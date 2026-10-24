"""pomodoro: a focus session counted down in the status bar (its timer called here, the clock a pretend one: h.clock),
the time by the clock after a sleep, the end — a note, the day's count written, a break by itself (a long one after N)
or not (autoBreak) —, a break's end, stop, a session started again, the settings."""
import json, os, time
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


def run(factory, tag):
    h = start(factory, tag)
    if not h:
        return
    T = 1_800_000_000
    h.clock = T                         # (unixTime and localTime: this pretend clock)

    def setnow(t):
        h.clock = t

    titles = {r["title"] for r in h.regs if r["kind"] == "command"}
    sd = {k: (h.reg("setting", key=k) or {}).get("default")
          for k in ("focusMinutes", "shortBreakMinutes", "longBreakMinutes", "autoBreak", "longBreakEvery")}
    check(tag + "its commands and settings",
          {"Focus: start", "Focus: short break", "Focus: long break", "Focus: stop"} <= titles and
          sd == {"focusMinutes": 25, "shortBreakMinutes": 5, "longBreakMinutes": 15, "autoBreak": True,
                 "longBreakEvery": 4}, (titles, sd))
    cmd = lambda t: h.reg("command", title=t)["cb"]
    timers = lambda: [r for r in h.regs if r["kind"] == "timer"]
    data = os.path.join(h.tmp, "data", "pomodoro", "sessions.json")
    today = time.strftime("%Y-%m-%d", time.localtime(T))
    h.call(cmd("Focus: stop"))
    check(tag + "stop with none running: it says so", h.messages[-1] == "Focus: no session is running", h.messages[-1:])
    # a session: 25:00, a timer once a second, the time left
    h.call(cmd("Focus: start"))
    t = timers()[-1]
    s0 = h.status
    setnow(T + 1)
    h.call(t["cb"])
    check(tag + "start: 25:00 in the status bar, a message, a timer once a second; a second later 24:59",
          s0 == "Focus 25:00" and h.messages[-1] == "Focus for 25 minutes (Focus: stop ends it)" and
          t["ms"] == 1000 and t["repeat"] is True and h.status == "Focus 24:59", (s0, h.messages[-1:], t, h.status))
    setnow(T + 2)
    h.call(t["cb"])
    h.call(cmd("Focus: stop"))
    check(tag + "stop: the timer stopped, the status bar empty, the time that was left",
          t["cb"] in h.stopped and h.status == "" and h.messages[-1] == "Focus: stopped with 24:58 left (not counted)",
          (h.stopped, h.status, h.messages[-1:]))
    # one minute (the settings), the clock jumping ahead (the device slept), the end
    os.makedirs(os.path.dirname(data), exist_ok=True)
    open(data, "w").write(json.dumps({today: 2, "2001-01-01": 9}))
    h.settings = {"focusMinutes": 1, "shortBreakMinutes": 2}
    setnow(T)
    h.call(cmd("Focus: start"))
    t = timers()[-1]
    setnow(T + 4)
    h.call(t["cb"])
    s4 = h.status
    setnow(T + 50)
    h.call(t["cb"])
    s5 = h.status
    check(tag + "focusMinutes; the time by the clock: 50 s gone though the timer was called twice (the device slept)",
          s4 == "Focus 0:56" and s5 == "Focus 0:10", (s4, s5))
    setnow(T + 61)
    h.call(t["cb"])
    saved = json.load(open(data)) if os.path.exists(data) else {}
    b = timers()[-1]
    check(tag + "the end: a note with the day's count (written down, the other days kept), a short break by itself",
          t["cb"] in h.stopped and saved == {today: 3, "2001-01-01": 9} and
          h.messages[-1] == "Focus session done — 3 sessions today. A short break starts now" and
          b["cb"] != t["cb"] and h.status == "Break 2:00", (h.stopped, saved, h.messages[-1:], h.status))
    setnow(T + 62)
    h.call(b["cb"])
    s1 = h.status
    setnow(T + 61 + 125)
    h.call(b["cb"])
    check(tag + "the break counts down, then ends: a note, the status bar empty, its timer stopped",
          s1 == "Break 1:59" and b["cb"] in h.stopped and h.status == "" and
          h.messages[-1] == "The break is over — Focus: start when you are ready", (s1, h.status, h.messages[-1:]))
    # longBreakEvery: the second session of a row ends in a long break; autoBreak off: no break
    h.settings = {"focusMinutes": 1, "longBreakEvery": 2, "longBreakMinutes": 3}
    T2 = T + 1000
    setnow(T2)
    h.call(cmd("Focus: start"))
    t = timers()[-1]
    setnow(T2 + 60)
    h.call(t["cb"])
    check(tag + "longBreakEvery 2: after the second session a long break",
          h.status == "Break 3:00" and h.messages[-1].endswith("A long break starts now"), (h.status, h.messages[-1:]))
    h.call(cmd("Focus: stop"))
    h.settings = {"focusMinutes": 1, "autoBreak": False}
    setnow(T2 + 100)
    h.call(cmd("Focus: start"))
    t = timers()[-1]
    h.call(cmd("Focus: start"))
    again = h.messages[-1]
    t2 = timers()[-1]
    setnow(T2 + 200)
    h.call(t2["cb"])
    check(tag + "start while one runs: started again (the old timer stopped); autoBreak off: no break, the day's "
          "count in the status bar",
          again == "Started again: focus for 1 minute (Focus: stop ends it)" and t["cb"] in h.stopped and
          t2["cb"] in h.stopped and timers()[-1] == t2 and h.status == "Focus: 5 today" and
          h.messages[-1] == "Focus session done — 5 sessions today. Time for a break (Focus: short break)",
          (again, h.status, h.messages[-1:]))
    h.settings = {}
    h.call(cmd("Focus: long break"))
    m = h.messages[-1]
    st = h.status
    h.call(cmd("Focus: short break"))
    check(tag + "the breaks on their own: long, short", m == "A long break of 15 minutes" and st == "Break 15:00" and
          h.messages[-1] == "Started again: a short break of 5 minutes" and h.status == "Break 5:00",
          (m, st, h.messages[-1:], h.status))
    h.call(cmd("Focus: stop"))
