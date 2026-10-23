# ── context menus: what a right click (or a long press) offers, wherever it lands — a text field, the gutter, the
#    status bar and each of its parts, the title bar, a dock's header and its rows, the bottom panel, the
#    breadcrumbs, the minimap, a notification, a split pane's header ──

proc ctxOpen(items: seq[MenuItem]) =
  if items.len > 0: openMenu(items, mouseX, mouseY + 1)

proc ctxCopy(label, text: string): MenuItem =
  let t = text
  mi(label, "", proc() =
    clipSet(t)
    info("Copied " & truncTo(t, 60)))

# ── a text field: as any text box ──

proc fieldMenu(tp: ptr string, cp: ptr int): seq[MenuItem] =
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
  let ll = l
  let c = cmd
  proc() =
    let b = buf()
    if ll <= b.lines.high: b.setSingle(Pos(line: ll, col: 0))
    runCmd(c)

proc gutterMenu(l: int): seq[MenuItem] =
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
  @[mc("Show problems", "Problems"), mc("Show recent messages", "Recent messages"),
    mc("Command palette"), msep(),
    mc("Toggle title bar", "Title bar", chk(cfgTitleBar)), mc("Toggle tab bar", "Tab bar", chk(cfgTabBar)),
    mc("Toggle breadcrumbs", "Breadcrumbs", chk(cfgBreadcrumbs)),
    mc("Toggle status bar", "Hide the status bar")]

proc statusPosMenu(): seq[MenuItem] =
  let b = buf()
  let p = b.primary.head
  result = @[mc("Go to line…", "Go to line…")]
  if b.path.len > 0:
    result.add ctxCopy("Copy file:line:col", relPath(b.path) & ":" & $(p.line + 1) & ":" & $(p.col + 1))
    result.add ctxCopy("Copy the path", b.path)
  result.add mc("Select all")

proc statusEolMenu(): seq[MenuItem] =
  let b = buf()
  @[mi("LF (Linux, macOS, Termux)", "", proc() = (if buf().crlf: runCmd("Toggle line endings (LF/CRLF)")), chk(not b.crlf)),
    mi("CRLF (Windows)", "", proc() = (if not buf().crlf: runCmd("Toggle line endings (LF/CRLF)")), chk(b.crlf))]

proc statusLangMenu(): seq[MenuItem] =
  let b = buf()
  @[mi("Change the language…", "", proc() = cmdLanguages()),
    mc("Format document"),
    mi("Settings of " & b.lang.name & "…", "", proc() = openSettingsUi(b.lang.name.toLowerAscii))]

proc statusAiMenu(): seq[MenuItem] =
  @[mc("AI: new chat", "New chat"), mc("AI: choose model…", "Choose the model…"),
    mc("AI: choose provider…", "Choose the provider…"), mc("AI: toggle agent mode", "Agent mode", chk(cfgAiAgent)),
    mc("AI: toggle inline suggestions", "Inline suggestions"), msep(), mc("AI: settings…", "Settings…")]

proc statusTermMenu(): seq[MenuItem] =
  @[mc("Toggle terminal", "Show or hide the terminal"), mc("Terminal: new", "New terminal"),
    mc("Terminal: split", "Split the terminal"), mc("Run in terminal (interactive)", "Run this file in it")]

proc statusLsMenu(): seq[MenuItem] =
  let b = buf()
  result = @[mc("Nim panel (project, tools, toolchain)", "The Nim panel")]
  if b.lang.mode == lmNim:
    result.add mc("Nim: choose the Nim for this project…", "Choose the Nim…")
    result.add mc("Nim: restart nimsuggest", "Restart nimsuggest")
  result.add mc("Restart language server")

proc statusProblemsMenu(): seq[MenuItem] =
  @[mc("Show problems", "Show the problems"), mc("Next problem"), mc("Previous problem"), msep(),
    mc("Problems: all of them with their code (multibuffer)", "All of them with their code"),
    mc("AI: fix problems in file", "Fix them with the assistant")]

# ── the title bar and the menu bar ──

proc titleBarMenu(): seq[MenuItem] =
  @[mc("Command palette"), mc("Open folder…"), msep(),
    mc("Toggle title bar", "Title bar", chk(cfgTitleBar)), mc("Toggle tab bar", "Tab bar", chk(cfgTabBar)),
    mc("Toggle breadcrumbs", "Breadcrumbs", chk(cfgBreadcrumbs)), mc("Toggle status bar", "Status bar", chk(cfgStatusBar)),
    mc("Toggle minimap", "Minimap"), msep(), mc("Toggle zen mode", "Zen mode")]

# ── docks ──

proc dockHeaderMenu(side: DockSide): seq[MenuItem] =
  let views = if side == dsRight: @RightViews else: @LeftViews
  let cur = if side == dsRight: rightView else: sideView
  for v in views:
    let vv = v
    result.add mi(viewTitle(v).capitalizeAscii, "", proc() = showSide(vv), chk(v == cur))
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
  let b = buf()
  if b.path.len == 0: return
  @[mc("Go to symbol…", "Go to a symbol…"), mc("Outline panel", "The outline"), msep(),
    ctxCopy("Copy the path", b.path), ctxCopy("Copy the relative path", relPath(b.path)),
    mi("Reveal in the file tree", "", proc() =
      showSide(svFiles)
      revealInTree(buf().path)), msep(),
    mc("Toggle breadcrumbs", "Hide the breadcrumbs")]

proc minimapMenu(): seq[MenuItem] =
  @[mc("Toggle minimap", "Hide the minimap"), mc("Fold all"), mc("Unfold all")]

proc toastMenu(i: int): seq[MenuItem] =
  if i < 0 or i >= toasts.len: return
  let t = toasts[i].text
  let k = i
  @[ctxCopy("Copy the message", t),
    mi("Dismiss", "", proc() = (if k < toasts.len: toasts.delete(k))),
    mi("Dismiss all", "Esc", proc() = toasts.setLen(0)),
    mc("Show recent messages", "Recent messages")]

proc paneHeaderMenu(i: int): seq[MenuItem] =
  let pi = i
  @[mi("Close this pane", "", proc() =
      if pi == activePane: focusPane(1 - pi)
      closeSplit()),
    mi((if splitDown: "Side by side" else: "One above the other"), "", proc() =
      splitDown = not splitDown
      needRender = true),
    mc("View: show file in other pane", "Show this file in the other pane")]
