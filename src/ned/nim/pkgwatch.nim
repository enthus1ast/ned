# ── nimble packages installed (or removed) while ned runs: in ned's terminal, another one, or by nimble setup /
#    atlas. The compiler finds a new package at once, but what read the package folders when it started does not:
#    ned's engine (completion, hover, its checks), nimsuggest and nimlangserver. So when a package folder or a file
#    that puts packages on the path changes, the engine reads them again, `nim dump` is asked again, the Nim language
#    server starts again, and the open Nim files are checked again — no "cannot open file" for a package that is
#    there now ──

var
  pkgWatchAt: MonoTime                  # when the folders were last looked at
  pkgWatchStamp: Table[string, string]  # what they looked like then (path → its time; empty: not yet)

proc pkgWatchPaths(): seq[string] =
  ## the folders packages are installed in, and the files that put packages on a project's path
  let nd = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")
  result = @[nd / "pkgs2", nd / "pkgs"]          # (not ~/.nimble itself: nimble writes its own files there)
  for p in nxDumpLazy:
    if p notin result: result.add p
  var roots = @[rootDir]
  for r in wsRoots:
    if r notin roots: roots.add r
  for r in roots:
    if r.len <= 1: continue
    for p in [r / "nimbledeps" / "pkgs2", r / "nimbledeps" / "pkgs", r / "deps",
              r / "nimble.paths", r / "nim.cfg", r / "config.nims", r / "nimble.lock"]:
      result.add p

proc pkgWatchNow(): Table[string, string] =
  ## each path's modification time (a folder's changes when a package is added to it or taken out) — an empty
  ## folder counts as none: nimble makes ~/.nimble and its package folders before anything is installed in them
  for p in pkgWatchPaths():
    result[p] = "-"
    try:
      if dirExists(p):
        var empty = true
        for _ in walkDir(p):
          empty = false
          break
        if empty: continue
      let t = getLastModificationTime(p)
      result[p] = $t.toUnix & "." & $t.nanosecond
    except CatchableError: discard

proc pkgsChanged() =
  ## the packages changed: everything that read them reads them again
  nxDumped.clear()                       # (`nim dump` again: nimble.paths, nim.cfg, the package folders)
  nxApplyToolchain()                     # (the engine: the installed packages read again, what it resolved forgotten)
  if wkp != nil and not wkp.dead: wkSend(%*{"op": "packages"})   # (the engine worker: the same)
  var nimOpen = false
  for b in bufs:
    if b.lang == nil or b.lang.mode != lmNim or b.path.len == 0: continue
    nimOpen = true
    typingSig.del b.path                 # (the same code, checked again: what it imports may be there now)
    b.chkAt = (if b.dirty: -1 else: 0)
    nxEnsureToolchain(b)
  if not nimOpen: return
  nsShutdown()                           # (nimsuggest reads the package folders once, when it starts)
  var srv = false
  for s in servers:
    if s.langId == "nim" and not s.dead: srv = true
  if srv: restartLangServer("nim")       # (nimlangserver's nimsuggest: the same)
  for b in bufs:
    if b.lang != nil and b.lang.mode == lmNim and b.path.len > 0 and not b.dirty and not srv and
       not typingCheckUsable(b):
      runCheck(b)                        # (no check of the unsaved text: the one on save, now)
  info("Nimble packages changed — the Nim checks run again")

proc pkgWatchPump() =
  ## (the main loop, every two seconds) — a path looked at before that changed; one new to the list (a folder
  ## `nim dump` named after ned started, a workspace's folder) is only noted: nothing was installed by it
  if pkgWatchStamp.len > 0 and msSince(pkgWatchAt) < 2000: return
  pkgWatchAt = getMonoTime()
  let now = pkgWatchNow()
  var changed = false
  for p, t in now:
    if p in pkgWatchStamp and pkgWatchStamp[p] != t: changed = true
  pkgWatchStamp = now
  if changed: pkgsChanged()
