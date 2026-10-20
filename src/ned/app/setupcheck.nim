# ════════════════════════════════════════════════════════════════════════════
#  Setup check (Help ▸ Check setup, ned --check) and info for bug reports
# ════════════════════════════════════════════════════════════════════════════

type SetupRow = tuple[group, name: string, state: int, ver, purpose, hint: string]
  ## state: 0 found · 1 missing, optional · 2 missing, needed · 3 a note

proc isTermux(): bool = getEnv("TERMUX_VERSION").len > 0 or "com.termux" in getEnv("PREFIX")

proc detectTrueColor(): bool =
  let ct = getEnv("COLORTERM").toLowerAscii
  "truecolor" in ct or "24bit" in ct or getEnv("TERMUX_VERSION").len > 0 or
    "direct" in getEnv("TERM") or getEnv("TERM_PROGRAM") in ["iTerm.app", "WezTerm", "vscode", "ghostty"]

proc installHint(termuxPkg, linuxPkg: string): string =
  ## the command that installs a missing package on this system
  if isTermux(): return "pkg install " & termuxPkg
  if haveExe("apt"): "sudo apt install " & linuxPkg
  elif haveExe("dnf"): "sudo dnf install " & linuxPkg
  elif haveExe("pacman"): "sudo pacman -S " & linuxPkg
  elif haveExe("apk"): "sudo apk add " & linuxPkg
  elif haveExe("zypper"): "sudo zypper install " & linuxPkg
  elif haveExe("brew") or defined(macosx): "brew install " & linuxPkg
  else: "install " & linuxPkg & " with your package manager"

proc versionOf(tool: string): string =
  ## first version-looking word of `tool --version` ("" when there is none)
  let (_, o, e) = runFilter(quoteShell(findExe(tool)) & " --version 2>&1", "", rootDir, 4000)
  for l in (o & "\n" & e).splitLines:
    for w in l.splitWhitespace:
      let v = w.strip(chars = {'v', 'V', ',', '(', ')', '[', ']'})
      if v.len >= 3 and v[0] in Digits and '.' in v: return v
  ""

proc osLine(): string =
  var u: Utsname
  if uname(u) == 0:
    result = $cast[cstring](addr u.sysname[0]) & " " & $cast[cstring](addr u.release[0]) & " " &
             $cast[cstring](addr u.machine[0])
  else:
    result = hostOS & " " & hostCPU
  if isWsl(): result.add " · WSL" & (if getEnv("WSL_DISTRO_NAME").len > 0: " (" & getEnv("WSL_DISTRO_NAME") & ")" else: "")
  if isTermux():
    result.add " · Termux " & getEnv("TERMUX_VERSION", "?")
    let (ok, o, _) = runFilter("getprop ro.build.version.release", "", rootDir, 2000)
    if ok and o.strip.len > 0: result.add " · Android " & o.strip

proc termLine(inEditor: bool): string =
  let tc = if inEditor: trueColor else: detectTrueColor()
  let (w, h) = if inEditor: (scrW, scrH) else: getTermSize()
  result = "TERM=" & getEnv("TERM", "?") & " · " & (if tc: "true colour" else: "256 colours") & " · " & $w & "×" & $h

proc setupRows(inEditor: bool): seq[SetupRow] =
  var rows: seq[SetupRow]
  proc tool(group, name, purpose: string, needed: bool, hint: string, askVersion = true) =
    if haveExe(name):
      rows.add (group, name, 0, (if askVersion: versionOf(name) else: ""), purpose, "")
    else:
      rows.add (group, name, (if needed: 2 else: 1), "", "not installed · " & purpose, hint)
  rows.add ("System", "system", 3, "", osLine(), "")
  rows.add ("System", "terminal", 3, "", termLine(inEditor),
            (if inEditor and not trueColor: "colours look off? set COLORTERM=truecolor or \"ui.trueColor\": \"on\"" else: ""))
  if inEditor:
    # what the terminal said it can do (termcaps), and what ned does with it
    var said = if tcAnswers.len > 0: tcAnswers.join(", ") else: "nothing to ned's questions"
    rows.add ("System", "terminal answers", 3, "", said, "")
    rows.add ("System", "keys", 3, "",
              (if tcKittyOn: "kitty keyboard protocol: Ctrl+Shift+letters, Ctrl+I, Ctrl+Enter, Shift+Enter"
               elif tcKitty: "kitty keyboard protocol off (ui.kittyKeyboard)"
               else: "the classic way (Ctrl+Shift+F arrives as Ctrl+F; Ctrl+I as Tab)"), "")
    if inWindowsTerminal():
      rows.add ("System", "quick fixes", 1, "", "Windows Terminal keeps Alt+Enter for full screen: quick fixes are " &
                "Alt+Shift+Enter here (or Ctrl+., the right-click menu, Edit › Quick fix…)",
                "or remove Alt+Enter from Windows Terminal's Settings › Actions")
    rows.add ("System", "emoji", 3, "",
              (if graphemes: "emoji sequences as one character (👨‍👩‍👧, flags, skin tones)"
               else: "each emoji apart (ui.graphemes: \"on\" for a terminal that joins them)"), "")
    rows.add ("System", "underlines", 3, "",
              (if ulStyled: "curly underlines in the problem's colour" else: "straight underlines (ui.undercurl)"), "")
    if getEnv("NED_SOCKET").len > 0:
      rows.add ("System", "remote", 0, "", "ned --remote … and `ned FILE` in its terminal reach this ned", "")
  let cf = configFile()
  if fileExists(cf): rows.add ("System", "settings", 0, "", cf, "")
  else: rows.add ("System", "settings", 3, "", "not created yet — the defaults are in use", "palette (Ctrl+E) › Open settings file")
  let sd = stateDir()
  if not dirExists(sd) or posix.access(sd.cstring, W_OK) == 0: rows.add ("System", "state", 0, "", sd, "")
  else: rows.add ("System", "state", 2, "", sd & " is not writable — no session, recovery files or history", "")
  let nimHint = if isTermux(): "pkg install nim"
                elif defined(macosx): "brew install nim (or choosenim)"
                else: "see nim-lang.org/install.html (choosenim or grabnim)"
  tool("Nim", "nim", "compiler: run, build, check", true, nimHint)
  if nimToolchainLine().len > 0:
    rows.add ("Nim", "this project", (if tcProblem.len > 0: 2 else: 3), "", nimToolchainLine(),
              (if tcProblem.len > 0: tcProblem & " — Nim › choose the Nim for this project" else: ""))
  tool("Nim", "nimble", "packages and nimble tasks", true, nimHint)
  tool("Nim", "nimsuggest", "extra lookups for the built-in engine", false, "comes with Nim", false)
  tool("Nim", "nimlangserver", "optional language server (the built-in engine works without it)", false,
       "nimble install nimlangserver", false)
  tool("Nim", "nph", "optional formatter (the built-in one is used without it)", false, "nimble install nph", false)
  tool("Nim", "inim", "Nim REPL", false, "nimble install inim", false)
  tool("Nim", "gdb", "debugger", false, installHint("gdb", "gdb"))
  tool("Tools", "git", "source control", true, installHint("git", "git"))
  tool("Tools", "gh", "pull requests (Git › Pull request)", false, installHint("gh", "gh"))
  tool("Tools", "rg", "fast project search (grep is used without it)", false, installHint("ripgrep", "ripgrep"))
  tool("Tools", "curl", "AI assistant, playground sharing", false, installHint("curl", "curl"))
  # clipboard: OSC 52 always copies; reading (paste from other apps) needs a helper
  let clip = if haveExe("termux-clipboard-get"): "termux-clipboard"
             elif haveExe("pbpaste"): "pbcopy / pbpaste"
             elif getEnv("WAYLAND_DISPLAY").len > 0 and haveExe("wl-paste"): "wl-clipboard"
             elif getEnv("DISPLAY").len > 0 and haveExe("xclip"): "xclip"
             elif isWsl() and haveExe("powershell.exe"): "the Windows clipboard (OSC 52 and PowerShell)"
             else: ""
  if clip.len > 0: rows.add ("Tools", "clipboard", 0, "", clip, "")
  else:
    let h = if isTermux(): "pkg install termux-api, and install the Termux:API app"
            elif getEnv("WAYLAND_DISPLAY").len > 0: installHint("wl-clipboard", "wl-clipboard")
            else: installHint("xclip", "xclip")
    rows.add ("Tools", "clipboard", 1, "", "copy works through the terminal (OSC 52); pasting from other apps needs a helper", h)
  # AI: never shows the key itself
  let model = aiModel()
  let prov = cfgAiProvider & " · " & (if model.len > 0: model else: "model not chosen")
  if cfgAiProvider == "ollama": rows.add ("AI", "assistant", 0, "", prov & " · local, no key needed", "")
  elif aiKey().len > 0:
    rows.add ("AI", "assistant", 0, "", prov & " · key " &
      (if cfgAiKey.len > 0: "in the settings file (an environment variable is safer)" else: "from " & aiKeyEnvName()), "")
  else:
    rows.add ("AI", "assistant", 1, "", prov & " · no API key, so the assistant is off",
              "set " & aiKeyEnvName() & ", or pick another provider (AI: choose provider…)")
  rows

proc setupReport(inEditor: bool): string =
  let rows = setupRows(inEditor)
  result = AppName & " " & Version & " — setup check\n"
  var group = ""
  var needed, optional = 0
  for r in rows:
    if r.group != group:
      group = r.group
      result.add "\n" & group & "\n"
    let mark = case r.state
      of 0: "✓"
      of 2: "✗"
      of 1: "·"
      else: " "
    var line = "  " & mark & " " & alignLeft(r.name, 14)
    case r.state
    of 0: line.add (if r.ver.len > 0: r.ver & " · " else: "") & r.purpose
    else: line.add r.purpose
    if r.hint.len > 0: line.add "\n" & repeat(' ', 19) & "→ " & r.hint
    result.add line & "\n"
    if r.state == 2: inc needed
    elif r.state == 1: inc optional
  result.add "\n"
  if needed == 0 and optional == 0: result.add "Everything ned can use is here.\n"
  else:
    if needed > 0: result.add $needed & " missing (✗): the features next to them will not work.\n"
    if optional > 0: result.add $optional & " optional (·): ned works without them.\n"
  result.add "\nReporting a problem? Help › Copy info for bug report puts a short summary on the clipboard.\n"

proc bugReportInfo(): string =
  let rows = setupRows(true)
  var tools: seq[string]
  var nimV = ""
  for r in rows:
    if r.group in ["Nim", "Tools"]:
      if r.name == "nim": nimV = r.ver
      elif r.state == 0: tools.add r.name & (if r.ver.len > 0: " " & r.ver else: "")
      else: tools.add r.name & " ✗"
  result = "ned " & Version & " · Nim " & (if nimV.len > 0: nimV else: "not found") & " · " & osLine() & "\n" &
           "terminal: " & termLine(true) & " · theme " & cfgThemeName & "\n" &
           "tools: " & tools.join(", ") & "\n"

proc cmdCheckSetup() =
  info("Checking setup…")
  discard openScratch("Setup check", setupReport(true), langByName("Text"))

proc cmdCopyBugInfo() =
  let s = bugReportInfo()
  clipSet(s)
  toast("Copied for a bug report: ned " & Version & ", Nim, system, terminal and tools — paste it into the issue", 3)

proc initCommandsV4() =
  ## commands added in ned 4
  template add(n, k: string, body: untyped) =
    commands.add Command(name: n, keys: k, action: proc() = body)
  add("View: split editor right", "Alt+\\", splitEditor(false))
  add("View: split editor down", "", splitEditor(true))
  add("View: focus other pane", "Alt+\\", toggleSplitFocus())
  add("View: close split", "Alt+|", closeSplit())
  add("View: show file in other pane", "", moveToOtherPane())
  add("View: make pane/dock wider", "Ctrl+Alt+→", resizeBy(true, 1))
  add("View: make pane/dock narrower", "Ctrl+Alt+←", resizeBy(true, -1))
  add("View: make panel/pane taller", "Ctrl+Alt+↑", resizeBy(false, 1))
  add("View: make panel/pane shorter", "Ctrl+Alt+↓", resizeBy(false, -1))
  add("View: reset split and dock sizes", "", (block:
    splitRatio = 0.5
    cfgLeftW = 0
    cfgRightW = 0
    cfgPanelH = 0
    setSetting("ui.leftDockWidth", %0)
    setSetting("ui.rightDockWidth", %0)
    setSetting("ui.panelHeight", %0)))
  add("Bookmarks: toggle", "Alt+'", toggleBookmark())
  add("Bookmarks: next", "Alt+;", gotoBookmark(1))
  add("Bookmarks: previous", "Alt+:", gotoBookmark(-1))
  add("Bookmarks: list…", "", listBookmarks())
  add("Bookmarks: clear all", "", clearBookmarks())
  add("File: local history…", "", cmdLocalHistory())
  add("File: open recent project…", "", cmdRecentProjects())
  add("File: compare with saved", "", diffWithSaved())
  add("File: recover unsaved edits…", "", cmdRecoverFiles())
  add("File: allow editing this file", "read-only off", (block:
    let b = buf()
    if b.binary: info("A binary file opens in the hex editor (Tab: hex ↔ text · Insert: insert mode)")
    elif not b.readOnly: info(b.name & " can be edited")
    elif b.path.len == 0 or b.title.len > 0: info("This view is made by ned: it cannot be edited")
    else:
      b.readOnly = false
      b.libLocked = false
      info("You can edit " & b.name & " now — a save changes it for every project that uses it")
      needRender = true))
  add("Git: next change", "F7", gotoHunk(1))
  add("Git: previous change", "Shift+F7", gotoHunk(-1))
  add("Git: show this change", "", showHunk())
  add("Git: revert this change", "", revertHunk())
  add("Git: stage this change", "", stageHunk())
  add("Git: unstage this file", "", unstageFile())
  add("Git: unstage this change", "", cmdGitUnstageHere())
  add("Git: changes (every change, editable)…", "Alt+Shift+G", cmdGitChanges())
  add("Peek definition", "Alt+F12", cmdPeekDefinition())
  add("Call hierarchy (callers and calls)", "", cmdCallHierarchy())
  add("Type hierarchy (supertypes and subtypes)", "", cmdTypeHierarchy())
  add("Go to type definition", "", cmdTypeDefinition())
  add("Go to implementation", "", cmdImplementation())
  add("Go to symbol in workspace (language server)…", "", (block:
    let b = buf()
    let s = lspReady(b)
    if s != nil and s.caps != nil and s.caps{"workspaceSymbolProvider"} != nil:
      discard s.lspRequest("workspace/symbol", %*{"query": b.wordAt(b.primary.head)}, LspReq(kind: lrWsSymbols))
    else: cmdProjectSymbols()))
  add("Keyboard shortcuts…", "", cmdKeyboardShortcuts())
  add("Your commands…", "add, change or delete your own commands", cmdEditUserCommands())
  add("Show recent messages", "", (block:
    var t = ""
    for i in countdown(msgLog.high, 0):
      let (tm, sv, tx) = msgLog[i]
      t.add tm & "  " & ["info", "error", "warning", "info", "ok"][clamp(sv, 0, 4)] & "  " & tx.replace("\n", "\n          ") & "\n"
    discard openScratch("Recent messages", (if t.len > 0: t else: "No messages yet\n"), langByName("Text"))))
  add("File: rename or move this file…", "Nim imports follow", (block:
    let b = buf()
    if b.path.len == 0: info("Save the file first")
    else:
      treeTarget = b.path
      openPrompt(pRenamePath, "Rename or move to", relPath(b.path))))
  add("Nim: add the missing case branches", "Alt+Enter in a case", addMissingBranches())
  add("Nim: generate $, ==, hash and a constructor for this type", "Alt+Enter on a type", generateForType("all"))
  add("Nim: add a doc comment to this proc", "", docCommentStub())
  add("Nim: run the selection", "Alt+Enter with code selected", runSelection())
  add("Nim: test coverage (run, then colour the lines that ran)", "", cmdCoverage())
  add("Nim: hide coverage", "", (block:
    covLines.clear()
    needRender = true))
  add("Test coverage: run and colour the lines that ran", "", cmdCoverageRun())
  add("Test coverage: load an lcov file", "", cmdCoverageLoad())
  add("Test coverage: summary by file", "each file's share that ran, the total", covPanel())
  add("Test coverage: this Nim test file", "built with gcov, run, its lines counted", (block:
    let b = buf()
    if b.lang.mode == lmNim and b.path.len > 0: cmdCoverageTestFile(b.path)
    else: info("Open a Nim test file")))
  add("Test coverage: hide", "", (block:
    covLines.clear()
    needRender = true))
  add("Nim: profile", "where the time goes, by proc and by line", cmdProfile())
  add("Nim: show the profile", "", (if profRows.len > 0: (profShown = true; profPanel()) else: info("No profile yet — Nim: profile")))
  add("Nim: hide the profile", "", (profShown = false; needRender = true))
  add("Nim: share to the Playground (link to the clipboard)", "", cmdShareToPlayground())
  add("Nim: switch compiler version…", "choosenim · grabnim", cmdSwitchNim())
  add("Nim: standard library docs browser…", "", cmdDocsBrowser())
  add("Nimble: dependencies and updates…", "", cmdNimbleView())
  add("Nimble: dependency tree", "what requires what, and what is installed", cmdNimbleTree())
  add("CSV: sort by this column", "the first row stays when it holds the headings", cmdCsvSort(false))
  add("CSV: sort by this column, largest first", "", cmdCsvSort(true))
  add("CSV: summary of this column", "count, sum, smallest, largest, mean, the most common values", cmdCsvSummary())
  add("CSV: toggle lining the columns up", "", (block:
    setSetting("csv.alignColumns", %(not cfgCsvAlign))
    for bb in bufs:
      if bb.lang.mode == lmCsv:
        bb.inlays.clear()
        bb.inlayAt = -1
    cfgWrap = wrapFor(buf())
    info("CSV columns " & (if cfgCsvAlign: "lined up" else: "as written"))))
  add("Open results in a multibuffer (edit many files at once)", "", cmdMultibufferFromSearch())
  add("Markdown: open preview to the side", "", cmdMarkdownPreview())
  add("Peek references", "Alt+Shift+F12", cmdPeekReferences())
  add("Git: toggle inline blame", "", toggleSetting("git.inlineBlame", "Inline blame"))
  add("Nim: REPL (inim / nim secret)", "", nimRepl())
  add("REPL: send the selection or the statement at the cursor", "Shift+Enter", replSendSelOrStatement())
  add("REPL: send the cell (# %%)", "", replSendCell(buf(), buf().primary.head.line))
  add("REPL: send the proc / function at the cursor", "", replSendProc())
  add("REPL: send the whole file", "", replSendFile())
  add("REPL: open the REPL for this language", "", replOpen(buf().lang))
  add("REPL: restart", "", replOpen(buf().lang, true))
  add("Nim: toggle export marker (*)", "", toggleExport())
  add("Nim: open documentation for symbol", "", nimDocsForSymbol())
  add("Nimble: add dependency…", "", openPrompt(pNimbleAdd, "Package to require (e.g. jsony >= 1.1)", ""))
  add("Nimble: search packages…", "", openPrompt(pNimbleSearch, "nimble search", ""))
  add("Nimble: newer versions of the dependencies…", "", cmdNimbleOutdated())
  add("Git: generate commit message with AI", "", aiCommitMessage())
  add("AI: toggle inline suggestions", "", toggleSetting("ai.inlineCompletion", "Inline AI suggestions (Tab accepts)"))
  add("AI: chat history…", "", cmdChatHistory())
  add("AI: regenerate last reply", "", aiRegenerate())
  add("AI: explain problem at cursor", "", aiExplainProblem())
  add("AI: review staged changes (findings in Problems)", "", aiReviewStaged())
  add("AI: clear review findings", "", (block:
    diagsAi.clear()
    rebuildProblems()
    info("AI review findings cleared")))
  add("AI: undo the assistant's changes…", "", cmdAiUndo())
  add("AI: plan a change, then do it step by step…", "", cmdAiPlan())
  add("AI: on this device, offline (Ollama, llama.cpp)…", "", cmdAiOffline())
  add("AI: the plan… (go on, change it, go back to a step)", "", aiPlanMenu())
  add("AI: fast / smart model", "", toggleAiFast())
  add("AI: MCP servers…", "", cmdMcpServers())
  add("AI: review the assistant's changes…", "", cmdAiReview())
  add("AI: fix problem at cursor", "", aiFixProblem())
  add("AI: make the failing test pass", "the change kept only when the test then passes", cmdAiFixTest())
  add("Search: replace in files…", "", (block:
    let b = buf()
    if dockQuery.len == 0:
      let (a, e) = b.primary.range
      dockQuery = if a != e and a.line == e.line: b.getText(a, e) else: b.wordAt(b.primary.head)
      dockQueryCur = dockQuery.len
    showSide(svSearch)
    dockShowReplace = true
    dockField = if dockQuery.len > 0: 1 else: 0
    if dockQuery.len > 0 and dockQuery != dockQueryRan: projectSearch(dockQuery)))
  add("Search: undo replace all", "", undoProjectReplace())
  add("Search: only in some files…", "", showIncludeRow())
  add("Find: toggle regular expressions", "Alt+R in find", (block:
    findRegex = not findRegex
    info("Regular expressions " & (if findRegex: "on" else: "off"))))
