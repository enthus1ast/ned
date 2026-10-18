## Which version of a nimble package the index reads: the one the project builds with — the paths its config gives
## (nimble.paths, atlas), nimble.lock, nimbledeps/, atlas' deps/, the `requires` of its .nimble — and only then the
## newest installed. A fake pkgs2 holds two versions (and a #head) of a package. Run: nim r tests/unit/tversions.nim

import std/[os, strutils, unittest, tables, times]
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

let tmp = getTempDir() / ("ned_tversions_" & $getCurrentProcessId())
removeDir(tmp)
let pkgs = tmp / "nimble" / "pkgs2"

proc put(path, text: string) =
  createDir(path.parentDir)
  writeFile(path, text)

# the installed packages: foo 1.0.0, 2.0.0 and #head; bar 1.0.0 and 1.5.0 (foo 2.0.0 requires bar); baz in src/
put pkgs / "foo-1.0.0-aaaa1111" / "foo.nimble", "version = \"1.0.0\"\n"
put pkgs / "foo-1.0.0-aaaa1111" / "foo.nim", "proc oldOne*(): int = 1\n"
put pkgs / "foo-2.0.0-bbbb2222" / "foo.nimble", "version = \"2.0.0\"\nrequires \"nim >= 2.0\", \"bar >= 1.0\"\n"
put pkgs / "foo-2.0.0-bbbb2222" / "foo.nim", "proc newOne*(): int = 2\n"
put pkgs / "foo-#head-cccc3333" / "foo.nimble", "version = \"2.1.0\"\n"
put pkgs / "foo-#head-cccc3333" / "foo.nim", "proc headOne*(): int = 3\n"
put pkgs / "bar-1.0.0-dddd4444" / "bar.nim", "proc barOld*() = discard\n"
put pkgs / "bar-1.5.0-eeee5555" / "bar.nim", "proc barNew*() = discard\n"
put pkgs / "baz-0.1.0-ffff6666" / "src" / "baz.nim", "proc bazOne*() = discard\n"

nxInitDefines()
nxSetToolchain(nimLib(), @[], @[pkgs])

proc project(name, nimble: string, files: openArray[(string, string)] = []): string =
  ## a project folder with its .nimble (and other files), and a module importing foo, bar and baz
  let root = tmp / name
  put root / (name & ".nimble"), nimble
  for (p, t) in files: put root / p, t
  put root / "src" / (name & ".nim"), "import foo, bar, baz\n"
  root

proc resolved(root, module: string): string =
  ## the folder of the package `import module` reaches from the project's main module (relative to pkgs2)
  let r = nxResolve(root / "src" / (extractFilename(root) & ".nim"), module)
  if r.len == 0: return "(not found)"
  var d = r.parentDir
  if d.endsWith("/src"): d = d.parentDir
  if d.startsWith(pkgs & "/"): d[pkgs.len + 1 .. ^1] else: relativePath(d, tmp)

proc why(root, name: string): string =
  for d in nxProjectAt(root).deps:
    if d.name == name: return d.version & " (" & d.why & ")"
  "(none)"

suite "requirements":
  test "nimble's version rules":
    check nxSatisfies("1.2.3", ">= 1.2")
    check not nxSatisfies("1.1.9", ">= 1.2")
    check nxSatisfies("1.4.0", ">= 1.2 & < 2.0")
    check not nxSatisfies("2.0.0", ">= 1.2 & < 2.0")
    check nxSatisfies("1.4", "== 1.4") and nxSatisfies("1.4.0", "1.4") and not nxSatisfies("1.4.1", "== 1.4")
    check nxSatisfies("1.9.0", "^= 1.2") and not nxSatisfies("2.0.0", "^= 1.2") and not nxSatisfies("1.1.0", "^= 1.2")
    check nxSatisfies("0.3.9", "^= 0.3.1") and not nxSatisfies("0.4.0", "^= 0.3.1")
    check nxSatisfies("1.2.9", "~= 1.2.3") and not nxSatisfies("1.3.0", "~= 1.2.3")
    check nxSatisfies("#head", "#head") and not nxSatisfies("#head", ">= 1.0") and nxSatisfies("1.0", "")

  test "a requirement's package name, a URL's too":
    check nxSplitRequire("jsony >= 1.1 & < 2.0") == ("jsony", ">= 1.1 & < 2.0")
    check nxSplitRequire("foo#head") == ("foo", "#head")
    check nxSplitRequire("foo@#head") == ("foo", "#head")
    check nxSplitRequire("https://github.com/x/bar.git >= 1.0") == ("bar", ">= 1.0")
    check nxSplitRequire("git@github.com:x/qux#v2") == ("qux", "#v2")
    check nxSplitRequire("chronos") == ("chronos", "")

suite "the version a project builds with":
  test "nimble.lock: the folder whose version and checksum the lock names (the older of two installed)":
    let a = project("pa", "requires \"foo\"\n", [("nimble.lock",
      """{"version": 2, "packages": {"foo": {"version": "1.0.0", "vcsRevision": "x", "url": "u", "downloadMethod": "git",
         "dependencies": [], "checksums": {"sha1": "aaaa1111"}}}}""")])
    check resolved(a, "foo") == "foo-1.0.0-aaaa1111"
    check why(a, "foo") == "1.0.0 (nimble.lock)"
    check resolved(a, "baz") == "baz-0.1.0-ffff6666"           # (not in the lock: the newest installed, src/ too)

  test "the requires lines: the newest installed version that meets them, and what that one requires":
    let b = project("pb", "requires \"nim >= 2.0\"\nrequires \"foo >= 1.5\"\n")
    check resolved(b, "foo") == "foo-2.0.0-bbbb2222"           # (#head does not count for a numbered requirement)
    check why(b, "foo") == "2.0.0 (requires >= 1.5)"
    check resolved(b, "bar") == "bar-1.5.0-eeee5555"
    check why(b, "bar") == "1.5.0 (foo requires >= 1.0)"
    let c = project("pc", "requires \"foo < 2.0\", \"bar == 1.0.0\"\n")
    check resolved(c, "foo") == "foo-1.0.0-aaaa1111"
    check resolved(c, "bar") == "bar-1.0.0-dddd4444"
    check resolved(project("pd", "requires \"foo ^= 1.0\"\n"), "foo") == "foo-1.0.0-aaaa1111"
    check resolved(project("pe", "requires \"foo ~= 2.0\"\n"), "foo") == "foo-2.0.0-bbbb2222"
    check resolved(project("pf", "requires \"foo#head\"\n"), "foo") == "foo-#head-cccc3333"
    check resolved(project("pg", "requires \"https://example.com/x/foo.git == 1.0.0\"\n"), "foo") == "foo-1.0.0-aaaa1111"
    check resolved(project("ph", "requires(\n  \"foo >= 1.0 & < 2.0\",\n  \"bar\")\n"), "foo") == "foo-1.0.0-aaaa1111"

  test "nothing required: the newest installed (#head counts as newest, as the compiler takes it)":
    check resolved(project("pi", "version = \"0.1\"\n"), "foo") == "foo-#head-cccc3333"

  test "a nimbledeps/ folder, then atlas' deps/":
    let d = project("pj", "requires \"foo\"\n", [("nimbledeps/pkgs2/foo-1.5.0-gggg7777/foo.nim", "proc localOne*() = discard\n")])
    check resolved(d, "foo") == "pj/nimbledeps/pkgs2/foo-1.5.0-gggg7777"
    check why(d, "foo") == "1.5.0 (nimbledeps/)"
    let e = project("pk", "requires \"foo >= 2.0\"\n", [("deps/foo/foo.nimble", "version = \"1.7.0\"\n"),
                                                        ("deps/foo/foo.nim", "proc atlasOne*() = discard\n")])
    check resolved(e, "foo") == "pk/deps/foo"
    check why(e, "foo") == "1.7.0 (deps/)"

  test "the paths the project's config gives (nim dump: nimble.paths) win over the lock and the requires":
    let f = project("pl", "requires \"foo >= 2.0\"\n", [("nimble.paths", "--noNimblePath\n--path:\"" & pkgs /
                                                         "foo-1.0.0-aaaa1111" & "\"\n")])
    nxProjectPaths[f] = @[pkgs / "foo-1.0.0-aaaa1111"]
    check resolved(f, "foo") == "foo-1.0.0-aaaa1111"
    check why(f, "foo") == "1.0.0 (nimble.paths)"

  test "two projects, two versions: each reads its own; a package's files follow the project asking":
    let a = tmp / "pa"
    let b = tmp / "pb"
    let fa = nxLoad(a / "src" / "pa.nim")
    let fb = nxLoad(b / "src" / "pb.nim")
    var na, nb: seq[string]
    for r in nxScope(fa).refs: na.add r.sym.name
    for r in nxScope(fb).refs: nb.add r.sym.name
    check "oldOne" in na and "newOne" notin na
    check "newOne" in nb and "oldOne" notin nb
    # foo 2.0.0's own `import bar`: bar as project pb has it, or as pc has it
    let inFoo = pkgs / "foo-2.0.0-bbbb2222" / "foo.nim"
    nxSetActiveFile(b / "src" / "pb.nim")
    check nxResolve(inFoo, "bar").contains("bar-1.5.0")
    nxSetActiveFile(tmp / "pc" / "src" / "pc.nim")
    check nxResolve(inFoo, "bar").contains("bar-1.0.0")

  test "the lock edited: read again":
    let a = tmp / "pa"
    writeFile(a / "nimble.lock", """{"version": 2, "packages": {"foo": {"version": "2.0.0", "checksums": {"sha1": "bbbb2222"}}}}""")
    setLastModificationTime(a / "nimble.lock", fromUnix(1_900_000_000))
    nxProjects.del a                      # (a project is looked at again at most every 2 s: not wait here)
    check resolved(a, "foo") == "foo-2.0.0-bbbb2222"
    var names: seq[string]
    for r in nxScope(nxLoad(a / "src" / "pa.nim")).refs: names.add r.sym.name
    check "newOne" in names and "oldOne" notin names

removeDir(tmp)
