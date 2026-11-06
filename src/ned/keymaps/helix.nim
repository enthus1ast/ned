# ── the helix keymap: select, then act. NOR: h j k l · w b e (W B E) · x line · v extend · ; collapse · % all ·
#    d c y p P · i a I A o O · u U · r<c> · ~ · > < · J · / ? n N · g (g e h l s d r) · space (f b s S / k a r c y p) ·
#    : commands · C add a cursor below · , keep one cursor ──

proc hxSetMode(m: HxMode) =
  ## switches between Helix's normal, select and insert modes; edits made in one insert session are merged into one undo
  ## step on leaving it, and the cursor's shape is set for the mode
  if m == hxInsert and vimUndoMark < 0: vimUndoMark = buf().undoStack.len
  if m != hxInsert and hxMode == hxInsert:
    buf().mergeUndo(vimUndoMark)
    vimUndoMark = -1
  hxMode = m
  vimShape()
  needRender = true

# whether the character is part of a word: for a WORD (W, B, E) anything but a blank; for a word a letter, digit,
# underscore or non-ASCII byte
func hxIsWordCh(c: char, big: bool): bool = (if big: c notin {' ', '\t'} else: c.isAlphaNumeric or c == '_' or ord(c) >= 0x80)

proc hxWordFwd(b: Buffer, p: Pos, big, toEnd: bool): Pos =
  ## w: the start of the next word · e: the end of this/next word (positions between characters)
  var l = p.line
  var c = p.col
  # the character at the position being walked, a line break past the end of its line
  template ch(): char = (if c < b.lines[l].len: b.lines[l][c] else: '\n')
  template step(): bool =
    ## moves the walked position on by one character, over a line break to the next line's start; false at the end of
    ## the buffer
    (if c < b.lines[l].len: (inc c; true) elif l < b.lines.high: (inc l; c = 0; true) else: false)
  if toEnd:
    # skip blanks, then to the end of the word
    while ch() in {' ', '\t', '\n'}:
      if not step(): return Pos(line: l, col: c)
    let w = hxIsWordCh(ch(), big)
    while c < b.lines[l].len and ch() notin {' ', '\t'} and hxIsWordCh(ch(), big) == w: inc c
    return Pos(line: l, col: c)
  if c < b.lines[l].len:
    let w = hxIsWordCh(ch(), big)
    while c < b.lines[l].len and ch() notin {' ', '\t'} and hxIsWordCh(ch(), big) == w: inc c
  while ch() in {' ', '\t', '\n'}:
    if not step(): break
  Pos(line: l, col: c)

proc hxWordBack(b: Buffer, p: Pos, big: bool): Pos =
  ## the start of the word before the position (b) — skips blanks and line breaks backwards, then the run of word (or of
  ## other) characters
  var l = p.line
  var c = p.col
  # the character before the walked position, a line break at the start of its line
  template prevCh(): char = (if c > 0: b.lines[l][c - 1] else: '\n')
  while prevCh() in {' ', '\t', '\n'}:
    if c > 0: dec c
    elif l > 0:
      dec l
      c = b.lines[l].len
    else: return Pos(line: l, col: c)
  let w = hxIsWordCh(prevCh(), big)
  while c > 0 and prevCh() notin {' ', '\t'} and hxIsWordCh(prevCh(), big) == w: dec c
  Pos(line: l, col: c)

proc hxRange(b: Buffer): (Pos, Pos) =
  ## what d / c / y act on: the selection, else the character under the cursor
  let (a, e) = b.primary.range
  if a != e: return (a, e)
  let p = b.primary.head
  if p.col < b.lines[p.line].len: return (p, b.posRight(p))
  if p.line < b.lines.high: return (p, Pos(line: p.line + 1, col: 0))
  (p, p)

proc helixKey(k: Key): bool =
  ## the Helix keymap for one key: insert mode passes everything but Esc on to the editor; normal and select mode take
  ## counts, the g and space prefixes, r<char>, motions (select mode extends the selection instead of moving it) and the
  ## editing keys. True when the key was taken
  let b = buf()
  # ── insert ──
  if hxMode == hxInsert:
    if k.kind == kEsc or (k.kind == kChar and mCtrl in k.mods and k.ch in [ord('['), ord('c')]):
      if compOpen: closeComp()
      b.stops.setLen(0)
      hxSetMode(hxNormal)
      return true
    return false
  if k.kind == kEsc:
    hxPending = ""
    hxCount = ""
    if hxMode == hxSelect: hxSetMode(hxNormal)
    if b.cursors.len > 1:
      b.cursors = @[b.primary]
      b.prim = 0
    b.setSingle(b.primary.head)
    return true
  # ordinary shortcuts (Ctrl+…, Alt+…, F-keys, arrows) keep working
  if k.kind != kChar or k.mods - {mShift} != {} or k.ch >= 128:
    if k.kind in {kLeft, kRight, kUp, kDown} and k.mods == {}:
      cmdMove(k.kind, hxMode == hxSelect, false)
      return true
    return false
  let ch = char(k.ch)
  let ext = hxMode == hxSelect
  let n = (if hxCount.len > 0: (try: parseInt(hxCount) except ValueError: 1) else: 1)
  # ── pending: g · space · r ──
  if hxPending.len > 0:
    let pend = hxPending
    hxPending = ""
    hxCount = ""
    case pend
    of "g":
      let anc = if ext: b.primary.anchor else: Pos(line: -1)
      case ch
      of 'g': b.setSingle(Pos(line: (if n > 1: min(n - 1, b.lines.high) else: 0), col: 0), anc)
      of 'e': b.setSingle(Pos(line: b.lines.high, col: 0), anc)
      of 'h': b.setSingle(Pos(line: b.primary.head.line, col: 0), anc)
      of 'l': b.setSingle(Pos(line: b.primary.head.line, col: b.lines[b.primary.head.line].len), anc)
      of 's': b.setSingle(Pos(line: b.primary.head.line, col: leadingWs(b.lines[b.primary.head.line]).len), anc)
      of 'd': runCmd("Go to definition")
      of 'r': runCmd("Find references")
      of 'y': runCmd("Go to type definition")
      of 'i': runCmd("Go to implementation")
      of 'n': switchTab(1)
      of 'p': switchTab(-1)
      else: discard
      b.ensureVisible()
    of "space":
      case ch
      of 'f': runCmd("Open file…")
      of 'b': runCmd("Switch buffer…")
      of 's': runCmd("Go to symbol…")
      of 'S': runCmd("Go to symbol in project…")
      of '/': runCmd("Search in project…")
      of 'k': cmdHover()
      of 'a': runCmd("Quick fix / code actions…")
      of 'r': runCmd("Rename symbol")
      of 'c': b.toggleComment()
      of 'y': copySel(false)
      of 'p', 'P': paste()
      of 'd': setPanel(pkProblems)
      of '?': runCmd("Command palette")
      else: discard
    of "r":
      if b.canEdit():
        let (a, e) = b.hxRange()
        if a != e:
          var t = b.getText(a, e)
          for i in 0 ..< t.len:
            if t[i] != '\n': t[i] = ch
          b.beginEdit()
          discard b.replaceText(a, e, t)
          b.endEdit()
          b.setSingle(a)
    else: discard
    return true
  if ch in Digits and (hxCount.len > 0 or ch != '0'):
    hxCount.add ch
    return true
  defer: hxCount = ""
  case ch
  of 'h': (for _ in 0 ..< n: cmdMove(kLeft, ext, false))
  of 'l': (for _ in 0 ..< n: cmdMove(kRight, ext, false))
  of 'j': (for _ in 0 ..< n: cmdMove(kDown, ext, false))
  of 'k': (for _ in 0 ..< n: cmdMove(kUp, ext, false))
  of 'w', 'W', 'e', 'E':
    var a = if ext: b.primary.anchor else: b.primary.head
    var h = b.primary.head
    for _ in 0 ..< n:
      if not ext: a = h
      h = b.hxWordFwd(h, ch in {'W', 'E'}, ch in {'e', 'E'})
    b.setSingle(h, a)
    b.ensureVisible()
  of 'b', 'B':
    var a = if ext: b.primary.anchor else: b.primary.head
    var h = b.primary.head
    for _ in 0 ..< n:
      if not ext: a = h
      h = b.hxWordBack(h, ch == 'B')
    b.setSingle(h, a)
    b.ensureVisible()
  of 'x', 'X':
    let (a0, e0) = b.primary.range
    var a = Pos(line: a0.line, col: 0)
    var e = if e0.col == 0 and e0.line > a0.line: e0 else: Pos(line: e0.line + 1, col: 0)
    if a0 == Pos(line: a0.line, col: 0) and e0.col == 0 and e0.line > a0.line: e = Pos(line: e0.line + n, col: 0)
    else: e = Pos(line: e.line + n - 1, col: 0)
    if e.line > b.lines.high: e = Pos(line: b.lines.high, col: b.lines[^1].len)
    b.setSingle(e, a)
    b.ensureVisible()
  of 'v': hxSetMode(if hxMode == hxSelect: hxNormal else: hxSelect)
  of ';': b.setSingle(b.primary.head)
  of '%': b.setSingle(Pos(line: b.lines.high, col: b.lines[^1].len), Pos())
  of ',':
    b.cursors = @[b.primary]
    b.prim = 0
  of 'C': b.addCursorVert(1)
  of 'd', 'c':
    if b.canEdit():
      let (a, e) = b.hxRange()
      if a != e:
        b.setSingle(e, a)
        copySel(true)
      if ch == 'c': hxSetMode(hxInsert)
      elif hxMode == hxSelect: hxSetMode(hxNormal)
  of 'y':
    let (a, e) = b.hxRange()
    if a != e:
      let keep = b.cursors
      b.setSingle(e, a)
      copySel(false)
      b.cursors = keep
    if hxMode == hxSelect: hxSetMode(hxNormal)
  of 'p', 'P':
    if b.canEdit():
      let (a, e) = b.primary.range
      let lineWise = clipLineMode or (clipParts.len == 1 and clipParts[0].endsWith("\n"))
      if lineWise:
        let l = if ch == 'p': min(e.line + (if e.col == 0 and e.line > a.line: 0 else: 1), b.lines.len) else: a.line
        if l >= b.lines.len:
          b.setSingle(Pos(line: b.lines.high, col: b.lines[^1].len))
          b.insertText("\n")
          b.setSingle(Pos(line: b.lines.high, col: 0))
        else: b.setSingle(Pos(line: l, col: 0))
        let t = if clipParts.len > 0: clipParts.join("") else: clipGet()
        b.insertText(if l >= b.lines.len - 1 and t.endsWith("\n") and ch == 'p' and b.lines[^1].len == 0: t[0 ..< ^1] else: t)
      else:
        b.setSingle(if ch == 'p': (if a != e: e else: b.posRight(e)) else: a)
        paste()
  of 'i':
    b.setSingle(b.primary.range[0])
    hxSetMode(hxInsert)
  of 'a':
    let (a, e) = b.primary.range
    b.setSingle(if a != e: e else: b.posRight(e))
    hxSetMode(hxInsert)
  of 'I':
    let l = b.primary.head.line
    b.setSingle(Pos(line: l, col: leadingWs(b.lines[l]).len))
    hxSetMode(hxInsert)
  of 'A':
    let l = b.primary.head.line
    b.setSingle(Pos(line: l, col: b.lines[l].len))
    hxSetMode(hxInsert)
  of 'o':
    let l = b.primary.range[1].line
    b.setSingle(Pos(line: l, col: b.lines[l].len))
    hxSetMode(hxInsert)
    b.newline()
  of 'O':
    let l = b.primary.range[0].line
    b.setSingle(Pos(line: l, col: 0))
    hxSetMode(hxInsert)
    let ind = leadingWs(b.lines[l])
    b.insertText(ind & "\n")
    b.setSingle(Pos(line: l, col: ind.len))
  of 'u': b.undo()
  of 'U': b.redo()
  of 'Q': macroToggle()                       # Helix: Q records a macro (and stops), q plays it
  of 'q': macroPlay(macroLast, n)
  of 'r': hxPending = "r"
  of 'g': hxPending = "g"
  of ' ': hxPending = "space"
  of '~', '`':
    if b.canEdit():
      let (a, e) = b.hxRange()
      var t = b.getText(a, e)
      for i in 0 ..< t.len:
        t[i] = if ch == '`': t[i].toLowerAscii elif t[i].isUpperAscii: t[i].toLowerAscii else: t[i].toUpperAscii
      b.beginEdit()
      discard b.replaceText(a, e, t)
      b.endEdit()
      if b.primary.hasSel: b.setSingle(e, a) else: b.setSingle(a)
  of '>': b.indentLines(1)
  of '<': b.indentLines(-1)
  of 'J':
    if b.canEdit() and b.primary.head.line < b.lines.high:
      let l = b.primary.head.line
      let nxt = b.lines[l + 1].strip(trailing = false)
      b.beginEdit()
      discard b.replaceText(Pos(line: l, col: b.lines[l].len), Pos(line: l + 1, col: b.lines[l + 1].len - nxt.len),
                            (if b.lines[l].len > 0 and nxt.len > 0: " " else: ""))
      b.endEdit()
  of '/', '?':
    vimSearchBack = ch == '?'
    openPrompt(pVimSearch, (if ch == '/': "search:" else: "rsearch:"), "")
  of 'n', 'N':
    if findQuery.len > 0: findStep((ch == 'n') != vimSearchBack)
  of '*':
    let (a, e) = b.primary.range
    findQuery = selQuery(if a != e and a.line == e.line: b.getText(a, e) else: b.wordAt(b.primary.head))
    findWord = a == e
    info("Search: " & findQuery)
  of ':': openPrompt(pVimCmd, ":", "")
  else: discard
  true

proc helixEditorKey(k: Key): bool =
  ## the editor's entry to the Helix keymap: only when editor.keymap is helix, and not while the completion list is open
  ## in insert mode; sets the cursor's shape for the mode after the key
  if cfgKeymap != "helix": return false
  if compOpen and hxMode == hxInsert: return false
  result = helixKey(k)
  vimShape()

func keymapAct(v: string): Action =
  ## an action that selects the key bindings `v` (default, vim, emacs or helix): saves editor.keymap, leaves vim mode,
  ## resets the Helix and emacs states and tells what the main keys are
  proc() =
    setSetting("editor.keymap", %v)
    if v != "vim" and sBool("editor.vimMode"): setSetting("editor.vimMode", %false)
    hxMode = hxNormal
    emacsMark = false
    emacsPrefix = ""
    vimShape()
    info("Key bindings: " & v & (if v == "helix": " — NOR: select with w x %, act with d c y p; i to type, Esc back"
                                 elif v == "emacs": " — C-x C-s saves, M-x runs a command, C-g cancels" else: ""))

proc cmdKeymap() =
  ## the command "Key bindings: default · vim · emacs · helix…": a menu of the four keymaps with a line on each, the current one marked
  var items: seq[(string, string, Action)]
  for (v, d) in [("default", "VS Code-like: Ctrl+S, Ctrl+P, Ctrl+F …"), ("vim", "modal: hjkl, i, :w …"),
                 ("emacs", "C-f C-b C-n C-p, C-x C-s, C-k C-y, C-SPC, M-x"),
                 ("helix", "select then act: w x d c y p, space mode, g goto")]:
    items.add act((if v == cfgKeymap: "● " else: "  ") & v, d, keymapAct(v))
  openActions("Key bindings", items)
