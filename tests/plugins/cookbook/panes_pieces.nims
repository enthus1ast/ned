## word-places — panes and multibuffers: every line of the open files with the word at the cursor, in one tab to
## edit them together; the test of a module beside it; and the file behind the cursor of a multibuffer
import nedplugin

requiresNed(">= 6.31")

proc wordPlaces() =
  ## collects, from every open file, each line that has the word at the cursor with a line either side, and opens them
  ## together in one multibuffer
  let b = current()
  let w = b.wordAt(b.cursor)
  if w.len == 0:
    message("Put the cursor on a word first")
    return
  var ps: seq[Piece]
  for x in buffers():
    if x.path.len == 0 or x.isMultibuffer: continue
    let ls = x.lines                          # (all its lines at once: one request, not one a line)
    for i, l in ls:
      if w in l: ps.add piece(x.path, max(0, i - 1), min(ls.high, i + 1))   # (a line around it)
  if ps.len == 0:
    message("No open file has " & w)
    return
  discard openMultibuffer("“" & w & "” in the open files", ps)

proc testBeside() =
  ## tests/test_<module>.nim beside the module, in a pane at its right
  let b = current()
  let (_, name, _) = splitFile(b.path)
  let test = projectRoot() / "tests" / ("test_" & name & ".nim")
  var here = 0
  for p in panes():
    if p.path == test:
      focusPane(p.index)                      # (it is shown already: go there)
      return
    if p.active: here = p.index
  if not fileExists(test):
    message("No tests/test_" & name & ".nim")
    return
  let t = openFile(test)                      # (it comes to the front of this pane …)
  showInPane(here, b)                         # (… the module goes back there)
  if splitPane(show = t) < 0: message("No room for another pane")

proc fileHere() =
  ## opens the real file, at the real line and column, behind the cursor's place in a multibuffer; says so when the
  ## cursor is not in a piece of one
  let b = current()
  let (path, at) = b.placeInFile(b.cursor)
  if path.len == 0:
    message("Not in a piece of a multibuffer")
    return
  discard openFile(path, at.line, at.col)

command "Word places: every line with this word, together":
  wordPlaces()

command "Word places: the module's test beside it":
  testBeside()

command "Word places: the file behind the cursor":
  fileHere()

command "Word places: two columns, the same size":
  paneLayout("columns 2")
  paneLayout("equal")
