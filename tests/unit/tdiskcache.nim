## The index kept on disk (nim.indexCache): a library file read from the cache is the same as one parsed afresh;
## a changed text, other defines or a damaged cache file are never used. Run: nim r tests/unit/tdiskcache.nim

import std/[os, strutils, unittest, random, sets, times, algorithm, tables]
import ../../src/ned/nim/index

proc nimLib(): string =
  let nim = findExe("nim")
  doAssert nim.len > 0, "put nim on PATH"
  var exe = nim
  try:
    if symlinkExists(exe): exe = expandFilename(exe)
  except OSError: discard
  let prefix = exe.parentDir.parentDir
  for cand in [prefix / "lib", prefix / "lib" / "nim", "/usr/lib/nim", "/usr/lib/nim/lib"]:
    if fileExists(cand / "system.nim"): return cand
  doAssert false, "no standard library found near " & nim

nxInitDefines()
let lib = nimLib()
nxSetToolchain(lib, @[], @[])
let tmp = getTempDir() / ("ned_tdiskcache_" & $getCurrentProcessId())
createDir(tmp)
nxDiskCacheDir = tmp / "cache"

proc cacheFiles(): seq[string] =
  if dirExists(nxDiskCacheDir):
    for k, p in walkDir(nxDiskCacheDir):
      if p.endsWith(".nx"): result.add p

suite "the index on disk":
  test "a library file from the cache is the file parsed afresh":
    var n = 0
    for f in walkDirRec(lib):
      if not f.endsWith(".nim"): continue
      inc n
      if n > 60: break
      let fresh = nxParse(readFile(f).splitLines, f)
      let first = nxParseDisk(f)                # (parsed, and written)
      let again = nxParseDisk(f)                # (read back)
      check nxCacheBytes(first) == nxCacheBytes(fresh)
      check nxCacheBytes(again) == nxCacheBytes(fresh)
      check again.syms.len == fresh.syms.len
    check cacheFiles().len >= 50

  test "project files are kept unless nim.indexCacheProject is off; untitled buffers never":
    let mine = tmp / "project" / "mine.nim"
    createDir(mine.parentDir)
    writeFile(mine, "proc mine*() = discard\n")
    nxCacheProject = false
    var before = cacheFiles().len
    check nxParseDisk(mine).syms.len == 1
    check cacheFiles().len == before
    nxCacheProject = true
    check nxParseDisk(mine).syms.len == 1
    check cacheFiles().len == before + 1
    check nxParseDisk(mine).syms[0].name == "mine"     # (read back)
    writeFile(mine, "proc mine2*() = discard\n")
    check nxParseDisk(mine).syms[0].name == "mine2"    # (a changed file is parsed again)
    let untitled = tmp / "project" / "untitled-1.nim"
    writeFile(untitled, "proc u*() = discard\n")
    before = cacheFiles().len
    check nxParseDisk(untitled).syms.len == 1
    check cacheFiles().len == before

  test "a changed text is parsed again, even of the same length":
    let pkg = tmp / "nimble" / "pkgs2" / "foo-1.0.0-abc" / "foo.nim"
    createDir(pkg.parentDir)
    writeFile(pkg, "proc alpha*() = discard\n")
    check nxParseDisk(pkg).syms[0].name == "alpha"
    check nxParseDisk(pkg).syms[0].name == "alpha"
    writeFile(pkg, "proc gamma*() = discard\n")          # (same length, maybe the same second)
    check nxParseDisk(pkg).syms[0].name == "gamma"

  test "other defines: another entry":
    let pkg = tmp / "nimble" / "pkgs2" / "bar-1.0.0-abc" / "bar.nim"
    createDir(pkg.parentDir)
    writeFile(pkg, "when defined(nedTestFlag):\n  proc on*() = discard\nelse:\n  proc off*() = discard\n")
    proc same(): bool =
      let a = nxParseDisk(pkg)
      a.syms[0].name == nxParse(readFile(pkg).splitLines, pkg).syms[0].name
    let complete = nxDefinesComplete
    check same()
    nxDefinesComplete = true                     # (an unknown name is now known not to be defined)
    check same()
    check nxParseDisk(pkg).syms[0].name == "off"
    nxDefines.incl "nedTestFlag"
    check same()
    check nxParseDisk(pkg).syms[0].name == "on"
    nxDefines.excl "nedTestFlag"
    check nxParseDisk(pkg).syms[0].name == "off"
    nxDefinesComplete = complete

  test "a damaged cache file is never used, and never stops the parse":
    let pkg = tmp / "nimble" / "pkgs2" / "baz-1.0.0-abc" / "baz.nim"
    createDir(pkg.parentDir)
    var text = ""
    for i in 0 ..< 40:
      text.add "type T" & $i & "* = object\n  a, b: int\n  s: seq[string]\nproc p" & $i & "*(x: T" & $i &
               ", y = \"q\"): int {.inline.} = 1\n"
    writeFile(pkg, text)
    let fresh = nxCacheBytes(nxParse(text.splitLines, pkg))
    discard nxParseDisk(pkg)
    var entry = ""
    for p in cacheFiles():
      if pkg in readFile(p): entry = p
    check entry.len > 0
    let good = readFile(entry)
    var r = initRand(68)
    var used = 0
    for round in 0 ..< 400:
      var bad = good
      case round mod 4
      of 0: bad.setLen(r.rand(bad.len - 1))                                  # cut short
      of 1:                                                                    # bytes changed
        for k in 0 .. r.rand(3):
          let i = r.rand(bad.high)
          bad[i] = char(r.rand(255))
      of 2: bad.add char(r.rand(255))                                          # something after the end
      else:                                                                    # a huge length
        let i = r.rand(bad.high)
        bad.insert("\xff\xff\xff\xff\xff\xff\xff\xff\x7f", i)
      writeFile(entry, bad)
      var got: NxFile
      try: got = nxParseDisk(pkg)
      except CatchableError: got = nil
      check got != nil
      if got != nil:
        if nxCacheBytes(got) != fresh: inc used
    check used == 0          # (the body's hash: a changed name is noticed too)

  test "at most 4000 entries: the oldest go":
    for i in 0 ..< 4100:
      writeFile(nxDiskCacheDir / ("old" & $i & ".nx"), "x")
      if i < 200: setLastModificationTime(nxDiskCacheDir / ("old" & $i & ".nx"), fromUnix(1_000_000 + i))
    nxDiskCacheTidied = false
    let pkg = tmp / "nimble" / "pkgs2" / "tidy-1.0.0-abc" / "tidy.nim"
    createDir(pkg.parentDir)
    writeFile(pkg, "proc tidy*() = discard\n")
    discard nxParseDisk(pkg)
    let left = cacheFiles()
    check left.len <= 3001
    check not fileExists(nxDiskCacheDir / "old0.nx")         # (the oldest first)

  test "off: nothing written":
    nxDiskCache = false
    let pkg = tmp / "nimble" / "pkgs2" / "off-1.0.0-abc" / "off.nim"
    createDir(pkg.parentDir)
    writeFile(pkg, "proc off*() = discard\n")
    let before = cacheFiles().len
    check nxParseDisk(pkg).syms.len == 1
    check cacheFiles().len == before
    nxDiskCache = true

suite "the index's memory (nim.indexMemory)":
  test "over the budget the files asked about least recently go — never an open one — and come back the same":
    var libFiles: seq[string]
    for f in walkDirRec(lib / "pure"):
      if f.endsWith(".nim") and getFileSize(f) < 200_000: libFiles.add f
    libFiles.sort()
    # a project file importing strutils, "open in a buffer"
    let mine = tmp / "proj" / "open.nim"
    createDir(mine.parentDir)
    let text = "import std/strutils\nlet s = \"x\"\necho s.toUpp\n"
    writeFile(mine, text)
    nxBufferStamp = proc(p: string): string = (if p == mine: "b1:1" else: "")
    nxBufferLines = proc(p: string): seq[string] = (if p == mine: text.split('\n') else: @[])
    let f = nxLoad(mine)
    let ls = text.split('\n')
    let before = nxComplete(f, ls, 2, ls[2].len)
    check before.items.len > 0
    nxIndexBudget = 400_000
    let dropped0 = nxDropped
    for p in libFiles[0 ..< min(80, libFiles.len)]: discard nxLoad(p)
    check nxDropped > dropped0
    check nxFilesBytes <= nxIndexBudget
    check mine in nxFiles                              # (open: kept)
    var labels: seq[string]
    for it in before.items: labels.add it.label
    var again: seq[string]
    for it in nxComplete(nxLoad(mine), ls, 2, ls[2].len).items: again.add it.label
    check again == labels                              # (what was dropped is read again: the same answer)
    check "toUpperAscii" in again
    nxIndexBudget = 0                                  # (no limit: nothing goes)
    let dropped1 = nxDropped
    for p in libFiles[0 ..< min(80, libFiles.len)]: discard nxLoad(p)
    check nxDropped == dropped1
    nxBufferStamp = nil
    nxBufferLines = nil

  test "what a parsed file takes, as counted, is near what freeing it gives back":
    nxForgetFiles()
    nxScopes.clear()
    nxIndexBudget = 0
    GC_fullCollect()
    let m0 = getOccupiedMem()
    for f in walkDirRec(lib / "pure"):
      if f.endsWith(".nim"): discard nxLoad(f)
    let counted = nxFilesBytes
    GC_fullCollect()
    let used = getOccupiedMem() - m0
    check counted > 1_000_000
    check counted.float > used.float * 0.6 and counted.float < used.float * 1.4

removeDir(tmp)
