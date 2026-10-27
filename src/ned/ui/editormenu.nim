proc openFolder(d: string) =
  for b in bufs:
    if b.dirty and b.path.len == 0 and b.title.len == 0:
      let i = bufs.find(b)
      if i >= 0: curBuf = i
      focus = fEditor
      warn("Save (Ctrl+S) or close this untitled file before opening another folder")
      return
  if not saveAll():
    warn("Save or close the unsaved files first")
    return
  saveState()                       # remembers this folder's open files for next time
  # the previous project's tabs go; the new project's session comes back
  closeSplit()
  for b in bufs:
    rememberPos(b)
    lspDidClose(b)
    removeSwap(b)
  bufs = @[newBuffer()]
  bufs[0].welcome = true
  curBuf = 0
  if d != rootDir:
    wsRoots.setLen(0)                 # another project: the workspace's other folders go too
    wsFile = ""
  rootDir = d
  setCurrentDir(d)
  wkFolderChanged()                 # (the engine worker: a new one for this folder, when needed)
  reloadSettings(true)
  nxLibGuessed = false              # the Nim index reads the new project's paths and packages
  nxDumped.clear()
  nxWarm.clear()
  treeRoot = nil
  fileCacheValid = false
  startScan()
  flattenTree()
  readBranch()
  loadNimbleInfo(true)
  testScanned = false
  gitStatusLines.setLen(0)
  gitFileStatus.clear()
  if gitRepoRoots().len > 0: refreshGitStatus()
  nsShutdown()
  lspRestartAll()
  addRecent(d)
  restoreSession()
  showSide(svFiles)
  info("Opened " & d)

proc editorMenu(): seq[MenuItem] =
  let b = buf()
  let hasSel = b.primary.hasSel
  result = @[mc("Go to definition"), mc("Go to type definition"), mc("Peek definition"), mc("Find references"),
             mc("Peek references"),
             mc("Call hierarchy (callers and calls)", "Call hierarchy"), mc("Show hover info", "Show info"),
             mc("Rename symbol"), mc("Quick fix / code actions…", "Quick fix…"), msep(),
             mc("Cut", disabled = not hasSel), mc("Copy"), mc("Paste"), msep(),
             mc("Toggle comment"), mc("Format document")]
  if hasSel: result.add mc("Format selection (ned's own for Nim and C, or the language server)", "Format selection")
  result.add mc("Surround with…")
  if b.id in multiBufs:
    result.add msep()
    result.add msub("Multibuffer", @[mc("Multibuffer: open the file here", "Open the file here"),
      mc("Multibuffer: more lines around this piece", "More lines around this piece"),
      mc("Multibuffer: more lines above this piece", "More lines above"),
      mc("Multibuffer: more lines below this piece", "More lines below"),
      mc("Multibuffer: remove this piece", "Remove this piece"), msep(),
      mc("Multibuffer: next piece", "Next piece"), mc("Multibuffer: previous piece", "Previous piece"),
      mc("Multibuffer: refresh (each piece as its file has it now)", "Refresh")])
  elif b.path.len > 0:
    result.add mc("Multibuffer: add the selection", (if hasSel: "Add the selection to a multibuffer"
                                                       else: "Add this line to a multibuffer"))
  let ln = b.primary.head.line
  if ln < b.git.len and b.git[ln] != 0:
    result.add msep()
    result.add mc("Git: show this change", "Show this change")
    result.add mc("Git: stage this change", "Stage this change")
    if b.id in multiBufs and b.title == "Git: changes": result.add mc("Git: unstage this change", "Unstage this change")
    result.add mc("Git: revert this change", "Revert this change")
  if b.lang != nil and b.lang.id in ["c", "cpp"]:
    result.add mc("C: switch between header and source", (if splitFile(b.path).ext.toLowerAscii in
                  [".h", ".hh", ".hpp", ".hxx"]: "Go to the source (.c)" else: "Go to the header (.h)"))
  if b.lang.mode == lmNim:
    result.add msep()
    result.add msub("Refactor", @[mc("Nim: change signature…", "Change signature…"),
      mc("Nim: inline this proc", "Inline this proc"), mc("Nim: move to another module…", "Move to another module…"),
      msep(),
      mc("Nim: extract selection into a proc", "Extract into a proc", disabled = not hasSel),
      mc("Nim: add the missing case branches", "Add missing case branches"),
      mc("Nim: generate $, ==, hash and a constructor for this type", "Generate $, ==, hash, constructor"),
      mc("Nim: add a doc comment to this proc", "Add doc comment"), mc("Nim: toggle proc ⇄ func", "proc ⇄ func"),
      mc("Nim: sort imports", "Sort imports")])
    if hasSel: result.add mc("Nim: run the selection", "Run the selection")
    result.add msub("Debug", @[mc("Debug: toggle breakpoint", "Toggle breakpoint"),
      mc("Debug: conditional breakpoint on this line…", "Conditional breakpoint…"),
      mc("Debug: logpoint on this line…", "Logpoint…"), mc("Debug: stop when this changes…", "Stop when it changes…"),
      mc("Debug: run to cursor", "Run to cursor"), mc("Debug: debug the test at the cursor", "Debug this test"),
      mc("Debug: add a watch expression…", "Watch…")])
    result.add mc("Nim: expand macro/template at cursor", "Expand macro")
    result.add mc("Nim: why? (where an exception or a side effect comes from)", "Why? (exceptions, side effects)")
    result.add mc("Nim: ARC/ORC view of current proc (expandArc)", "ARC/ORC view")
    result.add mc("Nim: decompile this proc (side by side)", "Decompile this proc")
  if b.lang.mode == lmNim or b.lang.id in ["c", "cpp"]:
    result.add mc("Compiler Explorer", "Compiler Explorer (assembly, live)")
  result.add msep()
  result.add mc("AI: ask about selection", (if hasSel: "Ask AI about selection" else: "Ask AI about this file"))
  result.add mc("AI: edit selection…", "Edit with AI…")
  if cfgFolding:
    result.add msep()
    result.add mc("Fold")
    result.add mc("Unfold")

proc scrollAt(x, y, d: int) =
  if panelTopY >= 0 and y >= panelTopY and x >= lay.edX and x < lay.edX + lay.edW:
    if panelKind == pkTerminal:
      termScroll(-d)
      return
    panelScroll = max(0, panelScroll + d)
    panelFollow = false
    if focus == fPanel: panelSel = clamp(panelSel + d, 0, max(0, panelLines.high))
  elif treeOpen and x < lay.leftW:
    if sideView == svFiles:
      treeScroll = max(0, treeScroll + d)
      treeSel = clamp(treeSel + d, 0, max(0, treeRows.high))
    else:
      leftList.scroll = max(0, leftList.scroll + d)
      leftList.sel = clamp(leftList.sel + d, 0, max(0, leftList.items.high))
  elif rightOpen and x >= lay.rightX:
    if rightView == svAssistant: aiScroll(d)
    else:
      rightList.scroll = max(0, rightList.scroll + d)
      rightList.sel = clamp(rightList.sel + d, 0, max(0, rightList.items.high))
  else:
    hoverOpen = false
    if buf().hex != nil:
      let hx = buf().hex
      hx.top = clamp(hx.top + d, 0, max(0, hx.data.len div max(1, hx.perRow)))
      # (the cursor stays on the screen: it moves along when it would scroll out)
      let row = hx.cur div max(1, hx.perRow)
      if row < hx.top: hx.cur += (hx.top - row) * hx.perRow
      elif row >= hx.top + hx.rows: hx.cur -= (row - hx.top - hx.rows + 1) * hx.perRow
      hx.cur = clamp(hx.cur, 0, hx.data.len)
      needRender = true
      return
    buf().scrollBy(d)
