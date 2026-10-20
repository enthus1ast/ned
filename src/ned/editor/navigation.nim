proc gotoLineText(t: string) =
  let b = buf()
  var s = t.strip
  if s.startsWith(":"): s = s[1 .. ^1]
  if s.len == 0: return
  let parts = s.split({':', ',', ' '})
  try:
    var l = parseInt(parts[0])
    if s[0] in {'+', '-'}: l = b.primary.head.line + 1 + l
    let c = if parts.len > 1 and parts[1].len > 0: parseInt(parts[1]) - 1 else: 0
    pushJump()
    b.centerOn(b.clampPos(Pos(line: l - 1, col: c)))
  except ValueError:
    error("Not a line number: " & s)

proc jumpBack() =
  if jumpStack.len == 0:
    info("Jump list is empty")
    return
  let here = buf()
  if here.path.len > 0: fwdStack.add (here.path, here.primary.head)
  let (path, p) = jumpStack.pop()
  let b = openFile(path)
  if b != nil: b.centerOn(b.clampPos(p))

proc jumpForward() =
  if fwdStack.len == 0:
    info("Nothing to go forward to")
    return
  let here = buf()
  if here.path.len > 0: jumpStack.add (here.path, here.primary.head)
  let (path, p) = fwdStack.pop()
  let b = openFile(path)
  if b != nil: b.centerOn(b.clampPos(p))

proc reopenClosedTab() =
  while closedTabs.len > 0:
    let (path, p) = closedTabs.pop()
    if not fileExists(path) or bufIndexByPath(path) >= 0: continue
    let b = openFile(path)
    if b != nil: b.centerOn(b.clampPos(p))
    return
  info("No closed tabs to reopen")

proc gotoDiag(dir: int) =
  var all: seq[(string, Diag)]
  var paths: HashSet[string]
  for path in diagsLsp.keys: paths.incl path
  for path in diagsBuild.keys: paths.incl path
  for path in diagsAi.keys: paths.incl path
  for path in diagsFfi.keys: paths.incl path
  for path in diagsEmit.keys: paths.incl path
  for path in diagsWeb.keys: paths.incl path
  for path in diagsExt.keys: paths.incl path
  for path in paths:
    for d in diagsFor(path): all.add (path, d)
  if all.len == 0:
    info("No problems")
    return
  all.sort(proc(x, y: (string, Diag)): int =
    result = cmp(x[0], y[0])
    if result == 0: result = cmp(x[1].line * 100000 + x[1].col, y[1].line * 100000 + y[1].col))
  let b = buf()
  let here = (b.path, b.primary.head)
  proc key(x: (string, Diag)): (string, int) = (x[0], x[1].line * 100000 + x[1].col)
  let hk = (here[0], here[1].line * 100000 + here[1].col)
  var idx = -1
  if dir > 0:
    for i, x in all:
      if key(x) > hk:
        idx = i
        break
    if idx < 0: idx = 0
  else:
    for i in countdown(all.high, 0):
      if key(all[i]) < hk:
        idx = i
        break
    if idx < 0: idx = all.high
  let (path, d) = all[idx]
  let nb = openFile(path)
  if nb == nil: return
  nb.centerOn(nb.clampPos(Pos(line: d.line, col: d.col)))
  setMsg((if d.sev == 1: "Error: " elif d.sev == 2: "Warning: " else: "") & diagText(d, path) & fixHint(d), d.sev)

proc heuristicSymbols(b: Buffer): seq[PickItem] =
  var inType = false
  for l, s in b.lines:
    let t = s.strip(trailing = false)
    if t.len == 0: continue
    let indent = s.len - t.len
    if b.lang.mode == lmMarkdown:
      if t.startsWith("#"):
        var h = 0
        while h < t.len and t[h] == '#': inc h
        result.add PickItem(label: spaces((h - 1) * 2) & t[h .. ^1].strip, icon: "#", path: b.path, line: l)
      continue
    if b.lang.lineComment.len > 0 and t.startsWith(b.lang.lineComment): continue
    if indent == 0: inType = false
    var j = 0
    while j < t.len and isWordByte(t[j]): inc j
    let first = t[0 ..< j]
    if b.lang.mode == lmNim and (first == "type" and (j == t.len or t[j] == ' ')):
      inType = true
      if j == t.len: continue
    let isDef = first in b.lang.defWords
    let isCls = first in b.lang.classWords or (first == "type" and b.lang.mode != lmNim and j < t.len)
    if isDef or isCls or (b.lang.mode == lmNim and first == "type"):
      var k = j
      while k < t.len and t[k] == ' ': inc k
      var e = k
      if k < t.len and t[k] == '`':
        e = t.find('`', k + 1) + 1
        if e <= 0: e = t.len
      else:
        while e < t.len and isWordByte(t[e]): inc e
      if e > k:
        result.add PickItem(label: t[k ..< e], detail: first, icon: (if isDef: "ƒ" else: "T"),
                            path: b.path, line: l, col: k + indent)
      continue
    if inType and indent > 0 and j > 0 and first[0] in {'A'..'Z'}:
      var k = j
      if k < t.len and t[k] == '*': inc k
      if k < t.len and t[k] == '[':
        let e = t.find(']', k)
        if e > 0: k = e + 1
      while k < t.len and t[k] == ' ': inc k
      if k < t.len and t[k] == '=':
        result.add PickItem(label: first, detail: "type", icon: "T", path: b.path, line: l, col: indent)
      continue
    if b.lang.mode in {lmC, lmJs} and indent == 0 and '(' in t and not t.endsWith(";") and
       first notin ["if", "for", "while", "switch", "return", "else", "do", "case", "typedef", "export", "import", "const", "let", "var"]:
      let p = t.find('(')
      var e = p
      while e > 0 and t[e-1] == ' ': dec e
      var k = e
      while k > 0 and isWordByte(t[k-1]): dec k
      if e > k: result.add PickItem(label: t[k ..< e], icon: "ƒ", path: b.path, line: l, col: k)

proc cmdSymbols() =
  let b = buf()
  if nimEngineOn(b):
    var items: seq[PickItem]
    try: items = engineSymbols(b)
    except Exception as e: internalError("Nim index", e)
    if items.len > 0:
      openPicker(pickSymbol, "Go to symbol", items)
      return
  let s = lspReady(b)
  if s != nil and s.caps != nil and s.caps{"documentSymbolProvider"} != nil:
    discard s.lspRequest("textDocument/documentSymbol", %*{"textDocument": b.docId},
                         LspReq(kind: lrSymbols, bufId: b.id))
    return
  let items = heuristicSymbols(b)
  if items.len == 0:
    info("No symbols found")
    return
  openPicker(pickSymbol, "Go to symbol", items)

proc isDefLine(lang: Lang, s, w: string): int =
  ## column where `w` is defined on this line, or -1
  let t = s.strip(trailing = false)
  let ind = s.len - t.len
  var kws: seq[string]
  for k in lang.defWords: kws.add k
  for k in lang.classWords: kws.add k
  for k in ["type", "let", "var", "const", "struct", "enum", "interface", "trait", "#define", "class", "def", "fn", "func"]:
    kws.add k
  for kw in kws:
    if t.startsWith(kw & " "):
      var k = kw.len
      while k < t.len and t[k] == ' ': inc k
      if t.startsAt(w, k) and (k + w.len >= t.len or not isWordByte(t[k + w.len])): return ind + k
  if t.startsWith(w) and (w.len == t.len or not isWordByte(t[w.len])):
    var k = w.len
    if k < t.len and t[k] == '*': inc k
    if k < t.len and t[k] == '[':
      let e = t.find(']', k)
      if e > 0: k = e + 1
    while k < t.len and t[k] == ' ': inc k
    if k < t.len and t[k] == '=' and (k + 1 >= t.len or t[k+1] != '='): return ind
  -1

proc cmdReferences()

proc capOn(s: LspServer, name: string): bool =
  ## the server offers this (a capability that is there and not false)
  s != nil and s.caps != nil and s.caps{name} != nil and not (s.caps[name].kind == JBool and not s.caps[name].getBool)

proc nimTypeDefinition(b: Buffer): bool =
  ## Nim (built-in engine): the declaration of the type of the name at the cursor
  try:
    let f = nxFileFor(b)
    if f == nil: return false
    let p = b.primary.head
    let w = b.wordAt(p)
    if w.len == 0: return false
    let sc = nxScope(f)
    var t = nxTypeOfExpr(f, sc, nxLocals(f, b.lines, p.line, p.col), w, p.line, 0).typ.strip
    if t.len == 0: return false
    for pre in ["var ", "ref ", "ptr ", "sink ", "lent ", "static "]:
      if t.startsWith(pre): t = t[pre.len .. ^1].strip
    var names: seq[string]                     # Person · seq[Person] → Person first, then seq
    var cur = ""
    for c in t & " ":
      if c in IdentChars: cur.add c
      else:
        if cur.len > 0 and cur notin names: names.add cur
        cur = ""
    for i in countdown(names.high, 0):
      for r in nxLookup(sc, names[i]):
        if r.sym.kind == nxType:
          let path = if r.file.path == f.path: b.path else: r.file.path
          pushJump()
          let nb = if path == b.path: b else: openFile(path)
          if nb != nil: nb.centerOn(nb.clampPos(Pos(line: r.sym.line, col: r.sym.col)))
          info(w & ": " & t)
          return true
  except Exception as e: internalError("Nim index", e)
  false

proc nimTypeOfWord(b: Buffer, f: NxFile): (string, NxRef) =
  ## the type the word at the cursor names, or the type of the value it names: (its name, its declaration)
  let p = b.primary.head
  let (refs, locals, _) = nxTargets(f, b.lines, p.line, p.col)
  let sc = nxScope(f)
  var typ = ""
  if refs.len > 0 and refs[0].sym.kind == nxType: return (refs[0].sym.name, refs[0])
  if locals.len > 0:
    typ = locals[0].typ
    if typ.len == 0: typ = nxTypeOfName(f, sc, nxLocals(f, b.lines, p.line, p.col), locals[0].name, p.line, 0).typ
  elif refs.len > 0 and refs[0].sym.kind in {nxLet, nxVar, nxConst, nxField, nxParam}:
    typ = refs[0].sym.typ
  if typ.len == 0: return
  let base = nxBaseName(nxStripMods(typ))
  for r in nxTypeSyms(sc, base): return (r.sym.name, r)
  (base, NxRef())

proc nimShownPath(p: string): string =
  ## a path as the pickers show it: project-relative, the standard library's as lib/…
  if nxLibDir.len > 0 and p.startsWith(nxLibDir & "/"): "lib/" & p[nxLibDir.len + 1 .. ^1] else: relPath(p)

proc nimSubtypes(sc: NxScope, name: string): seq[(NxRef, int)] =
  ## the project's object types that inherit from `name`, and theirs (with how many steps down).
  ## Shape = ref ShapeObj: what inherits from ShapeObj counts too
  var frontier = @[nxNorm(name)]
  let (od, _) = nxObjectDef(sc, name)
  if od.file != nil and nxNorm(od.sym.name) notin frontier: frontier.add nxNorm(od.sym.name)
  var seen: HashSet[string]
  for x in frontier: seen.incl x
  var files: seq[NxFile]
  for path in nimSourceFiles():
    let g = nxLoad(path)
    if g != nil: files.add g
  for depth in 1 .. 8:
    var next: seq[string]
    for g in files:
      for i, sy in g.syms:
        if sy.kind != nxType: continue
        let k = sy.typ.find(" of ")
        if k < 0 or "object" notin sy.typ[0 ..< k]: continue
        let parent = nxNorm(nxBaseName(sy.typ[k + 4 .. ^1]))
        if parent in frontier and nxNorm(sy.name) notin seen:
          seen.incl nxNorm(sy.name)
          next.add nxNorm(sy.name)
          result.add (NxRef(file: g, idx: int32(i)), depth)
          # (and the ref type made for it: CircleRef = ref CircleObj)
          for h in files:
            for j, sz in h.syms:
              if sz.kind == nxType and nxNorm(nxBaseName(nxStripMods(sz.typ))) == nxNorm(sy.name) and
                 sz.typ.startsWith("ref ") and nxNorm(sz.name) notin seen:
                seen.incl nxNorm(sz.name)
                next.add nxNorm(sz.name)
    if next.len == 0: break
    frontier = next

proc nimTypeItem(t: NxRef, label: string): PickItem =
  PickItem(label: label, detail: nimShownPath(t.file.path) & ":" & $(t.sym.line + 1) &
                          (if t.sym.typ.len > 0: " · " & t.sym.typ else: ""), icon: "T",
           path: t.file.path, line: t.sym.line, col: t.sym.col)

proc nimTypeHierarchy(b: Buffer): bool =
  ## the object type at the cursor (or a value's type): what it inherits from, and what inherits from it
  var items: seq[PickItem]
  var name = ""
  var here = -1
  try:
    let f = nxFileFor(b)
    if f == nil: return false
    let (nm, r) = nimTypeOfWord(b, f)
    if nm.len == 0: return false
    name = nm
    let sc = if r.file != nil: nxScope(r.file) else: nxScope(f)
    var ups: seq[NxRef]
    for a in nxAncestors(sc, nm):
      for t in nxTypeSyms(sc, a):
        ups.add t
        break
    for k in countdown(ups.high, 0):
      items.add nimTypeItem(ups[k], "↑ " & repeat("  ", ups.high - k) & ups[k].sym.name)
    if r.file != nil:
      here = items.len
      items.add nimTypeItem(r, "• " & repeat("  ", ups.len) & r.sym.name)
    for (t, depth) in nimSubtypes(sc, nm):
      items.add nimTypeItem(t, "↓ " & repeat("  ", ups.len + depth) & t.sym.name)
  except Exception as e:
    internalError("Nim index", e)
    return false
  if items.len <= 1:
    info(name & " inherits from nothing, and nothing in this project inherits from it")
    return true
  openPicker(pickSymbol, "Type hierarchy — " & name & "  (↑ inherits from · ↓ inherit from it)", items)
  if here >= 0: pickSel = max(0, pickShown.find(here))
  true

proc nimImplementations(b: Buffer): bool =
  ## a `method`: the methods of that name for its type and the types that inherit from it (what can run);
  ## a type: the types that inherit from it
  var items: seq[PickItem]
  var name = ""
  try:
    let f = nxFileFor(b)
    if f == nil: return false
    let p = b.primary.head
    let (refs, _, _) = nxTargets(f, b.lines, p.line, p.col)
    if refs.len == 0: return false
    let s0 = refs[0].sym
    let sc = nxScope(refs[0].file)
    if s0.kind == nxType and nxIsConcept(s0):
      # a concept: the types that satisfy it (the engine sure of each)
      name = s0.name
      let (yes, _, unsure, _) = nxConceptImpls(refs[0], nimSourceFiles(), f, 2000)
      for (n, t) in yes:
        if t.file == nil: continue
        items.add PickItem(label: n, detail: nimShownPath(t.file.path) & ":" & $(t.sym.line + 1) & " · satisfies " &
                           s0.name, icon: "T", path: t.file.path, line: t.sym.line, col: t.sym.col)
      if items.len == 0:
        info("No type of this project is known to satisfy " & name &
             (if unsure > 0: " (" & $unsure & " the engine cannot tell)" else: ""))
        return true
    elif s0.kind == nxType:
      name = s0.name
      for (t, depth) in nimSubtypes(sc, s0.name):
        items.add nimTypeItem(t, repeat("  ", depth - 1) & t.sym.name)
    elif s0.kind == nxMethod and s0.params.len > 0:
      name = s0.name
      let base = nxBaseName(nxStripMods(s0.params[0].typ))
      var family: HashSet[string]
      family.incl nxNorm(base)
      let (od, _) = nxObjectDef(sc, base)
      if od.file != nil: family.incl nxNorm(od.sym.name)
      for (t, _) in nimSubtypes(sc, base): family.incl nxNorm(t.sym.name)
      for path in nimSourceFiles():
        let g = nxLoad(path)
        if g == nil: continue
        for i, sy in g.syms:
          if sy.kind == nxMethod and nxNorm(sy.name) == nxNorm(s0.name) and sy.params.len > 0 and
             nxNorm(nxBaseName(nxStripMods(sy.params[0].typ))) in family:
            items.add PickItem(label: sy.name & "(" & nxParamsText(sy.params, false) & ")" &
                               (if "base" in sy.pragmas: "  {.base.}" else: ""),
                               detail: nimShownPath(g.path) & ":" & $(sy.line + 1), icon: "ƒ", path: g.path,
                               line: sy.line, col: sy.col)
    else: return false
  except Exception as e:
    internalError("Nim index", e)
    return false
  if items.len == 0:
    info("Nothing in this project implements or inherits from " & name)
    return true
  if items.len == 1:
    pushJump()
    let nb = if items[0].path == b.path: b else: openFile(items[0].path)
    if nb != nil: nb.centerOn(nb.clampPos(Pos(line: items[0].line, col: items[0].col)))
    return true
  openPicker(pickSymbol, "Implementations — " & name, items)
  true

proc cmdTypeDefinition() =
  let b = buf()
  if nimEngineOn(b) and nimTypeDefinition(b): return
  let s = lspReady(b)
  if s.capOn("typeDefinitionProvider"):
    lspSync(b)
    discard s.lspRequest("textDocument/typeDefinition", %*{"textDocument": b.docId,
      "position": s.lspPos(b, b.primary.head)}, LspReq(kind: lrTypeDef, bufId: b.id))
  else: info("No type definition here" & (if s == nil and b.lang.mode != lmNim: " (it needs a language server)" else: ""))

proc cmdImplementation() =
  let b = buf()
  let s = lspReady(b)
  if nimEngineOn(b) and nimImplementations(b): return
  if s.capOn("implementationProvider"):
    lspSync(b)
    discard s.lspRequest("textDocument/implementation", %*{"textDocument": b.docId,
      "position": s.lspPos(b, b.primary.head)}, LspReq(kind: lrImpl, bufId: b.id))
  elif b.lang.mode == lmNim: cmdReferences()            # Nim has no interfaces: where it is used
  else: info("The language server does not find implementations" & (if s == nil: " (none is running)" else: ""))

proc cmdTypeHierarchy() =
  let b = buf()
  if nimEngineOn(b) and nimTypeHierarchy(b): return
  let s = lspReady(b)
  if not s.capOn("typeHierarchyProvider"):
    info("Type hierarchy needs a language server that offers it (Java, C++, TypeScript …)")
    return
  lspSync(b)
  discard s.lspRequest("textDocument/prepareTypeHierarchy", %*{"textDocument": b.docId,
    "position": s.lspPos(b, b.primary.head)}, LspReq(kind: lrTypePrep, bufId: b.id))

proc lspExtras(b: Buffer) =
  ## when the editor is idle: the server's folding ranges, and the uses of the symbol at the cursor
  if b.path.len == 0: return
  let s = lspReady(b)
  if s == nil: return
  if s.capOn("foldingRangeProvider") and b.lspFoldsAt != b.changeId and msSince(b.lspChangeAt) > 500 and
     b.lines.len < 100_000:
    b.lspFoldsAt = b.changeId
    lspSync(b)
    discard s.lspRequest("textDocument/foldingRange", %*{"textDocument": b.docId},
                         LspReq(kind: lrFolding, bufId: b.id, version: b.changeId))
  if cfgHighlightOcc and s.capOn("documentHighlightProvider"):
    let h = b.primary.head
    if (docHl.bufId != b.id or docHl.pos != h or docHl.change != b.changeId) and msSince(navAt) > 150:
      docHl = (b.id, b.changeId, h, @[])
      if not b.primary.hasSel and b.wordAt(h).len > 0:
        lspSync(b)
        discard s.lspRequest("textDocument/documentHighlight", %*{"textDocument": b.docId,
          "position": s.lspPos(b, h)}, LspReq(kind: lrHighlight, bufId: b.id, pos: h))

proc cmdDefinition() =
  let b = buf()
  if openLinkAt(b, b.primary.head): return       # a link: #include "x.h", @import, a URL in a comment
  if b.lang.mode == lmNim and pragmaStringGoto(b, b.primary.head): return  # header: "…" opens it, importc: "…" its C
  if cEngineOn(b) and cEngDefinition(b, b.primary.head): return          # C: ned's own engine
  if webDefinition(b, b.primary.head): return                            # JavaScript: ned's own engine
  if b.lang.mode == lmNim and emitGoto(b, b.primary.head): return          # in an emit: the C (or Nim) side
  if b.lang.mode == lmNim and cGotoFromDecl(b, b.primary.head): return     # an importc declaration: C's
  if nimEngineOn(b) and b.wordAt(b.primary.head).len > 0:
    if engineDefinition(b, b.primary.head): return
    if nsUsable(b) and nsRequest(b, nsDef, b.primary.head): return
    if compilerAnswer(b, nsDef, b.primary.head): return        # (nimsuggest off: the compiler, once)
  elif nimEngineOn(b) and opAtCursor(b).len > 0:
    if engineDefinition(b, b.primary.head): return
  let s = lspReady(b)
  if s != nil and s.caps != nil and s.caps{"definitionProvider"} != nil:
    discard s.lspRequest("textDocument/definition", %*{"textDocument": b.docId,
      "position": s.lspPos(b, b.primary.head)}, LspReq(kind: lrDefinition, bufId: b.id))
    return
  if s == nil and nsUsable(b) and b.wordAt(b.primary.head).len > 0:
    if nsRequest(b, nsDef, b.primary.head): return
  let w = b.wordAt(b.primary.head)
  if w.len == 0:
    info("No symbol under cursor")
    return
  var hits: seq[PickItem]
  for l, s in b.lines:
    let c = isDefLine(b.lang, s, w)
    if c >= 0: hits.add PickItem(label: relPath(b.path) & ":" & $(l + 1), detail: s.strip, path: b.path, line: l, col: c)
  if hits.len == 0:
    var scanned = 0
    for rel in projectFiles():
      let path = if rel.isAbsolute: rel else: rootDir / rel
      if path == b.path or detectLang(path, "") != b.lang: continue
      inc scanned
      if scanned > 3000: break
      try:
        var l = 0
        for s in lines(path):
          let c = isDefLine(b.lang, s, w)
          if c >= 0: hits.add PickItem(label: rel & ":" & $(l + 1), detail: s.strip, path: path, line: l, col: c)
          inc l
      except CatchableError: discard
      if hits.len > 50: break
  if hits.len == 0: info("No definition found for " & w)
  elif hits.len == 1:
    pushJump()
    let nb = openFile(hits[0].path)
    if nb != nil: nb.centerOn(nb.clampPos(Pos(line: hits[0].line, col: hits[0].col)))
  else: openPicker(pickSymbol, "Definitions of " & w, hits)

proc prettyNimError(msg: string): string =
  ## Nim's "type mismatch" (dozens of lines of overloads) → what you gave, the closest candidate and
  ## what is wrong with it, and how many others there were
  if "type mismatch" in msg and "Expected one of" in msg: return prettyNimError2(msg)
  if "type mismatch" notin msg or "expected one of" notin msg: return msg
  let ls = msg.splitLines
  var got = ""
  var expr = ""
  var cands: seq[(string, seq[string], int)]          # signature, detail lines, mismatch position
  var inCands = false
  for l in ls:
    let t = l.strip
    if t.startsWith("type mismatch: got"):
      got = t["type mismatch: got".len .. ^1].strip
      if got.startsWith("<") and got.endsWith(">"): got = got[1 ..< got.high]
    elif t.startsWith("but expected one of"): inCands = true
    elif t.startsWith("expression:"):
      expr = t["expression:".len .. ^1].strip
      inCands = false
    elif inCands and t.len > 0:
      if not (l.startsWith(" ") or l.startsWith("\t")):
        cands.add (t, @[], 0)
      elif cands.len > 0:
        cands[^1][1].add t
        if t.startsWith("first type mismatch at position:"):
          try: cands[^1][2] = parseInt(t.split(':')[^1].strip)
          except ValueError: discard
  if cands.len == 0: return msg
  var best = 0
  for i, c in cands:
    if c[2] > cands[best][2]: best = i
  result = "type mismatch" & (if expr.len > 0: " in `" & expr & "`" else: "") & "\n"
  if got.len > 0: result.add "  you gave:  (" & got & ")\n"
  result.add "  closest:   " & cands[best][0] & "\n"
  for d in cands[best][1]:
    if d.startsWith("required type for") or d.startsWith("but expression") or d.startsWith("first type mismatch") or
       d.startsWith("missing parameter") or d.startsWith("extra argument"):
      result.add "             " & d & "\n"
  if cands.len > 1:
    var names: seq[string]
    for i, c in cands:
      if i != best and names.len < 4: names.add c[0].split('(')[0]
    result.add "  " & $(cands.len - 1) & " other candidate" & (if cands.len > 2: "s" else: "") & ": " & names.join(" · ")

proc cmdHover(auto = false) =
  let b = buf()
  let p = b.primary.head
  # a selected expression: its type
  let (sa, se) = b.primary.range
  if not auto and sa != se and sa.line == se.line and nimEngineOn(b):
    let ex = b.getText(sa, se).strip
    try:
      let f = nxFileFor(b)
      if f != nil and ex.len > 0:
        let t = nxTypeOfExpr(f, nxScope(f), nxLocals(f, b.lines, sa.line, sa.col), ex, sa.line, 0).typ
        var v = nxCtHover(f, ex)                     # (worked out at compile time, when it can be)
        if v == "= " & ex: v = ""
        if t.len > 0 or v.len > 0:
          showHover("```nim\n" & ex & (if t.len > 0: ": " & t else: "") & (if v.len > 0: " " & v else: "") &
                    "\n```")
          return
    except Exception as e: internalError("Nim index", e)
  var lines: seq[string]
  for d in diagsFor(b.path):
    if d.line <= p.line and p.line <= max(d.line, d.eline):
      if auto and d.sev > 2: continue
      let pm = if b.lang.mode == lmNim: prettyNimError(d.msg) else: d.msg
      if pm != d.msg: lines.add "**error**\n```text\n" & pm.strip(leading = false) & "\n```"     # keep its layout
      else: lines.add (if d.sev == 1: "error: " elif d.sev == 2: "warning: " else: "info: ") & d.msg
  let rh = reviewHoverAt(b.path, p.line)              # a review comment of the pull request
  if rh.len > 0: lines.add rh
  if cfgShowCopies and b.id in copyMarks and p.line in copyMarks[b.id]:
    for m in copyMarks[b.id][p.line]:
      if m.text == b.lines[p.line] and p.col >= m.startCol and p.col <= m.col: lines.add m.what
  hoverPrefix = if lines.len > 0: lines.join("\n") & "\n\n" else: ""
  if b.lang.mode == lmNim:
    let ph = pragmaStringHover(b, p)             # header: "…" / importc: "…": the header, the C declaration
    if ph.len > 0:
      showHoverAuto(hoverPrefix & ph, auto)
      return
  let w = b.wordAt(p)
  let tk = if w.len > 0: b.tokenAt(p) else: tkText
  let onSymbol = w.len > 0 and not w[0].isDigit and tk notin {tkComment, tkString, tkDoc, tkNumber} and
                 not foreignAt(p.col)
  if w.len > 0 and not onSymbol and b.lang.mode == lmNim and tk notin {tkComment, tkString, tkDoc} and
     foreignAt(p.col):
    if embHover(b, p, auto):                     # HTML, CSS, SQL … in a string: its server's hover
      if lines.len > 0: showHoverAuto(hoverPrefix, auto)
      return
    let wh = webHoverInfo(b, p)                  # … ned's own
    if wh.len > 0:
      showHoverAuto(hoverPrefix & wh, auto)
      return
    if emitLspHover(b, p, auto):                 # C in an emit: clangd's hover, when installed
      if lines.len > 0: showHoverAuto(hoverPrefix, auto)
      return
    let eh = emitHoverInfo(b, p)                 # C in an emit: its declaration
    if eh.len > 0:
      showHoverAuto(hoverPrefix & eh, auto)
      return
  if onSymbol and dbgOn:
    let v = dbgValueOf(w)                  # stopped in the debugger: the variable's value
    if v.len > 0:
      showHoverAuto(hoverPrefix & v, auto)
      return
  if not onSymbol and nimEngineOn(b) and opAtCursor(b).len > 0:
    let h = engineHover(b, p)                    # an operator: the overload its operands' types pick
    if h.len > 0:
      showHoverAuto(hoverPrefix & h, auto)
      return
  if onSymbol and cEngineOn(b):
    let ch = cEngHover(b, p)                     # C: ned's own engine
    if ch.len > 0:
      showHoverAuto(hoverPrefix & ch, auto)
      return
  if b.lang.mode != lmNim and webFamily(b.lang.id).len > 0:
    let wh = webHoverInfo(b, p)                  # CSS, HTML, SQL: ned's own (no language server for it)
    if wh.len > 0:
      showHoverAuto(hoverPrefix & wh, auto)
      return
  let s = lspReady(b)
  let cInfo = if onSymbol and b.lang.mode == lmNim: cHoverInfo(b, p) else: ""
  if onSymbol and nimEngineOn(b):
    let h = engineHover(b, p)
    if h.len > 0: showHoverAuto(hoverPrefix & h & cInfo, auto)
    elif cInfo.len > 0: showHoverAuto(hoverPrefix & cInfo.strip(trailing = false), auto)
    elif nsUsable(b):
      discard nsRequest(b, (if auto: nsAutoHover else: nsHover), p)
      if lines.len > 0: showHoverAuto(hoverPrefix, auto)
    elif nimDocFor(w).len > 0: showHoverAuto(hoverPrefix & nimDocFor(w), auto)
    elif compilerAnswer(b, (if auto: nsAutoHover else: nsHover), p):          # (nimsuggest off: the compiler, once)
      if lines.len > 0: showHoverAuto(hoverPrefix, auto)
    elif lines.len > 0: showHoverAuto(lines.join("\n"), auto)
    elif not auto: info("Nothing known about " & w)
  elif onSymbol and cInfo.len > 0 and (s == nil or s.caps == nil or s.caps{"hoverProvider"} == nil) and
       not nsUsable(b):
    showHoverAuto(hoverPrefix & cInfo.strip, auto)
  elif onSymbol and s != nil and s.caps != nil and s.caps{"hoverProvider"} != nil:
    if cInfo.len > 0: hoverPrefix = hoverPrefix & cInfo.strip & "\n\n"
    discard s.lspRequest("textDocument/hover", %*{"textDocument": b.docId,
      "position": s.lspPos(b, p)}, LspReq(kind: lrHover, bufId: b.id, pos: p, extra: (if auto: "auto" else: "")))
    if lines.len > 0: showHoverAuto(hoverPrefix, auto)
  elif onSymbol and s == nil and nsUsable(b):
    if cInfo.len > 0: hoverPrefix = hoverPrefix & cInfo.strip & "\n\n"
    discard nsRequest(b, (if auto: nsAutoHover else: nsHover), p)
    if lines.len > 0 or cInfo.len > 0: showHoverAuto(hoverPrefix, auto)
  elif lines.len > 0: showHoverAuto(lines.join("\n"), auto)
  elif onSymbol and b.lang.mode == lmNim and nimDocFor(w).len > 0: showHoverAuto(nimDocFor(w), auto)
  elif not auto:
    info("Nothing to show here" & (if lspFor(b, false) == nil and not nsUsable(b): " (no language server)" else: ""))

proc cmdRename() =
  let b = buf()
  let s = lspReady(b)
  let w = b.wordAt(b.primary.head)
  if w.len == 0:
    let op = if nimEngineOn(b): opAtCursor(b) else: ""
    if op.len > 0: info("An operator keeps its name — Alt+Q lists where " & op & " is used")
    else: info("No symbol under cursor")
    return
  if s != nil and s.caps != nil and s.caps{"renameProvider"} != nil:
    openPrompt(pLspRename, "Rename '" & w & "' to", w)
  elif nimEngineOn(b) or (s == nil and nsUsable(b)) or cEngineOn(b):
    openPrompt(pLspRename, "Rename '" & w & "' to", w)
  else:
    b.cursors = @[cur(b.primary.head)]
    b.prim = 0
    b.selectNextOccurrence()
    b.selectAllOccurrences()
    info("Editing all occurrences of '" & w & "' — just type")

var
  searchJob: Job
  searchQuery = ""
  searchCaseS = false
  searchCount = 0
  searchFiles = 0
  searchLastPath = ""
  searchSkip: HashSet[string]
  searchBuiltin = false
  searchIdx = 0
  searchDone = true
