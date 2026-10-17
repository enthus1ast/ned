# ── Format every file of a folder (or the project): each with what Alt+F would use, reviewed before anything
#    is written ──

var
  fmtAllQueue: seq[string]                      # files still to look at
  fmtAllChanges: seq[(string, string, string, string)]   # (path, text now, formatted, by what)
  fmtAllLeft: seq[(string, string)]             # (path, why it was left alone)
  fmtAllTotal = 0
  fmtAllDir = ""
  fmtAllOn = false
  fmtAllUndo: seq[(string, string)]             # files on disk the last apply changed: (path, old text)
  fmtAllUndoBufs: seq[(int, int)]               # open files it changed: (buffer id, undo step)

proc fmtHowFor(path: string): (string, string) =
  ## how a file gets formatted: ("builtin", kind) · ("cmd", command) · ("", "") when nothing formats it
  let lang = detectLang(path, "")
  let bk = builtinFmtKind(path, lang.id)
  if bk == "nim":
    if lang.id in cfgUserFmt:
      let c = cfgUserFmt[lang.id]
      let w = c.splitWhitespace
      return (if w.len > 0 and haveExe(w[0]) and "$in" notin c: ("cmd", c) else: ("", ""))
    case cfgNimFormatter
    of "nph": return (if haveExe("nph"): ("cmd", "nph -") else: ("", ""))
    of "nimpretty": return ("", "")
    else: return ("builtin", "nim")
  if lang.id in cfgUserFmt:
    let c = cfgUserFmt[lang.id]
    let w = c.splitWhitespace
    if w.len > 0 and haveExe(w[0]) and "$in" notin c: return ("cmd", c)
  for c in lang.fmt:
    let w = c.splitWhitespace
    if w.len > 0 and haveExe(w[0]) and "$in" notin c: return ("cmd", c)
  if bk.len > 0: return ("builtin", bk)
  ("", "")

proc formatTextOf(b: Buffer): (string, string, string) =
  ## (what the formatter would make of the buffer, why it cannot, by what) — without changing the buffer
  let text = b.allText & "\n"
  let (how, what) = fmtHowFor(b.path)
  if how.len == 0 or what.strip.len == 0: return (text, "nothing formats " & b.lang.name & " here", "")
  if how == "builtin":
    let (res, err) = builtinFormatText(what, text, b.indentW(), b.path)
    return (res, err, "built-in")
  let cmd = what.replace("$file", b.path).replace("$dir", parentDir(b.path)).replace("$name", splitFile(b.path).name)
  let (ok, o, e) = runFilter(cmd, text, (if b.path.len > 0: parentDir(b.path) else: rootDir))
  if ok and o.strip.len > 0:
    return ((if b.lang.mode == lmNim: formatEmitBlocks(o, b.path)[0] else: o), "", what.firstWord)
  let first = (e & o).strip.splitLines
  (text, what.firstWord & ": " & (if first.len > 0: first[0] else: "failed"), what.firstWord)

proc cmdFormatPreview() =
  ## what formatting would change, side by side — then apply it (all, or where you changed lines) or leave it
  let b = buf()
  if b.path.len == 0 and b.title.len > 0:
    info("Nothing to format here")
    return
  let (res, err, by) = formatTextOf(b)
  if err.len > 0:
    error("Format: " & err)
    return
  let now = b.lines
  let after = res.strip(leading = false, chars = {'\n'}).split('\n')
  if after == now:
    info("Already formatted")
    return
  let (adds, dels) = diffStats(lineDiff(now, after))
  let id = b.id
  let ch = b.changeId
  openDiffView(relPath(b.path), now, "now", nil, after, "formatted (" & by & ")", b.lang)
  let dvId = buf().id
  proc back() =
    # the side-by-side view closed, the file in front again
    let dv = bufById(dvId)
    if dv != nil and dv.id != id:
      let k = bufs.find(dv)
      if k >= 0: closeBufferAt(k)
    let x = bufById(id)
    if x != nil and x.path.len > 0: discard openFile(x.path)
  proc apply(onlyChanged: bool) =
    let x = bufById(id)
    back()
    if x == nil or not x.canEdit(): return
    if x.changeId != ch:
      info("The file changed since — preview it again")
      return
    var target = after
    if onlyChanged:
      let (known, changed) = changedLineSet(x)
      if known: target = keepFormatOf(now, after, changed)
    x.setTextMinimal(target.join("\n"))
    info("Formatted" & (if onlyChanged: " where you changed lines" else: ""))
  openActions("Format " & extractFilename(b.path) & ": +" & $adds & " −" & $dels & " lines (" & by & ")", @[
    act("Apply it", "the whole file", proc() = apply(false)),
    act("Apply only where I changed lines", "since git last saw the file", proc() = apply(true)),
    act("Leave it", "nothing changes", proc() =
      back()
      info("Left as it is"))])

proc fmtAllFiles(dir: string): seq[string] =
  ## the files under `dir` worth formatting: git's list when it is a repository (what .gitignore leaves out
  ## stays out), else a walk that skips node_modules, nimcache, build folders and hidden ones
  let gr = findGitRoot(dir)
  if gr.len > 0 and haveExe("git"):
    let (ok, o, _) = runFilter("git ls-files -z --cached --others --exclude-standard -- " & quoteShell(dir), "", gr, 20000)
    if ok:
      for f in o.split('\0'):
        if f.len == 0: continue
        # (what git does not ignore, but no node_modules, nimcache, build output or hidden folder all the same)
        var skip = false
        for part in f.split('/')[0 ..< ^1]:
          if part.startsWith(".") or part in SkipDirs or part in cfgExclude: skip = true
        if skip: continue
        let p = if f.isAbsolute: f else: gr / f
        if fileExists(p): result.add p
      result.sort()
      return
  var stack = @[dir]
  while stack.len > 0 and result.len < 20000:
    let d = stack.pop()
    try:
      for kind, p in walkDir(d):
        let nm = extractFilename(p)
        if nm.startsWith("."): continue
        if kind == pcDir:
          if nm notin SkipDirs and nm notin cfgExclude: stack.add p
        elif kind in {pcFile, pcLinkToFile}: result.add p
    except OSError: discard
  result.sort()

proc fmtAllReview()

proc cmdFormatAll(dir0 = "") =
  ## look at every file of the folder (the project by default) with its formatter; nothing is written until
  ## the changes are reviewed
  let dir = if dir0.len > 0: dir0 else: rootDir
  if fmtAllOn:
    info("Already formatting " & relPath(fmtAllDir) & " — " & $(fmtAllTotal - fmtAllQueue.len) & " of " & $fmtAllTotal)
    return
  fmtAllQueue.setLen(0)
  fmtAllChanges.setLen(0)
  fmtAllLeft.setLen(0)
  for p in fmtAllFiles(dir):
    let (how, _) = fmtHowFor(p)
    if how.len > 0: fmtAllQueue.add p
  if fmtAllQueue.len == 0:
    info("Nothing to format in " & (if dir == rootDir: "the project" else: relPath(dir)) &
         " (ned formats Nim, JSON, Markdown and CSS itself; other languages need their formatter installed)")
    return
  fmtAllDir = dir
  fmtAllTotal = fmtAllQueue.len
  fmtAllOn = true
  fmtAllQueue.reverse()                       # (taken from the end: the first file first)
  info("Formatting " & $fmtAllTotal & " file(s) in " & (if dir == rootDir: "the project" else: relPath(dir)) & "…")
  needRender = true

proc fmtAllPump(budgetMs: int) =
  ## a few files per slice (the editor stays usable); the review opens when all are done
  if not fmtAllOn: return
  let t0 = getMonoTime()
  while fmtAllQueue.len > 0 and msSince(t0) < budgetMs:
    let p = fmtAllQueue.pop()
    var text = ""
    let bi = bufIndexByPath(p)
    if bi >= 0: text = bufs[bi].allText & "\n"           # an open file: what is in the editor
    else:
      try:
        if getFileSize(p) > 2_000_000:
          fmtAllLeft.add (p, "too big")
          continue
        text = readFile(p)
      except CatchableError as e:
        fmtAllLeft.add (p, e.msg)
        continue
    if text.len == 0 or '\0' in text[0 ..< min(text.len, 4000)]: continue
    let (how, what) = fmtHowFor(p)
    if how.len == 0 or what.strip.len == 0: continue     # (nothing formats it now: a setting changed meanwhile)
    var res = ""
    var err = ""
    var by = ""
    if how == "builtin":
      let iw = if bi >= 0: bufs[bi].indentW() else: 2
      (res, err) = builtinFormatText(what, text, iw, p)
      by = "built-in"
    else:
      let cmd = what.replace("$file", p).replace("$dir", parentDir(p)).replace("$name", splitFile(p).name)
      let (ok, o, e) = runFilter(cmd, text, parentDir(p))
      by = what.firstWord
      if ok and o.strip.len > 0: res = o
      else:
        let first = (e & o).strip.splitLines
        err = by & ": " & (if first.len > 0: first[0] else: "failed")
    if err.len > 0:
      fmtAllLeft.add (p, err)
      continue
    if res != text: fmtAllChanges.add (p, text, res, by)
  needRender = true
  if fmtAllQueue.len == 0:
    fmtAllOn = false
    if fmtAllChanges.len == 0:
      info("All " & $fmtAllTotal & " file(s) are formatted already" &
           (if fmtAllLeft.len > 0: " (" & $fmtAllLeft.len & " left alone: " & relPath(fmtAllLeft[0][0]) & " — " &
                                   fmtAllLeft[0][1] & ")" else: ""))
    else: fmtAllReview()

proc fmtAllApply(which: seq[int]) =
  ## write the formatted text: open files change in the editor (save them), the others on disk (with a copy
  ## kept in the local history; the toast's Undo puts them back)
  fmtAllUndo.setLen(0)
  fmtAllUndoBufs.setLen(0)
  var n = 0
  var errs: seq[string]
  for k in which:
    let (p, before, after, _) = fmtAllChanges[k]
    let bi = bufIndexByPath(p)
    if bi >= 0:
      let b = bufs[bi]
      if b.allText & "\n" != before:
        errs.add relPath(p) & " (changed since)"
        continue
      b.setTextMinimal(after)
      fmtAllUndoBufs.add (b.id, b.topSeq())
      inc n
    else:
      try:
        if readFile(p) != before:
          errs.add relPath(p) & " (changed since)"
          continue
        snapshotHistory(p)
        writeFileSafe(p, after)
        fmtAllUndo.add (p, before)
        inc n
      except CatchableError as e: errs.add relPath(p) & ": " & e.msg
  var keep: seq[(string, string, string, string)]
  for k, c in fmtAllChanges:
    if k notin which: keep.add c
  fmtAllChanges = keep
  if errs.len > 0: warn("Not formatted: " & errs.join(", "))
  if n > 0:
    toast("Formatted " & $n & " file(s)" & (if fmtAllUndoBufs.len > 0: " — the open ones in the editor: save them" else: ""),
          5, "Undo", proc() =
            var m = 0
            for (path, old) in fmtAllUndo:
              try:
                snapshotHistory(path)
                writeFileSafe(path, old)
                inc m
              except CatchableError as e: error(path & ": " & e.msg)
            for (id, sq) in fmtAllUndoBufs:
              let b = bufById(id)
              if b != nil and b.topSeq() == sq:
                b.undo()
                inc m
            fmtAllUndo.setLen(0)
            fmtAllUndoBufs.setLen(0)
            info("Put back " & $m & " file(s) as they were"), 30000)
  refreshTree()

proc fmtAllFileAct(k: int): Action =
  ## one file of the review: see the change, take it, or leave it
  result = proc() =
    if k >= fmtAllChanges.len: return
    let (p, before, after, by) = fmtAllChanges[k]
    openActions(relPath(p) & " — formatted by " & by, @[
      act("Show what changes", "side by side", proc() =
        let lang = detectLang(p, "")
        openDiffView(relPath(p), before.strip(leading = false, chars = {'\n'}).split('\n'), "now", nil,
                     after.strip(leading = false, chars = {'\n'}).split('\n'), "formatted", lang)
        info("Format: review the project's changes takes you back to the list")),
      act("Format this file", "", proc() =
        fmtAllApply(@[k])
        if fmtAllChanges.len > 0: fmtAllReview()),
      act("Leave it as it is", "", proc() =
        fmtAllChanges.delete(k)
        if fmtAllChanges.len > 0: fmtAllReview())])

proc fmtAllReview() =
  if fmtAllOn:
    info("Still formatting: " & $(fmtAllTotal - fmtAllQueue.len) & " of " & $fmtAllTotal)
    return
  if fmtAllChanges.len == 0:
    info("Nothing waiting — Format: every file in the project looks again")
    return
  var items: seq[(string, string, Action)]
  var all: seq[int]
  for k in 0 ..< fmtAllChanges.len: all.add k
  let left = if fmtAllLeft.len > 0: " · " & $fmtAllLeft.len & " left alone" else: ""
  items.add act("Format all " & $fmtAllChanges.len & " file(s)", "y" & left, proc() = fmtAllApply(all))
  for k, (p, before, after, by) in fmtAllChanges:
    let a = before.count('\n')
    let b2 = after.count('\n')
    items.add act(relPath(p), by & " · " & $a & " → " & $b2 & " lines", fmtAllFileAct(k))
  if fmtAllLeft.len > 0:
    var why: seq[string]
    for (p, w) in fmtAllLeft: why.add relPath(p) & ": " & w
    items.add act("Left alone: " & $fmtAllLeft.len & " file(s)", why[0], proc() =
      setPanel(pkOutput)
      panelLines = @[PanelLine(text: "Format — files left alone", sev: 5, line: -1)]
      for w in why: panelLines.add PanelLine(text: w, sev: 2, line: -1))
  openActions("Format — " & $fmtAllChanges.len & " of " & $fmtAllTotal & " file(s) would change", items)
