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

**The `:` line** runs every command of ned by its name, in any case, or by enough of its start to be the only
one (`:about`, `:git: commit`), and reaches every setting with `:set`. **Tab** completes command names, settings
and their values, themes, files and tabs; Tab again steps through the choices. `:help` lists all of it in a tab;
`:help editor.tabSize` or `:help Sort lines` says what one is.

| | |
|---|---|
| `:w` `:w file` `:up` `:sav file` | save · save as · save if changed · save under another name |
| `:q` `:q!` `:wq` `:x` `:wa` `:qa` `:wqa` | write, quit — one file or all |
| `:e file` · `:e!` · `:r file` | open a file · read it from disk again · put a file's lines below the cursor |
| `:tabnew [file]` `:tabn` `:tabp` `:tabc` · `:bn` `:bp` `:bd` | tabs |
| `:ls` · `:b 3` · `:b name` | the tabs · the third · the one whose name starts with (or has) that |
| `:sp` · `:vs` · `:new` `:vnew` · `:only` | split the editor (above and below · side by side) · with a new file · one pane |
| `:set key=value` · `:set key` `nokey` `key!` · `:set key?` `key&` | any setting by its key (`editor.tabSize`, or only `tabSize`): a value · on, off, the other way · shown, back as ned comes |
| `:set key+=2` · `:set` · `:set all` | a number up · the settings you changed · every setting, in a tab |
| Vim's names | `wrap` `list` `cursorline` `scrolloff` `foldenable` `undofile` `autoread` `autowrite` `encoding` `spelllang` `laststatus` `showtabline` `title` `number` `relativenumber` `colorcolumn=80,120` `mouse` `clipboard` `background=light` `spell` `ignorecase`; for this file `tabstop` `shiftwidth` `expandtab` `filetype=python` |
| `:colorscheme NAME` | the theme |
| `:N` · `:$` · `:'<` | go to a line |
| `:s/a/b/gi` | replace the text (not a pattern) — every one with g, in any case with i (`:set gdefault`: every one unless g) |
| `:d` `:y` `:m N` `:t N` `:j` `:>` `:<` | delete, yank, move or copy below line N (0: the top), join, indent |
| `:sort` · `:sort! i n u` | sort (backwards, in any case, by number, without repeats) |
| `:g/text/d` · `:v/text/d` · `:g/text/s/a/b/` | the lines that have (or lack) the text: delete them, or replace on them |
| `:!cmd` · `:%!sort` · `:'<,'>!cmd` | run a command (`%` is the file) · put lines through one |
| `:noh` `:u` `:redo` `:cn` `:cp` `:copen` `:Explore` `:term` `:make` `:run` `:zen` `:pwd` `:registers` | the search highlight · undo, redo · the problems · the files · the terminal · build, run · zen mode |

A line command takes a range first: `%` (the whole file), `.` (this line), `$` (the last), `N`, `N,M`, `'<,'>` (the
selection), each with `+N` or `-N` after it if you like — `:.,+3d`, `:%sort`, `:'<,'>s/a/b/g`. A setting changed
with `:set` is kept in your settings, as the Settings window keeps it; `tabstop`, `shiftwidth`, `expandtab` and
`filetype` change only the file in front of you. Vim options ned has no setting for (`hlsearch`, `autoindent` …)
are accepted and left alone, so lines from a vimrc work.

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
| `vim.escapeSequence` | `""` | two keys typed quickly in insert mode that act as Esc, e.g. `"jk"` or `"jj"` (Helix's insert mode too) |
| `vim.keys` · `vim.visualKeys` | `{}` | your own keys in normal mode · in visual mode ([Your own keys](#your-own-keys)) |
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
`~`, `> <`, `J`; `/ ? n N *`; `g` goes (`g e h l s d r y i n p` — `gn` and `gp` are the next and the previous tab),
space opens the space menu (`f b s S / k a r c y p d ?`), and `:w :q`. `vim.escapeSequence` (`"jj"`) leaves insert
mode as Esc does, and `helix.keys` adds your own keys ([below](#your-own-keys)).

## Your own keys

Put any command of the palette (its name, as the palette shows it) or a `:` line on keys of your own, in the key
bindings that have modes:

| setting | in | for example |
|---|---|---|
| `vim.keys` | vim's normal mode | `{"<leader>n": "Next tab", "<leader>p": "Previous tab", "<leader>x": "Close tab", "<leader>w": ":w"}` |
| `vim.visualKeys` | vim's visual modes | `{"<leader>s": "Sort lines"}` |
| `helix.keys` | Helix's normal and select modes | `{"<space>n": "Next tab", "<space>x": "Close tab", "<space>w": ":w"}` |

Write the keys as vim does: `<leader>` (or `<space>`) is the space bar, and in vim mode `<CR>` is Enter, `<Tab>` Tab
and `<C-a>` … `<C-z>` Ctrl and a letter. Yours come before ned's own use of the keys and before a plugin's; while
their first keys are typed, ned waits for the rest (the **which-key** plugin shows what can follow), and a count
before them runs the command that many times (`3<leader>n`: three tabs on). A key with Ctrl or Alt that should work
in every mode goes in the `keys` setting instead (`{"alt+w": "Close tab"}`).

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
