## Pictures read from their bytes — PNG, JPEG, GIF and BMP, with nothing outside Nim's standard library — and turned
## into what a terminal can show: half blocks (▀ in two colours a cell), sixel, the kitty graphics protocol and
## iTerm2's inline images. A file is untrusted: every read is checked, every loop ends on a damaged or cut-short file,
## sizes are limited, and what goes wrong comes back as a sentence, never as an exception.
## A module of its own: tests/unit/timages.nim.

import std/[base64, bitops, math, os, tables]

type
  ImgPicture* = object
    w*, h*: int
    px*: seq[uint8]        # RGBA, 4 bytes a pixel, row by row from the top
    format*: string        # "PNG", "JPEG", "GIF", "BMP"
    frames*: int           # GIF: how many frames the file has (the first is decoded); else 1
    scaled*: int           # JPEG: 1, 2, 4 or 8 — decoded at 1/scaled of its size (w, h are the size decoded)
    fullW*, fullH*: int    # the size the file says, before any reduced-scale decoding (turned as it is shown)
  ImgError = object of CatchableError

const
  ImgMaxSide* = 16384                ## the most pixels a picture may have across or down
  ImgMaxPixels* = 64 * 1024 * 1024   ## the most pixels a decoded picture may have (64 megapixels)

proc imgFail(msg: string) {.noreturn, noinline.} =
  raise newException(ImgError, msg)

proc imgCheckSize(w, h: int, what: string, most = ImgMaxPixels) =
  ## refused before anything is allocated: a header can claim any size
  if w <= 0 or h <= 0: imgFail("The " & what & " file gives no size")
  if w > ImgMaxSide or h > ImgMaxSide or w * h > most:
    imgFail("The picture is too large: " & $w & " × " & $h & " pixels (ned shows up to 16384 in either direction " &
            "and 64 megapixels)")

# ── reading numbers: 0 past the end, so a short file reads as zeros and is caught by the checks after ──

func imgU8(d: string, i: int): int {.inline.} = (if i >= 0 and i < d.len: ord(d[i]) else: 0)
func imgBe16(d: string, i: int): int = imgU8(d, i) shl 8 or imgU8(d, i + 1)
func imgBe32(d: string, i: int): int = imgBe16(d, i) shl 16 or imgBe16(d, i + 2)
func imgLe16(d: string, i: int): int = imgU8(d, i) or imgU8(d, i + 1) shl 8
func imgLe32(d: string, i: int): int = imgLe16(d, i) or imgLe16(d, i + 2) shl 16
func imgLe32s(d: string, i: int): int =
  let v = imgLe32(d, i)
  if v >= 0x8000_0000: v - 0x1_0000_0000 else: v
func imgHas(d: string, i: int, s: string): bool =
  if i < 0 or i + s.len > d.len: return false
  for k in 0 ..< s.len:
    if d[i + k] != s[k]: return false
  true
func imgCeilDiv(a, b: int): int {.inline.} = (a + b - 1) div b
func imgClampU8(v: int): uint8 {.inline.} = uint8(if v < 0: 0 elif v > 255: 255 else: v)
func imgClamp16(v: int): int16 {.inline.} = int16(if v < -32768: -32768 elif v > 32767: 32767 else: v)
func imgRgba(r, g, b, a: int): uint32 {.inline.} =
  ## a pixel packed with red in the low byte, as it lies in ImgPicture.px
  uint32(r and 255) or uint32(g and 255) shl 8 or uint32(b and 255) shl 16 or uint32(a and 255) shl 24

template imgPut(px: var seq[uint8], o: int, c: uint32) =
  px[o] = uint8(c and 255)
  px[o + 1] = uint8((c shr 8) and 255)
  px[o + 2] = uint8((c shr 16) and 255)
  px[o + 3] = uint8(c shr 24)

# ── what kind of file, and its size from the header ──

proc imgSniff*(data: string): string =
  ## what kind of picture the bytes are, from the first few: "png", "jpeg", "gif", "bmp", "webp", or "" for none of them
  if imgHas(data, 0, "\x89PNG\r\n\x1a\n"): "png"
  elif data.len >= 3 and data[0] == '\xFF' and data[1] == '\xD8' and data[2] == '\xFF': "jpeg"
  elif imgHas(data, 0, "GIF87a") or imgHas(data, 0, "GIF89a"): "gif"
  elif imgHas(data, 0, "BM") and data.len >= 18 and imgLe32(data, 14) in [12, 16, 40, 52, 56, 64, 108, 124]: "bmp"
  elif imgHas(data, 0, "RIFF") and imgHas(data, 8, "WEBP"): "webp"
  else: ""

proc imgExifOrientation(d: string, a, b: int): int =
  ## the EXIF orientation (1–8) in the APP1 segment d[a ..< b]; 1 when it has none
  result = 1
  if b - a < 14 or not imgHas(d, a, "Exif\0\0"): return
  let t = a + 6
  let le = imgHas(d, t, "II")
  if not le and not imgHas(d, t, "MM"): return
  template u16(i: int): int = (if le: imgLe16(d, i) else: imgBe16(d, i))
  template u32(i: int): int = (if le: imgLe32(d, i) else: imgBe32(d, i))
  if u16(t + 2) != 42: return
  let ifd = t + u32(t + 4)
  if ifd + 2 > b: return
  for k in 0 ..< u16(ifd):
    let e = ifd + 2 + k * 12
    if e + 12 > b: break
    if u16(e) == 0x0112:
      let v = u16(e + 8)
      if u16(e + 2) == 3 and v in 1..8: return v
      return

proc imgJpegHead(d: string): (int, int, int) =
  ## the size and the EXIF orientation, from the segments before the picture data
  var pos = 2
  var orient = 1
  while pos + 4 <= d.len:
    if d[pos] != '\xFF':
      inc pos
      continue
    let m = imgU8(d, pos + 1)
    if m == 0xFF:
      inc pos
      continue
    if m in [0x00, 0x01, 0xD8] or m in 0xD0..0xD7:
      pos += 2
      continue
    if m in [0xD9, 0xDA]: break
    let ln = imgBe16(d, pos + 2)
    if ln < 2: break
    if m in 0xC0..0xCF and m notin [0xC4, 0xC8, 0xCC]:
      return (imgBe16(d, pos + 7), imgBe16(d, pos + 5), orient)
    if m == 0xE1 and orient == 1: orient = imgExifOrientation(d, pos + 4, min(d.len, pos + 2 + ln))
    pos += 2 + ln
  (0, 0, orient)

proc imgGifFirst(d: string): (int, int, int, int) =
  ## where the first frame is on the canvas and its size; zeros when there is none
  if d.len < 13: return
  var p = 13
  let flags = imgU8(d, 10)
  if (flags and 0x80) != 0: p += 3 * (2 shl (flags and 7))
  while p < d.len:
    let b = ord(d[p])
    inc p
    if b == 0x21:
      inc p
      while p < d.len:
        let n = ord(d[p])
        p += n + 1
        if n == 0: break
    elif b == 0x2C:
      return (imgLe16(d, p), imgLe16(d, p + 2), imgLe16(d, p + 4), imgLe16(d, p + 6))
    else: return

proc imgSize*(data: string): (int, int) =
  ## the picture's size from its header alone, without decoding it; (0, 0) if it is not known. A JPEG's EXIF
  ## orientation is applied (a phone photo taken upright gives its upright size), a GIF's canvas grows to its first
  ## frame as imgDecode does; WebP sizes are read too
  try:
    case imgSniff(data)
    of "png":
      if imgHas(data, 12, "IHDR"): return (imgBe32(data, 16), imgBe32(data, 20))
    of "jpeg":
      let (w, h, o) = imgJpegHead(data)
      return (if o >= 5: (h, w) else: (w, h))
    of "gif":
      let (fx, fy, fw, fh) = imgGifFirst(data)
      return (max(imgLe16(data, 6), fx + fw), max(imgLe16(data, 8), fy + fh))
    of "bmp":
      if imgLe32(data, 14) == 12: return (imgLe16(data, 18), imgLe16(data, 20))
      if imgLe32s(data, 18) > 0: return (imgLe32s(data, 18), abs(imgLe32s(data, 22)))
    of "webp":
      if imgHas(data, 12, "VP8 ") and imgHas(data, 23, "\x9D\x01\x2A"):
        return (imgLe16(data, 26) and 0x3FFF, imgLe16(data, 28) and 0x3FFF)
      if imgHas(data, 12, "VP8L") and imgU8(data, 20) == 0x2F:
        let b = imgLe32(data, 21)
        return ((b and 0x3FFF) + 1, ((b shr 14) and 0x3FFF) + 1)
      if imgHas(data, 12, "VP8X"):
        return ((imgLe32(data, 24) and 0xFFFFFF) + 1, (imgLe32(data, 27) and 0xFFFFFF) + 1)
    else: discard
  except Exception: discard
  (0, 0)

# ── zlib (RFC 1950, 1951) for PNG. The Adler-32 sum at the end is not checked: reading stops as soon as the picture
#    has all its bytes, and a damaged stream almost always breaks a Huffman code or a filter byte first ──

type
  ImgZTree = object
    fast: array[1024, uint16]     # by the next 10 bits: (code length shl 9) or symbol; 0: a longer code
    counts: array[16, int]
    syms: array[320, int]         # by code, the shortest first
  ImgZ = object
    src: string
    pos: int
    buf: uint64                   # the next bits, the first in the lowest
    cnt: int
    over: int                     # zero bytes put in after the end

const
  ImgLenBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163,
                195, 227, 258]
  ImgLenExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
  ImgDistBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049,
                 3073, 4097, 6145, 8193, 12289, 16385, 24577]
  ImgDistExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
  ImgClOrder = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

proc imgZFill(z: var ImgZ) {.inline.} =
  while z.cnt <= 56:
    var b = 0'u64
    if z.pos < z.src.len:
      b = uint64(ord(z.src[z.pos]))
      inc z.pos
    else: inc z.over
    z.buf = z.buf or (b shl z.cnt)
    z.cnt += 8
  # more of the zeros used than were put in after the end: the stream asks for bytes it does not have
  if z.over * 8 > z.cnt: imgFail("The PNG file is cut short")

proc imgZBits(z: var ImgZ, n: int): int {.inline.} =
  if n == 0: return 0
  if z.cnt < n: imgZFill(z)
  result = int(z.buf and ((1'u64 shl n) - 1))
  z.buf = z.buf shr n
  z.cnt -= n

proc imgZBuild(t: var ImgZTree, lens: openArray[int]) =
  ## a canonical Huffman code from the code lengths (RFC 1951 3.2.2)
  for i in 0 ..< t.fast.len: t.fast[i] = 0
  for i in 0 ..< t.counts.len: t.counts[i] = 0
  for l in lens: inc t.counts[l]
  t.counts[0] = 0
  var left = 1
  for l in 1..15:
    left = (left shl 1) - t.counts[l]
    if left < 0: imgFail("The PNG file is damaged")
  var offs: array[16, int]
  for l in 1..14: offs[l + 1] = offs[l] + t.counts[l]
  for s, l in lens:
    if l != 0:
      t.syms[offs[l]] = s
      inc offs[l]
  var code = 0
  var k = 0
  for l in 1..15:
    for i in 0 ..< t.counts[l]:
      if l <= 10:
        var rev = 0             # the stream sends codes from their top bit: reversed for a lookup by its low bits
        for b in 0 ..< l:
          if (code and (1 shl b)) != 0: rev = rev or (1 shl (l - 1 - b))
        let e = uint16((l shl 9) or t.syms[k])
        var j = rev
        while j < 1024:
          t.fast[j] = e
          j += 1 shl l
      inc code
      inc k
    code = code shl 1

proc imgZDecode(z: var ImgZ, t: ImgZTree): int {.inline.} =
  if z.cnt < 15: imgZFill(z)
  let e = t.fast[int(z.buf and 1023)]
  if e != 0:
    let l = int(e shr 9)
    z.buf = z.buf shr l
    z.cnt -= l
    return int(e and 511)
  var code, first, index = 0
  for l in 1..15:
    code = code or int(z.buf and 1)
    z.buf = z.buf shr 1
    dec z.cnt
    let c = t.counts[l]
    if code - first < c: return t.syms[index + code - first]
    index += c
    first = (first + c) shl 1
    code = code shl 1
  imgFail("The PNG file is damaged")

proc imgInflate(src: sink string, dst: var seq[uint8], want: int) =
  ## zlib data into dst[0 ..< want]; what comes after is not read
  if src.len < 2: imgFail("The PNG file is cut short")
  let cmf = ord(src[0])
  let flg = ord(src[1])
  if (cmf and 15) != 8 or (cmf shr 4) > 7 or (cmf * 256 + flg) mod 31 != 0 or (flg and 32) != 0:
    imgFail("The PNG file is damaged: its picture data is not zlib")
  var z = ImgZ(src: src, pos: 2)
  var lit, dist, cl: ImgZTree
  var fixedLit, fixedDist: ImgZTree
  var haveFixed = false
  # a block's code tables take a few microseconds to make: a stream of millions of tiny blocks could take minutes,
  # so there may be one for each 512 bytes of the picture (encoders make one for each 16 KB or more, or a row)
  var tables = want div 512 + 256
  var op = 0
  var final = false
  while not final and op < want:
    final = imgZBits(z, 1) == 1
    let kind = imgZBits(z, 2)
    if kind == 0:
      discard imgZBits(z, z.cnt and 7)
      let n = imgZBits(z, 16)
      if n != (imgZBits(z, 16) xor 0xFFFF): imgFail("The PNG file is damaged")
      for i in 0 ..< n:
        let b = imgZBits(z, 8)
        if op < want:
          dst[op] = uint8(b)
          inc op
      continue
    if kind == 1:
      if not haveFixed:
        var lens: array[288, int]
        for i in 0..143: lens[i] = 8
        for i in 144..255: lens[i] = 9
        for i in 256..279: lens[i] = 7
        for i in 280..287: lens[i] = 8
        imgZBuild(fixedLit, lens)
        var dl: array[30, int]
        for i in 0..29: dl[i] = 5
        imgZBuild(fixedDist, dl)
        haveFixed = true
    elif kind == 2:
      dec tables
      if tables < 0: imgFail("The PNG file is damaged")
      let hlit = imgZBits(z, 5) + 257
      let hdist = imgZBits(z, 5) + 1
      let hclen = imgZBits(z, 4) + 4
      var cll: array[19, int]
      for i in 0 ..< hclen: cll[ImgClOrder[i]] = imgZBits(z, 3)
      imgZBuild(cl, cll)
      var lens: array[320, int]
      var n = 0
      while n < hlit + hdist:
        let s = imgZDecode(z, cl)
        if s < 16:
          lens[n] = s
          inc n
        else:
          var rep, val = 0
          if s == 16:
            if n == 0: imgFail("The PNG file is damaged")
            val = lens[n - 1]
            rep = 3 + imgZBits(z, 2)
          elif s == 17: rep = 3 + imgZBits(z, 3)
          else: rep = 11 + imgZBits(z, 7)
          if n + rep > hlit + hdist: imgFail("The PNG file is damaged")
          for i in 0 ..< rep:
            lens[n] = val
            inc n
      imgZBuild(lit, lens.toOpenArray(0, hlit - 1))
      imgZBuild(dist, lens.toOpenArray(hlit, hlit + hdist - 1))
    else: imgFail("The PNG file is damaged")
    let lt = if kind == 1: addr fixedLit else: addr lit
    let dt = if kind == 1: addr fixedDist else: addr dist
    while op < want:
      let s = imgZDecode(z, lt[])
      if s < 256:
        dst[op] = uint8(s)
        inc op
      elif s == 256: break
      else:
        let li = s - 257
        if li >= 29: imgFail("The PNG file is damaged")
        let ln = ImgLenBase[li] + imgZBits(z, ImgLenExtra[li])
        let ds = imgZDecode(z, dt[])
        if ds >= 30: imgFail("The PNG file is damaged")
        let d = ImgDistBase[ds] + imgZBits(z, ImgDistExtra[ds])
        if d > op: imgFail("The PNG file is damaged")
        let n = min(ln, want - op)
        if d >= n: copyMem(addr dst[op], addr dst[op - d], n)
        else:
          # the last d bytes over and over: copied in pieces that double, each from bytes already there
          var k = 0
          while k < n:
            let m = min(n - k, d + k)
            copyMem(addr dst[op + k], addr dst[op - d], m)
            k += m
        op += n
  if op < want: imgFail("The PNG file is cut short")

# ── PNG ──

type
  ImgPngInfo = object
    depth, ctype: int
    pal: array[256, uint32]
    tGrey, tR, tG, tB: int      # the colour tRNS makes transparent (-1: none)

proc imgPngPx(b: seq[uint8], r, x: int, ip: ImgPngInfo): uint32 {.inline.} =
  ## pixel x of the unfiltered row that starts at r
  let d = ip.depth
  template small(): int =
    let bit = x * d
    (int(b[r + (bit shr 3)]) shr (8 - d - (bit and 7))) and ((1 shl d) - 1)
  case ip.ctype
  of 0:
    var v, g: int
    if d == 16:
      v = int(b[r + 2 * x]) shl 8 or int(b[r + 2 * x + 1])
      g = v shr 8
    elif d == 8:
      v = int(b[r + x])
      g = v
    else:
      v = small()
      g = v * (255 div ((1 shl d) - 1))
    imgRgba(g, g, g, if v == ip.tGrey: 0 else: 255)
  of 2:
    if d == 16:
      let o = r + 6 * x
      let rr = int(b[o]) shl 8 or int(b[o + 1])
      let gg = int(b[o + 2]) shl 8 or int(b[o + 3])
      let bb = int(b[o + 4]) shl 8 or int(b[o + 5])
      imgRgba(rr shr 8, gg shr 8, bb shr 8, if rr == ip.tR and gg == ip.tG and bb == ip.tB: 0 else: 255)
    else:
      let o = r + 3 * x
      let rr = int(b[o])
      let gg = int(b[o + 1])
      let bb = int(b[o + 2])
      imgRgba(rr, gg, bb, if rr == ip.tR and gg == ip.tG and bb == ip.tB: 0 else: 255)
  of 3:
    ip.pal[if d == 8: int(b[r + x]) else: small()]
  of 4:
    if d == 16: imgRgba(int(b[r + 4 * x]), int(b[r + 4 * x]), int(b[r + 4 * x]), int(b[r + 4 * x + 2]))
    else: imgRgba(int(b[r + 2 * x]), int(b[r + 2 * x]), int(b[r + 2 * x]), int(b[r + 2 * x + 1]))
  else:
    if d == 16:
      let o = r + 8 * x
      imgRgba(int(b[o]), int(b[o + 2]), int(b[o + 4]), int(b[o + 6]))
    else:
      let o = r + 4 * x
      imgRgba(int(b[o]), int(b[o + 1]), int(b[o + 2]), int(b[o + 3]))

proc imgPngUnfilter(b: var seq[uint8], start, rows, stride, bpp: int) =
  ## the five PNG filters undone in place; each row is a filter byte and `stride` bytes
  if rows <= 0 or stride <= 0: return
  if start < 0 or start + rows * (stride + 1) > b.len: imgFail("The PNG file is damaged")
  # each row through a pointer, its bounds the check above: a check a byte would take half the time
  var prev: ptr UncheckedArray[uint8] = nil     # the row above (nil: the first row, whose row above is zeros)
  for y in 0 ..< rows:
    let f = start + y * (stride + 1)
    let ft = b[f]
    let cur = cast[ptr UncheckedArray[uint8]](addr b[f + 1])
    case ft
    of 0: discard
    of 1:
      for i in bpp ..< stride: cur[i] = cur[i] + cur[i - bpp]
    of 2:
      if prev != nil:
        for i in 0 ..< stride: cur[i] = cur[i] + prev[i]
    of 3:
      if prev == nil:
        for i in bpp ..< stride: cur[i] = cur[i] + (cur[i - bpp] shr 1)
      else:
        for i in 0 ..< bpp: cur[i] = cur[i] + (prev[i] shr 1)
        for i in bpp ..< stride: cur[i] = cur[i] + uint8((int(cur[i - bpp]) + int(prev[i])) shr 1)
    of 4:
      if prev == nil:
        for i in bpp ..< stride: cur[i] = cur[i] + cur[i - bpp]
      else:
        for i in 0 ..< bpp: cur[i] = cur[i] + prev[i]
        for i in bpp ..< stride:
          let a = int(cur[i - bpp])
          let u = int(prev[i])
          let c = int(prev[i - bpp])
          let pa = abs(u - c)
          let pb = abs(a - c)
          let pc = abs(a + u - 2 * c)
          cur[i] = cur[i] + uint8(if pa <= pb and pa <= pc: a elif pb <= pc: u else: c)
    else: imgFail("The PNG file is damaged")
    prev = cur

proc imgPng(d: string): ImgPicture =
  var w, h, interlace = 0
  var ip = ImgPngInfo(tGrey: -1, tR: -1, tG: -1, tB: -1)
  for i in 0..255: ip.pal[i] = imgRgba(0, 0, 0, 255)
  var seen = false
  var idat = ""
  var pos = 8
  while pos + 8 <= d.len:
    let ln = imgBe32(d, pos)
    let body = pos + 8
    let n = min(ln, d.len - body)   # a cut-short chunk: what there is of it
    if imgHas(d, pos + 4, "IHDR"):
      if n < 13: imgFail("The PNG file is damaged")
      w = imgBe32(d, body)
      h = imgBe32(d, body + 4)
      ip.depth = imgU8(d, body + 8)
      ip.ctype = imgU8(d, body + 9)
      interlace = imgU8(d, body + 12)
      let ok = case ip.ctype
        of 0: ip.depth in [1, 2, 4, 8, 16]
        of 3: ip.depth in [1, 2, 4, 8]
        of 2, 4, 6: ip.depth in [8, 16]
        else: false
      if not ok or imgU8(d, body + 10) != 0 or imgU8(d, body + 11) != 0 or interlace > 1:
        imgFail("The PNG file is damaged: no such kind of pixels")
      imgCheckSize(w, h, "PNG")
      seen = true
    elif not seen: imgFail("The PNG file is damaged: it does not start with its header")
    elif imgHas(d, pos + 4, "PLTE"):
      for i in 0 ..< min(256, n div 3):
        ip.pal[i] = imgRgba(imgU8(d, body + 3 * i), imgU8(d, body + 3 * i + 1), imgU8(d, body + 3 * i + 2), 255)
    elif imgHas(d, pos + 4, "tRNS"):
      case ip.ctype
      of 3:
        for i in 0 ..< min(256, n):
          ip.pal[i] = (ip.pal[i] and 0xFFFFFF'u32) or (uint32(imgU8(d, body + i)) shl 24)
      of 0:
        if n >= 2: ip.tGrey = imgBe16(d, body)
      of 2:
        if n >= 6:
          ip.tR = imgBe16(d, body)
          ip.tG = imgBe16(d, body + 2)
          ip.tB = imgBe16(d, body + 4)
      else: discard
    elif imgHas(d, pos + 4, "IDAT"):
      if n > 0: idat.add d[body ..< body + n]
    elif imgHas(d, pos + 4, "IEND"): break
    if ln > d.len - body: break
    pos = body + ln + 4
  if not seen: imgFail("The PNG file is cut short")
  if idat.len == 0: imgFail("The PNG file has no picture data")
  let channels = [1, 0, 3, 1, 2, 0, 4][ip.ctype]
  let bits = channels * ip.depth
  let bpp = max(1, bits div 8)
  const pass = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
  var rawLen = 0
  if interlace == 0: rawLen = h * ((w * bits + 7) div 8 + 1)
  else:
    for (x0, y0, dx, dy) in pass:
      let pw = (w - x0 + dx - 1) div dx
      let ph = (h - y0 + dy - 1) div dy
      if pw > 0 and ph > 0: rawLen += ph * ((pw * bits + 7) div 8 + 1)
  # deflate makes at most 1032 bytes of a byte: a file too small for its size is refused before the allocation
  if idat.len.float * 1032.0 + 1024.0 < rawLen.float: imgFail("The PNG file is cut short")
  let outLen = w * h * 4
  result = ImgPicture(w: w, h: h, format: "PNG", frames: 1, scaled: 1, fullW: w, fullH: h)
  if interlace == 0:
    # the pixels are made in the buffer the data was inflated into: from the first row forward when a pixel takes
    # 4 bytes or more (each is written no later than it is read), else from the last backward
    var buf = newSeqUninit[uint8](max(rawLen, outLen))
    imgInflate(move idat, buf, rawLen)
    let stride = (w * bits + 7) div 8
    imgPngUnfilter(buf, 0, h, stride, bpp)
    let p = cast[ptr UncheckedArray[uint8]](addr buf[0])  # (the rows and pixels below stay inside buf by its size)
    if ip.ctype == 6 and ip.depth == 8:
      # RGBA: the rows only move up, by their filter bytes
      for y in 0 ..< h: moveMem(addr p[y * w * 4], addr p[y * (stride + 1) + 1], w * 4)
    elif ip.ctype in [0, 2, 3] and ip.depth == 8:
      # grey, RGB and palette, the common kinds, without a decision a pixel
      for y in countdown(h - 1, 0):
        let r = y * (stride + 1) + 1
        let o = y * w * 4
        for x in countdown(w - 1, 0):
          var c: uint32
          if ip.ctype == 3: c = ip.pal[p[r + x]]
          elif ip.ctype == 2:
            let rr = int(p[r + 3 * x])
            let gg = int(p[r + 3 * x + 1])
            let bb = int(p[r + 3 * x + 2])
            c = imgRgba(rr, gg, bb, if rr == ip.tR and gg == ip.tG and bb == ip.tB: 0 else: 255)
          else:
            let g = int(p[r + x])
            c = imgRgba(g, g, g, if g == ip.tGrey: 0 else: 255)
          p[o + 4 * x] = uint8(c and 255)
          p[o + 4 * x + 1] = uint8((c shr 8) and 255)
          p[o + 4 * x + 2] = uint8((c shr 16) and 255)
          p[o + 4 * x + 3] = uint8(c shr 24)
    elif bits >= 32:
      for y in 0 ..< h:
        let r = y * (stride + 1) + 1
        let o = y * w * 4
        for x in 0 ..< w:
          let c = imgPngPx(buf, r, x, ip)
          imgPut(buf, o + 4 * x, c)
    else:
      for y in countdown(h - 1, 0):
        let r = y * (stride + 1) + 1
        let o = y * w * 4
        for x in countdown(w - 1, 0):
          let c = imgPngPx(buf, r, x, ip)
          imgPut(buf, o + 4 * x, c)
    buf.setLen(outLen)
    result.px = move buf
  else:
    var raw = newSeqUninit[uint8](rawLen)
    imgInflate(move idat, raw, rawLen)
    result.px = newSeq[uint8](outLen)
    var off = 0
    for (x0, y0, dx, dy) in pass:
      let pw = (w - x0 + dx - 1) div dx
      let ph = (h - y0 + dy - 1) div dy
      if pw <= 0 or ph <= 0: continue
      let stride = (pw * bits + 7) div 8
      imgPngUnfilter(raw, off, ph, stride, bpp)
      for py in 0 ..< ph:
        let r = off + py * (stride + 1) + 1
        let o = (y0 + py * dy) * w + x0
        for px in 0 ..< pw:
          imgPut(result.px, (o + px * dx) * 4, imgPngPx(raw, r, px, ip))
      off += ph * (stride + 1)

# ── JPEG: baseline and progressive, Huffman-coded. It follows libjpeg (which PIL, browsers and most tools use) where
#    a choice shows: its accurate integer IDCT, its chroma upsampling (a triangle filter) and its colour conversion,
#    so a picture comes out as they show it ──

type
  ImgJHuff = object
    fast: array[512, uint16]      # by the next 9 bits: (code length shl 8) or value; 0: a longer code
    fastAc: array[512, int32]     # AC: by the next 9 bits when they hold a code and its value too: (value shl 8) or
                                  # (run shl 4) or the bits they take; 0: not so
    maxcode: array[18, int]       # the largest code of each length, -1: none
    valptr: array[17, int]        # where the values of each length start, less its first code
    counts: array[17, int]        # how many codes of each length
    vals: array[256, uint8]
    ok: bool                      # defined
    ready: bool                   # its lookups made (when a scan first uses it: a file can define thousands)
  ImgJComp = object
    id, h, v, tq, td, ta: int     # sampling factors, its tables
    bw, bh: int                   # blocks across and down, whole MCUs
    cbw, cbh: int                 # the blocks it needs itself (a scan of it alone goes over these)
    n: int                        # pixels a block decodes to across and down: 8, 4, 2 or 1
    pw, ph: int                   # its plane: bw * n × bh * n
    dw, dh: int                   # of that, the part inside the picture
    plane: seq[uint8]
    cs: int                       # progressive: coefficients kept a block (64, or 1 when only the DC is shown)
    coef: seq[int16]
    pred: int                     # the DC prediction
  ImgJpeg = object
    p: ptr UncheckedArray[uint8]  # the file (read only after checking against n)
    n, pos: int
    buf: uint64                   # the next bits, the first in the top bit
    cnt: int
    pad: int                      # zero bits put in after a marker or the end
    over: bool                    # the data ran out or broke: skip to the next restart marker
    marker: int                   # the marker the bits ran into (0: none, 0x100: the end of the file)
    eobrun: int
    qt: array[4, array[64, int]]  # in natural order
    ht: array[8, ImgJHuff]        # 0–3 DC, 4–7 AC
    comps: seq[ImgJComp]
    w, h, hmax, vmax, mcux, mcuy: int
    progressive, jfif: bool
    ri: int                       # MCUs between restart markers (0: none)
    adobe: int                    # the transform of the Adobe APP14 segment, -1: none
    orient: int
    scale: int
    budget: int                   # blocks still to visit: a damaged file can have endless scans

const ImgZigzag = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20,
                   13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52,
                   45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63]

func imgRedTable(n: int): array[8, array[8, int]] =
  ## the inverse DCT averaged over groups of 8 div n pixels, so that a block gives n × n pixels, each the mean of the
  ## ones the full block has — libjpeg's reduced sizes (jidctred.c) work out the same
  let g = 8 div n
  for x in 0 ..< n:
    for u in 0..7:
      var s = 0.0
      for k in x * g ..< x * g + g:
        s += (if u == 0: sqrt(0.5) else: 1.0) / 2 * cos(float((2 * k + 1) * u) * PI / 16)
      result[x][u] = int(round(s / float(g) * 8192))

func imgRedFreqs(n: int): seq[int] =
  ## the frequencies the averaging keeps: over pairs the 4th averages out, over fours the 2nd, 4th and 6th
  let t = imgRedTable(n)
  for u in 0..7:
    for x in 0 ..< n:
      if t[x][u] != 0:
        result.add u
        break

const
  ImgRed4 = imgRedTable(4)
  ImgRed2 = imgRedTable(2)
  ImgRedF4 = imgRedFreqs(4)
  ImgRedF2 = imgRedFreqs(2)

func imgJExtend(v, n: int): int {.inline.} =
  if n == 0: 0 elif v < (1 shl (n - 1)): v - (1 shl n) + 1 else: v

proc imgJDefine(t: var ImgJHuff, counts: array[17, int], d: string, at: int) =
  ## a Huffman table as DHT gives it: how many codes of each length, then their values at d[at ..]
  var code, k = 0
  for l in 1..16:
    t.valptr[l] = k - code
    k += counts[l]
    code += counts[l]
    if code > (1 shl l): imgFail("The JPEG file is damaged: a Huffman table does not fit")
    t.maxcode[l] = if counts[l] > 0: code - 1 else: -1
    code = code shl 1
  t.counts = counts
  for i in 0 ..< k: t.vals[i] = uint8(imgU8(d, at + i))
  t.ok = true
  t.ready = false

proc imgJLookups(t: var ImgJHuff) =
  ## the lookups by the next 9 bits
  for i in 0 ..< t.fast.len: t.fast[i] = 0
  var code, k = 0
  for l in 1..9:
    for i in 0 ..< t.counts[l]:
      let base = code shl (9 - l)
      for j in 0 ..< (1 shl (9 - l)): t.fast[base + j] = uint16((l shl 8) or int(t.vals[k]))
      inc code
      inc k
    code = code shl 1
  # most AC coefficients are small: their code and value fit in 9 bits, read in one go
  for i in 0..511:
    t.fastAc[i] = 0
    let e = int(t.fast[i])
    if e == 0: continue
    let l = e shr 8
    let r = (e shr 4) and 15
    let sz = e and 15
    if sz != 0 and l + sz <= 9:
      let v = imgJExtend((i shr (9 - l - sz)) and ((1 shl sz) - 1), sz)
      t.fastAc[i] = int32((v shl 8) or (r shl 4) or (l + sz))
  t.ready = true

proc imgJFill(j: var ImgJpeg) =
  while j.cnt <= 56:
    var b = 0
    if j.marker == 0 and j.pos < j.n:
      b = int(j.p[j.pos])
      if b == 0xFF:
        let nx = if j.pos + 1 < j.n: int(j.p[j.pos + 1]) else: 0x100
        if nx == 0: j.pos += 2
        else:
          j.marker = nx           # the end of this data: the bits after are zeros, the marker stays to be read
          b = 0
          j.pad += 8
      else: inc j.pos
    else:
      if j.marker == 0: j.marker = 0x100
      j.pad += 8
    j.buf = j.buf or (uint64(b) shl (56 - j.cnt))
    j.cnt += 8

proc imgJDecode(j: var ImgJpeg, t: int): int {.inline.} =
  ## the next Huffman-coded value; a code the table does not have marks the data as broken
  if j.cnt < 16: imgJFill(j)
  let e = j.ht[t].fast[int(j.buf shr 55)]
  if e != 0:
    let l = int(e shr 8)
    j.buf = j.buf shl l
    j.cnt -= l
    return int(e and 255)
  for l in 10..16:
    let code = int(j.buf shr (64 - l))
    if code <= j.ht[t].maxcode[l]:
      j.buf = j.buf shl l
      j.cnt -= l
      return int(j.ht[t].vals[(code + j.ht[t].valptr[l]) and 255])
  j.over = true
  0

proc imgJBits(j: var ImgJpeg, n: int): int {.inline.} =
  if n <= 0: return 0
  if j.cnt < n: imgJFill(j)
  result = int(j.buf shr (64 - n))
  j.buf = j.buf shl n
  j.cnt -= n

proc imgJReset(j: var ImgJpeg) =
  j.buf = 0
  j.cnt = 0
  j.pad = 0
  j.over = false
  j.marker = 0
  j.eobrun = 0
  for c in j.comps.mitems: c.pred = 0

proc imgJNextMarker(j: ImgJpeg): int =
  ## where the next marker is, past the data of a scan (restart markers belong to the data)
  var p = j.pos
  while p + 1 < j.n:
    if j.p[p] == 0xFF:
      let m = int(j.p[p + 1])
      if m == 0xFF: inc p
      elif m == 0 or m in 0xD0..0xD7: p += 2
      else: return p
    else: inc p
  j.n

proc imgJRestart(j: var ImgJpeg): int =
  ## at a restart marker the bits start again on a byte and the DC predictions from zero; its number (0–7),
  ## or -1 when the next marker is another one (the scan is over)
  var p = j.pos
  while p + 1 < j.n and not (j.p[p] == 0xFF and j.p[p + 1] != 0 and j.p[p + 1] != 0xFF): inc p
  if p + 1 >= j.n:
    j.pos = j.n
    return -1
  let m = int(j.p[p + 1])
  if m notin 0xD0..0xD7:
    j.pos = p
    return -1
  j.pos = p + 2
  imgJReset(j)
  m - 0xD0

# The transforms, the upsampling and the colour conversion go without Nim's checks: they index only within a block of
# 64 and within the planes and rows imgJFrame and imgJOutput sized for them (each index is worked out from those
# sizes, never from the file's bytes), and their sums stay far from overflowing (coefficients of 16 bits times
# tables of 16). With the checks a full-size decode takes about twice as long.
{.push checks: off.}

proc imgIdct8(blk: array[64, int], dst: var seq[uint8], off, stride: int) =
  ## libjpeg's accurate integer IDCT (jidctint.c, the Loeffler–Ligtenberg–Moschytz one), the coefficients dequantized
  const cb = 13                   # bits of the constants
  const p1 = 2                    # bits kept after the first pass
  var ws: array[64, int]
  for col in 0..7:
    template inp(r: int): int = blk[r * 8 + col]
    if inp(1) == 0 and inp(2) == 0 and inp(3) == 0 and inp(4) == 0 and inp(5) == 0 and inp(6) == 0 and inp(7) == 0:
      let dc = inp(0) shl p1
      for r in 0..7: ws[r * 8 + col] = dc
      continue
    var z2 = inp(2)
    var z3 = inp(6)
    var z1 = (z2 + z3) * 4433
    var tmp2 = z1 - z3 * 15137
    var tmp3 = z1 + z2 * 6270
    z2 = inp(0)
    z3 = inp(4)
    var tmp0 = (z2 + z3) shl cb
    var tmp1 = (z2 - z3) shl cb
    let tmp10 = tmp0 + tmp3
    let tmp13 = tmp0 - tmp3
    let tmp11 = tmp1 + tmp2
    let tmp12 = tmp1 - tmp2
    tmp0 = inp(7)
    tmp1 = inp(5)
    tmp2 = inp(3)
    tmp3 = inp(1)
    z1 = tmp0 + tmp3
    z2 = tmp1 + tmp2
    z3 = tmp0 + tmp2
    var z4 = tmp1 + tmp3
    let z5 = (z3 + z4) * 9633
    tmp0 = tmp0 * 2446
    tmp1 = tmp1 * 16819
    tmp2 = tmp2 * 25172
    tmp3 = tmp3 * 12299
    z1 = -z1 * 7373
    z2 = -z2 * 20995
    z3 = -z3 * 16069 + z5
    z4 = -z4 * 3196 + z5
    tmp0 += z1 + z3
    tmp1 += z2 + z4
    tmp2 += z2 + z3
    tmp3 += z1 + z4
    const sh = cb - p1
    const rnd = 1 shl (sh - 1)
    ws[col] = (tmp10 + tmp3 + rnd) shr sh
    ws[56 + col] = (tmp10 - tmp3 + rnd) shr sh
    ws[8 + col] = (tmp11 + tmp2 + rnd) shr sh
    ws[48 + col] = (tmp11 - tmp2 + rnd) shr sh
    ws[16 + col] = (tmp12 + tmp1 + rnd) shr sh
    ws[40 + col] = (tmp12 - tmp1 + rnd) shr sh
    ws[24 + col] = (tmp13 + tmp0 + rnd) shr sh
    ws[32 + col] = (tmp13 - tmp0 + rnd) shr sh
  for row in 0..7:
    let o = row * 8
    let d = off + row * stride
    if ws[o + 1] == 0 and ws[o + 2] == 0 and ws[o + 3] == 0 and ws[o + 4] == 0 and ws[o + 5] == 0 and
       ws[o + 6] == 0 and ws[o + 7] == 0:
      let v = imgClampU8(((ws[o] + (1 shl (p1 + 2))) shr (p1 + 3)) + 128)
      for x in 0..7: dst[d + x] = v
      continue
    var z2 = ws[o + 2]
    var z3 = ws[o + 6]
    var z1 = (z2 + z3) * 4433
    var tmp2 = z1 - z3 * 15137
    var tmp3 = z1 + z2 * 6270
    var tmp0 = (ws[o] + ws[o + 4]) shl cb
    var tmp1 = (ws[o] - ws[o + 4]) shl cb
    let tmp10 = tmp0 + tmp3
    let tmp13 = tmp0 - tmp3
    let tmp11 = tmp1 + tmp2
    let tmp12 = tmp1 - tmp2
    tmp0 = ws[o + 7]
    tmp1 = ws[o + 5]
    tmp2 = ws[o + 3]
    tmp3 = ws[o + 1]
    z1 = tmp0 + tmp3
    z2 = tmp1 + tmp2
    z3 = tmp0 + tmp2
    var z4 = tmp1 + tmp3
    let z5 = (z3 + z4) * 9633
    tmp0 = tmp0 * 2446
    tmp1 = tmp1 * 16819
    tmp2 = tmp2 * 25172
    tmp3 = tmp3 * 12299
    z1 = -z1 * 7373
    z2 = -z2 * 20995
    z3 = -z3 * 16069 + z5
    z4 = -z4 * 3196 + z5
    tmp0 += z1 + z3
    tmp1 += z2 + z4
    tmp2 += z2 + z3
    tmp3 += z1 + z4
    const sh = cb + p1 + 3
    const rnd = 1 shl (sh - 1)
    dst[d] = imgClampU8(((tmp10 + tmp3 + rnd) shr sh) + 128)
    dst[d + 7] = imgClampU8(((tmp10 - tmp3 + rnd) shr sh) + 128)
    dst[d + 1] = imgClampU8(((tmp11 + tmp2 + rnd) shr sh) + 128)
    dst[d + 6] = imgClampU8(((tmp11 - tmp2 + rnd) shr sh) + 128)
    dst[d + 2] = imgClampU8(((tmp12 + tmp1 + rnd) shr sh) + 128)
    dst[d + 5] = imgClampU8(((tmp12 - tmp1 + rnd) shr sh) + 128)
    dst[d + 3] = imgClampU8(((tmp13 + tmp0 + rnd) shr sh) + 128)
    dst[d + 4] = imgClampU8(((tmp13 - tmp0 + rnd) shr sh) + 128)

proc imgIdctRed(blk: array[64, int], t: array[8, array[8, int]], f: openArray[int], n: int, dst: var seq[uint8],
                off, stride: int) =
  ## a block to n × n pixels (n = 4 or 2) with the averaged tables, over the frequencies f they keep
  var ws: array[32, int]
  for v in f:
    for u in f:
      let c = blk[v * 8 + u]
      if c != 0:
        for y in 0 ..< n: ws[y * 8 + u] += t[y][v] * c
  for y in 0 ..< n:
    for u in f: ws[y * 8 + u] = (ws[y * 8 + u] + 1024) shr 11
  for y in 0 ..< n:
    for x in 0 ..< n:
      var s = 0
      for u in f: s += t[x][u] * ws[y * 8 + u]
      dst[off + y * stride + x] = imgClampU8(((s + 16384) shr 15) + 128)

proc imgJIdct(blk: array[64, int], ac: bool, n: int, dst: var seq[uint8], off, stride: int) =
  if not ac or n == 1:
    # the DC alone: the block's mean, as libjpeg rounds it
    let v = imgClampU8(((blk[0] + 4) shr 3) + 128)
    for y in 0 ..< n:
      for x in 0 ..< n: dst[off + y * stride + x] = v
  elif n == 8: imgIdct8(blk, dst, off, stride)
  elif n == 4: imgIdctRed(blk, ImgRed4, ImgRedF4, 4, dst, off, stride)
  else: imgIdctRed(blk, ImgRed2, ImgRedF2, 2, dst, off, stride)

{.pop.}

proc imgJBlock(j: var ImgJpeg, ci: int, blk: var array[64, int]): bool =
  ## a block of a sequential scan, dequantized in natural order; true when an AC coefficient is not zero. A component
  ## shown at 1/8 needs only its DC: the AC ones are read past
  let c = addr j.comps[ci]
  let tq = c.tq
  zeroMem(addr blk[0], sizeof(blk))
  var s = imgJDecode(j, c.td)
  if s > 15:
    j.over = true
    s = 0
  c.pred = max(-65536, min(65536, c.pred + imgJExtend(imgJBits(j, s), s)))
  blk[0] = c.pred * j.qt[tq][0]
  let dcOnly = c.n == 1
  let ta = 4 + c.ta
  var k = 1
  while k < 64:
    if j.cnt < 16: imgJFill(j)
    let fa = int(j.ht[ta].fastAc[int(j.buf shr 55)])
    if fa != 0:
      let tl = fa and 15
      j.buf = j.buf shl tl
      j.cnt -= tl
      k += (fa shr 4) and 15
      if k > 63:
        j.over = true
        break
      if not dcOnly:
        let z = ImgZigzag[k]
        blk[z] = (fa shr 8) * j.qt[tq][z]
        result = true
      inc k
      continue
    let rs = imgJDecode(j, ta)
    let r = rs shr 4
    let sz = rs and 15
    if sz == 0:
      if r != 15: break
      k += 16
      continue
    k += r
    if k > 63:
      j.over = true
      break
    let v = imgJExtend(imgJBits(j, sz), sz)
    if not dcOnly:
      let z = ImgZigzag[k]
      blk[z] = v * j.qt[tq][z]
      result = true
    inc k

proc imgJAcFirst(j: var ImgJpeg, ci, o, ss, se, al: int) =
  if j.eobrun > 0:
    dec j.eobrun
    return
  if o < 0 or o + 64 > j.comps[ci].coef.len: return
  let cf = cast[ptr UncheckedArray[int16]](addr j.comps[ci].coef[o])   # the block's 64, checked just above
  let t = 4 + j.comps[ci].ta
  var k = ss
  while k <= se:
    if j.cnt < 16: imgJFill(j)
    let fa = int(j.ht[t].fastAc[int(j.buf shr 55)])
    if fa != 0:
      let tl = fa and 15
      j.buf = j.buf shl tl
      j.cnt -= tl
      k += (fa shr 4) and 15
      if k > 63:
        j.over = true
        return
      cf[ImgZigzag[k]] = imgClamp16((fa shr 8) * (1 shl al))
      inc k
      continue
    let rs = imgJDecode(j, t)
    let r = rs shr 4
    let s = rs and 15
    if s == 0:
      if r < 15:
        j.eobrun = (1 shl r) - 1 + imgJBits(j, r)
        break
      k += 16
    else:
      k += r
      if k > 63:
        j.over = true
        return
      cf[ImgZigzag[k]] = imgClamp16(imgJExtend(imgJBits(j, s), s) * (1 shl al))
      inc k

proc imgJAcRefine(j: var ImgJpeg, ci, o, ss, se, al: int) =
  ## a refining AC scan: one more bit of the coefficients already there, and the ones that become non-zero (jdphuff.c)
  let p1 = 1 shl al
  let m1 = -p1
  let t = 4 + j.comps[ci].ta
  if o < 0 or o + 64 > j.comps[ci].coef.len: return
  let coef = cast[ptr UncheckedArray[int16]](addr j.comps[ci].coef[o])   # the block's 64, checked just above
  template refine(z: int) =
    if coef[z] != 0 and imgJBits(j, 1) == 1 and (int(coef[z]) and p1) == 0:
      coef[z] = imgClamp16(int(coef[z]) + (if coef[z] >= 0: p1 else: m1))
  var k = ss
  if j.eobrun == 0:
    while k <= se:
      let rs = imgJDecode(j, t)
      var r = rs shr 4
      var s = rs and 15
      if s != 0:
        s = if imgJBits(j, 1) == 1: p1 else: m1
      elif r != 15:
        j.eobrun = (1 shl r) + imgJBits(j, r)
        break
      while k <= se:
        let z = ImgZigzag[k]
        if coef[z] != 0: refine(z)
        else:
          dec r
          if r < 0: break
        inc k
      if s != 0 and k <= se: coef[ImgZigzag[k]] = int16(s)
      inc k
      if j.over: return
  if j.eobrun > 0:
    while k <= se:
      refine(ImgZigzag[k])
      inc k
    dec j.eobrun

proc imgJUnit(j: var ImgJpeg, ci, bx, by, ss, se, ah, al: int, blk: var array[64, int]) =
  ## one block of a scan, decoded into the plane (sequential) or into the coefficients (progressive)
  let c = addr j.comps[ci]
  if bx >= c.bw or by >= c.bh: return
  if not j.progressive:
    let ac = imgJBlock(j, ci, blk)
    imgJIdct(blk, ac, c.n, c.plane, by * c.n * c.pw + bx * c.n, c.pw)
    return
  let o = (by * c.bw + bx) * c.cs
  if ss == 0:
    if ah == 0:
      var s = imgJDecode(j, c.td)
      if s > 15:
        j.over = true
        s = 0
      c.pred = max(-65536, min(65536, c.pred + imgJExtend(imgJBits(j, s), s)))
      c.coef[o] = imgClamp16(c.pred * (1 shl al))
    elif imgJBits(j, 1) == 1:
      c.coef[o] = imgClamp16(int(c.coef[o]) or (1 shl al))
  elif ah == 0: imgJAcFirst(j, ci, o, ss, se, al)
  else: imgJAcRefine(j, ci, o, ss, se, al)

proc imgJScan(j: var ImgJpeg, sc: seq[int], ss, se, ah, al: int) =
  let single = sc.len == 1
  let mx = if single: j.comps[sc[0]].cbw else: j.mcux
  let my = if single: j.comps[sc[0]].cbh else: j.mcuy
  var per = 1
  if not single:
    per = 0
    for ci in sc: per += j.comps[ci].h * j.comps[ci].v
  j.budget -= mx * my * per
  if j.budget < 0: imgFail("The JPEG file is damaged: it has too many scans")
  # the AC of a component shown at 1/8 changes nothing on the screen: its scans are not even read
  if j.progressive and ss > 0 and j.comps[sc[0]].cs == 1: return
  imgJReset(j)
  var blk: array[64, int]
  var rst = 0
  let total = mx * my
  var m = 0
  while m < total:
    if j.ri > 0 and m > 0 and m mod j.ri == 0:
      let k = imgJRestart(j)
      if k < 0: break
      # a marker other than the one expected: the ones between were lost, and so were their intervals
      m += ((k - rst) and 7) * j.ri
      rst = (k + 1) and 7
      if m >= total: break
    elif j.over:
      if j.ri == 0: break
      m = (m div j.ri + 1) * j.ri
      continue
    let ux = m mod mx
    let uy = m div mx
    if single: imgJUnit(j, sc[0], ux, uy, ss, se, ah, al, blk)
    else:
      for ci in sc:
        let ch = j.comps[ci].h
        let cv = j.comps[ci].v
        for v in 0 ..< cv:
          for h in 0 ..< ch: imgJUnit(j, ci, ux * ch + h, uy * cv + v, ss, se, ah, al, blk)
    # bits used past what the data had: what follows is not this picture's
    if j.cnt < j.pad: j.over = true
    inc m

proc imgJSos(j: var ImgJpeg, d: string, a, b: int): int =
  ## a scan: its header at d[a ..< b], then its data; where the next marker is
  let ns = imgU8(d, a)
  j.pos = b
  if ns < 1 or ns > 4 or b - a < 4 + 2 * ns: return imgJNextMarker(j)
  var sc: seq[int]
  for i in 0 ..< ns:
    let id = imgU8(d, a + 1 + 2 * i)
    let t = imgU8(d, a + 2 + 2 * i)
    var found = -1
    for ci in 0 ..< j.comps.len:
      if j.comps[ci].id == id: found = ci
    if found < 0 or (t shr 4) > 3 or (t and 15) > 3: return imgJNextMarker(j)
    j.comps[found].td = t shr 4
    j.comps[found].ta = t and 15
    sc.add found
  let o = a + 1 + 2 * ns
  let ss = imgU8(d, o)
  let se = imgU8(d, o + 1)
  let ah = imgU8(d, o + 2) shr 4
  let al = imgU8(d, o + 2) and 15
  # a scan that cannot be right is passed over, the others may still make a picture
  var ok = true
  if j.progressive:
    ok = ss <= se and se <= 63 and (ss == 0) == (se == 0) and (ss == 0 or ns == 1) and al <= 13 and ah <= 13
    for ci in sc:
      if ss == 0 and ah == 0 and not j.ht[j.comps[ci].td].ok: ok = false
      if ss > 0 and not j.ht[4 + j.comps[ci].ta].ok: ok = false
  else:
    for ci in sc:
      if not j.ht[j.comps[ci].td].ok or not j.ht[4 + j.comps[ci].ta].ok: ok = false
  if ok:
    for ci in sc:
      for t in [j.comps[ci].td, 4 + j.comps[ci].ta]:
        if j.ht[t].ok and not j.ht[t].ready: imgJLookups(j.ht[t])
    if j.progressive: imgJScan(j, sc, ss, se, ah, al)
    else: imgJScan(j, sc, 0, 63, 0, 0)
  imgJNextMarker(j)

proc imgJFrame(j: var ImgJpeg, d: string, a, b: int, wantW, wantH: int) =
  if b - a < 6: imgFail("The JPEG file is damaged")
  let prec = imgU8(d, a)
  if prec != 8:
    imgFail(if prec in [12, 16]: $prec & "-bit JPEG pictures are not supported" else: "The JPEG file is damaged")
  j.h = imgBe16(d, a + 1)
  j.w = imgBe16(d, a + 3)
  let nc = imgU8(d, a + 5)
  if j.h == 0: imgFail("JPEG pictures that give their height after the picture data are not supported")
  if nc == 2: imgFail("JPEG pictures with two colour components are not supported")
  if nc notin [1, 3, 4]: imgFail("The JPEG file is damaged")
  if b - a < 6 + 3 * nc: imgFail("The JPEG file is damaged")
  imgCheckSize(j.w, j.h, "JPEG", most = high(int))   # (the pixel limit is for the size it is decoded at)
  j.comps = newSeq[ImgJComp](nc)
  j.hmax = 1
  j.vmax = 1
  for i in 0 ..< nc:
    let o = a + 6 + 3 * i
    j.comps[i].id = imgU8(d, o)
    j.comps[i].h = imgU8(d, o + 1) shr 4
    j.comps[i].v = imgU8(d, o + 1) and 15
    j.comps[i].tq = imgU8(d, o + 2)
    if j.comps[i].h notin 1..4 or j.comps[i].v notin 1..4 or j.comps[i].tq > 3:
      imgFail("The JPEG file is damaged")
    j.hmax = max(j.hmax, j.comps[i].h)
    j.vmax = max(j.vmax, j.comps[i].v)
  for i in 0 ..< nc:
    if j.hmax mod j.comps[i].h != 0 or j.vmax mod j.comps[i].v != 0:
      imgFail("JPEG pictures sampled this way are not supported")
  j.mcux = imgCeilDiv(j.w, 8 * j.hmax)
  j.mcuy = imgCeilDiv(j.h, 8 * j.vmax)
  # the scale: a picture at least 2, 4 or 8 times the size it is shown at in both directions is decoded smaller
  let (sw, sh) = if j.orient >= 5: (j.h, j.w) else: (j.w, j.h)
  var s = 1
  if wantW > 0 or wantH > 0:
    s = 8
    while s > 1 and not ((wantW <= 0 or sw >= s * wantW) and (wantH <= 0 or sh >= s * wantH)): s = s div 2
  j.scale = s
  let n = 8 div s
  imgCheckSize(imgCeilDiv(j.w, s), imgCeilDiv(j.h, s), "JPEG")
  # libjpeg's choice (jdmaster.c): a component sampled less than the most decodes at a larger IDCT size when that
  # makes upsampling unneeded, so its colour is as sharp as the picture allows. A progressive picture keeps its
  # coefficients until the end; when they would take too much memory the components all decode at the same size
  for attempt in 0..1:
    var coefBytes = 0
    for c in j.comps.mitems:
      var ss = n
      while attempt == 0 and ss < 8 and (j.hmax * n) mod (c.h * ss * 2) == 0 and (j.vmax * n) mod (c.v * ss * 2) == 0:
        ss *= 2
      c.n = ss
      c.bw = j.mcux * c.h
      c.bh = j.mcuy * c.v
      c.cbw = imgCeilDiv(imgCeilDiv(j.w * c.h, j.hmax), 8)
      c.cbh = imgCeilDiv(imgCeilDiv(j.h * c.v, j.vmax), 8)
      c.pw = c.bw * ss
      c.ph = c.bh * ss
      c.dw = imgCeilDiv(j.w * c.h * ss, j.hmax * 8)
      c.dh = imgCeilDiv(j.h * c.v * ss, j.vmax * 8)
      c.cs = if ss == 1: 1 else: 64
      coefBytes += c.bw * c.bh * c.cs * 2
    if not j.progressive or coefBytes <= 256 * 1024 * 1024: break
    if attempt == 1:
      imgFail("This progressive JPEG is too large to decode: " & $j.w & " × " & $j.h & " pixels")
  var blocks = 0
  for c in j.comps.mitems:
    c.plane = newSeqUninit[uint8](c.pw * c.ph)
    for i in 0 ..< c.plane.len: c.plane[i] = 128        # what a block with no data shows: grey
    if j.progressive: c.coef = newSeq[int16](c.bw * c.bh * c.cs)
    blocks += c.bw * c.bh
  j.budget = blocks * 64 + 65536

proc imgJFinish(j: var ImgJpeg) =
  ## a progressive picture's coefficients, all scans read, into its planes
  var blk: array[64, int]
  for c in j.comps.mitems:
    let q = j.qt[c.tq]
    for by in 0 ..< c.bh:
      for bx in 0 ..< c.bw:
        let o = (by * c.bw + bx) * c.cs
        var ac = false
        blk[0] = int(c.coef[o]) * q[0]
        if c.cs == 64:
          for k in 1..63:
            blk[k] = int(c.coef[o + k]) * q[k]
            if blk[k] != 0: ac = true
        imgJIdct(blk, ac, c.n, c.plane, by * c.n * c.pw + bx * c.n, c.pw)

{.push checks: off.}   # (as the transforms above)

proc imgJUpRow(c: ImgJComp, y, ow, ux, uy: int, fancy: bool, row: var seq[int]) =
  ## row y of the picture from a component's plane. Fancy, as libjpeg does for the common 2:1 cases (jdsample.c):
  ## each new sample 3/4 the nearer one and 1/4 the next (9/16, 3/16, 3/16, 1/16 for 2 × 2); else each one repeated
  template at(r, x: int): int = int(c.plane[r * c.pw + x])
  let dw = c.dw
  if ux == 1 and uy == 1:
    let r = min(y, c.ph - 1)
    for x in 0 ..< ow: row[x] = at(r, min(x, c.pw - 1))
  elif fancy and ux == 2 and uy == 1 and dw > 2:
    let r = min(y, c.ph - 1)
    row[0] = at(r, 0)
    row[1] = (at(r, 0) * 3 + at(r, 1) + 2) shr 2
    for i in 1 ..< dw - 1:
      let v = at(r, i) * 3
      row[2 * i] = (v + at(r, i - 1) + 1) shr 2
      row[2 * i + 1] = (v + at(r, i + 1) + 2) shr 2
    let v = at(r, dw - 1)
    row[2 * dw - 2] = (v * 3 + at(r, dw - 2) + 1) shr 2
    row[2 * dw - 1] = v
  elif fancy and uy == 2 and (ux == 1 or (ux == 2 and dw > 2)):
    # the row above or below, whichever is nearer, the picture's edge rows repeated
    let r0 = min(y shr 1, c.dh - 1)
    let r1 = max(0, min(if (y and 1) == 0: r0 - 1 else: r0 + 1, c.dh - 1))
    if ux == 1:
      let bias = if (y and 1) == 0: 1 else: 2
      for x in 0 ..< min(ow, dw): row[x] = (at(r0, x) * 3 + at(r1, x) + bias) shr 2
    else:
      template cs(i: int): int = at(r0, i) * 3 + at(r1, i)
      var last = cs(0)
      var this = last
      var next = cs(1)
      row[0] = (this * 4 + 8) shr 4
      row[1] = (this * 3 + next + 7) shr 4
      last = this
      this = next
      for i in 1 ..< dw - 1:
        next = cs(i + 1)
        row[2 * i] = (this * 3 + last + 8) shr 4
        row[2 * i + 1] = (this * 3 + next + 7) shr 4
        last = this
        this = next
      row[2 * dw - 2] = (this * 3 + last + 8) shr 4
      row[2 * dw - 1] = (this * 4 + 7) shr 4
  else:
    let r = min(y div uy, c.ph - 1)
    for x in 0 ..< ow: row[x] = at(r, min(x div ux, c.pw - 1))

func imgMulDiv255(a, b: int): int {.inline.} =
  let t = a * b + 128
  (t + (t shr 8)) shr 8

proc imgJColourRow(rows: array[4, seq[int]], model, ow: int, px: var seq[uint8], start, step: int) =
  ## a row of RGBA pixels from the components' rows, the first at px[start], each next `step` on: model 0 grey,
  ## 1 RGB, 2 YCbCr, 3 CMYK, 4 YCCK
  var o = start
  template put(r, g, b: int) =
    px[o] = imgClampU8(r)
    px[o + 1] = imgClampU8(g)
    px[o + 2] = imgClampU8(b)
    px[o + 3] = 255
    o += step
  case model
  of 0:
    for x in 0 ..< ow:
      let v = rows[0][x]
      put(v, v, v)
  of 1:
    for x in 0 ..< ow: put(rows[0][x], rows[1][x], rows[2][x])
  of 2:
    # libjpeg's fixed point (jdcolor.c): 1.402, 0.34414, 0.71414 and 1.772 in 16 bits
    for x in 0 ..< ow:
      let yy = rows[0][x]
      let cb = rows[1][x] - 128
      let cr = rows[2][x] - 128
      put(yy + ((91881 * cr + 32768) shr 16), yy + ((-22554 * cb - 46802 * cr + 32768) shr 16),
          yy + ((116130 * cb + 32768) shr 16))
  else:
    # CMYK as Adobe writes it, inverted (PIL takes every CMYK JPEG so); YCCK is its C, M, Y made Y, Cb, Cr
    for x in 0 ..< ow:
      var ci, mi, yi: int
      if model == 4:
        let yy = rows[0][x]
        let cb = rows[1][x] - 128
        let cr = rows[2][x] - 128
        ci = max(0, min(255, yy + ((91881 * cr + 32768) shr 16)))
        mi = max(0, min(255, yy + ((-22554 * cb - 46802 * cr + 32768) shr 16)))
        yi = max(0, min(255, yy + ((116130 * cb + 32768) shr 16)))
      else:
        ci = 255 - rows[0][x]
        mi = 255 - rows[1][x]
        yi = 255 - rows[2][x]
      let nk = rows[3][x]
      put(nk - imgMulDiv255(ci, nk), nk - imgMulDiv255(mi, nk), nk - imgMulDiv255(yi, nk))

{.pop.}

proc imgJOutput(j: var ImgJpeg): ImgPicture =
  let s = j.scale
  let n = 8 div s
  let ow = imgCeilDiv(j.w, s)
  let oh = imgCeilDiv(j.h, s)
  let nc = j.comps.len
  # the colour space as libjpeg tells it (jdapimin.c): JFIF means YCbCr; else Adobe's transform; else the
  # component ids ('R', 'G', 'B': no conversion). Four components are CMYK or, by Adobe's transform, YCCK
  var model = [0, 0, 2, 2, 3][nc]
  if nc == 3 and not j.jfif:
    if j.adobe >= 0:
      if j.adobe == 0: model = 1
    elif j.comps[0].id == 82 and j.comps[1].id == 71 and j.comps[2].id == 66: model = 1
  if nc == 4 and j.adobe > 0: model = 4
  var ux, uy: array[4, int]
  var rows: array[4, seq[int]]
  for ci in 0 ..< nc:
    ux[ci] = (j.hmax * n) div (j.comps[ci].h * j.comps[ci].n)
    uy[ci] = (j.vmax * n) div (j.comps[ci].v * j.comps[ci].n)
    rows[ci] = newSeq[int](max(ow, 2 * j.comps[ci].dw) + 2)
  # EXIF orientation: each pixel written straight to where it shows, base + x * sx + y * sy
  let (tw, th, base, sx, sy) = case j.orient
    of 2: (ow, oh, 4 * (ow - 1), -4, 4 * ow)
    of 3: (ow, oh, 4 * (ow * oh - 1), -4, -4 * ow)
    of 4: (ow, oh, 4 * ow * (oh - 1), 4, -4 * ow)
    of 5: (oh, ow, 0, 4 * oh, 4)
    of 6: (oh, ow, 4 * (oh - 1), 4 * oh, -4)
    of 7: (oh, ow, 4 * (ow * oh - 1), -4 * oh, -4)
    of 8: (oh, ow, 4 * oh * (ow - 1), -4 * oh, 4)
    else: (ow, oh, 0, 4, 4 * ow)
  result = ImgPicture(w: tw, h: th, format: "JPEG", frames: 1, scaled: s,
                      fullW: (if j.orient >= 5: j.h else: j.w), fullH: (if j.orient >= 5: j.w else: j.h))
  result.px = newSeqUninit[uint8](ow * oh * 4)
  for y in 0 ..< oh:
    for ci in 0 ..< nc: imgJUpRow(j.comps[ci], y, ow, ux[ci], uy[ci], n > 1, rows[ci])
    imgJColourRow(rows, model, ow, result.px, base + y * sy, sx)

proc imgJpeg(d: string, wantW, wantH: int): ImgPicture =
  var j = ImgJpeg(adobe: -1, orient: 1)
  j.p = cast[ptr UncheckedArray[uint8]](unsafeAddr d[0])
  j.n = d.len
  var frame = false
  var scans = 0
  var pos = 2
  while pos < d.len:
    if d[pos] != '\xFF':
      inc pos
      continue
    while pos < d.len and d[pos] == '\xFF': inc pos
    if pos >= d.len: break
    let m = ord(d[pos])
    inc pos
    if m == 0xD9: break
    if m in [0x00, 0x01, 0xD8] or m in 0xD0..0xD7: continue
    let ln = imgBe16(d, pos)
    let seg = pos + 2
    let segEnd = pos + ln
    if ln < 2 or segEnd > d.len: break
    case m
    of 0xC0, 0xC1, 0xC2:
      if not frame:
        j.progressive = m == 0xC2
        imgJFrame(j, d, seg, segEnd, wantW, wantH)
        frame = true
    of 0xC3, 0xC5, 0xC6, 0xC7: imgFail("Lossless and hierarchical JPEG pictures are not supported")
    of 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF: imgFail("Arithmetic-coded JPEG pictures are not supported")
    of 0xC4:
      var p = seg
      while p + 17 <= segEnd:
        let tc = imgU8(d, p) shr 4
        let th = imgU8(d, p) and 15
        var counts: array[17, int]
        var total = 0
        for l in 1..16:
          counts[l] = imgU8(d, p + l)
          total += counts[l]
        if tc > 1 or th > 3 or total > 256 or p + 17 + total > segEnd: imgFail("The JPEG file is damaged")
        imgJDefine(j.ht[tc * 4 + th], counts, d, p + 17)
        p += 17 + total
    of 0xDB:
      var p = seg
      while p < segEnd:
        let pq = imgU8(d, p) shr 4
        let tq = imgU8(d, p) and 15
        if tq > 3 or pq > 1 or p + 1 + 64 * (pq + 1) > segEnd: imgFail("The JPEG file is damaged")
        for k in 0..63:
          j.qt[tq][ImgZigzag[k]] = if pq == 0: imgU8(d, p + 1 + k) else: imgBe16(d, p + 1 + 2 * k)
        p += 1 + 64 * (pq + 1)
    of 0xDD: j.ri = imgBe16(d, seg)
    of 0xDA:
      if not frame: imgFail("The JPEG file is damaged: its picture data comes before its size")
      # progressive files have ten or twenty scans; past a thousand the rest are left out
      if scans >= 1000: break
      pos = imgJSos(j, d, seg, segEnd)
      inc scans
      continue
    of 0xE0:
      if imgHas(d, seg, "JFIF\0"): j.jfif = true
    of 0xE1:
      if j.orient == 1: j.orient = imgExifOrientation(d, seg, segEnd)
    of 0xEE:
      if ln >= 14 and imgHas(d, seg, "Adobe"): j.adobe = imgU8(d, seg + 11)
    else: discard
    pos = segEnd
  if not frame: imgFail("The JPEG file has no picture in it")
  if scans == 0: imgFail("The JPEG file is cut short: it has no picture data")
  if j.progressive: imgJFinish(j)
  imgJOutput(j)

# ── GIF: the first frame on a transparent canvas, and how many frames there are ──

proc imgGifTable(d: string, p, n: int): seq[uint32] =
  for i in 0 ..< n:
    result.add imgRgba(imgU8(d, p + 3 * i), imgU8(d, p + 3 * i + 1), imgU8(d, p + 3 * i + 2), 255)

proc imgGifLzw(src: string, minSize, fx, fy, fw, fh: int, interlaced: bool, tbl: seq[uint32], trans: int,
               px: var seq[uint8], cw: int) =
  ## the frame's LZW data drawn on the canvas; it stops at the frame's last pixel, at the end code or at the first
  ## code that cannot be right
  if minSize < 1 or minSize > 11 or fw <= 0 or fh <= 0: return
  let clear = 1 shl minSize
  let eoi = clear + 1
  var size = minSize + 1
  var avail = clear + 2
  var prefix: array[4096, int16]
  var suffix, first: array[4096, uint8]
  for i in 0 ..< clear:
    suffix[i] = uint8(i and 255)
    first[i] = uint8(i and 255)
  var stack: array[4097, uint8]
  var old = -1
  var bp, cnt = 0
  var buf = 0'u64
  var x, y, pass = 0
  var done = 0
  let total = fw * fh
  var pal: array[256, uint32]
  for i in 0..255: pal[i] = if i < tbl.len: tbl[i] else: imgRgba(0, 0, 0, 255)
  # the canvas holds the whole frame (imgGif made it so): each pixel goes to `o` through a pointer
  if px.len < ((fy + fh - 1) * cw + fx + fw) * 4: return
  let dst = cast[ptr UncheckedArray[uint8]](addr px[0])
  var o = (fy * cw + fx) * 4
  const istart = [0, 4, 2, 1]
  const istep = [8, 8, 4, 2]
  while done < total:
    while cnt < size:
      if bp >= src.len: return
      buf = buf or (uint64(ord(src[bp])) shl cnt)
      inc bp
      cnt += 8
    let code = int(buf and ((1'u64 shl size) - 1))
    buf = buf shr size
    cnt -= size
    if code == clear:
      size = minSize + 1
      avail = clear + 2
      old = -1
      continue
    if code == eoi: return
    var sp = 0
    if old < 0:
      if code >= clear: return
      stack[0] = uint8(code and 255)
      sp = 1
    else:
      if code > avail: return
      var c = code
      if code == avail:
        stack[0] = first[old]
        sp = 1
        c = old
      while c >= clear:
        if sp >= 4096: return
        stack[sp] = suffix[c]
        inc sp
        c = int(prefix[c])
      stack[sp] = uint8(c and 255)
      inc sp
      if avail < 4096:
        prefix[avail] = int16(old)
        suffix[avail] = stack[sp - 1]
        first[avail] = first[old]
        inc avail
        if avail == (1 shl size) and size < 12: inc size
    old = code
    for k in countdown(sp - 1, 0):
      let ci = int(stack[k])
      if ci != trans:
        let c = pal[ci]
        dst[o] = uint8(c and 255)
        dst[o + 1] = uint8((c shr 8) and 255)
        dst[o + 2] = uint8((c shr 16) and 255)
        dst[o + 3] = uint8(c shr 24)
      inc done
      if done >= total: return
      inc x
      o += 4
      if x == fw:
        x = 0
        if interlaced:
          y += istep[pass]
          while y >= fh and pass < 3:
            inc pass
            y = istart[pass]
        else: inc y
        if y >= fh: return
        o = ((fy + y) * cw + fx) * 4

proc imgGif(d: string): ImgPicture =
  if d.len < 13: imgFail("The GIF file is cut short")
  var cw = imgLe16(d, 6)
  var ch = imgLe16(d, 8)
  let flags = imgU8(d, 10)
  var p = 13
  var gct: seq[uint32]
  if (flags and 0x80) != 0:
    let n = 2 shl (flags and 7)
    gct = imgGifTable(d, p, n)
    p += 3 * n
  var trans = -1
  var frames = 0
  var have = false
  while p < d.len:
    let b = ord(d[p])
    inc p
    if b == 0x21:
      let label = imgU8(d, p)
      inc p
      if label == 0xF9 and not have and imgU8(d, p) >= 4:
        trans = if (imgU8(d, p + 1) and 1) != 0: imgU8(d, p + 4) else: -1
      while p < d.len:
        let n = ord(d[p])
        p += n + 1
        if n == 0: break
    elif b == 0x2C:
      if p + 10 > d.len: break
      inc frames
      let fx = imgLe16(d, p)
      let fy = imgLe16(d, p + 2)
      let fw = imgLe16(d, p + 4)
      let fh = imgLe16(d, p + 6)
      let pf = imgU8(d, p + 8)
      p += 9
      var lct: seq[uint32]
      if (pf and 0x80) != 0:
        let n = 2 shl (pf and 7)
        lct = imgGifTable(d, p, n)
        p += 3 * n
      let minSize = imgU8(d, p)
      inc p
      var data = ""
      while p < d.len:
        let n = ord(d[p])
        if n == 0:
          inc p
          break
        if not have: data.add d[p + 1 ..< min(d.len, p + 1 + n)]
        p += n + 1
      if not have:
        have = true
        # the canvas is the logical screen, made larger when the frame does not fit in it (as browsers and PIL do)
        cw = max(cw, fx + fw)
        ch = max(ch, fy + fh)
        imgCheckSize(cw, ch, "GIF")
        result.px = newSeq[uint8](cw * ch * 4)
        var tbl = if lct.len > 0: lct else: gct
        if tbl.len == 0:
          for i in 0..255: tbl.add imgRgba(i, i, i, 255)
        imgGifLzw(data, minSize, fx, fy, fw, fh, (pf and 0x40) != 0, tbl, trans, result.px, cw)
    elif b == 0x3B: break
    else: break
  if not have: imgFail("The GIF file has no picture in it")
  result.w = cw
  result.h = ch
  result.format = "GIF"
  result.frames = frames
  result.scaled = 1
  result.fullW = cw
  result.fullH = ch

# ── BMP ──

proc imgBmp(d: string): ImgPicture =
  if d.len < 26: imgFail("The BMP file is cut short")
  let off = imgLe32(d, 10)
  let hs = imgLe32(d, 14)
  var w, h, bpp, comp, ncol: int
  var masks: array[4, int]          # red, green, blue, alpha
  let core = hs == 12
  if core:
    w = imgLe16(d, 18)
    h = imgLe16(d, 20)
    bpp = imgLe16(d, 24)
  else:
    w = imgLe32s(d, 18)
    h = imgLe32s(d, 22)
    bpp = imgLe16(d, 28)
    if hs >= 20: comp = imgLe32(d, 30)
    if hs >= 36: ncol = imgLe32(d, 46)
    if hs >= 52:
      for i in 0..2: masks[i] = imgLe32(d, 54 + 4 * i)
    if hs >= 56: masks[3] = imgLe32(d, 66)
  let topDown = h < 0
  h = abs(h)
  imgCheckSize(w, h, "BMP")
  var p = 14 + hs
  if comp in [3, 6] and hs < 52:
    for i in 0..2: masks[i] = imgLe32(d, p + 4 * i)
    p += 12
    if comp == 6:
      masks[3] = imgLe32(d, p)
      p += 4
  if comp == 0 and bpp == 16: masks = [0x7C00, 0x3E0, 0x1F, 0]
  if comp == 0 and bpp == 32: masks = [0xFF0000, 0xFF00, 0xFF, 0]
  var pal: array[256, uint32]
  for i in 0..255: pal[i] = imgRgba(0, 0, 0, 255)
  if bpp <= 8:
    let es = if core: 3 else: 4
    let n = if ncol > 0 and ncol <= 256: ncol else: 1 shl min(bpp, 8)
    for i in 0 ..< n:
      let q = p + i * es
      if q + 3 > d.len: break
      pal[i] = imgRgba(imgU8(d, q + 2), imgU8(d, q + 1), imgU8(d, q), 255)
  if off <= 0 or off >= d.len: imgFail("The BMP file is cut short")
  result = ImgPicture(w: w, h: h, format: "BMP", frames: 1, scaled: 1, fullW: w, fullH: h)
  result.px = newSeqUninit[uint8](w * h * 4)
  case comp
  of 0, 3, 6:
    if bpp == 64: imgFail("BMP files with 64 bits a pixel are not supported")
    if bpp notin [1, 2, 4, 8, 16, 24, 32]: imgFail("The BMP file is damaged")
    if comp != 0 and bpp notin [16, 32]: imgFail("The BMP file is damaged")
    let stride = ((w * bpp + 31) div 32) * 4
    if off + stride * (h - 1) + (w * bpp + 7) div 8 > d.len: imgFail("The BMP file is cut short")
    var shift, top: array[4, int]
    for i in 0..3:
      if masks[i] != 0:
        shift[i] = countTrailingZeroBits(masks[i])
        top[i] = masks[i] shr shift[i]
    var anyAlpha = false
    let p = cast[ptr UncheckedArray[uint8]](unsafeAddr d[0])   # (every row is inside d: checked above)
    for y in 0 ..< h:
      let r = off + (if topDown: y else: h - 1 - y) * stride
      let o = y * w * 4
      if bpp == 24 or (bpp == 32 and comp == 0):
        let n = bpp div 8
        for x in 0 ..< w:
          result.px[o + 4 * x] = p[r + n * x + 2]
          result.px[o + 4 * x + 1] = p[r + n * x + 1]
          result.px[o + 4 * x + 2] = p[r + n * x]
          result.px[o + 4 * x + 3] = 255
        continue
      for x in 0 ..< w:
        var c: uint32
        case bpp
        of 16, 32:
          let v = if bpp == 16: imgLe16(d, r + 2 * x) else: imgLe32(d, r + 4 * x)
          var ch: array[4, int]
          for i in 0..3:
            # a channel of any width to 0–255, as PIL does it (5 bits: v * 255 div 31)
            ch[i] = if top[i] == 0: (if i == 3: 255 else: 0) else: ((v and masks[i]) shr shift[i]) * 255 div top[i]
          if ch[3] != 0: anyAlpha = true
          c = imgRgba(ch[0], ch[1], ch[2], ch[3])
        else:
          let bit = x * bpp
          c = pal[(ord(d[r + (bit shr 3)]) shr (8 - bpp - (bit and 7))) and ((1 shl bpp) - 1)]
        imgPut(result.px, o + 4 * x, c)
    # alpha masks with every alpha zero are writers that meant no alpha: shown opaque, as browsers do
    if masks[3] != 0 and not anyAlpha:
      for i in 0 ..< w * h: result.px[4 * i + 3] = 255
  of 1, 2:
    let rle8 = comp == 1
    if bpp != (if rle8: 8 else: 4): imgFail("The BMP file is damaged")
    for i in 0 ..< w * h: imgPut(result.px, 4 * i, pal[0])   # what the runs do not reach: colour 0, as PIL has it
    var q = off
    var x, row = 0
    # x only grows within a row, so each row takes at most w pixels: runs past its end are not drawn at all
    template put(ci: int) =
      imgPut(result.px, ((if topDown: row else: h - 1 - row) * w + x) * 4, pal[ci and 255])
      inc x
    while q + 1 < d.len and row < h:
      let a = ord(d[q])
      let b = ord(d[q + 1])
      q += 2
      if a > 0:
        let n = max(0, min(a, w - x))
        for i in 0 ..< n:
          put(if rle8: b elif (i and 1) == 0: b shr 4 else: b and 15)
        x += a - n
      elif b == 0:
        x = 0
        inc row
      elif b == 1: break
      elif b == 2:
        x += imgU8(d, q)
        row += imgU8(d, q + 1)
        q += 2
      else:
        let n = max(0, min(b, w - x))
        for i in 0 ..< n:
          if rle8: put(imgU8(d, q + i))
          else: put(if (i and 1) == 0: imgU8(d, q + i div 2) shr 4 else: imgU8(d, q + i div 2) and 15)
        x += b - n
        q += (if rle8: b + (b and 1) else: ((b + 3) div 4) * 2)
  else: imgFail("BMP files compressed this way are not supported")

# ── decoding ──

proc imgDecode*(data: string, wantW = 0, wantH = 0): (ImgPicture, string) =
  ## the picture in the bytes and "", or an empty picture and why not (a short sentence for a person). wantW, wantH:
  ## the pixel size it will be shown at, 0 for not known; a JPEG at least 2, 4 or 8 times larger in both directions
  ## is decoded at 1/2, 1/4 or 1/8 of its size, which takes a fraction of the time (the result's `scaled` says which)
  try:
    case imgSniff(data)
    of "png": (imgPng(data), "")
    of "jpeg": (imgJpeg(data, wantW, wantH), "")
    of "gif": (imgGif(data), "")
    of "bmp": (imgBmp(data), "")
    of "webp": (ImgPicture(), "WebP pictures are not supported")
    else: (ImgPicture(), "Not a picture ned can read (PNG, JPEG, GIF or BMP)")
  except ImgError as e: (ImgPicture(), e.msg)
  except Exception as e: (ImgPicture(), "The picture cannot be read: " & e.msg)

proc imgDecodeFile*(path: string, wantW = 0, wantH = 0, maxBytes = 64 * 1024 * 1024): (ImgPicture, string) =
  ## imgDecode for a file; one larger than maxBytes is not read at all
  try:
    let size = getFileSize(path)
    if size > maxBytes:
      return (ImgPicture(), "The file is too large to show: " & $(size div (1024 * 1024)) & " MB (the most is " &
              $(maxBytes div (1024 * 1024)) & " MB)")
    let data = readFile(path)
    if data.len > maxBytes: return (ImgPicture(), "The file is too large to show")
    imgDecode(data, wantW, wantH)
  except Exception as e: (ImgPicture(), "The file cannot be read: " & e.msg)

# ── sizes and colours ──

proc imgFit*(iw, ih, maxW, maxH: int, upscale = false): (int, int) =
  ## the largest size within maxW × maxH with the shape of iw × ih (at least 1 × 1); the size itself when it fits
  ## already, unless upscale. (0, 0) when a size is zero or less
  if iw <= 0 or ih <= 0 or maxW <= 0 or maxH <= 0: return (0, 0)
  let mw = min(maxW, 1 shl 24)
  let mh = min(maxH, 1 shl 24)
  if not upscale and iw <= mw and ih <= mh: return (iw, ih)
  if mw * ih <= mh * iw: (mw, max(1, (ih * mw + iw div 2) div iw))
  else: (max(1, (iw * mh + ih div 2) div ih), mh)

proc imgAxis(src, dst: int): (seq[int], seq[int], seq[float32]) =
  ## for each new pixel along an axis: the first old pixel it covers, how many, and how much of each
  var start, cnt: seq[int]
  var wts: seq[float32]
  for i in 0 ..< dst:
    if dst >= src:
      start.add min(src - 1, ((2 * i + 1) * src) div (2 * dst))
      cnt.add 1
      wts.add 1.0'f32
    else:
      # in units where an old pixel is dst wide and a new one src wide
      let a = i * src
      let b = a + src
      let j0 = a div dst
      let j1 = min(src - 1, (b - 1) div dst)
      start.add j0
      cnt.add j1 - j0 + 1
      for k in j0..j1: wts.add float32(min(b, (k + 1) * dst) - max(a, k * dst)) / float32(src)
  (start, cnt, wts)

# The scaling loops go without Nim's checks: they read the picture through the axis tables, whose every entry is
# inside its size (checked against px.len on the way in), and they are most of the time a large picture takes
{.push checks: off.}

proc imgScale*(p: ImgPicture, w, h: int): ImgPicture =
  ## the picture at w × h pixels: made smaller, each pixel the average of the area it covers (colours weighted by
  ## their opacity, so transparent edges do not darken); made larger, the nearest pixel. Each direction on its own
  if w <= 0 or h <= 0 or p.w <= 0 or p.h <= 0 or p.px.len < p.w * p.h * 4 or w > ImgMaxSide or h > ImgMaxSide or
     w * h > ImgMaxPixels:
    return ImgPicture(format: p.format, frames: p.frames, scaled: p.scaled, fullW: p.fullW, fullH: p.fullH)
  if w == p.w and h == p.h: return p
  result = ImgPicture(w: w, h: h, format: p.format, frames: p.frames, scaled: p.scaled, fullW: p.fullW,
                      fullH: p.fullH)
  result.px = newSeqUninit[uint8](w * h * 4)
  let (xs, xc, xw) = imgAxis(p.w, w)
  let (ys, yc, yw) = imgAxis(p.h, h)
  if w >= p.w and h >= p.h:
    # larger both ways: each pixel copied from the nearest
    for y in 0 ..< h:
      let r = ys[y] * p.w
      for x in 0 ..< w: copyMem(addr result.px[(y * w + x) * 4], unsafeAddr p.px[(r + xs[x]) * 4], 4)
    return
  var alpha = false
  for i in 0 ..< p.w * p.h:
    if p.px[4 * i + 3] != 255:
      alpha = true
      break
  var tmp = newSeqUninit[float32](w * p.h * 4)
  for y in 0 ..< p.h:
    var k = 0
    for x in 0 ..< w:
      var r, g, b, a = 0.0'f32
      for t in 0 ..< xc[x]:
        let o = (y * p.w + xs[x] + t) * 4
        let wt = xw[k + t]
        let aa = float32(p.px[o + 3])
        let m = if alpha: wt * aa else: wt
        r += m * float32(p.px[o])
        g += m * float32(p.px[o + 1])
        b += m * float32(p.px[o + 2])
        a += wt * aa
      k += xc[x]
      let o = (y * w + x) * 4
      tmp[o] = r
      tmp[o + 1] = g
      tmp[o + 2] = b
      tmp[o + 3] = a
  var k = 0
  for y in 0 ..< h:
    for x in 0 ..< w:
      var r, g, b, a = 0.0'f32
      for t in 0 ..< yc[y]:
        let o = ((ys[y] + t) * w + x) * 4
        let wt = yw[k + t]
        r += wt * tmp[o]
        g += wt * tmp[o + 1]
        b += wt * tmp[o + 2]
        a += wt * tmp[o + 3]
      if alpha:
        if a > 0.0'f32:
          r /= a
          g /= a
          b /= a
        else:
          r = 0
          g = 0
          b = 0
      let o = (y * w + x) * 4
      result.px[o] = imgClampU8(int(r + 0.5'f32))
      result.px[o + 1] = imgClampU8(int(g + 0.5'f32))
      result.px[o + 2] = imgClampU8(int(b + 0.5'f32))
      result.px[o + 3] = imgClampU8(int(a + 0.5'f32))
    k += yc[y]

{.pop.}

proc imgOver*(p: ImgPicture, bg: uint32): ImgPicture =
  ## the picture put over a background colour (0xRRGGBB): fully opaque after
  result = p
  let br = int((bg shr 16) and 255)
  let bgg = int((bg shr 8) and 255)
  let bb = int(bg and 255)
  for i in 0 ..< min(p.w * p.h, p.px.len div 4):
    let o = 4 * i
    let a = int(result.px[o + 3])
    if a == 255: continue
    result.px[o] = uint8((int(result.px[o]) * a + br * (255 - a) + 127) div 255)
    result.px[o + 1] = uint8((int(result.px[o + 1]) * a + bgg * (255 - a) + 127) div 255)
    result.px[o + 2] = uint8((int(result.px[o + 2]) * a + bb * (255 - a) + 127) div 255)
    result.px[o + 3] = 255

proc imgHalfBlocks*(p: ImgPicture, cols, rows: int, bg: uint32): seq[seq[(uint32, uint32)]] =
  ## for each cell of rows × cols, the 0xRRGGBB colours of its upper and lower half — drawn as '▀' with the upper
  ## colour in front and the lower behind. The picture is fitted into cols × 2*rows pixels first (larger or smaller,
  ## its shape kept, in the middle), bg around it and under its transparent parts
  if cols <= 0 or rows <= 0: return
  result = newSeq[seq[(uint32, uint32)]](rows)
  for r in result.mitems: r = newSeq[(uint32, uint32)](cols)
  for r in result.mitems:
    for c in r.mitems: c = (bg and 0xFFFFFF'u32, bg and 0xFFFFFF'u32)
  let (fw, fh) = imgFit(p.w, p.h, cols, rows * 2, upscale = true)
  if fw == 0 or p.px.len < p.w * p.h * 4: return
  let s = imgOver(imgScale(p, fw, fh), bg)
  if s.px.len < fw * fh * 4: return             # (more cells than a picture may have pixels: left blank)
  let x0 = (cols - fw) div 2
  let y0 = (rows * 2 - fh) div 2
  for y in 0 ..< fh:
    let cy = (y0 + y) div 2
    for x in 0 ..< fw:
      let o = (y * fw + x) * 4
      let c = uint32(s.px[o]) shl 16 or uint32(s.px[o + 1]) shl 8 or uint32(s.px[o + 2])
      if ((y0 + y) and 1) == 0: result[cy][x0 + x][0] = c
      else: result[cy][x0 + x][1] = c

# ── what a terminal is sent ──

proc imgQuantize(q: ImgPicture, most: int): (seq[uint32], seq[uint8]) =
  ## at most `most` colours (0xRRGGBB) and each pixel's: the picture's own when it has few enough, else median cut
  ## over a histogram of 5 bits a channel
  let n = q.w * q.h
  var idx = newSeq[uint8](n)
  var pal: seq[uint32]
  var seen = initTable[uint32, int]()
  var last = 0xFFFFFFFF'u32
  var li = 0
  var exact = true
  for i in 0 ..< n:
    let c = uint32(q.px[4 * i]) shl 16 or uint32(q.px[4 * i + 1]) shl 8 or uint32(q.px[4 * i + 2])
    if c != last:
      li = seen.getOrDefault(c, -1)
      if li < 0:
        if pal.len >= most:
          exact = false
          break
        li = pal.len
        seen[c] = li
        pal.add c
      last = c
    idx[i] = uint8(li)
  if exact: return (pal, idx)
  template key(i: int): int =
    (int(q.px[4 * i]) shr 3) shl 10 or (int(q.px[4 * i + 1]) shr 3) shl 5 or (int(q.px[4 * i + 2]) shr 3)
  var count = newSeq[int](32768)
  var sums = newSeq[array[3, int]](32768)
  for i in 0 ..< n:
    let k = key(i)
    inc count[k]
    for c in 0..2: sums[k][c] += int(q.px[4 * i + c])
  var bins: seq[int]
  for k in 0 ..< 32768:
    if count[k] > 0: bins.add k
  template chan(k, c: int): int = (k shr (10 - 5 * c)) and 31
  # a box: its bins, its pixels, the channel it is longest in and how much a split of it is worth (the pixels
  # times that length) — worked out once, when the box is made
  type Box = tuple[lo, hi, axis, score: int]
  proc measure(lo, hi: int): Box =
    var mn = [31, 31, 31]
    var mx = [0, 0, 0]
    var pixels = 0
    for t in lo ..< hi:
      let k = bins[t]
      pixels += count[k]
      for c in 0..2:
        mn[c] = min(mn[c], chan(k, c))
        mx[c] = max(mx[c], chan(k, c))
    var ax = 0
    for c in 1..2:
      if mx[c] - mn[c] > mx[ax] - mn[ax]: ax = c
    (lo, hi, ax, if hi - lo < 2: 0 else: pixels * (mx[ax] - mn[ax] + 1))
  var tmp = newSeq[int](bins.len)
  var boxes = @[measure(0, bins.len)]
  while boxes.len < most:
    # split the box worth most, at its median along its longest side
    var best = -1
    var bestScore = 0
    for bi, b in boxes:
      if b.score > bestScore:
        best = bi
        bestScore = b.score
    if best < 0: break
    let (lo, hi, ax, _) = boxes[best]
    # its bins in order along that channel: a counting sort, the channel has 32 values
    var at: array[33, int]
    for t in lo ..< hi: inc at[chan(bins[t], ax) + 1]
    for v in 1..32: at[v] += at[v - 1]
    for t in lo ..< hi:
      let k = bins[t]
      tmp[lo + at[chan(k, ax)]] = k
      inc at[chan(k, ax)]
    for t in lo ..< hi: bins[t] = tmp[t]
    var total = 0
    for t in lo ..< hi: total += count[bins[t]]
    var acc = 0
    var m = lo
    while m < hi - 1 and acc + count[bins[m]] <= total div 2:
      acc += count[bins[m]]
      inc m
    if m == lo: m = lo + 1
    boxes[best] = measure(lo, m)
    boxes.add measure(m, hi)
  # each box's colour the mean of its pixels; each bin goes to its box's
  pal.setLen(0)
  var map = newSeq[uint8](32768)
  for bi, (lo, hi, _, _) in boxes:
    var s: array[3, int]
    var cnt = 0
    for t in lo ..< hi:
      cnt += count[bins[t]]
      for c in 0..2: s[c] += sums[bins[t]][c]
      map[bins[t]] = uint8(bi)
    let c = cnt.max(1)
    pal.add uint32((s[0] + c div 2) div c) shl 16 or uint32((s[1] + c div 2) div c) shl 8 or
            uint32((s[2] + c div 2) div c)
  for i in 0 ..< n: idx[i] = map[key(i)]
  (pal, idx)

proc imgSixel*(p: ImgPicture, bg: uint32): string =
  ## the picture as a DCS sixel sequence (ESC P q … ESC \) at its pixel size, transparent parts over bg: the raster
  ## attributes, up to 256 colours, then bands of six rows, each colour of a band from its first column to its last
  let q = imgOver(p, bg)
  if q.w <= 0 or q.h <= 0 or q.px.len < q.w * q.h * 4: return ""
  let (pal, idx) = imgQuantize(q, 256)
  let w = q.w
  result = newStringOfCap(w * q.h div 2 + 4096)
  result.add "\eP0;1;0q\"1;1;" & $w & ";" & $q.h
  for i, c in pal:
    template pct(v: uint32): string = $((int(v and 255) * 100 + 127) div 255)
    result.add "#" & $i & ";2;" & pct(c shr 16) & ";" & pct(c shr 8) & ";" & pct(c)
  proc run(s: var string, ch: char, n: int) =
    if n >= 4:
      s.add '!'
      s.add $n
      s.add ch
    else:
      for i in 0 ..< n: s.add ch
  # for each colour of a band, the columns it has (in order) and its six bits in each: the work and the output
  # go with the pixels, not with the colours times the width
  var bits = newSeq[uint8](pal.len * w)
  var cols = newSeq[seq[int32]](pal.len)
  var used: seq[int]
  let bands = (q.h + 5) div 6
  for band in 0 ..< bands:
    used.setLen(0)
    let rowsIn = min(6, q.h - band * 6)
    for x in 0 ..< w:
      for dy in 0 ..< rowsIn:
        let c = int(idx[(band * 6 + dy) * w + x])
        let k = c * w + x
        if bits[k] == 0:
          if cols[c].len == 0: used.add c
          cols[c].add int32(x)
        bits[k] = bits[k] or uint8(1 shl dy)
    for ui, c in used:
      result.add '#'
      result.add $c
      var next = 0                  # the column the next sixel goes to
      var i = 0
      let cc = cols[c].len
      while i < cc:
        let x = int(cols[c][i])
        run(result, '?', x - next)
        let b = bits[c * w + x]
        var n = 1
        while i + n < cc and int(cols[c][i + n]) == x + n and bits[c * w + x + n] == b: inc n
        run(result, char(63 + int(b)), n)
        for k in x ..< x + n: bits[c * w + k] = 0
        next = x + n
        i += n
      cols[c].setLen(0)
      if ui < used.high: result.add '$'
    if band < bands - 1: result.add '-'
  result.add "\e\\"

proc imgKitty*(p: ImgPicture, id, cols, rows: int, png = ""): string =
  ## the kitty graphics protocol: transmit and show (a=T) at the cursor, scaled to cols × rows cells, as image `id`,
  ## quiet (q=2), the cursor left where it is (C=1, so a picture on the last row does not scroll the screen), the
  ## data in base64 chunks of at most 4096 (m=1 … m=0). png: the file's own bytes when it is a PNG (f=100), else the
  ## picture's RGBA is sent (f=32)
  let payload = if png.len > 0: encode(png) else: encode(p.px)
  var keys = if png.len > 0: "a=T,f=100" else: "a=T,f=32,s=" & $p.w & ",v=" & $p.h
  keys.add ",i=" & $id
  if cols > 0: keys.add ",c=" & $cols
  if rows > 0: keys.add ",r=" & $rows
  keys.add ",C=1,q=2,"
  var i = 0
  while true:
    let n = min(4096, payload.len - i)
    let more = i + n < payload.len
    result.add "\e_G"
    if i == 0: result.add keys
    else: result.add "q=2,"
    result.add (if more: "m=1;" else: "m=0;")
    result.add payload.substr(i, i + n - 1)
    result.add "\e\\"
    i += n
    if not more: break

proc imgKittyDelete*(id: int): string =
  ## the kitty graphics protocol: delete image `id` and its placements, freeing its data (a=d,d=I)
  "\e_Ga=d,d=I,i=" & $id & ",q=2\e\\"

proc imgIterm*(data: string, cols, rows: int): string =
  ## an iTerm2 / WezTerm inline image of the file's own bytes, in cols × rows cells, its shape kept
  "\e]1337;File=inline=1;width=" & $cols & ";height=" & $rows & ";preserveAspectRatio=1:" & encode(data) & "\a"
