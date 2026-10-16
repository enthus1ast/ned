proc symbolIcon(kind: int): string =
  case kind
  of 6, 9, 12: "ƒ"
  of 5, 10, 11, 23, 26: "T"
  of 7, 8, 13: "v"
  of 14, 22: "c"
  of 2, 3, 4: "m"
  else: "•"

proc handleSymbols(s: LspServer, b: Buffer, res: JsonNode) =
  var items: seq[PickItem]
  proc walk(n: JsonNode, prefix: string) =
    for it in n:
      let name = it{"name"}.getStr
      var rng = it{"selectionRange"}
      if rng == nil: rng = it{"location", "range"}
      let p = fromLspPos(s, b, rng{"start"})
      items.add PickItem(label: prefix & name, detail: it{"detail"}.getStr, icon: symbolIcon(it{"kind"}.getInt),
                         path: b.path, line: p.line, col: p.col)
      if it.hasKey("children"): walk(it["children"], prefix & name & ".")
  if res != nil and res.kind == JArray: walk(res, "")
  if items.len == 0:
    info("No symbols")
    return
  openPicker(pickSymbol, "Go to symbol", items)

proc showHoverAuto(text: string, auto: bool) =
  ## show Markdown text (signature in a ```nim block, documentation, diagnostics) in the hover popup
  let t = text.strip
  if t.len == 0 or t == "---":
    if not auto: info("No information")
    return
  hoverMd = t
  hoverLines = t.splitLines
  hoverScroll = 0
  hoverOpen = true
  hoverIsAuto = auto
  needRender = true

proc showHover(text: string) = showHoverAuto(text, false)

proc handleInlays(s: LspServer, req: LspReq, res: JsonNode)
proc handleCodeActions(s: LspServer, res: JsonNode)

proc lspConfigChanged() =
  for s in servers:
    if s.dead or not s.ready: continue
    if s.langId == "nim":
      s.lspNotify("workspace/didChangeConfiguration", %*{"settings": {"nim": nimSection()}})
    else:
      s.lspNotify("workspace/didChangeConfiguration", %*{"settings": sectionFor(s.langId)})

proc lspHandle(s: LspServer, m: JsonNode) =
  if m.kind != JObject: return
  if m.hasKey("id") and m.hasKey("method"):
    case m["method"].getStr
    of "workspace/configuration":
      var arr = newJArray()
      let items = m{"params", "items"}
      if items != nil:
        for it in jitems(items): arr.add sectionFor(it{"section"}.getStr)
      s.lspReply(m["id"], arr)
      # files held back for a new project rule can open now (a moment later: the server applies it first)
      if s.langId == "nim": nimCfgWaitUntil = getMonoTime() + initDuration(milliseconds = 150)
      var held: seq[int]
      for id in lspHoldAttach.keys: held.add id
      for id in held:
        lspHoldAttach[id] = min(lspHoldAttach[id], getMonoTime() + initDuration(milliseconds = 150))
    of "workspace/inlayHint/refresh":
      for b in bufs:
        if b.lang.id == s.langId: b.inlayAt = -1
      s.lspReply(m["id"], newJNull())
    of "workspace/applyEdit":
      applyWorkspaceEdit(s, m{"params", "edit"})
      s.lspReply(m["id"], %*{"applied": true})
    else:
      s.lspReply(m["id"], newJNull())
    return
  if m.hasKey("id"):
    let id = m["id"].getInt
    if id notin s.pending: return
    let req = s.pending[id]
    s.pending.del id
    if m.hasKey("error"):
      if req.kind notin {lrCompletion, lrHover}:
        warn(s.name & ": " & m["error"]{"message"}.getStr)
      if req.kind == lrInit: s.dead = true
      return
    let res = m{"result"}
    case req.kind
    of lrInit:
      s.caps = res{"capabilities"}
      s.utf8 = res{"capabilities", "positionEncoding"}.getStr == "utf-8"
      let tc = res{"capabilities", "completionProvider", "triggerCharacters"}
      if tc != nil:
        for t in jitems(tc):
          let x = t.getStr
          if x.len == 1: s.triggers.incl x[0]
      let st = res{"capabilities", "signatureHelpProvider", "triggerCharacters"}
      if st != nil:
        for t in jitems(st):
          let x = t.getStr
          if x.len == 1: s.sigTriggers.incl x[0]
      s.ready = true
      s.status = ""
      if s.langId == "html" and s.caps != nil and s.caps.kind == JObject and s.caps{"completionProvider"} == nil:
        # vscode-html-language-server declares completion only to clients with snippets; it answers anyway
        s.caps["completionProvider"] = %*{"triggerCharacters": [".", ":", "<", "\"", "=", "/"]}
        for c in ".:<\"=/": s.triggers.incl c
      if s.langId == "nim": nimCfgWaitUntil = getMonoTime() + initDuration(milliseconds = 1500)
      s.lspNotify("initialized", newJObject())
      for b in bufs:
        if b.lang.id == s.langId: lspAttach(b)
      info(s.name & " ready")
    of lrCompletion: handleCompletion(s, req, res)
    of lrResolve:
      # completionItem/resolve: the documentation of the item selected in the list
      if res == nil or res.kind != JObject: return
      let label = res{"label"}.getStr
      for it in compItems.mitems:
        if it.label == label and it.resolveAsked:
          let d = markupText(res{"documentation"}).strip
          let det = res{"detail"}.getStr.strip
          var doc = ""
          if det.len > 0 and det notin d: doc = "```" & buf().lang.name.toLowerAscii & "\n" & det & "\n```"
          if d.len > 0: doc.add (if doc.len > 0: "\n" else: "") & d
          if doc.len > 0:
            it.doc = doc
            it.docMade = true
          if it.detail.len == 0 and det.len > 0: it.detail = det.splitLines()[0]
          break
    of lrHover:
      let auto = req.extra == "auto"
      let b = buf()
      if auto and (b.id != req.bufId or b.primary.head != req.pos): return
      if b.id != req.bufId: return                          # another tab by now: its answer is for that one
      var txt = if res != nil and res.kind == JObject: markupText(res{"contents"}) else: ""
      if req.extra2 == "emit" and b.id == req.bufId:          # C in an emit (clangd)
        if txt.strip.len == 0: txt = emitHoverInfo(b, req.pos)
        else: txt.add emitNimNote(b, b.wordAt(req.pos))
      elif req.extra2 == "emb": discard                     # HTML, CSS … in a string: its server's or nothing
      elif txt.strip.len == 0 and b.lang.mode == lmNim: txt = nimDocFor(b.wordAt(req.pos))
      if (hoverPrefix & txt).strip.len > 0: showHoverAuto(hoverPrefix & txt, auto)
      elif not auto: info("No information")
    of lrReferences:
      var hits: seq[(string, int, int)]
      if res != nil and res.kind == JArray:
        for loc in res:
          let path = pathFromUri(loc{"uri"}.getStr)
          let st = loc{"range", "start"}
          var p = Pos(line: st{"line"}.getInt, col: st{"character"}.getInt)
          let bi = bufIndexByPath(path)
          if bi >= 0: p = fromLspPos(s, bufs[bi], st)
          hits.add (path, p.line, p.col)
      showReferences("REFERENCES " & req.extra, hits)
    of lrExpand:
      let content = if res != nil and res.kind == JObject: res{"content"}.getStr else: ""
      if content.strip.len == 0: info("Nothing to expand — put the cursor on a macro or template call")
      else:
        discard openScratch("expand: " & req.extra, content.strip(chars = {'\n'}) & "\n", langByName("Nim"))
        info("Macro expansion shown in a read-only tab — Ctrl+W closes it")
    of lrDefinition: handleDefinition(s, res)
    of lrWsSymbols:
      var items: seq[PickItem]
      if res != nil and res.kind == JArray:
        for it in res:
          let loc = it{"location"}
          let path = pathFromUri(loc{"uri"}.getStr)
          let st = loc{"range", "start"}
          let l = if st != nil: st{"line"}.getInt else: 0
          items.add PickItem(label: it{"name"}.getStr, detail: relPath(path) & ":" & $(l + 1) &
                             (if it{"containerName"}.getStr.len > 0: " · " & it{"containerName"}.getStr else: ""),
                             icon: "◇", path: path, line: l, col: (if st != nil: st{"character"}.getInt else: 0))
      if items.len == 0: info("The language server found no symbols")
      else: openPicker(pickSymbol, "Workspace symbols (" & s.name & ") — " & $items.len, items)
    of lrSemTokens:
      let b = bufById(req.bufId)
      if b == nil or res == nil or res.kind != JObject: return
      let legend = s.caps{"semanticTokensProvider", "legend", "tokenTypes"}
      var types: seq[TokKind]
      if legend != nil:
        for t in jitems(legend): types.add semKindOf(t.getStr)
      var tbl: Table[int, seq[(int, int, TokKind)]]
      let d = res{"data"}
      if d != nil and d.kind == JArray:
        var line, col = 0
        var i = 0
        while i + 4 < d.len:
          let dl = d[i].getInt
          let dc = d[i + 1].getInt
          if dl > 0:
            line += dl
            col = dc
          else: col += dc
          let ty = d[i + 3].getInt
          if ty >= 0 and ty < types.len and types[ty] != tkText:
            tbl.mgetOrPut(line, @[]).add (col, d[i + 2].getInt, types[ty])
          i += 5
      lspSem[b.id] = (req.version, tbl)
      needRender = true
    of lrCallPrep:
      if res == nil or res.kind != JArray or res.len == 0:
        info("No call hierarchy here")
        return
      let item = res[0]
      callName = item{"name"}.getStr
      callItems.setLen(0)
      callWaiting = 2
      discard s.lspRequest("callHierarchy/incomingCalls", %*{"item": item}, LspReq(kind: lrCallIn))
      discard s.lspRequest("callHierarchy/outgoingCalls", %*{"item": item}, LspReq(kind: lrCallOut))
    of lrTypeDef: handleLocations(s, res, "type definition")
    of lrImpl: handleLocations(s, res, "implementation")
    of lrHighlight:
      let b = bufById(req.bufId)
      if b == nil or b.primary.head != req.pos: return
      docHl.ranges.setLen(0)
      for h in jitems(res):
        docHl.ranges.add (fromLspPos(s, b, h{"range", "start"}), fromLspPos(s, b, h{"range", "end"}))
      needRender = true
    of lrFolding:
      let b = bufById(req.bufId)
      if b == nil: return
      b.lspFolds.clear()
      for r in jitems(res):
        let a = r{"startLine"}.getInt
        let e = r{"endLine"}.getInt
        if e > a and r{"kind"}.getStr != "imports": b.lspFolds[a] = max(e, b.lspFolds.getOrDefault(a))
      b.lspFoldsAt = req.version
    of lrTypePrep:
      if res == nil or res.kind != JArray or res.len == 0:
        info("No type hierarchy here")
        return
      let item = res[0]
      typeHier = (item{"name"}.getStr, @[], 2)
      discard s.lspRequest("typeHierarchy/supertypes", %*{"item": item}, LspReq(kind: lrTypeSuper))
      discard s.lspRequest("typeHierarchy/subtypes", %*{"item": item}, LspReq(kind: lrTypeSub))
    of lrTypeSuper, lrTypeSub:
      for it in jitems(res): typeHier.items.add callItemOf(s, it, (if req.kind == lrTypeSuper: "↑" else: "↓"))
      dec typeHier.waiting
      if typeHier.waiting <= 0:
        if typeHier.items.len == 0: info("No supertypes or subtypes of " & typeHier.name)
        else: openPicker(pickSymbol, "Type hierarchy — " & typeHier.name & "  (↑ supertypes · ↓ subtypes)", typeHier.items)
    of lrCallIn, lrCallOut:
      if res != nil and res.kind == JArray:
        for c in res:
          if req.kind == lrCallIn: callItems.add callItemOf(s, c{"from"}, "←")
          else: callItems.add callItemOf(s, c{"to"}, "→")
      callDone()
    of lrInlay: handleInlays(s, req, res)
    of lrCodeAction: handleCodeActions(s, res)
    of lrRename: previewWorkspaceEdit(s, res, req.extra, req.extra2)
    of lrFormat:
      let b = bufById(req.bufId)
      if b != nil and res != nil and res.kind == JArray:
        # applied as a line diff, so the cursor and the view stay on the code you were at
        var edits: seq[(Pos, Pos, string)]
        for e in res:
          edits.add (fromLspPos(s, b, e{"range", "start"}), fromLspPos(s, b, e{"range", "end"}),
                     e{"newText"}.getStr.replace("\r\n", "\n"))
        if edits.len > 0: b.setTextMinimal(b.textWithEdits(edits))
        info("Formatted (" & s.name & ")")
    of lrSymbols:
      let b = bufById(req.bufId)
      if b != nil: handleSymbols(s, b, res)
    of lrSignature:
      sigOpen = false
      let b = buf()
      if res == nil or res.kind != JObject or b.id != req.bufId or b.primary.head.line != req.pos.line: return
      let sigs = res{"signatures"}
      if sigs == nil or sigs.kind != JArray or sigs.len == 0: return
      let si = clamp(res{"activeSignature"}.getInt, 0, sigs.len - 1)
      let sg = sigs[si]
      sigLabel = sg{"label"}.getStr
      let ap = if sg.hasKey("activeParameter"): sg["activeParameter"].getInt else: res{"activeParameter"}.getInt
      sigHl = (0, 0)
      sigDoc = markupText(sg{"documentation"}).strip
      sigMore = if sigs.len > 1: $(si + 1) & "/" & $sigs.len else: ""
      let params = sg{"parameters"}
      if params != nil and params.kind == JArray and ap >= 0 and ap < params.len:
        let pl = params[ap]{"label"}
        if pl != nil and pl.kind == JArray and pl.len == 2:
          sigHl = (fromU16(sigLabel, pl[0].getInt), fromU16(sigLabel, pl[1].getInt))
        elif pl != nil and pl.kind == JString:
          let j = sigLabel.find(pl.getStr)
          if j >= 0: sigHl = (j, j + pl.getStr.len)
      if params != nil and params.kind == JArray and ap >= 0 and ap < params.len:
        # the documentation of the parameter being typed comes first
        let pd = markupText(params[ap]{"documentation"}).strip
        let pl = if sigHl[1] > sigHl[0] and sigHl[1] <= sigLabel.len: sigLabel[sigHl[0] ..< sigHl[1]] else: ""
        if pd.len > 0: sigDoc = (if pl.len > 0: "`" & pl & "` — " else: "") & pd & (if sigDoc.len > 0: "\n\n" & sigDoc else: "")
      sigLine = req.pos.line
      sigOpen = sigLabel.len > 0
    else: discard
    needRender = true
    return
  let params = m{"params"}
  case m{"method"}.getStr
  of "textDocument/publishDiagnostics":
    let path = pathFromUri(params{"uri"}.getStr)
    if path in shadowNim:                       # the C a Nim file emits: its problems on the .nim's lines
      emitShadowDiags(s, path, params)
      return
    let i = bufIndexByPath(path)
    var ds: seq[Diag]
    for d in jitems(params{"diagnostics"}):
      var a = Pos(line: d{"range", "start", "line"}.getInt, col: d{"range", "start", "character"}.getInt)
      var e = Pos(line: d{"range", "end", "line"}.getInt, col: d{"range", "end", "character"}.getInt)
      if i >= 0:
        a = fromLspPos(s, bufs[i], d{"range", "start"})
        e = fromLspPos(s, bufs[i], d{"range", "end"})
      let (m, fx) = lspDiagMsg(d)
      ds.add Diag(line: a.line, col: a.col, eline: e.line, ecol: e.col,
                  sev: (let v = d{"severity"}.getInt(1); if v == 0: 1 else: v),
                  msg: m, raw: d{"message"}.getStr, fixes: fx, src: d{"source"}.getStr(s.name), code: d{"code"})
    diagsLsp[path] = ds
    needRender = true
  of "window/showMessage":
    let t = params{"type"}.getInt(3)
    let text = s.name & ": " & params{"message"}.getStr
    if t == 1:
      error(text)
      toast(text, 1)
    elif t == 2: warn(text)
  of "extension/statusUpdate":
    nlsStatus = params
    needRender = true
  of "$/progress":
    let v = params{"value"}
    case v{"kind"}.getStr
    of "begin": s.status = v{"title"}.getStr & " " & v{"message"}.getStr
    of "report":
      let pct = v{"percentage"}
      s.status = v{"message"}.getStr & (if pct != nil: " " & $pct.getInt & "%" else: "")
    of "end": s.status = ""
    needRender = true
  else: discard

var lspLastLog = initTable[string, seq[string]]()   # language id → stderr tail of the last server that died
var lspRestartAt = initTable[string, MonoTime]()    # language id → when to start a crashed server again

proc lspReadErr(s: LspServer) =
  ## keep the tail of the server's stderr instead of throwing it away
  var tmp: array[16384, char]
  while true:
    let n = posix.read(s.errFd, addr tmp[0], tmp.len)
    if n <= 0: break
    var chunk = newString(n)
    copyMem(addr chunk[0], addr tmp[0], n)
    let data = s.errPart & chunk
    let parts = data.split('\n')
    for k in 0 ..< parts.high:
      let l = stripAnsi(parts[k]).strip
      if l.len > 0: s.errTail.add (if l.len > 400: l[0 ..< 400] else: l)
    s.errPart = parts[^1]
    if s.errPart.len > 4000: s.errPart = s.errPart[^4000 .. ^1]
    if s.errTail.len > 120: s.errTail = s.errTail[^80 .. ^1]

proc lspDeathReason(s: LspServer): string =
  ## the most telling stderr line of a server that died
  for i in countdown(s.errTail.high, max(0, s.errTail.len - 40)):
    let l = s.errTail[i]
    let low = l.toLowerAscii
    if "error" in low or "exception" in low or "fatal" in low or "traceback" in low or "sigsegv" in low or
       "cannot" in low or "not found" in low or "failed" in low:
      return l
  if s.errTail.len > 0: s.errTail[^1] else: ""

proc lspRead(s: LspServer) =
  var tmp: array[65536, char]
  while true:
    let n = posix.read(s.outFd, addr tmp[0], tmp.len)
    if n > 0:
      let old = s.rbuf.len
      s.rbuf.setLen(old + n)
      copyMem(addr s.rbuf[old], addr tmp[0], n)
    elif n == 0:
      s.dead = true
      break
    else: break
  while true:
    let he = s.rbuf.find("\r\n\r\n")
    if he < 0: break
    var clen = -1
    # by lines, not \r\n: a server that prints to stdout (sql-language-server's timings) puts its lines
    # before the header
    for h0 in s.rbuf[0 ..< he].split('\n'):
      let h = h0.strip(chars = {'\r', ' '})
      if h.toLowerAscii.startsWith("content-length:"):
        try: clen = parseInt(h[15 .. ^1].strip)
        except ValueError: discard
    if clen < 0:
      s.rbuf = s.rbuf[he + 4 .. ^1]
      continue
    if s.rbuf.len < he + 4 + clen: break
    let body = s.rbuf[he + 4 ..< he + 4 + clen]
    s.rbuf = s.rbuf[he + 4 + clen .. ^1]
    try:
      lspHandle(s, parseJson(body))
    except CatchableError: discard

proc lspShutdown() =
  ## polite shutdown, then the whole process group goes: a language server's helpers (nimsuggest
  ## under nimlangserver) share its group, so none is ever left running after ned exits
  for s in servers:
    if s.dead: continue
    s.stopped = true
    discard s.lspRequest("shutdown", newJNull(), LspReq(kind: lrShutdown))
    s.lspNotify("exit", newJNull())
  let t0 = getMonoTime()
  for s in servers:
    while msSince(t0) < 600 and not s.pr.reap(): os.sleep(10)
    if s.pr.pid > 0: discard posix.kill(Pid(-s.pr.pid), SIGTERM)
    if not s.pr.exited: discard waitProc(s.pr, 150)
    closeFd(s.inFd)
    closeFd(s.outFd)
    closeFd(s.errFd)
  servers.setLen(0)
  for b in bufs: b.lspOpen = false
  nlsStatus = nil

proc lspRestartAll() =
  ## after the project folder changed: servers were started with the old root (and mapping)
  lspShutdown()
  lspFailed.clear()
  lspDeaths.clear()
  diagsLsp.clear()
  for b in bufs:
    if b.path.len > 0 and b.title.len == 0: lspAttach(b)
