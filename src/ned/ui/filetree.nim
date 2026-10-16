# ── file tree ──


proc treeMenu(n: TreeNode): seq[MenuItem] =
  let dir = if n == nil: rootDir elif n.isDir: n.path else: parentDir(n.path)
  let pre = if dir == rootDir: "" else: relPath(dir) & "/"
  result = @[mi("New file…", "n", proc() = openPrompt(pNewFile, "New file", pre)),
             mi("New folder…", "f", proc() = openPrompt(pNewFolder, "New folder", pre))]
  if n != nil:
    let node = n
    result.add msep()
    if not n.isDir: result.add mi("Open", "Enter", proc() = discard openFile(node.path))
    if findGitRoot(dir).len > 0: result.add mi("Add to .gitignore", "", proc() = gitIgnore(node.path))
    result.add mi("Rename…", "r", proc() =
      treeTarget = node.path
      openPrompt(pRenamePath, "Rename to", relPath(node.path)))
    result.add mi("Delete…", "d", proc() =
      askConfirm("Delete " & relPath(node.path) & (if node.isDir: " and everything in it" else: "") &
                 remoteToo(node.path) & "? (y/n)",
        proc(c: char) =
          if c == 'y':
            try:
              if node.isDir: removeDir(node.path) else: removeFile(node.path)
              remoteFileOp("rm", node.path)
              refreshTree()
              info("Deleted " & node.name)
            except CatchableError as e: error(e.msg)))
    result.add msep()
    result.add mi("Copy path", "", proc() =
      clipSet(node.path)
      info("Copied " & node.path))
    result.add mi("Copy relative path", "", proc() =
      clipSet(relPath(node.path))
      info("Copied " & relPath(node.path)))
    if not n.isDir:
      result.add mi("Open in browser", "", proc() = openInBrowser(node.path))
      result.add mi("Ask AI about this file", "", proc() = aiAskAboutFile(node.path))
    result.add mi("Search in folder…", "", proc() =
      showSide(svSearch)
      dockQuery = "")
    if n.isDir:
      result.add mi("Open as the project", "", proc() = openFolder(node.path))
      result.add mi("Format the files in this folder…", "", proc() = cmdFormatAll(node.path))
  if haveExe("git") and findGitRoot(dir).len == 0:
    let d = dir
    result.add msep()
    result.add mi("Initialize a git repository here", "", proc() = gitInitHere(d))
  result.add msep()
  result.add mi((if showHidden: "Hide" else: "Show") & " hidden files", ".", proc() =
    showHidden = not showHidden
    refreshTree())
  result.add mi("Refresh", "R", proc() = refreshTree())
  if n == nil: result.add mi("Open another folder…", "", proc() = cmdOpenFolder())
  result.add mi("Collapse all", "", proc() =
    proc coll(t: TreeNode) =
      for c in t.children:
        if c.isDir:
          c.expanded = false
          coll(c)
    if treeRoot != nil: coll(treeRoot)
    flattenTree())

proc drawTree(x0, y0, w, h: int) =
  let bg0 = theme.dockBg
  let showTags = cfgTodoHl and todoTags.len > 0
  if showTags: todoRefreshCache()
  fillRect(x0, y0, w, h, theme.fg, bg0)
  if treeRows.len == 0: flattenTree()
  # project row
  let title = " " & ic("chevD") & " " & projectName()
  discard putStr(x0, y0, title, (if focus == fTree: theme.fg else: theme.dim), bg0, {aBold}, x0 + w)
  region(x0, y0, w, 1, proc() = discard, rootDir, proc() = openMenu(treeMenu(nil), mouseX, y0 + 1))
  let rows = h - 1
  if treeSel < treeScroll: treeScroll = treeSel
  if treeSel >= treeScroll + rows: treeScroll = treeSel - rows + 1
  treeScroll = clamp(treeScroll, 0, max(0, treeRows.len - rows))
  let curPath = buf().path
  for r in 0 ..< rows:
    let i = treeScroll + r
    if i >= treeRows.len: break
    let n = treeRows[i]
    let y = y0 + 1 + r
    let sel = i == treeSel
    let isCur = n.path == curPath
    let isH = hov(x0, y, w)
    let bg = if sel and focus == fTree: theme.menuSel elif isH: theme.hoverBg
             elif sel: blend(bg0, theme.menuSel, 0.45) elif isCur: blend(bg0, theme.accent, 0.12) else: bg0
    fillRect(x0, y, w, 1, theme.fg, bg)
    # indent guides
    for d in 0 ..< n.depth:
      setCell(x0 + 2 + d * 2, y, Cell(ch: 0x2502, fg: blend(bg0, theme.fg, 0.14), bg: bg))
    var x = x0 + 1 + n.depth * 2 + 1
    let st = gitFileStatus.getOrDefault(n.path, ' ')
    let stFg = case st
      of 'M', 'R': theme.warn
      of 'A', 'U', '?': theme.gitAdd
      of 'D': theme.err
      else: NoColor
    var worst = 0
    if not n.isDir:
      for d in diagsFor(n.path):
        if worst == 0 or d.sev < worst: worst = d.sev
    if n.isDir:
      x = putStr(x, y, (if n.expanded: ic("chevD") else: ic("chevR")) & " ", theme.dim, bg, {}, x0 + w)
      let dfg = if n.path in gitDirty: blend(theme.fg, theme.warn, 0.5) else: theme.fg
      x = putStr(x, y, n.name, dfg, bg, {}, x0 + w - 2)
      if n.path in gitDirty: discard putStr(x0 + w - 2, y, "•", theme.warn, bg)
    else:
      x = putStr(x, y, fileIcon(n.path), langColor(n.path), bg, {}, x0 + w)
      x += 1
      let bi = bufIndexByPath(n.path)
      var fg = if worst == 1: theme.err elif worst == 2: theme.warn elif stFg != NoColor: stFg
               elif isCur or bi >= 0: theme.fg else: blend(theme.fg, theme.dim, 0.35)
      # tag comments in this file: ⚑3 in the colour of the most urgent one, left of the git letter
      var nameEnd = x0 + w - 3
      if showTags and w >= 18 and n.path in todoCacheByFile:
        let (tn, tb) = todoCacheByFile[n.path]
        let lab = ic("todo") & $min(tn, 99)
        let lx = x0 + w - 3 - strWidth(lab)
        discard putStr(lx, y, lab, todoColor(tb, bg), bg)
        nameEnd = lx - 1
      x = putStr(x, y, n.name, fg, bg, (if isCur: {aBold} else: {}), nameEnd)
      if bi >= 0 and bufs[bi].dirty: discard putStr(x + 1, y, ic("dirty"), theme.accent, bg, {}, min(x0 + w - 2, nameEnd + 1))
      if st != ' ':
        discard putStr(x0 + w - 2, y, (if st == '?': "U" else: $st), stFg, bg, {aBold})
      elif worst in {1, 2}:
        discard putStr(x0 + w - 2, y, $diagsFor(n.path).len, sevColor(worst), bg)
    let idx = i
    let node = n
    capture idx, node, y:
      region(x0, y, w, 1, proc() =
        focus = fTree
        treeSel = idx
        if node.isDir:
          node.expanded = not node.expanded
          flattenTree()
        else:
          discard openFile(node.path)
          if scrW < 70: treeOpen = false, node.path, proc() =
            treeSel = idx
            openMenu(treeMenu(node), mouseX, y + 1))
