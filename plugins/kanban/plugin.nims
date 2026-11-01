## kanban — a board from TODO.md: its headings are the columns, its checklist items the cards; moving a card edits the file
##
##   Kanban: open the board    the board in a tab of its own: the columns side by side (one under another when the
##                             editor is narrow), each card in its column, ☐ open, ☑ done. In it: Alt+Right and
##                             Alt+Left move the card at the cursor to the next column or the one before, Alt+Up and
##                             Alt+Down move it up or down its column, Alt+Enter goes to it in TODO.md; vim: > < and
##                             Enter
##   Kanban: move the card…    the card at the cursor — on the board, or a checklist line of TODO.md itself — to a
##                             column you choose
##   Kanban: add a card…       its text, then its column
##   the Plugins dock          KANBAN: the columns and their cards — tap a card to move it, tick it or go to it
##   settings                  plugins.kanban.file — the board's file, from the project's folder (TODO.md) · .level
##                             — the headings that are columns (2: ##) · .doneColumn — a card moved to the column of
##                             this name is ticked, one moved out of it unticked ("Done")
##
## A card is a checklist line — `- [ ] write the docs` — with the lines indented under it (notes, sub-tasks), which
## go with it. Moving a card cuts its lines from one column and puts them after the last card of another; the rest of
## the file stays as you wrote it. The file is edited in its tab when it is open (and saved, when it had no changes
## of yours), else opened, changed and saved. Saving TODO.md shows its changes on the board.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("file", "TODO.md", "Kanban: the board's Markdown file, from the project's folder (or a full path)")
settingDef("level", 2, "Kanban: the level of the headings that are the board's columns (2: ## headings)")
settingDef("doneColumn", "Done", "Kanban: the column whose cards are done — ticked when moved there, unticked when " &
           "moved out")

language("kanban", LangSpec(name: "Kanban board"))

const View = "KANBAN"

type
  Card* = object
    first*, last*: int           # its lines in the file (the ones indented under it are its own)
    done*: bool
    text*: string
  Column* = object
    name*: string
    line*: int                   # its heading's line
    stop*: int                   # the first line after it
    cards*: seq[Card]

# ── reading the file ──

func indentOf(s: string): int =
  ## how many spaces or tabs the line starts with
  while result < s.len and s[result] in {' ', '\t'}: inc result

func checkbox*(s: string): (int, bool, int) =
  ## a checklist line: (its indentation, ticked, where its text starts); (-1, …) when it is not one
  let i = indentOf(s)
  if i + 4 < s.len and s[i] in {'-', '*', '+'} and s[i + 1] == ' ' and s[i + 2] == '[' and
     s[i + 3] in {' ', 'x', 'X'} and s[i + 4] == ']' and (i + 5 == s.len or s[i + 5] == ' '):
    return (i, s[i + 3] != ' ', min(s.len, i + 6))
  (-1, false, 0)

func headingLevel(s: string): int =
  ## the level of a Markdown heading line (how many #, when a space follows them); 0 for any other line
  var n = 0
  while n < s.len and s[n] == '#': inc n
  if n > 0 and n < s.len and s[n] == ' ': n else: 0

func columnsOf*(lines: seq[string], level: int): seq[Column] =
  ## the headings of `level` (else of the first level that has two or more: a title alone is no board) with their
  ## cards
  var lv = level
  var any = false
  for l in lines:
    if headingLevel(l) == lv: any = true
  if not any:
    for x in 1 .. 4:
      var n = 0
      for l in lines:
        if headingLevel(l) == x: inc n
      if n >= 2:
        lv = x
        any = true
        break
  if not any: return
  var fence = false
  for i, l in lines:
    if l.strip.startsWith("```"): fence = not fence
    if fence: continue
    let h = headingLevel(l)
    if h > 0 and h <= lv:
      if result.len > 0 and result[^1].stop < 0: result[^1].stop = i
      if h == lv: result.add Column(name: l[h + 1 .. ^1].strip, line: i, stop: -1)
  if result.len > 0 and result[^1].stop < 0: result[^1].stop = lines.len
  for c in result.mitems:
    var i = c.line + 1
    var top = -1                 # (the cards' indentation: the first one's)
    var inFence = false          # (a ``` block's lines are not cards)
    while i < c.stop:
      if lines[i].strip.startsWith("```"): inFence = not inFence
      if inFence or lines[i].strip.startsWith("```"):
        inc i
        continue
      let (ind, done, at) = checkbox(lines[i])
      if ind < 0 or (top >= 0 and ind > top):
        inc i
        continue
      if top < 0: top = ind
      var card = Card(first: i, last: i, done: done, text: lines[i][at .. ^1].strip)
      var j = i + 1
      while j < c.stop and lines[j].strip.len > 0 and indentOf(lines[j]) > ind:
        card.last = j
        inc j
      c.cards.add card
      i = card.last + 1

func cardAtLine*(cols: seq[Column], line: int): (int, int) =
  ## the column and the card a line of the file is in ((-1, -1): none)
  for ci, c in cols:
    for k, card in c.cards:
      if card.first <= line and line <= card.last: return (ci, k)
  (-1, -1)

# ── changing it ──

func ticked(s: string, done: bool): string =
  ## the checklist line with its box ticked [x] (done) or empty [ ]; any other line as it is
  let (ind, _, _) = checkbox(s)
  if ind < 0: s else: s[0 ..< ind + 3] & (if done: "x" else: " ") & s[ind + 4 .. ^1]

func moved*(lines: seq[string], cols: seq[Column], ci, k, to: int, doneName: string): (seq[string], int) =
  ## the file with card k of column ci at the end of column `to` — ticked when it is the done column, unticked when
  ## it leaves it — and its first line now
  let c = cols[ci].cards[k]
  var blk = lines[c.first .. c.last]
  let dest = cols[to]
  var at = if dest.cards.len > 0: dest.cards[^1].last + 1
           else:
             var e = dest.stop
             while e - 1 > dest.line and lines[e - 1].strip.len == 0: dec e
             e
  let isDone = cmpIgnoreCase(dest.name, doneName) == 0
  let wasDone = cmpIgnoreCase(cols[ci].name, doneName) == 0
  if isDone: blk[0] = ticked(blk[0], true)
  elif wasDone: blk[0] = ticked(blk[0], false)
  var rest = lines[0 ..< c.first] & lines[c.last + 1 .. ^1]
  if at > c.last: at -= blk.len
  for x in countdown(blk.high, 0): rest.insert(blk[x], at)
  (rest, at)

func swapped*(lines: seq[string], cols: seq[Column], ci, k, by: int): (seq[string], int) =
  ## the file with card k of column ci swapped with the card `by` (-1 above, 1 below) — and its first line now
  let cs = cols[ci].cards
  let o = k + by
  if o < 0 or o >= cs.len: return (lines, cs[k].first)
  let (a, b) = if by < 0: (cs[o], cs[k]) else: (cs[k], cs[o])
  let mid = lines[a.last + 1 ..< b.first]
  let r = lines[0 ..< a.first] & lines[b.first .. b.last] & mid & lines[a.first .. a.last] & lines[b.last + 1 .. ^1]
  (r, (if by < 0: a.first else: a.first + (b.last - b.first + 1) + mid.len))

func toggled*(lines: seq[string], card: Card): seq[string] =
  ## the file's lines with the card's box ticked if it was open, or unticked if it was done
  result = lines
  result[card.first] = ticked(lines[card.first], not card.done)

# ── the file: its tab, or on disk ──

proc listPath(): string =
  ## the full path of the board's file (the file setting, from the project's folder unless it is absolute)
  let f = setting("file", "TODO.md")
  if f.isAbsolute: f else: projectRoot() / f

proc listBuf(): Buf =
  ## the open tab of the board's file; an invalid buffer when it is not open
  let p = listPath()
  for b in buffers():
    if b.path == p: return b
  Buf(id: -1)

proc readList(): seq[string] =
  ## the lines of the board's file: from its tab when it is open (with changes not saved too), else from disk; none when
  ## there is no such file
  let b = listBuf()
  if b.valid: return b.lines
  let p = listPath()
  if fileExists(p):
    result = readFile(p).replace("\r\n", "\n").split('\n')
    if result.len > 0 and result[^1].len == 0: result.setLen(result.len - 1)

proc writeList(ls: seq[string]) =
  ## the file changed: in its tab when it is open (saved, when it had no other changes), else opened, changed and
  ## saved
  var b = listBuf()
  let clean = not b.valid or not b.dirty
  if not b.valid: b = openFile(listPath())
  if not b.valid:
    warn("Kanban: " & listPath() & " could not be opened")
    return
  b.setText(ls.join("\n"))
  if clean:
    try: b.save()
    except ValueError as e: warn("Kanban: " & extractFilename(listPath()) & " is changed in its tab — save it (" &
                                 e.msg & ")")

# ── the board ──

func width(s: string): int =
  ## the characters of a UTF-8 text (as many columns as it takes, near enough)
  for c in s:
    if (ord(c) and 0xC0) != 0x80: inc result

func cut(s: string, w: int): string =
  ## at most w characters: the text cut, … at its end
  if width(s) <= w: return s
  var n = 0
  for i, c in s:
    if (ord(c) and 0xC0) != 0x80:
      if n == w - 1: return s[0 ..< i] & "…"
      inc n
  s

func wrap(s: string, w, most: int): seq[string] =
  ## the words of s in lines of at most w characters, `most` lines at most (the last one cut)
  var cur = ""
  for word in s.splitWhitespace:
    if cur.len == 0: cur = word
    elif width(cur) + 1 + width(word) <= w: cur.add " " & word
    else:
      result.add cut(cur, w)
      cur = word
  if cur.len > 0 or result.len == 0: result.add cut(cur, w)
  if result.len > most:
    result.setLen(most)
    result[^1] = cut(result[^1] & " …", w)

type Spot = object
  row, a, b: int                 # a row of the board and its bytes a ..< b
  col, card: int                 # the column and card there (card -1: the column's heading)

var
  cols: seq[Column]
  spots: seq[Spot]
  boardTab = Buf(id: -1)

# s followed by spaces up to w columns
func pad(s: string, w: int): string = s & spaces(max(0, w - width(s)))

proc render*(cs: seq[Column], file: string, paneWidth: int): (string, seq[Spot]) =
  ## the board as text, and where each card is in it: side by side when they fit, else one under another
  var rows: seq[string]
  var sp: seq[Spot]
  rows.add "▦ " & file & " — " & $cs.len & " columns · Alt+←/→ move a card, Alt+↑/↓ up or down, Alt+Enter: to it"
  rows.add ""
  let n = max(1, cs.len)
  let colW = min(34, (paneWidth - 2 * (n - 1)) div n)
  if colW >= 16:
    # side by side: a cell for each column on each row
    var cells: seq[seq[(string, int)]]           # for each column, its rows: (text, card; -1 the heading, -2 none)
    for c in cs:
      var cl = @[(cut(c.name.toUpperAscii & " (" & $c.cards.len & ")", colW), -1), ("─".repeat(colW), -2)]
      for k, card in c.cards:
        let ls = wrap(card.text, colW - 2, 3)
        for j, l in ls: cl.add ((if j == 0: (if card.done: "☑ " else: "☐ ") else: "  ") & l, k)
      cells.add cl
    var height = 0
    for cl in cells: height = max(height, cl.len)
    for r in 0 ..< height:
      var line = ""
      for ci, cl in cells:
        let a = line.len
        let (t, k) = if r < cl.len: cl[r] else: ("", -2)
        line.add pad(t, colW)
        if k >= -1: sp.add Spot(row: rows.len, a: a, b: line.len, col: ci, card: k)
        if ci < cells.high: line.add "  "
      rows.add line.strip(leading = false)
  else:
    for ci, c in cs:
      sp.add Spot(row: rows.len, a: 0, b: high(int), col: ci, card: -1)
      rows.add c.name.toUpperAscii & " (" & $c.cards.len & ")"
      for k, card in c.cards:
        for j, l in wrap(card.text, max(20, paneWidth - 4), 3):
          sp.add Spot(row: rows.len, a: 0, b: high(int), col: ci, card: k)
          rows.add (if j == 0: (if card.done: "  ☑ " else: "  ☐ ") else: "    ") & l
      rows.add ""
  (rows.join("\n"), sp)

proc paneWidth(): int =
  ## how many columns the active pane has for the board (less the gutter); 100 when it cannot be found
  result = 100
  try:
    for p in panes():
      if p.active: result = p.w - 8                 # (the gutter's columns)
  except ValueError: discard

proc spotAt(p: Pos): (int, int) =
  ## the column and card at a place of the board ((-1, -1): none)
  for s in spots:
    if s.row == p.line and p.col >= s.a and (p.col < s.b or s.b == high(int)): return (s.col, s.card)
  # (past a cell's end on its row: the nearest cell before)
  var best = (-1, -1)
  for s in spots:
    if s.row == p.line and s.a <= p.col: best = (s.col, s.card)
  best

proc boardOpen(): bool =
  ## whether the board's tab is still open
  if not boardTab.valid: return false
  for b in buffers():
    if b.id == boardTab.id: return true
  false

proc showBoard(focus = (-1, -1), front = true) =
  ## the board drawn again from the file — brought to the front, or where it is; the cursor on a card (column,
  ## card) when given
  let ls = readList()
  cols = columnsOf(ls, setting("level", 2))
  let (text, sp) = render(cols, extractFilename(listPath()), paneWidth())
  spots = sp
  if front or not boardOpen(): boardTab = newTab("Kanban: " & extractFilename(listPath()), text, "kanban")
  else: boardTab.setText(text)
  try:
    boardTab.markSaved()                         # (no question when it closes; newTab may use it again)
    if focus[0] >= 0:
      for s in spots:
        if s.col == focus[0] and s.card == focus[1]:
          boardTab.setCursor(pos(s.row, s.a))
          break
  except ValueError: discard

proc refreshAll(focus = (-1, -1), front = false) =
  ## after a change: the board drawn again (to the front when the change was made on it), the dock's view too
  if front or boardOpen(): showBoard(focus, front)
  refreshView(View)

proc cardAt(b: Buf): (int, int) =
  ## the card at the cursor: on the board, or a line of the file
  if b.lang == "kanban": return spotAt(b.cursor)
  if b.path == listPath():
    cols = columnsOf(b.lines, setting("level", 2))
    return cardAtLine(cols, b.cursor.line)
  (-1, -1)

proc fresh(): bool =
  ## the columns read again from the file; false (said) when it has none
  cols = columnsOf(readList(), setting("level", 2))
  if cols.len == 0:
    message("Kanban: " & extractFilename(listPath()) & " has no headings to be columns (## To do, ## Doing, ## Done)")
    return false
  true

proc moveTo(ci, k, to: int, fromBoard: bool) =
  ## moves card k of column ci to the end of column `to` in the file (ticked or unticked as the done column asks), says
  ## so, and draws the board again with the cursor on the card; nothing happens for places that do not exist
  let ls = readList()
  cols = columnsOf(ls, setting("level", 2))
  if ci < 0 or ci >= cols.len or k < 0 or k >= cols[ci].cards.len or to < 0 or to >= cols.len or to == ci: return
  let (nl, at) = moved(ls, cols, ci, k, to, setting("doneColumn", "Done"))
  writeList(nl)
  let nc = columnsOf(nl, setting("level", 2))
  message("Kanban: “" & cut(cols[ci].cards[k].text, 40) & "” → " & nc[to].name)
  refreshAll(cardAtLine(nc, at), fromBoard)

proc moveBy(b: Buf, step: int) =
  ## moves the card at the cursor to the column step places along (1 the next, -1 the one before); nothing at the first
  ## and last columns
  let (ci, k) = cardAt(b)
  if k < 0:
    message("Kanban: put the cursor on a card")
    return
  if ci + step < 0 or ci + step >= cols.len: return
  moveTo(ci, k, ci + step, b.lang == "kanban")

proc upDown(b: Buf, by: int) =
  ## swaps the card at the cursor with the one above (by -1) or below (1) it in its column, in the file, and draws the
  ## board again with the cursor on it
  let (ci, k) = cardAt(b)
  if k < 0:
    message("Kanban: put the cursor on a card")
    return
  let ls = readList()
  cols = columnsOf(ls, setting("level", 2))
  if k + by < 0 or k + by >= cols[ci].cards.len: return
  let (nl, at) = swapped(ls, cols, ci, k, by)
  writeList(nl)
  refreshAll(cardAtLine(columnsOf(nl, setting("level", 2)), at), b.lang == "kanban")

proc goTo(ci, k: int) =
  ## opens the board's file at the first line of card k of column ci
  if ci >= 0 and k >= 0 and ci < cols.len and k < cols[ci].cards.len:
    discard openFile(listPath(), cols[ci].cards[k].first)

proc goToAt(b: Buf) =
  ## opens the board's file at the card at the cursor
  let (ci, k) = cardAt(b)
  goTo(ci, k)

proc chooseColumn(title: string, skip = -1): int =
  ## lists the columns (with their card counts, but not column skip) to pick one; gives its place, -1 when nothing was
  ## picked
  var items, dets: seq[string]
  var idx: seq[int]
  for i, c in cols:
    if i == skip: continue
    items.add c.name
    dets.add $c.cards.len & " card" & (if c.cards.len == 1: "" else: "s")
    idx.add i
  let i = pick(title, items, dets)
  if i < 0: -1 else: idx[i]

proc cardMenu(ci, k: int, fromBoard: bool) =
  ## a list of what can be done with card k of column ci — move it to another column, tick or untick it, move it up or
  ## down, go to it in the file — and does the one chosen
  if ci < 0 or ci >= cols.len or k < 0 or k >= cols[ci].cards.len: return
  let card = cols[ci].cards[k]
  var items, dets: seq[string]
  var acts: seq[int]                             # ≥ 0 a column to move to; -1 tick, -2 up, -3 down, -4 go to it
  for i, c in cols:
    if i != ci:
      items.add "Move to " & c.name
      dets.add $c.cards.len & " card" & (if c.cards.len == 1: "" else: "s")
      acts.add i
  items.add (if card.done: "Not done" else: "Done")
  dets.add "[x] or [ ]"
  acts.add -1
  if k > 0:
    items.add "Up"
    dets.add "above " & cut(cols[ci].cards[k - 1].text, 30)
    acts.add -2
  if k < cols[ci].cards.high:
    items.add "Down"
    dets.add "below " & cut(cols[ci].cards[k + 1].text, 30)
    acts.add -3
  items.add "Go to it in " & extractFilename(listPath())
  dets.add "line " & $(card.first + 1)
  acts.add -4
  let i = pick(cut(card.text, 60) & " — " & cols[ci].name, items, dets)
  if i < 0: return
  let a = acts[i]
  if a >= 0: moveTo(ci, k, a, fromBoard)
  elif a == -1:
    writeList(toggled(readList(), card))
    refreshAll((ci, k), fromBoard)
  elif a in [-2, -3]:
    let ls = readList()
    let (nl, at) = swapped(ls, cols, ci, k, (if a == -2: -1 else: 1))
    writeList(nl)
    refreshAll(cardAtLine(columnsOf(nl, setting("level", 2)), at), fromBoard)
  else: goTo(ci, k)

# ── commands, keys, the dock ──

command "Kanban: open the board":
  if fresh(): showBoard()

command "Kanban: move the card…":
  let b = current()
  let (ci, k) = cardAt(b)
  if k < 0: message("Kanban: put the cursor on a card (on the board, or a checklist line of " &
                    extractFilename(listPath()) & ")")
  else:
    let to = chooseColumn("Move “" & cut(cols[ci].cards[k].text, 40) & "” to", ci)
    if to >= 0: moveTo(ci, k, to, b.lang == "kanban")

command "Kanban: add a card…":
  if fresh():
    let text = ask("Kanban: the new card:")
    if text.strip.len > 0:
      let to = if cols.len == 1: 0 else: chooseColumn("Kanban: “" & cut(text.strip, 40) & "” in")
      if to >= 0:
        var ls = readList()
        let dest = cols[to]
        var at = if dest.cards.len > 0: dest.cards[^1].last + 1
                 else:
                   var e = dest.stop
                   while e - 1 > dest.line and ls[e - 1].strip.len == 0: dec e
                   e
        let done = cmpIgnoreCase(dest.name, setting("doneColumn", "Done")) == 0
        ls.insert("- [" & (if done: "x" else: " ") & "] " & text.strip, at)
        writeList(ls)
        message("Kanban: a card added to " & dest.name)
        refreshAll(cardAtLine(columnsOf(ls, setting("level", 2)), at))

keyIn("kanban", "alt+right", "move the card to the next column", proc(b: Buf) = moveBy(b, 1))
keyIn("kanban", "alt+left", "move the card to the column before", proc(b: Buf) = moveBy(b, -1))
keyIn("kanban", "alt+up", "move the card up its column", proc(b: Buf) = upDown(b, -1))
keyIn("kanban", "alt+down", "move the card down its column", proc(b: Buf) = upDown(b, 1))
keyIn("kanban", "alt+enter", "go to the card in the file", proc(b: Buf) = goToAt(b))
nmapIn("kanban", ">", "move the card to the next column", proc(count: int) = moveBy(current(), 1))
nmapIn("kanban", "<", "move the card to the column before", proc(count: int) = moveBy(current(), -1))
nmapIn("kanban", "<CR>", "go to the card in the file", proc(count: int) = goToAt(current()))

onSave("*.md") do (ev: Event):
  if ev.path == listPath(): refreshAll()

view(View) do () -> seq[ViewItem]:
  let ls = readList()
  cols = columnsOf(ls, setting("level", 2))
  result.add ViewItem(text: "Open the board", icon: "▦", color: "accent", id: "board",
                      detail: extractFilename(listPath()))
  if cols.len == 0:
    result.add ViewItem(text: "no columns: ## headings in " & extractFilename(listPath()), icon: "·", color: "hint")
  for ci, c in cols:
    result.add ViewItem(text: c.name, detail: $c.cards.len, icon: "▸")
    for k, card in c.cards:
      result.add ViewItem(text: card.text, icon: (if card.done: "☑" else: "☐"), color: (if card.done: "hint" else: ""),
                          id: $ci & ":" & $k, depth: 1)
do (id: string):
  if id == "board":
    if fresh(): showBoard()
  else:
    let p = id.split(':')
    if p.len == 2:
      try: cardMenu(parseInt(p[0]), parseInt(p[1]), false)
      except ValueError: discard
