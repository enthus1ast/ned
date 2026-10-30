# ── menus ──

type
  MenuItem = object
    label, keys: string
    act: Action
    sep: bool
    check: int            # -1 none, 0 off, 1 on
    sub: seq[MenuItem]
    disabled: bool
  MenuState = object
    items: seq[MenuItem]
    x, y, w, sel: int
    bar: int              # index in the menu bar this dropdown belongs to (-1 = context menu)
    top, rows: int        # the first item shown, and how many fit (a long menu on a small screen scrolls)

var
  menus: seq[MenuState]
  menuBarRanges: seq[(int, int, int)]     # x0, x1, index

func mi(label: string, keys = "", act: Action = nil, check = -1, disabled = false): MenuItem =
  ## a menu item: its label, the key text shown at the right, what it does, a tick state (-1 none, 0 off, 1 on) and
  ## whether it is disabled
  MenuItem(label: label, keys: keys, act: act, check: check, disabled: disabled)
# a separator line between menu items
func msep(): MenuItem = MenuItem(sep: true)
# a menu item that opens a submenu of `sub`
func msub(label: string, sub: seq[MenuItem]): MenuItem = MenuItem(label: label, sub: sub, check: -1)

# whether a menu is showing (it then takes the keys)
proc menuOpen(): bool {.inline.} = menus.len > 0

proc menuWidth(items: seq[MenuItem]): int =
  ## the width a menu needs: its longest label and longest key text plus the margins, at most the screen's width less 2
  var lw, kw = 0
  for it in items:
    lw = max(lw, strWidth(it.label))
    kw = max(kw, strWidth(it.keys))
  min(scrW - 2, lw + kw + 8)

proc menuKeepSel(m: var MenuState) =
  ## scroll a long menu so its selected item is shown
  if m.rows <= 0 or m.rows >= m.items.len: return
  if m.sel < m.top: m.top = m.sel
  if m.sel >= m.top + m.rows: m.top = m.sel - m.rows + 1
  m.top = clamp(m.top, 0, m.items.len - m.rows)

proc openMenu(items: seq[MenuItem], x, y: int, bar = -1) =
  ## opens a menu (or a submenu on top of the ones open) at x, y, moved to fit on the screen; the first item that can be
  ## chosen is selected, and a menu longer than the screen scrolls. `bar` is the menu-bar entry it belongs to, -1 for a
  ## context menu (which moves up to fit; a bar's dropdown stays under the bar)
  var w = menuWidth(items)
  var mx = clamp(x, 0, max(0, scrW - w - 1))
  var my = y
  let h = items.len + 2
  # a menu bar's dropdown stays under the bar (and scrolls if it is longer than the screen); a context menu
  # or submenu moves up to fit first
  if my + h > scrH - 1 and bar < 0: my = max(0, scrH - 1 - h)
  let rows = max(3, min(items.len, scrH - 1 - my - 2))
  var sel = 0
  while sel < items.high and (items[sel].sep or items[sel].disabled): inc sel
  var m = MenuState(items: items, x: mx, y: my, w: w, sel: sel, bar: bar, rows: rows)
  m.menuKeepSel()
  menus.add m
  needRender = true

proc menuScroll(level, d: int) =
  ## scrolls the menu at that level by `d` items when it is longer than its room
  if level < 0 or level >= menus.len: return
  # the menu being scrolled
  template m: untyped = menus[level]
  if m.rows >= m.items.len: return
  m.top = clamp(m.top + d, 0, m.items.len - m.rows)
  needRender = true

proc closeMenus() =
  ## closes every open menu
  menus.setLen(0)
  needRender = true

proc activateMenuItem(level, idx: int) =
  ## uses an item of the menu at that level: a submenu opens beside it (closing any deeper one), a separator or disabled
  ## item does nothing, else all menus close and the item's action runs
  if level >= menus.len or idx < 0 or idx >= menus[level].items.len: return
  let it = menus[level].items[idx]
  if it.sep or it.disabled: return
  if it.sub.len > 0:
    menus.setLen(level + 1)
    menus[level].sel = idx
    let m = menus[level]
    openMenu(it.sub, m.x + m.w - 1, m.y + 1 + idx - m.top)
    return
  closeMenus()
  if it.act != nil: it.act()
proc openMenuBar(i: int)

proc drawMenus() =
  ## draws the open menus, each in a frame at its place: the items with their tick, label, key text or submenu arrow,
  ## separators, the selected or hovered item highlighted, arrows on the frame when a long menu can scroll; every item
  ## is clickable and the frame swallows clicks between them
  for level, m in menus:
    let rows = if m.rows > 0: min(m.rows, m.items.len) else: m.items.len
    let h = rows + 2
    if level == 0: modalStart = regions.len
    drawFrame(m.x, m.y, m.w, h, theme.menuBg, theme.border)
    region(m.x, m.y, m.w, h, proc() = discard)     # the frame swallows clicks between items
    if rows < m.items.len:
      # more above / below: arrows on the frame (a click, the wheel or the arrow keys scroll)
      let lv = level
      let mid = m.x + m.w div 2 - 1
      if m.top > 0:
        discard putStr(mid, m.y, " ▲ ", theme.accent, theme.menuBg, {aBold})
        capture lv:
          region(mid, m.y, 3, 1, proc() = menuScroll(lv, -5), "More above")
      if m.top + rows < m.items.len:
        discard putStr(mid, m.y + h - 1, " ▼ ", theme.accent, theme.menuBg, {aBold})
        capture lv:
          region(mid, m.y + h - 1, 3, 1, proc() = menuScroll(lv, 5), "More below")
    var lw = 0
    for it in m.items: lw = max(lw, strWidth(it.label))
    for i, it in m.items:
      if i < m.top or i >= m.top + rows: continue
      let y = m.y + 1 + i - m.top
      if it.sep:
        for xx in m.x + 1 ..< m.x + m.w - 1: setCell(xx, y, Cell(ch: 0x2500, fg: theme.border, bg: theme.menuBg))
        setCell(m.x, y, Cell(ch: 0x251C, fg: theme.border, bg: theme.menuBg))
        setCell(m.x + m.w - 1, y, Cell(ch: 0x2524, fg: theme.border, bg: theme.menuBg))
        continue
      let selected = i == m.sel or hov(m.x + 1, y, m.w - 2)
      let bg = if selected and not it.disabled: theme.menuSel else: theme.menuBg
      fillRect(m.x + 1, y, m.w - 2, 1, theme.fg, bg)
      let fg = if it.disabled: theme.dim else: theme.fg
      if it.check == 1: discard putStr(m.x + 1, y, "✓", theme.accent, bg, {aBold})
      elif it.check == 0: discard putStr(m.x + 1, y, " ", theme.dim, bg)
      discard putStr(m.x + 3, y, it.label, fg, bg, {}, m.x + m.w - 2)
      if it.sub.len > 0: discard putStr(m.x + m.w - 3, y, "›", theme.dim, bg)
      elif it.keys.len > 0:
        # (only in the room the label leaves: a narrow screen's menu drew the keys over the label and the frame)
        let room = m.w - 6 - strWidth(it.label)
        if room >= 3:
          let ks = if strWidth(it.keys) <= room: it.keys else: truncTo(it.keys, room)
          discard putStr(m.x + m.w - 2 - strWidth(ks), y, ks, theme.dim, bg, {}, m.x + m.w - 1)
      let lv = level
      let idx = i
      let rx = m.x + 1
      let rw = m.w - 2
      capture lv, idx:
        region(rx, y, rw, 1, proc() = activateMenuItem(lv, idx))

proc menuKey(k: Key) =
  ## the keys of the open menus (the top one): Up, Down, Home, End and Page Up/Down move over items that can be chosen,
  ## Enter or Right open the item or submenu, Left and Esc close a submenu (Left and Right at the top level move to the
  ## next or previous menu-bar menu), F10 closes all, and a letter jumps to the item that starts with it (and uses it
  ## when it is the only one)
  if menus.len == 0: return
  let lv = menus.high
  # the top menu
  template m: untyped = menus[lv]
  proc move(d: int) =
    ## moves the selection `d` items, wrapping round and stepping over separators and disabled items
    let n = menus[lv].items.len
    var s = menus[lv].sel
    for _ in 0 ..< n:
      s = (s + d + n) mod n
      if not menus[lv].items[s].sep and not menus[lv].items[s].disabled: break
    menus[lv].sel = s
  case k.kind
  of kUp: move(-1)
  of kDown: move(1)
  of kHome:
    m.sel = -1
    move(1)
  of kEnd:
    m.sel = m.items.len
    move(-1)
  of kEnter: activateMenuItem(lv, m.sel)
  of kRight:
    if m.sel >= 0 and m.sel < m.items.len and m.items[m.sel].sub.len > 0: activateMenuItem(lv, m.sel)
    elif menus[0].bar >= 0: openMenuBar(menus[0].bar + 1)
  of kLeft:
    if lv > 0: menus.setLen(lv)
    elif menus[0].bar >= 0: openMenuBar(menus[0].bar - 1)
  of kEsc:
    if lv > 0: menus.setLen(lv) else: closeMenus()
  of kPgUp, kPgDn:
    for _ in 0 ..< max(1, m.rows - 1): move(if k.kind == kPgUp: -1 else: 1)
  of kFn:
    if k.fn == 10: closeMenus()
  of kChar:
    if k.mods == {} and k.ch < 128:
      # first letter jumps to (and activates if unique) the matching item
      let c = toLowerAscii(char(k.ch))
      var hits: seq[int]
      for i, it in m.items:
        if not it.sep and not it.disabled and it.label.len > 0 and toLowerAscii(it.label[0]) == c: hits.add i
      if hits.len == 1: activateMenuItem(lv, hits[0])
      elif hits.len > 1:
        var nx = hits[0]
        for h in hits:
          if h > m.sel:
            nx = h
            break
        m.sel = nx
  else: discard
  if lv < menus.len: menus[lv].menuKeepSel()
  needRender = true

# (the context menus, ui/contextmenus.nim)
proc fieldMenu(tp: ptr string, cp: ptr int): seq[MenuItem]        # ui/contextmenus.nim
proc gutterMenu(l: int): seq[MenuItem]
proc statusBarMenu(): seq[MenuItem]
proc statusPosMenu(): seq[MenuItem]
proc statusEolMenu(): seq[MenuItem]
proc statusLangMenu(): seq[MenuItem]
proc statusAiMenu(): seq[MenuItem]
proc statusTermMenu(): seq[MenuItem]
proc statusLsMenu(): seq[MenuItem]
proc statusProblemsMenu(): seq[MenuItem]
proc titleBarMenu(): seq[MenuItem]
proc dockHeaderMenu(side: DockSide): seq[MenuItem]
proc dockItemMenu(it: SideItem, v: SideView, isRight: bool): seq[MenuItem]
proc panelHeaderMenu(): seq[MenuItem]
proc panelLineMenu(i: int): seq[MenuItem]
proc breadcrumbMenu(): seq[MenuItem]
proc minimapMenu(): seq[MenuItem]
proc toastMenu(i: int): seq[MenuItem]
proc paneHeaderMenu(i: int): seq[MenuItem]
proc ctxOpen(items: seq[MenuItem])
proc ctxCopy(label, text: string): MenuItem
