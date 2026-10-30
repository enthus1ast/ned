## Why tracers: why a routine raises an exception or has side effects — the place in its body where it comes in,
## the routine called there, its place, … down to the raise, the global or the declaration that starts it.
## Run: nim r tests/unit/twhy.nim

import std/[os, strutils, unittest]
import ../../src/ned/nim/index

proc realOf(p: string): string =
  ## the path a symbolic link points to; any other path as it is
  result = p
  try:
    if symlinkExists(p): result = expandFilename(p)
  except OSError: discard

proc nimLib(): string =
  ## the folder of Nim's standard library next to the nim on PATH, empty when there is none (the tests that need it are
  ## skipped)
  let nim = findExe("nim")
  if nim.len == 0: return ""
  let prefix = nim.realOf.parentDir.parentDir
  for cand in [prefix / "lib", prefix / "lib" / "nim", "/usr/lib/nim", "/usr/lib/nim/lib"]:
    if fileExists(cand / "system.nim"): return cand

nxInitDefines()
let lib = nimLib()
if lib.len > 0: nxSetToolchain(lib, @[], @[])

let dir = getTempDir() / ("ned_twhy_" & $getCurrentProcessId())
createDir(dir)

const Src = """
type ParseFail = object of ValueError

var counter = 0

proc inner(x: int) =
  if x < 0:
    raise newException(ParseFail, "negative")

proc middle(x: int) =
  let y = x * 2
  inner(y)

proc outer(x: int) =
  discard x + 1
  middle(x)

proc declared() {.raises: [IOError].} =
  discard

proc callsDeclared() =
  declared()

proc touch() =
  counter = counter + 1

proc viaTouch() =
  let a = 1
  touch()

proc talks() =
  echo "hi"
"""

writeFile(dir / "w.nim", Src)
let f = nxLoad(dir / "w.nim")

proc refOf(name: string): NxRef =
  ## the reference to the routine of that name in the test file
  for i in 0 ..< f.syms.len:
    if f.syms[i].name == name and f.syms[i].kind in NxRoutineKinds: return NxRef(file: f, idx: int32(i))

proc lineOf(text: string): int =
  ## the number of the first line of the test source that has the text, -1 when none does
  let ls = Src.splitLines
  for i, l in ls:
    if text in l: return i
  -1

discard nxRaisesOf(refOf("outer"), 100_000, 60_000)    # (the standard library read once: no test runs out of time)

suite "why tracers":
  test "an exception: the call in each body down to the raise":
    let st = nxWhy(refOf("outer"), "ParseFail")
    check st.len == 3
    if st.len == 3:
      check st[0].kind == nwCall and st[0].what == "middle" and st[0].line == lineOf("  middle(x)") and
            st[0].routine == "outer"
      check st[1].kind == nwCall and st[1].what == "inner" and st[1].line == lineOf("  inner(y)") and
            st[1].routine == "middle"
      check st[2].kind == nwRaise and st[2].line == lineOf("raise newException") and st[2].routine == "inner"
  test "an exception a routine declares: the chain stops at its declaration":
    let st = nxWhy(refOf("callsDeclared"), "IOError")
    check st.len == 2
    if st.len == 2:
      check st[0].kind == nwCall and st[0].what == "declared"
      check st[1].kind == nwDeclared and st[1].routine == "declared" and "IOError" in st[1].what
  test "a side effect: down to the global it uses":
    let st = nxWhy(refOf("viaTouch"), "", fx = true)
    check st.len == 2
    if st.len == 2:
      check st[0].kind == nwCall and st[0].what == "touch" and st[0].line == lineOf("  touch()")
      check st[1].kind == nwGlobal and st[1].what == "counter" and st[1].routine == "touch"
  test "a side effect of a routine that says so (echo)":
    let st = nxWhy(refOf("talks"), "", fx = true)
    check st.len >= 1
    if st.len >= 1: check st[0].kind == nwCall and st[0].what == "echo"
    if st.len >= 2: check st[^1].kind == nwDeclared

removeDir(dir)
