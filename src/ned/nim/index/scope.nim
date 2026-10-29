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
    ikey*: string                          # what it depends on besides its own text (the toolchain, its imports)
    own*: NxFile                           # the parsed file this scope was built for
    deps*: seq[(string, string)]           # (path, stamp) of every other file it took symbols from
    memo*: NxTypeMemo                      # what was worked out about its types (shared with the next version of
                                           # the scope while no type declaration changed: tm)
  NxTypeMemo* = ref object
    anc*: Table[string, seq[string]]       # type → its ancestors (normalized base names)
    alias*: Table[string, string]          # type name → what its aliases lead to
    unions*: Table[string, (seq[string], seq[string])]   # type name → (its alternatives when it is `A | B`, its
                                                          #   generic parameters)
    plain*: HashSet[string]                # types as written that are no union (nxUnionAlts asked again and again)
    compat*: Table[string, int8]           # (parameter type, generics, argument type) → nxCompat's answer

var
  nxFiles* = initTable[string, NxFile]()          # path → parsed file
  nxScopes* = initTable[string, NxScope]()        # path → what that file sees
  nxLibDir* = ""
  nxSearchPaths*: seq[string]                     # the compiler's search paths (stdlib dirs, --path, …)
  nxPkgDirs*: seq[string]                         # newest version of every installed nimble package
  nxModCache* = initTable[string, string]()       # "dir\tspec" → resolved path ("" = not found)
  nxGen* = 0                                      # bumped when the toolchain or a file changes
  nxScopeEpoch* = 0                               # bumped when what scopes hold changes without the files' text
                                                  #   changing (names a macro makes, other defines): completion's memo
  nxTrace*: proc(what: string, t0: MonoTime) {.nimcall.} = nil   # (measuring: how long a part took — ned's
                                                                 #   NED_PERF_TRACE; nil: nothing noted)
  nxBufferStamp*: proc(path: string): string = nil          # open buffers win over disk: "" = not open
  nxBufferLines*: proc(path: string): seq[string] = nil

proc tm*(sc: NxScope): NxTypeMemo {.inline.} =
  if sc.memo == nil: sc.memo = NxTypeMemo()
  sc.memo

proc nxSameTypes*(a, b: NxFile): bool =
  ## do two versions of a file declare the same types (the same definitions)? Then what a scope worked out about
  ## types still holds with the other version in it
  if a == b: return true
  if a == nil or b == nil: return false
  var i, j = 0
  while true:
    while i < a.syms.len and a.syms[i].kind != nxType: inc i
    while j < b.syms.len and b.syms[j].kind != nxType: inc j
    if i >= a.syms.len or j >= b.syms.len: return i >= a.syms.len and j >= b.syms.len
    if a.syms[i].name != b.syms[j].name or a.syms[i].typ != b.syms[j].typ or a.syms[i].generics != b.syms[j].generics or
       a.syms[i].local != b.syms[j].local:
      return false
    inc i
    inc j

var nxExact* = false      ## Nim 3 (nimony): names are matched as written — case and underscores count

func nxNorm2*(s: string): string =
  ## Nim 2's rule: identifiers are style-insensitive apart from the first character
  if s.len == 0: return s
  result.add s[0]
  for i in 1 ..< s.len:
    if s[i] != '_': result.add toLowerAscii(s[i])

func nxNorm*(s: string): string =
  ## a name as the index keys it: Nim 2's rule, or (Nim 3) as it is written
  {.cast(noSideEffect).}:
    if nxExact: return s
  nxNorm2(s)

func nxNameHash*(s: string): uint32 =
  ## the hash a scope keeps a name under (its normalized form's, as nxNorm makes it — without making it: a scope of
  ## ten thousand names made as many strings)
  var h = 2166136261'u32
  template mix(c: char) = h = (h xor uint32(ord(c))) * 16777619'u32
  {.cast(noSideEffect).}:
    let exact = nxExact
  if s.len == 0: return h
  if exact:
    for c in s: mix(c)
  else:
    mix(s[0])
    for i in 1 ..< s.len:
      if s[i] != '_': mix(toLowerAscii(s[i]))
  h

const NxStatFreshMs = 50                # (a file's stamp, read again after this: one question stats each file once)
var
  nxStatMemo* = false                  # ned --lint: nothing changes the files while it runs — each one stat'ed once
  nxStatSeen: Table[string, (string, MonoTime)]

proc nxStamp*(path: string): string =
  ## a file's modification time and size ("" not there). A question to the engine asks for the same files many times
  ## (each scope it looks through checks what it read): a stamp read in the last 50 ms is taken as it is — on
  ## Android's shared storage a stat is slow
  let now = getMonoTime()
  nxStatSeen.withValue(path, v):
    if nxStatMemo or (now - v[][1]).inMilliseconds < NxStatFreshMs: return v[][0]
  result = try:
             let i = getFileInfo(path)
             $i.lastWriteTime.toUnix & ":" & $i.size
           except CatchableError: ""
  if nxStatSeen.len > 50_000: nxStatSeen.clear()
  nxStatSeen[path] = (result, now)

proc nxStatForget*(path = "") =
  ## a file just written (or all, "") is stat'ed again when next asked for
  if path.len == 0: nxStatSeen.clear() else: nxStatSeen.del path

proc nxCurStamp*(path: string): string =
  if nxBufferStamp != nil:
    let s = nxBufferStamp(path)
    if s.len > 0: return s
  nxStamp(path)

proc nxParseDisk*(path: string): NxFile

# ── what the index takes: the parsed files are counted, and over nim.indexMemory the ones asked about least recently
#    (and not open) are dropped with the scopes that read them — a library file comes back from the disk cache ──

var
  nxIndexBudget* = 64 * 1048576        # nim.indexMemory: bytes the parsed files may take (0: no limit)
  nxTick = 0                           # (a clock: each file or scope asked for moves it on)
  nxFileUsed: Table[string, int]       # path → when it was asked for last
  nxFileBytes: Table[string, int]      # path → what its parsed file takes
  nxFilesBytes* = 0                    # their sum
  nxBuildDepth = 0                     # (scopes being built: no file is dropped meanwhile)
  nxDropped* = 0                       # files dropped to stay within the budget, so far

func nxStrBytes(s: string): int {.inline.} =
  if s.len == 0: 0 else: (s.capacity + 9 + 15) and not 15

func nxFileSize*(f: NxFile): int =
  ## the bytes a parsed file takes (its declarations, their strings, its imports; its line table when made)
  result = 256 + nxStrBytes(f.path) + nxStrBytes(f.module) + nxStrBytes(f.stamp) + nxStrBytes(f.doc) +
           f.syms.capacity * sizeof(NxSym) + f.syms.len * 40      # (byLine, made on first use)
  for s in f.syms:
    result += nxStrBytes(s.name) + nxStrBytes(s.generics) + nxStrBytes(s.ret) + nxStrBytes(s.typ) +
              nxStrBytes(s.value) + nxStrBytes(s.pragmas) + nxStrBytes(s.doc) + nxStrBytes(s.owner)
    if s.params.len > 0:
      result += 16 + s.params.capacity * sizeof(NxParam)
      for p in s.params: result += nxStrBytes(p.name) + nxStrBytes(p.typ) + nxStrBytes(p.default)
  result += f.imports.capacity * sizeof(NxImport)
  for im in f.imports:
    result += nxStrBytes(im.spec) + nxStrBytes(im.alias)
    for x in im.only: result += nxStrBytes(x) + 16
    for x in im.excepts: result += nxStrBytes(x) + 16
  for x in f.exports: result += nxStrBytes(x) + 16
  result += f.inactive.len * 8 + f.symBranch.len * 4 + f.inactiveChain.len * 4
  for x in f.chains: result += nxStrBytes(x) + 16

proc nxTrimIndex*(keep = "")

proc nxBuildDone(keep: string) =
  ## a scope made: what it read may have gone over the budget meanwhile
  dec nxBuildDepth
  if nxBuildDepth == 0 and nxIndexBudget > 0 and nxFilesBytes > nxIndexBudget: nxTrimIndex(keep)

proc nxKeepFile(path: string, f: NxFile) =
  ## a freshly parsed file kept: what it takes counted; over the budget, the least recently used ones go
  if f.syms.capacity - f.syms.len > 8:
    # (the parser's list grew by doubling: 12% of what the declarations took was room never used)
    var s = newSeqOfCap[NxSym](f.syms.len)
    for x in f.syms.mitems: s.add move(x)
    f.syms = move(s)
  nxFiles[path] = f
  let b = nxFileSize(f)
  nxFilesBytes += b - nxFileBytes.getOrDefault(path)
  nxFileBytes[path] = b
  inc nxTick
  nxFileUsed[path] = nxTick
  if nxIndexBudget > 0 and nxFilesBytes > nxIndexBudget and nxBuildDepth == 0: nxTrimIndex(path)

proc nxLoad*(path: string): NxFile =
  ## the parsed file, from the open buffer when there is one, else from disk (cached by mtime and size)
  if path.len == 0: return nil
  if nxBufferStamp != nil:
    let stamp = nxBufferStamp(path)
    if stamp.len > 0:
      let old = nxFiles.getOrDefault(path)
      if old != nil and old.stamp == stamp:
        inc nxTick
        nxFileUsed[path] = nxTick
        return old
      let lines = nxBufferLines(path)
      result = nxParse(lines, path)
      nxAddMacroSyms(result, lines)
      result.stamp = stamp
      nxKeepFile(path, result)
      return
  let stamp = nxStamp(path)
  if stamp.len == 0: return nil
  let old = nxFiles.getOrDefault(path)
  if old != nil and old.stamp == stamp:
    inc nxTick
    nxFileUsed[path] = nxTick
    return old
  try:
    if getFileSize(path) > 4_000_000: return nil
    result = nxParseDisk(path)
    if path in nxMacroSyms: nxAddMacroSyms(result, readFile(path).splitLines)
    result.stamp = stamp
    nxKeepFile(path, result)
  except CatchableError: result = nil

proc nxForgetFiles*() =
  ## every parsed file read again when next asked for (the defines changed: what `when` decides)
  inc nxScopeEpoch
  nxFiles.clear()
  nxFileBytes.clear()
  nxFileUsed.clear()
  nxFilesBytes = 0

proc nxVersionKey*(dirName: string): seq[int] =
  ## "jsony-1.1.5-abc…" → @[1, 1, 5]
  let parts = dirName.split('-')
  if parts.len < 2: return
  for p in parts[1].split('.'):
    try: result.add parseInt(p)
    except ValueError: result.add 0

func nxVerLess*(a, b: seq[int]): bool =
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: a[i] else: 0
    let y = if i < b.len: b[i] else: 0
    if x != y: return x < y
  false

var nxPkgRoots: seq[string]       # (the folders nimble packages were looked for in last)

type
  NxInstalled* = object
    ver*: string                  # "1.1.5", "#head", "" (atlas: none in the folder's name)
    key*: seq[int]
    sum*: string                  # pkgs2's checksum: name-1.1.5-<sum>
    dir*: string
  NxDep* = object
    name*, version*, dir*, why*: string     # why: "nimble.lock", "nimble.paths", "requires >= 1.2", "newest installed" …
  NxProject* = ref object
    root*: string                 # the folder of its .nimble ("" for files outside any nimble package)
    paths*: seq[string]           # package folders its config puts on the path (`nim dump`: nimble.paths, atlas)
    deps*: seq[NxDep]             # the version of each package it uses, and why that one
    dirs*: seq[string]            # their folders, in the order imports look in them
    rest*: seq[string]            # the newest installed version of every other package
    key*: string                  # (what imports resolve to: a scope or a resolved import made for another is not used)
    stamp: string
    checked: float

var
  nxInstalled*: Table[string, seq[NxInstalled]]   # package (lower case) → every installed version
  nxProjects*: Table[string, NxProject]           # project folder → the versions it builds with
  nxProjectPaths*: Table[string, seq[string]]     # project folder → the package folders `nim dump` put on its path
  nxActive*: NxProject                            # the project asked about last: package files follow it
  nxResolveMemo*: Table[(string, string), tuple[path, root: string, pkg: bool, proj: NxProject]]
                                                  # (importing file, spec as written) → nxResolve's answer, and the
                                                  #   project it was for (its folder; a package's file: the active)
  nxRootOf: Table[string, string]                 # folder → the project folder above it ("" none)

proc nxPkgSplit*(dirName: string): (string, string) =
  ## a package folder's name and version: "jsony-1.1.5-7957fb…" → ("jsony", "1.1.5"), "nim-libp2p-1.2.0" →
  ## ("nim-libp2p", "1.2.0"), "foo-#head-ab12" → ("foo", "#head"), "foo" (atlas) → ("foo", "")
  let parts = dirName.split('-')
  for i in 1 ..< parts.len:
    if parts[i].len > 0 and (parts[i][0] in Digits or parts[i][0] == '#'):
      return (parts[0 ..< i].join("-"), parts[i])
  (dirName, "")

proc nxVerKey*(v: string): seq[int] =
  ## "1.10.2" → @[1, 10, 2] (a version that is no number, #head: @[])
  for p in v.strip(chars = {'v', ' '}).split('.'):
    var d = 0
    var any = false
    for c in p:
      if c notin Digits: break
      d = d * 10 + (ord(c) - 48)
      any = true
    if not any: break
    result.add d

proc nxSatisfies*(ver, cons: string): bool =
  ## nimble's version rules: >= 1.2 · > · <= · < · == · 1.2 (that one) · ^= 1.2 (same major) · ~= 1.2.3 (same minor)
  ## · several joined by & · #head, #tag (that one) · nothing (any)
  let c = cons.strip
  if c.len == 0 or c == "*" or c == "any version": return true
  if c.startsWith("#") or c.startsWith("@#"): return ver == c.strip(chars = {'@'})
  if ver.startsWith("#"): return false              # (#head does not count for a numbered requirement)
  let v = nxVerKey(ver)
  if v.len == 0: return true                         # (a version we cannot read: not held against it)
  for part0 in c.split('&'):
    let part = part0.strip
    if part.len == 0: continue
    var k = 0
    while k < part.len and part[k] in {'>', '<', '=', '^', '~', '@'}: inc k
    let op = part[0 ..< k]
    let want = nxVerKey(part[k .. ^1])
    if want.len == 0: continue
    var d = 0
    for i in 0 ..< max(v.len, want.len):
      let x = if i < v.len: v[i] else: 0
      let y = if i < want.len: want[i] else: 0
      if x != y:
        d = cmp(x, y)
        break
    let ok = case op
      of ">=": d >= 0
      of ">": d > 0
      of "<=": d <= 0
      of "<": d < 0
      of "", "==", "@": d == 0
      of "^=": d >= 0 and (if want[0] > 0: v[0] == want[0] else: v.len > 1 and want.len > 1 and v[1] == want[1])
      of "~=":
        var same = true
        for i in 0 ..< max(1, want.len - 1):
          if i >= v.len or i >= want.len or v[i] != want[i]: same = false
        d >= 0 and same
      else: true
    if not ok: return false
  true

func nxSplitRequire*(r: string): (string, string) =
  ## "jsony >= 1.1 & < 2.0" → ("jsony", ">= 1.1 & < 2.0") · "foo#head" → ("foo", "#head") ·
  ## "https://github.com/x/bar.git >= 1.0" → ("bar", ">= 1.0")
  let t = r.strip
  var k = 0
  if "://" in t or t.startsWith("git@"):
    k = (if t.startsWith("git@"): 4 else: t.find("://") + 3)
    while k < t.len and t[k] notin {' ', '#', '>', '<', '=', '~', '^', '@'}: inc k
    var nm = t[0 ..< k].strip(chars = {'/'})
    nm = nm[max(nm.rfind('/'), nm.rfind(':')) + 1 .. ^1]
    if nm.endsWith(".git"): nm.setLen(nm.len - 4)
    return (nm, t[k .. ^1].strip(chars = {' ', '@'}))
  while k < t.len and t[k] notin {' ', '>', '<', '=', '#', '@', '~', '^'}: inc k
  (t[0 ..< k], t[k .. ^1].strip(chars = {' ', '@'}))

proc nxNimbleRequires*(nimbleFile: string): seq[string] =
  ## the `requires` of a .nimble file as written ("jsony >= 1.1", "https://…/foo#head")
  var inReq = false
  var depth = 0                     # (inside `requires(` … `)` over several lines)
  try:
    for raw in lines(nimbleFile):
      let t = raw.strip
      if t.len == 0 or t.startsWith("#"):
        if depth == 0: inReq = false
        continue
      let k = t.find("requires")
      if (k >= 0 and (k == 0 or not nxIsIdent(t[k - 1])) and k + 8 < t.len and t[k + 8] in {' ', '('}) or
         (inReq and (t.startsWith("\"") or t.startsWith(")"))):
        var i = (if k >= 0: k + 8 else: 0)
        while i < t.len:
          if t[i] == '#': break
          if t[i] == '"':
            let e = t.find('"', i + 1)
            if e < 0: break
            result.add t[i + 1 ..< e]
            i = e + 1
          else:
            if t[i] == '(': inc depth
            elif t[i] == ')': depth = max(0, depth - 1)
            inc i
        inReq = t.endsWith(",") or depth > 0
      else:
        inReq = false
        depth = 0
  except CatchableError: discard

proc nxNimbleIn(dir: string): string =
  ## the .nimble file in a folder ("" none)
  try:
    for kind, p in walkDir(dir):
      if kind in {pcFile, pcLinkToFile} and p.endsWith(".nimble"): return p
  except OSError: discard
  ""

proc nxNimbleVersion(dir: string): string =
  ## the `version = "…"` of the package in `dir`
  let nf = nxNimbleIn(dir)
  if nf.len == 0: return
  try:
    for l in lines(nf):
      let t = l.strip
      if t.toLowerAscii.startsWith("version") and '=' in t:
        let q = t.find('"')
        let e = t.find('"', q + 1)
        if q >= 0 and e > q: return t[q + 1 ..< e]
  except CatchableError: discard

proc nxPkgVersions(root: string): Table[string, seq[NxInstalled]] =
  ## the package folders in a pkgs2/pkgs/deps folder, by package (lower case)
  if not dirExists(root): return
  try:
    for kind, d in walkDir(root):
      if kind notin {pcDir, pcLinkToDir}: continue
      let nm = extractFilename(d)
      if nm.len == 0 or nm[0] == '.': continue
      let (pkg, ver) = nxPkgSplit(nm)
      var sum = ""
      if ver.len > 0:
        let k = nm.find("-" & ver & "-", pkg.len)
        if k >= 0: sum = nm[k + ver.len + 2 .. ^1]
      result.mgetOrPut(pkg.toLowerAscii, @[]).add NxInstalled(ver: ver, key: nxVerKey(ver), sum: sum, dir: d)
  except OSError: discard

func nxNewer(a, b: NxInstalled): bool =
  ## is a newer than b? (#head is newest, as the compiler takes it)
  if a.ver.startsWith("#") != b.ver.startsWith("#"): return a.ver.startsWith("#")
  nxVerLess(b.key, a.key)

proc nxSetToolchain*(libDir: string, searchPaths, lazyPaths: seq[string], extraPkgRoots: seq[string] = @[]) =
  nxLibDir = libDir
  nxPkgRoots = lazyPaths & extraPkgRoots
  nxSearchPaths.setLen(0)
  for p in searchPaths:
    if p.len > 0 and dirExists(p) and p notin nxSearchPaths: nxSearchPaths.add p
  for p in [libDir / "std", libDir, libDir / "pure", libDir / "core", libDir / "pure" / "collections",
            libDir / "impure", libDir / "pure" / "concurrency", libDir / "posix", libDir / "system",
            # (and the rest of the compiler's own config: winlean for Windows code, jsffi for js code …)
            libDir / "wrappers", libDir / "windows", libDir / "js", libDir / "deprecated" / "pure",
            libDir / "deprecated" / "core"]:
    if dirExists(p) and p notin nxSearchPaths: nxSearchPaths.add p
  # nimble packages: every installed version; the newest of each is what a file outside a project imports
  nxInstalled.clear()
  for root in lazyPaths & extraPkgRoots:
    for pkg, vs in nxPkgVersions(root):
      for v in vs:
        var dup = false
        for w in nxInstalled.getOrDefault(pkg):
          if w.dir == v.dir: dup = true
        if not dup: nxInstalled.mgetOrPut(pkg, @[]).add v
  nxPkgDirs.setLen(0)
  for _, vs in nxInstalled:
    var best = 0
    for i in 1 ..< vs.len:
      if nxNewer(vs[i], vs[best]): best = i
    nxPkgDirs.add vs[best].dir
  nxProjects.clear()
  nxActive = nil
  nxModCache.clear()
  nxResolveMemo.clear()
  nxScopes.clear()
  inc nxGen
  inc nxScopeEpoch

var nxSysMemo: (string, string)

proc nxSystemPath*(): string =
  ## system.nim of the library in use: lib/system.nim (Nim 2) or lib/std/system.nim (Nimony, Nim 3)
  if nxLibDir.len == 0: return ""
  if nxSysMemo[0] == nxLibDir: return nxSysMemo[1]
  result = if fileExists(nxLibDir / "system.nim"): nxLibDir / "system.nim"
           elif fileExists(nxLibDir / "std" / "system.nim"): nxLibDir / "std" / "system.nim"
           else: ""
  nxSysMemo = (nxLibDir, result)

proc nxInSystem*(path: string, partsOnly = false): bool =
  ## is `path` system.nim or one of its parts (lib/system/…; Nimony: lib/std/system/…)? (partsOnly: only the parts)
  let sys = nxSystemPath()
  if sys.len == 0: return false
  path.startsWith(parentDir(sys) / "system" & "/") or (not partsOnly and path == sys)

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

var nxLibOfDir: Table[string, string]

proc nxLibOf*(dir: string): string =
  ## no standard library known (no `nim` found): the one of the Nim tree a file is in, if it is in one (a folder
  ## above it with system.nim and pure/), else ""
  if dir in nxLibOfDir: return nxLibOfDir[dir]
  var d = dir
  for _ in 0 .. 5:
    if d.len == 0: break
    if fileExists(d / "system.nim") and dirExists(d / "pure"):
      result = d
      break
    let lib = d / "lib"
    if fileExists(lib / "system.nim") and dirExists(lib / "pure"):
      result = lib                   # (compiler/x.nim of a Nim checkout: its lib/ next to it)
      break
    let up = parentDir(d)
    if up == d: break
    d = up
  if nxLibOfDir.len > 2000: nxLibOfDir.clear()
  nxLibOfDir[dir] = result

proc nxPkgDirName*(nm: string, sum: bool): bool =
  ## a package folder's name as nimble makes it: `name-1.2.3` / `name-#head` (pkgs/), and with `sum` the
  ## checksum after it, `name-1.2.3-<sha1: 40 hex digits>` (pkgs2/)
  let (pkg, ver) = nxPkgSplit(nm)
  if pkg.len == 0 or ver.len == 0 or pkg.len + 1 + ver.len > nm.len: return false
  let rest = nm[pkg.len + 1 + ver.len .. ^1]
  if not sum: return rest.len == 0
  rest.len == 41 and rest[0] == '-' and rest[1 .. ^1].allCharsInSet(HexDigits)

var nxAtlasOf: Table[string, (float, bool)]     # project folder → (when looked at, its deps/ is atlas')

proc nxAtlasDeps*(root: string): bool =
  ## does `root/deps` hold the packages atlas installed for the project in `root`: atlas' own files (atlas.config,
  ## atlas.workspace, atlas.lock, deps/atlas.config) or a config putting deps/ on the path (atlas' nim.cfg section:
  ## --path:"deps/x") — and not just a folder of the project's that is called deps (looked at again after 5 s)
  let now = epochTime()
  let m = nxAtlasOf.getOrDefault(root, (-1.0, false))
  if m[0] >= 0 and now - m[0] < 5: return m[1]
  var yes = false
  if dirExists(root / "deps"):
    for f in [root / "atlas.config", root / "atlas.workspace", root / "atlas.lock", root / "deps" / "atlas.config"]:
      if fileExists(f): yes = true
    if not yes:
      for cfg in [root / "nim.cfg", root / "config.nims"]:
        if fileExists(cfg):
          try:
            for l in lines(cfg):
              let t = l.strip
              if not t.startsWith("#") and "path" in t and ("\"deps/" in t or "'deps/" in t or ":deps/" in t or
                                                             "= deps/" in t):
                yes = true
                break
          except CatchableError: discard
        if yes: break
  if nxAtlasOf.len > 2000: nxAtlasOf.clear()
  nxAtlasOf[root] = (now, yes)
  yes

proc nxIsPkgPath*(path: string): bool =
  ## a file or folder of an installed package: under the package folders the toolchain is configured with
  ## (NIMBLE_DIR's pkgs2/pkgs, `nim dump`'s lazy paths, the open project's nimbledeps/ and deps/), or in a folder
  ## laid out as nimble or atlas make them — `…/pkgs2/name-1.2.3-<sha1>/`, `…/.nimble/pkgs/name-1.2.3/`,
  ## `<project>/nimbledeps/pkgs2/name-1.2.3-…/`, `<atlas project>/deps/name/`. A folder of your own that is just
  ## called pkgs2, pkgs, nimbledeps or deps is not one.
  for r in nxPkgRoots:
    if r.len > 1 and (path == r or path.startsWith(r & "/")): return true
  if "/pkgs2/" notin path and "/pkgs/" notin path and "/deps/" notin path: return false
  let parts = path.split('/')
  for i in 0 ..< parts.len - 1:
    let nx = parts[i + 1]
    case parts[i]
    of "pkgs2":
      if nxPkgDirName(nx, sum = true): return true
      if i > 0 and parts[i - 1] == "nimbledeps" and nxPkgSplit(nx)[1].len > 0: return true
    of "pkgs":
      if i > 0 and parts[i - 1] in [".nimble", "nimbledeps"] and nxPkgDirName(nx, sum = false): return true
    of "deps":
      if i > 0 and nx.len > 0 and nx[0] != '.' and nxAtlasDeps(parts[0 ..< i].join("/")): return true
    else: discard
  false

proc nxRootFor*(dir: string): string =
  ## the project folder `dir` is in: the nearest one above with a .nimble ("" none) — a package's own folder
  ## inside pkgs2 too
  if dir in nxRootOf: return nxRootOf[dir]
  var d = dir
  var seen: seq[string]                  # (the folders on the way: theirs is the same answer)
  for _ in 0 .. 10:
    if d.len == 0: break
    if d in nxRootOf:
      result = nxRootOf[d]
      break
    seen.add d
    if nxNimbleIn(d).len > 0:
      result = d
      break
    let up = parentDir(d)
    if up == d: break
    d = up
  if nxRootOf.len > 5000: nxRootOf.clear()
  for s in seen: nxRootOf[s] = result

proc nxLockedDir(name, ver, sum: string, local: Table[string, seq[NxInstalled]]): (string, string) =
  ## the installed folder of a locked package version: (folder, "" | why it is not the locked one)
  var byVer = ""
  for vs in [local.getOrDefault(name.toLowerAscii), nxInstalled.getOrDefault(name.toLowerAscii)]:
    for v in vs:
      if v.ver == ver and sum.len > 0 and v.sum.len > 0 and (v.sum.startsWith(sum) or sum.startsWith(v.sum)):
        return (v.dir, "")
      if v.ver == ver and byVer.len == 0 and (v.sum.len == 0 or sum.len == 0): byVer = v.dir   # (pkgs/: no checksum)
  if byVer.len > 0: return (byVer, "")
  ("", "not installed")

proc nxComputeProject(root: string): NxProject =
  ## which version of each package the project builds with: the paths its config gives (`nim dump`: nimble.paths,
  ## atlas' nim.cfg), then nimble.lock, its nimbledeps/ folder, atlas' deps/, the `requires` of its .nimble (the
  ## newest installed version that meets them, and theirs in turn); any other package: the newest installed
  result = NxProject(root: root)
  var chosen: Table[string, int]              # package (lower case) → index in deps
  let res = result
  proc take(d: NxDep) =
    let k = d.name.toLowerAscii
    if k.len == 0 or k == "nim" or k in chosen: return
    chosen[k] = res.deps.len
    res.deps.add d
  # 1. what its config puts on the path
  let nimblePaths = try: readFile(root / "nimble.paths") except CatchableError: ""
  let nimCfg = try: readFile(root / "nim.cfg") except CatchableError: ""
  for p in nxProjectPaths.getOrDefault(root):
    var (nm, ver) = nxPkgSplit(extractFilename(p))
    if ver.len == 0: ver = nxNimbleVersion(p)
    result.paths.add p
    take NxDep(name: nm, version: ver, dir: p,
               why: (if p in nimblePaths: "nimble.paths" elif p in nimCfg: "nim.cfg" else: "--path"))
  var local: Table[string, seq[NxInstalled]]          # nimbledeps/
  for sub in ["pkgs2", "pkgs"]:
    for k, vs in nxPkgVersions(root / "nimbledeps" / sub): local.mgetOrPut(k, @[]).add vs
  # 2. nimble.lock
  if fileExists(root / "nimble.lock"):
    try:
      let j = parseJson(readFile(root / "nimble.lock"))
      let ps = j{"packages"}
      if ps != nil and ps.kind == JObject:
        for name, v in ps.pairs:
          if v.kind != JObject: continue
          let ver = v{"version"}.getStr
          let sum = v{"checksums"}{"sha1"}.getStr
          let (d, missing) = nxLockedDir(name, ver, sum, local)
          take NxDep(name: name, version: ver, dir: d, why: "nimble.lock" & (if missing.len > 0: ", " & missing else: ""))
    except CatchableError: discard
  # 3. nimbledeps/ (the newest there of each), 4. atlas' deps/
  for k, vs in local:
    var best = 0
    for i in 1 ..< vs.len:
      if nxNewer(vs[i], vs[best]): best = i
    take NxDep(name: nxPkgSplit(extractFilename(vs[best].dir))[0], version: vs[best].ver, dir: vs[best].dir,
               why: "nimbledeps/")
  for k, vs in (if nxAtlasDeps(root): nxPkgVersions(root / "deps") else: initTable[string, seq[NxInstalled]]()):
    for v in vs:
      take NxDep(name: nxPkgSplit(extractFilename(v.dir))[0], version: (if v.ver.len > 0: v.ver else: nxNimbleVersion(v.dir)),
                 dir: v.dir, why: "deps/")
  # 5. `requires`: the newest installed version that meets them — and what those require, in turn
  var queue: seq[(string, string, string)]            # (requirement, required by: "" the project)
  for r in nxNimbleRequires(nxNimbleIn(root)): queue.add (r, "", "")
  var walked: HashSet[string]
  var qi = 0
  while qi < queue.len and qi < 2000:
    let (req, by, _) = queue[qi]
    inc qi
    let (nm, cons) = nxSplitRequire(req)
    let k = nm.toLowerAscii
    if k.len == 0 or k == "nim": continue
    if k notin chosen:
      var best = -1
      let vs = nxInstalled.getOrDefault(k)
      for i, v in vs:
        if nxSatisfies(v.ver, cons) and (best < 0 or nxNewer(v, vs[best])): best = i
      let why = (if by.len > 0: by & " requires" else: "requires") & (if cons.len > 0: " " & cons else: "")
      if best >= 0: take NxDep(name: nxPkgSplit(extractFilename(vs[best].dir))[0], version: vs[best].ver,
                               dir: vs[best].dir, why: why)
      else: take NxDep(name: nm, version: "", dir: "",
                       why: why & (if vs.len > 0: ", no installed version meets it" else: ", not installed"))
    let d = result.deps[chosen.getOrDefault(k, 0)]
    if k in chosen and d.dir.len > 0 and k notin walked:
      walked.incl k
      for r in nxNimbleRequires(nxNimbleIn(d.dir)): queue.add (r, d.name, "")
  for d in result.deps:
    if d.dir.len > 0 and d.dir notin result.dirs: result.dirs.add d.dir
  # 6. every other package: the newest installed
  for p in nxPkgDirs:
    if nxPkgSplit(extractFilename(p))[0].toLowerAscii notin chosen: result.rest.add p
  result.key = if result.deps.len == 0 and result.paths.len == 0: "" else: $hash(result.dirs.join("\n"))

proc nxProjectStamp(root: string): string =
  result = nxStamp(nxNimbleIn(root)) & "|" & nxStamp(root / "nimble.lock") & "|" & nxStamp(root / "nimble.paths") & "|" &
           $dirExists(root / "nimbledeps") & $dirExists(root / "deps") & "|" & nxStamp(root / "nim.cfg") & "|" &
           $nxGen & "|" &
           $hash(nxProjectPaths.getOrDefault(root).join("\n"))

var nxNoProject = NxProject()        # files outside any nimble package: the newest installed version of each

proc nxProjectAt*(root: string): NxProject =
  ## the project in folder `root` and the versions it builds with (worked out again when its .nimble, nimble.lock
  ## or nimble.paths changed — looked at once in 2 s at most)
  if root.len == 0:
    if nxNoProject.stamp != $nxGen:
      nxNoProject = NxProject(rest: nxPkgDirs, stamp: $nxGen)
    return nxNoProject
  let now = epochTime()
  var p = nxProjects.getOrDefault(root)
  if p != nil and now - p.checked < 2: return p
  let st = nxProjectStamp(root)
  if p != nil and p.stamp == st:
    p.checked = now
    return p
  p = nxComputeProject(root)
  p.stamp = st
  p.checked = now
  nxProjects[root] = p
  p

proc nxProjectWhere(path: string): tuple[root: string, pkg: bool] =
  ## the folder of the project a file belongs to — or pkg: a package's own file, which follows the project asked
  ## about last (what imports it)
  if nxIsPkgPath(path): return ("", true)
  let root = nxRootFor(parentDir(path))
  if root.len > 0 and nxIsPkgPath(root): return ("", true)
  (root, false)

proc nxProjectOf*(path: string): NxProject =
  ## the project a file belongs to; a package's own file follows the project asked about last (what imports it)
  let (root, pkg) = nxProjectWhere(path)
  if pkg: (if nxActive != nil: nxActive else: nxProjectAt("")) else: nxProjectAt(root)

proc nxSetActiveFile*(path: string) =
  ## the file asked about now (a request starts): the package files it reaches follow its project's versions
  if path.len == 0 or nxIsPkgPath(path): return
  nxActive = nxProjectOf(path)

proc nxResolve0(fromPath, spec0: string, proj: NxProject): string

var nxPluginLibDir* = ""
  ## the folder of the library ned's plugins import (nedplugin.nim, nedlsp.nim): set by ned (plugins/host)

proc nxResolve*(fromPath, spec0: string): string =
  ## the file an import refers to, searched like the compiler does: next to the importing module,
  ## then the search paths (stdlib, --path, config), then nimble packages — the versions the project builds with.
  ## (Asked thousands of times when a scope is made: the answer kept by what was asked, while the project it was
  ## for is still the one the file follows — the same as it was worked out, the same one active for a package's
  ## file. Nothing on disk is looked at for that: nxProjectAt looks at the project's files every 2 s when a scope
  ## is asked for)
  nxResolveMemo.withValue((fromPath, spec0), v):
    let now = (if v.pkg and nxActive != nil: nxActive
               elif v.pkg or v.root.len == 0: nxNoProject        # (made again for the same packages: a miss)
               else: nxProjects.getOrDefault(v.root))
    if now != nil and now == v.proj: return v.path
  let (root, pkg) = nxProjectWhere(fromPath)
  let proj = (if pkg: (if nxActive != nil: nxActive else: nxProjectAt("")) else: nxProjectAt(root))
  result = nxResolve0(fromPath, spec0, proj)
  if nxResolveMemo.len > 20000: nxResolveMemo.clear()
  nxResolveMemo[(fromPath, spec0)] = (result, root, pkg, proj)

proc nxResolve0(fromPath, spec0: string, proj: NxProject): string =
  var spec = spec0.strip(chars = {'"', ' '})
  if spec.len == 0: return ""
  if spec[0] == '$':
    # the compiler's path variables: import "$nim"/compiler/ast, "$lib"/pure/os, "$home"/…
    spec = spec.replace("\"", "")
    let slash = spec.find('/')
    let v = (if slash > 0: spec[1 ..< slash] else: spec[1 .. ^1]).toLowerAscii
    let rest = if slash > 0: spec[slash + 1 .. ^1] else: ""
    let base = case v
               of "nim": (if nxLibDir.len > 0: parentDir(nxLibDir) else: "")
               of "lib": nxLibDir
               of "home": getHomeDir().strip(leading = false, chars = {'/'})
               else: ""
    if base.len == 0 or rest.len == 0: return ""
    spec = base / rest
  let dir = parentDir(fromPath)
  let key = proj.key & "\t" & dir & "\t" & spec
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
  if not std:
    for p in proj.paths: try1(p / spec)        # (nimble.paths, atlas: before the standard library, as --path is)
  if not pkg:
    for p in nxSearchPaths: try1(p / spec)
  if not std:
    for p in proj.dirs: try1(p / spec)
    for p in proj.rest: try1(p / spec)
    # `import foo` of a package whose module sits in src/ inside the package folder
    let first = spec.split('/')[0].replace(".nim", "").toLowerAscii
    for ps in [proj.dirs, proj.rest]:
      for p in ps:
        if found.len == 0 and nxPkgSplit(extractFilename(p))[0].toLowerAscii == first: try1(p / "src" / spec)
    if found.len == 0:
      let ps = nxPackageSrc(dir)
      if ps.len > 0: try1(ps / spec)
  # a plugin's `import nedplugin` / `import nedlsp`: the library ned gives its plugins (nim e / nim c --path:)
  if found.len == 0 and nxPluginLibDir.len > 0 and spec in ["nedplugin.nim", "nedlsp.nim"]:
    try1(nxPluginLibDir / spec)
  nxModCache[key] = found
  found

func nxModuleName*(spec: string): string =
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
    for i in 0 ..< g.syms.len:
      template s: untyped = g.syms[i]
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
      # a single symbol re-exported from one of the imports (export asyncmacro.async: from that one)
      var only = e
      var fromMod = ""
      let dot = e.rfind('.')
      if dot > 0 and e[0 ..< dot].allCharsInSet(IdentChars):
        fromMod = e[0 ..< dot]
        only = e[dot + 1 .. ^1].strip(chars = {'`', ' '})
      for mname, p in mods:
        if fromMod.len > 0 and mname != fromMod: continue
        let g = nxLoad(p)
        if g == nil: continue
        for i in 0 ..< g.syms.len:
          template s: untyped = g.syms[i]
          if s.exported and s.name == only: res.add NxRef(file: g, idx: int32(i))

var
  nxIncFiles*: Table[string, (string, seq[string])]          # a file → (its stamp, the files it `include`s)
  nxIncDirs*: Table[string, (float, Table[string, string], bool)]  # folder → (when looked, included file →
                                                                   # includer, a package's top: none above it)
  nxScopeBuilding*: HashSet[string]                           # (scopes being built: an include loop stops here)

proc nxIncludesOf*(p: string): seq[string] =
  ## the files `p` pulls in with `include` (read again only when it changed)
  let st = nxCurStamp(p)
  if p in nxIncFiles and nxIncFiles[p][0] == st: return nxIncFiles[p][1]
  var res: seq[string]
  try:
    var any = false
    if nxBufferLines != nil and nxBufferStamp(p).len > 0:
      for l in nxBufferLines(p):
        if l.len > 8 and l.strip.startsWith("include "):
          any = true
          break
    elif getFileSize(p) <= 3_000_000:
      # (a folder's files looked through for `include` when a file of it is opened: no copy of each line made)
      let t = readFile(p)
      var k = t.find("include ")
      while k >= 0 and not any:
        var a = k
        while a > 0 and t[a - 1] in {' ', '\t'}: dec a
        if a == 0 or t[a - 1] == '\n': any = true
        else: k = t.find("include ", k + 8)
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
  var d = parentDir(path)
  # (and up to three folders above: a project's src/app.nim can include src/app/ui/menus.nim — but not above the
  # standard library or a package's top folder, the one with its .nimble: the files there are not its)
  for _ in 0 ..< 4:
    if d notin nxIncDirs or now - nxIncDirs[d][0] > 10:
      var m: Table[string, string]
      var top = d == nxLibDir or d.endsWith("/pkgs2") or d.endsWith("/pkgs")
      try:
        for kind, p in walkDir(d):
          if kind notin {pcFile, pcLinkToFile}: continue
          if p.endsWith(".nimble"): top = true
          elif p.endsWith(".nim"):
            for inc in nxIncludesOf(p):
              if inc notin m: m[inc] = p
      except CatchableError: discard
      nxIncDirs[d] = (now, m, top)
    let h = nxIncDirs[d][1].getOrDefault(path)
    if h.len > 0 and h != path: return h
    if nxIncDirs[d][2]: break
    let up = parentDir(d)
    if up.len <= 1 or up == d: break
    d = up
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

proc nxSortByHash*(a: var seq[(uint32, int32)]) =
  ## by hash, stable (entries of one hash in the order they came): two passes of 16 bits — a merge sort with a
  ## comparison proc took a fifth of making a scope
  if a.len < 64:
    a.sort(proc(x, y: (uint32, int32)): int = cmp(x[0], y[0]))
    return
  # (three passes of 11 bits: 2048 counters to clear each time, not 65536 — a scope of 6600 names spent more on
  # clearing the counters than on sorting)
  var tmp = newSeq[(uint32, int32)](a.len)
  var count: array[2049, int]
  for shift in [0'u32, 11'u32, 22'u32]:
    zeroMem(addr count[0], sizeof(count))
    for x in a: inc count[int((x[0] shr shift) and 0x7FF'u32) + 1]
    for k in 1 .. 2048: count[k] += count[k - 1]
    for x in a:
      let k = int((x[0] shr shift) and 0x7FF'u32)
      tmp[count[k]] = x
      inc count[k]
    swap(a, tmp)

proc nxIndexNames(sc: NxScope) =
  ## the scope's names, by hash, sorted (nxLookup)
  sc.byHash.setLen(sc.refs.len)
  for i in 0 ..< sc.refs.len:
    sc.byHash[i] = (nxNameHash(sc.refs[i].file.syms[sc.refs[i].idx].name), int32(i))
  nxSortByHash(sc.byHash)

var
  nxScopeMax* = 48                     # scopes kept: the files asked about most recently (each holds thousands of
                                       # refs; a check of one proc walks a dozen library modules: fewer and an edit
                                       # made them all again) — and no more than a quarter of nim.indexMemory
  nxScopeUsed: Table[string, int]      # path → when its scope was asked for last (nxTick)

proc nxKeepScope(path: string, sc: NxScope) =
  ## remember a scope — and forget the one asked about least recently when there are too many
  inc nxTick
  nxScopeUsed[path] = nxTick
  nxScopes[path] = sc
  var refs = 0
  for _, x in nxScopes: refs += x.refs.len
  while nxScopes.len > nxScopeMax or
        (nxScopes.len > 12 and nxIndexBudget > 0 and refs * (sizeof(NxRef) + 8) > nxIndexBudget div 4):
    var oldest = ""
    var t = high(int)
    for p, _ in nxScopes:
      let u = nxScopeUsed.getOrDefault(p, 0)
      if p != path and u < t:
        t = u
        oldest = p
    if oldest.len == 0: break
    refs -= nxScopes[oldest].refs.len
    nxScopes.del oldest
    nxScopeUsed.del oldest

proc nxForgetScopesOf*(path: string) =
  ## the names of `path` changed without its text changing (what its macro calls make): the scopes that see it go
  inc nxScopeEpoch
  var dead: seq[string]
  for k, sc in nxScopes:
    var hit = sc.own != nil and sc.own.path == path
    if not hit:
      for (p, _) in sc.deps:
        if p == path:
          hit = true
          break
    if not hit:
      for _, p in sc.modules:              # (a module it imports that had nothing it could see, until now)
        if p == path:
          hit = true
          break
    if hit: dead.add k
  for k in dead:
    nxScopes.del k
    nxScopeUsed.del k

func skey(f: NxFile): string {.inline.} =
  ## the key a file's scope is kept under (its path; the file as a left-out `when` branch sees it: its own)
  if f.scopeKey.len > 0: f.scopeKey else: f.path

var nxFocusPath* = ""     # the file being edited (the one in front): its scope is its own, whatever it is part of

proc nxScopeCached*(f: NxFile): bool =
  ## is the scope of `f` made already? (what can wait for a quiet moment asks before it would make one)
  if f == nil: return false
  let s = nxScopes.getOrDefault(f.skey)
  s != nil and (s.own == f or f.path != nxFocusPath)

proc nxPatchScope(old: NxScope, path: string, g: NxFile): NxScope =
  ## the scope with one of the files the module includes in its new version (`g`): that file's names taken out and
  ## the new ones put in their place, the rest kept — no gathering and sorting a hundred thousand names again for a
  ## keystroke in one include file of a big program (ned's own source has 290). nil when the file's names are not
  ## one block of names the module took all of
  var a, e = -1
  for i, r in old.refs:
    if r.file.path == path:
      if e >= 0 or r.origin != 1: return nil        # (a second block, or names it took only some of)
      if a < 0: a = i
    elif a >= 0 and e < 0: e = i
  if a < 0: return nil
  if e < 0: e = old.refs.len
  let n = g.syms.len
  let delta = n - (e - a)
  result = NxScope(stamp: old.stamp, ikey: old.ikey, own: old.own, modules: old.modules, deps: old.deps)
  if nxSameTypes(old.refs[a].file, g): result.memo = old.memo     # (an edit in a routine's body: types as they were)
  result.refs = newSeqOfCap[NxRef](old.refs.len + delta)
  for i in 0 ..< a: result.refs.add old.refs[i]
  for i in 0 ..< n: result.refs.add NxRef(file: g, idx: int32(i), origin: 1)
  for i in e ..< old.refs.len: result.refs.add old.refs[i]
  var fresh = newSeq[(uint32, int32)](n)
  for i in 0 ..< n: fresh[i] = (nxNameHash(g.syms[i].name), int32(a + i))
  fresh.sort(proc(x, y: (uint32, int32)): int = cmp(x[0], y[0]))
  result.byHash = newSeqOfCap[(uint32, int32)](old.byHash.len + delta)
  var k = 0
  for (h, ix) in old.byHash:
    if ix >= int32(a) and ix < int32(e): continue
    while k < n and fresh[k][0] < h:
      result.byHash.add fresh[k]
      inc k
    result.byHash.add (h, (if ix >= int32(e): ix + int32(delta) else: ix))
  while k < n:
    result.byHash.add fresh[k]
    inc k
  for d in result.deps.mitems:
    if d[0] == path: d[1] = g.stamp

proc nxSameImports(a, b: NxFile): bool =
  ## do two versions of a file import and include the same (the same way)?
  if a.imports.len != b.imports.len: return false
  for i in 0 ..< a.imports.len:
    let (x, y) = (a.imports[i], b.imports[i])
    if x.spec != y.spec or x.alias != y.alias or x.isInclude != y.isInclude or x.only != y.only or
       x.excepts != y.excepts:
      return false
  true

proc nxSameDecls(a, b: NxFile): bool =
  ## two versions of a file that declare the same, in the same order (an edit inside a routine's body, a comment):
  ## what the files importing it see of it is the same
  if a == b: return true
  if a == nil or b == nil or a.syms.len != b.syms.len or a.exports != b.exports or not nxSameImports(a, b): return false
  for i in 0 ..< a.syms.len:
    let (x, y) = (a.syms[i].addr, b.syms[i].addr)
    if x.name != y.name or x.kind != y.kind or x.exported != y.exported or x.generics != y.generics or
       x.params != y.params or x.ret != y.ret or x.typ != y.typ or x.value != y.value or x.pragmas != y.pragmas or
       x.owner != y.owner or x.made != y.made or x.local != y.local:
      return false
  true

proc nxRepointScope(old: NxScope, path: string, g: NxFile): NxScope =
  ## the scope with a module it imports in a new version that declares the same as the last (an edit inside a
  ## body): its names pointed at the new version, nothing gathered or sorted again — nil when the declarations
  ## changed. (Every module importing one that was edited made its whole scope again: in a big program, a hundred
  ## thousand names for each of them)
  var was: NxFile = nil
  for r in old.refs:
    if r.file.path == path:
      was = r.file
      break
  if was == nil or was == g or not nxSameDecls(was, g): return nil
  result = NxScope(stamp: old.stamp, ikey: old.ikey, own: old.own, modules: old.modules, deps: old.deps,
                   byHash: old.byHash, refs: old.refs, memo: old.memo)
  for r in result.refs.mitems:
    if r.file == was: r.file = g
  for d in result.deps.mitems:
    if d[0] == path: d[1] = g.stamp

proc nxIncludedScope*(f, host: NxFile): NxScope =
  ## what a file that another one includes can see: everything its includer sees (the includer's own
  ## declarations, its imports, its other include files), with this file's current declarations
  if f.path == nxFocusPath and nxFiles.getOrDefault(f.path) == f:
    # the file being edited, a keystroke later: its scope before, with this version's names in place of the last
    # one's — the includer's scope is left as it was (patching it, then copying it for this file, was two copies of
    # a hundred thousand names at every key in a big program)
    # (a file of its own imports too — ned.nim, that nedls.nim includes: its names are the first block, the
    # includer's follow without it)
    let old = nxScopes.getOrDefault(f.skey)
    if old != nil and old.own != nil and old.own.path == f.path and old.stamp.startsWith("inc|") and
       nxSameImports(old.own, f):
      var stale = ""
      var many = false
      for (p, ps) in old.deps:
        if nxCurStamp(p) != ps:
          if stale.len > 0:
            many = true
            break
          stale = p
      if stale.len == 0 and old.own == f:
        inc nxTick
        nxScopeUsed[f.skey] = nxTick
        return old
      if not many and (stale == f.path or stale.len == 0):
        let pt = nxPatchScope(old, f.path, f)
        if pt != nil:
          pt.own = f
          pt.stamp = "inc|" & f.stamp & "|patched"
          nxKeepScope(f.skey, pt)
          return pt
  let hs = nxScope(host)
  if f.path != nxFocusPath:
    # an include file that is not the one being edited, that imports nothing of its own and is the very file the
    # includer's scope was made with: it sees just what the includer sees — that scope itself. (A program of many
    # include files — ned's own source: 290 — made one scope per file it walked into, each a copy of the
    # includer's hundred thousand names, more than the index keeps: they were made again and again)
    var plain = true
    for im in f.imports:
      if not im.isInclude:
        plain = false
        break
    if plain and nxFiles.getOrDefault(f.path) == f:
      for (p, ps) in hs.deps:
        if p == f.path and ps == f.stamp: return hs
  block shared:
    # the file being edited, when the includer's scope holds this very version of it and it imports nothing of its
    # own: the includer's names as they are, this file as the scope's own — a copy, nothing gathered or sorted again
    for im in f.imports:
      if not im.isInclude: break shared
    if nxFiles.getOrDefault(f.path) != f: break shared
    var holds = false
    for (p, ps) in hs.deps:
      if p == f.path and ps == f.stamp:
        holds = true
        break
    if not holds: break shared
    let st = "inc|" & f.stamp & "|" & host.path & "|" & hs.stamp & "/" & $nxGen & "|" & $hs.refs.len & "|" &
             $cast[int](hs)
    let old = nxScopes.getOrDefault(f.skey)
    if old != nil and old.stamp == st and old.own == f:
      inc nxTick
      nxScopeUsed[f.skey] = nxTick
      return old
    result = NxScope(stamp: st, own: f, modules: hs.modules, refs: hs.refs, byHash: hs.byHash, deps: hs.deps,
                     memo: hs.tm)
    result.deps.add (host.path, host.stamp)
    nxKeepScope(f.skey, result)
    return
  let st = "inc|" & f.stamp & "|" & host.path & "|" & hs.stamp & "/" & $nxGen
  var old = nxScopes.getOrDefault(f.skey)
  if old != nil and old.stamp == st and old.own == f:
    var stale = ""
    var many = false
    for (p, ps) in old.deps:
      if nxCurStamp(p) != ps:
        if stale.len > 0:
          many = true
          break
        stale = p
    if stale.len == 0:
      inc nxTick
      nxScopeUsed[f.skey] = nxTick
      return old
    if not many and stale != host.path:
      # (one file of the program edited — ned.nim's scope when ui/editorview.nim, that it includes, changed: its
      # new names in place of the old, not every import gathered again)
      let g = nxLoad(stale)
      let patched = if g != nil: nxPatchScope(old, stale, g) else: nil
      if patched != nil:
        nxKeepScope(f.skey, patched)
        return patched
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
  var lastF: NxFile = nil                    # (a file's names come together: its path hashed once, not per name)
  for r in result.refs:
    if r.file == lastF: continue
    lastF = r.file
    if r.file != f and r.file.path notin seenP:
      seenP.incl r.file.path
      result.deps.add (r.file.path, r.file.stamp)
  if host.path notin seenP: result.deps.add (host.path, host.stamp)
  nxKeepScope(f.skey, result)

proc nxScopeImports(f: NxFile): string =
  ## what a module's scope depends on besides its own text and the files it reads: its imports, the package
  ## versions it is read with (a new toolchain forgets every scope; new names a macro makes, those that see them)
  result = nxProjectOf(f.path).key
  for im in f.imports:
    result.add "|" & im.spec & ":" & im.alias & ":" & im.only.join(",") & ":" & im.excepts.join(",") &
               (if im.isInclude: ":i" else: "")

proc nxScopeStamp(f: NxFile): string =
  ## what a module's scope depends on besides the files it reads: its text, the toolchain, its imports
  f.stamp & "/" & nxScopeImports(f)

proc nxScope*(f: NxFile): NxScope =
  ## what `f` can see: its own declarations, system, and its imports (a file another one `include`s: what that
  ## one sees)
  if f == nil: return NxScope()
  inc nxBuildDepth                     # (no parsed file is dropped while a scope is made: it would hold the old one)
  defer: nxBuildDone(f.path)
  if nxLibDir.len == 0 and f.path.len > 0:
    # no standard library known (no `nim` found) and a file of a Nim tree: that tree's
    let lib = nxLibOf(parentDir(f.path))
    if lib.len > 0:
      let (sp, roots) = (nxSearchPaths, nxPkgRoots)     # (copies: the call starts both afresh)
      nxSetToolchain(lib, sp, @[], roots)
  if nxActive == nil and f.path.len > 0 and not nxIsPkgPath(f.path): nxActive = nxProjectOf(f.path)
  if f.path notin nxScopeBuilding:
    let hp = nxIncluderOf(f.path)
    if hp.len > 0:
      let hf = nxLoad(hp)
      if hf != nil and hf != f:
        nxScopeBuilding.incl f.path
        try: result = nxIncludedScope(f, hf)
        finally: nxScopeBuilding.excl f.path
        return
  let ikey = nxScopeImports(f)
  let stamp = f.stamp & "/" & ikey
  var old = nxScopes.getOrDefault(f.skey)
  if old != nil:
    # another file it sees was edited (or saved): start over — or, when that is one file the module includes and
    # nothing else changed, put that file's new names in (an edit in one include file of a big program)
    var stale = ""
    var many = false
    for (p, st) in old.deps:
      if nxCurStamp(p) != st:
        if stale.len > 0:
          many = true
          break
        stale = p
    if stale.len > 0:
      var patched: NxScope = nil
      if not many and old.stamp == stamp and old.own == f and old.ikey == ikey:
        let g = nxLoad(stale)
        if g != nil: patched = nxPatchScope(old, stale, g)
        if patched == nil and g != nil: patched = nxRepointScope(old, stale, g)
      if patched != nil:
        nxKeepScope(f.skey, patched)
        inc nxTick
        return patched
      old = nil
  if old != nil and old.stamp == stamp and old.own == f:
    inc nxTick
    nxScopeUsed[f.skey] = nxTick
    return old
  if old != nil and old.ikey == ikey and old.own != nil and old.own.path == f.path:
    # own symbols change with every edit; imports rarely do: what the imports bring is kept (system's and the
    # imports' thousands of names: an edit no longer gathers them all again) — this file's names put in place of
    # the last version's, the rest's index kept (sorting a hundred thousand names again took 16 ms a key in ned.nim)
    let pt = nxPatchScope(old, f.path, f)
    if pt != nil:
      pt.stamp = stamp
      pt.own = f
      nxKeepScope(f.skey, pt)
      return pt
    var sc = NxScope(refs: newSeqOfCap[NxRef](old.refs.len + 16), stamp: stamp, ikey: ikey, modules: old.modules,
                     own: f, deps: old.deps, memo: (if nxSameTypes(old.own, f): old.memo else: nil))
    for i in 0 ..< f.syms.len: sc.refs.add NxRef(file: f, idx: int32(i), origin: 1)
    for r in old.refs:
      if r.file != old.own and r.file != f and r.file.path != f.path: sc.refs.add r
    nxIndexNames(sc)
    nxKeepScope(f.skey, sc)
    return sc
  result = NxScope(stamp: stamp, ikey: ikey, own: f)
  for i in 0 ..< f.syms.len: result.refs.add NxRef(file: f, idx: int32(i), origin: 1)
  for g in nxIncluded(f):
    for i in 0 ..< g.syms.len: result.refs.add NxRef(file: g, idx: int32(i), origin: 1)
  var seen: HashSet[string]
  seen.incl f.path
  let sys = nxSystemPath()
  if sys.len > 0 and f.path != sys and not f.path.startsWith(parentDir(sys) / "system" & "/"):
    let before = result.refs.len
    nxExports(sys, 0, seen, result.refs)
    # system's NimScript part (exec, thisDir, switch …): a NimScript file's only — and a .nimble sees nimble's own
    # versions of some, its other API and strutils, as nimble's wrapper gives them (nxNimbleApiPath)
    let script = nxIsScript(f.path)
    let nimble = nxIsNimbleFile(f.path)
    var w = before
    for k in before ..< result.refs.len:
      let r = result.refs[k]
      if nxFromNimscriptApi(r.file.path) and
         (not script or (nimble and r.file.syms[r.idx].name in NxNimbleOverrides)): continue
      result.refs[w] = r
      result.refs[w].origin = 3
      inc w
    result.refs.setLen(w)
    if nimble:
      for p in [nxNimbleApiPath(), nxResolve(f.path, "std/strutils")]:
        if p.len == 0: continue
        var got: seq[NxRef]
        nxExports(p, 0, seen, got)
        for r in got:
          var r2 = r
          r2.origin = 3
          result.refs.add r2
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
  var lastF: NxFile = nil                    # (a file's names come together: its path hashed once, not per name)
  for r in result.refs:
    if r.file == lastF: continue
    lastF = r.file
    if r.file != f and r.file.path notin seenP:
      seenP.incl r.file.path
      result.deps.add (r.file.path, r.file.stamp)
  nxKeepScope(f.skey, result)

var nxStyleFree: Table[string, (string, bool)]   # path → (stamp, it has {.feature: "ignoreStyle".})

proc nxIgnoresStyle*(f: NxFile): bool =
  ## does this Nim 3 module ask for Nim 2's style-insensitive names?
  if f == nil or f.path.len == 0: return false
  let k = nxStyleFree.getOrDefault(f.path, ("", false))
  if k[0].len > 0 and k[0] == f.stamp: return k[1]
  var text = ""
  if nxBufferLines != nil and nxBufferStamp != nil and nxBufferStamp(f.path).len > 0:
    text = nxBufferLines(f.path).join("\n")
  else:
    try: text = readFile(f.path)
    except CatchableError: discard
  result = "\"ignoreStyle\"" in text and "feature" in text
  nxStyleFree[f.path] = (f.stamp, result)

proc nxLookup*(sc: NxScope, name: string): seq[NxRef] =
  let n = nxNorm(name)
  let h = nxNameHash(name)
  var lo = 0
  var hi = sc.byHash.len
  while lo < hi:                               # the first entry with this hash
    let mid = (lo + hi) div 2
    if sc.byHash[mid][0] < h: lo = mid + 1 else: hi = mid
  while lo < sc.byHash.len and sc.byHash[lo][0] == h:
    let r = sc.refs[sc.byHash[lo][1]]
    if nxNorm(r.file.syms[r.idx].name) == n: result.add r
    inc lo
  if result.len == 0 and nxExact and sc.own != nil and nxIgnoresStyle(sc.own):
    # (Nim 3: a module with {.feature: "ignoreStyle".} finds names by Nim 2's rule)
    let n2 = nxNorm2(name)
    for r in sc.refs:
      if nxNorm2(r.file.syms[r.idx].name) == n2: result.add r

func sym*(r: NxRef): lent NxSym {.inline.} = r.file.syms[r.idx]     # (lent: `r.sym.kind` copies nothing)

var
  nxOverlays: seq[(string, NxFile)]       # (file and branch, the file as that branch sees it), the latest last
  nxFullParse: (string, NxFile)           # (path and stamp, the file read with its left-out branches)

proc nxAt*(f: NxFile, lines: openArray[string], line: int): NxFile =
  ## the file as code at `line` sees it: when the line is inside a `when` branch left out on this platform (Windows
  ## code, `when defined(js)`, `when false`), the branch's own declarations and imports come first — the types it
  ## declares are not those of the branch taken here — then the file's, then those of the other left-out branches
  if f == nil or f.inactive.len == 0 or lines.len == 0 or f.scopeKey.len > 0: return f   # (an overlay already)
  inc nxBuildDepth
  defer: nxBuildDone(f.path)
  var inside = false
  for (a, b) in f.inactive:
    if a <= line and line <= b:
      inside = true
      break
  if not inside: return f
  let fkey = f.path & "\t" & f.stamp
  if nxFullParse[0] != fkey: nxFullParse = (fkey, nxParse(lines, f.path, keepInactive = true))
  let full = nxFullParse[1]
  # the innermost left-out branch around the line: its conditions
  var lo, hi = -1'i32
  var chain = -1'i32
  for k, (a, b) in full.inactive:
    if a <= line and line <= b and (lo < 0 or b - a < hi - lo):
      lo = a
      hi = b
      chain = if k < full.inactiveChain.len: full.inactiveChain[k] else: -1
  if chain < 0: return f
  let cs = full.chains[chain]
  let key = fkey & "\t" & cs
  for i in countdown(nxOverlays.high, 0):
    if nxOverlays[i][0] == key:
      result = nxOverlays[i][1]
      if i < nxOverlays.high:                       # (the latest last: the oldest go first)
        let e = nxOverlays[i]
        nxOverlays.delete(i)
        nxOverlays.add e
      return
  let g = NxFile(path: f.path, module: f.module, stamp: f.stamp & "#" & $chain, doc: f.doc, imports: full.imports,
                 exports: full.exports, pragmas: full.pragmas, scopeKey: f.path & "#when" & $chain,
                 inactive: f.inactive)
  # the declarations of branches with these conditions first (any `when defined(windows)` of the file for Windows
  # code), then those of the branches around them, then the file's, then the rest
  var mine, around, others: seq[NxSym]
  for k in 0 ..< full.syms.len:
    template s: untyped = full.syms[k]
    let b = if k < full.symBranch.len: full.symBranch[k] else: -1'i32
    if b < 0: g.syms.add s
    elif b == chain: mine.add s
    elif cs.startsWith(full.chains[b] & "\x01"): around.add s
    else: others.add s
  g.syms = mine & around & g.syms & others
  if nxIncluderOf(f.path).len == 0:
    # its scope: the file's own one with these declarations in place of its, and what the left-out branches import
    # (made from the file's scope rather than read again from all the imports: a branch is entered in a few ms)
    let base = nxScope(f)
    let sc = NxScope(stamp: nxScopeStamp(g), ikey: "-", own: g, modules: base.modules, deps: base.deps)
    for i in 0 ..< g.syms.len: sc.refs.add NxRef(file: g, idx: int32(i), origin: 1)
    for r in base.refs:
      if r.file.path != f.path: sc.refs.add r
    var have: HashSet[string]
    for im in f.imports: have.incl im.spec
    var seen: HashSet[string]
    seen.incl f.path
    for im in g.imports:
      if im.isInclude or im.spec in have: continue
      let p = nxResolve(f.path, im.spec)
      if p.len == 0: continue
      sc.modules[nxModuleName(if im.alias.len > 0: im.alias else: im.spec)] = p
      var got: seq[NxRef]
      nxExports(p, 0, seen, got)
      for r in got:
        var r2 = r
        r2.origin = 2
        sc.refs.add r2
        if r.file.path notin have:
          have.incl r.file.path
          sc.deps.add (r.file.path, r.file.stamp)
    nxIndexNames(sc)
    nxKeepScope(g.skey, sc)
  if nxOverlays.len >= 16: nxOverlays.delete(0)
  nxOverlays.add (key, g)
  g

proc nxTrimIndex*(keep = "") =
  ## over nim.indexMemory: drop the parsed files needed least recently — never one open in a buffer, nor `keep` —
  ## down to three quarters of the budget, with the scopes and `when` overlays made from them (a file comes back
  ## when next asked for: a library file from the disk cache in a few ms)
  if nxIndexBudget <= 0: return
  var total = 0                         # (the sum again: a file may have been dropped elsewhere)
  var stale: seq[string]
  for p, b in nxFileBytes:
    if p in nxFiles: total += b
    else: stale.add p
  for p in stale:
    nxFileBytes.del p
    nxFileUsed.del p
  nxFilesBytes = total
  if total <= nxIndexBudget: return
  # when each file was needed last: asked for itself, or read by a scope asked for
  var used = nxFileUsed
  for k, sc in nxScopes:
    let t = nxScopeUsed.getOrDefault(k, 0)
    for (p, _) in sc.deps:
      if used.getOrDefault(p, 0) < t: used[p] = t
    if sc.own != nil and used.getOrDefault(sc.own.path, 0) < t: used[sc.own.path] = t
  var cands: seq[(int, string)]
  for p, _ in nxFiles:
    if p == keep or (nxBufferStamp != nil and nxBufferStamp(p).len > 0): continue
    cands.add (used.getOrDefault(p, 0), p)
  cands.sort(proc(a, b: (int, string)): int = cmp(a[0], b[0]))
  let goal = nxIndexBudget div 4 * 3
  var gone: HashSet[string]
  for (_, p) in cands:
    if nxFilesBytes <= goal: break
    gone.incl p
    nxFiles.del p
    nxFilesBytes -= nxFileBytes.getOrDefault(p)
    nxFileBytes.del p
    nxFileUsed.del p
    inc nxDropped
  if gone.len == 0: return
  # the scopes that read a dropped file: they would keep it alive, and answer with it
  var dead: seq[string]
  for k, sc in nxScopes:
    var hit = sc.own != nil and sc.own.path in gone
    if not hit:
      for (p, _) in sc.deps:
        if p in gone:
          hit = true
          break
    if hit: dead.add k
  for k in dead:
    nxScopes.del k
    nxScopeUsed.del k
  var keepO: seq[(string, NxFile)]
  for o in nxOverlays:
    if o[1].path notin gone: keepO.add o
  nxOverlays = keepO
  if nxFullParse[1] != nil and nxFullParse[1].path in gone: nxFullParse = ("", nil)
