## What a file sees, held in shared layers (6.33): every name is found as it was when each scope held its own copy —
## a lookup gives what going through all the scope's names gives, in the same order — and two files that import the
## same module share what it brings. Run: nim r tests/unit/tscopes.nim

import std/[os, strutils, unittest, algorithm, sets, times]
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

removeDir(dir)
