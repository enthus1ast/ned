## blame-heat — the lines changed lately tinted by how recently: today hot, this week warm, this month mild (git blame)
##
##   Blame heat: on/off    the file in front tinted by the age of each line, as git blame gives it: changed today
##                         (or not committed yet) red, this week orange, this month blue; older lines as they are.
##                         Again to clear it. While on it follows you: each file you go to, and each save
##   Blame heat: the file's ages   how many lines are of today, this week, this month and older — in the status line
##   settings              plugins.blame-heat.days (30): the oldest change still tinted · .hotDays (1) · .warmDays (7)
##
## The tint is faint, behind the text: the code's own colours stay. Files over 5000 lines, and files git does not
## know, are left as they are.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs git blame to know when each line changed")

settingDef("days", 30, "Blame heat: changes older than this many days are not tinted")
settingDef("hotDays", 1, "Blame heat: changes this many days old or newer are hot (red)")
settingDef("warmDays", 7, "Blame heat: changes this many days old or newer are warm (orange)")

var
  on = false
  tinted: seq[int]              # the files tinted now

func bucketOf*(ageDays: float, hot, warm, mild: int): int =
  ## 0 hot, 1 warm, 2 mild, 3 old (not tinted)
  if ageDays <= float(hot): 0
  elif ageDays <= float(warm): 1
  elif ageDays <= float(mild): 2
  else: 3

const Colours = ["del", "warn", "info"]

proc times*(porcelain: string): seq[float] =
  ## when each line of the file was last changed (seconds since 1970), from git blame --line-porcelain; a line not
  ## committed yet: -1
  var t = 0.0
  var uncommitted = false
  for l in porcelain.splitLines:
    if l.len >= 41 and l[40] == ' ' and l[0 ..< 40].allCharsInSet(HexDigits):
      uncommitted = l.startsWith("0000000000000000000000000000000000000000")
    elif l.startsWith("author-time "):
      try: t = parseFloat(l["author-time ".len .. ^1].strip)
      except ValueError: t = 0
    elif l.startsWith("\t"):
      result.add (if uncommitted: -1.0 else: t)

proc tint(b: Buf, ts: seq[float], draw: bool) =
  ## the file's lines tinted (`draw`), a run of lines of the same age at a time; a count of each age in the status
  ## line
  if draw: b.clearDecorations()
  let now = unixTime()
  let hot = setting("hotDays", 1)
  let warm = setting("warmDays", 7)
  let mild = setting("days", 30)
  let ls = b.lines
  var counts = [0, 0, 0, 0]
  var i = 0
  while i < ts.len and i < ls.len:
    let k = bucketOf((if ts[i] < 0: 0.0 else: (now - ts[i]) / 86400.0), hot, warm, mild)
    var j = i
    while j + 1 < ts.len and j + 1 < ls.len and
          bucketOf((if ts[j + 1] < 0: 0.0 else: (now - ts[j + 1]) / 86400.0), hot, warm, mild) == k: inc j
    counts[k] += j - i + 1
    if draw and k < 3: b.highlight(rng(pos(i, 0), pos(j, ls[j].len)), Colours[k])
    i = j + 1
  if draw and b.id notin tinted: tinted.add b.id
  message("Blame heat: " & $counts[0] & " hot · " & $counts[1] & " warm · " & $counts[2] & " mild · " & $counts[3] &
          " older")

proc heat(b: Buf, draw = true) =
  ## git blame of the file, in the background, then its tint (or only the count of its ages)
  let p = b.path
  if p.len == 0: return
  if b.lineCount > 5000:
    message("Blame heat: " & extractFilename(p) & " is too long to tint (over 5000 lines)")
    return
  let id = b.id
  shellAsync("cd " & quoteShell(parentDir(p)) & " && git blame --line-porcelain -- " &
             quoteShell(extractFilename(p))) do (output: string, code: int):
    if draw and not on: return                  # (turned off meanwhile)
    let x = Buf(id: id)
    if code != 0:
      message("Blame heat: git does not know " & extractFilename(p))
      return
    try: tint(x, times(output), draw)
    except CatchableError: discard              # (its tab closed meanwhile)

proc clearAll() =
  ## every tint goes
  for id in tinted:
    try: Buf(id: id).clearDecorations()
    except CatchableError: discard
  tinted.setLen(0)

command "Blame heat: on/off":
  on = not on
  if on: heat(current())
  else:
    clearAll()
    message("Blame heat off")

command "Blame heat: the file's ages":
  heat(current(), draw = false)

onEnter("*") do (ev: Event):
  if on and ev.path.len > 0: heat(ev.buf)

onSave("*") do (ev: Event):
  if on: heat(ev.buf)
