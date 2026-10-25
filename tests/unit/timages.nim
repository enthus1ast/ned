## The pictures ned shows: PNG, JPEG, GIF and BMP decoded and compared with what PIL makes of the files in
## tests/unit/images (made by images/make.py, listed in its manifest.txt); damaged and cut-short files; the size
## limits; how long a phone-sized photo takes; and what goes to the terminal: half blocks, sixel, kitty, iTerm2.
## Run: nim r -d:release --hints:off tests/unit/timages.nim

import std/[base64, math, monotimes, os, random, strutils, times, unittest]
import ../../src/ned/core/images

const dir = currentSourcePath().parentDir / "images"

type Fixture = object
  file, exp, kind: string
  w, h, frames: int

proc fixtures(): seq[Fixture] =
  for line in lines(dir / "manifest.txt"):
    if line.len == 0 or line.startsWith("#"): continue
    let f = line.splitWhitespace()
    result.add Fixture(file: f[0], exp: f[1], w: parseInt(f[2]), h: parseInt(f[3]), frames: parseInt(f[4]),
                       kind: f[5])

proc expected(f: Fixture): seq[uint8] =
  let s = readFile(dir / f.exp)
  result = newSeq[uint8](s.len)
  for i, c in s: result[i] = uint8(ord(c))

proc ms(d: Duration): float = d.inNanoseconds.float / 1e6
proc whole(x: float): string = $int(x + 0.5)

proc bytes(px: seq[uint8]): string =
  result = newString(px.len)
  for i, b in px: result[i] = char(b)

proc sameVisible(a, b: seq[uint8]): bool =
  ## equal pixel by pixel, the colour of fully transparent ones aside
  if a.len != b.len: return false
  for i in countup(0, a.len - 4, 4):
    if a[i + 3] == 0 and b[i + 3] == 0: continue
    for k in 0..3:
      if a[i + k] != b[i + k]: return false
  true

proc diff(a, b: seq[uint8]): (float, int) =
  ## the mean absolute difference a channel (of R, G, B) and the largest
  var total, most = 0
  for i in countup(0, a.len - 4, 4):
    for k in 0..2:
      let d = abs(int(a[i + k]) - int(b[i + k]))
      total += d
      most = max(most, d)
  (total.float / (a.len div 4 * 3).float, most)

proc boxReduce(px: seq[uint8], w, h, s: int): seq[uint8] =
  ## a picture made s times smaller by averaging (the edge cells over what they have)
  let ow = (w + s - 1) div s
  let oh = (h + s - 1) div s
  result = newSeq[uint8](ow * oh * 4)
  for y in 0 ..< oh:
    for x in 0 ..< ow:
      var sum: array[4, int]
      var n = 0
      for yy in y * s ..< min(h, y * s + s):
        for xx in x * s ..< min(w, x * s + s):
          for k in 0..3: sum[k] += int(px[(yy * w + xx) * 4 + k])
          inc n
      for k in 0..3: result[(y * ow + x) * 4 + k] = uint8((sum[k] + n div 2) div n)

proc picture(w, h: int, f: proc (x, y: int): (int, int, int, int)): ImgPicture =
  result = ImgPicture(w: w, h: h, px: newSeq[uint8](w * h * 4), frames: 1, scaled: 1, fullW: w, fullH: h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let (r, g, b, a) = f(x, y)
      let o = (y * w + x) * 4
      result.px[o] = uint8(r)
      result.px[o + 1] = uint8(g)
      result.px[o + 2] = uint8(b)
      result.px[o + 3] = uint8(a)

proc photoLike(w, h: int): ImgPicture =
  var r = initRand(7)
  picture(w, h, proc (x, y: int): (int, int, int, int) =
    let n = r.rand(16) - 8
    (clamp(128 + int(100 * sin(x / 37)) + n, 0, 255), clamp(y * 255 div h + n, 0, 255),
     clamp(200 - x * 150 div w + int(40 * cos(y / 23)) + n, 0, 255), 255))

# ── a small sixel reader, to see that what imgSixel writes draws the picture ──

proc readSixel(s: string): (int, int, seq[uint32]) =
  ## the size the raster attributes give and each pixel's colour (0xRRGGBB; 0xFF000000 where nothing was drawn)
  doAssert s.startsWith("\eP") and s.endsWith("\e\\")
  var i = s.find('q') + 1
  var w, h, x, y, cur = 0
  var pal: seq[uint32] = newSeq[uint32](256)
  var px: seq[uint32]
  proc num(i: var int): int =
    while i < s.len and s[i] in Digits:
      result = result * 10 + ord(s[i]) - ord('0')
      inc i
  proc draw(px: var seq[uint32], w, h, x, y: int, bits: int, c: uint32) =
    for k in 0..5:
      if (bits and (1 shl k)) != 0 and x < w and y + k < h: px[(y + k) * w + x] = c
  while i < s.len - 2:
    let c = s[i]
    if c == '"':
      inc i
      discard num(i)
      inc i
      discard num(i)
      inc i
      w = num(i)
      inc i
      h = num(i)
      px = newSeq[uint32](w * h)
      for p in px.mitems: p = 0xFF000000'u32
    elif c == '#':
      inc i
      cur = num(i)
      if i < s.len and s[i] == ';':
        inc i
        discard num(i)
        var rgb: array[3, int]
        for k in 0..2:
          inc i
          rgb[k] = num(i)
        pal[cur] = uint32((rgb[0] * 255 + 50) div 100) shl 16 or uint32((rgb[1] * 255 + 50) div 100) shl 8 or
                   uint32((rgb[2] * 255 + 50) div 100)
    elif c == '!':
      inc i
      let n = num(i)
      let ch = s[i]
      inc i
      for k in 0 ..< n:
        draw(px, w, h, x, y, ord(ch) - 63, pal[cur])
        inc x
    elif c == '$':
      x = 0
      inc i
    elif c == '-':
      x = 0
      y += 6
      inc i
    elif c in '?'..'~':
      draw(px, w, h, x, y, ord(c) - 63, pal[cur])
      inc x
      inc i
    else: inc i
  (w, h, px)

suite "decoding the fixtures":
  let all = fixtures()

  test "lossless pictures (PNG, GIF, BMP) come out exactly as written":
    var n = 0
    for f in all:
      if f.kind != "exact": continue
      let (p, err) = imgDecodeFile(dir / f.file)
      if err.len > 0: echo "  ", f.file, ": ", err
      check err == ""
      check p.w == f.w and p.h == f.h
      check p.frames == f.frames
      check p.scaled == 1 and p.fullW == f.w and p.fullH == f.h
      if not sameVisible(p.px, expected(f)):
        echo "  ", f.file, " differs"
        check false
      inc n
    echo "  ", n, " lossless files"

  test "JPEG pictures come out as libjpeg (PIL) decodes them":
    var worstMean = 0.0
    var worstMax = 0
    for f in all:
      if f.kind != "jpeg": continue
      let (p, err) = imgDecodeFile(dir / f.file)
      check err == ""
      check p.w == f.w and p.h == f.h and p.scaled == 1 and p.format == "JPEG"
      if p.px.len != f.w * f.h * 4: continue
      let (mean, most) = diff(p.px, expected(f))
      echo "  ", f.file.alignLeft(20), " mean ", mean.formatFloat(ffDecimal, 3), "  max ", most
      check mean < 3.0
      check most < 40
      worstMean = max(worstMean, mean)
      worstMax = max(worstMax, most)
    echo "  worst: mean ", worstMean.formatFloat(ffDecimal, 3), ", max ", worstMax

  test "JPEG at 1/2, 1/4, 1/8: as PIL's draft mode, and close to the full picture averaged down":
    for f in all:
      if not f.kind.startsWith("jpeg/"): continue
      let s = parseInt(f.kind[5 .. ^1])
      let data = readFile(dir / f.file)
      let (full, _) = imgDecode(data)
      # shown at 1/s of its size or smaller: decoded at 1/s
      let (p, err) = imgDecode(data, full.w div s, full.h div s)
      check err == ""
      check p.scaled == s and p.w == f.w and p.h == f.h and p.fullW == full.w and p.fullH == full.h
      if p.px.len != f.w * f.h * 4: continue
      let (mean, most) = diff(p.px, expected(f))
      let (bmean, bmost) = diff(p.px, boxReduce(full.px, full.w, full.h, s))
      echo "  ", f.file.alignLeft(16), " 1/", s, ": PIL's draft mean ", mean.formatFloat(ffDecimal, 3), " max ", most,
           " · averaged down mean ", bmean.formatFloat(ffDecimal, 3), " max ", bmost
      check mean < 3.0
      check most < 40
      check bmean < 6.0
    # not quite 2× larger: decoded at full size
    let (p, _) = imgDecode(readFile(dir / "jpg_64.jpg"), 33, 20)
    check p.scaled == 1 and p.w == 64
    let (q, _) = imgDecode(readFile(dir / "jpg_64.jpg"), 32, 0)
    check q.scaled == 2 and q.w == 32

  test "EXIF orientation: the picture the right way up, fullW and fullH as shown":
    for o in 1..8:
      let (p, err) = imgDecodeFile(dir / ("jpg_exif" & $o & ".jpg"))
      check err == ""
      check (p.w, p.h) == (if o >= 5: (13, 21) else: (21, 13))
      check (p.fullW, p.fullH) == (p.w, p.h)

  test "imgSize from the header alone":
    for f in all:
      if f.kind.startsWith("jpeg/"): continue
      let data = readFile(dir / f.file)
      check imgSize(data) == (f.w, f.h)
      # only what comes before the picture data
      var head = data
      case imgSniff(data)
      of "png": head = data[0 ..< 33]
      of "bmp": head = data[0 ..< 54]
      of "jpeg": head = data[0 ..< data.find("\xFF\xDA")]
      else: discard
      check imgSize(head) == (f.w, f.h)
    check imgSize("") == (0, 0)
    check imgSize("not a picture at all") == (0, 0)

  test "what the first bytes say":
    check imgSniff(readFile(dir / "png_rgb8.png")) == "png"
    check imgSniff(readFile(dir / "jpg_420.jpg")) == "jpeg"
    check imgSniff(readFile(dir / "gif_basic.gif")) == "gif"
    check imgSniff(readFile(dir / "bmp_24.bmp")) == "bmp"
    check imgSniff("RIFF\x10\0\0\0WEBPVP8L") == "webp"
    check imgSniff("") == ""
    check imgSniff("BM") == ""
    check imgSniff("hello") == ""

  test "WebP, arithmetic coding, files that are no pictures: a sentence why":
    # a lossless WebP header, 300 × 200
    var webp = "RIFF\x20\0\0\0WEBPVP8L\x10\0\0\0\x2F"
    let bits = 299 or (199 shl 14)
    for k in 0..3: webp.add char((bits shr (8 * k)) and 255)
    webp.add "\0\0\0\0\0\0\0"
    check imgDecode(webp)[1] == "WebP pictures are not supported"
    check imgSize(webp) == (300, 200)
    var arith = readFile(dir / "jpg_444.jpg")
    let sof = arith.find("\xFF\xC0")
    arith[sof + 1] = '\xC9'
    check imgDecode(arith)[1] == "Arithmetic-coded JPEG pictures are not supported"
    check imgDecode("plain text")[1] == "Not a picture ned can read (PNG, JPEG, GIF or BMP)"
    check imgDecode("")[1].len > 0
    check imgDecodeFile(dir / "no-such-file.png")[1].startsWith("The file cannot be read")
    check imgDecodeFile(dir / "jpg_444.jpg", maxBytes = 100)[1].startsWith("The file is too large")

suite "damaged files":
  test "cut short and with bytes changed: an error or a picture, quickly, never an exception":
    var r = initRand(20261025)
    var runs, pictures, errors = 0
    var slowest = 0.0
    var slowestName = ""
    let start = getMonoTime()
    var seen: seq[string]
    for f in fixtures():
      if f.file in seen: continue
      seen.add f.file
      let data = readFile(dir / f.file)
      var variants: seq[string]
      for n in 0 ..< min(64, data.len): variants.add data[0 ..< n]
      for k in 1..40: variants.add data[0 ..< data.len * k div 41]
      for k in 0 ..< 60:
        var d = data
        for t in 0 .. r.rand(3): d[r.rand(d.high)] = char(r.rand(255))
        variants.add d
      for k, v in variants:
        let t0 = getMonoTime()
        try:
          # every other one as if shown small, so the reduced-size JPEG paths are damaged too
          let (p, err) = imgDecode(v, (if (k and 1) == 0: 0 else: 4), (if (k and 1) == 0: 0 else: 3))
          if err.len > 0:
            inc errors
            check p.px.len == 0
            # the words for what nothing in the decoders expected: an index or a conversion out of range, which
            # with the checks off (-d:danger) would have been a crash
            if err.startsWith("The picture cannot be read"):
              echo "  ", f.file, " variant ", k, ": ", err
              check false
          else:
            inc pictures
            check p.w > 0 and p.h > 0 and p.px.len == p.w * p.h * 4
        except CatchableError, Defect:
          echo "  ", f.file, " variant ", k, " raised ", getCurrentExceptionMsg()
          check false
        let t = ms(getMonoTime() - t0)
        if t > slowest:
          slowest = t
          slowestName = f.file & " variant " & $k
        inc runs
    echo "  ", runs, " variants: ", pictures, " pictures, ", errors, " errors, in ",
         ms(getMonoTime() - start).whole, " ms; the slowest ",
         slowest.formatFloat(ffDecimal, 1), " ms (", slowestName, ")"
    check slowest < 1000

  test "a header claiming 100000 × 100000 is refused before anything is allocated":
    proc chunk(kind, body: string): string =
      for k in [24, 16, 8, 0]: result.add char((body.len shr k) and 255)
      result.add kind & body & "\0\0\0\0"
    proc be32(v: int): string =
      for k in [24, 16, 8, 0]: result.add char((v shr k) and 255)
    let png = "\x89PNG\r\n\x1a\n" & chunk("IHDR", be32(100000) & be32(100000) & "\x08\x06\0\0\0") &
              chunk("IDAT", "\x78\x9c\x03\0\0\0\0\x01") & chunk("IEND", "")
    let mem0 = getOccupiedMem()
    let t0 = getMonoTime()
    let (p, err) = imgDecode(png)
    check err == "The picture is too large: 100000 × 100000 pixels (ned shows up to 16384 in either direction " &
                 "and 64 megapixels)"
    check p.px.len == 0
    check imgSize(png) == (100000, 100000)
    # at the limit but with far too little data: refused too, before the 256 MB are taken
    let big = "\x89PNG\r\n\x1a\n" & chunk("IHDR", be32(16384) & be32(4096) & "\x08\x06\0\0\0") &
              chunk("IDAT", "\x78\x9c\x03\0\0\0\0\x01") & chunk("IEND", "")
    check imgDecode(big)[1] == "The PNG file is cut short"
    # JPEG, GIF and BMP headers
    var jpg = readFile(dir / "jpg_444.jpg")
    let sof = jpg.find("\xFF\xC0")
    jpg[sof + 5] = '\xEA'                    # 60000 high
    jpg[sof + 6] = '\x60'
    check imgDecode(jpg)[1].startsWith("The picture is too large: 37 × 60000")
    jpg[sof + 5] = '\x3E'                    # 16000 × 16000: within the sides, but 256 megapixels at full size …
    jpg[sof + 6] = '\x80'
    jpg[sof + 7] = '\x3E'
    jpg[sof + 8] = '\x80'
    check imgDecode(jpg)[1].startsWith("The picture is too large: 16000 × 16000")
    let (small, serr) = imgDecode(jpg, 2000, 2000)  # … and fine at 1/8 (the data runs out: grey after it)
    check serr == "" and small.scaled == 8 and small.w == 2000
    var gif = readFile(dir / "gif_basic.gif")
    for k in 6..9: gif[k] = '\xFF'
    check imgDecode(gif)[1].startsWith("The picture is too large: 65535 × 65535")
    var bmp = readFile(dir / "bmp_24.bmp")
    for k, c in [0xA0, 0x86, 0x01, 0x00]: bmp[18 + k] = char(c)
    for k, c in [0xA0, 0x86, 0x01, 0x00]: bmp[22 + k] = char(c)
    check imgDecode(bmp)[1].startsWith("The picture is too large: 100000 × 100000")
    check ms(getMonoTime() - t0) < 2000
    check getOccupiedMem() - mem0 < 64 * 1024 * 1024

suite "speed":
  test "a 4000 × 3000 JPEG shown at 200 × 150 decodes in well under half a second":
    # a phone-sized photo made of the MCUs of a small picture that has a restart marker after each, so any of
    # them can go anywhere: 250 × 188 MCUs of 16 × 16, 4:2:0
    let src = readFile(dir / "jpg_rst.jpg")
    var head = ""
    var pos = 2
    var scanHead = ""
    var data = ""
    while pos + 4 <= src.len:
      let m = ord(src[pos + 1])
      let ln = ord(src[pos + 2]) * 256 + ord(src[pos + 3])
      let seg = src[pos ..< pos + 2 + ln]
      if m == 0xC0:
        var s = seg
        s[5] = char(3000 shr 8)
        s[6] = char(3000 and 255)
        s[7] = char(4000 shr 8)
        s[8] = char(4000 and 255)
        head.add s
      elif m == 0xDD: discard
      elif m == 0xDA:
        scanHead = seg
        data = src[pos + 2 + ln ..< src.rfind("\xFF\xD9")]
        break
      else: head.add seg
      pos += 2 + ln
    var mcus: seq[string]
    var last = 0
    for i in 0 ..< data.len - 1:
      if data[i] == '\xFF' and ord(data[i + 1]) in 0xD0..0xD7:
        mcus.add data[last ..< i]
        last = i + 2
    mcus.add data[last .. ^1]
    check mcus.len == 6
    var big = "\xFF\xD8" & head & "\xFF\xDD\x00\x04\x00\x01" & scanHead
    let total = 250 * 188
    for i in 0 ..< total:
      if i > 0: big.add "\xFF" & char(0xD0 + (i - 1) mod 8)
      big.add mcus[(i * 7 + i div 250) mod mcus.len]
    big.add "\xFF\xD9"
    proc timed(data: string, w, h: int): (float, ImgPicture) =
      var best = 1e9
      var p: ImgPicture
      for k in 0..2:
        let t0 = getMonoTime()
        p = imgDecode(data, w, h)[0]
        best = min(best, ms(getMonoTime() - t0))
      (best, p)
    let (t8, p8) = timed(big, 200, 150)
    check p8.scaled == 8 and p8.w == 500 and p8.h == 375
    let (t2, p2) = timed(big, 2000, 1500)
    check p2.scaled == 2
    let (t1, p1) = timed(big, 0, 0)
    check p1.scaled == 1 and p1.w == 4000
    echo "  made of MCUs (", big.len div 1024, " KB): 1/8 ", t8.whole, " ms, 1/2 ",
         t2.whole, " ms, full ", t1.whole, " ms"
    check t8 < 500
    # a photo-like one from make.py --big, when it is there (it is not committed: 2 MB)
    if fileExists(dir / "big.jpg"):
      let photo = readFile(dir / "big.jpg")
      let (b8, q8) = timed(photo, 200, 150)
      check q8.scaled == 8
      let (b1, _) = timed(photo, 0, 0)
      echo "  big.jpg (", photo.len div 1024, " KB): 1/8 ", b8.whole, " ms, full ",
           b1.whole, " ms"
      check b8 < 500
    # the rest of the way to the screen
    let t0 = getMonoTime()
    let cells = imgHalfBlocks(p8, 100, 40, 0x202020)
    check cells.len == 40 and cells[0].len == 100
    let t1a = getMonoTime()
    let big1600 = photoLike(1600, 1200)
    let t1b = getMonoTime()
    let pic = imgScale(big1600, 1000, 800)
    let t2b = getMonoTime()
    let six = imgSixel(pic, 0)
    let t3b = getMonoTime()
    let kit = imgKitty(pic, 1, 100, 40)
    let t4b = getMonoTime()
    echo "  half blocks 100 × 40 from 500 × 375: ", ms(t1a - t0).formatFloat(ffDecimal, 1),
         " ms; imgScale 1600 × 1200 to 1000 × 800: ", ms(t2b - t1b).whole, " ms; imgSixel 1000 × 800: ",
         ms(t3b - t2b).whole, " ms, ", six.len div 1024, " KB; imgKitty RGBA: ",
         ms(t4b - t3b).whole, " ms, ", kit.len div 1024, " KB"

suite "sizes and colours":
  test "imgFit":
    check imgFit(100, 50, 40, 40) == (40, 20)
    check imgFit(50, 100, 40, 40) == (20, 40)
    check imgFit(10, 10, 40, 30) == (10, 10)
    check imgFit(10, 10, 40, 30, upscale = true) == (30, 30)
    check imgFit(1, 1000, 10, 10) == (1, 10)
    check imgFit(3, 2, 100, 100, upscale = true) == (100, 67)
    check imgFit(0, 10, 10, 10) == (0, 0)
    check imgFit(10, 10, 0, 10) == (0, 0)

  test "imgScale: areas averaged down, nearest up, transparent edges not darkened":
    let p = picture(4, 2, proc (x, y: int): (int, int, int, int) = (x * 60, y * 200, 7, 255))
    let s = imgScale(p, 2, 1)
    check s.w == 2 and s.h == 1
    check s.px == @[30'u8, 100, 7, 255, 150, 100, 7, 255]
    let u = imgScale(imgScale(p, 2, 1), 4, 2)
    check u.px[0 .. 3] == @[30'u8, 100, 7, 255] and u.px[4 .. 7] == @[30'u8, 100, 7, 255]
    check u.px[8 .. 11] == @[150'u8, 100, 7, 255]
    check u.px[16 .. 19] == @[30'u8, 100, 7, 255]
    # opaque white next to transparent black: white at half opacity, not grey
    let t = picture(2, 1, proc (x, y: int): (int, int, int, int) = (if x == 0: (255, 255, 255, 255) else: (0, 0, 0, 0)))
    check imgScale(t, 1, 1).px == @[255'u8, 255, 255, 128]
    # 3 to 2: each new pixel 1.5 old ones
    let q = picture(3, 1, proc (x, y: int): (int, int, int, int) = ([0, 90, 180][x], 0, 0, 255))
    check imgScale(q, 2, 1).px == @[30'u8, 0, 0, 255, 150, 0, 0, 255]
    check imgScale(p, 4, 2).px == p.px
    check imgScale(p, 0, 3).px.len == 0

  test "imgOver":
    let p = picture(2, 1, proc (x, y: int): (int, int, int, int) = (if x == 0: (255, 0, 0, 128) else: (1, 2, 3, 255)))
    let o = imgOver(p, 0x0000FF)
    check o.px == @[128'u8, 0, 127, 255, 1, 2, 3, 255]
    check imgOver(picture(1, 1, proc (x, y: int): (int, int, int, int) = (9, 9, 9, 0)), 0x102030).px ==
          @[0x10'u8, 0x20, 0x30, 255]

  test "imgHalfBlocks: upper and lower halves, the picture in the middle":
    let p = picture(2, 4, proc (x, y: int): (int, int, int, int) = (x * 100, y * 50, 0, 255))
    let c = imgHalfBlocks(p, 2, 2, 0)
    check c.len == 2 and c[0].len == 2
    check c[0][0] == (0x000000'u32, 0x003200'u32)
    check c[0][1] == (0x640000'u32, 0x643200'u32)
    check c[1][0] == (0x006400'u32, 0x009600'u32)
    # one pixel in 3 × 1 cells: fitted to 2 × 2 pixels, in the middle, bg at the side
    let one = picture(1, 1, proc (x, y: int): (int, int, int, int) = (255, 255, 255, 255))
    let d = imgHalfBlocks(one, 3, 1, 0x112233)
    check d[0][0] == (0xFFFFFF'u32, 0xFFFFFF'u32) and d[0][1] == (0xFFFFFF'u32, 0xFFFFFF'u32)
    check d[0][2] == (0x112233'u32, 0x112233'u32)
    # a wide picture in square cells: bg above and below
    let wide = picture(4, 1, proc (x, y: int): (int, int, int, int) = (0, 0, 255, 255))
    let e = imgHalfBlocks(wide, 4, 2, 0x010101)
    check e[0][0] == (0x010101'u32, 0x0000FF'u32) and e[1][0] == (0x010101'u32, 0x010101'u32)
    check imgHalfBlocks(p, 0, 5, 0).len == 0

suite "what goes to the terminal":
  test "sixel: a 2 × 6 picture's exact sequence":
    let p = picture(2, 6, proc (x, y: int): (int, int, int, int) = (if x == 0: (255, 0, 0, 255) else: (0, 0, 255, 255)))
    check imgSixel(p, 0) == "\eP0;1;0q\"1;1;2;6#0;2;100;0;0#1;2;0;0;100#0~$#1?~\e\\"

  test "sixel: a picture of few colours reads back as it was":
    let (p, _) = imgDecodeFile(dir / "png_p8_trns.png")
    let o = imgOver(p, 0x336699)
    let s = imgSixel(p, 0x336699)
    check s.startsWith("\eP") and s.endsWith("\e\\") and s.contains("\"1;1;37;23")
    let (w, h, px) = readSixel(s)
    check w == 37 and h == 23
    var worst = 0
    for i in 0 ..< w * h:
      check px[i] != 0xFF000000'u32
      for k in 0..2: worst = max(worst, abs(int((px[i] shr (16 - 8 * k)) and 255) - int(o.px[4 * i + k])))
    check worst <= 2
    # six rows a band: 23 rows are 4 bands, so three '-' between them
    check s.count('-') == 3

  test "sixel: a photo, more than 256 colours, reads back close":
    let (p, _) = imgDecodeFile(dir / "jpg_64.jpg")
    let s = imgSixel(p, 0)
    let (w, h, px) = readSixel(s)
    check w == 64 and h == 48
    var colours = 0
    var i = 0
    while true:
      i = s.find(";2;", i)
      if i < 0: break
      inc colours
      inc i
    check colours <= 256 and colours > 64
    var total = 0
    for k in 0 ..< w * h:
      for c in 0..2: total += abs(int((px[k] shr (16 - 8 * c)) and 255) - int(p.px[4 * k + c]))
    let mean = total / (w * h * 3)
    echo "  ", colours, " colours, mean difference ", mean.formatFloat(ffDecimal, 2)
    check mean < 6.0

  test "kitty: chunks of at most 4096, m=1 then m=0, the keys in the first":
    let p = photoLike(100, 100)
    let s = imgKitty(p, 7, 20, 10)
    let parts = s.split("\e\\")
    check parts[^1] == ""
    var payload = ""
    for k, part in parts[0 ..< ^1]:
      check part.startsWith("\e_G")
      let semi = part.find(';')
      let keys = part[3 ..< semi]
      let body = part[semi + 1 .. ^1]
      check body.len <= 4096
      payload.add body
      if k == 0:
        for key in ["a=T", "f=32", "s=100", "v=100", "i=7", "c=20", "r=10", "q=2", "C=1"]:
          check key in keys.split(',')
      check (if k < parts.len - 2: "m=1" else: "m=0") in keys.split(',')
    check parts.len - 1 == (encode(bytes(p.px)).len + 4095) div 4096
    check decode(payload) == bytes(p.px)
    # the PNG's own bytes: f=100
    let png = readFile(dir / "png_1x1.png")
    let t = imgKitty(p, 3, 5, 5, png)
    check t.startsWith("\e_Ga=T,f=100,i=3,c=5,r=5,C=1,q=2,m=0;")
    check decode(t["\e_Ga=T,f=100,i=3,c=5,r=5,C=1,q=2,m=0;".len ..< t.len - 2]) == png
    check imgKittyDelete(7) == "\e_Ga=d,d=I,i=7,q=2\e\\"

  test "iTerm2 inline image":
    let data = readFile(dir / "gif_basic.gif")
    let s = imgIterm(data, 20, 10)
    let start = "\e]1337;File=inline=1;width=20;height=10;preserveAspectRatio=1:"
    check s.startsWith(start) and s.endsWith("\a")
    check decode(s[start.len ..< s.len - 1]) == data
