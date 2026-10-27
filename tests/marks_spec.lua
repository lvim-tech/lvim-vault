-- The marks collection, over live editor state.
--
-- The marks themselves are the editor's: only an optional annotation persists. So the collection
-- can be stated exactly -- set real marks in real buffers and ask. Three things are worth pinning
-- because every API involved disagrees about them:
--
--   * the position conventions. getmarklist hands back getpos-style columns (1-based);
--     nvim_buf_set_mark takes a 0-based one. An off-by-one here puts the cursor one character off
--     every jump;
--   * the ORDER: the local block first, then global; locals grouped by file; then by letter;
--   * `under_cursor`, whose rule is column-aware -- the first mark at or after the cursor column,
--     falling back to the nearest one to the LEFT once the cursor is past them all.
--
-- The annotation store needs sqlite.lua, which is not installed here, so those paths are off and
-- `collect` works from live marks alone.

local marks = require("lvim-vault.marks")
local store = require("lvim-vault.store")
local config = require("lvim-vault.config")

--- Forget every mark this suite could see, so one case cannot leak into the next.
local function no_marks()
    vim.cmd("silent! delmarks A-Z")
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(buf) then
            pcall(vim.api.nvim_buf_call, buf, function()
                vim.cmd("silent! delmarks a-z")
            end)
        end
    end
end

--- A named, loaded file buffer holding `lines`.
---@param name string
---@param lines string[]
---@return integer buf
local function file_buffer(name, lines)
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    local path = dir .. "/" .. name
    vim.fn.writefile(lines, path)
    vim.cmd("silent! edit " .. vim.fn.fnameescape(path))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    return buf
end

--- Entries of `collect()` described as "letter:kind".
---@return string[]
local function described()
    local out = {}
    for i, e in ipairs(marks.collect()) do
        out[i] = e.mark .. ":" .. e.kind
    end
    return out
end

describe("lvim-vault: collecting marks")

it("a local mark is collected with its position and its line", function()
    no_marks()
    local buf = file_buffer("subject.txt", { "first line", "second line", "third line" })
    vim.api.nvim_buf_set_mark(buf, "a", 2, 3, {})

    local found
    for _, e in ipairs(marks.collect()) do
        if e.mark == "a" then
            found = e
        end
    end
    truthy(found, "the mark was set but not collected")
    eq("local", found.kind)
    eq(buf, found.bufnr)
    eq(2, found.lnum)
    eq(4, found.col, "set_mark takes a 0-based column; the entry carries the getpos 1-based one")
    eq("second line", found.text, "the preview snippet is the mark's own line")
end)

it("a global mark is collected as global", function()
    no_marks()
    local buf = file_buffer("global.txt", { "alpha", "beta" })
    vim.api.nvim_buf_set_mark(buf, "G", 2, 0, {})

    local found
    for _, e in ipairs(marks.collect()) do
        if e.mark == "G" then
            found = e
        end
    end
    truthy(found)
    eq("global", found.kind)
    eq(2, found.lnum)
    eq("beta", found.text)
end)

it("only a-z and A-Z are marks; the editor's own punctuation marks are not", function()
    no_marks()
    local buf = file_buffer("punct.txt", { "one", "two" })
    vim.api.nvim_buf_set_mark(buf, "a", 1, 0, {})
    -- '"' and "." and "^" are the editor's automatic marks; getmarklist reports them too.
    for _, e in ipairs(marks.collect()) do
        truthy(e.mark:match("^%a$"), "collected a non-letter mark: " .. vim.inspect(e.mark))
    end
end)

it("the local block comes first, then global, each by letter", function()
    no_marks()
    local buf = file_buffer("order.txt", { "l1", "l2", "l3" })
    vim.api.nvim_buf_set_mark(buf, "b", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, "a", 2, 0, {})
    vim.api.nvim_buf_set_mark(buf, "Z", 3, 0, {})
    vim.api.nvim_buf_set_mark(buf, "B", 1, 0, {})

    eq({ "a:local", "b:local", "B:global", "Z:global" }, described())
end)

it("a project's local marks are grouped by file", function()
    no_marks()
    local first = file_buffer("aaa.txt", { "x" })
    vim.api.nvim_buf_set_mark(first, "z", 1, 0, {})
    local second = file_buffer("zzz.txt", { "y" })
    vim.api.nvim_buf_set_mark(second, "a", 1, 0, {})

    local files = {}
    for _, e in ipairs(marks.collect()) do
        if e.kind == "local" then
            files[#files + 1] = vim.fn.fnamemodify(e.file, ":t")
        end
    end
    eq(2, #files)
    truthy(files[1] < files[2], "grouped by file before letter: " .. vim.inspect(files))
end)

it("an unnamed scratch buffer contributes nothing", function()
    no_marks()
    vim.cmd("enew!")
    local scratch = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(scratch, 0, -1, false, { "x" })
    vim.api.nvim_buf_set_mark(scratch, "q", 1, 0, {})
    eq({}, described(), "a mark in a buffer with no file has nowhere to point")
end)

describe("lvim-vault: re-lettering a mark")

--- The collected entry for `letter`, or nil.
---@param letter string
---@return table|nil
local function entry_for(letter)
    for _, e in ipairs(marks.collect()) do
        if e.mark == letter then
            return e
        end
    end
end

it("a letter that is not a letter is refused", function()
    no_marks()
    local buf = file_buffer("reletter.txt", { "one", "two" })
    vim.api.nvim_buf_set_mark(buf, "a", 1, 0, {})
    local ok, err = marks.set_letter(entry_for("a"), "4")
    eq(false, ok)
    truthy(type(err) == "string" and err ~= "", "and the refusal says why")
end)

it("re-lettering to the same letter changes nothing and succeeds", function()
    no_marks()
    local buf = file_buffer("same.txt", { "one", "two" })
    vim.api.nvim_buf_set_mark(buf, "a", 2, 0, {})
    eq(true, (marks.set_letter(entry_for("a"), "a")))
    truthy(entry_for("a"), "the mark is still there")
end)

it("a local mark moves to another local letter, at the same position", function()
    no_marks()
    local buf = file_buffer("move.txt", { "one", "two", "three" })
    vim.api.nvim_buf_set_mark(buf, "a", 3, 2, {})

    eq(true, (marks.set_letter(entry_for("a"), "c")))
    eq(nil, entry_for("a"), "the old letter is gone, not duplicated")
    local moved = entry_for("c")
    truthy(moved)
    eq(3, moved.lnum)
    eq(3, moved.col, "the position travels with the letter")
end)

it("a global mark cannot become a local one", function()
    no_marks()
    local buf = file_buffer("globalonly.txt", { "one" })
    vim.api.nvim_buf_set_mark(buf, "G", 1, 0, {})
    local ok, err = marks.set_letter(entry_for("G"), "a")
    eq(false, ok)
    truthy(err and err:match("global"), tostring(err))
    truthy(entry_for("G"), "and the mark is left where it was")
end)

it("a global mark moves to another global letter", function()
    no_marks()
    local buf = file_buffer("globalmove.txt", { "one", "two" })
    vim.api.nvim_buf_set_mark(buf, "G", 2, 0, {})
    eq(true, (marks.set_letter(entry_for("G"), "H")))
    eq(nil, entry_for("G"))
    truthy(entry_for("H"))
end)

describe("lvim-vault: deleting marks")

it("a deleted mark is gone from the collection", function()
    no_marks()
    local buf = file_buffer("del.txt", { "one", "two" })
    vim.api.nvim_buf_set_mark(buf, "a", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, "b", 2, 0, {})

    marks.delete(entry_for("a"))
    eq(nil, entry_for("a"))
    truthy(entry_for("b"), "its neighbour is untouched")
end)

it("clearing one kind leaves the other", function()
    no_marks()
    local buf = file_buffer("clear.txt", { "one", "two" })
    vim.api.nvim_buf_set_mark(buf, "a", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, "A", 2, 0, {})

    marks.clear("local")
    eq(nil, entry_for("a"))
    truthy(entry_for("A"), "a global mark is not a local one")

    marks.clear("global")
    eq(nil, entry_for("A"))
end)

describe("lvim-vault: the mark under the cursor")

it("a mark on the cursor line is found", function()
    no_marks()
    local buf = file_buffer("under.txt", { "one", "two", "three" })
    vim.api.nvim_buf_set_mark(buf, "a", 2, 0, {})
    vim.api.nvim_win_set_cursor(0, { 2, 0 })

    local found = marks.under_cursor("local")
    truthy(found, "the cursor is on the mark's line")
    eq("a", found.mark)
end)

it("a mark on another line is not", function()
    no_marks()
    local buf = file_buffer("other.txt", { "one", "two", "three" })
    vim.api.nvim_buf_set_mark(buf, "a", 1, 0, {})
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    eq(nil, marks.under_cursor("local"), "the rule is the cursor LINE, deliberately")
end)

it("with several marks on one line the pick is column-aware", function()
    no_marks()
    local buf = file_buffer("cols.txt", { "abcdefghij" })
    vim.api.nvim_buf_set_mark(buf, "a", 1, 1, {}) -- column 2 (1-based)
    vim.api.nvim_buf_set_mark(buf, "b", 1, 5, {}) -- column 6

    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    eq("a", marks.under_cursor("local").mark, "the first mark at or after the cursor")

    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    eq("a", marks.under_cursor("local").mark, "a mark UNDER the cursor is the one returned")

    vim.api.nvim_win_set_cursor(0, { 1, 2 })
    eq("b", marks.under_cursor("local").mark, "moving right advances to the next mark ahead")

    vim.api.nvim_win_set_cursor(0, { 1, 9 })
    eq("b", marks.under_cursor("local").mark, "past them all, the nearest one to the LEFT")
end)

it("the scope decides which letters are considered", function()
    no_marks()
    local buf = file_buffer("scope.txt", { "one" })
    vim.api.nvim_buf_set_mark(buf, "a", 1, 0, {})
    vim.api.nvim_buf_set_mark(buf, "A", 1, 0, {})
    vim.api.nvim_win_set_cursor(0, { 1, 0 })

    eq("a", marks.under_cursor("local").mark)
    eq("A", marks.under_cursor("global").mark)
end)

describe("lvim-vault: the annotation store")

it("annotations need the store, and say so when it is missing", function()
    if store.available() then
        skip("the absent-store path", "sqlite.lua is installed here, so the store is available")
        return
    end
    eq(false, store.available())

    no_marks()
    local buf = file_buffer("annotated.txt", { "one" })
    vim.api.nvim_buf_set_mark(buf, "a", 1, 0, {})
    local e = entry_for("a")
    truthy(e, "the mark itself is live editor state and does not need the store")
    eq(nil, e.annotation, "and carries no annotation when there is nowhere to keep one")

    local was = config.marks.annotations
    config.marks.annotations = true
    local ok = pcall(marks.annotate, e, "a note")
    config.marks.annotations = was
    truthy(ok, "annotating without a store must decline, not raise")
end)
