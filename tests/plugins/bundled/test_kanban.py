"""kanban: TODO.md as a board — its ## headings the columns, its checklist items the cards (with the lines under them;
a paragraph and a ``` block left alone); the board side by side (a long card over several lines) and, in a narrow
editor, one column under another; a card moved with Alt+Right/Alt+Left (ticked in Done, unticked out of it), up and
down, with the file edited (not open: opened, changed, saved; open: in its tab); the card at the cursor of TODO.md
itself moved to a column chosen; a card added; the dock's view and a card's menu; a file without headings"""
import os
from tplugins import check

TODO = """# Project

Some intro text.

## To do
- [ ] write the docs
  - a note under it
- [ ] fix the parser bug that eats the last line of a file when it has no line end at all, ever
Not a card, a paragraph.
```
- [ ] not a card in a fence
```

## Doing
- [ ] the kanban plugin

## Done
- [x] the todo plugin
"""


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    titles = ["Kanban: open the board", "Kanban: move the card…", "Kanban: add a card…"]
    c = {t: h.reg("command", title=t) for t in titles}
    keys = {k: h.reg("langKey", lang="kanban", keys=k) for k in ("alt+right", "alt+left", "alt+up", "alt+down",
                                                                   "alt+enter")}
    view, click = h.reg("view", title="KANBAN"), h.reg("viewClick", title="KANBAN")
    sd = {k: (h.reg("setting", key=k) or {}).get("default") for k in ("file", "level", "doneColumn")}
    check(tag + "its commands, keys on the board (and vim's), a view, its settings, its language",
          all(c.values()) and all(keys.values()) and view and click and h.reg("language", id="kanban") and
          h.reg("vimMap", lang="kanban", keys=">") and sd == {"file": "TODO.md", "level": 2, "doneColumn": "Done"},
          sd)
    if not (all(c.values()) and all(keys.values()) and view):
        return
    proj = os.path.join(h.tmp, "proj")
    os.makedirs(proj)
    h.root = proj
    todo = os.path.join(proj, "TODO.md")
    open(todo, "w").write("# Notes\n\nNo headings of columns here.\n")
    h.call(c["Kanban: open the board"]["cb"])
    check(tag + "a file with no column headings: said", "has no headings to be columns" in h.messages[-1],
          h.messages[-1:])
    open(todo, "w").write(TODO)
    # (ned's side: opening a file gives a tab with its text; saving it writes it; a new tab becomes the current one)
    h.switch_on_new_tab = True
    base = h.api
    width = [100]

    def api(j):
        fn, a = j["fn"], j.get("args", {})
        if fn == "open":
            p = a["path"]
            if 60 not in h.others and h.cur != 60:
                h.others[60] = {"lines": open(p).read().rstrip("\n").split("\n"), "path": p, "lang": "markdown",
                                "cursor": {"line": max(0, a.get("line", 0)), "col": 0}}
            h.opened.append((p, a.get("line")))
            h.send({"t": "res", "id": j["id"], "value": 60})
        elif fn == "save" and a.get("buf") == 60:
            st = h.others[60] if h.cur != 60 else {"lines": h.lines}
            open(todo, "w").write("\n".join(st["lines"]) + "\n")
            if h.cur == 60: h.dirty_ = False
            else: st["dirty"] = False
            h.saved += 1
            h.send({"t": "res", "id": j["id"], "value": True})
        elif fn == "panes":
            h.send({"t": "res", "id": j["id"], "value": [{"index": 0, "buf": h.cur, "path": "", "active": True,
                                                          "x": 0, "y": 1, "w": width[0], "h": 30}]})
        else:
            base(j)
    h.api = api

    def board():
        return [t for t in h.tabs if t[0] == "Kanban: TODO.md"]

    def file_lines():
        return open(todo).read().rstrip("\n").split("\n")

    h.call(c["Kanban: open the board"]["cb"])
    b = board()
    text = b[-1][1] if b else ""
    rows = text.split("\n")
    check(tag + "the board: the columns side by side, the cards under them (not a paragraph, not in a fence)",
          b and b[-1][2] == "kanban" and any("TO DO (2)" in r and "DOING (1)" in r and "DONE (1)" in r for r in rows)
          and "☐ write the docs" in text and "☑ the todo plugin" in text and "not a card in a fence" not in text and
          "paragraph" not in text, text)
    check(tag + "… a long card over several lines of its column",
          sum(1 for r in rows if "eats the" in r or "line end" in r or "fix the parser" in r) >= 2, text)
    bid = h.cur

    def at(word):
        """the cursor on the board on a word"""
        for i, r in enumerate(h.lines if h.cur == bid else h.others[bid]["lines"]):
            k = r.encode().find(word.encode())
            if k >= 0:
                if h.cur == bid: h.cursor = {"line": i, "col": k}
                else: h.others[bid]["cursor"] = {"line": i, "col": k}
                return True
        return False

    # Alt+Right: the card (and the line under it) to the end of Doing; the file not open: opened, changed, saved
    at("write the docs")
    h.call(keys["alt+right"]["cb"], {"buf": bid})
    fl = file_lines()
    check(tag + "Alt+Right: the card and its note at the end of the next column, the file saved",
          fl[fl.index("## Doing"):fl.index("## Doing") + 4] == ["## Doing", "- [ ] the kanban plugin",
                                                                  "- [ ] write the docs", "  - a note under it"]
          and "  - a note under it" not in fl[:fl.index("## Doing")] and h.saved >= 1, fl)
    cur = h.cursor if h.cur == bid else h.others.get(bid, {}).get("cursor")
    line = (h.lines if h.cur == bid else h.others[bid]["lines"])[cur["line"]] if cur else ""
    check(tag + "… the board drawn again, in front, the cursor on the card moved", h.cur == bid and
          "write the docs" in line.encode()[cur["col"]:].decode(errors="replace"), (cur, line))
    # to Done: ticked; back: unticked
    h.call(keys["alt+right"]["cb"], {"buf": bid})
    fl = file_lines()
    check(tag + "into Done: ticked", fl[-2:] == ["- [x] write the docs", "  - a note under it"], fl)
    h.call(keys["alt+left"]["cb"], {"buf": bid})
    fl = file_lines()
    check(tag + "out of Done: unticked", "- [ ] write the docs" in fl and fl.index("- [ ] write the docs") <
          fl.index("## Done"), fl)
    # up and down its column
    at("write the docs")
    h.call(keys["alt+up"]["cb"], {"buf": bid})
    fl = file_lines()
    k = fl.index("## Doing")
    check(tag + "Alt+Up: above the card before it (its note with it)", fl[k + 1:k + 4] == [
        "- [ ] write the docs", "  - a note under it", "- [ ] the kanban plugin"], fl)
    h.call(keys["alt+down"]["cb"], {"buf": bid})
    fl = file_lines()
    check(tag + "Alt+Down: back below it", fl[k + 1:k + 4] == ["- [ ] the kanban plugin", "- [ ] write the docs",
                                                                "  - a note under it"], fl)
    # Alt+Enter: to the card in the file
    h.opened = []
    at("the kanban plugin")
    h.call(keys["alt+enter"]["cb"], {"buf": bid})
    check(tag + "Alt+Enter: the card's line in TODO.md", h.opened and h.opened[-1] == (todo, k + 1), h.opened)
    # in TODO.md itself (open in its tab): the card at the cursor moved to a column chosen, in the tab, saved
    h.switch_to(60)
    h.dirty_ = False
    h.lines = file_lines()
    h.cursor = {"line": h.lines.index("- [ ] the kanban plugin"), "col": 3}
    saved = h.saved
    h.answers["pick"] = 1                         # (the columns but its own: To do, Done)
    h.call(c["Kanban: move the card…"]["cb"])
    fl = file_lines()
    check(tag + "the card at the cursor of TODO.md moved to the column chosen — in its tab, saved",
          fl[-1] == "- [x] the kanban plugin" and h.lines[-1] == "- [x] the kanban plugin" and h.saved == saved + 1,
          fl)
    # a card added
    h.answers["ask"] = "release 6.32"
    h.answers["pick"] = 0
    h.call(c["Kanban: add a card…"]["cb"])
    fl = file_lines()
    k = fl.index("## To do")
    check(tag + "a card added at the end of the column chosen", fl[k + 2] == "- [ ] release 6.32", fl)
    # the dock's view, a card's menu
    r = h.call(view["cb"])
    rows = (r or {}).get("value") or []
    got = [(x["icon"], x["text"], x["depth"]) for x in rows]
    check(tag + "the view: the board's row, the columns and their cards", got == [
        ("▦", "Open the board", 0), ("▸", "To do", 0),
        ("☐", "fix the parser bug that eats the last line of a file when it has no line end at all, ever", 1),
        ("☐", "release 6.32", 1), ("▸", "Doing", 0), ("☐", "write the docs", 1), ("▸", "Done", 0),
        ("☑", "the todo plugin", 1), ("☑", "the kanban plugin", 1)], got)
    h.asked = []
    h.answers["pick"] = 2                         # (Move to Doing, Move to Done, Done, Up, Go to it)
    h.call(click["cb"], {"id": "0:1"})
    menu = h.asked[-1][1] if h.asked else {}
    fl = file_lines()
    check(tag + "a card's menu in the dock: move it, tick it, up, go to it — ticked",
          menu.get("items") == ["Move to Doing", "Move to Done", "Done", "Up", "Go to it in TODO.md"] and
          "- [x] release 6.32" in fl, (menu, fl))
    # a narrow editor: one column under another
    width[0] = 40
    h.call(c["Kanban: open the board"]["cb"])
    text = board()[-1][1]
    check(tag + "a narrow editor: the columns one under another", "\nTO DO (2)\n  ☐ fix the parser" in text and
          "\nDOING (1)\n  ☐ write the docs" in text, text)
    # saving TODO.md draws the board again
    open(todo, "a").write("- [ ] a card added by hand\n")
    h.switch_to(60)
    h.lines = file_lines()
    h.call(h.reg("event", event="save")["cb"], {"buf": 60, "path": todo, "lang": "markdown"})
    st = h.others.get(bid, {})
    check(tag + "TODO.md saved: the board drawn again where it is", "a card added by hand" in "\n".join(
        st.get("lines", [])) and h.cur == 60, st.get("lines", [])[:6])
