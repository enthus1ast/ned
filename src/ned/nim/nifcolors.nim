# ── Nim 3: colours from nimony's own reading of a saved file (its .s.nif, after nimony checks it): what each name is
#    as the compiler resolved it — a name a macro made, which overload, a field — over the engine's guess, on the
#    lines as saved (a buffer changed since keeps the engine's colours until nimony reads it again) ──

type NifColors = object
  stamp: string                              # the source file's stamp they are for
  nifTime: times.Time
  at: Table[int, seq[(int, int, TokKind)]]   # line → (column, length, colour)

var
  nifColorMemo: Table[string, NifColors]     # path → its colours
  nifColorLooked: Table[string, MonoTime]    # (the NIF looked for: at most every 3 s a file)
  nifFileMemo: Table[string, (string, string)]   # path → (its stamp, its .s.nif)

func nifTagColor(tag: string): TokKind =
  case tag
  of "proc", "func", "iterator", "converter", "method": tkFunc
  of "template", "macro": tkPreproc
  of "type": tkType
  of "fld": tkProperty
  of "efld", "const": tkConst
  of "param": tkParam
  of "gvar", "tvar": tkGlobalVar
  of "glet": tkGlobal
  of "var": tkMutable
  else: tkText

proc nifColorsBuild(path, nif: string): Table[int, seq[(int, int, TokKind)]] =
  ## each symbol written in the file, coloured by its declaration in the NIF (this module's), or by where it stands
  ## (the callee of a call: a routine; a field after a dot) for the other modules' — nothing when unsure
  var nodes: seq[NifNode]
  try: nodes = nifParse(readFile(nif).splitLines)
  except CatchableError: return
  var kindOf: Table[string, TokKind]
  for n in nodes:
    if n.isDef and n.parent >= 0:
      let k = nifTagColor(nodes[n.parent].tag)
      if k != tkText: kindOf[nifSymName(n.atom)] = k
  let fileEnd = "/" & extractFilename(path)
  for i, n in nodes:
    if n.atom.len == 0 or n.sline < 0 or n.tag.len > 0: continue
    if n.file.len > 0 and not (path.endsWith(n.file) or n.file.endsWith(fileEnd) or n.file == extractFilename(path)):
      continue
    let name = nifSymName(n.atom)
    if name.len == 0 or name[0] notin IdentStartChars: continue
    var k = kindOf.getOrDefault(name, tkText)
    if k == tkText and n.parent >= 0:
      let p = nodes[n.parent]
      # (the first thing in a call is what is called; the third of a `dot` is the field)
      var first = -1
      var nth = 0
      for j in n.parent + 1 ..< min(nodes.len, n.parent + 64):
        if nodes[j].parent != n.parent: continue
        if first < 0: first = j
        if j == i: break
        inc nth
      if p.tag in ["call", "cmd", "callstrlit", "infix", "prefix"] and first == i: k = tkFunc
      elif p.tag == "dot" and nth == 1: k = tkProperty
    if k == tkText: continue
    let short = name.split('.')[0]
    result.mgetOrPut(n.sline, @[]).add (n.scol, short.len, k)

proc nifColorsFor(b: Buffer): ptr Table[int, seq[(int, int, TokKind)]] =
  ## the colours nimony's reading of the file gives, when the buffer is the file as saved (nil: none)
  if not nim3On() or b.path.len == 0 or b.dirty or b.lang == nil or b.lang.mode != lmNim: return nil
  let st = nxStamp(b.path)
  nifColorMemo.withValue(b.path, m):
    if m[].stamp == st and msSince(nifColorLooked.getOrDefault(b.path)) < 3000: return addr m[].at
  if msSince(nifColorLooked.getOrDefault(b.path)) < 3000:
    nifColorMemo.withValue(b.path, m):
      if m[].stamp == st: return addr m[].at
    return nil
  if nifColorLooked.len > 200: nifColorLooked.clear()
  nifColorLooked[b.path] = getMonoTime()
  var nif = ""
  nifFileMemo.withValue(b.path, fm):
    if fm[][0] == st: nif = fm[][1]
  if nif.len == 0:
    nif = nifFileFor(b.path)
    if nifFileMemo.len > 200: nifFileMemo.clear()
    nifFileMemo[b.path] = (st, nif)
  if nif.len == 0 or not nif.endsWith(".s.nif"): return nil
  var t: times.Time
  try: t = getLastModificationTime(nif)
  except CatchableError: return nil
  var srcT: times.Time
  try: srcT = getLastModificationTime(b.path)
  except CatchableError: return nil
  if t < srcT: return nil                      # (read before the last save: its positions are not this text's)
  nifColorMemo.withValue(b.path, m):
    if m[].stamp == st and m[].nifTime == t: return addr m[].at
  if nifColorMemo.len > 32: nifColorMemo.clear()
  nifColorMemo[b.path] = NifColors(stamp: st, nifTime: t, at: nifColorsBuild(b.path, nif))
  needRender = true
  addr nifColorMemo[b.path].at

proc applyNifColors(s: string, toks: var seq[TokKind], at: ptr Table[int, seq[(int, int, TokKind)]], line: int) =
  if at == nil: return
  at[].withValue(line, cs):
    for (c, n, k) in cs[]:
      # (only over a name the text still has there, coloured as code)
      if c < 0 or c + n > s.len or c + n > toks.len: continue
      if not (s[c] in IdentStartChars) or (c + n < s.len and s[c + n] in IdentChars): continue
      if toks[c] notin {tkText, tkType, tkFunc, tkProperty, tkConst, tkParam, tkMutable, tkGlobal, tkGlobalVar}: continue
      for p in c ..< c + n: toks[p] = k
