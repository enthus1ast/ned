"""nim-tips: a tip at start once a day (not again the same day, not when atStart is off), the next one on asking, in
order and round again, where it is kept in the data folder, and all of them in a Markdown tab."""
import json, os
from tplugins import check


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
    titles = {r["title"] for r in h.regs if r["kind"] == "command"}
    check(tag + "its commands", {"Nim tip: another one", "Nim tip: all of them"} <= titles, titles)
    st = h.reg("event", event="startup")
    h.call(st["cb"], {"buf": 1, "path": "", "lang": ""})
    first = h.messages[-2] if len(h.messages) >= 2 else ""        # (the note; then the status line's)
    n0 = len(h.messages)
    h.call(st["cb"], {"buf": 1, "path": "", "lang": ""})
    check(tag + "at start: tip 1 in a note (its Markdown left out); not again the same day",
          first.startswith("Nim tip 1/") and "`" not in first and len(h.messages) == n0, (first, h.messages[-3:]))
    total = int(first.split("/")[1].split(":")[0])
    another = h.reg("command", title="Nim tip: another one")["cb"]
    h.call(another)
    second = [m for m in h.messages if m.startswith("Nim tip 2/")]
    data = os.path.join(h.tmp, "data", "nim-tips", "state.json")
    kept = json.load(open(data)) if os.path.exists(data) else {}
    check(tag + "another one: the next tip, in a note and in the status line; where it is kept in the data folder",
          second and h.messages[-1].startswith("Nim tip: ") and kept.get("next") == 2, (h.messages[-3:], kept))
    for _ in range(total - 2): h.call(another)
    h.call(another)
    check(tag + "round again after the last (%d tips)" % total, total >= 40 and
          any(m.startswith("Nim tip 1/") for m in h.messages[-2:]), h.messages[-2:])
    h.call(h.reg("command", title="Nim tip: all of them")["cb"])
    t = h.tabs[-1] if h.tabs else ("", "", "")
    check(tag + "all of them: a Markdown tab, every tip numbered",
          t[0] == "Nim tips" and t[2] == "markdown" and ("%d. " % total) in t[1], t[:1] + (t[1][-200:],) + t[2:])
    # the next day: a tip at start again; atStart off: none
    h.clock = T + 86400 * 2
    n1 = len(h.messages)
    h.settings = {"atStart": False}
    h.call(st["cb"], {"buf": 1, "path": "", "lang": ""})
    off = len(h.messages) == n1
    h.settings = {}
    h.call(st["cb"], {"buf": 1, "path": "", "lang": ""})
    check(tag + "another day: a tip at start again; plugins.nim-tips.atStart false: none",
          off and len(h.messages) > n1 and h.messages[-2].startswith("Nim tip "), (off, h.messages[-2:]))
