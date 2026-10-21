# ── colours from the index: a name is coloured by what it is (proc, template, type, constant, field, parameter,
#    module), not by its case — and by where it stands: after a dot a field or a call, a parameter inside its
#    routine, a module name before a dot ──

type SemImports = ref object
  ## what the names from the rest of the scope are (imports, system, the program's other files) — shared by the
  ## files that see the same, and made a slice at a time: a big program's hundred thousand names took 30–50 ms at once
  key: uint64
  rich: bool
  kinds: Table[string, TokKind]
  fields, calls, macros: HashSet[string]
  globalVars, globalLets, deprecated, undeprecated: HashSet[string]
  done: bool
  pos: int                       # (how far through the scope's names it got)
  scope: NxScope                 # (the scope gone through, while it is made)
  own: string                    # (the file whose own names are left out)

type SemMap = ref object
  at: int                        # buffer version it was made for
  rich: bool                     # made with nim.richColors
  exact: bool                    # made for Nim 3 (names as written: nxExact)
  built: MonoTime
  kinds: Table[string, TokKind]  # this file's names → colour (normalized)
  fields: HashSet[string]        # this file's names that are fields of some object (coloured so after a dot)
  calls: HashSet[string]         # … that are routines
  macros: HashSet[string]        # … templates and macros among them
  routines: seq[(int, int, seq[string])]   # this file's routines: (first line, last line, their parameters)
  locals: seq[(int, int, HashSet[string], HashSet[string])]   # (nim.richColors) each routine's vars and lets
  globalVars, globalLets, deprecated: HashSet[string]          # … the module's own, and deprecated names
  undeprecated, importUndeprecated: HashSet[string]            # … names that also have an overload not deprecated
  modules: HashSet[string]       # the names its imports go by (strutils, or the `as` name)
  imp: SemImports                # the rest of the scope's names (nil: not made yet — the lexer's colours meanwhile)
  impNext: SemImports            # … being made for what the scope holds now

const SemPauseMs = 350
var semMaps: Table[int, SemMap]
var semLastMs = 0.0                     # how long the last rebuild took
var semImportsMade: seq[SemImports]     # (the last few made: another file of the program sees the same)

func semKindOfSym(k: NxKind): TokKind =
  case k
  of nxProc, nxFunc, nxMethod, nxIterator, nxConverter: tkFunc
  of nxTemplate, nxMacro: tkPreproc
  of nxType: tkType
  of nxConst, nxEnumVal: tkConst
  of nxField: tkProperty
  else: tkText

proc semAdd(kinds: var Table[string, TokKind], fields, calls, macros: var HashSet[string], s: NxSym) =
  let n = nxNorm(s.name)
  case s.kind
  of nxField: fields.incl n
  of NxRoutineKinds:
    calls.incl n
    if s.kind in {nxTemplate, nxMacro}: macros.incl n
  else: discard
  let k = semKindOfSym(s.kind)
  if k != tkText and n notin kinds: kinds[n] = k

func semMix(h: var uint64, s: string) =
  for c in s: h = (h xor uint64(ord(c))) * 0x100000001b3'u64
  h = (h xor 0xff'u64) * 0x100000001b3'u64

proc semImportKey(sc: NxScope, f: NxFile): uint64 =
  ## what the rest of the scope is: the files it read (each version) but this one, the toolchain
  result = 0xcbf29ce484222325'u64
  for (p, st) in sc.deps:
    if p != f.path:
      semMix(result, p)
      semMix(result, st)
  semMix(result, $(sc.refs.len - f.syms.len) & "/" & $nxGen & "/" & $nxScopeEpoch & "/" & $cfgRichColors)

proc semImportStep(m: SemImports, budgetMs: int): bool =
  ## a slice of the rest of the scope's names gone through; true when all are
  let t0 = getMonoTime()
  let refs = addr m.scope.refs
  while m.pos < refs[].len:
    let r = refs[][m.pos]
    inc m.pos
    if r.file.path == m.own: continue
    semAdd(m.kinds, m.fields, m.calls, m.macros, r.sym)
    if m.rich:
      let n = nxNorm(r.sym.name)
      if "deprecated" in r.sym.pragmas: m.deprecated.incl n
      elif r.sym.kind in NxRoutineKinds + {nxType, nxConst}: m.undeprecated.incl n
      if not r.sym.local:
        if r.sym.kind == nxVar: m.globalVars.incl n
        elif r.sym.kind == nxLet: m.globalLets.incl n
    if (m.pos and 1023) == 0 and msSince(t0) >= budgetMs: return false
  m.done = true
  m.scope = nil
  semImportsMade.add m
  if semImportsMade.len > 3: semImportsMade.delete(0)
  true

proc semImportsPump(b: Buffer) =
  ## the main loop, in quiet moments: the rest of the scope's names, 4 ms a round
  let m = semMaps.getOrDefault(b.id)
  if m == nil or m.impNext == nil: return
  if semImportStep(m.impNext, 4):
    m.imp = m.impNext
    m.impNext = nil
    needRender = true

proc semMapFor(b: Buffer): SemMap =
  ## what each name of the file means; rebuilt when typing pauses (it parses the whole file, which in a big file
  ## would make keys stutter) — the main loop asks for a frame once the pause is long enough. The part from the
  ## imported modules is kept while they stay the same: only this file's own names are gone through again
  if not cfgSemColors or not nimEngineOn(b) or b.path.len == 0: return nil
  result = semMaps.getOrDefault(b.id)
  if result != nil and (result.rich != cfgRichColors or result.exact != nxExact):
    result.rich = cfgRichColors                  # (the setting changed, or Nim 2 ↔ 3: all of it again)
    result.exact = nxExact
    result.at = -1
    result.imp = nil
    result.impNext = nil
  if result != nil and (result.at == b.changeId or msSince(b.lspChangeAt) < SemPauseMs): return
  if result != nil and not engineReady(b): return     # (the files it needs are being read: a moment)
  if result == nil:
    result = SemMap(rich: cfgRichColors, exact: nxExact)
    semMaps[b.id] = result
    var later = b.lines.len > 3000
    if not later:
      try: later = not nxScopeCached(nxFileFor(b))
      except CatchableError: later = true
    if later:
      # a big file just opened — or one whose imports have not been read yet: shown at once, its names coloured
      # a moment later (the main loop asks for that frame), once the engine has read what it sees in a quiet
      # moment — doing that first would hold up the first frame
      result.at = -1
      result.built = getMonoTime()
      return
  let t0 = getMonoTime()
  result.at = b.changeId
  result.built = t0
  try:
    let f = nxFileFor(b)
    if f == nil: return
    let sc = nxScope(f)
    # the rest of the scope's names: kept while it stays the same (typing in this file changes only its own) — made
    # anew a slice at a time when it changed, another file's when it sees the same
    let key = semImportKey(sc, f)
    if result.imp == nil or result.imp.key != key:
      var found: SemImports = nil
      for x in semImportsMade:
        if x.key == key: found = x
      if found != nil:
        result.imp = found
        result.impNext = nil
      elif result.impNext == nil or result.impNext.key != key:
        result.impNext = SemImports(key: key, rich: cfgRichColors, scope: sc, own: f.path)
        when defined(nedNoMain):
          # (nedls: no main loop to make it in quiet moments — the answer waits for it)
          discard semImportStep(result.impNext, high(int) div 2)
          result.imp = result.impNext
          result.impNext = nil
    # this file's own names (they win over imported ones of the same name)
    result.kinds.clear()
    result.fields.clear()
    result.calls.clear()
    result.macros.clear()
    result.routines.setLen(0)
    result.locals.setLen(0)
    result.globalVars.clear()
    result.globalLets.clear()
    result.deprecated.clear()
    result.undeprecated.clear()
    result.modules.clear()
    for m in sc.modules.keys: result.modules.incl nxNorm(m)
    for s in f.syms:
      if s.made: continue
      semAdd(result.kinds, result.fields, result.calls, result.macros, s)
      if cfgRichColors:
        let n = nxNorm(s.name)
        if "deprecated" in s.pragmas: result.deprecated.incl n
        elif s.kind in NxRoutineKinds + {nxType, nxConst}: result.undeprecated.incl n
        if s.kind in {nxVar, nxLet} and not s.local and nxEnclosing(f, s.line) < 0:
          if s.kind == nxVar: result.globalVars.incl n
          else: result.globalLets.incl n
      if s.kind in NxRoutineKinds and s.endLine >= s.line:
        var ps: seq[string]
        for p in s.params: ps.add nxNorm(p.name)
        if s.ret.len > 0 and s.ret != "void" and s.kind notin {nxTemplate, nxMacro, nxIterator}:
          ps.add "result"           # (the routine's implicit variable, coloured like its parameters)
        if ps.len > 0: result.routines.add (s.line, s.endLine, ps)
        if cfgRichColors and s.endLine > s.line and s.endLine < b.lines.len and s.endLine - s.line < 4000 and
           result.locals.len < 3000:
          # its locals: which can change (var) and which cannot (let) — a local wins over a global of that name
          var vs, ls: HashSet[string]
          for l in nxLocals(f, b.lines, s.endLine, b.lines[s.endLine].len, everything = true):
            if l.kind == nxVar: vs.incl nxNorm(l.name)
            elif l.kind in {nxLet, nxForVar}: ls.incl nxNorm(l.name)
          if vs.len + ls.len > 0: result.locals.add (s.line, s.endLine, vs, ls)
  except Exception as e: internalError("Nim index", e)
  semLastMs = float((getMonoTime() - t0).inMicroseconds) / 1000.0

proc semKind(m: SemMap, w: string): TokKind =
  result = m.kinds.getOrDefault(w, tkText)
  if result == tkText and m.imp != nil: result = m.imp.kinds.getOrDefault(w, tkText)

template impHas(m: SemMap, field: untyped, w: string): bool =
  m.imp != nil and w in m.imp.field

proc semParamsAt(m: SemMap, line: int): seq[string] =
  ## the parameters of the routines that `line` is inside (an inner one's too)
  for i in 0 ..< m.routines.len:            # (by index: no copy of each routine's list on the way)
    if m.routines[i][0] > line: break
    if line <= m.routines[i][1]: result.add m.routines[i][2]

proc semLocalKind(m: SemMap, line: int, w: string): TokKind =
  ## (nim.richColors) a local's colour on `line`: tkMutable for a var, tkText for a let, tkNone… (tkPunct: not a local)
  result = tkPunct
  for k in countdown(m.locals.high, 0):         # (an inner routine's locals first)
    if m.locals[k][0] > line or line > m.locals[k][1]: continue
    if w in m.locals[k][2]: return tkMutable
    if w in m.locals[k][3]: return tkText

const UnsafeWords = ["cast", "addr", "unsafeAddr", "ptr"]

proc applySem(s: string, toks: var seq[TokKind], m: SemMap, line = -1) =
  ## recolour the names on a line by what the index knows they are, and where they stand
  var i = 0
  let n = min(s.len, toks.len)
  let params = if line >= 0: m.semParamsAt(line) else: @[]
  while i < n:
    if s[i] in IdentStartChars and (i == 0 or s[i - 1] notin IdentChars):
      var j = i
      while j < n and s[j] in IdentChars: inc j
      if cfgRichColors and toks[i] in {tkKeyword, tkText, tkFunc} and j - i <= 10 and s[i ..< j] in UnsafeWords:
        for p in i ..< j: toks[p] = tkUnsafe
        i = j
        continue
      if toks[i] in {tkText, tkType, tkFunc, tkProperty}:     # (what the lexer guessed from the shape: f(…), x.y)
        let w = nxNorm(s[i ..< j])
        var q = j
        while q < n and s[q] == ' ': inc q
        var k = tkText
        if i > 0 and s[i - 1] == '.' and (i < 2 or s[i - 2] != '.'):
          # after a dot: a field, or a call (method-call syntax)
          let call = q < n and s[q] in {'(', '"', '['}
          let isField = w in m.fields or m.impHas(fields, w)
          let isCall = w in m.calls or m.impHas(calls, w)
          if isField and not isCall: k = tkProperty
          elif isCall and (call or not isField): k = (if w in m.macros or m.impHas(macros, w): tkPreproc else: tkFunc)
          elif not isField: k = m.semKind(w)
          # (both a field somewhere and a routine, written without a call — x.len, x.name: the lexer's guess stays)
        elif w in params: k = tkParam
        elif q < n and s[q] == '.' and (q + 1 >= n or s[q + 1] != '.') and w in m.modules and
             m.semKind(w) == tkText:
          k = tkType                # a module name before a dot: strutils.join
        else:
          k = m.semKind(w)
          if k == tkProperty and not (q < n and s[q] == ':' and (q + 1 >= n or s[q + 1] != ':')):
            k = tkText              # (a bare field name is coloured only where it is named: Foo(x: 1))
          if cfgRichColors and k == tkText and line >= 0:
            let lk = m.semLocalKind(line, w)
            if lk != tkPunct: k = lk
            elif w in m.globalVars or (w notin m.globalLets and m.impHas(globalVars, w)): k = tkGlobalVar
            elif w in m.globalLets or m.impHas(globalLets, w): k = tkGlobal
        # (deprecated: every overload of that name is — `add` has deprecated overloads, and others)
        if cfgRichColors and k != tkParam and (w in m.deprecated or m.impHas(deprecated, w)) and
           w notin m.undeprecated and not m.impHas(undeprecated, w) and
           not (i > 0 and s[i - 1] == '.' and k == tkProperty):
          k = tkDeprecated
        if k != tkText:
          for p in i ..< j: toks[p] = k
      i = j
    else: inc i
