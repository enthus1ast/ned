# ── more of the language server protocol: problems ned asks for (pull diagnostics — servers that only answer
#    when asked), the file's links (#include "x.h", @import, a JSON $schema, URLs in comments) underlined and
#    opened with Go to definition or Ctrl+click, and formatting as you type (editor.formatOnType) ──

proc lspPullDiags(s: LspServer, b: Buffer) =
  ## ask the server for the file's problems (it says it answers when asked: diagnosticProvider)
  if s == nil or s.dead or not s.ready or s.caps == nil or s.caps.kind != JObject or b.path.len == 0: return
  let dp = s.caps{"diagnosticProvider"}
  if dp == nil or dp.kind notin {JObject, JBool} or (dp.kind == JBool and not dp.getBool): return
  var p = %*{"textDocument": b.docId}
  let prev = s.pullIds.getOrDefault(b.path)
  if prev.len > 0: p["previousResultId"] = %prev
  if dp.kind == JObject and dp{"identifier"} != nil and dp{"identifier"}.kind == JString: p["identifier"] = dp["identifier"]
  discard s.lspRequest("textDocument/diagnostic", p, LspReq(kind: lrPullDiag, bufId: b.id, extra: b.path))

proc handlePullDiags(s: LspServer, req: LspReq, res: JsonNode) =
  ## the answer to a pull diagnostics request: remembers its result id for the next request, and when the report is a
  ## full one sets the file's problems from it (those of a hidden document of code in a Nim string or emit go onto the
  ## Nim file's lines); an "unchanged" report leaves them as they are
  if res == nil or res.kind != JObject: return
  let rid = res{"resultId"}.getStr
  if rid.len > 0: s.pullIds[req.extra] = rid
  if res{"kind"}.getStr == "full":
    if req.extra in shadowNim:
      # (the hidden document of code in a Nim string or emit: its problems go on the Nim file's lines)
      emitShadowDiags(s, req.extra, %*{"uri": uriFromPath(req.extra), "diagnostics": res{"items"}})
    else: lspSetDiags(s, req.extra, res{"items"})
  # ("unchanged": what it said the last time still holds)

# ── links ──

type DocLink = object
  a, e: Pos
  target, tip: string

var docLinks: Table[int, (int, seq[DocLink])]   # buffer id → (the version they were found in, the links)

proc lspLinksAsk(s: LspServer, b: Buffer) =
  ## asks the server for the file's links, when it offers them and the file is not very long; the answer comes to
  ## handleLinks
  if s == nil or s.caps == nil or s.caps.kind != JObject or s.caps{"documentLinkProvider"} == nil or
     b.path.len == 0 or b.lines.len > 20000: return
  discard s.lspRequest("textDocument/documentLink", %*{"textDocument": b.docId},
                       LspReq(kind: lrLinks, bufId: b.id, version: b.changeId))

proc openLinkTarget(target: string)

proc handleLinks(s: LspServer, req: LspReq, res: JsonNode) =
  ## keeps the links the server found for the buffer (with the version they belong to), to be underlined; or, for the
  ## answer to a resolve request, opens the target the server worked out
  if req.extra == "resolve":
    # a link whose target the server works out only when it is opened
    if res != nil and res.kind == JObject and res{"target"}.getStr.len > 0: openLinkTarget(res{"target"}.getStr)
    else: info("The language server did not say where this link goes")
    return
  let b = bufById(req.bufId)
  if b == nil: return
  var ls: seq[DocLink]
  if res != nil and res.kind == JArray:
    for l in res:
      if l.kind != JObject or l{"range"} == nil: continue
      ls.add DocLink(a: fromLspPos(s, b, l{"range", "start"}), e: fromLspPos(s, b, l{"range", "end"}),
                     target: l{"target"}.getStr, tip: l{"tooltip"}.getStr)
  if ls.len == 0 and b.id notin docLinks: return
  docLinks[b.id] = (req.version, ls)
  needRender = true

proc linkRangesOn(b: Buffer, line: int): seq[(int, int)] =
  ## the server's links on a line (as of the buffer's version) and the URLs written in it: (from, to) columns
  let dl = docLinks.getOrDefault(b.id, (-1, @[]))
  if dl[0] == b.changeId:
    for l in dl[1]:
      if l.a.line <= line and line <= l.e.line:
        result.add ((if l.a.line == line: l.a.col else: 0), (if l.e.line == line: l.e.col else: b.lines[line].len))
  let s = b.lines[line]
  if s.len > 2000: return
  var k = s.find("://")
  while k > 0:
    var a = k
    while a > 0 and s[a - 1] in Letters: dec a
    let scheme = s[a ..< k]
    var e = k + 3
    while e < s.len and s[e] notin {' ', '\t', '"', '\'', '<', '>', '`', ')', ']', '}'}: inc e
    while e > k + 3 and s[e - 1] in {'.', ',', ';', ':', '!', '?'}: dec e
    if scheme in ["http", "https", "file"] and e > k + 3: result.add (a, e)
    k = s.find("://", e)

proc linkTextAt(b: Buffer, p: Pos): (string, DocLink, bool) =
  ## the link under `p`: (a URL written there, the server's link, whether the server's link is it)
  let dl = docLinks.getOrDefault(b.id, (-1, @[]))
  if dl[0] == b.changeId:
    for l in dl[1]:
      if (l.a.line < p.line or (l.a.line == p.line and l.a.col <= p.col)) and
         (p.line < l.e.line or (p.line == l.e.line and p.col <= l.e.col)):
        return ("", l, true)
  if p.line < b.lines.len:
    for (a, e) in linkRangesOn(b, p.line):
      if p.col >= a and p.col <= e: return (b.lines[p.line][a ..< e], DocLink(), false)
  ("", DocLink(), false)

proc openLinkTarget(target: string) =
  ## a link's target: a file (file:///x#L12 opens at line 12), else the browser
  if target.startsWith("file://"):
    var t = target
    var line = -1
    let h = t.find('#')
    if h >= 0:
      var frag = t[h + 1 .. ^1]
      t = t[0 ..< h]
      if frag.startsWith("L"): frag = frag[1 .. ^1]
      let c = frag.find({',', ':'})
      if c >= 0: frag = frag[0 ..< c]
      try: line = parseInt(frag) - 1 except ValueError: discard
    let path = pathFromUri(t)
    if not fileExists(path):
      info("The link's file is not there: " & path)
      return
    pushJump()
    let nb = openFile(path)
    if nb != nil and line >= 0: nb.centerOn(nb.clampPos(Pos(line: line, col: 0)))
  elif target.startsWith("http://") or target.startsWith("https://") or target.startsWith("mailto:"):
    openInBrowser(target)
    info("Opened " & truncTo(target, 70))
  else: info("Not a link ned can open: " & truncTo(target, 60))

proc openLinkAt(b: Buffer, p: Pos): bool =
  ## the link under the cursor opened (true), or none there
  let (url, l, isServer) = linkTextAt(b, p)
  if isServer:
    if l.target.len > 0: openLinkTarget(l.target)
    else:
      let s = lspReady(b)
      if s == nil: return false
      let j = %*{"range": {"start": s.lspPos(b, l.a), "end": s.lspPos(b, l.e)}}
      discard s.lspRequest("documentLink/resolve", j, LspReq(kind: lrLinks, bufId: b.id, extra: "resolve"))
    return true
  if url.len > 0:
    openLinkTarget(url)
    return true
  false

proc cmdOpenLink() =
  ## the command that opens the link under the cursor
  let b = buf()
  if not openLinkAt(b, b.primary.head): info("No link at the cursor")

# ── formatting as you type: the server's on-type formatting, after the characters it asks for ──

proc formatOnTypeAsk(b: Buffer, ch: string) =
  ## after a character is typed, asks the server to format as you type (editor.formatOnType) if that character is one of
  ## its trigger characters; only with a single cursor
  if not cfgFormatOnType or b.path.len == 0 or b.cursors.len > 1: return
  let s0 = lspFor(b, false)
  if s0 == nil or not s0.ready or s0.caps == nil or s0.caps.kind != JObject: return
  let p = s0.caps{"documentOnTypeFormattingProvider"}
  if p == nil or p.kind != JObject: return
  var trig = @[p{"firstTriggerCharacter"}.getStr]
  for t in jitems(p{"moreTriggerCharacter"}): trig.add t.getStr
  if ch notin trig: return
  let s = lspReady(b)                         # (it has the character just typed)
  if s == nil: return
  discard s.lspRequest("textDocument/onTypeFormatting", %*{"textDocument": b.docId,
    "position": s.lspPos(b, b.primary.head), "ch": ch,
    "options": {"tabSize": b.indentW(), "insertSpaces": b.indent != "\t"}},
    LspReq(kind: lrOnType, bufId: b.id, version: b.changeId))

proc handleOnType(s: LspServer, req: LspReq, res: JsonNode) =
  ## applies the server's on-type formatting edits, unless the buffer was changed since the request (the edits would
  ## land in the wrong place)
  let b = bufById(req.bufId)
  if b == nil or b.changeId != req.version: return     # (typed on since: its edits would land in the wrong place)
  if res != nil and res.kind == JArray and res.len > 0:
    applyTextEdits(s, b, res)
    needRender = true
