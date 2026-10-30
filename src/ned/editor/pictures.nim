# ── pictures: a .png, .jpg, .gif or .bmp file opens as a picture (Tab: its bytes in the hex editor, Shift+Tab
#    back), and a Markdown preview shows the pictures it has. Drawn in the terminal's cells (▀, two pixels a cell:
#    in any terminal, Termux too) — and, where the terminal draws pictures itself (kitty, iTerm2, sixel), by the
#    terminal over them, sharper ──

const PicExts = [".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp"]

type PicView = object
  zoom: float                       # 1: the picture fits the view
  panX, panY: int                   # what of a zoomed picture is shown: its left and top, in cells and rows
  hex: bool                         # Tab: the bytes instead (Shift+Tab: the picture again)

var
  picViews: Table[int, PicView]     # buffer id → its picture view
  picDec: Table[string, (int64, int, int, ImgPicture, string)]   # path → (its time, the size asked for (w, h), it, why not)
  picSizes: Table[string, (int64, int, int)]                     # path → (its time, its width, its height)
  picBlocks: Table[string, seq[seq[(uint32, uint32)]]]           # (a path and size) → its cells
  picKittyId = 7300                 # (the kitty pictures' numbers)

# whether a file name ends in one of the picture extensions ned shows as pictures
proc isPicturePath(path: string): bool = splitFile(path).ext.toLowerAscii in PicExts

proc picTime(path: string): int64 =
  ## a stamp for the picture file's version — its modification time in milliseconds with a bit of its size — that the
  ## caches compare to see that the file changed; -1 when it cannot be read
  try: getLastModificationTime(path).toUnix * 1000 + getFileSize(path) mod 1000
  except CatchableError: -1

proc picSize(path: string): (int, int) =
  ## its width and height, from its header (kept until the file changes)
  let t = picTime(path)
  picSizes.withValue(path, e):
    if e[][0] == t: return (e[][1], e[][2])
  var data = ""
  try:
    let f = open(path)
    defer: f.close()
    data = newString(min(getFileSize(path), 262_144))
    data.setLen(f.readBuffer(addr data[0], data.len))
  except CatchableError: return (0, 0)
  result = imgSize(data)
  picSizes[path] = (t, result[0], result[1])

proc picGet(path: string, wantW, wantH: int): (ImgPicture, string) =
  ## the picture, decoded once at a size good for wantW × wantH pixels (a big JPEG at a fraction of its size)
  let t = picTime(path)
  picDec.withValue(path, e):
    if e[][0] == t and e[][1] >= wantW and e[][2] >= wantH: return (e[][3], e[][4])
  # (a picture far bigger than any view, not a JPEG — which is read at a fraction of its size —: not read whole
  # into memory on a phone)
  let (iw, ih) = picSize(path)
  let jpeg = splitFile(path).ext.toLowerAscii in [".jpg", ".jpeg"]
  if not jpeg and iw.int64 * ih.int64 > 40_000_000:
    let why = "Too big to show here (" & $iw & "×" & $ih & ") — Tab: its bytes"
    picDec[path] = (t, wantW, wantH, ImgPicture(), why)
    return (ImgPicture(), why)
  var (p, why) = imgDecodeFile(path, wantW, wantH)
  if why.len > 0 and splitFile(path).ext.toLowerAscii == ".webp":
    # (WebP: an outside converter, when there is one, makes a PNG of it)
    let tmp = privTmp("webp") & ".png"
    for cmd in ["dwebp " & quoteShell(path) & " -o " & quoteShell(tmp), "magick " & quoteShell(path) & " " & quoteShell(tmp),
                "convert " & quoteShell(path) & " " & quoteShell(tmp)]:
      let exe = cmd.split(' ')[0]
      if not haveExe(exe): continue
      let (ok, _, _) = runFilter(cmd & " 2>/dev/null", "", parentDir(path), 15000)
      if ok and fileExists(tmp):
        (p, why) = imgDecodeFile(tmp, wantW, wantH)
        try: removeFile(tmp)
        except CatchableError: discard
        break
    if why.len > 0: why = "WebP pictures need dwebp or ImageMagick to be shown (pkg install libwebp)"
  picDec[path] = (t, wantW, wantH, p, why)
  if picDec.len > 24:
    var old: seq[string]
    for k in picDec.keys:
      if k != path and old.len < 8: old.add k
    for k in old: picDec.del k
  (p, why)

proc picCells(path: string, cols, rows: int, bg: Rgb): seq[seq[(uint32, uint32)]] =
  ## the picture in cols × rows cells (▀: each cell its upper and lower pixel)
  let key = path & "\0" & $cols & "x" & $rows & "\0" & $picTime(path) & "\0" & $bg
  picBlocks.withValue(key, e): return e[]
  let (p, why) = picGet(path, cols, rows * 2)
  if why.len > 0 or p.w == 0: return
  result = imgHalfBlocks(p, cols, rows, uint32(bg))
  if picBlocks.len > 40: picBlocks.clear()
  picBlocks[key] = result

# ── in the Markdown preview ──

proc mdPicRows(path: string, cols: int): int =
  ## how many rows a picture takes at most cols wide (its own width when it is narrower; 30 rows at most)
  let (iw, ih) = picSize(path)
  if iw <= 0 or ih <= 0: return 0
  let c = min(cols, max(8, iw))
  clamp(int(ih.float * c.float / iw.float / 2.0 + 0.5), 1, 30)

proc mdPicRow(path: string, cols, rows, k: int): seq[(Rgb, Rgb)] =
  ## row `k` of a picture in the Markdown preview, as (upper pixel, lower pixel) colours for each cell: the picture is
  ## made at most `cols` wide and `rows` tall, keeping its shape
  let (iw, ih) = picSize(path)
  if iw <= 0: return
  var c = min(cols, max(8, iw))
  # (the rows were worked out for this width: the picture's own shape kept, at most 30 rows)
  let (fw, _) = imgFit(iw, ih, c, rows * 2, upscale = true)
  c = max(1, fw)
  let cells = picCells(path, c, rows, theme.bg)
  if k < cells.len:
    for (a, b) in cells[k]: result.add (Rgb(a), Rgb(b))

# ── the picture view ──

proc picProtocol(): string =
  ## how the terminal draws pictures: pictures.draw, or (auto) what it is — kitty's protocol, iTerm2's, sixel —
  ## else in cells (and always in cells inside tmux, which would not pass them on)
  let s = sStr("pictures.draw")
  if s in ["kitty", "iterm", "sixel", "cells"]: return s
  if getEnv("TMUX").len > 0: return "cells"
  let t = getEnv("TERM")
  let p = getEnv("TERM_PROGRAM")
  if getEnv("KITTY_WINDOW_ID").len > 0 or t in ["xterm-kitty", "xterm-ghostty"] or p == "ghostty": return "kitty"
  if p in ["iTerm.app", "WezTerm"]: return "iterm"
  if tcSixel: return "sixel"
  "cells"

proc picOpen(b: Buffer) =
  ## a picture file just opened (its bytes in the hex editor): shown as a picture
  picViews[b.id] = PicView(zoom: 1.0)
  let (w, h) = picSize(b.path)
  info(extractFilename(b.path) & (if w > 0: " · " & $w & "×" & $h else: "") &
       " — + and − zoom, 0 fits, arrows move, Tab: its bytes (hex)")

proc drawPicture(b: Buffer, x0, y0, w, h: int) =
  ## draws the picture view in a rectangle: a top line with the name, format, size and zoom, then the picture fitted to
  ## the room, zoomed and panned, in cells of two pixels each (▀). When the terminal draws pictures itself and the
  ## picture is unzoomed and unpanned, a request for the terminal to draw it sharper over the cells is made as well.
  var pv = picViews.getOrDefault(b.id, PicView(zoom: 1.0))
  cursorX = -1
  cursorY = -1
  let (iw, ih) = picSize(b.path)
  # the line at the top: what it is
  let hb = blend(theme.bg, theme.fg, 0.06)
  fillRect(x0, y0, w, 1, theme.fg, hb)
  var hx = putStr(x0 + 1, y0, "▣ " & extractFilename(b.path), theme.fg, hb, {aBold}, x0 + w)
  var fmtName = splitFile(b.path).ext.toUpperAscii.strip(chars = {'.'})
  if fmtName == "JPG": fmtName = "JPEG"
  hx = putStr(hx, y0, "  " & fmtName & (if iw > 0: " · " & $iw & "×" & $ih else: "") & " · " &
              formatSize(try: getFileSize(b.path) except CatchableError: 0) &
              (if pv.zoom != 1.0: " · " & $int(pv.zoom * 100) & "% of the view" else: ""), theme.dim, hb, {}, x0 + w)
  let hint = "Tab: bytes · + − 0 · arrows"
  if hx + strWidth(hint) + 3 < x0 + w: discard putStr(x0 + w - strWidth(hint) - 1, y0, hint, theme.dim, hb)
  let ah = h - 1
  if ah < 2 or w < 4: return
  if iw <= 0:
    discard putStr(x0 + 2, y0 + 2, "Not a picture ned can read — Tab shows its bytes", theme.dim, theme.bg)
    return
  # its size in cells (two pixel rows a cell), fitted, then zoomed
  let (fw, fh) = imgFit(iw, ih, w, ah * 2, upscale = true)
  let zw = max(1, int(fw.float * pv.zoom))
  let zh = max(1, int(fh.float * pv.zoom))
  let rowsAll = (zh + 1) div 2
  pv.panX = clamp(pv.panX, 0, max(0, zw - w))
  pv.panY = clamp(pv.panY, 0, max(0, rowsAll - ah))
  picViews[b.id] = pv
  let cells = picCells(b.path, zw, rowsAll, theme.bg)
  if cells.len == 0:
    let (_, why) = picGet(b.path, zw, zh)
    discard putStr(x0 + 2, y0 + 2, (if why.len > 0: why else: "Could not read the picture"), theme.err, theme.bg,
                   {}, x0 + w)
    return
  let shownW = min(w, zw - pv.panX)
  let shownH = min(ah, rowsAll - pv.panY)
  let ox = x0 + max(0, (w - shownW) div 2)
  let oy = y0 + 1 + max(0, (ah - shownH) div 2)
  for r in 0 ..< shownH:
    let row = cells[pv.panY + r]
    for c in 0 ..< shownW:
      let (top, bot) = row[pv.panX + c]
      setCell(ox + c, oy + r, Cell(ch: 0x2580, fg: Rgb(top), bg: Rgb(bot)))
  # sharper: the terminal draws it, over the cells (the whole picture fitted, not zoomed)
  let proto = picProtocol()
  if proto != "cells" and pv.zoom == 1.0 and pv.panX == 0 and pv.panY == 0:
    let key = proto & ":" & b.path & ":" & $picTime(b.path) & ":" & $ox & "," & $oy & ":" & $shownW & "x" & $shownH
    if gfxShown.key == key: gfxNow = gfxShown
    else:
      var payload, del = ""
      case proto
      of "kitty":
        let data = try: readFile(b.path) except CatchableError: ""
        if splitFile(b.path).ext.toLowerAscii == ".png" and data.len < 8_000_000:
          payload = imgKitty(ImgPicture(), picKittyId, shownW, shownH, data)
        else:
          let (p, _) = picGet(b.path, min(iw, 1600), min(ih, 1600))
          if p.w > 0: payload = imgKitty(p, picKittyId, shownW, shownH)
        del = imgKittyDelete(picKittyId)
      of "iterm":
        let data = try: readFile(b.path) except CatchableError: ""
        if data.len < 8_000_000: payload = imgIterm(data, shownW, shownH)
      of "sixel":
        # (a sixel picture is drawn at its size in pixels: about 10 × 20 a cell)
        let (p, _) = picGet(b.path, shownW * 10, shownH * 20)
        if p.w > 0:
          let (sw, sh) = imgFit(p.w, p.h, shownW * 10, shownH * 20)
          payload = imgSixel(imgScale(p, sw, sh), uint32(theme.bg))
      else: discard
      if payload.len > 0:
        gfxNow = GfxReq(key: key, x: ox, y: oy, w: shownW, h: shownH, payload: payload, del: del,
                        again: proto == "sixel")

proc picKey(b: Buffer, k: Key): bool =
  ## the picture view's keys: + − zoom, 0 fit, arrows move (zoomed), Tab: the bytes; true when it took the key
  if b.id notin picViews: return false
  var pv = picViews[b.id]
  # (Tab: its bytes; there Tab goes between the hex and the text columns, as in any hex view, and Shift+Tab back to
  # the picture)
  if k.kind == kTab and ((not pv.hex and k.mods == {}) or (pv.hex and k.mods == {mShift})):
    pv.hex = not pv.hex
    picViews[b.id] = pv
    needRender = true
    info(if pv.hex: "Its bytes — Tab: the hex or the text column · Shift+Tab: the picture again"
         else: "The picture — Tab: its bytes")
    return true
  if pv.hex: return false
  case k.kind
  of kChar:
    if k.mods != {} and k.mods != {mShift}: return false
    case char(k.ch and 0x7F)
    of '+', '=': pv.zoom = min(16.0, pv.zoom * 1.5)
    of '-', '_': pv.zoom = max(0.1, pv.zoom / 1.5)
    of '0':
      pv.zoom = 1.0
      pv.panX = 0
      pv.panY = 0
    of 'h': pv.panX -= 4
    of 'l': pv.panX += 4
    of 'k': pv.panY -= 2
    of 'j': pv.panY += 2
    else: return false
  of kLeft: pv.panX -= 4
  of kRight: pv.panX += 4
  of kUp: pv.panY -= 2
  of kDown: pv.panY += 2
  of kPgUp: pv.panY -= 10
  of kPgDn: pv.panY += 10
  of kHome:
    pv.panX = 0
    pv.panY = 0
  else: return false
  pv.panX = max(0, pv.panX)
  pv.panY = max(0, pv.panY)
  picViews[b.id] = pv
  needRender = true
  true

proc cmdPictureToggle() =
  ## palette command: for a picture file, switches between the picture and its bytes in the hex editor (a picture file
  ## open as bytes gets its picture view)
  let b = buf()
  if b.id notin picViews:
    if b.path.len > 0 and isPicturePath(b.path) and b.hex != nil:
      picViews[b.id] = PicView(zoom: 1.0)
      needRender = true
    else: info("Not a picture (.png, .jpg, .gif, .bmp, .webp)")
    return
  picViews[b.id].hex = not picViews[b.id].hex
  needRender = true
