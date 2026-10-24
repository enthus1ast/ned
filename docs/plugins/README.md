# Plugins

New to writing plugins? The [tutorial](tutorial.md) builds one step by step; the [API reference](api.md) lists
every proc and type. This page says what plugins can do and how they run.

A plugin is a folder with a `plugin.nims` — NimScript, the Nim of `config.nims` — or a `plugin.nim`, a plugin in
full Nim. Yours are in `~/.config/ned/plugins/<name>/`; a project's in `.ned/plugins/<name>/` run once you trust
the folder. *Plugins: new plugin…* (and *new plugin in full Nim…*) makes one from a template, *Plugins: add an
example…* copies one of the six below, *Plugins: install from git…* clones a repository that has a `plugin.nims`
(or `plugin.nim`) at its top, *Plugins: browse the plugin list…* installs from a list (`plugins.indexUrl`: a URL or a
file of JSON, `[{"name", "url", "description"}]`), and *Plugins: update* pulls the ones that came from git. Saving a
plugin's file reloads it (*Plugins: reload one…* too). While you write one, `import nedplugin` (and `nedlsp`)
resolves wherever the plugin is: every proc, type and field of the API has its hover with its doc, completion
after `b.` lists what a buffer offers, and NimScript's own procs (`exec`, `readFile` …) are there too.

```nim
import nedplugin

requiresNed(">= 6.20")                               # an older ned leaves it out, and says why

command "Upper-case the line", "ctrl+alt+u":       # the palette (and the Plugins dock), on a key
  let b = current()
  let l = b.cursor.line
  b.replace(b.lineRange(l), b.line(l).toUpperAscii)  # a command's edits are one undo step

onSave("*.md") do (ev: Event):
  status("saved " & $ev.buf.lineCount & " lines")    # an item in the status bar

hover("zig") do (b: Buf, p: Pos) -> string:          # under ned's own hover
  "**" & b.wordAt(p) & "**"
```

**How it runs.** The NimScript plugins are imported into one host program that ned starts with `nim e` (about a
second, once) and talks to in JSON lines: the plugins register what they have, ned calls them back, and they ask
ned for the text, to edit it, to show things. One process for all of them keeps a phone's memory free; a plugin in
`plugins.alone` runs in a process of its own (a slow or crashing one never holds up the others). A process starts
only when one of its plugins is needed — ned keeps what they registered (`~/.cache/ned/plugins/manifest.json`), so
their commands and keys are there at once — or right after ned starts when a plugin answers events, keeps time,
formats, completes, hovers, lists symbols or shows a view; it stops after `plugins.idleStopMinutes` without a call.
`plugins.native` (auto): a set of plugins started before as it is now is compiled (`nim c`, in the background) for
the next start — a faster start, calls 0.3 ms instead of 3–6, less memory; on: always; off: never. A **plugin in
full Nim** (`plugin.nim`) is always compiled into a program of its own: the whole standard library (std/times,
osproc, threads, sockets …); while it is built the dock says *compiling…*, and its errors go to Problems. A plugin
that does not compile is left out — its error is in Problems and its file — and the others start without it; an
exception in a callback is that call's error, in the plugin's log. The **Plugins dock** (View › Plugins panel) lists
the processes (click: restart, stop), the plugins' views, each plugin with what it registered (on/off, reload, its
own process), and their log (`echo` goes there). ned waits `plugins.timeoutMs` (1500) for what it must have before
it goes on: an event before saving, a NimScript formatter, a text object, code actions (1 s).

**The API** (`nedplugin.nim` — *Plugins: the API* opens it; lines and columns from 0, columns in bytes, a `Range`
from `start` up to `stop`):

| | |
|---|---|
| commands, keys | `command "title": …`, `command "title", "ctrl+alt+x": …` (your `keys` setting wins over a plugin's), `runCommand(name)` (one of ned's) |
| events | `onStartup`, `onOpen(pattern)`, `onBeforeSave(pattern)` (what it changes is saved), `onSave`, `onClose`, `onChange` (after a pause in the typing); `pattern`: `"*"`, `"*.zig"`, `"src/*.nim"`, `"lang:zig"`; `autocmd("BufWritePre", "*.nim")` with vim's names |
| the text | `current()`, `openFile(path, line)`, `buffers()`; `b.path`, `b.lang`, `b.lineCount`, `b.line(i)`, `b.lines(a, e)`, `b.text`, `b.textIn(r)`, `b.setText(s)` (only the lines that differ change), `b.replace(r, s)`, `b.insert(p, s)`, `b.delete(r)`, `b.cursor`, `b.setCursor(p)`, `b.selection`, `b.selections`, `b.select(r)`, `b.wordAt(p)`, `b.dirty`, `b.save()`, `b.indentUnit`, `b.lineComment` |
| you | `message(s)`, `warn(s)`, `toast(s)`, `pick(title, items)` (the index, -1), `ask(prompt, default)`, `confirm(question)` |
| problems | `b.setProblems([Problem(range, severity, message, fixes)])` — Problems, the underline, and Alt+Enter applies a `Fix(title, edits)` |
| in the editor | `b.sign(line, "★", "warn")` (the gutter), `b.virtualText(line, text)` (after the line), `b.highlight(r, "accent")`, `b.clearDecorations`, `status(text)`, `progress("Indexing", 40)` / `progressDone()` (the status bar), `output(text)` / `showOutput()` (the Output panel; `file:line:col` in it can be clicked), `runInTerminal(cmd, dir)` (ned's terminal) |
| a language's features | `completions("zig") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]: …` (`label`, `insert`, `detail`, `doc`, `kind`, `snippet`; merged with ned's and a language server's), `hover("zig") do (b, p) -> string` (Markdown, under ned's own), `codeActions("zig") do (b: Buf, r: Range) -> seq[Fix]` (Alt+Enter), `symbols("zig") do (b: Buf) -> seq[Symbol]` (`name`, `kind`, `detail`, `line`, `col`, `depth`: the Outline, Go to symbol, the breadcrumbs), `snippet("zig", "fn", "fn ${1:name}() {\n\t$0\n}", "a function")`; `"*"` for every language |
| languages | `language("zig", LangSpec(extensions, lineComment, blockComment, keywords, types, constants, builtins, functionWords, indentAfter, dedent, indentSize, tabs, run, pairs))`; `filetype("python", indentSize = 4)`; your `languages` setting wins over a plugin's |
| formatters | `formatter("zig", "zig fmt --stdin")` or one in NimScript: `formatter("zig") do (text: string) -> string: …` (Alt+F and format on save; your `formatters` setting wins) |
| language servers | `languageServer("zig", @["zls"])`, or one written in NimScript: `languageServerScript("lang", "server.nims")` |
| the assistant | `aiTool("name", "what it does", %*{"path": {"type": "string"}}) do (args: JsonNode) -> string: …` — a tool ned's AI agent may call (it asks you first, as for a command); `aiToolReadOnly(…)` for one that only reads (no question) |
| views | `view("Title") do () -> seq[ViewItem]: …` — a section of the Plugins dock (`text`, `detail`, `icon`, `color`, `id`, `path`, `line`, `depth`), with `do (id: string): …` for a click; `refreshView("Title")` |
| vim | `nmap("<leader>f") do (count: int): …`, `vmap`, `operator("gc") do (b: Buf, r: Range, linewise: bool): …` (with motions, text objects, `gcc`, visual), `textObject("ie") do (b: Buf, p: Pos) -> Range: …` (after `d c y`, a plugin's operator, in visual mode), `exCommand("Name") do (args: string): …`; the leader is the space bar |
| time | `every(ms) do (): …`, `after(ms) do (): …`, `stopTimer(id)` |
| settings, files | `settingDef("width", 80, "…")` (in ned's Settings panel as `plugins.<name>.width`), `setting("width", 80)`; `dataDir()` (`~/.local/share/ned/plugins/<name>`), `pluginDir()`, `shell(cmd)` (output, exit code), `log(s)`; `requiresNed(">= 6.20")` |

**A language server in NimScript.** `import nedlsp`, answer requests with `onRequest("textDocument/hover") do
(params: JsonNode) -> JsonNode: …`, take notifications with `onNotification`, and end with
`serve(capabilities)`; the library keeps the open documents' text (`docText(uri)`, full and incremental changes),
answers initialize/shutdown/exit, and converts the client's columns (`byteCol`, `wordAt(params)`). `ned
--lsp-bridge server.nims` runs it with the protocol's framing — that command is the server for ned and for any
other editor.

**The examples** (`examples/plugins/`, or *Plugins: add an example…*): **zig-lite** — a language ned does not have
(Zig: colours, comments, indentation, F5), formatted by `zig fmt` or, without zig, by a formatter in NimScript, and
zls when it is installed; **wordinfo-lsp** — a language server in NimScript for text files (hover: how often a word
occurs; completion of the text's words; a TODO or a long line as a diagnostic); **commentary** — vim's `gc`
operator (`gcc`, `gcj`, `gcip`, in visual mode), an `ie` text object (the whole text: `yie`, `die`, `vie`) and
`:Comment`; **ini-tools** — a language's features for INI-style files (completions of the keys other sections
have, hover, the sections and keys as the outline, code actions: sort a section, remove a key given twice, a
snippet), a view of the file's sections in the Plugins dock, a command with progress and lines in the Output panel,
its own setting, and `ini_get`, a tool for the assistant; **clock-native** — a plugin in full Nim (std/times): a
clock in the status bar, two commands; **notes** — the one the [tutorial](tutorial.md) builds step by step: the
TODO, NOTE and FIXME notes of your files as problems with quick fixes, signs, a setting, a view in the dock,
completion and hover, vim keys and text objects, a reminder on a timer, and two tools for the assistant.

**Settings:** `plugins.enabled`, `plugins.disabled` (names), `plugins.alone` (names), `plugins.native` (auto · on ·
off), `plugins.timeoutMs`, `plugins.idleStopMinutes`, `plugins.indexUrl`, and each plugin's own
`plugins.<name>.<key>`. Plugins run with your rights, like any program: read one before you install it.
