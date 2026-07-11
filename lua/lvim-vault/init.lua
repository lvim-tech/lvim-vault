-- lvim-vault: an editor-state bank — three collections in ONE lvim-ui.tabs panel:
--   • Marks  — local (a-z) marks across EVERY open project buffer + global (A-Z) marks from all projects,
--              with line preview + a persisted user ANNOTATION; jump / delete / re-letter / annotate / clear.
--   • Jumps  — the opener window's jumplist newest-first (deduped), ➤ on the current position;
--              REAL <C-o>/<C-i> travel, prune above/below, clear.
--   • Macros — the persistent macro bank (SQLite through lvim-utils.store): save the last recorded
--              register under a name, play with count, load into a register, edit as TEXT
--              (keytrans ↔ nvim_replace_termcodes), rename / delete / duplicate; project or
--              global scope.
-- The panel is one `ui.tabs` surface. Each tab's list is GROUPED into collapsible SECTIONS (the
-- form's native accordion — Marks: Local / Global; Jumps: This buffer / Other buffers; Macros:
-- Project / Global), a live title counter (shown/total), the per-tab CLEAR actions in the FOOTER
-- band, and the marks/jumps location PREVIEW panel (lvim-ui.preview through the tabs `preview`
-- block). Per-row action keys are wired in `on_open` and dispatch on the row-name namespace
-- (mk_/jp_/mc_) — ENTRY rows only (a section header just folds); every mutation re-collects +
-- `recalc()`s.
--
---@module "lvim-vault"

local config = require("lvim-vault.config")
local marks = require("lvim-vault.marks")
local jumps = require("lvim-vault.jumps")
local macros = require("lvim-vault.macros")
local store = require("lvim-vault.store")
local rowslib = require("lvim-vault.rows")
local highlights = require("lvim-vault.highlights")
local ui = require("lvim-ui")
local uipreview = require("lvim-ui.preview")
local hl = require("lvim-utils.highlight")
local merge = require("lvim-utils.utils").merge

local api = vim.api

local M = {}

-- The three collections (panel tabs). Icons are Nerd glyphs (bookmark / redo-history / record).
---@type { id: string, label: string, icon: string }[]
local TABS = {
    { id = "marks", label = "Marks", icon = "󰃀" },
    { id = "jumps", label = "Jumps", icon = "󰕍" },
    { id = "macros", label = "Macros", icon = "󰑋" },
}

-- Row-name namespace → its tab (the dispatch seam: rows are namespaced mk_/jp_/mc_).
---@type table<string, string>
local PREFIX_TAB = { mk = "marks", jp = "jumps", mc = "macros" }

---@class LvimVaultState
---@field handle table?        -- the live ui.tabs handle
---@field opener_win integer?  -- the window the panel opened from (owns the jumplist / gets the jumps)
---@field opener_buf integer?  -- the buffer the panel opened from (owns the local marks)
---@field layout string?       -- session-sticky per-command layout override
---@field active string         -- the active tab id (kept in sync from the cursor row's namespace)
---@field collapsed table<string, table<string, boolean>>  -- tab id → section id → collapsed? (per session)
---@field registry table<string, LvimVaultRowRecord>  -- row name → record (rebuilt per refresh)
---@field collections { marks: LvimVaultMark[], jumps: LvimVaultJump[], macros: LvimVaultMacro[] }
---@field counts table<string, { current: integer, total: integer }>
---@field tabs table[]?        -- the live tabs spec (rows mutated in place + recalc)
---@field preview_pan table?   -- the preview panel (captured in the provider's keys hook)
---@field first_loc table?     -- the initial tab's first location (preview before the handle exists)
---@field active_layout string? -- the RESOLVED layout of the open panel (override → config.layout)
---@field sync_group integer?  -- the live-sync augroup (created on open, cleared on close)
---@field mark_sig string?     -- last marks signature (letters + line numbers) for the cheap diff
local state = {
    active = "marks",
    -- section collapse state per session (default expanded — a section is collapsed only once toggled)
    collapsed = { marks = {}, jumps = {}, macros = {} },
    registry = {},
    collections = { marks = {}, jumps = {}, macros = {} },
    counts = {},
}

---@param msg string
---@param level integer?
local function notify(msg, level)
    vim.notify("lvim-vault: " .. msg, level or vim.log.levels.INFO)
end

-- ── collection + section grouping ────────────────────────────────────────────

--- Re-read all three LIVE collections (marks span every project buffer; jumps from the opener window;
--- macros from the store).
local function collect_all()
    state.collections.marks = marks.collect()
    state.collections.jumps = state.opener_win and jumps.collect(state.opener_win) or {}
    state.collections.macros = macros.list("all")
end

---@generic T
---@param entries T[]
---@param match fun(e: T): boolean
---@return T[]
local function group(entries, match)
    local out = {}
    for _, e in ipairs(entries) do
        if match(e) then
            out[#out + 1] = e
        end
    end
    return out
end

-- ── the preview (marks/jumps location, the picker contract) ──────────────────

--- The location under the cursor — resolved LIVE from the form cursor through the row registry,
--- so it survives tab switches and recalcs with zero stale state. Before the handle exists (the
--- open-time first render) it falls back to the initial tab's first location.
---@return table?  { filename, lnum, col } or nil (→ the empty placeholder)
local function current_location()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    local rec = name and state.registry[name] or nil
    local loc = rec and rec.loc or (not state.handle and state.first_loc or nil)
    if loc and loc.filename then
        return loc
    end
    return nil
end

local function refresh_preview()
    if state.preview_pan and state.preview_pan.refresh then
        state.preview_pan.refresh()
    end
end

--- The preview block provider handed to `ui.tabs` (nil when `config.preview` is off) — a thin
--- wrapper over lvim-ui.preview that captures the live panel for cursor-move refreshes.
---@return table?
local function build_preview()
    if not config.preview then
        return nil
    end
    local up = uipreview.new({ item = current_location, number = "normal" })
    return {
        size = function()
            return math.max(40, math.floor(vim.o.columns * 0.5)), 12
        end,
        update = up.update,
        item = up.item,
        reset = up.reset,
        keys = function(_, pan)
            state.preview_pan = pan
        end,
        on_close = function(pan)
            state.preview_pan = nil
            up.on_close(pan)
        end,
    }
end

-- ── row / band builders ──────────────────────────────────────────────────────

---@type fun(rec: LvimVaultRowRecord, count: integer)  forward decl (defined below); reached by on_pick
local perform

--- A row is picked (<CR>). In a DOCKED layout (area / bottom) the action runs IN PLACE and the panel
--- STAYS open: the docked panel is not modal (the editor is live beside it), so a mark/jump jumps in the
--- opener window and a macro plays into it, leaving the panel docked so the user can pick / replay again
--- without reopening. A `float` is modal/trapped, so there it stays close-then-perform, carrying the record
--- + typed count out through the tabs callback. (`perform` switches to the opener window before playing a
--- macro, so the queued keys never land in the panel.)
---@param rec LvimVaultRowRecord
---@param close fun(confirmed: boolean, result: any)
local function on_pick(rec, close)
    local docked = state.active_layout == "area" or state.active_layout == "bottom"
    if docked then
        perform(rec, vim.v.count1)
        return
    end
    close(true, { rec = rec, count = vim.v.count1 })
end

---@param prompt string
---@param fn fun()
local function confirm_then(prompt, fn)
    ui.confirm({
        prompt = prompt,
        default_no = true,
        callback = function(yes)
            if yes then
                fn()
            end
        end,
    })
end

-- ── collapsible sections ─────────────────────────────────────────────────────

--- Build the grouped rows for a tab: one collapsible SECTION header per group (an accordion whose
--- children are the group's entry rows), and update `state.counts[tab] = { current, total }` where
--- `current` counts only the entries in EXPANDED sections (what is actually shown). A section's
--- children are built (and its entries registered) only while it is expanded — a collapsed section
--- costs nothing. `groups` = `{ { id, label, entries } }`; `row_of(entry)` builds one child row.
---@param tab string
---@param prefix string
---@param total integer
---@param bw integer   the collection's badge content width (sizes each section's caret box)
---@param groups { id: string, label: string, entries: table[], badge_hl: string, accent: string }[]
---@param row_of fun(entry: table): table
---@return table[] rows
local function sectioned(tab, prefix, total, bw, groups, row_of)
    local rows = {}
    local shown = 0
    for _, g in ipairs(groups) do
        local expanded = state.collapsed[tab][g.id] ~= true -- default expanded
        local children = {}
        if expanded then
            for _, e in ipairs(g.entries) do
                children[#children + 1] = row_of(e)
            end
            shown = shown + #g.entries
        end
        rows[#rows + 1] = rowslib.section(
            prefix .. "_sec_" .. g.id,
            g.label,
            #g.entries,
            expanded,
            children,
            bw,
            g.badge_hl,
            g.accent
        )
    end
    state.counts[tab] = { current = shown, total = total }
    return rows
end

--- Build one tab's row set: collapsible sections (or an empty-state row), refreshing the registry
--- records and the title-counter numbers. The clear actions now live in the FOOTER (build_footer).
---@param tab_id string
---@return table[] rows
local function build_rows(tab_id)
    if tab_id == "marks" then
        local entries = state.collections.marks
        if #entries == 0 then
            state.counts.marks = { current = 0, total = 0 }
            return { rowslib.empty("mk", "No marks — set one with m<letter> in a buffer.") }
        end
        local locw = rowslib.loc_width(entries)
        local bw = rowslib.badge_width(entries, "mark")
        return sectioned("marks", "mk", #entries, bw, {
            {
                id = "local",
                label = "Local",
                badge_hl = "LvimVaultMarkBadge",
                accent = config.colors.marks,
                entries = group(entries, function(e)
                    return e.kind == "local"
                end),
            },
            {
                id = "global",
                label = "Global",
                badge_hl = "LvimVaultMarkGlobalBadge",
                accent = config.colors.marks_global,
                entries = group(entries, function(e)
                    return e.kind == "global"
                end),
            },
        }, function(e)
            return rowslib.mark_row(e, state.registry, on_pick, locw, bw)
        end)
    elseif tab_id == "jumps" then
        local entries = state.collections.jumps
        if #entries == 0 then
            state.counts.jumps = { current = 0, total = 0 }
            return { rowslib.empty("jp", "The jumplist is empty.") }
        end
        local locw = rowslib.loc_width(entries)
        local bw = rowslib.badge_width(entries, "jump")
        return sectioned("jumps", "jp", #entries, bw, {
            {
                id = "this",
                label = "This buffer",
                badge_hl = "LvimVaultJumpBadge",
                accent = config.colors.jumps,
                entries = group(entries, function(e)
                    return e.bufnr == state.opener_buf
                end),
            },
            {
                id = "other",
                label = "Other buffers",
                badge_hl = "LvimVaultJumpBadge",
                accent = config.colors.jumps,
                entries = group(entries, function(e)
                    return e.bufnr ~= state.opener_buf
                end),
            },
        }, function(e)
            return rowslib.jump_row(e, state.registry, on_pick, locw, bw)
        end)
    end
    -- macros
    local entries = state.collections.macros
    if not store.available() then
        state.counts.macros = { current = 0, total = 0 }
        return { rowslib.empty("mc", "sqlite.lua is missing — the macro bank needs it (see :checkhealth).") }
    end
    if #entries == 0 then
        state.counts.macros = { current = 0, total = 0 }
        return {
            rowslib.empty(
                "mc",
                "No banked macros — record one (q<reg>…q), then press s or :LvimVault save <name>."
            ),
        }
    end
    local namew = rowslib.name_width(entries)
    local bw = rowslib.badge_width(entries, "macro")
    local groups = {}
    if config.macros.project_scope then
        groups[#groups + 1] = {
            id = "project",
            label = "Project",
            badge_hl = "LvimVaultMacroBadge",
            accent = config.colors.macros,
            entries = group(entries, function(m)
                return m.scope == "project"
            end),
        }
    end
    groups[#groups + 1] = {
        id = "global",
        label = "Global",
        badge_hl = "LvimVaultMacroBadge",
        accent = config.colors.macros,
        entries = group(entries, function(m)
            return m.scope == "global"
        end),
    }
    return sectioned("macros", "mc", #entries, bw, groups, function(m)
        return rowslib.macro_row(m, state.registry, on_pick, namew, bw)
    end)
end

-- ── per-tab footer (the clear / delete-all actions) ──────────────────────────

--- The footer button list for a tab — the clear / delete-all actions moved off the content into the
--- surface footer band (rebuilt per tab by ui.tabs). Each `run` goes through `ui.confirm` and then
--- `M.refresh`. Keys are the CAPITALS freed by dropping the filter bar (never clash with the
--- lowercase row-action keys).
---@param tab_id string
---@return table[]  footer specs { key, name, run }
local function build_footer(tab_id)
    if tab_id == "marks" then
        return {
            {
                key = "L",
                name = "Clear local",
                run = function()
                    confirm_then("Delete ALL local marks of the buffer?", function()
                        marks.clear("local")
                        M.refresh()
                    end)
                end,
            },
            {
                key = "G",
                name = "Clear global",
                run = function()
                    confirm_then("Delete ALL global A-Z marks?", function()
                        marks.clear("global")
                        M.refresh()
                    end)
                end,
            },
        }
    elseif tab_id == "jumps" then
        return {
            {
                key = "C",
                name = "Clear jumplist",
                run = function()
                    confirm_then("Clear the window's jumplist?", function()
                        jumps.clear(state.opener_win)
                        M.refresh()
                    end)
                end,
            },
        }
    end
    -- macros
    if not store.available() then
        return {}
    end
    local specs = {}
    if config.macros.project_scope then
        specs[#specs + 1] = {
            key = "P",
            name = "Clear project",
            run = function()
                confirm_then("Delete ALL project macros for this root?", function()
                    macros.clear_scope("project")
                    M.refresh()
                end)
            end,
        }
    end
    specs[#specs + 1] = {
        key = "G",
        name = "Clear global",
        run = function()
            confirm_then("Delete ALL global macros?", function()
                macros.clear_scope("global")
                M.refresh()
            end)
        end,
    }
    return specs
end

--- The active tab, derived from the cursor row's namespace (survives h/l switches the presenter
--- performs without telling the consumer).
---@return string
local function active_tab()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    local tab = name and PREFIX_TAB[name:sub(1, 2)] or nil
    if tab then
        state.active = tab
    end
    return state.active
end

-- ── actions after close (jump / play run back in the opener) ─────────────────

--- Perform the picked row's action in the opener window — after the panel is closed (a `float`), or IN
--- PLACE while a DOCKED panel stays open (mark jump / jumplist travel / macro play). For a macro it switches
--- to the opener window FIRST, so the feedkeys land there and never in the panel. Assigned to the forward
--- decl above so on_pick can reach it.
---@param rec LvimVaultRowRecord
---@param count integer
function perform(rec, count)
    if rec.kind == "mark" then
        if not marks.jump(rec.entry, state.opener_win) then
            notify("could not jump to mark " .. rec.entry.mark, vim.log.levels.WARN)
        end
    elseif rec.kind == "jump" then
        if not jumps.jump(rec.entry, state.opener_win) then
            notify("could not travel the jumplist", vim.log.levels.WARN)
        end
    elseif rec.kind == "macro" then
        if state.opener_win and api.nvim_win_is_valid(state.opener_win) then
            api.nvim_set_current_win(state.opener_win)
        end
        macros.play(rec.entry, count)
    end
end

-- ── the per-row action keys (on_open) ────────────────────────────────────────

--- The record under the form cursor.
---@return LvimVaultRowRecord?
local function cur_rec()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    return name and state.registry[name] or nil
end

--- The macro scope `s` should save into — WHERE the cursor is: the Project section (its header or
--- a project macro) → "project"; otherwise → "global". Replaces the old filter-driven scope.
---@return "project"|"global"
local function current_macro_scope()
    local name = state.handle and state.handle.cursor_name and state.handle.cursor_name()
    if type(name) == "string" then
        if name == "mc_sec_project" then
            return "project"
        end
        if name == "mc_sec_global" then
            return "global"
        end
        local rec = state.registry[name]
        if rec and rec.kind == "macro" and rec.entry.scope == "project" then
            return "project"
        end
    end
    return "global"
end

--- Wire the per-row action keys on the panel buffer. Every key dispatches on the focused row's
--- kind (the installer pattern), so one set serves all three tabs; mutations re-collect +
--- recalc. Digits are UN-nopped so a typed count reaches the macro <CR> play.
---@param buf integer
local function wire_keys(buf)
    local function key(lhs, fn, desc)
        vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = desc })
    end
    -- the modal lock nops digit keys; macro play takes a COUNT, so restore native count entry
    for i = 0, 9 do
        pcall(vim.keymap.del, "n", tostring(i), { buffer = buf })
    end

    key("d", function()
        local rec = cur_rec()
        if not rec then
            return
        end
        if rec.kind == "mark" then
            marks.delete(rec.entry)
            M.refresh()
        elseif rec.kind == "macro" then
            confirm_then(("Delete macro '%s'?"):format(rec.entry.name), function()
                macros.delete(rec.entry)
                M.refresh()
            end)
        end
    end, "Delete mark / macro")

    key("a", function()
        local rec = cur_rec()
        if not (rec and rec.kind == "mark") then
            return
        end
        if not config.marks.annotations then
            notify("mark annotations are disabled (config.marks.annotations)", vim.log.levels.WARN)
            return
        end
        ui.input({
            title = ("Annotate mark %s (empty clears)"):format(rec.entry.mark),
            default = rec.entry.annotation or "",
            callback = function(confirmed, value)
                if confirmed == true then
                    marks.annotate(rec.entry, value)
                    M.refresh()
                end
            end,
        })
    end, "Annotate mark")

    key("m", function()
        local rec = cur_rec()
        if not (rec and rec.kind == "mark") then
            return
        end
        ui.input({
            title = ("Move mark %s to letter"):format(rec.entry.mark),
            callback = function(confirmed, value)
                if confirmed ~= true then
                    return
                end
                local ok, err = marks.set_letter(rec.entry, vim.trim(value or ""))
                if not ok then
                    notify(err or "could not move the mark", vim.log.levels.WARN)
                end
                M.refresh()
            end,
        })
    end, "Move mark to another letter")

    -- a literal "<" lhs must be written "<lt>" — a bare "<" collides with key-notation parsing
    key("<lt>", function()
        local rec = cur_rec()
        if rec and rec.kind == "jump" then
            jumps.prune(state.opener_win, state.collections.jumps, rec.entry, "above")
            M.refresh()
        end
    end, "Prune newer jump entries")

    key(">", function()
        local rec = cur_rec()
        if rec and rec.kind == "jump" then
            jumps.prune(state.opener_win, state.collections.jumps, rec.entry, "below")
            M.refresh()
        end
    end, "Prune older jump entries")

    key("s", function()
        local reg = macros.source_register()
        local scope = current_macro_scope()
        ui.input({
            title = ("Save @%s as %s macro"):format(reg, scope),
            callback = function(confirmed, value)
                if confirmed ~= true then
                    return
                end
                local ok, err = macros.save(value, reg, scope)
                if ok then
                    notify(("saved @%s as '%s' (%s)"):format(reg, vim.trim(value), scope))
                else
                    notify(err or "could not save the macro", vim.log.levels.WARN)
                end
                M.refresh()
            end,
        })
    end, "Save the recorded register as a macro")

    key("e", function()
        local rec = cur_rec()
        if not (rec and rec.kind == "macro") then
            return
        end
        ui.input({
            title = ("Edit macro '%s'"):format(rec.entry.name),
            default = rec.entry.keys or "",
            width = 0.8,
            callback = function(confirmed, value)
                if confirmed ~= true then
                    return
                end
                local ok, err = macros.edit(rec.entry, value)
                if not ok then
                    notify(err or "could not edit the macro", vim.log.levels.WARN)
                end
                M.refresh()
            end,
        })
    end, "Edit macro keys as text")

    key("r", function()
        local rec = cur_rec()
        if not (rec and rec.kind == "macro") then
            return
        end
        ui.input({
            title = ("Load '%s' into register"):format(rec.entry.name),
            default = rec.entry.register or config.macros.default_register,
            callback = function(confirmed, value)
                if confirmed ~= true then
                    return
                end
                local ok, err = macros.load(rec.entry, vim.trim(value or ""))
                if ok then
                    notify(("loaded '%s' into @%s — replay with @%s"):format(rec.entry.name, value, value))
                else
                    notify(err or "could not load the macro", vim.log.levels.WARN)
                end
            end,
        })
    end, "Load macro into a register")

    key("n", function()
        local rec = cur_rec()
        if not (rec and rec.kind == "macro") then
            return
        end
        ui.input({
            title = ("Rename macro '%s'"):format(rec.entry.name),
            default = rec.entry.name or "",
            callback = function(confirmed, value)
                if confirmed ~= true then
                    return
                end
                local ok, err = macros.rename(rec.entry, value)
                if not ok then
                    notify(err or "could not rename the macro", vim.log.levels.WARN)
                end
                M.refresh()
            end,
        })
    end, "Rename macro")

    key("c", function()
        local rec = cur_rec()
        if rec and rec.kind == "macro" then
            macros.duplicate(rec.entry)
            M.refresh()
        end
    end, "Duplicate macro")
end

-- ── live sync while the panel is open ────────────────────────────────────────

--- A CHEAP signature of the opener's marks (letters + line numbers, local + global) — a change
--- here means a mark was added / removed / moved OUTSIDE the panel. Handful of marks, so this is
--- light enough to run on CursorMoved while a docked panel is open. Collects nothing heavy (no
--- line text / annotations) — just enumerates the two mark lists.
---@return string
local function marks_signature()
    if not (state.opener_buf and api.nvim_buf_is_valid(state.opener_buf)) then
        return ""
    end
    local parts = {}
    for _, m in ipairs(vim.fn.getmarklist(state.opener_buf)) do
        if m.mark:sub(2):match("^%l$") then
            parts[#parts + 1] = m.mark .. m.pos[2]
        end
    end
    for _, m in ipairs(vim.fn.getmarklist()) do
        if m.mark:sub(2):match("^%u$") then
            parts[#parts + 1] = m.mark .. (m.pos[2] or 0) .. (m.file or "")
        end
    end
    table.sort(parts)
    return table.concat(parts, "|")
end

--- Re-collect + refresh ONLY when the marks signature changed (the CursorMoved/CursorHold diff on
--- a docked panel), so an editor edit that touched marks is reflected without any panel action and
--- a plain cursor move costs one cheap enumeration.
local function sync_if_marks_changed()
    local sig = marks_signature()
    if sig ~= state.mark_sig then
        state.mark_sig = sig
        M.refresh()
    end
end

--- Wire the live-sync autocmds for an open panel, into a per-open augroup torn down on close (so
--- there is ZERO cost when no panel is open). Always: `User LvimVaultMark*` (our own mutation
--- events) → refresh. Docked only (a float is modal/trapped, so nothing changes under it):
--- WinEnter on the panel window (return-to-panel) → refresh; a global CursorMoved / CursorHold
--- signature-diff → refresh when marks changed in the editor beside the dock.
---@param docked boolean
---@param panel_win integer?
local function setup_sync(docked, panel_win)
    local group = api.nvim_create_augroup("LvimVaultSync", { clear = true })
    state.sync_group = group
    state.mark_sig = marks_signature()

    api.nvim_create_autocmd("User", {
        group = group,
        pattern = "LvimVaultMark*",
        callback = function()
            state.mark_sig = marks_signature()
            M.refresh()
        end,
    })

    if not docked then
        return
    end
    if panel_win and api.nvim_win_is_valid(panel_win) then
        api.nvim_create_autocmd("WinEnter", {
            group = group,
            callback = function()
                if api.nvim_get_current_win() == panel_win then
                    M.refresh()
                end
            end,
        })
    end
    api.nvim_create_autocmd({ "CursorMoved", "CursorHold" }, {
        group = group,
        callback = function()
            -- ignore moves INSIDE the panel (its own rows) — only editor-side edits matter here
            if panel_win and api.nvim_get_current_win() == panel_win then
                return
            end
            sync_if_marks_changed()
        end,
    })
end

--- Tear the live-sync augroup down (on close).
local function teardown_sync()
    if state.sync_group then
        pcall(api.nvim_del_augroup_by_id, state.sync_group)
        state.sync_group = nil
    end
end

-- ── the panel ────────────────────────────────────────────────────────────────

--- Rebuild every tab's rows from the CURRENT collections + collapse state and re-fit the open
--- panel, keeping the cursor line. Does NOT re-read the editor (that is `collect_all`) — used by a
--- fold (the collections are unchanged, only the collapse state / visible count is).
local function rebuild()
    if not (state.handle and state.handle.valid and state.handle.valid()) then
        return
    end
    state.registry = {}
    for i, t in ipairs(TABS) do
        state.tabs[i].rows = build_rows(t.id)
    end
    local idx = state.handle.cursor_index()
    state.handle.recalc()
    state.handle.focus_index(idx)
    refresh_preview()
end

--- Re-read the live collections then rebuild — the ONE mutation path (every entry action lands
--- here, plus the live-sync events).
function M.refresh()
    if not (state.handle and state.handle.valid and state.handle.valid()) then
        return
    end
    collect_all()
    rebuild()
end

--- A section header was folded/unfolded (the form fires `on_change` on an accordion toggle):
--- persist the collapse state for the session and rebuild so the caret flips and the title counter
--- (shown/total) tracks the now-hidden/shown entries. The collections are unchanged, so no
--- re-collect. Non-section changes (there are none in this panel) are ignored.
---@param row table  the toggled accordion row
local function on_section_toggle(row)
    if not (row and type(row.name) == "string" and row.children) then
        return
    end
    local tab = PREFIX_TAB[row.name:sub(1, 2)]
    local sec = row.name:match("_sec_(.+)$")
    if not (tab and sec) then
        return
    end
    state.collapsed[tab][sec] = not row.expanded
    rebuild()
end

--- The window + buffer whose marks / jumps the vault should report: the current one when it is a normal
--- FILE window, else a fallback (the previous window, then any normal window in the tab). Opening the vault
--- from a UI panel (the file tree, a picker, …) must still show the code buffer's LOCAL marks — a panel
--- buffer has none, so capturing `nvim_get_current_buf()` blindly reported an empty Local section.
---@return integer win, integer buf
local function resolve_opener()
    local function normal(win)
        if not (win and win ~= 0 and api.nvim_win_is_valid(win)) then
            return false
        end
        if api.nvim_win_get_config(win).relative ~= "" then
            return false -- a float (picker / preview) — not the editor
        end
        return vim.bo[api.nvim_win_get_buf(win)].buftype == "" -- a real file buffer (not nofile/terminal/…)
    end
    local cur = api.nvim_get_current_win()
    if normal(cur) then
        return cur, api.nvim_win_get_buf(cur)
    end
    local prev = vim.fn.win_getid(vim.fn.winnr("#"))
    if prev ~= cur and normal(prev) then
        return prev, api.nvim_win_get_buf(prev)
    end
    for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
        if win ~= cur and normal(win) then
            return win, api.nvim_win_get_buf(win)
        end
    end
    return cur, api.nvim_win_get_buf(cur) -- nothing better (only panels open)
end

--- Open the vault panel.
---@param tab string?     initial tab id ("marks" | "jumps" | "macros"; default "marks")
---@param layout string?  per-open layout override ("float" | "area" | "bottom"; session-sticky)
function M.open(tab, layout)
    if state.handle and state.handle.valid and state.handle.valid() then
        state.handle.close()
    end
    -- Drop the old handle NOW: the old panel's close callback (which nils it) may not run
    -- synchronously, and `title_count` → `active_tab()` reads `state.handle.cursor_name()` while the
    -- NEW panel is being constructed — a lingering old handle would report the PREVIOUS tab's cursor,
    -- so the border counter would show the previous tab's numbers. Nil → active_tab falls back to the
    -- freshly-set `state.active` until the new handle's cursor exists.
    state.handle = nil
    if layout then
        state.layout = layout -- a per-command override is sticky for the session
    end
    state.opener_win, state.opener_buf = resolve_opener()
    state.active = (tab == "jumps" or tab == "macros") and tab or "marks"
    -- the RESOLVED layout of THIS open (the override → the cross-session default): drives the
    -- docked <CR>-stays-open behaviour and the live-sync WinEnter/CursorMoved wiring
    state.active_layout = state.layout or config.layout
    collect_all()
    -- drop annotations of marks deleted outside the plugin (scoped: only the marks we can PROVE
    -- are gone — global marks + this buffer's local marks; other files' local notes are kept)
    marks.prune_orphans()

    state.registry = {}
    state.tabs = {}
    local sel = 1
    for i, t in ipairs(TABS) do
        state.tabs[i] = {
            label = t.label,
            icon = t.icon,
            menu = true,
            rows = build_rows(t.id),
            footer = build_footer(t.id), -- the per-tab clear actions (rebuilt on tab switch by ui.tabs)
        }
        if t.id == state.active then
            sel = i
        end
    end
    -- the initial preview location: the active tab's first ENTRY (a section child) with a location,
    -- resolved before the handle exists (the open-time first render)
    state.first_loc = nil
    for _, sec in ipairs(state.tabs[sel].rows) do
        for _, row in ipairs(sec.children or {}) do
            if row._item and row._item.filename then
                state.first_loc = row._item
                break
            end
        end
        if state.first_loc then
            break
        end
    end

    state.handle = ui.tabs({
        title = config.title,
        title_pos = config.title_pos,
        title_count = function()
            return state.counts[active_tab()]
        end,
        tabs = state.tabs,
        layout = state.layout or config.layout,
        pad = 0, -- body row left lpad (default 2): the badges already carry their own gutter, so drop it — the list sits flush
        tab_selector = sel,
        cursorline_hl = "LvimUiCursorLine",
        preview = build_preview(),
        on_change = on_section_toggle,
        on_item_change = function()
            refresh_preview()
        end,
        on_open = function(buf, win)
            wire_keys(buf)
            -- live sync: our own mutation events always; a docked panel also follows editor-side
            -- mark edits (WinEnter return + a cheap CursorMoved signature diff)
            setup_sync(state.active_layout == "area" or state.active_layout == "bottom", win)
        end,
        callback = function(confirmed, result)
            teardown_sync()
            state.handle = nil
            state.tabs = nil
            state.preview_pan = nil
            if confirmed == true and type(result) == "table" and result.rec then
                vim.schedule(function()
                    perform(result.rec, result.count or 1)
                end)
            end
        end,
    })
end

--- Bank the last recorded register under `name` without opening the panel
--- (`:LvimVault save <name>`; prompts when the name is missing). Saves GLOBAL scope — bank into
--- the project scope from the panel (`s` with the Project filter active).
---@param name string?
function M.save(name)
    if name and vim.trim(name) ~= "" then
        local reg = macros.source_register()
        local ok, err = macros.save(name, reg, "global")
        if ok then
            notify(("saved @%s as '%s' (global)"):format(reg, vim.trim(name)))
        else
            notify(err or "could not save the macro", vim.log.levels.WARN)
        end
        return
    end
    ui.input({
        title = ("Save @%s as macro"):format(macros.source_register()),
        callback = function(confirmed, value)
            if confirmed == true then
                M.save(value)
            end
        end,
    })
end

---@type table<string, boolean>
local LAYOUTS = { float = true, area = true, bottom = true }
-- Subcommands: the PLURALS (marks/jumps/macros) open a panel tab; the SINGULARS (mark/jump/macro) run
-- editor commands on one item; `save` banks a macro. `save`/`macro` are GREEDY — they consume the rest of
-- the tokens verbatim (a macro name may contain spaces and must not be eaten by layout detection).
---@type table<string, boolean>
local SUBS = { marks = true, jumps = true, macros = true, save = true, mark = true, jump = true, macro = true }

--- The `mark` subcommand's actions (`:LvimVault mark <action>`).
---@type table<string, boolean>
local MARK_ACTIONS = {
    ["add-local"] = true,
    ["add-global"] = true,
    ["delete-local"] = true,
    ["delete-global"] = true,
    ["delete-locals"] = true,
    ["delete-globals"] = true,
    ["change-local"] = true,
    ["change-global"] = true,
    ["annotate-local"] = true,
    ["annotate-global"] = true,
    ["jump-local"] = true,
    ["jump-global"] = true,
    ["next"] = true,
    ["prev"] = true,
}

--- The `jump` subcommand's actions (`:LvimVault jump <action>`).
---@type table<string, boolean>
local JUMP_ACTIONS = { clear = true, ["prune-above"] = true, ["prune-below"] = true }

--- The `macro` subcommand's actions (`:LvimVault macro <action> <name>`).
---@type table<string, boolean>
local MACRO_ACTIONS = { save = true, play = true, load = true, delete = true }

--- The `:LvimVault mark <action>` handlers (act on the editor, not the panel):
---   * `add-local` / `add-global` — set a mark at the cursor: prompt for its letter (a-z / A-Z) and set
---     it through the vault setter (db first, then native), so it persists.
---   * `delete-local` / `delete-global` — delete the SINGLE mark on the cursor line (the column-aware
---     pick, same as the statuscolumn letter).
---   * `delete-locals` / `delete-globals` — clear ALL local / global marks (confirms first).
---   * `change-local` / `change-global` — re-letter the mark on the cursor line to a prompted
---     letter (a-z for local, A-Z for global), through the vault setter so the db stays in lockstep.
---   * `annotate-local` / `annotate-global` — annotate the mark on the cursor line (empty clears).
---   * `jump-local` / `jump-global` — prompt for a letter and jump to that mark (a REAL jump).
---   * `next` / `prev` — jump to the next / previous LOCAL mark in the current buffer (wraps).
--- Refreshes an open panel afterwards (a no-op when none is open).
---@param action string?
function M.mark_command(action)
    if action == "add-local" or action == "add-global" then
        local scope = action == "add-global" and "global" or "local"
        local want = scope == "global" and "A-Z" or "a-z"
        -- Set at the window that invoked the command: the prompt float steals focus, so pin the origin
        -- window and its cursor now, and restore it before the setter reads the position.
        local win = api.nvim_get_current_win()
        ui.input({
            title = ("Add %s mark (%s)"):format(scope, want),
            callback = function(confirmed, value)
                if confirmed ~= true then
                    return
                end
                local letter = vim.trim(value or "")
                if not letter:match(scope == "global" and "^%u$" or "^%l$") then
                    notify(("not a %s mark letter (%s)"):format(scope, want), vim.log.levels.WARN)
                    return
                end
                if api.nvim_win_is_valid(win) then
                    api.nvim_set_current_win(win)
                end
                if marks.set(letter) then
                    notify(("added %s mark %s"):format(scope, letter))
                    M.refresh()
                else
                    notify("could not add the mark (special / unnamed buffer)", vim.log.levels.WARN)
                end
            end,
        })
        return
    end
    if action == "delete-locals" or action == "delete-globals" then
        local kind = action == "delete-globals" and "global" or "local"
        confirm_then(("Clear ALL %s marks?"):format(kind), function()
            if marks.clear(kind) then
                notify(("cleared all %s marks"):format(kind))
                M.refresh()
            else
                notify("could not clear the marks", vim.log.levels.WARN)
            end
        end)
        return
    end
    if action == "delete-local" or action == "delete-global" then
        local scope = action == "delete-global" and "global" or "local"
        local entry = marks.under_cursor(scope)
        if not entry then
            notify(("no %s mark on the cursor line"):format(scope), vim.log.levels.WARN)
            return
        end
        if marks.delete(entry) then
            notify(("deleted %s mark %s"):format(scope, entry.mark))
            M.refresh()
        else
            notify("could not delete the mark", vim.log.levels.WARN)
        end
        return
    end
    if action == "change-local" or action == "change-global" then
        local scope = action == "change-global" and "global" or "local"
        local entry = marks.under_cursor(scope)
        if not entry then
            notify(("no %s mark on the cursor line"):format(scope), vim.log.levels.WARN)
            return
        end
        local want = scope == "global" and "A-Z" or "a-z"
        ui.input({
            title = ("Re-letter %s mark %s to (%s)"):format(scope, entry.mark, want),
            callback = function(confirmed, value)
                if confirmed ~= true then
                    return
                end
                local letter = vim.trim(value or "")
                if not letter:match(scope == "global" and "^%u$" or "^%l$") then
                    notify(("not a %s mark letter (%s)"):format(scope, want), vim.log.levels.WARN)
                    return
                end
                local ok, err = marks.set_letter(entry, letter)
                if not ok then
                    notify(err or "could not move the mark", vim.log.levels.WARN)
                    return
                end
                notify(("mark %s → %s"):format(entry.mark, letter))
                M.refresh()
            end,
        })
        return
    end
    if action == "annotate-local" or action == "annotate-global" then
        local scope = action == "annotate-global" and "global" or "local"
        local entry = marks.under_cursor(scope)
        if not entry then
            notify(("no %s mark on the cursor line"):format(scope), vim.log.levels.WARN)
            return
        end
        ui.input({
            title = ("Annotate %s mark %s (empty clears)"):format(scope, entry.mark),
            callback = function(confirmed, value)
                if confirmed ~= true then
                    return
                end
                if marks.annotate(entry, vim.trim(value or "")) then
                    M.refresh()
                else
                    notify("annotations are disabled (marks.annotations = false)", vim.log.levels.WARN)
                end
            end,
        })
        return
    end
    if action == "jump-local" or action == "jump-global" then
        local scope = action == "jump-global" and "global" or "local"
        local want = scope == "global" and "A-Z" or "a-z"
        local win = api.nvim_get_current_win()
        ui.input({
            title = ("Jump to %s mark (%s)"):format(scope, want),
            callback = function(confirmed, value)
                if confirmed ~= true then
                    return
                end
                local letter = vim.trim(value or "")
                if not letter:match(scope == "global" and "^%u$" or "^%l$") then
                    notify(("not a %s mark letter (%s)"):format(scope, want), vim.log.levels.WARN)
                    return
                end
                -- resolve the letter through collect() (includes CLOSED-file local rows); for a local letter
                -- shared across buffers, prefer this window's own buffer.
                local buf = api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) or nil
                local target
                for _, e in ipairs(marks.collect()) do
                    if e.kind == scope and e.mark == letter then
                        if scope == "local" and e.bufnr == buf then
                            target = e
                            break
                        end
                        target = target or e
                    end
                end
                if not target then
                    notify(("no %s mark %s"):format(scope, letter), vim.log.levels.WARN)
                    return
                end
                if not marks.jump(target, win) then
                    notify("could not jump to the mark", vim.log.levels.WARN)
                end
            end,
        })
        return
    end
    if action == "next" or action == "prev" then
        -- buffer-local navigation: the CURRENT buffer's a-z marks, sorted by position, jump to the one after
        -- (next) / before (prev) the cursor, wrapping around the ends.
        local buf = api.nvim_get_current_buf()
        local ms = {}
        for _, m in ipairs(vim.fn.getmarklist(buf)) do
            local letter = m.mark:sub(2)
            if letter:match("^%l$") then
                ms[#ms + 1] = { letter = letter, lnum = m.pos[2], col = m.pos[3] }
            end
        end
        if #ms == 0 then
            notify("no local marks in this buffer", vim.log.levels.WARN)
            return
        end
        table.sort(ms, function(a, b)
            return a.lnum < b.lnum or (a.lnum == b.lnum and a.col < b.col)
        end)
        local cur = api.nvim_win_get_cursor(0)
        local cl, cc = cur[1], cur[2] + 1
        local target
        if action == "next" then
            for _, m in ipairs(ms) do
                if m.lnum > cl or (m.lnum == cl and m.col > cc) then
                    target = m
                    break
                end
            end
            target = target or ms[1] -- wrap to the first
        else
            for i = #ms, 1, -1 do
                local m = ms[i]
                if m.lnum < cl or (m.lnum == cl and m.col < cc) then
                    target = m
                    break
                end
            end
            target = target or ms[#ms] -- wrap to the last
        end
        pcall(vim.cmd, "normal! g`" .. target.letter) -- a REAL jump (the jumplist gets the origin)
        return
    end
    notify(
        "unknown mark action (add-local|add-global|delete-local|delete-global|delete-locals|delete-globals|change-local|change-global|annotate-local|annotate-global|jump-local|jump-global|next|prev)",
        vim.log.levels.WARN
    )
end

--- The `:LvimVault jump <action>` handlers on the CURRENT window's jumplist: `clear` (confirms), or
--- `prune-above` / `prune-below` — drop the entries newer / older than the current jumplist position.
---@param action string?
function M.jump_command(action)
    local win = api.nvim_get_current_win()
    if action == "clear" then
        confirm_then("Clear the jumplist?", function()
            if jumps.clear(win) then
                notify("jumplist cleared")
                M.refresh()
            else
                notify("could not clear the jumplist", vim.log.levels.WARN)
            end
        end)
        return
    end
    if action == "prune-above" or action == "prune-below" then
        local list = jumps.collect(win)
        -- Anchor on the current jumplist position; when the cursor sits past the newest entry (no row is
        -- flagged `current`) fall back to the NEWEST entry, so the command always has a reference.
        local cur
        for _, e in ipairs(list) do
            if e.current then
                cur = e
                break
            end
        end
        cur = cur or list[1]
        if not cur then
            notify("the jumplist is empty", vim.log.levels.WARN)
            return
        end
        local dir = action == "prune-above" and "above" or "below"
        if jumps.prune(win, list, cur, dir) then
            notify(("pruned the jumps %s the current position"):format(dir == "above" and "newer than" or "older than"))
            M.refresh()
        else
            notify("could not prune the jumplist", vim.log.levels.WARN)
        end
        return
    end
    notify("unknown jump action (clear|prune-above|prune-below)", vim.log.levels.WARN)
end

--- The `:LvimVault macro <action> <name>` handlers — drive the macro bank from the editor. `save` banks the
--- last recorded register under the name (a GLOBAL macro — same as `:LvimVault save`), `play` replays the
--- named macro, `load` puts it in a register (`@<reg>` then replays it), `delete` removes it (confirms).
--- The name is matched across scopes, preferring the current project's macro over a global one.
---@param rest string?
function M.macro_command(rest)
    local action, name = (vim.trim(rest or "")):match("^(%S*)%s*(.-)$")
    action, name = action or "", vim.trim(name or "")
    if not MACRO_ACTIONS[action] then
        notify("unknown macro action (save|play|load|delete) — usage: macro <action> <name>", vim.log.levels.WARN)
        return
    end
    if name == "" then
        notify(("macro %s needs a <name>"):format(action), vim.log.levels.WARN)
        return
    end
    if action == "save" then
        -- create: bank the recorded register under the name (global) — shares M.save with `:LvimVault save`
        M.save(name)
        return
    end
    local mac
    for _, m in ipairs(macros.list("all")) do
        if m.name == name then
            if m.scope == "project" then
                mac = m
                break
            end
            mac = mac or m
        end
    end
    if not mac then
        notify(("no macro named '%s'"):format(name), vim.log.levels.WARN)
        return
    end
    if action == "play" then
        macros.play(mac, 1)
    elseif action == "load" then
        local ok, err = macros.load(mac)
        if ok then
            notify(("loaded '%s' into @%s"):format(name, mac.register or config.macros.default_register))
        else
            notify(err or "could not load the macro", vim.log.levels.WARN)
        end
    elseif action == "delete" then
        confirm_then(("Delete macro '%s'?"):format(name), function()
            if macros.delete(mac) then
                notify(("deleted macro '%s'"):format(name))
                M.refresh()
            else
                notify("could not delete the macro", vim.log.levels.WARN)
            end
        end)
    end
end

-- ── command + setup ──────────────────────────────────────────────────────────

--- Parse `:LvimVault` args: a layout token anywhere + a subcommand; `save`/`macro` consume the REST of the
--- tokens verbatim (names may contain spaces).
---@param args string
---@return string sub, string? layout, string? name
local function parse(args)
    local sub, layout = "marks", nil
    local rest = {}
    local greedy = false
    for _, tok in ipairs(vim.split(vim.trim(args), "%s+")) do
        if tok == "" then -- skip
        elseif greedy then
            rest[#rest + 1] = tok
        elseif LAYOUTS[tok] then
            layout = tok
        elseif SUBS[tok] then
            sub = tok
            greedy = tok == "save" or tok == "macro"
        else
            rest[#rest + 1] = tok
        end
    end
    return sub, layout, table.concat(rest, " ")
end

---@type boolean  one-time registration (command, highlights) done
local registered = false

--- Merge user options into the LIVE config (lvim-utils.utils.merge — in place, so every reader
--- sees the effective values) and register the command + self-themed highlights once.
---@param opts LvimVaultConfig|table|nil
function M.setup(opts)
    if opts then
        merge(config, opts)
    end
    if registered then
        return
    end
    registered = true
    hl.setup()
    hl.bind(highlights.build)
    api.nvim_create_user_command("LvimVault", function(cmd)
        local sub, layout, name = parse(cmd.args)
        if sub == "save" then
            M.save(name)
        elseif sub == "mark" then
            M.mark_command(name)
        elseif sub == "jump" then
            M.jump_command(name)
        elseif sub == "macro" then
            M.macro_command(name)
        else
            M.open(sub, layout)
        end
    end, {
        nargs = "*",
        desc = "lvim-vault: marks|jumps|macros / mark|jump|macro <action> / save <name> [float|area|bottom]",
        complete = function(_, line)
            -- after a singular subcommand, complete ITS actions; otherwise the tabs / layouts / verbs
            if line:match("%f[%w]mark%s+%S*$") then
                return vim.tbl_keys(MARK_ACTIONS)
            elseif line:match("%f[%w]jump%s+%S*$") then
                return vim.tbl_keys(JUMP_ACTIONS)
            elseif line:match("%f[%w]macro%s+%S*$") then
                return vim.tbl_keys(MACRO_ACTIONS)
            end
            return { "marks", "jumps", "macros", "mark", "jump", "macro", "save", "float", "area", "bottom" }
        end,
    })
    -- Disable the native `m`: the vault does NOT bind any mark keys of its own — you drive it through the
    -- `:LvimVault mark …` commands (map `m` as a prefix yourself, see the README). So `m` no longer sets a
    -- native mark under the vault's back (which would bypass the db); it is mapped to <Nop>, which frees it as
    -- a menu prefix and keeps every mark flowing through the vault. `disable_native = false` leaves `m` native.
    if config.marks.disable_native then
        vim.keymap.set("n", "m", "<Nop>", { desc = "lvim-vault: native mark set disabled (own `m` as a prefix)" })
    end
    -- Own recordings: a native `q<reg>…q` never touched the vault, so a just-recorded macro was invisible in
    -- the panel until an explicit save. When `macros.autobank` is on, bank it on RecordingLeave — a GLOBAL
    -- macro named after the register, upserted (a re-record replaces it). `vim.schedule` defers past the event
    -- so the register holds the finished recording; an open panel refreshes.
    if config.macros.autobank then
        api.nvim_create_autocmd("RecordingLeave", {
            group = api.nvim_create_augroup("LvimVaultAutobank", { clear = true }),
            desc = "lvim-vault: bank a finished recording into the panel",
            callback = function()
                local reg = vim.v.event.regname
                if type(reg) ~= "string" or not reg:match("^%l$") then
                    return
                end
                vim.schedule(function()
                    if macros.save(reg, reg, "global") then
                        M.refresh()
                    end
                end)
            end,
        })
    end
end

return M
