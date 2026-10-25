# ════════════════════════════════════════════════════════════════════════════
#  Input handling
# ════════════════════════════════════════════════════════════════════════════

proc dirPrefix(dir: string): string =
  if dir == rootDir: "" else: relPath(dir) & "/"

proc treeKey(k: Key) =
  if treeRows.len == 0: flattenTree()
  let n = if treeSel >= 0 and treeSel < treeRows.len: treeRows[treeSel] else: nil
  let rows = max(1, scrH - 4)
  template activate() =
    if n != nil:
      if n.isDir:
        n.expanded = not n.expanded
        flattenTree()
      else:
        discard openFile(n.path)
  case k.kind
  of kUp: treeSel = max(0, treeSel - 1)
  of kDown: treeSel = min(max(0, treeRows.high), treeSel + 1)
  of kPgUp: treeSel = max(0, treeSel - rows)
  of kPgDn: treeSel = min(max(0, treeRows.high), treeSel + rows)
  of kHome: treeSel = 0
  of kEnd: treeSel = max(0, treeRows.high)
  of kEnter: activate()
  of kRight:
    if n != nil and n.isDir and not n.expanded:
      n.expanded = true
      flattenTree()
    elif n != nil and not n.isDir: discard openFile(n.path)
  of kLeft:
    if n != nil and n.isDir and n.expanded:
      n.expanded = false
      flattenTree()
    elif n != nil:
      for i in countdown(treeSel - 1, 0):
        if treeRows[i].depth < n.depth:
          treeSel = i
          break
  of kEsc:
    focus = fEditor
    if scrW < 70: treeOpen = false
  of kDelete:
    if n != nil:
      askConfirm("Delete " & relPath(n.path) & (if n.isDir: " and everything in it" else: "") & remoteToo(n.path) &
                 "? (y/n)",
        proc(c: char) =
          if c == 'y':
            try:
              if n.isDir: removeDir(n.path) else: removeFile(n.path)
              remoteFileOp("rm", n.path)
              refreshTree()
              info("Deleted " & n.name)
            except CatchableError as e: error(e.msg))
  of kChar:
    if k.mods != {}: return
    let dir = if n == nil: rootDir elif n.isDir: n.path else: parentDir(n.path)
    case (if k.ch in 0 .. 127: char(k.ch) else: '\0')
    of 'j': treeSel = min(max(0, treeRows.high), treeSel + 1)
    of 'k': treeSel = max(0, treeSel - 1)
    of 'l', 'o': activate()
    of 'h':
      var kk = k
      kk.kind = kLeft
      treeKey(kk)
    of 'n', 'a': openPrompt(pNewFile, "New file", dirPrefix(dir))
    of 'f', 'A': openPrompt(pNewFolder, "New folder", dirPrefix(dir))
    of 'r':
      if n != nil:
        treeTarget = n.path
        openPrompt(pRenamePath, "Rename to", relPath(n.path))
    of 'd':
      var kk = k
      kk.kind = kDelete
      treeKey(kk)
    of 'R':
      refreshTree()
      info("Tree refreshed")
    of '.':
      showHidden = not showHidden
      refreshTree()
      info("Hidden files " & (if showHidden: "shown" else: "hidden"))
    of 'q':
      treeOpen = false
      focus = fEditor
    else: discard
  else: discard

proc panelJump(i: int) =
  if i < 0 or i >= panelLines.len: return
  let pl = panelLines[i]
  if pl.path.startsWith("dbg:"):
    dbgPanelAction(pl.path)
    return
  if pl.path.startsWith("dep:"):
    let k = (try: parseInt(pl.path[4 .. ^1]) except ValueError: -1)
    if k >= 0 and k < depActs.len and depActs[k] != nil: depActs[k]()
    return
  if pl.path.len == 0 or pl.line < 0: return
  pushJump()
  let b = openFile(pl.path)
  if b != nil:
    b.centerOn(b.clampPos(Pos(line: pl.line, col: pl.col)))
    if pl.sev in {1, 2}: setMsg(pl.text.strip, pl.sev)
  focus = fEditor

proc panelKey(k: Key) =
  let rows = max(1, scrH div 3 - 1)
  case k.kind
  of kUp, kDown, kPgUp, kPgDn, kHome, kEnd:
    panelFollow = false
    let d = case k.kind
      of kUp: -1
      of kDown: 1
      of kPgUp: -rows
      of kPgDn: rows
      of kHome: -panelLines.len
      else: panelLines.len
    panelSel = clamp(panelSel + d, 0, max(0, panelLines.high))
  of kEnter: panelJump(panelSel)
  of kEsc: focus = fEditor
  of kChar:
    if mCtrl in k.mods and k.ch == ord('c'): stopRun()
    elif k.mods == {}:
      case (if k.ch in 0 .. 127: char(k.ch) else: '\0')
      of 'j': panelSel = min(max(0, panelLines.high), panelSel + 1)
      of 'k': panelSel = max(0, panelSel - 1)
      of 'q':
        panelOpen = false
        focus = fEditor
      else: discard
  else: discard

proc inlayAdjust(b: Buffer, line, tx: int, segStart = 0, segEnd = high(int)): int =
  ## screen column → text column on a line (the row of it from segStart) that is drawn with inlay hints
  let s = b.lines[line]
  var shift = 0
  var toks: seq[TokKind]
  if s.len <= 20000:
    let (st, _) = b.stateAt(line)
    discard lexLine(b.lang, s, st, toks)
  let sw = if cfgSwatches and s.len <= 4000 and b.lang.mode != lmDiff: colourSwatches(b.lang, s, toks) else: @[]
  var decor = b.lineDecor(line, toks, sw)
  var hw = 0
  for (_, lb) in decor: hw += strWidth(lb)
  if cfgWrap and (b.lineSegs(line).len > 1 or visColOf(s, s.len) + hw > textW):
    var keep: seq[(int, string)]
    for h in decor:
      if h[1] != SwatchMark: keep.add h
    decor = keep
  let base = if cfgWrap: visColOf(s, segStart) else: b.leftCol
  for (col, label) in decor:
    if cfgWrap and (col < segStart or (col >= segEnd and segEnd < s.len)): continue
    let hv = visColOf(s, min(col, s.len)) - base
    let w = strWidth(label)
    if tx >= hv + shift + w: shift += w
    elif tx >= hv + shift: return hv
    else: break
  tx - shift

proc editorPosAt(x, y: int): (bool, Pos) =
  let b = buf()
  let (ex, ey, ew, eh) = editorRect
  if x < ex or x >= ex + ew or y < ey or y >= ey + eh: return (false, Pos())
  var row = y - ey
  var line = b.topLine
  var sub = b.topSub
  while line < b.lines.len:
    let s = b.lines[line]
    let segs = b.lineSegs(line)
    let vr = b.vrowCount(line)
    if row >= segs.len - sub and row < segs.len + vr - sub:
      return (true, Pos(line: line, col: s.len))        # (a row under the line — a cell's output: its end)
    let n = segs.len - sub
    if row < n:
      let si = sub + row
      let segStart = segs[si]
      var tx = x - (ex + gutterW) - (if si > 0: contIndent(s, textW) else: 0)
      if tx < 0: return (true, Pos(line: line, col: segStart))
      if line in inlayShown: tx = inlayAdjust(b, line, tx, segStart, (if si + 1 < segs.len: segs[si + 1] else: s.len))
      var col: int
      if cfgWrap:
        let baseVc = visColOf(s, segStart)
        col = colAtVis(s, baseVc + tx, segStart, baseVc)
      else:
        col = colAtVis(s, b.leftCol + tx)
      if si + 1 < segs.len and col >= segs[si + 1]: col = prevRune(s, segs[si + 1])
      return (true, Pos(line: line, col: col))
    row -= max(0, segs.len + vr - sub)
    line = if b.folds.len > 0: b.nextVisible(line) else: line + 1
    sub = 0
  (true, Pos(line: b.lines.high, col: b.lines[^1].len))


proc editorKey(k: Key)
