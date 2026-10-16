proc isWordAt(s: string, j, n: int): bool {.inline.} =
  (j == 0 or not isWordByte(s[j-1])) and (j + n >= s.len or not isWordByte(s[j + n]))

proc findInLine(s, q: string, start: int, caseSens, word: bool): int =
  var i = start
  while true:
    let j = rawFind(s, q, i, caseSens)
    if j < 0: return -1
    if not word or isWordAt(s, j, q.len): return j
    i = j + 1

proc findAllInLine(s, q: string, caseSens, word: bool): seq[int] =
  if q.len == 0 or q.len > s.len: return
  var i = 0
  while true:
    let j = rawFind(s, q, i, caseSens)
    if j < 0: break
    if not word or isWordAt(s, j, q.len): result.add j
    i = j + max(1, q.len)
    if result.len > 2000: break

var findRegex = false     # the find widget / search dock treat the query as a regular expression

proc findSpans(s, q: string, caseSens, word, rx: bool): seq[(int, int)] =
  ## every match in one line as (start, end) — literal or regex
  if q.len == 0: return
  if not rx:
    for j in findAllInLine(s, q, caseSens, word): result.add (j, j + q.len)
    return
  let re = cachedRegex(q, caseSens)
  if re[].err.len > 0: return
  var caps: seq[int]
  var i = 0
  while i <= s.len and result.len <= 2000:
    if not re[].reSearch(s, i, caps): break
    let (a, e) = (caps[0], caps[1])
    if not word or isWordAt(s, a, e - a): result.add (a, e)
    i = if e > a: e elif a < s.len: a + utf8Len(s[a]) else: a + 1

proc searchFrom(b: Buffer, q: string, frm: Pos, forward, caseSens, word: bool, rx = false): (bool, Pos, Pos) =
  if q.len == 0 or ('\n' in q and not rx): return (false, Pos(), Pos())
  let n = b.lines.len
  if rx:
    if cachedRegex(q, caseSens)[].err.len > 0: return (false, Pos(), Pos())
    let t0 = getMonoTime()
    for k in 0 .. n:
      let l = if forward: (frm.line + k) mod n else: ((frm.line - k) mod n + n) mod n
      let sp = findSpans(b.lines[l], q, caseSens, word, true)
      if forward:
        for (a, e) in sp:
          if k == 0 and a < frm.col: continue
          if k == n and a >= frm.col: break
          return (true, Pos(line: l, col: a), Pos(line: l, col: e))
      else:
        for h in countdown(sp.high, 0):
          if k == 0 and sp[h][0] >= frm.col: continue
          return (true, Pos(line: l, col: sp[h][0]), Pos(line: l, col: sp[h][1]))
      if (k and 1023) == 1023 and msSince(t0) > 1500: break     # a pathological pattern on a huge file
    return (false, Pos(), Pos())
  if forward:
    for k in 0 .. n:
      let l = (frm.line + k) mod n
      let start = if k == 0: frm.col else: 0
      if k == n and start == 0 and frm.col == 0: break
      let s = b.lines[l]
      var j = findInLine(s, q, start, caseSens, word)
      if k == n and j >= frm.col: j = -1
      if j >= 0: return (true, Pos(line: l, col: j), Pos(line: l, col: j + q.len))
  else:
    for k in 0 .. n:
      let l = ((frm.line - k) mod n + n) mod n
      let s = b.lines[l]
      let hits = findAllInLine(s, q, caseSens, word)
      for h in countdown(hits.high, 0):
        if k == 0 and hits[h] + q.len > frm.col: continue
        return (true, Pos(line: l, col: hits[h]), Pos(line: l, col: hits[h] + q.len))
  (false, Pos(), Pos())

proc selectNextOccurrence(b: Buffer) =
  let p = b.primary
  if not p.hasSel:
    for c in b.cursors.mitems:
      if not c.hasSel:
        let (a, e) = b.wordRangeAt(c.head)
        c.anchor = a
        c.head = e
    b.wordMode = true
    b.normalize()
    return
  let (pa, pe) = p.range
  if pa.line != pe.line:
    info("Multi-line selections can't be matched")
    return
  let q = b.getText(pa, pe)
  var last = Pos()
  for c in b.cursors: last = maxP(last, c.range[1])
  var frm = last
  for attempt in 0 .. b.cursors.len:
    let (ok, s, e) = b.searchFrom(q, frm, true, true, b.wordMode)
    if not ok: break
    var taken = false
    for c in b.cursors:
      if c.range[0] == s: taken = true
    if taken:
      frm = e
      continue
    b.cursors.add Cursor(anchor: s, head: e, goalX: -1)
    b.prim = b.cursors.high
    b.normalize()
    return
  info("No more occurrences")

proc selectAllOccurrences(b: Buffer) =
  if not b.primary.hasSel: b.selectNextOccurrence()
  let (pa, pe) = b.primary.range
  if pa.line != pe.line: return
  let q = b.getText(pa, pe)
  if q.len == 0: return
  var cs: seq[Cursor]
  for l in 0 ..< b.lines.len:
    for j in findAllInLine(b.lines[l], q, true, b.wordMode):
      cs.add Cursor(anchor: Pos(line: l, col: j), head: Pos(line: l, col: j + q.len), goalX: -1)
  if cs.len > 0:
    b.cursors = cs
    b.prim = 0
    for i, c in cs:
      if c.anchor == pa: b.prim = i
    b.normalize()
    info($cs.len & " occurrences selected")

proc addCursorVert(b: Buffer, dir: int) =
  var src = b.cursors[0]
  for c in b.cursors:
    if (dir > 0 and src.head < c.head) or (dir < 0 and c.head < src.head): src = c
  var nc = cur(src.head)
  nc.goalX = src.goalX
  b.moveVert(nc, dir)
  nc.anchor = nc.head
  if nc.head.line == src.head.line: return
  b.cursors.add nc
  b.prim = b.cursors.high
  b.normalize()

proc matchBracket(b: Buffer, p: Pos): (bool, Pos, Pos) =
  ## bracket at/before p and its partner
  const opens = "([{"
  const closes = ")]}"
  let s = b.lines[p.line]
  var at = -1
  if p.col < s.len and (s[p.col] in opens or s[p.col] in closes): at = p.col
  elif p.col > 0 and (s[p.col-1] in opens or s[p.col-1] in closes): at = p.col - 1
  if at < 0: return (false, p, p)
  let ch = s[at]
  let oi = opens.find(ch)
  let forward = oi >= 0
  let mine = ch
  let other = if forward: closes[oi] else: opens[closes.find(ch)]
  var depth = 0
  var l = p.line
  var i = at
  var scanned = 0
  while l >= 0 and l < b.lines.len and scanned < 5000:
    let t = b.lines[l]
    if forward:
      while i < t.len:
        if t[i] == mine: inc depth
        elif t[i] == other:
          dec depth
          if depth == 0: return (true, Pos(line: p.line, col: at), Pos(line: l, col: i))
        inc i
      inc l
      i = 0
    else:
      while i >= 0:
        if i < t.len:
          if t[i] == mine: inc depth
          elif t[i] == other:
            dec depth
            if depth == 0: return (true, Pos(line: p.line, col: at), Pos(line: l, col: i))
        dec i
      dec l
      if l >= 0: i = b.lines[l].len - 1
    inc scanned
  (false, p, p)
