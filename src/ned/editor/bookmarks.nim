# ════════════════════════════════════════════════════════════════════════════
#  ned 4: bookmarks · local history · crash recovery · git changes & blame
# ════════════════════════════════════════════════════════════════════════════

proc gotoBufLine(id, line: int) =
  ## goes to a line of the open buffer with this id: remembers where it was (for jumping back), makes that buffer
  ## current, focuses the editor and centres the cursor on the line, after its indentation
  for i, b in bufs:
    if b.id == id:
      pushJump()
      curBuf = i
      focus = fEditor
      let l = clamp(line, 0, b.lines.high)
      b.centerOn(Pos(line: l, col: leadingWs(b.lines[l]).len))
      return

# ── bookmarks ──

proc toggleBookmark() =
  ## puts a bookmark on the cursor's line, or takes it off when there is one; a saved file's bookmarks are also kept in
  ## savedMarks, for the session
  let b = buf()
  if b.isWelcome(): return
  let l = b.primary.head.line
  let i = b.marks.find(l)
  if i >= 0:
    b.marks.delete(i)
    info("Bookmark removed")
  else:
    b.marks.add l
    b.marks.sort()
    info("Bookmark on line " & $(l + 1) & "  ·  Alt+; next  ·  Alt+: previous  ·  palette › Bookmarks")
  if b.path.len > 0: savedMarks[b.path] = b.marks

proc allBookmarks(): seq[(int, int)] =
  ## (buffer index, line) in tab order
  for i, b in bufs:
    var ms = b.marks
    ms.sort()
    for m in ms:
      if m < b.lines.len: result.add (i, m)

proc gotoBookmark(d: int) =
  ## jumps to the next bookmark (d > 0) or the previous one, over all open buffers in tab order, wrapping round at the
  ## ends
  let all = allBookmarks()
  if all.len == 0:
    info("No bookmarks — Alt+' toggles one on the current line")
    return
  let here = (curBuf, buf().primary.head.line)
  var pick = -1
  if d > 0:
    for k, m in all:
      if m[0] > here[0] or (m[0] == here[0] and m[1] > here[1]):
        pick = k
        break
    if pick < 0: pick = 0
  else:
    for k in countdown(all.high, 0):
      let m = all[k]
      if m[0] < here[0] or (m[0] == here[0] and m[1] < here[1]):
        pick = k
        break
    if pick < 0: pick = all.high
  let (bi, l) = all[pick]
  gotoBufLine(bufs[bi].id, l)

proc bookmarkAct(id, line: int): Action =
  ## an action that jumps to the line of a buffer — made here so each list row keeps its own values
  result = proc() = gotoBufLine(id, line)

proc listBookmarks() =
  ## palette command: lists every bookmark (file, line and the line's text) and jumps to the one picked
  var items: seq[(string, string, Action)]
  for (bi, l) in allBookmarks():
    let b = bufs[bi]
    items.add act(b.name & ":" & $(l + 1) & "   " & b.lines[l].strip, relPath(b.path), bookmarkAct(b.id, l))
  if items.len == 0:
    info("No bookmarks — Alt+' toggles one on the current line")
    return
  openActions("Bookmarks", items)

proc clearBookmarks() =
  ## palette command: removes the bookmarks of every open buffer, and the saved ones
  for b in bufs:
    b.marks.setLen(0)
    if b.path.len > 0: savedMarks.del b.path
  info("Bookmarks cleared")
