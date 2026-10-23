# ── The large-file viewer: a file bigger than editor.viewerSize (512 MB) — a log, a dump, a data file — opened
#    read-only with a window of its lines in memory (LfWin of them). Where every LfStep-th line starts is indexed in
#    the background (a few megabytes a round), so scrolling, Go to line, Ctrl+End and the search (the whole file, in
#    the background too) reach any line of it; Copy copies from the window ──

const
  LfStep = 1024            # (a line start kept every LfStep lines: 30 million lines, 30 000 numbers)
  LfWin = 6000             # the lines held at a time
  LfMargin = 400           # this near the window's edge, the window moves
  LfLineCap = 8192         # a longer line is shown cut (…)
  LfChunk = 4 * 1024 * 1024

proc lfReadAt(v: LfView, off: int64, n: int): string =
  ## n bytes from off (fewer at the end of the file)
  if n <= 0 or off >= v.size: return ""
  result = newString(min(int64(n), v.size - off))
  try:
    v.f.setFilePos(off)
    result.setLen(v.f.readBuffer(addr result[0], result.len))
  except CatchableError: result.setLen(0)

proc lfLinesFrom(v: LfView, off: int64, n: int): (seq[string], int) =
  ## up to n lines from the byte offset `off` (a line start), each cut at LfLineCap: (the lines, how many were cut)
  var pos = off
  var cur = ""
  var cutN = 0
  var cutting = false
  var res: seq[string]
  while res.len < n and pos < v.size:
    let chunk = lfReadAt(v, pos, 1024 * 1024)
    if chunk.len == 0: break
    pos += chunk.len
    var i = 0
    while i < chunk.len and res.len < n:
      let nl = chunk.find('\n', i)
      let e = if nl < 0: chunk.len else: nl
      if not cutting:
        let room = LfLineCap - cur.len
        if e - i > room:
          cur.add chunk[i ..< i + room]
          cur.add "…"
          cutting = true
          inc cutN
        else: cur.add chunk[i ..< e]
      if nl < 0: break
      if cur.endsWith("\r"): cur.setLen(cur.len - 1)
      res.add cur
      cur = ""
      cutting = false
      i = nl + 1
  if res.len < n and (cur.len > 0 or res.len == 0): res.add cur
  (res, cutN)

proc lfOffsetOf(v: LfView, line: int): int64 =
  ## where `line` starts (a line the index has reached)
  let k = clamp(line div LfStep, 0, v.marks.high)
  var off = v.marks[k]
  var left = line - k * LfStep
  while left > 0 and off < v.size:
    let chunk = lfReadAt(v, off, 1024 * 1024)
    if chunk.len == 0: break
    var i = 0
    while left > 0:
      let nl = chunk.find('\n', i)
      if nl < 0: break
      dec left
      i = nl + 1
    off += (if left == 0: i else: chunk.len)
  off

proc lfLineOf(v: LfView, off: int64): int =
  ## the line the byte at `off` is on (in the indexed part)
  var lo = 0
  var hi = v.marks.high
  while lo < hi:
    let mid = (lo + hi + 1) div 2
    if v.marks[mid] <= off: lo = mid else: hi = mid - 1
  result = lo * LfStep
  var p = v.marks[lo]
  while p < off:
    let chunk = lfReadAt(v, p, int(min(int64(1024 * 1024), off - p)))
    if chunk.len == 0: break
    result += chunk.count('\n')
    p += chunk.len

proc lfSetLines(b: Buffer, lines: seq[string]) =
  b.lines = if lines.len > 0: lines else: @[""]
  b.hlStart = newSeq[LexSt](b.lines.len + 1)
  b.hlValid = 0
  b.git = newSeq[uint8](b.lines.len)
  inc b.changeId
  b.undoStack.setLen(0)
  b.redoStack.setLen(0)
  b.undoBranches.setLen(0)

proc lfLoad(b: Buffer, base0: int) =
  ## the window from line base0 (as far as the index has come)
  let v = b.viewer
  let last = max(0, (if v.done: v.lineCount else: v.lineCount) - 1)
  let base = clamp(base0, 0, max(0, last - (if v.done: LfWin - 1 else: 0)))
  let (ls, cutN) = lfLinesFrom(v, lfOffsetOf(v, base), LfWin)
  v.base = base
  v.cut = cutN
  b.lfSetLines(ls)
  needRender = true

proc lfShowAt(b: Buffer, absLine, col: int) =
  ## line absLine (of the file) in the middle of the screen, the cursor on it
  let v = b.viewer
  var l = absLine
  if not v.done: l = min(l, max(0, v.lineCount - 1))
  elif v.lineCount > 0: l = min(l, v.lineCount - 1)
  if l < v.base or l >= v.base + b.lines.len or
     (l - v.base < LfMargin and v.base > 0) or (v.base + b.lines.len - l < LfMargin and
                                                 v.base + b.lines.len < v.lineCount):
    b.lfLoad(l - LfWin div 2)
  let p = b.clampPos(Pos(line: l - v.base, col: col))
  b.cursors = @[cur(p)]
  b.prim = 0
  b.centerOn(p)

proc lfFollow(b: Buffer) =
  ## the window moved with you: near its edge (scrolling, the cursor), the lines beyond it read in its place
  let v = b.viewer
  if v == nil: return
  let head = b.primary.head.line
  let n = b.lines.len
  # (the window's last line or its first: only Ctrl+End or Ctrl+Home get there — scrolling moves the window before —
  # so the file's end or its start)
  if head == n - 1 and v.base + n < v.lineCount and v.done:
    b.lfShowAt(v.lineCount - 1, 0)
    return
  if head == 0 and v.base > 0 and b.primary.head.col == 0:
    b.lfShowAt(0, 0)
    return
  let nearTop = (b.topLine < LfMargin or head < LfMargin) and v.base > 0
  let nearEnd = (b.topLine + lay.textH > n - LfMargin or head > n - LfMargin) and v.base + n < v.lineCount
  if not (nearTop or nearEnd): return
  let absTop = v.base + b.topLine
  let absHead = v.base + head
  let col = b.primary.head.col
  # (around what is on the screen: the cursor when it is there, else the middle of the screen — the wheel scrolls
  # without moving it)
  let shown = head >= b.topLine and head < b.topLine + lay.textH
  b.lfLoad((if shown: absHead else: absTop + lay.textH div 2) - LfWin div 2)
  b.topLine = clamp(absTop - v.base, 0, b.lines.high)
  let l = if absHead >= v.base and absHead < v.base + b.lines.len: absHead - v.base else: b.topLine
  let p = b.clampPos(Pos(line: l, col: (if l == absHead - v.base: col else: 0)))
  b.cursors = @[cur(p)]
  b.prim = 0

proc lfIndexStep(v: LfView, ms: int) =
  ## more of the index: where each LfStep-th line starts
  let t0 = getMonoTime()
  while not v.done and msSince(t0) < ms:
    let chunk = lfReadAt(v, v.indexed, LfChunk)
    if chunk.len == 0:
      v.done = true
      if not v.lastNl: inc v.lineCount          # (the last line has no line end)
      break
    var i = 0
    while true:
      let nl = chunk.find('\n', i)
      if nl < 0: break
      inc v.lineCount
      if v.lineCount mod LfStep == 0: v.marks.add v.indexed + nl + 1
      i = nl + 1
    v.lastNl = chunk[^1] == '\n'
    v.indexed += chunk.len
    if v.indexed >= v.size:
      v.done = true
      if not v.lastNl: inc v.lineCount
  needRender = true

proc lfFindStep(b: Buffer, ms: int) =
  ## more of the search (behind the index: a match's line is then known)
  let v = b.viewer
  if not v.findBusy: return
  let t0 = getMonoTime()
  let q = v.findQ
  while msSince(t0) < ms:
    let limit = if v.findWrapped: v.findFrom else: (if v.done: v.size else: v.indexed)
    if v.findAt >= limit:
      if not v.done and not v.findWrapped: return            # (the index has not come this far yet)
      if not v.findWrapped:
        v.findWrapped = true
        v.findAt = 0
        continue
      v.findBusy = false
      info("“" & q & "” is not in " & extractFilename(v.path))
      return
    let n = int(min(int64(LfChunk), limit - v.findAt))
    var chunk = lfReadAt(v, v.findAt, n + q.len - 1)
    if chunk.len == 0:
      v.findAt = limit
      continue
    if v.findFold: chunk = chunk.toLowerAscii
    let k = chunk.find(if v.findFold: q.toLowerAscii else: q)
    if k >= 0 and k < n:
      let off = v.findAt + k
      v.findBusy = false
      let line = lfLineOf(v, off)
      let col = int(off - lfOffsetOf(v, line))
      b.lfShowAt(line, col)
      let h = b.primary.head
      b.cursors = @[Cursor(anchor: h, head: b.clampPos(Pos(line: h.line, col: h.col + q.len)), goalX: -1)]
      info("Line " & $(line + 1) & (if v.findWrapped: " (from the top again)" else: ""))
      return
    v.findAt += n

proc lfFind(b: Buffer, q: string, forward = true) =
  ## the whole file, from the cursor on (backwards: the lines in the window)
  let v = b.viewer
  if q.len == 0: return
  v.lastFind = q
  if not forward:
    let (s, _) = b.primary.range
    for l in countdown(s.line, 0):
      let t = b.lines[l]
      let k = (if l == s.line: t[0 ..< min(s.col, t.len)] else: t).rfind(q)
      if k >= 0:
        b.cursors = @[Cursor(anchor: Pos(line: l, col: k), head: Pos(line: l, col: k + q.len), goalX: -1)]
        b.centerOn(Pos(line: l, col: k))
        return
    info("Backwards: not in the " & $b.lines.len & " lines read now (F3 searches the whole file)")
    return
  let (_, e) = b.primary.range
  v.findQ = q
  v.findFold = q == q.toLowerAscii
  v.findFrom = lfOffsetOf(v, v.base + e.line) + e.col
  v.findAt = v.findFrom
  v.findWrapped = false
  v.findBusy = true
  info("Searching " & extractFilename(v.path) & " for “" & q & "”…")
  lfFindStep(b, 6)

proc lfPump() =
  ## each round: the index, a search, the window following you (a few milliseconds, only while there is work)
  for b in bufs:
    let v = b.viewer
    if v == nil: continue
    if not v.done and msSince(lastInputAt) > 50: lfIndexStep(v, 5)
    if v.findBusy: lfFindStep(b, 4)
  let b = buf()
  if b.viewer != nil: lfFollow(b)

proc lfBusy(): bool =
  for b in bufs:
    if b.viewer != nil and (not b.viewer.done or b.viewer.findBusy): return true
  false

proc lfOpen(b: Buffer, path: string, size: int64): bool =
  ## the viewer for a file too big to edit
  var f: File
  if not open(f, path): return false
  let v = LfView(path: path, size: size, f: f, marks: @[0'i64])
  if '\0' in lfReadAt(v, 0, 8000):                  # (a binary file: not lines — refused as before)
    close(f)
    return false
  b.viewer = v
  b.readOnly = true
  b.large = true
  b.largeWhy = $(size div (1024 * 1024)) & " MB: the viewer"
  b.enc = EncUtf8
  let (ls, cutN) = lfLinesFrom(v, 0, LfWin)
  v.cut = cutN
  b.lfSetLines(ls)
  lfIndexStep(v, 20)
  info(extractFilename(path) & " (" & $(size div (1024 * 1024)) & " MB) in the viewer: read-only, its lines read as you " &
       "go — Ctrl+G, Ctrl+F and F3 reach the whole file" & (if cutN > 0: "; very long lines are shown cut" else: ""))
  true

proc lfClose(b: Buffer) =
  if b.viewer != nil:
    try: close(b.viewer.f)
    except CatchableError: discard
    b.viewer = nil

proc lfStatus(b: Buffer): string =
  ## the status bar's position: the line in the file, of how many
  let v = b.viewer
  let p = b.primary.head
  "Ln " & $(v.base + p.line + 1) & " of " & (if v.done: $v.lineCount else: "≥" & $v.lineCount) &
    (if not v.done: " (" & $(v.indexed * 100 div max(1, v.size)) & "% read)" else: "") &
    (if v.findBusy: " · searching" else: "")

lfOpenHook = proc(b: Buffer, path: string, size: int64): bool = lfOpen(b, path, size)
