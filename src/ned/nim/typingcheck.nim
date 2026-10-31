# ── errors while you type, from the compiler: the unsaved text checked as it is ──
#    `nim check -` reads the module from stdin. Run in the file's folder, it sees the same imports (relative ones
#    too), the same nim.cfg / config.nims and the same nimble packages as a check of the file itself — so ned
#    hands it a private copy of the buffer after a pause in typing, and puts what it says on the buffer. With Nim
#    2.4 the check is `nim nif -`: the same messages, and the compiler's reading of the text too (nimnif.nim).

var
  typingChecks: Table[string, (int, MonoTime, string)]   # path → (the text's changeId, started, the copy)
  typingCheckMs: Table[string, int]                      # path → how long its last check took (ms)
  typingSig: Table[string, Hash]                         # path → the code the last check was of (see typingCodeSig)
  typingRuns, typingSkips = 0                            # (the performance report: checks run, and not needed)

proc typingCodeSig(b: Buffer): Hash =
  ## what the compiler sees of the text: its lines without their comments and trailing spaces — a change to a
  ## comment, or to spaces at a line's end, needs no new check (the line count is in it: problems keep their lines)
  var h: Hash = 0
  h = h !& b.lines.len
  for l in b.lines:
    var e = l.len
    if "\"\"\"" notin l and "#[" notin l and "]#" notin l:     # (a long string or a block comment: the whole line)
      var i = 0
      var inStr = false
      while i < l.len:
        let c = l[i]
        if inStr:
          if c == '\\': inc i
          elif c == '"': inStr = false
        elif c == '"': inStr = true
        elif c == '\'' and i + 2 < l.len:
          # a character literal ('#', '\'') — not the start of a comment
          let close = l.find('\'', i + 1)
          if close > i and close - i <= 4: i = close
        elif c == '#':
          e = i
          break
        inc i
    var k = e
    while k > 0 and l[k - 1] in {' ', '\t'}: dec k
    h = h !& hash(l.toOpenArray(0, k - 1))
  !$h


proc typingCheckUsable(b: Buffer): bool =
  ## should the compiler check this buffer's unsaved text while you type (rather than nimsuggest, or nothing)?
  if b.lang == nil or b.lang.mode != lmNim or b.path.len == 0 or not b.path.endsWith(".nim") or b.largeOn or
     b.readOnly or not (if nim3On(): nimonyExe().len > 0 else: haveExe("nim")) or lspActiveFor(b) or
     not nimEngineOn(b):
    return false
  if not codeTrusted(parentDir(b.path)):
    askTrust(parentDir(b.path), quiet = true)          # (the compiler runs the folder's config.nims and macros)
    return false
  let how = sStr("nim.liveDiagnosticsFrom")
  if how == "nimsuggest": return false
  let took = typingCheckMs.getOrDefault(b.path, 0)
  # (a big project whose check takes long: nimsuggest, which keeps the project in memory, answers faster)
  if how != "compiler" and took > 10_000 and nsUsable(b): return false
  if how != "compiler" and took > 30_000: return false
  for l in b.lines:
    if l.startsWith("<<<<<<< ") or l == "<<<<<<<": return false     # (a merge to finish first: no errors yet)
  if nim3On(): return nxIncluderOf(b.path).len == 0       # (Nim 3: a module of its own; an included part on save)
  # a file another one includes is checked inside it (includerCopy): one level of include
  let inc = nxIncluderOf(b.path)
  inc.len == 0 or nxIncluderOf(inc).len == 0

proc parseNimCheck(output, cwd, stdinPath: string): (Table[string, seq[Diag]], Table[string, seq[(int, int, string)]]) =
  ## `nim check`'s errors, warnings and "declared but not used" hints by file; `stdinPath`: the file that
  ## "stdinfile.nim" stands for
  var lastP = ""
  var extra = 0
  for raw in output.splitLines:
    var t = stripAnsi(raw)
    if stdinPath.len > 0 and t.startsWith("stdinfile.nim("): t = stdinPath & t["stdinfile.nim".len .. ^1]
    var (ok, p, l, c, sev, m) = parseErrLine(t, cwd)
    if stdinPath.len > 0 and "stdinfile" in m:
      # (the module read from stdin is "stdinfile" to the compiler: its own name in the message — `for type
      # demo.Config [type declared in demo.nim(3, 6)]`, not `stdinfile.Config`)
      let fname = extractFilename(stdinPath)
      m = m.replace("stdinfile.nim", fname).replace("stdinfile.", fname.changeFileExt("") & ".")
    if ok and sev in {1, 2} and m.len > 0 and m != "Traceback":
      result[0].mgetOrPut(p, @[]).add Diag(line: l, col: c, eline: l, ecol: -1, sev: sev, msg: m, src: "nim")
      lastP = p
      extra = 0
    elif ok:
      lastP = ""
      if "declared but not used" in m: result[1].mgetOrPut(p, @[]).add (l, c, quotedNameOf(m))
    elif lastP.len > 0 and extra < 60 and t.len > 0 and not t.startsWith("Hint:") and not t.startsWith("CC:") and
         not t.startsWith("Success"):
      # (a type mismatch goes on over the next lines)
      result[0][lastP][^1].msg.add "\n" & t
      inc extra

proc includerCopy(b: Buffer, copy: string): (string, string) =
  ## a file another one includes is no module of its own: (the module that includes it, that module's text with
  ## the `include` of this file pointing at `copy`, the private copy of the unsaved text) — so the compiler
  ## checks the unsaved text where it belongs. ("", "") when that cannot be done: the includer is itself
  ## included, or the file imports or includes by a path of its own (looked for next to the copy, that would fail)
  let inc = nxIncluderOf(b.path)
  if inc.len == 0 or nxIncluderOf(inc).len > 0: return
  for l in b.lines:
    let t = l.strip
    if (t.startsWith("import ") or t.startsWith("include ") or t.startsWith("from ")) and
       not (t.startsWith("import std/") or t.startsWith("from std/")):
      return
  let g = nxLoad(inc)
  if g == nil: return
  let bi = bufIndexByPath(inc)
  var lines: seq[string]
  try: lines = if bi >= 0: bufs[bi].lines else: readFile(inc).splitLines
  except CatchableError: return
  var target = -1
  for im in g.imports:
    if im.isInclude and nxResolve(inc, im.spec) == b.path: target = im.line
  if target < 0 or target >= lines.len or ';' in lines[target] or not lines[target].strip.startsWith("include "):
    return
  var specs: seq[string]
  for im in g.imports:
    if im.isInclude and im.line == target:
      specs.add (if nxResolve(inc, im.spec) == b.path: "\"" & copy & "\"" else: im.spec)
  lines[target] = spaces(leadWs(lines[target])) & "include " & specs.join(", ")
  (inc, lines.join("\n") & "\n")

proc typingCheckNimony(b: Buffer) =
  ## Nim 3: `nimony check` reads no stdin — a copy of the text in ned's own folder, its relative imports made
  ## absolute and the file's folder on the search path, under the file's own name (nimony's build files stay)
  let id = b.changeId
  let dir = privDir() / "nimony" / ("typing-" & nimonyKey(b.path))
  let copy = dir / extractFilename(b.path)
  try:
    createDir(dir)
    writeFile(copy, nimonyCopyText(b.lines, parentDir(b.path)))
  except CatchableError: return
  b.chkAt = id
  let path = b.path
  let bid = b.id
  typingChecks[path] = (id, getMonoTime(), copy)
  typingSig[path] = b.typingCodeSig()
  inc typingRuns
  discard startJob(jkCheck, quoteShell(nimonyExe()) & " check " & nimonyArgs() & " --path:" &
                            quoteShell(parentDir(path)) & " " & quoteShell(copy) & " 2>&1", dir, proc(j: Job) =
    let st = typingChecks.getOrDefault(path)
    typingChecks.del path
    typingCheckMs[path] = int(msSince(st[1]))
    var (found, _) = parseNimCheck(j.output, j.cwd, "")
    let x = bufById(bid)
    if x == nil or x.changeId != id: return        # (typed since: the next pause checks the new text)
    var mine: seq[Diag]
    for k, v in found:
      if k == copy or (extractFilename(k) == extractFilename(copy) and k.startsWith(dir)): mine.add v
    diagsBuild[path] = mine
    engineAgain(path)
    needRender = true)

proc typingCheck(b: Buffer) =
  ## has the compiler check the buffer's unsaved text after a pause in typing (one check per file at a time): nimony in
  ## a Nim 3 project; else `nim check -` on a private copy (for an included file, inside the module that includes it),
  ## run in the file's folder. When it ends — and the text has not changed meanwhile — the problems and the unused-name
  ## hints found for the file replace the build ones
  if b.path in typingChecks: return
  if nim3On():
    b.typingCheckNimony()
    return
  let id = b.changeId
  let copy = privTmp("typing") & ".nim"
  # an included file: checked inside the module that includes it (that module's text, on stdin, includes the copy)
  var (main, mainText) = ("", "")
  if nxIncluderOf(b.path).len > 0:
    (main, mainText) = includerCopy(b, copy)
    if main.len == 0:
      b.chkAt = id
      return
  let mainCopy = if main.len > 0: privTmp("typingmain") & ".nim" else: ""
  try:
    writeFile(copy, b.lines.join("\n") & (if b.noEol: "" else: "\n"))
    if main.len > 0: writeFile(mainCopy, mainText)
  except CatchableError: return
  b.chkAt = id
  let path = b.path
  let bid = b.id
  typingChecks[path] = (id, getMonoTime(), copy)
  # (a plugin's source: the plugin library's folder, as ned gives it to the plugins — else `import nedplugin` fails)
  let libFlag = if main.len > 0: pluginLibFlag(mainText.splitLines) else: pluginLibFlag(b.lines)
  let folder = parentDir(if main.len > 0: main else: path)
  # (Nim 2.4: `nim nif`, with the same messages and the compiler's reading of the text — nimnif.nim)
  let nifCmd = nifTypingCmd(folder)
  let alias = if main.len > 0: copy else: folder / "stdinfile.nim"
  let started = getTime()
  let job = startJob(jkCheck, (if nifCmd.len > 0: nifCmd & " " else: "nim check ") &
                            "--hint:all:off --hint:XDeclaredButNotUsed:on --colors:off " &
                            "--listFullPaths:on" & libFlag & " - < " & quoteShell(if main.len > 0: mainCopy else: copy),
                   folder, proc(j: Job) =
    if nifCmd.len > 0: nifTypingDone(folder)
    let st = typingChecks.getOrDefault(path)
    typingChecks.del path
    typingCheckMs[path] = int(msSince(st[1]))
    # (read while the copies are still there: a message's file is looked up)
    var (found, unused) = parseNimCheck(j.output, j.cwd, (if main.len > 0: main else: path))
    try:
      removeFile(copy)
      if mainCopy.len > 0: removeFile(mainCopy)
    except CatchableError: discard
    let x = bufById(bid)
    if x == nil or x.changeId != id: return        # (typed since: the next pause checks the new text)
    if main.len > 0:
      # what the compiler says about the copy is this file's (its path may come back through a symlink: by name)
      let cn = extractFilename(copy)
      var mineD: seq[Diag]
      var mineU: seq[(int, int, string)]
      for k, v in found:
        if extractFilename(k) == cn: mineD = v
      for k, v in unused:
        if extractFilename(k) == cn: mineU = v
      found[path] = mineD
      unused[path] = mineU
    var mine = found.getOrDefault(path)
    keepCDiags(path, mine)
    diagsBuild[path] = mine                          # (other files' errors: from their own checks, on disk)
    engineAgain(path)
    unusedHints[path] = unused.getOrDefault(path)
    if nifCmd.len > 0: nifTypingRead(x, folder, alias, started, j.output)
    needRender = true)
  if job == nil and nifCmd.len > 0: nifTypingDone(folder)

proc recheckBuildErrors(saved: Buffer) =
  ## after a save: the errors other files show from a build or check may be gone now (the fix was in this
  ## file), and with a language server this file's own build errors are not re-checked by runCheck — so
  ## check again every file of the same language that shows an error from a build or check
  if not cfgCheckOnSave or saved.path.len == 0 or saved.lang == nil: return
  let fam = if saved.lang.id in ["c", "cpp"]: @["c", "cpp"] else: @[saved.lang.id]
  let lspHere = lspActiveFor(saved)
  var todo: seq[(string, string)]
  var cmds: HashSet[string]
  for p, ds in diagsBuild:
    if todo.len >= 4: break
    var bad = false
    for d in ds:
      if d.sev == 1 and d.src != "examples": bad = true
    if not bad: continue
    if p == saved.path and not lspHere: continue          # runCheck has just checked it
    let i = bufIndexByPath(p)
    if i >= 0 and bufs[i].dirty: continue                 # its own save checks it; the disk copy is old
    let lid = if i >= 0: bufs[i].lang.id else: detectLang(p, "").id
    if lid notin fam or not fileExists(p): continue
    let (cmd, cwd) = checkCmdForPath(p, lid)
    if cmd.len == 0 or (cmd.startsWith("cargo ") and cwd in cmds): continue
    cmds.incl cwd
    todo.add (p, lid)
  for (p, lid) in todo: runCheckPath(p, lid, keepExamples = p != saved.path)

proc findGitRoot(start: string): string =
  ## the folder holding the .git of a path, looked for upwards (up to 40 levels); for a remote folder, its local mirror
  ## when the server has a repository; "" when there is none
  if remotes.len > 0:
    # a remote folder's local copy: its repository is on the server (git runs there), when it has one
    let ri = remoteOf(start)
    if ri >= 0: return (if remotes[ri].git: remotes[ri].mirror else: "")
  var d = start
  for _ in 0 .. 40:
    if dirExists(d / ".git") or fileExists(d / ".git"): return d
    let p = parentDir(d)
    if p == d or p.len == 0: break
    d = p
  ""
