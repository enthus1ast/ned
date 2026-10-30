# ════════════════════════════════════════════════════════════════════════════
#  nedls — the other languages ned's own engines know, as the editor has them: C and C++ (completion, hover,
#  signature help, definition through the #includes, references, rename, symbols, parameter names, the compiler's
#  errors as you type and its fixes), JavaScript (completion, hover, definition and references across the modules
#  that import a name, rename, symbols, its checks), HTML, CSS, SQL and JSON (completion, hover, checks, symbols —
#  JSON's from a schema: package.json, tsconfig.json, ned's settings …), and formatting for every language ned
#  formats. A document in another language gets these answers (or none), never the Nim engine's.
# ════════════════════════════════════════════════════════════════════════════

type LxLang = enum lxNim, lxC, lxWeb, lxOther

var lxCheckedAt: Table[int, int]        # buffer id → the change ned's own checks last looked at

proc lxLangOf(d: LsDoc): LxLang =
  ## which of ned's engines answers for the document: Nim, C and C++, the web languages (JavaScript, HTML, CSS, SQL,
  ## JSON …) or none of them
  if d == nil or d.b.lang == nil or d.b.lang.mode == lmNim: return lxNim
  let id = d.b.lang.id
  if id in ["c", "cpp"]: lxC
  elif webFamily(id).len > 0: lxWeb
  else: lxOther

proc lxFmtKind(b: Buffer): string =
  ## which of ned's formatters fits the document ("" none)
  result = fmtKindOf(b.path)
  if result.len == 0 and b.lang != nil:
    case b.lang.id
    of "cpp", "c": result = "c"
    of "json": result = "json"
    of "markdown": result = "markdown"
    of "css": result = "css"
    of "scss", "less": result = "scss"
    of "yaml": result = "yaml"
    of "toml": result = "toml"
    of "html": result = "html"
    of "sql": result = "sql"
    else: discard

# ── completion ──

proc lxIncludeEdit(b: Buffer, incl: string): JsonNode =
  ## the edit that adds a C `#include` where ned's editor adds it (after the file's last one)
  result = newJArray()
  let at = cxIncludeLine(b.lines)
  if at < b.lines.len: result.add %*{"range": lsRangeIn(b.lines, at, 0, at, 0), "newText": incl & lsEol(b)}
  else:
    let l = b.lines.high
    result.add %*{"range": lsRangeIn(b.lines, l, b.lines[l].len, l, b.lines[l].len), "newText": lsEol(b) & incl}

proc lxCompItems(d: LsDoc, p: Pos): JsonNode =
  ## what ned's completion list holds now (compItems, as compShown orders it), as LSP's items
  let b = d.b
  var items = newJArray()
  let n = min(compShown.len, lsCompLimit)
  let line = b.lines[p.line]
  for k in 0 ..< n:
    let it = compItems[compShown[k]]
    let start = min(compStartCol, p.col)
    let snip = it.snippet.len > 0 and lsSnippets
    # (C: a call with its parameters to fill in, for a client that fills in snippets — the name for the others)
    let text = if snip: it.snippet elif it.snippet.len > 0 and lxLangOf(d) != lxC: stripSnippet(it.snippet)
               else: compInsert(it)
    var j = %*{"label": it.label, "kind": max(1, it.kind), "sortText": align($k, 5, '0'),
               "filterText": line[start ..< min(compStartCol, line.len)] & compFilter(it),
               "textEdit": {"range": lsRangeIn(b.lines, p.line, start, p.line, p.col), "newText": text}}
    if snip: j["insertTextFormat"] = %2
    if it.detail.len > 0: j["detail"] = %it.detail
    if it.doc.len > 0: j["documentation"] = lsMd(it.doc)
    if it.addImport.startsWith("#include "): j["additionalTextEdits"] = lxIncludeEdit(b, it.addImport)
    items.add j
  %*{"isIncomplete": compShown.len > n, "items": items}

proc lxCompletion(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/completion for C, C++ and the web languages, from ned's own completion; for C only the triggers that
  ## make sense (`->`, `::`, the quote or bracket of an #include); no items for any other language
  result = %*{"isIncomplete": false, "items": []}
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  let ctx = params{"context"}
  let invoked = ctx == nil or ctx{"triggerKind"}.getInt(1) == 1
  let trig = ctx{"triggerCharacter"}.getStr
  let before = b.lines[p.line][0 ..< min(p.col, b.lines[p.line].len)]
  compItems.setLen(0)
  compShown.setLen(0)
  case lxLangOf(d)
  of lxC:
    # (`->`, `::`, an #include's "…" or <…>: not every > or :)
    if trig == ">" and not before.endsWith("->"): return
    if trig == ":" and not before.endsWith("::"): return
    if trig in ["\"", "<", "/"] and not before.strip.startsWith("#"): return
    if not cEngComplete(b, p, invoked): return
  of lxWeb:
    if not webComplete(b, p, invoked): return
  else: return
  result = lxCompItems(d, p)

# ── hover, signature help ──

proc lxHover(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/hover for C, C++ and the web languages, and for pnak lockfiles and NIF files; null when there is
  ## nothing to say
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  let md = case lxLangOf(d)
           of lxC: cEngHover(b, p)
           of lxWeb: webHoverInfo(b, p)
           else:
             if pnakFile(b.path): pnakHover(b, p)                     # (pnak's lockfile: the package)
             elif b.lang.id == "nif": nifHover(b, p)                  # (NIF: the tag, the source place)
             else: ""
  if md.strip.len == 0: return newJNull()
  result = %*{"contents": lsMd(md)}
  let (wa, we) = b.wordRangeAt(p)
  if wa.col < we.col: result["range"] = %*{"start": lsPos(b, wa), "end": lsPos(b, we)}

func lxParamSpans(lbl: string): seq[(int, int)] =
  ## the parameters of a signature's label: `int f(int a, char *b)` → the spans of `int a` and `char *b`
  let a = lbl.find('(')
  let e = lbl.rfind(')')
  if a < 0 or e <= a + 1: return
  var depth = 0
  var s = a + 1
  for i in a + 1 .. e:
    let c = lbl[i]
    if c in {'(', '[', '<', '{'}: inc depth
    elif c in {')', ']', '>', '}'} and i < e: dec depth
    if (c == ',' and depth == 0) or i == e:
      var x = s
      var y = i
      while x < y and lbl[x] == ' ': inc x
      while y > x and lbl[y - 1] == ' ': dec y
      if y > x: result.add (x, y)
      s = i + 1

proc lxSignatureHelp(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/signatureHelp for C and C++ (ned's C engine): the one signature, with its parameters' spans and the
  ## one being typed active; null elsewhere
  if lxLangOf(d) != lxC: return newJNull()
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  if not cEngSignature(b, p): return newJNull()
  sigOpen = false
  var ps = newJArray()
  var active = -1
  for k, (a, e) in lxParamSpans(sigLabel):
    ps.add %*{"label": [lsChar(sigLabel, a), lsChar(sigLabel, e)]}
    if (a, e) == sigHl: active = k
  var sig = %*{"label": sigLabel, "parameters": ps}
  if sigDoc.len > 0: sig["documentation"] = lsMd(sigDoc)
  result = %*{"signatures": [sig], "activeSignature": 0}
  if active >= 0: result["activeParameter"] = %active

# ── definition, references, highlights, rename ──

proc lxDefinitions(d: LsDoc, p: Pos): seq[(string, int, int)] =
  ## where the name at the position is defined, by the engine of the document's language: C and C++ through the
  ## #includes, JavaScript in the file or the module it imports from, a pnak lockfile's package (its .nimble)
  let b = d.b
  case lxLangOf(d)
  of lxC:
    if not cEngineOn(b): return
    let t = cEngDefTarget(b, p)
    if t[0].len > 0: result.add (t[0], t[1], t[2])
  of lxWeb:
    if not webJsAt(b, p): return
    let doc = webDoc(b, "js", near = -1)
    if p.line >= doc.len: return
    let o = jsCrossDefinition(b, doc, p)
    if o[0].len > 0: return @[o]
    let (l, c) = jsDefinition(doc, p.line, p.col)
    if l >= 0: result.add (b.path, l, c)
  else:
    if pnakFile(b.path):
      # (pnak's lockfile: the package's .nimble in deps/)
      let i = pnakAt(b, p)
      if i >= 0:
        let (there, _, at) = pnakCheckout(parentDir(b.path), pnakRequires(b.lines)[i].name)
        if there:
          try:
            for kind, f in walkDir(at):
              if kind == pcFile and f.endsWith(".nimble"): return @[(f, 0, 0)]
          except CatchableError: discard

proc lxDefinition(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/definition (and declaration) for the other languages: lxDefinitions as locations
  result = newJArray()
  let p = lsToPos(d.b, params{"position"})
  lsFocus(d, p)
  for (path, l, c) in lxDefinitions(d, p): result.add lsLocation(path, l, c)

proc lxImplementation(d: LsDoc, params: JsonNode): JsonNode =
  ## C++: a method's overrides in the classes derived from its class, a class's derived classes — else (C, and
  ## anything else) its definition
  result = newJArray()
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  if lxLangOf(d) == lxC and cEngineOn(b) and cxIsCppBuf(b):
    lsEnsureFiles()
    let f = cxFileOf(b)
    let ts = cxTargets(f, p.line, p.col)
    if ts.len > 0 and ts[0][1].kind == cxMethod:
      for (g, x) in cxxOverrides(cEngCppFiles(), f, p.line, p.col)[1]: result.add lsLocation(g.path, x.line, x.col)
      if result.len > 0: return
    elif ts.len > 0 and ts[0][1].kind in {cxClass, cxStruct, cxUnion}:
      let (g, cls) = cxxClassAt(f, p.line, p.col)
      if g != nil:
        for (h, x, _) in cxxDerived(cEngCppFiles(), cls): result.add lsLocation(h.path, x.line, x.col)
      if result.len > 0: return
  result = lxDefinition(d, params)

proc lxCxxItem(g: CxFile, s: CxSym): JsonNode =
  ## a TypeHierarchyItem for a C++ class: its whole body, its name
  let path = g.path
  let ls = lsLinesOf(path)
  let el = clamp(max(s.endLine, s.line), 0, max(0, ls.high))
  %*{"name": s.name, "kind": 5, "detail": s.text, "uri": lsUriOf(path),
     "range": lsRangeIn(ls, s.line, 0, el, (if el < ls.len: ls[el].len else: 0)),
     "selectionRange": lsRangeIn(ls, s.line, s.col, s.line, s.col + s.name.len),
     "data": {"cxx": true, "path": path, "line": s.line, "col": s.col}}

proc lxPrepareTypeHierarchy(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/prepareTypeHierarchy for C++: the class at the position as the root item; null otherwise
  result = newJNull()
  let b = d.b
  if lxLangOf(d) != lxC or not cEngineOn(b) or not cxIsCppBuf(b): return
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  let (g, cls) = cxxClassAt(cxFileOf(b), p.line, p.col)
  if g != nil: result = %*[lxCxxItem(g, cls)]

proc lxTypeHierarchyMore(meth: string, params: JsonNode): JsonNode =
  ## a C++ class's bases (supertypes) or the classes derived from it (subtypes)
  result = newJArray()
  let dt = params{"item"}{"data"}
  let path = dt{"path"}.getStr
  let l = dt{"line"}.getInt(-1)
  let c = dt{"col"}.getInt(-1)
  let dd = lsDocByPath(path)
  let f = if dd != nil: cxFileOf(dd.b) else: cxLoad(path, cpp = true)
  if f == nil: return
  var cls: CxSym
  var found = false
  for s in f.syms:
    if s.kind in {cxClass, cxStruct, cxUnion} and s.line == l and s.col == c:
      (cls, found) = (s, true)
  if not found:
    # (the file changed since: the class of that name nearest to where it was)
    var best = high(int)
    for s in f.syms:
      if s.kind in {cxClass, cxStruct, cxUnion} and s.isDef and s.name == params{"item"}{"name"}.getStr and
         abs(s.line - l) < best:
        (cls, found, best) = (s, true, abs(s.line - l))
  if not found: return
  if meth == "typeHierarchy/supertypes":
    for (g, x) in cxxBasesOf(f, cls): result.add lxCxxItem(g, x)
  else:
    lsEnsureFiles()
    for (g, x, depth) in cxxDerived(cEngCppFiles(), cls):
      if depth == 1: result.add lxCxxItem(g, x)

proc lxTypeDefinition(d: LsDoc, params: JsonNode): JsonNode =
  ## C: the declaration of the type of what the name names (a struct's body through its typedef)
  result = newJArray()
  if lxLangOf(d) != lxC or not cEngineOn(d.b): return
  let p = lsToPos(d.b, params{"position"})
  lsFocus(d, p)
  let t = cEngTypeTarget(d.b, p)
  if t[0].len > 0: result.add lsLocation(t[0], t[1], t[2])

proc lxRefHits(d: LsDoc, p: Pos, rename = false): seq[(string, int, int)] =
  ## where the name at p is used, as ned's Find references lists it
  let b = d.b
  case lxLangOf(d)
  of lxC:
    if cEngineOn(b): result = cEngReferenceHits(b, p)[0]
  of lxWeb:
    if webJsAt(b, p): result = jsProjectRefs(b, p, rename)
  else: discard

proc lxReferences(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/references for C, C++ and JavaScript, as ned's Find references lists them; the declaration left out
  ## when the client does not want it
  result = newJArray()
  let p = lsToPos(d.b, params{"position"})
  lsFocus(d, p)
  lsEnsureFiles()
  let withDecl = params{"context"}{"includeDeclaration"}.getBool(true)
  var decls: HashSet[(string, int, int)]
  if not withDecl:
    for x in lxDefinitions(d, p): decls.incl x
  var seen: HashSet[(string, int, int)]
  for h in lxRefHits(d, p):
    if h in seen or h in decls: continue
    seen.incl h
    result.add lsLocation(h[0], h[1], h[2])

proc lxHighlights(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/documentHighlight for C, C++ and JavaScript: the uses of what the name at the position names, in this
  ## file
  result = newJArray()
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  case lxLangOf(d)
  of lxC:
    # (the uses of what the name names, as the engine tells: not a field of another struct of that name)
    for (ra, re) in cEngHighlights(b, p):
      result.add %*{"range": lsRangeIn(b.lines, ra.line, ra.col, re.line, re.col), "kind": 1}
  of lxWeb:
    if not webJsAt(b, p): return
    let doc = webDoc(b, "js", near = -1)
    if p.line >= doc.len: return
    for (l, c, e) in jsReferences(doc, p.line, p.col):
      result.add %*{"range": lsRangeIn(b.lines, l, c, l, e), "kind": 1}
  else: discard

proc lxPrepareRename(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/prepareRename: the name's range and placeholder, or an error when there is no name or ned finds no
  ## declaration of it
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  let (a, e) = b.wordRangeAt(p)
  if a.col >= e.col: lsRaise(ErrRequestFailed, "no name here")
  let w = b.lines[p.line][a.col ..< e.col]
  if lxRefHits(d, p, rename = true).len == 0:
    lsRaise(ErrRequestFailed, "'" & w & "' is not declared where ned can find it — nothing to rename")
  %*{"range": lsRangeIn(b.lines, a.line, a.col, e.line, e.col), "placeholder": w}

proc lxRename(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/rename for C, C++ and JavaScript: checks the new name (a name, not a keyword) and that the declaration
  ## is in the project, then gives a text edit for every place found, grouped by file
  let b = d.b
  let p = lsToPos(b, params{"position"})
  lsFocus(d, p)
  lsEnsureFiles()
  let nn = params{"newName"}.getStr.strip
  let old = b.wordAt(p)
  if old.len == 0: lsRaise(ErrRequestFailed, "no name here")
  let js = lxLangOf(d) == lxWeb
  if nn.len == 0 or not (nn[0] in IdentStartChars or (js and nn[0] == '$')) or
     not nn.allCharsInSet(if js: IdentChars + {'$'} else: IdentChars):
    lsRaise(ErrRequestFailed, "'" & nn & "' is not a name")
  if lxLangOf(d) == lxC:
    if nn in CxKeywords or (cxIsCppBuf(b) and nn in CxxKeywords): lsRaise(ErrRequestFailed, "'" & nn & "' is a keyword")
    let ts = cxTargets(cxFileOf(b), p.line, p.col)
    if ts.len > 0 and ts[0][1].kind notin {cxLocal, cxParam, cxLabel} and
       not (ts[0][0].path == b.path or (rootDir.len > 0 and ts[0][0].path.startsWith(rootDir & "/"))):
      lsRaise(ErrRequestFailed, "'" & old & "' is declared in " & ts[0][0].path & " — outside this project, so it is not renamed")
  let hits = lxRefHits(d, p, rename = true)
  var byFile: OrderedTable[string, seq[(int, int)]]
  for (path, l, c) in hits: byFile.mgetOrPut(path, @[]).add (l, c)
  var changes = newJObject()
  for path, at in byFile:
    let ls = lsLinesOf(path)
    var es = newJArray()
    var done: HashSet[(int, int)]
    for (l, c) in at:
      if l >= ls.len or (l, c) in done or not ls[l].continuesWith(old, c): continue
      done.incl (l, c)
      es.add %*{"range": lsRangeIn(ls, l, c, l, c + old.len), "newText": nn}
    if es.len > 0: changes[lsUriOf(path)] = es
  %*{"changes": changes}

# ── symbols ──

func lxSymKind(it: SideItem, lang: string): int =
  ## the LSP symbol kind for an outline item, from its icon and depth: a function (a method when nested), a class or
  ## struct, a Markdown heading or macro, an object, an array, a property, a field or a variable
  case it.icon
  of "ƒ": (if it.depth > 0: 6 else: 12)            # a method, a function
  of "T": (if lang in ["c", "cpp"] and not it.detail.startsWith("class"): 23 else: 5)
  of "#": (if lang == "markdown": 15 else: 14)       # a heading, a macro
  of "{": 19
  of "[": 18
  of "·": 7
  else: (if it.depth > 0: 8 else: 13)                # a field, a variable

proc lxOutline(d: LsDoc): seq[SideItem] =
  ## the document's outline from the engine for its language: C's, JSON's, JavaScript's, a pnak lockfile's or NIF's,
  ## else a guess from the text's shape
  let b = d.b
  case lxLangOf(d)
  of lxC: cEngOutline(b)
  of lxWeb:
    if b.lang.id == "json": jsonOutlineOf(b)
    elif b.lang.id == "javascript" and b.lines.len < 40_000: jsOutlineOf(b)
    else: heuristicOutline(b)
  else:
    if pnakFile(b.path): pnakOutlineOf(b)
    elif b.lang.id == "nif": nifOutlineOf(b)
    else: heuristicOutline(b)

proc lxDocumentSymbol(d: LsDoc): JsonNode =
  ## textDocument/documentSymbol for the other languages: the outline as symbols, each with a range up to the line
  ## before the next item at its depth or above, nested by depth (a flat list when the client takes no nesting)
  result = newJArray()
  let b = d.b
  if b.lines.len == 0: return
  let items = lxOutline(d)
  let lang = if b.lang != nil: b.lang.id else: ""
  # each item's range: to the line before the next item at its depth or above (the end of the file)
  var ends = newSeq[int](items.len)
  for i, it in items:
    var e = b.lines.high
    for j in i + 1 ..< items.len:
      if items[j].depth <= it.depth:
        e = max(it.line, items[j].line - 1)
        break
    ends[i] = e
  proc symJson(i: int): JsonNode =
    ## outline item i as a DocumentSymbol: its name and kind, its range and the range of its name (an identifier, or a
    ## quoted JSON key)
    let it = items[i]
    let l = clamp(it.line, 0, b.lines.high)
    let s = b.lines[l]
    let c = clamp(it.col, 0, s.len)
    var e = c
    while e < s.len and (s[e] in IdentChars or s[e] in {'$', '-'}): inc e
    if e == c and c < s.len and s[c] == '"':
      e = s.find('"', c + 1) + 1
      if e <= c: e = s.len
    let last = clamp(ends[i], l, b.lines.high)
    result = %*{"name": (if it.text.len > 0: it.text else: "?"), "kind": lxSymKind(it, lang),
                "range": lsRangeIn(b.lines, l, 0, last, b.lines[last].len),
                "selectionRange": lsRangeIn(b.lines, l, c, l, max(e, c))}
    if it.detail.len > 0: result["detail"] = %it.detail
  if not lsHierSymbols:
    for i in 0 ..< items.len:
      let j = symJson(i)
      result.add %*{"name": j["name"], "kind": j["kind"], "location": {"uri": d.uri, "range": j["range"]}}
    return
  var stack: seq[(int, JsonNode)]                  # (depth, symbol) of the items open above
  for i in 0 ..< items.len:
    let j = symJson(i)
    let dep = items[i].depth
    while stack.len > 0 and stack[^1][0] >= dep: discard stack.pop()
    if stack.len == 0: result.add j
    else:
      let parent = stack[^1][1]
      if parent{"children"} == nil: parent["children"] = newJArray()
      parent["children"].add j
    stack.add (dep, j)

const LxWsExts = [".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".hxx", ".js", ".mjs", ".cjs", ".json"]

proc lxWsWanted(path: string): bool =
  ## a project file whose names workspace symbols list: C, C++, JavaScript and JSON — not a lock file's
  var want = false
  for e in LxWsExts:
    if path.endsWith(e): want = true
  let name = extractFilename(path)
  want and not (name.endsWith("-lock.json") or name.endsWith(".lock.json") or name == "package-lock.json")

proc lxWsSymbols(path: string): seq[tuple[name: string, kind, line, col: int, container: string]] =
  ## workspace symbols of a C, C++, JavaScript or JSON file (an open one as it is now): the names its outline has —
  ## a JSON file's keys two levels deep. Positions are ned's (bytes)
  var d = lsDocByPath(path)
  let ext = path.splitFile.ext.toLowerAscii
  if d == nil and ext in [".c", ".h", ".cc", ".cpp", ".cxx", ".hpp", ".hh", ".hxx"]:
    # (a C file not open: its index from disk, as the C engine keeps it — no buffer of its own)
    if not (cfgCEngine in ["builtin", "both"] or (cfgCEngine == "auto" and not haveExe("clangd"))): return
    var items: seq[SideItem]
    try: items = cEngOutlineOf(cxLoad(path), path)
    except Exception: return
    let lang = if cxIsCppPath(path): "cpp" else: "c"
    var owner = ""
    for it in items:
      if it.depth == 0: owner = it.text
      if it.text.len == 0: continue
      result.add (it.text, lxSymKind(it, lang), max(0, it.line), max(0, it.col),
                  (if it.depth > 0: owner else: ""))
    return
  if d == nil:
    let lines = lsLinesOf(path)
    if lines.len == 0 or lines.len > 20_000: return
    let b = newBuffer()
    b.path = path
    b.lines = lines
    b.lang = detectLang(path, lines[0])
    if b.lang == nil: return
    d = LsDoc(uri: lsUriOf(path), b: b)
  let lang = if d.b.lang != nil: d.b.lang.id else: ""
  if lxLangOf(d) notin {lxC, lxWeb} or lang notin ["c", "cpp", "javascript", "json"]: return
  var items: seq[SideItem]
  try: items = lxOutline(d)
  except Exception: return
  var parents: seq[string]               # (the item each depth is in)
  for it in items:
    if parents.len > it.depth: parents.setLen(it.depth)
    while parents.len < it.depth: parents.add ""
    let container = if it.depth > 0 and parents.len > 0: parents[^1] else: ""
    parents.add it.text
    if it.text.len == 0 or (lang == "json" and it.depth > 1): continue
    result.add (it.text, lxSymKind(it, lang), clamp(it.line, 0, max(0, d.b.lines.high)), max(0, it.col), container)

# ── linked editing: an HTML tag's name and its partner's ──

proc lxLinkedEditing(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/linkedEditingRange: on an HTML tag's name, it and its closing (opening) tag's name — renamed
  ## together as you type, as ned's editor.linkedEditing does
  result = newJNull()
  let b = d.b
  if b.lang == nil or b.lang.id notin ["html", "xml", "svg", "vue", "svelte", "php"]: return
  let p = lsToPos(b, params{"position"})
  if p.line < 0 or p.line >= b.lines.len: return
  let (a, e, cl) = htmlTagNameAt(b.lines[p.line], p.col)
  if a < 0 or e <= a: return
  let (pl, pa, pe) = b.htmlPartner(p.line, a, e, cl)
  if pl < 0: return
  result = %*{"ranges": [lsRangeIn(b.lines, p.line, a, p.line, e), lsRangeIn(b.lines, pl, pa, pl, pe)],
              "wordPattern": "[A-Za-z0-9_:.-]+"}

# ── parameter names, quick fixes, links ──

proc lxInlayHints(d: LsDoc, params: JsonNode): JsonNode =
  ## textDocument/inlayHint for C and C++: the parameter names ned's C engine shows before arguments on the range's
  ## lines, as LSP parameter hints
  result = newJArray()
  let b = d.b
  if lxLangOf(d) != lxC or not cEngineOn(b) or not cfgInlayHints: return
  let r = params{"range"}
  let lo = clamp(lsToPos(b, r{"start"}).line, 0, b.lines.high)
  let hi = clamp(lsToPos(b, r{"end"}).line, lo, b.lines.high)
  lsFocus(d, b.primary.head)
  cEngInlays(b, lo, hi)
  var ls: seq[int]
  for l in b.inlays.keys: ls.add l
  ls.sort()
  for l in ls:
    if l < lo or l > hi or l > b.lines.high: continue
    for (c, label) in b.inlays[l]:
      result.add %*{"position": lsPosIn(b.lines, l, min(c, b.lines[l].len)), "label": label.strip(leading = false),
                    "kind": 2, "paddingRight": true}

proc lxCodeActions(d: LsDoc, params: JsonNode): JsonNode =
  ## the compiler's own fixes (C, C++) and ned's engine's, for the problems in the range
  result = newJArray()
  let b = d.b
  let r = params{"range"}
  let a = lsToPos(b, r{"start"})
  let e = lsToPos(b, r{"end"})
  for dg in diagsFor(b.path):
    if dg.fixes == nil or dg.line > e.line or max(dg.line, dg.eline) < a.line: continue
    for f in jitems(dg.fixes):
      if f{"at"}.getInt(-1) != b.changeId: continue
      var es = newJArray()
      for x in jitems(f{"nedEdits"}):
        let s0 = x{"range"}{"start"}
        let s1 = x{"range"}{"stop"}
        es.add %*{"range": lsRangeIn(b.lines, s0{"line"}.getInt, s0{"col"}.getInt, s1{"line"}.getInt, s1{"col"}.getInt),
                  "newText": x{"text"}.getStr}
      if es.len == 0: continue
      let (sc, el, ec) = lsDiagRange(b.lines, dg)
      result.add %*{"title": f{"title"}.getStr, "kind": "quickfix", "isPreferred": result.len == 0,
                    "diagnostics": [{"range": lsRangeIn(b.lines, dg.line, max(0, sc), el, max(0, ec)),
                                     "severity": clamp(dg.sev, 1, 4), "message": dg.msg}],
                    "edit": {"changes": {d.uri: es}}}
  if lxLangOf(d) != lxC or not cEngineOn(b) or a.line >= b.lines.len: return
  # ned's engine at the start of the range: the #include an unknown name needs, a switch's missing cases, the
  # selection in a variable (the name ned gives it), an if/else inverted
  let f = cxFileOf(b)
  var refs: seq[(string, string, CkFix)]
  let t = b.lines[a.line]
  let (wa, we) = cxWordAt(t, a.col)
  if wa < we and t[wa] notin Digits and not cxIsMember(t, wa) and t[wa ..< we] notin CxKeywords and
     b.tokenAt(Pos(line: a.line, col: wa)) notin {tkComment, tkDoc, tkString, tkChar} and
     cxTargets(f, a.line, a.col).len == 0:
    let h = cEngHeaderFor(b, t[wa ..< we])
    var have = false
    for x in result: have = have or x{"title"}.getStr == "#include " & h
    if h.len > 0 and not have:
      result.add %*{"title": "#include " & h, "kind": "quickfix",
                    "edit": {"changes": {d.uri: lxIncludeEdit(b, "#include " & h)}}}
  for fx in ckFillSwitch(f, a.line, a.col): refs.add (fx.title, "quickfix", fx)
  if a != e and a.line == e.line:
    for fx in ckExtractVar(f, a.line, a.col, e.col): refs.add (fx.title, "refactor.extract", fx)
  for fx in ckInvertIf(b.lines, a.line): refs.add (fx.title, "refactor.rewrite", fx)
  for (title, kind, fx) in refs:
    var es = newJArray()
    for x in fx.edits: es.add %*{"range": lsRangeIn(b.lines, x.line, x.col, x.eline, x.ecol), "newText": x.text}
    result.add %*{"title": title, "kind": kind, "edit": {"changes": {d.uri: es}}}

proc lxDocumentLinks(d: LsDoc): JsonNode =
  ## the files a document names: C's #include "…" and <…> (where the engine finds them), JavaScript's imports of a
  ## file, HTML's href and src of a file of the project
  result = newJArray()
  let b = d.b
  if b.path.len == 0: return
  let dir = parentDir(b.path)
  template link(l, a, e: int, target: string) =
    ## adds a document link for columns a..e of line l when the target file exists
    if target.len > 0 and fileExists(target):
      result.add %*{"range": lsRangeIn(b.lines, l, a, l, e), "target": lsUriOf(target)}
  let lang = if b.lang != nil: b.lang.id else: ""
  for l, s in b.lines:
    if l > 20000: break
    if lang in ["c", "cpp"]:
      let t = s.strip
      if t.startsWith("#") and "include" in t:
        let q0 = s.find({'"', '<'})
        if q0 < 0: continue
        let q1 = s.find(if s[q0] == '"': '"' else: '>', q0 + 1)
        if q1 <= q0 + 1: continue
        let name = s[q0 + 1 ..< q1]
        var target = if s[q0] == '"' and fileExists(dir / name): dir / name else: ""
        if target.len == 0:
          cxSetDirsFor(b.path)
          target = cxFindInclude(name, dir)
        link(l, q0 + 1, q1, target)
    elif lang == "javascript":
      for kw in ["from ", "import ", "require("]:
        var k = s.find(kw)
        while k >= 0:
          var q = k + kw.len
          while q < s.len and s[q] == ' ': inc q
          if q < s.len and s[q] in {'"', '\'', '`'}:
            let e = s.find(s[q], q + 1)
            if e > q + 1: link(l, q + 1, e, jsModulePath(b.path, s[q + 1 ..< e]))
          k = s.find(kw, k + 1)
    elif lang in ["html", "css"]:
      for kw in ["href=\"", "src=\"", "href='", "src='", "url("]:
        var k = s.find(kw)
        while k >= 0:
          var q = k + kw.len
          let close = if kw == "url(": ')' else: kw[^1]
          var e = s.find(close, q)
          if kw == "url(" and q < s.len and s[q] in {'"', '\''}:
            inc q
            e = s.find(s[q - 1], q)
          if e > q:
            var t = s[q ..< e].split({'#', '?'})[0]
            if t.len > 0 and "://" notin t and not t.startsWith("data:") and not t.startsWith("mailto:"):
              let target = if t.startsWith("/") and rootDir.len > 0: rootDir / t[1 .. ^1] else: dir / t
              link(l, q, q + t.len, normalizedPath(target))
          k = s.find(kw, k + 1)

# ── formatting ──

proc lxFormatting(d: LsDoc): JsonNode =
  ## ned's formatter for the document's language (C and C++, JSON, Markdown, CSS, SCSS, YAML, TOML, HTML, SQL)
  result = newJArray()
  let b = d.b
  let kind = lxFmtKind(b)
  if kind.len == 0 or kind == "nim" or b.largeOn: return
  applySettingsFor(b.path)
  let (ok, outp) = lsInChild(proc(): string =
    let text = b.allText & "\n"
    let (res, err) = fmtTextOf(kind, text, b.path)
    if err.len > 0 and res == text: "E" & err
    elif res == text: "R[]"
    else: "R" & $lsLineEdits(b.lines, lsTextLines(res), lsEol(b)))
  result = lsFormatAnswer(d, ok, outp, "format")

proc lxRangeFormatting(d: LsDoc, params: JsonNode): JsonNode =
  ## C and C++: what ned's own C formatter changes on the lines of the range (the whole file formatted — a line is
  ## laid out by what is around it —, the rest left as it is)
  result = newJArray()
  let b = d.b
  if lxFmtKind(b) notin ["c", "cpp"] or b.largeOn or b.lines.len == 0: return
  applySettingsFor(b.path)
  let r = params{"range"}
  let a = lsToPos(b, r{"start"})
  let e = lsToPos(b, r{"end"})
  var l1 = e.line
  if e.col == 0 and l1 > a.line: dec l1
  let (ok, outp) = lsInChild(proc(): string =
    let (nl, err) = b.cFormatLines(a.line, l1)
    if err.len > 0: "E" & err
    elif nl == b.lines: "R[]"
    else: "R" & $lsLineEdits(b.lines, nl, lsEol(b)))
  result = lsFormatAnswer(d, ok, outp, "format selection")

# ── problems ──

proc lxPumpChecks(d: LsDoc, active: bool) =
  ## ned's own checks of a document in another language, after a pause in typing: C's (and, for the document typed
  ## into last, the C compiler on the unsaved text), JavaScript's, HTML's, CSS's, SQL's and JSON's
  let b = d.b
  if b.path.len == 0 or msSince(d.changedAt) < 400: return
  if lxCheckedAt.getOrDefault(b.id, -1) == b.changeId: return
  lxCheckedAt[b.id] = b.changeId
  case lxLangOf(d)
  of lxC:
    if not cEngineOn(b): return
    cEngChecks(b)
    if active and cfgLiveCheck and b.path notin cTypingChecks and (b.dirty or b.chkAt == 0): cTypingCheck(b)
  of lxWeb:
    var ds = webDiagsOf(b)
    lintApply(b.path, b.lines, ds)
    if ds.len > 0: diagsWeb[b.path] = ds
    else: diagsWeb.del b.path
  else:
    if not pnakFile(b.path): return
    var ds = pnakDiags(b)
    lintApply(b.path, b.lines, ds)
    if ds.len > 0: diagsWeb[b.path] = ds
    else: diagsWeb.del b.path
  lsDiagsDirty = true

proc lxNextCheckMs(d: LsDoc): int =
  ## ms until lxPumpChecks has something to do for this document
  result = 1000
  if d == nil or d.b.path.len == 0 or (lxLangOf(d) notin {lxC, lxWeb} and not pnakFile(d.b.path)): return
  if lxCheckedAt.getOrDefault(d.b.id, -1) != d.b.changeId:
    result = max(10, 400 - int(msSince(d.changedAt)) + 5)

# ── semantic tokens: C's names by what they are ──

proc lxSemanticTokens(d: LsDoc, lo0, hi0: int): seq[int32] =
  ## C and C++: what the engine knows each name is, as semantic tokens (the legend nedls gives: a function, a macro,
  ## a type, an enum constant, a field, a parameter, a local or a global — static: the file's own —, a namespace;
  ## a declaration's own name marked so); none for the other languages
  let b = d.b
  if lxLangOf(d) != lxC or not cEngineOn(b) or b.lines.len == 0: return
  let lo = clamp(lo0, 0, b.lines.high)
  let hi = clamp(hi0, lo, b.lines.high)
  var toks: seq[CxSemTok]
  var decls: HashSet[(int, int)]
  try:
    let f = cxFileOf(b)
    toks = cxSemTokens(f, lo, hi)
    for x in f.syms: decls.incl (x.line, x.col)
  except CatchableError as e:
    internalError("C engine", e)
    return
  var pl = 0
  var pc = 0
  for (l, c, n, k) in toks:
    var (t, mods) = case k
                    of cxFunc: (6, 0)
                    of cxMacro: (7, 0)
                    of cxTypedef: (1, 0)
                    of cxEnumConst: (2, 0)
                    of cxField: (5, 0)
                    of cxParam: (4, 0)
                    of cxLocal: (3, 0)
                    of cxVar: (3, 4)
                    of cxNamespace: (0, 0)
                    else: (-1, 0)
    if t < 0: continue
    if (l, c) in decls: mods = mods or 1
    let s = b.lines[l]
    let sc = lsChar(s, c)
    let ln = lsChar(s, c + n) - sc
    let dl = l - pl
    let dc = if dl == 0: sc - pc else: sc
    result.add [dl.int32, dc.int32, ln.int32, t.int32, mods.int32]
    pl = l
    pc = sc

proc lxSemData(d: LsDoc, lo, hi: int, data: var seq[int32]): bool =
  ## a document in another language: its tokens (none but C's and C++'s) — true; a Nim one: false
  if d == nil or lxLangOf(d) == lxNim: return false
  data = lxSemanticTokens(d, lo, hi)
  true

# ── the dispatch: a request about a document in another language ──

proc lxHandle(meth: string, params: JsonNode, id: JsonNode): bool =
  ## answer a request about a document that is not Nim (true when answered here)
  if meth in ["typeHierarchy/supertypes", "typeHierarchy/subtypes"] and params{"item"}{"data"}{"cxx"}.getBool:
    lsReply(id, lxTypeHierarchyMore(meth, params))          # (a C++ class's)
    return true
  if not meth.startsWith("textDocument/"): return false
  let d = lsDocOf(params, required = false)
  if d == nil or lxLangOf(d) == lxNim: return false
  case meth
  of "textDocument/completion": lsReply(id, lxCompletion(d, params))
  of "textDocument/hover": lsReply(id, lxHover(d, params))
  of "textDocument/signatureHelp": lsReply(id, lxSignatureHelp(d, params))
  of "textDocument/definition", "textDocument/declaration": lsReply(id, lxDefinition(d, params))
  of "textDocument/implementation": lsReply(id, lxImplementation(d, params))
  of "textDocument/prepareTypeHierarchy": lsReply(id, lxPrepareTypeHierarchy(d, params))
  of "textDocument/references": lsReply(id, lxReferences(d, params))
  of "textDocument/documentHighlight": lsReply(id, lxHighlights(d, params))
  of "textDocument/prepareRename": lsReply(id, lxPrepareRename(d, params))
  of "textDocument/rename": lsReply(id, lxRename(d, params))
  of "textDocument/documentSymbol": lsReply(id, lxDocumentSymbol(d))
  of "textDocument/formatting": lsReply(id, lxFormatting(d))
  of "textDocument/inlayHint": lsReply(id, lxInlayHints(d, params))
  of "textDocument/codeAction": lsReply(id, lxCodeActions(d, params))
  of "textDocument/documentLink": lsReply(id, lxDocumentLinks(d))
  of "textDocument/linkedEditingRange": lsReply(id, lxLinkedEditing(d, params))
  of "textDocument/onTypeFormatting": lsReply(id, newJArray())
  of "textDocument/foldingRange", "textDocument/selectionRange": return false      # (the same for every language)
  of "textDocument/semanticTokens/full", "textDocument/semanticTokens/full/delta",
     "textDocument/semanticTokens/range": return false     # (lsSemData picks the engine; the deltas are the same)
  of "textDocument/typeDefinition": lsReply(id, lxTypeDefinition(d, params))
  of "textDocument/rangeFormatting": lsReply(id, lxRangeFormatting(d, params))
  of "textDocument/prepareCallHierarchy", "textDocument/codeLens":
    lsReply(id, (if meth.startsWith("textDocument/prepare"): newJNull() else: newJArray()))
  else: return false
  true
