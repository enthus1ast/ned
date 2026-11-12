# the vim keymap's key handling (editor.vimMode): Ctrl+W window commands, and vimKey, which takes each key in insert,
# replace, normal and visual mode — counts, operators, motions, text objects, macros and repeating the last change with
# a dot.
proc vimWindowKey(c: char): bool =
  ## Ctrl+W then c: vim's window commands, on ned's panes
  result = true
  case c
  of 'h': focusDir(-1, 0)
  of 'l': focusDir(1, 0)
  of 'k': focusDir(0, -1)
  of 'j': focusDir(0, 1)
  of 'w': toggleSplitFocus()
  of 'W', 'p':
    if splitOn:
      let o = otherPane()
      if c == 'p': focusPane(o)
      else:
        let ord = paneOrder()
        focusPane(ord[(ord.find(activePane) + ord.len - 1) mod ord.len])
  of 's', 'S': splitEditor(true)
  of 'v': splitEditor(false)
  of 'q', 'c': closeActivePane()
  of 'o': closeSplit()
  of '=': equalizePanes()
  of 'x': swapPaneDir(1, 0)
  of 'z', '_', '|': toggleZoom()
  of 'H', 'J', 'K', 'L':
    swapPaneDir((if c == 'H': -1 elif c == 'L': 1 else: 0), (if c == 'K': -1 elif c == 'J': 1 else: 0))
  else: result = false

proc vimEscapeSeq(b: Buffer, k: Key): bool =
  ## vim.escapeSequence in insert mode (vim's or Helix's): true on its second key typed within 400 ms of the first,
  ## the first taken out of the text again; the first key remembered
  if cfgVimEscape.len != 2 or k.kind != kChar or k.mods != {} or k.ch >= 128: return false
  let c = char(k.ch)
  if vimEscChar == cfgVimEscape[0] and c == cfgVimEscape[1] and msSince(vimEscAt) < 400:
    vimEscChar = '\0'
    b.backspace()
    return true
  if c == cfgVimEscape[0]:
    vimEscChar = c
    vimEscAt = getMonoTime()
  else: vimEscChar = '\0'
  false

proc vimUserRun(what: string, count: int, visual: bool) =
  ## one of your own keys (vim.keys, vim.visualKeys, helix.keys): `what` is a `:` line, run as if typed after :, or
  ## the name of a command of the palette — `count` times (a count typed before the keys; 100 at most). In a visual
  ## mode the command gets what it shows selected (whole lines in V, the last character too in v), and normal mode
  ## comes back after it, at the selection's start, as after vim's own commands
  if visual and cfgVim and vimMode in {vmVisual, vmVLine}:
    let b = buf()
    var (a, e) = b.primary.range
    if vimMode == vmVLine: (a, e) = (Pos(line: a.line, col: 0), Pos(line: e.line, col: b.lines[e.line].len))
    else: e = b.clampPos(Pos(line: e.line, col: e.col + 1))
    b.setSingle(e, a)
  for _ in 1 .. clamp(count, 1, 100):
    if what.startsWith(":"): vimEx(what[1 .. ^1]) else: runCmd(what)
  if visual and cfgVim and vimMode in {vmVisual, vmVLine}:
    let b = buf()
    vimSetMode(vmNormal)
    b.setSingle(b.clampNormal(b.primary.range[0]))
  needRender = true

proc vimKey(k: Key): bool =
  ## true when vim consumed the key
  let b = buf()
  if b.isWelcome(): return false
  if vimMode in {vmVisual, vmVLine}:
    # (what gv brings back: the selection as it stands before this key — an operator or Esc then acts on it, and it is
    # still the last one afterwards)
    vimPrevSel = (true, vimMode, b.cursors[b.prim].anchor, b.cursors[b.prim].head, vimVLineCol)
  if not vimReplaying:
    if vimMode == vmNormal and vimPending.len == 0 and vimCount.len == 0:
      vimRec.setLen(0)
      vimIsChange = false
    vimRec.add k
  # ── insert / replace mode ──
  if vimMode in {vmInsert, vmReplace}:
    let esc = k.kind == kEsc or (k.kind == kChar and mCtrl in k.mods and k.ch in [ord('['), ord('c')]) or
              vimEscapeSeq(b, k)
    if esc:
      if compOpen:
        closeComp()
      b.stops.setLen(0)
      let p = b.primary.head
      b.mergeUndo(vimUndoMark)
      vimUndoMark = -1
      vimSetMode(vmNormal)
      b.setSingle(b.clampNormal(Pos(line: p.line, col: max(0, p.col - 1))))
      if vimIsChange and not vimReplaying: vimLastChange = vimRec
      return true
    if k.kind == kChar and k.mods == {mCtrl} and k.ch in [ord('t'), ord('d')]:
      # (vim's i_CTRL-T / i_CTRL-D: the line one level in or out, the cursor staying on the same text)
      let p = b.primary.head
      let before = b.lines[p.line].len
      b.indentLines(if k.ch == ord('t'): 1 else: -1)
      let moved = b.lines[p.line].len - before
      b.setSingle(Pos(line: p.line, col: max(0, p.col + moved)))
      return true
    if vimMode == vmReplace and k.kind == kChar and k.mods == {}:
      let p = b.primary.head
      if p.col < b.lines[p.line].len:
        b.beginEdit()
        var s = ""
        s.addUtf8(k.ch)
        discard b.replaceText(p, Pos(line: p.line, col: p.col + runeLen(b.lines[p.line][p.col])), s)
        b.endEdit()
        b.setSingle(Pos(line: p.line, col: p.col + s.len))
        return true
    return false
  # ── normal / visual ──
  let visual = vimMode in {vmVisual, vmVLine}
  if k.kind == kEsc:
    vimPending = ""
    vimCount = ""
    vimOpCount = ""
    plugVimReset()
    if visual:
      vimSetMode(vmNormal)
      b.setSingle(b.clampNormal(b.primary.head))
    elif b.cursors.len > 1:
      b.cursors = @[b.primary]
      b.prim = 0
    hoverOpen = false
    return true
  # let ordinary shortcuts (Ctrl+S, Alt+…, F-keys, arrows) keep working
  var ch = '\0'
  var plainChar = false                    # (a character key, ASCII or not: r, f and t take any character)
  if k.kind == kChar and (k.mods == {} or k.mods == {mShift}):
    plainChar = true
    if k.ch < 128: ch = char(k.ch)
  elif k.kind == kChar and mCtrl in k.mods and k.ch < 128:
    let c = toLowerAscii(char(k.ch))
    let p = b.primary.head
    # (a plugin's mapping of <C-a> … <C-z> — dial's Ctrl+A: it comes as the control character)
    if c in {'a'..'z'} and mAlt notin k.mods and plugVimKey(b, chr(ord(c) - 96), visual): return true
    if vimPending == "\x17":
      vimPending = ""
      return vimWindowKey(c)                  # (Ctrl+W Ctrl+H … as Ctrl+W h)
    case c
    of 'w':
      vimPending = "\x17"                    # Ctrl+W: a pane command follows (h j k l, w, s, v, q, o, =)
      info("Ctrl+W: h j k l to that pane · w next · s v split · q close · o only this one · = equal · x swap")
      return true
    of 'r':
      b.redo()
      return true
    of 'd', 'u':
      let d = textH div 2 * (if c == 'd': 1 else: -1)
      b.scrollBy(d)
      b.setSingle(b.clampNormal(Pos(line: clamp(p.line + d, 0, b.lines.high), col: p.col)))
      return true
    of 'f', 'b':
      let d = (textH - 2) * (if c == 'f': 1 else: -1)
      b.scrollBy(d)
      b.setSingle(b.clampNormal(Pos(line: clamp(p.line + d, 0, b.lines.high), col: p.col)))
      return true
    of 'o':
      jumpBack()
      return true
    of 'v':
      vimSetMode(vmVisual)
      return true
    of 'z':
      suspendNed()                           # (as vim: back to the shell, fg returns)
      return true
    else: return false
  elif k.kind == kEnter:
    if plugVimKey(b, '\r', visual): return true       # (a plugin's <CR>: the folder view's "open this")
    ch = '+'
  elif k.kind == kBackspace: ch = 'h'
  else:
    if k.kind in {kLeft, kRight, kUp, kDown, kHome, kEnd, kPgUp, kPgDn} and k.mods == {}:
      ch = case k.kind
        of kLeft: 'h'
        of kRight: 'l'
        of kUp: 'k'
        of kDown: 'j'
        of kHome: '0'
        of kEnd: '$'
        else: '\0'
      if ch == '\0': return false
    else: return false
  if ch == '\0' and not plainChar: return false
  if plugVimKey(b, ch, visual): return true          # (a plugin's mapping, operator or what it waits for)
  # (where the cursor is after it: keys it held back that were not a mapping after all, given back to vim, may have
  # moved it — space then l went one to the right, not two)
  let p = b.primary.head
  # counts
  if ch in {'1'..'9'} or (ch == '0' and vimCount.len > 0):
    if vimPending in ["", "d", "c", "y", ">", "<", "gu", "gU", "gc", "~"] or vimPending.len == 0:
      if vimCount.len < 6: vimCount.add ch      # counts stop at 999999
      return true
  # pending two-key commands
  if vimPending == "\x17":
    vimPending = ""
    discard vimWindowKey(ch)
    return true
  if vimPending.len > 0:
    let pend = vimPending
    if pend in ["f", "t", "F", "T"] or (pend.len == 2 and pend[1] in {'f', 't', 'F', 'T'} and pend[0] in {'d', 'c', 'y', '>', '<'}):
      discard
    elif pend == "r":
      vimPending = ""
      let n = max(1, (if vimCount.len > 0: parseInt(vimCount) else: 1))
      vimCount = ""
      var e = p.col                         # n characters, not n bytes
      var cnt = 0
      while cnt < n and e < b.lines[p.line].len:
        e = nextCluster(b.lines[p.line], e)
        inc cnt
      if cnt == n and b.canEdit():
        # (the character typed may be a multi-byte one: r takes any character, not just an ASCII byte)
        var one = ""
        if k.kind == kChar: one.addUtf8(k.ch) else: one.add ch
        var rep = ""
        for _ in 0 ..< n: rep.add one
        b.beginEdit()
        discard b.replaceText(p, Pos(line: p.line, col: e), rep)
        b.endEdit()
        # (vim's r leaves the cursor where it was; with a count, on the last character it replaced)
        b.setSingle(b.clampNormal(Pos(line: p.line, col: p.col + rep.len - one.len)))
        vimIsChange = true
        if not vimReplaying: vimLastChange = vimRec
      return true
    elif pend == "q":
      # q{a-z}: record into a register (the next q stops)
      vimPending = ""
      vimCount = ""
      if ch in {'a'..'z', 'A'..'Z', '0'..'9'}: macroStart($toLowerAscii(ch))
      return true
    elif pend == "@":
      # @{a-z} plays a register, @@ the one played last; a count plays it that many times
      vimPending = ""
      let n = max(1, (if vimCount.len > 0: parseInt(vimCount) else: 1))
      vimCount = ""
      let reg = if ch == '@': vimMacroLastReg else: $toLowerAscii(ch)
      if reg.len == 0 or reg notin macroRegs:
        info(if reg.len == 0: "No register played yet" else: "Register @" & reg & " is empty — q" & reg & " records into it")
        return true
      vimMacroLastReg = reg
      macroPlay(macroRegs[reg], n)
      return true
    elif pend == "z":
      vimPending = ""
      case ch
      of 'z': b.centerOn(p)
      of 't':
        b.topLine = p.line
        b.topSub = 0
      of 'b':
        b.topLine = max(0, p.line - textH + 1)
        b.topSub = 0
      of 'a', 'c', 'o', 'M', 'R':
        case ch
        of 'a': runCmd("Toggle fold")
        of 'c': runCmd("Fold")
        of 'o': runCmd("Unfold")
        of 'M': runCmd("Fold all")
        else: runCmd("Unfold all")
      else: discard
      return true
    elif pend == "g":
      vimPending = ""
      case ch
      of 'g':
        # (gg is a motion like the others: it keeps its column without a count, and goes to that line's column 1 with one)
        let hadC = vimCount.len > 0
        let m = b.vimMotion("gg", max(1, (if hadC: parseInt(vimCount) else: 1)), p)
        vimCount = ""
        var np = m.p
        if hadC: vimDesiredCol = -1
        if visual: b.cursors[b.prim].head = np else: b.setSingle(b.clampNormal(np))
        return true
      of 'd':
        cmdDefinition()
        return true
      of 'r':
        cmdReferences()
        return true
      of 't':
        switchTab(1)
        return true
      of 'T':
        switchTab(-1)
        return true
      of 'u', 'U', 'c', '~':
        if visual:
          let (a, e) = b.primary.range
          b.vimApply("g" & $ch, a, (if vimMode == vmVLine: e else: Pos(line: e.line, col: e.col)), vimMode == vmVLine)
          vimSetMode(vmNormal)
          return true
        vimPending = "g" & $ch
        vimOpCount = vimCount
        vimCount = ""
        return true
      of 'J':
        b.joinLines()
        return true
      of 'v':
        # (gv: the last visual selection again, in its mode — after Esc, or after an operator on it)
        if vimPrevSel.ok:
          vimSetMode(vimPrevSel.mode)
          b.cursors = @[Cursor(anchor: b.clampPos(vimPrevSel.anchor), head: b.clampPos(vimPrevSel.head), goalX: -1)]
          b.prim = 0
          if vimPrevSel.mode == vmVLine: vimVLineCol = vimPrevSel.vcol
        return true
      of '-', '+':
        for _ in 0 ..< max(1, (if vimCount.len > 0: parseInt(vimCount) else: 1)): b.undoChrono(if ch == '-': -1 else: 1)
        vimCount = ""
        return true
      else: return true
    elif pend in ["ys", "ysi", "ysa", "ys>", "ds", "cs", "S"] or (pend.len == 3 and pend.startsWith("cs")):
      # vim-surround: ys{motion}{char} (yss: the line), ds{char}, cs{old}{new}, S{char} on a visual selection
      let n = max(1, (if vimCount.len > 0: parseInt(vimCount) else: 1)) *
              max(1, (if vimOpCount.len > 0: parseInt(vimOpCount) else: 1))
      vimCount = ""
      vimOpCount = ""
      case pend
      of "ys":
        if ch in {'i', 'a'}:
          vimPending = "ys" & $ch
          return true
        if ch == 's':
          let fb = b.firstNonBlank(p.line)
          vimSurRange = (fb, Pos(line: p.line, col: b.lines[p.line].len))
        else:
          vimPending = "ys"
          let m = b.vimMotion($ch, n, p)
          if not m.ok:
            vimPending = ""
            return true
          var e = m.p
          if m.inclusive: e.col += 1
          vimSurRange = if m.linewise: (Pos(line: min(p.line, e.line), col: 0),
                                        Pos(line: max(p.line, e.line), col: b.lines[max(p.line, e.line)].len))
                        else: (minP(p, e), maxP(p, e))
        vimPending = "ys>"
      of "ysi", "ysa":
        let (ok, a, e) = b.textObject(pend[2], ch, p)
        vimPending = if ok: "ys>" else: ""
        vimSurRange = (a, e)
      of "ys>":
        vimPending = ""
        b.vimSurroundChar(ch, @[vimSurRange])
        vimIsChange = true
        if not vimReplaying: vimLastChange = vimRec
        b.setSingle(b.clampNormal(vimSurRange[0]))
      of "S":
        vimPending = ""
        let (a, e) = b.primary.range
        let lw = vimMode == vmVLine
        vimSetMode(vmNormal)
        b.vimSurroundChar(ch, @[(a, (if lw: Pos(line: e.line, col: b.lines[e.line].len) else: Pos(line: e.line, col: e.col + 1)))],
                          lines = lw)
        b.setSingle(b.clampNormal(a))
      of "ds":
        vimPending = ""
        if b.deleteSurrounding(ch):
          vimIsChange = true
          if not vimReplaying: vimLastChange = vimRec
      of "cs":
        vimPending = "cs" & $ch
      else:
        vimPending = ""
        let old = pend[2]
        if ch in {'t', '<'}: changeSurroundingToTag(old)
        else:
          let (op, cl) = surroundPair(ch)
          if op.len > 0 and b.changeSurrounding(op, cl, old):
            vimIsChange = true
            if not vimReplaying: vimLastChange = vimRec
      return true
    elif pend.len >= 2 and pend[^1] in {'i', 'a'} and
         pend[0 ..< pend.len - 1] in ["d", "c", "y", ">", "<", "gu", "gU", "g~", "gc"]:
      discard
    elif pend.len == 2 and pend[1] == 'g' and pend[0] in {'d', 'c', 'y', '>', '<'}:
      vimPending = ""
      let cnt = if vimOpCount.len > 0: parseInt(vimOpCount) elif vimCount.len > 0: parseInt(vimCount) else: 1
      let hadC = vimOpCount.len > 0 or vimCount.len > 0
      vimCount = ""
      vimOpCount = ""
      if ch == 'g':
        let target = if hadC: clamp(cnt - 1, 0, b.lines.high) else: 0
        b.vimApply($pend[0], p, Pos(line: target, col: 0), true, b.visColOfPos(p))
        if pend[0] != 'y':
          vimIsChange = true
          if vimMode == vmNormal and not vimReplaying: vimLastChange = vimRec
      return true
    elif visual and pend.len == 1 and pend[0] in {'i', 'a'}:
      discard                                # (a visual text object: `vi` `w` — the branch below it reads the object)
    else:
      # operator pending: d c y > < gu gU gc
      let op = pend
      let n1 = if vimOpCount.len > 0: parseInt(vimOpCount) else: 1
      let n2 = if vimCount.len > 0: parseInt(vimCount) else: 1
      let n = min(1_000_000, n1 * n2)
      if (op.len == 1 and ch == op[0]) or (op == "gc" and ch == 'c') or (op in ["gu", "gU"] and ch in {'u', 'U'}) or
         (op == "g~" and ch == '~'):
        # dd cc yy >> << gcc guu
        vimPending = ""
        vimCount = ""
        vimOpCount = ""
        let e = min(b.lines.high, p.line + n - 1)
        b.vimApply(op, Pos(line: p.line, col: 0), Pos(line: e, col: 0), true, b.visColOfPos(p))
        if op != "y": vimIsChange = true
        if vimIsChange and vimMode == vmNormal and not vimReplaying: vimLastChange = vimRec
        return true
      if ch == 's' and op in ["y", "d", "c"]:
        vimPending = op & "s"
        vimOpCount = $n
        return true
      if ch in {'i', 'a'}:
        vimPending = op & $ch
        return true
      if ch in {'f', 't', 'F', 'T'}:
        vimPending = op & $ch
        return true
      if ch == 'g':
        vimPending = op & "g"
        return true
      let key = $ch
      if op.endsWith("g") and op.len == 2 and op[0] in {'d', 'c', 'y', '>', '<'}:
        discard
      # (vim's cw and cW change to the end of the word under the cursor — not ce, which runs on to the next word when
      # the cursor is already on this one's last character; the count counts words, so `2cw` on "the quick" changes
      # both and keeps the space after)
      var m: MotionRes
      if op == "c" and ch in {'w', 'W'} and p.col < b.lines[p.line].len and
         b.lines[p.line][p.col] notin {' ', '\t'}:
        var wend = b.currentWordEnd(p, ch == 'W')
        for _ in 1 ..< n: wend = b.wordEnd(wend, ch == 'W')
        m = MotionRes(ok: true, p: wend, inclusive: true)
      else:
        m = b.vimMotion(key, n, p)
      vimPending = ""
      vimCount = ""
      vimOpCount = ""
      if not m.ok: return true
      var e = m.p
      if m.inclusive: e.col += 1
      elif key in ["w", "W"] and e.col == 0 and e.line > p.line:
        # (w and W ending at a line's start stop at the previous line's end: `dw` on a line's last word deletes the
        # word, not the line break)
        e = Pos(line: e.line - 1, col: b.lines[e.line - 1].len)
      # (`$` — a to-the-line's-end motion — leaves the cursor at that end after a shift)
      b.vimApply(op, p, e, m.linewise, b.visColOfPos(p), toEol = key == "$")
      if op != "y": vimIsChange = true
      if vimIsChange and vimMode == vmNormal and not vimReplaying: vimLastChange = vimRec
      return true
  # text objects / find chars after an operator
  if vimPending.len >= 2 and vimPending[^1] in {'i', 'a'} and
     vimPending[0 ..< vimPending.len - 1] in ["d", "c", "y", ">", "<", "gu", "gU", "g~", "gc"]:
    let kind = vimPending[^1]
    let op = vimPending[0 ..< vimPending.len - 1]
    let (ok, a, e) = b.textObject(kind, ch, p)
    vimPending = ""
    vimCount = ""
    vimOpCount = ""
    if ok:
      # (whole lines — a paragraph, a plugin's line object —: linewise, as vim's own ip)
      let lw = b.objLinewise(ch, a, e)
      b.vimApply(op, a, (if lw: Pos(line: (if e.col == 0: e.line - 1 else: e.line), col: 0) else: e), lw,
                  b.visColOfPos(p))
      if op != "y":
        vimIsChange = true
        if vimMode == vmNormal and not vimReplaying: vimLastChange = vimRec
    return true
  if visual and vimPending.len == 1 and vimPending[0] in {'i', 'a'}:
    let (ok, a, e) = b.textObject(vimPending[0], ch, p)
    vimPending = ""
    if ok:
      if b.objLinewise(ch, a, e):
        vimSetMode(vmVLine)                          # (whole lines: visual-line mode, as vim's vip)
        b.setSingle(Pos(line: (if e.col == 0: e.line - 1 else: e.line), col: 0), a)
      else: b.setSingle(Pos(line: e.line, col: max(0, e.col - 1)), a)
    return true
  if vimPending.len > 0 and vimPending[^1] in {'f', 't', 'F', 'T'}:
    let op = vimPending[0 ..< vimPending.len - 1]
    let fk = vimPending[^1]
    vimPending = ""
    let n = min(1_000_000, max(1, (if vimCount.len > 0: parseInt(vimCount) else: 1)) *
                           max(1, (if vimOpCount.len > 0: parseInt(vimOpCount) else: 1)))
    vimCount = ""
    vimOpCount = ""
    var target = ""
    if k.kind == kChar and k.mods == {}: target.addUtf8(k.ch) else: target.add ch
    let m = b.vimMotion($fk & target, n, p)
    if not m.ok: return true
    if op.len > 0:
      var e = m.p
      if m.inclusive: e.col += 1
      b.vimApply(op, p, e, false, b.visColOfPos(p))
      if op != "y":
        vimIsChange = true
        if vimMode == vmNormal and not vimReplaying: vimLastChange = vimRec
    elif visual: b.cursors[b.prim].head = m.p
    else: b.setSingle(m.p)
    return true
  let count = if vimCount.len > 0: parseInt(vimCount) else: 1
  let hadCount = vimCount.len > 0
  vimCount = ""
  # plain motions
  let m = b.vimMotion($ch, count, p)
  if m.ok and ch notin {'d', 'c', 'y'}:
    if visual:
      # (visual-line takes whole lines: the head stands on the last character of the line it is on, so that the line is
      # inside the selection by the editor's own rule — a head at column 0 would leave that line out, and `V` `j` `>`
      # would not indent the line the cursor is on)
      b.cursors[b.prim].head = if vimMode == vmVLine:
                                 let l = m.p.line
                                 Pos(line: l, col: max(0, b.lines[l].len - 1))
                               else: m.p
    else:
      var np = m.p
      if m.keepCol:
        # (vim's remembered column: j and k come back to it over a short line and past a tab — it is the display column
        # the cursor is drawn at, and where it stands is what the next one remembers)
        if vimDesiredCol < 0: vimDesiredCol = b.visColOfPos(p)
        np.col = b.colAtVis(np.line, vimDesiredCol)
      else:
        vimDesiredCol = -1              # (any other motion: the remembered column is where it left the cursor)
      b.setSingle(b.clampNormal(np))
    return true
  # commands
  template change(body: untyped) =
    vimIsChange = true
    if vimUndoMark < 0: vimUndoMark = b.undoStack.len
    body
  case ch
  of 'i':
    if visual:
      vimPending = "i"
      return true
    change: vimSetMode(vmInsert)
  of 'a':
    if visual:
      vimPending = "a"
      return true
    change:
      if b.lines[p.line].len > 0: b.setSingle(Pos(line: p.line, col: p.col + 1))
      vimSetMode(vmInsert)
  of 'I':
    change:
      b.setSingle(b.firstNonBlank(p.line))
      vimSetMode(vmInsert)
  of 'A':
    change:
      b.setSingle(Pos(line: p.line, col: b.lines[p.line].len))
      vimSetMode(vmInsert)
  of 'o', 'O':
    if visual and ch == 'o':
      let c = b.cursors[b.prim]
      b.cursors[b.prim] = Cursor(anchor: c.head, head: c.anchor, goalX: -1)
      return true
    change:
      if ch == 'o': b.setSingle(Pos(line: p.line, col: b.lines[p.line].len))
      else:
        b.setSingle(Pos(line: p.line, col: 0))
      if ch == 'o': b.newline()
      else:
        b.beginEdit()
        let ind = leadingWs(b.lines[p.line])
        discard b.replaceText(Pos(line: p.line, col: 0), Pos(line: p.line, col: 0), ind & "\n")
        b.endEdit()
        b.setSingle(Pos(line: p.line, col: ind.len))
      vimSetMode(vmInsert)
  of 'v':
    if vimMode == vmVisual: vimSetMode(vmNormal)
    else:
      vimSetMode(vmVisual)
      b.setSingle(p)
  of 'V':
    if vimMode == vmVLine: vimSetMode(vmNormal)
    else:
      vimSetMode(vmVLine)
      vimVLineCol = b.visColOfPos(p)     # (where the cursor was drawn: `>` and `<` keep it)
      # (the head on the line's last character: visual-line takes whole lines, and a head at column 0 would leave its
      # own line out of the selection — see the plain motions above)
      b.setSingle(Pos(line: p.line, col: max(0, b.lines[p.line].len - 1)))
  of 'x', 'X', 's', 'S', 'C', 'D', 'Y':
    if visual and ch == 'S':
      vimPending = "S"                    # (vim-surround: S{char} puts a pair around the selection)
      return true
    if visual:
      let (a, e) = b.primary.range
      let lw = vimMode == vmVLine or ch in {'X', 'S', 'D', 'Y'}
      vimSetMode(vmNormal)
      let op = case ch
        of 'x', 'X', 'D': "d"
        of 's', 'S', 'C': "c"
        else: "y"
      if op != "y": vimIsChange = true
      b.vimApply(op, a, Pos(line: e.line, col: e.col + (if lw: 0 else: 1)), lw,
                 (if vimMode == vmVLine: vimVLineCol else: b.visColOfPos(b.primary.head)))
      if vimIsChange and vimMode == vmNormal and not vimReplaying: vimLastChange = vimRec
      return true
    case ch
    of 'x':
      vimIsChange = true
      if b.lines[p.line].len > 0:
        # (characters, not bytes: a multi-byte character is one, so x on `•` takes all of it)
        let e = rightRunes(b.lines[p.line], p.col, count, b.lines[p.line].len)
        b.vimApply("d", p, Pos(line: p.line, col: e), false)
    of 'X':
      vimIsChange = true
      if p.col > 0:
        # (vim's X leaves the cursor where it was, which is the last character when the line got shorter: column 5 of a
        # line that lost two characters is its new last one)
        let s = b.lines[p.line]
        let a = leftRunes(s, p.col, count)
        b.vimApply("d", Pos(line: p.line, col: a), p, false)
        # (the cursor stays on the character it was on, which the new line has at the deletion's start)
        b.setSingle(b.clampNormal(Pos(line: p.line, col: a)))
    of 's':
      vimIsChange = true
      let e = rightRunes(b.lines[p.line], p.col, count, b.lines[p.line].len)
      b.vimApply("c", p, Pos(line: p.line, col: e), false)
    of 'S':
      vimIsChange = true
      b.vimApply("c", p, Pos(line: min(b.lines.high, p.line + count - 1), col: 0), true)
    of 'C':
      # (vim leaves the cursor where the change starts: |col 5| of 1,5 -> `Col 4`, as the text is typed there)
      vimIsChange = true
      b.vimApply("c", p, Pos(line: p.line, col: b.lines[p.line].len), false)
    of 'D':
      vimIsChange = true
      b.vimApply("d", p, Pos(line: p.line, col: b.lines[p.line].len), false)
    else:
      b.vimApply("y", p, Pos(line: min(b.lines.high, p.line + count - 1), col: 0), true)
    if vimIsChange and vimMode == vmNormal and not vimReplaying: vimLastChange = vimRec
  of 'd', 'c', 'y', '>', '<', '~':
    if visual:
      let (a, e) = b.primary.range
      let lw = vimMode == vmVLine
      vimSetMode(vmNormal)
      if ch != 'y': vimIsChange = true
      b.vimApply($ch, a, (if lw: e else: Pos(line: e.line, col: e.col + 1)), lw,
                 (if lw: vimVLineCol else: b.visColOfPos(b.primary.head)))
      if vimIsChange and vimMode == vmNormal and not vimReplaying: vimLastChange = vimRec
      return true
    if ch == '~':
      vimIsChange = true
      let e = rightRunes(b.lines[p.line], p.col, count, b.lines[p.line].len)
      # (the toggled text may be a different length — ß and ẞ — so the cursor goes after it in the new text)
      let after = p.col + vimCaseMap(b.getText(p, Pos(line: p.line, col: e)), "~").len
      b.vimApply("~", p, Pos(line: p.line, col: e), false)
      b.setSingle(b.clampNormal(Pos(line: p.line, col: after)))
      if not vimReplaying: vimLastChange = vimRec
      return true
    vimPending = $ch
    vimOpCount = if hadCount: $count else: ""
  of 'p', 'P':
    vimIsChange = true
    if visual:
      let (a, e) = b.primary.range
      let txt = if cfgVimClipboard and clipGet().len > 0: clipGet() else: vimReg
      vimSetMode(vmNormal)
      b.beginEdit()
      let q = b.replaceText(a, Pos(line: e.line, col: e.col + 1), txt)
      b.endEdit()
      b.setSingle(b.clampNormal(q))
    else: b.vimPaste(ch == 'p', count)
    if not vimReplaying: vimLastChange = vimRec
  of 'u':
    if visual:
      let (a, e) = b.primary.range
      vimSetMode(vmNormal)
      b.vimApply("gu", a, Pos(line: e.line, col: e.col + 1), false)
    else:
      for _ in 0 ..< count: b.undo()
      b.setSingle(b.clampNormal(b.primary.head))
  of 'U':
    if visual:
      let (a, e) = b.primary.range
      vimSetMode(vmNormal)
      b.vimApply("gU", a, Pos(line: e.line, col: e.col + 1), false)
  of 'J':
    if not visual and p.line >= b.lines.high: return true     # (no line below: vim's J does nothing)
    vimIsChange = true
    # (vim's count joins count lines — J two, 3J three — so count-1 joins, at least one. The cursor is left where the
    # last join met: the end of the line before it)
    var at = Pos(line: p.line, col: b.lines[p.line].len)
    for _ in 0 ..< max(1, count - 1):
      at = Pos(line: b.primary.head.line, col: b.lines[b.primary.head.line].len)
      b.joinLines()
    b.setSingle(b.clampNormal(at))
    if not vimReplaying: vimLastChange = vimRec
  of 'r':
    vimPending = "r"
    vimCount = if hadCount: $count else: ""
  of 'R':
    vimIsChange = true
    vimSetMode(vmReplace)
  of 'f', 't', 'F', 'T':
    vimPending = $ch
    vimCount = if hadCount: $count else: ""
  of 'g', 'z':
    vimPending = $ch
    vimCount = if hadCount: $count else: ""
  of '.':
    # never inside a replay (a recorded '.' would repeat itself forever), and bounded: 99999. must not hang
    if vimLastChange.len > 0 and not vimReplaying:
      # (a count before `.` sets the count of the change, as typing it would: `3.` after `>>` is `3>>` — three lines —
      # and after `cw` it is `3cw`, the change's own count replaced. An insert is the exception: its count repeats the
      # text inserted, so its keys are played again `count` times)
      var keys = vimLastChange
      var first = 0
      while first < keys.len and keys[first].kind == kChar and keys[first].mods == {} and
            keys[first].ch in ord('0')..ord('9'):
        inc first
      let insertLike = first < keys.len and keys[first].kind == kChar and keys[first].mods == {} and
                       keys[first].ch in [ord('i'), ord('a'), ord('I'), ord('A'), ord('o'), ord('O')]
      var times = 1
      if hadCount:
        if insertLike: times = count
        else:
          var nk: seq[Key]
          for d in $count: nk.add Key(kind: kChar, ch: ord(d))
          for q in first ..< keys.len: nk.add keys[q]
          keys = nk
      vimReplaying = true
      try:
        for _ in 0 ..< min(times, max(1, 200_000 div max(1, keys.len))):
          for kk in keys:
            let k2 = kk
            if not vimKey(k2): editorKey(k2)
      finally:
        vimReplaying = false
  of 'n', 'N':
    if findQuery.len > 0: findStep((ch == 'n') != vimSearchBack)
  of '*', '#':
    let w = b.wordAt(p)
    if w.len > 0:
      findQuery = w
      findWord = true
      vimSearchBack = ch == '#'
      findStep(ch == '*')
  of '/', '?':
    vimSearchBack = ch == '?'
    openPrompt(pVimSearch, (if ch == '/': "/" else: "?"), "")
  of ':':
    openPrompt(pVimCmd, ":", (if visual: "'<,'>" else: ""))
    if visual: vimSetMode(vmNormal)
  of 'K': cmdHover()
  of 'q':
    if macroRecording: macroStop()             # q stops the recording
    elif not visual: vimPending = "q"
  of '@':
    vimPending = "@"
    vimCount = if hadCount: $count else: ""
  of 'w', 'b', 'e', 'W', 'B', 'E', 'h', 'l', 'j', 'k', '$', '^', '0', 'G', '{', '}', '%', 'H', 'M', 'L', ';', ',', '+', '-', '_':
    discard
  else: discard
  return true


proc vimEditorKey(k: Key): bool =
  ## entry from editorKey; false = let the normal editor handle the key
  if not cfgVim: return false
  if compOpen and vimMode == vmInsert:
    # (the completion list takes the keys typed — but Esc, Ctrl+[ and the escape sequence still leave insert mode in one
    # press, the list closing with it, as vim does; its first key may have opened the list)
    let esc = k.kind == kEsc or (k.kind == kChar and mCtrl in k.mods and k.ch in [ord('['), ord('c')])
    if not esc and not vimEscapeSeq(buf(), k): return false
    result = vimKey(if esc: k else: Key(kind: kEsc))
    vimShape()
    return
  result = vimKey(k)
  vimShape()
