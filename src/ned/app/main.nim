# ════════════════════════════════════════════════════════════════════════════
#  Main loop
# ════════════════════════════════════════════════════════════════════════════

when not defined(windows):
  var SIGWINCH {.importc, header: "<signal.h>".}: cint

proc onWinch(sig: cint) {.noconv.} =
  ## the handler of the signal that the terminal was resized: it only notes it, and the main loop sizes the screen again
  gResized = true

var inputBacklog = false   # processInput stopped early to draw a frame; more keys are waiting
var workDeferred = false   # (a round had no room for all its background work: the next one comes at once)
var
  frameAt: MonoTime            # when the last frame was drawn
  frameHeld = false            # a frame waits (frames not asked for by input are paced)

proc processInput(force: bool) =
  ## takes the keys and mouse events that are waiting in the input buffer and hands each to handleKey (a failure becomes
  ## an internal-error note). After a burst of more than 50 ms it stops and notes the backlog, so that a frame is drawn
  ## and ned stays responsive. With `force` an event cut off at the end of the input — a half-arrived escape sequence —
  ## is taken as it is
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
    lastInputAt = getMonoTime()
    if (n and 15) == 0 and msSince(t0) > 50:
      inputBacklog = true          # a big burst (pasted keys, a stuck key): show progress, stay responsive
      break
  compactInput()

proc compilerRunning(): bool =
  ## is the compiler checking something now? (background compiler runs go one at a time)
  for j in jobs:
    if j.kind == jkCheck and not j.done: return true
  orRunning                         # (the compiler asked in the background: nim.compilerOracle)

proc pumpJobs(ready: HashSet[cint]) =
  ## services the background jobs: reads the output of those that poll says have some, kills an auxiliary job after 4
  ## seconds and any job past its own time limit, and for one whose output has ended and whose process is reaped records
  ## the exit code, marks it done and calls its callback; finished jobs are then dropped from the list
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
    if j.kind == jkAux and j.deadlineMs == 0 and not j.done and msSince(j.started) > 4000:
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
  startQueuedChecks()                # (a check ended: the next one waiting for its turn)

var privSwept = false

proc mainLoop() =
  ## the editor's main loop, until it is told to quit. A closed terminal or a stop signal saves every unsaved edit (hot
  ## exit, else recovery files) and leaves. Each round: sizes the screen after a resize; draws a frame when one is
  ## wanted, at most 60 a second (30 on a slow terminal) unless a key asked for it; waits with poll on the keyboard and
  ## every pipe that can speak — jobs, language servers, nimsuggest, MCP servers, the remote-control socket, plugins,
  ## notebooks, terminals, the git watcher, the debugger — for as long as the soonest thing that is due allows; reads
  ## the keys; then does the background work in small slices so that typing always wins (the file scan, searches,
  ## highlighting, TODOs, checks, hints, the engine's reading, git marks, language server traffic and restarts, recovery
  ## files, disk changes, autosave, the status message timing out)
  lastFileCheck = getMonoTime()
  var busyFrom = getMonoTime()
  while not quitting:
    when defined(nedMemProbe): memProbeTick("")               # (a build that finds leaks: tests/memory/memprobe.py)
    if ttyGone and termSignal == 0: termSignal = SIGHUP.int    # no terminal left to draw on or read from
    if termSignal != 0:
      # the terminal went away (Termux session closed, ssh dropped) or we were asked to stop:
      # keep every unsaved edit in its recovery file and leave quietly
      for b in bufs:
        if b.dirty:
          b.swapAt = -1
          writeSwap(b, force = true)
      if hotExitOn() and hotExitSave():
        for b in bufs: removeSwap(b)       # (the hot-exit file has them: back, unsaved, next time — no recovery asked)
      quitting = true
      break
    if gResized:
      gResized = false
      gridResize()
      for b in bufs: b.lastChange = -1      # keep the cursor visible when the keyboard opens/closes
      needRender = true
    # (frames no key or click asked for — a streaming answer, a terminal's or a job's output — 60 a second at most,
    # 30 on a slow terminal: a fast model's tokens were a frame each)
    frameHeld = needRender and lastInputAt < frameAt and not inputBacklog and
                msSince(frameAt) < (if slowTerminal(): 33 else: 16)
    if needRender and not frameHeld:
      needRender = false
      frameAt = getMonoTime()
      try:
        timedWork("drawing the screen"): render()
      except Exception as e:
        internalError("render", e)
      if startTrace and startRss.len == 0:
        smark("first frame")
        startRss.add ("first frame", rssMB())
      if not privSwept:
        privSwept = true
        timedWork("old temporary files"): privSweep()   # (after the first frame: nothing in the way of the start)
        menuDump()                                       # (NED_MENU_DUMP: the menus for the smoke test)
    caPump()                                # (the cursor's glide, a frame of its own: only the trail's cells)
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
    if focusNews != 0:
      let fnow = focusNews
      focusNews = 0
      if fnow == 1:
        lastFileCheck = getMonoTime()
        checkDiskChanges()                 # (back from another window: what changed meanwhile, at once)
      elif cfgSaveOnBlur: saveOnFocusLost()
    if tcSchemeNews: timedWork("terminal colours"): handleTermScheme()
    # the terminal lost the focus a while ago: what only serves the screen waits (jobs, terminals, servers go on)
    let away = cfgPauseAway and awayIdle()
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
    ctlFds(fds)
    plugFds(fds)
    nbFds(fds)
    for fd in termFds(): fds.add TPollfd(fd: fd, events: POLLIN)
    gitWatchFds(fds)
    wkFds(fds)
    if dbgOn and dbgProc.outFd >= 0: fds.add TPollfd(fd: dbgProc.outFd, events: POLLIN)
    if dbgOn and dbgDap and dapSock >= 0: fds.add TPollfd(fd: dapSock, events: POLLIN)
    if dbgOn and dbgDap and dapParentSock >= 0: fds.add TPollfd(fd: dapParentSock, events: POLLIN)
    var timeout = 2000
    let cb0 = buf()
    let busy = scanning or searchBuiltin or cb0.hlValid < cb0.hlTarget() or todoQueue.len > 0 or fmtAllOn
    if busy or lspMorePending: timeout = 0
    lspMorePending = false
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
    let semStale = (cfgSemColors and cb0.id in semMaps and semMaps[cb0.id].at != cb0.changeId) or inactiveDue(cb0)
    if semStale: timeout = min(timeout, SemPauseMs + 10)
    if cfgSemColors and cb0.id in semMaps and semMaps[cb0.id].impNext != nil: timeout = min(timeout, 10)
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
    timeout = min(timeout, plugNextDueMs())
    timeout = min(timeout, nbNextDueMs())             # (a cell running, its output to lay out)             # (a plugin's timer, the plugins' start, a change to tell them)
    if astOn or docPvSrc >= 0: timeout = min(timeout, 500)
    if lfBusy(): timeout = min(timeout, 30)            # (the viewer's index, a search: on while it lasts)   # (the AST view, the docs preview: after a pause)
    if workDeferred: timeout = min(timeout, 5)
    if frameHeld: timeout = min(timeout, max(1, (if slowTerminal(): 33 else: 16) - int(msSince(frameAt))))
    if cfgWebEngine != "off" and cb0.path.len > 0 and cb0.lang != nil and
       (webFamily(cb0.lang.id).len > 0 or cb0.lang.mode == lmNim) and webChkAt.getOrDefault(cb0.id, -1) != cb0.changeId:
      timeout = min(timeout, 420)                              # (ned's own CSS, HTML and SQL checks after a pause)
    if landBuf >= 0: timeout = min(timeout, 40)              # (the line a jump landed on, fading)
    if progressAnimating() or (progWas and msSince(progSince) < 600): timeout = min(timeout, 80)   # (the progress band)
    if cfgRefCounts and not refComplete and refFiles.len > 0: timeout = min(timeout, 20)   # the project's words
    if cfgRefCounts and refJobs.len > 0: timeout = min(timeout, 40)        # (a count of many places, going on)
    if cfgRefCounts and msSince(lastInputAt) < 450: timeout = min(timeout, 250)          # (the counts after scrolling)
    if nxWarmMods.len > 0: timeout = min(timeout, 60)          # (the imports' scopes, a few at a time while quiet)
    if nxCompletionPending(): timeout = min(timeout, 20)      # (completion's list, made a slice at a time)
    if nxPreloadQ.len > 0 or (nimEngineOn(cb0) and cb0.path.len > 0 and cb0.id notin nxPreloaded):
      timeout = min(timeout, 10)                               # (the files the open file's scope is made of)
    if cfgTooltips and not tipShown and mouseX >= 0 and msSince(mouseMovedAt) < 700:
      timeout = min(timeout, max(1, 660 - int(msSince(mouseMovedAt))))
    if (cfgInlayHints or cb0.lang.mode == lmCsv) and cb0.inlayAt != cb0.changeId and cb0.path.len > 0: timeout = min(timeout, 400)
    if cfgInlayHints and ihPending: timeout = min(timeout, 15)   # (the hints around the screen, a chunk at a time)
    if cb0.gitHasBase and cb0.gitAt != cb0.changeId: timeout = min(timeout, 250)
    if lspRestartAt.len > 0 or lspHoldAttach.len > 0: timeout = min(timeout, 100)
    if cfgGhostOn and cb0.dirty and cb0.changeId != ghostAskedChange:
      timeout = min(timeout, max(250, sInt("ai.inlineCompletionDelay")) + 20)
    if cfgBlame and blameText.len == 0 and cb0.inGit: timeout = min(timeout, 400)
    var anySwap = false
    for b in bufs:
      if b.changeId != b.swapAt and b.dirty: anySwap = true
    if anySwap: timeout = min(timeout, 1000)
    if away and not busy and inBuf.len == 0 and not inputBacklog and landBuf < 0: timeout = max(timeout, 1000)
    # (saving the battery: while you are not typing, background work in slices a tenth of a second apart)
    if batterySave and not busy and inBuf.len == 0 and not inputBacklog and msSince(lastInputAt) > 1500 and
       not frameHeld:
      timeout = max(timeout, 100)
    let caMs = caDueMs()
    if caMs >= 0: timeout = min(timeout, caMs)               # (the cursor's glide: its next frame)
    # (how long the round before took — a long one is a moment ned did not answer keys or the mouse)
    noteBusy(int((getMonoTime() - busyFrom).inMicroseconds))
    let r = poll(addr fds[0], fds.len.Tnfds, timeout.cint)
    busyFrom = getMonoTime()
    perfRoundStart()
    if r < 0:
      if errno == EINTR: continue
      os.sleep(10)
      continue
    var ready: HashSet[cint]
    for f in fds:
      if (f.revents and (POLLIN or POLLHUP or POLLERR)) != 0: ready.incl f.fd
    timedWork("the engine worker's answers"): wkRead(ready)
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
      timedWork("keys and mouse"): processInput(false)
    elif inputBacklog:
      timedWork("keys and mouse"): processInput(false)
    elif inBuf.len > 0:
      timedWork("keys and mouse"): processInput(true)
    try:
      # background work in small slices so typing always wins
      if inBuf.len == 0:
        if scanning: timedWork("the project's files listed"): pumpScan(8)
        if searchBuiltin: timedWork("search"): pumpSearch(8)
        if fmtAllOn:
          fmtAllPump(25)
          if fmtAllOn: setMsg("Formatting " & $(fmtAllTotal - fmtAllQueue.len) & " of " & $fmtAllTotal & "…", 3)
        timedWork("highlighting"): hlPump(buf(), 6)
        if todoTagsChanged:
          todoTagsChanged = false
          inc todoGen
          todoBufCache.clear()
          todoFiles.clear()
          todoScanned = false
          todoScanProject()
        # (the project's TODOs only in a round with room left: with the engine reading imports after it, two
        # slices made one 13-16 ms round)
        if todoQueue.len > 0 and msSince(busyFrom) < 3: timedWork("TODOs"): todoPump(4)
        # (the open files' tags in a round of their own: after the engine's reading, the two made a 16-20 ms round)
        if msSince(busyFrom) < 3: timedWork("TODOs"): todoRefreshBufs()
        if ffiQueue.len > 0:
          let fb = bufById(ffiQueue[0])
          ffiQueue.delete(0)
          if fb != nil: timedWork("C wrappers checked"): ffiCheck(fb)
        if semStale and msSince(cb0.lspChangeAt) >= SemPauseMs:
          needRender = true                    # semantic colours (and the code left out) catch up
          if inactiveDue(cb0): timedWork("code left out, dimmed"): discard inactiveRanges(cb0)
        if rightOpen and rightView == svTodos and msSince(todoScanAt) > 30_000: todoScanProject()
      if oscBgReply.len > 0: handleTermBg()
      if ciDue and getMonoTime() >= ciDueAt: timedWork("CI status"): ciRefresh()
      timedWork("results of programs (checks, git …)"): pumpJobs(ready)
      if ctlFd >= 0 or ctlClients.len > 0: timedWork("remote control"): ctlPump(ready)
      timedWork("terminals"): pumpTerms(ready)
      if reapPids.len > 0: timedWork("ended programs"): reapPending()
      if mcpServers.len > 0: timedWork("MCP servers"): mcpPump(ready)
      timedWork("plugins"): plugPump(ready)
      timedWork("notebook"): nbPump(ready)
      timedWork("Nim tour"): tourPump()
      if not syncStartDone: syncAtStart()
      if lfBusy() or buf().viewer != nil: timedWork("the large-file viewer"): lfPump()
      if dcView.bufId > 0: dcPump()
      if ce.viewBufId > 0: timedWork("Compiler Explorer"): cePump()
      if nifv.viewBufId > 0: timedWork("NIF view"): nifPump()
      if multiBufs.len > 0: timedWork("multibuffers"): mbPump()
      if macroViews.len > 0: timedWork("macro expansions"): mvPump()
      timedWork("nimble packages"): pkgWatchPump()
      batteryPump()
      lowMemPump()
      if astOn: astPump()
      if docPvSrc >= 0: docPvPump()
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
      if landBuf >= 0:
        needRender = true
        if msSince(landAt) > JumpHlMs: landBuf = -1
      if progressAnimating() or progressStarting(): needRender = true      # (the progress band, or its first frame)
      # (one heavy piece of work a round: hints, the engine's checks, reading imports, counts and macro names each
      # take up to a few dozen ms on a phone — two in one round and a key waits for both)
      workDeferred = false
      template roomLeft(): bool =
        ## whether this round has used less than 8 ms so far; if not, it notes that work was put off, so that the next
        ## round comes at once
        # (from the round's start: keys, the TODOs' slice and the hints count too)
        (if msSince(busyFrom) < 8: true else: (workDeferred = true; false))
      if (cfgInlayHints or cfgCsvAlign) and inBuf.len == 0 and not away: timedWork("type and parameter hints"): requestInlays(buf())
      if cfgCSigHints and inBuf.len == 0 and not away: timedWork("C signature hints"): cSigHintsUpdate(buf())
      if inBuf.len == 0 and not away: timedWork("language server requests"): lspExtras(buf())
      # (the engine's reading: early in a round only — the frame drawn after it takes 5-6 ms of its own)
      if inBuf.len == 0 and not away and not lowMemory:     # (short of memory: read when asked, not ahead)
        if msSince(busyFrom) < 3:
          timedWork("the engine reading imports"): engineWarm(buf())
        else: workDeferred = true
      if inBuf.len == 0 and not away and roomLeft(): timedWork("semantic colours"): semImportsPump(buf())
      if inBuf.len == 0 and not away:
        timedWork("AI suggestions"): ghostTick()
        timedWork("next edits"): nesTick()
      if inBuf.len == 0 and not away:
        let gb = buf()
        if gb.gitHasBase and gb.gitAt != gb.changeId and msSince(gb.lspChangeAt) > 200: timedWork("git marks"): updateGitMarks(gb)
        if splitOn:
          for pi in 0 ..< panes.len:
            let ob = if pi == activePane: nil else: bufById(panes[pi].bufId)
            if ob != nil and ob.gitHasBase and ob.gitAt != ob.changeId and msSince(ob.lspChangeAt) > 200:
              updateGitMarks(ob)
        if cfgBlame: timedWork("blame"): requestBlame(gb)
      var liveNs: seq[NimSug]
      for s in nimSugs:
        if not s.dead and s.pr.outFd in ready: timedWork("nimsuggest's answers"): nsRead(s)
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
      if cfgAutoHover and not autoHoverFired and not away and msSince(navAt) >= cfgHoverDelay and focus == fEditor and
         pickKind == pickNone and promptKind == pNone and not compOpen and not hoverOpen and not helpOpen and
         not dialogOpen() and not menuOpen() and not replaceActive and inBuf.len == 0 and not mouseDragging:
        autoHoverFired = true
        timedWork("hover"): cmdHover(auto = true)
      # live diagnostics through nimsuggest
      if not away:
        timedWork("clangd for the emitted C"): emitPump(cb)
        timedWork("servers for the languages in strings"): embPump(cb)
        if roomLeft(): timedWork("reference counts"): refLensPump(cb)
      timedWork("remote folder"): remoteAutoSync()   # a remote folder: what changed on the server
      if away: discard                     # (checks of what you look at: when you are back)
      elif cfgLiveCheck and not lowMemory and cb.chkAt == 0 and not cb.dirty and cb.lang != nil and cb.lang.mode == lmNim and
         msSince(cb.lspChangeAt) > 1200 and cb.path notin typingChecks and msSince(lastInputAt) > 800:
        # a project file just opened: its errors, without waiting for an edit or a save
        if rootDir.len > 0 and cb.path.startsWith(rootDir & "/") and typingCheckUsable(cb):
          timedWork("the compiler's check started"): typingCheck(cb)
        else: cb.chkAt = -1
      elif cfgLiveCheck and not batterySave and not lowMemory and (cb.dirty or cb.chkAt > 0) and cb.chkAt != cb.changeId and
         msSince(cb.lspChangeAt) > max(1200, min(4000, typingCheckMs.getOrDefault(cb.path, 0))) and
         cb.path notin typingChecks and not cEngineOn(cb) and not compOpen:   # (C: below)
        # (a check that takes long waits for a longer pause; none while the completion list is open: a word
        # half typed is an error the next key mends)
        if typingCheckUsable(cb):
          if cb.path in typingSig and typingSig[cb.path] == cb.typingCodeSig():
            cb.chkAt = cb.changeId                    # (only a comment or spacing changed: what it said stands)
            inc typingSkips
          else:
            timedWork("the compiler's check started"): typingCheck(cb)   # the compiler, on the unsaved text
        elif nsUsable(cb):
          cb.chkAt = cb.changeId
          discard nsRequest(cb, nsChk, Pos())
        else: cb.chkAt = cb.changeId                        # (nothing to check it with: on save, then)
      if cfgLiveCheck and not away and cEngineOn(cb) and cb.dirty and cb.chkAt != cb.changeId and
         msSince(cb.lspChangeAt) > 1000 and not lspActiveFor(cb):
        timedWork("the C compiler's check started"): cTypingCheck(cb)   # C: the compiler on the unsaved text
      if cfgLiveCheck and not away and cb.lang != nil and cb.lang.mode == lmNim and typoAt.getOrDefault(cb.id, -1) != cb.changeId and
         msSince(cb.lspChangeAt) > 500 and msSince(lastInputAt) > 300 and (nxWarmMods.len == 0 or wkOn()) and
         (cb.dirty or engineChecksOnOpen(cb)):
        # (a pause in typing and in scrolling: on a phone the checks of a big file take a moment; the imports read
        # first, a few at a time)
        if roomLeft(): timedWork("the engine's checks"): engineTypos(cb)
      if cfgOracle and not away and not lowMemory and cb.lang != nil and cb.lang.mode == lmNim and not compilerRunning() and
         msSince(lastInputAt) > 2500 and roomLeft():
        timedWork("the compiler asked in the background"): oracleStep(cb)
      if cfgMacroNames and cb.lang != nil and cb.lang.mode == lmNim and cb.path.len > 0 and cb.path notin nxMacroDone and
         cb.path notin mnDiskTried and nxDefinesComplete and mnUsable(cb.path):
        discard mnLoad(cb.path, cb.lines)          # (what its macro calls made, kept on disk for this text: at once)
      if cfgMacroNames and not away and not lowMemory and cb.lang != nil and cb.lang.mode == lmNim and mnSeen.getOrDefault(cb.id, -1) != cb.changeId and
         msSince(cb.lspChangeAt) > 1500 and msSince(lastInputAt) > 1000 and not compilerRunning():
        # (one compiler at a time, and not while you scroll or type: a phone has the CPU for one)
        if roomLeft(): timedWork("names macros make"): macroNamesFor(cb)
      if cfgWebEngine != "off" and not away and inBuf.len == 0 and roomLeft():
        timedWork("CSS, HTML and SQL checks"): webChecksPump(cb)        # ned's own (web.engine)
      # (every 5 s while the Git or Files dock shows it — less often in a repository git takes long over, and not
      # while you are away)
      if cfgGitAutoRefresh and not away and (treeOpen and sideView in {svGit, svFiles}) and
         msSince(gitStatusAt) > max((if gitWatchOn(): 60_000 else: 5000), 20 * gitStatusTook):
        timedWork("git status"): refreshGitStatus()
      timedWork("git status"): gitWatchPump(ready)      # (what changed in the repository: see git/watch)
      tsLivePump()                                       # (a live Telescope finder: its search as you type)
      if wsRoots.len > 0 and cb.path.len > 0 and cb.path != gitFollowPath:
        # a workspace: the Git dock follows the open file to its folder's repository
        gitFollowPath = cb.path
        let g = findGitRoot(parentDir(cb.path))
        if g.len > 0 and g != gitHome() and g in gitRepoRoots(): gitPickRepoAct(g, quiet = true)()
      var alive: seq[LspServer]
      for s in servers:
        if not s.dead:
          if s.errFd in ready: lspReadErr(s)
          if s.outFd in ready or s.rbuf.len > 0: timedWork("language servers' answers"): lspRead(s)
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
          else: timedWork("language servers started"): lspAttach(hb)
      if lspRestartAt.len > 0:
        var due: seq[string]
        for lang, t in lspRestartAt:
          if getMonoTime() >= t: due.add lang
        for lang in due:
          lspRestartAt.del lang
          if lang notin lspFailed:
            for b in bufs:
              if b.lang.id == lang and b.path.len > 0 and b.title.len == 0:
                timedWork("language servers started"): lspAttach(b)   # starts it again; it opens every file of that language
                break
      for b in bufs:
        if b.lspDirty and (b.lspOpen or b.lspMore) and msSince(b.lspChangeAt) > 120: timedWork("language servers told"): lspSync(b)
      if msSince(lastSwapCheck) > 900:
        lastSwapCheck = getMonoTime()
        for b in bufs:
          if b.changeId != b.swapAt and msSince(b.lspChangeAt) > 600: timedWork("recovery files"): writeSwap(b)
      timedWork("quick fixes asked"): codeActionsOverdue()
      if msSince(lastFileCheck) > 2000:
        lastFileCheck = getMonoTime()
        timedWork("files changed on disk"): checkDiskChanges()
        timedWork("theme clock"): themeClockCheck()
        timedWork("local model download"): ollamaPullTick()
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
  ## prints the help text of the command line: every option, the files ned keeps, and the main keys
  echo AppName & " " & Version & " — fast, safe terminal code editor and Nim IDE for Termux, Linux and macOS"
  echo ""
  echo "Usage: ned [options] [file[:line[:col]] | +line file | folder] ..."
  echo "       command | ned [-]        open what the command printed (git log | ned)"
  echo ""
  echo "  -h, --help            show this help"
  echo "  -v, --version         show version"
  echo "  --check               check the setup: Nim, tools, clipboard, terminal (for bug reports too)"
  echo "  --update              install the newest release, the way this ned was installed (it asks first;"
  echo "                        --check only says whether there is one, --yes does not ask); the package is"
  echo "                        checked against the release's SHA256SUMS and signature first. --update --verify"
  echo "                        DIR [FILE…]: check a release you downloaded the same way"
  echo "  --sandbox [options] [--] CMD…  run CMD (and what it starts) so that it changes files only in this folder,"
  echo "                        reads only it and the system's, and has no network (Linux: Landlock) — the way"
  echo "                        plugins run: ned --sandbox --help"
  echo "  --default-settings    print the full settings file with every option and its default"
  echo "  --doc-settings, --doc-commands  every setting, every command of the palette, as Markdown (the docs)"
  echo "  --reset [--yes] [--keep-plugins]  remove ned's settings, sessions, history, caches and downloads: ned"
  echo "                        starts as on its first run (asks first; --yes does not ask)"
  echo "  --bench FILE          render FILE off-screen and print timings (performance check)"
  echo "  --format [options] FILE|FOLDER…|-  format with ned's own formatters: Nim (nph style), JSON, Markdown"
  echo "                        tables, CSS, C, YAML, TOML; a folder: every such file in it (not what git ignores)."
  echo "                        --check (exit 1 if one would change), --diff, --out, --outDir, - (stdin),"
  echo "                        --install-hook (git pre-commit) … — the same as nedfmt: ned --format --help"
  echo "  --lint [options] [FILE|FOLDER…]  the Nim engine's checks without the compiler: misspelled names, fields,"
  echo "                        argument counts, unused imports and locals, a var that can be a let, deprecated or"
  echo "                        too-new library names … — text, GitHub annotations or JSON; --staged, --install-hook"
  echo "                        (git pre-commit): ned --lint --help"
  echo "  --warm-index [-q]     read Nim's standard library into the index cache once, so a first session's"
  echo "                        completion and hover start at once (the Termux package does it when installed)"
  echo "  --import-theme FILE…  turn Zed (.json) and Helix (.toml) themes into your own, in ned's themes folder"
  echo "  --lsp-bridge FILE.nims  run a language server written in NimScript (import nedlsp) with the protocol's"
  echo "                        framing on stdin/stdout — the command for ned's plugins and for other editors"
  echo "  --wait FILE…          in ned's terminal (or with --remote): open the files in the running ned and wait"
  echo "                        until their tabs are closed — git's editor: GIT_EDITOR=\"ned --wait\""
  echo "  --new                 start a new ned, even in ned's own terminal (where `ned FILE` opens FILE there)"
  echo "  --remote FILE[:LINE[:COL]]…  open the files in a ned that is running (the one whose project holds them,"
  echo "                        else the last started); with --wait, wait for their tabs to close"
  echo "  --remote-command NAME run a command of the palette there (\"Format document\", \"Run tests in file\" …)"
  echo "  --remote-message TEXT show a message there (scripts: \"build done\")"
  echo "  --remote-problems [NAME]  a build's or a linter's output on stdin → its Problems (file:line:col: msg,"
  echo "                        Nim's file(line, col) Error: …), under NAME; sending again replaces them"
  echo "  --remote-get WHAT     print file, line, col, selection, word, root, files or text of the running ned"
  echo "  --remote-list         the neds running for you: process, project, files"
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
  swapThreadStop()
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
  ## the handler of SIGHUP and SIGTERM: it only notes the signal, and the main loop saves the unsaved edits and leaves
  termSignal = sig.int

proc runBench(path: string) =
  ## ned --bench FILE > /dev/null : renders frames off-screen and reports timings on stderr
  wkBench = true
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
    ## runs `step` and draws a frame, `n` times, and prints to stderr the milliseconds a frame took and the bytes it
    ## sent to the terminal
    let t0 = getMonoTime()
    let bytes0 = frameBytesTotal
    for i in 0 ..< n:
      step()
      render()
    let dt = float((getMonoTime() - t0).inMicroseconds) / 1000.0
    # (and what each frame sent to the terminal: on a phone, what the terminal has to draw is what you wait for)
    stderr.writeLine(alignLeft(name, 22) & formatFloat(dt / float(n), ffDecimal, 3) & " ms/frame  " &
                     $((frameBytesTotal - bytes0) div n) & " bytes/frame")
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
  block:
    # the built-in terminal taking a flood of output (seq 1 200000) with 20 000 lines of scrollback kept: what it
    # does with each line, no process and no drawing
    let keep = cfgTermScrollback
    cfgTermScrollback = 20000
    let t = Term(w: 160, h: 40, fd: -1, autoWrap: true, cursorVisible: true, fg: NoColor, bg: NoColor, navCmd: -1)
    t.bot = t.h - 1
    for _ in 0 ..< t.h: t.scr.add t.blankRow
    var chunk = ""
    let t0 = getMonoTime()
    for n in 1 .. 200_000:
      chunk.add $n & "\r\n"
      if chunk.len >= 4096:
        t.feed(chunk)
        chunk.setLen(0)
    t.feed(chunk)
    stderr.writeLine("terminal flood        " &
                     formatFloat(float((getMonoTime() - t0).inMicroseconds) / 2000.0, ffDecimal, 3) & " ms/100k lines")
    cfgTermScrollback = keep
  quit 0

proc formatFiles(args: seq[string]) =
  ## ned --format [options] FILE|FOLDER… : the same as nedfmt (--check, --diff, --out, --outDir, - for stdin …),
  ## with the editor's own Nim formatting (the C in emits by clang-format, as Alt+F does)
  fmtVerifyFromCli = true
  quit fmtCliMain(args, "ned --format", Version, proc(text, path: string): (string, string) =
    cfgFormatEmitC = fmtEmitC                 # (fmtCliMain read this file's settings: yours, then its project's)
    cfgNimTarget = if fmtEmitCpp: "cpp" else: "c"
    nimFormatAll(text, path, ownWidth = false))      # (fmtCliMain worked out the width: settings, .editorconfig)

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

func argNum(s: string): int =
  ## a line or column from the command line; absurd numbers become "the end"
  try: min(parseInt(s), 100_000_000)
  except ValueError: 100_000_000

proc remoteMain(targets: seq[(string, int, int)], op, arg: string, explicit, wait, wantStdin: bool): int =
  ## `ned` as the running ned's remote: the exit code — or -1 when there is no ned to talk to and a ned of its own
  ## should start (in its terminal, where one ran before; EDITOR="ned --wait" outside one)
  let cwd = getCurrentDir()
  if op == "list":
    let all = ctlRunning()
    if all.len == 0:
      stderr.writeLine("ned: no ned is running")
      return 1
    for (p, j) in all:
      var files: seq[string]
      for f in j{"files"}: files.add relativePath(f.getStr, j{"root"}.getStr)
      echo $j{"pid"}.getInt & "  " & j{"root"}.getStr & (if files.len > 0: "  (" & files.join(", ") & ")" else: "")
    return 0
  let near = if targets.len > 0: absolutePath(targets[0][0]).normalizedPath else: cwd
  let implicit = op.len == 0 and not explicit
  let sock = if implicit: getEnv("NED_SOCKET") else: ctlFind(near)
  let alive = sock.len > 0 and ctlAsk(sock, %*{"cmd": "info"}, 1500) != nil
  if not alive:
    if implicit: return -1                     # (the ned whose terminal this was is gone: start one)
    stderr.writeLine("ned: no running ned to talk to (start one: ned [folder])")
    return 1
  case op
  of "command": return ctlClient(sock, %*{"cmd": "command", "name": arg}, false)
  of "message": return ctlClient(sock, %*{"cmd": "message", "text": arg}, false)
  of "get": return ctlClient(sock, %*{"cmd": "get", "what": arg}, false)
  of "problems":
    var text = ""
    try: text = stdin.readAll()
    except CatchableError: discard
    return ctlClient(sock, %*{"cmd": "problems", "source": arg, "text": text, "cwd": cwd}, false)
  else: discard
  var piped = ""
  if isatty(0) == 0 or wantStdin:
    if isatty(0) == 0:
      try: piped = stdin.readAll()
      except CatchableError: discard
  if targets.len == 0 and piped.len == 0:
    if implicit:
      stderr.writeLine("ned: this is ned's terminal — `ned FILE` opens FILE in it, `ned --new` starts another ned")
      return 0
    stderr.writeLine("ned: --remote needs files (or text on stdin)")
    return 2
  var code = 0
  if piped.len > 0:
    code = ctlClient(sock, %*{"cmd": "text", "text": piped, "wait": wait and targets.len == 0}, wait and targets.len == 0)
  if targets.len > 0:
    var files = newJArray()
    for (p, l, c) in targets:
      files.add %*{"path": absolutePath(p).normalizedPath, "line": l, "col": c}
    code = max(code, ctlClient(sock, %*{"cmd": "open", "files": files, "wait": wait}, wait))
  code

proc main() =
  ## starts ned. Reads the command line — options, and files as FILE:LINE:COL or +LINE FILE — and runs the ones that do
  ## something else and exit (help, version, --check, --format, --lint, --update, --sandbox, --reset, --bench, the
  ## --remote ones …). When a ned is running, `ned FILE` in its terminal and the remote options talk to it instead.
  ## Otherwise it puts the Nim, Cargo and Go tool folders on PATH, takes piped input and keys from the terminal, chooses
  ## the project folder, loads state, settings and theme, makes the first tab and opens the files, sets the signal
  ## handlers, starts the file scan and the control socket, enters raw mode and restores the session, layout, unsaved
  ## edits and recovery files, then runs the main loop. A crash writes recovery files and the stack trace; a leave saves
  ## the state and stops the assistant, terminals, language servers, MCP servers, plugins, nimsuggest, the engine
  ## worker, ssh connections and jobs, and with --startup-time prints how long each step took
  var targets: seq[(string, int, int)]
  var pendingLine = -1
  var optsDone, wantStdin, doCheck = false
  var wantNew, wantWait, wantRemote = false
  var remoteOp, remoteArg = ""            # --remote-command NAME, --remote-message TEXT, --remote-get WHAT …
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
      of "--engine-worker": workerMain()          # (the editor's engine worker: nim/worker.nim)
      of "--update": quit updateMain(cl[ai .. ^1])
      of "--sandbox": quit sandboxMain(cl[ai .. ^1])     # (sys/landlock.nim: a command limited by Landlock)
      of "--term-host":                           # (a kept terminal's shell: term/termhost.nim)
        when not defined(windows): termHostMain(cl[ai .. ^1])
        else: quit 2
      of "--check": doCheck = true
      of "--reset": quit resetCli(cl[ai .. ^1])
      of "--startup-time": startTrace = true
      of "--default-settings":
        applyTheme("nim-crown")
        stdout.write defaultSettingsText()
        quit 0
      of "--doc-settings":
        applyTheme("nim-crown")
        stdout.write settingsMarkdown()
        # (and what is wrong with them, on stderr — tests/docs/wiring.py fails on it: a setting declared twice, a
        # choice whose default is none of its values, one with no description)
        var seen: HashSet[string]
        for d in setDefs:
          if seen.containsOrIncl(d.key): stderr.writeLine "setting " & d.key & ": declared twice"
          if d.kind == skEnum and d.def.getStr notin d.opts:
            stderr.writeLine "setting " & d.key & ": its default " & $d.def & " is none of its values " & $d.opts
          if d.doc.strip.len < 12: stderr.writeLine "setting " & d.key & ": no description a person can act on"
          if not validSetting(d, d.def): stderr.writeLine "setting " & d.key & ": its default is not a valid value"
        quit 0
      of "--doc-commands":
        applyTheme("nim-crown")
        stdout.write commandsMarkdown()
        quit 0
      of "--bench":
        if ai >= cl.len: quit "ned: --bench needs a file", 2
        runBench(cl[ai])
      of "--format":
        formatFiles(cl[ai .. ^1])
      of "--lint":
        quit lintMain(cl[ai .. ^1])
      of "--warm-index":
        quit warmIndexMain(cl[ai .. ^1])
      of "--import-theme": quit importThemeCli(cl[ai .. ^1])
      of "--lsp-bridge":
        # (a language server written in NimScript — nedlsp — given the protocol's framing: for ned and other editors)
        if ai >= cl.len: quit "ned: --lsp-bridge needs a .nims file", 2
        quit lspBridge(cl[ai])
      of "--new": wantNew = true
      of "--wait": wantWait = true
      of "--remote": wantRemote = true
      of "--remote-list": remoteOp = "list"
      of "--remote-command", "--remote-message", "--remote-get":
        if ai >= cl.len: quit "ned: " & a & " needs a value — see ned --help", 2
        remoteOp = a[9 .. ^1]
        remoteArg = cl[ai]
        inc ai
      of "--remote-problems":
        remoteOp = "problems"
        if ai < cl.len and not cl[ai].startsWith("-"):
          remoteArg = cl[ai]
          inc ai
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
      # FILE:LINE[:COL] (a Windows drive's colon is the path's: C:/x.nim:10)
      let drive = when defined(windows): (if a.len >= 2 and a[1] == ':': a[0 .. 1] else: "") else: ""
      let parts = a[drive.len .. ^1].split(':')
      if parts.len >= 2 and parts[1].allDigits:
        path = drive & parts[0]
        line = argNum(parts[1]) - 1
        if parts.len >= 3 and parts[2].allDigits: col = argNum(parts[2]) - 1
    targets.add (path, line, col)
  smark("command line")
  if remoteOp.len > 0 or wantRemote or (not wantNew and not doCheck and not startTrace and getEnv("NED_SOCKET").len > 0):
    let code = remoteMain(targets, remoteOp, remoteArg, wantRemote, wantWait, wantStdin)
    if code >= 0: quit code
  # tools installed by nimble/cargo/go/pip --user are often not on Termux's PATH
  var path = getEnv("PATH")
  let parts = path.split(PathSep)
  for d in [getHomeDir() / ".nimble" / "bin", getHomeDir() / ".local" / "bin",
            getHomeDir() / ".cargo" / "bin", getHomeDir() / "go" / "bin"]:
    if dirExists(d) and d notin parts: path.add PathSep & d
  putEnv("PATH", path)
  if doCheck:
    # ned --check: the same report as Help › Check setup, printed (works without a terminal, for bug reports)
    initLangs()
    loadState()
    rootDir = getCurrentDir()
    loadConfig()
    applyNimToolchain()
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
  applyNimToolchain()                 # (the project's Nim first on PATH, before anything is started)
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
  if fromStdin: openTextBuffer(stdinText)
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
  ctlListen()                          # (`ned FILE` in its terminal, git's editor, scripts: see control)
  enterRaw()
  gridResize()
  loadingHook = showLoading            # from now on a big file shows "Opening …" while it loads
  var opened = fromStdin
  for t in targets:
    if fileExists(t[0]) or not dirExists(t[0]): opened = true
  if not opened: restoreSession()
  else: restoreBreakpoints()
  termReattach()                       # (terminal.keepRunning: the terminals kept running since last time)
  when defined(windows):
    if isCmdExe(winShell()[0]):
      toast("Git for Windows' sh was not found: builds, checks and tasks run through cmd.exe, where some of them " &
            "fail — winget install Git.Git (Help › Check setup)", 2)
  restoreLayout()
  hotExitRestore()                     # (files.hotExit: the unsaved edits of last time, in their tabs)
  checkRecoveryAtStart()
  keysCheckAtStart()                   # (the "keys" setting: an unknown command, a key no terminal sends)
  smark("session restored")
  if gitRepoRoots().len > 0: refreshGitStatus()
  smark("git status started")
  try:
    lastInputAt = getMonoTime()     # (what starts in the background waits for the first frame and a moment of calm)
    perfTraceOn = getEnv("NED_PERF_TRACE").len > 0
    mainLoop()
    # (NED_PERF_LOG=file: the performance report written there on the way out — for measuring, and tests)
    let perfLog = getEnv("NED_PERF_LOG")
    if perfLog.len > 0:
      try: writeFile(perfLog, perfReport())
      except CatchableError: discard
    if perfTraceOn:
      try: writeFile(getEnv("NED_PERF_TRACE"), perfTrace.join("\n") & "\n")
      except CatchableError: discard
  except Exception as e:
    leaveRaw()
    cleanProjectTemps()
    emergencySave()
    stderr.writeLine("ned crashed: " & e.msg)
    stderr.writeLine(e.getStackTrace())
    quit 1
  finally:
    leaveRaw()
    ctlClose()
    cleanProjectTemps()
  if resetPending.len == 0: saveState()     # (Reset everything: no state written back)
  if termSignal == 0:
    for b in bufs: removeSwap(b)     # a normal exit: unsaved edits were saved or discarded on purpose
  swapThreadStop()                   # (the recovery files it was writing or removing: done before ned leaves)
  aiStop()
  killTerminals()
  lspShutdown()
  mcpStopAll()
  plugQuitEvents()
  syncAtQuit()                       # (sync.auto: this device's changes saved there, a few seconds at most)
  plugStopAll()
  nsShutdown()
  wkStop()
  if haveExe("ssh"):
    for r in remotes:                  # the shared ssh connections end with ned (where one was made)
      var st: Stat
      if stat(cstring(r.ctl), st) == 0: discard execShellCmd(sshCmd(r) & " -O exit >/dev/null 2>&1")
  for j in jobs:
    if not j.done: killProc(j.pr)
  resetFinish()                      # (Reset everything: the parts removed, ned started again)
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
