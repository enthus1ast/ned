# ── CSV tables: sort by a column, a column's summary ──

func csvCell(s: string, f: (int, int)): string =
  ## a field's value: its quotes taken off ("" is a quote)
  result = s[f[0] ..< f[1]].strip
  if result.len >= 2 and result[0] == '"' and result[^1] == '"': result = result[1 ..< ^1].replace("\"\"", "\"")

func csvNum(v: string): (bool, float) =
  ## reads a CSV value as a number: (true, its value), or (false, 0) when it is empty or not one — underscores are
  ## ignored
  let t = v.strip.replace("_", "")
  if t.len == 0: return (false, 0.0)
  try: (true, parseFloat(t))
  except ValueError: (false, 0.0)

proc csvColumnAt(b: Buffer): int =
  ## the number (from 0) of the column the cursor is in, on its own line; 0 when it is in none
  let p = b.primary.head
  let s = b.lines[p.line]
  for i, f in csvFields(s, csvSepOf(b.lang, s)):
    if p.col >= f[0] and p.col <= f[1]: return i
  0

proc csvHasHeader(b: Buffer): bool =
  ## the first row names the columns: none of its fields is a number
  if b.lines.len < 2: return false
  let s = b.lines[0]
  for f in csvFields(s, csvSepOf(b.lang, s)):
    if csvNum(csvCell(s, f))[0]: return false
  true

proc csvNatCmp(a, b: string): int =
  ## text compared the way people read it: the numbers in it by their value ("item 9" before "item 10")
  var i, j = 0
  while i < a.len and j < b.len:
    if a[i] in Digits and b[j] in Digits:
      var e1 = i
      while e1 < a.len and a[e1] in Digits: inc e1
      var e2 = j
      while e2 < b.len and b[e2] in Digits: inc e2
      let n1 = a[i ..< e1].strip(trailing = false, chars = {'0'})
      let n2 = b[j ..< e2].strip(trailing = false, chars = {'0'})
      if n1.len != n2.len: return cmp(n1.len, n2.len)
      let c = cmp(n1, n2)
      if c != 0: return c
      i = e1
      j = e2
    else:
      let c = cmp(a[i].toLowerAscii, b[j].toLowerAscii)
      if c != 0: return c
      inc i
      inc j
  cmp(a.len - i, b.len - j)

proc cmdCsvSort(desc: bool) =
  ## the rows sorted by the cursor's column — as numbers when every value is one (the first row stays when it is
  ## the headings; empty values go last)
  let b = buf()
  if b.lang.mode != lmCsv:
    info("Open a CSV or TSV file")
    return
  if not b.canEdit(): return
  let col = csvColumnAt(b)
  let first = if csvHasHeader(b): 1 else: 0
  var last = b.lines.high
  while last >= first and b.lines[last].strip.len == 0: dec last
  if last - first < 1:
    info("Nothing to sort")
    return
  var rows: seq[(string, bool, float, string)]       # (value, is a number, number, the line)
  var allNum = true
  for l in first .. last:
    let s = b.lines[l]
    let fs = csvFields(s, csvSepOf(b.lang, s))
    let v = if col < fs.len: csvCell(s, fs[col]) else: ""
    let (isN, n) = csvNum(v)
    if v.len > 0 and not isN: allNum = false
    rows.add (v, isN, n, s)
  rows.sort(proc(x, y: (string, bool, float, string)): int =
    if x[0].len == 0 and y[0].len == 0: return 0
    if x[0].len == 0: return 1
    if y[0].len == 0: return -1
    let c = if allNum or (x[1] and y[1]): cmp(x[2], y[2])
            elif x[1] != y[1]: (if x[1]: -1 else: 1)       # (numbers before words)
            else: csvNatCmp(x[0], y[0])                     # "15th century" after "6th century"
    if desc: -c else: c)
  var outL = b.lines[0 ..< first]
  for r in rows: outL.add r[3]
  if last < b.lines.high: outL.add b.lines[last + 1 .. ^1]
  let p = b.primary.head
  b.setTextMinimal(outL.join("\n"))
  b.setSingle(b.clampPos(p))
  let hs = csvFields(b.lines[0], csvSepOf(b.lang, b.lines[0]))
  let name = if first == 1 and col < hs.len: csvCell(b.lines[0], hs[col]) else: "column " & $(col + 1)
  info("Sorted " & $rows.len & " rows by " & name & (if allNum: " (as numbers)" else: "") &
       (if desc: ", largest first" else: "") & " — Ctrl+Z undoes")

proc cmdCsvSummary() =
  ## the cursor's column: how many values, how many empty; numbers: sum, smallest, largest, mean; text: the most common
  let b = buf()
  if b.lang.mode != lmCsv:
    info("Open a CSV or TSV file")
    return
  let col = csvColumnAt(b)
  let first = if csvHasHeader(b): 1 else: 0
  var n, empty, nums = 0
  var sum = 0.0
  var lo = Inf
  var hi = NegInf
  var counts: CountTable[string]
  for l in first .. b.lines.high:
    let s = b.lines[l]
    if s.strip.len == 0: continue
    let fs = csvFields(s, csvSepOf(b.lang, s))
    let v = if col < fs.len: csvCell(s, fs[col]) else: ""
    inc n
    if v.len == 0:
      inc empty
      continue
    counts.inc v
    let (isN, x) = csvNum(v)
    if isN:
      inc nums
      sum += x
      lo = min(lo, x)
      hi = max(hi, x)
  let hs = csvFields(b.lines[0], csvSepOf(b.lang, b.lines[0]))
  let name = if first == 1 and col < hs.len: csvCell(b.lines[0], hs[col]) else: "column " & $(col + 1)
  proc num(x: float): string =
    ## a number for the summary: whole values without decimals, others with up to three decimals and no trailing zeros
    if abs(x) < 1e15 and x == float(int64(x)): $int64(x) else: formatFloat(x, ffDecimal, 3).strip(leading = false, chars = {'0'}).strip(leading = false, chars = {'.'})
  var ls = @[PanelLine(text: "COLUMN " & $(col + 1) & " — " & name, sev: 5, line: -1),
             PanelLine(text: "  rows " & $n & (if empty > 0: " · empty " & $empty else: "") & " · different values " & $counts.len, line: -1)]
  if nums > 0:
    ls.add PanelLine(text: "  numbers " & $nums & " · sum " & num(sum) & " · smallest " & num(lo) & " · largest " & num(hi) &
                           " · mean " & num(sum / nums.float), line: -1)
  if nums < n - empty:
    counts.sort()
    var top: seq[string]
    for v, c in counts:
      top.add truncTo(v, 30) & " ×" & $c
      if top.len >= 8: break
    ls.add PanelLine(text: "  most common: " & top.join(" · "), line: -1)
  setPanel(pkOutput)
  panelTitle = "CSV"
  panelLines = ls
  panelFollow = false
  panelScroll = 0
  needRender = true
