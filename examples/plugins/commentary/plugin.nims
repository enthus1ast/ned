## commentary — vim's gc operator and an ie text object (editor.vimMode on).
##
##   gcc     comment or uncomment the line (3gcc: three lines)
##   gc{motion}, gcip, gcie   the lines a motion or a text object covers
##   gc      on a visual selection
##   ie      the whole text as a text object: yie copies it, die empties it, vie selects it
##   :Comment   the current line (or :Comment 5 for five lines)
## ned has its own gc; this one shows how a plugin makes operators and text objects (it takes the place of ned's).
import nedplugin

proc toggle(b: Buf, first, last: int) =
  let cm = b.lineComment
  if cm.len == 0:
    message("this language has no line comment")
    return
  # (all commented: uncomment them; else comment them, at the smallest indentation)
  var all = true
  var ind = high(int)
  for l in first .. last:
    let s = b.line(l)
    if s.strip.len == 0: continue
    if not s.strip.startsWith(cm): all = false
    ind = min(ind, s.len - s.strip(trailing = false).len)
  if ind == high(int): return
  var lines: seq[string]
  for l in first .. last:
    let s = b.line(l)
    if s.strip.len == 0: lines.add s
    elif all:
      let k = s.find(cm)
      var e = k + cm.len
      if e < s.len and s[e] == ' ': inc e
      lines.add s[0 ..< k] & s[e .. ^1]
    else: lines.add s[0 ..< ind] & cm & " " & s[ind .. ^1]
  b.replace(rng(pos(first, 0), pos(last, b.line(last).len)), lines.join("\n"))

operator("gc") do (b: Buf, r: Range, linewise: bool):
  var last = r.stop.line
  if not linewise and r.stop.col == 0 and last > r.start.line: dec last
  toggle(b, r.start.line, last)

textObject("ie") do (b: Buf, p: Pos) -> Range:
  let n = b.lineCount
  rng(pos(0, 0), pos(n - 1, b.line(n - 1).len))

exCommand("Comment") do (args: string):
  let b = current()
  let l = b.cursor.line
  let n = (try: parseInt(args.strip) except ValueError: 1)
  toggle(b, l, min(b.lineCount - 1, l + max(1, n) - 1))
