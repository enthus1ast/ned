"""log-tail: a log's lines told apart (errors, warnings, debug — as words, not inside others) and coloured a run at a
time; following a file — new lines coloured, the cursor to the end, a shorter file coloured again, its tab closed —
and stopping; only the lines with some words in a tab of their own; the words set by settings."""
from tplugins import check
from tbundled import pos

LOG = ["2026-11-01 10:00:01 INFO started", "2026-11-01 10:00:02 DEBUG config read", "2026-11-01 10:00:03 debug more",
       "2026-11-01 10:00:04 WARNING disk 91% full", "2026-11-01 10:00:05 ERROR could not open db",
       "Traceback (most recent call last):", "2026-11-01 10:00:06 INFO terrible weather, no error words here? no",
       "2026-11-01 10:00:07 INFO done"]


def hl(h):
    return [(a["range"]["start"]["line"], a["range"]["stop"]["line"], a["color"]) for k, a in h.decor
            if k == "highlight"]


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    if not h.pump(lambda j: j.get("t") == "ready", 90):
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    h.path_ = h.tmp + "/app.log"
    h.lines = LOG[:6]
    h.call(h.reg("command", title="Log: colour this file")["cb"])
    check(tag + "coloured: debug lines dim (a run of two), the warning, the error and the traceback (a run of two)",
          sorted(hl(h)) == [(1, 2, "hint"), (3, 3, "warn"), (4, 5, "error")], hl(h))
    follow = h.reg("command", title="Log: follow this file")["cb"]
    h.decor = []
    h.call(follow)
    timers = [r for r in h.regs if r["kind"] == "timer"]
    t = timers[-1]
    check(tag + "follow: coloured, the cursor on the last line, ⇣ in the status bar, a timer once a second",
          len(hl(h)) == 3 and h.cursor == pos(5, 0) and h.status == "⇣ app.log" and t["ms"] == 1000 and t["repeat"],
          (hl(h), h.cursor, h.status, t))
    h.lines = LOG                      # (two more lines, as ned reloads it)
    h.call(t["cb"])
    new = [x for x in hl(h) if x[1] >= 6]          # (the last line before is coloured again: it may have grown)
    check(tag + "new lines coloured — \"error\" as a word of its own: red; the last, ordinary, not — and the cursor "
          "follows", h.cursor == pos(7, 0) and new == [(5, 6, "error")], (h.cursor, hl(h)))
    h.lines = ["2026-11-01 11:00:00 WARN rotated"]
    h.call(t["cb"])
    check(tag + "a shorter file (rotated): cleared and coloured again from the start",
          "clearDecorations" in h.calls_seen and hl(h) == [(0, 0, "warn")], hl(h))
    h.call(follow)
    check(tag + "again: not following, the timer stopped", t["cb"] in h.stopped and h.status == "" and
          h.messages[-1] == "Log: not following app.log any more", (h.stopped, h.status, h.messages[-1:]))
    # only the lines with …
    h.lines = LOG
    h.answers["ask"] = "ERROR|disk"
    h.decor = []
    h.call(h.reg("command", title="Log: only the lines with…")["cb"])
    tab = h.tabs[-1] if h.tabs else ("", "", "")
    check(tag + "only the lines with words (any case, | between): in a tab of their own, coloured",
          tab[0] == "log: ERROR|disk" and tab[1].split("\n") == [LOG[3], LOG[4], LOG[6]] and
          h.messages[-1] == "Log: 3 lines with ERROR|disk" and sorted(hl(h)) == [(0, 0, "warn"), (1, 2, "error")],
          (tab, h.messages[-1:], hl(h)))
    h.answers["ask"] = "nothing-like-this"
    h.call(h.reg("command", title="Log: only the lines with…")["cb"])
    check(tag + "no line has it: it says so", h.messages[-1] == "Log: no line has nothing-like-this", h.messages[-1:])
    h.settings = {"errorWords": "boom", "warnWords": "", "debugWords": ""}
    h.decor = []
    h.lines = ["x boom y", "error here"]
    h.call(h.reg("command", title="Log: colour this file")["cb"])
    check(tag + "the words are settings", hl(h) == [(0, 0, "error")], hl(h))
