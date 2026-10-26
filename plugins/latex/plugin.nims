## latex — LaTeX (and BibTeX): colours, comments, indentation, F5, snippets, an outline; texlab and latexindent
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned LaTeX's `.tex`, `.sty`, `.cls` and `.ltx` files and
## BibTeX's `.bib` files. LaTeX's: their colours (ned's generic lexer: $math$ as strings, LaTeX's own commands —
## \documentclass, \usepackage, \newcommand, \textbf … — as keywords, but not the ones that are also English words,
## \section or \begin: those would colour the text too), `%` comments, indentation after `{` and `[`, a tab as
## latexindent writes, brackets and $ that close themselves, snippets (doc, begin, sec, itemize, figure, table, eq,
## frame) and F5: the document made — `latexmk -pdf` (or `pdflatex` when latexmk is not installed) on the file, or
## on the main file a `% !TEX root = main.tex` line at the top names. BibTeX's: @entries in their colour, `%`
## comments, snippets (article, book, misc).
##
## Without a language server, the outline lists a LaTeX file's parts, chapters, sections … (nested by their
## level), its \newcommands and \newenvironments — and a .bib file's entries by their keys, from a simple scan.
##
## The tools, when they are on PATH (TeX Live has latexmk and latexindent: `tlmgr install latexmk latexindent`;
## Termux: `pkg install texlive-installer`): texlab, LaTeX's language server (https://github.com/latex-lsp/texlab),
## for both — completion of commands, labels and citations, go to definition, problems; latexindent formats LaTeX
## (Format document, and on save with editor.formatOnSave).
##
## Settings (the Plugins dock › latex › its settings; Plugins: reload after a change):
## - plugins.latex.server — the language server's command, when it is not `texlab` ("off": none)
## - plugins.latex.formatter — the formatter's command (the text on its stdin), when it is not latexindent
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")

settingDef("server", "", "The language server's command, for LaTeX and BibTeX: empty for texlab (when it is " &
           "installed), \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command for LaTeX, which reads the text on its stdin: empty for " &
           "latexindent (when it is installed), \"off\" for none. Plugins: reload after a change")

language("latex", LangSpec(
  name: "LaTeX",
  extensions: @["tex", "sty", "cls", "ltx"],
  lineComment: "%",
  # ($: inline math in the colour of strings — LaTeX has no quotes of its own to colour)
  quotes: "$",
  keywords: @["documentclass", "usepackage", "RequirePackage", "newcommand", "renewcommand", "providecommand",
              "newenvironment", "renewenvironment", "DeclareMathOperator", "def", "includegraphics",
              "tableofcontents", "maketitle", "bibliographystyle", "bibliography", "addbibresource",
              "printbibliography", "newpage", "clearpage", "subsection", "subsubsection", "textbf", "textit",
              "texttt", "emph", "mathbf", "mathrm", "mathcal", "frac", "sqrt", "eqref", "autoref", "cref", "citep",
              "citet", "hline", "toprule", "midrule", "bottomrule", "usetikzlibrary", "vspace", "hspace",
              "noindent", "centering"],
  functionWords: @["newcommand", "renewcommand", "providecommand", "def", "DeclareMathOperator"],
  classWords: @["newenvironment", "renewenvironment"],
  indentAfter: @["{", "["],
  dedent: "}]",
  tabs: true,
  # (latexmk's -cd and pdflatex in the main file's folder: what they make goes beside it)
  run: "sh -c 'f=\"$file\"; r=$(sed -n \"1,5s/^%[[:space:]]*!T[Ee][Xx] root[[:space:]]*=[[:space:]]*" &
       "\\([^[:space:]]*\\).*/\\1/p\" \"$f\" | head -n 1); [ -n \"$r\" ] && f=\"$r\"; " &
       "cd \"$(dirname \"$f\")\" || exit 1; f=$(basename \"$f\"); if command -v latexmk >/dev/null 2>&1; then " &
       "exec latexmk -pdf -interaction=nonstopmode -file-line-error \"$f\"; fi; " &
       "exec pdflatex -interaction=nonstopmode -file-line-error \"$f\"'",
  pairs: "{}[]()$$"))

language("bibtex", LangSpec(
  name: "BibTeX",
  extensions: @["bib"],
  lineComment: "%",
  quotes: "\"",
  decorators: true,
  indentAfter: @["{", "("],
  dedent: "})",
  indentSize: 2,
  pairs: "{}()\"\""))

snippet("latex", "doc", "\\documentclass{${1:article}}\n\\usepackage{${2:amsmath}}\n\n\\begin{document}\n\n$0\n\n" &
        "\\end{document}", "a document")
snippet("latex", "begin", "\\begin{${1:env}}\n\t$0\n\\end{$1}", "an environment")
snippet("latex", "sec", "\\section{${1:Title}}\\label{sec:${2:name}}\n\n$0", "a section")
snippet("latex", "itemize", "\\begin{itemize}\n\t\\item ${1:first}$0\n\\end{itemize}", "a list")
snippet("latex", "figure", "\\begin{figure}[${1:htbp}]\n\t\\centering\n\t\\includegraphics[width=${2:0.8}" &
        "\\linewidth]{${3:file}}\n\t\\caption{${4:what it shows}}\n\t\\label{fig:${5:name}}\n\\end{figure}$0",
        "a figure")
snippet("latex", "table", "\\begin{table}[${1:htbp}]\n\t\\centering\n\t\\begin{tabular}{${2:ll}}\n\t\t$0\n" &
        "\t\\end{tabular}\n\t\\caption{${3:what it shows}}\n\\end{table}", "a table")
snippet("latex", "eq", "\\begin{equation}\n\t${1:x}\n\t\\label{eq:${2:name}}\n\\end{equation}$0", "an equation")
snippet("latex", "frame", "\\begin{frame}{${1:Title}}\n\t$0\n\\end{frame}", "a slide (beamer)")
snippet("bibtex", "article", "@article{${1:key},\n\tauthor  = {${2:}},\n\ttitle   = {${3:}},\n" &
        "\tjournal = {${4:}},\n\tyear    = {${5:}},\n}$0", "an article")
snippet("bibtex", "book", "@book{${1:key},\n\tauthor    = {${2:}},\n\ttitle     = {${3:}},\n" &
        "\tpublisher = {${4:}},\n\tyear      = {${5:}},\n}$0", "a book")
snippet("bibtex", "misc", "@misc{${1:key},\n\tauthor = {${2:}},\n\ttitle  = {${3:}},\n\turl    = {${4:}},\n" &
        "\tyear   = {${5:}},\n}$0", "anything else (a web page …)")

# ── the outline ──

const TexLevels = ["part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph"]
const TexVerbatim = ["verbatim", "Verbatim", "lstlisting", "minted", "comment"]

func texNoComment(s: string): string =
  ## the line up to its comment (a % that is not \%)
  var i = 0
  while i < s.len:
    if s[i] == '\\':
      i += 2
      continue
    if s[i] == '%': return s[0 ..< i]
    inc i
  s

func texGroup(s: string, at: int): (string, int) =
  ## the text in the {…} at `at` (its own braces kept): (it, where it ends) — ("", -1) when there is none
  if at >= s.len or s[at] != '{': return ("", -1)
  var depth = 0
  for k in at ..< s.len:
    if s[k] == '{' and (k == 0 or s[k - 1] != '\\'): inc depth
    elif s[k] == '}' and (k == 0 or s[k - 1] != '\\'):
      dec depth
      if depth == 0: return (s[at + 1 ..< k], k + 1)
  ("", -1)

func texSymbols*(lines: seq[string]): seq[Symbol] =
  ## the headings (\part … \subparagraph, nested by their level), the \newcommands, \DeclareMathOperators and
  ## \newenvironments — comments and verbatim text left out
  var verbatim = ""                    # the environment of the verbatim text the line is in ("" none)
  var levels: seq[int]                 # each heading's level (its depth: its rank among the levels there are)
  var heads: seq[int]                  # where the headings are in result
  for ln, s in lines:
    let t = texNoComment(s).strip
    if verbatim.len > 0:
      if t.startsWith("\\end{" & verbatim & "}"): verbatim = ""
      continue
    if t.len == 0 or t[0] != '\\': continue
    let col = s.len - s.strip(trailing = false).len
    var e = 1
    while e < t.len and t[e].isAlphaAscii: inc e
    let cmd = t[1 ..< e]
    if cmd == "begin":
      let (env, _) = texGroup(t, e)
      if env in TexVerbatim: verbatim = env
      continue
    let lv = TexLevels.find(cmd)
    if lv >= 0:
      var k = e
      if k < t.len and t[k] == '*': inc k
      if k < t.len and t[k] == '[':
        let c = t.find(']', k)
        if c > 0: k = c + 1
      let (title, stop) = texGroup(t, k)
      if stop > 0:
        heads.add result.len
        levels.add lv
        result.add Symbol(name: title.strip, kind: "heading", detail: cmd, line: ln, col: col)
    elif cmd in ["newcommand", "renewcommand", "providecommand", "DeclareMathOperator", "def"]:
      var k = e
      if k < t.len and t[k] == '*': inc k
      var name = ""
      if k < t.len and t[k] == '{':
        name = texGroup(t, k)[0].strip
      elif k < t.len and t[k] == '\\':
        var n = k + 1
        while n < t.len and t[n].isAlphaAscii: inc n
        name = t[k ..< n]
      if name.startsWith("\\"):
        result.add Symbol(name: name, kind: "function", detail: cmd, line: ln, col: max(0, s.find(name)))
    elif cmd in ["newenvironment", "renewenvironment"]:
      let name = texGroup(t, e)[0].strip
      if name.len > 0:
        result.add Symbol(name: name, kind: "class", detail: cmd, line: ln, col: max(0, s.find(name, col)))
  # (a heading's depth: how many of the levels there are come before its — a document with sections and
  # paragraphs only has its sections at the top, its paragraphs one in)
  var present: seq[int]
  for lv in levels:
    if lv notin present: present.add lv
  for i, at in heads:
    for p in present:
      if p < levels[i]: inc result[at].depth

func bibSymbols*(lines: seq[string]): seq[Symbol] =
  ## the entries by their keys, the @strings by their names (not @comment and @preamble)
  for ln, s in lines:
    let t = texNoComment(s).strip
    if not t.startsWith("@"): continue
    var e = 1
    while e < t.len and t[e].isAlphaAscii: inc e
    let kind = t[1 ..< e].toLowerAscii
    var k = e
    while k < t.len and t[k] == ' ': inc k
    if k >= t.len or t[k] notin {'{', '('} or kind in ["comment", "preamble"]: continue
    inc k
    while k < t.len and t[k] == ' ': inc k
    var n = k
    while n < t.len and t[n] notin {',', ' ', '=', '}', ')'}: inc n
    if n > k:
      let name = t[k ..< n]
      result.add Symbol(name: name, kind: (if kind == "string": "constant" else: "struct"), detail: kind, line: ln,
                        col: max(0, s.find(name)))

# ── the tools ──

proc texHave(cmd: string): bool =
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let texServerSet = setting("server", "").strip
var texServer: seq[string]
if texServerSet == "off": discard
elif texServerSet.len > 0:
  if texHave(texServerSet): texServer = texServerSet.splitWhitespace()
  else: echo "latex: the server " & texServerSet & " is not installed (plugins.latex.server)"
elif findExe("texlab").len > 0: texServer = @["texlab"]
if texServer.len > 0:
  texServer[0] = expandTilde(texServer[0])
  # (one texlab for each: ned starts a server for each language, and tells it which the file is)
  languageServer("latex", texServer)
  languageServer("bibtex", texServer)
else:
  symbols("latex") do (b: Buf) -> seq[Symbol]:
    texSymbols(b.lines)
  symbols("bibtex") do (b: Buf) -> seq[Symbol]:
    bibSymbols(b.lines)

let texFmtSet = setting("formatter", "").strip
if texFmtSet == "off": discard
elif texFmtSet.len > 0:
  if texHave(texFmtSet): formatter("latex", texFmtSet)
  else: echo "latex: the formatter " & texFmtSet & " is not installed (plugins.latex.formatter)"
else:
  # (with no file it reads stdin and writes the result to stdout; -g /dev/null: no indent.log left in the folder,
  # as its manual suggests)
  for exe in ["latexindent", "latexindent.pl"]:
    if findExe(exe).len > 0:
      formatter("latex", exe & " -g /dev/null")
      break
