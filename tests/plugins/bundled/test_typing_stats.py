"""typing-stats: what is typed counted from the changes (the cursor's line growing, Enter), not a paste or a move;
the words a minute over the last minutes of typing in the status bar, the days in a row, the days kept in the data
folder, today's summary and the week in a tab, the status bar item off by a setting."""
import json, os, time
from tplugins import check
from tbundled import pos


def run(factory, tag):
    T = 1_800_000_000 - 1_800_000_000 % 86400 + 43200      # (noon, UTC: the day does not change in the test)
    day = lambda t: time.strftime("%Y-%m-%d", time.localtime(t))
    h = factory()
    # (the day before and the one before it written already: a streak of 3 with today; read when first needed)
    data = os.path.join(h.tmp, "data", "typing-stats", "days.json")
    os.makedirs(os.path.dirname(data), exist_ok=True)
    json.dump({day(T - 86400): {"chars": 900, "seconds": 300, "best": 51},
               day(T - 2 * 86400): {"chars": 250, "seconds": 120, "best": 40},
               day(T - 4 * 86400): {"chars": 5000, "seconds": 900, "best": 70}}, open(data, "w"))
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    if not h.pump(lambda j: j.get("t") == "ready", 90):
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    h.clock = T
    ch = h.reg("event", event="change")["cb"]
    ev = {"buf": h.cur, "path": h.path_, "lang": "plaintext"}
    h.call(h.reg("event", event="startup")["cb"], ev)
    st0 = h.status
    check(tag + "at start: the streak so far in the status bar (yesterday and the day before)", st0 == "⌨ 2 days", st0)
    # typing: 20 characters every 4 seconds for a minute = 300 characters a minute = 60 wpm
    h.lines = [""]
    h.cursor = pos(0, 0)
    h.call(ch, ev)                       # (first seen: nothing counted)
    t = T
    for i in range(1, 16):
        t += 4
        h.clock = t
        h.lines = ["x" * (20 * i)]
        h.cursor = pos(0, 20 * i)
        h.call(ch, ev)
    st1 = h.status
    check(tag + "typing: the speed (60 wpm) and the streak, today counted (3 days)", st1 == "⌨ 60 wpm · 3 days", st1)
    # Enter: a new line, then typing on it
    h.clock = t + 2
    h.lines = ["x" * 300, "abcd"]
    h.cursor = pos(1, 4)
    h.call(ch, ev)
    # a paste of many characters, a move, a deletion: not counted
    h.clock = t + 3
    h.lines = ["x" * 300, "abcd" + "p" * 500]
    h.cursor = pos(1, 504)
    h.call(ch, ev)
    h.clock = t + 4
    h.cursor = pos(0, 10)
    h.call(ch, ev)
    h.clock = t + 5
    h.lines = ["x" * 290, "abcd" + "p" * 500]
    h.call(ch, ev)
    # the minute's timer writes the days down
    timers = [r for r in h.regs if r["kind"] == "timer"]
    h.call(timers[-1]["cb"])
    saved = json.load(open(data))
    td = saved.get(day(T), {})
    check(tag + "what was typed: 300 on one line, Enter and 4 on the next (305); not the paste, the move or the "
          "deletion; written to the data folder, the other days kept",
          td.get("chars") == 305 and day(T - 4 * 86400) in saved and 55 <= td.get("best", 0) <= 65, td)
    h.call(h.reg("command", title="Typing: today")["cb"])
    tab = h.tabs[-1] if h.tabs else ("", "", "")
    check(tag + "Typing: today — the words, the time, the best speed and the streak; the week in a Markdown tab",
          h.messages[-1].startswith("⌨ Today 61 words in 1 min, best 60 wpm") and "3 days in a row" in h.messages[-1]
          and tab[0] == "Typing" and "| " + day(T) + " (today) | 61 |" in tab[1] and
          "| " + day(T - 86400) + " | 180 |" in tab[1] and "| " + day(T - 3 * 86400) + " | 0 | — | — |" in tab[1] and
          "Your best speed: **70 wpm**" in tab[1], (h.messages[-1:], tab[1][:600]))
    # five minutes later: no speed, the streak stays; statusBar off: nothing
    h.clock = t + 400
    h.call(timers[-1]["cb"])
    st2 = h.status
    h.settings = {"statusBar": False}
    h.call(timers[-1]["cb"])
    check(tag + "after a while without typing: the streak alone; statusBar off: no item",
          st2 == "⌨ 3 days" and h.status == "", (st2, h.status))
