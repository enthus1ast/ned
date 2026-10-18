## The table of standard-library names and modules each Nim release added (src/ned/nim/nimapis.nim, made by
## .github/ci/nimapis.py): its releases in order, a few names and modules where they belong, and (with nim on
## PATH) the modules it says came with the Nim in use or before are in that Nim's library.
## Run: nim r tests/unit/tnimapis.nim

import std/[os, osproc, strutils, unittest, tables]

include ../../src/ned/nim/nimapis

proc ver(s: string): seq[int] =
  for p in s.split('.'): result.add parseInt(p)

proc less(a, b: seq[int]): bool =
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: a[i] else: 0
    let y = if i < b.len: b[i] else: 0
    if x != y: return x < y
  false

proc stepOf(module, name: string): int =
  result = -1
  for i, st in NimApiSteps:
    for ln in st[3].split('\n'):
      let c = ln.find(": ")
      if c > 0 and ln[0 ..< c] == module and name in ln[c + 2 .. ^1].splitWhitespace: return i

suite "Nim releases' new names":
  test "the steps go from older to newer releases, each after the one before":
    for i, st in NimApiSteps:
      check less(ver(st[0]), ver(st[1]))
      if i > 0: check not less(ver(st[0]), ver(NimApiSteps[i - 1][1]))

  test "names where they belong":
    check NimApiSteps[stepOf("pure/collections/sequtils", "minmax")][1] == "2.0.0"
    check NimApiSteps[stepOf("pure/collections/sequtils", "addUnique")][1] == "2.2.0"
    check NimApiSteps[stepOf("system", "newSeqUninit")][1] == "2.2.0"
    check stepOf("pure/strutils", "split") < 0                 # (as old as Nim 1.0)

  test "modules where they belong":
    var at: Table[string, string]
    for st in NimApiSteps:
      for m in st[2].splitWhitespace: at[m] = st[1]
    check at.getOrDefault("paths") == "2.0.0"
    check at.getOrDefault("staticos") == "2.2.0"
    check "strutils" notin at

  test "the Nim in use has what the table says came before it":
    let nim = findExe("nim")
    if nim.len == 0:
      skip()
    else:
      let (o, _) = execCmdEx("nim --version")
      var cur: seq[int]
      for w in o.splitWhitespace:
        if w.len > 2 and w[0] in Digits and w.count('.') == 2:
          cur = ver(w)
          break
      var lib = ""
      var exe = nim
      try:
        if symlinkExists(exe): exe = expandFilename(exe)
      except OSError: discard
      for c in [exe.parentDir.parentDir / "lib", exe.parentDir.parentDir / "lib" / "nim"]:
        if fileExists(c / "system.nim"): lib = c
      if cur.len == 0 or lib.len == 0:
        skip()
      else:
        # (a module may have gone again since — dom_extensions —: nearly all are there)
        var missing: seq[string]
        var total = 0
        var have: seq[string]
        for f in walkDirRec(lib):
          if f.endsWith(".nim"): have.add extractFilename(f)[0 .. ^5]
        for st in NimApiSteps:
          if less(cur, ver(st[1])): continue                 # (newer than this Nim: not looked for)
          for m in st[2].splitWhitespace:
            inc total
            if m notin have: missing.add m
        check missing.len * 10 <= total
        if missing.len > 0: echo "  (gone since: ", missing.join(", "), ")"
