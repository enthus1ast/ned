# ── NimScript files (config.nims, build.nims, a package's .nimble): what they see and write that programs do not ──
#    system's NimScript API (exec, thisDir, switch …) is theirs only; a .nimble sees nimble's own API too (requires,
#    task, namedBin, taskRequires, feature, before/after hooks …) and strutils, as nimble's wrapper gives them; the
#    compiler's switches (`--opt:speed`, `switch("opt", "speed")`) are completed, explained and checked

include switches

func nxIsScript*(path: string): bool =
  ## a NimScript file: config.nims, build.nims, a package's .nimble
  path.endsWith(".nims") or path.endsWith(".nimble")

func nxIsNimbleFile*(path: string): bool = path.endsWith(".nimble")

func nxScriptTasks*(lines: openArray[string]): seq[tuple[name: string, line, col: int, desc: string]] =
  ## a NimScript file's tasks (`task build, "Build it":` at the top level): the outline, Go to symbol
  for i, l in lines:
    if not l.startsWith("task ") and not l.startsWith("task\t"): continue
    var a = 4
    while a < l.len and l[a] in {' ', '\t'}: inc a
    var e = a
    while e < l.len and nxIsIdent(l[e]): inc e
    if e == a: continue
    var desc = ""
    let q1 = l.find('"', e)
    let q2 = if q1 >= 0: l.find('"', q1 + 1) else: -1
    if q2 > q1: desc = l[q1 + 1 ..< q2]
    result.add (l[a ..< e], i, a, desc)

func nxFromNimscriptApi*(path: string): bool =
  ## a declaration of system's NimScript part (lib/system/nimscript.nim): exec, thisDir, switch, mkDir …
  path.endsWith("/system/nimscript.nim")

const
  NxNimbleOverrides* = ["getCommand", "setCommand", "switch", "--", "thisDir", "packageName", "version", "author",
    "description", "license", "srcDir", "binDir", "backend", "skipDirs", "skipFiles", "skipExt", "installDirs",
    "installFiles", "installExt", "bin", "foreignDeps", "requires", "requiresData", "task"]
    ## (what nimble's wrapper takes from system for a .nimble: its own versions are the ones it sees)

  NxScriptOnly* = [
    ("exec", "osproc's execCmd or execProcess"), ("thisDir", "the folder of currentSourcePath() (std/os: parentDir)"),
    ("projectDir", "getAppDir() (std/os)"), ("mkDir", "createDir (std/os)"), ("rmDir", "removeDir (std/os)"),
    ("rmFile", "removeFile (std/os)"), ("cpFile", "copyFile (std/os)"), ("mvFile", "moveFile (std/os)"),
    ("cpDir", "copyDir (std/os)"), ("mvDir", "moveDir (std/os)"), ("listFiles", "walkDir (std/os)"),
    ("listDirs", "walkDir (std/os)"), ("withDir", "setCurrentDir (std/os)"), ("cd", "setCurrentDir (std/os)"),
    ("selfExe", "getAppFilename (std/os)"), ("toExe", "addFileExt(…, ExeExt) (std/os)"),
    ("toDll", "DynlibFormat (std/os)"), ("switch", "a {.passC.}/{.passL.} pragma, or the option in config.nims"),
    ("hint", "the option in config.nims"), ("patchFile", "config.nims"), ("setCommand", "a .nimble task"),
    ("getCommand", "a .nimble task"), ("cppDefine", "config.nims"), ("requires", "the package's .nimble"),
    ("task", "the package's .nimble or config.nims"), ("readAllFromStdin", "stdin.readAll"),
    ("readLineFromStdin", "stdin.readLine"), ("buildOS", "hostOS"), ("buildCPU", "hostCPU")]
    ## system's NimScript procs a program cannot call — and what a program uses instead

  NxNimbleApi = """## nimble's API in a package's .nimble (nimble 0.26) — described by ned for completion and hover; nimble's
## wrapper gives a .nimble this, system's NimScript part and strutils
import std/tables
export tables

var
  packageName*: string ## The package's name — the .nimble file's own name when it is not set.
  version*: string ## The package's version: "1.2.0".
  author*: string ## Who wrote the package.
  description*: string ## What the package does, in a line.
  license*: string ## Its license: "MIT", "Apache-2.0", "BSD-3-Clause" …
  srcDir*: string ## The folder its modules are in ("src").
  binDir*: string ## Where `nimble build` puts its programs.
  backend*: string ## c, cpp, objc or js: what its programs are compiled with.
  testEntryPoint*: string ## The file `nimble test` runs (instead of every tests/t*.nim).
  skipDirs*: seq[string] ## Folders `nimble install` leaves out.
  skipFiles*: seq[string] ## Files `nimble install` leaves out.
  skipExt*: seq[string] ## Extensions `nimble install` leaves out.
  installDirs*: seq[string] ## Folders `nimble install` copies (only these, when set).
  installFiles*: seq[string] ## Files `nimble install` copies (only these, when set).
  installExt*: seq[string] ## Extensions `nimble install` copies (only these, when set): @["nim"].
  bin*: seq[string] ## The programs it builds: their main modules, without .nim — @["tool"] builds srcDir/tool.nim.
  namedBin*: Table[string, string] ## A program built under another name: namedBin["src/main"] = "tool".
  paths*: seq[string] ## More folders to search for modules.
  entryPoints*: seq[string] ## Its public modules (for documentation and checks).
  requiresData*: seq[string] ## Every requirement `requires` gave so far.
  taskRequiresData*: Table[string, seq[string]] ## Each task's own requirements (taskRequires).
  foreignDeps*: seq[string] ## Packages of the system's package manager it needs (distros: foreignDep).

proc requires*(deps: varargs[string]) =
  ## Packages this one needs: `requires "nim >= 2.0", "jsony >= 1.1"`. Inside a `feature` block: only with that
  ## feature. A version: `>= 1.1`, `== 1.2.3`, `^= 1.2` (1.x from 1.2), `~= 1.2.3` (1.2.x from 1.2.3), `#head`,
  ## `#<commit>`; a URL or `name@<url>` for a package not in the list.
  discard

proc taskRequires*(task: string, deps: varargs[string]) =
  ## Packages one task needs: `taskRequires "test", "unittest2 >= 0.2"` — installed when that task runs, not
  ## for those who install the package.
  discard

template task*(name: untyped, description: string, body: untyped) =
  ## A task: `nimble <name>` runs its body (`nimble tasks` lists them; an empty description hides one).
  discard

template before*(action: untyped, body: untyped) =
  ## Runs before nimble's action (install, build, test …); the action goes on unless the body sets
  ## `result = false`.
  discard

template after*(action: untyped, body: untyped) =
  ## Runs after nimble's action (install, build, test …).
  discard

template feature*(name: string, body: untyped) =
  ## Requirements only for those who ask for the feature (`nimble install pkg[name]`): `requires` inside.
  discard

template dev*(body: untyped) =
  ## Requirements only while developing the package (the feature "dev").
  discard

proc getPkgDir*(): string =
  ## The folder of the .nimble file being run.
  discard

proc thisDir*(): string =
  ## The folder of the .nimble file being run (getPkgDir).
  discard

proc getPaths*(): seq[string] =
  ## The folders of the packages it depends on — in a task, those of the task's requirements too.
  discard

proc getPathsClause*(): string =
  ## getPaths as compiler options: `exec "nim c " & getPathsClause() & " src/tool.nim"`.
  discard

proc getCommand*(): string =
  ## The compiler command setCommand gave (c, cpp, js …).
  discard

proc setCommand*(cmd: string, prj = "") =
  ## After the task, run the compiler with this command (c, cpp, js …) on prj — with the switches given.
  discard

proc switch*(key: string, value = "") =
  ## A compiler option for setCommand: `switch("define", "release")`.
  discard

template `--`*(key, val: untyped) =
  ## A compiler option for setCommand: `--define:release`.
  discard

template `--`*(key: untyped) =
  ## A compiler option for setCommand: `--threads`.
  discard

proc foreignDep*(name: string) =
  ## (import distros) A package of the system's package manager it needs.
  discard

const
  nimbleExe*: string = "nimble" ## The nimble running this file.
  NimbleVersion*: string = "" ## The version of the nimble running this file: "0.26.1".
  NimbleMajor*: int = 0 ## nimble's major version (0).
  NimbleMinor*: int = 0 ## nimble's minor version (26).
  NimblePatch*: int = 0 ## nimble's patch version (1).
"""

var nxNimbleApiMemo = ""

const NxVmCannot* = [
    ## modules of the standard library NimScript cannot run (`nim e`, config.nims, a .nimble — checked with Nim
    ## 2.2: they call C, threads or the OS where the VM has none), and what a script uses instead
    ("osproc", "exec, or gorgeEx (output and exit code), or staticExec"),
    ("net", "exec curl or wget"), ("nativesockets", "exec curl or wget"), ("httpclient", "exec curl or wget"),
    ("asyncdispatch", "a program of its own (nim r)"), ("asyncnet", "a program of its own (nim r)"),
    ("selectors", "a program of its own (nim r)"), ("terminal", "plain echo"),
    ("memfiles", "readFile / writeFile"), ("sha1", "exec sha1sum, or std/hashes"), ("oids", "a counter, or exec"),
    ("re", "std/strutils (find, replace), or std/pegs"), ("typedthreads", "a program of its own (nim r)"),
    ("threadpool", "a program of its own (nim r)"), ("tempfiles", "a name of your own under getTempDir()"),
    ("browsers", "exec xdg-open / open"), ("logging", "echo"), ("marshal", "std/json (%*, to)"),
    ("unittest", "doAssert, or nimble test"), ("endians", "std/bitops"),
    ("dirs", "the NimScript procs: mkDir, rmDir, listDirs"), ("files", "the NimScript procs: rmFile, cpFile, mvFile"),
    ("paths", "std/os's procs on strings"),
    ("posix", "a program of its own"), ("winlean", "a program of its own")]

proc nxNimbleApiPath*(): string =
  ## nimble's API as a module (written once into ned's cache): what a .nimble sees besides system and strutils
  if nxNimbleApiMemo.len > 0 and fileExists(nxNimbleApiMemo): return nxNimbleApiMemo
  let dir = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / "ned" / "nimscript"
  let p = dir / "nimbleapi_" & $(hash(NxNimbleApi) and 0xFFFFFF) & ".nim"
  try:
    if not fileExists(p):
      createDir(dir)
      writeFile(p, NxNimbleApi)
  except CatchableError: return ""
  nxNimbleApiMemo = p
  p

# ── the compiler's switches ──

func nxSwitchFind*(name: string): int =
  ## the switch called `name` (its long name or its one letter, case-insensitive like the compiler): its index, -1
  for i, s in NxSwitches:
    if cmpIgnoreStyle(s[0], name) == 0 or (s[1].len > 0 and s[1] == name): return i
  -1

func nxSwitchValues*(i: int): seq[string] =
  ## the values a switch takes when its help lists them (none|speed|size), else none
  let a = NxSwitches[i][2]
  if '|' notin a: return
  for v in a.split('|'):
    let w = v.split(':')[^1]
    if w.len > 0 and w.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}): result.add w

func nxSwitchDoc*(i: int): string =
  let s = NxSwitches[i]
  "--" & s[0] & (if s[2].len > 0: ":" & s[2] else: "") & (if s[1].len > 0: "  (-" & s[1] & ")" else: "") &
    "\n\n" & s[3]

type NxSwitchCtx* = object
  ok*: bool          # the cursor is on a switch
  value*: bool       # … on its value (after `--name:`, or switch's second string)
  name*: string      # the switch's name (as written)
  start*, stop*: int # what the word under the cursor spans (the name, or the value)

func nxSwitchAt*(line: string, col: int): NxSwitchCtx =
  ## is (col) of this NimScript line on a compiler switch: `--opt:speed`, `-d:release`, `switch("opt", "speed")`
  let c = min(col, line.len)
  var i = 0
  while i < line.len and line[i] in {' ', '\t'}: inc i
  if i < line.len and line[i] == '-':
    var n0 = i
    while n0 < line.len and line[n0] == '-': inc n0
    var n1 = n0
    while n1 < line.len and line[n1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: inc n1
    if n0 - i notin [1, 2] or c < i: return
    if c <= n1:
      return NxSwitchCtx(ok: true, name: line[n0 ..< n1], start: n0, stop: n1)
    if n1 < line.len and line[n1] == ':':
      var v1 = n1 + 1
      if v1 < line.len and line[v1] == '"': inc v1
      var v2 = v1
      while v2 < line.len and line[v2] notin {' ', '"', ':', '#'}: inc v2
      if c >= v1 and c <= v2: return NxSwitchCtx(ok: true, value: true, name: line[n0 ..< n1], start: v1, stop: v2)
    return
  let k = line.find("switch(")
  if k < 0 or c < k: return
  var p = k + 7
  while p < line.len and line[p] == ' ': inc p
  if p >= line.len or line[p] != '"': return
  let a1 = p + 1
  var a2 = a1
  while a2 < line.len and line[a2] notin {'"', ','}: inc a2
  if c >= a1 and c <= a2: return NxSwitchCtx(ok: true, name: line[a1 ..< a2], start: a1, stop: a2)
  var q = a2 + 1
  while q < line.len and line[q] in {' ', ','}: inc q
  if q < line.len and line[q] == '"' and a2 < line.len and line[a2] == '"':
    let b1 = q + 1
    var b2 = b1
    while b2 < line.len and line[b2] != '"': inc b2
    if c >= b1 and c <= b2: return NxSwitchCtx(ok: true, value: true, name: line[a1 ..< a2], start: b1, stop: b2)

# ── nimble's package list: the names `requires "…"` can name ──

var nxPkgNamesMemo: (string, seq[(string, string)])     # (the lists' stamps, (name, description))

proc nxPackageNames*(): seq[(string, string)] =
  ## the packages nimble knows (its package lists, ~/.nimble/packages_*.json): (name, description)
  let nd = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")
  var files: seq[string]
  var stamp = ""
  try:
    for kind, p in walkDir(nd):
      if kind == pcFile and extractFilename(p).startsWith("packages_") and p.endsWith(".json"):
        files.add p
        stamp.add p & "@" & $getLastModificationTime(p).toUnix & ";"
  except CatchableError: discard
  if stamp == nxPkgNamesMemo[0]: return nxPkgNamesMemo[1]
  var seen: HashSet[string]
  for p in files:
    try:
      for e in parseJson(readFile(p)):
        let n = e{"name"}.getStr
        if n.len > 0 and n.toLowerAscii notin seen:
          seen.incl n.toLowerAscii
          result.add (n, e{"description"}.getStr)
    except CatchableError: discard
  nxPkgNamesMemo = (stamp, result)

func nxRequiresStringAt*(line: string, col: int): (bool, int) =
  ## is the cursor in a package name in `requires "…"` (or taskRequires' second string on): (yes, where the name
  ## starts)
  let t = line.strip(trailing = false)
  if not (t.startsWith("requires") or t.startsWith("taskRequires") or t.startsWith("task_requires")): return
  let c = min(col, line.len)
  var inStr = false
  var start = -1
  var nth = 0
  for k in 0 ..< c:
    if line[k] == '"':
      inStr = not inStr
      if inStr:
        start = k + 1
        inc nth
  if not inStr: return
  if t.startsWith("taskRequires") or t.startsWith("task_requires"):
    if nth < 2: return                                      # (the first string is the task's name)
  # only the name: before a space, a version operator or `@`
  for k in start ..< c:
    if line[k] in {' ', '<', '>', '=', '~', '^', '@', '#'}: return
  (true, start)

# ── what a project's code asks -d: about: the names a config's --define can set ──

var nxDefMemo: Table[string, (float, seq[(string, string)])]

const NxCommonDefines* = [
  ("release", "optimised, checks on (nim c -d:release)"), ("danger", "optimised, every check off"),
  ("ssl", "std/net, httpclient: TLS through OpenSSL"), ("useMalloc", "the C allocator instead of Nim's"),
  ("nimStackTraceOverride", "your own stack traces"), ("nimPreviewSlimSystem", "a smaller system module"),
  ("nimDebugDlOpen", "say why a dynamic library did not load"), ("checkAbi", "check the C types' sizes"),
  ("noSignalHandler", "no SIGSEGV handler of Nim's"), ("nimNoLentIterators", "iterators yield copies"),
  ("strip", "strip the binary (-s)"), ("lto", "link-time optimisation (with a toolchain that has it)")]

proc nxProjectDefines*(root: string): seq[(string, string)] =
  ## the names the project's code asks about — `defined(x)`, and the consts with {.strdefine.} {.intdefine.}
  ## {.booldefine.} (or {.strdefine: "pkg.name".}): (name, where it is asked); a few hundred milliseconds at most,
  ## kept for 20 s
  if root.len == 0 or not dirExists(root): return
  let m = nxDefMemo.getOrDefault(root, (0.0, newSeq[(string, string)]()))
  if epochTime() - m[0] < 20: return m[1]
  let t0 = epochTime()
  var seen: Table[string, string]
  var order: seq[string]
  var files = 0
  proc note(name, where: string) =
    if name.len == 0 or not name[0].isAlphaAscii: return
    if name notin seen:
      seen[name] = where
      order.add name
  try:
    for path in walkDirRec(root, skipSpecial = true):
      if epochTime() - t0 > 0.3 or files > 4000: break
      if not path.endsWith(".nim"): continue
      let rel = path[min(path.len, root.len + 1) .. ^1]
      if rel.startsWith(".") or "/." in rel or rel.startsWith("nimcache") or rel.startsWith("nimbledeps") or
         "node_modules" in rel:
        continue
      inc files
      var text = ""
      try: text = readFile(path)
      except CatchableError: continue
      if "define" notin text: continue
      var ln = 0
      for line in text.splitLines:
        inc ln
        var k = line.find("defined(")
        while k >= 0:
          var e = k + 8
          while e < line.len and line[e] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}: inc e
          note(line[k + 8 ..< e], "when defined(…) — " & rel & ":" & $ln)
          k = line.find("defined(", e)
        for pr in ["strdefine", "intdefine", "booldefine", "define"]:
          let p = line.find("{." & pr)
          if p < 0: continue
          let after = p + 2 + pr.len
          if after < line.len and line[after] in {'a'..'z', 'A'..'Z'}: continue     # (a longer name)
          var name = ""
          let colon = line.find(':', after)
          let close = line.find(".}", after)
          if colon >= 0 and (close < 0 or colon < close):
            let q1 = line.find('"', colon)
            let q2 = if q1 > 0: line.find('"', q1 + 1) else: -1
            if q2 > q1: name = line[q1 + 1 ..< q2]
          if name.len == 0:
            var e = p
            while e > 0 and line[e - 1] in {' ', '*'}: dec e
            var s = e
            while s > 0 and line[s - 1] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: dec s
            name = line[s ..< e]
          let dflt = if '=' in line[after .. ^1]: " = " & line[line.find('=', after) + 1 .. ^1].strip else: ""
          note(name, "const {." & pr & ".}" & dflt & " — " & rel & ":" & $ln)
          break
  except CatchableError: discard
  for n in order: result.add (n, seen[n])
  nxDefMemo[root] = (epochTime(), result)

proc nxPathItems*(dir, typed: string): seq[string] =
  ## --path:… — the folders under `dir` that what is typed leads to (the last part's candidates)
  let k = typed.rfind('/')
  let base = if k >= 0: typed[0 ..< k] else: ""
  let d = if base.isAbsolute: base elif base.startsWith("~"): expandTilde(base) else: dir / base
  try:
    for kind, p in walkDir(d):
      if kind in {pcDir, pcLinkToDir}:
        let n = extractFilename(p)
        if not n.startsWith(".") and n notin ["nimcache", "node_modules"]: result.add n
  except CatchableError: discard
  result.sort()
