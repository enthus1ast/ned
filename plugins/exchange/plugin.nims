## exchange — swap two pieces of text: mark one, then the other, and they change places
##
##   Exchange: mark the selection (then again to swap)   the first time it marks the selection (or the cursor's
##                     line when nothing is selected) — tinted, and ⇄ in the gutter; the second time the two swap
##   Exchange: clear   forget the marked text
##   vim (as vim-exchange)   cx{motion} or cx{text object}: cxiw, cxia (with text-objects), cx$, cxf), cxgg, cxip —
##                     then the same on the other text; cxx the line (3cxx three lines); cxc forgets the marked text
##                     (so does cX, or cx again on it); in visual mode X or cx, on what is selected (V: whole lines).
##                     The other text can be in another file
##   The text marked first is checked before the swap: when it has changed, the second one is marked instead. When
##   one is inside the other, the larger one is replaced by the smaller. One undo step puts both back.
import nedplugin

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

type Marked = object
  buf: int                       ## the file (-1: nothing is marked)
  r: Range
  text: string

var marked = Marked(buf: -1)

# whether position a comes earlier in the buffer than b
func before(a, b: Pos): bool = a.line < b.line or (a.line == b.line and a.col < b.col)
# whether position a is b or comes earlier
func atOrBefore(a, b: Pos): bool = not before(b, a)
# whether the two ranges start and stop at the same places
func same(a, b: Range): bool = a.start.line == b.start.line and a.start.col == b.start.col and
                               a.stop.line == b.stop.line and a.stop.col == b.stop.col

proc unmark() =
  ## forgets the marked text and takes its tint and ⇄ sign off (nothing is done to it when its tab has been closed)
  if marked.buf >= 0:
    try: Buf(id: marked.buf).clearDecorations()
    except CatchableError: discard                  # (its tab was closed)
  marked = Marked(buf: -1)

proc mark(b: Buf, r: Range, text: string) =
  ## marks the range r of the buffer as the first text of an exchange (replacing any mark before): remembers where it is
  ## and what it says, tints it and puts ⇄ in the gutter at its first line
  unmark()
  marked = Marked(buf: b.id, r: r, text: text)
  if not r.isEmpty: b.highlight(r, "accent")
  b.sign(r.start.line, "⇄", "accent")

func shifted(p: Pos, old: Range, newText: string): Pos =
  ## where p (after old) is once old's text is newText
  if before(p, old.stop): return p
  let nl = newText.count('\n')
  let lastLen = if nl == 0: newText.len else: newText.len - newText.rfind('\n') - 1
  if p.line == old.stop.line:
    pos(old.start.line + nl, (if nl == 0: old.start.col else: 0) + lastLen + p.col - old.stop.col)
  else:
    pos(p.line + nl - (old.stop.line - old.start.line), p.col)

proc exchange(b: Buf, r: Range, moveCursor = true) =
  ## r marked, or swapped with the text marked before (the cursor then where the second one was)
  if marked.buf < 0:
    mark(b, r, b.textIn(r))
    message("Exchange: marked — now the other text (cx, or Exchange: mark the selection) swaps them")
    return
  let mb = Buf(id: marked.buf)
  if mb.id == b.id and same(r, marked.r):
    unmark()
    message("Exchange: forgotten")
    return
  var now = ""
  try: now = mb.textIn(marked.r)
  except CatchableError: now = "\0"                # (its tab was closed)
  if now != marked.text:
    mark(b, r, b.textIn(r))
    message("Exchange: the text marked first has changed — this one is marked instead")
    return
  let t2 = b.textIn(r)
  let m = marked.r
  var at = r.start
  if mb.id != b.id:
    b.replace(r, marked.text)
    mb.replace(m, t2)
  elif atOrBefore(m.start, r.start) and atOrBefore(r.stop, m.stop):
    b.replace(m, t2)                                 # (the second inside the first: the first becomes it)
    at = m.start
  elif atOrBefore(r.start, m.start) and atOrBefore(m.stop, r.stop):
    b.replace(r, marked.text)                        # (the first inside the second)
  elif before(m.start, r.stop) and before(r.start, m.stop):
    message("Exchange: the two texts overlap — mark another one, or Exchange: clear")
    return
  elif before(m.start, r.start):
    # (the later one first: the earlier one's place does not move)
    b.replace(r, marked.text)
    b.replace(m, t2)
    at = shifted(r.start, m, t2)
  else:
    b.replace(m, t2)
    b.replace(r, marked.text)
  unmark()
  if moveCursor: b.setCursor(at)

proc linesRange(b: Buf, first, last: int): Range =
  ## the range of whole lines first … last, from the start of the first to the end of the last
  rng(pos(first, 0), pos(last, b.line(last).len))

command "Exchange: mark the selection (then again to swap)":
  let b = current()
  if b.valid:
    let r = b.selection
    exchange(b, if r.isEmpty: b.linesRange(r.start.line, r.start.line) else: r)

proc forget() =
  ## Exchange: clear — forgets the marked text, or says that nothing is marked
  if marked.buf < 0: message("Exchange: nothing is marked")
  else:
    unmark()
    message("Exchange: forgotten")

command "Exchange: clear": forget()

operator("cx", "exchange: mark, then swap with the next (cxx: the line)") do (b: Buf, r: Range, linewise: bool):
  var x = r
  if linewise: x = b.linesRange(r.start.line, r.stop.line)
  exchange(b, x)

# (cxc: ned runs a mapping of an operator's keys and one more key in place of a motion)
nmap("cxc", "exchange: forget the marked text") do (count: int): forget()
nmap("cX", "exchange: forget the marked text") do (count: int): forget()

vmap("X", "exchange: mark the selection, or swap it") do (count: int):
  # (the selection as vim shows it: the character under the cursor in it, whole lines in visual-line mode; the
  # cursor left alone, so ned goes back to normal mode at the selection's start)
  let b = current()
  let r = b.selection
  exchange(b, (if r.isEmpty: b.linesRange(r.start.line, r.start.line) else: r), moveCursor = false)
