# ── selection by structure: it grows to the enclosing word, string, brackets, statement and block, and shrinks back
#    ──

var selStack: seq[seq[Cursor]]

# ── the pieces of code around a selection, smallest first: a name, a member chain (a.b(c).d), what a pair of
#    brackets or quotes holds and the pair, one argument of a call, the value after `=`, the statement (with its
#    continuation lines), the block it is in, the block with its header, the top-level declaration (with the
#    comments above it), the file. By the text's brackets, quotes and indentation: every language ──

func prevPos(b: Buffer, p: Pos): Pos =
  ## the position one character before p (the end of the line above at a line start); line -1 at the start of the buffer
  if p.col > 0: Pos(line: p.line, col: p.col - 1)
  elif p.line > 0: Pos(line: p.line - 1, col: max(0, b.lines[p.line - 1].len))
  else: Pos(line: -1)

proc enclosingPair(b: Buffer, a, e: Pos, obj: char): (bool, Pos, Pos) =
  ## the innermost pair of brackets `obj` around a..e (its opener, just after its closer)
  var p = a
  for _ in 0 ..< 64:
    if p.line < 0: return
    let (ok, x, y) = b.textObject('a', obj, p)
    if not ok: return
    if x <= a and e <= y and not (x == a and y == e): return (true, x, y)
    p = b.prevPos(x)

func selIndent(s: string): int =
  ## the number of leading spaces and tabs of a line
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  i

func codeEnd(s: string): string =
  ## the line without its trailing comment (roughly: a # or // outside quotes) and spaces
  var q = '\0'
  var i = 0
  while i < s.len:
    let c = s[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c in {'"', '\''}: q = c
    elif c == '#' or (c == '/' and i + 1 < s.len and s[i + 1] == '/'): return s[0 ..< i].strip(leading = false)
    inc i
  s.strip(leading = false)

func openCount(s: string): int =
  ## ( and [ opened minus closed on a line (outside quotes)
  var q = '\0'
  var i = 0
  while i < s.len:
    let c = s[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c in {'"', '\''}: q = c
    elif c in {'(', '['}: inc result
    elif c in {')', ']'}: dec result
    elif c == '#': break
    inc i

func balanced(b: Buffer, l0, l1: int): bool =
  ## do lines l0..l1 close every bracket they open (outside quotes and # comments)?
  var depth = 0
  for l in l0 .. l1:
    let s = b.lines[l]
    var q = '\0'
    var i = 0
    while i < s.len:
      let c = s[i]
      if q != '\0':
        if c == '\\': inc i
        elif c == q: q = '\0'
      elif c in {'"', '\''}: q = c
      elif c in {'(', '[', '{'}: inc depth
      elif c in {')', ']', '}'}:
        dec depth
        if depth < 0: return false
      elif c == '#' or (c == '/' and i + 1 < s.len and s[i + 1] == '/'): break
      inc i
  depth == 0

func continues(s: string): bool =
  ## does a statement go on below this line (an operator, a comma or an open bracket at its end)?
  let t = codeEnd(s)
  if t.len == 0: return false
  if t[^1] in {',', '(', '[', '+', '-', '*', '/', '&', '|', '\\', '.'}: return true
  if t[^1] == '=' and not t.endsWith("==") and not t.endsWith("<=") and not t.endsWith(">="): return false
  for w in [" and", " or", " xor", " not", " in", " notin", " is", " isnot", " &&", " ||"]:
    if t.endsWith(w): return true
  false

proc statementRange(b: Buffer, l0, l1: int): (int, int) =
  ## the lines of the statement(s) around l0..l1: up while the line above goes on, down while a line goes on or
  ## leaves a bracket open
  var s = l0
  while s > 0 and not isBlank(b.lines[s - 1]) and continues(b.lines[s - 1]): dec s
  var depth = 0
  var e = s
  while true:
    depth += openCount(b.lines[e])
    if e >= l1 and depth <= 0 and not continues(b.lines[e]): break
    if e >= b.lines.high: break
    inc e
  (s, e)

proc structuralCands(b: Buffer, a, e: Pos): seq[(Pos, Pos)] =
  ## the pieces of code around a..e, found from brackets, quotes and indentation so that it works for every language:
  ## the steps of a member chain (name, its call brackets, what is before and after a dot), what each kind of enclosing
  ## bracket holds and the bracket pair itself, each argument between commas, the statement over its continuation lines,
  ## the value after its `=`, then the enclosing blocks — each alone and with its header — up to the top-level
  ## declaration with the comments above it
  let la = a.line
  # a member chain, a step at a time: a name, its call (name(…) / name[…]), what comes before its dot, .d after
  block chain:
    if a.line != e.line: break chain
    let s = b.lines[la]
    var x = a.col
    var y = e.col
    if x == y:
      let (wa, we) = b.wordRangeAt(a)
      x = wa.col
      y = we.col
    if x >= y: break chain
    for _ in 0 ..< 32:
      var moved = false
      if x > 0 and s[x] in {'(', '['} and isWordByte(s[x - 1]):
        # (a call's brackets: with its name)
        var k = x - 1
        while k >= 0 and isWordByte(s[k]): dec k
        x = k + 1
        moved = true
      elif y < s.len and s[y] in {'(', '['} and y > 0 and isWordByte(s[y - 1]):
        let (ok, _, ce) = b.matchBracket(Pos(line: la, col: y))
        if not ok or ce.line != la: break
        y = ce.col + 1
        moved = true
      elif x >= 2 and s[x - 1] == '.' and (isWordByte(s[x - 2]) or s[x - 2] in {')', ']'}):
        var k = x - 2
        if s[k] in {')', ']'}:
          let (ok, oa, _) = b.matchBracket(Pos(line: la, col: k))
          if not ok or oa.line != la: break
          k = oa.col - 1
        while k >= 0 and isWordByte(s[k]): dec k
        x = k + 1
        moved = true
      elif y + 1 < s.len and s[y] == '.' and isWordByte(s[y + 1]):
        var k = y + 1
        while k < s.len and isWordByte(s[k]): inc k
        y = k
        moved = true
      if not moved: break
      result.add (Pos(line: la, col: x), Pos(line: la, col: y))
  # what brackets hold, and the brackets; one argument between their commas
  for obj in ['(', '[', '{']:
    let (ok, x, y) = b.enclosingPair(a, e, obj)
    if not ok: continue
    result.add (x, y)
    var ia = Pos(line: x.line, col: x.col + 1)
    var ie = Pos(line: y.line, col: y.col - 1)
    if x.line < y.line and b.lines[x.line][x.col + 1 .. ^1].strip.len == 0 and
       b.lines[y.line][0 ..< y.col - 1].strip.len == 0 and y.line - x.line >= 2:
      # (a block in braces over lines: its lines, without the braces' line ends)
      result.add (Pos(line: x.line + 1, col: selIndent(b.lines[x.line + 1])), Pos(line: y.line - 1, col: b.lines[y.line - 1].len))
    else: result.add (ia, ie)
    # the argument: commas at this depth between ia and ie
    var parts: seq[(Pos, Pos)]
    var start = ia
    var depth = 0
    var q = '\0'
    var l = ia.line
    var c = ia.col
    while l < ie.line or (l == ie.line and c < ie.col):
      let t = b.lines[l]
      if c >= t.len:
        inc l
        c = 0
        continue
      let ch = t[c]
      if q != '\0':
        if ch == '\\': inc c
        elif ch == q: q = '\0'
      elif ch in {'"', '\''}: q = ch
      elif ch in {'(', '[', '{'}: inc depth
      elif ch in {')', ']', '}'}: dec depth
      elif ch == ',' and depth == 0:
        parts.add (start, Pos(line: l, col: c))
        start = Pos(line: l, col: c + 1)
      inc c
    parts.add (start, ie)
    if parts.len > 1:
      for (pa, pe) in parts:
        var x0 = pa
        var y0 = pe
        while x0 < y0 and x0.col < b.lines[x0.line].len and b.lines[x0.line][x0.col] in {' ', '\t'}: inc x0.col
        if x0.col >= b.lines[x0.line].len and x0.line < y0.line: x0 = Pos(line: x0.line + 1, col: selIndent(b.lines[x0.line + 1]))
        while y0.col > 0 and y0 > x0 and b.lines[y0.line][y0.col - 1] in {' ', '\t'}: dec y0.col
        if x0 <= a and e <= y0 and x0 < y0: result.add (x0, y0)
  # the statement, and the value after its `=`
  let (sl, el) = b.statementRange(a.line, e.line)
  let stA = Pos(line: sl, col: selIndent(b.lines[sl]))
  let stE = Pos(line: el, col: codeEnd(b.lines[el]).len)
  if stA < stE: result.add (stA, stE)
  block value:
    let t = b.lines[sl]
    var k = stA.col
    var depth = 0
    var q = '\0'
    while k < t.len:
      let ch = t[k]
      if q != '\0':
        if ch == '\\': inc k
        elif ch == q: q = '\0'
      elif ch in {'"', '\''}: q = ch
      elif ch in {'(', '['}: inc depth
      elif ch in {')', ']'}: dec depth
      elif ch == '=' and depth == 0 and (k + 1 >= t.len or t[k + 1] notin {'=', '>'}) and
           (k == 0 or t[k - 1] notin {'=', '<', '>', '!', ':', '+', '-', '*', '/', '&', '|', '.'}):
        var v = k + 1
        while v < t.len and t[v] == ' ': inc v
        if v < t.len:
          let va = Pos(line: sl, col: v)
          if va <= a: result.add (va, stE)
        break
      inc k
  # the block the statement is in, then with its header; the top-level declaration with the comments above it
  var ind = selIndent(b.lines[sl])
  var top = sl
  var bottom = el
  for _ in 0 ..< 12:
    var u = top
    while u > 0:
      if isBlank(b.lines[u - 1]):
        dec u
        continue
      # (a statement over lines above: where it starts decides — a header's continuation lines are not the block's)
      let (s0, _) = b.statementRange(u - 1, u - 1)
      if selIndent(b.lines[s0]) < ind: break
      u = s0
    while u < top and isBlank(b.lines[u]): inc u
    var d = bottom
    while d < b.lines.high and (isBlank(b.lines[d + 1]) or selIndent(b.lines[d + 1]) >= ind): inc d
    while d > bottom and isBlank(b.lines[d]): dec d
    if ind > 0: result.add (Pos(line: u, col: selIndent(b.lines[u])), Pos(line: d, col: b.lines[d].len))
    # its header: the line above with less indentation (a closing brace below it, for brace languages)
    if u == 0 or ind == 0: break
    let h = u - 1
    var hd = d
    if hd + 1 <= b.lines.high and b.lines[hd + 1].strip.len > 0 and b.lines[hd + 1].strip[0] in {'}', ')', ']'} and
       selIndent(b.lines[hd + 1]) < ind:
      inc hd
    let (hs, _) = b.statementRange(h, h)
    result.add (Pos(line: hs, col: selIndent(b.lines[hs])), Pos(line: hd, col: b.lines[hd].len))
    top = hs
    bottom = hd
    ind = selIndent(b.lines[hs])
    if ind == 0:
      # a top-level declaration: with the comments right above it
      var c = hs
      while c > 0 and b.lines[c - 1].strip.len > 0 and
            (b.lines[c - 1].strip.startsWith("#") or b.lines[c - 1].strip.startsWith("//") or
             b.lines[c - 1].strip.startsWith("/*") or b.lines[c - 1].strip.startsWith("*")):
        dec c
      if c < hs: result.add (Pos(line: c, col: 0), Pos(line: hd, col: b.lines[hd].len))
      break

proc selectionCands(b: Buffer, a, e: Pos, head: Pos): seq[(Pos, Pos)] =
  ## the pieces of code a selection a..e (its cursor at `head`) can grow to: the word, a string, an argument, the
  ## expression, the statement, the blocks around it with their headers, the file — in no order
  var cands: seq[(Pos, Pos)]
  let (wa, we) = b.wordRangeAt(head)
  if wa != we: cands.add (wa, we)
  for obj in ['"', '\'', '`']:
    for kind in ['i', 'a']:
      let (ok, x, y) = b.textObject(kind, obj, head)
      if ok and x != y: cands.add (x, y)
  # (a selection ending at the start of a line ends at the end of the line before it, for the pieces of code)
  let eL = if e.col == 0 and e.line > a.line: Pos(line: e.line - 1, col: b.lines[e.line - 1].len) else: e
  try: cands.add b.structuralCands(a, eL)
  except CatchableError, Defect: discard
  if b.balanced(a.line, eL.line):
    cands.add (Pos(line: a.line, col: leadingWs(b.lines[a.line]).len), Pos(line: eL.line, col: b.lines[eL.line].len))
  let h = b.foldHeaderFor(a.line)
  if h >= 0:
    let (_, fe) = b.foldRange(h)
    cands.add (Pos(line: h, col: selIndent(b.lines[h])), Pos(line: fe, col: b.lines[fe].len))
  cands.add (Pos(), Pos(line: b.lines.high, col: b.lines[^1].len))
  cands

proc expandSelection() =
  ## the selection grows to the next piece of code around it (shrinkSelection goes back)
  let b = buf()
  let (a, e) = b.primary.range
  let cands = b.selectionCands(a, e, b.primary.head)
  var best = (Pos(line: -1), Pos())
  var bestSize = high(int)
  for (x0, y0) in cands:
    let x = b.clampPos(x0)
    let y = b.clampPos(y0)
    if x <= a and e <= y and (x < a or e < y):
      # (the size in characters: a piece over two short lines is smaller than one long line)
      var size = 0
      if x.line == y.line: size = y.col - x.col
      else:
        size = b.lines[x.line].len - x.col + y.col
        for l in x.line + 1 ..< y.line: size += b.lines[l].len + 1
      if size < bestSize:
        bestSize = size
        best = (x, y)
  if best[0].line < 0: return
  selStack.add b.cursors
  b.setSingle(best[1], best[0])

proc shrinkSelection() =
  ## undoes the last expandSelection: restores the cursors saved before it grew
  if selStack.len == 0: return
  let b = buf()
  b.cursors = selStack.pop()
  b.prim = 0
  b.normalize()
