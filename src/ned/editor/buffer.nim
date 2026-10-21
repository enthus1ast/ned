# ════════════════════════════════════════════════════════════════════════════
#  Buffer core: text storage, edit primitive, undo
# ════════════════════════════════════════════════════════════════════════════

const
  ekOther = 0
  ekType = 1
  ekDelete = 2

proc buf(): Buffer {.inline.} = bufs[curBuf]

proc newBuffer(): Buffer =
  result = Buffer(id: nextBufId, lines: @[""], cursors: @[cur(Pos())], indent: "  ",
                  lang: langByName("Text"), hlStart: @[0'u32, 0'u32], git: @[0'u8], ecTrim: -1, ecFinalNl: -1,
                  wkLogFrom: -1)
  inc nextBufId

func topSeq(b: Buffer): int = (if b.undoStack.len == 0: 0 else: b.undoStack[^1].seqId)
func dirty(b: Buffer): bool =
  if b.hex != nil: b.hex.undo.len != b.hex.savedAt          # (the hex editor's own undo)
  else: b.topSeq() != b.savedSeq
func isWelcome(b: Buffer): bool =
  b.welcome and b.path.len == 0 and b.title.len == 0 and b.lines.len == 1 and b.lines[0].len == 0 and
    b.undoStack.len == 0

func name(b: Buffer): string =
  if b.path.len > 0: extractFilename(b.path)
  elif b.title.len > 0: b.title
  elif b.isWelcome(): "Welcome"
  else: "untitled"
proc tabOf(b: Buffer): int = (if b.tabSize > 0: b.tabSize else: cfgTabSize)
func largeOn(b: Buffer): bool = b != nil and b.large and not b.largeOff
proc wrapFor(b: Buffer): bool =
  ## soft wrap: not in large-file mode, nor in a CSV table (its rows scroll sideways)
  cfgWrapUser and not b.largeOn and not (cfgCsvAlign and b.lang != nil and b.lang.mode == lmCsv)
proc indentW(b: Buffer): int = (if b.indent == "\t": b.tabOf else: max(1, b.indent.len))

proc clampPos(b: Buffer, p: Pos): Pos =
  result.line = clamp(p.line, 0, b.lines.high)
  let s = b.lines[result.line]
  result.col = clamp(p.col, 0, s.len)
  while result.col > 0 and result.col < s.len and (s[result.col].uint8 and 0xC0) == 0x80:
    dec result.col

func posAfter(a: Pos, text: string): Pos =
  let nl = text.count('\n')
  if nl == 0: Pos(line: a.line, col: a.col + text.len)
  else: Pos(line: a.line + nl, col: text.len - text.rfind('\n') - 1)

proc getText(b: Buffer, a0, c0: Pos): string =
  var a = b.clampPos(a0)            # out-of-range ends read up to the text's edge instead of failing
  var c = b.clampPos(c0)
  if c < a: swap(a, c)
  if a.line == c.line: return b.lines[a.line][a.col ..< c.col]
  result = b.lines[a.line][a.col .. ^1]
  for l in a.line + 1 ..< c.line:
    result.add '\n'
    result.add b.lines[l]
  result.add '\n'
  result.add b.lines[c.line][0 ..< c.col]

proc allText(b: Buffer): string = b.lines.join("\n")

proc shiftSeq[T](s: var seq[T], at, delta: int) =
  ## insert (delta > 0) or remove (delta < 0) |delta| default elements at index `at`
  if delta > 0:
    let old = s.len
    s.setLen(old + delta)
    for i in countdown(old - 1, at): s[i + delta] = move s[i]
    for i in at ..< at + delta: s[i] = default(T)
  elif delta < 0:
    let d = -delta
    for i in at ..< s.len - d: s[i] = move s[i + d]
    s.setLen(s.len - d)

proc shiftDiagTable(t: var Table[string, seq[Diag]], path: string, a, c, dl: int) =
  if path notin t: return
  for d in t[path].mitems:
    if d.line > c:
      d.line += dl
      d.eline += dl
    elif d.line > a and dl < 0:
      d.line = a
      d.eline = max(d.eline + dl, a)

proc shiftInlays(b: Buffer, a, c, e: Pos) =
  ## inlay hints follow their code: lines below the edit move with it, hints before the edit on its first
  ## line stay, hints after it on its last line move with that text, and hints inside it are dropped (a
  ## fresh set comes from nimsuggest / the language server shortly)
  if b.inlays.len == 0: return
  let dl = e.line - c.line
  var nt: Table[int, seq[(int, string)]]
  for ln, hs in b.inlays:
    if ln < a.line: nt[ln] = hs
    elif ln > c.line: nt[ln + dl] = hs
    else:
      for (col, label) in hs:
        if ln == a.line and col < a.col: nt.mgetOrPut(ln, @[]).add (col, label)
        elif ln == c.line and col > c.col: nt.mgetOrPut(e.line, @[]).add (col - c.col + e.col, label)
  for _, v in nt.mpairs:
    v.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
  b.inlays = nt

proc rawReplace(b: Buffer, a, c: Pos, text: string): Pos =
  if b.wkLogFrom >= 0:
    # (the engine worker has the text of change wkLogFrom: these edits bring it up to date — too many, the whole text)
    if b.wkLog.len < 3000: b.wkLog.add WkEdit(a: a, c: c, text: text)
    else:
      b.wkLog.setLen(0)
      b.wkLogFrom = -1
  if b.hlStart.len != b.lines.len + 1: b.hlStart.setLen(b.lines.len + 1)
  if b.git.len != b.lines.len: b.git.setLen(b.lines.len)
  if a.line == c.line and '\n' notin text and b.lines[a.line].len > 4096:
    # a long line: change it in place (one move of the tail) instead of building it again from copies
    template ln: untyped = b.lines[a.line]
    if c.col > a.col:                   # (std's delete and insert move a character at a time)
      let tail = ln.len - c.col
      if tail > 0: moveMem(addr ln[a.col], addr ln[c.col], tail)
      ln.setLen(a.col + tail)
    if text.len > 0:
      let old = ln.len
      ln.setLen(old + text.len)
      if old > a.col: moveMem(addr ln[a.col + text.len], addr ln[a.col], old - a.col)
      copyMem(addr ln[a.col], unsafeAddr text[0], text.len)
    result = Pos(line: a.line, col: a.col + text.len)
    b.hlValid = min(b.hlValid, a.line)
    inc b.changeId
    b.lspDirty = true
    b.lspChangeAt = getMonoTime()
    b.shiftInlays(a, c, result)
    if b.inGit and a.line < b.git.len and b.git[a.line] == 0: b.git[a.line] = 2'u8
    if not b.large and cfgLongLine > 0 and b.lines[a.line].len >= cfgLongLine and b.title.len == 0:
      b.large = true
      b.largeWhy = "a line of " & $b.lines[a.line].len & " characters"
      info("Large-file mode: " & b.largeWhy & " — no soft wrap or language features for this file " &
           "(palette › Large file mode)")
    needRender = true
    return
  let prefix = b.lines[a.line][0 ..< a.col]
  let suffix = b.lines[c.line][c.col .. ^1]
  if '\n' notin text:
    b.lines[a.line] = prefix & text & suffix
    let removed = c.line - a.line
    if removed > 0:
      shiftSeq(b.lines, a.line + 1, -removed)
      shiftSeq(b.hlStart, a.line + 1, -removed)
      shiftSeq(b.git, a.line + 1, -removed)
    result = Pos(line: a.line, col: a.col + text.len)
  else:
    let parts = text.split('\n')
    let delta = parts.len - (c.line - a.line + 1)
    if delta != 0:
      shiftSeq(b.lines, a.line + 1, delta)
      shiftSeq(b.hlStart, a.line + 1, delta)
      shiftSeq(b.git, a.line + 1, delta)
    for k in 0 ..< parts.len:
      var l = if k == 0: prefix & parts[k] else: parts[k]
      if k == parts.high:
        result = Pos(line: a.line + k, col: l.len)
        l.add suffix
      b.lines[a.line + k] = l
  b.hlValid = min(b.hlValid, a.line)
  inc b.changeId
  b.lspDirty = true
  b.lspChangeAt = getMonoTime()
  let dl = result.line - c.line
  b.shiftInlays(a, c, result)
  if dl != 0 and b.path.len > 0:
    shiftDiagTable(diagsLsp, b.path, a.line, c.line, dl)
    shiftDiagTable(diagsBuild, b.path, a.line, c.line, dl)
    shiftDiagTable(diagsFfi, b.path, a.line, c.line, dl)
    shiftDiagTable(diagsEmit, b.path, a.line, c.line, dl)
    shiftDiagTable(diagsWeb, b.path, a.line, c.line, dl)
  if b.inGit:
    for l in a.line .. min(result.line, b.git.high):
      if b.git[l] == 0: b.git[l] = (if dl > 0 and l > a.line: 1'u8 else: 2'u8)
  needRender = true

func shiftPos(p, a, c, e: Pos): Pos {.inline.} =
  if p <= a: p
  elif p <= c: e
  elif p.line == c.line: Pos(line: e.line, col: e.col + p.col - c.col)
  else: Pos(line: p.line + e.line - c.line, col: p.col)

# ── folding: which lines are hidden (the rest lives in the IDE section) ──

func isHidden(b: Buffer, l: int): bool =
  for (s, e) in b.folds:
    if l > s and l <= e: return true
  false

func foldAt(b: Buffer, l: int): int =
  for i, (s, _) in b.folds:
    if s == l: return i
  -1

func nextVisible(b: Buffer, l: int): int =
  result = l + 1
  for (s, e) in b.folds:
    if result > s and result <= e: result = e + 1

proc prevVisible(b: Buffer, l: int): int =
  result = l - 1
  for i in countdown(b.folds.high, 0):
    let (s, e) = b.folds[i]
    if result > s and result <= e: result = s

proc unfoldLine(b: Buffer, l: int) =
  var keep: seq[(int, int)]
  for f in b.folds:
    if l >= f[0] and l <= f[1]: continue
    keep.add f
  b.folds = keep

proc shiftFolds(b: Buffer, a, c, e: Pos) =
  ## keep folds in place across an edit (edits inside a fold open it)
  if b.folds.len == 0: return
  let delta = e.line - c.line
  var keep: seq[(int, int)]
  for (s, f) in b.folds:
    if c.line < s:
      keep.add (s + delta, f + delta)
    elif a.line > f: keep.add (s, f)
    elif a.line == s and c.line == s and e.line == s: keep.add (s, f)
  b.folds = keep

proc shiftMarks(b: Buffer, a, c, e: Pos) =
  ## line-anchored state (folds, bookmarks, TODO marks, breakpoints) follows every edit — typing, undo, redo,
  ## replace
  if b.folds.len > 0: b.shiftFolds(a, c, e)
  b.shiftTodos(a, c, e)
  if b.marks.len > 0 and e.line != c.line:
    let delta = e.line - c.line
    var keep: seq[int]
    for m in b.marks:
      if m > c.line or (m == c.line and a.line < c.line and a.col == 0): keep.add max(a.line, m + delta)
      elif m > a.line: keep.add a.line       # the marked line was deleted: the mark moves to the edit
      else: keep.add m
    b.marks.setLen(0)
    for m in keep:
      if m notin b.marks: b.marks.add m
  # breakpoints (and their conditions) follow the edit too
  if breakpoints.len > 0 and e.line != c.line and b.path.len > 0 and b.path in breakpoints:
    let delta = e.line - c.line
    var moved: HashSet[int]
    var conds, logs: seq[(int, string)]
    for m in breakpoints[b.path]:
      let n = if m > c.line or (m == c.line and a.line < c.line and a.col == 0): max(a.line, m + delta)
              elif m > a.line: a.line
              else: m
      moved.incl n
      let k = b.path & ":" & $m
      if k in bpCond:
        conds.add (n, bpCond[k])
        bpCond.del k
      if k in bpLog:
        logs.add (n, bpLog[k])
        bpLog.del k
    breakpoints[b.path] = moved
    for (n, c2) in conds: bpCond[b.path & ":" & $n] = c2
    for (n, l2) in logs: bpLog[b.path & ":" & $n] = l2

proc revealCursor(b: Buffer) =
  if b.folds.len == 0: return
  for cu in b.cursors:
    if b.isHidden(cu.head.line): b.unfoldLine(cu.head.line)

proc replaceText(b: Buffer, a0, c0: Pos, text: string): Pos =
  ## the one edit primitive: records undo and keeps every cursor valid
  # positions from callers are clamped to the text (a stale or computed position must never crash an edit)
  var a = b.clampPos(a0)
  var c = b.clampPos(c0)
  if c < a: swap(a, c)
  let old = if a == c: "" else: b.getText(a, c)
  if old.len == 0 and text.len == 0: return a
  let e = b.rawReplace(a, c, text)
  b.shiftMarks(a, c, e)
  if b.inGroup: b.group.ops.add EditOp(a: a, oldText: old, newText: text)
  for cu in b.cursors.mitems:
    cu.anchor = shiftPos(cu.anchor, a, c, e)
    cu.head = shiftPos(cu.head, a, c, e)
  for st in b.stops.mitems:
    st.anchor = shiftPos(st.anchor, a, c, e)
    st.head = shiftPos(st.head, a, c, e)
  e

proc beginEdit(b: Buffer, kind = ekOther) =
  b.inGroup = true
  b.group = UndoGroup(before: b.cursors, kind: kind, time: getMonoTime())
  # (next-edit suggestions: the line the edits are on, as it was before they began)
  if b.cursors.len == 1:
    let l = clamp(b.cursors[0].head.line, 0, b.lines.high)
    if not b.nesHas or b.nesLine != l:
      b.nesHas = true
      b.nesLine = l
      b.nesBefore = b.lines[l]
  else: b.nesHas = false

proc detachRedo(b: Buffer) =
  ## the steps undone (the redo stack) kept as a branch of the undo tree, off the line of edits where they were
  if b.redoStack.len == 0: return
  let d = b.undoStack.len
  var tail = newSeqOfCap[UndoGroup](b.redoStack.len)
  for i in countdown(b.redoStack.high, 0): tail.add b.redoStack[i]
  for br in b.undoBranches.mitems:
    if br.at > d:
      # (it hung off those steps: now off this branch, with the steps it shared)
      br.groups = tail[0 ..< clamp(br.at - d, 0, tail.len)] & br.groups
      br.at = d
  b.undoBranches.add UndoBranch(at: d, groups: tail)
  if b.undoBranches.len > 64: b.undoBranches.delete(0)
  b.redoStack.setLen(0)

proc dropOldestUndo(b: Buffer) =
  ## (the history is full: its oldest step goes, and the branches off the state before it)
  b.undoStack.delete(0)
  var k = 0
  while k < b.undoBranches.len:
    dec b.undoBranches[k].at
    if b.undoBranches[k].at < 0: b.undoBranches.delete(k) else: inc k

proc endEdit(b: Buffer) =
  b.inGroup = false
  if b.group.ops.len == 0: return
  if b.nesHas:
    for o in b.group.ops:
      if o.a.line != b.nesLine or '\n' in o.oldText or '\n' in o.newText:
        b.nesHas = false            # (an edit over lines, or elsewhere: no single line's change to repeat)
        break
  b.group.after = b.cursors
  let branched = b.redoStack.len > 0
  b.detachRedo()                   # (an edit after an undo: what was undone stays reachable — Undo history…)
  inc undoSeq
  let forceNew = b.newGroup or branched
  b.newGroup = false
  if b.group.kind in {ekType, ekDelete} and b.undoStack.len > 0 and not forceNew:
    let last = addr b.undoStack[^1]
    if last.kind == b.group.kind and msSince(last.time) < 1500 and last.after == b.group.before:
      last.ops.add b.group.ops
      last.after = b.group.after
      last.time = getMonoTime()
      last.seqId = undoSeq
      return
  b.group.seqId = undoSeq
  b.undoStack.add b.group
  if b.undoStack.len > 2000: b.dropOldestUndo()

proc normalize(b: Buffer)

proc textAt(b: Buffer, a, c: Pos, text: string): bool =
  ## is `text` what stands between a and c?
  if a.line < 0 or c.line > b.lines.high or a.line > c.line: return false
  if a.col < 0 or a.col > b.lines[a.line].len or c.col < 0 or c.col > b.lines[c.line].len: return false
  if a.line == c.line and c.col < a.col: return false
  b.getText(a, c) == text

proc undo(b: Buffer) =
  if b.undoStack.len == 0:
    info("Nothing to undo")
    return
  let g = b.undoStack.pop()
  b.nesHas = false
  b.stops.setLen(0)
  b.stopIds.setLen(0)
  for i in countdown(g.ops.high, 0):
    let op = g.ops[i]
    let c = posAfter(op.a, op.newText)
    if not b.textAt(op.a, c, op.newText):
      # the text is no longer what this step left (it was replaced from outside the undo history)
      b.undoStack.setLen(0)
      b.redoStack.setLen(0)
      b.normalize()
      b.undoBranches.setLen(0)
      warn("The undo history no longer matches this text — it was cleared")
      return
    let e = b.rawReplace(op.a, c, op.oldText)
    b.shiftMarks(op.a, c, e)
  b.cursors = g.before
  b.redoStack.add g
  b.normalize()

proc redo(b: Buffer) =
  if b.redoStack.len == 0:
    info("Nothing to redo")
    return
  let g = b.redoStack.pop()
  b.nesHas = false
  for op in g.ops:
    let c = posAfter(op.a, op.oldText)
    if not b.textAt(op.a, c, op.oldText):
      b.undoStack.setLen(0)
      b.redoStack.setLen(0)
      b.normalize()
      b.undoBranches.setLen(0)
      warn("The undo history no longer matches this text — it was cleared")
      return
    let e = b.rawReplace(op.a, c, op.newText)
    b.shiftMarks(op.a, c, e)
  b.cursors = g.after
  b.undoStack.add g
  b.normalize()

proc normalize(b: Buffer) =
  ## clamp, sort and merge overlapping cursors, keep track of the primary one
  if b.cursors.len == 0: b.cursors = @[cur(Pos())]
  b.prim = clamp(b.prim, 0, b.cursors.high)
  for c in b.cursors.mitems:
    c.anchor = b.clampPos(c.anchor)
    c.head = b.clampPos(c.head)
  if b.cursors.len == 1:
    b.prim = 0
    return
  let primHead = b.cursors[b.prim].head
  b.cursors.sort(proc(x, y: Cursor): int = cmp(x.range[0].line * 1_000_000_000 + x.range[0].col,
                                                y.range[0].line * 1_000_000_000 + y.range[0].col))
  var res: seq[Cursor]
  for c in b.cursors:
    if res.len > 0:
      let (ps, pe) = res[^1].range
      let (cs, ce) = c.range
      if cs < pe or cs == ps:
        let forward = res[^1].anchor <= res[^1].head
        let ne = maxP(pe, ce)
        res[^1] = if forward: Cursor(anchor: ps, head: ne, goalX: -1)
                  else: Cursor(anchor: ne, head: ps, goalX: -1)
        continue
    res.add c
  b.cursors = res
  b.prim = 0
  for i, c in b.cursors:
    let (s, e) = c.range
    if s <= primHead and primHead <= e:
      b.prim = i
      break

func primary(b: Buffer): var Cursor = b.cursors[b.prim]

proc setSingle(b: Buffer, p: Pos, anchor = Pos(line: -1)) =
  let p2 = b.clampPos(p)
  b.cursors = @[Cursor(anchor: (if anchor.line < 0: p2 else: b.clampPos(anchor)), head: p2, goalX: -1)]
  b.prim = 0

func bracketDelta(s: string, toks: seq[TokKind]): int =
  for i in 0 ..< min(s.len, toks.len):
    if toks[i] == tkPunct:
      case s[i]
      of '(', '[', '{': inc result
      of ')', ']', '}': dec result
      else: discard

proc ensureHl(b: Buffer, upto: int) =
  ## exact lexer state (and bracket depth) for every line start up to `upto`
  if b.hlStart.len != b.lines.len + 1: b.hlStart.setLen(b.lines.len + 1)
  if b.hlDepth.len != b.lines.len + 1: b.hlDepth.setLen(b.lines.len + 1)
  var toks: seq[TokKind]
  let target = min(upto, b.lines.len)
  while b.hlValid < target:
    let l = b.hlValid
    if b.lines[l].len > 20000:
      b.hlStart[l + 1] = b.hlStart[l]
      b.hlDepth[l + 1] = b.hlDepth[l]
    else:
      b.hlStart[l + 1] = lexLine(b.lang, b.lines[l], b.hlStart[l], toks)
      b.hlDepth[l + 1] = int16(clamp(b.hlDepth[l].int + bracketDelta(b.lines[l], toks), 0, 30000))
    inc b.hlValid

proc stateAt(b: Buffer, line: int): (LexSt, int) =
  ## lexer state + bracket depth at `line`. Far beyond the computed region we lex a short
  ## window instead (instant jumps in huge files); the background pass makes it exact.
  if line <= b.hlValid and line < b.hlStart.len:
    return (b.hlStart[line], (if line < b.hlDepth.len: b.hlDepth[line].int else: 0))
  if line - b.hlValid <= 4000:
    b.ensureHl(line)
    return (b.hlStart[line], b.hlDepth[line].int)
  var toks: seq[TokKind]
  var st: LexSt = 0
  var d = 0
  for l in max(0, line - 300) ..< line:
    if b.lines[l].len > 20000: continue
    st = lexLine(b.lang, b.lines[l], st, toks)
    d = max(0, d + bracketDelta(b.lines[l], toks))
  (st, d)

proc hlTarget(b: Buffer): int =
  min(b.lines.len, max(b.topLine, b.cursors[b.prim].head.line) + max(textH, 20) + 200)

proc hlPump(b: Buffer, budgetMs: int) =
  ## background: make highlighting exact up to the visible region, a slice at a time
  let target = b.hlTarget()
  if b.hlValid >= target: return
  let t0 = getMonoTime()
  while b.hlValid < target and msSince(t0) < budgetMs:
    b.ensureHl(min(target, b.hlValid + 3000))
  if b.hlValid >= target: needRender = true

proc tokenAt(b: Buffer, p: Pos): TokKind =
  let (st, _) = b.stateAt(p.line)
  var toks: seq[TokKind]
  discard lexLine(b.lang, b.lines[p.line], st, toks)
  if p.col < toks.len: toks[p.col] elif toks.len > 0: toks[^1] else: tkText

proc foreignAt(col: int): bool =
  ## after tokenAt: is the column in code of another language (C in an emit, HTML in a Nim string)?
  for (a, e) in lexForeign:
    if col >= a and col < e: return true

proc chainLang(st: LexSt): Lang =
  ## the innermost language of the blocks open at a line start (C in an emit, JavaScript in a <script> …)
  var x = st
  var id = stTop(x)
  while id > 0 and id < embeds.len:
    let l = embedLang(embeds[id].langId)
    if l == nil or l.id == "nimfmt": break
    result = l
    x = stInner(x)
    id = stTop(x)

proc langAt(b: Buffer, p: Pos): Lang =
  ## the language of the code at p: the file's own, or the one embedded there — C in a Nim emit, HTML or SQL
  ## in a string, JavaScript in a <script>, a Markdown code block's
  result = b.lang
  if b.lang == nil or b.lang.mode notin {lmNim, lmMarkdown, lmHtml, lmNimf} or p.line < 0 or p.line >= b.lines.len:
    return
  let s = b.lines[p.line]
  if s.len > 2000: return
  let (st, _) = b.stateAt(p.line)
  var toks: seq[TokKind]
  discard lexLine(b.lang, s, st, toks)
  var best: Lang = nil
  var bestD = 0
  var bestW = high(int)
  for (a, e, d, l) in lexLangs:
    if l == nil or l.id == "nimfmt": continue
    if (p.col >= a and p.col < e) or (p.col == e and e == s.len):
      if d > bestD or (d == bestD and e - a <= bestW):
        best = l
        bestD = d
        bestW = e - a
  if best != nil: return best
  if s.strip.len == 0:                      # a blank line inside a block: the block's language
    let l = chainLang(st)
    if l != nil: return l
