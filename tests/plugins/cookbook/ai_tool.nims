## editor-tools — tools for ned's assistant (its agent mode): what is open in the editor and what is selected
## (read-only: called without asking), and text put in place of the selection (it asks you first)
import nedplugin

requiresNed(">= 6.31")

# no arguments: an empty object. The model knows it as plugin__editor-tools__open_files
aiToolReadOnly("open_files", "The files open in the editor, one a line: its path, then * when it has changes " &
               "not saved. The first line is the file being edited.", %*{}) do (args: JsonNode) -> string:
  let cur = current()
  var rows: seq[string]
  for b in buffers():
    let p = b.path
    let row = (if p.len > 0: p else: b.title & " (not a file)") & (if b.dirty: " *" else: "")
    if b.id == cur.id: rows.insert(row, 0) else: rows.add row
  rows.join("\n")

# an argument it may leave out ("optional": true); every other one is required
aiToolReadOnly("selection", "The text selected in the file being edited, after a line with the file and the " &
               "selected lines (counted from 1). Empty when nothing is selected.",
               %*{"maxLines": {"type": "integer", "description": "at most this many lines (200 when not given)",
                               "optional": true}}) do (args: JsonNode) -> string:
  let b = current()
  if not b.valid: raise newException(ValueError, "no file is being edited")   # (what the model reads)
  let r = b.selection
  if r.isEmpty: return ""
  var ls = b.textIn(r).splitLines
  ls.setLen(min(ls.len, args{"maxLines"}.getInt(200)))
  b.path & ":" & $(r.start.line + 1) & "-" & $(r.stop.line + 1) & "\n" & ls.join("\n")

# a tool that changes something: ned asks you before each call (ai.autoApprove)
aiTool("replace_selection", "Put new text in place of the text selected in the file being edited. The file is " &
       "not saved; Ctrl+Z takes it back.",
       %*{"text": {"type": "string", "description": "the new text"}}) do (args: JsonNode) -> string:
  let b = current()
  let r = b.selection
  if r.isEmpty: raise newException(ValueError, "nothing is selected: ask the person to select the text first")
  b.replace(r, args{"text"}.getStr)
  "replaced lines " & $(r.start.line + 1) & "-" & $(r.stop.line + 1) & " (not saved)"
