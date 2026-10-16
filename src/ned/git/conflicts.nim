# ── git merge conflicts: accept ours / theirs / both, and a side-by-side view against the last commit ──

proc resolveConflict(b: Buffer, ci: int, choice: string) =
  ## replace the whole conflict block by ours, theirs or both (ours first)
  let cs = b.conflictsOf()
  if ci < 0 or ci >= cs.len or not b.canEdit(): return
  let c = cs[ci]
  let oursEnd = if c.base >= 0: c.base else: c.mid
  var keep: seq[string]
  if choice in ["ours", "both"]:
    for l in c.start + 1 ..< oursEnd: keep.add b.lines[l]
  if choice in ["theirs", "both"]:
    for l in c.mid + 1 ..< c.stop: keep.add b.lines[l]
  b.beginEdit()
  if keep.len > 0:
    discard b.replaceText(Pos(line: c.start, col: 0), Pos(line: c.stop, col: b.lines[c.stop].len), keep.join("\n"))
  elif c.stop + 1 < b.lines.len:
    discard b.replaceText(Pos(line: c.start, col: 0), Pos(line: c.stop + 1, col: 0), "")
  else:
    discard b.replaceText(Pos(line: c.start, col: 0), Pos(line: c.stop, col: b.lines[c.stop].len), "")
  b.endEdit()
  b.setSingle(Pos(line: min(c.start, b.lines.high), col: 0))
  let left = b.conflictsOf().len
  info("Conflict resolved (" & choice & ")" & (if left > 0: " — " & $left & " left" else: " — none left"))

proc cmdConflict(choice: string) =
  let b = buf()
  let ci = b.conflictAt(b.primary.head.line)
  if ci < 0:
    let cs = b.conflictsOf()
    if cs.len == 0: info("No merge conflicts in this file")
    else:
      # go to the next one
      for c in cs:
        if c.start > b.primary.head.line:
          b.centerOn(Pos(line: c.start, col: 0))
          return
      b.centerOn(Pos(line: cs[0].start, col: 0))
    return
  if choice == "next":
    let cs = b.conflictsOf()
    b.centerOn(Pos(line: cs[(ci + 1) mod cs.len].start, col: 0))
    return
  b.resolveConflict(ci, choice)

proc openDiffView(title: string, left: seq[string], leftTitle: string, src: Buffer, right: seq[string],
                  rightTitle: string, lang: Lang) =
  ## a side-by-side diff in its own tab; with `src` the right side is that open file, live
  let dv = openScratch("Diff: " & title, "", lang)
  dv.readOnly = true
  diffViews[dv.id] = DiffView(left: left, right: right, src: (if src != nil: src.id else: 0),
                              leftTitle: leftTitle, rightTitle: rightTitle)
  dv.setSingle(Pos())
  viewHead.del dv.id
  # start at the first change
  let v = diffViews[dv.id]
  v.diffRows()
  dv.lines = newSeq[string](max(1, v.rows.len))
  for k, r in v.rows:
    if r.kind != ' ':
      dv.setSingle(Pos(line: k, col: 0))
      break
  needRender = true

proc diffRevertAt(v: DiffView, ri: int) =
  ## the change at row `ri` back to the left side's text, in the live file on the right
  let s = bufById(v.src)
  if s == nil or not s.canEdit() or ri < 0 or ri >= v.rows.len or v.rows[ri].kind == ' ':
    if ri >= 0 and ri < v.rows.len and v.rows[ri].kind == ' ': info("Not on a change")
    return
  var a0 = ri
  while a0 > 0 and v.rows[a0 - 1].kind != ' ': dec a0
  var e0 = ri
  while e0 + 1 < v.rows.len and v.rows[e0 + 1].kind != ' ': inc e0
  var old: seq[string]
  var bl: seq[int]
  for k in a0 .. e0:
    if v.rows[k].a >= 0: old.add v.left[v.rows[k].a]
    if v.rows[k].b >= 0: bl.add v.rows[k].b
  s.beginEdit()
  if bl.len > 0:
    let first = min(bl)
    let last = max(bl)
    if old.len > 0:
      discard s.replaceText(Pos(line: first, col: 0), Pos(line: last, col: s.lines[last].len), old.join("\n"))
    elif last + 1 < s.lines.len:
      discard s.replaceText(Pos(line: first, col: 0), Pos(line: last + 1, col: 0), "")
    elif first > 0:
      discard s.replaceText(Pos(line: first - 1, col: s.lines[first - 1].len), Pos(line: last, col: s.lines[last].len), "")
    else:
      discard s.replaceText(Pos(), Pos(line: last, col: s.lines[last].len), "")
  else:
    var nb = s.lines.len
    for k in e0 + 1 ..< v.rows.len:
      if v.rows[k].b >= 0:
        nb = v.rows[k].b
        break
    if nb < s.lines.len:
      discard s.replaceText(Pos(line: nb, col: 0), Pos(line: nb, col: 0), old.join("\n") & "\n")
    else:
      let l = s.lines.high
      discard s.replaceText(Pos(line: l, col: s.lines[l].len), Pos(line: l, col: s.lines[l].len), "\n" & old.join("\n"))
  s.endEdit()
  info("Change reverted in " & s.name & " — Ctrl+Z there brings it back")
  needRender = true
