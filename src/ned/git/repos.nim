# ── git repositories of the workspace: each folder's own; the Git dock and git commands act on one at a time ──

type GitRepoInfo = object
  root, branch, state: string            # state: merge, rebase, cherry-pick, revert or ""
  lines: seq[string]                     # its `git status --porcelain=v1 -b` lines
  changes, ahead, behind: int

var
  gitRepos: seq[GitRepoInfo]             # every repository of the open folders, from the last status
  gitRepo = ""                           # the repository the Git dock acts on ("": the project folder's)
  gitFollowPath = ""                     # the file whose repository the dock last followed

proc gitDirOf(root: string): string =
  ## the repository's git folder (in a worktree or a submodule, .git is a file that names it)
  let g = root / ".git"
  if dirExists(g): return g
  try:
    let t = readFile(g).strip
    if t.startsWith("gitdir:"):
      let d = t[7 .. ^1].strip
      return (if d.isAbsolute: d else: (root / d).normalizedPath)
  except CatchableError: discard
  g

var
  bisectRoot = ""                 # the repository being bisected
  bisectInfo = ""                 # "about 3 steps left · testing a1b2c3d Fix the parser"
  bisectSteps = ""                # "about 3 steps left"
  bisectAt = ""                   # the commit being tested
  bisectSubj = ""                 #   its subject

proc gitBisecting(root: string): bool =
  ## whether this repository is in the middle of a bisect: the one ned started (bisectRoot), or any local one with a
  ## BISECT_LOG in its git folder
  root.len > 0 and (bisectRoot == root or (remotes.len == 0 or remoteOf(root) < 0) and
                    fileExists(gitDirOf(root) / "BISECT_LOG"))

var gitSubCache: Table[string, (times.Time, seq[string])]   # repository → (.gitmodules' time, its checked-out submodules)

proc gitSubmodulesOf(root: string): seq[string] =
  ## a repository's checked-out submodules (from its .gitmodules, read again when it changes)
  if remotes.len > 0 and remoteOf(root) >= 0: return
  let gm = root / ".gitmodules"
  var t: times.Time
  try: t = getLastModificationTime(gm)
  except CatchableError: return
  if root in gitSubCache and gitSubCache[root][0] == t: return gitSubCache[root][1]
  var subs: seq[string]
  try:
    for l in lines(gm):
      let x = l.strip
      if x.startsWith("path") and '=' in x:
        let p = root / x[x.find('=') + 1 .. ^1].strip
        if dirExists(p / ".git") or fileExists(p / ".git"): subs.add p
  except CatchableError: discard
  gitSubCache[root] = (t, subs)
  subs

proc gitRepoRoots(): seq[string] =
  ## the repositories of the open folders (the project folder's first), each once; with their submodules
  for d in @[rootDir] & wsRoots:
    let g = findGitRoot(d)
    if g.len > 0 and g notin result:
      result.add g
      for sm in gitSubmodulesOf(g):
        if sm notin result: result.add sm

proc gitHome(): string =
  ## the repository git commands act on: the one picked in the Git dock (or followed from the open file), else
  ## the project folder's, else the first folder that has one
  if gitRepo.len > 0:
    let rs = gitRepoRoots()
    if gitRepo in rs: return gitRepo
    gitRepo = ""
  result = findGitRoot(rootDir)
  if result.len == 0 and wsRoots.len > 0:
    let rs = gitRepoRoots()
    if rs.len > 0: result = rs[0]

proc gitRepoInfo(root: string): GitRepoInfo =
  ## the last status read for this repository from gitRepos (an empty record when it is not there)
  for r in gitRepos:
    if r.root == root: return r

proc gitOk(root: string): bool =
  ## git can run for this repository: installed here, or a remote folder's (git runs on the server)
  root.len > 0 and (haveExe("git") or (remotes.len > 0 and remoteOf(root) >= 0))

proc readBranch() =
  ## sets gitBranch for the repository git commands act on: a remote folder's from its last status, else from .git/HEAD
  ## — the branch name, or the first seven letters of the commit when HEAD is detached
  gitBranch = ""
  let g = gitHome()
  if g.len == 0: return
  if remotes.len > 0 and remoteOf(g) >= 0:
    gitBranch = gitRepoInfo(g).branch              # the server's, from its last status
    return
  try:
    let head = readFile(g / ".git" / "HEAD").strip
    gitBranch = if head.startsWith("ref: refs/heads/"): head[16 .. ^1] else: head[0 ..< min(7, head.len)]
  except CatchableError: discard

proc refreshGit(b: Buffer) =
  ## reads what git knows of the buffer's file for the change marks in the gutter: the indexed version (kept as the base
  ## for exact marks while typing and for "Revert change"), and, when there is no base to be had (a new file), the marks
  ## from `git diff -U0`'s hunks. Two background jobs; the buffer is found again by id when they finish
  if b.path.len == 0 or not fileExists(b.path) or b.viewer != nil: return
  if not gitOk(findGitRoot(parentDir(b.path))): return
  b.inGit = true
  let id = b.id
  # the indexed version, for exact change marks while typing and for "Revert change"
  discard startJob(jkGit, "git --no-pager show " & quoteShell(":./" & extractFilename(b.path)),
                   parentDir(b.path), proc(j: Job) =
    let b = bufById(id)
    if b == nil: return
    if j.code != 0:
      b.gitHasBase = false
      b.gitBase.setLen(0)
      return
    var ls = j.output.split('\n')
    if ls.len > 0 and ls[^1].len == 0: ls.setLen(ls.len - 1)
    for x in ls.mitems:
      if x.endsWith("\r"): x.setLen(x.len - 1)
    b.gitBase = ls
    b.gitHasBase = true
    b.gitAt = -1
    needRender = true)
  discard startJob(jkGit, "git --no-pager diff --no-color --no-ext-diff -U0 -- " & quoteShell(b.path),
                   parentDir(b.path), proc(j: Job) =
    let b = bufById(id)
    if b == nil or j.code != 0 or b.gitHasBase: return
    var marks = newSeq[uint8](b.lines.len)
    for line in j.output.splitLines:
      if not line.startsWith("@@"): continue
      let f = line.splitWhitespace()
      if f.len < 3: continue
      proc rng(x: string): (int, int) =
        ## reads a hunk range such as "-12,3" or "+7" as (first line, number of lines), the count being 1 when it is
        ## left out
        let p = x[1 .. ^1].split(',')
        (parseInt(p[0]), (if p.len > 1: parseInt(p[1]) else: 1))
      try:
        let (_, oldN) = rng(f[1])
        let (start, newN) = rng(f[2])
        if newN == 0:
          let idx = clamp(start - 1, 0, marks.high)
          if marks.len > 0: marks[idx] = 3
        else:
          for k in 0 ..< newN:
            let idx = start - 1 + k
            if idx >= 0 and idx < marks.len: marks[idx] = (if oldN == 0: 1'u8 else: 2'u8)
      except ValueError: discard
    b.git = marks
    needRender = true)
