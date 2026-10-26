## bookmarks — a view in the Plugins dock: the lines you bookmark, by file — a click opens one; a row to bookmark
## the cursor's line and one to clear them all. They are kept in the plugin's data folder
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

type Mark = object
  path: string                                # the file
  line: int                                   # the line, from 0 (it does not follow later edits)
  text: string                                # what the line said

var
  marks: seq[Mark]
  loaded = false

proc load() =
  ## the bookmarks kept last time, read once
  if loaded: return
  loaded = true
  try:
    for j in parseJson(readData("marks.json")):
      marks.add Mark(path: j{"path"}.getStr, line: j{"line"}.getInt, text: j{"text"}.getStr)
  except CatchableError: discard              # (none yet: readData gave "")

proc store() =
  ## the bookmarks written to the data folder, and the view shown again
  marks.sort(proc(a, b: Mark): int = cmp((a.path, a.line), (b.path, b.line)))
  var a = newJArray()
  for m in marks: a.add %*{"path": m.path, "line": m.line, "text": m.text}
  writeData("marks.json", a.pretty)
  refreshView("Bookmarks")                    # (its rows changed: ned asks for them again)

proc toggle(b: Buf) =
  ## the cursor's line bookmarked — or, when it is, not any more
  load()
  let p = b.path
  if p.len == 0:
    message("Bookmarks: save the file first")
    return
  let l = b.cursor.line
  for i, m in marks:
    if m.path == p and m.line == l:
      marks.delete(i)
      store()
      message("Bookmark removed")
      return
  marks.add Mark(path: p, line: l, text: b.line(l).strip)
  store()
  message("Bookmarked line " & $(l + 1))

view("Bookmarks") do () -> seq[ViewItem]:
  load()
  let root = projectRoot() & "/"
  result.add ViewItem(text: "Bookmark this line", icon: "+", color: "accent", id: "toggle")
  var last = ""
  for m in marks:
    if m.path != last:                        # a file's row, its bookmarks under it
      result.add ViewItem(text: m.path.replace(root, ""), icon: "▸")
      last = m.path
    # a row with a path and no id: a click opens the file at its line
    result.add ViewItem(text: m.text, detail: $(m.line + 1), icon: "•", path: m.path, line: m.line, depth: 1)
  if marks.len > 0:
    result.add ViewItem(text: "Clear them all", icon: "✕", color: "warn", id: "clear")
do (id: string):
  # a row with an id was clicked (a file's row has neither id nor path: it comes here as "")
  case id
  of "toggle": toggle(current())
  of "clear":
    if confirm("Remove all " & $marks.len & " bookmarks?"):
      marks.setLen(0)
      store()
  else: discard

command "Bookmarks: bookmark the line (or not)", "ctrl+alt+b":
  toggle(current())
