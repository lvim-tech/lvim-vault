-- lvim-vault.jumps: the jumplist collection — model a window's jumplist newest-first (optionally
-- deduped per buffer+line), navigate it with REAL <C-o>/<C-i> motions (so the window's own
-- jumplist POSITION moves and plain <C-o> stays natural afterwards), and prune it.
--
-- Pruning: Neovim has no per-entry jumplist delete; the ONLY documented way to add an entry is
-- `m'` (:h jumplist). So prune = snapshot the kept locations, :clearjumps, then replay each with
-- `m'` inside the window (eventignore around the buffer hops, view restored) — the proper
-- mechanism, not a workaround.
--
-- getjumplist() conventions (kept explicit): entries are OLDEST-first `{ bufnr, lnum, col }` with
-- a 0-based col; the returned position `p` counts the entries BEHIND the cursor — raw index
-- `i <= p` is reachable with (p - i + 1) <C-o>, `i > p + 1` with (i - p - 1) <C-i>, and
-- `i == p + 1` IS the current position (the ➤ row).
--
---@module "lvim-vault.jumps"

local config = require("lvim-vault.config")

local api = vim.api

local M = {}

local CTRL_O = api.nvim_replace_termcodes("<C-o>", true, false, true)
local CTRL_I = api.nvim_replace_termcodes("<C-i>", true, false, true)

---@class LvimVaultJump
---@field raw_i integer   -- index in the raw (oldest-first) jumplist
---@field bufnr integer
---@field file string     -- normalized absolute path ("" for an unnamed buffer)
---@field lnum integer
---@field col integer     -- 1-based (preview convention)
---@field text string     -- the target line's text (preview snippet)
---@field back integer?   -- reachable with this many <C-o> (behind the position)
---@field fwd integer?    -- reachable with this many <C-i> (ahead of the position)
---@field current boolean -- the window's current jumplist position (the ➤ row)

--- The text of `lnum` in a jump target — live buffer lines when loaded, else read from disk.
---@param bufnr integer
---@param file string
---@param lnum integer
---@return string
local function line_text(bufnr, file, lnum)
    if api.nvim_buf_is_valid(bufnr) and api.nvim_buf_is_loaded(bufnr) then
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

--- Collect `win`'s jumplist NEWEST-first. Entries whose buffer no longer exists are dropped;
--- `config.jumps.dedupe` collapses same buffer+line entries keeping the newest occurrence.
---@param win integer
---@return LvimVaultJump[]
function M.collect(win)
    if not (win and api.nvim_win_is_valid(win)) then
        return {}
    end
    local jl = vim.fn.getjumplist(win)
    local raw, p = jl[1], jl[2]
    local out = {}
    local seen = {}
    for i = #raw, 1, -1 do
        local e = raw[i]
        if e.bufnr and api.nvim_buf_is_valid(e.bufnr) then
            local key = e.bufnr .. ":" .. e.lnum
            if not (config.jumps.dedupe and seen[key]) then
                seen[key] = true
                local file = vim.fs.normalize(api.nvim_buf_get_name(e.bufnr))
                out[#out + 1] = {
                    raw_i = i,
                    bufnr = e.bufnr,
                    file = file,
                    lnum = e.lnum,
                    col = (e.col or 0) + 1,
                    text = line_text(e.bufnr, file, e.lnum),
                    back = i <= p and (p - i + 1) or nil,
                    fwd = i > p + 1 and (i - p - 1) or nil,
                    current = i == p + 1,
                }
            end
        end
    end
    return out
end

--- Travel to a jumplist entry with REAL <C-o>/<C-i> motions in `win`, so the jumplist position
--- itself moves (a later plain <C-o> continues from there). The current entry is a no-op.
---@param entry LvimVaultJump
---@param win integer
---@return boolean ok
function M.jump(entry, win)
    if not (win and api.nvim_win_is_valid(win)) then
        return false
    end
    local count, key
    if entry.back then
        count, key = entry.back, CTRL_O
    elseif entry.fwd then
        count, key = entry.fwd, CTRL_I
    else
        return true -- already at the current position
    end
    api.nvim_set_current_win(win)
    return pcall(vim.cmd, "normal! " .. count .. key)
end

--- Rebuild `win`'s jumplist from `kept` (LvimVaultJump entries, any order — replayed oldest-first
--- by `raw_i`): :clearjumps, then one `m'` per kept location. Buffer hops run under
--- eventignore=all and the window's original buffer + view are restored. The position ends past
--- the newest entry (like a fresh jump history).
---@param win integer
---@param kept LvimVaultJump[]
---@return boolean ok
function M.rebuild(win, kept)
    if not (win and api.nvim_win_is_valid(win)) then
        return false
    end
    local ordered = {}
    for _, e in ipairs(kept) do
        ordered[#ordered + 1] = e
    end
    table.sort(ordered, function(a, b)
        return a.raw_i < b.raw_i
    end)
    local saved_ei = vim.o.eventignore
    local ok = pcall(api.nvim_win_call, win, function()
        local view = vim.fn.winsaveview()
        local orig = api.nvim_win_get_buf(win)
        vim.cmd("clearjumps")
        vim.o.eventignore = "all"
        for _, e in ipairs(ordered) do
            if api.nvim_buf_is_valid(e.bufnr) then
                vim.fn.bufload(e.bufnr)
                api.nvim_win_set_buf(win, e.bufnr)
                local last = api.nvim_buf_line_count(e.bufnr)
                pcall(api.nvim_win_set_cursor, win, { math.min(e.lnum, last), math.max(0, e.col - 1) })
                vim.cmd("normal! m'")
            end
        end
        api.nvim_win_set_buf(win, orig)
        vim.fn.winrestview(view)
    end)
    vim.o.eventignore = saved_ei
    return ok
end

--- Prune every entry STRICTLY NEWER (dir = "above", the rows above it in the newest-first list)
--- or STRICTLY OLDER (dir = "below") than `entry`, keeping the entry itself.
---@param win integer
---@param entries LvimVaultJump[]  the collected (displayed) list
---@param entry LvimVaultJump      the anchor row
---@param dir "above"|"below"
---@return boolean ok
function M.prune(win, entries, entry, dir)
    local kept = {}
    for _, e in ipairs(entries) do
        local newer = e.raw_i > entry.raw_i
        if e.raw_i == entry.raw_i or (dir == "above" and not newer) or (dir == "below" and newer) then
            kept[#kept + 1] = e
        end
    end
    return M.rebuild(win, kept)
end

--- Clear `win`'s jumplist entirely.
---@param win integer
---@return boolean ok
function M.clear(win)
    if not (win and api.nvim_win_is_valid(win)) then
        return false
    end
    return pcall(api.nvim_win_call, win, function()
        vim.cmd("clearjumps")
    end)
end

return M
