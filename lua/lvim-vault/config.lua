-- lvim-vault.config: the LIVE config table — `setup()` merges user opts into THIS table in place
-- (via lvim-utils.utils.merge), so every reader `require("lvim-vault.config")` sees the effective
-- values. Only options live here; runtime state stays in the modules that own it.
--
---@module "lvim-vault.config"

---@class LvimVaultMarksOpts
---@field annotations boolean  -- persist + show a per-mark user annotation (stored in the vault db)

---@class LvimVaultJumpsOpts
---@field dedupe boolean       -- collapse jumplist entries that land on the same buffer+line (keep the newest)

---@class LvimVaultMacrosOpts
---@field project_scope boolean    -- enable the per-project macro scope (the [p]roject filter)
---@field default_register string  -- fallback register for save/load when none was recorded/given

---@class LvimVaultIcons
---@field expand_closed string  -- collapsed-section caret (Nerd Font, single width)
---@field expand_open string    -- expanded-section caret (Nerd Font, single width)

---@class LvimVaultConfig
---@field title string                    -- the panel's frame title
---@field title_pos "left"|"center"|"right" -- title alignment on the frame
---@field layout "float"|"area"|"bottom"  -- default panel layout (per-open `:LvimVault … <layout>` overrides)
---@field save string|nil                 -- db DIRECTORY; nil = stdpath("data")/lvim-vault
---@field preview boolean                 -- open the marks/jumps location preview panel alongside the list
---@field icons LvimVaultIcons            -- section fold carets
---@field marks LvimVaultMarksOpts
---@field jumps LvimVaultJumpsOpts
---@field macros LvimVaultMacrosOpts

---@type LvimVaultConfig
local M = {
    title = "Vault",
    title_pos = "center",
    layout = "area",
    save = nil,
    preview = true,
    icons = {
        expand_closed = "", -- nf-fa-caret_right (U+F0DA), single width
        expand_open = "", -- nf-fa-caret_down  (U+F0D7), single width
    },
    marks = {
        annotations = true,
    },
    jumps = {
        dedupe = true,
    },
    macros = {
        project_scope = true,
        default_register = "q",
    },
}

return M
