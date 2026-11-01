## log-tail — a log file followed as it grows, its errors and warnings coloured, and only the lines you want to see
##
##   Log: follow this file        the file in front followed: as lines come in (ned reloads a file that changes on
##                                disk), the cursor goes to the last one and the new ones are coloured — errors red,
##                                warnings yellow, debug lines dim; ⇣ in the status bar. Again to stop following
##   Log: colour this file        its errors, warnings and debug lines coloured once (the last 5000 lines)
##   Log: only the lines with…    the lines that have a word — or any of several, with | between — in a tab of their
##                                own, coloured too
##   settings                     plugins.log-tail.errorWords, .warnWords, .debugWords: the words that say what a line
##                                is (any case)
##
## A file that gets shorter (a log rotated, emptied) is coloured again from its start.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("errorWords", "error|fatal|panic|critical|exception|traceback|failed|crit|emerg",
           "Log: the words that make a line an error (with | between, any case)")
settingDef("warnWords", "warn|warning|deprecated", "Log: the words that make a line a warning (with | between)")
settingDef("debugWords", "debug|trace|verbose", "Log: the words that make a line a debug line, shown dim")

var
  following = -1                # the file followed (-1: none)
  seenLines = 0                 # how many of its lines were coloured
  timer = -1
  lastQuery = "error|warn"

proc words(key, default: string): seq[string] =
  ## a setting's words, small letters
  for w in setting(key, default).split('|'):
    if w.strip.len > 0: result.add w.strip.toLowerAscii

func hasWord(low: string, ws: seq[string]): bool =
  ## does the line (in small letters) have one of the words, as a word of its own (not inside a longer one)?
  for w in ws:
    var k = low.find(w)
    while k >= 0:
      let a = k == 0 or low[k - 1] notin {'a'..'z'}
      let e = k + w.len >= low.len or low[k + w.len] notin {'a'..'z'}
      if a and (e or w.len >= 4): return true          # (warn in warning; not err in terrible)
      k = low.find(w, k + 1)
  false

proc kindOf*(line: string, errs, warns, dbg: seq[string]): string =
  ## what the line is: "error", "warn", "hint" (debug) or "" (an ordinary line)
  let low = line.toLowerAscii
  if hasWord(low, errs): "error"
  elif hasWord(low, warns): "warn"
  elif hasWord(low, dbg): "hint"
  else: ""

proc colour(b: Buf, ls: seq[string], first: int) =
  ## the lines from `first` coloured by what they are (a run of lines of one kind at a time)
  let errs = words("errorWords", "error|fatal|panic|critical|exception|traceback|failed|crit|emerg")
  let warns = words("warnWords", "warn|warning|deprecated")
  let dbg = words("debugWords", "debug|trace|verbose")
  var i = max(0, first)
  while i < ls.len:
    let k = kindOf(ls[i], errs, warns, dbg)
    var j = i
    while j + 1 < ls.len and kindOf(ls[j + 1], errs, warns, dbg) == k: inc j
    if k.len > 0: b.highlight(rng(pos(i, 0), pos(j, ls[j].len)), k)
    i = j + 1

proc follow() =
  ## (every second while following) new lines: coloured, the cursor to the last one
  if following < 0: return
  let b = Buf(id: following)
  var n = 0
  try: n = b.lineCount
  except CatchableError:                  # (its tab closed)
    stopTimer(timer)
    timer = -1
    following = -1
    status("")
    return
  if n == seenLines: return
  if n < seenLines:                       # (shorter: rotated or emptied — coloured again from the start)
    b.clearDecorations()
    seenLines = 0
  let ls = b.lines
  colour(b, ls, max(seenLines - 1, ls.len - 5000))
  seenLines = ls.len
  if current().id == following: b.setCursor(pos(max(0, ls.high), 0))

command "Log: follow this file":
  let b = current()
  if following == b.id:
    if timer >= 0: stopTimer(timer)
    timer = -1
    following = -1
    status("")
    message("Log: not following " & extractFilename(b.path) & " any more")
  else:
    if following >= 0:
      try: Buf(id: following).clearDecorations()
      except CatchableError: discard
    following = b.id
    b.clearDecorations()
    let ls = b.lines
    colour(b, ls, ls.len - 5000)
    seenLines = ls.len
    b.setCursor(pos(max(0, ls.high), 0))
    if timer < 0: timer = every(1000) do (): follow()
    status("⇣ " & extractFilename(b.path))
    message("Log: following " & extractFilename(b.path) & " — again to stop")

command "Log: colour this file":
  let b = current()
  b.clearDecorations()
  let ls = b.lines
  colour(b, ls, ls.len - 5000)
  message("Log: coloured")

command "Log: only the lines with…":
  let b = current()
  let q = ask("Only the lines with (| between several words):", lastQuery).strip
  if q.len > 0:
    lastQuery = q
    var ws: seq[string]
    for w in q.split('|'):
      if w.strip.len > 0: ws.add w.strip.toLowerAscii
    var kept: seq[string]
    for l in b.lines:
      let low = l.toLowerAscii
      for w in ws:
        if w in low:
          kept.add l
          break
    if kept.len == 0: message("Log: no line has " & q)
    else:
      let t = newTab("log: " & q, kept.join("\n"), "")
      colour(t, kept, 0)
      message("Log: " & $kept.len & (if kept.len == 1: " line" else: " lines") & " with " & q)
