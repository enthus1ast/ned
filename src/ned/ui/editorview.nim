proc mbDiags(b: Buffer): seq[Diag] =
  ## a multibuffer's lines show the problems of the files they come from
  let secs = multiBufs.getOrDefault(b.id)
  if secs.len == 0: return
  var k = -1
  var base = 0
  var byPath: Table[string, seq[Diag]]
  for l, s in b.lines:
    if k + 1 < secs.len and s == mbHeaderOf(b.lang, secs[k + 1]):
      inc k
      base = l + 1
      if secs[k].path notin byPath: byPath[secs[k].path] = diagsFor(secs[k].path)
      continue
    if k < 0: continue
    let fl = secs[k].start + (l - base)
    for d in byPath[secs[k].path]:
      if d.line == fl:
        var x = d
        x.line = l
        if d.eline != d.line: x.ecol = -1
        x.eline = l
        result.add x

proc graphLineColors(s: string): seq[Rgb] =
  ## a branch-graph line: each lane its colour, the commit's hash, its branches and tags, the author dim
  result = newSeq[Rgb](s.len)
  for i in 0 ..< s.len: result[i] = NoColor
  let lanes = [theme.syn[tkKeyword], theme.syn[tkFunc], theme.syn[tkString], theme.syn[tkNumber], theme.syn[tkType],
               theme.syn[tkProperty], theme.syn[tkPreproc]]
  var i = 0
  while i < s.len and s[i] in {'*', '|', '/', '\\', '_', ' ', '-', '.'}:
    if s[i] != ' ': result[i] = (if s[i] == '*': theme.accent else: lanes[(i div 2) mod lanes.len])
    inc i
  var e = i
  while e < s.len and s[e] in HexDigits: inc e
  if e - i < 7: return
  for k in i ..< e: result[k] = theme.syn[tkNumber]
  if e + 1 < s.len and s[e] == ' ' and s[e + 1] == '(':
    let c = s.find(')', e)
    if c > e:
      for k in e + 1 .. c: result[k] = theme.warn
  let dot = s.rfind(" · ")
  if dot > e:
    for k in dot ..< s.len: result[k] = theme.dim

func graphHashAt(s: string): string =
  var i = 0
  while i < s.len and s[i] in {'*', '|', '/', '\\', '_', ' ', '-', '.'}: inc i
  var e = i
  while e < s.len and s[e] in HexDigits: inc e
  if e - i >= 7: s[i ..< e] else: ""

var
  mergeViews: HashSet[int]             # buffers shown in the 3-pane merge editor (ours | theirs over the result)
  mergeInner = false                   # drawing its result pane

proc drawMergeView(b: Buffer, x0, y0, w, h: int, active: bool)

# ── editor.fontLigatures ──

const
  LigOpChars = {'-', '>', '<', '=', '!', ':', '|', '&', '+', '*', '/', '%', '^', '~', '?', '.', '@', '$'}
  LigSyms = [("->", [0x2500'u32, 0x2192]), ("=>", [0x2550'u32, 0x21D2]), ("!=", [0x2260'u32, 32]),
             ("<=", [0x2264'u32, 32]), (">=", [0x2265'u32, 32]), (":=", [0x2254'u32, 32])]
    ## what `symbols` draws, cell by cell: arrows as long arrows over both cells (─→ ═⇒), the others with a blank

proc ligatureRuns(s: string, toks: seq[TokKind]): seq[(int, int)] =
  ## the operators of a line of code — runs of two or more operator characters, not in strings, characters or
  ## comments: (start, end)
  var i = 0
  while i < s.len:
    if s[i] in LigOpChars and i < toks.len and toks[i] in {tkOperator, tkPunct, tkText}:
      var e = i + 1
      while e < s.len and s[e] in LigOpChars and e < toks.len and toks[e] in {tkOperator, tkPunct, tkText}: inc e
      if e - i >= 2: result.add (i, e)
      i = e
    else: inc i

func ligatureSymbol(op, langId: string): array[2, uint32] =
  ## the two cells `symbols` draws for an operator (only a whole one: not the >= of >>=), [0, 0] for none
  for (k, v) in LigSyms:
    if op == k: return v
  if op == "<-" and langId == "go": return [0x2190'u32, 0x2500]       # (a channel; in C, a<-b is a < -b)

proc drawEditor(b: Buffer, x0, y0, w, h: int, active: bool) =
  if b.id in mergeViews and not mergeInner and h >= 14 and w >= 40:
    drawMergeView(b, x0, y0, w, h, active)
    return
  let tabW0 = tabW
  let wrap0 = cfgWrap
  tabW = b.tabOf                       # each pane with its own file's tab width
  cfgWrap = wrapFor(b)                 # … and soft wrap (off in large-file mode)
  defer:
    tabW = tabW0
    cfgWrap = wrap0
  if b.id in diffViews:
    editorRect = (x0, y0, w, h)
    fillRect(x0, y0, w, h, theme.fg, theme.bg)
    drawDiffView(b, x0, y0, w, h)
    return
  if b.hex != nil:
    drawHexView(b, x0, y0, w, h, active)
    return
  if b.mdSrc != 0:
    editorRect = (x0, y0, w, h)
    fillRect(x0, y0, w, h, theme.fg, theme.bg)
    drawMdPreview(b, x0, y0, w, h)
    return
  let sem = semMapFor(b)
  let lsem = lspSemFor(b)
  let isMb = b.id in multiBufs
  var mbRows: seq[(int, int)]          # a multibuffer: (line, screen row) of the lines drawn
  # names the compiler says are unused: faded, like desktop editors do
  var unusedAt: Table[int, seq[(int, string)]]
  if b.path.len > 0 and b.lang.mode == lmNim:
    for (l, c, n) in unusedHints.getOrDefault(b.path):
      if n.len > 0: unusedAt.mgetOrPut(l, @[]).add (c, n)
    for d in diagsFor(b.path):
      if (d.sev >= 3 and "declared but not used" in d.msg) or "imported and not used" in d.msg:
        let n = quotedNameOf(d.msg)
        if n.len > 0: unusedAt.mgetOrPut(d.line, @[]).add (d.col, n)
  let inactive = if cfgDimInactive and b.id notin diffViews and b.id notin multiBufs: inactiveRanges(b) else: @[]
  let conflicts = if b.path.len > 0 or b.title.len == 0: b.conflictsOf() else: @[]
  let bpLines = if b.path.len > 0: breakpoints.getOrDefault(b.path) else: initHashSet[int]()
  let spellOnHere = b.spellOn() and b.id notin diffViews and b.id notin multiBufs
  let hasConflicts = conflicts.len > 0
  let numW = if cfgLineNums == 0 or (zenMode and cfgZenHideNums): 0
             else: max(3, len($(b.lines.len + (if b.viewer != nil: b.viewer.base else: 0))))
  let gw = 2 + numW + (if numW > 0: 1 else: 0)
  gutterW = gw
  textW = max(4, w - gw - 1)
  textH = max(1, h)
  editorRect = (x0, y0, w, h)
  fillRect(x0, y0, w, h, theme.fg, theme.bg)
  if b.isWelcome():
    drawWelcome(x0, y0, w, h)
    return
  b.topLine = clamp(b.topLine, 0, b.lines.high)
  if b.folds.len > 0:
    b.revealCursor()
    for (fs, fe) in b.folds:
      if b.topLine > fs and b.topLine <= fe:
        b.topLine = fs
        b.topSub = 0
  inlayShown.clear()
  let showInlays = (cfgInlayHints or b.lang.mode == lmCsv) and b.inlays.len > 0
  if not cfgWrap: b.topSub = 0
  else: b.topSub = clamp(b.topSub, 0, b.segCount(b.topLine) - 1)
  let ph = b.primary.head
  if ph != b.lastHead or b.changeId != b.lastChange:
    if zenMode and cfgZenTypewriter:
      let sub = if cfgWrap: subRowOf(b.lineSegs(ph.line), ph.col) else: 0
      (b.topLine, b.topSub) = b.stepBack(ph.line, sub, h div 2)
    else: b.ensureVisible()
    b.lastHead = ph
    b.lastChange = b.changeId
  # zen focus: the block (or paragraph) around the cursor stays bright, the rest is dimmed
  var focA = -1
  var focB = high(int)
  if zenMode and cfgZenDim:
    # code: the top-level declaration around the cursor; prose: the paragraph
    var hd = -1
    if b.lang.mode notin {lmMarkdown, lmPlain}:
      for k in countdown(ph.line, max(0, ph.line - 5000)):
        let t = b.lines[k]
        if t.len > 0 and t[0] notin {' ', '\t'}:
          let (ok, e) = b.foldRange(k)
          if ok and e >= ph.line: hd = k
          break
    if hd >= 0:
      focA = hd
      focB = b.foldRange(hd)[1]
    else:
      focA = ph.line
      while focA > 0 and not isBlank(b.lines[focA - 1]): dec focA
      focB = ph.line
      while focB < b.lines.high and not isBlank(b.lines[focB + 1]): inc focB
  let primSel = b.primary.hasSel
  let ds = if isMb: b.mbDiags() else: diagsFor(b.path)
  var findQ = ""
  var fCase = true
  var fWord = false
  var isFind = false
  if promptKind in {pFind, pReplaceFind, pVimSearch} or replaceActive:
    findQ = if replaceActive: replaceQuery else: promptText
    fCase = findCase
    fWord = findWord
    isFind = true
  elif primSel:
    let (a, e) = b.primary.range
    if a.line == e.line and e.col - a.col <= 200: findQ = b.getText(a, e)
  var useDocHl = false
  if findQ.len == 0 and not isFind and not primSel and cfgHighlightOcc and docHl.bufId == b.id and docHl.pos == ph and
     docHl.change == b.changeId and docHl.ranges.len > 0:
    useDocHl = true                     # the language server knows which names are the same symbol
  elif cfgHighlightOcc and not isFind and not primSel and not b.largeOn:
    let wd = b.wordAt(ph)
    if wd.len >= 2 and not wd[0].isDigit:
      findQ = wd
      fWord = true
  let (bm, ba, bb) = b.matchBracketKept(ph)
  let vimVis = cfgVim and vimMode in {vmVisual, vmVLine}
  let unit = b.indentW()
  # the active indent guide: the one of the block the cursor is in, a little brighter (like VS Code)
  var agCol, agA, agB = -1
  if cfgGuides and unit > 0 and b.lines.len < 200_000 and ph.line < b.lines.len:
    proc indOf(l: int): int = visColOf(b.lines[l], leadingWs(b.lines[l]).len)
    var ci = -1
    if not isBlank(b.lines[ph.line]): ci = indOf(ph.line)
    else:
      var up = ph.line
      while up > 0 and isBlank(b.lines[up]) and ph.line - up < 200: dec up
      var dn = ph.line
      while dn < b.lines.high and isBlank(b.lines[dn]) and dn - ph.line < 200: inc dn
      if not isBlank(b.lines[up]) and not isBlank(b.lines[dn]): ci = min(indOf(up), indOf(dn))
    if ci >= unit:
      agCol = ((ci - 1) div unit) * unit
      agA = ph.line
      while agA > 0 and ph.line - agA < 3000 and (isBlank(b.lines[agA - 1]) or indOf(agA - 1) > agCol): dec agA
      agB = ph.line
      while agB < b.lines.high and agB - ph.line < 3000 and (isBlank(b.lines[agB + 1]) or indOf(agB + 1) > agCol): inc agB
      while agB > agA and isBlank(b.lines[agB]): dec agB
  let guideOn = blend(theme.guide, theme.fg, 0.32)
  # editor.fontLigatures: operators in code kept in one colour (font), or drawn as symbols — but not on a line with a
  # cursor, where the text itself is shown (symbols)
  let ligOn = cfgLigatures in ["font", "symbols"] and b.lang != nil and
              b.lang.mode in {lmGeneric, lmNim, lmC, lmJs, lmRust, lmPython} and b.lang.id notin ["csv", "tsv"] and
              b.id notin graphBufs and not isMb
  var curLines: HashSet[int]
  if ligOn and cfgLigatures == "symbols":
    for c in b.cursors: curLines.incl c.head.line
  var toks: seq[TokKind]
  var tagCols: seq[Rgb]
  for ti in 0 ..< todoTags.len: tagCols.add todoColor(ti, theme.bg)
  var (st, depth) = b.stateAt(b.topLine)
  var line = b.topLine
  var sub0 = b.topSub
  var row = 0
  var prevIndent = 0
  let tx0 = x0 + gw
  let limX = x0 + w
  # rulers (editor.rulers): a thin line at fixed columns, only in empty cells so it never hides text;
  # what goes past the last one is tinted
  let rulersOn = rulersSet() and not rulersHidden and not zenMode and b.id notin graphBufs
  let rcols = rulerColumns(b)        # (.editorconfig max_line_length: the project's limit; "lineLength": the formatter's)
  let rulerX0 = tx0 - (if cfgWrap: 0 else: b.leftCol)          # where display column 0 is on the screen
  let tintFrom = if rulersOn and cfgRulerTint: rcols[^1] else: -1
  # the last profile's numbers for this file (none once it has changed)
  let (profLn, profDl) = profFor(b)
  # debugging: where the stopped function starts, and the variables' values (inline values)
  var ivA = -1
  var ivMap: Table[string, string]
  if dbgOn and cfgInlineValues and dbgAt[0] == b.path and dbgAt[1] >= 0 and dbgAt[1] < b.lines.len and dbgVars.len > 0:
    for (n, t, v) in dbgVars:
      # (a bare address — an object passed by pointer — says nothing at the end of a line)
      let addrOnly = v.startsWith("0x") and v.len > 2 and v[2 .. ^1].allCharsInSet(HexDigits)
      if v.len > 0 and not addrOnly: ivMap[(if dbgDap: n else: nimVarName(n))] = v.replace("\n", " ")
    ivA = dbgAt[1]
    let stopInd = leadingWs(b.lines[dbgAt[1]]).len
    var minInd = stopInd
    while ivA > 0 and dbgAt[1] - ivA < 80:
      let u = b.lines[ivA - 1]
      if not isBlank(u):
        let ui = leadingWs(u).len
        if ui < minInd:
          minInd = ui
          let t = u.strip
          if t.startsWith("proc ") or t.startsWith("func ") or t.startsWith("method ") or t.startsWith("iterator ") or
             t.startsWith("def ") or t.startsWith("async def ") or t.startsWith("fn ") or t.startsWith("pub fn ") or
             t.startsWith("func(") or (b.lang.id in ["c", "cpp", "go"] and t.endsWith("{") and ui == 0):
            break
          if ui == 0: break
      dec ivA
  template rulerRow(yy: int) =
    for r in rcols:
      let rx = rulerX0 + r
      if rx >= tx0 and rx < tx0 + textW:
        let gi = yy * scrW + rx
        if grid[gi].ch == 32:
          grid[gi].ch = 0x258F                                   # ▏ on the cell's left edge: the column boundary
          grid[gi].fg = theme.ruler
  while row < h and line < b.lines.len:
    let s {.cursor.} = b.lines[line]      # (the line itself, not a copy: nothing here changes the text)
    var endSt = st
    var toksUnfaded: seq[TokKind]
    if s.len > 20000:
      toks.setLen(0)                      # (a very long line is plain text: no colours to fill in for each byte)
    else:
      endSt = lexLine(b.lang, s, st, toks)
      # code of another language in this line (C in an emit, HTML in a string): the Nim name colours stay out
      let foreign = lexForeign
      let lexed = if foreign.len > 0: toks else: @[]
      if sem != nil: applySem(s, toks, sem, line)
      if b.lang.mode == lmNim and s.len < 4000 and '"' in s and ("header" in s or "importc" in s or "dynlib" in s):
        pragmaStrColors(s, toks)
      if lsem.len > 0 and line in lsem:
        for (c, n, k) in lsem[line]:
          for q in c ..< min(c + n, toks.len):
            if toks[q] in {tkText, tkType, tkVariable}: toks[q] = k
      if unusedAt.len > 0 and line in unusedAt:
        toksUnfaded = toks                 # (a type hint after a faded name is still drawn)
        for (c, n) in unusedAt[line]:
          # the name on the line (the column may point at the statement): at or after it, as a whole word
          let short = n.split('.')[^1]
          var at = -1
          var k = s.find(short, max(0, min(c, s.len)))
          if k < 0: k = s.find(short)
          while k >= 0:
            if (k == 0 or s[k - 1] notin IdentChars) and (k + short.len >= s.len or s[k + short.len] notin IdentChars):
              at = k
              break
            k = s.find(short, k + 1)
          if at >= 0:
            for q in at ..< min(at + short.len, toks.len): toks[q] = tkComment
      for (a, e) in foreign:
        for q in a ..< min(e, toks.len): toks[q] = lexed[q]
      if inactive.len > 0 and lineInactive(inactive, line):
        # left out of the compile here (a false `when` branch, #if 0): dimmed
        if toksUnfaded.len == 0: toksUnfaded = toks
        for q in 0 ..< toks.len:
          if toks[q] notin {tkComment, tkDoc}: toks[q] = tkComment
    let th = if cfgTodoHl and s.len <= 20000 and todoWordIn(s): todoHits(s, toks) else: @[]
    let gcol = if b.id in graphBufs: graphLineColors(s) else: @[]
    var bdep: seq[int16]
    var rbCol: seq[Rgb]
    if cfgRainbow and s.len <= 20000:
      bdep = rbDepths(s, toks, depth)
      rbCol = b.rbColours(line, s, toks, bdep)
    if s.len <= 20000: depth = max(0, depth + bracketDelta(s, toks))
    if line == b.hlValid and line + 1 < b.hlStart.len:
      if b.hlDepth.len != b.lines.len + 1: b.hlDepth.setLen(b.lines.len + 1)
      b.hlStart[line + 1] = endSt
      b.hlDepth[line + 1] = int16(min(depth, 30000))
      b.hlValid = line + 1
    st = endSt
    let segs = b.lineSegs(line)
    var selR: seq[(int, int)]
    for c in b.cursors:
      if c.hasSel or vimVis:
        var (a, e) = c.range
        if vimVis:
          if vimMode == vmVLine:
            a.col = 0
            e.col = high(int) div 2
          else: e.col += 1
        if a.line <= line and line <= e.line:
          selR.add ((if a.line == line: a.col else: 0), (if e.line == line: e.col else: s.len + 1))
    var matchR: seq[(int, int)]
    if findQ.len > 0 and s.len <= 20000:
      matchR = findSpans(s, findQ, fCase, fWord, isFind and findRegex)
    elif useDocHl:
      for (ra, re) in docHl.ranges:
        if ra.line <= line and line <= re.line:
          matchR.add ((if ra.line == line: ra.col else: 0), (if re.line == line: re.col else: s.len))
    var diagR: seq[(int, int, int)]
    var worst = 0
    var lineDiag = -1
    for di, d in ds:
      if d.line <= line and line <= max(d.line, d.eline):
        var a = if d.line == line: d.col else: 0
        var e = if d.eline == line and d.ecol >= 0 and d.eline >= d.line: d.ecol else: s.len
        if d.ecol < 0 and d.line == line:
          let (_, we) = b.wordRangeAt(Pos(line: line, col: min(a, s.len)))
          e = max(we.col, a + 1)
        if a >= s.len and s.len > 0: a = s.len - 1
        if e <= a: e = a + 1
        diagR.add (a, min(e, max(s.len, 1)), d.sev)
        if d.sev <= 3 and (worst == 0 or d.sev < worst):
          worst = d.sev
          if d.line == line: lineDiag = di
    if spellOnHere and s.len <= 4000:
      for (a, e) in b.spellErrors(s, toks): diagR.add (a, e, 8)        # misspelled: underlined, colour kept
    if b.path.len > 0 and b.id notin diffViews and s.len <= 20000 and ("://" in s or b.id in docLinks):
      for (a, e) in linkRangesOn(b, line): diagR.add (a, e, 9)        # a link: underlined (F12 or Ctrl+click opens it)
    let isCurLine = line == ph.line and not primSel
    var rowBg = if isCurLine and active and cfgLineHl: theme.curLine else: theme.bg
    if flashBuf == b.id and line >= flashA and line <= flashB and msSince(flashAt) < 1800:
      rowBg = blend(theme.bg, theme.accent, 0.16)       # code just put in (AI chat › Insert)
    if dbgOn and line == dbgAt[1] and b.path == dbgAt[0]: rowBg = blend(theme.bg, theme.warn, 0.20)
    if landBuf == b.id and line == landLine:
      let t = float(msSince(landAt)) / float(JumpHlMs)
      if t < 1.0: rowBg = blend(rowBg, theme.accent, 0.32 * (1.0 - t) * (1.0 - t))     # (a jump landed here)
    var conflictStart = -1
    if hasConflicts:
      let ci = b.conflictAt(line)
      if ci >= 0:
        let c = conflicts[ci]
        let oursEnd = if c.base >= 0: c.base else: c.mid
        if line in [c.start, c.base, c.mid, c.stop]: rowBg = blend(theme.bg, theme.fg, 0.12)
        elif line < oursEnd: rowBg = blend(theme.bg, theme.gitAdd, 0.13)        # ours
        elif line > c.mid: rowBg = blend(theme.bg, theme.info, 0.13)            # theirs
        if line == c.start: conflictStart = ci
    # inlay hints: drawn inline when the whole line (plus hints) fits on one row
    var hints: seq[(int, string)]
    let sw = if cfgSwatches and s.len <= 4000 and b.lang.mode != lmDiff and b.id notin graphBufs:
               colourSwatches(b.lang, s, toks) else: @[]
    var swBg: seq[(int, int, Rgb)]       # swatches with no room on the row: the colour behind the text instead
    var overlays: seq[(int, string)]     # type hints over the spaces before a lined-up `=`
    if (showInlays and line in b.inlays) or sw.len > 0 or (nesSug.buf == b.id and nesSug.at.line == line) or
       (cfgCSigHints and b.id in cSigHints and line in cSigHints[b.id]) or
       (cfgShowCopies and b.id in copyMarks and line in copyMarks[b.id]) or
       (showInlays and b.lang.mode == lmNim and s.len < 400 and '=' in s):     # (a run lined up on `=` with hints)
      hints = b.lineDecor(line, (if toksUnfaded.len > 0: toksUnfaded else: toks), sw)
      overlays = decorOverlay
      var hw = 0
      for (_, lb) in hints: hw += strWidth(lb)
      if segs.len > 1 or (cfgWrap and visColOf(s, s.len) + hw > textW):
        # type hints wrap with the line (its rows have room for them); colour swatches do not: the colour goes
        # behind the text instead
        var keep: seq[(int, string)]
        for h in hints:
          if h[1] != SwatchMark: keep.add h
        hints = keep
        swBg = sw
      if hints.len > 0: inlayShown.incl line
    var ligRuns: seq[(int, int)]
    var ligCh: seq[uint32]
    var lr = 0
    var ligFrom = -1
    var ligFg: Rgb
    var ligAttr: set[Attr]
    if ligOn and s.len <= 4000:
      ligRuns = ligatureRuns(s, toks)
      if cfgLigatures == "symbols" and ligRuns.len > 0 and line notin curLines:
        for (a, e) in ligRuns:
          if e - a != 2: continue
          let sym = ligatureSymbol(s[a ..< e], b.lang.id)
          if sym[0] != 0:
            if ligCh.len == 0: ligCh = newSeq[uint32](s.len)
            ligCh[a] = sym[0]
            ligCh[a + 1] = sym[1]
    var hk = 0
    var shift = 0
    # indentation guides
    var guideW = 0
    if cfgGuides and b.lang.mode != lmDiff:
      if isBlank(s):
        var nextInd = 0
        for l2 in line + 1 .. min(b.lines.high, line + 60):
          if not isBlank(b.lines[l2]):
            nextInd = visColOf(b.lines[l2], leadingWs(b.lines[l2]).len)
            break
        guideW = min(prevIndent, nextInd)
      else:
        guideW = visColOf(s, leadingWs(s).len)
        prevIndent = guideW
    let plugHl = if plugDecor.len > 0: b.plugHighlights(line) else: @[]
    for si in sub0 ..< segs.len:
      if row >= h: break
      let y = y0 + row
      fillRect(x0, y, w, 1, theme.fg, rowBg)
      if si == 0 and isMb: mbRows.add (line, y)
      if si == 0:
        if dbgOn and line == dbgAt[1] and b.path == dbgAt[0]:
          setCell(x0, y, Cell(ch: 0x25B6, fg: theme.warn, bg: rowBg))                # ▶ stopped here
        elif bpLines.len > 0 and line in bpLines:
          let cond = bpCond.len > 0 and (b.path & ":" & $line) in bpCond
          let logp = bpLog.len > 0 and (b.path & ":" & $line) in bpLog
          if logp:
            setCell(x0, y, Cell(ch: (if cfgAccessible: uint32(ord('L')) else: 0x25C7'u32), fg: theme.info, bg: rowBg))  # ◇ logpoint
          else:
            setCell(x0, y, Cell(ch: (if cfgAccessible: (if cond: uint32(ord('C')) else: uint32(ord('B')))
                                     elif cond: 0x25C6'u32 else: 0x25CF'u32), fg: theme.err, bg: rowBg))  # ● breakpoint · ◆ with a condition
        elif worst > 0:
          setCell(x0, y, Cell(ch: (if cfgAccessible: uint32(ord("EWIH"[clamp(worst - 1, 0, 3)])) else: 0x25CF'u32),
                              fg: sevColor(worst), bg: rowBg))                # letters, not only colours
        elif b.marks.len > 0 and line in b.marks:
          setCell(x0, y, Cell(ch: (if cfgAccessible: uint32(ord('M')) else: 0x25C6'u32), fg: theme.accent, bg: rowBg))  # ◆ bookmark
        elif plugDecor.len > 0 and (let (sg, sc) = b.plugSignAt(line); sg.len > 0):
          discard putStr(x0, y, sg, sc, rowBg, {aBold}, x0 + 1)                  # a plugin's sign
        elif cfgCodeLens and b.path.len > 0:
          let (lens, _) = b.lensAt(line)
          if lens.len > 0:
            discard putStr(x0, y, lens, (if lens == "✗": theme.err else: theme.gitAdd), rowBg, {aBold})
        if cfgFolding and numW > 0:
          if b.foldAt(line) >= 0:
            discard putStr(x0 + gw - 1, y, ic("chevR"), theme.accent, rowBg, {aBold})
          elif line == ph.line or hov(x0, y, gw):
            let (fok, _) = b.foldRange(line)
            if fok: discard putStr(x0 + gw - 1, y, ic("chevD"), theme.dim, rowBg)
        if numW > 0:
          let n = if cfgLineNums == 2 and line != ph.line: abs(line - ph.line)
                  else: line + 1 + (if b.viewer != nil: b.viewer.base else: 0)
          let cov = if covLines.len > 0 and b.path in covLines: covLines[b.path].getOrDefault(line, false) else: false
          let covKnown = covLines.len > 0 and b.path in covLines and line in covLines[b.path]
          discard putStr(x0 + 1, y, align($n, numW), (if covKnown: (if cov: theme.gitAdd else: theme.err)
                                                         elif line == ph.line: theme.gutterCur else: theme.gutter),
                         rowBg, (if line == ph.line: {aBold} else: {}))
          if covKnown and cfgAccessible:                     # ran / never ran: a sign, not only the colour
            setCell(x0 + 1, y, Cell(ch: uint32(ord(if cov: '+' else: '-')), fg: (if cov: theme.gitAdd else: theme.err), bg: rowBg))
        if cfgGitGutter and (not zenMode or cfgZenGit) and line < b.git.len:     # (zen: zen.gitChanges)
          let gx = x0 + 1 + numW
          case b.git[line]
          of 1: setCell(gx, y, Cell(ch: (if cfgAccessible: uint32(ord('+')) else: 0x258E'u32), fg: theme.gitAdd, bg: rowBg))
          of 2: setCell(gx, y, Cell(ch: (if cfgAccessible: uint32(ord('~')) else: 0x258E'u32), fg: theme.gitMod, bg: rowBg))
          of 3: setCell(gx, y, Cell(ch: (if cfgAccessible: uint32(ord('_')) else: 0x2581'u32), fg: theme.gitDel, bg: rowBg))
          else: discard
      elif numW > 0:
        discard putStr(x0 + numW, y, "↪", theme.guide, rowBg)
      let segStart = segs[si]
      let segEnd = if si + 1 < segs.len: segs[si + 1] else: s.len
      let rowOff = if si > 0: contIndent(s, textW) else: 0
      var vc = 0
      var i = 0
      var baseVc = 0
      if cfgWrap:
        vc = visColOf(s, segStart)
        i = segStart
        baseVc = vc
        shift = 0                                    # (a row of its own: the hints of the rows above are not here)
        while hk < hints.len and hints[hk][0] < segStart: inc hk
      else:
        baseVc = b.leftCol
        if b.leftCol > 0 and s.len >= VcLongLine:
          (i, vc) = b.vcMarkBefore(line, b.leftCol)      # (scrolled far right on a long line: from the nearest mark)
        while i < s.len:
          if s[i] in {' ' .. '~'}:
            if vc + 1 > b.leftCol: break
            inc vc
            inc i
            continue
          let (cw, n) = charWidthAt(s, i, vc)
          if vc + cw > b.leftCol: break
          vc += cw
          i += n
      # guides on blank stretches / leading whitespace
      if cfgGuides and si == 0 and unit > 0:
        var g = 0
        let sVis = if guideW > 0: visColOf(s, min(s.len, guideW + 1)) else: 0
        while g < guideW:
          let gx = tx0 + g - baseVc
          if gx >= tx0 and gx < limX and ((g >= sVis and sVis <= guideW) or (g < s.len and s[g] in {' ', '\t'})):
            setCell(gx, y, Cell(ch: 0x2502, fg: (if g == agCol and line >= agA and line <= agB: guideOn else: theme.guide),
                                 bg: rowBg))
          g += unit
      while i < segEnd:
        while hk < hints.len and hints[hk][0] <= i:
          let hx = tx0 + vc - baseVc + rowOff + shift
          if hx >= tx0:
            if hints[hk][1] == SwatchMark: drawSwatch(b, line, hints[hk][0], hx, y, limX, sw, rowBg)
            elif hints[hk][1].strip.len == 0: discard putStr(hx, y, hints[hk][1], theme.fg, rowBg, {}, limX)  # (a CSV column's padding)
            else: discard putStr(hx, y, hints[hk][1], theme.inlay, blend(rowBg, theme.fg, 0.05), {aItalic}, limX)
          shift += strWidth(hints[hk][1])
          inc hk
        let (cw, n) = charWidthAt(s, i, vc)
        let x = tx0 + vc - baseVc + rowOff + shift
        if x >= limX: break
        let tk = if i < toks.len: toks[i] else: tkText
        var fg = theme.syn[tk]
        var at: set[Attr] = {}
        if tk == tkPunct and i < rbCol.len and s[i] in {'(', ')', '[', ']', '{', '}'}:
          fg = rbCol[i]
        if tk in {tkComment, tkDoc}: at.incl aItalic
        elif tk in {tkHeading, tkBold, tkGlobal, tkGlobalVar} or (tk in {tkKeyword, tkUnsafe} and theme.boldKw): at.incl aBold
        elif tk == tkDeprecated: at.incl aStrike
        var bg = rowBg
        if tintFrom >= 0 and vc >= tintFrom: bg = blend(rowBg, theme.warn, 0.11)      # past the last ruler
        for (sc, sn, cc) in swBg:
          if i >= sc and i < sc + sn:
            bg = cc
            fg = if luminance(cc) > 0.35: Rgb(0x111111) else: Rgb(0xF5F5F5)
        for hh in th:
          # a tag comment: the tag as a coloured badge, its (name) and the message tinted
          if i >= hh.a and i < hh.e:
            fg = tagCols[hh.tag]
            at.excl aItalic
            at.incl aBold
            bg = blend(rowBg, tagCols[hh.tag], 0.16)
          elif hh.wa >= 0 and i >= hh.wa and i < hh.we:
            fg = blend(tagCols[hh.tag], theme.syn[tkComment], 0.45)
          elif i >= max(hh.e, hh.we) and tk in {tkComment, tkDoc}:
            fg = blend(theme.syn[tkComment], tagCols[hh.tag], 0.5)
        if i < gcol.len and gcol[i] != NoColor:
          fg = gcol[i]
          if s[i] == '*': at.incl aBold
        for (a, e, hc) in plugHl:
          if i >= a and i < e: bg = blend(rowBg, hc, 0.28)                   # a plugin's highlight
        for (a, e) in matchR:
          if i >= a and i < e:
            bg = if isFind: theme.match else: theme.wordHl
        if bm and ((line == ba.line and i == ba.col) or (line == bb.line and i == bb.col)):
          bg = theme.bracket
          at.incl aBold
        for (a, e) in selR:
          if i >= a and i < e: bg = theme.sel
        for (a, e, sv) in diagR:
          if i >= a and i < e and sv <= 2:
            at.incl aUnder
            # a curly underline in the problem's colour where the terminal draws one (the text keeps its colour);
            # else a straight one, and a plain name takes the colour
            if ulStyled: at.incl {aCurl, (if sv == 1: aUcErr else: aUcWarn)}
            elif tk == tkText: fg = sevColor(sv)
          elif i >= a and i < e and sv == 8:
            at.incl aUnder
            if ulStyled: at.incl {aCurl, aUcInfo}             # (misspelled)
          elif i >= a and i < e and sv == 9:
            at.incl aUnder
        if ligRuns.len > 0:
          # an operator: one colour and style over all of it (from its first cell drawn)
          while lr < ligRuns.len and ligRuns[lr][1] <= i: inc lr
          if lr < ligRuns.len and i >= ligRuns[lr][0]:
            if ligFrom != ligRuns[lr][0] or i == ligRuns[lr][0]:
              ligFrom = ligRuns[lr][0]
              ligFg = fg
              ligAttr = at
            else:
              fg = ligFg
              at = ligAttr
        let c = s[i]
        if c == '\t':
          for k in 0 ..< cw:
            if x + k < limX:
              setCell(x + k, y, Cell(ch: (if k == 0 and cfgShowWs: 0x2192'u32 else: 32'u32), fg: theme.guide, bg: bg))
        elif c == ' ':
          let isGuide = cfgGuides and unit > 0 and vc < guideW and vc mod unit == 0 and si == 0
          let ch = if isGuide: 0x2502'u32 elif cfgShowWs: 0x00B7'u32 else: 32'u32
          setCell(x, y, Cell(ch: ch, fg: (if isGuide and vc == agCol and line >= agA and line <= agB: guideOn
                                          else: theme.guide), bg: bg))
        elif cw > 0 and x >= tx0:
          var (cp, _) = runeAt(s, i)
          if ligCh.len > 0 and i < ligCh.len and ligCh[i] != 0: cp = ligCh[i].int     # (editor.fontLigatures: symbols)
          if cp < 32: cp = 0x2400 + cp
          elif cp == 127: cp = 0x2421
          if x + cw <= limX:
            # (an accent with its letter, a ZWJ emoji: one cell — see cellOf)
            let rn = runeLen(s[i])
            let ch = if n > rn and s[i].uint8 >= 32 and s[i] != '\x7f' and (i >= ligCh.len or ligCh[i] == 0): cellOf(s, i, n)
                     else: cp.uint32
            setCell(x, y, Cell(ch: ch, fg: fg, bg: bg, at: at))
            if cw == 2: setCell(x + 1, y, Cell(ch: 0, fg: fg, bg: bg, at: at))
        vc += cw
        i += n
      if rulersOn: rulerRow(y)
      for (oc, ot) in overlays:
        # a type hint over the spaces before a lined-up `=` (its column: where the spaces start)
        if oc < segStart or oc > segEnd: continue
        var hs = 0
        for (hc, lb) in hints:
          if hc < oc: hs += strWidth(lb)
        let ox = tx0 + visColOf(s, oc) - baseVc + rowOff + hs
        if ox >= tx0: discard putStr(ox, y, ot, theme.inlay, blend(rowBg, theme.fg, 0.05), {aItalic}, limX)
      if segEnd == s.len:
        while hk < hints.len:
          let hx = tx0 + vc - baseVc + rowOff + shift
          if hx >= tx0:
            if hints[hk][1] == SwatchMark: drawSwatch(b, line, hints[hk][0], hx, y, limX, sw, rowBg)
            elif hints[hk][1].strip.len == 0: discard putStr(hx, y, hints[hk][1], theme.fg, rowBg, {}, limX)  # (a CSV column's padding)
            else: discard putStr(hx, y, hints[hk][1], theme.inlay, blend(rowBg, theme.fg, 0.05), {aItalic}, limX)
          shift += strWidth(hints[hk][1])
          inc hk
        let ex = tx0 + vc - baseVc + rowOff + shift
        if b.folds.len > 0:
          let fi = b.foldAt(line)
          if fi >= 0 and ex + 2 < limX:
            let n = b.folds[fi][1] - b.folds[fi][0]
            discard putStr(ex + 1, y, " ⋯ " & $n & " lines ", theme.dim, theme.codeBg, {}, limX)
        for (a, e) in selR:
          if e > s.len and ex < limX and ex >= tx0: setCell(ex, y, Cell(ch: 32, fg: theme.fg, bg: theme.sel))
        if lineDiag >= 0 and (ds[lineDiag].sev <= 2 or line == ph.line) and ex + 3 < limX:
          let dg = ds[lineDiag]
          let txt = "● " & diagText(dg, (if isMb and b.lang.mode == lmNim: "x.nim" else: b.path))
          let nx = putStr(ex + 2, y, txt, sevColor(dg.sev), rowBg, {aItalic, aDim}, limX)
          let hint = fixHint(dg)
          var hx = nx
          if hint.len > 0 and nx + 4 < limX:
            # what Alt+Enter would do — a click does it too
            hx = putStr(nx, y, hint, theme.accent, rowBg, {aItalic}, limX)
          if not isMb:
            let bid = b.id
            let dl = dg.line
            let dc = dg.col
            let fixable = hint.len > 0
            capture bid, dl, dc, fixable:
              region(ex + 2, y, hx - ex - 2, 1, proc() =
                let bb = bufById(bid)
                if bb == nil: return
                bb.setSingle(bb.clampPos(Pos(line: dl, col: dc)))
                if fixable: cmdCodeActions() else: cmdHover(),
                (if fixable: "Fix it (" & fixKey() & ")" else: "The whole message (Alt+H)"))
        elif plugDecor.len > 0 and (let (vt, vc) = b.plugTextAfter(line); vt.len > 0) and ex + 4 < limX:
          discard putStr(ex + 3, y, vt, vc, rowBg, {aItalic}, limX)            # a plugin's text after the line
        elif b.path.len > 0 and (let rn = reviewNoteAt(b.path, line); rn.len > 0) and ex + 6 < limX:
          # a review comment of the branch's pull request (GitHub)
          discard putStr(ex + 3, y, rn, blend(theme.info, theme.inlay, 0.3), rowBg, {aItalic}, limX)
        elif b.lang.mode == lmNim and (let (tnote, tst) = b.testNoteAt(line); tst > 0) and ex + 6 < limX:
          # a test's last result (run on save, or by ▶)
          let tc = case tst
            of 1: theme.gitAdd
            of 2: theme.err
            else: theme.inlay
          discard putStr(ex + 3, y, tnote, tc, rowBg, {aItalic}, limX)
        elif cfgBlame and active and line == ph.line and blameText.len > 0 and ex + 8 < limX and
             blameFor.startsWith(b.path & ":" & $line & ":"):
          discard putStr(ex + 3, y, blameText, theme.inlay, rowBg, {aItalic}, limX)
        elif (profLn.len > 0 or profDl.len > 0) and (line in profLn or line in profDl) and ex + 6 < limX:
          # the profile: this line's share of the time (with what it calls), a proc's on its first line
          let tot = max(profSamples, 1)
          var txt = ""
          var heat = 0.0
          if line in profDl:
            let (sn, tn) = profDl[line]
            heat = tn / tot
            txt = "◷ " & formatFloat(tn * 100 / tot, ffDecimal, 1) & "% of the time · " &
                  formatFloat(sn * 100 / tot, ffDecimal, 1) & "% in itself"
          elif line in profLn:
            let (sn, tn) = profLn[line]
            if tn * 200 >= tot:                       # (from 0.5 %)
              heat = tn / tot
              const bars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
              txt = bars[clamp(int(heat * 8), 0, 7)] & " " & formatFloat(tn * 100 / tot, ffDecimal, 1) & "%" &
                    (if sn * 200 >= tot and sn < tn: " · " & formatFloat(sn * 100 / tot, ffDecimal, 1) & "% on the line itself" else: "")
          if txt.len > 0:
            discard putStr(ex + 3, y, txt, blend(theme.inlay, theme.err, clamp(heat * 1.6, 0.0, 1.0)), rowBg, {aItalic}, limX)
        elif cfgRefCounts and b.lang.mode == lmNim and (let (rl, unused) = b.refLensAt(line); rl.len > 0) and ex + 6 < limX:
          # "3 references" — a click lists them; an export nothing uses in the warning colour
          let rx = ex + 3
          let nx = putStr(rx, y, rl, (if unused: theme.warn else: theme.inlay), rowBg, {aItalic}, limX)
          let bid = b.id
          let ln = line
          capture bid, ln:
            region(rx, y, nx - rx, 1, proc() =
              let bb = bufById(bid)
              if bb != nil: refLensClick(bb, ln), "List them (Find references)")
        elif ivMap.len > 0 and line >= ivA and line <= dbgAt[1] and ex + 6 < limX and s.len <= 2000:
          # stopped in the debugger: the values of the variables this line uses (like VS Code's inline values)
          var shown: seq[string]
          var k = 0
          while k < s.len and shown.len < 5:
            if s[k] in IdentStartChars and (k == 0 or s[k - 1] notin IdentChars):
              var e = k
              while e < s.len and s[e] in IdentChars: inc e
              let w = s[k ..< e]
              if w in ivMap and (k >= toks.len or toks[k] notin {tkComment, tkDoc, tkString}):
                let item = w & " = " & truncTo(ivMap[w], 30)
                if item notin shown: shown.add item
              k = e
            else: inc k
          if shown.len > 0:
            discard putStr(ex + 2, y, shown.join("  "), blend(theme.warn, rowBg, 0.25), rowBg, {aItalic}, limX)
      if jumpCollect and active and b.id == jumpBufId and s.len <= 4000:
        # jump labels: the words this row shows
        var k = segStart
        while k < min(segEnd, s.len):
          if s[k] in IdentChars and (k == 0 or s[k - 1] notin IdentChars):
            var hshift = 0
            for (hc, lb) in hints:
              if hc < k and (not cfgWrap or hc >= segStart): hshift += strWidth(lb)
            let cx = tx0 + b.visColAt(line, k) - baseVc + rowOff + hshift
            if cx >= tx0 and cx + 1 < limX: jumpVis.add (Pos(line: line, col: k), cx, y)
            while k < s.len and s[k] in IdentChars: inc k
          else: inc k
      for ci, c in b.cursors:
        let hp = c.head
        if hp.line != line or hp.col < segStart or hp.col > segEnd: continue
        if hp.col == segEnd and si + 1 < segs.len: continue
        var hshift = 0
        for (hc, lb) in hints:
          if hc < hp.col and (not cfgWrap or hc >= segStart): hshift += strWidth(lb)
        let cx = tx0 + b.visColAt(line, hp.col) - baseVc + rowOff + hshift
        if cx < tx0 or cx >= limX: continue
        if ci == b.prim:
          if active and focus == fEditor:
            edCaretX = cx                   # where the caret is, for popups placed beside it
            edCaretY = y
          if active and focus == fEditor and pickKind == pickNone:
            cursorX = cx
            cursorY = y
            if ghostVisible(b):
              # inline AI suggestion: grey, from the cursor on (Tab accepts, Esc dismisses)
              let gl = ghostText.splitLines()
              var gx = cx
              if gl.len > 0: gx = putStr(cx, y, gl[0].replace("\t", "    "), theme.inlay, rowBg, {aItalic}, limX)
              if gl.len > 1 and gx + 4 < limX:
                discard putStr(gx + 1, y, "⋯+" & $(gl.len - 1), theme.dim, rowBg, {}, limX)
          elif splitOn and not active:
            let idx = y * scrW + cx
            if grid[idx].ch == 0: grid[idx].ch = 32
            grid[idx].bg = blend(theme.cursorSec, theme.bg, 0.45)
        else:
          let idx = y * scrW + cx
          if grid[idx].ch == 0: grid[idx].ch = 32
          grid[idx].bg = theme.cursorSec
          grid[idx].fg = theme.bg
      if focA >= 0 and (line < focA or line > focB):
        for xx in x0 ..< x0 + w:
          let gi = y * scrW + xx
          grid[gi].fg = blend(grid[gi].fg, grid[gi].bg, 0.62)
      if conflictStart >= 0 and si == 0:
        # on the <<<<<<< line: the choices, clickable
        var bx = tx0 + visColOf(s, s.len) - baseVc + 2
        let cidx = conflictStart
        for (lab0, ch) in [("Accept ours", "ours"), ("Accept theirs", "theirs"), ("Accept both", "both")]:
          let lab = " " & lab0 & " "
          if bx + lab.len >= limX: break
          let chc = ch
          capture cidx, chc:
            bx = button(bx, y, lab, proc() = buf().resolveConflict(cidx, chc), "", theme.fg, theme.btnBg) + 1
      inc row
    sub0 = 0
    if b.folds.len > 0:
      let nl = b.nextVisible(line)
      if nl != line + 1 and nl < b.lines.len:
        (st, depth) = b.stateAt(nl)
      line = nl
    else: inc line
  if rulersOn:
    for r2 in row ..< h: rulerRow(y0 + r2)                        # past the end of the file too
  if jumpOn and active and b.id == jumpBufId:
    if jumpCollect:
      jumpCollect = false
      jumpAssign(b.primary.head)
      if jumpTargets.len == 0:
        jumpOn = false
        info("No words on screen to jump to")
    if jumpOn: jumpPaint(tx0, y0, limX - tx0, h)
  # sticky scroll: enclosing headers stay visible at the top
  if cfgSticky and h >= 10 and b.topLine > 0:
    let maxN = if h >= 26: 3 elif h >= 15: 2 else: 1
    var sl = stickyLines(b, b.topLine, maxN)
    if cursorY >= y0 and cursorY - y0 < sl.len: sl.setLen(max(0, cursorY - y0))
    for i, l in sl:
      let y = y0 + i
      fillRect(x0, y, w - 1, 1, theme.fg, theme.stickyBg)
      if numW > 0:
        discard putStr(x0 + 1, y, align($(l + 1), numW), theme.gutter, theme.stickyBg)
      drawCodeLine(b, l, tx0, y, limX - 1, theme.stickyBg, (if cfgWrap: 0 else: b.leftCol))
      if i == sl.high:
        for xx in x0 ..< limX - 1:
          grid[y * scrW + xx].at.incl aUnder
  # scrollbar
  if cfgScrollbar and not minimapShown and b.lines.len > h and w > 10:
    if active:
      sbCol = x0 + w - 1
      sbTop = y0
      sbH = h
    let total = b.lines.len
    let thumbH = max(1, h * h div total)
    let thumbY = y0 + (h - thumbH) * b.topLine div max(1, total - 1)
    # (its track, faint: there is a scroll bar to tap — and the thumb on it)
    let trackC = blend(theme.bg, theme.border, 0.45)
    for yy in y0 ..< y0 + h:
      if yy < thumbY or yy >= thumbY + thumbH: setCell(x0 + w - 1, yy, Cell(ch: 0x2595, fg: trackC, bg: theme.bg))
    for yy in thumbY ..< min(y0 + h, thumbY + thumbH):
      setCell(x0 + w - 1, yy, Cell(ch: 0x2590, fg: theme.border, bg: theme.bg))
    if cfgTodoHl and tagCols.len > 0:
      for it in todoForBuf(b):
        let yy = y0 + it.line * h div total
        if yy < y0 + h: setCell(x0 + w - 1, yy, Cell(ch: 0x2590, fg: tagCols[min(it.tag, tagCols.high)], bg: theme.bg))
    for d in ds:
      if d.sev <= 2:
        let yy = y0 + d.line * h div total
        if yy < y0 + h: setCell(x0 + w - 1, yy, Cell(ch: 0x2590, fg: sevColor(d.sev), bg: theme.bg))
  # a multibuffer's § lines: drawn as headers, a click opens that place in its file
  for mr in mbRows:
    let line = mr[0]
    let y = mr[1]
    let (ok, path, fl) = mbHeaderAt(b, line)
    if not ok: continue
    let hbg = theme.crumbBg
    fillRect(x0, y, w - 1, 1, theme.fg, hbg)
    var xx = putStr(x0 + 1, y, " ▤ ", theme.accent, hbg, {aBold})
    xx = putStr(xx, y, relPath(path), theme.fg, hbg, {aBold}, x0 + w - 2)
    xx = putStr(xx, y, "  line " & $(fl + 1), theme.dim, hbg, {}, x0 + w - 2)
    let nk = b.lines[line].find("  — ")
    if nk >= 0:
      # (a note: the Git changes view's +added −removed · staged or not)
      let note = b.lines[line][nk + "  — ".len .. ^1]
      let col = if "not staged" in note or "not tracked" in note: theme.gitMod
                elif "partly" in note: theme.warn elif "staged" in note: theme.gitAdd else: theme.dim
      xx = putStr(xx + 2, y, note, col, hbg, {}, x0 + w - 2)
    let hint = "↵ or click: open"
    if xx + strWidth(hint) + 3 < x0 + w: discard putStr(x0 + w - strWidth(hint) - 2, y, hint, theme.dim, hbg)
    let pp = path
    let ll = fl
    capture pp, ll:
      region(x0 + gw, y, w - gw - 1, 1, proc() = mbOpen(pp, ll), "Open " & relPath(pp) & " at line " & $(ll + 1))

proc spansWidth(cl: ChatLine): int =
  for sp in cl.spans: result += strWidth(sp.t)

proc drawDocLines(lines: seq[ChatLine], x, y, w, h, scroll: int, bg: Rgb) =
  ## rendered Markdown inside a popup area
  for r in 0 ..< h:
    let li = scroll + r
    fillRect(x, y + r, w, 1, theme.fg, bg)
    if li >= lines.len: continue
    let cl = lines[li]
    let lb = if cl.bg == NoColor: bg else: cl.bg
    if lb != bg: fillRect(x, y + r, w, 1, theme.fg, lb)
    var xx = x
    for sp in cl.spans:
      xx = putStr(xx, y + r, sp.t, sp.fg, (if sp.bg == NoColor or sp.bg == cl.bg: lb else: sp.bg), sp.at - {aItalic}, x + w)
