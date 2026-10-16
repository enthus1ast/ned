# ── the assistant's changes of one run, file by file, as side-by-side diffs (r undoes one change) ──

proc aiReviewCheckpoint(id: int) =
  let ci = aiCpIndex(id)
  if ci < 0:
    info("Those changes were already undone")
    return
  let cp = aiCheckpoints[ci]
  var items: seq[(string, string, Action)]
  var only: Action = nil
  for path, (existed, text) in cp.files:
    let old = if existed: text.split('\n') else: @[]
    let v = DiffView(left: old, right: fileLinesNow(path))
    v.diffRows()
    var add, del = 0
    for r in v.rows:
      if r.a < 0 and r.b >= 0: inc add
      elif r.b < 0 and r.a >= 0: inc del
      elif r.kind != ' ':
        inc add
        inc del
    let p = path
    let o = old
    capture p, o:
      let a: Action = proc() =
        let src = bufferFor(p)
        if src == nil:
          error("Cannot open " & relPath(p))
          return
        openDiffView(relPath(p) & " — the assistant's change", o, "before the assistant", src, src.lines,
                     "now — r undoes a change (then save the file)", detectLang(p, ""))
      only = a
      items.add act(relPath(p), "+" & $add & " −" & $del & (if not existed: " · new file" else: ""), a)
  if items.len == 0:
    info("That run changed no files")
    return
  if items.len == 1:
    only()
    return
  let cid = id
  items.add act("↶ Undo all of it", "every file back as it was before this run", proc() =
    askConfirm("Put back all " & $cp.files.len & " file(s)? (y/n)", proc(c: char) =
      if c in {'y', 'Y'}: aiUndoCheckpoint(cid)))
  openActions("The assistant's changes — " & truncTo(cp.prompt.replace('\n', ' '), 40) & " (" & cp.at & ")", items)

proc cmdAiReview() =
  if aiCheckpoints.len == 0:
    info("The assistant has not changed any files in this session")
    return
  if aiCheckpoints.len == 1:
    aiReviewCheckpoint(aiCheckpoints[0].id)
    return
  var items: seq[(string, string, Action)]
  for i in countdown(aiCheckpoints.high, 0):
    let cp = aiCheckpoints[i]
    let id = cp.id
    var names: seq[string]
    for p in cp.files.keys: names.add extractFilename(p)
    capture id:
      items.add act(cp.at & "  " & truncTo(cp.prompt.replace('\n', ' '), 50), names.join(", "),
                    proc() = aiReviewCheckpoint(id))
  openActions("Review which run of the assistant?", items)
