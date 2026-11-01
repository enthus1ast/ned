# Plugins

A plugin adds to ned what it does not do by itself: a command, a key, a language, a formatter, a check of your
files with quick fixes, a view in the Plugins dock, a tool for the assistant. This page says what plugins can do,
area by area, and how they run. New to writing one? The [tutorial](tutorial.md) builds one step by step, the
[cookbook](cookbook.md) has a whole plugin for each area below, and the [API reference](api.md) documents every
proc and type. ned comes with plugins of its own, off until you turn one on: [ned's own plugins](available.md).

- [A first plugin](#a-first-plugin)
- [What plugins can do](#what-plugins-can-do)
- [How plugins run](#how-plugins-run)
- [Permissions](#permissions)
- [Where things are](#where-things-are)
- [Settings](#settings)
- [Versions and updates](#versions-and-updates)
- [Debugging a plugin](#debugging-a-plugin)
- [Limits](#limits)
- [Testing a plugin](#testing-a-plugin)
- [The examples](#the-examples)

## A first plugin

A plugin is a folder with a `plugin.nims` — NimScript, the Nim of `config.nims` — or a `plugin.nim`, a plugin in
full Nim. Yours are in `~/.config/ned/plugins/<name>/`; a project's in `.ned/plugins/<name>/` run once you trust
the folder. The folder's name is the plugin's: letters, digits, `-`, `_` and `.`, up to 64.

*Plugins: new plugin…* (and *new plugin in full Nim…*) makes one from a template, *Plugins: add an example…*
copies one of [the examples](#the-examples), *Plugins: install from git…* clones a repository that has a
`plugin.nims` (or `plugin.nim`) at its top, *Plugins: browse the plugin list…* installs from a list
(`plugins.indexUrl`: a URL or a file of JSON, `[{"name", "url", "description"}]`), and *Plugins: update* pulls
the ones that came from git. Saving a plugin's file reloads it (*Plugins: reload one…* too). While you write
one, `import nedplugin` (and `nedlsp`) resolves wherever the plugin is: every proc, type and field of the API has
its hover with its doc, completion after `b.` lists what a buffer offers, and NimScript's own procs (`exec`,
`readFile` …) are there too.

```nim
import nedplugin

requiresNed(">= 6.31")                               # an older ned leaves it out, and says why
pluginInfo(version = "1.2.0", author = "You", homepage = "https://…", license = "MIT")   # shown in the dock

command "Upper-case the line", "ctrl+alt+u":       # the palette (and the Plugins dock), on a key
  let b = current()
  let l = b.cursor.line
  b.replace(b.lineRange(l), b.line(l).toUpperAscii)  # a command's edits are one undo step

onSave("*.md") do (ev: Event):
  status("saved " & $ev.buf.lineCount & " lines")    # an item in the status bar

hover("zig") do (b: Buf, p: Pos) -> string:          # under ned's own hover
  "**" & b.wordAt(p) & "**"
```

A plugin's top-level code runs once, when it starts: it registers what it has, and ned calls it back. Three
rules hold everywhere: **lines and columns count from 0, and a column is a byte offset in the line** (UTF-8);
**a `Range` goes from `start` up to `stop`**, `stop` not included; and **all the edits of one callback are one
undo step**.

## What plugins can do

Each area has a short example, the entries of the [API reference](api.md) it uses, and a plugin of the
[cookbook](cookbook.md) that does it whole.

### Commands and keys

A command is in the palette (Ctrl+E) and the Plugins dock, on a key when you give one. Your `keys` setting wins
over a plugin's key, and a plugin's key over ned's own. `runCommand` runs one of ned's commands by its name.

```nim
command "Copy the file's name", "ctrl+alt+n":
  message(extractFilename(current().path))
```

[`command`](api.md#command) · [`runCommand`](api.md#runcommand) · cookbook:
[a command on a key](cookbook.md#1-a-command-on-a-key-and-vim-mappings)

### Events

A file opened, saved, changed (after a pause in the typing), brought to the front, closed; ned starting and
quitting; a run, build or test of yours ending (`onJobDone`: what it was, its exit code, how long it took). ned waits for `onBeforeSave` — what it changes is saved — and for `onQuit`, a moment; not for the
others. The pattern says which files: `"*"`, `"*.md"`, `"src/*.nim"`, `"lang:zig"`, several with commas.
`autocmd` takes vim's names.

```nim
onBeforeSave("*.txt") do (ev: Event):
  let t = ev.buf.text
  if t.endsWith(" "): ev.buf.setText(t.strip(leading = false))
```

[`onOpen`](api.md#onopen) · [`onBeforeSave`](api.md#onbeforesave) · [`onSave`](api.md#onsave) ·
[`onChange`](api.md#onchange) · [`onEnter`](api.md#onenter) · [`onClose`](api.md#onclose) ·
[`onStartup`](api.md#onstartup) · [`onQuit`](api.md#onquit) · [`onJobDone`](api.md#onjobdone) · [`autocmd`](api.md#autocmd) ·
[`Event`](api.md#type-event)
· cookbook: [events](cookbook.md#2-events)

### Reading and changing the text

`current()` is the file being edited, a `Buf`; everything about a file is asked through it — its lines, its
text, the cursor, the selections of each cursor — and changed through it. `setText` changes only the lines that
differ.

```nim
let b = current()
for r in b.selections:                     # (sort them and go from the last to edit several)
  log(b.textIn(r))
b.insert(pos(0, 0), "# " & localTime()[0 ..< 10] & "\n")
```

[`current`](api.md#current) · [`buffers`](api.md#buffers) · [`openFile`](api.md#openfile) ·
[`lines`](api.md#lines) · [`textIn`](api.md#textin) · [`replace`](api.md#replace) · [`setText`](api.md#settext)
· [`selection`](api.md#selection) · [`selections`](api.md#selections) · [`select`](api.md#select) ·
[`setCursor`](api.md#setcursor) · [`wholeLines`](api.md#wholelines) · [`wordAt`](api.md#wordat) ·
[the whole section](api.md#buffers-the-text) · cookbook: [reading and changing the text](cookbook.md#3-reading-and-changing-the-text)

### Tabs of a plugin's own

`newTab` opens a tab with a text that is not a file: a report, a response, a pad. Give it a language of the
plugin's own, and saving it (`onSaveTab`) and keys in it (`keyIn`, `nmapIn`) are the plugin's — oil's folder
view is one.

```nim
let b = newTab("Report", report.join("\n"), "markdown")
onSaveTab("scratch") do (ev: Event):
  writeData("scratch.md", ev.buf.text)
  ev.buf.markSaved()
```

[`newTab`](api.md#newtab) · [`onSaveTab`](api.md#onsavetab) · [`markSaved`](api.md#marksaved) ·
[`keyIn`](api.md#keyin) · [`setTitle`](api.md#settitle) · [`closeTab`](api.md#closetab) · cookbook:
[a tab of the plugin's own](cookbook.md#18-a-tab-of-the-plugins-own)

### Panes and multibuffers

The editor can be cut into panes (*View › Panes*): a plugin lists them with their files, gives one the focus,
shows a file in one, cuts one in two or lays them out. A multibuffer is one tab made of pieces of many files,
edited as one text — Ctrl+S writes each piece back to its file: a plugin makes one from any lines it finds, reads
its pieces, adds to it, and maps a place in it back to its file.

```nim
var ps: seq[Piece]
for (path, line) in found: ps.add piece(path, max(0, line - 1), line + 1)
let mb = openMultibuffer("unsafe casts", ps)
discard splitPane(show = openFile("tests/test_cast.nim"))
```

[`panes`](api.md#panes) · [`splitPane`](api.md#splitpane) · [`focusPane`](api.md#focuspane) ·
[`closePane`](api.md#closepane) · [`showInPane`](api.md#showinpane) · [`paneLayout`](api.md#panelayout) ·
[`openMultibuffer`](api.md#openmultibuffer) · [`pieces`](api.md#pieces) · [`placeInFile`](api.md#placeinfile) ·
[`lineInMultibuffer`](api.md#lineinmultibuffer) · [`addPiece`](api.md#addpiece) · [`removePiece`](api.md#removepiece)
· [`refreshMultibuffer`](api.md#refreshmultibuffer) · cookbook: [panes and multibuffers](cookbook.md#21-panes-and-multibuffers)

### Talking to you

A line in the status line, a note in the corner, a list to choose from, a line of text, a yes or no. `pick`,
`ask` and `confirm` wait for your answer (the plugin waits; ned does not).

```nim
let i = pick("Which one?", ["first", "second"], ["the dimmer text", "beside each"])
if i >= 0 and confirm("Use the " & ["first", "second"][i] & "?"): toast("done")
```

[`message`](api.md#message) · [`warn`](api.md#warn) · [`toast`](api.md#toast) · [`pick`](api.md#pick) ·
[`ask`](api.md#ask) · [`confirm`](api.md#confirm) · cookbook: [asking you](cookbook.md#13-asking-you-pick-ask-confirm)

### Problems and quick fixes

A plugin's problems in a file are underlined, listed in the Problems panel and marked in the gutter; Alt+Enter
on a problem's line offers its fixes. All of a file's problems go in one request.

```nim
let r = b.lineRange(3)
b.setProblems([Problem(range: r, severity: 2, message: "a long line",
                       fixes: @[Fix(title: "Cut it", edits: @[Edit(range: r, text: b.line(3)[0 ..< 100])])])])
```

[`setProblems`](api.md#setproblems) · [`Problem`](api.md#type-problem) · [`Fix`](api.md#type-fix) ·
[`Edit`](api.md#type-edit) · cookbook: [problems and quick fixes](cookbook.md#5-problems-and-quick-fixes)

### Marks in the editor

A sign in the gutter, text after a line's end, a tinted background, each the plugin's own until it clears
them. `indentStyle` says once how indentation looks — dots, a colour for each level, a band where it is wrong —
and ned draws it with each line: nothing is sent per line.

```nim
b.sign(4, "●", "warn")
b.virtualText(4, "← 3 ms")
b.highlight(rng(pos(4, 0), pos(4, 5)), "accent")
indentStyle(IndentStyle(levels: @["warn", "add", "info"], wrongColor: "error"))
```

[`sign`](api.md#sign) · [`virtualText`](api.md#virtualtext) · [`highlight`](api.md#highlight) ·
[`clearDecorations`](api.md#cleardecorations) · [`indentStyle`](api.md#indentstyle) ·
[`IndentStyle`](api.md#type-indentstyle) · cookbook: [signs, text after a line, highlights](cookbook.md#4-signs-text-after-a-line-highlights-the-indentation)

### The status bar, progress, the Output panel, the terminal

Each plugin has one item in the status bar, and one for work under way. `output` writes lines in the Output
panel, where a `file:line:col` can be clicked; `runInTerminal` runs a command in ned's terminal.

```nim
progress("Indexing", 40)
output("src/app.nim:12:5: a TODO is left")
showOutput()
runInTerminal("nimble test")
```

[`status`](api.md#status) · [`progress`](api.md#progress) · [`progressDone`](api.md#progressdone) ·
[`output`](api.md#output) · [`showOutput`](api.md#showoutput) · [`runInTerminal`](api.md#runinterminal) ·
cookbook: [the status bar](cookbook.md#17-the-status-bar), [progress and output](cookbook.md#14-progress-the-output-panel-the-terminal)

### Views in the Plugins dock

A section of the Plugins dock with rows of the plugin's: a text, a dimmer detail, an icon, a colour, a depth for
a tree. A row with a path opens that file when clicked; a row with an id calls the plugin back.

```nim
view("Open files") do () -> seq[ViewItem]:
  for b in buffers(): result.add ViewItem(text: b.title, id: $b.id)
do (id: string):
  message("clicked " & id)
```

[`view`](api.md#view) · [`ViewItem`](api.md#type-viewitem) · [`refreshView`](api.md#refreshview) · cookbook:
[a view](cookbook.md#9-a-view-in-the-plugins-dock)

### A language

A language ned does not have — its files, colours (ned's generic lexer with its words), comments, indentation,
pairs, F5 — or changes to one it has. `filetype` changes a language's indentation or comment. Your `languages`
setting wins over a plugin's.

```nim
language("zig", LangSpec(name: "Zig", extensions: @["zig"], lineComment: "//",
                         keywords: @["fn", "const", "var", "return"], indentSize: 4, run: "zig run $file"))
filetype("python", indentSize = 4)
```

[`language`](api.md#language) · [`LangSpec`](api.md#type-langspec) · [`filetype`](api.md#filetype) · cookbook:
[a language](cookbook.md#6-a-language-and-its-features)

### A language's features

What a language server gives, from a plugin: completions (merged with ned's own), hover (under ned's own), code
actions (on Alt+Enter), symbols (the outline, Go to symbol, the breadcrumbs) and snippets. `"*"` gives them to
every file — except symbols, which take the place of ned's own outline for the language.

```nim
completions("zig") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  for w in ["comptime", "defer"]:
    if w.startsWith(prefix): result.add CompletionItem(label: w, kind: "keyword")
snippet("zig", "fn", "fn ${1:name}() void {\n    $0\n}", "a function")
```

[`completions`](api.md#completions) · [`hover`](api.md#hover) · [`codeActions`](api.md#codeactions) ·
[`symbols`](api.md#symbols) · [`snippet`](api.md#snippet) · [`CompletionItem`](api.md#type-completionitem) ·
[`Symbol`](api.md#type-symbol) · cookbook: [a language and its features](cookbook.md#6-a-language-and-its-features)

### Formatters

A command that formats the text on its standard input (Alt+F and format on save), or a formatter written in
Nim: the text in, the formatted text out. Your `formatters` setting wins over a plugin's.

```nim
if findExe("shfmt").len > 0: formatter("shellscript", "shfmt -i 2")
else: formatter("shellscript") do (text: string) -> string: text.replace("\t", "  ")
```

[`formatter`](api.md#formatter) · [`formatter` in Nim](api.md#formatter-1) · cookbook:
[a formatter](cookbook.md#7-a-formatter)

### Language servers

A language server ned starts for a language's files, as it starts the ones it knows — or one written in
NimScript with `nedlsp`, which ned runs with `ned --lsp-bridge server.nims`. That command is the server for
other editors too (Helix, Neovim …). The library keeps the open documents' text, answers initialize, shutdown
and exit, and turns the editor's columns into bytes.

```nim
languageServer("zig", @["zls"])                           # plugin.nims
languageServerScript("markdown", "server.nims")           # plugin.nims, with this server.nims beside it:

import nedlsp
onRequest("textDocument/hover") do (params: JsonNode) -> JsonNode:
  %*{"contents": {"kind": "markdown", "value": "**" & wordAt(params) & "**"}}
serve(%*{"hoverProvider": true})
```

[`languageServer`](api.md#languageserver) · [`languageServerScript`](api.md#languageserverscript) ·
[`nedlsp`](api.md#nedlsp) · cookbook: [a language server in NimScript](cookbook.md#8-a-language-server-in-nimscript)

### Vim

With vim keys on (`editor.vimMode`): mappings in normal and visual mode (with the count typed before them, and
what they do for which-key), operators that take vim's motions and text objects, text objects that work after
any operator, and `:` commands. `<leader>` is the space bar.

```nim
nmap("<leader>w", "save") do (count: int): runCommand("Save")
operator("gU", "upper-case") do (b: Buf, r: Range, linewise: bool):
  b.replace(r, b.textIn(r).toUpperAscii)
exCommand("Lines") do (args: string): message($current().lineCount)
```

[`nmap`](api.md#nmap) · [`vmap`](api.md#vmap) · [`nmapIn`](api.md#nmapin) · [`operator`](api.md#operator) ·
[`textObject`](api.md#textobject) · [`exCommand`](api.md#excommand) · [`vimMode`](api.md#vimmode) · cookbook:
[vim](cookbook.md#15-vim-an-operator-text-objects-mappings)

### Keys that wait (which-key)

When keys wait for more — vim's `g`, a `<leader>`, emacs's `C-x`, helix's space — a plugin is told, can list
every key the plugins use with what it does, and can show a box of what may follow. ned's own `which-key` plugin
does this.

```nim
onKeysWaiting(400) do (keys, mode: string):
  if keys == "<leader>": discard showKeyHints("leader", [("w", "save"), ("f", "find a file")])
```

[`onKeysWaiting`](api.md#onkeyswaiting) · [`pendingKeys`](api.md#pendingkeys) · [`keyMaps`](api.md#keymaps) ·
[`showKeyHints`](api.md#showkeyhints) · cookbook: [keys that wait](cookbook.md#19-keys-that-wait-which-key)

### Timers and time

A callback every so many milliseconds, or once after a while; ned keeps the time. NimScript has no clock: ned's
is asked.

```nim
discard every(60_000) do ():
  status(localTime()[11 ..< 16])               # "14:03"
let id = after(25 * 60_000) do (): toast("Time for a break")
```

[`every`](api.md#every) · [`after`](api.md#after) · [`stopTimer`](api.md#stoptimer) ·
[`unixTime`](api.md#unixtime) · [`localTime`](api.md#localtime) · cookbook: [timers](cookbook.md#10-timers)

### Settings

A plugin declares its settings — ned's Settings panel shows them as `plugins.<name>.<key>`, with their
descriptions — and reads them where it uses them, so a change applies at once.

```nim
settingDef("width", 100, "Long lines: how many characters a line may have")
let width = setting("width", 100)
```

[`settingDef`](api.md#settingdef) · [`setting`](api.md#setting) · cookbook:
[settings and data](cookbook.md#11-settings-and-the-plugins-data)

### Data and files

Each plugin has a data folder of its own, written and read with no permission; `pluginDir` is its own folder,
`projectRoot` the project's. NimScript's `readFile`, `fileExists` and the like work too — with a path from
`projectRoot()`, since the plugin's process runs elsewhere.

```nim
appendData("saves.log", localTime() & " " & ev.path & "\n")
let state = (try: parseJson(readData("state.json")) except CatchableError: newJObject())
```

[`dataDir`](api.md#datadir) · [`readData`](api.md#readdata) · [`writeData`](api.md#writedata) ·
[`appendData`](api.md#appenddata) · [`pluginDir`](api.md#plugindir) · [`projectRoot`](api.md#projectroot) ·
cookbook: [settings and data](cookbook.md#11-settings-and-the-plugins-data)

### Running programs

A command run and waited for (its output and exit code), or run in the background with a callback when it
ends. Both need the "shell" permission.

```nim
permission("shell", "runs git")
let (o, code) = shell("git rev-parse --abbrev-ref HEAD")
shellAsync("git fetch --quiet") do (output: string, code: int): toast("fetched")
```

[`shell`](api.md#shell) · [`shellAsync`](api.md#shellasync) · [`permission`](api.md#permission) ·
[`allowed`](api.md#allowed) · cookbook: [permissions and programs](cookbook.md#12-permissions-and-running-programs)

### Regular expressions

ned's own regular expressions — its search's — for NimScript, which has none: every match with its groups, or a
replacement with `$1`.

```nim
let (t, n) = regexReplace(r"(\d+)-(\d+)", "pages 3-7", "$1 to $2")     # ("pages 3 to 7", 1)
```

[`regexMatches`](api.md#regexmatches) · [`regexReplace`](api.md#regexreplace) ·
[`RegexMatch`](api.md#type-regexmatch) · cookbook: [regular expressions](cookbook.md#20-regular-expressions)

### Tools for the assistant

A tool ned's assistant may call in its agent mode: its arguments as JSON Schema, the text it returns what the
model gets. One that only reads runs without asking; one that changes something asks you first.

```nim
aiToolReadOnly("line_count", "How many lines the file being edited has", %*{}) do (args: JsonNode) -> string:
  $current().lineCount
```

[`aiTool`](api.md#aitool) · [`aiToolReadOnly`](api.md#aitoolreadonly) · cookbook:
[tools for the assistant](cookbook.md#16-tools-for-the-assistant)

### The clipboard

What Ctrl+V would paste, and putting text there: with the "clipboard" permission.

```nim
permission("clipboard", "copies the file's path")
setClipboard(current().path)
```

[`clipboard`](api.md#clipboard) · [`setClipboard`](api.md#setclipboard)

## How plugins run

**One process for the NimScript plugins.** The NimScript plugins are imported into one host program that ned
starts with `nim e` (about a second, once) and talks to in lines of JSON: the plugins register what they have,
ned calls them back, and they ask ned for the text, to edit it, to show things. One process for all of them
keeps a phone's memory free; a plugin in `plugins.alone` runs in a process of its own, so a slow or crashing one
never holds up the others. A **plugin in full Nim** (`plugin.nim`) is always compiled into a program of its own:
the whole standard library (std/times, osproc, threads, sockets …); while it is built the dock says
*compiling…*, and its errors go to Problems.

**Compiled when you keep them.** With `plugins.native` (auto), a set of NimScript plugins is compiled (`nim c`,
in the background) as soon as it starts, for the next start — and for this one, once the process has stopped
while idle: a faster start, calls of 0.3 ms instead of 3–6, less memory. A plugin you are writing (changed in the
last 10 minutes) waits until it has started unchanged once; on: always; off: never. A plugin that uses what only
NimScript has (`exec`, `listFiles` …) does not compile, and stays with `nim e`. Write plugins that compile both
ways: the cookbook's do.

**Started when needed.** A process starts only when one of its plugins is needed — ned keeps what they
registered (`~/.cache/ned/plugins/manifest.json`), so their commands and keys are there at once — or right after
ned starts when a plugin answers events (opening, changing, before saving, starting, keys that wait), keeps
time, formats in Nim, gives text objects, completes, hovers, gives code actions or symbols, or shows a view. It
stops after `plugins.idleStopMinutes` (10) without a call, unless it must run or one of its plugins shows a
status-bar item; it starts again when needed.

**One call at a time.** ned calls a process back one call at a time: while a callback runs, the other plugins of
that process wait. Every API proc that asks ned something is a request that waits for its answer — a few
milliseconds under `nim e`, about 0.3 ms compiled — so ask for many lines at once (`b.lines`), give `output`
all its lines in one call, and set all of a file's problems with one `setProblems`. A plugin reading a file
line by line still asks ned only twice: ned sends the version of the buffers a call is about with the call, and
the plugin keeps a copy of their lines while that version stays (a file of 5000 lines read with `b.line(i)`:
2.6 s → 0.19 s under `nim e`, 95 → 2 ms compiled).

**What ned waits for.** Most callbacks ned does not wait for: their results show when they come. It waits for
the ones it must have before it goes on: an `onBeforeSave` event and a vim text object (`plugins.timeoutMs`,
1500 ms), a formatter in Nim (3 s, or `plugins.timeoutMs` when longer), code actions (1 s), and the `onQuit`
events (1.5 s each). While it waits, a plugin's `pick`, `ask` and `confirm` answer at once (-1, "", false). A
call that has not come back in a minute is given up, and the log says so.

**Undo and errors.** All the edits a plugin makes in one callback — a command, an event, a fix, a timer's call —
are one undo step. A request ned refuses (a closed tab, a read-only file, a permission not given) raises
`ValueError` in the plugin; an exception that leaves a callback is that call's error, in the plugin's log and
the status line, and the plugin goes on. A plugin that does not compile is left out — its error is in Problems
and in its file — and the others start without it.

## Permissions

Before a plugin runs, ned reads its source (every `.nims` and `.nim` file in its folder) for what it does beyond
editing: **run programs** (`shell`, `shellAsync`, `runInTerminal`, a command of ned's that runs programs,
NimScript's `exec` and `gorgeEx`, `osproc`), **change files** (`writeFile`, `mkDir`, `mvFile`, `rmFile`,
`removeFile` …), **use the clipboard**, and, for a plugin in full Nim, **use the network** (`std/net`,
`httpclient` …). A plugin says why it needs each one with `permission("shell", "sends your requests with curl")`
— one line, two plain strings. The first time it would run — installed, copied in, or one of ned's own turned
on — ned shows what it asks for, why, and where in its source, and runs it only after you *Allow*; until then
the Plugins dock says it is waiting (a toast too, once). What you allowed is kept on this device only
(`~/.local/state/ned/plugin-permissions.json`, never in synced settings); a plugin's menu in the dock and
*Plugins: permissions…* show it and take it back. A plugin that later asks for more waits again.

At run time a call the plugin was not allowed (`shell`, `shellAsync`, `runInTerminal`, the clipboard, a command
of ned's that runs programs, saving a file outside the project) raises an error that names the permission, and
the plugin's log says *refused*; `allowed("shell")` asks first. Its own data folder needs no permission:
`writeData(name, text)`, `appendData`, `readData`. Code ned cannot read ahead — `{.importc.}`, `{.emit.}`, `asm`,
macros that make code from text, a module from outside the plugin's folder — counts as asking for everything.

This keeps a plugin to what it said; on Linux the kernel also holds a plugin to it (a sandbox, `plugins.sandbox`: [Safety](../guide/safety.md)); elsewhere it is not a sandbox against code written to hide what it does. What a
plugin *registers* for ned to run when you ask — a formatter command, a language server, a language's run,
build and check commands — runs as ned runs your own settings' commands, when you format, open a file or press
F5: read what a plugin registers before you install it, as you read the rest of it. Plugins run with your
rights, like any program. The first 6.26 start gave the plugins you had on what they use, since they could do
all of it before.

## Where things are

| what | where |
|---|---|
| your plugins | `~/.config/ned/plugins/<name>/plugin.nims` (or `plugin.nim`) |
| a project's plugins | `.ned/plugins/<name>/` — they run once you trust the folder |
| ned's own plugins | in ned; turned on ones are listed in `plugins.bundled`, a copy of yours takes their place |
| a plugin's data | `~/.local/share/ned/plugins/<name>/` (under `$XDG_DATA_HOME` when it is set): `dataDir()` |
| what the plugins registered, the compiled hosts, the API's files | `~/.cache/ned/plugins/` (`manifest.json`, `native/`, `lib-…/nedplugin.nim`) |
| what you allowed them | `~/.local/state/ned/plugin-permissions.json` |
| the plugin process's own folder | `~/.config/ned/plugins/` — so build a project's paths from `projectRoot()` |

## Settings

`plugins.enabled`, `plugins.disabled` (names), `plugins.bundled` (ned's own you turned on), `plugins.alone`
(names), `plugins.native` (auto · on · off), `plugins.timeoutMs`, `plugins.idleStopMinutes`, `plugins.indexUrl`,
`plugins.checkForUpdates`, `plugins.pinned` — see [the settings](../reference/settings.md). Each plugin's own
settings are `plugins.<name>.<key>`, written flat or in one object for the plugin:

```json
{
  "plugins.notes.markers": "NOTE TODO FIXME HACK",
  "plugins": {"notes": {"problems": false}}
}
```

## Versions and updates

`pluginInfo(version = "1.2.0", author = "…", homepage = "https://…", license = "MIT")` in a plugin's source gives
its version (major.minor.patch), who wrote it, where it lives and its licence — any licence you like: ned is GPL, but
the plugin library a plugin imports comes with the [ned Plugin Exception](../../PLUGIN-EXCEPTION.md), which lets you
convey a plugin under terms of your choice. ned reads them from the source, not
by running it — plain strings, by name or in that order — so a plugin that is off shows them too. The Plugins dock
shows the version next to the plugin; its menu shows the rest, with *Its home page*. `requiresNed(">= 6.31")`
names the ned it needs: an older ned leaves it out and says why.

For a plugin that came from git (*Plugins: install from git…*):

- **Check for updates**: *Plugins: check for updates* (or the plugin's menu) asks each repository what it has now
  (`git fetch`), and says which have a newer version — *upd 1.2.0 → 1.3.0* — or newer commits with the same
  version. With `plugins.checkForUpdates` (on), ned asks once a day by itself, in the background. The dock marks a
  plugin with an update waiting: *↑ 1.3.0*.
- **Update** one from its menu (*Update to 1.3.0*), or all with *Plugins: update (git pull)* — fast-forward only: a
  plugin with changes of your own is left as it is, and says so.
- **Roll back**: its menu's *Roll back to 1.2.0* takes it back to the version it had before its last update.
- **Pin**: *Pin at 1.2.0* keeps it at the version it is at — updates leave it alone (📌 in the dock) — until
  *Unpin*. The pins are the setting `plugins.pinned` (`{"notes": "1.2.0"}`).

A plugin is shared as a git repository with its `plugin.nims` (or `plugin.nim`) at the top; it is named after the
repository, without a `ned-plugin-` or `ned-` in front. ned's own plugins come with ned and update with it; each
has its version and author as well.

## Debugging a plugin

- **The Plugins dock** (View › Plugins panel) lists the processes — *running · nim e* or *native*, *starting…*,
  *compiling…*, *failed:* and why; click one to restart or stop it — then the plugins' views, each plugin with
  what it registered (its menu: open its file, turn it off, its settings, reload it, run it in a process of its
  own, its permissions), and the **log**.
- **The log** has what `echo` and `log(text)` write, each callback's error (*error: …*), a call that was refused
  a permission (*refused …*), one ned stopped waiting for (*no answer in 1500 ms (plugins.timeoutMs)*), and when
  a process started, was compiled or stopped.
- **Compile errors** go to the Problems panel and to their line in the plugin's file; the plugin is left out and
  the others start without it. Fix it and save: saving a plugin reloads it.
- **One at a time**: *Plugins: turn one on or off…* (`plugins.disabled`), *Plugins: reload one…*, and *Run it
  in a process of its own* (`plugins.alone`) for one that hangs or crashes.
- **Check it without ned**: `nim check --hints:off --path:<the API's folder> plugin.nims`, with the folder
  `~/.cache/ned/plugins/lib-…/` (or `src/ned/plugins/lib` in ned's source). ned's own Nim check does this as you
  type in a plugin's file.
- **NimScript's limits**: no clock (`unixTime`, `localTime`), no regular expressions (`regexMatches`), an error of
  `readFile` or `writeFile` that cannot be caught (check with `fileExists` first, or use `shell`), no `return` in
  a command's body (call a proc), and some of the standard library missing. When you hit one, move the work into
  `shell`, or make the plugin a `plugin.nim`.

## Limits

| what | limit |
|---|---|
| ned waiting for `onBeforeSave` and a text object | `plugins.timeoutMs`: 1500 ms (200 at least) |
| … a formatter in Nim · code actions · each `onQuit` | 3 s (or `plugins.timeoutMs` when longer) · 1 s · 1.5 s |
| a call that does not come back | given up after a minute |
| `onChange` | after 0.4 s without typing |
| a timer (`every`, `after`) | 100 ms at least |
| a view's rows asked again | twice a second at most |
| a sign, a dot, a tab or line-end mark | one character; one sign shows on a line |
| `readData` / `writeData` names | relative to `dataDir()`, no `..`, 200 bytes at most; 64 MB in one write |
| a log line | 400 bytes (the dock keeps the last few hundred lines) |
| `regexMatches` | 100 000 matches |
| a view row's `depth` · a symbol's `depth` | 6 · 8 |
| a tool's name for the model (`plugin__<plugin>__<name>`) | 64 characters |
| a plugin's name | letters, digits, `-`, `_`, `.`; 64 at most |
| the source ned reads for permissions | 60 files, 4 MB |

## Testing a plugin

A plugin can be tested without the editor, by playing ned's side of the conversation:
[`tests/plugins/tplugins.py`](../../tests/plugins/tplugins.py) does it for the examples, and its `Host` class is
easy to copy — the tutorial's [Testing](tutorial.md#testing) shows how. ned's own plugins have their checks in
[`tests/plugins/bundled/`](../../tests/plugins/bundled). The cookbook's plugins are checked by
`python3 tests/plugins/cookbook/check.py`: each compiles both as NimScript and as Nim, and
[the cookbook page](cookbook.md) shows each file as it is (`--run` starts each in the plugin host too).

## The examples

`examples/plugins/`, or *Plugins: add an example…*: **zig-lite** — a language ned does not have (Zig: colours,
comments, indentation, F5), formatted by `zig fmt` or, without zig, by a formatter in NimScript, and zls when it
is installed; **wordinfo-lsp** — a language server in NimScript for text files (hover: how often a word occurs;
completion of the text's words; a TODO or a long line as a diagnostic); **commentary** — vim's `gc` operator
(`gcc`, `gcj`, `gcip`, in visual mode), an `ie` text object (the whole text: `yie`, `die`, `vie`) and
`:Comment`; **ini-tools** — a language's features for INI-style files (completions of the keys other sections
have, hover, the sections and keys as the outline, code actions: sort a section, remove a key given twice, a
snippet), a view of the file's sections in the Plugins dock, a command with progress and lines in the Output
panel, its own setting, and `ini_get`, a tool for the assistant; **clock-native** — a plugin in full Nim
(std/times): a clock in the status bar, two commands; **notes** — the one the [tutorial](tutorial.md) builds step
by step: the TODO, NOTE and FIXME notes of your files as problems with quick fixes, signs, a setting, a view in
the dock, completion and hover, vim keys and text objects, a reminder on a timer, and two tools for the
assistant. The [cookbook](cookbook.md) has twenty more, one for each area above.
