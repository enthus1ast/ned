## mermaid — Mermaid diagrams: their colours, snippets for each kind, an outline, and the picture made with mermaid-cli
## (mmdc) and shown in ned — of a .mmd file, or of the ```mermaid block of a Markdown file the cursor is in
##
##   The language: .mmd and .mermaid files — %% comments, the diagrams' words (flowchart, sequenceDiagram,
##   classDiagram, stateDiagram-v2, erDiagram, gantt, pie, journey, gitGraph, mindmap, timeline …, subgraph, end,
##   participant, loop, alt …), indentation after a block's start
##   Snippets: flowchart, sequence, class, state, er, gantt, pie, mindmap
##   The outline: the diagram's kind, its subgraphs, participants, classes, states and sections
##   Mermaid: show the picture       mmdc makes it (plugins.mermaid.format: png, svg or pdf) and ned opens it —
##                                    the picture beside the diagram, made again by the same command after a change
##   Mermaid: save the picture next to the file   the same, as name.png (or .svg) beside it
## mmdc: `npm install -g @mermaid-js/mermaid-cli` (it brings a headless Chromium; Termux: the browser it needs is
## not there — use the saved .mmd with https://mermaid.live)
import nedplugin
import std/[strutils, os]

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs mmdc (mermaid-cli) to make the picture")

settingDef("format", "png", "Mermaid: the picture's format — png, svg or pdf")
settingDef("theme", "default", "Mermaid: its theme — default, dark, forest or neutral")
settingDef("program", "mmdc", "The mermaid-cli program (its name on PATH, or its path)")

const Kinds = ["flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram", "stateDiagram-v2",
               "erDiagram", "gantt", "pie", "journey", "gitGraph", "mindmap", "timeline", "quadrantChart",
               "requirementDiagram", "C4Context", "sankey-beta", "xychart-beta", "block-beta", "packet-beta",
               "kanban", "architecture-beta"]

language("mermaid", LangSpec(
  name: "Mermaid",
  extensions: @["mmd", "mermaid"],
  lineComment: "%%",
  quotes: "\"",
  keywords: @Kinds & @["subgraph", "end", "direction", "participant", "actor", "as", "note", "over", "left", "right",
             "of", "loop", "alt", "else", "opt", "par", "and", "critical", "break", "rect", "activate", "deactivate",
             "autonumber", "box", "class", "classDef", "style", "linkStyle", "click", "callback", "link", "state",
             "section", "title", "dateFormat", "axisFormat", "excludes", "includes", "todayMarker", "commit",
             "branch", "checkout", "merge", "cherry-pick", "root", "accTitle", "accDescr", "namespace"],
  constants: @["TB", "TD", "BT", "RL", "LR", "true", "false", "done", "active", "crit", "milestone"],
  indentAfter: @["subgraph", "loop", "alt", "opt", "par", "critical", "rect", "box", "{", "section"],
  dedentWords: @["end"],
  indentSize: 4,
  pairs: "()[]{}\"\""))

snippet("mermaid", "flowchart", "flowchart ${1:TD}\n    ${2:A}[${3:Start}] --> ${4:B}{${5:Is it?}}\n    $4 -->|Yes| ${6:C}[${7:OK}]\n    $4 -->|No| ${8:D}[${9:Not OK}]$0", "a flowchart")
snippet("mermaid", "sequence", "sequenceDiagram\n    participant ${1:A}\n    participant ${2:B}\n    $1->>$2: ${3:request}\n    $2-->>$1: ${4:answer}$0", "a sequence diagram")
snippet("mermaid", "class", "classDiagram\n    class ${1:Animal} {\n        +${2:String} ${3:name}\n        +${4:speak}()\n    }\n    $1 <|-- ${5:Dog}$0", "a class diagram")
snippet("mermaid", "state", "stateDiagram-v2\n    [*] --> ${1:Still}\n    $1 --> ${2:Moving}\n    $2 --> [*]$0", "a state diagram")
snippet("mermaid", "er", "erDiagram\n    ${1:CUSTOMER} ||--o{ ${2:ORDER} : ${3:places}\n    $2 ||--|{ ${4:LINE} : ${5:contains}$0", "an entity–relationship diagram")
snippet("mermaid", "gantt", "gantt\n    title ${1:A plan}\n    dateFormat YYYY-MM-DD\n    section ${2:First}\n    ${3:A task} :a1, ${4:2026-01-01}, ${5:7d}$0", "a Gantt chart")
snippet("mermaid", "pie", "pie title ${1:What}\n    \"${2:One}\" : ${3:40}\n    \"${4:Two}\" : ${5:60}$0", "a pie chart")
snippet("mermaid", "mindmap", "mindmap\n  root((${1:The idea}))\n    ${2:A branch}\n      ${3:A leaf}$0", "a mind map")

func diagramSymbols*(lines: seq[string], first = 0): seq[Symbol] =
  ## the diagram's kind, then its subgraphs, participants, classes, states and sections
  var depth = 0
  for i, raw in lines:
    let t = raw.strip
    if t.len == 0 or t.startsWith("%%"): continue
    let w = t.split({' ', '\t', '[', '(', '{', ':'})[0]
    if w in Kinds:
      result.add Symbol(name: w, kind: "class", detail: t[w.len .. ^1].strip, line: first + i,
                        col: raw.len - raw.strip(trailing = false).len)
      depth = 1
      continue
    let rest = t[w.len .. ^1].strip
    case w
    of "subgraph", "section", "participant", "actor", "class", "state", "box", "namespace":
      var name = rest
      for sep in [" as ", "[", "{", ":", " "]:
        let k = name.find(sep)
        if k > 0: name = name[0 ..< k]
      if name.len == 0: continue
      result.add Symbol(name: name.strip(chars = {'"', ' '}), kind: (if w in ["participant", "actor"]: "variable"
                        elif w == "class": "class" else: "section"), detail: w, line: first + i,
                        col: raw.len - raw.strip(trailing = false).len, depth: depth)
    else: discard

symbols("mermaid") do (b: Buf) -> seq[Symbol]:
  diagramSymbols(b.lines)

# s as one word for a shell command line, in single quotes (a quote inside it written '\'')
func q(s: string): string = "'" & s.replace("'", "'\\''") & "'"

func blockAt*(lines: seq[string], line: int): (int, int) =
  ## a Markdown file's ```mermaid block around a line: (its first line, its last) — (-1, -1) none
  var start = -1
  for i, l in lines:
    let t = l.strip
    if start < 0 and t.startsWith("```mermaid"): start = i
    elif start >= 0 and t.startsWith("```"):
      if line > start and line < i: return (start + 1, i - 1)
      start = -1
  (-1, -1)

proc diagramText(b: Buf): string =
  ## the diagram to draw: in a Markdown file the ```mermaid block the cursor is in ("" when it is in none), in any other
  ## file the whole text
  if b.lang == "markdown" or b.path.endsWith(".md"):
    let (a, e) = blockAt(b.lines, b.cursor.line)
    if a < 0: return ""
    return b.lines(a, e).join("\n")
  b.text

proc render(beside: bool) =
  ## makes the picture of the diagram with mmdc (mermaid-cli) in the format and theme of the settings: opens it in a tab
  ## when beside is false, or saves it next to the file (named after it) and says where; warns when mmdc is missing or
  ## fails, showing its words in the Output panel
  let b = current()
  let text = diagramText(b)
  if text.strip.len == 0:
    message(if b.lang == "markdown": "Put the cursor in a ```mermaid block" else: "No diagram here")
    return
  let fmt = setting("format", "png")
  let prog = setting("program", "mmdc")
  if findExe(prog).len == 0 and not fileExists(prog):
    warn("mmdc (mermaid-cli) is not installed — npm install -g @mermaid-js/mermaid-cli")
    return
  writeData("diagram.mmd", text & "\n")
  let src = dataDir() / "diagram.mmd"
  let name = if b.path.len > 0: b.path.splitFile.name else: "diagram"
  let dest = if beside and b.path.len > 0: b.path.splitFile.dir / name & "." & fmt
             else: dataDir() / name & "." & fmt
  status("Making the picture…")
  let r = shell(q(prog) & " -q -t " & setting("theme", "default") & " -b white -i " & q(src) & " -o " & q(dest) &
                " 2>&1")
  status("")
  if r.code != 0 or not fileExists(dest):
    warn("mmdc: " & (if r.output.strip.len > 0: r.output.strip.splitLines[^1] else: "no picture made"))
    output(r.output)
    return
  if beside: message("Saved " & dest)
  else: discard openFile(dest)

command "Mermaid: show the picture":
  render(false)

command "Mermaid: save the picture next to the file":
  render(true)
