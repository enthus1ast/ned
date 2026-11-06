# what the prompts do when answered, and their keys: the commands that start from a prompt or a folder (editing a
# theme's colours, opening a folder, moving a file) and the Enter and key handling for every kind of prompt
proc cmdEditThemeColours() =
  ## the current theme as a file of its own to change: ~/.config/ned/themes/<name>-mine.json
  var j = themeJson(theme)
  var name = theme.name
  if not name.endsWith("-mine"): name.add "-mine"
  j["name"] = %name
  try:
    let existing = themesDir() / (themeSlug(name) & ".json")
    let f = if fileExists(existing): existing else: saveThemeFile(j)   # never overwrite your earlier changes
    reloadThemes()
    applyTheme(name)
    setSetting("theme", %name)
    discard openFile(f)
    info("Your copy of the theme — change any colour and save (Ctrl+S) to see it")
  except CatchableError as e:
    error("Cannot write the theme file: " & e.msg)


proc cmdOpenFolder() =
  ## start beside the current project (where the others usually are), else in the current folder
  let start = if projectMarks(rootDir).len > 0 and parentDir(rootDir).len > 0: parentDir(rootDir) else: rootDir
  browseFolder(start)

proc movePath(src, dest: string, what = "Moved to ") =
  ## a file or folder moved (renamed): its open buffers follow it, a Nim module's importers are fixed
  if src == dest: return
  try:
    createDir(parentDir(dest))
    if dirExists(src): moveDir(src, dest) else: moveFile(src, dest)
    remoteFileOp("mv", src, dest)
    for b in bufs:
      if b.path == src: b.path = dest
      elif b.path.startsWith(src & "/"): b.path = dest & b.path[src.len .. ^1]
    refreshTree()
    info(what & relPath(dest))
    if src.endsWith(".nim") and fileExists(dest): fixImportsAfterMove(src, dest)
  except CatchableError as e: error(e.msg)

proc submitPrompt() =
  ## Enter in a prompt: remembers the text in the prompt's history and does what that kind of prompt is for — find,
  ## replace (asks for the new text, then goes through the matches), go to line, save as, run a command, project search,
  ## new file or folder, rename, language-server rename, new project, Atlas and nimble commands, git commit, plugin
  ## prompts, Vim commands and searches, open folder, AI edit, a setting, breakpoint conditions, user commands and
  ## debugger watches; most close the prompt first
  let kind = promptKind
  let t = promptText
  addHist(kind, t)
  case kind
  of pFind:
    findQuery = t
    findStep(true)
    return
  of pReplaceFind:
    if t.len == 0: return
    replaceQuery = t
    findQuery = t
    let b = buf()
    var initial = ""
    let h = promptHist.getOrDefault(pReplaceWith)
    if h.len > 0: initial = h[^1]
    if findOrigin.len > 0:
      b.cursors = findOrigin
      b.normalize()
    openPrompt(pReplaceWith, "Replace \"" & t & "\" with", initial)
    findOrigin = @[]
    return
  of pReplaceWith:
    closePrompt()
    replaceWith = t
    replaceCount = 0
    replaceActive = true
    if not replaceNext(buf().primary.range[0]):
      info("No matches for \"" & replaceQuery & "\"")
    return
  of pGoto: gotoLineText(t)
  of pSaveAs:
    if t.strip.len > 0:
      let p = expandTilde(t.strip)
      discard buf().saveBuffer(if p.isAbsolute: p else: rootDir / p)
      refreshTree()
  of pRunCmd:
    if t.strip.len > 0:
      let b = buf()
      runCommand(expandCmd(t, b), (if b.path.len > 0: parentDir(b.path) else: rootDir))
  of pSearch: projectSearch(t)
  of pNewFile:
    if t.strip.len > 0:
      let p = expandTilde(t.strip)
      let full = if p.isAbsolute: p else: rootDir / p
      try:
        createDir(parentDir(full))
        if not fileExists(full):
          writeFile(full, "")
          fileWritten(full)
        refreshTree()
        discard openFile(full)
        revealInTree(full)
      except CatchableError as e: error(e.msg)
  of pNewFolder:
    if t.strip.len > 0:
      let p = expandTilde(t.strip)
      let full = if p.isAbsolute: p else: rootDir / p
      try:
        createDir(full)
        remoteFileOp("mkdir", full)
        refreshTree()
      except CatchableError as e: error(e.msg)
  of pRenamePath:
    if t.strip.len > 0 and treeTarget.len > 0:
      let p = expandTilde(t.strip)
      let dest = if p.isAbsolute: p else: rootDir / p
      movePath(treeTarget, dest, "Renamed to ")
  of pLspRename:
    let b = buf()
    let s = lspReady(b)
    if s != nil and t.len > 0:
      discard s.lspRequest("textDocument/rename", %*{"textDocument": b.docId,
        "position": s.lspPos(b, b.primary.head), "newName": t},
        LspReq(kind: lrRename, bufId: b.id, extra: b.wordAt(b.primary.head), extra2: t))
    elif t.len > 0 and cEngineOn(b):
      discard cEngRename(b, b.primary.head, t)
    elif t.len > 0 and webJsAt(b, b.primary.head):
      discard webRename(b, b.primary.head, t)
    elif t.len > 0 and nimEngineOn(b):
      let old = b.wordAt(b.primary.head)
      let nn = t.strip
      let (hits, why, sev) = engineRename(b, b.primary.head, nn)
      if sev == -1 and nsUsable(b):
        let (a, _) = b.wordRangeAt(b.primary.head)
        discard nsRequest(b, nsRename, a, old & "\t" & nn)
      elif why.len > 0:
        if sev == 2: warn(why) else: info(why)
      else: previewRenameHits(hits, old, nn)
    elif t.len > 0 and nsUsable(b):
      let (a, _) = b.wordRangeAt(b.primary.head)
      discard nsRequest(b, nsRename, a, b.wordAt(b.primary.head) & "\t" & t)
  of pNewProject:
    if t.strip.len > 0: discard createNimProject(t.strip)
  of pAtlasUse:
    if t.strip.len > 0: runCommand("atlas use " & quoteShell(t.strip), rootDir)
  of pAtlasSearch:
    if t.strip.len > 0: runCommand("atlas search " & t.strip, rootDir)
  of pGitCommit:
    if t.strip.len > 0:
      let m = t.strip
      proc commitNow() =
        ## makes the commit with the typed message after the pre-commit checks: when nothing is staged asks first
        ## whether to commit all changed files (new files left out)
        # (git.checksBeforeCommit as for the message box: formatted, the tests passing — or why not, and the choice)
        if gitStaged() == 0:
          askConfirm("Nothing is staged — commit all changed files? (new files are left out) (y/n)", proc(c: char) =
            if c in {'y', 'Y'}:
              precommitChecks(gitHome(), true, proc() = gitRun(@["commit", "-a", "-m", m], "Committed")))
        else: precommitChecks(gitHome(), false, proc() = gitRun(@["commit", "-m", m], "Committed"))
      closePrompt()
      let home = gitHome()
      if home.len > 0 and (remotes.len == 0 or remoteOf(home) < 0) and gitIdentityMissing(home):
        gitAskIdentity(home, commitNow)        # (git has to know who you are first: asked once)
      else: commitNow()
      return
  of pGitInput, pPathInput:
    closePrompt()
    let cb = gitPromptCb
    gitPromptCb = nil
    if cb != nil and t.strip.len > 0: cb(t.strip)
    return
  of pNimbleTask:
    if t.strip.len > 0: runCommand("nimble " & t.strip, (if nimble.dir.len > 0: nimble.dir else: rootDir))
  of pPluginAsk:
    closePrompt()
    plugAskDone(t)
    return
  of pPluginNew:
    closePrompt()
    if t.strip.len > 0: plugNew(t)
    return
  of pPluginInstall:
    closePrompt()
    if t.strip.len > 0: plugInstall(t)
    return
  of pVimCmd:
    closePrompt()
    vimEx(t)
    return
  of pVimSearch:
    closePrompt()
    if t.len > 0:
      findQuery = t
      findWord = false
      findStep(not vimSearchBack)
    return
  of pOpenFolder:
    let d = absolutePath(expandTilde(t.strip)).normalizedPath
    if dirExists(d):
      closePrompt()
      openFolder(d)
      return
    error("No such folder: " & t)
  of pAiEdit:
    closePrompt()
    aiInlineEdit(t)
    return
  of pSetting:
    closePrompt()
    submitSetting(t)
    return
  of pNimbleAdd:
    closePrompt()
    nimbleAddDep(t)
    return
  of pBpCond:
    closePrompt()
    setBpCond(t)
    return
  of pUserCmdName:
    closePrompt()
    if t.strip.len > 0:
      userCmdEditing = t.strip
      openPrompt(pUserCmdRun, "Shell command for “" & userCmdEditing & "” ($file $dir $line $word $selection …)", "")
    return
  of pPipeCmd:
    closePrompt()
    pipeThroughCommand(t)
    return
  of pUserCmdRun:
    closePrompt()
    if t.strip.len > 0 and userCmdEditing.len > 0:
      let isNew = not userCmdExists(userCmdEditing)
      setUserCmdField(userCmdEditing, "run", t.strip)
      if isNew: userCmdOutputMenu(userCmdEditing)
      else: info("“" & userCmdEditing & "” now runs: " & t.strip)
    return
  of pBpLog:
    closePrompt()
    setBpLog(t)
    return
  of pDbgWp:
    closePrompt()
    if t.strip.len > 0: dbgAddWatchpoint(t.strip)
    return
  of pDbgWatch:
    closePrompt()
    if t.strip.len > 0 and t.strip notin dbgWatches:
      dbgWatches.add t.strip
      if dbgOn: dbgSend("-stack-list-variables --simple-values")     # evaluated now (with the locals' C names)
      dbgPanel()
      setPanel(pkDebug)
    return
  of pNimbleSearch:
    closePrompt()
    if t.strip.len > 0: runNimble("search " & quoteShell(t.strip))
    return
  of pNone: discard
  closePrompt()

proc promptKey(k: Key) =
  ## the keys of the open prompt: Esc closes, Enter answers (Shift+Enter steps back in a find), Up and Down walk the
  ## prompt's history (or step through matches in a find), Tab completes paths (and vim's : line), F3 and Ctrl+F step through matches,
  ## Alt+C, W and R toggle case, whole word and regex in find prompts, Ctrl+R turns find into replace; other keys edit
  ## the text, and a find prompt updates its matches as you type
  let kind = promptKind
  let isFind = kind in {pFind, pReplaceFind, pVimSearch}
  case k.kind
  of kEsc:
    closePrompt()
    return
  of kEnter:
    if isFind and mShift in k.mods: findStep(false)
    else: submitPrompt()
    return
  of kUp, kDown:
    if kind == pFind:
      findStep(k.kind == kDown)
      return
    let h = promptHist.getOrDefault(kind)
    if h.len == 0: return
    if promptHistIdx < 0: promptHistIdx = h.len
    promptHistIdx = clamp(promptHistIdx + (if k.kind == kUp: -1 else: 1), 0, h.len)
    promptText = if promptHistIdx < h.len: h[promptHistIdx] else: ""
    promptCur = promptText.len
  of kTab:
    if kind in {pSaveAs, pNewFile, pNewFolder, pRenamePath, pOpenFolder, pPathInput}:
      promptText = completePath(promptText)
      promptCur = promptText.len
    elif kind == pVimCmd:                       # (vim's : line: commands, settings, themes, files, tabs)
      promptText = vimExComplete(promptText)
      promptCur = promptText.len
    return
  of kFn:
    if k.fn == 3 and isFind: findStep(mShift notin k.mods)
    return
  of kChar:
    if mAlt in k.mods and isFind:
      if k.ch == ord('c'): findCase = not findCase
      elif k.ch == ord('w'): findWord = not findWord
      elif k.ch == ord('r') or k.ch == ord('x'): findRegex = not findRegex
      findIncremental()
      return
    if mCtrl in k.mods and isFind and k.ch == ord('f'):
      findStep(true)
      return
    if mCtrl in k.mods and kind == pFind and k.ch == ord('r'):
      let t = promptText
      openPrompt(pReplaceFind, "Replace", t)
      return
    if not editLine(promptText, promptCur, k): return
  else:
    if not editLine(promptText, promptCur, k): return
  if isFind: findIncremental()
