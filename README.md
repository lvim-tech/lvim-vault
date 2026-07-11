# lvim-vault

An editor-state bank for Neovim: your **marks**, the window's **jumplist**, and a persistent
**macro bank** — three collections in ONE tabbed panel, with a live location preview and SQLite
persistence for the durable parts (named macros + per-mark annotations).

- **Marks** — local (`a-z`, the buffer you opened from) and global (`A-Z`) marks with the mark
  line's text and an optional persisted ANNOTATION. Jump, delete, move to another letter,
  annotate, clear local/global. The list is grouped into **Local** and **Global** sections.
- **Jumps** — the window's jumplist newest-first (deduped per buffer+line), a `➤` pointer on the
  current position. Travelling uses REAL `<C-o>`/`<C-i>` motions, so the jumplist position moves
  and a plain `<C-o>` afterwards continues naturally. Prune everything newer/older than a row,
  clear the list. Grouped into **This buffer** and **Other buffers** sections.
- **Macros** — bank the recorded register under a name, play it with a count, load it into a
  register (`@r` replays natively), **edit it as text** (termcodes are stored human-readable via
  `keytrans()` — `"ciwHELLO<Esc>"` — and materialised back with `nvim_replace_termcodes`, a
  verified identical round-trip), rename / delete / duplicate. Macros are **project**- or
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

- **`<CR>` on a mark or jump keeps the panel open** — it jumps in the editor above and leaves the
  dock in place, so you can return to it (`<C-w>` / your window keys) and pick another. (A `float`
  is trapped, so there `<CR>` closes then jumps; macros always close then play.)
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
    -- Default panel layout: "float" | "area" | "bottom" (a per-command token overrides,
    -- sticky for the session).
    layout = "area",
    -- Database DIRECTORY. nil = stdpath("data") .. "/lvim-vault".
    save = nil,
    -- Show the marks/jumps location preview panel beside the list.
    preview = true,
    icons = {
        -- Section fold carets (Nerd Font, single width).
        expand_closed = "", -- nf-fa-caret_right
        expand_open = "", -- nf-fa-caret_down
    },
    marks = {
        -- Persist + show a per-mark user annotation (stored in the vault db).
        annotations = true,
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
`LvimVaultSection` (the collapsible section headers), `LvimVaultEmpty`.

## Health

`:checkhealth lvim-vault` reports the sqlite backend, whether the db opened (path, schema
version, row counts) and validates the config.

## License

BSD 3-Clause — see [LICENSE](LICENSE).
