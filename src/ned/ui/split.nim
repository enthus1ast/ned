# ── panes (6.31: tiled) — the editor area cut into panes, as many as fit, by a tree of splits (PaneNode): each split
#    side by side or one above the other, its divider dragged to resize it. The active pane shows `curBuf` with its
#    cursors; each other one keeps a snapshot of its view (ViewSnap) and draws from it ──

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

const MinPaneW = 14              # (a pane narrower than this, or lower than MinPaneH, is not made: the split is refused)
const MinPaneH = 4

proc phoneFlip(): bool =
  ## a phone held upright: two side-by-side panes are put one above the other
  lay.edW < 60 and panes.len == 2 and not paneRoot.leaf and paneRoot.vertical

proc paneAt(x, y: int): int =
  if not splitOn: return -1
  for i in 0 ..< panes.len:
    let r = panes[i].rect
    if r.w > 0 and x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h: return i
  -1

proc paneGeometry(i: int) =
  ## (until the next frame) the editor geometry of pane i: mouse hit-testing, scrolling
  let r = panes[i].rect
  if r.w <= 0: return
  editorRect = (r.x, r.y + 1, r.w, max(1, r.h - 1))
  gutterW = panes[i].gutterW
  textW = panes[i].textW
  textH = panes[i].textH

proc focusPane(i: int) =
  ## make pane `i` the active one: its buffer becomes `curBuf` with that pane's cursors and scroll
  if not splitOn or i == activePane or i < 0 or i >= panes.len: return
  let cur = buf()
  panes[activePane].bufId = cur.id
  panes[activePane].snap = snapView(cur)
  paneLast = activePane
  activePane = i
  var bi = -1
  for k, x in bufs:
    if x.id == panes[i].bufId: bi = k
  if bi >= 0:
    curBuf = bi
    applyView(bufs[bi], panes[i].snap)
  else:
    panes[i].bufId = cur.id
  paneGeometry(i)
  closeComp()
  hoverOpen = false
  focus = fEditor
  needRender = true

proc splitPaneOf(i: int, down: bool, show: Buffer = nil): bool =
  ## pane i cut in two: the new pane — right of it, or below — shows `show` (else the same file) and gets the focus
  let leaf = leafOf(paneRoot, i)
  if leaf == nil: return false
  if splitOn:
    let r = panes[i].rect
    if r.w > 0 and ((not down and r.w < 2 * MinPaneW + 1) or (down and r.h < 2 * MinPaneH + 1)):
      info("No room for another pane there — close one, or split " & (if down: "right" else: "down") & " instead")
      return false
  if i != activePane: focusPane(i)
  let b = buf()
  panes[activePane].bufId = b.id
  panes[activePane].snap = snapView(b)
  let shown = if show != nil: show else: b
  panes.add Pane(bufId: shown.id, snap: snapView(shown))
  let n = panes.high
  let old = PaneNode(leaf: true, pane: leaf.pane)
  leaf.leaf = false
  leaf.vertical = not down
  leaf.ratio = 0.5
  leaf.a = old
  leaf.b = PaneNode(leaf: true, pane: n)
  splitOn = true
  paneZoom = false
  paneLast = activePane
  activePane = n
  if show != nil and show != b:
    let k = bufs.find(show)
    if k >= 0:
      curBuf = k
      applyView(show, panes[n].snap)
  focus = fEditor
  needRender = true
  true

proc splitEditor(down: bool) =
  let b = buf()
  if b.isWelcome():
    info("Open a file first")
    return
  let first = not splitOn
  if splitPaneOf(activePane, down) and first:
    info("Split — Alt+\\ goes to the next pane, Alt+| closes this one; split again to tile (View › Panes)")

proc removePane(i: int) =
  ## pane i taken out of the layout: its part goes to its neighbour (the other half of its split)
  if panes.len <= 1 or i < 0 or i >= panes.len: return
  let leaf = leafOf(paneRoot, i)
  let par = parentOf(paneRoot, leaf)
  if par != nil:
    let keep = if par.a == leaf: par.b else: par.a
    par.leaf = keep.leaf
    par.pane = keep.pane
    par.vertical = keep.vertical
    par.ratio = keep.ratio
    par.a = keep.a
    par.b = keep.b
  panes.delete(i)
  var ls: seq[PaneNode]
  paneLeaves(paneRoot, ls)
  for l in ls:
    if l.pane > i: dec l.pane
  if paneLast == i: paneLast = -1
  elif paneLast > i: dec paneLast
  splitOn = panes.len > 1
  if not splitOn:
    paneRoot = PaneNode(leaf: true, pane: 0)
    paneZoom = false

proc closePane(i: int) =
  ## close pane i — the active one: the focus goes to the pane that had it before (else its neighbour)
  if not splitOn or i < 0 or i >= panes.len: return
  paneZoom = false
  if i == activePane:
    let b = buf()
    panes[activePane].bufId = b.id
    panes[activePane].snap = snapView(b)
    var nxt = otherPane()
    removePane(i)
    if nxt > i: dec nxt
    activePane = clamp(nxt, 0, panes.high)
    var bi = -1
    for k, x in bufs:
      if x.id == panes[activePane].bufId: bi = k
    if bi >= 0:
      curBuf = bi
      applyView(bufs[bi], panes[activePane].snap)
  else:
    let wasActive = activePane
    removePane(i)
    activePane = if wasActive > i: wasActive - 1 else: wasActive
  focus = fEditor
  needRender = true

proc closeSplit() =
  ## only the active pane left (vim's :only)
  if not splitOn: return
  let b = buf()
  panes = @[Pane(bufId: b.id, snap: snapView(b))]
  paneRoot = PaneNode(leaf: true, pane: 0)
  activePane = 0
  paneLast = -1
  paneZoom = false
  splitOn = false
  needRender = true

proc closeActivePane() = (if splitOn: closePane(activePane) else: info("One pane only — nothing to close"))

proc toggleSplitFocus() =
  ## Alt+\: the next pane (reading order, round again) — or, with one pane, a split
  if not splitOn:
    splitEditor(false)
    return
  let ord = paneOrder()
  focusPane(ord[(ord.find(activePane) + 1) mod ord.len])

proc focusDir(dx, dy: int) =
  ## the pane left, right, above or below the active one (the nearest whose side faces it)
  if not splitOn: return
  let r = panes[activePane].rect
  let cx = r.x + r.w div 2
  let cy = r.y + r.h div 2
  var best = -1
  var bestD = high(int)
  for i in 0 ..< panes.len:
    if i == activePane: continue
    let o = panes[i].rect
    if o.w <= 0: continue
    let ok = (dx < 0 and o.x + o.w <= r.x + 1 and o.y < r.y + r.h and o.y + o.h > r.y) or
             (dx > 0 and o.x >= r.x + r.w - 1 and o.y < r.y + r.h and o.y + o.h > r.y) or
             (dy < 0 and o.y + o.h <= r.y + 1 and o.x < r.x + r.w and o.x + o.w > r.x) or
             (dy > 0 and o.y >= r.y + r.h - 1 and o.x < r.x + r.w and o.x + o.w > r.x)
    if not ok: continue
    let d = abs(o.x + o.w div 2 - cx) + abs(o.y + o.h div 2 - cy)
    if d < bestD:
      bestD = d
      best = i
  if best >= 0: focusPane(best)
  else: info("No pane " & (if dx < 0: "to the left" elif dx > 0: "to the right" elif dy < 0: "above" else: "below"))

proc swapPaneDir(dx, dy: int) =
  ## the active pane's file and the neighbour's change places; the focus goes with the file
  if not splitOn: return
  let a = activePane
  focusDir(dx, dy)
  let b = activePane
  if a == b: return
  let cur = buf()
  panes[b].bufId = cur.id
  panes[b].snap = snapView(cur)
  swap(panes[a].bufId, panes[b].bufId)
  swap(panes[a].snap, panes[b].snap)
  # (the file that was in the active pane is now in b: b keeps the focus, showing it)
  var bi = -1
  for k, x in bufs:
    if x.id == panes[b].bufId: bi = k
  if bi >= 0:
    curBuf = bi
    applyView(bufs[bi], panes[b].snap)
  needRender = true

proc balanceNode(n: PaneNode): int =
  ## every split shares its area by the panes on each side; the panes under n
  if n == nil: return 0
  if n.leaf: return 1
  let x = balanceNode(n.a)
  let y = balanceNode(n.b)
  n.ratio = x.float / float(x + y)
  x + y

proc equalizePanes() =
  discard balanceNode(paneRoot)
  needRender = true

proc toggleZoom() =
  ## the active pane alone, full size — again: the layout as it was
  if not splitOn:
    info("One pane only")
    return
  paneZoom = not paneZoom
  info(if paneZoom: "This pane alone — View: this pane alone again (or ⤡ in its header) for every pane"
       else: "Every pane")
  needRender = true

proc resizePane(vertical: bool, d: int): bool =
  ## Ctrl+Alt+arrows: the nearest split around the active pane that cuts that way, its divider moved
  if not splitOn: return false
  var n = leafOf(paneRoot, activePane)
  var child = n
  while true:
    let par = parentOf(paneRoot, child)
    if par == nil: return false
    if par.vertical == vertical:
      let grow = if par.a == child: d else: -d        # (the active pane grows: its side of the divider)
      par.ratio = clamp(par.ratio + grow.float * 0.04, 0.1, 0.9)
      needRender = true
      return true
    child = par

proc showBeside(src, v: Buffer, down = false) =
  ## (side views: the AST, Compiler Explorer, NIF, the decompiler, a compare) `v` beside `src` — a split of two
  ## when there is one pane, else in the other pane; the focus stays on src
  paneZoom = false                       # (shown beside: every pane shown)
  if not splitOn:
    let k = bufs.find(src)
    if k >= 0: curBuf = k
    panes = @[Pane(bufId: src.id, snap: snapView(src)), Pane(bufId: v.id, snap: snapView(v))]
    paneRoot = PaneNode(leaf: false, vertical: not down, ratio: 0.5, a: PaneNode(leaf: true, pane: 0),
                        b: PaneNode(leaf: true, pane: 1))
    activePane = 0
    paneLast = 1
    splitOn = true
  else:
    let o = otherPane()
    panes[o] = Pane(bufId: v.id, snap: snapView(v), rect: panes[o].rect)
    paneLast = o
  needRender = true

proc toSidePane() =
  ## (Open to the side) the other pane gets the focus — split first: what this pane shows stays there
  if splitOn: focusPane(otherPane())
  elif bufs.len > 0 and not buf().isWelcome(): splitEditor(false)   # (the new pane, the focus: the same file for now)

proc openToSide(path: string, line = -1, col = -1): Buffer =
  toSidePane()
  openFile(path, line, col)

proc moveToOtherPane() =
  ## show the current file in the other pane too (split first when needed)
  let b = buf()
  if not splitOn:
    splitEditor(false)
    return
  let o = otherPane()
  panes[o].bufId = b.id
  panes[o].snap = snapView(b)
  focusPane(o)

proc dropBufFromPanes(id: int) =
  ## buffer `id` closed: the panes (other than the active one) that showed it go
  for i in countdown(panes.high, 0):
    if splitOn and i != activePane and panes[i].bufId == id: closePane(i)

proc paneLayoutPreset(kind: string) =
  ## the open files laid out at once: "columns 2", "columns 3", "grid", "main" (one large, the rest stacked beside)
  let b = buf()
  if b.isWelcome():
    info("Open a file first")
    return
  var files = @[b]
  for x in bufs:
    if x != b and not x.isWelcome() and x.path.len > 0 and files.len < 4: files.add x
  let want = case kind
    of "columns 2": 2
    of "columns 3": 3
    else: 4
  # (room for them: a pane is at least MinPaneW columns and MinPaneH rows)
  let cols = case kind
    of "columns 2": 2
    of "columns 3": 3
    else: 2
  let rows = if kind in ["grid", "main"]: (if kind == "main": 3 else: 2) else: 1
  let roomH = (if lay.crumbY >= 0: lay.crumbY else: lay.textY)
  if lay.edW < cols * MinPaneW + cols - 1 or lay.textY + lay.textH - roomH < rows * MinPaneH + rows - 1:
    info("No room for " & (case kind
      of "columns 2": "two columns"
      of "columns 3": "three columns"
      of "grid": "a grid of four"
      else: "one large and three") & " on this screen")
    return
  while files.len < want: files.add b                     # (fewer files than panes: the same file twice)
  files.setLen(want)
  closeSplit()
  case kind
  of "columns 2", "columns 3":
    for i in 1 ..< want:
      paneLast = activePane
      discard splitPaneOf(activePane, false, files[i])
  of "grid":
    discard splitPaneOf(0, false, files[1])
    discard splitPaneOf(0, true, files[2])
    discard splitPaneOf(1, true, files[3])
  else:                                                    # main: one at the left, three stacked at the right
    discard splitPaneOf(0, false, files[1])
    paneRoot.ratio = 0.6
    discard splitPaneOf(1, true, files[2])
    discard splitPaneOf(2, true, files[3])
  equalizePanes()
  if kind == "main": paneRoot.ratio = 0.6
  focusPane(0)

proc drawPaneHeader(b: Buffer, i, x, y, w: int) =
  if ceIsView(b):
    ceDrawHeader(b, i, x, y, w)                 # (Compiler Explorer's view: its toolbar)
    return
  let active = i == activePane
  let bg = if active: theme.crumbBg else: theme.splitBar      # never the editor's own background
  fillRect(x, y, w, 1, theme.dim, bg)
  if active: discard putStr(x, y, "▎", theme.accent, bg)
  var xx = x + 1
  let lim = x + w - (if paneZoom: 5 else: 3)
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
    if paneZoom and active:
      discard button(x + w - 4, y, "⤡", proc() = toggleZoom(), "Every pane again", theme.accent, bg)
    discard button(x + w - 2, y, ic("close"), proc() = closePane(pi), "Close this pane (Alt+|)", theme.dim, bg)

proc layoutPanes(n: PaneNode, x, y, w, h: int, rects: var seq[tuple[x, y, w, h: int]]) =
  ## the panes' rectangles; a divider (a column or a row) between the two parts of each split
  if n == nil: return
  if n.leaf:
    if n.pane >= 0 and n.pane < rects.len: rects[n.pane] = (x, y, w, h)
    return
  let dc = blend(theme.splitBar, theme.fg, 0.45)
  if n.vertical:
    let w0 = if w >= 2 * MinPaneW + 1: clamp(int(float(w - 1) * n.ratio), MinPaneW, w - 1 - MinPaneW)
             else: max(1, (w - 1) div 2)
    layoutPanes(n.a, x, y, w0, h, rects)
    layoutPanes(n.b, x + w0 + 1, y, max(1, w - w0 - 1), h, rects)
    let k = splitDivs.len
    let c = if dragTarget == dtSplit and dragDiv == k: theme.accent else: dc
    for yy in y ..< y + h: setCell(x + w0, yy, Cell(ch: 0x2502, fg: c, bg: theme.splitBar))
    splitDivs.add (x + w0, y, h, true, n, x, w)
  else:
    let h0 = if h >= 2 * MinPaneH + 1: clamp(int(float(h - 1) * n.ratio), MinPaneH, h - 1 - MinPaneH)
             else: max(1, (h - 1) div 2)
    layoutPanes(n.a, x, y, w, h0, rects)
    layoutPanes(n.b, x, y + h0 + 1, w, max(1, h - h0 - 1), rects)
    let k = splitDivs.len
    let c = if dragTarget == dtSplit and dragDiv == k: theme.accent else: dc
    for xx in x ..< x + w: setCell(xx, y + h0, Cell(ch: 0x2500, fg: c, bg: theme.splitBar))
    splitDivs.add (x, y + h0, w, false, n, y, h)

proc drawSplit(): bool =
  ## every pane: the inactive ones first, the active one last, so its geometry (editorRect, gutterW, textW …) is
  ## what the mouse and scrolling code see afterwards. false = nothing to split any more
  var gone: seq[int]
  for i in 0 ..< panes.len:
    if i != activePane and bufById(panes[i].bufId) == nil: gone.add i
  for k in countdown(gone.high, 0): closePane(gone[k])      # (a pane whose file was closed)
  if not splitOn: return false
  let top = if lay.crumbY >= 0: lay.crumbY else: lay.textY
  let fullH = lay.textY + lay.textH - top
  var rects = newSeq[tuple[x, y, w, h: int]](panes.len)
  splitDivs.setLen(0)
  if paneZoom:
    for i in 0 ..< panes.len: rects[i] = (0, 0, 0, 0)
    rects[activePane] = (lay.edX, top, lay.edW, fullH)
  elif phoneFlip():
    paneRoot.vertical = false              # (for the layout only: the tree keeps them side by side)
    layoutPanes(paneRoot, lay.edX, top, lay.edW, fullH, rects)
    paneRoot.vertical = true
  else:
    layoutPanes(paneRoot, lay.edX, top, lay.edW, fullH, rects)
  var order: seq[int]
  for i in 0 ..< panes.len:
    if i != activePane: order.add i
  order.add activePane
  for i in order:
    let r = rects[i]
    panes[i].rect = r
    if r.w <= 0 or r.h <= 0: continue
    let pb = if i == activePane: buf() else: bufById(panes[i].bufId)
    if pb == nil: continue
    var saved: ViewSnap
    if i != activePane:
      saved = snapView(pb)
      applyView(pb, panes[i].snap)
    drawPaneHeader(pb, i, r.x, r.y, r.w)
    drawEditor(pb, r.x, r.y + 1, r.w, max(1, r.h - 1), i == activePane)
    panes[i].gutterW = gutterW
    panes[i].textW = textW
    panes[i].textH = textH
    if i != activePane:
      panes[i].snap = snapView(pb)
      applyView(pb, saved)
    else: panes[i].bufId = pb.id
  true

proc nodeJson(n: PaneNode): JsonNode =
  ## the layout as JSON, each pane by its file (a pane with no file: null)
  if n == nil: return newJNull()
  if n.leaf:
    let b = if n.pane == activePane: buf() else: bufById(panes[n.pane].bufId)
    let top = if n.pane == activePane or b == nil: (if b != nil: b.topLine else: 0) else: panes[n.pane].snap.topLine
    return (if b != nil and b.path.len > 0: %*{"file": b.path, "active": n.pane == activePane, "top": top}
            else: newJNull())
  let a = nodeJson(n.a)
  let b = nodeJson(n.b)
  if a.kind == JNull: return b
  if b.kind == JNull: return a
  %*{"vertical": n.vertical, "ratio": n.ratio, "a": a, "b": b}

proc layoutState(): JsonNode =
  result = %*{"left": treeOpen, "leftView": $sideView, "right": rightOpen, "rightView": $rightView,
              "panel": panelOpen, "panelKind": $panelKind}
  if splitOn:
    let t = nodeJson(paneRoot)
    if t.kind == JObject and t{"file"} == nil: result["panes"] = t

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
    if buf().isWelcome(): return
    var t = savedLayout{"panes"}
    if t == nil and savedLayout{"split"} != nil:
      # (a session of 6.30 or before: two panes)
      let sp = savedLayout{"split"}
      let i = bufIndexByPath(sp{"other"}.getStr)
      if i >= 0 and i != curBuf:
        let me = %*{"file": buf().path, "active": true}
        let other = %*{"file": bufs[i].path}
        let first = sp{"active"}.getInt == 0
        t = %*{"vertical": not sp{"down"}.getBool, "ratio": 0.5, "a": (if first: me else: other),
               "b": (if first: other else: me)}
    if t == nil or t.kind != JObject: return
    var ps: seq[Pane]
    var act = -1
    proc build(j: JsonNode): PaneNode =
      if j == nil or j.kind != JObject: return nil
      if j{"file"} != nil:
        let k = bufIndexByPath(j{"file"}.getStr)
        if k < 0: return nil
        let b = bufs[k]
        var sn = snapView(b)
        sn.topLine = clamp(j{"top"}.getInt(b.topLine), 0, b.lines.high)
        ps.add Pane(bufId: b.id, snap: sn)
        if j{"active"}.getBool: act = ps.high
        return PaneNode(leaf: true, pane: ps.high)
      let a = build(j{"a"})
      let b = build(j{"b"})
      if a == nil: return b
      if b == nil: return a
      PaneNode(leaf: false, vertical: j{"vertical"}.getBool(true), ratio: clamp(j{"ratio"}.getFloat(0.5), 0.1, 0.9),
               a: a, b: b)
    let root = build(t)
    if root == nil or root.leaf or ps.len < 2: return
    panes = ps
    paneRoot = root
    activePane = if act >= 0: act else: 0
    splitOn = true
    let k = bufIndexByPath(bufById(panes[activePane].bufId).path)
    if k >= 0:
      curBuf = k
      applyView(bufs[k], panes[activePane].snap)
  except CatchableError: discard
