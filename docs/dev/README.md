# Working on ned: the developer documentation

These pages explain how ned is built inside, for people (and AI agents) who want to change it. They say what
each part does and why it is built that way, with the files to open. The short versions are
[AGENTS.md](../../AGENTS.md) (build, test and the rules of the source on one page) and
[CONTRIBUTING.md](../../CONTRIBUTING.md) (how to send a change). The user documentation is in [docs/](../README.md);
the plugin *author* documentation is in [docs/plugins](../plugins/README.md).

| page | what it covers |
|---|---|
| [Architecture](architecture.md) | how `src/ned.nim` puts the program together, the modules compiled on their own, the main loop, global state |
| [Rendering](rendering.md) | how a frame is drawn: the cell grid, the diff sent to the terminal, regions and clicks, popups, layout, themes, pictures |
| [Editing](editing.md) | buffers, cursors, edits and the undo tree, highlighting, soft wrap, folding, big files, encodings, saving, keymaps, commands |
| [Engines](engines.md) | the Nim engine, the C/C++ engine, the web engines, nedls, and the scoreboard that guards their accuracy |
| [Integrations](integrations.md) | language servers, nimsuggest, the debugger, the terminal, git, the AI assistant, remote folders, the remote-control socket, settings sync |
| [The plugin host](plugins-host.md) | how ned runs plugins: the processes, the JSON-lines protocol, permissions, ned's own plugins, adding an API function |
| [Testing](testing.md) | every test suite, what it guards and how to run it; how to write a UI test |
| [Recipes](recipes.md) | step by step: a setting, a command, a dock view, a language, a theme, a finder, an API function, a test, a release |
| [Pitfalls](pitfalls.md) | the lessons that cost time — read it before your first change |

## A ten-minute tour

### 1. Build

ned is one program in Nim, standard library only. You need Nim 2.2 or newer and nothing else to build it; the tests
also want tmux, git and python3.

```sh
nim c -d:release --hints:off --compileOnly:on src/ned.nim    # does it compile? (about 2 minutes)
nim c -d:release --opt:speed -d:strip -o:ned src/ned.nim     # the editor (about 7 minutes)
```

`nimble typecheck` runs `nim check` on the whole program. The other two programs, `nedfmt` (the formatters) and
`nedls` (the engines as a language server), are built from the same sources: see
[Building, tasks and performance](../guide/building.md). The biggest C file needs a lot of memory: on a small
machine build one thing at a time.

### 2. Run it

Give it settings and state of its own, so your own are not touched and it starts as on a first run:

```sh
export XDG_CONFIG_HOME=$(mktemp -d) XDG_STATE_HOME=$(mktemp -d)
./ned src/ned.nim
```

Inside ned's own terminal `./ned FILE` opens the file in the ned you are in (see the remote-control socket in
[Integrations](integrations.md#the-remote-control-socket)); `./ned --new FILE` starts a second one.
*Help › Performance…* shows what a frame costs and what kept ned busy; `ned --startup-time` prints where the time
goes when it starts.

### 3. Run one UI test

```sh
python3 tests/ui/run.py --list                        # the tests' names
python3 tests/ui/run.py ./ned t_edit_save_undo        # one test: ned in a private tmux server, keys in, screen out
NED_UI_FULL=1 python3 tests/ui/run.py ./ned t_vim      # a failure prints the whole screen
```

The whole suite takes about an hour; run the tests near your change. [Testing](testing.md) has every suite.

### 4. Where to look first

| file | why |
|---|---|
| [`src/ned.nim`](../../src/ned.nim) | the list of the program's parts, in the order they are included — the table of contents of the source |
| [`src/ned/core/types.nim`](../../src/ned/core/types.nim) | `Buffer`, `Pos`, `Cursor`, `Cell`, `Key`, `Theme`, `Lang`, `Job`, `LspServer` … |
| [`src/ned/core/state.nim`](../../src/ned/core/state.nim) | the global state: the open buffers, the focus, the screen grid, the `cfg…` copies of the settings |
| [`src/ned/app/main.nim`](../../src/ned/app/main.nim) | `main` (start-up) and `mainLoop` (one round: wait, read keys, do background work in slices, draw) |
| [`src/ned/app/keyboard.nim`](../../src/ned/app/keyboard.nim) | `handleKey`: where every key and click goes |
| [`src/ned/editor/buffer.nim`](../../src/ned/editor/buffer.nim) | `replaceText`, the one way the text changes, and undo |
| [`src/ned/ui/frame.nim`](../../src/ned/ui/frame.nim) | `render`: one frame, from the layout to the last popup |
| [`src/ned/app/commandlist.nim`](../../src/ned/app/commandlist.nim) | every command of the palette — a good index of what ned can do |
| [`src/ned/config/settings.nim`](../../src/ned/config/settings.nim) | every setting with its default and description |

### 5. Follow one key press

A good way into the code is to follow the letter `a` typed into a file:

1. `mainLoop` (app/main.nim) waits in `poll` on the terminal's input, the programs it runs and its sockets.
   The terminal has bytes: `readInput` (core/keys.nim) appends them to `inBuf`.
2. `processInput` turns bytes into `Key`s with `parseKey` and hands each to `handleKey` (app/keyboard.nim).
3. `handleKey` gives the key to whatever is in front — a dialog, a menu, a form, the picker, a prompt — then to your
   own `keys` setting and the plugins' keys, then to the global keys (`globalKey`), then by focus. The editor has
   the focus: `editorKey`, where vim or helix may take it first, then `typeChar` (editor/editing.nim).
4. `typeChar` opens an undo group (`beginEdit`), changes the text at every cursor through `replaceText`
   (editor/buffer.nim) and closes the group (`endEdit`). `replaceText` records the change for undo, moves every
   cursor, and `rawReplace` bumps the buffer's `changeId`, marks the highlighting stale from that line, marks the
   file dirty for the language server and sets `needRender`.
5. At the start of the next round `needRender` is set: `render` (ui/frame.nim) draws the whole screen into a grid
   of cells, and `flushScreen` (core/screen.nim) sends the terminal only the cells that differ from what it shows.
6. The rounds after it do the rest when there is time: the language server is told after a pause, the engine
   worker works out type hints, the engine checks the file, the recovery file is written. None of it holds up the
   next key.

## The words these pages use

| word | meaning |
|---|---|
| buffer | an open file, or a tab without one (a diff, a scratch text, a multibuffer): `Buffer` in core/types.nim |
| pane | a part of the editor area showing a buffer; the editor can be cut into several (ui/split.nim) |
| dock | the side columns: left (files, search, git, Nim, tests) and right (assistant, outline, TODOs, timeline, plugins) |
| panel | the bottom area: output, search results, problems, terminal, debug |
| round | one turn of the main loop: a frame when one is due, the wait, input, background work |
| frame | one drawing of the screen (`render` then `flushScreen`) |
| region | a clickable rectangle registered while drawing a frame (ui/regions.nim) |
| engine | ned's own understanding of a language: the Nim index, the C index, the web engines |
| engine worker | a second ned process (`ned --engine-worker`) that works out hints and checks on another core |
| host | a process running plugins (`nim e`, or compiled) |
| job | a program ned runs in the background: a build, a check, git, curl (`Job`, run/process.nim) |
