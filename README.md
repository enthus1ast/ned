# ned

**A fast, safe code editor and Nim IDE for Termux and Linux.**
It runs in any terminal but looks and behaves like a desktop editor: menus, docks, tabs, split panes,
mouse and touch support, dialogs, toasts and tooltips. It is written in Nim, uses only the standard
library, and builds to one binary of about 9 MB.

![Member completion from the built-in Nim engine, with the documentation beside the list (nim-crown theme)](screenshots/completion-docs.png)

![Hover from the built-in engine: signature, documentation and where it is defined](screenshots/hover-docs.png)

![Split panes: each with its own header bar, divided by a solid bar](screenshots/split-panes.png)

![A nimble project with the Files dock, inlay hints and the assistant explaining the file](screenshots/nimble-ai.png)

![Project-wide replace with its preview in the Search dock, the editor split in two](screenshots/split-and-replace.png)

![Nim dock with one nimsuggest, and an AI edit waiting for approval as a diff](screenshots/ai-diff-approval.png)

---

## Contents

- [What's new in 6.15](#whats-new-in-615) · [6.14.1](CHANGELOG.md#whats-new-in-6141) · [6.14](CHANGELOG.md#whats-new-in-614) · [6.13](CHANGELOG.md#whats-new-in-613) · [older releases](CHANGELOG.md)
- [Features](#features)
- [Installing](#installing)
- [First steps](#first-steps)
- [Key bindings](#key-bindings)
- [Nim IDE: the built-in engine](#nim-ide-the-built-in-engine)
- [C: ned's own engine](#c-neds-own-engine)
- [AI assistant](#ai-assistant)
- [Search and replace](#search-and-replace)
- [Safety: how ned protects your work](#safety-how-ned-protects-your-work)
- [Settings](#settings)
- [Vim mode and zen mode](#vim-mode-and-zen-mode)
- [Files ned uses](#files-ned-uses)
- [Building, tasks and performance](#building-tasks-and-performance)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)

---

## What's new in 6.15

6.15 is about editing — selections that know the code, pairs put around it, an undo that loses nothing, the next
edit guessed, every git change in one place — and two more languages ned answers for itself: JavaScript, and C++.

**Select by the code's structure** (Alt+Shift+→, Alt+Shift+← back): from a name, its call, the call's argument, what
the brackets hold, the brackets, the member chain (`foo.bar(a).baz`), the value after `=`, the statement (over its
continuation lines), the block, the block with its header, the routine with its doc comment, the file — by the
text's brackets, quotes and indentation, so in every language (in C, a brace block's lines, then with the braces,
then the `if (…) { … }`).

**Surround** (Alt+Shift+S, *Edit › Surround*, the right-click menu): brackets, quotes, backticks or an element
(`<tag attrs>` — you type it) around each selection or the word under each cursor; around lines, a block of the
language: Nim's `if`, `when`, `for`, `while`, `block`, `try` (with its `except`), `try … finally`, a `proc`; Python's,
C's, JavaScript's, Go's, Rust's, shell's, Lua's and Ruby's own, Markdown's code fence — the lines indented, Tab
walking its places (`${1:cond}`). *Change the surrounding pair…* and *Delete the surrounding pair* (an element
too). In vim mode, as vim-surround: `ys{motion}{char}` (`ysiw"`), `yss)`, `cs"'`, `ds(`, `S{char}` on a visual
selection, `t` or `<` for a tag.

**The undo tree.** An edit after an undo no longer throws away what was undone: it stays, as a branch.
*Edit › Undo history…* (Alt+Shift+U) lists every state the file has been in, the newest first — what each step did
(*typed “size”*, *deleted “width”*), its line and how long ago, ↷ for the undone, ⑂ for a branch — with **the text
at that state beside the list**; Enter goes there (the edits you leave become a branch in turn). Vim's `g-` and
`g+` go back and forth in time across branches. The branches are kept with the file's undo history
(`editor.persistentUndo`).

![Undo history: every state of the file, the branch an edit after an undo left, and the text at the selected state](screenshots/undo-tree-615.png)

**Next-edit suggestions** (`editor.nextEdit`). Change a name — `width` made `size` — and the next place that still
says `width` shows *→ size ⇥*: Tab goes there (the word selected), Tab again makes the change and shows the place
after it — Tab, Tab… through the file; Esc says no. Whole words only (`widthy` stays). With the assistant set up,
`ai.nextEdit` asks the quick model where an edit with no repeat leads (*→ 2.0 ⇥ (AI)*).

**Git › Changes…** (Alt+Shift+G): every change not committed, in every file, in one editable multibuffer — each
with a line around it, its header saying what it adds and removes and whether it is staged (*+3 −2 · not staged*,
*partly staged*, *new file*), the change marks in the gutter. Edit there and Ctrl+S writes each piece back to its
file; the right-click menu (or the palette) stages, unstages or reverts the change at the cursor — revert puts
back the last commit's text and unstages it — and the view is made again, the cursor where it was. Enter on a
header opens the file there. *Git: unstage this change* is new for any file too.

![Git › Changes: every change in one editable view, staged or not](screenshots/git-changes-615.png)

**JavaScript — ned's own** (`web.engine`; a JavaScript language server, when installed, answers instead), in .js
files, an HTML page's `<script>`s, Nim strings (`js"""…"""`, emits with `nim.backend` js):

- **Completion**: after `.` the members of what is before it when the engine can tell — a class of the file (its
  methods, fields set by `this.x = …`, inherited ones, `#private` ones; its statics after `Point.`), `this.` and
  `super.`, the browser's and Node's globals (`document.`, `Math.`, `console.`, `localStorage.` …), and values it
  recognises: strings, arrays, `new X()`, an element from `querySelector`, `classList`, a `fetch` Response, a
  Promise, an object literal's keys; elsewhere the names in scope (the nearest first), keywords, globals. Nothing
  in strings and comments, but `${…}` in a template literal is code.
- **Hover** with the signature and a line of documentation (and the MDN or Node.js page); **F12** to a
  declaration, a method of the file's classes too.
- **Problems**: a bracket or `${` never closed, a name declared twice in a scope, an assignment to a `const` or an
  import, a name nothing declares one letter off one that is (*did you mean 'card'?*), an unused function, `let`,
  `const` or import (in a module), `==` with a literal — rules `js-brace`, `js-redeclare`, `js-const-assign`,
  `js-typo`, `js-unused`, `js-eqeq`. Checked on 1,223 real files (174,000 lines): no false alarms.
- `ned --lint app.js style.css page.html query.sql`: ned's own checks of those languages, for files named on the
  command line.

**C++ — ned's own C engine reads it** (in `.cpp`/`.cc`/`.hpp` files, a `.h` with classes in it, and emits when
`nim.backend` is cpp): classes and structs with their bases, methods in the class or outside it
(`Ret Class::method`), constructors, operators, namespaces (nested, `inline`, anonymous, `using namespace`),
templates (`Box<Point>` gives `value` the type `Point`), references, `auto`, `enum class`. **Completion** after `.`
and `->` — inherited members too, through `auto`, references, templates and smart pointers (`p->` on a
`unique_ptr<T>` lists T's) —, after `::` a namespace's names, a class's members or an enum's constants, a class's
members inside its methods (and after `this->`), and `std::`'s common names with what they are. **Hover and F12**:
a method's body outside its class first, then its declaration, and back. Errors while you type from
`c++ -std=c++17`; the outline puts members under their class; `#ifdef __cplusplus` branches are live. 823 real C++
files (libstdc++, and others) read in 0.44 s together. Overloads are all listed (not resolved), and `decltype`,
concepts and template specializations are not understood — clangd is still used first when installed.

**The showcase** (`examples/showcase.nim`) has a section for all of this: a proc to select by structure, surround,
rename and undo in, the JavaScript in its strings with a misspelled name, and how an emit becomes C++.

Tip: the formatter wraps at `nim.format.lineLength` (88 unless your settings or `.editorconfig` say otherwise). A
ruler at another column (`"editor.rulers": [80]`) does not move it: `"editor.rulers": ["lineLength"]` puts the
ruler where the formatter wraps, or set `"nim.format.lineLength": 80`.

Older releases are in [CHANGELOG.md](CHANGELOG.md): [6.14.1](CHANGELOG.md#whats-new-in-6141) kept scrolling
smooth with reference counts and gave quick fixes keys Windows Terminal leaves alone, [6.14](CHANGELOG.md#whats-new-in-614)
made ned faster where you wait and brought its own CSS, HTML and SQL, [6.13](CHANGELOG.md#whats-new-in-613) made the running ned
reachable from its terminal, git and scripts and asked the terminal what it can do, [6.12](CHANGELOG.md#whats-new-in-612) brought Nim 3
(Nimony), the hex editor and big files in less memory, [6.11.2](CHANGELOG.md#whats-new-in-6112) fixed the ▶ of runnableExamples,
terminal floods and very long lines, [6.11.1](CHANGELOG.md#whats-new-in-6111) wrapped long comments and
kept type hints ahead of scrolling, [6.11](CHANGELOG.md#whats-new-in-611) made scrolling send only the new lines and
the engine's checks wait for a pause, with Help › Performance, [6.10](CHANGELOG.md#whats-new-in-610) brought lint
rules and `--fix`, *can be a func*, the project's own checks and Nim test coverage,
[6.9](CHANGELOG.md#whats-new-in-69) hints the compiler does not give, memory layout on hover and `ned --lint`,
[6.8](CHANGELOG.md#whats-new-in-68) nedls and nedfmt, the engine's own checks at once and names a macro makes,
[6.7](CHANGELOG.md#whats-new-in-67) signed in to GitHub without a password and brought AI that knows your code,
[6.6](CHANGELOG.md#whats-new-in-66) showed where ARC/ORC copies, ran tests on save and added postfix completion,
[6.5.1](CHANGELOG.md#whats-new-in-651) fixed C wrappers written one parameter a line,
[6.5](CHANGELOG.md#whats-new-in-65) brought ned's own C engine and ligatures, [6.4](CHANGELOG.md#whats-new-in-64) took
the Nim engine further (parameter names, a generic's instance, organize imports), [6.3](CHANGELOG.md#whats-new-in-63)
explained C from Nim and gave the formatter your settings, [6.2](CHANGELOG.md#whats-new-in-62) a calmer, desktop-like
look, [6.1](CHANGELOG.md#whats-new-in-61) smarter colours, [6.0](CHANGELOG.md#whats-new-in-60) split ned into a
project with its tests.

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
and the assistant's commands on the server; its changes come back by themselves), settings sync.

**Editing** — multi-cursor (Ctrl+D, Alt+A, Alt+J/K), selection that grows by the code's structure (a name, the
call, the statement, the block, the routine), surround (brackets, quotes, a tag, a block — and vim-surround), an
undo tree (Undo history… with the text at each state), next-edit suggestions (a rename's next place: Tab, Tab),
move/duplicate lines, toggle comment, folding, snippets for Nim, Python, C, C++, JS/TS, Rust, Go, HTML and shell (plus your own),
completion, auto-pairs, smart indentation, soft wrap, split editor, bookmarks, regex find/replace, sort/join/
case transforms, line-ending and indentation conversion, format on save (built in for Nim, JSON, Markdown, CSS,
HTML, SQL, YAML and TOML; a whole project at once; or only the lines you changed, and a preview first), jump labels
(Alt+Shift+J), a preview beside the file and symbol pickers,
rulers at the columns you choose or where the formatter wraps (`"editor.rulers": ["lineLength"]`; long lines tinted), colour swatches, `.editorconfig` support (its `max_line_length` is the formatter's too), spell check,
CSV and TSV files as tables (columns lined up, sort by a column, a column's sum and mean), large-file mode, a 3-pane merge editor, keyboard macros, vim, Emacs and Helix key bindings, operator ligatures
(`editor.fontLigatures`: drawn by ned in any terminal — `─→ ═⇒ ≠ ≤ ≥` — or kept whole for a ligature font).

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
browser's globals (`web.engine`).

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
show what porting them needs, fixed one by one, all at once, or by the assistant checked with nimony.

**C and C++** — ned's own C engine, no clangd needed: completion (struct members after `.` and `->` too; C++
classes with their bases, methods, namespaces after `::`, templates, `auto`), hover with the comment that documents
a declaration, go to definition through `#include`s (a C++ method's body outside its class), references, rename,
signature help, the outline, the compiler's errors while you type and a missing `#include` added — in emits too
(C++ when `nim.backend` is cpp); clangd when you prefer it.

**Hex editor** — binary files as offset · hex · text, typed over or inserted, undo, find bytes or text, go to an
offset, a data inspector, copy as hex, a Nim array or a C array; programs and libraries (ELF, Mach-O, PE) with their
sections and symbols — Nim's procs by their Nim names, the bytes each module takes, a proc's Nim source.

**Integrated terminal** — a real pty with an xterm-compatible emulator: vim, htop, less, git, ssh all work;
several terminals (two side by side), scrollback, mouse, selection and copy; with bash, zsh and fish every command
is marked — Ctrl+↑/↓ go through them, failed ones show red, a command's output can be copied or it can be run again.
`ned FILE` there opens FILE in this ned, and this ned is git's editor (`git commit` opens the message in a tab).

**Remote control** — scripts reach the running ned: `ned --remote FILE:LINE`, `--remote-command`,
`--remote-message`, `--remote-problems` (a build's output → Problems), `--remote-get`, `--remote-list`;
`ned --wait` as `GIT_EDITOR`.

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
merge, and checks before a commit (formatted, tests passing).

**AI** — chat and agent (read, search, edit files, run commands — you approve edits and commands; its edits are
checked with `nim check` and the like, and it is told what is wrong), a plan first and then each step with a
restore point, tests it writes kept only when they pass, a failing test made to pass (kept only when it does),
answers grounded in the declarations your code uses, inline edit of a selection (Alt+Shift+C), undo of the agent's
changes, token and cost counter, AI review of staged changes, a local model on the device (Ollama or llama.cpp,
set up for you: offline on a phone too), MCP servers for more tools, their prompts (/server:prompt) and resources (@server:uri); Anthropic, OpenAI, OpenRouter, Ollama, Groq, DeepSeek, Gemini, Mistral or any
OpenAI-compatible endpoint.

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

or, from the project folder: `nimble termux` (ned, with `nedfmt` and `nedls` beside it).

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

### Windows (WSL)

ned is a Unix terminal program, so on Windows it runs inside **WSL** (Windows Subsystem for Linux) — the Linux
build, in Windows Terminal:

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
and arm64), macOS (Apple silicon and Intel), Termux (aarch64) and Windows through WSL, runs it in a real
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

## Key bindings

In Termux, Alt comes from the extra-keys row (or a hardware keyboard). Every binding is listed in **F1** and in the palette, and you
can add your own (see [Settings](#settings)).

### Window and layout

| keys | action |
|---|---|
| F10 | menu bar (while debugging: step over — Shift+F10 opens the menus) |
| Ctrl+E / Alt+X | command palette |
| Ctrl+B | left dock (Files · Search · Git · Nim · Tests; Tab cycles) |
| Alt+C | AI assistant (right dock) · Alt+I outline |
| Ctrl+\\ / Alt+` | integrated terminal · Alt+O bottom panel |
| Ctrl+↑ / Ctrl+↓ (in the terminal) | the commands you ran · Alt+Enter: its output, run it again … · Ctrl+PgUp/PgDn the other terminal |
| Alt+\\ | split the editor / switch panes · Alt+\| close the split |
| Ctrl+Alt+←/→ · ↑/↓ | resize the split or the focused dock · the bottom panel (↑ taller) · ⤢ or *Toggle maximized panel* fills the window with it |
| F6 / Shift+F6 | move focus editor → docks → panel |
| Alt+Z | zen mode (Esc Esc leaves) |
| Alt+T | themes (live preview) · Alt+W soft wrap · Alt+L line numbers · Alt+U mouse on/off |
| right click | context menus (editor, files, tabs, git, search results, terminal) — on touch: press and hold |
| drag | split divider, dock edges, the bottom panel's header, the scrollbar, the minimap, a tab (reorder) |
| wheel | scroll · Shift+wheel or tilt wheel: sideways · over the tabs: switch tabs |

### Files and navigation

| keys | action |
|---|---|
| Ctrl+P / Ctrl+O | find file (`:` line · `@` symbol · `#` project symbol · `>` command) |
| Ctrl+N · Ctrl+W | new file · close tab |
| Ctrl+S · Ctrl+Q | save · quit (asks about unsaved files) |
| Alt+← Alt+→ · Ctrl+PgUp/PgDn · Alt+1..9 | switch tabs |
| Ctrl+G | go to line[:col] · Ctrl+T symbol in file |
| Alt+. / F12 / Ctrl+click | go to definition · Alt+, jump back · Alt+< go forward |
| Alt+F12 · Alt+Shift+F12 | peek definition · peek references |
| Alt+Shift+T | reopen the last closed tab |
| Alt+Shift+J | jump labels: a letter over every word on screen, type it to go there |
| Alt+Q / Shift+F12 | find all references |
| Alt+H | hover info (also automatic) |
| Alt+N / Alt+P / F8 | next / previous problem |
| Alt+' | toggle bookmark · Alt+; next · Alt+: previous |
| Alt+V / Alt+Shift+V | next / previous TODO · FIXME · BUG · HACK · NOTE comment (View › TODOs lists and counts them) |
| F7 / Shift+F7 | next / previous git change · click the branch in the title bar: branches · ⟳ sync |

### Editing

| keys | action |
|---|---|
| Ctrl+Z / Ctrl+Y | undo / redo |
| Ctrl+C / X / V | copy / cut / paste (whole line when nothing is selected) |
| Ctrl+A · Ctrl+L | select all · select line |
| Ctrl+D · Alt+A | next occurrence · all occurrences (multi-cursor) |
| Alt+J / Alt+K · Alt+Shift+↑↓ | add cursor below / above · Esc back to one cursor |
| Alt+click · Alt+drag | add a cursor · box (column) selection |
| Alt+Shift+→ / ← | grow / shrink the selection by the code's structure (name, call, argument, statement, block, routine) |
| Alt+Shift+S | surround: brackets, quotes, a tag or a block around the selection (*Edit › Surround* also changes or deletes a pair) |
| Alt+Shift+U | undo history: every state of the file, the undo tree's branches too, with the text there |
| Tab on a → … ⇥ hint | next edit: to the place, then the same change there (Esc: no) |
| Alt+Shift+G | Git › Changes: every change not committed in one editable view |
| Alt+↑ / Alt+↓ · Alt+D | move line(s) · duplicate |
| Alt+Shift+R · Alt+Shift+M | record a keyboard macro (again: stop) · play it — *Edit › Macros* for N times, each line, saved ones |
| Ctrl+K · Ctrl+/ | delete line(s) · toggle comment |
| Alt+- / Alt+= | fold / unfold (or click ▾ ▸) |
| Tab after a keyword | snippet (Tab / Shift+Tab walk the fields) |
| Ctrl+Space | completion |
| Alt+F | format document (with lines selected: just those) · F2 rename symbol |
| Alt+Enter · Ctrl+. | quick fixes (Nim: fixes for the compiler's errors and warnings, missing case branches, generate $/==/hash, doc comment, run selection, debug this test) — also the right-click menu and Edit › Quick fix…; Windows Terminal keeps Alt+Enter for full screen: there Alt+Shift+Enter |
| F2 | rename — a preview lists every change first (Space unticks, Enter applies) |

### Search

| keys | action |
|---|---|
| Ctrl+F | find (Enter next · Shift+Enter previous · Alt+C case · Alt+W whole word · Alt+R regex) |
| Ctrl+R | replace — then Yes / No / All / Done (y n a q) |
| F3 / Shift+F3 | next / previous match |
| Alt+S | search the project (Search dock) |
| Alt+H (in the Search dock) | show the replace box · Alt+Enter replace all · Tab moves between boxes |

### Run, test, debug

| keys | action |
|---|---|
| Alt+R / F5 | run the current file · Alt+B / Shift+F5 build or check |
| F9 · click the gutter's left edge | toggle a breakpoint (then F5 starts the debugger) · palette: conditional breakpoint, logpoint, stop when this changes |
| F5 · F10 · F11 · Shift+F11 · Shift+F5 | while debugging: continue · step over · step in · step out · stop |
| in the Debug panel | Enter on ▸ expands a variable · *+ add a watch expression* · Enter on a watch (or a *stop when it changes*) removes it |
| Ctrl+F10 | debugger: run to cursor (starts debugging if needed) |
| ▶ in the gutter | run a test, a suite, `when isMainModule`, a nimble task |
| Alt+Y | nimble tasks · Alt+E Nim dock |
| palette | Debug: … · Nim: debug with gdb (in the terminal) · Run tests in file · Run all tests · Stop |

### AI

| keys | action |
|---|---|
| Alt+C | chat (Enter sends, Alt+Enter new line, ↑ history, Ctrl+L new chat, Esc stops) |
| Alt+Shift+C | edit the selection — or the enclosing block — with an instruction |
| y · a · n | allow · always allow · deny an agent action |
| Tab (in the chat box) | complete a `/command` or `@mention` |
| Tab (in the editor) | accept an inline suggestion (when enabled) · Esc dismisses it |

### Hex editor (a binary file)

| keys | action |
|---|---|
| 0-9 a-f · any key | type over a byte in the hex column · in the text column |
| Tab | hex column ⇄ text column |
| Insert | insert mode (typing adds bytes) ⇄ overwrite |
| Delete · Backspace | take bytes away (Backspace: the one before, in insert mode) |
| Shift+arrows · Ctrl+A | select bytes · all of them |
| Ctrl+C · Ctrl+X · Ctrl+V | copy as hex (as text in the text column) · cut · paste hex (`de ad`, `0xde, 0xad`) or text |
| Ctrl+G | go to an offset: `8000`, `0x1F40`, `1f40h`, `+16`, `-0x10` |
| Ctrl+F · F3 · Shift+F3 | find bytes (`de ad be ef`) or text (`"abc"`) · the next · the one before |
| Ctrl+Z · Ctrl+Y · Ctrl+S | undo · redo · save |

Palette: *Hex: symbols…*, *Hex: sections…*, *Hex: Nim modules by size*, *Hex: open the Nim source of the proc at the
cursor*, *Hex: copy as a Nim array / a Nim string / a C array*, *Hex: show as text*.

## Nim IDE: the built-in engine

ned 5 understands Nim itself. Its index reads your files, the standard library and your nimble packages
as you work. It answers completion, hover, go to definition, signature help, references, rename, the
outline and symbol search immediately, with no compiler run and no server process.

**How it finds things.** Imports are resolved like the compiler resolves them:
1. next to the importing file;
2. `std/…`, and the search paths that `nim dump` reports for your project (so `--path` lines in
   `config.nims` and `nim.cfg` count);
3. the package's `srcDir`, so tests and examples can `import mypkg`;
4. the newest installed version of each nimble package, including `nimbledeps/` and atlas `deps/`.

`export`, `include`, `from … import`, `except` and `import … as` are followed. A file that another one
`include`s sees what its includer sees: the includer's imports, its declarations and its other include files
(the includer is looked for in the file's folder and the one above). `when` branches are evaluated for your
platform and for what your project's config defines (`nim dump` lists it, so a symbol it leaves out is false). Names are compared style-insensitively, as Nim does. Your
open, unsaved buffers count over the files on disk.

**How it knows types.** From declarations, literals and call results, through chains like
`t.getOrDefault(k).len`. Generics are filled in from arguments (`some(5)` is an `Option[int]`,
`initTable[string, int]()` a `Table[string, int]`, `convert(Seconds, Nanoseconds, x)` x's type) and through
aliases (`Vec2 = GVec2[float32]`, so `v.x` is a `float32`). It also handles:
- loop variables (`for k, v in t.pairs`, a type's own `items` and `pairs` iterators) and tuple unpacking
  (`let (a, b) = …`);
- object fields including inherited ones, `ref`/`ptr` dereferences (`t[]`), and `x{…}` / `x[…]`
  accessors;
- values over several lines (`let x = if c:` / `case k` / `try:` / `block:`, or on the line after `=`),
  aliases (`BiggestInt` is `int64`) and conversions in every spelling (`x.float`, `fd.AsyncFD`, `BiggestUInt 1`);
- operators as Nim types them: `/` of integers is a `float`, `a .. b` an `HSlice`, `and`/`or` of integers an
  integer, `5 * x` x's type, `n - 1` of a `Natural` an `int`, `Time - Duration` a `Time`;
- overloads by their number of arguments and by all of their types (`sock.recv(10)` is a `string`,
  `recv(sock, buf, 10)` an `int`), and generic parameters by their constraints (`[T: SomeInteger]`);
- routines inside routines, an async proc's `result` (what its Future holds), a macro's `untyped` arguments
  (`NimNode`s);
- what a template of the file declares (`genVecConstructor(vec, Vec, float32)` makes `vec2`, `vec3` …);
- block scoping: a `let` in one `of` branch is not seen in the next;
- generic objects built with or without their arguments (`Box[int]()`, `Box(val: "x")` is a `Box[string]`), a
  generic routine's instance on hover (`T = int`), what a concept asks of a value of its type, statements after `;`.

**Type hints.** A `let`, `var` or `const` written without a type shows it after its name, in grey:
`let n: int = parseInt(s)`. The engine works them out 16 lines at a time, those on screen first, then ahead of
where you scroll — in a few milliseconds a round, so they are there when the lines come in — and once for each
version of the text: scrolling back works nothing out again. Calls show
their parameters' names before literal arguments — `draw(width: 10, height: 20, filled: true)` (`nim.parameterHints`:
`literals`, `all` or `off`).
`"nim.typeHints": "nimsuggest"` asks nimsuggest instead (when it is turned on); `"editor.inlayHints": false` turns them off.

**What completion offers:**
- After a `.`: the receiver's fields first, then the procs that take it exactly, then related ones
  (subtypes, `openArray`, wider numbers), then generic ones.
- A bare name: locals, then this module, then imports, then `system`, then keywords.
- `Foo(` lists `Foo`'s fields as `name: `, and after `import` it offers module names.
- Overloads are folded into one entry; the documentation lists every signature.

**How good it is.** The same questions to ned's engine and to nimsuggest, on 23 files of the standard library,
nimble packages and the compiler (see [What's new in 5.25](CHANGELOG.md#whats-new-in-525) for the list):

| | ned's engine | nimsuggest |
|---|---|---|
| type hints: the same as nimsuggest's | 99.3% | — |
| go to definition: the same place | 98.9% | — |
| a variable's type: the same | 98.6% | — |
| member completion: the member written there is offered | 98.9% | 74% |
| time for one question | 0.6 ms | 250 ms |

Where nimsuggest answers with a name it made up itself (a gensym'd symbol, an `:anonymous` proc) it counts as no
answer. What still differs is mostly where both answers are defensible (a name a template call declares: ned goes
to the call, nimsuggest into the template; a union-typed parameter, where nimsuggest reports the instance it
compiled), how a type is printed (an alias kept or expanded: `Fixed32` or `int32`), code in `when` branches that are
false here, and nimsuggest answers that point at another symbol on the line. The engine knows chronos' futures that
carry what they raise: a call of an `{.async: (raises: [A, B]).}` routine is an `InternalRaisesFuture[T, (A, B)]`,
as its macro makes it, and so is `Future[T].Raising([A, B])`. The comparison is in [tests/engine](tests/engine):
`tests/engine/build.sh && tests/engine/compare.py file.nim` runs it on your own code.

**Errors.** While you type, the compiler checks the unsaved text after a pause (`nim check`, reading it from
stdin in the file's folder: same imports, same config); a misspelled name is marked at once by the engine. On
save, `nim check` runs on the file. See [What's new in 5.26](CHANGELOG.md#whats-new-in-526).

**The engine's own checks, at once** (`nim.engineChecks`, on by default), half a second after you stop typing and
before the compiler's check: a field name that is a typo of one the object has (`p.lable` — *did you mean
'label'?*), a call with the wrong number of arguments for every routine of that name in scope, a call whose value is
neither used nor discarded, a literal that can never be the declared type (`let n: int = "3"`), an import nothing in
the file uses, code after a `return`, `raise`, `break` or `continue` in the same block, and a local `let`/`var`
nothing uses. The messages are the compiler's own, so the same quick fixes apply (Alt+Enter: discard the value,
remove the import). Only what the engine can be sure of: not inside templates and macros or what they are given,
not where an overload the engine cannot see could be the one called, not an import whose `$` or `==` code here might
call without naming it, not in `when` branches left out. On Nim's own compiler and standard library (463 files) and
563 files of 19 nimble packages they report nothing the compiler would not — apart from a few mistakes in generic
code nothing instantiates, which the compiler never looks at; the compiler's word wins on any line where both say
something.

**Hints the compiler does not give** (`nim.engineHints`, on by default, with `nim.engineChecks`): a `var` nothing
changes afterwards — not assigned, not given to a `var` parameter, its address not taken, not touched by a template
or macro it is given to — *'limit' is never changed: it can be a let* (Alt+Enter makes it one, or every one in the
file); a parameter a routine of this module never uses (not an exported routine, a hook, an operator, an `importc`
or `exportc` one, a callback passed around, a stub, a typedesc that only picks the overload); a routine that never
sets its result, never returns a value and does not end in one (*it always returns the default value*); and a name
whose every declaration in scope is `{.deprecated.}`, in the compiler's own words so its quick fix (*Use newSum
instead*) applies. The var hints were checked on Nim's compiler and standard library: each of the 992 was made a
`let` and the file compiled again, with no new error (the few in files that do not compile on their own were read
by hand) — one of them is a loop in the standard library that never moves on.

**Can be a func** (with the hints above). A proc of this module with no side effects — it uses no module variable
(a `var`, `let`, threadvar or `{.global.}`) and calls nothing that has side effects (`echo`, I/O, a proc variable
not declared `{.noSideEffect.}`), as the compiler infers it — is marked *'add1' has no side effects: it can be a
func* (rule `can-be-func`). Alt+Enter makes it a func, or every one in the file; `ned --lint --fix:can-be-func`
does the same from the command line. Only when the engine is sure of every call; not on generic, forward-declared,
nested, importc/exportc/async procs, nor in a file built with strictFuncs. Each of the 1,797 hints on Nim's
compiler, standard library and 19 packages that could be checked was made a func and compiled again: no new error.

**Library names newer than your Nim** (`nim.minVersion`; empty: what the .nimble asks for). With `requires "nim >=
1.6.0"`, a standard-library name or module that Nim 1.6 does not have is marked: *'minmax' is not in Nim 1.6.20 or
older (Nim 2.0.0 has it)*, *module paths is not in Nim 1.6.20 or older*. It knows from a name's `{.since.}` and
from a table of what each release from 1.0 to 2.2.12 added (`.github/ci/nimapis.py` makes it from the releases'
libraries). Code inside a `when` that asks which Nim this is — `NimMajor`, `NimVersion`, `declared(…)`,
`compiles(…)` — is left alone. `"off"` turns it off.

**Memory layout** (`nim.memoryLayout`, on by default). Hover a type's name — where it is declared or where it is
used — and ned shows how it lies in memory: each field's offset, size and the padding after it, the total size and
alignment, as Nim's C code generator lays it out here (64-bit; 32-bit on i386 and ARM). Inheritance, case objects,
`{.packed.}`, `{.union.}`, `{.align.}` and generics given their arguments are followed; when ned cannot be sure
(importc types, unknown names, a `when` it cannot decide) it shows nothing. It matches the compiler's `sizeof`,
`alignof` and `offsetOf` for every one of 1,312 types of the standard library, the compiler and 19 packages. When
sorting an object's fields by alignment would make it smaller, Alt+Enter on its line reorders them, comments moving
with their field (*Reorder fields to save 8 bytes (32 → 24 B)*).

**Exception hints** (`nim.raisesHints`, off by default; View › Editor › Exception hints). A routine without a
`{.raises.}` of its own shows what it can raise before the `=` of its header — `{.raises: [IOError, OSError].}` —
as the engine works it out: its `raise` statements and the routines it calls, less what its `try … except`
catches. A hint appears only when the engine is sure of every call in the body; Defects are not listed, as in the
compiler's effects. Hovering a routine, or a call of it, shows the same list. Converters are counted too: one that
raises, applied where an argument or an assignment needs it, is listed; where ned cannot tell whether one applies,
there is no hint. For 1,422 routines compared with the compiler's `{.effects.}`, they agree.

**Concepts.** Hover a concept to see the project's types that satisfy it (*satisfied by: `Circle`, `Square`*),
hover a type to see the concepts it satisfies; *Go to implementation* on a concept lists those types. The new
syntax (routines on `Self`) is matched as the compiler matches it, the old one (`concept x, y`) in its common forms
(`x.f is T`, `f(x)`, `x < y is bool`, `x.field`, `x[i]`, `$x`). A type is listed only when ned is sure: for 700
answers compared with the compiler's `T is C`, they agree.

**The package versions your build uses.** The engine reads each nimble package in the version your project builds
with: the package folders your config puts on the path (nimble.paths, atlas' nim.cfg), then the versions
nimble.lock pins, a local `nimbledeps/` or atlas `deps/`, then the newest installed version that meets the
`requires` of your .nimble and of those packages in turn. Only a package nothing asks for uses the newest
installed. Each open project has its own versions, and the Nim dock shows each requirement's version and why, e.g.
`jsony 1.1.5 (nimble.lock)` (also *Nim: language server status*); *Nimble: dependency tree* shows the same versions
as a tree, each package under what requires it, with what that version requires in turn.

A folder counts as a package only when nimble or atlas made it: under your toolchain's package folders (NIMBLE_DIR,
what `nim dump` reports, the open project's `nimbledeps/` and `deps/`), a nimble folder name with its checksum
(`pkgs2/jsony-1.1.5-<sha1>`), `.nimble/pkgs/name-1.2.3`, a project's `nimbledeps/pkgs2/…`, or the `deps/` of a
project atlas set up (its `nim.cfg` section or `atlas.config`). A folder of yours that is merely called `deps`,
`pkgs` or `pkgs2` is read as your own code, with your project's versions.

**Completion by the expected type.** Where the code expects a type — a call argument (also when the call is
written over several lines), a parameter's default in a routine's header (`proc p(c: Color = `), `let x: T = `, `x = `,
`result = `, `return `, a comparison, a field in `Foo(name: …)` — completion lists what has that type first:
values, enum values, fields and routines returning it, subtypes and numbers that convert without a cast included.
The rest stays in the list behind them. After `p.` in such a place, p's members of that type come first.

**The index's memory** (`nim.indexMemory`, 64 MB by default, 0 for no limit). The engine counts what its parsed
files take and keeps them under the budget: above it, the files asked about least recently and not open are
dropped and read again when needed (a library file comes back from the index cache in a few ms). On the whole Nim
repository, a 16 MB budget holds the process at 23 MB instead of 40 MB.

**The compiler's answer, once** (`nim.compilerAnswers`, on by default). With nimsuggest off (the default), a
hover or *Go to definition* the engine has no answer for — a name a macro makes, say — asks the compiler once: one
nimsuggest run for that question, which then quits, so its memory goes with it. The answer is kept until the file
changes; your unsaved text goes to it as a private copy, deleted after.

**Names a macro makes** (`nim.macroNames`, on by default). `makeProcs(Foo, Bar)` at the top of a module declares
`getFoo` and `getBar`, which no reader of the text can see: the compiler expands the file's top-level macro calls
once, in the background (`nim check --expandMacro`, your unsaved text as a private copy, deleted after), and the
project files it imports are expanded the same way. What the expansions declare — routines, types and their fields,
constants — is then known to completion, hover (which says which call made it), signature help and *Go to
definition* (which goes to the call). It runs again only when those calls change.

**The index on disk** (`nim.indexCache`, on by default). The engine's reading of the standard library and the
nimble packages is kept in `~/.cache/ned/index`, so a new session — ned's or nedls' — answers its first question
without parsing them again (the whole standard library comes back from the cache in a fifth of the time parsing
it takes). An entry is used only for the very text it was made from, by the same parser, with the same
defines; anything else is read afresh. The project's own files are kept too, as they are on disk
(`nim.indexCacheProject`): reopening a project of hundreds of files reads them instead of parsing them.

**Expansion.** Alt+M on a template call writes it out with the arguments in place (the engine, at once); on a
macro call, the compiler expands it (`nim check --expandMacro`). Hover on a template call shows the same.

**ned's engine and nimsuggest.** Since 5.28 nimsuggest is off by default; this is what each gives:

| | ned's engine (the default) | nimsuggest |
|---|---|---|
| completion, hover, signature help, outline | ✓ | ✓ |
| go to definition, references, rename | ✓ | ✓ |
| … of operators (`a + b`), of fields in constructors (`Vec(x: 1)`), of one overload | ✓ | ✓ |
| type definition, go to implementation, type hierarchy | ✓ | — |
| reference counts beside declarations | ✓ | — |
| type hints beside `let`, `var` and loop variables | ✓ | ✓ |
| errors while you type | `nim check` on the unsaved text | ✓ |
| template expansion · macro expansion | at once · `nim check --expandMacro` | ✓ · ✓ |
| quick fixes and code actions (fill in fields, write a forward declaration's body, generate `$`/`==`/hash) | ✓ | — |
| first answer in a 52 000-line file (ned 5.28's source) | at once | 12 s (it compiles the project first) |
| memory with that file open | 30 MB, the whole editor | 600 MB, nimsuggest alone |
| crashes during the comparison above (23 files) | 0 | 52 (started again each time) |

Turn nimsuggest on (`"nim.nimsuggest": true`, when it is installed — it comes with Nim) for a second opinion:
completion where the index cannot tell a receiver's type (inside macros, `auto` results), and errors while you
type in a big project whose `nim check` takes over 10 s. It is restarted past `nim.nimsuggestMaxMB` (1500 by
default).

**Settings.**
- `nim.ide`: `builtin` (the default), `nimlangserver`, or `off`.
- `nim.nimsuggest`: run nimsuggest for the extras above (off by default); `nim.nimsuggestMaxMB` caps its memory.
- `nim.typeHints`: where the type hints come from, `builtin` (the default) or `nimsuggest`.
- `nim.liveDiagnostics`: errors while you type (on by default); `nim.liveDiagnosticsFrom`: `auto`, `compiler`
  or `nimsuggest`.
- `editor.completionDocs`: documentation beside the list. Ctrl+Space toggles it while the list is open,
  Ctrl+↑/↓ scrolls it.
- *Nim: language server status* shows what the engine has indexed and which search paths and packages it
  uses.

### nedls: ned's engine in other editors

**`nedls`** is ned's Nim engine as a language server (LSP over stdin/stdout), for VS Code, Neovim, Helix, Zed,
Emacs, Kate, Sublime — instead of nimlangserver or nimsuggest. Its answers are ned's own: the same code the editor
runs, without its screen. `nimble install` builds it next to ned (or `nimble nedls`, or `nim c -d:release -o:nedls
src/nedls.nim`).

What it does: completion (with documentation, ned's snippets and postfix templates, the import it adds), hover,
signature help with every overload, definition, declaration, type definition, references, highlights, rename,
document and workspace symbols, semantic colours, inlay hints (types and parameter names), folding, formatting
(ned's formatter; a file it is not sure of gets no edits and a message), the quick fixes for the compiler's
problems (a missing std import, an unused one), and problems: ned's own checks at once, the compiler on the
unsaved text after a pause, `nim check` on save. Positions are UTF-8 when the editor offers it, else UTF-16.
It starts at about 6 MB, holds a big file with its imports in about 16 MB, and answers a hover in a few
milliseconds and a completion in about 20.

Settings (in the editor's `initializationOptions`, or under `nedls` in its settings): `inlayHints` (true),
`parameterHints` (`literals`, `all`, `off`), `raisesHints` (false: what a routine can raise, after its header),
`checkOnSave` (true), `liveDiagnostics` (true), `formatLineLength` (not given: `nim.format.lineLength`, else the
file's `.editorconfig`), `nedSettings` (true: your ned settings apply too). `nedls --lint` checks files from the
command line, as `ned --lint` does.

```lua
-- Neovim 0.11+
vim.lsp.config('nedls', { cmd = { 'nedls' }, filetypes = { 'nim', 'nims', 'nimble' },
  root_markers = { 'nim.cfg', 'config.nims', '.git' } })
vim.lsp.enable('nedls')
```

```toml
# Helix: languages.toml
[language-server.nedls]
command = "nedls"
[[language]]
name = "nim"
language-servers = ["nedls"]
```

- **Emacs (eglot):** `(add-to-list 'eglot-server-programs '(nim-mode . ("nedls")))`
- **Kate** (LSP Client › User Server Settings): `{"servers": {"nim": {"command": ["nedls"], "highlightingModeRegex": "^Nim$"}}}`
- **Sublime** (LSP settings): `"clients": {"nedls": {"enabled": true, "command": ["nedls"], "selector": "source.nim"}}`
- **Zed** (with the Nim extension): `"lsp": {"nimlangserver": {"binary": {"path": "/path/to/nedls"}}}`
- **VS Code:** a generic LSP client extension pointed at `nedls` for the `nim` language (turn off the Nim
  extension's own server).
- **ned itself:** `{"nim.ide": "nimlangserver", "lsp": {"nim": ["nedls"]}}` — mostly for testing nedls; the
  editor has the engine built in anyway.

nedls trusts the folder it is given (it runs `nim dump` and `nim check`, which run the project's `config.nims`):
editors ask about trusting a workspace themselves. `nimble lsptest` drives it with a test client (every feature,
and 2000 random edits that must not put it out of step).

### One Nim per project

`nim.toolchain` (Nim settings; best in the project's `.ned/settings.json`, or *Nim: choose the Nim for this
project…*) is the Nim a project builds with, for every program ned starts — nim, nimble, nimsuggest,
nimlangserver, testament, the terminal: its `bin` folder goes first on PATH. `auto`, the default, keeps the `nim`
on PATH unless the project's .nimble asks for a Nim it is not (`requires "nim >= 2.2"`) and choosenim or grabnim
installed one that is; `path` always keeps PATH's; a version (`"2.0.16"`) or a Nim folder picks one. The status
bar shows the version (`✓ Nim 2.2.12`), and warns — *⚠ Nim 2.0.16: needs nim >= 2.2* — when the Nim in use is not
what the .nimble asks for; a nimsuggest from another Nim than `nim` is a warning too. A project's own
`nim.toolchain` takes effect only in a folder you trust.

### Lint: the engine's checks from the command line and in CI

`ned --lint` runs the engine's checks — a misspelled name, a field that is not there, a wrong number of arguments,
a value neither used nor discarded, an unused import or local, code that never runs, the hints above, deprecated
and too-new library names, and the project's own checks below — over files or folders, without the compiler or a
build (`nedls --lint` is the same):

```sh
ned --lint                          # this folder: the files git knows; path:line:col: warning: … [rule]
ned --lint --format:github src/     # GitHub annotations on the pull request (by itself under GitHub Actions)
ned --lint --format:sarif > ned.sarif   # SARIF 2.1.0, for GitHub code scanning (upload-sarif)
ned --lint --format:json x.nim      # a JSON array, each problem with its rule
ned --lint --severity:hint          # the hints too (var → let, unused parameters); default: warnings and errors
ned --lint --fail-on:error          # exit 1 only for errors (default: warnings too; never)
ned --lint --fix --diff             # what --fix would change, as a diff; nothing written
ned --lint --fix:var-let,deprecated # fix those rules in place (no --fix list: every rule that has a fix)
ned --lint --rules                  # the rules, their default severity, which have a fix
ned --lint --staged                 # the Nim files staged in git, as staged
ned --lint --install-hook           # a git pre-commit hook running that (beside nedfmt's, in one file)
```

**What `--fix` fixes**: a `var` nothing changes becomes a `let` (`var-let`), a deprecated name becomes the one its
message names (`deprecated`), an unused import goes (`unused-import`), a `proc` without side effects becomes a
`func` (`can-be-func`), and an imported package the .nimble does not require is added to its `requires`, with the
version the project builds with (`import-not-required`); in a Nim 3 project (or a file being ported) what Nim 3 needs
changed is made (`nim3`: `except E:`, `raise E`, `{.passive.}`, `low(E)..high(E)`, a named `break`, `x == nil`,
`t()`). Each fix is the editor's quick fix; a file keeps its line endings, and is checked again
afterwards.

**The project's own checks**: an `import` of a package the .nimble does not require (it builds here only because
the package happens to be installed), a package the .nimble requires that nothing imports, an exported routine
nothing in a program uses (a library's exports are for others), and the .nimble itself — a `requires` nimble cannot
read or written twice, a version no installed package meets, a `srcDir` or `bin` that is not there, a Nim
requirement the Nim in use does not meet, and no `version`, `author`, `description` or `license`. In the editor the
import and .nimble checks show while you type, with their quick fix (Alt+Enter: *Add requires "jsony" to
app.nimble*); the two that need the whole project, in `ned --lint` of the project.

**Rules per project** (`.ned/lint.json`, *Nim: lint rules for this project* writes one with every rule):

```json
{"rules": {"var-let": "off", "deprecated": "error", "unused-param": "hint"},
 "exclude": ["generated/", "tests/fixtures/*.nim"]}
```

Each rule is `off`, `hint`, `info`, `warning` or `error`, in the editor, nedls and `ned --lint` alike (a file's
nearest `.ned/lint.json` counts). A line is silenced with `# ned: ignore` (every
rule) or `# ned: ignore[var-let, unused-param]`, the next one with `# ned: ignore-next-line[…]`, a whole file with
`# ned: ignore-file[…]` near its top. Alt+Enter on a problem offers both: *Silence var-let on this line* and *Turn
off var-let for this project*. nedls gives each problem its rule as the diagnostic's `code`.

It reads the project's paths with `nim dump` once (`--no-config`: not, since that reads `config.nims`); ned's own
263 files take under 2 seconds — 7 with `--severity:hint`, since only then does it look for the hints (*can be a
func* among them). Why not in `nedfmt`: nedfmt is the formatter alone (1 MB; ned is 13), while the
checks need the whole engine — so they come with `ned` and `nedls`, which have it. *Nim: lint the project* shows the
same list in the output panel, each problem a link.

**Nim: add a CI workflow (GitHub Actions)…** writes `.github/workflows/ci.yml`: the project's dependencies
(`nimble install --depsOnly`), build and tests on Linux and macOS with the oldest Nim the .nimble allows and the
newest. Two more choices add a job that builds ned from the repository you give (`nim.ciNedRepository`, asked
once; a link with a login in it is refused) and runs `ned --lint --format:github` — and `nedfmt --check`. The file
is written, not committed: read it, then commit and push.

### Using nimlangserver instead

Set `"nim.ide": "nimlangserver"` (or click *Use nimlangserver instead* in the Nim dock). All nimlangserver
settings are in the settings file under `nim.*`; completion documentation, signature docs and Markdown
hovers work with it too. The rest of this section is about that mode.

### One nimsuggest per project

nimlangserver decides per file which project (nimsuggest process) serves it. Without a mapping, older
versions start a nimsuggest for every file you open. Newer ones pin whichever file you opened first and
restart it after an idle timeout. ned avoids both:

1. Before the server starts, ned picks the **main module**. It uses `nim.projectFile` if you set it.
   Otherwise it takes the `.nimble` package's `srcDir/<name>.nim` (the same module nimlangserver's own
   nimble entry point uses), then a `bin`, `<folder>.nim`, `src/<folder>.nim`, a module with its own
   `.nims`/`.nim.cfg`, `main.nim`, or the only `.nim` file.
2. It sends a `projectMapping` that maps the project's sources to that module. They all share one
   nimsuggest, which is never stopped for being idle.
3. **A folder with several packages** (your home folder, a monorepo) gets one rule per nimble package, added
   as you open its files. Loose scripts share one nimsuggest, started for the first script you open. A
   package file is therefore always checked inside its own package, with its imports and nimble paths.
4. Tests and examples are separate programs. With `nim.maxNimsuggestProcesses` = 1 (the default) they are
   served by the same process. Set it to 2 to give them their own, for complete answers there.
5. ned always names the `nimsuggest` to use: `nim.nimsuggestPath`, or the one on your `PATH`. Without
   that, nimlangserver would use the Nim folder that `nimble dump` reports inside a package, which is
   often not the Nim you use.
6. The server and its nimsuggest children are shut down when ned exits and restarted when you open
   another folder, so processes never pile up. A server that crashes is restarted. If it keeps crashing,
   the built-in nimsuggest client takes over.

Check it in the **Nim dock** (Alt+E › Code intelligence) or with *Nim: language server status*. Change the
main module with *Nim: use current file as main module* (stored in the project's `.ned/settings.json`).
Your own `nim.projectMapping` always wins.

### Formatting Nim

Alt+F (*Format document*) and `"editor.formatOnSave": true` use ned's own formatter. It formats the way nph does:
- 2-space indentation, and spaces around operators and after commas;
- one statement per line, with a blank line after multi-line routines and types;
- `proc f()` with an empty parameter list, and long import lists packed (one module a line when they are paths
  such as `std/os`);
- `if` and `case` written out on several lines unless every branch is a plain value;
- calls, parameter lists and collections wrapped at 88 columns, with a trailing comma when they take
  several lines;
- comments kept, and a trailing comment that does not fit moved under its line (a lone `## doc` line under
  a statement joins it when it fits);
- a long `from x import …` with the names on the next line.

With several lines selected, Alt+F (or *Format selection*) formats only those lines, at their indentation.

Its layout is yours to choose (settings, Nim section):

| setting | default | |
|---|---|---|
| `nim.format.lineLength` | 88 | where lines wrap (80 and 100 are common too); not written in your settings or the project's: a file's `.editorconfig` `max_line_length` |
| `nim.format.params` | `fit` | a routine's parameters: `fit` — on one line, else all on the next line or one per line (nph) · `onePerLine` — one per line when too long · `always` — one per line when there are two or more · `keep` — your line breaks |
| `nim.format.arguments` | `fit` | a call's arguments: the same four (`fit` packs them on the next lines) |
| `nim.format.collections` | `fit` | array, seq, table, set and tuple literals: the same four |
| `nim.format.imports` | `keep` | `sort` — std/, pkg/, others, ./relative · `merge` — sorted, and `std/a` + `std/b` → `std/[a, b]` (module initialisation follows import order: keep it if that matters) |
| `nim.format.align` | off | line up object field types and the `=` of const / let / var members |
| `nim.format.reflowDocComments` | off | re-wrap a `##` paragraph with a line longer than the line length (lists, tables and code stay) |
| `nim.format.reflowComments` | off | the same for `#` paragraphs of prose — what reads as commented-out code, lists, TODOs and `# ned:` directives stay; a banner's rule (`# ── Section ────`) is cut to fit |
| `nim.format.maxBlankLines` | 1 | empty lines kept in a row (up to 3) |
| `nim.formatEmitC` | on | the C in `{.emit: """…""".}` formatted too: clang-format (your `.clang-format`), else ned's own C formatter |
| `editor.formatOnPaste` | `indent` | pasted lines take the indentation of where they go · `format` — and pasted Nim is formatted · `off` |

ned's own **C formatter** (used for the emits, and for `.c` files when clang-format is not installed) indents by
braces in LLVM's layout and evens out spaces — after commas and keywords, around assignments and comparisons,
none inside brackets — and keeps your line breaks; like the Nim one, it checks that the code is the same token for
token, or changes nothing.

From the shell: **`nedfmt`** — the same formatters as a small program of their own (`nimble install` builds it
next to ned; `ned --format` is the same command) — with nph's options:

```sh
nedfmt src/ tests/                 # format in place (in a git repository: the files git knows, not ignored ones)
nedfmt --check .                   # CI: exit 1 when a file would change, nothing written
nedfmt --diff x.nim                # a unified diff of what would change
cat x.nim | nedfmt -               # stdin to stdout (--stdin-name=path/x.nim: its kind and its project's settings)
nedfmt --outDir:out src/           # write beside, the originals untouched (--out:FILE for one file)
nedfmt --install-hook              # a git pre-commit hook: the staged Nim files must be formatted
nedfmt --verify src/               # check every Nim result with Nim's own parser too (below)
```

`--exclude`, `--extend-exclude` and `--include` take regular expressions, and nph's `.nph.toml` (exclude,
extend-exclude, include) is read too, so a project set up for nph needs nothing new; files named on the command
line are always taken. The layout settings (`nim.format.*`) come from your settings and the project's
`.ned/settings.json`; where neither sets the line length, a file's `.editorconfig` `max_line_length` does — as in
the editor, where `.nph.toml`'s excludes also keep a file from being formatted on save or by *Format: every file in
the project*. Exit status: 0 done, 1 `--check` found files to change, 2 a file was left alone (the
formatter was not sure of it) or could not be read, 3 wrong arguments. The hook checks what is staged, not your
working copy; a file the formatter is not sure of does not stop the commit, and `git commit --no-verify` skips it.
*Format: every file in the project…* does it from the editor, with a review first (see the 5.24 notes).

**Nim's own parser as a second check** (`nim.format.verify`, `nedfmt --verify`). Where the compiler's sources are
installed — choosenim and source builds have them, or `nimble install compiler` — ned builds a small checker from
them once (in the background, about half a minute) and asks it whether each formatted file parses to the same
syntax tree as before, comments and layout aside. A file it reads differently is left alone. The formatter's own
token and block check runs anyway; this one is for when you want the compiler's word on it. `nimble parsecheck`
runs it over 463 files of Nim's compiler and standard library.

JSON, Markdown (tables), CSS, HTML and SQL have built-in formatters too, used when prettier (or a formatter of
yours) is not installed: HTML blocks on lines of their own and indented, what `<pre>`, `<script>`, `<style>` and
`<textarea>` hold kept as it is, templates (`{{ }}`, `{% %}`, `{expr}`) untouched; SQL one clause a line, keywords in
upper case, strings, comments and placeholders untouched. Like the others they check their result, or change
nothing.

It works on tokens and checks every result before writing it: the same tokens in the same order (doc comments
included), the same block structure, and line breaks only where Nim's parser reads the line on — after `,` `(` `[`
`{` `{.` `=` `:`, an operator or `import`, before a closing bracket, a `.` or a branch, or where you already had one;
a line break your code needs, between two statements, always stays. If anything would differ, it changes nothing
and names the file, so you can report it. Long string literals and code with statements inside brackets (a lambda's
body, `do` blocks) keep their layout. All seven layout settings (`fit`, `onePerLine`, `always`, `keep`, other widths,
alignment) are checked with Nim's own parser over the 3,800 files of Nim's compiler, standard library and tests:
only files Nim cannot read in the first place come out read differently.

How it compares with nph, on Nim's compiler and standard library:

| | built-in | nph |
|---|---|---|
| lines identical to nph's output | 99.8% of 198 000 | — |
| same code for Nim's parser (463 files) | all | all |
| semexprs.nim, 3 598 lines | 14 ms | 24 ms |
| strutils.nim, 3 069 lines | 7.5 ms | 10.5 ms |
| json.nim, 1 398 lines | 4 ms | 6.5 ms |
| json.nim, already formatted | 4 ms | 6.5 ms |

Both measured on the same (slow) machine; nph's times include starting the program, which ned also has to do when
it runs nph. Where the two still differ — about two lines in a thousand — it is mostly a token nph rewrites (a
`tuple` with comments, `s.fromHex[:int16]`), a long call's arguments, or a comment inside a parenthesized
condition.

To use nph or nimpretty instead, set `"nim.formatter": "nph"` (or `"nimpretty"`), or pick *Nim: format with nph*
in the palette. Your own `formatters` entry for `nim` always wins.

### Other Nim features

- Alt+M expands the macro/template call under the cursor; *expand one level*; ARC/ORC view
  (`expandArc`); show generated C; check the project; generate docs.
- Quick fixes (Alt+Enter): *Import std/tables* for `undeclared identifier: 'initTable'` (from an index of
  the standard library's exports, built once and cached), *Remove unused import os*, and fixes worked out from
  the compiler's messages (let → var, discard, conversions, did you mean, export, create the proc, missing case
  branches, raises, ambiguous names, deprecated names), with *Fix all like this in the file*; AI fix (checked
  with `nim check` before it is applied) / explain.
- *Nim: toggle export marker (\*)*, *Nim: open documentation for symbol*, *Nim: REPL*.
- C interop: F12 on an `importc` declaration opens the C prototype (the hover shows it, with the comment that
  documents it in the header — in completion too), the C signature is shown dimmed after each wrapper
  (`nim.cSignatureHints`), `header: "…"` and `importc: "…"` are coloured and have a hover and F12, Alt+Enter
  rewrites a wrapper from its C declaration, and `proc ` + a C name completes a whole new wrapper; wrappers are checked
  against their headers (`nim.checkWrappers`), completion in `header: "…"` and `importc: "…"`, *wrap a C header
  (c2nim)*, *compile_commands.json for clangd*.
- Code inside strings in its own colours: `{.emit}` as C (C++, JS), `sql"…"`, `re"…"`, `peg"…"`, `parseJson("…")`,
  the `{expressions}` of `fmt"…"` and `&"…"`, and HTML or SQL in triple-quoted strings. `#[html]#` before a string
  marks it; `nim.embeddedLanguages` names your own procs (`{"render": "html"}`).
- C in `{.emit}` edits as C: indentation, `//` comments, completion from its headers and `nimbase.h`, hover,
  F12 between the Nim declaration and the C, C compiler errors on the emit's lines (on save and from builds);
  with clangd installed, clangd's completion, errors while typing, fixes and parameter hints (`nim.emitClangd`).
- HTML, CSS, SQL and JSON in strings go to their language servers: errors on the Nim line, completion, hover,
  fixes.
- *Nim: extract selection into a proc*, *change signature…*, *inline this proc*, *move to another module…* (see the
  5.19 notes), *Nim: sort imports*, *Nim: toggle proc ⇄ func*.
- Reference counts after each proc and type (`nim.referenceCounts`); *Nim: exports nothing uses…*.
- Completion offers names from standard modules not imported yet, and adds the import (`nim.autoImport`), and
  postfix templates after a `.`: `xs.for`, `c.case` with every value of its enum, `v.if` by its type
  (`nim.postfixCompletion`).
- Where ARC/ORC copies, after each save: ⧉copy beside what is copied, hover for why (`nim.showCopies`).
- Constants worked out on hover — a `when` too, with its branch left out on this platform dimmed
  (`editor.dimInactiveCode`).
- Debugger panel with gdb: F9 breakpoints, F5 start/continue, F10/F11 stepping (see the 5.2 notes); conditional
  breakpoints, logpoints and stops when a value changes (5.24).
- *Nimble: add dependency…* (adds `requires` and offers `nimble install -d`), *dependency tree*, *search packages*, tasks,
  build modes (debug / release / danger), backends (C, C++, JS, ObjC), Nim 3 with Nimony (*Nim › Nim 3 (Nimony)*: see
  [What's new in 6.12](#whats-new-in-612)).
- Test explorer (Tests dock) for `std/unittest` suites, with ▶ buttons in the gutter; tests run on save, ✓ or ✗
  beside each (`nim.testOnSave`).
- **Test coverage**: *Test coverage: run* builds the project's Nim tests with coverage, runs each one, and colours
  the line numbers — green ran, red never ran. It runs the test explorer's tests and nimble's `tests/t*.nim`; in the
  explorer, `c` on a test file covers just that one (*Nim: test coverage* covers the file you are in). The count is
  exact per Nim line: with gcc, ned rewrites the generated C so that a statement's extra C lines do not land on the
  Nim lines after it; with clang (Termux, macOS) it uses clang's source-based coverage and maps the C lines back
  through `#line`. Procs no test calls (Nim leaves them out of the binary) count as missed and are named in *Test
  coverage: summary by file*, which shows each file's share and the project's. Only the project's own files count —
  not the standard library, nimble packages, or the tests unless `nim.coverageTestFiles` is on. The C build is kept
  privately between runs, so a second run takes a moment; nothing runs in a folder you have not trusted. Needs gcov
  (it comes with gcc) or, with clang, llvm-cov and llvm-profdata (Termux: `pkg install llvm libcompiler-rt`).

## C: ned's own engine

C files get an IDE without installing anything: ned reads the file and the headers it includes, the way a person
skimming them does, and answers from that — about 15 ms the first time a file is opened (with every header it
includes), under a millisecond after.

- **Completion**: locals, parameters, the file's and its headers' functions, types, macros and enum constants, and
  **members after `.` and `->`** — through typedefs, pointers, arrays, casts, calls and macros (`opts->`,
  `list.items[i].`, `get(x)->`, `P_OPERAND(p)->`), and in designated initializers (`{ .x = 1, .`), each with its type
  and comment beside the list. After `goto`, the function's labels; in `#include "` and `<`, the headers there.
- **Hover**: the declaration on one line, where it is, and the comment that documents it (`/** … */`, `///` or `//`
  above it, `/**< … */` after it); a definition without a comment shows its prototype's from the header. A struct
  lists its fields.
- **Go to definition (F12)** through `#include`s: the file's folder, the project's `include/`, `inc/`, `src/` and
  `lib/`, the `-I` folders of `compile_commands.json`, `C_INCLUDE_PATH` and `CPATH`, then the compiler's own. On a
  function or global declared in a header, its definition — in the project's other `.c` files too (a system
  header's declaration stays); on a definition's name, its prototype, and back; on `goto x`, the label.
- **References (Alt+Q) and rename (F2, with a preview)**: a local, parameter or label in its function, anything else
  across the project's C files — never inside strings or comments. A name declared outside the project (in the
  system's headers) is not renamed.
- **Signature help** on `(` and `,` with the parameter being typed marked; the **outline** with each struct's fields;
  symbols in the file (Ctrl+T).
- **Errors while you type**: the C compiler (`cc -fsyntax-only`) checks the unsaved text — a private copy, removed
  after — with `compile_commands.json`'s `-D`s; **Alt+Enter adds a missing `#include`** for a standard function,
  type or macro (`printf` → `<stdio.h>`, `size_t` → `<stddef.h>`).

It does not run the preprocessor: every `#if` branch is read, except where the answer is known without one — `#if 0`,
C++-only code (`#ifdef __cplusplus`, `extern "C++" { … }`) and the compiler's target (`__x86_64__`, `__linux__`,
`_WIN32` … as `cc -dM -E` reports them) —, and of branches that open a brace each (`#ifdef X  if (a) {  #else  if (b)
{`) the first, as ctags does. Macros used as expressions are expanded for the types (`#define atime tv[0]`), as are
export markers (`mod_export int x;`) and prototypes written through a macro (`int f _((int a));`); declarations a
macro makes (`local_list1(foo);`) are not understood.

**C++** is read too — in `.cpp`, `.cc`, `.cxx`, `.hpp` files, a `.h` with classes, namespaces or templates in it,
and emits when `nim.backend` is cpp: classes, structs and unions with their access sections and bases, methods in
the class or outside it (`Ret Class::method(…)`, constructor init lists), operators, nested classes, namespaces
(nested, `a::b`, `inline`, anonymous, `using namespace`, `using T = …`), templates (a class template's arguments put
in for its parameters: `Box<Point>`'s `value` is a `Point`), references, `auto` (range-for too), `enum class`,
`extern "C"`. Completion after `.`, `->` (smart pointers too) and `::`, a class's members in its methods, `std::`'s
common names; hover and F12 from a call to a method's body, then its declaration; errors from `c++ -std=c++17`.
Overloads are listed, not resolved; dependent types, `decltype`, concepts, specializations and structured bindings
are not understood — clangd answers those.

`c.engine` chooses: `auto` (the default: ned's engine when clangd is not installed, clangd when it is), `builtin`,
`clangd`, or `both`. How it compares with clangd is measured in [tests/engine](tests/engine/README.md#c-ned-against-clangd).

## AI assistant

Set a key in your shell (e.g. `~/.bashrc`) and restart ned:

```sh
export ANTHROPIC_API_KEY=…     # or OPENAI_API_KEY, OPENROUTER_API_KEY, GROQ_API_KEY, DEEPSEEK_API_KEY …
```

Choose the provider and model with *AI: choose provider…* / *AI: choose model…*, or in the settings
(`ai.provider`, `ai.model`, `ai.baseUrl` for Ollama or any OpenAI-compatible server — Ollama needs no key).

**No key, no internet**: *AI: on this device, offline…* (also first in *AI: choose provider…*) runs a model on
your phone or computer. It finds Ollama — or installs it (`pkg install ollama` in Termux, `brew install ollama`,
Ollama's script on Linux) — starts it, offers the Qwen 2.5 Coder model that fits the device's memory (0.5B under
3 GB, 1.5B from 3 GB, 3B from 5 GB, 7B from 9 GB, 14B from 18 GB; *Other models…* for the rest), downloads it with
its progress in the status bar, sets `ai.provider` and `ai.model`, and times a first answer. llama.cpp's
`llama-server` on port 8080 is used the same way. `ai.localUrl` says where Ollama listens.
*Type a model id…* in the model list accepts any model your provider offers. Keys are passed to `curl`
through a private temporary file, never on the command line.

**OpenAI**: ned speaks both Chat Completions and the Responses API (`ai.openaiApi`: auto / chat / responses).
For reasoning models (GPT-5 and later, o-series) it sends what they accept: `max_completion_tokens` with room
to think, the `developer` role, no temperature. A model that only runs on the Responses API, or an
organisation that is not verified for streaming, is handled automatically. When an endpoint refuses a
parameter, ned adjusts the request, retries, and remembers the change for that model.

- **Chat** sends the current file (or selection) along. **Agent mode** lets the assistant read, search and
  edit files and run commands. Edits and commands wait for your approval (`ai.autoApprove`: none / reads /
  edits / all); file changes are shown as a **diff** first, with *Open diff* for the whole change. Anything
  outside the project folder always asks, and the agent cannot edit outside it.
- **Plan first** (*AI: plan a change, then do it step by step…*, or `/plan …`): the assistant reads the code —
  editing and commands are refused while it plans — and answers with numbered steps. *Do it* runs them all
  (stopping when a step leaves errors), *One step* asks again after each, *Change the plan…* sends what should be
  different. Every step has a restore point: *AI: the plan…* › *Back to before step N*.
- **A failing test**: Alt+Enter on a failed check (or *AI: make the failing test pass*) sends the test, how it
  failed and the code it tests; the change is kept only when the test then passes.
- **Slash commands**: `/explain` `/fix` `/tests` `/doc` `/review` `/optimize` `/commit` `/plan` `/regen` `/new`
  `/history` `/model` `/provider` `/help`.
- **Mentions** attach context: `@file` `@selection` `@diff` `@staged` `@problems` `@terminal` `@tree`, or
  `@path/to/file`.
- **Saved chats**: every conversation is kept (*AI: chat history…*, or the ◷ button) and can be resumed.
- **Project instructions**: `AGENTS.md`, `CLAUDE.md`, `NED.md`, `.ned/instructions.md` or
  `.github/copilot-instructions.md` are added to the system prompt (`ai.projectInstructions`).
- **Prompt caching** for Anthropic (`ai.promptCaching`) and a token counter for the chat — in dollars with
  `ai.price`. Requests over `ai.warnTokens` ask first. `ai.fastModel` adds a ⚡ fast / smart switch.
- **Undo**: every agent run keeps the files it changed; the toast at the end, or *AI: undo the assistant's
  changes…*, puts them back.
- **Nim context** (`ai.nimContext`): the definitions your Nim code uses go along with it — and with inline
  edits and suggestions, for C too; a suggestion naming something that does not exist is dropped
  (`ai.checkSuggestions`).
- *AI: review staged changes* puts its findings in the Problems panel.
- Code blocks have *Copy*, *Insert*, and *Apply* when the block names a file (shows the diff first).
- Alt+Shift+C rewrites the selection (or the enclosing block) in place — Ctrl+Z undoes it.
- *Git: generate commit message with AI* (also in the git dock and `/commit`).
- **Inline suggestions** (`ai.inlineCompletion`, off by default because it sends code on every pause): grey
  text after the cursor, Tab accepts.

## Search and replace

- **Find** (Ctrl+F): case (Alt+C), whole word (Alt+W), regular expression (Alt+R). **Replace** (Ctrl+R)
  asks match by match or replaces all; with regex, `$1`, `${12}`, `$0`/`$&` and `\n` work in the replacement.
- **Project search** (Alt+S): results grouped by file, matches highlighted, the same three toggles, and a
  **files filter** (*files…*): `*.nim, src/, !tests/`. Uses ripgrep when available.
- **Replace in files**: open the replace box (chevron, ⇄, or Alt+H). Every result shows *old → new* inline.
  Right-click a result to replace that line or that file, or to dismiss it; **All** (Alt+Enter) replaces the
  rest after a confirmation. Open files change in the editor (save them); the others are written to disk
  after a local-history copy, and *Search: undo replace all* restores everything.

Regex syntax: `.` `[abc]` `[^a-z]` `[[:digit:]]` `\d \w \s \b` (and negations) `^ $` `( )` `(?: )` `a|b`
`* + ? {n} {n,} {n,m}` and lazy `*? +? ??`. Matching is per line.

## Safety: how ned protects your work

- **Atomic saves**: ned writes a temporary file next to the original, flushes it to storage (`fsync`) and
  renames it over the original, keeping permissions — a crash or power loss leaves the old or the new file,
  never half of one. Hard-linked files are written in place; symlinks are followed.
- **Recovery files**: unsaved edits are written to a private recovery file about a second after you stop
  typing (files over 20 000 lines at most every 20 s, over 300 000 lines not at all); each ned process has its own, so two sessions never overwrite each other's. If ned crashes, Termux kills the session, the ssh connection drops (SIGHUP/SIGTERM) or the
  battery dies, the next start offers *Restore*. *File › Recover unsaved edits…* lists everything.
- **Local history**: every save keeps the previous version (last 60 per file). *File › Local history…* shows
  each version as a diff against the current text and restores it with one click. Agent edits and
  project-wide replaces are saved the same way, so they can always be undone.
- **No silent overwrites**: if a file changed on disk since you opened it, saving asks whether to overwrite or
  reload; if another running ned has unsaved edits to the same file, you are warned.
- **Binary files** open in the hex editor: what you type changes only the bytes you type over (or insert), saving
  writes the bytes as they are (a new file renamed over the old one, its permissions kept); files over 512 MB are
  refused.
- **Libraries open read-only**: files of the Nim toolchain (the standard library, the compiler) and of installed
  nimble packages — where go to definition often lands — cannot be changed by a stray key; *Read-only* in the
  status bar (or *File: allow editing this file*) unlocks one. The project you have open is never locked.
  `files.protectLibraries: false` turns it off.
- **Folder trust**: a folder you open is not trusted until you run *Workspace: trust this folder* (or press
  *Trust* on the notice, or *⛉ Not trusted* in the status bar). Until then ned's own Nim and C engines read and
  check its code, but nothing in it runs — not the Nim compiler (its `config.nims` and macros can run commands),
  nimble, nimsuggest, its tests or the program — and its project settings that run programs (`lsp`, `run`,
  `run.configs`, `formatters`, `languages`, `debug.adapters`, `repl.commands`, `terminal.shell`, `keys`,
  `editor.keymap`, `commands`, `ai.*` including MCP servers, `nim.nimsuggestPath`, `sync.repository`) are ignored, so
  opening a cloned repository cannot start programs or redirect your code (or your settings) somewhere else. A
  project ned creates for you, the Nim toolchain's own files and nimble packages are trusted;
  `security.folderTrust: off` trusts every folder.
- **Secrets stay put**: API keys and MCP server tokens are never put on a command line; *Settings sync* leaves
  them out of what it exports; a remote folder's ssh password or passphrase is asked by ssh itself, in the
  terminal; a settings repository URL with a token in it is refused.
- *File › Compare with saved* shows your unsaved changes as a diff.

## Settings

Everything is in one commented JSON file: **`~/.config/ned/config.json`** (palette › *Open settings file*),
or use the settings UI (palette › *Settings*, ⚙ in the title bar), where you can type a setting's name or words
from its description. Saving the file applies it immediately.
`ned --default-settings` prints every option with its default and a description.

A few examples:

```jsonc
{
  "theme": "vscode-dark",
  "ui.icons": "nerd",
  "ui.italics": false,
  "editor.tabSize": 2,
  "editor.rulers": [80],
  "editor.fontLigatures": "symbols",
  "editor.formatOnSave": true,
  "editor.vimMode": false,
  "editor.completionDocs": true,
  "nim.ide": "builtin",
  "nim.nimsuggest": false,
  "nim.formatter": "builtin",
  "ai.provider": "anthropic",
  "ai.autoApprove": "reads",
  "git.inlineBlame": true,
  "keys": {"alt+g": "Go to symbol in project…", "ctrl+shift+f": "Search in project…"},
  "commands": {"Upper case": {"run": "tr a-z A-Z", "output": "replace"}},
  "ui.messages": "popup",
  "snippets": {"nim": {"dbg": "echo \"${1:x} = \", $1"}},
  "lsp": {"python": ["pyright-langserver", "--stdio"]},
  "run": {"python": "python3 $file"},
  "editor.keymap": "default",
  "editor.spellCheck": "markdown",
  "ui.accessible": false,
  "repl.commands": {"python": "ipython --no-autoindent"},
  "sync.repository": "git@github.com:you/ned-settings.git"
}
```

*Settings: reset to defaults* (palette, or near the top of the Settings UI) puts every setting and key binding
back to its default after asking. Your old file stays next to it as `config.json.bak-<date>`.

**Project settings**: `<folder>/.ned/settings.json` overrides your settings inside that folder (palette ›
*Settings: open project settings*). Typical uses: `editor.tabSize`, `nim.projectFile`, `files.exclude`,
`nim.toolchain` (the Nim the project builds with), `nim.minVersion`, `nim.format.lineLength`. Settings that start
programs (`nim.toolchain`, `lsp`, `run` …) take effect only in a folder you trust.

Setting groups: Appearance (`theme`, `ui.*`), Editor (`editor.*`), Zen (`zen.*`), Vim (`vim.*`), Files
(`files.*`), Search (`search.*`), Terminal (`terminal.*`), Git (`git.*`), Nim (`nim.*`, including every
nimlangserver option), C (`c.*`), AI (`ai.*`), Languages (`lsp`, `formatters`, `run`, `snippets`, `web.engine`) and `keys`.

## Vim mode and zen mode

**Key bindings:** *Key bindings: default · vim · emacs · helix…* (`"editor.keymap"`). **Emacs**: C-f C-b C-n C-p,
C-a C-e, M-f M-b, C-v M-v, M-< M->, C-k (again: adds to the same kill), C-w M-w C-y, C-SPC sets the mark, C-g,
C-s, M-%, C-/, C-l, C-o, C-t, M-u M-l M-c, M-;, M-/, M-x (palette), M-g g, C-x C-s / C-f / C-w / C-c / C-x,
C-x b / k / u / h / o / 1 / 2 / 3. **Helix** (select, then act): `h j k l`, `w b e W B E`, `x` line, `%` all,
`v` extend, `;` collapse, `,` one cursor, `C` cursor below, `d c y p P`, `i a I A o O`, `u U`, `r<c>`, `~`,
`> <`, `J`, `/ ? n N *`, `g` (`g e h l s d r y i n p`), space (`f b s S / k a r c y p d ?`), `:w :q`.

**Vim mode** (`"editor.vimMode": true` or View › Vim mode): normal, insert, visual, visual-line and replace
modes; motions `hjkl w b e 0 ^ $ gg G { } % f t ; ,`; operators `d c y > < gu gU gc` with motions and text
objects (`iw aw i( a( i" a" i{ …`); `x X s S C D Y p P J r R ~ . u Ctrl+R`, `g-` `g+` (back and forth in time,
across the undo tree's branches); vim-surround's `ys{motion}{char}`, `yss`, `cs{old}{new}`, `ds{char}` and `S{char}`
in visual mode (`t` or `<`: a tag); `/ ? n N * #`; `:w :q :wq :e
file :s/a/b/g :%s/a/b/g :set wrap :term :zen`; `:!cmd` (`%` is the file) and `:%!sort`, `:'<,'>!cmd`,
`:N,M!cmd` (lines through a command); `zz zt zb za zc zo zM zR`; optional `jk` escape
(`vim.escapeSequence`).

**Zen mode** (Alt+Z): no chrome, a centred column (`zen.width`), the block or paragraph you are in stays bright
(`zen.dimOthers`), optional typewriter scrolling and a quiet word count; git's change marks stay out of the gutter
unless you want them (`zen.gitChanges`). Esc Esc leaves. In vim mode Esc
belongs to vim: leave with Alt+Z or `:zen`; the corner shows the vim mode.

## Files ned uses

| path | contents |
|---|---|
| `~/.config/ned/config.json` | your settings (`$XDG_CONFIG_HOME` is respected) |
| `~/.config/ned/themes/*.json` | your own and imported themes |
| `~/.config/ned/words.txt` | your own dictionary words (spell check) |
| `~/.local/share/ned/dictionaries/` | dictionaries downloaded by *Spell check: download a dictionary…* |
| `<folder>/*.ned-workspace` | a multi-root workspace (*Workspace: save as…*) |
| `<project>/.ned/settings.json` | project settings, run configurations |
| `~/.local/state/ned/state.json` | recent files, sessions, layout, bookmarks, trusted folders (`$XDG_STATE_HOME`) |
| `~/.local/state/ned/swap/` | recovery files of unsaved edits |
| `~/.local/state/ned/history/` | local history (previous versions of saved files) |
| `~/.local/state/ned/chats/` | saved AI chats (newest 200) |
| `~/.local/state/ned/nimindex.json` | index of the Nim standard library's exports |
| `~/.cache/ned/index/` | the engine's reading of the standard library, packages and the project's files, kept between sessions (`nim.indexCache`; `$XDG_CACHE_HOME`; safe to delete) |
| `~/.cache/ned/nedastcheck-*` | the Nim parser check the formatter can use (`nim.format.verify`), built once |
| `~/.local/state/ned/errors.log` | details of internal errors, if any ever happen (please include it in a report) |
| `~/.local/state/ned/remote/` | the local copies of remote (SSH) folders, and `remotes.json` |
| `~/.local/state/ned/settings-sync/` | the clone of your settings repository (*Settings sync: push / pull*) |
| `$TMPDIR/ned-UID/remote-PID.sock` | the socket a running ned answers on (`ned --remote …`, `ned FILE` in its terminal; only you can reach it; gone when it quits) |

## Building, tasks and performance

```sh
nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim      # what you need
```

`src/ned.nims` (picked up automatically) turns on `--opt:speed` for release builds. Add `-d:lto` for link-time
optimisation: 5–10% less time in the engine and the formatter, a 7% smaller binary and 1.5 MB less memory at
start, for a build that takes about twice as long (gcc, or clang with a linker that does LTO); the release binaries
are built with it. `-d:useMalloc` (the C library's allocator) saves about 3 MB with a big file open but makes the
engine and the formatter 20% slower: not used, but yours to add where memory matters most. The nimble file has
tasks:

| task | |
|---|---|
| `nimble release` | optimised `./ned` |
| `nimble termux` | build into `$PREFIX/bin` |
| `nimble local` | build into `~/.local/bin` |
| `nimble debug` | debug build with stack traces |
| `nimble typecheck` | `nim check` only |
| `nimble android` | verify it compiles for Android/arm64 (C generation only) |
| `nimble test` | the unit tests: the Nim and C indexes, the formatters, the regular expressions, ARC/ORC copies |
| `nimble uitest` | the whole editor driven through tmux (needs tmux; see [tests/README.md](tests/README.md)) |
| `nimble bench` | render a 200 000-line file off-screen and print frame timings and bytes |
| `nimble perf` | startup time, memory and frame times, checked against the CI budget (needs python3) |
| `nimble smoke` | build and run the non-interactive checks |
| `nimble nedfmt` · `nimble nedls` | build the formatter and the language server on their own |
| `nimble lsptest` | nedls driven by a test client: every feature, then 2000 random edits |
| `nimble parsecheck` | the formatter over 463 files of Nim's own source, each checked by Nim's parser |
| `nimble tools` | install nimlangserver, nph and inim |

Why it is fast: a cell grid with per-cell diffing (only changed cells are sent, inside synchronized-output
frames, colours carried along a row and unchanged stretches skipped), scrolling done by the terminal itself (a
scroll region: only the new lines are sent), incremental per-line highlighting with a background pass, nothing done
per frame that depends on file size, file indexing and project search in the background, the engine's checks in
the pauses between keys and swipes, language servers and git in separate processes with non-blocking pipes and a
lower priority than ned, and zero CPU while idle. Files over 40 000 lines skip the language server so typing stays
instant; a 1-million-line file scrolls and edits normally.

*Help › Performance…* shows how ned does on your device: frames (made in, bytes sent, how long the terminal took),
the terminal's speed, the moments ned could not read input and what kept it busy, the engine's timings, memory and
what runs in the background, with the settings that would make it lighter. `NED_PERF_LOG=file` writes it when ned
exits. `ned --bench FILE` gives the time and bytes per frame without a terminal, and
`ned --startup-time [file …]` where the time goes when ned starts, and the memory it uses (see the 5.22 notes); CI
checks those numbers on every push.

### The source

ned is one program in about 260 files, standard library only:

```
src/ned.nim            the program: the parts below, in the order they build on each other
src/ned/
  core/                types, global state, themes, the cell grid and terminal output, keys, languages, highlighting
  editor/              the buffer and its undo tree, editing, cursors, selection by structure, surround, next edits, find …
  ui/                  drawing: layout, menus, dialogs, pickers, docks, the file tree, the panel, the editor view
  nim/                 the Nim IDE: the engine's glue, quick fixes, refactorings, codegen, nimble, examples …
  nim/index/           the Nim index — a module of its own: parsing, scopes, types, completion, hover, typos
  format/              the formatters (Nim, JSON, Markdown, CSS, HTML, SQL — a module of their own) and Format all
  web/                 ned's own CSS, HTML, SQL and JavaScript: what they know, completion, hover, problems (a module)
  lsp/                 the language-server client, code actions, inlay hints, servers for code inside strings
  ai/                  the assistant: requests, agent tools, MCP, chats, inline suggestions
  git/  term/  debug/  c/  run/  testing/  project/  config/  keymaps/  app/
tests/                 unit tests, the UI suite, the fuzzer, the engine comparison, cross builds
examples/showcase.nim  one Nim file that tours what ned does for Nim
```

Most files are parts of the program (`include`d in order: each sees the ones before it). The Nim index, the
formatters, the regular expressions, `core/text` and `core/editorconfig` are modules: they compile on their own, in
parallel, and other programs can import them (`import ned/nim/index`). `nim/nimapis.nim` — what each Nim release
added to the standard library — is made by `.github/ci/nimapis.py` from the releases' libraries. The tests are described in
[tests/README.md](tests/README.md); GitHub runs them on every push.

## Troubleshooting

- **Start here:** `ned --check` (or *Help › Check setup*) shows which tools ned found and how to install the
  missing ones. When you report a problem, *Help › Copy info for bug report* gives the details to paste.
- **Several nimsuggest processes** — open *Nim: language server status*: it lists each process and why it
  exists. With the built-in engine there is one per project at most; with nimlangserver it is usually a test
  file with `nim.maxNimsuggestProcesses` ≥ 2, or a `nim.projectMapping` of your own.
- **No completion or hover for Nim** — check that `nim` is on your `PATH`. The engine finds the standard
  library from it. *Nim: language server status* shows the library folder and the search paths in use.
  Completion that comes up but does not know a type falls back to nimsuggest when it is turned on.
- **nimsuggest uses too much memory** — it is off by default since 5.28; if you turned it on, lower
  `nim.nimsuggestMaxMB` or `nim.nimsuggestIdleMinutes`, or set `"nim.nimsuggest": false` again.
- **Nim works in single files but not in a nimble project** — fixed in 4.1. Open *Nim: language server
  status*: it shows the nimsuggest in use, the rule for each project, and the server's errors. If the
  package needs a different Nim, set `nim.nimsuggestPath` to that Nim's `nimsuggest`.
- **"nimlangserver exited"** — the warning shows the server's last error line, and the status page shows
  its output. ned restarts it, and switches to the built-in nimsuggest client if it keeps failing.
- **AI: "Unsupported parameter: 'max_tokens'…" or a model that answers with nothing** — update to 4.1. The
  request is adjusted to each model automatically. An empty reply says why, usually the token limit (raise
  `ai.maxTokens`).
- **Alt keys don't work** — in Termux add ALT to the extra-keys row (`~/.termux/termux.properties`); on macOS
  terminals enable "Option as Meta". Every command is also in the menus (F10) and the palette (Ctrl+E).
- **Can't select text with the mouse in Termux** — Alt+U turns ned's mouse support off for a moment.
- **Slow on a phone** — *Help › Performance…* says what takes the time and which settings would help (often
  `"ui.minimap": "off"` on a slow terminal, or `"nim.engineHints": false` on a big file).
- **Lines left behind or out of place after scrolling** — the terminal does not handle scroll regions as ned
  expects: set `"ui.terminalScroll": false` (and *Redraw the screen* from the palette clears it at once).
- **Colours look wrong** — set `"ui.trueColor": "on"` or `"off"` (256 colours).
- **Emoji push the text out of place** — terminals disagree on emoji sequences (👨‍👩‍👧, 👍🏽, flags): ned joins them
  where the terminal says it does (mode 2027). If yours joins them without saying so, set `"ui.graphemes": "on"`; if
  it shows them apart although it said otherwise, `"off"`. *Help › Check setup* shows what the terminal answered.
- **A key does something odd in kitty, WezTerm, Ghostty or foot** — ned speaks the kitty keyboard protocol there;
  `"ui.kittyKeyboard": "off"` goes back to the classic keys (please report the key).
- **`ned FILE` in ned's terminal starts no second ned** — that is on purpose: the file opens in the ned around it.
  `ned --new FILE` starts another one; `"terminal.editorEnv": false` keeps git's and your `$EDITOR` as they were.
- **Comments look odd or garbled** — italics are off by default. Turn them on with `"ui.italics": true`
  only if your terminal font has an italic face.
- **AI says "No API key"** — export the key in the shell that starts ned, or set `ai.apiKey`
  (`ai.apiKeyEnv` names a different variable). Or use a model on the device, which needs none: *AI: on this
  device, offline…*.
- **git push asks for a username and password, and fails** — GitHub stopped taking passwords. Since 6.7 ned
  offers *Sign in* when that happens (also *Git: sign in to GitHub*): the GitHub CLI signs you in in the
  browser, or an SSH key is made and added. In a shell the same is `gh auth login` and `gh auth setup-git`.
- **"the built-in formatter would change the code here, so nothing was changed"** — the formatter met code it
  cannot lay out safely and left the file as it was. Choose nph for that project (`"nim.formatter": "nph"` in
  its `.ned/settings.json`), and please report the file.
- **Something crashed** — start ned again and restore the offered edits; please report the stack trace it
  printed.

## Contributing

Bug reports, ideas, themes and code are welcome — [CONTRIBUTING.md](CONTRIBUTING.md) explains how ned is built,
laid out and tested. Security problems: please report them privately ([SECURITY.md](SECURITY.md)).

## License

MIT — see [LICENSE](LICENSE).
