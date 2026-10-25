# ── ned's own CSS, HTML, SQL, JavaScript and JSON in the editor: in .css / .scss / .less, .html, .sql, .js and .json
#    files and where they are embedded (an HTML <style> or <script>, Nim strings) — completion, hover, go to
#    definition and problems, when no language server does it (web.engine: auto) ──

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

# ── JSON: the schemas of the files ned knows — package.json, tsconfig.json, atlas.config … and its own ──

var nedSettingsSchemaMemo, nedLintSchemaMemo: JSchema

proc nedSettingsSchema(): JSchema =
  ## ned's settings (config.json, a project's .ned/settings.json): every setting, what it takes, what it does —
  ## each by its whole name ("nim.engineHints") or in its section's object ("nim": {"engineHints": …})
  if nedSettingsSchemaMemo != nil: return nedSettingsSchemaMemo
  initSettingDefs()
  result = JSchema(typ: "object", title: "ned's settings", other: JSchema(),
                   desc: "ned's settings — Settings (Ctrl+,) shows them all, with what each does")
  var sections: OrderedTable[string, JSchema]
  for d in setDefs:
    let s = JSchema(desc: d.doc & "  (" & d.cat & ")", default: $d.def)
    case d.kind
    of skBool: (s.typ = "boolean"; s.values = @["true", "false"])
    of skInt: s.typ = "number"
    of skStr: s.typ = "string"
    of skEnum:
      s.typ = "string"
      for o in d.opts: s.values.add escapeJson(o)
    of skJson: s.typ = (case d.def.kind
                        of JArray: "array"
                        of JObject: "object"
                        else: "")
    result.props[d.key] = s
    let dot = d.key.find('.')
    if dot > 0 and d.key[0 ..< dot] in SettingSections:
      let sec = d.key[0 ..< dot]
      if sec notin sections:
        sections[sec] = JSchema(typ: "object", other: JSchema(), desc: "the " & sec & " settings, by their short names")
      sections[sec].props[d.key[dot + 1 .. ^1]] = s
  for sec, s in sections:
    if sec notin result.props: result.props[sec] = s
  nedSettingsSchemaMemo = result

proc nedLintSchema(): JSchema =
  ## .ned/lint.json: each of ned's own checks by its rule, how serious it is or off; the files left out
  if nedLintSchemaMemo != nil: return nedLintSchemaMemo
  let sevs = @["\"off\"", "\"error\"", "\"warning\"", "\"info\"", "\"hint\"", "true", "false"]
  let rules = JSchema(typ: "object", desc: "a rule's severity, or off: \"var-let\": \"off\"")
  for (r, what, sv) in NedRules:
    rules.props[r] = JSchema(desc: what & " — on its own: " & ["off", "an error", "a warning", "information", "a hint"][sv],
                             values: sevs)
  result = JSchema(typ: "object", title: ".ned/lint.json", desc: "the rules of ned's own checks for this project", props:
    {"rules": rules,
     "exclude": JSchema(typ: "array", desc: "files left out: \"generated/\" (a folder), \"**/*_gen.nim\" (a glob)",
                        items: JSchema(typ: "string"))}.toOrderedTable)
  nedLintSchemaMemo = result

proc jsonSchemaOf(path: string): JSchema =
  ## the schema of a JSON file by its name and place (nil: none)
  if path.len == 0: return nil
  let p = path.replace('\\', '/')
  if p.endsWith("/.ned/lint.json"): return nedLintSchema()
  if p.endsWith("/.ned/settings.json") or path == configFile(): return nedSettingsSchema()
  jsonSchemaFor(path)

proc nedSettingsChecks(lines: seq[string]): seq[WebDiag] =
  ## ned's settings file: keys ned does not know (a typo's near name), values a setting does not take — as ned reads
  ## the file (a section's object as its keys)
  let d = jsonRead(lines, comments = true)
  if d.root == nil or d.root.kind != jkObject: return
  var members: seq[(string, JNode)]
  for k in d.root.kids:
    if k.key in SettingSections and k.kind == jkObject:
      for k2 in k.kids: members.add (k.key & "." & k2.key, k2)
    else: members.add (k.key, k)
  for (key, n) in members:
    if n.kind == jkBad: continue
    let i = setIndex.getOrDefault(key, -1)
    if i < 0:
      let note = unknownSettingNote(key)
      if note.len > 0:
        result.add WebDiag(line: n.keyLine, col: n.keyCol, eline: n.keyLine, ecol: n.keyEcol, sev: 2,
                           rule: "json-unknown-key", msg: "not a setting ned has: " & note)
      continue
    let v = jsonToNode(n)
    if v != nil and not validSetting(setDefs[i], v):
      let sd = setDefs[i]
      let want = case sd.kind
                 of skBool: "true or false"
                 of skInt: "a number"
                 of skStr: "a string"
                 of skEnum: "one of " & (if sd.opts.len > 8: sd.opts[0 ..< 8].join(", ") & " …" else: sd.opts.join(", "))
                 of skJson: (if sd.def.kind == JArray: "a list […]" else: "an object {…}")
      result.add WebDiag(line: n.line, col: n.col, eline: n.eline, ecol: n.ecol, sev: 2, rule: "json-schema",
                         msg: "\"" & key & "\" takes " & want & " — ned uses its default (" & $sd.def & ")")

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
                                of "json": "JSON"
                                else: "SQL"))

proc webEngineOn(b: Buffer, p: Pos): bool =
  ## ned's own engine answers at p (web.engine: auto — when no language server does)
  if cfgWebEngine == "off" or b.largeOn: return false
  let fam = webLangAt(b, p)
  if fam.len == 0: return false
  if fam == "json" and (webFamily(b.lang.id) != "json" or jsonSchemaOf(b.path) == nil): return false   # (a schema's)
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
  of "json":
    if b.lines.len > 20000: return false
    let (a, its) = jsonComplete(b.lines, p.line, p.col, jsonSchemaOf(b.path), jsonComments(b.path))
    # (as you type: after a key's opening quote, after `: `, and at the letters of a key or a value)
    if not manual and its.len == 0: return false
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
    of "json": (if b.lines.len > 20000: "" else: jsonHover(b.lines, p.line, p.col, jsonSchemaOf(b.path),
                                                              jsonComments(b.path)))
    else: ""
  except CatchableError, Defect: ""

# ── JavaScript across files: an import's module, what it exports, who imports it ──

proc jsModulePath(fromPath, spec: string): string =
  ## an import's module as a file — "./util.js", "./util" (.js .mjs .cjs, or its folder's index.js), from the
  ## importing file's folder ("/x": from the project's) — "" for a package's
  if not (spec.startsWith("./") or spec.startsWith("../") or spec.startsWith("/")): return ""
  let base = if spec.startsWith("/"): (if rootDir.len > 0: rootDir / spec[1 .. ^1] else: spec)
             else: parentDir(fromPath) / spec
  let p = normalizedPath(base)
  for cand in [p, p & ".js", p & ".mjs", p & ".cjs", p / "index.js", p / "index.mjs"]:
    if fileExists(cand) and not dirExists(cand): return cand
  ""

proc jsLinesOf(path: string): seq[string] =
  ## a file's lines as the editor has them (an open buffer's, unsaved), else as they are on disk
  let i = bufIndexByPath(path)
  if i >= 0: return bufs[i].lines
  try: readFile(path).splitLines
  except CatchableError: @[]

proc jsCrossDefinition(b: Buffer, doc: seq[string], p: Pos): (string, int, int) =
  ## an imported name (or `ns.name` of an `import * as ns`): where its module declares it — ("", -1, -1) none
  result = ("", -1, -1)
  if b.path.len == 0 or webFamily(b.lang.id) != "js": return
  var (name, spec) = jsImportAt(doc, p.line, p.col)
  if spec.len == 0:
    # ns.name: the word before the dot is a namespace import
    let s = doc[p.line]
    var a = min(p.col, s.len)
    while a > 0 and (s[a - 1] in IdentChars or s[a - 1] == '$'): dec a
    var e = a
    while e < s.len and (s[e] in IdentChars or s[e] == '$'): inc e
    if a >= 2 and s[a - 1] == '.' and s[a - 2] in IdentChars:
      let (nm, sp) = jsImportAt(doc, p.line, a - 2)
      if nm == "*" and e > a: (name, spec) = (s[a ..< e], sp)
  if spec.len == 0 or name == "*": return
  let path = jsModulePath(b.path, spec)
  if path.len == 0: return
  let (l, c) = jsExportAt(jsLinesOf(path), name)
  result = if l < 0: (path, 0, 0) else: (path, l, c)     # (no such export: the module, at least)

proc jsImportersOf(home, name: string, rename: bool, skip: seq[string]): seq[(string, int, int)] =
  ## in the project's other JavaScript files: the places that import `name` (or, "default", the default export)
  ## from the module `home`, and their uses of it — for a rename only the imported name (`{name as x}` keeps x;
  ## a default import's own name stays)
  if rootDir.len == 0: return
  let stem = splitFile(home).name
  var n = 0
  for rel in projectFiles():
    let lr = rel.toLowerAscii
    if not (lr.endsWith(".js") or lr.endsWith(".mjs") or lr.endsWith(".cjs")): continue
    let full = if rel.isAbsolute: rel else: rootDir / rel
    if full == home or full in skip: continue
    inc n
    if n > 3000: break
    let ls = jsLinesOf(full)
    var any = false
    for l in ls:
      if "import" in l and (name in l or stem in l):
        any = true
        break
    if not any: continue
    # each import statement, from `import` to its "module"
    var l = 0
    while l < ls.len:
      if not ls[l].strip.startsWith("import"):
        inc l
        continue
      var last = l
      while last < ls.len - 1 and last - l < 40 and not ("\"" in ls[last] or "'" in ls[last]): inc last
      for k in l .. last:
        let s = ls[k]
        var c = 0
        while c < s.len:
          if s[c] notin IdentStartChars and s[c] != '$':
            inc c
            continue
          var e = c
          while e < s.len and (s[e] in IdentChars or s[e] == '$'): inc e
          let w = s[c ..< e]
          if w notin ["import", "from", "as"]:
            var bindAt = c
            var aliased = false
            # `name as x`: the binding is x
            var q = e
            while q < s.len and s[q] == ' ': inc q
            if s.continuesWith("as ", q):
              q += 3
              while q < s.len and s[q] == ' ': inc q
              if q < s.len and s[q] in IdentStartChars:
                bindAt = q
                aliased = true
            let (nm, sp) = jsImportAt(ls, k, bindAt)
            if sp.len > 0 and (nm == name or (name == "default" and nm == "default")) and
               (aliased or nm == "default" or w == name) and jsModulePath(full, sp) == home:
              if aliased: result.add (full, k, c)                     # (`{name as x}`: the name, not x)
              elif nm == "default" and rename: discard                # (a default import's name is its own)
              else:
                for (rl, rc, _) in jsReferences(ls, k, bindAt): result.add (full, rl, rc)
          c = e
      l = last + 1

proc jsProjectRefs(b: Buffer, p: Pos, rename = false): seq[(string, int, int)] =
  ## the name at p in this file and, when a module exports it, in the module it comes from and the files that
  ## import it
  let doc = webDoc(b, "js", near = -1)
  if p.line >= doc.len: return
  let local = jsReferences(doc, p.line, p.col)
  if local.len == 0: return
  let (imp, spec) = jsImportAt(doc, p.line, p.col)
  let word = block:
    var w = ""
    for (l, c, e) in local:
      if l == p.line and c <= p.col and p.col <= e: w = doc[l][c ..< e]
    if w.len == 0: doc[local[0][0]][local[0][1] ..< local[0][2]]
    else: w
  let aliasOnly = spec.len > 0 and imp != word          # (`{join as j}`: j is this file's own name)
  for (l, c, _) in local: result.add (b.path, l, c)
  if b.path.len == 0 or webFamily(b.lang.id) != "js" or aliasOnly or imp == "*": return
  var home = b.path
  var exportName = word
  if spec.len > 0:
    home = jsModulePath(b.path, spec)
    exportName = imp
    if home.len == 0: return
    if imp == "default" and rename: return            # (a default import's name is the importer's own)
    let hl = jsLinesOf(home)
    let (dl, dc) = jsExportAt(hl, imp)
    if dl >= 0:
      for (rl, rc, _) in jsReferences(hl, dl, dc): result.add (home, rl, rc)
  else:
    let (dl, dc) = jsExportAt(doc, "default")
    if dl >= 0 and (dl, dc, dc + word.len) in local: exportName = "default"
    elif jsExportAt(doc, word)[0] < 0: return         # (not the module's own top-level name)
  for h in jsImportersOf(home, exportName, rename, @[b.path]):
    if h notin result: result.add h

proc webDefinition(b: Buffer, p: Pos): bool =
  ## JavaScript: where the name at p is declared (in the file, or the <script>s of the page) — an imported name in
  ## the module it comes from
  if not webEngineOn(b, p) or webLangAt(b, p) != "js" or b.jsTooBig(): return false
  let doc = webDoc(b, "js", near = -1)
  if p.line >= doc.len: return false
  var at = (-1, -1)
  var other = ("", -1, -1)
  try:
    other = jsCrossDefinition(b, doc, p)
    if other[0].len == 0: at = jsDefinition(doc, p.line, p.col)
  except CatchableError, Defect: return false
  if other[0].len > 0:
    pushJump()
    let nb = openFile(other[0])
    if nb != nil:
      let q = nb.clampPos(Pos(line: other[1], col: other[2]))
      nb.setSingle(q)
      nb.centerOn(q)
    return true
  if at[0] < 0: return false
  pushJump()
  b.setSingle(b.clampPos(Pos(line: at[0], col: at[1])))
  b.centerOn(b.primary.head)
  true

proc webJsAt(b: Buffer, p: Pos): bool =
  ## does ned's own JavaScript engine answer at p (a .js file, a page's <script>)?
  webEngineOn(b, p) and webLangAt(b, p) == "js" and not b.jsTooBig()

proc webReferences(b: Buffer, p: Pos): bool =
  ## JavaScript: the uses of the name at p — across the project's modules for an exported one
  if not webJsAt(b, p): return false
  var hits: seq[(string, int, int)]
  try: hits = jsProjectRefs(b, p)
  except CatchableError, Defect: return false
  if hits.len == 0:
    info("No references — '" & b.wordAt(p) & "' is not declared in this file")
    return true
  showReferences("REFERENCES " & b.wordAt(p), hits)
  true

proc webRename(b: Buffer, p: Pos, newName: string): bool =
  ## JavaScript: the name at p renamed everywhere it means the same (with a preview)
  if not webJsAt(b, p): return false
  let nn = newName.strip
  if nn.len == 0 or not (nn[0] in IdentStartChars or nn[0] == '$') or not nn.allCharsInSet(IdentChars + {'$'}):
    warn("'" & nn & "' is not a JavaScript name")
    return true
  var hits: seq[(string, int, int)]
  try: hits = jsProjectRefs(b, p, rename = true)
  except CatchableError, Defect: return false
  if hits.len == 0: info("'" & b.wordAt(p) & "' is not declared in this file — nothing to rename")
  else: previewRenameHits(hits, b.wordAt(p), nn)
  true

# ── problems: after a pause in typing, for the file in front ──

proc webDiagsOf(b: Buffer): seq[Diag] =
  if extractFilename(b.path) == "pnak.nif": return pnakDiags(b)     # (Nim 3's lockfile)
  var ws: seq[WebDiag]
  let fam = webFamily(b.lang.id)
  let own = (fam == "html" and webHtmlFile(b)) or fam in ["css", "sql", "js", "json"]
  if own and not (cfgWebEngine == "on" or not webServerFor(b, fam)): return
  case fam
  of "css":
    let strict = splitFile(b.path).ext.toLowerAscii == ".css"
    if strict or b.path.len == 0: ws.add cssChecks(b.lines, strict = true)
  of "html":
    if webHtmlFile(b):
      ws.add htmlChecks(b.lines)
      # (the files it links to: beside it, as the browser looks for them)
      if b.path.len > 0 and splitFile(b.path).ext.toLowerAscii in [".html", ".htm"]:
        let dir = parentDir(b.path)
        for (l, c, e, p) in htmlLocalRefs(b.lines):
          let f = dir / p.replace("%20", " ")
          if not fileExists(f) and not dirExists(f):
            ws.add WebDiag(line: l, col: c, eline: l, ecol: e, sev: 2, rule: "html-link",
                           msg: "no " & p & " beside this page")
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
  of "json":
    # (a file of megabytes — data, not something typed: what std/json says of it once is enough)
    var n = 0
    for l in b.lines: n += l.len
    if n <= 4_000_000:
      let p = b.path.replace('\\', '/')
      if p.endsWith("/.ned/settings.json") or b.path == configFile():
        ws.add jsonChecks(b.lines, nil, comments = true)
        ws.add nedSettingsChecks(b.lines)
      else:
        ws.add jsonChecks(b.lines, jsonSchemaOf(b.path), jsonComments(b.path))
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
  if fam.len == 0 and b.lang.mode != lmNim and extractFilename(b.path) != "pnak.nif": return
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
