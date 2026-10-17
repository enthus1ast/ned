# ── names a macro makes, from the compiler: a module's top-level macro calls (makeProcs(Foo, Bar) at the left
#    margin) expanded once by `nim check --expandMacro`, and what the expansion declares added to what the engine
#    knows of the file (nim.macroNames) — completion, hover, Go to definition and signature help then know getFoo.
#    The file as it is (unsaved text too) goes to the compiler as a private copy, deleted after; the project files
#    it imports are expanded the same way. Done again only when those calls change ──

var
  mnRunning = ""                      # the file being expanded now ("": none)
  mnDone: Table[string, string]       # path → the calls last expanded for it (their lines)
  mnSeen: Table[int, int]             # buffer id → the change its calls were last looked at for
  mnQueue: seq[string]                # files waiting their turn (one `nim check` at a time)

proc mnUsable(path: string): bool =
  cfgMacroNames and path.endsWith(".nim") and not nimUsesLsp() and haveExe("nim") and
    nxIncluderOf(path).len == 0 and codeTrusted(parentDir(path))

proc mnLinesOf(path: string): seq[string] =
  let i = bufIndexByPath(path)
  if i >= 0: return bufs[i].lines
  try: readFile(path).splitLines except CatchableError: @[]

proc mnCalls(f: NxFile, lines: openArray[string]): seq[(int, string)] =
  ## the file's top-level macro calls: (line, the macro)
  if f == nil: return
  let sc = nxScope(f)
  var inTriple = false
  var inComment = 0
  for i in 0 ..< lines.len:
    let l = lines[i]
    let before = inTriple or inComment > 0
    discard ecCodeOnly(l, inTriple, inComment)
    if before or l.len == 0 or l[0] notin IdentStartChars: continue
    var off = false
    for (a, b) in f.inactive:
      if i >= a and i <= b: off = true
    if off: continue
    var e = 0
    while e < l.len and l[e] in IdentChars: inc e
    if e < l.len and l[e] notin {'(', ' ', ':'}: continue           # (x.y, x = 1, x[…]: no call of x)
    if e < l.len and l[e] == ' ':
      let rest = l[e .. ^1].strip
      if rest.len == 0 or rest[0] in {'=', '.', ':', '*', '+', '-', '/', '<', '>', '&', '|', '[', '#'}: continue
    let w = l[0 ..< e]
    for r in nxLookup(sc, w):
      if r.file.syms[r.idx].kind == nxMacro:
        result.add (i, w)
        break

proc mnParse(output: string): seq[(int, string)] =
  ## the expansions of the copy's macro calls in nim check's output: (line, the code it expands to)
  var cur = -1
  var acc: seq[string]
  const Mark = "[ExpandMacro]"
  const Head = ") Hint: expanded macro:"
  for raw in stripAnsi(output).splitLines:
    if cur < 0:
      let k = raw.find(Head)
      if k <= 0 or not raw.startsWith("stdinfile.nim("): continue
      let inner = raw["stdinfile.nim(".len ..< k].split(',')
      cur = (try: parseInt(inner[0].strip) - 1 except ValueError: -1)
      if cur < 0: continue
      acc = @[]
      var rest = raw[k + Head.len .. ^1].strip(trailing = false)
      if rest.endsWith(Mark):
        result.add (cur, rest[0 ..< rest.len - Mark.len])
        cur = -1
      elif rest.len > 0: acc.add rest
    elif raw.endsWith(Mark):
      acc.add raw[0 ..< raw.len - Mark.len]
      result.add (cur, acc.join("\n"))
      cur = -1
    else: acc.add raw

proc mnForget(path: string) =
  if path in nxMacroSyms:
    nxMacroSyms.del path
    nxFiles.del path
    nxScopes.clear()
    inc nxGen

proc mnNext()

proc mnExpand(path: string) =
  ## expand the file's top-level macro calls (its text as it is now) and keep what they declare
  let lines = mnLinesOf(path)
  if lines.len == 0 or lines.len > 20_000 or not mnUsable(path): return
  let f = nxLoad(path)
  let calls = mnCalls(f, lines)
  var sig = ""
  for (l, _) in calls: sig.add $l & ":" & lines[l] & "\n"
  if mnDone.getOrDefault(path, "\x00") == sig: return
  mnDone[path] = sig
  if calls.len == 0:
    mnForget(path)
    return
  var names: seq[string]
  for (_, w) in calls:
    if w notin names: names.add w
  let copy = privTmp("macros") & ".nim"
  try: writeFile(copy, lines.join("\n") & "\n")
  except CatchableError: return
  var cmd = "nim check --hint:all:off --hint:ExpandMacro:on --warnings:off --colors:off"
  for w in names: cmd.add " --expandMacro:" & quoteShell(w)
  cmd.add " - < " & quoteShell(copy) & " 2>&1"
  mnRunning = path
  var texts: seq[(int, string, string)]          # (line, macro, the line as it is now)
  for (l, w) in calls: texts.add (l, w, lines[l])
  let job = startJob(jkAux, cmd, parentDir(path), proc(j: Job) =
    mnRunning = ""
    mnSeen.clear()                             # (the buffers looked at again: typed while this ran?)
    try: removeFile(copy)
    except CatchableError: discard
    var made: seq[NxMacroCall]
    for (l, code) in mnParse(j.output):
      for (cl, w, t) in texts:
        if cl != l: continue
        var syms = nxParse(code.splitLines, path).syms
        if syms.len == 0: break
        let callText = t.strip
        for s in syms.mitems:
          if s.doc.len == 0: s.doc = "(made by `" & (if callText.len > 60: callText[0 ..< 60] & "…" else: callText) & "`)"
        made.add NxMacroCall(line: l, text: t, syms: syms)
        break
    # (nothing expanded — the text does not compile now, say: what the calls made before stays)
    if made.len > 0 or j.code == 0:
      nxMacroSyms[path] = made
      if made.len == 0: nxMacroSyms.del path
      nxFiles.del path
      nxScopes.clear()
      inc nxGen
      needRender = true
    mnNext())
  if job != nil: job.deadlineMs = 60_000       # (a macro that never ends: stopped)

proc mnNext() =
  while mnRunning.len == 0 and mnQueue.len > 0:
    let p = mnQueue[0]
    mnQueue.delete(0)
    mnExpand(p)

proc macroNamesFor(b: Buffer) =
  ## the buffer's macro calls (and those of the project files it imports): expanded when they changed
  mnSeen[b.id] = b.changeId
  if b.path.len == 0 or b.lang == nil or b.lang.mode != lmNim or b.largeOn or not mnUsable(b.path): return
  let f = nxFileFor(b)
  if f == nil: return
  var want = @[b.path]
  if rootDir.len > 0:
    for im in f.imports:
      if want.len > 8: break
      let p = nxResolve(b.path, im.spec)
      if p.len > 0 and p.startsWith(rootDir & "/") and p.endsWith(".nim") and p notin want: want.add p
  for i in countdown(want.high, 0):
    let p = want[i]
    let k = mnQueue.find(p)
    if k >= 0: mnQueue.delete(k)
    if p == mnRunning: continue
    mnQueue.insert(p, 0)                       # (this buffer first)
  mnNext()
