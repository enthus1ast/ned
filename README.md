# ned

**A fast, safe code editor and Nim IDE for Termux and Linux.**
It runs in any terminal but looks and behaves like a desktop editor: menus, docks, tabs, tiled panes,
mouse and touch support, dialogs, toasts and tooltips. It is written in Nim, uses only the standard
library, and builds to one binary of about 12 MB.

![Member completion from the built-in Nim engine, with the documentation beside the list (nim-crown theme)](screenshots/completion-docs.png)

![Hover from the built-in engine: signature, documentation and where it is defined](screenshots/hover-docs.png)

![Split panes: each with its own header bar, divided by a solid bar](screenshots/split-panes.png)

![A nimble project with the Files dock, inlay hints and the assistant explaining the file](screenshots/nimble-ai.png)

![Project-wide replace with its preview in the Search dock, the editor split in two](screenshots/split-and-replace.png)

![Nim dock with one nimsuggest, and an AI edit waiting for approval as a diff](screenshots/ai-diff-approval.png)

---

## Contents

- [What's new in 6.32](#whats-new-in-632) · [6.31](CHANGELOG.md#whats-new-in-631) · [6.30](CHANGELOG.md#whats-new-in-630) · [6.29](CHANGELOG.md#whats-new-in-629) · [6.28](CHANGELOG.md#whats-new-in-628) · [6.27](CHANGELOG.md#whats-new-in-627) · [older releases](CHANGELOG.md)
- [Features](#features)
- [Installing](#installing)
- [First steps](#first-steps)
- [Documentation](#documentation) — the guides, the [FAQ](docs/FAQ.md), the [plugin tutorial](docs/plugins/tutorial.md)
- [Contributing](#contributing)

---

## What's new in 6.32

6.32 is about seeing what Nim does: **macros written out under their calls**, **where an exception or a side effect
comes from**, **more errors before the compiler** and **references you can trust**, with **bigger refactorings** and
**a Nim tour** that runs in the notebook. Panes get **their own tabs**, a **terminal or the assistant as a pane** and
**named layouts**; nedls reaches **Neovim, Helix and Zed**; plugins run in a **sandbox** and releases are **checked
before they are installed**.

**Macros you can see.** Alt+M on a macro or template call shows what it writes right under the call, coloured as
Nim — not part of the file: nothing is saved and the line numbers stay. A template is written out at once by ned's
engine, a macro by the compiler. In it, a name hovers with its documentation and a click (a tap) goes to where it is
declared; an error the compiler reports on the call is shown on the generated line it is about. The expansion follows
its call when lines come and go above it and is written again when the call changes; Alt+M again, or a tap on its
heading, hides it. *Nim: expand macro/template in a tab* keeps the old way. [Expansion](docs/guide/nim.md).

**Why?** Tap a routine's exception hint — or *Nim: why?* — and ned shows where an exception comes from: the call in
the routine that raises it, the call in that one, … down to the `raise` (or a routine's own `{.raises.}`); each step
a row that goes there. For a routine that cannot be a func, the same down to the global it uses or the routine that
has side effects. On the compiler's *can raise an unlisted exception* and *can have side effects*, Alt+Enter offers
it.

**More errors before the compiler.** ned's engine says, as you type and in `ned --lint`: an assignment to a `let`, a
`const`, a loop's variable or a parameter that is not `var`; a literal of the wrong type given to a variable, to
`result` or by `return`; a member an object of the project does not have — in the compiler's words, checked on its
compiler and standard library to say nothing the compiler would not.

**Bigger refactorings, and references you can trust.** Each refactoring is a diff before anything changes, undone
file by file with Ctrl+Z: *object ⇄ ref object* (constructors stay, `var x: T` and `result` get a `T()` where they
relied on a value; `==`, shared copies, nil fields and nil checks listed), *split the selected declarations into a
new module* (imports both ways, what the old module still uses exported, what it exported exported again),
*callback → async* (`Future[T]`, `let r = await f(…)` in async callers, the rest listed), *switch call syntax*
(`f(x, y)` · `x.f(y)` · `f x, y`, at the cursor or for a selection, only where the meaning stays). **Find
references** now finds what nimsuggest finds on every place of the scoreboard's sample (95.6% before) and on 99% of
870 more: `0..s.len`, a tuple's labels, a variable in its own value, `high(int64)` and `int.high`, a declaration
below its use, command calls, forward declarations, a `let` in a condition, a module's own type over an imported
one, pragma names, `when` over several lines or decided by `(NimMajor, NimMinor)`. (The comparison now also leaves
out what nimsuggest itself does not resolve — `quote do:` bodies, implicitly generic routines; counted the old way,
97.8%.)

**A package installed while ned runs is found.** (Foxoman's bug: "cannot open file", found after a save, lost after
the next.) ned now watches nimble's package folders and the files that put packages on the path; when they change,
its engine reads them again, nimsuggest and nimlangserver start again (they read them only when they start), and the
open Nim files are checked again — no save needed. nedls too.

**The Nim tour.** Sixteen short lessons of Nim that run in the notebook, from the first `echo` through types,
procedures, iterators, objects and references, generics, errors, templates and macros, async and the standard
library, to ARC/ORC with `sink` and `lent`, and calling C. Ctrl+Enter runs a cell and shows what it printed under it.
Each lesson ends with an exercise whose check says ✓ when your code works, and its answer is folded away beneath.
The lessons are built into ned, so the tour needs no files and no network, only Nim and a C compiler. Each lesson
opens as your own copy, and ned remembers where you were and which lessons you finished. *Help › Nim tour*. A
notebook can now also say how it runs: `# notebook: compiled` above its first cell. [The Nim tour](docs/guide/tour.md).

**Panes, each with its own tabs.** With several panes, a pane's files are tabs in its header: a tap shows one there,
Ctrl+PgUp/PgDn go through that pane's tabs, × takes one out of the pane. **Named layouts**: *View: save this layout
as…*, *View: layouts…* puts it back with its files. **A terminal or the assistant as a pane**: *View: terminal in a
pane* (a shell of its own beside the code), *View: assistant in a pane*, *View: panel in a pane* (Problems,
Output, the debugger beside the code). [Panes](docs/guide/projects.md#panes-tiling).

**Smaller things in the editor.** A breadcrumb tapped lists what is beside it — a folder's files, a symbol's
neighbours. The minimap marks what the find box finds and git's changes. In a Nim file the touch bar adds ▶ run, ✓
check, μ macro, ? why and ⚡ fixes (`ui.touchBarLanguageKeys`), and with the touch bar shown lists have rows twice as
tall (`ui.bigTargets`). **Battery saver** (`ui.batterySaver`, on by itself on battery): no cursor glide, the compiler
on save rather than while typing, no AI completion as you type, fewer wake-ups — a leaf ❦ in the status bar.
**Themes** for phones and tablets outdoors and for e-ink screens: `sunlight`, `sunlight-warm`, `sunlight-blue`,
`e-ink`, `e-ink-dark` (black and white only — every shade ned would mix is drawn as one or the other). **Zed and
Helix themes imported**: *Theme: import a Zed or Helix theme…* (or `ned --import-theme FILE…`) makes a Zed theme
family `.json` or a Helix `.toml` — with its palette and the theme it inherits — into themes of your own: what the
theme leaves out comes from the nearest built-in theme, and a colour too faint to read is made readable, its hue
kept.

**Formatter.** **Closer to nph**: 99.7% of the lines of Nim's compiler and standard library come out as nph writes
them (360 of 463 files identical), with nph's empty lines in type sections and before a section's commented member,
`x = block:`, `typeof(for …)` and `collect(for …)` as blocks, a `while` with a long condition, and comment blocks at
their statement's level. **Code in strings**: the SQL, HTML and JSON in a Nim file's triple-quoted strings is
formatted with the file (`nim.format.embedded`). **Indentation as you type**: in Nim a closing bracket and
`of`/`elif`/`else`/`except`/`finally` go back to where they belong (`editor.autoDedent`). **Format only what I
changed** now works in files git does not have (since you opened them), and gives black, ruff and clang-format the
changed lines themselves.

**nedls in more editors, and the whole project's problems.** Set-ups for **Neovim** (`editors/nvim`: `lsp/nedls.lua`
for Neovim 0.11's `vim.lsp.enable('nedls')`, or `require('nedls').setup()`), **Helix** (`editors/helix/languages.toml`)
and **Zed** (`editors/zed`: an extension that starts nedls beside the Nim extension), each with a README that says how
to install it. An editor that asks for problems (pull diagnostics) gets the whole workspace's: ned's own checks, as
`ned --lint` makes them, go over the project's files that are not open while nedls is idle, and the editor hears when
they change (`workspaceDiagnostics`) — the VS Code extension asks for them, so its Problems panel lists the
project's errors and warnings. Colours come as the edits since the last answer (semantic token deltas), not the whole
file again. Workspace symbols answer at once, from a table nedls keeps up to date as files change: the project's
names first, the names its imports export for a longer query, a name's word starts (`nsv` finds `newShapeValue`), and
`Shape.wid` for a type's fields. And text typed on the last, empty line of a file no longer joins the line above in
nedls's copy. [nedls in other editors](docs/guide/nim.md#nedls-neds-engine-in-other-editors).

**Safety.** Releases carry SHA256SUMS and a signature, and `ned --update` and install.sh check them before
installing (`ned --update --verify DIR` for a download). What goes to the AI has its secrets replaced with
placeholders — keys, tokens, passwords in URLs, private keys — and files of secrets (`.env`, key files) are not sent
(`ai.redactSecrets`). On Linux, plugins run in a Landlock sandbox (`plugins.sandbox`): they read the project and what
they need, change files only in their data folder and the project, and have no network unless you allowed it; `ned
--sandbox CMD` runs any command that way. [Safety](docs/guide/safety.md).

**Fifteen new plugins of ned's own** (Plugins dock › AVAILABLE): for Nim, **benchy** (benchmarks run, shown in a
table, compared with the last run), **web-routes** (a Jester or Prologue app's routes, each a tap from its handler),
**examples-to-tests** (a routine's runnableExamples made a test file), **nimble-browser** (nimble's packages searched,
a README read, installed, required) and **nim-playground** (the selection shared on play.nim-lang.org or run there);
**containers** (Docker or Podman: containers, images, logs, start, stop), **github** (pull requests and issues through
gh), **kanban** (a board from TODO.md, a card moved by editing the file), **wiki-notes** (Markdown notes with
[[links]], their backlinks); and the languages **Typst, Kotlin, Fortran, Pascal, Ada** and **V** — colours,
indentation, F5, snippets, an outline, their language servers, formatters and compiler checks when they are
installed. [ned's own plugins](docs/plugins/available.md). **Plugins under any licence**: the plugin library comes
with the [ned Plugin Exception](PLUGIN-EXCEPTION.md) — a plugin that imports it can be conveyed under terms of your
choice; ned itself stays GPL-3.0-or-later.

**Termux.** The package reads Nim's standard library into ned's index when it is installed (`ned --warm-index`), so
the first session's completion and hover start at once. The debugger shows Nim strings, seqs and tables readably
even when the Nim in use came without its gdb pretty printers (ned keeps a copy).

## Features

**Desktop-style UI in the terminal** — title bar with menus (F10), command palette (Ctrl+E, over 500 commands,
most-used first), Telescope (Alt+Shift+F: every finder with a preview), a cursor that glides, left dock (files,
search & replace, git, Nim, tests), right dock (AI assistant, outline, timeline), bottom panel (problems, output,
terminal), tabs, breadcrumbs, minimap, sticky scroll, indent guides, rainbow brackets, tooltips, toasts, modal
dialogs, context menus (right click), drop shadows, hover effects, 60 themes (VS Code dark/light, One Dark, Tokyo
Night, Catppuccin, Gruvbox, Dracula, Nord, Solarized, GitHub, Rosé Pine, Kanagawa, Ayu, Monokai, Modus, Shades of
Purple, Slate, Monochrome, Everforest, Night Owl, from vim Jellybeans, Iceberg, Sonokai and PaperColor, Foxoman's
ClassicBlue and Nebula themes, and ned's own: Nim Crown, Frankincense, Desert Dusk, Lagoon, Sea Glass, Paper Ink,
Rose Quartz, Amber CRT, Green Phosphor, and six easy on the eyes for OLED and LCD screens …) — or `auto`, following
the terminal's background or the time of day, your own colours (a theme editor that checks contrast), VS Code or
base16 themes imported, and Termux's own colours set to match — three icon sets (unicode, Nerd Font, ASCII), phone
layout below 70 columns, an accessibility mode (ASCII, letters beside colours, high contrast), multi-root workspaces
(git for each folder), remote folders over SSH (git, Run and the assistant's commands on the server; its changes come
back by themselves), settings sync. → [Themes and appearance](docs/guide/themes.md) · [Key
bindings](docs/guide/keys.md) · [Settings](docs/guide/settings.md)

**Editing** — multi-cursor (Ctrl+D, Alt+A, Alt+J/K), selection that grows by the code's structure (a name, the
call, the statement, the block, the routine), surround (brackets, quotes, a tag, a block — and vim-surround), an
undo tree (Undo history… with the text at each state), next-edit suggestions (a rename's next place: Tab, Tab),
move/duplicate lines, toggle comment, folding, snippets for Nim, Python, C, C++, JS/TS, Rust, Go, HTML and shell (plus your own),
completion, auto-pairs, smart indentation, soft wrap, tiled panes, multibuffers, bookmarks, regex find/replace, sort/join/
case transforms, line-ending and indentation conversion, format on save (built in for Nim, JSON, Markdown, CSS,
HTML, SQL, YAML and TOML; a whole project at once; or only the lines you changed, and a preview first), jump labels
(Alt+Shift+J), a preview beside the file and symbol pickers,
files in their encoding (UTF-16, Windows-1252 … written back as read), unsaved edits kept when you quit (hot exit),
rulers at the columns you choose or where the formatter wraps (`"editor.rulers": ["lineLength"]`; long lines tinted), colour swatches, `.editorconfig` support (its `max_line_length` is the formatter's too), spell check,
CSV and TSV files as tables (columns lined up, sort by a column, a column's sum and mean), large-file mode and a viewer for files of any size, a 3-pane merge editor, keyboard macros, vim, Emacs and Helix key bindings, operator ligatures
(`editor.fontLigatures`: drawn by ned in any terminal — `─→ ═⇒ ≠ ≤ ≥` — or kept whole for a ligature font). → [Editing](docs/guide/editing.md) · [Key bindings](docs/guide/keys.md) · [Search and replace](docs/guide/search.md) · [Formatting](docs/guide/formatting.md) · [Vim mode and zen mode](docs/guide/vim-and-zen.md)

**Plugins** — written in NimScript (or full Nim, compiled): commands, keys, events, the text, problems with fixes,
signs and highlights, languages with their completions, hover, code actions, outline and snippets, formatters,
language servers (also written in NimScript, for any editor: `ned --lsp-bridge`), tools for the assistant, views
in their dock, progress and output, vim mappings, operators and text objects, timers, how indentation looks — the
NimScript ones in one process, a dock to manage them with their versions and updates, a list to install from; each
asks before it runs programs, changes files or uses the clipboard. Seventy-three of ned's own come with it, off until
you turn one on. → [Plugins](docs/plugins/README.md) · [Tutorial](docs/plugins/tutorial.md) · [API reference](docs/plugins/api.md)

**Languages** — syntax highlighting for Nim, C, C++, JS/TS, Rust, Go, Python, Kotlin, C#, PHP, SQL, Java, Lua,
Ruby, shell, Markdown, JSON, YAML, TOML, HTML, CSS, Makefiles, diffs, Nim templates (`.nimf`), Jinja-style templates
(Nimja's `.nimja`, `.jinja`, `.j2`) and more — and your
own (`languages`); code inside strings and Markdown code blocks in its own colours (C in `{.emit}`, SQL, HTML,
regular expressions); any language server (configure in `lsp`) with type definition, implementation and type
hierarchy, document links, pull diagnostics and formatting as you type — and a second one beside it (a linter such
as ruff), their problems and fixes merged; formatters per language; debugging through the Debug Adapter Protocol (Python, C, C++, Rust, Go, JS/TS …) with logpoints and
stops when a value changes; tests for pytest, go
test, cargo test, PHPUnit, dotnet test and Gradle/Maven; coverage for **Nim**, Python, Go, Rust, JS/TS and any lcov file;
Send to REPL, and `# %%` cells run as a notebook (the output under each cell); Emmet for HTML and CSS; **ned's own CSS, HTML, SQL, JavaScript and JSON** — completion,
hover and problems in their files and in Nim strings (and a page's `<script>`s), with your project's class names,
tables and columns, the `?` of a query counted against the values it is given, a script's classes and the
browser's globals, JavaScript's definitions and references across its modules, and the keys and values of
package.json, tsconfig.json, atlas's and nimble's files and ned's settings (`web.engine`). → [Running, testing and debugging](docs/guide/run-and-debug.md) · [Settings](docs/guide/settings.md) · [Formatting](docs/guide/formatting.md)

**Nim IDE** — a built-in Nim engine (completion with documentation beside the list, hover, go to definition,
signature help, references with counts beside each declaration (operators too), rename, type hierarchy, go to
implementation, change signature, inline, move to another module, fill in a constructor's fields, outline, project symbols, the types of `let`s, `var`s and loop variables shown beside them,
`include`d files and what templates and macros declare understood) that needs no language server — and serves
other editors as one (`nedls`) — a formatter in nph's style (also on its own: `nedfmt`, with a pre-commit hook),
errors while you type from the compiler itself and the engine's own checks at once (unused imports, field typos,
argument counts, values not used, a var that can be a let, unused parameters, deprecated names and library names
newer than the package's Nim) — also from the command line and in CI (`ned --lint`, GitHub annotations, a
pre-commit hook, *Nim: add a CI workflow*) — `nim check` on save; a type's memory layout on hover (and the field
order that saves bytes), what a routine can raise, the package versions the build uses (nimble.lock, nimble.paths,
atlas), one Nim per project for every tool (`nim.toolchain`); nimlangserver if you prefer it;
macro/template expansion (Alt+M), ARC/ORC view, generated C, test explorer for `std/unittest`
with ▶ run buttons in the gutter, project symbols, nimble tasks and the dependency tree, Atlas, Nimony, gdb
debugging in the terminal (logpoints, stops when a value changes), a profiler that shows each proc's and line's
share of the time beside it (and a flame graph), memory checks (AddressSanitizer, UBSan, valgrind), tests
written from running a proc, quick fixes from the compiler's messages, AI fixes checked by `nim check`, REPL (Shift+Enter sends code to inim), docs lookup, run configurations, what a
proc can raise, benchmarks, nimble releases and newer dependency versions, testament, runnableExamples with a ▶,
type mismatches explained argument by argument. **Nim 3 (Nimony)**: a project built with nimony gets names matched as
written, Nimony's own library, errors from `nimony check` and its `--def`/`--usages`, Nim 3's pragmas; Nim 2 files
show what porting them needs, fixed one by one, all at once, or by the assistant checked with nimony. → [Nim IDE](docs/guide/nim.md) · [Formatting](docs/guide/formatting.md) · [Compiler Explorer](docs/guide/compiler-explorer.md)

**C and C++** — ned's own C engine, no clangd needed: completion (struct members after `.` and `->` too; C++
classes with their bases, methods, namespaces after `::`, templates, `auto`), hover with the comment that documents
a declaration, go to definition through `#include`s (a C++ method's body outside its class), references, rename,
signature help, the outline, the compiler's errors while you type and a missing `#include` added — in emits too
(C++ when `nim.backend` is cpp); clangd when you prefer it. → [C and C++](docs/guide/c.md) · [Compiler Explorer](docs/guide/compiler-explorer.md)

**Compiler Explorer** — the machine code beside your Nim, C or C++ while you type, as on godbolt.org: each line and its instructions in one colour, the cursor or the mouse on either side lighting up the other, a toolbar for the C compiler, the processor (ARM64 on a PC through zig), the options, Intel or AT&T, the compiler's assembly or a disassembled object, godbolt's filters, the program run, two builds compared, and what each instruction does on hover → [Compiler Explorer](docs/guide/compiler-explorer.md)

**Hex editor** — binary files as offset · hex · text, typed over or inserted, undo, find bytes or text, go to an
offset, a data inspector, copy as hex, a Nim array or a C array; programs and libraries (ELF, Mach-O, PE) with their
sections and symbols — Nim's procs by their Nim names, the bytes each module takes, a proc's Nim source; a proc
decompiled to C beside it. → [Hex editor, programs and the decompiler](docs/guide/hex-and-binaries.md)

**Integrated terminal** — a real pty with an xterm-compatible emulator: vim, htop, less, git, ssh all work;
several terminals (two side by side), scrollback, mouse, selection and copy; with bash, zsh and fish every command
is marked — Ctrl+↑/↓ go through them, failed ones show red, a command's output can be copied or it can be run again.
`ned FILE` there opens FILE in this ned, and this ned is git's editor (`git commit` opens the message in a tab). → [The terminal and remote work](docs/guide/terminal.md)

**Remote control** — scripts reach the running ned: `ned --remote FILE:LINE`, `--remote-command`,
`--remote-message`, `--remote-problems` (a build's output → Problems), `--remote-get`, `--remote-list`;
`ned --wait` as `GIT_EDITOR`. → [The terminal and remote work](docs/guide/terminal.md)

**The terminal it runs in, asked** — the kitty keyboard protocol (Ctrl+Shift+letters, Ctrl+I apart from Tab),
24-bit colour, curly underlines in the problem's colour, emoji sequences as one character (mode 2027), light and
dark following the system (mode 2031), the focus (files looked at again when you come back, background work paused
while you are away), the terminal's title, progress on its tab, a transparent background.

**Git** — source-control dock (stage, unstage, discard, diff, commit, push, pull, log), every change not committed
in one editable view (Alt+Shift+G: stage, unstage or revert each), gutter marks that follow your typing, change
navigation and revert, inline blame, file timeline, AI-written commit messages,
interactive rebase, cherry-pick, branch compare and graph, the history of some lines, bisect (by hand or with a
command), worktrees, submodules, GitHub pull requests, issues and CI status (`gh`), review comments on their
lines; signing in to GitHub (the GitHub CLI or an SSH key — no passwords), undo of the last commit, pull or
merge, and checks before a commit (formatted, tests passing). → [Git](docs/guide/git.md)

**AI** — chat and agent (read, search, edit files, run commands — you approve edits and commands; its edits are
checked with `nim check` and the like, and it is told what is wrong), a plan first and then each step with a
restore point, tests it writes kept only when they pass, a failing test made to pass (kept only when it does),
answers grounded in the declarations your code uses, inline edit of a selection (Alt+Shift+C), undo of the agent's
changes, token and cost counter, AI review of staged changes, a local model on the device (Ollama or llama.cpp,
set up for you: offline on a phone too), MCP servers for more tools, their prompts (/server:prompt) and resources (@server:uri); Anthropic, OpenAI, OpenRouter, Ollama, Groq, DeepSeek, Gemini, Mistral or any
OpenAI-compatible endpoint. → [The AI assistant](docs/guide/ai.md)

![Colour swatches, and a ruler at column 80 with the rest of the long line tinted](screenshots/rulers-swatches.png)

![Problems: every error and warning with its code in one editable multibuffer, each in plain words](screenshots/problems-multibuffer.png)

![Reviewing the assistant's change side by side — r undoes it](screenshots/agent-review.png)

## Installing

ned needs **Nim 2.2 or newer** and nothing else to build. Everything else is optional and is picked up
automatically when it is on your `PATH`.

**The quick way** — Termux gets the release's package, anywhere else ned is built with nimble:

```sh
curl -fsSL https://raw.githubusercontent.com/foxoman/ned/main/install.sh | sh
```

**With nimble**: `nimble install https://github.com/foxoman/ned` (once ned is in Nim's package list: `nimble install
ned`) builds `ned`, `nedfmt` and `nedls` into `~/.nimble/bin`. **With Atlas**: ned needs no packages, so there is
nothing for Atlas to fetch to build it — clone it and build it as below; in an Atlas project that uses ned's engine
as a library (`import ned/nim/index`), `atlas use https://github.com/foxoman/ned` adds it.

**Updating**: `ned --update` (or *Help: update ned…* in the palette) finds the newest release and installs it the
way this ned was installed — the Termux package, nimble, or a checkout it was built in — after saying what it will
run and asking; `ned --update --check` only says whether there is one. The package is checked against the
release's SHA256SUMS and its signature first.

### Termux (Android)

```sh
pkg install nim git ripgrep curl            # nim to build; the rest is optional but recommended
nim c -d:release --opt:speed -d:strip -o:$PREFIX/bin/ned src/ned.nim
ned --check                                 # what ned found, and how to add the rest
ned
```

or, from the project folder: `nimble termux` (ned, with `nedfmt` and `nedls` beside it) — or the ready-made package
of a release, `pkg install ./ned_6.32.0_aarch64.deb` (ned, nedls, nedfmt; the example plugins in
`$PREFIX/share/ned/plugins`). `nimble termuxdeb` makes that package on a Linux machine (with zig).

The Nim IDE features need nothing more: the engine is built in, and `nim check` does the rest.
Recommended extras:

```sh
nimble install inim                         # Nim REPL (formatting is built in; nph is optional)
pkg install gdb termux-api                  # debugger; clipboard (also install the Termux:API app)
```

Nothing stays running in the background — nimsuggest is off by default, and the checks while you type are short
`nim check` runs — which suits a phone's memory. A save also runs the tests that cover the file and asks the
compiler where ARC/ORC copies, short runs as well; `"nim.testOnSave": "off"` and `"nim.showCopies": false` leave
them out to spare the battery.

Use a Nerd Font in `~/.termux/font.ttf` and set `"ui.icons": "nerd"` for nicer icons. The extra-keys row of
Termux (Esc, Ctrl, Alt, arrows, F-keys) makes every shortcut reachable; every command is also in the menus
and the palette, and everything can be tapped.

### Linux

```sh
nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim && sudo mv ned /usr/local/bin/
# or
nimble install            # builds and installs ~/.nimble/bin/ned (and nedfmt, nedls)
nimble local              # builds into ~/.local/bin (ned, nedfmt, nedls)
```

A terminal with true colour and mouse reporting (kitty, WezTerm, foot, Alacritty, GNOME Terminal,
Konsole, Windows Terminal, iTerm2, tmux with `set -g mouse on`) gives the best result.

### macOS

```sh
brew install nim git ripgrep               # Homebrew (brew.sh); choosenim works too
nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim && sudo mv ned /usr/local/bin/
ned --check
```

The clipboard uses `pbcopy` / `pbpaste`. iTerm2, WezTerm, kitty and Ghostty show true colour and pass the mouse;
in Terminal.app set *Use Option as Meta key* (Settings › Profiles › Keyboard) so the Alt shortcuts work. The
debugger panel uses `gdb`, which macOS only lets run once it is code-signed (`brew install gdb`, then its signing
steps); without it, *Nim: debug with gdb* in the palette falls back to `lldb` in the terminal.

### Windows

**Native (experimental, since 6.21).** ned builds for Windows itself — the same program, with Win32 and the C
runtime behind its terminal calls: the console is its terminal (Windows Terminal, or the console of Windows 10
1809 and later — virtual-terminal input and output, UTF-8), its terminal panel is a pseudo-console (ConPTY) running
PowerShell (or `terminal.shell`), its commands (tasks, builds, `nim check`) run through Git for Windows' `sh` when it
is installed (else `cmd.exe`), the clipboard is the Windows clipboard, and paths are written with `/` (Windows
takes them). It is built and checked on every push (`windows-x86_64` in `.github/workflows/build.yml`: the command
line, the formatter's tests), but used far less than the Linux, macOS and Termux builds — WSL is the tried way.

The release's `ned-6.32.0-windows-x86_64.zip` has `ned.exe`, `nedfmt.exe` and `nedls.exe`, ready to run: unzip
it, and start `.\ned.exe` in Windows Terminal (`nim` on the PATH for the Nim features). Or build it:

```powershell
scoop install nim git                       # or the official Nim zip, and Git for Windows (its sh runs ned's commands)
nim c -d:release --opt:speed -d:strip -o:ned.exe src/ned.nim
.\ned.exe --check
.\ned.exe
```

What it does not have there: the remote-control socket needs Windows 10 1803 or later (AF_UNIX); the formatter of
nedls runs in-process instead of in a child of its own (no fork); `nice` is a lower priority class.

**WSL.** The Linux build, inside WSL (Windows Subsystem for Linux), in Windows Terminal:

```powershell
wsl --install                               # once, in PowerShell as administrator; then restart and open Ubuntu
```

```sh
# inside Ubuntu (apt's Nim is too old — take the official build)
sudo apt install build-essential git ripgrep curl xz-utils
curl -sSfL https://nim-lang.org/download/nim-2.2.4-linux_x64.tar.xz | tar -xJ -C ~
echo 'export PATH=$HOME/nim-2.2.4/bin:$PATH' >> ~/.bashrc && . ~/.bashrc
nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim && sudo mv ned /usr/local/bin/
ned --check
```

Copying goes to the Windows clipboard (OSC 52 in Windows Terminal, and PowerShell), pasting reads it through
PowerShell, and links open in your Windows browser with `wslview` (`sudo apt install wslu`). Keep your projects
inside the Linux file system (`~/code`, not `/mnt/c/…`): it is much faster there.

### Ready-made binaries

The project's GitHub Actions workflow (`.github/workflows/build.yml`) builds ned on every push for Linux (x86_64
and arm64), macOS (Apple silicon and Intel), Termux (aarch64), Windows (native, and through WSL), runs it in a real
pseudo-terminal, and attaches the binaries to the release when you push a tag such as `v5.6.1` — `nedfmt` (the
formatter) and `nedls` (the language server) beside each `ned`.

### Optional tools ned uses when present

| tool | what for |
|---|---|
| `nimsuggest` | ships with Nim; off by default — a second opinion where the built-in engine cannot infer a type (`"nim.nimsuggest": true`) |
| `nimlangserver` | only if you choose it (`"nim.ide": "nimlangserver"`) instead of the built-in engine |
| `nph`, `nimpretty` | only if you choose one (`"nim.formatter"`) instead of the built-in formatter |
| `inim` | Nim REPL (palette › Nim: REPL) — falls back to `nim secret` |
| `clangd` | C and C++ language server — for C, ned's own engine answers when it is not installed (`c.engine`) |
| `cc` (gcc or clang) | C errors while you type, the C in `{.emit}` checked, what the system's headers declare |
| `rg` (ripgrep) | fast project search (falls back to grep, then to a built-in search) |
| `git` | git dock, gutter marks, blame, timeline |
| `curl` | the AI assistant |
| `gdb` / `lldb` | Nim: debug with gdb |
| `termux-clipboard-*`, `pbcopy`, `wl-copy`, `xclip`, PowerShell (WSL) | system clipboard (OSC 52 is used too) |
| `gh` | Git › Pull request, and *Create a GitHub issue* from a TODO comment |

## First steps

```sh
ned                      # the folder you are in (reopens the files you had open)
ned src/app.nim:42:7     # a file at line 42, column 7      (also: ned +42 src/app.nim)
ned ~/code/project       # a folder (inside ned: File › Open folder…, or d on the Welcome page)
git log | ned            # what a command printed
ned --check              # what ned found on this system, and how to install what is missing
```

Starting ned on a file outside the current folder (say `ned ~/code/app/src/x.nim` from `$HOME`) opens that
file's project (the nearest folder with `.git`, a `.nimble`, `Cargo.toml` …) instead of indexing your home.

- **F10** opens the menus, **Ctrl+E** the command palette, **F1** the key bindings.
- **Ctrl+P** finds a file — type `:42` for a line, `@name` for a symbol, `#name` for a project symbol,
  `>` for commands.
- Click or tap anything: tabs, gutter markers (▶ run, ▾ fold), breadcrumbs, dock items, buttons.

## Documentation

Everything ned does is described in the guides under [`docs/`](docs/README.md):

| | |
|---|---|
| [FAQ](docs/FAQ.md) | short answers: installing and updating, keys a terminal does not pass on, which Nim engine, clangd or not, formatters, AI providers and offline use, where ned keeps things, speed on a phone, plugins, reporting a bug |
| [Key bindings](docs/guide/keys.md) | every key, by what it is for |
| [Files, folders and projects](docs/guide/projects.md) | starting ned, the project folder, the file tree, Ctrl+P, tabs, splits, sessions |
| [Editing](docs/guide/editing.md) | cursors and selections, surround, snippets, the undo tree, macros, folding, spell check, encodings, big files |
| [Nim IDE](docs/guide/nim.md) | the built-in engine, nedls in other editors, lint rules, quick fixes and rewrites, one Nim per project, nimsuggest and nimlangserver |
| [C and C++](docs/guide/c.md) | ned's own C engine, or clangd |
| [Formatting](docs/guide/formatting.md) | Nim in nph's style and its settings, C in clang-format's styles, `nedfmt`, the other languages |
| [Compiler Explorer](docs/guide/compiler-explorer.md) | the assembly beside the code, live |
| [Running, testing and debugging](docs/guide/run-and-debug.md) | run configurations, tasks, tests, coverage, the debugger, the REPL, profiling |
| [Git](docs/guide/git.md) | the dock, the changes view, blame, history, rebase, bisect, GitHub |
| [The AI assistant](docs/guide/ai.md) | chat, the agent, providers, local models, MCP |
| [Search and replace](docs/guide/search.md) | in the file and the project |
| [The terminal and remote work](docs/guide/terminal.md) | the integrated terminal, scripting a running ned, SSH folders, workspaces |
| [Themes and appearance](docs/guide/themes.md) | the themes, your own colours, icons, accessibility |
| [Vim mode and zen mode](docs/guide/vim-and-zen.md) | |
| [Settings](docs/guide/settings.md) | where they live, projects' settings, sync — and [every setting](docs/reference/settings.md) |
| [Plugins](docs/plugins/README.md) | how they run — the [tutorial](docs/plugins/tutorial.md) and the [API reference](docs/plugins/api.md) |
| [Hex editor and programs](docs/guide/hex-and-binaries.md) | binary files, a program's sections and symbols, the decompiler |
| [Safety](docs/guide/safety.md) | how ned protects your work |
| [Files ned uses](docs/guide/files.md) | settings, state, caches |
| [Building, tasks and performance](docs/guide/building.md) | building ned, its tests, run configurations, speed |
| [Troubleshooting](docs/guide/troubleshooting.md) | when something does not work |
| [Commands](docs/reference/commands.md) | every command of the palette |

## Contributing

Bug reports, ideas, themes and code are welcome — [CONTRIBUTING.md](CONTRIBUTING.md) explains how ned is built,
laid out and tested. Security problems: please report them privately ([SECURITY.md](SECURITY.md)).

## License

Copyright © 2026 Foxoman.

ned is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as
published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
It is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details: the full
text is in [LICENSE](LICENSE) (SPDX: `GPL-3.0-or-later`).

Plugins may use any licence: the plugin library they import comes with the
[ned Plugin Exception](PLUGIN-EXCEPTION.md), an additional permission to combine a plugin with it and convey the
plugin under terms of your choice.
