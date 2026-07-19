-- lvim-vault.marks: the marks collection — collect local (a-z, one buffer) + global (A-Z) marks
-- as uniform entries, and the actions on them (jump / delete / re-letter / annotate / clear).
-- The marks themselves are LIVE editor state (getmarklist / nvim_buf_set_mark); only the optional
-- per-mark ANNOTATION persists, in the vault store keyed by mark letter + normalized file path.
-- Position conventions kept explicit because every API disagrees: getmarklist pos is getpos-style
-- (bufnum, lnum, col 1-based); nvim_buf_set_mark takes (1,0)-indexed line/col; the preview item
-- contract wants a 1-based col.
--
---@module "lvim-vault.marks"

local config = require("lvim-vault.config")
local store = require("lvim-vault.store")

local api = vim.api

local M = {}

---@class LvimVaultMark
---@field mark string        -- the letter (a-z local, A-Z global)
---@field kind "local"|"global"
---@field bufnr integer?     -- local marks: the owning buffer
---@field file string        -- normalized absolute path ("" for an unnamed buffer)
---@field lnum integer
---@field col integer        -- 1-based (getpos convention)
---@field text string        -- the mark line's text (preview snippet)
---@field annotation string? -- the stored user annotation

--- The text of `lnum` in `file` — from the loaded buffer when there is one (live, unsaved edits
--- included), else read from disk. Empty string when unreachable.
---@param file string
---@param bufnr integer?
---@param lnum integer
---@return string
local function line_text(file, bufnr, lnum)
    if bufnr and api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
        local lines = api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)
        return lines[1] or ""
    end
    if file ~= "" and vim.fn.filereadable(file) == 1 then
        local ok, lines = pcall(vim.fn.readfile, file, "", lnum)
        if ok and lines[lnum] then
            return lines[lnum]
        end
    end
    return ""
end

--- Every LOADED, NAMED real-file buffer — the set whose local a-z marks are enumerable (an unloaded file
--- cannot report its local marks; the API only exposes them once a buffer is loaded, exactly like vessel).
--- These are "the project": every open file, whether `:ls`-listed or hidden (a file opened through the tree
--- may be unlisted, so `buflisted` is intentionally NOT required — only a real file buffer, `buftype == ""`).
---@return integer[]
local function project_buffers()
    local out = {}
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "" and api.nvim_buf_get_name(buf) ~= "" then
            out[#out + 1] = buf
        end
    end
    return out
end

--- Collect ALL marks. The LIVE set is every LOCAL a-z mark across every open project buffer + every GLOBAL
--- A-Z mark. When `marks.disable_native` is on, the db is synced to that live set (so it tracks the editor for open
--- files / globals) and the marks of CLOSED files are then added FROM the db — so a mark stays visible even
--- after its file is closed. Each carries a preview snippet (from the buffer, else read from disk) and its
--- stored annotation.
---@return LvimVaultMark[]
function M.collect()
    local out = {}
    local notes = config.marks.annotations and store.available() and store.annotations() or {}
    local loaded_files = {}

    -- LOCAL marks — every open project buffer contributes its a-z marks.
    for _, buf in ipairs(project_buffers()) do
        local buf_file = vim.fs.normalize(api.nvim_buf_get_name(buf))
        loaded_files[buf_file] = true
        for _, m in ipairs(vim.fn.getmarklist(buf)) do
            local letter = m.mark:sub(2)
            if letter:match("^%l$") then
                local lnum, col = m.pos[2], m.pos[3]
                out[#out + 1] = {
                    mark = letter,
                    kind = "local",
                    bufnr = buf,
                    file = buf_file,
                    lnum = lnum,
                    col = col,
                    text = line_text(buf_file, buf, lnum),
                    annotation = notes[store.annotation_key(letter, buf_file)],
                }
            end
        end
    end
    -- GLOBAL marks (A-Z) — all of them, across every project.
    for _, m in ipairs(vim.fn.getmarklist()) do
        local letter = m.mark:sub(2)
        if letter:match("^%u$") then
            local file = vim.fs.normalize(vim.fn.fnamemodify(m.file or "", ":p"))
            local lnum, col = m.pos[2], m.pos[3]
            -- getmarklist() pos[1] is the mark's buffer when it is loaded (0 otherwise).
            local mbuf = m.pos[1] ~= 0 and m.pos[1] or nil
            out[#out + 1] = {
                mark = letter,
                kind = "global",
                bufnr = mbuf,
                file = file,
                lnum = lnum,
                col = col,
                text = line_text(file, mbuf, lnum),
                annotation = notes[store.annotation_key(letter, file)],
            }
        end
    end
    -- PERSISTED marks: reconcile the db to the live set (enumerable = loaded locals + globals), then add the
    -- CLOSED files' local rows (files not currently loaded) — the marks that live only in the db now.
    if config.marks.disable_native and store.available() then
        store.marks_replace(loaded_files, out)
        for _, r in ipairs(store.marks_all()) do
            if r.kind == "local" and not loaded_files[r.file] then
                out[#out + 1] = {
                    mark = r.mark,
                    kind = "local",
                    bufnr = nil,
                    file = r.file,
                    lnum = r.lnum,
                    col = r.col,
                    text = line_text(r.file, nil, r.lnum),
                    annotation = notes[store.annotation_key(r.mark, r.file)],
                }
            end
        end
    end
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then
            return a.kind == "local" -- local block first, then global
        end
        if a.kind == "local" and a.file ~= b.file then
            return a.file < b.file -- group a project's local marks by file
        end
        return a.mark < b.mark
    end)
    return out
end

--- Jump to a mark in `win` as a REAL jump (normal! g backtick — the jumplist gets the origin, so
--- `<C-o>` returns naturally). A GLOBAL mark opens its own file; a LOCAL mark lives in its OWN buffer (which
--- may not be the one `win` currently shows, now that Local spans every project buffer), so show that buffer
--- in `win` first, then jump.
---@param entry LvimVaultMark
---@param win integer
---@return boolean ok
function M.jump(entry, win)
    if not (win and api.nvim_win_is_valid(win)) then
        return false
    end
    api.nvim_set_current_win(win)
    if entry.kind == "local" then
        if entry.bufnr and api.nvim_buf_is_valid(entry.bufnr) then
            if api.nvim_win_get_buf(win) ~= entry.bufnr then
                pcall(api.nvim_win_set_buf, win, entry.bufnr)
            end
        elseif entry.file and entry.file ~= "" then
            pcall(vim.cmd, "edit " .. vim.fn.fnameescape(entry.file)) -- a CLOSED file's local mark (from the db)
        end
    end
    local ok = pcall(vim.cmd, "normal! g`" .. entry.mark)
    if not ok and entry.lnum then
        -- the native mark did not resolve (a just-opened closed file whose shada mark is gone) — use the
        -- db-stored position as the fallback, clamped to the buffer (the file may have shrunk since the mark
        -- was stored). Report the REAL outcome — a discarded pcall would claim success while the cursor never
        -- moved.
        local last = api.nvim_buf_line_count(api.nvim_win_get_buf(win))
        local lnum = math.max(1, math.min(entry.lnum, last))
        return (pcall(api.nvim_win_set_cursor, win, { lnum, math.max(0, (entry.col or 1) - 1) }))
    end
    return ok
end

--- Fire a `User LvimVaultMark<Event>` autocmd (the lvim-files `User LvimFiles*` idiom), so an open
--- panel — or any consumer — can react to a mutation without polling. `data` carries `{ mark, file,
--- from?, to? }`. Pattern `LvimVaultMark*` matches every event.
---@param event "Delete"|"Set"|"Change"|"Annotate"
---@param data table
local function emit(event, data)
    pcall(api.nvim_exec_autocmds, "User", { pattern = "LvimVaultMark" .. event, data = data })
end

--- Set a mark THROUGH the vault — the persisted, consistent path: record it in the db FIRST, then set the
--- native mark. The `:LvimVault mark add-local|add-global` commands drive this, so a mark set through the
--- vault can never diverge from the db. A non-file / unnamed buffer falls back to the native `m` (nothing to
--- persist). Emits `User LvimVaultMarkSet`.
---@param letter string  a-z (local) / A-Z (global)
---@return boolean ok
function M.set(letter)
    if not (type(letter) == "string" and letter:match("^%a$")) then
        return false
    end
    local buf = api.nvim_get_current_buf()
    local file = vim.fs.normalize(api.nvim_buf_get_name(buf))
    if vim.bo[buf].buftype ~= "" or file == "" then
        pcall(vim.cmd, "normal! m" .. letter) -- special / unnamed buffer: the native mark, nothing to persist
        return false
    end
    local pos = api.nvim_win_get_cursor(0) -- { lnum (1-based), col (0-based) }
    local kind = letter:match("%u") and "global" or "local"
    -- 1) the db first (source of truth) for LOCAL marks — those are the ones lost when a file closes; GLOBAL
    -- marks are already all-projects-persistent via shada / getmarklist(), so they need no db row.
    -- 2) then the native mark (both kinds).
    if kind == "local" and config.marks.disable_native and store.available() then
        store.mark_set(letter, file, kind, pos[1], pos[2] + 1)
    end
    pcall(api.nvim_buf_set_mark, buf, letter, pos[1], pos[2], {})
    emit("Set", { mark = letter, file = file })
    return true
end

--- Delete a mark (its annotation row is pruned with it). Emits `User LvimVaultMarkDelete`.
---@param entry LvimVaultMark
---@return boolean ok
function M.delete(entry)
    local ok
    if entry.kind == "local" then
        if entry.bufnr and api.nvim_buf_is_valid(entry.bufnr) then
            ok = api.nvim_buf_del_mark(entry.bufnr, entry.mark)
        else
            ok = true -- a CLOSED file's local mark: only its db row is reachable (the native mark is in shada)
        end
    else
        ok = api.nvim_del_mark(entry.mark)
    end
    if ok and store.available() then
        if config.marks.disable_native and entry.kind == "local" then
            store.mark_remove(entry.mark, entry.file)
        end
        if config.marks.annotations then
            store.annotation_set(entry.mark, entry.file, nil)
        end
    end
    if ok then
        emit("Delete", { mark = entry.mark, file = entry.file })
    end
    return ok == true
end

--- Move a mark to another LETTER (same position): set the new mark, delete the old one, and carry
--- the annotation over. A lowercase target stays in the entry's buffer; an uppercase target makes
--- it global. The target letter must be free is NOT enforced — re-lettering onto an existing mark
--- overwrites it, exactly like `m<letter>` would.
---@param entry LvimVaultMark
---@param letter string  a-z or A-Z
---@return boolean ok, string? err
function M.set_letter(entry, letter)
    if not letter:match("^%a$") then
        return false, "not a mark letter (a-z / A-Z)"
    end
    if letter == entry.mark then
        return true, nil
    end
    local buf = entry.bufnr
    if not (buf and api.nvim_buf_is_valid(buf)) then
        -- an unloaded global mark's file: load its buffer to host the new mark
        if entry.file == "" then
            return false, "mark buffer is gone"
        end
        buf = vim.fn.bufadd(entry.file)
        vim.fn.bufload(buf)
    end
    if letter:match("%l") and entry.kind == "global" then
        -- a LOCAL letter lands in the mark's own buffer (the panel's buffer may be another file)
        return false, "a global mark can only move to another global letter (A-Z)"
    end
    if not api.nvim_buf_set_mark(buf, letter, entry.lnum, math.max(0, entry.col - 1), {}) then
        return false, "could not set mark " .. letter
    end
    if entry.kind == "local" then
        -- use the RESOLVED handle (`buf`), not `entry.bufnr` — the latter is nil for a closed-file local
        -- mark (a db-only row), which would throw "bad argument" into the user's face.
        api.nvim_buf_del_mark(buf, entry.mark)
    else
        api.nvim_del_mark(entry.mark)
    end
    -- Persist the re-letter the same way the setter writes a fresh mark: drop the old LOCAL row and, when the
    -- target letter is local, write the new one — so a re-letter can't leave a stale db row if nvim quits
    -- before the next collect reconciles (globals live in shada, never the db).
    if config.marks.disable_native and store.available() and entry.file ~= "" then
        if entry.kind == "local" then
            store.mark_remove(entry.mark, entry.file)
        end
        if letter:match("%l") then
            store.mark_set(letter, entry.file, "local", entry.lnum, entry.col)
        end
    end
    if config.marks.annotations and store.available() and entry.annotation then
        store.annotation_set(entry.mark, entry.file, nil)
        store.annotation_set(letter, entry.file, entry.annotation)
    end
    emit("Change", { mark = entry.mark, file = entry.file, from = entry.mark, to = letter })
    return true, nil
end

--- The mark of `scope` sitting on the CURSOR LINE of the current window — the target of the single-mark
--- commands (`delete-local` / `delete-global` / `change-local` / `change-global`). Restricted to the cursor
--- LINE, and when that line holds several marks the pick is COLUMN-AWARE, exactly like the statuscolumn
--- letter: the first mark AT or AFTER the cursor column (so a mark under the cursor is the one returned, and
--- moving right advances to the next mark ahead), falling back to the nearest mark to the LEFT once the
--- cursor is past them all. A `"local"` scope scans the current buffer's own a-z marks; a `"global"` scope
--- scans the A-Z marks that point at this buffer's file. Returns a full LvimVaultMark (so `delete`/
--- `set_letter` can act on it) or nil.
---@param scope "local"|"global"
---@return LvimVaultMark?
function M.under_cursor(scope)
    local buf = api.nvim_get_current_buf()
    local name = api.nvim_buf_get_name(buf)
    if name == "" then
        return nil
    end
    local file = vim.fs.normalize(name)
    local cur = api.nvim_win_get_cursor(0)
    local lnum, ccol = cur[1], cur[2] + 1 -- 0-based window col → 1-based getmarklist col
    local notes = config.marks.annotations and store.available() and store.annotations() or {}
    -- Every mark of the scope on the cursor line, as full entries.
    local cands = {}
    if scope == "local" then
        for _, m in ipairs(vim.fn.getmarklist(buf)) do
            local letter = m.mark:sub(2)
            if letter:match("^%l$") and m.pos[2] == lnum then
                cands[#cands + 1] = {
                    mark = letter,
                    kind = "local",
                    bufnr = buf,
                    file = file,
                    lnum = lnum,
                    col = m.pos[3],
                    text = line_text(file, buf, lnum),
                    annotation = notes[store.annotation_key(letter, file)],
                }
            end
        end
    else
        for _, m in ipairs(vim.fn.getmarklist()) do
            local letter = m.mark:sub(2)
            if letter:match("^%u$") and m.pos[2] == lnum and vim.fs.normalize(m.file or "") == file then
                cands[#cands + 1] = {
                    mark = letter,
                    kind = "global",
                    bufnr = buf,
                    file = file,
                    lnum = lnum,
                    col = m.pos[3],
                    text = line_text(file, buf, lnum),
                    annotation = notes[store.annotation_key(letter, file)],
                }
            end
        end
    end
    if #cands == 0 then
        return nil
    end
    table.sort(cands, function(a, b)
        return a.col < b.col
    end)
    for _, e in ipairs(cands) do
        if e.col >= ccol then
            return e
        end
    end
    return cands[#cands]
end

--- Store / replace / clear the annotation of a mark (empty text clears). Emits
--- `User LvimVaultMarkAnnotate`.
---@param entry LvimVaultMark
---@param text string?
---@return boolean ok
function M.annotate(entry, text)
    if not (config.marks.annotations and store.available()) then
        return false
    end
    local ok = store.annotation_set(entry.mark, entry.file, text)
    if ok then
        emit("Annotate", { mark = entry.mark, file = entry.file })
    end
    return ok
end

--- The set of files whose LOCAL marks are currently enumerable — every open project buffer's file. A
--- local-mark annotation is verifiable (prunable) only when its file is in this set; a note for an unloaded
--- file is left untouched (absence from `live` proves nothing there).
---@return table<string, boolean>
local function enumerable_files()
    local files = {}
    for _, buf in ipairs(project_buffers()) do
        files[vim.fs.normalize(api.nvim_buf_get_name(buf))] = true
    end
    return files
end

--- Prune the annotation rows of marks deleted OUTSIDE the plugin (native `:delmarks`, an overwrite, the API,
--- a stale shada row) — but ONLY the ones we can PROVE are gone: a GLOBAL mark (always enumerable via
--- `getmarklist()`), or a LOCAL mark of an OPEN project buffer's file (enumerable via `getmarklist(buf)`). A
--- local-mark annotation for any UNLOADED file is left untouched. Call on panel open, after collecting.
---@return integer removed
function M.prune_orphans()
    if not (config.marks.annotations and store.available()) then
        return 0
    end
    local files = enumerable_files()
    local live = {}
    for _, e in ipairs(M.collect()) do
        live[store.annotation_key(e.mark, e.file)] = true
    end
    return store.annotations_prune(live, function(row)
        local letter = row.mark or ""
        if letter:match("^%u$") then
            return true -- a global mark is always enumerable
        end
        return files[row.file or ""] == true -- a local-mark row is verifiable only for an open buffer's file
    end)
end

--- Clear ALL local marks across every open project buffer (delmarks!) or ALL global A-Z marks, pruning THEIR
--- annotations only (scoped): clearing locals prunes the cleared files' local-mark notes, clearing globals
--- prunes the global ones — never the other scope, and never an unloaded file's local notes.
---@param kind "local"|"global"
---@return boolean ok
function M.clear(kind)
    local ok
    local files = enumerable_files()
    if kind == "local" then
        ok = true
        for _, b in ipairs(project_buffers()) do
            local o = pcall(api.nvim_buf_call, b, function()
                vim.cmd("delmarks!")
            end)
            ok = ok and o
        end
    else
        ok = pcall(vim.cmd, "delmarks A-Z")
    end
    if ok and store.available() then
        -- persisted marks: clear the whole scope (locals = loaded + closed files' rows) so the vault view is
        -- emptied, not just the loaded buffers
        if config.marks.disable_native then
            store.marks_clear_kind(kind, nil)
        end
        if config.marks.annotations then
            -- prune the stored annotations down to the marks that still exist, SCOPED to the cleared kind
            local live = {}
            for _, e in ipairs(M.collect()) do
                live[store.annotation_key(e.mark, e.file)] = true
            end
            store.annotations_prune(live, function(row)
                local letter = row.mark or ""
                if kind == "global" then
                    return letter:match("^%u$") ~= nil
                end
                -- local: with persist every local row was cleared, so any local note is verifiable; else only
                -- the loaded (cleared) files' local notes are
                if config.marks.disable_native then
                    return letter:match("^%l$") ~= nil
                end
                return letter:match("^%l$") ~= nil and files[row.file or ""] == true
            end)
        end
    end
    if ok then
        emit("Delete", { mark = kind == "local" and "*local*" or "*global*", file = "" })
    end
    return ok == true
end

return M
