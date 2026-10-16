# ── Run › Configurations, run with arguments ──

proc addRunConfigFromFile() =
  let b = buf()
  if b.path.len == 0:
    info("Open the file to run first")
    return
  let base = splitFile(b.path).name
  askText("Name of the configuration", base, proc(name: string) =
    let nm = name
    askText("Program arguments (optional — Enter for none)", " ", proc(args: string) =
      var cur = newJArray()
      try:
        let pj = parseFile(projectSettingsFile())
        if pj{"run.configs"} != nil and pj{"run.configs"}.kind == JArray: cur = pj{"run.configs"}
      except CatchableError: discard
      var c = %*{"name": nm, "main": relPath(b.path)}
      if args.strip.len > 0: c["args"] = %args.strip
      if b.lang.mode == lmNim:
        c["mode"] = %cfgNimMode
        c["backend"] = %cfgNimTarget
      var kept = newJArray()
      for x in cur:
        if x{"name"}.getStr != nm: kept.add x
      kept.add c
      if rootDir notin trustedDirs: trustedDirs.add rootDir      # you made it: this folder's run settings count
      setProjectSetting("run.configs", kept)
      activeRunConfig = nm
      info("Run configuration \"" & nm & "\" saved in .ned/settings.json — Alt+R runs it")))

proc cmdRunConfigs() =
  var items: seq[(string, string, Action)]
  items.add act((if activeRunConfig.len == 0: "✓ " else: "  ") & "The current file", "no configuration: Alt+R runs what you edit",
                proc() =
                  activeRunConfig = ""
                  info("Alt+R runs the current file"))
  for c in runConfigs():
    let nm = c{"name"}.getStr
    let (cmd, _) = runConfigCmd(c, false)
    capture nm:
      items.add act((if nm == activeRunConfig: "✓ " else: "  ") & "▶ " & nm, cmd, proc() =
        activeRunConfig = nm
        info("Alt+R runs \"" & nm & "\""))
  items.add act("+ Add a configuration for this file…", "name, arguments — saved in the project's settings",
                proc() = addRunConfigFromFile())
  items.add act("✎ Edit the configurations", "the run.configs setting in .ned/settings.json", proc() =
    if not fileExists(projectSettingsFile()): setProjectSetting("run.configs", newJArray())
    discard openFile(projectSettingsFile()))
  openActions("Run configurations", items)

proc runWithArgs() =
  let b = buf()
  if b.path.len == 0:
    info("Save the file first")
    return
  askText("Run " & extractFilename(b.path) & " with arguments", runArgsByFile.getOrDefault(b.path), proc(args: string) =
    runArgsByFile[b.path] = args
    discard saveAll()
    if b.lang.mode == lmNim: runCommand(nimCmd(b, true) & " " & args, parentDir(b.path))
    else:
      let r = b.lang.run
      if r.len == 0:
        info("No run command for " & b.lang.name)
        return
      runCommand(r.replace("\"$file\"", quoteShell(b.path)).replace("$file", quoteShell(b.path)) & " " & args,
                 parentDir(b.path)))
