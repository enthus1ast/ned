## scratch — a tab of the plugin's own: a scratch pad that is not a file. Ctrl+S keeps it in the plugin's data
## folder (onSaveTab), Alt+Enter (or Enter in vim) ticks a "- [ ]" line — keys only in that tab
import nedplugin

requiresNed(">= 6.31")

const Title = "Scratch"

# a language of its own: saving its tabs, and its keys, are this plugin's — and its own colours
language("scratch", LangSpec(name: "Scratch", lineComment: "#", keywords: @["TODO", "DONE"]))

proc keep(b: Buf) =
  ## the pad's text kept, its tab marked as saved (no ●, no question when it closes)
  writeData("scratch.md", b.text)
  b.markSaved()

proc openPad() =
  ## opens the scratch pad in a tab of its own, filled from the saved pad, or brings the one already open to the front;
  ## a pad with no changes gets the cursor at the start
  # a tab of that title already open is used again — as it is, when it has changes not saved
  let b = newTab(Title, readData("scratch.md"), "scratch")
  if not b.dirty: b.setCursor(pos(0, 0))

proc tick(b: Buf) =
  ## "- [ ]" ↔ "- [x]" on the cursor's line
  let l = b.cursor.line
  let s = b.line(l)
  let k = s.find("- [")
  if k < 0 or k + 4 >= s.len or s[k + 4] != ']': return
  b.replace(rng(pos(l, k + 3), pos(l, k + 4)), (if s[k + 3] == ' ': "x" else: " "))

onSaveTab("scratch") do (ev: Event):          # Ctrl+S (or :w) in the pad: no file name asked for
  keep(ev.buf)
  message("Scratch pad kept")

keyIn("scratch", "alt+enter", "tick or untick the line") do (b: Buf):
  tick(b)

nmapIn("scratch", "<CR>", "tick or untick the line") do (count: int):
  tick(current())

onQuit do (ev: Event):                        # (a pad with changes not saved: kept anyway)
  for b in buffers():
    if b.lang == "scratch" and b.dirty: keep(b)

command "Scratch: open the pad", "ctrl+alt+p":
  openPad()

command "Scratch: close the pad":
  for b in buffers():
    if b.lang == "scratch":
      if b.dirty: keep(b)                     # (a tab that is not a file closes without asking)
      b.closeTab()
