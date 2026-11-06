# ════════════════════════════════════════════════════════════════════════════
#  What many commands do: quitting, the docks and the panel, tabs, sorting and joining lines, indent, restarting
#  language servers
# ════════════════════════════════════════════════════════════════════════════

from std/unicode import nil

proc requestQuit() =
  ## quits ned: at once when no tab has unsaved changes, or when files.hotExit has kept them for the next start;
  ## otherwise it asks to save all and quit, discard and quit, or cancel
  var names: seq[string]
  for b in bufs:
    if b.dirty: names.add b.name
  if names.len == 0:
    quitting = true
    return
  if hotExitOn() and hotExitSave():
    # (files.hotExit: nothing asked — the edits are kept and come back, unsaved, next time)
    quitting = true
    return
  askConfirm("Unsaved: " & names.join(", ") & " — (s)ave all & quit, (d)iscard & quit, (c)ancel",
    proc(c: char) =
      case c
      of 's', 'y':
        if saveAll(): quitting = true
      of 'd', 'n', 'q': quitting = true
      else: discard)

# shows or hides the left dock (the files)
proc toggleTree() = toggleDock(dsLeft)

proc togglePanel() =
  ## shows or hides the bottom panel; opened with nothing in it, it shows a line on how to run the file; hiding it
  ## returns the focus to the editor
  if panelOpen:
    panelOpen = false
    if focus == fPanel: focus = fEditor
  else:
    if panelLines.len == 0:
      panelTitle = "OUTPUT"
      panelKind = pkOutput
      panelLines = @[PanelLine(text: "No output yet — Alt+R runs the current file", sev: 3, line: -1)]
    panelOpen = true

proc newFile() =
  ## a new empty tab, which gets the focus
  bufs.add newBuffer()
  curBuf = bufs.high
  focus = fEditor
  closeComp()

proc switchTab(d: int) =
  ## goes `d` tabs on (negative: back), round to the other end, within the active pane's tabs when the editor is split;
  ## the editor gets the focus
  if bufs.len == 0: return
  if paneTabStep(d): return             # (panes: the active pane's own tabs)
  curBuf = (curBuf + d + bufs.len) mod bufs.len
  focus = fEditor
  closeComp()

proc runInTerminal(cmd, cwd: string, wait = true) =
  ## runs the command in the real terminal, the screen left to it: ned gives up raw mode and ignores Ctrl+C and Ctrl+\
  ## for itself, and the command runs with sh in `cwd` as a child process that has them. With `wait` it shows the exit
  ## code and waits for Enter. Then ned takes the terminal back (its process group, raw mode), and redraws
  # while the terminal is the program's, Ctrl+C and Ctrl+\ are for it, never for ned (also at "press Enter")
  signal(SIGINT, SIG_IGN)
  signal(SIGQUIT, SIG_IGN)
  leaveRaw()
  writeAll("\e[2J\e[H\e[?25h")
  if wait: echo "$ ", cmd, "\n"
  let run = if cmd.contains({';', '&', '|', '\n'}): cmd else: "exec " & cmd      # no shell left in between
  # (fork and exec rather than system(): the program gets Ctrl+C and Ctrl+\ back, ned keeps ignoring them)
  var code = 127
  when defined(windows):
    code = winRun(cmd, cwd)        # (the console is the program's while it runs; ned waits)
  else:
    let args = allocCStringArray(["/bin/sh", "-c", "cd " & quoteShell(cwd) & " && " & run])
    let pid = fork()
    if pid == 0:
      signal(SIGINT, SIG_DFL)
      signal(SIGQUIT, SIG_DFL)
      signal(SIGPIPE, SIG_DFL)
      discard execv("/bin/sh", args)
      exitnow(127)
    deallocCStringArray(args)
    if pid > 0:
      var st: cint
      while waitpid(pid, st, 0) < 0 and errno == EINTR: discard
      code = if WIFEXITED(st): int(WEXITSTATUS(st)) else: 128 + int(WTERMSIG(st))
  if wait:
    stdout.write "\n\e[2m[exit " & $code & "] press Enter to return to ned\e[0m"
    stdout.flushFile()
    try: discard stdin.readLine()
    except CatchableError: discard
  # the terminal back to ned's process group (a shell that took it may not have handed it back), then raw mode
  signal(SIGTTOU, SIG_IGN)
  discard tcsetpgrp(0, getpgrp())
  signal(SIGTTOU, SIG_DFL)
  enterRaw()
  signal(SIGINT, SIG_DFL)          # (SIGQUIT stays ignored: ned never wants Ctrl+\ to kill it)
  gridResize()
  needRender = true

proc transformSel(f: proc(s: string): string) =
  ## replaces the text of each selection — the word at the cursor where nothing is selected — with what `f` makes of it,
  ## in one undo step, and selects the new text
  let b = buf()
  if not b.canEdit(): return
  if b.cursors.len in 2 .. 4000:
    # (two cursors in one word, or overlapping selections: that text once — a second pass would change it again)
    var seen: seq[(Pos, Pos)]
    var keep: seq[Cursor]
    for cu in b.cursors:
      var (a, e) = cu.range
      if a == e: (a, e) = b.wordRangeAt(a)
      var dup = false
      for (x, y) in seen:
        if (a < y and x < e) or (a == x and e == y): dup = true
      if not dup:
        seen.add (a, e)
        keep.add cu
    if keep.len < b.cursors.len: b.cursors = keep
  b.beginEdit()
  for i in countdown(b.cursors.high, 0):
    var (a, e) = b.cursors[i].range
    if a == e: (a, e) = b.wordRangeAt(a)
    let t = b.getText(a, e)
    let r = f(t)
    if r != t:
      let p = b.replaceText(a, e, r)
      b.cursors[i] = Cursor(anchor: a, head: p, goalX: -1)
  b.endEdit()
  b.normalize()

proc sortLines(b: Buffer) =
  ## sorts each block of selected lines (of two or more lines), ignoring case, as one undo step
  if not b.canEdit(): return
  for (s, e) in b.lineBlocks():
    if e > s:
      var ls = b.lines[s .. e]
      ls.sort(proc(x, y: string): int = cmp(x.toLowerAscii, y.toLowerAscii))
      b.beginEdit()
      discard b.replaceText(Pos(line: s, col: 0), Pos(line: e, col: b.lines[e].len), ls.join("\n"))
      b.endEdit()
  b.normalize()

proc joinLines(b: Buffer) =
  ## joins each block of selected lines — or a line with the next one, where only a line is selected — into one line,
  ## with a single space between the parts and the indentation of the joined lines removed
  if not b.canEdit(): return
  b.beginEdit()
  for k in countdown(b.lineBlocks().high, 0):
    let (s, e0) = b.lineBlocks()[k]
    let e = if e0 == s: min(s + 1, b.lines.high) else: e0
    if e == s: continue
    var t = b.lines[s].strip(leading = false)
    for l in s + 1 .. e:
      let x = b.lines[l].strip
      if x.len > 0: t.add (if t.len > 0: " " else: "") & x
    discard b.replaceText(Pos(line: s, col: 0), Pos(line: e, col: b.lines[e].len), t)
  b.endEdit()
  b.normalize()

proc setIndent(b: Buffer, unit: string) =
  ## changes the buffer's indentation to `unit` (a tab or some spaces) and rewrites the indentation of every line to
  ## match, level by level, as one undo step; spaces left over that do not make a whole level stay
  let old = b.indent
  b.indent = unit
  if old == unit: return
  b.beginEdit()
  let ow = if old == "\t": b.tabOf else: old.len
  for l in 0 ..< b.lines.len:
    let s = b.lines[l]
    let ws = leadingWs(s)
    if ws.len == 0: continue
    let levels = visColOf(ws, ws.len) div max(1, ow)
    let rest = visColOf(ws, ws.len) mod max(1, ow)
    let nws = repeat(unit, levels) & spaces(rest)
    if nws != ws: discard b.replaceText(Pos(line: l, col: 0), Pos(line: l, col: ws.len), nws)
  b.endEdit()
  b.normalize()
  info("Indentation: " & (if unit == "\t": "tabs" else: $unit.len & " spaces"))

proc openSettings() =
  ## opens the settings file in a tab, making it first, with the commented default settings, when there is none
  let p = configFile()
  if not fileExists(p):
    try:
      createDir(parentDir(p))
      writeFile(p, defaultSettingsText())
    except CatchableError as e:
      error(e.msg)
      return
  discard openFile(p)

proc restartLsp() =
  ## restarts the language server of the current file's language: stops the running ones, forgets that it failed or died
  ## and its problems, and starts it again for the open files; it says when there is no server for the language
  let b = buf()
  for s in servers:
    if s.langId == b.lang.id and not s.dead:
      s.stopped = true
      s.dead = true
      killProc(s.pr)
  lspFailed.excl b.lang.id
  lspDeaths.del b.lang.id
  lspMoreFailed.clear()
  diagsLsp.del b.path
  for x in bufs:
    if x.lang.id == b.lang.id:
      x.lspOpen = false
      x.lspMore = false
  lspMoreSync(b, start = true)
  let s = lspFor(b)
  if s == nil: info("No language server found for " & b.lang.name &
                    (if b.lang.lsp.len > 0: " (install " & b.lang.lsp[0][0] & ")" else: ""))
  else: info("Starting " & s.name & "…")

proc restartLangServer(langId: string) =
  ## stop the server of one language (its whole process group) and start it again for the open files
  for s in servers:
    if s.langId == langId and not s.dead:
      discard s.lspRequest("shutdown", newJNull(), LspReq(kind: lrShutdown))
      s.lspNotify("exit", newJNull())
      s.stopped = true
      s.dead = true          # the main loop reaps it and kills the group
  lspFailed.excl langId
  lspDeaths.del langId
  lspMoreFailed.clear()
  if langId == "nim": nlsStatus = nil
  for b in bufs:
    if b.lang.id == langId:
      b.lspOpen = false
      b.lspMore = false
      diagsLsp.del b.path
  for b in bufs:
    if b.lang.id == langId and b.path.len > 0 and b.title.len == 0:
      lspAttach(b)                 # starts a new server (the old one is reaped by the main loop)
      break

proc nimRestartSuggest() =
  ## restarts nimsuggest: through nimlangserver (asking it to restart them all, or starting it again) when that is the
  ## engine, else ned's own nimsuggest is stopped and starts again with the next request
  if nimUsesLsp():
    for s in servers:
      if s.langId == "nim" and s.ready and not s.dead:
        discard s.lspRequest("extension/suggest", %*{"action": "restartAll", "projectFile": ""},
                             LspReq(kind: lrOther, extra: "suggest"))
        info("Restarting nimsuggest…")
        return
    restartLangServer("nim")
    for b in bufs:
      if b.lang.id == "nim": lspAttach(b)
    info("Starting nimlangserver…")
  else:
    nsShutdown()
    info("nimsuggest will restart on the next request")

proc nimUseAsMain() =
  ## makes the current Nim file the project's main module (nim.projectFile in the project settings) and restarts the Nim
  ## server for it
  let b = buf()
  if b.lang.mode != lmNim or b.path.len == 0:
    info("Open the Nim module that is your program's or library's entry point first")
    return
  let rel = relPath(b.path)
  setProjectSetting("nim.projectFile", %rel)
  if nimUsesLsp():
    restartLangServer("nim")
    toast("Main module: " & rel & " — nimlangserver restarts with one nimsuggest for it", 5)
  else:
    nsShutdown()
    info("Main module: " & rel)

proc nimServerStatus() =
  ## opens a Markdown page, Nim: language server status, on how Nim is served: for nimlangserver its main module,
  ## nimsuggest processes, errors and warnings; for ned's own engine the Nim in use, how many files are indexed and the
  ## memory they take, the search paths and the nimsuggest processes
  var o = "# Nim code intelligence\n\n"
  if nimUsesLsp():
    var srv: LspServer
    for s in servers:
      if s.langId == "nim" and not s.dead: srv = s
    o.add "- engine: nimlangserver" & (if srv == nil: " (not running — opens with the first Nim file)"
                                       elif not srv.ready: " (starting)" else: "") & "\n"
    if nlsRootMapped or (nlsProjects.len == 0 and nlsLoose.len == 0):
      o.add "- main module: " & (if nlsMain.len > 0: relPath(nlsMain) else: "—") &
            (if sStr("nim.projectFile").len > 0: "  (nim.projectFile)" else: "  (detected)") & "\n"
    else:
      o.add "- one nimsuggest per project in this folder:\n"
      for (d, m) in nlsProjects: o.add "  - " & d & "/ → " & m & "\n"
      if nlsLoose.len > 0: o.add "  - loose .nim files → " & nlsLoose & "\n"
    let pm = nimSection(){"projectMapping"}
    o.add "- projectMapping sent: " & (if pm != nil: $pm else: "none") & "\n"
    o.add "- maxNimsuggestProcesses: " & $sInt("nim.maxNimsuggestProcesses") & "\n"
    o.add "- nimsuggest: " & nimSection(){"nimsuggestPath"}.getStr("(not found on PATH)") &
          (if sStr("nim.nimsuggestPath").len > 0: "  (nim.nimsuggestPath)" else: "  (from PATH)") & "\n"
    if nlsStatus != nil:
      o.add "- server: " & nlsStatus{"lspPath"}.getStr & "  " & nlsStatus{"version"}.getStr & "\n\n"
      let inst = nlsStatus{"nimsuggestInstances"}
      o.add "## nimsuggest processes: " & $(if inst != nil: inst.len else: 0) & "\n\n"
      if inst != nil:
        for it in jitems(inst):
          o.add "### " & relPath(it{"projectFile"}.getStr) & "\n"
          o.add "- " & it{"path"}.getStr & "  " & it{"version"}.getStr.splitLines()[0] & "\n"
          var caps: seq[string]
          for c in jitems(it{"capabilities"}): caps.add c.getStr
          o.add "- capabilities: " & caps.join(", ") & "\n"
          var files: seq[string]
          for f in jitems(it{"openFiles"}): files.add relPath(pathFromUri(f.getStr))
          o.add "- open files: " & files.join(", ") & "\n"
          var unk: seq[string]
          for f in jitems(it{"unknownFiles"}): unk.add relPath(pathFromUri(f.getStr))
          if unk.len > 0: o.add "- outside the project's imports (still served): " & unk.join(", ") & "\n"
          o.add "\n"
      let errs = nlsStatus{"projectErrors"}
      if errs != nil and errs.len > 0:
        o.add "## errors\n\n"
        for e in jitems(errs): o.add "- " & relPath(e{"projectFile"}.getStr) & ": " & e{"errorMessage"}.getStr & "\n"
    else:
      o.add "\n(this nimlangserver does not report its nimsuggest processes)\n"
    if srv != nil:
      # a running server logs every request (DBG lines): show only what it complained about
      var bad: seq[string]
      for l in srv.errTail:
        if l.startsWith("WRN") or l.startsWith("ERR") or l.startsWith("FAT") or l.startsWith("Error") or
           l.toLowerAscii.contains("traceback"):
          bad.add l
      o.add "\n## nimlangserver warnings and errors\n\n"
      if bad.len == 0: o.add "none so far\n"
      else:
        o.add "```\n"
        for l in bad[max(0, bad.len - 25) .. ^1]: o.add l & "\n"
        o.add "```\n"
    else:
      let tail = lspLastLog.getOrDefault("nim")
      if tail.len > 0:
        o.add "\n## output of the nimlangserver that exited (last lines)\n\n```\n"
        for l in tail[max(0, tail.len - 30) .. ^1]: o.add l & "\n"
        o.add "```\n"
    if "nim" in lspFailed:
      o.add "\nnimlangserver kept exiting, so ned's built-in Nim engine is used now. Fix the cause shown above, " &
            "then palette › Restart language server.\n"
  elif cfgNimIde == "off":
    o.add "- engine: off (settings › nim.ide)\n"
  else:
    if "nim" in lspFailed and cfgNimIde == "nimlangserver":
      o.add "nimlangserver kept exiting, so ned's built-in Nim engine took over. Its last output:\n\n```\n"
      let tail = lspLastLog.getOrDefault("nim")
      for l in tail[max(0, tail.len - 15) .. ^1]: o.add l & "\n"
      o.add "```\n\nFix the cause, then palette › Restart language server.\n\n"
    o.add "- engine: ned's built-in Nim index — completion, hover, definition, signatures, outline, references and " &
          "rename without a compiler\n"
    o.add "- standard library: " & (if nxLibFound.len > 0: nxLibFound else: "not found (is nim installed?)") & "\n"
    if nimToolchainLine().len > 0:
      o.add "- the Nim in use: " & nimToolchainLine() & (if tcProblem.len > 0: " — ⚠ " & tcProblem else: "") & "\n"
    o.add "- files indexed: " & $nxFiles.len & " · their memory: " & $(nxFilesBytes div (1024 * 1024)) & " MB" &
          (if nxIndexBudget > 0: " of " & $(nxIndexBudget div (1024 * 1024)) & " MB (nim.indexMemory)" else: "") &
          (if nxDropped > 0: " · read again when needed: " & $nxDropped else: "") & "\n"
    o.add "- semantic colours: " & (if not cfgSemColors: "off (nim.semanticColors)"
                                   else: "the last update took " & formatFloat(semLastMs, ffDecimal, 1) & " ms") & "\n"
    o.add "- search paths: " & $nxSearchPaths.len & " · nimble packages: " & $nxPkgDirs.len & "\n"
    o.add "- project config read with `nim dump`: " & (if nxDumped.len == 0: "not yet" else: $nxDumped.len & " project(s)") & "\n"
    let deps = engineDepLines(rootDir)
    if deps.len > 0:
      o.add "\n## the package versions this project builds with\n\n"
      for d in deps: o.add "- " & d & "\n"
    var live = 0
    for s in nimSugs:
      if not s.dead: inc live
    o.add "\n## nimsuggest\n\n"
    if not haveExe("nimsuggest"): o.add "not installed — it comes with nim; the index works without it\n"
    elif not cfgNimSuggest: o.add "off (settings › nim.nimsuggest)\n"
    else:
      o.add "used for: types the index cannot infer (completion after `.`), errors while typing, inlay hints" &
            (if nsProtoVer >= 4: "" elif nsProtoVer > 0: " (needs protocol 4: Nim 2.2+)" else: "") & ", macro expansion\n"
      o.add "protocol: " & (if nsProtoVer < 0: "not started yet" else: $nsProtoVer) & " · memory limit: " &
            (if cfgNsMaxMB > 0: $cfgNsMaxMB & " MB" else: "none") & "\n\n"
      o.add "processes: " & $live & "\n"
      for s in nimSugs:
        if not s.dead: o.add "- " & relPath(s.project) & "\n"
    o.add "\nErrors on save come from `nim check`.\n"
  o.add "\nOne nimsuggest per project: a package's files are checked with its main module, loose scripts share " &
        "one.\nChange the main module with \"Nim: use current file as main module\" or the nim.projectFile setting.\n"
  discard openScratch("Nim: language server status", o, langByName("Markdown"))
