"""power-mode: off at start; on, typing grows the combo in the status bar, sparks after the line (cleared a moment
later), a cheer at 50; a paste or another line counts nothing; three seconds without typing end the combo, the best
kept; off again clears it all; onAtStart, and sparks off."""
from tplugins import check
from tbundled import pos


def start(factory, tag, settings=None):
    h = factory()
    if settings: h.settings = settings
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return None
    if not h.pump(lambda j: j.get("t") == "ready", 90):
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
    h.clock = T
    ev = {"buf": h.cur, "path": h.path_, "lang": "plaintext"}
    ch = h.reg("event", event="change")["cb"]
    toggle = h.reg("command", title="Power mode: on/off")["cb"]
    h.call(h.reg("event", event="startup")["cb"], ev)
    h.lines = ["ab"]
    h.cursor = pos(0, 2)
    h.call(ch, ev)
    check(tag + "off at start: typing shows nothing", h.status == "" and not h.decor, (h.status, h.decor))
    h.call(toggle)
    check(tag + "on: it says so", h.messages[-1] == "⚡ Power mode on — type!", h.messages[-1:])
    h.call(ch, ev)                         # (first seen)
    for i in range(1, 6):
        h.clock = T + i
        h.lines = ["ab" + "x" * (10 * i)]
        h.cursor = pos(0, 2 + 10 * i)
        h.call(ch, ev)
    st = h.status
    sparks = [a for k, a in h.decor if k == "vtext"]
    cheer = [m for m in h.messages if m.startswith("⚡ 50 combo")]
    check(tag + "typing: the combo in the status bar, sparks after the line, a cheer at 50",
          st == "⚡ combo 50" and sparks and sparks[-1].get("line") == 0 and len(cheer) == 1 and
          cheer[0] == "⚡ 50 combo — Nice!", (st, sparks[-1:], cheer))
    timers = [r for r in h.regs if r["kind"] == "timer"]
    once = [r for r in timers if not r.get("repeat")]
    h.call(once[-1]["cb"])
    check(tag + "the sparks go a moment later", "clearDecorations" in h.calls_seen, h.calls_seen[-3:])
    h.clock = T + 6
    h.lines = ["ab" + "x" * 50 + "p" * 600]
    h.cursor = pos(0, 652)
    h.call(ch, ev)
    h.cursor = pos(3, 0)
    h.lines = ["a", "b", "c", "d"]
    h.call(ch, ev)
    check(tag + "a paste, a jump to another line: not counted", h.status == "⚡ combo 50", h.status)
    tick = [r for r in timers if r.get("repeat")][-1]
    h.clock = T + 8
    h.call(tick["cb"])
    s1 = h.status
    h.clock = T + 10
    h.call(tick["cb"])
    best = open(__import__("os").path.join(h.tmp, "data", "power-mode", "best.txt")).read()
    check(tag + "three seconds without typing end the combo, the best kept", s1 == "⚡ combo 50" and h.status == "" and
          best == "50", (s1, h.status, best))
    h.call(toggle)
    check(tag + "off: it says so, the timer stopped", h.messages[-1] == "Power mode off" and tick["cb"] in h.stopped,
          (h.messages[-1:], h.stopped))
    h.call(toggle)
    check(tag + "on again: the best combo said", h.messages[-1] == "⚡ Power mode on — type! (best combo: 50)",
          h.messages[-1:])
    # onAtStart, sparks off
    h2 = start(factory, tag + "onAtStart: ", {"onAtStart": True, "sparks": False})
    if not h2:
        return
    ev2 = {"buf": h2.cur, "path": h2.path_, "lang": "plaintext"}
    h2.call(h2.reg("event", event="startup")["cb"], ev2)
    ch2 = h2.reg("event", event="change")["cb"]
    h2.lines = [""]
    h2.cursor = pos(0, 0)
    h2.call(ch2, ev2)
    h2.lines = ["hello"]
    h2.cursor = pos(0, 5)
    h2.call(ch2, ev2)
    check(tag + "onAtStart: on from the start; sparks off: the combo alone",
          h2.status == "⚡ combo 5" and not [1 for k, a in h2.decor if k == "vtext"], (h2.status, h2.decor))
