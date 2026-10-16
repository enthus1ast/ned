proc lineInlays(b: Buffer, line: int, toks: seq[TokKind]): seq[(int, string)] =
  ## the hints that can be shown on a line: never past its end, never inside a comment or string, and a
  ## type (`: int`) only right after a name — a hint left over from older text is not drawn
  if line notin b.inlays or line >= b.lines.len: return
  let s = b.lines[line]
  for (col, label) in b.inlays[line]:
    if col > s.len: continue
    if col > 0 and col - 1 < toks.len and toks[col - 1] in {tkComment, tkDoc, tkString, tkChar}: continue
    if label.strip.startsWith(":") and
       (col == 0 or s[col - 1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '`', '\x80'..'\xFF'}):
      continue
    result.add (col, label)

proc drawDocLines(lines: seq[ChatLine], x, y, w, h, scroll: int, bg: Rgb)

var mdPreviewCache: Table[int, (int, int, seq[ChatLine])]     # preview id → (source change, width, lines)
var viewHead: Table[int, int]          # previews and diffs: the cursor line last drawn (the view follows it when it moves)
