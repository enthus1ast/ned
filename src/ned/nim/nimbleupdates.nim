# ── Nimble: which dependencies have newer versions (each package's git tags), and moving a requirement up ──

type DepRow = object
  req, name, url, op, want, latest, installed, err: string

var
  depRows: seq[DepRow]
  depPending = 0
  depStarted: MonoTime

proc nimbleHome(): string = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")

proc splitRequire(r: string): (string, string, string) =
  ## "jsony >= 1.1" → ("jsony", ">=", "1.1") · "foo#head" → ("foo", "#", "head") · "bar" → ("bar", "", "")
  let t = r.strip
  let h = t.find('#')
  if h > 0: return (t[0 ..< h].strip, "#", t[h + 1 .. ^1].strip)
  var i = 0
  while i < t.len and t[i] notin {' ', '<', '>', '=', '~', '^', '@'}: inc i
  let name = t[0 ..< i]
  var rest = t[i .. ^1].strip
  var op = ""
  while rest.len > 0 and rest[0] in {'<', '>', '=', '~', '^', '@'}:
    op.add rest[0]
    rest = rest[1 .. ^1]
  let ws = rest.strip.splitWhitespace()
  (name, op, (if ws.len > 0: ws[0] else: ""))

proc verParts(v: string): seq[int] =
  for x in v.split('.'):
    var n = 0
    for c in x:
      if c in Digits: n = n * 10 + (ord(c) - 48)
      else: break
    result.add n

proc verCmp(a, b: string): int =
  let x = verParts(a)
  let y = verParts(b)
  for i in 0 ..< max(x.len, y.len):
    let p = if i < x.len: x[i] else: 0
    let q = if i < y.len: y[i] else: 0
    if p != q: return cmp(p, q)
  0

func tagVersion(tag: string): string =
  ## refs/tags/v1.2.3 → 1.2.3 ("" for tags that are not versions)
  var t = tag.strip
  if t.startsWith("refs/tags/"): t = t[10 .. ^1]
  if t.len > 0 and t[0] in {'v', 'V'}: t = t[1 .. ^1]
  if t.len == 0 or t[0] notin Digits: return ""
  for c in t:
    if c notin Digits and c != '.': return ""
  t

proc packageListFiles(): seq[string] =
  let nd = nimbleHome()
  try:
    for kind, p in walkDir(nd):
      if kind == pcFile and extractFilename(p).startsWith("packages_") and p.endsWith(".json"): result.add p
  except OSError: discard
  result.add stateDir() / "nimble-packages.json"           # ned's own copy (when nimble never refreshed)

proc packageUrls(): Table[string, string] =
  ## package name (lower case) → its repository, from nimble's package lists
  for f in packageListFiles():
    try:
      if not fileExists(f) or getFileSize(f) < 10: continue
      let j = parseJson(readFile(f))
      var alias: seq[(string, string)]
      for e in jitems(j):
        let n = e{"name"}.getStr.toLowerAscii
        if n.len == 0: continue
        if e{"url"}.getStr.len > 0 and n notin result: result[n] = e{"url"}.getStr
        elif e{"alias"}.getStr.len > 0: alias.add (n, e{"alias"}.getStr.toLowerAscii)
      for (n, a) in alias:
        if a in result and n notin result: result[n] = result[a]
    except CatchableError: discard

proc installedVersion(name: string): string =
  ## the version the project builds with (the engine's choice: nimble.paths, nimble.lock, nimbledeps/, the newest
  ## installed one that meets the requirement); else the lock file's, else the newest installed (name-1.2.3-<hash>)
  let d = engineDepOf(nimble.dir, name)
  if d.dir.len > 0 and d.version.len > 0: return d.version
  let lock = nimble.dir / "nimble.lock"
  if fileExists(lock):
    try:
      let j = parseJson(readFile(lock))
      for k, v in j{"packages"}.pairs:
        if k.toLowerAscii == name.toLowerAscii: return v{"version"}.getStr
    except CatchableError: discard
  for d in [nimble.dir / "nimbledeps" / "pkgs2", nimble.dir / "nimbledeps" / "pkgs", nimbleHome() / "pkgs2", nimbleHome() / "pkgs"]:
    try:
      for kind, p in walkDir(d):
        if kind notin {pcDir, pcLinkToDir}: continue
        let parts = extractFilename(p).split('-')
        if parts.len >= 2 and parts[0].toLowerAscii == name.toLowerAscii and parts[1].len > 0 and parts[1][0] in Digits:
          if result.len == 0 or verCmp(parts[1], result) > 0: result = parts[1]
    except OSError: discard

proc depNewer(d: DepRow): bool =
  d.latest.len > 0 and d.op != "#" and (d.want.len == 0 or verCmp(d.latest, d.want) > 0)

proc nimbleBump(rows: seq[DepRow]) =
  ## move each requirement up to its latest version (the operator kept, >= when there was none)
  loadNimbleInfo(true)
  if nimble.file.len == 0: return
  for bb in bufs:
    if bb.path == nimble.file and bb.dirty:
      error("Save " & extractFilename(nimble.file) & " first")
      return
  var text = try: readFile(nimble.file) except CatchableError: ""
  var names: seq[string]
  for d in rows:
    if not d.depNewer: continue
    let nr = d.name & " " & (if d.op.len == 0 or d.op == "@": ">=" else: d.op) & " " & d.latest
    let old = "\"" & d.req & "\""
    let k = text.find(old)
    if k < 0: continue
    text = text[0 ..< k] & "\"" & nr & "\"" & text[k + old.len .. ^1]
    names.add d.name
  if names.len == 0:
    info("Nothing to update")
    return
  try:
    snapshotHistory(nimble.file)
    writeFileSafe(nimble.file, text)
  except CatchableError as e:
    error("Could not update " & nimble.file & ": " & e.msg)
    return
  for bb in bufs:
    if bb.path == nimble.file: reloadBuffer(bb)
  loadNimbleInfo(true)
  let locked = fileExists(nimble.dir / "nimble.lock")
  toast("Updated " & names.join(", ") & " in " & extractFilename(nimble.file), 5,
        (if locked: "nimble upgrade" else: "Install now"),
        (if locked: (proc() = runNimble("upgrade " & names.join(" ")))
         else: (proc() = runNimble("install -d -y"))), 20000)

proc depRowAct(d: DepRow, label, detail: string): Action =
  ## (one closure per row: a proc of its own, not a closure made in the loop)
  if d.depNewer: (proc() = nimbleBump(@[d])) else: (proc() = info(label & ": " & detail))

proc depShow() =
  ## the results: newer versions first; choosing one moves its requirement up
  if depRows.len == 0: return
  var rows = depRows
  rows.sort(proc(a, b: DepRow): int =
    if a.depNewer != b.depNewer: (if a.depNewer: -1 else: 1) else: cmp(a.name, b.name))
  var items: seq[(string, string, Action)]
  var newer: seq[DepRow]
  for d in rows:
    if d.depNewer: newer.add d
  if newer.len > 1:
    let all = newer
    items.add act("Update all " & $newer.len & " to their latest versions", "", proc() = nimbleBump(all))
  for d in rows:
    let label = d.name & (if d.op.len > 0: " " & d.op & " " & d.want else: "")
    let inst = if d.installed.len > 0: " · installed " & d.installed else: ""
    let detail = if d.err.len > 0: d.err
                 elif d.op == "#": "pinned to #" & d.want & (if d.latest.len > 0: " · latest release " & d.latest else: "")
                 elif d.depNewer: "→ " & d.latest & " available" & inst
                 elif d.latest.len > 0: "up to date (latest " & d.latest & ")" & inst
                 else: "no version tags" & inst
    items.add act(label, detail, depRowAct(d, label, detail))
  openActions("Dependencies of " & extractFilename(nimble.file) & " — " &
              (if newer.len == 0: "all up to date" else: $newer.len & " with a newer version"), items)

proc depDone() =
  dec depPending
  if depPending == 0: depShow()

proc depFetch(i: int) =
  ## the newest version-looking tag of one dependency's repository
  let url = depRows[i].url
  if not gitArgSafe(url):
    # (a URL a .nimble or the package list gives: never one git could read as an option)
    depRows[i].err = "not a repository URL: " & truncTo(url, 60)
    dec depPending
    if depPending == 0: depShow()
    return
  let cmd = (if haveExe("timeout"): "timeout 30 " else: "") & "env GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs -- " &
            quoteShell(url) & " 2>&1"
  let j = startJob(jkAux, cmd, nimble.dir, proc(jj: Job) =
    if i < depRows.len:
      if jj.code != 0:
        depRows[i].err = "could not read " & url & " (" & jj.output.strip.splitLines()[^1].strip & ")"
      else:
        var best = ""
        for l in jj.output.splitLines:
          let parts = l.splitWhitespace()
          if parts.len < 2: continue
          let v = tagVersion(parts[1])
          if v.len > 0 and (best.len == 0 or verCmp(v, best) > 0): best = v
        depRows[i].latest = best
    depDone())
  if j == nil:
    depRows[i].err = "could not start git"
    depDone()

proc cmdNimbleOutdated(fetched = false) =
  loadNimbleInfo(true)
  if nimble.file.len == 0:
    error("No .nimble file in this project")
    return
  if not haveExe("git"):
    error("git is needed to look up the versions")
    return
  if depPending > 0 and msSince(depStarted) < 60_000:
    info("Still checking " & $depPending & " package(s)…")
    return
  let urls = packageUrls()
  if urls.len == 0 and not fetched:
    # no package list yet (nimble refresh was never run): fetch one, then go on
    if not haveExe("curl"):
      error("No nimble package list — run nimble refresh")
      return
    let dest = stateDir() / "nimble-packages.json"
    info("Fetching the Nimble package list…")
    let j = startJob(jkAux, "curl -fsSL --max-time 60 -o " & quoteShell(dest & ".part") &
                     " https://raw.githubusercontent.com/nim-lang/packages/master/packages.json && mv " &
                     quoteShell(dest & ".part") & " " & quoteShell(dest), rootDir, proc(jj: Job) =
      if jj.code != 0: error("Could not fetch the package list — run nimble refresh")
      else: cmdNimbleOutdated(true))
    if j == nil: error("Could not start curl")
    return
  depRows.setLen(0)
  for r in nimble.requires:
    var (name, op, want) = splitRequire(r)
    if name.len == 0 or name.toLowerAscii == "nim": continue
    var d = DepRow(req: r, name: name, op: op, want: want, installed: installedVersion(name))
    if "://" in name or name.startsWith("git@"):
      d.url = name
      d.name = name.strip(chars = {'/'}).split('/')[^1].replace(".git", "")
    else: d.url = urls.getOrDefault(name.toLowerAscii)
    if d.url.len == 0: d.err = "not in the package list (nimble refresh)"
    depRows.add d
  if depRows.len == 0:
    info(extractFilename(nimble.file) & " requires no packages")
    return
  depPending = 1                      # held until every lookup has started
  depStarted = getMonoTime()
  for i in 0 ..< depRows.len:
    if depRows[i].url.len > 0:
      inc depPending
      depFetch(i)
  info("Looking up the newest version of " & $(depPending - 1) & " package(s)…")
  depDone()
