# ════════════════════════════════════════════════════════════════════════════
#  nedls — the language features, each one the editor's own: completion (engineComplete), hover
#  (engineHover), signature help (engineSignature), definition and references (nxDefinition,
#  engineReferences), rename (engineRename), symbols (the index's declarations), semantic colours (semMapFor
#  and applySem over ned's lexer), inlay hints (engineInlays), formatting (nimFormatAll, formatLineRange) and
#  quick fixes (nimProblemFixes) — turned into LSP's shapes.
# ════════════════════════════════════════════════════════════════════════════

var
  lsCompGen = 0                       # bumps with every completion list (completionItem/resolve checks it)
  lsCompUri = ""
  lsCompLimit = 400                   # items sent at most (the list says it is incomplete beyond that)
  lsResolveEdits = false              # the client resolves additionalTextEdits lazily
  lsHierSymbols = true                # the client takes nested document symbols
  lsInlayBudgetMs = 250               # time for one inlay hint request (the first one reads the imports)
  lsSnippets = true                   # the client expands snippets
  lsFoldLimit = 5000                  # folding ranges sent at most (the client's rangeLimit)
  lsFmtSaid = ""                      # the formatter's last refusal shown (document, version, why)

proc lsEnsureFiles() =
  ## the project's file list, complete (the editor lists it in the background, a slice at a time) — up to 3 s
  if not fileCacheValid: startScan()
  let t0 = getMonoTime()
  while scanning and msSince(t0) < 3000: pumpScan(100)

proc lsEngineOn(d: LsDoc): bool = d != nil and nimEngineOn(d.b)

proc lsMd(s: string): JsonNode = %*{"kind": "markdown", "value": s}

proc lsLocation(path: string, l, c: int, lines: seq[string] = @[]): JsonNode =
  ## a Location for the name at (l, c) of a file
  let ls = if lines.len > 0: lines else: lsLinesOf(path)
  var e = c
  if l >= 0 and l < ls.len: e = lsWordEnd(ls[l], c)
  %*{"uri": lsUriOf(path), "range": lsRangeIn(ls, l, c, l, e)}

# ── completion ──

proc lsImportEdit(d: LsDoc, module: string): JsonNode =
  ## the edit that adds `import module` the way ned does (into an `import std/[…]` list when there is one)
  let b = d.b
  let id = b.id
  let ch = lsDryRun(proc() =
    let x = bufById(id)
    if x != nil: addImport(x, module))
  result = newJArray()
  for (path, before, after) in ch:
    if path == b.path:
      for e in lsLineEdits(before, after, lsEol(b)): result.add e

proc lsCompletion(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  result = %*{"isIncomplete": false, "items": []}
  if not lsEngineOn(d): return
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  if not engineComplete(b, true): return
  inc lsCompGen
  lsCompUri = d.uri
  let line = b.lines[p.line]
  var items = newJArray()
  let n = min(compShown.len, lsCompLimit)
  for k in 0 ..< n:
    let i = compShown[k]
    let it = compItems[i]
    var start = min(compStartCol, p.col)
    var filter = it.filter
    if it.postfix > 0:
      start = min(it.postfix - 1, p.col)
      filter = line[start ..< min(compStartCol, line.len)] & it.filter
    let snip = it.snippet.len > 0 and lsSnippets
    let text = if snip: it.snippet elif it.snippet.len > 0: stripSnippet(it.snippet) else: it.insert
    var j = %*{"label": it.label, "kind": max(1, it.kind), "sortText": align($k, 5, '0'), "filterText": filter,
               "textEdit": {"range": lsRangeIn(b.lines, p.line, start, p.line, p.col), "newText": text},
               "data": {"g": lsCompGen, "i": i, "u": d.uri}}
    if snip: j["insertTextFormat"] = %2
    if it.detail.len > 0: j["detail"] = %it.detail
    if it.nx > 0 and it.nx <= compNx.len:
      let nx = compNx[it.nx - 1]
      if nx.refs.len > 0 and "deprecated" in nx.refs[0].file.syms[nx.refs[0].idx].pragmas: j["tags"] = %*[1]
    if it.addImport.len > 0:
      j["data"]["m"] = %it.addImport
      if not lsResolveEdits: j["additionalTextEdits"] = lsImportEdit(d, it.addImport)
    items.add j
  result["items"] = items
  result["isIncomplete"] = %(compShown.len > n)

proc lsCompletionResolve(item: JsonNode): JsonNode =
  ## the documentation of an item (made only when the client shows it) and the import it adds
  result = item
  let data = item{"data"}
  if data == nil or data.kind != JObject: return
  let d = lsDocs.getOrDefault(data{"u"}.getStr)
  if d == nil: return
  let m = data{"m"}.getStr
  if m.len > 0 and item{"additionalTextEdits"} == nil: result["additionalTextEdits"] = lsImportEdit(d, m)
  if data{"g"}.getInt(-1) != lsCompGen or data{"u"}.getStr != lsCompUri: return
  let i = data{"i"}.getInt(-1)
  if i < 0 or i >= compItems.len: return
  let i0 = bufs.find(d.b)
  if i0 >= 0: curBuf = i0
  let doc = compDocOf(i)
  if doc.len > 0: result["documentation"] = lsMd(doc)

# ── hover, signature help ──

proc lsHover(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  if not lsEngineOn(d): return nil
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  var md = ""
  let ph = pragmaStringHover(b, p)                 # header: "…" / importc: "…": the header, the C declaration
  let (wa, we) = b.wordRangeAt(p)
  let w = b.lines[p.line][wa.col ..< we.col]
  var ra = wa
  var re = we
  if ph.len > 0: md = ph
  else:
    let tk = if w.len > 0: b.tokenAt(p) else: tkText
    let onSymbol = w.len > 0 and not w[0].isDigit and tk notin {tkComment, tkString, tkDoc, tkNumber} and
                   not foreignAt(p.col)
    if onSymbol:
      md = engineHover(b, p)
      let ci = cHoverInfo(b, p)                  # an importc wrapper: the C declaration behind it
      if ci.len > 0: md = (if md.len > 0: md & ci else: ci.strip(trailing = false))
      if md.len == 0: md = nimDocFor(w)          # a keyword
    elif w.len == 0 and opAtCursor(b).len > 0:
      md = engineHover(b, p)                     # an operator: the overload its operands' types pick
      let (oa, oe) = nxOpRunAt(b.lines[p.line], p.col)
      ra = Pos(line: p.line, col: oa)
      re = Pos(line: p.line, col: oe)
  if md.strip.len == 0: return nil
  %*{"contents": lsMd(md), "range": {"start": lsPos(b, ra), "end": lsPos(b, re)}}

proc lsSignatureHelp(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  if not lsEngineOn(d): return nil
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  if not engineSignature(b, p): return nil
  # every overload, in the order ned shows them (the one engineSignature picked is active)
  var pick = 0
  let sl = sigMore.find('/')
  if sl > 0:
    try: pick = parseInt(sigMore[0 ..< sl]) - 1
    except ValueError: pick = 0
  var h: NxSigHelp
  try: h = nxSignatureHelp(nxFileFor(b), b.lines, p.line, p.col)
  except Exception: discard
  let inFor = b.lines[p.line].strip.startsWith("for ")
  var ordered: seq[NxRef]
  for r in h.overloads:
    if (r.sym.kind == nxIterator) == inFor: ordered.add r
  for r in h.overloads:
    if (r.sym.kind == nxIterator) != inFor: ordered.add r
  var sigs = newJArray()
  proc sigJson(lbl: string, spans: seq[(int, int)], active: int, doc: string): JsonNode =
    var ps = newJArray()
    for (a, e) in spans: ps.add %*{"label": [lsChar(lbl, a), lsChar(lbl, e)]}
    result = %*{"label": lbl, "parameters": ps}
    if active >= 0: result["activeParameter"] = %active
    if doc.len > 0: result["documentation"] = lsMd(doc)
  if ordered.len == 0 or pick >= ordered.len:
    sigs.add sigJson(sigLabel, (if sigHl[1] > sigHl[0]: @[sigHl] else: @[]), 0, sigDoc)
    pick = 0
  else:
    for i, r in ordered:
      let s = r.sym
      let binds = if h.ufcs and h.recv.len > 0: nxBindings(s, h.recv) else: initTable[string, string]()
      let (lbl, spans) = nxSigLabel(s, h.ufcs, binds)
      var act = -1
      if i == pick:
        for k, sp in spans:
          if sp == sigHl and sigHl[1] > sigHl[0]: act = k
      else:
        if h.active < spans.len: act = h.active
        elif s.params.len > 0 and s.params[^1].typ.startsWith("varargs"): act = spans.high
      sigs.add sigJson(lbl, spans, act, (if i == pick: sigDoc else: nxRstToMd(s.doc)))
  let act0 = sigs[pick]{"activeParameter"}.getInt(-1)
  result = %*{"signatures": sigs, "activeSignature": pick}
  if act0 >= 0: result["activeParameter"] = %act0

# ── definition, type definition, references, highlights ──

proc lsDefinitions(d: LsDoc, p: Pos): seq[(string, int, int)] =
  ## where the name at p is declared (several when the index cannot tell overloads apart)
  let b = d.b
  let f = nxFileFor(b)
  if f == nil: return
  for (path, l, c, _) in nxDefinition(f, b.lines, p.line, p.col):
    result.add ((if path == f.path: b.path else: path), l, c)

proc lsDefinition(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d): return
  let p = lsToPos(d.b, params{"position"})
  lsFocus(d, p)
  for (path, l, c) in lsDefinitions(d, p):
    if path.len > 0: result.add lsLocation(path, l, c)

proc lsTypeDefinition(params: JsonNode): JsonNode =
  ## the declaration of the type of what is at the position (a variable's, a field's, a routine's result)
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d): return
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  let f = nxFileFor(b)
  if f == nil: return
  let (refs, locals, _) = nxTargets(f, b.lines, p.line, p.col)
  let sc = nxScope(f)
  var t = ""
  var tf = f
  if locals.len > 0:
    t = locals[0].typ
    if t.len == 0: t = nxTypeOfName(f, sc, nxLocals(f, b.lines, p.line, p.col), locals[0].name, p.line, 0).typ
  elif refs.len > 0:
    let r = refs[0]
    let s = r.sym
    tf = r.file
    case s.kind
    of nxType: t = s.name
    of NxRoutineKinds: t = s.ret
    of nxEnumVal: t = s.owner
    else:
      t = s.typ
      if t.len == 0 and s.value.len > 0: t = nxTypeOfExpr(r.file, nxScope(r.file), @[], s.value, s.line, 0).typ
  if t.len == 0: return
  var base = nxBaseName(nxStripMods(t))
  let el = nxElemType(t)                       # seq[Foo] → Foo, when Foo is declared and seq is not
  let tsc = nxScope(tf)
  var found = nxTypeSyms(tsc, base)
  if found.len == 0 and el.len > 0:
    base = nxBaseName(nxStripMods(el))
    found = nxTypeSyms(tsc, base)
  for r in found:
    if r.sym.kind == nxType:
      let path = if r.file == f: b.path else: r.file.path
      result.add lsLocation(path, r.sym.line, r.sym.col)

proc lsDeclPositions(d: LsDoc, p: Pos): HashSet[(string, int, int)] =
  ## where what the name at p names is declared (its own place counts as a use only when the client asks)
  for (path, l, c) in lsDefinitions(d, p): result.incl (path, l, c)

proc lsReferences(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d): return
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  lsEnsureFiles()
  var hits: seq[(string, int, int)]
  var decl = ""
  if not engineReferences(b, p, hits, decl): return
  let withDecl = params{"context"}{"includeDeclaration"}.getBool(true)
  let decls = if withDecl: initHashSet[(string, int, int)]() else: lsDeclPositions(d, p)
  var seen: HashSet[(string, int, int)]
  for h in hits:
    if h in seen or h in decls: continue
    seen.incl h
    result.add lsLocation(h[0], h[1], h[2])
  if nxRefsCut: lsShowMessage(2, RefsCutMsg)

proc lsFileUses(d: LsDoc, p: Pos): seq[(int, int, int)] =
  ## the places in this file that name what the name at p names: (line, column, end column) — each one resolved
  ## as Find references does; after 60 ms the rest by name only (it is asked at every move of the cursor)
  let b = d.b
  let f = nxFileFor(b)
  if f == nil: return
  let (a0, e0) = b.wordRangeAt(p)
  if a0.col >= e0.col: return
  let w = b.lines[p.line][a0.col ..< e0.col]
  if w[0].isDigit or w in NxKeywords: return
  let nw = nxNorm(w)
  var targets: seq[NxRef]
  var locals: seq[NxSym]
  var modPath = ""
  let at = nxSymAt(f, p.line, a0.col)
  if at >= 0: targets = @[NxRef(file: f, idx: int32(at))]
  else: (targets, locals, modPath) = nxTargets(f, b.lines, p.line, a0.col)
  var la = 0
  var le = b.lines.high
  if locals.len > 0:
    let ri = nxEnclosing(f, locals[0].line)
    if ri >= 0: (la, le) = (f.syms[ri].line, min(f.syms[ri].endLine, b.lines.high))
  let byName = modPath.len > 0 or (targets.len == 0 and locals.len == 0)
  let t0 = getMonoTime()
  var st: NxLexState
  for l in 0 .. le:
    let s = b.lines[l]
    let ids = nxIdents(s, st)                       # (the lexer state follows every line)
    if l < la: continue
    for (c, e) in ids:
      if nxNorm(s[c ..< e]) != nw: continue
      var ok = false
      if byName or msSince(t0) > 60: ok = s[c ..< e] == w or not byName
      elif locals.len > 0:
        if l == locals[0].line and c == locals[0].col: ok = true
        else:
          let (_, ls, _) = nxTargets(f, b.lines, l, c)
          ok = ls.len > 0 and ls[0].line == locals[0].line and ls[0].name == locals[0].name
      else:
        let k = nxSymAt(f, l, c)
        if k >= 0:
          let r = NxRef(file: f, idx: int32(k))
          for t in targets:
            if nxSameDecl(t, r): ok = true
        else:
          let (rs, ls, mp) = nxTargets(f, b.lines, l, c)
          if ls.len == 0 and mp.len == 0:
            for r in rs:
              for t in targets:
                if nxSameDecl(t, r): ok = true
      if ok: result.add (l, c, e)

proc lsDocumentHighlight(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d): return
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  let f = nxFileFor(b)
  for (l, c, e) in lsFileUses(d, p):
    let kind = if f != nil and nxSymAt(f, l, c) >= 0: 3 else: 2      # its declaration: Write, a use: Read
    result.add %*{"range": lsRangeIn(b.lines, l, c, l, e), "kind": kind}

# ── rename ──

proc lsPrepareRename(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  if not lsEngineOn(d): return nil
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  let (a, e) = b.wordRangeAt(p)
  if a.col >= e.col: lsRaise(ErrRequestFailed, "an operator keeps its name")
  let w = b.lines[p.line][a.col ..< e.col]
  if w[0].isDigit or w in NxKeywords: lsRaise(ErrRequestFailed, "'" & w & "' cannot be renamed")
  let tk = b.tokenAt(p)
  if tk in {tkComment, tkString, tkDoc, tkNumber}: lsRaise(ErrRequestFailed, "not a name in the code")
  let f = nxFileFor(b)
  if f == nil: return nil
  let at = nxSymAt(f, p.line, a.col)
  if at < 0:
    let (rs, ls, mp) = nxTargets(f, b.lines, p.line, a.col)
    if mp.len > 0: lsRaise(ErrRequestFailed, "'" & w & "' is a module: rename its file")
    if rs.len == 0 and ls.len == 0: lsRaise(ErrRequestFailed, "ned cannot tell what '" & w & "' refers to here")
    if ls.len == 0:
      let dp = rs[0].file.path
      if rs[0].file != f and not dp.startsWith(rootDir & "/") and lsDocByPath(dp) == nil:
        lsRaise(ErrRequestFailed, "'" & w & "' is declared in " & dp & " — outside this project, so it is not renamed")
      for r in rs:
        if r.sym.made:
          lsRaise(ErrRequestFailed, "'" & w & "' is declared by a template call (" & relPath(r.file.path) & ":" &
                  $(r.sym.line + 1) & ") — rename it there, not here")
  %*{"range": lsRangeIn(b.lines, a.line, a.col, e.line, e.col), "placeholder": w}

proc lsRename(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  if not lsEngineOn(d): return nil
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  lsEnsureFiles()
  let nn = params{"newName"}.getStr.strip
  let old = b.wordAt(p)
  let (hits, why, sev) = engineRename(b, p, nn)
  if why.len > 0:
    if sev == 0: return %*{"changes": {}}
    lsRaise(ErrRequestFailed, why)
  # each place as applyRenameHits finds it: the name there (style-insensitively), bottom-up per file
  var byFile: Table[string, seq[(int, int)]]
  var order: seq[string]
  for (path, l, c) in hits:
    if path notin byFile: order.add path
    byFile.mgetOrPut(path, @[]).add (l, c)
  var changes = newJObject()
  let lowOld = old.replace("_", "").toLowerAscii
  for path in order:
    let ls = lsLinesOf(path)
    var es = newJArray()
    var done: HashSet[(int, int)]
    for (l, c) in byFile[path]:
      if l >= ls.len or (l, c) in done: continue
      done.incl (l, c)
      let s = ls[l]
      var col = c
      var e = col + old.len
      if not s.continuesWith(old, col):
        var k = col
        while k < s.len and isWordByte(s[k]): inc k
        if k > col and s[col ..< k].replace("_", "").toLowerAscii == lowOld and s[col] == old[0]: e = k
        else:
          let j = s.find(old)
          if j < 0: continue
          col = j
          e = j + old.len
      es.add %*{"range": lsRangeIn(ls, l, col, l, e), "newText": nn}
    if es.len > 0: changes[lsUriOf(path)] = es
  %*{"changes": changes}

# ── symbols ──

proc lsSymbolKind(s: NxSym): int =
  case s.kind
  of nxProc, nxFunc, nxIterator, nxConverter, nxTemplate, nxMacro: 12
  of nxMethod: 6
  of nxType:
    let t = s.typ.strip
    if t.startsWith("enum"): 10
    elif t.startsWith("concept"): 11
    elif t.startsWith("ref object") or t.startsWith("ptr object"): 5
    elif t.startsWith("object") or t.startsWith("tuple"): 23
    else: 5
  of nxField: 8
  of nxEnumVal: 22
  of nxConst: 14
  of nxLet, nxVar, nxParam, nxForVar, nxResult: 13
  of nxModule: 2

proc lsSymDetail(s: NxSym): string =
  case s.kind
  of NxRoutineKinds: nxKindWord(s.kind) & " " & nxShortDetail(s)
  of nxType:
    let w = s.typ.split({' ', '['})[0]
    if w.len > 0: w else: "type"
  of nxEnumVal: ""
  else: nxShortDetail(s)

proc lsDocumentSymbol(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d): return
  let b = d.b
  let f = nxFileFor(b)
  if f == nil: return
  proc symJson(s: NxSym): JsonNode =
    let l = clamp(s.line, 0, b.lines.high)
    let s0 = b.lines[l]
    let c = min(s.col, s0.len)
    let e = lsWordEnd(s0, c)
    var last = if s.endLine > l and s.endLine <= b.lines.high: s.endLine else: l
    let name = if s.name.len > 0: s.name else: "?"
    result = %*{"name": name, "kind": lsSymbolKind(s),
                "range": lsRangeIn(b.lines, l, 0, last, b.lines[last].len),
                "selectionRange": lsRangeIn(b.lines, l, c, l, e)}
    let det = lsSymDetail(s)
    if det.len > 0: result["detail"] = %det
    if "deprecated" in s.pragmas: result["tags"] = %*[1]
  if not lsHierSymbols:
    for s in f.syms:
      if s.kind == nxModule or s.local: continue
      let j = symJson(s)
      var si = %*{"name": j["name"], "kind": j["kind"], "location": {"uri": d.uri, "range": j["range"]}}
      if s.owner.len > 0 and s.kind in {nxField, nxEnumVal}: si["containerName"] = %s.owner
      result.add si
    return
  # types hold their fields and values; everything else at the top
  var typeAt: Table[string, int]          # owner name → index in result (the last type of that name)
  var typeEnd: seq[int]
  for s in f.syms:
    if s.kind == nxModule or s.local or s.line < 0 or s.line > b.lines.high: continue
    let j = symJson(s)
    if s.kind in {nxField, nxEnumVal} and s.owner.len > 0 and s.owner in typeAt:
      let k = typeAt[s.owner]
      let parent = result[k]
      if parent{"children"} == nil: parent["children"] = newJArray()
      parent["children"].add j
      # (the type's range covers its members)
      let pe = parent["range"]["end"]["line"].getInt
      if s.line > pe: parent["range"]["end"] = lsPosIn(b.lines, s.line, b.lines[s.line].len)
      continue
    result.add j
    if s.kind == nxType: typeAt[s.name] = result.len - 1

proc lsWorkspaceSymbol(params: JsonNode): JsonNode =
  ## the project's declarations whose names fit the query (as ned's Go to symbol in project matches them)
  result = newJArray()
  lsEnsureFiles()
  let q = params{"query"}.getStr.strip.toLowerAscii
  var hits: seq[(int, string, NxSym)]
  var hl: seq[int]
  let t0 = getMonoTime()
  var paths: seq[string]
  var seen: HashSet[string]
  for u, d in lsDocs:
    if d.b.path.len > 0 and d.b.lang.mode == lmNim and d.b.path notin seen:
      seen.incl d.b.path
      paths.add d.b.path
  for rel in projectFiles():
    if not (rel.endsWith(".nim") or rel.endsWith(".nims")): continue
    let p = if rel.isAbsolute: rel else: rootDir / rel
    if p notin seen:
      seen.incl p
      paths.add p
  for path in paths:
    if msSince(t0) > 2500: break
    var f: NxFile
    try: f = nxLoad(path)
    except Exception: continue
    if f == nil: continue
    for s in f.syms:
      if s.kind == nxModule or s.local or s.name.len == 0: continue
      var score = 0
      if q.len > 0:
        score = fuzzyMatch(q, s.name, hl)
        if score == low(int): continue
      hits.add (score, path, s)
  hits.sort(proc(a, b: (int, string, NxSym)): int = cmp(b[0], a[0]))
  for k in 0 ..< min(hits.len, 500):
    let (_, path, s) = hits[k]
    var j = %*{"name": s.name, "kind": lsSymbolKind(s), "location": lsLocation(path, s.line, s.col)}
    if s.owner.len > 0 and s.kind in {nxField, nxEnumVal}: j["containerName"] = %s.owner
    else: j["containerName"] = %nxModuleName(path)
    result.add j

# ── semantic tokens: ned's colours ──

const
  LsTokTypes = ["namespace", "type", "enumMember", "variable", "parameter", "property", "function", "macro"]
  LsTokMods = ["declaration", "readonly", "static", "deprecated"]

proc lsTokOf(k: TokKind): (int, int) =
  ## an LSP token type and modifiers for one of ned's colours (-1: no token)
  case k
  of tkFunc: (6, 0)
  of tkPreproc: (7, 0)
  of tkType: (1, 0)
  of tkConst: (3, 2)                       # (a constant: readonly)
  of tkProperty: (5, 0)
  of tkParam: (4, 0)
  of tkMutable: (3, 0)
  of tkGlobalVar: (3, 4)                   # (static: the module's own)
  of tkGlobal: (3, 2 or 4)
  else: (-1, 0)

proc lsSemanticTokens(d: LsDoc, lo0, hi0: int): string =
  ## the data array of semanticTokens for lines lo..hi, as JSON text
  let b = d.b
  if not lsEngineOn(d) or b.lines.len == 0: return "{\"data\":[]}"
  let lo = clamp(lo0, 0, b.lines.high)
  let hi = clamp(hi0, lo, b.lines.high)
  let t0 = getMonoTime()
  var m = semMapFor(b)
  if m != nil and m.at != b.changeId: m = semMapFor(b)     # (a big file's first map comes on the second call)
  let f = nxFileFor(b)
  var enums: HashSet[string]
  if f != nil:
    try:
      let sc = nxScope(f)
      for r in sc.refs:
        if r.file.syms[r.idx].kind == nxEnumVal: enums.incl nxNorm(r.file.syms[r.idx].name)
      for s in f.syms:
        if s.kind == nxEnumVal: enums.incl nxNorm(s.name)
    except Exception: discard
  let t1 = getMonoTime()
  b.ensureHl(hi + 1)
  var lexT, semT: Duration
  var o = newStringOfCap(4096)
  o.add "{\"data\":["
  var first = true
  var pl = 0
  var pc = 0
  var toks: seq[TokKind]
  for l in lo .. hi:
    let s = b.lines[l]
    if s.len == 0 or s.len > 20000: continue
    let q0 = getMonoTime()
    discard lexLine(b.lang, s, b.hlStart[l], toks)
    let foreign = lexForeign
    let q1 = getMonoTime()
    if m != nil: applySem(s, toks, m, l)
    lexT += q1 - q0
    semT += getMonoTime() - q1
    let ascii = block:
      var a = true
      for ch in s:
        if ch.uint8 >= 0x80:
          a = false
          break
      a
    var i = 0
    let n = min(s.len, toks.len)
    while i < n:
      if s[i] in IdentStartChars and (i == 0 or s[i - 1] notin IdentChars):
        var j = i
        while j < n and s[j] in IdentChars: inc j
        var inForeign = false
        for (fa, fe) in foreign:
          if i >= fa and i < fe: inForeign = true
        var (t, mods) = lsTokOf(toks[i])
        let w = nxNorm(s[i ..< j])
        if toks[i] == tkDeprecated:
          (t, mods) = lsTokOf(if m != nil: m.semKind(w) else: tkText)
          if t < 0: t = 3
          mods = mods or 8
        elif toks[i] == tkType and m != nil and w in m.modules and m.semKind(w) == tkText:
          var q = j
          while q < n and s[q] == ' ': inc q
          if q < n and s[q] == '.': t = 0                  # a module name before a dot: strutils.join
        elif toks[i] == tkConst:
          if w in ["true", "false", "nil"]: t = -1
          elif w in enums: (t, mods) = (2, 0)
        if t >= 0 and not inForeign:
          if f != nil and nxSymAt(f, l, i) >= 0: mods = mods or 1
          let sc = if ascii: i else: lsChar(s, i)
          let ln = if ascii: j - i else: lsChar(s, j) - sc
          let dl = l - pl
          let dc = if dl == 0: sc - pc else: sc
          if not first: o.add ','
          first = false
          o.add $dl & "," & $dc & "," & $ln & "," & $t & "," & $mods
          pl = l
          pc = sc
        i = j
      else: inc i
  o.add "]}"
  if lsVerbose:
    lsLog("semanticTokens: map+scope " & $(t1 - t0).inMilliseconds & " ms, lexer " & $lexT.inMilliseconds &
          " ms, colours " & $semT.inMilliseconds & " ms, all " & $(getMonoTime() - t0).inMilliseconds & " ms")
  o

# ── inlay hints ──

proc lsInlayHints(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d) or not cfgInlayHints or d.b.path.len == 0: return
  let b = d.b
  let r = params{"range"}
  let lo = clamp(lsToPos(b, r{"start"}).line, 0, b.lines.high)
  let hi = clamp(lsToPos(b, r{"end"}).line, lo, b.lines.high)
  lsFocus(d, b.primary.head)
  let t0 = getMonoTime()
  let keep = engineInlayBudget
  engineInlayBudget = lsInlayBudgetMs
  # (the editor asks again for a cut-short round: so does this, while there is time)
  var rounds = 0
  while true:
    engineInlays(b, lo, hi)
    inc rounds
    if b.inlayAt >= 0 or rounds >= 5 or msSince(t0) > lsInlayBudgetMs * 3: break
  engineInlayBudget = keep
  var ls: seq[int]
  for l in b.inlays.keys: ls.add l
  ls.sort()
  for l in ls:
    if l < lo or l > hi or l > b.lines.high: continue
    for (c, label) in b.inlays[l]:
      let isType = label.startsWith(":")
      var lab = label
      if not isType: lab = label.strip(leading = false)
      var h = %*{"position": lsPosIn(b.lines, l, min(c, b.lines[l].len)), "label": lab,
                 "kind": (if isType: 1 else: 2)}
      if not isType: h["paddingRight"] = %true
      result.add h

# ── formatting ──

proc lsInChild(work: proc(): string, timeoutMs = 30_000): (bool, string) =
  ## `work` run in a child process of its own (fork), its answer back through a pipe: what it allocates goes with
  ## it, and work that fails on a strange file — or never ends — takes nothing else down. (false, "") when it
  ## could not run, crashed or took too long
  var fds: array[2, cint]
  if posix.pipe(fds) != 0: return (false, "")
  let pid = posix.fork()
  if pid < 0:
    discard posix.close(fds[0])
    discard posix.close(fds[1])
    return (false, "")
  if pid == 0:
    lsOutBroken = true                  # (the child never speaks the protocol)
    discard posix.close(fds[0])
    var msg = ""
    try: msg = work()
    except CatchableError, Defect: msg = ""
    var off = 0
    while off < msg.len:
      let n = posix.write(fds[1], unsafeAddr msg[off], msg.len - off)
      if n > 0: off += n
      elif n < 0 and errno == EINTR: continue
      else: break
    exitnow(if msg.len > 0: 0 else: 1)
  discard posix.close(fds[1])
  var got = ""
  var buf: array[65536, char]
  var timedOut = false
  let t0 = getMonoTime()
  while true:
    let left = timeoutMs - int(msSince(t0))
    if left <= 0:
      discard posix.kill(pid, SIGKILL)
      timedOut = true
      break
    var pfd = TPollfd(fd: fds[0], events: POLLIN)
    let r = poll(addr pfd, 1, cint(min(left, 1000)))
    if r < 0 and errno == EINTR: continue
    if r <= 0: continue
    let n = posix.read(fds[0], addr buf[0], buf.len)
    if n > 0:
      let old = got.len
      got.setLen(old + n)
      copyMem(addr got[old], addr buf[0], n)
    elif n == 0 or errno notin [EINTR, EAGAIN]: break
  discard posix.close(fds[0])
  var st: cint
  discard posix.waitpid(pid, st, 0)
  if timedOut or not WIFEXITED(st) or WEXITSTATUS(st) != 0: return (false, "")
  (true, got)

const LsFmtFailed = "the built-in formatter failed on this file (please report it)"

proc lsFormatAnswer(d: LsDoc, ok: bool, outp, what: string): JsonNode =
  ## a formatting answer from the child: "R" and the edits, or "E" and why the text was left alone
  result = newJArray()
  var err = ""
  if not ok or outp.len == 0: err = LsFmtFailed
  elif outp[0] == 'E': err = outp[1 .. ^1]
  else:
    try: return parseJson(outp[1 .. ^1])
    except CatchableError: err = LsFmtFailed
  # (said once for a text: a client that formats on every save would repeat it)
  if lsFmtSaid != d.uri & "#" & $d.version & err:
    lsFmtSaid = d.uri & "#" & $d.version & err
    lsShowMessage(2, what & ": " & err)

proc lsFormatting(params: JsonNode): JsonNode =
  ## ned's formatter on the whole file (nimFormatAll: checked, and left alone when it is not sure), in a child
  ## process: a big file's formatting and diff cost the server no memory
  let d = lsDocOf(params)
  result = newJArray()
  if d == nil or d.b.lang == nil or d.b.lang.mode != lmNim or d.b.largeOn: return
  let b = d.b
  discard fmtCheckerExe()               # (nim.format.verify: its checker is built here, once — not in each child)
  let (ok, outp) = lsInChild(proc(): string =
    let text = b.allText & "\n"
    let (res, err) = nimFormatAll(text, b.path)
    if err.len > 0: "E" & err
    elif res == text: "R[]"
    else: "R" & $lsLineEdits(b.lines, lsTextLines(res), lsEol(b)))
  result = lsFormatAnswer(d, ok, outp, "format")

proc lsRangeFormatting(params: JsonNode): JsonNode =
  ## the lines of the range, formatted as a block at their own indentation (ned's Format selection)
  let d = lsDocOf(params)
  result = newJArray()
  if d == nil or d.b.lang == nil or d.b.lang.mode != lmNim or d.b.largeOn: return
  let b = d.b
  let r = params{"range"}
  let a = lsToPos(b, r{"start"})
  let e = lsToPos(b, r{"end"})
  var l1 = e.line
  if e.col == 0 and l1 > a.line: dec l1
  lsFocus(d, a)
  discard fmtCheckerExe()
  let (ok, outp) = lsInChild(proc(): string =
    # (in the child the buffer may change: it ends with it)
    let before = lsCopy(b.lines)
    if not b.formatLineRange(a.line, l1, quiet = true):
      return "Ethe built-in formatter left these lines alone (it is not sure of them)"
    "R" & $lsLineEdits(before, b.lines, lsEol(b)))
  result = lsFormatAnswer(d, ok, outp, "format selection")

# ── folding ──

proc lsFoldingRanges(params: JsonNode): JsonNode =
  ## blocks by indentation, as ned folds them: a line and the lines below it indented deeper
  let d = lsDocOf(params)
  result = newJArray()
  if d == nil: return
  let b = d.b
  let limit = lsFoldLimit
  var stack: seq[(int, int)]               # (header line, its indentation)
  var lastCode = -1
  var n = 0
  for l in 0 .. b.lines.len:
    let blank = l < b.lines.len and isBlank(b.lines[l])
    if blank: continue
    let ind = if l < b.lines.len: visColOf(b.lines[l], leadingWs(b.lines[l]).len) else: -1
    while stack.len > 0 and stack[^1][1] >= ind:
      let (h, _) = stack.pop()
      if lastCode > h and n < limit:
        result.add %*{"startLine": h, "endLine": lastCode}
        inc n
    if l < b.lines.len:
      stack.add (l, ind)
      lastCode = l
  # (nested ranges come out innermost first: the client sorts them)

# ── quick fixes ──

proc lsCodeActions(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d) or d.b.path.len == 0: return
  let only = params{"context"}{"only"}
  if only != nil and only.kind == JArray and only.len > 0:
    var want = false
    for k in only.elems:
      if k.getStr == "quickfix" or "quickfix".startsWith(k.getStr): want = true
    if not want: return
  let b = d.b
  let r = params{"range"}
  let a = lsToPos(b, r{"start"})
  let e = lsToPos(b, r{"end"})
  lsFocus(d, a)
  var ds: seq[Diag]
  for x in diagsFor(b.path):
    if x.line <= e.line and max(x.line, x.eline) >= a.line: ds.add x
  ds.sort(proc(x, y: Diag): int = cmp(x.sev, y.sev))
  if ds.len == 0: return
  var fixes: seq[(string, string, Action)]
  try: fixes = nimProblemFixes(b, ds)
  except Exception as ex: lsLog("quick fixes: " & ex.msg)
  for (title, detail, act) in fixes:
    let ch = lsDryRun(act)
    let we = lsWorkspaceEdit(ch)
    if we == nil: continue
    var j = %*{"title": title, "kind": "quickfix", "edit": we}
    result.add j
