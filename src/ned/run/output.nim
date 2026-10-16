proc parseErrLine(s, cwd: string): (bool, string, int, int, int, string) =
  ## recognises Nim, GCC/Clang/Go/TS, Rust and Python locations. sev: 1 err, 2 warn, 3 info
  let t = s.strip()
  let p1 = t.find('(')
  if p1 > 0:
    let p2 = t.find(')', p1)
    if p2 > p1:
      let inner = t[p1+1 ..< p2].split(',')
      if inner.len in 1..2 and inner[0].strip.allDigits and (inner.len == 1 or inner[1].strip.allDigits):
        let path = resolvePath(t[0 ..< p1], cwd)
        if path.len > 0:
          let l = parseInt(inner[0].strip) - 1
          let c = if inner.len > 1: parseInt(inner[1].strip) - 1 else: 0
          let rest = if p2 + 2 <= t.len: t[min(p2 + 2, t.len) .. ^1] else: ""
          if rest.startsWith("Error:"): return (true, path, l, c, 1, rest[6..^1].strip)
          if rest.startsWith("Warning:"): return (true, path, l, c, 2, rest[8..^1].strip)
          return (true, path, l, c, 3, rest)
  if t.startsWith("--> ") or t.startsWith("File \""):
    if t.startsWith("File \""):
      let e = t.find('"', 6)
      if e > 6:
        let path = resolvePath(t[6 ..< e], cwd)
        let k = t.find("line ", e)
        if path.len > 0 and k > 0:
          var d = k + 5
          var num = ""
          while d < t.len and t[d] in Digits:
            num.add t[d]
            inc d
          if num.len > 0: return (true, path, parseInt(num) - 1, 0, 1, "Traceback")
    else:
      let parts = t[4..^1].split(':')
      if parts.len >= 2 and parts[1].allDigits:
        let path = resolvePath(parts[0], cwd)
        if path.len > 0:
          let c = if parts.len >= 3 and parts[2].allDigits: parseInt(parts[2]) - 1 else: 0
          return (true, path, parseInt(parts[1]) - 1, c, 1, "see above")
  let lk = t.find(": line ")
  if lk > 0:
    var d = lk + 7
    var num = ""
    while d < t.len and t[d] in Digits:
      num.add t[d]
      inc d
    let path = resolvePath(t[0 ..< lk], cwd)
    if num.len > 0 and path.len > 0:
      return (true, path, parseInt(num) - 1, 0, 1, t[min(d + 2, t.len) .. ^1].strip)
  let parts = t.split(':', 3)
  if parts.len >= 3 and parts[1].allDigits:
    let path = resolvePath(parts[0], cwd)
    if path.len > 0:
      var c = 0
      var rest = ""
      if parts.len >= 4 and parts[2].allDigits:
        c = parseInt(parts[2]) - 1
        rest = parts[3].strip
      else:
        rest = parts[2 .. ^1].join(":").strip
      var sev = 1
      if rest.startsWith("warning"): sev = 2
      elif rest.startsWith("note") or rest.startsWith("info"): sev = 3
      for pre in ["fatal error:", "error:", "warning:", "note:"]:
        if rest.startsWith(pre): rest = rest[pre.len .. ^1].strip
      if isNimGenC(path):
        # C code from an emit: its line in the .nim file, the C file's line named in the message
        let (np, nl, nc) = mapGenC(path, cwd, parseInt(parts[1]) - 1, max(0, c))
        if np.len > 0:
          return (true, np, nl, nc, sev, "C: " & rest & "  [" & extractFilename(path) & ":" & parts[1] & "]")
      return (true, path, parseInt(parts[1]) - 1, max(0, c), sev, rest)
  (false, "", 0, 0, 0, "")

proc addPanelLine(pl: PanelLine) =
  panelStore[pkOutput].add pl
  if panelStore[pkOutput].len > 22000:
    # drop the oldest 2000 at once: one move per 2000 lines instead of a 20000-line shift per line
    panelStore[pkOutput] = panelStore[pkOutput][2000 .. ^1]
    panelSelA[pkOutput] = max(0, panelSelA[pkOutput] - 2000)
    panelScrollA[pkOutput] = max(0, panelScrollA[pkOutput] - 2000)
  needRender = true

proc addRunLine(j: Job, raw: string) =
  var s = stripAnsi(raw)
  for r in remotes:                         # the server's paths in compiler messages: the local copies
    if r.absPath.len > 1 and r.absPath in s: s = s.replace(r.absPath & "/", r.mirror & "/")
  if s.endsWith('\r'): s.setLen(s.len - 1)
  let cr = s.rfind('\r')
  if cr >= 0: s = s[cr + 1 .. ^1]
  var pl = PanelLine(text: s, line: -1)
  let (ok, path, l, c, sev, m) = parseErrLine(s, j.cwd)
  if ok:
    pl.path = path
    pl.line = l
    pl.col = c
    pl.sev = sev
    if sev in {1, 2}:
      diagsBuild.mgetOrPut(path, @[]).add Diag(line: l, col: c, eline: l, ecol: -1, sev: sev, msg: m, src: "build")
  addPanelLine(pl)

proc searchLine(j: Job, raw: string)

proc jobChunk(j: Job, chunk: string) =
  if j.kind notin {jkSearch, jkAi} and j.output.len < 8_000_000: j.output.add chunk
  if j.kind == jkAi:
    let data = j.partial & chunk
    let parts = data.split('\n')
    for k in 0 ..< parts.high: aiLine(parts[k])
    j.partial = parts[^1]
    return
  if j.kind in {jkRun, jkSearch}:
    let data = j.partial & chunk
    let parts = data.split('\n')
    for k in 0 ..< parts.high:
      if j.kind == jkRun: addRunLine(j, parts[k]) else: searchLine(j, parts[k])
    j.partial = parts[^1]

proc runningJob(): Job =
  for j in jobs:
    if j.kind == jkRun and not j.done: return j
  nil

proc stopRun() =
  let j = runningJob()
  if j == nil:
    info("Nothing is running")
    return
  killProc(j.pr)
  addPanelLine(PanelLine(text: "■ Stopped", sev: 2, line: -1))

proc expandCmd(cmd: string, b: Buffer): string =
  result = cmd
  if b != nil and b.path.len > 0:
    result = result.replace("$file", b.path).replace("$dir", parentDir(b.path))
      .replace("$name", splitFile(b.path).name)
  result = result.replace("$tmp", tmpDir()).replace("$root", rootDir)

proc runCommand(cmd0, cwd: string, after: proc(code: int) {.closure.} = nil) =
  ## run a command with its output in the Output panel (`after`: told the exit code when it ends)
  if cmd0.strip.len == 0: return
  let ri = if remotes.len > 0: remoteOf(cwd) else: -1
  # a remote folder: on the server, once the saves are there
  let cmd = if ri >= 0: remoteWaitPushes() & remoteCommand(remotes[ri], cmd0, cwd) else: cmd0
  let onHost = if ri >= 0: "  (on " & remotes[ri].host & ")" else: ""
  discard saveAll()
  let r = runningJob()
  if r != nil: killProc(r.pr)
  diagsBuild.clear()
  lastRunCmd = cmd0
  panelKind = pkOutput
  panelLines = @[PanelLine(text: "▶ " & cmd0 & onHost, sev: 5, line: -1)]
  panelTitle = "OUTPUT"
  panelOpen = true
  panelFollow = true
  panelSel = 0
  let j = startJob(jkRun, cmd, cwd, proc(j: Job) =
    if j.partial.len > 0:
      addRunLine(j, j.partial)
      j.partial = ""
    let dt = float(msSince(j.started)) / 1000.0
    var errs = 0
    for ds in diagsBuild.values:
      for d in ds:
        if d.sev == 1: inc errs
    if " install" in cmd or cmd.startsWith("pkg ") or cmd.startsWith("pip"):
      exeCache.clear()        # newly installed tools (nimlangserver, nph, …) get picked up
    if j.code == 0:
      addPanelLine(PanelLine(text: "✓ Finished in " & formatFloat(dt, ffDecimal, 1) & "s", sev: 4, line: -1))
    else:
      addPanelLine(PanelLine(text: "✗ Exit code " & $j.code & " after " & formatFloat(dt, ffDecimal, 1) & "s" &
        (if errs > 0: " · " & $errs & " error(s) — Alt+N jumps to the next" else: ""), sev: 1, line: -1))
    if ri >= 0 and ri < remotes.len: remoteSync(ri)       # what it changed on the server comes back
    needRender = true
    if after != nil: after(j.code))
  if j == nil: return
  info("Running: " & cmd0 & onHost)

proc probeTool(tool, args: string) =
  if not haveExe(tool): return
  discard startJob(jkAux, tool & " " & args & " 2>&1", rootDir, proc(j: Job) =
    for l in j.output.splitLines:
      for w in l.splitWhitespace:
        let v = w.strip(chars = {'v', 'V', ',', '(', ')', '[', ']'})
        if v.len >= 3 and v[0] in Digits and '.' in v:
          toolVersions[tool] = v
          needRender = true
          return)

proc probeTools() =
  ## tool versions for the welcome page and the Nim panel, fetched in the background
  probeTool("nim", "--version")
  probeTool("nimble", "--version")
  probeTool("git", "--version")
  probeTool("rg", "--version")
  probeTool("nimony", "--version")

proc nimCmd(b: Buffer, run: bool): string =
  let f = quoteShell(b.path)
  let mode = case cfgNimMode
    of "release": " -d:release"
    of "danger": " -d:danger"
    else: ""
  if b.path.endsWith(".nims"): return "nim e --hints:off " & f
  if b.path.endsWith(".nimble"): return (if run: "nimble run" else: "nimble build")
  if cfgNimCompiler == "nimony" and findExe("nimony").len > 0:
    return "nimony c" & (if run: " -r" else: "") & mode & " " & f
  "nim " & cfgNimTarget & (if run: " -r" else: "") & " --hints:off" & mode &
    (if cfgNimFlags.len > 0: " " & cfgNimFlags else: "") & " " & f

proc openInBrowser(path: string) =
  let isUrl = "://" in path
  for opener in (if isUrl: @["termux-open-url", "wslview", "xdg-open", "open"] else: @["termux-open", "wslview", "xdg-open", "open"]):
    if findExe(opener).len > 0:
      discard startJob(jkAux, opener & " " & quoteShell(path), (if isUrl: rootDir else: parentDir(path)))
      info("Opening " & (if isUrl: path else: extractFilename(path)) & " in the browser")
      return
  error("No opener found (Termux: pkg install termux-tools)")
