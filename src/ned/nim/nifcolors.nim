# ── colours from the compiler's reading of a saved file (nimnif.nim: Nim 2.4's `nim nif`, or nimony with Nim 3):
#    what each name is as the compiler resolved it — a name a macro made, which overload, a field — over the engine's
#    guess, on the lines as saved — or, while you type, as the last typing check read them (nimnif.nim: a line
#    changed since keeps the engine's colours until the next check) ──

proc nifColorsOn(b: Buffer): bool =
  ## whether the buffer's colours come partly from its NIF now (asked once a frame: each line then looks it up)
  nifFactsFor(b) != nil

proc applyNifColors(b: Buffer, s: string, toks: var seq[TokKind], line: int) =
  ## recolours the names of a line by what the compiler says they are — a name only where the compiler gives all of
  ## that name on the line one colour, and only over text coloured as code (not a keyword, a string or a comment)
  let fx = nifFactsFor(b)
  let fl = nifLineAt(fx, b, line)
  if fl < 0: return
  fx.kinds.withValue(fl, row):
    var i = 0
    let n = min(s.len, toks.len)
    while i < n:
      if s[i] in IdentStartChars and (i == 0 or s[i - 1] notin IdentChars):
        var j = i
        while j < n and s[j] in IdentChars: inc j
        let k = row[].getOrDefault(nxNorm(s[i ..< j]), tkText)
        if k != tkText and toks[i] in {tkText, tkType, tkFunc, tkProperty, tkConst, tkParam, tkMutable, tkGlobal,
                                       tkGlobalVar, tkVariable}:
          for p in i ..< j: toks[p] = k
        i = j
      else: inc i
