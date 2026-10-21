# ── inlay hints (LSP textDocument/inlayHint) ──

var engineInlayBudget = 60                 # ms for the type hints of the lines around the screen

var inlayRetries: Table[int, (int, int)]     # buffer id → (changeId, rounds cut short for it)

func argIsLiteral(a: string): bool =
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
  for i in 0 ..< f.syms.len:
    template s: untyped = f.syms[i]
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

proc engineTypeHints(b: Buffer, f: NxFile, sc: NxScope, lo, hi: int, hints: var Table[int, seq[(int, string)]],
                     t0: MonoTime): bool =
  ## the types of lets, vars and consts written without one on lines lo..hi, worked out by ned's own engine (no
  ## nimsuggest) — false: out of time (engineInlayBudget ms from t0)
  result = true
  var got: Table[int, seq[(int, string)]]       # (a closure cannot hold on to `hints`: they go there at the end)
  defer:
    for l, v in got: hints.mgetOrPut(l, @[]).add v
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
    let row = addr got.mgetOrPut(s.line, @[])
    for (c0, _) in row[]:
      if c0 == c: return                 # (a routine inside a routine: its lines are looked at twice)
    row[].add (c, ": " & t)
  try:
    # module level
    for s in f.syms:
      if s.kind in {nxLet, nxVar, nxConst} and s.typ.len == 0 and s.value.len > 0 and s.line >= lo and s.line <= hi:
        if msSince(t0) > engineInlayBudget: return false
        let v = nxTypeOfExpr(f, sc, @[], s.value, s.line, 0)
        if s.slots < 0:
          let parts = nxTupleTypes(v.typ)
          if s.slot < parts.len: hintFor(s, parts[s.slot])
        else: hintFor(s, v.typ)
    # inside the routines on screen, and in top-level statements (a `for` loop's variables, the lets in its body)
    var done, doneTop: HashSet[int]
    var cut = false
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
      if cut: return false
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
    if cut: return false
  except Exception as e: internalError("type hints", e)

proc engineInlays(b: Buffer, lo, hi: int) =
  ## the hints of lines lo..hi at once (nedls asks for a range): types, parameter names, what routines raise
  let f = nxFileFor(b)
  if f == nil: return
  let sc = nxScope(f)
  let t0 = getMonoTime()
  var hints: Table[int, seq[(int, string)]]
  var cut = not engineTypeHints(b, f, sc, lo, hi, hints, t0)       # (out of time: the rest on the next round)
  var raisesCut = false                    # (… because of what routines raise: more rounds for that)
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
  lastInlayMs = int(msSince(t0))
  needRender = true

# ── in the editor: a chunk at a time ──
# The hints of 16 lines are worked out together, each chunk once for a text: what is on screen first, then ahead in
# the direction you scroll (two screens), then behind (one). A round takes a few ms — 4 while you swipe — so the
# hints are there by the time the lines scroll in, and scrolling back works nothing out again.

const IhChunk = 16

type IhState = object
  key: string                    # the text, index and settings the chunks below were worked out for
  done: HashSet[int]             # chunks (IhChunk lines from chunk * IhChunk) worked out
  tries: Table[int, int]         # chunks that ran out of time: how often (the next try has more)
  lastTop: int                   # where the view was (which way it scrolls)
  down: bool

var ihStates: Table[int, IhState]
var ihPending = false            # chunks around the screen still to do: the main loop comes back soon

proc engineInlayStep(b: Buffer) =
  ihPending = false
  let f = nxFileFor(b)
  if f == nil or b.lines.len == 0: return
  let key = $b.changeId & "/" & $nxGen & "/" & cfgParamHints & "/" & $cfgRaisesHints
  let st = addr ihStates.mgetOrPut(b.id, IhState(lastTop: b.topLine, down: true))
  let page = max(textH, 20)
  if b.inlayAt == -1:
    # (the hints were cleared — a setting, another engine: all of them again)
    st.key = ""
    b.inlayAt = -2
  if st.key != key:
    if st.key.len > 0:
      # another text: what is far from the screen goes (moved with its lines, it may no longer be right); what is
      # near stays shown until its chunk is worked out again
      var far: seq[int]
      for l in b.inlays.keys:
        if l < b.topLine - 3 * page or l > b.topLine + 4 * page: far.add l
      for l in far: b.inlays.del l
    st.key = key
    st.done.clear()
    st.tries.clear()
  if b.topLine != st.lastTop:
    st.down = b.topLine > st.lastTop
    st.lastTop = b.topLine
  let last = b.lines.high
  let visA = b.topLine div IhChunk
  let visB = min(last, b.topLine + textH) div IhChunk
  let below = min(last, b.topLine + textH + (if st.down: 2 * page else: page)) div IhChunk
  let above = max(0, b.topLine - (if st.down: page else: 2 * page)) div IhChunk
  var order: seq[int]
  for c in visA .. visB: order.add c
  if st.down:
    for c in visB + 1 .. below: order.add c
    for c in countdown(visA - 1, above): order.add c
  else:
    for c in countdown(visA - 1, above): order.add c
    for c in visB + 1 .. below: order.add c
  let quiet = msSince(lastInputAt) >= 150
  let slice = if quiet: 16 else: 4
  let t0 = getMonoTime()
  var sc: NxScope = nil
  var changed = false
  var visibleDone = true
  for c in order:
    if c in st.done: continue
    let el = int(msSince(t0))
    if el >= slice:
      ihPending = true
      if c >= visA and c <= visB: visibleDone = false
      break
    let tries = st.tries.getOrDefault(c)
    if tries > 0 and not quiet:
      # (one that ran out of time before: when you stop scrolling, with more time)
      ihPending = true
      if c >= visA and c <= visB: visibleDone = false
      continue
    if sc == nil: sc = nxScope(f)
    # (a chunk that ran out of time: more the next times, but never so much that a key or a wheel turn arriving
    # meanwhile waits long for it)
    let budget = if tries == 0: max(slice - el, 3) else: min(30, 10 * (tries + 1))
    let a = c * IhChunk
    let e = min(last, a + IhChunk - 1)
    var hints: Table[int, seq[(int, string)]]
    let keep = engineInlayBudget
    engineInlayBudget = budget
    let ct0 = getMonoTime()
    var cut = not engineTypeHints(b, f, sc, a, e, hints, ct0)
    if not cut and cfgParamHints != "off":
      try: engineParamHints(b, f, a, e, hints, ct0)
      except Exception as ex: internalError("parameter hints", ex)
      cut = msSince(ct0) > budget
    if not cut and cfgRaisesHints:
      try: cut = not engineRaisesHints(b, f, a, e, hints, ct0)
      except Exception as ex: internalError("exception hints", ex)
    engineInlayBudget = keep
    if cut and tries + 1 < 10:
      st.tries[c] = tries + 1
      ihPending = true
      if c >= visA and c <= visB: visibleDone = false
      continue
    # this chunk's lines: these hints now (after ten tries, what it got)
    for l in a .. e:
      var nw = hints.getOrDefault(l)
      nw.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
      if nw != b.inlays.getOrDefault(l):
        if nw.len == 0: b.inlays.del l
        else: b.inlays[l] = nw
        changed = true
    st.done.incl c
  if visibleDone: b.inlayAt = b.changeId
  if ihStates.len > 64:
    var gone: seq[int]
    for id in ihStates.keys:
      if bufById(id) == nil: gone.add id
    for id in gone: ihStates.del id
  let used = int(msSince(t0))
  if used > 0: lastInlayMs = used
  if changed: needRender = true

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

proc inlayCovered(b: Buffer): bool =
  ## are the hints of the lines on screen (and a few around them) worked out for this text already? Scrolling within
  ## what was worked out costs nothing; past it, the next window is worked out — a screen above, two below
  if b.inlayAt != b.changeId: return false
  let vlo = max(0, b.topLine - 5)
  let vhi = min(b.lines.high, b.topLine + max(textH, 20) + 5)
  vlo >= b.inlayLo and vhi <= b.inlayHi

proc inlayWindow(b: Buffer): (int, int) =
  let page = max(textH, 20)
  (clamp(b.topLine - page, 0, b.lines.high), min(b.lines.high, b.topLine + 2 * page + 20))

proc requestInlays(b: Buffer) =
  if b.lang.mode == lmCsv:
    if not cfgCsvAlign or b.largeOn:
      if b.inlays.len > 0: b.inlays.clear()
      return
    let (lo, hi) = inlayWindow(b)
    if inlayCovered(b): return
    csvInlays(b, lo, hi)
    return
  if not cfgInlayHints or b.path.len == 0: return
  if nimEngineOn(b) and sStr("nim.typeHints") != "nimsuggest":
    # ned's own engine: at once, without nimsuggest
    if msSince(b.lspChangeAt) < 300: return      # (typing: the hints there move with the text meanwhile)
    if wkOn():
      wkInlayStep(b)                             # (the engine worker works them out: the answers come back)
      return
    if not engineReady(b): return                # (the files it needs are being read, a few at a time)
    engineInlayStep(b)
    return
  if nimEngineOn(b):
    # nimsuggest (protocol 4) knows the types of lets and vars
    if not nsUsable(b) or nsProtoVer == 3: return
    let (lo, hi) = inlayWindow(b)
    if inlayCovered(b): return
    if msSince(b.inlayReqTime) < 900 or msSince(b.lspChangeAt) < 600: return
    b.inlayReqTime = getMonoTime()
    discard nsRequest(b, nsInlay, Pos(line: lo), $lo & "/" & $hi & "/" & $b.changeId)
    return
  let s = lspReady(b)
  if s == nil or s.caps == nil or s.caps{"inlayHintProvider"} == nil: return
  if s.caps{"inlayHintProvider"}.kind == JBool and not s.caps["inlayHintProvider"].getBool: return
  let (lo, hi) = inlayWindow(b)
  if inlayCovered(b): return
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
