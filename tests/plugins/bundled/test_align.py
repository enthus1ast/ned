"""align: = : , | and any text in one column — the selection or the paragraph, strings and comments, indentation,
Markdown tables, every one or the first, vim's ga with what it asks"""
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
    cmds = {d: h.reg("command", title="Align: on " + d + (" (table)" if d == "|" else "")) for d in ["=", ":", ",", "|"]}
    askc = h.reg("command", title="Align: on a character or text…")
    ga = h.reg("operator", keys="ga")
    st = h.reg("setting", key="all")
    check(tag + "its commands, vim's ga, the all setting", all(cmds.values()) and askc and ga and st and
          st["default"] is False, h.regs)

    def al(d, lines, l=0, sel=None, lang="nim"):
        h.lang = lang
        h.comment = {"nim": "#", "python": "#", "markdown": ""}.get(lang, "//")
        h.lines = list(lines)
        h.cursor = pos(l, 0)
        h.sel = sel
        r = h.call(cmds[d]["cb"])
        return h.lines if r and "err" not in r else ("error", r)

    check(tag + "on =: the paragraph at the cursor, = with what goes with it (+=) right-aligned, a line without = left",
          al("=", ["a = 1", "long_name = 2", "  # note", "x += 3", "", "zz = 9"], 1) ==
          ["a          = 1", "long_name  = 2", "  # note", "x         += 3", "", "zz = 9"], h.lines)
    check(tag + "an = in a string, or after the line's comment, is not one; == is one",
          al("=", ['s = "a=b"  # c=d', 'name == "x"']) == ['s     = "a=b"  # c=d', 'name == "x"'], h.lines)
    check(tag + "the indentation kept; widths in characters, not bytes (é)",
          al("=", ["  é = 1", "  ab = 2"]) == ["  é  = 1", "  ab = 2"], h.lines)
    check(tag + "the selected lines only (a selection that ends at a line's start leaves that line out)",
          al("=", ["a = 1", "bb = 2", "ccc = 3", "d = 4"], 0, rng(1, 0, 3, 0)) == ["a = 1", "bb  = 2", "ccc = 3", "d = 4"],
          h.lines)
    check(tag + "on :, the colon after the key, the values lined up; a :: or a := is not one",
          al(":", ["name: Ann", "years: 30", "std::io: x", "y := 1"]) ==
          ["name:    Ann", "years:   30", "std::io: x", "y := 1"], h.lines)
    check(tag + "on ,: every comma, the columns of a list",
          al(",", ["a, bb, c", "aaa, b, cc"]) == ["a,   bb, c", "aaa, b,  cc"], h.lines)
    tbl = ["| a | bbb |", "|---|:-:|", "| cc | d |"]
    check(tag + "on | (table): a Markdown table — the |---| line with dashes, its colons kept",
          al("|", tbl, 0, None, "markdown") == ["| a   | bbb |", "| --- | :-: |", "| cc  | d   |"], h.lines)
    check(tag + "fewer than two lines with it: a message, nothing changed",
          al("=", ["a = 1", "b"]) == ["a = 1", "b"] and "fewer than two" in h.messages[-1], h.messages[-1:])
    check(tag + "on a blank line, nothing selected: a message", al("=", ["a = 1", "", "b = 2"], 1) == ["a = 1", "", "b = 2"]
          and "paragraph" in h.messages[-1], h.messages[-1:])
    # what to align on, asked
    h.answers["ask"] = "#"
    h.lines = ["x = 1 # one", "yy = 22 # two"]
    h.cursor = pos(0, 0)
    h.sel = None
    h.comment = "#"
    h.call(askc["cb"])
    check(tag + "on a character or text…: asked (= by default) — # lines up the comments",
          h.lines == ["x = 1   # one", "yy = 22 # two"] and h.asked[-1][1]["default"] == "=", (h.lines, h.asked[-1:]))
    h.answers["ask"] = "*="
    h.lines = ["a = b = c", "aa = bb = cc"]
    h.call(askc["cb"])
    check(tag + "* in front: every one on the line", h.lines == ["a  = b  = c", "aa = bb = cc"], h.lines)
    h.answers["ask"] = "->"
    h.lines = ["a -> 1", "bbb -> 2"]
    h.call(askc["cb"])
    check(tag + "any text: ->", h.lines == ["a   -> 1", "bbb -> 2"], h.lines)
    h.answers["ask"] = ""
    h.lines = ["a = 1", "bb = 2"]
    h.call(askc["cb"])
    check(tag + "cancelled: nothing changes", h.lines == ["a = 1", "bb = 2"], h.lines)
    h.settings = {"all": True}
    check(tag + "the all setting: every = of a line", al("=", ["a = b = c", "aa = bb = cc"]) == ["a  = b  = c", "aa = bb = cc"],
          h.lines)
    h.settings = {}
    # vim: ga with a motion or a text object, then the character
    h.answers["ask"] = ":"
    h.lines = ["k: 1", "key: 2", "other: 3"]
    h.call(ga["cb"], {"buf": 1, "range": rng(0, 0, 1, 6), "linewise": True})
    check(tag + "ga on two lines (gaj), then : — asked, and only those lines", h.lines == ["k:   1", "key: 2", "other: 3"]
          and h.asked[-1][0] == "ask", (h.lines, h.asked[-1:]))
    h.answers["ask"] = "="
    h.lines = ["a = 1", "bb = 2", ""]
    h.call(ga["cb"], {"buf": 1, "range": rng(0, 0, 2, 0), "linewise": False})
    check(tag + "ga with a text object up to a line's start (gaip): the lines before it", h.lines == ["a  = 1", "bb = 2", ""],
          h.lines)
    h.answers["ask"] = "Ann"
    h.lang = "plaintext"
    h.comment = "#"
