# ── clickable regions (rebuilt every frame; the last match is the topmost) ──

type Region = object
  x, y, w, h: int
  act, rightAct: Action
  tip: string

var
  regions: seq[Region]
  modalStart = -1          # regions[modalStart..] belong to the open modal (menu/dialog)
  mouseX = -1
  mouseY = -1
  mouseMovedAt: MonoTime
  tipShown = false

proc region(x, y, w, h: int, act: Action, tip = "", rightAct: Action = nil) =
  if w <= 0 or h <= 0: return
  regions.add Region(x: x, y: y, w: w, h: h, act: act, rightAct: rightAct, tip: tip)

proc hitRegion(x, y: int, fromIdx = 0): int =
  for i in countdown(regions.high, max(0, fromIdx)):
    let r = regions[i]
    if x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h: return i
  -1

proc hov(x, y, w: int, h = 1): bool {.inline.} =
  cfgHoverFx and mouseX >= x and mouseX < x + w and mouseY >= y and mouseY < y + h

proc shadeRect(x, y, w, h: int) =
  ## darken cells (drop shadow) — keeps the characters, only dims colours
  if not cfgShadows: return
  for yy in max(0, y) ..< min(scrH, y + h):
    for xx in max(0, x) ..< min(scrW, x + w):
      let i = yy * scrW + xx
      grid[i].bg = blend(grid[i].bg, 0x000000'u32, (if theme.dark: 0.45 else: 0.18))
      grid[i].fg = blend(grid[i].fg, grid[i].bg, 0.5)

proc dropShadow(x, y, w, h: int) =
  ## a soft shadow under a box at x, y (w × h): half a cell wide on its right, half a cell high below it — block
  ## characters in a darker shade of what they cover (ui.shadows)
  if not cfgShadows: return
  let k = if theme.dark: 0.55 else: 0.22
  proc put(xx, yy: int, ch: uint32) =
    if xx < 0 or yy < 0 or xx >= scrW or yy >= scrH: return
    let i = yy * scrW + xx
    let under = grid[i].bg
    if grid[i].ch in [32'u32, 0x2502, 0x2503, 0x258C, 0x2580, 0x2598, 0x2590] or grid[i].ch == 0:
      # a blank (or a line, or an earlier shadow): the half block
      setCell(xx, yy, Cell(ch: ch, fg: blend(under, 0x000000'u32, k), bg: under))
    else:
      # text stays readable: a little darker, not hidden
      grid[i].bg = blend(under, 0x000000'u32, k * 0.4)
      grid[i].fg = blend(grid[i].fg, grid[i].bg, 0.35)
  for yy in y + 1 ..< y + h: put(x + w, yy, 0x258C)      # ▌
  for xx in x + 1 ..< x + w: put(xx, y + h, 0x2580)      # ▀
  put(x + w, y + h, 0x2598)                              # ▘

proc drawFrame(x, y, w, h: int, bg, border: Rgb, title = "", titleFg: Rgb = NoColor, shadow = true) =
  fillRect(x, y, w, h, theme.fg, bg)
  for xx in x + 1 ..< x + w - 1:
    setCell(xx, y, Cell(ch: 0x2500, fg: border, bg: bg))
    setCell(xx, y + h - 1, Cell(ch: 0x2500, fg: border, bg: bg))
  for yy in y + 1 ..< y + h - 1:
    setCell(x, yy, Cell(ch: 0x2502, fg: border, bg: bg))
    setCell(x + w - 1, yy, Cell(ch: 0x2502, fg: border, bg: bg))
  setCell(x, y, Cell(ch: 0x256D, fg: border, bg: bg))
  setCell(x + w - 1, y, Cell(ch: 0x256E, fg: border, bg: bg))
  setCell(x, y + h - 1, Cell(ch: 0x2570, fg: border, bg: bg))
  setCell(x + w - 1, y + h - 1, Cell(ch: 0x256F, fg: border, bg: bg))
  if title.len > 0:
    discard putStr(x + 2, y, " " & truncTo(title, w - 6) & " ", (if titleFg == NoColor: theme.accent else: titleFg),
                   bg, {aBold}, x + w - 1)
  if shadow: dropShadow(x, y, w, h)

proc button(x, y: int, label: string, act: Action, tip = "", fg: Rgb = NoColor, bg: Rgb = NoColor,
            at: set[Attr] = {}, hoverBg: Rgb = NoColor): int =
  ## a flat button; returns the x after it
  let w = strWidth(label)
  let baseBg = if bg == NoColor: grid[clamp(y, 0, scrH - 1) * scrW + clamp(x, 0, scrW - 1)].bg else: bg
  let isH = hov(x, y, w)
  let b2 = if isH: (if hoverBg == NoColor: blend(baseBg, theme.fg, 0.14) else: hoverBg) else: baseBg
  result = putStr(x, y, label, (if fg == NoColor: theme.fg else: fg), b2, at)
  region(x, y, w, 1, act, tip)

proc pill(x, y: int, label: string, act: Action, tip = "", fg: Rgb = NoColor, bg: Rgb = NoColor,
          at: set[Attr] = {}, hoverBg: Rgb = NoColor): int =
  ## a button with rounded-looking ends — half blocks in its colour — for dialogs and toasts; returns the x after it
  let w = strWidth(label) + 4
  let under = grid[clamp(y, 0, scrH - 1) * scrW + clamp(x, 0, scrW - 1)].bg
  let base = if bg == NoColor: theme.btnBg else: bg
  let b = if hov(x, y, w): (if hoverBg == NoColor: blend(base, theme.fg, 0.14) else: hoverBg) else: base
  setCell(x, y, Cell(ch: 0x2590, fg: b, bg: under))              # ▐
  discard putStr(x + 1, y, " " & label & " ", (if fg == NoColor: theme.fg else: fg), b, at)
  setCell(x + w - 1, y, Cell(ch: 0x258C, fg: b, bg: under))      # ▌
  region(x, y, w, 1, act, tip)
  x + w
