# ── colours from the index: a name is coloured by what it is (proc, template, type, constant, field, parameter,
#    module), not by its case — and by where it stands: after a dot a field or a call, a parameter inside its
#    routine, a module name before a dot ──

type SemMap = ref object
  at: int                        # buffer version it was made for
  built: MonoTime
  kinds: Table[string, TokKind]  # this file's names → colour (normalized)
  fields: HashSet[string]        # this file's names that are fields of some object (coloured so after a dot)
  calls: HashSet[string]         # … that are routines
  macros: HashSet[string]        # … templates and macros among them
  routines: seq[(int, int, seq[string])]   # this file's routines: (first line, last line, their parameters)
  modules: HashSet[string]       # the names its imports go by (strutils, or the `as` name)
  importKey: string              # the imported modules (and their stamps) the part below was made from
  importKinds: Table[string, TokKind]
  importFields, importCalls, importMacros: HashSet[string]

const SemPauseMs = 350
var semMaps: Table[int, SemMap]
var semLastMs = 0.0                     # how long the last rebuild took

proc semKindOfSym(k: NxKind): TokKind =
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
  if result != nil and (result.at == b.changeId or msSince(b.lspChangeAt) < SemPauseMs): return
  if result == nil:
    result = SemMap()
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
      for r in sc.refs:
        if r.file == f: continue
        semAdd(result.importKinds, result.importFields, result.importCalls, result.importMacros, r.sym)
    # this file's own names (they win over imported ones of the same name)
    result.kinds.clear()
    result.fields.clear()
    result.calls.clear()
    result.macros.clear()
    result.routines.setLen(0)
    result.modules.clear()
    for m in sc.modules.keys: result.modules.incl nxNorm(m)
    for s in f.syms:
      if s.made: continue
      semAdd(result.kinds, result.fields, result.calls, result.macros, s)
      if s.kind in NxRoutineKinds and s.endLine >= s.line:
        var ps: seq[string]
        for p in s.params: ps.add nxNorm(p.name)
        if ps.len > 0: result.routines.add (s.line, s.endLine, ps)
  except Exception as e: internalError("Nim index", e)
  semLastMs = float((getMonoTime() - t0).inMicroseconds) / 1000.0

proc semKind(m: SemMap, w: string): TokKind =
  result = m.kinds.getOrDefault(w, tkText)
  if result == tkText: result = m.importKinds.getOrDefault(w, tkText)

proc semParamsAt(m: SemMap, line: int): seq[string] =
  ## the parameters of the routines that `line` is inside (an inner one's too)
  for (a, e, ps) in m.routines:
    if a > line: break
    if line <= e: result.add ps

proc applySem(s: string, toks: var seq[TokKind], m: SemMap, line = -1) =
  ## recolour the names on a line by what the index knows they are, and where they stand
  var i = 0
  let n = min(s.len, toks.len)
  let params = if line >= 0: m.semParamsAt(line) else: @[]
  while i < n:
    if s[i] in IdentStartChars and (i == 0 or s[i - 1] notin IdentChars):
      var j = i
      while j < n and s[j] in IdentChars: inc j
      if toks[i] in {tkText, tkType}:
        let w = nxNorm(s[i ..< j])
        var q = j
        while q < n and s[q] == ' ': inc q
        var k = tkText
        if i > 0 and s[i - 1] == '.' and (i < 2 or s[i - 2] != '.'):
          # after a dot: a field, or a call (method-call syntax)
          let call = q < n and s[q] in {'(', '"', '['}
          let isField = w in m.fields or w in m.importFields
          let isCall = w in m.calls or w in m.importCalls
          if isField and (not isCall or not call): k = tkProperty
          elif isCall: k = (if w in m.macros or w in m.importMacros: tkPreproc else: tkFunc)
          else: k = m.semKind(w)
        elif w in params: k = tkParam
        elif q < n and s[q] == '.' and (q + 1 >= n or s[q + 1] != '.') and w in m.modules and
             m.semKind(w) == tkText:
          k = tkType                # a module name before a dot: strutils.join
        else:
          k = m.semKind(w)
          if k == tkProperty and not (q < n and s[q] == ':' and (q + 1 >= n or s[q + 1] != ':')):
            k = tkText              # (a bare field name is coloured only where it is named: Foo(x: 1))
        if k != tkText:
          for p in i ..< j: toks[p] = k
      i = j
    else: inc i
