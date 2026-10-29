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

func mnHasWord(text, w: string): bool =
  ## is `w` written in `text` as a word of its own?
  var k = text.find(w)
  while k >= 0:
    let e = k + w.len
    if (k == 0 or text[k - 1] notin IdentChars) and (e >= text.len or text[e] notin IdentChars): return true
    k = text.find(w, k + 1)

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
      let rest = raw[k + Head.len .. ^1].strip(trailing = false)
      if rest.endsWith(Mark):
        result.add (cur, rest[0 ..< rest.len - Mark.len])
        cur = -1
      elif rest.len > 0: acc.add rest
    elif raw.endsWith(Mark):
      acc.add raw[0 ..< raw.len - Mark.len]
      result.add (cur, acc.join("\n"))
      cur = -1
    else: acc.add raw

func mnSame(a, b: seq[NxMacroCall]): bool =
  ## the same calls making the same names (the lines they are on aside)
  if a.len != b.len: return false
  for i in 0 ..< a.len:
    if a[i].text != b[i].text or a[i].syms.len != b[i].syms.len: return false
    for k in 0 ..< a[i].syms.len:
      var x = a[i].syms[k]
      var y = b[i].syms[k]
      x.line = 0; x.col = 0; x.endLine = 0
      y.line = 0; y.col = 0; y.endLine = 0
      if x != y: return false
  true

proc mnForget(path: string) =
  ## the file has no top-level macro calls (any more): nothing they make, and that is known
  let was = nxMacroDone.getOrDefault(path, "\x00")
  nxMacroDone[path] = ""
  if path in nxMacroSyms:
    nxMacroSyms.del path
    nxFiles.del path
    nxForgetScopesOf(path)
    inc nxGen
  if was != "":
    typoAt.clear()
    wkMacros(path)

# ── what the calls made, kept on disk with what it came from (the file's text, the files it sees, where the
#    macros are, the defines and the compiler): the next time the file is opened as it was, the names are known at
#    once — no compiler run, and nothing marked missing meanwhile — as Nim's own compiler keeps a module's results
#    with what they depend on ──

proc mnDiskFile(path: string): string =
  getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / AppName / "macros" / (toHex(cast[uint64](hash(path))) & ".json")

proc mnNimStamp(): string =
  let exe = findExe("nim")
  if exe.len == 0: "" else: exe & "|" & nxStamp(exe)

func mnTextKey(lines: openArray[string]): string =
  let text = lines.join("\n") & "\n"
  $text.len & ":" & $hash(text)

proc mnDepsOf(f: NxFile, macroFiles: seq[string]): (bool, seq[(string, string)]) =
  ## the files an expansion may have read besides the file itself — the project's and the packages' modules it
  ## sees, those of the macros — with their stamps on disk; false when one of them has unsaved changes (what the
  ## compiler read is not on disk then)
  var ps = macroFiles
  let sc = nxScope(f)
  if sc != nil:
    for (p, _) in sc.deps:
      if p notin ps: ps.add p
  result[0] = true
  for p in ps:
    if p == f.path or p.len == 0 or (nxLibDir.len > 0 and p.startsWith(nxLibDir & "/")): continue
    let i = bufIndexByPath(p)
    if i >= 0 and bufs[i].dirty: return (false, @[])
    result[1].add (p, nxStamp(p))

proc mnStore(path, textKey, sig: string, deps: seq[(string, string)]) =
  var d = newJArray()
  for (p, st) in deps: d.add %*[p, st]
  let j = %*{"path": path, "text": textKey, "defs": nxDefinesKeyOf(), "nim": mnNimStamp(), "deps": d, "sig": sig,
             "b": encode(nxMacroCallsBytes(nxMacroSyms.getOrDefault(path)))}
  let f = mnDiskFile(path)
  try:
    createDir(parentDir(f))
    let tmp = f & ".tmp" & $getCurrentProcessId()
    writeFile(tmp, $j)
    moveFile(tmp, f)
  except CatchableError: discard

var mnDiskTried: HashSet[string]       # (files looked for on the disk this session: once each)

proc mnLoad(path: string, lines: seq[string]): bool =
  ## what the calls made, from the disk, when it was made from this very text and nothing it came from changed
  if path in nxMacroDone or path in mnDiskTried or lines.len == 0 or not nxDefinesComplete: return false
  mnDiskTried.incl path                  # (once the defines are the project's: they are part of what it came from)
  let f = mnDiskFile(path)
  if not fileExists(f): return false
  try:
    let j = parseFile(f)
    if j{"path"}.getStr != path or j{"text"}.getStr != mnTextKey(lines) or j{"defs"}.getStr != nxDefinesKeyOf() or
       j{"nim"}.getStr != mnNimStamp() or j{"deps"} == nil or j{"deps"}.kind != JArray:
      return false
    for d in j["deps"]:
      if d.kind != JArray or d.len != 2: return false
      let p = d[0].getStr
      let i = bufIndexByPath(p)
      if nxStamp(p) != d[1].getStr or (i >= 0 and bufs[i].dirty): return false
    let bytes = decode(j{"b"}.getStr)
    let calls = nxMacroCallsFrom(bytes)
    if nxMacroCallsBytes(calls) != bytes: return false          # (kept by another version of ned)
    let sig = j{"sig"}.getStr
    if calls.len > 0: nxMacroSyms[path] = calls
    else: nxMacroSyms.del path
    nxMacroDone[path] = sig
    mnDone[path] = sig
    nxFiles.del path
    nxForgetScopesOf(path)
    inc nxGen
    typoAt.clear()
    wkMacros(path)
    needRender = true
    true
  except CatchableError, Defect: false

var mnSigMemo: Table[string, (string, string)]   # project module → (its stamp, its top-level macro calls' lines)

proc mnCallsSig(f: NxFile, lines: openArray[string]): string =
  for (l, _) in mnCalls(f, lines): result.add lines[l] & "\n"

proc mnNamesKnown(f: NxFile, lines: seq[string], sc: NxScope): bool =
  ## are the names that the top-level macro calls of this file, and of the project's modules it imports, make known
  ## — for the calls as they are now? (Until they are, a member the engine cannot find may be one of them)
  if f == nil or sc == nil: return false
  let own = mnCallsSig(f, lines)
  if own.len > 0 and nxMacroDone.getOrDefault(f.path, "\x00") != own: return false
  for _, p in sc.modules:
    if p.len == 0 or p == f.path or not p.endsWith(".nim") or nxIsPkgPath(p) or
       (nxLibDir.len > 0 and p.startsWith(nxLibDir & "/")):
      continue
    let st = nxCurStamp(p)
    var sig = ""
    if p in mnSigMemo and mnSigMemo[p][0] == st: sig = mnSigMemo[p][1]
    else:
      let g = nxLoad(p)
      if g != nil: sig = mnCallsSig(g, mnLinesOf(p))
      if mnSigMemo.len > 2000: mnSigMemo.clear()
      mnSigMemo[p] = (st, sig)
    if sig.len > 0 and nxMacroDone.getOrDefault(p, "\x00") != sig: return false
  true

proc mnNext()

proc mnExpand(path: string) =
  ## expand the file's top-level macro calls (its text as it is now) and keep what they declare
  let lines = mnLinesOf(path)
  if lines.len == 0 or lines.len > 20_000 or not mnUsable(path): return
  let f = nxLoad(path)
  let calls = mnCalls(f, lines)
  var sig = ""
  for (l, _) in calls: sig.add lines[l] & "\n"     # (the calls as written: a line typed above them moves them, and
                                                  # what they make is found at the call wherever it is now)
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
  var bodies: Table[string, string]              # macro → its source (what it writes with a `*`)
  var macroFiles: seq[string]                    # (where the macros are: what the names made depend on)
  let sc = nxScope(f)
  for w in names:
    for r in nxLookup(sc, w):
      let sy = r.file.syms[r.idx]
      if sy.kind != nxMacro: continue
      if r.file.path notin macroFiles: macroFiles.add r.file.path
      let src = mnLinesOf(r.file.path)
      var t = ""
      for k in sy.line .. min(sy.endLine, src.high): t.add src[k] & "\n"
      bodies[w] = bodies.getOrDefault(w) & t
  let (depsOk, deps) = mnDepsOf(f, macroFiles)
  let textKey = mnTextKey(lines)
  let job = startJob(jkAux, cmd, parentDir(path), proc(j: Job) =
    mnRunning = ""
    mnSeen.clear()                             # (the buffers looked at again: typed while this ran?)
    try: removeFile(copy)
    except CatchableError: discard
    var made: seq[NxMacroCall]
    for (l, code) in mnParse(j.output):
      for (cl, w, t) in texts:
        if cl != l: continue
        let body = bodies.getOrDefault(w)
        var syms: seq[NxSym]
        for s0 in nxParse(code.splitLines, path).syms:
          var s = s0
          if (s.name & "`gensym") in code: continue        # (a name the macro hides: not reachable)
          # (the expansion as the compiler prints it drops a routine's `*`: public when the macro writes the name
          # with one, or makes names (`nm`*) and does not write this one plainly)
          if not s.exported and s.kind notin {nxField, nxEnumVal}:
            s.exported = (s.name & "*") in body or ("`" & s.name & "`*") in body or
                         (not mnHasWord(body, s.name) and ("`*" in body or "postfix(" in body))
          syms.add s
        if syms.len == 0: break
        let callText = t.strip
        for s in syms.mitems:
          if s.doc.len == 0: s.doc = "(made by `" & (if callText.len > 60: callText[0 ..< 60] & "…" else: callText) & "`)"
        made.add NxMacroCall(line: l, text: t, syms: syms)
        break
    # (nothing expanded — the text does not compile now, say: what the calls made before stays)
    if made.len > 0 or j.code == 0:
      if mnSame(nxMacroSyms.getOrDefault(path), made):
        if made.len > 0: nxMacroSyms[path] = made      # (the same names: where the calls are now, nothing to redo)
      else:
        nxMacroSyms[path] = made
        if made.len == 0: nxMacroSyms.del path
        nxFiles.del path
        nxForgetScopesOf(path)                     # (what sees this file: the others are kept)
        inc nxGen
        needRender = true
      # (known now, for the calls as they were given: the engine's checks made without these names are made again,
      # the worker told, and the disk keeps them)
      nxMacroDone[path] = sig
      typoAt.clear()
      wkMacros(path)
      if depsOk: mnStore(path, textKey, sig, deps)
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
    if p notin nxMacroDone and p notin mnDiskTried and mnLoad(p, mnLinesOf(p)): continue   # (kept on disk for this text)
    let k = mnQueue.find(p)
    if k >= 0: mnQueue.delete(k)
    if p == mnRunning: continue
    mnQueue.insert(p, 0)                       # (this buffer first)
  mnNext()
