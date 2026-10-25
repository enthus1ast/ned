# ── the engine worker (nim.engineWorker): what the Nim engine works out at length — type and parameter hints,
#    its own checks, misspelled names — worked out by a second ned (`ned --engine-worker`, the same program) on
#    another processor core. The editor sends it the text of the open Nim files (then only what changed) and asks;
#    the answers come back while you type and scroll: nothing waits for them, and an answer for a text that has
#    changed since is dropped (asked again for the new one). Completion, hover, go to definition and the rest you
#    ask for stay in the editor (its own index answers them at once).
#
#    A worker that stops is started again; one that keeps stopping (4 times in 10 minutes) is given up, and the
#    editor does the work itself as before (the reason in Help › Performance). One that has had nothing to do for
#    10 minutes is stopped (its memory given back) and started again when needed.
#
#    The protocol: one JSON object a line each way. The editor sends init (the folder, the settings, what `nim
#    dump` said), doc (a file's whole text), edits (the changes since the version the worker has), close, hints
#    (16-line chunks of a file, for a key: its version and the settings), checks (the file's misspelled names
#    around the screen and the engine's checks), settings, dump. The worker answers hints (one chunk each),
#    checks, resync (the edits did not fit: the whole text, please) and error. ──

const
  WkIdleMs = 600_000             # nothing asked for this long: the worker stops (its memory given back)
  WkDeathsMax = 4                # this many stops in WkDeathsWindowMs: given up, the editor works it out itself
  WkDeathsWindowMs = 600_000

type
  EngineWorker = ref object
    pr: Proc
    inFd, outFd, errFd: cint
    rbuf, ebuf: string            # what arrived of its answers (a line not yet whole), its stderr (the end of it)
    wbuf: string                  # what waits to be written to it
    wpos: int
    dead: bool
    started, usedAt: MonoTime
    sent: Table[int, int]         # buffer id → the version of its text the worker has
    hintsFly: Table[int, (string, HashSet[int])]  # buffer id → (the key, the chunks asked for and not answered)
    checksFly: Table[int, int]    # buffer id → the version its checks were asked for
    refsAsked: Table[int, (int, int, int)]   # buffer id → (version, first line, last line) counts were asked for
    answers: int                  # (Help › Performance)
    hintsMs, checksMs: int        # how long the last ones took it
    fullSends, editSends: int
    held: string                  # what its memory holds (it says so with its checks)

var
  wkVerify = getEnv("NED_WK_VERIFY") == "1"
  wkp: EngineWorker
  wkRefsVer: Table[int, int]      # buffer id → the version of its text its reference counts are for
  wkDeaths: seq[MonoTime]
  wkOffWhy = ""                   # given up: why (Help › Performance)
  wkDumps: seq[(string, string)]  # what `nim dump` said of each project (a new worker is told too)
  wkLastErr = ""

var wkBench = false                # (ned --bench: no worker — the frames are what is measured)

proc wkOn(): bool =
  ## does the worker work out the hints and checks (else the editor, in slices, as before)?
  when defined(nedNoMain): false     # (nedls, the engine's test driver: their own process does it)
  else: not wkWorkerMode and not wkBench and wkOffWhy.len == 0 and sBool("nim.engineWorker")

proc wkTidyHere(): bool {.nimcall.} =
  ## the index's disk cache tidied here? In the worker — or the editor when there is none (it takes a moment)
  wkWorkerMode or not wkOn()

nxCacheTidyHere = wkTidyHere

proc wkExe(): string =
  ## this very program (Linux: even when its file was replaced by an update meanwhile)
  if fileExists("/proc/self/exe"): "/proc/self/exe" else: getAppFilename()

proc wkFlush() =
  let w = wkp
  if w == nil or w.dead or w.wpos >= w.wbuf.len: return
  while w.wpos < w.wbuf.len:
    let n = posix.write(w.inFd, unsafeAddr w.wbuf[w.wpos], w.wbuf.len - w.wpos)
    if n > 0: w.wpos += n
    elif n < 0 and (errno == EAGAIN or errno == EWOULDBLOCK or errno == EINTR): break
    else:
      w.dead = true
      return
  if w.wpos >= w.wbuf.len:
    w.wbuf.setLen(0)
    w.wpos = 0
  elif w.wpos > 1_000_000:
    w.wbuf = w.wbuf[w.wpos .. ^1]
    w.wpos = 0

proc wkSend(j: JsonNode) =
  if wkp == nil or wkp.dead: return
  wkp.wbuf.add $j
  wkp.wbuf.add '\n'
  wkFlush()

proc wkStop(why = "") =
  ## (quitting, a folder opened, idle: the worker goes — a new one when needed)
  let w = wkp
  if w == nil: return
  wkp = nil
  if not w.dead:
    try:
      discard posix.write(w.inFd, cstring("{\"op\":\"quit\"}\n"), 14)
    except CatchableError: discard
  closeFd(w.inFd)
  closeFd(w.outFd)
  closeFd(w.errFd)
  killProc(w.pr)
  reapSoon(w.pr.pid)
  for b in bufs: b.wkLogFrom = -1
  for id in w.hintsFly.keys:
    let b = bufById(id)
    if b != nil and b.id in ihStates: ihStates[b.id].key = ""    # (the chunks it was asked for: asked again)
  for id in w.checksFly.keys: typoAt.del id

proc wkSettingsJson(): JsonNode =
  result = if settingsJ != nil: settingsJ.copy else: newJObject()

proc wkStart(): bool =
  ## a worker running and told the folder, the settings and the toolchain — false when it cannot be
  if wkp != nil and not wkp.dead: return true
  if wkp != nil:
    # (it stopped: why, from its last words)
    let why = if wkp.ebuf.strip.len > 0: wkp.ebuf.strip.splitLines()[^1] else: "it stopped"
    wkLastErr = why
    wkDeaths.add getMonoTime()
    var keep: seq[MonoTime]
    for t in wkDeaths:
      if msSince(t) < WkDeathsWindowMs: keep.add t
    wkDeaths = keep
    wkStop()
    if wkDeaths.len >= WkDeathsMax:
      wkOffWhy = "the engine worker stopped " & $wkDeaths.len & " times (" & why & ") — the editor works it out itself"
      internalError("engine worker", newException(CatchableError, wkOffWhy))
      return false
  try:
    var p = spawnProc(@[wkExe(), "--engine-worker"], (if rootDir.len > 0: rootDir else: getCurrentDir()), siPipe,
                      erPipe, 5)
    let w = EngineWorker(pr: p, inFd: p.inFd, outFd: p.outFd, errFd: p.errFd, started: getMonoTime(),
                         usedAt: getMonoTime())
    w.pr.inFd = -1
    w.pr.outFd = -1
    w.pr.errFd = -1
    setNonBlock(w.inFd); setNonBlock(w.outFd); setNonBlock(w.errFd)
    wkp = w
  except CatchableError as e:
    wkOffWhy = "the engine worker could not start (" & e.msg & ") — the editor works it out itself"
    return false
  var dumps = newJArray()
  for (proj, o) in wkDumps: dumps.add %*[proj, o]
  wkSend(%*{"op": "init", "root": rootDir, "ws": wsRoots, "s": wkSettingsJson(), "dumps": dumps,
            "n3": nim3On()})
  for b in bufs: b.wkLogFrom = -1
  true

proc wkSync(b: Buffer) =
  ## the worker has this buffer's text as it is now: what changed since its version, or the whole text
  let w = wkp
  let have = w.sent.getOrDefault(b.id, -1)
  if have == b.changeId: return
  var bytes = 0
  for e in b.wkLog: bytes += e.text.len
  if have >= 0 and b.wkLogFrom == have and b.wkLog.len == b.changeId - have and b.wkLog.len > 0 and
     bytes < 200_000:
    var es = newJArray()
    for e in b.wkLog: es.add %*[e.a.line, e.a.col, e.c.line, e.c.col, e.text]
    let last = b.wkLog[^1]
    let hl = clamp(last.a.line + last.text.count('\n'), 0, b.lines.high)
    wkSend(%*{"op": "edits", "id": b.id, "from": have, "v": b.changeId, "e": es, "n": b.lines.len, "hl": hl,
              "h": fnv(b.lines[hl])})
    inc w.editSends
  else:
    wkSend(%*{"op": "doc", "id": b.id, "path": b.path, "lang": b.lang.name, "v": b.changeId,
              "text": b.lines.join("\n")})
    inc w.fullSends
  w.sent[b.id] = b.changeId
  b.wkLog.setLen(0)
  b.wkLogFrom = b.changeId
  if wkVerify:
    # (tests, the fuzzer: the worker checks that its text is the editor's, every time)
    wkSend(%*{"op": "verify", "id": b.id, "v": b.changeId, "h": fnv(b.lines.join("\n")), "path": b.path})

proc wkSyncAll(b: Buffer) =
  ## before a question about b: b, and every other Nim file open with unsaved changes (they are what its scope
  ## sees), and the ones it had before (kept up to date — or closed there)
  let w = wkp
  var gone: seq[int]
  for id in w.sent.keys:
    if bufById(id) == nil: gone.add id
  for id in gone:
    w.sent.del id
    wkSend(%*{"op": "close", "id": id})
  for x in bufs:
    if x == b: continue
    if x.lang != nil and x.lang.mode == lmNim and x.path.len > 0 and x.title.len == 0 and
       (x.dirty or x.id in w.sent):
      wkSync(x)
  wkSync(b)

proc wkReady(b: Buffer): bool =
  ## the worker answers for this buffer (started now when it was not)
  if not wkOn() or b == nil or b.path.len == 0: return false
  var t0 = getMonoTime()
  if nimEngineOn(b): nxEnsureToolchain(b)   # (`nim dump` of its project runs here — the worker is told what it said)
  noteWork("the toolchain looked at", t0)
  t0 = getMonoTime()
  if not wkStart(): return false
  noteWork("the engine worker started", t0)
  wkp.usedAt = getMonoTime()
  true

# ── in the editor: asking ──

proc wkInlayStep(b: Buffer) =
  ## the hints of the chunks around the screen asked of the worker (the one in front first, then ahead in the
  ## direction you scroll, then behind) — engineInlayStep's order; nothing is worked out here
  ihPending = false
  if b.lines.len == 0 or not wkReady(b): return
  let key = $b.changeId & "/" & $nxGen & "/" & cfgParamHints & "/" & $cfgRaisesHints & "/" & $orGen & "/" & $cfgChainHints
  let st = addr ihStates.mgetOrPut(b.id, IhState(lastTop: b.topLine, down: true))
  let page = max(textH, 20)
  if b.inlayAt == -1:
    st.key = ""
    b.inlayAt = -2
  if st.key != key:
    if st.key.len > 0:
      var far: seq[int]
      for l in b.inlays.keys:
        if l < b.topLine - 3 * page or l > b.topLine + 4 * page: far.add l
      for l in far: b.inlays.del l
    st.key = key
    st.done.clear()
    st.tries.clear()
  if b.topLine != st.lastTop:
    st.down = b.topLine > st.lastTop
    st.lastTop = b.topLine
  let last = b.lines.high
  let visA = b.topLine div IhChunk
  let visB = min(last, b.topLine + textH) div IhChunk
  let below = min(last, b.topLine + textH + (if st.down: 2 * page else: page)) div IhChunk
  let above = max(0, b.topLine - (if st.down: page else: 2 * page)) div IhChunk
  var order: seq[int]
  for c in visA .. visB: order.add c
  if st.down:
    for c in visB + 1 .. below: order.add c
    for c in countdown(visA - 1, above): order.add c
  else:
    for c in countdown(visA - 1, above): order.add c
    for c in visB + 1 .. below: order.add c
  let fly = addr wkp.hintsFly.mgetOrPut(b.id, ("", initHashSet[int]()))
  if fly[0] != key:
    fly[0] = key
    fly[1].clear()
  var ask: seq[int]
  var visibleDone = true
  for c in order:
    if c in st.done: continue
    if c >= visA and c <= visB: visibleDone = false
    if c in fly[1]: continue
    ask.add c
  if visibleDone: b.inlayAt = b.changeId
  if ask.len == 0: return
  block:
    let st0 = getMonoTime()
    wkSyncAll(b)
    noteWork("texts sent to the engine worker", st0)
  wkSend(%*{"op": "hints", "id": b.id, "v": b.changeId, "key": key, "c": ask})
  for c in ask: fly[1].incl c

proc wkChecks(b: Buffer) =
  ## the misspelled names around the screen and the engine's checks of the file, asked of the worker
  typoAt[b.id] = b.changeId
  if b.path.len == 0 or b.lines.len > 15_000 or not nimEngineOn(b) or not wkReady(b): return
  let lo = max(0, b.topLine - 100)
  let hi = min(b.lines.high, b.topLine + max(textH, 20) + 100)
  block:
    let st0 = getMonoTime()
    wkSyncAll(b)
    noteWork("texts sent to the engine worker", st0)
  wkSend(%*{"op": "checks", "id": b.id, "v": b.changeId, "lo": lo, "hi": hi, "cl": b.primary.head.line,
            "cc": b.primary.head.col, "n3": b.path in nim3Asked})
  wkp.checksFly[b.id] = b.changeId

proc wkRefs(b: Buffer) =
  ## the reference counts of the declarations on screen (and a few lines around), asked of the worker
  if not wkReady(b): return
  let top = max(0, b.topLine - 5)
  let bottom = min(b.lines.high, b.topLine + max(20, textH) + 5)
  if wkp.refsAsked.getOrDefault(b.id, (-1, -1, -1)) == (b.changeId, top, bottom): return
  wkp.refsAsked[b.id] = (b.changeId, top, bottom)
  block:
    let st0 = getMonoTime()
    wkSyncAll(b)
    noteWork("texts sent to the engine worker", st0)
  wkSend(%*{"op": "refs", "id": b.id, "v": b.changeId, "top": top, "bottom": bottom})

proc wkWeb(b: Buffer): bool =
  ## ned's own CSS, HTML, SQL and JavaScript checks of the file (and of the code in its strings), asked of the
  ## worker — true when it was asked (the answer comes back)
  if not wkOn() or b.path.len == 0 or not wkReady(b): return false
  var srv = newJArray()
  for fam in ["css", "html", "sql", "js", "json"]:
    if webServerFor(b, fam): srv.add %fam
  block:
    let st0 = getMonoTime()
    wkSyncAll(b)
    noteWork("texts sent to the engine worker", st0)
  wkSend(%*{"op": "web", "id": b.id, "v": b.changeId, "srv": srv})
  true

proc wkDump(proj, o: string) =
  ## `nim dump` said what a project builds with: the worker is told too (and a new one later)
  for i, (p, _) in wkDumps:
    if p == proj:
      wkDumps[i] = (proj, o)
      if wkp != nil and not wkp.dead: wkSend(%*{"op": "dump", "proj": proj, "out": o})
      return
  wkDumps.add (proj, o)
  if wkp != nil and not wkp.dead: wkSend(%*{"op": "dump", "proj": proj, "out": o})

proc wkSettingsChanged() =
  ## the settings changed (yours, the project's): the worker's too — its hints and checks again
  if wkp == nil or wkp.dead: return
  wkSend(%*{"op": "settings", "s": wkSettingsJson(), "n3": nim3On()})
  for b in bufs:
    if b.id in ihStates: ihStates[b.id].key = ""
    typoAt.del b.id

proc wkFolderChanged() =
  ## another folder (or workspace): a new worker for it, when needed
  wkStop()

# ── in the editor: the answers ──

func wkDiagJson(d: Diag): JsonNode =
  result = %*{"l": d.line, "c": d.col, "el": d.eline, "ec": d.ecol, "s": d.sev, "m": d.msg, "r": d.rule, "src": d.src}
  # (what its quick fixes are made from: Nim 3's edits, a server's code and words)
  if d.code != nil: result["code"] = d.code
  if d.fixes != nil: result["fx"] = d.fixes
  if d.raw.len > 0: result["raw"] = %d.raw

func wkDiagOf(j: JsonNode): Diag =
  Diag(line: j{"l"}.getInt, col: j{"c"}.getInt, eline: j{"el"}.getInt, ecol: j{"ec"}.getInt, sev: j{"s"}.getInt,
       msg: j{"m"}.getStr, rule: j{"r"}.getStr, src: j{"src"}.getStr("ned"), code: j{"code"}, fixes: j{"fx"},
       raw: j{"raw"}.getStr)

proc wkHintsAnswer(j: JsonNode) =
  let b = bufById(j{"id"}.getInt)
  if b == nil or b.id notin ihStates: return
  let st = addr ihStates[b.id]
  let key = j{"key"}.getStr
  let c = j{"c"}.getInt
  if wkp != nil and b.id in wkp.hintsFly and wkp.hintsFly[b.id][0] == key: wkp.hintsFly[b.id][1].excl c
  if st.key != key: return                         # (for a text that has changed since: dropped)
  var got: Table[int, seq[(int, string)]]
  for x in jitems(j{"l"}):
    var hs: seq[(int, string)]
    for h in jitems(x[1]): hs.add (h[0].getInt, h[1].getStr)
    got[x[0].getInt] = hs
  let a = c * IhChunk
  let e = min(b.lines.high, a + IhChunk - 1)
  var changed = false
  for l in a .. e:
    let nw = got.getOrDefault(l)
    if nw != b.inlays.getOrDefault(l):
      if nw.len == 0: b.inlays.del l
      else: b.inlays[l] = nw
      changed = true
  st.done.incl c
  let visA = b.topLine div IhChunk
  let visB = min(b.lines.high, b.topLine + textH) div IhChunk
  var visibleDone = true
  for v in visA .. visB:
    if v notin st.done: visibleDone = false
  if visibleDone: b.inlayAt = b.changeId
  lastInlayMs = j{"ms"}.getInt
  if wkp != nil: wkp.hintsMs = lastInlayMs
  if changed: needRender = true

proc wkChecksAnswer(j: JsonNode) =
  let b = bufById(j{"id"}.getInt)
  if b == nil: return
  if wkp != nil: wkp.checksFly.del b.id
  if j{"v"}.getInt != b.changeId: return          # (an older text: the newer one is asked for after a pause)
  var found: seq[(int, int, string, string)]
  for t in jitems(j{"typos"}): found.add (t[0].getInt, t[1].getInt, t[2].getStr, t[3].getStr)
  var mine: seq[Diag]
  for d in jitems(j{"diags"}): mine.add wkDiagOf(d)
  lastChecksMs = j{"ms"}.getInt
  if wkp != nil:
    wkp.checksMs = lastChecksMs
    wkp.held = j{"held"}.getStr
  engineTyposApply(b, found, mine, j{"on"}.getBool)

proc wkRefsAnswer(j: JsonNode) =
  let b = bufById(j{"id"}.getInt)
  if b == nil or j{"v"}.getInt != b.changeId: return
  var lens = if wkRefsVer.getOrDefault(b.id, -1) == b.changeId: refLens.getOrDefault(b.id) else: initTable[int, (string, bool)]()
  let top = j{"top"}.getInt
  let bottom = j{"bottom"}.getInt
  var gone: seq[int]
  for l in lens.keys:
    if l >= top and l <= bottom: gone.add l
  for l in gone: lens.del l
  for x in jitems(j{"lens"}): lens[x[0].getInt] = (x[1].getStr, x[2].getBool)
  if lens != refLens.getOrDefault(b.id): needRender = true
  refLens[b.id] = lens
  wkRefsVer[b.id] = b.changeId

proc wkWebAnswer(j: JsonNode) =
  let b = bufById(j{"id"}.getInt)
  if b == nil or j{"v"}.getInt != b.changeId: return
  var ds: seq[Diag]
  for d in jitems(j{"diags"}): ds.add wkDiagOf(d)
  webChecksApply(b, ds)

proc wkAnswer(line: string) =
  var j: JsonNode
  try: j = parseJson(line)
  except CatchableError: return
  if wkp != nil: inc wkp.answers
  case j{"op"}.getStr
  of "hints": wkHintsAnswer(j)
  of "checks": wkChecksAnswer(j)
  of "refs": wkRefsAnswer(j)
  of "web": wkWebAnswer(j)
  of "resync":
    # (the edits did not fit what it had: the whole text next time, and what was asked, asked again)
    let id = j{"id"}.getInt
    if wkp != nil: wkp.sent.del id
    let b = bufById(id)
    if b != nil:
      b.wkLogFrom = -1
      if b.id in ihStates: ihStates[b.id].key = ""
      typoAt.del b.id
  of "error":
    wkLastErr = j{"m"}.getStr
    if wkVerify: internalError("engine worker", newException(CatchableError, wkLastErr))
  else: discard

proc wkRead(ready: HashSet[cint]) =
  ## the main loop: what the worker answered (and wrote to stderr), what waits to be written to it
  let w = wkp
  if w == nil: return
  if not w.dead and w.errFd >= 0 and w.errFd in ready:
    var buf = newString(4096)
    while true:
      let n = posix.read(w.errFd, addr buf[0], buf.len)
      if n <= 0: break
      w.ebuf.add buf[0 ..< n]
      if w.ebuf.len > 8192: w.ebuf = w.ebuf[^4096 .. ^1]
  if not w.dead and w.outFd in ready:
    var buf = newString(65536)
    while true:
      let n = posix.read(w.outFd, addr buf[0], buf.len)
      if n > 0:
        w.rbuf.add buf[0 ..< n]
      elif n == 0:
        w.dead = true
        break
      else:
        if errno != EAGAIN and errno != EWOULDBLOCK and errno != EINTR: w.dead = true
        break
    var start = 0
    while true:
      let nl = w.rbuf.find('\n', start)
      if nl < 0: break
      if nl > start:
        try: wkAnswer(w.rbuf[start ..< nl])
        except CatchableError as e: internalError("engine worker answer", e)
      start = nl + 1
    if start > 0: w.rbuf = w.rbuf[start .. ^1]
  wkFlush()
  if w.dead and wkp == w:
    # (it stopped: started again by the next question — or given up after a few times)
    for id in w.hintsFly.keys:
      if id in ihStates: ihStates[id].key = ""
    for id in w.checksFly.keys: typoAt.del id
    w.refsAsked.clear()
    discard w.pr.reap()
  elif not w.dead and msSince(w.usedAt) > WkIdleMs and w.hintsFly.len == 0 and w.checksFly.len == 0:
    wkStop()

proc wkFds(fds: var seq[TPollfd]) =
  if wkp == nil or wkp.dead: return
  fds.add TPollfd(fd: wkp.outFd, events: POLLIN)
  if wkp.errFd >= 0: fds.add TPollfd(fd: wkp.errFd, events: POLLIN)
  if wkp.wpos < wkp.wbuf.len: fds.add TPollfd(fd: wkp.inFd, events: POLLOUT)

proc wkReport(): string =
  ## (Help › Performance) what the worker does and costs
  if wkWorkerMode: return ""
  if not sBool("nim.engineWorker"): return "  engine worker: off (nim.engineWorker) — hints and checks worked out here\n"
  if wkOffWhy.len > 0: return "  engine worker: " & wkOffWhy & "\n"
  if wkp == nil or wkp.dead: return "  engine worker: not running (starts when a Nim file needs it)\n"
  let mb = procRssMB(wkp.pr.pid.int)
  "  engine worker: pid " & $wkp.pr.pid & ", " & $mb & " MB · the last hints took it " & $wkp.hintsMs &
    " ms, the last checks " & $wkp.checksMs & " ms · " & $wkp.answers & " answers, texts sent whole " &
    $wkp.fullSends & "×, as edits " & $wkp.editSends & "×" & (if wkLastErr.len > 0: " · last error: " & wkLastErr else: "") &
    "\n" & (if wkp.held.len > 0: "    it holds " & wkp.held & "\n" else: "")

# ── the worker itself (`ned --engine-worker`) ──

type WkTask = object
  kind: string                    # "hints" | "checks" | "refs" | "web"
  id, v: int
  key: string
  chunk: int
  lo, hi, cl, cc: int
  n3: bool

var
  wkIn, wkOut: cint
  wkInBuf: string
  wkTasks: seq[WkTask]
  wkQuit = false

proc wkWrite(j: JsonNode) =
  var s = $j
  s.add '\n'
  var off = 0
  while off < s.len:
    let n = posix.write(wkOut, addr s[off], s.len - off)
    if n > 0: off += n
    elif n < 0 and errno == EINTR: continue
    else:
      wkQuit = true                # (the editor is gone)
      return

proc wkDoc(id: int): Buffer =
  for x in bufs:
    if x.id == id and x.path.len > 0: return x
  nil

proc wkApplySettings(j: JsonNode) =
  if j{"s"} != nil and j["s"].kind == JObject:
    settingsJ = j["s"]
    applySettings()
    applyNimToolchain()
  if j{"n3"} != nil: discard
  nxApplyToolchain()
  ecLast.clear()
  typosLast.clear()

proc wkHandle(line: string) =
  var j: JsonNode
  try: j = parseJson(line)
  except CatchableError: return
  let id = j{"id"}.getInt
  case j{"op"}.getStr
  of "init":
    rootDir = j{"root"}.getStr
    wsRoots.setLen(0)
    for x in jitems(j{"ws"}): wsRoots.add x.getStr
    nxInitDefines()
    nxLibFound = nxGuessLib()
    nxLibGuessed = true
    wkApplySettings(j)
    for d in jitems(j{"dumps"}):
      nxDumpApply(d[0].getStr, d[1].getStr)
      nxDumped.incl d[0].getStr
  of "settings": wkApplySettings(j)
  of "dump":
    nxDumpApply(j{"proj"}.getStr, j{"out"}.getStr)
    nxDumped.incl j{"proj"}.getStr
  of "doc":
    var b = wkDoc(id)
    if b == nil:
      b = newBuffer()
      dec nextBufId
      b.id = id
      bufs.add b
    b.path = j{"path"}.getStr
    b.lang = langByName(j{"lang"}.getStr)
    if b.lang == nil or b.lang.name == "Text": b.lang = detectLang(b.path, "")
    b.lines = j{"text"}.getStr.split('\n')
    if b.lines.len == 0: b.lines = @[""]
    b.hlStart = newSeq[LexSt](b.lines.len + 1)
    b.hlValid = 0
    b.git = newSeq[uint8](b.lines.len)
    b.changeId = j{"v"}.getInt
    b.savedSeq = -1                   # (dirty: its text is not the file's)
    var keep: seq[WkTask]
    for t in wkTasks:
      if not (t.id == id and t.v < b.changeId): keep.add t
    wkTasks = keep
  of "edits":
    let b = wkDoc(id)
    if b == nil or b.changeId != j{"from"}.getInt:
      wkWrite(%*{"op": "resync", "id": id})
      return
    var ok = true
    try:
      for e in jitems(j{"e"}):
        let a = Pos(line: e[0].getInt, col: e[1].getInt)
        let c = Pos(line: e[2].getInt, col: e[3].getInt)
        if a.line < 0 or c.line >= b.lines.len or a.line > c.line or a.col > b.lines[a.line].len or
           c.col > b.lines[c.line].len:
          ok = false
          break
        discard b.rawReplace(a, c, e[4].getStr)
    except CatchableError, Defect: ok = false
    let hl = j{"hl"}.getInt
    if ok and (b.lines.len != j{"n"}.getInt or hl < 0 or hl >= b.lines.len or fnv(b.lines[hl]) != j{"h"}.getStr):
      ok = false
    if not ok:
      bufs.delete(bufs.find(b))
      wkWrite(%*{"op": "resync", "id": id})
      return
    b.changeId = j{"v"}.getInt
    # (questions about older versions of it: no use now)
    var keep: seq[WkTask]
    for t in wkTasks:
      if not (t.id == id and t.v < b.changeId): keep.add t
    wkTasks = keep
  of "close":
    let b = wkDoc(id)
    if b != nil: bufs.delete(bufs.find(b))
    var keep: seq[WkTask]
    for t in wkTasks:
      if t.id != id: keep.add t
    wkTasks = keep
  of "hints":
    let key = j{"key"}.getStr
    var keep: seq[WkTask]
    for t in wkTasks:
      if not (t.kind == "hints" and t.id == id and t.key != key): keep.add t
    wkTasks = keep
    for c in jitems(j{"c"}):
      var dup = false
      for t in wkTasks:
        if t.kind == "hints" and t.id == id and t.key == j{"key"}.getStr and t.chunk == c.getInt: dup = true
      if not dup:
        wkTasks.add WkTask(kind: "hints", id: id, v: j{"v"}.getInt, key: j{"key"}.getStr, chunk: c.getInt)
  of "checks":
    var keep: seq[WkTask]
    for t in wkTasks:
      if not (t.kind == "checks" and t.id == id): keep.add t
    wkTasks = keep
    wkTasks.add WkTask(kind: "checks", id: id, v: j{"v"}.getInt, lo: j{"lo"}.getInt, hi: j{"hi"}.getInt,
                       cl: j{"cl"}.getInt, cc: j{"cc"}.getInt, n3: j{"n3"}.getBool)
  of "web":
    var keep: seq[WkTask]
    for t in wkTasks:
      if not (t.kind == "web" and t.id == id): keep.add t
    wkTasks = keep
    var srv: seq[string]
    for x in jitems(j{"srv"}): srv.add x.getStr
    wkTasks.add WkTask(kind: "web", id: id, v: j{"v"}.getInt, key: srv.join(","))
  of "refs":
    var keep: seq[WkTask]
    for t in wkTasks:
      if not (t.kind == "refs" and t.id == id): keep.add t
    wkTasks = keep
    wkTasks.add WkTask(kind: "refs", id: id, v: j{"v"}.getInt, lo: j{"top"}.getInt, hi: j{"bottom"}.getInt)
  of "verify":
    let b = wkDoc(id)
    if b == nil or b.changeId != j{"v"}.getInt or fnv(b.lines.join("\n")) != j{"h"}.getStr:
      wkWrite(%*{"op": "error", "m": "the worker's text of " & j{"path"}.getStr & " is not the editor's (version " &
                 $j{"v"}.getInt & ")"})
      if b != nil: bufs.delete(bufs.find(b))
      wkWrite(%*{"op": "resync", "id": id})
  of "text":
    let b = wkDoc(id)
    wkWrite(%*{"op": "text", "id": id, "v": (if b == nil: -1 else: b.changeId),
               "text": (if b == nil: "" else: b.lines.join("\n"))})
  of "quit": wkQuit = true
  else: discard

proc wkDrain(wait: bool) =
  ## what the editor sent: read (waiting for it when there is nothing to do), each line handled
  var pf = [TPollfd(fd: wkIn, events: POLLIN)]
  let r = poll(addr pf[0], 1, (if wait: 60_000 else: 0).cint)
  if r < 0:
    if errno != EINTR: wkQuit = true
    return
  if r == 0:
    if wait and getppid() == 1: wkQuit = true    # (the editor is gone)
    return
  var buf = newString(65536)
  while true:
    let n = posix.read(wkIn, addr buf[0], buf.len)
    if n > 0:
      wkInBuf.add buf[0 ..< n]
      continue
    if n == 0: wkQuit = true
    elif errno != EINTR and errno != EAGAIN and errno != EWOULDBLOCK: wkQuit = true
    break
  var start = 0
  while true:
    let nl = wkInBuf.find('\n', start)
    if nl < 0: break
    if nl > start:
      try: wkHandle(wkInBuf[start ..< nl])
      except CatchableError as e: wkWrite(%*{"op": "error", "m": "handling: " & e.msg})
    start = nl + 1
  if start > 0: wkInBuf = wkInBuf[start .. ^1]

proc wkRunHints(t: WkTask) =
  let b = wkDoc(t.id)
  if b == nil or b.changeId != t.v: return
  curBuf = bufs.find(b)
  let t0 = getMonoTime()
  var hs: Table[int, seq[(int, string)]]
  let a = t.chunk * IhChunk
  let e = min(b.lines.high, a + IhChunk - 1)
  if a <= e:
    let f = try: nxFileFor(b) except CatchableError: nil
    if f != nil:
      let sc = nxScope(f)
      engineInlayBudget = 10_000                   # (no hurry here: nothing waits on this process — but not forever)
      let ct0 = getMonoTime()
      try:
        discard engineTypeHints(b, f, sc, a, e, hs, ct0)
        if cfgParamHints != "off": engineParamHints(b, f, a, e, hs, ct0)
        if cfgRaisesHints: discard engineRaisesHints(b, f, a, e, hs, ct0)
      except CatchableError, Defect: discard
  var ls = newJArray()
  for l in a .. e:
    if l in hs:
      var v = hs[l]
      v.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
      var arr = newJArray()
      for (c, lb) in v: arr.add %*[c, lb]
      ls.add %*[l, arr]
  wkWrite(%*{"op": "hints", "id": t.id, "key": t.key, "c": t.chunk, "l": ls, "ms": int(msSince(t0))})

proc wkRunChecks(t: WkTask) =
  let b = wkDoc(t.id)
  if b == nil or b.changeId != t.v: return
  curBuf = bufs.find(b)
  let t0 = getMonoTime()
  if t.n3: nim3Asked.incl b.path else: nim3Asked.excl b.path
  b.cursors = @[cur(Pos(line: clamp(t.cl, 0, b.lines.high), col: max(0, t.cc)))]
  b.prim = 0
  var typos = newJArray()
  var diags = newJArray()
  let f = try: nxFileFor(b) except CatchableError: nil
  if f != nil:
    try:
      for (l, c, w, meant) in nxTypos(f, b.lines, clamp(t.lo, 0, b.lines.high), clamp(t.hi, 0, b.lines.high),
                                      (t.cl, t.cc)):
        typos.add %*[l, c, w, meant]
    except CatchableError, Defect: discard
    if cfgEngineChecks:
      try:
        for d in engineChecksFor(b): diags.add wkDiagJson(d)
      except CatchableError, Defect: discard
  var scopeRefs = 0
  for _, sc in nxScopes: scopeRefs += sc.refs.len
  let held = $(nxFilesBytes div 1048576) & " MB of " & $nxFiles.len & " parsed files, " & $nxScopes.len & " scopes (" &
             $(scopeRefs div 1000) & "k names), the project's words: " & $refFilePath.len & " files · heap " &
             $(getOccupiedMem() div 1048576) & " MB in use of " & $(getTotalMem() div 1048576) & " MB · " & nxCacheStats()
  wkWrite(%*{"op": "checks", "id": t.id, "v": t.v, "typos": typos, "diags": diags, "on": cfgEngineChecks,
             "ms": int(msSince(t0)), "held": held})

var wkScanAt: MonoTime              # (the worker's list of the project's files: made again every 30 s)

proc wkEnsureScan() =
  if not fileCacheValid or msSince(wkScanAt) > 30_000:
    fileCacheValid = false
    startScan()
    while scanning: pumpScan(400)
    wkScanAt = getMonoTime()
    refFiles = nimSourceFiles()
    refFilesAt = getMonoTime()

proc wkRunWeb(t: WkTask) =
  let b = wkDoc(t.id)
  if b == nil or b.changeId != t.v: return
  curBuf = bufs.find(b)
  wkEnsureScan()
  wkWebServed = if t.key.len > 0: t.key.split(',') else: @[]
  var diags = newJArray()
  try:
    for d in webDiagsOf(b): diags.add wkDiagJson(d)
  except CatchableError, Defect: discard
  wkWrite(%*{"op": "web", "id": t.id, "v": t.v, "diags": diags})

proc wkRunRefs(t: WkTask) =
  ## the counts of the declarations of lines t.lo..t.hi — all of them, as long as they take
  let b = wkDoc(t.id)
  if b == nil or b.changeId != t.v or not cfgRefCounts: return
  curBuf = bufs.find(b)
  wkEnsureScan()
  for p in refFiles: refIndexFile(p)
  if b.path notin refFiles: refIndexFile(b.path)
  refComplete = true
  let f = try: nxFileFor(b) except CatchableError: nil
  if f == nil: return
  var lens = newJArray()
  for i in refLensDecls(b, f):
    let s = f.syms[i]
    if s.line < t.lo or s.line > t.hi: continue
    let key = b.path & "|" & s.name & "|" & $s.line
    let have = refCounts.getOrDefault(key, (-2, -1))
    var n = have[0]
    if have[1] != refVersion:
      n = try: refCountOf(b.path, f, i) except CatchableError, Defect: -3
      refCounts[key] = (n, refVersion)
    let label = if n == -3: "" elif n < 0: "5000+ references" elif n == 0: "no references"
                elif n == 1: "1 reference"
                else: $n & " references"
    if label.len > 0: lens.add %*[s.line, label, n == 0 and s.exported]
  wkWrite(%*{"op": "refs", "id": t.id, "v": t.v, "top": t.lo, "bottom": t.hi, "lens": lens})

proc workerMain() =
  ## `ned --engine-worker`: no screen; questions on stdin, answers on stdout, one JSON object a line
  wkWorkerMode = true
  wkIn = cint(posix.dup(0))
  wkOut = cint(posix.dup(1))
  setNonBlock(wkIn)
  let devnull = posix.open("/dev/null", O_RDWR)
  if devnull >= 0:
    discard dup2(devnull, 0)        # (nothing else may read the questions or write into the answers)
    discard dup2(devnull, 1)
  signal(SIGPIPE, SIG_IGN)
  initLangs()
  initSettingDefs()
  bufs = @[newBuffer()]             # (a buffer that is no file: the ones asked about come after it)
  curBuf = 0
  while not wkQuit:
    wkDrain(wait = wkTasks.len == 0)
    if wkQuit: break
    if wkTasks.len == 0: continue
    let t = wkTasks[0]
    wkTasks.delete(0)
    try:
      case t.kind
      of "hints": wkRunHints(t)
      of "checks": wkRunChecks(t)
      of "refs": wkRunRefs(t)
      of "web": wkRunWeb(t)
      else: discard
    except CatchableError as e: wkWrite(%*{"op": "error", "m": t.kind & ": " & e.msg})
  quit 0
