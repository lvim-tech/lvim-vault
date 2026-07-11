-- lvim-vault: :checkhealth lvim-vault.
-- Diagnoses what makes the vault misbehave invisibly: the MANDATORY sqlite backend (the macro
-- bank + mark annotations ARE the plugin's data — no fallback), whether the db actually opened
-- (path, schema version, row counts), the lvim-ui / lvim-utils presence the panel is built on,
-- and a config sanity pass. Read-only reporting — never mutates config or state.
--
---@module "lvim-vault.health"

local config = require("lvim-vault.config")

local M = {}

--- Validate the live config table; error per violation, ok when clean.
---@param health table  the vim.health reporter
local function check_config(health)
    local problems = 0
    local layouts = { float = true, area = true, bottom = true }
    if not layouts[config.layout] then
        problems = problems + 1
        health.error(("config.layout '%s' is not one of float/area/bottom"):format(tostring(config.layout)))
    end
    if config.save ~= nil and type(config.save) ~= "string" then
        problems = problems + 1
        health.error("config.save must be nil or a directory path string")
    end
    local reg = config.macros.default_register
    if type(reg) ~= "string" or not reg:match("^%w$") then
        problems = problems + 1
        health.error(("config.macros.default_register '%s' is not a single register letter"):format(tostring(reg)))
    end
    if problems == 0 then
        health.ok("config valid")
    end
end

--- Run the health report.
function M.check()
    local health = vim.health
    health.start("lvim-vault")

    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim >= 0.10")
    else
        health.error("Neovim >= 0.10 is required (keytrans, vim.fs.root, getmarklist shapes)")
    end

    -- the ecosystem the panel is built on
    local ok_ui = pcall(require, "lvim-ui")
    local ok_utils = pcall(require, "lvim-utils.utils")
    if ok_ui and ok_utils then
        health.ok("lvim-ui + lvim-utils found (panel / store / palette)")
    else
        health.error("lvim-ui / lvim-utils not found — the vault panel cannot open")
    end

    -- sqlite.lua is MANDATORY here: the macro bank + mark annotations live in the vault db.
    local ok_store, store_lib = pcall(require, "lvim-utils.store")
    if ok_store then
        store_lib.health(health, true)
    end

    local ok_vstore, vstore = pcall(require, "lvim-vault.store")
    if ok_vstore and vstore.available() then
        if vstore.is_open() then
            health.ok("database open: " .. tostring(vstore.path()))
            health.info(("schema version %d"):format(vstore.schema_version()))
            local n_macros, n_notes = vstore.counts()
            health.info(("%d macro(s), %d mark annotation(s) stored"):format(n_macros, n_notes))
        else
            health.error("database did NOT open: " .. tostring(vstore.path()) .. " (directory not writable?)")
        end
    end

    check_config(health)

    if not config.marks.annotations then
        health.info("mark annotations are disabled (config.marks.annotations = false)")
    end
    if not config.preview then
        health.info("the marks/jumps location preview is disabled (config.preview = false)")
    end
end

return M
