-- lvim-vault.macros: the macro bank (the macrobank half) — bank a register's recording under a
-- name, play it (with count), load it back into a register, and edit it as TEXT.
--
-- Encoding is the whole trick and lives in exactly two seams:
--   • STORE: `vim.fn.keytrans(raw)` — the register's raw bytes become human-readable notation
--     ("ihello<Esc>", a literal "<" becomes "<lt>"), safe to show, edit and persist as TEXT.
--   • MATERIALISE: `nvim_replace_termcodes(text, true, true, true)` — the exact inverse (do_lt
--     handles the "<lt>" case), used on play and on load-into-register. Round-trip verified.
--
-- Playback goes through `nvim_feedkeys(raw:rep(count), "m", false)` — remapped like a real `@`
-- replay (a macro that triggers mappings must keep triggering them), repeated `count` times.
--
---@module "lvim-vault.macros"

local config = require("lvim-vault.config")
local store = require("lvim-vault.store")

local M = {}

--- The current project root: the nearest `.git` ancestor of the cwd, else the cwd itself —
--- normalized, so it matches the stored `project_root` column byte-for-byte.
---@return string
function M.project_root()
    local root = vim.fs.root(0, ".git") or vim.fn.getcwd()
    return vim.fs.normalize(root)
end

--- Human-readable notation of a register's raw bytes.
---@param raw string
---@return string
function M.to_text(raw)
    return vim.fn.keytrans(raw)
end

--- Raw bytes of the human-readable notation (the keytrans inverse).
---@param text string
---@return string
function M.to_keys(text)
    return vim.api.nvim_replace_termcodes(text, true, true, true)
end

--- The register a plain `save` banks: the last RECORDED register when there is one, else the
--- configured default.
---@return string
function M.source_register()
    local rec = vim.fn.reg_recorded()
    if rec ~= "" then
        return rec
    end
    return config.macros.default_register
end

--- Banked macros for a scope filter, newest-updated first.
---@param filter "project"|"global"|"all"
---@return LvimVaultMacro[]
function M.list(filter)
    if not store.available() then
        return {}
    end
    local rows = store.macros(M.project_root())
    if filter == "all" then
        return rows
    end
    local out = {}
    for _, r in ipairs(rows) do
        if r.scope == filter then
            out[#out + 1] = r
        end
    end
    return out
end

--- Bank `register`'s current content under `name` (upsert: an existing name in the same scope is
--- replaced). Project scope requires `config.macros.project_scope`; it degrades to global.
---@param name string
---@param register string?  nil = the last recorded register / the configured default
---@param scope "project"|"global"|nil  default "global"
---@return boolean ok, string? err
function M.save(name, register, scope)
    if not store.available() then
        return false, "sqlite.lua not found — the macro bank is unavailable"
    end
    name = vim.trim(name or "")
    if name == "" then
        return false, "macro name is empty"
    end
    local reg = register or M.source_register()
    if not reg:match('^[%w"]$') then
        return false, "invalid register: " .. reg
    end
    local raw = vim.fn.getreg(reg)
    if raw == "" then
        return false, "register @" .. reg .. " is empty — record a macro first"
    end
    if scope == "project" and not config.macros.project_scope then
        scope = "global"
    end
    local ok = store.macro_save({
        name = name,
        keys = M.to_text(raw),
        register = reg,
        scope = scope or "global",
        project_root = scope == "project" and M.project_root() or nil,
    })
    if not ok then
        return false, "could not write the macro"
    end
    return true, nil
end

--- Replay a banked macro `count` times (feedkeys, remapped — real `@` semantics).
---@param mac LvimVaultMacro
---@param count integer?  default 1
function M.play(mac, count)
    local raw = M.to_keys(mac.keys or "")
    if raw == "" then
        return
    end
    vim.api.nvim_feedkeys(raw:rep(math.max(1, count or 1)), "m", false)
end

--- Load a banked macro into a register (so `@<reg>` replays it natively).
---@param mac LvimVaultMacro
---@param register string?  nil = the macro's own source register, else the configured default
---@return boolean ok, string? err
function M.load(mac, register)
    local reg = register or mac.register or config.macros.default_register
    if not reg:match('^[%w"]$') then -- accept `"` too (save allows it, so its own stored hint must load)
        return false, "invalid register: " .. tostring(reg)
    end
    vim.fn.setreg(reg, M.to_keys(mac.keys or ""))
    return true, nil
end

--- Replace a macro's KEYS from edited human-readable text.
---@param mac LvimVaultMacro
---@param text string
---@return boolean ok, string? err
function M.edit(mac, text)
    text = text or ""
    if vim.trim(text) == "" then
        return false, "macro text is empty"
    end
    -- normalise through a round-trip so what is stored is canonical keytrans notation
    return store.macro_update(mac.id, { keys = M.to_text(M.to_keys(text)) }), nil
end

--- Rename a macro (the name must stay unique within its scope).
---@param mac LvimVaultMacro
---@param name string
---@return boolean ok, string? err
function M.rename(mac, name)
    name = vim.trim(name or "")
    if name == "" then
        return false, "macro name is empty"
    end
    local clash = store.macro_find(name, mac.scope, mac.project_root)
    if clash and clash.id ~= mac.id then
        return false, ("a %s macro named '%s' already exists"):format(mac.scope, name)
    end
    return store.macro_update(mac.id, { name = name }), nil
end

--- Delete a macro.
---@param mac LvimVaultMacro
---@return boolean ok
function M.delete(mac)
    return store.macro_delete(mac.id)
end

--- Delete EVERY macro of a scope (the footer "Clear project" / "Clear global"). Project scope is
--- narrowed to the current project root. Returns the number removed.
---@param scope "project"|"global"
---@return integer removed
function M.clear_scope(scope)
    if not store.available() then
        return 0
    end
    return store.macros_clear(scope, scope == "project" and M.project_root() or nil)
end

--- Duplicate a macro as "<name> copy[ n]" in the same scope.
---@param mac LvimVaultMacro
---@return boolean ok, string? err
function M.duplicate(mac)
    local base = (mac.name or "macro") .. " copy"
    local name = base
    local n = 1
    while store.macro_find(name, mac.scope, mac.project_root) do
        n = n + 1
        name = base .. " " .. n
    end
    local ok = store.macro_save({
        name = name,
        keys = mac.keys,
        register = mac.register,
        desc = mac.desc,
        scope = mac.scope,
        project_root = mac.project_root,
    })
    if not ok then
        return false, "could not write the macro"
    end
    return true, nil
end

return M
