# ── the bigger refactorings in the editor: object ⇄ ref object, a module split, callback → async, a call's syntax.
#    The index works each one out (nim/index/reshape.nim) as a plan; here it is shown as a diff first, applied when
#    you say so (one undo step a file, the files left changed, not saved), and the places it leaves to you listed ──

proc rfPlanEdits(plan: NxPlan): seq[RfEdit] =
  ## a plan's edits in the form the editor applies (file, from, to, new text)
  for x in plan.edits:
    result.add (x.path, Pos(line: x.line, col: x.col), Pos(line: x.endLine, col: x.endCol), x.text)

proc rfNotesList(title: string, plan: NxPlan) =
  ## the places the refactoring left to you: a list to go to each
  if plan.notes.len == 0: return
  var places: seq[(string, int, int, string)]
  for x in plan.notes: places.add (x.path, x.line, x.col, x.why)
  rfByHand(title & " — " & $plan.notes.len & " place" & (if plan.notes.len == 1: "" else: "s") & " to look at",
           places)

proc rfPreviewPlan(title: string, plan: NxPlan) =
  ## what the plan changes, as a diff — one file side by side, several as one unified diff — then Apply it or
  ## Leave it. Nothing is written before Apply; a file changed since the preview stops it
  var files: seq[string]
  for x in plan.edits:
    if x.path notin files: files.add x.path
  if files.len == 0:
    info(plan.msg & (if plan.notes.len > 0: " — nothing to change, only places to look at" else: " — nothing to change"))
    rfNotesList(title, plan)
    return
  var befores, afters: seq[seq[string]]
  var adds, dels = 0
  for p in files:
    let before = if p in plan.creates: newSeq[string]() else: rfLinesOf(p)
    var mine: seq[NxEdit]
    for x in plan.edits:
      if x.path == p: mine.add x
    let after = nxApplyEdits(before, mine)
    let (ad, de) = diffStats(lineDiff(before, after))
    adds += ad
    dels += de
    befores.add before
    afters.add after
  let fromId = buf().id
  if files.len == 1 and files[0] notin plan.creates:
    openDiffView(relPath(files[0]), befores[0], "now", nil, afters[0], title, detectLang(files[0], ""))
  else:
    var text = "# " & title & " — " & $files.len & " files\n"
    for x in plan.notes: text.add "# to look at: " & relPath(x.path) & ":" & $(x.line + 1) & " — " & x.why & "\n"
    for i, p in files:
      text.add "\n" & unifiedDiff(befores[i], afters[i], (if p in plan.creates: "/dev/null" else: "a/" & relPath(p)),
                                  "b/" & relPath(p))
    discard openScratch("Refactor preview", text, langByName("Diff"))
  let pvId = buf().id
  proc back() =
    ## closes the preview's tab and brings the file the refactoring started from to the front
    # the preview's tab closed, the file it started from in front again
    let pv = bufById(pvId)
    if pv != nil and pv.id != fromId:
      let k = bufs.find(pv)
      if k >= 0: closeBufferAt(k)
    let x = bufById(fromId)
    if x != nil:
      let k = bufs.find(x)
      if k >= 0: curBuf = k
  proc doApply() =
    ## applies the plan: refuses if a file changed since the preview, creates the new files, makes the edits (one undo
    ## step a file) and lists the places left to look at
    back()
    for i, p in files:
      let now = if p in plan.creates: (if fileExists(p): rfLinesOf(p) else: newSeq[string]()) else: rfLinesOf(p)
      if now != befores[i] and not (p in plan.creates and now.join("").strip.len == 0):
        info(relPath(p) & " changed since the preview — run the refactoring again")
        return
    for p in plan.creates:
      if fileExists(p): continue
      try:
        createDir(parentDir(p))
        writeFile(p, "")
      except CatchableError as ex:
        error("Cannot create " & relPath(p) & ": " & ex.msg)
        return
      fileWritten(p)
    let n = rfApply(rfPlanEdits(plan))
    info(plan.msg & " — " & $n & " file" & (if n == 1: "" else: "s") & " changed (Ctrl+Z undoes it in each, Ctrl+S saves)")
    rfNotesList(title, plan)
  var items = @[act("Apply it", "Ctrl+Z undoes it, file by file", doApply),
                act("Leave it", "nothing changes", proc() =
                  back()
                  info("Left as it is"))]
  if plan.notes.len > 0:
    items.add act("The " & $plan.notes.len & " places to look at", "first, without changing anything", proc() =
      back()
      rfNotesList(title, plan))
  openActions(title & ": +" & $adds & " −" & $dels & " lines in " & $files.len & " file" &
              (if files.len == 1: "" else: "s") &
              (if plan.notes.len > 0: " · " & $plan.notes.len & " to look at" else: ""), items)

proc rfNimReady(b: Buffer, what: string): bool =
  ## whether a refactoring can work on this buffer (a saved Nim file with the built-in engine on); says so when it
  ## cannot
  if b.lang.mode != lmNim or not nimEngineOn(b) or b.path.len == 0:
    info(what & " works on a saved Nim file, with the built-in engine")
    return false
  true

proc cmdRefObject() =
  ## the object type at the cursor ⇄ ref object, and its uses in the project
  let b = buf()
  if not rfNimReady(b, "object ⇄ ref object"): return
  let f = nxFileFor(b)
  if f == nil: return
  let p = b.primary.head
  let plan = nxPlanRefObject(f, b.lines, p.line, p.col, nimSourceFiles())
  if not plan.ok:
    info(plan.msg)
    return
  rfPreviewPlan("Refactor: " & plan.msg, plan)

proc cmdCallbackToAsync() =
  ## the proc at the cursor, which takes a callback, made {.async.} — and its calls awaited
  let b = buf()
  if not rfNimReady(b, "Callback → async"): return
  let f = nxFileFor(b)
  if f == nil: return
  let p = b.primary.head
  let plan = nxPlanAsync(f, b.lines, p.line, p.col, nimSourceFiles())
  if not plan.ok:
    info(plan.msg)
    return
  rfPreviewPlan("Refactor: " & plan.msg, plan)

proc cmdSplitModule() =
  ## the selected top-level declarations into a new module (or the end of one that exists)
  let b = buf()
  if not rfNimReady(b, "Splitting a module"): return
  let (sa, se) = b.primary.range
  if sa == se:
    info("Select the declarations to move into a new module")
    return
  let a = sa.line
  let e = if se.col == 0 and se.line > a: se.line - 1 else: se.line   # (a selection that ends at a line's start)
  let bid = b.id
  askText("New module (path)", relPath(parentDir(b.path)) & "/", proc(t: string) =
    let bb = bufById(bid)
    if bb == nil: return
    var p = expandTilde(t.strip)
    if p.len == 0 or p.endsWith("/"): return
    if not p.endsWith(".nim"): p.add ".nim"
    let full = if p.isAbsolute: p else: rootDir / p
    let f = nxFileFor(bb)
    if f == nil: return
    let plan = nxPlanSplit(f, bb.lines, a, e, full, nimSourceFiles())
    if not plan.ok:
      info(plan.msg)
      return
    rfPreviewPlan("Refactor: split " & extractFilename(bb.path), plan))

proc rfCallSyntaxAct(bid, a, e: int, form: NxCallForm): Action =
  ## (a factory: a closure made in a loop would share its variables)
  result = proc() =
    let b = bufById(bid)
    if b == nil: return
    let f = nxFileFor(b)
    if f == nil: return
    let plan = nxPlanCallSyntax(f, b.lines, b.path, a, e, 0, ord(form))
    if not plan.ok:
      info(plan.msg)
      return
    rfPreviewPlan("Refactor: " & plan.msg, plan)

proc cmdSwitchCallSyntax() =
  ## the call at the cursor written the next way that means the same — f(x, y) → x.f(y) → f x, y → f(x, y) —;
  ## with a selection, every call in it written one way (asked)
  let b = buf()
  if not rfNimReady(b, "Switching a call's syntax"): return
  let f = nxFileFor(b)
  if f == nil: return
  let (sa, se) = b.primary.range
  if sa == se:
    let p = b.primary.head
    let plan = nxPlanCallSyntax(f, b.lines, b.path, p.line, p.line, p.col)
    if not plan.ok:
      info(plan.msg)
      return
    rfPreviewPlan("Refactor: " & plan.msg, plan)
    return
  let a = sa.line
  let e = if se.col == 0 and se.line > a: se.line - 1 else: se.line
  openActions("Write every call in lines " & $(a + 1) & "–" & $(e + 1) & " as…", @[
    act("f(x, y)", "a plain call", rfCallSyntaxAct(b.id, a, e, cfPlain)),
    act("x.f(y)", "method call syntax (where x.f is not a field of x)", rfCallSyntaxAct(b.id, a, e, cfMethod)),
    act("f x, y", "command syntax (whole statements only)", rfCallSyntaxAct(b.id, a, e, cfCommand))])
