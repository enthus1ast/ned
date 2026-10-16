# ── code actions (quick fixes) ──

var pendingLocalFixes: seq[(string, string, Action)]
var pendingInlineFixes: seq[JsonNode]   # fixes the server sent with the diagnostics at the cursor (clangd)
var pendingFixBuf = -1                  # the buffer Quick fixes was asked in
proc localFixes(b: Buffer): seq[(string, string, Action)]

proc fixTouches(fixes: JsonNode, a, e: int): bool =
  ## does one of these fixes change a line from a to e? (clangd reports a missing `;` where the next
  ## statement starts, and its fix is at the end of the line before)
  if fixes == nil: return false
  for ca in fixes:
    let ed = ca{"edit"}
    if ed == nil: continue
    var tes: seq[JsonNode]
    if ed{"changes"} != nil and ed["changes"].kind == JObject:
      for _, arr in ed["changes"]:
        for te in jitems(arr): tes.add te
    for dc in jitems(ed{"documentChanges"}):
      for te in jitems(dc{"edits"}): tes.add te
    for te in tes:
      let l = te{"range", "start", "line"}.getInt(-1)
      if l >= a and l <= e: return true
  false

proc cmdCodeActions() =
  let b = buf()
  if b.lang.mode == lmNim and b.lines[b.primary.head.line].len <= 2000:
    # C in an emit, CSS … in a string: that server's fixes (its edits are on the .nim's own lines)
    var (es, sh) = (LspServer(nil), Buffer(nil))
    if emitIsC(b, b.primary.head): (es, sh) = emitLsp(b)
    else: (es, sh) = embDocAt(b, b.primary.head)
    if es != nil and es.caps != nil and es.caps{"codeActionProvider"} != nil:
      pendingLocalFixes.setLen(0)
      let (fl, _, fbody, flg) = b.embeddedStringAt(b.primary.head)
      if fl >= 0 and flg != nil and fbody.len >= 2:
        pendingLocalFixes.add act("Format the " & flg.name & " in this string", "", proc() = cmdFormatEmbedded())
      var (a, e) = b.primary.range
      # at the end of a line, the next line's problems too: C reports a missing ; where the next statement starts
      let atEnd = e.col >= b.lines[e.line].len
      var diags = newJArray()
      pendingInlineFixes.setLen(0)
      pendingFixBuf = b.id
      for d in diagsByShadow.getOrDefault(sh.path):
        if (d.line <= e.line and max(d.line, d.eline) >= a.line) or (atEnd and d.line == e.line + 1) or
           fixTouches(d.fixes, a.line, e.line):
          for ca in jitems(d.fixes): pendingInlineFixes.add ca
          let da = Pos(line: d.line, col: d.col)
          let de = Pos(line: max(d.line, d.eline), col: max(0, d.ecol))
          var dj = %*{"range": {"start": es.lspPos(b, da), "end": es.lspPos(b, de)},
                       "severity": d.sev, "message": (if d.raw.len > 0: d.raw else: d.msg[d.msg.find(": ") + 2 .. ^1])}
          if d.code != nil: dj["code"] = d.code
          diags.add dj
          if da < a: a = da
          if e < de: e = de
      discard es.lspRequest("textDocument/codeAction", %*{"textDocument": {"uri": uriFromPath(sh.path)},
        "range": {"start": es.lspPos(b, a), "end": es.lspPos(b, e)}, "context": {"diagnostics": diags}},
        LspReq(kind: lrCodeAction, bufId: b.id))
      return
  pendingLocalFixes = localFixes(b)
  pendingInlineFixes.setLen(0)
  pendingFixBuf = b.id
  let s = lspReady(b)
  if s == nil or s.caps == nil or s.caps{"codeActionProvider"} == nil:
    if pendingLocalFixes.len > 0: openActions("Quick fixes", pendingLocalFixes)
    else: info("No quick fixes here")
    return
  lspSync(b)
  var (a, e) = b.primary.range
  let (a0, e0) = (a, e)
  # at the end of a line, the next line's problem that starts its first word too: C reports a missing `;`
  # where the next statement begins
  let atEnd = e.col >= b.lines[e.line].len and e.line < b.lines.high
  let nextFirst = if atEnd: leadingWs(b.lines[e.line + 1]).len else: -1
  var diags = newJArray()
  for d in diagsLsp.getOrDefault(b.path):
    if (d.line <= e0.line and max(d.line, d.eline) >= a0.line) or fixTouches(d.fixes, a0.line, e0.line) or
       (atEnd and d.line == e0.line + 1 and d.col == nextFirst):
      var dj = %*{"range": {"start": s.lspPos(b, Pos(line: d.line, col: d.col)),
                            "end": s.lspPos(b, Pos(line: max(d.line, d.eline), col: max(0, d.ecol)))},
                  "severity": d.sev, "message": (if d.raw.len > 0: d.raw else: d.msg)}
      if d.code != nil: dj["code"] = d.code            # servers find their fixes by it (CSS, ESLint …)
      diags.add dj
      for ca in jitems(d.fixes): pendingInlineFixes.add ca
      let da = Pos(line: d.line, col: d.col)
      let de = Pos(line: max(d.line, d.eline), col: max(0, d.ecol))
      if da < a: a = da
      if e < de: e = de
  discard s.lspRequest("textDocument/codeAction", %*{"textDocument": b.docId,
    "range": {"start": s.lspPos(b, a), "end": s.lspPos(b, e)}, "context": {"diagnostics": diags}},
    LspReq(kind: lrCodeAction, bufId: b.id))

proc handleCodeActions(s: LspServer, res: JsonNode) =
  var items: seq[(string, string, Action)]
  let local = pendingLocalFixes
  pendingLocalFixes.setLen(0)
  let inline = pendingInlineFixes
  pendingInlineFixes.setLen(0)
  var all: seq[JsonNode]
  if res != nil and res.kind == JArray:
    for ca in res: all.add ca
  for ca in inline: all.add ca          # (what the server already listed is left out below)
  if all.len == 0:
    if local.len > 0: openActions("Quick fixes", local)
    else: info("No quick fixes here")
    return
  var seen: HashSet[string]
  var preferred: seq[(string, string, Action)]
  for ca in all:
    let ed = ca{"edit"}
    let cm = ca{"command"}
    let key = ca{"title"}.getStr & "|" & (if ed != nil: $ed else: "") & "|" & (if cm != nil: $cm else: "")
    if key in seen: continue
    seen.incl key
    let (title, what) = fixLabel(s, ca)
    let node = ca
    capture node:
      let it = act(title, (if what.len > 0: what else: node{"kind"}.getStr), proc() =
        if node{"edit"} != nil: applyWorkspaceEdit(s, node["edit"])
        let cmd = if node{"command"} != nil and node["command"].kind == JObject: node["command"]
                  elif node{"command"} != nil and node["command"].kind == JString: node
                  else: nil
        if cmd != nil:
          let cname = cmd{"command"}.getStr
          let args = cmd{"arguments"}
          if cname.endsWith(".applyCodeAction") and args != nil and args.kind == JArray and args.len >= 3:
            # the CSS server's fixes are a command its client runs: [uri, version, edits]
            applyWorkspaceEdit(s, %*{"changes": {args[0].getStr: args[2]}})
          else:
            discard s.lspRequest("workspace/executeCommand", %*{"command": cname,
              "arguments": (if args != nil: args else: newJArray())}, LspReq(kind: lrOther)))
      if node{"isPreferred"}.getBool: preferred.add it else: items.add it
  items = preferred & items             # (the fix the server prefers first: Enter applies it)
  for it in local: items.add it
  openActions("Quick fixes", items)
