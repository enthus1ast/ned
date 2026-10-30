# ── git status when something changes, not every few seconds: the repository's .git folder (a commit, a stage,
#    a branch, a checkout, a pull — from ned, its terminal or anywhere), the project's folders and the open files'
#    are watched (inotify: Linux and Android); git status runs a moment after they change. Elsewhere — and for a
#    change deeper in the project than what is watched — the Git dock still looks every git.autoRefresh period
#    (a minute when the watching works) ──

when defined(linux) or defined(android):
  proc inotify_init1(flags: cint): cint {.importc, header: "<sys/inotify.h>".}
  proc inotify_add_watch(fd: cint, name: cstring, mask: uint32): cint {.importc, header: "<sys/inotify.h>".}
  var
    IN_NONBLOCK {.importc, header: "<sys/inotify.h>".}: cint
    IN_CLOEXEC {.importc, header: "<sys/inotify.h>".}: cint

const GitWatchMax = 400                  # folders watched at most (the project's first levels, the open files')

var
  gitWatchFd: cint = -1
  gitWatchRoot = ""                      # the repository watched
  gitWatchDirs: HashSet[string]
  gitWatchDirty = false                  # something changed: git status soon
  gitWatchAt: MonoTime                   # … when the last change came
  gitWatchRuns = 0                       # (git status runs it caused: perf report)

proc gitWatchAdd(dir: string): bool {.discardable.} =
  ## adds a folder to the inotify watch (for creating, deleting, renaming and writing files in it); false when it is
  ## watched already, is not a folder, the watch limit is reached, the watching is not running or the system refuses
  when defined(linux) or defined(android):
    if gitWatchFd < 0 or dir in gitWatchDirs or gitWatchDirs.len >= GitWatchMax or not dirExists(dir): return false
    # created, deleted, renamed, written and closed: what changes git's answer (not every read)
    let mask = 0x8'u32 or 0x40'u32 or 0x80'u32 or 0x100'u32 or 0x200'u32   # CLOSE_WRITE MOVED_FROM/TO CREATE DELETE
    if inotify_add_watch(gitWatchFd, dir.cstring, mask) < 0: return false
    gitWatchDirs.incl dir
    true
  else: false

proc gitWatchOn(): bool = gitWatchFd >= 0
  ## the watching works here (a slow look every minute is enough besides)

proc gitWatchStart() =
  ## (when the project's repository is known) watch its .git folder, refs, the project's folders two levels down
  ## and the open files' folders
  when defined(linux) or defined(android):
    let root = gitHome()
    if root.len == 0 or root == gitWatchRoot or remotes.len > 0 and remoteOf(root) >= 0: return
    if gitWatchFd >= 0: discard posix.close(gitWatchFd)
    gitWatchDirs.clear()
    gitWatchRoot = root
    gitWatchFd = inotify_init1(IN_NONBLOCK or IN_CLOEXEC)
    if gitWatchFd < 0: return
    let g = root / ".git"
    if not dirExists(g): return                  # (a worktree's .git is a file: looked at every git.autoRefresh)
    gitWatchAdd(g)
    for sub in ["refs", "refs/heads", "refs/remotes", "refs/tags"]: gitWatchAdd(g / sub)
    try:
      for k, d in walkDir(g / "refs" / "remotes"):
        if k == pcDir: gitWatchAdd(d)
    except OSError: discard
    gitWatchAdd(root)
    var level = @[root]
    for depth in 0 .. 1:
      var next: seq[string]
      for d in level:
        try:
          for k, e in walkDir(d):
            if k != pcDir: continue
            let n = extractFilename(e)
            if n.startsWith(".") or n in ["node_modules", "nimcache", "target", "build", "dist", "__pycache__",
                                           "nimbledeps", "deps", "vendor"]: continue
            if gitWatchAdd(e): next.add e
        except OSError: discard
      level = next
    for b in bufs:
      if b.path.startsWith(root & "/"): gitWatchAdd(parentDir(b.path))

proc gitWatchFds(fds: var seq[TPollfd]) =
  ## adds the watch's inotify descriptor to the set the main loop waits on, when the watching is running
  if gitWatchFd >= 0: fds.add TPollfd(fd: gitWatchFd, events: POLLIN)

proc gitWatchPump(ready: HashSet[cint]) =
  ## what changed came in: git status a moment later (changes come in bursts: a checkout writes many files), and
  ## not more often than every 2 s — or 10 times what git status takes in a big repository
  if gitHome() != gitWatchRoot and msSince(gitWatchAt) > 1000:
    gitWatchAt = getMonoTime()
    gitWatchStart()
  if gitWatchFd < 0: return
  let cp = buf().path
  if cp.len > 0 and cp.startsWith(gitWatchRoot & "/"): gitWatchAdd(parentDir(cp))   # (a file opened since: its folder)
  if gitWatchFd in ready:
    var tmp: array[8192, char]
    var got = false
    while true:
      let n = posix.read(gitWatchFd, addr tmp[0], tmp.len)
      if n <= 0: break
      got = true
    if got:
      gitWatchDirty = true
      gitWatchAt = getMonoTime()
  if gitWatchDirty and msSince(gitWatchAt) > 300 and not gitStatusBusy and
     msSince(gitStatusAt) > max(2000, 10 * gitStatusTook):
    gitWatchDirty = false
    inc gitWatchRuns
    refreshGitStatus()
    if buf().path.len > 0: refreshGit(buf())      # (the gutter of the file in front; the others when shown)
