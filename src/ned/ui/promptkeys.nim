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

proc submitPrompt() =
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
      try:
        createDir(parentDir(dest))
        if dirExists(treeTarget): moveDir(treeTarget, dest) else: moveFile(treeTarget, dest)
        remoteFileOp("mv", treeTarget, dest)
        for b in bufs:
          if b.path == treeTarget: b.path = dest
          elif b.path.startsWith(treeTarget & "/"): b.path = dest & b.path[treeTarget.len .. ^1]
        refreshTree()
        info("Renamed to " & relPath(dest))
        if treeTarget.endsWith(".nim") and fileExists(dest): fixImportsAfterMove(treeTarget, dest)
      except CatchableError as e: error(e.msg)
  of pLspRename:
    let b = buf()
    let s = lspReady(b)
    if s != nil and t.len > 0:
      discard s.lspRequest("textDocument/rename", %*{"textDocument": b.docId,
        "position": s.lspPos(b, b.primary.head), "newName": t},
        LspReq(kind: lrRename, bufId: b.id, extra: b.wordAt(b.primary.head), extra2: t))
    elif t.len > 0 and nimEngineOn(b):
      let old = b.wordAt(b.primary.head)
      let nn = t.strip
      if nn.len == 0 or not (nn[0] in {'a'..'z', 'A'..'Z', '_'} or nn[0] >= '\x80') or not nn.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}):
        warn("'" & nn & "' is not a Nim identifier")
      elif nn in NxKeywords: warn("'" & nn & "' is a Nim keyword")
      else:
        var hits: seq[(string, int, int)]
        var decl = ""
        var known = false
        var madeBy = ""
        try:
          let f = nxFileFor(b)
          if f != nil:
            let (a0, _) = b.wordRangeAt(b.primary.head)
            let (rs, _, _) = nxTargets(f, b.lines, a0.line, a0.col)
            for r in rs:
              if r.sym.made: madeBy = r.file.path & ":" & $(r.sym.line + 1)
        except Exception as e: internalError("Nim index", e)
        if madeBy.len == 0:
          try: known = engineReferences(b, b.primary.head, hits, decl)
          except Exception as e: internalError("Nim index", e)
        if madeBy.len > 0:
          warn("'" & old & "' is declared by a template call (" & relPath(madeBy) & ") — rename it there, not here")
        elif known and nxRefsCut:
          warn("'" & old & "' is used too often in this project to find every use in time (10 s) — not renamed")
        elif known:
          if decl.len > 0 and not decl.startsWith(rootDir & "/") and bufIndexByPath(decl) < 0:
            warn("'" & old & "' is declared in " & decl & " — outside this project, so it is not renamed")
          elif hits.len == 0: info("Nothing to rename")
          else: previewRenameHits(hits, old, nn)
        elif nsUsable(b):
          let (a, _) = b.wordRangeAt(b.primary.head)
          discard nsRequest(b, nsRename, a, old & "\t" & nn)
        else: info("ned cannot tell what '" & old & "' refers to here")
    elif t.len > 0 and nsUsable(b):
      let (a, _) = b.wordRangeAt(b.primary.head)
      discard nsRequest(b, nsRename, a, b.wordAt(b.primary.head) & "\t" & t)
  of pNewProject:
    if t.strip.len > 0: createNimProject(t.strip)
  of pAtlasUse:
    if t.strip.len > 0: runCommand("atlas use " & quoteShell(t.strip), rootDir)
  of pAtlasSearch:
    if t.strip.len > 0: runCommand("atlas search " & t.strip, rootDir)
  of pGitCommit:
    if t.strip.len > 0:
      let m = t.strip
      proc commitNow() =
        if gitStaged() == 0:
          askConfirm("Nothing is staged — commit all changed files? (new files are left out) (y/n)", proc(c: char) =
            if c in {'y', 'Y'}: gitRun(@["commit", "-a", "-m", m], "Committed"))
        else: gitRun(@["commit", "-m", m], "Committed")
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
