# ── settings sync: your settings, key bindings, snippets, themes and dictionary words in one file — exported,
#    imported, or kept in a git repository of yours. API keys, tokens and MCP server env values never leave ──

const SyncFile = "ned-settings.json"

func secretName(k: string): bool =
  let l = k.toLowerAscii
  l in ["ai.apikey", "apikey", "api_key", "authorization"] or "token" in l or "secret" in l or "password" in l or
    "apikey" in l or "api_key" in l or l.endsWith(".key") or l == "key"

proc scrubSecrets(j: JsonNode, inEnv = false): JsonNode =
  ## a copy without secrets: secret-looking keys dropped, environment and header values emptied
  case j.kind
  of JObject:
    result = newJObject()
    for k, v in j:
      if inEnv: result[k] = %""
      elif secretName(k): continue
      else: result[k] = scrubSecrets(v, k in ["env", "headers"])
  of JArray:
    result = newJArray()
    for x in j: result.add scrubSecrets(x)
  else: result = j.copy

proc syncBundle(): JsonNode =
  var themes = newJObject()
  try:
    for kind, f in walkDir(themesDir()):
      if kind == pcFile and f.endsWith(".json"):
        try: themes[extractFilename(f)] = parseJson(readFile(f))
        except CatchableError: discard
  except OSError: discard
  var words = newJArray()
  try:
    if fileExists(spellUserFile()):
      for w in readFile(spellUserFile()).splitLines:
        if w.strip.len > 0: words.add %w.strip
  except CatchableError: discard
  var host = getEnv("HOSTNAME")
  if host.len == 0:
    try: host = readFile("/etc/hostname").strip
    except CatchableError: host = "this device"
  var macros = newJObject()               # your saved keyboard macros (macros.json)
  try:
    if fileExists(configDir() / "macros.json"):
      let j = parseJson(readFile(configDir() / "macros.json"))
      if j.kind == JObject: macros = j
  except CatchableError: discard
  %*{"ned": Version, "exported": $now(), "from": host, "settings": scrubSecrets(settingsUser), "themes": themes,
     "words": words, "macros": macros}

proc syncApply(bundle: JsonNode): string =
  ## an exported bundle over this device's settings (its secrets kept); "" when it worked, else why not
  if bundle == nil or bundle.kind != JObject or bundle{"settings"} == nil or bundle["settings"].kind != JObject:
    return "not a ned settings file"
  let p = configFile()
  try:
    createDir(parentDir(p))
    var text = if fileExists(p): readFile(p) else: defaultSettingsText()
    if fileExists(p): copyFile(p, p & ".bak-sync")
    for k, v0 in bundle["settings"]:
      if secretName(k): continue
      var v = v0
      if k == "ai.mcpServers" and v.kind == JObject:
        # empty env values from the other device: this device's own values stay
        let mine = settingsUser{"ai.mcpServers"}
        v = v.copy
        for srv, spec in v:
          if spec.kind == JObject and spec{"env"} != nil and spec["env"].kind == JObject:
            let env = spec["env"]
            var ks: seq[string]
            for ek, _ in env: ks.add ek
            for ek in ks:
              if env[ek].getStr.len == 0 and mine != nil and mine{srv, "env", ek} != nil: env[ek] = mine{srv, "env", ek}.copy
      text = updateSettingsText(text, k, v)
    writeFileSafe(p, text)
    if bundle{"themes"} != nil and bundle["themes"].kind == JObject:
      createDir(themesDir())
      for f, t in bundle["themes"]:
        let name = extractFilename(f)
        if name.endsWith(".json") and name.len > 5: writeFileSafe(themesDir() / name, t.pretty)
    if bundle{"words"} != nil and bundle["words"].kind == JArray and bundle["words"].len > 0:
      var have: HashSet[string]
      var cur = if fileExists(spellUserFile()): readFile(spellUserFile()) else: ""
      for w in cur.splitLines: have.incl w.strip
      for w in bundle["words"]:
        if w.getStr.strip.len > 0 and w.getStr.strip notin have:
          if cur.len > 0 and not cur.endsWith("\n"): cur.add "\n"
          cur.add w.getStr.strip & "\n"
      writeFileSafe(spellUserFile(), cur)
      spellReset()
    if bundle{"macros"} != nil and bundle["macros"].kind == JObject and bundle["macros"].len > 0:
      # macros: the other device's added to these (the same name: theirs)
      let mf = configDir() / "macros.json"
      var mine = newJObject()
      try:
        if fileExists(mf):
          let j = parseJson(readFile(mf))
          if j.kind == JObject: mine = j
      except CatchableError: discard
      for name, v in bundle["macros"]: mine[name] = v
      writeFileSafe(mf, mine.pretty & "\n")
      loadMacros()
  except CatchableError as e:
    return e.msg
  for b in bufs:
    if b.path == p and not b.dirty: reloadBuffer(b)
  reloadThemes()
  reloadSettings(true)
  ""

proc syncExport(path: string) =
  let f = path.expandTilde
  try:
    writeFileSafe(f, syncBundle().pretty & "\n", 0o600)
    info("Settings exported to " & tildePath(f) & " (API keys, tokens and MCP env values left out)")
  except CatchableError as e: error("Could not export: " & e.msg)

proc syncImport(path: string) =
  let f = path.expandTilde
  var j: JsonNode
  try: j = parseJson(readFile(f))
  except CatchableError as e:
    error("Could not read " & f & ": " & e.msg)
    return
  let why = syncApply(j)
  if why.len > 0: error("Could not import: " & why)
  else: info("Settings imported from " & tildePath(f) & " — the old file is config.json.bak-sync")

proc syncDir(): string = stateDir() / "settings-sync"

proc syncRepoOk(url: string): bool =
  ## a repository URL with a password or token in it would put that on a command line: not that
  let k = url.find("://")
  if k > 0 and url[k + 3 .. ^1].find('@') > 0 and url[k + 3 .. ^1].find('@') < max(0, url[k + 3 .. ^1].find('/')):
    error("Keep the token out of the URL — use an ssh URL (git@…) or git's credential helper")
    return false
  if url.len > 0 and not gitArgSafe(url):
    error("Not a repository URL: " & url)
    return false
  url.len > 0

proc syncGit(push: bool) =
  let url = sStr("sync.repository").strip
  if url.len == 0:
    askText("Your settings repository (a private git repository you can push to)", "", proc(t: string) =
      if syncRepoOk(t.strip):
        setSetting("sync.repository", %t.strip)
        syncGit(push))
    return
  if not syncRepoOk(url) or not haveExe("git"):
    if not haveExe("git"): error("git is not installed")
    return
  let d = syncDir()
  let q = quoteShell(d)
  var sh = "set -e; "
  if not dirExists(d / ".git"):
    sh.add "rm -rf " & q & "; git clone -q -- " & quoteShell(url) & " " & q & " 2>&1; "
  sh.add "cd " & q & "; B=$(git symbolic-ref --short HEAD 2>/dev/null || echo main); git fetch -q origin 2>&1 || true; "
  if push:
    try:
      createDir(d)
    except OSError: discard
    let (_, who, _) = runFilter("git config user.name", "", rootDir, 3000)
    let ident = if who.strip.len == 0: "-c user.name=ned -c user.email=ned@localhost " else: ""
    sh.add "if git rev-parse -q --verify \"origin/$B\" >/dev/null; then git reset -q --soft \"origin/$B\"; fi; " &
           "cp " & quoteShell(privDir() / SyncFile) & " " & SyncFile & "; git add " & SyncFile & "; " &
           "git " & ident & "commit -q -m \"ned settings\" || true; git push -q origin \"HEAD:$B\" 2>&1"
  else:
    sh.add "git reset -q --hard \"origin/$B\" 2>&1"
  if push:
    try: writeFileSafe(privDir() / SyncFile, syncBundle().pretty & "\n", 0o600)
    except CatchableError as e:
      error("Could not write the settings: " & e.msg)
      return
  info((if push: "Saving your settings to " else: "Loading your settings from ") & url & "…")
  let j = startJob(jkAux, sh, rootDir, proc(jj: Job) =
    if jj.code != 0:
      error("Settings sync failed: " & jj.output.strip.splitLines()[^1])
      return
    if push:
      info("Settings saved to " & url)
    else:
      let f = d / SyncFile
      if not fileExists(f):
        info("The repository has no " & SyncFile & " yet — Settings sync: push saves one")
        return
      let why = (try: syncApply(parseJson(readFile(f))) except CatchableError as e: e.msg)
      if why.len > 0: error("Could not load the settings: " & why)
      else: info("Settings loaded from " & url))
  if j == nil: error("Could not start git")
