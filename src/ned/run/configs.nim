# ── run configurations ("run.configs"): the project's ways to run, one of them chosen for Alt+R / ▶ ──

proc runConfigs(): seq[JsonNode] =
  ## the run configurations from the `run.configs` setting: its entries that are objects with a name
  let n = settingNode("run.configs")
  if n != nil and n.kind == JArray:
    for c in n:
      if c.kind == JObject and c{"name"}.getStr.len > 0: result.add c

proc runConfigNamed(name: string): JsonNode =
  ## the run configuration of that name, or nil when there is none
  for c in runConfigs():
    if c{"name"}.getStr == name: return c

proc runConfigCmd(c: JsonNode, build: bool): (string, string) =
  ## (shell command, folder) for a configuration; ("", "") when it says nothing runnable
  var mainP = c{"main"}.getStr
  if mainP.len == 0 and buf().path.len > 0: mainP = buf().path
  let main = if mainP.len == 0: "" elif mainP.isAbsolute: mainP else: rootDir / mainP
  let args = c{"args"}.getStr
  var env = ""
  let e = c{"env"}
  if e != nil and e.kind == JObject:
    for k, v in e:
      if k.validIdentifier: env.add k & "=" & quoteShell(v.getStr) & " "
  var cmd = c{"command"}.getStr
  if cmd.len > 0:
    cmd = cmd.replace("$file", quoteShell(main)).replace("$root", quoteShell(rootDir))
  elif main.endsWith(".nim") or main.endsWith(".nims"):
    let mode = c{"mode"}.getStr(cfgNimMode)
    cmd = "nim " & c{"backend"}.getStr(cfgNimTarget) & (if build: "" else: " -r") & " --hints:off" &
          (case mode
           of "release": " -d:release"
           of "danger": " -d:danger"
           else: "")
    for d in jitems(c{"defines"}): cmd.add " -d:" & quoteShell(d.getStr)
    if c{"flags"}.getStr.len > 0: cmd.add " " & c{"flags"}.getStr
    if cfgNimFlags.len > 0: cmd.add " " & cfgNimFlags
    cmd.add " " & quoteShell(main)
    if not build and args.len > 0: cmd.add " " & args
  elif main.len > 0:
    let r = detectLang(main, "").run
    if r.len == 0: return ("", "")
    cmd = r.replace("\"$file\"", quoteShell(main)).replace("$file", quoteShell(main)) & (if args.len > 0: " " & args else: "")
  if cmd.len == 0: return ("", "")
  let cw = c{"cwd"}.getStr
  let cwd = if cw.len > 0: (if cw.isAbsolute: cw else: rootDir / cw) elif main.len > 0: parentDir(main) else: rootDir
  (env & cmd, cwd.normalizedPath)

proc runWithConfig(c: JsonNode, build = false) =
  ## saves all files, then runs (or builds) a configuration's command in its folder; warns when it has no "main" or
  ## "command"
  discard saveAll()
  let (cmd, cwd) = runConfigCmd(c, build)
  if cmd.len == 0:
    warn("The run configuration \"" & c{"name"}.getStr & "\" has no \"main\" or \"command\"")
    return
  runCommand(cmd, cwd)

proc runCurrent(build = false) =
  ## what Alt+R (or Build) does: runs the chosen run configuration when there is one (forgetting it if it was removed
  ## from the settings); otherwise the current file by its language's run or build command — a Nim file through
  ## `nimCmd`, a Rust project with cargo, C with make or cmake for a build, Python from the project's virtual
  ## environment when it has one, HTML in the browser. With nothing known to run, it asks for a command.
  if activeRunConfig.len > 0:
    let c = runConfigNamed(activeRunConfig)
    if c != nil:
      runWithConfig(c, build)
      return
    activeRunConfig = ""                 # it was removed from the settings
  let b = buf()
  if b.path.len == 0 and b.title.len == 0:
    openPrompt(pRunCmd, "Run command", lastRunCmd)
    return
  var cmd = if build: b.lang.build else: b.lang.run
  let dir = if b.path.len > 0: parentDir(b.path) else: rootDir
  if b.lang.mode == lmNim and b.path.len > 0: cmd = nimCmd(b, not build)
  if not build and b.lang.id in cfgUserRun: cmd = cfgUserRun[b.lang.id]
  case b.lang.id
  of "rust":
    var d = dir
    for _ in 0 .. 8:
      if fileExists(d / "Cargo.toml"):
        runCommand(if build: "cargo build" else: "cargo run", d)
        return
      if parentDir(d) == d or parentDir(d).len == 0: break
      d = parentDir(d)
  of "c", "cpp":
    if build and fileExists(rootDir / "Makefile"):
      runCommand("make", rootDir)
      return
    if build and fileExists(rootDir / "CMakeLists.txt"):
      runCommand("cmake -S . -B build && cmake --build build", rootDir)
      return
  of "python":
    for v in [rootDir / ".venv" / "bin" / "python", rootDir / "venv" / "bin" / "python"]:
      if fileExists(v):
        cmd = quoteShell(v) & " \"$file\""
        break
    if findExe("python3").len == 0: cmd = cmd.replace("python3", "python")
  of "html":
    if b.path.len > 0:
      if b.dirty: discard b.saveBuffer()
      openInBrowser(b.path)
      return
  else: discard
  if cmd.len == 0 or b.path.len == 0:
    openPrompt(pRunCmd, "Run command", lastRunCmd)
    return
  runCommand(expandCmd(cmd, b), dir)
