# ── the formatter ──

type FOut* = object
  depth*: int
  toks*: seq[FTok]
  blank*: bool
  comment*: bool
  verbatim*: bool
  keep*: bool           # (NimScript) kept exactly as written
  origText*: string
  cont*: int            # extra indentation for physical lines kept as written
  complexKind*: int
  lineCount*: int       # output lines it took (after wrapping)
  importish*: bool      # a line in an `import` block: module paths
  exprLine*: bool       # a value on its own line after `x =`
  declLike*: bool       # a declaration (a section's member, a field, a routine): a `##` may go under it
  children*: int        # deeper lines right after it
  lambdaCmd*: bool      # a command whose last argument is a lambda opening a block: one argument a line

proc fTop*(toks: openArray[FTok], what: proc(t: FTok, depth: int): bool): int =
  var d = 0
  for k, t in toks:
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and what(t, d): return k
  -1

func fSimpleTail*(toks: openArray[FTok], a: int): bool =
  ## only plain values (names, literals, a.b, discard) — and an `else` branch of the same kind
  var prevOperand = false
  for k in a ..< toks.len:
    let t = toks[k]
    case t.kind
    of fkIdent, fkNum, fkStr, fkChar:
      if prevOperand: return false                 # echo x — a command, not a value (a bracket: not plain)
      if t.kind == fkStr and t.text.len > 0 and t.text[0] in IdentStartChars: return false   # bindSym"x": a call
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

func fTopEq*(toks: openArray[FTok], a, b: int): int =
  ## the first `=` outside brackets in toks[a ..< b], or -1
  var d = 0
  for k in a ..< b:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkOp and t.text == "=": return k
  -1

func fTopColon*(toks: openArray[FTok], a, b: int): int =
  var d = 0
  for k in a ..< b:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkColon: return k
  -1

func fCallColon*(toks: openArray[FTok], a, b: int): int =
  ## `withLock(l): body`, `p.nested: body` — a call (with parentheses, or a dotted name) given a block on the
  ## same line: the index of its `:`, else -1 (a plain `name:` could be a field or a section's member)
  if b - a < 3 or toks[a].kind != fkIdent: return -1
  var k = a + 1
  var dotted = false
  while k + 1 < b and toks[k].kind == fkDot and toks[k + 1].kind == fkIdent:
    k += 2
    dotted = true
  var call = false
  if k < b and toks[k].kind == fkOpen and toks[k].text == "(" and fCallParen(toks, k):
    var d = 0
    while k < b:
      if toks[k].kind in {fkOpen, fkPragOpen}: inc d
      elif toks[k].kind in {fkClose, fkPragClose}:
        dec d
        if d == 0: break
      inc k
    if k >= b: return -1
    inc k
    call = true
  if not (call or dotted) or k >= b - 1 or toks[k].kind != fkColon or toks[k + 1].kind == fkComment: return -1
  k

proc fSplitIdx*(toks: openArray[FTok], a, b: int): (int, int) =
  ## an inline block in toks[a ..< b]:  `if a: b else: c` → (index of the header's last token, where
  ## the body ends); (-1, -1) when there is none
  if b - a < 2: return (-1, -1)
  let t0 {.cursor.} = toks[a]
  var hdrEnd = -1
  var valueIf = false
  var valueTry = false
  if t0.kind == fkKw and t0.text in FRoutineKw and toks[a + 1].kind in {fkIdent, fkKw}:
    hdrEnd = fTopEq(toks, a, b)
  elif t0.kind == fkKw and t0.text in FBlockKw:
    if t0.text == "static" and toks[a + 1].kind != fkColon: return (-1, -1)
    hdrEnd = fTopColon(toks, a, b)
  elif fCallColon(toks, a, b) > 0:
    hdrEnd = fCallColon(toks, a, b)          # doAssertRaises(E): body  →  its body on the next line
  else:
    # a lambda as a value:  let f = proc(x: int): int = x + 1  → its body on the next line
    let eq1 = if t0.kind == fkKw and t0.text in ["return", "yield"] and a + 1 < b and toks[a + 1].kind == fkKw and
                 toks[a + 1].text in ["if", "when"]: a          # return if a: b else: c
              else: fTopEq(toks, a, b)
    if eq1 >= 0 and eq1 + 2 < b and toks[eq1 + 1].kind == fkKw and toks[eq1 + 1].text in ["proc", "func"] and
       toks[eq1 + 2].kind == fkOpen:
      hdrEnd = fTopEq(toks, eq1 + 1, b)
    # an if-expression as a value:  x = if a: f() else: g()  → one branch per line
    elif eq1 >= 0 and eq1 + 2 < b and toks[eq1 + 1].kind == fkKw and toks[eq1 + 1].text in ["if", "when"]:
      hdrEnd = fTopColon(toks, eq1 + 2, b)
      valueIf = true
    # a try-expression as a value:  x = try: f() except E: y
    elif eq1 >= 0 and eq1 + 2 < b and toks[eq1 + 1].kind == fkKw and toks[eq1 + 1].text == "try" and
         toks[eq1 + 2].kind == fkColon:
      hdrEnd = eq1 + 2
      valueTry = true
  if hdrEnd < 0 or hdrEnd >= b - 1 or toks[hdrEnd + 1].kind == fkComment: return (-1, -1)
  # the body runs to an elif/else (or except/finally) of this statement, not of an if-expression inside it
  var stop = b
  var nested = 0
  var d = 0
  let tryLike = valueTry or t0.text in ["try", "except"]
  let ifLike = valueIf or t0.text in ["if", "elif", "when"]
  for k in hdrEnd + 1 ..< b:
    let t {.cursor.} = toks[k]
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
    elif t.kind == fkComment and k < b - 1: return false     # (a comment in it: one branch a line, like nph)
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

proc fValueIf*(toks: openArray[FTok], depth = -1): int =
  ## `x = if a: f() else: g()` whose branches are not plain values (or that is too long on one line at `depth`),
  ## `return if …`, `x = try: f() except E: y`: the index of its `=` (or `return`), or -1
  if toks.len < 4 or (toks[0].kind == fkKw and (toks[0].text in FRoutineKw or toks[0].text in FBlockKw)):
    return -1
  let eq = if toks[0].kind == fkKw and toks[0].text in ["return", "yield"]: 0 else: fTopEq(toks, 0, toks.len)
  if eq < 0 or eq + 2 >= toks.len or toks[eq + 1].kind != fkKw or toks[eq + 1].text notin ["if", "when", "try"]:
    return -1
  let (h, _) = fSplitIdx(toks, 0, toks.len)
  if h < 0: return -1
  if toks[eq + 1].text != "try" and fInlineIf(toks, eq + 1, toks.len) and
     (depth < 0 or depth * 2 + fRenderLen(toks) <= FmtMax):
    return -1
  eq

proc fKeepInline*(toks: openArray[FTok], depth = -1): bool =
  ## `if a: x else: y` and `v = if a: x else: y` with plain values stay on one line (like nph) — when it fits
  if toks.len == 0: return false
  let t0 = toks[0]
  var inline = false
  if t0.kind == fkKw and t0.text in ["if", "when"]: inline = fInlineIf(toks, 0, toks.len)
  elif t0.kind == fkKw and t0.text in ["return", "yield"] and toks.len > 1 and toks[1].kind == fkKw and
       toks[1].text in ["if", "when"]:
    inline = fInlineIf(toks, 1, toks.len)
  elif t0.kind == fkKw and (t0.text in FBlockKw or t0.text in FRoutineKw): return false
  else:
    let eq = fTopEq(toks, 0, toks.len)
    inline = eq >= 0 and eq + 1 < toks.len and toks[eq + 1].kind == fkKw and toks[eq + 1].text in ["if", "when"] and
             fInlineIf(toks, eq + 1, toks.len)
  # (the width last: the most work)
  inline and not (depth >= 0 and depth * 2 + fRenderLen(toks) > FmtMax)

proc fLambdaAt*(e: openArray[FTok], a: int): int

proc fLambdaCmd*(toks: openArray[FTok]): bool =
  ## `cmd a, b, proc(x: T) =` — a command (no parentheses) of two or more arguments whose last one is a lambda
  ## opening a block: nph writes its arguments one a line, the lambda's body under the lambda
  if toks.len < 6 or toks[0].kind != fkIdent or toks[^1].kind != fkOp or toks[^1].text != "=": return false
  var k = 0
  while k + 2 < toks.len and toks[k + 1].kind == fkDot and toks[k + 2].kind == fkIdent: k += 2
  if k + 1 >= toks.len: return false
  let a = toks[k + 1]
  if not (a.sp or a.nl) or a.kind notin {fkIdent, fkNum, fkStr, fkChar, fkOpen} or (a.kind == fkOpen and a.text == "("):
    return false
  var d = 0
  var lastComma = -1
  for j in k + 1 ..< toks.len:
    let t = toks[j]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif t.kind in {fkComment, fkSemi}: return false
    elif d == 0 and t.kind == fkComma: lastComma = j
    elif d == 0 and t.kind == fkOp and t.text == "=" and j < toks.high and lastComma < 0: return false
    elif d == 0 and t.kind == fkKw and t.text in FBlockKw: return false
  lastComma > k + 1 and fLambdaAt(toks, lastComma + 1) == toks.high

proc fColonBlock*(toks: openArray[FTok], a, b: int): bool
proc fCommandLike*(toks: openArray[FTok]): bool

proc fEnumComment(v: seq[FTok], c: FTok): bool =
  ## is comment c (after an enum value's comma) that value's trailing comment? On the value's line — or on a
  ## line of its own after a line of several values (`a, b,` ⏎ `# note` → `b # note`), or deeper than the value's
  ## own line (`a,` ⏎ `  # note` → `a # note`), like nph
  if not c.nl: return true
  if v.len == 0 or v[^1].kind == fkComment or c.text.startsWith("#["): return false
  var f = 0
  while f < v.high and v[f].kind == fkComment: inc f
  if v[f].nl: c.col > v[f].col
  else: not c.text.startsWith("##")

proc fBranchWidth(toks: seq[FTok], depth: int): int =
  ## the width nph counts for an inline case branch (`of a, b: x`): it measures from after `case `, a few
  ## columns more than the branch's own line
  depth * 2 + fRender(toks).len + (if toks[0].text == "else": 5 else: 4)

func fTypeMemberComplex*(l: FLine): bool =
  for t in l.toks:
    if t.kind == fkKw and t.text in ["object", "enum"]: return true
  false

proc fTransform*(lines: seq[FLine]): seq[FOut] =
  ## split one-line blocks, collapse one-member sections, put enum values one per line
  var i = 0
  var typeDepth = -1            # inside a type section: its depth (+1 for members)
  var enumDepth = -1
  var secDepth = -1             # inside a var/let/const/type section: its depth
  # (each pass below moves the lines it keeps from `work` to `res` — no copies of their tokens)
  var work = lines
  # a statement followed by a single `## doc` line under it: the comment joins the statement (like
  # nph; it moves back under the statement when the line gets too long)
  block:
    var joined = newSeqOfCap[FLine](work.len)
    var k = 0
    while k < work.len:
      var l = move(work[k])
      if not l.comment and not l.verbatim and l.toks.len > 0 and
         l.toks[^1].kind != fkComment and not fOpensBlock(l) and k + 1 < work.len:
        template c: untyped = work[k + 1]
        if c.comment and c.toks.len == 1 and c.depth > l.depth and
           c.toks[0].text.startsWith("#") and not c.toks[0].text.startsWith("##[") and
           not c.toks[0].text.startsWith("#[") and
           (k + 2 >= work.len or (not work[k + 2].comment and work[k + 2].depth <= l.depth)):
          var t = c.toks[0]
          t.nl = false
          t.blanks = 0
          l.toks.add t
          joined.add move(l)
          k += 2
          continue
      joined.add move(l)
      inc k
    work = move(joined)
  # `if a:` ⏎ a comment written deeper than the block's first statement: the header's trailing comment (nph)
  block:
    var joined = newSeqOfCap[FLine](work.len)
    var k = 0
    while k < work.len:
      var l = move(work[k])
      if not l.comment and not l.verbatim and l.toks.len > 1 and l.toks[^1].kind == fkColon and k + 2 < work.len:
        template c: untyped = work[k + 1]
        template b: untyped = work[k + 2]
        if c.comment and c.toks.len == 1 and not c.blank and c.toks[0].text.startsWith("#") and
           not c.toks[0].text.startsWith("##") and not c.toks[0].text.startsWith("#[") and
           not b.comment and b.indent > l.indent and c.indent > b.indent:
          var t = c.toks[0]
          t.nl = false
          t.blanks = 0
          l.toks.add t
          joined.add move(l)
          k += 2
          continue
      joined.add move(l)
      inc k
    work = move(joined)
  # sections with exactly one member (and nothing else) are written on one line
  var k = 0
  var res = newSeqOfCap[FLine](work.len)
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
          # (a comment deeper than the member belongs to it: nph still writes `type X = int` ⏎ its comment)
          if work[j].depth <= l.depth + 1: hasComment = true
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
  # a trailing comment that goes on in comment lines under it: all of them under the code, 2 deeper (like nph)
  res = newSeqOfCap[FLine](work.len)
  proc inEnum(done: seq[FLine], depth: int): bool =
    ## an enum's value (its comma goes: the values end up one a line) — `done`: the lines before it
    var j = done.high
    while j >= 0 and (done[j].comment or done[j].depth >= depth): dec j
    if j < 0 or done[j].toks.len == 0: return false
    var q = done[j].toks.high
    while q > 0 and done[j].toks[q].kind == fkComment: dec q
    done[j].toks[q].kind == fkKw and done[j].toks[q].text == "enum"
  for k in 0 ..< work.len:
    template l: untyped = work[k]
    if not l.comment and not l.verbatim and l.toks.len > 1 and l.toks[^1].kind == fkComment and
       not l.toks[^1].text.startsWith("#[") and not l.toks[^1].text.startsWith("##[") and
       # (not when the statement goes on: `a, ## doc` in a list of names — the comment must stay on its line)
       not (l.toks[^1].text.startsWith("##") and (l.toks[^2].kind in {fkComma, fkOp} or fWordOp(l.toks[^2])) and
            not (l.toks[^2].kind == fkComma and inEnum(res, l.depth))) and
       k + 1 < work.len and work[k + 1].comment and not work[k + 1].blank and work[k + 1].depth > l.depth and
       (not fOpensBlock(l) or (block:
         # (a block's line: only a comment that goes on further right than the block's code — the block's own
         # first comments stay where they are)
         var q = k + 1
         while q < work.len and work[q].comment: inc q
         q >= work.len or work[q].depth <= l.depth or work[k + 1].indent > work[q].indent)):
      var code = l
      let c = code.toks[^1]
      code.toks.setLen(code.toks.len - 1)
      let d = l.depth
      res.add code
      var cl = FLine(toks: @[c], depth: d + 1, comment: true, phys: 1, indent: l.indent + 2)
      cl.toks[0].nl = true
      res.add cl
      var q = k + 1
      while q < work.len and work[q].comment and work[q].depth > d and not work[q].blank:
        work[q].depth = d + 1
        inc q
      continue
    res.add move(work[k])
  work = move(res)
  # a lambda on the line after `x =`: up on that line, its body one less deep (like nph)
  res = newSeqOfCap[FLine](work.len)
  var ak = 0
  while ak < work.len:
    template l: untyped = work[ak]
    if not l.comment and not l.verbatim and l.toks.len >= 2 and l.toks[^1].kind == fkOp and l.toks[^1].text == "=" and
       fValueEq(l.toks) and ak + 1 < work.len:
      template m: untyped = work[ak + 1]
      if not m.comment and not m.verbatim and not m.blank and m.depth == l.depth + 1 and m.toks.len >= 3 and
         fLambdaAt(m.toks, 0) == m.toks.high:
        var merged = move(work[ak])
        merged.toks.add m.toks
        let mDepth = m.depth
        res.add move(merged)
        var q = ak + 2
        while q < work.len and work[q].depth > mDepth:
          work[q].depth -= 1             # (in place: a lambda in its body is looked at next)
          inc q
        ak += 2
        continue
    res.add move(work[ak])
    inc ak
  work = move(res)
  # a value that is an if/case/try over several lines: `x =` ⏎ the expression under it, its branches lined up
  # (like nph)
  res = newSeqOfCap[FLine](work.len)
  var vk = 0
  while vk < work.len:
    template l: untyped = work[vk]
    var eq = -1
    var kw = ""
    if not l.comment and not l.verbatim and l.toks.len > 3 and
       not (l.toks[0].kind == fkKw and (l.toks[0].text in FRoutineKw or l.toks[0].text in FBlockKw)):
      eq = fTopEq(l.toks, 0, l.toks.len)
      if eq > 0 and eq + 2 < l.toks.len and l.toks[eq + 1].kind == fkKw and
         l.toks[eq + 1].text in ["if", "when", "case", "try"]:
        kw = l.toks[eq + 1].text
        # (the if/try/block must open its block on this line; a case's branches follow)
        if kw != "case" and not fOpensBlock(l): kw = ""
        var lam = false
        for q in 0 ..< eq:
          if l.toks[q].kind == fkKw and l.toks[q].text in FRoutineKw: lam = true
        if lam: kw = ""
    var j = vk + 1
    while j < work.len and work[j].comment: inc j
    if kw.len == 0 or j >= work.len or work[j].depth < l.depth or
       (work[j].depth == l.depth and not (kw == "case" and work[j].toks[0].kind == fkKw and work[j].toks[0].text == "of")):
      res.add move(work[vk])
      inc vk
      continue
    let d = l.depth
    let branchKw = case kw
                   of "if", "when": @["elif", "else"]
                   of "case": @["of", "elif", "else"]
                   of "try": @["except", "finally"]
                   else: @[]
    let bd = work[j].depth
    let shift = if kw == "case": (d + 1) - bd else: (d + 2) - bd
    var head = l
    head.toks = l.toks[0 .. eq]
    res.add head
    var ex = l
    ex.toks = l.toks[eq + 1 .. ^1]
    ex.depth = d + 1
    ex.blank = false
    ex.toks[0].nl = true
    res.add ex
    var q = vk + 1
    var curShift = shift
    let bodyInd = work[j].indent
    while q < work.len:
      var m = work[q]
      if m.depth > d and not m.comment and m.indent < bodyInd and m.toks[0].kind == fkKw and
         m.toks[0].text in branchKw:
        # (a branch written less deep than the body, deeper than x: at the if's level, its body under it)
        curShift = (d + 1) - m.depth
        m.depth = d + 1
      elif m.depth > d:
        m.depth += curShift
      elif m.depth == d and not m.comment and m.toks[0].kind == fkKw and m.toks[0].text in branchKw:
        curShift = (d + 1) - m.depth
        m.depth = d + 1
      elif m.comment and m.depth == d:
        # (a comment between the branches stays with them)
        var r = q + 1
        while r < work.len and work[r].comment: inc r
        if r < work.len and work[r].depth == d and work[r].toks[0].kind == fkKw and work[r].toks[0].text in branchKw:
          m.depth = d + 1
        else: break
      else: break
      res.add m
      inc q
    vk = q
  work = move(res)
  # `if a:` ⏎ x ⏎ `else:` ⏎ y (or `if a: x` ⏎ `else: y`) with plain values: on one line when it fits (like nph)
  res = newSeqOfCap[FLine](work.len)
  var jk = 0
  while jk < work.len:
    template l: untyped = work[jk]
    var joined: seq[FTok]
    var nxt = jk + 1
    var ok = false
    proc usable(x: FLine): bool =
      not x.comment and not x.verbatim and x.toks.len > 0 and x.toks[^1].kind != fkComment
    proc noColon(t: seq[FTok]): bool = fTopColon(t, 0, t.len) < 0     # (`when x: a: int` — fields, not values)
    if usable(l) and l.toks.len >= 3 and
       ((l.toks[0].kind == fkKw and l.toks[0].text in ["if", "when"]) or
        (l.toks[0].kind == fkKw and l.toks[0].text in ["return", "yield"] and l.toks[1].kind == fkKw and
         l.toks[1].text in ["if", "when"])):
      var i = jk + 1
      var good = true
      joined = l.toks
      if l.toks[^1].kind == fkColon:
        # the body on the next line: one line
        if i < work.len and usable(work[i]) and not work[i].blank and work[i].depth == l.depth + 1 and
           noColon(work[i].toks):
          joined.add work[i].toks
          inc i
        else: good = false
      else:
        let (h, stop) = fSplitIdx(l.toks, 0, l.toks.len)
        if h < 0 or stop != l.toks.len or not noColon(l.toks[h + 1 .. ^1]): good = false   # (an inline else already?)
      # the else: `else:` ⏎ y, or `else: y`
      if good and i < work.len and usable(work[i]) and not work[i].blank and work[i].depth == l.depth and
         work[i].toks.len >= 2 and work[i].toks[0].kind == fkKw and work[i].toks[0].text == "else" and
         work[i].toks[1].kind == fkColon:
        let e = work[i]
        joined.add e.toks
        inc i
        if e.toks.len == 2:
          if i < work.len and usable(work[i]) and not work[i].blank and work[i].depth == l.depth + 1 and
             noColon(work[i].toks):
            joined.add work[i].toks
            inc i
          else: good = false
        elif not noColon(e.toks[2 .. ^1]): good = false
      else: good = false
      if good and (i >= work.len or work[i].depth <= l.depth) and i > jk + 1:
        ok = fKeepInline(joined, l.depth)
        nxt = i
    if ok:
      var m = move(work[jk])
      m.toks = move(joined)
      res.add move(m)
      jk = nxt
    else:
      res.add move(work[jk])
      inc jk
  work = move(res)
  # `x =` ⏎ a value on the next line (or `return` ⏎ its value): one statement again — nph decides where it
  # breaks (it joins them when they fit on one line)
  res = newSeqOfCap[FLine](work.len)
  var mk = 0
  while mk < work.len:
    template l: untyped = work[mk]
    if not l.comment and not l.verbatim and mk + 1 < work.len and l.toks.len >= 1 and
       (fValueEq(l.toks) or (l.toks.len == 1 and l.toks[0].kind == fkKw and
                             l.toks[0].text in ["return", "yield", "discard", "raise"])):
      template m: untyped = work[mk + 1]
      var after = mk + 2
      while after < work.len and work[after].comment: inc after     # (a doc comment under it stays there)
      if not m.comment and not m.verbatim and not m.blank and m.depth == l.depth + 1 and m.toks.len > 0 and
         m.toks[^1].kind != fkComment and not fOpensBlock(m) and
         (after >= work.len or work[after].depth <= l.depth) and
         (not (m.toks[0].kind == fkKw and (m.toks[0].text in FBlockKw or m.toks[0].text in ["case", "try", "block"])) or
          (m.toks[0].text in ["if", "when"] and fInlineIf(m.toks, 0, m.toks.len))):
        var merged = move(work[mk])
        merged.toks.add m.toks
        res.add move(merged)
        mk += 2
        continue
    res.add move(work[mk])
    inc mk
  work = move(res)
  # import blocks: one module (or std/[…] group) per line, a comma after all but the last
  res = newSeqOfCap[FLine](work.len)
  var importDepth = -1
  for li in 0 ..< work.len:
    template l: untyped = work[li]
    if not l.comment and importDepth >= 0 and l.depth <= importDepth: importDepth = -1
    if not l.comment and l.toks.len == 1 and l.toks[0].kind == fkKw and
       l.toks[0].text in ["import", "include", "export"]:
      # modules without comments: one statement, packed on one line when it fits (like nph; fRenderLine puts
      # them one a line when not)
      var q = li + 1
      var plain = true
      var mods: seq[FTok]
      while q < work.len and work[q].depth > l.depth:
        if work[q].comment or work[q].verbatim: plain = false
        for t in work[q].toks:
          if t.kind == fkComment: plain = false
          mods.add t
        inc q
      if plain and mods.len > 0 and mods[^1].kind != fkComma:
        var one = work[li]
        for t in mods:
          var t2 = t
          t2.nl = false
          one.toks.add t2
        res.add one
        for m in li + 1 ..< q: work[m].toks.setLen(0)
        importDepth = -2
        continue
      importDepth = l.depth
      res.add move(work[li])
      continue
    if importDepth == -2:
      if work[li].toks.len == 0: continue
      importDepth = -1
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
  # `Foo = object # what it is` ⏎ comment lines: the comment goes under it, as its body's first line (like nph —
  # when the body starts with no comment, it stays on the line)
  res = newSeqOfCap[FLine](work.len)
  for k in 0 ..< work.len:
    template l: untyped = work[k]
    if k + 1 < work.len and work[k + 1].comment and work[k + 1].depth > l.depth and
       not l.comment and not l.verbatim and l.toks.len > 3 and l.toks[^1].kind == fkComment and
       not l.toks[^1].text.startsWith("#[") and not l.toks[^1].text.startsWith("##") and
       l.toks[^2].kind == fkKw and l.toks[^2].text in ["object", "tuple"] and
       (l.toks[^3].kind == fkOp and l.toks[^3].text == "=" or
        l.toks[^3].kind == fkKw and l.toks[^3].text in ["ref", "ptr"]):
      var moved = l
      moved.toks = l.toks[0 ..< l.toks.high]
      res.add moved
      res.add FLine(toks: @[l.toks[^1]], depth: l.depth + 1, comment: true, phys: 1, indent: l.indent + 2)
    else: res.add move(work[k])
  work = move(res)
  # `Foo = object` ⏎ one comment line, then its fields: the comment on the object's line; an object's (or enum's)
  # last member ⏎ one comment line, where the object ends: the comment on the member's line — when it fits there
  # (like nph)
  proc headKind(x: FLine): int =
    ## 1 `X = object`, `X = ref object of Y` (not `ptr object`: nph puts that apart) · 2 `X = enum` · 0 else (a
    ## trailing comment aside)
    var j = x.toks.high
    while j > 0 and x.toks[j].kind == fkComment: dec j
    if x.comment or x.verbatim or j < 2: return 0
    if x.toks[j].kind == fkKw and x.toks[j].text == "enum" and x.toks[j - 1].kind == fkOp and
       x.toks[j - 1].text == "=":
      return 2
    if j >= 2 and x.toks[j - 1].kind == fkKw and x.toks[j - 1].text == "of" and x.toks[j].kind == fkIdent: j -= 2
    if j < 2 or x.toks[j].kind != fkKw or x.toks[j].text != "object": return 0
    var p = j - 1
    if x.toks[p].kind == fkKw and x.toks[p].text == "ref": dec p
    if p >= 1 and x.toks[p].kind == fkOp and x.toks[p].text == "=": 1 else: 0
  res = newSeqOfCap[FLine](work.len)
  var ck = 0
  while ck < work.len:
    template l: untyped = work[ck]
    var join = false
    if ck + 1 < work.len and not l.comment and not l.verbatim and l.toks.len > 0 and l.toks[^1].kind != fkComment:
      template c: untyped = work[ck + 1]
      let ct = c.toks[0]
      let single = c.comment and c.toks.len == 1 and not c.blank and not ct.text.startsWith("#[") and
                   not ct.text.startsWith("##[") and (ck + 2 >= work.len or not work[ck + 2].comment)
      template fits(a: int): bool =
        l.depth * 2 + fRenderLen(l.toks.toOpenArray(a, l.toks.high)) + 1 + ct.text.len <= FmtMax
      if single and c.depth == l.depth + 1 and headKind(l) == 1: join = fits(0)
      elif single and c.depth == l.depth and l.depth > 0 and (ck + 2 >= work.len or work[ck + 2].depth < l.depth):
        # (the member's object: the line before its first member)
        var j = res.high
        while j >= 0 and (res[j].comment or res[j].depth >= l.depth): dec j
        if j >= 0 and res[j].depth == l.depth - 1:
          let hk = headKind(res[j])
          if hk == 1: join = fits(0)
          elif hk == 2:
            # (enum values one a line: the comment goes to the last one)
            var a = 0
            var d = 0
            for k, t in l.toks:
              if t.kind in {fkOpen, fkPragOpen}: inc d
              elif t.kind in {fkClose, fkPragClose}: dec d
              elif d == 0 and t.kind == fkComma: a = k + 1
            join = a < l.toks.len and fits(a)
    if join:
      var t = work[ck + 1].toks[0]
      t.nl = false
      t.sp = true
      t.blanks = 0
      var m = move(work[ck])
      m.toks.add t
      res.add move(m)
      ck += 2
      continue
    res.add move(work[ck])
    inc ck
  work = move(res)
  # case branches indented under `case` move to its level (like nph); a case whose branches all are
  # one-liners with plain values keeps them inline, otherwise every branch body goes on its own line
  var shifts: seq[int]
  var inlineBranch = newSeq[bool](work.len)
  var lastBranchComment = newSeq[bool](work.len)
  var absorbed = newSeq[bool](work.len)      # a branch's value written under it, now on the branch's line
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
    var bodies: seq[int]           # (branches whose value is on the next line)
    var commented = -1             # (a branch with a trailing comment: only the last may have one)
    j = idx + 1
    while j < work.len:
      let m = work[j]
      if m.comment:
        if m.depth >= bd:
          # (comments after the last branch are the case's own: they change nothing)
          var q = j
          while q < work.len and work[q].comment: inc q
          if q < work.len and work[q].depth >= bd: trivial = false
          else: break
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
      if commented >= 0: trivial = false
      # (`of a:` ⏎ a plain value: as `of a: value` — nph does not keep the line break)
      if m.toks[^1].kind == fkColon and not m.verbatim and j + 1 < work.len and not work[j + 1].comment and
         not work[j + 1].verbatim and work[j + 1].depth == bd + 1 and work[j + 1].toks[^1].kind != fkComment and
         fSimpleTail(work[j + 1].toks, 0) and fTopColon(work[j + 1].toks, 0, work[j + 1].toks.len) < 0 and
         (j + 2 >= work.len or work[j + 2].depth <= bd):
        if fBranchWidth(m.toks & work[j + 1].toks, l.depth) > FmtMax: trivial = false
        bodies.add j
        j += 2
        continue
      let hasC = m.toks[^1].kind == fkComment and not m.toks[^1].text.startsWith("#[") and
                 not m.toks[^1].text.startsWith("##")
      if hasC: commented = j
      let mt2 = if hasC: m.toks[0 ..< m.toks.high] else: m.toks
      let (h, stop) = fSplitIdx(mt2, 0, mt2.len)
      if h < 0 or stop < mt2.len or mt2[^1].kind == fkComment or m.verbatim or not fSimpleTail(mt2, h + 1) or
         fBranchWidth(mt2, l.depth) > FmtMax:
        trivial = false
      inc j
    if trivial:
      for b in branches: inlineBranch[b] = true
      for b in bodies:
        work[b].toks = work[b].toks & work[b + 1].toks
        absorbed[b + 1] = true
      # (the last branch's trailing comment is the case's own: nph puts it on a line after the branches)
      if commented >= 0: lastBranchComment[commented] = true
  i = 0
  while i < work.len:
    template l: untyped = work[i]
    if absorbed[i]:
      inc i
      continue
    # where are we: in a type section (members at depth+1), an enum body?
    if not l.comment:
      if typeDepth >= 0 and l.depth <= typeDepth: typeDepth = -1
      if enumDepth >= 0 and l.depth <= enumDepth: enumDepth = -1
      if secDepth >= 0 and l.depth <= secDepth: secDepth = -1
    var o = FOut(depth: l.depth, toks: l.toks, blank: l.blank, comment: l.comment, verbatim: l.verbatim,
                 keep: l.keep, origText: l.origText, importish: l.origText == "import")
    if not l.comment:
      let k0 = l.toks[0]
      o.declLike = (secDepth >= 0 and l.depth == secDepth + 1) or typeDepth >= 0 or
                   (k0.kind == fkKw and (k0.text in FSectionKw or k0.text in FRoutineKw))
      if k0.kind == fkKw and k0.text in FSectionKw and (l.toks.len == 1 or l.toks[1].kind == fkComment):
        secDepth = l.depth
    if l.comment or l.verbatim:
      if l.verbatim:
        # (a value under `x =` holding a long string: nph's layout may join or break it — fNphLayout)
        var pc = i - 1
        while pc >= 0 and work[pc].comment: dec pc
        o.exprLine = pc >= 0 and l.depth == work[pc].depth + 1 and fValueEq(work[pc].toks)
      result.add o
      inc i
      continue
    let t0 = l.toks[0]
    let inType = typeDepth >= 0 and l.depth > typeDepth
    if not inType and fLambdaCmd(l.toks):
      # `cmd a, b, proc(…) =`: the arguments one a line (fRenderLine), the lambda's body under the lambda
      o.lambdaCmd = true
      var j = i + 1
      while j < work.len and work[j].depth > l.depth:
        work[j].depth += 1
        inc j
      result.add o
      inc i
      continue
    # a value on its own line after `x =` (not a routine body): an expression, never split
    var pc = i - 1
    while pc >= 0 and work[pc].comment: dec pc
    if pc >= 0 and l.depth == work[pc].depth + 1 and
       (fValueEq(work[pc].toks) or (work[pc].toks.len == 1 and work[pc].toks[0].kind == fkKw and
                                    work[pc].toks[0].text in ["return", "yield", "discard", "raise"])):
      o.exprLine = true
    if t0.kind == fkKw and t0.text == "type":
      typeDepth = l.depth
      o.complexKind = 2
      if l.toks.len > 1 and fTypeMemberComplex(l): o.complexKind = 2
    if inType and l.depth == typeDepth + 1 and fTypeMemberComplex(l): o.complexKind = 3
    if t0.kind == fkKw and t0.text == "type" and l.toks.len > 1 and fTypeMemberComplex(l): o.complexKind = 2
    # `Name = ptr object` with fields under it: `Name =` ⏎ `ptr object` ⏎ the fields one deeper (like nph: a
    # `ptr` type is not one it keeps on the line of the `=` when it does not fit there)
    if ((inType and l.depth == typeDepth + 1) or t0.kind == fkKw and t0.text == "type") and l.toks.len >= 4 and
       l.toks[^1].kind == fkKw and
       l.toks[^1].text == "object" and l.toks[^2].kind == fkKw and l.toks[^2].text == "ptr" and
       l.toks[^3].kind == fkOp and l.toks[^3].text == "=" and i + 1 < work.len and work[i + 1].depth > l.depth:
      var head = o
      head.toks = l.toks[0 .. ^3]
      result.add head
      var po = FOut(depth: l.depth + 1, toks: l.toks[^2 .. ^1])
      po.toks[0].nl = true
      result.add po
      var j = i + 1
      while j < work.len and work[j].depth > l.depth:
        work[j].depth += 1
        inc j
      inc i
      continue
    # enum values: one per line
    let isEnumLine = enumDepth >= 0 and l.depth == enumDepth + 1
    var enumAt = -1
    for k2, t in l.toks:
      # (an enum's definition: `= enum` — not `SomeNumber | enum | ptr`, a type class)
      if t.kind == fkKw and t.text == "enum" and k2 > 0 and l.toks[k2 - 1].kind == fkOp and
         l.toks[k2 - 1].text == "=" and not (k2 < l.toks.high and l.toks[k2 + 1].kind == fkOp):
        enumAt = k2
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
          elif t.kind == fkComment and curv.len == 0 and vals.len > 0 and fEnumComment(vals[^1], t): vals[^1].add t
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
        elif t.kind == fkComment and curv.len == 0 and vals.len > 0 and fEnumComment(vals[^1], t): vals[^1].add t
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
    # (a trailing `#` comment is the statement's own, not its last branch's: `x = if a: b else: c # note` stays
    # inline when the code fits — the comment goes under it when the line is too long, like nph)
    let codeEnd = if l.toks.len > 2 and l.toks[^1].kind == fkComment and not l.toks[^1].text.startsWith("#[") and
                     not l.toks[^1].text.startsWith("##"): l.toks.high
                  else: l.toks.len
    if splitHere and (inlineBranch[i] or fKeepInline(l.toks.toOpenArray(0, codeEnd - 1), l.depth)): splitHere = false
    if lastBranchComment[i]:
      o.toks = l.toks[0 ..< codeEnd]
      result.add o
      result.add FOut(depth: l.depth, toks: @[l.toks[^1]], comment: true)
      inc i
      continue
    if inType:
      # (an object branch keeps its fields inline — and `of x: discard`, `of x: nil` too, like nph; other
      # one-line statements in a type (`when x: discard` ⏎ …) are split)
      let (h0, stop0) = fSplitIdx(l.toks, 0, l.toks.len)
      let body0Len = if h0 < 0: 0 else: stop0 - (h0 + 1)
      splitHere = body0Len > 0 and l.toks[h0 + 1].kind == fkKw and l.toks[h0 + 1].text in ["discard", "nil"] and
                  not (t0.kind == fkKw and t0.text == "of" and body0Len == 1)
    # `runnableExamples: body`, `assert: x` — a call given a block on its line (not a field, not a section's
    # member): `name:` ⏎ its body under it (like nph); the body is looked at again as a line of its own
    if splitHere and not o.declLike and fColonBlock(l.toks, 0, l.toks.len) and l.toks[^1].kind != fkComment and
       not fOpensBlock(l):
      var head = o
      head.toks = l.toks[0 .. 1]
      result.add head
      let body = l.toks[2 .. ^1]
      work[i].toks = body
      work[i].depth = work[i].depth + 1
      work[i].blank = false
      work[i].toks[0].nl = true
      continue
    if splitHere and fSplitIdx(l.toks, 0, l.toks.len)[0] < 0 and fValueIf(l.toks, l.depth) < 0:
      # (nothing to split — most lines: what the loop below gives for it, without its copies)
      o.origText = ""
      o.exprLine = o.exprLine and not ifExpr
      if t0.kind == fkKw and t0.text in FRoutineKw and t0.text notin ["func"]: o.complexKind = 1
      result.add move(o)
      inc i
      continue
    if splitHere:
      var pending = @[(l.toks, l.depth, l.blank)]
      var first = true
      let startLen = result.len
      while pending.len > 0:
        let (toks, dep, blnk) = pending[0]
        pending.delete(0)
        let veq = fValueIf(toks, dep)
        if veq >= 0:
          # x = if a: f() else: g()  →  x = ⏎ if a: ⏎ f() ⏎ else: ⏎ g()
          result.add FOut(depth: dep, toks: toks[0 .. veq], blank: blnk and first,
                          complexKind: (if first: o.complexKind else: 0), importish: o.importish)
          first = false
          pending.insert((toks[veq + 1 .. ^1], dep + 1, false), 0)
          continue
        if not first and fKeepInline(toks, dep):
          result.add FOut(depth: dep, toks: toks, importish: o.importish)
          continue
        let (hdr, body, rest) = fSplitStatement(FLine(toks: toks, depth: dep))
        var oo = FOut(depth: dep, toks: hdr, blank: blnk and first, complexKind: (if first: o.complexKind else: 0),
                      declLike: first and o.declLike,
                      importish: o.importish, exprLine: o.exprLine and not ifExpr)
        if hdr[0].kind == fkKw and hdr[0].text in FRoutineKw and hdr[0].text notin ["func"]:
          oo.complexKind = 1           # (a blank line after it when it takes more than one line — a forward
                                       #  declaration too, like nph)
        result.add oo
        first = false
        if body.len > 0:
          let (h2, b2, r2) = fSplitStatement(FLine(toks: body, depth: dep + 1))
          if (b2.len > 0 and not fKeepInline(body, dep + 1)) or fValueIf(body, dep + 1) >= 0:
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
      # (a block written on one line with a trailing comment — like nph: after an `of` branch's body followed by
      # another branch, the comment goes on a line of its own at the `of`'s level; after a body that is a command
      # (`static: doAssert x # note`), on a line of its own under it; else it stays on the body's line)
      if result.len - startLen > 1 and not fOpensBlock(l) and not result[^1].comment:
        let lt = result[^1].toks
        if lt.len > 1 and lt[^1].kind == fkComment and not lt[^1].text.startsWith("##") and
           not lt[^1].text.startsWith("#["):
          var nx = i + 1
          while nx < work.len and work[nx].comment: inc nx
          let branchNext = t0.kind == fkKw and t0.text == "of" and nx < work.len and work[nx].depth == l.depth and
                           work[nx].toks[0].kind == fkKw and work[nx].toks[0].text in ["of", "elif", "else"]
          if branchNext or fCommandLike(lt[0 ..< lt.high]) or (t0.kind == fkKw and t0.text in ["static", "defer"]):
            let c = lt[^1]
            result[^1].toks = lt[0 ..< lt.high]
            result.add FOut(depth: (if branchNext: l.depth else: result[^1].depth), toks: @[c], comment: true)
      inc i
      continue
    result.add o
    inc i

const FOpClasses = [@["or", "xor"], @["and"], @["==", "!=", "<", "<=", ">", ">=", "in", "notin", "is", "isnot", "of"],
                    @["&"], @["+", "-", "|"], @["*", "/", "%", "div", "mod", "shl", "shr"]]

func fUnaryAt*(toks: openArray[FTok], k: int): bool =
  ## the operator at k applies to what follows it: spaced before and not after (`f %x`, `echo -1`) — never a
  ## place to break a line
  k + 1 < toks.len and (toks[k].sp or toks[k].nl) and not (toks[k + 1].sp or toks[k + 1].nl)

func fExportStar*(toks: openArray[FTok], k: int): bool =
  ## the `*` at k marks a name exported (`x*: int`, `x* = 1`, `x* {.used.}`), not a product
  toks[k].kind == fkOp and toks[k].text == "*" and
    (k + 1 >= toks.len or toks[k + 1].kind in {fkColon, fkPragOpen, fkComma, fkClose, fkSemi} or
     (toks[k + 1].kind == fkOp and toks[k + 1].text == "="))

func fFitLen(s: string): int =
  ## a line's length as nph counts it: a trailing `,` `:` or operator does not count
  var e = s.len
  while e > 0 and s[e - 1] == ' ': dec e
  if e > 0 and s[e - 1] in {',', ':'}: return e - 1
  var k = e
  while k > 0 and s[k - 1] in {'&', '+', '-', '*', '/', '<', '>', '=', '!', '|', '%', '^', '~', '.', '@', '$', '?'}: dec k
  if k < e and k > 0 and s[k - 1] == ' ': return k - 1
  for w in ["and", "or", "xor", "in", "notin", "is", "isnot", "div", "mod", "shl", "shr", "of"]:
    if e > w.len and s[e - w.len - 1] == ' ' and s[e - w.len ..< e] == w: return e - w.len - 1
  e

proc fWrapGroup*(prefix: seq[FTok], inner: seq[FTok], suffix: seq[FTok], ind: int, innerInd: int,
                onePerLine: bool, params = false, importish = false, noTrailing = false): seq[string]

proc fLiteralGroup(sg: seq[FTok]): (int, int) =
  ## a piece of an expression that is one literal — `[a, b]`, `@[…]`, `{…}`, `(a, b)` — maybe with the operator
  ## after it: (its open, its close), else (-1, -1)
  var last = sg.high
  if last > 0 and (sg[last].kind in {fkOp, fkColon} or fWordOp(sg[last])): dec last
  let open = 0                 # (not `@[…]`: nph leaves that on a line of its own)
  if last <= open + 1 or sg[open].kind != fkOpen or sg[last].kind != fkClose: return (-1, -1)
  var d = 0
  for k in open .. last:
    if sg[k].kind in {fkOpen, fkPragOpen}: inc d
    elif sg[k].kind in {fkClose, fkPragClose}:
      dec d
      if d == 0 and k < last: return (-1, -1)
  (open, last)

proc fBreakOps(e: seq[FTok], pad, contPad: string): seq[string]

proc fLastGroup(a: seq[FTok]): (int, int) =
  ## the last bracket group at the top of a piece (a call's or a `(…)`'s), before a trailing operator or `:` —
  ## (its open, its close), else (-1, -1)
  var last = a.high
  while last > 0 and (a[last].kind in {fkOp, fkColon} or fWordOp(a[last])): dec last
  if last < 1 or a[last].kind != fkClose: return (-1, -1)
  var d = 0
  for k in countdown(last, 0):
    if a[k].kind in {fkClose, fkPragClose}: inc d
    elif a[k].kind in {fkOpen, fkPragOpen}:
      dec d
      if d == 0:
        if a[k].kind != fkOpen or last - k < 2: return (-1, -1)
        return (k, last)
  (-1, -1)

proc fPackSegs(segs: seq[seq[FTok]], pad, contPad: string): seq[string] =
  ## an expression's pieces (split after operators of one class) packed: as many whole pieces a line as fit. A
  ## piece too long by itself that ends in a call or `(…)` is wrapped there, the rest after its `)` (`if f(` ⏎
  ## args ⏎ `) == 0:`); a literal last piece that does not fit on its own line goes back up and is wrapped
  ## there (`fmt % [` ⏎ items ⏎ `]`); else a piece too long is broken at its own operators — like nph
  var parts: seq[(string, seq[FTok], int)]
  var lead = pad
  var acc: seq[FTok]
  var n = 0
  for sg in segs:
    if acc.len > 0 and fFitLen(lead & fRender(acc & sg)) > FmtMax:
      parts.add (lead, acc, n)
      lead = contPad
      acc = @[]
      n = 0
    acc.add sg
    inc n
  if acc.len > 0: parts.add (lead, acc, n)
  proc plain(res: var seq[string], l: string, a: seq[FTok]) =
    let r = l & fRender(a)
    let sub = if fFitLen(r) > FmtMax: fBreakOps(a, l, contPad) else: @[]
    if sub.len > 1: res.add sub else: res.add r
  # the first piece too long by itself: a literal or `(…)` goes back up onto the line before and is wrapped there
  # (`x in {` ⏎ items ⏎ `}:`), one ending in a call or (…) is wrapped in place — what follows after its close
  for pi in 0 ..< parts.len:
    let (l, a, cnt) = parts[pi]
    if cnt != 1 or fFitLen(l & fRender(a)) <= FmtMax: continue
    var rest: seq[FTok]
    for pj in pi + 1 ..< parts.len: rest.add parts[pj][1]
    let (lo, lc) = fLiteralGroup(a)
    var w: seq[string]
    var first = pi
    if lo >= 0 and pi > 0:
      let (pl, pa, _) = parts[pi - 1]
      let joined = pa & a
      let o = pa.len + lo
      let c = pa.len + lc
      w = fWrapGroup(joined[0 .. o], joined[o + 1 ..< c], joined[c .. ^1] & rest, pl.len, pl.len + 2, false)
      first = pi - 1
    if not (w.len >= 3 and fFitLen(w[0]) <= FmtMax and fFitLen(w[^1]) <= FmtMax):
      first = pi
      w = @[]
      let (go, gc) = fLastGroup(a)
      if go >= 0:
        w = fWrapGroup(a[0 .. go], a[go + 1 ..< gc], a[gc .. ^1] & rest, l.len, l.len + 2, false)
    if w.len >= 3 and fFitLen(w[0]) <= FmtMax and fFitLen(w[^1]) <= FmtMax:
      for pj in 0 ..< first: plain(result, parts[pj][0], parts[pj][1])
      result.add w
      return
    break
  for (l, a, _) in parts: plain(result, l, a)

proc fOpSegs(e: seq[FTok], cls: openArray[string], isCond = false): seq[seq[FTok]] =
  ## e split after each operator of the class (at the top, binary ones)
  var cur: seq[FTok]
  var d = 0
  for k, t in e:
    cur.add t
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.text in cls and (t.kind == fkKw or t.kind == fkOp) and k > 0 and k < e.high and
         fOperand(e[k - 1]) and e[k + 1].kind notin {fkComma, fkComment} and not fExportStar(e, k) and
         not fExportMark(e, k) and              # (`type X*[T] … = object`: no line break after that `*`)
         not (t.kind == fkOp and fUnaryAt(e, k)) and not (isCond and k == e.high - 1):
      result.add cur
      cur = @[]
  if cur.len > 0: result.add cur

proc fBreakOps(e: seq[FTok], pad, contPad: string): seq[string] =
  ## a long expression broken after its loosest operator, as many whole operands a line as fit (like nph) —
  ## @[] when it has no operator to break at
  for cls in FOpClasses:
    let segs = fOpSegs(e, cls)
    if segs.len < 2: continue
    return fPackSegs(segs, pad, contPad)

proc fSimpleElem(e: openArray[FTok]): bool =
  ## nph's "simple" list element: a name, a literal, a.b, -1 (lists of them are packed; anything else gets a line)
  var last = e.high
  while last >= 0 and e[last].kind in {fkComment, fkComma, fkSemi, fkColon}: dec last
  for k in 0 .. last:
    let t = e[k]
    case t.kind
    of fkIdent, fkNum, fkStr, fkChar, fkDot, fkComment: discard
    of fkKw:
      if t.text != "nil": return false
    of fkOp:
      if not (k == 0 and t.text == "-" and k < last and e[k + 1].kind == fkNum): return false
    else: return false
  true

proc fWrapElem(e: seq[FTok], ind: int, importish: bool): seq[string] =
  ## an element still too long on its own line: the bracket group it ends with wrapped in turn (nph wraps all the
  ## way down) — @[] when it does not end with one
  var last = e.high
  while last >= 0 and e[last].kind == fkComma: dec last
  if last < 1 or e[last].kind != fkClose: return
  for t in e:
    if t.kind == fkComment: return
  var d = 0
  var open = -1
  for k in countdown(last, 0):
    let t = e[k]
    if t.kind in {fkClose, fkPragClose}: inc d
    elif t.kind in {fkOpen, fkPragOpen}:
      dec d
      if d == 0:
        open = k
        break
  if open < 0 or last - open < 2: return
  fWrapGroup(e[0 .. open], e[open + 1 ..< last], e[last .. ^1], ind, ind + 2, false, importish = importish)

proc fPragmaWrap(toks: seq[FTok], ind, pind: int): seq[string] =
  ## a line too long for its pragma: `… {.` ⏎ the pragmas (on one line, else one a line) ⏎ `.} …` (like nph);
  ## @[] when it has no pragma to wrap
  var d = 0
  var open = -1
  for k, t in toks:
    if t.kind == fkPragOpen and d <= 0:        # (`) {.…` : the closing bracket of the parameters before it)
      open = k
      break
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
  if open < 0: return
  var close = -1
  d = 0
  for k in open ..< toks.len:
    let t = toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}:
      dec d
      if d == 0:
        close = k
        break
  if close < open + 2 or toks[close].kind != fkPragClose: return
  for k in open .. close:
    if toks[k].kind == fkComment or (k > open and toks[k].nl and toks[k].kind == fkStr and toks[k].text.startsWith("\"\"\"")):
      return
  fWrapGroup(toks[0 .. open], toks[open + 1 ..< close], toks[close .. ^1], ind, pind, false, noTrailing = true)

proc fLambdaAt*(e: openArray[FTok], a: int): int =
  ## e[a] starts a lambda (`proc(x: int): int =` …): the index of the `=` its body follows, else -1
  if a + 1 >= e.len or e[a].kind != fkKw or e[a].text notin ["proc", "func", "iterator"] or
     e[a + 1].kind != fkOpen or e[a + 1].text != "(":
    return -1
  var d = 0
  for k in a ..< e.len:
    let t = e[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkOp and t.text == "=": return k
    elif d == 0 and t.kind in {fkComma, fkSemi, fkComment}: return -1
  -1

proc fBlockElem*(e: openArray[FTok]): (int, int) =
  ## a list element nph writes as a block: a lambda with its body on the line (`proc(x: int): int = x + 1`, also
  ## as `name = …` or `name: …`) or an if-expression whose branches are not plain values — (0 a lambda, 1 an if;
  ## where it starts), or (-1, -1)
  result = (-1, -1)
  var last = e.high
  while last >= 0 and e[last].kind == fkComma: dec last
  if last < 3: return
  for k in 0 .. last:
    if e[k].kind == fkComment: return
  var a = 0
  if e[0].kind == fkIdent and ((e[1].kind == fkOp and e[1].text == "=") or e[1].kind == fkColon): a = 2
  let eq = fLambdaAt(e, a)
  if eq > a and eq < last:
    for k in eq + 1 .. last:
      if e[k].kind == fkSemi or (e[k].kind == fkKw and e[k].text in FBlockKw): return    # (one plain body only)
    return (0, a)
  # (also `name: if a: x else: y` — nph puts the if-expression under `name:`)
  if e[a].kind == fkKw and e[a].text in ["if", "when"]:
    let (h, _) = fSplitIdx(e, a, last + 1)
    if h <= a or fInlineIf(e, a, last + 1): return
    var d = 0
    var hasElse = false
    for k in h + 1 .. last:
      let t = e[k]
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
      elif d == 0 and t.kind == fkKw and t.text == "else": hasElse = true
      elif d == 0 and t.kind == fkSemi: return
    if hasElse: return (1, a)

proc fCommandLike*(toks: openArray[FTok]): bool =
  ## a statement or a command call (`echo x`, `s.add item`, `discard f()`): a comma after it would be read as more
  ## of its arguments
  if toks.len == 0: return false
  if toks[0].kind == fkKw and toks[0].text == "echo": return true
  if toks[0].kind == fkKw and toks[0].text in ["discard", "return", "raise", "yield", "break", "continue"]:
    # (these end at a comma themselves — `return x,` — unless what they are given is a command: `return f x`)
    return toks.len > 1 and fCommandLike(toks[1 .. ^1])
  var d = 0
  for k, t in toks:
    if t.kind in {fkOpen, fkPragOpen}:
      if d == 0 and k > 0 and (t.sp or t.nl) and fOperand(toks[k - 1]): return true     # `f (a, b)`, `f [x]`
      inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and k > 0 and (t.sp or t.nl) and t.kind in {fkIdent, fkNum, fkStr, fkChar} and fOperand(toks[k - 1]):
      return true
    elif d == 0 and k > 0 and t.kind == fkOp and (t.sp or t.nl) and k + 1 < toks.len and
         not (toks[k + 1].sp or toks[k + 1].nl) and fOperand(toks[k - 1]):
      return true                                            # `f -1`: a prefix operator, an argument
  false

proc fRenderLine*(o0: FOut, lines: seq[string]): seq[string]

proc fBlockElemLines*(e: seq[FTok], kind, a, ind: int): seq[string] =
  ## a list element (fBlockElem) as nph writes it: `proc(x: int): int =` ⏎ its body, or `if a:` ⏎ value ⏎
  ## `else:` ⏎ value — a comma after its last line when it has one; @[] when it cannot be split so
  var last = e.high
  var tail = ""
  if last >= 0 and e[last].kind == fkComma:
    tail = ","
    dec last
  let pad = spaces(ind)
  var lastPart: seq[FTok]
  # (each header and value on its line — wrapped there when too long, as a statement of its own: like nph)
  template line(part: seq[FTok], at: int): seq[string] = fRenderLine(FOut(depth: at div 2, toks: part), @[])
  if kind == 0:
    let eq = fLambdaAt(e, a)
    if eq < 0: return @[]
    lastPart = e[eq + 1 .. last]
    result = @[pad & fRender(e[0 .. eq])]
    result.add line(lastPart, ind + 2)
  else:
    # (`name: if …`: `name:` on its line, the if-expression under it)
    let ipad = if a > 0: ind + 2 else: ind
    let ibpad = if a > 0: ind + 4 else: ind + 2
    if a > 0: result.add pad & fRender(e[0 ..< a])
    var rest = e[a .. last]
    var branches = 0
    while rest.len > 0:
      let (h, stop) = fSplitIdx(rest, 0, rest.len)
      if h < 0 or h + 1 >= stop: return @[]
      result.add line(rest[0 .. h], ipad)
      lastPart = rest[h + 1 ..< stop]
      result.add line(lastPart, ibpad)
      rest = rest[stop .. ^1]
      inc branches
    if branches < 2: return @[]
  # (after a command the comma goes on a line of its own: `s.add x,` would give it one more argument — like nph)
  if tail.len > 0:
    if fCommandLike(lastPart): result.add pad & tail
    else: result[^1].add tail

proc fBlockElemGroup*(toks: seq[FTok]): (int, int) =
  ## the call (or object construction) of a line whose arguments hold a block element (fBlockElem): nph writes
  ## them one a line however short the line is — (its `(`, its `)`), or (-1, -1) (none, or more than one such call)
  result = (-1, -1)
  var d = 0
  var k = 0
  while k < toks.len:
    let t = toks[k]
    if t.kind == fkOpen and d == 0 and t.text == "(" and fCallParen(toks, k):
      var dd = 0
      var close = -1
      var elemStart = k + 1
      var found = false
      for j in k ..< toks.len:
        let u = toks[j]
        if u.kind in {fkOpen, fkPragOpen}: inc dd
        elif u.kind in {fkClose, fkPragClose}:
          dec dd
          if dd == 0:
            close = j
            if fBlockElem(toks.toOpenArray(elemStart, j - 1))[0] >= 0: found = true
            break
        elif dd == 1 and u.kind == fkComma:
          if fBlockElem(toks.toOpenArray(elemStart, j))[0] >= 0: found = true
          elemStart = j + 1
      if close < 0: return (-1, -1)
      if found:
        if result[0] >= 0: return (-1, -1)
        result = (k, close)
      k = close + 1
      continue
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    inc k

proc fWrapGroup*(prefix: seq[FTok], inner: seq[FTok], suffix: seq[FTok], ind: int, innerInd: int,
                onePerLine: bool, params = false, importish = false, noTrailing = false): seq[string] =
  ## prefix( ⏎ inner ⏎ )suffix   — inner packed on lines (or one element per line, with a trailing comma)
  # (a statement in parentheses — `(for k, v in a: (k, v))` — has no list to lay out: its commas are its own)
  if inner.len > 0 and inner[0].kind == fkKw and prefix.len > 0 and prefix[^1].text == "(" and
     inner[0].text in ["for", "while", "let", "var", "const", "discard", "return", "break", "continue", "raise",
                       "yield", "defer"]:
    return @[]
  var elems: seq[seq[FTok]]
  var cur: seq[FTok]
  var d = 0
  var hasComment = false
  var typed = false
  var postfix: seq[int]              # comment lines that belong to the element before them
  for ti, t in inner:
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
    elif t.kind == fkComment and d == 0 and (cur.len == 0 or (t.nl and cur[^1].kind == fkComment)):
      if cur.len > 0:
        # (a comment line after an element's trailing comment, before its comma: a line of its own — not on that
        # comment's line, where it would be part of it. But when the element goes on after the comment lines —
        # `(a or # c1` ⏎ `# c2` ⏎ `b)`, no comma — it is one element, laid out as written: split there, `(…)`
        # would get a trailing comma and become a tuple)
        var nx = ti + 1
        while nx < inner.len and inner[nx].kind == fkComment: inc nx
        if nx < inner.len and inner[nx].kind notin {fkComma, fkSemi}: return @[]
        elems.add cur
        cur = @[]
      hasComment = true
      if elems.len > 0 and not t.nl: elems[^1].add t   # a comment after an element's comma stays with it
      else:
        # a comment on its own line — under the element before it and deeper: that element's (2 deeper, nph)
        if elems.len > 0 and elems[^1].len > 0 and elems[^1][0].kind != fkComment and elems[^1][0].nl and
           elems[^1][^1].kind != fkComment and t.col > elems[^1][0].col:
          postfix.add elems.len
        elems.add @[t]
    elif t.kind == fkComment:
      hasComment = true
      cur.add t
    else:
      if cur.len > 0 and cur[^1].kind == fkComment: return @[]   # a comment inside an element: keep the layout
      cur.add t
  if cur.len > 0: elems.add cur
  if elems.len == 0: return @[]
  # (`f(proc() = echo a, b)`: the commas after a lambda's command are the command's, not the list's — as written)
  for ei in 0 ..< elems.high:
    let e = elems[ei]
    var a = 0
    if e.len > 2 and e[0].kind == fkIdent and (e[1].kind == fkColon or (e[1].kind == fkOp and e[1].text == "=")): a = 2
    let eq = fLambdaAt(e, a)
    var last = e.high
    while last > eq and e[last].kind in {fkComma, fkComment}: dec last
    if eq > 0 and eq < last and fCommandLike(e.toOpenArray(eq + 1, last)): return @[]
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
  # (after parameters without a type a `;`, like nph: `a, b,` ⏎ `)` would wait for another name)
  if elems[^1].len > 0 and elems[^1][0].kind != fkComment and not parenOne and codeElems > 1 and not noTrailing:
    var k = elems[^1].high
    while k >= 0 and elems[^1][k].kind == fkComment: dec k
    if k >= 0 and elems[^1][k].kind notin {fkComma, fkSemi}:
      elems[^1].insert((if params and not typed: FTok(kind: fkSemi, text: ";") else: FTok(kind: fkComma, text: ",")),
                       k + 1)
  # nph packs simple elements (names, literals, a.b, -1) and gives anything else a line of its own (a call, an
  # operator, a `name: value`)
  var allSimple = true
  for e in elems:
    var last = e.high
    while last >= 0 and e[last].kind in {fkComment, fkComma, fkSemi}: dec last
    for k in 0 .. last:
      let t = e[k]
      case t.kind
      of fkIdent, fkNum, fkStr, fkChar, fkDot: discard
      of fkKw:
        if t.text != "nil": allSimple = false
      of fkOp:
        if not (k == 0 and t.text == "-" and k < last and e[k + 1].kind == fkNum): allSimple = false
      of fkComment: discard
      else: allSimple = false
  let forced = onePerLine
  let onePerLine = onePerLine or not allSimple
  let pad = spaces(innerInd)
  result.add spaces(ind) & fRender(prefix, importish = importish)
  var lines: seq[string]
  let single = block:
    var s = pad
    for k, e in elems:
      var ee = e
      if k == elems.high and ee.len > 0 and ee[^1].kind in {fkComma, fkSemi}: ee.setLen(ee.len - 1)
      s.add (if k > 0: " " else: "") & fRender(ee, importish = importish)
    s
  var blockElems = false
  if not params:
    for e in elems:
      if fBlockElem(e)[0] >= 0: blockElems = true
  if not hasComment and not forced and not blockElems and single.len <= FmtMax:
    lines.add single
  elif onePerLine or hasComment:
    for e in elems:
      if not params:
        let (bk, ba) = fBlockElem(e)
        if bk >= 0:
          let bl = fBlockElemLines(e, bk, ba, innerInd)
          if bl.len > 0:
            lines.add bl
            continue
      let r = pad & fRender(e, importish = importish)
      if e.len == 1 and e[0].kind == fkComment and postfix.len > 0 and elems.find(e) in postfix:
        lines.add pad & "  " & e[0].text
        continue
      # (an element's trailing comment that does not fit after it: on the next line, 2 deeper — like nph)
      # (not a doc comment: Nim reads `##` as part of the code, which it cannot be on a line of its own there)
      if r.len > FmtMax and e.len > 2 and e[^1].kind == fkComment and e[^2].kind == fkComma and
         not e[^1].text.startsWith("#[") and not e[^1].text.startsWith("##"):
        let code = pad & fRender(e[0 ..< e.high], importish = importish)
        if code.len <= FmtMax:
          lines.add code
          lines.add pad & "  " & e[^1].text
          continue
      let colon = fTop(e, proc(t: FTok, d: int): bool = t.kind == fkColon)
      if r.len > FmtMax and not params:
        var w = fWrapElem(e, innerInd, importish)
        if w.len == 0 and colon < 0 and fTopEq(e, 0, e.len) < 0:
          # (inside `(…)` that only groups an expression its lines line up; an argument's go 2 deeper)
          w = fBreakOps(e, pad, if parenOne: pad else: pad & "  ")
        if w.len > 0:
          lines.add w
          continue
      var vEnd = e.high
      while vEnd > 0 and e[vEnd].kind in {fkComma, fkComment}: dec vEnd
      if r.len > FmtMax and colon == 1 and e[0].kind == fkIdent and colon < vEnd:
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
  if t.text == "[" and open > 0 and fExportMark(toks, open - 1): return 3      # `array*[I, T]`: generic parameters
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

func fListCount*(inner: openArray[FTok], params: bool): int =
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
  if routine:
    # (the parameters on one line, a bracket after them over several — `): tuple[a,` ⏎ `b: int] =`: that one kept)
    var d = 0
    var open2 = -1
    for k in close + 1 ..< o.toks.len:
      let t {.cursor.} = o.toks[k]
      if t.kind in {fkOpen, fkPragOpen}:
        if d == 0: open2 = k
        inc d
      elif t.kind in {fkClose, fkPragClose}:
        dec d
        if d == 0 and open2 >= 0:
          var brk = false
          for j in open2 + 1 .. k:
            if o.toks[j].nl: brk = true
          if brk and o.toks[open2].kind == fkOpen:
            return fKeepGroup(o.toks[0 .. open2], o.toks[open2 + 1 ..< k], o.toks[k .. ^1], ind, innerInd, o.importish)
          open2 = -1

proc fParamSemis*(toks: seq[FTok]): seq[FTok] =
  ## `a, b: int; c: string` → `…, c: string` in a routine's parameters (same meaning when the part
  ## before the `;` has a type or a default)
  result = toks
  var stack: seq[(int, bool, bool)]       # (open index, is a parameter list, the segment had a type before it)
  var segHasType = false
  # (the routine's own parameters: the first `(` at the top of a line that starts with proc/func/…, after its
  # name and generic parameters)
  var headerParams = -1
  if toks.len > 2 and toks[0].kind == fkKw and toks[0].text in FRoutineKw:
    var d = 0
    for k, t in toks:
      if t.kind == fkOpen and t.text == "(" and d == 0:
        headerParams = k
        break
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
  for k in 0 ..< result.len:
    let t = result[k]
    if t.kind in {fkOpen, fkPragOpen}:
      let isParams = (t.text == "(" and k >= 1 and
        (k == headerParams or
         (result[k - 1].kind == fkKw and result[k - 1].text in FRoutineKw) or
         (k >= 2 and result[k - 2].kind == fkKw and result[k - 2].text in FRoutineKw) or
         (k >= 3 and result[k - 3].kind == fkKw and result[k - 3].text in FRoutineKw and result[k - 1].kind == fkOp))) or
        (t.text == "[" and k >= 1 and result[k - 1].kind == fkKw and result[k - 1].text == "tuple")
      stack.add (k, isParams, segHasType)
      segHasType = false
    elif t.kind in {fkClose, fkPragClose}:
      if stack.len > 0:
        segHasType = stack[^1][2]
        stack.setLen(stack.len - 1)
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
    elif t.kind == fkSemi and groups.len > 0 and groups[^1][0] == "call" and k + 1 < toks.len and
         toks[k + 1].kind == fkClose:
      continue                   # (nph's `;` after a last parameter without a type: `f(a, b;)`)
    result.add t

proc fAsWritten*(o: FOut): seq[string] =
  ## what cannot be wrapped stays on one (long) line — broken only after comments inside it
  var cur: seq[FTok]
  var extra = 0
  for k, t in o.toks:
    cur.add t
    # (not after a `#[ … ]#` in the middle of the line: `hel#[!]#lo()` is `hel lo()`, a line apart two statements)
    if t.kind == fkComment and k < o.toks.high and not t.text.startsWith("#[") and not t.text.startsWith("##["):
      result.add spaces(o.depth * 2 + extra) & fRender(cur, importish = o.importish)
      cur = @[]
      extra = 4
  if cur.len > 0: result.add spaces(o.depth * 2 + extra) & fRender(cur, importish = o.importish)

# ── nph's layout of a long statement ──
# The statement's tokens are read the way nph's parser reads them (calls, brackets, operators by precedence,
# dots, commands, `k: v` and `k = v` arguments) and that tree is laid out the way nph's renderer lays it out:
# the same questions (does it fit here? on the next line? one element a line?) asked in the same order. What
# it decides is where lines break (and how deep the new line starts) and where a trailing comma is added; the
# text between the breaks is the statement's own one-line rendering. A long string over several lines counts
# as nph counts it: what holds it never fits on one line.

type
  XKind = enum
    xAtom, xList, xCall, xIndex, xCurlyX, xInfix, xPrefix, xDot, xColon, xEq, xCommand, xCast, xParam, xProcTy
  XFlag = enum
    xfNoIndent, xfLongIndent, xfStackDot, xfStackDotInCall
  XNode = object
    kind: XKind
    a, b: int              # its tokens: [a, b)
    l, r: int              # its parts: a call's callee and argument list, an operator's operands, …
    op: int                # the operator's token; a list's opening bracket
    close: int             # a list's closing bracket
    elems: seq[int]        # a list's elements, a command's arguments
    lk: int                # a bracket on its own: 0 `(x)`, 1 a tuple, 2 `[…]`, 3 `{…}`, 4 pragmas `{.….}`,
                           # 5 parameters
    v: int                 # a parameter's default value; a proc type's pragmas (-1: none)
    obj: bool              # a call whose first argument is `name: value` (nph: an object construction)
  XLen = tuple[len: int, nl: bool]     # nph's LineLen: the first line's length, and whether a line break follows
  XTree = object
    toks: seq[FTok]
    n: seq[XNode]
    fail: bool
    noCmd: int             # inside pragmas: no command syntax
    typeCtx: int           # reading a type: `proc(…)` is a proc type (not a lambda)
    pos: seq[int]          # each token's column in the statement's one-line rendering
    sp: seq[bool]          # a space before it there
    firstMulti: seq[int]   # the first token at or after it that holds a line break (toks.len: none)
    brk: seq[int]          # a line starts at the token: its indentation (-1: none)
    comma: seq[char]       # a separator added after the token: ',' (';' after a parameter without a type)
    lineLen, indent, pendingNL: int

proc xNew(x: var XTree, nd: XNode): int =
  x.n.add nd
  x.n.high

func xPrec(t: FTok): int =
  ## nph's precedence of a binary operator (-10: not one)
  if t.kind == fkKw:
    case t.text
    of "div", "mod", "shl", "shr": 9
    of "in", "notin", "is", "isnot", "of", "as": 5
    of "and": 4
    of "or", "xor": 3
    else: -10
  elif t.kind == fkOp and t.text != "=":
    let s = t.text
    if s.len > 1 and s[^1] == '>' and s[^2] in {'-', '~', '='}: return 0      # arrow-like
    let asg = s[^1] == '='
    case s[0]
    of '$', '^': (if asg: 1 else: 10)
    of '*', '%', '/', '\\': (if asg: 1 else: 9)
    of '~': 8
    of '+', '-', '|': (if asg: 1 else: 8)
    of '&': (if asg: 1 else: 7)
    of '=', '<', '>', '!': 5
    of '.': (if asg: 1 else: 6)
    of '?': 2
    else: (if asg: 1 else: 2)
  else: -10

func xCmdStart(x: XTree, k: int): bool =
  ## does toks[k], after an operand, start a command's argument (`echo x`, `f -1`, `(T)x`)?
  if x.noCmd > 0: return false
  let t = x.toks[k]
  case t.kind
  of fkIdent, fkNum, fkChar, fkStr: true
  of fkOpen: t.sp or t.nl
  of fkKw: t.text in ["nil", "cast", "addr"]
  of fkOp: t.text != "=" and fUnaryAt(x.toks, k)
  else: false

proc xExpr(x: var XTree, i, e, limit: int, next: var int, cmd = true): int

proc xList(x: var XTree, open, e: int, next: var int): int =
  ## the bracket group at `open` (or the pragmas `{.….}`): its elements (`a`, `k: v`, `k = v`)
  var d = 0
  var close = -1
  for k in open ..< e:
    let t = x.toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}:
      dec d
      if d == 0:
        close = k
        break
  let prag = x.toks[open].kind == fkPragOpen
  if close < 0 or x.toks[close].kind != (if prag: fkPragClose else: fkClose):
    x.fail = true
    return -1
  if prag: inc x.noCmd
  var elems: seq[int]
  var commas = 0
  var k = open + 1
  while k < close:
    var nx = k
    var el = x.xExpr(k, close, -1, nx)
    if x.fail: return -1
    if nx < close and (x.toks[nx].kind == fkColon or (x.toks[nx].kind == fkOp and x.toks[nx].text == "=")):
      var nx2 = nx
      let r = x.xExpr(nx + 1, close, -1, nx2)
      if x.fail: return -1
      el = x.xNew(XNode(kind: (if x.toks[nx].kind == fkColon: xColon else: xEq), a: k, b: x.n[r].b, l: el, r: r,
                        op: nx))
      nx = nx2
    elems.add el
    if nx < close:
      if x.toks[nx].kind != fkComma:
        x.fail = true
        return -1
      inc commas
      k = nx + 1
    else: k = nx
  if prag: dec x.noCmd
  if commas > 0 and commas >= elems.len and not (elems.len == 1 and x.toks[open].text == "("):
    x.fail = true                       # (a trailing comma: only `(x,)` has one here)
    return -1
  var lk = 2
  if prag: lk = 4
  elif x.toks[open].text == "(":
    lk = (if elems.len == 1 and commas == 0 and x.n[elems[0]].kind != xColon: 0 else: 1)
  elif x.toks[open].text == "{": lk = 3
  next = close + 1
  x.xNew(XNode(kind: xList, a: open, b: close + 1, op: open, close: close, elems: elems, lk: lk))

proc xParamList(x: var XTree, open, e: int, next: var int): int =
  ## a routine's parameters `(a, b: int; c = 1)` (or generic parameters `[T: X]`): one element per group of names
  ## with its type and default (nph's identDefs)
  var d = 0
  var close = -1
  for k in open ..< e:
    let t = x.toks[k]
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}:
      dec d
      if d == 0:
        close = k
        break
  if close < 0 or x.toks[close].kind != fkClose:
    x.fail = true
    return -1
  var elems: seq[int]
  var k = open + 1
  while k < close:
    # the names: `a, b*,` up to the group's `:` or `=` (a name alone before `;` or the end is a group too)
    let start = k
    var q = k
    var namesEnd = -1
    while q < close:
      if x.toks[q].kind != fkIdent:
        x.fail = true
        return -1
      inc q
      if q < close and x.toks[q].kind == fkOp and x.toks[q].text == "*" and not x.toks[q].sp: inc q
      if q < close and x.toks[q].kind == fkComma:
        # (more names of this group — or the next group: `a, b: int` vs `a: int, b`)
        var r = q + 1
        var typed = false
        while r < close:
          let u = x.toks[r]
          if u.kind == fkColon or (u.kind == fkOp and u.text == "="):
            typed = true
            break
          if u.kind != fkIdent and u.kind != fkComma and not (u.kind == fkOp and u.text == "*"): break
          inc r
        if typed or r >= close:
          inc q
          continue
        namesEnd = q
        break
      namesEnd = q
      break
    if namesEnd < 0: namesEnd = q
    if namesEnd <= start:
      x.fail = true
      return -1
    let names = x.xNew(XNode(kind: xAtom, a: start, b: namesEnd))
    var nx = namesEnd
    var tp, colonAt, eqAt, val = -1
    if nx < close and x.toks[nx].kind == fkColon:
      colonAt = nx
      inc x.typeCtx
      tp = x.xExpr(nx + 1, close, -1, nx)
      dec x.typeCtx
      if x.fail: return -1
    if nx < close and x.toks[nx].kind == fkOp and x.toks[nx].text == "=":
      eqAt = nx
      val = x.xExpr(nx + 1, close, -1, nx)
      if x.fail: return -1
    let b = if val >= 0: x.n[val].b elif tp >= 0: x.n[tp].b else: namesEnd
    elems.add x.xNew(XNode(kind: xParam, a: start, b: b, l: names, r: tp, op: colonAt, close: eqAt, v: val))
    if nx < close:
      if x.toks[nx].kind notin {fkComma, fkSemi} or nx + 1 >= close:
        x.fail = true
        return -1
      k = nx + 1
    else: k = nx
  next = close + 1
  x.xNew(XNode(kind: xList, a: open, b: close + 1, op: open, close: close, elems: elems, lk: 5))

proc xPrimary(x: var XTree, i, e: int, next: var int, cmd: bool): int =
  ## an operand: prefix operators, a name or literal or bracket group, then calls, indexes, dots — and with
  ## `cmd` a command (`f x`) whose argument is the rest of the expression
  if i >= e:
    x.fail = true
    return -1
  let t = x.toks[i]
  var nx = i + 1
  var res = -1
  if (t.kind == fkOp and t.text != "=") or (t.kind == fkKw and t.text == "not"):
    let r = x.xPrimary(i + 1, e, nx, true)
    if x.fail: return -1
    next = nx
    return x.xNew(XNode(kind: xPrefix, a: i, b: x.n[r].b, op: i, r: r))
  case t.kind
  of fkIdent, fkNum, fkChar, fkStr: res = x.xNew(XNode(kind: xAtom, a: i, b: i + 1))
  of fkKw:
    if t.text in ["nil", "addr", "tuple"] or (t.text == "static" and i + 1 < e and x.toks[i + 1].kind == fkOpen and
                                             not x.toks[i + 1].sp):
      res = x.xNew(XNode(kind: xAtom, a: i, b: i + 1))
    elif t.text in ["var", "ptr", "ref", "out", "distinct", "static"] and i + 1 < e and x.toks[i + 1].sp:
      # a type's modifier: `var T`, `ptr T`
      let r = x.xPrimary(i + 1, e, nx, false)
      if x.fail: return -1
      next = nx
      return x.xNew(XNode(kind: xPrefix, a: i, b: x.n[r].b, op: i, r: r))
    elif t.text in ["proc", "iterator"] and x.typeCtx > 0 and i + 1 < e and x.toks[i + 1].kind == fkOpen and
         x.toks[i + 1].text == "(":
      # a proc type: `proc(a: int): T {.pragmas.}`
      var nx2 = i + 1
      let params = x.xParamList(i + 1, e, nx2)
      if x.fail: return -1
      var colonAt, ret, prag = -1
      if nx2 < e and x.toks[nx2].kind == fkColon:
        colonAt = nx2
        ret = x.xExpr(nx2 + 1, e, -1, nx2)
        if x.fail: return -1
      if nx2 < e and x.toks[nx2].kind == fkPragOpen:
        prag = x.xList(nx2, e, nx2)
        if x.fail: return -1
      next = nx2
      return x.xNew(XNode(kind: xProcTy, a: i, b: nx2, l: params, op: colonAt, r: ret, v: prag))
    elif t.text == "cast" and i + 1 < e and x.toks[i + 1].kind == fkOpen and x.toks[i + 1].text == "[":
      # cast[T](x): the type as it is, the value laid out
      var d = 0
      var c1 = -1
      for k in i + 1 ..< e:
        if x.toks[k].kind in {fkOpen, fkPragOpen}: inc d
        elif x.toks[k].kind in {fkClose, fkPragClose}:
          dec d
          if d == 0:
            c1 = k
            break
      if c1 < i + 3 or c1 + 2 >= e or x.toks[c1 + 1].kind != fkOpen or x.toks[c1 + 1].text != "(" or
         x.toks[c1 + 1].sp or x.toks[c1 + 1].nl:
        x.fail = true
        return -1
      for k in i + 2 ..< c1:
        if x.toks[k].kind == fkPragOpen or x.toks[k].multi:
          x.fail = true
          return -1
      let tp = x.xNew(XNode(kind: xAtom, a: i + 2, b: c1))
      var nx2 = c1 + 2
      let v = x.xExpr(c1 + 2, e, -1, nx2)
      if x.fail or nx2 >= e or x.toks[nx2].kind != fkClose or x.toks[nx2].text != ")":
        x.fail = true
        return -1
      res = x.xNew(XNode(kind: xCast, a: i, b: nx2 + 1, l: tp, r: v))
      nx = nx2 + 1
    else:
      x.fail = true
      return -1
  of fkOpen:
    var close = -1
    if t.text == "(" and i + 1 < e and x.toks[i + 1].kind == fkKw and x.toks[i + 1].text in ["if", "when"]:
      var d = 0
      for k in i ..< e:
        if x.toks[k].kind in {fkOpen, fkPragOpen}: inc d
        elif x.toks[k].kind in {fkClose, fkPragClose}:
          dec d
          if d == 0:
            close = k
            break
    if close > i + 1:
      # `(if a: x else: y)` with plain values: as it is (nph: a statement list in parentheses, on one line)
      if not fInlineIf(x.toks, i + 1, close):
        x.fail = true
        return -1
      for k in i + 1 ..< close:
        if x.toks[k].multi:
          x.fail = true
          return -1
      res = x.xNew(XNode(kind: xList, a: i, b: close + 1, op: i, close: close, lk: 6))
      nx = close + 1
    else:
      res = x.xList(i, e, nx)
      if x.fail: return -1
  else:
    x.fail = true
    return -1
  while nx < e:
    let u = x.toks[nx]
    if u.kind == fkOpen and not u.sp and not u.nl:
      var nx2 = nx
      let lst = x.xList(nx, e, nx2)
      if x.fail: return -1
      let kind = if u.text == "(": xCall elif u.text == "[": xIndex else: xCurlyX
      let obj = kind == xCall and x.n[lst].elems.len > 0 and x.n[x.n[lst].elems[0]].kind == xColon
      res = x.xNew(XNode(kind: kind, a: x.n[res].a, b: x.n[lst].b, l: res, r: lst, obj: obj))
      nx = nx2
    elif u.kind == fkDot:
      if nx + 1 < e and x.toks[nx + 1].kind in {fkIdent, fkKw, fkStr} and not x.toks[nx + 1].multi:
        let r = x.xNew(XNode(kind: xAtom, a: nx + 1, b: nx + 2))
        res = x.xNew(XNode(kind: xDot, a: x.n[res].a, b: nx + 2, l: res, r: r, op: nx))
        nx += 2
      else:
        x.fail = true
        return -1
    elif cmd and x.xCmdStart(nx):
      var nx2 = nx
      let arg = x.xExpr(nx, e, -1, nx2)
      if x.fail: return -1
      res = x.xNew(XNode(kind: xCommand, a: x.n[res].a, b: x.n[arg].b, l: res, elems: @[arg]))
      nx = nx2
      break
    else: break
  next = nx
  res

proc xExpr(x: var XTree, i, e, limit: int, next: var int, cmd = true): int =
  ## an expression: operands joined by binary operators, by precedence (as nph's parser does)
  var nx = i
  var lhs = x.xPrimary(i, e, nx, cmd)
  if x.fail: return -1
  while nx < e:
    let t = x.toks[nx]
    let p = xPrec(t)
    if p == -10 or p < limit or (t.kind == fkOp and fUnaryAt(x.toks, nx)) or fExportStar(x.toks, nx): break
    let left = if t.kind == fkOp and t.text[0] == '^': 0 else: 1
    var nx2 = nx + 1
    let rhs = x.xExpr(nx + 1, e, p + left, nx2)
    if x.fail: return -1
    lhs = x.xNew(XNode(kind: xInfix, a: x.n[lhs].a, b: x.n[rhs].b, l: lhs, r: rhs, op: nx))
    nx = nx2
  next = nx
  lhs

# the layout (nph's renderer: lineLen, indent, a pending line break)

func `+`(a: XLen, b: int): XLen = (if a.nl: a else: (a.len + b, false))
func `+`(a: int, b: XLen): XLen = (a + b.len, b.nl)
func `+`(a, b: XLen): XLen = (if a.nl: a else: (a.len + b.len, b.nl))

func xFirstW(t: FTok): int =
  ## a token's width on its line (up to its first line break)
  if not t.multi: return t.text.len
  let p = t.text.find('\n')
  if p < 0: t.text.len else: p

func xLen(x: XTree, a, b: int): XLen =
  ## the one-line length of toks[a ..< b] — up to a long string's first line break when it holds one
  let m = x.firstMulti[a]
  if m < b: (x.pos[m] + xFirstW(x.toks[m]) - x.pos[a], true)
  else: (x.pos[b - 1] + x.toks[b - 1].text.len - x.pos[a], false)

func xNodeLen(x: XTree, nd: int): XLen = x.xLen(x.n[nd].a, x.n[nd].b)
func xSpAt(x: XTree, k: int): int = (if x.pendingNL >= 0 or k == 0: 0 else: ord(x.sp[k]))
proc xOver(x: XTree, l: XLen): bool = l.nl or x.lineLen + l.len > FmtMax
proc xFits(l: XLen): bool = not l.nl and l.len <= FmtMax
func xFlagIndent(f: set[XFlag]): int = (if xfNoIndent in f: 0 elif xfLongIndent in f: 4 else: 2)

func xPut(x: var XTree, k: int) =
  let t = x.toks[k]
  if x.pendingNL >= 0:
    x.brk[k] = x.pendingNL
    x.lineLen = x.pendingNL + t.text.len
    x.pendingNL = -1
  else: x.lineLen += ord(x.sp[k] and k > 0) + t.text.len
  # (after a long string over several lines nph's line length counts all of it: nothing fits after it)

func xOptNL(x: var XTree) =
  x.pendingNL = x.indent
  x.lineLen = x.indent

func xOptIndent(x: var XTree, w: int) =
  x.indent += w
  if x.pendingNL >= 0:
    x.pendingNL = x.indent
    x.lineLen = x.indent

func xIndentNL(x: var XTree, w: int) =
  x.indent += w
  x.pendingNL = x.indent
  x.lineLen = x.indent

func xDedent(x: var XTree, w: int) =
  x.indent -= w
  if x.pendingNL > x.indent:
    x.pendingNL = x.indent
    x.lineLen = x.indent

func xSimple(x: XTree, nd: int): bool =
  ## nph's simple list element (a name, a literal, a.b, -1): lists of them are packed
  let node = x.n[nd]
  case node.kind
  of xAtom: x.toks[node.a].kind != fkKw or x.toks[node.a].text == "nil"
  of xDot: x.xSimple(node.l) and x.xSimple(node.r)
  of xProcTy: true
  of xParam: node.r < 0 and node.v < 0
  of xPrefix:
    x.toks[node.op].text == "-" and x.n[node.r].kind == xAtom and x.toks[x.n[node.r].a].kind == fkNum and
      not (x.toks[x.n[node.r].a].sp or x.toks[x.n[node.r].a].nl)
  else: false

func xNlLenImpl(x: XTree, nd: int): (bool, XLen) =
  let node = x.n[nd]
  case node.kind
  of xDot:
    let (e, l) = x.xNlLenImpl(node.l)
    if e: (e, l) else: (false, l + x.xNodeLen(node.r) + 1)
  of xList: (true, (if node.lk == 4: (2, false) else: (1, false)))
  of xAtom:
    let l = x.xNodeLen(nd)
    if x.toks[node.a].kind == fkStr and x.toks[node.a].text.startsWith("\"\"\""): (true, (l.len, false))
    else: (false, l)
  else: (false, x.xNodeLen(nd))

func xNlLen(x: XTree, nd: int): XLen =
  ## the length up to where nph would rather break (a bracket's opening, a long string's first line)
  x.xNlLenImpl(nd)[1]

func xStacked(x: XTree, nd: int, inCall: bool): bool =
  ## two calls or more in a dotted chain (`a.b(x).c(y)`): nph may put each `.c(…)` on a line of its own
  let node = x.n[nd]
  case node.kind
  of xCall:
    if node.obj: false
    elif inCall: true
    else: x.xStacked(node.l, true)
  of xDot: x.xStacked(node.l, inCall)
  else: false

func xDotCall(x: XTree, nd: int): bool =
  let node = x.n[nd]
  case node.kind
  of xDot: x.xDotCall(node.l)
  of xCall: not node.obj
  else: false

proc xSub(x: var XTree, nd: int, flags: set[XFlag])

proc xComma(x: var XTree, elems: seq[int], indentNL: int, sticky = false, alone = false, sepAtEnd = false,
            longSep = false, firstComplex = false, subFlags: set[XFlag] = {}) =
  ## nph's gcomma: on one line when they fit, else one a line when any is not simple, else packed
  if elems.len == 0: return
  var start = 0
  var indented = false
  if sticky:
    x.xSub(elems[0], subFlags)
    if elems.len == 1: return
    x.xPut(x.n[elems[0]].b)
    if alone and x.xOver(x.xSpAt(x.n[elems[1]].a) + x.xLen(x.n[elems[1]].a, x.n[elems[^1]].b)):
      indented = true
      x.xIndentNL(indentNL)
    start = 1
  if not indented: x.indent += indentNL
  var onePer = false
  if elems.len - start > 1 and
     x.xOver(x.xSpAt(x.n[elems[start]].a) + x.xLen(x.n[elems[start]].a, x.n[elems[^1]].b)):
    for i in (if firstComplex: 1 else: 0) ..< elems.len:
      if not x.xSimple(elems[i]):
        onePer = true
        break
  var newline = false
  for i in start ..< elems.len:
    let c = i < elems.high
    let ea = x.n[elems[i]].a
    let eb = x.n[elems[i]].b
    if onePer or x.xOver(x.xSpAt(ea) + x.xLen(ea, eb) + ord(c)):
      x.xOptNL()
      newline = true
    x.xSub(elems[i], subFlags)
    if c or sepAtEnd: x.xPut(eb)
    elif newline and longSep and elems.len - start > 1:
      # (nph: `;` after a last parameter without a type or default — `a, b,` ⏎ `)` would wait for another name)
      let nd = x.n[elems[i]]
      x.comma[eb - 1] = if nd.kind == xParam and nd.r < 0 and nd.v < 0: ';' else: ','
      x.lineLen += 1
  x.xDedent(indentNL)

proc xGlist(x: var XTree, lst: int, indentNL = 2, sepAtEnd = false, longSep = false, firstComplex = false,
            subFlags: set[XFlag] = {}, extra = 0) =
  ## nph's glist: `(` and its elements on the line when they fit, else `(` ⏎ the elements ⏎ `)`
  let open = x.n[lst].op
  let close = x.n[lst].close
  let withNL = x.n[lst].elems.len > 0 and x.xOver(x.xSpAt(open) + x.xNodeLen(lst) + extra)
  x.xPut(open)
  x.xOptIndent(indentNL)
  if withNL: x.xOptNL()
  x.xComma(x.n[lst].elems, 0, sepAtEnd = sepAtEnd, longSep = longSep, firstComplex = firstComplex,
           subFlags = subFlags)
  x.xDedent(indentNL)
  if withNL: x.xOptNL()
  x.xPut(close)

proc xSubOptNL(x: var XTree, nd: int, flags: set[XFlag] = {}, indentNL = 2) =
  ## nph's gsubOptNL (the value after `=`, `:`, `return`): on the next line when it fits there and not here,
  ## or when it is not a call or bracket and its first part does not fit here
  let node = x.n[nd]
  let s = x.xSpAt(node.a)
  let sublen = x.xNodeLen(nd)
  # (`tuple[…]` is not a bracket expression to nph: it may go to the next line)
  let tupleTy = node.kind == xIndex and x.n[node.l].kind == xAtom and x.toks[x.n[node.l].a].kind == fkKw
  let avoid = (node.kind in {xCall, xIndex, xCurlyX, xCommand, xEq, xColon, xCast, xPrefix, xParam, xProcTy} and
               not tupleTy) or (node.kind == xList and node.lk notin {0, 6}) or x.xDotCall(nd)
  let nl = (not avoid and x.xOver(s + x.xNlLen(nd))) or
           (x.xOver(s + sublen) and xFits(sublen + (x.indent + indentNL)))
  let ind = if x.xStacked(nd, false) or nl or x.pendingNL >= 0: indentNL else: 0
  x.xOptIndent(ind)
  if nl: x.xOptNL()
  x.xSub(nd, if ind > 0: flags + {xfNoIndent} else: flags)
  x.xDedent(ind)

proc xSub(x: var XTree, nd: int, flags: set[XFlag]) =
  ## nph's gsub
  let kind = x.n[nd].kind
  case kind
  of xAtom:
    for k in x.n[nd].a ..< x.n[nd].b: x.xPut(k)
  of xCall, xIndex, xCurlyX:
    let callee = x.n[nd].l
    let lst = x.n[nd].r
    if kind == xCall:
      var stackDot = false
      if x.n[callee].kind == xDot:
        let dl = x.n[callee].l
        let dr = x.n[callee].r
        stackDot = xfStackDot in flags or
                   (x.xOver(x.xNodeLen(dl) + x.xNodeLen(dr) + 1) and x.xStacked(dl, true))
      x.xSub(callee, flags * {xfStackDot, xfNoIndent, xfLongIndent} + {xfStackDotInCall})
      let ind = if stackDot: xFlagIndent(flags) else: 0
      x.xOptIndent(ind)
      x.xGlist(lst, longSep = true)
      x.xDedent(ind)
    elif kind == xIndex:
      x.xSub(callee, {})
      x.xGlist(lst, indentNL = xFlagIndent(flags - {xfNoIndent}), longSep = true)
    else:
      x.xSub(callee, {})
      x.xGlist(lst, indentNL = xFlagIndent(flags), longSep = true)
  of xList:
    let elems = x.n[nd].elems.len
    case x.n[nd].lk
    of 0: x.xGlist(nd, subFlags = {xfNoIndent})
    of 1:
      let one = elems == 1 and x.n[x.n[nd].elems[0]].kind != xColon
      x.xGlist(nd, sepAtEnd = one, longSep = not one)
    of 2: x.xGlist(nd, longSep = true, firstComplex = true)
    of 4: x.xGlist(nd, indentNL = xFlagIndent(flags))
    of 5: x.xGlist(nd, indentNL = xFlagIndent(flags), longSep = true)
    of 6:
      for k in x.n[nd].a ..< x.n[nd].b: x.xPut(k)
    else: x.xGlist(nd, longSep = true)
  of xPrefix:
    x.xPut(x.n[nd].op)
    x.xSub(x.n[nd].r, {})
  of xInfix:
    let f = flags * {xfNoIndent, xfLongIndent}
    let rhs = x.n[nd].r
    x.xSub(x.n[nd].l, f)
    x.xPut(x.n[nd].op)
    # (the space after the operator does not count: nph decides before it puts it)
    let sublen = x.xNodeLen(rhs)
    let over = x.xOver(x.xNlLen(rhs))
    let wid = xFlagIndent(f)
    let fitsNL = x.xOver(sublen) and xFits(sublen + (x.indent + wid))
    let hasIndent = x.n[rhs].kind == xList and x.n[rhs].lk != 1
    let ind = xfNoIndent notin f and (fitsNL or (over and not hasIndent))
    if ind: x.xIndentNL(wid)
    elif over or fitsNL: x.xOptNL()
    x.xSub(rhs, if ind: f + {xfNoIndent} else: f)
    if ind: x.xDedent(wid)
  of xDot:
    let dl = x.n[nd].l
    let dr = x.n[nd].r
    let stackDot = xfStackDot in flags or
                   (x.xOver(x.xNodeLen(dl) + x.xNodeLen(dr) + 1) and x.xStacked(dl, xfStackDotInCall in flags))
    var sub = flags * {xfNoIndent, xfLongIndent}
    if stackDot: sub.incl xfStackDot
    let wid = xFlagIndent(flags)
    x.xSub(dl, sub)
    if stackDot and xfStackDotInCall in flags: x.xOptNL()
    x.xOptIndent(wid)
    x.xPut(x.n[nd].op)
    x.xSub(dr, {xfNoIndent})
    x.xDedent(wid)
  of xColon, xEq:
    x.xSub(x.n[nd].l, {})
    x.xPut(x.n[nd].op)
    x.xSubOptNL(x.n[nd].r)
  of xCommand:
    x.xSub(x.n[nd].l, {})
    let args = x.n[nd].elems
    x.xComma(args, 2, sticky = true, alone = true)
  of xParam:
    x.xSub(x.n[nd].l, {})
    if x.n[nd].op >= 0:
      x.xPut(x.n[nd].op)
      x.xSubOptNL(x.n[nd].r)
    if x.n[nd].close >= 0:
      x.xPut(x.n[nd].close)
      x.xSubOptNL(x.n[nd].v)
  of xProcTy:
    let ret = x.n[nd].r
    x.xPut(x.n[nd].a)
    x.xGlist(x.n[nd].l, longSep = true, extra = (if ret >= 0: x.xNodeLen(ret).len + 2 else: 0))
    if ret >= 0:
      x.xPut(x.n[nd].op)
      x.xSub(ret, {})
    if x.n[nd].v >= 0: x.xGlist(x.n[nd].v)
  of xCast:
    let tp = x.n[nd].l
    x.xPut(x.n[nd].a)
    x.xPut(x.n[nd].a + 1)
    x.xSub(tp, {})
    x.xPut(x.n[tp].b)
    x.xPut(x.n[tp].b + 1)
    x.xSub(x.n[nd].r, {})
    x.xPut(x.n[nd].b - 1)

proc fNphLayout*(toks0: seq[FTok], depth: int, exprLine = false, declLike = false): seq[string] =
  ## a long statement laid out as nph lays it out — @[] when it is not one this knows (then the other rules
  ## decide). A long string's lines come as they are, each a line of the result.
  let toks = fDropTrailing(toks0)          # (they come back where nph puts them)
  let n = toks.len
  if n < 2: return
  for t in toks:
    if t.kind in {fkComment, fkSemi}: return
  var x = XTree(toks: toks, pos: newSeq[int](n), sp: newSeq[bool](n), brk: newSeq[int](n), comma: newSeq[char](n),
                firstMulti: newSeq[int](n), indent: depth * 2, lineLen: depth * 2, pendingNL: -1)
  var col = 0
  for k in 0 ..< n:
    if k > 0 and fSpaceBefore(toks, k, false):
      x.sp[k] = true
      inc col
    x.pos[k] = col
    col += xFirstW(toks[k])
    x.brk[k] = -1
  var fm = n
  for k in countdown(n - 1, 0):
    if toks[k].multi: fm = k
    x.firstMulti[k] = fm
  var nx = 0
  template whole(i, e: int): int =
    let r = x.xExpr(i, e, -1, nx)
    if x.fail or nx != e: return
    r
  proc identDefs(x: var XTree, a: int, typeVal = false): bool =
    ## `a, b*: T = v` (a let/var/const member, a field): the names, then type and value as nph puts them
    var k = a
    while k < n:
      if x.toks[k].kind != fkIdent: return false
      inc k
      if k < n and x.toks[k].kind == fkOp and x.toks[k].text == "*" and not x.toks[k].sp: inc k
      if k < n and x.toks[k].kind == fkComma:
        inc k
        continue
      break
    if k == a or k >= n: return false
    let namesEnd = k
    var names: seq[int]
    var q = a
    while q < namesEnd:
      var b = q + 1
      if b < namesEnd and x.toks[b].kind == fkOp: inc b
      names.add x.xNew(XNode(kind: xAtom, a: q, b: b))
      q = b + 1                                  # (past its comma)
    var tp, val, colonAt, eqAt = -1
    var nx2 = k
    if x.toks[k].kind == fkColon:
      colonAt = k
      inc x.typeCtx
      tp = x.xExpr(k + 1, n, -1, nx2)
      dec x.typeCtx
      if x.fail: return false
      k = nx2
    if k < n:
      if x.toks[k].kind != fkOp or x.toks[k].text != "=": return false
      eqAt = k
      if typeVal: inc x.typeCtx
      val = x.xExpr(k + 1, n, -1, nx2)
      if typeVal: dec x.typeCtx
      if x.fail or nx2 != n: return false
    elif colonAt < 0: return false
    x.xComma(names, 2, sticky = true)
    if tp >= 0:
      x.xPut(colonAt)
      x.xSubOptNL(tp)
    if val >= 0:
      x.xPut(eqAt)
      x.xSubOptNL(val)
    true
  proc routine(x: var XTree, a: int, named: bool): bool =
    ## a routine's header from toks[a] (`proc`) to the end — its name (`named`), generic parameters,
    ## parameters, return type, pragmas, ` =` — as nph's gproc; also a lambda's (`x = proc(…) =`)
    var k = a + 1
    if named:
      if k >= n or toks[k].kind != fkIdent: return false
      inc k
      if k < n and toks[k].kind == fkOp and toks[k].text == "*" and not toks[k].sp: inc k
    let nameEnd = k
    var gen = -1
    if named and k < n and toks[k].kind == fkOpen and toks[k].text == "[":
      gen = x.xParamList(k, n, k)
      if x.fail: return false
    if k >= n or toks[k].kind != fkOpen or toks[k].text != "(": return false
    let params = x.xParamList(k, n, k)
    if x.fail: return false
    var colonAt, ret, prag = -1
    if k < n and toks[k].kind == fkColon:
      colonAt = k
      inc x.typeCtx
      ret = x.xExpr(k + 1, n, -1, k)
      dec x.typeCtx
      if x.fail: return false
    if k < n and toks[k].kind == fkPragOpen:
      prag = x.xList(k, n, k)
      if x.fail: return false
    let body = k < n and toks[k].kind == fkOp and toks[k].text == "="
    if k + ord(body) != n or (not named and not body): return false
    let f = if body: {xfLongIndent} else: {}
    for q in a ..< nameEnd: x.xPut(q)
    if gen >= 0: x.xGlist(gen, indentNL = xFlagIndent(f), longSep = true)
    var extra = (if body: 2 else: 0)
    if prag >= 0: extra += 1 + x.xNodeLen(prag).len
    if ret >= 0: extra += x.xNodeLen(ret).len + 2
    x.xGlist(params, indentNL = xFlagIndent(f), longSep = true, extra = extra)
    if ret >= 0:
      x.xPut(colonAt)
      x.xSub(ret, f)
    if prag >= 0: x.xGlist(prag, indentNL = xFlagIndent(f))
    if body: x.xPut(n - 1)
    true
  let t0 = toks[0]
  if exprLine:
    # a value on its own line under `x =`: as nph puts it there
    let v = whole(0, n)
    x.xSub(v, {xfNoIndent})
  elif t0.kind == fkKw and t0.text != "cast":
    case t0.text
    of "return", "discard", "raise", "yield":
      let v = whole(1, n)
      x.xPut(0)
      x.xSubOptNL(v)
    of "if", "elif", "while", "when":
      if toks[^1].kind != fkColon: return
      let c = whole(1, n - 1)
      x.xPut(0)
      x.xSub(c, {xfLongIndent})
      x.xPut(n - 1)
    of "case":
      let c = whole(1, n)
      x.xPut(0)
      x.xSub(c, {})
    of "for":
      if toks[^1].kind != fkColon: return
      var inAt = -1
      for k in 1 ..< n:
        if toks[k].kind in {fkOpen, fkClose, fkPragOpen, fkPragClose}: break
        if toks[k].kind == fkKw and toks[k].text == "in":
          inAt = k
          break
      if inAt < 2: return
      let it = whole(inAt + 1, n - 1)
      for k in 0 .. inAt: x.xPut(k)
      x.xSub(it, {xfLongIndent})
      x.xPut(n - 1)
    of "let", "var", "const":
      x.xPut(0)
      if not x.identDefs(1): return
    of "type":
      # `type X = T` (a section of one): as its member `X = T`
      x.xPut(0)
      if toks[1].kind != fkIdent or toks[2].kind == fkComma or not x.identDefs(1, typeVal = true): return
    of "bind", "mixin":
      # names packed, 2 deeper (nph's gcomma)
      var names: seq[int]
      var k = 1
      while k < n:
        if toks[k].kind != fkIdent or (k + 1 < n and toks[k + 1].kind != fkComma): return
        names.add x.xNew(XNode(kind: xAtom, a: k, b: k + 1))
        k += 2
      x.xPut(0)
      x.xComma(names, 2)
    of "proc", "func", "method", "iterator", "converter", "template", "macro":
      if not x.routine(0, true): return
    else: return
  elif t0.kind == fkPragOpen:
    # a pragma statement: `{.` ⏎ its pragmas ⏎ `.}` when they do not fit
    let p = x.xList(0, n, nx)
    if x.fail or nx != n: return
    x.xSub(p, {})
  elif t0.kind == fkIdent and declLike and (block:
         # a type's name with its pragmas: `Name*[T] {.pragmas.} = object`
         var k = 1
         if k < n and toks[k].kind == fkOp and toks[k].text == "*" and not toks[k].sp: inc k
         if k < n and toks[k].kind == fkOpen and toks[k].text == "[":
           discard x.xParamList(k, n, k)
         not x.fail and k < n and toks[k].kind == fkPragOpen):
    var k = 1
    if toks[k].kind == fkOp: inc k
    var gen = -1
    if toks[k].kind == fkOpen: gen = x.xParamList(k, n, k)
    let prag = x.xList(k, n, k)
    if x.fail or k + 1 >= n or toks[k].kind != fkOp or toks[k].text != "=" or toks[k + 1].kind != fkKw or
       toks[k + 1].text notin ["object", "ref", "ptr", "enum", "tuple", "distinct", "concept"]:
      return
    for q in 0 ..< (if gen >= 0: x.n[gen].a else: x.n[prag].a): x.xPut(q)
    if gen >= 0: x.xGlist(gen, longSep = true)
    x.xGlist(prag)
    for q in k ..< n: x.xPut(q)
  elif t0.kind == fkIdent and (toks[1].kind in {fkComma, fkColon} or
                               (toks[1].kind == fkOp and toks[1].text == "*" and not toks[1].sp)):
    # (a section's member or a field — not `runnableExamples: body`, a call given a block)
    if not declLike or not x.identDefs(0): return
  elif t0.kind in {fkIdent, fkOpen} or (t0.kind == fkKw and t0.text == "cast"):
    let head = x.xExpr(0, n, -1, nx, cmd = false)
    if x.fail: return
    if nx == n: x.xSub(head, {})
    elif toks[nx].kind == fkOp and toks[nx].text == "=" and nx + 2 < n and toks[nx + 1].kind == fkKw and
         toks[nx + 1].text in ["proc", "func", "iterator"] and toks[^1].kind == fkOp and toks[^1].text == "=":
      # `x = proc(…) =` ⏎ its body: the lambda's header as a routine's
      x.xSub(head, {})
      x.xPut(nx)
      if not x.routine(nx + 1, false): return
    elif toks[nx].kind == fkOp and toks[nx].text == "=":
      let eqAt = nx
      let v = whole(eqAt + 1, n)
      x.xSub(head, {})
      x.xPut(eqAt)
      x.xSubOptNL(v)
    elif x.xCmdStart(nx):
      # `cmd a, b = c`: a command and its arguments
      var args: seq[int]
      var k = nx
      while true:
        var nx2 = k
        var a = x.xExpr(k, n, -1, nx2)
        if x.fail: return
        if args.len > 0 and nx2 < n and toks[nx2].kind == fkOp and toks[nx2].text == "=":
          let eqAt = nx2
          let r = x.xExpr(eqAt + 1, n, -1, nx2)
          if x.fail: return
          a = x.xNew(XNode(kind: xEq, a: k, b: x.n[r].b, l: a, r: r, op: eqAt))
        args.add a
        if nx2 == n: break
        if toks[nx2].kind != fkComma: return
        k = nx2 + 1
        if k >= n: return
      x.xSub(head, {})
      x.xComma(args, 2, sticky = true, alone = true)
    else: return
  else: return
  var cur = spaces(depth * 2)
  for k in 0 ..< n:
    if x.brk[k] >= 0:
      result.add cur
      cur = spaces(x.brk[k])
    elif k > 0 and x.sp[k]: cur.add ' '
    cur.add toks[k].text
    if x.comma[k] != '\0': cur.add x.comma[k]
  result.add cur
  if x.firstMulti[0] < n:
    var flat: seq[string]
    for r in result:
      for l in r.split('\n'): flat.add l
    swap(result, flat)        # (not `result = flat`: Nim 2.2 took that for result's first value — what it held leaked)

proc fCommentValue(o: FOut): seq[string] =
  ## `x = a and # note` ⏎ `b` — a value with comments among its operands (outside brackets) as nph lays it out:
  ## `x =` on its line, the value under it, a line break after each comment (an own-line comment stays on its
  ## line) — or a value on a line of its own already (no `x =`), the same at its depth; @[] when not one such
  let toks = o.toks
  let ind = o.depth * 2
  var eq = -1
  var d = 0
  for k, t in toks:
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif t.kind == fkComment:
      if eq < 0 and not o.exprLine: return
    elif d == 0 and eq < 0 and t.kind == fkOp and t.text == "=" and not o.exprLine: eq = k
    elif t.kind == fkKw and t.text in FRoutineKw: return
    if t.multi: return
  if eq < 0 and not o.exprLine: return
  var outp: seq[string]
  if eq >= 0: outp.add spaces(ind) & fRender(toks.toOpenArray(0, eq))
  proc binOp(t: FTok): bool = (t.kind == fkOp and t.text != "=") or fWordOp(t)
  proc chain(a, b, vind: int, outp: var seq[string]): bool =
    ## toks[a ..< b] at `vind`: a line break after each comment — comments only after operators, and inside
    ## brackets only in a last `(…)` operand, which is laid out `(` ⏎ its operands 2 deeper ⏎ `)` (like nph)
    var piece: seq[FTok]
    template flush(comment: string): bool =
      var ok = true
      if piece.len > 0:
        let line = spaces(vind) & fRender(piece)
        # (a piece too long: laid out as a value on its line would be)
        var ls = if fFitLen(line) <= FmtMax: @[line]
                 else: fRenderLine(FOut(depth: vind div 2, toks: piece, exprLine: true), @[])
        if ls.len == 0: ok = false
        else:
          if comment.len > 0:
            # (a trailing comment that does not fit after the code: under it, 2 deeper — like nph)
            if ls[^1].len + 1 + comment.len <= FmtMax: ls[^1].add " " & comment
            else: ls.add spaces(vind + 2) & comment
          outp.add ls
        piece.setLen(0)
      elif comment.len > 0: ok = false
      ok
    var k = a
    while k < b:
      let t {.cursor.} = toks[k]
      if t.kind == fkComment:
        let prev = if piece.len > 0: piece[^1] else: (if k > a: toks[k - 1] else: nil)
        if t.text.startsWith("#[") or t.text.startsWith("##[") or prev == nil or
           not (binOp(prev) or prev.kind == fkComment):
          return false
        if t.nl:
          if not flush(""): return false
          # (deeper than the code after it: the comment of the code before — 2 deeper, like nph)
          var nx = k + 1
          while nx < b and toks[nx].kind == fkComment: inc nx
          let post = nx < b and toks[nx].nl and t.col > toks[nx].col
          outp.add spaces(vind + (if post: 2 else: 0)) & t.text
        elif not flush(t.text): return false
        inc k
        continue
      if t.kind in {fkOpen, fkPragOpen}:
        var dd = 0
        var close = -1
        var inner = false
        for j in k ..< b:
          if toks[j].kind in {fkOpen, fkPragOpen}: inc dd
          elif toks[j].kind in {fkClose, fkPragClose}:
            dec dd
            if dd == 0:
              close = j
              break
          elif toks[j].kind == fkComment: inner = true
        if close < 0: return false
        if inner:
          # a last operand `(…)` holding comments: `(` ⏎ its operands ⏎ `)`
          if t.text != "(" or close != b - 1 or (piece.len > 0 and not binOp(piece[^1])) or
             (piece.len == 0 and k > a and not (binOp(toks[k - 1]) or toks[k - 1].kind == fkComment)):
            return false
          if not flush(""): return false
          outp.add spaces(vind) & "("
          if not chain(k + 1, close, vind + 2, outp): return false
          outp.add spaces(vind) & ")"
          return true
        for j in k .. close: piece.add toks[j]
        k = close + 1
        continue
      piece.add t
      inc k
    flush("")
  if not chain(eq + 1, toks.len, (if eq >= 0: ind + 2 else: ind), outp): return
  outp

proc fParenStmts(o: FOut): seq[string] =
  ## a long statement ending in statements in parentheses (`if x and (let a = f(); a > 0):`): `… (` ⏎ a
  ## statement a line, 2 deeper ⏎ `)` (like nph — the `;` become line breaks); @[] when not one such
  let toks = o.toks
  var e = toks.high
  if e > 0 and toks[e].kind == fkColon: dec e          # (a condition's `:`)
  if e < 3 or toks[e].kind != fkClose or toks[e].text != ")": return
  var d = 0
  var open = -1
  for k in countdown(e, 0):
    if toks[k].kind in {fkClose, fkPragClose}: inc d
    elif toks[k].kind in {fkOpen, fkPragOpen}:
      dec d
      if d == 0:
        open = k
        break
  if open < 0 or toks[open].text != "(" or fCallParen(toks, open): return
  for k in 0 ..< toks.len:
    if toks[k].kind == fkComment or toks[k].multi: return
  var stmts: seq[(int, int)]
  var a = open + 1
  d = 0
  for k in open + 1 .. e:
    let t {.cursor.} = toks[k]
    if k == e or (d == 0 and t.kind == fkSemi):
      if k == a: return
      stmts.add (a, k)
      a = k + 1
      continue
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkComma: return          # (a tuple)
  # (a `let`/`var`/`const` first: what makes Nim read the lines as statements — `(n = f()` ⏎ `n != nil)` it
  # does not)
  if stmts.len < 2 or toks[open + 1].kind != fkKw or toks[open + 1].text notin ["let", "var", "const"]: return
  let ind = o.depth * 2
  # (after an operator: when it fits on a line of its own, the line breaks after the operator instead, like nph)
  if open > 0 and (toks[open - 1].kind == fkOp or fWordOp(toks[open - 1])):
    let cond = toks[0].kind == fkKw and toks[0].text in ["if", "elif", "while", "when"]
    if fFitLen(spaces(ind + (if cond: 4 else: 2)) & fRender(toks.toOpenArray(open, toks.high))) <= FmtMax: return
  var outp = @[spaces(ind) & fRender(toks.toOpenArray(0, open))]
  if outp[0].len > FmtMax: return
  for (sa, sb) in stmts:
    outp.add fRenderLine(FOut(depth: o.depth + 1, toks: toks[sa ..< sb]), @[])
  outp.add spaces(ind) & fRender(toks.toOpenArray(e, toks.high))
  outp

proc fCommentCond(o: FOut): seq[string] =
  ## `if a and # note` ⏎ `b:` — a condition with comments among its operands as nph lays it out: an operand
  ## after a trailing comment at the `if`'s column, one after own-line comments 4 deeper (at the column when it is
  ## in parentheses), one that does not fit 4 deeper; a comment that does not fit after its code under it, 2
  ## deeper; @[] when not one such
  let toks = o.toks
  let ind = o.depth * 2
  let t0 = toks[0]
  if t0.kind != fkKw or t0.text notin ["if", "elif", "while", "when"]: return
  let c = fTopColon(toks, 0, toks.len)
  if c < 2: return
  var tail = ""                       # (a comment after the `:`)
  if c < toks.high:
    if c + 1 != toks.high or toks[c + 1].kind != fkComment or toks[c + 1].nl: return
    tail = toks[c + 1].text
  for k in 0 ..< c:
    if toks[k].multi or (toks[k].kind == fkComment and (toks[k].text.startsWith("#[") or
                                                        toks[k].text.startsWith("##["))):
      return
  # the operands: split at the loosest operators at the top
  proc binaryAt(k: int): bool =
    var p = k - 1
    while p > 0 and toks[p].kind == fkComment: dec p
    p > 0 and fOperand(toks[p]) and (toks[k].kind == fkOp or fWordOp(toks[k]))
  var cls = -1
  for ci, ops in FOpClasses:
    var d = 0
    for k in 1 ..< c:
      let t {.cursor.} = toks[k]
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
      elif d == 0 and t.text in ops and binaryAt(k): cls = ci
    if cls >= 0: break
  if cls < 0: return
  var segs: seq[seq[FTok]]
  var ops: seq[FTok]
  var trails, pres: seq[seq[string]]
  segs.add @[]
  trails.add @[]
  pres.add @[]
  var d = 0
  for k in 1 ..< c:
    let t = toks[k]
    if t.kind == fkComment:
      if d > 0: return
      # (only right after an operator: trailing it, or on lines of their own before the next operand — those
      # deeper than that operand belong to the operator's line: under it, like nph)
      if segs[^1].len > 0 or ops.len < segs.len - 1 or segs.len < 2: return
      var nx = k + 1
      while nx < c and toks[nx].kind == fkComment: inc nx
      let post = not t.nl or (nx < c and toks[nx].nl and t.col > toks[nx].col)
      if not post: pres[^1].add t.text
      elif pres[^1].len > 0 or (not t.nl and trails[^2].len > 0): return
      else: trails[^2].add t.text
      continue
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.text in FOpClasses[cls] and binaryAt(k):
      if segs[^1].len == 0: return
      ops.add t
      segs.add @[]
      trails.add @[]
      pres.add @[]
      continue
    segs[^1].add t
  if segs[^1].len == 0 or segs.len < 2: return
  proc parened(s: seq[FTok]): bool =
    if s.len < 2 or s[0].text != "(" or s[^1].text != ")": return false
    var dd = 0
    for k, t in s:
      if t.kind in {fkOpen, fkPragOpen}: inc dd
      elif t.kind in {fkClose, fkPragClose}:
        dec dd
        if dd == 0 and k < s.high: return false
    true
  var outp: seq[string]
  var line = spaces(ind) & t0.text & " " & fRender(segs[0])
  var pending = false
  for i in 0 ..< segs.len:
    if i > 0:
      let s = fRender(segs[i]) & (if i == segs.high: ":" else: "")
      if pres[i].len > 0:
        if line.len > 0: outp.add line
        let at = ind + (if parened(segs[i]): 0 else: 4)
        for pc in pres[i]: outp.add spaces(at) & pc
        line = spaces(at) & s
      elif pending:
        line = spaces(ind) & s
        if fFitLen(line) > FmtMax: line = spaces(ind + 4) & s
      elif fFitLen(line & " " & s) <= FmtMax: line.add " " & s
      else:
        outp.add line
        line = spaces(ind + 4) & s
      pending = false
    if fFitLen(line) > FmtMax: return @[]          # (an operand too long by itself: as written)
    if i < segs.high:
      line.add " " & ops[i].text
      if trails[i].len > 0:
        if trails[i].len == 1 and line.len + 1 + trails[i][0].len <= FmtMax: outp.add line & " " & trails[i][0]
        else:
          outp.add line
          for tc in trails[i]: outp.add spaces(ind + 2) & tc
        line = ""
        pending = true
  if tail.len > 0:
    if line.len + 1 + tail.len <= FmtMax: line.add " " & tail
    else:
      outp.add line
      line = spaces(ind + 2) & tail
  outp.add line
  outp

proc fRenderLine*(o0: FOut, lines: seq[string]): seq[string] =
  ## the output lines of one statement: on one line when it fits, wrapped like nph when not
  var hasSemi, hasTrailing = false
  for k, t in o0.toks:
    if t.kind == fkSemi: hasSemi = true
    if t.kind in {fkComma, fkSemi} and k < o0.toks.high and o0.toks[k + 1].kind == fkClose: hasTrailing = true
  # (most statements: they fit on their line and hold nothing nph lays out otherwise — the line as it is, what the
  # rules below give for it, without their work)
  if not hasSemi and not hasTrailing and not o0.comment and not o0.lambdaCmd and FmtParams == fwFit and
     FmtArgs == fwFit and FmtColl == fwFit:
    var inner = false
    for k in 0 ..< o0.toks.high:
      if o0.toks[k].kind == fkComment:
        inner = true
        break
    if not inner:
      var one = spaces(o0.depth * 2)
      one.add fRender(o0.toks, importish = o0.importish)
      let oneFit = if one.len > 0 and one[^1] == ':': one.len - 1 else: one.len
      if oneFit <= FmtMax and fBlockElemGroup(o0.toks)[0] < 0: return @[one]
  var o: FOut
  if hasSemi:
    o = o0
    o.toks = fParamSemis(o.toks)
  else:
    o = FOut(depth: o0.depth, comment: o0.comment, importish: o0.importish, exprLine: o0.exprLine,
             complexKind: o0.complexKind, declLike: o0.declLike, lambdaCmd: o0.lambdaCmd)
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
  var opComment = false
  var cd = 0
  var lastCode = -1
  for k, t in o.toks:
    if t.kind in {fkOpen, fkPragOpen}: inc cd
    elif t.kind in {fkClose, fkPragClose}: dec cd
    elif t.kind == fkComment and k < o.toks.high:
      hasInnerComment = true
      if cd == 0 and lastCode >= 0 and not t.text.startsWith("#[") and not t.text.startsWith("##[") and
         ((o.toks[lastCode].kind == fkOp and o.toks[lastCode].text != "=") or fWordOp(o.toks[lastCode])):
        opComment = true
    if t.kind != fkComment: lastCode = k
  # a value with comments among its operands, after operators (`x = a and # note` ⏎ `b`): as nph lays it out —
  # or as written, broken after each comment
  if opComment:
    let r = if o.toks[0].kind == fkKw and o.toks[0].text in ["if", "elif", "while", "when"]: fCommentCond(o)
            else: fCommentValue(o)
    return (if r.len > 0: r elif lines.len > 0: lines else: fAsWritten(o0))
  if FmtParams != fwFit or FmtArgs != fwFit or FmtColl != fwFit:
    let r = fListLayout(o, one.len <= FmtMax and not hasInnerComment)
    if r.len > 0: return r
  if not hasInnerComment and FmtArgs != fwKeep:
    # a call with a lambda or an if-expression among its arguments: one argument a line, those as blocks (nph)
    let (bo, bc) = fBlockElemGroup(o.toks)
    if bo > 0:
      let r = fWrapGroup(o.toks[0 .. bo], o.toks[bo + 1 ..< bc], o.toks[bc .. ^1], ind, ind + 2, true)
      if r.len > 0: return r
    if o.lambdaCmd:
      # a command whose last argument is a lambda with a block: `cmd a,` ⏎ each other argument ⏎ `proc(…) =`
      var elems: seq[seq[FTok]]
      var cur: seq[FTok]
      var d = 0
      for t in o.toks:
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}: dec d
        cur.add t
        if d == 0 and t.kind == fkComma:
          elems.add cur
          cur = @[]
      if cur.len > 0: elems.add cur
      if elems.len >= 2:
        result = @[pad & fRender(elems[0])]
        for e in elems[1 .. ^1]: result.add pad & "  " & fRender(e)
        return
  # (a block's closing `:` does not count: nph lets it stand past the width)
  let oneFit = if one.len > 0 and one[^1] == ':': one.len - 1 else: one.len
  if oneFit <= FmtMax and not hasInnerComment:
    # a trailing comma before the closing bracket goes away on one line
    if not hasTrailing: return @[one]
    return @[pad & fRender(fDropTrailing(o.toks), importish = o.importish)]
  let t0 = o.toks[0]
  # ending in statements in parentheses, `(let a = f(); a > 0)`: one a line in them (like nph)
  if not hasInnerComment and not o.importish:
    let r = fParenStmts(o)
    if r.len > 0: return r
  # nph's own layout, for the statements it knows (with nph's list settings: "fit")
  if not hasInnerComment and not o.importish and FmtArgs == fwFit and FmtColl == fwFit and FmtParams == fwFit:
    let r = fNphLayout(o.toks, o.depth, o.exprLine, o.declLike)
    if r.len > 0: return r
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
  # a trailing comment that does not fit: on the next line, under the statement (like nph) — not a `##` doc
  # comment: on a line of its own under a statement it would be a statement of its own, and not always allowed there
  if o.toks.len > 1 and o.toks[^1].kind == fkComment and not hasInnerComment and
     not o.toks[^1].text.startsWith("#[") and (o.declLike or not o.toks[^1].text.startsWith("##")) and
     not (o.toks[^1].text.startsWith("##") and (o.toks[^2].kind in {fkComma, fkOp} or fWordOp(o.toks[^2]))):
    var o2 = o
    o2.toks = o.toks[0 ..< o.toks.high]
    let code = fRenderLine(o2, @[pad & fRender(o2.toks, importish = o.importish)])
    # (the code over several lines: the comment stays at the end of the last one when it fits there, like nph)
    if code.len > 1 and code[^1].len + 1 + o.toks[^1].text.len <= FmtMax:
      return code[0 ..< code.high] & @[code[^1] & " " & o.toks[^1].text]
    return code & @[pad & "  " & o.toks[^1].text]
  # a long `of a, b, c:`: the first value stays, the others follow 4 deeper — packed when all are plain names,
  # else one a line (like nph)
  if t0.kind == fkKw and t0.text == "of" and o.toks[^1].kind == fkColon and not hasInnerComment and o.toks.len > 3:
    var elems: seq[seq[FTok]]
    var cur: seq[FTok]
    var d = 0
    for k in 1 .. o.toks.high:
      let t = o.toks[k]
      if t.kind in {fkOpen, fkPragOpen}: inc d
      elif t.kind in {fkClose, fkPragClose}: dec d
      cur.add t
      if d == 0 and t.kind == fkComma:
        elems.add cur
        cur = @[]
    if cur.len > 0: elems.add cur
    if elems.len > 1:
      var simple = true
      for e in elems:
        if not fSimpleElem(e): simple = false
      var outp = @[pad & "of " & fRender(elems[0])]
      let cpad = spaces(ind + 4)
      for e in elems[1 .. ^1]:
        let r = fRender(e)
        # (a value's comma counts — nph's gcomma — the branch's closing `:` does not)
        let w = if r.endsWith(","): outp[^1].len + 1 + r.len else: fFitLen(outp[^1] & " " & r)
        if not simple or w > FmtMax: outp.add cpad & r
        else: outp[^1].add " " & r
      return outp
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
      # (too many for one line: packed, as many a line as fit — the comma counts)
      var outp = @[pad & fRender(o.toks[0 .. imp], importish = true)]
      var line = spaces(ind + 2)
      var cur: seq[FTok]
      var d = 0
      for k in imp + 1 .. o.toks.len:
        if k < o.toks.len:
          let t = o.toks[k]
          if t.kind in {fkOpen, fkPragOpen}: inc d
          elif t.kind in {fkClose, fkPragClose}: dec d
          cur.add t
          if not (d == 0 and t.kind == fkComma): continue
        if cur.len == 0: break
        let r = fRender(cur, importish = true)
        if line.len > ind + 2 and line.len + 1 + r.len > FmtMax:
          outp.add line
          line = spaces(ind + 2) & r
        else: line.add (if line.len > ind + 2: " " else: "") & r
        cur = @[]
      outp.add line
      return outp
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
    var simple = true
    for e in elems:
      if not fSimpleElem(e): simple = false
    if simple:
      # plain module names: packed, as many a line as fit (like nph)
      var line = spaces(ind + 2)
      for ei, e in elems:
        let r = fRender(e, importish = true) & (if ei < elems.high: "," else: "")
        if line.len > ind + 2 and line.len + 1 + r.len > FmtMax:        # (the comma counts: nph's gcomma)
          outp.add line
          line = spaces(ind + 2) & r
        else: line.add (if line.len > ind + 2: " " else: "") & r
      outp.add line
      return outp
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
    var eq = fTopEq(o.toks, 0, o.toks.len)
    if eq < 0:
      # `x += …`, `s &= …`: an assignment too
      var d = 0
      for k in 1 ..< o.toks.len:
        let t = o.toks[k]
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}: dec d
        elif d == 0 and t.kind == fkOp and t.text.len >= 2 and t.text[^1] == '=' and
             t.text notin ["==", "<=", ">=", "!=", "=="] and fOperand(o.toks[k - 1]):
          eq = k
          break
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
      # a long value that is not a call or a bracket (an operator expression, a literal): on its own lines under
      # the `=`, broken there (nph moves such a value down; a call stays and wraps its arguments)
      var d = 0
      var logic = false
      var sawOperand = false
      for k in eq + 1 ..< o.toks.len:
        let t = o.toks[k]
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}: dec d
        elif d == 0 and (t.kind == fkOp or fWordOp(t)) and t.text notin [".", "@"] and k > eq + 1 and
             fOperand(o.toks[k - 1]):
          logic = true
        if d == 0 and t.kind in {fkIdent, fkNum, fkStr, fkChar, fkClose}: sawOperand = true
      if not logic and eq + 2 == o.toks.len and o.toks[eq + 1].kind in {fkStr, fkIdent, fkNum}: logic = true
      # (not when the statement goes on in the next line: it ends with an operator or a comma)
      if o.toks[^1].kind in {fkOp, fkComma} or fWordOp(o.toks[^1]): logic = false
      if logic:
        let sub = fRenderLine(FOut(depth: o.depth + 1, toks: o.toks[eq + 1 .. ^1], exprLine: true), @[value])
        return @[pad & fRender(o.toks[0 .. eq])] & sub
  # `raise newException(…)`, `discard "…"`, `return f(…)` too long: the value on the next line when it fits there
  # (like nph)
  if not hasInnerComment and t0.kind == fkKw and t0.text in ["raise", "discard", "return", "yield"] and
     o.toks.len > 1 and o.toks[^1].kind != fkComment and
     not (o.toks[1].kind == fkKw and o.toks[1].text in ["if", "when", "try", "case", "proc", "func"]):
    let value = pad & "  " & fRender(fDropTrailing(o.toks[1 .. ^1]))
    if fFitLen(value) <= FmtMax: return @[pad & t0.text, value]
    # (an operator expression too long there too: still under the keyword, broken there)
    if t0.text != "raise":
      var d = 0
      var logic = false
      for k in 1 ..< o.toks.len:
        let t = o.toks[k]
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}: dec d
        elif d == 0 and (t.kind == fkOp or fWordOp(t)) and t.text notin [".", "@"] and k > 1 and
             fOperand(o.toks[k - 1]) and not fUnaryAt(o.toks, k):
          logic = true
      if logic:
        let sub = fRenderLine(FOut(depth: o.depth + 1, toks: o.toks[1 .. ^1], exprLine: true), @[value])
        if sub.len > 1: return @[pad & t0.text] & sub
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
          # (`): T {.pragmas.} =` still too long: its pragmas wrapped too)
          proc pragmaFix(r: seq[string]): seq[string] =
            result = r
            # (the ` =` after them does not count: nph lets it stand past the width)
            if r.len > 0 and r[^1].len - (if r[^1].endsWith(" ="): 2 else: 0) > FmtMax:
              let w = fPragmaWrap(o.toks[close .. ^1], ind, pind)
              if w.len > 0: result = r[0 ..< r.high] & w
          if FmtParams == fwFit:
            let res1 = fWrapGroup(o.toks[0 .. open], inner, o.toks[close .. ^1], ind, pind, false, params = true)
            if res1.len == 3 and res1[1].len <= FmtMax: return pragmaFix(res1)
          return pragmaFix(fWrapGroup(o.toks[0 .. open], inner, o.toks[close .. ^1], ind, pind, true, params = true))
      elif close == open + 1:
        # no parameters to wrap: the pragmas — when they do not fit even without the ` =` (like nph)
        let hasBody = o.toks[^1].kind == fkOp and o.toks[^1].text == "="
        if hasBody and one.len - 2 <= FmtMax and not hasInnerComment: return @[one]
        let w = fPragmaWrap(o.toks, ind, ind + (if hasBody: 4 else: 2))
        if w.len > 0: return w
    # what the rules above leave: keep — a header written on one line stays on it, its pragmas wrapped when too
    # long (`{.` ⏎ …); else nph's layout of it (long generic parameters: `proc f*[` ⏎ `T: …` ⏎ `]() =`). Never
    # the rules below: they would take the `*` of `proc f*` for a product and break the line after it. (A proc
    # type or lambda, `proc (x: int): T`, has no name to keep: those rules lay it out.)
    if not (o.toks.len > 1 and o.toks[1].kind == fkOpen):
      if not hasInnerComment:
        let hasBody = o.toks[^1].kind == fkOp and o.toks[^1].text == "="
        if one.len - (if hasBody: 2 else: 0) > FmtMax:
          if FmtParams == fwKeep:
            let w = fPragmaWrap(o.toks, ind, ind + (if hasBody: 4 else: 2))
            if w.len > 0: return w
          else:
            let r = fNphLayout(o.toks, o.depth, o.exprLine, o.declLike)
            if r.len > 0: return r
      return (if lines.len > 0: lines else: fAsWritten(o0))
  # a pragma statement too long: `{.` ⏎ its pragmas (one a line when they are not plain) ⏎ `.}` (like nph)
  if t0.kind == fkPragOpen and not hasInnerComment:
    let w = fPragmaWrap(o.toks, ind, ind + 2)
    if w.len > 0: return w
  # a long expression: break after its loosest operator (or, and, comparisons, &, + -) where the next
  # operand no longer fits — 4 deeper in a condition, 2 elsewhere, not at all for a value that already
  # stands on its own line — like nph
  if not hasInnerComment:
    let isCond = t0.kind == fkKw and t0.text in ["if", "elif", "while", "when"]
    let cind = ind + (if isCond: 4 elif o.exprLine: 0 else: 2)
    const classes = [@["or", "xor"], @["and"], @["==", "!=", "<", "<=", ">", ">=", "in", "notin", "is", "isnot"],
                     @["&"], @["+", "-"], @["*", "/", "%", "div", "mod", "shl", "shr"]]
    var segs: seq[seq[FTok]]
    for cls in classes:
      segs = fOpSegs(o.toks, cls, isCond)
      if segs.len > 1: break
    if segs.len > 1:
      let outp = fPackSegs(segs, pad, spaces(cind))
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
        for j in close + 1 ..< o.toks.len:
          if j < o.toks.high or o.toks[j].kind != fkComment: tail += o.toks[j].text.len + 1   # (a trailing comment aside)
        var inner = 0
        for j in k + 1 ..< close: inner += o.toks[j].text.len + 1
        # (a tiny group after a big one — `opGorge(…)[0]` — is not the one to open: the call is)
        if tail <= 30 and not (open > 0 and inner <= 12): open = k
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
  # a pragma that makes the line too long: `… {.` ⏎ its pragmas ⏎ `.}` (like nph) — not a name's own pragma
  # (`Lock* {.importc: "x", final.} = object`: nph leaves that line long)
  if not hasInnerComment and not (t0.kind == fkIdent and o.toks.len > 2 and
                                  (o.toks[1].kind == fkPragOpen or o.toks[2].kind == fkPragOpen)):
    let w = fPragmaWrap(o.toks, ind, ind + 2)
    if w.len > 0 and w.len >= 3: return w
  # cannot wrap: as written (inner comments need their line breaks)
  if lines.len > 0: lines else: fAsWritten(o0)

const FStmtWords = ["if", "when", "case", "try", "for", "while", "block", "proc", "func", "iterator", "do", "template",
                    "macro", "converter", "method", "elif", "else", "of", "except", "finally", "defer", "static", "let",
                    "var", "const", "type", "return", "yield", "discard", "raise", "break", "continue", "using",
                    "mixin", "bind", "import", "include", "export", "from", "asm"]

proc fSnippet(toks: openArray[FTok], a, b: int, text: string): string =
  ## toks[a ..< b] as written, its lines moved left by the first token's column — "" when a line starts left of it
  ## or a token spans lines
  let base = toks[a].col
  for k in a ..< b:
    let t {.cursor.} = toks[k]
    if t.multi: return ""
    if k > a:
      if t.nl:
        if t.col < base: return ""
        for _ in 0 .. t.blanks: result.add '\n'
        result.add spaces(t.col - base)
      else:
        let p {.cursor.} = toks[k - 1]
        let pend = if p.kind == fkIdent and p.text.len > 0 and p.text[0] == '`': text.find('`', p.pos + 1) + 1
                   else: p.pos + p.text.len
        if pend < 0 or pend > t.pos: return ""
        result.add text[pend ..< t.pos]
    result.add t.text
  result.add '\n'

proc fSameTokens*(a, b: seq[FTok]): bool

proc fFormatPart(snippet: string, width: int): seq[string] =
  ## a piece of a statement (a lambda's body, a block given as an argument) formatted on its own, `width`
  ## columns wide — @[] when the formatter would leave it alone
  if snippet.len == 0 or width < 30: return
  let keep = FmtMax
  FmtMax = width
  var err = ""
  var r = ""
  try: r = fFormat(snippet, err)
  finally: FmtMax = keep
  if err.len > 0: return
  # (its tokens as they were — not those it normalizes, `quote do:` → `quote:`: in a line kept as written they
  # were not normalized, and the check of the whole file would refuse it)
  var ok1, ok2 = true
  if not fSameTokens(fLex(snippet, ok1), fLex(r, ok2)) or not ok1 or not ok2: return
  result = r.split('\n')
  while result.len > 0 and result[^1].len == 0: result.setLen(result.len - 1)

proc fLastStmt(part: seq[string]): (FLine, bool) =
  ## the last statement of formatted lines (FLine() when none) — and is it in an `if`/`when` without other
  ## branches (in the body of its `if` line, at any depth)?
  var ok = true
  var ls = fGroupLines(fLex(part.join("\n") & "\n", ok))
  if not ok or ls.len == 0: return
  fDepths(ls)
  result[0] = ls[^1]
  if ls[^1].comment: return
  var d = ls[^1].depth
  for j in countdown(ls.high - 1, 0):
    if not ls[j].comment and ls[j].depth < d:
      d = ls[j].depth
      if ls[j].toks[0].kind == fkKw and ls[j].toks[0].text in ["if", "when"]: result[1] = true

proc fVerbatimCall*(o: FOut, text: string): seq[string] =
  ## a statement kept as written because a call's arguments hold a block — a lambda with its body (`cb:
  ## proc(x: T) =` ⏎ body) or an if/when/case written as a statement — as nph writes it: the arguments one a
  ## line, the block under its argument (formatted on its own), a comma after it; @[] when it is not one such
  let toks = o.toks
  # (a comment after the call's `)` stays after it)
  let trailing = toks.len > 0 and toks[^1].kind == fkComment and not toks[^1].multi and not toks[^1].nl
  let n = toks.len - ord(trailing)
  if n < 4 or toks[n - 1].kind != fkClose or toks[n - 1].text != ")": return
  var d = 0
  var open = -1
  for k in countdown(n - 1, 0):
    if toks[k].kind in {fkClose, fkPragClose}: inc d
    elif toks[k].kind in {fkOpen, fkPragOpen}:
      dec d
      if d == 0:
        open = k
        break
  if open < 1 or toks[open].text != "(" or not fCallParen(toks, open): return
  # the head (`x = f(`): an expression, after let/var/const or return/discard at most
  for k in 0 .. open:
    let t {.cursor.} = toks[k]
    if t.kind in {fkComment, fkSemi} or t.multi: return
    if t.kind == fkKw and t.text in FStmtWords and
       not (k == 0 and t.text in ["let", "var", "const", "return", "discard", "yield"]):
      return
  let ind = o.depth * 2
  var outp = @[spaces(ind) & fRender(toks.toOpenArray(0, open))]
  if outp[0].len > FmtMax: return
  # the arguments
  var elems: seq[(int, int)]
  var a = open + 1
  d = 0
  for k in open + 1 .. n - 1:
    let t {.cursor.} = toks[k]
    if k == n - 1 or (d == 0 and t.kind == fkComma):
      if k > a: elems.add (a, k)
      elif k < n - 1: return
      a = k + 1
      continue
    if t.kind in {fkOpen, fkPragOpen}: inc d
    elif t.kind in {fkClose, fkPragClose}: dec d
    elif d == 0 and t.kind == fkSemi: return
  if elems.len == 0: return
  let pad2 = spaces(ind + 2)
  var blocks = 0
  # (a block ends at the call's `)`, at a comma starting a line left of the block, or at a trailing comma with
  # the `)` on the next line: another comma on a line of the block may be its own — `echo a, b` in a lambda's
  # body — so such a statement stays as written)
  template blockEnds(eb, base: int): bool =
    eb == n - 1 or (toks[eb].nl and toks[eb].col < base) or
      (eb == n - 2 and toks[eb].kind == fkComma and toks[n - 1].nl)
  for ei, (ea, eb) in elems:
    # (a comma after each argument — after the last too when there are several, like nph)
    let sep = if ei < elems.high or elems.len > 1: "," else: ""
    # a lambda (`proc(…) =`, `name: proc(…) =`, `name = proc(…) =`) and its body
    var p = ea
    if toks[p].kind == fkIdent and p + 2 < eb and
       (toks[p + 1].kind == fkColon or (toks[p + 1].kind == fkOp and toks[p + 1].text == "=")):
      p += 2
    let eq = fLambdaAt(toks.toOpenArray(p, eb - 1), 0)
    if eq > 0 and p + eq + 1 < eb:
      let bodyAt = p + eq + 1
      for k in ea .. p + eq:
        if toks[k].kind == fkComment or toks[k].multi: return
      let hdr = pad2 & fRender(toks.toOpenArray(ea, p + eq))
      if hdr.len > FmtMax: return
      # (a body on the lambda's line: as written — the arguments around it may have made the statement one kept
      # as written only after a first run)
      if not toks[bodyAt].nl or not blockEnds(eb, toks[bodyAt].col): return
      let body = fFormatPart(fSnippet(toks, bodyAt, eb, text), FmtMax - ind - 4)
      if body.len == 0: return
      let (last, ifOne) = fLastStmt(body)
      if last.toks.len == 0: return
      # (`echo a,` ⏎ `)`: that comma could be the command's — as written)
      if eb == n - 2 and not toks[eb].nl and fCommandLike(last.toks): return
      outp.add hdr
      for l in body: outp.add (if l.len > 0: spaces(ind + 4) & l else: "")
      if sep.len > 0:
        # its comma after the body's last line — on a line of its own when that line is a comment, a command or
        # in the body of an `if`/`when` without other branches (like nph)
        if last.comment or last.toks[^1].kind == fkComment or ifOne or fCommandLike(last.toks):
          outp.add pad2 & sep
        else: outp[^1].add sep
      inc blocks
      continue
    # an if/when/case/try/block written as a statement over lines: formatted as one, under the call
    if toks[ea].kind == fkKw and toks[ea].text in ["if", "when", "case", "try", "block", "for", "while"]:
      var lines = false
      for k in ea + 1 ..< eb:
        if toks[k].nl: lines = true
      if not lines or not blockEnds(eb, toks[ea].col): return
      let part = fFormatPart(fSnippet(toks, ea, eb, text), FmtMax - ind - 2)
      if part.len < 2: return
      for l in part: outp.add (if l.len > 0: pad2 & l else: "")
      if sep.len > 0:
        let (last, _) = fLastStmt(part)
        if last.toks.len == 0 or last.comment or last.toks[^1].kind == fkComment: return
        if fCommandLike(last.toks): outp.add pad2 & sep
        else: outp[^1].add sep
      inc blocks
      continue
    # anything else: a plain value on its line
    for k in ea ..< eb:
      let t {.cursor.} = toks[k]
      if t.kind == fkComment or t.multi or (t.kind == fkKw and t.text in FStmtWords): return
    let line = pad2 & fRender(toks.toOpenArray(ea, eb - 1)) & sep
    if line.len > FmtMax: return
    outp.add line
  if blocks == 0: return
  outp.add spaces(ind) & ")" & (if trailing: " " & toks[^1].text else: "")
  if outp[^1].len > FmtMax: return
  outp

proc fColonBlock*(toks: openArray[FTok], a, b: int): bool =
  ## `name: stmt` where stmt is a command or a block statement (`runnableExamples: assert x`, `doAssert: static:
  ## …`): a call given a block on its line — not a field and its type
  var b = b
  while b > a and toks[b - 1].kind == fkComment: dec b          # (a trailing comment changes nothing)
  var a = a
  if b - a > 3 and toks[a].kind == fkKw and toks[a].text in FSectionKw: inc a     # (`var x: T`: the same)
  if b - a < 3 or toks[a].kind != fkIdent or toks[a + 1].kind != fkColon: return false
  let t = toks[a + 2]
  if t.kind == fkKw: return t.text in ["static", "block", "discard", "echo"] or (t.text in FBlockKw and b - a > 3)
  # (an expression too — `assert: a in b` — but never one with a `=` after it: `x: T = v`, a field's default)
  t.kind == fkIdent and t.text notin ["sink", "lent", "owned", "typedesc"] and fTopEq(toks, a + 2, b) < 0 and
    toks[b - 1].kind != fkColon

proc fStructToks*(toks: openArray[FTok], a, b: int, base: int, res: var seq[int]) =
  ## block depth of each token of a statement: an inline body (`if a: b`, `proc f() = x`) and an
  ## inline section member or enum value list count one deeper, exactly as when written on their own lines
  if a >= b: return
  var (hdrEnd, stop) = fSplitIdx(toks, a, b)
  if hdrEnd < 0 and fColonBlock(toks, a, b):
    # (`runnableExamples: assert x` — a call given a block: its body one deeper, on the line or under it)
    hdrEnd = a + 1 + ord(toks[a].kind == fkKw)
    stop = b
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
    # (separators: in brackets all at the brackets' depth, and checked with the tokens — `(a; b)` written a line
    # each has no `;`, a parameter's `;` becomes `,`)
    if t.kind in {fkComma, fkSemi}: continue
    var lvl = base
    if isSection and k > a: lvl += 1
    if afterEnum: lvl += 1
    res.add lvl
    if t.kind == fkKw and t.text == "enum" and k > a and toks[k - 1].kind == fkOp and toks[k - 1].text == "=" and
       not (k + 1 < b and toks[k + 1].kind == fkOp):
      afterEnum = true

func fCodeToks*(toks: seq[FTok]): int =
  ## how many tokens are code (not comments)
  for t in toks:
    if t.kind != fkComment: inc result

proc fStructureOf*(lines: seq[FLine]): seq[int] =
  ## for every token: how deep it sits in blocks
  var adj: seq[(int, int, string, int)]   # (depth of a line, what its children add, the branch words of a value
                                          # block it opens, the indentation of that block's first line): one-line
                                          # sections (`type X = object`) +1, a value on the line after `x =` -1
  for li in 0 ..< lines.len:
    template l: untyped = lines[li]
    if l.comment: continue
    while adj.len > 0 and l.depth <= adj[^1][0]:
      # (`x = if a:` ⏎ … ⏎ `else:` written at x's own level: still a branch of that if)
      if l.depth == adj[^1][0] and adj[^1][2].len > 0 and l.toks[0].kind == fkKw and
         (" " & l.toks[0].text & " ") in adj[^1][2]: break
      adj.setLen(adj.len - 1)
    # (`x = if a:` ⏎ body ⏎ `else:` written less deep than the body but deeper than x: a branch of that if too)
    let between = adj.len > 0 and adj[^1][2].len > 0 and l.depth > adj[^1][0] and l.indent < adj[^1][3] and
                  l.toks[0].kind == fkKw and (" " & l.toks[0].text & " ") in adj[^1][2]
    var base = if between: adj[^1][0] else: l.depth
    for a in adj: base += a[1]
    let before = result.len
    fStructToks(l.toks, 0, l.toks.len, base, result)
    let t0 = l.toks[0]
    var delta = 0
    if fOpensBlock(l) and result.len > before:
      delta = result[^1] - base             # `else: static:` — the block opened last holds the children
    elif t0.kind == fkKw and t0.text in FSectionKw and fCodeToks(l.toks) > 1: inc delta    # (`const ## doc`: not one)
    if fValueEq(l.toks): dec delta
    if l.toks.len == 1 and t0.kind == fkKw and t0.text in ["return", "yield", "raise", "discard"]:
      var nx = li + 1
      while nx < lines.len and lines[nx].comment: inc nx
      if nx < lines.len and lines[nx].depth > l.depth: dec delta          # return ⏎ its value under it
    if t0.kind == fkKw and t0.text == "case": dec delta          # its branches, if indented
    # `import` on its own line: the modules under it are part of that one statement
    if l.toks.len == 1 and t0.kind == fkKw and t0.text in ["import", "export", "include"]: dec delta
    # `x = if a:` / `x = case k` with its lines under it: however deep they are written, the same as `x =` ⏎
    # `if a:` (or `case k`) on a line of its own
    var branches = ""
    var bodyInd = -1
    if not (t0.kind == fkKw and (t0.text in FRoutineKw or t0.text in FBlockKw)):
      let eq = fTopEq(l.toks, 0, l.toks.len)
      if eq > 0 and eq + 2 < l.toks.len and l.toks[eq + 1].kind == fkKw and
         l.toks[eq + 1].text in ["if", "when", "case", "try"] and
         (fOpensBlock(l) or l.toks[eq + 1].text == "case"):
        var lam = false
        for q in 0 ..< eq:
          if l.toks[q].kind == fkKw and l.toks[q].text in FRoutineKw: lam = true
        var nx = li + 1
        while nx < lines.len and lines[nx].comment: inc nx
        if not lam and nx < lines.len and lines[nx].depth > l.depth:
          let sec = ord(t0.kind == fkKw and t0.text in FSectionKw)
          delta = l.depth + sec + (if l.toks[eq + 1].text == "case": 0 else: 1) - lines[nx].depth
          branches = case l.toks[eq + 1].text
                     of "if", "when": " elif else "
                     of "case": " of elif else "
                     else: " except finally "
          bodyInd = lines[nx].indent
    if between: adj.add (l.depth, delta + adj[^1][0] - l.depth, "", -1)       # (its body: as under a branch at x's level)
    elif adj.len > 0 and adj[^1][0] == l.depth and adj[^1][2].len > 0: discard   # (a branch of that value block)
    else: adj.add (l.depth, delta, branches, bodyInd)

type FCmpState* = object
  k*: int
  groups*: seq[(string, int)]     # open brackets: (text, commas seen in it)

proc fCmpNext*(toks: seq[FTok], st: var FCmpState): int =
  ## the next token that matters for "same code": not comments (doc comments do), not depth-0 commas,
  ## not trailing commas — except in `(x,)`, a one-element tuple
  while st.k < toks.len:
    let t {.cursor.} = toks[st.k]
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

func fTypedBefore(toks: seq[FTok], k: int): bool =
  ## has the element before the separator at k a type or a default (`c: T`, `c = 1`) — which ends its group, so
  ## that `;` and `,` after it mean the same?
  var d = 0
  var m = k - 1
  while m >= 0:
    let t = toks[m]
    if t.kind in {fkClose, fkPragClose}: inc d
    elif t.kind in {fkOpen, fkPragOpen}:
      if d == 0: return false
      dec d
    elif d == 0 and t.kind in {fkComma, fkSemi}: return false
    elif d == 0 and (t.kind == fkColon or (t.kind == fkOp and t.text == "=")): return true
    dec m
  false

func fParamSep*(toks: seq[FTok], k: int): bool =
  ## does a parameter (`name: T`, `a, b: T`, `name = x`) follow the separator at k?
  var m = k + 1
  while m + 1 < toks.len and toks[m].kind == fkComment: inc m
  while m + 1 < toks.len and toks[m].kind == fkIdent and toks[m + 1].kind == fkComma: m += 2
  if m < toks.len and toks[m].kind == fkClose and m > k + 1 and toks[m - 1].kind == fkComma: return true  # `a, b,)`
  if m < toks.len and toks[m].kind == fkClose and m == k + 1 and fTypedBefore(toks, k): return true  # `(q: T;)`
  if m + 2 < toks.len and toks[m].kind == fkIdent and toks[m + 1].kind == fkPragOpen:
    # (Nim 3: `r {.register: "rdi".}: Words` — a parameter with a pragma of its own: the pragma is skipped)
    var e = m + 2
    while e < toks.len and toks[e].kind != fkPragClose: inc e
    if e + 1 < toks.len and toks[e + 1].kind == fkColon: return true
  m + 1 < toks.len and toks[m].kind == fkIdent and
    (toks[m + 1].kind in {fkColon, fkClose} or (toks[m + 1].kind == fkOp and toks[m + 1].text == "=") or
     (toks[m + 1].kind == fkSemi and m + 2 < toks.len and toks[m + 2].kind == fkClose) or   # (`def;` ⏎ `)`, nph's)
     # (`c = 1; y; z: int` → `c = 1, y; z: int`: a `using` parameter after one with a default — that one's group
     # has ended, so `y` stays on its own either way)
     (toks[m + 1].kind == fkSemi and fTypedBefore(toks, k)))

func fSameWords*(a, b: string): bool =
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

func fCommentMark*(t: string): string =
  ## "##" for a line of a doc comment, "#" for one of a plain comment, "" for anything else (a block comment
  ## `#[ … ]#`, `###`, a shebang, a source filter)
  if t.startsWith("##"):
    if t.startsWith("##[") or t.startsWith("###"): "" else: "##"
  elif t.startsWith("#"):
    if t.len > 1 and t[1] in {'[', '!', '?'}: "" else: "#"
  else: ""

func fRuleTail*(t: string): (string, int) =
  ## a comment line that ends in a rule (`# ── Section ─────`): (the rule's character, where the rule starts) —
  ## ("", -1) when it does not end in 3 or more of one of ─ ═ - = * ~ _ #
  for r in ["─", "═", "-", "=", "*", "~", "_", "#"]:
    if t.endsWith(r & r & r):
      var k = t.len
      while k >= r.len and t[k - r.len ..< k] == r: k -= r.len
      return (r, k)
  ("", -1)

func fSameButRule*(a, b: string): bool =
  ## two comment lines the same but for how long the rule at their end is (a banner cut to the line length)
  let (ra, ka) = fRuleTail(a)
  let (rb, kb) = fRuleTail(b)
  ra.len > 0 and ra == rb and fSameWords(a[0 ..< ka], b[0 ..< kb])

func fPrefixLike*(toks: seq[FTok], k: int): bool =
  ## an operator after an operand, with a space before it and none after: Nim reads it as a prefix
  ## (`echo -1` is echo(-1)) — the formatter must never change that
  if k == 0 or k + 1 >= toks.len or toks[k].nl: return false        # first on its line: a statement's start
  var p = k - 1
  while p > 0 and toks[p].kind == fkComment: dec p
  # (after a keyword too: `distinct|(a)` is a typeclass, `distinct |(a)` does not parse)
  if not (fOperand(toks[p]) or toks[p].kind == fkKw and not fWordOp(toks[p])): return false
  let before = toks[k].sp or toks[k].nl
  let after = toks[k + 1].sp or toks[k + 1].nl
  before and not after

func fInImport*(toks: seq[FTok], k: int): bool =
  ## is token k in an import / include / from statement? (one over several lines too: `import ⏎ a, ⏎ b/[c]`)
  var i = k
  while i > 0:
    if toks[i].nl:
      let p = toks[i - 1]
      if not (p.kind in {fkComma, fkOpen} or (p.kind == fkKw and p.text in ["import", "include", "from", "export"])):
        break
    dec i
  toks[i].kind == fkKw and toks[i].text in ["import", "include", "from", "export"]

proc fSameTokensMap(a, b: seq[FTok], map: var seq[int32]): bool =
  ## the same code: tokens in the same order — layout, comments, trailing commas, item commas and
  ## `;` vs `,` between parameters aside. With a `map` (b.len long), map[y] = the token of a that b[y] is
  var sa, sb: FCmpState
  let mapped = map.len > 0
  while true:
    var x = fCmpNext(a, sa)
    let y = fCmpNext(b, sb)
    if x < 0 or y < 0: return x < 0 and y < 0
    # (statements in parentheses `(let a = f(); a > 0)` written a line each: the `;` became a line break — nph's
    # layout of a long one; kept as written from then on, the line breaks being the code's)
    if a[x].kind == fkSemi and b[y].kind != fkSemi and b[y].nl and sa.groups.len > 0 and sa.groups[^1][0] == "(":
      x = fCmpNext(a, sa)
      if x < 0: return false
    if mapped: map[y] = int32(x)
    let tx {.cursor.} = a[x]
    let ty {.cursor.} = b[y]
    if tx.kind == fkComment or ty.kind == fkComment:
      # doc comments: the same words (a block one may move with its statement)
      if tx.kind != ty.kind: return false
      if not fSameWords(tx.text, ty.text) and not fSameButRule(tx.text, ty.text):
        # a comment paragraph re-wrapped (nim.format.reflowDocComments, reflowComments): the same words over its
        # lines, all of them comments of the same kind
        let mark = fCommentMark(tx.text)
        if mark.len == 0 or fCommentMark(ty.text) != mark: return false
        var wa = tx.text[mark.len .. ^1].splitWhitespace
        var wb = ty.text[mark.len .. ^1].splitWhitespace
        if wa.len == 0 or wb.len == 0: return false
        while wa != wb:
          if wa.len < wb.len and wb[0 ..< wa.len] == wa:
            let nx = fCmpNext(a, sa)
            if nx < 0 or a[nx].kind != fkComment or fCommentMark(a[nx].text) != mark: return false
            wa.add a[nx].text[mark.len .. ^1].splitWhitespace
          elif wb.len < wa.len and wa[0 ..< wb.len] == wb:
            let ny = fCmpNext(b, sb)
            if ny < 0 or b[ny].kind != fkComment or fCommentMark(b[ny].text) != mark: return false
            wb.add b[ny].text[mark.len .. ^1].splitWhitespace
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

proc fSameTokens*(a, b: seq[FTok]): bool =
  var none: seq[int32]
  fSameTokensMap(a, b, none)

proc fContinues(a: seq[FTok], x: int): bool =
  ## may a line break follow a[x] in the middle of a statement — does Nim's parser read the next line as more of
  ## it? After `,` `;` `:` `=` `.`, an opening bracket (`(` `[` `{` `{.`), an operator (`+`, `and`, `not`, `%*` …:
  ## what follows it may start on the next line, deeper), `import` …: not after the `*` that exports a name
  ## (`proc f*` ⏎ `(…)`), another keyword, or an operand. (Whether an operator is binary or applies to what
  ## follows — `echo -1` — is the spacing's, checked with the tokens: fPrefixLike.)
  let t {.cursor.} = a[x]
  case t.kind
  of fkComma, fkSemi, fkOpen, fkPragOpen, fkColon, fkDot: true
  of fkOp: not fExportMark(a, x)
  of fkKw: fWordOp(t) or t.text in ["import", "include", "export", "from"]      # (`import` ⏎ a, b)
  else: false

func fEnumValue(a: seq[FTok], aStart: seq[int16], x: int): bool =
  ## is a[x] one of an enum's values — on the `X = enum` line or on a line under it? (aStart: where a's statements
  ## start, their depth + 1)
  var s = x
  while s > 0 and aStart[s] == 0: dec s
  for k in s + 1 ..< x:
    if a[k].kind == fkKw and a[k].text == "enum" and a[k - 1].kind == fkOp and a[k - 1].text == "=": return true
  let d = aStart[s]
  var p = s - 1
  while p >= 0:
    if aStart[p] > 0 and aStart[p] < d and a[p].kind != fkComment:
      if aStart[p] != d - 1: return false
      var last = s - 1           # (the end of that line: the next statement starts at or before s)
      for q in p + 1 ..< s:
        if aStart[q] > 0:
          last = q - 1
          break
      while last > p and a[last].kind == fkComment: dec last
      return last > p and a[last].kind == fkKw and a[last].text == "enum" and a[last - 1].kind == fkOp and
             a[last - 1].text == "="
    dec p
  false

proc fBreakNeeded(a: seq[FTok], aStart: seq[int16], k: int): bool =
  ## the code's line break before a[k]: is it one the code needs — not one a line may go on after (fContinues:
  ## `x =` ⏎ value, `if a:` ⏎ body; before a closing bracket, `.`, `{.`, `,`; before a branch `else:` …; after
  ## the `type` of a section of one)? Two statements apart (`(discard` ⏎ `echo 1)`), a statement and the next
  var pk = k - 1
  while pk >= 0 and a[pk].kind == fkComment: dec pk
  var nk = k
  while nk < a.len and a[nk].kind == fkComment: inc nk
  if pk < 0 or nk >= a.len: return false
  let n {.cursor.} = a[nk]
  if n.kind in {fkClose, fkPragClose, fkDot, fkPragOpen, fkComma, fkSemi} or a[pk].kind == fkSemi: return false
  if n.kind == fkKw and n.text in ["else", "elif", "of", "except", "finally"]: return false
  # (a section of one: `type` ⏎ `X = …` is `type X = …`, like nph)
  if a[pk].kind == fkKw and a[pk].text in FSectionKw and aStart[pk] > 0: return false
  # (`return` ⏎ its value, deeper: `return value`)
  if a[pk].kind == fkKw and a[pk].text in ["return", "raise", "yield", "discard", "break", "continue"] and
     n.col > a[pk].col:
    return false
  not fContinues(a, pk)

proc fBreaksOk(a: seq[FTok], aNl: seq[bool], aStart: seq[int16], b: seq[FTok], map: seq[int32]): bool =
  ## every line break in the output b — whose tokens are a's (map) — where Nim's parser reads on: before a
  ## statement (one of a's: aStart), after a token a line may continue after (fContinues; after `return`,
  ## `raise` … when the value is deeper), before a closing bracket or a `.` (`foo` ⏎ `.bar()`), before a branch
  ## (`else:` of an if-expression), between two enum values (their comma gone: nph's one a line), or one a had
  ## between the same two tokens (aNl: a's line breaks before the formatting; a `;` there too — nph's statements
  ## in parentheses a line each). And every line break of a's that is not one of those stays (fBreakNeeded).
  var py = -1                 # the last code token
  var brk = false             # a line break since it
  var depth = 0               # brackets open
  var lastX = -1              # the last code token's in a (of those that are a's)
  var brkX = false            # a line break (or a `;`) since that one
  for y in 0 ..< b.len:
    let t {.cursor.} = b[y]
    let tk = t.kind
    if t.nl:
      brk = true
      brkX = true
    if tk == fkComment:
      # (a doc comment is code to Nim: in brackets, one the code had at the end of a line does not get a line of
      # its own)
      if t.nl and depth > 0 and t.text.startsWith("##") and map[y] >= 0 and not aNl[map[y]] and
         aStart[map[y]] == 0:
        return false
      continue
    if brk and py >= 0:
      let x = map[y]
      let px = map[py]
      # (a `,` inside brackets may start a line: nph's after a lambda's body, `proc() =` ⏎ body ⏎ `,`)
      var ok = (x >= 0 and aStart[x] > 0) or t.kind in {fkClose, fkPragClose, fkDot} or
               (t.kind == fkComma and depth > 0) or
               (if px >= 0: fContinues(a, px) else: b[py].kind in {fkComma, fkSemi})
      if not ok and px >= 0 and a[px].kind == fkKw and a[px].text == "enum": ok = true      # `= enum` ⏎ A
      if not ok and t.kind == fkKw:
        if t.text in ["else", "elif", "except", "finally"]: ok = true
        elif t.text == "of" and x >= 0:           # (a branch, not the operator: `x of T`)
          var p = x - 1
          while p >= 0 and a[p].kind == fkComment: dec p
          ok = p < 0 or not fOperand(a[p])
      if not ok and px >= 0 and a[px].kind == fkKw and
         a[px].text in ["return", "raise", "yield", "discard", "break", "continue"]:
        ok = t.col > b[py].col                    # (`raise` ⏎ its value, deeper)
      if not ok and x > px and px >= 0:
        # (the same two tokens a line apart in the code: only comments, commas and `;` between them)
        var had = false
        var comma = false
        ok = true
        for k in px + 1 .. x:
          if aNl[k] or a[k].kind == fkSemi: had = true
          if a[k].kind == fkComma: comma = true
          if k < x and a[k].kind notin {fkComment, fkComma, fkSemi}: ok = false
        ok = ok and (had or comma and fEnumValue(a, aStart, x))
      if not ok: return false
    let x = map[y]
    if x >= 0:
      # the other way: a line break the code had between this token and the last one of a's before it, gone in
      # the output — fine where a line goes on (as above), else it is the code's: two statements, `(discard` ⏎
      # `echo 1)`, are not `(discard echo 1)` (a `;` in the output for it does)
      if lastX >= 0 and not brkX and x > lastX:
        var k = lastX + 1
        if k < x:                 # (most often x is the very next one)
          while k < x and not aNl[k]: inc k
        if aNl[k] and fBreakNeeded(a, aStart, k): return false
      lastX = x
      brkX = false
    case tk
    of fkOpen, fkPragOpen: inc depth
    of fkClose, fkPragClose: dec depth
    of fkSemi: brkX = true
    else: discard
    py = y
    brk = false
  true


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
        var bl = l
        bl.toks = l.toks[h + 1 .. ^1]
        bl.depth = l.depth + 1
        bl.blank = false
        # (one doc line: on the header's line when it fits there — `proc f(): int = ## doc` ⏎ body —, after a
        # body that is a `return`, `discard` or `raise` on the body's line; like nph)
        let c = lines[idx].toks[0]
        let after = bl.toks.len > 1 and bl.toks[0].kind == fkKw and bl.toks[0].text in ["return", "discard", "raise"]
        if lines[idx].toks.len == 1 and not lines[idx].blank and not c.text.startsWith("##[") and
           (idx + 1 >= lines.len or not lines[idx + 1].comment) and
           (if after: bl.depth * 2 + fRenderLen(bl.toks) else: l.depth * 2 + fRenderLen(hl.toks)) + 1 +
             c.text.len <= FmtMax:
          var t = c
          t.nl = false
          t.sp = true                  # (a space before it now: `=` stays a binary operator for the check)
          t.blanks = 0
          if after: bl.toks.add t else: hl.toks.add t
          inc idx
        res.add hl
        while idx < lines.len and lines[idx].comment and lines[idx].depth > l.depth and
              lines[idx].toks[0].text.startsWith("##"):
          var c = lines[idx]
          c.depth = l.depth + 1
          res.add c
          inc idx
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
      # (not before a `#[ … ]#` with code after it: `proc#[!]#f*() =` is the routine f)
      if k < l.toks.len and not (l.toks[k].kind == fkOpen and l.toks[k].text == "(") and
         (l.toks[k].kind in {fkColon, fkPragOpen} or (l.toks[k].kind == fkOp and l.toks[k].text == "=") or
          (l.toks[k].kind == fkComment and (k == l.toks.high or not l.toks[k].text.startsWith("#[")))):
        let p = l.toks[k - 1].pos
        l.toks.insert(FTok(kind: fkClose, text: ")", pos: p), k)
        l.toks.insert(FTok(kind: fkOpen, text: "(", pos: p), k)
      elif k == l.toks.len and l.toks[k - 1].kind == fkIdent:
        l.toks.add [FTok(kind: fkOpen, text: "(", pos: l.toks[k - 1].pos),
                    FTok(kind: fkClose, text: ")", pos: l.toks[k - 1].pos)]
    # `case x:` → `case x` (like nph)
    var caseAt = if t0.kind == fkKw and t0.text == "case": 0 else: -1
    if caseAt < 0:
      let e = fTopEq(l.toks, 0, l.toks.len)
      if e > 0 and e + 1 < l.toks.len and l.toks[e + 1].kind == fkKw and l.toks[e + 1].text == "case": caseAt = e + 1
    if caseAt >= 0 and l.toks.len > caseAt + 2:
      var k = l.toks.high
      while k > 0 and l.toks[k].kind == fkComment: dec k
      if l.toks[k].kind == fkColon and k >= 2: l.toks.delete(k)
    # `quote do:` ⏎ body → `quote:` — a block given to a call needs no `do` without parameters (like nph)
    block:
      var k = l.toks.high
      while k > 0 and l.toks[k].kind == fkComment: dec k
      if k >= 2 and l.toks[k].kind == fkColon and l.toks[k - 1].kind == fkKw and l.toks[k - 1].text == "do" and
         l.toks[k - 2].kind in {fkIdent, fkClose} and not (t0.kind == fkKw and t0.text in FRoutineKw):
        # (only when the call is the whole statement or the whole value after `=`: in `s.add quote do:` the block
        # would go to `add`)
        # (after an inline block's header, `insert(0): quote do:`, the statement starts after its `:`)
        let (hb, _) = fSplitIdx(l.toks, 0, k + 1)
        let s0 = if hb >= 0 and hb < k - 2: hb + 1 else: 0
        let eq = fTopEq(l.toks, s0, k - 1)
        var a = if eq >= 0: eq + 1 elif s0 == 0 and t0.kind == fkKw and t0.text in FSectionKw: 1 else: s0
        if eq >= 0 and a < k - 1 and l.toks[a].kind == fkKw: a = -1         # (x = when …)
        var plain = a >= 0 and a < k - 1 and l.toks[a].kind == fkIdent
        var q = a + 1
        while plain and q < k - 1 and l.toks[q].kind == fkDot and q + 1 < k - 1 and l.toks[q + 1].kind == fkIdent:
          q += 2
        if plain and q < k - 1:
          # one call's parentheses, right after the name, then nothing
          if l.toks[q].kind == fkOpen and l.toks[q].text == "(" and fCallParen(l.toks, q):
            var d = 0
            while q < k - 1:
              if l.toks[q].kind in {fkOpen, fkPragOpen}: inc d
              elif l.toks[q].kind in {fkClose, fkPragClose}:
                dec d
                if d == 0:
                  inc q
                  break
              inc q
            plain = q == k - 1
          else: plain = false
        if plain: l.toks.delete(k - 1)
    # `f():` ⏎ body → `f:` — a call whose only argument is its block needs no parentheses (like nph): the whole
    # statement `name(.name)*():`, nothing else on it
    block:
      var k = l.toks.high
      while k > 0 and l.toks[k].kind == fkComment: dec k
      if k >= 3 and l.toks[k].kind == fkColon and l.toks[k - 1].kind == fkClose and l.toks[k - 1].text == ")" and
         l.toks[k - 2].kind == fkOpen and l.toks[k - 2].text == "(" and t0.kind == fkIdent:
        var q = 1
        while q + 1 < k - 2 and l.toks[q].kind == fkDot and l.toks[q + 1].kind == fkIdent: q += 2
        if q == k - 2 and l.toks[k - 3].kind == fkIdent:
          l.toks.delete(k - 1)
          l.toks.delete(k - 2)
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
    # (`say f, if a: f else: f += 1; f`: a `;` after a block inside the statement is that block's — as written)
    block:
      var inBlock = false
      d = 0
      for k in 1 ..< semis[0]:
        let t {.cursor.} = l.toks[k]
        if t.kind in {fkOpen, fkPragOpen}: inc d
        elif t.kind in {fkClose, fkPragClose}: dec d
        elif d == 0 and t.kind == fkKw and (t.text in FBlockKw or t.text in FRoutineKw or
                                            t.text in ["case", "do"]):
          inBlock = true
      if inBlock and not (t0.kind == fkKw and (t0.text in FBlockKw or t0.text in FRoutineKw)):
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

func fRuneLen(s: string): int =
  ## the columns `s` takes (characters, not bytes: `·` and `—` are one each)
  for c in s:
    if (ord(c) and 0xC0) != 0x80: inc result

const FTodoTags = ["TODO", "FIXME", "NOTE", "XXX", "HACK", "BUG", "OPTIMIZE", "REVIEW", "SAFETY"]

func fProseLine(c: string, plain: bool): bool =
  ## a line of prose in a comment, which may be re-wrapped with the lines around it — not a list item, a table, a
  ## heading, a directive, code (an RST block, a fenced or indented one; in a # comment, also what reads as
  ## commented-out code), a banner, a TODO
  if c.len == 0 or c[0] in {' ', '\t', '|', '>', '#', '='}: return false
  if c.startsWith("```") or c.startsWith(".."): return false              # (a fence, an RST directive)
  if c[0] in {'-', '*', '+'} and (c.len == 1 or c[1] == ' ' or c[1] == c[0]): return false   # (a list item, a rule)
  if c[0] == ':' and c.len > 1 and c[1] in IdentChars: return false     # (an RST field: `:param x:`)
  var d = 0
  while d < c.len and c[d] in Digits: inc d
  if d > 0 and d < c.len and c[d] in {'.', ')'}: return false            # (a numbered list)
  for bar in ["───", "═══", "---", "===", "***", "~~~", "___", "###", "///", "+++"]:
    if bar in c: return false                                            # (a banner or a rule)
  if c.startsWith("[^") or c.startsWith("http://") or c.startsWith("https://"): return false   # (a footnote, a link)
  if " # " in c: return false                     # (an example with a comment of its own: `foo(x) # why`)
  if c[0] == '[':
    let rb = c.find(']')
    if rb > 0 and rb + 1 < c.len and c[rb + 1] == ':': return false       # (a link's definition: `[name]: url`)
  if not plain: return true
  # (a # comment: directives, TODOs and what reads as commented-out code stay as they are)
  for dir in ["ned:", "nim:", "noqa", "nolint", "pragma", "type:"]:
    if c.startsWith(dir): return false
  for op in [" == ", " != ", " += ", " -= ", " *= ", " &= ", " := ", " >= ", " <= "]:
    if op in c: return false                                            # (an expression, not a sentence)
  var w = 0
  while w < c.len and c[w] in IdentChars: inc w
  let first = c[0 ..< w]
  if first in FTodoTags and (w == c.len or c[w] in {':', ' ', '('}): return false
  let t = c.strip(leading = false)
  if t[^1] in {'=', '(', '[', '{', '\\'}: return false
  if t[^1] == ':' and first in ["if", "elif", "else", "when", "while", "for", "case", "of", "try", "except",
                                 "finally", "block", "defer", "static", "using"]:
    return false                                                      # `for x in y:`, `of 1:`
  if w < c.len and first.len > 0:
    if c[w] in {'(', '[', '{', '='}: return false                       # `foo(x)`, `a[0]`, `x=1`
    if c[w] == '.' and first.len >= 2 and w + 1 < c.len and c[w + 1] in IdentStartChars: return false   # `x.y`
  if w + 2 < c.len and c[w] == ' ' and c[w + 1] in {'=', ':'} and c[w + 2] == ' ': return false   # `x = 1`
  let ws = c.splitWhitespace
  if first in ["let", "var", "const", "proc", "func", "iterator", "method", "template", "macro", "converter",
               "type"] and ws.len >= 2:
    # `let x = 1`, `proc foo(…)`, `type T = object`: a name, then what follows a declared name
    let rest = c[w .. ^1].strip
    var k = 0
    while k < rest.len and rest[k] in IdentChars: inc k
    if k > 0 and (k == rest.len or rest[k] in {'*', '(', '[', ':', '{'} or rest[k .. ^1].startsWith(" =")):
      return false
  if first in ["import", "include", "export"] and (ws.len <= 3 or '/' in c or '[' in c): return false
  if first == "from" and " import " in c: return false
  if first in ["echo", "discard", "return", "yield", "raise", "assert", "doAssert"] and
     (ws.len <= 2 or '"' in c or ',' in c): return false
  # an identifier right before `(` outside `backticks`: a call written as code
  var inTick = false
  for k in 0 ..< c.len:
    if c[k] == '`': inTick = not inTick
    elif not inTick and c[k] == '(' and k > 0 and c[k - 1] in IdentChars: return false
  true

proc fReflowComments*(entries: var seq[FOut]) =
  ## nim.format.reflowDocComments (and reflowComments): a `##` paragraph (a `#` one) with a line longer than the
  ## line length re-wrapped to it — lists, code, tables, headings, directives and banners stay as they are
  var res: seq[FOut]
  var fence = false
  var i = 0
  proc textOf(o: FOut): (string, string) =
    ## (its mark, the text after it) — mark "" when it is no comment line of its own
    if not o.comment or o.toks.len != 1: return ("", "")
    let t = o.toks[0].text
    let m = fCommentMark(t)
    if m.len == 0 or (m == "##" and not FmtReflow) or (m == "#" and not FmtReflowPlain): return ("", "")
    var c = t[m.len .. ^1]
    if m == "#" and c.len > 0 and c[0] != ' ': return ("#", "")     # (`#code`: commented out — as it is)
    if c.startsWith(" "): c = c[1 .. ^1]
    (m, c)
  while i < entries.len:
    let (mark, c0) = textOf(entries[i])
    if mark.len == 0:
      fence = false
      res.add move(entries[i])
      inc i
      continue
    if c0.startsWith("```"): fence = not fence
    if fence or not fProseLine(c0, mark == "#"):
      # (a banner — `# ── Section ──────` — longer than the line: its rule cut to fit, three at least)
      let t = entries[i].toks[0].text
      let over = entries[i].depth * 2 + fRuneLen(t) - FmtMax
      let (r, k) = fRuleTail(t)
      if not fence and over > 0 and r.len > 0:
        let n = (t.len - k) div r.len
        let keep = max(3, n - over)
        if keep < n:
          entries[i].toks[0].text = t[0 ..< k] & r.repeat(keep)
      res.add move(entries[i])
      inc i
      continue
    # only a comment block of its own — the module's, a routine's or type's under its header, or between
    # statements — not one under a field or an enum value (that one moves with it as its trailing comment)
    var pc = i - 1
    while pc >= 0 and (entries[pc].comment or entries[pc].toks.len == 0): dec pc     # (an empty one: a blank line)
    if pc >= 0 and entries[pc].depth < entries[i].depth:
      let fl = FLine(toks: entries[pc].toks)
      if not fOpensBlock(fl):
        res.add move(entries[i])
        inc i
        continue
    var j = i
    var words: seq[string]
    var long = false
    while j < entries.len and entries[j].depth == entries[i].depth and (j == i or not entries[j].blank) and
          entries[j].toks.len == 1 and entries[j].toks[0].col == entries[i].toks[0].col:
      let (m2, c) = textOf(entries[j])
      if m2 != mark or not fProseLine(c, mark == "#"): break
      if entries[j].depth * 2 + fRuneLen(entries[j].toks[0].text) > FmtMax: long = true
      words.add c.splitWhitespace
      inc j
    if not long:
      for k in i ..< j: res.add move(entries[k])
      i = j
      continue
    let width = FmtMax - entries[i].depth * 2 - mark.len - 1
    var cur = ""
    var curLen = 0
    var outp: seq[string]
    for w in words:
      let wl = fRuneLen(w)
      if curLen > 0 and curLen + 1 + wl > width:
        outp.add cur
        cur = w
        curLen = wl
      else:
        if curLen > 0:
          cur.add ' '
          inc curLen
        cur.add w
        curLen += wl
    if cur.len > 0: outp.add cur
    let first = entries[i]
    for k, o in outp:
      var ne = first
      ne.toks = @[FTok(kind: fkComment, text: mark & " " & o, nl: true, col: first.toks[0].col,
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

var fNoCheck* = false      # (the formatter's own tests: the result unchecked, to see what a refused one would be)

func fScriptField(o: FOut): bool =
  ## a package field of a NimScript file: `name = value` at the top (version, author, srcDir, bin …)
  o.keep and o.depth == 0 and not o.comment and o.toks.len >= 3 and o.toks[0].kind == fkIdent and
    o.toks[1].kind == fkOp and o.toks[1].text == "="

proc fScriptKeep(lines: var seq[FLine]) =
  ## NimScript (.nims, .nimble): what scripts write their own way stays as written — the package's `name = value`
  ## lines (lined up after: fScriptAlign), compiler switches (`--opt:speed`), task and hook headers (`task build,
  ## "…":`, `before install:`), a short `if x: y`, and a line with a comment at its end (it stays there)
  for l in lines.mitems:
    if l.comment or l.toks.len == 0: continue
    let t0 = l.toks[0]
    var last = l.toks.high
    while last > 0 and l.toks[last].kind == fkComment: dec last
    var keep = false
    if l.depth == 0 and t0.kind == fkIdent and fTopEq(l.toks, 0, l.toks.len) > 0:
      keep = true                                   # version = "1.0" · namedBin["x"] = "y"
    elif t0.kind == fkOp and t0.text in ["--", "-"]:
      keep = true                                   # --opt:speed · --path:"../src"
    elif t0.kind == fkIdent and t0.text in ["task", "before", "after", "feature"] and l.toks[last].kind == fkColon:
      keep = true
    elif t0.kind == fkKw and t0.text in ["if", "when", "elif", "else", "for", "while"]:
      let c = fTopColon(l.toks, 0, l.toks.len)
      if c > 0 and c < last: keep = true            # `if x: y` on one line
    if not keep and last < l.toks.high and last > 0: keep = true    # a comment at the end of the line
    if keep:
      l.verbatim = true
      l.keep = true

proc fScriptAlign(entries: seq[FOut], res: var seq[string], firstLine: seq[int], gap: seq[bool]) =
  ## NimScript: the `=` of a run of package fields lined up, as nimble's own template writes them
  ## (`version       = "0.1.0"`): at the column they share already when there is room, else one after the
  ## longest name. A value continued on the lines below moves with its `=`
  var i = 0
  while i < entries.len:
    if not fScriptField(entries[i]):
      inc i
      continue
    var run = @[i]
    var j = i + 1
    while j < entries.len and fScriptField(entries[j]) and not gap[j]:
      run.add j
      inc j
    i = j
    if run.len < 2: continue
    var longest = 0
    var cols: seq[int]
    for e in run:
      let name = entries[e].toks[0].text
      longest = max(longest, name.len)
      cols.add res[firstLine[e]].find('=', name.len)
    if -1 in cols: continue
    var shared = true
    for c in cols:
      if c != cols[0]: shared = false
    let target = if shared and cols[0] >= longest + 1: cols[0] else: longest + 1
    for n, e in run:
      let line = res[firstLine[e]]
      let name = entries[e].toks[0].text
      # (`name<pad>= value`: one space after the `=` — with none, Nim would read it as a prefix operator)
      var vs = cols[n] + 1
      while vs < line.len and line[vs] == ' ': inc vs
      let fresh = name & spaces(target - name.len) & "= " & line[vs .. ^1]
      let delta = (target + 2) - vs
      if fresh == line: continue
      res[firstLine[e]] = fresh
      if delta == 0: continue
      for k in 1 ..< entries[e].lineCount:
        let at = firstLine[e] + k
        if at >= res.len or res[at].len == 0: continue
        if delta > 0: res[at] = spaces(delta) & res[at]
        else:
          let lead = leadingWs(res[at]).len
          res[at] = res[at][min(lead, -delta) .. ^1]

proc fFormat*(text: string, err: var string): string =
  var ok = true
  let toks = fLex(text, ok)
  if not ok:
    err = "cannot read this file (an unclosed string or comment?)"
    return text
  var lines = fGroupLines(toks)
  fDepths(lines)
  fNormalize(lines)
  if FmtScript: fScriptKeep(lines)
  if FmtImports > 0: fImports(lines)
  var normToks: seq[FTok]
  for l in lines: normToks.add l.toks
  # (for the check: the code's line breaks and where its statements start — the tokens are shared and the
  # transformation moves some)
  var normNl = newSeq[bool](normToks.len)
  var normStart = newSeq[int16](normToks.len)     # (its depth + 1)
  block:
    var k = 0
    for l in lines:
      if l.toks.len > 0: normStart[k] = int16(min(l.depth + 1, high(int16)))
      k += l.toks.len
    for k in 0 ..< normToks.len: normNl[k] = normToks[k].nl
  var entries = fTransform(lines)
  if FmtReflow or FmtReflowPlain: fReflowComments(entries)
  var res: seq[string]
  var prevDepth = -1
  var firstLine = newSeq[int](entries.len)      # (for lining up: where each entry's first line went,
  var parentOf = newSeq[int](entries.len)       #  and the entry it belongs to)
  var lastAt: seq[int]
  var gap = newSeq[bool](entries.len)           # an empty line written before it
  var lastAtPrev: seq[int]                      # (each depth's last entry before this one)
  for i in 0 ..< entries.len:
    template o: untyped = entries[i]
    lastAtPrev = lastAt
    parentOf[i] = if o.depth > 0 and o.depth - 1 < lastAt.len: lastAt[o.depth - 1] else: -1
    if lastAt.len <= o.depth: lastAt.setLen(o.depth + 1)
    lastAt[o.depth] = i
    # blank lines: one at most, never at the top of a block nor before a branch (of, elif, else, except,
    # finally), and one after a multi-line routine or type — also where its block ends (like nph)
    let branch = not o.comment and o.toks.len > 0 and o.toks[0].kind == fkKw and
                 o.toks[0].text in ["of", "elif", "else", "except", "finally"]
    var blank = o.blank and res.len > 0 and not (prevDepth >= 0 and o.depth > prevDepth) and not branch
    if res.len > 0 and o.depth <= prevDepth:
      for dd in o.depth .. prevDepth:
        let j = if dd < lastAtPrev.len: lastAtPrev[dd] else: -1
        if j < 0 or entries[j].depth != dd: continue
        var inside = true                         # (nothing at its depth or above since)
        for q in j + 1 ..< i:
          if entries[q].depth <= dd and not entries[q].comment: inside = false
        if inside and entries[j].complexKind > 0 and (i - j > 1 or entries[j].lineCount > 1):
          blank = true
          break
    if blank and res.len > 0 and res[^1].len > 0:
      # (nim.format.maxBlankLines: the empty lines written there, up to that many)
      let n = if FmtBlank > 1 and o.blank: clamp(o.toks[0].blanks, 1, FmtBlank) else: 1
      for _ in 1 .. n: res.add ""
      gap[i] = true
    firstLine[i] = res.len
    var rendered: seq[string]
    # a statement holding a long string: as nph lays it out, when it is one fNphLayout knows
    if o.verbatim and not o.keep and FmtArgs == fwFit and FmtColl == fwFit and FmtParams == fwFit:
      # (not statements in parentheses a line apart: their line breaks are the code's)
      var parenStmts = false
      var dd = 0
      for t in o.toks:
        if t.kind in {fkOpen, fkPragOpen}: inc dd
        elif t.kind in {fkClose, fkPragClose}: dec dd
        elif dd > 0 and t.kind == fkKw and t.text in ["let", "var", "const"]: parenStmts = true
      if not parenStmts: rendered = fNphLayout(o.toks, o.depth, o.exprLine, o.declLike)
      # (a call whose arguments hold a lambda with its body, or a block: one argument a line, like nph)
      if rendered.len == 0: rendered = fVerbatimCall(o, text)
    if o.verbatim and rendered.len == 0:
      # holds a long string or block comment: kept as written, only moved to its new indentation
      let delta = o.depth * 2 - o.toks[0].col
      var s = spaces(o.depth * 2)
      for k, t in o.toks:
        if k > 0:
          let p = o.toks[k - 1]
          if t.nl:
            rendered.add s
            s = spaces(max(0, t.col + delta))
          else:
            # (where p ends in the text: an identifier in backticks may be spaced otherwise now — fAccQuoted)
            let pend = if p.kind == fkIdent and p.text.len > 0 and p.text[0] == '`': text.find('`', p.pos + 1) + 1
                       else: p.pos + p.text.len
            s.add text[pend ..< t.pos]
        s.add t.text
      rendered.add s
      var flat: seq[string]
      for r in rendered:
        for x in r.split('\n'): flat.add x
      rendered = flat
    elif not o.verbatim:
      rendered = fRenderLine(o, @[])
    entries[i].lineCount = rendered.len
    # (a long string's lines keep their trailing spaces: they are part of the string)
    for k in 0 ..< rendered.len:
      template r: untyped = rendered[k]
      if r.len == 0 or r[^1] notin Whitespace or (o.verbatim and k < rendered.high):
        res.add move(rendered[k])          # (nothing to strip: the line itself)
        continue
      var line = r.strip(leading = false)
      if line.len < r.len:
        # (a comment's own trailing spaces stay, like nph)
        for t in o.toks:
          if t.kind == fkComment and t.text.len > 0 and t.text[^1] in {' ', '\t'} and r.endsWith(t.text): line = r
      res.add line
    prevDepth = o.depth
  if FmtAlign: fAlignRuns(entries, res, firstLine, parentOf, gap)
  if FmtScript: fScriptAlign(entries, res, firstLine, gap)
  while res.len > 0 and res[^1].len == 0: res.setLen(res.len - 1)
  var total = 1
  for r in res: total += r.len + 1
  result = newStringOfCap(total)
  for k in 0 ..< res.len:
    if k > 0: result.add '\n'
    result.add res[k]
  result.add '\n'
  if result == text or fNoCheck: return          # nothing changed: nothing to check
  # the check: same tokens, same block structure — or nothing changes
  var ok2 = true
  let toks2 = fLex(result, ok2)
  var map = newSeq[int32](toks2.len)
  for m in map.mitems: m = -1
  if not ok2 or not fSameTokensMap(normToks, toks2, map):
    err = "the built-in formatter would change the code here, so nothing was changed (please report this file)"
    return text
  if not fBreaksOk(normToks, normNl, normStart, toks2, map):
    err = "the built-in formatter would add or remove a line break that changes how Nim reads the code, so " &
          "nothing was changed (please report this file)"
    return text
  var lines2 = fGroupLines(toks2)
  fDepths(lines2)
  if fStructureOf(lines) != fStructureOf(lines2):
    err = "the built-in formatter would change the block structure, so nothing was changed (please report this file)"
    return text

# ── formatting only what changed: a file cut into its top-level statements where an empty line comes before one,
#    each piece formatted on its own and kept (the same text, the same settings: the same result), so formatting
#    a big file again costs only the statements that changed. Cut only where the whole-file formatter writes
#    exactly the empty lines that were there: in front of a statement at column 0, outside brackets, that does
#    not continue the line before it nor is a branch (else, of …) ──

var
  fChunkMemo: Table[string, string]    # settings & "\0" & a piece's text → the piece formatted
  fChunkMemoBytes = 0
  fChunkUsed: HashSet[string]          # (the pieces of the last file formatted: kept when the memo is trimmed)
const FChunkMemoMax = 24 * 1048576

proc fSettingsKey(): string =
  $FmtWidth & "," & $FmtMax & "," & $FmtParams & "," & $FmtArgs & "," & $FmtColl & "," & $FmtBlank & "," &
    $FmtImports & "," & $FmtAlign & "," & $FmtReflow & "," & $FmtReflowPlain & "," & $fNoCheck & "," & $FmtScript

proc fChunkStarts*(toks: seq[FTok]): seq[int] =
  ## the tokens where a piece may start (each first on its line, column 0, after an empty line)
  const contKw = ["and", "or", "xor", "not", "in", "notin", "is", "isnot", "of", "div", "mod", "shl", "shr", "as",
                  "addr", "ptr", "ref", "var", "out", "distinct", "static", "type", "proc", "iterator", "func"]
  var depth = 0
  var lastCode = -1                    # (the last token not a comment)
  for k, t in toks:
    if k > 0 and t.nl and t.col == 0 and depth == 0 and t.blanks > 0 and t.kind != fkComment and
       not (t.kind == fkKw and t.text in ["of", "elif", "else", "except", "finally", "do"]) and lastCode >= 0:
      let p = toks[lastCode]
      if p.kind notin {fkOp, fkComma, fkColon, fkDot, fkSemi, fkOpen, fkPragOpen} and
         not (p.kind == fkKw and p.text in contKw):
        result.add k
    if t.kind in {fkOpen, fkPragOpen}: inc depth
    elif t.kind in {fkClose, fkPragClose}: depth = max(0, depth - 1)
    if t.kind != fkComment: lastCode = k

proc fFormatPieces*(text: string, err: var string, fresh: var seq[(string, string)]): string =
  ## fFormat's result, made piece by piece and remembered (fresh: the pieces formatted this time, for a second
  ## check). Settings that look across statements (imports sorted, lining up) format the whole file
  if FmtImports > 0 or FmtAlign or FmtScript or text.len < 4096:
    result = fFormat(text, err)
    if err.len == 0 and result != text: fresh.add (text, result)
    return
  var ok = true
  let toks = fLex(text, ok)
  if not ok:
    err = "cannot read this file (an unclosed string or comment?)"
    return text
  let starts = fChunkStarts(toks)
  if starts.len == 0:
    result = fFormat(text, err)
    if err.len == 0 and result != text: fresh.add (text, result)
    return
  let sk = fSettingsKey() & "\0"
  var used: HashSet[string]
  var outp = newStringOfCap(text.len + text.len div 8)
  var at = 0
  for n in 0 .. starts.len:
    let stop = if n < starts.len: toks[starts[n]].pos else: text.len
    let piece = text[at ..< stop]
    let key = sk & piece
    var r = fChunkMemo.getOrDefault(key)
    if r.len == 0:
      var e = ""
      r = fFormat(piece, e)
      if e.len > 0:
        # (a piece the formatter is not sure of: the whole file, as it would say it)
        fChunkUsed = used
        return fFormat(text, err)
      if r != piece: fresh.add (piece, r)
      if fChunkMemoBytes > FChunkMemoMax:
        var keep: Table[string, string]
        var bytes = 0
        for k2, v in fChunkMemo:
          if k2 in used or k2 in fChunkUsed:
            keep[k2] = v
            bytes += k2.len + v.len
        fChunkMemo = keep
        fChunkMemoBytes = bytes
      fChunkMemo[key] = r
      fChunkMemoBytes += key.len + r.len
    used.incl key
    if n > 0:
      let bl = toks[starts[n - 1]].blanks
      let gaps = if FmtBlank > 1: clamp(bl, 1, FmtBlank) else: 1
      for _ in 1 .. gaps: outp.add '\n'
    outp.add r
    at = stop
  fChunkUsed = used
  result = outp

proc fForgetPieces*(fresh: seq[(string, string)]) =
  ## pieces a second check refused: not remembered
  let sk = fSettingsKey() & "\0"
  for (p, _) in fresh:
    let key = sk & p
    if key in fChunkMemo:
      fChunkMemoBytes -= key.len + fChunkMemo[key].len
      fChunkMemo.del key
