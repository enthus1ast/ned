## benchy — benchmarks run and shown in a table (benchy's timeIt, or std/monotimes timings), compared with the last run
##
##   Bench: run this file          the file (saved first) compiled with -d:release and run in the background; its
##                                 results in a table in a tab of their own — the min, the average, ± and the runs
##                                 of each benchmark, beside the last run's average and how much faster or slower
##                                 it is now — and after each timeIt line (→ 2.45 ms · 3% faster). What the program
##                                 printed goes to the Output panel. The results are kept for the next run
##   Bench: show the last results  the table of this file's last run again
##   Bench: clear the marks        the → texts after the lines taken away
##   snippets (Nim)                timeit — a benchy block; monobench — a block timed with std/monotimes
##   settings                      plugins.benchy.command — how the file is run ($file in it; "nim r -d:release
##                                 --hints:off $file") · .threshold — a change smaller than this (in percent, 3)
##                                 is "the same"
##
## What it reads in the program's output: benchy's rows (`   2.411 ms    2.448 ms    ±0.037  x1000 fib 30`, with
## -d:benchyHistogram too) and lines of your own timings, `name: 1.25 ms` — the units ns, µs (us), ms and s — or a
## Duration as std/times prints it (`name: 1 millisecond and 250 microseconds`): `echo "parse: ", getMonoTime() -
## t0`. benchy is a nimble package (`nimble install benchy`); std/monotimes needs nothing. It needs nim on PATH.
import nedplugin
import std/[math, sequtils]

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "compiles and runs the file you benchmark with nim r")

settingDef("command", "nim r -d:release --hints:off $file", "Bench: how the file is compiled and run — $file is " &
           "replaced by its path (-d:danger for the fastest code)")
settingDef("threshold", 3, "Bench: a change of the average smaller than this, in percent, is shown as the same")

snippet("nim", "timeit", "timeIt \"${1:name}\":\n\t$0", "a benchy benchmark (import benchy)")
snippet("nim", "monobench", "let t${1:0} = getMonoTime()\n$0\necho \"${2:name}: \", getMonoTime() - t${1:0}",
        "a block timed with std/monotimes (import std/monotimes)")

type Result* = object
  name*: string
  minMs*, avgMs*, sdMs*: float    # milliseconds
  runs*: int

# ── reading the output ──

func numAt(s: string, i: var int): float =
  ## the number at i (digits, a dot), i moved past it; -1 when there is none
  let a = i
  while i < s.len and s[i] in {'0'..'9', '.'}: inc i
  if i == a: return -1
  try: parseFloat(s[a ..< i]) except ValueError: -1

func skipSpaces(s: string, i: var int) =
  ## moves i past any spaces at it
  while i < s.len and s[i] == ' ': inc i

func benchyRow*(line: string): (bool, Result) =
  ## a row of benchy's table: min ms, avg ms, ±sd, xRuns, [a histogram], the name
  var i = 0
  skipSpaces(line, i)
  let mn = numAt(line, i)
  if mn < 0 or not line.continuesWith(" ms", i): return
  i += 3
  skipSpaces(line, i)
  let av = numAt(line, i)
  if av < 0 or not line.continuesWith(" ms", i): return
  i += 3
  skipSpaces(line, i)
  if not line.continuesWith("±", i): return
  i += "±".len
  let sd = numAt(line, i)
  if sd < 0: return
  skipSpaces(line, i)
  if i >= line.len or line[i] != 'x': return
  inc i
  let a = i
  while i < line.len and line[i] in {'0'..'9'}: inc i
  if i == a: return
  let runs = parseInt(line[a ..< i])
  skipSpaces(line, i)
  # (-d:benchyHistogram: braille dots before the name, then two spaces)
  var j = i
  while j + 2 < line.len and line[j] == '\xE2' and line[j + 1] in {'\xA0'..'\xA3'}: j += 3
  if j > i and line.continuesWith("  ", j): i = j + 2
  let name = line[i .. ^1].strip
  if name.len == 0: return
  (true, Result(name: name, minMs: mn, avgMs: av, sdMs: sd, runs: runs))

const Units = [("nanoseconds", 1e-6), ("nanosecond", 1e-6), ("microseconds", 1e-3), ("microsecond", 1e-3),
               ("milliseconds", 1.0), ("millisecond", 1.0), ("seconds", 1000.0), ("second", 1000.0),
               ("minutes", 60_000.0), ("minute", 60_000.0), ("hours", 3_600_000.0), ("hour", 3_600_000.0),
               ("ns", 1e-6), ("µs", 1e-3), ("μs", 1e-3), ("us", 1e-3), ("ms", 1.0), ("sec", 1000.0), ("s", 1000.0)]

func timeOf*(text: string): float =
  ## "1.25 ms", "450 µs", "2 s", "1 millisecond and 250 microseconds" (a Duration) in milliseconds; -1: not a time
  var t = text.strip.replace(" and ", ", ")
  if t.len == 0: return -1
  var total = 0.0
  for part in t.split(','):
    let p = part.strip
    var i = 0
    let v = numAt(p, i)
    if v < 0: return -1
    let unit = p[i .. ^1].strip
    var found = false
    for (u, f) in Units:
      if unit == u:
        total += v * f
        found = true
        break
    if not found: return -1
  total

func timingLine*(line: string): (bool, Result) =
  ## a line of your own: `name: 1.25 ms` (or a Duration)
  let c = line.find(": ")
  if c <= 0: return
  let name = line[0 ..< c].strip
  if name.len == 0 or name.len > 80: return
  let ms = timeOf(line[c + 2 .. ^1])
  if ms < 0: return
  (true, Result(name: name, minMs: ms, avgMs: ms, sdMs: 0, runs: 1))

func resultsOf*(output: string): seq[Result] =
  ## every benchmark the program printed, in order (a name printed twice: the last)
  for l in output.splitLines:
    var (ok, r) = benchyRow(l)
    if not ok: (ok, r) = timingLine(l)
    if not ok: continue
    var dup = false
    for x in result.mitems:
      if x.name == r.name:
        x = r
        dup = true
    if not dup: result.add r

# ── showing them ──

func showTime*(ms: float): string =
  ## a time in the unit that suits it: 812 ns, 45.2 µs, 2.45 ms, 1.30 s
  func three(x: float): string =
    if x >= 100: formatFloat(x, ffDecimal, 1)
    elif x >= 10: formatFloat(x, ffDecimal, 2)
    else: formatFloat(x, ffDecimal, 3)
  if ms < 0.001: $int(round(ms * 1e6)) & " ns"
  elif ms < 1: three(ms * 1000) & " µs"
  elif ms < 1000: three(ms) & " ms"
  else: three(ms / 1000) & " s"

func change*(now, before: float, threshold: int): (string, int) =
  ## how the average moved: ("12% faster", -1), ("3% slower", 1), ("the same", 0)
  if before <= 0: return ("", 0)
  let pct = (now - before) / before * 100
  let shown = if abs(pct) >= 10: $int(round(abs(pct))) else: formatFloat(abs(pct), ffDecimal, 1)
  if abs(pct) < float(threshold): ("the same (" & (if pct < 0: "−" else: "+") & shown & "%)", 0)
  elif pct < 0: (shown & "% faster", -1)
  else: (shown & "% slower", 1)

func lineOf*(lines: seq[string], name: string): int =
  ## the line that makes a benchmark: its timeIt (benchy), else the line that prints its name; -1 none
  for i, l in lines:
    let t = l.strip
    if t.startsWith("timeIt") and ("\"" & name & "\"") in t: return i
  for i, l in lines:
    if ("\"" & name & ":") in l or ("\"" & name & "\"") in l: return i
  -1

func table*(file, stamp: string, rs, last: seq[Result], lastStamp: string, threshold: int): string =
  ## the results as a Markdown table, beside the last run's
  result = "# Benchmarks: " & file & "\n\n" & stamp &
           (if lastStamp.len > 0: " — compared with the run of " & lastStamp else: " — the first run") & "\n\n"
  if rs.len == 0:
    return result & "No benchmark in what the program printed: benchy's timeIt rows, or lines like " &
           "`name: 1.25 ms`.\n"
  result.add "| benchmark | min | average | ± | runs | last run | change |\n|---|---:|---:|---:|---:|---:|---|\n"
  for r in rs:
    var before = ""
    var ch = ""
    for l in last:
      if l.name == r.name:
        before = showTime(l.avgMs)
        ch = change(r.avgMs, l.avgMs, threshold)[0]
    result.add "| " & r.name.replace("|", "\\|") & " | " & showTime(r.minMs) & " | " & showTime(r.avgMs) & " | " &
               (if r.runs > 1: showTime(r.sdMs) else: "") & " | " & $r.runs & " | " & before & " | " & ch & " |\n"
  var gone: seq[string]
  for l in last:
    if not rs.anyIt(it.name == l.name): gone.add l.name
  if gone.len > 0: result.add "\nNot in this run: " & gone.join(", ") & "\n"

# ── the last runs, kept in the plugin's data folder ──

proc keyOf(path: string): string =
  ## the file's name in the data folder: its path with / made _
  var k = path
  for c in k.mitems:
    if c in {'/', '\\', ':'}: c = '_'
  "runs/" & k.strip(chars = {'_'}) & ".json"

func jsonItems(j: JsonNode): seq[JsonNode] =
  ## a JSON array's items; none for anything else (a key that is not there: nil)
  if j != nil and j.kind == JArray: j.getElems else: @[]

proc loadRun(path: string): (seq[Result], string) =
  ## the results of the file's last run and the time it was made, read from the plugin's data folder; both empty when
  ## nothing was saved or it cannot be read
  try:
    let j = parseJson(readData(keyOf(path)))
    for x in jsonItems(j{"results"}):
      result[0].add Result(name: x{"name"}.getStr, minMs: x{"min"}.getFloat, avgMs: x{"avg"}.getFloat,
                           sdMs: x{"sd"}.getFloat, runs: x{"runs"}.getInt)
    result[1] = j{"when"}.getStr
  except CatchableError: discard

proc saveRun(path: string, rs: seq[Result], stamp: string, previous: seq[Result], previousStamp: string) =
  ## writes this run's results and time to the file's JSON in the data folder, together with the run before it (what
  ## this one was compared with), so the table can be shown again
  var a = newJArray()
  for r in rs: a.add %*{"name": r.name, "min": r.minMs, "avg": r.avgMs, "sd": r.sdMs, "runs": r.runs}
  var p = newJArray()
  for r in previous: p.add %*{"name": r.name, "min": r.minMs, "avg": r.avgMs, "sd": r.sdMs, "runs": r.runs}
  writeData(keyOf(path), $(%*{"path": path, "when": stamp, "results": a,
                              "before": {"when": previousStamp, "results": p}}))

proc mark(b: Buf, rs, last: seq[Result], threshold: int) =
  ## each benchmark's average after its line, with how it moved
  b.clearDecorations()
  let ls = b.lines
  for r in rs:
    let l = lineOf(ls, r.name)
    if l < 0: continue
    var text = "→ " & showTime(r.avgMs)
    var color = "hint"
    for x in last:
      if x.name == r.name:
        let (ch, dir) = change(r.avgMs, x.avgMs, threshold)
        text.add " · " & ch
        color = if dir < 0: "add" elif dir > 0: "del" else: "hint"
    b.virtualText(l, text, color)

# ── the commands ──

var running = false

proc runBench() =
  ## Bench: run this file — saves the .nim file, runs it with the `command` setting in the background, and when it ends
  ## puts the output in the Output panel, reads the benchmarks out of it, compares them with the last saved run, marks
  ## the lines, opens the table in a tab and saves the run; a failed run with no benchmark in it is only reported
  let b = current()
  let path = b.path
  if path.len == 0 or not path.endsWith(".nim"):
    message("Bench: open a .nim file with benchmarks (timeIt blocks, or timings of your own)")
    return
  if running:
    message("Bench: a run is already going")
    return
  if b.dirty:
    try: b.save()
    except ValueError:
      message("Bench: save " & extractFilename(path) & " first (it is outside the project)")
      return
  let cmd = setting("command", "nim r -d:release --hints:off $file").replace("$file", quoteShell(path))
  let name = extractFilename(path)
  running = true
  progress("Bench: running " & name)
  status("⏱ " & name)
  let started = unixTime()
  shellAsync(cmd & " 2>&1") do (o: string, code: int):
    running = false
    progressDone()
    status("")
    let secs = unixTime() - started
    output("▶ " & cmd & "\n" & o & "\n(" & formatFloat(secs, ffDecimal, 1) & " s, exit code " & $code & ")")
    let rs = resultsOf(o)
    if code != 0 and rs.len == 0:
      warn("Bench: " & name & " did not run (exit code " & $code & ") — its output is in the Output panel")
      showOutput()
      return
    let (last, lastStamp) = loadRun(path)
    let stamp = localTime()[0 ..< 16]
    let threshold = setting("threshold", 3)
    saveRun(path, rs, stamp, last, lastStamp)
    try: mark(b, rs, last, threshold)
    except ValueError: discard                     # (its tab was closed meanwhile)
    discard newTab("Bench: " & name, table(name, stamp, rs, last, lastStamp, threshold), "markdown")
    message("Bench: " & $rs.len & " benchmark" & (if rs.len == 1: "" else: "s") & " in " & name &
            (if last.len > 0: ", compared with the last run" else: " — the next run is compared with this one"))

proc showLast() =
  ## Bench: show the last results — opens the table of the file's last saved run (beside the run before it) in a tab,
  ## without running anything
  let b = current()
  let path = b.path
  try:
    let j = parseJson(readData(keyOf(path)))
    var rs, before: seq[Result]
    for x in jsonItems(j{"results"}):
      rs.add Result(name: x{"name"}.getStr, minMs: x{"min"}.getFloat, avgMs: x{"avg"}.getFloat,
                    sdMs: x{"sd"}.getFloat, runs: x{"runs"}.getInt)
    for x in jsonItems(j{"before"}{"results"}):
      before.add Result(name: x{"name"}.getStr, minMs: x{"min"}.getFloat, avgMs: x{"avg"}.getFloat,
                        sdMs: x{"sd"}.getFloat, runs: x{"runs"}.getInt)
    let threshold = setting("threshold", 3)
    discard newTab("Bench: " & extractFilename(path), table(extractFilename(path), j{"when"}.getStr, rs, before,
                   j{"before"}{"when"}.getStr, threshold), "markdown")
  except CatchableError:
    message("Bench: no run of " & extractFilename(path) & " yet — Bench: run this file")

command "Bench: run this file":
  runBench()

command "Bench: show the last results":
  showLast()

command "Bench: clear the marks":
  current().clearDecorations()
