# ════════════════════════════════════════════════════════════════════════════
#  nedls — problems, as ned finds them: a misspelled name at once (engineTypos), the compiler on the unsaved
#  text after a pause in typing (typingCheck: `nim check -` on a private copy, in the file's folder), and
#  `nim check` of the file when it is saved (runCheck). Each runs as in the editor (one check of a file at a
#  time, the one typed into last); a check of text that changed meanwhile is stopped. What ned would list for a
#  file (diagsFor, and the names it fades as unused) is published whenever it changes.
# ════════════════════════════════════════════════════════════════════════════

const
  LsTypingPauseMs = 1200              # (as ned's main loop: the compiler checks the text after this pause)
  LsTyposPauseMs = 500

var
  lsPublished: Table[string, string]   # path → the diagnostics last sent (JSON text)
  lsDiagsDirty = true                  # something may have changed: compare and publish
  lsPublishedAt: MonoTime

proc lsDiagRange(lines: seq[string], d: Diag): (int, int, int) =
  ## where a problem's underline goes: (start column, end line, end column) — its own end, else the name it
  ## starts at (as the editor underlines it); a member the compiler points at by its dot (`x.nmae`) from the name
  if d.ecol >= 0 and (d.eline > d.line or (d.eline == d.line and d.ecol > d.col)): return (d.col, d.eline, d.ecol)
  if d.line < 0 or d.line >= lines.len: return (d.col, d.line, d.col)
  let s = lines[d.line]
  var c = clamp(d.col, 0, s.len)
  let q = quotedName(d.msg)
  if c < s.len and s[c] == '.' and q.len > 0 and s.continuesWith(q, c + 1): inc c
  if c < s.len and (isWordByte(s[c]) or s[c] == '`'): return (c, d.line, lsWordEnd(s, c))
  if c < s.len: return (c, d.line, nextRune(s, c))
  (c, d.line, c)

proc lsDiagnosticsOf(path: string): JsonNode =
  ## the problems ned shows for a file, as LSP diagnostics
  result = newJArray()
  let lines = lsLinesOf(path)
  let nimFile = path.endsWith(".nim") or path.endsWith(".nims") or path.endsWith(".nimble")
  let all = diagsFor(path)
  var fieldLines: HashSet[int]           # lines with an "undeclared field: 'x'" (its "'.'" echoes add nothing)
  for d in all:
    if d.msg.startsWith("undeclared field: '") and not d.msg.startsWith("undeclared field: '.'"): fieldLines.incl d.line
  var seen: HashSet[string]
  for d in all:
    if d.line < 0: continue
    if d.line in fieldLines and d.msg.startsWith("undeclared field: '.'"): continue
    let key = $d.line & ":" & $d.col & ":" & $d.sev & ":" & d.msg
    if key in seen: continue             # (the same problem reported twice)
    seen.incl key
    let (sc, el, ec) = lsDiagRange(lines, d)
    var msg = if nimFile: prettyNimError(d.msg) else: d.msg
    if msg.strip.len == 0: msg = d.msg
    var j = %*{"range": lsRangeIn(lines, d.line, max(0, sc), el, max(0, ec)),
               "severity": clamp(d.sev, 1, 4), "message": msg.strip(leading = false)}
    if d.src.len > 0: j["source"] = %(if d.src == "ned": "nedls" else: d.src)
    if "is deprecated" in d.msg: j["tags"] = %*[2]
    result.add j
  # names the compiler says are not used: faded, as in the editor
  for (l, c, name) in unusedHints.getOrDefault(path):
    if l < 0 or l >= lines.len or name.len == 0: continue
    let s = lines[l]
    let short = name.split('.')[^1]
    var at = -1
    var k = s.find(short, max(0, min(c, s.len)))
    if k < 0: k = s.find(short)
    while k >= 0:
      if (k == 0 or s[k - 1] notin IdentChars) and (k + short.len >= s.len or s[k + short.len] notin IdentChars):
        at = k
        break
      k = s.find(short, k + 1)
    if at < 0: continue
    result.add %*{"range": lsRangeIn(lines, l, at, l, at + short.len), "severity": 4,
                  "message": "'" & name & "' is declared but not used", "source": "nim", "tags": [1]}

proc lsPublishAll(force = false) =
  ## send the problems of every file whose list changed since it was last sent
  if not (lsDiagsDirty or force): return
  lsDiagsDirty = false
  lsPublishedAt = getMonoTime()
  var paths: seq[string]
  var seen: HashSet[string]
  template want(p: string) =
    if p.len > 0 and p notin seen:
      seen.incl p
      paths.add p
  for _, d in lsDocs: want(d.b.path)
  for p in diagsBuild.keys: want(p)
  for p in unusedHints.keys: want(p)
  for p in diagsFfi.keys: want(p)
  for p in diagsEmit.keys: want(p)
  for p in lsPublished.keys: want(p)
  for p in paths:
    var ds: JsonNode
    try: ds = lsDiagnosticsOf(p)
    except Exception as e:
      lsLog("diagnostics of " & p & ": " & e.msg)
      continue
    let key = $ds
    if lsPublished.getOrDefault(p, "[]") == key and (p in lsPublished or ds.len == 0): continue
    lsPublished[p] = key
    var params = %*{"uri": lsUriOf(p), "diagnostics": ds}
    let d = lsDocByPath(p)
    if d != nil: params["version"] = %d.version
    lsNotify("textDocument/publishDiagnostics", params)
    if ds.len == 0: lsPublished.del p

proc lsKillStaleCheck(d: LsDoc) =
  ## the text changed while the compiler checks it: that check is stopped (its answer would be thrown away)
  let path = d.b.path
  if path notin typingChecks: return
  let copy = typingChecks[path][2]
  for j in jobs:
    if j.kind == jkCheck and not j.done and copy.len > 0 and copy in j.cmd: killProc(j.pr, SIGKILL)

proc lsPumpChecks() =
  ## the editor's main-loop rules, for the document typed into last
  if not cfgLiveCheck: return
  let d = lsActive
  if d == nil or d.b.lang == nil or d.b.lang.mode != lmNim or d.b.path.len == 0: return
  let cb = d.b
  let quiet = msSince(d.changedAt)
  try:
    if cb.chkAt == 0 and not cb.dirty and quiet > LsTypingPauseMs and cb.path notin typingChecks:
      # a project file just opened: its errors, without waiting for an edit or a save
      if rootDir.len > 0 and cb.path.startsWith(rootDir & "/") and typingCheckUsable(cb): typingCheck(cb)
      else: cb.chkAt = -1
    elif (cb.dirty or cb.chkAt > 0) and cb.chkAt != cb.changeId and quiet > LsTypingPauseMs and
         cb.path notin typingChecks:
      if typingCheckUsable(cb): typingCheck(cb)           # the compiler, on the unsaved text
      else: cb.chkAt = cb.changeId
    if cb.dirty and typoAt.getOrDefault(cb.id, -1) != cb.changeId and quiet > LsTyposPauseMs:
      # a misspelled name: looked for around the last edit (the editor looks around the screen)
      let keepTop = cb.topLine
      let keepH = textH
      cb.topLine = max(0, d.editPos.line - 150)
      textH = 300
      cb.setSingle(cb.clampPos(d.editPos))
      engineTypos(cb)
      cb.topLine = keepTop
      textH = keepH
      lsDiagsDirty = true
  except Exception as e: lsLog("checks: " & e.msg)

proc lsTimeToNextCheck(): int =
  ## ms until lsPumpChecks has something to do (for poll's timeout)
  result = 1000
  if not cfgLiveCheck: return
  let d = lsActive
  if d == nil or d.b.path.len == 0: return
  let cb = d.b
  let quiet = int(msSince(d.changedAt))
  if cb.chkAt != cb.changeId and cb.path notin typingChecks and (cb.dirty or cb.chkAt >= 0):
    result = min(result, max(10, LsTypingPauseMs - quiet + 5))
  if cb.dirty and typoAt.getOrDefault(cb.id, -1) != cb.changeId:
    result = min(result, max(10, LsTyposPauseMs - quiet + 5))
