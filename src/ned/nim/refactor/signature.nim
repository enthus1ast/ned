# ── change signature ──

func rfParamText(p: NxParam): string =
  p.name & (if p.typ.len > 0: ": " & p.typ else: "") & (if p.default.len > 0: " = " & p.default else: "")

proc cmdChangeSignature() =
  let b = buf()
  if b.lang.mode != lmNim or not nimEngineOn(b):
    info("Change signature works on Nim, with the built-in engine")
    return
  let (d, ok) = rfDeclOf(b)
  if not ok or d.sym.kind notin NxRoutineKinds:
    info("Put the cursor on a proc — its name, or a call of it")
    return
  let s = d.sym
  for p in s.params:
    if p.typ.startsWith("varargs"):
      info(s.name & " takes varargs — change its calls by hand")
      return
  var lines = @[
    "# " & s.name & " — Ctrl+S changes it and every call (Ctrl+W: no)",
    "# One per line, in order:  name: Type = default  ← old name",
    "# Delete a line to drop it. New: a default, or  :: value",
    "# Last line: what it returns (-> T, or just ->)"]
  for p in s.params: lines.add rfParamText(p) & "  ← " & p.name
  lines.add "-> " & s.ret
  let pb = openScratch("Change signature: " & s.name, lines.join("\n") & "\n", langByName("Nim"))
  pb.readOnly = false
  pb.savedSeq = pb.topSeq()
  var ps: seq[tuple[name, typ, default: string]]
  for p in s.params: ps.add (p.name, p.typ, p.default)
  sigPlans[pb.id] = SigPlan(path: d.file.path, name: s.name, line: s.line, col: s.col, params: ps, ret: s.ret)
  pb.setSingle(Pos(line: 4, col: 0))
  focus = fEditor

func rfParseParam(t: string): (NxParam, string, string, string) =
  ## "name: Type = default :: value ← old" → (param, old name, value for the calls, error)
  var x = t
  var old = ""
  let arrow = x.find("←")
  if arrow >= 0:
    old = x[arrow + "←".len .. ^1].strip
    x = x[0 ..< arrow]
  var value = ""
  let vv = x.find("::")
  if vv >= 0:
    value = x[vv + 2 .. ^1].strip
    x = x[0 ..< vv]
  x = x.strip
  var p: NxParam
  # the default: after the first top-level "=" that is not "=="
  var depth = 0
  var eq = -1
  for i, ch in x:
    if ch in {'(', '[', '{'}: inc depth
    elif ch in {')', ']', '}'}: dec depth
    elif ch == '=' and depth == 0 and (i + 1 >= x.len or x[i + 1] != '=') and (i == 0 or x[i - 1] notin {'=', '<', '>', '!'}):
      eq = i
      break
  var head = x
  if eq >= 0:
    p.default = x[eq + 1 .. ^1].strip
    head = x[0 ..< eq].strip
  let colon = head.find(':')
  if colon >= 0:
    p.name = head[0 ..< colon].strip
    p.typ = head[colon + 1 .. ^1].strip
  else: p.name = head.strip
  if not p.name.validIdentifier: return (p, old, value, "not a parameter name: " & p.name)
  if p.typ.len == 0 and p.default.len == 0: return (p, old, value, p.name & " needs a type or a default")
  (p, old, value, "")

proc rfHeaderEdits(lines: seq[string], path: string, l, c: int, newParams: seq[NxParam],
                   ret: string, edits: var seq[RfEdit]): bool =
  ## the declaration (or a forward one) at (l, c): its parameter list and return type rewritten
  let s = lines[l]
  var e = c + rfIdentLen(s, c)
  if e < s.len and s[e] == '*': inc e
  if e < s.len and s[e] == '[':
    let close = rfMatchClose(lines, l, e)
    if close.line != l: return false
    e = close.col + 1
  var ps: seq[string]
  for p in newParams: ps.add rfParamText(p)
  let plist = "(" & ps.join(", ") & ")"
  var afterL, afterC: int
  if e < s.len and s[e] == '(':
    let close = rfMatchClose(lines, l, e)
    if close.line < 0: return false
    edits.add (path, Pos(line: l, col: e), Pos(line: close.line, col: close.col + 1), plist)
    afterL = close.line
    afterC = close.col + 1
  else:
    edits.add (path, Pos(line: l, col: e), Pos(line: l, col: e), (if ps.len > 0: plist else: ""))
    afterL = l
    afterC = e
  # the return type: ": T" up to " =" or "{."
  let t = lines[afterL]
  var k = afterC
  while k < t.len and t[k] == ' ': inc k
  if k < t.len and t[k] == ':':
    var stop = k + 1
    var depth = 0
    while stop < t.len:
      let ch = t[stop]
      if ch in {'(', '['}: inc depth
      elif ch in {')', ']'}: dec depth
      elif depth == 0 and (ch == '=' or (ch == '{' and stop + 1 < t.len and t[stop + 1] == '.')): break
      inc stop
    var endT = stop
    while endT > k + 1 and t[endT - 1] == ' ': dec endT
    edits.add (path, Pos(line: afterL, col: afterC), Pos(line: afterL, col: endT), (if ret.len > 0: ": " & ret else: ""))
  elif ret.len > 0:
    edits.add (path, Pos(line: afterL, col: afterC), Pos(line: afterL, col: afterC), ": " & ret)
  true

proc doSignatureFromBuffer(b: Buffer): bool =
  let plan0 = sigPlans[b.id]
  var oldParams: seq[NxParam]
  for p in plan0.params: oldParams.add NxParam(name: p.name, typ: p.typ, default: p.default)
  let plan = (path: plan0.path, name: plan0.name, line: plan0.line, col: plan0.col, params: oldParams, ret: plan0.ret)
  var newParams: seq[NxParam]
  var fromOld: seq[int]              # the old parameter each new one was (-1: new)
  var values: seq[string]            # a new one: what the calls pass
  var ret = plan.ret
  var seen: HashSet[string]
  for raw in b.lines:
    let t = raw.strip
    if t.len == 0 or t.startsWith("#"): continue
    if t.startsWith("->"):
      ret = t[2 .. ^1].strip
      continue
    let (p, old, value, err) = rfParseParam(t)
    if err.len > 0:
      error(err)
      return false
    if nxNorm(p.name) in seen:
      error(p.name & " is there twice")
      return false
    seen.incl nxNorm(p.name)
    var oi = -1
    if old.len > 0:
      for i, q in plan.params:
        if nxNorm(q.name) == nxNorm(old): oi = i
      if oi < 0:
        error("← " & old & ": " & plan.name & " has no parameter " & old)
        return false
    if oi < 0 and p.default.len == 0 and value.len == 0:
      error(p.name & " is new: give it a default, or the value the calls pass (" & p.name & ": " & p.typ & " :: 0)")
      return false
    newParams.add p
    fromOld.add oi
    values.add value
  # the places: the declaration, forward declarations, the calls
  let f = nxLoad(plan.path)
  if f == nil: return false
  var si = -1
  for i, s in f.syms:
    if s.line == plan.line and s.name == plan.name: si = i
  if si < 0:
    error("Cannot find " & plan.name & " at line " & $(plan.line + 1) & " any more — open Change signature again")
    return false
  let (full, hits) = rfRefs(NxRef(file: f, idx: int32(si)))
  if hits.len == 0:
    error("The engine found no references to " & plan.name)
    return false
  var edits: seq[RfEdit]
  var byHand: seq[(string, int, int, string)]
  var calls = 0
  for (path, l, c) in hits:
    let lines = rfLinesOf(path)
    if l >= lines.len: continue
    let g = nxLoad(path)
    let isDecl = (path == plan.path and l == plan.line and c == plan.col) or
                 (g != nil and (let d = nxSymAt(g, l, c); d >= 0 and g.syms[d].kind in NxRoutineKinds))
    if isDecl:
      if not rfHeaderEdits(lines, path, l, c, newParams, ret, edits):
        byHand.add (path, l, c, "its parameter list")
        continue
      # its body: a renamed parameter's uses follow; one dropped but still used is left to you
      let di = if g != nil: nxSymAt(g, l, c) else: -1
      if g != nil and di >= 0:
        for oi, q in plan.params:
          let ni = fromOld.find(oi)
          if ni >= 0 and nxNorm(newParams[ni].name) == nxNorm(q.name): continue
          let uses = rfParamUses(path, g.syms[di], q.name)
          if ni >= 0:
            for u in uses:
              edits.add (path, u, Pos(line: u.line, col: u.col + rfIdentLen(lines[u.line], u.col)), newParams[ni].name)
          elif uses.len > 0:
            byHand.add (path, uses[0].line, uses[0].col, q.name & " is dropped, but the body still uses it")
      continue
    let cs = parseCallSite(lines, l, c, rfIdentLen(lines[l], c))
    if not cs.ok:
      byHand.add (path, l, c, "a call ned cannot read (command syntax: f x)")
      continue
    let (okMap, vals) = rfMapArgs(cs, plan.params)
    if not okMap:
      byHand.add (path, l, c, "its arguments do not match the parameters")
      continue
    if not cs.parens:
      # x.f passes the receiver, f nothing: still right when the rest can be left out
      var fine = not (cs.meth and newParams.len == 0)
      for i in 0 ..< newParams.len:
        if cs.meth and i == 0:
          if fromOld[0] != 0: fine = false
        elif newParams[i].default.len == 0: fine = false
      if not fine: byHand.add (path, l, c, "a call without parentheses")
      continue
    # the new argument list: positional until one is left out, named after that
    var outArgs: seq[string]
    var named = false
    var startAt = 0
    if cs.meth:
      if fromOld.len == 0 or fromOld[0] != 0:
        byHand.add (path, l, c, "x." & plan.name & "(…): the first parameter changed")
        continue
      startAt = 1
    for i in startAt ..< newParams.len:
      let oi = fromOld[i]
      let passed = if oi >= 0: vals[oi] else: values[i]
      if passed.len == 0:
        named = true
        continue
      outArgs.add (if named: newParams[i].name & " = " & passed else: passed)
    edits.add (path, cs.oa, Pos(line: cs.ea.line, col: cs.ea.col + 1), "(" & outArgs.join(", ") & ")")
    inc calls
  let files = rfApply(edits)
  b.savedSeq = b.topSeq()
  sigPlans.del b.id
  let i = bufs.find(b)
  if i >= 0: closeBufferAt(i)
  info("Changed " & plan.name & " and " & $calls & " call(s) in " & $files & " file(s) — Ctrl+S saves each (palette › Save all)" &
       (if byHand.len > 0: " · " & $byHand.len & " to change by hand" else: "") & (if full: "" else: " · " & RefsCutMsg))
  if byHand.len > 0: rfByHand("Change by hand — " & plan.name, byHand)
  true
