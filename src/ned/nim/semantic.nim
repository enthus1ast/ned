# ── colours from the index: a name is coloured by what it is (proc, type, constant, field), not by its case ──

type SemMap = ref object
  at: int                       # buffer version it was made for
  built: MonoTime
  kinds: Table[string, TokKind]  # normalized name → colour

const SemPauseMs = 350
var semMaps: Table[int, SemMap]

proc semMapFor(b: Buffer): SemMap =
  ## what each visible module-level name is; rebuilt when typing pauses (it parses the whole file, which in a
  ## big file would make keys stutter) — the main loop asks for a frame once the pause is long enough
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
  result.at = b.changeId
  result.built = getMonoTime()
  result.kinds.clear()
  try:
    let f = nxFileFor(b)
    if f == nil: return
    let sc = nxScope(f)
    for name, idxs in sc.byName:
      if idxs.len == 0: continue
      let k = sc.refs[idxs[0]].file.syms[sc.refs[idxs[0]].idx].kind
      let tk = case k
        of nxProc, nxFunc, nxMethod, nxIterator, nxConverter, nxTemplate, nxMacro: tkFunc
        of nxType: tkType
        of nxConst, nxEnumVal: tkConst
        of nxField: tkProperty
        else: tkText
      if tk != tkText: result.kinds[name] = tk
  except Exception as e: internalError("Nim index", e)

proc applySem(s: string, toks: var seq[TokKind], m: SemMap) =
  ## recolour the names on a line by what the index knows they are
  var i = 0
  let n = min(s.len, toks.len)
  while i < n:
    if s[i] in IdentStartChars and (i == 0 or s[i - 1] notin IdentChars) and toks[i] in {tkText, tkType}:
      var j = i
      while j < n and s[j] in IdentChars: inc j
      let k = m.kinds.getOrDefault(nxNorm(s[i ..< j]), tkText)
      if k != tkText:
        for q in i ..< j: toks[q] = k
      i = j
    else: inc i
