## gleam — Gleam: colours, comments, indentation, F5, snippets, an outline; gleam lsp and gleam format
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Gleam's `.gleam` files: their colours (ned's generic
## lexer with Gleam's words: Capitalised names as types and constructors, strings over several lines,
## @attributes), `//` comments (`///` and `////`, the documentation, in its colour), indentation after `{` `(` `[`
## `->` and `=`, two spaces as `gleam format` writes, brackets and quotes that close themselves, snippets (pub fn,
## fn, type, case, use) and F5: `gleam run` in the project (the folder with gleam.toml, above the file) —
## `gleam test` for a file of its test folder. Build (Alt+B) is `gleam build`, and `gleam check` checks it.
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the file's functions, types with their
## constructors under them, and constants, from a simple scan.
##
## The tools, when they are on PATH — one program, gleam: Termux `pkg install gleam` (it brings Erlang);
## elsewhere https://gleam.run/getting-started/installing/
## - `gleam lsp`, Gleam's language server: completion, hover, go to definition, problems, code actions, the outline
## - `gleam format --stdin`, the formatter (Format document, and on save with editor.formatOnSave)
##
## Settings (the Plugins dock › gleam › its settings; Plugins: reload after a change):
## - plugins.gleam.server — the language server's command, when it is not `gleam lsp` ("off": none)
## - plugins.gleam.formatter — the formatter's command (the text on its stdin), when it is not
##   `gleam format --stdin` ("off": none)
import nedplugin

requiresNed(">= 6.25")

settingDef("server", "", "The language server's command: empty for gleam lsp (when gleam is installed), \"off\" " &
           "for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for " &
           "gleam format --stdin (when gleam is installed), \"off\" for none. Plugins: reload after a change")

language("gleam", LangSpec(
  name: "Gleam",
  extensions: @["gleam"],
  lineComment: "//",
  docComment: "///",
  quotes: "\"",
  multilineStrings: true,
  capitalTypes: true,
  decorators: true,
  keywords: @["as", "assert", "case", "const", "echo", "fn", "if", "import", "let", "opaque", "panic", "pub", "todo",
              "type", "use",
              # (reserved: no use yet)
              "auto", "delegate", "derive", "else", "implement", "macro", "test"],
  constants: @["True", "False", "Nil"],    # (other constructors, Ok and Error among them, as types)
  classWords: @["type"],
  indentAfter: @["{", "(", "[", "->", "="],
  dedent: "})]",
  indentSize: 2,
  # (gleam finds the project's gleam.toml above the folder itself; only the test folder's files need telling)
  run: "sh -c 'while [ ! -f gleam.toml ] && [ \"$PWD\" != / ]; do cd ..; done; " &
       "case \"$file\" in \"$PWD\"/test/*) exec gleam test ;; *) exec gleam run ;; esac'",
  build: "gleam build",
  check: "gleam check",
  pairs: "()[]{}\"\""))

snippet("gleam", "pub", "pub fn ${1:name}($2) -> ${3:Nil} {\n\t$0\n}", "a public function")
snippet("gleam", "fn", "fn ${1:name}($2) -> ${3:Nil} {\n\t$0\n}", "a private function")
snippet("gleam", "type", "pub type ${1:Name} {\n\t${2:Constructor}($3)\n}$0", "a custom type")
snippet("gleam", "case", "case ${1:value} {\n\t${2:pattern} -> ${3:todo}\n\t_ -> $0\n}", "a case expression")
snippet("gleam", "use", "use ${1:x} <- ${2:result.try}(${3:value})\n$0", "a use expression")

# ── the outline, when there is no language server ──

func gleamIdentStart(c: char): bool = c in {'a'..'z', 'A'..'Z', '_'}
func gleamIdentChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc gleamCode(s: string, inString: var bool): string =
  ## the line with its comments and strings made spaces (the columns kept); a string may go on to the next line
  result = s
  var i = 0
  while i < s.len:
    if inString:
      if s[i] == '\\' and i + 1 < s.len:
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      if s[i] == '"': inString = false
      result[i] = ' '
      inc i
    elif s.continuesWith("//", i):
      for k in i ..< s.len: result[k] = ' '
      break
    elif s[i] == '"':
      inString = true
      result[i] = ' '
      inc i
    else: inc i

proc gleamWord(code: string, i: var int): string =
  ## the word at i (i moves past it and the spaces after it)
  let a = i
  while i < code.len and gleamIdentChar(code[i]): inc i
  result = code[a ..< i]
  while i < code.len and code[i] in {' ', '\t'}: inc i

proc gleamSymbols(lines: seq[string]): seq[Symbol] =
  ## the top-level functions, types and constants — a custom type's constructors under it
  var inString = false
  var level = 0
  var inType = false             # inside a custom type's { … }: its constructors
  for ln, s in lines:
    let code = gleamCode(s, inString)
    var i = 0
    while i < code.len and code[i] in {' ', '\t'}: inc i
    if level == 0:
      var pub = false
      var opaque = false
      var w = gleamWord(code, i)
      if w == "pub":
        pub = true
        w = gleamWord(code, i)
      if w == "opaque":
        opaque = true
        w = gleamWord(code, i)
      if w in ["fn", "type", "const"] and i < code.len and gleamIdentStart(code[i]):
        let col = i
        let name = gleamWord(code, i)
        let vis = (if pub: "pub " else: "") & (if opaque: "opaque " else: "")
        case w
        of "fn":
          # its signature: from ( up to the body's {
          let p = code.find('(', col)
          var e = code.strip(leading = false).len
          let brace = code.rfind('{')
          if brace > p and p >= 0: e = brace
          var sig = (if p >= 0: s[p ..< max(p, e)].strip else: "")
          if sig.endsWith("("): sig = "(…)"
          result.add Symbol(name: name, kind: "function", detail: (vis & sig).strip, line: ln, col: col)
        of "type":
          let alias = code.find('=', col) >= 0
          result.add Symbol(name: name, kind: "type", detail: (vis & "type" & (if alias: " =" else: "")).strip,
                            line: ln, col: col)
          inType = not alias and code.find('{', col) >= 0
        else:
          result.add Symbol(name: name, kind: "constant", detail: (vis & "const").strip, line: ln, col: col)
    elif level == 1 and inType and i < code.len and code[i] in {'A'..'Z'}:
      let col = i
      let name = gleamWord(code, i)
      var detail = ""
      if i < code.len and code[i] == '(':
        detail = s[i ..< code.strip(leading = false).len].strip
        if detail.endsWith("("): detail = "(…)"
      result.add Symbol(name: name, kind: "constructor", detail: detail, line: ln, col: col, depth: 1)
    for c in code:
      if c in {'{', '(', '['}: inc level
      elif c in {'}', ')', ']'}: level = max(0, level - 1)
    if level == 0: inType = false

# ── the tools ──

proc gleamHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let gleamServerSet = setting("server", "").strip
var gleamServer: seq[string]
if gleamServerSet == "off": discard
elif gleamServerSet.len > 0:
  if gleamHave(gleamServerSet): gleamServer = gleamServerSet.splitWhitespace()
  else: echo "gleam: the server " & gleamServerSet & " is not installed (plugins.gleam.server)"
elif findExe("gleam").len > 0: gleamServer = @["gleam", "lsp"]
if gleamServer.len > 0:
  gleamServer[0] = expandTilde(gleamServer[0])
  languageServer("gleam", gleamServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("gleam") do (b: Buf) -> seq[Symbol]:
    gleamSymbols(b.lines)

let gleamFmtSet = setting("formatter", "").strip
if gleamFmtSet == "off": discard
elif gleamFmtSet.len > 0:
  if gleamHave(gleamFmtSet): formatter("gleam", gleamFmtSet)
  else: echo "gleam: the formatter " & gleamFmtSet & " is not installed (plugins.gleam.formatter)"
elif findExe("gleam").len > 0: formatter("gleam", "gleam format --stdin")
