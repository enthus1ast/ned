# ── the undo tree: an edit after an undo keeps what was undone as a branch (buffer.nim: detachRedo), and Edit ›
#    Undo history… lists every state the file has been in — on the line of edits and on its branches, the newest
#    first — with a preview of the text there; picking one goes to it (the line of edits it leaves becomes a branch
#    in its turn) ──

var
  undoPickStates: seq[(int, int)]   # (branch, depth) behind each line of it: branch -1 is the line of edits
  undoPrev: tuple[buf, sel, changeId: int, b: Buffer, line: int] = (-1, -1, -1, nil, 0)

proc undoJump(b: Buffer, br, depth: int): bool =
  ## to a state: `depth` steps along the line of edits (br -1: the steps done then the ones undone), or along branch
  ## br (the line of edits from where the branch leaves it becomes a branch)
  if br < 0:
    if depth < 0 or depth > b.undoStack.len + b.redoStack.len: return false
    while b.undoStack.len > depth:
      let n = b.undoStack.len
      b.undo()
      if b.undoStack.len >= n: return false
    while b.undoStack.len < depth:
      let n = b.undoStack.len
      b.redo()
      if b.undoStack.len <= n: return false
    return true
  if br >= b.undoBranches.len: return false
  let at = b.undoBranches[br].at
  if depth < 1 or depth > b.undoBranches[br].groups.len: return false
  if not b.undoJump(-1, at): return false
  let target = b.undoBranches[br]
  b.undoBranches.delete(br)
  b.detachRedo()
  for i in countdown(target.groups.high, 0): b.redoStack.add target.groups[i]
  b.undoJump(-1, at + depth)

proc undoShort(s: string, n = 32): string =
  ## the text of a step, short: line breaks as ⏎, spaces only as ␣
  var t = s.replace("\n", "⏎").replace("\t", "⇥")
  if t.strip.len == 0: t = t.replace(" ", "␣")
  "“" & truncTo(t, n) & "”"

proc undoSummary(g: UndoGroup): string =
  ## what a step did, in a few words: typed “…”, deleted “…”, replaced “…” → “…”
  if g.ops.len == 0: return "(no change)"
  # typing: insertions one after the other; Backspace: deletions each just before the last
  var typed = ""
  var chain = true
  for i, o in g.ops:
    if o.oldText.len > 0 or (i > 0 and o.a != posAfter(g.ops[i - 1].a, g.ops[i - 1].newText)):
      chain = false
      break
    typed.add o.newText
  if chain: return "typed " & undoShort(typed)
  var gone = ""
  chain = true
  for i, o in g.ops:
    if o.newText.len > 0 or (i > 0 and posAfter(o.a, o.oldText) != g.ops[i - 1].a and o.a != g.ops[i - 1].a):
      chain = false
      break
    if i > 0 and o.a == g.ops[i - 1].a: gone.add o.oldText       # (Delete: the text after)
    else: gone = o.oldText & gone
  if chain: return "deleted " & undoShort(gone)
  let o = g.ops[0]
  result = if o.oldText.len == 0: "inserted " & undoShort(o.newText)
           elif o.newText.len == 0: "deleted " & undoShort(o.oldText)
           else: "replaced " & undoShort(o.oldText, 18) & " → " & undoShort(o.newText, 18)
  if g.ops.len > 1: result.add " and " & $(g.ops.len - 1) & " more"

proc undoAgo(g: UndoGroup): string =
  if g.time == MonoTime(): return ""
  let s = msSince(g.time) div 1000
  if s < 60: $s & " s ago"
  elif s < 3600: $(s div 60) & " min ago"
  elif s < 86400: $(s div 3600) & " h ago"
  else: $(s div 86400) & " d ago"

proc undoPreviewOf(b: Buffer, br, depth: int): (Buffer, int) =
  ## the text the state has (a copy of the buffer taken there) and the line its last step changed
  let c = newBuffer()
  dec nextBufId                    # (not an editor buffer: its id stays free)
  c.id = -300
  c.lines = b.lines
  c.lang = b.lang
  c.indent = b.indent
  c.undoStack = b.undoStack
  c.redoStack = b.redoStack
  c.undoBranches = b.undoBranches
  c.cursors = b.cursors
  c.hlStart = @[0'u32]
  c.hlValid = 0
  if not c.undoJump(br, depth): return (nil, 0)
  let line = if c.undoStack.len > 0 and c.undoStack[^1].ops.len > 0: c.undoStack[^1].ops[0].a.line
             else: c.primary.head.line
  (c, clamp(line, 0, c.lines.high))

proc undoPreviewTarget(): (string, int, Buffer) =
  ## (for the picker's preview) the selected state's text
  if undoPickBuf < 0 or pickSel < 0 or pickSel >= pickShown.len: return ("", -1, nil)
  var b: Buffer = nil
  for x in bufs:
    if x.id == undoPickBuf: b = x
  if b == nil: return ("", -1, nil)
  let i = pickItems[pickShown[pickSel]].idx
  if i < 0 or i >= undoPickStates.len: return ("", -1, nil)
  if undoPrev.buf == b.id and undoPrev.sel == i and undoPrev.changeId == b.changeId and undoPrev.b != nil:
    return ("", undoPrev.line, undoPrev.b)
  let (c, line) = b.undoPreviewOf(undoPickStates[i][0], undoPickStates[i][1])
  if c == nil: return ("", -1, nil)
  undoPrev = (b.id, i, b.changeId, c, line)
  ("", line, c)

type UndoState = tuple[br, depth, seqId: int, g: UndoGroup, undone: bool]

proc undoStates(b: Buffer): seq[UndoState] =
  ## every state but the oldest, the newest first: on the line of edits (branch -1) and on the branches
  var seen: HashSet[int]
  var main = b.undoStack
  for i in countdown(b.redoStack.high, 0): main.add b.redoStack[i]
  for k in 1 .. main.len:
    result.add (-1, k, main[k - 1].seqId, main[k - 1], k > b.undoStack.len)
    seen.incl main[k - 1].seqId
  for bi, br in b.undoBranches:
    for k in 1 .. br.groups.len:
      let g = br.groups[k - 1]
      if g.seqId in seen: continue           # (a step two branches share: listed once)
      seen.incl g.seqId
      result.add (bi, k, g.seqId, g, false)
  result.sort(proc(x, y: UndoState): int = cmp(y.seqId, x.seqId))

proc undoChrono(b: Buffer, dir: int) =
  ## vim's g- and g+: to the state made just before (or after) this one, whichever branch it is on
  let sts = b.undoStates()
  let now = b.topSeq()
  var best = -1
  for i, s in sts:
    if (dir < 0 and s.seqId < now) or (dir > 0 and s.seqId > now):
      if best < 0 or (dir < 0 and s.seqId > sts[best].seqId) or (dir > 0 and s.seqId < sts[best].seqId): best = i
  if best < 0:
    if dir < 0 and b.undoStack.len > 0: discard b.undoJump(-1, 0)
    else: info(if dir < 0: "At the oldest state" else: "At the newest state")
    return
  if not b.undoJump(sts[best].br, sts[best].depth): warn("The undo history no longer matches the text")

proc undoJumpSeq(b: Buffer, seqId: int): bool =
  ## to the state its step `seqId` made (0: the oldest state kept), wherever it is in the tree now
  if seqId == 0: return b.undoJump(-1, 0)
  for s in b.undoStates():
    if s.seqId == seqId: return b.undoJump(s.br, s.depth)
  false

proc cmdUndoHistory() =
  ## Edit › Undo history…: every state of the file (the newest first), the branches an edit after an undo left too
  let b = buf()
  if b.undoStack.len == 0 and b.redoStack.len == 0 and b.undoBranches.len == 0:
    info("No undo history for this file yet")
    return
  let sts = b.undoStates()
  var items: seq[(string, string, proc() {.closure.})]
  undoPickStates.setLen(0)
  let bid = b.id
  proc go(seqId: int): proc() {.closure.} =
    result = proc() =
      for x in bufs:
        if x.id == bid:
          let before = x.undoBranches.len
          let br = block:
            var r = -1
            for s in x.undoStates():
              if s.seqId == seqId: r = s.br
            r
          if x.undoJumpSeq(seqId):
            x.newGroup = true
            info("Undo history: at that state now" & (if br >= 0 or x.undoBranches.len > before:
                   " — the edits you left are a branch (Undo history… goes back)" else: ""))
          else: warn("Could not go to that state: the undo history no longer matches the text")
  for s in sts:
    let cur = s.br < 0 and s.depth == b.undoStack.len
    let mark = if cur: "● " elif s.br >= 0: "⑂ " elif s.undone: "↷ " else: "  "
    let line = if s.g.ops.len > 0: "line " & $(s.g.ops[0].a.line + 1) else: ""
    var det = line
    let ago = undoAgo(s.g)
    if ago.len > 0: det.add " · " & ago
    if s.br >= 0: det.add " · branch " & $(s.br + 1)
    elif s.undone: det.add " · undone"
    if cur: det.add " · now"
    undoPickStates.add (s.br, s.depth)
    items.add (mark & undoSummary(s.g), det, go(s.seqId))
  let oldest = b.undoStack.len == 0 and b.redoStack.len == 0
  undoPickStates.add (-1, 0)
  items.add ((if b.undoStack.len == 0: "● " else: "  ") & "the oldest state kept" &
             (if b.savedSeq == 0 and not oldest: " (as opened)" else: ""), "before every step", go(0))
  openActions("Undo history — " & b.name & " (● now · ↷ undone · ⑂ a branch)", items)
  undoPickBuf = b.id
  undoPrev = (-1, -1, -1, nil, 0)
