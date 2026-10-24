## pomodoro — a focus timer: 25 minutes of work, then a break, the time left in the status bar
##
##   Focus: start            a focus session (focusMinutes: 25)
##   Focus: short break      a break (shortBreakMinutes: 5) · Focus: long break (longBreakMinutes: 15)
##   Focus: stop             the session ends here (not counted)
##   the status bar          Focus 24:13 while you work, Break 4:59 in a break; after a session, the day's count
##   at the end of one       a note in the corner — and a break starts by itself (autoBreak), a long one after
##                           every fourth session (longBreakEvery). A focus session after a break you start yourself
##   settings                plugins.pomodoro.focusMinutes, .shortBreakMinutes, .longBreakMinutes, .autoBreak,
##                           .longBreakEvery
##
## The sessions you finish are counted for each day, in the plugin's data folder (sessions.json). The time is the
## clock's: a session that ends while the device sleeps has ended when it wakes.
import nedplugin

requiresNed(">= 6.25")

settingDef("focusMinutes", 25, "Focus: how long a focus session is (minutes)")
settingDef("shortBreakMinutes", 5, "Focus: how long a short break is (minutes)")
settingDef("longBreakMinutes", 15, "Focus: how long a long break is (minutes)")
settingDef("autoBreak", true, "Focus: start a break by itself when a focus session ends")
settingDef("longBreakEvery", 4, "Focus: a long break after this many focus sessions (the others: short ones)")

type Kind = enum kFocus, kShort, kLong

var
  timer = -1                     # the timer of the session running (-1: none)
  kind = kFocus
  total = 0                      # its length, in seconds
  startedAt = 0.0                # the clock when it started (seconds since 1970)
  inRow = 0                      # focus sessions since the last long break

proc today(): string = localTime()[0 ..< 10]

proc left(): int =
  ## the seconds left of the session running (by the clock: the timer's calls stop while the device sleeps)
  total - int(unixTime() - startedAt)

func plural(n: int, w: string): string = $n & " " & w & (if n == 1: "" else: "s")

func mmss(s: int): string =
  let m = s div 60
  let r = s mod 60
  $m & ":" & (if r < 10: "0" else: "") & $r

# ── the day's count ──

proc countFile(): string = dataDir() / "sessions.json"

proc readCounts(): JsonNode =
  let f = countFile()
  result = newJObject()
  if fileExists(f):
    try:
      let j = parseJson(readFile(f))
      if j.kind == JObject: result = j
    except CatchableError: discard

proc addOne(): int =
  ## one more finished today (written down): how many now
  var j = readCounts()
  let t = today()
  result = j{t}.getInt(0) + 1
  j[t] = %result
  writeFile(countFile(), j.pretty & "\n")

# ── sessions ──

proc label(): string = (if kind == kFocus: "Focus " else: "Break ")

proc tick()

proc begin(k: Kind, quiet = false) =
  ## a session of this kind starts (one that runs ends: it is not counted)
  let mins = case k
    of kFocus: setting("focusMinutes", 25)
    of kShort: setting("shortBreakMinutes", 5)
    of kLong: setting("longBreakMinutes", 15)
  let again = timer >= 0
  if timer >= 0: stopTimer(timer)
  kind = k
  total = max(1, mins) * 60
  startedAt = unixTime()
  status(label() & mmss(total))
  timer = every(1000) do (): tick()
  if not quiet:
    let what = case k
      of kFocus: "focus for " & plural(mins, "minute") & " (Focus: stop ends it)"
      of kShort: "a short break of " & plural(mins, "minute")
      of kLong: "a long break of " & plural(mins, "minute")
    message(if again: "Started again: " & what else: capitalizeAscii(what))

proc ended() =
  ## the session's time is up
  stopTimer(timer)
  timer = -1
  if kind == kFocus:
    let n = addOne()
    inc inRow
    let long = inRow >= max(1, setting("longBreakEvery", 4))
    if setting("autoBreak", true):
      if long: inRow = 0
      begin((if long: kLong else: kShort), quiet = true)
      toast("Focus session done — " & plural(n, "session") & " today. A " & (if long: "long" else: "short") &
            " break starts now")
    else:
      status("Focus: " & $n & " today")
      toast("Focus session done — " & plural(n, "session") & " today. Time for a break (Focus: " &
            (if long: "long" else: "short") & " break)")
  else:
    if kind == kLong: inRow = 0
    status("")
    toast("The break is over — Focus: start when you are ready")

proc tick() =
  let l = left()
  if l <= 0: ended()
  else: status(label() & mmss(l))

command "Focus: start":
  begin(kFocus)
command "Focus: short break":
  begin(kShort)
command "Focus: long break":
  begin(kLong)
command "Focus: stop":
  if timer < 0:
    message("Focus: no session is running")
  else:
    stopTimer(timer)
    timer = -1
    status("")
    message("Focus: stopped with " & mmss(max(0, left())) & " left (not counted)")
