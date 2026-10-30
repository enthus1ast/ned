## time-tracker — how long you work on each project and file, kept on your device only
##
##   what counts      the time between the things you do — typing (after each pause), saving, opening a file,
##                    going to another tab, moving the cursor (looked at every 15 s) —, for the project and the file;
##                    a gap longer than idleMinutes (5) is a pause, and is not counted
##   the status bar   ⏱ 1 h 25 min today — in the project you are in (showStatus)
##   Time: report     a new tab (Markdown): today, this week day by day, by project and by file
##   Time: pause or resume counting
##   settings         plugins.time-tracker.idleMinutes, plugins.time-tracker.showStatus
##
## The time is written to the plugin's data folder, a file of JSON lines for each month (2026-10.jsonl: the day, the
## project, the file, the seconds), about once a minute and when ned quits. Nothing leaves the device.
import nedplugin
import std/[tables, algorithm]

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("idleMinutes", 5, "Time: a gap without typing, saving or moving longer than this (minutes) is a pause, " &
           "not counted")
settingDef("showStatus", true, "Time: show today's time for the project in the status bar")

const TickMs = 15_000            # how often the timer looks at the cursor (reading counts) and writes the time

var
  paused = false
  lastTime = 0.0                 # the clock when you last did something (0: nothing yet, or since a pause)
  lastProject, lastFile = ""     # where that was
  pending: seq[(string, string, float)]   # project, file, seconds: not written yet
  dayKey = ""                    # the day the totals below are for
  todays: Table[string, float]   # today's seconds for each project (written and not)
  shown = "-"                    # what the status bar shows
  lastBuf = -1
  lastAt = pos(-1, 0)
  lastWrite = 0.0                # the clock when the time was last written

# today's date as yyyy-mm-dd, in local time
proc today(): string = localTime()[0 ..< 10]

func dur(s: int): string =
  ## seconds as 1 h 5 min, 25 min
  let m = s div 60
  if m < 60: $m & " min" else: $(m div 60) & " h " & $(m mod 60) & " min"

# ── days: the calendar without a clock ──

func daysOf(date: string): int =
  ## the day's number (days since 1970-01-01) of yyyy-mm-dd
  let p = date.split('-')
  if p.len != 3: return 0
  let (y0, m, d) = (try: (parseInt(p[0]), parseInt(p[1]), parseInt(p[2])) except ValueError: (1970, 1, 1))
  let y = if m <= 2: y0 - 1 else: y0
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let doy = (153 * ((m + 9) mod 12) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

func dateOf(days: int): string =
  ## yyyy-mm-dd of a day's number
  let z = days + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  let y = yoe + era * 400 + (if m <= 2: 1 else: 0)
  $y & "-" & align($m, 2, '0') & "-" & align($d, 2, '0')

const DayNames = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
const MonthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                    "October", "November", "December"]

# the day of the week of a day's number, Monday 0 to Sunday 6
func weekday(days: int): int = ((days mod 7) + 7 + 3) mod 7      # Monday 0 (1970-01-01 was a Thursday)

func longDate(date: string): string =
  ## a yyyy-mm-dd date written for the report: the weekday's name, the day and the month's name (Monday 5 October)
  let p = date.split('-')
  DayNames[weekday(daysOf(date))] & " " & $parseInt(p[2]) & " " & MonthNames[parseInt(p[1]) - 1]

# ── the data ──

# the path in the plugin's data folder of the file for the month of a yyyy-mm-dd day (2026-10.jsonl)
proc monthFile(day: string): string = dataDir() / day[0 .. 6] & ".jsonl"

proc readMonth(day: string): seq[(string, string, string, int)] =
  ## a month's lines: day, project, file, seconds
  let f = monthFile(day)
  if not fileExists(f): return
  for l in readFile(f).splitLines:
    if l.strip.len == 0: continue
    try:
      let j = parseJson(l)
      result.add (j{"day"}.getStr, j{"project"}.getStr, j{"file"}.getStr, j{"secs"}.getInt)
    except CatchableError: discard

proc load() =
  ## today's totals for each project, from the file (once a day: flush says when the day has changed)
  if dayKey.len > 0: return
  let t = today()
  dayKey = t
  if lastWrite == 0.0: lastWrite = unixTime()
  todays = initTable[string, float]()
  for (d, p, _, s) in readMonth(t):
    if d == t: todays[p] = todays.getOrDefault(p) + float(s)
  for (p, _, s) in pending: todays[p] = todays.getOrDefault(p) + s

proc flush() =
  ## the time not written yet (whole seconds: the rest waits), at the end of this month's file; a new day noticed
  lastWrite = unixTime()
  let day = today()
  if day != dayKey: dayKey = ""                 # (a new day: its totals read again)
  var text = ""
  var rest: seq[(string, string, float)]
  for (p, f, s) in pending:
    if int(s) > 0: text.add $(%*{"day": day, "project": p, "file": f, "secs": int(s)}) & "\n"
    if s - float(int(s)) > 0: rest.add (p, f, s - float(int(s)))
  pending = rest
  if text.len == 0: return
  appendData(day[0 .. 6] & ".jsonl", text)      # (its own data folder: ned adds the lines, no permission needed)

proc showStatus() =
  ## puts today's time for the current project in the status bar ("time paused" while counting is paused, nothing when
  ## plugins.time-tracker.showStatus is off), touching the status bar only when the text changed
  let t = if paused: "⏸ time paused"
          elif not setting("showStatus", true): ""
          else: "⏱ " & dur(int(todays.getOrDefault(projectRoot()))) & " today"
  if t != shown:
    status(t)
    shown = t

proc add(project, file: string, secs: float) =
  ## adds the seconds to the time not written yet for that project and file (to its entry when it has one, else as a new
  ## one) and to today's total for the project
  for x in pending.mitems:
    if x[0] == project and x[1] == file:
      x[2] += secs
      todays[project] = todays.getOrDefault(project) + secs
      return
  pending.add (project, file, secs)
  todays[project] = todays.getOrDefault(project) + secs

proc fileIn(project, path: string): string =
  ## the file as the report names it: from the project's folder, else from your home (~/…)
  if path.len == 0: "(not saved)"
  elif path.startsWith(project & "/"): path[project.len + 1 .. ^1]
  elif path.startsWith(getHomeDir()): "~/" & path[getHomeDir().len .. ^1]
  else: path

proc did(path: string) =
  ## something done in the file: the time since the last thing counts — to where that was —, unless it was a pause
  if paused: return
  load()
  let now = unixTime()
  let project = projectRoot()
  let gap = now - lastTime
  if lastTime > 0 and gap > 0 and gap <= float(setting("idleMinutes", 5) * 60): add(lastProject, lastFile, gap)
  lastTime = now
  lastProject = project
  lastFile = fileIn(project, path)
  showStatus()

proc tick() =
  ## the timer every 15 seconds: when the cursor has moved in the tab that was already the current one, that counts as
  ## something done (reading), the time not written is written when a minute has passed since the last write, and the
  ## status bar is brought up to date; nothing while paused
  if paused: return
  load()
  # reading counts too: the cursor moved in the tab you look at (another tab: onEnter)
  let b = current()
  if b.valid:
    let c = b.cursor
    if b.id == lastBuf and c != lastAt: did(b.path)
    lastBuf = b.id
    lastAt = c
  if unixTime() - lastWrite >= 60: flush()
  showStatus()

discard every(TickMs) do (): tick()

onOpen("*") do (ev: Event): did(ev.path)
onChange("*") do (ev: Event): did(ev.path)
onSave("*") do (ev: Event): did(ev.path)
onEnter("*") do (ev: Event): did(ev.path)
onQuit do (ev: Event): flush()

# ── the report ──

proc nameOf(project: string, all: seq[string]): string =
  ## a project by its folder's name (by its path when two have that name)
  let n = extractFilename(project)
  for p in all:
    if p != project and extractFilename(p) == n: return project
  if n.len > 0: n else: project

proc mdTable(head: string, rows: seq[(string, int)]): seq[string] =
  ## the lines of a Markdown table with the heading `head` and a Time column from the (name, seconds) rows, `|` in a
  ## name escaped
  result.add "| " & head & " | Time |"
  result.add "|---|---:|"
  for (k, s) in rows: result.add "| " & k.replace("|", "\\|") & " | " & dur(s) & " |"

proc sortedRows(t: Table[string, int]): seq[(string, int)] =
  ## the table's (name, seconds) pairs with the most time first
  for k, v in t: result.add (k, v)
  result.sort(proc(a, b: (string, int)): int = cmp(b[1], a[1]))

proc report(): string =
  ## the report as Markdown text: today by project, this week (from Monday) day by day, by project and by file (the 30
  ## longest), added up from the month files (last month's too when the week began in it) after writing what is not
  ## written yet. Projects whose folders have the same name are told apart by their paths
  flush()
  dayKey = ""
  load()
  let t = today()
  let n = daysOf(t)
  let monday = n - weekday(n)
  var lines = readMonth(t)
  if dateOf(monday)[0 .. 6] != t[0 .. 6]: lines = readMonth(dateOf(monday)) & lines
  var projects: seq[string]
  for (_, p, _, _) in lines:
    if p notin projects: projects.add p
  var todayP, weekP, weekF: Table[string, int]
  var days: Table[string, int]
  var total, week = 0
  for (d, p, f, s) in lines:
    let k = daysOf(d)
    if d == t:
      todayP[nameOf(p, projects)] = todayP.getOrDefault(nameOf(p, projects)) + s
      total += s
    if k >= monday and k <= n:
      week += s
      days[d] = days.getOrDefault(d) + s
      weekP[nameOf(p, projects)] = weekP.getOrDefault(nameOf(p, projects)) + s
      let fk = f & " (" & nameOf(p, projects) & ")"
      weekF[fk] = weekF.getOrDefault(fk) + s
  var md = @["# Time — " & longDate(t), ""]
  md.add "## Today: " & dur(total)
  md.add ""
  if total == 0: md.add "Nothing counted yet today."
  else: md.add mdTable("Project", sortedRows(todayP))
  md.add ""
  md.add "## This week: " & dur(week) & " (from " & longDate(dateOf(monday)) & ")"
  md.add ""
  var dayRows: seq[(string, int)]
  for k in monday .. n: dayRows.add (longDate(dateOf(k)), days.getOrDefault(dateOf(k)))
  md.add mdTable("Day", dayRows)
  md.add ""
  md.add "## This week by project"
  md.add ""
  md.add mdTable("Project", sortedRows(weekP))
  md.add ""
  let files = sortedRows(weekF)
  md.add "## This week by file" & (if files.len > 30: " (the 30 longest)" else: "")
  md.add ""
  md.add mdTable("File", files[0 ..< min(files.len, 30)])
  md.add ""
  md.add "*Kept in " & dataDir() & " (a file for each month). A gap of more than " &
         $setting("idleMinutes", 5) & " minutes is a pause.*"
  md.join("\n") & "\n"

command "Time: report":
  discard newTab("Time report", report(), "markdown")

command "Time: pause or resume counting":
  if paused:
    paused = false
    lastTime = 0.0
    showStatus()
    message("Time: counting again")
  else:
    flush()
    paused = true
    lastTime = 0.0
    showStatus()
    message("Time: paused — nothing is counted until you resume")
