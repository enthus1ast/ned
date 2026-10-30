# ── git ──────────────────────────────────────────────────────────────────────

proc refreshGitStatus()

var gitStatusRuns = 0                   # (git status runs since ned started: the performance report)

proc gitRun(args: seq[string], okMsg: string) =
  ## run a git command in the repo root, report the result, refresh the git view
  let root = gitHome()
  if not gitOk(root):
    error("Not a git repository")
    return
  var cmd = "git"
  for a in args: cmd.add " " & quoteShell(a)
  discard startJob(jkGit, remoteGitBefore(root) & cmd, root, proc(j: Job) =
    let o = stripAnsi(j.output).strip
    if j.code == 0: info(okMsg & (if o.len > 0 and o.count('\n') == 0: " — " & o else: ""))
    else: error("git: " & (if o.len > 0: o.splitLines[^1] else: "failed"))
    refreshGitStatus()
    for b in bufs: refreshGit(b)
    remoteGitAfter(root))

proc gitStatusOf(path: string): char =
  ## a file's or folder's git mark (' ' none): its own, or '?' inside a folder git does not know
  result = gitFileStatus.getOrDefault(path, ' ')
  if result != ' ' or gitNewDirs.len == 0: return
  var d = parentDir(path)
  for _ in 0 .. 64:
    if d in gitNewDirs: return '?'
    let up = parentDir(d)
    if up.len == 0 or up == d: break
    d = up

type GitStatusRun = ref object
  pending: int
  outs: Table[string, string]

proc gitStatusDone(st: GitStatusRun) =
  ## every repository's status is in: the Git dock's (the active one), the file marks of all of them
  gitStatusBusy = false
  gitStatusAt = getMonoTime()
  gitStatusTook = int(msSince(gitStatusStart))
  gitRepos.setLen(0)
  gitFileStatus.clear()
  gitNewDirs.clear()
  gitDirty.clear()
  gitStatusLines.setLen(0)
  gitAhead = 0
  gitBehind = 0
  gitHasUpstream = false
  let home = gitHome()
  for root in gitRepoRoots():
    if root notin st.outs: continue
    var info = GitRepoInfo(root: root)
    for l in st.outs[root].splitLines:
      if l.startsWith("#ned-state "):
        info.state = l[11 .. ^1].strip
        continue
      # only git's status lines (not an ssh or git warning on the way)
      if l.startsWith("## ") or (l.len >= 4 and l[2] == ' ' and l[0] in " MADRCUT?!" and l[1] in " MADRCUT?!"):
        info.lines.add l
    if info.lines.len > 0 and info.lines[0].startsWith("## "):
      let h = info.lines[0][3 .. ^1]
      # "main...origin/main [ahead 1]" · "No commits yet on main" · "HEAD (no branch)"
      var br = h
      let dots = br.find("...")
      if dots >= 0: br = br[0 ..< dots]
      let sp = br.find(" [")
      if sp >= 0: br = br[0 ..< sp]
      if br.startsWith("No commits yet on "): br = br[18 .. ^1]
      elif br.startsWith("Initial commit on "): br = br[18 .. ^1]
      if br.startsWith("HEAD (no branch)"): br = "(detached)"
      info.branch = br.strip
      for (word, target) in [("ahead ", 0), ("behind ", 1)]:
        let k = h.find(word)
        if k > 0:
          var e = k + word.len
          while e < h.len and h[e] in Digits: inc e
          let n = (try: parseInt(h[k + word.len ..< e]) except ValueError: 0)
          if target == 0: info.ahead = n else: info.behind = n
      if root == home: gitHasUpstream = "..." in h
    for l in info.lines:
      if l.len < 4 or l.startsWith("## "): continue
      inc info.changes
      var path = l[3 .. ^1]
      let arrow = path.find(" -> ")
      if arrow >= 0: path = path[arrow + 4 .. ^1]
      if path.len > 1 and path[0] == '"': path = unquoteNim(path)
      var full = root / path
      let c = if l[0] == '?': '?' elif l[1] notin {' ', '?'}: l[1] else: l[0]
      if full.endsWith("/"):
        full.setLen(full.len - 1)
        if c == '?': gitNewDirs.incl full           # (a new folder: everything in it is new)
      gitFileStatus[full] = c
      var d = parentDir(full)
      while d.len > root.len and d notin gitDirty:
        gitDirty.incl d
        d = parentDir(d)
    if root == home:
      gitStatusLines = info.lines
      gitAhead = info.ahead
      gitBehind = info.behind
    gitRepos.add info
  readBranch()
  needRender = true

proc gitStatusJob(st: GitStatusRun, root: string) =
  ## starts `git status --porcelain=v1 -b` for one repository (for a remote folder also reading its merge / rebase state
  ## on the server) and keeps its output in the run; when the last repository of the run has answered — or could not
  ## start — gitStatusDone reads them all
  # a remote folder's merge / rebase state is read on the server too (there is no .git here to look at)
  let probe = if remotes.len > 0 and remoteOf(root) >= 0:
                "; g=$(git rev-parse --git-dir) && for f in MERGE_HEAD:merge rebase-merge:rebase rebase-apply:rebase " &
                "CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert; do [ -e \"$g/${f%%:*}\" ] && echo \"#ned-state ${f#*:}\" " &
                "&& break; done; true"
              else: ""
  # (-unormal: a new folder is one line, not every file in it — a folder of thousands is not listed; and no index
  # lock taken, so a git command of yours running meanwhile never finds the index locked)
  let j = startJob(jkGit, "git --no-optional-locks status --porcelain=v1 -b " &
                   (if cfgGitUntrackedAll: "-uall" else: "-unormal") & probe, root, proc(j: Job) =
    st.outs[root] = j.output
    dec st.pending
    if st.pending == 0: gitStatusDone(st))
  if j == nil:
    dec st.pending
    if st.pending == 0: gitStatusDone(st)

proc refreshGitStatus() =
  ## `git status` of every repository of the open folders (the project's, and a workspace's other folders')
  if gitStatusBusy: return
  var roots: seq[string]
  for r in gitRepoRoots():
    if gitOk(r): roots.add r
  if roots.len == 0: return
  gitStatusBusy = true
  gitStatusStart = getMonoTime()
  inc gitStatusRuns
  let st = GitStatusRun(pending: roots.len)
  for r in roots: gitStatusJob(st, r)

proc gitDiffView(path: string, staged: bool) =
  ## shows `git diff` of one file (the staged changes when `staged`) in the output view, as a diff
  let root = gitHome()
  if root.len == 0: return
  let cmd = "git --no-pager diff --no-color " & (if staged: "--cached " else: "") & "-- " & quoteShell(path)
  toolOutput("diff: " & extractFilename(path), cmd, root, proc(o: string): string = o, langByName("Diff"))
