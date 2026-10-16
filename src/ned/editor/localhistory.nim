# ── local history: every save keeps the previous version (File › Local history) ──

proc historyDir(path: string): string = stateDir() / "history" / fnv(path)

proc snapshotHistory(path: string) =
  ## keep the version on disk before it is overwritten (small text files only)
  try:
    if not fileExists(path): return
    let size = getFileSize(path)
    if size <= 0 or size > 4_000_000: return
    let old = readFile(path)
    if '\0' in old[0 ..< min(old.len, 8000)]: return
    let d = historyDir(path)
    privateDir(stateDir() / "history")
    privateDir(d)
    var snaps: seq[string]
    for kind, p in walkDir(d):
      if kind == pcFile and extractFilename(p).allCharsInSet(Digits): snaps.add p
    snaps.sort()
    if snaps.len > 0 and readFile(snaps[^1]) == old: return
    writeFile(d / "path", path)
    writeFile(d / $(epochTime() * 1000).int64, old)
    snaps.add ""
    let excess = snaps.len - 60
    for i in 0 ..< excess: removeFile(snaps[i])
  except CatchableError: discard

proc historyVersions(path: string): seq[(int64, string)] =
  ## (unix ms, file) newest first
  let d = historyDir(path)
  if not dirExists(d): return
  for kind, p in walkDir(d):
    let n = extractFilename(p)
    if kind == pcFile and n.len > 0 and n.allCharsInSet(Digits):
      try: result.add (parseBiggestInt(n).int64, p)
      except ValueError: discard
  result.sort(proc(x, y: (int64, string)): int = cmp(y[0], x[0]))

proc agoText(ms: int64): string =
  let s = max(0'i64, (epochTime() * 1000).int64 - ms) div 1000
  if s < 60: $s & "s ago"
  elif s < 3600: $(s div 60) & " min ago"
  elif s < 86400: $(s div 3600) & " h ago"
  else: $(s div 86400) & " days ago"
