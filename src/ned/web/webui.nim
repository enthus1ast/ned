# ── ned's own CSS, HTML, SQL and JavaScript in the editor: in .css / .scss / .less, .html, .sql and .js files and
#    where they are embedded (an HTML <style> or <script>, Nim strings) — completion, hover, go to definition and
#    problems, when no language server does it (web.engine: auto) ──

var
  webDocMemo: Table[(int, string), (int, seq[string])]    # (buffer, language) → (the change it was made for, text)
  webChkAt: Table[int, int]                                # buffer → the change its problems were found for
  webHeld: Table[int, (int, Pos)]                          # buffer → (change, cursor) a problem was held back at
  webLast: Table[int, (int, seq[Diag])]                    # buffer → (change, what its checks found)
  sqlFileMemo: Table[string, (times.Time, SqlSchema)]            # a project file → (its time, the tables it creates)
  sqlSchemaMemo: SqlSchema
  sqlSchemaAt: MonoTime
  sqlSchemaMade = false
  cssFileMemo: Table[string, (times.Time, seq[string], seq[string])]   # a project .css → (its time, classes, ids)

proc webHtmlFile(b: Buffer): bool =
  ## HTML that is HTML (not XML, SVG, a plist or a Vue file, which the same colours serve)
  let ext = splitFile(b.path).ext.toLowerAscii
  b.path.len == 0 or ext in [".html", ".htm", ".xhtml"]

proc webLangAt(b: Buffer, p: Pos): string =
  ## "css", "html", "sql", "js" or "": the language ned's own engines know at p
  if b.lang == nil or p.line < 0 or p.line >= b.lines.len: return ""
  let own = webFamily(b.lang.id)
  if own == "html" and not webHtmlFile(b): return ""
  if b.lang.mode notin {lmNim, lmHtml, lmMarkdown, lmNimf}: return own
  let l = b.langAt(Pos(line: p.line, col: max(0, p.col - 1)))
  let l2 = if l == nil or webFamily(l.id).len == 0: b.langAt(p) else: l
  if l2 != nil: return webFamily(l2.id)
  own

proc webDoc(b: Buffer, fam: string, near = -1): seq[string] =
  ## the text of that language in the buffer, at its own lines and columns (the rest blank): the file itself
  ## when it is in that language; else what its lexer coloured as that language (a <style>, Nim strings — their
  ## {expressions} as a 0, SQL strings each ended by a `;`). near: only the lines around that one (completion and
  ## hover in a big Nim file: a key costs the few hundred lines around it, not the file)
  if webFamily(b.lang.id) == fam: return b.lines
  let key = (b.id, fam)
  if key in webDocMemo and webDocMemo[key][0] == b.changeId: return webDocMemo[key][1]
  var res = newSeq[string](b.lines.len)
  let lo = if near >= 0 and b.lines.len > 1500: max(0, near - 600) else: 0
  let hi = if near >= 0 and b.lines.len > 1500: min(b.lines.high, near + 60) else: b.lines.high
  if b.lines.len <= 30000:
    b.ensureHl(hi + 1)
    var toks: seq[TokKind]
    for l in lo .. hi:
      let s = b.lines[l]
      if s.len > 4000: continue
      let st = if l < b.hlStart.len: b.hlStart[l] else: 0
      if b.lang.mode == lmNim and '"' notin s and stTop(st) == 0: continue
      discard lexLine(b.lang, s, st, toks)
      var holes: seq[(int, int)]
      for (a, e, d, lg) in lexLangs:
        if lg != nil and lg.id == "nim" and d >= 1: holes.add (a, e)
      for (a, e, d, lg) in lexLangs:
        if lg == nil or webFamily(lg.id) != fam or e <= a: continue
        var line = res[l]
        if line.len < e: line.add spaces(e - line.len)
        for k in a ..< e: line[k] = s[k]
        for (h0, h1) in holes:
          if h0 >= a and h1 <= e:
            var x0 = h0
            if x0 - 1 >= a and s[x0 - 1] == '{': dec x0
            var x1 = h1
            let cl = s.find('}', h1)
            if cl >= 0 and cl < e: x1 = cl + 1
            for q in x0 ..< x1: line[q] = ' '
            line[x0] = '0'
        if fam == "sql" and e < s.len and b.lang.mode == lmNim:
          if line.len < e + 1: line.add ' '
          line[e] = ';'
        res[l] = line
  if lo == 0 and hi == b.lines.high:
    if webDocMemo.len > 24: webDocMemo.clear()       # (closed buffers' too: a few at a time is all it needs)
    webDocMemo[key] = (b.changeId, res)
  res

var wkWebServed: seq[string]       # (the engine worker: the languages the editor has a server for — it asks)

proc webServerFor(b: Buffer, fam: string): bool =
  ## does a language server answer for this language here (the file's own, or the one embedded strings use)?
  if wkWorkerMode: return fam in wkWebServed
  if webFamily(b.lang.id) == fam:
    let s = lspReady(b)
    return s != nil and s.caps != nil
  embServerAvailable(langByName(case fam
                                of "css": "CSS"
                                of "html": "HTML"
                                of "js": "JavaScript"
                                else: "SQL"))

proc webEngineOn(b: Buffer, p: Pos): bool =
  ## ned's own engine answers at p (web.engine: auto — when no language server does)
  if cfgWebEngine == "off" or b.largeOn: return false
  let fam = webLangAt(b, p)
  if fam.len == 0: return false
  cfgWebEngine == "on" or not webServerFor(b, fam)

# ── what other files tell: the tables a project creates, the class names its stylesheets have ──

proc sqlSchema(b: Buffer): SqlSchema =
  ## every table the project creates: its .sql files, the SQL of its Nim files that create tables, the open buffers
  if sqlSchemaMade and msSince(sqlSchemaAt) < 4000:
    result = sqlSchemaMemo
  else:
    var sc: SqlSchema
    var n = 0
    for rel in projectFiles():
      let lr = rel.toLowerAscii
      if not (lr.endsWith(".sql") or lr.endsWith(".nim")): continue
      let p = if rel.isAbsolute: rel else: rootDir / rel
      inc n
      if n > 3000: break
      var t: times.Time
      try: t = getLastModificationTime(p)
      except CatchableError: continue
      var got: SqlSchema
      if p in sqlFileMemo and sqlFileMemo[p][0] == t: got = sqlFileMemo[p][1]
      else:
        try:
          if getFileSize(p) < 2_000_000:
            let text = readFile(p)
            if lr.endsWith(".sql") or "create table" in text.toLowerAscii:
              let ls = text.splitLines
              if lr.endsWith(".sql"): got.addCreates(ls, p)
              else:
                # (the SQL in a Nim file: its strings that create tables)
                var sqlLines = newSeq[string](ls.len)
                for (l, c, body) in tripleStrings(ls):
                  for k, x in body:
                    let col = if k == 0: c else: 0
                    if l + k < sqlLines.len: sqlLines[l + k] = spaces(col) & x
                for i, x in ls:
                  let q = x.toLowerAscii.find("create table")
                  if q >= 0 and sqlLines[i].len == 0:
                    let e = x.rfind('"')
                    if e > q: sqlLines[i] = spaces(q) & x[q ..< e] & ";"
                got.addCreates(sqlLines, p)
        except CatchableError: discard
        sqlFileMemo[p] = (t, got)
      for k, v in got.tables:
        if k notin sc.tables: sc.tables[k] = v
    sqlSchemaMemo = sc
    sqlSchemaAt = getMonoTime()
    sqlSchemaMade = true
    result = sc
  # the open buffers as they are now
  for x in bufs:
    if x.lang == nil or x.lines.len > 30000: continue
    let f = webFamily(x.lang.id)
    if f == "sql" or (x.lang.mode == lmNim and x.dirty):
      var s2: SqlSchema
      s2.addCreates(webDoc(x, "sql"), x.path)
      for k, v in s2.tables: result.tables[k] = v

proc projectCssNames(): (seq[string], seq[string]) =
  ## the class names and ids the project's stylesheets name (and its open buffers' CSS)
  var cs, ids: HashSet[string]
  var n = 0
  for rel in projectFiles():
    if not rel.toLowerAscii.endsWith(".css"): continue
    inc n
    if n > 400: break
    let p = if rel.isAbsolute: rel else: rootDir / rel
    var t: times.Time
    try: t = getLastModificationTime(p)
    except CatchableError: continue
    if p notin cssFileMemo or cssFileMemo[p][0] != t:
      try:
        if getFileSize(p) < 3_000_000:
          let (c, i) = cssClassesAndIds(readFile(p).splitLines)
          cssFileMemo[p] = (t, c, i)
        else: cssFileMemo[p] = (t, @[], @[])
      except CatchableError: continue
    for c in cssFileMemo[p][1]:
      if c notin cs:
        cs.incl c
        result[0].add c
    for c in cssFileMemo[p][2]:
      if c notin ids:
        ids.incl c
        result[1].add c
  for x in bufs:
    if x.lang == nil or x.lines.len > 30000: continue
    if webFamily(x.lang.id) == "css" or x.lang.mode in {lmNim, lmHtml}:
      let (c, i) = cssClassesAndIds(webDoc(x, "css"))
      for y in c:
        if y notin cs:
          cs.incl y
          result[0].add y
      for y in i:
        if y notin ids:
          ids.incl y
          result[1].add y

proc pageClassesAndIds(b: Buffer): (seq[string], seq[string]) =
  ## the class names and ids the HTML of this buffer and the other open HTML has
  var cs, ids: HashSet[string]
  for x in bufs:
    if x.lang == nil or x.lines.len > 30000: continue
    if x != b and webFamily(x.lang.id) != "html": continue
    if x.lang.mode notin {lmNim, lmHtml, lmMarkdown, lmNimf} and webFamily(x.lang.id) != "html": continue
    let (c, i) = htmlClassesAndIds(webDoc(x, "html"))
    for y in c:
      if y notin cs:
        cs.incl y
        result[0].add y
    for y in i:
      if y notin ids:
        ids.incl y
        result[1].add y

# ── completion, hover ──

proc toCompItems(ws: seq[WebItem]): seq[CompItem] =
  for w in ws:
    result.add CompItem(label: w.label, insert: w.insert, snippet: w.snippet, detail: w.detail, kind: w.kind,
                        filter: w.label, sortText: $w.rank & w.label, rank: w.rank, doc: w.doc, docMade: true)

var webCompAt = (-1, -1, -1)      # (buffer, line, column) the list ned's own engine opened is for

proc jsTooBig(b: Buffer): bool =
  ## (a minified bundle: the engine reads the whole text at every question — not that one)
  if b.lines.len > 40_000: return true
  var n = 0
  for l in b.lines:
    n += l.len
    if n > 1_500_000: return true
  false

proc webComplete(b: Buffer, p: Pos, manual: bool): bool =
  ## ned's own completion for the CSS, HTML or SQL at p; false when it has nothing to say there
  if not webEngineOn(b, p): return false
  let fam = webLangAt(b, p)
  # the list open for this word: it narrows as the word is typed
  if not manual and compOpen and compFromLsp and webCompAt == (b.id, p.line, compStartCol) and compLine == p.line and
     p.col > compStartCol and p.col <= b.lines[p.line].len:
    let typed = b.lines[p.line][compStartCol ..< p.col]
    var ok = true
    var word = false                  # (`:`, `::`, `@` only in front of the word: `u.` asks for the columns anew)
    for ch in typed:
      let identCh = if fam == "js": ch in IdentChars or ch == '$' else: isCssIdent(ch) and not (fam == "sql" and ch == '-')
      if identCh: word = true
      elif word or fam in ["sql", "js"] or ch notin {':', '@'}: ok = false
    if ok:
      refilterComp()
      return true
  var start = p.col
  var items: seq[WebItem]
  let doc = webDoc(b, fam, near = p.line)
  if p.line >= doc.len: return false
  case fam
  of "css":
    var cs, ids: seq[string]
    if cssContext(doc, p.line, p.col).kind in {ccClass, ccId}: (cs, ids) = pageClassesAndIds(b)   # (only then)
    let (cx, its) = cssComplete(doc, p.line, p.col, cs, ids)
    if cx.kind == ccNone: return false
    if not manual:
      if cx.word.len == 0 and cx.kind notin {ccValue, ccPseudo, ccAtRule, ccClass, ccId, ccVar}: return false
      # (not after `1.` or `#` in a value: a number, a colour)
      let before = if cx.start > 0 and cx.start <= doc[p.line].len: doc[p.line][cx.start - 1] else: ' '
      if cx.kind == ccValue and cx.word.len == 0 and before notin {':', ' ', '(', ','}: return false
      if cx.kind == ccSelector and cx.word.len > 2: return false     # (the list was there at the first letters)
    start = cx.start
    items = its
  of "html":
    var cs, ids: seq[string]
    let cx0 = htmlContext(doc, p.line, p.col)
    if cx0.kind == hcAttrValue:                     # (the class names and ids: only for an attribute's value)
      (cs, ids) = projectCssNames()
      let (_, pageIds) = htmlClassesAndIds(doc)
      for i in pageIds:
        if i notin ids: ids.add i
    let (cx, its) = htmlComplete(doc, p.line, p.col, cs, ids)
    if cx.kind in {hcNone, hcText}: return false
    if not manual and cx.kind == hcAttrName and cx.word.len == 0 and
       not (p.col > 0 and b.lines[p.line][p.col - 1] == ' '):
      return false
    start = cx.start
    items = its
  of "sql":
    let (a, its) = sqlComplete(doc, p.line, p.col, sqlSchema(b))
    if not manual and p.col - a < 1 and not (a > 0 and doc[p.line].len >= a and doc[p.line][a - 1] == '.'):
      return false
    start = a
    items = its
  of "js":
    if b.jsTooBig(): return false
    let (a, its) = jsComplete(doc, p.line, p.col)
    let afterDot = a > 0 and doc[p.line].len >= a and doc[p.line][a - 1] == '.'
    if not manual and p.col - a < 1 and not afterDot: return false
    start = a
    items = its
  else: return false
  if items.len == 0:
    if manual: info("No completions")
    return manual
  webCompAt = (b.id, p.line, start)
  compLine = p.line
  compStartCol = start
  compManual = manual
  compNx.setLen(0)
  compItems = toCompItems(items)
  compFromLsp = true
  refilterComp()
  true

proc webHoverInfo(b: Buffer, p: Pos): string =
  ## what the CSS property, HTML element or attribute, SQL table, column or function at p is
  if not webEngineOn(b, p): return ""
  let fam = webLangAt(b, p)
  let doc = webDoc(b, fam, near = p.line)
  if p.line >= doc.len: return ""
  try:
    case fam
    of "css": cssHover(doc, p.line, p.col)
    of "html": htmlHover(doc, p.line, p.col)
    of "sql": sqlHover(doc, p.line, p.col, sqlSchema(b))
    of "js": (if b.jsTooBig(): "" else: jsHover(doc, p.line, p.col))
    else: ""
  except CatchableError, Defect: ""

proc webDefinition(b: Buffer, p: Pos): bool =
  ## JavaScript: where the name at p is declared (in the file, or the <script>s of the page)
  if not webEngineOn(b, p) or webLangAt(b, p) != "js" or b.jsTooBig(): return false
  let doc = webDoc(b, "js", near = -1)
  if p.line >= doc.len: return false
  var at = (-1, -1)
  try: at = jsDefinition(doc, p.line, p.col)
  except CatchableError, Defect: return false
  if at[0] < 0: return false
  pushJump()
  b.setSingle(b.clampPos(Pos(line: at[0], col: at[1])))
  b.centerOn(b.primary.head)
  true

# ── problems: after a pause in typing, for the file in front ──

proc webDiagsOf(b: Buffer): seq[Diag] =
  var ws: seq[WebDiag]
  let fam = webFamily(b.lang.id)
  let own = (fam == "html" and webHtmlFile(b)) or fam in ["css", "sql", "js"]
  if own and not (cfgWebEngine == "on" or not webServerFor(b, fam)): return
  case fam
  of "css":
    let strict = splitFile(b.path).ext.toLowerAscii == ".css"
    if strict or b.path.len == 0: ws.add cssChecks(b.lines, strict = true)
  of "html":
    if webHtmlFile(b):
      ws.add htmlChecks(b.lines)
      let css = webDoc(b, "css")
      var any = false
      for l in css:
        if l.len > 0:
          any = true
          break
      if any: ws.add cssChecks(css, strict = true)
      if not b.jsTooBig() and (cfgWebEngine == "on" or not webServerFor(b, "js")):
        # the page's <script>s: each a piece (a name two module scripts declare is no redeclaration)
        let js = webDoc(b, "js")
        var anyJs = false
        for l in js:
          if l.strip.len > 0:
            anyJs = true
            break
        if anyJs: ws.add jsChecks(js, fragment = true)
  of "sql": ws.add sqlChecks(b.lines, sqlSchema(b))
  of "js":
    if not b.jsTooBig(): ws.add jsChecks(b.lines)
  else:
    var any3 = false                     # (HTML, CSS and SQL live in triple-quoted strings and sql"…")
    if b.lang.mode == lmNim and b.lines.len <= 15000:
      for l in b.lines:
        if "\"\"\"" in l or "sql\"" in l or "sql(" in l:
          any3 = true
          break
    if any3:
      # the HTML, CSS, SQL and JavaScript in the Nim strings — pieces of a page, a query, a script: no brace or
      # end-tag counting
      for f in ["html", "css", "sql", "js"]:
        if cfgWebEngine != "on" and webServerFor(b, f): continue
        let d = webDoc(b, f)
        var any = false
        for l in d:
          if l.len > 0:
            any = true
            break
        if not any: continue
        case f
        of "html": ws.add htmlChecks(d, fragment = true)
        of "css": ws.add cssChecks(d, strict = false)
        of "js": ws.add jsChecks(d, fragment = true)
        else: ws.add sqlChecks(d, sqlSchema(b))
      var anyDb = false
      for l in b.lines:
        if "sql\"" in l or "sql(" in l or "exec(" in l or "Rows(" in l or "getRow(" in l or "getValue(" in l:
          anyDb = true
          break
      if anyDb: ws.add sqlArgChecks(b.lines)
  for w in ws:
    result.add Diag(line: w.line, col: w.col, eline: w.eline, ecol: w.ecol, sev: w.sev, msg: w.msg, src: "ned",
                    rule: w.rule)

proc wkWeb(b: Buffer): bool
proc webChecksApply(b: Buffer, found: seq[Diag])

proc webChecksPump(b: Buffer) =
  ## the problems ned's own engines find, once the text has settled (web.engine)
  if cfgWebEngine == "off" or b == nil or b.lang == nil or b.path.len == 0 or b.largeOn: return
  let fam = webFamily(b.lang.id)
  if fam.len == 0 and b.lang.mode != lmNim: return
  if webChkAt.getOrDefault(b.id, -1) == b.changeId:
    # (done for this text — unless a problem under the cursor was held back and the cursor has moved on)
    if b.id notin webHeld or webHeld[b.id] == (b.changeId, b.primary.head): return
    if b.id in webLast and webLast[b.id][0] == b.changeId:
      webChecksApply(b, webLast[b.id][1])         # (the same text: what was found, without the cursor's word)
      return
  if msSince(lastInputAt) < 400: return
  webChkAt[b.id] = b.changeId
  webHeld.del b.id
  if wkWeb(b): return                            # (the engine worker works them out: the answer comes back)
  var ds: seq[Diag]
  try: ds = webDiagsOf(b)
  except CatchableError, Defect: return
  webChecksApply(b, ds)

proc webChecksApply(b: Buffer, found: seq[Diag]) =
  ## what ned's own CSS, HTML, SQL and JavaScript checks found (here or by the engine worker), among the file's
  ## problems — not the word being typed at the cursor
  var ds = found
  webHeld.del b.id
  webLast[b.id] = (b.changeId, found)
  if webLast.len > 64: webLast.clear()
  lintApply(b.path, b.lines, ds)
  # (not the word being typed at the cursor: `fl` on the way to `flex`; nor the tag being written there, not closed
  # yet — once the cursor moves on they show)
  if b == buf():
    let h = b.primary.head
    var keep: seq[Diag]
    for d in ds:
      if not ((d.line == h.line and d.eline == h.line and d.ecol == h.col) or
              (d.line == h.line and d.rule == "html-close" and d.sev == 2)):
        keep.add d
    if keep.len < ds.len: webHeld[b.id] = (b.changeId, h)
    ds = keep
  if ds.len > 0:
    diagsWeb[b.path] = ds
    needRender = true
  elif b.path in diagsWeb:
    diagsWeb.del b.path
    needRender = true
