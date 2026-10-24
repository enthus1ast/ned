"""split-join: a bracket list one item a line and back — trailing commas per language, strings, comments and inner
brackets, nested lists, tuples of one, vim's gS and gJ"""
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
    tog = h.reg("command", title="Split/join: toggle the list at the cursor")
    spl = h.reg("command", title="Split/join: split the list at the cursor")
    joi = h.reg("command", title="Split/join: join the list at the cursor")
    gS, gJ = h.reg("vimMap", mode="n", keys="gS"), h.reg("vimMap", mode="n", keys="gJ")
    check(tag + "its commands (toggle, split, join) and vim's gS gJ", tog and spl and joi and gS and gJ, h.regs)

    def do(cb, lines, l, c, lang="nim", indent="  "):
        h.lang = lang
        h.comment = {"nim": "#", "python": "#", "json": "", "lua": "--"}.get(lang, "//")
        h.indent_ = indent
        h.lines = list(lines)
        h.cursor = pos(l, c)
        h.sel = None
        r = h.call(cb["cb"], {"count": 1})
        return h.lines if r and "err" not in r else ("error", r)

    one = ['  echo foo(a, b, "x, y")']
    split = ["  echo foo(", "    a,", "    b,", '    "x, y",', "  )"]
    check(tag + "Nim: a call split — one item a line, a unit deeper, a comma after the last, the ) on its own line; "
          "the comma in the string is not the list's",
          do(tog, one, 0, 11) == split and h.cursor == pos(0, 10), (do(tog, one, 0, 11), h.cursor))
    check(tag + "… and joined back, the cursor on a later line of it", do(tog, split, 2, 4) == one, do(tog, split, 2, 4))
    check(tag + "the cursor on the name before the bracket: its list", do(tog, ["x = foo(1, 2)"], 0, 5) ==
          ["x = foo(", "  1,", "  2,", ")"], do(tog, ["x = foo(1, 2)"], 0, 5))
    check(tag + "nested: the innermost list around the cursor ([3, 4]), the rest of the line kept",
          do(tog, ["x = f(g(1, 2), [3, 4]) + 1"], 0, 16) == ["x = f(g(1, 2), [", "  3,", "  4,", "]) + 1"],
          do(tog, ["x = f(g(1, 2), [3, 4]) + 1"], 0, 16))
    check(tag + "the outer list: inner brackets are one item",
          do(tog, ["x = f(g(1, 2), [3, 4])"], 0, 5) == ["x = f(", "  g(1, 2),", "  [3, 4],", ")"],
          do(tog, ["x = f(g(1, 2), [3, 4])"], 0, 5))
    nested = ["x = f(", "  g(", "    1,", "    2,", "  ),", "  @[3],", ")"]
    check(tag + "joined: inner lists that were split are joined too (no comma left before a closing bracket)",
          do(tog, nested, 6, 0) == ["x = f(g(1, 2), @[3])"], do(tog, nested, 6, 0))
    check(tag + "Nim: a seq literal @[…], a table {…}, a parameter list with ; (kept)",
          do(tog, ["let s = @[1, 2]"], 0, 10) == ["let s = @[", "  1,", "  2,", "]"] and
          do(tog, ['let t = {"a": 1, "b": 2}.toTable'], 0, 9) == ["let t = {", '  "a": 1,', '  "b": 2,', "}.toTable"] and
          do(tog, ["proc f(a, b: int; c: string): int ="], 0, 7) ==
          ["proc f(", "  a,", "  b: int;", "  c: string,", "): int ="],
          (do(tog, ["proc f(a, b: int; c: string): int ="], 0, 7),))
    check(tag + "… and the parameter list joined back with its ;",
          do(tog, ["proc f(", "  a,", "  b: int;", "  c: string,", "): int ="], 2, 3) ==
          ["proc f(a, b: int; c: string): int ="], do(tog, ["proc f(", "  a,", "  b: int;", "  c: string,", "): int ="], 2, 3))
    check(tag + "JSON: no comma after the last item; four spaces when the file indents with four",
          do(tog, ['{"a": 1, "b": [1, 2]}'], 0, 2, "json", "    ") == ["{", '    "a": 1,', '    "b": [1, 2]', "}"],
          do(tog, ['{"a": 1, "b": [1, 2]}'], 0, 2, "json", "    "))
    check(tag + "C: none either; Go, Rust, Python, JavaScript: a comma",
          do(tog, ["int a[] = {1, 2};"], 0, 11, "c") == ["int a[] = {", "  1,", "  2", "};"] and
          do(tog, ["f(1, 2)"], 0, 2, "go")[-2] == "  2," and do(tog, ["f(1, 2)"], 0, 2, "rust")[-2] == "  2," and
          do(tog, ["f(1, 2)"], 0, 2, "python")[-2] == "  2," and do(tog, ["f(1, 2)"], 0, 2, "javascript")[-2] == "  2,",
          (do(tog, ["int a[] = {1, 2};"], 0, 11, "c"),))
    check(tag + "another language: as the list had it (a comma after the last one, or not)",
          do(tog, ["t = {1, 2,}"], 0, 5, "lua")[-2] == "  2," and do(tog, ["t = {1, 2}"], 0, 5, "lua")[-2] == "  2",
          (do(tog, ["t = {1, 2,}"], 0, 5, "lua"), do(tog, ["t = {1, 2}"], 0, 5, "lua")))
    check(tag + "strings and comments: brackets and commas in them are not the list's",
          do(tog, ['f("(", \'),\', x)  # (a, b'], 0, 2, "python") == ["f(", '  "(",', "  '),',", "  x,", ")  # (a, b"],
          do(tog, ['f("(", \'),\', x)  # (a, b'], 0, 2, "python"))
    check(tag + "Rust: a lifetime is not a string, a character is",
          do(tog, ["fn f<'a>(x: &'a str, c: char) {"], 0, 9, "rust") ==
          ["fn f<'a>(", "  x: &'a str,", "  c: char,", ") {"] and
          do(tog, ["g(',', b)"], 0, 2, "rust") == ["g(", "  ',',", "  b,", ")"],
          (do(tog, ["fn f<'a>(x: &'a str, c: char) {"], 0, 9, "rust"), do(tog, ["g(',', b)"], 0, 2, "rust")))
    check(tag + "Python: a tuple of one keeps its comma when joined; (a) round an expression gets none when split",
          do(tog, ["t = (", "    a,", ")"], 1, 4, "python") == ["t = (a,)"] and
          do(tog, ["x = (a)"], 0, 5, "python") == ["x = (", "  a", ")"] and
          do(tog, ["f(a)"], 0, 2, "python") == ["f(", "  a,", ")"],
          (do(tog, ["t = (", "    a,", ")"], 1, 4, "python"), do(tog, ["x = (a)"], 0, 5, "python")))
    check(tag + "JavaScript and Rust objects joined with spaces inside the braces; Rust's use a::{…} without",
          do(tog, ["const o = {", "  a: 1,", "  b: 2,", "};"], 1, 2, "javascript") == ["const o = { a: 1, b: 2 };"] and
          do(tog, ["use std::{", "    io,", "    fs,", "};"], 1, 4, "rust") == ["use std::{io, fs};"],
          (do(tog, ["const o = {", "  a: 1,", "  b: 2,", "};"], 1, 2, "javascript"),))
    prag = ["proc f() {.inline, raises: [].} ="]
    check(tag + "Nim's pragma braces {. .}: split and joined as a list, the dots kept with the braces",
          do(tog, prag, 0, 12) == ["proc f() {.", "  inline,", "  raises: [],", ".} ="] and
          do(tog, ["proc f() {.", "  inline,", "  raises: [],", ".} ="], 1, 3) == prag, (do(tog, prag, 0, 12),))
    check(tag + "statements are not a list: for (…; …), { a(); b(); }, a { } block over lines — left, with a message",
          do(tog, ["for (i = 0; i < n; i++) {"], 0, 5, "c") == ["for (i = 0; i < n; i++) {"] and "statements" in h.messages[-1]
          and do(tog, ["f(() => { a(); b(); })"], 0, 9, "javascript") == ["f(() => { a(); b(); })"] and
          do(tog, ["if x {", "    a()", "    b()", "}"], 1, 0, "go") == ["if x {", "    a()", "    b()", "}"] and
          "statements" in h.messages[-1], (h.lines, h.messages[-1:]))
    check(tag + "one item in { } of a language with blocks: no comma added (it may be a block: { x + 1 })",
          do(tog, ["fn f() -> i32 { x + 1 }"], 0, 16, "rust") == ["fn f() -> i32 {", "  x + 1", "}"],
          do(tog, ["fn f() -> i32 { x + 1 }"], 0, 16, "rust"))
    check(tag + "a list in a hanging style is joined too", do(tog, ["foo(a,", "    b)"], 1, 4) == ["foo(a, b)"],
          do(tog, ["foo(a,", "    b)"], 1, 4))
    cm = ["f(", "  a,  # the first", "  b,", ")"]
    check(tag + "comments in the list: it stays split, and says why",
          do(tog, cm, 2, 2) == cm and "comments" in h.messages[-1], (do(tog, cm, 2, 2), h.messages[-1:]))
    ms = ['f(', '  """a', '  b""",', '  c,', ')']
    check(tag + "a string over several lines in the list: it stays split",
          do(tog, ms, 3, 2, "python") == ms and "string" in h.messages[-1], (h.lines, h.messages[-1:]))
    check(tag + "an empty list: nothing to split", do(tog, ["f()"], 0, 1) == ["f()"] and "empty" in h.messages[-1],
          h.messages[-1:])
    check(tag + "no brackets at the cursor: a message", do(tog, ["x = 1"], 0, 0) == ["x = 1"] and
          "no list" in h.messages[-1], h.messages[-1:])
    # vim: gS and gJ, the split and join commands
    lst = ["x = f(", "  g(1, 2),", "  3,", ")"]
    check(tag + "gS inside a split list splits the list on one line at the cursor (g's)",
          do(gS, lst, 1, 5) == ["x = f(", "  g(", "    1,", "    2,", "  ),", "  3,", ")"], do(gS, lst, 1, 5))
    check(tag + "gJ on g's line joins the list around it that is over several lines (f's)",
          do(gJ, lst, 1, 5) == ["x = f(g(1, 2), 3)"], do(gJ, lst, 1, 5))
    check(tag + "gS with no list on one line: a message",
          do(gS, ["f(", "  a,", ")"], 1, 2) == ["f(", "  a,", ")"] and "on one line" in h.messages[-1], h.messages[-1:])
    h.commands_run = []
    check(tag + "gJ with no list over several lines: ned's own Join lines",
          do(gJ, ["a", "b"], 0, 0) == ["a", "b"] and h.commands_run == ["Join lines"], h.commands_run)
    check(tag + "Split/join: split / join the list at the cursor",
          do(spl, ["f(a, b)"], 0, 2) == ["f(", "  a,", "  b,", ")"] and do(joi, ["f(", "  a,", "  b,", ")"], 1, 2) ==
          ["f(a, b)"], (do(spl, ["f(a, b)"], 0, 2),))
    h.lang = "plaintext"
    h.comment = "#"
    h.indent_ = "  "
