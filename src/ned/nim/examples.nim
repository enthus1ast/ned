# ── Nim: run runnableExamples — the ▶ beside them runs one block, "run all examples" every block in the file ──

proc exampleBlocks(b: Buffer): seq[(int, int)] =
  ## every runnableExamples block: (its first line, its last line)
  for l, s in b.lines:
    if examplesHead(s):
      let ind = leadingWs(s).len
      var e = l
      var k = l + 1
      while k < b.lines.len:
        let u = b.lines[k]
        if u.strip.len == 0:
          inc k
          continue
        if leadingWs(u).len <= ind: break
        e = k
        inc k
      if e > l: result.add (l, e)

proc runExamples(b: Buffer, line: int) =
  ## the examples, in a module next to the file that imports it (as nim doc runs them); failures map back to
  ## the lines of the examples
  if b.lang.mode != lmNim or not haveExe("nim"):
    info("Open a Nim file (and install Nim)")
    return
  if not codeTrusted(parentDir(b.path)):
    askTrust(parentDir(b.path))
    return
  if not saveForTool(b): return
  var blocks: seq[(int, int)]
  for (a, e) in b.exampleBlocks():
    if line < 0 or a == line: blocks.add (a, e)
  if blocks.len == 0:
    info("No runnableExamples " & (if line < 0: "in this file" else: "on this line"))
    return
  let wrap = blocks.len > 1                     # several blocks: each in its own block: so names do not clash
  var outp: seq[(string, int, int)]             # (text, source line, column shift)
  var imports: seq[(string, int, int)]
  var flags: seq[string]
  var compileOnly = false
  let modName = splitFile(b.path).name
  for (a, e) in blocks:
    let head = b.lines[a].strip
    let q1 = head.find('"')
    let q2 = head.rfind('"')
    if q1 >= 0 and q2 > q1:                     # runnableExamples("-d:ssl"), ("-r:off")
      for f in head[q1 + 1 ..< q2].splitWhitespace:
        if f in ["-r:off", "--run:off"]: (if not wrap: compileOnly = true)
        elif f notin flags: flags.add f
    var ind0 = high(int)
    for k in a + 1 .. e:
      if b.lines[k].strip.len > 0: ind0 = min(ind0, leadingWs(b.lines[k]).len)
    if wrap: outp.add ("block:", a, 0)
    let pad = if wrap: "  " else: ""
    for k in a + 1 .. e:
      let raw = b.lines[k]
      let t = raw.strip
      let txt = if raw.len >= ind0: raw[ind0 .. ^1] else: t
      if wrap and leadingWs(raw).len == ind0 and (t.startsWith("import ") or t.startsWith("from ")):
        imports.add (txt, k, ind0)
      else: outp.add (pad & txt, k, ind0 - pad.len)
  var lines = @[("import \"./" & modName & "\"", blocks[0][0], 0)] & imports & outp
  # a private copy, compiled on stdin from the file's folder (its imports, nim.cfg and ./module work there):
  # the compiler calls it stdinfile.nim
  let priv = privTmp("examples") & ".nim"
  let tmp = "stdinfile.nim"
  var text = ""
  for (t, _, _) in lines: text.add t & "\n"
  try: writeFile(priv, text)
  except CatchableError as ex:
    error("Cannot write the examples: " & ex.msg)
    return
  let exe = privDir() / ("ned_examples_" & $getCurrentProcessId())
  var keys: seq[string]
  for (a, _) in blocks: keys.add b.path & ":" & $a
  for k in keys: exampleStatus[k] = 3                       # running
  let what = if line < 0: $blocks.len & " example block(s) of " & extractFilename(b.path)
             else: "the examples on line " & $(line + 1)
  info("Running " & what & "…")
  let path = b.path
  var flagStr = ""
  for f in flags: flagStr.add quoteShell(f) & " "
  let cmd = "nim c" & (if compileOnly: "" else: " -r") & " --hints:off --warnings:off --colors:off " &
            flagStr & "--nimcache:" & quoteShell(privDir() / "examples_cache") & " -o:" & quoteShell(exe) & " - < " &
            quoteShell(priv) & " 2>&1"
  discard startJob(jkTool, cmd, parentDir(b.path), proc(j: Job) =
    try:
      removeFile(priv)
      if fileExists(exe): removeFile(exe)
    except CatchableError: discard
    # tmp(LINE, COL) → the file's own line and column
    proc mapLine(s: string): string =
      result = s
      var at = result.find(tmp)
      while at >= 0:
        let p = at + tmp.len
        var e = p
        var ln, col = -1
        if p < result.len and result[p] == '(':
          let close = result.find(')', p)
          if close > p:
            let nums = result[p + 1 ..< close].split(',')
            try:
              ln = parseInt(nums[0].strip)
              if nums.len > 1: col = parseInt(nums[1].strip)
              e = close + 1
            except ValueError: discard
        var rep = path
        if ln >= 1 and ln - 1 < lines.len:
          let (_, sl, shift) = lines[ln - 1]
          rep.add "(" & $(sl + 1) & (if col >= 0: ", " & $(col + shift) else: "") & ")"
        elif ln >= 1: rep.add "(" & $(blocks[0][0] + 1) & ")"
        result = result[0 ..< at] & rep & result[e .. ^1]
        at = result.find(tmp, at + rep.len)
    var ds = diagsBuild.getOrDefault(path)
    var keep: seq[Diag]
    for d in ds:
      if d.src != "examples": keep.add d
    ds = keep
    let ok = j.code == 0
    for k in keys: exampleStatus[k] = (if ok: 1 else: 2)
    if ok:
      if path in diagsBuild: diagsBuild[path] = ds
      # what they printed (with what the module itself prints when it is imported), in a popup
      var shown: seq[string]
      for raw in j.output.splitLines:
        let x = stripAnsi(raw)
        if x.strip.len == 0 and shown.len == 0: continue
        shown.add x
      while shown.len > 0 and shown[^1].strip.len == 0: shown.setLen(shown.len - 1)
      if compileOnly or shown.len == 0:
        info("✓ " & what & (if compileOnly: " compile" else: " pass (they print nothing)"))
      else:
        let more = shown.len - 40
        if shown.len > 40: shown.setLen(40)
        showHover("**✓ " & what & " pass** — their output:\n```text\n" & shown.join("\n") &
                  (if more > 0: "\n… " & $more & " more lines" else: "") & "\n```")
        info("✓ " & what & " pass")
      needRender = true
      return
    panelKind = pkOutput
    panelLines = @[PanelLine(text: "▶ runnableExamples — " & what, sev: 5, line: -1)]
    panelTitle = "OUTPUT"
    panelOpen = true
    panelFollow = true
    panelSel = 0
    for raw in j.output.splitLines:
      if raw.len == 0: continue
      let s = mapLine(stripAnsi(raw))
      var pl = PanelLine(text: s, line: -1)
      let (pok, pp, l, c, sev, m) = parseErrLine(s, parentDir(path))
      if pok:
        pl.path = pp
        pl.line = l
        pl.col = c
        pl.sev = sev
        if pp == path and sev == 1: ds.add Diag(line: l, col: c, eline: l, ecol: -1, sev: 1, msg: m, src: "examples")
      elif "[AssertionDefect]" in s or "unhandled exception:" in s:
        # Error: unhandled exception: file(12, 5) `expr`  [AssertionDefect]
        let p0 = s.find(path & "(")
        if p0 >= 0:
          let cl = s.find(')', p0)
          let nums = s[p0 + path.len + 1 ..< max(p0 + path.len + 1, cl)].split(',')
          try:
            let l2 = parseInt(nums[0].strip) - 1
            let c2 = if nums.len > 1: parseInt(nums[1].strip) else: 0
            let bt1 = s.find('`')
            let bt2 = s.rfind('`')
            let expr = if bt2 > bt1 and bt1 >= 0: s[bt1 .. bt2] else: s[s.find("unhandled exception:") + 20 .. ^1].strip
            pl.path = path
            pl.line = l2
            pl.col = c2
            pl.sev = 1
            ds.add Diag(line: l2, col: c2, eline: l2, ecol: -1, sev: 1, msg: "example failed: " & expr, src: "examples")
          except ValueError: discard
      addPanelLine(pl)
    addPanelLine(PanelLine(text: "✗ " & what & (if compileOnly: " do not compile" else: " failed"), sev: 1, line: -1))
    diagsBuild[path] = ds
    # which block failed: ✗ on it, ✓ on the ones that ran before it, nothing on the ones that did not run
    var bad: seq[int]
    for d in ds:
      if d.src == "examples": bad.add d.line
    if bad.len > 0:
      let first = min(bad)
      for i, (a, e) in blocks:
        var hit = false
        for l in bad:
          if l in a .. e: hit = true
        exampleStatus[keys[i]] = (if hit: 2 elif e < first and not compileOnly and bad.len == 1: 1 else: 0)
    needRender = true)

proc nimbleRelease() =
  ## set the version in the .nimble file, commit, tag v<version> and push
  loadNimbleInfo(true)
  if nimble.file.len == 0:
    info("No .nimble file in this project")
    return
  let root = findGitRoot(parentDir(nimble.file))
  if root.len == 0:
    info("The project is not in a git repository")
    return
  var parts = nimble.version.split('.')
  var guess = nimble.version
  if parts.len > 0:
    try:
      parts[^1] = $(parseInt(parts[^1]) + 1)
      guess = parts.join(".")
    except ValueError: discard
  let nf = nimble.file
  askText("New version (now " & nimble.version & ")", guess, proc(v: string) =
    let ver = v.strip.strip(chars = {'v', 'V'})
    if ver.len == 0 or not ver[0].isDigit:
      error("A version looks like 1.2.3")
      return
    askConfirm("Release " & ver & ": set it in " & extractFilename(nf) & ", commit, tag v" & ver & " and push? (y/n)",
      proc(c: char) =
        if c notin {'y', 'Y'}: return
        try:
          var ls = readFile(nf).splitLines
          var done = false
          for i, l in ls:
            let s = l.strip
            if not done and s.startsWith("version") and '=' in s:
              let q1 = l.find('"')
              let q2 = if q1 >= 0: l.find('"', q1 + 1) else: -1
              if q1 >= 0 and q2 > q1:
                ls[i] = l[0 .. q1] & ver & l[q2 .. ^1]
                done = true
          if not done:
            error("No version = \"…\" line in " & extractFilename(nf))
            return
          writeFileSafe(nf, ls.join("\n"))
          let bi = bufIndexByPath(nf)
          if bi >= 0: reloadBuffer(bufs[bi])
        except CatchableError as e:
          error("Cannot update " & extractFilename(nf) & ": " & e.msg)
          return
        let rel = relativePath(nf, root)
        gitShell("git add " & quoteShell(rel) & " && git commit -m " & quoteShell("Release v" & ver) &
                 " && git tag -a " & quoteShell("v" & ver) & " -m " & quoteShell("v" & ver),
                 "Committed and tagged v" & ver, proc() = gitNet("push --follow-tags", "Pushed v" & ver), root)))
