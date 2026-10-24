# ned's own plugins

ned comes with nineteen plugins of its own. They are all off until you turn one on. Turn one on in the
**Plugins dock** (View › Plugins panel, or the menu bar's **Plugins** › Plugins panel): its **AVAILABLE ·
ned's own plugins** section lists the ones that are off, each with a line saying what it does. Tap one, then
*Turn on*, *View its source* (read-only) or *Copy to my plugins*. Copying makes the plugin yours to change: your
copy, in `~/.config/ned/plugins/<name>/`, takes the place of ned's. *Plugins › Available plugins (ned's own)…*
in the menu bar, or the same command in the palette, lists them as well.

Once a plugin is on, it is under **INSTALLED** in the dock, marked *ned's*. Tap it for its menu:

- see its source;
- turn it off (it stays in the list, off);
- its settings, which opens the Settings panel at `plugins.<name>.`;
- reload it;
- run it in a process of its own;
- remove it, which puts it back in AVAILABLE. *Plugins: uninstall / remove one…* does the same from the palette.

The plugins you have turned on are listed in the setting `plugins.bundled`. A project cannot set it until you
trust the folder.

Each plugin's source begins with its full description: every command, key and setting. *View its source* shows
it. In short:

## Editing

| plugin | what it does |
|---|---|
| **dial** | Ctrl+Alt+A / Ctrl+Alt+X, or vim's Ctrl+A / Ctrl+X, add one to (or take one from) what is at the cursor: a number (hex, binary, `1_000`), a date, a time, true/false, a weekday, a month. *Dial: add 1, 2, 3 …* numbers a column. `plugins.dial.cycles` sets your own word lists |
| **case-change** | the name at the cursor in another case: snake_case, camelCase, PascalCase, UPPER_CASE, kebab-case, dot.case, Title Case. *Case: choose…* lists the name in every case, to tap. In vim: `crs`, `crc`, `crp`, `cru` …, as vim-abolish |
| **split-join** | the list in the brackets at the cursor, one item to a line, or back on one line. A comma after the last item is added where the language wants one. In vim: `gS`, `gJ` |
| **text-objects** | more vim text objects: `ia aa` an argument, `ii ai` an indentation level, `iq aq` any quotes, `il al` the line, `ie ae` everything, `i_ a_` a part of a name |
| **exchange** | swap two pieces of text: mark one, then the other. In vim: `cx{motion}`, `cxx`, `cxc` to clear, `X` in visual mode |
| **align** | line up the `=`, `:`, `,`, `|` (or any text) of several lines in one column; Markdown tables too. In vim: `ga{motion}` |

## Moving around and seeing what keys do

| plugin | what it does |
|---|---|
| **harpoon** | pin the few files of a project you work on: *Harpoon: add this file*, the list (Alt+Shift+H), *go to 1 … 4*, a HARPOON view in the dock to tap. In vim: `<leader>a`, `<leader>h`, `<leader>1` … |
| **which-key** | after a key that waits for more (vim's `g`, `z`, `d`, your `<leader>`, emacs's C-x, helix's space), a box above the status bar lists what each next key does: ned's own keys and the plugins' mappings. Type the next key, or tap it. `plugins.which-key.delay` (500 ms) |
| **oil** | a folder as text you edit (*Oil: edit this file's folder as text*). Change a line to rename the file, delete a line to delete it (to the plugin's trash), add one to make a file (`new/` for a folder), then save: ned lists what will happen and asks first. Alt+Enter (vim: Enter) opens what is under the cursor, Alt+Up (vim: `-`) goes to the folder above |

## Tools

| plugin | what it does |
|---|---|
| **json-to-nim** | Nim types from a sample of JSON: the selection, the clipboard or a .json file. They go in at the cursor or in a new tab, and work with std/json's `to` and with jsony. The assistant can use it too |
| **rest-client** | HTTP requests written in `.http` files (variables, `# @name` to use one response in the next, `{{$guid}}` …), sent with curl in the background. The response opens in a tab of its own. Ctrl+Alt+R, or vim `<leader>r` |
| **path-complete** | the names of files and folders, completed in a path you type: in quotes, on an `import` line, in a Markdown link |
| **markdown-tools** | a table of contents kept up to date (on save too), lists renumbered, checkboxes, bold, italic and links, completion of `#anchors` |
| **pomodoro** | a focus timer: 25 minutes, then a break, with the time left in the status bar |
| **time-tracker** | how long you work on each project and file (only while you do something), in the status bar and in a report. It stays on your device |

## Languages

| plugin | what it does |
|---|---|
| **odin** | Odin: colours, comments, indentation, F5 (`odin run`), snippets, an outline; ols and odinfmt when they are installed |
| **gleam** | Gleam: colours, comments, indentation, F5 (`gleam run`, `gleam test`), snippets, an outline; `gleam lsp` and `gleam format` |
| **elixir** | Elixir: colours, comments, indentation, F5 (mix), snippets, an outline; Expert, Next LS, Lexical or ElixirLS, and `mix format` |
| **haskell** | Haskell: colours, comments, indentation, F5 (stack, cabal, runghc), snippets, an outline; HLS, and ormolu or fourmolu |

A language plugin works without its tools; the language server, formatter or compiler is used once it is on
PATH. Each plugin's description says how to install them, in Termux and elsewhere.

The plugins are tested as ned runs them, in `nim e` and compiled: `python3 tests/plugins/tbundled.py --native`.
