"""examples-to-tests: a module's runnableExamples — a routine's two (one with flags), one over a header of several
lines, the module's own, a single-line one, a routine without — turned into tests/t<module>.nim beside the .nimble:
the routine at the cursor, then the whole file (the examples' imports at the top, once), a routine's blocks made again
in place, the unittest style; the test file run with nim r (it passes); nothing to do said"""
import os, shutil, subprocess
from tplugins import check

MODULE = """## Small things.
runnableExamples:
  import std/strutils
  doAssert "ab".repeat(2) == "abab"

proc double*(x: int): int =
  ## twice x
  runnableExamples:
    doAssert double(2) == 4
    let y = double(-1)

    doAssert y == -2
  runnableExamples("-d:release"):
    doAssert double(0) == 0
  x * 2

func greet*(name: string,
            loud = false): string =
  runnableExamples:
    import std/strutils
    doAssert greet("ann").startsWith("hello")
  result = "hello " & name

proc noExamples*() = discard

template twice*(body: untyped) =
  runnableExamples: twice(echo "hi")
  body
  body
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
    one, whole = h.reg("command", title="Examples to tests: this routine"), \
        h.reg("command", title="Examples to tests: the whole file")
    sd = {k: (h.reg("setting", key=k) or {}).get("default") for k in ("folder", "style")}
    check(tag + "its two commands and its settings", one and whole and sd == {"folder": "tests", "style": "block"}, sd)
    if not (one and whole):
        return
    proj = os.path.join(h.tmp, "proj")
    os.makedirs(os.path.join(proj, "src"))
    open(os.path.join(proj, "mathx.nimble"), "w").write("version = \"0.1.0\"\nsrcDir = \"src\"\n")
    src = os.path.join(proj, "src", "mathx.nim")
    open(src, "w").write(MODULE)
    h.root = proj
    h.path_ = src
    h.lines = MODULE.rstrip("\n").split("\n")
    test = os.path.join(proj, "tests", "tmathx.nim")
    # (ned's side: opening a file gives a tab of its own — empty for a new file — and saving it writes it)
    base = h.api
    opened = []

    def api(j):
        fn, a = j["fn"], j.get("args", {})
        if fn == "open":
            p = a["path"]
            opened.append(p)
            text = open(p).read() if os.path.exists(p) else ""
            h.others[50] = {"lines": text.split("\n"), "path": p, "lang": "nim"}
            h.send({"t": "res", "id": j["id"], "value": 50})
        elif fn == "save" and a.get("buf") == 50:
            st = h.others[50]
            os.makedirs(os.path.dirname(st["path"]), exist_ok=True)
            open(st["path"], "w").write("\n".join(st["lines"]))
            h.send({"t": "res", "id": j["id"], "value": True})
        else:
            base(j)
    h.api = api

    def test_text():
        return open(test).read() if os.path.exists(test) else ""

    # nothing to do
    h.cursor = {"line": 23, "col": 0}            # (noExamples)
    h.call(one["cb"])
    check(tag + "a routine without examples: said, nothing written", "noExamples has no runnableExamples" in
          h.messages[-1] and not os.path.exists(test), h.messages[-1:])
    h.cursor = {"line": 0, "col": 0}
    h.call(one["cb"])
    check(tag + "outside a routine (not on the module's examples): said", "put the cursor in a routine" in
          h.messages[-1], h.messages[-1:])
    # the routine at the cursor: its two examples, one with flags
    h.cursor = {"line": 10, "col": 4}
    h.call(one["cb"])
    t = test_text()
    check(tag + "the routine at the cursor: tests/tmathx.nim beside the .nimble, importing the module, a block for "
          "each example (its flags said)",
          opened[-1:] == [test] and t.startswith("## Tests made from the runnableExamples of src/mathx.nim") and
          "\nimport ../src/mathx\n" in t and "\nblock double_example:\n  doAssert double(2) == 4\n  let y = double(-1)\n\n"
          "  doAssert y == -2\n" in t and "# (its examples are run with -d:release: run this file with them too)\n"
          "block double_example_2:\n  doAssert double(0) == 0\n" in t and "greet" not in t, t)
    check(tag + "said where, and how to run it", "2 examples of double in tests/tmathx.nim" in h.messages[-1] and
          "nim r tests/tmathx.nim" in h.messages[-1], h.messages[-1:])
    # the whole file: the module's, greet's (its header over two lines), the single-line one; imports once at the top
    h.call(whole["cb"])
    t = test_text()
    check(tag + "the whole file: every example; the examples' imports at the top, once; the blocks of double not "
          "made twice",
          t.count("import std/strutils") == 1 and t.index("import std/strutils") < t.index("# ── ") and
          "block module_example:\n  doAssert \"ab\".repeat(2) == \"abab\"\n" in t and
          "block greet_example:\n  doAssert greet(\"ann\").startsWith(\"hello\")\n" in t and
          "block twice_example:\n  twice(echo \"hi\")\n" in t and t.count("block double_example:") == 1, t)
    nim = shutil.which("nim")
    if nim:
        r = subprocess.run([nim, "r", "--hints:off", "--nimcache:" + os.path.join(h.tmp, "nc"), test],
                           cwd=proj, capture_output=True, text=True, timeout=300)
        check(tag + "the test file compiles and passes (nim r)", r.returncode == 0, (r.stdout + r.stderr)[-800:])
    # made again: a routine's blocks take the place of the ones before, the others stay where they are
    h.lines[8] = "    doAssert double(3) == 6"
    h.cursor = {"line": 6, "col": 0}
    order = [l for l in test_text().split("\n") if l.startswith("# ── ")]
    h.call(one["cb"])
    t = test_text()
    check(tag + "made again: double's blocks replaced in their place, the rest kept",
          "doAssert double(3) == 6" in t and "doAssert double(2) == 4" not in t and t.count("block double_example:") == 1 and
          [l.split(" — ")[0] for l in t.split("\n") if l.startswith("# ── ")] == [l.split(" — ")[0] for l in order], t)
    # the unittest style
    h.settings["style"] = "unittest"
    os.remove(test)
    h.cursor = {"line": 20, "col": 4}
    h.call(one["cb"])
    t = test_text()
    check(tag + "the unittest style: std/unittest imported, a test for each",
          "\nimport std/unittest\n" in t and "\ntest \"greet\":\n  doAssert greet(\"ann\").startsWith(\"hello\")\n" in t,
          t)
    if nim:
        r = subprocess.run([nim, "r", "--hints:off", "--nimcache:" + os.path.join(h.tmp, "nc2"), test],
                           cwd=proj, capture_output=True, text=True, timeout=300)
        check(tag + "… and it passes", r.returncode == 0 and "[OK] greet" in r.stdout, (r.stdout + r.stderr)[-800:])
    # on the module's own examples
    h.settings["style"] = "block"
    h.cursor = {"line": 2, "col": 2}
    h.call(one["cb"])
    check(tag + "the cursor on the module's runnableExamples: the module's", "1 example of the module" in
          h.messages[-1], h.messages[-1:])
