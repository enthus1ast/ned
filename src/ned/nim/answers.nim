var nxWarm: HashSet[int]                 # buffers whose imports the index has already read

proc engineWarm(b: Buffer) =
  ## read a Nim file's imports while you are not typing, so the first completion is instant
  if b.id in nxWarm or not nimEngineOn(b): return
  nxWarm.incl b.id
  try: discard nxScope(nxFileFor(b))
  except Exception as e: internalError("Nim index", e)

proc nxKindIcon(k: NxKind): int =
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

proc nxIconText(k: NxKind): string =
  case k
  of NxRoutineKinds: "ƒ"
  of nxType: "T"
  of nxConst, nxEnumVal: "c"
  of nxField: "m"
  else: "v"

proc addImport(b: Buffer, module: string)
proc importedModules(b: Buffer): HashSet[string]
proc stdNamesStarting(lp: string): seq[(string, seq[string])]

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
    try: d = nxDocItem(compNx[nx - 1])
    except Exception as e: internalError("Nim index", e)
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
        if t.len > 0: return "```nim\n" & ex & ": " & t & "\n```\nthe type of the selection"
    result = nxHover(f, b.lines, p.line, p.col)
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

proc nxSameDecl(a, b: NxRef): bool =
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
        if nxSameDecl(t, NxRef(file: g, idx: d)): hits.add (path, l, s)
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
  if at >= 0: targets = @[NxRef(file: f, idx: at)]
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
          let r = NxRef(file: g, idx: d)
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
