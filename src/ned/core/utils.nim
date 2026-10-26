# ════════════════════════════════════════════════════════════════════════════
#  Small utilities
# ════════════════════════════════════════════════════════════════════════════

const ExeDot = when defined(windows): ".exe" else: ""   # (a program ned builds: `nim c -o:` takes the name as it is)

func `<`(a, b: Pos): bool {.inline.} = a.line < b.line or (a.line == b.line and a.col < b.col)
func `<=`(a, b: Pos): bool {.inline.} = not (b < a)
func minP(a, b: Pos): Pos {.inline.} = (if a < b: a else: b)
func maxP(a, b: Pos): Pos {.inline.} = (if a < b: b else: a)
func range(c: Cursor): (Pos, Pos) {.inline.} = (minP(c.anchor, c.head), maxP(c.anchor, c.head))
proc hasSel(c: Cursor): bool {.inline.} = c.anchor != c.head
func cur(p: Pos): Cursor {.inline.} = Cursor(anchor: p, head: p, goalX: -1)

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

proc fuzzyMatch(pat, text: string, hl: var seq[int]): int = fuzzyCore(pat, text, hl, true)

proc fuzzyScore(pat, text: string): int =
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
  result = "file://"
  when defined(windows):
    if p.len >= 2 and p[1] == ':': result.add '/'          # file:///C:/… (the drive's colon as it is)
  for c in (when defined(windows): p.replace('\\', '/') else: p):
    if c == ':' and defined(windows): result.add c
    elif c in {'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~', '/'}: result.add c
    else: result.add '%' & toHex(ord(c), 2)

func pathFromUri(u: string): string =
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
template compInsert(it: CompItem): string = (if it.insert.len > 0: it.insert else: it.label)

func gitArgSafe*(s: string): bool =
  ## a URL, folder or revision a project or a link gives that git can take as itself — not as one of its options
  ## (`--upload-pack=…` runs a command: what nimble 0.26.1 closed in its own git calls), nor two lines
  s.len > 0 and s[0] != '-' and '\n' notin s and '\r' notin s and '\0' notin s
