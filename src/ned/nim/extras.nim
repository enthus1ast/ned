# ── Nim: what a proc can raise · benchmark a call · nimble release ──

proc enclosingProc(b: Buffer, line: int): (int, int) =
  ## the proc/func/method/iterator around `line`: (its first line, its last line), (-1, -1) when none
  var l = min(line, b.lines.high)
  while l >= 0:
    let s = b.lines[l].strip
    if s.startsWith("proc ") or s.startsWith("func ") or s.startsWith("method ") or s.startsWith("iterator ") or
       s.startsWith("converter "):
      let ind = leadingWs(b.lines[l]).len
      var e = l
      var k = l + 1
      while k < b.lines.len:
        let t = b.lines[k]
        if t.strip.len == 0:
          inc k
          continue
        if leadingWs(t).len <= ind: break
        e = k
        inc k
      if e > l or line == l: return (l, e)
    dec l
  (-1, -1)

proc nimEffects() =
  ## the exceptions and effects the compiler infers for the proc at the cursor ({.effects.})
  let b = buf()
  if b.lang.mode != lmNim or b.path.len == 0 or not haveExe("nim"):
    info("Put the cursor in a Nim proc (in a saved file)")
    return
  let (a, e) = b.enclosingProc(b.primary.head.line)
  if a < 0 or e <= a:
    info("Put the cursor inside a proc with a body")
    return
  var bodyInd = ""
  for k in a + 1 .. e:
    if b.lines[k].strip.len > 0:
      bodyInd = leadingWs(b.lines[k])
      break
  let name = b.lines[a].strip.split({' ', '(', '*', '[', '='})[1]
  var ls = b.lines
  ls.insert(bodyInd & "{.effects.}", e + 1)
  # a private copy, checked on stdin from the file's folder (so its imports and nim.cfg work)
  let tmp = privTmp("effects") & ".nim"
  try: writeFile(tmp, ls.join("\n") & "\n")
  except CatchableError as ex:
    error("Cannot write the copy to check: " & ex.msg)
    return
  info("Asking the compiler what " & name & " can raise…")
  discard startJob(jkTool, "nim check --hint:all:off --hint:User:on --warnings:off --colors:off - < " & quoteShell(tmp) &
                   " 2>&1", parentDir(b.path), proc(j: Job) =
    try: removeFile(tmp)
    except CatchableError: discard
    var raises, effects: seq[string]
    var failed = ""
    let tn = "stdinfile.nim"
    for l in j.output.splitLines:
      if tn notin l: continue
      if "Error:" in l:
        if failed.len == 0: failed = l[l.find("Error:") .. ^1]
        continue
      if "[User]" notin l or "Hint: " notin l: continue
      var what = l[l.find("Hint: ") + 6 ..< l.rfind("[User]")].strip
      if what.startsWith("ref "): what = what[4 .. ^1]
      let lp = l.find('(')
      let at = if lp >= 0: l[lp + 1 ..< l.find(',', lp)] else: "?"
      let item = what & " (line " & at & ")"
      if what.endsWith("Effect"):
        if item notin effects: effects.add item
      elif item notin raises: raises.add item
    if failed.len > 0 and raises.len == 0 and effects.len == 0:
      error("The compiler stopped before " & name & ": " & failed)
      return
    var names: seq[string]
    for r in raises:
      let n = r.split(' ')[0]
      if n notin names: names.add n
    let body = (if raises.len == 0: name & " raises nothing — {.raises: [].} would hold."
                else: name & " can raise:\n  " & raises.join("\n  ")) &
               (if effects.len > 0: "\n\nEffects: " & effects.join(", ") else: "\n\nNo tagged effects (IO, time …).")
    let pragma = "{.raises: [" & names.join(", ") & "].}"
    openDialog("What " & name & " can raise", body, @[("Copy " & pragma, 'c'), ("OK", 'y')], proc(c: char) =
      if c == 'c':
        clipSet(pragma)
        info("Copied " & pragma)))

proc nimBenchmark() =
  ## times a call, in a harness next to the file (its imports and config work), built in release mode
  let b = buf()
  if b.lang.mode != lmNim or b.path.len == 0 or not haveExe("nim"):
    info("Open a saved Nim file")
    return
  var guess = ""
  let (a, _) = b.enclosingProc(b.primary.head.line)
  if a >= 0:
    let w = b.lines[a].strip.split({' ', '(', '*', '[', '='})
    if w.len > 1: guess = w[1] & (if "()" in b.lines[a] or "(" notin b.lines[a]: "()" else: "(")
  let (sa, se) = b.primary.range
  if sa != se and sa.line == se.line: guess = b.getText(sa, se)
  askText("Benchmark this call (any expression)", guess, proc(call: string) =
    var src: seq[string]
    for l in b.lines:
      src.add (if l.strip.startsWith("when isMainModule"): l.replace("when isMainModule", "when false") else: l)
    src.add ""
    src.add "import std/[monotimes, times, algorithm]"
    src.add "var nedSinkP {.volatile.}: pointer          # keeps the optimiser from dropping an unused result"
    src.add "proc nedBenchRun() ="
    src.add "  template nedCall() ="
    src.add "    when typeof((" & call & ")) is void: " & call
    src.add "    else:"
    src.add "      var nedR = (" & call & ")"
    src.add "      nedSinkP = addr nedR"
    src.add "  var n = 1"
    src.add "  while true:"
    src.add "    let t0 = getMonoTime()"
    src.add "    for i in 0 ..< n: nedCall()"
    src.add "    if (getMonoTime() - t0).inMicroseconds > 200_000 or n >= (1 shl 30): break"
    src.add "    n *= 2"
    src.add "  var s: seq[float]"
    src.add "  for r in 0 ..< 7:"
    src.add "    let t0 = getMonoTime()"
    src.add "    for i in 0 ..< n: nedCall()"
    src.add "    s.add (getMonoTime() - t0).inNanoseconds.float / n.float"
    src.add "  s.sort()"
    src.add "  echo \"NEDBENCH \", n, \" \", s[0], \" \", s[3], \" \", s[^1]"
    src.add "nedBenchRun()"
    # (a private copy, built on stdin from the file's folder: its imports work there)
    let tmp = privTmp("bench") & ".nim"
    let exe = privDir() / ("ned_bench_" & $getCurrentProcessId()) & ExeDot
    try: writeFile(tmp, src.join("\n") & "\n")
    except CatchableError as ex:
      error("Cannot write the benchmark: " & ex.msg)
      return
    info("Benchmarking " & call & " (release build)…")
    discard startJob(jkTool, "nim c -r -d:release --hints:off --warnings:off --colors:off --nimcache:" &
                     quoteShell(privDir() / "bench_cache") & " -o:" & quoteShell(exe) & " - < " &
                     quoteShell(tmp) & " 2>&1", parentDir(b.path), proc(j: Job) =
      try:
        removeFile(tmp)
        if fileExists(exe): removeFile(exe)
      except CatchableError: discard
      proc fmtNs(x: float): string =
        ## a time in nanoseconds written with the unit that fits: ns, µs, ms or s
        if x < 1000: formatFloat(x, ffDecimal, 1) & " ns"
        elif x < 1e6: formatFloat(x / 1e3, ffDecimal, 2) & " µs"
        elif x < 1e9: formatFloat(x / 1e6, ffDecimal, 2) & " ms"
        else: formatFloat(x / 1e9, ffDecimal, 2) & " s"
      for l in j.output.splitLines:
        if l.startsWith("NEDBENCH "):
          let f = l.splitWhitespace()
          if f.len >= 5:
            try:
              let body = call & "\n\nper call:  " & fmtNs(parseFloat(f[3])) & " (median)\n" &
                         "fastest:   " & fmtNs(parseFloat(f[2])) & "\nslowest:   " & fmtNs(parseFloat(f[4])) &
                         "\n\n7 rounds of " & f[1] & " calls, -d:release"
              openDialog("Benchmark", body, @[("OK", 'y')], nil)
            except ValueError: discard
            return
      let lines = j.output.strip.splitLines
      var msg = ""
      for l in lines:
        if "Error:" in l:
          msg = l[l.find("Error:") .. ^1]
          break
      error("The benchmark did not build" & (if msg.len > 0: ": " & msg else: "") & " — is the call right? (the proc must be visible at the end of the file)")))
