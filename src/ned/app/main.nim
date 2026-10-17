# ════════════════════════════════════════════════════════════════════════════
#  Main loop
# ════════════════════════════════════════════════════════════════════════════

var SIGWINCH {.importc, header: "<signal.h>".}: cint

proc onWinch(sig: cint) {.noconv.} =
  gResized = true

var inputBacklog = false   # processInput stopped early to draw a frame; more keys are waiting

proc processInput(force: bool) =
  var k: Key
  let t0 = getMonoTime()
  var n = 0
  inputBacklog = false
  while not quitting and termSignal == 0 and parseKey(force, k):
    if k.kind == kNone: continue
    try:
      handleKey(k)
    except Exception as e:
      internalError("key " & $k.kind, e)
    inc n
    if (n and 15) == 0 and msSince(t0) > 50:
      inputBacklog = true          # a big burst (pasted keys, a stuck key): show progress, stay responsive
      break
  compactInput()

proc pumpJobs(ready: HashSet[cint]) =
  let snapshot = jobs
  for j in snapshot:
    if not j.eof and j.outFd in ready:
      var tmp: array[16384, char]
      while true:
        let n = posix.read(j.outFd, addr tmp[0], tmp.len)
        if n > 0:
          var chunk = newString(n)
          copyMem(addr chunk[0], addr tmp[0], n)
          jobChunk(j, chunk)
        elif n == 0:
          j.eof = true
          break
        else:
          if errno notin [EAGAIN, EINTR]: j.eof = true
          break
    if j.kind == jkAux and not j.done and msSince(j.started) > 4000:
      killProc(j.pr, SIGKILL)
      j.eof = true
    if j.deadlineMs > 0 and not j.done and not j.eof and msSince(j.started) > j.deadlineMs:
      killProc(j.pr, SIGKILL)
    if j.eof and j.outFd >= 0: closeFd(j.outFd)
    if j.eof and not j.done:
      if j.pr.reap():
        j.code = j.pr.code
        j.done = true
        closeProc(j.pr)
        if j.onDone != nil:
          try: j.onDone(j)
          except Exception as e: error("Job error: " & e.msg)
        needRender = true
  var keep: seq[Job]
  for j in jobs:
    if not j.done: keep.add j
  jobs = keep

var privSwept = false

proc mainLoop() =
  lastFileCheck = getMonoTime()
  while not quitting:
    if ttyGone and termSignal == 0: termSignal = SIGHUP.int    # no terminal left to draw on or read from
    if termSignal != 0:
      # the terminal went away (Termux session closed, ssh dropped) or we were asked to stop:
      # keep every unsaved edit in its recovery file and leave quietly
      for b in bufs:
        if b.dirty:
          b.swapAt = -1
          writeSwap(b, force = true)
      quitting = true
      break
    if gResized:
      gResized = false
      gridResize()
      for b in bufs: b.lastChange = -1      # keep the cursor visible when the keyboard opens/closes
      needRender = true
    if needRender:
      needRender = false
      try: render()
      except Exception as e:
        internalError("render", e)
      if startTrace and startRss.len == 0:
        smark("first frame")
        startRss.add ("first frame", rssMB())
      if not privSwept:
        privSwept = true
        privSweep()                  # (after the first frame: nothing in the way of the start)
    if startTrace and startRss.len == 1:
      # settled: the file list made, git and the other background jobs done (10 s at most)
      var busyJobs = false
      for j in jobs:
        if not j.done and j.kind notin {jkRun}: busyJobs = true
      let since = float((getMonoTime() - startT0).inMilliseconds)
      if (not scanning and not busyJobs and since - startMarks[^1][1] > 300) or since > 10_000:
        smark("settled")
        startRss.add ("settled", rssMB())
        quitting = true
        break
    var fds = @[TPollfd(fd: 0, events: POLLIN)]
    for j in jobs:
      if not j.eof: fds.add TPollfd(fd: j.outFd, events: POLLIN)
    for s in servers:
      if s.dead: continue
      fds.add TPollfd(fd: s.outFd, events: POLLIN)
      fds.add TPollfd(fd: s.errFd, events: POLLIN)
      if s.wbuf.len > 0: fds.add TPollfd(fd: s.inFd, events: POLLOUT)
    for s in nimSugs:
      if not s.dead and s.pr.outFd >= 0: fds.add TPollfd(fd: s.pr.outFd, events: POLLIN)
    mcpFds(fds)
    for fd in termFds(): fds.add TPollfd(fd: fd, events: POLLIN)
    if dbgOn and dbgProc.outFd >= 0: fds.add TPollfd(fd: dbgProc.outFd, events: POLLIN)
    if dbgOn and dbgDap and dapSock >= 0: fds.add TPollfd(fd: dapSock, events: POLLIN)
    if dbgOn and dbgDap and dapParentSock >= 0: fds.add TPollfd(fd: dapParentSock, events: POLLIN)
    var timeout = 2000
    let cb0 = buf()
    let busy = scanning or searchBuiltin or cb0.hlValid < cb0.hlTarget() or todoQueue.len > 0 or fmtAllOn
    if busy: timeout = 0
    if inBuf.len > 0: timeout = min(timeout, (if inputBacklog: 0 else: 25))
    if cfgAutoHover and not autoHoverFired:
      timeout = min(timeout, max(0, cfgHoverDelay - int(msSince(navAt))) + 5)
    if cfgLiveCheck and (cb0.dirty or cb0.chkAt >= 0) and cb0.chkAt != cb0.changeId and
       (nsUsable(cb0) or (cb0.lang != nil and cb0.lang.mode == lmNim)):
      timeout = min(timeout, 300)
    if sideView == svGit and treeOpen: timeout = min(timeout, 1000)
    for j in jobs:
      if j.eof: timeout = min(timeout, 30)
    for b in bufs:
      if b.lspDirty and (b.lspOpen or b.lspMore): timeout = min(timeout, 150)
    if msg.len > 0 and msSince(msgTime) < 6000: timeout = min(timeout, int(6001 - msSince(msgTime)))
    if toasts.len > 0: timeout = min(timeout, 500)
    let semStale = cfgSemColors and cb0.id in semMaps and semMaps[cb0.id].at != cb0.changeId
    if semStale: timeout = min(timeout, SemPauseMs + 10)
    for b in bufs:
      if b.todoBufStale():
        timeout = min(timeout, 320)
        break
    if flashBuf >= 0: timeout = min(timeout, 120)
    if aiBusy or aiInlineMode: timeout = min(timeout, 120)
    if mcpWaitReq: timeout = min(timeout, 200)
    if fixWanted > 0: timeout = min(timeout, 200)
    for t in terms:
      if t.replQ.len > 0: timeout = min(timeout, 250)
    if reapPids.len > 0: timeout = min(timeout, 500)
    if startTrace: timeout = min(timeout, 20)
    if cfgRefCounts and not refComplete and refFiles.len > 0: timeout = min(timeout, 20)   # the project's words
    if cfgTooltips and not tipShown and mouseX >= 0 and msSince(mouseMovedAt) < 700:
      timeout = min(timeout, max(1, 660 - int(msSince(mouseMovedAt))))
    if (cfgInlayHints or cb0.lang.mode == lmCsv) and cb0.inlayAt != cb0.changeId and cb0.path.len > 0: timeout = min(timeout, 400)
    if cb0.gitHasBase and cb0.gitAt != cb0.changeId: timeout = min(timeout, 250)
    if lspRestartAt.len > 0 or lspHoldAttach.len > 0: timeout = min(timeout, 100)
    if cfgGhostOn and cb0.dirty and cb0.changeId != ghostAskedChange:
      timeout = min(timeout, max(250, sInt("ai.inlineCompletionDelay")) + 20)
    if cfgBlame and blameText.len == 0 and cb0.inGit: timeout = min(timeout, 400)
    var anySwap = false
    for b in bufs:
      if b.changeId != b.swapAt and b.dirty: anySwap = true
    if anySwap: timeout = min(timeout, 1000)
    let r = poll(addr fds[0], fds.len.Tnfds, timeout.cint)
    if r < 0:
      if errno == EINTR: continue
      os.sleep(10)
      continue
    var ready: HashSet[cint]
    for f in fds:
      if (f.revents and (POLLIN or POLLHUP or POLLERR)) != 0: ready.incl f.fd
    if dbgOn and dbgProc.outFd >= 0 and dbgProc.outFd in ready:
      try: dbgRead()
      except CatchableError as e: dbgEnd("debugger error: " & e.msg)
    if dbgOn and dbgDap and dapParentSock >= 0 and dapParentSock in ready: dapDrainParent()
    if dbgOn and dbgDap and dapSock >= 0 and dapSock in ready:
      try:
        if not dapReadFd(dapSock): dbgEnd(if dbgState.startsWith("program exited"): dbgState else: "the debug adapter closed the connection")
      except CatchableError as e: dbgEnd("debugger error: " & e.msg)
    if (fds[0].revents and (POLLHUP or POLLERR or POLLNVAL)) != 0 and (fds[0].revents and POLLIN) == 0:
      ttyGone = true
    if 0.cint in ready:
      discard readInput()
      processInput(false)
    elif inputBacklog:
      processInput(false)
    elif inBuf.len > 0:
      processInput(true)
    try:
      # background work in small slices so typing always wins
      if inBuf.len == 0:
        if scanning: pumpScan(8)
        if searchBuiltin: pumpSearch(8)
        if fmtAllOn:
          fmtAllPump(25)
          if fmtAllOn: setMsg("Formatting " & $(fmtAllTotal - fmtAllQueue.len) & " of " & $fmtAllTotal & "…", 3)
        hlPump(buf(), 6)
        if todoTagsChanged:
          todoTagsChanged = false
          inc todoGen
          todoBufCache.clear()
          todoFiles.clear()
          todoScanned = false
          todoScanProject()
        if todoQueue.len > 0: todoPump(8)
        todoRefreshBufs()
        if ffiQueue.len > 0:
          let fb = bufById(ffiQueue[0])
          ffiQueue.delete(0)
          if fb != nil: ffiCheck(fb)
        if semStale and msSince(cb0.lspChangeAt) >= SemPauseMs: needRender = true   # semantic colours catch up
        if rightOpen and rightView == svTodos and msSince(todoScanAt) > 30_000: todoScanProject()
      if oscBgReply.len > 0: handleTermBg()
      if ciDue and getMonoTime() >= ciDueAt: ciRefresh()
      pumpJobs(ready)
      pumpTerms(ready)
      if reapPids.len > 0: reapPending()
      if mcpServers.len > 0: mcpPump(ready)
      if mcpWaitReq and not mcpStarting():
        mcpWaitReq = false
        aiRequest()
      if toasts.len > 0 and pruneToasts(): needRender = true
      if flashBuf >= 0:
        needRender = true
        if msSince(flashAt) > 1900: flashBuf = -1
      if aiBusy or aiInlineMode: needRender = true
      if aiCmdJob != nil and msSince(aiCmdJob.started) > 180_000:
        killProc(aiCmdJob.pr, SIGKILL)
      if cfgTooltips and not tipShown and mouseX >= 0 and msSince(mouseMovedAt) >= 650 and
         msSince(mouseMovedAt) < 2000:
        let ri = hitRegion(mouseX, mouseY)
        if ri >= 0 and regions[ri].tip.len > 0: needRender = true
      if (cfgInlayHints or cfgCsvAlign) and inBuf.len == 0: requestInlays(buf())
      if cfgCSigHints and inBuf.len == 0: cSigHintsUpdate(buf())
      if inBuf.len == 0: lspExtras(buf())
      if inBuf.len == 0: engineWarm(buf())
      if inBuf.len == 0: ghostTick()
      if inBuf.len == 0:
        let gb = buf()
        if gb.gitHasBase and gb.gitAt != gb.changeId and msSince(gb.lspChangeAt) > 200: updateGitMarks(gb)
        if splitOn:
          let ob = bufById(panes[1 - activePane].bufId)
          if ob != nil and ob.gitHasBase and ob.gitAt != ob.changeId and msSince(ob.lspChangeAt) > 200: updateGitMarks(ob)
        if cfgBlame: requestBlame(gb)
      var liveNs: seq[NimSug]
      for s in nimSugs:
        if not s.dead and s.pr.outFd in ready: nsRead(s)
        if s.dead:
          nsKill(s)
          needRender = true
        else: liveNs.add s
      nimSugs = liveNs
      if cfgNsMaxMB > 0:
        # nimsuggest can grow without bound on big projects: restart it past the limit (phones!)
        for s in nimSugs:
          if not s.dead and msSince(s.memAt) > 10_000:
            s.memAt = getMonoTime()
            let mb = procRssMB(s.pr.pid.int)
            if mb > cfgNsMaxMB:
              nsKill(s)
              toast("nimsuggest used " & $mb & " MB — restarted (settings › nim.nimsuggestMaxMB)", 2)
      if cfgNsIdleMin > 0:
        # nobody asked it anything for a while: give the memory back (it starts again on the next question)
        for s in nimSugs:
          if not s.dead and s.inflight.len == 0 and s.waiting.len == 0 and
             msSince(max(s.usedAt, s.started)) > cfgNsIdleMin * 60_000:
            nsKill(s)
            needRender = true
      # auto hover: the cursor came to rest on a symbol after navigation (not typing)
      let cb = buf()
      let hh = cb.primary.head
      if cb.id != navBuf:
        navBuf = cb.id
        navHead = hh
        navChange = cb.changeId
        autoHoverFired = true
      elif hh != navHead:
        if cb.changeId != navChange: autoHoverFired = true
        else:
          navAt = getMonoTime()
          autoHoverFired = false
          hoverOpen = false
        navHead = hh
        navChange = cb.changeId
      elif cb.changeId != navChange:
        navChange = cb.changeId
        autoHoverFired = true
      if cfgAutoHover and not autoHoverFired and msSince(navAt) >= cfgHoverDelay and focus == fEditor and
         pickKind == pickNone and promptKind == pNone and not compOpen and not hoverOpen and not helpOpen and
         not dialogOpen() and not menuOpen() and not replaceActive and inBuf.len == 0 and not mouseDragging:
        autoHoverFired = true
        cmdHover(auto = true)
      # live diagnostics through nimsuggest
      emitPump(cb)                         # clangd's copy of the C this Nim file emits
      embPump(cb)                          # the servers' copies of the HTML, CSS, SQL, JSON in its strings
      refLensPump(cb)                      # "3 references" beside the declarations on screen
      remoteAutoSync()                     # a remote folder: what changed on the server
      if cfgLiveCheck and cb.chkAt == 0 and not cb.dirty and cb.lang != nil and cb.lang.mode == lmNim and
         msSince(cb.lspChangeAt) > 1200 and cb.path notin typingChecks:
        # a project file just opened: its errors, without waiting for an edit or a save
        if rootDir.len > 0 and cb.path.startsWith(rootDir & "/") and typingCheckUsable(cb): typingCheck(cb)
        else: cb.chkAt = -1
      elif cfgLiveCheck and (cb.dirty or cb.chkAt > 0) and cb.chkAt != cb.changeId and msSince(cb.lspChangeAt) > 1200 and
         cb.path notin typingChecks and not cEngineOn(cb):           # (C: below)
        if typingCheckUsable(cb): typingCheck(cb)           # the compiler, on the unsaved text
        elif nsUsable(cb):
          cb.chkAt = cb.changeId
          discard nsRequest(cb, nsChk, Pos())
        else: cb.chkAt = cb.changeId                        # (nothing to check it with: on save, then)
      if cfgLiveCheck and cEngineOn(cb) and cb.dirty and cb.chkAt != cb.changeId and msSince(cb.lspChangeAt) > 1000 and
         not lspActiveFor(cb):
        cTypingCheck(cb)                                    # C: the compiler on the unsaved text
      if cfgLiveCheck and cb.dirty and cb.lang != nil and cb.lang.mode == lmNim and
         typoAt.getOrDefault(cb.id, -1) != cb.changeId and msSince(cb.lspChangeAt) > 500:
        engineTypos(cb)                                     # a misspelled name: at once
      if cfgGitAutoRefresh and (treeOpen and sideView in {svGit, svFiles}) and msSince(gitStatusAt) > 5000:
        refreshGitStatus()
      if wsRoots.len > 0 and cb.path.len > 0 and cb.path != gitFollowPath:
        # a workspace: the Git dock follows the open file to its folder's repository
        gitFollowPath = cb.path
        let g = findGitRoot(parentDir(cb.path))
        if g.len > 0 and g != gitHome() and g in gitRepoRoots(): gitPickRepoAct(g, quiet = true)()
      var alive: seq[LspServer]
      for s in servers:
        if not s.dead:
          if s.errFd in ready: lspReadErr(s)
          if s.outFd in ready: lspRead(s)
          if s.wbuf.len > 0: s.lspFlush()
        if s.dead:
          if s.errFd >= 0: lspReadErr(s)
          killProc(s.pr)
          discard waitProc(s.pr, 150)
          closeFd(s.inFd)
          closeFd(s.outFd)
          closeFd(s.errFd)
          if s.secondary:
            # a second server (a linter): its problems go; it is not started again this session
            for p, ds in diagsLsp.mpairs:
              var keep: seq[Diag]
              for d in ds:
                if d.srv != s.uid: keep.add d
              ds = keep
            if not s.stopped:
              lspMoreFailed.incl s.cmd.join(" ")
              let why = lspDeathReason(s)
              warn(s.name & " exited" & (if why.len > 0: ": " & truncTo(why, 100) else: "") &
                   " — not started again (palette: Restart language server)")
            needRender = true
            continue
          for b in bufs:
            if b.lang.id == s.langId: b.lspOpen = false
          if not s.stopped:
            lspLastLog[s.langId] = s.errTail
            # a server that ran for a while and then died is not "keeps crashing"
            let n = (if msSince(s.startedAt) > 120_000: 1 else: lspDeaths.getOrDefault(s.langId) + 1)
            lspDeaths[s.langId] = n
            let why = lspDeathReason(s)
            if n >= 3:
              lspFailed.incl s.langId
              warn(s.name & " keeps exiting" & (if s.langId == "nim" and haveExe("nimsuggest"):
                     " — using the built-in nimsuggest client instead" else: " — disabled") &
                   (if why.len > 0: " (" & truncTo(why, 90) & ")" else: "") & " · palette: Restart language server")
            else:
              warn(s.name & " exited" & (if why.len > 0: ": " & truncTo(why, 100) else: "") & " — restarting")
              lspRestartAt[s.langId] = getMonoTime() + initDuration(milliseconds = 800 * n)
          needRender = true
        else: alive.add s
      servers = alive
      if lspHoldAttach.len > 0:
        var due: seq[int]
        for id, t in lspHoldAttach:
          if getMonoTime() >= t: due.add id
        for id in due:
          let hb = bufById(id)
          if hb == nil: lspHoldAttach.del id
          else: lspAttach(hb)
      if lspRestartAt.len > 0:
        var due: seq[string]
        for lang, t in lspRestartAt:
          if getMonoTime() >= t: due.add lang
        for lang in due:
          lspRestartAt.del lang
          if lang notin lspFailed:
            for b in bufs:
              if b.lang.id == lang and b.path.len > 0 and b.title.len == 0:
                lspAttach(b)          # starts the server again; it opens every file of that language
                break
      for b in bufs:
        if b.lspDirty and (b.lspOpen or b.lspMore) and msSince(b.lspChangeAt) > 120: lspSync(b)
      if msSince(lastSwapCheck) > 900:
        lastSwapCheck = getMonoTime()
        for b in bufs:
          if b.changeId != b.swapAt and msSince(b.lspChangeAt) > 600: writeSwap(b)
      codeActionsOverdue()
      if msSince(lastFileCheck) > 2000:
        lastFileCheck = getMonoTime()
        checkDiskChanges()
        themeClockCheck()
        ollamaPullTick()
        if cfgAutoSave:
          for b in bufs:
            if b.dirty and b.path.len > 0 and b.group.time.ticks > 0 and msSince(b.lspChangeAt) > 1500:
              # never auto-save over a file that changed on disk or that another ned is editing
              if b.diskChanged or otherSessionEditing(b.path) > 0:
                if b.path notin autoSaveWarned:
                  autoSaveWarned.incl b.path
                  warn("Not auto-saving " & b.name & ": it changed on disk or is open in another ned — Ctrl+S to decide")
                continue
              discard b.saveBuffer()
      if msg.len > 0 and msSince(msgTime) >= 6000:
        msg = ""
        needRender = true
    except Exception as e:
      internalError("main loop", e)

proc usage() =
  echo AppName & " " & Version & " — fast, safe terminal code editor and Nim IDE for Termux, Linux and macOS"
  echo ""
  echo "Usage: ned [options] [file[:line[:col]] | +line file | folder] ..."
  echo "       command | ned [-]        open what the command printed (git log | ned)"
  echo ""
  echo "  -h, --help            show this help"
  echo "  -v, --version         show version"
  echo "  --check               check the setup: Nim, tools, clipboard, terminal (for bug reports too)"
  echo "  --default-settings    print the full settings file with every option and its default"
  echo "  --bench FILE          render FILE off-screen and print timings (performance check)"
  echo "  --format [--check] FILE|FOLDER…  format in place with ned's own formatters: Nim (nph style), JSON,"
  echo "                        Markdown tables, CSS; a folder: every such file in it (not what git ignores);"
  echo "                        --check: only list the files it would change (exit 1)"
  echo "  --startup-time [FILE…] start as usual, then quit once settled and print how long each step took"
  echo "                        and the memory used (the CI benchmark reads it)"
  echo "  --                    the rest are file names, even when they start with -"
  echo ""
  echo "Files:   settings  " & configFile()
  echo "         project   <folder>/.ned/settings.json"
  echo "         state     " & stateDir() & "  (session, recovery files, local history, chats)"
  echo ""
  echo "Inside ned: F10 menus · Ctrl+E command palette · Ctrl+P find file · F1 key bindings"

proc emergencySave() =
  ## crash: every unsaved buffer goes to its recovery file; the next start offers to restore it
  for b in bufs:
    if b.dirty:
      b.swapAt = -1
      writeSwap(b, force = true)
      if b.swapMine:
        stderr.writeLine("ned: unsaved edits of " & b.name & " are safe — start ned again to restore them")
      else:
        let p = (if b.path.len > 0: b.path else: rootDir / "untitled") & ".ned-recovery"
        try:
          writeFile(p, b.lines.join("\n") & "\n")
          stderr.writeLine("ned: unsaved changes written to " & p)
        except CatchableError: discard

proc onTermSignal(sig: cint) {.noconv.} =
  termSignal = sig.int

proc runBench(path: string) =
  ## ned --bench FILE > /dev/null : renders frames off-screen and reports timings on stderr
  initLangs()
  applyTheme(getEnv("NED_THEME", "nim-crown"))
  rootDir = getCurrentDir()
  scrW = 160
  scrH = 50
  grid.setLen(scrW * scrH)
  prevGrid.setLen(0)
  bufs = @[newBuffer()]
  initCommands()
  let b = openFile(path)
  if b == nil: quit "cannot open " & path
  proc bench(name: string, n: int, step: proc()) =
    let t0 = getMonoTime()
    for i in 0 ..< n:
      step()
      render()
    let dt = float((getMonoTime() - t0).inMicroseconds) / 1000.0
    stderr.writeLine(alignLeft(name, 22) & formatFloat(dt / float(n), ffDecimal, 3) & " ms/frame")
  render()
  bench("scroll", 400, proc() = buf().scrollBy(1))
  bench("cursor down", 400, proc() = cmdMove(kDown, false, false))
  bench("type", 300, proc() =
    buf().typeChar("x"))
  bench("idle redraw", 400, proc() = discard)
  block:
    let t0 = getMonoTime()
    for i in 0 ..< 400: flushScreen()
    stderr.writeLine("flush only            " & formatFloat(float((getMonoTime() - t0).inMicroseconds) / 400000.0, ffDecimal, 3) & " ms")
  b.centerOn(Pos(line: b.lines.len div 2, col: 0))
  bench("far jump", 100, proc() =
    let bb = buf()
    bb.centerOn(Pos(line: (bb.topLine + 9973) mod bb.lines.len, col: 0)))
  quit 0

proc formatFiles(args: seq[string]) =
  ## ned --format [--check] FILE|FOLDER… : ned's own formatters from the shell — Nim (nph's style), JSON,
  ## Markdown (tables), CSS and C (indentation and spaces). Each file is rewritten in place when it changes (written atomically); --check
  ## only says which would change (exit 1). A file a formatter is not sure about is left alone and named (exit 2).
  ## A folder: every file in it these formatters know (git's list in a repository: ignored files stay out).
  var check = false
  var files: seq[string]
  for a in args:
    if a == "--check": check = true
    elif a.len > 0:
      if dirExists(a):
        for p in fmtAllFiles(absolutePath(a)):
          if builtinFmtKind(p, "").len > 0: files.add relativePath(p, getCurrentDir())
      else: files.add a
  var named = false
  for a in args:
    if a != "--check" and a.len > 0: named = true
  if not named:
    quit "ned --format: which files? (ned --format [--check] file.nim README.md src/ …)", 2
  var changed, refused = 0
  for f in files:
    let kind = builtinFmtKind(f, "")
    if kind.len == 0:
      stderr.writeLine(f & ": ned has no formatter for this kind of file — left alone")
      continue
    var text = ""
    try: text = readFile(f)
    except CatchableError as e:
      stderr.writeLine(f & ": " & e.msg)
      inc refused
      continue
    let (res, err) = builtinFormatText(kind, text, 2, absolutePath(f))
    if err.len > 0:
      stderr.writeLine(f & ": " & err)
      inc refused
      continue
    if res == text: continue
    inc changed
    if check:
      echo f & ": would change"
      continue
    try:
      writeFileSafe(f, res)
      echo f & ": formatted"
    except CatchableError as e:
      stderr.writeLine(f & ": cannot write: " & e.msg)
      inc refused
  if refused > 0: quit 2
  if check and changed > 0: quit 1
  quit 0

proc isProjectDir(d: string): bool =
  ## does `d` look like the root of a project? (git, a .nimble file, Cargo.toml … — the same list the
  ## folder browser marks ◆)
  d.len > 0 and projectMarks(d).len > 0

proc projectRootOf(file: string): string =
  ## nearest folder above `file` that looks like a project root (never $HOME or above it)
  let home = getHomeDir().normalizedPath.strip(leading = false, chars = {'/'})
  var d = parentDir(file)
  for _ in 0 .. 40:
    if d.len <= 1 or d == home: break
    if isProjectDir(d): return d
    let up = parentDir(d)
    if up == d: break
    d = up
  ""

proc argNum(s: string): int =
  ## a line or column from the command line; absurd numbers become "the end"
  try: min(parseInt(s), 100_000_000)
  except ValueError: 100_000_000

proc main() =
  var targets: seq[(string, int, int)]
  var pendingLine = -1
  var optsDone, wantStdin, doCheck = false
  let cl = commandLineParams()
  var ai = 0
  while ai < cl.len:
    let a = cl[ai]
    inc ai
    if not optsDone and a.len > 1 and a[0] == '-':
      case a
      of "--": optsDone = true
      of "-h", "--help":
        usage()
        quit 0
      of "-v", "--version":
        echo AppName & " " & Version
        quit 0
      of "--check": doCheck = true
      of "--startup-time": startTrace = true
      of "--default-settings":
        applyTheme("nim-crown")
        stdout.write defaultSettingsText()
        quit 0
      of "--bench":
        if ai >= cl.len: quit "ned: --bench needs a file", 2
        runBench(cl[ai])
      of "--format":
        formatFiles(cl[ai .. ^1])
      else:
        stderr.writeLine("ned: unknown option " & a & " — see ned --help\n" &
          "     (to open a file whose name starts with -, use: ned -- " & a & ")")
        quit 2
      continue
    if a == "-" and not optsDone:
      wantStdin = true
      continue
    if a.len > 1 and a[0] == '+' and a[1 .. ^1].allDigits:
      pendingLine = argNum(a[1 .. ^1]) - 1
      continue
    var path = a
    var line = pendingLine
    var col = -1
    pendingLine = -1
    if not fileExists(path) and not dirExists(path):
      let parts = a.split(':')
      if parts.len >= 2 and parts[1].allDigits:
        path = parts[0]
        line = argNum(parts[1]) - 1
        if parts.len >= 3 and parts[2].allDigits: col = argNum(parts[2]) - 1
    targets.add (path, line, col)
  smark("command line")
  # tools installed by nimble/cargo/go/pip --user are often not on Termux's PATH
  var path = getEnv("PATH")
  let parts = path.split(':')
  for d in [getHomeDir() / ".nimble" / "bin", getHomeDir() / ".local" / "bin",
            getHomeDir() / ".cargo" / "bin", getHomeDir() / "go" / "bin"]:
    if dirExists(d) and d notin parts: path.add ':' & d
  putEnv("PATH", path)
  if doCheck:
    # ned --check: the same report as Help › Check setup, printed (works without a terminal, for bug reports)
    initLangs()
    loadState()
    rootDir = getCurrentDir()
    loadConfig()
    stdout.write setupReport(false)
    quit 0
  # piped input (`git log | ned`, `nim check x.nim | ned -`): read it, then take keys from the terminal
  var stdinText = ""
  var fromStdin = false
  if isatty(0) == 0 or wantStdin:
    if isatty(0) == 0:
      try: stdinText = stdin.readAll()
      except CatchableError: discard
      let tn = ttyname(1)
      let fd = posix.open((if tn != nil: tn else: cstring("/dev/tty")), O_RDWR)
      if fd < 0:
        stderr.writeLine("ned: no terminal to read keys from")
        quit 1
      discard dup2(fd, 0)
      discard posix.close(fd)
    fromStdin = wantStdin or stdinText.len > 0      # empty /dev/null input keeps the welcome page
  if isatty(1) == 0:
    stderr.writeLine("ned: stdout must be a terminal (ned --check works without one)")
    quit 1
  initLangs()
  smark("languages")
  loadState()
  loadRemotes()
  smark("state (recent files, layout)")
  # the project folder: a folder argument, else the project the first file belongs to (when ned
  # is started outside it, e.g. `ned ~/code/app/src/x.nim` from $HOME), else the current folder
  rootDir = getCurrentDir()
  for t in targets.mitems:
    if t[0].len > 0: t[0] = absolutePath(t[0]).normalizedPath
  var dirArg = false
  for t in targets:
    if dirExists(t[0]):
      rootDir = t[0]
      dirArg = true
      break
  if not dirArg and targets.len > 0 and not isProjectDir(rootDir):
    let r = projectRootOf(targets[0][0])
    if r.len > 0: rootDir = r
    elif rootDir == getHomeDir().normalizedPath.strip(leading = false, chars = {'/'}) or rootDir == "/":
      rootDir = parentDir(targets[0][0])
  if dirExists(rootDir) and rootDir != getCurrentDir():
    try: setCurrentDir(rootDir)
    except OSError: rootDir = getCurrentDir()
  smark("project folder")
  loadConfig()
  smark("settings")
  applyTheme(cfgThemeName)
  themeFollowers()
  smark("theme")
  trueColor = detectTrueColor()
  case sStr("ui.trueColor")
  of "on": trueColor = true
  of "off": trueColor = false
  else: discard
  bufs = @[newBuffer()]
  bufs[0].welcome = true
  initCommands()
  smark("commands")
  readBranch()
  smark("git branch")
  for t in targets:
    if dirExists(t[0]):
      treeOpen = true
      focus = fTree
      flattenTree()
    else:
      discard openFile(t[0], t[1], t[2])
  if fromStdin:
    let b = newBuffer()
    let txt = stripAnsi(stdinText).replace("\r\n", "\n")
    b.setContent(if txt.endsWith("\n"): txt[0 ..< ^1] else: txt)
    let l0 = b.lines[0]
    b.lang = if l0.startsWith("diff ") or l0.startsWith("--- ") or
                (l0.startsWith("commit ") and "\ndiff --git " in txt): langByName("Diff")
             else: detectLang("", l0)
    if bufs.len == 1 and bufs[0].isWelcome(): bufs[0] = b
    else: bufs.add b
    curBuf = bufs.find(b)
    focus = fEditor
  smark("files opened")
  signal(SIGWINCH, onWinch)
  signal(SIGPIPE, SIG_IGN)
  signal(SIGQUIT, SIG_IGN)         # Ctrl+\ is ned's terminal key; never a reason to stop (and drop unsaved work)
  signal(SIGHUP, onTermSignal)
  signal(SIGTERM, onTermSignal)
  probeTools()
  smark("tools looked up")
  # index the project in the background so Ctrl+P is instant (never the whole filesystem)
  if rootDir != "/" and rootDir.len > 1: startScan()
  smark("file list started")
  enterRaw()
  gridResize()
  loadingHook = showLoading            # from now on a big file shows "Opening …" while it loads
  var opened = fromStdin
  for t in targets:
    if fileExists(t[0]) or not dirExists(t[0]): opened = true
  if not opened: restoreSession()
  else: restoreBreakpoints()
  restoreLayout()
  checkRecoveryAtStart()
  smark("session restored")
  if gitRepoRoots().len > 0: refreshGitStatus()
  smark("git status started")
  try:
    mainLoop()
  except Exception as e:
    leaveRaw()
    cleanProjectTemps()
    emergencySave()
    stderr.writeLine("ned crashed: " & e.msg)
    stderr.writeLine(e.getStackTrace())
    quit 1
  finally:
    leaveRaw()
    cleanProjectTemps()
  saveState()
  if termSignal == 0:
    for b in bufs: removeSwap(b)     # a normal exit: unsaved edits were saved or discarded on purpose
  aiStop()
  killTerminals()
  lspShutdown()
  mcpStopAll()
  nsShutdown()
  if haveExe("ssh"):
    for r in remotes:                  # the shared ssh connections end with ned (where one was made)
      var st: Stat
      if stat(cstring(r.ctl), st) == 0: discard execShellCmd(sshCmd(r) & " -O exit >/dev/null 2>&1")
  for j in jobs:
    if not j.done: killProc(j.pr)
  if startTrace:
    # the report: each step with the time it took, the memory at the first frame and once settled
    var o = AppName & " " & Version & " — startup (ms since the program started)\n"
    var prev = 0.0
    for (n, t) in startMarks:
      o.add "  " & alignLeft(n, 30) & align(formatFloat(t, ffDecimal, 1), 8) & "   +" & formatFloat(t - prev, ffDecimal, 1) & "\n"
      prev = t
    for (n, m) in startRss: o.add "  memory " & alignLeft(n, 23) & align(formatFloat(m, ffDecimal, 1), 8) & " MB\n"
    block:
      var syms, docB, strB, lines = 0
      for _, f in nxFiles:
        if f == nil: continue
        syms += f.syms.len
        for sy in f.syms:
          docB += sy.doc.len
          strB += sy.name.len + sy.generics.len + sy.ret.len + sy.typ.len + sy.value.len + sy.pragmas.len + sy.owner.len
          for pp in sy.params: strB += pp.name.len + pp.typ.len + pp.default.len
      o.add "  Nim index: " & $nxFiles.len & (if nxFiles.len == 1: " module, " else: " modules, ") & $syms & " names, docs " &
            $(docB div 1024) & " KB, other text " &
            $(strB div 1024) & " KB\n"
    var kv = "STARTUP"
    for (n, t) in startMarks:
      if n in ["first frame", "settled"]: kv.add " " & n.replace(' ', '_') & "_ms=" & formatFloat(t, ffDecimal, 1)
    for (n, m) in startRss: kv.add " rss_" & n.replace(' ', '_') & "_mb=" & formatFloat(m, ffDecimal, 1)
    stderr.write o & kv & "\n"

when isMainModule and not defined(nedNoMain):     # (-d:nedNoMain: the engine driver of tests/engine)
  main()
