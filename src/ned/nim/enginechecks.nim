# ── checks from ned's own Nim engine, at once while you type (no compiler): code after a return, a field or
#    proc that is not there (with the name meant), a call with too many or too few arguments, a value that is
#    neither used nor discarded, a local that is never used. Only what the engine is sure of: anything it cannot
#    tell (templates, macros, generics it does not follow, `when` branches) is left to the compiler's check, whose
#    word wins on a line where both say something ──


proc ecWordAt(s: string, i: int): (int, int) =
  ## the identifier around column i: (start, end)
  var a = i
  var e = i
  while a > 0 and nxIsIdent(s[a - 1]): dec a
  while e < s.len and nxIsIdent(s[e]): inc e
  (a, e)

proc ecCodeOnly(s: string, inTriple: var bool, inComment: var int): string =
  ## a line with its comments blanked and its strings and characters made 0s (same length): only code is looked
  ## at (inTriple: the line starts inside a """ string, and whether the next one does; inComment: how many
  ## `#[ … ]#` block comments it starts inside)
  result = s
  var i = 0
  while inComment > 0 and i < result.len:
    if result[i] == '#' and i + 1 < result.len and result[i + 1] == '[':
      inc inComment
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
    elif result[i] == ']' and i + 1 < result.len and result[i + 1] == '#':
      dec inComment
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
    else:
      result[i] = ' '
      inc i
  if inComment > 0: return
  if inTriple:
    let e = result.find("\"\"\"")
    if e < 0:
      for k in 0 ..< result.len: result[k] = '0'
      return
    for k in 0 ..< e + 3: result[k] = '0'
    i = e + 3
    inTriple = false
  while i < result.len:
    let c = result[i]
    if c == '#' and i + 1 < result.len and result[i + 1] == '[' or
       c == '#' and i + 2 < result.len and result[i + 1] == '#' and result[i + 2] == '[':
      # a block comment: to its end, maybe lines below
      var depth = 0
      var k = i
      while k < result.len:
        if result[k] == '#' and k + 1 < result.len and result[k + 1] == '[':
          inc depth
          result[k] = ' '
          result[k + 1] = ' '
          k += 2
        elif result[k] == ']' and k + 1 < result.len and result[k + 1] == '#':
          dec depth
          result[k] = ' '
          result[k + 1] = ' '
          k += 2
          if depth == 0: break
        else:
          result[k] = ' '
          inc k
      if depth > 0:
        inComment = depth
        return
      i = k
      continue
    if c == '#':
      for k in i ..< result.len: result[k] = ' '
      return
    if c == '"':
      let triple = i + 2 < result.len and result[i + 1] == '"' and result[i + 2] == '"'
      if triple:
        let e = result.find("\"\"\"", i + 3)
        if e < 0: inTriple = true
        let stop = if e < 0: result.len else: e + 3
        for k in i ..< stop: result[k] = '0'
        i = stop
        continue
      var k = i + 1
      let raw = i > 0 and (nxIsIdent(result[i - 1]))      # r"…" and call"…": no escapes
      while k < result.len and result[k] != '"':
        if result[k] == '\\' and not raw: inc k
        inc k
      for q in i .. min(k, result.high): result[q] = '0'
      result[i] = ' '                                      # (getIdent"x": the name stays a name of its own)
      i = k + 1
      continue
    if c == '\'' and i + 2 < result.len and (result[i + 2] == '\'' or (result[i + 1] == '\\' and i + 3 < result.len)):
      let e = result.find('\'', i + 1 + ord(result[i + 1] == '\\'))
      if e > i:
        for k in i .. e: result[k] = '0'
        i = e + 1
        continue
    inc i

proc ecIndent(s: string): int =
  var k = 0
  while k < s.len and s[k] == ' ': inc k
  k

proc ecUnreachable(lines: seq[string], code: seq[string], res: var seq[Diag]) =
  ## a statement after `return`, `raise`, `break`, `continue` or `quit(…)` in the same block can never run
  const Enders = ["return", "raise", "break", "continue"]
  for i in 0 ..< code.len:
    let t = code[i].strip
    if t.len == 0: continue
    var w = ""
    var k = 0
    while k < t.len and nxIsIdent(t[k]): inc k
    w = t[0 ..< k]
    if w notin Enders: continue
    # (the whole statement on this line: nothing after it continues it, nor is it inside brackets)
    var depth = 0
    for ch in t:
      if ch in {'(', '[', '{'}: inc depth
      elif ch in {')', ']', '}'}: dec depth
    if depth != 0 or t.endsWith(",") or t.endsWith("=") or t.endsWith(":") or t.endsWith("and") or
       t.endsWith("or") or t.endsWith("&") or t.endsWith("+") or t.endsWith("-"):
      continue
    let ind = ecIndent(code[i])
    var j = i + 1
    while j < code.len and code[j].strip.len == 0: inc j
    if j >= code.len: continue
    let nind = ecIndent(code[j])
    if nind > ind: continue                             # (a continuation line, or the value after `return`)
    if nind < ind: continue                             # (the block ended)
    let nt = code[j].strip
    var nk = 0
    while nk < nt.len and nxIsIdent(nt[nk]): inc nk
    let nw = nt[0 ..< nk]
    if nw in ["else", "elif", "of", "except", "finally", "when", "proc", "func", "template", "macro", "iterator",
              "method", "converter", "type", "const"] or nt.startsWith("{.") or nt.startsWith("#") or
       nt.startsWith("##"):
      continue
    res.add Diag(line: j, col: nind, eline: j, ecol: lines[j].len, sev: 3, src: "ned",
                 msg: "this code never runs: the `" & w & "` above it leaves the block first")

proc ecUnusedLocals(f: NxFile, lines: seq[string], code: seq[string], res: var seq[Diag]) =
  ## a `let`/`var` inside a routine that nothing after it mentions (style-insensitive, as Nim compares names)
  for ri in 0 ..< f.syms.len:
    let r = f.syms[ri]
    if r.kind notin {nxProc, nxFunc, nxMethod, nxIterator, nxConverter} or r.made or r.endLine <= r.line or
       r.endLine >= code.len or r.endLine - r.line > 3000:
      continue
    var counts: Table[string, int]
    for l in r.line .. r.endLine:
      let s = code[l]
      var k = 0
      while k < s.len:
        if nxIsIdent(s[k]) and (k == 0 or not nxIsIdent(s[k - 1])) and s[k] notin {'0'..'9'}:
          var e = k
          while e < s.len and nxIsIdent(s[e]): inc e
          counts.mgetOrPut(nxNorm(s[k ..< e]), 0) += 1
          k = e
        else: inc k
    # (names an emit or asm string uses: `name`)
    for l in r.line .. r.endLine:
      let raw = lines[l]
      var k = raw.find('`')
      while k >= 0:
        let e = raw.find('`', k + 1)
        if e < 0: break
        counts.mgetOrPut(nxNorm(raw[k + 1 ..< e]), 0) += 1
        k = raw.find('`', e + 1)
    # (sample code in runnableExamples: left alone)
    var examples: seq[(int, int)]
    for l in r.line .. r.endLine:
      let t = code[l].strip
      if t.startsWith("runnableExamples"):
        let ind = ecIndent(code[l])
        var e = l + 1
        while e <= r.endLine and (code[e].strip.len == 0 or ecIndent(code[e]) > ind): inc e
        examples.add (l, e - 1)
    var locals: seq[NxSym]
    try: locals = nxLocals(f, lines, r.endLine, 0, everything = true)
    except CatchableError: continue
    for v in locals:
      if v.kind notin {nxLet, nxVar} or v.line <= r.line or v.line > r.endLine or v.name.len == 0 or
         v.name == "_" or v.name.startsWith("_") or v.exported:
        continue
      # (the name written at its declaration, on that line: a pattern or a template's output is not checked)
      if v.line >= code.len or v.col < 0 or v.col + v.name.len > code[v.line].len or
         code[v.line][v.col ..< v.col + v.name.len] != v.name:
        continue
      var inExample = false
      for (a, e) in examples:
        if v.line >= a and v.line <= e: inExample = true
      var plainName = true
      for ch in v.name:
        if not nxIsIdent(ch): plainName = false
      if not inExample and plainName and counts.getOrDefault(nxNorm(v.name)) <= 1:
        res.add Diag(line: v.line, col: v.col, eline: v.line, ecol: v.col + v.name.len, sev: 4, src: "ned",
                     msg: "'" & v.name & "' is declared but not used")

proc ecMembers(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## `x.name` where the engine knows x's object type (one of this project's) and nothing is called `name`: not a
  ## field of it (or of its ancestors), no routine, template, macro or iterator of that name in scope, and the
  ## name written nowhere else in the file — a misspelling. Not in templates and macros (their names are bound
  ## where they are used), nor under `compiles(…)`
  let sc = nxScope(f)
  if sc == nil: return
  # the names written in the file other than after a dot
  var elsewhere: HashSet[string]
  for s in code:
    var k = 0
    while k < s.len:
      if nxIsIdent(s[k]) and (k == 0 or not nxIsIdent(s[k - 1])) and s[k] notin {'0'..'9'}:
        var e = k
        while e < s.len and nxIsIdent(s[e]): inc e
        if k == 0 or s[k - 1] != '.': elsewhere.incl nxNorm(s[k ..< e])
        k = e
      else: inc k
  # (a `.` operator in scope — JsObject's, a macro's — makes any name a member)
  for op in [".", ".=", ".()"]:
    if nxLookup(sc, op).len > 0: return
  var skipLines = newSeq[bool](code.len)
  for sy in f.syms:
    if sy.kind in {nxTemplate, nxMacro} and sy.endLine >= sy.line:
      for l in sy.line .. min(sy.endLine, code.high): skipLines[l] = true
  var seen = 0
  for l in 0 ..< code.len:
    let s = code[l]
    if skipLines[l] or "compiles(" in s or "declared(" in s: continue
    var k = s.find('.')
    while k > 0 and k + 1 < s.len:
      if not nxIsIdent(s[k - 1]) or not nxIsIdent(s[k + 1]) or s[k + 1] in {'0'..'9'} or
         (k + 1 < s.len and s[k + 1] == '.') or (k > 0 and s[k - 1] == '.'):
        k = s.find('.', k + 1)
        continue
      let (ma, me) = ecWordAt(s, k + 1)
      let name = s[ma ..< me]
      inc seen
      if seen > 4000: return
      # anything visible by that name, or the name used elsewhere: the call may well go to it (UFCS, templates,
      # macros, generics, a routine declared inside another)
      if nxNorm(name) in elsewhere or nxLookup(sc, name).len > 0:
        k = s.find('.', me)
        continue
      # the receiver's type, from the engine
      var typ = ""
      try:
        let (refs, locals, _) = nxTargets(f, b.lines, l, k - 1)
        if locals.len > 0:
          typ = locals[0].typ
          if typ.len == 0:
            typ = nxTypeOfName(f, sc, nxLocals(f, b.lines, l, k - 1), locals[0].name, l, 0).typ
        elif refs.len > 0 and refs[0].file != nil:
          let sy = refs[0].file.syms[refs[0].idx]
          if sy.kind in {nxLet, nxVar, nxConst, nxParam, nxField}: typ = sy.typ
      except CatchableError: discard
      let base = nxBaseName(nxStripMods(typ))
      if base.len == 0 or base[0] notin {'A'..'Z'}:     # (only the module's own object types, written out)
        k = s.find('.', me)
        continue
      let (r, def) = nxObjectDef(sc, base)
      if r.file == nil or (nxLibDir.len > 0 and r.file.path.startsWith(nxLibDir)) or
         not def.startsWith("object") and not def.startsWith("ref object") and not def.startsWith("ptr object"):
        k = s.find('.', me)
        continue
      var known = false
      for fr in nxFields(sc, base):
        if fr.file != nil and nxNorm(fr.file.syms[fr.idx].name) == nxNorm(name): known = true
      if not known:
        var meant = ""
        var best = 3
        for fr in nxFields(sc, base):
          if fr.file == nil: continue
          let fn = fr.file.syms[fr.idx].name
          let dd = nxTypoDist(nxNorm(fn), nxNorm(name))
          if dd < best:
            best = dd
            meant = fn
        # (only a near miss of one of its fields: what a typo looks like — anything else is the compiler's call)
        if meant.len > 0:
          res.add Diag(line: l, col: ma, eline: l, ecol: me, sev: 2, src: "ned",
                       msg: "'" & name & "' is not a field of " & base & " — did you mean '" & meant & "'?")
      k = s.find('.', me)

proc ecRoutineKind(sc: NxScope, name: string): int =
  ## what a name called means: 0 unknown, 1 only procs/funcs/iterators, 2 a template, macro or anything else too
  let found = nxLookup(sc, name)
  if found.len == 0: return 0
  result = 1
  for fr in found:
    if fr.file == nil or fr.file.syms[fr.idx].kind notin {nxProc, nxFunc, nxMethod, nxIterator, nxConverter}:
      return 2

proc ecArgCounts(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## `f(a, b, c)` when every routine called f in scope takes fewer or more arguments — not when any of them is a
  ## template, macro or has varargs or untyped parameters, nor when something else is called f (a variable of a
  ## proc type, a type conversion), nor when the call is given a block (`f(a): …`, `f(a) do …`), nor inside what
  ## a template or macro gets (its arguments, its block: it may rewrite them)
  let sc = nxScope(f)
  if sc == nil: return
  # (every import found: else an overload the engine cannot see may be the one called)
  # (a file another one includes sees what that one sees: not judged here)
  if nxIncluderOf(f.path).len > 0: return
  var imports = 0
  for im in f.imports:
    if im.isInclude: return
    inc imports
    if im.spec.len == 0 or nxResolve(f.path, im.spec).len == 0: return
  # (no imports at all: maybe a file included from somewhere ned does not know — only calls of its own
  # routines are judged)
  let ownOnly = imports == 0
  var skipLines = newSeq[bool](code.len)
  for sy in f.syms:
    if sy.kind in {nxTemplate, nxMacro} and sy.endLine >= sy.line:
      for l in sy.line .. min(sy.endLine, code.high): skipLines[l] = true
  # the blocks given to a call that is not a plain routine (`tests:`, `withLock(l):`, `quote do:`)
  for l in 0 ..< code.len:
    let t = code[l].strip
    if not t.endsWith(":") or t.len < 2: continue
    var k = 0
    while k < t.len and (nxIsIdent(t[k]) or t[k] == '.'): inc k
    if k == 0: continue
    var callee = t[0 ..< k]
    if '.' in callee: callee = callee[callee.rfind('.') + 1 .. ^1]
    if callee in ["if", "elif", "else", "when", "while", "for", "case", "of", "try", "except", "finally", "block",
                  "proc", "func", "iterator", "method", "converter", "template", "macro", "type", "var", "let",
                  "const", "static", "defer", "object", "enum", "tuple"]:
      continue
    if ecRoutineKind(sc, callee) != 1:
      let ind = ecIndent(code[l])
      var e = l + 1
      while e < code.len and (code[e].strip.len == 0 or ecIndent(code[e]) > ind):
        skipLines[e] = true
        inc e
  var modNames = toHashSet([nxNorm("system"), nxNorm(nxModuleName(f.path))])
  for im in f.imports:
    modNames.incl nxNorm(nxModuleName(im.spec).strip)
    if im.alias.len > 0: modNames.incl nxNorm(im.alias.strip)
  let inc = nxIncluderOf(f.path)                     # (an included file: its includer's name qualifies too)
  if inc.len > 0: modNames.incl nxNorm(nxModuleName(inc))
  var calls = 0
  for l in 0 ..< code.len:
    let s = code[l]
    if skipLines[l] or "compiles(" in s: continue
    var k = s.find('(')
    while k > 0:
      if not nxIsIdent(s[k - 1]) or s[k - 1] in {'0'..'9'}:
        k = s.find('(', k + 1)
        continue
      let (ma, me) = ecWordAt(s, k - 1)
      let name = s[ma ..< me]
      var byDot = ma > 0 and s[ma - 1] == '.' and not (ma > 1 and s[ma - 2] == '.')      # (not a..b's dots)
      var unsureRecv = byDot and ma > 1 and s[ma - 2] in NxOpChars                     # (`?.f(…)`: an operator)
      if byDot and ma > 1 and nxIsIdent(s[ma - 2]):
        let (pa, pe) = ecWordAt(s, ma - 2)
        let rw = s[pa ..< pe]
        if (pa == 0 or s[pa - 1] != '.') and (nxNorm(rw) in modNames or sc.modules.hasKey(rw)):
          unsureRecv = true          # strutils.find(…): that module's own routines — or a variable `options`
      # (first on its line after a line that ends with a dot: a method call that goes on from there)
      if not byDot and s[0 ..< ma].strip.len == 0 and l > 0 and code[l - 1].strip.endsWith("."): unsureRecv = true
      # (inside the arguments of a template, a macro or something unknown: it may rewrite them)
      var dd = 0
      var j = k - 1
      while j >= 0 and not unsureRecv:
        if s[j] in {')', ']', '}'}: inc dd
        elif s[j] in {'(', '[', '{'}:
          if dd == 0:
            if s[j] == '(' and j > 0 and nxIsIdent(s[j - 1]):
              let (oa, oe) = ecWordAt(s, j - 1)
              if ecRoutineKind(sc, s[oa ..< oe]) != 1: unsureRecv = true
          else: dec dd
        dec j
      # (a command's argument: `cmd f(x)`, the command may be a template too)
      let lead = s[0 ..< ma].strip
      if lead.len > 0 and nxIsIdent(lead[0]):
        var q = 0
        while q < lead.len and (nxIsIdent(lead[q]) or lead[q] == '.'): inc q
        if q < lead.len and lead[q] == ' ':
          var cw = lead[0 ..< q]
          if '.' in cw: cw = cw[cw.rfind('.') + 1 .. ^1]
          if cw notin ["return", "result", "discard", "yield", "raise", "echo", "if", "elif", "while", "when", "and",
                       "or", "not", "let", "var", "const", "for", "in", "case", "of", "assert", "doAssert"] and
             ecRoutineKind(sc, cw) != 1:
            unsureRecv = true
      if unsureRecv:
        k = s.find('(', k + 1)
        continue
      # the arguments, on this line only (a call over several lines is left alone)
      var d = 0
      var commas = 0
      var close = -1
      var any = false
      for j in k ..< s.len:
        let ch = s[j]
        if ch in {'(', '[', '{'}: inc d
        elif ch in {')', ']', '}'}:
          dec d
          if d == 0:
            close = j
            break
        elif ch == ',' and d == 1: inc commas
        elif d >= 1 and ch notin {' ', '\t'}: any = true
      # (not a declaration's own name: `proc value(this: …)`)
      let before = s[0 ..< ma].strip
      var declHere = false
      for kw in ["proc", "func", "iterator", "method", "converter", "template", "macro"]:
        if before == kw or before.endsWith(" " & kw): declHere = true
      if close < 0 or name.len == 0 or name[0] in {'A'..'Z'} or ma > 0 and s[ma - 1] == '`' or declHere:
        k = s.find('(', k + 1)
        continue
      let after = s[close + 1 .. ^1].strip
      if after.startsWith(":") or after.startsWith("do") or after.startsWith("="):
        k = s.find('(', close + 1)
        continue
      inc calls
      if calls > 3000: return
      let nargs = (if any: commas + 1 else: 0) + ord(byDot)
      let found = nxLookup(sc, name)
      var routines = 0
      var fits = false
      var lo = high(int)
      var hi = 0
      var unsure = found.len == 0
      for fr in found:
        if fr.file == nil or (ownOnly and fr.file.path != f.path):
          unsure = true
          continue
        let sy = fr.file.syms[fr.idx]
        if sy.kind notin {nxProc, nxFunc, nxMethod, nxIterator, nxConverter}:
          unsure = true                    # (a template, macro, variable, field, type …: not ours to judge)
          continue
        inc routines
        var need = 0
        for p in sy.params:
          if p.default.len == 0: inc need
          let t = p.typ.strip
          if t.startsWith("varargs") or t in ["untyped", "typed"] or t.startsWith("static") or t.len == 0 and
             p.default.len == 0:
            unsure = true
        if "varargs" in sy.pragmas: unsure = true          # (C's varargs: printf and friends)
        lo = min(lo, need)
        hi = max(hi, sy.params.len)
        if nargs >= need and nargs <= sy.params.len: fits = true
      # (a local routine or lambda of that name in this file: the engine may not see it)
      if not unsure and routines > 0 and not fits:
        var localDecl = false
        for l2 in 0 ..< code.len:
          if ecIndent(code[l2]) == 0: continue          # (the module's own routines: the engine has them)
          let t = code[l2].strip
          for kw in ["proc ", "func ", "iterator ", "template ", "macro ", "method ", "converter "]:
            if t.startsWith(kw) and nxNorm(t[kw.len .. ^1].strip(chars = {'`', ' '}).split({'(', '[', '*', ' ', ':', '='})[0]) == nxNorm(name):
              localDecl = true
          if ("let " & name) in t or ("var " & name) in t: localDecl = true
        if not localDecl:
          let want = if lo == hi: $lo else: $lo & " to " & $hi
          res.add Diag(line: l, col: ma, eline: l, ecol: close + 1, sev: 2, src: "ned",
                       msg: name & " takes " & want & " argument" & (if hi == 1 and lo == 1: "" else: "s") &
                            ", here " & $nargs & (if byDot: " (with the one before the dot)" else: ""))
      k = s.find('(', k + 1)

proc engineChecksFor(b: Buffer): seq[Diag] =
  ## the engine's own checks of a Nim buffer as it is now
  if b == nil or b.lang == nil or b.lang.mode != lmNim or b.lines.len > 20000 or b.largeOn: return
  let f = try: nxFileFor(b) except CatchableError: nil
  if f == nil: return
  # (system's own parts see more than ned knows)
  if nxLibDir.len > 0 and f.path.startsWith(nxLibDir / "system" & "/"): return
  let sk = f.path.find("/lib/system/")
  if sk >= 0 and fileExists(f.path[0 ..< sk] / "lib" / "system.nim"): return
  var code = newSeq[string](b.lines.len)
  var inTriple = false
  var inComment = 0
  for i, l in b.lines: code[i] = ecCodeOnly(l, inTriple, inComment)
  # (inside a `when` branch the engine leaves out, nothing is checked)
  try:
    ecUnreachable(b.lines, code, result)
    ecUnusedLocals(f, b.lines, code, result)
    ecMembers(f, b, code, result)
    ecArgCounts(f, b, code, result)
  except CatchableError, Defect: discard
  var keep: seq[Diag]
  for d in result:
    var inactive = false
    for (a, e) in f.inactive:
      if d.line >= a and d.line <= e: inactive = true
    if not inactive: keep.add d
  keep
