# ── context menus: what a right click (or a long press) offers, wherever it lands — a text field, the gutter, the
#    status bar and each of its parts, the title bar, a dock's header and its rows, the bottom panel, the
#    breadcrumbs, the minimap, a notification, a split pane's header ──

proc ctxOpen(items: seq[MenuItem]) =
  ## opens a context menu with these items just below the mouse pointer (nothing when the list is empty)
  if items.len > 0: openMenu(items, mouseX, mouseY + 1)

proc ctxCopy(label, text: string): MenuItem =
  ## a menu item that copies `text` to the clipboard and says so in a message
  let t = text
  mi(label, "", proc() =
    clipSet(t)
    info("Copied " & truncTo(t, 60)))

# ── a text field: as any text box ──

proc fieldMenu(tp: ptr string, cp: ptr int): seq[MenuItem] =
  ## the menu of a one-line text field (`tp` its text, `cp` its cursor): cut, copy, paste (the first line of the
  ## clipboard), select all and clear, with cut and copy off when nothing is selected
  let (a, b) = fieldSelRange(tp[], cp[])
  let hasSel = b > a
  @[mi("Cut", "Ctrl+X", proc() =
      clipSet(tp[][a ..< b])
      fieldSelect(tp[], a, b)
      discard fieldDeleteSel(tp[], cp[]), disabled = not hasSel),
    mi("Copy", "Ctrl+C", proc() = clipSet(tp[][a ..< b]), disabled = not hasSel),
    mi("Paste", "Ctrl+V", proc() =
      var t = clipGet()
      if t.len == 0: t = clipParts.join("")
      t = t.splitLines()[0]
      fieldSelect(tp[], a, b)
      cp[] = b
      discard fieldDeleteSel(tp[], cp[])
      tp[].insert(t, cp[])
      cp[] += t.len),
    msep(),
    mi("Select all", "Ctrl+A", proc() =
      fieldSelect(tp[], 0, tp[].len)
      cp[] = tp[].len),
    mi("Clear", "", proc() =
      tp[].setLen(0)
      cp[] = 0
      fieldSelClear(), disabled = tp[].len == 0)]

# ── the editor's gutter: the line's breakpoint, bookmark, fold, git change ──

proc ctxAtLine(l: int, cmd: string): Action =
  ## an action that puts the cursor on line `l` and then runs the command named `cmd`, so a gutter command works on the
  ## line that was clicked
  let ll = l
  let c = cmd
  proc() =
    let b = buf()
    if ll <= b.lines.high: b.setSingle(Pos(line: ll, col: 0))
    runCmd(c)

proc gutterMenu(l: int): seq[MenuItem] =
  ## the menu for a right click in the gutter at line `l`: breakpoints and logpoints, bookmarks, folding (when folding
  ## is on), the git change on the line (show, stage, revert), copying file:line or a link to the line, who changed it,
  ## and selecting the line
  let b = buf()
  if l < 0 or l > b.lines.high: return
  result.add mi("Toggle breakpoint", "F9", ctxAtLine(l, "Debug: toggle breakpoint"))
  result.add mi("Conditional breakpoint…", "", ctxAtLine(l, "Debug: conditional breakpoint on this line…"))
  result.add mi("Logpoint…", "", ctxAtLine(l, "Debug: logpoint on this line…"))
  result.add msep()
  result.add mi("Toggle bookmark", "", ctxAtLine(l, "Bookmarks: toggle"))
  result.add mi("Bookmarks…", "", ctxAtLine(l, "Bookmarks: list…"))
  if cfgFolding:
    result.add mi("Fold or unfold here", "", ctxAtLine(l, "Toggle fold"))
    result.add mi("Fold all", "", ctxAtLine(l, "Fold all"))
    result.add mi("Unfold all", "", ctxAtLine(l, "Unfold all"))
  if l < b.git.len and b.git[l] != 0:
    result.add msep()
    result.add mi("Show this change", "", ctxAtLine(l, "Git: show this change"))
    result.add mi("Stage this change", "", ctxAtLine(l, "Git: stage this change"))
    result.add mi("Revert this change", "", ctxAtLine(l, "Git: revert this change"))
  if b.path.len > 0:
    result.add msep()
    result.add ctxCopy("Copy file:line", relPath(b.path) & ":" & $(l + 1))
    result.add mi("Copy a link to this line (git host)", "", ctxAtLine(l, "Git: copy link to this line"))
    result.add mi("Git: who changed this line", "", ctxAtLine(l, "Git: history of these lines"))
  result.add mi("Select the line", "", proc() =
    let bb = buf()
    if l <= bb.lines.high:
      let e = if l < bb.lines.high: Pos(line: l + 1, col: 0) else: Pos(line: l, col: bb.lines[l].len)
      bb.setSingle(e, Pos(line: l, col: 0)))

# ── the status bar ──

proc statusBarMenu(): seq[MenuItem] =
  ## the menu of the status bar's empty part: problems, recent messages, the command palette and toggles for the bars
  @[mc("Show problems", "Problems"), mc("Show recent messages", "Recent messages"),
    mc("Command palette"), msep(),
    mc("Toggle title bar", "Title bar", chk(cfgTitleBar)), mc("Toggle tab bar", "Tab bar", chk(cfgTabBar)),
    mc("Toggle breadcrumbs", "Breadcrumbs", chk(cfgBreadcrumbs)),
    mc("Toggle status bar", "Hide the status bar")]

proc statusPosMenu(): seq[MenuItem] =
  ## the menu of the cursor position in the status bar: go to line, copy file:line:col or the path, select all
  let b = buf()
  let p = b.primary.head
  result = @[mc("Go to line…", "Go to line…")]
  if b.path.len > 0:
    result.add ctxCopy("Copy file:line:col", relPath(b.path) & ":" & $(p.line + 1) & ":" & $(p.col + 1))
    result.add ctxCopy("Copy the path", b.path)
  result.add mc("Select all")

proc statusEolMenu(): seq[MenuItem] =
  ## the menu of the line-ending label in the status bar: LF or CRLF, the file's current one ticked
  let b = buf()
  @[mi("LF (Linux, macOS, Termux)", "", proc() = (if buf().crlf: runCmd("Toggle line endings (LF/CRLF)")), chk(not b.crlf)),
    mi("CRLF (Windows)", "", proc() = (if not buf().crlf: runCmd("Toggle line endings (LF/CRLF)")), chk(b.crlf))]

proc statusLangMenu(): seq[MenuItem] =
  ## the menu of the language label in the status bar: change the language, format the document, open that language's
  ## settings
  let b = buf()
  @[mi("Change the language…", "", proc() = cmdLanguages()),
    mc("Format document"),
    mi("Settings of " & b.lang.name & "…", "", proc() = openSettingsUi(b.lang.name.toLowerAscii))]

proc statusAiMenu(): seq[MenuItem] =
  ## the menu of the AI label in the status bar: new chat, model, provider, agent mode, inline suggestions and settings
  @[mc("AI: new chat", "New chat"), mc("AI: choose model…", "Choose the model…"),
    mc("AI: choose provider…", "Choose the provider…"), mc("AI: toggle agent mode", "Agent mode", chk(cfgAiAgent)),
    mc("AI: toggle inline suggestions", "Inline suggestions"), msep(), mc("AI: settings…", "Settings…")]

proc statusTermMenu(): seq[MenuItem] =
  ## the menu of the terminal label in the status bar: show or hide, new, split, run this file in it
  @[mc("Toggle terminal", "Show or hide the terminal"), mc("Terminal: new", "New terminal"),
    mc("Terminal: split", "Split the terminal"), mc("Run in terminal (interactive)", "Run this file in it")]

proc statusLsMenu(): seq[MenuItem] =
  ## the menu of the language-server label in the status bar: the Nim panel, for a Nim file also choosing the Nim and
  ## restarting nimsuggest, and restarting the language server
  let b = buf()
  result = @[]
  if b.lang.mode == lmNim:
    # (which Nim, and why: what decides it is the first line — then the ways to change it)
    let why = nim3Why(rootDir)
    let head =
      if nim3On(): "Nim 3 (nimony)" & (if cfgNimCompiler == "auto" and why.len > 0: ": " & tildePath(why) & " is here"
                                      else: ": this project says so (nim.compiler)")
      elif cfgNimCompiler == "nimony": "Nim 3 asked for, but nimony is not installed"
      elif cfgNimCompiler == "auto" and why.len > 0: "Nim 2: " & tildePath(why) & " is here, but nimony is not installed"
      else: "Nim " & (if tcVer.len > 0: tcVerText(tcVer) else: "2") & (if tcWhy.len > 0: " (" & tcWhy & ")" else: "") &
            (if nim2NifOn(): " — saved files read by the compiler (nim nif)" else: "")
    result.add MenuItem(label: head, check: -1, disabled: true)
    if nimonyBuilding: result.add MenuItem(label: "Building nimony… (the Run panel shows how it goes)", check: -1,
                                           disabled: true)
    if cfgNimCompiler != "nimony": result.add mc("Nim 3: this project is Nim 3 (nimony)", "Make this project Nim 3")
    if cfgNimCompiler != "nim": result.add mc("Nim 3: this project is Nim 2 (nim)", "Make this project Nim 2")
    if cfgNimCompiler != "auto": result.add mc("Nim 3: decide from the project (auto)", "Decide from the project")
    if not nimonyBuilding:
      result.add mc("Nim 3: install or update nimony", (if nimonyRoot().len > 0: "Update nimony" else: "Install nimony"))
    result.add mc("Nim: choose the Nim for this project…", "Choose the Nim…")
    result.add mc("Nim: restart nimsuggest", "Restart nimsuggest")
  result.add mc("Nim panel (project, tools, toolchain)", "The Nim panel")
  result.add mc("Restart language server")

proc statusProblemsMenu(): seq[MenuItem] =
  ## the menu of the problem count in the status bar: show, next and previous problem, all of them with their code, fix
  ## them with the assistant
  @[mc("Show problems", "Show the problems"), mc("Next problem"), mc("Previous problem"), msep(),
    mc("Problems: all of them with their code (multibuffer)", "All of them with their code"),
    mc("AI: fix problems in file", "Fix them with the assistant")]

# ── the title bar and the menu bar ──

proc titleBarMenu(): seq[MenuItem] =
  ## the menu of the title bar: command palette, open folder, toggles for the bars and the minimap, zen mode
  @[mc("Command palette"), mc("Open folder…"), msep(),
    mc("Toggle title bar", "Title bar", chk(cfgTitleBar)), mc("Toggle tab bar", "Tab bar", chk(cfgTabBar)),
    mc("Toggle breadcrumbs", "Breadcrumbs", chk(cfgBreadcrumbs)), mc("Toggle status bar", "Status bar", chk(cfgStatusBar)),
    mc("Toggle minimap", "Minimap"), msep(), mc("Toggle zen mode", "Zen mode")]

# ── docks ──

proc dockHeaderMenu(side: DockSide): seq[MenuItem] =
  ## the menu of a dock's header: its views to switch to (the one showing ticked), wider, narrower and close
  let views = if side == dsRight: @RightViews else: @LeftViews
  let cur = if side == dsRight: rightView else: sideView
  for v in views:
    var show: Action
    capture v:                       # (each item its own view: closures made in a loop share its variables)
      show = proc() = showSide(v)
    result.add mi(viewTitle(v).capitalizeAscii, "", show, chk(v == cur))
  result.add msep()
  result.add mc("View: make pane/dock wider", "Wider")
  result.add mc("View: make pane/dock narrower", "Narrower")
  result.add mi("Close the dock", "", proc() =
    if side == dsRight: rightOpen = false else: treeOpen = false
    focus = fEditor)

proc dockItemMenu(it: SideItem, v: SideView, isRight: bool): seq[MenuItem] =
  ## a dock row's menu: open it (here or beside), copy its path or its text; the outline's and the tests' own
  let p = it.path
  let l = it.line
  let item = it
  proc openIt() =
    ## opens the row's file and centres on its line and column (when it has a line)
    let b = openFile(p)
    if b != nil and l >= 0: b.centerOn(b.clampPos(Pos(line: l, col: max(0, item.col))))
  if p.len > 0 and not dirExists(p):
    result.add mi("Open", "Enter", proc() = openIt())
    result.add mi("Open to the side", "", proc() =
      toSidePane()
      openIt())
  case v
  of svOutline:
    if p.len > 0 and l >= 0:
      result.add msep()
      result.add mi("Find references", "", proc() =
        openIt()
        runCmd("Find references"))
      result.add mi("Rename…", "F2", proc() =
        openIt()
        runCmd("Rename symbol"))
  of svTests:
    if p.len > 0:
      result.add msep()
      result.add mi("Run the tests of this file", "", proc() =
        openIt()
        runCmd("Run tests in file"))
      if l >= 0:
        result.add mi("Debug this test", "", proc() =
          openIt()
          runCmd("Debug: debug the test at the cursor"))
      result.add mi("Run with coverage", "", proc() = cmdCoverageTestFile(p))
  else: discard
  if result.len > 0: result.add msep()
  if p.len > 0:
    result.add ctxCopy("Copy the path", p)
    result.add ctxCopy("Copy the relative path", relPath(p))
    result.add mi("Reveal in the file tree", "", proc() =
      showSide(svFiles)
      revealInTree(p))
  if it.text.len > 0: result.add ctxCopy("Copy the text", it.text)

# ── the bottom panel ──

proc panelHeaderMenu(): seq[MenuItem] =
  ## the menu of the bottom panel's header: its tabs (problems, output, terminal, debug), maximise or restore, close
  @[mi("Problems", "", proc() = setPanel(pkProblems), chk(panelKind == pkProblems)),
    mi("Output", "", proc() = setPanel(pkOutput), chk(panelKind == pkOutput)),
    mi("Terminal", "", proc() = runCmd("Toggle terminal"), chk(panelKind == pkTerminal)),
    mi("Debug", "", proc() = runCmd("Debug: show the debug panel"), chk(panelKind == pkDebug)),
    msep(),
    mi((if panelMax: "Restore its size" else: "Maximize"), "", proc() = (panelMax = not panelMax)),
    mi("Close the panel", "", proc() =
      panelOpen = false
      if focus == fPanel: focus = fEditor)]

proc panelLineMenu(i: int): seq[MenuItem] =
  ## the menu of line `i` of the bottom panel: go to where it points, (for an error or warning in Problems) fix it with
  ## the assistant, copy the line or the whole panel
  if i < 0 or i >= panelLines.len: return
  let pl = panelLines[i]
  if pl.path.len > 0:
    let pp = pl.path
    let ll = pl.line
    let cc = pl.col
    result.add mi("Go there", "Enter", proc() =
      let b = openFile(pp)
      if b != nil and ll >= 0: b.centerOn(b.clampPos(Pos(line: ll, col: max(0, cc)))))
    if panelKind == pkProblems and pl.sev in {1, 2}:
      result.add mi("Fix it with the assistant", "", proc() =
        let b = openFile(pp)
        if b != nil and ll >= 0:
          b.setSingle(b.clampPos(Pos(line: ll, col: max(0, cc))))
          runCmd("AI: fix problem at cursor"))
    result.add msep()
  result.add ctxCopy("Copy the line", pl.text)
  var all: seq[string]
  for x in panelLines: all.add x.text
  result.add ctxCopy("Copy all of it", all.join("\n"))

# ── the rest: breadcrumbs, the minimap, a notification, a pane's header ──

proc breadcrumbMenu(): seq[MenuItem] =
  ## the menu of the breadcrumb bar: go to symbol, the outline, copy the path (full or relative), reveal in the file
  ## tree, hide the bar; nothing for a file without a path
  let b = buf()
  if b.path.len == 0: return
  @[mc("Go to symbol…", "Go to a symbol…"), mc("Outline panel", "The outline"), msep(),
    ctxCopy("Copy the path", b.path), ctxCopy("Copy the relative path", relPath(b.path)),
    mi("Reveal in the file tree", "", proc() =
      showSide(svFiles)
      revealInTree(buf().path)), msep(),
    mc("Toggle breadcrumbs", "Hide the breadcrumbs")]

proc minimapMenu(): seq[MenuItem] =
  ## the menu of the minimap: hide it, fold all, unfold all
  @[mc("Toggle minimap", "Hide the minimap"), mc("Fold all"), mc("Unfold all")]

proc toastMenu(i: int): seq[MenuItem] =
  ## the menu of notification `i`: copy its text, dismiss it or all, show recent messages
  if i < 0 or i >= toasts.len: return
  let t = toasts[i].text
  let k = i
  @[ctxCopy("Copy the message", t),
    mi("Dismiss", "", proc() = (if k < toasts.len: toasts.delete(k))),
    mi("Dismiss all", "Esc", proc() = toasts.setLen(0)),
    mc("Show recent messages", "Recent messages")]

proc paneHeaderMenu(i: int): seq[MenuItem] =
  ## the menu of split pane `i`'s header: close it or the others, split right or down, turn its split between side by
  ## side and stacked, show it alone or all panes again, equal sizes, show its file in the other pane
  let pi = i
  let par = parentOf(paneRoot, leafOf(paneRoot, i))
  result = @[mi("Close this pane", (if i == activePane: "Alt+|" else: ""), proc() = closePane(pi)),
    mi("Close the other panes", "", proc() =
      focusPane(pi)
      closeSplit()),
    msep(),
    mi("Split right", "", proc() = discard splitPaneOf(pi, false)),
    mi("Split down", "", proc() = discard splitPaneOf(pi, true))]
  if par != nil:
    result.add mi((if par.vertical: "Turn: one above the other" else: "Turn: side by side"), "", proc() =
      par.vertical = not par.vertical
      needRender = true)
  result.add mi((if paneZoom: "Every pane again" else: "This pane alone"), "", proc() =
    focusPane(pi)
    toggleZoom())
  result.add mi("Equal sizes", "", proc() = equalizePanes())
  result.add msep()
  result.add mc("View: show file in other pane", "Show this file in the other pane")
