# ── one-line text fields (prompts, the picker's query, the dock's search, forms): the selection in them ──
# A field is its text variable: the selection belongs to the field whose text's address it holds (the cursor is
# the field's own), so one set of keys and one mouse model serves every field — Shift+arrows, Ctrl+A, a drag, a
# double click on a word; typing or pasting replaces what is selected, Ctrl+C / Ctrl+X copy and cut it.

var
  fieldSelOwner: pointer          # the text the selection is in
  fieldSelAnchor = -1             # its other end (the field's cursor is the one end)

proc fieldOwns(text: var string): bool {.inline.} = fieldSelOwner == cast[pointer](addr text)

proc fieldSelRange(text: var string, cur: int): (int, int) =
  ## the selected bytes [a, b) of this field — (cur, cur) when nothing is selected in it
  if fieldOwns(text) and fieldSelAnchor >= 0 and fieldSelAnchor != cur:
    let a = clamp(fieldSelAnchor, 0, text.len)
    (min(a, cur), max(a, cur))
  else: (cur, cur)

proc fieldSelClear() = fieldSelAnchor = -1

proc fieldSelect(text: var string, a, b: int) =
  ## select text[a ..< b] (the cursor ends at b)
  fieldSelOwner = cast[pointer](addr text)
  fieldSelAnchor = clamp(a, 0, text.len)

proc fieldDeleteSel(text: var string, cur: var int): bool =
  ## the selection removed (the cursor where it was); false when nothing was selected
  let (a, b) = fieldSelRange(text, cur)
  if a == b: return false
  text.delete(a ..< b)
  cur = a
  fieldSelClear()
  true

proc fieldSelText(text: var string, cur: int): string =
  let (a, b) = fieldSelRange(text, cur)
  text[a ..< b]

func fieldWordStart(s: string, i: int): int =
  result = clamp(i, 0, s.len)
  while result > 0 and s[result - 1] == ' ': dec result
  while result > 0 and s[result - 1] notin {' ', '/', '.', ',', ':', '(', ')', '[', ']', '"'}: dec result

func fieldWordEnd(s: string, i: int): int =
  result = clamp(i, 0, s.len)
  while result < s.len and s[result] == ' ': inc result
  while result < s.len and s[result] notin {' ', '/', '.', ',', ':', '(', ')', '[', ']', '"'}: inc result
