# ── Nim: the compiler as an oracle in the background (nim.compilerOracle) ──
#    What ned's engine cannot work out by reading — the type of a let whose value a macro makes, a `when compiles`
#    branch, a generic it does not follow, which of several overloads a call picks — is asked of the compiler: one
#    nimsuggest run for the questions of the lines around the screen, after a pause in the typing (it answers them
#    all, then quits: no server kept running), on a private copy of the unsaved text. The answers are kept on disk,
#    each by the text of its line: a line you do not change keeps its answer across edits elsewhere and the next
#    time the file is opened — in the editor and in the engine worker alike (it reads the same file) ──

var
  orMem: Table[string, (times.Time, Table[string, seq[string]])]  # cache file → (its time on disk, line key → nimsuggest's lines)
  orMemAt: Table[string, MonoTime]        # (when the file's time was looked at: at most every 2 s)
  orRunning = false
  orAsked: Table[string, HashSet[string]] # path → the line keys asked (answered or not: not asked again this session)
  orGen = 0                               # answers came: the hints are worked out again
  orNextAt = MonoTime()                   # (one run at most every 8 s)
  orRuns, orAnswered = 0                  # (Help › Performance: runs, questions answered)

proc orDir(): string = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / AppName / "oracle"
proc orFile(path: string): string = orDir() / ($(hash(path) and 0x7FFFFFFF) & ".json")
var orCtxMemo: Table[string, (MonoTime, string)]

proc orCtx(path: string): string =
  ## what the compiler's answers about a file depend on besides their line: what the file declares, what the
  ## project's modules it sees declare (their faces — the same after edits inside bodies), the defines and the
  ## library. An answer is kept by these too: a return type changed in another file left the old type beside a line
  ## that had not changed (as Nim's own compiler keeps a module's results with the interfaces they came from)
  let now = getMonoTime()
  orCtxMemo.withValue(path, m):
    if (now - m[][0]).inMilliseconds < 1500: return m[][1]
  var h: Hash = hash(nxDefinesKeyOf()) xor hash(nxLibDir)
  let f = nxLoad(path)
  if f != nil:
    h = h xor hash(nxFaceStamp(f))
    let sc = nxScope(f)
    if sc != nil:
      for (p, _) in sc.deps:
        if p == path or (nxLibDir.len > 0 and p.startsWith(nxLibDir & "/")): continue
        let g = nxFiles.getOrDefault(p)
        if g != nil: h = h xor hash(p & "\t" & nxFaceStamp(g, exportedOnly = true))
  result = $(h and 0xFFFFFFF)
  if orCtxMemo.len > 200: orCtxMemo.clear()
  orCtxMemo[path] = (now, result)

proc orKey(path, lineText: string, col: int): string =
  $(hash(lineText) and 0xFFFFFFF) & ":" & $col & ":" & orCtx(path)

proc orTable(path: string): Table[string, seq[string]] =
  ## the answers kept for a file (read again when the file on disk changes: the worker reads what the editor wrote)
  let f = orFile(path)
  let now = getMonoTime()
  if f in orMem and (now - orMemAt.getOrDefault(f)).inMilliseconds < 2000: return orMem[f][1]
  orMemAt[f] = now
  var t: times.Time
  try: t = getLastModificationTime(f)
  except CatchableError:
    orMem.del f
    return
  if f in orMem and orMem[f][0] == t: return orMem[f][1]
  var tab: Table[string, seq[string]]
  try:
    let j = parseFile(f)
    if j{"path"}.getStr == path and j{"answers"} != nil and j{"answers"}.kind == JObject:
      for k, v in j["answers"]:
        var ls: seq[string]
        for x in jitems(v): ls.add x.getStr
        tab[k] = ls
  except CatchableError: discard
  orMem[f] = (t, tab)
  tab

proc orAnswer(path, lineText: string, col: int): seq[string] =
  ## nimsuggest's lines for the name at col on a line with that text ("def\tskLet\ta.x\tint\t…"; none: @[])
  if path.len == 0: return
  orTable(path).getOrDefault(orKey(path, lineText, col))

func orField(l: string, i: int): string =
  let p = l.split('\t')
  if i < p.len: p[i] else: ""

proc orTypeOf(path, lineText: string, col: int): string =
  ## the type of the let, var or const whose name starts at col on that line, as the compiler said ("" none)
  if not cfgOracle: return
  for l in orAnswer(path, lineText, col):
    if orField(l, 1) in ["skLet", "skVar", "skConst", "skForVar", "skResult"]:
      return orField(l, 3).replace("system.", "")
  ""

proc orStore(path: string, answers: seq[(string, seq[string])]) =
  ## the answers kept on disk with those already there (the newest 3000 of a file)
  var tab = orTable(path)
  for (k, ls) in answers: tab[k] = ls
  var keys: seq[string]
  for k in tab.keys: keys.add k
  if keys.len > 3000:
    for k in keys[0 ..< keys.len - 3000]: tab.del k
  var j = newJObject()
  for k, ls in tab:
    var a = newJArray()
    for l in ls: a.add %l
    j[k] = a
  let f = orFile(path)
  try:
    createDir(orDir())
    let tmp = f & ".tmp" & $getCurrentProcessId()
    writeFile(tmp, $(%*{"path": path, "answers": j}))
    moveFile(tmp, f)
  except CatchableError: discard
  orMem.del f
  orMemAt.del f

proc orCompilerLines(b: Buffer, p: Pos): seq[string] =
  ## what the oracle has for the word at p (the compiler's def lines), or @[]
  if not cfgOracle or b.path.len == 0 or p.line >= b.lines.len: return
  let (a, _) = b.wordRangeAt(p)
  orAnswer(b.path, b.lines[a.line], a.col)

proc orKeep(b: Buffer, p: Pos, lines: seq[string]) =
  ## a compiler's answer got another way (one nimsuggest run for a hover): kept with the oracle's
  if not cfgOracle or b.path.len == 0 or p.line >= b.lines.len or lines.len == 0: return
  let (a, _) = b.wordRangeAt(p)
  orStore(b.path, @[(orKey(b.path, b.lines[a.line], a.col), lines)])
