# ── side effects: has a routine any, as the engine works it out — the walk of raises.nim, where a side effect is
#    what is "raised": a module's variable used (a var, let, threadvar or {.global.}), a routine with side effects
#    called (echo, I/O, one through a proc variable without {.noSideEffect.} …). As the compiler infers it for a proc,
#    a func may call a proc that has none. Only when the engine is sure of every call: an unknown name, a method, a
#    macro, a call on a generic's type parameters → not known (no answer rather than a wrong one) ──

type NxPurity* = object
  known*: bool                 # the engine is sure
  pure*: bool                  # (known) no side effects
  why*: string                 # what it found (a side effect) or what stopped it (not known)
  cut*: bool                   # (not known) it ran out of time: asking again may tell

proc nxFxCtx(limit, ms: int): NxRsCtx =
  result = NxRsCtx(limit: limit, deadline: getMonoTime() + initDuration(milliseconds = ms), cycleAt: high(int),
                   fx: true)
  result.deps.add initHashSet[string]()

proc nxFxOne(c: var NxRsCtx, r: NxRef): NxPurity =
  ## one routine, in a request that may ask about several (what it looked up is shared; each has its own steps)
  c.steps = 0
  c.busy.setLen(0)
  c.cycleAt = high(int)
  c.impure = false
  c.why = ""
  var x: NxRaises
  try: x = nxRsRoutine(c, r, "", -1)
  except CatchableError: x = nxRsFail("an error")
  if c.cut:
    if getMonoTime() < c.deadline:
      c.cut = false                  # (its own steps ran out, not the time: not known, the next ones go on)
      return NxPurity(why: "too much to read")
    return NxPurity(why: "out of time", cut: true)
  if not x.known: return NxPurity(why: x.why)
  NxPurity(known: true, pure: not nxFxHas(x.excs), why: x.why)

proc nxSideEffectsOf*(r: NxRef, limit = 4000, ms = 2000): NxPurity =
  ## does routine `r` have side effects, as the compiler would infer it (known = false when the engine cannot be
  ## sure, or runs out of steps or of `ms` milliseconds — what it worked out on the way is kept for the next time)
  if r.file == nil or r.sym.kind notin NxRoutineKinds: return NxPurity(why: "not a routine")
  var c = nxFxCtx(limit, ms)
  nxFxOne(c, r)

var nxStrictDirs: Table[string, (float, bool)]     # folder → (when looked, a config file there names strictFuncs)

proc nxStrictFuncsOn*(path: string, lines: openArray[string]): bool =
  ## does the compiler check this file with strictFuncs (a func may not change what a ref or ptr parameter points
  ## to) — the file says so, or a nim.cfg / config.nims / *.nims of its folder or one above it — or reorder its code
  ## (codeReordering: a call may come before the body it calls)
  for l in lines:
    # ({.experimental: "strictFuncs".}: the name quoted — not an enum's member of that name)
    if l.len > 14 and ("\"strictFuncs\"" in l or "\"codeReordering\"" in l or ":strictFuncs" in l or
                       ":codeReordering" in l): return true
  let now = epochTime()
  var d = parentDir(path)
  for _ in 0 .. 12:
    if d.len == 0: break
    if d notin nxStrictDirs or now - nxStrictDirs[d][0] > 10:
      var on = false
      try:
        for kind, p in walkDir(d):
          if kind notin {pcFile, pcLinkToFile}: continue
          let n = p.extractFilename
          if n == "nim.cfg" or n == "config.nims" or n.endsWith(".nims") or n.endsWith(".nim.cfg"):
            if getFileSize(p) < 200_000:
              let t = readFile(p)
              if "strictFuncs" in t or "codeReordering" in t: on = true
      except CatchableError: discard
      if nxStrictDirs.len > 512: nxStrictDirs.clear()
      nxStrictDirs[d] = (now, on)
    if nxStrictDirs[d][1]: return true
    let up = parentDir(d)
    if up == d: break
    d = up
  false

const NxFuncPragmas = ["inline", "noinline", "gcsafe", "raises", "tags", "forbids", "discardable", "deprecated", "used",
                       "inl", "benign", "locks", "stackTrace", "lineTrace", "noinit", "procvar", "nimcall", "cdecl",
                       "since", "nosinks", "noreturn"]
  ## the pragmas a proc that can be a func may have (not exportc, importc, async, closure, sideEffect …)

proc nxFuncStub(lines: seq[string], s: NxSym): bool =
  ## a body still to be written: nothing, `discard`, a raise, `doAssert false`
  let (bl, bc) = nxRsBodyStart(lines, s)
  if bl < 0: return true
  for l in bl .. min(s.endLine, lines.high):
    let t = nxCodeOf(if l == bl: lines[l][min(bc, lines[l].len) .. ^1] else: lines[l]).strip
    if t.len == 0: continue
    if t == "discard" or t.startsWith("discard \"") or t.startsWith("raise ") or t == "raise" or
       t.startsWith("doAssert false") or t.startsWith("assert false") or t.startsWith("quit("): continue
    return false
  true

type NxFuncFile = object       # what the hint looks at once for a whole file
  ahead: HashSet[string]       # the names of the routines declared ahead (forward), here or in another file of
                               # the module (include)
  outer: seq[(int, int)]       # the routines' lines (a proc inside one is not the module's)
  sc: NxScope

proc nxFuncFileOf(c: var NxRsCtx, f: NxFile, lines: seq[string]): NxFuncFile =
  result.sc = nxRsScope(c, f)
  for s in f.syms:
    if s.kind notin NxRoutineKinds or s.made: continue
    result.outer.add (s.line, s.endLine)
    if s.endLine <= s.line and nxIsForward(lines, s): result.ahead.incl nxNorm(s.name)
  if f.path notin c.modFiles: c.modFiles[f.path] = nxFxModuleFiles(f.path)
  for p in c.modFiles[f.path]:
    if p == f.path: continue
    let g = nxLoad(p)
    if g == nil: continue
    for t in g.syms:
      if t.kind in NxRoutineKinds and not t.made and t.endLine <= t.line: result.ahead.incl nxNorm(t.name)

proc nxFuncHintableIn(ff: NxFuncFile, f: NxFile, lines: seq[string], s: NxSym): bool =
  if s.kind != nxProc or s.made or s.local or s.name.len == 0 or s.name[0] == '=': return false
  if s.endLine >= lines.len or s.line >= lines.len: return false
  for (n, _) in nxLayPragmas(s.pragmas):
    if n notin NxFuncPragmas: return false
  if nxNorm(s.name) in ff.ahead:
    # (declared ahead — this one, or one of the same name: the body would no longer be what it declares)
    if nxIsForward(lines, s) or nxForwardOf(f, lines, s) >= 0: return false
    let files = nxFxModuleFiles(f.path)
    for p in files:
      if p == f.path: continue
      let g = nxLoad(p)
      if g == nil: continue
      for t in g.syms:
        if t.kind in NxRoutineKinds and t.name == s.name and t.endLine <= t.line and nxSameSig(t, s): return false
  for (a, e) in ff.outer:
    if a < s.line and s.endLine <= e: return false
  if nxRsGenericParams(ff.sc, s).len > 0: return false
  not nxFuncStub(lines, s)

proc nxFuncHintable*(f: NxFile, lines: seq[string], s: NxSym): bool =
  ## a proc that the "can be a func" hint may be about: of this module, with a body (not a stub), not generic, not
  ## declared ahead (a forward declaration would need the change too), not a hook (=destroy …), not inside another
  ## routine, with no pragma that a func would change the meaning of (exportc, importc, async, closure, sideEffect …)
  var c = nxFxCtx(1, 1000)
  nxFuncHintableIn(nxFuncFileOf(c, f, lines), f, lines, s)

proc nxFuncKeywordAt*(lines: openArray[string], s: NxSym): int =
  ## the column of the `proc` that declares `s` (on its line), -1 when it is not there
  if s.line >= lines.len: return -1
  let t = lines[s.line]
  var k = t.find("proc")
  while k >= 0 and k < s.col:
    if (k == 0 or not nxIsIdent(t[k - 1])) and (k + 4 >= t.len or not nxIsIdent(t[k + 4])): return k
    k = t.find("proc", k + 1)
  -1

proc nxFuncHints*(f: NxFile, lines: seq[string], ms = 2000, keep: proc(s: NxSym): bool = nil): (seq[int], bool) =
  ## the procs of the file that can be funcs (indices into f.syms: the engine is sure they have no side effects),
  ## and whether it ran out of its `ms` milliseconds first (what it worked out is kept: asking again goes on).
  ## `keep`: which procs to look at (nil: all)
  if f == nil or nxStrictFuncsOn(f.path, lines): return
  var c = nxFxCtx(4000, ms)
  let ff = nxFuncFileOf(c, f, lines)
  for i in 0 ..< f.syms.len:
    template s: untyped = f.syms[i]
    if s.kind != nxProc or s.made or s.local: continue
    if keep != nil and not keep(s): continue
    if not nxFuncHintableIn(ff, f, lines, s): continue
    let x = nxFxOne(c, NxRef(file: f, idx: int32(i)))
    if x.cut: return (result[0], true)
    if x.known and x.pure: result[0].add i

# ── why tracers: why a routine raises an exception, or has a side effect — the place in its body where it comes in,
#    then the routine called there and the place in its body, … down to the raise, the global, or the declaration
#    that starts it ──

type
  NxWhyKind* = enum nwCall, nwRaise, nwGlobal, nwDeclared, nwStop
  NxWhyStep* = object
    path*: string
    line*, col*: int
    routine*: string           # the routine this place is in
    what*: string              # (nwCall) the routine called · (nwGlobal) the variable · (nwDeclared, nwStop) why
    kind*: NxWhyKind

proc nxWhyRef(v: NxVia): NxRef =
  ## the routine a step calls, found again by its file, line and name
  var f = nxFiles.getOrDefault(v.path)
  if f == nil:
    try: f = nxLoad(v.path)
    except CatchableError: return
  if f == nil: return
  for i in 0 ..< f.syms.len:
    if f.syms[i].line == v.line and f.syms[i].name == v.name: return NxRef(file: f, idx: int32(i))

proc nxFxBody(r: NxRef, ms: int): NxRaises =
  ## (fx) the side effects of a routine, with where each comes in (the first one: the rest is not read)
  var c = nxFxCtx(4000, ms)
  try: result = nxRsRoutine(c, r, "", -1)
  except CatchableError: result = nxRsFail("an error")
  if c.cut: result = NxRaises(known: false, why: "out of time", cut: true)

proc nxWhy*(r: NxRef, exc: string, fx = false, ms = 8000): seq[NxWhyStep] =
  ## why routine `r` raises `exc` (fx: has side effects): each place on the way, the first in r's own body
  if r.file == nil or r.sym.kind notin NxRoutineKinds: return
  let t0 = getMonoTime()
  var cur = r
  var seen: HashSet[string]
  for _ in 0 .. 24:
    let key = cur.file.path & ":" & $cur.sym.line
    if key in seen: break
    seen.incl key
    let left = ms - int((getMonoTime() - t0).inMilliseconds)
    if left <= 0:
      result.add NxWhyStep(path: cur.file.path, line: cur.sym.line, col: cur.sym.col, routine: cur.sym.name,
                           what: "out of time", kind: nwStop)
      return
    let x = if fx: nxFxBody(cur, left) else: nxRaisesOfBody(cur, 4000, left)
    let at0 = NxWhyStep(path: cur.file.path, line: cur.sym.line, col: cur.sym.col, routine: cur.sym.name)
    if not x.known:
      var s = at0
      s.kind = nwStop
      s.what = if x.why.len > 0: x.why else: "the engine cannot tell"
      result.add s
      return
    var hit = -1
    for i, e in x.excs:
      if (fx and e.name == NxFxMark) or (not fx and nxNorm(e.name) == nxNorm(exc)):
        hit = i
        break
    if hit < 0:
      var s = at0
      if fx:
        s.kind = nwDeclared
        s.what = if x.why.len > 0: x.why else: cur.sym.name & " has side effects"
      else:
        let (has, list) = nxRaisesDeclared(cur)
        s.kind = (if has: nwDeclared else: nwStop)
        s.what = if has: "{.raises: [" & list & "].}" else: "the engine does not see where"
      result.add s
      return
    let e = x.excs[hit]
    if e.at.path.len == 0:
      var s = at0
      s.kind = nwDeclared
      s.what = if fx: (if x.why.len > 0: x.why else: cur.sym.name & " has side effects")
               else: "it declares it"
      result.add s
      return
    var s = NxWhyStep(path: e.at.path, line: e.at.line, col: e.at.col, routine: cur.sym.name, what: e.at.what)
    s.kind = if e.via.path.len > 0: nwCall elif e.at.what == "raise": nwRaise elif fx: nwGlobal else: nwRaise
    result.add s
    if e.via.path.len == 0: return
    let nx = nxWhyRef(e.via)
    if nx.file == nil: return
    cur = nx
