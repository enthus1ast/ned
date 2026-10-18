# ── the index on disk: a library or package file parsed once, not again in every session. One small file per
#    source file in ~/.cache/ned/index, used only when it was made from the same text (its hash and length), by the
#    same parser (a hash of its source and of the declaration layout) with the same defines (what `when` decided):
#    anything else is parsed afresh and written again ──

var
  nxDiskCache* = true                   # nim.indexCache
  nxDiskCacheDir* = ""                  # (tests: another folder)
  nxDiskCacheTidied* = false            # (old entries removed once a session)

proc nxLayoutOf[T](x: T): string =
  for n, v in fieldPairs(x): result.add n & ":" & $typeof(v) & ";"

const NxCacheParser = block:
  # what a cached file depends on besides its text: the parser's own code, and what it fills in
  var s = staticRead(currentSourcePath().parentDir / "lex.nim") & staticRead(currentSourcePath().parentDir / "text.nim") &
          staticRead(currentSourcePath().parentDir / "parse.nim")
  var f: typeof(NxFile()[])
  s.add nxLayoutOf(f) & nxLayoutOf(NxSym()) & nxLayoutOf(NxParam()) & nxLayoutOf(NxImport())
  $hash(s)

const NxCacheMagic = "NEDX1"

proc nxCacheDir(): string =
  if nxDiskCacheDir.len > 0: return nxDiskCacheDir
  getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / "ned" / "index"

proc nxDefinesKey(): string =
  var ds: seq[string]
  for d in nxDefines: ds.add d
  ds.sort()
  ds.join(",") & (if nxDefinesComplete: "|complete" else: "|guessed")

proc nxCacheable*(path: string): bool =
  ## a library or package file (the project's own files change too often to be worth it)
  if not nxDiskCache or path.len == 0: return false
  if nxLibDir.len > 0 and path.startsWith(nxLibDir & "/"): return true
  for d in nxPkgDirs:
    if path.startsWith(d & "/"): return true
  "/pkgs2/" in path or "/pkgs/" in path

# (integers as zigzag varints, strings and lists with their length first)
func nxPut(s: var string, x: int64) =
  var u = (cast[uint64](x) shl 1) xor (if x < 0: not 0'u64 else: 0'u64)
  while u >= 0x80'u64:
    s.add char((u and 0x7f) or 0x80)
    u = u shr 7
  s.add char(u)
func nxPut(s: var string, x: bool) = s.add char(ord(x))
proc nxPut[T: int | int8 | int16 | int32](s: var string, x: T) = nxPut(s, int64(x))
proc nxPut[T: enum](s: var string, x: T) = nxPut(s, int64(ord(x)))
func nxPut(s: var string, x: string) =
  nxPut(s, int64(x.len))
  s.add x
proc nxPut[T](s: var string, x: seq[T])
proc nxPut[T: tuple | object](s: var string, x: T) =
  for v in fields(x): nxPut(s, v)
proc nxPut[T](s: var string, x: seq[T]) =
  nxPut(s, int64(x.len))
  for v in x: nxPut(s, v)

type NxReader = object
  s: string
  p: int

func nxNeed(r: var NxReader, n: int64) =
  if n < 0 or n > int64(r.s.len - r.p): raise newException(ValueError, "index cache: cut short")

func nxGet(r: var NxReader, x: var int64) =
  var u = 0'u64
  var sh = 0
  while true:
    r.nxNeed(1)
    let c = uint64(ord(r.s[r.p]))
    inc r.p
    if sh > 63: raise newException(ValueError, "index cache: bad number")
    u = u or ((c and 0x7f) shl sh)
    if c < 0x80: break
    sh += 7
  x = cast[int64](u shr 1) xor -cast[int64](u and 1)
func nxGet(r: var NxReader, x: var bool) =
  r.nxNeed(1)
  x = r.s[r.p] != '\0'
  inc r.p
proc nxGet[T: int | int8 | int16 | int32](r: var NxReader, x: var T) =
  var v: int64
  nxGet(r, v)
  if v < int64(low(T)) or v > int64(high(T)): raise newException(ValueError, "index cache: number out of range")
  x = T(v)
proc nxGet[T: enum](r: var NxReader, x: var T) =
  var v: int64
  nxGet(r, v)
  if v < int64(ord(low(T))) or v > int64(ord(high(T))): raise newException(ValueError, "index cache: bad kind")
  x = T(v)
func nxGet(r: var NxReader, x: var string) =
  var n: int64
  nxGet(r, n)
  r.nxNeed(n)
  x = r.s[r.p ..< r.p + int(n)]
  r.p += int(n)
proc nxGet[T](r: var NxReader, x: var seq[T])
proc nxGet[T: tuple | object](r: var NxReader, x: var T) =
  for v in fields(x): nxGet(r, v)
proc nxGet[T](r: var NxReader, x: var seq[T]) =
  var n: int64
  nxGet(r, n)
  r.nxNeed(n)                      # (every element takes a byte at least)
  x.setLen(int(n))
  for i in 0 ..< x.len: nxGet(r, x[i])

proc nxCacheBytes*(f: NxFile): string =
  ## a parsed file as the cache keeps it (without the header)
  for n, v in fieldPairs(f[]):
    when v is Table or v is HashSet: discard
    else: nxPut(result, v)

proc nxCacheFile(path: string): string =
  nxCacheDir() / toHex(cast[uint64](hash(path & "\0" & nxDefinesKey()))) & ".nx"

proc nxCacheHeader(path, text: string): string =
  NxCacheMagic & "\n" & NxCacheParser & "\n" & nxDefinesKey() & "\n" & $text.len & ":" & $hash(text) & "\n" & path & "\n"

proc nxCacheRead*(path, text: string): NxFile =
  ## the file as parsed before, when the cache has it for this very text (nil: parse it)
  if not nxCacheable(path): return nil
  try:
    let s = readFile(nxCacheFile(path))
    let h = nxCacheHeader(path, text)
    if not s.startsWith(h): return nil
    # (then the body's length and hash: a file cut short or changed on disk is not read)
    let nl = s.find('\n', h.len)
    if nl < 0 or s[h.len ..< nl] != $(s.len - nl - 1) & ":" & $hash(s.toOpenArray(nl + 1, s.high)): return nil
    var r = NxReader(s: s, p: nl + 1)
    var f = NxFile()
    for n, v in fieldPairs(f[]):
      when v is Table or v is HashSet: discard
      else: nxGet(r, v)
    if r.p != r.s.len or f.path != path: return nil
    f
  except CatchableError: nil

proc nxCacheTidy(dir: string) =
  ## at most 4000 entries: the oldest go (a Nim or package version no longer used)
  nxDiskCacheTidied = true
  var es: seq[(times.Time, string)]
  try:
    for k, p in walkDir(dir):
      if k == pcFile and p.endsWith(".nx"): es.add (getLastModificationTime(p), p)
  except OSError: return
  if es.len <= 4000: return
  es.sort(proc(a, b: (times.Time, string)): int = cmp(a[0], b[0]))
  for i in 0 ..< es.len - 3000:
    try: removeFile(es[i][1])
    except OSError: discard

proc nxCacheWrite*(path, text: string, f: NxFile) =
  ## keep a freshly parsed library file for the next session (written whole or not at all)
  if not nxCacheable(path) or f == nil: return
  try:
    let dir = nxCacheDir()
    if not dirExists(dir):
      createDir(dir)
      discard chmod(dir.cstring, 0o700)
    if not nxDiskCacheTidied: nxCacheTidy(dir)
    let body = nxCacheBytes(f)
    let s = nxCacheHeader(path, text) & $body.len & ":" & $hash(body.toOpenArray(0, body.high)) & "\n" & body
    let dest = nxCacheFile(path)
    let tmp = dest & "." & $getCurrentProcessId() & ".tmp"
    writeFile(tmp, s)
    moveFile(tmp, dest)
  except CatchableError: discard

proc nxParseDisk*(path: string): NxFile =
  ## a file on disk parsed (from the cache when it has this text)
  let text = readFile(path)
  result = nxCacheRead(path, text)
  if result != nil: return
  result = nxParse(text.splitLines, path)
  nxCacheWrite(path, text, result)
