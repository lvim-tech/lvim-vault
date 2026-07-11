# lvim-vault

An editor-state bank for Neovim: your **marks**, the window's **jumplist**, and a persistent
**macro bank** — three collections in ONE tabbed panel, with a live location preview and SQLite
persistence for the durable parts (named macros + per-mark annotations).

- **Marks** — the vault OWNS the marks. By default it **disables the native `m`** (maps it to `<Nop>`)
  so `m` is free to become YOUR own mark-menu prefix, and every mark is set through the
  `:LvimVault mark …` commands, which write the db FIRST and then the native mark — so **local marks
  persist across sessions and show even for CLOSED files** (global `A-Z` marks are already all-projects
  via shada). Local (`a-z`) marks span every open project buffer plus the closed files' persisted rows;
  each shows the mark line's text (from the buffer, else read from disk) and an optional ANNOTATION.
  Add, jump, delete (one / all), move to another letter, annotate. Grouped into **Local** (by file)
  and **Global** sections. Set `marks.disable_native = false` to keep the native `m` and live-only marks.
- **Jumps** — the window's jumplist newest-first (deduped per buffer+line), a `➤` pointer on the
  current position. Travelling uses REAL `<C-o>`/`<C-i>` motions, so the jumplist position moves
  and a plain `<C-o>` afterwards continues naturally. Prune everything newer/older than a row,
  clear the list. Grouped into **This buffer** and **Other buffers** sections.
- **Macros** — the vault also OWNS your recordings: finish a native `q<reg>…q` and it is **banked
  automatically** into the panel (a global macro named after its register, upserted — so `qa…q` then
  `@a` also leaves an `a` entry you can keep; `macros.autobank = false` turns this off). Bank the
  recorded register under a name, play it with a count, load it into a register (`@r` replays
  natively), **edit it as text** (termcodes are stored human-readable via `keytrans()` —
  `"ciwHELLO<Esc>"` — and materialised back with `nvim_replace_termcodes`, a verified identical
  round-trip), rename / delete / duplicate. Macros are **project**- or
  **global**-scoped; project macros live in the same db keyed by the project root — nothing is
  ever written inside your repositories. Grouped into **Project** and **Global** sections.

Each tab's list is grouped into **collapsible sections** — a `<caret> <Name> (<count>)` header
that folds/unfolds on `<CR>` / `l` / `h` / click; the title counter shows shown/total entries. The
**clear / delete-all** actions live in the footer bar, per tab.

The marks/jumps tabs carry a PREVIEW panel (the real buffer, treesitter-highlighted, editable —
the lvim-picker preview contract): it follows the focused row, `<Tab>`/`<C-l>` move into it,
`<C-e>` hides it, `<C-n>`/`<C-p>` rotate its side.

## Requirements

- Neovim >= 0.10
- [lvim-utils](https://github.com/lvim-tech/lvim-utils) (store / palette / merge)
- [lvim-ui](https://github.com/lvim-tech/lvim-ui) (the tabs panel + preview)
- [sqlite.lua](https://github.com/kkharji/sqlite.lua) — **mandatory**: the macro bank and mark
  annotations ARE the plugin's data (there is no JSON fallback)

## Installation

### lvim-installer (recommended)

Install and manage it from the LVIM package manager — open the **Plugins** tab and install /
update / pin it:

```vim
:LvimInstaller plugins
```

lvim-installer installs plugins through Neovim's built-in `vim.pack`, so no external plugin
manager is needed.

### Native (vim.pack)

```lua
vim.pack.add({
    { src = "https://github.com/kkharji/sqlite.lua" },
    { src = "https://github.com/lvim-tech/lvim-utils" },
    { src = "https://github.com/lvim-tech/lvim-ui" },
    { src = "https://github.com/lvim-tech/lvim-vault" },
})
require("lvim-vault").setup({})
```

## Usage

```vim
:LvimVault                       " open the panel on the Marks tab
:LvimVault marks|jumps|macros    " open on a specific tab
:LvimVault jumps float           " a layout token (float|area|bottom) anywhere in the args;
                                 " a per-command layout is sticky for the session
:LvimVault save <name>           " bank the last recorded register as a GLOBAL macro,
                                 " without opening the panel (prompts when <name> is missing)
:LvimVault mark add-local        " add a local mark at the cursor (prompts for an a-z letter)
:LvimVault mark add-global       " add a global mark at the cursor (prompts for an A-Z letter)
:LvimVault mark delete-local     " delete the local mark on the cursor line
:LvimVault mark delete-global    " delete the global mark on the cursor line
:LvimVault mark delete-locals    " clear ALL local marks (a-z), db included (confirms first)
:LvimVault mark delete-globals   " clear ALL global marks (A-Z) (confirms first)
:LvimVault mark change-local     " re-letter the mark on the cursor line to a prompted a-z letter
:LvimVault mark change-global    " re-letter the global mark on the cursor line to a prompted A-Z letter
:LvimVault mark annotate-local   " annotate the local mark on the cursor line (empty clears)
:LvimVault mark annotate-global  " annotate the global mark on the cursor line
:LvimVault mark jump-local       " jump to a local mark by letter (prompts a-z; a REAL jump)
:LvimVault mark jump-global      " jump to a global mark by letter (prompts A-Z)
:LvimVault mark next|prev        " jump to the next / previous LOCAL mark in the buffer (wraps)
:LvimVault jump clear            " clear the current window's jumplist (confirms first)
:LvimVault jump prune-above      " drop the jumps NEWER than the current position
:LvimVault jump prune-below      " drop the jumps OLDER than the current position
:LvimVault macro save <name>     " bank the recorded register as a macro (alias of `save <name>`)
:LvimVault macro play <name>     " replay a banked macro by name
:LvimVault macro load <name>     " load a banked macro into its register (@<reg> replays it)
:LvimVault macro delete <name>   " delete a banked macro by name (confirms first)
```

The `mark` subcommands act on the **editor** (not the panel), so they work with no panel open. The
SINGULAR verbs (`delete-local` / `delete-global` / `change-local` / `change-global`) target the mark
on the CURSOR LINE — when the line holds several marks the pick is COLUMN-AWARE, the same mark the
statuscolumn shows: the first mark at or after the cursor column (a mark under the cursor is the one
acted on). Local scope scans the current buffer's own a-z marks; global scans the A-Z marks pointing
at the current file. The PLURAL verbs (`delete-locals` / `delete-globals`) clear a whole scope (db
included, confirming first — the same as the panel footer's `Clear local` / `Clear global`). An open
panel refreshes automatically after any of them.

### Your own `m` mark menu

With `marks.disable_native = true` (the default) the native `m` is turned off, so **you own `m`** as a
prefix. The plugin ships no default keymaps — bind the `mark` commands however you like. A tidy
`m<verb><scope>` scheme (`m` = local, `M` = global):

```lua
local map = vim.keymap.set
-- add
map("n", "mam", "<Cmd>LvimVault mark add-local<CR>", { desc = "Mark: add local" })
map("n", "maM", "<Cmd>LvimVault mark add-global<CR>", { desc = "Mark: add global" })
-- delete the mark on the cursor line
map("n", "mdm", "<Cmd>LvimVault mark delete-local<CR>", { desc = "Mark: delete local (line)" })
map("n", "mdM", "<Cmd>LvimVault mark delete-global<CR>", { desc = "Mark: delete global (line)" })
-- delete ALL
map("n", "mDm", "<Cmd>LvimVault mark delete-locals<CR>", { desc = "Mark: delete all local" })
map("n", "mDM", "<Cmd>LvimVault mark delete-globals<CR>", { desc = "Mark: delete all global" })
-- change (re-letter) the mark on the cursor line
map("n", "mcm", "<Cmd>LvimVault mark change-local<CR>", { desc = "Mark: change local (line)" })
map("n", "mcM", "<Cmd>LvimVault mark change-global<CR>", { desc = "Mark: change global (line)" })
-- annotate the mark on the cursor line
map("n", "mnm", "<Cmd>LvimVault mark annotate-local<CR>", { desc = "Mark: annotate local (line)" })
map("n", "mnM", "<Cmd>LvimVault mark annotate-global<CR>", { desc = "Mark: annotate global (line)" })
-- jump to a mark by letter
map("n", "mgm", "<Cmd>LvimVault mark jump-local<CR>", { desc = "Mark: jump local by letter" })
map("n", "mgM", "<Cmd>LvimVault mark jump-global<CR>", { desc = "Mark: jump global by letter" })
-- next / previous local mark in the buffer
map("n", "m]", "<Cmd>LvimVault mark next<CR>", { desc = "Mark: next (buffer)" })
map("n", "m[", "<Cmd>LvimVault mark prev<CR>", { desc = "Mark: prev (buffer)" })
```

### Panel keys

Navigation is the canonical lvim-ui set: `j`/`k` move, `h`/`l` switch tabs (or fold/unfold the
section header under the cursor), `<CR>` runs the focused row, `<C-j>`/`<C-k>` move between sectors
(list · footer), `<Tab>`/`<C-l>`/`<C-h>` move between the list and the preview, `<C-e>` hides the
preview, `<C-n>`/`<C-p>` rotate its side, `q`/`<Esc>` close.

On a **section header**, `<CR>` / `l` / `h` / a mouse click folds or unfolds that section (a
collapsed section hides its entries; the collapse state is kept for the session). The keys below
act on **entry** rows.

| Key | Where | Action |
| --- | --- | --- |
| `<CR>` | marks / jumps | jump to the mark / travel the jumplist (a REAL jump — `<C-o>` returns) |
| `<CR>` | macros | play the macro; takes a count (`3<CR>` replays 3×) |
| `d` | marks / macros | delete the mark / the macro (macros confirm first) |
| `a` | marks | annotate the mark (empty input clears; persisted in the vault db) |
| `m` | marks | move the mark to another letter (uppercase = global) |
| `<` / `>` | jumps | prune every entry newer / older than the focused row |
| `s` | any tab | save the recorded register as a macro (scope = the section the cursor is in) |
| `e` | macros | edit the macro as text (`<Esc>`-style notation in, termcodes out) |
| `r` | macros | load the macro into a register |
| `n` | macros | rename the macro |
| `c` | macros | duplicate the macro |

The **clear / delete-all** actions are in the FOOTER bar, per tab (each confirms first): Marks —
`Clear local` (`L`) / `Clear global` (`G`); Jumps — `Clear jumplist` (`C`); Macros —
`Clear project` (`P`) / `Clear global` (`G`). Reach them by their hotkey, by `<C-j>` to the footer
sector + `h`/`l` + `<CR>`, or by clicking. The hotkeys are CAPITALS (the letters freed by the
grouped-section redesign) so they never clash with the lowercase entry-action keys.

### Docked panel (`area` / `bottom`)

A docked panel is not modal — the editor stays live beside it, so it behaves differently from a
`float`:

- **`<CR>` keeps the panel open** — a mark/jump jumps in the editor above and a macro plays into it
  (the play happens in the opener window, not the panel), leaving the dock in place so you can return
  to it (`<C-w>` / your window keys) and pick / replay another. (A `float` is trapped, so there `<CR>`
  closes then performs.)
- **The list stays in sync with the editor** — deleting a mark (`:delmarks`), overwriting it, or
  adding one in the editor is reflected in the open panel automatically (on the next cursor move),
  with no panel action. Mutations made from the panel emit `User LvimVaultMark{Delete,Set,Change,Annotate}`
  autocmds, which any consumer can also listen to.

Stale annotations are cleaned up on panel open — but only for marks the panel can PROVE are gone
(global marks, and the opened buffer's own local marks). A local-mark note for a file that is not
loaded is never dropped.

## Setup

`setup()` merges your options into the live config in place — every reader sees the effective
values, and it is optional (the defaults below work as-is). The full default config:

```lua
require("lvim-vault").setup({
    -- The panel's frame title + its alignment ("left" | "center" | "right").
    title = "Vault",
    title_pos = "center",
    -- Default panel layout: "float" | "area" | "bottom" (a per-command token overrides,
    -- sticky for the session).
    layout = "area",
    -- Database DIRECTORY. nil = stdpath("data") .. "/lvim-vault".
    save = nil,
    -- Show the marks/jumps location preview panel beside the list.
    preview = true,
    -- Per-collection accent: colours the row's badge box AND its location/name text. Each value is a
    -- lvim-utils palette KEY ("blue"/"cyan"/"orange"/"magenta"/…) resolved from the live theme, or a
    -- literal "#rrggbb".
    colors = {
        marks = "blue",
        marks_global = "orange",
        jumps = "cyan",
        macros = "magenta",
    },
    icons = {
        -- Section fold carets (Nerd Font, single width).
        expand_closed = "", -- nf-fa-caret_right
        expand_open = "", -- nf-fa-caret_down
    },
    marks = {
        -- Persist + show a per-mark user annotation (stored in the vault db).
        annotations = true,
        -- Disable the native `m` (the plugin maps it to <Nop>) so `m` is free to become your own mark-menu
        -- prefix (see "Your own `m` mark menu"), and let the vault OWN the marks: its commands write the db
        -- FIRST then set the native mark, so LOCAL marks survive across sessions and show even for CLOSED
        -- files, kept in lockstep. `false` keeps the native `m` and marks then bypass the db.
        disable_native = true,
    },
    jumps = {
        -- Collapse jumplist entries that land on the same buffer+line (keep the newest).
        dedupe = true,
    },
    macros = {
        -- Enable the per-project macro scope (the Project section + its Clear).
        project_scope = true,
        -- Fallback register for save/load when none was recorded/given.
        default_register = "q",
        -- Bank a finished native recording (`q<reg>…q`) into the panel automatically — a GLOBAL macro
        -- named after its register, upserted (a re-record replaces it). false = explicit saves only.
        autobank = true,
    },
})
```

## Persistence

One SQLite database at `stdpath("data")/lvim-vault/lvim-vault.db` (through the shared
`lvim-utils.store` wrapper, versioned via `PRAGMA user_version`):

- `macros(name, keys, register, desc, scope, project_root, updated)` — the macro bank. `keys`
  is human-readable `keytrans()` notation; project-scoped rows carry the project root (the
  nearest `.git` ancestor of the cwd, else the cwd).
- `mark_annotations(mark, file, text, updated)` — the per-mark annotations, pruned automatically
  when their marks are deleted/cleared.

The marks and the jumplist themselves are LIVE editor state — they are never persisted.

## Highlights

Self-themed from the lvim-utils palette (re-derived on `ColorScheme` / palette sync):
`LvimVaultMarkBadge`, `LvimVaultMarkGlobalBadge`, `LvimVaultJumpBadge`, `LvimVaultJumpCurrent`,
`LvimVaultMacroBadge`, `LvimVaultText`, `LvimVaultDim`, `LvimVaultAnnotation`, `LvimVaultScope`,
`LvimVaultSection` (the collapsible section-header text), `LvimVaultEmpty`, and the section-header
BANDS `LvimVault{Mark,MarkGlobal,Jump,Macro}Band{,Hover}` — the full-width row bg tinted with the
section's caret-box accent (0.1 at rest, 0.2 while the cursor hovers the header).

## Health

`:checkhealth lvim-vault` reports the sqlite backend, whether the db opened (path, schema
version, row counts) and validates the config.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
