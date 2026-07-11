-- lvim-vault.highlights: the vault's badge / accent groups, self-themed from the lvim-utils
-- palette. One accent per collection (mark = blue, jump = cyan, macro = magenta), each badge a
-- tint of its accent toward the editor bg (the shared "mtint" convention), so the rows track the
-- live theme. build() is bound via lvim-utils.highlight.bind in setup(), re-derived on
-- ColorScheme / palette sync.
--
---@module "lvim-vault.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")
local config = require("lvim-vault.config")

local M = {}

--- Blend an accent toward the editor bg (the shared "mtint" convention).
---@param accent string
---@param t number
---@return string
local function mtint(accent, t)
    return hl.blend(accent, c.bg, t)
end

--- Resolve a `config.colors` value to a real colour: a palette KEY (`c[key]`, tracks the live theme) or,
--- when it is not a palette field, the value itself (a literal "#rrggbb").
---@param key string
---@return string
local function accent(key)
    return c[key] or key
end

--- The vault highlight groups from the live palette + `config.colors`.
---@return table<string, table>
function M.build()
    local col = config.colors
    local mark, mark_g = accent(col.marks), accent(col.marks_global)
    local jump, macro = accent(col.jumps), accent(col.macros)
    return {
        -- lead badges (the row's icon zone) — the per-collection accent from config.colors
        LvimVaultMarkBadge = { fg = mark, bg = mtint(mark, 0.3), bold = true },
        LvimVaultMarkGlobalBadge = { fg = mark_g, bg = mtint(mark_g, 0.3), bold = true },
        LvimVaultJumpBadge = { fg = jump, bg = mtint(jump, 0.2) },
        LvimVaultJumpCurrent = { fg = jump, bg = mtint(jump, 0.4), bold = true },
        LvimVaultMacroBadge = { fg = macro, bg = mtint(macro, 0.3), bold = true },
        -- location / name text (left column): the SAME accent fg as the row's badge, so the primary text
        -- reads in the collection's colour (the trailing snippet / keys stay in the neutral text/dim tone)
        LvimVaultMarkLoc = { fg = mark },
        LvimVaultMarkGlobalLoc = { fg = mark_g },
        LvimVaultJumpLoc = { fg = jump },
        LvimVaultMacroLoc = { fg = macro },
        -- row text zones
        LvimVaultText = { fg = c.fg },
        LvimVaultDim = { fg = mtint(c.fg, 0.6) },
        LvimVaultAnnotation = { fg = c.yellow, italic = true },
        LvimVaultScope = { fg = c.green },
        -- (collapsible section HEADERS — band + hover + accent label — come from the shared
        -- lvim-utils.highlight.section_accent via lvim-ui.section; nothing section-specific is defined here.)
        -- empty-state text
        LvimVaultEmpty = { fg = mtint(c.fg, 0.5), italic = true },
    }
end

return M
