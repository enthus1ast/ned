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
##
## How the calls go, both ways:
##
## - ned calls a plugin back (a command, an event, a completion …) one call at a time for each process: while one
##   callback runs, the other plugins in the same process wait. Keep callbacks short; run slow programs with
##   `shellAsync`, and give a slow plugin a process of its own (`plugins.alone`).
## - Every proc below that asks ned something sends it a request and waits for the answer: a few milliseconds
##   under `nim e`, about 0.3 ms compiled. Ask for many lines at once (`b.lines`), not one request a line.
## - All the edits a plugin makes in one callback are one undo step.
## - A request ned refuses raises `ValueError` with ned's reason: a tab that was closed, a read-only file, a
##   permission you did not give. An exception that leaves a callback is that call's error: it is written in the
##   plugin's log and shown in the status line, and the plugin goes on running.
## - ned waits for some callbacks before it goes on — `onBeforeSave`, a NimScript formatter, a text object, code
##   actions — up to `plugins.timeoutMs` (1500 ms; 1 s for code actions). It does not wait for the others.

import std/[json, tables, strutils, os]
export json, strutils, os
when not defined(nimscript):
  import std/osproc

type
  Pos* = object
    ## A place in a file: a line and a column, both counted from 0. The column is a byte offset in the line's
    ## UTF-8 text, not a count of characters: in `"né x"` the `x` is at column 4. Nim's `find` and string
    ## indexes count the same way, so their numbers can be used as they are. Make one with `pos(line, col)`.
    ##
    ##     let top = pos(0, 0)              # the start of the file
    ##     let here = current().cursor      # where the cursor is
    line*, col*: int             ## its line (from 0) and column (from 0, a byte offset in the line)
  Range* = object
    ## Some text of a file: from `start` up to `stop`, `stop` itself not included. An empty range (`start` ==
    ## `stop`) is a place between two characters: replacing it inserts there. Make one with `rng(a, b)`,
    ## `b.lineRange(line)` or `b.wholeLines(first, last)`; `noRange()` is no range at all.
    ##
    ##     let word = rng(pos(2, 4), pos(2, 9))   # line 3, columns 4 to 8
    start*, stop*: Pos           ## from start up to stop (stop not included)
  Buf* = object
    ## A tab of ned's: a file, an unsaved new file, or a tab a plugin made (`newTab`). It is only a number —
    ## every question about it (`b.text`, `b.cursor` …) asks ned, so the answer is the file as it is now. Once
    ## its tab is closed, asking about it raises `ValueError` ("no such buffer").
    id*: int                     ## ned's number for it, the same while its tab is open (-1: none — `valid` is false)
  Event* = object
    ## What an event is about, given to each event's callback (`onOpen`, `onSave` …): the file, its path and its
    ## language.
    buf*: Buf                    ## the file (onQuit: none, id -1)
    path*, lang*: string         ## the file's path ("" for a tab that is not a file) and its language id ("nim",
                                 ## "zig" …)
  Edit* = object
    ## One change to a file: the text of `range` replaced with `text`. A `Fix` is a list of them; ned applies a
    ## list from the last edit back to the first, so each range is a range of the text before any of them.
    range*: Range                ## what it replaces (empty: an insertion at its start)
    text*: string                ## what goes there (it may have line ends; "" deletes)
  Fix* = object
    ## A change Alt+Enter offers in its Quick fixes list: the title it shows, and the edits it makes when chosen
    ## — all of them one undo step. A problem's `fixes` and what `codeActions` gives are lists of these.
    ##
    ##     Fix(title: "Use two spaces", edits: @[Edit(range: rng(pos(3, 0), pos(3, 1)), text: "  ")])
    title*: string               ## what the list shows ("Use `foo`"); a fix without a title is left out
    edits*: seq[Edit]            ## the changes it makes (one undo step); a fix without edits is left out
  Problem* = object
    ## Something wrong in a file, as a plugin reports it with `setProblems`: the text is underlined, the Problems
    ## panel lists it, the gutter marks it, Alt+N and Alt+P go from one to the next, and Alt+Enter on its line
    ## offers its fixes.
    ##
    ##     Problem(range: b.lineRange(4), severity: 2, message: "a line over 100 characters",
    ##             fixes: @[Fix(title: "Cut it", edits: @[Edit(range: rng(pos(4, 100), pos(4, 140)))])])
    range*: Range                ## the text it is about (an empty range: the place)
    severity*: int               ## 1 error, 2 warning (0 is taken as 2), 3 information, 4 hint
    message*: string             ## what is wrong, in the Problems panel and the hover
    fixes*: seq[Fix]             ## what Alt+Enter offers on its line (none: no fix)
  LangSpec* = object
    ## A language for `language`: a new one, or changes to one ned has. A new language is coloured by ned's
    ## generic lexer with the words and rules given here; for one ned has (by its id or its name), the word lists
    ## are added to its own and the other fields given take the place of its. Every field may be left out. They
    ## are the fields of the `languages` setting, and yours win over a plugin's, field by field.
    ##
    ##     language("just", LangSpec(name: "Just", files: @["justfile"], lineComment: "#",
    ##                               keywords: @["set", "alias", "export"], nameChars: "-"))
    name*: string                ## its name in the status bar and the language list ("Zig"; "": its id)
    extensions*, files*: seq[string]  ## its files: by extension, no dot (@["zig", "zon"]), or by whole name
                                      ## (@["build.zig"])
    lineComment*: string         ## its line comment ("//", "#"): what Ctrl+/ and `b.lineComment` use
    blockComment*: seq[string]   ## its block comment, start and end: `@["/*", "*/"]` (two strings, or none)
    quotes*: string              ## the characters a string starts and ends with (`"\"'"`; a new language: both)
    keywords*, types*, constants*, builtins*: seq[string]  ## words coloured as keywords, types, constants, builtins
    functionWords*, classWords*: seq[string]  ## the words before a function's or a class's name (@["fn"]): the
                                              ## outline finds the names after them
    indentAfter*: seq[string]    ## a line that ends in one of these indents the next: characters ({ ( [ : =) or
                                 ## words (@["do", "then"])
    dedent*: string              ## typing one of these characters at a line's start takes a level off ("})]")
    indentSize*: int             ## spaces to an indentation level (0: not set — 2 for a new language)
    tabs*: bool                  ## indent with tabs (false: not set; `filetype(lang, tabs = 0)` turns tabs off)
    run*: string                 ## the command F5 runs; $file $dir $name $root $tmp in it are replaced ("zig run
                                 ## $file")
    build*, check*: string       ## the commands of Build (Alt+B) and of the check on save (the same $ words)
    pairs*: string               ## `"()[]{}\"\""` — what typing an opening one closes (a new language: `()[]{}""''`)
    dedentWords*: seq[string]    ## a line that becomes one of these words alone goes one level out (@["end"])
    nestedComments*: bool        ## a block comment may hold another (`/* /* */ */` — Odin, Haskell's {- -})
    tripleQuotes*: bool          ## `"""…"""` strings, over several lines
    multilineStrings*: bool      ## a "…" string (or a backquoted one) not closed on its line goes on below (Gleam,
                                 ## Odin's raw)
    charLiterals*: bool          ## 'a' is a character (not a quote of a string)
    capitalTypes*: bool          ## a Capitalised word is a type (an ALL-CAPS one a constant)
    decorators*: bool            ## @name is coloured as an attribute
    docComment*: string          ## a doc comment's line start ("///", "--|"), coloured as documentation
    docBlockComment*: seq[string]  ## a doc block comment: `@["/**", "*/"]`
    nameChars*: string           ## characters a name may have after its first letter, besides letters, digits
                                 ## and _ ("?!" Elixir, "'" Haskell, "-" Lisp)

const ProtoMark = "\x1e"         ## (the start of a line ned reads as a message; any other line is the plugin's log)

var
  callbacks: seq[proc(args: JsonNode): JsonNode]
  cbOwner: seq[string]           # the plugin each callback belongs to
  nextApi = 0
  results: Table[int, JsonNode]  # API answers that came while waiting for another
  queued: seq[JsonNode]          # ned's calls that came while waiting for an answer
  curPlugin* = ""                ## the plugin whose code runs now — the library's own: a plugin whose source
                                 ## names it is taken as asking for every permission
  curRid = 0                     # the call of ned's it runs for (edits in it are one undo step)
  # a copy of a buffer's lines, kept while ned says its version has not changed: reading a file line by line asks
  # ned once, not once a line (ned sends the versions of the buffers a call is about with the call)
  bufVer: Table[int, string]     # buffer id → its version as ned last said
  bufCopy: Table[int, (string, seq[string])]   # buffer id → (the version it is a copy of, its lines)
  bufMiss: Table[int, (string, int)]           # buffer id → (version, reads asked of ned at it)
  knownCur = -2                  # the current buffer, as the call ned is running says (-2: not known: ask)
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
  ## The plugin a source file belongs to: the name of the plugin whose folder holds it (ned names the plugins'
  ## folders in `NED_PLUGIN_DIRS` when it starts their process), or — for a file run on its own — its folder's
  ## name. The registering templates use it to know whose a registration is; a plugin seldom needs it.
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

const ReadOnlyApi = ["buffers", "path", "lang", "lineCount", "line", "lines", "text", "textIn", "dirty", "indent",
                     "lineComment", "wordAt", "cursor", "selection", "selections", "vimMode", "snapshot", "setting",
                     "dataDir", "pluginDir", "log", "message", "status", "progress", "clipboard", "sign", "vtext",
                     "highlight", "clearDecorations", "toast", "output", "problems", "setCursor", "select"]

proc api*(fn: string, args: JsonNode = newJObject()): JsonNode =
  ## Sends ned the request `fn` with its arguments and waits for the answer: what every API proc below uses.
  ## Raises `ValueError` with ned's reason when ned refuses. The requests and their arguments are ned's own and
  ## may change between versions: use the procs below.
  if fn notin ReadOnlyApi:
    bufVer.clear()                               # (an edit, or something that may lead to one: copies not trusted)
    knownCur = -2
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
    let vs = j{"vers"}
    if vs != nil and vs.kind == JObject:
      for k, v in vs:
        try: bufVer[parseInt(k)] = v.getStr
        except ValueError: discard
    if cb < 0 or cb >= callbacks.len:
      send(%*{"t": "ret", "rid": rid, "err": "no such callback"})
      return
    let (p0, r0, c0) = (curPlugin, curRid, knownCur)
    curPlugin = cbOwner[cb]
    curRid = rid
    knownCur = j{"cur"}.getInt(-2)
    try:
      let v = callbacks[cb](j{"args"})
      send(%*{"t": "ret", "rid": rid, "value": (if v == nil: newJNull() else: v)})
    except CatchableError as e:
      send(%*{"t": "ret", "rid": rid, "err": e.msg})
    curPlugin = p0
    curRid = r0
    knownCur = c0
  of "quit": quit(0)
  else: discard

proc nedRun*() =
  ## The host's loop: ned writes a host program that imports each plugin and ends with `nedRun()`, which answers
  ## ned's calls one at a time until ned says quit. A plugin never calls it.
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
  ## The position as ned's JSON, `{"line": 3, "col": 0}` — for a tool's answer or a file of your own.
proc `%`*(r: Range): JsonNode = %*{"start": %r.start, "stop": %r.stop}
  ## The range as ned's JSON, `{"start": {…}, "stop": {…}}`.
proc toPos(j: JsonNode): Pos = Pos(line: j{"line"}.getInt, col: j{"col"}.getInt)
proc toRange(j: JsonNode): Range =
  if j == nil or j.kind != JObject: return Range(start: Pos(line: -1), stop: Pos(line: -1))
  Range(start: toPos(j{"start"}), stop: toPos(j{"stop"}))
proc `%`*(e: Edit): JsonNode = %*{"range": %e.range, "text": e.text}
  ## The edit as ned's JSON, `{"range": {…}, "text": "…"}`.
proc `%`*(f: Fix): JsonNode =
  ## The fix as ned's JSON, `{"title": "…", "edits": […]}`.
  result = %*{"title": f.title, "edits": newJArray()}
  for e in f.edits: result["edits"].add %e
proc `%`*(p: Problem): JsonNode =
  ## The problem as ned's JSON (a severity of 0 becomes 2, a warning).
  result = %*{"range": %p.range, "severity": (if p.severity == 0: 2 else: p.severity), "message": p.message,
              "fixes": newJArray()}
  for f in p.fixes: result["fixes"].add %f
proc toEvent(j: JsonNode): Event =
  Event(buf: Buf(id: j{"buf"}.getInt(-1)), path: j{"path"}.getStr, lang: j{"lang"}.getStr)

func pos*(line, col: int): Pos = Pos(line: line, col: col)
  ## A position: `line` and `col`, both from 0; `col` is a byte offset in the line.
  ##
  ##     b.setCursor(pos(0, 0))         # to the start of the file
func rng*(a, b: Pos): Range = Range(start: a, stop: b)
  ## The range from `a` up to `b` (`b` itself not included). `rng(p, p)` is empty: a place to insert at.
  ##
  ##     b.replace(rng(pos(0, 0), pos(0, 4)), "Done")   # the first four bytes of the first line
func isEmpty*(r: Range): bool = r.start.line < 0 or (r.start.line == r.stop.line and r.start.col >= r.stop.col)
  ## True when the range holds no text: `start` is at `stop` (or after it on the same line), or it is
  ## `noRange()`.
func noRange*(): Range = Range(start: Pos(line: -1), stop: Pos(line: -1))
  ## No range at all (its start is at line -1): what a text object returns when there is none at the cursor, and
  ## what a helper of yours can return for "not found". `isEmpty` is true for it.

# ── buffers: the text ──

proc current*(): Buf = Buf(id: (if knownCur >= -1: knownCur else: api("current").getInt(-1)))
  ## The file being edited: the tab in front. In a callback ned says which it is with the call, so this costs no
  ## request. Its id is -1 (`valid` false) when there is none.
  ##
  ##     let b = current()
  ##     message(b.path & ": line " & $(b.cursor.line + 1))
proc openFile*(path: string, line = -1, col = -1): Buf =
  ## Opens a file in a tab — or goes to its tab when it is open — and brings it to the front. `path` is absolute
  ## or relative to the project's folder. `line` and `col` (from 0) put the cursor there; -1 leaves it where it
  ## was. Returns the file's `Buf`, or one with id -1 (`valid` false) when it cannot be opened.
  ##
  ##     let b = openFile("src/app.nim", 41)     # line 42, as people count
  Buf(id: api("open", %*{"path": path, "line": line, "col": col}).getInt(-1))
proc newTab*(title, text: string, lang = ""): Buf =
  ## Opens a tab of the plugin's own with `text` in it — not a file until it is saved: a response, generated
  ## code, a report — and brings it to the front. `title` is the name on the tab. `lang` is a language's id or
  ## name ("json", "Markdown") for its colours ("": plain text). A tab of that title that is already open is used
  ## again, its text replaced — unless it has edits that are not saved: then it comes to the front as it is
  ## (check `b.dirty`). To make saving it do something of yours, give it a language of your own and `onSaveTab`.
  ##
  ##     let b = newTab("Report", lines.join("\n"), "markdown")
  Buf(id: api("newTab", %*{"title": title, "text": text, "lang": lang}).getInt(-1))
proc clipboard*(): string = api("clipboard").getStr
  ## The clipboard's text: what Ctrl+V would paste (the system's clipboard; what was copied in ned when the
  ## system's cannot be read). Needs the "clipboard" permission.
proc setClipboard*(text: string) = discard api("setClipboard", %*{"text": text})
  ## Puts `text` on the clipboard — the system's and ned's own. Needs the "clipboard" permission.
proc buffers*(): seq[Buf] =
  ## Every tab's file, in the order of the tabs: files, unsaved new files and plugins' tabs.
  ##
  ##     for b in buffers():
  ##       if b.dirty: log(b.title & " has changes not saved")
  for x in api("buffers"): result.add Buf(id: x.getInt)
proc valid*(b: Buf): bool = b.id >= 0
  ## True for a file ned has: false for the `Buf` that `current()` or `openFile` give when there is none (id -1).
  ## It asks nothing: a tab closed since still looks valid, and asking about it raises `ValueError`.
proc path*(b: Buf): string = api("path", %*{"buf": b.id}).getStr
  ## The file's path, absolute ("" for a tab that is not a file).
proc lang*(b: Buf): string = api("lang", %*{"buf": b.id}).getStr
  ## Its language's id, lower case: "nim", "python", "markdown", "plaintext" … (a plugin's language has the id
  ## it was registered with). The status bar shows a file's language.
proc copied(b: Buf): bool =
  ## a copy of the buffer's lines that is still its text — made at the second read of the same version
  if b.id notin bufVer: return false
  let v = bufVer[b.id]
  if b.id in bufCopy and bufCopy[b.id][0] == v: return true
  let m = if b.id in bufMiss and bufMiss[b.id][0] == v: bufMiss[b.id][1] + 1 else: 1
  bufMiss[b.id] = (v, m)
  if m < 2: return false
  let r = api("snapshot", %*{"buf": b.id})
  if r{"v"}.getStr != v: return false                 # (it changed meanwhile)
  var ls: seq[string]
  for x in r{"lines"}: ls.add x.getStr
  bufCopy[b.id] = (v, ls)
  true

proc lineCount*(b: Buf): int =
  ## How many lines it has. An empty file has one, empty, line: it is never 0.
  if copied(b): bufCopy[b.id][1].len else: api("lineCount", %*{"buf": b.id}).getInt
proc line*(b: Buf, i: int): string =
  ## Line `i` (from 0) without its line end; "" past the end. Reading a file line by line costs two requests,
  ## not one a line, while it does not change: the plugin keeps a copy of its lines (ned 6.29).
  if copied(b):
    if i >= 0 and i < bufCopy[b.id][1].len: bufCopy[b.id][1][i] else: ""
  else: api("line", %*{"buf": b.id, "line": i}).getStr
proc lines*(b: Buf, first = 0, last = -1): seq[string] =
  ## Lines `first` to `last`, both included (`last` -1, or past the end: to the end), without their line ends —
  ## one request for all of them.
  ##
  ##     for i, l in b.lines:
  ##       if l.len > 100: log("line " & $(i + 1) & " is long")
  if copied(b):
    let n = bufCopy[b.id][1].len
    let f = clamp(first, 0, max(0, n - 1))
    let l = if last < 0 or last > n - 1: n - 1 else: last
    for i in f .. l: result.add bufCopy[b.id][1][i]
  else:
    for x in api("lines", %*{"buf": b.id, "first": first, "last": last}): result.add x.getStr
proc text*(b: Buf): string =
  ## The whole text: its lines joined with "\n".
  if copied(b): bufCopy[b.id][1].join("\n") else: api("text", %*{"buf": b.id}).getStr
proc textIn*(b: Buf, r: Range): string = api("textIn", %*{"buf": b.id, "range": %r}).getStr
  ## The text in the range, its lines joined with "\n". A position past a line's end or the file's end is taken
  ## as that end.
proc setText*(b: Buf, s: string) = discard api("setText", %*{"buf": b.id, "text": s})
  ## Replaces the whole text with `s`. ned changes only the lines that differ, so the cursor, the folds and the
  ## undo stay sensible. One undo step with the plugin's other edits in this call. Raises `ValueError` for a file
  ## that cannot be changed (read-only).
proc replace*(b: Buf, r: Range, s: string) = discard api("replace", %*{"buf": b.id, "range": %r, "text": s})
  ## Replaces the text in `r` with `s` (which may have line ends); an empty range inserts. All the edits a plugin
  ## makes in one callback — a command, an event, a fix, a timer — are one undo step. Positions out of the text
  ## are moved into it. An edit moves the text after it: when making several, go from the last place to the
  ## first. Raises `ValueError` for a file that cannot be changed (read-only).
  ##
  ##     b.replace(b.lineRange(0), "# " & b.line(0))
proc insert*(b: Buf, p: Pos, s: string) = b.replace(rng(p, p), s)
  ## Inserts `s` at `p` (as `replace(rng(p, p), s)`).
proc delete*(b: Buf, r: Range) = b.replace(r, "")
  ## Removes the text in `r` (as `replace(r, "")`).
proc cursor*(b: Buf): Pos = toPos(api("cursor", %*{"buf": b.id}))
  ## Where the cursor is (the main one, with multiple cursors). In vim's normal mode, the character the block
  ## cursor is on starts there.
proc setCursor*(b: Buf, p: Pos) = discard api("setCursor", %*{"buf": b.id, "pos": %p})
  ## Moves the cursor to `p` (into the text when `p` is out of it): one cursor, nothing selected. It does not
  ## bring the file to the front: `openFile(b.path, line, col)` does that.
proc selection*(b: Buf): Range = toRange(api("selection", %*{"buf": b.id}))
  ## The main cursor's selection, from its start to its end whichever way it was made; empty (`start` == `stop`:
  ## the cursor) when nothing is selected. In vim's visual mode the character under the cursor is in it, and in
  ## visual-line mode the whole lines are (without the last one's line end).
  ##
  ##     let r = b.selection
  ##     let s = if r.isEmpty: b.wordAt(r.start) else: b.textIn(r)
proc vimMode*(): string = api("vimMode").getStr
  ## Vim's mode: "normal", "insert", "visual", "visual line" or "replace"; "" when vim keys are off
  ## (`editor.vimMode`).
proc selections*(b: Buf): seq[Range] =
  ## Every cursor's selection — one for each of multiple cursors (one with a single cursor) — as `selection`
  ## gives them. They are not in the file's order: sort them, and edit from the last one to the first, so the
  ## ranges not yet edited stay where they are. ned's *Add cursor below* (Alt+J) and *Add cursor above* (Alt+K)
  ## make more cursors.
  for x in api("selections", %*{"buf": b.id}): result.add toRange(x)
proc select*(b: Buf, r: Range) = discard api("select", %*{"buf": b.id, "range": %r})
  ## Selects `r`: one cursor, at `r.stop`, the selection going back to `r.start`.
proc wordAt*(b: Buf, p: Pos): string = api("wordAt", %*{"buf": b.id, "pos": %p}).getStr
  ## The word at `p` — the letters, digits and _ around it — or "" when there is none.
proc dirty*(b: Buf): bool = api("dirty", %*{"buf": b.id}).getBool
  ## True when it has changes that are not saved.
proc save*(b: Buf) = discard api("save", %*{"buf": b.id})
  ## Writes it to its file, as Ctrl+S does — but without the plugins' save events (`onBeforeSave`, `onSave`), so
  ## a save in an event cannot start another. Saving a file outside the project (and outside the plugin's data
  ## folder) needs the "files" permission.
proc closeTab*(b: Buf) = discard api("closeTab", %*{"buf": b.id})
  ## Closes its tab. A file with changes not saved asks you first (and stays open if you say no); a tab that is
  ## not a file closes without asking.
proc markSaved*(b: Buf) = discard api("markSaved", %*{"buf": b.id})
  ## Counts it as saved: no ● on its tab, no question when it closes. For a tab of the plugin's own, once
  ## `onSaveTab`'s callback has done what saving means for it.
proc title*(b: Buf): string = api("title", %*{"buf": b.id}).getStr
  ## The name on its tab (a file's: its file name).
proc setTitle*(b: Buf, title: string) = discard api("setTitle", %*{"buf": b.id, "title": title})
  ## Renames a tab that is not a file (one of `newTab`'s). Raises `ValueError` for a file's tab: its file names
  ## it.
proc indentUnit*(b: Buf): string = api("indent", %*{"buf": b.id}).getStr
  ## What one level of indentation is in this file: "  ", "    " or "\t" — from the file itself, its language
  ## and your settings.
proc lineComment*(b: Buf): string = api("lineComment", %*{"buf": b.id}).getStr
  ## Its language's line comment ("#", "//", "--"); "" when the language has none.
proc lineRange*(b: Buf, line: int): Range = rng(pos(line, 0), pos(line, b.line(line).len))
  ## Line `line` without its line end, as a Range: from column 0 to the line's length.
  ##
  ##     b.replace(b.lineRange(l), b.line(l).strip(leading = false))   # its trailing spaces gone
proc wholeLines*(b: Buf, first, last: int): Range =
  ## Lines `first` to `last` with their line ends, as a Range: from the start of `first` to the start of the line
  ## after `last` (to the end of the file when `last` is the last line). Deleting it removes the lines — but the
  ## file's last line has no line end of its own, so deleting it alone leaves an empty line: to remove it, start
  ## the range at the end of the line before it.
  ##
  ##     b.delete(b.wholeLines(4, 6))    # lines 5, 6 and 7 gone
  if last + 1 < b.lineCount: rng(pos(first, 0), pos(last + 1, 0))
  else: rng(pos(first, 0), pos(last, b.line(last).len))

# ── keys: what waits, what the next key does (which-key) ──

type
  KeyMap* = object
    ## A key, or keys, that a plugin uses (or your `keys` setting): what `keyMaps` lists, for a box of what can
    ## be typed next.
    mode*: string                ## n v (vim mappings), op (an operator), obj (a text object), key (any keymap)
    keys*: string                ## as given: `<leader>f`, `gc`, `ie`, `ctrl+alt+u`
    desc*: string                ## what it does ("": not said; for a command's key, its title)
    lang*: string                ## only in files of this language ("" every file)
    plugin*: string              ## whose ("" yours)

proc pendingKeys*(): tuple[keys, mode: string] =
  ## The keys typed that wait for more ("" when none waits) and the mode, as `onKeysWaiting` gives them: "n"
  ## (vim's normal mode), "v" (visual), "o" (an operator waits for its motion: "d", "gc"), "obj" (… for its text
  ## object, after i or a: "di"), "emacs" or "helix". The keys are written as vim writes them — `g`, `<leader>f`,
  ## `<C-a>` — and emacs's as `C-x`. ("", "") while a prompt or a list is open.
  let j = api("pendingKeys")
  (j{"keys"}.getStr, j{"mode"}.getStr)
proc showKeyHints*(title: string, hints: openArray[(string, string)]): bool =
  ## Shows a box above the status bar, titled `title`, with each key of `hints` and what it does: the keys that
  ## may come next. ned closes it when the keys waiting change (one is typed, Esc); tapping a key in it types it.
  ## Returns false, and shows nothing, when no keys wait now.
  ##
  ##     onKeysWaiting(300) do (keys, mode: string):
  ##       if keys == "<leader>":
  ##         discard showKeyHints("leader", [("f", "find a file"), ("g", "git")])
  var arr = newJArray()
  for (k, d) in hints: arr.add %*[k, d]
  api("showKeyHints", %*{"title": title, "hints": arr}).getBool
proc hideKeyHints*() = discard api("hideKeyHints")
  ## Closes the box of `showKeyHints` (ned closes it by itself when the keys waiting change).
proc keyMaps*(): seq[KeyMap] =
  ## Every key the plugins use — vim mappings, operators, text objects, `keyIn`'s keys, commands' keys — and the
  ## commands on keys in your `keys` setting, each with what it does: what a which-key box lists.
  for x in api("keyMaps"):
    result.add KeyMap(mode: x{"mode"}.getStr, keys: x{"keys"}.getStr, desc: x{"desc"}.getStr,
                      lang: x{"lang"}.getStr, plugin: x{"plugin"}.getStr)

# ── talking to you ──

proc message*(s: string) = discard api("message", %*{"text": s})
  ## Shows `s` in the status line, until the next message.
proc warn*(s: string) = discard api("message", %*{"text": s, "level": "warn"})
  ## Shows `s` in the status line as a warning, in the warning colour.
proc toast*(s: string) = discard api("toast", %*{"text": s})
  ## Shows a note in a corner of the screen that goes away by itself after a few seconds — for something that
  ## ended in the background, or a reminder.
proc pick*(title: string, items: openArray[string], details: openArray[string] = []): int =
  ## Shows a list to choose from, titled `title`, and waits until you choose: the index of the item chosen (from
  ## 0), or -1 when you cancel (Esc). `details`: dimmer text beside each item (one for each item, or none). The
  ## plugin waits meanwhile; ned does not. While ned waits for the plugin (an `onBeforeSave` event, a NimScript
  ## formatter, a text object, code actions), or while another plugin asks you something, it returns -1 at once.
  ##
  ##     let i = pick("Which case?", ["UPPER", "lower", "Title"])
  ##     if i >= 0: message("you chose " & $i)
  api("pick", %*{"title": title, "items": @items, "details": @details}).getInt(-1)
proc ask*(prompt: string, default = ""): string =
  ## Asks for a line of text: a prompt with `default` typed in it, waiting for Enter. Returns what you typed, or
  ## "" when you cancel — and "" at once while ned waits for the plugin, as `pick` does.
  ##
  ##     let name = ask("New name:", b.wordAt(b.cursor))
  api("ask", %*{"prompt": prompt, "default": default}).getStr
proc confirm*(question: string): bool = api("confirm", %*{"text": question}).getBool
  ## Asks a yes / no question ("… (y/n)"): true when you answer y. Returns false at once while ned waits for the
  ## plugin, as `pick` does.
proc runCommand*(name: string) = discard api("runCommand", %*{"name": name})
  ## Runs a command of ned's palette by its name, as you would: "Save", "Format document", "Add cursor below" …
  ## (every name is in docs/reference/commands.md; the plugins' commands are there too). Nothing happens for a
  ## name ned does not have. A command that runs programs or changes settings — one with run, build, test,
  ## terminal, git, format, setting … in its name — needs the "shell" permission.

proc shell*(cmd: string, dir = ""): tuple[output: string, code: int] =
  ## Runs `cmd` with the shell in `dir` (else the project's folder) and waits for it: its output — standard output
  ## and error together, without the line end at its end — and its exit code. Needs the "shell" permission
  ## (`ValueError` without it). The plugin's process waits until the command ends, and so do the other plugins in
  ## that process: use `shellAsync` for anything slow. Put a path in a command with `quoteShell`.
  ##
  ##     let (o, code) = shell("git rev-parse --abbrev-ref HEAD")
  ##     if code == 0: status("⎇ " & o)
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
  ## Runs `cmd` in the background — in `dir`, else the project's folder — and calls `cb` with its output
  ## (standard output and error, without the line end at its end) and its exit code when it ends. The plugin goes
  ## on meanwhile (`shell` waits): a build, a request, anything slow. `cb` is a call of ned's like a command: its
  ## edits are one undo step. Needs the "shell" permission (`ValueError` without it). When the plugin's process
  ## stops before the command ends, `cb` is not called.
  ##
  ##     shellAsync("git fetch --quiet") do (output: string, code: int):
  ##       toast(if code == 0: "fetched" else: "git fetch: " & output)
  let f = cb
  callbacks.add proc(a: JsonNode): JsonNode =
    f(a{"output"}.getStr, a{"code"}.getInt)
    newJNull()
  cbOwner.add curPlugin
  discard api("shellAsync", %*{"cmd": cmd, "dir": dir, "cb": callbacks.high})

type RegexMatch* = object
  ## One match of `regexMatches`: where it is in the text, in bytes, and where each of its groups is.
  start*, stop*: int             ## the match: `text[start ..< stop]` (byte offsets; stop not in it)
  groups*: seq[(int, int)]       ## each group's (start, stop), from group 1; (-1, -1) for a group that matched nothing

proc regexMatches*(pattern, text: string, ignoreCase = false, limit = 10000): seq[RegexMatch] =
  ## Every match of `pattern` in `text` (`limit` at most, up to 100000), by ned's own regular expressions — its
  ## search's: `.` `[a-z]` `\d` `\w` `\s` `\b` `*` `+` `?` `{n,m}`, lazy `*?`, groups `(…)` `(?:…)`, `|`, `^`
  ## `$`. With `ignoreCase`, upper and lower case match each other. Raises `ValueError` with ned's words for a
  ## pattern that is not one. NimScript has no regular expressions of its own: this is one request to ned.
  ##
  ##     for m in regexMatches(r"(\w+)@(\w+)\.org", text):
  ##       let (a, e) = m.groups[0]
  ##       log("a name: " & text[a ..< e])
  let r = api("regexFind", %*{"pattern": pattern, "text": text, "ignoreCase": ignoreCase, "limit": limit})
  for m in r:
    var g: seq[(int, int)]
    for x in m{"groups"}: g.add (x[0].getInt, x[1].getInt)
    result.add RegexMatch(start: m{"start"}.getInt, stop: m{"stop"}.getInt, groups: g)

proc regexReplace*(pattern, text, replacement: string, ignoreCase = false): tuple[text: string, count: int] =
  ## `text` with each match of `pattern` replaced by `replacement`, and how many matches there were. In
  ## `replacement`, $0 is the match, $1 … $9 and ${12} its groups, \n and \t a line end and a tab. Raises
  ## `ValueError` for a pattern that is not a regular expression.
  ##
  ##     let (t, n) = regexReplace(r"(\d+)-(\d+)", "pages 3-7", "$1 to $2")   # ("pages 3 to 7", 1)
  let r = api("regexReplace", %*{"pattern": pattern, "text": text, "with": replacement, "ignoreCase": ignoreCase})
  (r{"text"}.getStr, r{"count"}.getInt)

proc unixTime*(): float = api("unixTime").getFloat
  ## Now, in seconds since 1970 (UTC), with fractions — ned's clock: NimScript has none of its own. For how long
  ## something took, or since when.
proc localTime*(): string = api("localTime").getStr
  ## Now on your clock, as "2026-10-24 14:03:05" (year-month-day hours:minutes:seconds): `localTime()[0 ..< 10]`
  ## is today's date.

# ── problems, signs, text after a line, highlights, the status bar ──

proc setProblems*(b: Buf, problems: openArray[Problem]) =
  ## Sets this plugin's problems in the file: the ones it set there before go; other plugins' and ned's stay.
  ## They are underlined, listed in the Problems panel and marked in the gutter, and Alt+Enter on a problem's line
  ## offers its fixes. All of them go in one request. They stay where they were put while the text changes: set
  ## them again after a change (`onChange`).
  ##
  ##     b.setProblems([Problem(range: b.lineRange(3), severity: 2, message: "a long line")])
  var a = newJArray()
  for p in problems: a.add %p
  discard api("problems", %*{"buf": b.id, "problems": a})
proc clearProblems*(b: Buf) = b.setProblems([])
  ## Removes this plugin's problems in the file.
proc sign*(b: Buf, line: int, text: string, color = "accent") =
  ## Puts a mark in the gutter beside line `line`: one character, the first of `text` ("" gives •). `color`:
  ## error, warn, info, hint, accent, add, del, mod, guide, or "#rrggbb". One sign shows on a line (the first one
  ## set there). A plugin's signs, texts after lines and highlights are its own: `clearDecorations` removes them.
  ## They stay on their line numbers while the text changes (set them again in `onChange`), and go when the tab
  ## closes. Each one is a request: for many lines, `setProblems` (one request) may suit better.
  ##
  ##     b.sign(12, "●", "warn")
  discard api("sign", %*{"buf": b.id, "line": line, "text": text, "color": color})
proc virtualText*(b: Buf, line: int, text: string, color = "hint") =
  ## Shows `text` after the end of line `line`, in `color` (as `sign`'s). It is not in the file: the cursor does
  ## not go there and saving does not write it. Several on one line show one after the other.
  ##
  ##     b.virtualText(3, "← 3 ms", "hint")
  discard api("vtext", %*{"buf": b.id, "line": line, "text": text, "color": color})
proc highlight*(b: Buf, r: Range, color = "accent") =
  ## Tints the background of the text in `r` — over several lines too — with `color` (as `sign`'s).
  discard api("highlight", %*{"buf": b.id, "range": %r, "color": color})
proc clearDecorations*(b: Buf) = discard api("clearDecorations", %*{"buf": b.id})
  ## Removes this plugin's signs, texts after lines and highlights in the file; other plugins' stay.
proc status*(text: string) = discard api("status", %*{"text": text})
  ## Sets this plugin's item in the status bar to `text`; "" removes it. One item for each plugin: each call
  ## replaces the last. While a plugin's item shows, its process is not stopped for being idle.
  ##
  ##     status("✎ 3 notes")

type IndentStyle* = object
  ## How the indentation of each line looks — dots in its spaces, a mark for tabs, a colour for each level, a
  ## band where it is wrong. A plugin gives it once with `indentStyle`, and ned draws it as it draws each line:
  ## nothing is sent for each line, so a big file costs no more than a small one (ned 6.29). Each mark is one
  ## character.
  ##
  ##     indentStyle(IndentStyle(dot: "·", levels: @["warn", "add", "info", "accent"], wrongColor: "error"))
  dot*: string                   ## a mark in each space of the indentation, up to the first letter ("·"; "": none)
  dotColor*: string              ## its colour: guide (the default), hint, accent, info, warn, add, del, error or "#rrggbb"
  tab*: string                   ## a mark at the first column of a tab in the indentation ("→"; "": none)
  blankLines*: bool              ## a blank line's indentation too: as deep as the code around it
  lineEnd*: string               ## a mark after the end of each line ("¬"; "": none)
  levels*: seq[string]           ## a colour for each level of indentation, round again after the last (as dotColor)
  levelStyle*: string            ## how the levels show: "background" (bands: the default), "guides" (the │ of each
                                 ## level in its colour) or "dots" (the dots in it)
  wrongColor*: string            ## indentation that is not whole levels (3 spaces where a level is 2): its band
                                 ## ("": not marked)
  langs*: seq[string]            ## only in these languages ("nim", "python" …; empty: every file)

proc indentStyle*(s: IndentStyle) =
  ## Sets this plugin's look for indentation. One for each plugin: a new one takes the place of the last, and
  ## `indentStyle(IndentStyle())` takes it away. When several plugins give one, the first plugin's dot, tab mark,
  ## line-end mark and level colours each win. Selections, search matches and highlights keep their own colours;
  ## it is not drawn in diffs, nor with `ui.accessible` on.
  var lv = newJArray()
  for c in s.levels: lv.add %c
  var ls = newJArray()
  for l in s.langs: ls.add %l
  discard api("indentStyle", %*{"dot": s.dot, "dotColor": s.dotColor, "tab": s.tab, "blankLines": s.blankLines,
                                "lineEnd": s.lineEnd, "levels": lv, "levelStyle": s.levelStyle,
                                "wrongColor": s.wrongColor, "langs": ls})

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
  ## (what `setting` uses) the setting's value when it is a string, else `default`
func settingOr*(v: JsonNode, default: int): int = (if v == nil or v.kind != JInt: default else: v.getInt)
  ## (what `setting` uses) the setting's value when it is a whole number, else `default`
func settingOr*(v: JsonNode, default: bool): bool = (if v == nil or v.kind != JBool: default else: v.getBool)
  ## (what `setting` uses) the setting's value when it is true or false, else `default`
func settingOr*(v: JsonNode, default: float): float =
  ## (what `setting` uses) the setting's value when it is a number, else `default`
  if v == nil or v.kind notin {JFloat, JInt}: default else: v.getFloat
template setting*(key: string, default: string): string =
  ## Reads the setting `plugins.<this plugin>.<key>` from your settings: its value, or `default` when it is not set
  ## or is not a string. It works in the plugin's top-level code too. Your settings may write it flat
  ## (`"plugins.notes.markers": "TODO FIXME"`) or in an object (`"plugins": {"notes": {"markers": "…"}}`). Read
  ## it where you use it: a change of the setting then applies at the next call, without a reload. `settingDef`
  ## shows it in the Settings panel.
  ##
  ##     let markers = setting("markers", "TODO FIXME").splitWhitespace
  settingOr(settingIn(settingPlugin(instantiationInfo(-1, true).filename), key), default)
template setting*(key: string, default: int): int =
  ## Reads `plugins.<this plugin>.<key>` as a whole number: `default` when it is not set or is not one.
  ##
  ##     let width = setting("width", 100)
  settingOr(settingIn(settingPlugin(instantiationInfo(-1, true).filename), key), default)
template setting*(key: string, default: bool): bool =
  ## Reads `plugins.<this plugin>.<key>` as true or false: `default` when it is not set or is neither.
  settingOr(settingIn(settingPlugin(instantiationInfo(-1, true).filename), key), default)
template setting*(key: string, default: float): float =
  ## Reads `plugins.<this plugin>.<key>` as a number (a whole number is taken too): `default` when it is not set or
  ## is not one.
  settingOr(settingIn(settingPlugin(instantiationInfo(-1, true).filename), key), default)
proc projectRoot*(): string = api("root").getStr
  ## The project's folder — what the file tree shows — as an absolute path. The plugin's process runs elsewhere
  ## (in ned's plugins folder), so a relative path in `readFile` means nothing: `projectRoot() / "src/app.nim"`
  ## does. `shell` and `shellAsync` run here unless told otherwise, and `openFile` and `runInTerminal` take
  ## paths relative to it.
proc projectDir*(): string = api("root").getStr
  ## The same as `projectRoot`. In a plugin.nims write `nedplugin.projectDir()`, or use `projectRoot`: NimScript
  ## has a `projectDir` of its own (the script's folder).
proc dataDir*(): string = api("dataDir").getStr
  ## A folder of this plugin's own — `~/.local/share/ned/plugins/<plugin>/` (under `$XDG_DATA_HOME` when it is
  ## set) — made when asked for. `writeData`, `appendData` and `readData` use it with no permission; a plugin
  ## that uses `writeFile` asks for "files", even to write here.
proc readData*(name: string): string = api("dataRead", %*{"name": name}).getStr
  ## The text of a file of this plugin's data folder, or "" when there is none. `name` is relative to
  ## `dataDir()` — "lists.json", "2026-10/day.log"; a name that is absolute, has "..", ends in "/" or is over 200
  ## bytes raises `ValueError`.
  ##
  ##     let state = (try: parseJson(readData("state.json")) except CatchableError: newJObject())
proc writeData*(name, text: string) = discard api("dataWrite", %*{"name": name, "text": text})
  ## Writes `text` to a file of this plugin's data folder, in place of what it had, making its folders. It needs
  ## no permission, unlike `writeFile`. `name` as for `readData`; at most 64 MB in one call.
  ##
  ##     writeData("state.json", $(%*{"open": true}))
proc appendData*(name, text: string) = discard api("dataWrite", %*{"name": name, "text": text, "append": true})
  ## Adds `text` at the end of a file of this plugin's data folder (made when there is none): a log. It needs no
  ## permission.
  ##
  ##     appendData("saves.log", localTime() & " " & ev.path & "\n")
proc permission*(what, why: string) = discard
  ## Says what this plugin needs beyond editing, and why. `what` is one of:
  ##
  ## - "shell": run programs — `shell`, `shellAsync`, `runInTerminal`, a command of ned's that runs programs
  ##   (`runCommand`), NimScript's `exec` and `gorgeEx`, std/osproc
  ## - "files": change files — `writeFile`, `mkDir`, `mvFile`, `rmFile`, `removeFile` …, saving a file outside
  ##   the project (its own data needs none: `writeData`)
  ## - "clipboard": `clipboard` and `setClipboard`
  ## - "network": a plugin in full Nim's sockets (std/net, std/httpclient …)
  ##
  ## `why` is what ned shows you when it asks. ned reads these lines, and what the source uses, before the plugin
  ## runs, and asks you once; a call that was not allowed raises `ValueError`. Nothing happens when this runs:
  ## write it in the top-level code, on one line, with two plain strings. Code ned cannot read ahead
  ## (`{.importc.}`, `{.emit.}`, a module from outside the plugin's folder) counts as asking for everything.
  ##
  ##     permission("shell", "runs git to show who changed the line")
proc allowed*(what: string): bool = api("allowed", %*{"what": what}).getBool
  ## True when you allowed this plugin `what`: "shell", "network", "files" or "clipboard" (false for any other
  ## word). For a kinder word than the error when it was not allowed.
proc pluginDir*(): string = api("pluginDir").getStr
  ## The plugin's own folder, where its plugin.nims or plugin.nim is: for files that come with it
  ## (`readFile(pluginDir() / "words.txt")`).
proc log*(s: string) = discard api("log", %*{"text": s})
  ## Writes `s` as a line of the plugin's log (the Plugins dock); `echo` writes there too. A line over 400 bytes
  ## is cut, and the dock keeps the last few hundred lines.

# ── registering: what the top-level code of a plugin does ──

proc regCommand*(file, title, keys: string, cb: proc()) =
  ## (what `command` uses: call `command`)
  let f = cb
  discard register(file, "command", %*{"title": title, "keys": keys}, proc(a: JsonNode): JsonNode =
    f()
    newJNull())

template command*(title: string, body: untyped) =
  ## A command: `title` is its name in the palette (Ctrl+E), in the Plugins dock under the plugin and in
  ## *Plugins: run a plugin's command…* — when ned has a command of that name, the plugin's is called
  ## `<plugin>: <title>`. `body` runs each time it is chosen, as one call of ned's: its edits are one undo step.
  ## It cannot `return` (it is a template's body): put the work in a proc and call it.
  ##
  ##     command "Line count":
  ##       message($current().lineCount & " lines")
  regCommand(instantiationInfo(-1, true).filename, title, "", proc() = body)
template command*(title, keys: string, body: untyped) =
  ## A command on a key too: "ctrl+alt+u", "alt+shift+k", "f9" — ctrl, alt and shift in any order, case does
  ## not matter. Your `keys` setting wins over a plugin's key, and a plugin's key over ned's own use of it. Not
  ## every terminal passes every combination: the palette always works.
  ##
  ##     command "Upper-case the line", "ctrl+alt+u":
  ##       let b = current()
  ##       let l = b.cursor.line
  ##       b.replace(b.lineRange(l), b.line(l).toUpperAscii)
  regCommand(instantiationInfo(-1, true).filename, title, keys, proc() = body)

proc regEvent*(file, kind, pattern: string, cb: proc(ev: Event)) =
  ## (what onOpen, onSave … use: call those)
  let f = cb
  discard register(file, "event", %*{"event": kind, "pattern": pattern}, proc(a: JsonNode): JsonNode =
    f(toEvent(a))
    newJNull())

template onStartup*(cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "startup", "*", cb)
  ## Calls `cb` once, when ned has started and the plugin runs (a plugin with this event starts with ned).
  ## `ev.buf` is the tab in front. For reading what the plugin keeps (`readData`) or giving an `indentStyle`.
  ##
  ##     onStartup do (ev: Event):
  ##       log("ned started with " & ev.path)
template onOpen*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "open", pattern, cb)
  ## Calls `cb` when a file matching `pattern` is opened, and for the files open when ned starts. ned does not
  ## wait for it.
  ##
  ## The patterns of every event: `"*"` is every file (and tabs that are not files); `"*.md"` matches the file's
  ## name; one with a / (`"src/*.nim"`) its path in the project; `"lang:zig"` its language; several go with
  ## commas: `"*.md,*.txt"`. A tab that is not a file matches only `"*"` and `"lang:…"`. Several callbacks for one
  ## event — in one plugin or in several — all run, in the order they were registered (ned 6.24).
  ##
  ##     onOpen("*.md") do (ev: Event):
  ##       status($ev.buf.lineCount & " lines")
template onBeforeSave*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "beforeSave", pattern, cb)
  ## Calls `cb` when a file matching `pattern` is about to be written, and waits for it (`plugins.timeoutMs`,
  ## 1500 ms): what it changes in the file is saved. For what belongs in the saved file — trailing spaces gone, a
  ## date, a header. Not called for a save the plugin asks for itself (`b.save`), nor while the plugins are
  ## starting (ned saves without them, and says so). While ned waits, `pick`, `ask` and `confirm` answer at once.
  ##
  ##     onBeforeSave("*.txt") do (ev: Event):
  ##       let t = ev.buf.text
  ##       if t.endsWith(" "): ev.buf.setText(t.strip(leading = false))
template onSave*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "save", pattern, cb)
  ## Calls `cb` after a file matching `pattern` was written; ned does not wait. Not called for `b.save()`.
template onClose*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "close", pattern, cb)
  ## Calls `cb` when the tab of a file matching `pattern` was closed. The tab may be gone when it runs: `ev.path`
  ## and `ev.lang` say which it was, and asking about `ev.buf` may raise `ValueError`. Its signs, texts and
  ## highlights go with it.
template onChange*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "change", pattern, cb)
  ## Calls `cb` when the text of a file matching `pattern` has changed — after a pause in the typing (about 0.4
  ## s), not at every key; once for each file that changed. For what follows the text: problems, signs, a count.
template onEnter*(pattern: string, cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "enter", pattern, cb)
  ## Calls `cb` when a tab matching `pattern` comes to the front: you switched to it, opened it, or closed the
  ## one before it.
template onQuit*(cb: proc(ev: Event)) = regEvent(instantiationInfo(-1, true).filename, "quit", "*", cb)
  ## Calls `cb` when ned quits, and waits a moment for it (1.5 s at most): write what the plugin keeps now.
  ## `ev.buf` is not set. Only when the plugin's process is running.
  ##
  ##     onQuit do (ev: Event):
  ##       writeData("state.json", $state)
template autocmd*(event, pattern: string, cb: proc(ev: Event)) =
  ## The events by vim's names: BufRead, BufReadPost, BufNewFile and FileType are `onOpen`; BufEnter and
  ## BufWinEnter `onEnter`; BufWritePre `onBeforeSave`; BufWritePost `onSave`; BufDelete, BufUnload and
  ## BufWipeout `onClose`; TextChanged and TextChangedI `onChange`; VimEnter `onStartup`; VimLeave and VimLeavePre
  ## `onQuit`. With FileType the pattern is a language id ("markdown" is taken as "lang:markdown").
  ##
  ##     autocmd("BufWritePost", "*.nim") do (ev: Event):
  ##       log("saved " & ev.path)
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
  ## Registers a language: a new one — `id` its id, lower case ("zig") — or changes to one ned has (its id:
  ## "python"). See `LangSpec` for the fields. The open files of it are coloured again. Your `languages` setting
  ## wins over a plugin's, field by field.
  ##
  ##     language("zig", LangSpec(name: "Zig", extensions: @["zig"], lineComment: "//",
  ##                              keywords: @["fn", "const", "var", "return"], indentSize: 4))
  regLanguage(instantiationInfo(-1, true).filename, id, spec)

proc regFiletype*(file, lang: string, indentSize: int, tabs: int, lineComment: string) =
  ## (what `filetype` uses: call `filetype`)
  var j = newJObject()
  if indentSize > 0: j["indentSize"] = %indentSize
  if tabs >= 0: j["tabs"] = %(tabs == 1)
  if lineComment.len > 0: j["lineComment"] = %lineComment
  discard register(file, "language", %*{"id": lang, "spec": j})
template filetype*(lang: string, indentSize = 0, tabs = -1, lineComment = "") =
  ## Changes a few settings of a language's files: `indentSize` (spaces to a level; 0: as it is), `tabs` (1 tabs,
  ## 0 spaces, -1 as it is) and `lineComment` ("": as it is).
  ##
  ##     filetype("makefile", tabs = 1)
  ##     filetype("python", indentSize = 4)
  regFiletype(instantiationInfo(-1, true).filename, lang, indentSize, tabs, lineComment)

proc regFormatterCmd*(file, lang, cmd: string) = discard register(file, "formatter", %*{"lang": lang, "cmd": cmd})
  ## (what `formatter` with a command uses: call `formatter`)
proc regFormatter*(file, lang: string, f: proc(text: string): string) =
  ## (what `formatter` with a proc uses: call `formatter`)
  let ff = f
  discard register(file, "formatter", %*{"lang": lang}, proc(a: JsonNode): JsonNode = %ff(a{"text"}.getStr))
template formatter*(lang: string, cmd: string) =
  ## A formatter command for the language's files (`lang`: its id): the text on its standard input, the formatted
  ## text on its standard output. It runs in the file's folder; $file, $dir, $name, $root and $tmp in it are
  ## replaced (with $in and $out in it, the text goes through those two files instead). Alt+F and format on save
  ## use it when its program is on PATH, else the language's own formatter. Your `formatters` setting wins over
  ## it. Not for Nim files: `nim.formatter` decides those.
  ##
  ##     formatter("shellscript", "shfmt -i 2")
  regFormatterCmd(instantiationInfo(-1, true).filename, lang, cmd)
template formatter*(lang: string, f: proc(text: string): string) =
  ## A formatter written in Nim: `f` gets the whole text (ending in a line end) and returns it formatted; the
  ## text unchanged (or "") says it is formatted already. Raise `ValueError` to say why it cannot: the message
  ## shows in the status line. ned waits for it — 3 s, or `plugins.timeoutMs` when that is longer. A formatter
  ## command for the language wins over it.
  ##
  ##     formatter("plaintext") do (text: string) -> string:
  ##       for l in text.strip(leading = false).splitLines: result.add l.strip(leading = false) & "\n"
  regFormatter(instantiationInfo(-1, true).filename, lang, f)

proc regLsp*(file, lang: string, cmd: seq[string], script: string, afterSave = false) =
  ## (what languageServer and languageServerScript use: call those)
  discard register(file, "lsp", %*{"lang": lang, "cmd": cmd, "script": script, "afterSave": afterSave})
template languageServer*(lang: string, cmd: seq[string], afterSave = false) =
  ## A language server for the language's files: `cmd` is the program and its arguments (@["zls"],
  ## @["pyright-langserver", "--stdio"]). ned starts it for the files of the language and speaks the Language
  ## Server Protocol with it as with the servers it knows: completion, hover, go to definition, problems, renames
  ## … Your `lsp` setting wins over it. With `afterSave`, it starts when one of those files is first saved, not
  ## when one is opened — for a server that takes long to start (Julia's): reading files then costs nothing (ned
  ## 6.28).
  ##
  ##     if findExe("zls").len > 0: languageServer("zig", @["zls"])
  regLsp(instantiationInfo(-1, true).filename, lang, cmd, "", afterSave)
template languageServerScript*(lang, script: string, afterSave = false) =
  ## A language server written in NimScript with `nedlsp` (see that module below): `script` is its file,
  ## relative to the plugin's folder (or absolute). ned runs it as `ned --lsp-bridge <script>`, which gives it the
  ## protocol's framing — the same command is the server for other editors. `afterSave` as for `languageServer`.
  ##
  ##     languageServerScript("markdown", "server.nims")
  regLsp(instantiationInfo(-1, true).filename, lang, @[], script, afterSave)

# ── vim (editor.vimMode) ──

proc regVimMap*(file, mode, keys: string, cb: proc(count: int), desc = "", lang = "") =
  ## (what nmap and vmap use: call those)
  let f = cb
  discard register(file, "vimMap", %*{"mode": mode, "keys": keys, "desc": desc, "lang": lang}, proc(a: JsonNode): JsonNode =
    f(a{"count"}.getInt(1))
    newJNull())
template nmap*(keys: string, cb: proc(count: int)) =
  ## A vim normal-mode mapping (`editor.vimMode` on): typing `keys` calls `cb` with the count typed before them
  ## (2 for `2gx`; 1 when none was typed). In `keys`, `<leader>` is the space bar, `<CR>` Enter, `<Tab>` Tab, and
  ## `<C-a>` … `<C-z>` Ctrl and a letter. A plugin's mapping comes before vim's own use of the keys; while its
  ## first keys are typed, ned waits for the rest (`onKeysWaiting` can show what may follow).
  ##
  ##     nmap("<leader>w") do (count: int):
  ##       runCommand("Save")
  regVimMap(instantiationInfo(-1, true).filename, "n", keys, cb)
template nmap*(keys, desc: string, cb: proc(count: int)) =
  ## A normal-mode mapping with what it does, in a few words: which-key (and `keyMaps`) show it.
  ##
  ##     nmap("]t", "the next TODO") do (count: int):
  ##       message("down " & $count)
  regVimMap(instantiationInfo(-1, true).filename, "n", keys, cb, desc)
template nmapIn*(lang, keys, desc: string, cb: proc(count: int)) =
  ## A normal-mode mapping only in files (and tabs) of one language (`lang`: its id, "markdown", "oil" …). It
  ## comes before a mapping of the same keys for every file, and before vim's own.
  regVimMap(instantiationInfo(-1, true).filename, "n", keys, cb, desc, lang)
template vmap*(keys: string, cb: proc(count: int)) =
  ## A vim visual-mode mapping: typing `keys` with a selection calls `cb` (`current().selection` is the
  ## selection, the character under the cursor in it). When it is done, ned goes back to normal mode at the
  ## selection's start — unless it selected something itself (`select`).
  regVimMap(instantiationInfo(-1, true).filename, "v", keys, cb)
template vmap*(keys, desc: string, cb: proc(count: int)) =
  ## A visual-mode mapping with what it does, in a few words (which-key shows it).
  ##
  ##     vmap("<leader>u", "upper-case it") do (count: int):
  ##       let b = current()
  ##       let r = b.selection
  ##       b.replace(r, b.textIn(r).toUpperAscii)
  regVimMap(instantiationInfo(-1, true).filename, "v", keys, cb, desc)
template vmapIn*(lang, keys, desc: string, cb: proc(count: int)) =
  ## A visual-mode mapping only in files (and tabs) of one language.
  regVimMap(instantiationInfo(-1, true).filename, "v", keys, cb, desc, lang)

proc regLangKey*(file, lang, keys, desc: string, cb: proc(b: Buf)) =
  ## (what keyIn uses: call keyIn)
  let f = cb
  discard register(file, "langKey", %*{"lang": lang, "keys": keys, "desc": desc}, proc(a: JsonNode): JsonNode =
    f(Buf(id: a{"buf"}.getInt))
    newJNull())
template keyIn*(lang, keys, desc: string, cb: proc(b: Buf)) =
  ## A key ("alt+enter", "ctrl+alt+o") only in files (and tabs) of one language, in every keymap: `cb` gets the
  ## file. It comes before ned's own use of the key there; your `keys` setting wins over it. For a plugin's own
  ## kind of tab — oil's folder view opens what is under the cursor on Alt+Enter.
  ##
  ##     keyIn("scratch", "alt+enter", "tick the line") do (b: Buf):
  ##       message("line " & $(b.cursor.line + 1))
  regLangKey(instantiationInfo(-1, true).filename, lang, keys, desc, cb)

proc regSaveTab*(file, lang: string, cb: proc(ev: Event)) =
  ## (what onSaveTab uses: call onSaveTab)
  let f = cb
  discard register(file, "writer", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    f(toEvent(a))
    newJNull())
template onSaveTab*(lang: string, cb: proc(ev: Event)) =
  ## Makes saving a tab of this language that is not a file (one of `newTab`'s) the plugin's: Ctrl+S (or :w)
  ## calls `cb` with it instead of asking for a file name. `cb` does what saving means — writes the plugin's data,
  ## renames files (oil's folder view) … — then `ev.buf.markSaved()`. One plugin for each language: give the
  ## plugin's tabs a language of its own (`language`).
  ##
  ##     onSaveTab("scratch") do (ev: Event):
  ##       writeData("scratch.md", ev.buf.text)
  ##       ev.buf.markSaved()
  regSaveTab(instantiationInfo(-1, true).filename, lang, cb)

proc regKeysWaiting*(file: string, ms: int, cb: proc(keys, mode: string)) =
  ## (what onKeysWaiting uses: call onKeysWaiting)
  let f = cb
  discard register(file, "event", %*{"event": "keys", "pattern": $max(0, ms)}, proc(a: JsonNode): JsonNode =
    f(a{"keys"}.getStr, a{"mode"}.getStr)
    newJNull())
template onKeysWaiting*(ms: int, cb: proc(keys, mode: string)) =
  ## Calls `cb` when keys typed have waited `ms` milliseconds for more — vim's `g`, `z`, `d`, a plugin's
  ## `<leader>`, emacs's `C-x`, helix's `<space>` — with the keys (as `pendingKeys` writes them) and the mode: "n"
  ## (vim's normal mode), "v" (visual), "o" (an operator waits for its motion), "obj" (… for its text object,
  ## after i or a: "di"), "emacs" or "helix". Once for each wait. For a box of what may follow (`showKeyHints`,
  ## `keyMaps`).
  regKeysWaiting(instantiationInfo(-1, true).filename, ms, cb)

proc regEx*(file, name: string, cb: proc(args: string)) =
  ## (what exCommand uses: call exCommand)
  let f = cb
  discard register(file, "ex", %*{"name": name}, proc(a: JsonNode): JsonNode =
    f(a{"args"}.getStr)
    newJNull())
template exCommand*(name: string, cb: proc(args: string)) =
  ## A `:` command of vim mode: `:Name args` calls `cb` with what follows the name, stripped ("" for none). Its
  ## name starts with a capital letter, as vim's user commands do (ned leaves out one that does not, and says so
  ## in the plugin's log): ned's own — `:w`, `:q`, `:s` — stay ned's.
  ##
  ##     exCommand("Lines") do (args: string):
  ##       message($current().lineCount & " lines")
  regEx(instantiationInfo(-1, true).filename, name, cb)

proc regOperator*(file, keys: string, cb: proc(b: Buf, r: Range, linewise: bool), desc = "") =
  ## (what `operator` uses: call `operator`)
  let f = cb
  discard register(file, "operator", %*{"keys": keys, "desc": desc}, proc(a: JsonNode): JsonNode =
    f(Buf(id: a{"buf"}.getInt), toRange(a{"range"}), a{"linewise"}.getBool)
    newJNull())
template operator*(keys: string, cb: proc(b: Buf, r: Range, linewise: bool)) =
  ## A vim operator, as `d` or `gc` are: `keys` then a motion or a text object (`gcip`, `gc3j`), the keys' last
  ## letter again for lines (`gcc`; `3gcc` three lines), or `keys` on a visual selection. `cb` gets the file, the
  ## range covered, and whether it is whole lines — then the range goes from the first line's start to the last
  ## line's end, without its line end.
  ##
  ##     operator("gU") do (b: Buf, r: Range, linewise: bool):
  ##       b.replace(r, b.textIn(r).toUpperAscii)
  regOperator(instantiationInfo(-1, true).filename, keys, cb)
template operator*(keys, desc: string, cb: proc(b: Buf, r: Range, linewise: bool)) =
  ## An operator with what it does, in a few words (which-key shows it).
  regOperator(instantiationInfo(-1, true).filename, keys, cb, desc)

proc regTextObject*(file, keys: string, cb: proc(b: Buf, p: Pos): Range, desc = "") =
  ## (what textObject uses: call textObject)
  let f = cb
  discard register(file, "textObject", %*{"keys": keys, "desc": desc}, proc(a: JsonNode): JsonNode =
    %f(Buf(id: a{"buf"}.getInt), toPos(a{"pos"})))
template textObject*(keys: string, cb: proc(b: Buf, p: Pos): Range) =
  ## A vim text object of two keys, i or a and a letter ("ie", "al"): `cb` gets the file and the cursor and
  ## returns the range the object covers there, or `noRange()` when there is none. It works after an operator
  ## (vim's d c y …, a plugin's) and in visual mode. ned waits for it (`plugins.timeoutMs`). A range from a
  ## line's start to the start of a later line (or the file's end) counts as whole lines. A plugin's text object
  ## comes before ned's own of the same keys.
  ##
  ##     textObject("ie") do (b: Buf, p: Pos) -> Range:     # the whole text: yie, die, vie
  ##       rng(pos(0, 0), pos(b.lineCount - 1, b.line(b.lineCount - 1).len))
  regTextObject(instantiationInfo(-1, true).filename, keys, cb)
template textObject*(keys, desc: string, cb: proc(b: Buf, p: Pos): Range) =
  ## A text object with what it is, in a few words (which-key shows it).
  regTextObject(instantiationInfo(-1, true).filename, keys, cb, desc)

# ── timers ──

proc regTimer(file: string, ms: int, repeat: bool, cb: proc()): int =
  let f = cb
  register(file, "timer", %*{"ms": ms, "repeat": repeat}, proc(a: JsonNode): JsonNode =
    f()
    newJNull())
template every*(ms: int, cb: proc()): int =
  ## Calls `cb` every `ms` milliseconds (100 at least), and returns the timer's id for `stopTimer`. ned keeps
  ## the time: nothing runs between the calls. But a plugin with a timer keeps its process running
  ## (`plugins.idleStopMinutes` does not stop it), so keep `cb` small. A timer goes when its plugin is reloaded;
  ## one made in the top-level code is made again then.
  ##
  ##     discard every(1000) do ():
  ##       status(localTime()[11 ..< 16])     # a clock: "14:03"
  regTimer(instantiationInfo(-1, true).filename, ms, true, cb)
template after*(ms: int, cb: proc()): int =
  ## Calls `cb` once, `ms` milliseconds from now (100 at least), and returns its id: `stopTimer` cancels it.
  ##
  ##     let id = after(25 * 60_000) do ():
  ##       toast("Time for a break")
  regTimer(instantiationInfo(-1, true).filename, ms, false, cb)
proc stopTimer*(id: int) = discard api("stopTimer", %*{"cb": id})
  ## Stops the timer `every` or `after` gave this id; nothing happens for one that has ended.

# ── language features for a language (6.20): completions, hover, code actions, symbols, snippets ──

type
  CompletionItem* = object
    ## One item for the completion list, from `completions`.
    label*: string               ## what the list shows (and what is typed over)
    insert*: string              ## what goes in ("": the label)
    detail*: string              ## beside it in the list (a type, a signature; "": the plugin's name)
    doc*: string                 ## Markdown, shown beside the list
    kind*: string                ## its icon: function method variable field type class keyword constant module
                                 ## snippet text value enum event operator file folder
    snippet*: bool               ## insert is a snippet: $1 $2 … ${1:default} $0
  Symbol* = object
    ## One entry of a file's outline, from `symbols`.
    name*: string                ## what it shows
    kind*: string                ## function method type class variable constant heading section … (its icon:
                                 ## ƒ T # c •)
    detail*: string              ## dimmer text beside it (a signature, a value)
    line*, col*: int             ## where it is (both from 0)
    depth*: int                  ## how deep in the outline (0 at the top, up to 8)

proc `%`*(c: CompletionItem): JsonNode =
  ## The item as ned's JSON.
  %*{"label": c.label, "insert": c.insert, "detail": c.detail, "doc": c.doc, "kind": c.kind, "snippet": c.snippet}
proc `%`*(s: Symbol): JsonNode =
  ## The symbol as ned's JSON.
  %*{"name": s.name, "kind": s.kind, "detail": s.detail, "line": s.line, "col": s.col, "depth": s.depth}

proc regCompletions*(file, lang: string, cb: proc(b: Buf, p: Pos, prefix: string): seq[CompletionItem]) =
  ## (what `completions` uses: call `completions`)
  let f = cb
  discard register(file, "completion", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    result = newJArray()
    for it in f(Buf(id: a{"buf"}.getInt), toPos(a{"pos"}), a{"prefix"}.getStr): result.add %it)
template completions*(lang: string, cb: proc(b: Buf, p: Pos, prefix: string): seq[CompletionItem]) =
  ## Completions for the language's files ("zig"; `"*"`: every file), merged with ned's own and a language
  ## server's. ned asks when the list opens (Ctrl+Space, or as you type): `cb` gets the file, the cursor and the
  ## word typed so far before it (`prefix`), and ned narrows the list itself as you type on. It does not wait:
  ## items that come after the list has gone are dropped, so keep it quick.
  ##
  ##     completions("*") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  ##       for w in ["TODO", "FIXME"]:
  ##         if w.startsWith(prefix): result.add CompletionItem(label: w, kind: "keyword")
  regCompletions(instantiationInfo(-1, true).filename, lang, cb)

proc regHover*(file, lang: string, cb: proc(b: Buf, p: Pos): string) =
  ## (what `hover` uses: call `hover`)
  let f = cb
  discard register(file, "hover", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    %f(Buf(id: a{"buf"}.getInt), toPos(a{"pos"})))
template hover*(lang: string, cb: proc(b: Buf, p: Pos): string) =
  ## What the hover (Alt+H, or the mouse) shows at `p` in the language's files (`"*"`: every file): Markdown, ""
  ## for nothing. It shows under ned's own, when it comes while the hover is still for that place.
  ##
  ##     hover("markdown") do (b: Buf, p: Pos) -> string:
  ##       let w = b.wordAt(p)
  ##       if w.len > 0: "**" & w & "**: " & $w.len & " letters" else: ""
  regHover(instantiationInfo(-1, true).filename, lang, cb)

proc regCodeActions*(file, lang: string, cb: proc(b: Buf, r: Range): seq[Fix]) =
  ## (what codeActions uses: call codeActions)
  let f = cb
  discard register(file, "codeActions", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    result = newJArray()
    for x in f(Buf(id: a{"buf"}.getInt), toRange(a{"range"})): result.add %x)
template codeActions*(lang: string, cb: proc(b: Buf, r: Range): seq[Fix]) =
  ## Fixes and changes for the language's files (`"*"`: every file), in the Quick fixes list (Alt+Enter) with the
  ## problems' fixes. `r` is the selection, or the cursor's whole line when nothing is selected. ned waits for
  ## them, 1 s at most: keep it quick.
  ##
  ##     codeActions("*") do (b: Buf, r: Range) -> seq[Fix]:
  ##       let l = r.start.line
  ##       result.add Fix(title: "Upper-case the line",
  ##                      edits: @[Edit(range: b.lineRange(l), text: b.line(l).toUpperAscii)])
  regCodeActions(instantiationInfo(-1, true).filename, lang, cb)

proc regSymbols*(file, lang: string, cb: proc(b: Buf): seq[Symbol]) =
  ## (what `symbols` uses: call `symbols`)
  let f = cb
  discard register(file, "symbols", %*{"lang": lang}, proc(a: JsonNode): JsonNode =
    result = newJArray()
    for s in f(Buf(id: a{"buf"}.getInt)): result.add %s)
template symbols*(lang: string, cb: proc(b: Buf): seq[Symbol]) =
  ## The file's symbols for the language's files: the Outline dock, Go to symbol and the breadcrumbs. ned asks
  ## again after each pause in the typing, and shows the last answer until the next comes. They take the place
  ## of ned's own outline for that language — give them for a language you know (`"*"` would take every
  ## outline's place); one plugin's for each language.
  ##
  ##     symbols("markdown") do (b: Buf) -> seq[Symbol]:
  ##       for i, l in b.lines:
  ##         if l.startsWith("#"): result.add Symbol(name: l.strip(chars = {'#', ' '}), kind: "heading", line: i)
  regSymbols(instantiationInfo(-1, true).filename, lang, cb)

proc regSnippet*(file, lang, trigger, body, description: string) =
  ## (what `snippet` uses: call `snippet`)
  discard register(file, "snippet", %*{"lang": lang, "trigger": trigger, "body": body, "description": description})
template snippet*(lang, trigger, body: string, description = "") =
  ## A snippet for the language's files (`"*"`: every file): typing `trigger` offers it in the completion list,
  ## and choosing it inserts `body` — $1 $2 … the places Tab goes to, ${1:default} one with text in it, $0 where
  ## the cursor ends, "\n" a new line. `description` shows in the list ("": the plugin's name). Your `snippets`
  ## setting wins over a plugin's.
  ##
  ##     snippet("markdown", "link", "[${1:text}](${2:https://})$0", "a link")
  regSnippet(instantiationInfo(-1, true).filename, lang, trigger, body, description)

# ── the assistant: tools it may call (6.20) ──

proc regAiTool*(file, name, description: string, params: JsonNode, readOnly: bool, cb: proc(args: JsonNode): string) =
  ## (what aiTool and aiToolReadOnly use: call those)
  let f = cb
  discard register(file, "aiTool", %*{"name": name, "description": description, "params": params,
                                       "readOnly": readOnly}, proc(a: JsonNode): JsonNode = %f(a))
template aiTool*(name, description: string, params: JsonNode, cb: proc(args: JsonNode): string) =
  ## A tool the assistant (ned's AI agent) may call. `name`: letters, digits and _ — the model knows it as
  ## `plugin__<plugin>__<name>`. `description`: what it does and when to use it, for the model. `params`: its
  ## arguments as JSON Schema properties, each with a "type" and a "description" — every one required unless it
  ## has "optional": true — or a whole schema (`{"type": "object", …}`), taken as it is. `cb` gets the arguments
  ## as the model gave them and returns the text the model gets back; the message of an exception it raises is
  ## what the model sees. The assistant asks you before each call, as before a command it runs — unless
  ## `ai.autoApprove` is all.
  ##
  ##     aiTool("insert_text", "Insert text at the cursor in the file being edited",
  ##            %*{"text": {"type": "string", "description": "what to insert"}}) do (args: JsonNode) -> string:
  ##       let b = current()
  ##       b.insert(b.cursor, args{"text"}.getStr)
  ##       "inserted"
  regAiTool(instantiationInfo(-1, true).filename, name, description, params, false, cb)
template aiToolReadOnly*(name, description: string, params: JsonNode, cb: proc(args: JsonNode): string) =
  ## A tool that only reads: the assistant calls it without asking, as it reads a file (unless `ai.autoApprove`
  ## is none). Declare a tool read-only only when it changes nothing. A call with a "path" argument outside the
  ## project asks you first, whatever the tool.
  regAiTool(instantiationInfo(-1, true).filename, name, description, params, true, cb)

# ── views in the Plugins dock, progress, output, the terminal (6.20) ──

type
  ViewItem* = object
    ## One row of a view in the Plugins dock, from `view`.
    text*, detail*: string       ## its text, and the dimmer text beside it
    icon*: string                ## one character ("●", "✓" …)
    color*: string               ## error warn add accent hint ("": the text's colour)
    id*: string                  ## what the view's click callback gets
    path*: string                ## a file: clicking opens it (at line, when no click callback takes it)
    line*: int                   ## (with path) the line clicking opens it at (from 0)
    depth*: int                  ## how far it is indented (a tree: 0 at the top, up to 6)

proc `%`*(v: ViewItem): JsonNode =
  ## The item as ned's JSON.
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
  ## A section of the Plugins dock, titled `title` (shown in capitals): `getItems` gives its rows. ned asks for
  ## them when the dock shows and again after `refreshView` (at most twice a second), and shows the last rows
  ## until new ones come; an exception shows as a row in the error colour. Clicking a row with a `path` opens
  ## that file.
  ##
  ##     view("Open files") do () -> seq[ViewItem]:
  ##       for b in buffers():
  ##         result.add ViewItem(text: b.title, icon: (if b.dirty: "●" else: " "), path: b.path)
  regView(instantiationInfo(-1, true).filename, title, getItems, nil)
template view*(title: string, getItems: proc(): seq[ViewItem], click: proc(id: string)) =
  ## A view with what clicking a row does: `click` gets the row's `id`. A row with a `path` and no `id` still
  ## opens its file.
  regView(instantiationInfo(-1, true).filename, title, getItems, click)
proc refreshView*(title: string) = discard api("refreshView", %*{"title": title})
  ## Says the rows of this plugin's view `title` changed: ned asks for them again when it next draws the dock.

proc progress*(text: string, percent = -1) = discard api("progress", %*{"text": text, "percent": percent})
  ## Shows work under way in the status bar and the Plugins dock: `text` and how far it has got (`percent` from
  ## 0 to 100; -1: not known). One item for each plugin: each call replaces the last, and `progressDone` removes
  ## it.
  ##
  ##     for i, f in files:
  ##       progress("Checking " & f, i * 100 div files.len)
  ##     progressDone()
proc progressDone*() = progress("")
  ## Removes this plugin's progress item.
proc output*(text: string) = discard api("output", %*{"text": text})
  ## Writes `text` in the Output panel, each of its lines after the plugin's name. A line that starts with
  ## file:line:col (or file:line) goes there when clicked; a relative path is taken from the project's folder.
  ## One call with all the lines is much quicker than one a line. It does not open the panel: `showOutput` does.
  ##
  ##     output("src/app.nim:12:5: a TODO is left\nsrc/app.nim:40:1: another")
  ##     showOutput()
proc showOutput*() = discard api("showOutput")
  ## Opens the Output panel, with what `output` wrote.
proc runInTerminal*(cmd: string, dir = "") = discard api("terminal", %*{"cmd": cmd, "dir": dir})
  ## Runs `cmd` in ned's integrated terminal, in `dir` (relative to the project's folder, or absolute; "": the
  ## project's folder): you see it run and can type to it. A new terminal when the current one is busy. Needs the
  ## "shell" permission.
  ##
  ##     runInTerminal("nimble test")

# ── panes (6.31): the editor area cut into panes, each showing a file ──

type
  PaneInfo* = object
    ## One pane of the editor, from `panes`. The editor not split is one pane (index 0).
    index*: int                  ## its number: what `focusPane`, `closePane` and `showInPane` take
    buf*: Buf                    ## the file it shows
    path*: string                ## that file's path ("" for an unsaved one or a tab of a plugin's)
    active*: bool                ## the pane with the focus: its file is `current()`
    x*, y*, w*, h*: int          ## where it is on the screen (columns and rows from 0), its header row included

proc panes*(): seq[PaneInfo] =
  ## The editor's panes, left to right and top to bottom; one when the editor is not split.
  ##
  ##     for p in panes():
  ##       if not p.active: message("also open: " & p.path)
  for p in api("panes"):
    result.add PaneInfo(index: p{"index"}.getInt, buf: Buf(id: p{"buf"}.getInt(-1)), path: p{"path"}.getStr,
                        active: p{"active"}.getBool, x: p{"x"}.getInt, y: p{"y"}.getInt, w: p{"w"}.getInt,
                        h: p{"h"}.getInt)
proc splitPane*(down = false, show = Buf(id: -1), pane = -1): int =
  ## Cuts a pane in two — `pane` (its index), else the one with the focus — the new one at its right, or below it
  ## when `down`. The new pane shows `show` (else the same file) and gets the focus. Returns the new pane's index;
  ## -1 when there is no room for it (a pane narrower than 14 columns or lower than 4 rows is not made) or no
  ## file is open.
  ##
  ##     let b = openFile("tests/test_main.nim")
  ##     discard splitPane(show = b)          # the test beside the code
  api("splitPane", %*{"down": down, "show": show.id, "pane": pane}).getInt(-1)
proc focusPane*(pane: int) = discard api("focusPane", %*{"pane": pane})
  ## Gives the focus to that pane: its file becomes `current()`, with that pane's cursors.
proc closePane*(pane: int) = discard api("closePane", %*{"pane": pane})
  ## Closes that pane; the pane beside it takes its place. Its file stays open in its tab.
proc showInPane*(pane: int, b: Buf) = discard api("showInPane", %*{"pane": pane, "buf": b.id})
  ## Shows the file `b` in that pane; the focus stays where it is (in the pane with the focus: `b` in front).
proc paneLayout*(kind: string) = discard api("paneLayout", %*{"kind": kind})
  ## Lays the panes out: "columns 2", "columns 3", "grid" (four) and "main" (one large at the left, three stacked
  ## at the right) put the open files in them; "equal" gives every pane the same size; "zoom" shows the pane with
  ## the focus alone (again: every pane); "one" keeps only it. Another word raises `ValueError`.

# ── multibuffers (6.31): pieces of many files in one editable tab ──

type
  Piece* = object
    ## Lines of a file in a multibuffer. Make one with `piece`; `pieces` gives a multibuffer's.
    path*: string                ## the file (relative: the project's)
    first*, last*: int           ## its first and last line in the file (from 0)
    note*: string                ## shown after its header, dimmer (one line)
    line*: int                   ## (from `pieces`) the line of its § header in the multibuffer; -1 otherwise

func piece*(path: string, first: int, last = -1, note = ""): Piece =
  ## Lines `first` .. `last` of a file (`last` -1: the first line only), for `openMultibuffer` and `addPiece`.
  ##
  ##     piece("src/app.nim", 10, 14, "the parser's entry point")
  Piece(path: path, first: first, last: (if last < first: first else: last), note: note, line: -1)
proc openMultibuffer*(title: string, pieces: openArray[Piece], focus = true): Buf =
  ## Opens a multibuffer: one tab with these pieces of files, each under a header with its file and line, edited
  ## as one text; saving it (Ctrl+S) writes each edited piece back to its file, where its lines are then. Pieces of
  ## a file that touch or overlap become one. Its tab comes to the front unless `focus` is false. Returns it — an
  ## invalid Buf when no piece has a line (a file that does not exist, lines past its end).
  ##
  ##     var ps: seq[Piece]
  ##     for (path, line) in hits: ps.add piece(path, max(0, line - 2), line + 2)
  ##     discard openMultibuffer("unsafe casts", ps)
  var arr = newJArray()
  for p in pieces: arr.add %*{"path": p.path, "first": p.first, "last": p.last, "note": p.note}
  Buf(id: api("openMultibuffer", %*{"title": title, "pieces": arr, "focus": focus}).getInt(-1))
proc pieces*(b: Buf): seq[Piece] =
  ## A multibuffer's pieces, in order — their lines as they are in it, edits included — with the line of each
  ## one's header (`line`). Empty when `b` is not a multibuffer.
  for p in api("pieces", %*{"buf": b.id}):
    result.add Piece(path: p{"path"}.getStr, first: p{"first"}.getInt, last: p{"last"}.getInt,
                     note: p{"note"}.getStr, line: p{"line"}.getInt(-1))
proc isMultibuffer*(b: Buf): bool = b.pieces().len > 0
  ## A multibuffer with at least one piece.
proc placeInFile*(b: Buf, p: Pos): tuple[path: string, pos: Pos] =
  ## The file and the place in it behind a place of a multibuffer — on a § header: the piece's first line. path ""
  ## when there is none (before the first piece, or `b` is not a multibuffer).
  ##
  ##     let (path, at) = current().placeInFile(current().cursor)
  ##     if path.len > 0: discard openFile(path, at.line, at.col)
  let r = api("placeInFile", %*{"buf": b.id, "pos": {"line": p.line, "col": p.col}})
  if r.kind == JObject: (r{"path"}.getStr, toPos(r{"pos"})) else: ("", Pos(line: -1))
proc lineInMultibuffer*(b: Buf, path: string, line: int): int =
  ## The line of the multibuffer `b` that shows that line of that file; -1 when none of its pieces has it.
  api("lineInMultibuffer", %*{"buf": b.id, "path": path, "line": line}).getInt(-1)
proc addPiece*(p: Piece, to = Buf(id: -1)): Buf =
  ## Adds a piece to the multibuffer `to` — else the one in use (the last one in front; a new one, "collected",
  ## when there is none) — and returns the multibuffer it went to. Not to one with edits that are not saved: the
  ## piece then goes to a new one.
  Buf(id: api("addPiece", %*{"buf": to.id, "path": p.path, "first": p.first, "last": p.last,
                            "note": p.note}).getInt(-1))
proc removePiece*(b: Buf, index: int) = discard api("removePiece", %*{"buf": b.id, "index": index})
  ## Takes a piece (its index in `pieces`) out of a multibuffer; its file stays as it is. Raises `ValueError` when
  ## the multibuffer has edits that are not saved.
proc refreshMultibuffer*(b: Buf) = discard api("refreshMultibuffer", %*{"buf": b.id})
  ## Each piece as its file has it now. A multibuffer with no edits of its own does it by itself, twice a second,
  ## when one of its files changes.

# ── what the plugin needs, its settings (6.20) ──

proc regRequires*(file, spec: string) = discard register(file, "requires", %*{"spec": spec})
  ## (what requiresNed uses: call requiresNed)
template requiresNed*(spec: string) =
  ## The ned this plugin needs: ">= 6.20", "6.20" (the same as >=), "< 7", or several that must all hold, ">=
  ## 6.20, < 7" (>= <= > < ==). ned reads it from the source before it runs the plugin — give it as one plain
  ## string — and an older ned leaves the plugin out and says why in the Plugins dock.
  ##
  ##     requiresNed(">= 6.29")
  regRequires(instantiationInfo(-1, true).filename, spec)

proc regInfo*(file: string, info: JsonNode) = discard register(file, "info", info)
  ## (what pluginInfo uses: call pluginInfo)
template pluginInfo*(version: string, author = "", homepage = "", license = "") =
  ## The plugin's version ("1.2.0": major.minor.patch), who wrote it, where it lives and its licence, shown in the
  ## Plugins dock and its menu. ned reads them from the source without running it: give them as plain strings, by
  ## name or in this order, in a call at the start of a line. *Check for updates* compares the version with the
  ## one in the plugin's repository.
  ##
  ##     pluginInfo(version = "1.2.0", author = "You", homepage = "https://example.org/you/notes", license = "MIT")
  regInfo(instantiationInfo(-1, true).filename, %*{"version": version, "author": author, "homepage": homepage,
                                                   "license": license})

proc regSettingDef*(file, key: string, default: JsonNode, description: string) =
  ## (what settingDef uses: call settingDef)
  discard register(file, "setting", %*{"key": key, "default": default, "description": description})
template settingDef*(key: string, default: string | int | bool | float, description: string) =
  ## Declares one of the plugin's settings: ned's Settings panel shows it among the plugins' as
  ## `plugins.<plugin>.<key>`, with `description` and `default`. The default's type — a string, a whole number,
  ## true or false, a number — is the setting's. Read it with `setting(key, default)`.
  ##
  ##     settingDef("width", 100, "Long lines: how many characters a line may have")
  regSettingDef(instantiationInfo(-1, true).filename, key, %default, description)
