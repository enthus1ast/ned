# Vim mode, other key bindings, and zen mode

ned's keys are VS Code's by default ([Key bindings](keys.md)). *Key bindings: default · vim · emacs · helix…*
(File › Preferences, or the palette) switches to vim's, Emacs's or Helix's (`editor.keymap`); the menus, the
palette (Ctrl+E) and the mouse work the same in all of them.

## Vim

`"editor.vimMode": true`, or **View › Vim mode**. The status bar shows the mode; the cursor's shape follows it.

**Modes**: normal, insert, visual, visual-line and replace.

**Moving**: `h j k l`, `w b e` and `W B E`, `0 ^ $`, `gg G`, `{ }`, `%`, `H M L`, `f t F T` with `; ,` — all with
counts (`3w`, `5j`).

**Operators** `d c y > < gu gU gc` take a motion or a text object (`iw aw`, `i( a(`, `i" a"`, `i{ a{`, `ip ap`
— a paragraph, as whole lines …): `dw`, `ci"`, `yap`, `>ip`, `gUiw`; `vip` selects the paragraph's lines. Also `x X s S C D Y p P J r R ~`, `.` (repeat), `u` and Ctrl+R (undo, redo),
and `g-` `g+`, which go back and forth in time across the [undo tree](editing.md#undo)'s branches.

**vim-surround**: `ys{motion}{char}`, `yss{char}`, `cs{old}{new}`, `ds{char}`, and `S{char}` in visual mode — `t` or
`<` for an HTML tag.

**Search**: `/` and `?`, `n N`, `* #`. **Scrolling and folds**: `zz zt zb`, `za zc zo zM zR`. **Macros**: `q{a-z}`
records, `q` stops, `@{a-z}` plays, `@@` again — the same macros as Edit › Macros. `K` shows the hover.

**Ex commands**:

| | |
|---|---|
| `:w` `:q` `:q!` `:wq` `:x` `:wa` `:qa` `:wqa` | write, quit — one file or all |
| `:e file` · `:bn` `:bp` · `:bd` | open a file · the next and previous tab · close it |
| `:s/a/b/g` · `:%s/a/b/g` · `:'<,'>s/…/` | replace on the line · in the file · in the selection |
| `:!cmd` · `:%!sort` · `:'<,'>!cmd` · `:N,M!cmd` | run a command (`%` is the file) · put lines through one |
| `:sp` · `:vs` · `:only` | split the editor (above and below · side by side) · back to one pane |
| `:set wrap` `nowrap` `nu` `rnu` `nonu` `list` `nolist` · `:noh` | options · clear the search highlight |
| `:term` · `:make` · `:run` · `:zen` | the terminal · build · run · zen mode |
| `:N` | go to line N |

Plugins can add their own mappings, operators, text objects and ex commands ([Plugins](../plugins/README.md)) —
the *commentary* example adds `gc` with every motion, an `ie` text object and `:Comment`. Several of
[ned's own plugins](../plugins/available.md) are for vim: **which-key** shows what may follow a key that waits
(`g`, `z`, `d`, `<leader>` …) in a box you can tap; **dial** (Ctrl+A / Ctrl+X), **case-change** (`crs` …),
**split-join** (`gS` `gJ`), **text-objects** (`ia` `ii` `iq` …), **exchange** (`cx`), **align** (`ga`),
**harpoon** (`<leader>a`, `<leader>1` …) and **oil** (`<leader>-`). A plugin's operator takes every motion, `gg`
and `f{char}` too.

| setting | default | |
|---|---|---|
| `editor.vimMode` | `false` | vim keys |
| `vim.escapeSequence` | `""` | two keys typed quickly in insert mode that act as Esc, e.g. `"jk"` |
| `vim.useSystemClipboard` | `true` | `y`, `d` and `p` use the system clipboard |
| `vim.relativeNumbers` | `false` | relative line numbers while vim mode is on |

## Emacs

`"editor.keymap": "emacs"`: `C-f C-b C-n C-p`, `C-a C-e`, `M-f M-b`, `C-v M-v`, `M-< M->`; `C-k` (again: adds to
the same kill), `C-w M-w C-y`; `C-SPC` sets the mark, `C-g` quits; `C-s` searches, `M-%` replaces; `C-/` undoes;
`C-l C-o C-t`, `M-u M-l M-c`, `M-;` comments, `M-/` completes, `M-x` is the palette, `M-g g` goes to a line;
`C-x C-s` / `C-f` / `C-w` / `C-c` / `C-x`, and `C-x b` / `k` / `u` / `h` / `o` / `1` / `2` / `3`. The status bar
shows a prefix you have started (`C-x-`) and when the mark is set.

## Helix

`"editor.keymap": "helix"` — select first, then act: `h j k l`, `w b e W B E`, `x` selects the line, `%` all, `v`
extends, `;` collapses, `,` keeps one cursor, `C` adds a cursor below; `d c y p P`, `i a I A o O`, `u U`, `r<c>`,
`~`, `> <`, `J`; `/ ? n N *`; `g` goes (`g e h l s d r y i n p`), space opens the space menu (`f b s S / k a r c y p
d ?`), and `:w :q`.

## Zen mode

**Alt+Z** (View › Zen mode, or `:zen` in vim): the menus, tabs, docks and status bar go away, the text is a centred
column, and the block or paragraph you are in stays bright while the rest is dimmed — for writing, or reading code
without distractions. **Esc Esc** leaves (in vim mode Esc belongs to vim: leave with Alt+Z or `:zen`; the corner
shows the vim mode).

| setting | default | |
|---|---|---|
| `zen.width` | `90` | the column's width |
| `zen.hideLineNumbers` | `true` | no line numbers or gutter |
| `zen.dimOthers` | `true` | dim all but the block or paragraph you are in |
| `zen.typewriter` | `false` | typewriter scrolling: the cursor's line stays in the middle of the screen |
| `zen.gitChanges` | `false` | git's change marks in the gutter, in zen mode too |
| `zen.showInfo` | `true` | a quiet line and word count in the corner |
