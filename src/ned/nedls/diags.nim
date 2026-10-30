# ════════════════════════════════════════════════════════════════════════════
#  nedls — problems, as ned finds them: a misspelled name at once (engineTypos), the compiler on the unsaved
#  text after a pause in typing (typingCheck: `nim check -` on a private copy, in the file's folder), and
#  `nim check` of the file when it is saved (runCheck). Each runs as in the editor (one check of a file at a
#  time, the one typed into last); a check of text that changed meanwhile is stopped. What ned would list for a
#  file (diagsFor, and the names it fades as unused) is published whenever it changes — or, to a client that asks
#  for problems (LSP 3.17's pull diagnostics), given when it asks: an open document's (textDocument/diagnostic),
#  and the whole workspace's (workspace/diagnostic), for which ned's own checks also go over the project's files
#  that are not open, while nedls is idle.
# ════════════════════════════════════════════════════════════════════════════

const
  LsTypingPauseMs = 1200              # (as ned's main loop: the compiler checks the text after this pause)
  LsTyposPauseMs = 500

var
  lsPublished: Table[string, string]   # path → the diagnostics last sent (JSON text)
  lsDiagsDirty = true                  # something may have changed: compare and publish
  lsPublishedAt: MonoTime
  lsPullDiags = false                  # the client asks for an open document's problems (textDocument/diagnostic)
  lsDiagRefresh = false                # … and can be told to ask again (workspace/diagnostic/refresh)
  lsPulled: Table[string, string]      # path → the problems last given when asked (JSON text)
  lsAnnounced: Table[string, string]   # path → the problems the client was last told to ask for
  # the workspace's problems, when the client asks for them (workspace/diagnostic): then none are sent
  lsWsPulling = false                  # it asked once: ned's checks go over the project's files (lsLintPump)
  lsWsPull: JsonNode                   # a workspace/diagnostic held until something differs from what it has …
  lsWsPullPrev: Table[string, string]  # … what it has (uri → result id)
  lsWsPullAt: MonoTime
  lsWsAnsweredAt: MonoTime             # the last workspace/diagnostic answered …
  lsWsAnswered: Table[string, string]  # … and what it said (uri → result id)
  lsWsPullWas = false                  # lsWsPullOn() the last time it was looked at
  lsWsRefreshed = false                # the client was told to ask again (workspace/diagnostic/refresh)
  lsWsReported: HashSet[string]        # files whose problems a workspace answer listed (one gone clean: once more)
  # ned's checks of the project's files that are not open, for the workspace's problems: made while idle
  lsLintOn = true                      # (nedls's setting workspaceDiagnostics)
  lsLintDiags: Table[string, (string, seq[Diag])]   # path → (its stamp, what the checks found)
  lsLintQueue: seq[string]             # files to check
  lsLintQueued = false                 # the project's files were queued
  lsHeardAt: MonoTime                  # the client's last message (the checks wait for a pause)
  # (the problems of a file not open, as LSP's JSON: made again only when something may have changed them — a check
  # finished, a file opened, closed, saved or changed on disk — not at every key typed in another file)
  lsDiskGen = 1
  lsDiskMemo: Table[string, (int, JsonNode)]   # path → (lsDiskGen, its problems)

const
  LsLintMaxFiles = 400                 # (a bigger project: only the files that change, not all of them)
  LsWsPullHoldMs = 60_000              # a workspace/diagnostic answered at the latest after this, changed or not
  LsWsPullGapMs = 15_000               # no workspace/diagnostic held or answered for this long: problems sent again

proc lsWsPullOn(): bool =
  ## does the client pull the workspace's problems now? (one waits, or one was answered a moment ago: a client that
  ## asked once — a command, not a loop — is sent them again after a while)
  lsWsPull != nil or (lsWsPulling and msSince(lsWsAnsweredAt) < LsWsPullGapMs)

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
    if d.rule.len > 0: j["code"] = %d.rule          # (ned's own rule: what .ned/lint.json and `# ned: ignore[…]` name)
    if "is deprecated" in d.msg: j["tags"] = %*[2]
    elif d.rule in ["unused-local", "unused-import", "unused-param", "unreachable"]: j["tags"] = %*[1]
    result.add j
  # (a file not open: what ned's checks found in it while idle, where the compiler said nothing on the line)
  if path in lsLintDiags and lsDocByPath(path) == nil:
    var said: HashSet[int]
    for d in all: said.incl d.line
    for d in lsLintDiags[path][1]:
      if d.line < 0 or d.line in said: continue
      let (sc, el, ec) = lsDiagRange(lines, d)
      var j = %*{"range": lsRangeIn(lines, d.line, max(0, sc), el, max(0, ec)), "severity": clamp(d.sev, 1, 4),
                 "message": d.msg.strip(leading = false), "source": "nedls"}
      if d.rule.len > 0: j["code"] = %d.rule
      if d.rule in ["unused-local", "unused-import", "unused-param", "unreachable"]: j["tags"] = %*[1]
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

proc lsDiskChanged() =
  ## the problems of the files that are not open may be different now
  inc lsDiskGen

proc lsProblemsOf(path: string): JsonNode =
  ## lsDiagnosticsOf, kept for a file that is not open (it raises as lsDiagnosticsOf does)
  if lsDocByPath(path) != nil: return lsDiagnosticsOf(path)
  let m = lsDiskMemo.getOrDefault(path)
  if m[0] == lsDiskGen and m[1] != nil: return m[1]
  result = lsDiagnosticsOf(path)
  if lsDiskMemo.len > 2000:                  # (the problems of files not open, each kept: the out-of-date ones go)
    var old: seq[string]
    for k, v in lsDiskMemo:
      if v[0] != lsDiskGen: old.add k
    for k in old: lsDiskMemo.del k
  lsDiskMemo[path] = (lsDiskGen, result)

proc lsDiagPaths(): seq[string] =
  ## the files whose problems nedls knows of: the open documents, those with problems, those it said had some
  var seen: HashSet[string]
  template want(p: string) =
    if p.len > 0 and p notin seen:
      seen.incl p
      result.add p
  for _, d in lsDocs: want(d.b.path)
  for p in diagsBuild.keys: want(p)
  for p in unusedHints.keys: want(p)
  for p in diagsFfi.keys: want(p)
  for p in diagsEmit.keys: want(p)
  for p in diagsWeb.keys: want(p)
  for p in lsPublished.keys: want(p)
  for p, (_, ds) in lsLintDiags:
    if ds.len > 0: want(p)
  for p in lsWsReported: want(p)

proc lsWsPullTry(timedOut = false)
proc lsWsReports(prev: Table[string, string]): (JsonNode, bool)

proc lsPublishAll(force = false) =
  ## send the problems of every file whose list changed since it was last sent
  if not (lsDiagsDirty or force): return
  lsDiagsDirty = false
  lsPublishedAt = getMonoTime()
  let paths = lsDiagPaths()
  var refresh = false
  let wsPull = lsWsPullOn()
  for p in paths:
    if wsPull:
      # (the client asks for every file's problems: none are sent, and what was sent before is taken back)
      if p in lsPublished:
        lsPublished.del p
        lsNotify("textDocument/publishDiagnostics", %*{"uri": lsUriOf(p), "diagnostics": []})
      if not (lsPullDiags and lsDocByPath(p) != nil): continue     # (an open document's: the client is told below)
    var ds: JsonNode
    try: ds = lsProblemsOf(p)
    except Exception as e:
      lsLog("diagnostics of " & p & ": " & e.msg)
      continue
    let key = $ds
    # (an open document's, when the client asks for them: not sent — the client is told to ask again when they
    # changed since it last asked; what was sent before it opened is taken back)
    if lsPullDiags and lsDocByPath(p) != nil:
      if lsPulled.getOrDefault(p, "[]") != key and lsAnnounced.getOrDefault(p, "") != key:
        lsAnnounced[p] = key
        refresh = true
      if p in lsPublished:
        lsPublished.del p
        lsNotify("textDocument/publishDiagnostics", %*{"uri": lsUriOf(p), "diagnostics": []})
      continue
    if lsPublished.getOrDefault(p, "[]") == key and (p in lsPublished or ds.len == 0): continue
    lsPublished[p] = key
    var params = %*{"uri": lsUriOf(p), "diagnostics": ds}
    let d = lsDocByPath(p)
    if d != nil: params["version"] = %d.version
    lsNotify("textDocument/publishDiagnostics", params)
    if ds.len == 0: lsPublished.del p
  # (the workspace's problems changed while the client has no workspace/diagnostic waiting: told to ask, once)
  if wsPull and lsWsPull == nil and not lsWsRefreshed and lsDiagRefresh and lsWsReports(lsWsAnswered)[1]:
    lsWsRefreshed = true
    refresh = true
  if refresh and lsDiagRefresh: discard lsRequestOut("workspace/diagnostic/refresh", newJNull())
  if lsWsPull != nil: lsWsPullTry()

proc lsPullDiagnostics(params: JsonNode): JsonNode =
  ## textDocument/diagnostic: an open document's problems now (the same as would be sent), or "unchanged" when
  ## they are what the client was given last time
  let d = lsDocOf(params, required = false)
  let path = if d != nil: d.b.path else: lsPathOf(params{"textDocument"}{"uri"}.getStr)
  var ds = newJArray()
  if path.len > 0:
    try: ds = lsDiagnosticsOf(path)
    except Exception as e: lsLog("diagnostics of " & path & ": " & e.msg)
  let key = $ds
  let rid = $hash(key)
  if path.len > 0: lsPulled[path] = key
  if params{"previousResultId"}.getStr == rid: return %*{"kind": "unchanged", "resultId": rid}
  %*{"kind": "full", "resultId": rid, "items": ds}

# ── the workspace's problems (workspace/diagnostic) ──

proc lsLintQueueProject() =
  ## the project's Nim files, to be checked while idle (the client asks for the workspace's problems) — once the
  ## editor's scan has listed them all
  if rootDir.len > 0:
    if not fileCacheValid and not scanning: startScan()
    if scanning:
      pumpScan(10)
      if scanning: return
  lsLintQueued = true
  if rootDir.len == 0: return
  var n = 0
  for rel in fileCache:
    if not rel.endsWith(".nim"): continue
    let p = if rel.isAbsolute: rel else: rootDir / rel
    if isLibraryFile(p) or p in lsLintQueue: continue
    lsLintQueue.add p
    inc n
    if n >= LsLintMaxFiles: break

proc lsLintPump() =
  ## one file of the project checked as `ned --lint` checks it — while the client is quiet
  if not lsWsPulling or not lsLintOn or msSince(lsHeardAt) < 400: return
  if not lsLintQueued:
    lsLintQueueProject()
    return
  while lsLintQueue.len > 0:
    let p = lsLintQueue[0]
    lsLintQueue.delete(0)
    if lsDocByPath(p) != nil: continue                      # (open: its own checks, as you type)
    let st = nxStamp(p)
    if st.len == 0:
      if p in lsLintDiags:
        lsLintDiags.del p
        lsDiagsDirty = true
        lsDiskChanged()
      continue
    if lsLintDiags.getOrDefault(p)[0] == st: continue
    var ds: seq[Diag]
    try:
      if getFileSize(p) > 1_000_000: continue
      let b = newBuffer()
      b.path = p
      b.lines = lsTextLines(readFile(p).replace("\r\n", "\n"))
      if b.lines.len == 0: b.lines = @[""]
      if b.lines.len > 15_000: continue
      b.lang = detectLang(p, b.lines[0])
      if b.lang != nil and b.lang.mode == lmNim:
        # (errors and warnings, as `ned --lint` shows them: a project's hints would bury them in the editor's list)
        for x in lintChecks(b):
          if x.sev <= 2: ds.add x
    except Exception as e:
      lsLog("checks of " & p & ": " & e.msg)
    if lsLintDiags.getOrDefault(p)[1] != ds:
      lsDiagsDirty = true
      lsDiskChanged()
    lsLintDiags[p] = (st, ds)
    return

proc lsLintNext(): int =
  ## ms until lsLintPump (or the held workspace/diagnostic, or the end of pulling) has something to do (for poll's
  ## timeout)
  result = 1000
  if lsWsPull != nil: result = max(10, LsWsPullHoldMs - int(msSince(lsWsPullAt)) + 5)
  elif lsWsPullWas: result = max(10, LsWsPullGapMs - int(msSince(lsWsAnsweredAt)) + 5)
  if not lsWsPulling or not lsLintOn or (lsLintQueued and lsLintQueue.len == 0): return
  result = min(result, max(10, 400 - int(msSince(lsHeardAt)) + 5))

proc lsWsPullMode() =
  ## the client began or stopped pulling the workspace's problems: what is sent changes (taken back, or sent again)
  let on = lsWsPullOn()
  if on != lsWsPullWas:
    lsWsPullWas = on
    lsDiagsDirty = true

proc lsLintOff() =
  ## the setting turned off: what the checks found is forgotten (and taken back from the client)
  lsLintQueue.setLen(0)
  lsLintQueued = false
  if lsLintDiags.len > 0:
    lsLintDiags.clear()
    lsDiagsDirty = true
    lsDiskChanged()

proc lsWsReports(prev: Table[string, string]): (JsonNode, bool) =
  ## every file's problems as a workspace report: (the reports, whether one differs from what the client has)
  var items = newJArray()
  var changed = false
  for p in lsDiagPaths():
    var ds: JsonNode
    try: ds = lsProblemsOf(p)
    except Exception as e:
      lsLog("diagnostics of " & p & ": " & e.msg)
      continue
    let u = lsUriOf(p)
    if ds.len == 0 and p notin lsWsReported and u notin prev: continue   # (clean, and the client knows of nothing)
    let rid = $hash($ds)
    let d = lsDocByPath(p)
    let ver = if d != nil: %d.version else: newJNull()
    if prev.getOrDefault(u) == rid:
      items.add %*{"kind": "unchanged", "uri": u, "version": ver, "resultId": rid}
    else:
      changed = true
      items.add %*{"kind": "full", "uri": u, "version": ver, "resultId": rid, "items": ds}
  (items, changed)

proc lsWsPullAnswer(items: JsonNode) =
  ## the held workspace/diagnostic answered
  let id = lsWsPull
  lsWsPull = nil
  lsWsAnsweredAt = getMonoTime()
  lsWsAnswered.clear()
  for it in items:
    let u = it["uri"].getStr
    let p = lsPathOf(u)
    lsWsAnswered[u] = it["resultId"].getStr
    if it["kind"].getStr == "full":
      if it["items"].len > 0: lsWsReported.incl p else: lsWsReported.excl p
  lsReply(id, %*{"items": items})

proc lsWsPullTry(timedOut = false) =
  ## the held workspace/diagnostic: answered when a file's problems differ from what the client has (or it waited
  ## long enough)
  if lsWsPull == nil: return
  let (items, changed) = lsWsReports(lsWsPullPrev)
  if changed or timedOut: lsWsPullAnswer(items)

proc lsWorkspaceDiagnostic(id: JsonNode, params: JsonNode) =
  ## workspace/diagnostic: the problems of the open files and of the project's (ned's checks run over them while
  ## idle), each with a result id; answered when something differs from what the client has (its
  ## previousResultIds), else held until it does — the client asks again after each answer. The first one is
  ## answered at once, with what is known then.
  if lsWsPull != nil: lsReply(lsWsPull, %*{"items": []})     # (a newer one replaces it)
  let first = not lsWsPulling
  if first: lsWsPulling = true
  lsWsRefreshed = false
  var prev: Table[string, string]
  for r in jitems(params{"previousResultIds"}):
    let u = r{"uri"}.getStr
    if u.len > 0: prev[u] = r{"value"}.getStr
  lsWsPull = id
  lsWsPullPrev = prev
  lsWsPullAt = getMonoTime()
  lsWsPullMode()                       # (pulling now: what was sent is taken back)
  lsWsPullTry(timedOut = first)

proc lsWsPullDrop(id: JsonNode): bool =
  ## the held workspace/diagnostic, when `id` is its id, answered as cancelled (true); a cancel of another request:
  ## false
  if lsWsPull == nil or id == nil or $lsWsPull != $id: return false
  lsWsPull = nil
  lsReplyError(id, ErrRequestCancelled, "cancelled")
  true

proc lsKillStaleCheck(d: LsDoc) =
  ## the text changed while the compiler checks it: that check is stopped (its answer would be thrown away)
  let path = d.b.path
  if path notin typingChecks: return
  let copy = typingChecks[path][2]
  for j in jobs:
    if j.kind == jkCheck and not j.done and copy.len > 0 and copy in j.cmd: killProc(j.pr, SIGKILL)

proc lsCheckBusy(): bool =
  ## is the compiler checking something now? (one check at a time: each is a whole `nim check`)
  for j in jobs:
    if j.kind == jkCheck and not j.done: return true

var lsCheckQueue: seq[(string, bool)]   # files to `nim check` once the running check is done (path, the saved one)

proc lsSaved(b: Buffer) =
  ## ned's checks after a save, one at a time: the file (runCheck), then the other files of its language that show
  ## a compiler error, which the fix may have taken away (as recheckBuildErrors picks them)
  if b.path.len == 0 or not cfgCheckOnSave: return
  var k = 0
  while k < lsCheckQueue.len:
    if lsCheckQueue[k][0] == b.path: lsCheckQueue.delete(k) else: inc k
  lsCheckQueue.add (b.path, true)
  var n = 0
  for p, ds in diagsBuild:
    if n >= 4: break
    if p == b.path or not (p.endsWith(".nim") or p.endsWith(".nims")) or not fileExists(p): continue
    var bad = false
    for d in ds:
      if d.sev == 1 and d.src != "examples": bad = true
    if not bad: continue
    let od = lsDocByPath(p)
    if od != nil and od.b.dirty: continue        # (its own save checks it; the disk copy is old)
    var queued = false
    for (q, _) in lsCheckQueue:
      if q == p: queued = true
    if not queued:
      lsCheckQueue.add (p, false)
      inc n

proc lsPumpCheckQueue() =
  if lsCheckQueue.len == 0 or lsCheckBusy(): return
  let (p, saved) = lsCheckQueue[0]
  lsCheckQueue.delete(0)
  try:
    let d = lsDocByPath(p)
    if saved and d != nil: runCheck(d.b)
    else: runCheckPath(p, "nim", keepExamples = not saved)
  except Exception as e: lsLog("check of " & p & ": " & e.msg)

proc lsEngineChecks(d: LsDoc) =
  ## ned's own checks of a document now: a misspelled name around the last edit (the editor looks around the
  ## screen), the rules of .ned/lint.json
  let cb = d.b
  let keepTop = cb.topLine
  let keepH = textH
  cb.topLine = max(0, d.editPos.line - 150)
  textH = 300
  cb.setSingle(cb.clampPos(d.editPos))
  engineTypos(cb)
  cb.topLine = keepTop
  textH = keepH
  lsDiagsDirty = true

proc lxPumpChecks(d: LsDoc, active: bool)
proc lxNextCheckMs(d: LsDoc): int

proc lsPumpChecks() =
  ## the editor's main-loop rules, for the document typed into last
  lsPumpCheckQueue()
  let d = lsActive
  # (C, JavaScript, HTML, CSS, SQL, JSON: ned's own checks — of every open document; the C compiler's of the one
  # typed into last)
  for _, od in lsDocs:
    if od.b.lang != nil and od.b.lang.mode != lmNim:
      try: lxPumpChecks(od, od == d)
      except Exception as e: lsLog("checks: " & e.msg)
  if d != nil and d.b.lang != nil and d.b.lang.mode != lmNim: return
  if not cfgLiveCheck: return
  if d == nil or d.b.lang == nil or d.b.lang.mode != lmNim or d.b.path.len == 0: return
  let cb = d.b
  let quiet = msSince(d.changedAt)
  let busy = lsCheckBusy() or lsCheckQueue.len > 0
  try:
    if busy: discard                   # (the compiler is checking: the text waits for it)
    elif cb.chkAt == 0 and not cb.dirty and quiet > LsTypingPauseMs and cb.path notin typingChecks:
      # a project file just opened: its errors, without waiting for an edit or a save
      if rootDir.len > 0 and cb.path.startsWith(rootDir & "/") and typingCheckUsable(cb): typingCheck(cb)
      else: cb.chkAt = -1
    elif (cb.dirty or cb.chkAt > 0) and cb.chkAt != cb.changeId and quiet > LsTypingPauseMs and
         cb.path notin typingChecks:
      if typingCheckUsable(cb): typingCheck(cb)           # the compiler, on the unsaved text
      else: cb.chkAt = cb.changeId
    if (cb.dirty or engineChecksOnOpen(cb)) and typoAt.getOrDefault(cb.id, -1) != cb.changeId and
       quiet > LsTyposPauseMs:
      lsEngineChecks(d)
    if cfgMacroNames and mnSeen.getOrDefault(cb.id, -1) != cb.changeId and quiet > 1500:
      macroNamesFor(cb)                  # names its macro calls make: from the compiler, once
  except Exception as e: lsLog("checks: " & e.msg)

proc lsTimeToNextCheck(): int =
  ## ms until lsPumpChecks has something to do (for poll's timeout)
  result = 1000
  if lsCheckQueue.len > 0: result = 100
  let d = lsActive
  for _, od in lsDocs:
    if od.b.lang != nil and od.b.lang.mode != lmNim: result = min(result, lxNextCheckMs(od))
  if d != nil and d.b.lang != nil and d.b.lang.mode != lmNim: return
  if not cfgLiveCheck: return
  if d == nil or d.b.path.len == 0: return
  let cb = d.b
  let quiet = int(msSince(d.changedAt))
  if cb.chkAt != cb.changeId and cb.path notin typingChecks and (cb.dirty or cb.chkAt >= 0):
    result = min(result, max(10, LsTypingPauseMs - quiet + 5))
  if (cb.dirty or engineChecksOnOpen(cb)) and typoAt.getOrDefault(cb.id, -1) != cb.changeId:
    result = min(result, max(10, LsTyposPauseMs - quiet + 5))
