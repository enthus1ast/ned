## The regular expressions of Find and Replace (a small backtracking VM): syntax, captures, case, limits.
## Run: nim r tests/unit/tregex.nim

import std/unittest
import ../../src/ned/editor/regex

proc find(pat, s: string, icase = false): (bool, seq[int]) =
  ## compiles the pattern (the test fails if its syntax is wrong) and searches the text from its start: whether it
  ## matched, and the positions of the capture groups
  let re = compileRegex(pat, icase)
  check re.err.len == 0
  var caps: seq[int]
  let ok = reSearch(re, s, 0, caps)
  (ok, caps)

suite "regular expressions":
  test "literals, classes, repetition":
    check find("a[0-9]+b", "xx a123b yy")[0]
    check not find("a[0-9]+b", "xx ab yy")[0]
    check find(r"\d{3}-\d{4}", "call 555-1234 now")[0]

  test "alternatives and groups, with where they matched":
    let (ok, caps) = find("(foo|bar)baz", "xbarbaz")
    check ok
    check caps[0] == 1 and caps[1] == 7       # the whole match
    check caps[2] == 1 and caps[3] == 4       # group 1: "bar"

  test "anchors and word boundaries":
    check find(r"^proc\b", "proc x() =")[0]
    check not find(r"^proc\b", "  procedure")[0]

  test "case-insensitive":
    check find("hello", "HeLLo world", icase = true)[0]
    check not find("hello", "HeLLo world")[0]

  test "a pattern that does not compile says why":
    let re = compileRegex("a(b")
    check re.err.len > 0
