# ── Nim: the compiler's answer where the engine has none, without nimsuggest kept running (nim.nimsuggest off):
#    one nimsuggest run for the one question (hover, Go to definition), which then quits — its memory goes with
#    it. The answer is kept until the file changes. The unsaved text goes to it as a private copy, deleted after ──

var
  kind3Busy = false                           # (Nim 3: nimony is being asked)
  caRunning: HashSet[string]                  # questions being answered (their keys)
  caAnswers: Table[string, seq[string]]       # key → nimsuggest's answer lines
  caOrder: seq[string]                        # (the oldest answers go first: at most 200 kept)

proc compilerAnswerUsable(b: Buffer): bool =
  ## may the compiler be asked once about this buffer (the engine had no answer, nimsuggest is not running)?
  cfgCompilerAnswers and b.lang != nil and b.lang.mode == lmNim and b.path.len > 0 and b.path.endsWith(".nim") and
    not b.largeOn and b.lines.len < 60000 and not cfgNimSuggest and not nimUsesLsp() and cfgNimIde != "off" and
    haveExe("nimsuggest") and codeTrusted(parentDir(b.path))

proc compilerAnswerNim3(b: Buffer, p: Pos): bool =
  ## Nim 3: nimony's --def where the engine has none (nimony has no hover); shown as nimsuggest's answer would be
  if kind3Busy: return true
  let key = b.path & ":" & $b.changeId & ":" & $p.line & ":" & $p.col & ":def3"
  let r = NsReq(kind: nsDef, bufId: b.id, pos: p)
  if key in caAnswers:
    nsHandle(nil, r, caAnswers[key])
    return true
  info("Asking nimony…")
  kind3Busy = true
  let bid = b.id
  let changeAt = b.changeId
  b.nimonyAsk("def", p, proc(found: seq[(string, int, int)]) =
    kind3Busy = false
    var ls: seq[string]
    for (f, l, c) in found:
      # (as nimsuggest writes it: def, kind, name, signature, file, line from 1, column)
      ls.add "def\tskProc\t\t\t" & f & "\t" & $(l + 1) & "\t" & $c & "\t\t100"
    caAnswers[key] = ls
    caOrder.add key
    if caOrder.len > 200:
      caAnswers.del caOrder[0]
      caOrder.delete(0)
    let x = bufById(bid)
    if x == nil or x.changeId != changeAt or x != buf() or x.primary.head.line != p.line: return
    if ls.len == 0:
      info("nimony knows no definition here either")
      return
    nsHandle(nil, r, ls)
    needRender = true)
  true

proc compilerAnswer(b: Buffer, kind: NsKind, p: Pos): bool =
  ## ask the compiler about the word at `p` (false: it cannot be asked); its answer is shown as nimsuggest's
  ## would be (a hover, a jump) — if you are still there when it comes
  if nim3On() and b.lang != nil and b.lang.mode == lmNim and b.path.endsWith(".nim") and cfgNimIde != "off":
    return kind == nsDef and b.compilerAnswerNim3(p)
  if kind in {nsDef, nsHover, nsAutoHover} and b.lang != nil and b.lang.mode == lmNim:
    # (the compiler's answer for this name, kept from the background oracle or from an earlier question)
    let kept = orCompilerLines(b, p)
    if kept.len > 0:
      nsHandle(nil, NsReq(kind: kind, bufId: b.id, pos: p), kept)
      return true
  if not compilerAnswerUsable(b) or kind notin {nsDef, nsHover, nsAutoHover}: return false
  let q = if kind == nsDef: "def" else: "hover"
  let key = b.path & ":" & $b.changeId & ":" & $p.line & ":" & $p.col & ":" & q
  let r = NsReq(kind: kind, bufId: b.id, pos: p)
  if key in caAnswers:
    nsHandle(nil, r, caAnswers[key])
    return true
  if key in caRunning: return true
  if kind == nsAutoHover: return false              # (not for the mouse resting on a word: only when asked)
  var dirty = ""
  if b.dirty:
    dirty = privTmp("answer") & "_" & extractFilename(b.path)
    try: writeFile(dirty, b.allText & "\n")
    except CatchableError: return false
  let loc = b.path & (if dirty.len > 0: ";" & dirty else: "") & ":" & $(p.line + 1) & ":" & $p.col
  let proj = nimProjectFile(b)
  # (only paths on the command line: the text is in the private copy)
  let cmd = "printf '%s\\nquit\\n' " & quoteShell("def " & loc) & " | nimsuggest --stdin --v3 --maxresults:20 " &
            quoteShell(proj) & " 2>/dev/null"
  caRunning.incl key
  info("Asking the compiler (nimsuggest is off: one run for this question)…")
  let bid = b.id
  let changeAt = b.changeId
  discard startJob(jkAux, cmd, parentDir(proj), proc(j: Job) =
    caRunning.excl key
    if dirty.len > 0:
      try: removeFile(dirty)
      except CatchableError: discard
    var ls: seq[string]
    for l in j.output.splitLines:
      let t = l.strip(leading = true, trailing = false).strip(chars = {'>', ' '}, trailing = false)
      if t.startsWith("def\t"): ls.add t
    caAnswers[key] = ls
    caOrder.add key
    if caOrder.len > 200:
      caAnswers.del caOrder[0]
      caOrder.delete(0)
    let x = bufById(bid)
    if x != nil and x.changeId == changeAt and ls.len > 0: orKeep(x, p, ls)     # (kept for the next time)
    if x == nil or x.changeId != changeAt or x != buf() or x.primary.head.line != p.line: return
    if ls.len == 0 and kind == nsDef:
      info("The compiler knows no definition here either")
      return
    nsHandle(nil, r, ls)
    needRender = true)
  true
