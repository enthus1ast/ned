# ── project-wide replace (Search view › ⇄): preview inline, replace one / a file / everything ──

proc replaceLineSpans(line: string, q, r: string, caseS, word, rx: bool): (string, int) =
  ## the line with every match replaced, and how many there were
  let sp = findSpans(line, q, caseS, word, rx)
  if sp.len == 0: return (line, 0)
  var res = ""
  var last = 0
  for (a, e) in sp:
    res.add line[last ..< a]
    res.add replacementFor(line, q, r, a, e, caseS, rx)
    last = e
  res.add line[last .. ^1]
  (res, sp.len)

proc replaceInBuffer(b: Buffer, q, r: string, caseS, word, rx: bool, onlyLine = -1): int =
  ## undoable: one edit group for the whole buffer (or one line of it)
  if not b.canEdit(): return 0
  b.beginEdit()
  for l in countdown(b.lines.high, 0):
    if onlyLine >= 0 and l != onlyLine: continue
    if b.path.len > 0 and (b.path & ":" & $l) in searchDismissed: continue
    let line = b.lines[l]
    let sp = findSpans(line, q, caseS, word, rx)
    for h in countdown(sp.high, 0):
      let (a, e) = sp[h]
      discard b.replaceText(Pos(line: l, col: a), Pos(line: l, col: e), replacementFor(line, q, r, a, e, caseS, rx))
      inc result
  b.endEdit()
  b.normalize()

proc searchResultFiles(): seq[string] =
  for h in searchHits:
    if h.path in searchDismissed: continue
    if result.len == 0 or result[^1] != h.path:
      if h.path notin result: result.add h.path

proc replaceInDiskFile(path, q, r: string, caseS, word, rx: bool): (int, string) =
  ## (replacements, error) — writes crash-safely after keeping a local-history copy
  var content: string
  try:
    if getFileSize(path) > 4_000_000: return (0, "too big")
    content = readFile(path)
  except CatchableError as e: return (0, e.msg)
  if '\0' in content[0 ..< min(content.len, 8000)]: return (0, "binary")
  let crlf = content.count("\r\n") > 0 and content.count("\r\n") * 2 >= content.count('\n')
  let finalNl = content.endsWith("\n")
  var ls = content.split('\n')
  if finalNl: ls.setLen(ls.len - 1)
  var n = 0
  for l in 0 ..< ls.len:
    if (path & ":" & $l) in searchDismissed: continue
    var line = ls[l]
    let hadCr = line.endsWith("\r")
    if hadCr: line.setLen(line.len - 1)
    let (nl, k) = replaceLineSpans(line, q, r, caseS, word, rx)
    if k > 0:
      ls[l] = nl & (if hadCr: "\r" else: "")
      n += k
  if n == 0: return (0, "")
  discard crlf
  try:
    snapshotHistory(path)
    writeFileSafe(path, ls.join("\n") & (if finalNl: "\n" else: ""))
    lastReplaceUndo.add (path, content)
  except CatchableError as e: return (0, e.msg)
  (n, "")

proc undoProjectReplace() =
  if lastReplaceUndo.len == 0 and lastReplaceBufs.len == 0:
    info("No replace-all to undo")
    return
  var n = 0
  for (path, old) in lastReplaceUndo:
    try:
      snapshotHistory(path)
      writeFileSafe(path, old)
      inc n
    except CatchableError as e: error(path & ": " & e.msg)
  for (id, sq) in lastReplaceBufs:
    let b = bufById(id)
    if b != nil and b.topSeq() == sq:
      b.undo()
      inc n
  lastReplaceUndo.setLen(0)
  lastReplaceBufs.setLen(0)
  info("Undid the replace in " & $n & " file(s)")
  if dockQueryRan.len > 0: projectSearch(dockQueryRan)

proc projectReplaceAll() =
  if dockQueryRan.len == 0 or searchHits.len == 0:
    info("Search first (Enter in the search box), then replace")
    return
  if dockQuery != dockQueryRan:
    projectSearch(dockQuery)
    info("Results updated for the new search — check them, then Replace all again")
    return
  let files = searchResultFiles()
  var nHits = 0
  for h in searchHits:
    if h.path notin searchDismissed and (h.path & ":" & $h.line) notin searchDismissed: inc nHits
  let q = dockQueryRan
  let r = dockReplace
  let (caseS, word, rx) = (searchCaseS, searchWord, searchRx)
  var openN = 0
  for f in files:
    if bufIndexByPath(f) >= 0: inc openN
  let msg = "Replace " & (if searchCount >= cfgSearchMax: "the first " else: "") & $nHits & " matching line(s) in " &
            $files.len & " file(s) with \"" & truncTo(r, 30) & "\"?" &
            (if openN > 0: " Open files change in the editor (save them);" else: "") &
            (if files.len > openN: " the others are written to disk (Search: undo replace all reverts)." else: "") &
            "  (y)es (c)ancel"
  askConfirm(msg, proc(c: char) =
    if c != 'y': return
    lastReplaceUndo.setLen(0)
    lastReplaceBufs.setLen(0)
    var total, nfiles = 0
    var errs: seq[string]
    for f in files:
      let bi = bufIndexByPath(f)
      if bi >= 0:
        let b = bufs[bi]
        let k = replaceInBuffer(b, q, r, caseS, word, rx)
        if k > 0:
          total += k
          inc nfiles
          lastReplaceBufs.add (b.id, b.topSeq())
      else:
        let (k, err) = replaceInDiskFile(f, q, r, caseS, word, rx)
        if err.len > 0: errs.add relPath(f) & ": " & err
        if k > 0:
          total += k
          inc nfiles
    refreshTree()
    if errs.len > 0: warn("Skipped: " & errs.join(", "))
    toast("Replaced " & $total & " in " & $nfiles & " file(s)", 5, "Undo", proc() = undoProjectReplace(), 20000)
    projectSearch(q))

proc replaceHit(path: string, line: int) =
  ## replace the matches of one result line (in the editor — the file opens; save when ready)
  let b = openFile(path)
  if b == nil or line >= b.lines.len: return
  let k = replaceInBuffer(b, dockQueryRan, dockReplace, searchCaseS, searchWord, searchRx, line)
  b.centerOn(Pos(line: line, col: 0))
  focus = fTree
  var keep: seq[SearchHit]
  for h in searchHits:
    if not (h.path == path and h.line == line): keep.add h
  searchHits = keep
  info("Replaced " & $k & " on line " & $(line + 1) & " of " & b.name & " — Ctrl+S saves")

proc replaceInFileHits(path: string) =
  let b = openFile(path)
  if b == nil: return
  let k = replaceInBuffer(b, dockQueryRan, dockReplace, searchCaseS, searchWord, searchRx)
  focus = fTree
  var keep: seq[SearchHit]
  for h in searchHits:
    if h.path != path: keep.add h
  searchHits = keep
  info("Replaced " & $k & " in " & b.name & " — Ctrl+S saves, Ctrl+Z undoes")

proc dismissHit(path: string, line: int) =
  if line < 0: searchDismissed.incl path
  else: searchDismissed.incl path & ":" & $line
  var keep: seq[SearchHit]
  for h in searchHits:
    if h.path in searchDismissed or (h.path & ":" & $h.line) in searchDismissed: continue
    keep.add h
  searchHits = keep
  searchCount = searchHits.len

proc showProblems() =
  setPanel(pkProblems)
  panelFollow = false
  panelScroll = 0
  panelSel = if panelLines.len > 1: 1 else: 0
  focus = fPanel
