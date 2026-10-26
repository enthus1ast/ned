## regex-tools — ned's own regular expressions (NimScript has none): every match in the file listed in the
## Output panel, a click going to it; and a replacement in the selection with groups ($1)
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

proc findAll(b: Buf) =
  let pattern = ask("Find (a regular expression):")
  if pattern.len == 0: return
  let text = b.text
  var starts = @[0]                           # where each line starts in the text
  for i, c in text:
    if c == '\n': starts.add i + 1
  var rows: seq[string]
  try:
    for m in regexMatches(pattern, text):     # one request for the whole text, not one a line
      let line = upperBound(starts, m.start) - 1
      let col = m.start - starts[line]
      rows.add b.path & ":" & $(line + 1) & ":" & $(col + 1) & ": " & text[m.start ..< min(m.stop, m.start + 80)]
  except ValueError as e:
    warn(e.msg)                               # (not a regular expression: ned says why)
    return
  output(rows.join("\n"))
  showOutput()
  message($rows.len & " matches")

proc replaceIn(b: Buf) =
  let sel = b.selection
  let r = if sel.isEmpty: rng(pos(0, 0), pos(b.lineCount - 1, b.line(b.lineCount - 1).len)) else: sel
  let pattern = ask("Replace (a regular expression):")
  if pattern.len == 0: return
  let repl = ask("With ($0 the match, $1 … $9 its groups):")
  try:
    let (t, n) = regexReplace(pattern, b.textIn(r), repl)
    if n > 0: b.replace(r, t)
    message($n & " replaced" & (if sel.isEmpty: " in the file" else: " in the selection"))
  except ValueError as e:
    warn(e.msg)

command "Regex: find every match…":
  findAll(current())

command "Regex: replace in the selection…":
  replaceIn(current())
