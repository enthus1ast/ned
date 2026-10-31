## What a file sees, held in shared layers (6.33): every name is found as it was when each scope held its own copy —
## a lookup gives what going through all the scope's names gives, in the same order — and two files that import the
## same module share what it brings. Run: nim r tests/unit/tscopes.nim

import std/[os, strutils, unittest, algorithm, sets, times, tables]
import ../../src/ned/nim/index

proc nimLib(): string =
  ## the folder of Nim's standard library next to the nim on PATH (the test stops when there is none)
  var exe = findExe("nim")
  doAssert exe.len > 0, "put nim on PATH"
  try:
    if symlinkExists(exe): exe = expandFilename(exe)
  except OSError: discard
  for cand in [exe.parentDir.parentDir / "lib", "/usr/lib/nim", "/usr/lib/nim/lib"]:
    if fileExists(cand / "system.nim"): return cand
  doAssert false, "no standard library found"

nxInitDefines()
let lib = nimLib()
nxSetToolchain(lib, @[], @[])
let dir = getTempDir() / ("ned_tscopes_" & $getCurrentProcessId())
createDir(dir)

suite "what a file sees, in shared layers":
  test "every name of 60 library modules' scopes: a lookup finds what the whole list has, in its order":
    var files: seq[string]
    for f in walkDirRec(lib / "pure"):
      if f.endsWith(".nim"): files.add f
    files.sort()
    var checked = 0
    for p in files[0 ..< min(60, files.len)]:
      let f = nxLoad(p)
      if f == nil: continue
      let sc = nxScope(f)
      var seen: HashSet[string]
      var names: seq[string]
      for r in sc.refs:
        let nm = r.file.syms[r.idx].name
        if not seen.containsOrIncl(nxNorm(nm)): names.add nm
      for nm in names[0 ..< min(names.len, 400)]:
        var want: seq[(string, int32)]
        for r in sc.refs:
          if nxNorm(r.file.syms[r.idx].name) == nxNorm(nm): want.add (r.file.path, r.idx)
        var got: seq[(string, int32)]
        for r in nxLookup(sc, nm): got.add (r.file.path, r.idx)
        check got == want
        inc checked
    check checked > 5000

  test "two files importing the same module share what it brings; an edit inside a body keeps it":
    writeFile(dir / "lib1.nim", "proc helper*(x: int): int =\n  x + 1\n")
    writeFile(dir / "a.nim", "import std/strutils, lib1\necho helper(1).intToStr\n")
    writeFile(dir / "b.nim", "import std/strutils\necho \"x\".toUpperAscii\n")
    let sa = nxScope(nxLoad(dir / "a.nim"))
    let sb = nxScope(nxLoad(dir / "b.nim"))
    var shared = 0
    for la in sa.refs.layers:
      for lb in sb.refs.layers:
        if cast[pointer](la) == cast[pointer](lb): inc shared
    check shared >= 2                        # (system's, and std/strutils')
    check nxLookup(sa, "helper").len == 1 and nxLookup(sa, "toUpperAscii").len > 0
    # lib1 changes inside its body: a.nim's scope sees the new version, strutils' layer is the same one
    let strLayer = sa.refs.layers[1]
    writeFile(dir / "lib1.nim", "proc helper*(x: int): int =\n  x + 2\nproc other*(): int = 3\n")
    setLastModificationTime(dir / "lib1.nim", getTime() + initDuration(seconds = 5))
    nxStatForget()
    let sa2 = nxScope(nxLoad(dir / "a.nim"))
    check nxLookup(sa2, "other").len == 1
    var same = false
    for l in sa2.refs.layers:
      if cast[pointer](l) == cast[pointer](strLayer): same = true
    check same

  test "a module that offered nothing when first read: its new export is seen (its layer is made again)":
    writeFile(dir / "util2.nim", "# nothing yet\n")
    writeFile(dir / "app2.nim", "import util2\necho 1\n")
    check nxLookup(nxScope(nxLoad(dir / "app2.nim")), "hello").len == 0
    writeFile(dir / "util2.nim", "proc hello*() = discard\n")
    setLastModificationTime(dir / "util2.nim", getTime() + initDuration(seconds = 7))
    nxStatForget()
    check nxLookup(nxScope(nxLoad(dir / "app2.nim")), "hello").len == 1
  test "the files a module includes share its names (6.37): each has its own, then one layer of the module's":
    writeFile(dir / "prog.nim", "import std/strutils\nproc top*() = discard\ninclude part1, part2\n")
    writeFile(dir / "part1.nim", "proc one*(): int = 1\n")
    writeFile(dir / "part2.nim", "import std/os\nproc two*(): int = 2\n")
    nxStatForget()
    nxIncDirs.clear()                         # (the folder's includes, looked at by the tests above before prog.nim)
    nxFocusPath = dir / "part1.nim"           # (the file being edited: a scope of its own over the module's)
    let s1 = nxScope(nxLoad(dir / "part1.nim"))
    let s2 = nxScope(nxLoad(dir / "part2.nim"))   # (imports of its own: a scope of its own too)
    nxFocusPath = ""
    check s1.refs.own.len == 1 and s2.refs.own.len == 1      # (their own names only: no copy of the module's)
    check cast[pointer](s1.refs.layers[0]) == cast[pointer](s2.refs.layers[0])
    for nm in ["one", "two", "top"]:
      check nxLookup(s1, nm).len == 1 and nxLookup(s2, nm).len == 1   # (a file's names once, not again from the layer)
    check nxLookup(s1, "toUpperAscii").len > 0 and nxLookup(s2, "fileExists").len > 0
    check nxLookup(s1, "fileExists").len == 0                 # (part2's own import is not part1's)
    var n, ones = 0
    var order: seq[(string, int32)]
    for r in s1.refs:
      inc n
      order.add (r.file.path, r.idx)
      if r.file.syms[r.idx].name == "one": inc ones
    check ones == 1 and n == s1.refs.len
    for i in [0, 1, n div 2, n - 1]:
      check (s1.refs[i].file.path, s1.refs[i].idx) == order[i]

removeDir(dir)
