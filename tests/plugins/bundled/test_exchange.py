"""exchange: mark a text, then another, and they swap — vim's cx with motions and lines, cxc and cX, visual X, the
palette; the mark shown, a text that changed, overlapping and nested texts, two texts in two files"""
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    mk = h.reg("command", title="Exchange: mark the selection (then again to swap)")
    cl = h.reg("command", title="Exchange: clear")
    cx, cX, vX = h.reg("operator", keys="cx"), h.reg("vimMap", mode="n", keys="cX"), h.reg("vimMap", mode="v", keys="X")
    cxc = h.reg("vimMap", mode="n", keys="cxc")
    check(tag + "its commands, vim's cx operator, cxc and cX, visual X", mk and cl and cx and cxc and cX and vX, h.regs)

    def op(r, linewise=False):
        return h.call(cx["cb"], {"buf": h.cur, "range": r, "linewise": linewise})

    h.lines = ["alpha beta gamma"]
    h.decor = []
    op(rng(0, 0, 0, 5))
    kinds = [d[0] for d in h.decor]
    check(tag + "cx the first time: marked — tinted and ⇄ in the gutter, a message, nothing changed",
          h.lines == ["alpha beta gamma"] and kinds == ["highlight", "sign"] and
          h.decor[0][1]["range"] == rng(0, 0, 0, 5) and h.decor[1][1]["text"] == "⇄" and
          h.messages[-1].startswith("Exchange: marked"), (h.decor, h.messages[-1:]))
    h.calls_seen = []
    op(rng(0, 11, 0, 16))
    check(tag + "cx the second time: the two swap, the mark goes, the cursor where the second one was",
          h.lines == ["gamma beta alpha"] and h.decor == [] and "clearDecorations" in h.calls_seen and
          h.cursor == pos(0, 11), (h.lines, h.decor, h.cursor))
    op(rng(0, 11, 0, 16))
    op(rng(0, 0, 0, 5))
    check(tag + "the later one marked first: the same", h.lines == ["alpha beta gamma"] and h.cursor == pos(0, 0),
          (h.lines, h.cursor))
    h.lines = ["one", "two", "three", "four"]
    op(rng(0, 0, 0, 3), True)
    op(rng(2, 0, 3, 4), True)
    check(tag + "cxx (lines): line 1 with lines 3–4 — a different number of lines", h.lines == ["three", "four", "two", "one"]
          and h.cursor == pos(3, 0), (h.lines, h.cursor))
    h.lines = ["f(a, bb)", "x = 1"]
    op(rng(0, 2, 0, 3))
    op(rng(1, 0, 1, 5))
    check(tag + "a word with a whole other line (lines below move with it)", h.lines == ["f(x = 1, bb)", "a"] and
          h.cursor == pos(1, 0), (h.lines, h.cursor))
    h.lines = ["ab cd"]
    op(rng(0, 0, 0, 2))
    op(rng(0, 0, 0, 2))
    check(tag + "cx again on the marked text: forgotten", "forgotten" in h.messages[-1] and h.decor == [], h.messages[-1:])
    op(rng(0, 3, 0, 5))
    h.lines = ["ab XY"]
    op(rng(0, 0, 0, 2))
    check(tag + "the text marked first changed since: the new one is marked instead (nothing swapped)",
          h.lines == ["ab XY"] and "has changed" in h.messages[-1] and h.decor[-2][1]["range"] == rng(0, 0, 0, 2),
          (h.lines, h.messages[-1:], h.decor))
    h.call(cxc["cb"], {"count": 1})
    check(tag + "cxc forgets it", "forgotten" in h.messages[-1] and h.decor == [], (h.messages[-1:], h.decor))
    op(rng(0, 0, 0, 2))
    h.call(cX["cb"], {"count": 1})
    check(tag + "… and so does cX; with nothing marked, cxc says so", "forgotten" in h.messages[-1] and h.decor == [] and
          h.call(cxc["cb"], {"count": 1}) and h.messages[-1] == "Exchange: nothing is marked", (h.messages[-2:], h.decor))
    h.lines = ["abcdef"]
    op(rng(0, 0, 0, 4))
    op(rng(0, 2, 0, 6))
    check(tag + "two that overlap: a message, the first stays marked", h.lines == ["abcdef"] and "overlap" in h.messages[-1]
          and len(h.decor) == 2, (h.lines, h.messages[-1:]))
    h.call(cl["cb"])
    h.lines = ["f(g(x), y)"]
    op(rng(0, 2, 0, 6))
    op(rng(0, 4, 0, 5))
    check(tag + "one inside the other: the larger replaced by the smaller", h.lines == ["f(x, y)"], h.lines)
    h.call(cl["cb"])
    check(tag + "Exchange: clear with nothing marked: says so", h.messages[-1] == "Exchange: nothing is marked",
          h.messages[-1:])
    # the palette
    h.lines = ["first", "second"]
    h.sel = None
    h.cursor = pos(0, 2)
    h.call(mk["cb"])
    h.cursor = pos(1, 0)
    h.call(mk["cb"])
    check(tag + "the palette without a selection: the cursor's line", h.lines == ["second", "first"], h.lines)
    h.lines = ["a = 1", "b = 22"]
    h.sel = rng(0, 4, 0, 5)
    h.call(mk["cb"])
    h.sel = rng(1, 4, 1, 6)
    h.call(mk["cb"])
    check(tag + "the palette with selections", h.lines == ["a = 22", "b = 1"], h.lines)
    # visual X: the selection as vim shows it (ned gives it with the character under the cursor; V: whole lines)
    h.vim_mode = "visual"
    h.lines = ["foo bar"]
    h.sel = rng(0, 0, 0, 3)
    h.cursor = pos(0, 2)
    h.call(vX["cb"], {"count": 1})
    c1 = h.cursor
    h.sel = rng(0, 4, 0, 7)
    h.cursor = pos(0, 6)
    h.call(vX["cb"], {"count": 1})
    check(tag + "visual X: marks the selection, then swaps — the cursor left alone both times (ned goes back to "
          "normal mode)", h.lines == ["bar foo"] and c1 == pos(0, 2) and h.cursor == pos(0, 6), (h.lines, c1, h.cursor))
    h.vim_mode = "visual line"
    h.lines = ["1", "2", "3", "4"]
    h.sel = rng(0, 0, 1, 1)
    h.call(vX["cb"], {"count": 1})
    h.sel = rng(3, 0, 3, 1)
    h.call(vX["cb"], {"count": 1})
    check(tag + "visual X in visual-line mode: whole lines", h.lines == ["4", "3", "1", "2"], h.lines)
    h.vim_mode = ""
    # two files
    h.sel = None
    h.lines = ["let a = 1"]
    h.path_ = "/p/a.nim"
    h.others = {2: {"lines": ["x", "let b = 22"], "path": "/p/b.nim", "lang": "nim"}}
    op(rng(0, 8, 0, 9))
    h.switch_to(2)
    h.calls_seen = []
    op(rng(1, 8, 1, 10))
    other = h.others[1]["lines"]
    check(tag + "a text in one file with a text in another: both change, the mark in the first file goes",
          h.cur == 2 and h.lines == ["x", "let b = 1"] and other == ["let a = 22"] and h.decor == [] and
          "clearDecorations" in h.calls_seen, (h.lines, other, h.decor))
