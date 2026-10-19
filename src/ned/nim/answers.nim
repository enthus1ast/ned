var nxWarm: HashSet[int]                 # buffers whose imports the index has already read

var nxWarmMods: seq[(string, int)]      # modules the open file imports (and theirs) whose own scopes are still to be
var nxWarmedMods: HashSet[string]       #   made: (path, how far from the file)
var nxWarmBad: HashSet[string]          # files that would not stay read (unreadable, or the index over its memory)
var nxWarmGen = -1                      # the index generation they were made for (`nim dump` came back: again)
var nxWarmLeft = 0                      # how many more modules the file opened last may have warmed (40)

proc engineWarm(b: Buffer) =
  ## read a Nim file's imports while you are not typing, so the first completion is instant — then, in quiet
  ## moments, what those modules (and the ones they import) see themselves: the checks walk into them, and on a
  ## phone a dozen made at once would hold up the screen. A file read or a scope made at a time, 8 ms a round
  if not nimEngineOn(b): return
  if nxWarmGen != nxGen:
    # (a new toolchain, other defines, names a macro makes: what was made may be gone — the open file starts over)
    nxWarmGen = nxGen
    nxWarm.clear()
    nxWarmedMods.clear()
    nxWarmMods.setLen(0)
  template queue(f: NxFile, depth: int) =
    if f != nil:
      for im in f.imports:
        if im.isInclude: continue
        let p = nxResolve(f.path, im.spec)
        if p.len > 0 and p notin nxWarmedMods and nxWarmLeft > 0:
          var dup = false
          for (q, _) in nxWarmMods:
            if q == p: dup = true
          if not dup:
            nxWarmMods.add (p, depth)
            dec nxWarmLeft
  if b.id notin nxWarm:
    nxWarm.incl b.id
    nxWarmLeft = 40
    try:
      let f = nxFileFor(b)
      discard nxScope(f)
      queue(f, 1)
    except Exception as e: internalError("Nim index", e)
    return
  if nxWarmMods.len == 0 or msSince(lastInputAt) < 400: return
  let t0 = getMonoTime()
  while nxWarmMods.len > 0 and msSince(t0) < 8:
    let (p, depth) = nxWarmMods[0]
    try:
      if p notin nxFiles:
        discard nxLoad(p)                    # (the module read: a round of its own)
        if nxFiles.getOrDefault(p) == nil:
          nxWarmMods.delete(0)
        continue
      # the files it imports read one by one, then what it sees made
      let g = nxFiles[p]
      var pending = ""
      for im in g.imports:
        if im.isInclude: continue
        let q = nxResolve(p, im.spec)
        if q.len > 0 and q notin nxFiles and q notin nxWarmBad:
          pending = q
          break
      if pending.len > 0:
        discard nxLoad(pending)
        if pending notin nxFiles: nxWarmBad.incl pending        # (not again)
        continue
      nxWarmMods.delete(0)
      nxWarmedMods.incl p
      discard nxScope(g)
      if depth < 2: queue(g, depth + 1)
    except Exception as e:
      if nxWarmMods.len > 0 and nxWarmMods[0][0] == p: nxWarmMods.delete(0)
      internalError("Nim index", e)
  if nxWarmedMods.len > 400: nxWarmedMods.clear()
  if nxWarmBad.len > 400: nxWarmBad.clear()

func nxKindIcon(k: NxKind): int =
  ## completion kind numbers (LSP's), for icons and colours
  case k
  of nxProc, nxFunc, nxIterator, nxConverter, nxTemplate, nxMacro: 3
  of nxMethod: 2
  of nxType: 7
  of nxField: 5
  of nxEnumVal: 20
  of nxConst: 21
  of nxLet, nxVar, nxParam, nxForVar, nxResult: 6
  of nxModule: 9

func nxIconText(k: NxKind): string =
  case k
  of NxRoutineKinds: "ƒ"
  of nxType: "T"
  of nxConst, nxEnumVal: "c"
  of nxField: "m"
  else: "v"

proc addImport(b: Buffer, module: string)
proc importedModules(b: Buffer): HashSet[string]
proc stdNamesStarting(lp: string): seq[(string, seq[string])]

func postfixVarName(recv, shape: string): string =
  ## the loop variable for `recv.for`: items → item, entries → entry, a string's c, else x
  if shape == "string": return "c"
  let e = recv.len
  if e == 0 or recv[^1] in {')', ']', '"', '\''}: return "x"
  var a = e
  while a > 0 and nxIsIdent(recv[a - 1]): dec a
  let w = recv[a ..< e]
  var n = ""
  if w.len > 3 and w.endsWith("ies"): n = w[0 ..< ^3] & "y"
  elif w.len > 4 and (w.endsWith("ches") or w.endsWith("shes") or w.endsWith("sses") or w.endsWith("xes")): n = w[0 ..< ^2]
  elif w.len > 3 and w.endsWith("ren"): n = w[0 ..< ^3]                   # children → child
  elif w.len > 1 and w.endsWith("s") and not w.endsWith("ss"): n = w[0 ..< ^1]
  if n.len == 0 or n in NxKeywords or n == w: return "x"
  n

proc postfixItems(b: Buffer, c: NxCompletion, line, dot: int): seq[CompItem] =
  ## postfix templates for what is in front of the `.` at `dot`: xs.for → for x in xs:, c.case → a case with every
  ## value of c's enum, v.if → if v: (or v.isSome, v != nil, v.len > 0, by its type), x.echo, x.let, x.not …
  if not cfgPostfix or dot <= 0 or line >= b.lines.len: return
  let text = b.lines[line]
  if dot >= text.len or text[dot] != '.': return
  let recv = nxReceiver(text, dot)
  if recv.len == 0 or recv.len > 200 or recv[0] in Digits and '.' in recv: return
  var rs = dot - recv.len
  while rs > 0 and text[rs ..< dot].strip != recv: dec rs
  if rs < 0 or text[rs ..< dot].strip != recv: return
  while rs < dot and text[rs] == ' ': inc rs
  if c.recvIsType: return                       # Color. and strutils. → their values and procs, not templates
  let stmt = text[0 ..< rs].strip.len == 0      # it starts a statement: for, if, case … can take its place
  let sh = c.recvShape
  let r = recv.replace("$", "\\$")
  proc add(res: var seq[CompItem], label, detail, body: string) =
    # (after the receiver's fields and procs: `xs.le` is len before let)
    res.add CompItem(label: label, insert: label, filter: label, sortText: "9" & label, kind: 15,
                     detail: "postfix · " & detail, snippet: body, rank: 5, postfix: rs + 1)
  if stmt:
    let v = postfixVarName(recv, sh)
    case sh
    of "int":
      result.add("for", "for i in 0 ..< " & recv & ":", "for ${1:i} in 0 ..< " & r & ":\n\t$0")
    of "table":
      result.add("for", "for k, v in " & recv & ":", "for ${1:k}, ${2:v} in " & r & ":\n\t$0")
    else:
      result.add("for", "for " & v & " in " & recv & ":", "for ${1:" & v & "} in " & r & ":\n\t$0")
      result.add("fori", "for i, " & v & " in " & recv & ":", "for ${1:i}, ${2:" & v & "} in " & r & ":\n\t$0")
    let (cond, ncond) = case sh
      of "option": (recv & ".isSome", recv & ".isNone")
      of "ref": (recv & " != nil", recv & " == nil")
      of "string", "seq", "table": (recv & ".len > 0", recv & ".len == 0")
      of "int", "float": (recv & " != 0", recv & " == 0")
      else: (recv, "not " & recv)
    result.add("if", "if " & cond & ":", "if " & cond.replace("$", "\\$") & ":\n\t$0")
    result.add("ifnot", "if " & ncond & ":", "if " & ncond.replace("$", "\\$") & ":\n\t$0")
    if sh in ["", "bool"]: result.add("while", "while " & recv & ":", "while " & r & ":\n\t$0")
    if sh == "enum" and c.enumVals.len > 0:
      var body = "case " & r
      for i, ev in c.enumVals:
        body.add "\nof " & ev & ":\n\t" & (if i == 0: "${1:discard}" else: "discard")
      result.add("case", "case " & recv & " — all " & $c.enumVals.len & " values", body)
    else:
      result.add("case", "case " & recv & " · of … · else", "case " & r & "\nof ${1}:\n\t$0\nelse:\n\tdiscard")
    result.add("echo", "echo " & recv, "echo " & r & "$0")
    result.add("discard", "discard " & recv, "discard " & r & "$0")
    result.add("return", "return " & recv, "return " & r & "$0")
    result.add("let", "let x = " & recv, "let ${1:x} = " & r & "$0")
    result.add("var", "var x = " & recv, "var ${1:x} = " & r & "$0")
    if sh in ["", "bool"]: result.add("assert", "doAssert " & recv, "doAssert " & r & "$0")
  if sh in ["", "bool"]: result.add("not", "not " & recv, "not " & r & "$0")
  result.add("par", "(" & recv & ")", "(" & r & ")$0")
  if sh != "string": result.add("str", "$" & recv, "\\$" & r & "$0")

proc engineComplete(b: Buffer, manual: bool): bool =
  ## completion from the index — after a `.` the receiver's fields and the routines that take it;
  ## nimsuggest is asked as well when the index cannot tell the receiver's type
  let p = b.primary.head
  var c: NxCompletion
  try:
    let f = nxFileFor(b)
    if f == nil: return false
    c = nxComplete(f, b.lines, p.line, p.col)
  except Exception as e:
    internalError("Nim index", e)
    return false
  compLine = p.line
  compStartCol = b.wordStart(p)
  compManual = manual
  compNx = c.items
  var items: seq[CompItem]
  for i, it in c.items:
    let kw = it.detail == "keyword"
    items.add CompItem(label: it.label, insert: (if it.insert.len > 0: it.insert else: it.label), detail: (if kw: "" else: it.detail),
                       kind: (if kw: 14 else: nxKindIcon(it.kind)), filter: it.label,
                       sortText: $it.rank & it.label.toLowerAscii, rank: it.rank, nx: i + 1)
  if c.member and compStartCol > 0:
    items.add postfixItems(b, c, p.line, compStartCol - 1)
  if not c.member:
    for s in snippetItems(b, b.lines[p.line][compStartCol ..< p.col]):
      var s2 = s
      s2.rank = 3
      s2.sortText = "3" & s.label
      items.add s2
    # names from standard-library modules that are not imported yet: accepting one adds the import
    let prefix = b.lines[p.line][compStartCol ..< p.col]
    if prefix.len >= 2 and cfgAutoImport:
      var have = initHashSet[string]()
      for it in items: have.incl it.label
      let mods = b.importedModules()
      var added = 0
      for (name, ms) in stdNamesStarting(prefix.toLowerAscii):
        if added >= 40: break
        if name in have: continue
        for m in ms:
          let short = m.split('/')[^1]
          if short in mods or short == "system": continue
          items.add CompItem(label: name, insert: name, detail: "import " & m, kind: 3, filter: name,
                             sortText: "5" & name.toLowerAscii, rank: 5, addImport: m)
          inc added
          break
  compItems = items
  compFromLsp = true
  refilterComp()
  if c.member and not c.known and nsUsable(b):
    discard nsRequest(b, nsSug, p)        # the compiler knows what the index could not work out
  elif manual and not compOpen: info("No completions")
  true

proc compDocOf(i: int): string =
  ## the documentation shown beside completion item i (made once, when first shown)
  if i < 0 or i >= compItems.len: return ""
  if compItems[i].docMade: return compItems[i].doc
  compItems[i].docMade = true
  var d = compItems[i].doc
  let nx = compItems[i].nx
  if d.len == 0 and nx > 0 and nx <= compNx.len:
    try:
      d = nxDocItem(compNx[nx - 1])
      d.add cDocForNx(compNx[nx - 1])          # an importc proc: its C declaration and documentation
    except Exception as e: internalError("Nim index", e)
  elif d.len == 0 and compItems[i].postfix > 0:
    d = "```nim\n" & stripSnippet(compItems[i].snippet).replace("\t", "  ") & "\n```\npostfix — Tab or Enter writes this " &
        "in place of what is in front of the `.`"
  elif d.len == 0 and compItems[i].snippet.len > 0:
    d = "```" & buf().lang.name.toLowerAscii & "\n" & stripSnippet(compItems[i].snippet) & "\n```\nsnippet — Tab or Enter expands it"
  compItems[i].doc = d
  d

proc nxSigLabel(s: NxSym, ufcs: bool, binds: Table[string, string]): (string, seq[(int, int)]) =
  ## "name(a: int, b = 2): T" and where each parameter stands in it
  var lbl = s.name & "("
  var spans: seq[(int, int)]
  for i, prm in s.params:
    if ufcs and i == 0: continue
    if spans.len > 0: lbl.add ", "
    let a = lbl.len
    lbl.add prm.name
    if prm.typ.len > 0: lbl.add ": " & nxSubst(prm.typ, binds)
    if prm.default.len > 0: lbl.add " = " & prm.default
    spans.add (a, lbl.len)
  lbl.add ")"
  if s.ret.len > 0: lbl.add ": " & nxSubst(s.ret, binds)
  (lbl, spans)

proc engineSignature(b: Buffer, p: Pos): bool =
  ## signature help from the index: the call around the cursor, its parameter being typed, its docs
  var h: NxSigHelp
  try:
    let f = nxFileFor(b)
    if f == nil: return false
    h = nxSignatureHelp(f, b.lines, p.line, p.col)
  except Exception as e:
    internalError("Nim index", e)
    return false
  if h.overloads.len == 0: return false
  # iterators only where a loop asks for one: procs first otherwise
  let inFor = b.lines[p.line].strip.startsWith("for ")
  var ordered: seq[NxRef]
  for r in h.overloads:
    if (r.sym.kind == nxIterator) == inFor: ordered.add r
  for r in h.overloads:
    if (r.sym.kind == nxIterator) != inFor: ordered.add r
  h.overloads = ordered
  # the overload that best takes the arguments written so far (their types), and this many of them
  var pick = 0
  var argTypes: seq[string]
  try:
    let f = nxFileFor(b)
    let t = b.lines[p.line]
    var q = min(p.col, t.len) - 1
    var d = 0
    while q >= 0:
      if t[q] in {')', ']'}: inc d
      elif t[q] in {'(', '['}:
        if d == 0: break
        dec d
      dec q
    if q >= 0 and f != nil:
      let parts = nxSplitTop(t[q + 1 ..< min(p.col, t.len)], {','})
      let sc = nxScope(f)
      let locs = nxLocals(f, b.lines, p.line, p.col)
      for k in 0 ..< parts.len - 1:            # (the one being typed is not done)
        let a = parts[k].strip
        argTypes.add (if a.len > 0 and nxFindTop(a, '=') < 0: nxTypeOfExpr(f, sc, locs, a, p.line, 0).typ else: "")
      var bestScore = -1
      for i, r in h.overloads:
        let ps = r.sym.params
        let off = if h.ufcs: 1 else: 0
        if not (ps.len - off > h.active or (ps.len > 0 and ps[^1].typ.startsWith("varargs"))): continue
        var score = 1
        if h.ufcs and h.recv.len > 0 and ps.len > 0:
          let c = nxCompatP(sc, ps[0], r.sym.generics, h.recv)
          if c == 0: continue
          score += c
        var fits = true
        for k, at in argTypes:
          if at.len == 0 or k + off >= ps.len: continue
          let c = nxCompatP(sc, ps[k + off], r.sym.generics, at)
          if c == 0:
            fits = false
            break
          score += c
        if fits and score > bestScore:
          bestScore = score
          pick = i
      if bestScore < 0:
        for i, r in h.overloads:
          let ps = r.sym.params
          if ps.len - (if h.ufcs: 1 else: 0) > h.active or (ps.len > 0 and ps[^1].typ.startsWith("varargs")):
            pick = i
            break
  except Exception as e: internalError("Nim index", e)
  let s = h.overloads[pick].sym
  let binds = if h.ufcs and h.recv.len > 0: nxBindings(s, h.recv) else: initTable[string, string]()
  let (lbl, spans) = nxSigLabel(s, h.ufcs, binds)
  sigLabel = lbl
  sigHl = (0, 0)
  if spans.len > 0:
    if h.active < spans.len: sigHl = spans[h.active]
    elif s.params[^1].typ.startsWith("varargs"): sigHl = spans[^1]
  sigDoc = nxRstToMd(s.doc)
  sigMore = if h.overloads.len > 1: $(pick + 1) & "/" & $h.overloads.len else: ""
  sigLine = p.line
  sigOpen = true
  needRender = true
  true

proc nimSourceFiles(): seq[string]

proc engineHover(b: Buffer, p: Pos): string =
  try:
    let f = nxFileFor(b)
    if f == nil: return
    let (sa, se) = b.primary.range
    if sa != se and sa.line == se.line and p.line == sa.line and p.col >= sa.col and p.col <= se.col:
      # a selected expression: its type
      let ex = b.lines[sa.line][sa.col ..< se.col].strip
      if ex.len > 0:
        let t = nxTypeOfExpr(f, nxScope(f), nxLocals(f, b.lines, sa.line, sa.col), ex, sa.line, 0).typ
        var v = nxCtHover(f, ex)                     # (worked out at compile time, when it can be)
        if v == "= " & ex: v = ""
        if t.len > 0 or v.len > 0:
          return "```nim\n" & ex & (if t.len > 0: ": " & t else: "") & (if v.len > 0: " " & v else: "") &
                 "\n```\nthe " & (if t.len > 0: "type" else: "value") & " of the selection"
    result = nxHover(f, b.lines, p.line, p.col)
    if result.len > 0:
      # a concept: the types that satisfy it; a type: the concepts it satisfies
      let (refs, _, _) = nxTargets(f, b.lines, p.line, p.col)
      if refs.len > 0 and refs[0].sym.kind == nxType:
        let ch = nxConceptHover(refs[0], nimSourceFiles(), f)
        if ch.len > 0: result.add "\n\n" & ch
  except Exception as e: internalError("Nim index", e)

proc engineDefinition(b: Buffer, p: Pos): bool =
  ## jump to the declaration; a list when several fit (overloads the index cannot tell apart)
  var defs: seq[(string, int, int, string)]
  var own = ""
  try:
    let f = nxFileFor(b)
    if f == nil: return false
    own = f.path
    defs = nxDefinition(f, b.lines, p.line, p.col)
  except Exception as e:
    internalError("Nim index", e)
    return false
  if defs.len == 0: return false
  for d in defs.mitems:
    if d[0] == own: d[0] = b.path
  if defs.len == 1:
    pushJump()
    let nb = if defs[0][0] == b.path or defs[0][0].len == 0: b else: openFile(defs[0][0])
    if nb != nil: nb.centerOn(nb.clampPos(Pos(line: defs[0][1], col: defs[0][2])))
    return true
  var items: seq[PickItem]
  for (path, l, c, sig) in defs:
    items.add PickItem(label: sig, detail: relPath(path) & ":" & $(l + 1), icon: "ƒ", path: path, line: l, col: c)
  openPicker(pickSymbol, "Definitions — " & $defs.len, items)
  true

func nxSameDecl(a, b: NxRef): bool =
  a.file.path == b.file.path and a.sym.line == b.sym.line and a.sym.name == b.sym.name

const
  NxRefsLimitMs = 10000
  RefsCutMsg = "Stopped after 10 s: the name is used too often to check every use — the list is incomplete"
var nxRefsCut = false               # the last engineReferences stopped before it looked everywhere

proc nimSourceFiles(): seq[string] =
  ## the project's Nim files (absolute), open buffers first
  var seen: HashSet[string]
  for b in bufs:
    if b.lang.mode == lmNim and b.path.len > 0 and b.title.len == 0 and b.path notin seen:
      seen.incl b.path
      result.add b.path
  for rel in projectFiles():
    if not (rel.endsWith(".nim") or rel.endsWith(".nims")): continue
    let p = if rel.isAbsolute: rel else: rootDir / rel
    if p notin seen:
      seen.incl p
      result.add p

proc nxOpUses(t: NxRef, lines: seq[string], g: NxFile, path: string, hits: var seq[(string, int, int)],
              checked: var int, limit: int, t0: MonoTime, budgetMs = NxRefsLimitMs): bool =
  ## the places in one file where operator `t` is used (each resolved by its operands' types); false: stopped
  ## (more than `limit` places looked at, or out of time)
  let op = t.sym.name
  var st: NxLexState
  for l in 0 ..< lines.len:
    let blank = op notin lines[l]
    if blank and not st.inTriple and st.blockDepth == 0 and '"' notin lines[l] and '#' notin lines[l]: continue
    for (s, e) in nxLexRuns(lines[l], st, true):
      if e - s != op.len or lines[l][s ..< e] != op: continue
      let d = nxSymAt(g, l, s)
      if d >= 0:
        if nxSameDecl(t, NxRef(file: g, idx: int32(d))): hits.add (path, l, s)
        continue
      inc checked
      if (limit >= 0 and checked > limit) or msSince(t0) > budgetMs: return false
      for r in nxOpTargets(g, lines, l, s):
        if nxSameDecl(t, r):
          hits.add (path, l, s)
          break
  true

proc engineOpReferences(b: Buffer, f: NxFile, p: Pos, hits: var seq[(string, int, int)], decl: var string): bool =
  ## Find references on an operator (`a + b`, `` proc `+` ``): its uses whose operands' types pick it
  let (a, e) = nxOpRunAt(b.lines[p.line], p.col)
  if a >= e: return false
  let targets = nxOpTargets(f, b.lines, p.line, p.col)
  if targets.len == 0: return false
  let t = targets[0]
  decl = if t.file == f: b.path else: t.file.path
  if not (decl.startsWith(rootDir & "/") or bufIndexByPath(decl) >= 0 or t.file == f):
    return false                   # (system's `+`: its uses are every sum in the project)
  let t0 = getMonoTime()
  var checked = 0
  for path in nimSourceFiles():
    var lines: seq[string]
    let bi = bufIndexByPath(path)
    if bi >= 0: lines = bufs[bi].lines
    else:
      try:
        if getFileSize(path) > 3_000_000: continue
        let text = readFile(path)
        if t.sym.name notin text: continue
        lines = text.splitLines
      except CatchableError: continue
    let g = if path == b.path: f else: nxLoad(path)
    if g == nil: continue
    if not nxOpUses(t, lines, g, path, hits, checked, -1, t0):
      nxRefsCut = true
      break
  true

proc opAtCursor(b: Buffer): string =
  ## the operator at the cursor, backticked (`+`), when there is no word there (Nim)
  if b.lang.mode != lmNim or b.wordAt(b.primary.head).len > 0: return
  let p = b.primary.head
  if p.line >= b.lines.len: return
  let (a, e) = nxOpRunAt(b.lines[p.line], p.col)
  if a < e: result = "`" & b.lines[p.line][a ..< e] & "`"

proc engineReferences(b: Buffer, p: Pos, hits: var seq[(string, int, int)], decl: var string): bool =
  ## every place in the project that names the same declaration as the word at `p` (false: the
  ## index cannot tell what the word is). Each candidate is resolved like the word itself was.
  ## After 4 s the rest are matched by name only; after 10 s it stops (nxRefsCut: the list is partial)
  nxRefsCut = false
  let f = nxFileFor(b)
  if f == nil: return false
  let (a0, e0) = b.wordRangeAt(p)
  if a0.col >= e0.col: return engineOpReferences(b, f, p, hits, decl)
  let w = b.lines[p.line][a0.col ..< e0.col]
  let nw = nxNorm(w)
  var targets: seq[NxRef]
  var locals: seq[NxSym]
  var modPath = ""
  let at = nxSymAt(f, p.line, a0.col)
  if at >= 0: targets = @[NxRef(file: f, idx: int32(at))]
  else: (targets, locals, modPath) = nxTargets(f, b.lines, p.line, a0.col)
  if modPath.len > 0 or (targets.len == 0 and locals.len == 0): return false
  let t0 = getMonoTime()
  decl = if locals.len > 0 or targets[0].file == f: b.path else: targets[0].file.path
  if locals.len > 0:
    # a local: only inside its routine, in this file
    let loc = locals[0]
    let ri = nxEnclosing(f, loc.line)
    let (la, le) = if ri >= 0: (f.syms[ri].line, f.syms[ri].endLine) else: (loc.line, b.lines.high)
    var st: NxLexState
    for l in la .. min(le, b.lines.high):
      for (s, e) in nxIdents(b.lines[l], st):
        if nxNorm(b.lines[l][s ..< e]) != nw: continue
        if l == loc.line and s == loc.col:
          hits.add (b.path, l, s)
          continue
        let (_, ls, _) = nxTargets(f, b.lines, l, s)
        if ls.len > 0 and ls[0].line == loc.line and ls[0].name == loc.name: hits.add (b.path, l, s)
    return true
  let lowW = nw.toLowerAscii
  for path in nimSourceFiles():
    if msSince(t0) > NxRefsLimitMs:
      nxRefsCut = true
      break
    let bi = bufIndexByPath(path)
    var lines: seq[string]
    if bi >= 0: lines = bufs[bi].lines
    else:
      try:
        if getFileSize(path) > 3_000_000: continue
        let text = readFile(path)
        if lowW notin text.toLowerAscii.replace("_", ""): continue
        lines = text.splitLines
      except CatchableError: continue
    let g = nxLoad(path)
    if g == nil: continue
    var st: NxLexState
    var slow = msSince(t0) > 4000          # a huge project: keep going without resolving every name
    for l in 0 ..< lines.len:
      if (l and 255) == 255:
        let ms = msSince(t0)
        slow = ms > 4000
        if ms > NxRefsLimitMs:
          nxRefsCut = true
          break
      if lowW[0] notin lines[l].toLowerAscii: continue
      for (s, e) in nxIdents(lines[l], st):
        if nxNorm(lines[l][s ..< e]) != nw: continue
        let d = nxSymAt(g, l, s)
        var ok = false
        if d >= 0:
          let r = NxRef(file: g, idx: int32(d))
          for t in targets:
            if nxSameDecl(t, r): ok = true
        elif slow: ok = true
        else:
          let (rs, ls, mp) = nxTargets(g, lines, l, s)
          if ls.len == 0 and mp.len == 0:
            for r in rs:
              for t in targets:
                if nxSameDecl(t, r): ok = true
        if ok: hits.add (path, l, s)
  true

proc engineRename(b: Buffer, p: Pos, newName: string): (seq[(string, int, int)], string, int) =
  ## rename with ned's own index: (every place that names what the word at `p` names, why it is not renamed — ""
  ## when it can be, how serious that is: 2 a warning, 0 a note, -1 the index cannot tell what the word is)
  let old = b.wordAt(p)
  let nn = newName.strip
  if nn.len == 0 or not (nn[0] in {'a'..'z', 'A'..'Z', '_'} or nn[0] >= '\x80') or not nn.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}):
    return (@[], "'" & nn & "' is not a Nim identifier", 2)
  if nn in NxKeywords: return (@[], "'" & nn & "' is a Nim keyword", 2)
  var hits: seq[(string, int, int)]
  var decl = ""
  var known = false
  var madeBy = ""
  try:
    let f = nxFileFor(b)
    if f != nil:
      let (a0, _) = b.wordRangeAt(p)
      let (rs, _, _) = nxTargets(f, b.lines, a0.line, a0.col)
      for r in rs:
        if r.sym.made: madeBy = r.file.path & ":" & $(r.sym.line + 1)
  except Exception as e: internalError("Nim index", e)
  if madeBy.len == 0:
    try: known = engineReferences(b, p, hits, decl)
    except Exception as e: internalError("Nim index", e)
  if madeBy.len > 0:
    return (@[], "'" & old & "' is declared by a template call (" & relPath(madeBy) & ") — rename it there, not here", 2)
  if not known: return (@[], "ned cannot tell what '" & old & "' refers to here", -1)
  if nxRefsCut:
    return (@[], "'" & old & "' is used too often in this project to find every use in time (10 s) — not renamed", 2)
  if decl.len > 0 and not decl.startsWith(rootDir & "/") and bufIndexByPath(decl) < 0:
    return (@[], "'" & old & "' is declared in " & decl & " — outside this project, so it is not renamed", 2)
  if hits.len == 0: return (@[], "Nothing to rename", 0)
  (hits, "", 0)
