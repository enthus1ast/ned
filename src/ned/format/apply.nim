# the means of applying a formatter: running an external command as a filter (text in on stdin, text out), putting its
# result into the buffer as the smallest set of line edits with the cursors kept on their code, and working out a
# buffer's text after a list of edits.
proc runFilter(cmd, input, cwd: string, timeoutMs = 15000): (bool, string, string) =
  ## runs `cmd` with `input` on stdin; returns (ok, stdout, stderr)
  var p: Proc
  let run = if remotes.len > 0 and cmd.startsWith("git "): gitWrap(cmd, cwd) else: cmd
  try:
    p = spawnProc(@["sh", "-c", run], cwd, siPipe, erPipe)
  except CatchableError as e:
    return (false, "", e.msg)
  setNonBlock(p.inFd); setNonBlock(p.outFd); setNonBlock(p.errFd)
  var off = 0
  var o, e: string
  let t0 = getMonoTime()
  var tmp: array[16384, char]
  while p.outFd >= 0 or p.errFd >= 0:
    if p.inFd >= 0 and off >= input.len: closeFd(p.inFd)
    var fds: seq[TPollfd]
    if p.inFd >= 0: fds.add TPollfd(fd: p.inFd, events: POLLOUT)
    if p.outFd >= 0: fds.add TPollfd(fd: p.outFd, events: POLLIN)
    if p.errFd >= 0: fds.add TPollfd(fd: p.errFd, events: POLLIN)
    discard poll(addr fds[0], fds.len.Tnfds, 100)
    if p.inFd >= 0:
      let n = posix.write(p.inFd, unsafeAddr input[off], input.len - off)
      if n > 0: off += n
      elif n < 0 and errno notin [EAGAIN, EINTR]: closeFd(p.inFd)
    for isOut in [true, false]:
      let fd = if isOut: p.outFd else: p.errFd
      if fd < 0: continue
      let n = posix.read(fd, addr tmp[0], tmp.len)
      if n > 0:
        if isOut:
          let start = o.len
          o.setLen(start + n)
          copyMem(addr o[start], addr tmp[0], n)
        else:
          let start = e.len
          e.setLen(start + n)
          copyMem(addr e[start], addr tmp[0], n)
      elif n == 0 or (n < 0 and errno notin [EAGAIN, EINTR]):
        if isOut: closeFd(p.outFd) else: closeFd(p.errFd)
    if msSince(t0) > timeoutMs:
      killProc(p, SIGKILL)
      discard waitProc(p, 500)
      closeProc(p)
      return (false, o, "timed out")
  let code = waitProc(p, max(500, timeoutMs - int(msSince(t0))))
  closeProc(p)
  (code == 0, o, e)

func nonWsBefore(s: string, col: int): int =
  ## how many non-whitespace characters stand before `col` (survives re-indenting and re-spacing)
  for i in 0 ..< min(col, s.len):
    if s[i] notin {' ', '\t'}: inc result

func colForNonWs(s: string, n: int): int =
  ## the column after `n` non-whitespace characters (the inverse of nonWsBefore)
  if n <= 0:
    var i = 0
    while i < s.len and s[i] in {' ', '\t'}: inc i
    return i
  var k = 0
  for i in 0 ..< s.len:
    if s[i] notin {' ', '\t'}:
      inc k
      if k == n: return i + 1
  s.len

proc setTextMinimal(b: Buffer, newText: string) =
  ## replace the buffer's content with `newText` as one undo step, touching only the lines that differ.
  ## Cursors stay on the same code — an unchanged line keeps them, a changed line passes them to the
  ## line that replaced it, at the same character (counted without whitespace) — and the view keeps
  ## the cursor on the same screen row.
  var nl = newText.split('\n')
  if nl.len > 1 and nl[^1].len == 0: nl.setLen(nl.len - 1)
  let ol = b.lines
  if ol == nl: return
  let ops = lineDiff(ol, nl)
  # where each old line went: its new index (exact), or the line that replaced it
  var newOf = newSeq[int](ol.len)
  var hunkOf = newSeq[int](ol.len)       # the hunk an old line is in (-1: unchanged)
  type Hunk = object
    a0, a1, b0, b1: int        # old lines [a0, a1) became new lines [b0, b1)
  var hunks: seq[Hunk]
  var ai = 0
  var bi = 0
  var k = 0
  while k < ops.len:
    if ops[k].kind == ' ':
      newOf[ai] = bi
      hunkOf[ai] = -1
      inc ai
      inc bi
      inc k
      continue
    var h = Hunk(a0: ai, b0: bi)
    while k < ops.len and ops[k].kind != ' ':
      if ops[k].kind == '-': inc ai else: inc bi
      inc k
    h.a1 = ai
    h.b1 = bi
    for r in h.a0 ..< h.a1:
      newOf[r] = if h.b1 > h.b0: min(h.b0 + (r - h.a0), h.b1 - 1) else: min(h.b0, max(0, nl.high))
      hunkOf[r] = hunks.len
    hunks.add h
  # where each cursor goes: an unchanged line keeps it; inside a changed block of lines it moves to the
  # same character of the new lines, counted without whitespace from the block's start (a formatter
  # that splits or joins lines keeps the cursor on its code)
  proc nonWs(s: string): int =
    for ch in s:
      if ch notin {' ', '\t'}: inc result
  # is old line i one the formatter left as it was and that has code on it? Such lines mark the edges of a changed
  # region for the cursors
  proc anchor(i: int): bool = hunkOf[i] < 0 and ol[i].strip.len > 0     # an unchanged line with code
  proc target(p: Pos): Pos =
    ## where an old position goes in the new text: on an unchanged line, the same line (moved to its new number) and the
    ## same character; in a changed region, the character with the same number of non-blank characters before it,
    ## counted from the region's start, so a formatter that splits or joins lines keeps the cursor on its code
    let r = clamp(p.line, 0, ol.high)
    let atEol = p.col >= ol[r].len and ol[r].len > 0
    if hunkOf[r] < 0:
      let nlx = newOf[r]
      return Pos(line: nlx, col: (if atEol: nl[nlx].len else: colForNonWs(nl[nlx], nonWsBefore(ol[r], p.col))))
    # the changed region around the cursor: between the unchanged lines with code before and after it
    # (blank lines the diff happened to keep do not split it)
    var a = r - 1
    while a >= 0 and not anchor(a): dec a
    var z = r + 1
    while z < ol.len and not anchor(z): inc z
    let b0 = if a >= 0: newOf[a] + 1 else: 0
    let b1 = if z < ol.len: newOf[z] else: nl.len
    if b1 <= b0:
      # the cursor's lines are gone (blank lines the formatter removed): the end of the line before them —
      # at the end of the file that is the end of the last line, not its start
      if b0 >= 1 and b0 - 1 <= nl.high: return Pos(line: b0 - 1, col: nl[b0 - 1].len)
      return Pos(line: clamp(b0, 0, max(0, nl.high)), col: 0)
    var n = nonWsBefore(ol[r], p.col)
    for i in a + 1 ..< r: n += nonWs(ol[i])
    if n == 0 and ol[r].strip.len == 0:
      # on a blank line before any code of the region: stay on a blank line if one is left there
      var k = b0
      while k < b1 and nl[k].strip.len == 0: inc k
      if k > b0: return Pos(line: k - 1, col: nl[k - 1].len)
      if k == b0 and b0 >= 1 and nl[b0 - 1].strip.len > 0 and r > 0 and ol[r - 1].strip.len > 0:
        return Pos(line: b0 - 1, col: nl[b0 - 1].len)   # the blank line went: the end of the code above it
    for j in b0 ..< b1:
      let c = nonWs(nl[j])
      if n < c or (n == c and (j == b1 - 1 or atEol)): return Pos(line: j, col: colForNonWs(nl[j], n))
      n -= c
    Pos(line: b1 - 1, col: nl[b1 - 1].len)
  var marks: seq[(Pos, Pos)]
  for c in b.cursors: marks.add (target(c.head), target(c.anchor))
  let pl = clamp(b.primary.head.line, 0, ol.high)
  let rowOff = pl - b.topLine
  b.beginEdit()
  for hi in countdown(hunks.high, 0):
    let h = hunks[hi]
    let cur = b.lines
    let mid = nl[h.b0 ..< h.b1].join("\n")
    if h.a1 > h.a0 and h.b1 > h.b0:
      discard b.replaceText(Pos(line: h.a0, col: 0), Pos(line: h.a1 - 1, col: cur[h.a1 - 1].len), mid)
    elif h.a1 > h.a0:                       # lines removed
      if h.a1 < cur.len: discard b.replaceText(Pos(line: h.a0, col: 0), Pos(line: h.a1, col: 0), "")
      elif h.a0 > 0:
        discard b.replaceText(Pos(line: h.a0 - 1, col: cur[h.a0 - 1].len), Pos(line: h.a1 - 1, col: cur[h.a1 - 1].len), "")
      else: discard b.replaceText(Pos(), Pos(line: h.a1 - 1, col: cur[h.a1 - 1].len), "")
    else:                                   # lines added
      if h.a0 < cur.len: discard b.replaceText(Pos(line: h.a0, col: 0), Pos(line: h.a0, col: 0), mid & "\n")
      else: discard b.replaceText(Pos(line: cur.high, col: cur[^1].len), Pos(line: cur.high, col: cur[^1].len), "\n" & mid)
  b.endEdit()
  # put the cursors back on their code
  var cs: seq[Cursor]
  for (h, a) in marks:
    let nh = clamp(h.line, 0, b.lines.high)
    let na = clamp(a.line, 0, b.lines.high)
    cs.add Cursor(anchor: Pos(line: na, col: min(a.col, b.lines[na].len)),
                  head: Pos(line: nh, col: min(h.col, b.lines[nh].len)), goalX: -1)
  if cs.len > 0:
    b.cursors = cs
    b.prim = clamp(b.prim, 0, cs.high)
  b.normalize()
  # same screen row for the cursor
  b.topLine = clamp(b.primary.head.line - rowOff, 0, max(0, b.lines.high))
  b.topSub = 0

proc textWithEdits(b: Buffer, edits: seq[(Pos, Pos, string)]): string =
  ## the buffer's text after applying edits (positions in the current text), without touching it
  var starts = newSeq[int](b.lines.len + 1)
  var off = 0
  for i, l in b.lines:
    starts[i] = off
    off += l.len + 1
  starts[b.lines.len] = off
  proc at(p: Pos): int =
    ## the offset in the whole text of a position, kept inside its line
    let l = clamp(p.line, 0, b.lines.high)
    starts[l] + clamp(p.col, 0, b.lines[l].len)
  var list = edits
  list.sort(proc(x, y: (Pos, Pos, string)): int = cmp(at(y[0]), at(x[0])))
  result = b.allText
  var last = high(int)
  for (a, c, t) in list:
    let ia = at(a)
    let ic = max(ia, at(c))
    if ic > last: continue                 # overlapping edits: keep the first one
    result = result[0 ..< ia] & t & result[min(ic, result.len) .. ^1]
    last = ia
