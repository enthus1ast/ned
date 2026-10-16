# ── the formatter ──

type FOut* = object
  depth*: int
  toks*: seq[FTok]
  blank*: bool
  comment*: bool
  verbatim*: bool
  origText*: string
  cont*: int            # extra indentation for physical lines kept as written
  complexKind*: int
  lineCount*: int       # output lines it took (after wrapping)
  importish*: bool      # a line in an `import` block: module paths
  exprLine*: bool       # a value on its own line after `x =`
  children*: int        # deeper lines right after it

proc fTop*(toks: openArray[FTok], what: proc(t: FTok, depth: int): bool): int =
  var d = 0
  for k, t in toks:
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and what(t, d): return k
  -1

proc fSimpleTail*(toks: openArray[FTok], a: int): bool =
  ## only plain values (names, literals, a.b, discard) — and an `else` branch of the same kind
  var prevOperand = false
  var d = 0
  for k in a ..< toks.len:
    let t = toks[k]
    case t.kind
    of fkIdent, fkNum, fkStr, fkChar:
      if prevOperand and d == 0: return false      # echo x — a command, not a value
      prevOperand = true
    of fkDot: prevOperand = false
    of fkOp:
      # a negative number
      if prevOperand or t.text != "-" or k + 1 >= toks.len or toks[k + 1].kind != fkNum: return false
    of fkColon: prevOperand = false
    of fkKw:
      if t.text in ["else", "nil"]: prevOperand = t.text == "nil"
      elif t.text == "discard" and not prevOperand: discard
      else: return false
    of fkComment: discard
    else: return false
  true

proc fTopEq*(toks: openArray[FTok], a, b: int): int =
  ## the first `=` outside brackets in toks[a ..< b], or -1
  var d = 0
  for k in a ..< b:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkOp and t.text == "=": return k
  -1

proc fTopColon*(toks: openArray[FTok], a, b: int): int =
  var d = 0
  for k in a ..< b:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkColon: return k
  -1

proc fSplitIdx*(toks: openArray[FTok], a, b: int): (int, int) =
  ## an inline block in toks[a ..< b]:  `if a: b else: c` → (index of the header's last token, where
  ## the body ends); (-1, -1) when there is none
  if b - a < 2: return (-1, -1)
  let t0 = toks[a]
  var hdrEnd = -1
  var valueIf = false
  if t0.kind == fkKw and t0.text in FRoutineKw and toks[a + 1].kind in {fkIdent, fkKw}:
    hdrEnd = fTopEq(toks, a, b)
  elif t0.kind == fkKw and t0.text in FBlockKw:
    if t0.text == "static" and toks[a + 1].kind != fkColon: return (-1, -1)
    hdrEnd = fTopColon(toks, a, b)
  else:
    # a lambda as a value:  let f = proc(x: int): int = x + 1  → its body on the next line
    let eq1 = fTopEq(toks, a, b)
    if eq1 >= 0 and eq1 + 2 < b and toks[eq1 + 1].kind == fkKw and toks[eq1 + 1].text in ["proc", "func"] and
       toks[eq1 + 2].kind == fkOpen:
      hdrEnd = fTopEq(toks, eq1 + 1, b)
    # an if-expression as a value:  x = if a: f() else: g()  → one branch per line
    elif eq1 >= 0 and eq1 + 2 < b and toks[eq1 + 1].kind == fkKw and toks[eq1 + 1].text in ["if", "when"]:
      hdrEnd = fTopColon(toks, eq1 + 2, b)
      valueIf = true
  if hdrEnd < 0 or hdrEnd >= b - 1 or toks[hdrEnd + 1].kind == fkComment: return (-1, -1)
  # the body runs to an elif/else (or except/finally) of this statement, not of an if-expression inside it
  var stop = b
  var nested = 0
  var d = 0
  let tryLike = t0.text in ["try", "except"]
  let ifLike = valueIf or t0.text in ["if", "elif", "when"]
  for k in hdrEnd + 1 ..< b:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkKw:
      if t.text in ["if", "when", "case", "try"]: inc nested
      elif (tryLike and t.text in ["except", "finally"]) or (ifLike and t.text in ["elif", "else"]):
        if nested > 0:
          if t.text == "else" or t.text == "finally": dec nested
        else:
          stop = k
          break
  (hdrEnd, stop)

proc fSplitStatement*(l: FLine): (seq[FTok], seq[FTok], seq[FTok]) =
  ## `if a: b else: c` → header `if a:`, body `b`, rest `else: c` (empty body when nothing follows)
  let (hdrEnd, stop) = fSplitIdx(l.toks, 0, l.toks.len)
  if hdrEnd < 0: return (l.toks, @[], @[])
  (l.toks[0 .. hdrEnd], l.toks[hdrEnd + 1 ..< stop], l.toks[stop .. ^1])

proc fInlineIf*(toks: openArray[FTok], a, b: int): bool =
  ## `if a: x else: y` with plain values: nph keeps it on one line
  let (h, _) = fSplitIdx(toks, a, b)
  if h < 0: return false
  var d = 0
  var hasElse = false
  for k in h + 1 ..< b:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkKw and t.text == "else": hasElse = true
  hasElse and fSimpleTail(toks.toOpenArray(0, b - 1), h + 1)

proc fFormat*(text: string, err: var string): string

proc fValueEq*(toks: openArray[FTok]): bool =
  ## does the line end with the `=` of an assignment (its value follows on the next line)?
  var k = toks.high
  while k > 0 and toks[k].kind == fkComment: dec k
  if k < 1 or toks[k].kind != fkOp or toks[k].text != "=": return false
  if toks[0].kind == fkKw and toks[0].text in FRoutineKw: return false
  var d = 0
  for j in 0 ..< k:
    let t = toks[j]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkKw and t.text in FRoutineKw: return false     # a lambda's body follows
  true

proc fValueIf*(toks: openArray[FTok]): int =
  ## `x = if a: f() else: g()` whose branches are not plain values: the index of its `=`, or -1
  if toks.len < 4 or (toks[0].kind == fkKw and (toks[0].text in FRoutineKw or toks[0].text in FBlockKw)):
    return -1
  let eq = fTopEq(toks, 0, toks.len)
  if eq < 0 or eq + 2 >= toks.len or toks[eq + 1].kind != fkKw or toks[eq + 1].text notin ["if", "when"]: return -1
  let (h, _) = fSplitIdx(toks, 0, toks.len)
  if h < 0 or fInlineIf(toks, eq + 1, toks.len): return -1
  eq

proc fKeepInline*(toks: openArray[FTok]): bool =
  ## `if a: x else: y` and `v = if a: x else: y` with plain values stay on one line (like nph)
  if toks.len == 0: return false
  let t0 = toks[0]
  if t0.kind == fkKw and t0.text in ["if", "when"]: return fInlineIf(toks, 0, toks.len)
  if t0.kind == fkKw and (t0.text in FBlockKw or t0.text in FRoutineKw): return false
  let eq = fTopEq(toks, 0, toks.len)
  eq >= 0 and eq + 1 < toks.len and toks[eq + 1].kind == fkKw and toks[eq + 1].text in ["if", "when"] and
    fInlineIf(toks, eq + 1, toks.len)

proc fTypeMemberComplex*(l: FLine): bool =
  for t in l.toks:
    if t.kind == fkKw and t.text in ["object", "enum"]: return true
  false

proc fTransform*(lines: seq[FLine]): seq[FOut] =
  ## split one-line blocks, collapse one-member sections, put enum values one per line
  var i = 0
  var typeDepth = -1            # inside a type section: its depth (+1 for members)
  var enumDepth = -1
  var work = lines
  # a statement followed by a single `## doc` line under it: the comment joins the statement (like
  # nph; it moves back under the statement when the line gets too long)
  block:
    var joined: seq[FLine]
    var k = 0
    while k < work.len:
      var l = work[k]
      if not l.comment and not l.verbatim and l.phys == 1 and l.toks.len > 0 and
         l.toks[^1].kind != fkComment and not fOpensBlock(l) and
         not (l.toks[0].kind == fkKw and l.toks[0].text in FRoutineKw) and k + 1 < work.len:
        let c = work[k + 1]
        if c.comment and not c.blank and c.toks.len == 1 and c.depth > l.depth and
           c.toks[0].text.startsWith("##") and not c.toks[0].text.startsWith("##[") and
           (k + 2 >= work.len or (not work[k + 2].comment and work[k + 2].depth <= l.depth)):
          var t = c.toks[0]
          t.nl = false
          t.blanks = 0
          l.toks.add t
          joined.add l
          k += 2
          continue
      joined.add l
      inc k
    work = joined
  # sections with exactly one member (and nothing else) are written on one line
  var k = 0
  var res: seq[FLine]
  while k < work.len:
    template l: untyped = work[k]
    if not l.comment and l.toks.len == 1 and l.toks[0].kind == fkKw and l.toks[0].text in FSectionKw:
      var j = k + 1
      var members = 0
      var hasComment = false
      while j < work.len and (work[j].depth > l.depth or work[j].comment):
        if work[j].comment:
          if work[j].depth <= l.depth:
            # a comment at the section's own level ends it only when no member follows (comments end nothing)
            var q = j
            while q < work.len and work[q].comment: inc q
            if q >= work.len or work[q].depth <= l.depth: break
          hasComment = true
        elif work[j].depth == l.depth + 1: inc members
        inc j
      if members == 1 and not hasComment and k + 1 < work.len and work[k + 1].depth == l.depth + 1 and
         not work[k + 1].comment and not work[k + 1].verbatim:
        var merged = work[k + 1]
        merged.toks = @[l.toks[0]] & work[k + 1].toks
        merged.depth = l.depth
        merged.blank = l.blank
        res.add merged
        for m in k + 2 ..< j:
          var c = work[m]
          c.depth -= 1
          res.add c
        k = j
        continue
    res.add move(work[k])
    inc k
  work = move(res)
  # import blocks: one module (or std/[…] group) per line, a comma after all but the last
  res = @[]
  var importDepth = -1
  for li in 0 ..< work.len:
    template l: untyped = work[li]
    if not l.comment and importDepth >= 0 and l.depth <= importDepth: importDepth = -1
    if not l.comment and l.toks.len == 1 and l.toks[0].kind == fkKw and
       l.toks[0].text in ["import", "include", "export"]:
      importDepth = l.depth
      res.add move(work[li])
      continue
    if importDepth >= 0 and l.depth == importDepth + 1 and not l.comment and not l.verbatim:
      var elems: seq[seq[FTok]]
      var cur: seq[FTok]
      var d = 0
      for t in l.toks:
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}: dec d
        if t.kind == fkComma and d == 0:
          cur.add t
          elems.add cur
          cur = @[]
        elif t.kind == fkComment and d == 0 and cur.len == 0 and elems.len > 0: elems[^1].add t
        else: cur.add t
      if cur.len > 0: elems.add cur
      for ei, e in elems:
        var nl = l
        nl.toks = e
        nl.blank = l.blank and ei == 0
        nl.origText = "import"                     # marks the line as module paths
        res.add nl
      continue
    res.add move(work[li])
  work = move(res)
  # case branches indented under `case` move to its level (like nph); a case whose branches all are
  # one-liners with plain values keeps them inline, otherwise every branch body goes on its own line
  var shifts: seq[int]
  var inlineBranch = newSeq[bool](work.len)
  for idx in 0 ..< work.len:
    template l: untyped = work[idx]
    while shifts.len > 0 and l.depth <= shifts[^1] and not l.comment: shifts.setLen(shifts.len - 1)
    var sh = 0
    for x in shifts:
      if l.depth > x: inc sh
    work[idx].depth -= sh
    if l.comment or l.toks[0].kind != fkKw or l.toks[0].text != "case": continue
    var j = idx + 1
    while j < work.len and work[j].comment: inc j
    if j >= work.len: continue
    let bt = work[j].toks[0]
    if not (bt.kind == fkKw and bt.text in ["of", "elif", "else"]) or work[j].depth notin [l.depth, l.depth + 1]:
      continue
    let bd = work[j].depth
    if bd == l.depth + 1: shifts.add l.depth
    var trivial = true
    var branches: seq[int]
    j = idx + 1
    while j < work.len:
      let m = work[j]
      if m.comment:
        if m.depth >= bd: trivial = false
        inc j
        continue
      if m.depth < bd: break
      if m.depth > bd:
        trivial = false
        inc j
        continue
      let mt = m.toks[0]
      if not (mt.kind == fkKw and mt.text in ["of", "elif", "else"]): break
      branches.add j
      let (h, stop) = fSplitIdx(m.toks, 0, m.toks.len)
      if h < 0 or stop < m.toks.len or m.toks[^1].kind == fkComment or m.verbatim or
         not fSimpleTail(m.toks, h + 1):
        trivial = false
      inc j
    if trivial:
      for b in branches: inlineBranch[b] = true
  i = 0
  while i < work.len:
    template l: untyped = work[i]
    # where are we: in a type section (members at depth+1), an enum body?
    if not l.comment:
      if typeDepth >= 0 and l.depth <= typeDepth: typeDepth = -1
      if enumDepth >= 0 and l.depth <= enumDepth: enumDepth = -1
    var o = FOut(depth: l.depth, toks: l.toks, blank: l.blank, comment: l.comment, verbatim: l.verbatim,
                 origText: l.origText, importish: l.origText == "import")
    if l.comment or l.verbatim:
      result.add o
      inc i
      continue
    let t0 = l.toks[0]
    let inType = typeDepth >= 0 and l.depth > typeDepth
    # a value on its own line after `x =` (not a routine body): an expression, never split
    var pc = i - 1
    while pc >= 0 and work[pc].comment: dec pc
    if pc >= 0 and l.depth == work[pc].depth + 1 and fValueEq(work[pc].toks):
      o.exprLine = true
    if t0.kind == fkKw and t0.text == "type":
      typeDepth = l.depth
      o.complexKind = 2
      if l.toks.len > 1 and fTypeMemberComplex(l): o.complexKind = 2
    if inType and l.depth == typeDepth + 1 and fTypeMemberComplex(l): o.complexKind = 3
    if t0.kind == fkKw and t0.text == "type" and l.toks.len > 1 and fTypeMemberComplex(l): o.complexKind = 2
    # enum values: one per line
    let isEnumLine = enumDepth >= 0 and l.depth == enumDepth + 1
    var enumAt = -1
    for k2, t in l.toks:
      if t.kind == fkKw and t.text == "enum": enumAt = k2
    if enumAt >= 0 and (inType or t0.text == "type"):
      enumDepth = l.depth
      if enumAt < l.toks.high and l.toks[enumAt + 1].kind != fkComment:
        o.toks = l.toks[0 .. enumAt]
        result.add o
        var vals: seq[seq[FTok]]
        var curv: seq[FTok]
        var d = 0
        for t in l.toks[enumAt + 1 .. ^1]:
          if t.kind in {fkOpen, fkPragOpen}: inc d
          elif t.kind in {fkClose, fkPragClose}: dec d
          if t.kind == fkComma and d == 0:
            vals.add curv
            curv = @[]
          elif t.kind == fkComment and curv.len == 0 and vals.len > 0 and not t.nl: vals[^1].add t
          else: curv.add t
        if curv.len > 0: vals.add curv
        for v in vals: result.add FOut(depth: l.depth + 1, toks: v)
        inc i
        continue
      result.add o
      inc i
      continue
    if isEnumLine and not l.comment:
      var vals: seq[seq[FTok]]
      var curv: seq[FTok]
      var d = 0
      for t in l.toks:
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}: dec d
        if t.kind == fkComma and d == 0:
          vals.add curv
          curv = @[]
        elif t.kind == fkComment and curv.len == 0 and vals.len > 0 and not t.nl: vals[^1].add t
        else: curv.add t
      if curv.len > 0: vals.add curv
      for vi, v in vals:
        result.add FOut(depth: l.depth, toks: v, blank: (if vi == 0: l.blank else: false))
      inc i
      continue
    # one-line blocks become two lines (object branches inside types keep their fields inline); an
    # if-expression value gets one branch per line
    let ifExpr = o.exprLine and t0.kind == fkKw and t0.text in ["if", "when"]
    var splitHere = not inType and (not o.exprLine or ifExpr)
    if splitHere and (fKeepInline(l.toks) or inlineBranch[i]): splitHere = false
    if inType:
      let (_, body0, _) = fSplitStatement(l)
      splitHere = body0.len > 0 and body0[0].kind == fkKw and body0[0].text in ["discard", "nil"]
    if splitHere:
      var pending = @[(l.toks, l.depth, l.blank)]
      var first = true
      while pending.len > 0:
        let (toks, dep, blnk) = pending[0]
        pending.delete(0)
        let veq = fValueIf(toks)
        if veq >= 0:
          # x = if a: f() else: g()  →  x = ⏎ if a: ⏎ f() ⏎ else: ⏎ g()
          result.add FOut(depth: dep, toks: toks[0 .. veq], blank: blnk and first,
                          complexKind: (if first: o.complexKind else: 0), importish: o.importish)
          first = false
          pending.insert((toks[veq + 1 .. ^1], dep + 1, false), 0)
          continue
        if not first and fKeepInline(toks):
          result.add FOut(depth: dep, toks: toks, importish: o.importish)
          continue
        let (hdr, body, rest) = fSplitStatement(FLine(toks: toks, depth: dep))
        var oo = FOut(depth: dep, toks: hdr, blank: blnk and first, complexKind: (if first: o.complexKind else: 0),
                      importish: o.importish, exprLine: o.exprLine and not ifExpr)
        if hdr[0].kind == fkKw and hdr[0].text in FRoutineKw and hdr[0].text notin ["func"]:
          if body.len > 0 or (i + 1 < work.len and work[i + 1].depth > l.depth): oo.complexKind = 1
        result.add oo
        first = false
        if body.len > 0:
          let (h2, b2, r2) = fSplitStatement(FLine(toks: body, depth: dep + 1))
          if (b2.len > 0 and not fKeepInline(body)) or fValueIf(body) >= 0:
            pending.insert((body, dep + 1, false), 0)
          else: result.add FOut(depth: dep + 1, toks: body)
          discard h2
          discard r2
        if rest.len > 0: pending.add (rest, dep, false)
      # `else: static:` ⏎ body — the body now sits under the last piece
      let shift = result[^1].depth - l.depth
      if shift != 0 and fOpensBlock(l):
        var j = i + 1
        while j < work.len and (work[j].depth > l.depth or (work[j].comment and work[j].depth == l.depth + 1)):
          work[j].depth += shift
          inc j
      inc i
      continue
    result.add o
    inc i

proc fWrapGroup*(prefix: seq[FTok], inner: seq[FTok], suffix: seq[FTok], ind: int, innerInd: int,
                onePerLine: bool, params = false, importish = false): seq[string] =
  ## prefix( ⏎ inner ⏎ )suffix   — inner packed on lines (or one element per line, with a trailing comma)
  var elems: seq[seq[FTok]]
  var cur: seq[FTok]
  var d = 0
  var hasComment = false
  var typed = false
  for t in inner:
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    if d == 0 and (t.kind == fkColon or (t.kind == fkOp and t.text == "=")): typed = true
    if d == 0 and t.kind in {fkComma, fkSemi} and params and not typed and t.kind == fkComma:
      cur.add t                                     # a, b: int  — one parameter group
    elif d == 0 and t.kind in {fkComma, fkSemi}:
      if t.kind == fkSemi and not params: return @[]          # (a; b): statements, kept as written
      # (`a; b = 1`: the `;` stays when the part before it has no type or default — a `,` would give it b's)
      cur.add (if t.kind == fkSemi and not typed: t else: FTok(kind: fkComma, text: ","))
      elems.add cur
      cur = @[]
      typed = false
    elif t.kind == fkComment and d == 0 and cur.len == 0:
      hasComment = true
      if elems.len > 0 and not t.nl: elems[^1].add t   # a comment after an element's comma stays with it
      else: elems.add @[t]                           # a comment on its own line
    elif t.kind == fkComment:
      hasComment = true
      cur.add t
    else:
      if cur.len > 0 and cur[^1].kind == fkComment: return @[]   # a comment inside an element: keep the layout
      cur.add t
  if cur.len > 0: elems.add cur
  if elems.len == 0: return @[]
  # every element ends with a comma (the last one gets a trailing comma when the list takes several lines)
  # (never in `(x)`: `(x,)` would be a tuple — and `(x,)` is left as written)
  var codeElems = 0
  for e in elems:
    if e.len > 0 and e[0].kind != fkComment: inc codeElems
  let parenOne = codeElems == 1 and prefix.len > 0 and prefix[^1].text == "(" and
                 not fCallParen(prefix, prefix.high)
  if parenOne:
    for e in elems:
      var k = e.high
      while k >= 0 and e[k].kind == fkComment: dec k
      if k >= 0 and e[0].kind != fkComment and e[k].kind == fkComma: return @[]
  if elems[^1].len > 0 and elems[^1][0].kind != fkComment and not parenOne:
    var k = elems[^1].high
    while k >= 0 and elems[^1][k].kind == fkComment: dec k
    if k >= 0 and elems[^1][k].kind != fkComma: elems[^1].insert(FTok(kind: fkComma, text: ","), k + 1)
  # nph packs simple elements (names, literals, a.b) and gives anything else a line of its own
  var allSimple = true
  for e in elems:
    var dd = 0
    for t in e:
      if t.kind in {fkOpen, fkPragOpen}:
        allSimple = false
      elif dd == 0 and (t.kind == fkColon or (t.kind == fkOp and t.text == "=")):
        allSimple = false
  let forced = onePerLine
  let onePerLine = onePerLine or not allSimple
  let pad = spaces(innerInd)
  result.add spaces(ind) & fRender(prefix, importish = importish)
  var lines: seq[string]
  let single = block:
    var s = pad
    for k, e in elems:
      var ee = e
      if k == elems.high and ee.len > 0 and ee[^1].kind == fkComma: ee.setLen(ee.len - 1)
      s.add (if k > 0: " " else: "") & fRender(ee, importish = importish)
    s
  if not hasComment and not forced and single.len <= FmtMax:
    lines.add single
  elif onePerLine or hasComment:
    for e in elems:
      let r = pad & fRender(e, importish = importish)
      let colon = fTop(e, proc(t: FTok, d: int): bool = t.kind == fkColon)
      if r.len > FmtMax and colon == 1 and e[0].kind == fkIdent and colon < e.high - 1:
        # key: a long value  →  key: ⏎ value (and a long `&` chain one piece per line)
        lines.add pad & fRender(e[0 .. colon], importish = importish)
        let vpad = spaces(innerInd + 2)
        var acc: seq[FTok]
        let value = e[colon + 1 .. ^1]
        if (vpad & fRender(value)).len <= FmtMax:
          lines.add vpad & fRender(value)
        else:
          var dd = 0
          for t in value:
            acc.add t
            if t.kind in {fkOpen, fkPragOpen}: inc dd
            elif t.kind in {fkClose, fkPragClose}: dec dd
            elif dd == 0 and t.kind == fkOp and t.text == "&":
              lines.add vpad & fRender(acc)
              acc = @[]
          if acc.len > 0: lines.add vpad & fRender(acc)
      else: lines.add r
  else:
    var line = pad
    for e in elems:
      let r = fRender(e, importish = importish)
      if line.len > pad.len and line.len + 1 + r.len > FmtMax:
        lines.add line
        line = pad & r
      else: line.add (if line.len > pad.len: " " else: "") & r
    if line.len > pad.len: lines.add line
  result.add lines
  result.add spaces(ind) & fRender(suffix, importish = importish)

proc fKeepGroup*(prefix, inner, suffix: seq[FTok], ind, innerInd: int, importish = false): seq[string] =
  ## a list laid out as you wrote it (nim.format.* "keep"): each element stays on the line it was on — only the
  ## indentation and the spaces are tidied
  for t in prefix:
    if t.kind == fkComment: return @[]
  var rows: seq[(int, seq[FTok])] = @[(ind, prefix)]
  for t in inner:
    if t.nl: rows.add (innerInd, @[t])
    else: rows[^1][1].add t
  if suffix.len > 0 and suffix[0].nl: rows.add (ind, suffix)
  else:
    if rows[^1][1].len > 0 and rows[^1][1][^1].kind == fkComment: return @[]
    rows[^1][1].add suffix
  for (i, r) in rows: result.add spaces(i) & fRender(r, importish = importish)

proc fListKind*(toks: openArray[FTok], open: int): int =
  ## what the bracket at `open` holds: 0 parameters (`proc(…)`) · 1 call arguments · 2 a literal (array, seq,
  ## table, set, tuple) · 3 an index or generic arguments (`a[i]`, `Table[K, V]`)
  let t = toks[open]
  if open > 0 and toks[open - 1].kind == fkKw and toks[open - 1].text in FRoutineKw: return 0
  if t.text == "(": return (if fCallParen(toks, open): 1 else: 2)
  if t.text == "[" and open > 0 and not t.sp and toks[open - 1].kind in {fkIdent, fkClose}: return 3
  2

proc fListMode*(kind: int): FWrap =
  case kind
  of 0: FmtParams
  of 1: FmtArgs
  of 3: (if FmtArgs == fwKeep: fwKeep else: fwFit)     # (an index or generic is never one-per-line)
  else: FmtColl

proc fListAt*(toks: seq[FTok]): (int, int, int) =
  ## the list a statement's layout settings apply to — a routine header's parameters, else the bracket group the
  ## line ends with: (open, close, fListKind), or (-1, -1, -1)
  result = (-1, -1, -1)
  if toks.len < 3: return
  let t0 = toks[0]
  var open = -1
  var d = 0
  if t0.kind == fkKw and t0.text in FRoutineKw:
    for k, t in toks:
      if t.kind == fkOpen and t.text == "(" and d == 0 and k >= 2:
        open = k
        break
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
    if open < 0: return
  else:
    for k, t in toks:
      if t.kind == fkOpen and d == 0 and k > 0:
        var dd = 0
        var close = -1
        for j in k ..< toks.len:
          let u = toks[j]
          if u.kind in {fkOpen, fkPragOpen}: inc dd
          elif u.kind in {fkClose, fkPragClose}:
            dec dd
            if dd == 0:
              close = j
              break
        if close > k + 1:
          var tail = 0
          for j in close + 1 ..< toks.len: tail += toks[j].text.len + 1
          if tail <= 30: open = k
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
    if open <= 0: return
    # (not a target before `=`: `let (a, b) = …`, `x[i] = …`)
    let eq = fTopEq(toks, 0, toks.len)
    if eq >= 0 and open < eq: return
  d = 0
  for k in open ..< toks.len:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}:
      dec d
      if d == 0:
        return (open, k, (if t0.kind == fkKw and t0.text in FRoutineKw: 0 else: fListKind(toks, open)))

proc fListCount*(inner: openArray[FTok], params: bool): int =
  ## the elements of a list (parameters count per group: `a, b: int` is one)
  var d = 0
  var typed = false
  var any = false
  for t in inner:
    if t.kind == fkComment: continue
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    if d == 0 and (t.kind == fkColon or (t.kind == fkOp and t.text == "=")): typed = true
    if d == 0 and (t.kind == fkSemi or (t.kind == fkComma and (typed or not params))):
      if any: inc result
      any = false
      typed = false
    elif t.kind != fkComma: any = true
  if any: inc result

proc fListLayout*(o: FOut, fits: bool): seq[string] =
  ## the "always" and "keep" layouts of nim.format.params / arguments / collections ("fit" and "onePerLine" only
  ## change lines that are too long — fRenderLine)
  let (open, close, kind) = fListAt(o.toks)
  if open <= 0 or close <= open + 1: return
  let mode = fListMode(kind)
  if mode notin {fwAlways, fwKeep} or o.importish: return
  if o.toks[0].kind == fkKw and o.toks[0].text in ["import", "include", "export", "from"]: return
  for k, t in o.toks:
    if t.kind == fkComment and (k < open or (k > close and k < o.toks.high)): return
    # (keep: comments inside the list are laid out as in "fit" — a comment ends its line)
    if t.kind == fkComment and mode == fwKeep and k < o.toks.high: return
  let ind = o.depth * 2
  let t0 = o.toks[0]
  let routine = t0.kind == fkKw and t0.text in FRoutineKw
  let hasBody = o.toks[^1].kind == fkOp and o.toks[^1].text == "="
  let innerInd = if routine: ind + (if hasBody: 4 else: 2) else: ind + 2
  let inner = o.toks[open + 1 ..< close]
  if mode == fwAlways:
    if kind == 3 or fListCount(inner, kind == 0) < 2: return
    # (not in a condition or a loop header: `if f(⏎ a, ⏎ b ⏎ ):` reads worse than any long line)
    if not routine and t0.kind == fkKw and t0.text in ["if", "elif", "while", "when", "case", "of", "for"]: return
    return fWrapGroup(o.toks[0 .. open], inner, o.toks[close .. ^1], ind, innerInd, true, params = kind == 0,
                      importish = o.importish)
  var multi = o.toks[close].nl
  for t in inner:
    if t.nl: multi = true
  if multi: return fKeepGroup(o.toks[0 .. open], inner, o.toks[close .. ^1], ind, innerInd, o.importish)

proc fParamSemis*(toks: seq[FTok]): seq[FTok] =
  ## `a, b: int; c: string` → `…, c: string` in a routine's parameters (same meaning when the part
  ## before the `;` has a type or a default)
  result = toks
  var stack: seq[(int, bool)]       # (open index, is a parameter list)
  var segHasType = false
  for k in 0 ..< result.len:
    let t = result[k]
    if t.kind in {fkOpen, fkPragOpen}:
      let isParams = t.text == "(" and k >= 1 and
        ((result[k - 1].kind == fkKw and result[k - 1].text in FRoutineKw) or
         (k >= 2 and result[k - 2].kind == fkKw and result[k - 2].text in FRoutineKw) or
         (k >= 3 and result[k - 3].kind == fkKw and result[k - 3].text in FRoutineKw and result[k - 1].kind == fkOp))
      stack.add (k, isParams)
      segHasType = false
    elif t.kind in {fkClose, fkPragClose}:
      if stack.len > 0: stack.setLen(stack.len - 1)
    elif stack.len > 0 and stack[^1][1]:
      if t.kind in {fkColon} or (t.kind == fkOp and t.text == "="): segHasType = true
      elif t.kind == fkComma: discard
      elif t.kind == fkSemi:
        if segHasType: result[k] = FTok(kind: fkComma, text: ",", col: t.col, nl: t.nl, sp: t.sp, pos: t.pos)
        segHasType = false

proc fDropTrailing*(toks: seq[FTok]): seq[FTok] =
  ## without trailing commas — except in `(x,)`, where the comma makes a one-element tuple
  var groups: seq[(string, int)]
  for k in 0 ..< toks.len:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: groups.add ((if fCallParen(toks, k): "call" else: t.text), 0)
    elif t.kind in {fkClose, fkPragClose}:
      if groups.len > 0: groups.setLen(groups.len - 1)
    elif t.kind == fkComma and groups.len > 0:
      if k + 1 < toks.len and toks[k + 1].kind == fkClose:
        if not (groups[^1][0] == "(" and groups[^1][1] == 0): continue
      else: inc groups[^1][1]
    result.add t

proc fAsWritten*(o: FOut): seq[string] =
  ## what cannot be wrapped stays on one (long) line — broken only after comments inside it
  var cur: seq[FTok]
  var extra = 0
  for k, t in o.toks:
    cur.add t
    if t.kind == fkComment and k < o.toks.high:
      result.add spaces(o.depth * 2 + extra) & fRender(cur, importish = o.importish)
      cur = @[]
      extra = 4
  if cur.len > 0: result.add spaces(o.depth * 2 + extra) & fRender(cur, importish = o.importish)

proc fRenderLine*(o0: FOut, lines: seq[string]): seq[string] =
  ## the output lines of one statement: on one line when it fits, wrapped like nph when not
  var hasSemi, hasTrailing = false
  for k, t in o0.toks:
    if t.kind == fkSemi: hasSemi = true
    if t.kind in {fkComma, fkSemi} and k < o0.toks.high and o0.toks[k + 1].kind == fkClose: hasTrailing = true
  var o: FOut
  if hasSemi:
    o = o0
    o.toks = fParamSemis(o.toks)
  else:
    o = FOut(depth: o0.depth, comment: o0.comment, importish: o0.importish, exprLine: o0.exprLine,
             complexKind: o0.complexKind)
    o.toks = o0.toks            # shares the tokens (refs): no copy of the line
  # (trailing commas go, and come back wherever a list is laid out one per line: the next run decides alike)
  if hasTrailing and not o.comment: o.toks = fDropTrailing(o.toks)
  let ind = o.depth * 2
  let pad = spaces(ind)
  if o.comment:
    var s = ""
    for t in o.toks:
      s.add (if s.len > 0: " " else: "") & t.text
    return @[pad & s]
  let one = pad & fRender(o.toks, importish = o.importish)
  var hasInnerComment = false
  for k, t in o.toks:
    if t.kind == fkComment and k < o.toks.high: hasInnerComment = true
  if FmtParams != fwFit or FmtArgs != fwFit or FmtColl != fwFit:
    let r = fListLayout(o, one.len <= FmtMax and not hasInnerComment)
    if r.len > 0: return r
  if one.len <= FmtMax and not hasInnerComment:
    # a trailing comma before the closing bracket goes away on one line
    if not hasTrailing: return @[one]
    return @[pad & fRender(fDropTrailing(o.toks), importish = o.importish)]
  let t0 = o.toks[0]
  # a long declaration with several names: the names, then the type (and value) under them (like nph) — but
  # not for a trailing comment's sake: when the code fits without it, the comment goes under it (below)
  if not hasInnerComment:
    let cpos = fTopColon(o.toks, 0, o.toks.len)
    let codeToks = if o.toks[^1].kind == fkComment: o.toks[0 ..< o.toks.high] else: o.toks
    let codeLen = (pad & fRender(fDropTrailing(codeToks), importish = o.importish)).len
    if cpos > 0 and cpos < o.toks.high and o.toks[cpos + 1].kind != fkComment and fNamesHead(o.toks, cpos) and
       codeLen > FmtMax:
      let head = pad & fRender(o.toks[0 .. cpos], importish = o.importish)
      let rest = pad & "  " & fRender(o.toks[cpos + 1 .. ^1], importish = o.importish)
      if head.len <= FmtMax and rest.len <= FmtMax: return @[head, rest]
  # a trailing comment that does not fit: on the next line, under the statement (like nph)
  if o.toks.len > 1 and o.toks[^1].kind == fkComment and not hasInnerComment and
     not o.toks[^1].text.startsWith("#["):
    var o2 = o
    o2.toks = o.toks[0 ..< o.toks.high]
    let code = fRenderLine(o2, @[pad & fRender(o2.toks, importish = o.importish)])
    return code & @[pad & "  " & o.toks[^1].text]
  # a long `from x import a, b`: the names on the next line (like nph)
  if t0.kind == fkKw and t0.text == "from" and not hasInnerComment:
    var imp = -1
    for k, t in o.toks:
      if t.kind == fkKw and t.text == "import":
        imp = k
        break
    if imp > 0 and imp < o.toks.high:
      let names = spaces(ind + 2) & fRender(o.toks[imp + 1 .. ^1], importish = true)
      if names.len <= FmtMax:
        return @[pad & fRender(o.toks[0 .. imp], importish = true), names]
  # a long import: one module per line under `import`
  if t0.kind == fkKw and t0.text in ["import", "include", "export"] and o.toks.len > 1 and not hasInnerComment:
    var elems: seq[seq[FTok]]
    var cur: seq[FTok]
    var d = 0
    for t in o.toks[1 .. ^1]:
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
      if t.kind == fkComma and d == 0:
        elems.add cur
        cur = @[]
      else: cur.add t
    if cur.len > 0: elems.add cur
    var outp = @[pad & t0.text]
    for ei, e in elems:
      let comma = if ei < elems.high: "," else: ""
      let line = spaces(ind + 2) & fRender(e, importish = true) & comma
      var open = -1
      for k, t in e:
        if t.kind == fkOpen:
          open = k
          break
      if line.len > FmtMax and open > 0 and e[^1].kind == fkClose:
        let w = fWrapGroup(e[0 .. open], e[open + 1 ..< e.high], @[e[^1]], ind + 2, ind + 4, false, importish = true)
        if w.len > 0:
          for k, x in w: outp.add (if k == w.high: x & comma else: x)
          continue
      outp.add line
    return outp
  # a long assignment whose value fits on a line of its own: the value goes there (like nph)
  if not hasInnerComment and not (t0.kind == fkKw and t0.text in FRoutineKw):
    let eq = fTopEq(o.toks, 0, o.toks.len)
    # (not when the line opens a block: `x = if a:`, `let f = proc() =` — their bodies stay where they are)
    let opensBlock = o.toks[^1].kind == fkColon or (o.toks[^1].kind == fkOp and o.toks[^1].text == "=") or
                     (o.toks[^1].kind == fkKw and o.toks[^1].text in ["object", "enum", "tuple", "concept"])
    # (not a lambda's `=`, and not a try/case/block value: those stay as they are)
    var lambda = false
    var dd = 0
    for k in 0 ..< max(eq, 0):
      let t = o.toks[k]
      if t.kind in {fkOpen, fkPragOpen}: inc dd
      elif t.kind in {fkClose, fkPragClose}: dec dd
      elif dd == 0 and t.kind == fkKw and t.text in FRoutineKw: lambda = true
    let stmtValue = eq >= 0 and eq < o.toks.high and o.toks[eq + 1].kind == fkKw and
                    o.toks[eq + 1].text in FBlockKw and o.toks[eq + 1].text notin ["if", "when"]
    # (and only when `x =` itself fits: otherwise the next run would wrap it again — not idempotent)
    # (nor a list whose layout is "one per line": it breaks itself)
    var ownList = false
    if FmtArgs == fwOnePerLine or FmtColl == fwOnePerLine:
      let (lo, _, lk) = fListAt(o.toks)
      ownList = lo == eq + 1 + int(eq + 1 < o.toks.high and o.toks[eq + 1].kind == fkOp and o.toks[eq + 1].text == "@") and
                fListMode(lk) == fwOnePerLine
    if eq > 0 and eq < o.toks.high and o.toks[^1].kind != fkComment and not opensBlock and not lambda and
       not stmtValue and not ownList and (pad & fRender(o.toks[0 .. eq])).len <= FmtMax:
      let value = pad & spaces(2) & fRender(fDropTrailing(o.toks[eq + 1 .. ^1]))
      if value.len <= FmtMax:
        return @[pad & fRender(o.toks[0 .. eq]), value]
      # a long `a or b` value: on its own lines under the `=`
      var d = 0
      var logic = false
      for k in eq + 1 ..< o.toks.len:
        let t = o.toks[k]
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}: dec d
        elif d == 0 and t.kind == fkKw and t.text in ["and", "or"]: logic = true
      if logic:
        let sub = fRenderLine(FOut(depth: o.depth + 1, toks: o.toks[eq + 1 .. ^1], exprLine: true), @[value])
        return @[pad & fRender(o.toks[0 .. eq])] & sub
  # a routine header: its parameters, indented 4, then  ): T =
  if t0.kind == fkKw and t0.text in FRoutineKw:
    var open = -1
    var d = 0
    for k, t in o.toks:
      if t.kind == fkOpen and t.text == "(" and d == 0 and k >= 2:
        open = k
        break
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
    if open > 0:
      var close = -1
      d = 0
      for k in open ..< o.toks.len:
        let t = o.toks[k]
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}:
          dec d
          if d == 0:
            close = k
            break
      if close > open + 1:
        # `;` between typed parameters reads as `,`
        var inner = o.toks[open + 1 ..< close]
        # with a body the parameters sit 4 deeper (apart from the body), in a forward declaration 2
        let hasBody = o.toks[^1].kind == fkOp and o.toks[^1].text == "="
        let pind = ind + (if hasBody: 4 else: 2)
        if FmtParams != fwKeep:        # (keep: a header written on one line stays on one line)
          if FmtParams == fwFit:
            let res1 = fWrapGroup(o.toks[0 .. open], inner, o.toks[close .. ^1], ind, pind, false, params = true)
            if res1.len == 3 and res1[1].len <= FmtMax: return res1
          return fWrapGroup(o.toks[0 .. open], inner, o.toks[close .. ^1], ind, pind, true, params = true)
  # a long expression: break after its loosest operator (or, and, comparisons, &, + -) where the next
  # operand no longer fits — 4 deeper in a condition, 2 elsewhere, not at all for a value that already
  # stands on its own line — like nph
  if not hasInnerComment:
    let isCond = t0.kind == fkKw and t0.text in ["if", "elif", "while", "when"]
    let cind = ind + (if isCond: 4 elif o.exprLine: 0 else: 2)
    const classes = [@["or", "xor"], @["and"], @["==", "!=", "<", "<=", ">", ">=", "in", "notin", "is", "isnot"],
                     @["&"], @["+", "-"]]
    var segs: seq[seq[FTok]]
    for cls in classes:
      segs.setLen(0)
      var cur: seq[FTok]
      var d = 0
      for k, t in o.toks:
        cur.add t
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}: dec d
        elif d == 0 and t.text in cls and (t.kind == fkKw or t.kind == fkOp) and k > 0 and k < o.toks.high and
             fOperand(o.toks[k - 1]) and not (isCond and k == o.toks.high - 1):
          segs.add cur
          cur = @[]
      if cur.len > 0: segs.add cur
      if segs.len > 1: break
    if segs.len > 1:
      proc firstPart(sg: seq[FTok]): seq[FTok] =
        ## an operand up to its own first operator: what must fit for it to start on this line
        var dd = 0
        for k, t in sg:
          if dd == 0 and k > 0 and (t.kind == fkOp or fWordOp(t)) and k == sg.high: return
          result.add t
          if t.kind in {fkOpen, fkPragOpen}: inc dd
          elif t.kind in {fkClose, fkPragClose}: dec dd
          elif dd == 0 and k > 0 and k < sg.high and (t.kind == fkOp or fWordOp(t)):
            return
      var outp: seq[string]
      var acc: seq[FTok]
      var lead = pad
      for sg in segs:
        if acc.len > 0:
          let trial = lead & fRender(acc & firstPart(sg))
          if trial.len > FmtMax:
            outp.add lead & fRender(acc)
            lead = spaces(cind)
            acc = @[]
        acc.add sg
      if acc.len > 0: outp.add lead & fRender(acc)
      if outp.len > 1: return outp
  # a command with a long argument list:  echo a, ⏎ b, c …  (nph keeps the first argument up top)
  if t0.kind == fkIdent and o.toks.len > 2 and o.toks[1].sp and o.toks[1].kind in {fkIdent, fkNum, fkStr, fkChar} and
     not hasInnerComment:
    var elems: seq[seq[FTok]]
    var cur: seq[FTok]
    var d = 0
    for t in o.toks[1 .. ^1]:
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
      cur.add t
      if d == 0 and t.kind == fkComma:
        elems.add cur
        cur = @[]
    if cur.len > 0: elems.add cur
    var keepBreaks = false
    if FmtArgs == fwKeep:
      for e in elems[1 .. ^1]:
        if e[0].nl: keepBreaks = true
    if elems.len > 1 and (FmtArgs != fwKeep or keepBreaks):
      var outp = @[pad & fRender(@[t0] & elems[0])]
      var line = spaces(ind + 2)
      for e in elems[1 .. ^1]:
        let r = fRender(e)
        let brk = case FmtArgs
                  of fwKeep: e[0].nl
                  of fwOnePerLine, fwAlways: true
                  else: line.len + 1 + r.len > FmtMax
        if keepBreaks and not e[0].nl and line.len == ind + 2:      # (the first ones go up with the command)
          outp[^1].add " " & r
        elif line.len > ind + 2 and brk:
          outp.add line
          line = spaces(ind + 2) & r
        else: line.add (if line.len > ind + 2: " " else: "") & r
      if line.len > ind + 2: outp.add line
      return outp
  # a call or bracket at the end of the line: its arguments on their own lines
  var open = -1
  var d = 0
  for k, t in o.toks:
    if t.kind == fkOpen and d == 0 and k > 0:
      # the last top-level group that is still open at the end, or closes near it
      var dd = 0
      var close = -1
      for j in k ..< o.toks.len:
        let u = o.toks[j]
        if u.kind in {fkOpen, fkPragOpen}: inc dd
        elif u.kind in {fkClose, fkPragClose}:
          dec dd
          if dd == 0:
            close = j
            break
      if close > k + 1:
        var tail = 0
        for j in close + 1 ..< o.toks.len: tail += o.toks[j].text.len + 1
        if tail <= 30: open = k
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
  if open > 0:
    var close = -1
    d = 0
    for k in open ..< o.toks.len:
      let t = o.toks[k]
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}:
        dec d
        if d == 0:
          close = k
          break
    let mode = if o.importish: fwFit else: fListMode(fListKind(o.toks, open))
    if mode != fwKeep:              # (keep: a list written on one line stays on one line)
      let r = fWrapGroup(o.toks[0 .. open], o.toks[open + 1 ..< close], o.toks[close .. ^1], ind, ind + 2,
                         mode in {fwOnePerLine, fwAlways}, importish = o.importish)
      if r.len > 0: return r
  # cannot wrap: as written (inner comments need their line breaks)
  if lines.len > 0: lines else: fAsWritten(o0)

proc fStructToks*(toks: openArray[FTok], a, b: int, base: int, res: var seq[int]) =
  ## block depth of each token of a statement: an inline body (`if a: b`, `proc f() = x`) and an
  ## inline section member or enum value list count one deeper, exactly as when written on their own lines
  if a >= b: return
  let (hdrEnd, stop) = fSplitIdx(toks, a, b)
  if hdrEnd >= 0:
    # the body of a section line's lambda (let f = proc() = x) sits under the section's member
    let sec = toks[a].kind == fkKw and toks[a].text in FSectionKw
    fStructToks(toks, a, hdrEnd + 1, base, res)
    fStructToks(toks, hdrEnd + 1, stop, base + 1 + ord(sec), res)
    fStructToks(toks, stop, b, base + ord(sec), res)
    return
  let t0 = toks[a]
  let isSection = t0.kind == fkKw and t0.text in FSectionKw and b - a > 1
  var afterEnum = false
  var d = 0
  for k in a ..< b:
    let t = toks[k]
    if t.kind == fkComment: continue
    # in an import path a run of operators counts once: `.. / x` or `../x` (two tokens, or one)
    if t.kind == fkOp and k > a and toks[k - 1].kind == fkOp and
       ((toks[0].kind == fkKw and toks[0].text in ["import", "include", "from", "export"]) or
        (toks[0].kind == fkOp and toks[0].text.startsWith("."))): continue
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    if t.kind == fkComma or (t.kind == fkSemi and d > 0):
      if d == 0: continue
      var m = k + 1
      while m < b and toks[m].kind == fkComment: inc m
      if m < b and toks[m].kind == fkClose: continue
    var lvl = base
    if isSection and k > a: lvl += 1
    if afterEnum: lvl += 1
    res.add lvl
    if t.kind == fkKw and t.text == "enum": afterEnum = true

proc fCodeToks*(toks: seq[FTok]): int =
  ## how many tokens are code (not comments)
  for t in toks:
    if t.kind != fkComment: inc result

proc fStructureOf*(lines: seq[FLine]): seq[int] =
  ## for every token: how deep it sits in blocks
  var adj: seq[(int, int)]        # (depth of a line, what its children add): one-line sections (`type X =
                                  # object`) +1, a value on the line after `x =` -1
  for l in lines:
    if l.comment: continue
    while adj.len > 0 and l.depth <= adj[^1][0]: adj.setLen(adj.len - 1)
    var base = l.depth
    for a in adj: base += a[1]
    let before = result.len
    fStructToks(l.toks, 0, l.toks.len, base, result)
    let t0 = l.toks[0]
    var delta = 0
    if fOpensBlock(l) and result.len > before:
      delta = result[^1] - base             # `else: static:` — the block opened last holds the children
    elif t0.kind == fkKw and t0.text in FSectionKw and fCodeToks(l.toks) > 1: inc delta    # (`const ## doc`: not one)
    if fValueEq(l.toks): dec delta
    if t0.kind == fkKw and t0.text == "case": dec delta          # its branches, if indented
    # `import` on its own line: the modules under it are part of that one statement
    if l.toks.len == 1 and t0.kind == fkKw and t0.text in ["import", "export", "include"]: dec delta
    adj.add (l.depth, delta)

type FCmpState* = object
  k*: int
  groups*: seq[(string, int)]     # open brackets: (text, commas seen in it)

proc fCmpNext*(toks: seq[FTok], st: var FCmpState): int =
  ## the next token that matters for "same code": not comments (doc comments do), not depth-0 commas,
  ## not trailing commas — except in `(x,)`, a one-element tuple
  while st.k < toks.len:
    let t = toks[st.k]
    inc st.k
    if t.kind == fkComment:
      if t.text.startsWith("##"): return st.k - 1
      continue
    if t.kind in {fkOpen, fkPragOpen}:
      st.groups.add ((if fCallParen(toks, st.k - 1): "call" else: t.text), 0)
    elif t.kind in {fkClose, fkPragClose}:
      if st.groups.len > 0: st.groups.setLen(st.groups.len - 1)
    if t.kind == fkComma or (t.kind == fkSemi and st.groups.len > 0):
      if st.groups.len == 0: continue
      var m = st.k
      while m < toks.len and toks[m].kind == fkComment: inc m
      if m < toks.len and toks[m].kind == fkClose:
        if not (st.groups[^1][0] == "(" and st.groups[^1][1] == 0): continue      # a trailing comma
      inc st.groups[^1][1]
    return st.k - 1
  -1

proc fParamSep*(toks: seq[FTok], k: int): bool =
  ## does a parameter (`name: T`, `a, b: T`, `name = x`) follow the separator at k?
  var m = k + 1
  while m + 1 < toks.len and toks[m].kind == fkComment: inc m
  while m + 1 < toks.len and toks[m].kind == fkIdent and toks[m + 1].kind == fkComma: m += 2
  if m < toks.len and toks[m].kind == fkClose and m > k + 1 and toks[m - 1].kind == fkComma: return true  # `a, b,)`
  m + 1 < toks.len and toks[m].kind == fkIdent and
    (toks[m + 1].kind in {fkColon, fkClose} or (toks[m + 1].kind == fkOp and toks[m + 1].text == "="))

proc fSameWords*(a, b: string): bool =
  ## the same words, however they are spaced
  var i, j = 0
  while true:
    while i < a.len and a[i] in Whitespace: inc i
    while j < b.len and b[j] in Whitespace: inc j
    if i >= a.len or j >= b.len: return i >= a.len and j >= b.len
    while i < a.len and j < b.len and a[i] notin Whitespace and b[j] notin Whitespace:
      if a[i] != b[j]: return false
      inc i
      inc j
    if (i < a.len and a[i] notin Whitespace) or (j < b.len and b[j] notin Whitespace): return false

proc fPrefixLike*(toks: seq[FTok], k: int): bool =
  ## an operator after an operand, with a space before it and none after: Nim reads it as a prefix
  ## (`echo -1` is echo(-1)) — the formatter must never change that
  if k == 0 or k + 1 >= toks.len or toks[k].nl: return false        # first on its line: a statement's start
  var p = k - 1
  while p > 0 and toks[p].kind == fkComment: dec p
  if not fOperand(toks[p]): return false
  let before = toks[k].sp or toks[k].nl
  let after = toks[k + 1].sp or toks[k + 1].nl
  before and not after

proc fInImport*(toks: seq[FTok], k: int): bool =
  ## is token k in an import / include / from statement? (one over several lines too: `import ⏎ a, ⏎ b/[c]`)
  var i = k
  while i > 0:
    if toks[i].nl:
      let p = toks[i - 1]
      if not (p.kind in {fkComma, fkOpen} or (p.kind == fkKw and p.text in ["import", "include", "from", "export"])):
        break
    dec i
  toks[i].kind == fkKw and toks[i].text in ["import", "include", "from", "export"]

proc fSameTokens*(a, b: seq[FTok]): bool =
  ## the same code: tokens in the same order — layout, comments, trailing commas, item commas and
  ## `;` vs `,` between parameters aside
  var sa, sb: FCmpState
  while true:
    let x = fCmpNext(a, sa)
    let y = fCmpNext(b, sb)
    if x < 0 or y < 0: return x < 0 and y < 0
    let tx = a[x]
    let ty = b[y]
    if tx.kind == fkComment or ty.kind == fkComment:
      # doc comments: the same words (a block one may move with its statement)
      if tx.kind != ty.kind: return false
      if not fSameWords(tx.text, ty.text):
        # a doc paragraph re-wrapped (nim.format.reflowDocComments): the same words over its lines
        proc docWords(t: string): seq[string] =
          if t.startsWith("##") and not t.startsWith("##["): t[2 .. ^1].splitWhitespace else: @[t]
        var wa = docWords(tx.text)
        var wb = docWords(ty.text)
        if not tx.text.startsWith("##") or tx.text.startsWith("##[") or wa.len == 0 or wb.len == 0: return false
        while wa != wb:
          if wa.len < wb.len and wb[0 ..< wa.len] == wa:
            let nx = fCmpNext(a, sa)
            if nx < 0 or a[nx].kind != fkComment or not a[nx].text.startsWith("##") or a[nx].text.startsWith("##["):
              return false
            wa.add docWords(a[nx].text)
          elif wb.len < wa.len and wa[0 ..< wb.len] == wb:
            let ny = fCmpNext(b, sb)
            if ny < 0 or b[ny].kind != fkComment or not b[ny].text.startsWith("##") or b[ny].text.startsWith("##["):
              return false
            wb.add docWords(b[ny].text)
          else: return false
    elif tx.text != ty.text:
      if tx.kind == fkOp and ty.kind == fkOp and fInImport(a, x) and fInImport(b, y):
        # an import path: `.. / x` written apart, `../x` together — the same characters
        var ca = tx.text
        var cb = ty.text
        while ca != cb:
          if ca.len < cb.len and cb.startsWith(ca):
            let nx = fCmpNext(a, sa)
            if nx < 0 or a[nx].kind != fkOp: return false
            ca.add a[nx].text
          elif cb.len < ca.len and ca.startsWith(cb):
            let ny = fCmpNext(b, sb)
            if ny < 0 or b[ny].kind != fkOp: return false
            cb.add b[ny].text
          else: return false
      elif not (tx.kind in {fkSemi, fkComma} and ty.kind in {fkSemi, fkComma} and fParamSep(a, x) and
                fParamSep(b, y)):
        return false
    elif tx.kind == fkOp and fPrefixLike(a, x) != fPrefixLike(b, y) and not (fInImport(a, x) and fInImport(b, y)):
      return false               # `echo -1` vs `echo - 1`: spacing decides what an operator applies to


proc fNormalize*(lines: var seq[FLine]) =
  ## what nph changes beyond layout, done before formatting (and checked against):
  ## `proc f: int` → `proc f(): int`, `a; b` → one statement per line, and a one-line routine's doc
  ## comment goes before its body (`proc f(): int = 1` ⏎ `## doc` → `proc f(): int =` ⏎ `## doc` ⏎ `1`)
  var res: seq[FLine]
  var idx = 0
  while idx < lines.len:
    let li = idx
    template l: untyped = lines[li]
    inc idx
    if not l.comment and not l.verbatim and l.toks[0].kind == fkKw and l.toks[0].text in FRoutineKw and
       idx < lines.len and lines[idx].comment and lines[idx].depth > l.depth and
       lines[idx].toks[0].text.startsWith("##"):
      let (h, stop) = fSplitIdx(l.toks, 0, l.toks.len)
      if h >= 0 and stop == l.toks.len and l.toks[^1].kind != fkComment:
        var hl = l
        hl.toks = l.toks[0 .. h]
        res.add hl
        while idx < lines.len and lines[idx].comment and lines[idx].depth > l.depth and
              lines[idx].toks[0].text.startsWith("##"):
          var c = lines[idx]
          c.depth = l.depth + 1
          res.add c
          inc idx
        var bl = l
        bl.toks = l.toks[h + 1 .. ^1]
        bl.depth = l.depth + 1
        bl.blank = false
        res.add bl
        continue
    res.add move(lines[li])
  lines = move(res)
  res = @[]
  for li in 0 ..< lines.len:
    var l = move(lines[li])
    if l.comment or l.verbatim:
      res.add move(l)
      continue
    # a routine without a parameter list gets an empty one
    let t0 = l.toks[0]
    if t0.kind == fkKw and t0.text in FRoutineKw and l.toks.len > 1:
      var k = 1
      if l.toks[k].kind == fkIdent:
        inc k
        if k < l.toks.len and l.toks[k].kind == fkOp and l.toks[k].text == "*": inc k
        if k < l.toks.len and l.toks[k].kind == fkOpen and l.toks[k].text == "[":
          var d = 0
          while k < l.toks.len:
            if l.toks[k].kind in {fkOpen, fkPragOpen}: inc d
            elif l.toks[k].kind in {fkClose, fkPragClose}:
              dec d
              if d == 0:
                inc k
                break
            inc k
      if k < l.toks.len and not (l.toks[k].kind == fkOpen and l.toks[k].text == "(") and
         (l.toks[k].kind in {fkColon, fkPragOpen, fkComment} or (l.toks[k].kind == fkOp and l.toks[k].text == "=")):
        let p = l.toks[k - 1].pos
        l.toks.insert(FTok(kind: fkClose, text: ")", pos: p), k)
        l.toks.insert(FTok(kind: fkOpen, text: "(", pos: p), k)
      elif k == l.toks.len and l.toks[k - 1].kind == fkIdent:
        l.toks.add [FTok(kind: fkOpen, text: "(", pos: l.toks[k - 1].pos),
                    FTok(kind: fkClose, text: ")", pos: l.toks[k - 1].pos)]
    # statements separated by `;` go on lines of their own
    var semis: seq[int]
    var d = 0
    var innerComment = false
    for k, t in l.toks:
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
      elif d == 0 and t.kind == fkSemi: semis.add k
      elif t.kind == fkComment and k < l.toks.high: innerComment = true
    if semis.len == 0 or innerComment or (t0.kind == fkKw and t0.text == "type"):
      res.add move(l)
      continue
    var bodyStart = 0
    var bodyDepth = l.depth
    let (h, stop) = fSplitIdx(l.toks, 0, l.toks.len)
    if h >= 0:
      # `if a: x; y` — both are the body
      if not (t0.kind == fkKw and (t0.text in FBlockKw or t0.text in FRoutineKw)) or stop < l.toks.len or
         semis[0] < h:
        res.add move(l)
        continue
      var hl = l
      hl.toks = l.toks[0 .. h]
      res.add hl
      bodyStart = h + 1
      bodyDepth = l.depth + 1
    var a = bodyStart
    var first = h < 0
    for sk in semis & @[l.toks.len]:
      if sk > a:
        var nl = l
        nl.toks = l.toks[a ..< sk]
        nl.depth = bodyDepth
        nl.blank = l.blank and first
        res.add nl
        first = false
      a = sk + 1
  lines = move(res)

proc fImportElems(toks: seq[FTok]): seq[seq[FTok]] =
  ## the modules of an `import` statement, split at its top-level commas
  var cur: seq[FTok]
  var d = 0
  for k in 1 ..< toks.len:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    if t.kind == fkComma and d == 0:
      if cur.len > 0: result.add cur
      cur = @[]
    else: cur.add t
  if cur.len > 0: result.add cur

proc fImportKey(e: seq[FTok]): (int, string) =
  ## the order imports are sorted in: std/…, pkg/…, other packages and modules, ./ and ../, "$nim"/…
  let s = fRender(e, importish = true)
  let cat = if s.startsWith("std/"): 0 elif s.startsWith("pkg/"): 1 elif s.startsWith("."): 3
            elif s.startsWith("\""): 4 else: 2
  (cat, s.toLowerAscii)

proc fImportGroup(e: seq[FTok]): (int, seq[string]) =
  ## `std/os` → (index of its last `/`, @["os"]) · `std/[os, strutils]` → (…, @["os", "strutils"]) — a module
  ## that can join others under the same path; (-1, @[]) for anything else (`a as b`, `./x`, a string path)
  result = (-1, @[])
  var slash = -1
  for k, t in e:
    if t.kind == fkOpen: break
    if t.kind == fkOp and t.text == "/": slash = k
    elif t.kind != fkIdent: return
  if slash <= 0 or slash == e.high: return
  let rest = e[slash + 1 .. ^1]
  if rest.len == 1 and rest[0].kind == fkIdent: return (slash, @[rest[0].text])
  if rest.len >= 3 and rest[0].kind == fkOpen and rest[0].text == "[" and rest[^1].kind == fkClose:
    var names: seq[string]
    for k in 1 ..< rest.high:
      if rest[k].kind == fkIdent and (k == 1 or rest[k - 1].kind == fkComma): names.add rest[k].text
      elif rest[k].kind != fkComma: return
    if names.len > 0: return (slash, names)

proc fImports*(lines: var seq[FLine]) =
  ## nim.format.imports: the modules of each `import` sorted (std/, pkg/, others, relative); "merge" also joins
  ## import statements that follow each other and std/a, std/b into std/[a, b]. `include` keeps its order
  proc plain(l: FLine): bool =
    if l.comment or l.verbatim or l.toks.len < 2 or not (l.toks[0].kind == fkKw and l.toks[0].text == "import"):
      return false
    for t in l.toks:
      if t.kind == fkComment or (t.kind == fkKw and t.text == "except"): return false
    true
  var res: seq[FLine]
  var i = 0
  while i < lines.len:
    if not plain(lines[i]):
      res.add move(lines[i])
      inc i
      continue
    var l = lines[i]
    var elems = fImportElems(l.toks)
    var j = i + 1
    if FmtImports >= 2:
      while j < lines.len and plain(lines[j]) and lines[j].depth == l.depth and not lines[j].blank:
        elems.add fImportElems(lines[j].toks)
        inc j
      # std/a, std/[b, c] → std/[a, b, c] (any path written the same way: pkg/…, a folder)
      var merged: seq[seq[FTok]]
      var byPath = initTable[string, int]()
      for e in elems:
        let (slash, names) = fImportGroup(e)
        if slash < 0:
          merged.add e
          continue
        let path = fRender(e[0 ..< slash], importish = true)
        if path notin byPath:
          byPath[path] = merged.len
          merged.add e
          continue
        let at = byPath[path]
        var all = fImportGroup(merged[at])[1]
        for n in names:
          if n notin all: all.add n
        let first = merged[at]
        let p0 = first[0].pos
        var ne = first[0 .. fImportGroup(first)[0]]
        ne.add FTok(kind: fkOpen, text: "[", pos: p0)
        for k, n in all:
          if k > 0: ne.add FTok(kind: fkComma, text: ",", pos: p0)
          ne.add FTok(kind: fkIdent, text: n, sp: k > 0, pos: p0)
        ne.add FTok(kind: fkClose, text: "]", pos: p0)
        merged[at] = ne
      elems = merged
    # sorted (and the names inside std/[…] too)
    for e in elems.mitems:
      let (slash, names) = fImportGroup(e)
      if slash >= 0 and names.len > 1:
        var sn = names
        sn.sort(proc(a, b: string): int = cmp(a.toLowerAscii, b.toLowerAscii))
        if sn != names:
          let p0 = e[0].pos
          var ne = e[0 .. slash]
          ne.add FTok(kind: fkOpen, text: "[", pos: p0)
          for k, n in sn:
            if k > 0: ne.add FTok(kind: fkComma, text: ",", pos: p0)
            ne.add FTok(kind: fkIdent, text: n, sp: k > 0, pos: p0)
          ne.add FTok(kind: fkClose, text: "]", pos: p0)
          e = ne
    elems.sort(proc(a, b: seq[FTok]): int = cmp(fImportKey(a), fImportKey(b)))
    var toks = @[l.toks[0]]
    for k, e in elems:
      if k > 0: toks.add FTok(kind: fkComma, text: ",", pos: e[0].pos)
      toks.add e
    l.toks = toks
    l.phys = 1
    res.add l
    i = j
  lines = move(res)

proc fReflowDocs*(entries: var seq[FOut]) =
  ## nim.format.reflowDocComments: a `##` paragraph with a line longer than the line length re-wrapped to it —
  ## lists, code, tables, headings and directives stay as they are
  var res: seq[FOut]
  var fence = false
  var i = 0
  proc docText(o: FOut): (bool, string) =
    if not o.comment or o.toks.len != 1: return (false, "")
    let t = o.toks[0].text
    if not t.startsWith("##") or t.startsWith("##[") or t.startsWith("###"): return (false, "")
    var c = t[2 .. ^1]
    if c.startsWith(" "): c = c[1 .. ^1]
    (true, c)
  proc plainLine(c: string): bool =
    if c.len == 0 or c[0] in {' ', '\t', '-', '*', '+', '#', '|', '>', ':', '=', '`', '.'}: return false
    var d = 0
    while d < c.len and c[d] in Digits: inc d
    if d > 0 and d < c.len and c[d] in {'.', ')'}: return false
    true
  while i < entries.len:
    let (isDoc, c0) = docText(entries[i])
    if not isDoc:
      fence = false
      res.add move(entries[i])
      inc i
      continue
    if c0.startsWith("```"): fence = not fence
    if fence or not plainLine(c0):
      res.add move(entries[i])
      inc i
      continue
    # only a doc block of its own — the module's, a routine's or type's under its header, or between statements —
    # not one under a field or an enum value (that one moves with it as its trailing comment)
    var pc = i - 1
    while pc >= 0 and entries[pc].comment: dec pc
    if pc >= 0 and entries[pc].depth < entries[i].depth:
      var fl = FLine(toks: entries[pc].toks)
      if not fOpensBlock(fl):
        res.add move(entries[i])
        inc i
        continue
    var j = i
    var words: seq[string]
    var long = false
    while j < entries.len and entries[j].depth == entries[i].depth and (j == i or not entries[j].blank):
      let (d2, c) = docText(entries[j])
      if not d2 or not plainLine(c): break
      if entries[j].depth * 2 + entries[j].toks[0].text.len > FmtMax: long = true
      words.add c.splitWhitespace
      inc j
    if not long:
      for k in i ..< j: res.add move(entries[k])
      i = j
      continue
    let width = FmtMax - entries[i].depth * 2 - 3
    var cur = ""
    var outp: seq[string]
    for w in words:
      if cur.len > 0 and cur.len + 1 + w.len > width:
        outp.add cur
        cur = w
      else: cur.add (if cur.len > 0: " " else: "") & w
    if cur.len > 0: outp.add cur
    let first = entries[i]
    for k, o in outp:
      var ne = first
      ne.toks = @[FTok(kind: fkComment, text: "## " & o, nl: true, col: first.toks[0].col,
                       blanks: (if k == 0: first.toks[0].blanks else: 0), pos: first.toks[0].pos)]
      ne.blank = first.blank and k == 0
      res.add ne
    i = j
  entries = move(res)

proc fAlignRuns(entries: seq[FOut], res: var seq[string], firstLine, parentOf: seq[int], gap: seq[bool]) =
  ## nim.format.align: the types of object fields lined up, and the `=` of const / let / var section members
  var under = newSeq[bool](entries.len)      # rendered with its trailing comment on the next line
  for i in 0 ..< entries.len:
    under[i] = entries[i].lineCount == 2 and firstLine[i] + 1 < res.len and
               res[firstLine[i] + 1].strip.startsWith("#")
  proc kindOf(i: int): (int, int) =
    let o = entries[i]
    let parent = parentOf[i]
    if o.comment or o.verbatim or parent < 0 or o.toks.len < 3: return
    # (one line — or one with its trailing comment put under it)
    if not (o.lineCount == 1 or (o.lineCount == 2 and o.toks[^1].kind == fkComment and under[i])): return
    let p = entries[parent]
    if p.comment or p.verbatim or p.toks.len == 0: return
    let pt0 = p.toks[0]
    let section = p.toks.len == 1 and pt0.kind == fkKw and pt0.text in ["const", "let", "var"]
    var objectish = false
    if not (pt0.kind == fkKw and pt0.text in FRoutineKw):
      for t in p.toks:
        if t.kind == fkKw and t.text in ["object", "tuple"]: objectish = true
    if not (section or objectish): return
    let colon = fTopColon(o.toks, 0, o.toks.len)
    let eq = fTopEq(o.toks, 0, o.toks.len)
    let headEnd = if colon > 0 and (eq < 0 or colon < eq): colon elif eq > 0: eq else: -1
    if headEnd <= 0: return
    var d = 0
    for k in 0 ..< headEnd:
      let t = o.toks[k]
      if t.kind == fkPragOpen: inc d
      elif t.kind == fkPragClose: dec d
      elif d > 0: continue
      elif not (t.kind in {fkIdent, fkComma} or (t.kind == fkOp and t.text == "*")): return
    if section and eq > 0:
      return (if eq < o.toks.high and o.toks[eq + 1].kind != fkComment: (2, eq) else: (0, 0))
    if colon > 0 and colon < o.toks.high and o.toks[colon + 1].kind != fkComment: return (1, colon)
  var kinds = newSeq[(int, int)](entries.len)
  for i in 0 ..< entries.len: kinds[i] = kindOf(i)
  var i = 0
  while i < entries.len:
    let k1 = kinds[i][0]
    if k1 == 0:
      inc i
      continue
    var run = @[i]
    var j = i + 1
    while j < entries.len:
      # (a comment under the line before — deeper — belongs to it)
      if entries[j].comment and entries[j].depth > entries[i].depth and not gap[j]:
        inc j
        continue
      if not (kinds[j][0] == k1 and parentOf[j] == parentOf[i] and not gap[j] and entries[j].depth == entries[i].depth):
        break
      run.add j
      inc j
    if run.len >= 2:
      # where each line's column starts: after `name:` (types) or before ` = ` (values)
      var cols: seq[int]
      var ok = true
      for e in run:
        let o = entries[e]
        let line = res[firstLine[e]]
        let pre = spaces(o.depth * 2) & (if k1 == 1: fRender(o.toks[0 .. kinds[e][1]])
                                          else: fRender(o.toks[0 ..< kinds[e][1]]))
        let sep = if k1 == 1: " " else: " = "
        if not line.startsWith(pre & sep):
          ok = false
          break
        cols.add pre.len
      if ok:
        let target = max(cols)
        var outp: seq[string]
        for n, e in run:
          let line = res[firstLine[e]]
          let c = cols[n]
          let nl = line[0 ..< c] & spaces(target - c) & line[c .. ^1]
          if nl.len > FmtMax: ok = false
          outp.add nl
        if ok:
          for n, e in run: res[firstLine[e]] = outp[n]
    i = j

proc fFormat*(text: string, err: var string): string =
  var ok = true
  let toks = fLex(text, ok)
  if not ok:
    err = "cannot read this file (an unclosed string or comment?)"
    return text
  var lines = fGroupLines(toks)
  fDepths(lines)
  fNormalize(lines)
  if FmtImports > 0: fImports(lines)
  var normToks: seq[FTok]
  for l in lines: normToks.add l.toks
  var entries = fTransform(lines)
  if FmtReflow: fReflowDocs(entries)
  var res: seq[string]
  var prevDepth = -1
  var firstLine = newSeq[int](entries.len)      # (for lining up: where each entry's first line went,
  var parentOf = newSeq[int](entries.len)       #  and the entry it belongs to)
  var lastAt: seq[int]
  var gap = newSeq[bool](entries.len)           # an empty line written before it
  for i in 0 ..< entries.len:
    let o = entries[i]
    parentOf[i] = if o.depth > 0 and o.depth - 1 < lastAt.len: lastAt[o.depth - 1] else: -1
    if lastAt.len <= o.depth: lastAt.setLen(o.depth + 1)
    lastAt[o.depth] = i
    # blank lines: one at most, never at the top of a block, and one after a multi-line routine or type
    var blank = o.blank and res.len > 0 and not (prevDepth >= 0 and o.depth > prevDepth)
    if res.len > 0 and o.depth <= prevDepth:
      var j = i - 1
      while j >= 0 and entries[j].depth > o.depth: dec j
      if j >= 0 and entries[j].depth == o.depth and entries[j].complexKind > 0 and
         (i - j > 1 or entries[j].lineCount > 1):
        blank = true
    if blank and res.len > 0 and res[^1].len > 0:
      # (nim.format.maxBlankLines: the empty lines written there, up to that many)
      let n = if FmtBlank > 1 and o.blank: clamp(o.toks[0].blanks, 1, FmtBlank) else: 1
      for _ in 1 .. n: res.add ""
      gap[i] = true
    firstLine[i] = res.len
    var rendered: seq[string]
    if o.verbatim:
      # holds a long string or block comment: kept as written, only moved to its new indentation
      let delta = o.depth * 2 - o.toks[0].col
      var s = spaces(o.depth * 2)
      for k, t in o.toks:
        if k > 0:
          let p = o.toks[k - 1]
          if t.nl:
            rendered.add s
            s = spaces(max(0, t.col + delta))
          else: s.add text[p.pos + p.text.len ..< t.pos]
        s.add t.text
      rendered.add s
      var flat: seq[string]
      for r in rendered:
        for x in r.split('\n'): flat.add x
      rendered = flat
    else:
      rendered = fRenderLine(o, @[])
    entries[i].lineCount = rendered.len
    # (a long string's lines keep their trailing spaces: they are part of the string)
    for k, r in rendered: res.add (if o.verbatim and k < rendered.high: r else: r.strip(leading = false))
    prevDepth = o.depth
  if FmtAlign: fAlignRuns(entries, res, firstLine, parentOf, gap)
  while res.len > 0 and res[^1].len == 0: res.setLen(res.len - 1)
  result = res.join("\n") & "\n"
  if result == text: return          # nothing changed: nothing to check
  # the check: same tokens, same block structure — or nothing changes
  var ok2 = true
  let toks2 = fLex(result, ok2)
  if not ok2 or not fSameTokens(normToks, toks2):
    err = "the built-in formatter would change the code here, so nothing was changed (please report this file)"
    return text
  var lines2 = fGroupLines(toks2)
  fDepths(lines2)
  if fStructureOf(lines) != fStructureOf(lines2):
    err = "the built-in formatter would change the block structure, so nothing was changed (please report this file)"
    return text
