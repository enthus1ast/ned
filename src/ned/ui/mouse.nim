# ── drag handles (split divider, dock edges, bottom panel, scrollbar) and sizes from the keyboard ──

proc dragHandleAt(x, y: int): DragTarget =
  ## which draggable edge or bar is at that screen place: a split divider (remembering which), a dock's edge, the bottom
  ## panel's header, the editor's scroll bar (the column before it too on Termux, where a finger is wider than a column)
  ## or the minimap; dtNone when none
  for k, d in splitDivs:
    if (d.vertical and x == d.x and y >= d.y and y < d.y + d.len) or
       (not d.vertical and y == d.y and x >= d.x and x < d.x + d.len):
      if dragTarget != dtSplit:                     # (which divider a press takes; not changed during a drag)
        dragDiv = k
        dragNode = d.node
      return dtSplit
  if not lay.overlay and y >= lay.bodyTop and y < lay.bodyBot:
    if treeOpen and x == lay.leftW: return dtLeftDock
    if rightOpen and lay.rightW > 0 and not lay.rightFloat and x == lay.rightX - 1: return dtRightDock
  if panelTopY >= 0 and y == panelTopY and x >= lay.edX and x < lay.edX + lay.edW and hitRegion(x, y) < 0:
    return dtPanel
  # (the scroll bar: on a touch screen — Termux — the column before it too, a finger is wider than a column)
  if sbCol >= 0 and (x == sbCol or (x == sbCol - 1 and isTermux())) and y >= sbTop and y < sbTop + sbH: return dtScroll
  if mmRect.x >= 0 and x >= mmRect.x and x < mmRect.x + mmRect.w and y >= mmRect.y and y < mmRect.y + mmRect.h:
    return dtMinimap
  dtNone

proc minimapJump(y: int) =
  ## the view follows the pointer on the minimap (each minimap row is four lines)
  let b = buf()
  let line = clamp(mmFirst + (clamp(y, mmRect.y, mmRect.y + mmRect.h - 1) - mmRect.y) * 4, 0, b.lines.high)
  b.topLine = clamp(line - textH div 2, 0, b.lines.high)
  b.topSub = 0
  b.setSingle(b.clampPos(Pos(line: line, col: 0)))
  b.lastHead = b.primary.head
  b.lastChange = b.changeId

proc tabDragTo(x: int) =
  ## a tab dragged along the tab bar moves there
  for (a, e, i) in tabRanges:
    if x >= a and x < e and i != curBuf and i < bufs.len and curBuf < bufs.len:
      let b = bufs[curBuf]
      bufs.delete(curBuf)
      bufs.insert(b, i)
      curBuf = i
      tabRanges.setLen(0)          # positions change: wait for the redrawn bar
      needRender = true
      return

proc treeSwipe(dx: int) =
  ## touch: swipe left in the file tree = up to the parent folder (closed), swipe right = open the folder
  if treeSel < 0 or treeSel >= treeRows.len: return
  let n = treeRows[treeSel]
  if dx > 0:
    if n.isDir and not n.expanded:
      n.expanded = true
      flattenTree()
  else:
    if n.isDir and n.expanded:
      n.expanded = false
      flattenTree()
    else:
      for k in countdown(treeSel - 1, 0):
        if treeRows[k].isDir and treeRows[k].depth < n.depth:
          treeRows[k].expanded = false
          treeSel = k
          flattenTree()
          break
  needRender = true

proc scrollbarJump(y: int) =
  ## the scrollbar thumb follows the pointer
  let b = buf()
  let total = b.lines.len
  if sbH <= 1 or total <= sbH: return
  let target = clamp((y - sbTop) * (total - 1) div (sbH - 1) - sbH div 2, 0, max(0, total - sbH))
  b.scrollBy(target - b.topLine)

proc dragTo(x, y: int) =
  ## the pointer moved to x, y while dragging something: moves the split divider (only the two panes beside it change),
  ## sets a dock's width or the panel's height, drags the scroll bar, minimap, a tab (along the bar, or off it to drop
  ## on a pane), a text field's selection, a form's scroll bar or a box; or hands a file or text drag to the drop logic
  case dragTarget
  of dtSplit:
    if dragDiv < 0 or dragDiv >= splitDivs.len or splitDivs[dragDiv].node != dragNode:
      # (the panes changed under the drag: the divider of that split, where it is now)
      dragDiv = -1
      for k, d in splitDivs:
        if d.node == dragNode: dragDiv = k
    if dragDiv >= 0 and dragDiv < splitDivs.len:
      # (the split's own area: x0 and size are its first column — or row — and its width — or height)
      let d = splitDivs[dragDiv]
      let at = clamp(if d.vertical: x else: y, d.x0 + 1, d.x0 + d.size - 2)
      d.node.ratio = clamp((at - d.x0).float + 0.25, 1.0, float(d.size - 1)) / max(1, d.size - 1).float
      # the dividers next to it that cut the same way stay where they are: only the two panes beside it change
      for e in splitDivs:
        if e.vertical != d.vertical: continue
        let ex = if e.vertical: e.x else: e.y
        if e.node == d.node.b and not d.node.b.leaf and ex > at + 1:
          let st = at + 1
          let sz = d.x0 + d.size - st
          if sz > 2: e.node.ratio = clamp((ex - st).float + 0.25, 1.0, float(sz - 1)) / float(sz - 1)
        elif e.node == d.node.a and not d.node.a.leaf and ex < at - 1:
          let sz = at - d.x0
          if sz > 2: e.node.ratio = clamp((ex - d.x0).float + 0.25, 1.0, float(sz - 1)) / float(sz - 1)
  of dtLeftDock: cfgLeftW = clamp(x, 16, max(16, scrW - 30))
  of dtRightDock: cfgRightW = clamp(scrW - x - 1, 24, max(24, scrW - 30))
  of dtPanel:
    panelMax = false
    cfgPanelH = clamp(lay.bodyBot - y, 4, max(4, lay.bodyBot - lay.bodyTop - 4))
  of dtScroll: scrollbarJump(y)
  of dtMinimap: minimapJump(y)
  of dtTab:
    if cfgDragDrop and lay.tabY >= 0 and y != lay.tabY and bufs.len > 0 and not buf().isWelcome():
      # off the tab bar: onto a pane or an edge of the editor
      dndBufId = buf().id
      dragTarget = dtTabOut
      dropHover(x, y)
    else: tabDragTo(x)
  of dtField: fieldDragTo(x)
  of dtTabOut, dtFile, dtText: dropHover(x, y)
  of dtFormScroll: formScrollTo(y)
  of dtMove:
    # (the offset from where the box opens: it opens there again, this session)
    boxMoves[moveGrab.key] = (x - moveGrab.dx - moveGrab.x0, y - moveGrab.dy - moveGrab.y0)
  of dtNone: discard
  needRender = true

proc rememberSizes(t: DragTarget) =
  ## a dock or panel size chosen with the mouse or keyboard is kept in the settings
  case t
  of dtLeftDock: setSetting("ui.leftDockWidth", %cfgLeftW)
  of dtRightDock: setSetting("ui.rightDockWidth", %cfgRightW)
  of dtPanel: setSetting("ui.panelHeight", %cfgPanelH)
  else: discard

proc resizeBy(horizontal: bool, d: int) =
  ## Ctrl+Alt+arrows: the split divider, the dock that has the focus (or the open one), the bottom panel
  if horizontal:
    if splitOn and focus == fEditor and not phoneFlip() and resizePane(true, d): discard
    elif rightOpen and lay.rightW > 0 and (focus == fRight or not treeOpen):
      cfgRightW = clamp(lay.rightW - d * 2, 24, max(24, scrW - 30))
      rememberSizes(dtRightDock)
    elif treeOpen:
      cfgLeftW = clamp(lay.leftW + d * 2, 16, max(16, scrW - 30))
      rememberSizes(dtLeftDock)
    else: info("Nothing to resize here — open a dock or split the editor")
  else:
    if splitOn and focus == fEditor and (if phoneFlip(): resizePane(true, d) else: resizePane(false, d)): discard
    elif panelOpen and lay.panelH > 0:
      panelMax = false
      cfgPanelH = clamp(lay.panelH + d, 4, max(4, lay.bodyBot - lay.bodyTop - 4))
      rememberSizes(dtPanel)
    else: info("Nothing to resize here — open the bottom panel or split the editor down")
  needRender = true

proc handleMouse(k: Key) =
  ## every mouse event: motion (hover and tooltips), the wheel (scrolls the other pane, the tabs, menus, pickers,
  ## completion, hover, docks or the editor; sideways with Shift or a tilt wheel), releases (ends drags and drops, touch
  ## swipes in the tree, press-and-hold as a right click), drags (moving what was grabbed, Alt+drag box selection,
  ## extending the selection), right clicks (context menus for the picker, gutter or editor), middle click on a tab
  ## (closes it) and left presses, tried in turn against the open menu, dialog, form, picker, completion, prompt, drag
  ## handles and click regions, then the terminal, docks and the editor, where clicks place cursors (double: word,
  ## triple: line, Ctrl: definition, Alt: more cursors or a box)
  let x = k.mx
  let y = k.my
  # pointer motion (any-event tracking) → hover effects and tooltips
  if k.drag and k.mb == 3:
    if x != mouseX or y != mouseY:
      mouseX = x
      mouseY = y
      mouseMovedAt = getMonoTime()
      if cfgHoverFx or tipShown: needRender = true
    return
  mouseX = x
  mouseY = y
  mouseMovedAt = getMonoTime()
  if splitOn and not k.drag and not menuOpen() and not dialogOpen() and pickKind == pickNone and not helpOpen:
    let pi = paneAt(x, y)
    if pi >= 0 and pi != activePane:
      if k.mb == 64 or k.mb == 65:
        # the wheel scrolls the other pane without taking the focus
        let ob = bufById(panes[pi].bufId)
        if ob != nil:
          panes[pi].snap.topLine = clamp(panes[pi].snap.topLine + (if k.mb == 64: -3 else: 3), 0, ob.lines.high)
          panes[pi].snap.topSub = 0
          needRender = true
        return
      if k.press: focusPane(pi)
  # sideways: a tilt wheel, or Shift + wheel
  if k.mb in [66, 67] or (k.mb in [64, 65] and mShift in k.mods):
    let d = if k.mb in [64, 66]: -6 else: 6
    let (ex, ey, ew, eh) = editorRect
    if not cfgWrap and x >= ex and x < ex + ew and y >= ey and y < ey + eh and not menuOpen() and
       not dialogOpen() and pickKind == pickNone:
      let b = buf()
      b.leftCol = max(0, b.leftCol + d)
      needRender = true
    return
  # the wheel over the tabs switches tabs
  if (k.mb == 64 or k.mb == 65) and lay.tabY >= 0 and y == lay.tabY and not menuOpen() and not dialogOpen() and
     pickKind == pickNone and bufs.len > 1:
    curBuf = clamp(curBuf + (if k.mb == 64: -1 else: 1), 0, bufs.high)
    closeComp()
    needRender = true
    return
  if k.mb == 64 or k.mb == 65:
    let d = if k.mb == 64: -3 else: 3
    if helpOpen: helpScroll = max(0, helpScroll + d)
    elif menuOpen():
      # the wheel over a long menu scrolls it
      for lv in countdown(menus.high, 0):
        let m = menus[lv]
        if x >= m.x and x < m.x + m.w and y >= m.y and y < m.y + m.rows + 2:
          menuScroll(lv, d)
          break
    elif dialogOpen(): discard
    elif formOpen(): formScroll(d)
    elif pickKind != pickNone:
      if pickShown.len > 0: pickSel = clamp(pickSel + (if d < 0: -1 else: 1), 0, pickShown.high)
    elif compOpen and compDocRect.w > 0 and x >= compDocRect.x and x < compDocRect.x + compDocRect.w and
         y >= compDocRect.y and y < compDocRect.y + compDocRect.h:
      compDocScroll = max(0, compDocScroll + d)
    elif compOpen:
      compSel = clamp(compSel + (if d < 0: -1 else: 1), 0, max(0, compShown.high))
    elif hoverOpen and hoverMd.len > 0 and not hoverIsAuto:
      hoverScroll = max(0, hoverScroll + d)
    else: scrollAt(x, y, d)
    return
  if not k.press:
    mouseDragging = false
    termSelecting = false
    boxAnchor = Pos(line: -1)
    if dragTarget in {dtTabOut, dtFile, dtText}:
      dndDrop(x, y, k.mods)
      pressLeft = false
      return
    if dndArmed == dtText:
      # a click in the selection, without a drag: the cursor there
      dndArmed = dtNone
      buf().setSingle(buf().clampPos(dndPressPos))
      mouseDragging = false
    dndArmed = dtNone
    if dragTarget != dtNone:
      let t = dragTarget
      dragTarget = dtNone
      rememberSizes(t)
      needRender = true
      if not (t == dtTab and not pressMoved): return     # a tab held still: its menu (below)
    # touch: a quick sideways swipe in the file tree goes up a folder (left) or opens one (right)
    if pressLeft and pressMoved and treeOpen and pressX < lay.leftW and abs(x - pressX) >= 6 and
       abs(y - pressY) <= 1 and msSince(pressAt) < 700:
      pressLeft = false
      treeSwipe(x - pressX)
      return
    # touch: press and hold without moving = right click (context menus)
    if pressLeft and not pressMoved and cfgLongPress and msSince(pressAt) >= 550 and x == pressX and
       y == pressY and not menuOpen() and not dialogOpen():
      pressLeft = false
      handleMouse(Key(kind: kMouse, mb: 2, press: true, mx: x, my: y))
      return
    pressLeft = false
    return
  if k.drag:
    if x != pressX or y != pressY: pressMoved = true
    if dndArmed != dtNone and (abs(x - pressX) + abs(y - pressY) >= (if dndArmed == dtFile: 2 else: 1)):
      dndStart(dndArmed)
    if dragTarget != dtNone:
      dragTo(x, y)
      return
    if boxAnchor.line >= 0:
      # Alt+drag: one cursor per line, all selecting the same columns
      let (ex, ey, ew, eh) = editorRect
      let (ok, p) = editorPosAt(clamp(x, ex, ex + ew - 1), clamp(y, ey, ey + eh - 1))
      let b = buf()
      if ok and boxAnchor.line <= b.lines.high:
        b.cursors.setLen(0)
        let step = if p.line >= boxAnchor.line: 1 else: -1
        var l = boxAnchor.line
        while true:
          let n = b.lines[l].len
          b.cursors.add Cursor(anchor: Pos(line: l, col: min(boxAnchor.col, n)), head: Pos(line: l, col: min(p.col, n)), goalX: -1)
          if l == p.line: break
          l += step
        b.prim = b.cursors.high
        if y < ey: b.scrollBy(-1)
        elif y >= ey + eh: b.scrollBy(1)
        needRender = true
      return
    if mouseDragging:
      let (ex, ey, ew, eh) = editorRect
      let (ok, p) = editorPosAt(clamp(x, ex, ex + ew - 1), clamp(y, ey, ey + eh - 1))
      if ok:
        let b = buf()
        b.cursors[b.prim].head = p
        b.normalize()
        if y < ey: b.scrollBy(-1)
        elif y >= ey + eh: b.scrollBy(1)
    elif termSelecting: termDragTo(x, y)
    return
  # ── right click: context menus ──
  if k.mb == 2:
    closeMenus()
    let modal = dialogOpen() or formOpen()
    let i = hitContext(x, y, (if modal: max(0, modalStart) else: 0))
    if i >= 0:
      regions[i].rightAct()
      return
    if pickKind != pickNone and not modal:
      # a row of the list: open it (here or beside), copy its path
      let (bx, _, bw, _) = pickBox
      if y >= pickListY and y < pickListY + pickListN and x > bx and x < bx + bw - 1:
        let si = pickScroll + (y - pickListY) div max(1, pickRowH)
        if si < pickShown.len:
          pickSel = si
          var items = @[mi("Open", "Enter", proc() = acceptPicker())]
          if pickKind in {pickFile, pickRecent, pickBuffer, pickSymbol}:
            items.add mi("Open to the side", "", proc() =
              toSidePane()
              acceptPicker())
          if pickKind in {pickFile, pickRecent}:
            let it = pickItems[pickShown[si]]
            let path = pickPath(it)
            if path.len > 0:
              items.add msep()
              items.add ctxCopy("Copy the path", path)
          openMenu(items, x, y + 1)
      return
    if modal: return     # (over a dialog: nothing under it)
    let (ex, ey, ew, eh) = editorRect
    if x >= ex and x < ex + gutterW and y >= ey and y < ey + eh and not buf().isWelcome() and buf().hex == nil:
      # the gutter: the line's breakpoint, bookmark, fold, git change
      let (ok, p) = editorPosAt(ex + gutterW, y)
      if ok:
        focus = fEditor
        openMenu(gutterMenu(p.line), x, y + 1)
      return
    if x >= ex and x < ex + ew and y >= ey and y < ey + eh and not buf().isWelcome():
      let b = buf()
      let (ok, p) = editorPosAt(x, y)
      if ok and not b.primary.hasSel: b.setSingle(p)
      focus = fEditor
      openMenu(editorMenu(), x, y + 1)
    return
  if k.mb == 1:
    for (a, e, i) in tabRanges:
      if y == lay.tabY and x >= a and x < e:
        if i < bufs.len: closeBuffer(i)
        tabRanges.setLen(0)       # the tabs moved: the next click waits for the redrawn bar
        return
    return
  if k.mb != 0: return
  pressAt = getMonoTime()
  pressX = x
  pressY = y
  pressMoved = false
  pressLeft = true
  dragTarget = dtNone          # (a release lost outside the window never leaves a drag behind)
  dndArmed = dtNone
  dndPrevBufId = (if bufs.len > 0: buf().id else: -1)
  if menuOpen():
    let i = hitRegion(x, y, modalStart)
    if i >= 0: regions[i].act()
    else:
      # clicking another menu-bar title switches menus
      if lay.titleY >= 0 and y == lay.titleY:
        for (a, e, idx) in menuBarRanges:
          if x >= a and x < e:
            openMenuBar(idx)
            return
      closeMenus()
    return
  # a box's title bar (a dialog's, a form's, a picker's): a drag moves the box — a button on it still acts
  if moveBar.x >= 0 and y == moveBar.y and x >= moveBar.x and x < moveBar.x + moveBar.w and
     (dialogOpen() or formOpen() or pickKind != pickNone):
    let base = if dialogOpen() or formOpen(): modalStart else: pickRegions
    let i = hitRegion(x, y, max(0, base))
    if i < 0 or (i == base and (dialogOpen() or formOpen())):        # (nothing there but the box)
      dragTarget = dtMove
      moveGrab = (x - moveBar.x, y - moveBar.y, moveBar.x0, moveBar.y0, moveBar.key)
      return
  if dialogOpen() or formOpen():
    let i = hitRegion(x, y, modalStart)
    if i >= 0: regions[i].act()
    return
  hoverOpen = false
  if helpOpen:
    helpOpen = false
    return
  if pickKind != pickNone:
    let (bx, by, bw, bh) = pickBox
    if not (y >= pickListY and y < pickListY + pickListN) and pickRegions >= 0:
      let i = hitRegion(x, y, pickRegions)
      if i >= 0:
        regions[i].act()                # the query field (the cursor, a selection), the buttons
        return
    if y >= pickListY and y < pickListY + pickListN and x > bx and x < bx + bw - 1:
      let i = pickScroll + (y - pickListY) div max(1, pickRowH)
      if i < pickShown.len:
        pickSel = i
        acceptPicker()
    elif x < bx or x >= bx + bw or y < by or y >= by + bh:
      closePicker()
    return
  if compOpen:
    let (cx, cy, cw, ch) = compRect
    if x >= cx and x < cx + cw and y >= cy and y < cy + ch:
      let i = compScroll + (y - cy)
      if i >= 0 and i < compShown.len:
        compSel = i
        acceptComp()
      return
    let (dx, dy, dw, dh) = compDocRect
    if dw > 0 and x >= dx and x < dx + dw and y >= dy and y < dy + dh: return    # reading the docs
    closeComp()
  if promptKind notin {pNone, pFind, pReplaceFind, pReplaceWith}:
    let i = hitRegion(x, y, max(0, modalStart))
    if modalStart >= 0 and i >= modalStart:
      regions[i].act()                  # (the field: the cursor there, a drag selects — or a button)
      return
    closePrompt()
  # (a button drawn over the minimap or the scroll bar — the find bar's ×, a note, a hover — takes the click: the
  # handle under it does not)
  if overlayStart >= 0:
    let oi = hitRegion(x, y, overlayStart)
    if oi >= 0 and dragHandleAt(x, y) in {dtMinimap, dtScroll}:
      regions[oi].act()
      return
  # drag handles: the split divider, dock edges, the bottom panel's header, the scrollbar
  let dt = dragHandleAt(x, y)
  if dt != dtNone:
    dragTarget = dt
    if dt == dtScroll: scrollbarJump(y)
    elif dt == dtMinimap: minimapJump(y)
    elif dt == dtPanel: focus = fPanel
    needRender = true
    return
  let i = hitRegion(x, y)
  if i >= 0:
    let tip = regions[i].tip
    regions[i].act()
    # a press on a file tree row: a drag takes the file (onto the editor, a folder, the terminal)
    if treeOpen and sideView == svFiles and x < lay.leftW and tip.len > 0 and tip != rootDir and
       (fileExists(tip) or dirExists(tip)):
      dndArmFile(tip)
    # a press on a tab can become a drag that moves the tab
    if lay.tabY >= 0 and y == lay.tabY:
      for (a, e, ti) in tabRanges:
        if x >= a and x < e and ti == curBuf: dragTarget = dtTab
    return
  # terminal area
  if panelTopY >= 0 and y > panelTopY and panelKind == pkTerminal and x >= lay.edX and x < lay.edX + lay.edW:
    focus = fPanel
    termClick(x, y)
    return
  if panelTopY >= 0 and y >= panelTopY and x >= lay.edX and x < lay.edX + lay.edW:
    focus = fPanel
    return
  if treeOpen and x < lay.leftW:
    focus = fTree
    return
  if rightOpen and x >= lay.rightX:
    focus = fRight
    return
  let (ok, p) = editorPosAt(x, y)
  if not ok: return
  if gutterClick(x, p): return
  if treeOpen and scrW < 70: treeOpen = false
  focus = fEditor
  closeComp()
  let b = buf()
  if msSince(lastClickTime) < 450 and abs(x - lastClickX) <= 1 and y == lastClickY: inc clickCount
  else: clickCount = 1
  lastClickTime = getMonoTime()
  lastClickX = x
  lastClickY = y
  if mAlt in k.mods or mCtrl in k.mods:
    if mCtrl in k.mods and clickCount == 1 and not (mAlt in k.mods):
      # Ctrl+click: go to definition, like desktop editors
      b.setSingle(p)
      cmdDefinition()
      return
    b.cursors.add cur(p)
    b.prim = b.cursors.high
    b.normalize()
    if mAlt in k.mods: boxAnchor = p            # Alt+drag from here: a box selection
    return
  vimMouseClick()
  case clickCount
  of 2:
    let (a, e) = b.wordRangeAt(p)
    b.setSingle(e, a)
  of 3:
    let e = if p.line < b.lines.high: Pos(line: p.line + 1, col: 0) else: Pos(line: p.line, col: b.lines[p.line].len)
    b.setSingle(e, Pos(line: p.line, col: 0))
  else:
    if mShift in k.mods:
      b.cursors = @[Cursor(anchor: b.primary.anchor, head: p, goalX: -1)]
      b.prim = 0
    elif cfgDragDrop and b.cursors.len == 1 and b.primary.hasSel and
         inSel(p, b.primary.range[0], b.primary.range[1]):
      dndArmText(b, p)                          # (a drag moves the selection; a click puts the cursor here)
      return
    else: b.setSingle(p)
    mouseDragging = true
