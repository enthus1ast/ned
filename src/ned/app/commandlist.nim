proc initCommands() =
  template add(n, k: string, body: untyped) =
    commands.add Command(name: n, keys: k, action: proc() = body)
  initCommandsV4()
  refreshUserCommands()
  loadMacros()
  add("Open file…", "Ctrl+P", cmdFindFile())
  add("Save", "Ctrl+S", (discard buf().saveBuffer()))
  add("Save as…", "", openPrompt(pSaveAs, "Save as", (if buf().path.len > 0: relPath(buf().path) else: "")))
  add("Save all", "", (discard saveAll()))
  add("New file", "Ctrl+N", newFile())
  add("Close tab", "Ctrl+W", closeBuffer(curBuf))
  add("Close other tabs", "", (block:
    for i in countdown(bufs.high, 0):
      if i != curBuf and not bufs[i].dirty: closeBufferAt(i)))
  add("Switch buffer…", "", cmdBuffers())
  add("Reload from disk", "", buf().reloadBuffer())
  add("Quit", "Ctrl+Q", requestQuit())
  add("Undo", "Ctrl+Z", (if buf().hex != nil: buf().hexUndo() else: buf().undo()))
  add("Redo", "Ctrl+Y", (if buf().hex != nil: buf().hexUndo(redo = true) else: buf().redo()))
  add("Undo history…", "Alt+Shift+U", cmdUndoHistory())
  add("Find", "Ctrl+F", openPrompt(pFind, "Find", findQuery))
  add("Replace", "Ctrl+R", openPrompt(pReplaceFind, "Replace", findQuery))
  add("Find next", "F3", findStep(true))
  add("Find previous", "Shift+F3", findStep(false))
  add("Search in project…", "Alt+S", openPrompt(pSearch, "Search project", buf().wordAt(buf().primary.head)))
  add("Go to line…", "Ctrl+G", openPrompt(pGoto, "Go to line[:col]"))
  add("Go to symbol…", "Ctrl+T", cmdSymbols())
  add("Go to definition", "Alt+. / F12", cmdDefinition())
  add("C: switch between header and source", "", cmdSwitchHeaderSource())
  add("Open the link at the cursor", "", cmdOpenLink())
  add("Jump back", "Alt+,", jumpBack())
  add("Go forward", "Alt+Shift+, (Alt+<)", jumpForward())
  add("Reopen closed tab", "Alt+Shift+T", reopenClosedTab())
  add("Show hover info", "Alt+H", cmdHover())
  add("Rename symbol", "F2", cmdRename())
  add("Format document", "Alt+F", buf().formatBuffer())
  add("Format selection (Nim built in, or the language server)", "Alt+F with lines selected", buf().formatSelection())
  add("Format: the code in this string", "JSON, CSS, C in an emit …", cmdFormatEmbedded())
  add("Format: preview the change", "side by side, then apply it or not", cmdFormatPreview())
  add("Format: only the lines I changed", "since git last saw the file", (block:
    let b = buf()
    if b.canEdit():
      let saved = cfgFormatScope
      cfgFormatScope = "changed"
      let before = b.lines
      formatOnSave(b)
      cfgFormatScope = saved
      info(if b.lines == before: "Nothing to format where you changed lines" else: "Formatted the lines you changed")))
  add("Format: every file in the project…", "", cmdFormatAll())
  add("Format: review the project's changes", "", fmtAllReview())
  add("Next problem", "Alt+N / F8", gotoDiag(1))
  add("Previous problem", "Alt+P", gotoDiag(-1))
  add("Show problems", "", showProblems())
  add("Problems: all of them with their code (multibuffer)", "", cmdProblemsMultibuffer())
  add("HTML: expand Emmet abbreviation", "Tab", (block:
    if not buf().tryEmmet(): info("No Emmet abbreviation before the cursor (ul>li*3, div.box>p{text}, !)")))
  add("Run current file", "Alt+R / F5", runCurrent())
  add("Notebook: run the cell", "Ctrl+Enter — a .nim or .py file's # %% cell; its output under it", cmdNbRunCell(false))
  add("Notebook: run the cell and go to the next", "Shift+Enter once the notebook runs", cmdNbRunCell(true))
  add("Notebook: run all the cells", "", cmdNbRunAll())
  add("Notebook: run the cells above and this one", "", cmdNbRunAbove())
  add("Notebook: clear the outputs", "", cmdNbClear())
  add("Notebook: restart the session", "its variables forgotten", cmdNbRestart())
  add("Notebook: the cell's whole output", "in a tab", cmdNbWholeOutput())
  add("Nim: write tests for this proc (from running it)", "sample arguments, its results as std/unittest checks " &
      "in tests/t<module>.nim, then run with coverage", cmdWriteProcTests())
  add("Picture: show the picture / its bytes", "a .png, .jpg, .gif, .bmp or .webp file (Tab in its view)",
      cmdPictureToggle())
  add("Run with memory checks", "Nim, C, C++: overflows, uses after free, leaks, undefined behaviour — in Problems",
      cmdMemoryChecks())
  add("Build current file", "Alt+B", runCurrent(true))
  add("Run command…", "", openPrompt(pRunCmd, "Run command", lastRunCmd))
  add("Run in terminal (interactive)", "", (block:
    let b = buf()
    if b.path.len > 0 and b.lang.run.len > 0:
      discard saveAll()
      runInTerm("cd " & quoteShell(parentDir(b.path)) & " && " & expandCmd(cfgUserRun.getOrDefault(b.lang.id, b.lang.run), b))
    else: info("Nothing to run")))
  add("Stop running process", "", stopRun())
  add("Toggle output panel", "Alt+O", togglePanel())
  add("Open shell", "", toggleTerminal())
  add("Open shell full screen (leave ned temporarily)", "", runInTerminal(getEnv("SHELL", "sh"), rootDir, false))
  add("Toggle file tree", "", toggleTree())
  add("Nim: exports nothing uses…", "", cmdUnusedExports())
  add("Nim: change signature…", "", cmdChangeSignature())
  add("Nim: inline this proc", "", cmdInlineProc())
  add("Nim: move to another module…", "", cmdMoveToModule())
  add("Nim: toggle reference counts", "", toggleSetting("nim.referenceCounts", "Reference counts"))
  add("Macro: start or stop recording", "Alt+Shift+R", macroToggle())
  add("Macro: play the last one", "Alt+Shift+M", macroPlay(macroLast))
  add("Macro: play the last one N times…", "", askText("How many times? (it stops early once it changes nothing)", "10",
    proc(t: string) =
      let c = (try: parseInt(t.strip) except ValueError: 0)
      if c > 0: macroPlay(macroLast, c)))
  add("Macro: play on each selected line", "", macroPlayEachLine())
  add("Macro: play to the end of the file", "", macroPlayToEnd())
  add("Macro: save the last one…", "", macroSaveLast())
  add("Macro: saved macros…", "", macroManage())
  add("Reveal file in tree", "", (block:
    if sideView != svFiles: showSide(svFiles)       # the Files view, also when another view had the dock
    treeOpen = true
    focus = fTree
    revealInTree(buf().path)))
  add("Refresh file tree", "", refreshTree())
  add("New folder…", "", openPrompt(pNewFolder, "New folder", ""))
  add("New file at path…", "", openPrompt(pNewFile, "New file", ""))
  add("Toggle comment", "Ctrl+/", buf().toggleComment())
  add("Duplicate line/selection", "Alt+D", buf().duplicate())
  add("Delete line", "Ctrl+K", buf().deleteLines())
  add("Move line up", "Alt+↑", buf().moveLines(-1))
  add("Move line down", "Alt+↓", buf().moveLines(1))
  add("Indent lines", "Tab with lines selected", buf().indentLines(1))
  add("Unindent lines (outdent, dedent)", "Shift+Tab", buf().indentLines(-1))
  add("Select all", "Ctrl+A", (block:
    let b = buf()
    b.setSingle(Pos(line: b.lines.high, col: b.lines[^1].len), Pos())))
  add("Select line", "Ctrl+L", buf().selectLine())
  add("Select next occurrence", "Ctrl+D", buf().selectNextOccurrence())
  add("Select all occurrences", "Alt+A", buf().selectAllOccurrences())
  add("Add cursor below", "Alt+J", buf().addCursorVert(1))
  add("Jump to a word on screen (labels)", "Alt+Shift+J", cmdJumpLabels())
  add("Add cursor above", "Alt+K", buf().addCursorVert(-1))
  add("Go to matching bracket", "Ctrl+]", (block:
    let b = buf()
    let (ok, a, e) = b.matchBracket(b.primary.head)
    if ok: b.setSingle(if b.primary.head == a or b.primary.head.col == a.col + 1: e else: a)))
  add("Trigger completion", "Ctrl+Space", startCompletion(true))
  add("Sort lines", "", buf().sortLines())
  add("Join lines", "", buf().joinLines())
  add("Upper case", "", transformSel(proc(s: string): string = unicode.toUpper(s)))
  add("Lower case", "", transformSel(proc(s: string): string = unicode.toLower(s)))
  add("Trim trailing whitespace", "", buf().trimTrailing())
  add("File: EditorConfig for this file", "", (block:
    let b = buf()
    if b.ecInfo.len == 0:
      info(if not cfgEditorConfig: "EditorConfig is off (settings › editor.editorConfig)"
           elif b.path.len == 0: "Save the file first" else: "No .editorconfig applies to " & b.name)
    else:
      var body = ""
      var files: seq[string]
      for (k, v, f) in b.ecInfo:
        body.add alignLeft(k, 26) & " " & v & "\n"
        if tildePath(f) notin files: files.add tildePath(f)
      body.add "\nfrom " & files.join(", ") & "\n\nIndentation now: " &
               (if b.indent == "\t": "tabs, " & $b.tabOf & " wide" else: $b.indent.len & " spaces")
      let first = b.ecInfo[^1][2]
      openDialog("EditorConfig — " & b.name, body, @[("Open .editorconfig", 'o'), ("OK", 'y')], proc(c: char) =
        if c == 'o': discard openFile(first))))
  add("Copy file path", "", (block:
    clipSet(buf().path)
    clipParts = @[buf().path]
    clipLineMode = false
    info("Copied " & buf().path)))
  add("Toggle soft wrap", "Alt+W", (block:
    if sBool("editor.softWrap") and buf().largeOn:
      info("No soft wrap in this file: large-file mode (" & buf().largeWhy & ") — palette › Large file mode turns it off")
    else: toggleSetting("editor.softWrap", "Soft wrap")))
  add("Large file mode: on/off for this file", "", (block:
    let b = buf()
    if b.largeOn:
      b.largeOff = true
      info("Large-file mode off for " & b.name & " — soft wrap and language features are back")
    else:
      if not b.large:
        b.large = true
        b.largeWhy = "turned on by hand"
      b.largeOff = false
      info("Large-file mode on for " & b.name & ": no soft wrap, language server, minimap or word highlight")
    cfgWrap = wrapFor(b)))
  add("Cycle line numbers", "Alt+L", (block:
    let nx = ["off", "absolute", "relative"][(cfgLineNums + 1) mod 3]
    setSetting("editor.lineNumbers", %nx)
    info("Line numbers: " & nx)))
  add("Toggle whitespace", "", toggleSetting("editor.showWhitespace", "Whitespace"))
  add("Toggle indent guides", "", toggleSetting("editor.indentGuides", "Indent guides"))
  add("View: ligatures (off › font › symbols)", "", (block:
    # editor.fontLigatures, the next one: a ligature font's · ned's own symbols · off
    let nx = case cfgLigatures
             of "off": "font"
             of "font": "symbols"
             else: "off"
    setSetting("editor.fontLigatures", %nx)
    info("Ligatures: " & (case nx
      of "font": "font — each operator kept whole for a terminal with a ligature font"
      of "symbols": "symbols — drawn by ned (─→ ═⇒ ≠ ≤ ≥), the cursor's line as written"
      else: "off"))))
  add("View: toggle rulers", "", toggleRulers())
  add("View: set ruler columns…", "", askText("Ruler columns (e.g. 80 or 80, 120, or lineLength: where the " &
      "formatter wraps — empty: none)", (block:
        var cur: seq[string]
        for c in cfgRulers: cur.add $c
        if cfgRulerAtLength: cur.add "lineLength"
        if cur.len > 0: cur.join(", ") else: "lineLength"), proc(t: string) =
    var cols = newJArray()
    for p in t.split({',', ' ', ';'}):
      if p.strip.len > 0:
        if p.strip.toLowerAscii in ["linelength", "format", "formatter"]:
          cols.add %"lineLength"
          continue
        try:
          let c = parseInt(p.strip)
          if c in 1 .. 2000: cols.add %c
        except ValueError: discard
    rulersHidden = false
    setSetting("editor.rulers", cols)
    info(if cols.len == 0: "No rulers" else: "Rulers at column " & t.strip)))
  add("Toggle mouse", "Alt+U", (block:
    toggleSetting("ui.mouse", "Mouse")
    if not cfgMouse: info("Mouse off — Termux text selection works now")))
  add("Toggle auto-completion", "", toggleSetting("editor.autoComplete", "Auto-completion"))
  add("Select theme…", "Alt+T", cmdThemes())
  add("Set language mode…", "", cmdLanguages())
  add("Indent with 2 spaces", "", buf().setIndent("  "))
  add("Indent with 4 spaces", "", buf().setIndent("    "))
  add("Indent with tabs", "", buf().setIndent("\t"))
  add("Toggle line endings (LF/CRLF)", "", (block:
    let b = buf()
    b.crlf = not b.crlf
    inc undoSeq
    b.savedSeq = -undoSeq
    info("Line endings: " & (if b.crlf: "CRLF" else: "LF"))))
  add("Open settings file", "", openSettings())
  add("Settings", "", openSettingsUi())
  add("Settings: quick list (type a name, Enter changes it)…", "", openSettingsList())
  add("Settings: show all defaults", "", (discard openScratch("default settings.json", defaultSettingsText(), langByName("JSON"))))
  add("Settings: reset to defaults", "", resetSettings())
  add("Reset everything: remove all settings and state…", "", cmdResetEverything())
  add("Restart language server", "", restartLsp())
  add("Key bindings", "F1", (block:
    helpOpen = true
    helpScroll = 0))
  # ── Nim ───────────────────────────────────────────────────────────────
  add("Nim: expand macro/template at cursor", "Alt+M", cmdExpandMacro())
  add("Nim: expand macro one level", "", cmdExpandMacro("1"))
  add("Nim: ARC/ORC view of current proc (expandArc)", "", cmdExpandArc())
  add("Nim: show where ARC/ORC copies (⧉copy)", "", (block:
    if not cfgShowCopies:
      cfgShowCopies = true
      setSetting("nim.showCopies", %true)
    let b = buf()
    if b.lang.mode != lmNim or b.path.len == 0: info("Copies are shown for a saved Nim file")
    elif not codeTrusted(parentDir(b.path)): askTrust(parentDir(b.path))
    else:
      copyMs.del b.path
      info("Asking the compiler where ARC/ORC copies…")
      copiesCheck(b)))
  add("Nim: hide ARC/ORC copies", "", (block:
    cfgShowCopies = false
    setSetting("nim.showCopies", %false)
    copyMarks.clear()
    needRender = true))
  add("Nim: show generated C", "", cmdShowC())
  add("Nim: go to the C declaration (importc)", "", (block:
    let b = buf()
    discard cGotoFromDecl(b, b.primary.head, anyUse = true)))
  add("Nim: wrap a C header…", "its functions, structs, enums and constants as Nim — by ned's own C engine",
      cmdWrapHeader())
  add("Nim: wrap a C header with c2nim…", "", cmdWrapHeader(c2nim = true))
  add("Nim: write compile_commands.json for clangd", "", cmdCompileCommands())
  add("Nim: check the importc wrappers against their headers", "", (block:
    let b = buf()
    if b.lang.mode != lmNim:
      info("Open a Nim file")
    else:
      let was = cfgCheckWrappers
      cfgCheckWrappers = true
      ffiCheck(b)
      cfgCheckWrappers = was
      let n = diagsFfi.getOrDefault(b.path).len
      info(if n == 0: "The importc wrappers here fit their C headers (those ned could find)"
           else: $n & " wrapper problem" & (if n == 1: "" else: "s") & " — see Problems")))
  add("Nim: check project", "", (block:
    let b = buf()
    if b.lang.mode == lmNim and b.path.len > 0:
      runCommand("nim check --hints:off " & quoteShell(nimProjectFile(b)), parentDir(b.path))))
  add("Nim: new project…", "", cmdNewNimProject())
  add("Nim: build mode debug", "", setNimMode("debug"))
  add("Nim: build mode release", "", setNimMode("release"))
  add("Nim: build mode danger", "", setNimMode("danger"))
  add("Nim: backend C", "", setNimTarget("c"))
  add("Nim: backend C++", "", setNimTarget("cpp"))
  add("Nim: backend JavaScript", "", setNimTarget("js"))
  add("Nim: backend Objective-C", "", setNimTarget("objc"))
  add("Nim: compile with nim", "", setNimCompiler("nim"))
  add("Nim: compile with nimony", "", setNimCompiler("nimony"))
  add("Nim: restart nimsuggest", "", nimRestartSuggest())
  add("Nim: language server status", "", nimServerStatus())
  add("Nim: use ned's built-in engine", "", setSetting("nim.ide", %"builtin"))
  add("Nim: use nimlangserver", "", setSetting("nim.ide", %"nimlangserver"))
  add("Nim: choose the Nim for this project…", "for every tool: nim, nimble, nimsuggest, the terminal", cmdChooseProjectNim())
  add("Nim: add a CI workflow (GitHub Actions)…", "build and test; ned's lint and format check", cmdAddCiWorkflow())
  add("Nim: lint the project (the engine's checks)", "ned --lint over every file", cmdLintProject())
  add("Nim: lint rules for this project (.ned/lint.json)", "turn a check off, change its severity, leave files out",
      cmdLintRules())
  add("Nim: format with ned's built-in formatter (nph style)", "", setSetting("nim.formatter", %"builtin"))
  add("Nim: format with nph", "", setSetting("nim.formatter", %"nph"))
  add("Nim: format with nimpretty", "", setSetting("nim.formatter", %"nimpretty"))
  add("Nim: use current file as main module", "", nimUseAsMain())
  add("Nim: extract selection into a proc", "", cmdExtractProc())
  add("Refactor: extract into a variable", "", extractVariable())
  add("Nim: inline variable", "", inlineVariable())
  add("Nim: use fmt for this string", "", concatToFmt())
  add("Nim: evaluate at compile time", "", nimEvaluate())
  add("Git: accept ours (conflict at cursor)", "", cmdConflict("ours"))
  add("Git: merge editor (ours | theirs | result)", "", cmdMergeEditor())
  add("Key bindings: default · vim · emacs · helix…", "", cmdKeymap())
  add("Remote: open a folder over SSH…", "", askText("Open over SSH (user@host:/path, or a Host from ~/.ssh/config)", "",
      proc(t: string) = remoteOpen(t)))
  add("Remote: pull the latest files from the server", "", (block:
    let ri = remoteHere()
    if ri < 0: info("This folder is not a remote one — Remote: open a folder over SSH…")
    else: remoteConnect(remotes[ri], proc() = remotePull(ri, false))))
  add("Remote: SSH menu…", "", cmdRemoteMenu())
  add("Workspace: add a folder…", "", askPath("Add a folder to the workspace", parentDir(rootDir) & "/", proc(t: string) = wsAddFolder(t)))
  add("Workspace: remove a folder…", "", cmdWsRemove())
  add("Workspace: save as…", "", askPath("Save the workspace as",
      (if wsFile.len > 0: wsFile else: rootDir / extractFilename(rootDir) & ".ned-workspace"), proc(t: string) = wsSave(t)))
  add("Workspace: open a workspace file…", "", askPath("Open a .ned-workspace or .code-workspace file", rootDir & "/",
      proc(t: string) = discard openWorkspace(absolutePath(expandTilde(t.strip)))))
  add("Accessibility mode: on/off (ASCII, letters beside colours, a high-contrast theme)", "", (block:
    let on = not sBool("ui.accessible")
    setSetting("ui.accessible", %on)
    if on:
      if cfgThemeName notin ["modus-vivendi", "modus-operandi"]:
        setSetting("ui.themeBeforeAccessible", %cfgThemeName)
        let dark = theme.dark
        applyTheme(if dark: "modus-vivendi" else: "modus-operandi")
        setSetting("theme", %(if dark: "modus-vivendi" else: "modus-operandi"))
      info("Accessibility mode on: ASCII frames and symbols, E/W/B/+/~ beside the colours, the " & cfgThemeName & " theme")
    else:
      let was = sStr("ui.themeBeforeAccessible")
      if was.len > 0 and cfgThemeName in ["modus-vivendi", "modus-operandi"]:
        applyTheme(was)
        setSetting("theme", %was)
      info("Accessibility mode off")
    prevGrid.setLen(0)))
  add("Settings sync: export to a file…", "", askPath("Export your settings to", "~/" & SyncFile, proc(t: string) = syncExport(t)))
  add("Settings sync: import from a file…", "", askPath("Import settings from", "~/" & SyncFile, proc(t: string) = syncImport(t)))
  add("Settings sync: sync now (both ways)", "this device's changes and the other's merged, key by key", syncBoth())
  add("Settings sync: install the other device's plugins", "the ones offered here before and not installed",
      cmdSyncOfferedPlugins())
  add("Settings sync: push (save to your settings repository)", "", syncGit(true))
  add("Settings sync: pull (load from your settings repository)", "", syncGit(false))
  add("Settings sync: set the repository…", "", askText("Your settings repository (a private git repository you can push to)",
      sStr("sync.repository"), proc(t: string) =
        if syncRepoOk(t.strip):
          setSetting("sync.repository", %t.strip)
          info("Settings repository: " & t.strip & " — Settings sync: push saves your settings there")))
  add("Spell check: where (off · Markdown · also code comments and strings)…", "", cmdSpellWhere())
  add("Spell check: next misspelled word", "", spellNext())
  add("Spell check: download a dictionary…", "", cmdSpellDownload())
  add("Spell check: add the word at the cursor to your dictionary", "", (block:
    let b = buf()
    let w = b.wordAt(b.primary.head)
    if w.len > 0:
      spellAddWord(w)
      needRender = true))
  add("Git: accept theirs (conflict at cursor)", "", cmdConflict("theirs"))
  add("Git: accept both (conflict at cursor)", "", cmdConflict("both"))
  add("Git: next merge conflict", "", cmdConflict("next"))
  add("Git: compare with last commit (side by side)", "", cmdCompareHead())
  add("File: compare with another file…", "side by side", cmdCompareWithFile())
  add("Nim: sort imports", "", cmdSortImports())
  add("Nim: organize imports (remove unused, sort)", "", cmdOrganizeImports())
  add("Nim: toggle proc ⇄ func", "", cmdToggleFunc())
  add("Settings: open project settings (this folder)", "", (block:
    let p = projectSettingsFile()
    if not fileExists(p):
      try:
        createDir(parentDir(p))
        writeFile(p, "// ned project settings: they override your settings inside this folder.\n" &
                     "// Any key of the settings file works, e.g. \"editor.tabSize\": 2 or \"nim.projectFile\": \"src/app.nim\".\n" &
                     "// Keys that start programs (lsp, run, formatters, terminal.shell, ai.*) need \"Workspace: trust this folder\".\n{\n}\n")
      except CatchableError as e:
        error(e.msg)
    discard openFile(p)))
  add("Workspace: trust this folder", "", (block:
    if rootDir.len == 0: info("Open a folder first")
    else: trustFolder(rootDir)))
  add("Workspace: stop trusting this folder", "", (block:
    let k = trustKey(rootDir)
    var i = trustedDirs.find(k)
    if i < 0: i = trustedDirs.find(rootDir)
    if i >= 0: trustedDirs.delete(i)
    saveState()
    reloadSettings(true)
    info("Not trusted any more: ned runs none of this folder's code, and its project settings cannot start " &
         "programs" & (if codeTrusted(rootDir): " (a folder around it is still trusted)" else: ""))))
  add("Nim panel (project, tools, toolchain)", "Alt+E", showSide(svProject))
  add("Nimble: tasks…", "Alt+Y", cmdNimbleTasks())
  add("Nimble: build", "", runNimble("build"))
  add("Nimble: run", "", runNimble("run"))
  add("Nimble: test", "", runNimble("test"))
  add("Nimble: install dependencies", "", runNimble("install -d -y"))
  add("Nimble: install nimlangserver", "", runNimble("install -y nimlangserver"))
  add("Nimble: install nph (formatter)", "", runNimble("install -y nph"))
  add("Nimble: custom command…", "", openPrompt(pNimbleTask, "nimble", ""))
  add("Nimble: add a dependency…", "", cmdNimbleAddDependency())
  add("Nimble: lock file — what it pins and what changed", "", cmdNimbleLockChanges())
  add("Nim: the configuration the compiler ends up with (nim dump)", "", cmdNimConfig())
  add("Atlas…", "", cmdAtlas())
  add("Atlas: install", "", atlasRun("install"))
  add("Atlas: update all", "", atlasRun("update"))
  add("Atlas: update one…", "", cmdAtlasUpdateOne())
  add("Atlas: add a dependency…", "", cmdAtlasAddDependency())
  add("Atlas: link a project…", "", cmdAtlasLink())
  add("Atlas: unlink…", "", cmdAtlasUnlink())
  add("Atlas: pin (atlas.lock)", "", atlasRun("pin"))
  add("Atlas: replay atlas.lock", "", atlasRun("rep"))
  add("Atlas: what changed since atlas.lock", "", atlasRun("changed"))
  add("Atlas: outdated dependencies", "", atlasRun("outdated"))
  add("Atlas: dependency tree", "", cmdAtlasDepTree())
  add("Atlas: a Nim for this project (env)…", "", cmdAtlasEnv())
  add("Atlas: run a task…", "", cmdAtlasTasks())
  add("Atlas: build (atlas-run)", "", atlasRunTool("build"))
  add("Atlas: run the tests (atlas-run)", "", atlasRunTool("tests"))
  add("Atlas: make this an Atlas project", "", cmdAtlasInit())
  add("Nimony: check file", "", cmdNimony(false))
  add("Nimony: run file", "", cmdNimony(true))
  add("Nim 3: what this file needs (porting problems)", "", cmdNim3Problems())
  add("Nim 3: the NIF of this file beside it", "nimony's code for it, each side following the cursor in the other",
      cmdNifView())
  add("Edit: put the selection through a command…", "", cmdPipeSelection())
  add("Hex: symbols…", "", cmdHexSymbols())
  add("Hex: decompile a function…", "", cmdDecompileHex())
  add("Nim: decompile this proc (side by side)", "", cmdDecompileProc())
  add("Compiler Explorer", "the file beside its assembly, live (as godbolt.org)", cmdCompilerExplorer())
  add("Compiler Explorer: options…", "compiler, target, options, filters, execution", cmdCeOptions())
  add("Compiler Explorer: compare with other options…", "the assembly of two option sets in the diff view",
      cmdCeCompare())
  add("Compiler Explorer: run the program after each compile (on / off)", "", cmdCeToggleRun())
  add("Decompile a program…", "", cmdDecompileFile())
  add("Hex: sections…", "", cmdHexSections())
  add("Hex: Nim modules by size", "", cmdHexNimSizes())
  add("Hex: open the Nim source of the proc at the cursor", "", cmdHexOpenSource())
  add("Hex: go to offset…", "Ctrl+G", (if buf().hex != nil: discard buf().hexKey(Key(kind: kChar, ch: ord('g'), mods: {mCtrl})) else: info("Open a binary file")))
  add("Hex: find bytes or text…", "Ctrl+F", (if buf().hex != nil: discard buf().hexKey(Key(kind: kChar, ch: ord('f'), mods: {mCtrl})) else: info("Open a binary file")))
  add("Hex: copy as hex", "Ctrl+C", (if buf().hex != nil: buf().hexCopy("hex") else: info("Open a binary file")))
  add("Hex: copy as a Nim array", "", (if buf().hex != nil: buf().hexCopy("nim") else: info("Open a binary file")))
  add("Hex: copy as a Nim string", "", (if buf().hex != nil: buf().hexCopy("nimstr") else: info("Open a binary file")))
  add("Hex: copy as a C array", "", (if buf().hex != nil: buf().hexCopy("c") else: info("Open a binary file")))
  add("Hex: insert mode on/off", "Insert", (if buf().hex != nil: discard buf().hexKey(Key(kind: kInsert)) else: info("Open a binary file")))
  add("Hex: show as text", "", cmdHexAsText())
  add("Nim 3: pnak fetch (the project's packages, in deps/)", "pnak checks out the packages the .nimble (or " &
      "pnak.nif) asks for and writes nimony.paths", cmdPnak("fetch"))
  add("Nim 3: pnak pin (write pnak.nif)", "every package the project needs, theirs too, at the commit in use: a " &
      "lockfile", cmdPnak("pin"))
  add("Nim 3: port this file with AI", "", cmdNim3PortAi())
  add("Nim 3: this project is Nim 3 (nimony)", "", setProjectSetting("nim.compiler", %"nimony"))
  add("Nim 3: this project is Nim 2 (nim)", "", setProjectSetting("nim.compiler", %"nim"))
  add("Find references", "Alt+Q / Shift+F12", cmdReferences())
  add("File: reopen with encoding…", "", cmdEncodingPick(true))
  add("File: save with encoding…", "", cmdEncodingPick(false))
  add("Nim: AST view (the tree a macro gets, beside the code)", "", cmdAstView())
  add("Nim: preview this file's docs (as nim doc shows them)", "", cmdDocPreview())
  add("Plugins panel", "", (if rightOpen and rightView == svPlugins and focus == fRight: toggleDock(dsRight)
                            else: showSide(svPlugins)))
  add("Plugins: run a plugin's command…", "", cmdPluginCommands())
  add("Plugins: new plugin…", "", (plugNewFull = false; openPrompt(pPluginNew, "Name of the new plugin", "")))
  add("Plugins: new plugin in full Nim (compiled)…", "", (plugNewFull = true;
      openPrompt(pPluginNew, "Name of the new plugin (full Nim: compiled, a process of its own)", "")))
  add("Plugins: browse the plugin list…", "", plugBrowse())
  add("Plugins: update (git pull)", "", plugUpdate())
  add("Plugins: reload one…", "", cmdPluginReloadOne())
  add("Plugins: add an example…", "", plugAddExample())
  add("Plugins: install from git…", "", openPrompt(pPluginInstall, "Plugin repository (https://…)", ""))
  add("Plugins: reload", "", plugReload())
  add("Plugins: turn one on or off…", "", cmdPluginToggle())
  add("Plugins: permissions…", "what each may do beyond editing: run programs, change files, the clipboard",
      cmdPluginPermissions())
  add("Plugins: the API (nedplugin.nim)", "", plugHelp())
  add("Plugins: available plugins (ned's own)…", "turn one on: increment, case changes, align, harpoon …",
      cmdPluginsAvailable())
  add("Plugins: uninstall / remove one…", "", cmdPluginUninstall())
  add("TODOs panel", "", (if rightOpen and rightView == svTodos and focus == fRight: toggleDock(dsRight) else: showSide(svTodos)))
  add("TODO: next in this file", "Alt+V", todoJump(1))
  add("TODO: previous in this file", "Alt+Shift+V", todoJump(-1))
  add("TODO: insert a tag comment…", "", todoInsertMenu())
  add("TODO: copy the list as Markdown", "", todoCopyMarkdown())
  add("TODO: rescan the project", "", todoScanProject())
  add("Outline panel", "Alt+I", (if rightOpen and rightView == svOutline and focus == fRight: toggleDock(dsRight) else: showSide(svOutline)))
  add("Git panel", "Alt+G", showSide(svGit))
  add("Git: commit…", "", openPrompt(pGitCommit, "Commit message", ""))
  add("Git: stage all", "", gitRun(@["add", "-A"], "Staged all changes"))
  add("Git: pull", "", gitNet("pull", "Pulled"))
  add("Git: pull (rebase)", "", gitNet("pull --rebase", "Pulled"))
  add("Git: push", "", gitNet("push", "Pushed"))
  add("Git: sign in to GitHub", "GitHub CLI or an SSH key", cmdGithubSignIn())
  add("Git: fetch", "", gitNet("fetch --all --prune", "Fetched"))
  add("Git: sync (pull, then push)", "", gitSync())
  add("Git: branches…", "click the branch in the title bar", cmdBranches())
  add("Git: commit (message box)…", "", gitCommitBox(false))
  add("Git: amend the last commit…", "", gitCommitBox(true))
  add("Git: undo…", "the last commits, pulls, merges, rebases — back to before one", gitUndoMenu())
  add("Git: undo the last step", "a commit, an amend, a pull, a merge …", gitUndoLast())
  add("Git: undo the last commit", "its changes stay, staged", gitUndoLast())
  add("Git: stage selected lines", "", stageSelectedLines())
  add("Git: history…", "", gitLogView())
  add("Git: stash…", "", gitStashMenu())
  add("Git: blame this file", "", gitBlame())
  add("Git: continue (merge / rebase)", "", gitContinue())
  add("Git: abort (merge / rebase)", "", gitAbort())
  add("Git: clone a repository…", "", gitCloneFromLink())
  add("File: clone from a link…", "GitHub, GitLab, any git server", gitCloneFromLink())
  add("Git: initialize a repository here", "git init", gitInitHere())
  add("Git: create a tag…", "", gitAsk("Tag name", "", proc(t: string) = gitShell("git tag " & quoteShell(t), "Tagged " & t)))
  add("Git: push tags", "", gitNet("push --tags", "Pushed the tags"))
  add("Git: copy link to this line", "GitHub / GitLab / Codeberg", gitCopyLink())
  add("Git: create a pull request (gh)", "", (if haveExe("gh"): runInTerm("gh pr create --fill")
                                             else: info("Install the GitHub CLI (gh) for pull requests")))
  add("Git: diff current file", "", (block:
    if buf().path.len > 0: gitDiffView(buf().path, false)))
  add("Open in browser", "", (block:
    if buf().path.len > 0: openInBrowser(buf().path)))
  add("Toggle auto hover", "", (block:
    toggleSetting("editor.autoHover", "Auto hover")))
  add("Toggle sticky scroll", "", (block:
    toggleSetting("editor.stickyScroll", "Sticky scroll")))
  add("Toggle rainbow brackets", "", (block:
    toggleSetting("editor.rainbowBrackets", "Rainbow brackets")))
  add("Toggle live diagnostics", "", (block:
    toggleSetting("nim.liveDiagnostics", "Live diagnostics")))
  add("Toggle format on save", "", (block:
    toggleSetting("editor.formatOnSave", "Format on save")))
  add("Insert snippet…", "Tab after keyword", (block:
    let b = buf()
    var items: seq[(string, string, Action)]
    for (k, d, body) in snippetList(b.lang.id):
      block:
        let bd = body
        let kk = k
        let dd = d
        capture bd:
          items.add act(kk, dd, proc() =
            let bb = buf()
            bb.expandSnippet(bb.primary.range[0], bb.primary.range[1], bd))
    if items.len == 0: info("No snippets for " & b.lang.name)
    else: openActions("Snippets — " & b.lang.name, items)))
  add("Welcome page", "", (block:
    newFile()
    buf().welcome = true))
  # ── v3: desktop chrome, docks, panels ──
  add("Command palette", "Ctrl+E", cmdPalette())
  add("Open folder…", "", cmdOpenFolder())
  add("Theme: import a VS Code or base16 theme…", "", askPath("Theme file (.json, .yaml)", getHomeDir() & "/",
                                                            proc(t: string) = importTheme(t)))
  add("Theme: make my own copy of this theme", "", cmdEditThemeColours())
  add("Theme: edit colours (contrast checked)…", "", cmdThemeEditor())
  add("Theme: reload theme files", "", reloadThemes())
  add("Theme: use these colours in all of Termux", "", cmdTermuxColors())
  add("Theme: put Termux's own colours back", "", cmdTermuxRestore())
  add("Theme: light by day, dark at night", "", (block:
    if sStr("theme.autoBy") != "clock": setSetting("theme.autoBy", %"clock")
    if cfgThemeName != "auto": setSetting("theme", %"auto")
    info((if isDaytime(): "Day" else: "Night") & ": " & theme.name & " — light from " & sStr("theme.dayStarts") &
         ", dark from " & sStr("theme.nightStarts") & " (theme.light, theme.dark and these times are settings)")))
  add("Run: configurations…", "", cmdRunConfigs())
  add("Tasks: run a task…", "Shift+F4", cmdRunTask())
  add("Tasks: run the last task again", "F4", cmdRerunTask())
  add("Run: current file with arguments…", "", runWithArgs())
  add("Nim: what can this proc raise?", "", nimEffects())
  add("Nim: benchmark a call…", "", nimBenchmark())
  add("Nim: run the examples at the cursor (runnableExamples)", "", (block:
    let b = buf()
    var hit = -1
    for (a, e) in b.exampleBlocks():
      if b.primary.head.line in a .. e: hit = a
    if hit < 0:
      let (pa, pe) = b.enclosingProc(b.primary.head.line)
      for (a, _) in b.exampleBlocks():
        if pa >= 0 and a in pa .. pe: hit = a
    if hit >= 0: runExamples(b, hit) else: info("No runnableExamples here — Nim: run all examples in this file")))
  add("Nim: run all examples in this file", "", runExamples(buf(), -1))
  add("Nimble: release a new version…", "", nimbleRelease())
  add("Git: interactive rebase…", "", gitInteractiveRebase())
  add("Git: cherry-pick from a branch…", "", gitCherryPickFromBranch())
  add("Git: compare with a branch…", "", gitCompareBranch())
  add("Git: branch graph", "", gitBranchGraph())
  add("Git: history of these lines", "the selection, or the proc the cursor is in", gitLineHistory())
  add("Git: find the commit that broke it (bisect)…", "", gitBisectStart())
  add("Git: bisect — good (works here)", "", gitBisectStep("good"))
  add("Git: bisect — bad (broken here)", "", gitBisectStep("bad"))
  add("Git: bisect — skip (cannot tell here)", "", gitBisectStep("skip"))
  add("Git: bisect — stop, back to where I was", "", gitBisectStep("reset"))
  add("Git: worktrees…", "", gitWorktrees())
  add("Git: submodules…", "", gitSubmodules())
  add("Git: GitHub…", "", ghMenu())
  add("Git: GitHub pull requests…", "", ghPullRequests())
  add("Git: GitHub issues…", "", ghIssues())
  add("Git: GitHub Actions (CI)…", "", ghRuns())
  add("Git: GitHub review comments…", "the pull request's, on their lines", cmdReviewComments())
  add("File: open folder by path…", "", openPrompt(pOpenFolder, "Open folder", rootDir & "/"))
  add("Cut", "Ctrl+X", copySel(true))
  add("Copy", "Ctrl+C", copySel(false))
  add("Paste", "Ctrl+V", paste())
  add("Expand selection", "Alt+Shift+→", expandSelection())
  add("Shrink selection", "Alt+Shift+←", shrinkSelection())
  add("Surround with…", "Alt+Shift+S", cmdSurround())
  add("Change the surrounding pair…", "", cmdChangeSurrounding())
  add("Delete the surrounding pair", "", cmdDeleteSurrounding())
  add("Files", "Ctrl+B", showSide(svFiles))
  add("Search view", "Alt+S", showSide(svSearch))
  add("Test explorer", "", showSide(svTests))
  add("AI assistant", "Alt+C", toggleAssistant())
  add("Timeline", "", showSide(svTimeline))
  add("Toggle terminal", "Ctrl+\\ / Alt+`", toggleTerminal())
  add("Terminal: new", "", newTerminal())
  add("Terminal: split", "", termSplitToggle())
  add("Terminal: focus the other split", "Ctrl+PgUp/PgDn", termCycle(1))
  add("Terminal: commands…", "", termCommands())
  add("Terminal: previous command", "Ctrl+↑", (block:
    let t = curTermObj()
    if t != nil:
      setPanel(pkTerminal)
      focus = fPanel
      t.termNav(-1)))
  add("Terminal: next command", "Ctrl+↓", (block:
    let t = curTermObj()
    if t != nil: t.termNav(1)))
  add("Terminal: run the last command again", "", (block:
    let t = curTermObj()
    if t != nil:
      let i = t.termLastRan
      if i < 0: info("No command has run in this terminal yet")
      else: t.termRunText(t.cmds[i].text)))
  add("Terminal: copy the last command's output", "", (block:
    let t = curTermObj()
    if t != nil:
      let i = t.termLastRan
      if i < 0: info("No command has run in this terminal yet")
      else:
        let o = t.termCmdOutput(i)
        clipSet(o)
        info("Copied the output of " & truncTo(t.cmds[i].text, 40) & " (" & $(if o.len == 0: 0 else: o.count('\n') + 1) & " lines)")))
  add("Toggle left dock", "Ctrl+B", toggleDock(dsLeft))
  add("Toggle right dock", "", toggleDock(dsRight))
  add("Focus next area", "F6", cycleFocus(1))
  add("Menu bar", "F10", (if lay.titleY >= 0 and menuBarRanges.len > 0: openMenuBar(0) else: openAppMenu()))
  add("Toggle maximized panel", "", (panelMax = not panelMax))
  add("Toggle zen mode", "Alt+Z", toggleZen())
  add("Toggle title bar", "", toggleSetting("ui.titleBar", "Title bar"))
  add("Toggle tab bar", "", toggleSetting("ui.tabBar", "Tab bar"))
  add("Toggle breadcrumbs", "", toggleSetting("ui.breadcrumbs", "Breadcrumbs"))
  add("Toggle status bar", "", toggleSetting("ui.statusBar", "Status bar"))
  add("Toggle touch bar", "keys for touch above the status bar", (block:
    setSetting("ui.touchBar", %(if lay.touchY >= 0: "off" else: "on"))
    info("Touch bar " & cfgTouchBar & " (ui.touchBarKeys picks its keys)")))
  add("Toggle shadows", "", toggleSetting("ui.shadows", "Shadows"))
  add("Toggle minimap", "", (block:
    setSetting("ui.minimap", %(if cfgMinimap == "off": "on" else: "off"))
    info("Minimap " & cfgMinimap)))
  add("Cycle icon set", "", (block:
    let nx = case cfgIcons
      of "unicode": "nerd"
      of "nerd": "ascii"
      else: "unicode"
    setSetting("ui.icons", %nx)
    info("Icons: " & nx & (if nx == "nerd": " (needs a Nerd Font)" else: ""))))
  add("Toggle inlay hints", "", (block:
    toggleSetting("editor.inlayHints", "Inlay hints")
    for b in bufs:
      b.inlays.clear()
      b.inlayAt = -1))
  add("Toggle exception hints", "what a Nim routine can raise, after its header",
      toggleSetting("nim.raisesHints", "Exception hints"))
  add("Toggle code lens", "", toggleSetting("editor.codeLens", "Run buttons"))
  add("Toggle vim mode", "", (block:
    toggleSetting("editor.vimMode", "Vim mode")
    vimMode = vmNormal
    vimShape()))
  add("Toggle hover effects", "", toggleSetting("ui.hoverEffects", "Hover effects"))
  add("Fold", "Alt+-", (block:
    let b = buf()
    b.foldLine(b.primary.head.line)))
  add("Unfold", "Alt+=", (block:
    let b = buf()
    b.unfoldLine(b.primary.head.line)))
  add("Toggle fold", "", (block:
    let b = buf()
    b.toggleFold(b.primary.head.line)))
  add("Fold all", "", buf().foldAllAt(0))
  add("Fold level 2", "", buf().foldAllAt(1))
  add("Unfold all", "", (buf().folds.setLen(0)))
  add("Go to symbol in project…", "Ctrl+P #", cmdProjectSymbols())
  add("Quick fix / code actions…", (if inWindowsTerminal(): "Alt+Shift+Enter · Ctrl+." else: "Alt+Enter · Ctrl+."),
      cmdCodeActions())
  add("Nim: debug with gdb", "", cmdDebugGdb())
  add("Debug: start / continue", "F5", dbgStart())
  add("Debug: toggle breakpoint", "F9", toggleBreakpoint())
  add("Debug: conditional breakpoint on this line…", "", cmdBpCond())
  add("Debug: logpoint on this line…", "prints a message, does not stop", cmdBpLog())
  add("Debug: stop when this changes…", "a watchpoint", cmdWatchpoint())
  add("Debug: run to cursor", "Ctrl+F10", dbgRunToCursor())
  add("Debug: add a watch expression…", "", dbgPanelAction("dbg:watch"))
  add("Debug: remove all watches", "", (block:
    dbgWatches.setLen(0)
    dbgPanel()))
  add("Debug: debug the test at the cursor", "", debugTestAtCursor())
  add("Debug: check the debugger for this file", "", cmdDebugCheck())
  add("Debug: choose the debugger for this language…", "", cmdDebugChoose())
  add("Debug: install the debugger for this language…", "", cmdDebugInstall())
  add("Debug: step over", "F10", dbgCmd("-exec-next"))
  add("Debug: step into", "F11", dbgCmd("-exec-step"))
  add("Debug: step out", "Shift+F11", dbgCmd("-exec-finish"))
  add("Debug: stop", "Shift+F5", (if dbgOn: dbgEnd("stopped") else: info("Not debugging")))
  add("Debug: remove all breakpoints", "", (block:
    breakpoints.clear()
    bpCond.clear()
    bpLog.clear()
    if dbgOn: dbgSend("-break-delete")
    needRender = true))
  add("Debug: show the debug panel", "", (block:
    dbgPanel()
    setPanel(pkDebug)))
  add("Nim: generate docs", "", (block:
    let b = buf()
    if b.lang.mode == lmNim and b.path.len > 0:
      runCommand("nim doc --project --outdir:htmldocs " & quoteShell(nimProjectFile(b)), parentDir(nimProjectFile(b)))
    else: info("Open a Nim file first")))
  add("Nim: language server settings…", "", openSettingsUi("nim."))
  add("Run tests in file", "", (block:
    let b = buf()
    if testLangOf(b.path).len > 0:
      rescanTests()
      runTests(b.path)
    else: info("Open a test file (Nim, Python, Go, Rust, PHP, C#, Kotlin or Java)")))
  add("Run all tests", "", runAllTests())
  add("Nim: testament — run the spec tests in tests/", "", (block:
    if not testScanned: rescanTests()
    var specs: seq[string]
    for e in testEntries:
      if e.name == TestamentName and e.path notin specs: specs.add e.path
    if specs.len == 0: info("No testament tests: files in tests/ that start with a discard \"\"\" … \"\"\" spec")
    else: runTestamentFiles(specs)))
  add("AI: new chat", "", aiNewChat())
  add("AI: stop", "", aiStop())
  add("AI: ask about selection", "", (block:
    showSide(svAssistant)
    if aiInput.len == 0:
      aiInput = (if buf().primary.hasSel: "Explain the selected code." else: "Explain this file.")
      aiInputCur = aiInput.len))
  add("AI: edit selection…", "Alt+Shift+C", openPrompt(pAiEdit, "Edit with AI — describe the change", ""))
  add("AI: explain code", "", aiQuick("Explain this code step by step, briefly."))
  add("AI: fix problems in file", "", (block:
    let b = buf()
    var ds = ""
    for d in diagsFor(b.path): ds.add "line " & $(d.line + 1) & ": " & d.msg.splitLines()[0] & "\n"
    aiQuick("Fix these problems in the file" & (if ds.len > 0: ":\n" & ds else: " (run a check first if needed)."))))
  add("AI: write tests", "kept when they pass", aiWriteTests())
  add("AI: add doc comments", "", aiQuick("Add concise doc comments (## for Nim) to the public procs and types here, editing the file."))
  add("AI: choose provider…", "", aiChooseProvider())
  add("AI: choose model…", "", aiChooseModel())
  add("AI: toggle agent mode", "", toggleSetting("ai.agent", "Agent mode"))
  add("AI: settings…", "", openSettingsUi("ai."))
  add("Tips", "", (block:
    var t = ""
    for x in Tips: t.add "• " & x & "\n"
    discard openScratch("tips", t, langByName("Markdown"))))
  add("Check setup", "", cmdCheckSetup())
  add("Performance report", "frame time, what the terminal is sent, background work, memory", cmdPerfReport())
  add("Redraw the screen", "everything sent to the terminal again (if it shows something out of place)", (block:
    prevGrid.setLen(0)
    needRender = true))
  add("Copy info for bug report", "", cmdCopyBugInfo())
  add("About ned", "", openDialog("About ned", "ned " & Version & " — a fast, safe code editor for Termux " &
    "and Linux, written in Nim. Desktop-style UI in the terminal, Nim IDE features, integrated terminal, AI assistant, " &
    $allThemesRaw().len & " themes and vim mode. Settings: " & configFile(), @[("OK", 'y')], nil))

proc commandsMarkdown(): string =
  ## every command of the palette as Markdown (`ned --doc-commands`: docs/reference/commands.md is made from it)
  if commands.len == 0: initCommands()
  var seen: HashSet[string]
  var rows: seq[(string, string)]
  for c in commands:
    if c.name in seen or c.keys == MacroMark or c.name.startsWith("User: "): continue   # (not your own macros)
    seen.incl c.name
    rows.add (c.name, c.keys)
  rows.sort(proc(a, b: (string, string)): int = cmp(a[0].toLowerAscii, b[0].toLowerAscii))
  result = "# Commands\n\nEvery command of the palette (Ctrl+E, or Ctrl+P and `>`), with its key or what it does — " &
           "made by `ned --doc-commands`. Your own keys: the `keys` setting; your own commands: `commands`.\n\n" &
           "| Command | Key, or what it does |\n|---|---|\n"
  for (n, k) in rows:
    result.add "| " & n.replace("|", "\\|") & " | " & k.replace("|", "\\|") & " |\n"

