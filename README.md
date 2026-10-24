# ned

**A fast, safe code editor and Nim IDE for Termux and Linux.**
It runs in any terminal but looks and behaves like a desktop editor: menus, docks, tabs, split panes,
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

- [What's new in 6.25](#whats-new-in-625) · [6.24.1](CHANGELOG.md#whats-new-in-6241) · [6.24](CHANGELOG.md#whats-new-in-624) · [6.23](CHANGELOG.md#whats-new-in-623) · [older releases](CHANGELOG.md)
- [Features](#features)
- [Installing](#installing)
- [First steps](#first-steps)
- [Documentation](#documentation) — the guides, the [FAQ](docs/FAQ.md), the [plugin tutorial](docs/plugins/tutorial.md)
- [Contributing](#contributing)

---

## What's new in 6.25

6.25 brings **nineteen plugins of ned's own** — vim's favourites, VS Code's and four languages — with a
**Plugins menu** to find and manage them, and an engine that answers more of what only the compiler knew:
**the compiler as an oracle in the background**, chain hints, three more checks while you type, completion that
remembers what you chose, a rename that reaches strings and doc comments, and a C engine that runs the
preprocessor's `#if`. A **scoreboard** in CI keeps the engines' scores against nimsuggest and clangd from going
down.

**ned's own plugins**, off until you turn one on — in the Plugins dock, under **AVAILABLE**: a tap shows what it
does, *Turn on*, *View its source*, *Copy to my plugins*. The [list](docs/plugins/available.md):
- editing: **dial** (Ctrl+A / Ctrl+X on numbers, dates, times, true/false), **case-change** (snake_case,
  camelCase … — vim's `crs`, `crc`), **split-join** (`gS`, `gJ`), **text-objects** (an argument, an indentation
  level, any quotes, a part of a name), **exchange** (`cx`), **align** (`ga`, Markdown tables too);
- moving around: **harpoon** (a few pinned files, one key each), **which-key** (after `g`, `z`, `<leader>`, C-x
  or helix's space: a box of what each next key does — tap one), **oil** (a folder as text: rename, delete and
  make files by editing lines, then save — ned asks first, deleted files go to a trash folder);
- tools: **json-to-nim** (Nim types from a sample of JSON), **rest-client** (`.http` files sent with curl),
  **path-complete**, **markdown-tools** (a table of contents, lists, checkboxes), **pomodoro**, **time-tracker**;
- languages: **Odin**, **Gleam**, **Elixir**, **Haskell** — colours, indentation, F5, snippets, an outline, and
  their language servers and formatters when installed.

**The Plugins menu** in the menu bar: the Plugins panel, ned's own plugins, a plugin's commands, turn one on or
off, uninstall, reload, update, install from git or from the list, a new plugin, the API. In the dock a plugin's
menu has *its settings*, *view its source*, *uninstall*; **+** adds one.

**The plugin API** grew for them: tabs of a plugin's own (`newTab` reused by title, `onSaveTab`, `markSaved`,
`setTitle`, `closeTab`), keys of one language (`keyIn`, `nmapIn`, `vmapIn`), which-key's (`onKeysWaiting`,
`showKeyHints`, `keyMaps`, mappings that say what they do), `onEnter` and `onQuit`, `shellAsync`, `unixTime`,
`clipboard`, `vimMode`; the language spec's lexer options (nested comments, strings over several lines,
`'a'` characters, Capitalised types, `@decorators`, doc comments, the characters of a name, dedent words such as
`end`); `setting()` in a plugin's top-level code; vim's visual selection as vim means it, plugin operators with
`gg` and `f{char}`, a mapping after an operator (`cxc`), whole-line text objects, ned's own `ip`/`ap`;
completions from plugins inside strings. `projectRoot()` is `projectDir()` without NimScript's clash.

**The Nim engine:**
- **The compiler as an oracle** (`nim.compilerOracle`): what the engine cannot work out by reading — a type a
  macro or a `when compiles` makes, which overload a call picks — is asked of the compiler after a pause, one
  nimsuggest run for the lines around the screen, which then quits. The answers are kept on disk by each line's
  text: the type hints have them, an overloaded call's hover says **Called here — the compiler's choice**, Go to
  definition goes straight to it, and the next time the file opens they are there at once.
- **Chain hints** (`nim.chainHints`): a call chain written over several lines shows the type after each step.
- **Checks while you type**: a `case` over an enum that leaves values out (Alt+Enter adds the branches), an
  argument that can never be the parameter's type (`twice("x")`), a method call whose value is dropped
  (`s.pop()`) — in the compiler's words, so its fixes apply.
- **Completion** ranks what you chose lately first (kept between sessions); the type wanted still counts.
- **Rename** reaches `{name}` in `fmt"…"` and `&"…"` strings, `` `name` `` in doc comments, and your other
  packages (a workspace's folders, `nimble develop`'s).
- A generic routine's instance on hover (`T = int`) also for a call over several lines.

**The C engine** (ned's own, no clangd needed):
- **`#if` worked out** as the compiler would: `-D` and `-U` from `compile_commands.json`, the file's and its
  headers' `#define`s, and the compiler's own macros (`__linux__`, `_WIN32`, `__GNUC__` …, asked once of `cc -dM
  -E`). A branch left out is dimmed and declares nothing: of a function in both branches of `#ifdef _WIN32`, you get
  the one compiled here.
- **Declarations macros make**: `DECLARE_GETTER(width, int)` declares `get_width` — completed, hovered ("declared
  by the macro DECLARE_GETTER"), F12 to the macro's use; `#define Node struct node` gives `head->` the members.
- **Checks while you type, without a compiler** (`c.engineChecks`): an `#include` nothing of which is used
  (*Remove the #include*), a struct that takes less room with its fields ordered by size (*Order the fields*),
  printf and scanf formats against their arguments (*Use %f*, *Pass &n*).
- **C++**: an overloaded function or method's call goes to, hovers and helps with the overload its arguments fit;
  a class template's explicit or partial specialisation is gone to, hovered and completed from.
- Against clangd 18 (definitions · hover with the same parameters): OpenSSH 91.1% · 94.7% (from 84.2%), tinyxml2
  87.8% (from 80.8%) · 95.9% (from 82.6%), LevelDB 93.8% · 98.9%.

**Indent and unindent** wherever you look: *Indent lines* and *Unindent lines (outdent, dedent)* in the Edit menu
and the palette, ⇤ (and with `indent` in `ui.touchBarKeys`, ⇥) on the touch bar, Tab and Shift+Tab, vim's `>>` `<<` and,
in insert mode, Ctrl+T and Ctrl+D.

**The scoreboard** (`tests/engine/scoreboard.py`, in CI on every push): the Nim engine and nedls against
nimsuggest on standard-library modules, the C engine against clangd on Lua's sources — each score against its
minimum. Today's:

<!-- scoreboard -->
| | score | at least |
|---|---|---|
| nim: type hints, the same as nimsuggest's | 99.6% ✓ | 98% |
| nim: go to definition, the same place | 100.0% ✓ | 98% |
| nim: a variable's type, the same | 98.7% ✓ | 97% |
| nim: member completion, ned | 98.4% ✓ | 96% |
| nim: member completion, nimsuggest (not checked) | 70.9% |  |
| nedls: completion: the name offered | 100.0% ✓ | 98% |
| nedls: hover: its doc comment | 100.0% ✓ | 97% |
| nedls: hover: the same declaration | 98.9% ✓ | 97% |
| nedls: hover: there | 100.0% ✓ | 98% |
| nedls: signature help: the routine | 100.0% ✓ | 97% |
| c: go to definition, the same as clangd's | 93.5% ✓ | 90% |
| c: member completion, ned | 96.9% ✓ | 95% |
| c: member completion, clangd (not checked) | 96.9% |  |
| c: hover, the same parameters | 94.4% ✓ | 92% |
<!-- /scoreboard -->

---

## Features

**Desktop-style UI in the terminal** — title bar with menus (F10), command palette (Ctrl+E, over 200 commands,
most-used first), left dock (files, search & replace, git, Nim, tests), right dock (AI assistant, outline,
timeline), bottom panel (problems, output, terminal), tabs, breadcrumbs, minimap, sticky scroll, indent
guides, rainbow brackets, tooltips, toasts, modal dialogs, context menus (right click), drop shadows,
hover effects, 50 themes (VS Code dark/light, One Dark, Tokyo Night, Catppuccin, Gruvbox, Dracula, Nord,
Solarized, GitHub, Rosé Pine, Kanagawa, Ayu, Monokai, Modus, Slate, Monochrome, Everforest, Night Owl, from
vim Molokai, Jellybeans, Iceberg, Sonokai and PaperColor, and ned's own: Nim Crown, Frankincense, Desert Dusk,
Lagoon, Sea Glass, Paper Ink, Rose Quartz, Amber CRT and Green Phosphor …)
— or `auto`, following the terminal's background or the time of day, your own colours (a theme editor that
checks contrast), VS Code or base16 themes imported, and Termux's own colours set to match —
three icon sets (unicode, Nerd Font, ASCII), phone layout below 70 columns, an accessibility mode (ASCII, letters
beside colours, high contrast), multi-root workspaces (git for each folder), remote folders over SSH (git, Run
and the assistant's commands on the server; its changes come back by themselves), settings sync. → [Themes and appearance](docs/guide/themes.md) · [Key bindings](docs/guide/keys.md) · [Settings](docs/guide/settings.md)

**Editing** — multi-cursor (Ctrl+D, Alt+A, Alt+J/K), selection that grows by the code's structure (a name, the
call, the statement, the block, the routine), surround (brackets, quotes, a tag, a block — and vim-surround), an
undo tree (Undo history… with the text at each state), next-edit suggestions (a rename's next place: Tab, Tab),
move/duplicate lines, toggle comment, folding, snippets for Nim, Python, C, C++, JS/TS, Rust, Go, HTML and shell (plus your own),
completion, auto-pairs, smart indentation, soft wrap, split editor, bookmarks, regex find/replace, sort/join/
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
in their dock, progress and output, vim mappings, operators and text objects, timers — the NimScript ones in one
process, a dock to manage them, a list to install from. → [Plugins](docs/plugins/README.md) · [Tutorial](docs/plugins/tutorial.md) · [API reference](docs/plugins/api.md)

**Languages** — syntax highlighting for Nim, C, C++, JS/TS, Rust, Go, Python, Kotlin, C#, PHP, SQL, Java, Lua,
Ruby, shell, Markdown, JSON, YAML, TOML, HTML, CSS, Makefiles, diffs, Nim templates (`.nimf`) and more — and your
own (`languages`); code inside strings and Markdown code blocks in its own colours (C in `{.emit}`, SQL, HTML,
regular expressions); any language server (configure in `lsp`) with type definition, implementation and type
hierarchy, document links, pull diagnostics and formatting as you type — and a second one beside it (a linter such
as ruff), their problems and fixes merged; formatters per language; debugging through the Debug Adapter Protocol (Python, C, C++, Rust, Go, JS/TS …) with logpoints and
stops when a value changes; tests for pytest, go
test, cargo test, PHPUnit, dotnet test and Gradle/Maven; coverage for **Nim**, Python, Go, Rust, JS/TS and any lcov file;
Send to REPL with `# %%` cells; Emmet for HTML and CSS; **ned's own CSS, HTML, SQL and JavaScript** — completion,
hover and problems in their files and in Nim strings (and a page's `<script>`s), with your project's class names,
tables and columns, the `?` of a query counted against the values it is given, a script's classes and the
browser's globals (`web.engine`). → [Running, testing and debugging](docs/guide/run-and-debug.md) · [Settings](docs/guide/settings.md) · [Formatting](docs/guide/formatting.md)

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
share of the time beside it, quick fixes from the compiler's messages, AI fixes checked by `nim check`, REPL (Shift+Enter sends code to inim), docs lookup, run configurations, what a
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

### Termux (Android)

```sh
pkg install nim git ripgrep curl            # nim to build; the rest is optional but recommended
nim c -d:release --opt:speed -d:strip -o:$PREFIX/bin/ned src/ned.nim
ned --check                                 # what ned found, and how to add the rest
ned
```

or, from the project folder: `nimble termux` (ned, with `nedfmt` and `nedls` beside it) — or the ready-made package
of a release, `pkg install ./ned_6.25.0_aarch64.deb` (ned, nedls, nedfmt; the example plugins in
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

The release's `ned-6.25.0-windows-x86_64.zip` has `ned.exe`, `nedfmt.exe` and `nedls.exe`, ready to run: unzip
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

MIT — see [LICENSE](LICENSE).
