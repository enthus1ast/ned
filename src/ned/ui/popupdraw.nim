# ── toasts & dialogs drawing ──

proc sevIcon(sev: int): (string, Rgb) =
  ## the icon and its colour for a severity: 1 error, 2 warning, 4 ok, anything else info
  case sev
  of 1: (ic("error"), theme.err)
  of 2: (ic("warn"), theme.warn)
  of 4: (ic("ok"), theme.gitAdd)
  else: (ic("info"), theme.accent)

proc drawToasts(bottom: int) =
  ## draws the notifications as framed boxes stacked at the right edge from just above row `bottom` upwards (newest at
  ## the bottom), each with its severity icon, wrapped text (up to 10 lines for a message, 3 for a notification), a
  ## dismiss button and, if it has one, its action button; a click closes a message and a right click opens its menu
  if toasts.len == 0: return
  var y = bottom
  for ti in countdown(toasts.high, 0):
    let t = toasts[ti]
    var tw = 0
    for l in t.text.splitLines: tw = max(tw, strWidth(l))
    let w = min(scrW - 2, max(40, min(96, tw + 9)))
    var lines: seq[string]
    for l in t.text.splitLines: lines.add wrapText(l, w - 8)
    let n = min((if t.fromMsg: 10 else: 3), lines.len)
    let h = n + 2 + (if t.act != nil: 1 else: 0)
    y -= h
    if y < 1: break
    let x = scrW - w - 1
    drawFrame(x, y, w, h, theme.toastBg, blend(theme.toastBg, sevIcon(t.sev)[1], 0.55))
    let ri = ti
    let isMsg = t.fromMsg
    capture ri, isMsg:
      region(x, y, w, h, proc() =
        if isMsg and ri < toasts.len: toasts.delete(ri), "", proc() = ctxOpen(toastMenu(ri)))   # a click closes a message
    let (icn, icc) = sevIcon(t.sev)
    discard putStr(x + 2, y + 1, icn, icc, theme.toastBg, {aBold})
    for i in 0 ..< n:
      discard putStr(x + 4, y + 1 + i, lines[i], theme.fg, theme.toastBg, {}, x + w - 3)
    let idx = ti
    let a = t.act
    let lbl = t.actLabel
    capture idx, a, lbl, n:
      discard button(x + w - 3, y + 1, ic("close"), proc() =
        if idx < toasts.len: toasts.delete(idx), "Dismiss", theme.dim, theme.toastBg)
      if a != nil:
        discard pill(x + 3, y + 1 + n, lbl, proc() =
          if idx < toasts.len: toasts.delete(idx)
          a(), "", theme.badgeFg, theme.accent, {aBold}, blend(theme.accent, theme.fg, 0.2))
    dec y

proc drawDialog() =
  ## draws the top modal dialog over a shaded screen: a framed box (in the warning colour when dangerous) with its
  ## wrapped text and buttons at the bottom right, the selected button highlighted; clicks outside are swallowed
  if dialogs.len == 0: return
  let d = dialogs[^1]
  shadeRect(0, 0, scrW, scrH)
  let w = min(scrW - 4, max(44, min(70, strWidth(d.body) + 8)))
  let lines = wrapText(d.body, w - 6)
  var btnW = 0
  for (l, _) in d.buttons: btnW += strWidth(l) + 4 + 1
  let h = lines.len + 6
  let (x, y) = boxPlace("dialog", (scrW - w) div 2, max(1, (scrH - h) div 2 - 2), w, h)
  modalStart = regions.len
  region(0, 0, scrW, scrH, proc() = discard)          # swallow clicks outside
  drawFrame(x, y, w, h, theme.menuBg, (if d.danger: theme.warn else: theme.accent), d.title,
            (if d.danger: theme.warn else: theme.accent))
  for i, l in lines:
    discard putStr(x + 3, y + 2 + i, l, theme.fg, theme.menuBg, {}, x + w - 2)
  var bx = x + w - 2 - btnW
  if bx < x + 2: bx = x + 2
  let by = y + h - 2
  for i, (label, key) in d.buttons:
    let primary = i == d.sel
    let bg = if primary: (if d.danger: theme.warn else: theme.accent) else: theme.btnBg
    let fg = if primary: theme.badgeFg else: theme.fg
    let kk = key
    capture kk:
      bx = pill(bx, by, label, proc() = closeDialog(kk), "", fg, bg, (if primary: {aBold} else: {}),
                blend(bg, theme.fg, 0.15)) + 1
  cursorX = -1

proc dialogKey(k: Key) =
  ## the keys of the top dialog: arrows and Tab choose a button, Enter uses it, Esc answers as cancel (as "no" for a
  ## two-button yes/no), and a letter that is a button's key answers with it
  if dialogs.len == 0: return
  # the top dialog
  template d: untyped = dialogs[^1]
  case k.kind
  of kLeft, kUp: d.sel = (d.sel - 1 + d.buttons.len) mod d.buttons.len
  of kRight, kDown, kTab: d.sel = (d.sel + 1) mod d.buttons.len
  of kEnter: closeDialog(d.buttons[d.sel][1])
  of kEsc:
    var c = 'c'
    for (_, kk) in d.buttons:
      if kk == 'n' and d.buttons.len == 2: c = 'n'
    closeDialog(c)
  of kChar:
    if k.ch < 128:
      let c = toLowerAscii(char(k.ch))
      for (_, kk) in d.buttons:
        if kk == c:
          closeDialog(c)
          return
  else: discard
  needRender = true

# ── tooltips ──

proc drawTooltip() =
  ## draws the tooltip of the click region under the pointer once it has stayed still for 650 ms, below the pointer
  ## (above it near the bottom); none while a menu, dialog or picker is open
  if not cfgTooltips or mouseX < 0 or msSince(mouseMovedAt) < 650 or menuOpen() or dialogOpen() or
     pickKind != pickNone: return                       # a list opened over the place: no tip from what is under it
  let i = hitRegion(mouseX, mouseY)
  if i < 0 or regions[i].tip.len == 0: return
  let t = regions[i].tip
  let w = strWidth(t) + 2
  let x = clamp(mouseX - w div 2, 0, max(0, scrW - w))
  var y = mouseY + 1
  if y >= scrH - 1: y = mouseY - 1
  fillRect(x, y, w, 1, theme.fg, theme.toastBg)
  discard putStr(x + 1, y, t, theme.fg, theme.toastBg)
  dropShadow(x, y, w, 1)
  tipShown = true
