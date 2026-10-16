# ── Nim code generation: missing case branches, $ / == / hash / constructor, doc comment, run a selection ──

proc caseInfo(b: Buffer): (int, int, seq[string], int, bool) =
  ## the `case` around the cursor: (its line, the `of` indentation, the values it already has, where new
  ## branches go, has an else) — line -1 when there is none
  result = (-1, 0, @[], 0, false)
  var cl = b.primary.head.line
  let curInd = leadingWs(b.lines[cl]).len
  while cl >= 0 and b.primary.head.line - cl < 300:
    let t = b.lines[cl].strip
    if (t.startsWith("case ") or t.contains("= case ")) and leadingWs(b.lines[cl]).len <= curInd: break
    dec cl
  if cl < 0 or b.primary.head.line - cl >= 300: return
  let ci = leadingWs(b.lines[cl]).len
  var ofInd = -1
  var have: seq[string]
  var insertAt = cl + 1
  var hasElse = false
  var l = cl + 1
  while l < b.lines.len:
    let t = b.lines[l].strip
    let ind = leadingWs(b.lines[l]).len
    if t.len == 0 or t.startsWith("#"):
      inc l
      continue
    if ind < ci or (ind == ci and not (t.startsWith("of ") or t.startsWith("else") or t.startsWith("elif "))): break
    if t.startsWith("of ") and (ofInd < 0 or ind == ofInd):
      ofInd = ind
      let colon = t.find(':')
      for v in t[3 ..< (if colon > 0: colon else: t.len)].split(','):
        if v.strip.len > 0: have.add v.strip
    elif t.startsWith("else") and ind == ofInd:
      hasElse = true
      insertAt = l
      break
    insertAt = l + 1
    inc l
  result = (cl, (if ofInd >= 0: ofInd else: ci), have, insertAt, hasElse)

proc enumValuesOf(b: Buffer, caseLine: int): (string, seq[string]) =
  ## the values of the enum (or bool) a `case` switches on, from the Nim index
  let f = nxFileFor(b)
  if f == nil: return
  var ex = b.lines[caseLine].strip
  let k = ex.find("case ")
  ex = ex[k + 5 .. ^1]
  let h = ex.find('#')
  if h >= 0: ex = ex[0 ..< h]
  ex = ex.strip
  if ex.endsWith(":"): ex = ex[0 ..< ex.high].strip
  let sc = nxScope(f)
  let t = nxTypeOfExpr(f, sc, nxLocals(f, b.lines, caseLine, leadingWs(b.lines[caseLine]).len + k + 5), ex, caseLine, 0).typ
  if t.len == 0: return
  let base = nxResolveAlias(sc, nxBaseName(t))
  if base == "bool": return ("bool", @["false", "true"])
  for r in nxLookup(sc, base):
    if r.sym.kind != nxType: continue
    for sy in r.file.syms:
      if sy.kind == nxEnumVal and nxNorm(sy.owner) == nxNorm(r.sym.name): result[1].add sy.name
    if result[1].len > 0:
      result[0] = r.sym.name
      return

proc addMissingBranches() =
  let b = buf()
  if not nimEngineOn(b) or not b.canEdit(): return
  let (cl, ofInd, have, insertAt, hasElse) = caseInfo(b)
  if cl < 0:
    info("Put the cursor in a `case` statement")
    return
  var (tname, vals) = (("", newSeq[string]()))
  try: (tname, vals) = enumValuesOf(b, cl)
  except Exception as e: internalError("Nim index", e)
  if vals.len == 0:
    info("Missing branches work when the case is on an enum or a bool (the index could not tell its type)")
    return
  # values already handled (ranges a..b cover everything between, in declaration order)
  var covered: HashSet[string]
  for hv in have:
    let r = hv.find("..")
    if r > 0:
      let a = vals.find(hv[0 ..< r].strip.split('.')[^1])
      let e = vals.find(hv[r + 2 .. ^1].strip.strip(chars = {'<'}).split('.')[^1])
      if a >= 0 and e >= a:
        for i in a .. e: covered.incl nxNorm(vals[i])
    else: covered.incl nxNorm(hv.split('.')[^1])
  var missing: seq[string]
  for v in vals:
    if nxNorm(v) notin covered: missing.add v
  if missing.len == 0:
    info("Every value of " & tname & " has a branch")
    return
  var text = ""
  for v in missing: text.add spaces(ofInd) & "of " & v & ":\n" & spaces(ofInd) & b.indent & "discard\n"
  b.beginEdit()
  if insertAt < b.lines.len:
    discard b.replaceText(Pos(line: insertAt, col: 0), Pos(line: insertAt, col: 0), text)
  else:
    let l = b.lines.high
    discard b.replaceText(Pos(line: l, col: b.lines[l].len), Pos(line: l, col: b.lines[l].len), "\n" & text.strip(leading = false, chars = {'\n'}))
  b.endEdit()
  info("Added " & $missing.len & " branch" & (if missing.len > 1: "es" else: "") & " for " & tname &
       (if hasElse: " (the else branch is still there)" else: ""))

proc typeAtCursor(b: Buffer): (NxFile, int) =
  ## the object type declared on the cursor's line
  let f = nxFileFor(b)
  if f == nil: return (nil, -1)
  for i, sy in f.syms:
    if sy.kind == nxType and sy.line == b.primary.head.line and ("object" in sy.typ or "tuple" in sy.typ): return (f, i)
  (nil, -1)

proc generateForType(what: string) =
  let b = buf()
  if not b.canEdit(): return
  let (f, ti) = typeAtCursor(b)
  if f == nil:
    info("Put the cursor on an object type's line (Foo = object)")
    return
  let t = f.syms[ti]
  var fields: seq[NxSym]
  for sy in f.syms:
    if sy.kind == nxField and nxNorm(sy.owner) == nxNorm(t.name): fields.add sy
  let ex = if t.exported: "*" else: ""
  let isRef = t.typ.startsWith("ref")
  let ind = b.indent
  var outp: seq[string]
  if what in ["$", "all"]:
    var e = "\"" & t.name & "("
    for k, fl in fields:
      e.add (if k > 0: ", " else: "") & fl.name & ": \" & $x." & fl.name & " & \""
    e.add ")\""
    outp.add "proc `$`" & ex & "(x: " & t.name & "): string =\n" & ind & e
  if what in ["==", "all"]:
    var parts: seq[string]
    for fl in fields: parts.add "a." & fl.name & " == b." & fl.name
    outp.add "proc `==`" & ex & "(a, b: " & t.name & "): bool =\n" & ind &
             (if isRef: "if a.isNil or b.isNil: return a.isNil and b.isNil\n" & ind else: "") &
             (if parts.len > 0: parts.join(" and\n" & ind & ind) else: "true")
  if what in ["hash", "all"]:
    var body = ind & "var h: Hash = 0\n"
    for fl in fields: body.add ind & "h = h !& hash(x." & fl.name & ")\n"
    body.add ind & "result = !$h"
    outp.add "proc hash" & ex & "(x: " & t.name & "): Hash =\n" & body
  if what in ["init", "all"]:
    var params, assigns: seq[string]
    for fl in fields:
      params.add fl.name & ": " & (if fl.typ.len > 0: fl.typ else: "auto")
      assigns.add fl.name & ": " & fl.name
    let nm = (if isRef: "new" else: "init") & t.name
    outp.add "proc " & nm & ex & "(" & params.join(", ") & "): " & t.name & " =\n" & ind & t.name & "(" & assigns.join(", ") & ")"
  if outp.len == 0: return
  # after the type section
  var l = t.endLine + 1
  if l <= t.line: l = t.line + 1
  while l < b.lines.len and (b.lines[l].strip.len == 0 or leadingWs(b.lines[l]).len > 0): inc l
  while l > t.line + 1 and b.lines[l - 1].strip.len == 0: dec l
  let text = "\n\n" & outp.join("\n\n")
  b.beginEdit()
  let at = Pos(line: l - 1, col: b.lines[l - 1].len)
  discard b.replaceText(at, at, text)
  b.endEdit()
  if what in ["hash", "all"]: b.addImport("std/hashes")
  info("Generated " & (if what == "all": "$, ==, hash and a constructor" else: what) & " for " & t.name & " — Ctrl+Z undoes it")

proc docCommentStub() =
  ## a `##` comment under the routine header at the cursor, naming its parameters
  let b = buf()
  if not b.canEdit(): return
  let f = nxFileFor(b)
  if f == nil: return
  var ri = -1
  for i, sy in f.syms:
    if sy.kind in NxRoutineKinds and sy.line <= b.primary.head.line and b.primary.head.line <= sy.line + 3: ri = i
  if ri < 0:
    info("Put the cursor on a proc's first line")
    return
  let sy = f.syms[ri]
  # the body starts after the line that ends with `=`
  var hl = sy.line
  while hl < b.lines.high and not b.lines[hl].strip(leading = false).endsWith("="): inc hl
  if hl + 1 <= b.lines.high and b.lines[hl + 1].strip.startsWith("##"):
    info("It already has a doc comment")
    return
  let ind = leadingWs(b.lines[sy.line]) & b.indent
  var ps: seq[string]
  for prm in sy.params: ps.add "`" & prm.name & "`"
  let text = ind & "## " & (if ps.len > 0: "TODO: what it does with " & ps.join(", ") else: "TODO: what it does") &
             (if sy.ret.len > 0 and sy.ret != "void": "; what it returns" else: "") & "\n"
  b.beginEdit()
  discard b.replaceText(Pos(line: hl + 1, col: 0), Pos(line: hl + 1, col: 0), text)
  b.endEdit()
  b.setSingle(Pos(line: hl + 1, col: ind.len + 3), Pos(line: hl + 1, col: text.strip(leading = false).len))

type CtorInfo = object
  ok: bool
  typ: string                 # the object type
  open, close: Pos            # its `(` and `)`
  named: seq[string]          # the fields already given (normalized)
  hasArgs, trailingComma: bool
  missing: seq[(string, string)]   # field → the value to start it with

proc nimDefaultValue(sc: NxScope, typ: string): string =
  ## a value to start a field of type `typ` with
  let t = nxStripMods(typ).strip
  let r = nxResolveAlias(sc, t)
  if t.len == 0: return "default(auto)"
  if r in NxInts or t in NxInts or t in ["Natural", "Positive"]: return (if t == "Positive": "1" else: "0")
  if r in NxFloats or t in NxFloats: return "0.0"
  if r == "string" or t == "string": return "\"\""
  if r == "bool" or t == "bool": return "false"
  if r == "char" or t == "char": return "'\\0'"
  if t.startsWith("seq[") or r.startsWith("seq["): return "@[]"
  if t.startsWith("set[") or r.startsWith("set["): return "{}"
  if t.startsWith("Option[") and t.endsWith("]"): return "none(" & t[7 .. ^2] & ")"
  if t.startsWith("ref ") or t.startsWith("ptr ") or t in ["pointer", "cstring"]: return "nil"
  let (od, def) = nxObjectDef(sc, t)
  if od.file != nil:
    if def.startsWith("enum"):
      for sy in od.file.syms:
        if sy.kind == nxEnumVal and nxNorm(sy.owner) == nxNorm(od.sym.name): return sy.name
    if def.startsWith("ref ") or def.startsWith("ptr "): return "nil"
    if "object" in def and '[' notin t: return t & "()"
  "default(" & t & ")"

proc ctorAtCursor(b: Buffer): CtorInfo =
  ## the object constructor `Foo(a: 1, …)` the cursor is in, and the fields it does not set yet
  let f = nxFileFor(b)
  if f == nil: return
  let p = b.primary.head
  # back to the unclosed `(` (across a few lines)
  var l = p.line
  var c = min(p.col, b.lines[l].len) - 1
  var depth = 0
  var found = false
  let (wa, we) = nxWordAt(b.lines[l], p.col)
  if wa < we and we < b.lines[l].len and b.lines[l][we] == '(':
    c = we                            # (the cursor on the type's name)
    found = true
  while not found and l >= 0 and p.line - l <= 30:
    let t = b.lines[l]
    if c >= t.len: c = t.high
    while c >= 0:
      let ch = t[c]
      if ch in {')', ']', '}'}: inc depth
      elif ch in {'(', '[', '{'}:
        if depth == 0:
          if ch == '(': found = true
          break
        dec depth
      elif ch == '"':
        dec c
        while c >= 0 and t[c] != '"': dec c
      dec c
    if found or c >= 0: break
    dec l
    if l >= 0: c = b.lines[l].high
  if not found: return
  let t = b.lines[l]
  var e = c
  var a = e
  while a > 0 and nxIsIdent(t[a - 1]): dec a
  if a == e or a > 0 and t[a - 1] == '.': return
  let name = t[a ..< e]
  let sc = nxScope(f)
  var tr: NxRef
  for r in nxTypeSyms(sc, name):
    tr = r
    break
  if tr.file == nil: return
  let (od, def) = nxObjectDef(sc, name)
  if od.file == nil or "object" notin def: return
  # forward to its `)`, splitting the arguments at top-level commas
  var args: seq[string]
  var cur = ""
  depth = 0
  var ll = l
  var cc = c + 1
  var closed = false
  while ll < b.lines.len and ll - l <= 60 and not closed:
    let s2 = b.lines[ll]
    while cc < s2.len:
      let ch = s2[cc]
      if ch == '"':
        let q = s2.find('"', cc + 1)
        cur.add s2[cc .. (if q < 0: s2.high else: q)]
        cc = (if q < 0: s2.len else: q + 1)
        continue
      if ch == '#': break
      if ch in {'(', '[', '{'}: inc depth
      elif ch in {')', ']', '}'}:
        if depth == 0:
          if ch != ')': return
          result.close = Pos(line: ll, col: cc)
          closed = true
          break
        dec depth
      if ch == ',' and depth == 0:
        args.add cur
        cur = ""
      else: cur.add ch
      inc cc
    if not closed:
      inc ll
      cc = 0
      cur.add ' '
  if not closed: return
  if cur.strip.len > 0: args.add cur
  result.trailingComma = cur.strip.len == 0 and args.len > 0
  result.open = Pos(line: l, col: c)
  result.typ = name
  for x in args:
    let y = x.strip
    if y.len == 0: continue
    result.hasArgs = true
    var k = 0
    while k < y.len and nxIsIdent(y[k]): inc k
    var j = k
    while j < y.len and y[j] == ' ': inc j
    if k > 0 and j < y.len and y[j] == ':' and (j + 1 >= y.len or y[j + 1] != '='): result.named.add nxNorm(y[0 ..< k])
    else: return                      # (a positional argument: a conversion or a call, not a constructor)
  let fsc = if od.file != f: nxScope(od.file) else: sc
  for fr in nxFields(sc, name):
    let fl = fr.sym
    if nxNorm(fl.name) in result.named: continue
    if fr.file != f and not fl.exported and fr.file.path != f.path: continue     # (not visible from here)
    let v = if fl.value.len > 0: fl.value else: nimDefaultValue(fsc, fl.typ)
    result.missing.add (fl.name, v)
  result.ok = true

proc fillMissingFields() =
  let b = buf()
  if not b.canEdit(): return
  var ci: CtorInfo
  try: ci = ctorAtCursor(b)
  except Exception as e:
    internalError("Nim index", e)
    return
  if not ci.ok:
    info("Put the cursor inside an object constructor: Foo(a: 1, …)")
    return
  if ci.missing.len == 0:
    info("Every field of " & ci.typ & " is set already")
    return
  var parts: seq[string]
  for (n, v) in ci.missing: parts.add n & ": " & v
  b.beginEdit()
  if ci.open.line == ci.close.line:
    let at = ci.close
    let prev = if at.col > 0: b.lines[at.line][at.col - 1] else: ' '
    let sep = if ci.hasArgs and not ci.trailingComma: ", " elif ci.trailingComma and prev != ' ': " " else: ""
    discard b.replaceText(at, at, sep & parts.join(", "))
  else:
    # one per line, under the last one given
    var ll = ci.close.line
    let before = b.lines[ll][0 ..< ci.close.col]
    if before.strip.len == 0: dec ll
    let lastLine = b.lines[ll]
    let ind = if ll == ci.open.line: leadingWs(b.lines[ci.open.line]) & b.indent else: leadingWs(lastLine)
    var endCol = if ll == ci.close.line: ci.close.col else: lastLine.len
    while endCol > 0 and lastLine[endCol - 1] == ' ': dec endCol
    let lead = if ci.hasArgs and not ci.trailingComma: "," else: ""
    let text = lead & "\n" & ind & parts.join(",\n" & ind)
    let at = Pos(line: ll, col: endCol)
    discard b.replaceText(at, at, text)
  b.endEdit()
  var names: seq[string]
  for (n, _) in ci.missing: names.add n
  info("Filled in " & names.join(", ") & " — Ctrl+Z undoes it")

proc forwardDeclAt(b: Buffer): (NxFile, int) =
  ## the forward declaration (a routine header without a body) on the cursor's line that nothing implements
  let f = nxFileFor(b)
  if f == nil: return (nil, -1)
  let line = b.primary.head.line
  for i, sy in f.syms:
    if sy.kind notin NxRoutineKinds or sy.line != line or sy.made or b.hasBody(sy): continue
    if b.lines[line].len > 0 and b.lines[line][0] in {' ', '\t'}: continue    # (top level only)
    if "importc" in sy.pragmas or "importcpp" in sy.pragmas or "importjs" in sy.pragmas or "magic" in sy.pragmas or
       "dynlib" in sy.pragmas or "noDecl" in sy.pragmas: continue
    let want = nxParamsText(sy.params, false)
    var done = false
    for j, other in f.syms:
      if j != i and other.kind == sy.kind and nxNorm(other.name) == nxNorm(sy.name) and
         nxParamsText(other.params, false) == want and b.hasBody(other): done = true
    if not done: return (f, i)
  (nil, -1)

proc writeForwardBody() =
  ## the forward declaration at the cursor gets its implementation, at the end of the file (`discard` for now)
  let b = buf()
  if not b.canEdit(): return
  var (f, i) = (NxFile(nil), -1)
  try: (f, i) = forwardDeclAt(b)
  except Exception as e:
    internalError("Nim index", e)
    return
  if f == nil:
    info("Put the cursor on a forward declaration (a proc header without a body)")
    return
  let sy = f.syms[i]
  # the header, across its lines
  var head: seq[string]
  var depth = 0
  for l in sy.line .. min(sy.line + 20, b.lines.high):
    var t = b.lines[l]
    var k = 0
    var cut = t.len
    while k < t.len:
      case t[k]
      of '(', '[', '{': inc depth
      of ')', ']', '}': dec depth
      of '"':
        let q = t.find('"', k + 1)
        k = (if q < 0: t.len else: q)
      of '#':
        cut = k
        break
      else: discard
      inc k
    t = t[0 ..< cut].strip(leading = false)
    head.add t
    if depth <= 0 and not (t.endsWith(",") or t.endsWith("(")): break
  var text = head.join("\n")
  text = text.replace("{.forward.}", "").strip(leading = false)
  let at = Pos(line: b.lines.high, col: b.lines[^1].len)
  let gap = if b.lines[^1].strip.len == 0: (if b.lines.len >= 2 and b.lines[^2].strip.len == 0: "" else: "\n") else: "\n\n"
  b.beginEdit()
  discard b.replaceText(at, at, gap & text & " =\n" & b.indent & "discard  # TODO\n")
  b.endEdit()
  pushJump()
  let bl = b.lines.len - 2
  b.centerOn(b.clampPos(Pos(line: bl, col: b.indent.len)))
  b.setSingle(Pos(line: bl, col: b.indent.len), Pos(line: bl, col: b.indent.len + "discard".len))
  info("Wrote " & sy.name & "'s body at the end of the file — Alt+, goes back")

proc runSelection() =
  ## the selected code (with this file's imports) compiled and run; its output in a popup
  let b = buf()
  if b.lang.mode != lmNim: return
  let (a, e) = b.primary.range
  var code = if a != e: b.getText(a, e) else: b.lines[a.line]
  # dedent
  var ind = int.high
  for l in code.splitLines:
    if l.strip.len > 0: ind = min(ind, leadingWs(l).len)
  if ind == int.high: return
  var body: seq[string]
  for l in code.splitLines: body.add (if l.len >= ind: l[ind .. ^1] else: "")
  var imports: seq[string]
  for (l, le) in b.importStmts():
    for k in l .. le: imports.add b.lines[k]
  let tmp = privDir() / "ned_run_selection.nim"
  try: writeFile(tmp, imports.join("\n") & "\n" & body.join("\n") & "\n")
  except IOError, OSError:
    error("Could not write " & tmp)
    return
  info("Running the selection…")
  let dir = if b.path.len > 0: parentDir(b.path) else: rootDir
  discard startJob(jkTool, "nim r --hints:off --warnings:off --path:" & quoteShell(dir) & " " & quoteShell(tmp), dir, proc(j: Job) =
    var o = j.output.strip
    if o.len > 4000: o = o[0 ..< 4000] & "\n…"
    if o.len == 0: o = "(no output)"
    showHover((if j.code == 0: "**Output**" else: "**Failed** (exit " & $j.code & ")") & "\n```\n" & o & "\n```")
    info(if j.code == 0: "Ran the selection" else: "The selection did not compile or run — see the popup"))
