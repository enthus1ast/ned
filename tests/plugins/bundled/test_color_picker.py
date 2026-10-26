"""color-picker: the colour at the cursor converted (#rrggbb → rgb() → hsl() → #rrggbb, alpha too; Nim's 0xRRGGBB ⇄
rgb(); a name → its value), made lighter and darker (the form kept), and a named colour picked — replacing the one at
the cursor in its form, or in the form the file uses most"""
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


NAMES = {"tomato": "#ff6347", "aliceblue": "#f0f8ff", "rebeccapurple": "#663399", "darkorange": "#ff8c00",
         "gray": "#808080", "grey": "#808080"}


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    titles = ["Colour: convert", "Colour: pick…", "Colour: lighter", "Colour: darker"]
    c = {t: h.reg("command", title=t) for t in titles}
    check(tag + "its commands and the step setting", all(c.values()) and h.reg("setting", key="step")["default"] == 5,
          [t for t, v in c.items() if not v])

    def do(t, line, col, lang="css"):
        h.lines = [line]
        h.lang = lang
        h.cursor = pos(0, col)
        h.sel = None
        r = h.call(c[t]["cb"])
        return h.lines[0] if r and "err" not in r else ("ERR", r)

    def cycle(line, col, lang="css", n=3):
        out = []
        for _ in range(n):
            out.append(do("Colour: convert", line, col, lang))
            line = out[-1]
        return out

    check(tag + "convert: #rrggbb → rgb() → hsl() → #rrggbb, the cursor at its start",
          cycle("  color: #ff6347;", 10) == ["  color: rgb(255, 99, 71);", "  color: hsl(9.1, 100%, 63.9%);",
                                             "  color: #ff6347;"] and h.cursor == pos(0, 9), (h.lines, h.cursor))
    check(tag + "… with alpha: #rrggbbaa → rgba() → hsla() → #rrggbbaa",
          cycle("a: #ff634780", 4) == ["a: rgba(255, 99, 71, 0.5)", "a: hsla(9.1, 100%, 63.9%, 0.5)", "a: #ff634780"],
          h.lines)
    check(tag + "… the modern syntax kept: rgb(r g b / a) → hsl(h s% l% / a)",
          cycle("x rgb(255 99 71 / 50%) y", 3, n=2) == ["x hsl(9.1 100% 63.9% / 0.5) y", "x #ff634780 y"], h.lines)
    check(tag + "… the cursor right after the colour: that one", do("Colour: convert", "#000", 4) == "rgb(0, 0, 0)",
          h.lines)
    check(tag + "… a name (CSS) becomes rgb()", do("Colour: convert", "color: tomato;", 9) == "color: rgb(255, 99, 71);"
          and h.messages[-1] == "Colour: tomato → rgb(255, 99, 71)", (h.lines, h.messages[-1:]))
    check(tag + "… a name in a string of another language; not outside one",
          do("Colour: convert", 'c = "tomato"', 6, "python") == 'c = "rgb(255, 99, 71)"' and
          do("Colour: convert", "tomato = 1", 2, "python") == "tomato = 1" and "no colour at the cursor" in h.messages[-1],
          (h.lines, h.messages[-1:]))
    check(tag + "… Nim: 0xRRGGBB → rgb(r, g, b) → 0xRRGGBB; colTomato → 0xFF6347",
          cycle("let c = 0xFF6347", 10, "nim", 2) == ["let c = rgb(255, 99, 71)", "let c = 0xFF6347"] and
          do("Colour: convert", "let c = colTomato", 9, "nim") == "let c = 0xFF6347", h.lines)
    check(tag + "… Nim: a colour in a string is CSS's: #ff6347 → rgb() → hsl()",
          cycle('style = "color: #ff6347"', 17, "nim", 2) == ['style = "color: rgb(255, 99, 71)"',
                                                             'style = "color: hsl(9.1, 100%, 63.9%)"'], h.lines)
    check(tag + "… 0xRRGGBB in another language: no other form, said", do("Colour: convert", "C = 0xFF6347", 5, "python")
          == "C = 0xFF6347" and "no other form in a python file" in h.messages[-1], h.messages[-1:])
    check(tag + "… no colour at the cursor: said", do("Colour: convert", "a: b;", 1) == "a: b;" and
          "no colour at the cursor" in h.messages[-1], h.messages[-1:])
    # every named colour goes round and back
    bad = []
    for name in ["aliceblue", "antiquewhite", "chartreuse", "darkgoldenrod", "darkolivegreen", "darkslateblue",
                 "firebrick", "goldenrod", "indianred", "lightgoldenrodyellow", "mediumaquamarine",
                 "mediumvioletred", "navajowhite", "olivedrab", "palevioletred", "peru", "rebeccapurple", "rosybrown",
                 "saddlebrown", "seagreen", "sienna", "slategray", "steelblue", "thistle", "tomato", "wheat",
                 "yellowgreen", "lavenderblush", "darkcyan", "orchid"]:
        out = cycle(name, 1, n=3)
        if not out[-1].startswith("#") or cycle(out[-1], 1, n=3)[-1] != out[-1]:
            bad.append((name, out))
    check(tag + "… thirty named colours: hex → rgb → hsl → hex comes back the same", not bad, bad[:3])
    # lighter, darker
    check(tag + "lighter / darker: 5 % of lightness, the form kept",
          do("Colour: lighter", "#808080", 0) == "#8d8d8d" and do("Colour: darker", "#808080", 0) == "#737373" and
          do("Colour: lighter", "hsl(120, 50%, 50%)", 0) == "hsl(120, 50%, 55%)" and
          do("Colour: darker", "rgb(128, 128, 128)", 0) == "rgb(115, 115, 115)", h.lines)
    check(tag + "… capitals kept; alpha kept; white stays white; #rgb long when it must be",
          do("Colour: darker", "#FFFFFF", 0) == "#F2F2F2" and do("Colour: lighter", "#000", 0) == "#0d0d0d" and
          do("Colour: lighter", "#80808080", 0) == "#8d8d8d80" and do("Colour: lighter", "#fff", 0) == "#fff", h.lines)
    check(tag + "… a name becomes #rrggbb (Nim's colName 0xRRGGBB)", do("Colour: lighter", "gray", 0) == "#8d8d8d" and
          do("Colour: darker", "colGray", 0, "nim") == "0x737373" and do("Colour: lighter", "0x808080", 0, "nim") ==
          "0x8D8D8D", h.lines)
    h.settings["step"] = 10
    check(tag + "… the step setting (10)", do("Colour: lighter", "#808080", 0) == "#9a9a9a", h.lines)
    h.settings["step"] = 20
    check(tag + "… #rgb stays short when it can (step 20: #000 → #333)", do("Colour: lighter", "#000", 0) == "#333",
          h.lines)
    h.settings = {}
    # pick
    h.answers["pick"] = -1
    do("Colour: pick…", "", 0)
    a = h.asked[-1][1]
    check(tag + "pick: CSS's 148 named colours, each with its hex and rgb()",
          len(a["items"]) == 148 and a["items"][0] == "aliceblue" and a["details"][0] == "#f0f8ff · rgb(240, 248, 255)"
          and "rebeccapurple" in a["items"] and a["title"] == "Colour: insert", (len(a["items"]), a["items"][:3]))
    k = a["items"].index("tomato")
    h.answers["pick"] = k

    def pick(lines, line, col, lang):
        h.lines = list(lines)
        h.lang = lang
        h.cursor = pos(line, col)
        h.sel = None
        h.call(c["Colour: pick…"]["cb"])
        return h.lines[line]
    check(tag + "… a CSS file with no colours: the name, the cursor after it",
          pick(["a {", "  color: ;", "}"], 1, 9, "css") == "  color: tomato;" and h.cursor == pos(1, 15),
          (h.lines, h.cursor))
    check(tag + "… a CSS file with hex colours: #rrggbb; with mostly rgb(): rgb()",
          pick(["a { color: #000; }", "b { color: #fff; }", "c { color: ; }"], 2, 11, "css") == "c { color: #ff6347; }" and
          pick(["a { color: rgb(0, 0, 0); }", "b { color: #fff; }", "c { color: rgb(1, 1, 1); }", "d { color: ; }"],
               3, 11, "css") == "d { color: rgb(255, 99, 71); }", h.lines)
    check(tag + "… on a colour: it is replaced, in its form (rgba keeps its alpha; a name stays a name)",
          pick(["x: rgba(0, 0, 0, 0.5);"], 0, 5, "css") == "x: rgba(255, 99, 71, 0.5);" and
          h.asked[-1][1]["title"] == "Colour: replace rgba(0, 0, 0, 0.5) with" and
          pick(["x: navy;"], 0, 4, "css") == "x: tomato;" and pick(["x: hsl(0 0% 0%)"], 0, 4, "css") ==
          "x: hsl(9.1 100% 63.9%)", h.lines)
    check(tag + "… Nim: colTomato when the file imports std/colors, else 0xFF6347; another language: #rrggbb",
          pick(["import std/[colors, strutils]", "let c = "], 1, 8, "nim") == "let c = colTomato" and
          pick(["let c = "], 0, 8, "nim") == "let c = 0xFF6347" and pick(['c = ""'], 0, 5, "python") == 'c = "#ff6347"',
          h.lines)
