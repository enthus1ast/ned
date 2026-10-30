# Nim: run with ned's line profiler — a small module (kept in this file as text) is imported into the program, which
# samples where it is about every millisecond and writes the counts when it ends; ned reads them back into a panel of
# the procs that took the most time and a share beside each line.
const NedLineProf = """# ned's line profiler, imported into the program being profiled (--import): about every millisecond it notes
# where the program is — the line running (self) and every line and proc on the stack (total) — and writes the
# counts when the program ends. The sampling itself allocates nothing: it can run inside the allocator.
when not defined(profiler): {.error: "ned_lineprof needs --profiler:on".}
import std/[monotimes, times, os, exitprocs]
{.push profiler: off, stackTrace: off, lineTrace: off, checks: off.}
const
  NedSlots = 1 shl 15
  NedStackSlots = 1 shl 12
  NedDepth = 40
type
  NedSlot = object
    file, name: cstring
    line: int32
    self, total: int32
  NedStack = object                     # a whole call stack (for the flame graph): its procs, the innermost first
    used: bool
    n: int32
    procs, files: array[NedDepth, cstring]
    count: int32
var
  nedLines: array[NedSlots, NedSlot]      # (file, line) → counts
  nedProcs: array[NedSlots, NedSlot]      # (file, proc) → counts
  nedStacks: array[NedStackSlots, NedStack]   # the call stacks → how often each was seen
  nedSamples = 0
  nedLast: MonoTime
  nedEvery = initDuration(microseconds = 1000)
  nedBusy = true

proc nedSlotOf(tab: var array[NedSlots, NedSlot], file, name: cstring, line: int32): int =
  var h = (cast[uint](file) * 31'u + cast[uint](name) * 17'u + uint(line) * 2654435761'u) and uint(NedSlots - 1)
  for _ in 0 ..< NedSlots:
    let s = addr tab[int(h)]
    if s.file == nil:
      s.file = file
      s.name = name
      s.line = line
      return int(h)
    if s.file == file and s.name == name and s.line == line: return int(h)
    h = (h + 1) and uint(NedSlots - 1)
  -1

proc nedWanted(): bool {.nimcall, gcsafe.} =
  {.cast(gcsafe).}:
    if nedBusy: return false
    nedBusy = true                # (the clock's own code is profiled too)
    let now = getMonoTime()
    result = now - nedLast >= nedEvery
    if result: nedLast = now
    nedBusy = false

proc nedStackAdd(procs, files: array[NedDepth, cstring], n: int32) =
  var h = 0'u
  for i in 0 ..< n: h = h * 1000003'u + cast[uint](procs[i]) * 31'u + cast[uint](files[i])
  var k = int(h and uint(NedStackSlots - 1))
  for _ in 0 ..< NedStackSlots:
    let s = addr nedStacks[k]
    if not s.used:
      s.used = true
      s.n = n
      s.procs = procs
      s.files = files
      s.count = 1
      return
    if s.n == n:
      var same = true
      for i in 0 ..< n:
        if s.procs[i] != procs[i] or s.files[i] != files[i]:
          same = false
          break
      if same:
        inc s.count
        return
    k = (k + 1) and (NedStackSlots - 1)

proc nedHook(st: StackTrace) {.nimcall.} =
  nedBusy = true
  var f = getFrame()
  inc nedSamples
  # (a stack deeper than NedDepth keeps its outermost procs: the program's top stays at the top of the graph)
  var all: array[512, PFrame]
  var an = 0
  block:
    var g = f
    while g != nil and an < all.len:
      if g.procname != nil:
        all[an] = g
        inc an
      g = g.prev
  var sp, sf: array[NedDepth, cstring]
  var sn = 0'i32
  for i in max(0, an - NedDepth) ..< an:
    sp[sn] = all[i].procname
    sf[sn] = all[i].filename
    inc sn
  nedStackAdd(sp, sf, sn)
  var seenL, seenP: array[64, int]
  var nL, nP = 0
  var top = true
  var depth = 0
  while f != nil and depth < 64:
    if f.filename != nil:
      let li = nedSlotOf(nedLines, f.filename, nil, int32(f.line))
      if li >= 0:
        if top: inc nedLines[li].self
        var dup = false
        for k in 0 ..< nL:
          if seenL[k] == li: dup = true
        if not dup:
          inc nedLines[li].total
          seenL[nL] = li
          inc nL
      if f.procname != nil:
        let pi = nedSlotOf(nedProcs, f.filename, f.procname, 0)
        if pi >= 0:
          if top: inc nedProcs[pi].self
          var dup = false
          for k in 0 ..< nP:
            if seenP[k] == pi: dup = true
          if not dup:
            inc nedProcs[pi].total
            seenP[nP] = pi
            inc nP
      top = false
    f = f.prev
    inc depth
  nedBusy = false

proc nedWrite() {.noconv.} =
  nedBusy = true
  var o = "ned-lineprof 1\t" & $nedSamples & "\n"
  for s in nedLines:
    if s.file != nil: o.add "L\t" & $s.self & "\t" & $s.total & "\t" & $s.line & "\t" & $s.file & "\n"
  for s in nedProcs:
    if s.file != nil: o.add "P\t" & $s.self & "\t" & $s.total & "\t" & $s.name & "\t" & $s.file & "\n"
  for s in nedStacks:
    if not s.used: continue
    o.add "S\t" & $s.count
    for i in countdown(s.n - 1, 0):            # (the outermost first)
      o.add "\t" & $s.procs[i] & "\x1f" & (if s.files[i] == nil: "" else: $s.files[i])
    o.add "\n"
  try: writeFile(getEnv("NED_LINEPROF", "ned_lineprof.txt"), o)
  except CatchableError: discard

nedLast = getMonoTime()
profilingRequestedHook = nedWanted
profilerHook = nedHook
addExitProc(nedWrite)
nedBusy = false
{.pop.}
"""

proc profLoad(path: string): bool =
  ## ned_lineprof's counts → profLines (by file and line), profDecls (on each proc's first line), the panel's rows
  var lines0: seq[string]
  try: lines0 = readFile(path).splitLines
  except CatchableError: return false
  if lines0.len == 0 or not lines0[0].startsWith("ned-lineprof"): return false
  # (the profile before: kept for Nim: compare with the previous profile)
  if profRows.len > 0:
    profPrevRows = profRows
    profPrevSamples = profSamples
  profStacks.setLen(0)
  profLines.clear()
  profDecls.clear()
  profRows.setLen(0)
  profMtime.clear()
  profSamples = (try: parseInt(lines0[0].split('\t')[^1]) except ValueError: 0)
  var procs: Table[(string, string), (int, int)]     # (name, file) → (self, total)
  for l in lines0[1 .. ^1]:
    let f = l.split('\t')
    if f.len < 5: continue
    let selfN = (try: parseInt(f[1]) except ValueError: 0)
    let totN = (try: parseInt(f[2]) except ValueError: 0)
    let file = normalizedPath(f[4 .. ^1].join("\t"))
    if f[0] == "L":
      let ln = (try: parseInt(f[3]) - 1 except ValueError: -1)
      if ln < 0: continue
      var t = profLines.getOrDefault(file)
      let o = t.getOrDefault(ln)
      t[ln] = (o[0] + selfN, o[1] + totN)
      profLines[file] = t
    elif f[0] == "P":
      let k = (f[3], file)
      let o = procs.getOrDefault(k)
      procs[k] = (o[0] + selfN, o[1] + totN)
  for l in lines0[1 .. ^1]:
    if not l.startsWith("S\t"): continue
    let f = l.split('\t')
    let n = (try: parseInt(f[1]) except ValueError: 0)
    var st: seq[(string, string)]
    for x in f[2 .. ^1]:
      let k = x.find('\x1f')
      if k < 0: continue
      let name = x[0 ..< k]
      if name in ["NimMain", "NimMainInner", "PreMain", "PreMainInner"]: continue
      st.add (name, normalizedPath(x[k + 1 .. ^1]))
    if n > 0 and st.len > 0: profStacks.add (st, n)
  # each proc at its declaration: in the file the sample names, else (an iterator from the standard library ran
  # inside it) the project's proc of that name
  let projFiles = nimSourceFiles()
  for (k, v) in procs.pairs:
    let (name, file) = k
    if name.len == 0 or name in ["...", "NimMainModule", "NimMain", "PreMain"]: continue
    var where = ("", -1)
    for cand in @[file] & projFiles:
      if not fileExists(cand): continue
      let nf = nxLoad(cand)
      if nf == nil: continue
      for sy in nf.syms:
        if sy.kind in NxRoutineKinds and sy.name == name:
          where = (cand, sy.line)
          break
      if where[1] >= 0: break
    let shown = if name == splitFile(file).name: "(top level)" else: name
    let rf = if where[1] >= 0: where[0] else: file
    var merged = false
    for r in profRows.mitems:
      if r[0] == shown and r[1] == rf and r[2] == where[1]:
        r[3] += v[0]
        r[4] += v[1]
        merged = true
    if not merged: profRows.add (shown, rf, where[1], v[0], v[1])
    if where[1] >= 0:
      var t = profDecls.getOrDefault(where[0])
      let o = t.getOrDefault(where[1])
      t[where[1]] = (o[0] + v[0], o[1] + v[1])
      profDecls[where[0]] = t
  var files: seq[string]
  for f in profLines.keys: files.add f
  for f in profDecls.keys: files.add f
  for f in files:
    try: profMtime[f] = getLastModificationTime(f).toUnix
    except CatchableError: discard
  profRows.sort(proc(x, y: (string, string, int, int, int)): int = cmp(y[4] * 100000 + y[3], x[4] * 100000 + x[3]))
  profShown = true
  true

proc profPanel() =
  ## the procs that took the most time: total (with what they call) and self, click to go there
  panelKind = pkSearch
  panelLines.setLen(0)
  panelLines.add PanelLine(text: "  total %   self %   proc   (" & $profSamples & " samples, about 1 ms apart · the lines' share " &
                                 "is at the end of each line in the editor)", sev: 5, line: -1)
  for (name, file, line, selfN, totN) in profRows[0 ..< min(profRows.len, 200)]:
    if totN * 1000 < profSamples: continue       # (under 0.1 %)
    let tp = totN * 100 / max(profSamples, 1)
    let sp = selfN * 100 / max(profSamples, 1)
    let shown = if nxLibDir.len > 0 and file.startsWith(nxLibDir & "/"): "lib/" & file[nxLibDir.len + 1 .. ^1]
                else: relPath(file)          # (the standard library's files by their place in it)
    panelLines.add PanelLine(text: align(formatFloat(tp, ffDecimal, 1), 8) & "  " & align(formatFloat(sp, ffDecimal, 1), 7) &
                             "   " & name & "  " & shown & (if line >= 0: ":" & $(line + 1) else: ""),
                             path: (if line >= 0: file else: ""), line: line)
  panelTitle = "PROFILE · " & $profSamples & " samples"
  panelOpen = true
  panelFollow = false
  needRender = true

proc profFor(b: Buffer): (Table[int, (int, int)], Table[int, (int, int)]) =
  ## this file's profile — (lines, declarations) — while it is the text that was profiled
  if not profShown or b.path.len == 0 or b.dirty: return
  let p = normalizedPath(b.path)
  if p notin profLines and p notin profDecls: return
  if profChecked.getOrDefault(b.id, -1) != b.changeId:
    var same = true
    try: same = getLastModificationTime(p).toUnix == profMtime.getOrDefault(p)
    except CatchableError: same = false
    profChecked[b.id] = b.changeId
    profStale[b.id] = not same
  if profStale.getOrDefault(b.id): return
  (profLines.getOrDefault(p), profDecls.getOrDefault(p))

proc cmdProfile() =
  ## run with ned's line profiler: where the time went, by proc (the panel) and by line (beside the code)
  let b = buf()
  if b.lang.mode != lmNim or b.path.len == 0:
    info("Open the Nim program to profile")
    return
  discard saveAll()
  let main = if isNimProgram(b): b.path else: nimProjectFile(b)
  let dir = privDir() / ("ned_prof_" & splitFile(main).name)
  createDir(dir)
  let res = dir / "lineprof.txt"
  removeFile(res)
  try: writeFile(dir / "ned_lineprof.nim", NedLineProf)
  except CatchableError as e:
    error("Cannot write the profiler: " & e.msg)
    return
  let cmd = "nim c --hints:off -d:release --profiler:on --stackTrace:on --lineTrace:on --excessiveStackTrace:on " &
            (if cfgNimFlags.len > 0: cfgNimFlags & " " else: "") &
            "--import:" & quoteShell(dir / "ned_lineprof.nim") & " -o:" & quoteShell(dir / "prog" & ExeDot) & " " &
            quoteShell(main) & " && NED_LINEPROF=" & quoteShell(res) & " " & quoteShell(dir / "prog" & ExeDot) & " < /dev/null"
  info("Profiling " & extractFilename(main) & "…")
  discard startJob(jkTool, cmd, parentDir(main), proc(j: Job) =
    if not fileExists(res) or not profLoad(res):
      error("No profile was written — see the Output panel")
      for l in j.output.splitLines: addPanelLine(PanelLine(text: l, line: -1))
      return
    profChecked.clear()
    profPanel()
    for b in bufs:
      if b.id in flameViews: needRender = true          # (an open flame graph shows the new profile)
    info("Profile ready — the procs that took the most time are at the top; each line's share is beside it · " &
         "Nim: flame graph of the profile" & (if profPrevRows.len > 0: " · Nim: compare with the previous profile"
                                              else: "")))
