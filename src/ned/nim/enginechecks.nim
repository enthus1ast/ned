# ── checks from ned's own Nim engine, at once while you type (no compiler): code after a return, a field or
#    proc that is not there (with the name meant), a call with too many or too few arguments, a value that is
#    neither used nor discarded, a local that is never used. Only what the engine is sure of: anything it cannot
#    tell (templates, macros, generics it does not follow, `when` branches) is left to the compiler's check, whose
#    word wins on a line where both say something ──


func ecWordAt(s: string, i: int): (int, int) =
  ## the identifier around column i: (start, end)
  var a = i
  var e = i
  while a > 0 and nxIsIdent(s[a - 1]): dec a
  while e < s.len and nxIsIdent(s[e]): inc e
  (a, e)

func ecCodeOnly(s: string, inTriple: var bool, inComment: var int): string =
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

func ecIndent(s: string): int =
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
    res.add Diag(line: j, col: nind, eline: j, ecol: lines[j].len, sev: 3, src: "ned", rule: "unreachable",
                 msg: "this code never runs: the `" & w & "` above it leaves the block first")

proc ecBraceNames(raw: string, counts: var Table[string, int]) =
  ## the names inside `{…}` on a line, strings included: what fmt"…", &"…" and the like interpolate (`{who}`,
  ## `{n:>3}`, `{x=}`) is a use the code-only text does not show
  var k = raw.find('{')
  while k >= 0:
    let e = raw.find('}', k + 1)
    if e < 0: break
    var q = k + 1
    while q < e:
      if nxIsIdent(raw[q]) and (q == k + 1 or not nxIsIdent(raw[q - 1])) and raw[q] notin {'0'..'9'}:
        var z = q
        while z < e and nxIsIdent(raw[z]): inc z
        counts.mgetOrPut(nxNorm(raw[q ..< z]), 0) += 1
        q = z
      else: inc q
    k = raw.find('{', e + 1)

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
    # (names an emit or asm string uses: `name`; a string's last lines may be past the routine's end)
    var se = r.endLine
    while se + 1 < code.len and code[se + 1].strip(chars = {' ', '\t', '0'}).len == 0 and lines[se + 1].strip.len > 0:
      inc se                                     # (a string's text is 0s in the code-only lines)
    for l in r.line .. se:
      let raw = lines[l]
      var k = raw.find('`')
      while k >= 0:
        let e = raw.find('`', k + 1)
        if e < 0: break
        counts.mgetOrPut(nxNorm(raw[k + 1 ..< e]), 0) += 1
        k = raw.find('`', e + 1)
      ecBraceNames(raw, counts)                             # (names a format string interpolates: {who})
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
                     rule: "unused-local", msg: "'" & v.name & "' is declared but not used")

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
          res.add Diag(line: l, col: ma, eline: l, ecol: me, sev: 2, src: "ned", rule: "field-typo",
                       msg: "'" & name & "' is not a field of " & base & " — did you mean '" & meant & "'?")
      k = s.find('.', me)

func ecStmtStart(s: string, k: int, start = 0): int =
  ## where the statement holding column k starts on its line (or after column `start`, an opening bracket's
  ## inside): after the last `:` or `;` outside brackets before it (`if c: inc x`, `of 'a': x.add 1`,
  ## `a = 1; inc x`), else `start`
  result = start
  var d = 0
  for j in start ..< min(k, s.len):
    let c = s[j]
    if c in {'(', '[', '{'}: inc d
    elif c in {')', ']', '}'}: dec d
    elif d == 0 and (c == ';' or c == ':' and j + 1 < s.len and s[j + 1] == ' '): result = j + 1

proc ecRoutineKind(sc: NxScope, name: string): int =
  ## what a name called means: 0 unknown, 1 only procs/funcs/iterators, 2 a template, macro or anything else too
  let found = nxLookup(sc, name)
  if found.len == 0: return 0
  result = 1
  for fr in found:
    if fr.file == nil or fr.file.syms[fr.idx].kind notin {nxProc, nxFunc, nxMethod, nxIterator, nxConverter}:
      return 2

proc ecImportsKnown(f: NxFile): int =
  ## how many modules the file imports, every one found (-1: one is not found, or the file includes others or is
  ## included itself — an overload or a name the engine cannot see may be the one meant)
  if nxIncluderOf(f.path).len > 0: return -1
  for im in f.imports:
    if im.isInclude or im.spec.len == 0 or nxResolve(f.path, im.spec).len == 0: return -1
    inc result

proc ecSkipLines(f: NxFile, sc: NxScope, code: seq[string]): seq[bool] =
  ## the lines a template or macro may rewrite: their own bodies, and the blocks given to a call that is not a
  ## plain routine (`tests:`, `withLock(l):`, `quote do:`)
  result = newSeq[bool](code.len)
  for sy in f.syms:
    if sy.kind in {nxTemplate, nxMacro} and sy.endLine >= sy.line:
      for l in sy.line .. min(sy.endLine, code.high): result[l] = true
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
        result[e] = true
        inc e

proc ecLocalDecl(code: seq[string], name: string): bool =
  ## a routine, lambda or variable of that name declared inside a routine of the file (the engine may not see it)
  for l2 in 0 ..< code.len:
    if ecIndent(code[l2]) == 0: continue          # (the module's own routines: the engine has them)
    let t = code[l2].strip
    for kw in ["proc ", "func ", "iterator ", "template ", "macro ", "method ", "converter "]:
      if t.startsWith(kw) and nxNorm(t[kw.len .. ^1].strip(chars = {'`', ' '}).split({'(', '[', '*', ' ', ':', '='})[0]) == nxNorm(name):
        return true
    if ("let " & name) in t or ("var " & name) in t: return true

proc ecArgCounts(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =  # ned: ignore[unused-param]
  ## `f(a, b, c)` when every routine called f in scope takes fewer or more arguments — not when any of them is a
  ## template, macro or has varargs or untyped parameters, nor when something else is called f (a variable of a
  ## proc type, a type conversion), nor when the call is given a block (`f(a): …`, `f(a) do …`), nor inside what
  ## a template or macro gets (its arguments, its block: it may rewrite them)
  let sc = nxScope(f)
  if sc == nil: return
  # (every import found: else an overload the engine cannot see may be the one called)
  let imports = ecImportsKnown(f)
  if imports < 0: return
  # (no imports at all: maybe a file included from somewhere ned does not know — only calls of its own
  # routines are judged)
  let ownOnly = imports == 0
  let skipLines = ecSkipLines(f, sc, code)
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
        if rw.len > 0 and rw[0] in {'A' .. 'Z'} and (pa == 0 or s[pa - 1] != '.'):
          unsureRecv = true          # (Type.new(…), Type.init(…): constructors, often many overloads)
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
      let lead = s[ecStmtStart(s, ma) ..< ma].strip
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
        if not ecLocalDecl(code, name):
          let want = if lo == hi: $lo else: $lo & " to " & $hi
          res.add Diag(line: l, col: ma, eline: l, ecol: close + 1, sev: 2, src: "ned", rule: "arg-count",
                       msg: name & " takes " & want & " argument" & (if hi == 1 and lo == 1: "" else: "s") &
                            ", here " & $nargs & (if byDot: " (with the one before the dot)" else: ""))
      k = s.find('(', k + 1)

proc ecDiscarded(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## a statement that is a call `f(a, b)` of a routine that gives a value — every routine of that name taking that
  ## many arguments does, none is {.discardable.}: Nim wants the value used or discarded. Not the last statement of
  ## a block (it may be the block's value), not a call over several lines, not in templates and macros or what
  ## they are given
  let sc = nxScope(f)
  if sc == nil: return
  let imports = ecImportsKnown(f)
  if imports < 0: return
  let ownOnly = imports == 0
  let skip = ecSkipLines(f, sc, code)
  var depth = 0                                      # (brackets the lines above leave open)
  var n = 0
  for l in 0 ..< code.len:
    let s = code[l]
    let open = depth
    for ch in s:
      if ch in {'(', '[', '{'}: inc depth
      elif ch in {')', ']', '}'}: dec depth
    if depth < 0: depth = 0
    if open != 0 or skip[l]: continue
    let t = s.strip
    if t.len < 3 or t[^1] != ')' or t[0] notin IdentStartChars: continue
    var e = 0
    while e < t.len and t[e] in IdentChars: inc e
    if e >= t.len or t[e] != '(': continue
    let name = t[0 ..< e]
    if name[0] in {'A' .. 'Z'} or name in ["if", "elif", "while", "when", "case", "of", "return", "discard", "yield",
                                           "raise", "echo", "assert", "doAssert", "result", "defer", "static"]:
      continue
    # the call is the whole statement: its `(` closes at the end
    var d = 0
    var close = -1
    var commas = 0
    var any = false
    for j in e ..< t.len:
      let ch = t[j]
      if ch in {'(', '[', '{'}: inc d
      elif ch in {')', ']', '}'}:
        dec d
        if d == 0:
          close = j
          break
      elif ch == ',' and d == 1: inc commas
      elif d >= 1 and ch notin {' ', '\t'}: any = true
    if close != t.high: continue
    # (the line before goes on into this one: part of an expression)
    var pl = l - 1
    while pl >= 0 and code[pl].strip.len == 0: dec pl
    if pl >= 0:
      let pt = code[pl].strip
      if pt.len > 0 and (pt[^1] in NxOpChars + {',', '(', '[', '{'} and not pt.endsWith(":") or
                         pt.endsWith(" and") or pt.endsWith(" or") or pt.endsWith(" not") or pt.endsWith(" in") or
                         pt.endsWith(" of") or pt.endsWith(" div") or pt.endsWith(" mod") or pt.endsWith(" xor")):
        continue
      if pt.endsWith(":") and (pt.endsWith("=:") or "= " in pt and (" if " in pt or " case " in pt or "try:" in pt or
                                                                     "block:" in pt)):
        continue
    # (the last statement of its block may be the block's value: not judged)
    let ind = ecIndent(code[l])
    var nl = l + 1
    while nl < code.len and code[nl].strip.len == 0: inc nl
    if nl >= code.len or ecIndent(code[nl]) != ind: continue
    let nt = code[nl].strip
    var nk = 0
    while nk < nt.len and nxIsIdent(nt[nk]): inc nk
    if nt[0 ..< nk] in ["else", "elif", "of", "except", "finally"]: continue
    inc n
    if n > 3000: return
    let nargs = if any: commas + 1 else: 0
    let found = nxLookup(sc, name)
    if found.len == 0: continue
    var fitting = 0
    var unsure = false
    var gives = ""
    for fr in found:
      if fr.file == nil or (ownOnly and fr.file.path != f.path):
        unsure = true
        break
      let sy = fr.file.syms[fr.idx]
      if sy.kind notin {nxProc, nxFunc, nxMethod, nxConverter}:
        unsure = true                      # (a template, macro, iterator, variable …: not judged here)
        break
      var need = 0
      for p in sy.params:
        if p.default.len == 0: inc need
        let pt = p.typ.strip
        if pt.startsWith("varargs") or pt in ["untyped", "typed"] or pt.startsWith("static") or pt.len == 0 and
           p.default.len == 0:
          unsure = true
      if "varargs" in sy.pragmas: unsure = true
      if nargs < need or nargs > sy.params.len: continue
      inc fitting
      let r = sy.ret.strip
      if r.len == 0 or r == "void" or "discardable" in sy.pragmas:
        unsure = true                      # (one of them gives nothing: it may be the one called)
      elif r in ["auto", "untyped", "typed"] or r in nxGenericNames(sy.generics) or r.startsWith("owned"):
        unsure = true
      else: gives = r
    if unsure or fitting == 0 or gives.len == 0 or ecLocalDecl(code, name): continue
    let line = b.lines[l]
    let call = line[ind ..< min(line.len, ind + t.len)]
    res.add Diag(line: l, col: ind, eline: l, ecol: ind + t.len, sev: 2, src: "ned", rule: "discarded",
                 msg: "expression '" & call & "' is of type '" & gives & "' and has to be used (or discarded)")

func ecLiteralKind(v, code: string): string =
  ## the type of a value that is only a literal ("" for anything else): string, int, float, char or bool
  if v.len >= 2 and v[0] == '"' and v[^1] == '"' and not v.startsWith("\"\"\""):
    # (the whole value one string: in the code it is blanked to its end)
    for k in 1 ..< code.len:
      if code[k] != '0': return ""
    return "string"
  if v.len >= 3 and v[0] == '\'' and v[^1] == '\'' and (v.len == 3 or v.len == 4 and v[1] == '\\'): return "char"
  if v in ["true", "false"]: return "bool"
  var k = 0
  if k < v.len and v[k] == '-': inc k
  if k >= v.len or v[k] notin {'0' .. '9'}: return ""
  if v.len > k + 1 and v[k] == '0' and v[k + 1] in {'x', 'X', 'o', 'b', 'B'}: return ""   # (hex: may be a float's bits)
  var dot = false
  var ex = false
  while k < v.len:
    let c = v[k]
    if c in {'0' .. '9', '_'}: discard
    elif c == '.' and not dot and not ex and k + 1 < v.len and v[k + 1] in {'0' .. '9'}: dot = true
    elif c in {'e', 'E'} and not ex:
      ex = true
      if k + 1 < v.len and v[k + 1] in {'+', '-'}: inc k
    else: return ""                       # (a suffix — 1'u8, 2.0'f32 — or anything else: not judged)
    inc k
  if dot or ex: "float" else: "int"

proc ecLiteralTypes(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## `let x: int = "text"`: a declared type and a literal that can never be one (no converter in scope)
  const Ints = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64"]
  const Floats = ["float", "float32", "float64"]
  let sc = nxScope(f)
  if sc == nil or ecImportsKnown(f) < 0: return
  var convertsTo: HashSet[string]            # (what the converters in scope give: a literal may become one of those)
  for r in sc.refs:
    if r.file != nil and r.file.syms[r.idx].kind == nxConverter:
      let sy = r.file.syms[r.idx]
      let rt = nxBaseName(sy.ret)
      if rt.len == 0 or rt in nxGenericNames(sy.generics): return
      convertsTo.incl rt
  var n = 0
  for l in 0 ..< code.len:
    let s = code[l]
    let c = s.find(": ")
    if c <= 0: continue
    let eq = s.find(" = ", c)
    if eq < 0: continue
    let typ = s[c + 2 ..< eq].strip
    if typ notin Ints and typ notin Floats and typ notin ["string", "cstring", "char", "bool"]: continue
    # the name before the colon, alone (after let/var/const, or in a section or an object)
    var head = s[0 ..< c].strip
    var kw = ""
    for k in ["let ", "var ", "const "]:
      if head.startsWith(k):
        kw = k
        head = head[k.len .. ^1].strip
    if head.endsWith("*"): head = head[0 ..< ^1]
    if head.len == 0 or not head.validIdentifier: continue
    if kw.len == 0:
      # (in a let/var/const section or an object: the line that opens it)
      let ind = ecIndent(s)
      if ind == 0: continue
      var o = l - 1
      while o >= 0 and (code[o].strip.len == 0 or ecIndent(code[o]) >= ind): dec o
      if o < 0: continue
      let ot = code[o].strip
      if ot notin ["let", "var", "const"] and not (ot.endsWith("object") or " object of " in ot or "= object" in ot):
        continue
    # the value: from the line as written, up to where the code ends (a comment after it left out)
    var vStart = eq + 3
    while vStart < s.len and s[vStart] == ' ' and (vStart >= b.lines[l].len or b.lines[l][vStart] == ' '): inc vStart
    var vEnd = s.len
    while vEnd > vStart and s[vEnd - 1] == ' ': dec vEnd
    let line = b.lines[l]
    if vEnd > line.len or vEnd <= vStart: continue
    let v = line[vStart ..< vEnd]
    let lit = ecLiteralKind(v, s[vStart ..< vEnd])
    if lit.len == 0: continue
    let fits = case lit
      of "string": typ in ["string", "cstring"]
      of "int": typ in Ints or typ in Floats
      of "float": typ in Floats
      of "char": typ == "char"
      else: typ == "bool"
    if fits or typ in convertsTo: continue
    # (a type of that name made in this project: not the system's)
    var own = false
    for r in nxLookup(sc, typ):
      if r.file != nil and r.file.syms[r.idx].kind == nxType and not r.file.path.startsWith(nxLibDir): own = true
    if own: continue
    inc n
    if n > 200: return
    res.add Diag(line: l, col: vStart, eline: l, ecol: vStart + v.len, sev: 2, src: "ned", rule: "literal-type",
                 msg: "type mismatch: got '" & (if lit == "float": "float64" elif lit == "int": "int literal(" & v & ")" else: lit) & "' for '" & v &
                      "' but expected '" & typ & "'")

var ecModMarked: Table[string, (string, bool)]    # module file → (its stamp, says {.used.} or hides declarations)

proc ecTypeWords(t: string, into: var HashSet[string]) =
  ## the names in a type as written (Table[string, Time] → table, string, time)
  var i = 0
  while i < t.len:
    if t[i] in IdentStartChars:
      var e = i
      while e < t.len and t[e] in IdentChars: inc e
      into.incl nxNorm(t[i ..< e])
      i = e
    else: inc i

proc ecUnusedImports(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## `import x` (at the top of the file) when nothing x declares is named anywhere in the file — not in code, not
  ## in strings (fmt"{…}"), not in comments — nor x itself, and nothing of x can be called without its name being
  ## written: x's `$`, `==`, `items`, `contains` … for a type of its own that no other import's declarations
  ## mention (so no value of it can be here), no converter. Not when the file exports anything or is included, nor
  ## when x says {.used.}
  if ecImportsKnown(f) < 0: return
  const Always = ["toJson", "fromJson", "parseHook", "dumpHook", "enumHook", "renameHook", "newHook", "postHook",
                  "skipHook", ".", ".=", ".()", "()"]
  const ByValue = ["$", "==", "<", "<=", "cmp", "hash", "items", "mitems", "pairs", "mpairs", "fields", "fieldPairs",
                   "[]", "[]=", "{}", "{}=", "contains"]
  const Basic = ["string", "cstring", "int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32",
                 "uint64", "float", "float32", "float64", "char", "bool", "seq", "array", "openArray", "set",
                 "varargs", "tuple", "byte", "Natural", "Positive", "pointer", "range", "proc", "UncheckedArray"]
  # (a file of imports alone is meant to be included, or gathers them for others)
  var other = false
  for l in 0 ..< code.len:
    let t = code[l].strip
    if t.len == 0 or ecIndent(code[l]) > 0 or t.startsWith("import ") or t == "import" or t.startsWith("from ") or
       t.startsWith("include ") or t.startsWith("{."):
      continue
    other = true
    break
  if not other: return
  # every word and operator of the file, outside the import lines
  var words: HashSet[string]
  var importLines: seq[int]
  var usesIn = false                       # (`a in b` outside a for loop: contains)
  for im in f.imports: importLines.add im.line
  for l in 0 ..< b.lines.len:
    let s = b.lines[l]
    let t = code[l].strip
    if t.startsWith("export ") or t == "export": return                 # (what it exports: maybe x's)
    if l in importLines or (t.startsWith("import ") or t.startsWith("from ")) and ecIndent(code[l]) == 0: continue
    if (" in " in t or " notin " in t) and not t.startsWith("for ") or t.startsWith("for ") and t.count(" in ") > 1:
      usesIn = true
    var i = 0
    while i < s.len:
      if s[i] in IdentStartChars:
        var e = i
        while e < s.len and s[e] in IdentChars: inc e
        words.incl nxNorm(s[i ..< e])
        i = e
      elif s[i] in NxOpChars:
        var e = i
        while e < s.len and s[e] in NxOpChars: inc e
        words.incl s[i ..< e]
        i = e
      else: inc i
  # the words inside generic routines, templates and macros: a name there is looked up among every import's
  # overloads (an open choice), which counts each of them as used — and what is called without being written
  var inGeneric: HashSet[string]
  for sy in f.syms:
    if sy.kind notin NxRoutineKinds or sy.endLine <= sy.line: continue
    var generic = sy.generics.len > 0 or sy.kind in {nxTemplate, nxMacro}
    for p in sy.params:
      let pt = p.typ.strip
      if pt in ["auto", "typed", "untyped", "typedesc", "seq", "openArray", "set", "array", "proc", "tuple", "object",
                "enum", "range", "distinct", "ref", "ptr"] or pt.startsWith("Some") or " | " in pt or
         pt.startsWith("typedesc") or pt.startsWith("static") or pt.startsWith("varargs[typed") or
         pt.startsWith("varargs[untyped"):
        generic = true
    if not generic: continue
    for l in sy.line + 1 .. min(sy.endLine, b.lines.high):
      let t = b.lines[l]
      var i = 0
      while i < t.len:
        if t[i] in IdentStartChars:
          var e = i
          while e < t.len and t[e] in IdentChars: inc e
          inGeneric.incl nxNorm(t[i ..< e])
          i = e
        elif t[i] in NxOpChars:
          var e = i
          while e < t.len and t[e] in NxOpChars: inc e
          inGeneric.incl t[i ..< e]
          i = e
        else:
          if t[i] == '[':
            inGeneric.incl "[]"
            inGeneric.incl "[]="
          elif t[i] == '{':
            inGeneric.incl "{}"
            inGeneric.incl "{}="
          inc i
  if "echo" in inGeneric or "fmt" in inGeneric or "&" in inGeneric or "add" in inGeneric: inGeneric.incl "$"
  if "in" in inGeneric or "notin" in inGeneric: inGeneric.incl "contains"
  if "for" in inGeneric:
    for w in ["items", "pairs", "mitems", "mpairs", "fields", "fieldPairs"]: inGeneric.incl w
  if "sort" in inGeneric or "sorted" in inGeneric or "max" in inGeneric or "min" in inGeneric:
    for w in ["cmp", "<", "<=", "=="]: inGeneric.incl w
  if "find" in inGeneric or "contains" in inGeneric: inGeneric.incl "=="
  # what each import offers
  type Offer = object
    path, modName: string
    line: int
    refs: seq[NxRef]
    seen: HashSet[string]
  var offers: seq[Offer]
  for im in f.imports:
    if im.isInclude: continue
    let path = nxResolve(f.path, im.spec)
    if path.len == 0 or path == f.path: continue
    var o = Offer(path: path, line: im.line,
                  modName: if im.alias.len > 0: im.alias.strip else: nxModuleName(im.spec).strip)
    nxExports(path, 0, o.seen, o.refs)
    offers.add o
  for k, o in offers:
    if o.line >= code.len or ecIndent(code[o.line]) != 0: continue
    let t = code[o.line].strip
    if not t.startsWith("import "): continue                            # (from x import y: the names it lists)
    if nxNorm(o.modName) in words or o.refs.len == 0: continue          # (x.name)
    # (the parts Nim 2 took out of system, imported for nimPreviewSlimSystem: the compiler does not count them)
    if o.modName in ["assertions", "syncio", "formatfloat", "objectdollar", "widestrs", "typedthreads", "sysatomics",
                     "exitprocs", "dollars", "repr_v2"]:
      continue
    var own: HashSet[string]                                            # x's own types
    for r in o.refs:
      if r.file != nil and r.file.syms[r.idx].kind == nxType: own.incl nxNorm(r.file.syms[r.idx].name)
    var others: HashSet[string] = initHashSet[string]()                 # what the other imports' declarations name
    var othersMade = false
    template reachable(bt: string): bool =
      # can a value of this type be here without its name written? (x's own type: only if another import's
      # declarations mention it — its procs return one, its objects hold one)
      if nxNorm(bt) notin own: true
      else:
        if not othersMade:
          othersMade = true
          for k2, o2 in offers:
            if k2 == k: continue
            for r2 in o2.refs:
              if r2.file == nil: continue
              let s2 = r2.file.syms[r2.idx]
              ecTypeWords(s2.typ, others)
              ecTypeWords(s2.ret, others)
              for p in s2.params: ecTypeWords(p.typ, others)
        nxNorm(bt) in others
    var used = false
    var unsure = false
    for r in o.refs:
      if r.file == nil: continue
      let sy = r.file.syms[r.idx]
      let isOp = sy.name.len > 0 and sy.name[0] in NxOpChars
      if not isOp and nxNorm(sy.name) in words or sy.name in inGeneric or nxNorm(sy.name) in inGeneric:
        used = true
        break
      if isOp and sy.name in words:
        # (an operator written here — `*` is everywhere — is x's only if it can take what is here)
        var possible = true
        for p in sy.params:
          let bt = nxBaseName(p.typ)
          if bt.len > 0 and bt notin nxGenericNames(sy.generics) and nxNorm(bt) in own and not reachable(bt):
            possible = false
        if possible:
          used = true
          break
      if sy.kind == nxType:
        # (its fields and enum values: names written after a dot)
        for fs in r.file.syms:
          if fs.owner == sy.name and fs.exported and nxNorm(fs.name) in words: used = true
        if used: break
      if sy.kind == nxConverter or sy.name in Always:
        unsure = true
        break
      if sy.name in ByValue and sy.params.len > 0 and sy.kind in NxRoutineKinds:
        # called for a value of its first parameter's type: can there be one here?
        let bt = nxBaseName(sy.params[0].typ)
        if bt.len == 0 or bt in nxGenericNames(sy.generics) or bt in ["auto", "untyped", "typed", "typedesc", "T"]:
          unsure = true
        elif bt in Basic:
          if sy.name != "contains" or usesIn: unsure = true
        elif nxNorm(bt) notin own: unsure = true                        # (another module's type)
        elif reachable(bt): unsure = true
        if unsure: break
    if used or unsure: continue
    # (a module that says it is used, or does something just by being imported)
    # (or declares more than the engine reads: a block given to a call at the top, `since (1, 4):` …)
    var marked = false
    for fp in o.seen:
      let st = nxStamp(fp)
      let known = ecModMarked.getOrDefault(fp, ("", false))
      if st.len > 0 and known[0] == st:
        if known[1]: marked = true
        continue
      let before = marked
      marked = false
      try:
        let txt = readFile(fp)
        if "{.used.}" in txt or "{.used, " in txt or "addQuitProc" in txt or "addExitProc" in txt or
           "{.passl" in txt.toLowerAscii or "{.passc" in txt.toLowerAscii:
          marked = true
        var tr = false
        var cm = 0
        for ln in txt.splitLines:
          if marked: break
          let c = ecCodeOnly(ln, tr, cm)
          if c.len == 0 or c[0] notin IdentStartChars: continue
          let ct = c.strip
          if not ct.endsWith(":"): continue
          var e = 0
          while e < ct.len and ct[e] in IdentChars: inc e
          if ct[0 ..< e] notin ["when", "if", "elif", "else", "for", "while", "case", "of", "block", "try", "except",
                                "finally", "type", "const", "let", "var", "proc", "func", "template", "macro",
                                "iterator", "method", "converter", "static", "import", "export", "include", "from",
                                "runnableExamples", "using"]:
            marked = true
      except CatchableError: marked = true
      ecModMarked[fp] = (st, marked)
      marked = marked or before
    if marked: continue
    let line = b.lines[o.line]
    var col = line.find(o.modName)
    if col < 0: col = 0
    res.add Diag(line: o.line, col: col, eline: o.line, ecol: col + o.modName.len, sev: 2, src: "ned",
                 rule: "unused-import", msg: "imported and not used: '" & o.modName & "'")

# ── a var that never changes, a parameter never used, a result never set, a deprecated name, an API newer than
#    the Nim the package asks for ──

const EcAssignOps = ["=", "+=", "-=", "*=", "/=", "&=", "@=", "|=", "^=", "%=", "<<=", ">>=", "div=", "mod=", "and=",
                     "or=", "xor=", "shl=", "shr="]

func ecSkipChain(s: string, k: int): int =
  ## past `.name`, `[…]` and `{…}` after a name: where what follows the whole place begins
  var j = k
  while true:
    var q = j
    while q < s.len and s[q] == ' ': inc q
    if q < s.len and s[q] == '.' and q + 1 < s.len and nxIsIdent(s[q + 1]):
      inc q
      while q < s.len and nxIsIdent(s[q]): inc q
      j = q
    elif q < s.len and s[q] in {'[', '{'} and q == j:
      var d = 0
      while q < s.len:
        if s[q] in {'[', '{', '('}: inc d
        elif s[q] in {']', '}', ')'}:
          dec d
          if d == 0:
            inc q
            break
        inc q
      j = q
    else: return j

func ecAssignAfter(s: string, k: int): bool =
  ## does an assignment operator start at k (spaces skipped)? (`=`, `+=` … — not `==`, `<=`, `>=`, `!=`)
  var q = k
  while q < s.len and s[q] == ' ': inc q
  for op in EcAssignOps:
    if s.continuesWith(op, q):
      let e = q + op.len
      if op == "=" and e < s.len and s[e] == '=': return false
      if e < s.len and s[e] in NxOpChars and op.len <= 2 and op != "=": return false
      if op.len > 2 and op[0] in IdentChars and q > 0 and s[q - 1] notin {' ', '.', ')', ']'}: return false
      return true
  false

proc ecMutatingCall(f: NxFile, b: Buffer, l, col: int, argIdx: int): bool =
  ## the routine named at l:col, given something at argument `argIdx` (-1: any): may it change it? (a `var`/`out`
  ## parameter there in any overload, or not a plain routine at all — a template or macro may do anything)
  const Reads = ["assert", "doAssert", "debugEcho", "echo", "fmt", "len", "high", "low", "check", "require", "$"]
  let s = b.lines[l]
  let (a, e) = ecWordAt(s, col)
  if a >= e: return true
  if s[a ..< e] in Reads: return false
  # (its address taken, or a view of it handed on: whatever gets it may change it)
  if s[a ..< e] in ["addr", "unsafeAddr", "toOpenArray", "toOpenArrayByte", "toOpenArrayChar"]: return true
  var rs: seq[NxRef]
  try: (rs, _, _) = nxTargets(f, b.lines, l, a)
  except CatchableError: return true
  if rs.len == 0: return true
  for r in rs:
    template sy: untyped = r.sym
    if sy.kind notin {nxProc, nxFunc, nxMethod, nxIterator, nxConverter}: return true
    for i, p in sy.params:
      if argIdx >= 0 and i != argIdx and not p.typ.startsWith("varargs"): continue
      let t = p.typ.strip
      if t.startsWith("var ") or t.startsWith("out ") or t == "var" or t.startsWith("var[") or t.startsWith("sink") and false:
        return true
      if t.startsWith("varargs[untyped") or t.startsWith("varargs[typed") and argIdx < 0 or t in ["untyped", "typed"]:
        return true
  false

func ecEnclosingCall(s: string, k: int): (int, int, int, bool) =
  ## the innermost bracket around column k on its line: (its column, the callee's column or -1, the argument's
  ## index, opened by `(`)
  var d = 0
  var commas = 0
  var j = k - 1
  while j >= 0:
    let c = s[j]
    if c in {')', ']', '}'}: inc d
    elif c in {'(', '[', '{'}:
      if d == 0:
        let q = j - 1
        if c == '(' and q >= 0 and nxIsIdent(s[q]):
          let (ca, _) = ecWordAt(s, q)
          return (j, ca, commas, true)
        return (j, -1, commas, c == '(')
      dec d
    elif c == ',' and d == 0: inc commas
    dec j
  (-1, -1, 0, false)

proc ecCallsDirty(sc: NxScope, code: seq[string], a, e: int, memo: var Table[string, bool]): bool =
  ## does lines a..e call a {.dirty.} template? (it sees the caller's names: it may use or change any of them)
  if sc == nil: return true
  for l in a .. min(e, code.high):
    let s = code[l]
    var k = 0
    while k < s.len:
      if nxIsIdent(s[k]) and (k == 0 or not nxIsIdent(s[k - 1])) and s[k] notin {'0'..'9'}:
        var q = k
        while q < s.len and nxIsIdent(s[q]): inc q
        let w = s[k ..< q]
        var dirty = memo.getOrDefault(w, false)
        # (system's `in`, `notin`, `isnot` are dirty templates that only call contains/not: they change nothing
        # of the caller's — and `for x in xs` calls no template at all)
        if w in ["in", "notin", "isnot", "is", "of", "as", "and", "or", "not", "xor", "shl", "shr", "div", "mod"]:
          memo[w] = false
        elif w notin memo:
          for r in nxLookup(sc, w):
            if r.file != nil and r.sym.kind == nxTemplate and "dirty" in r.sym.pragmas: dirty = true
          memo[w] = dirty
        if dirty: return true
        k = q
      else: inc k

func ecModuleBefore(f: NxFile, s: string, dot: int): bool =
  ## is the word before the dot at column `dot` a module's name (`strutils.find(…)`: a qualified call, no receiver)?
  if dot <= 0 or not nxIsIdent(s[dot - 1]): return false
  let (a, e) = ecWordAt(s, dot - 1)
  if a > 0 and s[a - 1] == '.': return false
  let w = nxNorm(s[a ..< e])
  if w == "system" or w == nxNorm(splitFile(f.path).name): return true
  for im in f.imports:
    if im.isInclude: continue
    let nm = if im.alias.len > 0: im.alias else: splitFile(im.spec).name
    if nxNorm(nm) == w: return true
  false

proc ecCommandAt(f: NxFile, b: Buffer, s: string, l, k, start: int): int =
  ## the word at column k given to a command whose statement starts at `start` (`inc x`, `swap a, x`,
  ## `obj.add x`): 1 the command may change it, 0 it surely does not, -1 no command there
  var ind = start
  while ind < s.len and s[ind] == ' ': inc ind
  var w = ind
  while w < s.len and (nxIsIdent(s[w]) or s[w] == '.'): inc w
  if not (w < k and w < s.len and s[w] == ' ' and w > ind): return -1
  # (`a = b`, `x xor y`, `n < 3`: an operator after the word, not a command's argument)
  var q = w
  while q < s.len and s[q] == ' ': inc q
  var o = q
  while o < s.len and s[o] in {'=', '+', '-', '*', '/', '<', '>', '@', '$', '~', '&', '%', '|', '!', '?', '^', '.', ':'}: inc o
  if o > q and (o >= s.len or s[o] == ' '): return -1
  var ow = q
  while ow < s.len and nxIsIdent(s[ow]): inc ow
  if s[q ..< ow] in ["and", "or", "xor", "not", "shl", "shr", "div", "mod", "in", "notin", "is", "isnot", "of", "as"]:
    return -1
  let cw = s[ind ..< w]
  if cw in ["return", "result", "discard", "yield", "raise", "if", "elif", "while", "when", "case", "of", "let",
            "var", "const", "for", "in", "and", "or", "not", "echo", "assert", "doAssert", "notin", "is", "isnot"]:
    return -1
  var idx = 0                          # (its argument's index: commas outside brackets)
  var d = 0
  for c in s[w ..< k]:
    if c in {'(', '[', '{'}: inc d
    elif c in {')', ']', '}'}: dec d
    elif c == ',' and d == 0: inc idx
  let cc = if '.' in cw: ind + cw.rfind('.') + 1 else: ind
  let dotted = '.' in cw and not ecModuleBefore(f, s, cc - 1)
  if ecMutatingCall(f, b, l, cc, idx + ord(dotted)): 1 else: 0

proc ecVarsNeverChanged(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## `var x = …` in a routine that nothing changes afterwards: it can be a `let`. Only when every use of x is
  ## surely a read — an assignment to it or to a part of it, a call that takes it (or a part) as `var`, `addr`,
  ## a template or macro given it, a use inside a nested routine, inside brackets that began on an earlier line:
  ## any of these and x is left alone
  let lines = b.lines
  let sc = nxScope(f)
  var memo: Table[string, bool]
  for ri in 0 ..< f.syms.len:
    let r = f.syms[ri]
    if r.kind notin {nxProc, nxFunc, nxMethod, nxIterator, nxConverter} or r.made or r.endLine <= r.line or
       r.endLine >= code.len or r.endLine - r.line > 2000:
      continue
    var nested: seq[(int, int)]
    for sy in f.syms:
      if sy.kind in NxRoutineKinds and sy.line > r.line and sy.endLine <= r.endLine: nested.add (sy.line, sy.endLine)
    var depthAt = newSeq[int](r.endLine - r.line + 2)
    var d = 0
    for l in r.line .. r.endLine:
      depthAt[l - r.line] = d
      for ch in code[l]:
        if ch in {'(', '[', '{'}: inc d
        elif ch in {')', ']', '}'}: dec d
      if d < 0: d = 0
    if ecCallsDirty(sc, code, r.line, r.endLine, memo): continue
    var locals: seq[NxSym]
    try: locals = nxLocals(f, lines, r.endLine, 0, everything = true)
    except CatchableError: continue
    for v in locals:
      if v.kind != nxVar or v.line <= r.line or v.line > r.endLine or v.slots != 0 or v.name.len == 0 or
         v.name.startsWith("_") or v.exported:
        continue
      if v.col < 0 or v.col + v.name.len > code[v.line].len or code[v.line][v.col ..< v.col + v.name.len] != v.name:
        continue
      var inNested = false
      for (a, e) in nested:
        if v.line >= a and v.line <= e: inNested = true
      if inNested: continue
      # (written with a value, and nothing else on the line declares — `var a, b = 0`, pragmas, a section's
      # several members on one line: left alone)
      let rest = code[v.line][v.col + v.name.len .. ^1].strip
      if not (rest.startsWith("=") and not rest.startsWith("==") or rest.startsWith(":") and " = " in rest):
        continue
      if "{." in rest or code[v.line].strip.startsWith("var ") and code[v.line].count(',') > 0 and
         code[v.line].find('=') > code[v.line].find(','):
        continue
      let key = nxNorm(v.name)
      var uses = 0
      var changed = false
      for l in v.line .. r.endLine:
        if changed: break
        let s = code[l]
        var k = 0
        while k < s.len and not changed:
          if not (nxIsIdent(s[k]) and (k == 0 or not nxIsIdent(s[k - 1])) and s[k] notin {'0'..'9'}):
            inc k
            continue
          var e = k
          while e < s.len and nxIsIdent(s[e]): inc e
          if nxNorm(s[k ..< e]) != key or l == v.line and k == v.col or k > 0 and s[k - 1] == '.':
            k = e
            continue
          inc uses
          for (a, e2) in nested:
            if l >= a and l <= e2: changed = true
          if depthAt[l - r.line] > 0: changed = true            # (inside brackets from a line above)
          let before = s[0 ..< k].strip
          if before.endsWith("addr") or before.endsWith("unsafeAddr") or before.endsWith("ref"): changed = true
          # what follows the place: an assignment, or `.name` a call of
          let after = ecSkipChain(s, e)
          if ecAssignAfter(s, after): changed = true
          var q = e
          while not changed and q < after:
            if s[q] == '.' and q + 1 < s.len and nxIsIdent(s[q + 1]):
              if ecMutatingCall(f, b, l, q + 1, 0): changed = true
              break
            inc q
          if not changed:
            let (open, callee, idx, paren) = ecEnclosingCall(s, k)
            if open >= 0 and callee >= 0:
              # (`r.parse(x)`: the receiver is the first argument)
              let dotted = callee > 0 and s[callee - 1] == '.' and not ecModuleBefore(f, s, callee - 1)
              if ecMutatingCall(f, b, l, callee, idx + ord(dotted)): changed = true
            elif open >= 0 and paren:
              # (a command inside ( ): `(inc x; y = 1)`)
              let cm = ecCommandAt(f, b, s, l, k, ecStmtStart(s, k, open + 1))
              if cm == 1: changed = true
              elif cm < 0:
                # (a tuple: `(x, y) = …` assigns to it)
                var dd = 0
                var c2 = open
                while c2 < s.len:
                  if s[c2] in {'(', '[', '{'}: inc dd
                  elif s[c2] in {')', ']', '}'}:
                    dec dd
                    if dd == 0: break
                  inc c2
                if c2 < s.len and ecAssignAfter(s, c2 + 1): changed = true
            elif open < 0:
              # a command: `inc x`, `swap a, x`, `add x, 1` — the first word of the statement (after `if c:`,
              # `else:`, `of 'a':` or `;` on the same line, if any)
              if ecCommandAt(f, b, s, l, k, ecStmtStart(s, k)) == 1: changed = true
          k = e
      if not changed and uses > 0:
        res.add Diag(line: v.line, col: v.col, eline: v.line, ecol: v.col + v.name.len, sev: 4, src: "ned",
                     rule: "var-let", msg: "'" & v.name & "' is never changed: it can be a let")

proc ecUnusedParams(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## a parameter of a routine of this module (not exported, not passed around as a value, not a hook or an
  ## operator, not a stub, not calling a dirty template — it sees the parameters too) that its body never mentions
  let sc = nxScope(f)
  var memo: Table[string, bool]
  for ri in 0 ..< f.syms.len:
    let r = f.syms[ri]
    if r.kind notin {nxProc, nxFunc, nxIterator, nxConverter} or r.made or r.exported or r.local or
       r.endLine <= r.line or r.endLine >= code.len or r.endLine - r.line > 3000 or r.params.len == 0:
      continue
    if r.name.len == 0 or not nxIsIdent(r.name[0]) or r.name.startsWith("="): continue
    let pr = r.pragmas.toLowerAscii
    if "exportc" in pr or "importc" in pr or "cdecl" in pr or "noconv" in pr or "dynlib" in pr or "used" in pr or
       "closure" in pr or "nimcall" in pr or "async" in pr or "base" in pr:
      continue
    # (passed around as a value, or declared twice — a forward declaration: its signature is not its own to change)
    var asValue = false
    var decls = 0
    let key = nxNorm(r.name)
    for sy in f.syms:
      if sy.kind in NxRoutineKinds and nxNorm(sy.name) == key: inc decls
    if decls > 1: continue
    for l in 0 ..< code.len:
      let s = code[l]
      var k = s.find(r.name)
      while k >= 0 and not asValue:
        let e = k + r.name.len
        if (k == 0 or not nxIsIdent(s[k - 1])) and (e >= s.len or not nxIsIdent(s[e])) and l != r.line:
          var q = e
          while q < s.len and s[q] == ' ': inc q
          let callLike = q < s.len and s[q] in {'(', '['} or q < s.len and e < s.len and s[e] == ' ' and
                         s[q] notin {',', ')', ']', '}', '=', ':'}
          if not callLike and not (k > 0 and s[k - 1] == '.' and q < s.len and s[q] == '('): asValue = true
        k = s.find(r.name, k + 1)
      if asValue: break
    if asValue: continue
    # the body: after the header's `=` (a one-line body counts too)
    var bodyText = ""
    var stub = true
    for l in r.line .. r.endLine:
      bodyText.add code[l] & "\n"
      if l > r.line:
        let t = code[l].strip
        if t.len > 0 and not t.startsWith("discard") and not t.startsWith("raise") and
           not t.startsWith("doAssert false") and not t.startsWith("assert false"):
          stub = false
    if stub or ecCallsDirty(sc, code, r.line, r.endLine, memo): continue
    var counts: Table[string, int]
    var k = 0
    while k < bodyText.len:
      if nxIsIdent(bodyText[k]) and (k == 0 or not nxIsIdent(bodyText[k - 1])) and bodyText[k] notin {'0'..'9'}:
        var e = k
        while e < bodyText.len and nxIsIdent(bodyText[e]): inc e
        counts.mgetOrPut(nxNorm(bodyText[k ..< e]), 0) += 1
        k = e
      else: inc k
    var se = r.endLine                                    # (a string's last lines may be past the routine's end)
    while se + 1 < code.len and code[se + 1].strip(chars = {' ', '\t', '0'}).len == 0 and
          b.lines[se + 1].strip.len > 0: inc se
    for l in r.line .. se:                                # (names in emit strings: `name`)
      let raw = b.lines[l]
      var q = raw.find('`')
      while q >= 0:
        let e = raw.find('`', q + 1)
        if e < 0: break
        counts.mgetOrPut(nxNorm(raw[q + 1 ..< e]), 0) += 1
        q = raw.find('`', e + 1)
      ecBraceNames(raw, counts)                             # (names a format string interpolates: {n})
    for p in r.params:
      let pn = p.name.strip(chars = {'`', ' ', '*'})
      if pn.len == 0 or pn == "_" or pn.startsWith("_") or not nxIsIdent(pn[0]): continue
      # (a type given only to choose the overload or the generic: `retType: type[T]`)
      let pt = p.typ.strip
      if pt.startsWith("typedesc") or pt.startsWith("type[") or pt.startsWith("type ") or pt == "type": continue
      if counts.getOrDefault(nxNorm(pn)) <= 1:
        var at = -1
        var al = r.line
        for l in r.line .. min(r.endLine, r.line + 10):
          let (a0, e0) = (code[l].find(pn), code[l].find(pn) + pn.len)
          if a0 >= 0 and (a0 == 0 or not nxIsIdent(code[l][a0 - 1])) and (e0 >= code[l].len or not nxIsIdent(code[l][e0])):
            at = a0
            al = l
            break
        if at < 0: continue
        res.add Diag(line: al, col: at, eline: al, ecol: at + pn.len, sev: 4, src: "ned", rule: "unused-param",
                     msg: "parameter '" & pn & "' is never used")

proc ecResultNeverSet(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## a routine with a result type whose body never sets `result`, never returns a value and does not end in an
  ## expression: it always gives the default value — usually a forgotten `result =`
  var inString = newSeq[bool](code.len)          # (the line starts inside a """ string: part of what is above)
  var inTriple = false
  var inComment = 0
  for i in 0 ..< min(code.len, b.lines.len):
    inString[i] = inTriple or inComment > 0
    discard ecCodeOnly(b.lines[i], inTriple, inComment)
  for r in f.syms:
    if r.kind notin {nxProc, nxFunc, nxMethod, nxConverter} or r.made or r.endLine <= r.line or
       r.endLine >= code.len or r.endLine - r.line > 3000:
      continue
    let rt = r.ret.strip
    if rt.len == 0 or rt in ["void", "auto", "untyped", "typed"] or rt.startsWith("Future") or
       "noreturn" in r.pragmas or "importc" in r.pragmas or "importjs" in r.pragmas or "async" in r.pragmas or
       "magic" in r.pragmas or "compilerproc" in r.pragmas:
      continue
    # (a one-line body after the header: an expression)
    let hdr = code[r.line].strip
    if not hdr.endsWith("="): continue
    var bodyInd = -1
    var last = -1
    var mentions = false
    # (the body: the lines below the header indented more than it — the index's end may stop short)
    let hind = ecIndent(b.lines[r.line])
    var bodyEnd = r.line
    while bodyEnd + 1 < code.len and (code[bodyEnd + 1].strip.len == 0 or ecIndent(b.lines[bodyEnd + 1]) > hind or
                                      inString[bodyEnd + 1]):
      inc bodyEnd
    while bodyEnd > r.line and code[bodyEnd].strip.len == 0: dec bodyEnd
    for l in r.line + 1 .. bodyEnd:
      let t = code[l].strip
      if t.len == 0: continue
      if inString[l]: continue
      if bodyInd < 0: bodyInd = ecIndent(b.lines[l])
      if ecIndent(b.lines[l]) == bodyInd: last = l
      var k = 0
      let s = code[l]
      while k < s.len:
        if nxIsIdent(s[k]) and (k == 0 or not nxIsIdent(s[k - 1])):
          var e = k
          while e < s.len and nxIsIdent(s[e]): inc e
          let w = s[k ..< e]
          if w in ["result", "return", "asm", "emit", "quote", "noreturn"]: mentions = true
          k = e
        else: inc k
    if mentions or last < 0 or bodyInd <= ecIndent(b.lines[r.line]): continue
    # (the last statement at the body's level must be one that has no value)
    let t = code[last].strip
    var e0 = 0
    while e0 < t.len and nxIsIdent(t[e0]): inc e0
    let w0 = t[0 ..< e0]
    # (an `if` with no `else` — the last line at the body's level — has no value either; a `when` may: only its
    # branch for this build is there)
    var head = w0
    if w0 == "elif":
      for l in countdown(last - 1, r.line + 1):
        let tl = code[l].strip
        if ecIndent(b.lines[l]) == bodyInd and (tl.startsWith("if ") or tl.startsWith("when ")):
          head = tl.split(' ')[0]
          break
    let stmtOnly = w0 in ["for", "while", "echo", "inc", "dec", "var", "let", "const", "discard", "debugEcho"] or
                   (head == "if" and " else:" notin t and " else " notin t) or
                   (e0 > 0 and ecAssignAfter(t, ecSkipChain(t, e0)) and w0 notin ["if", "case", "when"])
    if not stmtOnly or w0 == "discard": continue                       # (`discard`: the default, on purpose)
    if last + 1 <= bodyEnd:
      # (the last statement goes on below — unless what follows is its block: `for …:`, `if …:`)
      if ecIndent(b.lines[bodyEnd]) > bodyInd and not t.endsWith(":"): continue
    res.add Diag(line: r.line, col: max(0, b.lines[r.line].find(r.name)), eline: r.line,
                 ecol: max(0, b.lines[r.line].find(r.name)) + r.name.len, sev: 2, src: "ned", rule: "result-unset",
                 msg: "'" & r.name & "' never sets its result: it always returns the default value")

const EcFuncMs = 12                         # ms a round of the "can be a func" check may take in an open file
var ecFuncRounds: Table[int, (int, int)]    # buffer id → (the change, the rounds the check asked for after it)

proc ecCanBeFunc(f: NxFile, b: Buffer, res: var seq[Diag]) =
  ## a proc of this module with no side effects — the engine sure of every call in it, as the compiler infers it:
  ## it touches no module variable and calls nothing that has side effects — can be a func. In an open file a round
  ## takes at most EcFuncMs: what is left is looked at in the next rounds (what was worked out is kept)
  let live = bufById(b.id) == b
  let keep = proc(s: NxSym): bool =
    for (a, e) in f.inactive:
      if s.line >= a and s.line <= e: return false
    true
  let (idx, cut) = nxFuncHints(f, b.lines, (if live: EcFuncMs else: 20_000), keep)
  for i in idx:
    let s = f.syms[i]
    if s.line >= b.lines.len: continue
    var c = s.col
    if c < 0 or b.lines[s.line].find(s.name, c) != c: c = max(0, b.lines[s.line].find(s.name))
    res.add Diag(line: s.line, col: c, eline: s.line, ecol: c + s.name.len, sev: 4, src: "ned", rule: "can-be-func",
                 msg: "'" & s.name & "' has no side effects: it can be a func")
  if cut and live:
    # (out of time: another round soon — a few at most for one change)
    let (ch, n) = ecFuncRounds.getOrDefault(b.id, (-1, 0))
    let rounds = if ch == b.changeId: n + 1 else: 1
    ecFuncRounds[b.id] = (b.changeId, rounds)
    if rounds <= 40: typoAt[b.id] = -1

func ecPragmaArg(pragmas, name: string): (bool, string) =
  ## is pragma `name` among these, and the text after `name:` (unquoted)
  var k = 0
  while true:
    k = pragmas.find(name, k)
    if k < 0: return (false, "")
    let e = k + name.len
    if (k == 0 or pragmas[k - 1] in {' ', ',', '.', '{'}) and (e >= pragmas.len or pragmas[e] in {' ', ',', ':', '.', '}'}):
      var v = ""
      var q = e
      while q < pragmas.len and pragmas[q] == ' ': inc q
      if q < pragmas.len and pragmas[q] == ':':
        inc q
        while q < pragmas.len and pragmas[q] == ' ': inc q
        if q < pragmas.len and pragmas[q] == '"':
          let c = pragmas.find('"', q + 1)
          if c > q: v = pragmas[q + 1 ..< c]
        elif q < pragmas.len and pragmas[q] == '(':
          let c = pragmas.find(')', q)
          if c > q: v = pragmas[q + 1 ..< c]
      return (true, v)
    k = e

proc ecVersion(v: string): seq[int] =
  ## "2, 2" / "2.2.4" / "(1, 3, 5)" → @[2, 2(, 4)]
  for p in v.replace("(", "").replace(")", "").replace(",", ".").split('.'):
    let t = p.strip
    if t.len == 0: continue
    try: result.add parseInt(t)
    except ValueError: return @[]

func ecVerLess(a, b: seq[int]): bool =
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: a[i] else: 0
    let y = if i < b.len: b[i] else: 0
    if x != y: return x < y
  false

var ecSinceBlocks: Table[string, (string, seq[(int, int, seq[int])])]   # library file → (stamp, its since blocks)
var ecMinNim: Table[string, (string, seq[int], string)]                  # .nimble → (stamp, the Nim it needs, as written)

proc ecSinceOf(r: NxRef): seq[int] =
  ## the Nim version a library declaration first appeared in: its {.since.} pragma or the `since (…):` block
  ## around it (@[] when it does not say)
  template sy: untyped = r.sym
  let (has, v) = ecPragmaArg(sy.pragmas, "since")
  if has: return ecVersion(v)
  let path = r.file.path
  let st = nxStamp(path)
  var blocks = ecSinceBlocks.getOrDefault(path, ("", @[]))
  if blocks[0] != st:
    blocks = (st, @[])
    let ls = nxLinesOf(r.file).ls
    var i = 0
    while i < ls.len:
      let t = ls[i].strip
      if (t.startsWith("since (") or t.startsWith("since((")) and t.endsWith(":"):
        let ind = ecIndent(ls[i])
        var e = i + 1
        while e < ls.len and (ls[e].strip.len == 0 or ecIndent(ls[e]) > ind): inc e
        let o = t.find('(')
        let c = t.rfind(')')
        if o >= 0 and c > o: blocks[1].add (i, e - 1, ecVersion(t[o .. c]))
      inc i
    if ecSinceBlocks.len > 200: ecSinceBlocks.clear()
    ecSinceBlocks[path] = blocks
  for (a, e, v) in blocks[1]:
    if sy.line > a and sy.line <= e: return v

proc ecProjectNim(path: string): (seq[int], string) =
  ## the oldest Nim the package says it works with: nim.minVersion, else `requires "nim >= …"` in its .nimble
  let set = cfgNimMinVersion.strip
  if set == "off": return (@[], "")
  if set.len > 0: return (ecVersion(set), set & " (nim.minVersion)")
  let nb = findNimbleFile(parentDir(path))
  if nb.len == 0: return (@[], "")
  let st = nxStamp(nb)
  let known = ecMinNim.getOrDefault(nb, ("", @[], ""))
  if known[0] == st and st.len > 0: return (known[1], known[2])
  var found: seq[int]
  var said = ""
  try:
    for ln in lines(nb):
      let t = ln.strip
      if not t.startsWith("requires"): continue
      var k = t.find('"')
      while k >= 0:
        let c = t.find('"', k + 1)
        if c < 0: break
        let req = t[k + 1 ..< c].strip
        if req.startsWith("nim ") or req.startsWith("nim>") or req == "nim":
          let rest = req[3 .. ^1].strip
          var v = ""
          for op in [">=", "==", "^=", "~=", ">"]:
            if rest.startsWith(op):
              v = rest[op.len .. ^1].strip.split({'&', ' '})[0]
              break
          if v.len > 0:
            found = ecVersion(v)
            said = "requires \"" & req & "\""
        k = t.find('"', c + 1)
  except CatchableError: discard
  ecMinNim[nb] = (st, found, said)
  (found, said)

proc ecNamesIn(code: seq[string], names: HashSet[string], visit: proc(l, k, e: int)) =
  ## each word of the code that is one of `names` (normalized), not after a dot's left side
  for l in 0 ..< code.len:
    let s = code[l]
    var k = 0
    while k < s.len:
      if nxIsIdent(s[k]) and (k == 0 or not nxIsIdent(s[k - 1])) and s[k] notin {'0'..'9'}:
        var e = k
        while e < s.len and nxIsIdent(s[e]): inc e
        if nxNorm(s[k ..< e]) in names: visit(l, k, e)
        k = e
      else: inc k

var ecApiNew: Table[string, int]          # "module\tname" (normalized) → the release step that added it (NimApiSteps)
var ecModNew: Table[string, int]          # a module's name → the release step that added it

proc ecApiLoad() =
  if ecApiNew.len > 0: return
  for i, st in NimApiSteps:
    for m in st[2].splitWhitespace: ecModNew[m] = i
    for ln in st[3].split('\n'):
      let c = ln.find(": ")
      if c < 0: continue
      let m = ln[0 ..< c]
      for n in ln[c + 2 .. ^1].splitWhitespace: ecApiNew[m & "\t" & nxNorm(n)] = i

proc ecApiStep(r: NxRef): int =
  ## the release step that added a library declaration (-1: older than any, or not known)
  if nxLibDir.len == 0 or not r.file.path.startsWith(nxLibDir & "/"): return -1
  var m = r.file.path[nxLibDir.len + 1 .. ^1]
  if m.endsWith(".nim"): m.setLen(m.len - 4)
  if m == "system" or m.startsWith("system/"): m = "system"
  ecApiLoad()
  ecApiNew.getOrDefault(m & "\t" & nxNorm(r.sym.name), -1)

proc ecVersionGuarded(code: seq[string]): seq[bool] =
  ## the lines of `when` statements that ask which Nim this is (NimMajor, NimVersion, declared(…), compiles(…),
  ## defined(nimHas…)): every branch — code there is written for more than one Nim
  result = newSeq[bool](code.len)
  const Guards = ["NimMajor", "NimMinor", "NimPatch", "NimVersion", "declared(", "compiles(", "defined(nim",
                  "declaredInScope("]
  var i = 0
  while i < code.len:
    let t = code[i].strip
    if not (t.startsWith("when ") or t.startsWith("when(")):
      inc i
      continue
    let ind = ecIndent(code[i])
    var guarded = false
    var e = i
    var j = i
    while j < code.len:
      let tj = code[j].strip
      if j > i and tj.len > 0 and ecIndent(code[j]) <= ind and
         not (ecIndent(code[j]) == ind and (tj.startsWith("elif ") or tj.startsWith("elif(") or tj.startsWith("else:") or tj == "else")):
        break
      if j == i or (ecIndent(code[j]) == ind and tj.startsWith("elif")):
        for g in Guards:
          if g in tj: guarded = true
      if tj.len > 0: e = j
      inc j
    if guarded:
      for k in i .. e: result[k] = true
    i = if guarded: e + 1 else: i + 1

proc ecVerText(v: seq[int]): string =
  var vs: seq[string]
  for x in v: vs.add $x
  vs.join(".")

proc ecDeprecatedAndNewer(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## a name whose every declaration it can mean is {.deprecated.} (the compiler's own words, so its quick fix
  ## applies), and a library name or module newer than the Nim the package asks for (its {.since.}, or the release
  ## that added it: NimApiSteps) — not in a `when` that asks which Nim this is
  let sc = nxScope(f)
  if sc == nil or ecImportsKnown(f) < 0: return
  let (minNim, said) = ecProjectNim(f.path)
  var guarded: seq[bool]
  if minNim.len > 0:
    guarded = ecVersionGuarded(code)
    ecApiLoad()
  # (a module the package's oldest Nim does not have: its import)
  if minNim.len > 0 and nxLibDir.len > 0:
    for im in f.imports:
      if im.isInclude or im.line < 0 or im.line >= code.len or guarded[im.line]: continue
      let p = nxResolve(f.path, im.spec)
      if not p.startsWith(nxLibDir & "/"): continue
      let stem = splitFile(p).name
      let st = ecModNew.getOrDefault(stem, -1)
      if st < 0 or ecVerLess(ecVersion(NimApiSteps[st][0]), minNim): continue
      let s = code[im.line]
      var k = s.find(stem)
      while k >= 0 and ((k > 0 and nxIsIdent(s[k - 1])) or (k + stem.len < s.len and nxIsIdent(s[k + stem.len]))):
        k = s.find(stem, k + 1)
      if k < 0: continue
      res.add Diag(line: im.line, col: k, eline: im.line, ecol: k + stem.len, sev: 2, src: "ned", rule: "newer-module",
                   msg: "module " & stem & " is not in Nim " & NimApiSteps[st][0] & " or older (Nim " &
                        NimApiSteps[st][1] & " has it); this package " & said)
  var depNames, newNames: HashSet[string]
  var notDep: HashSet[string]            # (a name with one declaration that is not deprecated: an overload may be meant)
  for r in sc.refs:
    if r.file == nil: continue
    template sy: untyped = r.sym
    if "deprecated" in sy.pragmas and r.file.path != f.path: depNames.incl nxNorm(sy.name)
    elif "deprecated" notin sy.pragmas: notDep.incl nxNorm(sy.name)
    if minNim.len > 0 and nxLibDir.len > 0 and r.file.path.startsWith(nxLibDir & "/"):
      let st = ecApiStep(r)
      if st >= 0 and not ecVerLess(ecVersion(NimApiSteps[st][0]), minNim): newNames.incl nxNorm(sy.name)
      elif "since" in sy.pragmas or r.file.path notin ecSinceBlocks or ecSinceBlocks[r.file.path][1].len > 0:
        let v = ecSinceOf(r)
        if v.len > 0 and ecVerLess(minNim, v): newNames.incl nxNorm(sy.name)
  for x in notDep: depNames.excl x
  if depNames.len == 0 and newNames.len == 0: return
  var n = 0
  let lines = b.lines
  var all = depNames
  for x in newNames: all.incl x
  var found: seq[Diag]
  ecNamesIn(code, all, proc(l, k, e: int) =
    if n > 200: return
    let key = nxNorm(code[l][k ..< e])
    # (inside a pragma, or given to a template or macro — `cbconf selfExe:` names a callback: not a use)
    let s = code[l]
    let po = s.rfind("{.", 0, k)
    if po >= 0 and (s.find(".}", po) < 0 or s.find(".}", po) > k): return
    let (open, callee, _, _) = ecEnclosingCall(s, k)
    var cw = ""
    if open >= 0 and callee >= 0:
      let (ca, ce) = ecWordAt(s, callee)
      cw = s[ca ..< ce]
    elif open < 0:
      let t0 = s.strip(trailing = false)
      let ind = s.len - t0.len
      var w = ind
      while w < s.len and nxIsIdent(s[w]): inc w
      if w < k and w < s.len and s[w] == ' ': cw = s[ind ..< w]
    if cw.len > 0 and cw notin ["echo", "return", "result", "discard", "let", "var", "const", "if", "elif", "when",
                                "while", "case", "of", "for", "in", "and", "or", "not", "yield", "raise"] and
       ecRoutineKind(sc, cw) != 1:
      return
    var rs: seq[NxRef]
    try: (rs, _, _) = nxTargets(f, lines, l, k)
    except CatchableError: return
    if rs.len == 0: return
    var allDep = key in depNames
    var allNew = key in newNames and not guarded[l]
    var newest: seq[int]                 # (the newest {.since.} of what it can mean)
    var step = -1                        # (else the latest release step that added one of them)
    var depMsg = ""
    for r in rs:
      template sy: untyped = r.sym
      if r.file.path == f.path and sy.line == l: return                 # (its own declaration)
      let (has, msg) = ecPragmaArg(sy.pragmas, "deprecated")
      if not has: allDep = false
      elif depMsg.len == 0: depMsg = msg
      if allNew:
        let st = ecApiStep(r)
        if st >= 0 and not ecVerLess(ecVersion(NimApiSteps[st][0]), minNim):
          step = max(step, st)
        else:
          let v = if nxLibDir.len > 0 and r.file.path.startsWith(nxLibDir & "/"): ecSinceOf(r) else: @[]
          if v.len == 0 or not ecVerLess(minNim, v): allNew = false
          elif newest.len == 0 or ecVerLess(newest, v): newest = v
    let name = lines[l][k ..< e]
    if allDep:
      inc n
      found.add Diag(line: l, col: k, eline: l, ecol: e, sev: 2, src: "ned", rule: "deprecated",
                     msg: (if depMsg.len > 0: depMsg & "; " else: "") & name & " is deprecated")
    elif allNew and newest.len > 0:
      inc n
      found.add Diag(line: l, col: k, eline: l, ecol: e, sev: 2, src: "ned", rule: "newer-api",
                     msg: "'" & name & "' is in Nim " & ecVerText(newest) & " and later; this package " & said)
    elif allNew and step >= 0:
      inc n
      found.add Diag(line: l, col: k, eline: l, ecol: e, sev: 2, src: "ned", rule: "newer-api",
                     msg: "'" & name & "' is not in Nim " & NimApiSteps[step][0] & " or older (Nim " &
                          NimApiSteps[step][1] & " has it); this package " & said))
  res.add found

# ── rules: each of ned's own checks has a rule id; .ned/lint.json (the nearest above a file) sets a rule's severity
#    or turns it off and leaves files out, and a `# ned: ignore` comment silences one line — in the editor, nedls
#    and ned --lint alike ──

const NedRules* = [  # (rule, what it finds, its severity unless .ned/lint.json says otherwise)
  ("typo", "a name nothing declares, close to one that is declared (the compiler's words)", 1),
  ("field-typo", "a field name that is a typo of one the object has", 2),
  ("arg-count", "a call with the wrong number of arguments for every routine of that name", 2),
  ("discarded", "a value neither used nor discarded", 2),
  ("literal-type", "a literal that can never be the declared type", 2),
  ("unused-import", "an import nothing in the file uses", 2),
  ("unreachable", "code after a return, raise, break or continue", 3),
  ("unused-local", "a local let or var nothing uses", 4),
  ("var-let", "a var nothing changes: it can be a let", 4),
  ("unused-param", "a parameter a routine never uses", 4),
  ("result-unset", "a routine that never sets its result", 2),
  ("deprecated", "a name only deprecated declarations have", 2),
  ("newer-api", "a standard-library name newer than the Nim the package asks for", 2),
  ("newer-module", "a standard-library module newer than the Nim the package asks for", 2),
  ("can-be-func", "a proc with no side effects: it can be a func", 4),
  ("unused-export", "an exported routine nothing in the project uses (programs, not libraries)", 4),
  ("import-not-required", "an import of a package the .nimble does not require", 2),
  ("require-unused", "a package the .nimble requires that nothing imports", 4),
  ("nimble", "a problem in a .nimble file", 2),
  ("nim3", "Nim 3 (Nimony): what Nim 2 code must change — in a Nim 3 project, or when asked", 2),
  # (ned's own CSS, HTML and SQL — in their files and in Nim strings)
  ("sql-args", "a query given more (or fewer) values than it has `?` (db_connector's exec, getRow …)", 1),
  ("sql-table", "a table no CREATE TABLE of the project makes", 2),
  ("sql-column", "a column its table does not have (`t.col`)", 2),
  ("css-property", "an unknown CSS property", 2),
  ("css-value", "a value its CSS property does not take", 2),
  ("css-semicolon", "a missing `;`: the next line is read as part of the value", 1),
  ("css-brace", "a `}` too many, or a `{` never closed", 1),
  ("html-close", "a closing tag that closes the wrong element or nothing, an element never closed", 1),
  ("html-id", "an id used twice", 2),
  ("html-element", "an element HTML does not have", 2),
  ("html-alt", "an <img> without alt text", 4),
  # (ned's own JavaScript — in .js files and an HTML page's <script>s)
  ("js-brace", "a bracket (or `${`) never closed, or one that closes nothing", 1),
  ("js-redeclare", "a let, const, class or import declared twice in one scope", 1),
  ("js-const-assign", "an assignment to a const (or an import)", 1),
  ("js-unused", "a function, let, const or import nothing uses (in a module)", 4),
  ("js-eqeq", "== or != with a literal: === and !== do not convert", 4),
  ("js-typo", "a name nothing declares, a letter or two away from one that is", 2)]

var ecWantSev* = 4                     # ned --lint: rules less serious than what it shows or fails on are not looked for

func nedRuleSev*(rule: string): int =
  ## a rule's own severity (NedRules)
  for (r, _, sv) in NedRules:
    if r == rule: return sv
  2

type LintCfg = object
  dir: string                          # the folder the .ned/ is in ("": no .ned/lint.json)
  sev: Table[string, int]              # rule → severity (0: off)
  exclude: seq[string]                 # globs, from that folder (EditorConfig's: * ** ? [ab] {a,b})
  problems: seq[string]                # what in the file could not be used (ned --lint says)

var lintCfgCache: Table[string, (string, LintCfg)]     # lint.json → (its stamp, what it says)

func lintSevOfName(name: string): int =
  ## "error" 1 · "warning" 2 · "info" 3 · "hint" 4 · "off" 0 · else -1
  case name.toLowerAscii
  of "error", "errors": 1
  of "warning", "warnings", "warn": 2
  of "info", "information": 3
  of "hint", "hints": 4
  of "off", "none", "never", "false": 0
  else: -1

proc lintCfgFile(path: string): string =
  ## the nearest .ned/lint.json above a file (its folder or one above, up to the repository's top) — "" none
  var d = parentDir(path)
  for _ in 0 .. 40:
    if fileExists(d / ".ned" / "lint.json"): return d / ".ned" / "lint.json"
    if dirExists(d / ".git") or d.len <= 1: break
    let up = parentDir(d)
    if up == d or up.len == 0: break
    d = up
  ""

proc lintCfgFor*(path: string): LintCfg =
  ## the rule settings a file is checked with (.ned/lint.json; none: every rule at its own severity)
  let f = lintCfgFile(path)
  if f.len == 0: return
  let st = nxStamp(f)
  if f in lintCfgCache and lintCfgCache[f][0] == st: return lintCfgCache[f][1]
  result.dir = parentDir(parentDir(f))
  var known: HashSet[string]
  for (r, _, _) in NedRules: known.incl r
  try:
    let j = parseJson(readFile(f))
    let rules = j{"rules"}
    if rules != nil and rules.kind == JObject:
      for k, v in rules:
        let sv = if v.kind == JString: lintSevOfName(v.getStr) elif v.kind == JBool: (if v.getBool: -2 else: 0) else: -1
        if k notin known: result.problems.add "unknown rule \"" & k & "\""
        elif sv == -1: result.problems.add "\"" & k & "\": off, error, warning, info or hint"
        elif sv != -2: result.sev[k] = sv
    let ex = j{"exclude"}
    if ex != nil and ex.kind == JArray:
      for x in ex:
        if x.kind == JString and x.getStr.len > 0: result.exclude.add x.getStr
  except CatchableError as e:
    result.problems.add "not read: " & e.msg
  lintCfgCache[f] = (st, result)

proc lintExcluded*(cfg: LintCfg, path: string): bool =
  ## is the file left out by the lint.json's exclude? ("generated/" a folder, "**/*_gen.nim" a glob)
  if cfg.dir.len == 0 or cfg.exclude.len == 0 or not path.startsWith(cfg.dir & "/"): return false
  let rel = path[cfg.dir.len + 1 .. ^1]
  for g in cfg.exclude:
    let g2 = g.strip(chars = {'/'}, trailing = false)
    if g2.endsWith("/"):
      if rel.startsWith(g2) or ("/" & g2) in ("/" & rel): return true
    elif ecGlobMatches(g2, rel) or ecGlobMatches(g2 & "/**", rel): return true
  false

proc lintIgnoreRules(comment: string, word: string): (bool, seq[string]) =
  ## `# ned: ignore` → (true, @[]) — every rule; `# ned: ignore[var-let, unused-param]` → (true, those)
  let k = comment.find("# ned: " & word)
  if k < 0: return
  let e = k + ("# ned: " & word).len
  if e < comment.len and comment[e] == '[':
    let c = comment.find(']', e)
    if c > e:
      for r in comment[e + 1 ..< c].split(','):
        if r.strip.len > 0: result[1].add r.strip
  elif e < comment.len and comment[e] notin {' ', '\t'}: return        # (ignore-next-line, when looking for ignore)
  result[0] = true

proc lintSilenced*(lines: openArray[string], l: int, rule: string): bool =
  ## is the rule silenced on line l — `# ned: ignore[…]` on it, `# ned: ignore-next-line[…]` alone on the line
  ## above, or `# ned: ignore-file[…]` near the top?
  proc hit(r: (bool, seq[string])): bool = r[0] and (r[1].len == 0 or rule in r[1])
  if l >= 0 and l < lines.len and "# ned: ignore" in lines[l] and hit(lintIgnoreRules(lines[l], "ignore")): return true
  if l > 0 and l - 1 < lines.len and lines[l - 1].strip.startsWith("# ned: ignore-next-line") and
     hit(lintIgnoreRules(lines[l - 1], "ignore-next-line")):
    return true
  for i in 0 ..< min(lines.len, 40):
    if "# ned: ignore-file" in lines[i] and hit(lintIgnoreRules(lines[i], "ignore-file")): return true
  false

proc lintApply*(path: string, lines: openArray[string], ds: var seq[Diag]) =
  ## ned's own diagnostics (those with a rule) as .ned/lint.json and `# ned: ignore` comments want them
  var any = false
  for d in ds:
    if d.rule.len > 0: any = true
  if not any: return
  let cfg = lintCfgFor(path)
  if lintExcluded(cfg, path):
    var keep: seq[Diag]
    for d in ds:
      if d.rule.len == 0: keep.add d
    ds = keep
    return
  var keep: seq[Diag]
  for d0 in ds:
    var d = d0
    if d.rule.len > 0:
      let s = cfg.sev.getOrDefault(d.rule, -1)
      if s == 0: continue
      if s > 0: d.sev = s
      if lintSilenced(lines, d.line, d.rule): continue
    keep.add d
  ds = keep

proc pcImportsNotRequired*(f: NxFile, b: Buffer, code: seq[string]): seq[Diag]
proc pcNimbleChecks*(b: Buffer): seq[Diag]

var ecLast: Table[int, (string, seq[Diag])]   # open buffer → (its text and what the engine knew, the checks but
                                              # can-be-func found then): a can-be-func round reuses them

proc engineChecksFor(b: Buffer): seq[Diag] =
  ## the engine's own checks of a Nim buffer as it is now. In an open file "can be a func" may take several rounds
  ## (a few ms each, so typing and scrolling go on): the other checks are made once per text, not every round
  if b == nil or b.lang == nil or b.lang.mode != lmNim or b.lines.len > 20000 or b.largeOn: return
  let f = try: nxFileFor(b) except CatchableError: nil
  if f == nil: return
  # (system's own parts see more than ned knows)
  if nxInSystem(f.path, partsOnly = true): return
  let sk = f.path.find("/lib/system/")
  if sk >= 0 and fileExists(f.path[0 ..< sk] / "lib" / "system.nim"): return
  var code = newSeq[string](b.lines.len)
  var inTriple = false
  var inComment = 0
  for i, l in b.lines: code[i] = ecCodeOnly(l, inTriple, inComment)
  # (inside a `when` branch the engine leaves out, nothing is checked; a rule .ned/lint.json turns off is not looked for)
  let lc = lintCfgFor(f.path)
  template on(rule: string): bool =
    (let sv = lc.sev.getOrDefault(rule, nedRuleSev(rule)); sv != 0 and sv <= ecWantSev)
  let live = bufById(b.id) == b
  let port3 = nim3On() or b.path in nim3Asked       # (Nim 3's porting problems: in a Nim 3 project, or asked for)
  let key = $b.changeId & "/" & $nxGen & "/" & lc.dir & "/" & $lc.sev & "/" & $ecWantSev & "/" & $cfgEngineMoreChecks &
            "/" & $port3
  if live and ecLast.getOrDefault(b.id)[0] == key:
    result = ecLast[b.id][1]                          # (the same text: only can-be-func goes on)
    try:
      if cfgEngineMoreChecks and on("can-be-func"): ecCanBeFunc(f, b, result)
    except CatchableError, Defect: discard
  else:
    try:
      if on("unreachable"): ecUnreachable(b.lines, code, result)
      if on("unused-local"): ecUnusedLocals(f, b.lines, code, result)
      if on("field-typo"): ecMembers(f, b, code, result)
      if on("arg-count"): ecArgCounts(f, b, code, result)
      if on("discarded"): ecDiscarded(f, b, code, result)
      if on("literal-type"): ecLiteralTypes(f, b, code, result)
      if on("unused-import"): ecUnusedImports(f, b, code, result)
      if cfgEngineMoreChecks:
        if on("var-let"): ecVarsNeverChanged(f, b, code, result)
        if on("unused-param"): ecUnusedParams(f, b, code, result)
        if on("result-unset"): ecResultNeverSet(f, b, code, result)
        if on("can-be-func"): ecCanBeFunc(f, b, result)
      if on("deprecated") or on("newer-api") or on("newer-module"): ecDeprecatedAndNewer(f, b, code, result)
      # (the project's .nimble: its requires)
      if on("import-not-required"): result.add pcImportsNotRequired(f, b, code)
      if b.path.endsWith(".nimble") and on("nimble"): result.add pcNimbleChecks(b)
      if port3 and on("nim3"): nim3Checks(f, b, code, result)
    except CatchableError, Defect: discard
    if live:
      var others: seq[Diag]
      for d in result:
        if d.rule != "can-be-func": others.add d
      if ecLast.len > 50: ecLast.clear()
      ecLast[b.id] = (key, others)
  var keep: seq[Diag]
  for d in result:
    var inactive = false
    for (a, e) in f.inactive:
      if d.line >= a and d.line <= e: inactive = true
    if not inactive: keep.add d
  lintApply(f.path, b.lines, keep)
  keep
