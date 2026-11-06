# ── the Git changes view (Git › Changes…, Alt+Shift+G): every change not committed yet, in every file, in one
#    editable multibuffer — each change with a line or two around it, its header saying what it adds and removes and
#    whether it is staged. Edit there and Ctrl+S writes back; stage, unstage or revert the change at the cursor
#    (right-click, or the palette); Enter on a header opens the file there ──

type
  GcHunk = object
    ## one change: lines oldStart ..< oldStart+oldLen of one version become newStart ..< newStart+newLen of another
    ## (0-based; a hunk adding lines has oldLen 0, one removing them newLen 0: then newStart is where they were)
    oldStart, oldLen, newStart, newLen: int
    old, new: seq[string]
    raw: string            # its text in the patch (the @@ line and the lines after it)
  GcFile = object
    path, rel, root: string
    head, cached, work: seq[GcHunk]    # HEAD → working tree, HEAD → index, index → working tree
    untracked: bool
var
  gcViews: Table[int, seq[GcFile]]     # a changes view's buffer id → the files it was made from
  gcBusy = false
  gcAgain: tuple[on: bool, at: Pos]    # (made again after a stage, an unstage…: quietly, the cursor where it was)

const GcMark = "@@@ned-changes@@@"
const GcEmptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

proc gcParse(text: string, files: var Table[string, seq[GcHunk]]) =
  ## a `git diff -U0` (no colour, no renames) → its hunks by file (repository-relative path)
  var cur = ""
  var h: GcHunk
  var inHunk = false
  template flush() =
    ## stores the hunk read so far under its file, if there is one
    if inHunk and cur.len > 0: files.mgetOrPut(cur, @[]).add h
    inHunk = false
  for line in text.split('\n'):
    if line.startsWith("diff --git "):
      flush()
      cur = ""
    elif line.startsWith("+++ "):
      let p = line[4 .. ^1]
      if p != "/dev/null": cur = (if p.startsWith("b/"): p[2 .. ^1] else: p)
    elif line.startsWith("--- "):
      let p = line[4 .. ^1]
      if p != "/dev/null" and cur.len == 0: cur = (if p.startsWith("a/"): p[2 .. ^1] else: p)
    elif line.startsWith("@@ "):
      flush()
      let f = line.splitWhitespace()
      if f.len < 3: continue
      proc rng(x: string): (int, int) =
        ## reads a range of a hunk header (`-12,3` or `+7`) as (first line, number of lines); a missing count is 1
        let q = x[1 .. ^1].split(',')
        (parseInt(q[0]), (if q.len > 1: parseInt(q[1]) else: 1))
      try:
        let (os, ol) = rng(f[1])
        let (ns, nl) = rng(f[2])
        # (git counts from 1; a range of 0 lines names the line before it)
        h = GcHunk(oldStart: (if ol == 0: os else: os - 1), oldLen: ol, newStart: (if nl == 0: ns else: ns - 1),
                   newLen: nl, raw: line & "\n")
        inHunk = true
      except ValueError: discard
    elif inHunk and line.len > 0 and line[0] in {'-', '+', '\\'}:
      h.raw.add line & "\n"
      if line[0] == '-': h.old.add line[1 .. ^1]
      elif line[0] == '+': h.new.add line[1 .. ^1]
  flush()

func gcOverlap(a, al, b, bl: int): bool =
  ## do lines a ..< a+al and b ..< b+bl meet (a range of 0 lines as the place between two lines)
  let ae = a + max(al, 1)
  let be = b + max(bl, 1)
  a < be and b < ae

proc gcStaged(f: GcFile, h: GcHunk): int =
  ## 0: not staged · 1: partly · 2: staged
  var inIndex = false
  var inWork = false
  for c in f.cached:
    if gcOverlap(c.oldStart, c.oldLen, h.oldStart, h.oldLen): inIndex = true
  for w in f.work:
    if gcOverlap(w.newStart, w.newLen, h.newStart, h.newLen): inWork = true
  if f.untracked: 0
  elif inIndex and not inWork: 2
  elif inIndex: 1
  else: 0

proc gcCommand(root: string, path = ""): string =
  ## the diffs a view (or one file's change) needs, in one run: against HEAD (the empty tree in a repository
  ## without commits), staged, not staged — and the files git does not track yet
  let only = if path.len > 0: " -- " & quoteShell(path) else: ""
  let base = "$(git rev-parse -q --verify HEAD >/dev/null 2>&1 && echo HEAD || echo " & GcEmptyTree & ")"
  let d = "git --no-pager diff --no-color --no-ext-diff --no-renames -U0 "
  d & base & only & "; echo " & GcMark & "; " & d & "--cached " & base & only & "; echo " & GcMark & "; " & d & only &
    "; echo " & GcMark & "; git ls-files --others --exclude-standard" & only

proc gcFilesOf(root, output: string): seq[GcFile] =
  ## turns the output of gcCommand into files with their hunks: the three diffs (against HEAD, staged, not staged) are
  ## matched up by file name, and the files git does not track yet (up to 60, text files under 1 MB) come as one hunk
  ## holding all their lines
  let parts = output.split(GcMark & "\n")
  if parts.len < 4: return
  var head, cached, work: Table[string, seq[GcHunk]]
  gcParse(parts[0], head)
  gcParse(parts[1], cached)
  gcParse(parts[2], work)
  var names: seq[string]
  for k in head.keys: names.add k
  names.sort()
  for rel in names:
    result.add GcFile(path: root / rel, rel: rel, root: root, head: head[rel], cached: cached.getOrDefault(rel),
                      work: work.getOrDefault(rel))
  var untracked = 0
  for rel in parts[3].splitLines:
    if rel.strip.len == 0 or rel in head: continue
    inc untracked
    if untracked > 60: break                   # (a folder of build output nobody ignored: not every file of it)
    let p = root / rel
    var ls: seq[string]
    try:
      if getFileSize(p) > 1_000_000: continue
      let t = readFile(p)
      if '\0' in t[0 ..< min(t.len, 8000)]: continue
      ls = t.split('\n')
      if ls.len > 0 and ls[^1].len == 0: ls.setLen(ls.len - 1)
    except CatchableError: continue
    result.add GcFile(path: p, rel: rel, root: root, untracked: true,
                      head: @[GcHunk(oldStart: 0, oldLen: 0, newStart: 0, newLen: ls.len, new: ls)])

proc gcNote(f: GcFile, hs: seq[GcHunk]): string =
  ## the note in a change's header: the lines it adds and removes, and whether the change is staged, partly staged or
  ## not staged (or a new file git does not track)
  var adds, dels, staged, notStaged = 0
  for h in hs:
    adds += h.newLen
    dels += h.oldLen
    case f.gcStaged(h)
    of 2: inc staged
    of 1:
      inc staged
      inc notStaged
    else: inc notStaged
  result = (if adds > 0: "+" & $adds else: "") & (if adds > 0 and dels > 0: " " else: "") &
           (if dels > 0: "−" & $dels else: "")
  if f.untracked: result.add " · new file, not tracked"
  elif staged > 0 and notStaged == 0: result.add " · staged"
  elif staged > 0: result.add " · partly staged"
  else: result.add " · not staged"

proc gcShow(files: seq[GcFile], reuse = -1) =
  ## the view: each file's changes with a line around them (changes close together: one piece)
  var secs: seq[MbSection]
  var marks: seq[(int, int, uint8)]       # (section, line in it, mark): the change marks in the gutter
  var dirty: seq[string]
  for f in files:
    let bi = bufIndexByPath(f.path)
    var ls: seq[string]
    if bi >= 0 and bufs[bi].dirty:
      dirty.add f.rel
      continue
    ls = fileLinesNow(f.path)              # (a closed file: as a buffer has it — no empty line after the last)
    if ls.len == 0: continue
    var hs = f.head
    hs.sort(proc(x, y: GcHunk): int = cmp(x.newStart, y.newStart))
    var k = 0
    while k < hs.len:
      let a = max(0, hs[k].newStart - 1)
      var e = min(ls.high, hs[k].newStart + max(hs[k].newLen, 1))
      if f.untracked: e = min(e, a + 199)        # (a new file: its start)
      var group = @[hs[k]]
      inc k
      while k < hs.len and max(0, hs[k].newStart - 1) <= e + 1:
        e = max(e, min(ls.high, hs[k].newStart + max(hs[k].newLen, 1)))
        group.add hs[k]
        inc k
      if a > e or a > ls.high: continue
      let si = secs.len
      secs.add MbSection(path: f.path, start: a, orig: ls[a .. e], note: f.gcNote(group))
      for h in group:
        if h.newLen == 0:
          let at = clamp(h.newStart - 1, a, e) - a
          marks.add (si, at, 3'u8)
        else:
          for l in h.newStart ..< h.newStart + h.newLen:
            if l >= a and l <= e: marks.add (si, l - a, (if h.oldLen > 0: 2'u8 else: 1'u8))
  if secs.len == 0:
    gcAgain.on = false
    info(if dirty.len > 0: "Only unsaved changes (" & dirty.join(", ") & ") — save them, then open the view again"
         else: "No changes: everything is committed")
    return
  let lang = detectLang(secs[0].path, "")
  var text: seq[string]
  var start: seq[int]
  for sc in secs:
    text.add mbHeaderOf(lang, sc)
    start.add text.len
    text.add sc.orig
  let b = openScratch("Git: changes", mbTextOf(text), lang)
  b.readOnly = false
  b.savedSeq = b.topSeq()
  multiBufs[b.id] = secs
  gcViews[b.id] = files
  b.git = newSeq[uint8](b.lines.len)
  for (si, l, m) in marks:
    let at = start[si] + l
    if at < b.git.len: b.git[at] = m
  if gcAgain.on:
    gcAgain.on = false
    b.setSingle(b.clampPos(gcAgain.at))
    return
  var nFiles: HashSet[string]
  for sc in secs: nFiles.incl sc.path
  info($secs.len & (if secs.len == 1: " change in " else: " changes in ") & $nFiles.len &
       (if nFiles.len == 1: " file" else: " files") & " — edit here (Ctrl+S writes back) · right-click: stage, unstage, " &
       "revert" & (if dirty.len > 0: " · not shown, unsaved: " & dirty.join(", ") else: ""))

var
  gcPending: seq[GcFile]          # (the repositories answered so far)
  gcLeft = 0

proc gcAsk(root: string) =
  ## asks git, in one repository, for the diffs of the changes view; when every repository has answered, shows the view
  discard startJob(jkGit, gcCommand(root), root, proc(j: Job) =
    dec gcLeft
    gcPending.add gcFilesOf(root, j.output)
    if gcLeft <= 0:
      gcBusy = false
      gcShow(gcPending))

proc cmdGitChanges() =
  ## Git › Changes…: the view, made again from git
  let roots = gitRepoRoots()
  if roots.len == 0:
    info("No git repository here")
    return
  if gcBusy: return
  gcBusy = true
  gcPending = @[]
  gcLeft = roots.len
  for r in roots: gcAsk(r)

proc gcRefreshViews() =
  ## (after a change was staged, reverted or written back) the open view made again
  for b in bufs:
    if b.id in gcViews and b.title == "Git: changes":
      if not b.dirty:
        gcAgain = (true, b.primary.head)
        cmdGitChanges()
      return

proc gcPlace(b: Buffer, line: int): (bool, string, int) =
  ## the file and its line behind a line of a multibuffer
  let secs = multiBufs.getOrDefault(b.id)
  var k = -1
  var base = 0
  for l in 0 .. min(line, b.lines.high):
    if k + 1 < secs.len and b.lines[l] == mbHeaderOf(b.lang, secs[k + 1]):
      inc k
      base = l + 1
  if k < 0: return
  if line < base: return (true, secs[k].path, secs[k].start)
  (true, secs[k].path, secs[k].start + (line - base))

proc gcApply(root, rel: string, hunks: seq[GcHunk], args, done: string, then: proc() {.closure.} = nil) =
  ## git apply (args) of these hunks of a file
  if hunks.len == 0:
    if then != nil: then()
    return
  var patch = "--- a/" & rel & "\n+++ b/" & rel & "\n"
  for h in hunks: patch.add h.raw
  let pf = privTmp("changes") & ".patch"
  try: writeFile(pf, patch)
  except IOError, OSError:
    error("Could not write the patch")
    return
  discard startJob(jkGit, "git apply " & args & " --unidiff-zero " & quoteShell(pf), root, proc(j: Job) =
    removeFile(pf)
    if j.code != 0:
      let msg = j.output.strip.splitLines()
      error("git could not " & done & ": " & (if msg.len > 0: msg[0] else: "it failed"))
      return
    if then != nil: then())

proc gcAfter(path, said: string) =
  ## after a stage, unstage or revert: says what was done, refreshes the change marks of the file if it is open and the
  ## git status, and makes the open changes view again
  info(said)
  let i = bufIndexByPath(path)
  if i >= 0: bufs[i].refreshGit()
  refreshGitStatus()
  gcRefreshViews()

proc gcWriteLines(path: string, h: GcHunk) =
  ## the working tree's lines of a change back to HEAD's (the open buffer edited, saved if it had no other changes)
  let bi = bufIndexByPath(path)
  let a = h.newStart
  if bi >= 0:
    let b = bufs[bi]
    let wasDirty = b.dirty
    b.beginEdit()
    if h.newLen > 0:
      let e = min(b.lines.high, a + h.newLen - 1)
      if h.oldLen > 0: discard b.replaceText(Pos(line: a, col: 0), Pos(line: e, col: b.lines[e].len), h.old.join("\n"))
      elif e < b.lines.high: discard b.replaceText(Pos(line: a, col: 0), Pos(line: e + 1, col: 0), "")
      elif a > 0: discard b.replaceText(Pos(line: a - 1, col: b.lines[a - 1].len), Pos(line: e, col: b.lines[e].len), "")
      else: discard b.replaceText(Pos(), Pos(line: e, col: b.lines[e].len), "")
    elif a < b.lines.len: discard b.replaceText(Pos(line: a, col: 0), Pos(line: a, col: 0), h.old.join("\n") & "\n")
    else:
      let l = b.lines.high
      discard b.replaceText(Pos(line: l, col: b.lines[l].len), Pos(line: l, col: b.lines[l].len), "\n" & h.old.join("\n"))
    b.endEdit()
    b.normalize()
    if not wasDirty: discard b.saveBuffer()
    return
  var t = ""
  try: t = readFile(path)
  except CatchableError: return
  let endNl = t.endsWith("\n")
  var ls = t.split('\n')
  if endNl: ls.setLen(ls.len - 1)
  ls = ls[0 ..< min(a, ls.len)] & h.old & ls[min(ls.len, a + h.newLen) .. ^1]
  try:
    writeFile(path, ls.join("\n") & (if endNl or ls.len > 0: "\n" else: ""))
    fileWritten(path)
  except IOError, OSError: error("Could not write " & relPath(path))

proc gcAct(path: string, line: int, what: string) =
  ## stage, unstage or revert the change at a line of a file (from git's diffs of it now)
  let root = findGitRoot(parentDir(path))
  if root.len == 0:
    info("Not in a git repository")
    return
  let rel = relativePath(path, root).replace('\\', '/')
  discard startJob(jkGit, gcCommand(root, rel), root, proc(j: Job) =
    let fs = gcFilesOf(root, j.output)
    if fs.len == 0:
      info("No change there")
      return
    let f = fs[0]
    var h = GcHunk(newStart: -1)
    for x in f.head:
      if (line >= x.newStart and line < x.newStart + x.newLen) or
         (x.newLen == 0 and (line == x.newStart or line + 1 == x.newStart)):
        h = x
        break
    if h.newStart < 0:
      info("The cursor is not on a change")
      return
    var cached, work: seq[GcHunk]
    for c in f.cached:
      if gcOverlap(c.oldStart, c.oldLen, h.oldStart, h.oldLen): cached.add c
    for w in f.work:
      if gcOverlap(w.newStart, w.newLen, h.newStart, h.newLen): work.add w
    case what
    of "stage":
      if f.untracked:
        discard startJob(jkGit, "git add -- " & quoteShell(rel), root, proc(j: Job) =
          if j.code != 0: error("git add failed: " & j.output.strip)
          else: gcAfter(path, "Added " & rel & " to the index"))
      elif work.len == 0: info("Already staged")
      else: gcApply(root, rel, work, "--cached", "stage this change", proc() = gcAfter(path, "Change staged"))
    of "unstage":
      if cached.len == 0: info("Nothing of this change is staged")
      else:
        gcApply(root, rel, cached, "--cached -R", "unstage this change", proc() = gcAfter(path, "Change unstaged"))
    else:
      if f.untracked:
        info("A new file: delete it to revert it (Files › Delete)")
        return
      # back to HEAD's text: what is staged of it unstaged, then the lines put back
      gcApply(root, rel, cached, "--cached -R", "unstage this change", proc() =
        gcWriteLines(path, h)
        gcAfter(path, "Change reverted to the last commit's text")))

proc gcActHere(what: string): bool =
  ## in a changes view (or any multibuffer): the change at the cursor; false when the editor is no multibuffer
  let b = buf()
  if b.id notin multiBufs: return false
  if b.dirty:
    info("Save the view first (Ctrl+S writes your edits to the files), then " & what)
    return true
  let (ok, path, line) = b.gcPlace(b.primary.head.line)
  if not ok:
    info("The cursor is not in a piece of a file")
    return true
  gcAct(path, line, what)
  true

proc cmdGitUnstageHere() =
  ## Git: unstage the change at the cursor (in a file, or the changes view)
  if gcActHere("unstage"): return
  let b = buf()
  if b.path.len == 0: return
  if b.dirty:
    info("Save first: the staged text is compared with the saved file")
    return
  gcAct(b.path, b.primary.head.line, "unstage")

proc gcAfterSave(b: Buffer) =
  ## (a changes view written back: made again, its changes are others now)
  if b.id in gcViews:
    gcAgain = (true, b.primary.head)
    cmdGitChanges()
