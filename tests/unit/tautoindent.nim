## Indentation as you type, for Nim (editor.autoDedent): which line a closing bracket typed alone, or a branch
## word typed at a line's start, takes its indentation from. Run: nim r tests/unit/tautoindent.nim

import std/[strutils, unittest]
import ../../src/ned/editor/autoindent

# the text as a list of lines
proc ls(s: string): seq[string] = s.split('\n')

suite "a branch word typed at the start of a line":
  test "else: to its if, past a deeper block":
    let t = ls("proc f() =\n  if a:\n    for x in y:\n      g(x)\n    else")
    check aiBranchLine(t, 4, "else") == 1
    check aiLeading(t[aiBranchLine(t, 4, "else")]) == 2

  test "else: the nearest if at a lower indentation":
    let t = ls("if a:\n  if b:\n    f()\n    else")
    check aiBranchLine(t, 3, "else") == 1
    let u = ls("if a:\n  if b:\n    f()\n  else")
    check aiBranchLine(u, 3, "else") == 0

  test "of: to the case, or to an of before it at its column":
    let t = ls("case k\nof 1:\n  f()\n  of")
    check aiBranchLine(t, 3, "of") == 1
    let u = ls("case k\n  of 1:\n    f()\n    of")
    check aiLeading(u[aiBranchLine(u, 3, "of")]) == 2

  test "elif after when, except and finally after try":
    check aiBranchLine(ls("when defined(js):\n  f()\n  elif"), 2, "elif") == 0
    check aiBranchLine(ls("try:\n  f()\n  except"), 2, "except") == 0
    check aiBranchLine(ls("try:\n  f()\nexcept:\n  g()\n  finally"), 4, "finally") == 2

  test "nothing to go back to: -1":
    check aiBranchLine(ls("proc f() =\n  g()\n  else"), 2, "else") == -1          # (a routine ends the search)
    check aiBranchLine(ls("else"), 0, "else") == -1
    check aiBranchLine(ls("if a:\n  f()\nelse"), 2, "else") == -1                 # (at the margin already)
    check aiBranchLine(ls("if a:\n  f()\n  other"), 2, "other") == -1

suite "a closing bracket typed alone on its line":
  test "to the line that opened it":
    let t = ls("let x = foo(\n  a,\n  b\n  ")
    check aiCloserLine(t, 3, ')') == 0
    let u = ls("proc f() =\n  let s = @[\n    1, 2,\n    3\n    ")
    check aiCloserLine(u, 4, ']') == 1

  test "brackets closed on the way, in strings and in comments do not count":
    let t = ls("call(\n  g(1), h[2],\n  \"(\", ')', # (\n  ")
    check aiCloserLine(t, 3, ')') == 0
    check aiCloserLine(ls("let t = {\n  \"a\": {1: 2},\n  "), 2, '}') == 0

  test "no bracket to close: -1":
    check aiCloserLine(ls("f(x)\n  "), 1, ')') == -1
    check aiCloserLine(ls("a\n  "), 1, '>') == -1
