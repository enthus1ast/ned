"""path-complete: the names of a folder completed in a path — in quotes (./ ../ ~/ / and a bare name with a /), on a
Nim import line (modules without .nim), in a Markdown link (a space as %20); folders first with a /, hidden names
only after a dot, the word typed replaced, the setting's cap; nothing outside a path."""
import os, shutil, tempfile
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


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


def touch(*parts):
    p = os.path.join(*parts)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, "w").write("x")


def run(factory, tag):
    # (the host's home folder: one of the test's, for ~/)
    home = tempfile.mkdtemp(prefix="pc-home-")
    try:
        go(factory, tag, home)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def go(factory, tag, home):
    old_home = os.environ.get("HOME")
    touch(home, "notes.txt")
    os.makedirs(os.path.join(home, "Projects"))
    os.environ["HOME"] = home
    try:
        h = start(factory, tag)
    finally:
        if old_home is None:
            del os.environ["HOME"]
        else:
            os.environ["HOME"] = old_home
    if not h:
        return
    proj = os.path.join(h.tmp, "proj")
    touch(proj, "src", "main.nim")
    touch(proj, "src", "my file.txt")
    touch(proj, "src", ".hidden")
    touch(proj, "src", "Utils.nim")
    os.makedirs(os.path.join(proj, "src", "sub"))
    touch(proj, "docs", "guide.md")
    touch(proj, "docs", "Guide two.md")
    touch(proj, "assets", "logo.png")
    for i in range(150):
        touch(proj, "many", "f%03d.txt" % i)
    h.root = proj
    h.path_ = os.path.join(proj, "src", "main.nim")
    h.lang = "nim"
    co = h.reg("completion", lang="*")
    check(tag + "completions for every file, a setting", co is not None and
          h.reg("setting", key="maxEntries")["default"] == 100, h.regs)

    def ask(line, prefix=None, col=None):
        h.lines = [line]
        c = len(line) if col is None else col
        if prefix is None:
            k = c
            while k > 0 and (line[k - 1].isalnum() or line[k - 1] == "_"):
                k -= 1
            prefix = line[k:c]
        r = h.call(co["cb"], {"buf": 1, "pos": pos(0, c), "prefix": prefix})
        return (r or {}).get("value")

    v = ask('const s = staticRead("./')
    check(tag + "./ in a string: the file's folder — folders first with a /, no hidden names, the insert the name",
          [(x["label"], x["insert"], x["kind"]) for x in v] ==
          [("sub/", "sub/", "folder"), ("main.nim", "main.nim", "file"), ("my file.txt", "my file.txt", "file"),
           ("Utils.nim", "Utils.nim", "file")], v)
    v = ask('let p = "./my fi')
    check(tag + "a name with a space: the item goes in for the word typed (fi)",
          [(x["label"], x["insert"]) for x in v] == [("my file.txt", "file.txt")], v)
    v = ask("let p = './.")
    check(tag + "in single quotes; hidden names after a dot", [(x["label"], x["insert"]) for x in v] == [(".hidden", "hidden")], v)
    v = ask('let p = "../docs/gu')
    check(tag + "../: the folder above (any case of the letters typed)",
          [(x["label"], x["insert"]) for x in v] == [("Guide two.md", "Guide two.md"), ("guide.md", "guide.md")], v)
    v = ask('let p = "docs/')
    check(tag + "a bare name with a /: the file's folder when it has it, else the project's",
          [x["label"] for x in v] == ["Guide two.md", "guide.md"], v)
    v = ask('let p = "sub/')
    check(tag + "… the file's folder first (src/sub, empty)", v == [], v)
    v = ask('let p = "~/')
    check(tag + "~/: your home folder", [x["label"] for x in v] == ["Projects/", "notes.txt"], v)
    v = ask('let p = "%s/assets/' % proj)
    check(tag + "/: an absolute path", [x["label"] for x in v] == ["logo.png"], v)
    v = ask("import ./ma")
    v2 = ask("import std/os, ../src/")
    v3 = ask("from ./ut")
    check(tag + "Nim's import lines: folders and modules without .nim (no other files)",
          [(x["label"], x["insert"]) for x in v] == [("main", "main")] and
          [x["label"] for x in v2] == ["sub/", "main", "Utils"] and [x["label"] for x in v3] == ["Utils"], (v, v2, v3))
    h.path_ = os.path.join(proj, "src", "README.md")
    h.lang = "markdown"
    v = ask("See [the guide](../docs/")
    v2 = ask("Don't miss [it](./my%20")
    check(tag + "a Markdown link: the names after ](, a space as %20 (an apostrophe before it is no string)",
          [x["label"] for x in v] == ["Guide%20two.md", "guide.md"] and
          [(x["label"], x["insert"]) for x in v2] == [("my%20file.txt", "20file.txt")], (v, v2))
    h.path_ = ""
    v = ask('x = "./')
    check(tag + "an unsaved file: from the project's folder", [x["label"] for x in v] == ["assets/", "docs/", "many/", "src/"], v)
    h.path_ = os.path.join(proj, "src", "main.nim")
    h.lang = "nim"
    v = ask('let p = "../many/')
    h.settings = {"maxEntries": 20}
    v2 = ask('let p = "../many/')
    h.settings = {}
    check(tag + "a big folder: 100 names at most, maxEntries fewer", len(v) == 100 and len(v2) == 20 and
          v2[0]["label"] == "f000.txt", (len(v), len(v2)))
    none = [ask('let s = "hello wor'), ask("let x = foo"), ask('let p = "./src" & na'), ask('echo "x/', col=6),
            ask('let p = "./nowhere/')]
    check(tag + "nothing outside a path: words in a string, code, after a closed string, before the /, a folder "
          "that is not there", none == [[], [], [], [], []], none)
    # as ned asks while you type in a string or a comment: after ~ ( / with nothing of the name typed yet
    seq = [ask('let p = "~'), ask('let p = "~/'), ask('let p = staticRead('), ask('let p = staticRead("../')]
    check(tag + "asked as you type (after ~ ( /): nothing until there is a folder, then its names",
          seq[0] == [] and [x["label"] for x in seq[1]] == ["Projects/", "notes.txt"] and seq[2] == [] and
          [x["label"] for x in seq[3]] == ["assets/", "docs/", "many/", "src/"], seq)
    h.comment = "#"
    v = ask("x = 1  # see ../docs/")
    v2 = ask('x = "#"  # ./su')
    h.comment = "//"
    h.path_ = os.path.join(proj, "src", "main.c")
    h.lang = "c"
    v3 = ask("int x;  // from ./")
    none = [ask("// https://example.com/"), ask("x = a/b"), ask("y = c;  // a/b")]
    h.comment = "#"
    check(tag + "in a comment (after the language's line comment, not one in a string): the path before the cursor",
          [x["label"] for x in v] == ["Guide two.md", "guide.md"] and [x["label"] for x in v2] == ["sub/"] and
          [x["label"] for x in v3] == ["sub/", "main.nim", "my file.txt", "Utils.nim"] and none == [[], [], []],
          (v, v2, v3, none))
