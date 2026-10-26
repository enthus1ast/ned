# ── the assistant with git: why a line changed (its commit, explained), merge conflicts resolved — and checked by
#    the compiler before you see them — and the staged changes reviewed with what their code uses ──

proc aiStripFences(t: string): string =
  ## a whole file the assistant wrote: without the ``` lines it may put round it
  var ls = t.strip(leading = false).splitLines
  while ls.len > 0 and ls[0].strip.len == 0: ls.delete(0)
  if ls.len > 0 and ls[0].strip.startsWith("```"): ls.delete(0)
  if ls.len > 0 and ls[^1].strip == "```": ls.setLen(ls.len - 1)
  ls.join("\n")

proc gitWhyLine() =
  ## Git: why did this line change? — the commit that last changed it (git blame), its message and what it did to
  ## this file, given to the assistant to explain in the chat
  let b = buf()
  if b.path.len == 0 or gitHome().len == 0:
    info("Not a file of a git repository")
    return
  let l = b.primary.head.line
  let file = extractFilename(b.path)
  let lineText = if l < b.lines.len: b.lines[l] else: ""
  let rel = relPath(b.path)
  info("Asking git who changed line " & $(l + 1) & "…")
  discard startJob(jkGit, "git --no-pager blame --porcelain -L " & $(l + 1) & "," & $(l + 1) & " -- " &
                   quoteShell(file), parentDir(b.path), proc(j: Job) =
    var hash, author, summary = ""
    for ln in j.output.splitLines:
      if hash.len == 0 and ln.len >= 40 and ln[0 ..< 40].allCharsInSet(HexDigits): hash = ln[0 ..< 40]
      elif ln.startsWith("author "): author = ln[7 .. ^1]
      elif ln.startsWith("summary "): summary = ln[8 .. ^1]
    if j.code != 0 or hash.len == 0:
      warn("git blame: " & j.output.strip.splitLines.join(" ")[0 ..< min(160, j.output.strip.len)])
      return
    if hash.startsWith("0000000"):
      info("Line " & $(l + 1) & " is not committed yet — your own change, nothing to explain")
      return
    let show = "git --no-pager show --no-color --stat --format='commit %H%nAuthor: %an <%ae>%nDate: %ad%n%n%B' " &
               hash & " && git --no-pager show --no-color --format= -U8 " & hash & " -- " & quoteShell(file)
    discard startJob(jkGit, show, parentDir(b.path), proc(j2: Job) =
      var c = j2.output
      if c.len > 16_000: c = c[0 ..< 16_000] & "\n… (cut: the commit is long)"
      showSide(svAssistant)
      aiSend("Why did this line change? From the commit below — its message and what it did — explain in a few " &
             "sentences what the change to this line was for, and anything the line now depends on. Say so when " &
             "the commit does not tell.\n\n<line file=\"" & rel & "\" number=\"" & $(l + 1) & "\">" & lineText &
             "</line>\n<commit>\n" & c & "\n</commit>", withContext = false,
             shownAs = "Why did line " & $(l + 1) & " of " & file & " change? (" & hash[0 ..< 8] & " · " & author &
                       " · " & summary & ")")))

proc aiConflictCheck(b: Buffer, text: string, then: proc(errs: string) {.closure.}) =
  ## the compiler's errors in a resolved Nim file ("" none — or no compiler to ask): `nim check` reads it on stdin
  ## in the file's folder (its imports found as the file's are)
  if b.lang == nil or b.lang.mode != lmNim or not haveExe("nim"):
    then("")
    return
  let tmp = privTmp("merge") & ".nim"
  try: writeFile(tmp, text)
  except CatchableError:
    then("")
    return
  discard startJob(jkCheck, "nim check --hints:off --warnings:off --colors:off - < " & quoteShell(tmp) & " 2>&1",
                   parentDir(b.path), proc(j: Job) =
    try: removeFile(tmp)
    except CatchableError: discard
    var errs: seq[string]
    for l in j.output.splitLines:
      if " Error: " in l: errs.add l.replace("stdinfile.nim", extractFilename(b.path))
    then(errs.join("\n")))

proc aiResolveConflicts() =
  ## Git: resolve the conflicts with AI — the file's conflicts (<<<<<<< … >>>>>>>) given to the assistant with the
  ## rest of the file; a Nim file's resolution is checked by the compiler (its errors sent back once to be fixed),
  ## then shown side by side to take or leave
  let b = buf()
  var n = 0
  for l in b.lines:
    if l.startsWith("<<<<<<<"): inc n
  if n == 0:
    info("No merge conflicts in this file (<<<<<<< … >>>>>>>)")
    return
  if b.lines.len > 6000:
    info("The file is too long to send whole — resolve its conflicts in the merge editor")
    return
  let id = b.id
  let ch = b.changeId
  let before = b.lines
  let rel = relPath(b.path)
  let ask = "Resolve the merge conflicts in this file. Each is between <<<<<<< (ours, this branch) and ======= " &
            "(then theirs, up to >>>>>>>), with ||||||| before ======= for the common ancestor when it is there. " &
            "Keep what both sides meant: both changes where they can live together, else the one that keeps the " &
            "code working — and the rest of the file exactly as it is. Reply with the whole file, resolved, and " &
            "nothing else: no explanation, no ``` fences.\n\n<file path=\"" & rel & "\">\n" & b.allText & "\n</file>"
  info("The assistant is resolving " & $n & " conflict" & (if n == 1: "" else: "s") & " in " & b.name & "…")
  proc show(res, checkNote: string) =
    let x = bufById(id)
    if x == nil: return
    let after = res.split('\n')
    openDiffView(rel, before, "with the conflicts", nil, after, "resolved by the assistant" & checkNote, x.lang)
    let dvId = buf().id
    proc back() =
      let dv = bufById(dvId)
      if dv != nil and dv.id != id:
        let k = bufs.find(dv)
        if k >= 0: closeBufferAt(k)
      let y = bufById(id)
      if y != nil and y.path.len > 0: discard openFile(y.path)
    openActions("Conflicts resolved by the assistant" & checkNote, @[
      act("Take it", "the file becomes the right side (undo brings the conflicts back)", proc() =
        let y = bufById(id)
        back()
        if y == nil or not y.canEdit(): return
        if y.changeId != ch:
          info("The file changed since — ask again")
          return
        y.setTextMinimal(after.join("\n"))
        info("Conflicts resolved — look it over, then save and stage it")),
      act("Leave it", "the conflicts stay", proc() =
        back()
        info("Left as it is"))])
  aiOneShot(ask, proc(t: string) =
    let res = aiStripFences(t)
    if res.strip.len == 0:
      warn("The assistant gave back nothing")
      return
    if "\n<<<<<<<" in "\n" & res or "\n>>>>>>>" in "\n" & res:
      warn("The assistant left conflict marks in — resolve it in the merge editor")
      return
    let x = bufById(id)
    if x == nil: return
    aiConflictCheck(x, res, proc(errs: string) =
      if errs.len == 0:
        show(res, (if x.lang != nil and x.lang.mode == lmNim and haveExe("nim"): " — the compiler finds no error" else: ""))
        return
      # once more, with what the compiler said
      info("The compiler found errors in it — the assistant fixes them…")
      aiOneShot("The compiler found these errors in your resolution of " & rel & ":\n" & errs & "\n\nFix them. " &
                "Reply with the whole file and nothing else, no ``` fences.\n\n<file path=\"" & rel & "\">\n" & res &
                "\n</file>", proc(t2: string) =
        let res2 = aiStripFences(t2)
        aiConflictCheck(x, res2, proc(errs2: string) =
          show(res2, (if errs2.len == 0: " — the compiler finds no error"
                      else: " — the compiler still finds " & $errs2.splitLines.len & " error(s): " &
                            errs2.splitLines[0].truncTo(80)))))))
