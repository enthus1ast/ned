# which inlay hints may be drawn on a line of the editor, and the tables that keep the Markdown previews' lines and the
# previews' and diffs' cursor lines between frames
proc lineInlays(b: Buffer, line: int, toks: seq[TokKind]): seq[(int, string)] =
  ## the hints that can be shown on a line: never past its end, never inside a comment or string, and a
  ## type (`: int`) only right after a name, or a call chain's step (`.mapIt(…): seq[int]`) — a hint left over
  ## from older text is not drawn. A saved Nim file's lets and vars get the type the compiler gave them, when its NIF
  ## says (nimnif.nim), in place of the engine's
  if line >= b.lines.len: return
  let fromNif = if b.lang.mode == lmNim: nifTypeHints(b, line) else: @[]
  if line notin b.inlays and fromNif.len == 0: return
  let s = b.lines[line]
  for (col, label) in b.inlays.getOrDefault(line):
    if col > s.len: continue
    if col > 0 and col - 1 < toks.len and toks[col - 1] in {tkComment, tkDoc, tkString, tkChar}: continue
    if label.strip.startsWith(":") and
       (col == 0 or s[col - 1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '`', '\x80'..'\xFF', ')', ']'}):
      continue
    var nl = label
    for (c, t) in fromNif:
      if c == col and label.strip.startsWith(":"): nl = (if label.startsWith(" "): " " else: "") & t
    result.add (col, nl)
  for (c, t) in fromNif:
    var have = false
    for (col, _) in result:
      if col == c: have = true
    if not have and c <= s.len: result.add (c, t)
  if fromNif.len > 0: result.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))

proc drawDocLines(lines: seq[ChatLine], x, y, w, h, scroll: int, bg: Rgb)

var mdPreviewCache: Table[int, (int, int, seq[ChatLine])]     # preview id → (source change, width, lines)
var viewHead: Table[int, int]          # previews and diffs: the cursor line last drawn (the view follows it when it moves)
