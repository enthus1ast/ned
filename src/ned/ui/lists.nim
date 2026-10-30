# ── lists ──

proc buildTestItems(): seq[SideItem]
proc buildItems(v: SideView): seq[SideItem] =
  ## the rows of a dock view's list, from that view's builder (nothing for the file tree and the assistant, which draw
  ## themselves; the outline is the current buffer's)
  case v
  of svFiles, svAssistant: @[]
  of svSearch: buildSearchItems()
  of svGit: buildGitItems()
  of svProject: buildProjectItems()
  of svTests: buildTestItems()
  of svOutline:
    let b = buf()
    ensureOutline(b)
    b.outline
  of svTimeline: buildTimelineItems()
  of svTodos: buildTodoItems()
  of svPlugins: buildPluginItems()

proc showSide(v: SideView) =
  ## opens the dock view `v` in the dock it belongs to, giving it the keyboard and resetting its selection; also
  ## refreshes what the view shows — the outline's selection at the cursor, the timeline, the TODO scan, git status, the
  ## file tree revealing the current file, and the search box filled with the selection or word under the cursor
  if v in RightViews:
    rightOpen = true
    rightView = v
    focus = fRight
    rightList.sel = 0
    rightList.scroll = 0
    if v == svOutline:
      let b = buf()
      ensureOutline(b)
      for i, it in b.outline:
        if it.line <= b.primary.head.line: rightList.sel = i
    if v == svTimeline: refreshTimeline()
    if v == svTodos and msSince(todoScanAt) > 5000: todoScanProject()
  else:
    treeOpen = true
    sideView = v
    focus = fTree
    leftList.sel = 0
    leftList.scroll = 0
    case v
    of svGit:
      refreshGitStatus()
      if haveExe("gh"): ciRefresh()
    of svFiles:
      flattenTree()
      if buf().path.len > 0: revealInTree(buf().path)
    of svSearch:
      if dockQuery.len == 0:
        let b = buf()
        let (a, e) = b.primary.range
        dockQuery = if a != e and a.line == e.line: b.getText(a, e) else: b.wordAt(b.primary.head)
        dockQueryCur = dockQuery.len
    else: discard
  needRender = true

proc toggleDock(side: DockSide) =
  ## a dock's toggle key: closes the dock when it has the keyboard, gives it the keyboard when it is open without, else
  ## opens it on its last view
  if side == dsLeft:
    if treeOpen and focus == fTree:
      treeOpen = false
      focus = fEditor
    elif treeOpen: focus = fTree
    else: showSide(sideView)
  else:
    if rightOpen and focus == fRight:
      rightOpen = false
      focus = fEditor
    elif rightOpen: focus = fRight
    else: showSide(rightView)
  needRender = true

proc toggleAssistant() =
  ## closes the assistant when it has the keyboard, else shows and focuses it
  if rightOpen and rightView == svAssistant and focus == fRight:
    rightOpen = false
    focus = fEditor
  else: showSide(svAssistant)

proc activateItem(dl: var DockList, v: SideView, idx: int) =
  ## uses row `idx` of a dock list (Enter or a click): selects it and runs its action, or opens its file at its line
  ## (leaving a jump to come back to for the outline, search and TODOs, and moving the keyboard to the editor on a wide
  ## screen); a staged or unstaged git file opens its diff
  if idx < 0 or idx >= dl.items.len: return
  dl.sel = idx
  let it = dl.items[idx]
  if it.action != nil:
    it.action()
  elif it.path.len > 0:
    if v in {svOutline, svSearch, svTodos}: pushJump()
    let b = openFile(it.path)
    if b != nil and it.line >= 0: b.centerOn(b.clampPos(Pos(line: it.line, col: max(0, it.col))))
    if v in {svOutline, svSearch, svTimeline, svTodos} and scrW >= 70: focus = fEditor
    if v == svGit:
      if it.data in ["staged", "unstaged"]:
        let root = gitHome()
        let rel = if it.path.startsWith(root & "/"): it.path[root.len + 1 .. ^1] else: it.path
        gitDiffView(rel, it.data == "staged")

proc gitItemMenu(it: SideItem): seq[MenuItem] =
  ## the menu of a file row in the git dock: open the file (or show a new folder in the tree), open its diff (not for
  ## untracked files), stage, unstage, and discard the changes after asking (an untracked file or folder is deleted)
  let root = gitHome()
  let p = it.path
  let rel = if p.startsWith(root & "/"): p[root.len + 1 .. ^1] else: p
  let untr = it.data in ["untracked", "untracked-dir"]
  let isDir = it.data == "untracked-dir"
  @[(if isDir: mi("Show in Files", "", proc() = revealInTree(p)) else: mi("Open file", "", proc() = discard openFile(p))),
    mi("Open diff", "d", proc() = gitOpenChangeDiff(rel, it.data == "staged"), disabled = untr),
    mi("Open diff as text", "", proc() = gitDiffView(rel, it.data == "staged"), disabled = untr),
    msep(),
    mi("Stage", "s", proc() = gitRun(@["add", "--", rel], "Staged " & rel), disabled = it.data == "staged"),
    mi("Unstage", "u", proc() = gitRun(@["restore", "--staged", "--", rel], "Unstaged " & rel),
       disabled = it.data != "staged"),
    msep(),
    mi("Discard changes…", "x", proc() =
      askConfirm("Discard changes to " & rel & (if isDir: " (delete the folder and everything in it)" elif untr: " (delete file)" else: "") &
                 "? (y/n)", proc(ch: char) =
        if ch == 'y':
          if untr:
            try:
              if isDir: removeDir(p) else: removeFile(p)
              remoteFileOp("rm", p)
              refreshGitStatus()
              info("Deleted " & rel)
            except CatchableError as e: error(e.msg)
          else: gitRun(@["restore", "--", rel], "Discarded changes to " & rel)))]

proc searchItemMenu(it: SideItem): seq[MenuItem] =
  ## the menu of a row in the search results: for a hit, open it, replace that line or all in its file (when the replace
  ## box is open) and dismiss it or its file; for a file heading, the same for the whole file
  let path = it.path
  let line = it.line
  if it.data == "hit":
    result.add mi("Open", "Enter", proc() =
      let b = openFile(path)
      if b != nil: b.centerOn(Pos(line: line, col: 0)))
    if dockShowReplace:
      result.add mi("Replace this line", "", proc() = replaceHit(path, line))
      result.add mi("Replace in this file", "", proc() = replaceInFileHits(path))
    result.add mi("Dismiss", "", proc() = dismissHit(path, line))
    result.add mi("Dismiss this file", "", proc() = dismissHit(path, -1))
  else:
    var p = ""
    for h in searchHits:
      if relPath(h.path) == it.text:
        p = h.path
        break
    if p.len == 0: return
    let pp = p
    result.add mi("Open", "", proc() = discard openFile(pp))
    if dockShowReplace: result.add mi("Replace in this file", "", proc() = replaceInFileHits(pp))
    result.add mi("Dismiss this file", "", proc() = dismissHit(pp, -1))

proc drawDockList(dl: var DockList, v: SideView, x0, y0, w, h: int, focused: bool, isRight: bool) =
  ## draws a dock's list of rows: a note when it is empty, otherwise the rows from the scroll position (the selection
  ## kept in view) as headings, or an icon, text and grey detail, with the search hits showing their matches (and the
  ## replacement beside them when replacing) and TODO rows as tag, name and message; each row is clickable (a right
  ## click opens its menu) and a line of key hints shows at the bottom for git and TODOs
  let bg0 = theme.dockBg
  if dl.items.len == 0:
    let msg = case v
      of svOutline: "No symbols in this file"
      of svGit: "Loading…"
      of svTodos:
        if todoScanBusy or todoQueue.len > 0: "Scanning…"
        elif todoTags.len == 0: "No tags — settings › todo.tags"
        else: (block:
          var ws: seq[string]
          for tg in todoTags: ws.add tg.word
          "No " & ws.join(", ") & " comments" & (if todoScopeFile: " in this file" else: ""))
      else: ""
    # (wrapped to the dock: a narrow one cut the list of tags in the middle)
    var yy = y0 + 1
    for l in wrapText(msg, max(8, w - 3)):
      discard putStr(x0 + 2, yy, l, theme.dim, bg0, {aItalic}, x0 + w)
      inc yy
    return
  var curIdx = -1
  if v == svOutline:
    let l = buf().primary.head.line
    for i, it in dl.items:
      if it.line <= l: curIdx = i
    if not focused and curIdx >= 0: dl.sel = curIdx
  let hintRows = if focused and v in {svGit, svTodos} and h > 8: 1 else: 0
  let rows = max(1, h - hintRows)
  dl.sel = clamp(dl.sel, 0, dl.items.high)
  if dl.sel < dl.scroll: dl.scroll = dl.sel
  if dl.sel >= dl.scroll + rows: dl.scroll = dl.sel - rows + 1
  dl.scroll = clamp(dl.scroll, 0, max(0, dl.items.len - rows))
  for r in 0 ..< rows:
    let i = dl.scroll + r
    if i >= dl.items.len: break
    let it = dl.items[i]
    let y = y0 + r
    let sel = i == dl.sel
    let isH = hov(x0, y, w)
    # the same in every list: selection (focused) · selection kept while another part has the focus · hover
    let bg = if sel and focused: theme.menuSel elif isH and it.role != 6: theme.hoverBg
             elif sel or i == curIdx: blend(bg0, theme.menuSel, 0.45) else: bg0
    fillRect(x0, y, w, 1, theme.fg, bg)
    if it.role == 6:
      discard putStr(x0 + 1, y, it.text, theme.dim, bg, {aBold}, x0 + w)
      continue
    var x = x0 + 1 + min(it.depth, 8) * 2
    if it.icon.len > 0:
      let icc = if v == svGit and it.icon.len == 1: roleColor(it.role)
                elif it.data == "file": theme.dim
                else: roleColor(if it.role in {7, 8, 9}: it.role else: 1)
      x = putStr(x, y, it.icon & " ", icc, bg, {}, x0 + w)
    let avail = x0 + w - 1 - x
    let tw = strWidth(it.text)
    var dw = 0
    if it.detail.len > 0:
      dw = min(strWidth(it.detail), avail - tw - 2)
      if dw < 3: dw = 0
    let maxT = x0 + w - 1 - (if dw > 0: dw + 2 else: 0)
    let fg = if v == svGit and it.data.len > 0: theme.fg
             elif it.data == "hit": theme.fg
             elif it.role in {7, 8, 9}: theme.fg       # (actions, routines, types: the icon carries the colour)
             else: roleColor(it.role)
    if it.data == "hit" and dockQueryRan.len > 0:
      # the matches inside the result line; with the replace box open, old → new inline
      let sp = findSpans(it.text, dockQueryRan, searchCaseS, searchWord, searchRx)
      if sp.len > 0:
        var last = 0
        if sp[0][0] > 16 and strWidth(it.text) > maxT - x:
          last = sp[0][0] - 10
          while last > 0 and ord(it.text[last]) in 0x80 .. 0xBF: dec last
          x = putStr(x, y, "…", theme.dim, bg, {}, maxT)
        for (a, e) in sp:
          if a < last: continue
          x = putStr(x, y, it.text[last ..< a], theme.dim, bg, {}, maxT)
          if dockShowReplace:
            x = putStr(x, y, it.text[a ..< e], theme.dim, blend(bg, theme.gitDel, 0.30), {}, maxT)
            let rep = replacementFor(it.text, dockQueryRan, dockReplace, a, e, searchCaseS, searchRx)
            x = putStr(x, y, rep, theme.fg, blend(bg, theme.gitAdd, 0.30), {aBold}, maxT)
          else:
            x = putStr(x, y, it.text[a ..< e], theme.fg, blend(bg, theme.accent, 0.35), {aBold}, maxT)
          last = e
        x = putStr(x, y, it.text[last .. ^1], theme.dim, bg, {}, maxT)
      else: x = putStr(x, y, it.text, fg, bg, {}, maxT)
    elif it.data.startsWith("todo:"):
      # TAG(name) what it says
      let parts = it.data.split(':', 2)
      let ti = (try: parseInt(parts[1]) except ValueError: -1)
      let tcol = todoColor(ti, bg)
      x = putStr(x, y, align($(it.line + 1), 3) & " ", theme.dim, bg, {}, maxT)
      x = putStr(x, y, (if ti >= 0 and ti < todoTags.len: todoTags[ti].word else: "?"), tcol, bg, {aBold}, maxT)
      if parts.len > 2 and parts[2].len > 0:
        x = putStr(x, y, "(" & parts[2] & ")", blend(tcol, theme.dim, 0.5), bg, {}, maxT)
      x = putStr(x, y, " " & truncTo(it.text, max(1, maxT - x - 1)), theme.fg, bg, {}, maxT)
    else:
      # (too long for the dock: cut with an ellipsis, not in the middle of a word with nothing to say so)
      x = putStr(x, y, truncTo(it.text, max(1, maxT - x)), fg, bg, (if i == curIdx: {aBold} else: {}), maxT)
    if dw > 0:
      let d = truncTo(it.detail, dw)
      discard putStr(x0 + w - 1 - strWidth(d), y, d, theme.dim, bg, {}, x0 + w)
    let idx = i
    let vv = v
    let rightSide = isRight
    let item = it
    capture idx, vv, rightSide, item, y:
      region(x0, y, w, 1, proc() =
        focus = (if rightSide: fRight else: fTree)
        if rightSide: activateItem(rightList, vv, idx) else: activateItem(leftList, vv, idx),
        "", (if vv == svGit and item.path.len > 0: Action(proc() = openMenu(gitItemMenu(item), mouseX, y + 1))
             elif vv == svSearch: Action(proc() = openMenu(searchItemMenu(item), mouseX, y + 1))
             elif vv == svTodos and item.path.len > 0: Action(proc() = openMenu(todoItemMenu(item), mouseX, y + 1))
             elif vv == svPlugins and item.data.startsWith("avail:"):
               Action(proc() = plugAvailableMenu(item.data["avail:".len .. ^1]))
             elif vv == svPlugins: nil
             else: Action(proc() =
               if rightSide: rightList.sel = idx else: leftList.sel = idx
               ctxOpen(dockItemMenu(item, vv, rightSide)))))
  if hintRows > 0:
    let hint = if v == svTodos: "f project/file · 1-9 filter · c copy · x done · i GitHub issue"
               else: "s stage · u unstage · d diff · x discard · c commit"
    discard putStr(x0 + 1, y0 + h - 1, truncTo(hint, w - 2), theme.dim, bg0, {aItalic}, x0 + w)
