## date-stamp — today's date at the cursor: a command on a key, vim mappings and a `:` command
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "You", license = "MIT")

proc today(withTime: bool): string =
  ## "2026-10-26", or "2026-10-26 14:03" — NimScript has no clock: ned's is asked
  let now = localTime()                       # "2026-10-26 14:03:05"
  if withTime: now[0 ..< 16] else: now[0 ..< 10]

proc stamp(b: Buf, withTime: bool) =
  ## the date in place of the selection (nothing selected: at the cursor), the cursor after it
  let s = today(withTime)
  let r = b.selection                         # (nothing selected: an empty range at the cursor)
  b.replace(r, s)
  b.setCursor(pos(r.start.line, r.start.col + s.len))

# in the palette (Ctrl+E) and on Ctrl+Alt+T
command "Date stamp: insert today's date", "ctrl+alt+t":
  stamp(current(), false)

# only in the palette
command "Date stamp: insert the date and the time":
  stamp(current(), true)

# vim's normal mode: space d t; with a count (2 space d t) the time too
nmap("<leader>dt", "insert today's date") do (count: int):
  stamp(current(), count > 1)

# vim's visual mode: the selection becomes the date (ned goes back to normal mode after it)
vmap("<leader>dt", "replace it with today's date") do (count: int):
  let b = current()
  b.replace(b.selection, today(false))

# :Date, or :Date time
exCommand("Date") do (args: string):
  stamp(current(), args == "time")
