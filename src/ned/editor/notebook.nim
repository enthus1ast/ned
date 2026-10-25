# ── Notebook: a Nim or Python file's `# %%` cells run in one session that stays alive, each cell's output drawn
#    under it (rows that are not part of the text: nothing is written into the file). Nim's session is
#    `nim secret` (the compiler's VM: instant, its variables kept from cell to cell — no C libraries); with
#    notebook.nim = "compiled", a run builds and runs the cells up to that one as a program. Python's is python3
#    with the cells' variables kept, the last expression's value shown, as Jupyter does ──

const NbMark = "\x1e"                      # (what ends a cell's output: the session prints it with a number)

type
  NbOut = object
    code: string                           # the cell's text when it ran (changed since: the output is old)
    lines: seq[string]
    err: bool
    ms: int
    running: bool
    n: int                                 # its run's number in the session (Out [n])
  NbRun = object
    cell: int                              # which cell (from 0)
    first: int                             # its first line in the file
    count: int                             # its lines
    code: string
    token: string
    base: int                              # nim secret: the session's input line it starts at
    started: MonoTime
  NbSession = ref object
    bufId: int
    path, kind: string                     # kind: "nim" (nim secret) or "python"
    pr: Proc
    fdIn, fdOut: cint
    wbuf, rbuf: string
    queue: seq[NbRun]
    cur: NbRun
    busy, dead: bool
    inputLines: int                        # nim secret: lines sent so far (its errors say stdin(line, col))
    runs: int
    got: seq[string]                       # the current cell's output so far

var
  nbSessions: seq[NbSession]
  nbOuts: Table[int, seq[NbOut]]           # buffer id → each cell's output (by the cell's number)
  nbLaid: Table[int, (int, int, int)]      # buffer id → (the change, the outputs' version, the width) laid out
  nbVersion = 0
  nbBuild: Table[int, Job]                 # (notebook.nim = compiled: the build running for a buffer)

proc nbCells(b: Buffer): seq[(int, int)] =
  ## the cells: (first line, last line) of the code between `# %%` markers (what comes before the first marker is
  ## a cell too, when it has code)
  var start = 0
  for i in 0 .. b.lines.high:
    if replMarker(b.lines[i]):
      if i > start:
        var any = false
        for k in start ..< i:
          if b.lines[k].strip.len > 0: any = true
        if any or result.len > 0: result.add (start, i - 1)
      start = i + 1
  if start <= b.lines.high: result.add (start, b.lines.high)

proc nbKind(b: Buffer): string =
  if b == nil or b.lang == nil: return ""
  if b.lang.mode == lmNim and b.path.endsWith(".nim"): "nim"
  elif b.lang.id == "python": "python"
  else: ""

proc nbCanRun(b: Buffer): bool =
  ## a file the notebook runs: Nim or Python, with `# %%` cells
  nbKind(b).len > 0 and replHasCells(b)

proc nbSessionOf(b: Buffer): NbSession =
  for s in nbSessions:
    if s.bufId == b.id and not s.dead: return s
  nil

proc nbActive(b: Buffer): bool = nbSessionOf(b) != nil or b.id in nbOuts

proc nbCellCode(b: Buffer, c: (int, int)): string =
  var ls: seq[string]
  for i in c[0] .. c[1]: ls.add b.lines[i].replace("\t", "    ")
  while ls.len > 0 and ls[^1].strip.len == 0: ls.setLen(ls.len - 1)
  ls.join("\n")

# ── the rows under each cell ──

proc nbLayout(b: Buffer) =
  ## each cell's output as rows under its last line of code (a long output: its first lines, and how many more)
  b.vrows.clear()
  let outs = nbOuts.getOrDefault(b.id)
  if outs.len == 0: return
  let cells = nbCells(b)
  let maxRows = max(3, sInt("notebook.outputLines"))
  for ci, c in cells:
    if ci >= outs.len: break
    let o = outs[ci]
    if o.code.len == 0 and not o.running: continue
    var last = c[1]
    while last > c[0] and b.lines[last].strip.len == 0: dec last
    let old = not o.running and o.code != nbCellCode(b, c)
    var rows: seq[VRow]
    var head: seq[(string, Rgb, set[Attr])]
    if o.running:
      head.add ("⟳ running…", theme.accent, {aItalic})
    else:
      head.add (("Out [" & $o.n & "]"), (if o.err: theme.err else: theme.accent), {aBold})
      head.add ((" · " & (if o.ms < 1000: $o.ms & " ms" else: formatFloat(o.ms / 1000, ffDecimal, 1) & " s")),
                theme.dim, {})
      if old: head.add (" · the cell changed since it ran", theme.dim, {aItalic})
      if o.lines.len == 0: head.add (" · no output", theme.dim, {})
    rows.add VRow(spans: head, bg: NoColor)
    let fg = if old: theme.dim elif o.err: theme.err else: theme.fg
    var shown = 0
    for l in o.lines:
      if shown >= maxRows: break
      rows.add VRow(spans: @[(l.replace("\t", "    "), fg, set[Attr]({}))], bg: NoColor)   # (cut at the edge)
      inc shown
    if o.lines.len > shown:
      rows.add VRow(spans: @[("… " & $(o.lines.len - shown) & " more lines — Notebook: the cell's whole output",
                              theme.dim, {aItalic})], bg: NoColor)
    b.vrows[last] = rows

proc nbRefresh() =
  ## the rows under the cells laid out again when the text, an output or the width changed
  for b in bufs:
    if b.id notin nbOuts and b.vrows.len == 0: continue
    let key = (b.changeId, nbVersion, textW)
    if nbLaid.getOrDefault(b.id, (-1, -1, -1)) == key: continue
    nbLaid[b.id] = key
    nbLayout(b)
    needRender = true

proc nbSetOut(bufId, cell: int, o: NbOut) =
  var outs = nbOuts.getOrDefault(bufId)
  while outs.len <= cell: outs.add NbOut()
  outs[cell] = o
  nbOuts[bufId] = outs
  inc nbVersion
  needRender = true

# ── problems: a cell's error on its line ──

proc nbProblems(path: string, first, last: int, ds: seq[Diag]) =
  ## the notebook's problems in the lines of one cell, replaced
  var keep: seq[Diag]
  for d in diagsBuild.getOrDefault(path):
    if not (d.src == "notebook" and d.line >= first and d.line <= last): keep.add d
  for d in ds: keep.add d
  if keep.len > 0: diagsBuild[path] = keep
  elif path in diagsBuild: diagsBuild.del path

func nbStripPrompt(s: string): string =
  ## nim secret's ">>> " and "... " before what a line prints
  var t = s
  while t.startsWith(">>> ") or t.startsWith("... "): t = t[4 .. ^1]
  if t == ">>>" or t == "...": t = ""
  t

# ── the session ──

const NbPyDriver = """
import sys, json, ast, traceback
ns = {"__name__": "__main__"}
for line in sys.stdin:
    try: req = json.loads(line)
    except ValueError: continue
    try:
        tree = ast.parse(req["code"], filename=req["file"])
        ast.increment_lineno(tree, req["line"])
        last = None
        if tree.body and isinstance(tree.body[-1], ast.Expr):
            last = ast.Expression(tree.body.pop().value)
        exec(compile(tree, req["file"], "exec"), ns)
        if last is not None:
            v = eval(compile(last, req["file"], "eval"), ns)
            if v is not None: print(repr(v))
    except SystemExit: pass
    except BaseException:
        sys.stdout.flush()
        traceback.print_exc(file=sys.stdout)
    sys.stdout.flush(); sys.stderr.flush()
    print("\x1e" + req["token"], flush=True)
"""

proc nbStart(b: Buffer): NbSession =
  let kind = nbKind(b)
  let dir = parentDir(b.path)
  var argv: seq[string]
  if kind == "nim":
    if not haveExe("nim"):
      error("nim is not installed")
      return nil
    argv = @["nim", "secret", "--hints:off", "--warnings:off", "--path:" & dir]
  else:
    let py = if haveExe("python3"): "python3" elif haveExe("python"): "python" else: ""
    if py.len == 0:
      error("python3 is not installed")
      return nil
    argv = @[py, "-u", "-c", NbPyDriver]
  var pr: Proc
  try: pr = spawnProc(argv, dir, siPipe, erMerge)
  except OSError as e:
    error("Could not start the notebook's session: " & e.msg)
    return nil
  setNonBlock(pr.outFd)
  setNonBlock(pr.inFd)
  result = NbSession(bufId: b.id, path: b.path, kind: kind, pr: pr, fdIn: pr.inFd, fdOut: pr.outFd)
  nbSessions.add result

proc nbStop(s: NbSession) =
  if s.dead: return
  s.dead = true
  if s.pr.pid > 0:
    discard posix.kill(Pid(-s.pr.pid), SIGTERM)
    reapSoon(s.pr.pid)
  closeFd(s.fdIn)
  closeFd(s.fdOut)
  s.fdIn = -1
  s.fdOut = -1

proc nbSend(s: NbSession) =
  ## the next cell in the queue to the session
  if s.busy or s.dead or s.queue.len == 0: return
  let r0 = s.queue[0]
  s.queue.delete(0)
  var r = r0
  inc s.runs
  r.token = $s.runs
  r.started = getMonoTime()
  r.base = s.inputLines
  s.cur = r
  s.busy = true
  s.got.setLen(0)
  if s.kind == "nim":
    # (a blank line ends what the cell left open; the echo says where its output ends)
    s.wbuf.add r.code & "\n\necho \"\\x1e" & r.token & "\"\n"
    s.inputLines += r.code.count('\n') + 3
  else:
    s.wbuf.add $(%*{"code": r.code, "token": r.token, "file": s.path, "line": r.first}) & "\n"
  nbSetOut(s.bufId, r.cell, NbOut(code: r.code, running: true, n: s.runs))

proc nbFinish(s: NbSession, ended = "") =
  ## the cell's output complete: under it, and its errors on its lines
  let r = s.cur
  s.busy = false
  var lines: seq[string]
  var ds: seq[Diag]
  var err = false
  var seen: HashSet[string]
  for raw in s.got:
    let l = (if s.kind == "nim": nbStripPrompt(raw) else: raw).strip(leading = false)
    if s.kind == "nim":
      # stdin(line, col) Error: …  — said once (the VM says some twice)
      let k = l.find("stdin(")
      if k >= 0 and (") Error: " in l or ") Warning: " in l):
        if l in seen: continue
        seen.incl l
        let e = l.find(')', k)
        let nums = l[k + 6 ..< e].split(',')
        if nums.len == 2:
          try:
            let ln = parseInt(nums[0].strip) - 1 - r.base
            let col = parseInt(nums[1].strip) - 1
            let msg = l[e + 2 .. ^1].strip
            let sev = if msg.startsWith("Error"): 1 else: 2
            if sev == 1: err = true
            if ln >= 0 and ln < r.count:
              ds.add Diag(line: r.first + ln, col: max(0, col), eline: r.first + ln, ecol: -1, sev: sev,
                          msg: msg.replace("Error: ", "").replace("Warning: ", ""), src: "notebook")
            lines.add "line " & $(r.first + max(0, ln) + 1) & ": " & msg
            continue
          except ValueError: discard
      if "Error: unhandled exception" in l or "Error: " in l: err = true
    else:
      if l.startsWith("Traceback (most recent call last)"): err = true
      # File "/path/x.py", line 12, in <module>
      let fk = l.find("File \"" & s.path & "\", line ")
      if fk >= 0:
        let rest = l[fk + ("File \"" & s.path & "\", line ").len .. ^1]
        var n = 0
        var i = 0
        while i < rest.len and rest[i] in Digits:
          n = n * 10 + (ord(rest[i]) - ord('0'))
          inc i
        if n > 0: ds = @[Diag(line: n - 1, col: 0, eline: n - 1, ecol: -1, sev: 1, msg: "", src: "notebook")]
    if lines.len < 5000: lines.add l
  if s.kind == "python" and err and ds.len > 0:
    # (the traceback's last line says what went wrong: the problem says it too)
    var last = ""
    for l in countdown(lines.high, 0):
      if lines[l].strip.len > 0:
        last = lines[l].strip
        break
    ds[0].msg = last
  while lines.len > 0 and lines[^1].strip.len == 0: lines.setLen(lines.len - 1)
  if ended.len > 0:
    lines.add ended
    err = true
  nbSetOut(s.bufId, r.cell, NbOut(code: r.code, lines: lines, err: err, ms: int(msSince(r.started)), n: s.runs))
  nbProblems(s.path, r.first, r.first + max(0, r.count - 1), ds)
  var ffi = false
  for l in lines:
    if "VM not allowed to do FFI" in l or "cannot 'importc'" in l or "cannot evaluate at compile time" in l: ffi = true
  if s.kind == "nim" and ffi:
    info("This cell needs what the VM does not have (C libraries): notebook.nim = \"compiled\" runs the cells as " &
         "a program")
  nbSend(s)

proc nbFds(fds: var seq[TPollfd]) =
  for s in nbSessions:
    if s.dead: continue
    if s.fdOut >= 0: fds.add TPollfd(fd: s.fdOut, events: POLLIN)
    if s.fdIn >= 0 and s.wbuf.len > 0: fds.add TPollfd(fd: s.fdIn, events: POLLOUT)

proc nbPump(ready: HashSet[cint]) =
  nbRefresh()
  if nbSessions.len == 0: return
  var gone: seq[NbSession]
  for s in nbSessions:
    if s.dead:
      gone.add s
      continue
    if bufById(s.bufId) == nil:            # (the file was closed: its session goes)
      nbStop(s)
      gone.add s
      continue
    while s.wbuf.len > 0 and s.fdIn >= 0:
      let n = posix.write(s.fdIn, addr s.wbuf[0], s.wbuf.len)
      if n > 0: s.wbuf = s.wbuf[n .. ^1]
      else: break
    if s.fdOut >= 0 and s.fdOut in ready:
      var chunk = newString(65536)
      let n = posix.read(s.fdOut, addr chunk[0], chunk.len)
      if n > 0:
        s.rbuf.add chunk[0 ..< n]
        while true:
          let nl = s.rbuf.find('\n')
          if nl < 0: break
          let line = s.rbuf[0 ..< nl]
          s.rbuf = s.rbuf[nl + 1 .. ^1]
          let m = line.find(NbMark & s.cur.token)
          if s.busy and m >= 0 and line[m + 1 .. ^1].strip == s.cur.token:
            if m > 0: s.got.add line[0 ..< m]
            nbFinish(s)
          elif s.busy:
            if s.got.len < 20_000: s.got.add line
        needRender = true
      elif n == 0 or (n < 0 and errno notin [EAGAIN, EINTR]):
        # the session ended (nim secret stops at an error the VM cannot go on from)
        if s.busy:
          if s.rbuf.len > 0: s.got.add s.rbuf
          nbFinish(s, "(the session ended — its variables are gone: the next run starts a new one)")
        nbStop(s)
        gone.add s
    if s.busy and msSince(s.cur.started) > max(5, sInt("notebook.timeoutSeconds")) * 1000:
      nbFinish(s, "(no end after " & $sInt("notebook.timeoutSeconds") & " s — stopped: the session starts again " &
                  "at the next run)")
      nbStop(s)
      gone.add s
  for s in gone:
    let i = nbSessions.find(s)
    if i >= 0: nbSessions.delete(i)

proc nbNextDueMs(): int =
  ## how soon the loop must look again: a cell running (its timeout), the rows to lay out
  result = int.high
  for s in nbSessions:
    if s.busy: result = min(result, 500)
  for b in bufs:
    if b.id in nbOuts and nbLaid.getOrDefault(b.id, (-1, -1, -1)) != (b.changeId, nbVersion, textW):
      return 0

# ── notebook.nim = compiled: the cells up to this one as a program ──

proc nbRunCompiled(b: Buffer, upto: int) =
  ## the cells from the first to `upto` built and run (each one's output between marks): all their outputs anew
  if b.id in nbBuild:
    info("Notebook: a run is going on")
    return
  let cells = nbCells(b)
  if upto < 0 or upto >= cells.len: return
  let tmp = privTmp("notebook")
  try: createDir(tmp)
  except OSError: discard
  var src = ""
  var lineMap: seq[(int, int)]                   # the program's line → (the cell, the file's line)
  var codes: seq[string]
  for ci in 0 .. upto:
    let c = cells[ci]
    src.add "echo \"\\x1eB" & $ci & "\"\n"
    lineMap.add (-1, -1)
    let code = nbCellCode(b, c)
    codes.add code
    let codeLines = code.split('\n')
    for k, l in codeLines:
      src.add l & "\n"
      lineMap.add (ci, c[0] + k)
    src.add "\necho \"\\x1eE" & $ci & "\"\n"
    lineMap.add (-1, -1)
    lineMap.add (-1, -1)
  let main = tmp / (splitFile(b.path).name & "_nb.nim")
  try: writeFile(main, src)
  except CatchableError as e:
    error("Notebook: " & e.msg)
    return
  for ci in 0 .. upto: nbSetOut(b.id, ci, NbOut(code: codes[ci], running: true))
  let bid = b.id
  let path = b.path
  let t0 = getMonoTime()
  let cmd = "nim c -r --hints:off --warnings:off --path:" & quoteShell(parentDir(b.path)) & " --nimcache:" &
            quoteShell(tmp / "nc") & " -o:" & quoteShell(tmp / "prog") & " " & quoteShell(main)
  let j = startJob(jkRun, cmd, parentDir(b.path), proc(j: Job) =
    nbBuild.del bid
    var per = newSeq[seq[string]](upto + 1)
    var cur = -1
    var ds: seq[Diag]
    var buildErr: seq[string]
    for raw in j.output.splitLines:
      let l = stripAnsi(raw)
      if l.startsWith(NbMark & "B"):
        cur = (try: parseInt(l[2 .. ^1].strip) except ValueError: -1)
        continue
      if l.startsWith(NbMark & "E"):
        cur = -1
        continue
      if cur >= 0 and cur <= upto:
        per[cur].add l
        continue
      # a compile error in the program: on the cell's line
      let (ok, p, ln, col, sev, m) = parseErrLine(l, parentDir(main))
      if ok and p == main and ln >= 0 and ln < lineMap.len and lineMap[ln][0] >= 0:
        ds.add Diag(line: lineMap[ln][1], col: col, eline: lineMap[ln][1], ecol: -1, sev: sev, msg: m, src: "notebook")
        buildErr.add "line " & $(lineMap[ln][1] + 1) & ": " & m
      elif l.strip.len > 0 and not l.startsWith("CC:") and not l.startsWith("Hint:"): buildErr.add l
    let ms = int(msSince(t0))
    let failed = j.code != 0
    for ci in 0 .. upto:
      var o = NbOut(code: codes[ci], lines: per[ci], ms: ms)
      if failed and ci == upto and per[ci].len == 0 and ds.len == 0:
        o.lines = buildErr
        o.err = true
      nbSetOut(bid, ci, o)
    if ds.len > 0:
      let c = ds[0].line
      for ci in 0 .. upto:
        if c >= cells[ci][0] and c <= cells[ci][1]:
          nbSetOut(bid, ci, NbOut(code: codes[ci], lines: buildErr, err: true, ms: ms))
    nbProblems(path, cells[0][0], cells[upto][1], ds)
    try: removeDir(tmp)
    except CatchableError: discard
    needRender = true)
  if j != nil: nbBuild[bid] = j

# ── the commands ──

proc nbRunCells(b: Buffer, which: seq[int]) =
  if not nbCanRun(b):
    info("Notebook: a Nim or Python file with # %% cells (each starts after a line # %%)")
    return
  let cells = nbCells(b)
  if which.len == 0 or cells.len == 0: return
  if b.lang.mode == lmNim and sStr("notebook.nim") == "compiled":
    nbRunCompiled(b, which.max)
    return
  var s = nbSessionOf(b)
  if s == nil: s = nbStart(b)
  if s == nil: return
  for ci in which:
    if ci < 0 or ci >= cells.len: continue
    let c = cells[ci]
    let code = nbCellCode(b, c)
    if code.strip.len == 0: continue
    s.queue.add NbRun(cell: ci, first: c[0], count: c[1] - c[0] + 1, code: code)
  nbSend(s)

proc nbCellIndexAt(b: Buffer, line: int): int =
  ## the cell a line is in (a marker line: the cell it starts)
  let cells = nbCells(b)
  for i, c in cells:
    if line >= c[0] - 1 and line <= c[1]: return i
  if cells.len > 0 and line > cells[^1][1]: return cells.high
  0

proc nbRunAt(b: Buffer, line: int, advance = false) =
  ## the cell at the line run (advance: then the cursor to the next cell, as Jupyter's Shift+Enter)
  let ci = nbCellIndexAt(b, line)
  nbRunCells(b, @[ci])
  if advance:
    let cells = nbCells(b)
    if ci + 1 < cells.len:
      b.setSingle(Pos(line: cells[ci + 1][0], col: 0))
      b.ensureVisible()

proc cmdNbRunCell(advance: bool) =
  let b = buf()
  nbRunAt(b, b.primary.head.line, advance)

proc cmdNbRunAll() =
  let b = buf()
  var xs: seq[int]
  for i in 0 ..< nbCells(b).len: xs.add i
  nbRunCells(b, xs)

proc cmdNbRunAbove() =
  let b = buf()
  let ci = nbCellIndexAt(b, b.primary.head.line)
  var xs: seq[int]
  for i in 0 .. ci: xs.add i
  nbRunCells(b, xs)

proc cmdNbClear() =
  let b = buf()
  nbOuts.del b.id
  b.vrows.clear()
  var keep: seq[Diag]
  for d in diagsBuild.getOrDefault(b.path):
    if d.src != "notebook": keep.add d
  if b.path in diagsBuild: diagsBuild[b.path] = keep
  inc nbVersion
  needRender = true
  info("Notebook: the outputs cleared (the session keeps its variables — Notebook: restart forgets them)")

proc cmdNbRestart() =
  let b = buf()
  let s = nbSessionOf(b)
  if s != nil: nbStop(s)
  let i = nbSessions.find(s)
  if i >= 0: nbSessions.delete(i)
  info("Notebook: the session stopped — its variables are gone; the next run starts a new one")

proc cmdNbWholeOutput() =
  let b = buf()
  let ci = nbCellIndexAt(b, b.primary.head.line)
  let outs = nbOuts.getOrDefault(b.id)
  if ci >= outs.len or outs[ci].lines.len == 0:
    info("Notebook: this cell has no output yet (Ctrl+Enter runs it)")
    return
  discard openScratch("Out [" & $outs[ci].n & "] — " & b.name, outs[ci].lines.join("\n") & "\n", langByName("Text"))
