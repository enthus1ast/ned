"""todo: a project's task list in TODO.md — a task added (from a TODO comment, with its place; due:tomorrow, due:+0,
due:fri written as dates), the list in its order (due, priority, file), done and not done (with the day), archive
under ## Done, the list open in a tab edited there, the status bar, the dock's view, the note at start, due dates
marked in TODO.md, Alt+Enter on a task, due: completed, the settings and keys."""
import os
import time
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


def day(t, plus=0):
    return time.strftime("%Y-%m-%d", time.localtime(t + plus * 86400))


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 90)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    T = int(time.mktime((2026, 10, 26, 12, 0, 0, 0, 0, -1)))     # (a Monday, at noon)
    h.clock = T
    proj = os.path.join(h.tmp, "proj")
    os.makedirs(os.path.join(proj, "src"), exist_ok=True)
    h.root = proj
    todo = os.path.join(proj, "TODO.md")
    picks, asks = [], []
    base = h.api

    def api(j):
        fn = j["fn"]
        if fn == "pick" and picks:
            h.asked.append((fn, j.get("args", {})))
            h.send({"t": "res", "id": j["id"], "value": picks.pop(0)})
        elif fn == "ask" and asks:
            h.asked.append((fn, j.get("args", {})))
            h.send({"t": "res", "id": j["id"], "value": asks.pop(0)})
        else:
            base(j)
    h.api = api

    titles = ["Todo: add a task…", "Todo: the list…", "Todo: done / not done", "Todo: archive the done tasks",
              "Todo: open the list"]
    c = {t: h.reg("command", title=t) for t in titles}
    vk = [h.reg("vimMap", mode="n", keys=k) for k in ("<leader>ta", "<leader>tl", "<leader>tx")]
    view, click = h.reg("view", title="TODO LIST"), h.reg("viewClick", title="TODO LIST")
    sd = {k: (h.reg("setting", key=k) or {}).get("default")
          for k in ("file", "linkHere", "doneDate", "statusBar", "remindAtStart")}
    check(tag + "its commands (add on Alt+Shift+A, the list on Alt+Shift+L), vim's <leader>t keys, a view, Alt+Enter "
          "and completion in Markdown, its settings",
          all(c.values()) and c["Todo: add a task…"]["keys"] == "alt+shift+a" and
          c["Todo: the list…"]["keys"] == "alt+shift+l" and all(vk) and view and click and
          h.reg("codeActions", lang="markdown") and h.reg("completion", lang="markdown") and
          sd == {"file": "TODO.md", "linkHere": False, "doneDate": True, "statusBar": True, "remindAtStart": True},
          ([t for t, v in c.items() if not v], sd))

    def run_(t):
        r = h.call(c[t]["cb"])
        return r and "err" not in r

    def lines():
        return open(todo).read().split("\n") if os.path.exists(todo) else []

    # from a TODO comment: the comment offered, its place added; due:tomorrow written as a date; TODO.md made
    h.path_ = os.path.join(proj, "src", "app.nim")
    h.lang = "nim"
    h.lines = ["proc main() =", "  discard", "  # TODO(ann): handle the errors", "  echo 1"]
    h.cursor = pos(2, 5)
    asks.append("handle the errors due:tomorrow")
    run_("Todo: add a task…")
    a = h.asked[-1]
    check(tag + "add on a TODO comment: its words offered", a[0] == "ask" and a[1].get("default") == "handle the errors",
          a)
    check(tag + "… TODO.md made with the task, due:tomorrow as a date, the comment's place as a link",
          lines() == ["# Tasks", "", "- [ ] handle the errors due:%s → [src/app.nim:3](src/app.nim#L3)" % day(T, 1), ""]
          and h.messages[-1] == "Todo: added — 1 open task in TODO.md" and h.status == "☐ 1", (lines(), h.messages[-1:],
                                                                                               h.status))
    # elsewhere: no place (linkHere off); due:+0 is today; then due:fri — the coming Friday
    h.cursor = pos(0, 2)
    asks.append("(A) write the docs due:+0")
    run_("Todo: add a task…")
    asks.append("ship it due:fri +release")
    run_("Todo: add a task…")
    asks.append("tidy up")
    run_("Todo: add a task…")
    ls = lines()
    check(tag + "more tasks, after the first; the coming Friday; no place (linkHere is off); the status bar: ☐ 4 ⚠ 1 "
          "(one due today)",
          ls[3:6] == ["- [ ] (A) write the docs due:%s" % day(T), "- [ ] ship it due:%s +release" % day(T, 4),
                      "- [ ] tidy up"] and h.status == "☐ 4 ⚠ 1", (ls, h.status))
    # the list: by the day due, then priority, then the file's order
    picks.extend([-1])
    run_("Todo: the list…")
    a = h.asked[-1][1]
    check(tag + "the list: + add, then due today (●), tomorrow, Friday, then the rest; the details: when, the place",
          a.get("items") == ["+ Add a task…", "● (A) write the docs", "☐ handle the errors", "☐ ship it +release",
                             "☐ tidy up"] and
          a.get("details") == ["", "due today", "due tomorrow · src/app.nim:3", "due friday", ""] and
          a.get("title") == "Tasks — 4 open (TODO.md)", a)
    # a task's menu: done (with the day), go to its place
    picks.extend([1, 0])
    run_("Todo: the list…")
    ls = lines()
    check(tag + "done from the list: ticked, with the day", ls[3] == "- [x] (A) write the docs due:%s ✓ %s" % (day(T), day(T))
          and h.status == "☐ 3" and h.messages[-1].startswith("Todo: ✓ done"), (ls, h.status, h.messages[-1:]))
    picks.extend([1, 1])
    run_("Todo: the list…")
    check(tag + "go to its place: the file at the comment's line",
          h.opened[-1] == (os.path.join(proj, "src", "app.nim"), 2), h.opened[-1:])
    # another due date, from the menu
    picks.extend([2, 2])
    asks.append("+10")
    run_("Todo: the list…")
    check(tag + "a due date from the menu: +10 days", lines()[4] == "- [ ] ship it due:%s +release" % day(T, 10),
          lines())
    # the view
    v = [(x["icon"], x["text"], x["detail"]) for x in (h.call(view["cb"]) or {}).get("value") or []]
    check(tag + "the dock's view: add, the open tasks with when, the done ones to move",
          v == [("", "+ add a task", ""), ("☐", "handle the errors", "due tomorrow"),
                ("☐", "ship it +release", "due " + day(T, 10)), ("☐", "tidy up", ""),
                ("✓", "1 done task — move them under ## Done", "")], v)
    # archive
    h.call(click["cb"], {"id": "archive"})
    ls = lines()
    check(tag + "archive: the done task under ## Done at the end",
          ls[-4:] == ["## Done", "", "- [x] (A) write the docs due:%s ✓ %s" % (day(T), day(T)), ""] and
          "- [ ] tidy up" in ls and ls.index("- [ ] tidy up") < ls.index("## Done"), ls)
    asks.append("one more")
    run_("Todo: add a task…")
    ls = lines()
    check(tag + "a task added later goes with the open ones, before ## Done",
          ls.index("- [ ] one more") == ls.index("- [ ] tidy up") + 1, ls)
    # the list open in a tab: edited there (and saved, when it had no other changes)
    h.others[7] = {"lines": lines()[:-1], "path": todo, "lang": "markdown", "cursor": pos(0, 0)}
    before = open(todo).read()
    saved = h.saved
    asks.append("in the tab")
    run_("Todo: add a task…")
    check(tag + "the list open in a tab: the task goes in the tab, which is saved",
          "- [ ] in the tab" in h.others[7]["lines"] and h.saved == saved + 1 and open(todo).read() == before,
          h.others[7]["lines"])
    # done / not done on the cursor's line, in a Markdown file; Alt+Enter offers the same
    h.switch_to(7)
    l = h.lines.index("- [ ] tidy up")
    h.cursor = pos(l, 3)
    run_("Todo: done / not done")
    check(tag + "done / not done: the cursor's task ticked with the day", h.lines[l] == "- [x] tidy up ✓ " + day(T),
          h.lines[l])
    run_("Todo: done / not done")
    check(tag + "… and back (the day taken off)", h.lines[l] == "- [ ] tidy up", h.lines[l])
    ca = h.reg("codeActions", lang="markdown")
    v = (h.call(ca["cb"], {"buf": 7, "range": rng(l, 0, l, 0)}) or {}).get("value") or []
    check(tag + "Alt+Enter on a task: Todo: done ✓, the line ticked",
          len(v) == 1 and v[0]["title"] == "Todo: done ✓" and v[0]["edits"][0]["text"] == "- [x] tidy up ✓ " + day(T), v)
    v = (h.call(ca["cb"], {"buf": 7, "range": rng(0, 0, 0, 0)}) or {}).get("value") or []
    check(tag + "… nothing on another line", v == [], v)
    # due: completed
    co = h.reg("completion", lang="markdown")
    h.lines.append("- [ ] call Bob due:fr")
    n = len(h.lines) - 1
    v = (h.call(co["cb"], {"buf": 7, "pos": pos(n, len(h.lines[n])), "prefix": "fr"}) or {}).get("value") or []
    got = {x["label"]: x["insert"] for x in v}
    check(tag + "after due: the days completed — friday is the coming one, tomorrow, in a week",
          got.get("friday") == day(T, 4) and got.get("tomorrow") == day(T, 1) and got.get("week") == day(T, 7) and
          got.get("month") == "2026-11-26", got)
    h.lines[n] = "- [ ] call Bob"
    v = (h.call(co["cb"], {"buf": 7, "pos": pos(n, 8), "prefix": "Bo"}) or {}).get("value")
    check(tag + "… nothing elsewhere", not v, v)
    # due dates marked in TODO.md
    h.decor = []
    h.call(h.reg("event", event="open", pattern="*")["cb"], {"buf": 7, "path": todo, "lang": "markdown"})
    marks = [(d[1]["line"], d[1]["text"], d[1]["color"]) for d in h.decor if d[0] == "vtext"]
    check(tag + "TODO.md: after each due date, how far it is", (h.lines.index(
        "- [ ] handle the errors due:%s → [src/app.nim:3](src/app.nim#L3)" % day(T, 1)), "tomorrow", "info") in marks and
        any(m[1] == "in 10 days" for m in marks), marks)
    # three days later: a note at start
    h.clock = T + 3 * 86400
    h.messages = []
    h.call(h.reg("event", event="startup")["cb"], {"buf": 7})
    check(tag + "at start, days later: a note — overdue", h.messages[-1:] == [
        "Todo: 1 task overdue — Alt+Shift+L lists them"] and h.status.startswith("☐") and "⚠ 1" in h.status,
        (h.messages, h.status))
    # the plugin may not write files and the list is not open: it goes in a tab to save
    h.switch_to(1)
    del h.others[7]
    h.allowed = set()
    h.clock = T
    asks.append("not written")
    before = open(todo).read()
    run_("Todo: add a task…")
    check(tag + "not allowed to write files: the list opened in a tab with the task, the file as it was",
          h.opened[-1][0] == todo and "- [ ] not written" in h.lines and open(todo).read() == before and
          any("in a tab" in m for m in h.messages[-2:]), (h.opened[-1:], h.messages[-2:]))
