-- lvim-vault.rows: entry → ui.tabs row builders. The list is GROUPED into collapsible SECTIONS —
-- each section is a `type="action"` row with `children` (the form's native accordion: a caret from
-- config.icons, `<CR>`/`l`/`h`/click fold it, collapsed children hide). Every ENTRY child renders
-- through the same three-zone model (the installer's contract): a LEAD BADGE in the `icon` zone
-- (mark letter / jump distance / macro register — one accent per collection), the aligned text in
-- `label` (columns padded against the longest cell), and a trailing `suffix` zone (annotation /
-- scope). Each entry carries `_item` (the preview location — `{ filename, lnum, col }`, or {} for a
-- macro) so the form's on_move drives the live preview, and registers itself in the caller's
-- REGISTRY (row name → record) so the panel's per-row action keys resolve the entry under the
-- cursor. Names are namespaced per collection (mk_ / jp_ / mc_) — the tab-dispatch seam; a section
-- header is `<prefix>_sec_<id>`, an entry keeps its own name (never in the registry, so an action
-- key on a header is a no-op).
--
---@module "lvim-vault.rows"

local config = require("lvim-vault.config")

local M = {}

---@class LvimVaultRowRecord
---@field kind "mark"|"jump"|"macro"
---@field entry table            -- the collection entry (LvimVaultMark / LvimVaultJump / LvimVaultMacro)
---@field loc table              -- the preview item ({ filename, lnum, col } or {})

--- Truncate `s` to at most `n` CHARACTERS (not bytes), with a trailing ellipsis when clipped.
---@param s string
---@param n integer
---@return string
local function clip(s, n)
    if vim.fn.strchars(s) <= n then
        return s
    end
    return vim.fn.strcharpart(s, 0, n - 1) .. "…"
end

--- A file:lnum location cell ("init.lua:42"); "[No Name]:N" for an unnamed buffer.
---@param file string
---@param lnum integer
---@return string
local function loc_cell(file, lnum)
    local tail = file ~= "" and vim.fn.fnamemodify(file, ":t") or "[No Name]"
    return tail .. ":" .. lnum
end

--- The display width of the widest `file:lnum` cell over `entries`, capped at 28.
---@param entries table[]
---@return integer
function M.loc_width(entries)
    local w = 0
    for _, e in ipairs(entries) do
        w = math.max(w, vim.fn.strdisplaywidth(loc_cell(e.file, e.lnum)))
    end
    return math.min(math.max(w, 1), 28)
end

--- The display width of the widest macro NAME over `macs`, capped at 24.
---@param macs table[]
---@return integer
function M.name_width(macs)
    local w = 0
    for _, m in ipairs(macs) do
        w = math.max(w, vim.fn.strdisplaywidth(m.name or ""))
    end
    return math.min(math.max(w, 1), 24)
end

--- The raw badge CONTENT for one entry (before padding): the mark letter, the jump distance / ➤,
--- or the macro's `@register`.
---@param e table
---@param kind "mark"|"jump"|"macro"
---@return string
local function badge_content(e, kind)
    if kind == "mark" then
        return e.mark
    elseif kind == "jump" then
        return e.current and "➤" or tostring(e.back or e.fwd or 0)
    end
    return "@" .. (e.register or "?")
end

--- The MAX badge content display-width across a collection — every badge (entry rows AND section
--- header carets) is padded to this so the boxes are one width and the names/locations after them
--- start at the same column (mirrors loc_width / name_width).
---@param entries table[]
---@param kind "mark"|"jump"|"macro"
---@return integer
function M.badge_width(entries, kind)
    local w = 1
    for _, e in ipairs(entries) do
        w = math.max(w, vim.fn.strdisplaywidth(badge_content(e, kind)))
    end
    return w
end

--- A badge box: the content padded to display-width `w` (right-aligned for numeric jump distances,
--- left-aligned otherwise), wrapped in a space each side — so every badge is exactly `w + 2` wide.
---@param content string
---@param w integer
---@param right boolean  right-align the content inside the box
---@return string
local function badge(content, w, right)
    local gap = string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(content)))
    return " " .. (right and (gap .. content) or (content .. gap)) .. " "
end

--- A collapsible SECTION header row (the form accordion). The caret is the row's own `icon` — a
--- `badge()` box RIGHT-ALIGNED (like the jump distances below it) and coloured with the section's
--- `badge_hl` (the accent of its child badges), so the header's box matches the boxes below it.
--- `flat = true` suppresses the form's auto-caret; the children flatten under the header when
--- `expanded`.
---@param name string       -- "<prefix>_sec_<id>"
---@param label string      -- the section name (the count is appended)
---@param count integer     -- entries in this section (shown as "(N)")
---@param expanded boolean
---@param children table[]  -- the entry rows
---@param bw integer        -- the collection's badge content width (aligns the caret box to the badges)
---@param badge_hl string   -- the child badges' highlight group (colours the caret box)
---@return table row
function M.section(name, label, count, expanded, children, bw, badge_hl)
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true, -- sit at the same ~2-col left gutter as the entry rows
        icon = badge(expanded and config.icons.expand_open or config.icons.expand_closed, bw, true),
        icon_hl = badge_hl,
        label = ("%s (%d)"):format(label, count),
        text_hl = "LvimVaultSection",
        row_hl = "LvimVaultSection", -- a full-width solid band so the header stands apart from the multicoloured child rows
        expanded = expanded,
        children = children,
    }
end

--- One empty-state spacer row (namespaced so cursor-derived tab detection keeps working).
---@param prefix string  the collection namespace ("mk" / "jp" / "mc")
---@param text string
---@return table row
function M.empty(prefix, text)
    return { type = "spacer", name = prefix .. "_empty", label = text, hl = { inactive = "LvimVaultEmpty" } }
end

--- One MARK entry row. Badge = the mark letter (blue local / orange global); label = location +
--- line text — an ANNOTATED mark shows its ➤-led annotation INSTEAD of the snippet (the user's own
--- label out-ranks the code, and stays inside the list panel width).
---@param e LvimVaultMark
---@param registry table<string, LvimVaultRowRecord>
---@param on_pick fun(rec: LvimVaultRowRecord, close: fun(confirmed: boolean, result: any))
---@param locw integer
---@param bw integer  the uniform badge content width for this collection
---@return table row
function M.mark_row(e, registry, on_pick, locw, bw)
    local name = "mk_" .. e.kind .. "_" .. e.mark
    local rec = {
        kind = "mark",
        entry = e,
        loc = e.file ~= "" and { filename = e.file, lnum = e.lnum, col = e.col } or {},
    }
    registry[name] = rec
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = badge(e.mark, bw, false),
        icon_hl = e.kind == "local" and "LvimVaultMarkBadge" or "LvimVaultMarkGlobalBadge",
        label = (" %-" .. locw .. "s  %s"):format(
            clip(loc_cell(e.file, e.lnum), locw),
            e.annotation and "" or clip(vim.trim(e.text), 48)
        ),
        text_hl = "LvimVaultText",
        suffix = e.annotation and ("➤ " .. clip(e.annotation, 44)) or nil,
        suffix_hl = e.annotation and "LvimVaultAnnotation" or nil,
        _item = rec.loc,
        run = function(_, close)
            on_pick(rec, close)
        end,
    }
end

--- One JUMP entry row. Badge = the <C-o>/<C-i> distance; the CURRENT position carries the ➤ pointer.
---@param e LvimVaultJump
---@param registry table<string, LvimVaultRowRecord>
---@param on_pick fun(rec: LvimVaultRowRecord, close: fun(confirmed: boolean, result: any))
---@param locw integer
---@param bw integer  the uniform badge content width for this collection
---@return table row
function M.jump_row(e, registry, on_pick, locw, bw)
    local name = "jp_" .. e.raw_i
    local rec = {
        kind = "jump",
        entry = e,
        loc = e.file ~= "" and { filename = e.file, lnum = e.lnum, col = e.col } or {},
    }
    registry[name] = rec
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        -- right-aligned so 1/2/3-digit distances line up (and the ➤ pointer sits in the same box)
        icon = badge(badge_content(e, "jump"), bw, true),
        icon_hl = e.current and "LvimVaultJumpCurrent" or "LvimVaultJumpBadge",
        label = (" %-" .. locw .. "s  %s"):format(clip(loc_cell(e.file, e.lnum), locw), clip(vim.trim(e.text), 60)),
        text_hl = e.current and "LvimVaultText" or "LvimVaultDim",
        _item = rec.loc,
        run = function(_, close)
            on_pick(rec, close)
        end,
    }
end

--- One MACRO entry row. Badge = the source register (magenta); label = name + the keytrans'd keys;
--- suffix = the scope tag.
---@param m LvimVaultMacro
---@param registry table<string, LvimVaultRowRecord>
---@param on_pick fun(rec: LvimVaultRowRecord, close: fun(confirmed: boolean, result: any))
---@param namew integer
---@param bw integer  the uniform badge content width for this collection
---@return table row
function M.macro_row(m, registry, on_pick, namew, bw)
    local name = "mc_" .. m.id
    local rec = { kind = "macro", entry = m, loc = {} }
    registry[name] = rec
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = badge(badge_content(m, "macro"), bw, false),
        icon_hl = "LvimVaultMacroBadge",
        label = (" %-" .. namew .. "s  %s"):format(clip(m.name or "", namew), clip(m.keys or "", 48)),
        text_hl = "LvimVaultText",
        suffix = m.scope == "project" and "project" or "global",
        suffix_hl = m.scope == "project" and "LvimVaultScope" or "LvimVaultDim",
        _item = rec.loc,
        run = function(_, close)
            on_pick(rec, close)
        end,
    }
end

return M
