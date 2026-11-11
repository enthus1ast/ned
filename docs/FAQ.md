# FAQ

Short answers, with a link to where each thing is explained in full. Something not here: *Help › Check setup*
(`ned --check`) and [Troubleshooting](guide/troubleshooting.md) cover most problems.

- [Installing and updating](#installing-and-updating)
- [Keys and the terminal](#keys-and-the-terminal)
- [Nim](#nim)
- [C and C++](#c-and-c)
- [Running and debugging](#running-and-debugging)
- [Formatting](#formatting)
- [The AI assistant](#the-ai-assistant)
- [Settings, files and privacy](#settings-files-and-privacy)
- [Speed and phones](#speed-and-phones)
- [Plugins](#plugins)
- [Reporting a problem](#reporting-a-problem)

## Installing and updating

**What does ned need?** Nim 2.2 or newer to build it — nothing else. Every other tool (git, ripgrep, gdb, clangd,
a language server, an AI key …) is optional and picked up when it is on your `PATH`; `ned --check` lists what it
found and how to install the rest. See [Installing](../README.md#installing).

**How do I install it on Termux?** Build it on the device: `curl -fsSL
https://raw.githubusercontent.com/foxoman/ned/main/install.sh | sh` does it with nimble, or by hand `pkg install nim
git`, then `nim c -d:release --opt:speed -d:strip -o:$PREFIX/bin/ned src/ned.nim` (or `nimble termux` in the project
folder). A ready-made package, if you have one — `pkg install ./ned_6.45.0_aarch64.deb` — brings ned, nedls and
nedfmt, and the example plugins in `$PREFIX/share/ned/plugins`.

**And on Linux, macOS, Windows?** Linux and macOS build from the source with one `nim c` (or `nimble install`).
On Windows, ned runs in WSL as on Linux — the tried way — or natively (experimental, since 6.21; built with `nim c`
as anywhere else). The [Installing](../README.md#installing) section has each one step by step.

**How do I update?** `ned --update` (or *Help › Update ned…*): it builds the newest version the way ned was installed
— with nimble, or a checkout pulled and built again. ned says by itself when a newer version is out (once a day;
`update.check`). Your
settings, sessions and plugins are kept: they are in your home folder, not next to the program
([Files ned uses](guide/files.md)).

**How do I start over?** *Reset everything* (File › Preferences, or the palette) or `ned --reset` removes ned's
settings, state, caches and downloads, and ned starts as on its first run.

## Keys and the terminal

**Where are the keys listed?** F1 in ned, and [Key bindings](guide/keys.md). Every command is also in the menus
(F10) and the palette (Ctrl+E, or Ctrl+P and `>`) — [every command](reference/commands.md) with its key.

**A key does nothing.** The terminal may keep it for itself or not send it. Alt keys: in Termux add ALT to the
extra-keys row (`~/.termux/termux.properties`); in macOS terminals turn on "Option as Meta". In kitty, WezTerm,
Ghostty and foot ned uses the kitty keyboard protocol — `"ui.kittyKeyboard": "off"` goes back to classic keys.
*Help › Check setup* shows what the terminal told ned it can do.

**Can I change the keys?** Yes: the `keys` setting (`{"ctrl+alt+u": "Upper case"}` — a command's palette name), or
choose a keymap: vim, Emacs or Helix ([Vim mode and zen mode](guide/vim-and-zen.md)).

**I cannot select text with the mouse to copy it.** ned takes the mouse; Alt+U gives it back to the terminal for a
moment. Or select in ned and Ctrl+C: ned copies to the system clipboard (OSC 52, `termux-clipboard-set`,
`wl-copy`, `xclip`, `pbcopy` — whichever is there).

**A long line I copied in Termux has a line break in it.** Termux's long press copies what is on the screen, and a
line too long for it is shown on two rows (↪): the copy has a line break there, and the ↪ and the line numbers.
Copy in ned instead: a triple tap selects the line, then **⧉ Copy** in the status bar (or Edit › Copy, Ctrl+C) puts
it on the clipboard whole.

**Swiping no longer scrolls in Termux after ned.** While ned runs it has the mouse, so a swipe goes to ned; it
gives the mouse back when it quits, and since 6.45 when it stops with a crash too (the shell then says ned stopped).
When Android ended it instead (see *Termux closed by itself* below), nothing can give it back and the terminal stays
as ned left it: `reset`, or
`printf '\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?1049l'`, and a swipe scrolls again. In ned's own Terminal panel a
swipe scrolls what the command printed (Shift+PgUp too).

**The colours or the emoji look wrong.** `"ui.trueColor": "on"` or `"off"`, and `"ui.graphemes"` for emoji — see
[Troubleshooting](guide/troubleshooting.md). Themes: [Themes and appearance](guide/themes.md).

## Nim

**Do I need nimsuggest or nimlangserver?** No. ned's own engine answers completion, hover, go to definition,
references, rename and the rest from its own reading of your code and the standard library — at once, without a
compiler process — and `nim check` gives the compiler's errors while you type. nimsuggest can be a second opinion
(`"nim.nimsuggest": true`); nimlangserver replaces the engine (*Nim: use nimlangserver*, `nim.ide`). See
[the Nim IDE](guide/nim.md).

**Can I use ned's Nim engine in another editor?** Yes: `nedls` is the engine as a language server (VS Code, Helix,
Neovim, Zed, Kakoune … — the setup for each is in [the Nim IDE guide](guide/nim.md#nedls-neds-engine-in-other-editors)).

**My project needs another Nim than the one on the PATH.** `nim.toolchain` (*Nim: choose the Nim for this
project…*): one Nim for every tool ned runs for that project ([One Nim per project](guide/nim.md#one-nim-per-project)).

**Nim 3 (Nimony)?** Supported: a project built with nimony gets its library, its errors and its checks; Nim 2 files
show what porting them needs ([the Nim IDE](guide/nim.md)).

**How do I see what my Nim compiles to?** *Compiler Explorer* — the assembly beside the code, live, as on
godbolt.org ([Compiler Explorer](guide/compiler-explorer.md)); *Nim: show generated C* for the C; *Decompile this
proc* for one proc of the built program.

## C and C++

**Do I need clangd?** No: ned's own C engine gives completion (struct members too), hover with a struct's layout,
go to definition through `#include`s, references, rename, signature help, parameter names, call hierarchy and the
compiler's own fixes. `c.engine` chooses: `auto` (clangd when it is installed), `builtin`, `clangd` or `both`.
Turning clangd off saves memory on a phone. See [C and C++](guide/c.md).

## Running and debugging

**How do I run my program?** Alt+R (or F5) runs the current file — `nim c -r` for Nim — with the output in the
Output panel and its errors in Problems; *Run › Configurations…* saves other ways to run it (arguments, defines,
release mode). Shift+F4 lists the project's tasks (Makefile, nimble, package.json …). See
[Running, testing and debugging](guide/run-and-debug.md).

**How do I debug?** F9 on a line sets a breakpoint, then F5: Nim is debugged with gdb (or lldb), Python, C, C++,
Rust, Go and JavaScript with their Debug Adapter Protocol debuggers. *Debug: check the debugger for this file*
says what is needed (Termux: `pkg install gdb`).

**My program reads from the keyboard.** The Output panel does not take input: use *Run in terminal (interactive)*.

**My C or Nim program crashes now and then.** *Run with memory checks* runs it with the compiler's address and
undefined-behaviour checks: an overflow, a use after free or a leak goes to Problems on its line — see
[Memory checks](guide/run-and-debug.md#memory-checks).

**Can I try code a piece at a time, as in Jupyter?** Put `# %%` lines in a Nim or Python file: Ctrl+Enter (or ▶ run)
runs a cell and shows its output under it — see [Notebooks](guide/run-and-debug.md#notebooks).

## Formatting

**Which formatter does Alt+F use?** For Nim, ned's own (nph's style; `nim.formatter` can choose nph or
nimpretty). For C and C++, ned's own in clang-format's styles — or clang-format itself (`c.formatter`). JSON,
Markdown tables, CSS, HTML, SQL, YAML and TOML have built-in ones too; `formatters` sets your own command for any
language. See [Formatting](guide/formatting.md).

**The formatter said it changed nothing.** It checks every result (the same tokens, the same structure) and leaves
the file alone when it is not sure. Choose nph for that project, wrap the part in `# fmt: off` … `# fmt: on`, and
please report the file.

**Can I keep a part of a file as I wrote it?** `# fmt: off` … `# fmt: on`, or `# fmt: skip` at the end of a
statement (C: `// clang-format off` … `on`).

## The AI assistant

**Which AI does it use?** The one you choose: Anthropic, OpenAI, OpenRouter, Groq, DeepSeek, Gemini, Mistral, any
OpenAI-compatible endpoint (`ai.provider`, `ai.model`, `ai.baseUrl`) — the key from an environment variable
(`ANTHROPIC_API_KEY`, `OPENAI_API_KEY` …, or `ai.apiKeyEnv`) or `ai.apiKey`. See [The AI assistant](guide/ai.md).

**Can it work offline?** Yes: *AI: on this device, offline (Ollama, llama.cpp)…* sets up a model on your machine —
on a phone too — and needs no key.

**Does it change my files without asking?** The agent asks before it edits a file or runs a command
(`ai.autoApprove`: none, reads, edits, all), shows its edits as a diff, checks them (`nim check` …) and can undo
them.

## Settings, files and privacy

**Where are the settings?** `~/.config/ned/config.json` — the Settings window (Ctrl+,) edits it, keeping its
comments; a project's own in `.ned/settings.json`. [Every setting](reference/settings.md) with its default;
[Settings](guide/settings.md) explains the rest (projects, sync).

**What does ned keep, and where?** [Files ned uses](guide/files.md): settings, state (recent files, sessions),
recovery files of unsaved edits, local history, caches — all in your home folder.

**Does ned send anything anywhere?** Only what you ask for: the AI provider you set up gets the messages you send
it (and the file, unless `ai.includeFile` is off); git talks to your remotes; a plugin list or a dictionary is
downloaded when you ask. There is no telemetry.

**Can a project's settings or plugins run code?** Not until you trust its folder (*Trust* on the notice, or
*Workspace: trust this folder*): until then ned's own engines read the code, but nothing in it runs — not the
compiler, its tests or the settings that start programs (`security.folderTrust`; see [Safety](guide/safety.md)).

## Speed and phones

**ned feels slow on my phone.** *Help › Performance report* says what takes the time and which setting would help —
often `"ui.minimap": "off"`, or `"nim.engineHints": false` on a big file. Nothing runs in the background by default
(nimsuggest is off); see [Building, tasks and performance](guide/building.md).

**Termux closed by itself while ned was busy.** Android closes apps when the phone runs out of memory, Termux with
them. ned runs at most two compiler checks at once, and when the system has little left (`ui.lowMemory`, 300 MB) it
keeps light: *mem low* in the status bar, checks on save only, its caches emptied. If it still happens, a smaller
`nim.indexMemory` (say 32) holds the engine to less, and closing tabs you do not need helps too.

**Does it work in portrait on a phone?** Yes: below 70 columns ned switches to a phone layout, and everything can be
tapped. A Nerd Font and `"ui.icons": "nerd"` give nicer icons.

## Plugins

**How do I write a plugin?** Start with the [tutorial](plugins/tutorial.md): a folder with a `plugin.nims` (NimScript)
in `~/.config/ned/plugins/<name>/`; *Plugins: new plugin…* makes one. Every proc is in the
[API reference](plugins/api.md); [Plugins](plugins/README.md) explains how they run.

**Where do I find plugins?** Nineteen come with ned, off until you turn one on: the menu bar's *Plugins › Plugins
panel*, then **AVAILABLE** — dial, which-key, oil, harpoon, rest-client, Odin, Gleam, Elixir, Haskell … ([the
list](plugins/available.md)). *Plugins: add an example…* (six examples, the tutorial's among them), *Plugins:
install from git…* and *Plugins: browse the plugin list…* (`plugins.indexUrl`) add others. Plugins run with your
rights: read one before you install it.

**A plugin says it waits for my OK.** It asks to do more than edit — run programs, change files, use the clipboard
or the network — and ned runs it only once you allow that: the note's *Review*, or *Plugins: permissions…*, shows
what it asks for, why, and where in its source. See [Permissions](plugins/README.md).

**How do I remove a plugin?** *Plugins › Uninstall…*, or tap it in the Plugins dock: *Uninstall…* deletes the
folder of one you installed (it asks first); one of ned's own goes back to AVAILABLE.

## Reporting a problem

*Help › Copy info for bug report* copies what a report needs (versions, the terminal, the tools found). Internal
errors are written to `~/.local/state/ned/errors.log` — please attach it. [CONTRIBUTING.md](../CONTRIBUTING.md)
explains how ned is built and tested; security problems go privately, as [SECURITY.md](../SECURITY.md) says.
