"""regex-lab: a pattern's matches lit up with their groups, the replace (with its count asked first), the explainer,
a pattern that is not one"""
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def asks(h, answers):
    """the next answers of ask(), one per call (the host's own gives one answer to all)"""
    base = h.api
    q = list(answers)

    def api(j, _base=base):
        if j["fn"] == "ask" and q:
            h.asked.append(("ask", j.get("args", {})))
            h.send({"t": "res", "id": j["id"], "value": q.pop(0)})
            return
        return _base(j)
    h.api = api
    return lambda: setattr(h, "api", base)


SAMPLE = ["name = alice, age = 31", "name = bob, age = 4", "no pairs here", "x = 1"]


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok)
    if not ok:
        return
    titles = ["Regex: try a pattern…", "Regex: replace with a pattern…", "Regex: explain the pattern…",
              "Regex: clear the marks"]
    cmds = {t: h.reg("command", title=t) for t in titles}
    check(tag + "its commands", all(cmds.values()), [t for t, c in cmds.items() if not c])
    if not all(cmds.values()):
        return
    # try: every match lit up, a ● on each line with one, the first match's groups after it
    h.lines = list(SAMPLE)
    h.cursor = pos(0, 0)
    h.sel = None
    h.decor = []
    undo = asks(h, [r"(\w+) = (\w+)"])
    h.call(cmds["Regex: try a pattern…"]["cb"])
    undo()
    hl = [a for f, a in h.decor if f == "highlight"]
    signs = sorted(a["line"] for f, a in h.decor if f == "sign")
    vt = {a["line"]: a["text"] for f, a in h.decor if f == "vtext"}
    check(tag + "try: 5 matches lit up, a mark on lines 1, 2 and 4, the groups of each line's first",
          len(hl) == 5 and signs == [0, 1, 3] and vt.get(0) == '1="name"  2="alice"' and vt.get(3) == '1="x"  2="1"',
          (len(hl), signs, vt))
    check(tag + "… how many, in the status bar", h.status.startswith("5 matches of /") and "on 3 lines" in h.status,
          h.status)
    check(tag + "… a match's place: name = alice is line 1, columns 0 to 12",
          hl and hl[0]["range"] == {"start": pos(0, 0), "stop": pos(0, 12)}, hl[:1])
    # a pattern that is not one: said, nothing lit up
    h.decor = []
    h.messages = []
    undo = asks(h, ["(unclosed"])
    h.call(cmds["Regex: try a pattern…"]["cb"])
    undo()
    check(tag + "a pattern that is not one: said so", not [a for f, a in h.decor if f == "highlight"] and
          any("not a regular expression" in m for m in h.messages), h.messages)
    # replace: the count asked, then each match replaced with its groups
    h.lines = list(SAMPLE)
    h.sel = None
    h.answers["confirm"] = True
    h.asked = []
    undo = asks(h, [r"(\w+) = (\w+)", r"$1: $2"])
    h.call(cmds["Regex: replace with a pattern…"]["cb"])
    undo()
    conf = [a for f, a in h.asked if f == "confirm"]
    check(tag + "replace: \"Replace 5 matches?\" asked, then $1 and $2 put in",
          conf and conf[0].get("text") == "Replace 5 matches?" and
          h.lines == ["name: alice, age: 31", "name: bob, age: 4", "no pairs here", "x: 1"], (conf, h.lines))
    # … only the selection
    h.lines = list(SAMPLE)
    h.sel = {"start": pos(1, 0), "stop": pos(1, 19)}
    undo = asks(h, [r"\d+", "N"])
    h.call(cmds["Regex: replace with a pattern…"]["cb"])
    undo()
    check(tag + "replace in the selection only", h.lines[0] == SAMPLE[0] and h.lines[1] == "name = bob, age = N",
          h.lines[:2])
    # … answered no: nothing changes
    h.lines = list(SAMPLE)
    h.sel = None
    h.answers["confirm"] = False
    undo = asks(h, ["a", "b"])
    h.call(cmds["Regex: replace with a pattern…"]["cb"])
    undo()
    check(tag + "replace answered no: the text as it was", h.lines == SAMPLE, h.lines)
    h.answers["confirm"] = True
    # explain: the pattern in the string at the cursor, a piece at a time, in a tab
    h.lines = ['let re = "^(\\d{3})-[a-z]+$"']
    h.cursor = pos(0, 12)
    h.sel = None
    h.tabs = []
    h.call(cmds["Regex: explain the pattern…"]["cb"])
    t = h.tabs[-1][1] if h.tabs else ""
    check(tag + "explain: the string at the cursor, each piece in words",
          t.startswith("/^(\\d{3})-[a-z]+$/") and "the start of a line" in t and "group 1 starts" in t and
          "a digit — 3 times" in t and "one of a–z — once or more" in t and "the end of a line" in t, t)
    h.call(cmds["Regex: clear the marks"]["cb"])
    check(tag + "clear the marks", h.decor == [], h.decor[:3])
