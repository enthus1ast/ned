# ── code from comments (as in Zed and Aider): a comment says what to write, the assistant writes it —
#    · Alt+Shift+C on a comment (nothing selected), or the ✦ after it: the code it describes, below it
#    · a comment ending in AI! (# make this a func AI!): at save, the change it asks for, anywhere in the file
#    · a comment ending in AI? (# why is this slow AI?): at save, answered in the chat
#    What the assistant writes is checked by the compiler first (Nim) and shown side by side to take or leave;
#    nothing changes without you. ai.commentCommands turns AI! and AI? off ──

proc aiCommentPrefix(b: Buffer): string =
  ## the file's line-comment marker (// or #), empty when its language has none
  if b.lang == nil: "" else: b.lang.lineComment

proc aiIsComment(b: Buffer, l: int): bool =
  ## whether line `l` starts (after its indentation) with the line-comment marker
  let p = b.aiCommentPrefix
  p.len > 0 and l >= 0 and l < b.lines.len and b.lines[l].strip(trailing = false).startsWith(p)

proc aiIsDocComment(b: Buffer, l: int): bool =
  ## a doc comment (## in Nim, /// and //! in C-like languages): it says what code does, not what to write
  let p = b.aiCommentPrefix
  if not b.aiIsComment(l): return false
  let t = b.lines[l].strip(trailing = false)
  t.startsWith(p & p[^1]) or (p == "//" and t.startsWith("//!"))

proc aiCommentBlock(b: Buffer, l: int): (int, int) =
  ## the comment lines around line l (-1, -1: l is not a comment)
  if not b.aiIsComment(l): return (-1, -1)
  var a = l
  var e = l
  while a > 0 and b.aiIsComment(a - 1): dec a
  while e < b.lines.high and b.aiIsComment(e + 1): inc e
  (a, e)

proc aiCommentHere(b: Buffer): (int, int) =
  ## the comment the cursor is on — or just below, on an empty line
  let l = b.primary.head.line
  result = b.aiCommentBlock(l)
  if result[0] < 0 and l > 0 and l < b.lines.len and b.lines[l].strip.len == 0: result = b.aiCommentBlock(l - 1)

proc aiCheckThenShow(b: Buffer, before: seq[string], newText, title, why: string, onTake: proc() {.closure.} = nil) =
  ## the assistant's version of a file: checked by the compiler (Nim), then side by side — Take it / Leave it
  let id = b.id
  let ch = b.changeId
  let after = newText.split('\n')
  proc show(note: string) =
    ## opens the side-by-side view of the file before and after the assistant's version, and a menu with the numbers of
    ## lines added and removed and the compiler's verdict (`note`): Take it puts the new text in the file, if it has not
    ## changed since, as one undo step; Leave it changes nothing. Both close the view
    let x = bufById(id)
    if x == nil: return
    openDiffView(relPath(x.path), before, "now", nil, after, why & note, x.lang)
    let dvId = buf().id
    proc back() =
      ## closes the side-by-side view and goes back to the file
      let dv = bufById(dvId)
      if dv != nil and dv.id != id:
        let k = bufs.find(dv)
        if k >= 0: closeBufferAt(k)
      let y = bufById(id)
      if y != nil and y.path.len > 0: discard openFile(y.path)
    let (adds, dels) = diffStats(lineDiff(before, after))
    openActions(title & ": +" & $adds & " −" & $dels & note, @[
      act("Take it", "Ctrl+Z gives the file back as it was", proc() =
        let y = bufById(id)
        back()
        if y == nil or not y.canEdit(): return
        if y.changeId != ch:
          info("The file changed since — ask again")
          return
        y.setTextMinimal(after.join("\n"))
        if onTake != nil: onTake()
        info("Done — Ctrl+Z undoes it")),
      act("Leave it", "nothing changes", proc() =
        back()
        info("Left as it is"))])
  if b.lang == nil or b.lang.mode != lmNim or not haveExe("nim"):
    show("")
    return
  let tmp = privTmp("aicomment") & ".nim"
  try: writeFile(tmp, newText)
  except CatchableError:
    show("")
    return
  discard startJob(jkCheck, "nim check --hints:off --warnings:off --colors:off - < " & quoteShell(tmp) & " 2>&1",
                   parentDir(b.path), proc(j: Job) =
    try: removeFile(tmp)
    except CatchableError: discard
    var errs: seq[string]
    for l in j.output.splitLines:
      if " Error: " in l: errs.add l.replace("stdinfile.nim", extractFilename(b.path))
    show(if errs.len == 0: " — the compiler finds no error"
         else: " — the compiler finds " & $errs.len & " error(s): " & errs[0].truncTo(90)))

proc aiCodeFromComment() =
  ## the code the comment at the cursor describes, written below it (and below the code already there for it:
  ## the assistant may rewrite that too)
  let b = buf()
  let (a, e) = b.aiCommentHere()
  if a < 0:
    info("Put the cursor on a comment that says what to write (or select code and say how to change it)")
    return
  if not b.canEdit(): return
  if b.lines.len > 4000:
    info("The file is too long to send whole — select the place and use AI: edit selection…")
    return
  let pre = b.aiCommentPrefix
  var said: seq[string]
  for l in a .. e: said.add b.lines[l].strip(trailing = false)[pre.len .. ^1].strip
  let defs = codeDefinitionsFor(b, max(0, a - 30), min(b.lines.high, e + 20))
  var numbered = ""
  for i, l in b.lines: numbered.add l & (if i == e: "    ⟵ (the comment ends here)" else: "") & "\n"
  let ask = "The comment that ends at the marked line says what code to write there. Write it — right after the " &
            "comment, at its indentation; replace what follows the comment only when it is a first try at the " &
            "same thing. Keep the comment and the rest of the file exactly as they are. Use only names that exist " &
            "(the file and <definitions> show them). Reply with the whole file, without the ⟵ mark, and nothing " &
            "else — no explanation, no ``` fences.\nLanguage: " & b.lang.name & "\nFile: " & relPath(b.path) &
            "\n<file>\n" & numbered & "</file>" & (if defs.len > 0: "\n" & defs else: "")
  let before = b.lines
  let id = b.id
  info("The assistant is writing what the comment says…")
  aiOneShot(ask, proc(t: string) =
    let x = bufById(id)
    if x == nil: return
    let res = aiStripFences(t).replace("    ⟵ (the comment ends here)", "")
    if res.strip.len == 0:
      warn("The assistant gave back nothing")
      return
    aiCheckThenShow(x, before, res, "Code for: " & said.join(" ").truncTo(50), "with the code the comment asks for"))

# ── AI! and AI? comments, at save ──

var aiCommentsDone: HashSet[string]       # (file, comment) already acted on: not again at the next save

proc aiCommentsSaved(b: Buffer) =
  ## (after a save) the comments ending in AI! or AI? (ai.commentCommands)
  if not sBool("ai.commentCommands") or b.path.len == 0 or b.lang == nil or b.lines.len > 4000: return
  if not (cfgAiProvider in ["ollama", "custom"] or aiKey().len > 0): return
  let pre = b.aiCommentPrefix
  if pre.len == 0: return
  var acts, asks: seq[(int, string)]
  for i, l in b.lines:
    let s = l.strip
    if not s.startsWith(pre) or s.len < pre.len + 3: continue
    let t = s[pre.len .. ^1].strip
    let key = b.path & "\0" & t
    if key in aiCommentsDone: continue
    if t.endsWith("AI!") or t.startsWith("AI!"):
      acts.add (i, t.replace("AI!", "").strip)
      aiCommentsDone.incl key
    elif t.endsWith("AI?") or t.startsWith("AI?"):
      asks.add (i, t.replace("AI?", "").strip)
      aiCommentsDone.incl key
  for (l, q) in asks:
    showSide(svAssistant)
    aiSend("About line " & $(l + 1) & " of " & relPath(b.path) & ": " & q, shownAs = q & "  (" & relPath(b.path) &
           ":" & $(l + 1) & ")")
    break                                   # (one question at a time: the chat answers in turn)
  if acts.len == 0: return
  var numbered = ""
  for i, l in b.lines: numbered.add l & "\n"
  var what: seq[string]
  for (l, q) in acts: what.add "line " & $(l + 1) & ": " & q
  let ask = "The comments ending in AI! in this file ask for changes. Make them — where each comment says, or where " &
            "it is about — and remove those AI! comments (only those). Keep everything else exactly as it is. Use only " &
            "names that exist. Reply with the whole file and nothing else — no explanation, no ``` fences.\n" &
            "The requests: " & what.join("; ") & "\nLanguage: " & b.lang.name & "\nFile: " & relPath(b.path) &
            "\n<file>\n" & numbered & "</file>"
  let before = b.lines
  let id = b.id
  info("AI!: the assistant is making " & (if acts.len == 1: "the change" else: $acts.len & " changes") & " the comments ask for…")
  aiOneShot(ask, proc(t: string) =
    let x = bufById(id)
    if x == nil: return
    let res = aiStripFences(t)
    if res.strip.len == 0:
      warn("The assistant gave back nothing")
      return
    aiCheckThenShow(x, before, res, "AI! " & acts[0][1].truncTo(50), "as the AI! comments ask"))
