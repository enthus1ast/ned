# ── files, modules and what each file can see ──

type
  NxRef* = object
    file*: NxFile
    idx*: int32                # (16 bytes a reference: a scope holds thousands)
    origin*: int8              # 1 this module · 2 an import · 3 system
  NxScope* = ref object
    refs*: seq[NxRef]
    byHash*: seq[(uint32, int32)]          # (hash of the normalized name, index into refs), sorted: one block of
                                           # memory where a table of names would be thousands of strings
    modules*: Table[string, string]        # module name or alias → path
    stamp*: string
    own*: NxFile                           # the parsed file this scope was built for
    anc*: Table[string, seq[string]]       # type → its ancestors (normalized base names), memoized
    deps*: seq[(string, string)]           # (path, stamp) of every other file it took symbols from
    alias*: Table[string, string]          # type name → what its aliases lead to, memoized

var
  nxFiles* = initTable[string, NxFile]()          # path → parsed file
  nxScopes* = initTable[string, NxScope]()        # path → what that file sees
  nxLibDir* = ""
  nxSearchPaths*: seq[string]                     # the compiler's search paths (stdlib dirs, --path, …)
  nxPkgDirs*: seq[string]                         # newest version of every installed nimble package
  nxModCache* = initTable[string, string]()       # "dir\tspec" → resolved path ("" = not found)
  nxGen* = 0                                      # bumped when the toolchain or a file changes
  nxBufferStamp*: proc(path: string): string = nil          # open buffers win over disk: "" = not open
  nxBufferLines*: proc(path: string): seq[string] = nil

proc nxNorm*(s: string): string =
  ## Nim identifiers are style-insensitive apart from the first character
  if s.len == 0: return s
  result.add s[0]
  for i in 1 ..< s.len:
    if s[i] != '_': result.add toLowerAscii(s[i])

proc nxStamp*(path: string): string =
  try:
    let i = getFileInfo(path)
    $i.lastWriteTime.toUnix & ":" & $i.size
  except CatchableError: ""

proc nxCurStamp*(path: string): string =
  if nxBufferStamp != nil:
    let s = nxBufferStamp(path)
    if s.len > 0: return s
  nxStamp(path)

proc nxLoad*(path: string): NxFile =
  ## the parsed file, from the open buffer when there is one, else from disk (cached by mtime and size)
  if path.len == 0: return nil
  if nxBufferStamp != nil:
    let stamp = nxBufferStamp(path)
    if stamp.len > 0:
      let old = nxFiles.getOrDefault(path)
      if old != nil and old.stamp == stamp: return old
      result = nxParse(nxBufferLines(path), path)
      result.stamp = stamp
      nxFiles[path] = result
      return
  let stamp = nxStamp(path)
  if stamp.len == 0: return nil
  let old = nxFiles.getOrDefault(path)
  if old != nil and old.stamp == stamp: return old
  try:
    if getFileSize(path) > 4_000_000: return nil
    result = nxParse(readFile(path).splitLines, path)
    result.stamp = stamp
    nxFiles[path] = result
  except CatchableError: result = nil

proc nxVersionKey*(dirName: string): seq[int] =
  ## "jsony-1.1.5-abc…" → @[1, 1, 5]
  let parts = dirName.split('-')
  if parts.len < 2: return
  for p in parts[1].split('.'):
    try: result.add parseInt(p)
    except ValueError: result.add 0

proc nxVerLess*(a, b: seq[int]): bool =
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: a[i] else: 0
    let y = if i < b.len: b[i] else: 0
    if x != y: return x < y
  false

proc nxSetToolchain*(libDir: string, searchPaths, lazyPaths: seq[string], extraPkgRoots: seq[string] = @[]) =
  nxLibDir = libDir
  nxSearchPaths.setLen(0)
  for p in searchPaths:
    if p.len > 0 and dirExists(p) and p notin nxSearchPaths: nxSearchPaths.add p
  for p in [libDir / "std", libDir, libDir / "pure", libDir / "core", libDir / "pure" / "collections",
            libDir / "impure", libDir / "pure" / "concurrency", libDir / "posix", libDir / "system"]:
    if dirExists(p) and p notin nxSearchPaths: nxSearchPaths.add p
  # nimble packages: the newest version of each
  var best = initTable[string, (seq[int], string)]()
  for root in lazyPaths & extraPkgRoots:
    if not dirExists(root): continue
    try:
      for kind, d in walkDir(root):
        if kind notin {pcDir, pcLinkToDir}: continue
        let nm = extractFilename(d)
        let dash = nm.find('-')
        let pkg = if dash > 0: nm[0 ..< dash] else: nm
        let v = nxVersionKey(nm)
        if pkg notin best or nxVerLess(best[pkg][0], v): best[pkg] = (v, d)
    except OSError: discard
  nxPkgDirs.setLen(0)
  for _, (v, d) in best: nxPkgDirs.add d
  nxModCache.clear()
  nxScopes.clear()
  inc nxGen

var nxSrcDirs* = initTable[string, string]()     # folder → srcDir of the nimble package it is in

proc nxPackageSrc*(dir: string): string =
  ## the source folder of the nimble package `dir` belongs to ("" = none): its tests and examples
  ## import the package's modules by name
  if dir in nxSrcDirs: return nxSrcDirs[dir]
  var d = dir
  block search:
    for _ in 0 .. 8:
      try:
        for kind, p in walkDir(d):
          if kind in {pcFile, pcLinkToFile} and p.endsWith(".nimble"):
            var src = ""
            for l in lines(p):
              let t = l.strip
              if t.startsWith("srcDir"):
                let eq = t.find('=')
                if eq > 0: src = t[eq + 1 .. ^1].strip.strip(chars = {'"', ' '})
            result = normalizedPath(if src.len > 0: d / src else: d)
            break search
      except OSError, IOError: discard
      let up = parentDir(d)
      if up.len == 0 or up == d: break
      d = up
  nxSrcDirs[dir] = result

proc nxResolve*(fromPath, spec0: string): string =
  ## the file an import refers to, searched like the compiler does: next to the importing module,
  ## then the search paths (stdlib, --path, config), then nimble packages
  var spec = spec0.strip(chars = {'"', ' '})
  if spec.len == 0: return ""
  let dir = parentDir(fromPath)
  let key = dir & "\t" & spec
  if key in nxModCache: return nxModCache[key]
  var std = false
  var pkg = false
  if spec.startsWith("std/"):
    spec = spec[4 .. ^1]
    std = true
  elif spec.startsWith("pkg/"):
    spec = spec[4 .. ^1]
    pkg = true
  if not spec.endsWith(".nim"): spec.add ".nim"
  var found = ""
  template try1(p: string) =
    if found.len == 0:
      let q = p
      if fileExists(q): found = normalizedPath(q)
  if spec.isAbsolute: try1(spec)
  if not std and not pkg: try1(dir / spec)
  if not pkg:
    for p in nxSearchPaths: try1(p / spec)
  if not std:
    for p in nxPkgDirs: try1(p / spec)
    # `import foo` of a package whose module sits in src/ inside the package folder
    let first = spec.split('/')[0].replace(".nim", "")
    for p in nxPkgDirs:
      if extractFilename(p).startsWith(first & "-"): try1(p / "src" / spec)
    if found.len == 0:
      let ps = nxPackageSrc(dir)
      if ps.len > 0: try1(ps / spec)
  nxModCache[key] = found
  found

proc nxModuleName*(spec: string): string =
  var s = spec.strip(chars = {'"', ' '})
  if s.endsWith(".nim"): s.setLen(s.len - 4)
  let k = s.rfind('/')
  if k >= 0: s[k + 1 .. ^1] else: s

proc nxIncluded*(f: NxFile, depth = 0): seq[NxFile] =
  ## files pulled in with `include` (recursively); their declarations belong to `f`
  if depth > 4 or f == nil: return
  for im in f.imports:
    if not im.isInclude: continue
    let p = nxResolve(f.path, im.spec)
    let g = nxLoad(p)
    if g != nil and g != f:
      result.add g
      result.add nxIncluded(g, depth + 1)

proc nxExports*(path: string, depth: int, seen: var HashSet[string], res: var seq[NxRef]) =
  ## everything a module offers to an importer: its exported symbols, those of its include files, and
  ## whatever it re-exports with `export`
  if depth > 4 or path.len == 0 or path in seen: return
  seen.incl path
  let f = nxLoad(path)
  if f == nil: return
  var parts = @[f]
  parts.add nxIncluded(f)
  for g in parts:
    for i, s in g.syms:
      if s.exported: res.add NxRef(file: g, idx: int32(i))
  if f.exports.len == 0: return
  var mods = initTable[string, string]()
  for g in parts:
    for im in g.imports:
      if im.isInclude: continue
      mods[nxModuleName(if im.alias.len > 0: im.alias else: im.spec)] = nxResolve(g.path, im.spec)
  for e in f.exports:
    let nm = nxModuleName(e.split(" except ")[0])
    if nm in mods: nxExports(mods[nm], depth + 1, seen, res)
    else:
      # a single symbol re-exported from one of the imports
      for _, p in mods:
        let g = nxLoad(p)
        if g == nil: continue
        for i, s in g.syms:
          if s.exported and s.name == e: res.add NxRef(file: g, idx: int32(i))

var
  nxIncFiles*: Table[string, (string, seq[string])]          # a file → (its stamp, the files it `include`s)
  nxIncDirs*: Table[string, (float, Table[string, string])]  # folder → (when looked, included file → includer)
  nxScopeBuilding*: HashSet[string]                           # (scopes being built: an include loop stops here)

proc nxIncludesOf*(p: string): seq[string] =
  ## the files `p` pulls in with `include` (read again only when it changed)
  let st = nxCurStamp(p)
  if p in nxIncFiles and nxIncFiles[p][0] == st: return nxIncFiles[p][1]
  var res: seq[string]
  try:
    let lines = if nxBufferLines != nil and nxBufferStamp(p).len > 0: nxBufferLines(p)
                elif getFileSize(p) <= 3_000_000: readFile(p).splitLines
                else: @[]
    var any = false
    for l in lines:
      if l.len > 8 and l.strip.startsWith("include "):
        any = true
        break
    if any:
      let g = nxLoad(p)
      if g != nil:
        for im in g.imports:
          if im.isInclude:
            let r = nxResolve(p, im.spec)
            if r.len > 0: res.add r
  except CatchableError: discard
  nxIncFiles[p] = (st, res)
  res

proc nxIncluderOf*(path: string): string =
  ## the file that `include`s this one (looked for in its folder and the three above it): its declarations,
  ## its imports and its other include files are this file's too
  if path.len == 0 or not path.endsWith(".nim"): return ""
  let now = epochTime()
  var dirs = @[parentDir(path)]
  # (and up to three folders above: a project's src/app.nim can include src/app/ui/menus.nim)
  while dirs.len < 4 and parentDir(dirs[^1]).len > 1 and parentDir(dirs[^1]) != dirs[^1]: dirs.add parentDir(dirs[^1])
  for d in dirs:
    if d notin nxIncDirs or now - nxIncDirs[d][0] > 10:
      var m: Table[string, string]
      try:
        for kind, p in walkDir(d):
          if kind in {pcFile, pcLinkToFile} and p.endsWith(".nim"):
            for inc in nxIncludesOf(p):
              if inc notin m: m[inc] = p
      except CatchableError: discard
      nxIncDirs[d] = (now, m)
    let h = nxIncDirs[d][1].getOrDefault(path)
    if h.len > 0 and h != path: return h
  ""

proc nxTopIncluder*(path: string): string =
  ## the module a file belongs to when another one `include`s it — following includes of includes — or ""
  var p = path
  for _ in 0 .. 6:
    let up = nxIncluderOf(p)
    if up.len == 0 or up == path: break
    p = up
  if p == path: "" else: p

proc nxScope*(f: NxFile): NxScope

proc nxIndexNames(sc: NxScope) =
  ## the scope's names, by hash, sorted (nxLookup)
  sc.byHash.setLen(sc.refs.len)
  for i, r in sc.refs: sc.byHash[i] = (uint32(hash(nxNorm(r.file.syms[r.idx].name)) and 0xFFFF_FFFF), int32(i))
  sc.byHash.sort(proc(x, y: (uint32, int32)): int = cmp(x[0], y[0]))

var
  nxScopeMax* = 12                     # scopes kept: the files asked about most recently (each holds thousands of refs)
  nxScopeTick = 0
  nxScopeUsed: Table[string, int]

proc nxKeepScope(path: string, sc: NxScope) =
  ## remember a scope — and forget the one asked about least recently when there are too many
  inc nxScopeTick
  nxScopeUsed[path] = nxScopeTick
  nxScopes[path] = sc
  while nxScopes.len > nxScopeMax:
    var oldest = ""
    var t = high(int)
    for p, _ in nxScopes:
      let u = nxScopeUsed.getOrDefault(p, 0)
      if p != path and u < t:
        t = u
        oldest = p
    if oldest.len == 0: break
    nxScopes.del oldest
    nxScopeUsed.del oldest

proc skey(f: NxFile): string {.inline.} =
  ## the key a file's scope is kept under (its path; the file as a left-out `when` branch sees it: its own)
  if f.scopeKey.len > 0: f.scopeKey else: f.path

proc nxIncludedScope*(f, host: NxFile): NxScope =
  ## what a file that another one includes can see: everything its includer sees (the includer's own
  ## declarations, its imports, its other include files), with this file's current declarations
  let hs = nxScope(host)
  let st = "inc|" & f.stamp & "|" & host.path & "|" & hs.stamp & "/" & $nxGen
  var old = nxScopes.getOrDefault(f.skey)
  if old != nil and old.stamp == st and old.own == f:
    var fresh = true
    for (p, ps) in old.deps:
      if nxCurStamp(p) != ps:
        fresh = false
        break
    if fresh:
      inc nxScopeTick
      nxScopeUsed[f.skey] = nxScopeTick
      return old
  result = NxScope(stamp: st, own: f, modules: hs.modules)
  for i in 0 ..< f.syms.len: result.refs.add NxRef(file: f, idx: int32(i), origin: 1)
  for r in hs.refs:
    if r.file.path != f.path: result.refs.add r
  # (its own imports, if it has any)
  var seen: HashSet[string]
  for im in f.imports:
    if im.isInclude: continue
    let p = nxResolve(f.path, im.spec)
    if p.len == 0: continue
    result.modules[nxModuleName(if im.alias.len > 0: im.alias else: im.spec)] = p
    var got: seq[NxRef]
    nxExports(p, 0, seen, got)
    for r in got:
      var r2 = r
      r2.origin = 2
      result.refs.add r2
  nxIndexNames(result)
  var seenP: HashSet[string]
  for r in result.refs:
    if r.file != f and r.file.path notin seenP:
      seenP.incl r.file.path
      result.deps.add (r.file.path, r.file.stamp)
  if host.path notin seenP: result.deps.add (host.path, host.stamp)
  nxKeepScope(f.skey, result)

proc nxScope*(f: NxFile): NxScope =
  ## what `f` can see: its own declarations, system, and its imports (a file another one `include`s: what that
  ## one sees)
  if f == nil: return NxScope()
  if f.path notin nxScopeBuilding:
    let hp = nxIncluderOf(f.path)
    if hp.len > 0:
      let hf = nxLoad(hp)
      if hf != nil and hf != f:
        nxScopeBuilding.incl f.path
        try: result = nxIncludedScope(f, hf)
        finally: nxScopeBuilding.excl f.path
        return
  var stamp = f.stamp & "/" & $nxGen
  for im in f.imports: stamp.add "|" & im.spec & ":" & $im.only.len & ":" & $im.excepts.len
  var old = nxScopes.getOrDefault(f.skey)
  if old != nil:
    # another file it sees was edited (or saved): start over
    for (p, st) in old.deps:
      if nxCurStamp(p) != st:
        old = nil
        break
  if old != nil and old.stamp == stamp and old.own == f:
    inc nxScopeTick
    nxScopeUsed[f.skey] = nxScopeTick
    return old
  if old != nil and old.stamp == stamp:
    # own symbols change with every edit; imports rarely do
    var sc = NxScope(refs: @[], stamp: stamp, modules: old.modules, own: f, deps: old.deps)
    for i in 0 ..< f.syms.len: sc.refs.add NxRef(file: f, idx: int32(i), origin: 1)
    for r in old.refs:
      if r.file != f and r.file.path != f.path: sc.refs.add r
    nxIndexNames(sc)
    nxKeepScope(f.skey, sc)
    return sc
  result = NxScope(stamp: stamp, own: f)
  for i in 0 ..< f.syms.len: result.refs.add NxRef(file: f, idx: int32(i), origin: 1)
  for g in nxIncluded(f):
    for i in 0 ..< g.syms.len: result.refs.add NxRef(file: g, idx: int32(i), origin: 1)
  var seen: HashSet[string]
  seen.incl f.path
  let sys = if nxLibDir.len > 0: nxLibDir / "system.nim" else: ""
  if sys.len > 0 and f.path != sys and not f.path.startsWith(nxLibDir / "system" & "/"):
    let before = result.refs.len
    nxExports(sys, 0, seen, result.refs)
    for k in before ..< result.refs.len: result.refs[k].origin = 3
  for im in f.imports:
    if im.isInclude: continue
    let p = nxResolve(f.path, im.spec)
    if p.len == 0: continue
    result.modules[nxModuleName(if im.alias.len > 0: im.alias else: im.spec)] = p
    var got: seq[NxRef]
    var seen2 = seen
    nxExports(p, 0, seen2, got)
    for r in got:
      let nm = r.file.syms[r.idx].name
      if im.only.len > 0 and nm notin im.only: continue
      if nm in im.excepts: continue
      var r2 = r
      r2.origin = 2
      result.refs.add r2
  nxIndexNames(result)
  var seenP: HashSet[string]
  for r in result.refs:
    if r.file != f and r.file.path notin seenP:
      seenP.incl r.file.path
      result.deps.add (r.file.path, r.file.stamp)
  nxKeepScope(f.skey, result)

proc nxLookup*(sc: NxScope, name: string): seq[NxRef] =
  let n = nxNorm(name)
  let h = uint32(hash(n) and 0xFFFF_FFFF)
  var lo = 0
  var hi = sc.byHash.len
  while lo < hi:                               # the first entry with this hash
    let mid = (lo + hi) div 2
    if sc.byHash[mid][0] < h: lo = mid + 1 else: hi = mid
  while lo < sc.byHash.len and sc.byHash[lo][0] == h:
    let r = sc.refs[sc.byHash[lo][1]]
    if nxNorm(r.file.syms[r.idx].name) == n: result.add r
    inc lo

proc sym*(r: NxRef): NxSym {.inline.} = r.file.syms[r.idx]

var
  nxOverlays: seq[(string, NxFile)]       # (file and branch, the file as that branch sees it), the latest last
  nxFullParse: (string, NxFile)           # (path and stamp, the file read with its left-out branches)

proc nxAt*(f: NxFile, lines: openArray[string], line: int): NxFile =
  ## the file as code at `line` sees it: when the line is inside a `when` branch left out on this platform (Windows
  ## code, `when defined(js)`, `when false`), the branch's own declarations and imports come first — the types it
  ## declares are not those of the branch taken here — then the file's, then those of the other left-out branches
  if f == nil or f.inactive.len == 0 or lines.len == 0: return f
  var inside = false
  for (a, b) in f.inactive:
    if a <= line and line <= b:
      inside = true
      break
  if not inside: return f
  let fkey = f.path & "\t" & f.stamp
  if nxFullParse[0] != fkey: nxFullParse = (fkey, nxParse(lines, f.path, keepInactive = true))
  let full = nxFullParse[1]
  # the innermost left-out branch around the line
  var lo, hi = -1'i32
  for (a, b) in full.inactive:
    if a <= line and line <= b and (lo < 0 or b - a < hi - lo):
      lo = a
      hi = b
  let key = fkey & "\t" & $lo
  for (k, g) in nxOverlays:
    if k == key: return g
  var ends: Table[int32, int32]
  for (a, b) in full.inactive: ends[a - 1] = b              # (symBranch holds the `when` line: the body starts below)
  let g = NxFile(path: f.path, module: f.module, stamp: f.stamp & "#" & $lo, doc: f.doc, imports: full.imports,
                 exports: full.exports, pragmas: full.pragmas,
                 scopeKey: f.path & "#when" & $lo)
  var mine, others: seq[NxSym]
  for k, s in full.syms:
    let b = if k < full.symBranch.len: full.symBranch[k] else: -1
    if b < 0: g.syms.add s
    elif b < line and line <= ends.getOrDefault(b, -1): mine.add s
    else: others.add s
  g.syms = mine & g.syms & others
  if nxOverlays.len >= 4: nxOverlays.delete(0)
  nxOverlays.add (key, g)
  g
