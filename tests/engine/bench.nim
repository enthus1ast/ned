## bench.nim FILE… — how fast ned's Nim engine is, and how much memory it takes, on real code: the time to read a
## file and everything it imports (cold), to answer again after an edit (warm), and the memory held afterwards.
## Build and run: nim r -d:release tests/engine/bench.nim ~/src/app.nim

import std/[os, strutils, monotimes, times, tables]
import ../../src/ned/nim/index

proc ms(t0: MonoTime): float = float((getMonoTime() - t0).inMicroseconds) / 1000.0

proc rssMB(): float =
  ## (Linux; elsewhere -1)
  result = -1.0
  try:
    for l in lines("/proc/self/status"):
      if l.startsWith("VmRSS:"): return parseFloat(l.splitWhitespace()[1]) / 1024.0
  except CatchableError: discard

nxInitDefines()
let nim = findExe("nim")
var lib = ""
if nim.len > 0:
  var prefix = nim
  try: prefix = expandFilename(nim)
  except OSError: discard
  for cand in [prefix.parentDir.parentDir / "lib", "/usr/lib/nim", "/usr/lib/nim/lib"]:
    if fileExists(cand / "system.nim"):
      lib = cand
      break
doAssert lib.len > 0, "put nim on PATH"
nxSetToolchain(lib, @[], @[])
echo "memory at start: ", rssMB().formatFloat(ffDecimal, 1), " MB"
for p in commandLineParams():
  let path = absolutePath(p)
  var t0 = getMonoTime()
  let f = nxLoad(path)
  let sc = nxScope(f)
  let cold = ms(t0)
  let lines = readFile(path).split('\n')
  # an answer after an edit: the file read again, its scope made again (the imports are kept)
  var warm = 0.0
  for i in 0 ..< 5:
    t0 = getMonoTime()
    let f2 = nxParse(lines, path)
    f2.stamp = "edit" & $i
    nxFiles[path] = f2
    discard nxScope(f2)
    warm += ms(t0)
  # completion at the end of the file
  t0 = getMonoTime()
  let c = nxComplete(nxFiles[path], lines, lines.high, 0)
  let compl = ms(t0)
  echo extractFilename(path), ": ", lines.len, " lines, ", sc.refs.len, " names in scope from ", sc.deps.len,
       " files · cold ", cold.formatFloat(ffDecimal, 1), " ms · after an edit ",
       (warm / 5).formatFloat(ffDecimal, 1), " ms · completion ", compl.formatFloat(ffDecimal, 1), " ms (",
       c.items.len, " items) · memory ", rssMB().formatFloat(ffDecimal, 1), " MB"
var total = 0
for _, f in nxFiles: total += f.syms.len
echo "files read: ", nxFiles.len, " · declarations: ", total
