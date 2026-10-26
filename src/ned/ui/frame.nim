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

var titleSent = ""

proc termTitle() =
  ## ui.terminalTitle: the file and the project in the terminal's title (● unsaved) — set when it changes
  if not cfgTermTitle:
    if titleSent.len > 0:
      writeAll("\e[23;0t\e[22;0t")         # (the title from before ned, and kept again for when it leaves)
      titleSent = ""
    return
  if titleReset:
    titleReset = false
    titleSent = ""
  let b = buf()
  let name = if b.path.len > 0: extractFilename(b.path) elif b.title.len > 0: b.title
             elif b.isWelcome(): "ned" else: "untitled"
  var t = (if b.dirty: "● " else: "") & name
  if rootDir.len > 1 and name != "ned": t.add " — " & extractFilename(rootDir)
  var clean = ""
  for c in t:
    if c.uint8 >= 32 and c != '\x7f': clean.add c
  if clean != titleSent:
    titleSent = clean
    writeAll("\e]2;" & clean & "\a")

proc render() =
  let renderT0 = getMonoTime()
  if cellPool.len > 50_000:
    resetCellPool()                 # (characters of several code points pile up: start the pool again)
    prevGrid.setLen(0)
  if bufs.len > 0:
    tabW = buf().tabOf
    cfgWrap = wrapFor(buf())
  cursorX = -1
  cursorY = -1
  edCaretX = -1
  edCaretY = -1
  splitDivs.setLen(0)
  sbCol = -1
  mmRect = (-1, 0, 0, 0)
  if grid.len != scrW * scrH: gridResize()
  regions.setLen(0)
  moveBar.x = -1                 # (a box drawn this frame sets its title bar again)
  modalStart = -1
  overlayStart = -1
  tipShown = false
  gfxNow = GfxReq()                 # (a picture view sets it again when it draws)
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
  overlayStart = regions.len         # (what is drawn from here may lie over the minimap or the scroll bar)
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
  drawKeyHints((if lay.touchY >= 0: lay.touchY elif lay.statusY >= 0: lay.statusY else: scrH))
  drawToasts((if lay.touchY >= 0: lay.touchY elif lay.statusY >= 0: lay.statusY else: scrH))
  drawDnd()
  if formOpen():
    cursorX = -1                      # (the form's own field has it, if one has the focus)
    drawForm()
  drawMenus()
  drawDialog()
  drawTooltip()
  if dialogOpen() or menuOpen() or helpOpen: cursorX = -1
  elif formOpen(): discard
  elif focus notin {fEditor} and promptKind == pNone and pickKind == pickNone and
       not (focus == fTree and sideView == svSearch) and not (focus == fRight and rightView == svAssistant) and
       not (focus == fPanel and panelKind == pkTerminal):
    cursorX = -1
  # (a menu, a dialog, a popup over the picture: the terminal's own picture would hide it — the cells' one shows)
  if gfxNow.key.len > 0 and (dialogOpen() or menuOpen() or helpOpen or pickKind != pickNone or compOpen or hoverOpen or
                             promptKind != pNone or formOpen() or toasts.len > 0):
    gfxNow = GfxReq()
  frameBuildUs = int((getMonoTime() - renderT0).inMicroseconds)
  flushScreen()
  updatePointer()
  if gRaw:
    termTitle()
    termProgress()
