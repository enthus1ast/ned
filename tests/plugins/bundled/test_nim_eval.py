"""nim-eval: the selection (or the line) run with nim r — the file's imports with it, an expression echoed, the first
line of what it prints after it, an error on its own line; as NimScript with nim e"""
import shutil
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok)
    if not ok:
        return
    ev = h.reg("command", title="Nim: evaluate the selection")
    es = h.reg("command", title="Nim: evaluate the selection as NimScript")
    cl = h.reg("command", title="Nim: clear the results")
    check(tag + "its commands", ev and es and cl)
    if not (ev and es and cl) or not shutil.which("nim"):
        check(tag + "(no nim on PATH: the runs left out)", True)
        return

    def vt():
        return [(a["line"], a["text"], a.get("color")) for f, a in h.decor if f == "vtext"]

    # an expression on the cursor's line: echoed, its value after it — the file's import is there
    h.lines = ["import std/strutils", "", "let x = 3", "\"a,b,c\".split(',').len", "echo 1"]
    h.cursor = pos(3, 2)
    h.sel = None
    h.decor = []
    h.call(ev["cb"], timeout=120)
    check(tag + "the cursor's line, an expression: its value after it (→ 3), with the file's imports", vt() ==
          [(3, "→ 3", "hint")], vt())
    # several lines, indented (a piece of a proc's body): run as they are, what they print
    h.lines = ["proc f() =", "  for i in 1..3:", "    echo i * i", "", "x"]
    h.sel = {"start": pos(1, 0), "stop": pos(3, 0)}
    h.decor = []
    h.output = []
    h.call(ev["cb"], timeout=120)
    check(tag + "a selection of indented lines: run, the first line printed after it, all of it in Output",
          vt() == [(2, "→ 1", "hint")] and any("1\n4\n9" in o for o in h.output), (vt(), h.output[-1:]))
    # an error: on the line of the selection it is on
    h.lines = ["let a = 1", "let b: string = a", "echo b"]
    h.sel = {"start": pos(0, 0), "stop": pos(2, 6)}
    h.decor = []
    h.call(ev["cb"], timeout=120)
    v = vt()
    check(tag + "an error: on its own line (2), the compiler's words", v and v[0][0] == 1 and v[0][1].startswith(
        "✗ Error: type mismatch") and v[0][2] == "error", v)
    # NimScript
    h.lines = ["echo \"from nim e\""]
    h.sel = None
    h.cursor = pos(0, 0)
    h.decor = []
    h.call(es["cb"], timeout=120)
    check(tag + "as NimScript: nim e", vt() == [(0, "→ from nim e", "hint")], vt())
    h.call(cl["cb"])
    check(tag + "clear the results", h.decor == [], h.decor)
