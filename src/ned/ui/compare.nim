proc diffKey(k: Key): bool =
  ## keys in a diff tab: F7 / Shift+F7 between changes, Enter opens the line, r reverts; typing is ignored
  let b = buf()
  let v = diffViews[b.id]
  v.diffRows()
  let ri = b.primary.head.line
  if k.kind == kFn and k.fn == 7:
    let back = mShift in k.mods
    var k2 = ri
    while true:
      k2 += (if back: -1 else: 1)
      if k2 < 0 or k2 >= v.rows.len:
        info("No more changes")
        return true
      if v.rows[k2].kind != ' ' and (k2 == 0 or v.rows[k2 - 1].kind == ' '): break
    b.setSingle(Pos(line: k2, col: 0))
    return true
  if k.kind == kEnter and k.mods == {}:
    if ri < v.rows.len:
      let r = v.rows[ri]
      let s = if v.src != 0: bufById(v.src) else: nil
      if s != nil:
        var l = r.b
        var q = ri
        while l < 0 and q > 0:
          dec q
          l = v.rows[q].b
        let i = bufs.find(s)
        if i >= 0:
          curBuf = i
          s.centerOn(s.clampPos(Pos(line: max(0, l), col: 0)))
    return true
  if k.kind == kChar and k.mods == {}:
    if k.ch == ord('r'): diffRevertAt(v, ri)
    elif k.ch == ord('n'): return diffKey(Key(kind: kFn, fn: 7))
    elif k.ch == ord('p'): return diffKey(Key(kind: kFn, fn: 7, mods: {mShift}))
    return true
  k.kind in {kBackspace, kDelete, kTab, kPaste}

proc cmdCompareHead() =
  ## the last commit's version on the left, your file on the right — aligned, live
  let b = buf()
  if b.path.len == 0 or not b.inGit:
    info("Compare with last commit works for files in a git repository")
    return
  let id = b.id
  let rel = extractFilename(b.path)
  discard startJob(jkGit, "git --no-pager show " & quoteShell("HEAD:./" & rel), parentDir(b.path), proc(j: Job) =
    let cur = bufById(id)
    if cur == nil: return
    if j.code != 0:
      info("Not in the last commit yet (a new file?)")
      return
    var old = j.output.split('\n')
    if old.len > 0 and old[^1].len == 0: old.setLen(old.len - 1)
    openDiffView(rel, old, "HEAD: " & rel, cur, @[], rel & " (yours)", cur.lang))

proc cmdCompareWithFile() =
  ## this file (right) against another one you pick (left)
  let b = buf()
  if b.isWelcome(): return
  var items: seq[(string, string, Action)]
  let id = b.id
  for rel in projectFiles():
    let path = if rel.isAbsolute: rel else: rootDir / rel
    if path == b.path: continue
    let pp = path
    capture pp:
      items.add act(relPath(pp), "", proc() =
        let cur = bufById(id)
        if cur == nil: return
        var other: seq[string]
        let oi = bufIndexByPath(pp)
        if oi >= 0: other = bufs[oi].lines
        else:
          try: other = textLines(readFile(pp))
          except CatchableError as e:
            error(e.msg)
            return
        openDiffView(extractFilename(pp) & " ↔ " & cur.name, other, relPath(pp), cur, @[], cur.name, cur.lang))
    if items.len > 20000: break
  openActions("Compare " & b.name & " with…", items)

proc cmdMarkdownPreview() =
  ## the Markdown file rendered, beside it; it follows your edits
  let b = buf()
  if b.lang.mode != lmMarkdown:
    info("Open a Markdown file first")
    return
  for pb in bufs:
    if pb.mdSrc == b.id:
      info("The preview is already open")
      return
  let pv = openScratch("Preview: " & b.name, "", b.lang)
  pv.mdSrc = b.id
  pv.readOnly = true
  let ci = bufs.find(b)
  if ci < 0: return
  curBuf = ci
  let wasSplit = splitOn
  splitEditor(false)
  if not wasSplit:
    # the file on the left (keeps the focus), its preview on the right
    panes[1] = Pane(bufId: pv.id, snap: snapView(pv))
    activePane = 0
  else: panes[1 - activePane] = Pane(bufId: pv.id, snap: snapView(pv))
  needRender = true
  info("Preview on the right — it follows your edits")
