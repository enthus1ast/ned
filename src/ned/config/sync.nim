# ── settings sync: your settings, key bindings, snippets, themes and dictionary words in one file — exported,
#    imported, or kept in a git repository of yours. API keys, tokens and MCP server env values never leave ──

const SyncFile = "ned-settings.json"

func secretName(k: string): bool =
  ## whether a settings key looks like a secret (an API key, token, password, authorization), so that it never goes into
  ## a bundle
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
  ## this device's settings bundle as JSON: ned's version, when and from which host, the settings the user set (secrets
  ## scrubbed), the theme files, the spelling words and the saved keyboard macros
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
  ## writes this device's bundle to a file the owner alone can read and says so (API keys, tokens and MCP env values are
  ## left out); a failure is shown as an error
  let f = path.expandTilde
  try:
    writeFileSafe(f, syncBundle().pretty & "\n", 0o600)
    info("Settings exported to " & tildePath(f) & " (API keys, tokens and MCP env values left out)")
  except CatchableError as e: error("Could not export: " & e.msg)

proc syncImport(path: string) =
  ## reads a bundle from a file and applies it (syncApply), saying that the old settings file is kept as
  ## config.json.bak-sync, or why it could not
  let f = path.expandTilde
  var j: JsonNode
  try: j = parseJson(readFile(f))
  except CatchableError as e:
    error("Could not read " & f & ": " & e.msg)
    return
  let why = syncApply(j)
  if why.len > 0: error("Could not import: " & why)
  else: info("Settings imported from " & tildePath(f) & " — the old file is config.json.bak-sync")

# the folder where the settings repository is cloned, under ned's state folder
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
  ## one-way sync with the settings git repository (sync.repository, asked for when empty): push writes the bundle and
  ## pushes it as one commit on top of the remote's, otherwise the remote's bundle is fetched and applied here. git runs
  ## as a background job, and the outcome is told in the message line
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

# ── both ways: this device's changes and the other's, merged key by key against what they both had at the last
#    sync (a key changed on both: this device's kept, and you are told); your plugins listed (installed on the
#    other device when you say so — each asks its permissions there); on start and on quit when sync.auto says ──

# where the bundle both devices had at the last sync is kept — the base of the three-way merge
proc syncBasePath(): string = stateDir() / "settings-sync-base.json"

proc syncExcluded(): HashSet[string] =
  ## sync.exclude: the settings that stay on this device
  for x in jitems(sval("sync.exclude")):
    if x.kind == JString: result.incl x.getStr

proc syncPluginList(): JsonNode =
  ## your plugins (not ned's own: plugins.bundled is a setting), each with the git address it came from
  result = newJArray()
  let root = configDir() / "plugins"
  if not dirExists(root): return
  var names: seq[string]
  try:
    for kind, d in walkDir(root):
      if kind in {pcDir, pcLinkToDir}: names.add extractFilename(d)
  except OSError: return
  names.sort()
  for n in names:
    var url = ""
    try:
      var inOrigin = false
      for l in readFile(root / n / ".git" / "config").splitLines:
        let t = l.strip
        if t.startsWith("["): inOrigin = t == "[remote \"origin\"]"
        elif inOrigin and t.startsWith("url"):
          let k = t.find('=')
          if k > 0: url = t[k + 1 .. ^1].strip
    except CatchableError: discard
    result.add %*{"name": n, "url": url}

# (the other device's plugins offered here once: not offered again at each sync — and still listed in this device's
# bundle, so that not installing one here does not take it off the list, and off the other device's next sync)
proc syncOfferedPath(): string = stateDir() / "settings-sync-offered.json"

proc syncOffered(): OrderedTable[string, string] =
  ## the plugins offered here: name → its git address
  try:
    if fileExists(syncOfferedPath()):
      for k, v in parseJson(readFile(syncOfferedPath())): result[k] = v.getStr
  except CatchableError: discard

proc syncOfferedSave(t: OrderedTable[string, string]) =
  ## remembers which of the other device's plugins have been offered here
  var j = newJObject()
  for k, v in t: j[k] = %v
  try: writeFileSafe(syncOfferedPath(), j.pretty & "\n", 0o600)
  except CatchableError: discard

proc syncNotInstalled(): seq[(string, string)] =
  ## the plugins offered here and not installed: (name, address)
  var have: HashSet[string]
  for x in jitems(syncPluginList()): have.incl x{"name"}.getStr
  for n, u in syncOffered():
    if n notin have and u.len > 0: result.add (n, u)

proc syncBundleNow(): JsonNode =
  ## this device's bundle, its plugins too, without what sync.exclude keeps here
  result = syncBundle()
  let ex = syncExcluded()
  if ex.len > 0 and result{"settings"} != nil:
    for k in ex:
      if result["settings"].hasKey(k): result["settings"].delete(k)
  var ps = syncPluginList()
  for (n, u) in syncNotInstalled(): ps.add %*{"name": n, "url": u}
  result["plugins"] = ps

func syncSame(a, b: JsonNode): bool =
  ## whether two JSON values are the same (both absent, or both present and written alike)
  (a == nil and b == nil) or (a != nil and b != nil and $a == $b)

proc syncMergeObj(base, mine, theirs: JsonNode, conflicts: var seq[string], what: string): JsonNode =
  ## two objects key by key against what both had: a key one side changed takes that side's value (a removal
  ## too); changed on both, this device's (a removal loses to a change)
  result = newJObject()
  var keys: seq[string]
  for j in [mine, theirs, base]:
    if j != nil and j.kind == JObject:
      for k, _ in j:
        if k notin keys: keys.add k
  for k in keys:
    let b0 = if base != nil and base.kind == JObject: base{k} else: nil
    let m = if mine != nil and mine.kind == JObject: mine{k} else: nil
    let t = if theirs != nil and theirs.kind == JObject: theirs{k} else: nil
    if syncSame(m, t):
      if m != nil: result[k] = m
    elif syncSame(m, b0):
      if t != nil: result[k] = t
    elif syncSame(t, b0):
      if m != nil: result[k] = m
    else:
      conflicts.add what & k
      result[k] = (if m != nil: m else: t)

proc syncMergeSet(base, mine, theirs: JsonNode, key: string): JsonNode =
  ## lists (words; plugins by name): what either has, without what one of them removed since
  proc keyOf(x: JsonNode): string = (if key.len > 0: x{key}.getStr else: x.getStr)
  proc names(j: JsonNode): HashSet[string] =
    ## the keys of the items of a list (the item itself when it is a string)
    for x in jitems(j): result.incl keyOf(x)
  let b0 = names(base)
  let m = names(mine)
  let t = names(theirs)
  result = newJArray()
  var seen: HashSet[string]
  for j in [mine, theirs]:
    for x in jitems(j):
      let k = keyOf(x)
      if k.len == 0 or k in seen: continue
      if (k in b0 and k notin m) or (k in b0 and k notin t): continue      # (removed on one side)
      seen.incl k
      result.add x

proc syncMerge(base, mine, theirs: JsonNode): (JsonNode, seq[string]) =
  ## the merge of two bundles against the base they both had: settings, themes and macros key by key, spelling words and
  ## plugins as sets. It gives the merged bundle and the keys changed on both sides, where this device's value is kept
  var conflicts: seq[string]
  var r = %*{"ned": Version, "exported": $now(), "from": mine{"from"}.getStr}
  r["settings"] = syncMergeObj(base{"settings"}, mine{"settings"}, theirs{"settings"}, conflicts, "")
  r["themes"] = syncMergeObj(base{"themes"}, mine{"themes"}, theirs{"themes"}, conflicts, "theme ")
  r["macros"] = syncMergeObj(base{"macros"}, mine{"macros"}, theirs{"macros"}, conflicts, "macro ")
  r["words"] = syncMergeSet(base{"words"}, mine{"words"}, theirs{"words"}, "")
  r["plugins"] = syncMergeSet(base{"plugins"}, mine{"plugins"}, theirs{"plugins"}, "name")
  (r, conflicts)

proc removeSettingText(text, key: string): string =
  ## one key taken out of the settings file (its line, and the comma that went with it), the rest as it was
  let needle = escapeJson(key)
  var i = text.find(needle)
  while i >= 0:
    var ls = i
    while ls > 0 and text[ls - 1] notin {'\n', '\r'}: dec ls
    let before = text[ls ..< i].strip
    var j = i + needle.len
    while j < text.len and text[j] in {' ', '\t'}: inc j
    if (before.len == 0 or before == "{" or before.endsWith(",")) and j < text.len and text[j] == ':':
      var e = jsonValueEnd(text, j + 1)
      var k = e
      while k < text.len and text[k] in {' ', '\t'}: inc k
      if k < text.len and text[k] == ',':
        e = k + 1
        if before.len == 0:
          while e < text.len and text[e] in {' ', '\t'}: inc e
          if e < text.len and text[e] == '\n': inc e
        return text[0 ..< (if before.len == 0: ls else: i)] & text[e .. ^1]
      # the last entry: the comma before it goes
      var p = i - 1
      while p >= 0 and text[p] in Whitespace: dec p
      if p >= 0 and text[p] == ',': return text[0 ..< p] & text[e .. ^1]
      return text[0 ..< i] & text[e .. ^1]
    i = text.find(needle, i + 1)
  text


proc syncApplyMerged(merged, base: JsonNode): string =
  ## the merged bundle over this device: what changed, what the other device removed — and the plugins it has
  let why = syncApply(merged)
  if why.len > 0: return why
  let ex = syncExcluded()
  # (a setting removed on the other device, as it was here at the last sync: removed here too)
  var gone: seq[string]
  let was = base{"settings"}
  let kept = merged{"settings"}
  if was != nil and was.kind == JObject:
    for k, v in was:
      if (kept != nil and kept.kind == JObject and kept.hasKey(k)) or k in ex or secretName(k): continue
      if settingsUser.hasKey(k) and syncSame(settingsUser[k], v): gone.add k
  if gone.len > 0:
    let p = configFile()
    try:
      var text = readFile(p)
      for k in gone: text = removeSettingText(text, k)
      writeFileSafe(p, text)
      reloadSettings(true)
    except CatchableError as e: return e.msg
  # the words: the merged list is the list (one removed elsewhere goes here too)
  try:
    var ws: seq[string]
    for w in jitems(merged{"words"}):
      if w.getStr.strip.len > 0: ws.add w.getStr.strip
    if ws.len > 0 or fileExists(spellUserFile()):
      writeFileSafe(spellUserFile(), ws.join("\n") & (if ws.len > 0: "\n" else: ""))
      spellReset()
  except CatchableError: discard
  # the other device's plugins this one has not: installed when you say so — offered once (Settings sync: install
  # the other device's plugins offers them again)
  var have: HashSet[string]
  for x in jitems(syncPluginList()): have.incl x{"name"}.getStr
  var offered = syncOffered()
  var missing: seq[(string, string)]
  for x in jitems(merged{"plugins"}):
    let n = x{"name"}.getStr
    if n.len > 0 and n notin have and n notin offered and x{"url"}.getStr.len > 0: missing.add (n, x{"url"}.getStr)
  if missing.len > 0:
    var names: seq[string]
    for (n, u) in missing:
      names.add n
      offered[n] = u
    syncOfferedSave(offered)
    let ms = missing
    toast("Your other device has the plugins " & names.join(", ") & " — install them here? (each asks its " &
          "permissions)", 3, "Install", proc() =
            for (n, u) in ms: plugInstall(u, n), 20000)
  ""

proc cmdSyncOfferedPlugins() =
  ## the other device's plugins offered here before and not installed: offered again
  let ms = syncNotInstalled()
  if ms.len == 0:
    info("No plugins of your other device are waiting here (Settings sync: sync now brings its list)")
    return
  var names: seq[string]
  for (n, _) in ms: names.add n
  toast("Your other device's plugins not installed here: " & names.join(", ") & " — install them? (each asks its " &
        "permissions)", 3, "Install", proc() =
          for (n, u) in ms: plugInstall(u, n), 20000)

var syncBusy = false

proc syncBoth(quiet = false) =
  ## Settings sync: both ways — the repository's bundle and this device's merged, then the result here and there
  let url = sStr("sync.repository").strip
  if url.len == 0:
    if not quiet:
      askText("Your settings repository (a private git repository you can push to)", "", proc(t: string) =
        if syncRepoOk(t.strip):
          setSetting("sync.repository", %t.strip)
          syncBoth())
    return
  if syncBusy or not syncRepoOk(url) or not haveExe("git"):
    if not haveExe("git") and not quiet: error("git is not installed")
    return
  syncBusy = true
  let d = syncDir()
  let q = quoteShell(d)
  var sh = "set -e; "
  if not dirExists(d / ".git"):
    sh.add "rm -rf " & q & "; git clone -q -- " & quoteShell(url) & " " & q & " 2>/dev/null || { mkdir -p " & q &
           "; cd " & q & "; git init -q; git remote add origin -- " & quoteShell(url) & "; }; "
  sh.add "cd " & q & "; git fetch -q origin 2>/dev/null || true; B=$(git symbolic-ref --short HEAD 2>/dev/null || echo main); " &
         "git show \"origin/$B:" & SyncFile & "\" 2>/dev/null || true"
  if not quiet: info("Settings sync: reading " & url & "…")
  let j = startJob(jkAux, sh, rootDir, proc(jj: Job) =
    var theirs = newJObject()
    let o = jj.output.strip
    if o.startsWith("{"):
      try: theirs = parseJson(o)
      except CatchableError: theirs = newJObject()
    var base = newJObject()
    try:
      if fileExists(syncBasePath()): base = parseJson(readFile(syncBasePath()))
    except CatchableError: discard
    let mine = syncBundleNow()
    let (merged, conflicts) = syncMerge(base, mine, theirs)
    let why = syncApplyMerged(merged, base)
    if why.len > 0:
      syncBusy = false
      error("Settings sync: " & why)
      return
    try: writeFileSafe(privDir() / SyncFile, merged.pretty & "\n", 0o600)
    except CatchableError as e:
      syncBusy = false
      error("Settings sync: " & e.msg)
      return
    let (_, who, _) = runFilter("git config user.name", "", rootDir, 3000)
    let ident = if who.strip.len == 0: "-c user.name=ned -c user.email=ned@localhost " else: ""
    let push = "set -e; cd " & q & "; B=$(git symbolic-ref --short HEAD 2>/dev/null || echo main); " &
               "if git rev-parse -q --verify \"origin/$B\" >/dev/null; then git reset -q --soft \"origin/$B\"; fi; " &
               "cp " & quoteShell(privDir() / SyncFile) & " " & SyncFile & "; git add " & SyncFile & "; " &
               "git " & ident & "commit -q -m \"ned settings\" >/dev/null 2>&1 || true; git push -q origin \"HEAD:$B\" 2>&1"
    let mergedNow = merged
    discard startJob(jkAux, push, rootDir, proc(j2: Job) =
      syncBusy = false
      if j2.code != 0:
        error("Settings sync: the merge is here, but saving it there failed: " & j2.output.strip.splitLines()[^1])
        return
      try: writeFileSafe(syncBasePath(), mergedNow.pretty & "\n", 0o600)
      except CatchableError: discard
      if conflicts.len > 0:
        warn("Settings sync: changed on both devices, this one's kept — " & conflicts[0 ..< min(6, conflicts.len)].join(", ") &
             (if conflicts.len > 6: " …" else: ""))
      elif not quiet: info("Settings in sync with " & url)))
  if j == nil:
    syncBusy = false
    if not quiet: error("Could not start git")

proc syncChangedSinceBase(): bool =
  ## whether this device's bundle differs from the one at the last sync in settings, themes, macros, words or plugins
  ## (true too when there is no base)
  try:
    if not fileExists(syncBasePath()): return true
    let base = parseJson(readFile(syncBasePath()))
    let mine = syncBundleNow()
    for sect in ["settings", "themes", "macros", "words", "plugins"]:
      if not syncSame(base{sect}, mine{sect}): return true
  except CatchableError: return true
  false

proc syncAtQuit() =
  ## sync.auto quit (or both): this device's changes saved before ned goes — merged with the repository's first,
  ## a few seconds at most
  let auto = sStr("sync.auto")
  if auto notin ["quit", "both"] or sStr("sync.repository").strip.len == 0 or not haveExe("git"): return
  if not syncChangedSinceBase(): return
  let d = syncDir()
  if not dirExists(d / ".git"): return
  let q = quoteShell(d)
  let (_, o, _) = runFilter("cd " & q & " && git fetch -q origin 2>/dev/null; B=$(git symbolic-ref --short HEAD " &
                            "2>/dev/null || echo main); git show \"origin/$B:" & SyncFile & "\" 2>/dev/null", "", rootDir, 4000)
  var theirs = newJObject()
  try: theirs = parseJson(o.strip)
  except CatchableError: discard
  var base = newJObject()
  try: base = parseJson(readFile(syncBasePath()))
  except CatchableError: discard
  let (merged, _) = syncMerge(base, syncBundleNow(), theirs)
  # (the other device's changes kept here too: else the next sync would take this device's older values for them)
  if syncApplyMerged(merged, base).len > 0: return
  try: writeFileSafe(d / SyncFile, merged.pretty & "\n", 0o600)
  except CatchableError: return
  let (ok, _, _) = runFilter("cd " & q & " && B=$(git symbolic-ref --short HEAD 2>/dev/null || echo main); " &
                             "(git rev-parse -q --verify \"origin/$B\" >/dev/null && git reset -q --soft \"origin/$B\"); " &
                             "git add " & SyncFile & " && (git -c user.name=ned -c user.email=ned@localhost commit -q -m " &
                             "\"ned settings\" >/dev/null 2>&1 || true) && git push -q origin \"HEAD:$B\"", "", rootDir, 5000)
  if ok:
    try: writeFileSafe(syncBasePath(), merged.pretty & "\n", 0o600)
    except CatchableError: discard

var
  syncStartDone = false
  syncStartAt: MonoTime

proc syncAtStart() =
  ## sync.auto start (or both): a sync a few seconds after ned starts, in the background
  if syncStartDone: return
  if syncStartAt == MonoTime(): syncStartAt = getMonoTime()
  if msSince(syncStartAt) < 3000: return
  syncStartDone = true
  if sStr("sync.auto") in ["start", "both"] and sStr("sync.repository").strip.len > 0: syncBoth(quiet = true)
