"""typst: the language (colours, comments, indentation, F5), its snippets, the outline without a language server
(headings as levels, #let functions and variables, labels — not in comments, strings or raw blocks), tinymist and
typstyle when they are installed (pretend ones here), the plugin's two settings"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from langcheck import check_language

SAMPLE = """#set page(paper: "a4")
#let title = "A report"
// #let commented = 1
/* = Not a heading
#let hidden(x) = x */
#let card(body, fill: none) = box(body)

= Introduction <intro>
Some text with a "string <notalabel>" and @intro.

== Background
#let note(x) = text(x)
```typ
= Not this either
```
#figure([x])[ = inside content ] <fig:one>

= Results""".split("\n")


def run(factory, tag):
    check_language(
        factory, tag, "typst",
        {"name": "Typst", "extensions": ["typ"], "lineComment": "//", "blockComment": ["/*", "*/"], "quotes": "\"",
         "decorators": True, "indentSize": 2, "dedent": "})]", "pairs": "()[]{}\"\"$$",
         "keywords": {"let", "set", "show", "if", "else", "for", "in", "while", "import", "include", "context"},
         "constants": {"none", "auto", "true", "false"}, "functionWords": ["let"],
         "build": "typst compile \"$file\"",
         "check": "typst compile --diagnostic-format short \"$file\" \"$tmp/$name.pdf\""},
        ["let", "set", "show", "figure", "table", "import", "page", "doc"],
        SAMPLE,
        [("title", "variable", 0), ("card", "function", 0), ("Introduction", "heading", 0),
         ("<intro>", "constant", 1), ("Background", "heading", 1), ("note", "function", 2),
         ("<fig:one>", "constant", 2), ("Results", "heading", 0)],
        ["typst", "tinymist", "typstyle"],
        runs=[("paper.typ", "= Hello\n", {}, "typst watch $file")],
        server=["tinymist", "lsp"], formatter="typstyle")
    src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "plugins", "typst",
                            "plugin.nims")).read()
    from tplugins import check
    check(tag + "it says why it runs programs (permission \"shell\")", 'permission("shell", "' in src)
