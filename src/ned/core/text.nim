## Text measured as the terminal shows it: UTF-8 runes, their display width, tabs.
## A module of its own: the Nim index and the formatters use it too.

import std/[json, tables]

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

# ── how many columns a character takes, as the terminal shows it ──
#
#    zero: the marks (Mn, Me, the Hangul medial and final jamo) join the character before them; the format characters
#    (Cf: ZWJ, the bidi marks, a BOM …) stand alone. Two: East Asian Wide and Fullwidth — CJK, Hangul, and the emoji
#    shown as emoji (✅ ⭐ ⌚ 🫠 …). From Unicode 15.1, by tests/unit/genwidths.py: what glibc's wcwidth says, and with
#    it the terminals and the programs in them

const ZeroRanges: array[358, (int32, int32, int8)] = [
  (0x300, 0x36F, 1), (0x483, 0x489, 1), (0x591, 0x5BD, 1), (0x5BF, 0x5BF, 1), (0x5C1, 0x5C2, 1), (0x5C4, 0x5C5, 1),
  (0x5C7, 0x5C7, 1), (0x610, 0x61A, 1), (0x61C, 0x61C, 2), (0x64B, 0x65F, 1), (0x670, 0x670, 1), (0x6D6, 0x6DC, 1),
  (0x6DF, 0x6E4, 1), (0x6E7, 0x6E8, 1), (0x6EA, 0x6ED, 1), (0x711, 0x711, 1), (0x730, 0x74A, 1), (0x7A6, 0x7B0, 1),
  (0x7EB, 0x7F3, 1), (0x7FD, 0x7FD, 1), (0x816, 0x819, 1), (0x81B, 0x823, 1), (0x825, 0x827, 1), (0x829, 0x82D, 1),
  (0x859, 0x85B, 1), (0x898, 0x89F, 1), (0x8CA, 0x8E1, 1), (0x8E3, 0x902, 1), (0x93A, 0x93A, 1), (0x93C, 0x93C, 1),
  (0x941, 0x948, 1), (0x94D, 0x94D, 1), (0x951, 0x957, 1), (0x962, 0x963, 1), (0x981, 0x981, 1), (0x9BC, 0x9BC, 1),
  (0x9C1, 0x9C4, 1), (0x9CD, 0x9CD, 1), (0x9E2, 0x9E3, 1), (0x9FE, 0x9FE, 1), (0xA01, 0xA02, 1), (0xA3C, 0xA3C, 1),
  (0xA41, 0xA42, 1), (0xA47, 0xA48, 1), (0xA4B, 0xA4D, 1), (0xA51, 0xA51, 1), (0xA70, 0xA71, 1), (0xA75, 0xA75, 1),
  (0xA81, 0xA82, 1), (0xABC, 0xABC, 1), (0xAC1, 0xAC5, 1), (0xAC7, 0xAC8, 1), (0xACD, 0xACD, 1), (0xAE2, 0xAE3, 1),
  (0xAFA, 0xAFF, 1), (0xB01, 0xB01, 1), (0xB3C, 0xB3C, 1), (0xB3F, 0xB3F, 1), (0xB41, 0xB44, 1), (0xB4D, 0xB4D, 1),
  (0xB55, 0xB56, 1), (0xB62, 0xB63, 1), (0xB82, 0xB82, 1), (0xBC0, 0xBC0, 1), (0xBCD, 0xBCD, 1), (0xC00, 0xC00, 1),
  (0xC04, 0xC04, 1), (0xC3C, 0xC3C, 1), (0xC3E, 0xC40, 1), (0xC46, 0xC48, 1), (0xC4A, 0xC4D, 1), (0xC55, 0xC56, 1),
  (0xC62, 0xC63, 1), (0xC81, 0xC81, 1), (0xCBC, 0xCBC, 1), (0xCBF, 0xCBF, 1), (0xCC6, 0xCC6, 1), (0xCCC, 0xCCD, 1),
  (0xCE2, 0xCE3, 1), (0xD00, 0xD01, 1), (0xD3B, 0xD3C, 1), (0xD41, 0xD44, 1), (0xD4D, 0xD4D, 1), (0xD62, 0xD63, 1),
  (0xD81, 0xD81, 1), (0xDCA, 0xDCA, 1), (0xDD2, 0xDD4, 1), (0xDD6, 0xDD6, 1), (0xE31, 0xE31, 1), (0xE34, 0xE3A, 1),
  (0xE47, 0xE4E, 1), (0xEB1, 0xEB1, 1), (0xEB4, 0xEBC, 1), (0xEC8, 0xECE, 1), (0xF18, 0xF19, 1), (0xF35, 0xF35, 1),
  (0xF37, 0xF37, 1), (0xF39, 0xF39, 1), (0xF71, 0xF7E, 1), (0xF80, 0xF84, 1), (0xF86, 0xF87, 1), (0xF8D, 0xF97, 1),
  (0xF99, 0xFBC, 1), (0xFC6, 0xFC6, 1), (0x102D, 0x1030, 1), (0x1032, 0x1037, 1), (0x1039, 0x103A, 1),
  (0x103D, 0x103E, 1), (0x1058, 0x1059, 1), (0x105E, 0x1060, 1), (0x1071, 0x1074, 1), (0x1082, 0x1082, 1),
  (0x1085, 0x1086, 1), (0x108D, 0x108D, 1), (0x109D, 0x109D, 1), (0x1160, 0x11FF, 1), (0x135D, 0x135F, 1),
  (0x1712, 0x1714, 1), (0x1732, 0x1733, 1), (0x1752, 0x1753, 1), (0x1772, 0x1773, 1), (0x17B4, 0x17B5, 1),
  (0x17B7, 0x17BD, 1), (0x17C6, 0x17C6, 1), (0x17C9, 0x17D3, 1), (0x17DD, 0x17DD, 1), (0x180B, 0x180D, 1),
  (0x180E, 0x180E, 2), (0x180F, 0x180F, 1), (0x1885, 0x1886, 1), (0x18A9, 0x18A9, 1), (0x1920, 0x1922, 1),
  (0x1927, 0x1928, 1), (0x1932, 0x1932, 1), (0x1939, 0x193B, 1), (0x1A17, 0x1A18, 1), (0x1A1B, 0x1A1B, 1),
  (0x1A56, 0x1A56, 1), (0x1A58, 0x1A5E, 1), (0x1A60, 0x1A60, 1), (0x1A62, 0x1A62, 1), (0x1A65, 0x1A6C, 1),
  (0x1A73, 0x1A7C, 1), (0x1A7F, 0x1A7F, 1), (0x1AB0, 0x1ACE, 1), (0x1B00, 0x1B03, 1), (0x1B34, 0x1B34, 1),
  (0x1B36, 0x1B3A, 1), (0x1B3C, 0x1B3C, 1), (0x1B42, 0x1B42, 1), (0x1B6B, 0x1B73, 1), (0x1B80, 0x1B81, 1),
  (0x1BA2, 0x1BA5, 1), (0x1BA8, 0x1BA9, 1), (0x1BAB, 0x1BAD, 1), (0x1BE6, 0x1BE6, 1), (0x1BE8, 0x1BE9, 1),
  (0x1BED, 0x1BED, 1), (0x1BEF, 0x1BF1, 1), (0x1C2C, 0x1C33, 1), (0x1C36, 0x1C37, 1), (0x1CD0, 0x1CD2, 1),
  (0x1CD4, 0x1CE0, 1), (0x1CE2, 0x1CE8, 1), (0x1CED, 0x1CED, 1), (0x1CF4, 0x1CF4, 1), (0x1CF8, 0x1CF9, 1),
  (0x1DC0, 0x1DFF, 1), (0x200B, 0x200F, 2), (0x202A, 0x202E, 2), (0x2060, 0x2064, 2), (0x2066, 0x206F, 2),
  (0x20D0, 0x20F0, 1), (0x2CEF, 0x2CF1, 1), (0x2D7F, 0x2D7F, 1), (0x2DE0, 0x2DFF, 1), (0x302A, 0x302D, 1),
  (0x3099, 0x309A, 1), (0xA66F, 0xA672, 1), (0xA674, 0xA67D, 1), (0xA69E, 0xA69F, 1), (0xA6F0, 0xA6F1, 1),
  (0xA802, 0xA802, 1), (0xA806, 0xA806, 1), (0xA80B, 0xA80B, 1), (0xA825, 0xA826, 1), (0xA82C, 0xA82C, 1),
  (0xA8C4, 0xA8C5, 1), (0xA8E0, 0xA8F1, 1), (0xA8FF, 0xA8FF, 1), (0xA926, 0xA92D, 1), (0xA947, 0xA951, 1),
  (0xA980, 0xA982, 1), (0xA9B3, 0xA9B3, 1), (0xA9B6, 0xA9B9, 1), (0xA9BC, 0xA9BD, 1), (0xA9E5, 0xA9E5, 1),
  (0xAA29, 0xAA2E, 1), (0xAA31, 0xAA32, 1), (0xAA35, 0xAA36, 1), (0xAA43, 0xAA43, 1), (0xAA4C, 0xAA4C, 1),
  (0xAA7C, 0xAA7C, 1), (0xAAB0, 0xAAB0, 1), (0xAAB2, 0xAAB4, 1), (0xAAB7, 0xAAB8, 1), (0xAABE, 0xAABF, 1),
  (0xAAC1, 0xAAC1, 1), (0xAAEC, 0xAAED, 1), (0xAAF6, 0xAAF6, 1), (0xABE5, 0xABE5, 1), (0xABE8, 0xABE8, 1),
  (0xABED, 0xABED, 1), (0xD7B0, 0xD7FF, 1), (0xFB1E, 0xFB1E, 1), (0xFE00, 0xFE0F, 1), (0xFE20, 0xFE2F, 1),
  (0xFEFF, 0xFEFF, 2), (0xFFF9, 0xFFFB, 2), (0x101FD, 0x101FD, 1), (0x102E0, 0x102E0, 1), (0x10376, 0x1037A, 1),
  (0x10A01, 0x10A03, 1), (0x10A05, 0x10A06, 1), (0x10A0C, 0x10A0F, 1), (0x10A38, 0x10A3A, 1), (0x10A3F, 0x10A3F, 1),
  (0x10AE5, 0x10AE6, 1), (0x10D24, 0x10D27, 1), (0x10EAB, 0x10EAC, 1), (0x10EFD, 0x10EFF, 1), (0x10F46, 0x10F50, 1),
  (0x10F82, 0x10F85, 1), (0x11001, 0x11001, 1), (0x11038, 0x11046, 1), (0x11070, 0x11070, 1), (0x11073, 0x11074, 1),
  (0x1107F, 0x11081, 1), (0x110B3, 0x110B6, 1), (0x110B9, 0x110BA, 1), (0x110C2, 0x110C2, 1), (0x11100, 0x11102, 1),
  (0x11127, 0x1112B, 1), (0x1112D, 0x11134, 1), (0x11173, 0x11173, 1), (0x11180, 0x11181, 1), (0x111B6, 0x111BE, 1),
  (0x111C9, 0x111CC, 1), (0x111CF, 0x111CF, 1), (0x1122F, 0x11231, 1), (0x11234, 0x11234, 1), (0x11236, 0x11237, 1),
  (0x1123E, 0x1123E, 1), (0x11241, 0x11241, 1), (0x112DF, 0x112DF, 1), (0x112E3, 0x112EA, 1), (0x11300, 0x11301, 1),
  (0x1133B, 0x1133C, 1), (0x11340, 0x11340, 1), (0x11366, 0x1136C, 1), (0x11370, 0x11374, 1), (0x11438, 0x1143F, 1),
  (0x11442, 0x11444, 1), (0x11446, 0x11446, 1), (0x1145E, 0x1145E, 1), (0x114B3, 0x114B8, 1), (0x114BA, 0x114BA, 1),
  (0x114BF, 0x114C0, 1), (0x114C2, 0x114C3, 1), (0x115B2, 0x115B5, 1), (0x115BC, 0x115BD, 1), (0x115BF, 0x115C0, 1),
  (0x115DC, 0x115DD, 1), (0x11633, 0x1163A, 1), (0x1163D, 0x1163D, 1), (0x1163F, 0x11640, 1), (0x116AB, 0x116AB, 1),
  (0x116AD, 0x116AD, 1), (0x116B0, 0x116B5, 1), (0x116B7, 0x116B7, 1), (0x1171D, 0x1171F, 1), (0x11722, 0x11725, 1),
  (0x11727, 0x1172B, 1), (0x1182F, 0x11837, 1), (0x11839, 0x1183A, 1), (0x1193B, 0x1193C, 1), (0x1193E, 0x1193E, 1),
  (0x11943, 0x11943, 1), (0x119D4, 0x119D7, 1), (0x119DA, 0x119DB, 1), (0x119E0, 0x119E0, 1), (0x11A01, 0x11A0A, 1),
  (0x11A33, 0x11A38, 1), (0x11A3B, 0x11A3E, 1), (0x11A47, 0x11A47, 1), (0x11A51, 0x11A56, 1), (0x11A59, 0x11A5B, 1),
  (0x11A8A, 0x11A96, 1), (0x11A98, 0x11A99, 1), (0x11C30, 0x11C36, 1), (0x11C38, 0x11C3D, 1), (0x11C3F, 0x11C3F, 1),
  (0x11C92, 0x11CA7, 1), (0x11CAA, 0x11CB0, 1), (0x11CB2, 0x11CB3, 1), (0x11CB5, 0x11CB6, 1), (0x11D31, 0x11D36, 1),
  (0x11D3A, 0x11D3A, 1), (0x11D3C, 0x11D3D, 1), (0x11D3F, 0x11D45, 1), (0x11D47, 0x11D47, 1), (0x11D90, 0x11D91, 1),
  (0x11D95, 0x11D95, 1), (0x11D97, 0x11D97, 1), (0x11EF3, 0x11EF4, 1), (0x11F00, 0x11F01, 1), (0x11F36, 0x11F3A, 1),
  (0x11F40, 0x11F40, 1), (0x11F42, 0x11F42, 1), (0x13430, 0x1343F, 2), (0x13440, 0x13440, 1), (0x13447, 0x13455, 1),
  (0x16AF0, 0x16AF4, 1), (0x16B30, 0x16B36, 1), (0x16F4F, 0x16F4F, 1), (0x16F8F, 0x16F92, 1), (0x16FE4, 0x16FE4, 1),
  (0x1BC9D, 0x1BC9E, 1), (0x1BCA0, 0x1BCA3, 2), (0x1CF00, 0x1CF2D, 1), (0x1CF30, 0x1CF46, 1), (0x1D167, 0x1D169, 1),
  (0x1D173, 0x1D17A, 2), (0x1D17B, 0x1D182, 1), (0x1D185, 0x1D18B, 1), (0x1D1AA, 0x1D1AD, 1), (0x1D242, 0x1D244, 1),
  (0x1DA00, 0x1DA36, 1), (0x1DA3B, 0x1DA6C, 1), (0x1DA75, 0x1DA75, 1), (0x1DA84, 0x1DA84, 1), (0x1DA9B, 0x1DA9F, 1),
  (0x1DAA1, 0x1DAAF, 1), (0x1E000, 0x1E006, 1), (0x1E008, 0x1E018, 1), (0x1E01B, 0x1E021, 1), (0x1E023, 0x1E024, 1),
  (0x1E026, 0x1E02A, 1), (0x1E08F, 0x1E08F, 1), (0x1E130, 0x1E136, 1), (0x1E2AE, 0x1E2AE, 1), (0x1E2EC, 0x1E2EF, 1),
  (0x1E4EC, 0x1E4EF, 1), (0x1E8D0, 0x1E8D6, 1), (0x1E944, 0x1E94A, 1), (0xE0001, 0xE0001, 2), (0xE0020, 0xE007F, 2),
  (0xE0100, 0xE01EF, 1)]

const WideRanges: array[120, (int32, int32)] = [
  (0x1100, 0x115F), (0x231A, 0x231B), (0x2329, 0x232A), (0x23E9, 0x23EC), (0x23F0, 0x23F0), (0x23F3, 0x23F3),
  (0x25FD, 0x25FE), (0x2614, 0x2615), (0x2648, 0x2653), (0x267F, 0x267F), (0x2693, 0x2693), (0x26A1, 0x26A1),
  (0x26AA, 0x26AB), (0x26BD, 0x26BE), (0x26C4, 0x26C5), (0x26CE, 0x26CE), (0x26D4, 0x26D4), (0x26EA, 0x26EA),
  (0x26F2, 0x26F3), (0x26F5, 0x26F5), (0x26FA, 0x26FA), (0x26FD, 0x26FD), (0x2705, 0x2705), (0x270A, 0x270B),
  (0x2728, 0x2728), (0x274C, 0x274C), (0x274E, 0x274E), (0x2753, 0x2755), (0x2757, 0x2757), (0x2795, 0x2797),
  (0x27B0, 0x27B0), (0x27BF, 0x27BF), (0x2B1B, 0x2B1C), (0x2B50, 0x2B50), (0x2B55, 0x2B55), (0x2E80, 0x2E99),
  (0x2E9B, 0x2EF3), (0x2F00, 0x2FD5), (0x2FF0, 0x303E), (0x3041, 0x3096), (0x3099, 0x30FF), (0x3105, 0x312F),
  (0x3131, 0x318E), (0x3190, 0x31E3), (0x31EF, 0x321E), (0x3220, 0x3247), (0x3250, 0x4DBF), (0x4E00, 0xA48C),
  (0xA490, 0xA4C6), (0xA960, 0xA97C), (0xAC00, 0xD7A3), (0xF900, 0xFAFF), (0xFE10, 0xFE19), (0xFE30, 0xFE52),
  (0xFE54, 0xFE66), (0xFE68, 0xFE6B), (0xFF01, 0xFF60), (0xFFE0, 0xFFE6), (0x16FE0, 0x16FE4), (0x16FF0, 0x16FF1),
  (0x17000, 0x187F7), (0x18800, 0x18CD5), (0x18D00, 0x18D08), (0x1AFF0, 0x1AFF3), (0x1AFF5, 0x1AFFB),
  (0x1AFFD, 0x1AFFE), (0x1B000, 0x1B122), (0x1B132, 0x1B132), (0x1B150, 0x1B152), (0x1B155, 0x1B155),
  (0x1B164, 0x1B167), (0x1B170, 0x1B2FB), (0x1F004, 0x1F004), (0x1F0CF, 0x1F0CF), (0x1F18E, 0x1F18E),
  (0x1F191, 0x1F19A), (0x1F200, 0x1F202), (0x1F210, 0x1F23B), (0x1F240, 0x1F248), (0x1F250, 0x1F251),
  (0x1F260, 0x1F265), (0x1F300, 0x1F320), (0x1F32D, 0x1F335), (0x1F337, 0x1F37C), (0x1F37E, 0x1F393),
  (0x1F3A0, 0x1F3CA), (0x1F3CF, 0x1F3D3), (0x1F3E0, 0x1F3F0), (0x1F3F4, 0x1F3F4), (0x1F3F8, 0x1F43E),
  (0x1F440, 0x1F440), (0x1F442, 0x1F4FC), (0x1F4FF, 0x1F53D), (0x1F54B, 0x1F54E), (0x1F550, 0x1F567),
  (0x1F57A, 0x1F57A), (0x1F595, 0x1F596), (0x1F5A4, 0x1F5A4), (0x1F5FB, 0x1F64F), (0x1F680, 0x1F6C5),
  (0x1F6CC, 0x1F6CC), (0x1F6D0, 0x1F6D2), (0x1F6D5, 0x1F6D7), (0x1F6DC, 0x1F6DF), (0x1F6EB, 0x1F6EC),
  (0x1F6F4, 0x1F6FC), (0x1F7E0, 0x1F7EB), (0x1F7F0, 0x1F7F0), (0x1F90C, 0x1F93A), (0x1F93C, 0x1F945),
  (0x1F947, 0x1F9FF), (0x1FA70, 0x1FA7C), (0x1FA80, 0x1FA88), (0x1FA90, 0x1FABD), (0x1FABF, 0x1FAC5),
  (0x1FACE, 0x1FADB), (0x1FAE0, 0x1FAE8), (0x1FAF0, 0x1FAF8), (0x20000, 0x2FFFD), (0x30000, 0x3FFFD)]

func zeroKind(cp: int): int8 =
  ## 0, or what kind of zero-width character `cp` is: 1 a mark (joins the character before), 2 a format character
  var lo = 0
  var hi = int(ZeroRanges.high)
  while lo <= hi:
    let mid = (lo + hi) shr 1
    if cp < ZeroRanges[mid][0]: hi = mid - 1
    elif cp > ZeroRanges[mid][1]: lo = mid + 1
    else: return ZeroRanges[mid][2]
  0

func isWide(cp: int): bool =
  var lo = 0
  var hi = int(WideRanges.high)
  while lo <= hi:
    let mid = (lo + hi) shr 1
    if cp < WideRanges[mid][0]: hi = mid - 1
    elif cp > WideRanges[mid][1]: lo = mid + 1
    else: return true
  false

func runeWidth*(cp: int): int =
  if cp < 0x300: return 1
  if cp >= 0x4E00 and cp <= 0x9FFF: return 2          # (CJK ideographs: the common case)
  if zeroKind(cp) != 0: return 0
  if isWide(cp): 2 else: 1

# ── characters of several code points: a letter with its accents (e + ◌́), and — when the terminal joins them
#    ("graphemes": DEC mode 2027, kitty, WezTerm, Ghostty) — an emoji with a skin tone, a family joined by ZWJ, a flag,
#    a keycap, an emoji chosen by VS16. Each is one character: the cursor steps over it at once, a Backspace takes it
#    all, and it is drawn whole ──

var graphemes* = false         # the terminal joins grapheme clusters (else: only marks join, as in every terminal)

func isPictographic*(cp: int): bool =
  ## an emoji or pictograph: what a ZWJ joins to the one before, what a skin tone or VS16 follows
  (cp >= 0x1F000 and cp <= 0x1FAFF) or (cp >= 0x2190 and cp <= 0x2BFF) or
    cp in [0xA9, 0xAE, 0x203C, 0x2049, 0x2122, 0x2139, 0x3030, 0x303D, 0x3297, 0x3299]

func isRegional(cp: int): bool {.inline.} = cp >= 0x1F1E6 and cp <= 0x1F1FF

func unitAt*(s: string, i: int, full: bool): (int, int) =
  ## (end byte, columns) of the character that starts at byte i: its base and what joins it. `full`: grapheme
  ## clusters as a terminal that joins them shows them; else marks only (what every terminal does)
  let (cp, n) = runeAt(s, i)
  var w = runeWidth(cp)
  var j = i + n
  let pict = isPictographic(cp)
  if full and isRegional(cp) and j < s.len:
    let (c2, n2) = runeAt(s, j)
    if isRegional(c2): return (j + n2, 2)            # a flag: two regional indicators
  var vs16, vs15 = false
  while j < s.len and s[j].uint8 >= 0x80:
    let (c2, n2) = runeAt(s, j)
    if c2 == 0xFE0F or c2 == 0xFE0E:
      if not full: break                             # (emoji or text presentation: only where clusters are joined)
      if c2 == 0xFE0F: vs16 = true else: vs15 = true
      j += n2
    elif c2 >= 0x300 and zeroKind(c2) == 1:
      j += n2                                        # a mark
    elif full and c2 == 0x200D:
      j += n2                                        # ZWJ: and the pictograph after it
      if pict and j < s.len:
        let (c3, n3) = runeAt(s, j)
        if isPictographic(c3): j += n3
    elif full and pict and c2 >= 0x1F3FB and c2 <= 0x1F3FF: j += n2         # a skin tone
    elif full and c2 >= 0xE0020 and c2 <= 0xE007F: j += n2                 # tags (a region's flag)
    else: break
  if vs16 and w < 2: w = 2
  elif vs15 and pict and w == 2: w = 1
  (j, w)

proc charWidthAt*(s: string, i: int, vc: int): (int, int) {.inline.} =
  ## (display width, byte length) of the char at byte i when it starts at visual column vc
  let c = s[i]
  if c == '\t': return (tabW - (vc mod tabW), 1)
  if c.uint8 < 0x80 and (i + 1 >= s.len or s[i + 1].uint8 < 0x80): return (1, 1)
  let (e, w) = unitAt(s, i, graphemes)
  (w, e - i)

func nextCluster*(s: string, i: int): int =
  ## where the character after the one at byte i starts (a grapheme cluster: an emoji sequence is one)
  if i >= s.len: return s.len
  if s[i].uint8 < 0x80 and (i + 1 >= s.len or s[i + 1].uint8 < 0x80): return i + 1
  max(i + 1, unitAt(s, i, true)[0])

func prevCluster*(s: string, i: int): int =
  ## where the character before byte i starts
  if i <= 0: return 0
  let i = min(i, s.len)
  if s[i - 1].uint8 < 0x80: return i - 1               # (ASCII never joins the character before it)
  var p = i - 1
  while p > 0 and i - p < 160 and s[p].uint8 >= 0x80: dec p
  while p < i and (s[p].uint8 and 0xC0) == 0x80: inc p  # (a rune's first byte)
  var a = p
  while true:
    let e = nextCluster(s, a)
    if e >= i or e <= a: return a
    a = e

# ── a cell holds one code point; a character of several (an accent, a ZWJ emoji) is kept in a pool and the cell
#    holds its number: PoolBase + its place ──

const PoolBase* = 0x110000'u32

var
  cellPool*: seq[string]
  cellPoolW: seq[int8]
  cellPoolIds: Table[string, uint32]

func visibleCh*(ch: int): int {.inline.} =
  ## a control character never goes to the terminal as it is — a file, a program's output or an AI's answer could
  ## otherwise move the cursor, set the window's title or the clipboard: its picture instead (␀ … ␟, ␡), and for C1
  ## (U+0080 … U+009F, which some terminals obey as escape sequences) �
  if ch < 32: 0x2400 + ch
  elif ch == 127: 0x2421
  elif ch >= 0x80 and ch < 0xA0: 0xFFFD
  else: ch

proc cellOf*(s: string, i, n: int): uint32 =
  ## the cell for the character of `n` bytes at byte i: its code point — or its number in the pool
  let (cp, rn) = runeAt(s, i)
  if rn >= n: return cp.uint32
  var t = s[i ..< i + n]
  var ctl = false
  for k, c in t:
    if c < ' ' or c == '\x7f' or (c == '\xC2' and k + 1 < t.len and t[k + 1] in {'\x80' .. '\x9F'}): ctl = true
  if ctl:
    # (a control character inside a cluster: its picture too)
    var u = ""
    var k = 0
    while k < t.len:
      let (c2, l2) = runeAt(t, k)
      let v = visibleCh(c2)
      if v == c2: u.add t[k ..< k + l2] else: u.addUtf8(v)
      k += l2
    t = u
  result = cellPoolIds.getOrDefault(t, 0'u32)
  if result == 0:
    result = PoolBase + cellPool.len.uint32
    cellPool.add t
    cellPoolW.add unitAt(t, 0, graphemes)[1].int8
    cellPoolIds[t] = result

proc cellWidth*(ch: uint32): int {.inline.} =
  if ch < PoolBase: runeWidth(ch.int)
  elif int(ch - PoolBase) < cellPoolW.len: cellPoolW[int(ch - PoolBase)]
  else: 1

proc resetCellPool*() =
  ## (the terminal's way of joining characters changed, or the pool grew big: the screen is drawn again from scratch)
  cellPool.setLen(0)
  cellPoolW.setLen(0)
  cellPoolIds.clear()

func printable8*(s: string, i: int): bool {.inline.} =
  ## are the 8 bytes at i all plain printable ASCII (' ' .. '~'), one column each? (8 at a time: long lines)
  var w: uint64
  copyMem(addr w, unsafeAddr s[i], 8)
  const ones = 0x0101010101010101'u64
  const high = 0x8080808080808080'u64
  if (w and high) != 0: return false                                  # (UTF-8)
  if ((w - 0x20'u64 * ones) and not w and high) != 0: return false     # (a control character or a tab)
  let d = w xor (0x7F'u64 * ones)
  ((d - ones) and not d and high) == 0                                 # (DEL)

proc visColFrom*(s: string, col, start, startVc: int): int =
  ## visColOf from a known point: byte `start` at visual column `startVc`
  var i = start
  result = startVc
  let e = min(col, s.len)
  while i < e:
    if i + 8 <= e and printable8(s, i) and (i + 8 >= s.len or s[i + 8].uint8 < 0x80):
      result += 8
      i += 8
      continue
    if s[i] in {' ' .. '~'} and (i + 1 >= s.len or s[i + 1].uint8 < 0x80):   # plain ASCII: one column (the common case)
      inc result
      inc i
      continue
    let (w, n) = charWidthAt(s, i, result)
    result += w
    i += n

proc visColOf*(s: string, col: int): int = visColFrom(s, col, 0, 0)

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
