## reminders — timers: a note when a file has had changes not saved for a while (`every`), and a reminder you set
## yourself (`after`), which you can cancel (`stopTimer`)
import nedplugin
import std/tables

requiresNed(">= 6.31")

settingDef("unsavedMinutes", 10, "Reminders: say so when a file has had changes not saved for this many minutes " &
           "(0: never)")

var
  dirtySince: Table[int, float]               # a tab with changes not saved → since when (unixTime)
  told: seq[int]                              # the tabs already said
  reminder = -1                               # the timer of the reminder you set (-1: none)

# every 30 seconds — ned keeps the time and calls; keep the work small (a plugin with a timer keeps running)
discard every(30_000) do ():
  let mins = setting("unsavedMinutes", 10)
  if mins <= 0: return
  let now = unixTime()                        # (NimScript has no clock: ned's)
  var seen: Table[int, float]
  for b in buffers():
    if not b.dirty: continue
    let since = dirtySince.getOrDefault(b.id, now)
    seen[b.id] = since
    if now - since >= float(mins * 60) and b.id notin told:
      told.add b.id
      toast(b.title & " has had changes not saved for " & $mins & " minutes")
  dirtySince = seen                           # (saved or closed tabs are forgotten …)
  var still: seq[int]
  for id in told:
    if id in seen: still.add id
  told = still                                # (… and said again when they change again)

proc remind() =
  let what = ask("Remind you of what?", "a break")
  if what.len == 0: return
  let mins = (try: parseInt(ask("In how many minutes?", "25")) except ValueError: 0)
  if mins <= 0:
    warn("Reminders: that is not a number of minutes")
    return
  if reminder >= 0: stopTimer(reminder)       # (one at a time: the new one takes the old one's place)
  reminder = after(mins * 60_000) do ():
    reminder = -1
    toast("Reminder: " & what)
  message("Reminder in " & $mins & " minutes (Reminders: cancel)")

command "Reminders: remind me…":
  remind()

command "Reminders: cancel":
  if reminder < 0:
    message("No reminder is set")
  else:
    stopTimer(reminder)
    reminder = -1
    message("The reminder is cancelled")
