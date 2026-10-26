## nedlsp — a language server in NimScript.
##
## `ned --lsp-bridge server.nims` runs the file with `nim e` and speaks the Language Server Protocol for it on its
## stdin and stdout: the file reads one JSON message per line and writes one per line. That command is the server
## for ned (a plugin's `languageServerScript`) and for any other editor.
##
## ```nim
## import nedlsp
##
## onRequest("textDocument/hover") do (params: JsonNode) -> JsonNode:
##   let w = wordAt(params)
##   if w.len == 0: return newJNull()
##   %*{"contents": {"kind": "markdown", "value": "**" & w & "**"}}
##
## serve(%*{"hoverProvider": true})
## ```
##
## The library keeps the open documents' text (`docText(uri)`), answers initialize, shutdown and exit, and
## converts the client's columns (UTF-16 or UTF-8, as agreed) to byte offsets in the line (`byteCol`).
##
## A server is a script of its own: it runs in its own process, with its folder as the current folder, and it
## cannot use `nedplugin` (it talks to the editor, not to ned's plugin host). It handles one message at a time,
## in the order they come. Its standard output is the protocol's: a line it writes that is not a message (an
## `echo` while you debug it) goes to the bridge's standard error, whose last lines ned shows when the server
## stops; `showMessage` puts an error or a warning in ned's status line. Try it on its own with
## `ned --lsp-bridge server.nims` and a few messages typed in, or from another editor (Helix, Neovim …): its
## language client runs `ned` with the arguments `--lsp-bridge /path/to/server.nims`.

import std/[json, tables, strutils]
export json, strutils, tables

var
  requests: Table[string, proc(params: JsonNode): JsonNode]
  notes: Table[string, proc(params: JsonNode)]
  docs*: Table[string, string]           ## The open documents' text by their URI ("file:///home/you/a.md"),
    ## as the client has it now, unsaved edits too. The library keeps it from didOpen, didChange (whole or in
    ## parts) and didClose; read it with `docText`.
  docVersion*: Table[string, int]        ## The open documents' versions by their URI: the number the client
    ## gave with its last didOpen or didChange.
  utf8* = false                          ## True when the client counts columns in bytes (it offered UTF-8
    ## positions at initialize); else it counts UTF-16 code units, the protocol's default. `byteCol`,
    ## `clientCol`, `lspRange` and `wordAt` count as it says.
  shuttingDown = false

proc send*(j: JsonNode) =
  ## Writes a message to the client, as one line of JSON (`ned --lsp-bridge` gives it the protocol's framing).
  ## The answers to requests and `notify` use it; a server seldom needs it itself.
  when defined(nimscript):
    echo $j
  else:
    stdout.write $j & "\n"
    stdout.flushFile()

proc onRequest*(meth: string, cb: proc(params: JsonNode): JsonNode) =
  ## Answers the client's requests of the method `meth` ("textDocument/hover", "textDocument/completion",
  ## "textDocument/definition" …): `cb` gets the request's params and returns its result (`newJNull()` for none).
  ## Raise an exception to answer with an error: its message goes to the client. One callback for each method —
  ## a second takes the first's place. A request with no callback is answered "not supported". The library
  ## answers initialize and shutdown itself (an `onRequest("initialize")` callback is called too, for the
  ## client's params). Say what the server answers in `serve`'s capabilities.
  ##
  ##     onRequest("textDocument/definition") do (params: JsonNode) -> JsonNode:
  ##       let uri = params["textDocument"]["uri"].getStr
  ##       %*{"uri": uri, "range": lspRange(0, 0, 0, "")}     # (the start of the same file)
  requests[meth] = cb
proc onNotification*(meth: string, cb: proc(params: JsonNode)) =
  ## Takes the client's notifications of the method `meth` ("textDocument/didOpen", "textDocument/didSave",
  ## "workspace/didChangeConfiguration" …): `cb` gets their params. For didOpen, didChange and didClose the
  ## library has updated `docs` before `cb` runs. An exception in `cb` goes to the client's log (`logMessage`).
  ##
  ##     onNotification("textDocument/didSave") do (params: JsonNode):
  ##       check(params["textDocument"]["uri"].getStr)
  notes[meth] = cb

proc notify*(meth: string, params: JsonNode) = send(%*{"jsonrpc": "2.0", "method": meth, "params": params})
  ## Sends the client a notification of the method `meth` with its params:
  ## `notify("window/logMessage", %*{"type": 3, "message": "hi"})`.
proc logMessage*(s: string, kind = 3) = notify("window/logMessage", %*{"type": kind, "message": s})
  ## Writes `s` as a line of the client's log of this server (`kind`: 1 error, 2 warning, 3 information, 4 log):
  ## other editors keep one (Neovim's :LspLog); ned does not show it — use `showMessage` for what you must see.
proc showMessage*(s: string, kind = 3) = notify("window/showMessage", %*{"type": kind, "message": s})
  ## A message the client shows to the person using it (`kind`: 1 error, 2 warning, 3 information). ned shows an
  ## error in its status line and as a note in the corner, a warning in its status line, and information not at
  ## all.
proc publishDiagnostics*(uri: string, diagnostics: JsonNode) =
  ## Sets the document's diagnostics — the problems the editor underlines and lists — in place of the ones sent
  ## for it before; an empty array clears them. `diagnostics` is a JSON array of
  ## {"range": …, "severity": 1 error · 2 warning · 3 information · 4 hint, "message": "…", "source": "…"}.
  ##
  ##     publishDiagnostics(uri, %*[{"range": lspRange(0, 0, 5, line), "severity": 2, "message": "too short"}])
  notify("textDocument/publishDiagnostics", %*{"uri": uri, "diagnostics": diagnostics})

proc docText*(uri: string): string = docs.getOrDefault(uri)
  ## The document's text as the client has it now, its unsaved edits too; "" for one that is not open.
proc docLines*(uri: string): seq[string] = docText(uri).split('\n')
  ## The document's lines: `docText` split at its line ends ("\n"). Line i is the protocol's line i.

proc byteCol*(line: string, character: int): int =
  ## Turns the client's column in `line` (a position's "character": UTF-16 code units, or bytes when `utf8`)
  ## into a byte offset in the line, as Nim's strings count; past the end gives the line's length.
  ##
  ##     let l = docLines(uri)[p["line"].getInt]
  ##     let c = byteCol(l, p["character"].getInt)     # l[c] is the character at the position
  if utf8: return min(character, line.len)
  var u = 0
  var i = 0
  while i < line.len and u < character:
    let c = line[i].ord
    let n = if c < 0x80: 1 elif c < 0xE0: 2 elif c < 0xF0: 3 else: 4
    u += (if n == 4: 2 else: 1)
    i += n
  min(i, line.len)

proc clientCol*(line: string, b: int): int =
  ## Turns a byte offset `b` in `line` into the client's column: for the positions a server sends.
  if utf8: return b
  var i = 0
  while i < min(b, line.len):
    let c = line[i].ord
    let n = if c < 0x80: 1 elif c < 0xE0: 2 elif c < 0xF0: 3 else: 4
    result += (if n == 4: 2 else: 1)
    i += n

proc lspRange*(line, a, e: int, text: string): JsonNode =
  ## A range on line `line` (from 0) from byte `a` to byte `e` of `text`, the line's text, as the client counts
  ## columns: what diagnostics, hover ranges, locations and edits need.
  ##
  ##     let k = l.find("TODO")
  ##     if k >= 0: diags.add %*{"range": lspRange(i, k, k + 4, l), "severity": 3, "message": "a TODO"}
  %*{"start": {"line": line, "character": clientCol(text, a)}, "end": {"line": line, "character": clientCol(text, e)}}

proc wordAt*(params: JsonNode): string =
  ## The word (letters, digits, _) at a request's position — params with "textDocument" and "position", as
  ## hover, completion and definition have — or "" when there is none.
  let uri = params{"textDocument"}{"uri"}.getStr
  let ls = docLines(uri)
  let ln = params{"position"}{"line"}.getInt
  if ln < 0 or ln >= ls.len: return ""
  let s = ls[ln]
  let c = byteCol(s, params{"position"}{"character"}.getInt)
  var a = c
  var e = c
  while a > 0 and s[a - 1] in IdentChars: dec a
  while e < s.len and s[e] in IdentChars: inc e
  s[a ..< e]

proc applyChange(uri: string, ch: JsonNode) =
  if ch{"range"} == nil:
    docs[uri] = ch{"text"}.getStr
    return
  var ls = docLines(uri)
  let r = ch["range"]
  let l0 = r["start"]["line"].getInt
  let l1 = r["end"]["line"].getInt
  if l0 >= ls.len: ls.add ""
  let a = byteCol(ls[min(l0, ls.high)], r["start"]["character"].getInt)
  let e = byteCol(ls[min(l1, ls.high)], r["end"]["character"].getInt)
  let before = ls[min(l0, ls.high)][0 ..< a]
  let after = ls[min(l1, ls.high)][e .. ^1]
  let mid = (before & ch{"text"}.getStr & after).split('\n')
  var res = ls[0 ..< min(l0, ls.len)]
  res.add mid
  if l1 + 1 < ls.len: res.add ls[l1 + 1 .. ^1]
  docs[uri] = res.join("\n")

proc handle(j: JsonNode, caps: JsonNode) =
  let meth = j{"method"}.getStr
  let params = j{"params"}
  if j.hasKey("id") and meth.len > 0:
    let id = j["id"]
    var res: JsonNode = newJNull()
    var err = ""
    if meth == "initialize":
      let pe = params{"capabilities"}{"general"}{"positionEncodings"}
      if pe != nil and pe.kind == JArray:
        for e in pe:
          if e.getStr == "utf-8": utf8 = true
      var c = if caps == nil: newJObject() else: caps.copy
      if not c.hasKey("textDocumentSync"): c["textDocumentSync"] = %*{"openClose": true, "change": 2, "save": true}
      if utf8: c["positionEncoding"] = %"utf-8"
      res = %*{"capabilities": c, "serverInfo": {"name": "nedlsp"}}
      if "initialize" in requests:
        try: discard requests["initialize"](params)
        except CatchableError: discard
    elif meth == "shutdown":
      shuttingDown = true
    elif meth in requests:
      try:
        res = requests[meth](params)
        if res == nil: res = newJNull()
      except CatchableError as e: err = e.msg
    else:
      send(%*{"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": "not supported: " & meth}})
      return
    if err.len > 0: send(%*{"jsonrpc": "2.0", "id": id, "error": {"code": -32603, "message": err}})
    else: send(%*{"jsonrpc": "2.0", "id": id, "result": res})
    return
  if j.hasKey("id"): return                   # (an answer to a request of ours: none are made)
  case meth
  of "exit": quit(if shuttingDown: 0 else: 1)
  of "textDocument/didOpen":
    let td = params{"textDocument"}
    docs[td{"uri"}.getStr] = td{"text"}.getStr
    docVersion[td{"uri"}.getStr] = td{"version"}.getInt
  of "textDocument/didChange":
    let uri = params{"textDocument"}{"uri"}.getStr
    let chs = params{"contentChanges"}
    if chs != nil and chs.kind == JArray:
      for ch in chs: applyChange(uri, ch)
    docVersion[uri] = params{"textDocument"}{"version"}.getInt
  of "textDocument/didClose":
    let uri = params{"textDocument"}{"uri"}.getStr
    docs.del uri
    docVersion.del uri
  else: discard
  if meth in notes:
    try: notes[meth](params)
    except CatchableError as e: logMessage(meth & ": " & e.msg, 1)

proc serve*(capabilities: JsonNode = nil) =
  ## The server's loop: reads the client's messages and calls the callbacks, one message at a time, until the
  ## client says exit. Call it last, at the end of the file. `capabilities` say what the server does, as the
  ## protocol's ServerCapabilities — {"hoverProvider": true, "completionProvider": {"triggerCharacters": ["."]},
  ## "definitionProvider": true, "documentSymbolProvider": true} …; the library adds "textDocumentSync" (open and
  ## close, changes in parts, saves) when they do not say, and the position encoding the client offered.
  ##
  ##     serve(%*{"hoverProvider": true, "completionProvider": {}})
  while true:
    var line = ""
    try:
      when defined(nimscript): line = readLineFromStdin()
      else:
        if not stdin.readLine(line): break
    except EOFError: break
    if line.len == 0 or line[0] != '{': continue
    var j: JsonNode
    try: j = parseJson(line)
    except CatchableError: continue
    handle(j, capabilities)
