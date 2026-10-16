# ── local history ──

proc historyAct(id: int, file: string, ms: int64): Action =
  result = proc() =
    let b = bufById(id)
    if b == nil: return
    var old = ""
    try: old = readFile(file)
    except CatchableError as e:
      error(e.msg)
      return
    let d = unifiedDiff(textLines(old), b.lines, b.name & "  (" & agoText(ms) & ")", b.name & "  (now)")
    if d.len == 0:
      info("That version is the same as the text now")
      return
    discard openScratch("history: " & b.name & " · " & agoText(ms), d, langByName("Diff"))
    toast("What changed since that version (− then, + now)", 3, "Restore it", proc() =
      let bb = bufById(id)
      if bb != nil:
        let i = bufs.find(bb)
        if i >= 0: curBuf = i
        bb.setTextMinimal(textLines(old).join("\n"))
        info("Restored the version from " & agoText(ms) & " — Ctrl+S saves it, Ctrl+Z undoes"), 30000)

proc cmdLocalHistory() =
  let b = buf()
  if b.path.len == 0 or b.title.len > 0:
    info("Local history is kept for files on disk")
    return
  let vs = historyVersions(b.path)
  if vs.len == 0:
    info("No earlier versions of " & b.name & " yet — every save keeps the one before it")
    return
  var items: seq[(string, string, Action)]
  for k, (ms, f) in vs:
    var detail = ""
    if k < 25:
      try:
        let (ad, de) = diffStats(lineDiff(textLines(readFile(f)), b.lines))
        detail = "+" & $ad & " −" & $de & " since"
      except CatchableError: discard
    let t = fromUnix(ms div 1000).local.format("ddd d MMM HH:mm")
    items.add act(agoText(ms) & "   " & t, detail, historyAct(b.id, f, ms))
  openActions("Local history · " & b.name, items)

proc folderAct(d: string): Action = (proc() = openFolder(d))

proc cmdRecentProjects() =
  ## folders you worked in (opened folders and every folder with a saved session)
  var dirs: seq[string]
  for r in recentFiles:
    if dirExists(r) and r notin dirs: dirs.add r
  if savedSessions != nil:
    for k, _ in savedSessions:
      if dirExists(k) and k notin dirs: dirs.add k
  var items: seq[(string, string, Action)]
  for d in dirs:
    if d == rootDir: continue
    let home = getHomeDir().strip(leading = false, chars = {'/'})
    items.add act(extractFilename(d), (if d.startsWith(home): "~" & d[home.len .. ^1] else: d), folderAct(d))
  if items.len == 0:
    info("No other projects yet — File › Open folder…")
    return
  openActions("Open recent project", items)

proc diffWithSaved() =
  ## unsaved edits of the current file vs the file on disk
  let b = buf()
  if b.path.len == 0 or not fileExists(b.path):
    info("Not saved yet")
    return
  var disk: seq[string]
  try: disk = textLines(readFile(b.path))
  except CatchableError as e:
    error(e.msg)
    return
  if disk == b.lines:
    info("No unsaved changes")
    return
  openDiffView("saved ↔ " & b.name, disk, b.name & " (saved)", b, @[], b.name & " (unsaved)", b.lang)
