## whitespace-check — problems with quick fixes: spaces at the end of a line, and a tab in an indentation of
## spaces; Alt+Enter on the line offers to fix it, or to fix every line of the file at once
import nedplugin

requiresNed(">= 6.31")

proc check(b: Buf) =
  ## the file's problems, all set in one request (they take the place of the ones this plugin set before)
  let ls = b.lines
  let unit = b.indentUnit                     # "  ", "    " or "\t": what this file indents with
  let lineBreaks = b.lang == "markdown"       # (two spaces at a line's end are a line break there)
  var ends: seq[Edit]                         # every line's spaces at its end: the whole-file fix
  var ps: seq[Problem]
  for i, l in ls:
    let t = l.strip(leading = false)
    if t.len < l.len and not lineBreaks:
      let r = rng(pos(i, t.len), pos(i, l.len))
      ends.add Edit(range: r, text: "")
      ps.add Problem(range: r, severity: 4, message: "spaces at the end of the line",
                     fixes: @[Fix(title: "Remove them", edits: @[Edit(range: r, text: "")])])
    var k = 0
    while k < l.len and l[k] in {' ', '\t'}: inc k
    if unit != "\t" and '\t' in l[0 ..< k]:
      let r = rng(pos(i, 0), pos(i, k))
      let spaces = l[0 ..< k].replace("\t", unit)
      ps.add Problem(range: r, severity: 2, message: "a tab in an indentation of spaces",
                     fixes: @[Fix(title: "Indent with spaces", edits: @[Edit(range: r, text: spaces)])])
  if ends.len > 1:
    # one fix with many edits: all of them one undo step
    let all = Fix(title: "Remove the spaces at the ends of all " & $ends.len & " lines", edits: ends)
    for p in ps.mitems:
      if p.severity == 4: p.fixes.add all
  b.setProblems(ps)

onOpen("*") do (ev: Event):
  check(ev.buf)
onChange("*") do (ev: Event):                 # (problems stay where they were put: set them again after a change)
  check(ev.buf)

command "Whitespace: check this file":
  let b = current()
  check(b)
  message("Whitespace: checked " & extractFilename(b.path) & " (Alt+N: the next problem)")

command "Whitespace: clear the marks":
  current().clearProblems()
