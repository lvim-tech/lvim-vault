-- lvim-vault.highlights: the vault's badge / accent groups, self-themed from the lvim-utils
-- palette. One accent per collection (mark = blue, jump = cyan, macro = magenta), each badge a
-- tint of its accent toward the editor bg (the shared "mtint" convention), so the rows track the
-- live theme. build() is bound via lvim-utils.highlight.bind in setup(), re-derived on
-- ColorScheme / palette sync.
--
---@module "lvim-vault.highlights"

local c = require("lvim-utils.colors")
local hl = require("lvim-utils.highlight")

local M = {}

--- Blend an accent toward the editor bg (the shared "mtint" convention).
---@param accent string
---@param t number
---@return string
local function mtint(accent, t)
    return hl.blend(accent, c.bg, t)
end

--- The vault highlight groups from the live palette.
---@return table<string, table>
function M.build()
    return {
        -- lead badges (the row's icon zone)
        LvimVaultMarkBadge = { fg = c.blue, bg = mtint(c.blue, 0.3), bold = true },
        LvimVaultMarkGlobalBadge = { fg = c.orange, bg = mtint(c.orange, 0.3), bold = true },
        LvimVaultJumpBadge = { fg = c.cyan, bg = mtint(c.cyan, 0.2) },
        LvimVaultJumpCurrent = { fg = c.cyan, bg = mtint(c.cyan, 0.4), bold = true },
        LvimVaultMacroBadge = { fg = c.magenta, bg = mtint(c.magenta, 0.3), bold = true },
        -- row text zones
        LvimVaultText = { fg = c.fg },
        LvimVaultDim = { fg = mtint(c.fg, 0.6) },
        LvimVaultAnnotation = { fg = c.yellow, italic = true },
        LvimVaultScope = { fg = c.green },
        -- collapsible section header (caret + name + count): a bold fg on a subtle full-width bg band
        -- (a faint blue tint toward bg) so the whole header line reads as one solid colour, set apart
        -- from the multicoloured child rows
        LvimVaultSection = { fg = mtint(c.fg, 0.9), bg = mtint(c.blue, 0.12), bold = true },
        -- empty-state / section text
        LvimVaultEmpty = { fg = mtint(c.fg, 0.5), italic = true },
    }
end

return M
