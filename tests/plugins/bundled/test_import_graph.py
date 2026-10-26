"""import-graph: a small Nim project read for its imports (std/[…], a/b, ../x, from … import, include, pkg/…, an
import over several lines, srcDir from the .nimble, --path from config.nims; nimcache and hidden folders left out);
the Mermaid flowchart (imports, an include, the standard library and the packages in boxes of their own) and the
tree (a cycle, a module seen above) in a Markdown tab; the external setting; who imports a file (pick, open at the
line)."""
import os
from tplugins import check

FILES = {
    "app.nimble": 'version = "0.1.0"\nsrcDir = "src"\n',
    "config.nims": '--path:"lib"\n',
    "src/app.nim": 'import std/[os, strutils], app/util, app/view # the parts\nimport karax/vdom\n'
                   'echo "import fake"\n',
    "src/app/util.nim": 'import\n  std/json\nfrom ./core import x\n',
    "src/app/core.nim": 'import ../app/util\nconst doc = """\nimport notreal\n"""\n',
    "src/app/view.nim": 'include parts\nimport pkg/jester\n',
    "src/app/parts.nim": 'proc p() = discard\n',
    "src/app/usesextra.nim": 'when defined(x):\n  import extra\n',
    "lib/extra.nim": '',
    "tests/test_app.nim": 'import app/util, unittest\n',
    "nimcache/gen.nim": 'import os\n',
    ".hidden/y.nim": 'import os\n',
}


def run(factory, tag):
    h = factory()
    if not h.build_ok:
        check(tag + "the host compiles", False, h.build_err)
        return
    ok = h.pump(lambda j: j.get("t") == "ready", 60)
    check(tag + "it starts", ok, "" if ok else h.p.stderr.read()[-1500:])
    if not ok:
        return
    g = h.reg("command", title="Imports: graph of this project's modules")
    w = h.reg("command", title="Imports: who imports this file")
    check(tag + "its two commands, its settings, the ned it needs",
          g and w and h.reg("setting", key="external")["default"] is True and
          h.reg("setting", key="direction")["default"] == "LR" and h.reg("requires")["spec"] == ">= 6.29")
    if not (g and w):
        return
    proj = os.path.join(h.tmp, "shop")
    for f, text in FILES.items():
        p = os.path.join(proj, f)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w").write(text)
    h.root = proj
    n = len(h.tabs)
    r = h.call(g["cb"], timeout=60)
    tab = h.tabs[-1] if len(h.tabs) > n else ("", "", "")
    text = tab[1]
    check(tag + "the graph: a Markdown tab, Imports.md; how many modules and imports",
          r and "err" not in r and tab[0] == "Imports.md" and tab[2] == "markdown" and
          text.startswith("# The imports of shop\n\n8 modules, 7 imports between them; 4 modules of the standard "
                          "library and 2 nimble packages besides.") and
          h.messages[-1] == "Imports: 8 modules, 7 imports — in Imports.md", (r, tab[0], text[:200], h.messages[-1:]))
    mm = text.split("```mermaid\n")[1].split("```")[0] if "```mermaid\n" in text else ""
    ml = mm.split("\n")
    nodes = ["m0[\"lib/extra.nim\"]", "m1[\"src/app.nim\"]", "m2[\"src/app/core.nim\"]", "m3[\"src/app/parts.nim\"]",
             "m4[\"src/app/usesextra.nim\"]", "m5[\"src/app/util.nim\"]", "m6[\"src/app/view.nim\"]",
             "m7[\"tests/test_app.nim\"]"]
    check(tag + "Mermaid: a flowchart, a node for each module (not nimcache's, not a hidden folder's)",
          ml[0] == "flowchart LR" and [x.strip() for x in ml[1:9]] == nodes and "gen.nim" not in mm and "y.nim" not in mm,
          ml[:10])
    check(tag + "Mermaid: the standard library's modules and the packages in boxes of their own",
          "  subgraph std [Standard library]\n    s0[\"json\"]\n    s1[\"os\"]\n    s2[\"strutils\"]\n    s3[\"unittest\"]\n"
          "  end\n  subgraph pkgs [Nimble packages]\n    p0[\"jester\"]\n    p1[\"karax\"]\n  end" in mm, mm)
    edges = [x.strip() for x in ml if "--" in x or "-.->" in x]
    check(tag + "Mermaid: the imports (std/[…], a/b through srcDir, ../x, from … import, --path, over two lines), "
          "an include dashed",
          edges == ["m1 --> s1", "m1 --> s2", "m1 --> m5", "m1 --> m6", "m1 --> p1", "m2 --> m5", "m4 --> m0",
                    "m5 --> s0", "m5 --> m2", "m6 -.->|include| m3", "m6 --> p0", "m7 --> m5", "m7 --> s3"], edges)
    tree = text.split("```text\n")[1].split("```")[0] if "```text\n" in text else ""
    want = """src/app.nim
├── src/app/util.nim
│   ├── src/app/core.nim
│   │   └── src/app/util.nim — a cycle
│   └── std: json
├── src/app/view.nim
│   ├── src/app/parts.nim (include)
│   └── packages: jester
├── std: os, strutils
└── packages: karax
src/app/usesextra.nim
└── lib/extra.nim
tests/test_app.nim
├── src/app/util.nim (above)
└── std: unittest
"""
    check(tag + "the tree: from the modules no one imports, a cycle, a module shown above, the outside ones apart",
          tree == want, tree)
    # without leave to run programs (find, awk): NimScript reads the files itself — the same graph
    h.allowed = set()
    h.call(g["cb"], timeout=60)
    check(tag + "not allowed to run programs: NimScript reads the files — the same graph and tree",
          h.tabs[-1][1] == text and h.messages[-1] == "Imports: 8 modules, 7 imports — in Imports.md", h.tabs[-1][1][:300])
    h.allowed = {"shell", "network", "files", "clipboard"}
    # the settings: the project's modules only, top down
    h.settings = {"external": False, "direction": "TD"}
    h.call(g["cb"], timeout=60)
    text = h.tabs[-1][1]
    check(tag + "external off: no standard library, no packages; direction TD",
          "flowchart TD" in text and "subgraph" not in text and "std:" not in text and "packages:" not in text and
          "m1 --> m5" in text and "(the standard library and the nimble packages left out)" in text, text[:600])
    h.settings = {}
    # who imports this file
    h.path_ = os.path.join(proj, "src", "app", "util.nim")
    h.answers["pick"] = 1
    h.opened = []
    h.call(w["cb"], timeout=60)
    a = h.asked[-1][1] if h.asked else {}
    check(tag + "who imports util.nim: the modules, the line, pick one to go there",
          a.get("title") == "3 modules import util.nim" and
          a.get("items") == ["src/app.nim", "src/app/core.nim", "tests/test_app.nim"] and
          a.get("details") == ["line 1", "line 1", "line 1"] and
          h.opened[-1:] == [(os.path.join(proj, "src/app/core.nim"), 0)], (a, h.opened))
    h.path_ = os.path.join(proj, "src", "app", "parts.nim")
    h.answers["pick"] = 0
    h.call(w["cb"], timeout=60)
    a = h.asked[-1][1]
    check(tag + "who imports parts.nim: an include", a.get("items") == ["src/app/view.nim"] and
          a.get("details") == ["line 1 · include"] and h.opened[-1:] == [(os.path.join(proj, "src/app/view.nim"), 0)], a)
    h.path_ = os.path.join(proj, "src", "app.nim")
    h.call(w["cb"], timeout=60)
    check(tag + "nothing imports app.nim: it says so", h.messages[-1] == "Imports: no module of the project imports "
          "src/app.nim", h.messages[-1:])
    h.path_ = os.path.join(h.tmp, "notes.txt")
    h.call(w["cb"])
    check(tag + "not a .nim file: it says what to do", h.messages[-1] == "Imports: open a .nim file of the project first",
          h.messages[-1:])
