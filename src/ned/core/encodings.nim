## Text encodings: what a file's bytes are (UTF-8, with or without a BOM, UTF-16 with its BOM, Windows-1252 for
## text that is not UTF-8) and the conversions to and from the UTF-8 the editor keeps. Others go through iconv
## (the editor runs it).

import std/strutils
import text

const
  EncUtf8* = ""                  ## (no name: UTF-8 without a BOM, nearly every file)
  EncUtf8Bom* = "utf-8-bom"
  EncUtf16Le* = "utf-16le"
  EncUtf16Be* = "utf-16be"
  EncCp1252* = "windows-1252"
  EncLatin1* = "iso-8859-1"
  BuiltinEncodings* = [EncUtf8, EncUtf8Bom, EncUtf16Le, EncUtf16Be, EncCp1252, EncLatin1]
  IconvEncodings* = ["iso-8859-2", "iso-8859-5", "iso-8859-7", "iso-8859-9", "iso-8859-15", "windows-1250",
                     "windows-1251", "windows-1253", "windows-1254", "windows-1256", "koi8-r", "koi8-u", "shift_jis",
                     "euc-jp", "gbk", "gb18030", "big5", "euc-kr", "cp437", "cp850", "macintosh"]
    ## what the encoding menu offers through iconv

  Cp1252High: array[32, int] = [0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160,
    0x2039, 0x0152, 0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122,
    0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178]
    ## Windows-1252's 0x80 … 0x9F (where Latin-1 has control characters; the five it leaves out: themselves)

func encLabel*(enc: string): string =
  ## what the status bar shows
  case enc
  of EncUtf8: "UTF-8"
  of EncUtf8Bom: "UTF-8 BOM"
  of EncUtf16Le: "UTF-16 LE"
  of EncUtf16Be: "UTF-16 BE"
  of EncCp1252: "Windows-1252"
  of EncLatin1: "ISO-8859-1"
  else: enc.toUpperAscii

func validUtf8*(s: string): bool =
  ## every byte sequence a valid UTF-8 character (no overlong forms, no surrogates)
  var i = 0
  let n = s.len
  while i < n:
    let c = s[i].ord
    if c < 0x80:
      inc i
      continue
    var need, cp, lo: int
    if c >= 0xC2 and c <= 0xDF: (need, cp, lo) = (1, c and 0x1F, 0x80)
    elif c >= 0xE0 and c <= 0xEF: (need, cp, lo) = (2, c and 0x0F, 0x800)
    elif c >= 0xF0 and c <= 0xF4: (need, cp, lo) = (3, c and 0x07, 0x10000)
    else: return false
    for k in 1 .. need:
      if i + k >= n: return false
      let d = s[i + k].ord
      if (d and 0xC0) != 0x80: return false
      cp = (cp shl 6) or (d and 0x3F)
    if cp < lo or cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF): return false
    i += need + 1
  true

func utf8Repaired*(s: string): string =
  ## `s` with each byte sequence that is not UTF-8 — a character cut in two, a byte of another encoding — as U+FFFD
  ## (�): text a server that checks its JSON's UTF-8 takes (llama.cpp refuses the whole request over one such byte);
  ## `s` itself when it is valid
  if validUtf8(s): return s
  result = newStringOfCap(s.len + 16)
  var i = 0
  let n = s.len
  while i < n:
    let c = s[i].ord
    if c < 0x80:
      result.add s[i]
      inc i
      continue
    var need, cp, lo: int
    if c >= 0xC2 and c <= 0xDF: (need, cp, lo) = (1, c and 0x1F, 0x80)
    elif c >= 0xE0 and c <= 0xEF: (need, cp, lo) = (2, c and 0x0F, 0x800)
    elif c >= 0xF0 and c <= 0xF4: (need, cp, lo) = (3, c and 0x07, 0x10000)
    else:
      result.add "\xEF\xBF\xBD"
      inc i
      continue
    var k = 1
    var whole = true
    while k <= need:
      if i + k >= n or (s[i + k].ord and 0xC0) != 0x80:
        whole = false
        break
      cp = (cp shl 6) or (s[i + k].ord and 0x3F)
      inc k
    if whole and cp >= lo and cp <= 0x10FFFF and not (cp >= 0xD800 and cp <= 0xDFFF):
      result.add s[i .. i + need]
    else:
      result.add "\xEF\xBF\xBD"         # (one for the start of a character and what came of it)
    i += k

func utf8Cut*(s: string, at: int): int =
  ## a byte index at or before `at` that does not split a UTF-8 character: where to cut `s` to about `at` bytes
  result = clamp(at, 0, s.len)
  while result > 0 and result < s.len and (ord(s[result]) and 0xC0) == 0x80: dec result

func detectEncoding*(bytes: string, fallback = EncCp1252): string =
  ## a BOM says it; else UTF-8 when the bytes are valid UTF-8; else `fallback` (text from an older Windows or Mac
  ## program, most often). Bytes with NULs and no BOM are not text (the caller's binary check)
  if bytes.len >= 3 and bytes[0] == '\xEF' and bytes[1] == '\xBB' and bytes[2] == '\xBF': return EncUtf8Bom
  if bytes.len >= 2 and bytes[0] == '\xFF' and bytes[1] == '\xFE': return EncUtf16Le
  if bytes.len >= 2 and bytes[0] == '\xFE' and bytes[1] == '\xFF': return EncUtf16Be
  if validUtf8(bytes): return EncUtf8
  # (UTF-8 with a few broken bytes — a cut-off character, a stray Latin-1 one: still UTF-8, its bytes kept as they
  # are; read as Windows-1252 every é in it would show as Ã©)
  var good, bad = 0
  var i = 0
  while i < bytes.len:
    let c = bytes[i].ord
    if c < 0x80:
      inc i
      continue
    let need = if c >= 0xC2 and c <= 0xDF: 1 elif c >= 0xE0 and c <= 0xEF: 2 elif c >= 0xF0 and c <= 0xF4: 3 else: 0
    var ok = need > 0 and i + need <= bytes.high
    if ok:
      for k in 1 .. need:
        if (bytes[i + k].ord and 0xC0) != 0x80: ok = false
    if ok:
      inc good
      i += need + 1
    else:
      inc bad
      inc i
  if good > 0 and good >= bad * 4: return EncUtf8
  fallback

func decodeUtf16(bytes: string, le: bool, start: int): (bool, string) =
  ## UTF-16 bytes (little or big endian) from byte start on, as UTF-8, surrogate pairs joined; false when something was
  ## not valid (a lone surrogate, which becomes U+FFFD, or an odd byte at the end)
  var i = start
  var ok = true
  var res = newStringOfCap(bytes.len)
  template unit(k: int): int =
    ## the 16-bit unit that starts at byte k, in the byte order being read
    (if le: bytes[k].ord or (bytes[k + 1].ord shl 8) else: (bytes[k].ord shl 8) or bytes[k + 1].ord)
  while i + 1 < bytes.len:
    var u = unit(i)
    i += 2
    if u >= 0xD800 and u <= 0xDBFF:
      if i + 1 < bytes.len:
        let u2 = unit(i)
        if u2 >= 0xDC00 and u2 <= 0xDFFF:
          i += 2
          res.addUtf8(0x10000 + ((u - 0xD800) shl 10) + (u2 - 0xDC00))
          continue
      ok = false
      u = 0xFFFD
    elif u >= 0xDC00 and u <= 0xDFFF:
      ok = false
      u = 0xFFFD
    res.addUtf8(u)
  if i < bytes.len: ok = false            # (an odd byte at the end)
  (ok, res)

func decode*(bytes: string, enc: string): (bool, string) =
  ## the bytes as UTF-8 (false: something did not convert cleanly — a replacement character stands for it; an
  ## encoding only iconv knows: false and the bytes unchanged)
  case enc
  of EncUtf8: (validUtf8(bytes), bytes)
  of EncUtf8Bom:
    let b = if bytes.startsWith("\xEF\xBB\xBF"): bytes[3 .. ^1] else: bytes
    (validUtf8(b), b)
  of EncUtf16Le: decodeUtf16(bytes, true, (if bytes.startsWith("\xFF\xFE"): 2 else: 0))
  of EncUtf16Be: decodeUtf16(bytes, false, (if bytes.startsWith("\xFE\xFF"): 2 else: 0))
  of EncCp1252, EncLatin1:
    var res = newStringOfCap(bytes.len + bytes.len div 8)
    for c in bytes:
      let o = c.ord
      if o < 0x80: res.add c
      elif o < 0xA0 and enc == EncCp1252: res.addUtf8(Cp1252High[o - 0x80])
      else: res.addUtf8(o)
    (true, res)
  else: (false, bytes)

iterator codepoints(s: string): (int, int) =
  ## (code point, its byte offset)
  var i = 0
  while i < s.len:
    let c = s[i].ord
    var n = 1
    var cp = c
    if c >= 0xF0 and i + 3 < s.len:
      n = 4
      cp = ((c and 0x07) shl 18) or ((s[i + 1].ord and 0x3F) shl 12) or ((s[i + 2].ord and 0x3F) shl 6) or
           (s[i + 3].ord and 0x3F)
    elif c >= 0xE0 and i + 2 < s.len:
      n = 3
      cp = ((c and 0x0F) shl 12) or ((s[i + 1].ord and 0x3F) shl 6) or (s[i + 2].ord and 0x3F)
    elif c >= 0xC0 and i + 1 < s.len:
      n = 2
      cp = ((c and 0x1F) shl 6) or (s[i + 1].ord and 0x3F)
    yield (cp, i)
    i += n

func encode*(text: string, enc: string): (bool, string, int) =
  ## UTF-8 → the encoding's bytes; false and the byte offset of the first character it cannot hold (-1: an
  ## encoding only iconv knows)
  case enc
  of EncUtf8: (true, text, -1)
  of EncUtf8Bom: (true, "\xEF\xBB\xBF" & text, -1)
  of EncUtf16Le, EncUtf16Be:
    let le = enc == EncUtf16Le
    var res = newStringOfCap(text.len * 2 + 2)
    res.add (if le: "\xFF\xFE" else: "\xFE\xFF")
    proc unit(r: var string, u: int, le: bool) =
      ## appends one 16-bit unit to the string in the given byte order
      if le:
        r.add char(u and 0xFF)
        r.add char(u shr 8)
      else:
        r.add char(u shr 8)
        r.add char(u and 0xFF)
    for (cp, _) in codepoints(text):
      if cp >= 0x10000:
        let v = cp - 0x10000
        res.unit(0xD800 + (v shr 10), le)
        res.unit(0xDC00 + (v and 0x3FF), le)
      else: res.unit(cp, le)
    (true, res, -1)
  of EncCp1252, EncLatin1:
    var res = newStringOfCap(text.len)
    for (cp, at) in codepoints(text):
      if cp < 0x80: res.add char(cp)
      elif enc == EncLatin1 and cp <= 0xFF: res.add char(cp)
      elif enc == EncCp1252 and cp >= 0xA0 and cp <= 0xFF: res.add char(cp)
      elif enc == EncCp1252:
        var k = -1
        for j, x in Cp1252High:
          if x == cp: k = j
        if k < 0: return (false, "", at)
        res.add char(0x80 + k)
      else: return (false, "", at)
    (true, res, -1)
  else: (false, text, -1)
