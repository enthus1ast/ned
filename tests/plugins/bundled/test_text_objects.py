"""text-objects: ia aa (an argument), ii ai aI (an indentation level, as whole lines), iq aq (any quotes), il al (the
line), ie ae (the whole text), i_ a_ (a part of a name) — the ranges they give, the tricky places; ip ap are ned's"""
from tplugins import check

NONE = {"start": {"line": -1, "col": 0}, "stop": {"line": -1, "col": 0}}


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
    keys = ["ia", "aa", "ii", "iI", "ai", "aI", "iq", "aq", "il", "al", "ie", "ae", "i_", "a_"]
    objs = {k: h.reg("textObject", keys=k) for k in keys}
    mine = {r["keys"] for r in h.regs if r["kind"] == "textObject"}
    vims = {"iw", "aw", "iW", "aW", "ib", "ab", "iB", "aB", "i(", "a(", "i[", "a[", "i{", "a{", "i<", "a<", 'i"', 'a"',
            "i'", "a'", "i`", "a`", "ip", "ap"}
    check(tag + "its text objects, none that ned's vim has already (ip ap are ned's own now)",
          all(objs.values()) and not (mine & vims),
          (sorted(mine), [k for k, v in objs.items() if not v]))

    def to(k, lines, l, c, lang="nim"):
        """the range a text object gives, and its text"""
        h.lang = lang
        h.comment = {"nim": "#", "python": "#"}.get(lang, "//")
        h.lines = list(lines)
        r = h.call(objs[k]["cb"], {"buf": 1, "pos": pos(l, c)})
        v = (r or {}).get("value")
        if not v or v == NONE or "err" in (r or {}):
            return (v, None) if "err" not in (r or {}) else ("error", r)
        return v, text(v)

    def text(v):
        s, e = v["start"], v["stop"]
        if s["line"] == e["line"]:
            return h.lines[s["line"]][s["col"]:e["col"]]
        return "\n".join([h.lines[s["line"]][s["col"]:]] + h.lines[s["line"] + 1:e["line"]] +
                         [h.lines[e["line"]][:e["col"]]])

    def t(k, lines, l, c, lang="nim"):
        return to(k, lines, l, c, lang)[1]

    # ia aa
    call = ['f(a, g(1, 2), "x, y")']
    check(tag + "ia: the argument at the cursor — inner brackets and a string with a comma are one",
          t("ia", call, 0, 2) == "a" and t("ia", call, 0, 5) == "g(1, 2)" and t("ia", call, 0, 16) == '"x, y"',
          [t("ia", call, 0, c) for c in (2, 5, 16)])
    check(tag + "ia inside an inner call: its argument; on a comma: the one before it; on the space after: the next",
          t("ia", call, 0, 10) == "2" and t("ia", call, 0, 3) == "a" and t("ia", call, 0, 4) == "g(1, 2)",
          [t("ia", call, 0, c) for c in (10, 3, 4)])
    check(tag + "aa: the argument and the comma after it (the spaces to the next one)",
          t("aa", call, 0, 2) == "a, " and t("aa", call, 0, 5) == "g(1, 2), ", [t("aa", call, 0, c) for c in (2, 5)])
    check(tag + "aa on the last argument: the comma before it", t("aa", call, 0, 16) == ', "x, y"', t("aa", call, 0, 16))
    check(tag + "aa on the only one: it alone, or with its comma (a tuple of one)",
          t("aa", ["f(x)"], 0, 2) == "x" and t("aa", ["t = (x,)"], 0, 5) == "x,", (t("aa", ["f(x)"], 0, 2),))
    check(tag + "[ ] and { } too: @[1, 2], {\"a\": 1, \"b\": 2}",
          t("ia", ["s = @[1, 22]"], 0, 9) == "22" and t("aa", ['{"a": 1, "b": 2}'], 0, 3) == '"a": 1, ',
          (t("ia", ["s = @[1, 22]"], 0, 9), t("aa", ['{"a": 1, "b": 2}'], 0, 3)))
    ml = ["foo(", "  first,", "  second(x),", "  third,", ")"]
    check(tag + "over several lines: ia on a line, aa up to the next one, aa on the last takes the comma before",
          t("ia", ml, 2, 4) == "second(x)" and t("aa", ml, 1, 3) == "first,\n  " and t("aa", ml, 3, 3) == ",\n  third",
          [t("ia", ml, 2, 4), t("aa", ml, 1, 3), t("aa", ml, 3, 3)])
    check(tag + "Nim's pragma {.inline, raises: [].}: an argument without the dots",
          t("ia", ["proc f() {.inline, raises: [].} ="], 0, 12) == "inline" and
          t("aa", ["proc f() {.inline, raises: [].} ="], 0, 22) == ", raises: []",
          (t("ia", ["proc f() {.inline, raises: [].} ="], 0, 12), t("aa", ["proc f() {.inline, raises: [].} ="], 0, 22)))
    check(tag + "on the opening bracket: the first argument, on the closing one: the last",
          t("ia", ["f(a, b)"], 0, 1) == "a" and t("ia", ["f(a, b)"], 0, 6) == "b", (t("ia", ["f(a, b)"], 0, 6),))
    check(tag + "no argument: empty brackets, or none around", to("ia", ["f()"], 0, 2)[1] is None and
          to("ia", ["x = 1"], 0, 2)[1] is None, (to("ia", ["f()"], 0, 2), to("ia", ["x = 1"], 0, 2)))
    check(tag + "a bracket in a comment or a string is not one: f(a, \")\") # (",
          t("ia", ['f(a, ")") # (b'], 0, 5) == '")"', t("ia", ['f(a, ")") # (b'], 0, 5))
    # ii ai aI: whole lines — from a line's start to the next one's (ned takes that as lines)
    py = ["def f(x):", "    if x:", "        a = 1", "", "        b = 2", "    return a", "", "y = 3"]
    check(tag + "ii: the lines indented as much as the cursor's or more, blank lines inside them too — whole lines",
          to("ii", py, 2, 8) == (rng(2, 0, 5, 0), "        a = 1\n\n        b = 2\n"), to("ii", py, 2, 8))
    check(tag + "ii on a blank line inside: the same; on the function's body: all of it",
          to("ii", py, 3, 0)[0] == rng(2, 0, 5, 0) and to("ii", py, 5, 4)[0] == rng(1, 0, 6, 0),
          (to("ii", py, 3, 0), to("ii", py, 5, 4)))
    check(tag + "ai: with the line above (the if); iI is ii", to("ai", py, 2, 8)[0] == rng(1, 0, 5, 0) and
          to("iI", py, 2, 8)[0] == rng(2, 0, 5, 0), (to("ai", py, 2, 8),))
    js = ["function f() {", "  if (x) {", "    a();", "  }", "}"]
    check(tag + "aI: with the line below too (a closing })", to("aI", js, 2, 4)[0] == rng(1, 0, 4, 0) and
          to("ai", js, 2, 4)[0] == rng(1, 0, 3, 0), (to("aI", js, 2, 4), to("ai", js, 2, 4)))
    check(tag + "at the top level: the paragraph; at the end of the file: to the end of its last line",
          to("ii", py, 7, 0)[0] == rng(7, 0, 7, 5) and to("ii", ["a", "b", "", "c"], 0, 0)[0] == rng(0, 0, 2, 0) and
          to("ii", ["x:", "  y", "  z"], 1, 2)[0] == rng(1, 0, 2, 3), (to("ii", py, 7, 0), to("ii", ["x:", "  y", "  z"], 1, 2)))
    # iq aq
    q = ['say("it\'s", \'x\', `y`)']
    check(tag + "iq: the quotes around the cursor of any kind — the ' inside \"it's\" is not one",
          t("iq", q, 0, 6, "python") == "it's" and t("iq", q, 0, 13, "python") == "x" and
          t("iq", q, 0, 18, "python") == "y", [t("iq", q, 0, c, "python") for c in (6, 13, 18)])
    check(tag + "aq: with the quotes; before any: the next ones; after all: the last ones",
          t("aq", q, 0, 6, "python") == '"it\'s"' and t("iq", q, 0, 0, "python") == "it's" and
          t("iq", ['a "b" c'], 0, 6) == "b", (t("aq", q, 0, 6, "python"), t("iq", q, 0, 0, "python")))
    check(tag + "an escaped quote does not end it; Nim: a character 'a' is quotes, a ' with no pair is not",
          t("iq", ['x = "a\\"b" & \'c\''], 0, 6) == 'a\\"b' and t("iq", ['x = "a\\"b" & \'c\''], 0, 14) == "c" and
          t("iq", ["x = 100'i32 & \"s\""], 0, 4) == "s",
          (t("iq", ['x = "a\\"b" & \'c\''], 0, 6), t("iq", ["x = 100'i32 & \"s\""], 0, 4)))
    check(tag + "no quotes on the line: none", to("iq", ["x = 1"], 0, 0)[1] is None, to("iq", ["x = 1"], 0, 0))
    # il al ie ae
    check(tag + "il: the line without its indentation and its spaces at the end; al: all of it; a blank line: none",
          t("il", ["    x = 1  "], 0, 0) == "x = 1" and t("al", ["    x = 1  "], 0, 0) == "    x = 1  " and
          to("il", ["   "], 0, 0)[1] is None, (t("il", ["    x = 1  "], 0, 0),))
    whole = ["", "a", "b", "", ""]
    check(tag + "ae: the whole text; ie: its lines without the blank ones at the start and the end",
          to("ae", whole, 1, 0)[0] == rng(0, 0, 4, 0) and to("ie", whole, 1, 0)[0] == rng(1, 0, 3, 0),
          (to("ae", whole, 1, 0), to("ie", whole, 1, 0)))
    # i_ a_
    check(tag + "i_: a word of snake_case, a hump of camelCase (HTTPServer: HTTP, Server)",
          t("i_", ["max_line_len"], 0, 5) == "line" and t("i_", ["getHTTPServer"], 0, 4) == "HTTP" and
          t("i_", ["getHTTPServer"], 0, 9) == "Server" and t("i_", ["utf8String"], 0, 1) == "utf8",
          [t("i_", ["getHTTPServer"], 0, c) for c in (0, 4, 9)])
    check(tag + "a_: with the _ after it, or for the last word the one before; a hump has none",
          t("a_", ["max_line_len"], 0, 5) == "line_" and t("a_", ["max_line_len"], 0, 10) == "_len" and
          t("a_", ["fooBar"], 0, 4) == "Bar", [t("a_", ["max_line_len"], 0, c) for c in (5, 10)])
    check(tag + "i_ on an underscore: the word after it; not on a name: none",
          t("i_", ["max_line"], 0, 3) == "line" and to("i_", ["a + b"], 0, 2)[1] is None, t("i_", ["max_line"], 0, 3))
    h.lang = "plaintext"
    h.comment = "#"
