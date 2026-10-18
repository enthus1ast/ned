# ── colours from the index: a name is coloured by what it is (proc, template, type, constant, field, parameter,
#    module), not by its case — and by where it stands: after a dot a field or a call, a parameter inside its
#    routine, a module name before a dot ──

type SemMap = ref object
  at: int                        # buffer version it was made for
  rich: bool                     # made with nim.richColors
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
  importKey: string              # the imported modules (and their stamps) the part below was made from
  importKinds: Table[string, TokKind]
  importFields, importCalls, importMacros: HashSet[string]
  importGlobalVars, importGlobalLets, importDeprecated: HashSet[string]

const SemPauseMs = 350
var semMaps: Table[int, SemMap]
var semLastMs = 0.0                     # how long the last rebuild took

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

proc semMapFor(b: Buffer): SemMap =
  ## what each name of the file means; rebuilt when typing pauses (it parses the whole file, which in a big file
  ## would make keys stutter) — the main loop asks for a frame once the pause is long enough. The part from the
  ## imported modules is kept while they stay the same: only this file's own names are gone through again
  if not cfgSemColors or not nimEngineOn(b) or b.path.len == 0: return nil
  result = semMaps.getOrDefault(b.id)
  if result != nil and result.rich != cfgRichColors:
    result.rich = cfgRichColors                  # (the setting changed: all of it again)
    result.at = -1
    result.importKey = ""
  if result != nil and (result.at == b.changeId or msSince(b.lspChangeAt) < SemPauseMs): return
  if result == nil:
    result = SemMap(rich: cfgRichColors)
    semMaps[b.id] = result
    if b.lines.len > 3000:
      # a big file just opened: shown at once, its names coloured a moment later (the main loop asks for that
      # frame) — parsing all of it first would hold up the first frame
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
    var key = ""
    for (p, st) in sc.deps: key.add p & "\t" & st & "\n"
    key.add $(sc.refs.len - f.syms.len)
    if key != result.importKey:
      result.importKey = key
      result.importKinds.clear()
      result.importFields.clear()
      result.importCalls.clear()
      result.importMacros.clear()
      result.importGlobalVars.clear()
      result.importUndeprecated.clear()
      result.importGlobalLets.clear()
      result.importDeprecated.clear()
      for r in sc.refs:
        if r.file == f: continue
        semAdd(result.importKinds, result.importFields, result.importCalls, result.importMacros, r.sym)
        if cfgRichColors:
          let n = nxNorm(r.sym.name)
          if "deprecated" in r.sym.pragmas: result.importDeprecated.incl n
          elif r.sym.kind in NxRoutineKinds + {nxType, nxConst}: result.importUndeprecated.incl n
          if not r.sym.local:
            if r.sym.kind == nxVar: result.importGlobalVars.incl n
            elif r.sym.kind == nxLet: result.importGlobalLets.incl n
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
  if result == tkText: result = m.importKinds.getOrDefault(w, tkText)

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
          let isField = w in m.fields or w in m.importFields
          let isCall = w in m.calls or w in m.importCalls
          if isField and not isCall: k = tkProperty
          elif isCall and (call or not isField): k = (if w in m.macros or w in m.importMacros: tkPreproc else: tkFunc)
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
            elif w in m.globalVars or (w notin m.globalLets and w in m.importGlobalVars): k = tkGlobalVar
            elif w in m.globalLets or w in m.importGlobalLets: k = tkGlobal
        # (deprecated: every overload of that name is — `add` has deprecated overloads, and others)
        if cfgRichColors and k != tkParam and (w in m.deprecated or w in m.importDeprecated) and
           w notin m.undeprecated and w notin m.importUndeprecated and
           not (i > 0 and s[i - 1] == '.' and k == tkProperty):
          k = tkDeprecated
        if k != tkText:
          for p in i ..< j: toks[p] = k
      i = j
    else: inc i
