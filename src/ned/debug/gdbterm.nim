# ── debugging with gdb in the integrated terminal ──

proc shellTermObj(): Term =
  ## the terminal tab to type shell commands into: the current one, unless it runs a REPL
  let t = curTermObj()
  if t == nil or t.replLang.len == 0: return t
  for i, x in terms:
    if x.replLang.len == 0:
      curTerm = i
      return x
  terms.add newTerm(max(20, lay.edW), max(4, lay.panelH - 1), termCwd())
  curTerm = terms.high
  terms[curTerm]

proc runInTerm(cmd: string) =
  ## type a command into the integrated terminal (waits for the shell prompt)
  setPanel(pkTerminal)
  focus = fPanel
  let t = shellTermObj()
  if t == nil: return
  if t.dead:
    terms[curTerm] = newTerm(t.w, t.h, termCwd())
  let tt = curTermObj()
  if tt.gotOutput: tt.termWrite(cmd & "\r") else: tt.pending = cmd & "\r"

proc cmdDebugGdb() =
  ## palette command: saves everything, then types into the terminal a line that builds the current Nim file with native
  ## debug information and starts gdb on it (with Nim's pretty printers when found), or lldb when there is no gdb
  let b = buf()
  if b.lang.mode != lmNim or b.path.len == 0:
    info("Open a Nim file to debug")
    return
  if not haveExe("gdb") and not haveExe("lldb"):
    error("gdb is not installed (Termux: pkg install gdb)")
    return
  discard saveAll()
  # (gdb with Nim's pretty printers: strings, seqs and tables as their items)
  let py = if haveExe("gdb"): nimGdbScript() else: ""
  let dbg = if haveExe("gdb"): "gdb -q" & (if py.len > 0: " -ex " & quoteShell("source " & py) else: "") else: "lldb"
  let outp = privDir() / ("ned_debug_" & splitFile(b.path).name) & ExeDot
  let cmd = "nim c --debugger:native --opt:none --gcc.options.debug:-g3 --clang.options.debug:-g3 --hints:off " & (if cfgNimFlags.len > 0: cfgNimFlags & " " else: "") &
            "-o:" & quoteShell(outp) & " " & quoteShell(b.path) & " && " & dbg & " " & quoteShell(outp) & "\r"
  setPanel(pkTerminal)
  focus = fPanel
  let t = shellTermObj()
  if t != nil:
    if t.gotOutput: t.termWrite(cmd) else: t.pending = cmd
  info("Building with --debugger:native and starting " & (if haveExe("gdb"): "gdb" else: "lldb") & " in the terminal")

proc restoreBreakpoints() =
  ## the folder's breakpoints (and their conditions), kept with its session
  if not cfgRestoreSession or savedSessions.isNil: return
  let s = savedSessions{rootDir}
  if s == nil: return
  breakpoints.clear()
  bpCond.clear()
  bpLog.clear()
  let bps = s{"breakpoints"}
  if bps != nil and bps.kind == JObject:
    for f, a in bps.pairs:
      var hs: HashSet[int]
      for x in jitems(a):
        if x.kind == JInt: hs.incl x.getInt
      if hs.len > 0: breakpoints[f] = hs
  let conds = s{"bpConditions"}
  if conds != nil and conds.kind == JObject:
    for k, c in conds.pairs: bpCond[k] = c.getStr
  let logs = s{"bpLogs"}
  if logs != nil and logs.kind == JObject:
    for k, c in logs.pairs: bpLog[k] = c.getStr
  dbgWatches.setLen(0)
  for w in jitems(s{"watches"}): dbgWatches.add w.getStr
  dbgWpWanted.setLen(0)
  for w in jitems(s{"watchpoints"}): dbgWpWanted.add w.getStr
  activeRunConfig = s{"runConfig"}.getStr("")
  taskRecent.setLen(0)
  for t in jitems(s{"tasks"}): taskRecent.add t.getStr
  lastTask = s{"lastTask"}.getStr("")

proc restoreSession() =
  ## at start-up and when a folder is opened, brings back the folder's saved session: its breakpoints and watches, then the files that were open
  ## (the ones that still exist) with the same one current, and puts the focus in the editor
  if not cfgRestoreSession or savedSessions.isNil: return
  let s = savedSessions{rootDir}
  if s == nil: return
  let cur = s{"cur"}.getStr
  restoreBreakpoints()
  for f in jitems(s{"files"}):
    if fileExists(f.getStr): discard openFile(f.getStr)
  if cur.len > 0:
    let i = bufIndexByPath(cur)
    if i >= 0: curBuf = i
  focus = fEditor
