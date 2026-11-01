## todo — a task list for the project, kept in a Markdown file (TODO.md): add a task from anywhere, tick it off, see what is due
##
##   Todo: add a task…        (Alt+Shift+A)  a line you type, put after the open tasks of the project's TODO.md (made
##                            when there is none). On a TODO, FIXME, BUG, HACK or XXX comment, the comment is offered,
##                            with where it is: → [src/app.nim:12](src/app.nim#L12)
##   Todo: the list…          (Alt+Shift+L)  the open tasks — overdue first, then by the day they are due, then by
##                            priority — pick one: done, go to its place, show it in TODO.md, another due date, remove
##   Todo: done / not done    the task on the cursor's line (- [ ] …), in any Markdown file: ticked, with the day
##                            (✓ 2026-10-26), or back. Alt+Enter on a task's line offers it too
##   Todo: archive the done tasks    moved under "## Done" at the end of the list
##   Todo: open the list      TODO.md in a tab
##   the Plugins dock         TODO LIST: the open tasks (⚠ overdue, ● due today) — tap one for what to do with it
##   the status bar           ☐ 3 — the open tasks (⚠ 1: overdue or due today)
##   at start                 a note when tasks are overdue or due today
##   in TODO.md               after a due date: overdue 2 days · today · tomorrow · in 3 days; after due: the dates
##                            are completed (today, tomorrow, friday …)
##   vim                      <leader>ta add · <leader>tl the list · <leader>tx done / not done
##   settings                 plugins.todo.file (TODO.md: from the project's folder) · .linkHere (false: on, a task
##                            added anywhere says where you were) · .doneDate (true) · .statusBar (true) ·
##                            .remindAtStart (true)
##
## A task is a Markdown checkbox line, as GitHub shows one: `- [ ] write the docs due:2026-10-30 +docs`. In it:
## (A), (B), (C) at the start — its priority, as todo.txt's; due:2026-10-30 — the day it is due (typing due:today,
## due:tomorrow, due:fri or due:+3 when you add one writes the date); +word and @word — tags, as you like; a place in
## the project, → [path:line](path#Lline), where "go to" takes you. Lines indented under a task go with it (notes,
## sub-tasks). The file stays yours: edit it as any other; the plugin reads it again each time.
import nedplugin
import std/algorithm

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("file", "TODO.md", "Todo: the task list, a Markdown file — from the project's folder (or a full path)")
settingDef("linkHere", false, "Todo: a task added anywhere says where you were (→ [src/app.nim:12](…)); off: only " &
           "one added on a TODO comment")
settingDef("doneDate", true, "Todo: a task ticked off gets the day: ✓ 2026-10-26")
settingDef("statusBar", true, "Todo: the open tasks counted in the status bar: ☐ 3 (⚠ 1: overdue or due today)")
settingDef("remindAtStart", true, "Todo: a note when ned starts if tasks are overdue or due today")

permission("files", "writes the task list (TODO.md) in the project's folder when it is not open in a tab")

const
  View = "TODO LIST"
  Weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
  Tags = ["TODO", "FIXME", "BUG", "HACK", "XXX"]

type Task = object
  line, last: int                # its line in the file and its last one (the lines indented under it) — from 0
  done: bool
  text: string                   # what follows the checkbox
  prio: char                     # 'A' … from (A); '~' none (after every letter)
  due: string                    # 2026-10-30, or ""
  linkPath: string               # a place: its file, from the list's folder ("" none)
  linkLine: int                  # … and its line (from 0)

# the count with its noun, an s added unless it is 1 ("3 tasks")
func plural(n: int, w: string): string = $n & " " & w & (if n == 1: "" else: "s")

# ── days ──

func daysFromCivil(y0, m, d: int): int =
  ## days since 1970-01-01 (the proleptic Gregorian calendar)
  let y = if m <= 2: y0 - 1 else: y0
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let doy = (153 * ((m + 9) mod 12) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

func civilFromDays(z0: int): (int, int, int) =
  ## the year, month and day of a day number (days since 1970-01-01); the opposite of daysFromCivil
  let z = z0 + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  (yoe + era * 400 + (if m <= 2: 1 else: 0), m, d)

# the number with a 0 in front when it has one digit
func pad2(v: int): string = (if v < 10: "0" else: "") & $v

func iso(n: int): string =
  ## a day number written as yyyy-mm-dd
  let (y, m, d) = civilFromDays(n)
  $y & "-" & pad2(m) & "-" & pad2(d)

func dayNum(s: string): int =
  ## 2026-10-30 as a day number (-1: not a date)
  if s.len != 10 or s[4] != '-' or s[7] != '-': return -1
  for i in [0, 1, 2, 3, 5, 6, 8, 9]:
    if s[i] notin {'0' .. '9'}: return -1
  let (y, m, d) = (parseInt(s[0 .. 3]), parseInt(s[5 .. 6]), parseInt(s[8 .. 9]))
  if m < 1 or m > 12 or d < 1 or d > 31: return -1
  let n = daysFromCivil(y, m, d)
  if iso(n) != s: -1 else: n           # (no 31st of April)

# the day of the week of a day number, Monday 0 to Sunday 6
func weekday(n: int): int = ((n mod 7) + 7 + 3) mod 7      # 0 Monday … 6 Sunday (1970-01-01 was a Thursday)

# today's day number, from the local date
proc today(): int = dayNum(localTime()[0 ..< 10])

func dueFrom(word: string, now: int): string =
  ## a due date as typed — 2026-10-30, today, tomorrow, fri, +3 (days), 2w (weeks) — as a date ("": not one)
  let w = word.toLowerAscii
  if dayNum(w) >= 0: return w
  case w
  of "today", "tod": return iso(now)
  of "tomorrow", "tom", "tmr": return iso(now + 1)
  else: discard
  if w.len >= 2 and w[0] == '+' and w[1 .. ^1].allCharsInSet({'0' .. '9'}): return iso(now + parseInt(w[1 .. ^1]))
  if w.len >= 2 and w[^1] in {'d', 'w'} and w[0 ..< ^1].allCharsInSet({'0' .. '9'}):
    return iso(now + parseInt(w[0 ..< ^1]) * (if w[^1] == 'w': 7 else: 1))
  if w.len >= 2:
    for i, d in Weekdays:
      if d.startsWith(w):
        var n = now + 1                  # (the next one: friday on a Friday is a week away)
        while weekday(n) != i: inc n
        return iso(n)
  ""

func dueWords(due: string, now: int): string =
  ## a due date in words, as the list shows it: overdue 2 days, due today, due tomorrow, due friday (within the week) or
  ## due and the date
  let d = dayNum(due) - now
  if d < 0: "overdue " & plural(-d, "day")
  elif d == 0: "due today"
  elif d == 1: "due tomorrow"
  elif d < 7: "due " & Weekdays[weekday(now + d)]
  else: "due " & due

# ── the list ──

proc listPath(): string =
  ## the path of the task list: the plugins.todo.file setting, taken from the project's folder unless it is a full path
  let f = setting("file", "TODO.md")
  if f.isAbsolute: f else: projectRoot() / f

proc listBuf(): Buf =
  ## the list, when it is open in a tab (Buf(id: -1): not)
  let p = listPath()
  for b in buffers():
    if b.path == p: return b
  Buf(id: -1)

proc readList(): seq[string] =
  ## the list's lines — the tab's when it is open, else the file's (none: there is no list yet)
  let b = listBuf()
  if b.id >= 0: return b.lines
  let p = listPath()
  if fileExists(p):
    result = readFile(p).replace("\r\n", "\n").split('\n')
    if result.len > 0 and result[^1].len == 0: result.setLen(result.len - 1)

func checkbox(s: string): (int, bool, int) =
  ## a task's line: (its indentation, done, where its text starts) — (-1, …) when it is not one
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  if i + 4 < s.len and s[i] in {'-', '*', '+'} and s[i + 1] == ' ' and s[i + 2] == '[' and
     s[i + 3] in {' ', 'x', 'X'} and s[i + 4] == ']' and (i + 5 == s.len or s[i + 5] == ' '):
    return (i, s[i + 3] != ' ', min(s.len, i + 6))
  (-1, false, 0)

func linkOf(s: string): (string, int, int) =
  ## the place in a task's text, → [path:line](…): (path, line from 0, where "→" starts) — ("", …) none
  let a = s.find("→ [")
  if a < 0: return ("", 0, -1)
  let b = s.find("](", a)
  if b < 0: return ("", 0, -1)
  let label = s[a + "→ [".len ..< b]
  let c = label.rfind(':')
  if c <= 0: return (label, 0, a)
  try: (label[0 ..< c], max(0, parseInt(label[c + 1 .. ^1]) - 1), a)
  except ValueError: (label, 0, a)

func tasksOf(ls: seq[string]): seq[Task] =
  ## the tasks in the lines of the list: each checkbox line with the more indented lines under it, its priority from a
  ## leading (A), its due: date and its → [path:line] place read from the text
  var i = 0
  while i < ls.len:
    let (ind, done, at) = checkbox(ls[i])
    if ind < 0:
      inc i
      continue
    var t = Task(line: i, last: i, done: done, text: ls[i][at .. ^1].strip, prio: '~')
    var j = i + 1
    while j < ls.len:                    # (the lines indented under it are its own)
      let s = ls[j]
      var k = 0
      while k < s.len and s[k] in {' ', '\t'}: inc k
      if s.strip.len == 0 or k <= ind: break
      t.last = j
      inc j
    let s = t.text
    if s.len >= 4 and s[0] == '(' and s[1] in {'A' .. 'Z'} and s[2] == ')' and s[3] == ' ': t.prio = s[1]
    let d = s.find("due:")
    if d >= 0 and (d == 0 or s[d - 1] == ' ') and d + 14 <= s.len and dayNum(s[d + 4 ..< d + 14]) >= 0:
      t.due = s[d + 4 ..< d + 14]
    let (lp, ll, _) = linkOf(s)
    t.linkPath = lp
    t.linkLine = ll
    result.add t
    i = t.last + 1

func shown(t: Task): string =
  ## a task's text without its place and due date (the list shows them beside it)
  var s = t.text
  let (_, _, a) = linkOf(s)
  if a >= 0: s = s[0 ..< a]
  if t.due.len > 0: s = s.replace("due:" & t.due, "")
  let k = s.find(" ✓ ")
  if k >= 0: s = s[0 ..< k]
  var ws: seq[string]
  for w in s.split(' '):
    if w.len > 0: ws.add w
  ws.join(" ")

func before(a, b: Task): bool =
  ## the order of the list: a day due before none, earlier first; then (A) before (B) before none; then the file's
  let da = if a.due.len > 0: dayNum(a.due) else: high(int)
  let db = if b.due.len > 0: dayNum(b.due) else: high(int)
  if da != db: return da < db
  if a.prio != b.prio: return a.prio < b.prio
  a.line < b.line

proc openTasks(ls: seq[string]): seq[Task] =
  ## the tasks not done, in the order of the list: the earliest due first, then by priority, then as the file has them
  for t in tasksOf(ls):
    if not t.done: result.add t
  result.sort(proc(a, b: Task): int = (if before(a, b): -1 elif before(b, a): 1 else: 0))

proc refresh()

proc writeList(ls: seq[string]): bool =
  ## the list changed: in its tab when it is open (saved, when it had no other changes), else in the file — or,
  ## when the plugin may not write files, in a tab of its own to save
  let b = listBuf()
  if b.id >= 0:
    let clean = not b.dirty
    b.setText(ls.join("\n"))
    if clean: b.save()
    result = true
  elif allowed("files"):
    try:
      writeFile(listPath(), ls.join("\n") & "\n")
      result = true
    except CatchableError as e:
      warn("Todo: " & listPath() & " could not be written — " & e.msg)
  else:
    let nb = openFile(listPath())
    if nb.valid:
      nb.setText(ls.join("\n"))
      message("Todo: the list is in a tab — save it (the plugin may not write files: Plugins dock › todo)")
      result = true
  refresh()

# ── what the commands do ──

proc relTo(dir, p: string): string =
  ## the path `p` from the folder `dir` when it is inside it, else as it is
  if dir.len > 0 and p.startsWith(dir & "/"): p[dir.len + 1 .. ^1] else: p

proc fromComment(b: Buf): string =
  ## the cursor's line as a task, when it is a TODO, FIXME … comment ("" when it is not one)
  let s = b.line(b.cursor.line)
  let c = b.lineComment
  let at = if c.len > 0: s.find(c) else: -1
  if at < 0: return ""
  let rest = s[at + c.len .. ^1]
  for tag in Tags:
    let k = rest.find(tag)
    if k < 0 or (k > 0 and rest[k - 1] notin {' ', '\t', '#', '/', '*', '-'}) or
       (k + tag.len < rest.len and rest[k + tag.len] notin {' ', ':', '(', '!', '-'}): continue
    var t = rest[k + tag.len .. ^1]
    if t.startsWith("("):                 # TODO(ann): …
      let e = t.find(')')
      if e > 0: t = t[e + 1 .. ^1]
    return t.strip(chars = {' ', ':', '-', '!', '\t'}).strip
  ""

proc addTask(text: string): int =
  ## a task at the end of the open ones (before a ## Done heading): the open tasks now (-1: not written)
  var ls = readList()
  if ls.len == 0: ls = @["# Tasks"]
  var doneHead = ls.len
  for i, l in ls:
    if l.strip.toLowerAscii in ["## done", "# done"]:
      doneHead = i
      break
  var at = -1
  for t in tasksOf(ls):
    if t.line < doneHead: at = t.last + 1
  if at < 0:
    at = doneHead
    while at > 0 and ls[at - 1].strip.len == 0: dec at
    if at > 0:                            # (a blank line after a heading or a paragraph)
      ls.insert("", at)
      inc at
  ls.insert("- [ ] " & text, at)
  if at + 1 < ls.len and ls[at + 1].startsWith("#"): ls.insert("", at + 1)
  if not writeList(ls): return -1
  openTasks(ls).len

proc addCmd() =
  ## Todo: add a task — asks for the text (offering the TODO or FIXME comment on the cursor's line, else the selection),
  ## turns the due: words typed (fri, +3 …) into dates and, for a comment or when plugins.todo.linkHere is on, adds a
  ## link to where the cursor is; then puts it at the end of the open tasks and says how many there are
  let b = current()
  var text = ""
  var here = false
  if b.valid:
    text = fromComment(b)
    here = text.len > 0 or setting("linkHere", false)
    if text.len == 0:
      let r = b.selection
      if r.start.line == r.stop.line and r.start.col != r.stop.col: text = b.textIn(r).strip
  let typed = ask("A task (due:fri, due:+3 · (A) first · +tag)", text).strip
  if typed.len == 0: return
  let now = today()
  var words = typed.split(' ')
  for w in words.mitems:
    if w.startsWith("due:") and w.len > 4:
      let d = dueFrom(w[4 .. ^1], now)
      if d.len > 0: w = "due:" & d
  var line = words.join(" ")
  if here and b.valid and b.path.len > 0 and b.path != listPath():
    let rel = relTo(listPath().parentDir, b.path)
    let l = b.cursor.line + 1
    line.add " → [" & rel & ":" & $l & "](" & rel & "#L" & $l & ")"
  let n = addTask(line)
  if n >= 0:
    message("Todo: added — " & plural(n, "open task") & " in " & extractFilename(listPath()))

proc toggled(s: string, now: int): string =
  ## a task's line ticked off (with the day, doneDate) — or back
  let (ind, done, _) = checkbox(s)
  if ind < 0: return s
  if done:
    result = s[0 .. ind + 2] & " " & s[ind + 4 .. ^1]
    let k = result.find(" ✓ ")
    if k >= 0 and k + " ✓ ".len + 10 <= result.len and dayNum(result[k + " ✓ ".len ..< k + " ✓ ".len + 10]) >= 0:
      result = result[0 ..< k] & result[k + " ✓ ".len + 10 .. ^1]
  else:
    result = s[0 .. ind + 2] & "x" & s[ind + 4 .. ^1]
    if setting("doneDate", true): result = result.strip(leading = false) & " ✓ " & iso(now)

proc setDone(t: Task, done: bool) =
  ## makes the task done or not done in the list (ticking it with the day, or back), if its line is still a task, and
  ## says so
  var ls = readList()
  if t.line >= ls.len or checkbox(ls[t.line])[0] < 0: return
  if checkbox(ls[t.line])[1] != done: ls[t.line] = toggled(ls[t.line], today())
  if writeList(ls):
    message("Todo: " & (if done: "✓ done — " else: "not done — ") & shown(t).substr(0, 60))

proc toggleCmd() =
  ## Todo: done / not done — ticks off or reopens the task on the cursor's line in the current file, whichever Markdown
  ## file it is; the list is refreshed when that file is the list
  let b = current()
  if not b.valid: return
  let l = b.cursor.line
  let s = b.line(l)
  if checkbox(s)[0] < 0:
    message("Todo: put the cursor on a task's line (- [ ] …)")
    return
  b.replace(b.lineRange(l), toggled(s, today()))
  if b.path == listPath(): refresh()

proc archiveCmd() =
  ## the done tasks (and their lines) under ## Done, at the end
  var ls = readList()
  var doneHead = -1
  for i, l in ls:
    if l.strip.toLowerAscii in ["## done", "# done"]:
      doneHead = i
      break
  var moved: seq[string]
  var keep: seq[string]
  var n = 0
  var i = 0
  let ts = tasksOf(ls)
  var k = 0
  while i < ls.len:
    while k < ts.len and ts[k].line < i: inc k
    if k < ts.len and ts[k].line == i and ts[k].done and (doneHead < 0 or i < doneHead):
      for j in i .. ts[k].last: moved.add ls[j]
      inc n
      i = ts[k].last + 1
      continue
    keep.add ls[i]
    inc i
  if n == 0:
    message("Todo: no done tasks to move")
    return
  var h = -1
  for j, l in keep:
    if l.strip.toLowerAscii in ["## done", "# done"]: h = j
  if h < 0:
    while keep.len > 0 and keep[^1].strip.len == 0: keep.setLen(keep.len - 1)
    if keep.len > 0: keep.add ""
    keep.add "## Done"
    h = keep.high
  # (right under the heading, after a blank line: the ones done last on top of those done before)
  if h + 1 >= keep.len or keep[h + 1].strip.len > 0: keep.insert("", h + 1)
  for j in countdown(moved.high, 0): keep.insert(moved[j], h + 2)
  if writeList(keep): message("Todo: " & plural(n, "done task") & " moved under ## Done")

proc openList() =
  ## opens the task list in a tab; when there is none yet it asks, and makes it with a heading
  let p = listPath()
  if not fileExists(p) and listBuf().id < 0:
    if not confirm("Make " & extractFilename(p) & " in the project's folder?"): return
    if not writeList(@["# Tasks", ""]): return
  discard openFile(p, 0)

proc setDue(t: Task) =
  ## asks for a due date for the task (a date, today, fri, +3 …; empty removes it) and writes it in its line: in place
  ## of the old date, else before its place or tick, else at the end
  let d = ask("Due (a date, today, tomorrow, fri, +3 — empty: none)", t.due).strip
  var ls = readList()
  if t.line >= ls.len: return
  var s = ls[t.line]
  let x = if d.len > 0: dueFrom(d, today()) else: ""
  if d.len > 0 and x.len == 0:
    message("Todo: not a day — " & d)
    return
  if t.due.len > 0:                      # (in its place)
    s = if x.len > 0: s.replace("due:" & t.due, "due:" & x) else: s.replace(" due:" & t.due, "").replace("due:" & t.due, "")
  elif x.len > 0:                        # (before the place and the ✓, else at the end)
    let (_, _, a) = linkOf(s)
    let k = s.find(" ✓ ")
    let at = if a >= 0: a elif k >= 0: k else: s.len
    s = s[0 ..< at].strip(leading = false) & " due:" & x & (if at < s.len: " " & s[at .. ^1].strip else: "")
  ls[t.line] = s
  if writeList(ls): message("Todo: " & (if d.len > 0: dueWords(dueFrom(d, today()), today()) else: "no due date"))

proc taskMenu(t: Task) =
  ## what to do with one task
  var items = @[(if t.done: "☐ Not done" else: "✓ Done")]
  var acts = @["done"]
  if t.linkPath.len > 0:
    items.add "→ Go to " & t.linkPath & ":" & $(t.linkLine + 1)
    acts.add "go"
  items.add ["Show it in " & extractFilename(listPath()), "Due date…", "Remove it"]
  acts.add ["show", "due", "remove"]
  let i = pick(shown(t).substr(0, 70), items)
  if i < 0: return
  case acts[i]
  of "done": setDone(t, not t.done)
  of "go":
    let p = if t.linkPath.isAbsolute: t.linkPath else: listPath().parentDir / t.linkPath
    discard openFile(p, t.linkLine)
  of "show": discard openFile(listPath(), t.line)
  of "due": setDue(t)
  of "remove":
    if confirm("Remove “" & shown(t).substr(0, 60) & "”?"):
      var ls = readList()
      if t.last < ls.len:
        for _ in t.line .. t.last: ls.delete(t.line)
        if writeList(ls): message("Todo: removed")
  else: discard

proc taskAt(line: int): (bool, Task) =
  ## the task of the list that starts on that line (false when there is none)
  for t in tasksOf(readList()):
    if t.line == line: return (true, t)
  (false, Task())

proc listCmd() =
  ## Todo: the list — a pick of the open tasks (⚠ overdue, ● due today, with the due date and place beside each), "add a
  ## task" first and, when some are done, the offer to move them under ## Done last; a task opens its menu
  let ls = readList()
  let ts = openTasks(ls)
  var done = 0
  for t in tasksOf(ls):
    if t.done: inc done
  if ts.len == 0 and done == 0:
    if ls.len == 0: message("Todo: no tasks yet — Todo: add a task… (Alt+Shift+A)")
    else: message("Todo: nothing to do")
    if ls.len == 0: return
  let now = today()
  var items = @["+ Add a task…"]
  var details = @[""]
  for t in ts:
    let d = dayNum(t.due) - now
    let mark = if t.due.len > 0 and d < 0: "⚠ " elif t.due.len > 0 and d == 0: "● " else: "☐ "
    items.add mark & shown(t)
    var det = if t.due.len > 0: dueWords(t.due, now) else: ""
    if t.linkPath.len > 0: det.add (if det.len > 0: " · " else: "") & t.linkPath & ":" & $(t.linkLine + 1)
    details.add det
  if done > 0:
    items.add "✓ " & plural(done, "done task") & " — move them under ## Done"
    details.add ""
  let i = pick("Tasks — " & $ts.len & " open (" & extractFilename(listPath()) & ")", items, details)
  if i < 0: return
  if i == 0: addCmd()
  elif i <= ts.len: taskMenu(ts[i - 1])
  else: archiveCmd()

# ── the status bar, the dock, TODO.md's own marks ──

var lastDay = -1

proc refresh() =
  ## reads the list again: the status bar shows the open tasks (and how many are overdue or due today) unless
  ## plugins.todo.statusBar is off, and the TODO LIST view in the dock is redrawn; remembers the day it was done
  let ls = readList()
  let now = today()
  lastDay = now
  var open, urgent = 0
  for t in tasksOf(ls):
    if t.done: continue
    inc open
    if t.due.len > 0 and dayNum(t.due) <= now: inc urgent
  if setting("statusBar", true):
    status(if open == 0: "" else: "☐ " & $open & (if urgent > 0: " ⚠ " & $urgent else: ""))
  else: status("")
  refreshView(View)

proc decorate(b: Buf) =
  ## after each due date of the list: how far it is
  if not b.valid or b.path != listPath(): return
  b.clearDecorations()
  let now = today()
  for t in tasksOf(b.lines):
    if t.done or t.due.len == 0: continue
    let d = dayNum(t.due) - now
    if d < 0: b.virtualText(t.line, "overdue " & plural(-d, "day"), "error")
    elif d == 0: b.virtualText(t.line, "today", "warn")
    elif d == 1: b.virtualText(t.line, "tomorrow", "info")
    else: b.virtualText(t.line, "in " & plural(d, "day"), "hint")

view(View) do () -> seq[ViewItem]:
  let ls = readList()
  let now = today()
  result.add ViewItem(text: "+ add a task", id: "add", color: "accent")
  var done = 0
  for t in tasksOf(ls):
    if t.done: inc done
  for t in openTasks(ls):
    let d = dayNum(t.due) - now
    let urgent = t.due.len > 0 and d <= 0
    result.add ViewItem(text: shown(t), detail: (if t.due.len > 0: dueWords(t.due, now) else: ""),
                        icon: (if t.due.len > 0 and d < 0: "⚠" elif urgent: "●" else: "☐"),
                        color: (if t.due.len > 0 and d < 0: "error" elif urgent: "warn" else: ""), id: $t.line)
  if done > 0: result.add ViewItem(text: plural(done, "done task") & " — move them under ## Done", icon: "✓",
                                   id: "archive", color: "hint")
do (id: string):
  case id
  of "add": addCmd()
  of "archive": archiveCmd()
  else:
    try:
      let (ok, t) = taskAt(parseInt(id))
      if ok: taskMenu(t)
    except ValueError: discard

command "Todo: add a task…", "alt+shift+a": addCmd()
command "Todo: the list…", "alt+shift+l": listCmd()
command "Todo: done / not done": toggleCmd()
command "Todo: archive the done tasks": archiveCmd()
command "Todo: open the list": openList()

nmap("<leader>ta", "Todo: add a task", proc(c: int) = addCmd())
nmap("<leader>tl", "Todo: the list", proc(c: int) = listCmd())
nmap("<leader>tx", "Todo: done / not done", proc(c: int) = toggleCmd())

codeActions("markdown", proc(b: Buf, r: Range): seq[Fix] =
  let l = r.start.line
  let s = b.line(l)
  let (ind, done, _) = checkbox(s)
  if ind >= 0:
    result.add Fix(title: (if done: "Todo: not done" else: "Todo: done ✓"),
                   edits: @[Edit(range: b.lineRange(l), text: toggled(s, today()))]))

completions("markdown", proc(b: Buf, p: Pos, prefix: string): seq[CompletionItem] =
  let s = b.line(p.line)
  let before = s[0 ..< min(s.len, p.col)]
  if not before.endsWith("due:" & prefix): return
  let now = today()
  var words = @["today", "tomorrow"]
  for d in Weekdays: words.add d
  words.add ["week", "month"]
  for w in words:
    let d = case w
      of "week": iso(now + 7)
      of "month":
        let (y, m, dd) = civilFromDays(now)
        let (y2, m2) = if m == 12: (y + 1, 1) else: (y, m + 1)
        var x = daysFromCivil(y2, m2, dd)
        while iso(x)[5 .. 6] != pad2(m2): dec x            # (the 31st of a month that has 30)
        iso(x)
      else: dueFrom(w, now)
    result.add CompletionItem(label: w, insert: d, detail: d & (if w in ["week", "month"]: " (in a " & w & ")" else: ""),
                              kind: "constant"))

onStartup(proc(ev: Event) =
  refresh()
  if not setting("remindAtStart", true): return
  let now = today()
  var late, due = 0
  for t in openTasks(readList()):
    if t.due.len == 0: continue
    let d = dayNum(t.due) - now
    if d < 0: inc late
    elif d == 0: inc due
  if late + due > 0:
    var parts: seq[string]
    if late > 0: parts.add plural(late, "task") & " overdue"
    if due > 0: parts.add (if late > 0: $due else: plural(due, "task")) & " due today"
    toast("Todo: " & parts.join(", ") & " — Alt+Shift+L lists them"))

onOpen("*", proc(ev: Event) = decorate(ev.buf))
onChange("*", proc(ev: Event) = decorate(ev.buf))
onSave("*", proc(ev: Event) =
  if ev.path == listPath():
    decorate(ev.buf)
    refresh())
onEnter("*", proc(ev: Event) =
  if today() != lastDay: refresh())       # (a new day: what is due changes)

discard every(600_000, proc() =
  if today() != lastDay: refresh())
