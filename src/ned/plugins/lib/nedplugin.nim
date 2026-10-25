## nedplugin — what a ned plugin imports.
##
## A plugin is a folder with a `plugin.nims` (NimScript: ned runs the NimScript plugins together in one `nim e`
## process — compiled when `plugins.native` says so: auto compiles a set of plugins you keep) or a `plugin.nim`
## (full Nim: ned compiles it into a program of its own — the whole standard library, threads, sockets). Its
## top-level code runs once when it starts: it registers commands, keys, events, languages, formatters, language
## servers, completions, hover, code actions, symbols, snippets, tools for the assistant, views in the Plugins dock,
## vim mappings … with the procs below. ned calls them back.
##
## ```nim
## import nedplugin
##
## command "Upper-case the line", "ctrl+alt+u":
##   let b = current()
##   let p = b.cursor
##   b.replace(lineRange(b, p.line), b.line(p.line).toUpperAscii)
##
## onSave("*.md") do (ev: Event):
##   message("saved " & ev.path)
## ```
##
## Lines and columns count from 0; a column is a byte offset in the line (UTF-8). A `Range` goes from `start` up to
## `stop` (`stop` itself not included). ned and the plugins talk in JSON lines over the host's stdin and stdout —
## `echo` in a plugin goes to its log (the Plugins dock).

import std/[json, tables, strutils, os]
export json, strutils, os
when not defined(nimscript):
  import std/osproc

type
  Pos* = object
    ## a place in a file
    line*, col*: int             ## its line (from 0) and column (from 0, a byte offset in the line)
  Range* = object
    start*, stop*: Pos           ## from start up to stop (stop not included)
  Buf* = object                  ## an open file (or an unsaved one) in ned
    id*: int                     ## ned's number for it (-1: none)
  Event* = object
    ## what an event (onOpen, onSave …) is about
    buf*: Buf                    ## the file
    path*, lang*: string         ## the file and its language id ("nim", "zig" …)
  Edit* = object
    ## one change: the range's text replaced with text
    range*: Range                ## what it replaces (empty: an insertion at its start)
    text*: string                ## what goes there
  Fix* = object
    ## a fix Alt+Enter offers: its title in the list, its edits when chosen
    title*: string               ## what the list shows ("Use `foo`")
    edits*: seq[Edit]            ## the changes it makes (one undo step)
  Problem* = object
    ## a problem in a file: underlined, in the Problems panel and the gutter
    range*: Range                ## the text it is about
    severity*: int               ## 1 error, 2 warning, 3 information, 4 hint
    message*: string             ## what is wrong
    fixes*: seq[Fix]             ## Alt+Enter offers them
  LangSpec* = object
    ## a language ned colours with its generic lexer (or changes to one it has): the "languages" setting's fields
    name*: string                ## its name in the status bar and the language list ("Zig")
    extensions*, files*: seq[string]  ## its files: by extension (@["zig", "zon"]) or whole name (@["build.zig"])
    lineComment*: string         ## its line comment ("//")
    blockComment*: seq[string]   ## @["/*", "*/"]
    quotes*: string              ## "\"'"
    keywords*, types*, constants*, builtins*: seq[string]  ## words coloured as keywords, types, constants, builtins
    functionWords*, classWords*: seq[string]  ## the words before a function's or a class's name (outline)
    indentAfter*: seq[string]    ## "{" ":" … or words: the next line is indented
    dedent*: string              ## typing one of these takes a level off ("}")
    indentSize*: int             ## spaces to an indentation level (0: the editor's setting)
    tabs*: bool                  ## indent with tabs
    run*: string                 ## the command F5 runs ($file …)
    build*, check*: string       ## the commands of Build (Alt+B) and of the check on save ($file $dir $name $tmp)
    pairs*: string               ## "()[]{}\"\"" — what typing an opening one closes
    dedentWords*: seq[string]    ## a line that becomes one of these words alone goes one level out (@["end"])
    nestedComments*: bool        ## a block comment may hold another (`/* /* */ */` — Odin, Haskell's {- -})
    tripleQuotes*: bool          ## """…""" strings, over several lines
    multilineStrings*: bool      ## a "…" or `…` string not closed on its line goes on below (Gleam, Odin's raw)
    charLiterals*: bool          ## 'a' is a character (not a quote of a string)
    capitalTypes*: bool          ## a Capitalised word is a type (an ALL-CAPS one a constant)
    decorators*: bool            ## @name is coloured as an attribute
    docComment*: string          ## a doc comment's line start ("///", "--|")
    docBlockComment*: seq[string]  ## a doc block comment: @["/**", "*/"]
    nameChars*: string           ## characters a name may have after its first letter ("?!" for Elixir, "'" Haskell)

const ProtoMark = "\x1e"         ## (the start of a line ned reads as a message; any other line is the plugin's log)

var
  callbacks: seq[proc(args: JsonNode): JsonNode]
  cbOwner: seq[string]           # the plugin each callback belongs to
  nextApi = 0
  results: Table[int, JsonNode]  # API answers that came while waiting for another
  queued: seq[JsonNode]          # ned's calls that came while waiting for an answer
  curPlugin* = ""                ## the plugin whose code runs now
  curRid = 0                     # the call of ned's it runs for (edits in it are one undo step)
  dirs: seq[(string, string)]    # plugin id, its folder

proc send(j: JsonNode) =
  when defined(nimscript):
    echo ProtoMark & $j
  else:
    stdout.write ProtoMark & $j & "\n"
    stdout.flushFile()

proc readMsg(): JsonNode =
  ## the next line from ned (nil at the end)
  while true:
    var line = ""
    try:
      when defined(nimscript): line = readLineFromStdin()
      else:
        if not stdin.readLine(line): return nil
    except EOFError: return nil
    if line.len == 0: continue
    try: return parseJson(line)
    except CatchableError: discard

proc pluginOf*(file: string): string =
  ## the plugin a source file belongs to (its folder is the plugin's, or one inside it)
  if dirs.len == 0:
    for l in getEnv("NED_PLUGIN_DIRS").split('\n'):
      let k = l.find('=')
      if k > 0: dirs.add (l[0 ..< k], l[k + 1 .. ^1])
  var best = ""
  var bestLen = -1
  for (id, d) in dirs:
    if (file == d or file.startsWith(d & "/")) and d.len > bestLen:
      best = id
      bestLen = d.len
  if best.len > 0: return best
  # (a plugin run on its own: its folder's name)
  let parts = file.split('/')
  if parts.len >= 2: parts[^2] else: file

proc handle(j: JsonNode)

proc api*(fn: string, args: JsonNode = newJObject()): JsonNode =
  ## ask ned something (or have it do something) and wait for the answer; what the API procs below use
  inc nextApi
  let id = nextApi
  send(%*{"t": "api", "id": id, "fn": fn, "args": args, "plugin": curPlugin, "rid": curRid})
  while true:
    if id in results:
      result = results[id]
      results.del id
      break
    let m = readMsg()
    if m == nil: quit(0)
    case m{"t"}.getStr
    of "res":
      let rid = m{"id"}.getInt
      if m.hasKey("err"): raise newException(ValueError, m["err"].getStr)
      if rid == id: return m{"value"}
      results[rid] = m{"value"}
    of "quit": quit(0)
    else: queued.add m              # (ned's calls wait until this one is answered)

proc register(file, kind: string, data: JsonNode, cb: proc(args: JsonNode): JsonNode = nil): int =
  let pid = pluginOf(file)
  var d = data
  if d == nil: d = newJObject()
  d["t"] = %"reg"
  d["kind"] = %kind
  d["plugin"] = %pid
  if cb != nil:
    callbacks.add cb
    cbOwner.add pid
    result = callbacks.high
    d["cb"] = %result
  else: result = -1
  send(d)

proc handle(j: JsonNode) =
  case j{"t"}.getStr
  of "call":
    let cb = j{"cb"}.getInt(-1)
    let rid = j{"rid"}.getInt
    if cb < 0 or cb >= callbacks.len:
      send(%*{"t": "ret", "rid": rid, "err": "no such callback"})
      return
    let (p0, r0) = (curPlugin, curRid)
    curPlugin = cbOwner[cb]
    curRid = rid
    try:
      let v = callbacks[cb](j{"args"})
      send(%*{"t": "ret", "rid": rid, "value": (if v == nil: newJNull() else: v)})
    except CatchableError as e:
      send(%*{"t": "ret", "rid": rid, "err": e.msg})
    curPlugin = p0
    curRid = r0
  of "quit": quit(0)
  else: discard

proc nedRun*() =
  ## the host's loop: ned's calls, one at a time (ned writes this call into the host it makes)
  send(%*{"t": "ready"})
  while true:
    while queued.len > 0:
      let q = queued[0]
      queued.delete(0)
      handle(q)
    let m = readMsg()
    if m == nil: break
    handle(m)

# ── JSON ⇄ the types ──

proc `%`*(p: Pos): JsonNode = %*{"line": p.line, "col": p.col}
  ## the position as ned's JSON
proc `%`*(r: Range): JsonNode = %*{"start": %r.start, "stop": %r.stop}
  ## the range as ned's JSON
proc toPos(j: JsonNode): Pos = Pos(line: j{"line"}.getInt, col: j{"col"}.getInt)
proc toRange(j: JsonNode): Range =
  if j == nil or j.kind != JObject: return Range(start: Pos(line: -1), stop: Pos(line: -1))
  Range(start: toPos(j{"start"}), stop: toPos(j{"stop"}))
proc `%`*(e: Edit): JsonNode = %*{"range": %e.range, "text": e.text}
  ## the edit as ned's JSON
proc `%`*(f: Fix): JsonNode =
  ## the fix as ned's JSON
  result = %*{"title": f.title, "edits": newJArray()}
  for e in f.edits: result["edits"].add %e
proc `%`*(p: Problem): JsonNode =
  ## the problem as ned's JSON
  result = %*{"range": %p.range, "severity": (if p.severity == 0: 2 else: p.severity), "message": p.message,
              "fixes": newJArray()}
  for f in p.fixes: result["fixes"].add %f
proc toEvent(j: JsonNode): Event =
  Event(buf: Buf(id: j{"buf"}.getInt(-1)), path: j{"path"}.getStr, lang: j{"lang"}.getStr)

func pos*(line, col: int): Pos = Pos(line: line, col: col)
  ## a position: line and column (both from 0; the column a byte offset in the line)
func rng*(a, b: Pos): Range = Range(start: a, stop: b)
  ## the range from a up to b (b itself not included)
func isEmpty*(r: Range): bool = r.start.line < 0 or (r.start.line == r.stop.line and r.start.col >= r.stop.col)
  ## no text in it: start == stop (or noRange())
func noRange*(): Range = Range(start: Pos(line: -1), stop: Pos(line: -1))
  ## what a text object returns when there is none at the cursor

# ── buffers: the text ──

proc current*(): Buf = Buf(id: api("current").getInt(-1))
  ## the file being edited
proc openFile*(path: string, line = -1, col = -1): Buf =
  ## open a file (or go to it), at a line when given
  Buf(id: api("open", %*{"path": path, "line": line, "col": col}).getInt(-1))
proc newTab*(title, text: string, lang = ""): Buf =
  ## a new tab with `text` (not a file until it is saved): a response, generated code. `lang`: its language's id or
  ## name ("json", "Nim"), for its colours. A tab of that title already open: it, its text replaced — unless it
  ## has edits not saved (then it as it is)
  Buf(id: api("newTab", %*{"title": title, "text": text, "lang": lang}).getInt(-1))
proc clipboard*(): string = api("clipboard").getStr
  ## the system clipboard's text (what Ctrl+V would paste)
proc setClipboard*(text: string) = discard api("setClipboard", %*{"text": text})
  ## put `text` on the system clipboard
proc buffers*(): seq[Buf] =
  ## every open file (and the unsaved ones), in the order of their tabs
  for x in api("buffers"): result.add Buf(id: x.getInt)
proc valid*(b: Buf): bool = b.id >= 0
  ## a file ned has (current() and openFile() give -1 when there is none)
proc path*(b: Buf): string = api("path", %*{"buf": b.id}).getStr
  ## the file's path ("" for an unsaved one)
proc lang*(b: Buf): string = api("lang", %*{"buf": b.id}).getStr
  ## its language id ("nim", "python", "zig" …)
proc lineCount*(b: Buf): int = api("lineCount", %*{"buf": b.id}).getInt
  ## how many lines it has (an empty file: 1)
proc line*(b: Buf, i: int): string = api("line", %*{"buf": b.id, "line": i}).getStr
  ## line i, without its line end ("" past the end)
proc lines*(b: Buf, first = 0, last = -1): seq[string] =
  ## lines first .. last (-1: to the end)
  for x in api("lines", %*{"buf": b.id, "first": first, "last": last}): result.add x.getStr
proc text*(b: Buf): string = api("text", %*{"buf": b.id}).getStr
  ## the whole text (lines joined with \n)
proc textIn*(b: Buf, r: Range): string = api("textIn", %*{"buf": b.id, "range": %r}).getStr
  ## the text in the range (lines joined with \n)
proc setText*(b: Buf, s: string) = discard api("setText", %*{"buf": b.id, "text": s})
  ## the whole text (ned changes only the lines that differ: the cursor and the undo stay sensible)
proc replace*(b: Buf, r: Range, s: string) = discard api("replace", %*{"buf": b.id, "range": %r, "text": s})
  ## the range's text replaced with s (one undo step with the plugin's other edits of this call)
proc insert*(b: Buf, p: Pos, s: string) = b.replace(rng(p, p), s)
  ## s inserted at p
proc delete*(b: Buf, r: Range) = b.replace(r, "")
  ## the range's text removed
proc cursor*(b: Buf): Pos = toPos(api("cursor", %*{"buf": b.id}))
  ## where the (main) cursor is
proc setCursor*(b: Buf, p: Pos) = discard api("setCursor", %*{"buf": b.id, "pos": %p})
  ## the cursor moved to p (the selection goes)
proc selection*(b: Buf): Range = toRange(api("selection", %*{"buf": b.id}))
  ## the main selection (empty: start == stop, the cursor) — in vim's visual mode with the character under the
  ## cursor, in visual-line mode the whole lines
proc vimMode*(): string = api("vimMode").getStr
  ## vim's mode: normal, insert, visual, visual line, replace ("" not vim keys)
proc selections*(b: Buf): seq[Range] =
  ## every cursor's selection (several with multiple cursors)
  for x in api("selections", %*{"buf": b.id}): result.add toRange(x)
proc select*(b: Buf, r: Range) = discard api("select", %*{"buf": b.id, "range": %r})
  ## the range selected (the cursor at its stop)
proc wordAt*(b: Buf, p: Pos): string = api("wordAt", %*{"buf": b.id, "pos": %p}).getStr
  ## the word at p (letters, digits, _), "" when there is none
proc dirty*(b: Buf): bool = api("dirty", %*{"buf": b.id}).getBool
  ## changed since it was last saved
proc save*(b: Buf) = discard api("save", %*{"buf": b.id})
  ## written to its file (as Ctrl+S does — but plugins get no save events for it)
proc closeTab*(b: Buf) = discard api("closeTab", %*{"buf": b.id})
  ## the tab closed (a file with edits not saved: you are asked first)
proc markSaved*(b: Buf) = discard api("markSaved", %*{"buf": b.id})
  ## counts as saved (no ● on its tab, no question when it closes) — a tab of yours, after onSaveTab did its work
proc title*(b: Buf): string = api("title", %*{"buf": b.id}).getStr
  ## the name on its tab (a file's: its name)
proc setTitle*(b: Buf, title: string) = discard api("setTitle", %*{"buf": b.id, "title": title})
  ## the name on a tab that is not a file (newTab's)
proc indentUnit*(b: Buf): string = api("indent", %*{"buf": b.id}).getStr
  ## two spaces, four, a tab … what this file indents with
proc lineComment*(b: Buf): string = api("lineComment", %*{"buf": b.id}).getStr
  ## the language's line comment ("#", "//"; "" none)
proc lineRange*(b: Buf, line: int): Range = rng(pos(line, 0), pos(line, b.line(line).len))
  ## line `line` without its line end, as a Range
proc wholeLines*(b: Buf, first, last: int): Range =
  ## lines first .. last with their line ends
  if last + 1 < b.lineCount: rng(pos(first, 0), pos(last + 1, 0))
  else: rng(pos(first, 0), pos(last, b.line(last).len))

# ── keys: what waits, what the next key does (which-key) ──

type
  KeyMap* = object
    ## a key a plugin (or your "keys" setting) uses
    mode*: string                ## n v (vim mappings), op (an operator), obj (a text object), key (any keymap)
    keys*: string                ## as given: "<leader>f", "gc", "ie", "ctrl+alt+u"
    desc*: string                ## what it does ("" not said)
    lang*: string                ## only in files of this language ("" every file)
    plugin*: string              ## whose ("" yours)

proc pendingKeys*(): tuple[keys, mode: string] =
  ## the keys typed that wait for more ("" when none waits) and the mode (as onKeysWaiting gives them)
  let j = api("pendingKeys")
  (j{"keys"}.getStr, j{"mode"}.getStr)
proc showKeyHints*(title: string, hints: openArray[(string, string)]): bool =
  ## a box above the status bar, each key and what it does, until the keys waiting change (ned closes it then;
  ## a tap on one types it). false: no keys wait now
  var arr = newJArray()
  for (k, d) in hints: arr.add %*[k, d]
  api("showKeyHints", %*{"title": title, "hints": arr}).getBool
proc hideKeyHints*() = discard api("hideKeyHints")
  ## the box of showKeyHints closed
proc keyMaps*(): seq[KeyMap] =
  ## the plugins' mappings, operators, text objects and keys, and the commands on keys (theirs and yours)
  for x in api("keyMaps"):
    result.add KeyMap(mode: x{"mode"}.getStr, keys: x{"keys"}.getStr, desc: x{"desc"}.getStr,
                      lang: x{"lang"}.getStr, plugin: x{"plugin"}.getStr)

# ── talking to you ──

proc message*(s: string) = discard api("message", %*{"text": s})
  ## the status line
proc warn*(s: string) = discard api("message", %*{"text": s, "level": "warn"})
  ## the status line, as a warning (its colour)
proc toast*(s: string) = discard api("toast", %*{"text": s})
  ## a note in the corner that goes away by itself
proc pick*(title: string, items: openArray[string], details: openArray[string] = []): int =
  ## a list to choose from: the index chosen, -1 when cancelled
  api("pick", %*{"title": title, "items": @items, "details": @details}).getInt(-1)
proc ask*(prompt: string, default = ""): string =
  ## a line of text ("" when cancelled)
  api("ask", %*{"prompt": prompt, "default": default}).getStr
proc confirm*(question: string): bool = api("confirm", %*{"text": question}).getBool
  ## a yes / no question: true for yes
proc runCommand*(name: string) = discard api("runCommand", %*{"name": name})
  ## a command of ned's palette, by its name ("Format document", "Save" …)

proc shell*(cmd: string, dir = ""): tuple[output: string, code: int] =
  ## a shell command's output and exit code (in `dir`, else the project's folder) — with permission "shell"
  if not api("allowed", %*{"what": "shell"}).getBool:
    raise newException(ValueError, "this plugin may not run programs: permission(\"shell\", \"why\") in its " &
                       "source, then allow it (Plugins dock › its menu)")
  let d = if dir.len > 0: dir else: api("root").getStr
  let full = "cd " & quoteShell(d) & " && " & cmd
  when defined(nimscript):
    let (o, c) = gorgeEx(full)
    (o, c)
  else:
    let (o, c) = execCmdEx(full)
    (o.strip(leading = false, chars = {'\n'}), c)

proc shellAsync*(cmd: string, cb: proc(output: string, code: int), dir = "") =
  ## a shell command ned runs in the background (in `dir`, else the project's folder): cb with its output and exit
  ## code when it ends. The plugin goes on meanwhile (`shell` waits): a slow request, a build
  let f = cb
  callbacks.add proc(a: JsonNode): JsonNode =
    f(a{"output"}.getStr, a{"code"}.getInt)
    newJNull()
  cbOwner.add curPlugin
  discard api("shellAsync", %*{"cmd": cmd, "dir": dir, "cb": callbacks.high})

proc unixTime*(): float = api("unixTime").getFloat
  ## now, in seconds since 1970 (NimScript has no clock of its own)
proc localTime*(): string = api("localTime").getStr
  ## now, on your clock: "2026-10-24 14:03:05"

# ── problems, signs, text after a line, highlights, the status bar ──

proc setProblems*(b: Buf, problems: openArray[Problem]) =
  ## this plugin's problems in the file (the ones it set before go); Alt+Enter offers their fixes
  var a = newJArray()
  for p in problems: a.add %p
  discard api("problems", %*{"buf": b.id, "problems": a})
proc clearProblems*(b: Buf) = b.setProblems([])
  ## the problems this plugin set in the file removed
proc sign*(b: Buf, line: int, text: string, color = "accent") =
  ## a mark in the gutter (one character); colors: error warn info hint accent add del, or "#rrggbb"
  discard api("sign", %*{"buf": b.id, "line": line, "text": text, "color": color})
proc virtualText*(b: Buf, line: int, text: string, color = "hint") =
  ## text after the line's end (not in the file)
  discard api("vtext", %*{"buf": b.id, "line": line, "text": text, "color": color})
proc highlight*(b: Buf, r: Range, color = "accent") =
  ## a tinted background over the range
  discard api("highlight", %*{"buf": b.id, "range": %r, "color": color})
proc clearDecorations*(b: Buf) = discard api("clearDecorations", %*{"buf": b.id})
  ## this plugin's signs, texts and highlights in the file
proc status*(text: string) = discard api("status", %*{"text": text})
  ## this plugin's item in the status bar ("" removes it)

# ── settings, its folder ──

proc settingIn*(plugin, key: string): JsonNode =
  ## (what `setting` uses) plugins.<plugin>.<key> as your settings have it, nil when they do not
  let keep = curPlugin
  if plugin.len > 0: curPlugin = plugin
  try: result = api("setting", %*{"key": key})
  finally: curPlugin = keep
proc settingPlugin*(file: string): string = (if curPlugin.len > 0: curPlugin else: pluginOf(file))
  ## (what `setting` uses) the plugin whose code runs now — in its top-level code too, by its file
func settingOr*(v: JsonNode, default: string): string = (if v == nil or v.kind != JString: default else: v.getStr)
  ## (what `setting` uses)
func settingOr*(v: JsonNode, default: int): int = (if v == nil or v.kind != JInt: default else: v.getInt)
  ## (what `setting` uses)
func settingOr*(v: JsonNode, default: bool): bool = (if v == nil or v.kind != JBool: default else: v.getBool)
  ## (what `setting` uses)
func settingOr*(v: JsonNode, default: float): float =
  ## (what `setting` uses)
  if v == nil or v.kind notin {JFloat, JInt}: default else: v.getFloat
template setting*(key: string, default: string): string =
  ## plugins.<this plugin>.<key> from your settings (in the plugin's top-level code too)
  settingOr(settingIn(settingPlugin(instantiationInfo(-1, true).filename), key), default)
template setting*(key: string, default: int): int =
  ## plugins.<this plugin>.<key> from your settings, a whole number (`default` when it is not one)
  settingOr(settingIn(settingPlugin(instantiationInfo(-1, true).filename), key), default)
template setting*(key: string, default: bool): bool =
  ## plugins.<this plugin>.<key> from your settings, true or false (`default` when it is not set)
  settingOr(settingIn(settingPlugin(instantiationInfo(-1, true).filename), key), default)
template setting*(key: string, default: float): float =
  ## plugins.<this plugin>.<key> from your settings, a number (`default` when it is not one)
  settingOr(settingIn(settingPlugin(instantiationInfo(-1, true).filename), key), default)
proc projectRoot*(): string = api("root").getStr
  ## the project's folder — what the file tree shows (the plugin's process runs elsewhere: a relative path in
  ## readFile means nothing, `projectRoot() & "/src/x.nim"` does)
proc projectDir*(): string = api("root").getStr
  ## the same as projectRoot — in a plugin.nims write `nedplugin.projectDir()` (NimScript has a projectDir of its
  ## own: the script's folder), or projectRoot
proc dataDir*(): string = api("dataDir").getStr
  ## a folder of this plugin's own (made when asked for)
proc readData*(name: string): string = api("dataRead", %*{"name": name}).getStr
  ## a file of this plugin's own data folder ("" when there is none): `name` is relative to dataDir() —
  ## "lists.json", "2026-10/day.log"
proc writeData*(name, text: string) = discard api("dataWrite", %*{"name": name, "text": text})
  ## a file of this plugin's own data folder written (its folders made): needs no permission, unlike writeFile
proc appendData*(name, text: string) = discard api("dataWrite", %*{"name": name, "text": text, "append": true})
  ## text added at the end of a file of this plugin's own data folder (made when there is none)
proc permission*(what, why: string) = discard
  ## what this plugin needs beyond editing, and why — "shell" (run programs: shell, shellAsync, runInTerminal,
  ## NimScript's exec and gorgeEx), "network" (a compiled plugin's sockets), "files" (writeFile, mkDir, mvFile,
  ## rmFile … — its own data needs none: writeData) or "clipboard". ned reads these lines, and what the source
  ## uses, before the plugin runs, and asks you once: `permission("shell", "sends your requests with curl")`.
  ## A call that was not allowed fails with an error. (Nothing happens when this runs: ned reads it from the source)
proc allowed*(what: string): bool = api("allowed", %*{"what": what}).getBool
  ## did you allow this plugin "shell", "network", "files" or "clipboard"?
proc pluginDir*(): string = api("pluginDir").getStr
  ## the plugin's own folder (where its plugin.nims or plugin.nim is)
proc log*(s: string) = discard api("log", %*{"text": s})
  ## a line in the plugin's log (the Plugins dock)

# ── registering: what the top-level code of a plugin does ──

proc regCommand*(file, title, keys: string, cb: proc()) =
  ## (what `command` uses: call `command`)
  let f = cb
  discard register(file, "command", %*{"title": title, "keys": keys}, proc(a: JsonNode): JsonNode =
    f()
    newJNull())

template command*(title: string, body: untyped) =
  ## a command in the palette (and in the Plugins menu)
  regCommand(instantiationInfo(-1, true).filename, title, "", proc() = body)
template command*(title, keys: string, body: untyped) =
  ## … on a key too ("ctrl+alt+u", "alt+shift+k", "f9" — your "keys" setting wins over it)
  regCommand(instantiationInfo(-1, true).filename, title, keys, proc() = body)

proc regEvent*(file, kind, pattern: string, cb: proc(ev: Event)) =
  ## (what onOpen, onSave … use: call those)
  let f = cb
  discard register(file, "event", %*{"event": kind, "pattern": pattern}, proc(a: JsonNode): JsonNode =
    f(toEvent(a))
    newJNull())

template onStartup*(cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "startup", "*", cb)
  ## once, when ned has started (ev.buf: the file shown)
template onOpen*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "open", pattern, cb)
  ## a file opened. `pattern`: "*", "*.zig", "src/*.nim", or "lang:zig" for a language
template onBeforeSave*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "beforeSave", pattern, cb)
  ## about to be written: what the plugin changes is saved (ned waits plugins.timeoutMs for it)
template onSave*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "save", pattern, cb)
  ## a file saved (written). `pattern`: "*", "*.md", "src/*.nim", or "lang:nim"
template onClose*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "close", pattern, cb)
  ## a file's tab closed
template onChange*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "change", pattern, cb)
  ## the text changed (after a pause in the typing: not every key)
template onEnter*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "enter", pattern, cb)
  ## a tab came to the front (you switched to it, opened it, closed the one before it)
template onQuit*(cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "quit", "*", cb)
  ## ned quits: write what you keep now (ned waits a moment for it — ev.buf is not set)
template autocmd*(event, pattern: string, cb: proc(ev: Event)) =
  ## vim's names: BufReadPost BufEnter BufWritePre BufWritePost BufDelete TextChanged VimEnter VimLeave FileType
  regEvent(instantiationInfo(-1, true).filename, (case event
    of "BufRead", "BufReadPost", "FileType", "BufNewFile": "open"
    of "BufEnter", "BufWinEnter": "enter"
    of "VimLeave", "VimLeavePre": "quit"
    of "BufWritePre": "beforeSave"
    of "BufWritePost": "save"
    of "BufDelete", "BufUnload", "BufWipeout": "close"
    of "TextChanged", "TextChangedI": "change"
    of "VimEnter": "startup"
    else: event), (if event == "FileType" and not pattern.startsWith("lang:"): "lang:" & pattern else: pattern), cb)

proc toJson(s: LangSpec): JsonNode =
  result = newJObject()
  if s.name.len > 0: result["name"] = %s.name
  if s.extensions.len > 0: result["extensions"] = %s.extensions
  if s.files.len > 0: result["files"] = %s.files
  if s.lineComment.len > 0: result["lineComment"] = %s.lineComment
  if s.blockComment.len == 2: result["blockComment"] = %s.blockComment
  if s.quotes.len > 0: result["quotes"] = %s.quotes
  if s.keywords.len > 0: result["keywords"] = %s.keywords
  if s.types.len > 0: result["types"] = %s.types
  if s.constants.len > 0: result["constants"] = %s.constants
  if s.builtins.len > 0: result["builtins"] = %s.builtins
  if s.functionWords.len > 0: result["functionWords"] = %s.functionWords
  if s.classWords.len > 0: result["classWords"] = %s.classWords
  if s.indentAfter.len > 0: result["indentAfter"] = %s.indentAfter
  if s.dedent.len > 0: result["dedent"] = %s.dedent
  if s.indentSize > 0: result["indentSize"] = %s.indentSize
  if s.tabs: result["tabs"] = %true
  if s.run.len > 0: result["run"] = %s.run
  if s.build.len > 0: result["build"] = %s.build
  if s.check.len > 0: result["check"] = %s.check
  if s.pairs.len > 0: result["pairs"] = %s.pairs
  if s.dedentWords.len > 0: result["dedentWords"] = %s.dedentWords
  if s.nestedComments: result["nestedComments"] = %true
  if s.tripleQuotes: result["tripleQuotes"] = %true
  if s.multilineStrings: result["multilineStrings"] = %true
  if s.charLiterals: result["charLiterals"] = %true
  if s.capitalTypes: result["capitalTypes"] = %true
  if s.decorators: result["decorators"] = %true
  if s.docComment.len > 0: result["docComment"] = %s.docComment
  if s.docBlockComment.len == 2: result["docBlockComment"] = %s.docBlockComment
  if s.nameChars.len > 0: result["nameChars"] = %s.nameChars

proc regLanguage*(file, id: string, spec: LangSpec) = discard register(file, "language", %*{"id": id, "spec": toJson(spec)})
  ## (what `language` uses: call `language`)
template language*(id: string, spec: LangSpec) =
  ## a new language (or changes to one ned has); your "languages" setting wins over it
  regLanguage(instantiationInfo(-1, true).filename, id, spec)

proc regFiletype*(file, lang: string, indentSize: int, tabs: int, lineComment: string) =
  ## (what `filetype` uses: call `filetype`)
  var j = newJObject()
  if indentSize > 0: j["indentSize"] = %indentSize
  if tabs >= 0: j["tabs"] = %(tabs == 1)
  if lineComment.len > 0: j["lineComment"] = %lineComment
  discard register(file, "language", %*{"id": lang, "spec": j})
template filetype*(lang: string, indentSize = 0, tabs = -1, lineComment = "") =
  ## settings for a language's files (tabs: 1 tabs, 0 spaces, -1 as it is)
  regFiletype(instantiationInfo(-1, true).filename, lang, indentSize, tabs, lineComment)

proc regFormatterCmd*(file, lang, cmd: string) = discard register(file, "formatter", %*{"lang": lang, "cmd": cmd})
  ## (what `formatter` with a command uses: call `formatter`)
proc regFormatter*(file, lang: string, f: proc(text: string): string) =
  ## (what `formatter` with a proc uses: call `formatter`)
  let ff = f
  discard register(file, "formatter", %*{"lang": lang}, proc(a: JsonNode): JsonNode = %ff(a{"text"}.getStr))
template formatter*(lang: string, cmd: string) =
  ## a formatter command (the text on its stdin, the formatted text on its stdout; $file is the file)
  regFormatterCmd(instantiationInfo(-1, true).filename, lang, cmd)
template formatter*(lang: string, f: proc(text: string): string) =
  ## a formatter written in NimScript: the text in, the formatted text out (raise ValueError to say why not)
  regFormatter(instantiationInfo(-1, true).filename, lang, f)

proc regLsp*(file, lang: string, cmd: seq[string], script: string) =
  ## (what languageServer and languageServerScript use: call those)
  discard register(file, "lsp", %*{"lang": lang, "cmd": cmd, "script": script})
template languageServer*(lang: string, cmd: seq[string]) =
  ## a language server for the language's files (["zls"], ["pyright-langserver", "--stdio"])
  regLsp(instantiationInfo(-1, true).filename, lang, cmd, "")
template languageServerScript*(lang, script: string) =
  ## a language server written in NimScript (import nedlsp), a file of the plugin's folder; ned runs it through
  ## `ned --lsp-bridge <file>` — the same command works in other editors
  regLsp(instantiationInfo(-1, true).filename, lang, @[], script)

# ── vim (editor.vimMode) ──

proc regVimMap*(file, mode, keys: string, cb: proc(count: int), desc = "", lang = "") =
  ## (what nmap and vmap use: call those)
  let f = cb
  discard register(file, "vimMap", %*{"mode": mode, "keys": keys, "desc": desc, "lang": lang}, proc(a: JsonNode): JsonNode =
    f(a{"count"}.getInt(1))
    newJNull())
template nmap*(keys: string, cb: proc(count: int)) =
  ## a normal-mode key sequence ("gx", "<leader>f" — the leader is the space bar; "<C-a>" … "<C-z>": Ctrl and a
  ## letter, before vim's own use of it; "<CR>": Enter); count: the number typed before
  regVimMap(instantiationInfo(-1, true).filename, "n", keys, cb)
template nmap*(keys, desc: string, cb: proc(count: int)) =
  ## … with what it does, in a few words (which-key shows it after the keys before it)
  regVimMap(instantiationInfo(-1, true).filename, "n", keys, cb, desc)
template nmapIn*(lang, keys, desc: string, cb: proc(count: int)) =
  ## a normal-mode key sequence only in files (and tabs) of one language (its id: "markdown", "oil" …), before
  ## a mapping of the same keys for every file and vim's own
  regVimMap(instantiationInfo(-1, true).filename, "n", keys, cb, desc, lang)
template vmap*(keys: string, cb: proc(count: int)) =
  ## a visual-mode key sequence (the selection: current().selection)
  regVimMap(instantiationInfo(-1, true).filename, "v", keys, cb)
template vmap*(keys, desc: string, cb: proc(count: int)) =
  ## … with what it does, in a few words. When it is done, back to normal mode (unless it selected something)
  regVimMap(instantiationInfo(-1, true).filename, "v", keys, cb, desc)
template vmapIn*(lang, keys, desc: string, cb: proc(count: int)) =
  ## a visual-mode key sequence only in files (and tabs) of one language
  regVimMap(instantiationInfo(-1, true).filename, "v", keys, cb, desc, lang)

proc regLangKey*(file, lang, keys, desc: string, cb: proc(b: Buf)) =
  ## (what keyIn uses: call keyIn)
  let f = cb
  discard register(file, "langKey", %*{"lang": lang, "keys": keys, "desc": desc}, proc(a: JsonNode): JsonNode =
    f(Buf(id: a{"buf"}.getInt))
    newJNull())
template keyIn*(lang, keys, desc: string, cb: proc(b: Buf)) =
  ## a key ("alt+enter", "ctrl+alt+o") only in files (and tabs) of one language, in every keymap — before ned's
  ## own use of it there (your "keys" setting wins over it)
  regLangKey(instantiationInfo(-1, true).filename, lang, keys, desc, cb)

proc regSaveTab*(file, lang: string, cb: proc(ev: Event)) =
  ## (what onSaveTab uses: call onSaveTab)
  let f = cb
  discard register(file, "writer", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    f(toEvent(a))
    newJNull())
template onSaveTab*(lang: string, cb: proc(ev: Event)) =
  ## a tab of this language that is not a file (newTab): saving it (Ctrl+S, :w) calls cb instead of asking for
  ## a file name — the plugin does what saving means (the folder view: renames, deletes …), then markSaved
  regSaveTab(instantiationInfo(-1, true).filename, lang, cb)

proc regKeysWaiting*(file: string, ms: int, cb: proc(keys, mode: string)) =
  ## (what onKeysWaiting uses: call onKeysWaiting)
  let f = cb
  discard register(file, "event", %*{"event": "keys", "pattern": $max(0, ms)}, proc(a: JsonNode): JsonNode =
    f(a{"keys"}.getStr, a{"mode"}.getStr)
    newJNull())
template onKeysWaiting*(ms: int, cb: proc(keys, mode: string)) =
  ## keys that wait for more have waited ms milliseconds (vim's "g", "z", "d", a plugin's "<leader>", emacs's
  ## "C-x", helix's "<space>"): cb with them and the mode — n (vim normal), v (visual), o (an operator waits for
  ## its motion), obj (… for its text object, after i or a: "di"), emacs, helix. Once for each wait
  regKeysWaiting(instantiationInfo(-1, true).filename, ms, cb)

proc regEx*(file, name: string, cb: proc(args: string)) =
  ## (what exCommand uses: call exCommand)
  let f = cb
  discard register(file, "ex", %*{"name": name}, proc(a: JsonNode): JsonNode =
    f(a{"args"}.getStr)
    newJNull())
template exCommand*(name: string, cb: proc(args: string)) =
  ## a `:` command (`:Name args`)
  regEx(instantiationInfo(-1, true).filename, name, cb)

proc regOperator*(file, keys: string, cb: proc(b: Buf, r: Range, linewise: bool), desc = "") =
  ## (what `operator` uses: call `operator`)
  let f = cb
  discard register(file, "operator", %*{"keys": keys, "desc": desc}, proc(a: JsonNode): JsonNode =
    f(Buf(id: a{"buf"}.getInt), toRange(a{"range"}), a{"linewise"}.getBool)
    newJNull())
template operator*(keys: string, cb: proc(b: Buf, r: Range, linewise: bool)) =
  ## an operator: keys then a motion or a text object (`gcip`), the keys' last letter twice for lines (`gcc`), or
  ## on the visual selection
  regOperator(instantiationInfo(-1, true).filename, keys, cb)
template operator*(keys, desc: string, cb: proc(b: Buf, r: Range, linewise: bool)) =
  ## … with what it does, in a few words (which-key shows it)
  regOperator(instantiationInfo(-1, true).filename, keys, cb, desc)

proc regTextObject*(file, keys: string, cb: proc(b: Buf, p: Pos): Range, desc = "") =
  ## (what textObject uses: call textObject)
  let f = cb
  discard register(file, "textObject", %*{"keys": keys, "desc": desc}, proc(a: JsonNode): JsonNode =
    %f(Buf(id: a{"buf"}.getInt), toPos(a{"pos"})))
template textObject*(keys: string, cb: proc(b: Buf, p: Pos): Range) =
  ## a text object (two keys: "ie", "al"): the range around p (noRange() when none) — after an operator (d c y,
  ## a plugin's) or in visual mode
  regTextObject(instantiationInfo(-1, true).filename, keys, cb)
template textObject*(keys, desc: string, cb: proc(b: Buf, p: Pos): Range) =
  ## … with what it is, in a few words (which-key shows it)
  regTextObject(instantiationInfo(-1, true).filename, keys, cb, desc)

# ── timers ──

proc regTimer(file: string, ms: int, repeat: bool, cb: proc()): int =
  let f = cb
  register(file, "timer", %*{"ms": ms, "repeat": repeat}, proc(a: JsonNode): JsonNode =
    f()
    newJNull())
template every*(ms: int, cb: proc()): int =
  ## cb every ms milliseconds (ned keeps the time: at least 100); stopTimer(id) stops it
  regTimer(instantiationInfo(-1, true).filename, ms, true, cb)
template after*(ms: int, cb: proc()): int =
  ## cb once, ms milliseconds from now
  regTimer(instantiationInfo(-1, true).filename, ms, false, cb)
proc stopTimer*(id: int) = discard api("stopTimer", %*{"cb": id})
  ## the timer `every` or `after` started (its id) stopped

# ── language features for a language (6.20): completions, hover, code actions, symbols, snippets ──

type
  CompletionItem* = object
    ## one item of the completion list
    label*: string               ## what the list shows (and what is typed over)
    insert*: string              ## what goes in ("": the label)
    detail*: string              ## beside it in the list (a type, a signature)
    doc*: string                 ## Markdown, shown beside the list
    kind*: string                ## function method variable field type class keyword constant module snippet text
    snippet*: bool               ## insert is a snippet: $1 $2 … ${1:default} $0
  Symbol* = object
    ## one entry of the outline
    name*: string                ## what it shows
    kind*: string                ## function method type class variable constant heading section …
    detail*: string
    line*, col*: int             ## where it is (both from 0)
    depth*: int                  ## how deep in the outline (0 at the top)

proc `%`*(c: CompletionItem): JsonNode =
  ## the item as ned's JSON
  %*{"label": c.label, "insert": c.insert, "detail": c.detail, "doc": c.doc, "kind": c.kind, "snippet": c.snippet}
proc `%`*(s: Symbol): JsonNode =
  ## the symbol as ned's JSON
  %*{"name": s.name, "kind": s.kind, "detail": s.detail, "line": s.line, "col": s.col, "depth": s.depth}

proc regCompletions*(file, lang: string, cb: proc(b: Buf, p: Pos, prefix: string): seq[CompletionItem]) =
  ## (what `completions` uses: call `completions`)
  let f = cb
  discard register(file, "completion", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    result = newJArray()
    for it in f(Buf(id: a{"buf"}.getInt), toPos(a{"pos"}), a{"prefix"}.getStr): result.add %it)
template completions*(lang: string, cb: proc(b: Buf, p: Pos, prefix: string): seq[CompletionItem]) =
  ## completions for the language's files ("zig"; "*": every file) — merged with ned's own and a language
  ## server's; `prefix` is the word typed so far (ned narrows the list as you type)
  regCompletions(instantiationInfo(-1, true).filename, lang, cb)

proc regHover*(file, lang: string, cb: proc(b: Buf, p: Pos): string) =
  ## (what `hover` uses: call `hover`)
  let f = cb
  discard register(file, "hover", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    %f(Buf(id: a{"buf"}.getInt), toPos(a{"pos"})))
template hover*(lang: string, cb: proc(b: Buf, p: Pos): string) =
  ## what the hover (Alt+H, the mouse) shows at p — Markdown, "" for nothing; added under ned's own
  regHover(instantiationInfo(-1, true).filename, lang, cb)

proc regCodeActions*(file, lang: string, cb: proc(b: Buf, r: Range): seq[Fix]) =
  ## (what codeActions uses: call codeActions)
  let f = cb
  discard register(file, "codeActions", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    result = newJArray()
    for x in f(Buf(id: a{"buf"}.getInt), toRange(a{"range"})): result.add %x)
template codeActions*(lang: string, cb: proc(b: Buf, r: Range): seq[Fix]) =
  ## fixes and refactorings for the selection or the cursor's line: the Quick fixes list (Alt+Enter)
  regCodeActions(instantiationInfo(-1, true).filename, lang, cb)

proc regSymbols*(file, lang: string, cb: proc(b: Buf): seq[Symbol]) =
  ## (what `symbols` uses: call `symbols`)
  let f = cb
  discard register(file, "symbols", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    result = newJArray()
    for s in f(Buf(id: a{"buf"}.getInt)): result.add %s)
template symbols*(lang: string, cb: proc(b: Buf): seq[Symbol]) =
  ## the file's symbols: the Outline dock, Go to symbol, the breadcrumbs (asked again after each pause in the typing)
  regSymbols(instantiationInfo(-1, true).filename, lang, cb)

proc regSnippet*(file, lang, trigger, body, description: string) =
  ## (what `snippet` uses: call `snippet`)
  discard register(file, "snippet", %*{"lang": lang, "trigger": trigger, "body": body, "description": description})
template snippet*(lang, trigger, body: string, description = "") =
  ## a snippet ($1 $2 … ${1:default} $0) for the language's files ("*": every file); yours (the "snippets"
  ## setting) win over it
  regSnippet(instantiationInfo(-1, true).filename, lang, trigger, body, description)

# ── the assistant: tools it may call (6.20) ──

proc regAiTool*(file, name, description: string, params: JsonNode, readOnly: bool, cb: proc(args: JsonNode): string) =
  ## (what aiTool and aiToolReadOnly use: call those)
  let f = cb
  discard register(file, "aiTool", %*{"name": name, "description": description, "params": params,
                                       "readOnly": readOnly}, proc(a: JsonNode): JsonNode = %f(a))
template aiTool*(name, description: string, params: JsonNode, cb: proc(args: JsonNode): string) =
  ## a tool the assistant (ned's AI agent) may call: params — its arguments as JSON schema properties
  ## (%*{"path": {"type": "string", "description": "…"}}); the text returned is what it gets back (raise to report
  ## an error). It asks you first, as for a command (ai.autoApprove)
  regAiTool(instantiationInfo(-1, true).filename, name, description, params, false, cb)
template aiToolReadOnly*(name, description: string, params: JsonNode, cb: proc(args: JsonNode): string) =
  ## … one that only reads: it runs without asking, as reading a file does
  regAiTool(instantiationInfo(-1, true).filename, name, description, params, true, cb)

# ── views in the Plugins dock, progress, output, the terminal (6.20) ──

type
  ViewItem* = object
    ## one row of a view in the Plugins dock
    text*, detail*: string       ## its text, and the dimmer text beside it
    icon*: string                ## one character ("●", "✓" …)
    color*: string               ## error warn info hint accent add del
    id*: string                  ## what the view's click callback gets
    path*: string                ## a file: clicking opens it (at line, when no click callback takes it)
    line*: int                   ## (with path) the line clicking opens it at (from 0)
    depth*: int                  ## how far it is indented (a tree: 0 at the top)

proc `%`*(v: ViewItem): JsonNode =
  ## the item as ned's JSON
  %*{"text": v.text, "detail": v.detail, "icon": v.icon, "color": v.color, "id": v.id, "path": v.path,
     "line": v.line, "depth": v.depth}

proc regView*(file, title: string, getItems: proc(): seq[ViewItem], click: proc(id: string)) =
  ## (what `view` uses: call `view`)
  let f = getItems
  discard register(file, "view", %*{"title": title}, proc(a: JsonNode): JsonNode =
    result = newJArray()
    for v in f(): result.add %v)
  if click != nil:
    let c = click
    discard register(file, "viewClick", %*{"title": title}, proc(a: JsonNode): JsonNode =
      c(a{"id"}.getStr)
      newJNull())
template view*(title: string, getItems: proc(): seq[ViewItem]) =
  ## a section of the Plugins dock: its items (asked when the dock shows, and after refreshView)
  regView(instantiationInfo(-1, true).filename, title, getItems, nil)
template view*(title: string, getItems: proc(): seq[ViewItem], click: proc(id: string)) =
  ## … and what clicking an item does (it gets the item's id)
  regView(instantiationInfo(-1, true).filename, title, getItems, click)
proc refreshView*(title: string) = discard api("refreshView", %*{"title": title})
  ## the view's items again (they changed)

proc progress*(text: string, percent = -1) = discard api("progress", %*{"text": text, "percent": percent})
  ## work under way, in the status bar ("Indexing", 40); percent -1: not known
proc progressDone*() = progress("")
  ## the status bar's progress item for this plugin removed
proc output*(text: string) = discard api("output", %*{"text": text})
  ## lines in the Output panel (file:line:col in them can be clicked)
proc showOutput*() = discard api("showOutput")
  ## the Output panel shown (what `output` wrote)
proc runInTerminal*(cmd: string, dir = "") = discard api("terminal", %*{"cmd": cmd, "dir": dir})
  ## a command in ned's integrated terminal (in dir; else the project's folder)

# ── what the plugin needs, its settings (6.20) ──

proc regRequires*(file, spec: string) = discard register(file, "requires", %*{"spec": spec})
  ## (what requiresNed uses: call requiresNed)
template requiresNed*(spec: string) =
  ## the ned it needs (">= 6.20"): an older ned leaves the plugin out and says why
  regRequires(instantiationInfo(-1, true).filename, spec)

proc regSettingDef*(file, key: string, default: JsonNode, description: string) =
  ## (what settingDef uses: call settingDef)
  discard register(file, "setting", %*{"key": key, "default": default, "description": description})
template settingDef*(key: string, default: string | int | bool | float, description: string) =
  ## one of the plugin's settings, shown in ned's Settings panel as plugins.<plugin>.<key>
  regSettingDef(instantiationInfo(-1, true).filename, key, %default, description)
