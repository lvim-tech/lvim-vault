-- lvim-vault.store: SQLite persistence for the vault, through the shared lvim-utils.store wrapper
-- (backend = "sqlite", versioned via PRAGMA user_version — the set's persistence canon). ONLY the
-- durable data lives here: the macro bank and the per-mark annotations. The marks/jumplist
-- themselves are LIVE editor state and are never persisted. Project-scoped macros are a
-- `project_root` COLUMN in the same db (one db for everything under stdpath("data")/lvim-vault),
-- so nothing is ever written inside the user's repositories. Every mutation is a direct query —
-- no whole-file rewrites, atomic by nature.
--
---@module "lvim-vault.store"

local config = require("lvim-vault.config")

local M = {}

-- Bump TOGETHER with a matching `MIGRATIONS[<new version>]` step whenever the schema changes; a
-- fresh db is created at the current schema and stamped directly (no steps run).
---@type integer
local SCHEMA_VERSION = 1

---@type table<string, table>
local TABLES = {
    macros = {
        id = { "integer", primary = true, autoincrement = true },
        name = { "text", required = true },
        keys = { "text", required = true }, -- HUMAN-READABLE (keytrans()) — never raw termcode bytes
        register = { "text" }, -- the register the macro was banked from (a load-target hint)
        desc = { "text" },
        scope = { "text", required = true }, -- "project" | "global"
        project_root = { "text" }, -- set only for scope = "project"
        updated = { "integer" },
    },
    mark_annotations = {
        id = { "integer", primary = true, autoincrement = true },
        mark = { "text", required = true }, -- the mark letter (a-z / A-Z)
        file = { "text", required = true }, -- normalized absolute path (the annotation key's 2nd half)
        text = { "text" },
        updated = { "integer" },
    },
}

-- PRAGMA user_version steps: an existing db at version N runs MIGRATIONS[N+1..SCHEMA_VERSION] in
-- order (each `function(db) db:exec("ALTER TABLE …") end`). Empty at v1 — the seam is here for
-- every later schema change.
---@type table<integer, fun(db: table)>
local MIGRATIONS = {}

---@type table?  the live store handle (lazy singleton)
local handle

--- Whether the sqlite backend is available (sqlite.lua installed). The macros ARE the plugin's
--- data, so sqlite is MANDATORY — there is no JSON fallback.
---@return boolean
function M.available()
    return require("lvim-utils.store").available()
end

--- The (lazily opened) live store handle. `config.save` names the db DIRECTORY; the path is
--- normalised with vim.fs.normalize (never vim.fn.expand — the control-center globbing pitfall).
---@return table  the lvim-utils.store handle
function M.get()
    if handle then
        return handle
    end
    local dir = config.save or (vim.fn.stdpath("data") .. "/lvim-vault")
    handle = require("lvim-utils.store").new({
        backend = "sqlite",
        name = "lvim-vault",
        dir = vim.fs.normalize(dir),
        version = SCHEMA_VERSION,
        tables = TABLES,
        migrations = MIGRATIONS,
    })
    return handle
end

--- Whether the db actually opened (sqlite.lua present AND the file is writable).
---@return boolean
function M.is_open()
    return M.get():is_open()
end

--- The db file path (for :checkhealth).
---@return string?
function M.path()
    return M.get():path()
end

--- The on-disk schema version (PRAGMA user_version; for :checkhealth).
---@return integer
function M.schema_version()
    local rows = M.get():exec("PRAGMA user_version")
    if type(rows) == "table" and rows[1] and rows[1].user_version ~= nil then
        return tonumber(rows[1].user_version) or 0
    end
    return 0
end

--- Close the handle (tests / teardown).
function M.close()
    if handle then
        handle:close()
        handle = nil
    end
end

-- ── macros ───────────────────────────────────────────────────────────────────

---@class LvimVaultMacro
---@field id integer
---@field name string
---@field keys string          -- keytrans()-readable key text
---@field register string?     -- the source register (load-target hint)
---@field desc string?
---@field scope "project"|"global"
---@field project_root string? -- set only for scope = "project"
---@field updated integer      -- os.time() of the last write

--- All banked macros, newest-updated first. `root` narrows PROJECT rows to that project (global
--- rows always pass) — the caller filters project/global/all on top of this.
---@param root string?  the current project root (nil = keep every row)
---@return LvimVaultMacro[]
function M.macros(root)
    local rows = M.get():find("macros") or {}
    if type(rows) ~= "table" then
        return {}
    end
    local out = {}
    for _, r in ipairs(rows) do
        if r.scope ~= "project" or root == nil or r.project_root == root then
            out[#out + 1] = r
        end
    end
    table.sort(out, function(a, b)
        return (a.updated or 0) > (b.updated or 0)
    end)
    return out
end

--- Find one macro by name within a scope (+ project root for project scope).
---@param name string
---@param scope "project"|"global"
---@param root string?
---@return LvimVaultMacro?
function M.macro_find(name, scope, root)
    local rows = M.get():find("macros", { name = name, scope = scope })
    if type(rows) ~= "table" then
        return nil
    end
    for _, r in ipairs(rows) do
        if scope ~= "project" or r.project_root == root then
            return r
        end
    end
    return nil
end

--- Upsert a macro (the unique key is name + scope + project_root).
---@param mac { name: string, keys: string, register: string?, desc: string?, scope: "project"|"global", project_root: string? }
---@return boolean ok
function M.macro_save(mac)
    local s = M.get()
    local existing = M.macro_find(mac.name, mac.scope, mac.project_root)
    local row = {
        name = mac.name,
        keys = mac.keys,
        register = mac.register,
        desc = mac.desc,
        scope = mac.scope,
        project_root = mac.scope == "project" and mac.project_root or nil,
        updated = os.time(),
    }
    if existing then
        return s:update("macros", { id = existing.id }, row)
    end
    return s:insert("macros", row) ~= false
end

--- Update fields of an existing macro row by id.
---@param id integer
---@param set table  column → new value
---@return boolean ok
function M.macro_update(id, set)
    set.updated = os.time()
    return M.get():update("macros", { id = id }, set)
end

--- Delete a macro row by id.
---@param id integer
---@return boolean ok
function M.macro_delete(id)
    return M.get():remove("macros", { id = id })
end

--- Delete EVERY macro of a scope (project rows are additionally narrowed to `root`). Returns the
--- number removed.
---@param scope "project"|"global"
---@param root string?  the project root (required for scope = "project")
---@return integer removed
function M.macros_clear(scope, root)
    local s = M.get()
    local rows = s:find("macros", { scope = scope }) or {}
    local removed = 0
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            if scope ~= "project" or r.project_root == root then
                if s:remove("macros", { id = r.id }) then
                    removed = removed + 1
                end
            end
        end
    end
    return removed
end

-- ── mark annotations ─────────────────────────────────────────────────────────

--- Every stored annotation as a lookup map `"<mark>\0<file>" → text`.
---@return table<string, string>
function M.annotations()
    local rows = M.get():find("mark_annotations") or {}
    local out = {}
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            out[(r.mark or "") .. "\0" .. (r.file or "")] = r.text or ""
        end
    end
    return out
end

--- The annotation lookup key for a mark entry.
---@param mark string  the mark letter
---@param file string  normalized absolute path
---@return string
function M.annotation_key(mark, file)
    return mark .. "\0" .. file
end

--- Set / replace / clear one mark annotation (empty text deletes the row).
---@param mark string
---@param file string
---@param text string?
---@return boolean ok
function M.annotation_set(mark, file, text)
    local s = M.get()
    if text == nil or vim.trim(text) == "" then
        return s:remove("mark_annotations", { mark = mark, file = file })
    end
    local existing = s:find("mark_annotations", { mark = mark, file = file })
    if type(existing) == "table" and existing[1] then
        return s:update("mark_annotations", { id = existing[1].id }, { text = text, updated = os.time() })
    end
    return s:insert("mark_annotations", { mark = mark, file = file, text = text, updated = os.time() }) ~= false
end

--- Drop the annotation rows of marks that no longer exist — but only the ones we can PROVE are
--- gone. A row is removed iff `is_checkable(row)` is true AND its key is not in `live`. Rows the
--- caller cannot verify (e.g. a local mark of a file that is not loaded, so `getmarklist()` can't
--- enumerate it) are left untouched — otherwise a valid note would be lost on every panel open.
--- `is_checkable` defaults to "every row is checkable" (the old whole-db behaviour).
---@param live table<string, boolean>  the annotation keys of the CURRENTLY enumerable marks
---@param is_checkable? fun(row: table): boolean  whether this row's mark was actually enumerable
---@return integer removed
function M.annotations_prune(live, is_checkable)
    local s = M.get()
    local rows = s:find("mark_annotations") or {}
    local removed = 0
    if type(rows) == "table" then
        for _, r in ipairs(rows) do
            local checkable = is_checkable == nil or is_checkable(r)
            if checkable and not live[M.annotation_key(r.mark or "", r.file or "")] then
                if s:remove("mark_annotations", { id = r.id }) then
                    removed = removed + 1
                end
            end
        end
    end
    return removed
end

--- Row counts for :checkhealth.
---@return integer macros, integer annotations
function M.counts()
    local s = M.get()
    return s:count("macros"), s:count("mark_annotations")
end

return M
