# ned's text measures: the column a byte is shown at (8 bytes at a time on plain ASCII) — the same as counting
# character by character, with tabs, wide and zero-width characters, control characters and DEL mixed in

import std/[random, strutils, unittest]
import ../../src/ned/core/text

proc oneByOne(s: string, col: int): int =
  var i = 0
  while i < col and i < s.len:
    let (w, n) = charWidthAt(s, i, result)
    result += w
    i += n

suite "visual columns":
  test "visColOf: the same as one character at a time (20 000 random lines)":
    randomize(7)
    let pieces = ["a", "b", " ", "~", "\t", "é", "中", "\x7f", "\x01", "😀", "xyz", "[{", "\x1f", "}", "́"]
    var bad = 0
    for t in 0 ..< 20000:
      var s = ""
      for k in 0 ..< rand(0 .. 60): s.add pieces[rand(pieces.high)]
      for col in 0 .. s.len + 2:
        if visColOf(s, col) != oneByOne(s, col): inc bad
    check bad == 0

  test "visColFrom: from a known point gives what counting from the start gives":
    let s = "ab\tcd中ef\tgh" & "x".repeat(100) & "\t!"
    for start in 0 ..< s.len:
      if (s[start].uint8 and 0xC0) == 0x80: continue        # (not inside a character)
      for col in start .. s.len:
        check visColFrom(s, col, start, visColOf(s, start)) == visColOf(s, col)

suite "widths and characters of several code points (6.13)":
  test "widths from Unicode 15.1: emoji shown as emoji take two columns, marks and format characters none":
    for cp in [0x2705, 0x2B50, 0x231A, 0x1FAE0, 0x1F600, 0x4E2D, 0xD55C, 0x1F3FD, 0xFF21]: check runeWidth(cp) == 2
    for cp in [0x301, 0x200D, 0xFE0F, 0x0E31, 0x20E3, 0x200B, 0xFEFF, 0x1160]: check runeWidth(cp) == 0
    for cp in [ord('a'), 0xAD, 0x1F1F4, 0x2764, 0x00E9, 0x0600]: check runeWidth(cp) == 1

  test "without joined clusters (most terminals): an accent joins its letter, an emoji sequence stays apart":
    graphemes = false
    let e = "é"                                   # e + combining acute
    check charWidthAt(e, 0, 0) == (1, e.len)
    let thumb = "👍🏽"                                   # thumbs up, medium skin tone: two emoji here
    check charWidthAt(thumb, 0, 0) == (2, 4)
    check strWidth(thumb) == 4
    check strWidth("❤️") == 1                           # (VS16 is left out: the terminal shows the text heart)
    check strWidth("👨‍👩‍👧") == 6

  test "with joined clusters (mode 2027, kitty, WezTerm, Ghostty): one character, two columns":
    graphemes = true
    defer: graphemes = false
    for s in ["👍🏽", "👨‍👩‍👧", "🇴🇲", "1️⃣", "❤️", "🏴󠁧󠁢󠁳󠁣󠁴󠁿"]:
      check charWidthAt(s, 0, 0) == (2, s.len)
      check strWidth(s) == 2
    check strWidth("⌚︎") == 1                           # (VS15: the text form)
    check strWidth("🇴🇲🇸🇦") == 4                        # (two flags: the indicators pair up)
    check strWidth("a‍b") == 2                     # (a ZWJ between letters joins nothing)

  test "the cursor steps over a whole character, either way":
    let s = "a👨‍👩‍👧b🇴🇲🇸🇦éz"
    var starts: seq[int]
    var i = 0
    while i < s.len:
      starts.add i
      i = nextCluster(s, i)
    check starts.len == 7                               # a · family · b · 🇴🇲 · 🇸🇦 · é · z
    var back: seq[int]
    var j = s.len
    while j > 0:
      j = prevCluster(s, j)
      back.add j
    check back.len == 7
    for k in 0 ..< 7: check back[6 - k] == starts[k]

  test "a character of several code points is one cell, kept once in the pool":
    graphemes = true
    defer:
      graphemes = false
      resetCellPool()
    let s = "x👍🏽y👍🏽"
    let a = cellOf(s, 1, 8)
    let b = cellOf(s, 10, 8)
    check a == b and a >= PoolBase
    check cellPool[int(a - PoolBase)] == "👍🏽"
    check cellWidth(a) == 2
    check cellOf(s, 0, 1) == uint32(ord('x'))

  test "visColOf and colAtVis agree with one character at a time, emoji sequences mixed in (both ways of joining)":
    randomize(13)
    let pieces = ["a", " ", "\t", "é", "é", "中", "😀", "👍🏽", "👨‍👩‍👧", "🇴🇲", "1️⃣", "❤️", "‍", "️", "xy"]
    for g in [false, true]:
      graphemes = g
      var bad = 0
      for t in 0 ..< 5000:
        var s = ""
        for k in 0 ..< rand(0 .. 30): s.add pieces[rand(pieces.high)]
        for col in 0 .. s.len + 1:
          if visColOf(s, col) != oneByOne(s, col): inc bad
        var i = 0
        while i < s.len:
          let vc = visColOf(s, i)
          if charWidthAt(s, i, vc)[0] > 0 and colAtVis(s, vc) != i: inc bad
          i += charWidthAt(s, i, vc)[1]
      check bad == 0
    graphemes = false

suite "control characters never reach the terminal (6.32.2)":
  test "C0, DEL and C1 (U+0080 … U+009F) become their pictures; the rest stays":
    check visibleCh(0x1b) == 0x241B
    check visibleCh(0x07) == 0x2407
    check visibleCh(0x7f) == 0x2421
    check visibleCh(0x9b) == 0xFFFD          # (an 8-bit CSI: some terminals obey it)
    check visibleCh(0x85) == 0xFFFD
    check visibleCh(0xA0) == 0xA0
    check visibleCh(ord('a')) == ord('a')
    check visibleCh(0x1F600) == 0x1F600
  test "a cluster with a control character in it: kept in the pool with its picture":
    graphemes = true
    let s = "é\x1b[31m"
    let c = cellOf(s, 0, 2 + 2)              # (e, the accent — and nothing of the escape: a cluster of two)
    check c >= PoolBase
    let bad = "á\xC2\x9B"              # (a cluster that ends in an 8-bit CSI, as a broken file could hold)
    let c2 = cellOf(bad, 0, bad.len)
    check c2 >= PoolBase
    check "\xC2\x9B" notin cellPool[int(c2 - PoolBase)]
    check "\xEF\xBF\xBD" in cellPool[int(c2 - PoolBase)]
    graphemes = false
