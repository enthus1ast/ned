"""nim-html: Karax's DSL — completion of tags and attributes in a buildHtml block (not outside one), hover on a tag
and an attribute; Emmet to Karax (nesting, siblings, *N with $, attributes, text, groups, ^, an error), the same
as a quick fix; HTML to Karax (a whole file into a tab with a proc; a selection in an HTML file into a tab; in a .nim
file in place, inside a buildHtml block and outside one with the import added); htmlgen to Karax (the call at the
cursor, htmlgen.x(…), a string of HTML in it, an expression as text); the snippets (htmlgen's page run by nim)."""
import os, subprocess
from tplugins import check


def pos(l, c):
    return {"line": l, "col": c}


def rng(l0, c0, l1, c1):
    return {"start": pos(l0, c0), "stop": pos(l1, c1)}


PAGE = """<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Shop &amp; more</title></head>
<body>
  <div class="card" data-id="7" style="color: red">
    <h2>Title</h2>
    <p>Hello <b>world</b> &mdash; again
    <p>Second
    <ul><li>one<li>two</ul>
    <input type="text" disabled>
    <button onclick="go()">Go</button>
    <!-- a note -->
    <my-widget></my-widget>
  </div>
</body>
</html>"""


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    titles = ["Nim HTML: Emmet to Karax", "Nim HTML: HTML to Karax", "Nim HTML: htmlgen to Karax"]
    c = {t: h.reg("command", title=t) for t in titles}
    co, hv, ca = h.reg("completion", lang="nim"), h.reg("hover", lang="nim"), h.reg("codeActions", lang="nim")
    sn = {t: h.reg("snippet", lang="nim", trigger=t) for t in ["buildhtml", "karax", "htmlgen"]}
    check(tag + "its three commands, completion, hover and quick fixes for Nim files, three snippets, the ned it needs",
          all(c.values()) and co and hv and ca and all(sn.values()) and h.reg("requires")["spec"] == ">= 6.29" and
          h.reg("info")["version"] == "1.0.0", [t for t, v in list(c.items()) + list(sn.items()) if not v])
    if not (all(c.values()) and co and hv and ca):
        return

    def run_(t):
        r = h.call(c[t]["cb"])
        return r and "err" not in r

    # completion
    h.lang = "nim"
    h.path_ = os.path.join(h.tmp, "app.nim")
    h.lines = ["import karax/[karaxdsl, vdom]", "", "proc render(): VNode =",
               "  result = buildHtml(tdiv(class = \"page\")):",       # 3
               "    td",                                               # 4
               "    h1(cl",                                            # 5
               "    p: te",                                            # 6
               "    a(href = \"#\", ta",                               # 7
               "    a(href = ",                                        # 8
               "    tdiv(class = \"x\",",                              # 9
               "         i",                                           # 10
               "let x = td"]                                           # 11

    def comp(l, col, prefix):
        r = h.call(co["cb"], {"buf": 1, "pos": pos(l, col), "prefix": prefix})
        return (r or {}).get("value") or []

    v = comp(4, 6, "td")
    t = [x for x in v if x["label"] == "tdiv"]
    check(tag + "completion at a statement in a buildHtml block: Karax's tags (tdiv for <div>), with what each is",
          t and t[0]["detail"] == "<div>" and "Nim keyword" in t[0]["doc"] and t[0]["kind"] == "class", v)
    v = comp(4, 4, "")
    labels = [x["label"] for x in v]
    check(tag + "… all of them with nothing typed: italic, bold, strikethrough, var, text and verbatim among them",
          all(x in labels for x in ["italic", "bold", "strikethrough", "var", "text", "verbatim", "h1", "input"]) and
          [x["insert"] for x in v if x["label"] == "var"] == ["`var`"], labels[:20])
    v = comp(5, 9, "cl")
    check(tag + "in a tag's brackets: its attributes as named arguments, a snippet (class = \"$1\")",
          [(x["label"], x["insert"], x["snippet"]) for x in v] == [("class", "class = \"$1\"$0", True)], v)
    v = comp(6, 9, "te")
    check(tag + "after a tag's colon: text, as a snippet (and the tags that start so: textarea, template)",
          [(x["label"], x["insert"], x["snippet"]) for x in v if x["label"] == "text"] == [("text", "text \"$1\"$0", True)]
          and "textarea" in [x["label"] for x in v], v)
    v = comp(7, 20, "ta")
    check(tag + "after a comma in the brackets: the attributes that start so (target, tabindex)",
          [x["label"] for x in v] == ["target", "tabindex"], v)
    v = comp(8, 13, "")
    check(tag + "after = (a value): nothing", v == [], v)
    v = comp(10, 9, "")
    labels = [x["label"] for x in v]
    check(tag + "on the next line of a tag's brackets: its attributes (id, `type` as type)",
          "id" in labels and "type" in labels and
          [x["insert"] for x in v if x["label"] == "type"] == ["`type` = \"$1\"$0"], labels)
    check(tag + "outside a buildHtml block: nothing", comp(11, 10, "td") == [])

    # hover
    def hover(l, col):
        r = h.call(hv["cb"], {"buf": 1, "pos": pos(l, col)})
        return (r or {}).get("value") or ""
    hh = hover(3, 22)
    check(tag + "hover on tdiv in buildHtml(…): <div>, and why Karax spells it so",
          hh.startswith("**tdiv** — `<div>`:") and "Nim keyword" in hh, hh)
    hh = hover(3, 29)
    check(tag + "hover on an attribute: what it is", hh.startswith("**class** — the element's classes"), hh)
    hh = hover(5, 4)
    check(tag + "hover on h1 at a statement's start", hh.startswith("**h1** — `<h1>`"), hh)
    h.lines[6] = "    p: text \"Hi\""
    h.lines[7] = "    for p in items: discard"
    hh = hover(6, 8)
    check(tag + "hover on text", hh.startswith("**text** — a text node"), hh)
    check(tag + "no hover outside a buildHtml block, nor on a word that is not a tag's place (a variable p)",
          hover(11, 9) == "" and hover(0, 2) == "" and hover(7, 8) == "", (hover(11, 9), hover(0, 2), hover(7, 8)))

    # Emmet to Karax
    h.lines = ["proc render(): VNode =", "  result = buildHtml(tdiv):", "    div.card>h2+p*2", "    p"]
    h.cursor = pos(2, 6)
    run_("Nim HTML: Emmet to Karax")
    check(tag + "Emmet: div.card>h2+p*2 at the line's indentation, the cursor in the first ()",
          h.lines[2:7] == ["    tdiv(class = \"card\"):", "      h2()", "      p()", "      p()", "    p"] and
          h.cursor == pos(3, 9), (h.lines, h.cursor))
    cases = [
        ("ul>li.item$*3", ["ul:", "  li(class = \"item1\")", "  li(class = \"item2\")", "  li(class = \"item3\")"]),
        ("a[href=#]{Home}", ["a(href = \"#\"): text \"Home\""]),
        ("#main", ["tdiv(id = \"main\")"]),
        ("ul>.x", ["ul:", "  li(class = \"x\")"]),
        ("(header>h1{Hi})+footer>p{x}^span",
         ["header:", "  h1: text \"Hi\"", "footer:", "  p: text \"x\"", "span()"]),
        ("form>input[type=email placeholder=\"Your mail\"]+button[type=submit]{Send}",
         ["form(action = \"\"):", "  input(`type` = \"email\", placeholder = \"Your mail\")",
          "  button(`type` = \"submit\"): text \"Send\""]),
        ("p>{Hello }+strong{you}", ["p:", "  text \"Hello \"", "  strong: text \"you\""]),
        ("table>tr*2>td{$}*2", ["table:", "  tr:", "    td: text \"1\"", "    td: text \"2\"", "  tr:",
                                "    td: text \"1\"", "    td: text \"2\""]),
        ("img[src=a.png alt=\"A cat\"]", ["img(src = \"a.png\", alt = \"A cat\")"]),
        ("div[data-id=3 aria-label=Close]", ["tdiv(data-id = \"3\", aria-label = \"Close\")"]),
    ]
    for ab, want in cases:
        h.lines = [ab]
        h.cursor = pos(0, 0)
        run_("Nim HTML: Emmet to Karax")
        check(tag + "Emmet: " + ab, h.lines == want, h.lines)
    h.lines = ["  ul>"]
    run_("Nim HTML: Emmet to Karax")
    check(tag + "Emmet: an abbreviation that is not one — the line kept, a warning that says why",
          h.lines == ["  ul>"] and h.messages[-1] == "Emmet: not an abbreviation — something after the last + > or ^",
          (h.lines, h.messages[-1:]))
    # … as a quick fix in a buildHtml block
    h.lines = ["proc render(): VNode =", "  result = buildHtml(tdiv):", "    ul>li*2", "    text \"x\"", "ul>li"]
    r = h.call(ca["cb"], {"buf": 1, "range": rng(2, 5, 2, 5)})
    v = (r or {}).get("value") or []
    check(tag + "Alt+Enter on an abbreviation in a buildHtml block: Emmet: expand …",
          len(v) == 1 and v[0]["title"] == "Emmet: expand ul>li*2" and
          v[0]["edits"][0]["text"] == "    ul:\n      li()\n      li()" and
          v[0]["edits"][0]["range"] == rng(2, 0, 2, 11), v)
    r1 = h.call(ca["cb"], {"buf": 1, "range": rng(3, 5, 3, 5)})
    r2 = h.call(ca["cb"], {"buf": 1, "range": rng(4, 1, 4, 1)})
    check(tag + "… none on a line of Karax, nor outside a buildHtml block",
          not (r1 or {}).get("value") and not (r2 or {}).get("value"), (r1, r2))

    # HTML to Karax: the whole file, into a tab
    h.lang = "html"
    h.path_ = os.path.join(h.tmp, "shop.html")
    h.lines = PAGE.split("\n")
    h.sel = None
    h.cursor = pos(0, 0)
    n = len(h.tabs)
    run_("Nim HTML: HTML to Karax")
    tab = h.tabs[-1] if len(h.tabs) > n else ("", "", "")
    code = tab[1]
    check(tag + "HTML to Karax, nothing selected: the whole file in a tab (shop.nim, Nim), the file as it was",
          tab[0] == "shop.nim" and tab[2] == "nim" and h.lines == PAGE.split("\n") and
          h.messages[-1] == "Karax's DSL for shop.html is in shop.nim", (tab[0], tab[2], h.messages[-1:]))
    check(tag + "… the imports (vstyles for a style), a proc that builds it, echo for the HTML",
          code.startswith("import karax/[karaxdsl, vdom, vstyles]\n\nproc render*(): VNode =\n"
                          "  result = buildHtml(html(lang = \"en\")):\n    head:\n") and
          "when isMainModule:\n  echo render()" in code, code[:300])
    for want, what in [
            ("      title: text \"Shop & more\"", "a character reference decoded"),
            ("      tdiv(class = \"card\", data-id = \"7\", style = \"color: red\".toCss):", "div as tdiv, data-id, "
             "a style through toCss"),
            ("        p:\n          text \"Hello \"\n          bold: text \"world\"\n          text \" — again\"\n"
             "        p: text \"Second\"", "a <p> the next one ends, b as bold, text and tags mixed"),
            ("        ul:\n          li: text \"one\"\n          li: text \"two\"", "li without its end tag"),
            ("        input(`type` = \"text\", disabled = \"\")", "a void element, `type`, an attribute alone"),
            ("        # onclick=\"go()\" — in Karax an event is a proc: onclick = proc () = …\n"
             "        button: text \"Go\"", "an HTML event: a comment above"),
            ("        # a note\n", "a comment"),
            ("        # <my-widget>: Karax has no tag of this name\n        tdiv()", "a tag Karax lacks")]:
        check(tag + "HTML to Karax: " + what, want in code, code)
    # a selection in an HTML file: a tab
    h.lines = ["<ul>", "  <li><a href=\"/a\">A</a></li>", "  <li>B</li>", "</ul>", "<p>after</p>"]
    h.sel = rng(0, 0, 3, 5)
    run_("Nim HTML: HTML to Karax")
    code = h.tabs[-1][1]
    check(tag + "a selection in an HTML file: a tab with it alone (one root: buildHtml(ul))",
          "  result = buildHtml(ul):\n    li:\n      a(href = \"/a\"): text \"A\"\n    li: text \"B\"\n" in code and
          "after" not in code and h.messages[-1] == "Karax's DSL for the selection is in shop.nim", (code, h.messages[-1:]))
    # in a .nim file, inside a buildHtml block: in place, at the indentation
    h.lang = "nim"
    h.path_ = os.path.join(h.tmp, "app.nim")
    h.lines = ["import karax/[karaxdsl, vdom]", "", "proc render(): VNode =", "  result = buildHtml(tdiv):",
               "    <p class=\"x\">Hi <em>there</em></p>", "    <br>", "  discard"]
    h.sel = rng(4, 4, 6, 0)
    run_("Nim HTML: HTML to Karax")
    check(tag + "a selection in a .nim file, in a buildHtml block: the DSL in its place, as it is",
          h.lines == ["import karax/[karaxdsl, vdom]", "", "proc render(): VNode =", "  result = buildHtml(tdiv):",
                      "    p(class = \"x\"):", "      text \"Hi \"", "      em: text \"there\"", "    br()", "  discard"],
          h.lines)
    # … outside one: a buildHtml(…) expression, and the import it needs
    h.lines = ["import std/strutils", "", "let page = <section><h1>Hi</h1></section>", "echo page"]
    h.sel = rng(2, 11, 2, 42)
    run_("Nim HTML: HTML to Karax")
    check(tag + "… outside a buildHtml block: buildHtml(section): its children, import karax/[karaxdsl, vdom] after "
          "the file's imports",
          h.lines == ["import std/strutils", "import karax/[karaxdsl, vdom]", "", "let page = buildHtml(section):",
                      "  h1: text \"Hi\"", "echo page"], h.lines)
    h.sel = None

    # htmlgen to Karax
    h.lines = ["import std/htmlgen", "", "let count = 2", "let page = html(head(title(\"Hi\")),",
               "  body(h1(\"Hello\"), p(class = \"x\", \"a &amp; <b>b</b>\", $count)))", "echo page"]
    h.cursor = pos(4, 10)
    run_("Nim HTML: htmlgen to Karax")
    check(tag + "htmlgen to Karax: the call the cursor is in (the outermost), as buildHtml(html); a string of HTML "
          "read as HTML; an expression as text; the import added",
          h.lines == ["import std/htmlgen", "import karax/[karaxdsl, vdom]", "", "let count = 2",
                      "let page = buildHtml(html):", "  head:", "    title: text \"Hi\"", "  body:",
                      "    h1: text \"Hello\"", "    p(class = \"x\"):", "      text \"a & \"", "      bold: text \"b\"",
                      "      text $count", "echo page"], h.lines)
    h.lines = ["from std/htmlgen import nil", "import karax/vdom", "",
               "echo htmlgen.`div`(htmlgen.a(href = url, target = \"_blank\", \"go\"))"]
    h.cursor = pos(3, 0)
    run_("Nim HTML: htmlgen to Karax")
    check(tag + "htmlgen.x(…) after echo; `div`; an attribute that is code; karaxdsl imported (vdom alone is not it)",
          h.lines == ["from std/htmlgen import nil", "import karax/vdom", "import karax/[karaxdsl, vdom]", "",
                      "echo buildHtml(tdiv):",
                      "  a(href = url, target = \"_blank\"): text \"go\""], h.lines)
    h.lines = ["let x = 1"]
    h.cursor = pos(0, 0)
    run_("Nim HTML: htmlgen to Karax")
    check(tag + "no htmlgen call here: it says so", h.lines == ["let x = 1"] and
          h.messages[-1].startswith("htmlgen to Karax: no htmlgen call here"), h.messages[-1:])

    # the snippets: Karax's app (createDom, setRenderer); htmlgen's page, run by nim
    check(tag + "the karax snippet: include karax/prelude, createDom, setRenderer",
          "include karax/prelude" in sn["karax"]["body"] and "proc createDom(): VNode =" in sn["karax"]["body"] and
          sn["karax"]["body"].rstrip().endswith("setRenderer createDom") and
          sn["buildhtml"]["body"].startswith("buildHtml(${1:tdiv}"), sn["karax"]["body"])
    body = sn["htmlgen"]["body"]
    import re
    prog = re.sub(r"\$\{\d+:([^}]*)\}", r"\1", body).replace("$0", "x").replace("\t", "  ")
    d = os.path.join(h.tmp, "snip")
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "page.nims"), "w").write(prog)
    p = subprocess.run(["nim", "e", "--hints:off", "page.nims"], cwd=d, capture_output=True, text=True, timeout=120)
    out = open(os.path.join(d, "index.html")).read() if os.path.exists(os.path.join(d, "index.html")) else ""
    check(tag + "the htmlgen snippet runs: a page written to index.html",
          p.returncode == 0 and out.startswith("<!DOCTYPE html>\n<html><head><title>Title</title></head><body>") and
          "<h1>Hello</h1>" in out, (p.stdout + p.stderr)[-600:] + out[:200])
