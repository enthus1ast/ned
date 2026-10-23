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

import std/[json, tables, strutils]
export json, strutils, tables

var
  requests: Table[string, proc(params: JsonNode): JsonNode]
  notes: Table[string, proc(params: JsonNode)]
  docs*: Table[string, string]           ## uri → the document's text, as the client has it
  docVersion*: Table[string, int]
  utf8* = false                          ## the client counts columns in bytes (else UTF-16 code units)
  shuttingDown = false

proc send*(j: JsonNode) =
  ## a message to the client
  when defined(nimscript):
    echo $j
  else:
    stdout.write $j & "\n"
    stdout.flushFile()

proc onRequest*(meth: string, cb: proc(params: JsonNode): JsonNode) =
  ## answer a request ("textDocument/hover", "textDocument/completion" …): the result (newJNull() for none);
  ## raise ValueError to answer with an error
  requests[meth] = cb
proc onNotification*(meth: string, cb: proc(params: JsonNode)) =
  ## a notification (didOpen, didChange, didSave and didClose are kept by the library first)
  notes[meth] = cb

proc notify*(meth: string, params: JsonNode) = send(%*{"jsonrpc": "2.0", "method": meth, "params": params})
  ## a notification to the client (the editor): `notify("window/logMessage", %*{"type": 3, "message": "hi"})`
proc logMessage*(s: string, kind = 3) = notify("window/logMessage", %*{"type": kind, "message": s})
  ## a line in the client's log of this server (kind: 1 error, 2 warning, 3 information, 4 log)
proc showMessage*(s: string, kind = 3) = notify("window/showMessage", %*{"type": kind, "message": s})
  ## a message the client shows (kind: 1 error, 2 warning, 3 information)
proc publishDiagnostics*(uri: string, diagnostics: JsonNode) =
  ## diagnostics: [{"range": …, "severity": 1, "message": "…"}]
  notify("textDocument/publishDiagnostics", %*{"uri": uri, "diagnostics": diagnostics})

proc docText*(uri: string): string = docs.getOrDefault(uri)
  ## the document's text as the client has it now (its unsaved edits too); "" for one not open
proc docLines*(uri: string): seq[string] = docText(uri).split('\n')
  ## the document's lines (docText split at its line ends)

proc byteCol*(line: string, character: int): int =
  ## the client's column → a byte offset in the line
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
  ## a byte offset in the line → the client's column
  if utf8: return b
  var i = 0
  while i < min(b, line.len):
    let c = line[i].ord
    let n = if c < 0x80: 1 elif c < 0xE0: 2 elif c < 0xF0: 3 else: 4
    result += (if n == 4: 2 else: 1)
    i += n

proc lspRange*(line, a, e: int, text: string): JsonNode =
  ## a range on one line given in bytes, as the client counts
  %*{"start": {"line": line, "character": clientCol(text, a)}, "end": {"line": line, "character": clientCol(text, e)}}

proc wordAt*(params: JsonNode): string =
  ## the word at a request's position (textDocument + position)
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
  ## the server's loop: the capabilities it has ({"hoverProvider": true, "completionProvider": {}} …)
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
