# Announcing ned, a terminal code editor and Nim IDE

*By Foxoman. This post comes with ned 6.35.0.*

![A nimble project in ned: the Files dock, inlay hints and the assistant explaining the file](../../screenshots/nimble-ai.png)

ned is a code editor for the terminal and an IDE for Nim. It runs in any terminal but behaves like a desktop editor:
menus, docks, tabs, split panes, and mouse and touch support. It is written in Nim, uses only Nim's standard
library, and builds to a single program, with nothing else to install.

It runs on Linux, on Android in Termux, and on Windows. I use it every day on an Android tablet, in Termux. It is
for people who write Nim and want an IDE with no language server beside it, and for anyone who wants a capable
editor on a phone, a tablet or a small machine.

## Highlights

**A Nim engine that needs no language server.** ned reads your files, the standard library and your nimble packages
as you work. Completion (with the documentation beside the list), hover, Go to definition, signature help,
references, rename and the outline are answered by ned itself, with no compiler run and no server process. Errors
appear as you type, from the compiler and from ned's own checks (unused imports, field typos, wrong argument
counts). Nothing stays running in the background, which suits a phone's memory.

![Member completion from the built-in Nim engine, with the documentation beside the list](../../screenshots/completion-docs.png)

**Nim 2.4 and Nim 3.** With Nim 2.4 or newer, a save asks the compiler for its own reading of the file. Names are
coloured by what they are, types appear after your `let`s and `var`s where the engine had none, and Go to
definition goes to the declaration the compiler chose. When a project has Nimony's files and `nimony` is installed,
ned treats it as Nim 3: `nimony` checks it as you type and runs it (F5). For a Nim 2 file, *Nim 3: what this file
needs* lists the changes porting calls for in the Problems dock. ned can install `nimony` for you.

**A formatter.** Alt+F formats in nph's style. Turn on `"editor.formatOnSave": true`, and with
`"editor.formatOnSaveScope": "changed"` only the lines you changed are formatted, so an old file does not become a
big diff. The formatter is built in for Nim, JSON, Markdown, CSS, HTML, SQL, YAML and TOML. C and C++ use
clang-format's styles. `nedfmt` runs the same formatters from the shell, in CI and as a pre-commit hook.

**An AI assistant.** Alt+C opens it. It answers questions about your code, and as an agent it can read and search
files, edit them and run commands. You approve each edit and each command, and its edits are checked with
`nim check` and the like. Use Anthropic, OpenAI, Gemini and other providers, any OpenAI-compatible endpoint, or a
model on the device with Ollama or llama.cpp, offline. Secrets are replaced with placeholders before anything is
sent, and files such as `.env` are not sent at all.

![An AI edit waiting for approval as a diff](../../screenshots/ai-diff-approval.png)

**Terminal, git, debugger and plugins.**

- A real terminal in the bottom panel (`Ctrl+\` or ``Alt+` ``). vim, htop, git and ssh work in it.
- A git dock: stage, commit, push, pull, log and diff, with blame, interactive rebase, bisect and a merge editor.
- A debugger. F9 sets a breakpoint and F5 starts the program under it: gdb for Nim, a Debug Adapter Protocol
  debugger for other languages.
- Plugins written in NimScript. Seventy-three of ned's own come with it, off until you turn one on, and each asks
  before it runs programs, changes files or uses the clipboard. The [tutorial](../plugins/tutorial.md) builds one.

**Made for a phone or tablet as much as a desktop.** Below 70 columns ned switches to a phone layout, and everything
can be tapped. Every command is in the menus and the palette, and Termux's extra-keys row reaches every shortcut.

## Install

To build ned you need Nim 2.2 or newer and nothing else. Other tools are optional and picked up when they are on your
`PATH`.

**1. Termux: the package from the release page.** Download `ned_6.35.0_aarch64.deb` from the
[releases](https://github.com/foxoman/ned/releases), then install it. It brings ned, nedls and nedfmt.

```sh
pkg install ./ned_6.35.0_aarch64.deb
```

**2. nimble, straight from GitHub.** This builds `ned`, `nedfmt` and `nedls` into `~/.nimble/bin`, and it takes a
few minutes.

```sh
nimble install https://github.com/foxoman/ned
```

Once ned is in Nim's package list, `nimble install ned` will do the same.

**3. From source.**

```sh
git clone https://github.com/foxoman/ned
cd ned
nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim
```

This takes a few minutes too. Move `ned` onto your `PATH`, for example `sudo mv ned /usr/local/bin/` on Linux.

On Windows, a release has a zip with `ned.exe`, `nedfmt.exe` and `nedls.exe`. Native Windows is experimental; WSL is
the tried way. [Installing](../../README.md#installing) in the README covers each system, macOS too.

## First steps

```sh
ned                      # the folder you are in, reopening the files you had open
ned src/app.nim:42:7     # a file at line 42, column 7
ned --check              # what ned found on this system, and how to install what is missing
```

- **F10** opens the menus, **Ctrl+E** the command palette, and **F1** the key bindings.
- **Ctrl+P** finds a file. Type `:42` for a line, `@name` for a symbol, `#name` for a project symbol, and `>` for
  commands.
- Click or tap anything: tabs, gutter markers, dock items and buttons.

## Use ned's engine in your editor

The same Nim engine runs without ned's screen as `nedls`, a language server for VS Code, Neovim, Helix, Zed, Emacs,
Kate and Sublime. `nimble install` builds it next to ned. The set-ups for each editor are in
[the Nim IDE guide](../guide/nim.md#nedls-neds-engine-in-other-editors).

## What's next, and how to get involved

The [changelog](../../CHANGELOG.md) lists what each release changed. One thing is still to do: ned is not in Nim's
package list yet, so `nimble install ned` waits on that.

Bug reports, ideas, themes, documentation and code are welcome on
[GitHub](https://github.com/foxoman/ned/issues). Run `ned --check` first, and paste *Help › Copy info for bug report*
into the issue. [CONTRIBUTING.md](../../CONTRIBUTING.md) explains how ned is laid out and tested. Please report
security problems privately, as [SECURITY.md](../../SECURITY.md) says.

## Licence

ned is free software under the GNU General Public License, version 3 or (at your option) any later version
(`GPL-3.0-or-later`). The full text is in [LICENSE](../../LICENSE). Plugins may use any licence: the plugin library
they import comes with the [ned Plugin Exception](../../PLUGIN-EXCEPTION.md).
