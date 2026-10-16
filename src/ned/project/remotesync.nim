proc remotesFile(): string = stateDir() / "remote" / "remotes.json"

proc saveRemotes() =
  var j = newJArray()
  for r in remotes: j.add %*{"host": r.host, "path": r.path, "absPath": r.absPath, "mirror": r.mirror, "git": r.git,
                             "pulledAt": r.pulledAt}
  try:
    createDir(stateDir() / "remote")
    writeFileSafe(remotesFile(), j.pretty, 0o600)
  except CatchableError: discard

proc loadRemotes() =
  ## the remote folders opened before (their local copies stay; the connection is made again when needed)
  try:
    if not fileExists(remotesFile()): return
    for x in jitems(parseJson(readFile(remotesFile()))):
      let m = x{"mirror"}.getStr
      if m.len == 0 or not dirExists(m) or remoteOf(m) >= 0: continue
      remotes.add Remote(host: x{"host"}.getStr, path: x{"path"}.getStr, absPath: x{"absPath"}.getStr, mirror: m,
                         ctl: getEnv("TMPDIR", "/tmp") / ("ned-ssh-" & $getuid()) / fnv(x{"host"}.getStr),
                         git: x{"git"}.getBool, pulledAt: x{"pulledAt"}.getFloat)
  except CatchableError: discard

proc remoteSafe(s: string): string =
  for c in s:
    result.add (if c.isAlphaNumeric or c in {'-', '_', '.'}: c else: '_')

proc remotePoll(check, host: string, tries: int, then: proc() {.closure.}) =
  ## wait (without blocking) for the connection made in the terminal
  let (ok, _, _) = runFilter(check, "", rootDir, 3000)
  if ok:
    focus = fEditor
    then()
  elif tries < 360:
    discard startJob(jkAux, "sleep 0.5", rootDir, proc(_: Job) = remotePoll(check, host, tries + 1, then))
  else: error("Could not connect to " & host)

proc remoteConnect(r: Remote, then: proc() {.closure.}) =
  ## the shared ssh connection: already up, made without a question (keys, agent), or made in the terminal
  ## (where ssh may ask for a password or a passphrase); then `then`
  if not haveExe("ssh"):
    error("ssh is not installed (" & installHint("openssh", "openssh-client") & ")")
    return
  try: createDir(parentDir(r.ctl))
  except OSError: discard
  let check = sshCmd(r) & " -O check 2>/dev/null"
  let (up, _, _) = runFilter(check, "", rootDir, 4000)
  if up:
    then()
    return
  info("Connecting to " & r.host & "…")
  let master = "ssh -o ControlMaster=yes -o ControlPath=" & quoteShell(r.ctl) & " -o ControlPersist=4h"
  let j = startJob(jkAux, master & " -o BatchMode=yes -o ConnectTimeout=15 -fN " & quoteShell(r.host) & " 2>&1",
                   rootDir, proc(jj: Job) =
    if jj.code == 0:
      then()
      return
    # it needs you: a password, a passphrase, a new host key — in the terminal
    runInTerm(master & " -fN " & quoteShell(r.host) & " && echo 'ned: connected to " & r.host & "'")
    info("Answer ssh in the terminal — ned goes on once it is connected")
    remotePoll(check, r.host, 0, then))
  if j == nil: error("Could not start ssh")

proc remotePrune(ri: int, listFile: string, before: float, exNames: seq[string]): int =
  ## files deleted on the server since the last copy: removed here too — never one saved here since then, or open
  ## with unsaved changes; returns how many
  var onServer: HashSet[string]
  try:
    for l in lines(listFile):
      var x = l.strip(leading = false)
      if x.startsWith("./"): x = x[2 .. ^1]
      x = x.strip(leading = false, chars = {'/'})
      if x.len > 0 and x != ".": onServer.incl x
  except CatchableError: return
  if onServer.len == 0: return                  # an empty list means something went wrong: delete nothing
  let m = remotes[ri].mirror
  var gone: seq[string]
  for f in walkDirRec(m, {pcFile, pcLinkToFile}, {pcDir}, relative = true):
    if f in onServer: continue
    var skip = false
    for part in f.split('/'):
      if part == ".git": skip = true
      for e in exNames:
        if part == e or globMatch(e, part): skip = true
    if skip: continue
    let full = m / f
    try:
      if getLastModificationTime(full).toUnixFloat >= before: continue
    except CatchableError: continue
    let bi = bufIndexByPath(full)
    if bi >= 0 and bufs[bi].dirty: continue
    gone.add full
  for g in gone:
    try:
      removeFile(g)
      inc result
    except CatchableError: discard

proc remoteDetectGit(ri: int) =
  ## is the folder a git repository's top on the server? Then git works on it there
  let r = remotes[ri]
  let (ok, o, _) = runFilter(sshRun(r, "cd " & quoteShell(r.absPath) & " && echo \"NED_PHYS=$(pwd -P)\" && " &
                             "echo \"NED_GIT=$(git rev-parse --show-toplevel 2>/dev/null)\"") & " 2>/dev/null", "", rootDir, 15000)
  if not ok: return
  var phys, top = ""
  for l in o.splitLines:
    if l.startsWith("NED_PHYS="): phys = l[9 .. ^1].strip
    elif l.startsWith("NED_GIT="): top = l[8 .. ^1].strip
  let was = remotes[ri].git
  remotes[ri].git = top.len > 0 and (top == phys or top == r.absPath)
  if top.len > 0 and not remotes[ri].git:
    info("git: " & r.absPath & " is inside the repository at " & top & " on " & r.host & " — open that folder for git")
  if remotes[ri].git != was: saveRemotes()

var remoteClientId = ""

proc remoteMarker(r: Remote): string =
  ## the file on the server whose time says when this ned last copied the folder (each computer has its own:
  ## a random id kept in the state folder)
  if remoteClientId.len == 0:
    let f = stateDir() / "remote" / "client-id"
    try: remoteClientId = readFile(f).strip
    except CatchableError: discard
    if remoteClientId.len == 0:
      var b = ""
      try:
        let u = open("/dev/urandom")
        var buf: array[8, char]
        discard u.readBuffer(addr buf[0], 8)
        u.close()
        for c in buf: b.add c
      except CatchableError: b = $epochTime() & $getCurrentProcessId()
      remoteClientId = fnv(b & $epochTime())
      try:
        createDir(stateDir() / "remote")
        writeFile(f, remoteClientId & "\n")
      except CatchableError: discard
  "\"${XDG_CACHE_HOME:-$HOME/.cache}/ned/sync-" & fnv(remoteClientId & "|" & r.absPath) & "\""

proc remotePull(ri: int, open: bool) =
  ## the server's files into the local copy (big generated folders left out); files deleted there since the last
  ## copy are removed here; then open it
  let r = remotes[ri]
  remoteDetectGit(ri)
  let ex = sval("remote.exclude")
  var excl = ""
  var exNames: seq[string]
  for x in jitems(ex):
    excl.add " --exclude=" & quoteShell(x.getStr)
    exNames.add x.getStr
  let arch = privTmp("remote-pull") & ".tgz"
  let list = arch & ".list"
  let started = epochTime()
  let before = r.pulledAt
  let mirror = r.mirror
  # (the marker first: what changes while it copies comes over with the next sync)
  let cmd = "mkdir -p " & quoteShell(r.mirror) & " && " &
            sshRun(r, "m=" & remoteMarker(r) & "; mkdir -p \"$(dirname \"$m\")\" && touch \"$m\"; cd " &
                   quoteShell(r.absPath) & " && tar czf - " & excl & " .") & " > " & quoteShell(arch) &
            " && tar xzf " & quoteShell(arch) & " -C " & quoteShell(r.mirror) & " && tar tzf " & quoteShell(arch) &
            " > " & quoteShell(list)
  info("Copying " & r.host & ":" & r.absPath & "…")
  let j = startJob(jkAux, cmd & " 2>&1", rootDir, proc(jj: Job) =
    var pruned = 0
    if jj.code == 0:
      let ri2 = remoteOf(mirror)
      if ri2 >= 0:
        if before > 0: pruned = remotePrune(ri2, list, before, exNames)
        remotes[ri2].pulledAt = started
        saveRemotes()
    try:
      removeFile(arch)
      removeFile(list)
    except CatchableError: discard
    if jj.code != 0:
      error("Could not copy the files from " & r.host & ": " & jj.output.strip.splitLines()[^1])
      return
    if open and rootDir != r.mirror: openFolder(r.mirror)
    else:
      for b in bufs:
        if remoteOf(b.path) == ri and not b.dirty and fileExists(b.path): reloadBuffer(b)
      refreshTree()
      refreshGitStatus()
    info(r.host & ":" & r.absPath & " — edit here; every save goes to the server, the terminal and Run work there" &
         (if remoteOf(mirror) >= 0 and remotes[remoteOf(mirror)].git: ", and git" else: "") &
         (if pruned > 0: " · " & $pruned & " file(s) deleted there removed here" else: "")))
  if j == nil: error("Could not start ssh")

proc remotePush(local: string) =
  ## a saved file of a remote folder: to the server, through the shared connection
  let ri = remoteOf(local)
  if ri < 0: return
  let r = remotes[ri]
  let rp = remotePath(r, local)
  let send = proc() =
    inc remotePushing
    if remotePushing == 1:
      try: writeFile(remotePushFlag(), "")
      except CatchableError: discard
    let cmd = sshRun(r, "mkdir -p " & quoteShell(parentDir(rp)) & " && cat > " & quoteShell(rp)) &
              " < " & quoteShell(local)
    let j = startJob(jkAux, cmd & " 2>&1", rootDir, proc(jj: Job) =
      dec remotePushing
      if remotePushing == 0:
        try: removeFile(remotePushFlag())
        except CatchableError: discard
      if jj.code != 0:
        toast("Not saved on " & r.host & ": " & extractFilename(local) & " — " & jj.output.strip.splitLines()[^1], 1,
              "Try again", proc() = remotePush(local), 20000)
      else: info("Saved on " & r.host & ": " & rp)
      needRender = true)
    if j == nil:
      dec remotePushing
      if remotePushing == 0:
        try: removeFile(remotePushFlag())
        except CatchableError: discard
  remoteConnect(r, send)

proc remoteRun(ri: int, script, okMsg: string, then: proc() = nil) =
  ## a shell command in the remote folder on the server (through the shared connection); a failure says so and
  ## offers to try again
  let r = remotes[ri]
  remoteConnect(r, proc() =
    let j = startJob(jkAux, remoteCommand(r, script, r.mirror) & " 2>&1", rootDir, proc(jj: Job) =
      if jj.code != 0:
        let last = jj.output.strip.splitLines()
        toast("Not done on " & r.host & ": " & (if last.len > 0: last[^1] else: "ssh failed"), 1, "Try again",
              proc() = remoteRun(ri, script, okMsg, then), 20000)
      else:
        if okMsg.len > 0: info(okMsg)
        if then != nil: then()
      needRender = true)
    if j == nil: error("Could not start ssh"))

var
  remoteSyncing: HashSet[string]            # local copies being synced now
  remoteSyncAt: float                       # the last automatic sync
  remoteSyncFails = 0                       # automatic syncs that failed in a row (they then come less often)

proc remoteSync(ri: int, then: proc() = nil) =
  ## the files changed on the server since the last copy (by a build, a formatter, the agent's commands, git,
  ## another editor) into the local copy: open tabs without unsaved changes reload; a tab with unsaved changes
  ## says the file changed on disk when it is saved. Deleted files wait for "Pull the latest files"
  if ri < 0 or ri >= remotes.len:
    if then != nil: then()
    return
  let r = remotes[ri]
  if r.mirror in remoteSyncing:
    if then != nil: then()
    return
  remoteSyncing.incl r.mirror
  var prune = ""
  for x in jitems(sval("remote.exclude")): prune.add " -name " & quoteShell(x.getStr) & " -prune -o"
  let script = "m=" & remoteMarker(r) & "; cd " & quoteShell(r.absPath) & " || exit 3; " &
    "if [ ! -f \"$m\" ]; then mkdir -p \"$(dirname \"$m\")\" && touch \"$m\"; exit 0; fi; " &
    "touch \"$m.new\"; find ." & prune & " -type f -newer \"$m\" -print > \"$m.list\"; mv -f \"$m.new\" \"$m\"; " &
    "if [ -s \"$m.list\" ]; then tar czf - -T \"$m.list\"; fi; rm -f \"$m.list\""
  let tmp = privTmp("remote-sync")
  let arch = tmp & ".tgz"
  let started = epochTime()
  let mirror = r.mirror
  let cmd = sshRun(r, script) & " > " & quoteShell(arch) & " && mkdir -p " & quoteShell(tmp) & " && if [ -s " &
            quoteShell(arch) & " ]; then tar xzf " & quoteShell(arch) & " -C " & quoteShell(tmp) & "; fi"
  let j = startJob(jkAux, cmd & " 2>&1", rootDir, proc(jj: Job) =
    remoteSyncing.excl mirror
    if jj.code != 0: inc remoteSyncFails
    else: remoteSyncFails = 0
    var changed, added: int
    if jj.code == 0 and dirExists(tmp):
      for rel in walkDirRec(tmp, {pcFile}, relative = true):
        if rel.startsWith("/") or "/../" in "/" & rel & "/": continue
        let src = tmp / rel
        let dst = mirror / rel
        try:
          let fresh = readFile(src)
          if fileExists(dst):
            if getLastModificationTime(dst).toUnixFloat >= started: continue     # saved here meanwhile: ours wins
            if readFile(dst) == fresh: continue
          else: inc added
          createDir(parentDir(dst))
          writeFile(dst, fresh)
          inc changed
          let bi = bufIndexByPath(dst)
          if bi >= 0 and not bufs[bi].dirty: reloadBuffer(bufs[bi])
        except CatchableError: discard
    try:
      removeDir(tmp)
      removeFile(arch)
    except CatchableError: discard
    if changed > 0:
      checkDiskChanges()
      if added > 0: refreshTree()
      refreshGitStatus()
      for b in bufs:
        if remoteOf(b.path) >= 0: refreshGit(b)
      info($changed & " file" & (if changed == 1: "" else: "s") & " changed on " & r.host & " — copied here")
    needRender = true
    if then != nil: then())
  if j == nil:
    remoteSyncing.excl mirror
    if then != nil: then()

proc remoteAutoSync() =
  ## (main loop) the open remote folders synced every remote.autoSync seconds
  if remotes.len == 0: return
  let every = sInt("remote.autoSync")
  if every <= 0: return
  let now = epochTime()
  if now - remoteSyncAt < float(every * (1 + min(remoteSyncFails, 10))): return
  remoteSyncAt = now
  for ri, r in remotes:
    var open = remoteOf(rootDir) == ri
    for w in wsRoots:
      if remoteOf(w) == ri: open = true
    if open and remotePushing == 0: remoteSync(ri)

proc remoteFileOp(op, local: string, dest = "") =
  ## a file deleted, moved or made in a remote folder's local copy: the same on the server
  if remotes.len == 0: return
  let ri = remoteOf(local)
  if ri < 0: return
  let r = remotes[ri]
  let rp = remotePath(r, local)
  # never the folder itself, nor anything outside it
  if r.absPath.len < 2 or not rp.startsWith(r.absPath & "/") or "/../" in rp & "/": return
  case op
  of "rm": remoteRun(ri, "rm -rf -- " & quoteShell(rp), "Deleted on " & r.host & ": " & rp)
  of "mkdir": remoteRun(ri, "mkdir -p -- " & quoteShell(rp), "")
  of "mv":
    if remoteOf(dest) != ri:
      warn("Moved out of the remote folder — on " & r.host & " it stays where it was")
      return
    let rd = remotePath(r, dest)
    if not rd.startsWith(r.absPath & "/") or "/../" in rd & "/": return
    remoteRun(ri, "mkdir -p -- " & quoteShell(parentDir(rd)) & " && mv -- " & quoteShell(rp) & " " & quoteShell(rd),
              "Renamed on " & r.host & " too")
  else: discard

proc remoteGitBefore(root: string): string =
  ## a git command in a remote folder: what the server's files are like before it (to copy back what it changes)
  if remotes.len == 0 or remoteOf(root) < 0: return ""
  "g=$(git rev-parse --git-dir 2>/dev/null) && { git rev-parse HEAD 2>/dev/null || echo none; " &
    "git -c core.quotePath=false status --porcelain -uall; } > \"$g/ned-before\" 2>/dev/null; "

proc remoteGitAfter(root: string) =
  ## after a git command in a remote folder: the files it changed on the server (a switch, a pull, a stash, a
  ## discard, a merge's conflicts …) copied into the local copy, the ones it deleted removed here
  if remotes.len == 0: return
  let ri = remoteOf(root)
  if ri < 0 or not remotes[ri].git: return
  let r = remotes[ri]
  let script = "g=$(git rev-parse --git-dir) || exit 0; [ -f \"$g/ned-before\" ] || exit 0; " &
    "b=$(head -n 1 \"$g/ned-before\"); " &
    "{ tail -n +2 \"$g/ned-before\"; git -c core.quotePath=false status --porcelain -uall; } | cut -c4- | " &
    "awk '{ n = index($0, \" -> \"); if (n) { print substr($0, 1, n - 1); print substr($0, n + 4) } else print }' " &
    "> \"$g/ned-changed\"; " &
    "if [ \"$b\" != none ]; then git -c core.quotePath=false diff --name-only \"$b\" HEAD -- >> \"$g/ned-changed\" 2>/dev/null; fi; " &
    "rm -f \"$g/ned-before\" \"$g/ned-exist\"; " &
    "sort -u \"$g/ned-changed\" | sed -e 's/^\"\\(.*\\)\"$/\\1/' | while IFS= read -r f; do " &
    "if [ -f \"$f\" ]; then printf '%s\\n' \"$f\" >> \"$g/ned-exist\"; echo \"+$f\"; " &
    "elif [ ! -e \"$f\" ]; then echo \"-$f\"; fi; done; rm -f \"$g/ned-changed\""
  let mirror = r.mirror
  let j = startJob(jkAux, remoteCommand(r, script, r.mirror) & " 2>/dev/null", rootDir, proc(jj: Job) =
    let ri2 = remoteOf(mirror)
    if ri2 < 0 or jj.code != 0: return
    let r2 = remotes[ri2]
    var plus = 0
    var removed, kept: seq[string]
    for l in jj.output.splitLines:
      if l.len < 2: continue
      let rel = l[1 .. ^1]
      if rel.startsWith("/") or "/../" in "/" & rel & "/": continue
      if l[0] == '+': inc plus
      elif l[0] == '-':
        let full = mirror / rel
        if not fileExists(full): continue
        let bi = bufIndexByPath(full)
        if bi >= 0 and bufs[bi].dirty:
          kept.add rel
          continue
        try:
          removeFile(full)
          removed.add rel
        except CatchableError: discard
    if kept.len > 0: warn("Deleted on " & r2.host & " but kept here (unsaved changes): " & kept.join(", "))
    let after = proc() =
      checkDiskChanges()
      refreshTree()
      refreshGitStatus()
      for b in bufs: refreshGit(b)
      needRender = true
    if plus == 0:
      if removed.len > 0: after()
      return
    let cmd = sshRun(r2, "cd " & quoteShell(r2.absPath) & " && g=$(git rev-parse --git-dir) && " &
              "tar czf - -T \"$g/ned-exist\"; rm -f \"$g/ned-exist\"") & " | tar xzmf - -C " & quoteShell(mirror)
    discard startJob(jkAux, cmd & " 2>&1", rootDir, proc(j2: Job) =
      if j2.code != 0: warn("Could not copy git's changes from " & r2.host & " — Remote: pull the latest files")
      after()))
  if j == nil: discard

proc remoteOpen(spec: string) =
  ## user@host:/path · host:~/project · host (its home folder)
  let t = spec.strip
  if t.len == 0: return
  let c = t.find(':')
  let host = if c > 0: t[0 ..< c] else: t
  let path = if c > 0 and c < t.high: t[c + 1 .. ^1] else: "~"
  if host.len == 0 or host[0] == '-':
    error("Not a host: " & host)
    return
  # the local copy: …/remote/<host>/<a key for the path>/<the folder's own name> (so the project keeps its name)
  let leaf = remoteSafe(extractFilename(path.strip(leading = false, chars = {'/'})).strip(chars = {'~'}))
  var r = Remote(host: host, path: path,
                 mirror: stateDir() / "remote" / remoteSafe(host) / fnv(path) / (if leaf.len > 0: leaf else: "home"),
                 ctl: getEnv("TMPDIR", "/tmp") / ("ned-ssh-" & $getuid()) / fnv(host))
  remoteConnect(r, proc() =
    # the folder's real path on the server (~ and relative paths resolved there)
    let p = if path == "~" or path.len == 0: "$HOME" elif path.startsWith("~/"): "$HOME/" & quoteShell(path[2 .. ^1]) else: quoteShell(path)
    let (ok, outp, _) = runFilter(sshRun(r, "cd " & p & " && pwd") & " 2>&1", "", rootDir, 15000)
    if not ok or outp.strip.len == 0 or not outp.strip.splitLines()[^1].startsWith("/"):
      error("No folder " & path & " on " & host & ": " & outp.strip)
      return
    r.absPath = outp.strip.splitLines()[^1].strip
    var ri = remoteOf(r.mirror)
    if ri < 0:
      remotes.add r
      ri = remotes.high
    else:
      r.git = remotes[ri].git                     # opened before: keep what is known about it
      r.pulledAt = remotes[ri].pulledAt
      remotes[ri] = r
    saveRemotes()
    remotePull(ri, true))

proc remoteHere(): int = (if remotes.len > 0: remoteOf(rootDir) else: -1)

proc cmdRemoteMenu() =
  let ri = remoteHere()
  var items: seq[(string, string, Action)]
  items.add act("Open a folder over SSH…", "user@host:/path · host:~/project", proc() =
    askText("Open over SSH (user@host:/path, or a Host from ~/.ssh/config)", "", proc(t: string) = remoteOpen(t)))
  if ri >= 0:
    let r = remotes[ri]
    items.add act("Pull the latest files from " & r.host, "files changed on the server", proc() =
      remoteConnect(remotes[ri], proc() = remotePull(ri, false)))
    items.add act("Terminal on " & r.host, r.absPath, proc() = (newTerminal()))
    items.add act("Disconnect from " & r.host, "ends the shared ssh connection", proc() =
      discard runFilter(sshCmd(remotes[ri]) & " -O exit 2>&1", "", rootDir, 4000)
      info("Disconnected from " & remotes[ri].host & " — the next save or Run connects again"))
  openActions("Remote (SSH)" & (if ri >= 0: " — " & remotes[ri].host & ":" & remotes[ri].absPath else: ""), items)
