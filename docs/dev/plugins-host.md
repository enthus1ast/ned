# The plugin host

How ned runs plugins: where they come from, the processes that run them, the messages between ned and a plugin,
permissions, ned's own plugins, and how to add a function to the plugin API. How to *write* a plugin is in the
plugin author documentation — [Plugins](../plugins/README.md), the [tutorial](../plugins/tutorial.md) and the
[API reference](../plugins/api.md) — and is not repeated here.

The code is [`src/ned/plugins/host.nim`](../../src/ned/plugins/host.nim) (ned's side),
[`src/ned/plugins/perms.nim`](../../src/ned/plugins/perms.nim) (permissions),
[`src/ned/plugins/decor.nim`](../../src/ned/plugins/decor.nim) (signs, notes after a line, highlights) and the
library plugins import, [`src/ned/plugins/lib/nedplugin.nim`](../../src/ned/plugins/lib/nedplugin.nim) (with
`nedlsp.nim` for language servers written in NimScript).

## Where plugins come from

`plugDiscover` finds them:

| plugins | folder | notes |
|---|---|---|
| yours | `~/.config/ned/plugins/<name>/` | `plugin.nims` (NimScript) or `plugin.nim` (full Nim) |
| a project's | `<project>/.ned/plugins/<name>/` | run only once you trust the folder |
| ned's own | `plugins/<name>/plugin.nims` in ned's source | read into ned when it is built; off until turned on (`plugins.bundled`) |
| the examples | `examples/plugins/` | read into ned too (`PlugExamples`); *Add an example* copies one to your folder |

ned's own plugins and `nedplugin.nim` itself are compiled into the ned binary with `staticRead`. At run time they
are written to the cache (`~/.cache/ned/plugins/bundled-<hash>/`, `lib-<hash>/`) once per version of them. So a
change to a plugin in `plugins/` or to the library reaches the editor only with a new build of ned.

## The processes

A `PlugHost` is one process running plugins:

- the NimScript plugins share one process, named `*` (`PlugShared`);
- a plugin in full Nim (`plugin.nim`) is compiled into a program of its own;
- `plugins.alone` gives a NimScript plugin a process of its own.

ned writes the host's source (`plugHostSource`) — `import nedplugin`, one `import "<plugin file>" as nedPlugN` per
plugin, then `nedRun()` — and runs it either with `nim e --path:<lib> host.nims`, or compiled: `plugBuild` runs
`nim c -d:release` as a background job into `~/.cache/ned/plugins/native/host-<signature>`. With
`plugins.native` set to `auto`, a set of plugins you keep is compiled in the background for the next start (one
you changed in the last ten minutes is not: it is still being written). A compile error of a plugin goes to
Problems, on its line.

Each process starts with `NED_PLUGIN_DIRS` (lines of `id=folder`), so the library can tell which plugin a registration
comes from (`pluginOf`). Its state — `off`, `building`, `starting`, `ready`, `failed: …`, `stopped` — and its log
(whatever a plugin `echo`es) show in the Plugins dock.

### Starting late, and the manifest

Plugins never slow ned's start. `plugBoot` runs after the first frame: it finds the plugins, makes the hosts, and
reads the **manifest** (`~/.cache/ned/plugins/manifest.json`): the registrations each host made the last time it ran
the same plugins (same signature). So the plugins' commands and keys are there at once, without a process. A host
is started right away only when it must run from the start (`plugEagerHost`: timers, text objects, completion,
hover, symbols, code actions, views, a formatter of its own, or the events `startup`, `open`, `change`,
`beforeSave`, `keys`); otherwise it starts on its first call, which waits in `h.queue` until the host is ready. A
host that is not needed from the start and has had nothing to do for `plugins.idleStopMinutes` is stopped, and starts
again the same way.

## The protocol

ned and a plugin host talk in **JSON lines** over the host's stdin and stdout. A line the host writes that starts
with `\x1e` (the record separator, `PlugMark` / `ProtoMark`) is a message; any other line is the plugin's log.

From the plugin to ned:

| message | meaning |
|---|---|
| `{"t":"reg","kind":"command","plugin":"p","cb":3, …}` | a registration made by the plugin's top-level code: a command, a key, an event, a language, a formatter, a language server, completion, hover, a vim mapping, a timer, a view … with the number of its callback |
| `{"t":"ready"}` | the top-level code has run: the registrations are complete (`plugReady`) |
| `{"t":"api","id":7,"fn":"replace","args":{…},"plugin":"p","rid":12}` | a call of ned's API, made while running ned's call number `rid` |
| `{"t":"ret","rid":12,"value":…}` or `{…,"err":"…"}` | the answer to ned's call |

From ned to the plugin:

| message | meaning |
|---|---|
| `{"t":"call","cb":3,"rid":12,"args":{…},"vers":{…},"cur":4}` | run callback 3 (`plugSendCall`) |
| `{"t":"res","id":7,"value":…}` or `{…,"err":"…"}` | the answer to API call 7 (`plugAnswer`) |
| `{"t":"quit"}` | stop |

A host runs one call at a time. Inside a call, the plugin's `api()` waits for its answer; ned's calls that arrive
meanwhile are queued and run after it. ned answers API calls in `plugApi`, as they arrive in the main loop's round.

### The vers and cur copies

Reading a file line by line would be one round trip per line. So each call carries `vers` — for the current buffer
and the event's buffer, their version (`changeId:lineCount`, `plugBufVer`) — and `cur`, the current buffer's id. The
library uses them:

- `current()` answers from `cur` without asking;
- the second read of a buffer at the same version asks for the whole text once (`snapshot`) and answers every
  further `line`, `lines` or `lineCount` from that copy;
- any API call that is not in `ReadOnlyApi` (an edit, or anything that may lead to one) forgets the versions: the
  copies are not trusted any more.

### Edits, waiting, timers, events

- **One undo step per call.** The first edit a call makes in a buffer notes where the buffer's undo history was
  (`plugMarkEdit`); when the call ends, everything it changed is merged into one step (`plugCallDone`, `mergeUndo`).
- **Waiting for an answer.** Some features need the plugin's answer before they go on: formatting before a save, a
  text object, a vim operator. `plugCallSync` waits up to `plugins.timeoutMs` (1500 ms), and while it waits it
  handles the host's messages (`plugWaitFor`), so the plugin can use the API meanwhile. It only waits for a host that
  is ready; one still starting answers "not now".
- **Timers** (`every`, `after`) are registrations of kind `timer`; `plugNextDueMs` tells the main loop when the next
  is due and `plugPump` fires it.
- **Events** go to every registration whose pattern matches the buffer (`plugFire`, `plugMatches`: `*`, `*.md`,
  `lang:nim`, or a path with `/`): opening, before saving, saving, closing, changes (after a pause), start, quit,
  pending keys, entering a buffer.

### From registrations to features

`plugApplyRegs` turns the registrations into the editor's things: commands in the palette, keys (`plugKeys`, after
your own `keys` in `customKey`), events (`plugEvts`), languages (`plugLangSpecs`, made into `Lang`s by
`applyUserLanguages`), formatters, language servers (a NimScript one runs through `ned --lsp-bridge server.nims`,
`lspBridge`, which adds the protocol's framing), providers of completion, hover, code actions and symbols
(`plugProviders`), vim mappings, operators, text objects and `:` commands, tools for the assistant, views in the
Plugins dock, which-key hints.

## Permissions

A plugin may edit text and show things freely. Four things need your OK: running programs (`shell`), the network,
changing files (other than the plugin's own data folder and the project's files it saves through ned), and the
clipboard. [`plugins/perms.nim`](../../src/ned/plugins/perms.nim):

1. **Before it runs**, ned reads the plugin's source (`plugScanText`): the names it uses outside comments and
   strings, its imports and pragmas, and what it says it needs each permission for (`permission("shell", "why")`).
   Code ned cannot read ahead — `importc`, `emit`, `asm`, building code from text with macros — counts as asking for
   everything.
2. **You are asked once** (`plugAskPerms`); the answer is kept by plugin in the state folder's
   `plugin-permissions.json` (a project's plugin by project too). A plugin that asks for more than you allowed waits,
   and says so. ned's own plugins are asked about when you turn them on.
3. **At run time**, `plugApi` refuses what was not allowed (`need(pp)` at its top): `shellAsync` and `terminal`
   without `shell`, the clipboard without `clipboard`, a command that runs programs, a save outside the project and the
   plugin's data folder without `files`. The plugin gets an error answer that names the permission.

## ned's own plugins

| what | where |
|---|---|
| the plugin | `plugins/<name>/plugin.nims` — one file; its first line is `## <name> — what it does` (shown in the Plugins dock) |
| the list | `PlugBundledNames` in `src/ned/plugins/host.nim` (every folder must be in it, and every name must have its folder) |
| turned on | the `plugins.bundled` setting (the Plugins dock's AVAILABLE list, *Plugins › Available plugins…*) |
| its checks | `tests/plugins/bundled/test_<name>.py` (dashes as underscores): a `run(factory, tag)` that starts the plugin in a host, plays ned's side and checks what it does |
| the users' list | [docs/plugins/available.md](../plugins/available.md) |

[`tests/plugins/tbundled.py`](../../tests/plugins/tbundled.py) runs every plugin's checks, in `nim e` and (with
`--native`) compiled, and checks that the folders, the list, the first lines and the test files agree.
`tests/plugins/bundled/langcheck.py` has the checks the language plugins share. [Recipes › Add a
language](recipes.md#add-a-language) shows a language as a plugin.

## Adding a function to the plugin API

An API function lives in two places — the library (the plugin's side) and `plugApi` (ned's side) — and is played
by the tests' imitation of ned. End to end:

1. **The library.** In `src/ned/plugins/lib/nedplugin.nim` (or `nedlsp.nim`), add an exported proc with a `##` doc
   comment, under the `# ── section ──` comment it belongs to (the reference is made from both). It calls
   `api("myFn", %*{"buf": b.id, …})` and turns the answer into a Nim value. If it only reads, add `"myFn"` to
   `ReadOnlyApi`, so the line copies stay trusted. Keep it to what NimScript can run (`nim e` has no `osproc`,
   sockets or threads), or guard it with `when not defined(nimscript)`.
2. **ned's side.** In `plugApi` in `src/ned/plugins/host.nim`, add `of "myFn":` — `needBuf()` when it takes a buffer;
   for an edit, `b.canEdit()`, `plugMarkEdit(h, rid, b)`, then `beginEdit`, `replaceText`, `endEdit`; `needRender = true`
   when the screen changes; and exactly one `answer(value)` or `answer(nil, "why not")` on every path (the
   plugin waits until it gets one). An answer may come later: `pick`, `ask` and `confirm` keep the call's id and
   answer when you choose — and answer at once with nothing while ned is itself waiting for the plugin. Something that
   needs a permission gets a `need(pp…)` line in the checks at the top of `plugApi`, and its name in the lists
   `perms.nim` scans for.
3. **The tests' ned.** [`tests/plugins/tplugins.py`](../../tests/plugins/tplugins.py) (`Host.api`) and
   `tests/plugins/tbundled.py` (`BHost.api`) answer the API as ned would: answer `myFn` there. Use it in the API test
   plugin (`tests/plugins/fixtures/apitest/plugin.nims`) with a check in `tplugins.py`, and where it matters add a UI
   test with the real host (`t_622_plugin_api` in `tests/ui/suite.py` is one).
4. **The documentation.** `python3 tests/docs/apiref.py` writes [docs/plugins/api.md](../plugins/api.md) from the
   doc comments (CI runs it with `--check`). If it changes how plugins are written, the tutorial too.
5. **The version.** A plugin that uses it says `requiresNed(">= <the version that has it>")`; ned leaves out the
   registrations of a plugin that needs a newer ned.

Then build ned again: the library is compiled into it.

## When a plugin misbehaves

- Its log, its state and its errors are in the Plugins dock; `plugLog` keeps the last lines (what it `echo`es, the
  errors of its calls, the API calls refused).
- A plugin that does not compile is left out, with its errors in Problems, and the others go on.
- A host that dies (`plugHostDied`): the plugin whose error it printed is left out until its file changes, the
  others start again, and the calls that waited get an error answer.
- A call ned waits for that takes longer than `plugins.timeoutMs` is given up and logged; any other call with no
  answer after a minute is given up too (the plugin may be stuck: *Reload*).
