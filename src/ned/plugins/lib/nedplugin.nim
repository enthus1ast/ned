## nedplugin — what a ned plugin imports.
##
## A plugin is a folder with a `plugin.nims` (NimScript: ned runs every plugin in one `nim e` process, or compiled
## when `plugins.native` is on). Its top-level code runs once when the plugins start: it registers commands, keys,
## events, languages, formatters, language servers, vim mappings … with the procs below. ned calls them back.
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
export json, strutils
when not defined(nimscript):
  import std/osproc

type
  Pos* = object
    line*, col*: int
  Range* = object
    start*, stop*: Pos           ## from start up to stop (stop not included)
  Buf* = object                  ## an open file (or an unsaved one) in ned
    id*: int
  Event* = object
    buf*: Buf
    path*, lang*: string         ## the file and its language id ("nim", "zig" …)
  Edit* = object
    range*: Range
    text*: string
  Fix* = object
    title*: string
    edits*: seq[Edit]
  Problem* = object
    range*: Range
    severity*: int               ## 1 error, 2 warning, 3 information, 4 hint
    message*: string
    fixes*: seq[Fix]             ## Alt+Enter offers them
  LangSpec* = object
    ## a language ned colours with its generic lexer (or changes to one it has): the "languages" setting's fields
    name*: string
    extensions*, files*: seq[string]
    lineComment*: string
    blockComment*: seq[string]   ## @["/*", "*/"]
    quotes*: string              ## "\"'"
    keywords*, types*, constants*, builtins*: seq[string]
    functionWords*, classWords*: seq[string]  ## the words before a function's or a class's name (outline)
    indentAfter*: seq[string]    ## "{" ":" … or words: the next line is indented
    dedent*: string              ## typing one of these takes a level off ("}")
    indentSize*: int
    tabs*: bool
    run*: string                 ## the command F5 runs ($file …)
    pairs*: string               ## "()[]{}\"\"" — what typing an opening one closes

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
proc `%`*(r: Range): JsonNode = %*{"start": %r.start, "stop": %r.stop}
proc toPos(j: JsonNode): Pos = Pos(line: j{"line"}.getInt, col: j{"col"}.getInt)
proc toRange(j: JsonNode): Range =
  if j == nil or j.kind != JObject: return Range(start: Pos(line: -1), stop: Pos(line: -1))
  Range(start: toPos(j{"start"}), stop: toPos(j{"stop"}))
proc `%`*(e: Edit): JsonNode = %*{"range": %e.range, "text": e.text}
proc `%`*(f: Fix): JsonNode =
  result = %*{"title": f.title, "edits": newJArray()}
  for e in f.edits: result["edits"].add %e
proc `%`*(p: Problem): JsonNode =
  result = %*{"range": %p.range, "severity": (if p.severity == 0: 2 else: p.severity), "message": p.message,
              "fixes": newJArray()}
  for f in p.fixes: result["fixes"].add %f
proc toEvent(j: JsonNode): Event =
  Event(buf: Buf(id: j{"buf"}.getInt(-1)), path: j{"path"}.getStr, lang: j{"lang"}.getStr)

func pos*(line, col: int): Pos = Pos(line: line, col: col)
func rng*(a, b: Pos): Range = Range(start: a, stop: b)
func isEmpty*(r: Range): bool = r.start.line < 0 or (r.start.line == r.stop.line and r.start.col >= r.stop.col)
func noRange*(): Range = Range(start: Pos(line: -1), stop: Pos(line: -1))
  ## what a text object returns when there is none at the cursor

# ── buffers: the text ──

proc current*(): Buf = Buf(id: api("current").getInt(-1))
  ## the file being edited
proc openFile*(path: string, line = -1, col = -1): Buf =
  ## open a file (or go to it), at a line when given
  Buf(id: api("open", %*{"path": path, "line": line, "col": col}).getInt(-1))
proc buffers*(): seq[Buf] =
  for x in api("buffers"): result.add Buf(id: x.getInt)
proc valid*(b: Buf): bool = b.id >= 0
proc path*(b: Buf): string = api("path", %*{"buf": b.id}).getStr
proc lang*(b: Buf): string = api("lang", %*{"buf": b.id}).getStr
proc lineCount*(b: Buf): int = api("lineCount", %*{"buf": b.id}).getInt
proc line*(b: Buf, i: int): string = api("line", %*{"buf": b.id, "line": i}).getStr
proc lines*(b: Buf, first = 0, last = -1): seq[string] =
  ## lines first .. last (-1: to the end)
  for x in api("lines", %*{"buf": b.id, "first": first, "last": last}): result.add x.getStr
proc text*(b: Buf): string = api("text", %*{"buf": b.id}).getStr
proc textIn*(b: Buf, r: Range): string = api("textIn", %*{"buf": b.id, "range": %r}).getStr
proc setText*(b: Buf, s: string) = discard api("setText", %*{"buf": b.id, "text": s})
  ## the whole text (ned changes only the lines that differ: the cursor and the undo stay sensible)
proc replace*(b: Buf, r: Range, s: string) = discard api("replace", %*{"buf": b.id, "range": %r, "text": s})
proc insert*(b: Buf, p: Pos, s: string) = b.replace(rng(p, p), s)
proc delete*(b: Buf, r: Range) = b.replace(r, "")
proc cursor*(b: Buf): Pos = toPos(api("cursor", %*{"buf": b.id}))
proc setCursor*(b: Buf, p: Pos) = discard api("setCursor", %*{"buf": b.id, "pos": %p})
proc selection*(b: Buf): Range = toRange(api("selection", %*{"buf": b.id}))
  ## the main selection (empty: start == stop, the cursor)
proc selections*(b: Buf): seq[Range] =
  for x in api("selections", %*{"buf": b.id}): result.add toRange(x)
proc select*(b: Buf, r: Range) = discard api("select", %*{"buf": b.id, "range": %r})
proc wordAt*(b: Buf, p: Pos): string = api("wordAt", %*{"buf": b.id, "pos": %p}).getStr
proc dirty*(b: Buf): bool = api("dirty", %*{"buf": b.id}).getBool
proc save*(b: Buf) = discard api("save", %*{"buf": b.id})
proc indentUnit*(b: Buf): string = api("indent", %*{"buf": b.id}).getStr
  ## two spaces, four, a tab … what this file indents with
proc lineComment*(b: Buf): string = api("lineComment", %*{"buf": b.id}).getStr
  ## the language's line comment ("#", "//"; "" none)
proc lineRange*(b: Buf, line: int): Range = rng(pos(line, 0), pos(line, b.line(line).len))
proc wholeLines*(b: Buf, first, last: int): Range =
  ## lines first .. last with their line ends
  if last + 1 < b.lineCount: rng(pos(first, 0), pos(last + 1, 0))
  else: rng(pos(first, 0), pos(last, b.line(last).len))

# ── talking to you ──

proc message*(s: string) = discard api("message", %*{"text": s})
  ## the status line
proc warn*(s: string) = discard api("message", %*{"text": s, "level": "warn"})
proc toast*(s: string) = discard api("toast", %*{"text": s})
  ## a note in the corner that goes away by itself
proc pick*(title: string, items: openArray[string], details: openArray[string] = []): int =
  ## a list to choose from: the index chosen, -1 when cancelled
  api("pick", %*{"title": title, "items": @items, "details": @details}).getInt(-1)
proc ask*(prompt: string, default = ""): string =
  ## a line of text ("" when cancelled)
  api("ask", %*{"prompt": prompt, "default": default}).getStr
proc confirm*(question: string): bool = api("confirm", %*{"text": question}).getBool
proc runCommand*(name: string) = discard api("runCommand", %*{"name": name})
  ## a command of ned's palette, by its name ("Format document", "Save" …)

proc shell*(cmd: string, dir = ""): tuple[output: string, code: int] =
  ## a shell command's output and exit code (in `dir`, else the project's folder)
  let d = if dir.len > 0: dir else: api("root").getStr
  let full = "cd " & quoteShell(d) & " && " & cmd
  when defined(nimscript):
    let (o, c) = gorgeEx(full)
    (o, c)
  else:
    let (o, c) = execCmdEx(full)
    (o.strip(leading = false, chars = {'\n'}), c)

# ── problems, signs, text after a line, highlights, the status bar ──

proc setProblems*(b: Buf, problems: openArray[Problem]) =
  ## this plugin's problems in the file (the ones it set before go); Alt+Enter offers their fixes
  var a = newJArray()
  for p in problems: a.add %p
  discard api("problems", %*{"buf": b.id, "problems": a})
proc clearProblems*(b: Buf) = b.setProblems([])
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

proc settingNode(key: string): JsonNode = api("setting", %*{"key": key})
proc setting*(key: string, default: string): string =
  ## plugins.<this plugin>.<key> from your settings
  let v = settingNode(key)
  if v == nil or v.kind != JString: default else: v.getStr
proc setting*(key: string, default: int): int =
  let v = settingNode(key)
  if v == nil or v.kind != JInt: default else: v.getInt
proc setting*(key: string, default: bool): bool =
  let v = settingNode(key)
  if v == nil or v.kind != JBool: default else: v.getBool
proc setting*(key: string, default: float): float =
  let v = settingNode(key)
  if v == nil or v.kind notin {JFloat, JInt}: default else: v.getFloat
proc dataDir*(): string = api("dataDir").getStr
  ## a folder of this plugin's own (made when asked for)
proc pluginDir*(): string = api("pluginDir").getStr
proc log*(s: string) = discard api("log", %*{"text": s})
  ## a line in the plugin's log (the Plugins dock)

# ── registering: what the top-level code of a plugin does ──

proc regCommand*(file, title, keys: string, cb: proc()) =
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
template onClose*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "close", pattern, cb)
template onChange*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "change", pattern, cb)
  ## the text changed (after a pause in the typing: not every key)
template autocmd*(event, pattern: string, cb: proc(ev: Event)) =
  ## vim's names: BufReadPost BufWritePre BufWritePost BufDelete TextChanged VimEnter FileType
  regEvent(instantiationInfo(-1, true).filename, (case event
    of "BufRead", "BufReadPost", "BufEnter", "FileType", "BufNewFile": "open"
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
  if s.pairs.len > 0: result["pairs"] = %s.pairs

proc regLanguage*(file, id: string, spec: LangSpec) = discard register(file, "language", %*{"id": id, "spec": toJson(spec)})
template language*(id: string, spec: LangSpec) =
  ## a new language (or changes to one ned has); your "languages" setting wins over it
  regLanguage(instantiationInfo(-1, true).filename, id, spec)

proc regFiletype*(file, lang: string, indentSize: int, tabs: int, lineComment: string) =
  var j = newJObject()
  if indentSize > 0: j["indentSize"] = %indentSize
  if tabs >= 0: j["tabs"] = %(tabs == 1)
  if lineComment.len > 0: j["lineComment"] = %lineComment
  discard register(file, "language", %*{"id": lang, "spec": j})
template filetype*(lang: string, indentSize = 0, tabs = -1, lineComment = "") =
  ## settings for a language's files (tabs: 1 tabs, 0 spaces, -1 as it is)
  regFiletype(instantiationInfo(-1, true).filename, lang, indentSize, tabs, lineComment)

proc regFormatterCmd*(file, lang, cmd: string) = discard register(file, "formatter", %*{"lang": lang, "cmd": cmd})
proc regFormatter*(file, lang: string, f: proc(text: string): string) =
  let ff = f
  discard register(file, "formatter", %*{"lang": lang}, proc(a: JsonNode): JsonNode = %ff(a{"text"}.getStr))
template formatter*(lang: string, cmd: string) =
  ## a formatter command (the text on its stdin, the formatted text on its stdout; $file is the file)
  regFormatterCmd(instantiationInfo(-1, true).filename, lang, cmd)
template formatter*(lang: string, f: proc(text: string): string) =
  ## a formatter written in NimScript: the text in, the formatted text out (raise ValueError to say why not)
  regFormatter(instantiationInfo(-1, true).filename, lang, f)

proc regLsp*(file, lang: string, cmd: seq[string], script: string) =
  discard register(file, "lsp", %*{"lang": lang, "cmd": cmd, "script": script})
template languageServer*(lang: string, cmd: seq[string]) =
  ## a language server for the language's files (["zls"], ["pyright-langserver", "--stdio"])
  regLsp(instantiationInfo(-1, true).filename, lang, cmd, "")
template languageServerScript*(lang, script: string) =
  ## a language server written in NimScript (import nedlsp), a file of the plugin's folder; ned runs it through
  ## `ned --lsp-bridge <file>` — the same command works in other editors
  regLsp(instantiationInfo(-1, true).filename, lang, @[], script)

# ── vim (editor.vimMode) ──

proc regVimMap*(file, mode, keys: string, cb: proc(count: int)) =
  let f = cb
  discard register(file, "vimMap", %*{"mode": mode, "keys": keys}, proc(a: JsonNode): JsonNode =
    f(a{"count"}.getInt(1))
    newJNull())
template nmap*(keys: string, cb: proc(count: int)) =
  ## a normal-mode key sequence ("gx", "<leader>f" — the leader is the space bar); count: the number typed before
  regVimMap(instantiationInfo(-1, true).filename, "n", keys, cb)
template vmap*(keys: string, cb: proc(count: int)) =
  ## a visual-mode key sequence (the selection: current().selection)
  regVimMap(instantiationInfo(-1, true).filename, "v", keys, cb)

proc regEx*(file, name: string, cb: proc(args: string)) =
  let f = cb
  discard register(file, "ex", %*{"name": name}, proc(a: JsonNode): JsonNode =
    f(a{"args"}.getStr)
    newJNull())
template exCommand*(name: string, cb: proc(args: string)) =
  ## a `:` command (`:Name args`)
  regEx(instantiationInfo(-1, true).filename, name, cb)

proc regOperator*(file, keys: string, cb: proc(b: Buf, r: Range, linewise: bool)) =
  let f = cb
  discard register(file, "operator", %*{"keys": keys}, proc(a: JsonNode): JsonNode =
    f(Buf(id: a{"buf"}.getInt), toRange(a{"range"}), a{"linewise"}.getBool)
    newJNull())
template operator*(keys: string, cb: proc(b: Buf, r: Range, linewise: bool)) =
  ## an operator: keys then a motion or a text object (`gcip`), the keys' last letter twice for lines (`gcc`), or
  ## on the visual selection
  regOperator(instantiationInfo(-1, true).filename, keys, cb)

proc regTextObject*(file, keys: string, cb: proc(b: Buf, p: Pos): Range) =
  let f = cb
  discard register(file, "textObject", %*{"keys": keys}, proc(a: JsonNode): JsonNode =
    %f(Buf(id: a{"buf"}.getInt), toPos(a{"pos"})))
template textObject*(keys: string, cb: proc(b: Buf, p: Pos): Range) =
  ## a text object (two keys: "ie", "al"): the range around p (noRange() when none) — after an operator (d c y,
  ## a plugin's) or in visual mode
  regTextObject(instantiationInfo(-1, true).filename, keys, cb)

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
