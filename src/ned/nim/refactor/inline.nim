# ── inline a routine: each call becomes its body ──

proc rfBodyExpr(lines: seq[string], s: NxSym): string =
  ## the one expression the routine's body is ("" when it is more than that)
  let h = lines[s.line]
  # the "=" that starts the body on the header line
  var depth = 0
  var eq = -1
  var i = s.col + s.name.len
  while i < h.len:
    let ch = h[i]
    if ch == '"':
      i = rfSkipStr(h, i)
      continue
    if ch in {'(', '[', '{'}: inc depth
    elif ch in {')', ']', '}'}: dec depth
    elif ch == '=' and depth == 0 and (i + 1 >= h.len or h[i + 1] != '=') and h[i - 1] notin {'=', '<', '>', '!'}:
      eq = i
      break
    inc i
  if eq < 0: return ""
  var body: seq[string]
  let rest = h[eq + 1 .. ^1].strip
  if rest.len > 0 and not rest.startsWith("#"): body.add rest
  for l in s.line + 1 .. min(s.endLine, lines.high):
    let t = lines[l].strip
    if t.len == 0 or t.startsWith("#"): continue
    body.add t
  if body.len != 1: return ""
  var e = body[0]
  if e.startsWith("result = "): e = e[9 .. ^1].strip
  elif e.startsWith("return "): e = e[7 .. ^1].strip
  elif e in ["discard", "result"]: return ""
  let hh = e.find(" #")
  if hh > 0: e = e[0 ..< hh].strip
  e

proc rfSubst(expr: string, params: seq[NxParam], vals: seq[string]): (bool, string) =
  ## the expression with each parameter replaced by what the call passes (false: an argument with work in it
  ## would run more than once)
  var uses = newSeq[int](params.len)
  var st: NxLexState
  let ids = nxIdents(expr, st)
  proc isLabel(a, e: int): bool =
    ## `name` in f(name = v) or P(name: v): a label, not the parameter
    var k = e
    while k < expr.len and expr[k] == ' ': inc k
    if k >= expr.len or expr[k] notin {':', '='} or (expr[k] == '=' and k + 1 < expr.len and expr[k + 1] == '='): return false
    var j = a - 1
    while j >= 0 and expr[j] == ' ': dec j
    j >= 0 and expr[j] in {'(', ','}
  for (a, e) in ids:
    if a > 0 and expr[a - 1] == '.': continue
    if isLabel(a, e): continue
    for i, p in params:
      if nxNorm(expr[a ..< e]) == nxNorm(p.name): inc uses[i]
  for i, p in params:
    let v = vals[i]
    let trivial = v.len > 0 and (v.validIdentifier or v[0] in Digits or (v.len >= 2 and v[0] == '"' and v[^1] == '"' and '"' notin v[1 ..< v.len - 1]) or
                                 v.allCharsInSet(IdentChars + {'.'}))
    if uses[i] > 1 and not trivial: return (false, "")
  var outp = ""
  var last = 0
  for (a, e) in ids:
    if a > 0 and expr[a - 1] == '.': continue
    if isLabel(a, e): continue
    var rep = ""
    for i, p in params:
      if nxNorm(expr[a ..< e]) == nxNorm(p.name):
        rep = if qSimple(vals[i]): vals[i] else: "(" & vals[i] & ")"
    if rep.len == 0: continue
    outp.add expr[last ..< a] & rep
    last = e
  outp.add expr[last .. ^1]
  (true, outp)

proc rfImportSpec(fromFile, target: string): string =
  ## how `fromFile` imports `target` (a path relative to its folder, without .nim)
  result = relativePath(target.changeFileExt(""), parentDir(fromFile)).replace('\\', '/')

proc rfImports(path: string, target: string): bool =
  ## does the file import the module `target`?
  let f = nxLoad(path)
  if f == nil: return false
  let tn = splitFile(target).name
  for im in f.imports:
    let spec = im.spec.strip(chars = {'"'})
    if spec.split('/')[^1] == tn or spec.endsWith("/" & tn) or spec == tn: return true
    if '[' in spec:
      for part in spec[spec.find('[') + 1 .. ^1].strip(chars = {']', ' '}).split(','):
        if part.strip == tn: return true
  false

proc rfAddImport(path: string, specs: seq[string], edits: var seq[RfEdit]) =
  ## `import spec` lines after the file's last import (or at the top), as one edit
  if specs.len == 0: return
  let lines = rfLinesOf(path)
  var at = 0
  var inImport = false
  for l, t in lines:
    if t.startsWith("import ") or t.startsWith("from ") or t.startsWith("include "):
      at = l + 1
      inImport = t.strip(leading = false).endsWith(",") or t.count('[') > t.count(']')
    elif inImport and t.len > 0 and t[0] == ' ':
      at = l + 1
      inImport = t.strip(leading = false).endsWith(",") or t.count('[') > t.count(']')
    elif t.strip.len > 0 and not t.startsWith("#"):
      if at == 0: at = l
      break
  var t = ""
  for sp in specs: t.add "import " & sp & "\n"
  edits.add (path, Pos(line: at, col: 0), Pos(line: at, col: 0), t)

proc rfImportMap(f: NxFile): Table[string, string] =
  ## the modules a file imports itself (not system, nor what an import re-exports): path → the spec it writes
  for im in f.imports:
    let raw = im.spec.strip(chars = {'"', ' '})
    var parts: seq[string]
    let lb = raw.find('[')
    if lb > 0 and raw.endsWith("]"):
      for x in raw[lb + 1 ..< raw.len - 1].split(','): parts.add raw[0 ..< lb] & x.strip
    else: parts.add raw
    for part in parts:
      let rp = nxResolve(f.path, part)
      if rp.len > 0: result[rp] = part

proc rfSpecFor(fromFile, m, part: string): string =
  ## how `fromFile` imports module `m`, which another file imports as `part`: the same (std/x, a package),
  ## or a path from its own folder
  if part.startsWith(".") or m.startsWith(rootDir & "/"): rfImportSpec(fromFile, m) else: part

proc cmdInlineProc() =
  let b = buf()
  if b.lang.mode != lmNim or not nimEngineOn(b):
    info("Inline works on Nim, with the built-in engine")
    return
  let (d, ok) = rfDeclOf(b)
  if not ok or d.sym.kind notin {nxProc, nxFunc, nxTemplate}:
    info("Put the cursor on a proc, func or template — its name, or a call of it")
    return
  let s = d.sym
  let declLines = rfLinesOf(d.file.path)
  let expr = rfBodyExpr(declLines, s)
  if expr.len == 0:
    info(s.name & ": only a routine whose body is one expression can be inlined")
    return
  # what the body uses: its own module's private names (a call elsewhere cannot see them), and modules its
  # module imports (a call elsewhere imports them too)
  var privates: seq[string]
  var bodyMods: seq[string]
  for (l, a, rs, ls, mp) in rfBodyIdents(d.file.path, s):
    if ls.len > 0: continue
    if mp.len > 0:
      if mp notin bodyMods: bodyMods.add mp
      continue
    if rs.len == 0: continue
    let r = rs[0]
    var same = true                     # (x.name with x's type unknown: every routine of that name)
    for q in rs:
      if q.file.path != r.file.path: same = false
    if not same: continue
    if r.file.path == d.file.path:
      if not r.sym.exported and r.sym.kind != nxParam and r.sym.name notin privates and
         not (r.sym.line == s.line and r.sym.name == s.name):
        privates.add r.sym.name
    elif r.file.path notin bodyMods: bodyMods.add r.file.path
  let declMods = rfImportMap(d.file)
  var needs: OrderedTable[string, seq[string]]    # file → the imports its inlined calls need
  let (full, hits) = rfRefs(d)
  var edits: seq[RfEdit]
  var byHand: seq[(string, int, int, string)]
  var calls = 0
  for (path, l, c) in hits:
    if path == d.file.path and l == s.line and c == s.col: continue
    if path != d.file.path:
      if privates.len > 0:
        byHand.add (path, l, c, "the body uses " & privates[0 ..< min(3, privates.len)].join(", ") & ", private to " &
                                extractFilename(d.file.path))
        continue
      var specs: seq[string]
      var cycle = ""
      for m in bodyMods:
        if m == path or m notin declMods or rfImports(path, m): continue
        if rfImports(m, path):
          cycle = m
          break
        specs.add rfSpecFor(path, m, declMods[m])
      if cycle.len > 0:
        byHand.add (path, l, c, "the body uses " & extractFilename(cycle) & ", which imports this module")
        continue
      for sp in specs:
        if sp notin needs.mgetOrPut(path, @[]): needs[path].add sp
    let lines = rfLinesOf(path)
    if l >= lines.len: continue
    let g = nxLoad(path)
    if g != nil and nxSymAt(g, l, c) >= 0:
      byHand.add (path, l, c, "another declaration of " & s.name)
      continue
    let nlen = rfIdentLen(lines[l], c)
    let cs = parseCallSite(lines, l, c, nlen)
    if not cs.ok or (not cs.parens and not cs.meth):
      byHand.add (path, l, c, (if cs.ok: "a call without parentheses" else: "could not read this call"))
      continue
    var (okMap, vals) = rfMapArgs(cs, s.params)
    if okMap:
      for i, p in s.params:
        if vals[i].len == 0:
          if p.default.len > 0: vals[i] = p.default
          else: okMap = false
    if not okMap:
      byHand.add (path, l, c, "its arguments do not match the parameters")
      continue
    let (okS, body) = rfSubst(expr, s.params, vals)
    if not okS:
      byHand.add (path, l, c, "an argument would run twice")
      continue
    let a = if cs.meth: Pos(line: l, col: cs.recvA) else: Pos(line: l, col: c)
    let e = if cs.parens: Pos(line: cs.ea.line, col: cs.ea.col + 1)
            else: Pos(line: l, col: c + nlen)
    # parentheses unless the call was a whole statement, or the body is a simple expression
    let stmt = lines[l][0 ..< a.col].strip.len == 0 and e.line == l and lines[l][e.col .. ^1].strip.len == 0
    edits.add (path, a, e, (if qSimple(body) or stmt: body else: "(" & body & ")"))
    inc calls
  if calls == 0 and byHand.len == 0:
    info(s.name & " is not called anywhere" & (if full: "" else: " that the engine found"))
    return
  for path, specs in needs:
    var inlined = false
    for x in edits:
      if x.path == path: inlined = true
    if inlined: rfAddImport(path, specs, edits)
  let files = rfApply(edits)
  info("Inlined " & $calls & " call(s) of " & s.name & " in " & $files & " file(s)" &
       (if byHand.len > 0: " · " & $byHand.len & " left to change by hand" else: "") & " — Ctrl+S saves")
  if byHand.len > 0:
    rfByHand("Inline " & s.name & " — by hand", byHand)
    return
  # nothing calls it any more: offer to remove it
  let path = d.file.path
  let a = s.line
  let e = s.endLine
  let name = s.name
  askConfirm("Every call of " & name & " is inlined — remove its declaration (lines " & $(a + 1) & "–" & $(e + 1) & ")? (y/n)",
    proc(c: char) =
      if c notin {'y', 'Y'}: return
      let db = loadBuffer(path)
      if db == nil: return
      var last = min(e, db.lines.high)
      if last + 1 < db.lines.len and db.lines[last + 1].strip.len == 0: inc last
      db.beginEdit()
      discard db.replaceText(Pos(line: a, col: 0), (if last + 1 < db.lines.len: Pos(line: last + 1, col: 0)
                                                     else: Pos(line: last, col: db.lines[last].len)), "")
      db.endEdit()
      db.normalize()
      info("Removed " & name))
