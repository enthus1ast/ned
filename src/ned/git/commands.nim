# ── git: branches, push/pull that ask for a login in the terminal, commit box, history, stash, blame, more ──

proc gitShell(cmd, okMsg: string, then: proc() = nil, inRepo = "") =
  ## a git command line (with environment variables) in the repo root (or `inRepo`); then refresh
  let root = if inRepo.len > 0: inRepo else: gitHome()
  if not gitOk(root):
    error("Not a git repository")
    return
  discard startJob(jkGit, remoteGitBefore(root) & cmd, root, proc(j: Job) =
    let o = stripAnsi(j.output).strip
    if j.code == 0:
      info(okMsg & (if o.len > 0 and o.count('\n') == 0: " — " & o else: ""))
      if then != nil: then()
    else: error("git: " & (if o.len > 0: o.splitLines[^1] else: "failed"))
    refreshGitStatus()
    checkDiskChanges()
    for b in bufs: refreshGit(b)
    remoteGitAfter(root))

proc gitAsk(label, initial: string, cb: proc(t: string)) =
  gitPromptCb = cb
  openPrompt(pGitInput, label, initial)

proc gitBatchEnv(root: string): string =
  ## environment for background git: no password prompts, and ssh in batch mode so it never asks over
  ## the editor — your own ssh command (GIT_SSH_COMMAND, core.sshCommand) is kept
  var base = getEnv("GIT_SSH_COMMAND")
  if base.len == 0:
    let (ok, o, _) = runFilter("git config --get core.sshCommand", "", root, 2000)
    if ok: base = o.strip
  if base.len == 0: base = "ssh"
  "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=" & quoteShell(base & " -o BatchMode=yes") & " "

proc gitNet(args, okMsg: string, then: proc() = nil) =
  ## push / pull / fetch without hanging on a password prompt: when the server wants a login the same
  ## command runs in the terminal, where you can type it; a new branch's first push sets its upstream
  let root = gitHome()
  if not gitOk(root):
    error("Not a git repository")
    return
  info("git " & args & "…")
  discard startJob(jkGit, remoteGitBefore(root) & gitBatchEnv(root) & "git " & args, root,
                   proc(j: Job) =
    let o = stripAnsi(j.output).strip
    if j.code == 0:
      info(okMsg & (if o.len > 0: "\n" & o.splitLines[^1] else: ""))
      if args.startsWith("push") and haveExe("gh"):
        ciDue = true                     # the run the push starts shows up after a few seconds
        ciDueAt = getMonoTime() + initDuration(seconds = 8)
      if then != nil: then()
    elif "git push --set-upstream" in o and "--set-upstream" notin args:
      # git suggests `git push --set-upstream <remote> <branch>`: never run its text (a branch name can hold
      # shell characters) — the remote, quoted, and HEAD
      let k = o.find("git push --set-upstream")
      var e = o.find('\n', k)
      if e < 0: e = o.len
      let w = o[k ..< e].splitWhitespace()
      let remote = if w.len >= 4: w[3] else: "origin"
      gitNet("push --set-upstream " & quoteShell(remote) & " HEAD", okMsg, then)
    elif "terminal prompts disabled" in o or "could not read Username" in o or "Permission denied" in o or
         "Authentication failed" in o or "Host key verification" in o or "passphrase" in o:
      runInTerm("git " & args)
      info("git needs your login — finish it in the terminal")
    else: error("git " & args.splitWhitespace()[0] & " failed:\n" & o.splitLines[max(0, o.splitLines.len - 4) .. ^1].join("\n"))
    refreshGitStatus()
    checkDiskChanges()
    for b in bufs: refreshGit(b)
    remoteGitAfter(root))

proc gitSync() =
  ## pull (rebasing your commits on top), then push
  gitNet("pull --rebase", "Pulled", proc() = gitNet("push", "Synced — pulled and pushed"))

proc gitStaged(): int =
  for l in gitStatusLines:
    if l.len > 3 and not l.startsWith("## ") and l[0] notin {' ', '?'}: inc result

# branches

proc gitSwitch(name: string) =
  discard saveAll()
  gitShell("git switch " & quoteShell(name), "On branch " & name, proc() = readBranch())

proc branchMenu(name: string, current: string) =
  let n = name
  openActions(n, @[
    act("Switch to it", "git switch", proc() = gitSwitch(n)),
    act("Merge it into " & current, "git merge", proc() = gitShell("git merge --no-edit " & quoteShell(n), "Merged " & n)),
    act("Rename…", "git branch -m", proc() =
      gitAsk("New name for " & n, n, proc(t: string) =
        gitShell("git branch -m " & quoteShell(n) & " " & quoteShell(t), "Renamed to " & t, proc() = readBranch()))),
    act("Delete…", "git branch -d (only when merged)", proc() =
      askConfirm("Delete the branch " & n & "? (y/n)", proc(c: char) =
        if c in {'y', 'Y'}: gitShell("git branch -d " & quoteShell(n), "Deleted " & n))),
    act("Delete even if not merged…", "git branch -D", proc() =
      askConfirm("Delete " & n & " and the commits only it has? (y/n)", proc(c: char) =
        if c in {'y', 'Y'}: gitShell("git branch -D " & quoteShell(n), "Deleted " & n)))])

proc cmdBranches() =
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  discard startJob(jkGit, "git for-each-ref --sort=-committerdate --format='%(HEAD)%09%(refname:short)%09%(upstream:short)%09%(committerdate:relative)%09%(refname)' refs/heads refs/remotes",
                   root, proc(j: Job) =
    var items: seq[(string, string, Action)]
    items.add act("+ New branch…", "from here (git switch -c)", proc() =
      gitAsk("New branch name", "", proc(t: string) =
        gitShell("git switch -c " & quoteShell(t), "On the new branch " & t, proc() = readBranch())))
    items.add act("Fetch", "see the remote's new branches", proc() = gitNet("fetch --all --prune", "Fetched"))
    var locals: HashSet[string]
    let cur = gitBranch
    for l in j.output.splitLines:
      let f = l.split('\t')
      if f.len < 5 or f[1].len == 0: continue
      if f[4].startsWith("refs/remotes/") and f[1].endsWith("/HEAD"): continue
      let name = f[1]
      let isRemote = f[4].startsWith("refs/remotes/")
      if not isRemote: locals.incl name
      let nm = name
      if isRemote:
        let short = nm[nm.find('/') + 1 .. ^1]
        if short in locals: continue
        capture nm, short:
          items.add act("  " & nm, "remote · " & f[3] & " · pick: a local branch that follows it", proc() = gitSwitch(short))
      else:
        capture nm:
          items.add act((if f[0] == "*": "✓ " else: "  ") & nm, (if f[2].len > 0: "↔ " & f[2] & " · " else: "") & f[3],
                        proc() = branchMenu(nm, cur))
    openActions("Branches (" & cur & ")", items))

# commit box

proc gitCommitBox(amend: bool) =
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  proc open(msg: string) =
    let n = gitStaged()
    let text = msg & "\n\n# Write the message above — the first line is the summary. Ctrl+S commits" &
               (if amend: " (replacing the last commit)" else: "") & ", Ctrl+W cancels.\n" &
               "# Lines starting with # are left out. Staged: " & $n & " file(s)" &
               (if n == 0 and not amend: " — nothing staged: you will be asked about committing everything" else: "") & "\n"
    let where = if gitRepoRoots().len > 1: " — " & extractFilename(root) else: ""
    let cb = openScratch((if amend: "Amend commit" else: "Commit message") & where, text, langByName("Markdown"))
    cb.readOnly = false
    cb.savedSeq = cb.topSeq()
    commitBufs[cb.id] = CommitBuf(amend: amend, root: root)
    cb.setSingle(Pos(line: 0, col: cb.lines[0].len))
    focus = fEditor
  if amend:
    discard startJob(jkGit, "git --no-pager log -1 --format=%B", root, proc(j: Job) = open(j.output.strip))
  else: open("")

proc doCommitFromBuffer(b: Buffer): bool =
  var msg: seq[string]
  for l in b.lines:
    if not l.startsWith("#"): msg.add l
  let text = msg.join("\n").strip
  let amend = commitBufs[b.id].amend
  let croot = commitBufs[b.id].root
  if text.len == 0:
    error("The commit message is empty")
    return false
  let tmp = privTmp("commit-msg")
  try: writeFile(tmp, text & "\n")
  except IOError, OSError: return false
  b.savedSeq = b.topSeq()
  let id = b.id
  proc go(all: bool) =
    let cb = bufById(id)
    if cb != nil:
      commitBufs.del cb.id
      let i = bufs.find(cb)
      if i >= 0: closeBufferAt(i)
    gitShell("git commit" & (if amend: " --amend" else: "") & (if all: " -a" else: "") & " -F " & quoteShell(tmp),
             (if amend: "Amended the last commit" else: "Committed"), nil, croot)
  var stagedN = 0
  for l in (if croot.len > 0 and croot != gitHome(): gitRepoInfo(croot).lines else: gitStatusLines):
    if l.len > 3 and not l.startsWith("## ") and l[0] notin {' ', '?'}: inc stagedN
  if stagedN == 0 and not amend:
    askConfirm("Nothing is staged — commit all changed files? (new files are left out) (y/n)", proc(c: char) =
      if c in {'y', 'Y'}: go(true))
  else: go(false)
  true

# changes in the diff view

proc gitShowLines(root, spec: string, cb: proc(ls: seq[string])) =
  ## a file as git has it (`HEAD:path`, `:path`, `abc123:path`); empty when it is not there
  discard startJob(jkGit, "git --no-pager show " & quoteShell(spec), root, proc(j: Job) =
    var ls = if j.code == 0: j.output.split('\n') else: @[]
    if ls.len > 0 and ls[^1].len == 0: ls.setLen(ls.len - 1)
    cb(ls))

proc gitOpenChangeDiff(rel: string, staged: bool) =
  let root = gitHome()
  if root.len == 0: return
  let full = root / rel
  let r = rel
  if staged:
    gitShowLines(root, "HEAD:" & r, proc(head: seq[string]) =
      gitShowLines(root, ":" & r, proc(idx: seq[string]) =
        openDiffView("staged " & extractFilename(r), head, "HEAD: " & r, nil, idx, "staged: " & r,
                     detectLang(full, ""))))
  else:
    gitShowLines(root, ":" & r, proc(idx: seq[string]) =
      let src = openFile(full)
      if src == nil: return
      openDiffView(extractFilename(r), idx, "staged / last commit: " & r, src, @[], r & " (yours)", src.lang))

proc stageSelectedLines() =
  ## only the changed lines inside the selection go into git's index
  let b = buf()
  if b.path.len == 0 or not b.gitHasBase:
    info("No git changes known for this file yet")
    return
  let root = findGitRoot(parentDir(b.path))
  if root.len == 0: return
  let (sa, se) = b.primary.range
  let l0 = sa.line
  let l1 = (if se.col == 0 and se.line > sa.line: se.line - 1 else: se.line)
  let ops = lineDiff(b.gitBase, b.lines)
  var outp: seq[string]
  var taken = 0
  var i = 0
  while i < ops.len:
    if ops[i].kind == ' ':
      outp.add ops[i].text
      inc i
      continue
    var dels, adds: seq[int]
    while i < ops.len and ops[i].kind != ' ':
      if ops[i].kind == '-': dels.add ops[i].aLine else: adds.add ops[i].bLine
      inc i
    let anchor = if adds.len > 0: adds[0] elif i < ops.len and ops[i].bLine >= 0: ops[i].bLine else: b.lines.len
    for k in 0 ..< max(dels.len, adds.len):
      let a = if k < dels.len: dels[k] else: -1
      let bl = if k < adds.len: adds[k] else: -1
      let picked = if bl >= 0: bl >= l0 and bl <= l1 else: anchor >= l0 and anchor <= l1 + 1
      if picked:
        inc taken
        if bl >= 0: outp.add b.lines[bl]
      elif a >= 0: outp.add b.gitBase[a]
  if taken == 0:
    info("No changed lines in the selection")
    return
  let rel = relativePath(b.path, root).replace('\\', '/')
  let tmp = privTmp("stage")
  let nl = if b.crlf: "\r\n" else: "\n"
  try: writeFile(tmp, outp.join(nl) & (if b.noEol: "" else: nl))
  except IOError, OSError: return
  let id = b.id
  # --path: the same clean filters and line-ending rules as `git add` would use for this file
  let after = proc() =
    let bb = bufById(id)
    if bb != nil: bb.refreshGit()
  gitShell("blob=$(git hash-object -w --path=" & quoteShell(rel) & " " & quoteShell(tmp) & ") && rm -f " &
           quoteShell(tmp) & " && mode=$(git ls-files -s -- " & quoteShell(rel) &
           " | cut -d' ' -f1) && git update-index --add --cacheinfo ${mode:-100644},$blob," & quoteShell(rel),
           "Staged " & $taken & " changed line(s)", after, root)

# history

proc commitFileDiff(root, hash, path: string) =
  let h = hash
  let p = path
  gitShowLines(root, h & "^:" & p, proc(before: seq[string]) =
    gitShowLines(root, h & ":" & p, proc(after: seq[string]) =
      openDiffView(h & " " & extractFilename(p), before, "before " & h & ": " & p, nil, after, h & ": " & p,
                   detectLang(root / p, ""))))

proc commitMenu(hash, subject: string) =
  let root = gitHome()
  if root.len == 0: return
  let h = hash
  discard startJob(jkGit, "git --no-pager show --name-status --format= " & h, root, proc(j: Job) =
    var items: seq[(string, string, Action)]
    for l in j.output.splitLines:
      let f = l.split('\t')
      if f.len < 2: continue
      let path = f[^1]
      let pp = path
      capture pp:
        items.add act(f[0] & "  " & pp, "see the change", proc() = commitFileDiff(root, h, pp))
    items.add act("Copy the hash", h, proc() =
      clipSet(h)
      info("Copied " & h))
    items.add act("The whole commit as text", "git show", proc() =
      toolOutput("commit " & h, "git --no-pager show --no-color " & h, root, proc(o: string): string = o, langByName("Diff")))
    items.add act("Create a branch here…", "", proc() =
      gitAsk("New branch at " & h, "", proc(t: string) = gitShell("git branch " & quoteShell(t) & " " & h, "Created " & t)))
    items.add act("Cherry-pick onto " & (if gitBranch.len > 0: gitBranch else: "this branch") & "…",
                  "copy this commit here", proc() =
      askConfirm("Copy " & h & " onto " & gitBranch & " (git cherry-pick)? (y/n)", proc(c: char) =
        if c in {'y', 'Y'}: gitShell("git cherry-pick " & h, "Cherry-picked " & h)))
    items.add act("Revert this commit…", "a new commit that undoes it", proc() =
      askConfirm("Make a commit that undoes " & h & "? (y/n)", proc(c: char) =
        if c in {'y', 'Y'}: gitShell("git revert --no-edit " & h, "Reverted " & h)))
    openActions(h & "  " & subject, items))

proc gitLogView() =
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  discard startJob(jkGit, "git --no-pager log --format='%h%x09%D%x09%s%x09%an%x09%ar' -n 400", root, proc(j: Job) =
    var items: seq[(string, string, Action)]
    for l in j.output.splitLines:
      let f = l.split('\t')
      if f.len < 5: continue
      let h = f[0]
      let s = f[2]
      capture h, s:
        items.add act((if f[1].len > 0: "◆ [" & f[1].replace("HEAD -> ", "") & "] " else: "◯ ") & s,
                      h & " · " & f[3] & " · " & f[4], proc() = commitMenu(h, s))
    if items.len == 0: info("No commits yet")
    else: openActions("History — pick a commit to see its files", items))

# stash

proc gitStashMenu() =
  let root = gitHome()
  if root.len == 0: return
  discard startJob(jkGit, "git stash list", root, proc(j: Job) =
    var items: seq[(string, string, Action)]
    items.add act("+ Stash my changes…", "put them aside (git stash push)", proc() =
      gitAsk("Stash message", "", proc(t: string) = gitShell("git stash push -m " & quoteShell(t), "Stashed")))
    items.add act("+ Stash, new files too…", "git stash push -u", proc() =
      gitAsk("Stash message", "", proc(t: string) = gitShell("git stash push -u -m " & quoteShell(t), "Stashed")))
    for l in j.output.splitLines:
      let c = l.find(':')
      if c <= 0: continue
      let r = l[0 ..< c]
      let desc = l[c + 1 .. ^1].strip
      capture r:
        items.add act(desc, r, proc() =
          openActions(r, @[
            act("Apply", "keep it in the list", proc() = gitShell("git stash apply " & r, "Applied " & r)),
            act("Pop", "apply and remove it", proc() = gitShell("git stash pop " & r, "Popped " & r)),
            act("Show", "its changes", proc() =
              toolOutput(r, "git --no-pager stash show -p --no-color " & r, root, proc(o: string): string = o, langByName("Diff"))),
            act("Drop…", "delete it", proc() =
              askConfirm("Delete " & r & "? (y/n)", proc(ch: char) =
                if ch in {'y', 'Y'}: gitShell("git stash drop " & r, "Dropped " & r)))]))
    openActions("Stash", items))

# merge / rebase in progress

proc gitState(): string =
  let root = gitHome()
  if root.len == 0: return ""
  if remotes.len > 0 and remoteOf(root) >= 0: return gitRepoInfo(root).state     # read on the server
  let g = root / ".git"
  if fileExists(g / "MERGE_HEAD"): "merge"
  elif dirExists(g / "rebase-merge") or dirExists(g / "rebase-apply"): "rebase"
  elif fileExists(g / "CHERRY_PICK_HEAD"): "cherry-pick"
  elif fileExists(g / "REVERT_HEAD"): "revert"
  else: ""

proc gitContinue() =
  let s = gitState()
  if s.len == 0:
    info("No merge or rebase in progress")
    return
  discard saveAll()
  gitShell("GIT_EDITOR=true git " & s & " --continue", s & " continued")

proc gitAbort() =
  let s = gitState()
  if s.len == 0:
    info("No merge or rebase in progress")
    return
  askConfirm("Abort the " & s & " and go back to how things were before it? (y/n)", proc(c: char) =
    if c in {'y', 'Y'}: gitShell("git " & s & " --abort", s & " aborted"))

# blame

proc gitBlame() =
  let b = buf()
  if b.path.len == 0: return
  let root = findGitRoot(parentDir(b.path))
  if root.len == 0:
    info("Not in a git repository")
    return
  let rel = relativePath(b.path, root)
  let name = b.name
  let lang = b.lang
  discard startJob(jkGit, "git --no-pager blame --date=short -- " & quoteShell(rel), root, proc(j: Job) =
    if j.code != 0:
      error("git blame: " & j.output.strip.splitLines()[0])
      return
    var outp: seq[string]
    var hashes: seq[string]
    for l in j.output.splitLines:
      if l.len == 0: continue
      let h = l.split(' ')[0].strip(chars = {'^'})
      let a = l.find('(')
      let e = l.find(')', a)
      if a < 0 or e < 0: continue
      let meta = l[a + 1 ..< e].splitWhitespace
      # (Author Name 2024-05-01 12)
      let date = if meta.len >= 2: meta[^2] else: ""
      let who = if meta.len > 2: meta[0 ..< meta.len - 2].join(" ") else: ""
      outp.add h[0 ..< min(7, h.len)] & "  " & date & "  " & truncTo(who, 14).alignLeft(14) & " │ " & l[e + 2 .. ^1]
      hashes.add h
    let bb = openScratch("Blame: " & name, outp.join("\n"), lang)
    blameBufs[bb.id] = hashes
    info("Blame — Enter on a line shows its commit"))

# extras

proc gitIgnore(path: string) =
  let root = findGitRoot(parentDir(path))
  if root.len == 0: return
  var rel = "/" & relativePath(path, root).replace('\\', '/')
  if dirExists(path): rel.add "/"
  try:
    let f = root / ".gitignore"
    var t = if fileExists(f): readFile(f) else: ""
    if t.len > 0 and not t.endsWith("\n"): t.add "\n"
    writeFile(f, t & rel & "\n")
    fileWritten(f)
    info("Added " & rel & " to .gitignore")
    refreshGitStatus()
  except CatchableError as e: error(e.msg)

proc gitClone() =
  gitAsk("Repository to clone (https://… or git@…)", "", proc(url: string) =
    var name = url.strip(chars = {'/'}).split({'/', ':'})[^1]
    if name.endsWith(".git"): name = name[0 ..< name.len - 4]
    let base = if rootDir.len > 1: parentDir(rootDir) else: getHomeDir()
    gitAsk("Clone into", base / name, proc(dest: string) =
      let d = expandTilde(dest)
      info("Cloning " & url & "…")
      discard startJob(jkGit, gitBatchEnv(parentDir(d)) & "git clone " &
                       quoteShell(url) & " " & quoteShell(d), parentDir(d), proc(j: Job) =
        if j.code == 0: openFolder(d)
        elif "terminal prompts disabled" in j.output or "Permission denied" in j.output or "could not read" in j.output:
          runInTerm("git clone " & quoteShell(url) & " " & quoteShell(d))
          info("git needs your login — finish in the terminal, then File › Open folder")
        else: error("git clone failed:\n" & j.output.strip.splitLines[^1]))))

proc remoteWebUrl(remote: string): string =
  ## the https address of a git remote, with any user name or token taken out
  var u = remote.strip
  if u.startsWith("git@"):
    u = "https://" & u[4 .. ^1].replace(":", "/")
  else:
    let p = u.find("://")
    if p >= 0:
      var rest = u[p + 3 .. ^1]
      let slash = rest.find('/')
      let at = rest.rfind('@', 0, (if slash < 0: rest.high else: slash))
      if at >= 0: rest = rest[at + 1 .. ^1]
      u = "https://" & rest
  if u.endsWith(".git"): u = u[0 ..< u.len - 4]
  u

proc gitCopyLink() =
  ## a link to the current line (or the selected lines) on GitHub / GitLab / Codeberg, at this commit
  let b = buf()
  if b.path.len == 0: return
  let root = findGitRoot(parentDir(b.path))
  if root.len == 0: return
  let rel = relativePath(b.path, root).replace('\\', '/')
  let (sa, se) = b.primary.range
  let l0 = sa.line + 1
  let l1 = se.line + 1
  discard startJob(jkGit, "git remote get-url origin && git rev-parse HEAD", root, proc(j: Job) =
    let ls = j.output.strip.splitLines
    if j.code != 0 or ls.len < 2:
      error("No remote called origin")
      return
    let u = remoteWebUrl(ls[0])
    let gitlab = "gitlab" in u
    let link = u & (if gitlab: "/-/blob/" else: "/blob/") & ls[1].strip & "/" & rel & "#L" & $l0 &
               (if l1 > l0: (if gitlab: "-" else: "-L") & $l1 else: "")
    clipSet(link)
    info("Copied the link:\n" & link))
