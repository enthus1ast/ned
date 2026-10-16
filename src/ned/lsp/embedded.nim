# ── HTML, CSS, SQL, JSON (and JavaScript) in Nim strings, through their language servers: hidden documents
#    built from what the lexer coloured, one per language (JSON: one per string), on the .nim's lines ──

type EmbDoc = object
  key: string                  # html, css, sql, javascript, json#0 …
  lang: Lang
  lines: seq[string]
  lo, hi: int                  # the lines it has text on

const EmbLangs = ["html", "css", "sql", "json", "javascript"]

var
  embDocs: Table[int, Table[string, Buffer]]     # Nim buffer id → key → hidden document
  embRange: Table[string, (int, int)]            # hidden document → the lines of its text
  embChange: Table[int, int]                     # Nim buffer id → the change its documents mirror
  embSrv: Table[string, LspServer]               # hidden document → the server it is open in
  embAvail: Table[string, bool]                  # language id → a server for it is installed

proc embServerAvailable(lg: Lang): bool =
  if lg == nil: return false
  if lg.id in embAvail: return embAvail[lg.id]
  var ok = false
  if lg.id in cfgUserLsp and cfgUserLsp[lg.id].len > 0 and findExe(cfgUserLsp[lg.id][0]).len > 0: ok = true
  for c in lg.lsp:
    if c.len > 0 and findExe(c[0]).len > 0: ok = true
  embAvail[lg.id] = ok
  ok

proc embedDocs(b: Buffer): seq[EmbDoc] =
  ## the text of each language in this file's strings, on its own lines and columns (strformat's
  ## {expressions} blanked, its {{ and }} one brace wide, SQL and JavaScript strings ending with a ;)
  if b.lines.len > 20000: return
  var any = false
  for l in b.lines:
    if '"' in l:
      any = true
      break
  if not any: return
  b.ensureHl(b.lines.len)
  var byLang: Table[string, int]
  var toks: seq[TokKind]
  var jsonOpen = -1
  var nJson = 0
  var openRun: Table[string, int]       # SQL / JavaScript in a string that goes on below: its last line so far
  proc closeRuns(res: var seq[EmbDoc], keepIds: HashSet[string]) =
    ## a multi-line SQL or JavaScript string ended: a ; after its last line (one statement per string)
    var done: seq[string]
    for lid, ln in openRun:
      if lid in keepIds or lid notin byLang: continue
      res[byLang[lid]].lines[ln].add ';'
      done.add lid
    for lid in done: openRun.del lid
  for l in 0 ..< b.lines.len:
    let s = b.lines[l]
    let st = if l < b.hlStart.len: b.hlStart[l] else: 0
    if s.len > 2000 or ('"' notin s and stTop(st) == 0):
      if stTop(st) == 0:
        jsonOpen = -1
        closeRuns(result, initHashSet[string]())
      continue
    discard lexLine(b.lang, s, st, toks)
    let ranges = lexLangs
    var holes: seq[(int, int)]
    for (a, e, d, lg) in ranges:
      if d == 1 and lg != nil and lg.id == "nim": holes.add (a, e)
    var contJson = false
    var cont: HashSet[string]                # languages whose string goes on from the line above
    if s.strip.len == 0 and stTop(st) != 0:
      for lid in openRun.keys: cont.incl lid
    for (a, e, d, lg) in ranges:
      if d == 1 and lg != nil and a == 0 and stTop(st) != 0: cont.incl lg.id
    closeRuns(result, cont)
    for (a, e, d, lg) in ranges:
      if d != 1 or lg == nil or lg.id notin EmbLangs or e <= a or not embServerAvailable(lg): continue
      var txt = s[a ..< e]
      for (h0, h1) in holes:
        if h0 >= a and h1 <= e:
          # {expr} or {expr:spec} → a 0 of the same width (a value in CSS, SQL or JSON; text in HTML)
          var x0 = h0
          var x1 = h1
          if x0 - 1 >= a and s[x0 - 1] == '{': dec x0
          let cl = s.find('}', h1)
          if cl >= 0 and cl < e: x1 = cl + 1
          for q in x0 ..< x1: txt[q - a] = ' '
          txt[x0 - a] = '0'
      var q = a
      while q + 1 < e:
        if q < toks.len and toks[q] == tkEscape and s[q] in {'{', '}'} and s[q + 1] == s[q]:
          txt[q + 1 - a] = ' '
          q += 2
        else: inc q
      let ends = e < s.len
      var idx: int
      if lg.id == "json":
        if a == 0 and jsonOpen >= 0: idx = jsonOpen
        else:
          result.add EmbDoc(key: "json#" & $nJson, lang: lg, lines: newSeq[string](b.lines.len), lo: l, hi: l)
          idx = result.high
          inc nJson
        if not ends:
          contJson = true
          jsonOpen = idx
      else:
        if lg.id notin byLang:
          result.add EmbDoc(key: lg.id, lang: lg, lines: newSeq[string](b.lines.len), lo: l, hi: l)
          byLang[lg.id] = result.high
        idx = byLang[lg.id]
      result[idx].hi = l
      var line = result[idx].lines[l]
      if line.len < a + txt.len: line.add spaces(a + txt.len - line.len)
      for k in 0 ..< txt.len: line[a + k] = txt[k]
      if ends and lg.id in ["sql", "javascript"]:        # one statement per string
        if line.len < e + 1: line.add spaces(e + 1 - line.len)
        line[e] = ';'
        openRun.del lg.id
      elif not ends and lg.id in ["sql", "javascript"]: openRun[lg.id] = l
      result[idx].lines[l] = line
    if not contJson and not (s.strip.len == 0 and stTop(st) != 0): jsonOpen = -1
  closeRuns(result, initHashSet[string]())

proc embExt(id: string): string =
  case id
  of "javascript": "js"
  else: id

proc embCloseDoc(sh: Buffer) =
  let s = embSrv.getOrDefault(sh.path)
  if s != nil and not s.dead and sh.lspOpen:
    s.lspNotify("textDocument/didClose", %*{"textDocument": {"uri": uriFromPath(sh.path)}})
  let nimPath = shadowNim.getOrDefault(sh.path)
  shadowNim.del sh.path
  shadowLangName.del sh.path
  embRange.del sh.path
  embSrv.del sh.path
  if sh.path in diagsByShadow:
    diagsByShadow.del sh.path
    if nimPath.len > 0: mergeShadowDiags(nimPath)

proc embSync(b: Buffer) =
  ## this file's hidden documents up to date, and open in their servers (started when needed)
  if b == nil or b.lang == nil or b.lang.mode != lmNim or b.path.len == 0 or b.largeOn: return
  var docs = embDocs.getOrDefault(b.id)
  if embChange.getOrDefault(b.id, -1) != b.changeId:
    embChange[b.id] = b.changeId
    let fresh = embedDocs(b)
    var keep: HashSet[string]
    for d in fresh:
      keep.incl d.key
      var sh = docs.getOrDefault(d.key)
      if sh == nil or sh.lang != d.lang:
        if sh != nil: embCloseDoc(sh)
        sh = newBuffer()
        sh.lang = d.lang
        sh.path = privDir() / "embed" / fnv(b.path) / (d.key.replace("#", "-") & "." & embExt(d.lang.id))
        try: createDir(parentDir(sh.path))
        except CatchableError: continue
        shadowNim[sh.path] = b.path
        shadowLangName[sh.path] = d.lang.name
        docs[d.key] = sh
      sh.lines = if d.lines.len > 0: d.lines else: @[""]
      sh.lspDirty = true
      embRange[sh.path] = (d.lo, d.hi)
    var gone: seq[string]
    for k in docs.keys:
      if k notin keep: gone.add k
    for k in gone:
      embCloseDoc(docs[k])
      docs.del k
    if docs.len > 0: embDocs[b.id] = docs
    elif b.id in embDocs: embDocs.del b.id
  for k, sh in docs:
    let s = lspFor(sh)
    if s == nil or not s.ready or s.dead: continue
    if embSrv.getOrDefault(sh.path) != s:
      sh.lspOpen = false
      embSrv[sh.path] = s
    lspSync(sh)

proc embClose(b: Buffer) =
  if b == nil or b.id notin embDocs: return
  for k, sh in embDocs[b.id]: embCloseDoc(sh)
  embDocs.del b.id
  embChange.del b.id

var embPumpAt: Table[int, MonoTime]

proc embPump(b: Buffer) =
  ## after a pause in typing: the hidden documents of the current Nim file's strings brought up to date
  if b == nil or b.lang == nil or b.lang.mode != lmNim or b.path.len == 0: return
  if msSince(b.lspChangeAt) < 400 or msSince(embPumpAt.getOrDefault(b.id)) < 300: return
  if embChange.getOrDefault(b.id, -1) == b.changeId:
    var settled = true
    for k, sh in embDocs.getOrDefault(b.id):
      if not sh.lspOpen or sh.lspDirty: settled = false
    if settled: return
  embPumpAt[b.id] = getMonoTime()
  embSync(b)

proc embDocAt(b: Buffer, p: Pos): (LspServer, Buffer) =
  ## the hidden document (and its server) for the string code at p
  if b == nil or b.lang == nil or b.lang.mode != lmNim or p.line >= b.lines.len or b.lines[p.line].len > 2000: return
  let lg = b.langAt(p)
  if lg == nil or lg.id notin EmbLangs: return
  embSync(b)
  var sh: Buffer = nil
  for k, d in embDocs.getOrDefault(b.id):
    if d.lang.id != lg.id: continue
    let r = embRange.getOrDefault(d.path, (-1, -1))
    if lg.id != "json" or (p.line >= r[0] and p.line <= r[1]): sh = d
  if sh == nil: return
  let s = embSrv.getOrDefault(sh.path)
  if s == nil or s.dead or not s.ready or not sh.lspOpen: return
  (s, sh)

proc embComplete(b: Buffer, p: Pos, manual: bool): bool =
  ## completion in HTML, CSS, SQL … in a Nim string, from that language's server
  let (s, sh) = embDocAt(b, p)
  if s == nil or s.caps == nil or s.caps{"completionProvider"} == nil: return false
  let ws = b.wordStart(p)
  if compOpen and compLine == p.line and compStartCol == ws and compFromLsp and compItems.len > 0:
    refilterComp()
    return true
  let prev = if p.col > 0: b.lines[p.line][p.col - 1] else: ' '
  let trig = prev in s.triggers and not isWordByte(prev)
  if not manual and not trig and not isWordByte(prev): return false
  let ctx = if trig: %*{"triggerKind": 2, "triggerCharacter": $prev} else: %*{"triggerKind": 1}
  discard s.lspRequest("textDocument/completion", %*{"textDocument": {"uri": uriFromPath(sh.path)},
    "position": s.lspPos(sh, p), "context": ctx},
    LspReq(kind: lrCompletion, bufId: b.id, pos: p, version: sh.lspVersion, extra: sh.lang.id))
  true

proc embHover(b: Buffer, p: Pos, auto: bool): bool =
  let (s, sh) = embDocAt(b, p)
  if s == nil or s.caps == nil or s.caps{"hoverProvider"} == nil: return false
  discard s.lspRequest("textDocument/hover", %*{"textDocument": {"uri": uriFromPath(sh.path)},
    "position": s.lspPos(sh, p)}, LspReq(kind: lrHover, bufId: b.id, pos: p,
    extra: (if auto: "auto" else: ""), extra2: "emb"))
  true
