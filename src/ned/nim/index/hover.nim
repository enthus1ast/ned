proc nxConstValue*(f: NxFile, e: string, depth: int): string =
  ## a constant expression worked out when it is plain arithmetic on numbers and other constants (or strings
  ## joined with &); "" when it is more than that
  if depth > 6: return ""
  var toks: seq[string]
  var i = 0
  let s = e.strip
  while i < s.len:
    let c = s[i]
    if c == ' ': inc i
    elif c in Digits:
      var j = i
      while j < s.len and (s[j] in Digits + {'_', '.', 'x', 'X', 'a'..'f', 'A'..'F'}): inc j
      if j < s.len and s[j] == '\'':           # 10'i64
        inc j
        while j < s.len and s[j] in IdentChars: inc j
      toks.add s[i ..< j]
      i = j
    elif c == '"':
      var j = i + 1
      while j < s.len and s[j] != '"':
        if s[j] == '\\': inc j
        inc j
      if j >= s.len: return ""
      toks.add s[i .. j]
      i = j + 1
    elif c in {'+', '-', '*', '/', '(', ')', '&'}:
      toks.add $c
      inc i
    elif c in IdentStartChars:
      var j = i
      while j < s.len and s[j] in IdentChars: inc j
      toks.add s[i ..< j]
      i = j
    else: return ""
  var p = 0
  var sawFloat = "/" in toks
  for t in toks:
    if t.len > 0 and t[0] in Digits and not t.startsWith("0x") and not t.startsWith("0X") and
       ('.' in t or 'e' in t or 'E' in t or "'f" in t): sawFloat = true
  proc expr(): (bool, float, string, bool)        # (ok, number, string, it is a string)
  proc atom(): (bool, float, string, bool) =
    if p >= toks.len: return (false, 0.0, "", false)
    let t = toks[p]
    inc p
    if t == "(":
      result = expr()
      if p < toks.len and toks[p] == ")": inc p
      else: return (false, 0.0, "", false)
    elif t == "-":
      let a = atom()
      return (a[0] and not a[3], -a[1], "", false)
    elif t[0] == '"': return (true, 0.0, t[1 ..< ^1], true)
    elif t[0] in Digits:
      var n = t.replace("_", "")
      let q = n.find('\'')
      if q >= 0: n = n[0 ..< q]
      try:
        if n.startsWith("0x") or n.startsWith("0X"): return (true, float(parseHexInt(n)), "", false)
        return (true, parseFloat(n), "", false)
      except ValueError: return (false, 0.0, "", false)
    elif t == "true": return (true, 1.0, "true", false)
    elif t == "false": return (true, 0.0, "false", false)
    else:
      for r in nxLookup(nxScope(f), t):
        if r.sym.kind == nxConst and r.sym.value.len > 0:
          let v = nxConstValue(r.file, r.sym.value, depth + 1)
          if v.len == 0: return (false, 0.0, "", false)
          if v[0] == '"': return (true, 0.0, v[1 ..< ^1], true)
          if '.' in v or 'e' in v: sawFloat = true
          try: return (true, parseFloat(v), "", false)
          except ValueError: return (false, 0.0, "", false)
      return (false, 0.0, "", false)
  proc term(): (bool, float, string, bool) =
    result = atom()
    while result[0] and p < toks.len and toks[p] in ["*", "/", "div", "mod", "shl", "shr"]:
      let op = toks[p]
      inc p
      let r = atom()
      if not r[0] or r[3] or result[3]: return (false, 0.0, "", false)
      case op
      of "*": result[1] = result[1] * r[1]
      of "/": result[1] = (if r[1] == 0: NaN else: result[1] / r[1])
      of "div": result[1] = (if r[1] == 0: NaN else: float(int(result[1]) div int(r[1])))
      of "mod": result[1] = (if r[1] == 0: NaN else: float(int(result[1]) mod int(r[1])))
      of "shl": result[1] = float(int(result[1]) shl int(r[1]))
      of "shr": result[1] = float(int(result[1]) shr int(r[1]))
      else: discard
  proc expr(): (bool, float, string, bool) =
    result = term()
    while result[0] and p < toks.len and toks[p] in ["+", "-", "&"]:
      let op = toks[p]
      inc p
      let r = term()
      if not r[0]: return (false, 0.0, "", false)
      if op == "&":
        if not (result[3] and r[3]): return (false, 0.0, "", false)
        result[2].add r[2]
      elif result[3] or r[3]: return (false, 0.0, "", false)
      elif op == "+": result[1] = result[1] + r[1]
      else: result[1] = result[1] - r[1]
  let v = expr()
  if not v[0] or p < toks.len: return ""
  if v[3]: return "\"" & v[2] & "\""
  if v[1] != v[1]: return ""                          # (NaN: a division by zero)
  if not sawFloat and abs(v[1]) < 9.0e15 and v[1] == float(int64(v[1])): $int64(v[1])
  else: $v[1]

proc nxExpandTemplate*(f: NxFile, lines: seq[string], line, col: int): (string, string)

proc nxHover*(f: NxFile, lines: seq[string], line, col: int): string =
  let (refs, locals, modPath) = nxTargets(f, lines, line, col)
  if modPath.len > 0:
    let g = nxLoad(modPath)
    return "```nim\nmodule " & nxModuleName(modPath) & "\n```\n" &
           (if g != nil and g.doc.len > 0: nxRstToMd(g.doc) & "\n\n" else: "") & modPath
  if locals.len > 0:
    var s = locals[0]
    if s.typ.len == 0:
      let sc = nxScope(f)
      let all = nxLocals(f, lines, line, col)
      let t = nxTypeOfName(f, sc, all, s.name, line, 0)
      if t.typ.len > 0: s.typ = t.typ
    return nxDocItem(NxItem(label: s.name, kind: s.kind, local: s))
  if refs.len == 0: return ""
  var done = false
  if refs.len == 1 and refs[0].sym.kind in {nxLet, nxVar, nxConst} and refs[0].sym.typ.len == 0:
    # show the type we can work out:  let p: Person = Person(…)
    var s = refs[0].sym
    let sc = nxScope(refs[0].file)
    let t = nxTypeOfExpr(refs[0].file, sc, @[], s.value, s.line, 0)
    if t.typ.len > 0:
      let g = NxFile(path: refs[0].file.path, module: refs[0].file.module, syms: @[s])
      g.syms[0].typ = t.typ
      result = nxDoc(NxRef(file: g, idx: 0))
      done = true
  if not done:
    var it = NxItem(label: refs[0].sym.name, kind: refs[0].sym.kind, refs: refs)
    result = nxDocItem(it, 3)
  let s0 = refs[0].sym
  if s0.kind == nxConst and s0.value.len > 0:
    # a constant's value, worked out: const KiB = 4 * 1024  → 4096
    let v = nxConstValue(refs[0].file, s0.value, 0)
    if v.len > 0 and v != s0.value.strip: result = "```nim\n= " & v & "\n```\n" & result
  elif s0.kind == nxTemplate and not (refs[0].file == f and s0.line == line):
    # what this call becomes
    let (_, ex) = nxExpandTemplate(f, lines, line, col)
    if ex.len > 0:
      var ls = ex.splitLines
      if ls.len > 12: ls = ls[0 ..< 12] & @["…"]
      result.add "\n\n**Here it becomes:**\n```nim\n" & ls.join("\n") & "\n```"

proc nxDefinition*(f: NxFile, lines: seq[string], line, col: int): seq[(string, int, int, string)] =
  let (refs, locals, modPath) = nxTargets(f, lines, line, col)
  if modPath.len > 0: return @[(modPath, 0, 0, "module " & nxModuleName(modPath))]
  if locals.len > 0: return @[(f.path, locals[0].line, locals[0].col, nxSig(locals[0]))]
  for r in refs: result.add (r.file.path, r.sym.line, r.sym.col, nxSig(r.sym))


proc nxSignatureHelp*(f: NxFile, lines: seq[string], line, col: int): NxSigHelp =
  ## the call around the cursor: walk back to the unclosed `(` (also across earlier lines)
  var l = line
  var c = min(col, lines[line].len) - 1
  var depth = 0
  var commas = 0
  var guard = 0
  var found = false
  while l >= 0 and guard < 4000:
    let s = lines[l]
    if c >= s.len: c = s.high
    while c >= 0:
      let ch = s[c]
      if ch in {')', ']', '}'}: inc depth
      elif ch in {'(', '[', '{'}:
        if depth == 0:
          if ch == '(':
            found = true
            break
          else: return
        dec depth
      elif ch == ',' and depth == 0: inc commas
      elif ch == '"':
        dec c
        while c >= 0 and s[c] != '"': dec c
      dec c
      inc guard
    if found: break
    dec l
    if l < 0 or line - l > 30: return
    c = lines[l].high
  if not found: return
  let s = lines[l]
  var e = c
  while e > 0 and s[e - 1] == ' ': dec e
  var a = e
  while a > 0 and nxIsIdent(s[a - 1]): dec a
  if a == e: return
  let name = s[a ..< e]
  if name in NxKeywords: return
  let sc = nxScope(f)
  let locals = nxLocals(f, lines, line, col)
  result.active = commas
  if a > 0 and s[a - 1] == '.':
    let recv = nxReceiver(s, a - 1)
    let v = nxTypeOfExpr(f, sc, locals, recv, l, 0)
    if v.module.len == 0 and v.typeName.len == 0:
      result.ufcs = true
      result.recv = v.typ
      for r in nxLookup(sc, name):
        if r.sym.kind notin NxRoutineKinds or r.sym.params.len == 0: continue
        if v.typ.len == 0 or nxCompatP(sc, r.sym.params[0], r.sym.generics, v.typ) > 0:
          result.overloads.add r
      return
  for r in nxLookup(sc, name):
    if r.sym.kind in NxRoutineKinds: result.overloads.add r
    elif r.sym.kind == nxType:
      # an object constructor: Foo(field: …) — offer the fields as "parameters"
      var fake = r.sym
      fake.kind = nxProc
      fake.params.setLen(0)
      for fr in nxFields(sc, r.sym.name): fake.params.add NxParam(name: fr.sym.name, typ: fr.sym.typ)
      fake.ret = r.sym.name
      fake.pragmas = "ned:constructor"
      let g = NxFile(path: r.file.path, module: r.file.module, syms: @[fake])
      result.overloads.add NxRef(file: g, idx: 0)

proc nxLexRuns*(line: string, st: var NxLexState, ops: bool): seq[(int, int)] =
  ## (start, end) of every identifier on the line outside strings, characters and comments; with `ops`, of
  ## every operator instead (`+`, `==`, `..<` — and the one inside `` `+` ``)
  var i = 0
  let n = line.len
  while i < n:
    if st.inTriple:
      let e = line.find("\"\"\"", i)
      if e < 0: return
      i = e + 3
      while i < n and line[i] == '"': inc i
      st.inTriple = false
      continue
    if st.blockDepth > 0:
      if i + 1 < n and line[i] == '#' and line[i + 1] == '[':
        inc st.blockDepth
        i += 2
      elif i + 1 < n and line[i] == ']' and line[i + 1] == '#':
        dec st.blockDepth
        i += 2
      else: inc i
      continue
    let c = line[i]
    if c == '#':
      if i + 1 < n and line[i + 1] == '[':
        st.blockDepth = 1
        i += 2
      elif i + 2 < n and line[i + 1] == '#' and line[i + 2] == '[':
        st.blockDepth = 1
        i += 3
      else: return
    elif c == '"':
      if i + 2 < n and line[i + 1] == '"' and line[i + 2] == '"':
        let e = line.find("\"\"\"", i + 3)
        if e < 0:
          st.inTriple = true
          return
        i = e + 3
        while i < n and line[i] == '"': inc i
      else:
        let raw = i > 0 and line[i - 1] in {'r', 'R'}
        var j = i + 1
        while j < n and line[j] != '"':
          if line[j] == '\\' and not raw: inc j
          inc j
        i = j + 1
    elif c == '\'' and not (i > 0 and nxIsIdent(line[i - 1])):
      var j = i + 1
      if j < n and line[j] == '\\': j += 2 else: inc j
      while j < n and line[j] != '\'' and j - i < 12: inc j
      i = j + 1
    elif c in {'a'..'z', 'A'..'Z', '_'} or c >= '\x80':
      var e = i
      while e < n and nxIsIdent(line[e]): inc e
      if not ops: result.add (i, e)
      i = e
    elif c in Digits:
      let st0 = i
      while i < n and (nxIsIdent(line[i]) or line[i] == '.' or
                       (ops and line[i] in {'+', '-'} and line[i - 1] in {'e', 'E'} and
                        not (i - st0 > 1 and line[st0 + 1] in {'x', 'X'}))):     # 1.5e-3 (not 0xFE - 1)
        inc i
    elif ops and c in NxOpChars:
      var e = i
      while e < n and line[e] in NxOpChars: inc e
      result.add (i, e)
      i = e
    else: inc i

proc nxIdents*(line: string, st: var NxLexState): seq[(int, int)] = nxLexRuns(line, st, false)

proc nxSymAt*(f: NxFile, line, col: int): int =
  ## the declaration whose name stands exactly at line:col, or -1 (by line through an index: Find
  ## references asks this for every use of a name, and a big file has tens of thousands of declarations)
  if f.byLineN != f.syms.len or (f.syms.len > 0 and f.byLine.len == 0):
    f.byLine = initTable[int, seq[int]]()
    for i, s in f.syms: f.byLine.mgetOrPut(s.line, @[]).add i
    f.byLineN = f.syms.len
  for i in f.byLine.getOrDefault(line):
    let s = f.syms[i]
    if s.col <= col and col <= s.col + s.name.len and not s.made: return i
  -1
