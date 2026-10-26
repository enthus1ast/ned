"""doc-gen: a doc comment for the routine at the cursor or the next one — Nim (## lines; an iterator yields; a body on
the signature's line moved under it; a declaration), Python (the three styles; self left out; a generator; a
result found in the body), JavaScript (JSDoc with {*}; a destructured parameter; an arrow; a constructor),
TypeScript (no types; void), C (Doxygen; a function pointer; a call is not a routine), C++ (above a template line;
a constructor), Go (named after the routine; a method), Rust (# Arguments, # Returns; above an attribute; &self
left out). The first placeholder selected; nothing written over a comment there already; the quick fix; the
placeholder setting; a language it does not know."""
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    cmd = h.reg("command", title="Doc: write a doc comment")
    langs = ["nim", "python", "javascript", "typescript", "c", "cpp", "go", "rust"]
    fixes = {l: h.reg("codeActions", lang=l) for l in langs}
    check(tag + "its command, a quick fix for each language, its two settings, the ned it needs",
          cmd and all(fixes.values()) and h.reg("setting", key="placeholder")["default"] == "…" and
          h.reg("setting", key="pythonStyle")["default"] == "google" and h.reg("requires")["spec"] == ">= 6.29",
          [l for l, v in fixes.items() if not v])
    if not cmd:
        return

    def doc(lang, lines, line, col=0, unit="  "):
        h.lang = lang
        h.lines = list(lines)
        h.cursor = pos(line, col)
        h.sel = None
        h.indent_ = unit
        r = h.call(cmd["cb"])
        return r and "err" not in r

    # Nim
    NIM = ["import std/strutils", "",
           "proc add*(a, b: int; c = 2): int =",            # 2
           "  result = a + b + c", "",
           "iterator countTo(n: int): int =",                # 5
           "  for i in 0 ..< n: yield i", "",
           "proc twice(x: int): int = x * 2", "",           # 8
           "proc documented(x: int) =",                      # 10
           "  ## already here", "  echo x", "",
           "proc forward(x: int): string",                   # 14
           "proc `$`*(p: Point): string {.inline.} =",       # 15
           "    $p.x"]
    doc("nim", NIM, 2, 5)
    check(tag + "Nim: ## lines under the signature — what it does, each parameter, the result",
          h.lines[2:11] == ["proc add*(a, b: int; c = 2): int =", "  ## …", "  ##", "  ## - `a`: …", "  ## - `b`: …",
                            "  ## - `c`: …", "  ##", "  ## Returns …", "  result = a + b + c"], h.lines[2:11])
    check(tag + "… the first … selected, to type over", h.sel == rng(3, 5, 3, 8), h.sel)
    lines = list(h.lines)
    doc("nim", lines, 0)
    check(tag + "… again (the cursor above it: the next routine is add): nothing written, it says why",
          h.lines == lines and h.messages[-1] == "Doc: add has a doc comment already (line 3)", h.messages[-1:])
    doc("nim", NIM, 6)
    check(tag + "Nim: the cursor in a body: the next routine below (twice); its body moved under the comment",
          h.lines[8:15] == ["proc twice(x: int): int =", "  ## …", "  ##", "  ## - `x`: …", "  ##", "  ## Returns …",
                            "  x * 2"], h.lines[8:15])
    doc("nim", NIM, 5)
    check(tag + "Nim: an iterator yields", h.lines[5:12] == ["iterator countTo(n: int): int =", "  ## …", "  ##",
                                                             "  ## - `n`: …", "  ##", "  ## Yields …",
                                                             "  for i in 0 ..< n: yield i"], h.lines[5:12])
    doc("nim", NIM, 10)
    check(tag + "Nim: a doc comment there already: nothing written",
          h.lines == NIM and h.messages[-1] == "Doc: documented has a doc comment already (line 11)", h.messages[-1:])
    doc("nim", NIM, 14)
    check(tag + "Nim: a declaration (no body): the comment under it, indented",
          h.lines[14:21] == ["proc forward(x: int): string", "  ## …", "  ##", "  ## - `x`: …", "  ##",
                             "  ## Returns …", "proc `$`*(p: Point): string {.inline.} ="], h.lines[14:21])
    doc("nim", NIM, 15)
    check(tag + "Nim: an operator's name, a pragma, the body's own indentation",
          h.lines[15:22] == ["proc `$`*(p: Point): string {.inline.} =", "    ## …", "    ##", "    ## - `p`: …",
                             "    ##", "    ## Returns …", "    $p.x"], h.lines[15:])

    # Python
    PY = ["class Shop:",
          "    def total(self, items, *, tax: float = 0.2) -> float:",   # 1
          "        return sum(items) * (1 + tax)", "",
          "    def log(self, msg):",                                    # 4
          "        print(msg)", "",
          "def gen(n):",                                                # 7
          "    for i in range(n):", "        yield i", "",
          "def find(xs, x, *args, **kw):",                              # 11
          "    for i, y in enumerate(xs):", "        if y == x:", "            return i", "    return None", "",
          "def one(): return 1",                                        # 17
          "def documented():", "    '''Here.'''"]
    doc("python", PY, 1, unit="    ")
    check(tag + "Python: a docstring (Args, Returns) under the def, self and * left out",
          h.lines[1:12] == ["    def total(self, items, *, tax: float = 0.2) -> float:", '        """…', "",
                            "        Args:", "            items: …", "            tax: …", "",
                            "        Returns:", "            …", '        """', "        return sum(items) * (1 + tax)"],
          h.lines[1:12])
    check(tag + "… the first … selected", h.sel == rng(2, 11, 2, 14), h.sel)
    doc("python", PY, 4, unit="    ")
    check(tag + "Python: no result (it returns nothing): no Returns",
          h.lines[4:10] == ["    def log(self, msg):", '        """…', "", "        Args:", "            msg: …",
                            '        """'], h.lines[4:10])
    doc("python", PY, 7, unit="    ")
    check(tag + "Python: a generator yields",
          h.lines[7:16] == ["def gen(n):", '    """…', "", "    Args:", "        n: …", "", "    Yields:", "        …",
                            '    """'], h.lines[7:16])
    doc("python", PY, 11, unit="    ")
    check(tag + "Python: a result found in the body (return i); *args and **kw",
          h.lines[11:22] == ["def find(xs, x, *args, **kw):", '    """…', "", "    Args:", "        xs: …", "        x: …",
                             "        *args: …", "        **kw: …", "", "    Returns:", "        …"], h.lines[11:24])
    doc("python", PY, 17, unit="    ")
    check(tag + "Python: a body on the def's line goes under the docstring",
          h.lines[17:23] == ["def one():", '    """…', "", "    Returns:", "        …", '    """'] and
          h.lines[23] == "    return 1", h.lines[17:25])
    doc("python", PY, 18, unit="    ")
    check(tag + "Python: a docstring there already (''')", h.lines == PY and "has a doc comment already" in h.messages[-1],
          h.messages[-1:])
    h.settings["pythonStyle"] = "sphinx"
    doc("python", PY, 1, unit="    ")
    check(tag + "Python, the sphinx style: :param x: and :returns:",
          h.lines[2:7] == ['        """…', "", "        :param items: …", "        :param tax: …", "        :returns: …"],
          h.lines[1:9])
    h.settings["pythonStyle"] = "numpy"
    doc("python", PY, 1, unit="    ")
    check(tag + "Python, the numpy style: Parameters and Returns under dashes",
          h.lines[2:14] == ['        """…', "", "        Parameters", "        ----------", "        items",
                            "            …", "        tax", "            …", "", "        Returns", "        -------",
                            "        …"], h.lines[1:16])
    del h.settings["pythonStyle"]

    # JavaScript
    JS = ["export async function fetchUser(id, { cache = true } = {}) {",    # 0
          "  const r = await fetch(url + id);", "  return r.json();", "}", "",
          "const double = (x) => x * 2;",                                    # 5
          "",
          "class Cart {",                                                    # 7
          "  constructor(items) {", "    this.items = items;", "  }",
          "  add(item, count = 1) {",                                        # 11
          "    this.items.push(item);", "  }", "}"]
    doc("javascript", JS, 0)
    check(tag + "JavaScript: JSDoc above it ({*} for the types), a destructured parameter as param1, @returns",
          h.lines[:7] == ["/**", " * …", " *", " * @param {*} id …", " * @param {*} param1 …", " * @returns …", " */"] and
          h.lines[7] == JS[0] and h.sel == rng(1, 3, 1, 6), (h.lines[:8], h.sel))
    doc("javascript", JS, 5)
    check(tag + "JavaScript: an arrow with an expression returns it",
          h.lines[5:11] == ["/**", " * …", " *", " * @param {*} x …", " * @returns …", " */"], h.lines[5:12])
    doc("javascript", JS, 9)
    check(tag + "JavaScript: the cursor in a constructor's body: the next method (add) — no result, at its indentation",
          h.lines[11:16] == ["  /**", "   * …", "   *", "   * @param {*} item …", "   * @param {*} count …"] and
          h.lines[16:18] == ["   */", "  add(item, count = 1) {"], h.lines[11:18])
    doc("javascript", JS, 8)
    check(tag + "JavaScript: a constructor: no @returns",
          h.lines[8:13] == ["  /**", "   * …", "   *", "   * @param {*} items …", "   */"], h.lines[8:14])

    # TypeScript
    TS = ["export function parse(text: string, opts?: Options): Result<Item[], Error> {",
          "  helper(text);", "  return ok(text);", "}", "", "class A {",
          "  @Log()",
          "  private log(msg: string, level: Map<string, number>): void {", "  }", "}"]
    doc("typescript", TS, 0)
    check(tag + "TypeScript: no types in the JSDoc (the signature has them), a generic result",
          h.lines[:6] == ["/**", " * …", " *", " * @param text …", " * @param opts …", " * @returns …"], h.lines[:8])
    doc("typescript", TS, 1)
    check(tag + "TypeScript: a call (helper(text);) is no routine: the next one, above its decorator; void: no @returns",
          h.lines[6:13] == ["  /**", "   * …", "   *", "   * @param msg …", "   * @param level …", "   */", "  @Log()"],
          h.lines[5:14])

    # C and C++
    C = ["#include <stdio.h>", "",
         "static const char *greet(const char *name, int times);",          # 2
         "",
         "int main(int argc, char **argv) {",                              # 4
         "    printf(\"%s\\n\", greet(\"x\", 1));",                        # 5
         "    return 0;", "}", "",
         "void each(int (*fn)(int), size_t n, int values[]);"]              # 9
    doc("c", C, 2)
    check(tag + "C: Doxygen above a declaration — @param, @return",
          h.lines[2:9] == ["/**", " * …", " *", " * @param name …", " * @param times …", " * @return …", " */"], h.lines[2:10])
    doc("c", C, 5)
    check(tag + "C: a call in a body is no routine: the next one (a function pointer, an array; void: no @return)",
          h.lines[9:16] == ["/**", " * …", " *", " * @param fn …", " * @param n …", " * @param values …", " */"],
          h.lines[9:])
    doc("c", C, 4)
    check(tag + "C: main", h.lines[4:11] == ["/**", " * …", " *", " * @param argc …", " * @param argv …", " * @return …",
                                            " */"], h.lines[4:12])
    CPP = ["template <typename T>", "T clamp(T v, T lo, T hi) {", "  return v;", "}", "",
           "Widget::Widget(int size) : size_(size) {}"]
    doc("cpp", CPP, 1)
    check(tag + "C++: above the template line",
          h.lines[:8] == ["/**", " * …", " *", " * @param v …", " * @param lo …", " * @param hi …", " * @return …", " */"]
          and h.lines[8] == "template <typename T>", h.lines[:10])
    doc("cpp", CPP, 5)
    check(tag + "C++: a constructor: its parameters, no @return",
          h.lines[5:10] == ["/**", " * …", " *", " * @param size …", " */"], h.lines[5:])

    # Go
    GO = ["package main", "", "func (s *Server) Handle(w http.ResponseWriter, r *http.Request) error {", "\treturn nil",
          "}", "", "func add(a, b int) int {", "\treturn a + b", "}", "", "// done is documented", "func done() {}"]
    doc("go", GO, 2, unit="\t")
    check(tag + "Go: // lines that start with its name, its parameters, its result",
          h.lines[2:9] == ["// Handle …", "//", "//   - w: …", "//   - r: …", "//", "// It returns …", GO[2]] and
          h.sel == rng(2, 10, 2, 13), (h.lines[2:9], h.sel))
    doc("go", GO, 6, unit="\t")
    check(tag + "Go: a, b int — both named", h.lines[6:12] == ["// add …", "//", "//   - a: …", "//   - b: …", "//",
                                                               "// It returns …"], h.lines[6:13])
    doc("go", GO, 11, unit="\t")
    check(tag + "Go: a comment right above: nothing written", h.lines == GO, h.lines)

    # Rust
    RS = ["impl Shape {", "    #[inline]", "    pub fn area(&self, scale: f64) -> f64 {", "        1.0", "    }", "}",
          "", "fn hello(mut name: String) {", "}"]
    doc("rust", RS, 2, unit="    ")
    check(tag + "Rust: /// lines above its attribute — # Arguments (&self left out), # Returns",
          h.lines[1:12] == ["    /// …", "    ///", "    /// # Arguments", "    ///", "    /// * `scale` - …", "    ///",
                            "    /// # Returns", "    ///", "    /// …", "    #[inline]", "    pub fn area(&self, scale: f64) -> f64 {"],
          h.lines[1:13])
    doc("rust", RS, 7, unit="    ")
    check(tag + "Rust: no result: no # Returns; mut left out of the name",
          h.lines[7:13] == ["/// …", "///", "/// # Arguments", "///", "/// * `name` - …", "fn hello(mut name: String) {"],
          h.lines[7:14])

    # the quick fix
    h.lang = "nim"
    h.lines = list(NIM)
    h.indent_ = "  "
    r = h.call(fixes["nim"]["cb"], {"buf": 1, "range": rng(8, 3, 8, 3)})
    v = (r or {}).get("value") or []
    check(tag + "Alt+Enter on a signature: Write a doc comment for twice — the same edit",
          len(v) == 1 and v[0]["title"] == "Write a doc comment for twice" and
          v[0]["edits"][0]["range"] == rng(8, 25, 8, 31) and
          v[0]["edits"][0]["text"] == "\n  ## …\n  ##\n  ## - `x`: …\n  ##\n  ## Returns …\n  x * 2", v)
    r1 = h.call(fixes["nim"]["cb"], {"buf": 1, "range": rng(10, 0, 10, 0)})
    r2 = h.call(fixes["nim"]["cb"], {"buf": 1, "range": rng(3, 0, 3, 0)})
    check(tag + "… none on a documented routine, none in a body", not (r1 or {}).get("value") and
          not (r2 or {}).get("value"), (r1, r2))

    # the placeholder setting; a language it does not know
    h.settings["placeholder"] = "TODO"
    doc("rust", ["fn f() -> u8 { 1 }"], 0)
    check(tag + "the placeholder setting: TODO, selected", h.lines[:6] == ["/// TODO", "///", "/// # Returns", "///",
                                                                            "/// TODO", "fn f() -> u8 { 1 }"] and
          h.sel == rng(0, 4, 0, 8), (h.lines, h.sel))
    del h.settings["placeholder"]
    doc("ruby", ["def x; end"], 0)
    check(tag + "a language it does not know: it says which it knows", h.lines == ["def x; end"] and
          h.messages[-1].startswith("Doc: not for ruby files — Nim, Python"), h.messages[-1:])
    doc("nim", ["let x = 1"], 0)
    check(tag + "no routine: it says so", h.messages[-1] == "Doc: no routine at the cursor or below it", h.messages[-1:])
