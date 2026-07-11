-- lvim-vault.config: the LIVE config table — `setup()` merges user opts into THIS table in place
-- (via lvim-utils.utils.merge), so every reader `require("lvim-vault.config")` sees the effective
-- values. Only options live here; runtime state stays in the modules that own it.
--
---@module "lvim-vault.config"

---@class LvimVaultMarksOpts
---@field annotations boolean    -- persist + show a per-mark user annotation (stored in the vault db)
---@field disable_native boolean -- kill the native `m` (map it to <Nop>) so `m` is free as YOUR own mark-menu prefix, and OWN the marks — the vault commands write the db FIRST then the native mark, so local marks persist across sessions / closed files. false = native `m` works as usual and marks bypass the db

---@class LvimVaultJumpsOpts
---@field dedupe boolean       -- collapse jumplist entries that land on the same buffer+line (keep the newest)

---@class LvimVaultMacrosOpts
---@field project_scope boolean    -- enable the per-project macro scope (the [p]roject filter)
---@field default_register string  -- fallback register for save/load when none was recorded/given
---@field autobank boolean         -- OWN recordings: when you finish `q<reg>…q`, bank it in the panel automatically (a GLOBAL macro named after the register, upserted) — so a native recording shows up without an explicit save

---@class LvimVaultIcons
---@field expand_closed string  -- collapsed-section caret (Nerd Font, single width)
---@field expand_open string    -- expanded-section caret (Nerd Font, single width)

---@class LvimVaultColors
---@field marks string         -- accent for LOCAL marks (a lvim-utils palette key like "blue", or a "#rrggbb")
---@field marks_global string  -- accent for GLOBAL marks
---@field jumps string         -- accent for jumps
---@field macros string        -- accent for macros

---@class LvimVaultConfig
---@field title string                    -- the panel's frame title
---@field title_pos "left"|"center"|"right" -- title alignment on the frame
---@field layout "float"|"area"|"bottom"  -- default panel layout (per-open `:LvimVault … <layout>` overrides)
---@field save string|nil                 -- db DIRECTORY; nil = stdpath("data")/lvim-vault
---@field preview boolean                 -- open the marks/jumps location preview panel alongside the list
---@field colors LvimVaultColors          -- per-collection accent (the badge box + the location/name text)
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
    -- Per-collection accent: colours the row's badge box AND its location/name text. Each value is a
    -- lvim-utils palette KEY ("blue" / "cyan" / "orange" / "magenta" / …) resolved from the live theme, or a
    -- literal "#rrggbb". Changing these re-tints on the next colorscheme / palette sync.
    colors = {
        marks = "blue",
        marks_global = "orange",
        jumps = "cyan",
        macros = "magenta",
    },
    icons = {
        expand_closed = "", -- nf-fa-caret_right (U+F0DA), single width
        expand_open = "", -- nf-fa-caret_down  (U+F0D7), single width
    },
    marks = {
        annotations = true,
        -- Disable the native `m` (the plugin maps it to <Nop>) so `m` becomes a free PREFIX you bind your own
        -- mark menu on (see the README — `mam`/`mdm`/`mDm`/`mcm` … calling `:LvimVault mark <action>`), and let
        -- the vault OWN the marks: its commands write the db FIRST then set the native mark, so local marks
        -- persist across sessions and show even for CLOSED files, kept in lockstep. `false` keeps native `m`.
        disable_native = true,
    },
    jumps = {
        dedupe = true,
    },
    macros = {
        project_scope = true,
        default_register = "q",
        -- Own recordings like the vault owns marks: finishing a native recording (`q<reg>…q`) banks it into
        -- the panel automatically — a GLOBAL macro named after its register (`a`, `q`, …), upserted so a
        -- re-record replaces it. So `qa…q` then `@a` also LEAVES a panel entry you can rename / keep. `false`
        -- = only explicit saves (`:LvimVault save` / panel `s`) bank a macro.
        autobank = true,
    },
}

return M
