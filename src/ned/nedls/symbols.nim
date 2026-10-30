# ════════════════════════════════════════════════════════════════════════════
#  nedls — workspace symbols (workspace/symbol): the declarations of the project's files — Nim's from the index,
#  C's and C++'s from the C engine, JavaScript's and JSON's from their outlines — and, for a query of three
#  characters or more, the exported names of the modules the project imports (the standard library's, packages').
#  They are kept in a table of their own, by file and its stamp, made while nedls has nothing else to do and kept
#  up to date as files are edited, saved, created and deleted, so a query only matches names. The ranking is a
#  picker's: the name itself, then names that start with the query, then names whose words start with its pieces
#  (nsh, newsha: newShape), then any fuzzy match — the project's good matches before its dependencies', and theirs
#  before the fuzzy ones.
#  "Shape.wid" looks for wid… in the type (or module) Shape; "Shape.ar" finds a routine whose first parameter is a
#  Shape too (s.area).
# ════════════════════════════════════════════════════════════════════════════

const
  LsWsLimit = 250                     # symbols in one answer at most (the best ones)
  LsWsDepQuery = 3                    # a query this long or longer looks in the dependencies too
  LsWsMaxFiles = 20_000               # project files read at most
  LsWsSweepMs = 10_000                # every so often the files' stamps are looked at again (an edit no one told of)
  LsWsQuietMs = 1500                  # the table is made while the client has been quiet this long (or when asked)

type
  LsWsSym = object
    name: string                      # as declared
    key: string                       # what a query is matched against: lower case, without underscores
    container: string                 # the type of a field or enum value, a C++ member's class, a JSON key's parent
    recv: string                      # (a Nim routine) its first parameter's type, as a key: what `Type.name` finds
    line, col, ecol: int32            # where its name is, in the client's encoding
    kind: int8                        # LSP's SymbolKind
    deprecated: bool
  LsWsFile = ref object
    path, stamp, module: string
    dep: bool                         # a module the project imports (exported names only), not one of its files
    syms: seq[LsWsSym]
    imports: seq[string]              # (Nim) its imports and includes as written

var
  lsWs: Table[string, LsWsFile]       # path → its symbols
  lsWsStale: HashSet[string]          # files changed (or opened, closed): read again before the next answer
  lsWsListed = false                  # every project file is in lsWs (made again when files come and go)
  lsWsDeps: seq[string]               # the modules the project imports, and system's files
  lsWsDepsMade = false
  lsWsSweepAt: MonoTime               # the last time every file's stamp was looked at
  lsWsSweepPos = 0                    # (a sweep goes a slice at a time)
  lsWsTags = false                    # the client takes tags (deprecated)
  lsWsGen = -1                        # nxGen when the toolchain was last looked at …
  lsWsToolchain = ""                  # … and what it was then (the library, the defines: `when` branches)
  lsWsAsked = false                   # a query came: the dependencies are read too, while idle
  lsWsBusy = true                     # lsWsIdle has more to do (else it looks again at the next sweep)

func lsWsKey(s: string): string =
  ## a name as a query is matched against it: Nim's names are the same whatever their case and underscores
  result = newStringOfCap(s.len)
  for ch in s:
    if ch notin {'_', ' '}: result.add toLowerAscii(ch)

func lsWsIsNim(path: string): bool =
  ## whether the path is a Nim source, NimScript or nimble file
  path.endsWith(".nim") or path.endsWith(".nims") or path.endsWith(".nimble")

func lsWsRecv(typ: string): string =
  ## the type a routine's first parameter has, as a key: `var Shape` → shape, `seq[T]` → seq
  var t = typ.strip
  for w in ["var ", "sink ", "lent ", "ptr ", "ref ", "static ", "typedesc "]:
    if t.startsWith(w): t = t[w.len .. ^1].strip
  var e = 0
  while e < t.len and t[e] in IdentChars: inc e
  lsWsKey(t[0 ..< e])

proc lsWsStamp(path: string): string =
  ## an open document's version, else the file's modification time and size
  let d = lsDocByPath(path)
  if d != nil: "d" & $d.b.id & ":" & $d.b.changeId else: nxStamp(path)

proc lsWsSymAt(lines: seq[string], name: string, kind, l, c: int, container: string, depr: bool): LsWsSym =
  ## one workspace symbol: its match key, and the columns of its name (to the end of the word, or of a quoted JSON key)
  ## in the client's encoding, worked out from the file's line; when the line is not known the columns are the name's
  ## length from c
  result = LsWsSym(name: name, key: lsWsKey(name), container: container, line: max(0, l).int32,
                   kind: kind.int8, deprecated: depr)
  if l >= 0 and l < lines.len:
    let s = lines[l]
    let c0 = clamp(c, 0, s.len)
    var e = lsWordEnd(s, c0)
    if c0 < s.len and s[c0] == '"':                   # (a JSON key: to its closing quote)
      let q = s.find('"', c0 + 1)
      if q > c0: e = q + 1
    result.col = lsChar(s, c0).int32
    result.ecol = lsChar(s, e).int32
  else:
    result.col = max(0, c).int32
    result.ecol = (max(0, c) + name.len).int32

proc lsWsReadNim(path, stamp: string, dep: bool): LsWsFile =
  ## a Nim file's declarations (a dependency's exported ones), from the open document or the disk — parsed by the
  ## index (or taken from its cache), not kept by it: a project of hundreds of files would crowd out what the open
  ## documents need
  result = LsWsFile(path: path, stamp: stamp, module: nxModuleName(path), dep: dep)
  let sys = nxSystemPath()
  if dep and sys.len > 0 and path.startsWith(parentDir(sys) & "/system/"): result.module = "system"
  var lines: seq[string]
  var f: NxFile
  let d = lsDocByPath(path)
  if d != nil:
    f = nxLoad(path)
    lines = d.b.lines
  else:
    if getFileSize(path) > 4_000_000: return
    let text = readFile(path)
    lines = nxLinesOf(text)
    f = nxFiles.getOrDefault(path)
    if f == nil or f.stamp != nxStamp(path):
      f = nxCacheRead(path, text)
      if f == nil:
        f = nxParse(lines, path)
        nxCacheWrite(path, text, f)
      if path in nxMacroSyms: nxAddMacroSyms(f, lines)
  if f == nil: return
  var shown: HashSet[string]             # (a dependency's exported types: their enum values are reachable too)
  if dep:
    for s in f.syms:
      if s.kind == nxType and s.exported: shown.incl s.name
  for s in f.syms:
    if s.kind in {nxModule, nxParam, nxForVar, nxResult} or s.local or s.name.len == 0: continue
    if dep and not (s.exported or (s.kind == nxEnumVal and s.owner in shown)): continue
    let container = if s.kind in {nxField, nxEnumVal}: s.owner else: ""
    result.syms.add lsWsSymAt(lines, s.name, lsSymbolKind(s), s.line, s.col, container, "deprecated" in s.pragmas)
    if s.kind in NxRoutineKinds and s.params.len > 0: result.syms[^1].recv = lsWsRecv(s.params[0].typ)
  if nxIsScript(path) and not dep:
    for t in nxScriptTasks(lines):          # (a NimScript file's tasks: `task build, "…":`)
      result.syms.add lsWsSymAt(lines, "task " & t.name, 12, t.line, t.col, "", false)
      result.syms[^1].key = lsWsKey(t.name)
  for im in f.imports: result.imports.add im.spec

proc lsWsRead(path: string, dep = false) =
  ## (re)read one file's symbols into the table (a file gone: out of it)
  let stamp = lsWsStamp(path)
  if stamp.len == 0:
    lsWs.del path
    return
  var wf: LsWsFile
  try:
    if lsWsIsNim(path): wf = lsWsReadNim(path, stamp, dep)
    else:
      wf = LsWsFile(path: path, stamp: stamp, module: extractFilename(path))
      let lines = lsLinesOf(path)
      for (name, kind, l, c, container) in lxWsSymbols(path):
        wf.syms.add lsWsSymAt(lines, name, kind, l, c, container, false)
  except Exception as e:
    lsLog("workspace symbols of " & path & ": " & e.msg)
    wf = LsWsFile(path: path, stamp: stamp, module: extractFilename(path), dep: dep)
  if wf != nil:
    # (a project file's imports changed: the dependencies are made again)
    if lsWsIsNim(path) and not dep and (path notin lsWs or lsWs[path].imports != wf.imports): lsWsDepsMade = false
    lsWs[path] = wf

proc lsWsProjectFiles(): seq[string] =
  ## the files whose symbols are listed: the open documents', then the project's (Nim, C, C++, JavaScript, JSON)
  var seen: HashSet[string]
  for _, d in lsDocs:
    let p = d.b.path
    if p.len > 0 and p notin seen and ((d.b.lang != nil and d.b.lang.mode == lmNim) or lxWsWanted(p)):
      seen.incl p
      result.add p
  if rootDir.len == 0: return
  for rel in fileCache:
    if result.len >= LsWsMaxFiles: break
    if not (lsWsIsNim(rel) or lxWsWanted(rel)): continue
    let p = if rel.isAbsolute: rel else: rootDir / rel
    if p notin seen:
      seen.incl p
      result.add p

proc lsWsMakeDeps() =
  ## the modules the project's Nim files import (and include), resolved as the compiler would, and system's files
  var deps: seq[string]
  var seen: HashSet[string]
  template add(p: string) =
    ## adds a module to the dependencies once, unless it is empty or is one of the project's own files already in the
    ## table
    if p.len > 0 and p notin seen and (p notin lsWs or lsWs[p].dep):
      seen.incl p
      deps.add p
  let sys = nxSystemPath()
  add(sys)
  for path, wf in lsWs:
    if wf.dep or not lsWsIsNim(path): continue
    for spec in wf.imports:
      try: add(nxResolve(path, spec))
      except Exception: discard
  # (system's include files are system's: their names are, too)
  var k = 0
  while k < deps.len:
    let p = deps[k]
    inc k
    if p == sys or (sys.len > 0 and p.startsWith(parentDir(sys) & "/system/")):
      let wf = lsWs.getOrDefault(p)
      if wf != nil:
        for spec in wf.imports:
          let q = (try: nxResolve(p, spec) except Exception: "")
          if q.len > 0 and q.startsWith(parentDir(sys) & "/"): add(q)
  lsWsDeps = deps
  lsWsDepsMade = true
  # (a module no longer imported: its names go)
  var gone: seq[string]
  for p, wf in lsWs:
    if wf.dep and p notin seen: gone.add p
  for p in gone: lsWs.del p

proc lsWsToolchainKey(): string =
  ## the library and the defines the Nim files are read with (`when defined(…)` decides what they declare)
  var hx: Hash = 0
  for d in nxDefines: hx = hx xor hash(d)
  nxLibDir & "|" & $hx & "|" & $nxDefinesComplete

proc lsWsUpdate(budgetMs: int, deps: bool): bool =
  ## bring the table up to date — the files changed, the files not read yet, the dependencies when wanted — for
  ## budgetMs at most; true when it is
  let t0 = getMonoTime()
  if lsWsGen != nxGen:
    lsWsGen = nxGen
    let tk = lsWsToolchainKey()
    if tk != lsWsToolchain:
      # (another toolchain, other defines: every Nim file read again)
      lsWsToolchain = tk
      lsWsDepsMade = false
      for p, wf in lsWs:
        if lsWsIsNim(p):
          wf.stamp = ""
          lsWsStale.incl p
    else:
      # (a macro's names, made by the compiler: the open documents' are read again)
      for _, d in lsDocs:
        if d.b.path in lsWs: lsWsStale.incl d.b.path
  if lsWsStale.len > 0:
    var done: seq[string]
    for p in lsWsStale:
      if msSince(t0) > budgetMs: break
      let wf = lsWs.getOrDefault(p)
      if wf == nil or wf.stamp != lsWsStamp(p): lsWsRead(p, wf != nil and wf.dep)
      done.add p
    for p in done: lsWsStale.excl p
    if lsWsStale.len > 0: return false
  if not lsWsListed:
    # (the project's file list first: the editor's own scan, a slice at a time)
    if rootDir.len > 0 and not fileCacheValid and not scanning: startScan()
    if scanning: pumpScan(max(5, budgetMs - int(msSince(t0))))
    if scanning: return false
    let files = lsWsProjectFiles()
    var want: HashSet[string]
    for p in files:
      want.incl p
      if p notin lsWs or lsWs[p].dep:
        if msSince(t0) > budgetMs: return false
        lsWsRead(p)
    var gone: seq[string]
    for p, wf in lsWs:
      if not wf.dep and p notin want: gone.add p
    for p in gone: lsWs.del p
    lsWsListed = true
    lsWsSweepAt = getMonoTime()
  if deps:
    if not lsWsDepsMade: lsWsMakeDeps()
    var k = 0
    while k < lsWsDeps.len:
      let p = lsWsDeps[k]
      inc k
      if p notin lsWs:
        if msSince(t0) > budgetMs: return false
        lsWsRead(p, dep = true)
        if p == nxSystemPath(): lsWsMakeDeps()    # (its include files are system's: now they are known)
  true

proc lsWsChanged(path: string) =
  ## a file was opened, edited, closed, saved or changed on disk: its symbols are read again when next wanted
  if path.len > 0 and (lsWsIsNim(path) or lxWsWanted(path)):
    if path in lsWs or lsWsListed:
      lsWsStale.incl path
      lsWsBusy = true

proc lsWsFilesComeAndGo() =
  ## files created or deleted, a folder added or taken away: the project's list is made again
  lsWsListed = false
  lsWsBusy = true

# ── the workspace's problems: what a change may have changed ──

proc lsLintAgain(path: string) =
  ## a file was saved, closed or changed on disk: it, the files that import it and those with errors are checked
  ## again (the change may have made or mended theirs)
  if not lsWsPulling or not lsLintOn or not lsLintQueued: return
  template again(p: string) =
    ## queues the file to be checked again, forgetting its last result so that it is checked even if its text is the
    ## same
    if p.len > 0:
      if p in lsLintDiags: lsLintDiags[p][0] = ""         # (checked again even when its own text is the same)
      if p notin lsLintQueue: lsLintQueue.add p
  if path.endsWith(".nim") and lsDocByPath(path) == nil and rootDir.len > 0 and path.startsWith(rootDir & "/") and
     not isLibraryFile(path):
    again(path)
  let name = nxModuleName(path)
  for p, wf in lsWs:
    if wf.dep or not p.endsWith(".nim") or p == path or lsDocByPath(p) != nil: continue
    for spec in wf.imports:
      if nxModuleName(spec) == name:
        again(p)
        break
  for p, (_, ds) in lsLintDiags:
    if p != path:
      for d in ds:
        if d.sev == 1:
          again(p)
          break

# ── while idle ──

proc lsWsIdle() =
  ## a slice of the table's making while nothing is asked, once the client has been quiet a moment (what it asks
  ## for comes first); lsWsBusy says whether there is more to do
  if not lsWsBusy and msSince(lsWsSweepAt) < LsWsSweepMs: return
  if msSince(lsHeardAt) < LsWsQuietMs:
    lsWsBusy = true
    return
  if not lsWsUpdate(15, lsWsAsked):
    lsWsBusy = true
    return
  lsWsBusy = false
  # (now and then every file's stamp, a few hundred at a time: changes no one told nedls of)
  if msSince(lsWsSweepAt) < LsWsSweepMs: return
  var paths: seq[string]
  for p in lsWs.keys: paths.add p
  let t0 = getMonoTime()
  while lsWsSweepPos < paths.len and msSince(t0) < 5:
    let p = paths[lsWsSweepPos]
    inc lsWsSweepPos
    if lsWsStamp(p) != lsWs[p].stamp:
      lsWsStale.incl p
      if not lsWs[p].dep and lsDocByPath(p) == nil: lsLintAgain(p)   # (changed on disk, no one said: its problems too)
  if lsWsSweepPos >= paths.len:
    lsWsSweepPos = 0
    lsWsSweepAt = getMonoTime()
  lsWsBusy = lsWsStale.len > 0 or lsWsSweepPos > 0

proc lsWsNextMs(): int =
  ## ms until lsWsIdle has something to do (for poll's timeout)
  if not lsWsBusy: return max(10, LsWsSweepMs - int(msSince(lsWsSweepAt)) + 5)
  max(10, LsWsQuietMs - int(msSince(lsHeardAt)) + 5)

# ── matching ──

func lsWsSubseq(q, key: string): bool =
  ## whether the query's letters are in the key in order, not necessarily next to each other
  var j = 0
  for ch in key:
    if j < q.len and ch == q[j]:
      inc j
      if j == q.len: return true
  j == q.len

func lsWsWords(name: string): seq[(int, int)] =
  ## the words of a name: (start, end) — split at underscores, at a capital after a small letter or a digit
  ## (newShape), before the last capital of a run followed by a small letter (HTMLParser: HTML, Parser), at digits
  var i = 0
  var start = -1
  while i <= name.len:
    let c = if i < name.len: name[i] else: '_'
    var boundary = c in {'_', '.', ' ', '-'}
    if not boundary and start >= 0 and i > start:
      let p = name[i - 1]
      if c in {'A'..'Z'} and p in {'a'..'z', '0'..'9'}: boundary = true
      elif c in {'A'..'Z'} and p in {'A'..'Z'} and i + 1 < name.len and name[i + 1] in {'a'..'z'}: boundary = true
      elif c in {'0'..'9'} and p notin {'0'..'9'}: boundary = true
    if boundary and start >= 0:
      result.add (start, i)
      start = -1
    if c notin {'_', '.', ' ', '-'} and start < 0: start = i
    inc i

proc lsWsWordStarts(q: string, qi: int, name: string, ws: seq[(int, int)], wi: int): bool =
  ## the rest of the query, q[qi..], made of pieces each of which starts a word of ws[wi..], in order
  if qi >= q.len: return true
  for w in wi ..< ws.len:
    var k = 0
    while qi + k < q.len and ws[w][0] + k < ws[w][1] and toLowerAscii(name[ws[w][0] + k]) == q[qi + k]: inc k
    for kk in countdown(k, 1):
      if lsWsWordStarts(q, qi + kk, name, ws, w + 1): return true
  false

proc lsWsMatch(q, name, key: string): (int, int) =
  ## (how well, score): 4 the name itself, 3 its start, 2 the starts of its words, 1 a fuzzy match, 0 none
  if q.len == 0: return (1, 0)
  if q.len > key.len or not lsWsSubseq(q, key): return (0, 0)
  if key == q: return (4, 0)
  if key.startsWith(q): return (3, -key.len)
  var sc = fuzzyScore(q, name)
  if sc == low(int): sc = -1_000_000
  if lsWsWordStarts(q, 0, name, lsWsWords(name), 0): return (2, sc)
  (1, sc)

proc lsWsContainerMatch(cq, name: string): int =
  ## how well a container (a type, a module) fits the part of the query before the dot: 3 itself, 2 its start,
  ## 1 the starts of its words, 0 not
  let key = lsWsKey(name)
  if key == cq: 3
  elif key.startsWith(cq): 2
  elif lsWsWordStarts(cq, 0, name, lsWsWords(name), 0): 1
  else: 0

func lsWsKindRank(k: int8): int =
  ## (equally good matches: types and routines before constants and variables, before fields and values)
  case k
  of 5, 10, 11, 23, 2: 0
  of 6, 12: 1
  of 14, 13: 2
  else: 3

proc lsWorkspaceSymbol(params: JsonNode): JsonNode =
  ## workspace/symbol: the best matches for the query among the project's names (and, for a longer query, its
  ## dependencies'), each with its kind, where it is and what it is in
  result = newJArray()
  if not lsWsAsked:
    lsWsAsked = true
    lsWsBusy = true                        # (the dependencies' names: read while idle from now on)
  let raw = params{"query"}.getStr.strip
  var q = lsWsKey(raw)
  var cq = ""                              # "Shape.wid": in the type or module Shape
  var cqRaw = ""
  let dot = raw.rfind('.')
  if dot > 0 and raw[dot - 1] != '.':
    cqRaw = raw[0 ..< dot]
    cq = lsWsKey(cqRaw)
    q = lsWsKey(raw[dot + 1 .. ^1])
  let deps = q.len >= LsWsDepQuery or cq.len >= LsWsDepQuery
  # (the project's names, all of them — the first time that may take a moment; the dependencies' as far as they
  # were read, a little more now: the rest comes while nedls is idle)
  let t0 = getMonoTime()
  discard lsWsUpdate(3000, false)
  if deps: discard lsWsUpdate(300, true)
  type Hit = tuple[ctier, good, dep, tier, score, len, rank: int, f: LsWsFile, i: int]
  var hits: seq[Hit]
  var cmemo: Table[string, int]            # container → how well it fits (asked once each)
  proc fits(c: string): int =
    ## how well a container fits the part of the query before the dot, worked out once for each container
    result = cmemo.getOrDefault(c, -1)
    if result < 0:
      result = lsWsContainerMatch(cq, c)
      cmemo[c] = result
  for f in lsWs.values:
    if f.dep and not deps: continue
    let inModule = if cq.len > 0: fits(f.module) else: 0
    for i in 0 ..< f.syms.len:
      # the symbol being looked at
      template s: untyped = f.syms[i]
      var ct = 0
      if cq.len > 0:
        # (a field, an enum value, a member: its type; a routine: its first parameter's type, or its module)
        if s.container.len > 0: ct = fits(s.container)
        else:
          ct = inModule
          if s.recv.len > 0:
            if s.recv == cq: ct = max(ct, 3)
            elif s.recv.startsWith(cq): ct = max(ct, 2)
        if ct == 0: continue
      let (tier, score) = lsWsMatch(q, s.name, s.key)
      if tier == 0: continue
      hits.add (ct, ord(tier >= 2), ord(f.dep), tier, score, s.name.len, lsWsKindRank(s.kind), f, i)
  # (the container named first; then the good matches — the name, its start, its words' starts — the project's
  # before the dependencies'; then the fuzzy ones)
  hits.sort(proc(a, b: Hit): int =
    result = cmp(b.ctier, a.ctier)
    if result == 0: result = cmp(b.good, a.good)
    if result == 0: result = cmp(a.dep, b.dep)
    if result == 0: result = cmp(b.tier, a.tier)
    if result == 0: result = cmp(b.score, a.score)
    if result == 0: result = cmp(a.len, b.len)
    if result == 0: result = cmp(a.rank, b.rank)
    if result == 0: result = cmp(a.f.path, b.f.path)
    if result == 0: result = cmp(a.i, b.i))
  var uris: Table[string, string]
  for k in 0 ..< min(hits.len, LsWsLimit):
    let f = hits[k].f
    # the symbol of the hit being written
    template s: untyped = f.syms[hits[k].i]
    var u = uris.getOrDefault(f.path)
    if u.len == 0:
      u = lsUriOf(f.path)
      uris[f.path] = u
    var j = %*{"name": s.name, "kind": s.kind.int,
               "location": {"uri": u, "range": {"start": {"line": s.line.int, "character": s.col.int},
                                                "end": {"line": s.line.int, "character": s.ecol.int}}},
               "containerName": (if s.container.len > 0: s.container else: f.module)}
    if s.deprecated and lsWsTags: j["tags"] = %*[1]
    result.add j
  if lsVerbose:
    lsLog("workspace/symbol " & raw & ": " & $hits.len & " matches in " & $lsWs.len & " files, " &
          $(getMonoTime() - t0).inMilliseconds & " ms")
