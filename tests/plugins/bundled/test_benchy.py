"""benchy: a file of benchmarks run with nim r (benchy's timeIt blocks — a benchy of the test's own, with fixed numbers
— and timings of std/monotimes, a Duration and `name: 1.5 ms`), the results in a table in a tab and after their lines;
a second run compared with the first (faster, slower, the same within the threshold, one gone; a -d:benchyHistogram
row), the last results shown again, a run that fails, a file that is not Nim"""
import os
from tplugins import check
from tbundled import run_jobs, pos

BENCHY = '''import std/strutils
var shownHeader = false
template keep*(value: untyped) = discard
proc row(m, s, d: float, num: int, tag: string) =
  echo align(formatFloat(m, ffDecimal, 3), 8), " ms ", align(formatFloat(s, ffDecimal, 3), 8), " ms ",
       align("±" & formatFloat(d, ffDecimal, 3), 8), "  ", align("x" & $num, 5), " ", tag
template timeIt*(tag: string, iterations: untyped, body: untyped) =
  if not shownHeader:
    shownHeader = true
    echo "   min time    avg time  std dv   runs name"
  block:
    proc test() {.gensym.} =
      body
    test()
  if tag == "fib 20": row(2.411, 2.448, 0.037, 1000, tag)
  else: row(0.012, 0.013, 0.001, 100, tag)
template timeIt*(tag: string, body: untyped) = timeIt(tag, 0, body)
'''

BENCH = '''import benchy, std/[monotimes, times]

proc fib(n: int): int = (if n < 2: n else: fib(n - 1) + fib(n - 2))

timeIt "fib 20":
  keep fib(20)

timeIt "sum", 100:
  var s = 0
  for i in 0 .. 1000: s += i
  keep s

let t0 = getMonoTime()
discard fib(15)
echo "mono fib: ", getMonoTime() - t0
echo "parse: 1.5 ms"
'''

SECOND = """   min time    avg time  std dv   runs name
   1.950 ms    2.000 ms    ±0.010  x1000 ⣀⣤⣿⣤⣀  fib 20
   0.013 ms    0.0135 ms    ±0.001    x100 sum
parse: 1.51 ms
"""


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    titles = ["Bench: run this file", "Bench: show the last results", "Bench: clear the marks"]
    c = {t: h.reg("command", title=t) for t in titles}
    snips = {r["trigger"] for r in h.regs if r["kind"] == "snippet" and r["lang"] == "nim"}
    sd = {k: (h.reg("setting", key=k) or {}).get("default") for k in ("command", "threshold")}
    check(tag + "its commands, snippets (timeit, monobench) and settings",
          all(c.values()) and snips == {"timeit", "monobench"} and
          sd == {"command": "nim r -d:release --hints:off $file", "threshold": 3}, (snips, sd))
    if not all(c.values()):
        return
    proj = os.path.join(h.tmp, "proj")
    os.makedirs(proj)
    h.root = proj
    open(os.path.join(proj, "benchy.nim"), "w").write(BENCHY)
    f = os.path.join(proj, "bench.nim")
    open(f, "w").write(BENCH)
    h.path_ = f
    h.lines = BENCH.rstrip("\n").split("\n")
    h.dirty_ = True

    def vt():
        return sorted((a["line"], a["text"], a.get("color")) for fn, a in h.decor if fn == "vtext")

    h.call(c["Bench: run this file"]["cb"])
    check(tag + "run: the file saved first, nim r on it in the background",
          h.saved == 1 and len(h.jobs) == 1 and h.jobs[0][0].startswith("nim r -d:release --hints:off ") and
          f in h.jobs[0][0], h.jobs)
    run_jobs(h, timeout=300)
    v = vt()
    want = [(4, "→ 2.448 ms", "hint"), (7, "→ 13.00 µs", "hint"), (15, "→ 1.500 ms", "hint")]
    check(tag + "each result after its line: the timeIt blocks, the line that prints the timing", all(
        w in v for w in want) and any(l == 14 and t.startswith("→ ") and t.endswith(("µs", "ns", "ms"))
                                      for l, t, _ in v), v)
    tab = h.tabs[-1] if h.tabs else ("", "", "")
    check(tag + "the table in a Markdown tab: benchy's rows, the Duration, `name: 1.5 ms`; the first run",
          tab[0] == "Bench: bench.nim" and tab[2] == "markdown" and "the first run" in tab[1] and
          "| fib 20 | 2.411 ms | 2.448 ms | 37.00 µs | 1000 |" in tab[1] and "| sum | 12.00 µs | 13.00 µs |" in tab[1]
          and "| mono fib |" in tab[1] and "| parse | 1.500 ms | 1.500 ms |  | 1 |" in tab[1], tab[1])
    check(tag + "what the program printed in the Output panel",
          any("mono fib: " in o and "x1000 fib 20" in o for o in h.output), h.output[-1:])
    # the second run (its output given by a command of the test's): compared with the first
    out2 = os.path.join(h.tmp, "second.txt")
    open(out2, "w").write(SECOND)
    h.settings["command"] = "cat " + out2
    h.dirty_ = False
    h.call(c["Bench: run this file"]["cb"])
    run_jobs(h)
    tab = h.tabs[-1]
    check(tag + "a second run: beside the last one's averages — faster, slower, the same within 3%, one not in it",
          "compared with the run of" in tab[1] and "| fib 20 | 1.950 ms | 2.000 ms | 10.00 µs | 1000 | 2.448 ms | 18% faster |"
          in tab[1] and "| sum | 13.00 µs | 13.50 µs | 1.000 µs | 100 | 13.00 µs | 3.8% slower |" in tab[1] and
          "| parse | 1.510 ms | 1.510 ms |  | 1 | 1.500 ms | the same (+0.7%) |" in tab[1] and
          "Not in this run: mono fib" in tab[1], tab[1])
    v = vt()
    check(tag + "the marks: faster in green, slower in red, the same in grey",
          v == [(4, "→ 2.000 ms · 18% faster", "add"), (7, "→ 13.50 µs · 3.8% slower", "del"),
                (15, "→ 1.510 ms · the same (+0.7%)", "hint")], v)
    h.tabs = []
    h.call(c["Bench: show the last results"]["cb"])
    check(tag + "the last results shown again", h.tabs and "18% faster" in h.tabs[-1][1], h.tabs)
    h.call(c["Bench: clear the marks"]["cb"])
    check(tag + "the marks cleared", vt() == [], vt())
    # a run that fails: said, the Output panel opened
    h.settings["command"] = "sh -c 'echo bench.nim: Error: undeclared identifier; exit 1' --"
    h.messages = []
    h.calls_seen = []
    h.call(c["Bench: run this file"]["cb"])
    run_jobs(h)
    check(tag + "a run that fails: said, its output in the Output panel",
          any("did not run (exit code 1)" in m for m in h.messages) and "showOutput" in h.calls_seen, h.messages)
    # not a Nim file
    h.path_ = os.path.join(proj, "notes.md")
    h.messages = []
    h.jobs = []
    h.call(c["Bench: run this file"]["cb"])
    check(tag + "a file that is not Nim: said, nothing run", h.jobs == [] and h.messages and "open a .nim file" in
          h.messages[-1], h.messages)
    h.call(c["Bench: show the last results"]["cb"])
    check(tag + "no run of a file yet: said", "no run of notes.md yet" in h.messages[-1], h.messages)
