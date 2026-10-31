# ── dock frame ──

proc toggleReplaceRow() =
  ## shows or hides the replace box of the search view and moves the keyboard to the search view (the replace box when
  ## it was just shown)
  dockShowReplace = not dockShowReplace
  dockField = if dockShowReplace: 1 elif dockField == 1: 0 else: dockField
  focus = fTree
  sideView = svSearch

proc showIncludeRow() =
  ## shows the "files" filter box of the search view, with the keyboard in it
  dockShowInclude = true
  dockField = 2
  focus = fTree
  sideView = svSearch

proc clearIncludeRow() =
  ## hides and empties the files filter of the search view, and searches again if a search had run
  dockShowInclude = false
  dockInclude = ""
  dockIncludeCur = 0
  if dockField == 2: dockField = 0
  if dockQueryRan.len > 0: projectSearch(dockQuery)

proc dockActions(v: SideView): seq[(string, string, Action)] =
  ## the buttons at the right of a dock's header for a view: (icon, tooltip, action) — new file and refresh for the
  ## files, commit for git, replace for search, run tests, add or install a plugin, and so on
  case v
  of svFiles: @[(ic("plus"), "New file", Action(proc() = openMenu(treeMenu(nil), mouseX, mouseY + 1))),
                ("⟳", "Refresh", Action(proc() = refreshTree()))]
  of svGit: @[(ic("ok"), "Commit", Action(proc() = openPrompt(pGitCommit, "Commit message", ""))),
              ("⟳", "Refresh", Action(proc() = refreshGitStatus()))]
  of svSearch: @[("⇄", "Replace in files (Alt+H)", Action(proc() = toggleReplaceRow())),
                 ("⟳", "Search again", Action(proc() = projectSearch(dockQuery)))]
  of svTests: @[(ic("run"), "Run all tests", Action(proc() = runCmd("Run all tests"))),
                ("◑", "Run all tests with coverage (c: the selected test's file)",
                 Action(proc() = runCmd("Test coverage: run and colour the lines that ran"))),
                ("⟳", "Rescan tests", Action(proc() = rescanTests()))]
  of svProject: @[("⟳", "Refresh tools", Action(proc() =
                    resetExeCache()
                    loadNimbleInfo(true)
                    probeTools()))]
  of svAssistant: @[(ic("plus"), "New chat", Action(proc() = runCmd("AI: new chat"))),
                    (ic("more"), "Assistant options",
                     Action(proc() = openMenu(menuItems(MenuNames.find("AI")), mouseX - 30, mouseY + 1)))]
  of svOutline: @[("⟳", "Refresh", Action(proc() = (buf().outlineAt = -1)))]
  of svTodos: @[("⎘", "Copy the list as Markdown (c)", Action(proc() = todoCopyMarkdown())),
                ("⟳", "Rescan the project (r)", Action(proc() = todoScanProject()))]
  of svPlugins: @[(ic("plus"), "Add: ned's own plugins, an example, from git, a new one…", Action(proc() =
                    openMenu(@[mc("Plugins: available plugins (ned's own)…", "Available plugins (ned's own)…"),
                               mc("Plugins: add an example…", "An example…"), mc("Plugins: install from git…", "From git…"),
                               mc("Plugins: browse the plugin list…", "From the plugin list…"),
                               mc("Plugins: new plugin…", "A new plugin…")], mouseX, mouseY + 1))),
                  ("⇣", "Install a plugin from git…", Action(proc() =
                    openPrompt(pPluginInstall, "Plugin repository (https://…)", ""))),
                  ("ⓘ", "The plugin API (nedplugin.nim)", Action(proc() = runCmd("Plugins: the API (nedplugin.nim)"))),
                  ("⟳", "Reload the plugins", Action(proc() = plugReload()))]
  of svTimeline: @[("⟳", "Refresh", Action(proc() =
                     timelinePath = ""
                     refreshTimeline()))]

proc drawTodoHeader(x0, y0, w: int): int =
  ## the TODOs dock's top: a chip per tag with its count (tap to hide or show it) · project or this file
  let bg0 = theme.dockBg
  discard buildTodoItems()                  # the counts come with the (cached) list
  let counts = todoDockCounts
  var y = y0
  var x = x0 + 1
  fillRect(x0, y, w, 1, theme.fg, bg0)
  let order = todoChipOrder(counts)
  for n, i in order:
    let word = todoTags[i].word
    let label = " " & word & " " & $counts[i] & " "
    if x + strWidth(label) > x0 + w - 1 and x > x0 + 1:
      inc y
      x = x0 + 1
      fillRect(x0, y, w, 1, theme.fg, bg0)
    let off = word in todoOff
    let col = todoColor(i, bg0)
    capture word:
      x = button(x, y, label, proc() =
        if word in todoOff: todoOff.excl word else: todoOff.incl word
        needRender = true, (if off: "Show " else: "Hide ") & word & (if n < 9: " (" & $(n + 1) & ")" else: ""),
        (if off: theme.dim else: col), (if off: bg0 else: blend(bg0, col, 0.20)), (if off: {} else: {aBold})) + 1
  if order.len == 0 and (todoScanBusy or todoQueue.len > 0):
    discard putStr(x0 + 2, y, "Scanning…", theme.dim, bg0, {aItalic}, x0 + w)
  inc y
  fillRect(x0, y, w, 1, theme.fg, bg0)
  var sx = x0 + 1
  sx = button(sx, y, (if todoScopeFile: "○" else: "◉") & " Project ", proc() = (todoScopeFile = false),
              "Every file in the project (f)", (if todoScopeFile: theme.dim else: theme.fg), bg0)
  sx = button(sx, y, (if todoScopeFile: "◉" else: "○") & " This file ", proc() = (todoScopeFile = true),
              "Only the file you are editing (f)", (if todoScopeFile: theme.fg else: theme.dim), bg0)
  let sum = $todoDockVis & (if todoScopeFile: "" else: " in " & $todoDockFiles & (if todoDockFiles == 1: " file" else: " files"))
  if sx + strWidth(sum) + 2 < x0 + w: discard putStr(x0 + w - strWidth(sum) - 1, y, sum, theme.dim, bg0)
  y + 1 - y0

proc drawAssistant(x0, y0, w, h: int)
proc drawSearchInput(x0, y0, w: int): int

proc drawDock(side: DockSide, x0, y0, w, h: int) =
  ## draws a side dock: a header row with an icon button for each of the side's views (the git one with its changed-file
  ## count), the shown view's title and its action buttons and a close button, tinted when the dock has the keyboard;
  ## below it the view itself (file tree, assistant, TODOs or search with their own top rows, else the list of items).
  ## Right-clicking the dock opens its menu
  let isRight = side == dsRight
  let v = if isRight: rightView else: sideView
  let focused = focus == (if isRight: fRight else: fTree)
  fillRect(x0, y0, w, h, theme.fg, theme.dockBg)
  # header: view icons · title · actions — tinted with the accent while the dock has the keyboard
  let hb = if focused: blend(theme.dockHeadBg, theme.accent, 0.14) else: theme.dockHeadBg
  fillRect(x0, y0, w, 1, theme.dim, hb)
  ctxRegion(x0, y0, w, h, proc() = ctxOpen(dockHeaderMenu(side)))     # (its header, and where its rows end)
  var x = x0 + 1
  let views = if isRight: @RightViews else: @LeftViews
  var ranges: seq[(int, int, SideView)]
  for vv in views:
    var label = " " & viewIcon(vv)
    if vv == svGit:
      var n = 0
      for k, c in gitFileStatus: inc n
      if n > 0: label.add $min(n, 99)
    label.add " "
    let active = vv == v
    let fg = if active: theme.accent else: theme.dim
    let bg = if active: blend(hb, theme.accent, 0.16) else: hb
    let x1 = x
    let target = vv
    capture target:
      x = button(x, y0, label, proc() = showSide(target), viewTitle(target).capitalizeAscii, fg, bg,
                 (if active: {aBold} else: {}))
    ranges.add (x1, x, vv)
  if isRight: rightTabRanges = ranges else: leftTabRanges = ranges
  # actions on the right
  let acts = dockActions(v)
  var aw = 3
  for (l, _, _) in acts: aw += strWidth(l) + 2
  var ax = x0 + w - aw
  let titleW = ax - x - 2
  if titleW >= strWidth(viewTitle(v)):
    discard putStr(ax - strWidth(viewTitle(v)) - 1, y0, viewTitle(v), (if focused: theme.accent else: theme.dim),
                   hb, {aBold})
  if ax > x:
    for (l, tip, a) in acts:
      ax = button(ax, y0, " " & l & " ", a, tip, theme.dim, hb)
    discard button(ax, y0, " " & ic("close") & " ", proc() =
      if isRight: rightOpen = false else: treeOpen = false
      focus = fEditor, "Close", theme.dim, hb)
  let cy = y0 + 1
  let ch = h - 1
  case v
  of svFiles: drawTree(x0, cy, w, ch)
  of svAssistant: drawAssistant(x0, cy, w, ch)
  of svTodos:
    let used = drawTodoHeader(x0, cy, w)
    if isRight:
      rightList.items = buildItems(v)
      drawDockList(rightList, v, x0, cy + used, w, ch - used, focused, true)
    else:
      leftList.items = buildItems(v)
      drawDockList(leftList, v, x0, cy + used, w, ch - used, focused, false)
  of svSearch:
    let used = drawSearchInput(x0, cy, w)
    leftList.items = buildItems(v)
    drawDockList(leftList, v, x0, cy + used, w, ch - used, focused, false)
  else:
    if isRight:
      rightList.items = buildItems(v)
      drawDockList(rightList, v, x0, cy, w, ch, focused, true)
    else:
      leftList.items = buildItems(v)
      drawDockList(leftList, v, x0, cy, w, ch, focused, false)

proc drawSearchInput(x0, y0, w: int): int =
  ## search box (+ replace box, + files filter) at the top of the search view; returns rows used
  let focused = focus == fTree and sideView == svSearch
  let bg = theme.inputBg
  proc field(y, idx: int, text: var string, cur: var int, placeholder, icon: string, rightW: int) =
    ## draws one text box of the search view on row `y` (`idx`: 0 search, 1 replace, 2 files filter): its icon and a
    ## field that takes the cursor when clicked; the screen cursor goes in it when it is the active one
    let active = focused and dockField == idx
    fillRect(x0 + 1, y, w - 2, 1, theme.fg, bg)
    discard putStr(x0 + 2, y, icon, (if active: theme.accent else: theme.dim), bg)
    let fx = x0 + 4
    let fw = max(3, w - 5 - rightW)
    let k = idx
    let onFocus = proc() =
      focus = fTree
      sideView = svSearch
      dockField = k
    region(x0 + 1, y, 3, 1, onFocus)
    let cx = drawField(fx, y, fw, text, cur, active, theme.fg, bg, placeholder, onFocus = onFocus)
    if active:
      cursorX = cx
      cursorY = y
  var y = y0
  # the chevron opens the replace row, like VS Code
  discard button(x0, y, (if dockShowReplace: ic("chevD") else: ic("chevR")), proc() = toggleReplaceRow(),
                 "Toggle replace (Alt+H)", theme.dim, theme.dockBg)
  field(y, 0, dockQuery, dockQueryCur, "Search", ic("search"), 10)
  var bx = x0 + w - 10
  bx = button(bx, y, "Aa", proc() =
    findCase = not findCase
    if dockQueryRan.len > 0: projectSearch(dockQuery), "Match case (Alt+C)",
    (if findCase: theme.accent else: theme.dim), bg, (if findCase: {aBold, aUnder} else: {})) + 1
  bx = button(bx, y, "W", proc() =
    findWord = not findWord
    if dockQueryRan.len > 0: projectSearch(dockQuery), "Whole word (Alt+W)",
    (if findWord: theme.accent else: theme.dim), bg, (if findWord: {aBold, aUnder} else: {})) + 1
  discard button(bx, y, ".*", proc() =
    findRegex = not findRegex
    if dockQueryRan.len > 0: projectSearch(dockQuery), "Regular expression (Alt+R)",
    (if findRegex: theme.accent else: theme.dim), bg, (if findRegex: {aBold, aUnder} else: {}))
  inc y
  if dockShowReplace:
    field(y, 1, dockReplace, dockReplaceCur, (if findRegex: "Replace ($1 = group 1)" else: "Replace"), "⇄", 6)
    discard button(x0 + w - 6, y, " All ", proc() = projectReplaceAll(), "Replace all (Alt+Enter)",
                   theme.badgeFg, theme.accent)
    inc y
  if dockShowInclude:
    field(y, 2, dockInclude, dockIncludeCur, "files: *.nim, src/, !tests/", "▤", 2)
    discard button(x0 + w - 3, y, ic("close"), proc() = clearIncludeRow(), "Clear the files filter", theme.dim, bg)
    inc y
  var info = ""
  if dockQueryRan.len > 0:
    info = $searchCount & (if searchCount >= cfgSearchMax: "+" else: "") &
           (if w >= 34: " results in " else: " in ") & $searchFiles & " files" &
           (if searchDone: "" else: " · searching…")
  fillRect(x0, y, w, 1, theme.dim, theme.dockBg)
  discard putStr(x0 + 2, y, truncTo(info, max(1, w - 10)), theme.dim, theme.dockBg, {}, x0 + w - 8)
  if not dockShowInclude:
    discard button(x0 + w - 7, y, "files…", proc() = showIncludeRow(), "Only search some files (globs)",
                   theme.dim, theme.dockBg)
  y + 1 - y0

proc dockListKey(dl: var DockList, v: SideView, k: Key) =
  ## the keys of a dock's list: arrows, Page Up/Down, Home and End move the selection, Enter or Right opens the row, Esc
  ## and q give the keyboard back to the editor (and close a dock on a narrow screen), r refreshes the view; and per
  ## view single-letter commands — TODOs (f scope, c copy, x done, i issue, 1–9 hide a tag), tests (c coverage), git (s
  ## stage, u unstage, d diff, x menu action, a stage all, c commit, P push, L pull, l log)
  let n = dl.items.len
  let rows = max(1, scrH - 6)
  proc moveSel(dl: var DockList, d: int) =
    ## moves the selection `d` rows, clamped to the list, stepping over a heading row (role 6) where it can — not one
    ## that does something (a part's title in the Nim panel folds it)
    let n = dl.items.len
    if n == 0: return
    var s = clamp(dl.sel + d, 0, n - 1)
    var steps = 0
    while dl.items[s].role == 6 and dl.items[s].action == nil and n > 1 and steps < 3:
      let s2 = clamp(s + (if d >= 0: 1 else: -1), 0, n - 1)
      if s2 == s: break
      s = s2
      inc steps
    dl.sel = s
  let it = if dl.sel >= 0 and dl.sel < n: dl.items[dl.sel] else: SideItem(line: -1)
  case k.kind
  of kUp: dl.moveSel(-1)
  of kDown: dl.moveSel(1)
  of kPgUp: dl.moveSel(-rows)
  of kPgDn: dl.moveSel(rows)
  of kHome: dl.sel = 0
  of kEnd: dl.sel = max(0, n - 1)
  of kEsc:
    focus = fEditor
    if scrW < 70:
      if v in RightViews: rightOpen = false else: treeOpen = false
  of kEnter, kRight: activateItem(dl, v, dl.sel)
  of kChar:
    if k.mods != {}: return
    let c = char(min(k.ch, 127))
    case c
    of 'j': dl.moveSel(1)
    of 'k': dl.moveSel(-1)
    of 'r', 'R':
      case v
      of svGit: refreshGitStatus()
      of svProject:
        resetExeCache()
        loadNimbleInfo(true)
      of svOutline: buf().outlineAt = -1
      of svTimeline:
        timelinePath = ""
        refreshTimeline()
      of svTests: rescanTests()
      of svTodos: todoScanProject()
      else: discard
      info("Refreshed")
    of 'q':
      if v in RightViews: rightOpen = false else: treeOpen = false
      focus = fEditor
    else:
      if v == svTodos:
        case c
        of 'f': todoScopeFile = not todoScopeFile
        of 'c': todoCopyMarkdown()
        of 'x':
          if it.path.len > 0 and it.line >= 0 and it.data.startsWith("todo:"):
            let menu = todoItemMenu(it)
            for m in menu:
              if m.label == "Done: delete the comment": m.act()
        of 'i':
          if it.path.len > 0 and it.line >= 0 and it.data.startsWith("todo:"):
            let menu = todoItemMenu(it)
            for m in menu:
              if m.label == "Create a GitHub issue…": m.act()
        of '1'..'9':
          let order = todoChipOrder(todoCounts(todoCollect(todoScopeFile)))
          let n = ord(c) - ord('1')
          if n < order.len:
            let word = todoTags[order[n]].word
            if word in todoOff: todoOff.excl word else: todoOff.incl word
        else: discard
        needRender = true
        return
      if v == svTests and c == 'c':           # the selected test's file, with coverage
        if it.path.len > 0: cmdCoverageTestFile(it.path)
        else: runCmd("Test coverage: run and colour the lines that ran")
        return
      if v == svGit and it.path.len > 0 or (v == svGit and c in {'a', 'c', 'P', 'L', 'l'}):
        let root = gitHome()
        let rel = if it.path.startsWith(root & "/"): it.path[root.len + 1 .. ^1] else: it.path
        case c
        of 's':
          if it.path.len > 0: gitRun(@["add", "--", rel], "Staged " & rel)
        of 'u':
          if it.path.len > 0: gitRun(@["restore", "--staged", "--", rel], "Unstaged " & rel)
        of 'd':
          if it.path.len > 0 and it.data != "untracked-dir": gitDiffView(rel, it.data == "staged")
        of 'x':
          if it.path.len > 0:
            let items = gitItemMenu(it)
            items[^1].act()
        of 'a': gitRun(@["add", "-A"], "Staged all changes")
        of 'c': gitCommitBox(false)              # (as its Commit… row says; the ✓ button: a one-line message)
        of 'P': gitNet("push", "Pushed")         # as the dock's Push and Pull: a login asked in the terminal,
        of 'L': gitNet("pull", "Pulled")         # and a remote folder's files follow a pull
        of 'l':
          toolOutput("git log", "git --no-pager log --oneline --graph --decorate -n 200", root,
                     proc(o: string): string = o, langByName("Text"))
        else: discard
  else: discard

proc treeKey(k: Key)
proc assistantKey(k: Key)

proc searchViewKey(k: Key) =
  ## the keys of the search view: Enter runs the search (or opens the selected hit when it has run), Alt+Enter or
  ## Ctrl+Enter replaces all, arrows move in the results, Tab moves between the boxes, Esc leaves; Alt+C, W, R and H
  ## toggle case, whole word, regex and the replace box; other keys edit the box that has the focus
  case k.kind
  of kEnter:
    if mAlt in k.mods or mCtrl in k.mods:
      if dockShowReplace: projectReplaceAll()
      else:
        dockShowReplace = true
        dockField = 1
      return
    if dockQuery != dockQueryRan or searchHits.len == 0 or dockInclude.strip != searchIncludeRan:
      if dockQuery.len > 0: projectSearch(dockQuery)
    else: activateItem(leftList, svSearch, leftList.sel)
  of kUp, kDown, kPgUp, kPgDn: dockListKey(leftList, svSearch, k)
  of kEsc:
    focus = fEditor
    if scrW < 70: treeOpen = false
  of kTab:
    var fields = @[0]
    if dockShowReplace: fields.add 1
    if dockShowInclude: fields.add 2
    let i = max(0, fields.find(dockField))
    dockField = fields[(i + (if mShift in k.mods: fields.len - 1 else: 1)) mod fields.len]
  else:
    if k.kind == kChar and mAlt in k.mods:
      case char(min(k.ch, 127))
      of 'c': findCase = not findCase
      of 'w': findWord = not findWord
      of 'r', 'x': findRegex = not findRegex
      of 'h':
        toggleReplaceRow()
        return
      else: return
      if dockQueryRan.len > 0: projectSearch(dockQuery)
      return
    case dockField
    of 1: discard editLine(dockReplace, dockReplaceCur, k)
    of 2: discard editLine(dockInclude, dockIncludeCur, k)
    else: discard editLine(dockQuery, dockQueryCur, k)

proc sideKey(k: Key) =
  ## the keys of the left dock: Tab and Shift+Tab switch between its views (unless a text box of the search needs the
  ## Tab), anything else goes to the view shown — the tree, the search, or a list
  if k.kind == kTab and mCtrl notin k.mods and not (sideView == svSearch and (dockShowReplace or dockShowInclude)):
    let d = if mShift in k.mods: -1 else: 1
    let i = LeftViews.find(sideView)
    showSide(LeftViews[(i + d + LeftViews.len) mod LeftViews.len])
    return
  case sideView
  of svFiles: treeKey(k)
  of svSearch: searchViewKey(k)
  else: dockListKey(leftList, sideView, k)

proc rightKey(k: Key) =
  ## the keys of the right dock: the assistant takes its own, Tab and Shift+Tab switch between the right views, anything
  ## else moves in the list
  if rightView == svAssistant:
    assistantKey(k)
    return
  if k.kind == kTab and mCtrl notin k.mods:
    let d = if mShift in k.mods: -1 else: 1
    let i = RightViews.find(rightView)
    showSide(RightViews[(i + d + RightViews.len) mod RightViews.len])
    return
  dockListKey(rightList, rightView, k)
