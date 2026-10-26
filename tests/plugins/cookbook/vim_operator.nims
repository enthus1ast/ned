## sort-motion — vim (editor.vimMode): an operator that sorts (gsip a paragraph's lines, gss the line and as
## many as the count, gsi( the items between brackets), text objects for a line (il its text, al the whole line),
## mappings with a count, and :Sort
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

proc sortRange(b: Buf, r: Range, linewise: bool, reverse = false, unique = false) =
  if linewise or r.start.line != r.stop.line:
    let first = r.start.line
    var last = r.stop.line
    if not linewise and r.stop.col == 0 and last > first: dec last   # (a motion that ends at a line's start)
    var ls = b.lines(first, last)
    ls.sort()
    if reverse: ls.reverse()
    if unique:
      var kept: seq[string]
      for l in ls:
        if kept.len == 0 or kept[^1] != l: kept.add l
      ls = kept
    b.replace(rng(pos(first, 0), pos(last, b.line(last).len)), ls.join("\n"))
  else:
    # within a line: the items between commas — "c, a, b" → "a, b, c"
    var items = b.textIn(r).split(',')
    for it in items.mitems: it = it.strip
    items.sort()
    b.replace(r, items.join(", "))

# gs then a motion or a text object; gss for lines; gs on a visual selection
operator("gs", "sort") do (b: Buf, r: Range, linewise: bool):
  sortRange(b, r, linewise)

# il: the line's text, without its indentation and the spaces at its end — cil, dil, yil, vil
textObject("il", "the line's text") do (b: Buf, p: Pos) -> Range:
  let l = b.line(p.line)
  let t = l.strip
  if t.len == 0: return noRange()             # (nothing there: the operator does nothing)
  let a = l.len - l.strip(trailing = false).len
  rng(pos(p.line, a), pos(p.line, a + t.len))

# al: the whole line, its line end too — from its start to the next line's start: operators take it as lines
textObject("al", "the whole line") do (b: Buf, p: Pos) -> Range:
  b.wholeLines(p.line, p.line)

proc moveLine(down: bool, count: int) =
  ## the cursor's line moved down (or up) past `count` lines; the cursor goes with it
  let b = current()
  let l = b.cursor.line
  let other = if down: min(b.lineCount - 1, l + count) else: max(0, l - count)
  if other == l: return
  let (a, e) = (min(l, other), max(l, other))
  var ls = b.lines(a, e)
  if down:
    ls.add ls[0]                              # the first line to the end
    ls.delete(0)
  else:
    ls.insert(ls[^1], 0)                      # the last line to the start
    ls.setLen(ls.len - 1)
  b.replace(rng(pos(a, 0), pos(e, b.line(e).len)), ls.join("\n"))
  b.setCursor(pos(other, 0))

# ]e and [e move the line; 3]e moves it three lines down
nmap("]e", "move the line down") do (count: int):
  moveLine(true, count)
nmap("[e", "move the line up") do (count: int):
  moveLine(false, count)

# :Sort — the whole file; :Sort r backwards; :Sort u without lines given twice
exCommand("Sort") do (args: string):
  let b = current()
  sortRange(b, b.wholeLines(0, b.lineCount - 1), true, reverse = 'r' in args, unique = 'u' in args)
