# ════════════════════════════════════════════════════════════════════════════
#  nedls — more of what the editor has, as LSP: the call hierarchy (who calls a routine, what it calls), the type
#  hierarchy (an object's ancestors and the types made of it), selection ranges (the selection grows piece by
#  piece of code), code lenses (▶ run a test, a suite, the file, its examples), document links (an import, an
#  include, staticRead's and {.compile.}'s paths), the imports changed when a module is renamed or moved, and a
#  method's implementations (the methods of the types made of its own).
# ════════════════════════════════════════════════════════════════════════════

const LsCmdRun = "nedls.run"          # (a code lens: [uri, line] — what is on that line, run)

proc lsBufFor(path: string): Buffer =
  ## a file as a Buffer: an open document's own, else its text from disk (not one of ned's buffers)
  let d = lsDocByPath(path)
  if d != nil: return d.b
  result = newBuffer()
  result.path = path
  result.lines = lsLinesOf(path)
  if result.lines.len == 0: result.lines = @[""]
  result.lang = langByName("Nim")

proc lsFileFor(b: Buffer): NxFile =
  ## the engine's index of the buffer's file: the open document's live one, else the file loaded from disk
  if lsDocByPath(b.path) != nil: nxFileFor(b) else: nxLoad(b.path)

proc lsSymItem(path: string, lines: seq[string], s: NxSym): JsonNode =
  ## a CallHierarchyItem / TypeHierarchyItem for a declaration: its whole span and its name
  let el = clamp(max(s.endLine, s.line), 0, max(0, lines.high))
  let endCol = if el < lines.len: lines[el].len else: 0
  let ne = if s.line < lines.len: lsWordEnd(lines[s.line], s.col) else: s.col
  %*{"name": s.name, "kind": lsSymbolKind(s), "detail": lsSymDetail(s), "uri": lsUriOf(path),
     "range": lsRangeIn(lines, s.line, 0, el, endCol), "selectionRange": lsRangeIn(lines, s.line, s.col, s.line, ne),
     "data": {"path": path, "line": s.line, "col": s.col}}

proc lsItemSym(item: JsonNode): (Buffer, NxFile, int) =
  ## the declaration an item stands for: (its file as a Buffer, the index's file, its index there; -1 when gone)
  let dt = item{"data"}
  var path = dt{"path"}.getStr
  if path.len == 0: path = lsPathOf(item{"uri"}.getStr)
  let b = lsBufFor(path)
  let f = lsFileFor(b)
  if f == nil: return (b, nil, -1)
  let l = dt{"line"}.getInt(item{"selectionRange"}{"start"}{"line"}.getInt(-1))
  let c = dt{"col"}.getInt(0)
  var at = nxSymAt(f, l, c)
  if at < 0:
    # (the file changed since: the declaration by its name, nearest to where it was)
    let nm = item{"name"}.getStr
    var bestD = high(int)
    for i in 0 ..< f.syms.len:
      if f.syms[i].name == nm and abs(f.syms[i].line - l) < bestD:
        bestD = abs(f.syms[i].line - l)
        at = i
  (b, f, at)

proc lsDeclAt(d: LsDoc, p: Pos, kinds: set[NxKind]): (string, Buffer, NxFile, int) =
  ## the declaration (of these kinds) at p: its own name there, else what the name there refers to
  let b = d.b
  let f = nxFileFor(b)
  if f == nil: return ("", nil, nil, -1)
  let (wa, _) = b.wordRangeAt(p)
  let own = nxSymAt(f, p.line, wa.col)
  if own >= 0 and f.syms[own].kind in kinds: return (b.path, b, f, own)
  let (refs, _, _) = nxTargets(f, b.lines, p.line, p.col)
  for r in refs:
    if r.sym.kind notin kinds: continue
    let path = if r.file == f: b.path else: r.file.path
    let tb = if path == b.path: b else: lsBufFor(path)
    let tf = if path == b.path: f else: lsFileFor(tb)
    if tf == nil: continue
    let i = nxSymAt(tf, r.sym.line, r.sym.col)
    if i >= 0: return (path, tb, tf, i)
  ("", nil, nil, -1)

# ── the call hierarchy ──

proc lsPrepareCallHierarchy(params: JsonNode): JsonNode =
  ## textDocument/prepareCallHierarchy: the routine at the position — the one whose name is there, one the name refers
  ## to, else the routine around the cursor — as the item the client then asks incoming and outgoing calls of; null when
  ## there is none
  let d = lsDocOf(params)
  result = newJNull()
  if not lsEngineOn(d): return
  let p = lsToPos(d.b, params{"position"})
  lsFocus(d, p)
  var (path, tb, tf, i) = lsDeclAt(d, p, NxRoutineKinds)
  if i < 0:
    # (not on a routine's name: the routine around the cursor)
    let f = nxFileFor(d.b)
    if f == nil: return
    let e = nxEnclosing(f, p.line)
    if e < 0 or f.syms[e].kind notin NxRoutineKinds: return
    (path, tb, tf, i) = (d.b.path, d.b, f, e)
  result = %*[lsSymItem(path, tb.lines, tf.syms[i])]

proc lsIncomingCalls(params: JsonNode): JsonNode =
  ## callHierarchy/incomingCalls: the routines that call the item's routine, each with the places of the calls
  ## (nimCallers over the project's files); the module's top level is listed as a module when it calls it
  result = newJArray()
  let (b, f, i) = lsItemSym(params{"item"})
  if f == nil or i < 0: return
  lsEnsureFiles()
  for c in nimCallers(b, f, i):
    let ls = lsLinesOf(c.path)
    var fromItem: JsonNode
    if c.line >= 0:
      let cb = lsBufFor(c.path)
      let cf = lsFileFor(cb)
      let ci = if cf != nil: nxSymAt(cf, c.line, c.col) else: -1
      if ci < 0: continue
      fromItem = lsSymItem(c.path, ls, cf.syms[ci])
    else:
      # (the module's top level calls it)
      fromItem = %*{"name": splitFile(c.path).name, "kind": 2, "uri": lsUriOf(c.path),
                    "range": lsRangeIn(ls, 0, 0, 0, 0), "selectionRange": lsRangeIn(ls, 0, 0, 0, 0),
                    "data": {"path": c.path, "line": -1, "col": 0}}
    var rs = newJArray()
    for (l, col) in c.sites:
      let e = if l < ls.len: lsWordEnd(ls[l], col) else: col
      rs.add lsRangeIn(ls, l, col, l, e)
    result.add %*{"from": fromItem, "fromRanges": rs}
  if nxRefsCut: lsShowMessage(2, RefsCutMsg)

proc lsOutgoingCalls(params: JsonNode): JsonNode =
  ## callHierarchy/outgoingCalls: the routines the item's routine calls (nimCallees), each with the places in its body
  result = newJArray()
  let (b, f, i) = lsItemSym(params{"item"})
  if f == nil or i < 0: return
  for c in nimCallees(b, f, i):
    let cb = lsBufFor(c.path)
    let cf = lsFileFor(cb)
    let ci = if cf != nil: nxSymAt(cf, c.line, c.col) else: -1
    if ci < 0: continue
    var rs = newJArray()
    for (l, col) in c.sites:
      let e = if l < b.lines.len: lsWordEnd(b.lines[l], col) else: col
      rs.add lsRangeIn(b.lines, l, col, l, e)
    result.add %*{"to": lsSymItem(c.path, cb.lines, cf.syms[ci]), "fromRanges": rs}

# ── the type hierarchy ──

proc lsBaseOf(s: NxSym): string =
  ## the type an object type is made of (`object of Base`, `ref object of Base`): Base
  let t = s.typ.strip
  let k = t.find(" of ")
  if k < 0 or not (t.startsWith("object") or t.startsWith("ref object") or t.startsWith("ptr object")): return ""
  var e = k + 4
  while e < t.len and (nxIsIdent(t[e]) or t[e] == '.'): inc e
  t[k + 4 ..< e].split('.')[^1]

proc lsPrepareTypeHierarchy(params: JsonNode): JsonNode =
  ## textDocument/prepareTypeHierarchy: the type declared at, or named at, the position as the item the supertypes and
  ## subtypes are asked of; null when there is none
  let d = lsDocOf(params)
  result = newJNull()
  if not lsEngineOn(d): return
  let p = lsToPos(d.b, params{"position"})
  lsFocus(d, p)
  let (path, tb, tf, i) = lsDeclAt(d, p, {nxType})
  if i < 0: return
  result = %*[lsSymItem(path, tb.lines, tf.syms[i])]

proc lsSupertypes(params: JsonNode): JsonNode =
  ## typeHierarchy/supertypes: the type the item's object type is made of (`object of Base`), when it is declared where
  ## the engine can find it
  result = newJArray()
  let (b, f, i) = lsItemSym(params{"item"})
  if f == nil or i < 0: return
  let base = lsBaseOf(f.syms[i])
  if base.len == 0: return
  let sc = nxScope(f)
  for r in nxTypeSyms(sc, base):
    if r.sym.kind != nxType: continue
    let path = if r.file == f: b.path else: r.file.path
    result.add lsSymItem(path, lsLinesOf(path), r.sym)
    break

proc lsSubtypes(params: JsonNode): JsonNode =
  ## typeHierarchy/subtypes: the object types in the project's Nim files that are made of the item's type
  result = newJArray()
  let (_, f, i) = lsItemSym(params{"item"})
  if f == nil or i < 0: return
  let nm = nxNorm(f.syms[i].name)
  lsEnsureFiles()
  for path in nimSourceFiles():
    let g = lsFileFor(lsBufFor(path))
    if g == nil: continue
    for s in g.syms:
      if s.kind == nxType and nxNorm(lsBaseOf(s)) == nm: result.add lsSymItem(path, lsLinesOf(path), s)

# ── implementations: a method's overrides ──

proc lsImplementation(params: JsonNode): JsonNode =
  ## a method: the methods of the same name for the types made of its receiver's (a routine otherwise: itself)
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d): return
  let p = lsToPos(d.b, params{"position"})
  lsFocus(d, p)
  let (path, _, tf, i) = lsDeclAt(d, p, {nxMethod})
  if i < 0: return lsDefinition(params)
  let s = tf.syms[i]
  lsEnsureFiles()
  for fp in nimSourceFiles():
    let g = lsFileFor(lsBufFor(fp))
    if g == nil: continue
    for t in g.syms:
      if t.kind == nxMethod and nxNorm(t.name) == nxNorm(s.name) and not (fp == path and t.line == s.line):
        result.add lsLocation(fp, t.line, t.col)

# ── selection ranges ──

proc lsSelectionRanges(params: JsonNode): JsonNode =
  ## textDocument/selectionRange: for each position, the chain of ever larger pieces of code around it — the editor's
  ## Expand selection, each step the smallest candidate that holds the one before — as nested ranges, the largest
  ## outermost
  let d = lsDocOf(params)
  result = newJArray()
  let b = d.b
  for pj in jitems(params{"positions"}):
    let p = lsToPos(b, pj)
    # the pieces of code around the position, each one around the one before (the editor's Expand selection)
    var chain: seq[(Pos, Pos)] = @[(p, p)]
    for _ in 0 ..< 40:
      let (a, e) = chain[^1]
      var best = (Pos(line: -1), Pos())
      var bestSize = high(int)
      for (x0, y0) in b.selectionCands(a, e, p):
        let x = b.clampPos(x0)
        let y = b.clampPos(y0)
        if x <= a and e <= y and (x < a or e < y):
          var size = 0
          if x.line == y.line: size = y.col - x.col
          else:
            size = b.lines[x.line].len - x.col + y.col
            for l in x.line + 1 ..< y.line: size += b.lines[l].len + 1
          if size < bestSize:
            bestSize = size
            best = (x, y)
      if best[0].line < 0: break
      chain.add best
    var node = newJNull()
    let lo = if chain.len > 1: 1 else: 0          # (the place itself, empty: not a range to select)
    for k in countdown(chain.high, lo):
      let (a, e) = chain[k]
      var r = %*{"range": lsRangeIn(b.lines, a.line, a.col, e.line, e.col)}
      if node.kind != JNull: r["parent"] = node
      node = r
    result.add node

# ── code lenses: ▶ run what is on a line ──

func lsLensTitle(line: string): string =
  ## the title of the code lens on a line, by what the line starts with: a test, a suite, `when isMainModule`,
  ## runnableExamples, a testament block, a `# %%` cell
  let t = line.strip
  if t.startsWith("test ") or t.startsWith("test\""): "▶ Run the test"
  elif t.startsWith("suite "): "▶ Run the suite"
  elif t.startsWith("when isMainModule"): "▶ Run the file"
  elif t.startsWith("runnableExamples"): "▶ Run the examples"
  elif t.startsWith("discard \"\"\""): "▶ Run this test (testament)"
  elif t.startsWith("# %%"): "▶ Run the cell"
  else: "▶ Run"

proc lsCodeLens(params: JsonNode): JsonNode =
  ## textDocument/codeLens: a run lens on each line the editor puts one on (lensAt), as a command nedls.run with the
  ## document and line; whether to show them is the client's say, not ned's setting
  let d = lsDocOf(params)
  result = newJArray()
  let b = d.b
  if b.path.len == 0: return
  let was = cfgCodeLens
  cfgCodeLens = true                     # (the client asked for them: its own setting decides showing them)
  defer: cfgCodeLens = was
  for l in 0 ..< b.lines.len:
    if b.lines[l].len == 0: continue
    var act: Action
    try: act = lensAt(b, l)[1]
    except CatchableError: continue
    if act == nil: continue
    let ind = b.lines[l].len - b.lines[l].strip(trailing = false).len
    result.add %*{"range": lsRangeIn(b.lines, l, ind, l, b.lines[l].len),
                  "command": {"title": lsLensTitle(b.lines[l]), "command": LsCmdRun, "arguments": [d.uri, l]}}

proc lsRunLens(args: JsonNode) =
  ## a code lens chosen: what is on its line runs as in the editor; what it says comes back as a message
  if args == nil or args.kind != JArray or args.len < 2: lsRaise(ErrInvalidParams, "[uri, line] expected")
  let d = lsDocs.getOrDefault(args[0].getStr)
  if d == nil: lsRaise(ErrInvalidParams, "document not open: " & args[0].getStr)
  let l = args[1].getInt(-1)
  if l < 0 or l > d.b.lines.high: lsRaise(ErrInvalidParams, "no such line")
  lsFocus(d, Pos(line: l, col: 0))
  let was = cfgCodeLens
  cfgCodeLens = true
  let act = lensAt(d.b, l)[1]
  cfgCodeLens = was
  if act == nil:
    lsShowMessage(2, "Nothing to run on line " & $(l + 1))
    return
  let before = jobs.len
  act()
  var j: Job = nil
  if jobs.len > before: j = jobs[^1]
  if j == nil: j = runningJob()
  if j == nil: return
  let what = lsLensTitle(d.b.lines[l]).replace("▶ ", "")
  let prev = j.onDone
  j.onDone = proc(jj: Job) =
    if prev != nil: prev(jj)
    var tail = jj.output.splitLines
    if tail.len > 60: tail = tail[^60 .. ^1]
    lsLogMessage(3, tail.join("\n"))
    var passed, failed = 0
    for ln in jj.output.splitLines:
      let t = stripAnsi(ln).strip
      if t.startsWith("[OK]"): inc passed
      elif t.startsWith("[FAILED]"): inc failed
    let say = if failed > 0: $failed & " failed, " & $passed & " passed"
              elif passed > 0: $passed & " passed"
              elif jj.code == 0: "done"
              else: "failed (exit code " & $jj.code & ")"
    lsShowMessage((if failed > 0 or jj.code != 0: 1 else: 3), what & ": " & say)
    lsDiagsDirty = true

# ── document links ──

proc lsDocumentLinks(params: JsonNode): JsonNode =
  ## the paths a Nim file names, as links: its imports and includes (to the module), staticRead / slurp,
  ## {.compile: ….}, {.link: ….}, {.include: …}
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d): return
  let b = d.b
  let f = nxFileFor(b)
  if f == nil: return
  for im in f.imports:
    let p = nxResolve(f.path, im.spec)
    if p.len == 0 or im.line < 0 or im.line > b.lines.high: continue
    let ln = b.lines[im.line]
    # (the module's name as written on its line: its last part, or the whole spec)
    let last = im.spec.split('/')[^1].strip(chars = {'"', ' '})
    var k = ln.find(im.spec)
    var e = k + im.spec.len
    if k < 0:
      k = ln.find(last)
      e = k + last.len
    if k < 0: continue
    result.add %*{"range": lsRangeIn(b.lines, im.line, k, im.line, e), "target": lsUriOf(p),
                  "tooltip": relPath(p)}
  let dir = parentDir(b.path)
  for l, ln in b.lines:
    for key in ["staticRead(\"", "slurp(\"", "compile: \"", "link: \"", "{.compile(\"", "passL: \""]:
      var k = ln.find(key)
      while k >= 0:
        let a = k + key.len
        let e = ln.find('"', a)
        if e <= a: break
        let rel = ln[a ..< e]
        let p = if rel.isAbsolute: rel else: dir / rel
        if fileExists(p):
          result.add %*{"range": lsRangeIn(b.lines, l, a, l, e), "target": lsUriOf(p), "tooltip": relPath(p)}
        k = ln.find(key, e)

# ── a module renamed or moved: the imports that name it ──

proc lsWillRenameFiles(params: JsonNode): JsonNode =
  ## workspace/willRenameFiles: when .nim files are renamed or moved, the workspace edit that fixes the imports naming
  ## them (importEditsForMove); a message lists the imports it could not change; null when nothing changes
  result = newJNull()
  lsEnsureFiles()
  var changes: seq[(string, seq[string], seq[string])]
  for fj in jitems(params{"files"}):
    let o = lsPathOf(fj{"oldUri"}.getStr)
    let n = lsPathOf(fj{"newUri"}.getStr)
    if not (o.endsWith(".nim") and n.endsWith(".nim")): continue
    let (edits, skipped) = importEditsForMove(o, n)
    for (path, after) in edits:
      changes.add (path, lsLinesOf(path), after)
    if skipped.len > 0: lsShowMessage(2, "Update these imports by hand: " & skipped.join(", "))
  if changes.len > 0: result = lsWorkspaceEdit(changes)
