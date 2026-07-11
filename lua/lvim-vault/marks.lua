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

--- Collect the marks visible from `buf`: its local a-z marks + every global A-Z mark, each with a
--- one-line preview snippet and its stored annotation (when `config.marks.annotations` is on).
---@param buf integer  the buffer the panel was opened from (owns the local marks)
---@return LvimVaultMark[]
function M.collect(buf)
    local out = {}
    local notes = config.marks.annotations and store.available() and store.annotations() or {}
    local buf_file = vim.fs.normalize(api.nvim_buf_get_name(buf))

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
    table.sort(out, function(a, b)
        if a.kind ~= b.kind then
            return a.kind == "local" -- local block first, then global
        end
        return a.mark < b.mark
    end)
    return out
end

--- Jump to a mark in `win` as a REAL jump (normal! g backtick — the jumplist gets the origin, so
--- `<C-o>` returns naturally). Global marks open their file; local marks assume `win` still shows
--- their buffer.
---@param entry LvimVaultMark
---@param win integer
---@return boolean ok
function M.jump(entry, win)
    if not (win and api.nvim_win_is_valid(win)) then
        return false
    end
    api.nvim_set_current_win(win)
    return pcall(vim.cmd, "normal! g`" .. entry.mark)
end

--- Fire a `User LvimVaultMark<Event>` autocmd (the lvim-files `User LvimFiles*` idiom), so an open
--- panel — or any consumer — can react to a mutation without polling. `data` carries `{ mark, file,
--- from?, to? }`. Pattern `LvimVaultMark*` matches every event.
---@param event "Delete"|"Set"|"Change"|"Annotate"
---@param data table
local function emit(event, data)
    pcall(api.nvim_exec_autocmds, "User", { pattern = "LvimVaultMark" .. event, data = data })
end

--- Delete a mark (its annotation row is pruned with it). Emits `User LvimVaultMarkDelete`.
---@param entry LvimVaultMark
---@return boolean ok
function M.delete(entry)
    local ok
    if entry.kind == "local" then
        ok = entry.bufnr ~= nil
            and api.nvim_buf_is_valid(entry.bufnr)
            and api.nvim_buf_del_mark(entry.bufnr, entry.mark)
    else
        ok = api.nvim_del_mark(entry.mark)
    end
    if ok and config.marks.annotations and store.available() then
        store.annotation_set(entry.mark, entry.file, nil)
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
        api.nvim_buf_del_mark(entry.bufnr, entry.mark)
    else
        api.nvim_del_mark(entry.mark)
    end
    if config.marks.annotations and store.available() and entry.annotation then
        store.annotation_set(entry.mark, entry.file, nil)
        store.annotation_set(letter, entry.file, entry.annotation)
    end
    emit("Change", { mark = entry.mark, file = entry.file, from = entry.mark, to = letter })
    return true, nil
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

--- Prune the annotation rows of marks that were deleted OUTSIDE the plugin (native `:delmarks`, an
--- overwrite, the API, a stale shada row) — but ONLY the ones this buffer can PROVE are gone.
--- Checkable rows: a GLOBAL mark (uppercase — always enumerable via `getmarklist()`), or a local
--- mark of the OPENER buffer's own file (its local marks are enumerable via `getmarklist(buf)`).
--- A local-mark annotation for ANY OTHER file is left untouched (its buffer may not be loaded, so
--- absence from `live` proves nothing — pruning it would silently drop a valid note). Call on
--- panel open, after collecting.
---@param buf integer  the opener buffer (owns the enumerable local marks)
---@return integer removed
function M.prune_orphans(buf)
    if not (config.marks.annotations and store.available()) then
        return 0
    end
    local buf_file = (buf and api.nvim_buf_is_valid(buf)) and vim.fs.normalize(api.nvim_buf_get_name(buf)) or ""
    local live = {}
    for _, e in ipairs(M.collect(buf)) do
        live[store.annotation_key(e.mark, e.file)] = true
    end
    return store.annotations_prune(live, function(row)
        local letter = row.mark or ""
        if letter:match("^%u$") then
            return true -- a global mark is always enumerable
        end
        -- a local-mark row is verifiable only for the buffer we actually enumerated
        return (row.file or "") == buf_file
    end)
end

--- Clear ALL local marks of `buf` (delmarks!) or ALL global A-Z marks, pruning THEIR annotations
--- only (scoped): clearing locals prunes the opener file's local-mark annotations, clearing
--- globals prunes the global ones — never the other scope, and never another file's local notes.
---@param kind "local"|"global"
---@param buf integer?  required for kind = "local"
---@return boolean ok
function M.clear(kind, buf)
    local ok
    if kind == "local" then
        if not (buf and api.nvim_buf_is_valid(buf)) then
            return false
        end
        ok = pcall(api.nvim_buf_call, buf, function()
            vim.cmd("delmarks!")
        end)
    else
        ok = pcall(vim.cmd, "delmarks A-Z")
    end
    local buf_file = (buf and api.nvim_buf_is_valid(buf)) and vim.fs.normalize(api.nvim_buf_get_name(buf)) or ""
    if ok and config.marks.annotations and store.available() then
        -- prune the stored annotations down to the marks that still exist, SCOPED to the cleared
        -- kind (+ the opener file for locals) so the other scope / other files are untouched
        local live = {}
        for _, e in ipairs(M.collect(buf or api.nvim_get_current_buf())) do
            live[store.annotation_key(e.mark, e.file)] = true
        end
        store.annotations_prune(live, function(row)
            local letter = row.mark or ""
            if kind == "global" then
                return letter:match("^%u$") ~= nil
            end
            return letter:match("^%l$") ~= nil and (row.file or "") == buf_file
        end)
    end
    if ok then
        emit("Delete", { mark = kind == "local" and "*local*" or "*global*", file = buf_file })
    end
    return ok == true
end

return M
