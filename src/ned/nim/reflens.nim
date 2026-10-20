# ── reference counts beside Nim declarations ("3 references"; a click lists them) ──
#    Each project file's words are indexed once (again when it changes); a declaration's count resolves each
#    place that names it, like Find references, a few declarations at a time while ned is idle.

type RefFile = object
  stamp: string
  words: seq[int32]                        # the distinct words it uses (ids)

var
  refWordId: Table[string, int32]          # normalized name → its id
  refFilesOf: seq[seq[int32]]              # word id → the files (ids) that use it
  refFileId: Table[string, int32]          # path → its id
  refFilePath: seq[string]                 # file id → path
  refFileInfo: seq[RefFile]                # file id → what is known of it
  refFiles: seq[string]
  refFilesAt: MonoTime
  refScanAt: MonoTime
  refScanPos = 0                           # where the next slice of the scan starts
  refComplete = false                      # every project file's words are in the index
  refVersion = 0                           # bumped when a project file's words change
  refCounts: Table[string, (int, int)]     # "path|name|line" → (count, version); count -1: too many to tell
  refLens: Table[int, Table[int, (string, bool)]]   # buffer id → line → (label, nobody uses an exported one)

proc refLinesOf(path: string): seq[string] =
  ## a file's text: its tab's when it is open (unsaved changes count), else from disk
  let bi = bufIndexByPath(path)
  if bi >= 0: return bufs[bi].lines
  try:
    if getFileSize(path) <= 3_000_000: result = readFile(path).splitLines
  except CatchableError: discard

proc refIndexFile(path: string) =
  ## which words the file uses, in the project-wide index (again when it changed). Only the words are kept,
  ## not the text, nor where each one is: a big project's sources would otherwise be held in memory twice over
  let stamp = nxCurStamp(path)
  if stamp.len == 0: return
  var fid = refFileId.getOrDefault(path, -1'i32)
  if fid >= 0 and refFileInfo[fid].stamp == stamp: return
  let lines = refLinesOf(path)
  if fid < 0:
    fid = int32(refFilePath.len)
    refFileId[path] = fid
    refFilePath.add path
    refFileInfo.add RefFile()
  else:
    for wid in refFileInfo[fid].words:      # its old words go
      let k = refFilesOf[wid].find(fid)
      if k >= 0: refFilesOf[wid].del k
  var seen: HashSet[int32]
  var st: NxLexState
  for line in lines:
    for (a, e) in nxIdents(line, st):
      let w = nxNorm(line[a ..< e])
      var wid = refWordId.getOrDefault(w, -1'i32)
      if wid < 0:
        wid = int32(refFilesOf.len)
        refWordId[w] = wid
        refFilesOf.add @[]
      if wid notin seen:
        seen.incl wid
        refFilesOf[wid].add fid
  var ws = newSeqOfCap[int32](seen.len)
  for wid in seen: ws.add wid
  refFileInfo[fid] = RefFile(stamp: stamp, words: ws)
  inc refVersion

proc refCountDirect(path: string, f: NxFile, si: int, limit = 300): int

proc refCountOf(path: string, f: NxFile, si: int, limit = 300): int =
  ## how many places in the project name declaration `si` (resolved as Find references does); -1: more than
  ## `limit` places to look at; -3: an operator whose uses take too long to resolve while idle.
  ## A method that overrides another also counts the calls of the ones it overrides (they dispatch to it)
  result = refCountDirect(path, f, si, limit)
  let sym = f.syms[si]
  if result < 0 or sym.kind != nxMethod or sym.params.len == 0 or "base" in sym.pragmas: return
  let sc = nxScope(f)
  let own = nxBaseName(nxStripMods(sym.params[0].typ))
  for anc in nxAncestors(sc, own):
    for r in nxLookup(sc, sym.name):
      if r.sym.kind == nxMethod and r.sym.params.len > 0 and
         nxNorm(nxBaseName(nxStripMods(r.sym.params[0].typ))) == anc:
        let n = refCountDirect(r.file.path, r.file, r.idx, limit)
        if n < 0: return n
        result += n

proc refCountDirect(path: string, f: NxFile, si: int, limit = 300): int =
  let sym = f.syms[si]
  let nw = nxNorm(sym.name)
  let target = NxRef(file: f, idx: int32(si))
  if nxIsOpName(sym.name):
    # an operator: the files that have it written, each use resolved by its operands' types
    var hits: seq[(string, int, int)]
    var checked = 0
    let t0 = getMonoTime()
    for p in refFiles:
      let lines = refLinesOf(p)
      var has = false
      for ln in lines:
        if sym.name in ln:
          has = true
          break
      if not has: continue
      let g = if p == path: f else: nxLoad(p)
      if g == nil: continue
      if not nxOpUses(target, lines, g, p, hits, checked, limit, t0, 400):
        return (if checked > limit: -1 else: -3)       # (-3: too slow to count while idle)
    return max(0, hits.len - 1)            # (its own declaration aside)
  let wid = refWordId.getOrDefault(nw, -1'i32)
  if wid < 0: return 0
  var checked = 0
  for fid in refFilesOf[wid]:
    let p = refFilePath[fid]
    let g = if p == path: f else: nxLoad(p)
    if g == nil: continue
    let lines = refLinesOf(p)
    var st: NxLexState
    for l, line in lines:
      for (c, e) in nxIdents(line, st):
        if line[c] != nw[0] or nxNorm(line[c ..< e]) != nw: continue
        if p == path and l == sym.line and c == sym.col: continue
        if nxSymAt(g, l, c) >= 0: continue            # another declaration of the name (an overload, a forward one)
        inc checked
        if checked > limit: return -1
        let (rs, ls, mp) = nxTargets(g, lines, l, c)
        if ls.len > 0 or mp.len > 0: continue
        for r in rs:
          if nxSameDecl(target, r):
            inc result
            break

proc hasBody(b: Buffer, s: NxSym): bool =
  ## a routine with a body (not a forward declaration, whose callers may be in files it includes)
  if s.endLine > s.line: return true
  var depth = 0
  for l in s.line .. min(s.line + 12, b.lines.high):
    let t = b.lines[l]
    var i = (if l == s.line: s.col else: 0)
    while i < t.len:
      case t[i]
      of '(', '[', '{': inc depth
      of ')', ']', '}': dec depth
      of '#': break
      of '"': (let e = t.find('"', i + 1); i = (if e < 0: t.len else: e))
      of '=':
        if depth == 0 and (i + 1 >= t.len or t[i + 1] != '='): return true
      else: discard
      inc i
    if depth <= 0: break                   # (the header ended on this line, without a body)
  false

proc refLensDecls(b: Buffer, f: NxFile): seq[int] =
  ## the declarations that get a count: top-level routines (not forward declarations), and types
  for i, s in f.syms:
    if s.line < 0 or s.line >= b.lines.len or s.made or s.local: continue
    if s.kind in NxRoutineKinds:
      if b.lines[s.line].len > 0 and b.lines[s.line][0] notin {' ', '\t'} and b.hasBody(s): result.add i
    elif s.kind == nxType: result.add i

proc refLensPump(b: Buffer, budgetMs = 12) =
  ## counts for the declarations on screen, a few at a time (after typing has paused)
  if not cfgRefCounts or b.lang.mode != lmNim or b.path.len == 0 or not nimEngineOn(b) or b.lines.len > 20000: return
  if not engineReady(b): return
  if msSince(b.lspChangeAt) < 700: return
  if msSince(lastInputAt) < 200: return        # (while you scroll: the counts come when you stop, not between frames)
  if refFiles.len == 0 or msSince(refFilesAt) > 10_000:
    refFiles = nimSourceFiles()
    refFilesAt = getMonoTime()
  if msSince(refScanAt) > 10_000 or not refComplete:
    # the project's words (again for files changed on disk or in another tab), a slice of the files at a time
    let t0 = getMonoTime()
    while refScanPos < refFiles.len:
      refIndexFile(refFiles[refScanPos])
      inc refScanPos
      if msSince(t0) > 12: break
    if refScanPos >= refFiles.len:
      refComplete = true
      refScanPos = 0
      refScanAt = getMonoTime()
    elif not refComplete: return            # (more next time round — the main loop comes back soon; the
                                            # counts wait for the whole project)
  let f = nxFileFor(b)
  if f == nil: return
  let t0 = getMonoTime()
  let top = max(0, b.topLine - 5)
  let bottom = b.topLine + max(20, textH) + 5
  var lens = refLens.getOrDefault(b.id)
  var changed = false
  # labels for lines that no longer hold a declaration go
  var keep: Table[int, (string, bool)]
  let decls = refLensDecls(b, f)
  var declLines: HashSet[int]
  for i in decls: declLines.incl f.syms[i].line
  for l, v in lens:
    if l in declLines: keep[l] = v
    else: changed = true
  lens = keep
  for i in decls:
    let s = f.syms[i]
    if s.line < top or s.line > bottom: continue
    let key = b.path & "|" & s.name & "|" & $s.line
    let have = refCounts.getOrDefault(key, (-2, -1))
    if have[1] == refVersion and s.line in lens: continue
    if msSince(t0) > budgetMs: break
    let n = if have[1] == refVersion: have[0] else: refCountOf(b.path, f, i)
    refCounts[key] = (n, refVersion)
    let label = if n == -3: "references…" elif n < 0: "300+ references" elif n == 0: "no references"
                elif n == 1: "1 reference"
                else: $n & " references"
    let v = (label, n == 0 and s.exported)
    if lens.getOrDefault(s.line, ("", false)) != v:
      lens[s.line] = v
      changed = true
  refLens[b.id] = lens
  if changed: needRender = true

proc refLensAt(b: Buffer, line: int): (string, bool) =
  if not cfgRefCounts or b.id notin refLens: return ("", false)
  refLens[b.id].getOrDefault(line, ("", false))

proc refLensClick(b: Buffer, line: int) =
  ## the references of the declaration on `line`
  let f = nxFileFor(b)
  if f == nil: return
  for s in f.syms:
    if s.line == line and (s.kind in NxRoutineKinds or s.kind == nxType):
      b.setSingle(Pos(line: line, col: s.col))
      runCmd("Find references")
      return
