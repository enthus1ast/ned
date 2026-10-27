## The Nim tour's lessons as ned has them (src/ned/editor/tourlessons.nim): every lesson read in, numbered in order,
## with a title, an exercise and an answer to fold; the check's ✓; the progress kept between runs.
## (tests/tour/check.py runs every cell of every lesson with nim.)
## Run: nim r tests/unit/ttour.nim

import std/[strutils, unittest]
import ../../src/ned/editor/tourlessons

suite "the lessons":
  test "each is read in, numbered in order, with a title":
    check TourLessons.len >= 12
    for i, (file, text) in TourLessons:
      check file == "lesson" & align($(i + 1), 2, '0') & "_" & file[9 .. ^5] & ".nim"
      check text.startsWith("# Nim tour · " & $(i + 1) & " of " & $TourLessons.len & " · ")
      check tourTitle(text).len > 0
      check "# notebook: compiled" in text.split("# %%", 1)[0]

  test "indented by two spaces (what ned guesses for the tab: Tab then indents by two)":
    for (file, text) in TourLessons:
      for l in text.splitLines:
        var n = 0
        while n < l.len and l[n] == ' ': inc n
        if n mod 2 != 0: checkpoint file & ": " & l
        check n mod 2 == 0

  test "each has cells and one exercise, last, with its answer to fold":
    for (file, text) in TourLessons:
      let lines = text.splitLines
      let titles = tourCellTitles(text)
      check titles.len >= 4
      check titles[^1].startsWith("Exercise: ")
      let ex = tourExerciseLine(lines)
      check ex > 0
      let (a, e) = tourAnswerFold(lines)
      check a > ex
      check e > a
      check lines[a] == "# Answer:"
      for k in a + 1 .. e: check lines[k].startsWith("  #")
      var checks = 0
      for k in ex .. a:
        if lines[k] == "# Check:": inc checks
      check checks == 1

  test "a title":
    check tourTitle("# Nim tour · 3 of 16 · Choices and loops\n# notebook: compiled") == "Choices and loops"
    check tourCellTitles("x\n# %% One\necho 1\n# %%\n# %% Exercise: two\n") == @["One", "Exercise: two"]

  test "an answer: the indented comment lines under # Answer:":
    check tourAnswerFold(["# %% Exercise: x", "echo 1", "# Check:", "echo 2", "# Answer:", "  # a", "  #",
                          "  # b", ""]) == (4, 7)
    check tourAnswerFold(["echo 1", "# Answer:", "echo 2"]) == (-1, -1)
    check tourAnswerFold(["echo 1"]) == (-1, -1)

suite "the check's ✓":
  test "✓ and nothing that says not yet":
    check tourPassed(["✓ well done"])
    check tourPassed(["42", "  ✓ isPalindrome works"])
    check not tourPassed(["not yet: 0 h"])
    check not tourPassed(["✓ a", "not yet: b"])
    check not tourPassed([])
    check not tourPassed(["it says ✓ in the middle"])

suite "the progress":
  test "kept as JSON and read back":
    var p = TourProgress(at: 4, done: @[0, 1, 3])
    p.tourSetMade("lesson01_hello.nim", tourHash("a"))
    p.tourSetMade("lesson02_values.nim", tourHash("b"))
    p.tourSetMade("lesson01_hello.nim", tourHash("c"))
    let q = tourProgressFrom(tourProgressJson(p))
    check q.at == 4
    check q.done == @[0, 1, 3]
    check q.tourMadeFrom("lesson01_hello.nim") == tourHash("c")
    check q.tourMadeFrom("lesson02_values.nim") == tourHash("b")
    check q.tourMadeFrom("lesson03_control.nim") == ""

  test "a broken or missing file is a fresh start":
    check tourProgressFrom("").at == 0
    check tourProgressFrom("{not json").done.len == 0
    check tourProgressFrom("[1, 2]").made.len == 0
    let q = tourProgressFrom("""{"at": 2, "done": [1, "x", 1], "made": {"a.nim": 3, "b.nim": "F00"}}""")
    check q.at == 2
    check q.done == @[1]
    check q.made == @[("b.nim", "F00")]

  test "a lesson's fingerprint":
    check tourHash("x") == tourHash("x")
    check tourHash("x") != tourHash("y")
    check tourHash(TourLessons[0][1]).len == 16
