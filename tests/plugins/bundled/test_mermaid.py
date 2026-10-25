"""mermaid: the language, its snippets, the outline, the ```mermaid block of a Markdown file found, the picture made
by mmdc (a pretend one here: it writes down its arguments and makes the file) and opened, or saved next to the file"""
import os, shutil, stat, tempfile
from tplugins import check

FLOW = ["%% a comment", "flowchart TD", "    subgraph Frontend [The front]", "        A[Start] --> B", "    end",
        "    subgraph Back", "        C --> D", "    end"]
SEQ = ["sequenceDiagram", "    participant Alice", "    actor Bob as B", "    Alice->>Bob: hi"]


def pos(l, c):
    return {"line": l, "col": c}


def run(factory, tag):
    tmp = tempfile.mkdtemp(prefix="ned-mmd-")
    try:
        _run(factory, tag, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def _run(factory, tag, tmp):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok)
    if not ok:
        return
    sp = (h.reg("language", id="mermaid") or {}).get("spec", {})
    check(tag + "the language: .mmd .mermaid, %% comments, the diagrams' words, end takes a level off",
          sp.get("extensions") == ["mmd", "mermaid"] and sp.get("lineComment") == "%%" and
          {"flowchart", "sequenceDiagram", "subgraph", "end", "participant", "gantt"} <= set(sp.get("keywords", [])) and
          sp.get("dedentWords") == ["end"] and "subgraph" in sp.get("indentAfter", []), sp)
    trig = {r["trigger"] for r in h.regs if r["kind"] == "snippet" and r["lang"] == "mermaid"}
    check(tag + "snippets for each kind", trig == {"flowchart", "sequence", "class", "state", "er", "gantt", "pie",
                                                    "mindmap"}, trig)
    h.lines = FLOW
    r = h.call(h.reg("symbols", lang="mermaid")["cb"], {"buf": 1})
    sy = [(s["name"], s["depth"]) for s in (r or {}).get("value") or []]
    check(tag + "the outline: the kind, its subgraphs", sy == [("flowchart", 0), ("Frontend", 1), ("Back", 1)], sy)
    h.lines = SEQ
    r = h.call(h.reg("symbols", lang="mermaid")["cb"], {"buf": 1})
    sy = [(s["name"], s["kind"]) for s in (r or {}).get("value") or []]
    check(tag + "… participants and actors", sy == [("sequenceDiagram", "class"), ("Alice", "variable"),
                                                   ("Bob", "variable")], sy)
    # the picture, with a pretend mmdc
    log = os.path.join(tmp, "mmdc.log")
    fake = os.path.join(tmp, "mmdc")
    open(fake, "w").write('#!/bin/sh\necho "$@" > %s\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && touch "$2"; '
                          '[ "$1" = -i ] && cp "$2" %s.in; shift; done\n' % (log, log))
    os.chmod(fake, os.stat(fake).st_mode | stat.S_IEXEC)
    h.settings["program"] = fake
    show = h.reg("command", title="Mermaid: show the picture")
    save = h.reg("command", title="Mermaid: save the picture next to the file")
    check(tag + "its two commands", show and save)
    d = os.path.join(tmp, "doc")
    os.makedirs(d)
    h.lang = "mermaid"
    h.path_ = os.path.join(d, "flow.mmd")
    h.lines = FLOW
    h.opened = []
    h.call(show["cb"])
    args = open(log).read() if os.path.exists(log) else ""
    check(tag + "show: mmdc with the theme, the input and a png in the plugin's folder, then opened",
          "-t default" in args and "-i " in args and args.strip().endswith("flow.png") and h.opened and
          h.opened[-1][0].endswith("flow.png"), (args, h.opened))
    check(tag + "… the diagram given to it", open(log + ".in").read() == "\n".join(FLOW) + "\n")
    h.settings["format"] = "svg"
    h.call(save["cb"])
    check(tag + "save: name.svg next to the file", os.path.exists(os.path.join(d, "flow.svg")), os.listdir(d))
    # Markdown: the block the cursor is in
    h.lang = "markdown"
    h.path_ = os.path.join(d, "README.md")
    h.lines = ["# Title", "```mermaid", "pie title Pets", '    "Dogs" : 3', "```", "after"]
    h.cursor = pos(3, 2)
    h.call(show["cb"])
    check(tag + "Markdown: the ```mermaid block the cursor is in", open(log + ".in").read() ==
          'pie title Pets\n    "Dogs" : 3\n', open(log + ".in").read())
    h.cursor = pos(5, 0)
    h.messages = []
    h.call(show["cb"])
    check(tag + "… outside a block: said", any("```mermaid block" in m for m in h.messages), h.messages)
    h.settings["program"] = "/no/such/mmdc"
    h.lang = "mermaid"
    h.path_ = os.path.join(d, "flow.mmd")
    h.lines = FLOW
    h.messages = []
    h.call(show["cb"])
    check(tag + "no mmdc: how to install it", any("npm install -g @mermaid-js/mermaid-cli" in m for m in h.messages),
          h.messages)
