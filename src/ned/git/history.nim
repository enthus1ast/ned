# ── git: the history of some lines, bisect, worktrees, submodules ──

proc gitLineHistory() =
  ## every commit that changed these lines — the selection, else the routine the cursor is in (Nim), else this
  ## line — each with how it changed them (git log -L); Enter on a commit opens it
  let b = buf()
  let root = findGitRoot(parentDir(b.path))
  if b.path.len == 0 or root.len == 0 or not gitOk(root):
    info("Not a file in a git repository")
    return
  var a = b.primary.head.line
  var e = a
  var what = "line " & $(a + 1)
  if b.primary.hasSel:
    let (p, q) = b.primary.range
    a = p.line
    e = (if q.col == 0 and q.line > p.line: q.line - 1 else: q.line)
    what = "lines " & $(a + 1) & "–" & $(e + 1)
  elif b.lang.mode == lmNim:
    let f = nxFileFor(b)
    if f != nil:
      let ri = nxEnclosing(f, a)
      if ri >= 0 and f.syms[ri].endLine > f.syms[ri].line:
        a = f.syms[ri].line
        e = min(f.syms[ri].endLine, b.lines.high)
        what = f.syms[ri].name
  let rel = relativePath(b.path, root)
  let name = extractFilename(b.path)
  let cmd = "git --no-pager log --no-color --date=short --format='commit %H%n%an · %ad · %s' -L " & $(a + 1) & "," &
            $(e + 1) & ":" & quoteShell(rel)
  info("Looking through the history of " & what & "…")
  discard startJob(jkGit, cmd, root, proc(j: Job) =
    if j.code != 0:
      error("git log -L: " & (if j.output.strip.len > 0: j.output.strip.splitLines()[^1] else: "failed"))
      return
    var outL: seq[string]
    var hashes: seq[string]
    var cur = ""
    var n = 0
    let ls = j.output.splitLines
    var i = 0
    while i < ls.len:
      let l = ls[i]
      if l.startsWith("commit ") and l.len >= 47:
        cur = l[7 .. ^1].strip
        inc n
        if outL.len > 0:
          outL.add ""
          hashes.add cur
        let head = if i + 1 < ls.len: ls[i + 1] else: ""
        outL.add "@@ " & cur[0 ..< 8] & " · " & head & " @@"
        hashes.add cur
        i += 2
        continue
      if l.startsWith("diff --git") or l.startsWith("--- ") or l.startsWith("+++ "):
        inc i
        continue
      outL.add l
      hashes.add cur
      inc i
    if n == 0:
      info("No commit changed " & what & " (or they are not committed yet)")
      return
    let sb = openScratch("History of " & what & " · " & name, outL.join("\n") & "\n", langByName("Diff"))
    blameBufs[sb.id] = hashes
    info($n & " commit" & (if n == 1: "" else: "s") & " changed " & what & " — Enter on one opens it")
    needRender = true)

proc gitBisectReport(root, o: string) =
  ## where a bisect stands after a step; when it is over: the commit, and back to where you were
  for l in o.splitLines:
    let k = l.find(" is the first bad commit")
    if k > 0:
      let h = l[0 ..< k].strip
      bisectInfo = ""; bisectAt = ""; bisectSteps = ""
      var subj = ""
      let (ok, so, _) = runFilter("git --no-pager log -1 --format=%s " & quoteShell(h), "", root, 5000)
      if ok: subj = so.strip
      toast("Found it: " & h[0 ..< min(8, h.len)] & " " & subj & " is the first bad commit", 0, "Show it", proc() =
        commitMenu(h, subj), 30000)
      askConfirm("The first bad commit is " & h[0 ..< min(8, h.len)] & " " & truncTo(subj, 50) &
                 ". Stop bisecting and go back to where you were? (y/n)", proc(c: char) =
        if c in {'y', 'Y'}:
          bisectRoot = ""
          gitShell("git bisect reset", "Back to where you were", nil, root)
        commitMenu(h, subj))
      return
  var steps, at, subj = ""
  for l in o.splitLines:
    let r = l.find("(roughly ")
    if l.startsWith("Bisecting:") and r > 0:
      steps = l[r + 9 .. ^1].strip(chars = {')', ' '})
    elif l.startsWith("[") and "]" in l:
      let c = l.find(']')
      at = l[1 ..< c]
      subj = l[c + 1 .. ^1].strip
  if at.len > 0:
    bisectInfo = (if steps.len > 0: "about " & steps & " left · " else: "") & "testing " & at[0 ..< min(8, at.len)] & " " & subj
    bisectSteps = (if steps.len > 0: "about " & steps & " left" else: "")
    bisectAt = at
    bisectSubj = subj
    info("Bisect: " & bisectInfo & " — Git dock: Good, Bad or Skip")
  needRender = true

proc gitBisectStep(what: string) =
  ## good / bad / skip for the commit being tested; reset ends it
  let root = if bisectRoot.len > 0: bisectRoot else: gitHome()
  if not gitBisecting(root):
    info("No bisect in progress — Git: find the commit that broke it (bisect)…")
    return
  discard saveAll()
  discard startJob(jkGit, remoteGitBefore(root) & "git bisect " & what, root, proc(j: Job) =
    let o = stripAnsi(j.output)
    if j.code != 0:
      error("git bisect " & what & ": " & (if o.strip.len > 0: o.strip.splitLines()[^1] else: "failed"))
    elif what == "reset":
      bisectRoot = ""
      bisectInfo = ""; bisectAt = ""; bisectSteps = ""
      info("Bisect stopped — back to where you were")
    else: gitBisectReport(root, o)
    refreshGitStatus()
    checkDiskChanges()
    for b in bufs: refreshGit(b)
    remoteGitAfter(root))

proc bisectFromAct(root, h: string): Action =
  ## bisect from commit `h` (it worked there; it is broken now): say how to tell
  result = proc() =
    var how: seq[(string, string, Action)]
    how.add act("I'll say at each step", "Good / Bad / Skip in the Git dock", proc() =
      discard startJob(jkGit, remoteGitBefore(root) & "git bisect start HEAD " & quoteShell(h), root, proc(j: Job) =
        if j.code != 0:
          error("git bisect: " & j.output.strip.splitLines()[^1])
          return
        bisectRoot = root
        gitBisectReport(root, stripAnsi(j.output))
        showSide(svGit)
        refreshGitStatus()
        checkDiskChanges()
        remoteGitAfter(root)))
    how.add act("A command tells…", "exit 0 = it works; git runs it at each step", proc() =
      loadNimbleInfo()
      let guess = if nimble.dir.len > 0: "nimble test" elif lastRunCmd.len > 0: lastRunCmd else: "make test"
      askText("Command that succeeds when it works (exit 0) and fails when it is broken", guess, proc(t: string) =
        let c = t.strip
        if c.len == 0: return
        bisectRoot = root
        runCommand("git bisect start HEAD " & quoteShell(h) & " && git bisect run sh -c " & quoteShell(c), root)
        let jr = runningJob()
        if jr != nil:
          let prev = jr.onDone
          jr.onDone = proc(jj: Job) =
            if prev != nil: prev(jj)
            let o2 = stripAnsi(jj.output)
            if " is the first bad commit" in o2: gitBisectReport(root, o2)
            else:
              bisectRoot = ""
              discard startJob(jkGit, "git bisect reset", root, proc(_: Job) = refreshGitStatus())
              error("Bisect could not tell (see Output) — stopped, back to where you were")))
    openActions("How do we tell whether it works?", how)

proc gitBisectStart() =
  ## find the commit that broke something: pick one where it still worked, then say good or bad at each step —
  ## or give a command that tells (exit 0: works) and git runs it at each step
  let root = gitHome()
  if not gitOk(root):
    info("Not a git repository")
    return
  if gitBisecting(root):
    info("A bisect is already going — Git dock: Good, Bad, Skip, or Stop")
    return
  for l in gitRepoInfo(root).lines:
    if l.len > 3 and not l.startsWith("##") and not l.startsWith("??"):
      error("Commit or stash your changes first: bisect checks out older commits")
      return
  let (ok, o, _) = runFilter("git --no-pager log --format='%h%x09%s · %ar' -n 80", "", root, 8000)
  if not ok or o.strip.len == 0:
    error("No commits to look through")
    return
  var items: seq[(string, string, Action)]
  for l in o.strip.splitLines:
    let t = l.find('\t')
    if t < 0: continue
    let h = l[0 ..< t]
    let label = l[t + 1 .. ^1]
    items.add act(h & "  " & label, "", bisectFromAct(root, h))
  openActions("Bisect: pick a commit where it still worked (now it is broken)", items)

proc gitWorktrees() =
  ## the repository's worktrees (more checkouts of it, each on its own branch): open one, add one, remove one
  let root = gitHome()
  if not gitOk(root):
    info("Not a git repository")
    return
  let (ok, o, _) = runFilter("git worktree list --porcelain", "", root, 8000)
  if not ok:
    error("git worktree: " & o.strip)
    return
  let ri = if remotes.len > 0: remoteOf(root) else: -1
  var items: seq[(string, string, Action)]
  var path, br = ""
  var main = ""
  proc addOne(p, b: string) =
    if p.len == 0: return
    if main.len == 0: main = p
    let here = (ri < 0 and p == root) or (ri >= 0 and p == remotes[ri].absPath)
    let pp = p
    items.add act((if here: "● " else: "  ") & p, (if b.len > 0: b else: "detached") & (if here: " · this one" else: ""), proc() =
      var acts: seq[(string, string, Action)]
      if ri >= 0:
        acts.add act("Open it", "over SSH, like this folder", proc() = remoteOpen(remotes[ri].host & ":" & pp))
      else:
        acts.add act("Open it", "as the project", proc() = openFolder(pp))
        acts.add act("Add it to this workspace", "beside the open folders", proc() = wsAddFolder(pp))
      if not here and pp != main:
        acts.add act("Remove it…", "its folder goes; the branch stays", proc() =
          askConfirm("Remove the worktree " & pp & "? Its folder is deleted (the branch stays) (y/n)", proc(c: char) =
            if c in {'y', 'Y'}: gitShell("git worktree remove " & quoteShell(pp), "Worktree removed", nil, root)))
      openActions(pp, acts))
  for l in o.splitLines & @[""]:
    if l.startsWith("worktree "): path = l[9 .. ^1]
    elif l.startsWith("branch "): br = l[7 .. ^1].replace("refs/heads/", "")
    elif l.len == 0:
      addOne(path, br)
      path = ""
      br = ""
  let base = if ri >= 0: remotes[ri].absPath else: root
  items.add act("New worktree…", "a branch checked out in a folder of its own", proc() =
    let (ok2, bo, _) = runFilter("git for-each-ref --format='%(refname:short)' refs/heads", "", root, 8000)
    var bs: seq[(string, string, Action)]
    proc mk(branch: string, isNew: bool) =
      askText("Folder for it", parentDir(base) / extractFilename(base) & "-" & branch.replace('/', '-'), proc(t: string) =
        let p = t.strip
        if p.len == 0: return
        let cmd = "git worktree add " & (if isNew: "-b " & quoteShell(branch) & " " & quoteShell(p)
                                         else: quoteShell(p) & " " & quoteShell(branch))
        gitShell(cmd, "Worktree made: " & p, proc() =
          askConfirm("Open " & p & " now? (y/n)", proc(c: char) =
            if c in {'y', 'Y'}:
              if ri >= 0: remoteOpen(remotes[ri].host & ":" & p) else: openFolder(p)), root))
    bs.add act("A new branch…", "made from this one", proc() =
      askText("New branch name", "", proc(t: string) =
        if t.strip.len > 0: mk(t.strip, true)))
    if ok2:
      for l in bo.splitLines:
        let b = l.strip
        if b.len > 0 and b != gitRepoInfo(root).branch:
          capture b:
            bs.add act(b, "", proc() = mk(b, false))
    openActions("Worktree for which branch?", bs))
  items.add act("Prune", "forget worktrees whose folder is gone", proc() = gitShell("git worktree prune", "Pruned", nil, root))
  openActions("Worktrees of " & extractFilename(base), items)

proc submoduleAct(root, sp: string, st: char): Action =
  ## one submodule's menu
  let full = root / sp
  result = proc() =
    var acts: seq[(string, string, Action)]
    acts.add act("Update it", "to the commit this repository records (init if needed)", proc() =
      gitShell("git submodule update --init --recursive -- " & quoteShell(sp), "Updated " & sp, nil, root))
    if st != '-':
      if remotes.len == 0 or remoteOf(root) < 0:
        acts.add act("Show it in the Git dock", "its own changes and branches", proc() =
          gitPickRepoAct(full)()
          showSide(svGit))
        acts.add act("Open it", "as the project", proc() = openFolder(full))
      acts.add act("Record its current commit", "stage it here, to commit", proc() =
        gitShell("git add -- " & quoteShell(sp), "Staged " & sp & " at its current commit", nil, root))
    openActions(sp, acts)

proc gitSubmodules() =
  ## the repository's submodules: their state, update them, add one, show one in the Git dock
  let root = gitHome()
  if not gitOk(root):
    info("Not a git repository")
    return
  let (ok, o, _) = runFilter("git submodule status --recursive", "", root, 15000)
  var items: seq[(string, string, Action)]
  if ok:
    for l in o.splitLines:
      if l.len < 3: continue
      let st = l[0]
      let parts = l[1 .. ^1].strip.splitWhitespace
      if parts.len < 2: continue
      let sha = parts[0]
      let sp = parts[1]
      let state = case st
        of '-': "not checked out"
        of '+': "at another commit than the one recorded"
        of 'U': "merge conflicts"
        else: "up to date"
      items.add act(sp, sha[0 ..< min(8, sha.len)] & " · " & state, submoduleAct(root, sp, st))
  if items.len > 0:
    items.add act("Update all", "git submodule update --init --recursive", proc() =
      gitShell("git submodule update --init --recursive", "Submodules updated", nil, root))
  items.add act("Add a submodule…", "a repository's URL, then a folder for it", proc() =
    askText("Repository URL", "", proc(u: string) =
      let url = u.strip
      if url.len == 0: return
      var nm = url.strip(leading = false, chars = {'/'})
      nm = nm[nm.rfind({'/', ':'}) + 1 .. ^1]
      if nm.endsWith(".git"): nm = nm[0 ..< nm.len - 4]
      askText("Folder for it", nm, proc(p: string) =
        if p.strip.len > 0:
          if not gitArgSafe(url) or not gitArgSafe(p.strip):
            error("Not a repository URL and folder git can take: " & truncTo(url, 60))
            return
          gitShell("git submodule add -- " & quoteShell(url) & " " & quoteShell(p.strip), "Submodule added: " & p.strip,
                   nil, root))))
  openActions((if items.len > 1: "Submodules" else: "No submodules yet"), items)

# GitHub through gh
