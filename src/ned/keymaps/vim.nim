# ════════════════════════════════════════════════════════════════════════════
#  Vim mode (editor.vimMode): normal · insert · visual · visual-line · replace
# ════════════════════════════════════════════════════════════════════════════

var
  vimPending = ""
  vimCount = ""
  vimOpCount = ""
  vimLastFind = ('\0', '\0')
  vimReg = ""
  vimRegLine = false
  vimRec: seq[Key]
  vimLastChange: seq[Key]
  vimIsChange = false
  vimReplaying = false
  vimEscAt: MonoTime
  vimEscChar = '\0'
  vimCursorShape = ""
  vimSurRange: (Pos, Pos)          # (vim-surround: what ys{motion} goes around, until its character)
  vimDesiredCol = -1               # (vim's remembered *display* column, counted from 1 as virtcol is: j and k go back
                                   # to it over short lines and past a tab; -1: none)

proc vimModeName(): string =
  ## the mode shown in the status bar for the keymap in use: NORMAL / INSERT / VISUAL / V-LINE / REPLACE for vim (with
  ## the count and operator typed so far), NOR / SEL / INS for helix, the pending prefix or Mark for emacs, "" for the
  ## default keymap
  if cfgKeymap == "helix":
    return (case hxMode
            of hxInsert: "INS"
            of hxSelect: "SEL"
            else: "NOR") & (if hxPending.len > 0: " " & hxCount & hxPending elif hxCount.len > 0: " " & hxCount else: "")
  if cfgKeymap == "emacs": return (if emacsPrefix.len > 0: emacsPrefix & "-" elif emacsMark: "Mark" else: "")
  if not cfgVim: return ""
  case vimMode
  of vmNormal: (if vimPending.len > 0: "NORMAL " & vimCount & vimPending else: "NORMAL")
  of vmInsert: "INSERT"
  of vmVisual: "VISUAL"
  of vmVLine: "V-LINE"
  of vmReplace: "REPLACE"

proc vimShape() =
  ## sets the terminal's cursor shape for the mode — the user's own in insert mode, a steady block in normal and visual,
  ## an underline in replace — writing the escape sequence only when it changes
  if not gRaw: return
  let want = if cfgKeymap == "helix": (if hxMode == hxInsert: cursorStyleSeq() else: "\e[2 q")
             elif not cfgVim or vimMode in {vmInsert}: cursorStyleSeq() elif vimMode == vmReplace: "\e[4 q" else: "\e[2 q"
  if want != vimCursorShape:
    writeAll(want)
    vimCursorShape = want

var vimUndoMark = -1

proc mergeUndo(b: Buffer, mark: int) =
  ## an insert session (or c/s/o + typing) undoes as one step, like Vim
  if mark < 0 or b.undoStack.len - mark < 2: return
  var g = b.undoStack[mark]
  let n = b.undoStack.len
  for i in mark + 1 .. b.undoStack.high:
    g.ops.add b.undoStack[i].ops
    g.after = b.undoStack[i].after
    g.seqId = b.undoStack[i].seqId
  b.undoStack.setLen(mark)
  b.undoStack.add g
  # (undo-tree branches off the steps merged: the states between them are gone; one off the last is off the merged)
  var k = 0
  while k < b.undoBranches.len:
    let at = b.undoBranches[k].at
    if at > mark and at < n: b.undoBranches.delete(k)
    else:
      if at == n: b.undoBranches[k].at = mark + 1
      inc k

proc vimSetMode(m: VimMode) =
  ## changes the vim mode; entering insert or replace marks where the undo stack stood, so what is typed there undoes as
  ## one step (see mergeUndo), and sets the cursor's shape
  if m in {vmInsert, vmReplace} and vimUndoMark < 0: vimUndoMark = buf().undoStack.len
  vimMode = m
  vimShape()
  needRender = true

proc vimMouseClick() =
  ## a mouse click while selecting in visual mode ends it, back to normal mode
  if cfgVim and vimMode in {vmVisual, vmVLine}: vimSetMode(vmNormal)

proc clampNormal(b: Buffer, p: Pos): Pos =
  ## the position kept inside the buffer and, as in vim's normal mode, on a character of its line — not past the last
  ## one
  result = b.clampPos(p)
  let n = b.lines[result.line].len
  if n > 0 and result.col >= n: result.col = n - 1

proc vimYank(text: string, linewise: bool) =
  ## puts text in vim's unnamed register (and whether it was whole lines); with vim.useSystemClipboard on, the system
  ## clipboard and ned's own as well
  vimReg = text
  vimRegLine = linewise
  if cfgVimClipboard:
    clipSet(text)
    clipParts = @[text]
    clipLineMode = linewise


const vimBlank = {' ', '\t', '\0', '\x0b', '\x0c', '\r', '\n'}   # (vim's iswhite(): what ^ and gg/G skip)

func vimCharClass(c: char): int {.inline.} =
  ## vim's class of a character for its word motions: 0 a blank (vim's iswhite()), 1 a character of a word, 2
  ## punctuation. The editor's own charClass counts only a space and a tab as blanks, which is right for its word moves
  ## and not for vim's (a leading tab is blank, not punctuation, so `w` crosses it)
  if c in vimBlank: 0 elif isWordByte(c): 1 else: 2

proc nextWordStart(b: Buffer, p: Pos, big: bool): Pos =
  ## vim's w / W: leaves the run of characters of the same class (any non-blank for a WORD) under the position, skips
  ## blanks and line breaks, and stops at the next word's start — or on an empty line
  var l = p.line
  var c = p.col
  let s0 = b.lines[l]
  if c < s0.len:
    let cls = if big: (if s0[c] in vimBlank: 0 else: 1) else: vimCharClass(s0[c])
    while c < s0.len and (if big: (if s0[c] in vimBlank: 0 else: 1) else: vimCharClass(s0[c])) == cls and cls != 0: inc c
  while true:
    let s = b.lines[l]
    while c < s.len and s[c] in vimBlank: inc c
    if c < s.len: return Pos(line: l, col: c)
    if l >= b.lines.high: return Pos(line: l, col: s.len)
    inc l
    c = 0
    if b.lines[l].len == 0: return Pos(line: l, col: 0)

func prevWordStart(b: Buffer, p: Pos, big: bool): Pos =
  ## vim's b / B: back over blanks and line ends, then to the first character of the word (WORD) found; an empty line
  ## counts as a stop
  var l = p.line
  var c = min(p.col, b.lines[l].len) - 1
  while true:
    let s = b.lines[l]
    while c >= 0 and s[c] in vimBlank: dec c
    if c >= 0:
      let cls = if big: 1 else: charClass(s[c])
      while c > 0 and (if big: (if s[c - 1] in {' ', '\t'}: 0 else: 1) else: charClass(s[c - 1])) == cls: dec c
      return Pos(line: l, col: c)
    if l == 0: return Pos(line: 0, col: 0)
    dec l
    c = b.lines[l].len - 1
    if b.lines[l].len == 0: return Pos(line: l, col: 0)

proc wordEnd(b: Buffer, p: Pos, big: bool): Pos =
  ## vim's e / E: the last character of the next word (WORD) after the position, over blanks and line breaks
  var l = p.line
  var c = p.col + 1
  while true:
    let s = b.lines[l]
    while c < s.len and s[c] in vimBlank: inc c
    if c < s.len:
      let cls = if big: 1 else: vimCharClass(s[c])
      while c + 1 < s.len and (if big: (if s[c + 1] in vimBlank: 0 else: 1) else: vimCharClass(s[c + 1])) == cls: inc c
      return Pos(line: l, col: c)
    if l >= b.lines.high: return Pos(line: l, col: max(0, s.len - 1))
    inc l
    c = 0

# the position of the first character of the line that is not a space or tab (the line's end for a blank line)
func firstNonBlank(b: Buffer, l: int): Pos = Pos(line: l, col: leadingWs(b.lines[l]).len)


proc firstNonBlankVim(b: Buffer, l: int): Pos =
  ## vim's first non-blank: a space, a tab, a form feed, a vertical tab and a carriage return are blanks there (ned's
  ## own firstNonBlank, for the editor, skips only spaces and tabs)
  var c = 0
  while c < b.lines[l].len and b.lines[l][c] in vimBlank: inc c
  Pos(line: l, col: c)

proc colAtVis(b: Buffer, l: int, vcol: int): int =
  ## the character column of a line that sits at display column `vcol` (from 1, as vim's virtcol), as vim's j and k put
  ## the cursor: the
  ## first character whose display position is at or after it — a tab covers the columns up to its stop, so a column
  ## inside one is the tab itself (vim's j from a column of 8 lands on a tab at the start of the next line). `visColAt`
  ## is the editor's own, so the same tab stops are used as the screen's cursor.
  let s = b.lines[l]
  for c in 0 ..< s.len:
    # (the character whose span covers that column: it starts at or before it and does not end before it)
    let start = b.visColAt(l, c) + 1
    if start >= vcol: return c
    if s[c] == '\t' and start + b.tabOf - (start - 1) mod b.tabOf > vcol: return c
  max(0, s.len - 1)

proc visColOfPos(b: Buffer, p: Pos): int =
  ## the display column the cursor is drawn at, as the editor draws it; a tab counts as the column it ends at (vim's
  ## virtcol), everything else as the column it starts at
  # (a display column counted from 1, as vim's virtcol: the cursor on a tab is at the last column the tab covers)
  let c = min(p.col, b.lines[p.line].len)
  if c < b.lines[p.line].len and b.lines[p.line][c] == '\t':
    let v = b.visColAt(p.line, c) + 1
    return v + b.tabOf - 1 - (v - 1) mod b.tabOf
  b.visColAt(p.line, c) + 1

proc paragraphMove(b: Buffer, p: Pos, d: int): Pos =
  ## vim's } and { (d is 1 or -1): over the blank lines and then the text lines in that direction to the start of the
  ## next blank run, or to the buffer's first or last line
  var l = p.line + d
  while l > 0 and l < b.lines.high and isBlank(b.lines[l]): l += d
  while l > 0 and l < b.lines.high and not isBlank(b.lines[l]): l += d
  Pos(line: clamp(l, 0, b.lines.high), col: 0)

func findChar(b: Buffer, p: Pos, cmd, ch: char): (bool, Pos) =
  ## vim's f, t, F and T on the cursor's line: (found, where the cursor goes) — t and T stop one short of the character,
  ## and when already next to it look for the one after
  let s = b.lines[p.line]
  let col = min(p.col, s.len)          # (a cursor past the end of a line that got shorter)
  case cmd
  of 'f', 't':
    let i = s.find(ch, col + 1 + (if cmd == 't' and col + 1 < s.len and s[col + 1] == ch: 1 else: 0))
    if i < 0: return (false, p)
    (true, Pos(line: p.line, col: (if cmd == 't': i - 1 else: i)))
  else:
    let start = col - 1 - (if cmd == 'T' and col - 1 >= 0 and s[col - 1] == ch: 1 else: 0)
    if start < 0: return (false, p)
    let i = s.rfind(ch, last = start)
    if i < 0: return (false, p)
    (true, Pos(line: p.line, col: (if cmd == 'T': i + 1 else: i)))

type MotionRes = object
  ok: bool
  p: Pos
  linewise, inclusive: bool
  keepCol: bool          # (j and k: the column the cursor came from is the one kept, see vimDesiredCol)

proc vimMotion(b: Buffer, key: string, count: int, p0: Pos): MotionRes =
  ## position after a motion; `key` is one or two characters
  result.ok = true
  # (a cursor left past the end of a line that got shorter counts from the line's end)
  let p = Pos(line: clamp(p0.line, 0, b.lines.high), col: clamp(p0.col, 0, b.lines[clamp(p0.line, 0, b.lines.high)].len))
  var q = p
  case key
  of "h":
    q.col = max(0, p.col - count)
  of "l", " ":
    q.col = min(max(0, b.lines[p.line].len - (if vimPending.len > 0: 0 else: 1)), p.col + count)
  of "j", "+":
    q.line = min(b.lines.high, p.line + count)
    result.linewise = true
    result.keepCol = true
    if key == "+": q = b.firstNonBlank(q.line)
    elif vimDesiredCol >= 0: q.col = b.colAtVis(q.line, vimDesiredCol)
  of "k", "-":
    q.line = max(0, p.line - count)
    result.linewise = true
    result.keepCol = true
    if key == "-": q = b.firstNonBlank(q.line)
    elif vimDesiredCol >= 0: q.col = b.colAtVis(q.line, vimDesiredCol)
  of "w", "W":
    for _ in 0 ..< count: q = b.nextWordStart(q, key == "W")
    if vimPending in ["c"] and q.line > p.line:
      q = Pos(line: p.line, col: b.lines[p.line].len)
  of "b", "B":
    for _ in 0 ..< count: q = b.prevWordStart(q, key == "B")
  of "e", "E":
    for _ in 0 ..< count: q = b.wordEnd(q, key == "E")
    result.inclusive = true
  of "0": q.col = 0
  of "^", "_": q = b.firstNonBlankVim(p.line)
  of "$":
    q.line = min(b.lines.high, p.line + count - 1)
    q.col = max(0, b.lines[q.line].len - (if vimPending.len > 0: 0 else: 1))
    if vimPending.len > 0: q.col = b.lines[q.line].len
  of "gg", "G":
    # (the line: the first or the last, or with a count that line; the column: the display column the cursor was drawn
    # at, which vim's jumps keep — `2G` from the middle of a line stays in the middle of the line)
    q = Pos(line: if count > 1: clamp(count - 1, 0, b.lines.high) else: (if key == "gg": 0 else: b.lines.high),
            col: b.colAtVis(if count > 1: clamp(count - 1, 0, b.lines.high) else: (if key == "gg": 0 else: b.lines.high),
                            b.visColOfPos(p)))
    result.linewise = true
  of "}":
    for _ in 0 ..< count: q = b.paragraphMove(q, 1)
  of "{":
    for _ in 0 ..< count: q = b.paragraphMove(q, -1)
  of "%":
    let (ok, a, e) = b.matchBracket(p)
    if not ok:
      result.ok = false
      return
    q = if p == a or p.col == a.col + 1: e else: a
    result.inclusive = true
  of "H": q = b.firstNonBlank(clamp(b.topLine + cfgScrollOff, 0, b.lines.high))
  of "M": q = b.firstNonBlank(clamp(b.topLine + textH div 2, 0, b.lines.high))
  of "L": q = b.firstNonBlank(clamp(b.topLine + textH - 1 - cfgScrollOff, 0, b.lines.high))
  else:
    if key.len == 2 and key[0] in {'f', 't', 'F', 'T'}:
      vimLastFind = (key[0], key[1])
      for _ in 0 ..< count:
        let (ok, np) = b.findChar(q, key[0], key[1])
        if not ok:
          result.ok = false
          return
        q = np
      result.inclusive = key[0] in {'f', 't'}
    elif key in [";", ","]:
      if vimLastFind[0] == '\0':
        result.ok = false
        return
      var cmd = vimLastFind[0]
      if key == ",":
        cmd = case cmd
          of 'f': 'F'
          of 'F': 'f'
          of 't': 'T'
          else: 't'
      for _ in 0 ..< count:
        let (ok, np) = b.findChar(q, cmd, vimLastFind[1])
        if not ok:
          result.ok = false
          return
        q = np
      result.inclusive = cmd in {'f', 't'}
    else:
      result.ok = false
      return
  result.p = q

func objLinewise(b: Buffer, obj: char, a, e: Pos): bool =
  ## a text object of whole lines (a paragraph; a plugin's from a line's start to a later one's, or to the end):
  ## operators take it as lines
  obj == 'p' or (a.col == 0 and e.line > a.line and
                 (e.col == 0 or (e.line == b.lines.high and e.col == b.lines[e.line].len)))

proc textObject(b: Buffer, kind, obj: char, p: Pos): (bool, Pos, Pos) =
  ## iw aw i( a( i[ i{ i< i" i' i` ip ap  (returns a half-open range) — and plugins' (ie …)
  if plugTextObjKeys.len > 0 and ($kind & $obj) in plugTextObjKeys:
    let (_, ok, a, e) = plugTextObject(b, kind, obj, p)
    return (ok, a, e)
  if obj == 'p':
    # a paragraph: the lines around that are not blank (on a blank line: the blank ones); ap with the blank lines
    # after it (or before it, at the end)
    let blank = b.lines[p.line].strip.len == 0
    var a = p.line
    var e = p.line
    while a > 0 and (b.lines[a - 1].strip.len == 0) == blank: dec a
    while e < b.lines.high and (b.lines[e + 1].strip.len == 0) == blank: inc e
    if kind == 'a':
      if e < b.lines.high:
        while e < b.lines.high and (b.lines[e + 1].strip.len == 0) != blank: inc e
      else:
        while a > 0 and (b.lines[a - 1].strip.len == 0) != blank: dec a
    return (true, Pos(line: a, col: 0),
            (if e < b.lines.high: Pos(line: e + 1, col: 0) else: Pos(line: e, col: b.lines[e].len)))
  let s = b.lines[p.line]
  case obj
  of 'w', 'W':
    var (a, e) = b.wordRangeAt(p)
    if a == e: return (false, p, p)
    if kind == 'a':
      while e.col < s.len and s[e.col] in {' ', '\t'}: inc e.col
    return (true, a, e)
  of '"', '\'', '`':
    if s.len == 0: return (false, p, p)
    var i = s.rfind(obj, last = min(p.col, s.len - 1))
    if i < 0 or (i == p.col and s.find(obj, p.col + 1) < 0): i = s.rfind(obj, last = clamp(p.col - 1, 0, s.len - 1))
    let j = s.find(obj, max(i + 1, if i == p.col: p.col + 1 else: p.col))
    if i < 0 or j < 0 or j <= i: return (false, p, p)
    if kind == 'i': return (true, Pos(line: p.line, col: i + 1), Pos(line: p.line, col: j))
    return (true, Pos(line: p.line, col: i), Pos(line: p.line, col: j + 1))
  else:
    let (op, cl) = case obj
      of '(', ')', 'b': ('(', ')')
      of '[', ']': ('[', ']')
      of '{', '}', 'B': ('{', '}')
      of '<', '>': ('<', '>')
      else: ('\0', '\0')
    if op == '\0': return (false, p, p)
    # walk back to the unmatched opener
    var depth = 0
    var l = p.line
    var c = p.col
    var found = false
    var oa: Pos
    while l >= 0 and not found:
      let t = b.lines[l]
      if c >= t.len: c = t.len - 1
      while c >= 0:
        if t[c] == cl and not (l == p.line and c == p.col): inc depth
        elif t[c] == op:
          if depth == 0:
            found = true
            oa = Pos(line: l, col: c)
            break
          dec depth
        dec c
      if not found:
        dec l
        if l >= 0: c = b.lines[l].len - 1
    if not found: return (false, p, p)
    let (ok, a, e) = b.matchBracket(oa)
    if not ok: return (false, p, p)
    let closeP = if a == oa: e else: a
    if kind == 'i':
      var ia = Pos(line: oa.line, col: oa.col + 1)
      var ie = closeP
      if ia.col >= b.lines[ia.line].len and ia.line < ie.line: ia = Pos(line: ia.line + 1, col: 0)
      return (true, ia, ie)
    (true, oa, Pos(line: closeP.line, col: closeP.col + 1))

proc vimApply(b: Buffer, op: string, a0, e0: Pos, linewise: bool) =
  ## does a vim operator on a range: y (yank), d and c (delete, c then enters insert mode), > and < (indent), ~ gu gU
  ## (case) and gc (comment); a linewise range is widened to whole lines, and d / c also fill the unnamed register
  var a = b.clampPos(a0)            # "one past the selection" may lie past the end of the line
  var e = b.clampPos(e0)
  if e < a: swap(a, e)
  if linewise:
    a = Pos(line: a.line, col: 0)
    e = if e.line < b.lines.high: Pos(line: e.line + 1, col: 0) else: Pos(line: e.line, col: b.lines[e.line].len)
  let text = b.getText(a, e)
  case op
  of "y":
    vimYank((if linewise and not text.endsWith("\n"): text & "\n" else: text), linewise)
    b.setSingle(b.clampNormal(a0.minP(e0)))
  of "d", "c":
    if not b.canEdit(): return
    if op == "c" and vimUndoMark < 0: vimUndoMark = b.undoStack.len
    vimYank((if linewise and not text.endsWith("\n"): text & "\n" else: text), linewise)
    b.beginEdit()
    if linewise and op == "d" and e.col == b.lines[e.line].len and e.line == b.lines.high and a.line > 0:
      # deleting the last lines: also remove the newline before them
      a = Pos(line: a.line - 1, col: b.lines[a.line - 1].len)
    if linewise and op == "c":
      let ind = leadingWs(b.lines[a.line])
      let ee = if e.col == 0 and e.line > a.line: Pos(line: e.line - 1, col: b.lines[e.line - 1].len) else: e
      let p = b.replaceText(a, ee, ind)
      b.endEdit()
      b.setSingle(p)
    else:
      let p = b.replaceText(a, e, "")
      b.endEdit()
      # (vim leaves the cursor on the last character of what is left before the deletion — `D` from column 5 on
      # "abcdef" is column 4 — and a `c` leaves it where the change starts, for the text about to be typed)
      b.setSingle(if op == "d": b.clampNormal(if linewise: b.firstNonBlank(min(p.line, b.lines.high))
                                              else: Pos(line: a.line, col: max(0, a.col - 1)))
                                  else: p)
    if op == "c": vimSetMode(vmInsert)
  of ">", "<":
    # (vim moves the text under the cursor, not the cursor: it stays in the display column it was drawn at — `>>` on the
    # first non-blank of the line, `> w` and `> j` wherever the motion put it. A cell the shift made empty is the last
    # character of the line)
    let want = a0.minP(e0)
    let vcol = b.visColAt(want.line, want.col) + 1
    # (the lines the widened range covers, both ends included: the selection must not end at column 0 of a line, which
    # the editor reads as "that line is not selected" — `V` `j` `>` on the last two lines of the file)
    let lastL = (if linewise and e.col == 0 and e.line > a.line: e.line - 1 else: e.line)
    b.setSingle(Pos(line: lastL, col: max(0, b.lines[lastL].len - 1)), Pos(line: a.line, col: 0))
    b.indentLines(if op == ">": 1 else: -1)
    let line = if linewise: min(a0.line, e0.line) else: want.line
    b.setSingle(b.clampNormal(Pos(line: line, col: b.colAtVis(line, vcol))))
  of "~", "gu", "gU":
    if not b.canEdit(): return
    var t = ""
    for ch in text:
      t.add (if op == "gu": toLowerAscii(ch) elif op == "gU": toUpperAscii(ch)
             elif ch in {'a'..'z'}: toUpperAscii(ch) elif ch in {'A'..'Z'}: toLowerAscii(ch) else: ch)
    b.beginEdit()
    discard b.replaceText(a, e, t)
    b.endEdit()
    b.setSingle(b.clampNormal(a))
  of "gc":
    b.setSingle(Pos(line: e0.line, col: 0), Pos(line: a0.line, col: 0))
    b.toggleComment()
    b.setSingle(b.firstNonBlank(min(a0.line, e0.line)))
  else: discard

proc vimPaste(b: Buffer, after: bool, count: int) =
  ## vim's p and P: puts the unnamed register (the system clipboard instead when vim.useSystemClipboard is on and it holds
  ## something else) `count` times after or before the cursor — whole lines below or above the line, else in the text —
  ## and leaves the cursor as vim does
  var text = vimReg
  var linewise = vimRegLine
  if cfgVimClipboard:
    let c = clipGet()
    if c.len > 0 and c != vimReg:
      text = c
      linewise = c.endsWith("\n")
  if text.len == 0 or not b.canEdit(): return
  var t = ""
  for _ in 0 ..< clamp(count, 1, max(1, 50_000_000 div max(1, text.len))): t.add text   # never a runaway paste
  let p = b.primary.head
  b.beginEdit()
  if linewise:
    if not t.endsWith("\n"): t.add "\n"
    if after:
      if p.line == b.lines.high:
        discard b.replaceText(Pos(line: p.line, col: b.lines[p.line].len), Pos(line: p.line, col: b.lines[p.line].len),
                              "\n" & t[0 ..< t.len - 1])
      else: discard b.replaceText(Pos(line: p.line + 1, col: 0), Pos(line: p.line + 1, col: 0), t)
      b.endEdit()
      b.setSingle(b.firstNonBlank(p.line + 1))
    else:
      discard b.replaceText(Pos(line: p.line, col: 0), Pos(line: p.line, col: 0), t)
      b.endEdit()
      b.setSingle(b.firstNonBlank(p.line))
  else:
    let at = if after and b.lines[p.line].len > 0: Pos(line: p.line, col: min(b.lines[p.line].len, p.col + 1)) else: p
    let e = b.replaceText(at, at, t)
    b.endEdit()
    b.setSingle(b.clampNormal(Pos(line: e.line, col: max(0, e.col - 1))))
