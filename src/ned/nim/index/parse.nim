# ── the declaration parser ──

type
  NxBlock* = enum bkRoutine, bkTypeSec, bkVarSec, bkObject, bkEnum, bkTransparent, bkObjTransparent, bkOther,
    bkLocal                  # a block inside a routine (if, for, an active `when` branch …): it can declare types
  NxFrame* = object
    ind*: int
    kind*: NxBlock
    sym*: int              # routine/type symbol index (bkRoutine, bkObject, bkEnum)
    secKind*: NxKind       # bkVarSec: nxConst / nxLet / nxVar
    memberInd*: int        # first member's indent in a section (-1 until known)
    owner*: string

proc nxParseImports*(f: NxFile, rest: string, line: int, kw: string) =
  var r = rest.strip
  if kw == "export":
    for p in nxSplitTop(r, {','}):
      let x = p.strip
      if x.len > 0: f.exports.add x
    return
  if kw == "from":
    let k = r.find(" import ")
    if k < 0: return
    var imp = NxImport(spec: r[0 ..< k].strip.strip(chars = {'"'}), line: line)
    for p in nxSplitTop(r[k + 8 .. ^1], {','}):
      let x = p.strip.strip(chars = {'`'})
      if x.len > 0: imp.only.add x
    f.imports.add imp
    return
  var excepts: seq[string]
  let ex = r.find(" except ")
  if ex >= 0:
    for p in nxSplitTop(r[ex + 8 .. ^1], {','}):
      let x = p.strip.strip(chars = {'`'})
      if x.len > 0: excepts.add x
    r = r[0 ..< ex]
  for p0 in nxSplitTop(r, {','}):
    var p = p0.strip
    if p.len == 0: continue
    var alias = ""
    let a = p.find(" as ")
    if a >= 0:
      alias = p[a + 4 .. ^1].strip
      p = p[0 ..< a].strip
    p = p.strip(chars = {'"', ' '})
    let br = p.find('[')
    if br >= 0 and p.endsWith("]"):
      # std/[os, strutils]
      let base = p[0 ..< br].strip
      for q in nxSplitTop(p[br + 1 ..< p.high], {','}):
        let x = q.strip.strip(chars = {'"'})
        if x.len > 0: f.imports.add NxImport(spec: base & x, line: line, isInclude: kw == "include")
    else:
      f.imports.add NxImport(spec: p, line: line, alias: alias, isInclude: kw == "include")
  if excepts.len > 0 and f.imports.len > 0: f.imports[^1].excepts = excepts

proc nxLocate*(lines: openArray[string], name: string, a, b: int, start: (int, int)): (int, int) =
  ## where `name` stands as a whole word in lines a..b (searching from `start`)
  for l in max(a, start[0]) .. min(b, lines.high):
    let s = lines[l]
    var k = if l == start[0]: start[1] else: 0
    while true:
      k = s.find(name, k)
      if k < 0: break
      let okL = k == 0 or not nxIsIdent(s[k - 1])
      let okR = k + name.len >= s.len or not nxIsIdent(s[k + name.len])
      if okL and okR: return (l, k)
      k += 1
  (a, max(0, lines[min(a, lines.high)].find(name)))

var nxDefines*: HashSet[string]       # what `defined(x)` is true for (the platform ned runs on)
var nxDefinesComplete* = false        # nxDefines came from `nim dump`: a name not in it is not defined

proc nxInitDefines*() =
  # (not nimPreviewSlimSystem: without it, system brings syncio's readFile, stdin, open … as the compiler does)
  for d in ["posix", "unix", "linux", "nimV2", "gcDestructors", "gcOrc", "nimSeqsV2", "nimHasAlignOf",
            "nimHasNoReturnError", "nimHasCursor", "nimHasSinkInference", "nimHasEffectsOf", "nimHasTopDownInference",
            "nimHasDefault", "nimHasStyleChecks", "nimHasWarningAsError", "ssl", "threads", "nimAllowNonVarDestructor"]:
    nxDefines.incl d
  when defined(android): nxDefines.incl "android"
  when defined(amd64): nxDefines.incl "amd64"
  when defined(arm64): nxDefines.incl "arm64"

proc nxWhen*(cond: string): int =
  ## evaluate a `when` condition we can be sure about: 1 true, 0 false, -1 unknown
  var toks: seq[string]
  var i = 0
  let c = cond
  while i < c.len:
    if c[i] in {' ', '\t'}: inc i
    elif c[i] in {'(', ')'}:
      toks.add $c[i]
      inc i
    elif nxIsIdent(c[i]):
      var e = i
      while e < c.len and (nxIsIdent(c[e]) or c[e] == '.'): inc e
      let w = c[i ..< e]
      if (w == "defined" or w == "declared") and e < c.len and c[e] == '(':
        let ce = c.find(')', e)
        if ce < 0: return -1
        let arg = c[e + 1 ..< ce].strip
        if w == "declared": toks.add "?"
        elif nxDefines.len == 0 and false: toks.add "?"
        else:
          let known = ["windows", "macosx", "osx", "ios", "js", "nimscript", "emscripten", "wasm", "hotcodereloading",
                       "freebsd", "openbsd", "netbsd", "dragonfly", "solaris", "haiku", "genode", "nintendoswitch",
                       "zephyr", "freertos", "standalone", "useNimRtl", "nimdoc", "gcRefc", "gcMarkAndSweep", "gcBoehm",
                       "gcGo", "gcRegions", "nogc", "nimHasCompiles", "nimNoLibc", "lwip", "nimdoc", "vcc", "msvc",
                       "createNimRtl", "booting", "nimTypeNames", "nimHasCursor"]
          if arg in nxDefines: toks.add "1"
          elif arg in known or arg == "android" or arg == "amd64" or arg == "arm64" or arg == "i386" or
               nxDefinesComplete: toks.add "0"
          else: toks.add "?"
        i = ce + 1
      else:
        case w
        of "not", "and", "or": toks.add w
        of "true": toks.add "1"
        of "false": toks.add "0"
        else: toks.add "?"          # (a constant: defined(windows) and not weirdTarget is still false)
        i = e
    else: return -1
  # tiny recursive evaluator over 0 / 1 / ? with not, and, or, ()
  var p = 0
  proc orExpr(): int
  proc atom(): int =
    if p >= toks.len: return -1
    let t = toks[p]
    inc p
    case t
    of "1": 1
    of "0": 0
    of "?": -1
    of "not":
      let v = atom()
      if v < 0: -1 else: 1 - v
    of "(":
      let v = orExpr()
      if p < toks.len and toks[p] == ")": inc p
      v
    else: -1
  proc andExpr(): int =
    result = atom()
    while p < toks.len and toks[p] == "and":
      inc p
      let r = atom()
      result = if result == 0 or r == 0: 0 elif result == 1 and r == 1: 1 else: -1
  proc orExpr(): int =
    result = andExpr()
    while p < toks.len and toks[p] == "or":
      inc p
      let r = andExpr()
      result = if result == 1 or r == 1: 1 elif result == 0 and r == 0: 0 else: -1
  let v = orExpr()
  if p < toks.len: -1 else: v

proc nxBlockValue*(lines: openArray[string], start, ind: int, val: string): string =
  ## a value that goes on in the lines below — let x = if c:   /   case k   /   try:   /   block:
  ## — as one line for the type to come from: "if c: <the first branch's last line> …"
  result = val
  let v = val.strip
  if v.len == 0:
    # let x =
    #   expression       (on the lines below: the first one, with what continues it)
    for l in start ..< min(lines.len, start + 20):
      let raw = lines[l]
      let t0 = raw.strip
      if t0.len == 0 or t0[0] == '#': continue
      if leadWs(raw) <= ind: return
      var t = t0
      if t.startsWith("if ") or t.startsWith("when ") or t.startsWith("case ") or t == "try:" or t == "block:":
        return nxBlockValue(lines, l + 1, ind, t)
      var open = 0
      var l2 = l
      while true:
        var q = false
        for ch in lines[l2]:
          if ch == '"': q = not q
          elif not q:
            if ch in {'(', '[', '{'}: inc open
            elif ch in {')', ']', '}'}: dec open
        let tt = lines[l2].strip
        if open <= 0 and not (tt.endsWith(",") or tt.endsWith("&") or tt.endsWith("+") or tt.endsWith("or") or
                              tt.endsWith("and")):
          break
        inc l2
        if l2 >= lines.len or l2 - l > 30 or leadWs(lines[l2]) <= ind: break
        t.add " " & lines[l2].strip
      return t
    return
  let isCase = v.startsWith("case ")
  if not (isCase or (v.endsWith(":") and (v.startsWith("if ") or v.startsWith("when ") or v == "try:" or
                                          v == "block:"))):
    return
  var inBranch = not isCase
  var last = ""
  for l in start ..< min(lines.len, start + 40):
    let raw = lines[l]
    var t = raw.strip
    var q = false
    for k in 0 ..< t.len:
      if t[k] == '"': q = not q
      elif t[k] == '#' and not q:
        t = t[0 ..< k].strip
        break
    if t.len == 0: continue
    if leadWs(raw) <= ind: break
    if t.startsWith("of ") or t.startsWith("elif ") or t.startsWith("else:") or t == "else" or
       t.startsWith("except"):
      if inBranch: break
      inBranch = true
      let c = t.find(": ")                  # of 1: "one"
      if c > 0 and c + 2 < t.len:
        last = t[c + 2 .. ^1].strip
        break
      continue
    if not inBranch or t.endsWith(":"): continue
    let (w, _) = nxName(t, 0)
    if w in ["raise", "return", "discard", "echo", "doAssert", "assert", "inc", "dec", "break", "continue",
             "var", "let", "const", "add", "quit"]:
      continue
    let e = nxFindTop(t, '=')
    if e > 0 and e + 1 < t.len and t[e + 1] != '=' and t[e - 1] notin {'<', '>', '!', '='}: continue   # x = 1
    last = t
  if last.len > 0:
    result = (if isCase: v & ": " else: v & " ") & last & " …"

proc nxSubstIdents*(s: string, sub: Table[string, string]): string =
  ## a template's body line with its arguments in place of its parameters; `lower 2` with lower = vec → vec2
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '#':
      result.add s[i .. ^1]
      return
    if c == '"':
      var j = i + 1
      while j < s.len and s[j] != '"':
        if s[j] == '\\': inc j
        inc j
      result.add s[i .. min(j, s.high)]
      i = j + 1
      continue
    if c == '\'' and nxCharEnd(s, i) > i:
      let e = nxCharEnd(s, i)
      result.add s[i .. e]
      i = e + 1
      continue
    if c == '`':
      let e = s.find('`', i + 1)
      if e < 0:
        result.add s[i .. ^1]
        return
      var joined = ""
      for part in s[i + 1 ..< e].splitWhitespace:
        joined.add sub.getOrDefault(part, part)
      if joined.len > 0 and joined[0] in IdentStartChars and joined.allCharsInSet(IdentChars): result.add joined
      else: result.add "`" & joined & "`"
      i = e + 1
      continue
    if c in IdentStartChars and (i == 0 or not nxIsIdent(s[i - 1])):
      var j = i
      while j < s.len and nxIsIdent(s[j]): inc j
      let w = s[i ..< j]
      result.add (if i > 0 and s[i - 1] == '.': w else: sub.getOrDefault(w, w))
      i = j
      continue
    result.add c
    inc i

proc nxParse*(lines: openArray[string], path: string): NxFile =
  result = NxFile(path: path, module: splitFile(path).name)
  let f = result
  var st: NxLexState
  var stack: seq[NxFrame]
  var docTarget = -1         # symbol that following ## lines document
  var docInd = 0
  var moduleDocOpen = true
  var lastContent = 0
  var code, doc: string
  var i = 0
  let n = lines.len
  var whenTaken = initTable[int, int]()

  var localDepth = 0         # > 0: inside a routine's body (a type declared there is a local one)
  template addSym(s0: NxSym) =
    f.syms.add s0
    if localDepth > 0: f.syms[^1].local = true
    let (pl, pc) = nxLocate(lines, f.syms[^1].name, startLine, i - 1, posFrom)
    f.syms[^1].line = pl
    f.syms[^1].col = pc
    posFrom = (pl, pc + f.syms[^1].name.len)
    docTarget = f.syms.high
    docInd = ind
    if doc.len > 0: f.syms[^1].doc = doc

  template enumValues(textT: string, ownerT: string, expT: bool) =
    for v in nxSplitTop(textT, {','}):
      let vv = nxStripPragma(v.strip)[0].strip
      if vv.len == 0: continue
      let (vn, ve) = nxName(vv, 0)
      if vn.len == 0: continue
      let eqv = vv.find('=', ve)
      addSym(NxSym(name: vn, kind: nxEnumVal, line: startLine, col: nxWordCol(raw, vn), owner: ownerT,
                   exported: expT, value: (if eqv >= 0: vv[eqv + 1 .. ^1].strip else: "")))

  template typeMember(mtT: string) =
    ## Name*[T] {.pragma.} = definition
    let mt = mtT
    let (nm, e) = nxName(mt, 0)
    if nm.len > 0:
      var s = NxSym(name: nm, kind: nxType, line: startLine, col: nxWordCol(raw, nm), endLine: startLine)
      var j = e
      if j < mt.len and mt[j] == '*':
        s.exported = true
        inc j
      let eq = nxFindTop(mt, '=', j)
      let (h2, prag) = nxStripPragma(if eq >= 0: mt[j ..< eq] else: mt[j .. ^1])
      let head = h2.strip
      s.pragmas = prag
      if head.startsWith("["): s.generics = nxCollapse(head)
      let def = nxStripPragma(if eq >= 0: mt[eq + 1 .. ^1].strip else: "")[0].strip
      s.typ = nxCollapse(def)
      addSym(s)
      let tyIdx = f.syms.high
      let fw = def.split({' ', '['})
      if fw.len > 0 and fw[0] == "enum":
        stack.add NxFrame(ind: ind, kind: bkEnum, sym: tyIdx, owner: nm)
        enumValues(def[4 .. ^1], nm, s.exported)
        docTarget = tyIdx
      elif "object" in fw or def == "tuple" or def.startsWith("concept"):
        stack.add NxFrame(ind: ind, kind: bkObject, sym: tyIdx, owner: nm)
      elif def.startsWith("tuple["):
        let ce = nxMatchClose(def, 5)
        if ce > 5:
          for p in nxParseParams(def[6 ..< ce]):
            f.syms.add NxSym(name: p.name.strip(chars = {'*'}), kind: nxField, line: startLine,
                             col: nxWordCol(raw, p.name), owner: nm, typ: p.typ, exported: true, local: localDepth > 0)
        docTarget = tyIdx
      elif t.endsWith(":") or t.endsWith("=") or def.len == 0:
        stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)

  template whenBranch(transparentKind: NxBlock) =
    ## when / elif / else: skip branches that cannot apply on this platform, keep the ones that might
    var cond = rest.strip
    if cond.endsWith(":"): cond.setLen(cond.len - 1)
    var v = -1
    if w0 == "when":
      v = nxWhen(cond)
      whenTaken[ind] = (if v == 1: 1 elif v == 0: 0 else: -1)
    elif w0 == "elif":
      let prev = whenTaken.getOrDefault(ind, -1)
      if prev == 1: v = 0
      else:
        v = nxWhen(cond)
        if v == 1 and prev == 0: whenTaken[ind] = 1
        elif v == -1: whenTaken[ind] = -1
    else:
      let prev = whenTaken.getOrDefault(ind, -1)
      v = if prev == 1: 0 elif prev == 0: 1 else: -1
    stack.add NxFrame(ind: ind, kind: (if v == 0: bkOther else: transparentKind), sym: -1)

  template varMember(mtT: string, kkT: NxKind) =
    ## a*, b {.pragma.}: T = value   /   (x, y) = value
    let mt = mtT
    let kk = kkT
    let c1 = nxFindTop(mt, ':')
    let e1 = nxFindTop(mt, '=')
    var endNames = mt.len
    if c1 >= 0: endNames = c1
    if e1 >= 0 and e1 < endNames: endNames = e1
    var typ = ""
    if c1 >= 0 and (e1 < 0 or c1 < e1): typ = (if e1 > c1: mt[c1 + 1 ..< e1] else: mt[c1 + 1 .. ^1]).strip
    let val = if e1 >= 0: mt[e1 + 1 .. ^1].strip else: ""
    let unpack = mt.strip.startsWith("(")          # let (a, b) = …: each name takes one element
    let names = nxSplitTop(mt[0 ..< endNames].strip(chars = {'(', ')', ' '}), {','})
    for vi, p in names:
      let (pn, _) = nxStripPragma(p)
      let (nm, e) = nxName(pn, 0)
      if nm.len == 0 or nm == "_": continue
      let val2 = if typ.len == 0 and e1 >= 0: nxBlockValue(lines, i, ind, val) else: val
      addSym(NxSym(name: nm, kind: kk, line: startLine, col: nxWordCol(raw, nm),
                   exported: e < pn.len and pn[e] == '*', typ: (if unpack: "" else: nxCollapse(typ)),
                   value: (if val2.len > 200: val2[0 ..< 197] & "…" else: val2),
                   slot: vi.int16, slots: (if unpack: -names.len.int16 else: 0)))

  while i < n:
    let startLine = i
    var posFrom = (i, 0)
    let raw = lines[i]
    var depth = 0
    let wasBlock = st.blockDepth > 0 or st.inTriple
    let wasDocBlock = st.docBlock
    nxSplitLine(raw, st, code, doc, depth)
    inc i
    if wasBlock:
      # still inside a block comment or a long string from an earlier line
      if wasDocBlock:
        let d = (if doc.len > 0: doc else: raw).strip(chars = {' ', '#', ']'})
        if moduleDocOpen and stack.len == 0 and docTarget < 0:
          f.doc.add "\n" & d
        elif docTarget >= 0:
          f.syms[docTarget].doc.add "\n" & d
      # a line that starts inside a long string or comment: its indentation means nothing
      continue
    var t = code.strip
    let ind = leadWs(raw)
    if t.len == 0:
      if doc.len > 0 or raw.strip.startsWith("##"):
        # a pure doc comment line
        if moduleDocOpen and stack.len == 0 and ind == 0 and docTarget < 0:
          f.doc.add (if f.doc.len > 0: "\n" else: "") & doc
        elif docTarget >= 0 and ind > docInd:
          let d = f.syms[docTarget].doc
          f.syms[docTarget].doc = (if d.len > 0: d & "\n" else: "") & doc
      elif raw.strip.len == 0 and docTarget >= 0:
        discard                  # a blank line inside a doc comment keeps it going
      continue
    moduleDocOpen = false
    # join continuation lines: open brackets, or a trailing comma
    var guard = 0
    while (depth > 0 or t.endsWith(",")) and i < n and guard < 60 and not st.inTriple and st.blockDepth == 0:
      var c2, d2: string
      nxSplitLine(lines[i], st, c2, d2, depth)
      t.add " " & c2.strip
      if d2.len > 0: doc = d2
      inc i
      inc guard
    if not t.endsWith("=") and nxName(t, 0)[0] in NxRoutineKw:
      # proc parseChunks(client: HttpClient): Future[void]
      #                  {.multisync.} =
      while i < n and guard < 60 and not st.inTriple and st.blockDepth == 0:
        let nl = lines[i].strip
        if leadWs(lines[i]) <= ind or nl.startsWith("#") or
           not (nl.startsWith("{.") or nl.startsWith("=") or nl.startsWith(":") or t.endsWith(":")): break
        var c2, d2: string
        nxSplitLine(lines[i], st, c2, d2, depth)
        t.add " " & c2.strip
        inc i
        inc guard
        while depth > 0 and i < n and guard < 60 and not st.inTriple and st.blockDepth == 0:
          nxSplitLine(lines[i], st, c2, d2, depth)
          t.add " " & c2.strip
          inc i
          inc guard
        if t.endsWith("="): break
    if t in ["import", "include", "export"] or (t.startsWith("from ") and t.endsWith(" import")):
      # import
      #   ast, astalgo, idents,
      #   semdata
      while i < n and guard < 60 and not st.inTriple and st.blockDepth == 0:
        if lines[i].strip.len == 0 or leadWs(lines[i]) <= ind: break
        var c2, d2: string
        nxSplitLine(lines[i], st, c2, d2, depth)
        let c2s = c2.strip
        if c2s.len > 0:
          t.add (if t.endsWith(",") or t.endsWith("import") or t.endsWith("include") or
                    t.endsWith("export"): " " else: ", ") & c2s
        inc i
        inc guard
    while stack.len > 0 and stack[^1].ind >= ind:
      let fr = stack.pop()
      if fr.kind in {bkRoutine, bkObject, bkEnum} and fr.sym >= 0 and fr.sym < f.syms.len:
        f.syms[fr.sym].endLine = lastContent
    lastContent = i - 1
    var k = stack.high
    while k >= 0 and stack[k].kind == bkTransparent: dec k
    let fk = if k >= 0: stack[k].kind else: bkTransparent
    localDepth = 0
    for fr in stack:
      if fr.kind == bkRoutine: inc localDepth
    docTarget = -1               # a code line ends a doc comment run (its own trailing ## aside)
    if t.startsWith("{.pragma:"):
      let (pn, _) = nxName(t, 9)
      if pn.len > 0: f.pragmas.add (pn, startLine)
    let (w0, w0end) = nxName(t, 0)
    let rest = if w0end < t.len: t[w0end .. ^1] else: ""
    let opensBlock = t.endsWith(":") or t.endsWith("=")
    case fk
    of bkTransparent:     # module level (or inside `when`)
      if w0 in NxRoutineKw and rest.len > 0 and rest[0] in {' ', '`'}:
        # proc name*[T](params): Ret {.pragmas.} = body
        let (nm, e) = nxName(t, w0end)
        if nm.len == 0:
          if opensBlock: stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)
          continue
        posFrom = (startLine, ind + w0end)
        var s = NxSym(name: nm, kind: NxKind(NxRoutineKw.find(w0)), line: startLine, endLine: startLine)
        var j = e
        if j < t.len and t[j] == '*':
          s.exported = true
          inc j
        while j < t.len and t[j] == ' ': inc j
        if j < t.len and t[j] == '[':
          let ce = nxMatchClose(t, j)
          if ce > j:
            s.generics = nxCollapse(t[j .. ce])
            j = ce + 1
        while j < t.len and t[j] == ' ': inc j
        if j < t.len and t[j] == '(':
          let ce = nxMatchClose(t, j)
          if ce > j:
            s.params = nxParseParams(t[j + 1 ..< ce])
            for p in s.params.mitems:
              p.typ = nxCollapse(p.typ)
              p.default = nxCollapse(p.default)
            j = ce + 1
        while j < t.len and t[j] == ' ': inc j
        if j < t.len and t[j] == ':':
          var e2 = t.len
          let pr = t.find("{.", j)
          if pr >= 0: e2 = pr
          let eq = nxFindTop(t, '=', j + 1)
          if eq >= 0 and eq < e2: e2 = eq
          s.ret = nxCollapse(t[j + 1 ..< e2].strip)
          j = e2
        let pr = t.find("{.", j)
        if pr >= 0:
          let pe = t.find(".}", pr + 1)
          if pe >= pr + 2: s.pragmas = t[pr + 2 ..< pe].strip      # (`{.}` while typing has none)
        addSym(s)
        if opensBlock: stack.add NxFrame(ind: ind, kind: bkRoutine, sym: f.syms.high)
      elif w0 in ["import", "include", "export"] and rest.len > 0 and rest[0] in {' ', '"'}:
        nxParseImports(f, rest, startLine, w0)
      elif w0 == "from" and " import " in rest:
        nxParseImports(f, rest, startLine, "from")
      elif w0 == "type":
        let r = rest.strip
        if r.len == 0: stack.add NxFrame(ind: ind, kind: bkTypeSec, sym: -1, memberInd: -1)
        else: typeMember(r)
      elif w0 in ["const", "let", "var"]:
        let kk = if w0 == "const": nxConst elif w0 == "let": nxLet else: nxVar
        let r = rest.strip
        if r.len == 0: stack.add NxFrame(ind: ind, kind: bkVarSec, sym: -1, secKind: kk, memberInd: -1)
        else:
          varMember(r, kk)
          if opensBlock: stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)
      elif w0 in ["when", "elif", "else"] and opensBlock:
        whenBranch(bkTransparent)
      elif opensBlock:
        stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)
      elif w0.len > 0 and rest.len > 0 and rest[0] in {'(', ' '}:
        # genVecConstructor(vec, Vec, float32): what a template of this file declares at the top level
        var tpl = -1
        for k in countdown(f.syms.high, 0):
          let s = f.syms[k]
          if s.kind == nxTemplate and s.name == w0 and s.endLine > s.line and s.line < startLine and
             s.params.len > 0:
            tpl = k
            break
        if tpl >= 0:
          let ts = f.syms[tpl]
          var argText = rest.strip
          if argText.startsWith("("):
            let ce = nxMatchClose(argText, 0)
            argText = if ce > 0: argText[1 ..< ce] else: ""
          let args = nxSplitTop(argText, {','})
          if args.len == ts.params.len:
            var sub: Table[string, string]
            for k, p in ts.params: sub[p.name.strip(chars = {'`', '*'})] = args[k].strip
            var body: seq[string]
            var bodyInd = -1
            var anyDecl = false
            for l in ts.line + 1 .. min(ts.endLine, lines.high):
              let rw = lines[l]
              if rw.strip.len == 0:
                body.add ""
                continue
              if bodyInd < 0: bodyInd = leadWs(rw)
              let bl = nxSubstIdents(rw[min(bodyInd, leadWs(rw)) .. ^1], sub)
              if leadWs(rw) == bodyInd and nxName(bl, 0)[0] in ["proc", "func", "template", "macro", "iterator",
                                                                  "converter", "method", "type", "const", "let", "var"]:
                anyDecl = true
              body.add bl
            if anyDecl and body.len < 2000:
              let g = nxParse(body, f.path)
              let cc = nxWordCol(raw, w0)
              for s0 in g.syms:
                var s = s0
                s.line = startLine
                s.col = cc
                s.endLine = startLine
                s.made = true
                if s.doc.len == 0: s.doc = "(declared by `" & w0 & "(" & argText.strip & ")`)"
                f.syms.add s
    of bkTypeSec:
      if stack[k].memberInd < 0: stack[k].memberInd = ind
      if w0 in ["when", "elif", "else"] and opensBlock: whenBranch(bkTransparent)
      else: typeMember(t)
    of bkObject, bkObjTransparent:
      var oi = k
      while oi >= 0 and stack[oi].kind != bkObject: dec oi
      let owner = if oi >= 0: stack[oi].owner else: ""
      if w0 in ["when", "elif", "else"] and opensBlock:
        whenBranch(bkObjTransparent)
        continue
      if w0 == "of" and opensBlock:
        stack.add NxFrame(ind: ind, kind: bkObjTransparent, sym: -1)
        continue
      var line2 = t
      if w0 == "case":
        line2 = rest.strip
        if line2.endsWith(":"): line2.setLen(line2.len - 1)
      if w0 in ["of", "else"]:
        # a branch of a case object with its field on the same line:  of kA: a: int
        let c = nxFindTop(t, ':')
        if c < 0: continue
        line2 = t[c + 1 .. ^1].strip
        let (w1, _) = nxName(line2, 0)
        if line2.len == 0 or w1 in ["discard", "nil"]: continue
      elif w0 in ["proc", "func", "discard", "nil"]: continue
      for p in nxParseParams(line2):
        let pn = p.name.strip
        let nm = pn.strip(chars = {'*', ' ', '`'})
        if nm.len == 0 or not nxIsIdent(nm[0]): continue
        addSym(NxSym(name: nm, kind: nxField, line: startLine, col: nxWordCol(raw, nm), owner: owner,
                     typ: nxCollapse(p.typ), value: p.default, exported: pn.endsWith("*")))
      if w0 == "case": stack.add NxFrame(ind: ind, kind: bkObjTransparent, sym: -1)
    of bkEnum:
      let exp = stack[k].sym >= 0 and f.syms[stack[k].sym].exported
      enumValues(t, stack[k].owner, exp)
    of bkVarSec:
      if stack[k].memberInd < 0: stack[k].memberInd = ind
      if ind > stack[k].memberInd: discard        # a value continued on the next line
      elif w0 in ["when", "elif", "else"] and opensBlock: whenBranch(bkTransparent)
      else:
        varMember(t, stack[k].secKind)
        if opensBlock: stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)
    of bkRoutine, bkLocal:
      # a routine's body: what it declares is local, but its types are worth knowing (their fields, for `x.`)
      if w0 == "type":
        let r = rest.strip
        if r.len == 0: stack.add NxFrame(ind: ind, kind: bkTypeSec, sym: -1, memberInd: -1)
        else: typeMember(r)
      elif w0 in ["when", "elif", "else"] and opensBlock: whenBranch(bkLocal)
      elif w0 in NxRoutineKw: (if opensBlock: stack.add NxFrame(ind: ind, kind: bkOther, sym: -1))  # (a nested routine)
      elif opensBlock: stack.add NxFrame(ind: ind, kind: bkLocal, sym: -1)
    of bkOther: discard
  while stack.len > 0:
    let fr = stack.pop()
    if fr.kind in {bkRoutine, bkObject, bkEnum} and fr.sym >= 0 and fr.sym < f.syms.len:
      f.syms[fr.sym].endLine = lastContent
