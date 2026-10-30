# ── crash recovery ──

proc applyRecovered(b: Buffer, text: string) =
  ## puts the recovered text into the buffer as one edit (changing only the lines that differ) and writes the swap file
  ## again, so the restored edits are safe at once; they still have to be saved
  b.setTextMinimal(text)
  writeSwap(b)
  info("Restored the unsaved edits of " & b.name & " — review them, then Ctrl+S")

proc recoverAct(path, text, file: string): Action =
  ## the action that restores one recovery file: opens its file (or a new untitled buffer when it had no path), deletes
  ## the recovery file first, then applies the saved text
  result = proc() =
    var b: Buffer
    if path.len > 0: b = openFile(path)
    else:
      bufs.add newBuffer()
      curBuf = bufs.high
      b = buf()
    if b == nil: return
    try: removeFile(file)          # before applying: applying writes this session's own recovery file
    except CatchableError: discard
    applyRecovered(b, text)

proc offerRecovery(b: Buffer) =
  ## unsaved edits of this file left by a ned that crashed or was killed: offer to restore them
  if b.path.len == 0 or b.binary: return
  let other = otherSessionEditing(b.path)
  if other > 0:
    warn(b.name & " has unsaved edits in another running ned (pid " & $other & ")")
    return
  let pre = fnv(b.path) & "-"
  let mine = "-" & $getCurrentProcessId() & ".json"
  var best: JsonNode
  var bestFile = ""
  if not dirExists(swapDir()): return
  for kind, p in walkDir(swapDir()):
    let n = extractFilename(p)
    if kind != pcFile or not n.startsWith(pre) or n.endsWith(mine): continue
    try:
      let j = parseFile(p)
      if j{"path"}.getStr != b.path or swapOwnerAlive(j): continue
      if j{"text"}.getStr == b.lines.join("\n"):
        removeFile(p)                     # nothing was lost: the file already has these edits
        continue
      if best == nil or j{"time"}.getInt > best{"time"}.getInt:
        best = j
        bestFile = p
    except CatchableError: discard
  if best == nil: return
  toast("Unsaved edits to " & b.name & " survived (" & agoText(best{"time"}.getInt * 1000) & ") — " &
        "also in File › Recover unsaved edits", 2, "Restore", recoverAct(b.path, best{"text"}.getStr, bestFile), 120000)

proc cmdRecoverFiles() =
  ## File › Recover unsaved edits: lists every recovery file left behind (file name, line count, age) as a menu of
  ## actions, with a last entry that deletes all of them after a confirmation
  let left = swapsLeftBehind()
  if left.len == 0:
    info("Nothing to recover")
    return
  var items: seq[(string, string, Action)]
  var files: seq[string]
  for j in left:
    let path = j{"path"}.getStr
    let text = j{"text"}.getStr
    files.add j{"file"}.getStr
    items.add act((if path.len > 0: relPath(path) else: "untitled"),
                  $(text.count('\n') + 1) & " lines · " & agoText(j{"time"}.getInt * 1000),
                  recoverAct(path, text, j{"file"}.getStr))
  let fs = files
  items.add act("Discard all of them", "", proc() =
    askConfirm("Delete " & $fs.len & " recovery file(s)? Their edits are lost. (y)es (c)ancel", proc(c: char) =
      if c == 'y':
        for f in fs:
          try: removeFile(f)
          except CatchableError: discard
        info("Recovery files deleted")))
  openActions("Recover unsaved edits", items)

proc checkRecoveryAtStart() =
  ## at start-up, shows a toast with a Recover… button when recovery files exist for files that are not open — edits
  ## from a session that ended unexpectedly
  var others = 0
  for j in swapsLeftBehind():
    let path = j{"path"}.getStr
    if path.len == 0 or bufIndexByPath(path) < 0: inc others
  if others > 0:
    toast($others & " file(s) have unsaved edits from a session that ended unexpectedly", 2, "Recover…",
          proc() = cmdRecoverFiles(), 60000)
