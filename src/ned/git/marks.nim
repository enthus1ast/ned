# ── git: live change marks, stepping through changes, reverting one, blame ──

type GitHunk = tuple[newStart, newEnd: int, old: seq[string]]

proc updateGitMarks(b: Buffer) =
  ## exact added/modified/deleted marks for unsaved text too (diff against the indexed version)
  if not b.gitHasBase or b.gitAt == b.changeId or b.lines.len > 100_000: return
  b.gitAt = b.changeId
  let ops = lineDiff(b.gitBase, b.lines)
  var marks = newSeq[uint8](b.lines.len)
  var i = 0
  while i < ops.len:
    if ops[i].kind == ' ':
      inc i
      continue
    var j = i
    var adds: seq[int]
    var dels = 0
    while j < ops.len and ops[j].kind != ' ':
      if ops[j].kind == '+': adds.add ops[j].bLine
      else: inc dels
      inc j
    if adds.len == 0:
      let l = if i > 0 and ops[i - 1].bLine >= 0: ops[i - 1].bLine else: 0
      if l < marks.len and marks[l] == 0: marks[l] = 3
    else:
      for l in adds: marks[l] = (if dels > 0: 2'u8 else: 1'u8)
    i = j
  b.git = marks
  needRender = true

proc gitHunks(b: Buffer): seq[GitHunk] =
  if not b.gitHasBase: return
  let ops = lineDiff(b.gitBase, b.lines)
  var i = 0
  while i < ops.len:
    if ops[i].kind == ' ':
      inc i
      continue
    var j = i
    var firstNew = -1
    var lastNew = -1
    var old: seq[string]
    while j < ops.len and ops[j].kind != ' ':
      if ops[j].kind == '-': old.add ops[j].text
      else:
        if firstNew < 0: firstNew = ops[j].bLine
        lastNew = ops[j].bLine
      inc j
    let at = if firstNew >= 0: firstNew elif i > 0 and ops[i - 1].bLine >= 0: ops[i - 1].bLine + 1 else: 0
    result.add (at, (if firstNew >= 0: lastNew + 1 else: at), old)
    i = j

proc hunkAtCursor(b: Buffer): int =
  let hs = b.gitHunks()
  let l = b.primary.head.line
  for k, h in hs:
    if (l >= h.newStart and l < h.newEnd) or (h.newStart == h.newEnd and (l == h.newStart or l + 1 == h.newStart)):
      return k
  -1

proc gotoHunk(d: int) =
  let b = buf()
  if not b.gitHasBase:
    info("No git changes to step through here")
    return
  let hs = b.gitHunks()
  if hs.len == 0:
    info("No changes in " & b.name)
    return
  let l = b.primary.head.line
  var pick = -1
  if d > 0:
    for k, h in hs:
      if h.newStart > l:
        pick = k
        break
    if pick < 0: pick = 0
  else:
    for k in countdown(hs.high, 0):
      if hs[k].newEnd <= l and hs[k].newStart < l:
        pick = k
        break
    if pick < 0: pick = hs.high
  gotoBufLine(b.id, min(hs[pick].newStart, b.lines.high))
  info("Change " & $(pick + 1) & " of " & $hs.len & "  ·  F7 next · Shift+F7 previous · palette › Git: revert this change")

proc showHunk() =
  let b = buf()
  let k = b.hunkAtCursor()
  if k < 0:
    info("The cursor is not on a changed line")
    return
  let h = b.gitHunks()[k]
  var t = ""
  for x in h.old: t.add "- " & x & "\n"
  for l in h.newStart ..< h.newEnd: t.add "+ " & b.lines[l] & "\n"
  showHover(t)

proc revertHunk()

proc stageHunk() =
  ## put the change at the cursor into git's index (the next commit), as it is in the editor
  let b = buf()
  let k = b.hunkAtCursor()
  if k < 0 or b.path.len == 0:
    info("The cursor is not on a changed line")
    return
  let root = findGitRoot(parentDir(b.path))
  if root.len == 0: return
  let hs = b.gitHunks()
  var off = 0
  for i in 0 ..< k: off += (hs[i].newEnd - hs[i].newStart) - hs[i].old.len
  let h = hs[k]
  let oldLen = h.old.len
  let newLen = h.newEnd - h.newStart
  let os0 = h.newStart - off
  let rel = relativePath(b.path, root).replace('\\', '/')
  var patch = "--- a/" & rel & "\n+++ b/" & rel & "\n@@ -" &
              (if oldLen > 0: $(os0 + 1) & "," & $oldLen else: $os0 & ",0") & " +" &
              (if newLen > 0: $(os0 + 1) & "," & $newLen else: $os0 & ",0") & " @@\n"
  for x in h.old: patch.add "-" & x & "\n"
  for l in h.newStart ..< h.newEnd: patch.add "+" & b.lines[l] & "\n"
  let pf = privTmp("stage") & ".patch"
  try: writeFile(pf, patch)
  except IOError, OSError:
    error("Could not write the patch")
    return
  let id = b.id
  discard startJob(jkGit, "git apply --cached --unidiff-zero " & quoteShell(pf), root, proc(j: Job) =
    removeFile(pf)
    if j.code != 0:
      error("git could not stage this change: " & j.output.strip.splitLines()[0])
      return
    info("Change staged — palette › Git: unstage this file undoes it")
    let b = bufById(id)
    if b != nil: b.refreshGit()
    refreshGitStatus())

proc unstageFile() =
  let b = buf()
  if b.path.len == 0: return
  let id = b.id
  let name = extractFilename(b.path)          # the tab may be closed before git answers
  discard startJob(jkGit, "git reset -q -- " & quoteShell(b.path), parentDir(b.path), proc(j: Job) =
    if j.code != 0:
      error("git reset failed: " & j.output.strip)
      return
    info("Unstaged " & name)
    let b = bufById(id)
    if b != nil: b.refreshGit()
    refreshGitStatus())

proc hunkActions() =
  ## clicking a change mark in the gutter: see it, stage it or revert it
  showHunk()
  openActions("Change", @[act("Stage this change", "git add just this part", proc() = stageHunk()),
                          act("Revert this change", "back to the committed text", proc() = revertHunk()),
                          act("Show the change", "", proc() = showHunk())])

proc revertHunk() =
  let b = buf()
  if not b.canEdit(): return
  let k = b.hunkAtCursor()
  if k < 0:
    info("The cursor is not on a changed line")
    return
  let h = b.gitHunks()[k]
  let oldText = h.old.join("\n")
  b.beginEdit()
  if h.newEnd > h.newStart:
    if h.old.len > 0:
      discard b.replaceText(Pos(line: h.newStart, col: 0), Pos(line: h.newEnd - 1, col: b.lines[h.newEnd - 1].len), oldText)
    elif h.newEnd < b.lines.len:
      discard b.replaceText(Pos(line: h.newStart, col: 0), Pos(line: h.newEnd, col: 0), "")
    elif h.newStart > 0:
      discard b.replaceText(Pos(line: h.newStart - 1, col: b.lines[h.newStart - 1].len),
                            Pos(line: h.newEnd - 1, col: b.lines[h.newEnd - 1].len), "")
    else:
      discard b.replaceText(Pos(), Pos(line: h.newEnd - 1, col: b.lines[h.newEnd - 1].len), "")
  else:
    if h.newStart < b.lines.len:
      discard b.replaceText(Pos(line: h.newStart, col: 0), Pos(line: h.newStart, col: 0), oldText & "\n")
    else:
      let l = b.lines.high
      discard b.replaceText(Pos(line: l, col: b.lines[l].len), Pos(line: l, col: b.lines[l].len), "\n" & oldText)
  b.endEdit()
  b.normalize()
  info("Change reverted — Ctrl+Z brings it back")

# the whole file's blame, once for each version of it and of the history (the line under the cursor is then
# looked up, not asked of git at every move)
type BlameAll = object
  key: string                    # the file's time, the history's (.git/logs/HEAD), when it was made
  at: MonoTime
  lineCommit: seq[int32]         # each line's commit (an index in commits)
  commits: seq[(string, string, int64)]   # (author, summary, time) — author "" when not committed yet
var
  blameAll: Table[string, BlameAll]
  blameAllBusy: HashSet[string]

proc blameAllKey(path: string): string =
  try:
    var key = $getLastModificationTime(path).toUnixFloat
    let g = findGitRoot(parentDir(path))
    if g.len > 0 and fileExists(g / ".git" / "logs" / "HEAD"):
      key.add "|" & $getLastModificationTime(g / ".git" / "logs" / "HEAD").toUnixFloat
    key
  except CatchableError: ""

proc parseBlameAll(o: string, key: string): BlameAll =
  result.key = key
  result.at = getMonoTime()
  var byHash: Table[string, int]
  var cur = -1
  var final = 0
  for ln in o.splitLines:
    if ln.len == 0: continue
    if ln[0] == '\t':
      if cur >= 0 and final > 0:
        if result.lineCommit.len < final: result.lineCommit.setLen(final)
        result.lineCommit[final - 1] = int32(cur)
      continue
    if ln.len >= 41 and ln[40] == ' ' and ln[0 ..< 40].allCharsInSet(HexDigits):
      let h = ln[0 ..< 40]
      let parts = ln.splitWhitespace
      final = (if parts.len >= 3: (try: parseInt(parts[2]) except ValueError: 0) else: 0)
      cur = byHash.getOrDefault(h, -1)
      if cur < 0:
        cur = result.commits.len
        byHash[h] = cur
        result.commits.add (if h.startsWith("0000000"): ("", "", 0'i64) else: ("?", "", 0'i64))
      continue
    if cur < 0 or result.commits[cur][0].len == 0: continue
    if ln.startsWith("author "): result.commits[cur][0] = ln[7 .. ^1]
    elif ln.startsWith("author-time "):
      try: result.commits[cur][2] = parseBiggestInt(ln[12 .. ^1].strip).int64
      except ValueError: discard
    elif ln.startsWith("summary "): result.commits[cur][1] = ln[8 .. ^1]

proc blameLineText(ba: BlameAll, l: int): string =
  if l < 0 or l >= ba.lineCommit.len: return ""
  let c = ba.commits[ba.lineCommit[l]]
  if c[0].len == 0: "You · not committed" else: c[0] & ", " & agoText(c[2] * 1000) & " · " & c[1]

proc requestBlame(b: Buffer) =
  if not cfgBlame or b.path.len == 0 or not b.inGit or b.binary: return
  let l = b.primary.head.line
  let key = b.path & ":" & $l & ":" & $b.changeId
  if key == blameFor: return
  if b.dirty and b.git.len > l and b.git[l] in {1'u8, 2'u8}:
    blameFor = key
    blameText = "You · not committed"
    return
  if b.dirty:
    blameFor = key
    blameText = ""
    return
  # (the whole file's, when it is made for this version: at once)
  if b.path in blameAll:
    let ba = blameAll[b.path]
    if msSince(ba.at) < 60_000 and ba.key == blameAllKey(b.path):
      blameFor = key
      blameText = ba.blameLineText(l)
      return
  if msSince(blameReqAt) < 350: return
  blameReqAt = getMonoTime()
  blameFor = key
  blameText = ""
  if b.lines.len <= 20000 and b.path notin blameAllBusy and remoteOf(b.path) < 0:
    let path = b.path
    let bkey = blameAllKey(path)
    blameAllBusy.incl path
    discard startJob(jkGit, "git --no-pager blame --porcelain -- " & quoteShell(extractFilename(path)), parentDir(path),
                     proc(j: Job) =
      blameAllBusy.excl path
      if j.code != 0: return
      if blameAll.len > 16: blameAll.clear()
      blameAll[path] = parseBlameAll(j.output, bkey)
      blameFor = ""                      # (asked again, now from it)
      needRender = true)
  let cmd = "git --no-pager blame --porcelain -L " & $(l + 1) & "," & $(l + 1) & " -- " &
            quoteShell(extractFilename(b.path))
  discard startJob(jkGit, cmd, parentDir(b.path), proc(j: Job) =
    if blameFor != key or j.code != 0: return
    var author, summary, hash = ""
    var t = 0'i64
    for ln in j.output.splitLines:
      if hash.len == 0 and ln.len >= 40: hash = ln[0 ..< 40]
      elif ln.startsWith("author "): author = ln[7 .. ^1]
      elif ln.startsWith("author-time "):
        try: t = parseBiggestInt(ln[12 .. ^1].strip).int64
        except ValueError: discard
      elif ln.startsWith("summary "): summary = ln[8 .. ^1]
    if hash.startsWith("0000000"): blameText = "You · not committed"
    elif author.len > 0:
      blameText = author & ", " & agoText(t * 1000) & " · " & summary
    needRender = true)
