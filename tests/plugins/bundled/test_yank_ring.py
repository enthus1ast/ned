"""yank-ring: what is copied is recorded (the clipboard read after a change, at a tab switch, while text is selected and
just after, before the history is shown), the history newest first, each on one line; a copy pasted from it, a paste
(this plugin's or Ctrl+V's) swapped for the copy before it, round the ring; the size, kept on disk or not, cleared"""
import json
import os
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    titles = ["Yank ring: paste from history…", "Yank ring: paste the one before", "Yank ring: clear the history"]
    c = {t: h.reg("command", title=t) for t in titles}
    timer = h.reg("timer")
    change, enter = h.reg("event", event="change"), h.reg("event", event="enter")
    check(tag + "its commands (Ctrl+Alt+V, Alt+Shift+Y), <leader>p, a timer of a second, the change and enter " +
          "events, its settings", all(c.values()) and c["Yank ring: paste from history…"]["keys"] == "ctrl+alt+v" and
          c["Yank ring: paste the one before"]["keys"] == "alt+shift+y" and h.reg("vimMap", mode="n", keys="<leader>p")
          and timer and timer["ms"] == 1000 and timer["repeat"] and change and enter and
          h.reg("setting", key="size")["default"] == 30 and h.reg("setting", key="keepOnDisk")["default"] is False,
          [t for t, v in c.items() if not v])
    src = open(os.path.join(os.path.dirname(__file__), "..", "..", "..", "plugins", "yank-ring", "plugin.nims")).read()
    check(tag + "it asks for the clipboard, saying why", 'permission("clipboard", "' in src, "")

    def run_(t):
        r = h.call(c[t]["cb"])
        return r and "err" not in r

    def history():
        h.answers["pick"] = -1
        run_("Yank ring: paste from history…")
        a = h.asked[-1][1]
        return a["items"]

    ev = {"buf": 1, "path": h.path_, "lang": "plaintext"}
    h.lines = ["one two three"]
    h.cursor = pos(0, 0)
    h.clip = "alpha"
    h.call(change["cb"], ev)
    h.clip = "beta"
    h.call(enter["cb"], ev)
    h.clip = "gamma"
    h.sel = {"start": pos(0, 0), "stop": pos(0, 3)}
    h.call(timer["cb"])
    h.clip = "delta"
    h.sel = None
    h.call(timer["cb"])                         # (just after a selection: still looked at)
    h.clip = "missed"
    h.call(timer["cb"])                         # (no selection now or before: not read)
    h.clip = "eps"
    items = history()
    check(tag + "copies recorded: after a change, at a tab switch, while text is selected and just after, before " +
          "the list — not on a timer with nothing selected", items == ["eps", "delta", "gamma", "beta", "alpha"], items)
    check(tag + "… the list's title, each entry's size beside it", h.asked[-1][1]["title"] ==
          "Paste from history — 5 copies, newest first" and h.asked[-1][1]["details"][0] == "1 line · 3 characters",
          h.asked[-1][1])
    h.clip = "  def f():\n\tpass\n    return 1\n"
    h.call(change["cb"], ev)
    h.clip = "gamma"
    h.call(change["cb"], ev)
    h.clip = "   \n"
    h.call(change["cb"], ev)
    h.clip = "x" * 100001
    h.call(change["cb"], ev)
    items = history()
    a = h.asked[-1][1]
    check(tag + "… on one line (⏎ between lines, no indentation); a copy already there moves to the top; empty " +
          "and very big ones are not kept", items == ["gamma", "def f(): ⏎ pass ⏎ return 1", "eps", "delta", "beta",
                                                      "alpha"] and a["details"][1] == "3 lines · 30 characters",
          (items, a["details"][:2]))
    # paste from history
    h.lines = ["say  now"]
    h.cursor = pos(0, 4)
    h.answers["pick"] = 2
    run_("Yank ring: paste from history…")
    check(tag + "paste from history: the one chosen at the cursor, the cursor after it",
          h.lines == ["say eps now"] and h.cursor == pos(0, 7), (h.lines, h.cursor))
    # swap for the one before, round the ring
    run_("Yank ring: paste the one before")
    l1, m1 = list(h.lines), h.messages[-1]
    run_("Yank ring: paste the one before")
    l2 = list(h.lines)
    run_("Yank ring: paste the one before")
    run_("Yank ring: paste the one before")
    l3 = list(h.lines)
    check(tag + "paste the one before: the pasted text swapped for the copy before it, again and again, round the ring",
          l1 == ["say delta now"] and m1 == "Yank ring: 4 of 6 — delta" and l2 == ["say beta now"] and
          l3 == ["say gamma now"] and h.cursor == pos(0, 9), (l1, m1, l2, l3, h.cursor))
    run_("Yank ring: paste the one before")
    check(tag + "… a copy of several lines in, and out again", h.lines == ["say   def f():", "\tpass", "    return 1", " now"]
          and h.cursor == pos(3, 0), (h.lines, h.cursor))
    run_("Yank ring: paste the one before")
    check(tag + "… (the lines put back as one)", h.lines == ["say eps now"], h.lines)
    h.cursor = pos(0, 0)
    run_("Yank ring: paste the one before")
    check(tag + "… the cursor elsewhere: paste first, it says", h.lines == ["say eps now"] and
          h.messages[-1].startswith("Yank ring: paste first"), h.messages[-1:])
    # after Ctrl+V: the text before the cursor is the newest copy
    h.clip = "pasted"
    h.lines = ["x = pasted"]
    h.cursor = pos(0, 10)
    h.call(change["cb"], ev)
    run_("Yank ring: paste the one before")
    check(tag + "… right after Ctrl+V (the newest copy before the cursor): swapped for the one before it",
          h.lines == ["x = gamma"], h.lines)
    h.clip = "a\nb"
    h.lines = ["(a", "b)"]
    h.cursor = pos(1, 1)
    run_("Yank ring: paste the one before")
    check(tag + "… Ctrl+V of several lines too", h.lines == ["(pasted)"], h.lines)
    # the size setting
    h.settings["size"] = 3
    h.clip = "new one"
    h.call(change["cb"], ev)
    items = history()
    check(tag + "the size setting: 3 kept", items == ["new one", "a ⏎ b", "pasted"], items)
    h.settings = {}
    # in memory only, unless keepOnDisk
    data = os.path.join(h.tmp, "data", "yank-ring", "ring.json")
    check(tag + "keepOnDisk off: nothing written to disk", not os.path.exists(data), data)
    h.settings["keepOnDisk"] = True
    h.clip = "kept"
    h.call(change["cb"], ev)
    saved = json.load(open(data))["ring"] if os.path.exists(data) else None
    check(tag + "keepOnDisk on: the history in the data folder", saved == ["kept", "new one", "a\nb", "pasted"], saved)
    h2 = factory()
    ok2 = h2.build_ok and h2.pump(lambda j: j.get("t") == "ready", 60)
    if ok2:
        h2.tmp = h.tmp
        h2.settings["keepOnDisk"] = True
        h2.clip = "kept"
        h2.answers["pick"] = -1
        h2.call(h2.reg("command", title="Yank ring: paste from history…")["cb"])
        it2 = h2.asked[-1][1]["items"] if h2.asked else []
        check(tag + "… read again at the next start", it2 == ["kept", "new one", "a ⏎ b", "pasted"], it2)
    run_("Yank ring: clear the history")
    run_("Yank ring: paste from history…")
    check(tag + "clear the history: empty (on disk too); the clipboard as it is is not taken again",
          h.messages[-1] == "Yank ring: nothing copied yet" and json.load(open(data))["ring"] == [], h.messages[-2:])
    h.call(h.reg("vimMap", mode="n", keys="<leader>p")["cb"], {"count": 1})
    check(tag + "<leader>p: the history", h.messages[-1] == "Yank ring: nothing copied yet", h.messages[-1:])
    h.clip = "é" * 150
    h.call(change["cb"], ev)
    items = history()
    check(tag + "a long copy is cut at 100 characters (not in the middle of one)", items == ["é" * 100 + "…"] and
          h.asked[-1][1]["details"] == ["1 line · 150 characters"], (items, h.asked[-1][1]["details"]))
