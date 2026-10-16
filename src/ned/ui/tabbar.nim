# ── editor tab bar ──

var tabScroll = 0

proc tabMenu(i: int): seq[MenuItem] =
  let idx = i
  @[mi("Close", "Ctrl+W", proc() = closeBuffer(idx)),
    mi("Close others", "", proc() =
      if idx < bufs.len:
        curBuf = idx
        runCmd("Close other tabs")),
    mi("Close to the right", "", proc() =
      for j in countdown(bufs.high, idx + 1):
        if not bufs[j].dirty: closeBufferAt(j)),
    mi("Close saved", "", proc() =
      for j in countdown(bufs.high, 0):
        if not bufs[j].dirty and bufs.len > 1: closeBufferAt(j)),
    mi("Reopen closed tab", "Alt+Shift+T", proc() = reopenClosedTab()),
    msep(),
    mi("Copy path", "", proc() =
      if idx < bufs.len and bufs[idx].path.len > 0:
        clipSet(bufs[idx].path)
        info("Copied " & bufs[idx].path)),
    mi("Reveal in files", "", proc() =
      if idx < bufs.len and bufs[idx].path.len > 0:
        showSide(svFiles)
        revealInTree(bufs[idx].path))]

proc drawTabBar() =
  let y = lay.tabY
  if y < 0: return
  let x0 = lay.edX
  let w = lay.edW
  fillRect(x0, y, w, 1, theme.dim, theme.tabBarBg)
  tabRanges.setLen(0)
  closeRanges.setLen(0)
  let actW = 4
  let avail = x0 + w - actW
  var widths: seq[int]
  for b in bufs: widths.add strWidth(b.name) + 6
  tabScroll = clamp(tabScroll, 0, bufs.high)
  if curBuf < tabScroll: tabScroll = curBuf
  var used = 0
  for i in tabScroll .. curBuf: used += widths[i]
  while used > avail - x0 - 2 and tabScroll < curBuf:
    used -= widths[tabScroll]
    inc tabScroll
  var x = x0
  if tabScroll > 0:
    x = button(x, y, "‹", proc() = (tabScroll = max(0, tabScroll - 1)), "", theme.dim, theme.tabBarBg)
  for i in tabScroll .. bufs.high:
    if x >= avail: break
    let b = bufs[i]
    let active = i == curBuf
    let tw = widths[i]
    let isH = hov(x, y, tw)
    # the active tab shares the breadcrumb bar's shade (one header for the file) when that bar is shown
    let bg = if active: (if lay.crumbY >= 0 and not splitOn: theme.crumbBg else: theme.bg)
             elif isH: theme.hoverBg else: theme.tabBarBg
    let fg = if active: theme.fg else: theme.dim
    let tx0 = x
    fillRect(x, y, min(tw, avail - x), 1, fg, bg)
    if active: discard putStr(x, y, "▎", theme.accent, bg)
    elif splitOn and b.id == panes[1 - activePane].bufId:
      discard putStr(x, y, "▎", blend(theme.accent, bg, 0.55), bg)     # shown in the other pane
    var xx = x + 1
    if b.path.len > 0:
      xx = putStr(xx, y, fileIcon(b.path), langColor(b.path), bg, {}, avail)
    elif b.title.len > 0: xx = putStr(xx, y, ic("spark"), theme.accent, bg, {}, avail)
    else: xx = putStr(xx, y, " ", fg, bg, {}, avail)
    xx = putStr(xx + 1, y, b.name, fg, bg, (if active: {aBold} else: {}), avail)
    let cx = xx + 1
    if cx < avail:
      let showClose = active or isH
      let mark = if b.dirty and not (isH and hov(cx, y, 1)): ic("dirty") elif showClose: ic("close") else: " "
      let mfg = if b.dirty: theme.accent elif hov(cx, y, 1): theme.fg else: theme.dim
      discard putStr(cx, y, mark, mfg, bg)
      closeRanges.add (cx, cx + 1, i)
    let idx = i
    let tip = b.path
    capture idx, tip, cx, tx0, tw, avail, y:
      region(tx0, y, min(tw, avail - tx0), 1, proc() =
        if idx < bufs.len:            # (a second click before the tabs were redrawn may be stale)
          curBuf = idx
          focus = fEditor
          closeComp(), tip, proc() = (if idx < bufs.len: openMenu(tabMenu(idx), mouseX, y + 1)))
      if cx < avail:
        # on a phone the close mark takes the space around it too: easier to hit with a finger
        if lay.overlay: region(cx - 1, y, min(3, avail - cx + 1), 1, proc() = closeBuffer(idx), "Close (Ctrl+W)")
        else: region(cx, y, 1, 1, proc() = closeBuffer(idx), "Close (Ctrl+W)")
    tabRanges.add (tx0, x + tw, i)
    x += tw
    if not active and i + 1 < bufs.len and i + 1 != curBuf and x < avail:
      setCell(x - 1, y, Cell(ch: 0x2502, fg: theme.border, bg: theme.tabBarBg))
  if x >= avail and tabScroll + tabRanges.len < bufs.len:
    discard button(avail - 1, y, "›", proc() = (tabScroll = min(bufs.high, tabScroll + 1)), "", theme.dim, theme.tabBarBg)
  discard button(x0 + w - actW + 1, y, " " & ic("more") & " ", proc() = openMenu(tabMenu(curBuf), x0 + w - 20, y + 1),
                 "Tab actions", theme.dim, theme.tabBarBg)
