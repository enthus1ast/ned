# the find and replace commands: counting the matches, finding as you type, stepping to the next or previous match,
# replacing all at once and asking match by match
proc countMatches() =
  ## counts the matches of the find query in the whole buffer (findTotal) and which of them the selection is at
  ## (findIdx); it gives up on a very big file after 25 ms or 100000 matches and marks the count as capped
  let b = buf()
  findTotal = 0
  findIdx = 0
  if findQuery.len == 0: return
  let s0 = b.primary.range[0]
  findCapped = false
  let t0 = getMonoTime()
  if findRegex and cachedRegex(findQuery, findCase)[].err.len > 0: return
  for l in 0 ..< b.lines.len:
    if b.lines[l].len >= findQuery.len or findRegex:
      for (j, _) in findSpans(b.lines[l], findQuery, findCase, findWord, findRegex):
        inc findTotal
        if l == s0.line and j == s0.col: findIdx = findTotal
    if (l and 4095) == 4095 and msSince(t0) > 25:
      findCapped = true
      break
    if findTotal > 99999:
      findCapped = true
      break

proc findIncremental() =
  ## as the find box is typed in: selects the first match from where the search began (an empty query puts the cursors
  ## back there) and updates the count
  let b = buf()
  findQuery = promptText
  if findQuery.len == 0:
    if findOrigin.len > 0: b.cursors = findOrigin
    b.normalize()
    countMatches()
    return
  let start = if findOrigin.len > 0: findOrigin[0].range[0] else: b.primary.range[0]
  let (ok, a, e) = b.searchFrom(findQuery, start, true, findCase, findWord, findRegex)
  if ok: b.setSingle(e, a)
  countMatches()

proc findStep(forward: bool) =
  ## goes to the next (or previous) match and selects it, with `n/total` in the message. With no query yet it takes the
  ## selected text or the word at the cursor. A file in the large-file viewer is searched by the viewer in the
  ## background.
  let b = buf()
  if findQuery.len == 0:
    let (a, e) = b.primary.range
    findQuery = if a != e and a.line == e.line: b.getText(a, e) else: b.wordAt(b.primary.head)
    if findQuery.len == 0:
      info("Nothing to find")
      return
  if b.viewer != nil:
    b.lfFind(findQuery, forward)                # (the viewer: the whole file, in the background)
    return
  let (s, e) = b.primary.range
  var frm = if forward: e else: s
  if findRegex and forward and s == e:
    frm = if e.col < b.lines[e.line].len: Pos(line: e.line, col: e.col + 1)
          else: Pos(line: (e.line + 1) mod b.lines.len, col: 0)
  let (ok, a, e2) = b.searchFrom(findQuery, frm, forward, findCase, findWord, findRegex)
  if ok:
    b.setSingle(e2, a)
    countMatches()
    if promptKind == pNone: info("\"" & findQuery & "\"  " & $findIdx & "/" & $findTotal)
  else:
    info("No matches for \"" & findQuery & "\"")

proc replacementFor(line, q, r: string, a, e: int, caseS, rx: bool): string =
  ## the text that replaces the match line[a ..< e] ($1 … groups when it is a regex)
  if not rx: return r
  let re = cachedRegex(q, caseS)
  var caps: seq[int]
  if re[].reSearch(line, a, caps) and caps[0] == a: reExpand(r, line, caps, re[].ncap) else: r

proc replaceAllIn(b: Buffer, q, r: string, caseS, word: bool, rx = false): int =
  ## replaces every match of `q` in the buffer with `r` (a regular expression's groups expanded) as one undo step,
  ## working from the last line up so positions stay valid; gives the number replaced
  if q.len == 0 or not b.canEdit(): return 0
  if rx and cachedRegex(q, caseS)[].err.len > 0: return 0
  b.beginEdit()
  for l in countdown(b.lines.high, 0):
    let line = b.lines[l]
    let hits = findSpans(line, q, caseS, word, rx)
    for h in countdown(hits.high, 0):
      let (a, e) = hits[h]
      discard b.replaceText(Pos(line: l, col: a), Pos(line: l, col: e), replacementFor(line, q, r, a, e, caseS, rx))
      inc result
  b.endEdit()
  b.normalize()

proc replaceNext(fromPos: Pos): bool =
  ## selects the next match for the replace query from `fromPos`; with none left it ends the replacing, says how many
  ## were replaced and gives false
  let b = buf()
  let (ok, a, e) = b.searchFrom(replaceQuery, fromPos, true, findCase, findWord, findRegex)
  if not ok:
    replaceActive = false
    info("Replaced " & $replaceCount & " occurrence(s)")
    return false
  b.setSingle(e, a)
  true

proc replaceKey(k: Key) =
  ## a key while replacing match by match: y or space replaces this match and moves to the next, n skips it, a or !
  ## replaces all the rest, q or Esc stops; the message says how many were replaced
  let b = buf()
  if k.kind == kEsc:
    replaceActive = false
    info("Replaced " & $replaceCount & " occurrence(s)")
    return
  if k.kind != kChar: return
  case (if k.ch in 0 .. 127: char(k.ch) else: '\0')
  of 'y', 'Y', ' ':
    let (a, e) = b.primary.range
    let rep = if a.line == e.line: replacementFor(b.lines[a.line], replaceQuery, replaceWith, a.col, e.col,
                                                  findCase, findRegex) else: replaceWith
    b.beginEdit()
    var p = b.replaceText(a, e, rep)
    b.endEdit()
    inc replaceCount
    if a == e:                                         # an empty regex match: move past it
      p = if p.col < b.lines[p.line].len: Pos(line: p.line, col: p.col + utf8Len(b.lines[p.line][p.col]))
          elif p.line < b.lines.high: Pos(line: p.line + 1, col: 0)
          else: p
      if a == e and p.line == b.lines.high and p.col >= b.lines[p.line].len:
        replaceActive = false
        info("Replaced " & $replaceCount & " occurrence(s)")
        return
    discard replaceNext(b.clampPos(p))
  of 'n', 'N':
    discard replaceNext(b.primary.range[1])
  of 'a', 'A', '!':
    replaceCount += b.replaceAllIn(replaceQuery, replaceWith, findCase, findWord, findRegex)
    replaceActive = false
    info("Replaced " & $replaceCount & " occurrence(s)")
  of 'q', 'Q':
    replaceActive = false
    info("Replaced " & $replaceCount & " occurrence(s)")
  else: discard
