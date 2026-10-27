"""wiki-notes: a folder of notes linked with [[links]] — followed (a name in another case and with - for its spaces, a
path in it, |text shown, #heading), a link to no note making it (saved in the project; in a folder outside it, left
to save), the backlinks (the command and the dock's view), completion of names and headings after [[, hover, the
hints of links to no note (not in `code`), finding a note, a new note, vim's Enter, a hidden folder left out"""
import os
from tplugins import check

NOTES = {
    "Home.md": "# Home\n\nSee [[Shopping list]] and [[projects/Ideas|my ideas]]. Also [[Missing note]].\n"
               "A `[[code link]]` is not one.\n\n## Section\nthe end\n",
    "shopping-list.md": "# Shopping list\n\n- milk\n- back [[home]]\n",
    "projects/Ideas.md": "# Ideas\n\n## Big ones\n- a ned plugin\n\nBack to [[Home#section]]\n",
    ".hidden/Secret.md": "# Secret\n[[Home]]\n",
}


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    titles = ["Wiki: follow the link", "Wiki: backlinks…", "Wiki: find a note…", "Wiki: new note…"]
    c = {t: h.reg("command", title=t) for t in titles}
    view = h.reg("view", title="BACKLINKS")
    key = h.reg("langKey", lang="markdown", keys="alt+shift+o")
    enter = h.reg("vimMap", lang="markdown", keys="<CR>")
    comp, hov = h.reg("completion", lang="markdown"), h.reg("hover", lang="markdown")
    ev = {e: h.reg("event", event=e) for e in ("open", "change", "save", "enter")}
    check(tag + "its commands, Alt+Shift+O and vim's Enter in Markdown, completion, hover, the view, its events",
          all(c.values()) and view and key and enter and comp and hov and all(ev.values()))
    if not (all(c.values()) and view and comp and hov):
        return
    proj = os.path.join(h.tmp, "proj")
    for name, text in NOTES.items():
        p = os.path.join(proj, name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)
    h.root = proj
    home = os.path.join(proj, "Home.md")
    shop = os.path.join(proj, "shopping-list.md")
    ideas = os.path.join(proj, "projects", "Ideas.md")
    # (ned's side: opening a file gives a tab of its own — empty when it is new —; saving writes it, in the project)
    nextid = [70]
    by_path = {}
    base = h.api

    def api(j):
        fn, a = j["fn"], j.get("args", {})
        if fn == "open":
            p = a["path"]
            h.opened.append((p, a.get("line")))
            if p not in by_path:
                by_path[p] = nextid[0]
                nextid[0] += 1
                h.others[by_path[p]] = {"lines": (open(p).read().split("\n") if os.path.exists(p) else [""]),
                                        "path": p, "lang": "markdown"}
            h.send({"t": "res", "id": j["id"], "value": by_path[p]})
        elif fn == "save" and a.get("buf") in by_path.values():
            st = h.others[a["buf"]]
            if not st["path"].startswith(proj + "/"):
                h.send({"t": "res", "id": j["id"], "err": "this plugin may not change files outside the project"})
                return
            os.makedirs(os.path.dirname(st["path"]), exist_ok=True)
            open(st["path"], "w").write("\n".join(st["lines"]))
            h.send({"t": "res", "id": j["id"], "value": True})
        else:
            base(j)
    h.api = api
    h.path_ = home
    h.lang = "markdown"
    h.lines = NOTES["Home.md"].split("\n")
    # follow: a name in another case, - for its spaces; a path in it and |text; #heading
    h.cursor = {"line": 2, "col": 8}
    h.call(c["Wiki: follow the link"]["cb"])
    h.cursor = {"line": 2, "col": 33}
    h.call(key["cb"], {"buf": 1})
    check(tag + "follow: [[Shopping list]] is shopping-list.md; [[projects/Ideas|my ideas]] the note Ideas",
          h.opened[-2:] == [(shop, -1), (ideas, -1)], h.opened)
    h.path_ = ideas
    h.lines = NOTES["projects/Ideas.md"].split("\n")
    h.cursor = {"line": 5, "col": 12}
    h.call(c["Wiki: follow the link"]["cb"])
    check(tag + "[[Home#section]]: at its heading", h.opened[-1] == (home, 5), h.opened[-1:])
    h.cursor = {"line": 0, "col": 2}
    h.call(c["Wiki: follow the link"]["cb"])
    check(tag + "not on a link: said", "put the cursor on a [[link]]" in h.messages[-1], h.messages[-1:])
    # the hints: a link to no note (not one in `code`)
    h.path_ = home
    h.lines = NOTES["Home.md"].split("\n")
    h.problems = None
    h.call(ev["open"]["cb"], {"buf": 1, "path": home, "lang": "markdown"})
    pr = [(p["range"]["start"]["line"], p["range"]["start"]["col"], p["severity"], p["message"]) for p in h.problems or []]
    check(tag + "a link to no note: a hint on it (`[[code link]]` is code)",
          pr == [(2, NOTES["Home.md"].split("\n")[2].index("[[Missing"), 4,
                  "no note “Missing note” yet — Wiki: follow the link makes it")], pr)
    # completion after [[ and after [[Note#; hover
    h.lines = ["x [[sh"]
    r = h.call(comp["cb"], {"buf": 1, "pos": {"line": 0, "col": 6}, "prefix": "sh"})
    items = {(x["label"], x["insert"]) for x in (r or {}).get("value") or []}
    check(tag + "completion after [[: the notes' names (not its own), ]] after them",
          items == {("shopping-list", "shopping-list]]"), ("Ideas", "Ideas]]")}, items)
    h.lines = ["[[Ideas#]]"]
    r = h.call(comp["cb"], {"buf": 1, "pos": {"line": 0, "col": 8}, "prefix": ""})
    items = [(x["label"], x["insert"]) for x in (r or {}).get("value") or []]
    check(tag + "… after [[Note#: its headings (]] there already)", items == [("Ideas", "Ideas"),
                                                                             ("Big ones", "Big ones")], items)
    h.lines = NOTES["Home.md"].split("\n")
    r = h.call(hov["cb"], {"buf": 1, "pos": {"line": 2, "col": 10}})
    v = (r or {}).get("value") or ""
    check(tag + "hover: the start of its note", v.startswith("**shopping-list**\n\n# Shopping list") and "milk" in v, v)
    r = h.call(hov["cb"], {"buf": 1, "pos": {"line": 2, "col": 66}})
    check(tag + "… a link to no note: said", "no note yet" in ((r or {}).get("value") or ""), r)
    # backlinks: the command, the view (the hidden folder left out)
    h.answers["pick"] = 1
    h.asked = []
    h.call(c["Wiki: backlinks…"]["cb"])
    a = h.asked[-1][1] if h.asked else {}
    check(tag + "backlinks: the notes linking to the open one, their lines; the one chosen opened at its line",
          a.get("items") == ["Ideas", "shopping-list"] and a.get("details") == ["Back to [[Home#section]]",
                                                                              "- back [[home]]"] and
          h.opened[-1] == (shop, 3), (a, h.opened[-1:]))
    rows = (h.call(view["cb"]) or {}).get("value") or []
    got = [(x["icon"], x["text"], x["depth"], x.get("line")) for x in rows]
    check(tag + "the view: the note, the notes linking to it and their lines", got == [
        ("◆", "Home", 0, 0), ("▸", "Ideas", 0, 5), ("•", "Back to [[Home#section]]", 1, 5),
        ("▸", "shopping-list", 0, 3), ("•", "- back [[home]]", 1, 3)], got)
    # a link to no note: the note made beside the note, saved
    h.cursor = {"line": 2, "col": 66}
    h.call(c["Wiki: follow the link"]["cb"])
    made = os.path.join(proj, "Missing note.md")
    check(tag + "a link to no note: its note made (# its name), saved, opened",
          os.path.exists(made) and open(made).read() == "# Missing note\n\n" and h.opened[-1][0] == made and
          "made" in h.messages[-1], (h.opened[-1:], h.messages[-1:]))
    h.call(ev["save"]["cb"], {"buf": by_path.get(made, 1), "path": made, "lang": "markdown"})
    check(tag + "… and the hint on its link gone", h.problems == [], h.problems)
    # find a note; a new note
    h.answers["pick"] = -1
    h.call(c["Wiki: find a note…"]["cb"])
    a = h.asked[-1][1]
    check(tag + "find a note: every note (not a hidden folder's), its folder beside it",
          a["items"] == ["Home", "Missing note", "Ideas", "shopping-list"] and a["details"][2] == "projects", a)
    h.answers["ask"] = "Recipes"
    h.call(c["Wiki: new note…"]["cb"])
    check(tag + "a new note: made in the folder of the note in front",
          open(os.path.join(proj, "Recipes.md")).read() == "# Recipes\n\n", h.messages[-1:])
    h.answers["ask"] = "shopping list"
    h.call(c["Wiki: new note…"]["cb"])
    check(tag + "a new note of a name there is: opened, said", "there is a note shopping-list already" in
          h.messages[-1] and h.opened[-1] == (shop, -1), h.messages[-1:])
    # vim's Enter: a link followed; elsewhere the next line's first letter
    h.lines = ["no link here", "   indented"]
    h.cursor = {"line": 0, "col": 3}
    h.call(enter["cb"], {"count": 1})
    check(tag + "vim's Enter off a link: the next line's first letter", h.cursor == {"line": 1, "col": 3}, h.cursor)
    # a folder of notes outside the project: a note made there is left to save
    elsewhere = os.path.join(h.tmp, "elsewhere")
    os.makedirs(elsewhere)
    open(os.path.join(elsewhere, "Index.md"), "w").write("# Index\n[[Later]]\n")
    h.settings["folder"] = elsewhere
    h.path_ = os.path.join(elsewhere, "Index.md")
    h.lines = ["# Index", "[[Later]]"]
    h.cursor = {"line": 1, "col": 3}
    h.call(c["Wiki: follow the link"]["cb"])
    st = h.others.get(by_path.get(os.path.join(elsewhere, "Later.md")), {})
    check(tag + "a folder outside the project: the note made in a tab, left to save",
          st.get("lines") == ["# Later", "", ""] and not os.path.exists(os.path.join(elsewhere, "Later.md")) and
          "save it to make it" in h.messages[-1], (st, h.messages[-1:]))
