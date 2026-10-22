# ── hot exit (files.hotExit): quitting keeps the unsaved edits without asking; they come back, still unsaved, the
#    next time ned opens the folder — the files and the untitled tabs, each where its cursor was ──

proc hotExitFile(): string = stateDir() / "hotexit" / (fnv(if rootDir.len > 0: rootDir else: "/") & ".json")

proc hotExitOn(): bool = sval("files.hotExit").getBool(true)

proc hotExitSave(): bool =
  ## the unsaved buffers into the folder's hot-exit file (true: written — quitting loses nothing)
  var arr = newJArray()
  for b in bufs:
    if not b.dirty or b.binary or b.hex != nil or b.title.len > 0 or b.isWelcome(): continue
    if b.id in multiBufs or b.id in commitBufs or b.id in rebaseBufs or b.id in sigPlans: continue
    let (mt, _) = if b.path.len > 0: fileStamp(b.path) else: (0'i64, 0'i64)
    arr.add %*{"path": b.path, "name": b.name, "text": b.lines.join("\n"), "crlf": b.crlf, "noEol": b.noEol,
               "line": b.primary.head.line, "col": b.primary.head.col, "mtime": mt,
               "lang": (if b.lang != nil: b.lang.id else: "")}
  let f = hotExitFile()
  try:
    if arr.len == 0:
      if fileExists(f): removeFile(f)
      return true
    privateDir(parentDir(f))
    writeFileSafe(f, $(%*{"root": rootDir, "time": getTime().toUnix, "buffers": arr}), 0o600)
    true
  except CatchableError as e:
    error("Could not keep the unsaved edits (" & e.msg & ") — save them, or turn off files.hotExit")
    false

proc hotExitRestore() =
  ## the unsaved edits kept when ned last quit in this folder: back in their tabs, unsaved
  let f = hotExitFile()
  if not fileExists(f): return
  var j: JsonNode
  try: j = parseFile(f)
  except CatchableError: return
  var n = 0
  var changedOnDisk: seq[string]
  for e in jitems(j{"buffers"}):
    let path = e{"path"}.getStr
    var b: Buffer = nil
    if path.len > 0:
      b = openFile(path)
    else:
      if bufs.len == 1 and bufs[0].isWelcome(): bufs[0] = newBuffer()
      else: bufs.add newBuffer()
      curBuf = bufs.high
      b = bufs[curBuf]
      let l = langByName(e{"lang"}.getStr)
      if l != nil: b.lang = l
    if b == nil: continue
    let text = e{"text"}.getStr
    if b.lines.join("\n") != text:
      b.setTextMinimal(text)
      b.crlf = e{"crlf"}.getBool(b.crlf)
      inc n
      if path.len > 0 and fileExists(path) and e{"mtime"}.getBiggestInt != 0 and
         fileStamp(path)[0] != e{"mtime"}.getBiggestInt:
        changedOnDisk.add b.name
    b.setSingle(b.clampPos(Pos(line: e{"line"}.getInt, col: e{"col"}.getInt)))
    b.centerOn(b.primary.head)
    writeSwap(b)
  try: removeFile(f)
  except CatchableError: discard
  if n > 0:
    toast("Unsaved edits of " & $n & " file" & (if n == 1: "" else: "s") & " are back, still unsaved (files.hotExit)" &
          (if changedOnDisk.len > 0: " — " & changedOnDisk.join(", ") & " changed on disk meanwhile: saving keeps " &
                                     "your version" else: ""), (if changedOnDisk.len > 0: 2 else: 3), ttl = 9000)
