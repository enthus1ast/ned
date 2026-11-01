## typst — Typst: colours, comments, indentation, F5 (typst watch), snippets, an outline; tinymist and typstyle
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Typst's `.typ` files: their colours (ned's generic
## lexer with Typst's words: `#let`, `#set`, `#show`, `context` …, `none` and `auto`, @references in their own
## colour), `//` and `/* */` comments, indentation after `{` `[` `(`, two spaces, brackets, quotes and `$…$` (maths)
## that close themselves, snippets (let, set, show, figure, table, import, page, doc) and F5: `typst watch` on the
## file — it writes the PDF beside it again each time you save, until you stop it. Build (Alt+B) is
## `typst compile`, and the check on save compiles into a file of ned's own, its problems at their lines.
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the file's headings (`=`, `==` … as levels),
## its functions and variables (`#let`) and its labels (`<intro>`), from a simple scan.
##
## The tools, when they are on PATH — typst itself: Termux `pkg install typst`; elsewhere
## https://github.com/typst/typst/releases (or `cargo install typst-cli`)
## - tinymist, Typst's language server (completion, hover, go to definition, problems, a preview):
##   https://github.com/Myriad-Dreamin/tinymist/releases — else typst-lsp, the older one
## - typstyle, the formatter (Format document, and on save with editor.formatOnSave):
##   `cargo install typstyle`, or https://github.com/Enter-tainer/typstyle/releases
##
## Settings (the Plugins dock › typst › its settings; Plugins: reload after a change):
## - plugins.typst.server — the language server's command, when it is neither of those ("off": none)
## - plugins.typst.formatter — the formatter's command (the text on its stdin), when it is not `typstyle`
##   ("off": none)
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs typst for F5, Build and the check, and tinymist and typstyle when they are installed")

settingDef("server", "", "The language server's command: empty for tinymist (or typst-lsp) when it is installed, " &
           "\"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for typstyle (when " &
           "it is installed), \"off\" for none. Plugins: reload after a change")

language("typst", LangSpec(
  name: "Typst",
  extensions: @["typ"],
  lineComment: "//",
  blockComment: @["/*", "*/"],
  docComment: "///",
  quotes: "\"",
  decorators: true,
  keywords: @["let", "set", "show", "if", "else", "for", "in", "while", "break", "continue", "return", "import",
              "include", "as", "context", "not", "and", "or"],
  constants: @["none", "auto", "true", "false"],
  types: @["int", "float", "str", "bool", "content", "array", "dictionary", "function", "length", "ratio",
           "relative", "fraction", "angle", "color", "datetime", "duration", "regex", "label", "selector",
           "module", "version", "bytes", "decimal"],
  builtins: @["text", "par", "heading", "figure", "table", "grid", "image", "link", "ref", "cite", "footnote",
              "list", "enum", "terms", "emph", "strong", "raw", "box", "block", "page", "document", "align",
              "stack", "pad", "place", "columns", "colbreak", "pagebreak", "v", "h", "rect", "square", "circle",
              "ellipse", "line", "path", "polygon", "outline", "bibliography", "numbering", "counter", "state",
              "query", "locate", "measure", "layout", "lorem", "rgb", "luma", "cmyk", "eval", "panic", "assert",
              "repr", "type", "calc", "underline", "overline", "strike", "highlight", "smallcaps", "upper",
              "lower", "quote", "math", "sym", "metadata"],
  functionWords: @["let"],
  indentAfter: @["{", "[", "("],
  dedent: "})]",
  indentSize: 2,
  run: "typst watch \"$file\"",
  build: "typst compile \"$file\"",
  check: "typst compile --diagnostic-format short \"$file\" \"$tmp/$name.pdf\"",
  pairs: "()[]{}\"\"$$"))

snippet("typst", "let", "#let ${1:name}(${2:args}) = ${3:none}$0", "a function")
snippet("typst", "set", "#set ${1:text}(${2:size: 11pt})$0", "a set rule")
snippet("typst", "show", "#show ${1:heading}: ${2:it => it}$0", "a show rule")
snippet("typst", "figure", "#figure(\n\timage(\"${1:picture.png}\", width: ${2:80%}),\n\t" &
        "caption: [${3:A caption}],\n) <${4:fig}>$0",
        "a figure with a caption and a label")
snippet("typst", "table", "#table(\n\tcolumns: ${1:2},\n\t[*${2:A}*], [*${3:B}*],\n\t$0\n)", "a table")
snippet("typst", "import", "#import \"${1:@preview/package:0.1.0}\": ${2:*}$0", "an import")
snippet("typst", "page", "#set page(paper: \"${1:a4}\", margin: ${2:2cm})$0", "the page's size and margins")
snippet("typst", "doc", "#set document(title: \"${1:Title}\", author: \"${2:Name}\")\n#set text(lang: \"${3:en}\")\n$0",
        "the document's title and author")

# ── the outline, when there is no language server ──

func typstCode(s: string, inBlock: var bool): string =
  ## the line with its comments and strings made spaces (the columns kept); a /* */ comment may go on
  result = s
  var i = 0
  while i < s.len:
    if inBlock:
      if s.continuesWith("*/", i):
        result[i] = ' '
        result[i + 1] = ' '
        inBlock = false
        i += 2
        continue
      result[i] = ' '
      inc i
    elif s.continuesWith("//", i) and (i == 0 or s[i - 1] != ':'):     # (not https://)
      for k in i ..< s.len: result[k] = ' '
      break
    elif s.continuesWith("/*", i):
      inBlock = true
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
    elif s[i] == '"':
      result[i] = ' '
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and i + 1 < s.len:
          result[i] = ' '
          inc i
        result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
      inc i
    else: inc i

# whether the character can be in a Typst name: a letter, a digit, `_` or `-`
func typstIdentChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}

func typstSymbols*(lines: seq[string]): seq[Symbol] =
  ## the headings (their level the depth), the #let functions and variables, the labels
  var inBlock = false
  var inRaw = false              # (inside a ``` block: nothing in it counts)
  var level = 0                  # (brackets open: a heading inside [ … ] is content, not the document's)
  var heading = 0                # (the level of the last heading: what follows it is under it)
  for ln, s in lines:
    let t0 = s.strip
    if t0.startsWith("```"):
      inRaw = not inRaw
      continue
    if inRaw: continue
    let code = typstCode(s, inBlock)
    let t = code.strip
    let col = code.len - code.strip(trailing = false).len
    if level == 0 and t.startsWith("="):
      var n = 0
      while n < t.len and t[n] == '=': inc n
      if n < t.len and t[n] == ' ':
        var name = s.strip[n .. ^1].strip
        let lb = name.rfind(" <")
        if lb > 0 and name.endsWith(">"): name = name[0 ..< lb].strip
        result.add Symbol(name: name, kind: "heading", line: ln, col: col, depth: min(8, n - 1))
        heading = n
    elif level == 0 and t.startsWith("#let "):
      var i = 5
      while i < t.len and t[i] == ' ': inc i
      let a = i
      while i < t.len and typstIdentChar(t[i]): inc i
      if i > a:
        let name = t[a ..< i]
        let fn = i < t.len and t[i] == '('
        var detail = ""
        if fn:
          let close = t.find(')', i)
          detail = if close > i: s.strip[i .. min(close, s.strip.len - 1)] else: "(…)"
        result.add Symbol(name: name, kind: (if fn: "function" else: "variable"), detail: detail, line: ln,
                          col: col + a, depth: heading)
    # labels: <name> at the end of something (not in a comparison: a letter right after <, > right after it)
    var k = 0
    while level == 0 and k < code.len:
      if code[k] == '<' and k + 1 < code.len and code[k + 1] in {'a'..'z', 'A'..'Z'}:
        var e = k + 1
        while e < code.len and (typstIdentChar(code[e]) or code[e] in {'.', ':'}): inc e
        if e < code.len and code[e] == '>':
          result.add Symbol(name: "<" & code[k + 1 ..< e] & ">", kind: "constant", detail: "label", line: ln,
                            col: k, depth: heading)
          k = e
      inc k
    for c in code:
      if c in {'{', '[', '('}: inc level
      elif c in {'}', ']', ')'}: level = max(0, level - 1)

# ── the tools ──

proc typstHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let typstServerSet = setting("server", "").strip
var typstServer: seq[string]
if typstServerSet == "off": discard
elif typstServerSet.len > 0:
  if typstHave(typstServerSet): typstServer = typstServerSet.splitWhitespace()
  else: echo "typst: the server " & typstServerSet & " is not installed (plugins.typst.server)"
else:
  for cmd in ["tinymist lsp", "typst-lsp"]:
    if typstHave(cmd):
      typstServer = cmd.splitWhitespace()
      break
if typstServer.len > 0:
  typstServer[0] = expandTilde(typstServer[0])
  languageServer("typst", typstServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("typst") do (b: Buf) -> seq[Symbol]:
    typstSymbols(b.lines)

let typstFmtSet = setting("formatter", "").strip
if typstFmtSet == "off": discard
elif typstFmtSet.len > 0:
  if typstHave(typstFmtSet): formatter("typst", typstFmtSet)
  else: echo "typst: the formatter " & typstFmtSet & " is not installed (plugins.typst.formatter)"
elif typstHave("typstyle"): formatter("typst", "typstyle")
