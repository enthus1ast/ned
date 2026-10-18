# ── git for a new folder and for other people's projects: init, who you are, clone from a link ──

proc gitLastLine(o: string): string =
  let ls = stripAnsi(o).strip.splitLines
  if ls.len > 0: ls[^1] else: "failed"

proc gitIdentityMissing(dir: string): bool =
  ## does git know the name and email it puts on commits (this repository's, or yours)?
  let (ok1, n, _) = runFilter("git config user.name", "", dir, 3000)
  let (ok2, e, _) = runFilter("git config user.email", "", dir, 3000)
  not (ok1 and n.strip.len > 0 and ok2 and e.strip.len > 0)

proc gitAskIdentity(dir: string, then: proc() {.closure.} = nil) =
  ## the name and email for commits, asked once and kept in your git settings (git config --global)
  gitAsk("Your name, for git commits (asked once)", getEnv("USER"), proc(name: string) =
    let nm = name.strip
    if nm.len == 0: return
    gitAsk("Your email, for git commits", "", proc(mail: string) =
      let em = mail.strip
      if em.len == 0 or '@' notin em:
        error("That does not look like an email address — nothing changed")
        return
      let (ok1, _, e1) = runFilter("git config --global user.name " & quoteShell(nm), "", dir, 5000)
      let (ok2, _, e2) = runFilter("git config --global user.email " & quoteShell(em), "", dir, 5000)
      if not (ok1 and ok2):
        error("git config failed: " & gitLastLine(e1 & "\n" & e2))
        return
      info("git signs your commits as " & nm & " <" & em & "> (git config --global)")
      if then != nil: then()))

proc gitInitIn(dir: string, firstCommit: bool) =
  ## `git init` in a folder; a new project also gets its first commit (once git knows who you are)
  if not haveExe("git"):
    error("git is not installed — Termux: pkg install git · Debian/Ubuntu: sudo apt install git")
    return
  discard startJob(jkGit, "git init -q", dir, proc(j: Job) =
    if j.code != 0:
      error("git init failed: " & gitLastLine(j.output))
      return
    let d = dir
    proc commit() =
      discard startJob(jkGit, "git add -A && git commit -qm " & quoteShell("First commit"), d, proc(j2: Job) =
        if j2.code == 0: info("A git repository with its first commit: " & relPath(d))
        else: info("A git repository in " & relPath(d) & " — not committed yet: " & gitLastLine(j2.output))
        refreshGitStatus())
    refreshGitStatus()
    if firstCommit:
      if gitIdentityMissing(d): gitAskIdentity(d, commit)
      else: commit()
    else:
      info("Initialised a git repository in " & relPath(d) & " — the Git dock (Alt+G) stages and commits")
      if gitIdentityMissing(d): gitAskIdentity(d))

proc gitInitNewProject(dir: string) = gitInitIn(dir, true)

proc gitInitHere(dir = "") =
  ## the open folder (or `dir`) made a git repository — on the server for a folder opened over SSH; asks first
  ## when the folder is already inside another repository
  let d = if dir.len > 0: dir elif rootDir.len > 0: rootDir else: getCurrentDir()
  let ri = if remotes.len > 0: remoteOf(d) else: -1
  if ri >= 0:
    let host = remotes[ri].host
    remoteRun(ri, "git init -q", "Initialised a repository on " & host, proc() =
      let k2 = remoteOf(rootDir)
      if k2 >= 0:
        remotes[k2].git = true
        saveRemotes()
      refreshGitStatus())
    return
  let outer = findGitRoot(d)
  if outer.len > 0 and normalizedPath(outer) == normalizedPath(d):
    info(relPath(d) & " is a git repository already")
    return
  if outer.len > 0:
    askConfirm("This folder is inside the git repository " & outer & " — make a separate repository here? (y/n)",
               proc(c: char) =
      if c in {'y', 'Y'}: gitInitIn(d, false))
  else: gitInitIn(d, false)

proc gitLinkParts(link: string): (string, string) =
  ## a link as people copy it → (what git clones, the branch it names or ""):
  ## github.com/u/r · https://github.com/u/r/tree/dev/src · https://gitlab.com/g/r/-/tree/dev ·
  ## https://codeberg.org/u/r/src/branch/dev · u/r (GitHub) · git@host:u/r.git · ssh://… · a local folder
  var u = link.strip
  if u.len == 0: return
  let web = u.startsWith("http://") or u.startsWith("https://")
  if web:
    let q = u.find({'?', '#'})
    if q > 0: u = u[0 ..< q]
  elif not (u.startsWith("git@") or u.startsWith("ssh://") or u.startsWith("git://") or u.startsWith("file://") or
            u.startsWith("/") or u.startsWith("~") or u.startsWith(".")):
    let first = u.split('/')[0]
    if u.count('/') == 1 and ':' notin u and ' ' notin u and '.' notin first: u = "https://github.com/" & u
    elif '.' in first and ':' notin first: u = "https://" & u                   # github.com/u/r
  var branch = ""
  if u.startsWith("http"):
    var markers = @["/-/tree/", "/-/blob/", "/tree/", "/blob/", "/src/branch/", "/src/tag/", "/src/commit/"]
    if "bitbucket.org/" in u: markers.add "/src/"
    for marker in markers:
      let k = u.find(marker)
      if k > 0:
        let rest = u[k + marker.len .. ^1]
        if not marker.contains("commit"): branch = rest.split('/')[0]
        u = u[0 ..< k]
        break
    u = u.strip(leading = false, chars = {'/'})
  (u, branch)

func gitLinkHasSecret(url: string): bool =
  ## https://user:token@host/…: a login written into the link (it would stay in .git/config and on a command line)
  let p = url.find("://")
  if p < 0: return false
  let rest = url[p + 3 .. ^1]
  let slash = rest.find('/')
  let at = rest.find('@')
  at > 0 and (slash < 0 or at < slash) and ':' in rest[0 ..< at]

proc gitAfterClone(d: string) =
  ## a clone done: its folder opens with its README, and a Nim project offers to fetch what it needs
  openFolder(d)
  for r in ["README.md", "readme.md", "Readme.md", "README.rst", "README.txt", "README"]:
    if fileExists(d / r):
      discard openFile(d / r)
      break
  var nimble = ""
  try:
    for kind, p in walkDir(d):
      if kind == pcFile and p.endsWith(".nimble"): nimble = p
  except OSError: discard
  if nimble.len > 0 and haveExe("nimble"):
    let dd = d
    toast("Cloned " & extractFilename(d) & " — a Nim project: install the packages it needs?", 3,
          "nimble install --depsOnly", proc() = runCommand("nimble install --depsOnly -y", dd), 20000)
  else: info("Cloned into " & d)

proc gitCloneFromLink(link = "") =
  ## clone a repository from a link — any host, https or ssh, a branch named in the link — into a folder you pick
  if not haveExe("git"):
    error("git is not installed — Termux: pkg install git · Debian/Ubuntu: sudo apt install git")
    return
  proc withLink(l: string) =
    let (url, branch) = gitLinkParts(l)
    if url.len == 0: return
    if gitLinkHasSecret(url):
      error("That link has a password or token in it — use the link without it: git asks for the login in the " &
            "terminal, and nothing secret stays in the project's .git/config")
      return
    var name = url.strip(chars = {'/'}).split({'/', ':'})[^1]
    if name.endsWith(".git"): name.setLen(name.len - 4)
    if name.len == 0: name = "project"
    let base = if rootDir.len > 1: parentDir(rootDir) else: getHomeDir()
    gitAsk("Clone into", base / name, proc(dest: string) =
      let d = absolutePath(expandTilde(dest.strip))
      if dest.strip.len == 0: return
      var used = false
      if dirExists(d):
        for _ in walkDir(d):
          used = true
          break
      if used:
        error(d & " is there already and not empty — pick another folder")
        return
      openDialog("Clone " & name, url & (if branch.len > 0: "  · branch " & branch else: "") & "\ninto " & d,
                 @[("Clone", 'y'), ("Latest version only", 'l'), ("Cancel", 'c')], proc(c: char) =
        if c notin {'y', 'l'}: return               # (Esc is Cancel)
        try: createDir(parentDir(d))
        except OSError as e:
          error("Cannot make " & parentDir(d) & ": " & e.msg)
          return
        let args = (if c == 'l': " --depth 1" else: "") & (if branch.len > 0: " -b " & quoteShell(branch) else: "") &
                   " " & quoteShell(url) & " " & quoteShell(d)
        info("Cloning " & url & "…")
        # (no password prompts in the background: when git needs your login, the clone runs in the terminal)
        runCommand(gitBatchEnv(parentDir(d)) & "git clone" & args, parentDir(d), proc(code: int) =
          if code == 0:
            gitAfterClone(d)
            return
          var o = ""
          for pl in panelLines: o.add pl.text & "\n"
          if "terminal prompts disabled" in o or "could not read" in o or "Permission denied" in o or
             "Authentication failed" in o or "Host key verification" in o:
            try: removeDir(d)
            except OSError: discard
            runInTerm("git clone" & args)
            info("git needs your login — answer it in the terminal; then File › Open folder opens " & d)
          else: error("git clone failed: " & gitLastLine(o)))))
  if link.len > 0: withLink(link)
  else:
    var clip = ""
    try: clip = clipGet().strip
    except CatchableError: discard
    let guess = if clip.len < 300 and '\n' notin clip and (clip.startsWith("http") or clip.startsWith("git@")): clip else: ""
    gitAsk("Link to clone (GitHub, GitLab, Codeberg, any git server — https or ssh)", guess, proc(l: string) =
      withLink(l))
