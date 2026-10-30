# ── gutter clicks: fold markers and run buttons ──

proc gutterClick(x: int, p: Pos): bool =
  ## a click at screen column `x` in the editor's gutter on the line of position `p`: the first column runs the line's
  ## code lens (▶ run) or toggles a breakpoint in a Nim file, the last folds or unfolds, the git mark opens the actions
  ## for that change, and the line numbers select the line; false when the click is not in the gutter
  let b = buf()
  let (ex, _, _, _) = editorRect
  if x >= ex + gutterW or b.isWelcome(): return false
  if x == ex:
    let (lbl, a) = b.lensAt(p.line)
    if lbl.len > 0 and a != nil:
      a()
      return true
    # the leftmost gutter column: a breakpoint
    if b.lang.mode == lmNim and b.path.len > 0:
      b.setSingle(Pos(line: p.line, col: 0))
      toggleBreakpoint()
      return true
  if x == ex + gutterW - 1 and cfgFolding:
    if b.foldAt(p.line) >= 0:
      b.unfoldLine(p.line)
      return true
    let (ok, _) = b.foldRange(p.line)
    if ok:
      b.foldLine(p.line)
      return true
  # a change mark (git): its menu
  if x == ex + gutterW - 2 and p.line < b.git.len and b.git[p.line] != 0 and cfgGitGutter and
     (not zenMode or cfgZenGit):
    b.setSingle(Pos(line: p.line, col: 0))
    hunkActions()
    return true
  # clicking a line number selects the line
  if x > ex and x < ex + gutterW - 1:
    let e = if p.line < b.lines.high: Pos(line: p.line + 1, col: 0) else: Pos(line: p.line, col: b.lines[p.line].len)
    b.setSingle(e, Pos(line: p.line, col: 0))
    focus = fEditor
    return true
  false
