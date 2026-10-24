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

proc vimModeName(): string =
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
  if m in {vmInsert, vmReplace} and vimUndoMark < 0: vimUndoMark = buf().undoStack.len
  vimMode = m
  vimShape()
  needRender = true

proc vimMouseClick() =
  if cfgVim and vimMode in {vmVisual, vmVLine}: vimSetMode(vmNormal)

proc clampNormal(b: Buffer, p: Pos): Pos =
  result = b.clampPos(p)
  let n = b.lines[result.line].len
  if n > 0 and result.col >= n: result.col = n - 1

proc vimYank(text: string, linewise: bool) =
  vimReg = text
  vimRegLine = linewise
  if cfgVimClipboard:
    clipSet(text)
    clipParts = @[text]
    clipLineMode = linewise


proc nextWordStart(b: Buffer, p: Pos, big: bool): Pos =
  var l = p.line
  var c = p.col
  let s0 = b.lines[l]
  if c < s0.len:
    let cls = if big: (if s0[c] in {' ', '\t'}: 0 else: 1) else: charClass(s0[c])
    while c < s0.len and (if big: (if s0[c] in {' ', '\t'}: 0 else: 1) else: charClass(s0[c])) == cls and cls != 0: inc c
  while true:
    let s = b.lines[l]
    while c < s.len and s[c] in {' ', '\t'}: inc c
    if c < s.len: return Pos(line: l, col: c)
    if l >= b.lines.high: return Pos(line: l, col: s.len)
    inc l
    c = 0
    if b.lines[l].len == 0: return Pos(line: l, col: 0)

func prevWordStart(b: Buffer, p: Pos, big: bool): Pos =
  var l = p.line
  var c = min(p.col, b.lines[l].len) - 1
  while true:
    let s = b.lines[l]
    while c >= 0 and s[c] in {' ', '\t'}: dec c
    if c >= 0:
      let cls = if big: 1 else: charClass(s[c])
      while c > 0 and (if big: (if s[c - 1] in {' ', '\t'}: 0 else: 1) else: charClass(s[c - 1])) == cls: dec c
      return Pos(line: l, col: c)
    if l == 0: return Pos(line: 0, col: 0)
    dec l
    c = b.lines[l].len - 1
    if b.lines[l].len == 0: return Pos(line: l, col: 0)

proc wordEnd(b: Buffer, p: Pos, big: bool): Pos =
  var l = p.line
  var c = p.col + 1
  while true:
    let s = b.lines[l]
    while c < s.len and s[c] in {' ', '\t'}: inc c
    if c < s.len:
      let cls = if big: 1 else: charClass(s[c])
      while c + 1 < s.len and (if big: (if s[c + 1] in {' ', '\t'}: 0 else: 1) else: charClass(s[c + 1])) == cls: inc c
      return Pos(line: l, col: c)
    if l >= b.lines.high: return Pos(line: l, col: max(0, s.len - 1))
    inc l
    c = 0

func firstNonBlank(b: Buffer, l: int): Pos = Pos(line: l, col: leadingWs(b.lines[l]).len)

proc paragraphMove(b: Buffer, p: Pos, d: int): Pos =
  var l = p.line + d
  while l > 0 and l < b.lines.high and isBlank(b.lines[l]): l += d
  while l > 0 and l < b.lines.high and not isBlank(b.lines[l]): l += d
  Pos(line: clamp(l, 0, b.lines.high), col: 0)

func findChar(b: Buffer, p: Pos, cmd, ch: char): (bool, Pos) =
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
    if key == "+": q = b.firstNonBlank(q.line)
  of "k", "-":
    q.line = max(0, p.line - count)
    result.linewise = true
    if key == "-": q = b.firstNonBlank(q.line)
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
  of "^", "_": q = b.firstNonBlank(p.line)
  of "$":
    q.line = min(b.lines.high, p.line + count - 1)
    q.col = max(0, b.lines[q.line].len - (if vimPending.len > 0: 0 else: 1))
    if vimPending.len > 0: q.col = b.lines[q.line].len
  of "gg":
    q = b.firstNonBlank(if vimCount.len > 0 or vimOpCount.len > 0: clamp(count - 1, 0, b.lines.high) else: 0)
    result.linewise = true
  of "G":
    q = b.firstNonBlank(if vimCount.len > 0 or vimOpCount.len > 0: clamp(count - 1, 0, b.lines.high) else: b.lines.high)
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
      b.setSingle(if op == "d": b.clampNormal(if linewise: b.firstNonBlank(min(p.line, b.lines.high)) else: p) else: p)
    if op == "c": vimSetMode(vmInsert)
  of ">", "<":
    b.setSingle(Pos(line: e0.line, col: 0), Pos(line: a0.line, col: 0))
    b.indentLines(if op == ">": 1 else: -1)
    b.setSingle(b.firstNonBlank(min(a0.line, e0.line)))
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

proc vimEx(cmd: string) =
  ## the ':' command line
  let b = buf()
  let c = cmd.strip
  if c.len == 0: return
  if plugExCommand(c): return                       # (a plugin's :Name)
  if c.allCharsInSet(Digits):
    b.centerOn(b.firstNonBlank(clamp(parseInt(c) - 1, 0, b.lines.high)))
    return
  # :!cmd runs a command (% is the file), its output in the panel · :%!cmd, :'<,'>!cmd, :.!cmd, :N,M!cmd put those
  # lines through it (sort, jq ., column -t …)
  let bang = c.find('!')
  if bang >= 0 and bang + 1 < c.len:
    let rng = c[0 ..< bang].strip
    let sh = c[bang + 1 .. ^1].strip
    var lo, hi = -1
    if rng == "%": (lo, hi) = (0, b.lines.high)
    elif rng == ".": (lo, hi) = (b.primary.head.line, b.primary.head.line)
    elif rng == "'<,'>":
      let (a, e) = b.primary.range
      (lo, hi) = (a.line, (if e.col == 0 and e.line > a.line: e.line - 1 else: e.line))
    elif rng.split(',').len == 2 and rng.split(',')[0].strip.allDigits and rng.split(',')[1].strip.allDigits and
         rng.split(',')[0].strip.len > 0 and rng.split(',')[1].strip.len > 0:
      lo = clamp(parseInt(rng.split(',')[0].strip) - 1, 0, b.lines.high)
      hi = clamp(parseInt(rng.split(',')[1].strip) - 1, lo, b.lines.high)
    if sh.len > 0 and rng.len == 0:
      var cmdl = ""
      for w in sh.split(' '):
        cmdl.add (if cmdl.len > 0: " " else: "") & (if w == "%" and b.path.len > 0: quoteShell(b.path) else: w)
      runCommand(cmdl, (if b.path.len > 0: parentDir(b.path) else: rootDir))
      return
    if sh.len > 0 and lo >= 0:
      b.setSingle(Pos(line: hi, col: b.lines[hi].len), Pos(line: lo, col: 0))
      pipeThroughCommand(sh)
      vimSetMode(vmNormal)
      return
  let parts = c.splitWhitespace
  let head = parts[0]
  let arg = if parts.len > 1: c[head.len .. ^1].strip else: ""
  case head
  of "w", "write":
    if arg.len > 0: discard b.saveBuffer(absProjectPath(arg)) else: discard b.saveBuffer()
  of "q", "quit", "close":
    if bufs.len > 1: closeBuffer(curBuf) else: requestQuit()
  of "q!", "quit!":
    if bufs.len > 1: closeBufferAt(curBuf) else: quitting = true
  of "wq", "x", "xit":
    if b.saveBuffer():
      if bufs.len > 1: closeBuffer(curBuf) else: requestQuit()
  of "wa", "wall": discard saveAll()
  of "qa", "qall", "qa!": (if head == "qa!": quitting = true else: requestQuit())
  of "wqa", "xa": (if saveAll(): quitting = true)
  of "e", "edit":
    if arg.len > 0: discard openFile(absProjectPath(arg)) else: b.reloadBuffer()
  of "bn", "bnext": switchTab(1)
  of "bp", "bprev", "bprevious": switchTab(-1)
  of "zen": toggleZen()
  of "bd", "bdelete": closeBuffer(curBuf)
  of "noh", "nohlsearch": findQuery = ""
  of "set", "se":
    for a in arg.splitWhitespace:
      case a
      of "wrap": setSetting("editor.softWrap", %true)
      of "nowrap": setSetting("editor.softWrap", %false)
      of "nu", "number": setSetting("editor.lineNumbers", %"absolute")
      of "rnu", "relativenumber": setSetting("editor.lineNumbers", %"relative")
      of "nonu", "nonumber": setSetting("editor.lineNumbers", %"off")
      of "list": setSetting("editor.showWhitespace", %true)
      of "nolist": setSetting("editor.showWhitespace", %false)
      else: info("Unknown option: " & a)
  of "sp", "split": splitEditor(down = true)          # (one pane above the other, as vim's)
  of "vs", "vsplit": splitEditor(down = false)       # (side by side)
  of "on", "only": closeSplit()
  of "term", "terminal": toggleTerminal()
  of "make": runCurrent(true)
  of "run": runCurrent()
  else:
    # :s/a/b/[g]  and  :%s/a/b/[g]
    var t = c
    var whole = false
    if t.startsWith("%"):
      whole = true
      t = t[1 .. ^1]
    if t.len > 2 and t[0] == 's' and t[1] in {'/', '#', '|'}:
      let d = t[1]
      let f = t[2 .. ^1].split(d)
      if f.len >= 2:
        let pat = f[0]
        let rep = f[1]
        let global = f.len >= 3 and 'g' in f[2]
        b.beginEdit()
        var n = 0
        let lo = if whole: 0 else: b.primary.head.line
        let hi = if whole: b.lines.high else: b.primary.head.line
        for l in lo .. hi:
          var s = b.lines[l]
          var i = s.find(pat)
          var changed = false
          while i >= 0:
            s = s[0 ..< i] & rep & s[i + pat.len .. ^1]
            inc n
            changed = true
            if not global: break
            i = s.find(pat, i + rep.len)
          if changed: discard b.replaceText(Pos(line: l, col: 0), Pos(line: l, col: b.lines[l].len), s)
        b.endEdit()
        b.normalize()
        info($n & " substitution(s)")
        return
    let ci = cmdByName(c)
    if ci >= 0: runCmd(c)
    else: error("Not an editor command: " & c)
