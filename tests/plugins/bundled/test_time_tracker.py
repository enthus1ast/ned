"""time-tracker: the time between the things you do, by the clock (a pretend one: h.clock) — events, another tab,
the cursor moved (its timer called here) —, an idle gap not counted, files and projects apart, today's time in the
status bar (read back from the file at the start), written once a minute (not on each event) and on quit, pause and
resume, the report (today, this week by day, by project, by file; another month's file, a day of last week left
out)."""
import datetime, json, os
from tplugins import check


def start(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return None
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    if not ok:
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return None
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    return h


DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
MONTHS = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
          "November", "December"]


def long_date(d):
    return "%s %d %s" % (DAYS[d.weekday()], d.day, MONTHS[d.month - 1])


def run(factory, tag):
    h = start(factory, tag)
    if not h:
        return
    titles = {r["title"] for r in h.regs if r["kind"] == "command"}
    evs = {r["event"]: r for r in h.regs if r["kind"] == "event"}
    tm = h.reg("timer")
    check(tag + "its commands, the events it counts (and quit), a timer every 15 s, its settings",
          {"Time: report", "Time: pause or resume counting"} <= titles and
          {"open", "change", "save", "enter", "quit"} <= set(evs) and
          all(evs[k]["pattern"] == "*" for k in ("open", "change", "save", "enter"))
          and tm and tm["ms"] == 15000 and tm["repeat"] is True and
          h.reg("setting", key="idleMinutes")["default"] == 5 and h.reg("setting", key="showStatus")["default"] is True,
          (titles, evs, tm))
    T = 1_800_000_000
    h.clock = T                          # (unixTime and localTime: this pretend clock)
    today = datetime.date.fromtimestamp(T)
    data = os.path.join(h.tmp, "data", "time-tracker")
    os.makedirs(data, exist_ok=True)
    month = lambda d: os.path.join(data, d.strftime("%Y-%m") + ".jsonl")

    def write(d, project, file, secs):
        open(month(d), "a").write(json.dumps({"day": d.isoformat(), "project": project, "file": file, "secs": secs}) + "\n")

    def lines(d):
        f = month(d)
        return [json.loads(l) for l in open(f).read().splitlines() if l.strip()] if os.path.exists(f) else []

    def at(t, what, path=None):
        """at second t: an event (open change save enter quit), or the timer"""
        h.clock = T + t
        if what == "tick":
            h.call(tm["cb"])
        else:
            h.call(evs[what]["cb"], {"buf": h.cur, "path": path, "lang": "nim"})

    write(today, "/x/ned", "src/old.nim", 600)
    h.root = "/x/ned"
    h.path_ = "/x/ned/src/a.nim"
    at(0, "open", "/x/ned/src/a.nim")
    s1 = h.status
    at(30, "tick")
    at(60, "change", "/x/ned/src/a.nim")
    s2 = h.status
    n1 = len(lines(today))
    check(tag + "today's time read back from the file; an open, then a change a minute later: the minute counts — in "
          "the status bar, not yet written",
          s1 == "⏱ 10 min today" and s2 == "⏱ 11 min today" and n1 == 1, (s1, s2, n1))
    h.cursor = {"line": 5, "col": 0}
    at(75, "tick")
    written = [l for l in lines(today) if l["file"] == "src/a.nim"]
    h.settings = {"idleMinutes": 1}
    at(75 + 61, "change", "/x/ned/src/a.nim")
    s3 = h.status
    check(tag + "the cursor moved counts (reading); a minute after the last write the time is written (the seconds of "
          "the file summed); a gap longer than idleMinutes is not counted",
          written == [{"day": today.isoformat(), "project": "/x/ned", "file": "src/a.nim", "secs": 75}] and
          s3 == "⏱ 11 min today", (written, s3))
    h.settings = {}
    at(140, "save", "/x/ned/src/b.nim")
    at(170, "change", "/x/ned/src/b.nim")
    h.root = "/x/other"
    at(185, "change", "/x/other/c.nim")
    s4 = h.status
    h.others[2] = {"lines": ["x"], "path": "/x/other/d.nim", "lang": "nim"}
    h.switch_to(2)
    at(200, "enter", "/x/other/d.nim")
    at(230, "change", "")
    check(tag + "another file, another project, another tab (onEnter): each its own time — the time before a change "
          "goes to where you were; the status bar for the project you are in", s4 == "⏱ 0 min today", s4)
    pr = h.reg("command", title="Time: pause or resume counting")["cb"]
    h.clock = T + 240
    h.call(pr)
    m1, s5 = h.messages[-1], h.status
    at(250, "tick")
    at(260, "change", "/x/other/d.nim")
    h.clock = T + 300
    h.call(pr)
    m2, s6 = h.messages[-1], h.status
    at(310, "change", "/x/other/d.nim")
    got = {}
    for l in lines(today):
        got[(l["project"], l["file"])] = got.get((l["project"], l["file"]), 0) + l["secs"]
    check(tag + "pause: written down, nothing counted meanwhile (nor the time to the first thing after it), said in "
          "the status bar; resume",
          m1 == "Time: paused — nothing is counted until you resume" and s5 == "⏸ time paused" and
          m2 == "Time: counting again" and s6 == "⏱ 0 min today" and
          got == {("/x/ned", "src/old.nim"): 600, ("/x/ned", "src/a.nim"): 79, ("/x/ned", "src/b.nim"): 45,
                  ("/x/other", "c.nim"): 15, ("/x/other", "d.nim"): 30}, (m1, s5, m2, s6, got))
    at(320, "change", "/x/other/d.nim")
    at(320, "quit")
    got = {}
    for l in lines(today):
        got[(l["project"], l["file"])] = got.get((l["project"], l["file"]), 0) + l["secs"]
    check(tag + "quitting writes the time not written yet", got.get(("/x/other", "d.nim")) == 40, got)
    h.settings = {"showStatus": False}
    at(330, "tick")
    check(tag + "showStatus off: no item in the status bar", h.status == "", h.status)
    h.settings = {}
    # the report
    monday = today - datetime.timedelta(days=today.weekday())
    if monday != today:
        write(monday, "/x/ned", "src/a.nim", 3600)
    write(today - datetime.timedelta(days=8), "/x/ned", "src/a.nim", 7200)
    write(today, "/y/ned", "x.nim", 120)
    h.call(h.reg("command", title="Time: report")["cb"])
    t = h.tabs[-1] if h.tabs else ("", "", "")
    md = t[1]
    mon = 3600 if monday != today else 0
    dur = lambda s: "%d min" % (s // 60) if s < 3600 else "%d h %d min" % (s // 3600, s // 60 % 60)
    want_days = ["| %s | %s |" % (long_date(monday + datetime.timedelta(days=k)),
                                   dur((mon if k == 0 else 0) + (899 if monday + datetime.timedelta(days=k) == today else 0)))
                 for k in range((today - monday).days + 1)]
    check(tag + "the report: a new tab in Markdown — today by project (two of the same name by their paths)",
          t[0] == "Time report" and t[2] == "markdown" and md.startswith("# Time — %s\n\n## Today: 14 min\n" % long_date(today))
          and "| /x/ned | 12 min |\n| /y/ned | 2 min |\n| other | 0 min |\n" in md, md)
    check(tag + "… this week day by day from Monday (a day of last week, in another month's file maybe, left out)",
          "## This week: %s (from %s)" % (dur(899 + mon), long_date(monday)) in md and
          "\n".join(want_days) in md, (want_days, md))
    check(tag + "… this week by project and by file, the longest first",
          ("| /x/ned | %s |" % dur(724 + mon)) in md and
          ("| src/a.nim (/x/ned) | %s |" % dur(79 + mon)) in md and "| src/old.nim (/x/ned) | 10 min |" in md and
          "| c.nim (other) | 0 min |" in md and md.index("src/old.nim") < md.index("src/b.nim"), md)
