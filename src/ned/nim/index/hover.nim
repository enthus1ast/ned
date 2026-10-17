proc nxConstValue*(f: NxFile, e: string, depth: int): string =
  ## a constant expression's value as the compiler would work it out (nxCtEval), "" when the index cannot tell
  nxCtRender(nxCtEval(f, e, depth))

proc nxPlatformWords(): string =
  ## what `defined(…)` answers for: the system and CPU ned runs on (and the project's -d: once `nim dump` told)
  var ws: seq[string]
  for w in ["linux", "android", "macosx", "windows", "freebsd", "openbsd", "netbsd", "amd64", "arm64", "i386", "arm",
            "riscv64"]:
    if w in nxDefines: ws.add w
  ws.join(", ")

proc nxWhenHover*(f: NxFile, lines: seq[string], line, col: int): string =
  ## on a `when` / `elif` line's keyword, or on defined / declared anywhere: the condition's value, here
  if line >= lines.len: return
  let raw = lines[line]
  let t = raw.strip(trailing = false)
  let ind = raw.len - t.len
  var a = min(col, raw.len)
  while a > 0 and nxIsIdent(raw[a - 1]): dec a
  var e = a
  while e < raw.len and nxIsIdent(raw[e]): inc e
  let w = raw[a ..< e]
  var cond = ""
  var shown = ""
  if (t.startsWith("when ") or t.startsWith("elif ")) and (a == ind or w in ["defined", "declared", "not", "and", "or"]):
    var c = t[5 .. ^1]
    let h = c.find(" #")
    if h >= 0: c = c[0 ..< h]
    c = c.strip
    if c.endsWith(":"): c = c[0 ..< ^1].strip
    else:
      let k = c.rfind(':')            # when x: stmt  (on one line)
      if k > 0: c = c[0 ..< k].strip
    cond = c
    shown = t[0 ..< 5] & c
  elif w in ["defined", "declared"] and e < raw.len and raw[e] == '(':
    let close = raw.find(')', e)
    if close < 0: return
    cond = raw[a .. close]
    shown = cond
  else: return
  let v = nxCtEval(f, cond)
  if v.kind != ctBool:
    if v.kind != ctNone: return "```nim\n" & shown & "\n```\n= `" & nxCtRender(v) & "`"
    if v.err.len > 0: return "```nim\n" & shown & "\n```\n**a compile error:** " & v.err
    return
  let here = nxPlatformWords()
  result = "```nim\n" & shown & "\n```\n= **" & (if v.i != 0: "true" else: "false") & "** here" &
           (if here.len > 0: " (" & here & (if nxDefinesComplete: ", and the project's -d: defines" else: "") & ")"
            else: "") &
           (if t.startsWith("when ") or t.startsWith("elif "):
              (if v.i != 0: " — this branch is compiled" else: " — this branch is left out")
            else: "")

proc nxExpandTemplate*(f: NxFile, lines: seq[string], line, col: int): (string, string)

proc nxCallInstance*(f: NxFile, lines: seq[string], line, col: int, s: NxSym): string =
  ## a generic routine at a call: its signature with the generic parameters bound from the arguments written
  ## there — `max(x: int, y: int): int   (T = int)` — or "" when it is not a call or nothing can be bound
  let names = nxGenericNames(s.generics)
  if names.len == 0 or line >= lines.len: return
  let t = lines[line]
  var a = min(col, t.len)
  while a > 0 and nxIsIdent(t[a - 1]): dec a
  var e = a
  while e < t.len and nxIsIdent(t[e]): inc e
  if e == a: return
  let sc = nxScope(f)
  let locals = nxLocals(f, lines, line, col)
  var argTypes: seq[string]
  if a > 0 and t[a - 1] == '.':
    argTypes.add nxTypeOfExpr(f, sc, locals, nxReceiver(t, a - 1), line, 0).typ     # x.name(…): x is the first
  var q = e
  var genArgs: seq[string]
  if q < t.len and t[q] == '[':
    let c = nxMatchClose(t, q)
    if c < 0: return
    for g in nxSplitTop(t[q + 1 ..< c], {','}): genArgs.add g.strip
    q = c + 1
  if q < t.len and t[q] == '(':
    let c = nxMatchClose(t, q)
    if c < 0: return
    if c > q + 1:
      for part in nxSplitTop(t[q + 1 ..< c], {','}):
        let x = part.strip
        argTypes.add (if x.len == 0 or nxFindTop(x, '=') >= 0: "" else: nxTypeOfExpr(f, sc, locals, x, line, 0).typ)
  elif argTypes.len == 0 and genArgs.len == 0: return
  var binds: Table[string, string]
  if genArgs.len > 0:
    for i in 0 ..< min(names.len, genArgs.len): binds[names[i]] = genArgs[i]
  else:
    for i, at in argTypes:
      if at.len == 0 or i >= s.params.len: continue
      nxUnify(s.params[i].typ, at, names, binds)
  if binds.len == 0: return
  result = s.name & "("
  for i, p in s.params:
    if i > 0: result.add ", "
    result.add p.name
    if p.typ.len > 0: result.add ": " & nxSubst(p.typ, binds)
    elif p.default.len > 0: result.add " = " & p.default
  result.add ")"
  if s.ret.len > 0: result.add ": " & nxSubst(s.ret, binds)
  var bs: seq[string]
  for n in names:
    if n in binds: bs.add n & " = " & binds[n]
  result.add "   (" & bs.join(", ") & ")"

proc nxHover*(f: NxFile, lines: seq[string], line, col: int): string =
  let wv = nxWhenHover(f, lines, line, col)
  let f = nxAt(f, lines, line)
  if wv.len > 0: return wv
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
  if s0.kind in NxRoutineKinds and s0.generics.len > 0 and not (refs[0].file == f and s0.line == line):
    # a generic routine called here: what it is for these arguments
    let here = nxCallInstance(f, lines, line, col, s0)
    if here.len > 0: result.add "\n\n**Here:** `" & here & "`"
  if s0.kind == nxConst and s0.value.len > 0:
    # a constant's value, worked out: const KiB = 4 * 1024  → 4096 (or the compile error it is: high(int8) + 1)
    let cv = nxCtEval(refs[0].file, s0.value, 0)
    let v = nxCtRender(cv)
    if v.len > 0 and v != s0.value.strip: result = "```nim\n= " & v & "\n```\n" & result
    elif cv.err.len > 0: result = "**a compile error:** " & cv.err & "\n\n" & result
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
  let f = nxAt(f, lines, line)
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
