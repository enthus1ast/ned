# ── ned --warm-index (6.32): Nim's standard library parsed once into the index cache (~/.cache/ned/index), so that
#    the first session's completion, hover and checks start at once instead of reading it then. The Termux package
#    runs it when it is installed (and a session after a new Nim reads only what changed) ──

proc warmIndexMain(args: seq[string]): int =
  ## ned --warm-index: finds Nim's standard library and parses every module of it (leaving out tests, examples and the
  ## JavaScript and Windows parts) into the index's disk cache, then once more with the defines `nim dump` gives; prints
  ## how many files and how long, unless -q. Gives the exit code, 1 when there is no library or the cache is off
  let t0 = getMonoTime()
  initLangs()
  rootDir = getCurrentDir()
  loadConfig()
  applyNimToolchain()
  nxInitDefines()
  nxLibFound = nxGuessLib()
  nxLibGuessed = true
  nxApplyToolchain()
  if nxLibFound.len == 0:
    stderr.writeLine "ned --warm-index: no Nim standard library found (is nim installed? Termux: pkg install nim)"
    return 1
  if not nxDiskCache:
    stderr.writeLine "ned --warm-index: the index cache is off (nim.indexCache)"
    return 1
  nxCacheTidyHere = nil          # (this process writes the cache: no engine worker of an editor here)
  var files: seq[string]
  for p in walkDirRec(nxLibFound, relative = false):
    if not p.endsWith(".nim"): continue
    let r = p[nxLibFound.len .. ^1]
    # (examples, tests and the JavaScript and Windows parts are seldom imported: read when they are)
    if "/tests/" in r or "/examples/" in r or r.startsWith("/js/") or r.startsWith("/windows/") or
       "/nimbase" in r: continue
    files.add p
  files.sort()
  var firstErr = ""
  proc pass(): int =
    ## parses each library file through the disk cache and gives how many worked; the first failure is kept to report
    for f in files:
      try:
        discard nxParseDisk(f)
        inc result
      except CatchableError as e:
        if firstErr.len == 0: firstErr = f & ": " & e.msg
  var n = pass()
  # again with the defines `nim dump` gives (what a session reads with once it has asked): the cache keeps both
  if haveExe("nim"):
    let tmp = getTempDir() / ("ned-warm-" & $getCurrentProcessId() & ".nim")
    try:
      writeFile(tmp, "")
      let (ok, o, _) = runFilter("nim dump --hints:off --warnings:off --dump.format:json " & quoteShell(tmp) &
                                 " 2>/dev/null", "", getTempDir(), 60000)
      if ok:
        nxDumpApply(tmp, o)
        n += pass()
    except CatchableError: discard
    try: removeFile(tmp)
    except CatchableError: discard
  if n == 0 and firstErr.len > 0: stderr.writeLine "ned --warm-index: " & firstErr
  let args0 = args
  if "-q" notin args0 and "--quiet" notin args0:
    echo "ned: Nim's standard library read into the index cache — ", files.len, " files in ",
         msSince(t0) div 1000, ".", (msSince(t0) mod 1000) div 100, " s (", nxCacheDirOf(), ")"
  0
