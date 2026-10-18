# ── where ARC/ORC copies: after a save the compiler expands the file's routines (nim c --expandArc) and each
#    =copy / =dup it inserted is marked beside what it copies (nim.showCopies) ──
#    The buffer goes to the compiler as a private copy with {.push exportc.} in front: every routine is then
#    generated (an exported one nothing calls yet would not be), so each shows its copies.

var
  copyRuns: Table[string, MonoTime]       # path → when its expansion started
  copyAgain: HashSet[string]              # saved again while it ran: once more when it ends
  copyMs: Table[string, int]              # path → how long the last one took (ms)

proc copiesUsable(b: Buffer): bool =
  if not cfgShowCopies or b.lang == nil or b.lang.mode != lmNim or b.path.len == 0 or not b.path.endsWith(".nim") or
     b.largeOn or b.lines.len > 30_000 or not nimEngineOn(b) or not haveExe("nim"):
    return false
  if not codeTrusted(parentDir(b.path)):
    askTrust(parentDir(b.path), quiet = true)          # (the compiler runs the folder's config.nims and macros)
    return false
  if copyMs.getOrDefault(b.path, 0) > 30_000: return false   # (a project this slow to compile: not on every save)
  nxIncluderOf(b.path).len == 0                        # (a file another one includes is no module of its own)

proc copyRoutines(b: Buffer): seq[ArcRoutine] =
  let f = nxFileFor(b)
  if f == nil: return
  for s in f.syms:
    if s.kind notin {nxProc, nxFunc, nxMethod, nxConverter} or s.name.len == 0: continue
    var ps: seq[string]
    for p in s.params:
      if not p.typ.strip.startsWith("sink"): ps.add p.name
    result.add ArcRoutine(name: s.name, line: s.line, endLine: max(s.line, s.endLine), params: ps)

func copyWhy(c: ArcCopy): string =
  let src = "`" & c.src & "`"
  let callee = if c.callee.len > 0: "`" & c.callee & "`" else: "this call"
  case c.kind
  of akSink, akAssign:
    if c.loopView:
      return "⧉ **copy** — " & src & " is the loop's view of an element (not a value of its own): " &
        (if c.kind == akSink: callee & " keeps it (a `sink` parameter)"
         else: "keeping it" & (if c.dest.len > 0 and c.dest != "result": " in `" & c.dest & "`" else: "")) &
        ", so it is copied — the element itself stays where it is. If those are not needed afterwards, move them " &
        "out instead (`move(xs[i])` in an index loop over a `var`)"
  else: discard
  case c.kind
  of akSink:
    if c.param:
      "⧉ **copy** — " & src & " is a parameter, only borrowed, and " & callee & " keeps it (a `sink` " &
        "parameter): so it is copied. Take it as `sink` too to hand it on without one"
    else:
      "⧉ **copy** — " & callee & " keeps " & src & " (a `sink` parameter), and it is still used after this: so " &
        "it is copied. If this is its last use, `move(" & c.src & ")` hands it over"
  of akIterArg:
    "⧉ **copy** — the loop goes over a copy of " & src & ": the iterator is inlined and its parameter bound " &
      "to a copy of what may change under it. A local `let` of it first (or a view: `toOpenArray`) avoids it"
  of akLoopVar:
    "⧉ **copy** — each " & src & " is a copy of what the iterator yields (it yields values, not `lent` views). " &
      "If you only read them, an iterator that yields `lent` (items, pairs of a seq) or an index loop avoids it"
  of akCapture:
    "⧉ **copy** — this closure captures " & src & ": a copy of it goes into the closure's environment" &
      (if c.param: " (a parameter is only borrowed, so it cannot be moved there)" else: "") &
      ". Pass it as a parameter instead, or capture what you no longer need elsewhere"
  of akAssign:
    if c.param:
      "⧉ **copy** — " & src & " is a parameter, only borrowed: keeping it" &
        (if c.dest.len > 0 and c.dest != "result": " in `" & c.dest & "`" else: "") & " copies it (=copy). " &
        "As a `sink` parameter it is handed over instead — moved, when the caller no longer needs it"
    else:
      "⧉ **copy** — " & src & (if c.dest.len > 0: " into `" & c.dest & "`" else: "") & " (=copy): it is used " &
        "again after this, or belongs to something that keeps it, so it cannot be moved. If this is its last " &
        "use, `move(" & c.src & ")` moves it"

proc copiesCheck(b: Buffer, everyRoutine = true) =
  ## everyRoutine: with {.push exportc.} in front, so that every routine is generated; some code does not compile
  ## so (an importc proc's effects change) — then once more without, for the routines the module itself uses
  if b == nil: return
  if not copiesUsable(b):
    if not cfgShowCopies and b.id in copyMarks: copyMarks.del b.id
    return
  if b.path in copyRuns:
    copyAgain.incl b.path
    return
  let rs = copyRoutines(b)
  if rs.len == 0:
    if b.id in copyMarks: copyMarks.del b.id
    return
  let snap = b.lines
  let snapId = b.changeId
  let copy = privTmp("copies") & ".nim"
  let cache = privTmp("copiesc")
  try: writeFile(copy, (if everyRoutine: "{.push exportc.}\n" else: "") & snap.join("\n") & "\n")
  except CatchableError: return
  var cmd = "nim c --compileOnly --hints:off --warnings:off --colors:off --nimcache:" & quoteShell(cache)
  var named: HashSet[string]
  for r in rs:
    if r.name notin named and named.len < 400:
      named.incl r.name
      cmd.add " " & quoteShell("--expandArc:" & r.name)
  cmd.add " - < " & quoteShell(copy)
  let path = b.path
  let bid = b.id
  copyRuns[path] = getMonoTime()
  let j0 = startJob(jkCheck, cmd, parentDir(path), proc(j: Job) =
    copyMs[path] = int(msSince(copyRuns.getOrDefault(path, getMonoTime())))
    copyRuns.del path
    try:
      removeFile(copy)
      removeDir(cache)
    except CatchableError: discard
    let x = bufById(bid)
    if x == nil: return
    if path in copyAgain:
      copyAgain.excl path
      copiesCheck(x)
      return
    if j.code != 0:
      if everyRoutine and x.changeId == snapId: copiesCheck(x, everyRoutine = false)
      return                                       # (it does not compile: the marks from before stay where they fit)
    var marks: Table[int, seq[CopyMark]]
    try:
      let got = arcCopies(j.output, snap, rs)
      let f = nxFileFor(x)
      let sc = if f != nil: nxScope(f) else: nil
      for c in got:
        # a ref, a closure, a number: copying it costs next to nothing — not marked
        if f != nil and sc != nil:
          let t = nxTypeOfExpr(f, sc, nxLocals(f, snap, c.line, c.col), c.src, c.line, 0).typ
          let (shape, _) = nxPostfixShape(sc, t)
          if shape in ["ref", "int", "float", "bool", "char", "enum"]: continue
        marks.mgetOrPut(c.line, @[]).add CopyMark(col: c.ecol, startCol: c.col, text: snap[c.line], what: copyWhy(c))
    except Exception as e:
      internalError("ARC/ORC copies", e)
      return
    if marks.len > 0: copyMarks[bid] = marks
    elif bid in copyMarks: copyMarks.del bid
    needRender = true)
  if j0 == nil:
    copyRuns.del path
    try: removeFile(copy)
    except CatchableError: discard
