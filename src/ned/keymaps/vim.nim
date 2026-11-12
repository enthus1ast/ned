# ════════════════════════════════════════════════════════════════════════════
#  Vim mode (editor.vimMode): normal · insert · visual · visual-line · replace
# ════════════════════════════════════════════════════════════════════════════

var
  vimPending = ""
  vimCount = ""
  vimOpCount = ""
  vimLastFind = ('\0', "")          # (the f/t command and its target, which may be a multi-byte character)
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
  vimVLineCol = 0                  # (visual-line: the display column `V` was pressed at, which `>` and `<` keep)
  vimPrevSel: tuple[ok: bool, mode: VimMode, anchor, head: Pos, vcol: int] = (false, vmVisual, Pos(), Pos(), 0)
                                   # (the last visual selection, for gv)

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

func currentWordEnd(b: Buffer, p: Pos, big: bool): Pos =
  ## the last character of the run of the same class (a WORD for big) under the cursor — what vim's cw and cW change
  ## to, which is not ce when the cursor is already on a word's last character
  let s = b.lines[p.line]
  if p.col >= s.len: return p
  let cls = if big: (if s[p.col] in vimBlank: 0 else: 1) else: vimCharClass(s[p.col])
  if cls == 0: return p
  var c = p.col
  while c + 1 < s.len and
        (if big: (if s[c + 1] in vimBlank: 0 else: 1) else: vimCharClass(s[c + 1])) == cls:
    inc c
  Pos(line: p.line, col: c)

func rightRunes(s: string, col, n, limit: int): int =
  ## the byte column `n` characters to the right of `col` — a multi-byte character counts as one, as vim's l does —
  ## not past `limit`
  result = col
  for _ in 0 ..< n:
    if result >= limit: break
    result = nextRune(s, result)

func leftRunes(s: string, col, n: int): int =
  ## the byte column `n` characters to the left of `col`, a multi-byte character counting as one (vim's h)
  result = col
  for _ in 0 ..< n:
    if result <= 0: break
    result = prevRune(s, result)

func vimUpperRune(r: unicode.Rune): unicode.Rune =
  ## vim's upper case for one rune: Nim's Unicode table, and ß → ẞ, which it leaves (vim does not)
  let u = unicode.toUpper(r)
  if u.int != r.int: return u
  if r.int == 0x00DF: return unicode.Rune(0x1E9E)
  r

func vimToggleRune(r: unicode.Rune): unicode.Rune =
  ## vim's ~ for one rune: the upper case of a lower one, the lower case of an upper one, itself otherwise
  let up = vimUpperRune(r)
  if up.int != r.int: return up
  unicode.toLower(r)

func vimCaseMap(s: string, op: string): string =
  ## `s` with vim's case mapping: gu lower, gU upper, ~ and g~ swapped — rune by rune, so ü ↔ Ü and ß ↔ ẞ
  var i = 0
  while i < s.len:
    let (cp, n) = runeAt(s, i)
    let r = unicode.Rune(cp)
    let m = (if op == "gu": unicode.toLower(r) elif op == "gU": vimUpperRune(r) else: vimToggleRune(r))
    result.addUtf8(m.int)
    i += n

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
  ## vim's } and { (d is 1 or -1): to the paragraph boundary in that direction — the blank line after (before) the
  ## paragraph, or the buffer's first (last) line; from a blank line, over the blanks and the next paragraph to the
  ## boundary beyond it. At the buffer's end the cursor goes to the last character, as vim's }
  var l = p.line
  let blank = isBlank(b.lines[l])
  if d > 0:
    if blank:
      while l + 1 <= b.lines.high and isBlank(b.lines[l + 1]): inc l
      while l + 1 <= b.lines.high and not isBlank(b.lines[l + 1]): inc l
    else:
      while l + 1 <= b.lines.high and not isBlank(b.lines[l + 1]): inc l
    if l + 1 <= b.lines.high: inc l                      # (onto the blank line after the paragraph)
    else: return Pos(line: l, col: max(0, b.lines[l].len - 1))   # (no blank line after it: the buffer's end)
  else:
    if blank:
      while l - 1 >= 0 and isBlank(b.lines[l - 1]): dec l
      while l - 1 >= 0 and not isBlank(b.lines[l - 1]): dec l
    else:
      while l - 1 >= 0 and not isBlank(b.lines[l - 1]): dec l
    if l - 1 >= 0: dec l
  Pos(line: clamp(l, 0, b.lines.high), col: 0)

func findChar(b: Buffer, p: Pos, cmd: char, target: string): (bool, Pos) =
  ## vim's f, t, F and T on the cursor's line: (found, where the cursor goes) — t and T stop one character short of
  ## the target, and when already next to it look for the one after. The target is a string, so a multi-byte
  ## character is one character, not its bytes
  let s = b.lines[p.line]
  let col = min(p.col, s.len)          # (a cursor past the end of a line that got shorter)
  if target.len == 0: return (false, p)
  case cmd
  of 'f', 't':
    var start = if col < s.len: nextRune(s, col) else: s.len
    if cmd == 't' and start < s.len and s.continuesWith(target, start): start += target.len
    let i = s.find(target, start)
    if i < 0: return (false, p)
    (true, Pos(line: p.line, col: (if cmd == 't': prevRune(s, i) else: i)))
  else:
    var last = col - 1
    if cmd == 'T' and col > 0:
      let pr = prevRune(s, col)
      if pr + target.len == col and s.continuesWith(target, pr): last = pr - 1
    if last < 0: return (false, p)
    let i = s.rfind(target, last = last)
    if i < 0: return (false, p)
    (true, Pos(line: p.line, col: (if cmd == 'T': nextRune(s, i) else: i)))

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
    q.col = leftRunes(b.lines[p.line], p.col, count)
  of "l", " ":
    # (the last column l may stand on: the start of the line's last character — or one past it, for an operator's
    # motion, so that dl deletes the character under the cursor)
    let s = b.lines[p.line]
    let limit = if vimPending.len > 0: s.len else: max(0, prevRune(s, s.len))
    q.col = rightRunes(s, p.col, count, limit)
  of "j", "+":
    if key == "j" and p.line >= b.lines.high:
      result.ok = false                    # (no line below: vim's dj does nothing)
      return
    q.line = min(b.lines.high, p.line + count)
    result.linewise = true
    result.keepCol = true
    if key == "+": q = b.firstNonBlank(q.line)
    elif vimDesiredCol >= 0: q.col = b.colAtVis(q.line, vimDesiredCol)
  of "k", "-":
    if key == "k" and p.line <= 0:
      result.ok = false                    # (no line above: vim's dk does nothing)
      return
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
    for _ in 0 ..< count:
      let nq = b.paragraphMove(q, 1)
      if count > 1 and nq == q:
        result.ok = false                    # (a counted motion that cannot finish: vim leaves the cursor)
        return
      q = nq
  of "{":
    for _ in 0 ..< count:
      let nq = b.paragraphMove(q, -1)
      if count > 1 and nq == q:
        result.ok = false
        return
      q = nq
  of "%":
    var at = p
    var (ok, a, e) = b.matchBracket(at)
    if not ok:
      # (not on a bracket: vim goes to the next one on the line — or a later line — and to its match)
      let s = b.lines[p.line]
      var found = -1
      for c in min(p.col + 1, s.len) ..< s.len:
        if s[c] in {'(', ')', '[', ']', '{', '}'}:
          found = c
          break
      if found < 0:
        result.ok = false
        return
      at = Pos(line: p.line, col: found)
      (ok, a, e) = b.matchBracket(at)
      if not ok:
        result.ok = false
        return
    q = if at == a or at.col == a.col + 1: e else: a
    result.inclusive = true
  of "H": q = b.firstNonBlank(clamp(b.topLine + cfgScrollOff, 0, b.lines.high))
  of "M": q = b.firstNonBlank(clamp(b.topLine + textH div 2, 0, b.lines.high))
  of "L": q = b.firstNonBlank(clamp(b.topLine + textH - 1 - cfgScrollOff, 0, b.lines.high))
  else:
    if key.len >= 2 and key[0] in {'f', 't', 'F', 'T'}:
      let target = key[1 .. ^1]
      vimLastFind = (key[0], target)
      for _ in 0 ..< count:
        let (ok, np) = b.findChar(q, key[0], target)
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

func tagRange(b: Buffer, p: Pos, inner: bool): (bool, Pos, Pos) =
  ## vim's `at` (the whole element around p) or `it` (what is inside its tags): the nearest enclosing element, found
  ## by walking back to an opening tag whose closing tag is after p
  var l = p.line
  var depth: Table[string, int]
  while l >= 0 and p.line - l < 2000:
    let ts = htmlTagsOn(b.lines[l])
    for k in countdown(ts.high, 0):
      let (na, ne, cl, selfc) = ts[k]
      if l == p.line and na > p.col: continue
      let name = b.lines[l][na ..< ne].toLowerAscii
      if selfc or name in VoidTags: continue
      if cl: depth[name] = depth.getOrDefault(name) + 1
      elif depth.getOrDefault(name) > 0: depth[name] = depth[name] - 1
      else:
        let (pl, pa, pe) = b.htmlPartner(l, na, ne, false)
        if pl < 0: continue
        let gt = b.lines[l].find('>', ne)
        let cgt = b.lines[pl].find('>', pe)
        if gt < 0 or cgt < 0: continue
        let openEnd = Pos(line: l, col: gt + 1)
        let closeStart = Pos(line: pl, col: pa - 2)
        if closeStart < p: continue
        if inner: return (true, openEnd, closeStart)
        return (true, Pos(line: l, col: na - 1), Pos(line: pl, col: cgt + 1))
    dec l
  (false, p, p)

proc textObject(b: Buffer, kind, obj: char, p: Pos): (bool, Pos, Pos) =
  ## iw aw i( a( i[ i{ i< i" i' i` ip ap it at  (returns a half-open range) — and plugins' (ie …)
  if plugTextObjKeys.len > 0 and ($kind & $obj) in plugTextObjKeys:
    let (_, ok, a, e) = plugTextObject(b, kind, obj, p)
    return (ok, a, e)
  if obj == 't': return b.tagRange(p, kind == 'i')
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
    if a == e:
      # (on blanks: vim's iw is the run of them, aw that run and the word after it)
      let isBlk = func(c: char): bool = (if obj == 'W': c in vimBlank else: c in {' ', '\t'})
      if p.col >= s.len or not isBlk(s[p.col]): return (false, p, p)
      a = Pos(line: p.line, col: p.col)
      e = a
      while e.col < s.len and isBlk(s[e.col]): inc e.col
      if kind == 'a' and e.col < s.len:
        if obj == 'W':
          while e.col < s.len and not isBlk(s[e.col]): inc e.col
        else:
          let cls = vimCharClass(s[e.col])
          while e.col < s.len and vimCharClass(s[e.col]) == cls: inc e.col
      return (true, a, e)
    if kind == 'a':
      let e0 = e.col
      while e.col < s.len and s[e.col] in {' ', '\t'}: inc e.col
      if e.col == e0 and a.col > 0:
        # (a word at the end of a line: aw takes the blanks before it, as the quote objects do at a line's end)
        while a.col > 0 and s[a.col - 1] in {' ', '\t'}: dec a.col
    return (true, a, e)
  of '<', '>':
    # (the nearest < before and the nearest > after, on the line — not b.matchBracket, which pairs () [] {} only)
    let i = s.rfind('<', last = max(0, min(p.col, s.len - 1)))
    let j = if i >= 0: s.find('>', max(i + 1, p.col)) else: -1
    if i < 0 or j < 0: return (false, p, p)
    if kind == 'i': return (true, Pos(line: p.line, col: i + 1), Pos(line: p.line, col: j))
    return (true, Pos(line: p.line, col: i), Pos(line: p.line, col: j + 1))
  of '"', '\'', '`':
    if s.len == 0: return (false, p, p)
    # (the two quotes around the cursor. On one, an even number of that quote before it means it opens a string and an
    # odd one that it closes it; with none around the cursor, vim takes the pair it is in and, before the line's first,
    # the next pair — `vi"` at the start of `x = "foo"` goes to the string)
    var i = -1
    if p.col < s.len and s[p.col] == obj:
      var n = 0
      for c in 0 ..< p.col:
        if s[c] == obj: inc n
      if (n and 1) == 0: i = p.col
      else: i = s.rfind(obj, last = p.col - 1)
    else:
      i = s.rfind(obj, last = min(p.col, s.len - 1))
      if i < 0: i = s.find(obj, p.col)
    let j = if i >= 0: s.find(obj, if i == p.col: p.col + 1 else: max(i + 1, p.col)) else: -1
    if i < 0 or j < 0 or j <= i: return (false, p, p)
    if kind == 'i': return (true, Pos(line: p.line, col: i + 1), Pos(line: p.line, col: j))
    # (vim's `a"`: the quotes and the blanks after them — at a line's end, the blanks before them instead)
    var ae = j + 1
    while ae < s.len and s[ae] in {' ', '\t'}: inc ae
    if ae == j + 1:
      var a0 = i
      while a0 > 0 and s[a0 - 1] in {' ', '\t'}: dec a0
      return (true, Pos(line: p.line, col: a0), Pos(line: p.line, col: ae))
    return (true, Pos(line: p.line, col: i), Pos(line: p.line, col: ae))
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
    if not found:
      # (not inside a bracket: vim goes forward to the next one on the line or a later line)
      var fl = p.line
      while fl < b.lines.len and not found:
        let t = b.lines[fl]
        var c = if fl == p.line: p.col else: 0
        while c < t.len:
          if t[c] == op:
            oa = Pos(line: fl, col: c)
            found = true
            break
          inc c
        inc fl
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

proc vimApply(b: Buffer, op: string, a0, e0: Pos, linewise: bool, cursorCol = -1, toEol = false) =
  ## does a vim operator on a range: y (yank), d and c (delete, c then enters insert mode), > and < (indent), ~ gu gU
  ## (case) and gc (comment); a linewise range is widened to whole lines, and d / c also fill the unnamed register.
  ## `cursorCol` (a display column from 1) is where the cursor stood before a `>` or `<`: vim moves the text, not the
  ## cursor
  var a = b.clampPos(a0)            # "one past the selection" may lie past the end of the line
  var e = b.clampPos(e0)
  if e < a: swap(a, e)
  if op in [">", "<"] and not linewise and a == e:
    return                          # (a motion that did not move: vim's > and < do nothing)
  let toEol = op in [">", "<"] and not linewise and toEol
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
      # (vim leaves the cursor where the text after the deletion now is — at the start of what went, so `diw` on
      # "quick" leaves it on the space after it; at a line's end, on the character before, so `D` from column 5 on
      # "abcdef" is column 4. A whole-line deletion keeps the display column the cursor was drawn at — `dd` from
      # column 5 of an indented line below is still column 5 — and a `c` leaves it where the change starts)
      b.setSingle(if op == "d":
                    if linewise:
                      let line = min(p.line, b.lines.high)
                      b.clampNormal(Pos(line: line, col: (if cursorCol > 0: b.colAtVis(line, cursorCol)
                                                           else: b.firstNonBlank(line).col)))
                    else: b.clampNormal(Pos(line: a.line, col: a.col))
                  else: p)
    if op == "c": vimSetMode(vmInsert)
  of ">", "<":
    # (vim moves the text under the cursor, not the cursor: it stays in the display column it was drawn at. The line is
    # the first of the range — a text object on another line puts the cursor there, at the same column. A cell the shift
    # made empty is the last character of the line)
    let want = a0.minP(e0)
    let vcol = if cursorCol > 0: cursorCol else: b.visColAt(want.line, want.col) + 1
    # (the lines the widened range covers, both ends included: the selection must not end at column 0 of a line, which
    # the editor reads as "that line is not selected" — `V` `j` `>` on the last two lines of the file)
    let lastL = (if linewise and e.col == 0 and e.line > a.line: e.line - 1 else: e.line)
    b.setSingle(Pos(line: lastL, col: max(0, b.lines[lastL].len - 1)), Pos(line: a.line, col: 0))
    b.indentLines(if op == ">": 1 else: -1, expandTabs = true)
    let line = if linewise: min(a0.line, e0.line) else: want.line
    if toEol: b.setSingle(b.clampNormal(Pos(line: line, col: max(0, b.lines[line].len - 1))))
    else: b.setSingle(b.clampNormal(Pos(line: line, col: b.colAtVis(line, vcol))))
  of "~", "g~", "gu", "gU":
    if not b.canEdit(): return
    b.beginEdit()
    discard b.replaceText(a, e, vimCaseMap(text, op))
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
