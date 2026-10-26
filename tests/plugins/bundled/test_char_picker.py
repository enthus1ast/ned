"""char-picker: the list of characters by name (the recent ones first), a character inserted at the cursor or over
the selection, one by its code point, and the character under the cursor (its code points, name, UTF-8 bytes) —
also on vim's g8"""
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
    titles = ["Insert a character…", "Insert a character by its code point…",
              "Character under the cursor: name and code point"]
    c = {t: h.reg("command", title=t) for t in titles}
    check(tag + "its commands (Ctrl+Alt+U), vim's g8 (not ga: align's), the recent setting",
          all(c.values()) and c["Insert a character…"]["keys"] == "ctrl+alt+u" and
          h.reg("vimMap", mode="n", keys="ga") is None and h.reg("vimMap", mode="n", keys="g8") and
          h.reg("setting", key="recent")["default"] == 8, [t for t, v in c.items() if not v])
    os.makedirs(os.path.join(h.tmp, "data", "char-picker"), exist_ok=True)

    def run_(t, **kw):
        r = h.call(c[t]["cb"])
        return r and "err" not in r

    # the list: every group, names to type, the code point and group beside each
    h.lines = ["x = 1"]
    h.cursor = pos(0, 4)
    h.answers["pick"] = -1
    run_("Insert a character…")
    a = h.asked[-1][1]
    items, dets = a["items"], a["details"]
    check(tag + "the list: hundreds of characters, each with its name; its code point and group beside it",
          len(items) > 500 and "→  rightwards arrow — right arrow, ->" in items and
          dets[items.index("→  rightwards arrow — right arrow, ->")] == "U+2192 · arrows" and
          "α  greek small letter alpha" in items and "€  euro sign — euro" in items and
          "┌  box drawings light down and right" in items, (len(items), items[:5]))
    groups = {d.split(" · ")[1] for d in dets}
    check(tag + "… every group: arrows, maths, Greek, box drawing, currency, emoji, Nerd Font …",
          {"arrows", "maths", "Greek", "box drawing", "blocks and shapes", "currency", "punctuation", "emoji",
           "Nerd Font", "keys", "spaces and invisible", "Latin letters"} <= groups and "-" not in groups, groups)
    check(tag + "… emoji with their everyday names, Nerd Font symbols by their nf- name, invisible ones shown as ⬚",
          "❤  heavy black heart — red heart" in items and "  nf-pl-left_hard_divider — Powerline: solid " +
          "triangle pointing right" in items and "⬚  zero width space — zwsp" in items and
          "\U000f01a5  nf-md-crown — crown (Nim's, in starship)" in items, [i for i in items if "heart" in i][:3])
    check(tag + "… not ASCII (only named under the cursor)", not any(i.startswith("A  ") for i in items), "")
    # choose one: inserted at the cursor, the cursor after it
    h.answers["pick"] = items.index("→  rightwards arrow — right arrow, ->")
    run_("Insert a character…")
    check(tag + "a character chosen: at the cursor (UTF-8), the cursor after it", h.lines == ["x = →1"] and
          h.cursor == pos(0, 4 + 3), (h.lines, h.cursor))
    # over the selection; the recent one first next time
    h.lines = ["a -> b"]
    h.sel = {"start": pos(0, 2), "stop": pos(0, 4)}
    h.answers["pick"] = 0
    run_("Insert a character…")
    a = h.asked[-1][1]
    check(tag + "the one used last is first (\"used lately\"); chosen over a selection, it replaces it",
          a["items"][0] == "→  rightwards arrow — right arrow, ->" and a["details"][0] == "U+2192 · used lately" and
          h.lines == ["a → b"] and h.sel is None, (a["items"][:2], h.lines))
    h.answers["pick"] = [i for i, x in enumerate(a["items"]) if x.startswith("α ")][0]
    h.lines = [""]
    h.cursor = pos(0, 0)
    run_("Insert a character…")
    h.answers["pick"] = -1
    a2 = h.call(c["Insert a character…"]["cb"]) and h.asked[-1][1]
    rec = open(os.path.join(h.tmp, "data", "char-picker", "recent.txt")).read().split()
    check(tag + "the recent ones: the newest first, each once, kept in the data folder",
          rec == ["03B1", "2192"] and a2["items"][:2] == ["α  greek small letter alpha", "→  rightwards arrow — right arrow, ->"],
          (rec, a2["items"][:3]))
    h.settings["recent"] = 0
    h.answers["pick"] = -1
    run_("Insert a character…")
    check(tag + "recent 0: none listed first", h.asked[-1][1]["items"][0].startswith("←  leftwards arrow"),
          h.asked[-1][1]["items"][:1])
    h.settings = {}
    # by its code point
    for typed, want in [("U+2713", "✓"), ("1F525", "🔥"), ("&#8594;", "→"), ("&#x3b1;", "α"), ("0x41", "A")]:
        h.lines = ["[]"]
        h.cursor = pos(0, 1)
        h.sel = None
        h.answers["ask"] = typed
        run_("Insert a character by its code point…")
        check(tag + "by its code point: " + typed + " → " + want, h.lines == ["[" + want + "]"], (h.lines, h.messages[-1:]))
    check(tag + "… its name said", h.messages[-1] == "U+0041  latin capital letter a", h.messages[-1:])
    h.answers["ask"] = "D800"
    run_("Insert a character by its code point…")
    check(tag + "… not a code point (a surrogate): said, nothing inserted", "Not a code point: D800" in h.messages[-1] and
          h.lines == ["[A]"], (h.messages[-1:], h.lines))

    # the character under the cursor
    def under(line, col, via=None):
        h.lines = [line]
        h.cursor = pos(0, col)
        if via:
            h.call(h.reg("vimMap", mode="n", keys=via)["cb"], {"count": 1})
        else:
            run_("Character under the cursor: name and code point")
        return h.messages[-1]
    check(tag + "under the cursor: the character, U+, its name, UTF-8 bytes, decimal",
          under("a → b", 2) == "→  U+2192  rightwards arrow  ·  UTF-8: E2 86 92  ·  decimal 8594", h.messages[-1:])
    check(tag + "… the cursor inside a character's bytes: that character", under("a → b", 3).startswith("→  U+2192"),
          h.messages[-1:])
    check(tag + "… at the end of the line: the one before", under("ab", 2).startswith("b  U+0062  latin small letter b"),
          h.messages[-1:])
    check(tag + "… an emoji with its variation selector: both code points",
          under("❤️", 0) == "❤️  U+2764 U+FE0F  heavy black heart, variation selector-16  ·  UTF-8: E2 9D A4 EF B8 8F",
          h.messages[-1:])
    check(tag + "… a skin tone", "U+1F44D U+1F3FD  thumbs up sign, emoji modifier fitzpatrick type-4" in under("👍🏽", 0),
          h.messages[-1:])
    check(tag + "… a tab (named, not shown)", under("\tx", 0) == "U+0009  character tabulation (tab)  ·  UTF-8: 09  ·  decimal 9",
          h.messages[-1:])
    check(tag + "… a Nerd Font symbol: its nf- name", "U+E0A0  nf-pl-branch (Nerd Font: Powerline: version control branch)"
          in under("", 0), h.messages[-1:])
    check(tag + "… one not in the table: by its block (a CJK ideograph has its name; Arabic, private use)",
          "U+4E2D  cjk unified ideograph-4E2D" in under("中", 0) and "(an Arabic letter or sign)" in under("ش", 0) and
          "(private use (an icon font, such as a Nerd Font, may draw it))" in under("", 0), h.messages[-3:])
    check(tag + "… vim's g8 says the same", under("é", 0, "g8") ==
          "é  U+00E9  latin small letter e with acute  ·  UTF-8: C3 A9  ·  decimal 233", h.messages[-1:])
    check(tag + "… an empty line: said", under("", 0) == "The line is empty", h.messages[-1:])
