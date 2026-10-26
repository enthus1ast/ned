## line-tools — reading and changing the text: sort or number the selected lines, upper-case each cursor's
## selection, remove blank lines, swap a line with the next — each command one undo step
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

proc selectedLines(b: Buf): (int, int) =
  ## the first and last line the selection touches (the cursor's line when nothing is selected) — a selection
  ## that ends at the start of a line leaves that line out
  let r = b.selection
  var last = r.stop.line
  if last > r.start.line and r.stop.col == 0: dec last
  (r.start.line, last)

proc sortLines(b: Buf) =
  ## the selected lines (nothing selected: every line) sorted, A and a together; then selected
  var (first, last) = selectedLines(b)
  if first == last: (first, last) = (0, b.lineCount - 1)
  var ls = b.lines(first, last)
  ls.sort(proc(x, y: string): int = cmp(x.toLowerAscii, y.toLowerAscii))
  b.replace(rng(pos(first, 0), pos(last, b.line(last).len)), ls.join("\n"))
  b.select(rng(pos(first, 0), pos(last, ls[^1].len)))
  message("Sorted " & $ls.len & " lines")

proc numberLines(b: Buf) =
  ## "1. ", "2. " … at the start of the selected lines — many inserts, one undo step
  let (first, last) = selectedLines(b)
  let width = len($(last - first + 1))
  for i in first .. last:
    let n = $(i - first + 1)
    b.insert(pos(i, 0), " ".repeat(width - n.len) & n & ". ")

func wordRange(l: string, line, col: int): Range =
  ## the word around column `col` of the line `l` (line number `line`): letters, digits and _
  var a = col
  var e = col
  while a > 0 and l[a - 1] in IdentChars: dec a
  while e < l.len and l[e] in IdentChars: inc e
  rng(pos(line, a), pos(line, e))

proc upperEach(b: Buf) =
  ## each cursor's selection in capitals — or, where nothing is selected, the word at that cursor
  var rs = b.selections                       # (one for each cursor; not in the file's order)
  rs.sort(proc(x, y: Range): int = cmp((x.start.line, x.start.col), (y.start.line, y.start.col)))
  # from the last to the first: an edit moves the text after it, not the text before
  for i in countdown(rs.high, 0):
    var r = rs[i]
    if r.isEmpty: r = wordRange(b.line(r.start.line), r.start.line, r.start.col)
    if not r.isEmpty: b.replace(r, b.textIn(r).toUpperAscii)

proc removeBlankLines(b: Buf) =
  ## the blank lines among the selected ones (nothing selected: in the whole file) deleted, line ends and all
  var (first, last) = selectedLines(b)
  if first == last: (first, last) = (0, b.lineCount - 1)
  let ls = b.lines(first, last)
  var n = 0
  for i in countdown(ls.high, 0):
    if ls[i].strip.len > 0: continue
    let l = first + i
    if l == b.lineCount - 1 and l > 0:
      # the file's last line has no line end of its own: it goes with the one of the line before it
      b.delete(rng(pos(l - 1, b.line(l - 1).len), pos(l, b.line(l).len)))
    else:
      b.delete(b.wholeLines(l, l))
    inc n
  message("Removed " & $n & " blank lines — Ctrl+Z puts them all back")

proc swapDown(b: Buf) =
  ## the cursor's line and the one below it change places; the cursor goes with its line
  let c = b.cursor
  if c.line + 1 >= b.lineCount: return
  let here = b.line(c.line)
  let below = b.line(c.line + 1)
  b.replace(rng(pos(c.line, 0), pos(c.line + 1, below.len)), below & "\n" & here)
  b.setCursor(pos(c.line + 1, c.col))

command "Line tools: sort the lines":
  sortLines(current())
command "Line tools: number the lines":
  numberLines(current())
command "Line tools: upper-case each selection", "ctrl+alt+u":
  upperEach(current())
command "Line tools: remove the blank lines":
  removeBlankLines(current())
command "Line tools: swap the line with the next", "alt+shift+n":
  swapDown(current())
