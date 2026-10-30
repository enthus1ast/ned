## daily-log — settings and the plugin's data: a line added to today's log, a file of the plugin's own data
## folder (no permission needed), and a day's log opened in a tab; its settings in ned's Settings panel
import nedplugin
import std/algorithm

requiresNed(">= 6.31")

# plugins.daily-log.<key> — shown in ned's Settings panel, with their descriptions; the default's type is theirs
settingDef("withTime", true, "Daily log: begin each line with the time (14:03)")
settingDef("heading", "# $date", "Daily log: the first line of a day's log ($date: the day)")
settingDef("days", 14, "Daily log: how many days 'Daily log: open a day…' lists")

# today's date, as year-month-day
proc today(): string = localTime()[0 ..< 10]                  # "2026-10-26"

# the path of a day's log inside the plugin's data folder, in a folder for its month
func fileOf(day: string): string = day[0 ..< 7] & "/" & day & ".md"     # "2026-10/2026-10-26.md": a folder a month

proc addLine() =
  ## asks for a line and adds it to today's log, with the time in front when the setting asks; a new day's file gets its
  ## heading first and the day is noted in days.txt, the list that 'open a day' reads
  let text = ask("Log:")
  if text.strip.len == 0: return
  let day = today()
  let f = fileOf(day)
  if readData(f).len == 0:                    # ("": there is no such file yet) — a new day: its heading first
    writeData(f, setting("heading", "# $date").replace("$date", day) & "\n\n")
    appendData("days.txt", day & "\n")        # (the days there are: NimScript cannot list a folder when compiled)
  let time = if setting("withTime", true): localTime()[11 ..< 16] & "  " else: ""
  appendData(f, "- " & time & text & "\n")
  toast("Logged")

proc openDay() =
  ## lists the days that have a log, the latest first and as many as the days setting says, and opens the one picked as
  ## a file from the plugin's data folder
  var days: seq[string]
  for d in readData("days.txt").splitLines:
    if d.len > 0: days.add d
  days.reverse()                              # (the latest first)
  if days.len > setting("days", 14): days.setLen(setting("days", 14))
  if days.len == 0:
    message("Daily log: nothing logged yet (Daily log: add a line…)")
    return
  let i = pick("Which day?", days)
  # the folder's own path: a file there opens as any file — and Ctrl+S saves your edits to it
  if i >= 0: discard openFile(dataDir() / fileOf(days[i]))

command "Daily log: add a line…", "ctrl+alt+l":
  addLine()

command "Daily log: open a day…":
  openDay()
