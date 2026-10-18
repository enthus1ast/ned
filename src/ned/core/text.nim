## Text measured as the terminal shows it: UTF-8 runes, their display width, tabs.
## A module of its own: the Nim index and the formatters use it too.

import std/json

var tabW* = 4                  # the tab width in use: the buffer being drawn or edited

func runeLen*(c: char): int {.inline.} =
  let b = c.uint8
  if b < 0x80: 1
  elif (b and 0xE0) == 0xC0: 2
  elif (b and 0xF0) == 0xE0: 3
  elif (b and 0xF8) == 0xF0: 4
  else: 1

func runeAt*(s: string, i: int): (int, int) =
  ## (codepoint, byte length) of the rune starting at byte i
  let b0 = s[i].uint8.int
  if b0 < 0x80: return (b0, 1)
  let n = runeLen(s[i])
  if n == 1 or i + n > s.len: return (0xFFFD, 1)
  for k in 1..<n:
    if (s[i+k].uint8 and 0xC0) != 0x80: return (0xFFFD, 1)
  case n
  of 2: (((b0 and 0x1F) shl 6) or (s[i+1].uint8.int and 0x3F), 2)
  of 3: (((b0 and 0x0F) shl 12) or ((s[i+1].uint8.int and 0x3F) shl 6) or
         (s[i+2].uint8.int and 0x3F), 3)
  else: (((b0 and 0x07) shl 18) or ((s[i+1].uint8.int and 0x3F) shl 12) or
         ((s[i+2].uint8.int and 0x3F) shl 6) or (s[i+3].uint8.int and 0x3F), 4)

func nextRune*(s: string, i: int): int {.inline.} =
  if i >= s.len: s.len else: i + runeAt(s, i)[1]

func prevRune*(s: string, i: int): int =
  if i <= 0: return 0
  var j = i - 1
  while j > 0 and (s[j].uint8 and 0xC0) == 0x80 and i - j < 4: dec j
  j

func addUtf8*(s: var string, cp: int) =
  if cp < 0x80: s.add chr(cp)
  elif cp < 0x800:
    s.add chr(0xC0 or (cp shr 6)); s.add chr(0x80 or (cp and 0x3F))
  elif cp < 0x10000:
    s.add chr(0xE0 or (cp shr 12)); s.add chr(0x80 or ((cp shr 6) and 0x3F))
    s.add chr(0x80 or (cp and 0x3F))
  else:
    s.add chr(0xF0 or (cp shr 18)); s.add chr(0x80 or ((cp shr 12) and 0x3F))
    s.add chr(0x80 or ((cp shr 6) and 0x3F)); s.add chr(0x80 or (cp and 0x3F))

func runeWidth*(cp: int): int =
  if cp < 0x300: return 1
  if (cp >= 0x300 and cp <= 0x36F) or (cp >= 0x483 and cp <= 0x489) or
     (cp >= 0x591 and cp <= 0x5BD) or (cp >= 0x610 and cp <= 0x61A) or
     (cp >= 0x64B and cp <= 0x65F) or cp == 0x670 or (cp >= 0x6D6 and cp <= 0x6ED) or
     (cp >= 0x1AB0 and cp <= 0x1AFF) or (cp >= 0x1DC0 and cp <= 0x1DFF) or
     (cp >= 0x200B and cp <= 0x200F) or (cp >= 0x20D0 and cp <= 0x20FF) or
     (cp >= 0xFE00 and cp <= 0xFE0F) or (cp >= 0xFE20 and cp <= 0xFE2F) or cp == 0xFEFF:
    return 0
  if (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0x303E) or
     (cp >= 0x3041 and cp <= 0x33FF) or (cp >= 0x3400 and cp <= 0x4DBF) or
     (cp >= 0x4E00 and cp <= 0x9FFF) or (cp >= 0xA000 and cp <= 0xA4CF) or
     (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
     (cp >= 0xFE30 and cp <= 0xFE4F) or (cp >= 0xFF00 and cp <= 0xFF60) or
     (cp >= 0xFFE0 and cp <= 0xFFE6) or (cp >= 0x1F300 and cp <= 0x1F64F) or
     (cp >= 0x1F680 and cp <= 0x1F6FF) or (cp >= 0x1F900 and cp <= 0x1F9FF) or
     (cp >= 0x20000 and cp <= 0x3FFFD):
    return 2
  1

proc charWidthAt*(s: string, i: int, vc: int): (int, int) {.inline.} =
  ## (display width, byte length) of the char at byte i when it starts at visual column vc
  let c = s[i]
  if c == '\t': return (tabW - (vc mod tabW), 1)
  if c.uint8 < 0x80: return (1, 1)
  let (cp, n) = runeAt(s, i)
  (runeWidth(cp), n)

proc visColOf*(s: string, col: int): int =
  var i = 0
  while i < col and i < s.len:
    if s[i] in {' ' .. '~'}:              # plain ASCII: one column (the common case, fast on long lines)
      inc result
      inc i
      continue
    let (w, n) = charWidthAt(s, i, result)
    result += w
    i += n

proc colAtVis*(s: string, target: int, start = 0, startVc = 0): int =
  ## byte index of the char covering visual column `target` (s.len if beyond)
  var i = start
  var vc = startVc
  while i < s.len:
    let (w, n) = charWidthAt(s, i, vc)
    if vc + w > target and w > 0:
      if target - vc > (w - 1) div 2 and w > 1 and s[i] == '\t': return i + n
      return i
    vc += w
    i += n
  s.len

proc strWidth*(s: string): int = visColOf(s, s.len)

func isWordByte*(c: char): bool {.inline.} =
  c in {'a'..'z', 'A'..'Z', '0'..'9', '_'} or c.uint8 >= 0x80

func isIdentStart*(c: char): bool {.inline.} =
  c in {'a'..'z', 'A'..'Z', '_'} or c.uint8 >= 0x80

func startsAt*(s, sub: string, i: int): bool {.inline.} =
  if sub.len == 0 or i + sub.len > s.len: return false
  for k in 0..<sub.len:
    if s[i+k] != sub[k]: return false
  true

func leadingWs*(s: string): string =
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  s[0..<i]

func isBlank*(s: string): bool =
  for c in s:
    if c notin {' ', '\t'}: return false
  true

iterator jitems*(n: JsonNode): JsonNode =
  ## the elements of a JSON array — nothing for nil or any other kind (servers and files are not trusted)
  if n != nil and n.kind == JArray:
    for x in n.elems: yield x

proc truncTo*(s: string, w: int): string =
  ## truncate to display width w, adding an ellipsis
  if w <= 0: return ""
  if strWidth(s) <= w: return s
  var i = 0
  var vc = 0
  while i < s.len:
    let (cw, n) = charWidthAt(s, i, vc)
    if vc + cw > w - 1: break
    vc += cw
    i += n
  s[0..<i] & "…"
