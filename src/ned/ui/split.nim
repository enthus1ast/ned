# ── split editor ──

func snapView(b: Buffer): ViewSnap =
  ViewSnap(topLine: b.topLine, topSub: b.topSub, leftCol: b.leftCol, prim: b.prim, cursors: b.cursors,
           lastHead: b.lastHead, lastChange: b.lastChange)

proc applyView(b: Buffer, v: ViewSnap) =
  b.topLine = clamp(v.topLine, 0, b.lines.high)
  b.topSub = v.topSub
  b.leftCol = v.leftCol
  if v.cursors.len > 0:
    b.cursors = v.cursors
    b.prim = clamp(v.prim, 0, v.cursors.high)
  b.lastHead = v.lastHead
  b.lastChange = v.lastChange
  b.normalize()

proc paneAt(x, y: int): int =
  if not splitOn: return -1
  for i in 0 .. 1:
    let r = panes[i].rect
    if r.w > 0 and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h: return i
  -1

proc focusPane(i: int) =
  ## make pane `i` the active one: its buffer becomes `curBuf` with that pane's cursors and scroll
  if not splitOn or i == activePane or i notin 0 .. 1: return
  let cur = buf()
  panes[activePane].bufId = cur.id
  panes[activePane].snap = snapView(cur)
  activePane = i
  var bi = -1
  for k, x in bufs:
    if x.id == panes[i].bufId: bi = k
  if bi >= 0:
    curBuf = bi
    applyView(bufs[bi], panes[i].snap)
  else:
    panes[i].bufId = cur.id
  # geometry of the new active pane until the next frame (mouse hit-testing, scrolling)
  let r = panes[i].rect
  editorRect = (r.x, r.y + 1, r.w, max(1, r.h - 1))
  gutterW = panes[i].gutterW
  textW = panes[i].textW
  textH = panes[i].textH
  closeComp()
  hoverOpen = false
  focus = fEditor
  needRender = true

proc splitEditor(down: bool) =
  let b = buf()
  if b.isWelcome():
    info("Open a file first")
    return
  if splitOn:
    splitDown = down
    needRender = true
    return
  splitOn = true
  splitDown = down
  # the new pane (right / below) shows the same file and gets the focus, like VS Code
  panes[0] = Pane(bufId: b.id, snap: snapView(b))
  panes[1] = Pane(bufId: b.id, snap: snapView(b))
  activePane = 1
  focus = fEditor
  info("Split editor — Alt+\\ switches panes, click a pane to focus it, Alt+| closes the split")

proc closeSplit() =
  if not splitOn: return
  splitOn = false
  activePane = 0
  needRender = true

proc toggleSplitFocus() =
  if splitOn: focusPane(1 - activePane) else: splitEditor()

proc toSidePane() =
  ## (Open to the side) the other pane gets the focus — split first: what this pane shows stays there
  if splitOn: focusPane(1 - activePane)
  elif bufs.len > 0 and not buf().isWelcome(): splitEditor(false)   # (the new pane, the focus: the same file for now)

proc openToSide(path: string, line = -1, col = -1): Buffer =
  toSidePane()
  openFile(path, line, col)

proc moveToOtherPane() =
  ## show the current file in the other pane too (split first when needed)
  let b = buf()
  if not splitOn:
    splitEditor()
    return
  let o = 1 - activePane
  panes[o].bufId = b.id
  panes[o].snap = snapView(b)
  focusPane(o)

proc drawPaneHeader(b: Buffer, i, x, y, w: int) =
  if ceIsView(b):
    ceDrawHeader(b, i, x, y, w)                 # (Compiler Explorer's view: its toolbar)
    return
  let active = i == activePane
  let bg = if active: theme.crumbBg else: theme.splitBar      # never the editor's own background
  fillRect(x, y, w, 1, theme.dim, bg)
  if active: discard putStr(x, y, "▎", theme.accent, bg)
  var xx = x + 1
  let lim = x + w - 3
  if b.path.len > 0: xx = putStr(xx, y, fileIcon(b.path), langColor(b.path), bg, {}, lim) + 1
  xx = putStr(xx, y, b.name & (if b.dirty: " " & ic("dirty") else: ""), (if active: theme.fg else: theme.dim),
              bg, (if active: {aBold} else: {}), lim)
  if b.path.len > 0 and xx + 4 < lim:
    let dir = relPath(parentDir(b.path))
    if dir.len > 0 and dir != ".":
      discard putStr(xx + 2, y, truncTo(dir, max(1, lim - xx - 2)), blend(theme.dim, bg, 0.3), bg, {}, lim)
  let pi = i
  capture pi:
    region(x, y, max(1, w - 2), 1, proc() = focusPane(pi), "", proc() = ctxOpen(paneHeaderMenu(pi)))
    discard button(x + w - 2, y, ic("close"), proc() =
      if pi == activePane: focusPane(1 - pi)     # the other pane stays
      closeSplit(), "Close this pane (Alt+|)", theme.dim, bg)

proc drawSplit(): bool =
  ## both panes; the inactive one first so the active pane's geometry (editorRect, gutterW, textW …)
  ## is what the mouse and scrolling code see afterwards. false = nothing to split any more.
  let other = 1 - activePane
  let ob = bufById(panes[other].bufId)
  if ob == nil:
    splitOn = false
    return false
  let top = if lay.crumbY >= 0: lay.crumbY else: lay.textY
  let fullH = lay.textY + lay.textH - top
  let stacked = splitDown or lay.edW < 60
  var rects: array[2, tuple[x, y, w, h: int]]
  if stacked:
    # one above the other: a solid divider row between them, like the bar between side-by-side panes
    let h0 = if fullH >= 9: clamp(int(float(fullH - 1) * splitRatio), 3, fullH - 4) else: max(2, (fullH - 1) div 2)
    rects[0] = (lay.edX, top, lay.edW, h0)
    rects[1] = (lay.edX, top + h0 + 1, lay.edW, max(2, fullH - h0 - 1))
    let dc = if dragTarget == dtSplit: theme.accent else: blend(theme.splitBar, theme.fg, 0.45)
    for xx in lay.edX ..< lay.edX + lay.edW:
      setCell(xx, top + h0, Cell(ch: 0x2500, fg: dc, bg: theme.splitBar))
    splitDiv = (lay.edX, top + h0, lay.edW, false)
  else:
    let w0 = if lay.edW >= 40: clamp(int(float(lay.edW - 1) * splitRatio), 14, lay.edW - 15) else: (lay.edW - 1) div 2
    rects[0] = (lay.edX, top, w0, fullH)
    rects[1] = (lay.edX + w0 + 1, top, lay.edW - w0 - 1, fullH)
    let dc = if dragTarget == dtSplit: theme.accent else: blend(theme.splitBar, theme.fg, 0.45)
    for yy in top ..< top + fullH:
      setCell(lay.edX + w0, yy, Cell(ch: 0x2502, fg: dc, bg: theme.splitBar))
    splitDiv = (lay.edX + w0, top, fullH, true)
  for i in [other, activePane]:
    let r = rects[i]
    let pb = if i == activePane: buf() else: ob
    var saved: ViewSnap
    if i != activePane:
      saved = snapView(pb)
      applyView(pb, panes[i].snap)
    drawPaneHeader(pb, i, r.x, r.y, r.w)
    drawEditor(pb, r.x, r.y + 1, r.w, max(1, r.h - 1), i == activePane)
    panes[i].rect = r
    panes[i].gutterW = gutterW
    panes[i].textW = textW
    panes[i].textH = textH
    if i != activePane:
      panes[i].snap = snapView(pb)
      applyView(pb, saved)
    else: panes[i].bufId = pb.id
  true

proc layoutState(): JsonNode =
  result = %*{"left": treeOpen, "leftView": $sideView, "right": rightOpen, "rightView": $rightView,
              "panel": panelOpen, "panelKind": $panelKind}
  if splitOn:
    let ob = bufById(panes[1 - activePane].bufId)
    if ob != nil and ob.path.len > 0:
      result["split"] = %*{"down": splitDown, "other": ob.path, "active": activePane}

proc restoreLayout() =
  if savedLayout.isNil or not sBool("ui.restoreLayout") or scrW < 70: return
  try:
    for v in SideView:
      if $v == savedLayout{"leftView"}.getStr: sideView = v
      if $v == savedLayout{"rightView"}.getStr: rightView = v
    if sideView in RightViews: sideView = svFiles
    if rightView in LeftViews: rightView = svAssistant
    treeOpen = savedLayout{"left"}.getBool
    rightOpen = savedLayout{"right"}.getBool
    for k in PanelKind:
      if $k == savedLayout{"panelKind"}.getStr and k != pkSearch: panelKind = k
    if savedLayout{"panel"}.getBool and panelKind != pkTerminal: panelOpen = true
    if treeOpen and sideView == svFiles: flattenTree()
    let sp = savedLayout{"split"}
    if sp != nil and not buf().isWelcome():
      let i = bufIndexByPath(sp{"other"}.getStr)
      if i >= 0 and i != curBuf:
        let b = buf()
        splitOn = true
        splitDown = sp{"down"}.getBool
        activePane = clamp(sp{"active"}.getInt, 0, 1)
        panes[activePane] = Pane(bufId: b.id, snap: snapView(b))
        panes[1 - activePane] = Pane(bufId: bufs[i].id, snap: snapView(bufs[i]))
  except CatchableError: discard
