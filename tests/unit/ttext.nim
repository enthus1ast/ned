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
