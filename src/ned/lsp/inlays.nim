# ── inlay hints (LSP textDocument/inlayHint) ──

var engineInlayBudget = 60                 # ms for the type hints of the lines around the screen

var inlayRetries: Table[int, (int, int)]     # buffer id → (changeId, rounds cut short for it)

proc argIsLiteral(a: string): bool =
  ## a number, string, character, true / false / nil, or a literal collection — what a reader cannot tell the
  ## meaning of without the parameter's name
  let t = a.strip
  if t.len == 0: return false
  if t[0] in Digits or (t[0] == '-' and t.len > 1 and t[1] in Digits): return true
  if t[0] in {'"', '\'', '[', '{'} or t.startsWith("r\"") or t.startsWith("@["): return true
  t in ["true", "false", "nil"]

proc engineParamHints(b: Buffer, f: NxFile, lo, hi: int, hints: var Table[int, seq[(int, string)]], t0: MonoTime) =
  ## the names of the parameters before the arguments of calls (nim.parameterHints): `draw(width: 10, height: 20)` —
  ## only before literals unless "all"; never for one-parameter routines, single-letter names, an argument that
  ## already is the name, named arguments, or varargs
  let all = cfgParamHints == "all"
  for l in lo .. hi:
    if msSince(t0) > engineInlayBudget: return
    let s = b.lines[l]
    if s.len > 500 or '(' notin s: continue
    var st: NxLexState
    # where the code is on this line: identifiers outside strings and comments
    var code = newSeq[bool](s.len)
    for (a, e) in nxLexRuns(s, st, false):
      for k in a ..< e: code[k] = true
    var i = 0
    while i < s.len:
      if s[i] == '#':
        var inStr = false
        for k in 0 ..< i:
          if s[k] == '"': inStr = not inStr
        if not inStr: break
      if s[i] == '"':
        inc i
        while i < s.len and s[i] != '"':
          if s[i] == '\\': inc i
          inc i
        inc i
        continue
      if s[i] != '(' or i == 0 or not code[i - 1]:
        inc i
        continue
      # a call: name( … ) on this line
      let open = i
      var d = 0
      var close = -1
      var k = open
      var args: seq[(int, int)]           # each argument's text: (start, end)
      var argStart = open + 1
      while k < s.len:
        let c = s[k]
        if c == '"':
          inc k
          while k < s.len and s[k] != '"':
            if s[k] == '\\': inc k
            inc k
        elif c in {'(', '[', '{'}: inc d
        elif c in {')', ']', '}'}:
          dec d
          if d == 0:
            close = k
            break
        elif c == ',' and d == 1:
          args.add (argStart, k)
          argStart = k + 1
        elif c == '#' and d >= 1: break
        inc k
      if close < 0: break                 # (an argument list that goes on below: its next lines are left alone)
      if close > open + 1: args.add (argStart, close)
      i = open + 1
      if args.len == 0: continue
      var lits = false
      for (a, e) in args:
        if all or argIsLiteral(s[a ..< e]): lits = true
      if not lits: continue
      var h: NxSigHelp
      try: h = nxSignatureHelp(f, b.lines, l, open + 1)
      except Exception: continue
      if h.overloads.len == 0: continue
      let off = if h.ufcs: 1 else: 0
      for ai, (a, e) in args:
        let txt = s[a ..< e]
        if nxFindTop(txt, '=') >= 0: break           # named from here on: positions no longer tell
        if not (all or argIsLiteral(txt)): continue
        var name = ""
        var agree = true
        var many = true
        for r in h.overloads:
          let ps = r.sym.params
          if ps.len - off < args.len and not (ps.len > 0 and ps[^1].typ.startsWith("varargs")): continue
          let idx = ai + off
          if idx >= ps.len or ps[idx].typ.startsWith("varargs"):
            agree = false
            break
          if ps.len - off < 2: many = false
          if name.len == 0: name = ps[idx].name
          elif ps[idx].name != name: agree = false
        if not agree or not many or name.len <= 1 or txt.strip == name: continue
        var c = a
        while c < e and s[c] == ' ': inc c
        hints.mgetOrPut(l, @[]).add (c, name & ": ")

proc engineRaisesHints(b: Buffer, f: NxFile, lo, hi: int, hints: var Table[int, seq[(int, string)]], t0: MonoTime): bool =
  ## what each routine on screen without a {.raises.} of its own can raise, before the `=` of its header
  ## (nim.raisesHints) — only when the engine is sure of every call in it, and something is raised. false: out of
  ## time (what was worked out is kept: the next round goes on from there)
  result = true
  for i, s in f.syms:
    if s.kind notin {nxProc, nxFunc, nxIterator, nxConverter} or s.line > hi or s.line + 16 < lo: continue
    let left = engineInlayBudget - int(msSince(t0))
    if left <= 0: return false
    if not nxRaisesHintable(f, b.lines, s): continue
    let x = nxRaisesOf(NxRef(file: f, idx: int32(i)), 4000, left)
    if x.cut: return false
    if not x.known or x.excs.len == 0: continue
    let (l, c) = nxRaisesHintAt(b.lines, s)
    if l < lo or l > hi or l >= b.lines.len: continue
    var list = nxExcList(x)
    if list.len > 60: list = list[0 ..< 59] & "…"
    hints.mgetOrPut(l, @[]).add (c, " {.raises: [" & list & "].}")

proc engineInlays(b: Buffer, lo, hi: int) =
  ## the types of lets, vars and consts written without one, worked out by ned's own engine (no nimsuggest)
  let f = nxFileFor(b)
  if f == nil: return
  let sc = nxScope(f)
  let t0 = getMonoTime()
  var cut = false                          # (out of time: the rest on the next round)
  var raisesCut = false                    # (… because of what routines raise: more rounds for that)
  var hints: Table[int, seq[(int, string)]]
  proc hintFor(s: NxSym, typ: string) =
    var t = typ.strip.replace("system.", "")
    if t.len == 0 or t in ["untyped", "typed", "auto", "void"] or s.line >= b.lines.len: return
    if t.len > 40: t = t[0 ..< 39] & "…"
    let line = b.lines[s.line]
    var c = s.col + s.name.len
    if c > line.len or line.find(s.name, s.col) != s.col:
      c = line.find(s.name)
      if c < 0: return
      c += s.name.len
    if c < line.len and line[c] == '*': inc c
    let row = addr hints.mgetOrPut(s.line, @[])
    for (c0, _) in row[]:
      if c0 == c: return                 # (a routine inside a routine: its lines are looked at twice)
    row[].add (c, ": " & t)
  try:
    # module level
    for s in f.syms:
      if s.kind in {nxLet, nxVar, nxConst} and s.typ.len == 0 and s.value.len > 0 and s.line >= lo and s.line <= hi:
        if msSince(t0) > engineInlayBudget:
          cut = true
          break
        let v = nxTypeOfExpr(f, sc, @[], s.value, s.line, 0)
        if s.slots < 0:
          let parts = nxTupleTypes(v.typ)
          if s.slot < parts.len: hintFor(s, parts[s.slot])
        else: hintFor(s, v.typ)
    # inside the routines on screen, and in top-level statements (a `for` loop's variables, the lets in its body)
    var done, doneTop: HashSet[int]
    proc hintLocals(last: int) =
      for s in nxLocals(f, b.lines, last, high(int) div 2, everything = true):
        if msSince(t0) > engineInlayBudget:
          cut = true
          break
        if s.kind notin {nxLet, nxVar, nxConst, nxForVar} or s.typ.len > 0 or s.value.len == 0 or s.line < lo or
           s.line > hi: continue
        let locs = nxLocals(f, b.lines, s.line, s.col)
        hintFor(s, nxTypeOfName(f, sc, locs, s.name, s.line, 0).typ)
    for l in lo .. hi:
      let ri = nxEnclosing(f, l)
      if ri >= 0:
        if ri in done: continue
        done.incl ri
        hintLocals(min(hi, f.syms[ri].endLine))
      else:
        var s0 = l
        while s0 > 0 and (b.lines[s0].len == 0 or b.lines[s0][0] in {' ', '\t', '#', ')', ']', '}'}): dec s0
        if s0 in doneTop or nxEnclosing(f, s0) >= 0: continue
        doneTop.incl s0
        var e = s0 + 1
        while e <= b.lines.high and (b.lines[e].len == 0 or b.lines[e][0] in {' ', '\t', '#', ')', ']', '}'}): inc e
        if e - 1 > s0: hintLocals(min(hi, e - 1))
  except Exception as e: internalError("type hints", e)
  if cfgParamHints != "off" and not cut:
    try: engineParamHints(b, f, lo, hi, hints, t0)
    except Exception as e: internalError("parameter hints", e)
  if cfgRaisesHints and not cut:
    try:
      cut = not engineRaisesHints(b, f, lo, hi, hints, t0)
      raisesCut = cut
    except Exception as e: internalError("exception hints", e)
  b.inlays.clear()
  for l, v in hints:
    var vs = v
    vs.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
    b.inlays[l] = vs
  b.inlayAt = b.changeId
  b.inlayLo = lo
  b.inlayHi = hi
  if cut:
    # the first time round (the imported modules read, their scopes built) may run out of time: a few more
    # rounds for the same text, each faster than the last
    let (rc, rn) = inlayRetries.getOrDefault(b.id, (-1, 0))
    let n = if rc == b.changeId: rn + 1 else: 1
    inlayRetries[b.id] = (b.changeId, n)
    if n <= (if raisesCut: 16 else: 4): b.inlayAt = -1    # (the modules a routine calls into: read once, then kept)
  needRender = true

proc csvInlays(b: Buffer, lo, hi: int) =
  ## a CSV table lined up: virtual spaces after each separator so every column starts at the same place (the
  ## widths from the whole file, or the rows around the screen in a big one; the first row always: it stays on top)
  let sample = if b.lines.len <= 20000: (0, b.lines.high) else: (max(0, lo - 1000), min(b.lines.high, hi + 1000))
  var widths: seq[int]
  let key = $b.changeId & "/" & $sample[0] & "/" & $sample[1]
  if csvWidthCache.getOrDefault(b.id)[0] == key: widths = csvWidthCache[b.id][1]
  else:
    for l in sample[0] .. sample[1]:
      let s = b.lines[l]
      if s.len > 4000: continue
      for k, (a, e) in csvFields(s, csvSepOf(b.lang, s)):
        if k >= 200: break
        while widths.len <= k: widths.add 0
        widths[k] = max(widths[k], min(visColOf(s, e) - visColOf(s, a), 48))
    csvWidthCache[b.id] = (key, widths)
  b.inlays.clear()
  var lines = @[0]
  for l in lo .. hi:
    if l > 0: lines.add l
  for l in lines:
    let s = b.lines[l]
    if s.len > 4000: continue
    let sep = csvSepOf(b.lang, s)
    let gap = if sep == '\t': b.tabOf else: 2
    var target = 0
    var cum = 0
    var hs: seq[(int, string)]
    for k, (a, e) in csvFields(s, sep):
      if e >= s.len or k >= widths.high: break
      target += widths[k] + gap
      let after = visColOf(s, e + 1) + cum           # where the next field would start on screen
      let pad = target - after
      if pad > 0:
        hs.add (e + 1, spaces(pad))
        cum += pad
    if hs.len > 0: b.inlays[l] = hs
  b.inlayAt = b.changeId
  b.inlayLo = lo
  b.inlayHi = hi
  needRender = true

proc requestInlays(b: Buffer) =
  if b.lang.mode == lmCsv:
    if not cfgCsvAlign or b.largeOn:
      if b.inlays.len > 0: b.inlays.clear()
      return
    let lo = clamp(b.topLine - 30, 0, b.lines.high)
    let hi = min(b.lines.high, b.topLine + max(textH, 20) + 60)
    if b.inlayAt == b.changeId and lo >= b.inlayLo and hi <= b.inlayHi: return
    csvInlays(b, lo, hi)
    return
  if not cfgInlayHints or b.path.len == 0: return
  if nimEngineOn(b) and sStr("nim.typeHints") != "nimsuggest":
    # ned's own engine: at once, without nimsuggest
    let lo = clamp(b.topLine - 30, 0, b.lines.high)
    let hi = min(b.lines.high, b.topLine + max(textH, 20) + 60)
    if b.inlayAt == b.changeId and lo >= b.inlayLo and hi <= b.inlayHi: return
    if msSince(b.lspChangeAt) < 400: return
    engineInlays(b, lo, hi)
    return
  if nimEngineOn(b):
    # nimsuggest (protocol 4) knows the types of lets and vars
    if not nsUsable(b) or nsProtoVer == 3: return
    let lo = clamp(b.topLine - 30, 0, b.lines.high)
    let hi = min(b.lines.high, b.topLine + max(textH, 20) + 60)
    if b.inlayAt == b.changeId and lo >= b.inlayLo and hi <= b.inlayHi: return
    if msSince(b.inlayReqTime) < 900 or msSince(b.lspChangeAt) < 600: return
    b.inlayReqTime = getMonoTime()
    discard nsRequest(b, nsInlay, Pos(line: lo), $lo & "/" & $hi & "/" & $b.changeId)
    return
  let s = lspReady(b)
  if s == nil or s.caps == nil or s.caps{"inlayHintProvider"} == nil: return
  if s.caps{"inlayHintProvider"}.kind == JBool and not s.caps["inlayHintProvider"].getBool: return
  let lo = clamp(b.topLine - 30, 0, b.lines.high)
  let hi = min(b.lines.high, b.topLine + max(textH, 20) + 60)
  if b.inlayAt == b.changeId and lo >= b.inlayLo and hi <= b.inlayHi: return
  if msSince(b.inlayReqTime) < 350: return
  b.inlayReqTime = getMonoTime()
  lspSync(b)
  discard s.lspRequest("textDocument/inlayHint", %*{"textDocument": b.docId,
    "range": {"start": s.lspPos(b, Pos(line: lo, col: 0)),
              "end": s.lspPos(b, Pos(line: hi, col: b.lines[hi].len))}},
    LspReq(kind: lrInlay, bufId: b.id, version: b.changeId, pos: Pos(line: lo, col: hi)))

proc handleInlays(s: LspServer, req: LspReq, res: JsonNode) =
  var b: Buffer = nil
  for x in bufs:
    if x.id == req.bufId: b = x
  if b == nil or res == nil or res.kind != JArray: return
  if req.version != b.changeId: return
  b.inlays.clear()
  for h in res:
    let p = fromLspPos(s, b, h{"position"})
    var label = ""
    let lj = h{"label"}
    if lj != nil:
      if lj.kind == JString: label = lj.getStr
      elif lj.kind == JArray:
        for part in lj: label.add part{"value"}.getStr
    label = label.replace("\n", " ").strip
    if label.len == 0 or p.line >= b.lines.len: continue
    if h{"paddingLeft"}.getBool: label = " " & label
    if h{"paddingRight"}.getBool: label = label & " "
    b.inlays.mgetOrPut(p.line, @[]).add (min(p.col, b.lines[p.line].len), label)
  for l, v in b.inlays.mpairs:
    v.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
  b.inlayAt = req.version
  b.inlayLo = req.pos.line
  b.inlayHi = req.pos.col
  needRender = true
