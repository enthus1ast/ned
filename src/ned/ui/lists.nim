# ── lists ──

proc buildTestItems(): seq[SideItem]
proc buildItems(v: SideView): seq[SideItem] =
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

proc showSide(v: SideView) =
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
  if rightOpen and rightView == svAssistant and focus == fRight:
    rightOpen = false
    focus = fEditor
  else: showSide(svAssistant)

proc activateItem(dl: var DockList, v: SideView, idx: int) =
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
  let root = gitHome()
  let p = it.path
  let rel = if p.startsWith(root & "/"): p[root.len + 1 .. ^1] else: p
  let untr = it.data == "untracked"
  @[mi("Open file", "", proc() = discard openFile(p)),
    mi("Open diff", "d", proc() = gitOpenChangeDiff(rel, it.data == "staged"), disabled = untr),
    mi("Open diff as text", "", proc() = gitDiffView(rel, it.data == "staged"), disabled = untr),
    msep(),
    mi("Stage", "s", proc() = gitRun(@["add", "--", rel], "Staged " & rel), disabled = it.data == "staged"),
    mi("Unstage", "u", proc() = gitRun(@["restore", "--staged", "--", rel], "Unstaged " & rel),
       disabled = it.data != "staged"),
    msep(),
    mi("Discard changes…", "x", proc() =
      askConfirm("Discard changes to " & rel & (if untr: " (delete file)" else: "") & "? (y/n)", proc(ch: char) =
        if ch == 'y':
          if untr:
            try:
              removeFile(p)
              remoteFileOp("rm", p)
              refreshGitStatus()
              info("Deleted " & rel)
            except CatchableError as e: error(e.msg)
          else: gitRun(@["restore", "--", rel], "Discarded changes to " & rel)))]

proc searchItemMenu(it: SideItem): seq[MenuItem] =
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
    discard putStr(x0 + 2, y0 + 1, msg, theme.dim, bg0, {aItalic}, x0 + w)
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
      x = putStr(x, y, " " & it.text, theme.fg, bg, {}, maxT)
    else:
      x = putStr(x, y, it.text, fg, bg, (if i == curIdx: {aBold} else: {}), maxT)
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
             else: nil))
  if hintRows > 0:
    let hint = if v == svTodos: "f project/file · 1-9 filter · c copy · x done · i GitHub issue"
               else: "s stage · u unstage · d diff · x discard · c commit"
    discard putStr(x0 + 1, y0 + h - 1, truncTo(hint, w - 2), theme.dim, bg0, {aItalic}, x0 + w)
