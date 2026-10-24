"""markdown-tools: the table of contents (put in, updated, on save, GitHub's anchors), a numbered list renumbered,
the checkbox toggled, bold / italic / code / strikethrough / link toggled, anchors completed after ](#, hover on a
link to a heading, its keys and vim mappings for Markdown files."""
import os
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


def start(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return None
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    if not ok:
        h.p.kill()
        check(tag + "it starts", False, h.p.stderr.read()[-1500:])
        return None
    check(tag + "it starts (%s ms)" % h.ready_ms, True)
    return h


DOC = """---
title: x
---
# My doc

Intro.

## Contents
<!-- toc -->
- [Old](#old)
<!-- tocstop -->

## Install
### On Termux
```sh
# not a heading
```
## Install
Setext Title
------------
## Skip me <!-- omit from toc -->
## What's new in 6.25?
## `ned --lsp-bridge` and [links](http://x.y)
## **Bold** __init__ and snake_case
## Ünïcode — emoji 🎉 here
## C++ & Nim""".split("\n")

TOC = ["- [Install](#install)",
       "  - [On Termux](#on-termux)",
       "- [Install](#install-1)",
       "- [Setext Title](#setext-title)",
       "- [What's new in 6.25?](#whats-new-in-625)",
       "- [`ned --lsp-bridge` and links](#ned---lsp-bridge-and-links)",
       "- [**Bold** __init__ and snake_case](#bold-init-and-snake_case)",
       "- [Ünïcode — emoji 🎉 here](#ünïcode--emoji--here)",
       "- [C++ & Nim](#c--nim)"]


def run(factory, tag):
    h = start(factory, tag)
    if not h:
        return
    titles = {r["title"] for r in h.regs if r["kind"] == "command"}
    want = {"Markdown: table of contents", "Markdown: renumber this list", "Markdown: toggle the checkbox",
            "Markdown: bold", "Markdown: italic", "Markdown: code", "Markdown: strikethrough", "Markdown: link"}
    keys = {(r["lang"], r["keys"]) for r in h.regs if r["kind"] == "langKey"}
    vim = {r["keys"] for r in h.regs if r["kind"] == "vimMap" and r.get("lang") == "markdown"}
    vis = {r["keys"] for r in h.regs if r["kind"] == "vimMap" and r.get("mode") == "v" and r.get("lang") == "markdown"}
    every = [r["keys"] for r in h.regs if r["kind"] == "vimMap" and not r.get("lang")]
    check(tag + "its commands; keys and vim mappings only in Markdown files; its settings",
          want <= titles and keys == {("markdown", "ctrl+alt+b"), ("markdown", "ctrl+alt+e"), ("markdown", "ctrl+alt+k"),
                                      ("markdown", "ctrl+alt+c")} and
          {"<leader>mt", "<leader>mn", "<leader>mx", "<leader>mb", "<leader>ml"} <= vim and every == [] and
          vis == {"<leader>mb", "<leader>mi", "<leader>mc", "<leader>ms", "<leader>ml"} and
          h.reg("setting", key="tocOnSave")["default"] is True and h.reg("setting", key="tocLevels")["default"] == "1..6",
          (titles, keys, vim))
    cmd = lambda t: h.reg("command", title=t)["cb"]
    h.lang = "markdown"
    h.path_ = os.path.join(h.tmp, "README.md")
    # the table of contents: updated between the markers
    h.lines = list(DOC)
    h.cursor = pos(20, 0)
    h.call(cmd("Markdown: table of contents"))
    a = h.lines.index("<!-- toc -->")
    e = h.lines.index("<!-- tocstop -->")
    got = h.lines[a + 1:e]
    check(tag + "the contents updated between the markers: GitHub's anchors (a second Install is #install-1, code "
          "and links, emphasis, accents, a dash and an emoji, & and ?), nested by level; the title, the heading of the "
          "contents, one marked omit, and # in code left out",
          got == [""] + TOC + [""] and h.messages[-1] == "Table of contents: 9 headings", (got, h.messages[-1:]))
    h.call(cmd("Markdown: table of contents"))
    check(tag + "again: it says it is up to date", h.messages[-1] == "The table of contents is up to date", h.messages[-1:])
    # on save
    bs = h.reg("event", event="beforeSave", pattern="lang:markdown")
    h.lines[h.lines.index("## C++ & Nim")] = "## C and Nim"
    h.call(bs["cb"], {"buf": 1, "path": h.path_, "lang": "markdown"})
    check(tag + "saving updates it (tocOnSave)", "- [C and Nim](#c-and-nim)" in h.lines, h.lines)
    h.settings = {"tocOnSave": False}
    h.lines[h.lines.index("## C and Nim")] = "## Nim"
    h.call(bs["cb"], {"buf": 1, "path": h.path_, "lang": "markdown"})
    check(tag + "… not when tocOnSave is off", "- [C and Nim](#c-and-nim)" in h.lines, h.lines)
    h.settings = {"tocLevels": "3..3"}
    h.call(cmd("Markdown: table of contents"))
    a = h.lines.index("<!-- toc -->")
    check(tag + "tocLevels: only those levels", h.lines[a + 1:a + 4] == ["", "- [On Termux](#on-termux)", ""], h.lines)
    h.settings = {}
    # put in at the cursor
    h.lines = ["# Title", "", "Some text.", "", "## One", "### Two", "## Three"]
    h.cursor = pos(1, 0)
    h.call(cmd("Markdown: table of contents"))
    check(tag + "no markers: the contents put in at the cursor's blank line, with the markers",
          h.lines[:9] == ["# Title", "<!-- toc -->", "", "- [One](#one)", "  - [Two](#two)", "- [Three](#three)", "",
                          "<!-- tocstop -->", ""] and h.lines[9] == "Some text.", h.lines)
    h.lines = ["## Contents", "", "## A"]
    h.cursor = pos(0, 3)
    h.call(cmd("Markdown: table of contents"))
    check(tag + "… on a heading's line: after it (the heading of the contents is left out of them)",
          h.lines == ["## Contents", "", "<!-- toc -->", "", "- [A](#a)", "", "<!-- tocstop -->", "", "## A"], h.lines)
    h.lang = "nim"
    h.path_ = os.path.join(h.tmp, "a.nim")
    h.call(cmd("Markdown: table of contents"))
    check(tag + "not in a Markdown file", h.messages[-1] == "Markdown: table of contents — this is not a Markdown file",
          h.messages[-1:])
    h.lang = "markdown"
    h.path_ = os.path.join(h.tmp, "README.md")
    # renumber
    h.lines = ["Intro", "", "1. a", "3. b", "   more of b", "   1. x", "   5. y", "      under y", "7. c", "lazy c",
               "", "9. d", "", "- bullet", "4) e", "8) f", "", "Paragraph", "1. other"]
    h.cursor = pos(6, 4)
    h.call(cmd("Markdown: renumber this list"))
    check(tag + "renumber: the list at the cursor 1. 2. 3. 4. (past lines under an item, a blank line), the list "
          "inside it from its own first number, one after a bullet list from its own; the next list left alone",
          h.lines == ["Intro", "", "1. a", "2. b", "   more of b", "   1. x", "   2. y", "      under y", "3. c",
                      "lazy c", "", "4. d", "", "- bullet", "4) e", "5) f", "", "Paragraph", "1. other"] and
          h.messages[-1] == "Renumbered 5 items", (h.lines, h.messages[-1:]))
    h.call(cmd("Markdown: renumber this list"))
    check(tag + "… again: numbered already", h.messages[-1] == "The list is numbered already", h.messages[-1:])
    h.lines = ["Some", "text", "- a", "- b"]
    h.cursor = pos(0, 0)
    h.call(cmd("Markdown: renumber this list"))
    m1 = h.messages[-1]
    h.cursor = pos(3, 0)
    h.call(cmd("Markdown: renumber this list"))
    check(tag + "… not in a numbered list: it says so",
          m1 == h.messages[-1] == "Markdown: the cursor is not in a numbered list", (m1, h.messages[-1:]))
    # the checkbox
    tg = cmd("Markdown: toggle the checkbox")
    h.lines = ["- [ ] milk", "  * [x] eggs", "1. bread", "plain line", "", "- ", "+ [X] tea"]
    seen = []
    for i in range(7):
        h.sel = None
        h.cursor = pos(i, 0)
        h.call(tg)
        seen.append(h.lines[i])
    check(tag + "the checkbox: ticked, cleared, added to a list item (- * + 1.) and to a plain or blank line",
          seen == ["- [x] milk", "  * [ ] eggs", "1. [ ] bread", "- [ ] plain line", "- [ ] ", "- [ ] ", "+ [ ] tea"],
          seen)
    h.lines = ["- [ ] a", "- [x] b", "- c", "after"]
    h.sel = rng(0, 2, 3, 0)
    h.call(tg)
    check(tag + "… on each selected line (not the line the selection ends at the start of)",
          h.lines == ["- [x] a", "- [ ] b", "- [ ] c", "after"], h.lines)
    h.sel = None
    # bold, italic, code, strikethrough, link
    bold, ital, code, strike = cmd("Markdown: bold"), cmd("Markdown: italic"), cmd("Markdown: code"), cmd("Markdown: strikethrough")
    h.lines = ["say hello there"]
    h.cursor = pos(0, 6)
    h.call(bold)
    l1, s1 = h.lines[0], h.sel
    h.sel = None
    h.cursor = pos(0, 8)
    h.call(bold)
    l2 = h.lines[0]
    check(tag + "bold: the word at the cursor between ** (selected) — again, taken away",
          l1 == "say **hello** there" and s1 == rng(0, 6, 0, 11) and l2 == "say hello there", (l1, s1, l2))
    h.sel = rng(0, 4, 0, 15)
    h.call(ital)
    l1, s1 = h.lines[0], h.sel
    h.call(ital)
    l2, s2 = h.lines[0], h.sel
    check(tag + "italic: the selection between * (and selected), again: without them",
          l1 == "say *hello there*" and s1 == rng(0, 5, 0, 16) and l2 == "say hello there" and s2 == rng(0, 4, 0, 15),
          (l1, s1, l2, s2))
    h.lines = ["a **word** b", "an _old_ one", "x __strong__ y"]
    h.sel = rng(0, 4, 0, 8)
    h.call(ital)
    l1 = h.lines[0]
    h.sel = None
    h.cursor = pos(1, 5)
    h.call(ital)
    h.sel = None
    h.cursor = pos(2, 5)
    h.call(bold)
    check(tag + "italic inside bold is both (***word***); _old_ and __strong__ are taken away too",
          l1 == "a ***word*** b" and h.lines[1:] == ["an old one", "x strong y"], (l1, h.lines))
    h.lines = ["run the tests now"]
    h.sel = None
    h.cursor = pos(0, 5)
    h.call(code)
    l1 = h.lines[0]
    h.sel = rng(0, 0, 0, 3)
    h.call(strike)
    l2 = h.lines[0]
    h.lines = ["x  y"]
    h.sel = None
    h.cursor = pos(0, 2)
    h.call(bold)
    check(tag + "code, strikethrough; with no word at the cursor: the marks, the cursor between them",
          l1 == "run `the` tests now" and l2 == "~~run~~ `the` tests now" and h.lines[0] == "x **** y" and
          h.cursor == pos(0, 4), (l1, l2, h.lines, h.cursor))
    link = cmd("Markdown: link")
    h.lines = ["see the docs here"]
    h.sel = rng(0, 4, 0, 12)
    h.clip = "https://example.com/docs"
    h.call(link)
    l1, s1 = h.lines[0], h.sel
    h.sel = None
    h.clip = "not an address"
    h.lines = ["see docs"]
    h.cursor = pos(0, 5)
    h.call(link)
    l2, c2 = h.lines[0], h.cursor
    h.lines = ["a [b c](http://x) d"]
    h.cursor = pos(0, 4)
    h.call(link)
    check(tag + "link: to the address on the clipboard (the text selected), else the cursor where the address "
          "goes; on a link, its text again",
          l1 == "see [the docs](https://example.com/docs) here" and s1 == rng(0, 5, 0, 13) and
          l2 == "see [docs]()" and c2 == pos(0, 11) and h.lines[0] == "a b c d", (l1, s1, l2, c2, h.lines))
    # vim: <leader>mb on the word
    h.lines = ["one two"]
    h.sel = None
    h.cursor = pos(0, 5)
    h.call(h.reg("vimMap", mode="n", keys="<leader>mb")["cb"], {"count": 1})
    l1, s1, c1 = h.lines[0], h.sel, h.cursor
    h.sel = rng(0, 0, 0, 3)
    h.call(h.reg("vimMap", mode="v", keys="<leader>ms")["cb"], {"count": 1})
    check(tag + "vim <leader>mb: the word bold, the cursor at its start (nothing selected); in visual mode "
          "<leader>ms: the selection struck through, still selected",
          l1 == "one **two**" and s1 is None and c1 == pos(0, 6) and h.lines[0] == "~~one~~ **two**" and
          h.sel == rng(0, 2, 0, 5), (l1, s1, c1, h.lines, h.sel))
    # anchors: completion and hover
    h.lines = list(DOC) + ["See [x](#on-te", "[i](#install-1) [bad](#nope) [far](other.md#part-two) [web](http://a/#x)"]
    co = h.reg("completion", lang="markdown")
    n = len(DOC)
    v = (h.call(co["cb"], {"buf": 1, "pos": pos(n, 14), "prefix": "te"}) or {}).get("value") or []
    lab = [(x["label"], x["insert"]) for x in v]
    check(tag + "completion after ](#on-te: the anchors that start so, each put in for the word typed (te)",
          lab == [("on-termux", "termux")] and v[0]["detail"] == "### On Termux" and v[0]["doc"] == "line 14", v)
    h.lines[n] = "See [x]("
    v0 = (h.call(co["cb"], {"buf": 1, "pos": pos(n, 8), "prefix": ""}) or {}).get("value")
    h.lines[n] = "See [x](#"
    v = (h.call(co["cb"], {"buf": 1, "pos": pos(n, 9), "prefix": ""}) or {}).get("value") or []
    check(tag + "as ned asks while you type a link (in it: after ( and #): nothing after ](, every heading's anchor "
          "after ](#", v0 == [] and len(v) == 12 and v[0]["label"] == "my-doc" and v[0]["insert"] == "my-doc",
          (v0, [x["label"] for x in v]))
    open(os.path.join(h.tmp, "other.md"), "w").write("# Other\n\n## Part two\n")
    h.lines[n] = "[y](other.md#pa"
    v = (h.call(co["cb"], {"buf": 1, "pos": pos(n, 15), "prefix": "pa"}) or {}).get("value") or []
    check(tag + "… after ](other.md#: that file's anchors",
          [(x["label"], x["insert"]) for x in v] == [("part-two", "part-two")] and v[0]["doc"] == "other.md, line 3", v)
    h.lines[n] = "See [x](http://a.b/c"
    v = (h.call(co["cb"], {"buf": 1, "pos": pos(n, 20), "prefix": "c"}) or {}).get("value")
    check(tag + "… none in a link without #", v == [], v)
    hv = h.reg("hover", lang="markdown")
    last = n + 1
    hs = [(h.call(hv["cb"], {"buf": 1, "pos": pos(last, c)}) or {}).get("value") for c in (2, 20, 35, 60, 2 + 200)]
    check(tag + "hover on a link to a heading: its line; one that no heading has; another file's; none on a web "
          "address or off a link",
          hs == ["**line 18** · `## Install`", "No heading has the anchor `#nope`", "**other.md, line 3** · `## Part two`",
                 "", ""], hs)
