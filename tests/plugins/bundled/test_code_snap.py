"""code-snap: the selected lines (or the whole file) as an SVG picture or an HTML page — a window with a title bar,
line numbers, a monospace font, coloured by code-snap's own lexer (Nim, Python, JS, C; comments, strings and numbers
of others), the indentation they share taken off, tabs as spaces; written to the data folder, beside the file or a
folder of yours, its path said"""
import os
import re
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


DARK = {"keyword": "#c678dd", "type": "#e5c07b", "string": "#98c379", "number": "#d19a66", "comment": "#7f848e",
        "function": "#61afef", "const": "#56b6c2", "meta": "#e06c75"}


def span(kind, text):
    return '<tspan fill="%s"%s>%s</tspan>' % (DARK[kind], ' font-style="italic"' if kind == "comment" else "", text)


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    svg_c, html_c = h.reg("command", title="Code snap: selection as SVG"), h.reg("command", title="Code snap: selection as HTML")
    sets = {k: (h.reg("setting", key=k) or {}).get("default") for k in
            ["folder", "lineNumbers", "theme", "fontSize", "font", "background"]}
    check(tag + "its two commands and settings", svg_c and html_c and sets["folder"] == "data" and
          sets["lineNumbers"] is True and sets["theme"] == "dark" and sets["fontSize"] == 14 and
          sets["font"].endswith("monospace") and sets["background"] == "#d8dee9", sets)
    src = open(os.path.join(os.path.dirname(__file__), "..", "..", "..", "plugins", "code-snap", "plugin.nims")).read()
    check(tag + "it asks to change files (beside the file), saying why", 'permission("files", "' in src, "")
    os.makedirs(os.path.join(h.tmp, "data", "code-snap"), exist_ok=True)

    def snap(lines, lang, sel=None, html=False, path="a.nim", comment="#", indent="  "):
        h.lines = list(lines)
        h.lang = lang
        h.comment = comment
        h.indent_ = indent
        h.path_ = os.path.join(h.tmp, path) if path else ""
        h.sel = sel
        h.cursor = sel["stop"] if sel else pos(0, 0)
        r = h.call((html_c if html else svg_c)["cb"])
        if not r or "err" in r:
            return ("ERR", r)
        m = h.messages[-1]
        f = m[len("Code snap: "):] if m.startswith("Code snap: ") else ""
        return (f, open(f).read() if f and os.path.exists(f) else "")

    nim = ["import std/strutils", "", "  proc greet*(name: string): int {.inline.} =",
           "    ## says hello",
           "    echo \"hi \", name  # a comment",
           "    result = 42 + 0x1F'i32", "", "x = 1"]
    f, t = snap(nim, "nim", rng(2, 0, 6, 0))
    check(tag + "SVG: written in the data folder (snaps/), named after the file and its lines; the path said",
          f == os.path.join(h.tmp, "data", "code-snap", "snaps", "a.nim-L3-6.svg") and t.startswith("<svg xmlns="), f)
    check(tag + "… a window: a title bar with three dots and the file's name, a shadow, the background around it",
          "<title>a.nim</title>" in t and t.count("<circle ") == 3 and 'fill="#ff5f57"' in t and
          'text-anchor="middle"' in t and ">a.nim</text>" in t and "feDropShadow" in t and 'fill="#d8dee9"' in t and
          'fill="#282c34"' in t, t[:600])
    check(tag + "… the lines numbered as in the file (3 … 6: a selection to the start of a line leaves it out)",
          re.findall(r'text-anchor="end" fill="#636d83">(\d+)</text>', t) == ["3", "4", "5", "6"], t)
    check(tag + "… a monospace font, spaces kept", 'font-family="JetBrains Mono, Fira Code' in t and
          'xml:space="preserve"' in t and 'font-size="14"' in t, "")
    code = re.findall(r'<text x="[\d.]+" y="[\d.]+" fill="#abb2bf">(.*?)</text>', t)
    check(tag + "… Nim coloured: proc a keyword, its name a function, string a type, a pragma, a number",
          len(code) == 4 and code[0] == span("keyword", "proc") + " " + span("function", "greet") + "*(name: " +
          span("type", "string") + "): " + span("type", "int") + " " + span("meta", "{.inline.}") + " =", code[:1])
    check(tag + "… a doc comment, echo, a string, a comment in italics",
          code[1] == "  " + span("comment", "## says hello") and
          code[2] == "  " + span("function", "echo") + " " + span("string", "&quot;hi &quot;") + ", name  " +
          span("comment", "# a comment"), code)
    # (the indentation the lines share — two spaces — is taken off: the proc line starts at the left)
    check(tag + "… the indentation they share taken off", code[0].startswith("<tspan"), code[0][:30])
    f, t = snap(["  x = 1", "  result = 0x1F'i32 + 1.5e3"], "nim", rng(0, 0, 1, 26))
    check(tag + "… numbers (with ' and exponents), result as a constant", span("const", "result") in t and
          span("number", "0x1F'i32") in t and span("number", "1.5e3") in t, t[-400:])
    # escaping, the block comment a selection starts in
    f, t = snap(["#[ a block", "comment ]# if a < b and c > d: echo \"&\""], "nim", rng(1, 0, 1, 40))
    check(tag + "… a selection that starts inside a block comment: coloured as one; <, > and & escaped",
          span("comment", "comment ]#") in t and "a &lt; b" in t and "c &gt; d" in t and
          span("string", "&quot;&amp;&quot;") in t and f.endswith("a.nim-L2.svg"), t[-500:])
    # the whole file when nothing is selected; blank lines at the ends left out
    f, t = snap(["", "a = 1", "b = 2", ""], "nim")
    check(tag + "nothing selected: the whole file (its blank lines at the ends left out)",
          f.endswith("a.nim-L2-3.svg") and re.findall(r'text-anchor="end"[^>]*>(\d+)<', t) == ["2", "3"], f)
    # settings: no line numbers, the light theme, no background
    h.settings = {"lineNumbers": False, "theme": "light", "background": "none", "fontSize": 20}
    f, t = snap(["let x = 1"], "nim")
    check(tag + "settings: no line numbers, the light theme, no margin or shadow, the font size",
          'text-anchor="end"' not in t and 'fill="#fafafa"' in t and '<tspan fill="#a626a4">let</tspan>' in t and
          "feDropShadow" not in t and 'font-size="20"' in t and '<rect x="0" y="0"' in t, t[:700])
    h.settings = {}
    # Python, JS, C, another language
    py = ["@dataclass", "class Point(Base):", "    def norm(self, k=2):", '        """Its length,', '        squared"""',
          "        return f\"{self.x}\" if True else None  # why"]
    f, t = snap(py, "python", rng(0, 0, 5, 60), path="p.py")
    check(tag + "Python: a decorator, class and def names, a string of several lines, an f-string, True and None",
          span("meta", "@dataclass") in t and span("keyword", "class") + " " + span("type", "Point") in t and
          span("keyword", "def") + " " + span("function", "norm") + "(" + span("const", "self") in t and
          span("string", "&quot;&quot;&quot;Its length,") in t and span("string", "        squared&quot;&quot;&quot;") in t
          and span("string", "f&quot;{self.x}&quot;") in t and span("const", "True") in t and
          span("comment", "# why") in t, t[-900:])
    js = ["function add(a, b) { // sum", "  const s = `x", "${a}`; return /* no */ a + b", "}"]
    f, t = snap(js, "javascript", rng(0, 0, 3, 1), path="a.js", comment="//")
    check(tag + "JavaScript: function and its name, // and /* */ comments, a template string of two lines",
          span("keyword", "function") + " " + span("function", "add") in t and span("comment", "// sum") in t and
          span("string", "`x") in t and span("string", "${a}`") in t and span("comment", "/* no */") in t and
          span("keyword", "return") in t, t[-700:])
    c = ["#include <stdio.h>", "int main(void) {", "  /* start", "  */ printf(\"%d\\n\", NULL);", "}"]
    f, t = snap(c, "c", rng(0, 0, 4, 1), path="m.c", comment="//")
    check(tag + "C: the preprocessor's line, types, a function, a block comment of two lines, NULL",
          span("meta", "#include &lt;stdio.h&gt;") in t and span("type", "int") + " " + span("function", "main") + "(" +
          span("type", "void") in t and span("comment", "  */") in t and span("function", "printf") in t and
          span("const", "NULL") in t and span("string", "&quot;%d\\n&quot;") in t, t[-700:])
    f, t = snap(["// note", "func main() { s := \"x\" + 1 }"], "go", rng(0, 0, 1, 30), path="m.go", comment="//")
    check(tag + "another language (Go): its comments, strings and numbers only",
          span("comment", "// note") in t and span("string", "&quot;x&quot;") in t and span("number", "1") in t and
          "#c678dd" not in t.split("</title>")[1], t[-500:])
    # tabs
    f, t = snap(["if x:", "\ty = 1"], "python", rng(0, 0, 1, 6), path="t.py", indent="    ")
    check(tag + "tabs as spaces (the file's indentation)", '">    y = ' in t and "\t" not in t, t[-300:])
    # HTML
    f, t = snap(py, "python", rng(1, 0, 2, 25), html=True, path="p.py")
    check(tag + "HTML: a page of its own — the window drawn with CSS, the lines numbered, classes for the colours",
          f.endswith("p.py-L2-3.html") and t.startswith("<!doctype html>") and "<title>p.py</title>" in t and
          ".k { color: #c678dd; }" in t and ".c { color: #7f848e; font-style: italic; }" in t and
          '<span class="ln">2</span><span class="k">class</span> <span class="t">Point</span>' in t and
          '<span class="ln">3</span>    <span class="k">def</span>' in t and 'class="dots"' in t, t[-600:])
    # where it goes: beside the file, a folder of yours
    h.settings = {"folder": "beside"}
    f, t = snap(["x = 1"], "nim", path="src.nim")
    check(tag + "folder beside: next to the file", f == os.path.join(h.tmp, "src.nim-L1.svg") and t.startswith("<svg"),
          f)
    mine = os.path.join(h.tmp, "pics")
    h.settings = {"folder": mine}
    f, t = snap(["x = 1"], "nim", path="src.nim")
    check(tag + "a folder of yours that is not there: said", not os.path.isdir(mine) and
          "there is no folder " + mine in h.messages[-1], h.messages[-1:])
    os.makedirs(mine)
    f, t = snap(["x = 1"], "nim", path="src.nim")
    check(tag + "… one that is: written there", f == os.path.join(mine, "src.nim-L1.svg") and os.path.exists(f), f)
    h.settings = {}
    f, t = snap(["x = 1"], "nim", path="")
    check(tag + "an unsaved tab: named after its tab, in the data folder", f.endswith("snaps/untitled-L1.svg"), f)
    f, t = snap(["", "  "], "nim")
    check(tag + "nothing but blank lines: said", h.messages[-1] == "Code snap: nothing to draw — the lines are empty",
          h.messages[-1:])
