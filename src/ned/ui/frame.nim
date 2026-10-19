proc showLoading(msg: string) =
  popupMsg(msg, 0)
  render()

proc updatePointer() =
  ## the mouse pointer's shape, where the terminal can change it: a hand over a button, a tab, a menu item or a
  ## row that can be clicked, an I-beam over the text you edit, the arrow elsewhere — sent only when it changes
  if not cfgPointer or not cfgHoverFx or not cfgMouse or mouseX < 0 or mouseY < 0: return
  var want = "default"
  let i = hitRegion(mouseX, mouseY)
  if i >= 0 and regions[i].h == 1 and regions[i].act != nil: want = "pointer"
  elif i < 0 and not dialogOpen() and not menuOpen() and pickKind == pickNone and not helpOpen and
       mouseX >= lay.edX + 4 and mouseX < lay.edX + lay.edW and mouseY >= lay.textY and mouseY < lay.textY + lay.textH:
    want = "text"
  if want != pointerShape:
    pointerShape = want
    writeAll("\e]22;" & want & "\a")

var lastDrawnBuf, lastDrawnTop = -1          # (the editor drawn last frame: did its text move?)

proc render() =
  let renderT0 = getMonoTime()
  if bufs.len > 0:
    tabW = buf().tabOf
    cfgWrap = wrapFor(buf())
  cursorX = -1
  cursorY = -1
  edCaretX = -1
  edCaretY = -1
  splitDiv = (-1, -1, 0, true)
  sbCol = -1
  mmRect = (-1, 0, 0, 0)
  if grid.len != scrW * scrH: gridResize()
  regions.setLen(0)
  modalStart = -1
  tipShown = false
  fillRect(0, 0, scrW, scrH, theme.fg, theme.bg)
  if scrW < 16 or scrH < 5:
    discard putStr(0, 0, "ned: window too small", theme.fg, theme.bg)
    flushScreen()
    return
  computeLayout()
  let b = buf()
  let bodyH = lay.bodyBot - lay.bodyTop
  let editorHidden = lay.overlay and (treeOpen or rightOpen)
  if not editorHidden:
    drawTabBar()
    let split = splitOn and not zenMode and drawSplit()
    if not split: drawBreadcrumbs()
    let mm = if b.isWelcome() or b.lines.len <= lay.textH or zenMode or split or b.largeOn or cfgAccessible: 0
             else: minimapWidth(lay.edW)
    minimapShown = mm > 0
    if split: discard
    elif zenMode and not b.isWelcome():
      # zen: one calm, centred column; top and bottom margins when there is room
      let numW = if cfgZenHideNums: 0 else: max(3, len($b.lines.len)) + 1
      let colW = min(lay.edW, cfgZenWidth + 3 + numW)
      let zx = lay.edX + max(0, (lay.edW - colW) div 2)
      let my = if lay.textH >= 30: 2 elif lay.textH >= 16: 1 else: 0
      drawEditor(b, zx, lay.textY + my, colW, max(1, lay.textH - 2 * my), focus == fEditor)
      drawZenInfo(b)
    else:
      drawEditor(b, lay.edX, lay.textY, lay.edW - mm, lay.textH, focus == fEditor)
      # (the text moved up or down — by scrolling, or drawing kept the cursor in view: the terminal may move what
      # it shows; flushScreen decides)
      if b.id == lastDrawnBuf and b.topLine != lastDrawnTop:
        scrollHint = (true, lay.textY, lay.textY + lay.textH - 1, lay.edX, lay.edX + lay.edW - mm - 1)
      lastDrawnBuf = b.id
      lastDrawnTop = b.topLine
    if mm > 0: drawMinimap(b, lay.edX + lay.edW - mm, lay.textY, mm, lay.textH)
    if lay.panelH > 0: drawBottomPanel(lay.edX, lay.panelY, lay.edW, lay.panelH)
  panelTopY = if lay.panelH > 0 and not editorHidden: lay.panelY else: -1
  treeWCur = lay.leftW
  if treeOpen:
    drawDock(dsLeft, 0, lay.bodyTop, lay.leftW, bodyH)
    if not lay.overlay:
      for yy in lay.bodyTop ..< lay.bodyBot:
        setCell(lay.leftW, yy, Cell(ch: 0x2502, fg: theme.border, bg: theme.dockBg))
  if rightOpen and lay.rightW > 0:
    drawDock(dsRight, lay.rightX, lay.bodyTop, lay.rightW, bodyH)
    if lay.rightFloat: shadeRect(lay.rightX - 1, lay.bodyTop, 1, bodyH)
    elif not lay.overlay:
      for yy in lay.bodyTop ..< lay.bodyBot:
        setCell(lay.rightX - 1, yy, Cell(ch: 0x2502, fg: theme.border, bg: theme.dockBg))
  drawTitleBar()
  drawStatusBar()
  drawTouchBar()
  drawSignature()
  if compOpen and focus == fEditor and promptKind == pNone: drawCompletion()
  if hoverOpen: drawHover()
  if promptKind in {pFind, pReplaceFind} or replaceActive: drawFindWidget()
  elif promptKind != pNone: drawQuickInput()
  if pickKind != pickNone: drawPicker()
  if helpOpen: drawHelp()
  drawToasts((if lay.touchY >= 0: lay.touchY elif lay.statusY >= 0: lay.statusY else: scrH))
  drawMenus()
  drawDialog()
  drawTooltip()
  if dialogOpen() or menuOpen() or helpOpen: cursorX = -1
  elif focus notin {fEditor} and promptKind == pNone and pickKind == pickNone and
       not (focus == fTree and sideView == svSearch) and not (focus == fRight and rightView == svAssistant) and
       not (focus == fPanel and panelKind == pkTerminal):
    cursorX = -1
  frameBuildUs = int((getMonoTime() - renderT0).inMicroseconds)
  flushScreen()
  updatePointer()
