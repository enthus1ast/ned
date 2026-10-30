# ── line diff (Myers, after trimming the common head and tail) ──

type DiffOp = object
  kind: char          # ' ' same, '-' only in a, '+' only in b
  text: string
  aLine, bLine: int   # 0-based line in a / b (-1 when absent)

proc lineDiff(a, b: seq[string]): seq[DiffOp] =
  ## the line-by-line difference between `a` and `b` as a sequence of same, removed and added lines, each with its line
  ## number on either side. The shared first and last lines are cut off, then Myers' algorithm finds the shortest edit
  ## of the rest; when it would need more than 2000 changes the whole middle is reported as removed and then added.
  var pre = 0
  while pre < a.len and pre < b.len and a[pre] == b[pre]: inc pre
  var suf = 0
  while suf < a.len - pre and suf < b.len - pre and a[a.high - suf] == b[b.high - suf]: inc suf
  for i in 0 ..< pre: result.add DiffOp(kind: ' ', text: a[i], aLine: i, bLine: i)
  let n = a.len - pre - suf
  let m = b.len - pre - suf
  var mid: seq[DiffOp]
  if n == 0:
    for j in 0 ..< m: mid.add DiffOp(kind: '+', text: b[pre + j], aLine: -1, bLine: pre + j)
  elif m == 0:
    for i in 0 ..< n: mid.add DiffOp(kind: '-', text: a[pre + i], aLine: pre + i, bLine: -1)
  else:
    let maxD = min(n + m, 2000)
    let off = maxD + 1
    var v = newSeq[int](2 * maxD + 3)
    var trace: seq[seq[int]]      # trace[d] = v[-d-1 .. d+1] before step d (O(D²) memory)
    var found = -1
    for d in 0 .. maxD:
      trace.add v[off - d - 1 .. off + d + 1]
      var k = -d
      while k <= d:
        var x = if k == -d or (k != d and v[off + k - 1] < v[off + k + 1]): v[off + k + 1] else: v[off + k - 1] + 1
        var y = x - k
        while x < n and y < m and a[pre + x] == b[pre + y]:
          inc x
          inc y
        v[off + k] = x
        if x >= n and y >= m:
          found = d
          break
        k += 2
      if found >= 0: break
    if found < 0:
      for i in 0 ..< n: mid.add DiffOp(kind: '-', text: a[pre + i], aLine: pre + i, bLine: -1)
      for j in 0 ..< m: mid.add DiffOp(kind: '+', text: b[pre + j], aLine: -1, bLine: pre + j)
    else:
      var x = n
      var y = m
      var rev: seq[DiffOp]
      for d in countdown(found, 1):
        let vv = trace[d]
        let o = d + 1
        let k = x - y
        let prevK = if k == -d or (k != d and vv[o + k - 1] < vv[o + k + 1]): k + 1 else: k - 1
        let px = vv[o + prevK]
        let py = px - prevK
        while x > px and y > py:
          dec x
          dec y
          rev.add DiffOp(kind: ' ', text: a[pre + x], aLine: pre + x, bLine: pre + y)
        if x == px:
          dec y
          rev.add DiffOp(kind: '+', text: b[pre + y], aLine: -1, bLine: pre + y)
        else:
          dec x
          rev.add DiffOp(kind: '-', text: a[pre + x], aLine: pre + x, bLine: -1)
      while x > 0 and y > 0:
        dec x
        dec y
        rev.add DiffOp(kind: ' ', text: a[pre + x], aLine: pre + x, bLine: pre + y)
      for i in countdown(rev.high, 0): mid.add rev[i]
  result.add mid
  for i in 0 ..< suf:
    result.add DiffOp(kind: ' ', text: a[a.len - suf + i], aLine: a.len - suf + i, bLine: b.len - suf + i)

proc textLines(t: string): seq[string] =
  ## a text as lines for comparing: split at line feeds, the empty piece after a final line feed dropped, carriage
  ## returns removed
  result = t.split('\n')
  if result.len > 1 and result[^1].len == 0: result.setLen(result.len - 1)
  for x in result.mitems:
    if x.len > 0 and x[^1] == '\r': x.setLen(x.len - 1)

func diffStats(ops: seq[DiffOp]): (int, int) =
  ## how many lines the diff adds and how many it removes, as (added, removed)
  for o in ops:
    if o.kind == '+': inc result[0]
    elif o.kind == '-': inc result[1]

proc unifiedDiff(a, b: seq[string], nameA, nameB: string, ctx = 3): string =
  ## the differences as `diff -u` text, with `ctx` lines of context around each change (nearby changes share one hunk);
  ## "" when the two are the same
  let ops = lineDiff(a, b)
  var changed = false
  for o in ops:
    if o.kind != ' ':
      changed = true
      break
  if not changed: return ""
  result = "--- " & nameA & "\n+++ " & nameB & "\n"
  var i = 0
  while i < ops.len:
    if ops[i].kind == ' ':
      inc i
      continue
    # a hunk: back up `ctx` lines, run until `ctx * 2` unchanged lines follow
    let s = max(0, i - ctx)
    var lastChange = i
    var e = i
    while e < ops.len:
      if ops[e].kind != ' ': lastChange = e
      elif e - lastChange > ctx * 2: break
      inc e
    e = min(ops.len, lastChange + 1 + ctx)
    var aStart, bStart = -1
    var aN, bN = 0
    for q in s ..< e:
      if ops[q].kind != '+':
        if aStart < 0: aStart = ops[q].aLine
        inc aN
      if ops[q].kind != '-':
        if bStart < 0: bStart = ops[q].bLine
        inc bN
    if aStart < 0: aStart = (if s > 0 and ops[s - 1].aLine >= 0: ops[s - 1].aLine + 1 else: 0)
    if bStart < 0: bStart = (if s > 0 and ops[s - 1].bLine >= 0: ops[s - 1].bLine + 1 else: 0)
    result.add "@@ -" & $(aStart + (if aN > 0: 1 else: 0)) & "," & $aN & " +" &
               $(bStart + (if bN > 0: 1 else: 0)) & "," & $bN & " @@\n"
    for q in s ..< e: result.add ops[q].kind & ops[q].text & "\n"
    i = e
