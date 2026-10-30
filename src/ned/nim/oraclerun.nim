# ── Nim: the oracle's questions and its runs (nim/oracle has what it keeps) ──

var orNotAsked: HashSet[string]          # (calls the engine decides itself, by their line's text: not looked at again)

proc orUsable(b: Buffer): bool =
  ## may the compiler be asked about this buffer in the background?
  cfgOracle and b.lang != nil and b.lang.mode == lmNim and b.path.len > 0 and b.path.endsWith(".nim") and
    not b.largeOn and b.lines.len < 20000 and not cfgNimSuggest and not nimUsesLsp() and cfgNimIde != "off" and
    not nim3On() and haveExe("nimsuggest") and codeTrusted(parentDir(b.path))

proc orQuestions(b: Buffer, f: NxFile): seq[(int, int)] =
  ## what to ask about the lines around the screen: the lets and vars written without a type that have no type
  ## hint (the engine found none), and the calls of a name with several overloads the engine cannot tell apart
  let lo = max(0, b.topLine - 10)
  let hi = min(b.lines.high, b.topLine + textH + 20)
  let asked = orAsked.getOrDefault(b.path)
  let tab = orTable(b.path)
  var seen: HashSet[(int, int)]
  template want(l, c: int) =
    ## adds the name at that place to the questions, unless it is not worth asking: outside the buffer, already listed,
    ## asked this session or already answered
    if l >= 0 and l < b.lines.len and (l, c) notin seen:
      let k = orKey(b.path, b.lines[l], c)
      if k notin asked and k notin tab:
        seen.incl (l, c)
        result.add (l, c)
  proc noHint(s: NxSym): bool =
    ## whether the declaration has no type hint (inlay) after its name yet
    var c = s.col + s.name.len
    if c < b.lines[s.line].len and b.lines[s.line][c] == '*': inc c
    for (c0, lab) in b.inlays.getOrDefault(s.line):
      if c0 == c and lab.startsWith(":"): return false
    true
  let sc = nxScope(f)
  if sc == nil: return
  # the lets and vars (inlays known for this text: the engine has had its go)
  if cfgInlayHints and b.inlayAt == b.changeId:
    for s in f.syms:
      if s.kind in {nxLet, nxVar, nxConst} and s.typ.len == 0 and s.value.len > 0 and s.line >= lo and s.line <= hi and
         s.line < b.lines.len and b.lines[s.line].find(s.name, s.col) == s.col and s.noHint: want(s.line, s.col)
    var done: HashSet[int]
    for l in lo .. hi:
      let ri = nxEnclosing(f, l)
      if ri < 0 or ri in done: continue
      done.incl ri
      for s in nxLocals(f, b.lines, min(hi, f.syms[ri].endLine), high(int) div 2, everything = true):
        if s.kind notin {nxLet, nxVar, nxForVar} or s.typ.len > 0 or s.value.len == 0 or s.line < lo or s.line > hi or
           s.line >= b.lines.len or b.lines[s.line].find(s.name, s.col) != s.col: continue
        if s.noHint: want(s.line, s.col)
      if result.len >= 80: return
  # calls of overloaded names the engine leaves undecided (a few ms at most: the rest the next time)
  let t0 = getMonoTime()
  var st: NxLexState
  for l in 0 .. hi:
    if l >= lo and msSince(t0) > 6: break
    let t = b.lines[l]
    let ids = nxIdents(t, st)
    if l < lo: continue
    for (a, e) in ids:
      if e >= t.len or t[e] != '(' or result.len >= 120: continue
      let k = orKey(b.path, t, a)
      if k in asked or k in tab or k in orNotAsked: continue    # (asked before, answered, or nothing to ask)
      let (refs, locals, _) = try: nxTargets(f, b.lines, l, a) except CatchableError: (@[], @[], "")
      if locals.len > 0 or refs.len < 2:
        if orNotAsked.len > 20000: orNotAsked.clear()
        orNotAsked.incl k
        continue
      var routines = true
      for r in refs:
        if r.sym.kind notin NxRoutineKinds: routines = false
      if routines: want(l, a)

proc oracleStep(b: Buffer) =
  ## after a pause: one nimsuggest run for the questions of the lines around the screen (nothing when they are
  ## answered already, or were asked)
  if orRunning or getMonoTime() < orNextAt or not orUsable(b) or msSince(lastInputAt) < 2500: return
  let f = try: nxFileFor(b) except CatchableError: nil
  if f == nil: return
  let qs = try: orQuestions(b, f) except CatchableError: @[]
  orNextAt = getMonoTime() + initDuration(milliseconds = 8000)
  if qs.len == 0: return
  var dirty = ""
  if b.dirty:
    dirty = privTmp("oracle") & "_" & extractFilename(b.path)
    try: writeFile(dirty, b.allText & "\n")
    except CatchableError: return
  let qfile = privTmp("oracle-q")
  var keys: seq[string]
  var text = ""
  for (l, c) in qs:
    text.add "def " & b.path & (if dirty.len > 0: ";" & dirty else: "") & ":" & $(l + 1) & ":" & $c & "\n"
    keys.add orKey(b.path, b.lines[l], c)
  text.add "quit\n"
  try: writeFile(qfile, text)
  except CatchableError: return
  if orAsked.len > 200: orAsked.clear()              # (files of a long session: asked again if need be)
  let asked = addr orAsked.mgetOrPut(b.path, initHashSet[string]())
  for k in keys: asked[].incl k
  let proj = nimProjectFile(b)
  let path = b.path
  orRunning = true
  inc orRuns
  discard startJob(jkAux, "nimsuggest --stdin --v3 --maxresults:5 " & quoteShell(proj) & " < " & quoteShell(qfile) &
                   " 2>/dev/null", parentDir(proj), proc(j: Job) =
    orRunning = false
    for x in [dirty, qfile]:
      if x.len > 0:
        try: removeFile(x)
        except CatchableError: discard
    # each question's answer: its def lines, then an empty line (after nimsuggest's lines of usage)
    var ls = j.output.splitLines
    var from0 = 0
    for i, l in ls:
      if "terse mode" in l:
        from0 = i + 1
        break
    var blocks: seq[seq[string]]
    var cur: seq[string]
    for i in from0 ..< ls.len:
      let l = ls[i].strip(trailing = false).strip(chars = {'>', ' '}, trailing = false)
      if l.startsWith("def\t"): cur.add l
      elif l.strip.len == 0:
        blocks.add cur
        cur.setLen(0)
    var got: seq[(string, seq[string])]
    for i, k in keys:
      if i < blocks.len and blocks[i].len > 0: got.add (k, blocks[i])
    if got.len > 0:
      orStore(path, got)
      orAnswered += got.len
      inc orGen
      for x in bufs:
        if x.path == path: x.inlayAt = -1
      needRender = true)

