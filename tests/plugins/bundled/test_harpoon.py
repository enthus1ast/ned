"""harpoon: pin a project's files and jump to them — add, the list (pick, remove, move up, clear), go to 1 … 4, next and
previous, the line each one opens at, the view in the Plugins dock, the size setting, a list per project kept on disk"""
import json
import os
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def drive(h, proj):
    """ned's side for harpoon: openFile switches the current file (its path, the cursor at the line); pick answers
    from h.picks one after the other"""
    h.root = proj
    h.picks = []
    h.opens = []
    base = h.api

    def api(j):
        fn, a = j["fn"], j.get("args", {})
        if fn == "open":
            h.opens.append((a["path"], a["line"]))
            h.path_ = a["path"]
            h.cursor = pos(max(0, a["line"]), 0)
            h.send({"t": "res", "id": j["id"], "value": h.cur})
        elif fn == "pick" and h.picks:
            h.asked.append((fn, a))
            h.send({"t": "res", "id": j["id"], "value": h.picks.pop(0)})
        else:
            base(j)
    h.api = api
    os.makedirs(os.path.join(h.tmp, "data", "harpoon"), exist_ok=True)   # (ned makes the data folder)


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    proj = os.path.join(h.tmp, "proj")
    os.makedirs(os.path.join(proj, "src"))
    for f in ["a.nim", "src/b.nim", "c.nim", "d.nim", "e.nim"]:
        open(os.path.join(proj, f), "w").write("x\n" * 20)
    drive(h, proj)
    P = lambda f: os.path.join(proj, f)
    titles = ["Harpoon: add this file", "Harpoon: the list…", "Harpoon: next", "Harpoon: previous",
              "Harpoon: remove this file", "Harpoon: remove a file…", "Harpoon: move a file up…",
              "Harpoon: clear the list"] + ["Harpoon: go to %d" % i for i in range(1, 5)]
    c = {t: h.reg("command", title=t) for t in titles}
    vk = {k: h.reg("vimMap", mode="n", keys=k) for k in ["<leader>a", "<leader>h", "<leader>1", "<leader>2",
                                                         "<leader>3", "<leader>4"]}
    view, click = h.reg("view", title="Harpoon"), h.reg("viewClick", title="Harpoon")
    check(tag + "its commands (the list on Alt+Shift+H), vim's <leader> keys, a view, the size setting",
          all(c.values()) and c["Harpoon: the list…"]["keys"] == "alt+shift+h" and all(vk.values()) and view and click
          and h.reg("setting", key="size")["default"] == 4 and h.reg("event", event="enter") and
          h.reg("event", event="save") and h.reg("event", event="quit") and not h.reg("event", event="change"),
          [t for t, v in c.items() if not v])

    def run_(t):
        r = h.call(c[t]["cb"])
        return r and "err" not in r

    def items():
        return [(x["text"], x["detail"], x["icon"], x["id"]) for x in (h.call(view["cb"]) or {}).get("value") or []]

    data = os.path.join(h.tmp, "data", "harpoon", "harpoon.json")
    h.path_ = P("a.nim")
    h.cursor = pos(3, 0)
    check(tag + "the view with no files: how to add one", [i[0] for i in items()][:1] == ["+ add a.nim"], items())
    run_("Harpoon: add this file")
    saved = json.load(open(data)) if os.path.exists(data) else {}
    check(tag + "add this file: number 1, kept in the data folder under the project (its path from there, its line)",
          h.messages[-1] == "Harpoon: a.nim is number 1" and saved == {proj: [{"path": "a.nim", "line": 3}]} and
          "refreshView" in h.calls_seen, (h.messages[-1:], saved))
    h.call(vk["<leader>a"]["cb"], {"count": 1})
    check(tag + "<leader>a on a file in the list: it says which number it is", h.messages[-1] == "Harpoon: a.nim is number 1 already",
          h.messages[-1:])
    h.path_ = ""
    run_("Harpoon: add this file")
    check(tag + "a tab that is not a file: save it first", "save it first" in h.messages[-1], h.messages[-1:])
    for f, l in [("src/b.nim", 0), ("c.nim", 5), ("d.nim", 7)]:
        h.path_ = P(f)
        h.cursor = pos(l, 0)
        run_("Harpoon: add this file")
    h.path_ = P("e.nim")
    run_("Harpoon: add this file")
    check(tag + "four files: the list is full (the size setting)", "the list is full (4 files)" in h.messages[-1],
          h.messages[-1:])
    h.path_ = P("d.nim")
    h.cursor = pos(9, 0)
    check(tag + "the view: number, name, folder and line; the file you are in marked; a tap's id",
          items() == [("1  a.nim", "line 4", "○", "0"), ("2  b.nim", "src · line 1", "○", "1"),
                      ("3  c.nim", "line 6", "○", "2"), ("4  d.nim", "line 8", "●", "3")], items())
    run_("Harpoon: go to 1")
    saved = json.load(open(data))[proj]
    check(tag + "go to 1: a.nim opened at its line — and d.nim's line (where the cursor was) remembered",
          h.opens[-1] == (P("a.nim"), 3) and saved[3] == {"path": "d.nim", "line": 9}, (h.opens[-1:], saved))
    run_("Harpoon: next")
    o1 = h.opens[-1]
    run_("Harpoon: previous")
    run_("Harpoon: previous")
    o2 = h.opens[-1]
    check(tag + "next and previous go round the list: a → b; b → a → d", o1 == (P("src/b.nim"), 0) and
          o2 == (P("d.nim"), 9), (o1, o2))
    h.call(vk["<leader>3"]["cb"], {"count": 1})
    check(tag + "<leader>3: the third", h.opens[-1] == (P("c.nim"), 5), h.opens[-1:])
    h.call(click["cb"], {"id": "1"})
    check(tag + "a tap in the view: that file", h.opens[-1] == (P("src/b.nim"), 0), h.opens[-1:])
    # the list
    h.picks = [0]
    run_("Harpoon: the list…")
    a = h.asked[-1][1]
    check(tag + "the list: its files (the one you are in marked), then remove, move up, clear; a pick opens it",
          a["items"] == ["1  a.nim", "2  b.nim  ●", "3  c.nim", "4  d.nim", "Remove a file from the list…",
                         "Move a file up…", "Clear the list"] and a["details"][1] == "src · line 1" and
          a["title"] == "Harpoon — 4 of 4 files" and h.opens[-1] == (P("a.nim"), 3), (a, h.opens[-1:]))
    h.picks = [5, 2]
    run_("Harpoon: the list…")
    check(tag + "… move a file up: c.nim is number 2", [p["path"] for p in json.load(open(data))[proj]] ==
          ["a.nim", "c.nim", "src/b.nim", "d.nim"] and h.messages[-1] == "Harpoon: c.nim is number 2 now",
          (json.load(open(data))[proj], h.messages[-1:]))
    h.picks = [4, 3]
    run_("Harpoon: the list…")
    check(tag + "… remove a file: d.nim is out", [p["path"] for p in json.load(open(data))[proj]] ==
          ["a.nim", "c.nim", "src/b.nim"] and "d.nim is out" in h.messages[-1], h.messages[-1:])
    h.path_ = P("e.nim")
    h.cursor = pos(2, 0)
    h.picks = [3]
    run_("Harpoon: the list…")
    check(tag + "… with room in it, + Add this file (the file you are in)", h.asked[-1][1]["items"][3] == "+ Add this file"
          and [p["path"] for p in json.load(open(data))[proj]][-1] == "e.nim", h.asked[-1][1]["items"])
    h.picks = [0]
    run_("Harpoon: move a file up…")
    check(tag + "move a file up… on the first: it is first already", "first already" in h.messages[-1], h.messages[-1:])
    run_("Harpoon: remove this file")
    check(tag + "remove this file", [p["path"] for p in json.load(open(data))[proj]] == ["a.nim", "c.nim", "src/b.nim"],
          json.load(open(data))[proj])
    run_("Harpoon: remove this file")
    check(tag + "… a file not in the list: says so", h.messages[-1] == "Harpoon: this file is not in the list",
          h.messages[-1:])
    # the line each one opens at: another tab comes to the front, a save, ned quits
    enter, quit_ = h.reg("event", event="enter")["cb"], h.reg("event", event="quit")["cb"]
    line_of = lambda f: [p["line"] for p in json.load(open(data))[proj] if p["path"] == f][0]
    h.path_ = P("c.nim")
    h.cursor = pos(12, 0)
    h.call(enter, {"buf": 1, "path": P("c.nim"), "lang": "nim"})
    h.others[2] = {"lines": ["y"] * 5, "path": P("e.nim"), "lang": "nim", "cursor": pos(3, 0)}
    h.switch_to(2)
    h.calls_seen = []
    h.call(enter, {"buf": 2, "path": P("e.nim"), "lang": "nim"})
    l1 = line_of("c.nim")
    v = items()
    check(tag + "another tab in front: the line of the file left is remembered, and the view's ● follows",
          l1 == 12 and "refreshView" in h.calls_seen and all(i[2] == "○" for i in v[:3]) and
          v[3][0] == "+ add e.nim", (l1, h.calls_seen, v))
    h.others[1]["cursor"] = pos(14, 0)
    h.call(h.reg("event", event="save")["cb"], {"buf": 1, "path": P("c.nim"), "lang": "nim"})
    l2 = line_of("c.nim")
    h.call(quit_, {})
    check(tag + "a save remembers it too; quitting in a file not in the list changes nothing",
          l2 == 14 and len(json.load(open(data))[proj]) == 3, json.load(open(data))[proj])
    h.switch_to(1)
    h.cursor = pos(16, 0)
    h.call(quit_, {})
    h.others[2]["path"] = ""
    h.call(enter, {"buf": 2, "path": "", "lang": "plaintext"})
    h.call(enter, {"buf": 1, "path": P("c.nim"), "lang": "nim"})
    del h.others[2]
    check(tag + "ned quitting in a file of the list: its line remembered (a tab that is not a file is no trouble)",
          line_of("c.nim") == 16, json.load(open(data))[proj])
    os.remove(P("c.nim"))
    run_("Harpoon: go to 2")
    check(tag + "a file that is not there any more: says so", "not there any more" in h.messages[-1], h.messages[-1:])
    run_("Harpoon: go to 4")
    check(tag + "go to 4 with three files: says so", h.messages[-1] == "Harpoon: there is no file 4 — the list has 3",
          h.messages[-1:])
    # another project: its own list; the size setting
    other = os.path.join(h.tmp, "other")
    os.makedirs(other)
    open(os.path.join(other, "x.nim"), "w").write("x\n")
    open(os.path.join(other, "y.nim"), "w").write("x\n")
    h.root = other
    h.settings = {"size": 1}
    h.path_ = os.path.join(other, "x.nim")
    h.cursor = pos(0, 0)
    h.call(click["cb"], {"id": "add"})
    h.path_ = os.path.join(other, "y.nim")
    run_("Harpoon: add this file")
    allp = json.load(open(data))
    check(tag + "another project has its own list; the size setting (1): full after one; + add in the view",
          allp[other] == [{"path": "x.nim", "line": 0}] and len(allp[proj]) == 3 and "full (1 file)" in h.messages[-1],
          (allp, h.messages[-1:]))
    h.settings = {}
    h.root = proj
    h.answers["confirm"] = False
    run_("Harpoon: clear the list")
    n1 = len(json.load(open(data))[proj])
    h.answers["confirm"] = True
    run_("Harpoon: clear the list")
    check(tag + "clear the list: asked first (no: it stays)", n1 == 3 and json.load(open(data))[proj] == [] and
          h.asked[-1][0] == "confirm", (n1, h.asked[-1:]))
    run_("Harpoon: next")
    check(tag + "next with no files: says how to add one", "no files in the list yet" in h.messages[-1], h.messages[-1:])
    # kept on disk: a new start of the plugin reads it
    h2 = factory()
    if not h2.build_ok:
        check(tag + "a second host compiles", False, h2.build_err)
        return
    h2.tmp = h.tmp                              # (the same data folder)
    ok = h2.pump(lambda j: j.get("t") == "ready", 60)
    drive(h2, other)
    h2.path_ = os.path.join(other, "y.nim")
    h2.call(h2.reg("command", title="Harpoon: go to 1")["cb"])
    check(tag + "the lists are kept: after a new start, go to 1 of the other project", ok and
          h2.opens == [(os.path.join(other, "x.nim"), 0)], h2.opens)
