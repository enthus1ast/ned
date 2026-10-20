# ── jump labels: a letter or two over every word on screen; typing it puts the cursor there (like flash.nvim,
#    hop, Helix's gw) — no counting lines, no searching ──

const JumpAlphabet = "fjdkslaghrueiwoqptyvbcnxmz"

var
  jumpOn = false               # waiting for a label
  jumpTyped = ""               # the label's letters typed so far
  jumpBufId = -1
  jumpCollect = false          # the next frame gathers the words it draws
  jumpVis: seq[(Pos, int, int)]          # the words on screen: (where, screen x, screen y)
  jumpTargets: seq[(Pos, int, int, string)]   # … with their labels

proc cmdJumpLabels() =
  ## a label on each word on screen; its letters put the cursor there (Esc: never mind)
  let b = buf()
  if b.hex != nil or b.mdSrc != 0 or b.id in diffViews:
    info("Jump labels work in a text view")
    return
  focus = fEditor
  closeComp()
  jumpOn = true
  jumpTyped = ""
  jumpBufId = b.id
  jumpCollect = true
  jumpVis.setLen(0)
  jumpTargets.setLen(0)
  needRender = true

proc jumpAssign(caret: Pos) =
  ## labels for the gathered words, the nearest to the cursor first (one letter while they suffice)
  var vis = jumpVis
  vis.sort(proc(a, b: (Pos, int, int)): int =
    let da = abs(a[0].line - caret.line) * 1000 + abs(a[0].col - caret.col)
    let db = abs(b[0].line - caret.line) * 1000 + abs(b[0].col - caret.col)
    cmp(da, db))
  let n = JumpAlphabet.len
  if vis.len > n * n: vis.setLen(n * n)
  jumpTargets.setLen(0)
  if vis.len <= n:
    for i, v in vis: jumpTargets.add (v[0], v[1], v[2], $JumpAlphabet[i])
  else:
    for i, v in vis: jumpTargets.add (v[0], v[1], v[2], $JumpAlphabet[i div n] & $JumpAlphabet[i mod n])

proc jumpPaint(x0, y0, w, h: int) =
  ## the labels over the words (the rest of the text dimmed, so they stand out)
  for yy in y0 ..< y0 + h:
    for xx in x0 ..< x0 + w:
      let gi = yy * scrW + xx
      if gi >= 0 and gi < grid.len: grid[gi].fg = blend(grid[gi].fg, grid[gi].bg, 0.55)
  for (p, x, y, lab) in jumpTargets:
    if not lab.startsWith(jumpTyped): continue
    let rest = lab[jumpTyped.len .. ^1]
    var xx = x
    for k, ch in rest:
      if xx >= x0 + w: break
      let gi = y * scrW + xx
      if gi < 0 or gi >= grid.len: break
      grid[gi] = Cell(ch: uint32(ord(ch)), fg: (if k == 0: theme.bg else: theme.bg),
                      bg: (if k == 0: theme.accent else: blend(theme.accent, theme.bg, 0.35)), at: {aBold})
      inc xx

proc jumpKey(k: Key): bool =
  ## a key while labels are shown: a label's letter, or anything else to stop (true: the key was used)
  if not jumpOn: return false
  if k.kind == kChar and k.ch < 128 and char(k.ch).toLowerAscii in JumpAlphabet and mCtrl notin k.mods and
     mAlt notin k.mods:
    jumpTyped.add char(k.ch).toLowerAscii
    var hit = -1
    var any = false
    for i, t in jumpTargets:
      if t[3] == jumpTyped: hit = i
      if t[3].startsWith(jumpTyped): any = true
    if hit >= 0:
      let b = buf()
      jumpOn = false
      if b.id == jumpBufId:
        pushJump()
        let p = b.clampPos(jumpTargets[hit][0])
        # (an upper-case label letter: the selection reaches there)
        if char(k.ch) in {'A'..'Z'}: b.setSingle(p, b.primary.anchor)
        else: b.setSingle(p)
      needRender = true
      return true
    if not any:
      jumpOn = false
      info("No such label")
    needRender = true
    return true
  jumpOn = false
  needRender = true
  k.kind == kEsc
