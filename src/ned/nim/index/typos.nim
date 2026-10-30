# ── names that are surely misspelled: told at once, before the compiler's check comes back ──

proc nxTypoDist*(a, b: string): int =
  ## edits between two names, a swap of two neighbours counting as one (nmaes → names)
  let n = a.len
  let m = b.len
  var d = newSeq[seq[int]](n + 1)
  for i in 0 .. n:
    d[i] = newSeq[int](m + 1)
    d[i][0] = i
  for j in 0 .. m: d[0][j] = j
  for i in 1 .. n:
    for j in 1 .. m:
      let cost = if a[i - 1] == b[j - 1]: 0 else: 1
      d[i][j] = min(min(d[i - 1][j] + 1, d[i][j - 1] + 1), d[i - 1][j - 1] + cost)
      if i > 1 and j > 1 and a[i - 1] == b[j - 2] and a[i - 2] == b[j - 1]:
        d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
  d[n][m]

var nxTypoText*: Table[string, (string, string)]     # path → (stamp, its text in lower case without underscores)
var nxTypoTextBytes* = 0               # (their sizes added up)

proc nxTypoWrittenIn*(sc: NxScope, nw: string): bool =
  ## does any file the scope draws on have the word in it (anywhere: a `when` branch ned left out, a template)?
  let w = nw.toLowerAscii
  var seen: HashSet[string]
  for r in sc.refs:
    let p = r.file.path
    if p.len == 0 or p in seen: continue
    seen.incl p
    let st = r.file.stamp
    var txt = ""
    if p in nxTypoText and nxTypoText[p][0] == st: txt = nxTypoText[p][1]
    else:
      try:
        txt = (if nxBufferLines != nil and nxBufferStamp(p).len > 0: nxBufferLines(p).join("\n") else: readFile(p))
        txt = txt.toLowerAscii.replace("_", "")
      except CatchableError: txt = ""
      nxTypoTextBytes += txt.len
      if nxTypoTextBytes > 16_000_000:       # (the text of every file looked through, in every project of a long
        nxTypoText.clear()                   # session: at most this much, made again as asked)
        nxTypoTextBytes = txt.len
      nxTypoText[p] = (st, txt)
    if r.file == sc.own: continue
    var k = txt.find(w)
    while k >= 0:
      # (as a word of its own)
      if (k == 0 or not nxIsIdent(txt[k - 1])) and (k + w.len >= txt.len or not nxIsIdent(txt[k + w.len])): return true
      k = txt.find(w, k + 1)
  false

proc nxTypos*(f: NxFile, lines: seq[string], lo, hi: int, cur: (int, int)): seq[(int, int, string, string)] =
  ## (line, col, name, the name meant) for a name inside a routine that nothing declares, that appears nowhere
  ## else in the file, and that is one or two letters away from a name that is declared. Kept to where that is
  ## certain: not in templates, macros, `when` branches, the arguments or blocks of a template call, `defined(…)`
  if f == nil or lines.len == 0 or nxLibDir.len == 0: return
  if nxInSystem(f.path, partsOnly = true): return      # (system's own parts see more than ned knows)
  if nxIncluderOf(f.path).len > 0: return                       # (nor does a file another one includes)
  for im in f.imports:
    # (a module ned cannot find may declare it)
    if nxResolve(f.path, im.spec).len == 0: return
  let sc = nxScope(f)
  # (a `.` macro or template in scope — jsffi's, a DSL's —: any name after a dot may be meant)
  let dotOps = nxLookup(sc, ".").len > 0 or nxLookup(sc, "`.`").len > 0 or nxLookup(sc, ".()").len > 0
  # how often each name is written in the file
  var count: CountTable[string]
  var st0: NxLexState
  for l in 0 ..< lines.len:
    for (s, e) in nxIdents(lines[l], st0): count.inc nxNorm(lines[l][s ..< e])
  for ri in 0 ..< f.syms.len:
    # the routine being checked for misspelt names
    template r: untyped = f.syms[ri]
    if r.kind notin {nxProc, nxFunc, nxMethod, nxIterator, nxConverter} or r.made: continue
    if r.endLine < lo or r.line > hi or r.endLine <= r.line: continue
    var known: Table[string, string]          # (normalized → as written)
    for s in nxLocals(f, lines, r.endLine, high(int) div 2, everything = true): known[nxNorm(s.name)] = s.name
    for g in nxGenericNames(r.generics): known[nxNorm(g)] = g
    known["result"] = "result"
    # the lines inside a block a template call or `when` opens (and the template calls' own lines): not looked at
    var skipInd = -1
    var whenInd = -1                         # (the `when` whose `elif` / `else` branches are skipped too)
    var whenDecided: Table[int, bool]        # (indentation → every condition of its when chain decided here)
    var st: NxLexState
    for l in r.line + 1 .. min(r.endLine, lines.high):
      let raw = lines[l]
      let t = raw.strip
      let wasStr = st.inTriple or st.blockDepth > 0
      let ids = nxIdents(raw, st)
      if t.len == 0 or t[0] == '#' or wasStr: continue
      let ind = leadWs(raw)
      if skipInd >= 0:
        if ind > skipInd: continue
        skipInd = -1
      let (w0, _) = nxName(t, 0)
      if w0 == "when": whenInd = ind
      elif w0 notin ["elif", "else"] and ind <= whenInd: whenInd = -1
      var skipLine = w0 in ["when", "elif", "quote", "asm", "type", "macro", "template", "using", "import", "from",
                            "include", "export", "runnableExamples"] or
                     (w0 in ["elif", "else"] and ind == whenInd) or
                     "defined(" in t or "declared(" in t or "compiles(" in t or "{.emit" in t
      if not skipLine and w0.len > 0:
        for rr in nxLookup(sc, w0):
          if rr.sym.kind in {nxTemplate, nxMacro}: skipLine = true
      if skipLine:
        # (a `when` branch: its body is looked at when it is the one compiled here — `else:` of `when
        # defined(windows)` on Linux —, not when ned left it out or cannot tell: `when declared(x)`, `compiles(…)`)
        let whenBranch = w0 in ["when", "elif"] or (w0 == "else" and ind == whenInd)
        var live = false
        if whenBranch:
          # (every condition of the chain so far decided here: else a branch is read, but not judged)
          if w0 in ["when", "elif"]:
            var cond = t[w0.len .. ^1].strip
            if cond.endsWith(":"): cond.setLen(cond.len - 1)
            var v = if "declared(" in cond or "compiles(" in cond: -1 else: nxWhen(cond)
            if v < 0 and "declared(" notin cond and "compiles(" notin cond: v = nxConstWhen(f, cond)
            whenDecided[ind] = (if w0 == "when": v >= 0 else: whenDecided.getOrDefault(ind, false) and v >= 0)
          if whenDecided.getOrDefault(ind, false) and l + 1 <= lines.high:
            var bl = l + 1
            while bl < lines.high and lines[bl].strip.len == 0: inc bl
            live = true
            for (a, b) in f.inactive:
              if bl >= int(a) and bl <= int(b): live = false
        if not live and (t.endsWith(":") or t.endsWith("=") or t.endsWith(" do") or
                         w0 in ["type", "using", "runnableExamples"]):
          skipInd = ind
        continue
      if l < lo or l > hi: continue
      for (s, e) in ids:
        let w = raw[s ..< e]
        let nw = nxNorm(w)
        if w.len < 4 or w in NxKeywords or count[nw] > 1 or nw in known: continue
        if l == cur[0] and cur[1] >= s and cur[1] <= e: continue            # (being typed)
        if s > 0 and raw[s - 1] == '`': continue
        if s > 0 and raw[s - 1] == '.':
          # a method call or a field (x.toLwer()): misspelled when nothing in scope has the name — not after a
          # module's name (os.name), not in a generic routine (its T's procs are bound when it is instantiated)
          if dotOps or r.generics.len > 0 or (s > 1 and raw[s - 2] == '.'): continue
          let recv = nxReceiver(raw, s - 1)
          if recv.len == 0 or recv in sc.modules or nxNorm(recv) == nxNorm(f.module) or
             (recv.len > 0 and recv[0] in {'A'..'Z'} and nxLookup(sc, recv).len == 0): continue
        var k = e
        while k < raw.len and raw[k] == ' ': inc k
        if k < raw.len and (raw[k] == ':' or (raw[k] == '=' and (k + 1 >= raw.len or raw[k + 1] != '='))): continue
        if nxLookup(sc, w).len > 0 or w in sc.modules or nw == nxNorm(f.module): continue
        # inside the arguments of a template or macro call: it may name what the call declares
        var inTpl = false
        var d = 0
        var q = s - 1
        while q >= 0:
          if raw[q] in {')', ']'}: inc d
          elif raw[q] in {'(', '['}:
            if d == 0:
              var a2 = q
              while a2 > 0 and nxIsIdent(raw[a2 - 1]): dec a2
              for rr in nxLookup(sc, raw[a2 ..< q]):
                if rr.sym.kind in {nxTemplate, nxMacro}: inTpl = true
              if inTpl: break
            else: dec d
          dec q
        if inTpl: continue
        # the name meant: one or two letters away, among the locals and what the module sees
        let maxD = if nw.len <= 5: 1 else: 2
        var best = ""
        var bestD = 99
        var bestShown = ""
        for cand, asWritten in known:
          if cand.len > 2 and abs(cand.len - nw.len) <= maxD:
            let dd = nxTypoDist(cand.toLowerAscii, nw.toLowerAscii)
            if dd <= maxD and dd < bestD:
              bestD = dd
              best = cand
              bestShown = asWritten
        if bestD > 1:
          var names: HashSet[string]
          for r in sc.refs: names.incl nxNorm(r.file.syms[r.idx].name)
          for cand in names:
            if cand.len > 2 and abs(cand.len - nw.len) <= maxD and cand[0].toLowerAscii == nw[0].toLowerAscii:
              let dd = nxTypoDist(cand.toLowerAscii, nw.toLowerAscii)
              if dd <= maxD and dd < bestD:
                bestD = dd
                best = cand
                bestShown = ""
        if best.len == 0: continue
        # a name the modules it sees write somewhere (declared in a branch for another platform): not sure
        if nxTypoWrittenIn(sc, nw): continue
        # (as written where it is declared)
        var shown = if bestShown.len > 0 and nxNorm(bestShown) == best: bestShown else: best
        if shown == best:
          for s2 in nxLookup(sc, best):
            shown = s2.sym.name
            break
        result.add (l, s, w, shown)

proc nxTypoMsg*(line: string, col: int, w, meant: string): string =
  ## the compiler's words for a misspelled name: a call after a dot is an undeclared routine, a name after a dot
  ## an undeclared field, else an undeclared identifier — then the name meant, as its --spellSuggest says it
  var k = col + w.len
  while k < line.len and line[k] == ' ': inc k
  let dot = col > 0 and line[col - 1] == '.'
  let head = if dot and k < line.len and line[k] == '(': "attempting to call undeclared routine: '" & w & "'"
             elif dot: "undeclared field: '" & w & "'"
             else: "undeclared identifier: '" & w & "'"
  head & "\ncandidates (edit distance, scope distance); see '--spellSuggest': \n (1, 0): '" & meant & "'"
