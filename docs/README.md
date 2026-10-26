# ned's documentation

New to ned? Read [Installing](../README.md#installing) and [First steps](../README.md#first-steps) in the README,
then keep [Key bindings](guide/keys.md) at hand. The [FAQ](FAQ.md) has short answers; F1 in ned shows the keys, and
every command is in the menus (F10) and the palette (Ctrl+E).

## Using ned

| guide | what it covers |
|---|---|
| [Key bindings](guide/keys.md) | every key, by what it is for |
| [Files, folders and projects](guide/projects.md) | starting ned, the project folder, the file tree, Ctrl+P, tabs, splits, sessions |
| [Editing](guide/editing.md) | cursors and selections, surround, snippets, the undo tree, macros, folding, the Markdown preview, spell check, encodings, big files, CSV |
| [Search and replace](guide/search.md) | in the file and in the project, multibuffers |
| [Running, testing and debugging](guide/run-and-debug.md) | running a file, run configurations, tasks, tests, coverage, the debugger, the REPL, notebooks, memory checks, profiling and flame graphs |
| [Git](guide/git.md) | the dock, the changes view, blame, history, rebase, bisect, GitHub |
| [The AI assistant](guide/ai.md) | chat, the agent, providers, models on your device, MCP |
| [Formatting](guide/formatting.md) | Nim in nph's style and every `nim.format.*` setting, C in clang-format's styles, `nedfmt`, other languages |
| [The terminal and remote work](guide/terminal.md) | the integrated terminal, scripting a running ned, folders over SSH, workspaces |
| [Themes and appearance](guide/themes.md) | the themes, your own colours, icons, accessibility |
| [Vim mode and zen mode](guide/vim-and-zen.md) | vim, Emacs and Helix keys; writing without distractions |
| [Settings](guide/settings.md) | where they live, a project's own, settings sync |
| [Hex editor, programs and the decompiler](guide/hex-and-binaries.md) | pictures, binary files, a program's sections and symbols, decompiling a proc |

## Languages

| guide | what it covers |
|---|---|
| [The Nim IDE](guide/nim.md) | the built-in engine, nedls in other editors, lint rules, quick fixes and rewrites, one Nim per project, nimsuggest and nimlangserver, Nimony |
| [C and C++](guide/c.md) | ned's own C engine, or clangd |
| [Compiler Explorer](guide/compiler-explorer.md) | the machine code beside your Nim, C or C++, live |

## Plugins

| page | what it covers |
|---|---|
| [Plugins](plugins/README.md) | what a plugin can do, how they run, permissions, installing and managing them |
| [ned's own plugins](plugins/available.md) | the fifty-eight that come with ned — dial, which-key, oil, harpoon, todo, indent-dots, rainbow-indent, rest-client, nim-html, Odin, Gleam, Swift … — and how to turn one on |
| [Tutorial](plugins/tutorial.md) | a plugin built step by step — its result is `examples/plugins/notes`, run by the plugin tests |
| [API reference](plugins/api.md) | every type and proc of `nedplugin` and `nedlsp` (made from their doc comments) |

## Reference

| page | what it covers |
|---|---|
| [Settings](reference/settings.md) | every setting, its default and what it does (`ned --doc-settings`) |
| [Commands](reference/commands.md) | every command of the palette, with its key (`ned --doc-commands`) |
| [Files ned uses](guide/files.md) | settings, state, caches, recovery files |
| [Safety](guide/safety.md) | atomic saves, recovery, local history, folder trust |
| [Troubleshooting](guide/troubleshooting.md) | when something does not work |

## Working on ned

| page | what it covers |
|---|---|
| [Building, tasks and performance](guide/building.md) | building ned, its nimble tasks, why it is fast, the source's layout |
| [Developer documentation](dev/README.md) | how ned works inside — architecture, rendering, editing, engines, integrations, the plugin host, testing — with recipes and pitfalls |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | how to send a change |
| [AGENTS.md](../AGENTS.md) | the short version for AI agents: build, test, the source's rules |
| [tests/README.md](../tests/README.md) | the tests and how to run them |
| [CHANGELOG.md](../CHANGELOG.md) | what changed in each release |

The references and the API page are made from the sources, and CI checks that they are up to date and that every
link in these pages goes somewhere (`tests/docs/`). To fix a setting's or a command's text, change it in the
source (`src/ned/config/settings.nim`, `src/ned/app/commandlist.nim`) and run `ned --doc-settings >
docs/reference/settings.md` / `ned --doc-commands > docs/reference/commands.md`; for the API, `python3
tests/docs/apiref.py`.
