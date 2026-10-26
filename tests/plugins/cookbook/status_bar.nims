## selection-stats — the status bar: while text is selected, its lines, words and characters. There is no event
## for a selection, so a timer looks twice a second, and the item is sent only when it changes
import nedplugin
from std/unicode import runeLen

requiresNed(">= 6.31")

var shown = ""                                # what the item says now

discard every(500) do ():
  let b = current()                           # (no request: ned says it with the call)
  var s = ""
  if b.valid:
    let r = b.selection                       # (one request)
    if not r.isEmpty:
      let t = b.textIn(r)
      s = "⌗ " & $(r.stop.line - r.start.line + 1) & " lines · " & $t.splitWhitespace.len & " words · " &
          $t.runeLen & " characters"
  if s != shown:
    shown = s
    status(s)                                 # this plugin's item; "" removes it
