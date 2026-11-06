# ── drag and drop (ui.dragAndDrop): a tab off the tab bar onto a pane or an edge (split there), a file or folder from
#    the file tree onto the editor (opened — at an edge, in a split), onto a folder (moved there) or the terminal (its
#    path typed), the selected text elsewhere in the file (moved; with Ctrl or Alt held: copied). While dragging, a
#    label follows the pointer and the place it would land is shaded. ──

proc tabDragTo(x: int)

type DndZone = enum dzNone, dzOpen, dzPane, dzSplitRight, dzSplitDown, dzFolder, dzTerminal, dzText, dzTabBar

var
  dndBufId = -1                 # the tab dragged
  dndPath = ""                  # the file or folder dragged
  dndText = ""                  # the text dragged …
  dndFromA, dndFromE: Pos       # … from there
  dndArmed = dtNone             # a press that becomes a drag once the pointer moves (dtFile, dtText)
  dndPressPos: Pos              # (a text press: where the click would put the cursor)
  dndX, dndY = -1

proc dndArmFile(path: string) =
  ## a press on a file or folder in the tree: it becomes a drag of that path once the pointer moves (nothing when drag
  ## and drop is off)
  if not cfgDragDrop or path.len == 0: return
  dndArmed = dtFile
  dndPath = path

proc dndArmText(b: Buffer, p: Pos) =
  ## a press inside the selection: a drag moves it, a click (no move) puts the cursor there
  dndArmed = dtText
  dndPressPos = p
  let (a, e) = b.primary.range
  dndFromA = a
  dndFromE = e
  dndText = b.getText(a, e)

proc dndStart(t: DragTarget) =
  ## starts the drag of kind `t` (the armed press has turned into a drag)
  dragTarget = t
  dndArmed = dtNone
  needRender = true

# whether position `p` lies inside the selection from `a` up to, but not including, `e`
func inSel(p, a, e: Pos): bool = (p.line > a.line or (p.line == a.line and p.col >= a.col)) and
                                 (p.line < e.line or (p.line == e.line and p.col < e.col))

proc dndTreeRowAt(x, y: int): int =
  ## the file tree's row under the pointer (-1 none)
  if not treeOpen or sideView != svFiles or x >= lay.leftW or lay.overlay: return -1
  let r = y - (lay.bodyTop + 2)          # (the dock's header, the project's row)
  if r < 0: return -1
  let i = treeScroll + r
  if i < 0 or i >= treeRows.len: -1 else: i

proc dndZoneAt(x, y: int): (DndZone, int) =
  ## where a drop at x, y would go, and its pane / tree row
  let ti = dndTreeRowAt(x, y)
  if ti >= 0 and dragTarget == dtFile:
    let n = treeRows[ti]
    let dir = if n.isDir: n.path else: parentDir(n.path)
    if dir != dndPath and not dir.startsWith(dndPath & "/") and dir != parentDir(dndPath): return (dzFolder, ti)
    return (dzNone, -1)
  if dragTarget == dtTabOut and lay.tabY >= 0 and y == lay.tabY: return (dzTabBar, -1)
  if panelTopY >= 0 and y > panelTopY and panelKind == pkTerminal and x >= lay.edX and x < lay.edX + lay.edW:
    if dragTarget in {dtFile, dtText}: return (dzTerminal, -1)
    return (dzNone, -1)
  let ex = lay.edX
  let ey = lay.textY
  let ew = lay.edW
  let eh = lay.textH
  if x < ex or x >= ex + ew or y < (if lay.crumbY >= 0: lay.crumbY else: ey) or y >= ey + eh: return (dzNone, -1)
  if dragTarget == dtText:
    let (ok, _) = editorPosAt(x, y)
    return (if ok: (dzText, -1) else: (dzNone, -1))
  if splitOn:
    # (a pane: its right or bottom quarter splits it — when there is room for two — else it shows the file)
    let pi = paneAt(x, y)
    if pi < 0: return (dzNone, -1)
    let r = panes[pi].rect
    if r.w >= 2 * MinPaneW + 1 and x >= r.x + r.w * 3 div 4: return (dzSplitRight, pi)
    if r.h >= 12 and y >= r.y + r.h * 3 div 4: return (dzSplitDown, pi)
    return (dzPane, pi)
  if buf().isWelcome(): return (dzOpen, -1)
  if x >= ex + ew * 3 div 4: return (dzSplitRight, -1)
  if eh >= 12 and y >= ey + eh * 3 div 4: return (dzSplitDown, -1)
  if dragTarget == dtTabOut: return (dzNone, -1)        # (the tab is shown already)
  (dzOpen, -1)

proc dropHover(x, y: int) =
  ## the pointer moved while dragging
  dndX = x
  dndY = y
  # a tab back on the tab bar moves along it again
  if dragTarget == dtTabOut and lay.tabY >= 0 and y == lay.tabY:
    dragTarget = dtTab
    tabDragTo(x)
  # (the tree scrolls at its edges)
  if dragTarget == dtFile and treeOpen and x < lay.leftW:
    if y <= lay.bodyTop + 1: treeScroll = max(0, treeScroll - 1)
    elif y >= lay.bodyBot - 1: treeScroll = min(max(0, treeRows.high), treeScroll + 1)
  needRender = true

proc dndBufIndex(id: int): int =
  ## the place of the buffer with that id among the tabs (-1: none)
  for i, b in bufs:
    if b.id == id: return i
  -1

proc dndShow(bufId: int) =
  ## shows the tab of that buffer in the active pane and gives the keyboard to the editor
  let bi = dndBufIndex(bufId)
  if bi >= 0:
    curBuf = bi
    focus = fEditor

proc dndSplit(down: bool, show: proc(), moving = -1, pane = -1) =
  ## a split — of `pane`, else the active one — with `show` in its new pane; the pane the press was in keeps what it
  ## showed before the press (or, when that is the tab being moved, the tab next to it)
  var prev = dndPrevBufId
  if prev < 0 or prev == moving:
    prev = -1
    let k = dndBufIndex(moving)
    for j in [k - 1, k + 1]:
      if j >= 0 and j < bufs.len and not bufs[j].isWelcome():
        prev = bufs[j].id
        break
  let pressPane = activePane
  if not splitOn:
    splitEditor(down)
    if not splitOn: return
  elif not splitPaneOf(if pane >= 0: pane else: activePane, down): return
  if prev >= 0 and prev != moving and pressPane != activePane and pressPane < panes.len:
    let ob = bufById(prev)
    if ob != nil:
      panes[pressPane].bufId = prev
      panes[pressPane].snap = snapView(ob)
  show()
  needRender = true

proc dndSplitWith(id: int, down: bool) =
  ## (a tab's menu) a split with that tab in its new pane
  dndPrevBufId = -1
  dndSplit(down, proc() = dndShow(id), id)

proc dndDrop(x, y: int, mods: set[Mod]) =
  ## ends a drag where the pointer was let go, by what was dragged and the zone it landed in: a tab pulled off the bar
  ## is shown in a pane or in a new split; a file or folder is opened (a folder revealed in the tree), opened in a pane
  ## or split, moved into a tree folder after asking, or its path typed in the terminal; selected text is moved to the
  ## drop place (copied with Ctrl or Alt, as one undo step) or pasted into the terminal
  let t = dragTarget
  let (z, idx) = dndZoneAt(x, y)
  dragTarget = dtNone
  dndX = -1
  needRender = true
  case t
  of dtTabOut:
    let id = dndBufId
    case z
    of dzPane:
      if idx != activePane: focusPane(idx)
      dndShow(id)
    of dzSplitRight: dndSplit(false, proc() = dndShow(id), id, idx)
    of dzSplitDown: dndSplit(true, proc() = dndShow(id), id, idx)
    else: discard
  of dtFile:
    let p = dndPath
    case z
    of dzOpen:
      if dirExists(p):
        showSide(svFiles)
        revealInTree(p)
      else: discard openFile(p)
    of dzPane:
      if idx != activePane: focusPane(idx)
      if fileExists(p): discard openFile(p)
    of dzSplitRight, dzSplitDown:
      if fileExists(p): dndSplit(z == dzSplitDown, proc() = discard openFile(p), -1, idx)
    of dzFolder:
      if idx >= 0 and idx < treeRows.len:
        let n = treeRows[idx]
        let dir = if n.isDir: n.path else: parentDir(n.path)
        let dest = dir / extractFilename(p)
        if fileExists(dest) or dirExists(dest):
          error(relPath(dest) & " is there already")
          return
        askConfirm("Move " & relPath(p) & " into " & relPath(dir) & "/? (y/n)", proc(c: char) =
          if c == 'y': movePath(p, dest))
    of dzTerminal:
      focus = fPanel
      terminalKey(Key(kind: kPaste, text: quoteShell(p) & " "))
    else: discard
  of dtText:
    let b = buf()
    case z
    of dzText:
      let (ok, p0) = editorPosAt(x, y)
      if not ok or not b.canEdit(): return
      let p = b.clampPos(p0)
      let copy = mCtrl in mods or mAlt in mods
      let (a, e) = (dndFromA, dndFromE)
      if not b.textAt(a, e, dndText): return            # (the text changed meanwhile)
      if not copy and (inSel(p, a, e) or p == e): return
      b.beginEdit()
      var na, ne: Pos
      if copy:
        na = p
        ne = b.replaceText(p, p, dndText)
      elif p.line > e.line or (p.line == e.line and p.col >= e.col):
        let q = b.replaceText(p, p, dndText)
        discard b.replaceText(a, e, "")
        na = shiftPos(p, a, e, a)
        ne = shiftPos(q, a, e, a)
      else:
        discard b.replaceText(a, e, "")
        na = p
        ne = b.replaceText(p, p, dndText)
      b.endEdit()
      b.setSingle(ne, na)
      b.normalize()
      focus = fEditor
      info((if copy: "Copied" else: "Moved") & " the selection" & (if copy: "" else: " (Ctrl+Z puts it back)"))
    of dzTerminal:
      focus = fPanel
      terminalKey(Key(kind: kPaste, text: dndText))
    else: discard
  else: discard

proc drawDnd() =
  ## the place a drop would land, shaded; the label at the pointer
  if dragTarget notin {dtTabOut, dtFile, dtText} or dndX < 0: return
  let (z, idx) = dndZoneAt(dndX, dndY)
  proc tint(x, y, w, h: int) =
    ## shades a rectangle of the screen by blending the accent colour into its background
    for yy in max(0, y) ..< min(scrH, y + h):
      for xx in max(0, x) ..< min(scrW, x + w):
        let i = yy * scrW + xx
        grid[i].bg = blend(grid[i].bg, theme.accent, 0.22)
  let ex = lay.edX
  let ey = if lay.crumbY >= 0: lay.crumbY else: lay.textY
  let ew = lay.edW
  let eh = lay.textY + lay.textH - ey
  var what = ""
  case z
  of dzOpen:
    tint(ex, ey, ew, eh)
    what = "open"
  of dzPane:
    if idx in 0 ..< panes.len:
      let r = panes[idx].rect
      tint(r.x, r.y, r.w, r.h)
      what = if dragTarget == dtTabOut: "show here" else: "open here"
  of dzSplitRight:
    let r = if idx in 0 ..< panes.len: panes[idx].rect else: (x: ex, y: ey, w: ew, h: eh)
    tint(r.x + r.w div 2, r.y, r.w - r.w div 2, r.h)
    what = "split right"
  of dzSplitDown:
    let r = if idx in 0 ..< panes.len: panes[idx].rect else: (x: ex, y: ey, w: ew, h: eh)
    tint(r.x, r.y + r.h div 2, r.w, r.h - r.h div 2)
    what = "split down"
  of dzFolder:
    let y = lay.bodyTop + 2 + idx - treeScroll
    tint(0, y, lay.leftW, 1)
    let n = treeRows[idx]
    what = "move into " & (if n.isDir: n.name else: extractFilename(parentDir(n.path))) & "/"
  of dzTerminal:
    tint(lay.edX, panelTopY + 1, lay.edW, max(1, lay.panelH - 1))
    what = if dragTarget == dtFile: "type its path" else: "paste"
  of dzText:
    let (ok, p) = editorPosAt(dndX, dndY)
    if ok:
      setCell(dndX, dndY, Cell(ch: 0x258F, fg: theme.accent, bg: grid[dndY * scrW + dndX].bg, at: {aBold}))
      discard p
    what = "move here (Ctrl: copy)"
  else: discard
  let name = case dragTarget
             of dtTabOut: (let b = bufById(dndBufId); if b != nil: b.name else: "")
             of dtFile: extractFilename(dndPath)
             else: (let l = dndText.splitLines; truncTo(l[0], 24) & (if l.len > 1: " (+" & $(l.len - 1) & " lines)" else: ""))
  let label = " " & name & (if what.len > 0: " → " & what else: "") & " "
  let lw = strWidth(label)
  let lx = clamp(dndX + 2, 0, max(0, scrW - lw))
  let ly = clamp(dndY + 1, 0, scrH - 1)
  fillRect(lx, ly, lw, 1, theme.fg, theme.toastBg)
  discard putStr(lx, ly, label, theme.fg, theme.toastBg, {aBold})
  dropShadow(lx, ly, lw, 1)
