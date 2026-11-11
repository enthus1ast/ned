# ════════════════════════════════════════════════════════════════════════════
#  Small utilities: positions and ranges, time since, relative paths, fuzzy matching
# ════════════════════════════════════════════════════════════════════════════

const ExeDot = when defined(windows): ".exe" else: ""   # (a program ned builds: `nim c -o:` takes the name as it is)

# text positions order by line, then by column
func `<`(a, b: Pos): bool {.inline.} = a.line < b.line or (a.line == b.line and a.col < b.col)
# the other half of the position ordering — true when the two are equal too
func `<=`(a, b: Pos): bool {.inline.} = not (b < a)
# the earlier of two positions
func minP(a, b: Pos): Pos {.inline.} = (if a < b: a else: b)
# the later of two positions
func maxP(a, b: Pos): Pos {.inline.} = (if a < b: b else: a)
# a cursor's selection as (start, end), whichever way it was dragged — anchor and head in order
func range(c: Cursor): (Pos, Pos) {.inline.} = (minP(c.anchor, c.head), maxP(c.anchor, c.head))
# whether the cursor has a selection (its anchor and head are apart)
proc hasSel(c: Cursor): bool {.inline.} = c.anchor != c.head
# a cursor with no selection at `p` and no remembered column for up/down moves (goalX -1)
func cur(p: Pos): Cursor {.inline.} = Cursor(anchor: p, head: p, goalX: -1)

# the milliseconds since a monotonic time stamp — for timeouts and for timing how long something took
proc msSince(t: MonoTime): int64 = (getMonoTime() - t).inMilliseconds

proc firstWord(s: string): string =
  ## the first word of a command (or "" when there is none — a setting left empty)
  let w = s.splitWhitespace()
  if w.len > 0: w[0] else: ""

proc wsLabel(p: string): string =
  ## a file of a workspace's other folder: "folder/rel" (for display only)
  for r in wsRoots:
    if p.startsWith(r & "/"): return extractFilename(r) & "/" & p[r.len + 1 .. ^1]
  p

proc relPath(p: string): string =
  ## a path as shown to the person: relative to the project folder when it is inside it, `~/…` when it is under the home
  ## folder, otherwise as it is
  if rootDir.len > 0 and p.startsWith(rootDir & "/"): p[rootDir.len + 1 .. ^1]
  else:
    let home = getHomeDir().strip(leading = false, chars = {'/'})
    if home.len > 0 and p.startsWith(home & "/"): "~" & p[home.len .. ^1] else: p

var fzPrev, fzCurr, fzBon, fzBack: seq[int]

proc fuzzyCore(pat, text: string, hl: var seq[int], wantHl: bool): int =
  ## fzf-style DP scoring; `pat` must be lowercase. low(int) = no match.
  ## Scratch buffers are reused so filtering 100k entries does not allocate.
  if wantHl: hl.setLen(0)
  if pat.len == 0: return 0
  let n = text.len
  let m = pat.len
  if m > n: return low(int)
  var j = 0
  for i in 0..<n:
    if j < m and toLowerAscii(text[i]) == pat[j]: inc j
  if j < m: return low(int)
  const Neg = -1_000_000
  let fileStart = text.rfind('/') + 1
  if fzBon.len < n: fzBon.setLen(n)
  if fzPrev.len < n: fzPrev.setLen(n)
  if fzCurr.len < n: fzCurr.setLen(n)
  if wantHl and fzBack.len < m * n: fzBack.setLen(m * n)
  for i in 0..<n:
    var b = 0
    if i == 0: b = 8
    else:
      let p = text[i-1]
      if p in {'/', '_', '-', '.', ' ', '\\', ':'}: b = 8
      elif p in {'a'..'z'} and text[i] in {'A'..'Z'}: b = 7
    if i == fileStart: b += 6
    fzBon[i] = b
  for i in 0..<n:
    fzPrev[i] = if toLowerAscii(text[i]) == pat[0]: 16 + 2 * fzBon[i] + (if i >= fileStart: 2 else: 0) else: Neg
  for k in 1..<m:
    var best = Neg
    var bestIdx = -1
    let pk = pat[k]
    for i in 0..<n:
      fzCurr[i] = Neg
      if i >= 2 and fzPrev[i-2] > best:
        best = fzPrev[i-2]
        bestIdx = i - 2
      if toLowerAscii(text[i]) == pk:
        var sc = Neg
        var bi = -1
        if i >= 1 and fzPrev[i-1] > Neg:
          sc = fzPrev[i-1] + 26
          bi = i - 1
        if best > Neg and best + 13 + fzBon[i] > sc:
          sc = best + 13 + fzBon[i]
          bi = bestIdx
        if bi >= 0:
          fzCurr[i] = sc
          if wantHl: fzBack[k*n + i] = bi
    swap(fzPrev, fzCurr)
  var bestScore = Neg
  var e = -1
  for i in 0..<n:
    if fzPrev[i] > bestScore:
      bestScore = fzPrev[i]
      e = i
  if e < 0: return low(int)
  if wantHl:
    hl.setLen(m)
    var idx = e
    for k in countdown(m - 1, 0):
      hl[k] = idx
      if k > 0: idx = fzBack[k*n + idx]
  bestScore - n div 3

# fuzzy score of `text` for the lowercase pattern `pat`, with the matched character positions put in `hl` for
# highlighting (low(int) when it does not match)
proc fuzzyMatch(pat, text: string, hl: var seq[int]): int = fuzzyCore(pat, text, hl, true)

proc fuzzyScore(pat, text: string): int =
  ## the same fuzzy score as fuzzyMatch, without the highlight positions — cheaper when only ranking matters
  var dummy: seq[int]
  fuzzyCore(pat, text, dummy, false)

proc fuzzyQuick(pat, text: string): int =
  ## greedy single pass for very large candidate sets
  var j = 0
  var score = 0
  var prev = -2
  let fileStart = text.rfind('/') + 1
  for i in 0 ..< text.len:
    if j < pat.len and toLowerAscii(text[i]) == pat[j]:
      var b = 10
      if i == prev + 1: b += 12
      if i == 0 or text[i-1] in {'/', '_', '-', '.', ' '} or (text[i-1] in {'a'..'z'} and text[i] in {'A'..'Z'}): b += 8
      if i >= fileStart: b += 3
      score += b
      prev = i
      inc j
  if j < pat.len: return low(int)
  score - text.len div 3

proc uriFromPath(p: string): string

proc wsFoldersJson(): JsonNode =
  ## the language servers' workspaceFolders: the project folder and a workspace's other folders
  result = newJArray()
  for d in @[rootDir] & wsRoots: result.add %*{"uri": uriFromPath(d), "name": extractFilename(d)}

proc uriFromPath(p: string): string =
  ## a file path as a `file://` URI for the language servers: every byte but letters, digits and `-_.~/` is %-escaped;
  ## on Windows backslashes become slashes and a drive path gets a leading slash
  result = "file://"
  when defined(windows):
    if p.len >= 2 and p[1] == ':': result.add '/'          # file:///C:/… (the drive's colon as it is)
  for c in (when defined(windows): p.replace('\\', '/') else: p):
    if c == ':' and defined(windows): result.add c
    elif c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~', '/'}: result.add c
    else: result.add '%' & toHex(ord(c), 2)

func pathFromUri(u: string): string =
  ## a `file://` URI back to a file path — the opposite of uriFromPath: %-escapes decoded and, on Windows, the leading
  ## slash before a drive letter dropped and the drive letter made upper case
  var s = u
  if s.startsWith("file://"): s = s[7..^1]
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      try:
        result.add chr(parseHexInt(s[i+1..i+2]))
        i += 3
        continue
      except ValueError: discard
    result.add s[i]
    inc i
  when defined(windows):
    if result.len >= 3 and result[0] == '/' and result[2] == ':': result = result[1 .. ^1]   # (/C:/… → C:/…)
    if result.len >= 2 and result[1] == ':': result[0] = result[0].toUpperAscii                # (c: → C:, as ned writes it)

func textDistance(a, b: string): int =
  ## edit distance in characters — by bytes when either is not valid UTF-8 (std's own would read past its end)
  var okA, okB = true
  for (s, ok) in [(a, addr okA), (b, addr okB)]:
    var i = 0
    while i < s.len:
      let c = ord(s[i])
      let n = if c < 0x80: 1 elif c shr 5 == 6: 2 elif c shr 4 == 14: 3 elif c shr 3 == 30: 4 else: 0
      if n == 0 or i + n > s.len:
        ok[] = false
        break
      for k in 1 ..< n:
        if (ord(s[i + k]) and 0xC0) != 0x80: ok[] = false
      if not ok[]: break
      i += n
  if okA and okB: editDistance(a, b) else: editDistanceAscii(a, b)

# (a completion item's text to filter by and to insert: its label when it has none of its own — the index's
# thousands of items carry one string each)
template compFilter(it: CompItem): string = (if it.filter.len > 0: it.filter else: it.label)
# the text a completion item puts in the buffer: its own insert text, or its label when it has none
template compInsert(it: CompItem): string = (if it.insert.len > 0: it.insert else: it.label)

# ── pipes to the programs ned talks to (language servers, MCP servers, plugins, notebooks, the engine worker,
#    debuggers): what waits to be written, and the lines that came. A big message (a whole file) goes out in many
#    writes and a burst of output holds many lines: neither copies what is left at each step ──

proc pipeWrite(fd: cint, buf: var string, pos: var int): bool =
  ## writes what waits in buf from pos to fd, as much as the pipe takes now (it never blocks); false when the write
  ## failed (the program is gone). pos moves on instead of the rest being copied to the front at each write; once all
  ## is sent the buffer is let go (the room a whole file took goes back), and most of a big one sent, cut down
  result = true
  while pos < buf.len:
    let n = posix.write(fd, addr buf[pos], buf.len - pos)
    if n > 0: pos += n
    elif n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR): break
    else: return false
  if pos >= buf.len:
    buf = ""
    pos = 0
  elif pos > 1_048_576 and pos > buf.len div 2:
    buf = buf[pos .. ^1]
    pos = 0

template eachLine(buf: untyped, line: untyped, body: untyped) =
  ## runs body for each whole line at the start of buf (`line`: without its '\n'), then takes those lines out of buf
  ## in one move — cut one at a time, the rest was copied for each line. When body empties buf (the program ended),
  ## it stops there
  var lineAt = 0
  while true:
    let lineEnd = buf.find('\n', lineAt)
    if lineEnd < 0: break
    let line = buf[lineAt ..< lineEnd]
    lineAt = lineEnd + 1
    body
    if buf.len < lineAt:
      lineAt = 0
      break
  if lineAt > 0 and lineAt <= buf.len: buf = buf[lineAt .. ^1]

func toU16(s: string, col: int): int =
  ## a byte column of a UTF-8 line as the number of UTF-16 code units before it (a character beyond the basic plane
  ## counts two) — the unit servers count in unless they agreed to UTF-8
  var i = 0
  while i < col and i < s.len:
    let (cp, n) = runeAt(s, i)
    result += (if cp >= 0x10000: 2 else: 1)
    i += n

var heapTidyAt: MonoTime         # when the heap last gave memory back (heapTidy)

proc heapTidy(minGapMs = 10_000) =
  ## gives back to the system what the heap holds but no longer uses (ned/sys/heap) when that is more than 4 MB — or
  ## when the sizes are not known here — at most every minGapMs: in quiet moments (the main loop's idle tick, the
  ## engine worker between tasks), after a big file, a search, a session's work
  if msSince(heapTidyAt) < minGapMs: return
  heapTidyAt = getMonoTime()
  let held = heapHeld()
  let used = heapInUse()
  if held < 0 or used < 0 or held - used > 4 * 1048576: discard heapGiveBack()

proc heapMB(): string =
  ## the heap for a report: "N MB in use of M MB", or "not known here"
  let used = heapInUse()
  let held = heapHeld()
  if used < 0 or held < 0: "not known here" else: $(used div 1048576) & " MB in use of " & $(held div 1048576) & " MB"

func gitArgSafe*(s: string): bool =
  ## a URL, folder or revision a project or a link gives that git can take as itself — not as one of its options
  ## (`--upload-pack=…` runs a command: what nimble 0.26.1 closed in its own git calls), nor two lines
  s.len > 0 and s[0] != '-' and '\n' notin s and '\r' notin s and '\0' notin s
