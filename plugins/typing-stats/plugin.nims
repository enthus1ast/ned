## typing-stats — how fast you type and how many days in a row you have written: words a minute in the status bar
##
##   the status bar     ⌨ 42 wpm · 3 days — how fast you typed in the last five minutes you were typing, and how
##                      many days in a row you have written (200 characters or more a day)
##   Typing: today      today's words, time typing and best speed, the streak — and the last seven days, in a tab
##   settings           plugins.typing-stats.statusBar (true)
##
## A word is five characters, as typing tests count them. Only what you type counts: a paste, an undo of many lines,
## a formatter's changes do not. The days are kept in the plugin's data folder (days.json), on this device only.
import nedplugin
import std/algorithm

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("statusBar", true, "Typing stats: the speed and the streak in the status bar")

const
  WindowSec = 300.0             # the speed is of the last five minutes of typing
  GapSec = 10.0                 # a pause longer than this is not typing time
  PasteChars = 200              # more than this at once is not typed
  StreakChars = 200             # a day counts for the streak with this many characters typed

type Seen = object
  buf, lines, line, len: int    # a file, its number of lines, the cursor's line and its length, when last seen

var
  seen: seq[Seen]
  recent: seq[(float, int)]     # (when, characters typed) in the window
  days: JsonNode                # day → {"chars", "seconds", "best"}
  lastAt = 0.0                  # the last time something was typed
  unsaved = false
  loaded = false

proc load() =
  ## the days kept in the data folder (none the first time)
  if loaded: return
  loaded = true
  days = newJObject()
  try:
    let j = parseJson(readData("days.json"))
    if j.kind == JObject: days = j
  except CatchableError: discard

proc save() =
  ## the days into the data folder, when something changed
  if not unsaved: return
  unsaved = false
  writeData("days.json", days.pretty & "\n")

proc today(): string = localTime()[0 ..< 10]
  ## today's date, yyyy-mm-dd

proc day(d: string): JsonNode =
  ## that day's counts (made when there are none)
  if not days.hasKey(d): days[d] = %*{"chars": 0, "seconds": 0.0, "best": 0}
  days[d]

func dateBefore(d: string): string =
  ## the day before yyyy-mm-dd (the calendar's months and leap years)
  var y = parseInt(d[0 .. 3])
  var m = parseInt(d[5 .. 6])
  var dd = parseInt(d[8 .. 9]) - 1
  if dd == 0:
    m -= 1
    if m == 0:
      m = 12
      y -= 1
    const Len = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    dd = Len[m - 1]
    if m == 2 and (y mod 4 == 0 and (y mod 100 != 0 or y mod 400 == 0)): dd = 29
  $y & "-" & (if m < 10: "0" else: "") & $m & "-" & (if dd < 10: "0" else: "") & $dd

proc streak(): int =
  ## the days in a row with enough typed, up to today (or yesterday, when today has not got there yet)
  var d = today()
  if days{d}{"chars"}.getInt(0) < StreakChars: d = dateBefore(d)
  while days{d}{"chars"}.getInt(0) >= StreakChars:
    inc result
    d = dateBefore(d)

proc speed(now: float): int =
  ## words a minute over the window: the characters typed in it, five to a word, over the time spent typing
  var keep: seq[(float, int)]
  for (t, n) in recent:
    if now - t <= WindowSec: keep.add (t, n)
  recent = keep
  if recent.len < 2: return 0
  var chars = 0
  var secs = 0.0
  for i, (t, n) in recent:
    if i > 0:                   # (what each change brought was typed in the time before it: the first one's is not known)
      chars += n
      secs += min(t - recent[i - 1][0], GapSec)
  if chars < 25 or secs < 15: return 0
  int(float(chars) / 5.0 / (secs / 60.0) + 0.5)

proc show(now: float) =
  ## the status bar's item: the speed (while there is one) and the streak
  if not setting("statusBar", true):
    status("")
    return
  let w = speed(now)
  let s = streak()
  var parts: seq[string]
  if w > 0: parts.add $w & " wpm"
  if s > 0: parts.add $s & (if s == 1: " day" else: " days")
  status(if parts.len > 0: "⌨ " & parts.join(" · ") else: "")

proc typed(b: Buf): int =
  ## the characters typed in `b` since it was last seen: the cursor's line grown, or lines added one at a time
  ## (Enter); 0 for anything else (a move, a deletion, a paste of many lines)
  let c = b.cursor
  let n = b.lineCount
  let l = b.line(c.line).len
  var k = -1
  for i, s in seen:
    if s.buf == b.id: k = i
  if k < 0:
    seen.add Seen(buf: b.id, lines: n, line: c.line, len: l)
    if seen.len > 32: seen.delete(0)
    return 0
  let s = seen[k]
  if n == s.lines and c.line == s.line: result = max(0, l - s.len)
  elif n > s.lines and n - s.lines <= 3 and c.line >= s.line and c.line - s.line <= 3:
    result = (n - s.lines) + max(0, l - (if c.line == s.line: s.len else: 0))
  seen[k] = Seen(buf: b.id, lines: n, line: c.line, len: l)
  if result > PasteChars: result = 0

onChange("*") do (ev: Event):
  load()
  let n = typed(ev.buf)
  if n <= 0: return
  let now = unixTime()
  let d = day(today())
  d["chars"] = %(d{"chars"}.getInt(0) + n)
  if lastAt > 0: d["seconds"] = %(d{"seconds"}.getFloat(0) + min(now - lastAt, GapSec))
  lastAt = now
  recent.add (now, n)
  let w = speed(now)
  if w > d{"best"}.getInt(0) and w < 250: d["best"] = %w      # (over 250: a burst, not a speed)
  unsaved = true
  show(now)

onStartup do (ev: Event):
  load()
  show(unixTime())

discard every(60_000) do ():
  save()
  show(unixTime())

onQuit do (ev: Event):
  save()

func mins(s: float): string =
  ## seconds as minutes: 12 min, under half a minute: < 1 min
  if s < 30: "< 1 min" else: $int(s / 60 + 0.5) & " min"

command "Typing: today":
  load()
  let t = day(today())
  let words = t{"chars"}.getInt(0) div 5
  let s = streak()
  message("⌨ Today " & $words & " words in " & mins(t{"seconds"}.getFloat(0)) & ", best " & $t{"best"}.getInt(0) &
          " wpm · " & $s & (if s == 1: " day" else: " days") & " in a row")
  var md = "# Typing\n\n**" & $s & (if s == 1: " day" else: " days") & " in a row** (" & $StreakChars &
           " characters or more a day)\n\n| day | words | typing | best speed |\n|---|---:|---:|---:|\n"
  var d = today()
  for i in 0 ..< 7:
    let x = days{d}
    md.add "| " & d & (if i == 0: " (today)" else: "") & " | " & $(x{"chars"}.getInt(0) div 5) & " | " &
           (if x == nil: "—" else: mins(x{"seconds"}.getFloat(0))) & " | " &
           (if x{"best"}.getInt(0) > 0: $x{"best"}.getInt(0) & " wpm" else: "—") & " |\n"
    d = dateBefore(d)
  var best = 0
  var bestDay = ""
  var all: seq[string]
  for k, _ in days: all.add k
  all.sort()
  for k in all:
    if days[k]{"best"}.getInt(0) > best:
      best = days[k]{"best"}.getInt(0)
      bestDay = k
  if best > 0: md.add "\nYour best speed: **" & $best & " wpm**, on " & bestDay & ".\n"
  discard newTab("Typing", md, "markdown")
