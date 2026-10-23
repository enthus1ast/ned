# ── title bar ──

proc projectName(): string =
  if nimble.name.len > 0 and nimble.dir == rootDir: nimble.name
  else: extractFilename(rootDir)

proc drawTitleBar() =
  let y = lay.titleY
  if y < 0: return
  fillRect(0, y, scrW, 1, theme.titleFg, theme.titleBg)
  ctxRegion(0, y, scrW, 1, proc() = ctxOpen(titleBarMenu()))
  menuBarRanges.setLen(0)
  # right-hand buttons first so the rest knows how much room is left
  type Btn = tuple[label, tip: string, fg: Rgb, act: Action, on: bool]
  var btns: seq[Btn]
  let running = runningJob() != nil
  btns.add ((if running: ic("stop") else: ic("run")), (if running: "Stop (Alt+R runs again)" else: "Run file (Alt+R)"),
            (if running: theme.err else: theme.gitAdd),
            Action(proc() = (if runningJob() != nil: stopRun() else: runCurrent())), false)
  if scrW >= 60:
    btns.add (ic("left"), "Toggle left dock (Ctrl+B)", theme.titleFg, Action(proc() = toggleDock(dsLeft)), treeOpen)
    btns.add (ic("panel"), "Toggle bottom panel (Alt+O)", theme.titleFg, Action(proc() = togglePanel()), panelOpen)
    btns.add (ic("right"), "Toggle right dock", theme.titleFg, Action(proc() = toggleDock(dsRight)), rightOpen)
  btns.add (ic("ai"), "AI assistant (Alt+C)", theme.accent, Action(proc() = toggleAssistant()), rightOpen and rightView == svAssistant)
  btns.add (ic("gear"), "Settings", theme.titleFg, Action(proc() = openSettingsUi()), false)
  var bw = 1
  for b in btns: bw += strWidth(b.label) + 2
  var rx = scrW - bw
  for b in btns:
    let bg = if b.on: blend(theme.titleBg, theme.accent, 0.22) else: theme.titleBg
    rx = button(rx, y, " " & b.label & " ", b.act, b.tip, b.fg, bg)
  let rightEdge = scrW - bw - 1
  var x = button(0, y, " " & ic("menu") & " ", proc() = openAppMenu(), "Menu (F10)", theme.fg, theme.titleBg)
  # menu bar labels when there is room
  var menusW = 0
  for n in MenuNames: menusW += strWidth(n) + 2
  let proj = projectName()
  var branch = if gitBranch.len > 0: gitBranch else: ""
  if branch.len > 0 and wsRoots.len > 0 and gitRepo.len > 0 and gitRepo != findGitRoot(rootDir):
    branch = extractFilename(gitRepo) & ": " & branch      # a workspace: another folder's repository is the active one
  let projW = strWidth(proj) + 2 + (if branch.len > 0: strWidth(branch) + 4 else: 0)
  if cfgMenuBar and x + menusW + projW + 34 < rightEdge:
    for i, n in MenuNames:
      let x0 = x
      let isOpen = menus.len > 0 and menus[0].bar == i
      let idx = i
      let lab = " " & n & " "
      capture idx:
        x = button(x, y, lab, proc() = openMenuBar(idx), "", theme.titleFg,
                   (if isOpen: theme.menuSel else: theme.titleBg))
      menuBarRanges.add (x0, x, i)
    x += 1
  # project · branch
  if x + 8 < rightEdge:
    x = button(x, y, " " & truncTo(proj, max(4, rightEdge - x - 4)) & " ", proc() = runCmd("Open folder…"),
               "Project: " & rootDir, theme.fg, theme.titleBg, {aBold})
    let ab = (if gitAhead > 0: " ↑" & $gitAhead else: "") & (if gitBehind > 0: " ↓" & $gitBehind else: "")
    if branch.len > 0 and x + strWidth(branch) + strWidth(ab) + 4 < rightEdge:
      x = button(x, y, ic("branch") & " " & branch & ab & " ", proc() = cmdBranches(),
                 "Branch — switch, create, merge…", theme.dim, theme.titleBg, rightAct = proc() =
                   ctxOpen(@[mc("Git: branches…", "Branches…"), mc("Git: pull"), mc("Git: push"),
                             mc("Git: sync (pull, then push)", "Sync (pull, then push)"), mc("Git: fetch"), msep(),
                             mc("Git: stash…", "Stash…"), mc("Git: history…", "History…"), mc("Git panel")]))
      if ab.len > 0 and x + 4 < rightEdge:
        x = button(x, y, "⟳ ", proc() = gitSync(), "Sync: pull, then push", theme.accent, theme.titleBg)
  # search box, centred in the space that is left
  let space = rightEdge - x - 2
  if space >= 18:
    let sw = min(space, 54)
    var sx = (scrW - sw) div 2
    if sx < x + 1: sx = x + 1
    if sx + sw > rightEdge: sx = rightEdge - sw
    let isH = hov(sx, y, sw)
    let bg = blend(theme.titleBg, theme.fg, (if isH: 0.16 else: 0.09))
    fillRect(sx, y, sw, 1, theme.dim, bg)
    if sx - 1 > x and sx + sw < rightEdge:
      # rounded-looking ends
      setCell(sx - 1, y, Cell(ch: 0x2590, fg: bg, bg: theme.titleBg))
      setCell(sx + sw, y, Cell(ch: 0x258C, fg: bg, bg: theme.titleBg))
    let keyW = if sw >= 30: 8 else: 1                    # "Ctrl+P " and a gap before it
    var txt = " " & ic("search") & "  Search files, or > for commands"
    if strWidth(txt) + keyW > sw: txt = " " & ic("search") & " Search files"
    discard putStr(sx, y, txt, theme.dim, bg, {}, sx + sw - keyW)
    if sw >= 30: discard putStr(sx + sw - 7, y, "Ctrl+P", blend(theme.dim, bg, 0.3), bg)
    region(sx, y, sw, 1, proc() = cmdFindFile(), "Go to file · > for commands · @ for symbols · : for a line")
