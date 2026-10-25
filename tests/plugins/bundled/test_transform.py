"""transform: lines sorted, unique, reversed, numbered, joined, split; the selection encoded and decoded; JSON pretty
and one line; the numbers added up; the counts"""
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
    check(tag + "it starts", ok)
    if not ok:
        return
    cmd = {}
    for r in h.regs:
        if r.get("kind") == "command" and r.get("title", "").startswith("Transform: "):
            cmd[r["title"][len("Transform: "):]] = r
    want = ["sort lines (A–Z)", "sort lines (Z–A)", "sort lines (by number)", "sort lines (by length)",
            "unique lines", "reverse lines", "number lines", "trim the ends of lines", "join lines (with a space)",
            "split at commas (one item a line)", "shuffle lines", "base64 encode", "base64 decode", "URL encode",
            "URL decode", "hex encode", "hex decode", "HTML escape", "HTML unescape", "to a string literal",
            "from a string literal", "upper case", "lower case", "pretty JSON", "one-line JSON",
            "add up the numbers", "count"]
    check(tag + "its commands", all(w in cmd for w in want), [w for w in want if w not in cmd])
    if not all(w in cmd for w in want):
        return

    def lines(name, ls, sel=None):
        h.lines = list(ls)
        h.sel = sel
        h.cursor = pos(0, 0)
        h.call(cmd[name]["cb"])
        return h.lines

    check(tag + "sort A–Z (case aside), Z–A", lines("sort lines (A–Z)", ["pear", "Apple", "fig"]) ==
          ["Apple", "fig", "pear"] and lines("sort lines (Z–A)", ["b", "c", "a"]) == ["c", "b", "a"])
    check(tag + "sort by number (10 after 9; lines without one last), by length",
          lines("sort lines (by number)", ["10 x", "9 y", "z", "-1 w"]) == ["-1 w", "9 y", "10 x", "z"] and
          lines("sort lines (by length)", ["ccc", "a", "bb"]) == ["a", "bb", "ccc"])
    check(tag + "only the selected lines (a selection ending at a line's start leaves that line out)",
          lines("sort lines (A–Z)", ["z", "c", "b", "a"], rng(1, 0, 3, 0)) == ["z", "b", "c", "a"], h.lines)
    check(tag + "unique, reverse, number, trim",
          lines("unique lines", ["a", "b", "a", "c", "b"]) == ["a", "b", "c"] and
          lines("reverse lines", ["1", "2", "3"]) == ["3", "2", "1"] and
          lines("number lines", ["a"] * 10)[9] == "10. a" and lines("number lines", ["a"] * 10)[0] == " 1. a" and
          lines("trim the ends of lines", ["a  ", "  b\t"]) == ["a", "  b"])
    check(tag + "join with a space, split at commas (the indentation kept)",
          lines("join lines (with a space)", ["  a", "   b", "c"]) == ["  a b c"] and
          lines("split at commas (one item a line)", ["  x, y,z"]) == ["  x", "  y", "  z"])
    sh = lines("shuffle lines", [str(i) for i in range(20)])
    check(tag + "shuffle: the same lines, in another order", sorted(sh) == sorted(str(i) for i in range(20)) and
          sh != [str(i) for i in range(20)], sh)

    def text(name, s, col=None):
        h.lines = [s]
        h.sel = rng(0, 0, 0, len(s)) if col is None else None
        h.cursor = pos(0, col or 0)
        h.call(cmd[name]["cb"])
        return "\n".join(h.lines)

    check(tag + "base64 both ways", text("base64 encode", "héllo") == "aMOpbGxv" and
          text("base64 decode", "aMOpbGxv") == "héllo", text("base64 encode", "héllo"))
    check(tag + "URL both ways", text("URL encode", "a b&c=d/é") == "a%20b%26c%3Dd%2F%C3%A9" and
          text("URL decode", "a%20b+c") == "a b c", text("URL encode", "a b&c=d/é"))
    check(tag + "hex both ways", text("hex encode", "Hi!") == "486921" and text("hex decode", "48 69 21") == "Hi!")
    check(tag + "HTML both ways", text("HTML escape", '<a href="x">&</a>') == "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;"
          and text("HTML unescape", "&lt;b&gt; &amp;amp;") == "<b> &amp;")
    check(tag + "a string literal both ways", text("to a string literal", 'say "hi"\t') == '"say \\"hi\\"\\t"' and
          text("from a string literal", '"a\\nb"') == "a\nb", text("to a string literal", 'say "hi"\t'))
    check(tag + "nothing selected: the word at the cursor", text("upper case", "make loud now", col=6) ==
          "make LOUD now", h.lines)
    h.messages = []
    text("hex decode", "abc")
    check(tag + "what cannot be decoded is said, the text kept", h.lines == ["abc"] and
          any("odd number" in m for m in h.messages), h.messages)
    h.lines = ['{"a": [1, 2], "b": {"c": null}}']
    h.sel = None
    h.indent_ = "  "
    h.call(cmd["pretty JSON"]["cb"])
    check(tag + "pretty JSON (the whole file), then one line again",
          h.lines[0] == "{" and '  "a": [' in h.lines and h.lines[-1] == "}", h.lines)
    h.call(cmd["one-line JSON"]["cb"])
    check(tag + "… one line", h.lines == ['{"a":[1,2],"b":{"c":null}}'], h.lines)
    h.messages = []
    h.lines = ["x2 costs 3.5, then -2 and 1_000;", "re-run 4"]
    h.sel = None
    h.call(cmd["add up the numbers"]["cb"])
    check(tag + "add up: 3.5 - 2 + 1000 + 4 (not x2's 2, not re-run's dash), the sum on the clipboard",
          h.messages and h.messages[-1].startswith("sum 1005.5 · 4 numbers") and h.clip == "1005.5", h.messages)
    h.lines = ["one two", "three"]
    h.call(cmd["count"]["cb"])
    check(tag + "count: lines, words, characters", h.messages[-1] == "2 lines · 3 words · 13 characters",
          h.messages[-1])
