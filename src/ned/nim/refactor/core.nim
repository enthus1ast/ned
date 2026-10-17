# ── Nim refactorings across the project: change a routine's signature, inline it, move it to another module ──
#    The places are the built-in engine's references (Find references); each call is parsed and rewritten.
#    Calls ned cannot rewrite safely are listed to change by hand. The files are left changed, not saved.

type CallSite = object
  ok: bool
  meth: bool                   # x.f(…): the receiver is the first argument
  recvA: int                   # where the receiver starts (same line)
  recv: string
  parens: bool
  oa, ea: Pos                  # the "(" and the ")" of the argument list
  args: seq[(string, string)]  # (name for a named argument or "", the text passed)

proc rfIdentLen(s: string, c: int): int =
  ## the length of the identifier at column c (Nim lets calls spell a name differently: my_proc · myProc)
  var e = c
  while e < s.len and s[e] in IdentChars: inc e
  e - c

proc rfSkipStr(s: string, i: int): int =
  ## the index after the string or char literal starting at `i`
  let q = s[i]
  if q == '"' and i + 2 < s.len and s[i + 1] == '"' and s[i + 2] == '"':
    let e = s.find("\"\"\"", i + 3)
    return (if e < 0: s.len else: e + 3)
  var k = i + 1
  while k < s.len:
    if s[k] == '\\': k += 2
    elif s[k] == q: return k + 1
    else: inc k
  s.len

proc rfMatchClose(lines: seq[string], l, c: int): Pos =
  ## the bracket closing the one at (l, c), across lines (-1: none within 80 lines)
  var depth = 0
  var line = l
  var i = c
  while line < lines.len and line < l + 80:
    let s = lines[line]
    while i < s.len:
      let ch = s[i]
      if ch == '#': break
      if ch == '"' or (ch == '\'' and i + 2 < s.len and (s[i + 2] == '\'' or s[i + 1] == '\\')):
        i = rfSkipStr(s, i)
        continue
      if ch in {'(', '[', '{'}: inc depth
      elif ch in {')', ']', '}'}:
        dec depth
        if depth == 0: return Pos(line: line, col: i)
      inc i
    inc line
    i = 0
  Pos(line: -1)

proc rfText(lines: seq[string], a, e: Pos): string =
  ## the text strictly between a and e
  if a.line == e.line: return lines[a.line][a.col + 1 ..< e.col]
  result = lines[a.line][a.col + 1 .. ^1]
  for l in a.line + 1 ..< e.line: result.add "\n" & lines[l]
  result.add "\n" & lines[e.line][0 ..< e.col]

proc rfSplitArgs(s: string): seq[string] =
  ## top-level comma-separated parts
  var depth = 0
  var cur = ""
  var i = 0
  while i < s.len:
    let ch = s[i]
    if ch == '"' or (ch == '\'' and i + 2 < s.len and (s[i + 2] == '\'' or s[i + 1] == '\\')):
      let e = rfSkipStr(s, i)
      cur.add s[i ..< e]
      i = e
      continue
    if ch in {'(', '[', '{'}: inc depth
    elif ch in {')', ']', '}'}: dec depth
    if ch == ',' and depth == 0:
      result.add cur.strip
      cur = ""
    else: cur.add ch
    inc i
  if cur.strip.len > 0 or result.len > 0: result.add cur.strip

proc rfRecvStart(s: string, dot: int): int =
  ## where the receiver before the `.` at `dot` starts: a.b, f(x).y, xs[0].z, "lit".w
  var i = dot - 1
  while i >= 0:
    let ch = s[i]
    if ch in IdentChars:
      while i >= 0 and s[i] in IdentChars: dec i
    elif ch in {')', ']'}:
      let open = if ch == ')': '(' else: '['
      var depth = 0
      while i >= 0:
        if s[i] == ch: inc depth
        elif s[i] == open:
          dec depth
          if depth == 0: break
        dec i
      dec i
      while i >= 0 and s[i] in IdentChars: dec i     # the callee of f(x)
    elif ch == '"':
      dec i
      while i >= 0 and s[i] != '"': dec i
      dec i
    else: break
    if i >= 0 and s[i] == '.' and i > 0 and s[i - 1] != '.': dec i
    else: break
  i + 1

proc parseCallSite(lines: seq[string], l, c, n: int): CallSite =
  ## the call whose routine name is at (l, c), n characters long
  let s = lines[l]
  var e = c + n
  if e < s.len and s[e] == '[':
    let close = rfMatchClose(lines, l, e)
    if close.line != l: return
    e = close.col + 1
  if c > 0 and s[c - 1] == '.':
    result.meth = true
    result.recvA = rfRecvStart(s, c - 1)
    result.recv = s[result.recvA ..< c - 1]
    if result.recv.len == 0: return
  if e + 1 < s.len and s[e] == ' ' and not result.meth:
    # `f x` (command syntax) passes x: ned does not rewrite those
    var k = e
    while k < s.len and s[k] == ' ': inc k
    if k < s.len and (s[k] in IdentStartChars + Digits + {'"', '@', '(', '[', '\''}):
      var w = k
      while w < s.len and s[w] in IdentChars: inc w
      if s[k ..< w] notin ["and", "or", "not", "xor", "shl", "shr", "div", "mod", "in", "notin", "is", "isnot",
                           "of", "as", "else", "elif", "do", "then"]:
        return
  if e < s.len and s[e] == '(':
    let close = rfMatchClose(lines, l, e)
    if close.line < 0: return
    result.parens = true
    result.oa = Pos(line: l, col: e)
    result.ea = close
    for a in rfSplitArgs(rfText(lines, result.oa, close)):
      if a.len == 0: continue
      var k = 0
      while k < a.len and a[k] in IdentChars: inc k
      var j = k
      while j < a.len and a[j] == ' ': inc j
      if k > 0 and a[0] in IdentStartChars and j < a.len and a[j] == '=' and (j + 1 >= a.len or a[j + 1] != '='):
        result.args.add (a[0 ..< k], a[j + 1 .. ^1].strip)
      else: result.args.add ("", a)
  result.ok = true

proc rfMapArgs(cs: CallSite, params: seq[NxParam]): (bool, seq[string]) =
  ## the text each parameter gets at this call ("" = none: its default)
  var vals = newSeq[string](params.len)
  var have = newSeq[bool](params.len)
  var pi = 0
  if cs.meth:
    if params.len == 0: return (false, vals)
    vals[0] = cs.recv
    have[0] = true
    pi = 1
  for (nm, v) in cs.args:
    if nm.len > 0:
      var found = -1
      for i, p in params:
        if nxNorm(p.name) == nxNorm(nm): found = i
      if found < 0: return (false, vals)
      vals[found] = v
      have[found] = true
    else:
      while pi < params.len and have[pi]: inc pi
      if pi >= params.len: return (false, vals)
      vals[pi] = v
      have[pi] = true
      inc pi
  (true, vals)

proc rfDeclOf(b: Buffer): (NxRef, bool) =
  ## the routine the cursor names: its declaration (or the one a call at the cursor goes to)
  let f = nxFileFor(b)
  if f == nil: return
  let p = b.primary.head
  let (a0, e0) = b.wordRangeAt(p)
  if a0.col >= e0.col: return
  let at = nxSymAt(f, p.line, a0.col)
  if at >= 0:
    if f.syms[at].kind in NxRoutineKinds + {nxType, nxConst}: return (NxRef(file: f, idx: int32(at)), true)
    return
  let (rs, _, mp) = nxTargets(f, b.lines, p.line, a0.col)
  if mp.len > 0: return
  for r in rs:
    if r.sym.kind in NxRoutineKinds: return (r, true)

type RfEdit = tuple[path: string, a, e: Pos, text: string]

proc rfApply(edits: seq[RfEdit]): int =
  ## the edits, file by file (bottom up, one undo step each); how many files changed
  var byFile: OrderedTable[string, seq[RfEdit]]
  for x in edits: byFile.mgetOrPut(x.path, @[]).add x
  for path, es0 in byFile:
    let b = loadBuffer(path)
    if b == nil or not b.canEdit(): continue
    var es = es0
    es.sort(proc(x, y: RfEdit): int = cmp((y.a.line, y.a.col, y.e.line, y.e.col), (x.a.line, x.a.col, x.e.line, x.e.col)))
    b.beginEdit()
    var last: RfEdit = ("", Pos(line: -1, col: -1), Pos(line: -1, col: -1), "")
    for x in es:
      if x == last: continue                   # the same place found twice
      last = x
      discard b.replaceText(b.clampPos(x.a), b.clampPos(x.e), x.text)
    b.endEdit()
    b.normalize()
    inc result
  needRender = true

proc rfByHand(title: string, places: seq[(string, int, int, string)]) =
  ## calls ned left alone: a list to go to each
  var items: seq[(string, string, Action)]
  for (path, l, c, why) in places:
    items.add act(relPath(path) & ":" & $(l + 1), why, gotoAct(path, l, c))
  openActions(title, items)

proc rfLinesOf(path: string): seq[string] =
  let bi = bufIndexByPath(path)
  if bi >= 0: return bufs[bi].lines
  try: readFile(path).splitLines except CatchableError: @[]

proc rfRefs(d: NxRef): (bool, seq[(string, int, int)]) =
  ## every place naming the declaration (its own name included)
  let b = loadBuffer(d.file.path)
  if b == nil: return
  var hits: seq[(string, int, int)]
  var decl = ""
  if not engineReferences(b, Pos(line: d.sym.line, col: d.sym.col), hits, decl): return
  (not nxRefsCut, hits)

proc rfIsLabel(s: string, a, e: int): bool =
  ## `name` in f(name = v) or P(name: v): a label, not a use of the name
  var k = e
  while k < s.len and s[k] == ' ': inc k
  if k >= s.len or s[k] notin {':', '='} or (k + 1 < s.len and s[k + 1] in {'=', ':'}): return false
  var j = a - 1
  while j >= 0 and s[j] == ' ': dec j
  j >= 0 and s[j] in {'(', ','}

proc rfBodyStart(lines: seq[string], s: NxSym): Pos =
  ## just after the "=" that ends the routine's header (line -1: it has no body here — a forward declaration)
  result = Pos(line: -1, col: 0)
  var l = s.line
  var i = s.col + s.name.len
  var depth = 0
  while l <= min(max(s.endLine, s.line + 12), lines.high):
    let h = lines[l]
    while i < h.len:
      let ch = h[i]
      if ch == '"' or (ch == '\'' and i + 2 < h.len and (h[i + 2] == '\'' or h[i + 1] == '\\')):
        i = rfSkipStr(h, i)
        continue
      if ch == '#': break
      if ch in {'(', '[', '{'}: inc depth
      elif ch in {')', ']', '}'}: dec depth
      elif ch == '=' and depth == 0 and (i + 1 >= h.len or h[i + 1] != '=') and i > 0 and h[i - 1] notin {'=', '<', '>', '!'}:
        return Pos(line: l, col: i + 1)
      inc i
    inc l
    i = 0

proc rfBodyIdents(path: string, s: NxSym): seq[(int, int, seq[NxRef], seq[NxSym], string)] =
  ## each name the routine's body uses (members after a "." too), resolved: (line, col, declarations, locals,
  ## module)
  let lines = rfLinesOf(path)
  let f = nxLoad(path)
  if f == nil: return
  let b0 = rfBodyStart(lines, s)
  if b0.line < 0: return
  var st: NxLexState
  for l in b0.line .. min(s.endLine, lines.high):
    let line = lines[l]
    for (a, e) in nxIdents(line, st):
      if l == b0.line and a < b0.col: continue
      if rfIsLabel(line, a, e): continue
      let (rs, ls, mp) = nxTargets(f, lines, l, a)
      result.add (l, a, rs, ls, mp)

proc rfParamUses(path: string, s: NxSym, name: string): seq[Pos] =
  ## where the routine's body uses its parameter `name`
  let lines = rfLinesOf(path)
  let nn = nxNorm(name)
  for (l, a, rs, ls, mp) in rfBodyIdents(path, s):
    if ls.len > 0 and ls[0].kind == nxParam and nxNorm(ls[0].name) == nn and
       nxNorm(lines[l][a ..< a + rfIdentLen(lines[l], a)]) == nn:
      result.add Pos(line: l, col: a)
