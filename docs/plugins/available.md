# ned's own plugins

ned comes with fifty-eight plugins of its own. They are all off until you turn one on. Turn one on in the
**Plugins dock** (View › Plugins panel, or the menu bar's **Plugins** › Plugins panel): its **AVAILABLE ·
ned's own plugins** section lists the ones that are off, each with a line saying what it does. A tap turns one
on: the dock goes to it under **INSTALLED**, and once it runs the status bar says what it added — the languages,
commands, snippets, a formatter … — which the dock lists under it. A right-click gives its menu instead: *Turn
on*, *View its source* (read-only, to read it first) or *Copy to my plugins*. Copying makes the plugin yours to
change: your copy, in `~/.config/ned/plugins/<name>/`, takes the place of ned's. *Plugins › Available plugins
(ned's own)…* in the menu bar, or the same command in the palette, lists them as well.

Once a plugin is on, it is under **INSTALLED** in the dock, marked *ned's*. Tap it for its menu:

- see its source;
- turn it off (it stays in the list, off);
- its settings, which opens the Settings panel at `plugins.<name>.`;
- reload it;
- run it in a process of its own;
- remove it, which puts it back in AVAILABLE. *Plugins: uninstall / remove one…* does the same from the palette.

Some of them do more than edit, and ask first when you turn them on (what you allow is kept on this device):
**rest-client** runs curl and uses the clipboard (*REST: copy as curl*), **json-to-nim** runs git to list a
project's `.json` files and reads JSON from the clipboard, **markdown-tools** reads a link's address from the
clipboard, **oil** changes files — that is what it is for —, **commit-helper** runs git, **nim-eval** runs nim,
**sqlite** runs sqlite3, **web-preview** opens your browser and starts a web server, **mermaid** runs mmdc,
**license-header** runs git and writes headers into files, **dotenv** writes an `.env.example`, **transform** puts a
sum on the clipboard, **yank-ring** reads the clipboard, **import-graph** reads a project's import lines with find
and awk, **release-helper** runs git, **db-client** runs psql or mysql, **code-snap** runs the program that draws its PNG
(and writes a picture beside your file when you set it to), the language plugins that start a language server or a
formatter, or give F5 a command, run those programs, and **todo** writes `TODO.md` when it is not open in a tab. The others only edit; harpoon,
pomodoro, time-tracker, yank-ring and char-picker keep their data in their own folder, which needs no permission.

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
| **transform** | the selected lines (or the whole file) sorted, made unique, reversed, shuffled, numbered, joined; the selection encoded and decoded (base64, URL, hex, HTML, a string literal), JSON made pretty or one line, numbers added up |
| **license-header** | the copyright and licence line at the top of a file, in the file's own comments: the licence of the project's LICENSE file, your name from git, this year — on one file or on every file of the project |
| **yank-ring** | a history of what you copied and cut: *Yank ring: paste from history…* (Ctrl+Alt+V) lists the last ones to paste; right after a paste, Alt+Shift+Y swaps it for the copy before. Kept in memory only, unless `plugins.yank-ring.keepOnDisk` says otherwise (a copy can be a password) |
| **doc-gen** | *Doc: write a doc comment* for the routine at the cursor: a line for what it does, one for each parameter and one for its result — `##` in Nim, a docstring in Python, JSDoc, Doxygen in C and C++, Go's and Rust's own. Alt+Enter on a signature without one offers it |
| **color-picker** | the colour at the cursor written another way (#rrggbb → rgb() → hsl(), Nim's 0xRRGGBB and std/colors' names), made lighter or darker, or picked from CSS's 148 named colours |
| **char-picker** | *Insert a character…* (Ctrl+Alt+U): about 850 characters by name — arrows, maths, Greek, box drawing, currency, emoji, Nerd Font symbols; the name and code point of the character under the cursor (vim: `g8`) |
| **indent-dots** | a dot in each space of a line's indentation, up to its first letter — not between words, as Xcode shows it; → where a tab starts, a blank line's dots as deep as the code around it, `¬` at line ends if you want. *Indent dots: on/off* (vim `<leader>id`) |
| **rainbow-indent** | each level of indentation in its own colour — soft bands, the guides, or the dots of indent-dots — and a red band where a line's indentation is not whole levels. The theme's colours by default, or yours. *Rainbow indent: on/off*, *…next style* |

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
| **todo** | a task list for the project in `TODO.md`, as Markdown checkboxes: *Todo: add a task…* (Alt+Shift+A) from anywhere — on a `TODO` comment, the comment and its place; `due:fri`, `due:+3` written as dates, `(A)` for priority —, *Todo: the list…* (Alt+Shift+L) by the day due, done with the day, archived under `## Done`. The open ones in the status bar (☐ 3 ⚠ 1) and in the Plugins dock; a note at start when some are due |
| **pomodoro** | a focus timer: 25 minutes, then a break, with the time left in the status bar |
| **time-tracker** | how long you work on each project and file (only while you do something), in the status bar and in a report. It stays on your device |
| **regex-lab** | try a regular expression on the file: its matches lit up, their groups beside them; a replace with $1 … (how many it changes asked first); a pattern explained a piece at a time |
| **sqlite** | an SQLite database beside the code: its tables and columns in the Plugins dock and in completion, the query at the cursor run on it, the rows in a tab |
| **web-preview** | the page you are writing in your browser: the file as it is, or served from the project's folder so its links and scripts work; the address at the cursor opened |
| **commit-helper** | a commit message drafted from what is staged — the kind of change, where, what — to read, fix and commit |
| **nim-eval** | the selected Nim (or the line) compiled and run where you write it, what it prints shown beside it |
| **mermaid** | Mermaid diagrams: their colours, snippets, an outline, and the picture made by mermaid-cli (mmdc) and shown in ned — of a `.mmd` file or a Markdown ```` ```mermaid ```` block |
| **nim-html** | web pages written in Nim with Karax: completion and hover of its tags and attributes in a `buildHtml` block; Emmet (`div.card>h2+p*2`), HTML and std/htmlgen calls turned into Karax's DSL; snippets |
| **import-graph** | how a Nim project's modules import one another: a Mermaid flowchart and a tree in a Markdown tab, and the modules that import the file you are in |
| **release-helper** | a Nim package's release: the version bumped in the `.nimble` file (and a `version.nim`), a CHANGELOG entry from git's log since the last tag, the tag made and pushed when you choose |
| **db-client** | SQL run on PostgreSQL or MySQL/MariaDB with psql or mysql: the statement at the cursor (Ctrl+Enter) or the file, the rows as a table in a tab, an error at its line. Connections in `plugins.db-client.connections`; passwords stay in the programs' own files, never in ned's settings |
| **code-snap** | the selected code as a picture — a PNG, an SVG or an HTML page of a window with its lines, coloured, numbered — to put in a README or a post. The PNG is drawn by rsvg-convert (librsvg), resvg, ImageMagick, Inkscape or Chromium; with none of them, it asks which to install and runs the command (pkg in Termux, apt, dnf, pacman, Homebrew …) in the terminal |

## Languages

| plugin | what it does |
|---|---|
| **odin** | Odin: colours, comments, indentation, F5 (`odin run`), snippets, an outline; ols and odinfmt when they are installed |
| **gleam** | Gleam: colours, comments, indentation, F5 (`gleam run`, `gleam test`), snippets, an outline; `gleam lsp` and `gleam format` |
| **elixir** | Elixir: colours, comments, indentation, F5 (mix), snippets, an outline; Expert, Next LS, Lexical or ElixirLS, and `mix format` |
| **haskell** | Haskell: colours, comments, indentation, F5 (stack, cabal, runghc), snippets, an outline; HLS, and ormolu or fourmolu |
| **zig** | Zig: colours, comments, indentation, F5 (`zig build run`, `zig run`, `zig test`), snippets, an outline; zls and `zig fmt` |
| **julia** | Julia: colours, comments, indentation, F5 (`julia --project`), snippets, an outline; LanguageServer.jl when it is installed, started the first time you save a Julia file (it starts slowly); JuliaFormatter when you set it |
| **ocaml** | OCaml: colours, `(* *)` comments, indentation, F5 (dune or ocaml), snippets, an outline; ocamllsp and ocamlformat |
| **crystal** | Crystal: colours, comments, indentation, F5 (`crystal run`, `crystal spec`), snippets, an outline; crystalline and `crystal tool format` |
| **dart** | Dart and Flutter: colours, comments, indentation, F5 (`dart run`, `dart test`, `flutter run`), snippets (widgets too), an outline; Dart's language server and `dart format` |
| **clojure** | Clojure, ClojureScript, EDN and Babashka: colours, comments, indentation, F5 (clojure, lein, bb), snippets, an outline; clojure-lsp, and zprint or cljfmt |
| **swift** | Swift: colours, comments, indentation, F5 (`swift run`, `swift test`, or the file alone), snippets, an outline; sourcekit-lsp and swift-format |
| **scala** | Scala 2 and 3, sbt files too: colours, comments, indentation, F5 (sbt, scala-cli or scala), snippets, an outline; Metals and scalafmt |
| **r** | R: colours, comments, indentation, F5 (`Rscript`, testthat for a test file), snippets, an outline; R's languageserver (started at the first save, when the package is installed) and styler |
| **nix** | Nix: colours, comments, indentation, F5 (`nix flake check`, else `nix-instantiate --eval`), snippets, an outline; nixd or nil, and nixfmt or alejandra |
| **terraform** | Terraform, its `.tfvars` and HCL: colours, comments, indentation, F5 (`terraform plan`), snippets, an outline; terraform-ls and `terraform fmt` |
| **protobuf** | Protocol Buffers: colours, comments, indentation, F5 (`buf generate`, `buf build` or protoc), snippets, an outline; protols or bufls, and `buf format` |
| **graphql** | GraphQL: colours, comments, indentation, snippets, an outline; graphql-lsp and prettier |
| **svelte** | Svelte components: colours, comments, indentation, F5 (`npm run dev`, or pnpm, yarn, bun), snippets, an outline; svelteserver and prettier |
| **cmake** | CMake (`CMakeLists.txt`, `.cmake`): colours, comments, indentation, F5 (configure and build; `cmake -P` for a script), snippets, an outline; neocmakelsp or cmake-language-server, and gersemi or cmake-format |
| **latex** | LaTeX and BibTeX: colours, comments, indentation, F5 (`latexmk -pdf`, following a `% !TEX root` line), snippets, an outline; texlab and latexindent |
| **perl** | Perl: colours, comments, indentation, F5 (`perl -Ilib`, `prove` for a `.t` file), snippets, an outline; Perl Navigator or Perl::LanguageServer, and perltidy |
| **erlang** | Erlang: colours, comments, indentation, F5 (rebar3's eunit or ct, else erlc and erl), snippets, an outline; ELP or erlang_ls, and erlfmt |
| **dotenv** | `.env` files: colours, their keys in the outline, their mistakes as you type, a `${KEY}`'s value on hover, an `.env.example` made from them |

A language plugin works without its tools; the language server, formatter or compiler is used once it is on
PATH. Each plugin's description says how to install them, in Termux and elsewhere.

The plugins are tested as ned runs them, in `nim e` and compiled: `python3 tests/plugins/tbundled.py --native`.
