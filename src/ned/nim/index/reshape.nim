# ── bigger refactorings, worked out from the text and the index: a type between `object` and `ref object`, the
#    selected declarations of a module split into a new one, a routine that takes a callback made {.async.}, and a
#    call's syntax (f(x, y) · x.f(y) · f x, y). Each is a plan — edits, and the places left for a person to look
#    at — that the editor previews as a diff and applies, one undo step a file ──

type
  NxEdit* = object
    ## the text of a file from (line, col) to (endLine, endCol), replaced by `text`
    path*: string
    line*, col*, endLine*, endCol*: int
    text*: string
  NxNote* = object
    ## a place a refactoring leaves as it is, but that you should look at, and why
    path*: string
    line*, col*: int
    why*: string
  NxPlan* = object
    ok*: bool
    msg*: string             ## not ok: why nothing can be done; ok: what it does, in a few words
    edits*: seq[NxEdit]
    notes*: seq[NxNote]
    creates*: seq[string]    ## files the plan makes (empty, before the edits fill them)
  NxCallForm* = enum
    ## the three ways of writing a call: f(x, y) · x.f(y) · f x, y
    cfPlain, cfMethod, cfCommand

func nxEditOf(path: string, l, c, el, ec: int, text: string): NxEdit =
  NxEdit(path: path, line: l, col: c, endLine: el, endCol: ec, text: text)

proc nxApplyEdits*(lines: seq[string], edits: seq[NxEdit]): seq[string] =
  ## the lines with the edits (all of one file) made — the last first, so the positions stay right; an edit that
  ## overlaps one made already is left out
  var es = edits
  es.sort(proc(x, y: NxEdit): int = cmp((y.line, y.col, y.endLine, y.endCol), (x.line, x.col, x.endLine, x.endCol)))
  var text = lines.join("\n")
  var starts = newSeq[int](lines.len)
  var o = 0
  for i, l in lines:
    starts[i] = o
    o += l.len + 1
  proc off(l, c: int): int =
    if l >= lines.len or l < 0: return text.len
    starts[l] + clamp(c, 0, lines[l].len)
  var lastStart = high(int)
  var prev = NxEdit(line: -1)
  for x in es:
    if x == prev: continue                     # (the same change found twice)
    let a = off(x.line, x.col)
    let e = max(a, off(x.endLine, x.endCol))
    if e > lastStart: continue
    text = text[0 ..< a] & x.text & text[e .. ^1]
    lastStart = a
    prev = x
  text.split('\n')

func nxIdentEnd(s: string, i: int): int =
  result = i
  while result < s.len and nxIsIdent(s[result]): inc result

func nxSameRef(a, b: NxRef): bool =
  a.file.path == b.file.path and a.sym.line == b.sym.line and a.sym.name == b.sym.name

proc nxReferencesIn*(t: NxRef, files: seq[string]): seq[(string, int, int)] =
  ## every place in `files` naming the declaration `t` (its own name too), each name resolved as Find references
  ## does — without its time limit (a refactoring asks once)
  var t = t
  block:
    # (a forward declaration stands for the routine it announces)
    let tl = nxFileLines(t.file.path)
    if t.sym.kind in NxRoutineKinds and nxIsForward(tl, t.sym):
      let bi = nxBodyOf(t.file, tl, t.sym)
      if bi >= 0: t = NxRef(file: t.file, idx: int32(bi))
  let nw = nxNorm(t.sym.name)
  let low = nw.toLowerAscii
  for path in files:
    let lines = nxFileLines(path)
    if lines.len == 0: continue
    var named = false
    for l in lines:
      if low[0] in l.toLowerAscii and low in l.toLowerAscii.replace("_", ""):
        named = true
        break
    if not named: continue
    let g = nxLoad(path)
    if g == nil: continue
    var st: NxLexState
    for l in 0 ..< lines.len:
      for (s, e) in nxIdents(lines[l], st):
        if nxNorm(lines[l][s ..< e]) != nw: continue
        let d = nxSymAt(g, l, s)
        if d >= 0:
          var r = NxRef(file: g, idx: int32(d))
          if g.syms[d].kind in NxRoutineKinds and nxIsForward(lines, g.syms[d]):
            let bi = nxBodyOf(g, lines, g.syms[d])
            if bi >= 0: r = NxRef(file: g, idx: int32(bi))
          if nxSameRef(t, r): result.add (path, l, s)
          continue
        let (rs, ls, mp) = nxTargets(g, lines, l, s)
        if ls.len > 0 and ls[0].kind == nxField and ls[0].line == l and ls[0].col == s and t.sym.kind == nxField and
           t.file.path == path and t.sym.line == l:
          result.add (path, l, s)        # (a field of the tuple a routine returns, where its type declares it)
          continue
        if ls.len > 0 or mp.len > 0: continue
        for r in rs:
          if nxSameRef(t, r):
            result.add (path, l, s)
            break

proc nxSectionOf(lines: seq[string], l: int): (int, string) =
  ## the line of the block a line is in, and its first word (`var`, `type`, `proc` …): the nearest line above
  ## indented less (-1, "" at the top level)
  let ind = leadWs(lines[l])
  var k = l - 1
  while k >= 0:
    let t = lines[k].strip
    if t.len > 0 and t[0] != '#' and leadWs(lines[k]) < ind:
      var w = 0
      while w < t.len and nxIsIdent(t[w]): inc w
      return (k, t[0 ..< w])
    dec k
  (-1, "")

proc nxTypeAt(f: NxFile, lines: seq[string], line, col: int): (NxRef, bool) =
  ## the type named at the place: its declaration, or the one a use there names
  if line < 0 or line >= lines.len: return
  let (a, e) = nxWordAt(lines[line], col)
  if a >= e: return
  let at = nxSymAt(f, line, a)
  if at >= 0:
    if f.syms[at].kind == nxType: return (NxRef(file: f, idx: int32(at)), true)
    return
  let (rs, _, _) = nxTargets(f, lines, line, a)
  for r in rs:
    if r.sym.kind == nxType: return (r, true)

proc nxRoutineAt(f: NxFile, lines: seq[string], line, col: int): (NxRef, bool) =
  ## the routine named at the place: its declaration, or the one a call there names
  if line < 0 or line >= lines.len: return
  let (a, e) = nxWordAt(lines[line], col)
  if a >= e: return
  let at = nxSymAt(f, line, a)
  if at >= 0:
    if f.syms[at].kind in NxRoutineKinds: return (NxRef(file: f, idx: int32(at)), true)
    return
  let (rs, ls, _) = nxTargets(f, lines, line, a)
  if ls.len > 0: return
  for r in rs:
    if r.sym.kind in NxRoutineKinds: return (r, true)

# ── object ⇄ ref object ──

proc nxObjKeyword(lines: seq[string], s: NxSym): (int, int, int) =
  ## where the declaration writes `ref object` or `object`: (line, column, how many characters `ref ` takes — 0
  ## for a plain object); line -1: neither
  result = (-1, 0, 0)
  if s.line >= lines.len: return
  let t = lines[s.line]
  let eq = nxFindTop(t, '=', min(t.len, s.col + s.name.len))
  if eq < 0: return
  var k = eq + 1
  while k < t.len and t[k] == ' ': inc k
  if t.continuesWith("ref ", k):
    var j = k + 4
    while j < t.len and t[j] == ' ': inc j
    if t.continuesWith("object", j) and nxIdentEnd(t, j) == j + 6: return (s.line, k, j - k)
  elif t.continuesWith("object", k) and nxIdentEnd(t, k) == k + 6: return (s.line, k, 0)

proc nxIsTypeNamed(typ, name: string): bool =
  let b = nxStripMods(typ.strip)
  b.len > 0 and b.find('[') < 0 and nxNorm(b) == nxNorm(name)

proc nxPlanRefObject*(f: NxFile, lines: seq[string], line, col: int, files: seq[string]): NxPlan =
  ## the object type at the place made a `ref object` (or the reverse), and its uses the index finds in `files`:
  ## constructors stay; a `var x: T` that relied on a value gets `= T()`, a routine that fills in `result` first
  ## gets `result = T()`; `new(x)` becomes `x = T()` the other way. Comparisons (`==`), copies that would share one
  ## object, fields that would start as nil and nil checks are listed to look at
  let (t, ok) = nxTypeAt(f, lines, line, col)
  if not ok: return NxPlan(msg: "Put the cursor on the name of an object type (its declaration or a use)")
  let s = t.sym
  let dpath = t.file.path
  if dpath != f.path and dpath notin files:
    return NxPlan(msg: s.name & " is declared in " & dpath & " — outside this project")
  let dl = nxFileLines(dpath)
  let (kl, kc, refLen) = nxObjKeyword(dl, s)
  if kl < 0:
    return NxPlan(msg: s.name & " is `" & s.typ & "` — only an `object` or a `ref object` changes")
  let toRef = refLen == 0
  let n = s.name
  if not toRef:
    # (an object that holds one of its own type would be infinitely large)
    for r in t.file.syms:
      if r.kind == nxField and r.owner == n and r.line > s.line and r.line <= s.endLine and nxIsTypeNamed(r.typ, n):
        return NxPlan(msg: n & " holds a " & n & " (field " & r.name & "): as an object it would be infinitely large")
  result.ok = true
  result.msg = n & ": " & (if toRef: "object → ref object" else: "ref object → object")
  if toRef: result.edits.add nxEditOf(dpath, kl, kc, kl, kc, "ref ")
  else: result.edits.add nxEditOf(dpath, kl, kc, kl, kc + refLen, "")
  # does the type have its own `==`? then comparisons keep their meaning
  var ownEq = false
  for r in nxLookup(nxScope(t.file), "=="):
    if r.sym.params.len == 2 and nxIsTypeNamed(r.sym.params[0].typ, n): ownEq = true
  let hits = nxReferencesIn(t, (if dpath in files: files else: files & @[dpath]))
  var cache: Table[string, seq[string]]
  proc linesOf(p: string): seq[string] =
    if p notin cache: cache[p] = nxFileLines(p)
    cache[p]
  var paths: seq[string]
  var routinesDone: HashSet[string]
  for (p, l, c) in hits:
    if p notin paths: paths.add p
    if p == dpath and l == s.line and c == s.col: continue
    let pl = linesOf(p)
    if l >= pl.len: continue
    let txt = pl[l]
    let ne = nxIdentEnd(txt, c)
    let before = txt[0 ..< c]
    let after = nxCodeOf(txt[ne .. ^1])
    let bcode = before.strip
    if toRef and bcode.endsWith(":") and after.len == 0 and bcode.count('(') <= bcode.count(')'):
      # `var x: T`, a `var` section's `x: T`, a field `x: T`
      var decl = bcode[0 ..< ^1].strip
      var isVar = false
      if decl.startsWith("var "):
        isVar = true
        decl = decl[4 .. ^1].strip
      else:
        let (_, kw) = nxSectionOf(pl, l)
        if kw == "var": isVar = true
        elif kw in ["object", "type", "case", "of", "else", "when", "elif"] or bcode.count('[') == 0:
          let g = nxLoad(p)
          var field = ""
          if g != nil:
            for x in g.syms:
              if x.kind == nxField and x.line == l: field = x.name
          if field.len > 0:
            result.notes.add NxNote(path: p, line: l, col: c,
              why: "the field " & field & " starts as nil now (it was a " & n & " value): give it one where it is made")
          continue
      if isVar:
        let colon = before.rfind(':')
        if ',' in decl or '{' in decl or colon < 0:
          result.notes.add NxNote(path: p, line: l, col: c,
            why: "starts as nil now (it was a " & n & " value): give it a " & n & "()")
        else:
          result.edits.add nxEditOf(p, l, colon, l, ne, " = " & txt[c ..< ne] & "()")
      continue
    # the return type of a routine: one that uses `result` before giving it a value relied on a value too
    let g = nxLoad(p)
    if toRef and g != nil:
      for r in g.syms:
        if r.kind notin NxRoutineKinds or r.line > l or not nxIsTypeNamed(r.ret, n): continue
        let (hdr, hl) = nxHeaderLast(pl, r)
        if hl < l: continue
        let key = p & ":" & $r.line
        if key in routinesDone: break
        routinesDone.incl key
        let eq = hdr.rfind('=')
        if eq < 0 or hdr[eq + 1 .. ^1].strip.len > 0 or r.endLine <= hl: break   # (one line: an expression)
        var first = -1                     # the first body line with a statement
        var needs = false
        var st: NxLexState
        block scan:
          var skipInd = -1
          for k in hl + 1 .. min(r.endLine, pl.high):
            let tk = pl[k].strip
            if skipInd >= 0:
              if tk.len == 0 or leadWs(pl[k]) > skipInd: continue
              skipInd = -1
            if first < 0:
              if tk.len == 0 or tk.startsWith("#"): continue
              if tk.startsWith("runnableExamples"):
                skipInd = leadWs(pl[k])
                continue
              first = k
            for (a, e) in nxIdents(pl[k], st):
              if pl[k][a ..< e] != "result": continue
              var j = e
              while j < pl[k].len and pl[k][j] == ' ': inc j
              let assign = j < pl[k].len and pl[k][j] == '=' and (j + 1 >= pl[k].len or pl[k][j + 1] != '=')
              needs = not assign
              break scan
            if tk.startsWith("return "): break scan
        if needs and first >= 0:
          result.edits.add nxEditOf(p, first, 0, first, 0, spaces(leadWs(pl[first])) & "result = " & n & "()\n")
        break
    if not toRef:
      # new(T), new T, T.new(): a T() now
      let b2 = before.strip(leading = false)
      if b2.endsWith("new(") and after.startsWith(")"):
        let a0 = before.rfind("new(")
        result.edits.add nxEditOf(p, l, a0, l, ne + txt[ne .. ^1].find(')') + 1, txt[c ..< ne] & "()")
      elif b2.endsWith("new") and before.endsWith(" ") and (after.len == 0 or after[0] in {')', ',', ']'}):
        let a0 = b2.len - 3
        result.edits.add nxEditOf(p, l, a0, l, ne, txt[c ..< ne] & "()")
      elif after.startsWith(".new"):
        var e2 = ne + txt[ne .. ^1].find(".new") + 4
        if e2 + 1 < txt.len and txt[e2] == '(' and txt[e2 + 1] == ')': e2 += 2
        result.edits.add nxEditOf(p, l, c, l, e2, txt[c ..< ne] & "()")
  # the files that use it: comparisons, copies, new(x), nil
  for p in paths:
    let pl = linesOf(p)
    let g = nxLoad(p)
    if g == nil: continue
    let sc = nxScope(g)
    proc isT(l, col: int, e: string): bool =
      let x = e.strip
      if x.len == 0 or x == "nil": return false
      nxIsTypeNamed(nxTypeOfExpr(g, sc, nxLocals(g, pl, l, col), x, l, 0).typ, n)
    var st, sti: NxLexState
    for l in 0 ..< pl.len:
      let txt = pl[l]
      # (operators, and the names isNil and new: each followed by its own lexer, which knows the strings)
      let runs = nxLexRuns(txt, st, true) & nxIdents(txt, sti)
      if "==" notin txt and "!=" notin txt and "nil" notin txt and "new" notin txt and " = " notin txt: continue
      for (a, e) in runs:
        let op = txt[a ..< e]
        if op in ["==", "!="]:
          var i = a
          while i > 0 and txt[i - 1] == ' ': dec i
          var j = e
          while j < txt.len and txt[j] == ' ': inc j
          let left = txt[nxOperandBack(txt, i) ..< i]
          let right = txt[j ..< nxOperandFwd(txt, j)]
          if not (isT(l, a, left) or isT(l, a, right)): continue
          if "nil" in [left.strip, right.strip]:
            if not toRef: result.notes.add NxNote(path: p, line: l, col: a, why: "an object is never nil: this " & op & " nil no longer compiles")
          elif not ownEq:
            result.notes.add NxNote(path: p, line: l, col: a, why: (if toRef: op & " compares which object it is now, not the fields"
                                                                    else: op & " compares the fields now, not which object it is"))
        elif op == "isNil" and not toRef:
          let arg = if a > 0 and txt[a - 1] == '.': nxReceiver(txt, a - 1)
                    elif e < txt.len and txt[e] == '(' and nxMatchClose(txt, e) > e: txt[e + 1 ..< nxMatchClose(txt, e)]
                    else: ""
          if isT(l, a, arg): result.notes.add NxNote(path: p, line: l, col: a, why: "an object is never nil: isNil no longer compiles")
        elif op == "new" and not toRef and (a == 0 or txt[a - 1] != '.'):
          # new(x) / new x (a whole statement): x = T()
          let code = nxCodeOf(txt)
          var arg = ""
          if code.startsWith("new(") and code.endsWith(")") and nxMatchClose(code, 3) == code.high: arg = code[4 ..< ^1].strip
          elif code.startsWith("new ") and code.len > 4: arg = code[4 .. ^1].strip
          if arg.len > 0 and ',' notin arg and nxTypeSyms(sc, arg).len == 0 and isT(l, a, arg):
            let ind = leadWs(txt)
            result.edits.add nxEditOf(p, l, ind, l, ind + code.len, arg & " = " & n & "()")
        elif op == "=" and toRef and txt.strip(trailing = false).startsWith("let ") or
             op == "=" and toRef and txt.strip(trailing = false).startsWith("var "):
          # let y = x: one object for both now
          let code = nxCodeOf(txt)
          let eq = code.find(" = ")
          if eq < 0: continue
          let rhs = code[eq + 3 .. ^1].strip
          if rhs.len == 0 or not rhs.allCharsInSet(IdentChars + {'.'}) or rhs[0] notin IdentStartChars: continue
          if isT(l, a, rhs):
            result.notes.add NxNote(path: p, line: l, col: a,
              why: "the same object as " & rhs & " now (it was a copy): a change through one shows in the other")
        elif op == "=" and not toRef:
          var i = a
          while i > 0 and txt[i - 1] == ' ': dec i
          var j = e
          while j < txt.len and txt[j] == ' ': inc j
          if txt[j ..< nxOperandFwd(txt, j)].strip == "nil" and isT(l, a, txt[nxOperandBack(txt, i) ..< i]):
            result.notes.add NxNote(path: p, line: l, col: a, why: "an object is never nil: this = nil no longer compiles")

# ── split a module: the selected declarations into a new one ──

proc nxSpecFrom(fromFile, target, written: string): string =
  ## how `fromFile` imports `target`, which another module imports as `written`: the same (std/x, a package's
  ## name) unless that is a path, then a path from fromFile's folder
  if written.len > 0 and not written.startsWith(".") and not written.startsWith("/") and
     (written.startsWith("std/") or written.startsWith("pkg/") or '/' notin written and
      not fileExists(parentDir(fromFile) / written & ".nim")):
    return written
  relativePath(target.changeFileExt(""), parentDir(fromFile)).replace('\\', '/')

proc nxDirectImports(f: NxFile): Table[string, string] =
  ## the modules a file imports itself: path → the spec it writes for it
  for im in f.imports:
    if im.isInclude: continue
    let raw = im.spec.strip(chars = {'"', ' '})
    var parts: seq[string]
    let lb = raw.find('[')
    if lb > 0 and raw.endsWith("]"):
      for x in raw[lb + 1 ..< raw.len - 1].split(','): parts.add raw[0 ..< lb] & x.strip
    else: parts.add raw
    for part in parts:
      let rp = nxResolve(f.path, part)
      if rp.len > 0: result[rp] = part

proc nxImportsModule(f: NxFile, target: string): bool =
  for p, _ in nxDirectImports(f):
    if p == target: return true

proc nxImportLine(lines: seq[string]): int =
  ## where an import goes: after the last import at the top of the file (or after the module's doc comment)
  var inImport = false
  for l, t in lines:
    if t.startsWith("import ") or t.startsWith("from ") or t.startsWith("include "):
      result = l + 1
      inImport = t.strip(leading = false).endsWith(",") or t.count('[') > t.count(']')
    elif inImport and t.len > 0 and t[0] == ' ':
      result = l + 1
      inImport = t.strip(leading = false).endsWith(",") or t.count('[') > t.count(']')
    elif t.strip.len > 0 and not t.startsWith("#"):
      break
    elif result == 0 and t.startsWith("##"): result = l + 1

proc nxAddExportMark(text: var seq[string], first: int, s: NxSym) =
  ## `name` → `name*` where the declaration (now at line s.line - first of `text`) writes it
  let k = s.line - first
  if k < 0 or k >= text.len: return
  let t = text[k]
  var e = s.col + s.name.len
  if s.col < t.len and t[s.col] == '`':
    e = t.find('`', s.col + 1) + 1
    if e <= 0: return
  if e > t.len or nxNorm(t[s.col ..< e].strip(chars = {'`'})) != nxNorm(s.name.strip(chars = {'`'})): return
  if e < t.len and t[e] == '*': return
  text[k] = t[0 ..< e] & "*" & t[e .. ^1]

proc nxPlanSplit*(f: NxFile, lines: seq[string], a, e: int, newPath: string, files: seq[string]): NxPlan =
  ## the top-level declarations on lines a..e (whole ones: the selection grows to where they start and end; inside
  ## a `type`/`const`/`let`/`var` section, its members) into the module `newPath` (made, or added to). The new
  ## module imports what they use; the old one imports the new one where it still uses them, and exports again
  ## the ones it exported, so the modules that import it go on as before
  if f == nil or a < 0 or e >= lines.len or a > e: return NxPlan(msg: "Select the declarations to move")
  if newPath == f.path: return NxPlan(msg: "That is the module they are in")
  var a = a
  var e = e
  while a < e and lines[a].strip.len == 0: inc a
  while e > a and lines[e].strip.len == 0: dec e
  var sa, se: int
  var section = ""                 # moving members of a section: its keyword (they get a section of their own)
  var wholeSection = false
  if leadWs(lines[a]) == 0:
    let t = lines[a].strip
    for kw in ["elif ", "else:", "of ", "except", "finally:"]:
      if t.startsWith(kw): return NxPlan(msg: "Select whole declarations (from their first line)")
    sa = a
    while sa > 0 and lines[sa - 1].startsWith("#"): dec sa      # (its comment above goes with it)
    se = e
    var k = e + 1
    while k < lines.len:
      if lines[k].strip.len == 0: inc k
      elif leadWs(lines[k]) > 0 or lines[k].startsWith("#"):
        if not lines[k].startsWith("#"): se = k
        inc k
      else: break
  else:
    proc topOf(l: int): int =
      ## the top-level line a line is in
      result = l
      while result > 0 and (lines[result].strip.len == 0 or lines[result].strip.startsWith("#") or
                            leadWs(lines[result]) > 0):
        dec result
    let hl = topOf(a)
    var kw = lines[hl].strip
    kw = kw[0 ..< nxIdentEnd(kw, 0)]
    if kw notin ["type", "const", "let", "var"]:
      return NxPlan(msg: "Select top-level declarations, or members of a type, const, let or var section")
    if leadWs(lines[e]) == 0 or topOf(e) != hl:
      return NxPlan(msg: "Select declarations of one section (or whole top-level ones)")
    var mind = high(int)
    for k in hl + 1 ..< lines.len:
      if lines[k].strip.len == 0 or lines[k].strip.startsWith("#"): continue
      if leadWs(lines[k]) == 0: break
      mind = min(mind, leadWs(lines[k]))
    section = kw
    sa = a
    while sa > hl + 1 and leadWs(lines[sa]) > mind: dec sa
    while sa > hl + 1 and lines[sa - 1].strip.startsWith("#") and leadWs(lines[sa - 1]) == mind: dec sa
    se = e
    var k = e + 1
    while k < lines.len and (lines[k].strip.len == 0 or leadWs(lines[k]) > mind):
      if lines[k].strip.len > 0: se = k
      inc k
    # the whole section selected: its keyword's line goes too
    var first = hl + 1
    while first < lines.len and (lines[first].strip.len == 0 or lines[first].strip.startsWith("#")): inc first
    var last = first
    k = first
    while k < lines.len and (lines[k].strip.len == 0 or leadWs(lines[k]) > 0):
      if lines[k].strip.len > 0: last = k
      inc k
    if sa <= first and se >= last and lines[hl].strip == kw:
      wholeSection = true
      sa = hl
      se = last
  # what moves: the declarations whose names are in the range
  var moved: seq[int]
  for i, s in f.syms:
    if s.line >= sa and s.line <= se and not s.local and not s.made and
       s.kind in NxRoutineKinds + {nxType, nxConst, nxLet, nxVar}:
      moved.add i
  if moved.len == 0: return NxPlan(msg: "No declaration in the selection")
  proc inRange(r: NxRef): bool = r.file.path == f.path and r.sym.line >= sa and r.sym.line <= se
  # what the moved code uses: modules to import, and names that stay behind (the two would import each other)
  let direct = nxDirectImports(f)
  var needMods: seq[string]
  var stays: seq[string]
  var st: NxLexState
  for l in 0 ..< sa: discard nxIdents(lines[l], st)
  for l in sa .. se:
    for (ia, ie) in nxIdents(lines[l], st):
      let (rs, ls, mp) = nxTargets(f, lines, l, ia)
      if ls.len > 0: continue
      if mp.len > 0:
        if mp in direct and mp notin needMods: needMods.add mp
        continue
      if rs.len == 0: continue
      let r = rs[0]
      if r.file.path == f.path:
        if not inRange(r) and r.sym.kind notin {nxParam, nxResult, nxForVar} and not r.sym.local and
           r.sym.name notin stays and nxSymAt(f, l, ia) < 0:
          stays.add r.sym.name
        continue
      var m = r.file.path
      if m notin direct:
        # (a name an import re-exports: that import)
        var found = ""
        for dp, _ in direct:
          var got: seq[NxRef]
          var seen: HashSet[string]
          nxExports(dp, 0, seen, got)
          for x in got:
            if x.file.path == m:
              found = dp
              break
          if found.len > 0: break
        m = found
      if m.len > 0 and m notin needMods: needMods.add m
  if stays.len > 0:
    return NxPlan(msg: "The code uses " & stays[0 ..< min(4, stays.len)].join(", ") & ", which stay in " &
                       extractFilename(f.path) & " — select them too (the two modules would import each other)")
  # who still uses what moves: the old module (it imports the new one), and the rest of the project (through the
  # old module, which exports them again)
  var usedByOld, reexport: seq[string]
  var marks: seq[int]               # moved declarations that need a `*` now
  for i in moved:
    let s = f.syms[i]
    let r = NxRef(file: f, idx: int32(i))
    var oldUse = false
    for (p, l, c) in nxReferencesIn(r, @[f.path]):
      if l < sa or l > se: oldUse = true
    if oldUse:
      usedByOld.add s.name
      if not s.exported: marks.add i
    if s.exported and s.name notin reexport: reexport.add s.name
  result.ok = true
  var text = lines[sa .. se]
  for i in marks: nxAddExportMark(text, sa, f.syms[i])
  if section.len > 0 and not wholeSection: text.insert(section, 0)
  # the new module: its imports, then the declarations (added at the end of one that exists)
  let tl = (if fileExists(newPath): nxFileLines(newPath) else: @[])
  let g = (if tl.len > 0: nxLoad(newPath) else: nil)
  var specs: seq[string]
  for m in needMods:
    if m == newPath or (g != nil and nxImportsModule(g, m)): continue
    specs.add nxSpecFrom(newPath, m, direct.getOrDefault(m))
  var tail = tl.len
  while tail > 0 and tl[tail - 1].strip.len == 0: dec tail
  if tail == 0:
    if not fileExists(newPath): result.creates.add newPath
    var t = ""
    for sp in specs: t.add "import " & sp & "\n"
    let endL = max(0, tl.high)
    result.edits.add nxEditOf(newPath, 0, 0, endL, (if tl.len > 0: tl[endL].len else: 0),
                              t & (if t.len > 0: "\n" else: "") & text.join("\n") & "\n")
  else:
    if specs.len > 0:
      var t = ""
      for sp in specs: t.add "import " & sp & "\n"
      let at = nxImportLine(tl)
      result.edits.add nxEditOf(newPath, at, 0, at, 0, t)
    result.edits.add nxEditOf(newPath, tl.high, tl[^1].len, tl.high, tl[^1].len, "\n\n" & text.join("\n"))
  # out of the old module (and the blank line after it), and its import of the new one
  var cutEnd = se + 1
  if cutEnd < lines.len and lines[cutEnd].strip.len == 0: inc cutEnd
  if cutEnd < lines.len: result.edits.add nxEditOf(f.path, sa, 0, cutEnd, 0, "")
  else:
    var a2 = sa
    var c2 = 0
    if a2 > 0:                                   # (at the end: the line break before it goes too)
      dec a2
      c2 = lines[a2].len
    result.edits.add nxEditOf(f.path, a2, c2, lines.high, lines[^1].len, "")
  if usedByOld.len > 0 or reexport.len > 0:
    let at = nxImportLine(lines)
    if at > sa and at <= se + 1:
      return NxPlan(msg: "The selection holds the module's imports — select declarations only")
    var t = "import " & nxSpecFrom(f.path, newPath, "") & "\n"
    if reexport.len > 0: t.add "export " & reexport.join(", ") & "\n"
    result.edits.add nxEditOf(f.path, at, 0, at, 0, t)
  result.msg = "Moved " & $moved.len & " declaration" & (if moved.len == 1: "" else: "s") & " to " &
               extractFilename(newPath)

# ── callback → async ──

proc nxCallbackParam(s: NxSym): (int, string, string) =
  ## the parameter of `s` that is a callback taking one value (proc (r: T)) or none: (its index, its name, T —
  ## "" for none); index -1 when there is none
  result = (-1, "", "")
  for k in countdown(s.params.high, 0):
    var t = s.params[k].typ.strip
    if t.startsWith("proc") and (t.len == 4 or t[4] in {' ', '('}):
      t = t[4 .. ^1].strip
      if not t.startsWith("("): continue
      let ce = nxMatchClose(t, 0)
      if ce < 0: continue
      let rest = t[ce + 1 .. ^1].strip
      if rest.startsWith(":"): continue                   # (a callback that returns a value: not a result)
      let ps = nxParseParams(t[1 ..< ce])
      if ps.len > 1: continue
      return (k, s.params[k].name, (if ps.len == 1: ps[0].typ.strip else: ""))

proc nxIsAsyncRoutine(s: NxSym): bool =
  ## {.async.}, {.async: (raises: […]).}, {.multisync.}
  for p in nxSplitTop(s.pragmas, {','}):
    if p.strip.split(':')[0].strip in ["async", "multisync"]: return true

proc nxPlanAsync*(f: NxFile, lines: seq[string], line, col: int, files: seq[string]): NxPlan =
  ## the routine at the place, which takes a callback `proc (r: T)`, made {.async.} and returning a Future[T]: the
  ## callback's calls in its body become `return value`; a call of it in an async routine becomes
  ## `let r = await f(…)` with the callback's body after it (`g(await f(…))` for a named callback); a call outside
  ## one is listed
  let (d, ok) = nxRoutineAt(f, lines, line, col)
  if not ok: return NxPlan(msg: "Put the cursor on a proc that takes a callback (its name, or a call of it)")
  let s = d.sym
  let dpath = d.file.path
  if dpath != f.path and dpath notin files:
    return NxPlan(msg: s.name & " is declared in " & dpath & " — outside this project")
  if s.kind notin {nxProc, nxFunc, nxMethod}: return NxPlan(msg: "Only a proc can become {.async.}")
  if nxIsAsyncRoutine(s): return NxPlan(msg: s.name & " is {.async.} already")
  if s.ret.strip.len > 0 and s.ret.strip != "void":
    return NxPlan(msg: s.name & " returns " & s.ret & " — only one that gives its result to a callback can change")
  let (ci, cname, ctyp) = nxCallbackParam(s)
  if ci < 0: return NxPlan(msg: s.name & " takes no callback of one value (proc (r: T)) to make a Future of")
  let dl = nxFileLines(dpath)
  let hl = nxHeaderLast(dl, s)[1]
  # the header: the callback out of the parameters, `: Future[T]` and {.async.} in
  let fut = "Future[" & (if ctyp.len > 0: ctyp else: "void") & "]"
  block header:
    # the parameter list as written (may go over several lines): find the callback's name in it
    let po = dl[s.line].find('(', s.col + s.name.len)
    if po < 0: return NxPlan(msg: "Cannot read the parameters of " & s.name)
    var whole = dl[s.line][po .. ^1]
    var lineStarts = @[(s.line, po, 0)]          # (line, its column, where it starts in `whole`)
    var k = s.line
    while nxMatchClose(whole, 0) < 0 and k < hl:
      inc k
      lineStarts.add (k, 0, whole.len + 1)
      whole.add "\n" & dl[k]
    let pc = nxMatchClose(whole, 0)
    if pc < 0: return NxPlan(msg: "Cannot read the parameters of " & s.name)
    proc posOf(o: int): (int, int) =
      var r = lineStarts[0]
      for x in lineStarts:
        if x[2] <= o: r = x
      (r[0], r[1] + o - r[2])
    let inner = whole[1 ..< pc]
    let parts = nxSplitTop(inner, {',', ';'})
    # each part's place in `inner`
    var offs: seq[int]
    var o = 0
    for part in parts:
      offs.add o
      o += part.len + 1
    var pi = -1
    for i, part in parts:
      let nm = part.strip.split(':')[0].strip
      if nxNorm(nm) == nxNorm(cname): pi = i
    if pi < 0: return NxPlan(msg: "Cannot find the parameter " & cname & " of " & s.name)
    if ':' notin parts[pi]: return NxPlan(msg: cname & " shares its type with another parameter — give it its own first")
    # out: from the separator before it (or, for the first, to the one after it)
    var ra, re: int
    if pi > 0:
      ra = offs[pi] - 1
      re = offs[pi] + parts[pi].len
    elif parts.len > 1:
      ra = 0
      re = offs[1]
      while re < inner.len and inner[re] in {' ', '\n'}: inc re
    else:
      ra = 0
      re = inner.len
    let (al, ac) = posOf(ra + 1)
    let (el, ec) = posOf(re + 1)
    result.edits.add nxEditOf(dpath, al, ac, el, ec, "")
    # after the ")": the return type and the pragma
    let (cl, cc) = posOf(pc)
    let rest = whole[pc + 1 .. ^1]
    let pr = rest.find("{.")
    let eqAt = nxFindTop(rest, '=')
    if pr >= 0 and (eqAt < 0 or pr < eqAt):
      let pe = rest.find(".}", pr)
      if pe < 0: return NxPlan(msg: "Cannot read the pragmas of " & s.name)
      let (pl1, pc1) = posOf(pc + 1 + pe)
      result.edits.add nxEditOf(dpath, cl, cc + 1, cl, cc + 1, ": " & fut)
      result.edits.add nxEditOf(dpath, pl1, pc1, pl1, pc1, ", async")
    else:
      result.edits.add nxEditOf(dpath, cl, cc + 1, cl, cc + 1, ": " & fut & " {.async.}")
  # the body: cb(x) → return x (where it ends the routine; elsewhere listed)
  result.ok = true
  result.msg = s.name & " → {.async.}: " & fut
  var st: NxLexState
  let bodyEnd = min(s.endLine, dl.high)
  var lastStmt = -1
  for k in hl + 1 .. bodyEnd:
    let t = dl[k].strip
    if t.len > 0 and not t.startsWith("#"): lastStmt = k
  for k in hl + 1 .. bodyEnd:
    for (a, e) in nxIdents(dl[k], st):
      if nxNorm(dl[k][a ..< e]) != nxNorm(cname): continue
      let code = nxCodeOf(dl[k])
      let ind = leadWs(dl[k])
      var arg = ""
      var whole = false
      if code.startsWith(dl[k][a ..< e] & "(") and code.endsWith(")") and a == ind and
         nxMatchClose(code, e - a) == code.high:
        arg = code[e - a + 1 ..< ^1].strip
        whole = true
      elif code.startsWith(dl[k][a ..< e] & " ") and a == ind:
        arg = code[e - a + 1 .. ^1].strip
        whole = true
      if not whole:
        result.notes.add NxNote(path: dpath, line: k, col: a,
          why: cname & " is used here, not called: there is no callback any more")
        continue
      # (in a loop, or with statements after it: a return ends the routine there)
      var tail = k == lastStmt
      if not tail:
        tail = true
        for q in k + 1 .. bodyEnd:
          let tq = dl[q].strip
          if tq.len == 0 or tq.startsWith("#"): continue
          if leadWs(dl[q]) >= ind or not (tq.startsWith("else") or tq.startsWith("elif ") or tq.startsWith("of ") or
                                          tq.startsWith("except")):
            tail = false
          break
      var inLoop = false
      var cur = ind
      for q in countdown(k - 1, hl + 1):
        let tq = dl[q].strip
        if tq.len == 0 or tq.startsWith("#"): continue
        if leadWs(dl[q]) < cur:
          cur = leadWs(dl[q])
          if tq.startsWith("for ") or tq.startsWith("while "): inLoop = true
      result.edits.add nxEditOf(dpath, k, a, k, a + code.len, (if arg.len > 0: "return " & arg else: "return"))
      if inLoop or not tail:
        result.notes.add NxNote(path: dpath, line: k, col: a,
          why: "returns here now: the code after it no longer runs (the callback did not end " & s.name & ")")
  # the module needs asyncdispatch
  var hasAsync = false
  for im in d.file.imports:
    if "async" in im.spec or "chronos" in im.spec: hasAsync = true
  if not hasAsync:
    let at = nxImportLine(dl)
    result.edits.add nxEditOf(dpath, at, 0, at, 0, "import std/asyncdispatch\n")
  # the calls
  let hits = nxReferencesIn(d, (if dpath in files: files else: files & @[dpath]))
  for (p, l, c) in hits:
    if p == dpath and l == s.line and c == s.col: continue
    let pl = nxFileLines(p)
    let g = nxLoad(p)
    if g == nil or l >= pl.len: continue
    let txt = pl[l]
    let ri = nxEnclosing(g, l)
    let caller = if ri >= 0: g.syms[ri] else: NxSym(name: "")
    if ri < 0 or not nxIsAsyncRoutine(caller):
      result.notes.add NxNote(path: p, line: l, col: c, why: (if ri < 0: "not in a routine" else: caller.name & " is not {.async.}") &
                              ": make it async (and await this), or waitFor it")
      continue
    let ind = leadWs(txt)
    let ne = nxIdentEnd(txt, c)
    # the call: f(args, cb) · f(args) do (r: T): · x.f(args, cb)
    var callStart = c
    var recv = ""
    if c > 0 and txt[c - 1] == '.':
      let r = nxReceiver(txt, c - 1)
      callStart = c - 1 - r.len
      recv = r
    if callStart != ind:
      result.notes.add NxNote(path: p, line: l, col: c, why: "a call inside another statement: rewrite it with await by hand")
      continue
    if ne >= txt.len or txt[ne] != '(':
      result.notes.add NxNote(path: p, line: l, col: c, why: "rewrite this call with await by hand")
      continue
    # its argument list, which may go on over the lines below (a callback written out)
    var whole = txt[ne .. ^1]
    var k = l
    while nxMatchClose(whole, 0) < 0 and k + 1 < pl.len and k - l < 200:
      inc k
      whole.add "\n" & pl[k]
    let ce = nxMatchClose(whole, 0)
    if ce < 0: continue
    let args = nxSplitTop(whole[1 ..< ce], {','})
    var plain: seq[string]
    for x in args:
      if x.strip.len > 0: plain.add x.strip
    if recv.len > 0: plain.insert(recv, 0)
    let after = whole[ce + 1 .. ^1].strip
    var cbArg = ""
    var body: seq[string]
    var rname = ""
    var lastLine = k
    if after.startsWith("do"):
      # f(args) do (r: T):⏎ body
      let dd = after[2 .. ^1].strip
      if dd.startsWith("(") and dd.endsWith(":") and nxMatchClose(dd, 0) > 0:
        let ps = nxParseParams(dd[1 ..< nxMatchClose(dd, 0)])
        if ps.len == 1: rname = ps[0].name
      elif dd == ":": discard
      else:
        result.notes.add NxNote(path: p, line: l, col: c, why: "rewrite this call with await by hand")
        continue
      var q = k + 1
      while q < pl.len and (pl[q].strip.len == 0 or leadWs(pl[q]) > ind):
        body.add pl[q]
        lastLine = q
        inc q
      while body.len > 0 and body[^1].strip.len == 0: body.setLen(body.len - 1)
      lastLine = k + body.len
    else:
      if after.len > 0:
        result.notes.add NxNote(path: p, line: l, col: c, why: "rewrite this call with await by hand")
        continue
      let cbIdx = ci                       # (a method call's receiver is the first parameter: in `plain` too)
      if cbIdx >= plain.len:
        result.notes.add NxNote(path: p, line: l, col: c, why: "the callback is not passed here: rewrite by hand")
        continue
      cbArg = plain[cbIdx]
      plain.delete(cbIdx)
      let lam = cbArg.strip
      if lam.startsWith("proc"):
        # proc (r: T) = expr  ·  proc (r: T) =⏎ body
        let po = lam.find('(')
        let pc2 = if po >= 0: nxMatchClose(lam, po) else: -1
        if pc2 < 0:
          result.notes.add NxNote(path: p, line: l, col: c, why: "rewrite this call with await by hand")
          continue
        let ps = nxParseParams(lam[po + 1 ..< pc2])
        if ps.len == 1: rname = ps[0].name
        let eq = nxFindTop(lam, '=', pc2 + 1)
        if eq < 0:
          result.notes.add NxNote(path: p, line: l, col: c, why: "rewrite this call with await by hand")
          continue
        let rest = lam[eq + 1 .. ^1]
        if '\n' notin rest: body = @[spaces(ind) & rest.strip]
        else:
          let bl = rest.split('\n')
          if bl[0].strip.len > 0: body.add spaces(ind) & bl[0].strip
          var bodyInd = high(int)
          for x in bl[1 .. ^1]:
            if x.strip.len > 0: bodyInd = min(bodyInd, leadWs(x))
          for x in bl[1 .. ^1]:
            body.add (if x.strip.len == 0: "" elif bodyInd != high(int) and x.len >= bodyInd: spaces(ind) & x[bodyInd .. ^1].strip(leading = false) else: x)
          while body.len > 0 and body[^1].strip.len == 0: body.setLen(body.len - 1)
        cbArg = ""
      else:
        if not lam.allCharsInSet(IdentChars + {'.'}):
          result.notes.add NxNote(path: p, line: l, col: c, why: "rewrite this call with await by hand")
          continue
    let call = s.name & "(" & plain.join(", ") & ")"
    var newText: string
    if cbArg.len > 0: newText = spaces(ind) & cbArg & "(await " & call & ")"
    else:
      newText = spaces(ind) & (if rname.len > 0: "let " & rname & " = await " & call else: "await " & call)
      if body.len > 0:
        # (the body, at the call's indentation)
        var bodyInd = high(int)
        for x in body:
          if x.strip.len > 0: bodyInd = min(bodyInd, leadWs(x))
        for x in body:
          newText.add "\n" & (if x.strip.len == 0: "" elif bodyInd != high(int) and bodyInd > ind: spaces(ind) & x[bodyInd .. ^1] else: x)
    result.edits.add nxEditOf(p, l, 0, lastLine, pl[lastLine].len, newText)

# ── a call's syntax: f(x, y) · x.f(y) · f x, y ──

type NxCallText* = object
  ## a call as written on one line
  ok*: bool
  form*: NxCallForm
  a*, e*: int                ## its text: from the receiver (or the name) to after its last argument
  name*: string
  recv*: string              ## x.f(…): x
  args*: seq[string]         ## the arguments after the receiver, as written

const NxNotArgWords = ["and", "or", "xor", "not", "in", "notin", "is", "isnot", "of", "as", "div", "mod", "shl", "shr",
                       "do", "then", "else", "elif"]

func nxRecvStart(s: string, dot: int): int =
  ## where the receiver before the `.` at `dot` starts: a.b, f(x).y, xs[0].z, "lit".w
  var i = dot - 1
  while i >= 0:
    let ch = s[i]
    if ch == '.' and i > 0 and s[i - 1] == '.': break
    if nxIsIdent(ch) or ch == '.': dec i
    elif ch in {')', ']', '}'}:
      let open = (if ch == ')': '(' elif ch == ']': '[' else: '{')
      var depth = 0
      while i >= 0:
        if s[i] == ch: inc depth
        elif s[i] == open:
          dec depth
          if depth == 0: break
        dec i
      dec i
    elif ch == '"':
      dec i
      while i >= 0 and s[i] != '"': dec i
      dec i
    else: break
  i + 1

func nxStmtStart(code: string, at: int): bool =
  ## is `at` where a statement starts (only spaces before it, or `discard `)
  let pre = code[0 ..< at].strip
  pre.len == 0 or pre == "discard"

proc nxParseCall*(line: string, nameAt: int): NxCallText =
  ## the call whose routine's name is written at `nameAt` (one line)
  let ne = nxIdentEnd(line, nameAt)
  if ne == nameAt: return
  result.name = line[nameAt ..< ne]
  if result.name in NxKeywords: return
  let code = block:
    var q = false
    var k = 0
    var cut = line.len
    while k < line.len:
      if line[k] == '\\' and q: inc k
      elif line[k] == '"': q = not q
      elif line[k] == '#' and not q:
        cut = k
        break
      inc k
    line[0 ..< cut].strip(leading = false)
  if ne < code.len and code[ne] == '[': return            # (explicit generics: f[T](x) — left alone)
  if nameAt > 0 and line[nameAt - 1] == '.' and not (nameAt > 1 and line[nameAt - 2] == '.'):
    result.form = cfMethod
    result.a = nxRecvStart(line, nameAt - 1)
    result.recv = line[result.a ..< nameAt - 1]
    if result.recv.len == 0: return
    if ne < code.len and code[ne] == '(':
      let ce = nxMatchClose(code, ne)
      if ce < 0: return
      for x in nxSplitTop(code[ne + 1 ..< ce], {','}):
        if x.strip.len > 0: result.args.add x.strip
      result.e = ce + 1
    else:
      var j = ne
      while j < code.len and code[j] == ' ': inc j
      if j < code.len and code[j] == '=' and (j + 1 >= code.len or code[j + 1] != '='): return   # x.f = v: a setter
      if j > ne and j < code.len and (nxIsIdent(code[j]) or code[j] in {'"', '\'', '@', '['}):
        var w = j
        while w < code.len and nxIsIdent(code[w]): inc w
        if code[j ..< w] notin NxNotArgWords: return      # (x.f y: a command call after a dot — left alone)
      result.e = ne
    result.ok = true
    return
  if ne < code.len and code[ne] == '(':
    let ce = nxMatchClose(code, ne)
    if ce < 0: return
    result.form = cfPlain
    result.a = nameAt
    for x in nxSplitTop(code[ne + 1 ..< ce], {','}):
      if x.strip.len > 0: result.args.add x.strip
    result.e = ce + 1
    result.ok = true
    return
  if ne < code.len and code[ne] == ' ' and nxStmtStart(code, nameAt):
    var j = ne
    while j < code.len and code[j] == ' ': inc j
    if j >= code.len: return
    let c0 = code[j]
    if not (nxIsIdent(c0) or c0 in {'"', '\'', '@', '[', '{', '('} or
            (c0 in {'-', '$', '~', '!'} and j + 1 < code.len and code[j + 1] notin {' ', '='})):
      return
    var w = j
    while w < code.len and nxIsIdent(code[w]): inc w
    if code[j ..< w] in NxNotArgWords: return
    let rest = code[j .. ^1]
    if rest.endsWith(":") or rest.endsWith("="): return    # (a block after it: not a command call)
    let q = nxFindTop(rest, '=')
    if q >= 0 and q + 1 < rest.len and rest[q + 1] != '=' and (q == 0 or rest[q - 1] notin {'=', '!', '<', '>'}):
      return                                               # (x y = z: not a command call)
    result.form = cfCommand
    result.a = nameAt
    for x in nxSplitTop(rest, {','}):
      if x.strip.len == 0: return
      result.args.add x.strip
    result.e = code.len
    result.ok = true

func nxIsPrimary(x: string): bool =
  ## can `x` go before a `.` as it is (a name, a call, an index, a literal, something in brackets)
  if x.len == 0: return false
  if x[0] in {'-', '+', '@', '$', '!', '~', '&', '*', '<', '>', '='}: return false
  if x[0] in {'(', '[', '{'} and nxMatchClose(x, 0) == x.high: return true
  var depth = 0
  var i = 0
  while i < x.len:
    let c = x[i]
    if c == '"':
      inc i
      while i < x.len and x[i] != '"':
        if x[i] == '\\': inc i
        inc i
    elif c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif depth == 0 and (c == ' ' or (c in NxOpChars and c != '.') or (c == '.' and i + 1 < x.len and x[i + 1] == '.')):
      return false
    inc i
  true

func nxUnwrap(x: string): string =
  ## (a + b) → a + b: brackets around all of it, not a tuple
  if x.len >= 2 and x[0] == '(' and nxMatchClose(x, 0) == x.high and nxFindTop(x[1 ..< ^1], ',') < 0: x[1 ..< ^1].strip
  else: x

func nxNamedArg(x: string): bool =
  let eq = nxFindTop(x, '=')
  (eq > 0 and (eq + 1 >= x.len or x[eq + 1] != '=') and x[0 ..< eq].strip.allCharsInSet(IdentChars)) or
    (nxFindTop(x, ':') > 0 and x[0 ..< nxFindTop(x, ':')].strip.allCharsInSet(IdentChars))

proc nxCallAs*(c: NxCallText, form: NxCallForm, line: string): string =
  ## the call written in `form` ("": not possible with the same meaning)
  var all = c.args
  if c.form == cfMethod: all.insert(nxUnwrap(c.recv), 0)
  case form
  of cfPlain:
    result = c.name & "(" & all.join(", ") & ")"
  of cfMethod:
    if all.len == 0 or nxNamedArg(all[0]): return ""
    let r = if nxIsPrimary(all[0]): all[0] else: "(" & all[0] & ")"
    result = r & "." & c.name & "(" & all[1 .. ^1].join(", ") & ")"
  of cfCommand:
    # (only a whole statement — after `discard`, one argument —; f (a), b would pass a tuple; f alone is not a
    # call)
    let pre = line[0 ..< c.a].strip
    if all.len == 0 or all[0].startsWith("(") or c.e < nxCodeOf(line).len + leadWs(line) or
       not (pre.len == 0 or (pre == "discard" and all.len == 1)):
      return ""
    for x in all:
      if x.startsWith("proc") or "\n" in x or nxFindTop(x, ':') >= 0 and not x.startsWith("\""): return ""
    result = c.name & " " & all.join(", ")

proc nxCallNames(f: NxFile, lines: seq[string], a, e: int): (HashSet[string], HashSet[string]) =
  ## the names of routines called on lines a..e (each one a routine wherever it is written there), and those that
  ## must not go after a dot (a field of the first argument's type has the name)
  var routines, others, noDot: HashSet[string]
  let sc = nxScope(f)
  var st: NxLexState
  for l in 0 ..< a: discard nxIdents(lines[l], st)
  for l in a .. e:
    for (ia, ie) in nxIdents(lines[l], st):
      let w = lines[l][ia ..< ie]
      if w in NxKeywords: continue
      let (rs, ls, mp) = nxTargets(f, lines, l, ia)
      var isRoutine = rs.len > 0 and ls.len == 0 and mp.len == 0
      for r in rs:
        if r.sym.kind notin NxRoutineKinds: isRoutine = false
      if ls.len > 0 and ls[0].kind in NxRoutineKinds: isRoutine = true
      if isRoutine: routines.incl nxNorm(w)
      else: others.incl nxNorm(w)
      # x.f would reach a field f of x's type, not the routine
      if isRoutine:
        let c = nxParseCall(lines[l], ia)
        if c.ok and c.form != cfMethod and c.args.len > 0:
          let t = nxTypeOfExpr(f, sc, nxLocals(f, lines, l, ia), c.args[0], l, 0).typ
          if t.len > 0:
            for fr in nxFields(sc, nxStripMods(t)):
              if nxNorm(fr.sym.name) == nxNorm(w): noDot.incl nxNorm(w)
  for x in others: routines.excl x
  (routines, noDot)

proc nxPlanCallSyntax*(f: NxFile, lines: seq[string], path: string, a, e, col: int,
                       form = -1): NxPlan =
  ## at the call whose name is at (a, col) (a == e, form -1): the next of its forms that means the same —
  ## f(x, y) → x.f(y) → f x, y → f(x, y). Over lines a..e: every call of a routine there written in `form`
  ## where it can be (inner calls first)
  if a < 0 or e >= lines.len or a > e: return NxPlan(msg: "Nothing selected")
  let (routines, noDot) = nxCallNames(f, lines, a, e)
  if form < 0:
    # one call, at the cursor
    let (wa, we) = nxWordAt(lines[a], col)
    if wa >= we: return NxPlan(msg: "Put the cursor on the name of a call")
    let c = nxParseCall(lines[a], wa)
    if not c.ok: return NxPlan(msg: "No call here ned can write another way")
    if nxNorm(c.name) notin routines: return NxPlan(msg: c.name & " is not a routine ned knows here")
    var nx = c.form
    for _ in 0 .. 1:
      nx = NxCallForm((ord(nx) + 1) mod 3)
      if nx == cfMethod and nxNorm(c.name) in noDot: continue
      let t = nxCallAs(c, nx, lines[a])
      if t.len > 0:
        return NxPlan(ok: true, msg: lines[a][c.a ..< c.e] & " → " & t, edits: @[nxEditOf(path, a, c.a, a, c.e, t)])
    return NxPlan(msg: "This call has no other way to be written with the same meaning")
  let target = NxCallForm(form)
  result.ok = true
  var n = 0
  for l in a .. e:
    var cur = lines[l]
    var guard = 0
    var changed = true
    while changed and guard < 60:
      changed = false
      inc guard
      # the calls on the line, the last first (inner ones are to the right of where their outer one starts)
      var st: NxLexState
      var names: seq[int]
      for (ia, ie) in nxIdents(cur, st): names.add ia
      for k in countdown(names.high, 0):
        let c = nxParseCall(cur, names[k])
        if not c.ok or c.form == target or nxNorm(c.name) notin routines: continue
        if target == cfMethod and nxNorm(c.name) in noDot: continue
        let t = nxCallAs(c, target, cur)
        if t.len == 0: continue
        cur = cur[0 ..< c.a] & t & cur[c.e .. ^1]
        inc n
        changed = true
        break
    if cur != lines[l]: result.edits.add nxEditOf(path, l, 0, l, lines[l].len, cur)
  result.msg = $n & " call" & (if n == 1: "" else: "s") & " written as " &
               (case target
                of cfPlain: "f(x, y)"
                of cfMethod: "x.f(y)"
                of cfCommand: "f x, y")
  if n == 0:
    result.ok = false
    result.msg = "No call in the selection can be written that way with the same meaning"
