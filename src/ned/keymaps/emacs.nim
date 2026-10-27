# ── the emacs keymap: C-f C-b C-n C-p · C-a C-e · M-f M-b · C-v M-v · M-< M-> · C-k C-w M-w C-y · C-SPC mark ·
#    C-s · M-% · C-/ · C-x C-s / C-f / C-w / b / k / u / h / o / 2 / 3 / 1 / C-c · M-g g · M-x · M-; · C-l ──

proc emacsMove(kind: KeyKind, word = false) =
  let b = buf()
  if not emacsMark and b.primary.hasSel: b.setSingle(b.primary.head)
  cmdMove(kind, emacsMark, word)

proc emacsKill() =
  ## C-k: to the end of the line (the line break when there is nothing else); C-k again adds to the same kill
  let b = buf()
  if not b.canEdit(): return
  let p = b.primary.head
  let e = if p.col < b.lines[p.line].len: Pos(line: p.line, col: b.lines[p.line].len)
          elif p.line < b.lines.high: Pos(line: p.line + 1, col: 0)
          else: p
  if e == p: return
  let txt = b.getText(p, e)
  let again = msSince(emacsKillAt) < 1500 and clipParts.len == 1 and not clipLineMode
  let kill = if again: clipParts[0] & txt else: txt
  clipParts = @[kill]
  clipLineMode = false
  clipSet(kill)
  b.beginEdit()
  discard b.replaceText(p, e, "")
  b.endEdit()
  b.setSingle(p)
  emacsKillAt = getMonoTime()

proc emacsCaseWord(mode: char) =
  ## M-u / M-l / M-c: the word after the cursor in upper case, lower case, or Capitalised
  let b = buf()
  if not b.canEdit(): return
  let p = b.primary.head
  let e = b.posWordRight(p)
  if e == p: return
  let w = b.getText(p, e)
  var r = w
  case mode
  of 'u': r = w.toUpperAscii
  of 'l': r = w.toLowerAscii
  else:
    r = w.toLowerAscii
    for i in 0 ..< r.len:
      if r[i].isAlphaAscii:
        r[i] = r[i].toUpperAscii
        break
  b.beginEdit()
  discard b.replaceText(p, e, r)
  b.endEdit()
  b.setSingle(e)

proc emacsKey(k: Key): bool =
  ## true when the emacs keymap took the key (the editor has the focus)
  let b = buf()
  let ctrl = mCtrl in k.mods
  let alt = mAlt in k.mods
  let c = if k.kind == kChar and k.ch < 128: toLowerAscii(char(k.ch)) else: '\0'
  let raw = if k.kind == kChar and k.ch < 128: char(k.ch) else: '\0'
  if emacsPrefix == "C-x":
    emacsPrefix = ""
    if ctrl:
      case c
      of 's': runCmd("Save")
      of 'f': runCmd("Open file…")
      of 'w': runCmd("Save as…")
      of 'c': runCmd("Quit")
      of 'x':                                       # exchange point and mark
        let (a, e) = (b.primary.anchor, b.primary.head)
        b.setSingle(a, e)
      else: info("C-x C-" & $c & " is not bound")
    else:
      case raw
      of 'b': runCmd("Switch buffer…")
      of 'k': runCmd("Close tab")
      of 'u': b.undo()
      of 'h': b.setSingle(Pos(line: b.lines.high, col: b.lines[^1].len), Pos())
      of 'o': runCmd("View: focus next pane")
      of '2': runCmd("View: split editor down")
      of '3': runCmd("View: split editor right")
      of '1': runCmd("View: close the other panes")
      of '0': runCmd("View: close this pane")
      of '(': (if not macroRecording: macroStart())       # keyboard macro: C-x ( records, C-x ) stops, C-x e plays
      of ')': macroStop(prefixKeys = 1)
      of 'e': macroPlay(macroLast)
      else: info("C-x " & $raw & " is not bound")
    return true
  if emacsPrefix == "M-g":
    emacsPrefix = ""
    if c in {'g', 'l'}: runCmd("Go to line…")
    elif c == 'n': runCmd("Next problem")
    elif c == 'p': runCmd("Previous problem")
    return true
  if ctrl and not alt and k.kind == kChar:
    case c
    of 'f': emacsMove(kRight)
    of 'b': emacsMove(kLeft)
    of 'n': emacsMove(kDown)
    of 'p': emacsMove(kUp)
    of 'a': emacsMove(kHome)
    of 'e': emacsMove(kEnd)
    of 'v': emacsMove(kPgDn)
    of 'd': b.deleteForward(false)
    of 'k': emacsKill()
    of 'w':
      if b.primary.hasSel: copySel(true)
      emacsMark = false
    of 'y': paste()
    of ' ', '@':
      emacsMark = true
      b.setSingle(b.primary.head, b.primary.head)
      info("Mark set")
    of 'g':
      emacsMark = false
      if b.primary.hasSel or b.cursors.len > 1: b.setSingle(b.primary.head)
      closeComp()
      info("Quit")
    of 's', 'r': runCmd("Find")
    of '/', '_', '7': b.undo()
    of 'l': b.centerOn(b.primary.head)
    of 'o':
      let p = b.primary.head
      b.insertText("\n")
      b.setSingle(p)
    of 't':                                           # transpose the characters around the cursor
      let p = b.primary.head
      let s = b.lines[p.line]
      if s.len >= 2 and b.canEdit():
        let at = if p.col >= s.len: s.len - 1 else: max(1, p.col)
        b.beginEdit()
        discard b.replaceText(Pos(line: p.line, col: at - 1), Pos(line: p.line, col: at + 1), $s[at] & $s[at - 1])
        b.endEdit()
        b.setSingle(Pos(line: p.line, col: at + 1))
    of 'x': emacsPrefix = "C-x"
    of 'j': b.newline()
    else: return false
    return true
  if alt and not ctrl and k.kind == kChar:
    case raw
    of 'f', 'F': emacsMove(kRight, true)
    of 'b', 'B': emacsMove(kLeft, true)
    of 'v', 'V': emacsMove(kPgUp)
    of '<': (b.setSingle(Pos(), (if emacsMark: b.primary.anchor else: Pos(line: -1))); b.ensureVisible())
    of '>':
      b.setSingle(Pos(line: b.lines.high, col: b.lines[^1].len), (if emacsMark: b.primary.anchor else: Pos(line: -1)))
      b.ensureVisible()
    of 'd': b.deleteForward(true)
    of 'w':
      if b.primary.hasSel: copySel(false)
      emacsMark = false
      b.setSingle(b.primary.head)
    of 'x': runCmd("Command palette")
    of '%': runCmd("Replace")
    of ';': b.toggleComment()
    of 'u', 'l', 'c': emacsCaseWord(raw)
    of 'g': emacsPrefix = "M-g"
    of '/': startCompletion(true)
    of '_': b.redo()
    else: return false
    return true
  if k.kind in {kLeft, kRight, kUp, kDown, kHome, kEnd, kPgUp, kPgDn} and emacsMark and k.mods == {}:
    cmdMove(k.kind, true, false)
    return true
  if emacsMark and k.kind in {kChar, kBackspace, kDelete, kEnter, kPaste}: emacsMark = false
  false
