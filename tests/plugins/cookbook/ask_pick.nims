## word-tools — asking you things: pick a case for the word at the cursor (pick), and replace a word everywhere
## in the file (ask for the new one, confirm how many)
import nedplugin

requiresNed(">= 6.31")

func wordRange(l: string, line, col: int): Range =
  ## the word around column `col` of the line `l` (number `line`)
  var a = col
  var e = col
  while a > 0 and l[a - 1] in IdentChars: dec a
  while e < l.len and l[e] in IdentChars: inc e
  rng(pos(line, a), pos(line, e))

func snake(w: string): string =
  ## fooBar → foo_bar
  for i, c in w:
    if c in {'A'..'Z'}:
      if i > 0 and w[i - 1] notin {'_', 'A'..'Z'}: result.add '_'
      result.add c.toLowerAscii
    else: result.add c

func camel(w: string): string =
  ## foo_bar → fooBar
  var up = false
  for c in w:
    if c == '_': up = true
    elif up:
      result.add c.toUpperAscii
      up = false
    else: result.add c

proc changeCase(b: Buf) =
  ## offers the word at the cursor in five forms (UPPER, lower, Capitalised, snake_case, camelCase) in a pick list and
  ## replaces the word with the one chosen; nothing happens on Esc
  let c = b.cursor
  let r = wordRange(b.line(c.line), c.line, c.col)
  if r.isEmpty:
    message("No word at the cursor")
    return
  let w = b.textIn(r)
  let forms = [w.toUpperAscii, w.toLowerAscii, w.toLowerAscii.capitalizeAscii, snake(w), camel(w)]
  # the list shows each form, its name beside it; -1 when you press Esc
  let i = pick("Change " & w & " to…", forms, ["UPPER", "lower", "Capitalised", "snake_case", "camelCase"])
  if i >= 0: b.replace(r, forms[i])

proc replaceEverywhere(b: Buf) =
  ## asks for a new word for the one at the cursor, finds every place the file has it as a whole word, asks to confirm
  ## the count, then replaces them from the last backwards so the earlier places keep their columns
  let w = b.wordAt(b.cursor)
  if w.len == 0:
    message("No word at the cursor")
    return
  let to = ask("Replace " & w & " with:", w)  # (what you typed, or "" when you press Esc)
  if to.len == 0 or to == w: return
  var places: seq[Range]                      # every place it is a whole word
  for i, l in b.lines:
    var k = l.find(w)
    while k >= 0:
      let e = k + w.len
      if (k == 0 or l[k - 1] notin IdentChars) and (e >= l.len or l[e] notin IdentChars):
        places.add rng(pos(i, k), pos(i, e))
      k = l.find(w, e)
  if not confirm("Replace " & w & " with " & to & " in " & $places.len & " places?"): return
  for i in countdown(places.high, 0):         # (from the last: the places before it stay where they are)
    b.replace(places[i], to)
  toast($places.len & " replaced — Ctrl+Z puts them all back")

command "Word: change its case…", "ctrl+alt+k":
  changeCase(current())

command "Word: replace it everywhere in the file…":
  replaceEverywhere(current())
