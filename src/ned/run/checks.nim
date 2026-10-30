# the check that runs when a file is saved: which checker command suits a language, running it as a background job and
# turning its output into the file's problems, and the C compiler's check of the C in a Nim file's emit.
proc lspActiveFor(b: Buffer): bool =
  ## true when a language server for the buffer's language is running (it then reports the problems, so no checker
  ## command is run)
  for s in servers:
    if s.langId == b.lang.id and not s.dead: return true
  false

proc cargoRoot(start: string): string =
  ## the nearest folder at or above `start` (up to ten levels) that holds a Cargo.toml, or "" when there is none
  var d = start
  for _ in 0 .. 10:
    if fileExists(d / "Cargo.toml"): return d
    let up = parentDir(d)
    if up.len == 0 or up == d: break
    d = up
  ""

proc pluginLibFlag(lines: openArray[string]): string =
  ## ` --path:<the plugin library>` for a plugin's source — a file that uses nedplugin or nedlsp, which only ned knows
  ## where to find (it gives the same --path: to `nim e` and `nim c` when it runs the plugins) — else ""
  for l in lines:
    let t = l.strip
    if t.len == 0 or t[0] == '#': continue
    for w in ["nedplugin", "nedlsp"]:
      let i = t.find(w)
      if i >= 0 and (i == 0 or t[i - 1] notin IdentChars) and (i + w.len >= t.len or t[i + w.len] notin IdentChars):
        return " --path:" & quoteShell(plugLibDir())
  ""

proc pluginLibFlagOf(path: string): string =
  ## ` --path:` flag for a plugin source file on disk, from `pluginLibFlag`; "" when the file cannot be read
  try: pluginLibFlag(readFile(path).splitLines)
  except CatchableError: ""

proc checkCmdForPath(path, langId: string): (string, string) =
  ## on-save checker (command, cwd) used when no language server is attached
  let q = quoteShell(path)
  let dir = parentDir(path)
  case langId
  of "nim":
    if path.endsWith(".nim") and (nim3On() or (path in nim3Asked and nimonyExe().len > 0)):
      return (nimonyCheckCmd(path), dir)              # (Nim 3: its build files in ned's folder, not nimcache/ here)
    if path.endsWith(".nim") and haveExe("nim"):
      # a file another one includes is no module of its own: the module that includes it is checked (its errors
      # land on this file's lines)
      let top = nxTopIncluder(path)
      let main = if top.len > 0: top else: path
      let flags = " --hint:all:off --hint:XDeclaredButNotUsed:on --colors:off --listFullPaths:on" & pluginLibFlagOf(main)
      # (Nim 2.4 and newer: `nim nif` — the same check, and the compiler's reading of each module kept in ned's
      # folder, for the colours, type hints and Go to definition of the saved file; older Nim: nim check)
      if nim2NifOn(): return (nim2NifCheckCmd(flags, main), parentDir(main))
      return ("nim check" & flags & " " & quoteShell(main), parentDir(main))
  of "c":
    if haveExe("cc"): return ("cc -fsyntax-only -Wall " & q, dir)
  of "cpp":
    if haveExe("c++"): return ("c++ -fsyntax-only -Wall -std=c++17 " & q, dir)
  of "python":
    if haveExe("ruff"): return ("ruff check --output-format=concise --no-cache " & q, dir)
    if haveExe("python3"): return ("python3 -m py_compile " & q, dir)
  of "shellscript":
    if haveExe("bash"): return ("bash -n " & q, dir)
  of "javascript":
    if haveExe("node"): return ("node --check " & q, dir)
  of "go":
    if haveExe("gofmt"): return ("gofmt -e -l " & q, dir)
  of "rust":
    let r = cargoRoot(dir)
    if r.len > 0 and haveExe("cargo"): return ("cargo check --quiet --message-format short", r)
  else:
    # (another language's own check command: the "languages" setting's "check", a plugin's LangSpec)
    let l = langByName(langId)
    if l != nil and l.check.len > 0:
      let first = l.check.strip.split(' ')[0]
      if first.len > 0 and (haveExe(first) or first in ["sh", "cd"]):
        let c = l.check.replace("\"$file\"", q).replace("$file", q).replace("\"$dir\"", quoteShell(dir))
                       .replace("$dir", quoteShell(dir)).replace("$name", splitFile(path).name)
                       .replace("$tmp", tmpDir()).replace("$root", rootDir)
        return (c, dir)
  ("", "")

# the checker command and folder for a buffer's file and language
proc checkCmdFor(b: Buffer): (string, string) = checkCmdForPath(b.path, b.lang.id)

var unusedHints: Table[string, seq[(int, int, string)]]   # file → (line, col, name) the compiler says is unused
var covLines: Table[string, Table[int, bool]]            # test coverage: file → line → ran

func quotedNameOf(msg: string): string =
  ## the text between the first pair of single quotes in a compiler message (the name it is about), or "" when there is
  ## none
  let a = msg.find('\'')
  if a < 0: return ""
  let e = msg.find('\'', a + 1)
  if e < 0: return ""
  msg[a + 1 ..< e]

var cCheckPending: HashSet[string]

proc keepCDiags(path: string, ds: var seq[Diag]) =
  ## a Nim check knows nothing of the C in an emit: the C errors found before stay
  for d in diagsBuild.getOrDefault(path):
    if d.msg.startsWith("C: "): ds.add d

proc cEmitCheck(path: string) =
  ## the C a Nim file emits, checked by the C compiler on save (nim c -c, then the module's own C file with
  ## -fsyntax-only): its errors on the emit's lines, like Nim's own
  if path in cCheckPending or not haveExe("nim"): return
  let dir = privTmp("ccheck")
  cCheckPending.incl path
  let name = splitFile(path).name
  proc finish(ds: seq[Diag], known: bool) =
    ## ends the C check of the file: removes the temporary folder, and — unless the Nim did not compile, when the C is
    ## not known — replaces the file's "C: " problems in `diagsBuild` with `ds`, leaving its other problems, then asks
    ## for a redraw
    cCheckPending.excl path
    try: removeDir(dir)
    except CatchableError: discard
    if not known: return                       # the Nim did not compile: what the C says is not known
    var keep: seq[Diag]
    for d in diagsBuild.getOrDefault(path):
      if not d.msg.startsWith("C: "): keep.add d
    for d in ds: keep.add d
    if keep.len > 0: diagsBuild[path] = keep
    elif path in diagsBuild: diagsBuild.del path
    needRender = true
  discard startJob(jkCheck, "nim c -c --hints:off --colors:off --nimcache:" & quoteShell(dir) & " " & quoteShell(path),
                   parentDir(path), proc(j: Job) =
    if j.code != 0:
      finish(@[], false)
      return
    var cfile, ccmd = ""
    try:
      let js = parseFile(dir / name & ".json")
      for e in js{"compile"}:
        if e.kind == JArray and e.len >= 2:
          let f = e[0].getStr
          let fn = extractFilename(f)
          if fn == "@m" & name & ".nim.c" or fn == "@m" & name & ".nim.cpp" or fn == "@m" & name & ".nim.m":
            cfile = f
            ccmd = e[1].getStr
    except CatchableError: discard
    if cfile.len == 0 or ccmd.len == 0:
      finish(@[], true)
      return
    # the same compiler and flags, without making an object file
    var cmd = ccmd
    let o = cmd.rfind(" -o ")
    if o > 0: cmd = cmd[0 ..< o] & " " & quoteShell(cfile)
    let k = cmd.find(" -c ")
    if k > 0: cmd = cmd[0 ..< k] & " -fsyntax-only " & cmd[k + 4 .. ^1]
    discard startJob(jkCheck, cmd, parentDir(path), proc(j2: Job) =
      var ds: seq[Diag]
      for raw in j2.output.splitLines:
        let (ok, p, l, c, sev, m) = parseErrLine(stripAnsi(raw), dir)
        if ok and p == path and sev in {1, 2} and m.startsWith("C: "):
          ds.add Diag(line: l, col: c, eline: l, ecol: -1, sev: sev, msg: m, src: "cc")
      finish(ds, true)))

proc runCheck(b: Buffer) =
  ## runs the check that follows a save, when checking on save is on: a Nim file with C in an emit gets the C compiler's
  ## check too; nothing more when a language server covers the file; otherwise nimsuggest's check when ned's own Nim
  ## index does not serve the buffer, else the language's checker command on the file
  if b.path.len == 0 or not cfgCheckOnSave: return
  if b.lang != nil and b.lang.mode == lmNim and b.path.endsWith(".nim") and not b.largeOn:
    # C in an {.emit.}: checked by the C compiler too (with any Nim engine or language server)
    for l in b.lines:
      if "{.emit" in l or "emit:" in l:
        cEmitCheck(b.path)
        break
  if lspActiveFor(b): return
  if nsUsable(b) and not nimEngineOn(b):
    b.chkAt = b.changeId
    discard nsRequest(b, nsChk, Pos())
    return
  runCheckPath(b.path, b.lang.id, keepExamples = false)

proc runCheckPath(path, langId: string, keepExamples: bool) =
  ## check one file on disk; its problems from earlier builds and checks are replaced by what this finds
  ## (keepExamples: a file that did not change keeps its failed runnableExamples marks)
  let (cmd, cwd) = checkCmdForPath(path, langId)
  if cmd.len == 0: return
  let exe = cmd.firstWord
  if not codeTrusted(cwd) and runsProjectCode(@["sh", "-c", cmd]):
    askTrust(cwd, quiet = true)
    return
  if path in checkPending:
    pendingRecheck.incl path
    return
  checkPending.incl path
  # a check of the whole crate (cargo) also answers for the crate's other files that showed errors
  var covered = @[path]
  if cwd != parentDir(path):
    for p, ds in diagsBuild:
      if p != path and p.startsWith(cwd & "/") and ds.len > 0: covered.add p
  discard startJob(jkCheck, cmd, cwd, proc(j: Job) =
    checkPending.excl path
    var found = initTable[string, seq[Diag]]()
    for p in covered: found[p] = @[]
    if keepExamples:
      for d in diagsBuild.getOrDefault(path):
        if d.src == "examples": found[path].add d
    var pend = ("", -1, 0)
    var unusedFound = initTable[string, seq[(int, int, string)]]()
    unusedFound[path] = @[]
    var lastP = ""                 # the message just read: Nim continues some on the next lines (type mismatch)
    var extra = 0
    for raw in j.output.splitLines:
      let t = stripAnsi(raw)
      let (ok, p, l, c, sev, m) = parseErrLine(t, j.cwd)
      if ok and sev in {1, 2}:
        if m == "Traceback" or m.len == 0:
          pend = (p, l, c)
          lastP = ""
        else:
          found.mgetOrPut(p, @[]).add Diag(line: l, col: c, eline: l, ecol: -1, sev: sev, msg: m, src: exe)
          lastP = p
          extra = 0
        continue
      if ok:
        lastP = ""
        if "declared but not used" in m:
          unusedFound.mgetOrPut(p, @[]).add (l, c, quotedNameOf(m))
          continue
      elif lastP.len > 0 and extra < 60 and not t.startsWith("Hint:") and not t.startsWith("CC:") and
           not t.startsWith("Success") and found[lastP].len > 0:
        found[lastP][^1].msg.add "\n" & t
        inc extra
        continue
      let colon = t.rfind(':')
      if colon > 0 and colon + 1 < t.len and t[colon + 1 .. ^1].allDigits:
        let rp = resolvePath(t[0 ..< colon], j.cwd)
        if rp.len > 0:
          pend = (rp, parseInt(t[colon + 1 .. ^1]) - 1, 0)
          continue
      if pend[0].len > 0 and "Error" in t and ':' in t:
        found.mgetOrPut(pend[0], @[]).add Diag(line: pend[1], col: pend[2], eline: pend[1], ecol: -1, sev: 1,
                                                msg: t.strip, src: exe)
        pend = ("", -1, 0)
    for p, ds0 in found:
      var ds = ds0
      keepCDiags(p, ds)
      diagsBuild[p] = ds
      engineAgain(p)
      if langId in ["c", "cpp"]: cEngAgain(p)
    for p, us in unusedFound: unusedHints[p] = us
    if path in pendingRecheck:
      pendingRecheck.excl path
      runCheckPath(path, langId, keepExamples)
    needRender = true)
