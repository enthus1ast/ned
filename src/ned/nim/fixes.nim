# ── Nim: quick fixes from the compiler's messages (Alt+Enter on the line) ──
#    Each fix is worked out from the message and the text alone — a list of edits — so it can be listed,
#    applied, or applied to every problem of its kind in the file.

type QEdit = tuple[a, e: Pos, text: string]

proc qApply(b: Buffer, edits: seq[QEdit], what: string) =
  ## apply edits (from the bottom up, so earlier positions stay right) as one undo step
  if edits.len == 0 or not b.canEdit(): return
  var es = edits
  es.sort(proc(x, y: QEdit): int = cmp((y.a.line, y.a.col), (x.a.line, x.a.col)))
  b.beginEdit()
  var lastA = Pos(line: -1, col: -1)
  for x in es:
    if x.a == lastA: continue                   # the same problem reported twice: one edit
    lastA = x.a
    discard b.replaceText(b.clampPos(x.a), b.clampPos(x.e), x.text)
  b.endEdit()
  b.normalize()
  if what.len > 0: info(what)
  needRender = true

proc qAct(b: Buffer, edits: seq[QEdit], what: string): Action =
  let id = b.id
  result = proc() =
    let x = bufById(id)
    if x != nil: qApply(x, edits, what)

func qNumType(t: string): bool =
  t in ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "byte", "Natural",
        "Positive", "cint", "cuint", "clong", "culong", "csize_t", "cshort", "cushort", "clonglong", "culonglong",
        "BiggestInt", "char"]

func qFloatType(t: string): bool =
  t in ["float", "float32", "float64", "cfloat", "cdouble", "BiggestFloat"]

func qNormType(t: string): string =
  ## int literal(5) → int, float64 → float64, var T → T, a quoted type → its text
  result = t.strip.strip(chars = {'\''})
  if result.startsWith("var "): result = result[4 .. ^1].strip
  let p = result.find(" literal(")
  if p > 0: result = result[0 ..< p]
  if result == "float literal": result = "float"

func qSimple(e: string): bool =
  ## an expression that needs no parentheses around it: a name, a call, a literal, a field
  if e.len == 0: return false
  var depth = 0
  var inStr = false
  for c in e:
    if c == '"': inStr = not inStr
    if inStr: continue
    if c in {'(', '['}: inc depth
    elif c in {')', ']'}: dec depth
    elif depth == 0 and c in {' ', '+', '-', '*', '/', '&', '<', '>', '=', '!', '%', '|', '^', '~', '@'}: return false
  true

func qConvert(e, got, want: string): (string, string) =
  ## the expression `e` of type `got` made into a `want`: (new text, the import it needs)
  let g = qNormType(got)
  let w = qNormType(want)
  let pe = if qSimple(e): e else: "(" & e & ")"
  if w == "string":
    if g == "cstring": return ("$" & pe, "")
    return ("$" & pe, "")
  if w == "cstring" and g == "string": return (pe & ".cstring", "")
  if qNumType(w) and w != "char":
    if g == "string":
      return ((if w == "int": "parseInt(" & e & ")" else: w & "(parseInt(" & e & "))"), "std/strutils")
    if qNumType(g) or qFloatType(g) or g == "bool": return (w & "(" & e & ")", "")
    return ("ord(" & e & ")", "")
  if qFloatType(w):
    if g == "string":
      return ((if w in ["float", "float64"]: "parseFloat(" & e & ")" else: w & "(parseFloat(" & e & "))"), "std/strutils")
    if qNumType(g) or qFloatType(g): return (w & "(" & e & ")", "")
  if w == "bool" and g == "string": return ("parseBool(" & e & ")", "std/strutils")
  if w.startsWith("seq[") and g.startsWith("array["): return ("@" & pe, "")
  ("", "")

proc qFindOnLine(s, needle: string, near: int): int =
  ## where `needle` is on the line — the occurrence nearest to column `near`
  result = -1
  var best = high(int)
  var k = s.find(needle)
  while k >= 0:
    if abs(k - near) < best:
      best = abs(k - near)
      result = k
    k = s.find(needle, k + 1)

proc qDeclLine(b: Buffer, name: string, before: int): (int, int) =
  ## the let/var/const that declares `name` above line `before`: (line, column of its keyword or name)
  for l in countdown(min(before, b.lines.high), 0):
    let s = b.lines[l]
    let t = s.strip(trailing = false)
    let ind = s.len - t.len
    for kw in ["let ", "var ", "const "]:
      if t.startsWith(kw):
        let rest = t[kw.len .. ^1]
        var k = 0
        while k < rest.len:
          while k < rest.len and rest[k] in {' ', ',', '('}: inc k
          var e = k
          while e < rest.len and rest[e] in IdentChars: inc e
          if e > k and rest[k ..< e] == name: return (l, ind)
          if e == k: break
          k = e
          if k < rest.len and rest[k] notin {',', ' '}: break
    # a name in a let/var section: the section keyword is the line above at a lower indent
    if t.startsWith(name) and (t.len == name.len or t[name.len] in {' ', ':', '=', ',', '*', '{'}) and ind > 0:
      for k in countdown(l - 1, max(0, l - 200)):
        let u = b.lines[k].strip(trailing = false)
        let ui = b.lines[k].len - u.len
        if ui < ind:
          if u in ["let", "var", "const"]: return (k, ui)
          break
  (-1, -1)

proc qFields(path: string, line: int): seq[string] =
  ## the field names of the object type declared at `line` of `path`
  var ls: seq[string]
  let bi = bufIndexByPath(path)
  if bi >= 0: ls = bufs[bi].lines
  else:
    try: ls = readFile(path).splitLines()
    except CatchableError: return
  if line < 0 or line >= ls.len: return
  let ind0 = ls[line].len - ls[line].strip(trailing = false).len
  for l in line + 1 ..< min(ls.len, line + 300):
    let s = ls[l]
    if s.strip.len == 0: continue
    let ind = s.len - s.strip(trailing = false).len
    if ind <= ind0: break
    let t = s.strip
    if t.startsWith("#") or t.startsWith("case ") or t.startsWith("of ") or t.startsWith("else"): continue
    let c = t.find(':')
    if c <= 0: continue
    for n in t[0 ..< c].split(','):
      let nm = n.strip.strip(chars = {'*'}).split('{')[0].strip
      if nm.validIdentifier and nm notin result: result.add nm

proc qClosest(name: string, cands: seq[string], maxN = 3): seq[string] =
  let low = name.toLowerAscii
  var scored: seq[(int, string)]
  for c in cands:
    if c == name: continue
    let d = textDistance(c.toLowerAscii, low)
    if d <= (if name.len <= 3: 1 else: max(2, min(3, name.len div 3))): scored.add (d, c)   # nmae → name: 2
  scored.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
  for (d, c) in scored:
    if c notin result: result.add c
    if result.len >= maxN: break

func qRoutineAbove(b: Buffer, line: int): int =
  ## the routine whose body has `line`: the line of its header
  let s0 = b.lines[line]
  var ind = s0.len - s0.strip(trailing = false).len
  for l in countdown(line, 0):
    let t = b.lines[l].strip(trailing = false)
    if t.len == 0: continue
    let i = b.lines[l].len - t.len
    if i < ind or l == line:
      for kw in ["proc ", "func ", "method ", "iterator ", "converter ", "template ", "macro "]:
        if t.startsWith(kw) and i < ind: return l
      if i < ind: ind = i
    if i == 0 and l < line: break
  -1

func qProcKeyword(s: string, nameCol: int): int =
  ## the `proc` keyword before the name at nameCol on a header line (-1: none)
  result = -1
  var k = s.find("proc")
  while k >= 0 and k < nameCol:
    if (k == 0 or not (s[k - 1] in IdentChars)) and (k + 4 >= s.len or s[k + 4] notin IdentChars): result = k
    k = s.find("proc", k + 1)

func qTopStmt(b: Buffer, line: int): int =
  ## the first line of the top-level statement or declaration that has `line`
  result = line
  while result > 0:
    let s = b.lines[result]
    if s.len > 0 and s[0] notin {' ', '\t', '#'}: break
    dec result

func qArgType(e: string): string =
  let t = e.strip
  if t.len == 0: return "auto"
  if t[0] == '"': return "string"
  if t[0] == '\'': return "char"
  if t in ["true", "false"]: return "bool"
  if t[0] in Digits or (t[0] == '-' and t.len > 1 and t[1] in Digits):
    return (if '.' in t or 'e' in t.toLowerAscii: "float" else: "int")
  if t.startsWith("@["): return "seq[auto]"
  "auto"

proc qExportAct(path: string, line, col: int, name: string): Action =
  result = proc() =
    let x = loadBuffer(path)
    if x == nil: return
    qApply(x, @[(Pos(line: line, col: col), Pos(line: line, col: col), "*")],
           "Exported " & name & " from " & extractFilename(path) & " — Ctrl+S there to save")

proc qDeprecated(b: Buffer, d: Diag): (int, string, string) =
  ## a deprecated name and the one its message says to use: (column on the line or -1, old, new)
  ##   "use greet instead; old is deprecated" · "'old' is deprecated: use greet" · "use `greet`"
  result = (-1, "", "")
  let low = d.msg.splitLines()[0]
  var repl = ""
  var k = low.find("use `")
  if k >= 0:
    let e = low.find('`', k + 5)
    if e > k: repl = low[k + 5 ..< e]
  if repl.len == 0:
    k = low.find("use ")
    if k >= 0:
      var e = k + 4
      while e < low.len and (low[e] in IdentChars or low[e] == '.'): inc e
      repl = low[k + 4 ..< e]
  var old = ""
  let isd = low.find(" is deprecated")
  if isd > 0:
    var a = isd - 1
    if low[a] == '\'': dec a
    let e = a + 1
    while a >= 0 and low[a] in IdentChars: dec a
    old = low[a + 1 ..< e].strip(chars = {'\''})
  let simpleRepl = repl.split('.')[^1]
  if repl.len > 0 and simpleRepl.validIdentifier and old.validIdentifier and old != simpleRepl and
     d.line >= 0 and d.line < b.lines.len:
    let at = qFindOnLine(b.lines[d.line], old, d.col)
    if at >= 0: result = (at, old, simpleRepl)

proc qBreakEdits(b: Buffer, line: int): (string, seq[QEdit]) =
  ## a `break` that leaves a block (Nim 2.2 warns, Nim 3 only leaves loops): break that block by its name — the
  ## block named `done` when it has no name. (title, edits); no edits when the break is inside a loop first
  if line < 0 or line >= b.lines.len: return
  let s = b.lines[line]
  let t = s.strip(trailing = false)
  let ind = s.len - t.len
  if not (t == "break" or t.startsWith("break ") or t.startsWith("break#")): return
  var u = line - 1
  while u >= 0:
    let ut = b.lines[u].strip(trailing = false)
    let ui = b.lines[u].len - ut.len
    if ut.len > 0 and ui < ind:
      if ut.startsWith("for ") or ut.startsWith("while "): return
      for kw in ["proc ", "func ", "iterator ", "method ", "template ", "macro "]:
        if ut.startsWith(kw): return
      if ut.startsWith("block"):
        let rest = ut[5 .. ^1]
        let colon = rest.find(':')
        let lbl = if colon >= 0: rest[0 ..< colon].strip else: ""
        if lbl.len > 0 and lbl.allCharsInSet(IdentChars):
          return ("Make it `break " & lbl & "`", @[(Pos(line: line, col: ind + 5), Pos(line: line, col: ind + 5), " " & lbl)])
        if colon >= 0 and lbl.len == 0:
          return ("Name the block `done` and break it", @[(Pos(line: u, col: ui + 5), Pos(line: u, col: ui + 5), " done"),
                  (Pos(line: line, col: ind + 5), Pos(line: line, col: ind + 5), " done")])
        return
    dec u

proc nimDiagFixes(b: Buffer, d: Diag): seq[(string, string, Action)] =
  ## the fixes for one Nim compiler message (empty when none fits)
  if d.line < 0 or d.line >= b.lines.len: return
  # ── a break that leaves a block: by the block's name (Nim 2.2 warns, Nim 3 leaves only loops)
  if "unnamed break in a block" in d.msg or "[UnnamedBreak]" in d.msg:
    let (title, es) = qBreakEdits(b, d.line)
    if es.len > 0: result.add act(title, "a named block and its break", qAct(b, es, ""))
    return
  # ── Nim 3 (ned's nim3 rule): the problem carries its edits
  if d.rule == "nim3" and d.code != nil and d.code.kind == JObject and d.code.hasKey("edits"):
    var es: seq[QEdit]
    for e in d.code["edits"]:
      es.add (Pos(line: e[0].getInt, col: e[1].getInt), Pos(line: e[2].getInt, col: e[3].getInt), e[4].getStr)
    result.add act(d.code{"nim3fix"}.getStr, "for Nim 3", qAct(b, es, ""))
    return
  let m = d.msg
  let first = m.splitLines()[0]
  let s = b.lines[d.line]
  let indent = s.len - s.strip(trailing = false).len
  # ── ambiguous identifier: 'x' -- use one of the following: a.x … · ambiguous call; both a.f() and b.f()
  let amb = m.find("ambiguous identifier: '")
  if amb >= 0 or first.startsWith("ambiguous call"):
    var quals: seq[string]
    var name = ""
    if amb >= 0:
      # also inside a type mismatch's list:  ambiguous identifier: 'x' -- use one of the following: ⏎ a.x: int
      name = quotedName(m[amb .. ^1])
      for l in m[amb .. ^1].splitLines()[1 .. ^1]:
        let t = l.strip
        if t.startsWith("ambiguous identifier"): continue
        let c = t.find(':')
        let q = if c > 0: t[0 ..< c].strip else: ""
        if q.len > 0 and '.' in q and q.split('.')[^1] == name and q notin quals: quals.add q
        if c <= 0: break
    else:
      # both other.helper() [proc declared in …] and other2.helper() [proc declared in …] match
      var k = first.find("both ")
      for marker in ["both ", " and "]:
        k = first.find(marker)
        if k < 0: continue
        var e = k + marker.len
        while e < first.len and first[e] notin {'(', ' ', '['}: inc e
        let q = first[k + marker.len ..< e]
        if '.' in q and q notin quals: quals.add q
      if quals.len > 0: name = quals[0].split('.')[^1]
    let at = if name.len > 0: qFindOnLine(s, name, d.col) else: -1
    if at >= 0:
      for q in quals:
        result.add act("Use " & q, "say which module's",
                       qAct(b, @[(Pos(line: d.line, col: at), Pos(line: d.line, col: at + name.len), q)], ""))
    return
  # ── expression '…' is of type 'T' and has to be used (or discarded)
  if "has to be used (or discarded)" in first or "has to be discarded" in first:
    let ex = quotedName(first)
    var at = -1
    if ex.len > 0:
      let head = ex[0 ..< min(ex.len, 12)]
      at = qFindOnLine(s, head, d.col)
    if at < 0: at = indent
    result.add act("Discard the result", "discard " & truncTo(ex, 40),
                   qAct(b, @[(Pos(line: d.line, col: at), Pos(line: d.line, col: at), "discard ")], ""))
    return
  # ── 'jsony' is imported but app.nimble does not require it (ned's own check): the requirement added
  if "is imported but " in first and " does not require it" in first:
    let pkg = quotedName(first)
    let nb = findNimbleFile(parentDir(b.path))
    if pkg.len > 0 and nb.len > 0:
      result.add act("Add requires \"" & pkg & "\" to " & extractFilename(nb), "the version this project builds with",
                     proc() =
        if pcAddRequire(nb, pkg): info("Added to " & extractFilename(nb) & " — Ctrl+S there to save"))
    return
  # ── 'x' is never changed: it can be a let (ned's own hint)
  if "is never changed: it can be a let" in first:
    let nm = quotedName(first)
    let t = s.strip(trailing = false)
    let ind = s.len - t.len
    # (only `var x = …` alone on its line: a section's member would need moving out of it)
    let comma = t.find(',')
    if nm.len > 0 and t.startsWith("var ") and t[4 .. ^1].strip.startsWith(nm) and
       (comma < 0 or comma > t.find('=')):
      result.add act("Make " & nm & " a let", "var → let: nothing changes it",
                     qAct(b, @[(Pos(line: d.line, col: ind), Pos(line: d.line, col: ind + 3), "let")], ""))
    return
  # ── 'x' has no side effects: it can be a func (ned's own hint)
  if "has no side effects: it can be a func" in first:
    let nm = quotedName(first)
    let k = qProcKeyword(s, d.col)
    if nm.len > 0 and k >= 0:
      result.add act("Make " & nm & " a func", "proc → func: it has no side effects",
                     qAct(b, @[(Pos(line: d.line, col: k), Pos(line: d.line, col: k + 4), "func")], ""))
    return
  # ── 'x' cannot be assigned to · expression 'x' is immutable, not 'var'
  var immut = ""
  if "cannot be assigned to" in first: immut = quotedName(first)
  else:
    let k = m.find("expression '")
    if k >= 0 and "is immutable, not 'var'" in m: immut = quotedName(m[k .. ^1])
  if immut.len > 0 and immut.validIdentifier:
    let (dl, dc) = qDeclLine(b, immut, d.line)
    if dl >= 0:
      let t = b.lines[dl]
      let k = t.find("let", dc)
      if k >= 0 and k == dc:
        result.add act("Make " & immut & " a var", "line " & $(dl + 1) & ": let → var",
                       qAct(b, @[(Pos(line: dl, col: k), Pos(line: dl, col: k + 3), "var")], ""))
    else:
      # a parameter: a copy that can change, at the top of the routine's body
      let r = qRoutineAbove(b, d.line)
      if r >= 0 and r + 1 < b.lines.len:
        var bodyLine = r + 1
        while bodyLine < b.lines.len and b.lines[bodyLine].strip.len == 0: inc bodyLine
        if bodyLine < b.lines.len:
          let bi = b.lines[bodyLine].len - b.lines[bodyLine].strip(trailing = false).len
          result.add act("Copy " & immut & " into a var", "var " & immut & " = " & immut & " at the top of the proc",
                         qAct(b, @[(Pos(line: bodyLine, col: 0), Pos(line: bodyLine, col: 0),
                                    spaces(bi) & "var " & immut & " = " & immut & "\n")], ""))
    if result.len > 0: return
  # ── type mismatch: got 'G' for 'E' but expected 'W'
  if first.startsWith("type mismatch: got"):
    let g1 = first.find('\'')
    let g2 = first.find('\'', g1 + 1)
    let f1 = first.find(" for '", g2)
    let f2 = if f1 >= 0: first.rfind("' but expected '") else: -1
    let w1 = if f2 >= 0: f2 + "' but expected '".len else: -1
    let w2 = if w1 >= 0: first.find('\'', w1) else: -1
    if g1 >= 0 and g2 > g1 and f1 > 0 and f2 > f1 and w2 > w1:
      let got = first[g1 + 1 ..< g2]
      let ex = first[f1 + 6 ..< f2]
      let want = first[w1 ..< w2]
      let (nt, imp) = qConvert(ex, got, want)
      let at = qFindOnLine(s, ex, d.col)
      if nt.len > 0 and at >= 0:
        let id = b.id
        let edits = @[(Pos(line: d.line, col: at), Pos(line: d.line, col: at + ex.len), nt)]
        result.add act("Convert: " & truncTo(nt, 40), qNormType(got) & " → " & qNormType(want) &
                       (if imp.len > 0: " (imports " & imp & ")" else: ""), proc() =
          let x = bufById(id)
          if x == nil: return
          qApply(x, edits, "")
          if imp.len > 0: x.addImport(imp))
    return
  # ── type mismatch in a call: the argument that does not fit, converted
  if first.startsWith("type mismatch") and "Expression:" in m:
    let mm = parseMismatch(m)
    if mm.best >= 0:
      let pos = mm.cands[mm.best][0]
      if pos >= 1 and pos <= mm.args.len:
        let (ex, ty, _) = mm.args[pos - 1]
        let wantFull = mismatchWant(mm, pos - 1)
        let wc = wantFull.find(": ")
        let want = if wc >= 0: wantFull[wc + 2 .. ^1] else: ""
        if want.len > 0 and ty.len > 0:
          let (nt, imp) = qConvert(ex, ty, want)
          var at = qFindOnLine(s, ex, d.col)
          if nt.len > 0 and at >= 0:
            let id = b.id
            let edits = @[(Pos(line: d.line, col: at), Pos(line: d.line, col: at + ex.len), nt)]
            result.add act("Convert argument " & $pos & ": " & truncTo(nt, 36), qNormType(ty) & " → " &
                           qNormType(want) & (if imp.len > 0: " (imports " & imp & ")" else: ""), proc() =
              let x = bufById(id)
              if x == nil: return
              qApply(x, edits, "")
              if imp.len > 0: x.addImport(imp))
    return
  # ── undeclared field (x.lenght): the members the engine knows for x, the closest first
  if first.startsWith("undeclared field:") and b.lang.mode == lmNim and nimEngineOn(b):
    let name = quotedName(first)
    if name.len == 0: return
    var at = -1
    var k = s.find("." & name, max(0, d.col - name.len - 2))
    if k < 0: k = s.find("." & name)
    if k >= 0: at = k + 1
    if at < 0: return
    let f = nxFileFor(b)
    if f == nil: return
    var labels: seq[string]
    try:
      for it in nxComplete(f, b.lines, d.line, at).items:
        if it.label notin labels: labels.add it.label
    except CatchableError: return
    for c in qClosest(name, labels, 3):
      result.add act("Change to " & c, "did you mean " & c & "?",
                     qAct(b, @[(Pos(line: d.line, col: at), Pos(line: d.line, col: at + name.len), c)], ""))
    return
  # ── undeclared identifier: the compiler's spelling candidates, and names close to it here
  if first.startsWith("undeclared identifier:") or first.startsWith("attempting to call undeclared routine:"):
    let name = quotedName(first)
    if name.len == 0: return
    var cands: seq[string]
    var inCands = false
    for l in m.splitLines:
      if l.startsWith("candidates (edit distance"):
        inCands = true
        continue
      if inCands:
        let c = quotedName(l)
        if c.len > 0 and c.validIdentifier and c notin cands: cands.add c
    var here: seq[string]
    var seenHere: HashSet[string]
    var stH: NxLexState
    for l in b.lines:
      # (names in the code, not words in its strings and comments: "tea" is no name)
      for (k, e) in nxIdents(l, stH):
        let w = l[k ..< e]
        if w.len >= 3 and w notin seenHere and w notin NxKeywords:
          seenHere.incl w
          here.add w
      if here.len > 20000: break
    var sugg = qClosest(name, here, 3)
    for c in cands:
      if c notin sugg and textDistance(c.toLowerAscii, name.toLowerAscii) <=
         (if name.len <= 3: 1 else: max(2, min(3, name.len div 3))): sugg.add c
    let at = qFindOnLine(s, name, d.col)
    if at >= 0:
      for c in sugg[0 ..< min(4, sugg.len)]:
        result.add act("Change to " & c, "did you mean " & c & "?",
                       qAct(b, @[(Pos(line: d.line, col: at), Pos(line: d.line, col: at + name.len), c)], ""))
    # a name a project module declares but does not export
    if b.path.len > 0:
      for l in b.lines:
        let t = l.strip
        if not (t.startsWith("import ") or t.startsWith("from ")): continue
        var body = t[(if t.startsWith("import "): 7 else: 5) .. ^1]
        let ik = body.find(" import ")
        if ik >= 0: body = body[0 ..< ik]
        var mods: seq[string]
        for part in body.replace("[", ",").replace("]", ",").split(','):
          let p = part.strip
          if p.len > 0 and not p.startsWith("std/") and p != "std": mods.add p
        # a/[b, c] → a/b, a/c
        let slash = body.find("/[")
        if slash > 0:
          mods = @[]
          let pre = body[0 ..< slash].strip
          for part in body[slash + 2 .. ^1].strip(chars = {']', ' '}).split(','):
            if part.strip.len > 0: mods.add pre & "/" & part.strip
        for md in mods:
          let mp = parentDir(b.path) / md.replace(".", "/") & ".nim"
          let mp2 = parentDir(b.path) / md & ".nim"
          let path = if fileExists(mp2): mp2 elif fileExists(mp): mp else: ""
          if path.len == 0: continue
          var ls: seq[string]
          try: ls = readFile(path).splitLines()
          except CatchableError: continue
          for li, x in ls:
            if x.len == 0 or x[0] in {' ', '\t'}: continue
            for kw in ["proc ", "func ", "template ", "macro ", "iterator ", "converter ", "method ", "type ",
                       "const ", "let ", "var "]:
              if x.startsWith(kw) and x.continuesWith(name, kw.len):
                let after = kw.len + name.len
                if after < x.len and x[after] notin IdentChars and x[after] != '*':
                  result.add act("Export " & name & " from " & extractFilename(path), "add * to its declaration (line " &
                                 $(li + 1) & ")", qExportAct(path, li, after, name))
    # a call of a routine nobody declared: make one
    if name.validIdentifier and (name & "(") in s:
      let k = s.find(name & "(", max(0, min(d.col, s.len) - name.len - 2))
      let k2 = if k >= 0: k else: s.find(name & "(")
      if k2 >= 0:
        var depth = 0
        var e = k2 + name.len
        var args: seq[string]
        var cur = ""
        var inStr = false
        while e < s.len:
          let c = s[e]
          if c == '"': inStr = not inStr
          if not inStr:
            if c == '(':
              inc depth
              if depth == 1:
                inc e
                continue
            elif c == ')':
              dec depth
              if depth == 0: break
            elif c == ',' and depth == 1:
              args.add cur
              cur = ""
              inc e
              continue
          if depth >= 1: cur.add c
          inc e
        if cur.strip.len > 0: args.add cur
        var ps: seq[string]
        for i, a in args: ps.add $char(ord('a') + min(i, 25)) & ": " & qArgType(a)
        # what it must return: a declared type on the line, a string where text is wanted, else nothing
        var ret = ""
        let t = s.strip
        let decl = t.find(':')
        let eq = t.find('=')
        if (t.startsWith("let ") or t.startsWith("var ") or t.startsWith("const ")) and decl > 0 and eq > decl:
          ret = t[decl + 1 ..< eq].strip
        elif t.startsWith("echo ") or "& " & name in s or "&" & name in s: ret = "string"
        elif not t.startsWith(name & "("): ret = "int"
        let top = qTopStmt(b, d.line)
        let stub = "proc " & name & "(" & ps.join(", ") & ")" & (if ret.len > 0: ": " & ret else: "") &
                   " =\n" & b.indent & "## TODO\n" & b.indent & "discard\n\n"
        result.add act("Create proc " & name & "(" & ps.join(", ") & ")" & (if ret.len > 0: ": " & ret else: ""),
                       "above line " & $(top + 1), qAct(b, @[(Pos(line: top, col: 0), Pos(line: top, col: 0), stub)],
                       "Made proc " & name & " — fill in its body"))
    return
  # ── undeclared field: the type's fields close to it
  if first.startsWith("undeclared field:"):
    let name = quotedName(first)
    let k = m.find("[type declared in ")
    if name.len > 0 and name.validIdentifier and k > 0:
      let inner = m[k + "[type declared in ".len .. ^1]
      let p1 = inner.rfind('(')
      let p2 = inner.find(')', max(0, p1))
      if p1 > 0 and p2 > p1:
        let path = inner[0 ..< p1]
        let nums = inner[p1 + 1 ..< p2].split(',')
        let tl = (try: parseInt(nums[0].strip) - 1 except ValueError: -1)
        let at = qFindOnLine(s, name, d.col)
        if tl >= 0 and at >= 0:
          for f in qClosest(name, qFields(path, tl), 3):
            result.add act("Change to " & f, "a field of the type",
                           qAct(b, @[(Pos(line: d.line, col: at), Pos(line: d.line, col: at + name.len), f)], ""))
    return
  # ── not all cases are covered; missing: {a, b}
  if first.startsWith("not all cases are covered"):
    let o = first.find('{')
    let c = first.rfind('}')
    if o > 0 and c > o:
      var vals: seq[string]
      for v in first[o + 1 ..< c].split(','):
        if v.strip.len > 0: vals.add v.strip
      # the branches' indentation and the line after the last one
      let ci = indent
      var ofInd = -1
      var last = d.line
      var elseAt = -1
      for l in d.line + 1 ..< b.lines.len:
        let u = b.lines[l]
        if u.strip.len == 0:
          continue
        let ui = u.len - u.strip(trailing = false).len
        if ui < ci or (ui == ci and not (u.strip.startsWith("of ") or u.strip.startsWith("else") or
                                          u.strip.startsWith("elif "))):
          break
        if ui == ci or (ofInd >= 0 and ui == ofInd) or (ofInd < 0 and u.strip.startsWith("of ")):
          if ofInd < 0: ofInd = ui
          if u.strip.startsWith("else"):
            elseAt = l
            break
        last = l
      if ofInd < 0: ofInd = ci
      let insertAt = if elseAt >= 0: elseAt else: last + 1
      var text = ""
      for v in vals: text.add spaces(ofInd) & "of " & v & ":\n" & spaces(ofInd) & b.indent & "discard\n"
      let edit = if insertAt < b.lines.len: (Pos(line: insertAt, col: 0), Pos(line: insertAt, col: 0), text)
                 else: (Pos(line: b.lines.high, col: b.lines[^1].len), Pos(line: b.lines.high, col: b.lines[^1].len),
                        "\n" & text.strip(leading = false, chars = {'\n'}))
      result.add act("Add the missing branches", vals.join(", "), qAct(b, @[edit],
                     "Added " & $vals.len & " branch" & (if vals.len > 1: "es" else: "")))
    return
  # ── X can raise an unlisted exception: E
  let ur = first.find("can raise an unlisted exception: ")
  if ur >= 0:
    let exc = first[ur + "can raise an unlisted exception: ".len .. ^1].strip.split({' ', ','})[0]
    let r = qRoutineAbove(b, d.line)
    if r >= 0 and exc.len > 0:
      for l in r .. min(b.lines.high, r + 6):
        let u = b.lines[l]
        let k = u.find("raises:")
        if k < 0: continue
        let o = u.find('[', k)
        let c = if o >= 0: u.find(']', o) else: -1
        if o < 0 or c < 0: break
        let inside = u[o + 1 ..< c].strip
        let nt = if inside.len == 0: exc else: inside & ", " & exc
        result.add act("Add " & exc & " to the raises list", "line " & $(l + 1) & ": raises: [" & nt & "]",
                       qAct(b, @[(Pos(line: l, col: o + 1), Pos(line: l, col: c), nt)], ""))
        break
    # or catch it here
    if exc.len > 0 and s.strip.len > 0:
      let pad = spaces(indent)
      let wrapped = pad & "try:\n" & pad & b.indent & s.strip & "\n" & pad & "except " & exc & ":\n" & pad & b.indent &
                    "discard  # TODO: handle " & exc
      result.add act("Catch " & exc & " here", "try: … except " & exc & ":",
                     qAct(b, @[(Pos(line: d.line, col: 0), Pos(line: d.line, col: s.len), wrapped)], ""))
    return
  # ── warnings: the bare except clause, a deprecated name with a replacement
  if "bare except clause is deprecated" in first or "[BareExcept]" in first:
    let k = s.find("except:")
    if k >= 0:
      result.add act("Catch CatchableError", "except: → except CatchableError:",
                     qAct(b, @[(Pos(line: d.line, col: k), Pos(line: d.line, col: k + 7), "except CatchableError:")], ""))
    return
  if "is deprecated" in first:
    let (at, old, repl) = qDeprecated(b, d)
    if at >= 0:
      result.add act("Use " & repl & " instead of " & old, "as the deprecation says",
                     qAct(b, @[(Pos(line: d.line, col: at), Pos(line: d.line, col: at + old.len), repl)], ""))
    return

proc nimFixKind(d: Diag): string =
  ## problems whose fix is the same everywhere in a file (for "fix all")
  let f = d.msg.splitLines()[0]
  if d.rule == "nim3": (if d.code != nil and d.code.kind == JObject and d.code.hasKey("edits"): "nim3" else: "")
  elif "unnamed break in a block" in f or "[UnnamedBreak]" in f: "unnamedBreak"
  elif "has to be used (or discarded)" in f: "discard"
  elif "bare except clause is deprecated" in f or "[BareExcept]" in f: "bareExcept"
  elif "imported and not used" in f: "unusedImport"
  elif "is deprecated" in f: "deprecated:" & quotedName(f)
  elif "is never changed: it can be a let" in f: "varLet"
  elif "has no side effects: it can be a func" in f: "canBeFunc"
  else: ""

proc nimFixEdits(b: Buffer, kind: string, edits: var seq[QEdit], imports: var seq[string]): int =
  ## the edits that fix every problem of this kind in the file (unused imports: their names), added to the lists;
  ## how many problems they fix
  var n = 0
  for d in diagsFor(b.path):
    let dk = nimFixKind(d)
    # (Nim 3's changes take the breaks that leave a block with them: Nim 3 needs those too)
    if dk != kind and not (kind == "nim3" and dk == "unnamedBreak"): continue
    if kind == "unusedImport":
      let nm = quotedName(d.msg)
      if nm.len > 0 and nm notin imports: imports.add nm
      inc n
      continue
    if dk == "unnamedBreak":
      let es = qBreakEdits(b, d.line)[1]
      if es.len > 0:
        for e in es: edits.add e
        inc n
      continue
    if kind == "nim3":
      for e in d.code["edits"]:
        edits.add (Pos(line: e[0].getInt, col: e[1].getInt), Pos(line: e[2].getInt, col: e[3].getInt), e[4].getStr)
      inc n
      continue
    let fx = nimDiagFixes(b, d)
    if fx.len == 0: continue
    # the fix's edit, worked out again here (the same as its first action would make)
    let s = b.lines[d.line]
    case kind
    of "discard":
      let ex = quotedName(d.msg)
      var at = if ex.len > 0: qFindOnLine(s, ex[0 ..< min(ex.len, 12)], d.col) else: -1
      if at < 0: at = s.len - s.strip(trailing = false).len
      edits.add (Pos(line: d.line, col: at), Pos(line: d.line, col: at), "discard ")
      inc n
    of "bareExcept":
      let k = s.find("except:")
      if k >= 0:
        edits.add (Pos(line: d.line, col: k), Pos(line: d.line, col: k + 7), "except CatchableError:")
        inc n
    of "varLet":
      # (the fix's own test: `var x = …` alone on its line)
      let t = s.strip(trailing = false)
      let ind = s.len - t.len
      let nm = quotedName(d.msg)
      let comma = t.find(',')
      if nm.len > 0 and t.startsWith("var ") and t[4 .. ^1].strip.startsWith(nm) and (comma < 0 or comma > t.find('=')):
        edits.add (Pos(line: d.line, col: ind), Pos(line: d.line, col: ind + 3), "let")
        inc n
    of "canBeFunc":
      let k = qProcKeyword(s, d.col)
      if k >= 0:
        edits.add (Pos(line: d.line, col: k), Pos(line: d.line, col: k + 4), "func")
        inc n
    else:
      if kind.startsWith("deprecated:"):
        let (at, old, repl) = qDeprecated(b, d)
        if at >= 0:
          edits.add (Pos(line: d.line, col: at), Pos(line: d.line, col: at + old.len), repl)
          inc n
  n

proc nimFixAllAct(b: Buffer, n: int, edits: seq[QEdit], imports: seq[string]): Action =
  let id = b.id
  let imps = imports
  var es = edits
  # (one edit per place: two kinds may want the same spot — the first one wins)
  es.sort(proc(x, y: QEdit): int = cmp((x[0].line, x[0].col), (y[0].line, y[0].col)))
  var k = 1
  while k < es.len:
    if es[k][0] < es[k - 1][1] or es[k][0] == es[k - 1][0]: es.delete(k) else: inc k
  result = proc() =
    let x = bufById(id)
    if x == nil: return
    if es.len > 0: qApply(x, es, "")
    for nm in imps: removeImportAct(id, nm)()
    info("Fixed " & $n & " in this file")

proc nimFixAll(b: Buffer, kind: string): (int, Action) =
  ## every problem of this kind in the file fixed at once: (how many, the action)
  var edits: seq[QEdit]
  var imports: seq[string]
  let n = nimFixEdits(b, kind, edits, imports)
  (n, nimFixAllAct(b, n, edits, imports))

proc nimFixAllKinds(b: Buffer): (int, Action) =
  ## every problem in the file whose fix is the same everywhere, of every kind, fixed at once (nedls's "Fix all":
  ## an editor's fix-all on save) — not Nim 3's changes, which are a port to choose
  var kinds: seq[string]
  for d in diagsFor(b.path):
    let k = nimFixKind(d)
    if k.len > 0 and k != "nim3" and k notin kinds: kinds.add k
  var edits: seq[QEdit]
  var imports: seq[string]
  var n = 0
  for k in kinds: n += nimFixEdits(b, k, edits, imports)
  (n, nimFixAllAct(b, n, edits, imports))
