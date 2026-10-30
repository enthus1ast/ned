# ── Nim 3 (Nimony). A project built with `nimony` (nim.compiler: "nimony", best in its .ned/settings.json) is Nim 3:
#    ned's engine matches names as written (Nim 3 is case-sensitive) and reads Nimony's own standard library, errors
#    come from `nimony check`, and Nimony itself answers go to definition and references where the engine has none
#    (--def, --usages). Nimony's build files go to ned's own folder, never into the project ──

var
  nimonyMemo = ("\x00", "", "")       # (PATH it was looked up with, the nimony program, its checkout)
  nim3Asked: HashSet[string]          # files of a Nim 2 project being ported: their porting problems shown, and
                                      # nimony checks them (on save, the assistant's edits)

var nimonyLookedAt: MonoTime

proc nimonyFind() =
  ## finds the nimony program (on PATH, else in ~/nimony, ~/src/nimony or ~/.local/nimony) and its checkout (the folder
  ## holding lib/std/system.nim), and remembers them while PATH is the same; when none is found it looks again only
  ## after 10 seconds
  let path = getEnv("PATH")
  # (not found: looked for again after 10 s — *Nim 3: install or update Nimony* may have just built it)
  if nimonyMemo[0] == path and (nimonyMemo[1].len > 0 or msSince(nimonyLookedAt) < 10_000): return
  nimonyLookedAt = getMonoTime()
  var exe = findExe("nimony")
  if exe.len == 0:
    for c in [getHomeDir() / "nimony" / "bin" / "nimony", getHomeDir() / "src" / "nimony" / "bin" / "nimony",
              getHomeDir() / ".local" / "nimony" / "bin" / "nimony"]:
      if fileExists(addFileExt(c, ExeExt)):
        exe = addFileExt(c, ExeExt)
        break
  var root = ""
  if exe.len > 0:
    var real = exe
    try: real = expandFilename(exe)
    except CatchableError: discard
    let top = parentDir(parentDir(real))
    if fileExists(top / "lib" / "std" / "system.nim"): root = normalizedPath(top)
  nimonyMemo = (path, exe, root)

proc nimonyExe(): string =
  ## the nimony program, "" when it is not installed
  nimonyFind()
  nimonyMemo[1]

proc nimonyRoot(): string =
  ## the Nimony checkout of the `nimony` in use (its lib/std, its doc/), "" when there is none
  nimonyFind()
  nimonyMemo[2]

var nimonyVer = ("", "")              # (program, its version)

proc nimonyVersion(): string =
  ## "0.6.3": the first word of the checkout's doc/version.md (what `nimony --version` says), no program run
  let e = nimonyExe()
  if e.len == 0: return ""
  if nimonyVer[0] == e: return nimonyVer[1]
  var v = ""
  try:
    let w = readFile(nimonyRoot() / "doc" / "version.md").splitWhitespace()
    if w.len > 0: v = w[0]
  except CatchableError: discard
  nimonyVer = (e, v)
  v

var nim3Seen: (string, bool, MonoTime)   # (the folder, whether it is a Nim 3 project, when looked at)

proc nim3Project(dir: string): bool =
  ## does the project say it is Nim 3: nimony's own configuration (nimony.args, nimony.paths) or pnak's (pnak.nif),
  ## in its folder or one above? (Looked at again after 5 s)
  if dir.len == 0: return false
  if nim3Seen[0] == dir and msSince(nim3Seen[2]) < 5000: return nim3Seen[1]
  var d = dir
  var found = false
  for _ in 0 .. 3:
    for n in ["nimony.args", "nimony.paths", "pnak.nif"]:
      if fileExists(d / n): found = true
    let up = parentDir(d)
    if found or up.len == 0 or up == d: break
    d = up
  nim3Seen = (dir, found, getMonoTime())
  found

proc nim3Why(dir: string): string =
  ## the file that makes a project Nim 3 for nim.compiler "auto" — nimony.args, nimony.paths or pnak.nif in its folder
  ## or up to three above — "" when there is none
  var d = dir
  for _ in 0 .. 3:
    for n in ["nimony.args", "nimony.paths", "pnak.nif"]:
      if fileExists(d / n): return d / n
    let up = parentDir(d)
    if up.len == 0 or up == d: break
    d = up
  ""

var nimonyBuilding = false              # (Nim 3: install or update nimony is running: the status bar says so)

proc nim3On(): bool =
  ## is the project Nim 3 — built with nimony (said so, or nim.compiler "auto" and the project has nimony's or pnak's
  ## files), which is installed?
  case cfgNimCompiler
  of "nimony": nimonyRoot().len > 0
  of "auto": nim3Project(rootDir) and nimonyRoot().len > 0
  else: false

func nimonyKey(s: string): string =
  ## a short name for a path (FNV-1a)
  var h = 2166136261'u32
  for c in s: h = (h xor uint32(ord(c))) * 16777619'u32
  toHex(h, 8)

proc nimonyCache(): string =
  ## where nimony keeps its build files for this project (it would make nimcache/ in the project's folder)
  privDir() / "nimony" / ("cache-" & nimonyKey(if rootDir.len > 0: rootDir else: getCurrentDir()))

proc nimonyArgs(): string =
  ## the arguments every nimony run gets: its build files go to ned's own folder
  "--nimcache:" & quoteShell(nimonyCache())

proc nimonyCheckCmd(path: string): string =
  ## the shell command that has nimony check a file, errors and all on the output
  quoteShell(nimonyExe()) & " check " & nimonyArgs() & " " & quoteShell(path) & " 2>&1"

proc nimonyCopyText(lines: openArray[string], dir: string): string =
  ## the text of a file for a copy kept elsewhere: imports and includes of a path relative to the file
  ## (`import ./a`, `include "../b"`) made absolute — on the same lines, so what nimony says keeps its lines
  for l in lines:
    let t = l.strip(trailing = false)
    let ind = l.len - t.len
    var kw = ""
    for k in ["import ", "include ", "from "]:
      if t.startsWith(k): kw = k
    if kw.len == 0:
      result.add l & "\n"
      continue
    var rest = t[kw.len .. ^1]
    var tail = ""
    if kw == "from ":
      let k = rest.find(" import ")
      if k < 0:
        result.add l & "\n"
        continue
      tail = rest[k .. ^1]
      rest = rest[0 ..< k]
    var parts: seq[string]
    for p0 in rest.split(','):
      var p = p0.strip
      var q = p.strip(chars = {'"'})
      if q.startsWith("./") or q.startsWith("../") or (q.len > 0 and q[0] notin {'(', '/'} and
         not q.startsWith("std/") and not q.startsWith("std /") and
         (fileExists(dir / q & ".nim") or fileExists(dir / q))):
        p = "\"" & normalizedPath(dir / q) & "\""
      parts.add p
    result.add spaces(ind) & kw & parts.join(", ") & tail & "\n"

proc nimonyDefaultDefines(): seq[string] =
  ## what nimony defines that `when defined(…)` asks about (and Nim 2 does not)
  @["nimony", "nimNativeAlloc", "nimNativeIo"]

# ── what Nimony says: --def and --usages, nimsuggest's format (def|use \t \t symbol \t \t \t file \t line \t col) ──

proc nimonyAnswerLines(output, cwd: string): seq[(string, int, int)] =
  ## (file, line from 0, column) of each def/use line
  for raw in output.splitLines:
    let f = raw.split('\t')
    if f.len >= 8 and f[0] in ["def", "use"]:
      try:
        var p = f[5]
        if not p.isAbsolute: p = normalizedPath(cwd / p)
        result.add (p, parseInt(f[6]) - 1, parseInt(f[7]))
      except ValueError: discard

var nimonyAskError = ""                 # why the last --def / --usages gave no answer ("" when it ran through)

func nimonyFailure(output: string): string =
  ## the line that says why nimony stopped (an assertion of its own, a FAILURE), "" when it did not
  for l in output.splitLines:
    let t = l.strip
    if t.startsWith("Error: unhandled exception:"): return t["Error: unhandled exception:".len .. ^1].strip
  for l in output.splitLines:
    let t = l.strip
    if t.startsWith("Error:"): return t

proc nimonyAsk(b: Buffer, what: string, pos: Pos, done: proc(found: seq[(string, int, int)])) =
  ## nimony check --def / --usages at a place of the buffer: its text as a copy in ned's folder (imports made
  ## absolute, the file's folder on the search path); what is in the copy is the file's own
  if nimonyExe().len == 0 or b.path.len == 0: return
  let dir = privDir() / "nimony" / ("ask-" & nimonyKey(b.path))
  let copy = dir / extractFilename(b.path)
  try:
    createDir(dir)
    writeFile(copy, nimonyCopyText(b.lines, parentDir(b.path)))
  except CatchableError: return
  let path = b.path
  let cmd = quoteShell(nimonyExe()) & " check " & nimonyArgs() & " --path:" & quoteShell(parentDir(path)) & " --" &
            what & ":" & quoteShell(copy & "," & $(pos.line + 1) & "," & $(pos.col + 1)) & " " & quoteShell(copy) &
            " 2>&1"
  discard startJob(jkTool, cmd, dir, proc(j: Job) =
    var found = nimonyAnswerLines(j.output, j.cwd)
    for x in found.mitems:
      if x[0] == copy: x[0] = path
    nimonyAskError = if found.len == 0 and j.code != 0: nimonyFailure(j.output) else: ""
    done(found))

# ── Nimony's guides for the assistant: Nim 3 is not what the models learned ──

proc nimonyGuide(maxBytes = 24_000): string =
  ## what Nim 3 changes and how to port to it, from the docs of the Nimony in use (doc/differences.md and
  ## doc/porting.md), shortened to maxBytes; a short summary when they are not there
  let root = nimonyRoot()
  for f in ["differences.md", "porting.md"]:
    let p = root / "doc" / f
    if root.len > 0 and fileExists(p):
      try:
        var t = readFile(p)
        if result.len + t.len > maxBytes: t = t[0 ..< max(0, maxBytes - result.len)] & "\n…\n"
        result.add "\n\n# " & f & "\n\n" & t
      except CatchableError: discard
  if result.len == 0:
    result = """
Nim 3 (Nimony) differs from Nim 2:
- identifiers are case-sensitive ({.feature: "ignoreStyle".} brings Nim 2's rule back for a module);
- ref, ptr, pointer, cstring and proc types cannot be nil unless written `nil ref T` (or {.feature: "lenientnils".});
- the library's errors are ErrorCode values: `raise IOError`, `except IOError:` (no `as e`, no `.msg`); a project's
  own `ref object of CatchableError` types still work as in Nim 2; procs do not raise unless marked {.raises.};
- async is `{.passive.}` and there is no `await`;
- func, iterator and converter have no side effects by default, proc has; there is no inference;
- macros are compiler plugins; multi-methods are gone;
- an unlabeled `break` leaves only a loop; strings have no terminating zero (s.toCString);
- a parameterless template is called with ().
"""
