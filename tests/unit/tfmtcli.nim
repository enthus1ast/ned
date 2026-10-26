## nedfmt's own parts: its unified diff (applied back, it gives the formatted text — random texts too), nph's
## .nph.toml read, the kinds of file, the C in emits, and the command run over a scratch folder.
## Run: nim r tests/unit/tfmtcli.nim

import std/[os, strutils, unittest, random]
import ../../src/ned/format/fmtcli

proc applyUnified(a, patch: string): string =
  ## a unified diff applied to `a` (what `patch` would do), strict: every context and removed line must match
  let la = a.split('\n')
  var res: seq[string]
  var at = 0                   # the next line of `a` not yet copied
  let pl = patch.split('\n')
  var i = 0
  while i < pl.len:
    let l = pl[i]
    if l.startsWith("@@ -"):
      let nums = l[4 .. ^1].split(' ')
      let aPart = nums[0].split(',')
      var aStart = parseInt(aPart[0])
      let aLen = parseInt(aPart[1])
      if aLen > 0: dec aStart            # (1-based, or the line before when the hunk removes nothing)
      while at < aStart:
        res.add la[at]
        inc at
      inc i
      while i < pl.len and pl[i].len > 0 and pl[i][0] in {' ', '-', '+'}:
        let t = pl[i]
        case t[0]
        of ' ':
          doAssert la[at] == t[1 .. ^1], "context differs at " & $at
          res.add la[at]
          inc at
        of '-':
          doAssert la[at] == t[1 .. ^1], "removed line differs at " & $at
          inc at
        else: res.add t[1 .. ^1]
        inc i
    else: inc i
  while at < la.len:
    res.add la[at]
    inc at
  res.join("\n")

suite "the diff":
  test "same texts: nothing":
    check unifiedDiff("a\nb\n", "a\nb\n", "x", "y") == ""

  test "a change in the middle, with context":
    let d = unifiedDiff("1\n2\n3\n4\n5\n6\n7\n8\n9\n", "1\n2\n3\n4\nfive\n6\n7\n8\n9\n", "x", "x (formatted)")
    check d.startsWith("--- x\n+++ x (formatted)\n@@ -2,7 +2,7 @@\n")
    check "-5\n+five\n" in d

  test "random texts: the diff applied gives the other text":
    var r = initRand(68)
    for round in 0 ..< 400:
      var a, b: seq[string]
      let n = r.rand(0 .. 40)
      for i in 0 ..< n: a.add $r.rand(0 .. 6)
      b = a
      for k in 0 ..< r.rand(0 .. 8):
        case r.rand(0 .. 2)
        of 0:
          if b.len > 0: b.delete(r.rand(0 .. b.high))
        of 1: b.insert($r.rand(0 .. 9), r.rand(0 .. b.len))
        else:
          if b.len > 0: b[r.rand(0 .. b.high)] = "x" & $r.rand(0 .. 3)
      let ta = a.join("\n")
      let tb = b.join("\n")
      let d = unifiedDiff(ta, tb, "a", "b")
      if ta == tb: check d == ""
      else:
        checkpoint "a=" & ta.escape & " b=" & tb.escape & "\n" & d
        check applyUnified(ta, d) == tb

suite "nph's settings file":
  test "exclude, extend-exclude over lines, include with \\., color":
    let p = getTempDir() / "tfmtcli.nph.toml"
    writeFile(p, "# nph\nexclude = [\"build\", 'dist']\nextend-exclude = [\n  \"tests/before\",  # old\n  \"vendor\",\n]\n" &
                 "include = [\"\\.nim$\"]\ncolor = false\n")
    let (ex, ext, inc, col) = readNphToml(p)
    check ex == @["build", "dist"]
    check ext == @["tests/before", "vendor"]
    check inc == @["\\.nim$"]
    check col == 0
    removeFile(p)

suite "kinds of file":
  test "which formatter":
    check fmtKindOf("a/b.nim") == "nim"
    check fmtKindOf("x.nimble") == "nim"
    check fmtKindOf("x.JSON") == "json"
    check fmtKindOf("README.md") == "markdown"
    check fmtKindOf("s.scss") == "scss"
    check fmtKindOf("x.h") == "c"
    check fmtKindOf("x.yml") == "yaml"
    check fmtKindOf("Cargo.toml") == "toml"
    check fmtKindOf("x.py") == ""

  test "the C in an emit formatted with the Nim, by ned's C formatter":
    let src = "{.emit: \"\"\"\nint f(int a){\nreturn a+1;\n}\n\"\"\".}\n"
    let (res, n, by) = formatEmitC(src, "", false, nil)
    check n == 1
    check by == "ned's C formatter"
    check "int f(int a) {\n  return a + 1;\n}" in res

suite "the command":
  let dir = getTempDir() / "tfmtcli-" & $getCurrentProcessId()
  setup:
    removeDir(dir)
    createDir(dir / "sub")
    createDir(dir / "nimcache")
    writeFile(dir / "a.nim", "proc  foo(a:int):int=\n  a+1\n")
    writeFile(dir / "sub" / "b.json", "{\"a\":1}")
    writeFile(dir / "nimcache" / "c.nim", "let  x=1\n")
  teardown:
    removeDir(dir)

  test "--check says which would change and changes nothing; nimcache is left out":
    let before = readFile(dir / "a.nim")
    check fmtCliMain(@["--check", "--quiet", dir], "nedfmt") == 1
    check readFile(dir / "a.nim") == before

  test "a folder formatted in place, then --check is happy":
    check fmtCliMain(@["--quiet", dir], "nedfmt") == 0
    check readFile(dir / "a.nim") == "proc foo(a: int): int =\n  a + 1\n"
    check readFile(dir / "sub" / "b.json") == "{\n  \"a\": 1\n}\n"
    check readFile(dir / "nimcache" / "c.nim") == "let  x=1\n"
    check fmtCliMain(@["--check", "--quiet", dir], "nedfmt") == 0

  test "--outDir leaves the originals":
    let o = dir & "-out"
    check fmtCliMain(@["--quiet", "--outDir:" & o, dir / "a.nim"], "nedfmt") == 0
    check readFile(dir / "a.nim") == "proc  foo(a:int):int=\n  a+1\n"
    var found = ""
    for p in walkDirRec(o):
      if p.endsWith("a.nim"): found = readFile(p)
    check found == "proc foo(a: int): int =\n  a + 1\n"
    removeDir(o)

  test "--extend-exclude and --include":
    check fmtCliMain(@["--check", "--quiet", "--extend-exclude:a\\.nim", dir], "nedfmt") == 1   # (b.json)
    check fmtCliMain(@["--check", "--quiet", "--extend-exclude:a\\.nim", "--include:\\.nim$", dir], "nedfmt") == 0

  test "wrong arguments":
    check fmtCliMain(@["--nope", dir], "nedfmt") == 3
    check fmtCliMain(@["--out:x", "--outDir:y", dir / "a.nim"], "nedfmt") == 3
    check fmtCliMain(@["--diff", "--out:x", dir / "a.nim"], "nedfmt") == 3
    check fmtCliMain(@[dir / "missing.nim"], "nedfmt") == 2

  test "a file the formatter is not sure of is left alone (exit 2)":
    writeFile(dir / "bad.nim", "proc  f() =\n  echo \"\"\"unclosed\n")
    let before = readFile(dir / "bad.nim")
    check fmtCliMain(@["--quiet", dir / "bad.nim"], "nedfmt") == 2
    check readFile(dir / "bad.nim") == before

suite "Nim's parser as a second check":
  test "a result the checker reads differently is left alone":
    let fake = getTempDir() / "tfmtcli-fakecheck.sh"
    writeFile(fake, "#!/bin/sh\ncat >/dev/null\necho 'different 2 2: x'\nexit 1\n")
    setFilePermissions(fake, {fpUserRead, fpUserWrite, fpUserExec})
    fmtVerifyExe = fake
    let (r, err) = fmtTextOf("nim", "let  x=1\n", "x.nim")
    fmtVerifyExe = ""
    removeFile(fake)
    check r == "let  x=1\n"
    check "Nim's parser reads the result differently (line 2)" in err

  test "the checker's build: its program named as the system names it, no `rm` (Windows has none), why it failed":
    let exe = astCheckerPath()
    if exe.len > 0:
      check exe.endsWith(ExeExt)
      let cmd = astCheckerBuildCmd()
      check "rm " notin cmd and "&&" notin cmd
      check astCheckerCacheDir() in cmd
    check astCheckerFailure("Hint: x\n/tmp/a.nim(3, 1) Error: cannot open file: compiler/parser\n", 1) ==
          "Error: cannot open file: compiler/parser"
    check astCheckerFailure("something\nthe last line\n\n", 1) == "the last line"
    check astCheckerFailure("", 3) == "nim stopped with exit status 3 and wrote nothing"

  test "the real checker (when this machine has the compiler sources and it is built)":
    let exe = astCheckerPath()
    if exe.len > 0 and fileExists(exe):
      check astSame(exe, "echo a - 1\n", "echo a  -  1 # c\n")[0] == 0
      check astSame(exe, "echo a - 1\n", "echo a -1\n")[0] == 1
      check astSame(exe, "proc (\n", "x\n")[0] == 2
    else: skip()
