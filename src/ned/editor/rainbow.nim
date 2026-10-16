# ── rainbow brackets: a pair never takes the colour of the text around it ──

proc rbDepths(s: string, toks: seq[TokKind], d0: int): seq[int16] =
  ## nesting depth of every bracket on a line (an opening bracket and its closing one get the same)
  result.setLen(s.len)
  var d = d0
  for q in 0 ..< min(s.len, toks.len):
    if toks[q] == tkPunct:
      case s[q]
      of '(', '[', '{':
        result[q] = int16(d)
        inc d
      of ')', ']', '}':
        d = max(0, d - 1)
        result[q] = int16(d)
      else: discard

proc rbClose(a, b: Rgb): bool =
  ## colours too close to tell apart next to each other
  let x = abs(int((a shr 16) and 0xFF) - int((b shr 16) and 0xFF)) +
          abs(int((a shr 8) and 0xFF) - int((b shr 8) and 0xFF)) + abs(int(a and 0xFF) - int(b and 0xFF))
  x < 60

proc rbNeighbours(s: string, toks: seq[TokKind], i: int, res: var seq[Rgb]) =
  ## the colours right before and right after the bracket at i (spaces skipped, other brackets ignored)
  var j = i - 1
  while j >= 0 and s[j] in {' ', '\t'}: dec j
  if j >= 0 and j < toks.len and not (toks[j] == tkPunct and s[j] in {'(', ')', '[', ']', '{', '}'}):
    res.add theme.syn[toks[j]]
  j = i + 1
  while j < s.len and s[j] in {' ', '\t'}: inc j
  if j < s.len and j < toks.len and not (toks[j] == tkPunct and s[j] in {'(', ')', '[', ']', '{', '}'}):
    res.add theme.syn[toks[j]]

proc rbPick(d: int, avoid: seq[Rgb]): Rgb =
  ## the depth's rainbow colour — or the next one that differs from the text around the pair
  for k in 0 .. 2:
    let c = theme.rainbow[(d + k) mod 3]
    var ok = true
    for a in avoid:
      if rbClose(c, a): ok = false
    if ok: return c
  for c in [theme.syn[tkOperator], theme.accent, theme.fg]:
    var ok = true
    for a in avoid:
      if rbClose(c, a): ok = false
    if ok: return c
  theme.rainbow[d mod 3]

var
  rbCache: Table[(int, int, int), Rgb]    # (buffer, line, column) → colour of a pair that spans lines
  rbStamp: (int, int, string)

proc rbCrossColour(b: Buffer, line, col, d: int, opener: bool, s: string, toks: seq[TokKind]): Rgb =
  ## the colour of a bracket whose partner is on another line: the partner is found through the bracket
  ## depth at each line start, so both ends get the same colour
  if rbStamp != (b.id, b.changeId, theme.name):
    rbCache.clear()
    rbStamp = (b.id, b.changeId, theme.name)
  if (b.id, line, col) in rbCache: return rbCache[(b.id, line, col)]
  var avoid: seq[Rgb]
  rbNeighbours(s, toks, col, avoid)
  var pl, pc = -1
  var ptoks: seq[TokKind]
  if opener:
    let last = min(b.lines.high, line + 200)
    b.ensureHl(last + 1)
    for m in line + 1 .. last:
      if b.lines[m].len > 20000 or m + 1 >= b.hlDepth.len: break
      if b.hlDepth[m + 1] <= d:                     # the pair closes on this line
        let (st, d0) = b.stateAt(m)
        discard lexLine(b.lang, b.lines[m], st, ptoks)
        let dd = rbDepths(b.lines[m], ptoks, d0)
        for q in 0 ..< min(b.lines[m].len, ptoks.len):
          if ptoks[q] == tkPunct and b.lines[m][q] in {')', ']', '}'} and dd[q] == d:
            pl = m
            pc = q
            break
        break
  else:
    for k in countdown(line - 1, max(0, line - 200)):
      if k >= b.hlDepth.len or b.lines[k].len > 20000: break
      if b.hlDepth[k] <= d:                         # the pair opens on this line
        let (st, d0) = b.stateAt(k)
        discard lexLine(b.lang, b.lines[k], st, ptoks)
        let dd = rbDepths(b.lines[k], ptoks, d0)
        for q in countdown(min(b.lines[k].len, ptoks.len) - 1, 0):
          if ptoks[q] == tkPunct and b.lines[k][q] in {'(', '[', '{'} and dd[q] == d:
            pl = k
            pc = q
            break
        break
  if pl >= 0: rbNeighbours(b.lines[pl], ptoks, pc, avoid)
  result = rbPick(d, avoid)
  rbCache[(b.id, line, col)] = result
  if pl >= 0: rbCache[(b.id, pl, pc)] = result

proc rbColours(b: Buffer, line: int, s: string, toks: seq[TokKind], bdep: seq[int16]): seq[Rgb] =
  ## the colour of every bracket on a line; both brackets of a pair share it
  result.setLen(s.len)
  var stack: seq[int]
  for q in 0 ..< min(s.len, min(toks.len, bdep.len)):
    if toks[q] != tkPunct: continue
    case s[q]
    of '(', '[', '{': stack.add q
    of ')', ']', '}':
      if stack.len > 0:
        let o = stack.pop()
        var avoid: seq[Rgb]
        rbNeighbours(s, toks, o, avoid)
        rbNeighbours(s, toks, q, avoid)
        let c = rbPick(bdep[q], avoid)
        result[o] = c
        result[q] = c
      else: result[q] = rbCrossColour(b, line, q, bdep[q], false, s, toks)
    else: discard
  for o in stack: result[o] = rbCrossColour(b, line, o, bdep[o], true, s, toks)
