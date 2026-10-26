## graphql — GraphQL: colours, comments, indentation, snippets, an outline; graphql-lsp and prettier
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned GraphQL's `.graphql`, `.gql` and `.graphqls` files —
## schemas and operations: their colours (ned's generic lexer with GraphQL's words: type, interface, input, enum,
## query, mutation, fragment …, Capitalised names as types, @directives, """descriptions""" over several lines), `#`
## comments, indentation after `{` `(` `[`, two spaces as prettier writes, brackets and quotes that close
## themselves and snippets (query, mutation, fragment, type, input, enum, interface).
##
## Without a language server, the outline lists the file's schema, types, interfaces, inputs and enums (with their
## fields and values under them), unions, scalars and directives, and its operations and fragments, from a simple
## scan.
##
## The tools, when they are on PATH: graphql-lsp, GraphQL's language server (`npm install -g
## graphql-language-service-cli`) — completion, hover, go to definition, problems; it reads the project's GraphQL
## config (a .graphqlrc, graphql.config.js …) to find the schema. prettier formats (`npm install -g prettier`;
## Format document, and on save with editor.formatOnSave).
##
## Settings (the Plugins dock › graphql › its settings; Plugins: reload after a change):
## - plugins.graphql.server — the language server's command, when it is not `graphql-lsp server -m stream` ("off":
##   none)
## - plugins.graphql.formatter — the formatter's command (the text on its stdin), when it is not prettier
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for graphql-lsp server -m stream (when it is " &
           "installed), \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for prettier (when " &
           "it is installed), \"off\" for none. Plugins: reload after a change")

language("graphql", LangSpec(
  name: "GraphQL",
  extensions: @["graphql", "gql", "graphqls"],
  lineComment: "#",
  quotes: "\"",
  tripleQuotes: true,
  capitalTypes: true,
  decorators: true,
  keywords: @["query", "mutation", "subscription", "fragment", "on", "type", "interface", "union", "enum", "input",
              "scalar", "schema", "extend", "implements", "directive", "repeatable"],
  types: @["Int", "Float", "String", "Boolean", "ID"],
  constants: @["true", "false", "null"],
  functionWords: @["query", "mutation", "subscription", "fragment"],
  classWords: @["type", "interface", "union", "enum", "input", "scalar"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 2,
  pairs: "()[]{}\"\""))

# (\$: a $ of the text — a variable — not a snippet's placeholder)
snippet("graphql", "query", "query ${1:Name}(\\$${2:id}: ${3:ID!}) {\n\t$0\n}", "a query")
snippet("graphql", "mutation", "mutation ${1:Name}(\\$${2:input}: ${3:Input!}) {\n\t$0\n}", "a mutation")
snippet("graphql", "fragment", "fragment ${1:Name} on ${2:Type} {\n\t$0\n}", "a fragment")
snippet("graphql", "type", "type ${1:Name} {\n\t${2:id}: ${3:ID!}$0\n}", "an object type")
snippet("graphql", "input", "input ${1:Name} {\n\t${2:field}: ${3:String}$0\n}", "an input type")
snippet("graphql", "enum", "enum ${1:Name} {\n\t${2:VALUE}$0\n}", "an enum")
snippet("graphql", "interface", "interface ${1:Name} {\n\t${2:id}: ${3:ID!}$0\n}", "an interface")

# ── the outline, when there is no language server ──

func gqlCode(s: string, triple: var bool): string =
  ## the line with its comments and strings made spaces (the columns kept) — `triple`: inside a """description"""
  ## that goes on below
  result = s
  var i = 0
  while i < s.len:
    if triple:
      if s.continuesWith("\"\"\"", i):
        triple = false
        for k in i ..< i + 3: result[k] = ' '
        i += 3
      else:
        result[i] = ' '
        inc i
      continue
    if s[i] == '#':
      for k in i ..< s.len: result[k] = ' '
      break
    if s.continuesWith("\"\"\"", i):
      triple = true
      for k in i ..< i + 3: result[k] = ' '
      i += 3
      continue
    if s[i] == '"':
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

func gqlNameEnd(s: string, i: int): int =
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] == '_'): inc result

func gqlWordAt(s: string, i: int): (string, int) =
  ## the name after spaces at i: (it, where it ends)
  var a = i
  while a < s.len and s[a] == ' ': inc a
  let e = gqlNameEnd(s, a)
  (s[a ..< e], e)

func gqlSymbols*(lines: seq[string]): seq[Symbol] =
  ## the schema, the types with their fields (enums with their values), unions, scalars, directives, the
  ## operations and fragments
  var triple = false
  var stack: seq[string]               # the braces open: a definition's kind ("type", "enum" …: its fields
  #                                      listed) or "" (an operation's selections, a value)
  var parens = 0                       # arguments over several lines (their names are not fields)
  var pending = ""                     # a definition whose `{` is on a line below
  for ln, s in lines:
    let code = gqlCode(s, triple)
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    var opens = ""
    template put(nm, kd, dt: string, d: int) =
      result.add Symbol(name: nm, kind: kd, detail: dt, line: ln, col: max(0, s.find(nm, col)), depth: d)
    if stack.len == 0 and parens == 0:
      var (first, e) = gqlWordAt(t, 0)
      var detail = first
      if first == "extend":
        (first, e) = gqlWordAt(t, e)
        detail = "extend " & first
      case first
      of "schema":
        put("schema", "module", detail, 0)
        opens = "schema"
      of "type", "interface", "input", "enum", "union", "scalar":
        let (n, _) = gqlWordAt(t, e)
        if n.len > 0:
          let kind = case first
                     of "type": "class"
                     of "interface": "interface"
                     of "input": "struct"
                     of "enum": "enum"
                     else: "type"
          put(n, kind, detail, 0)
        opens = first
      of "directive":
        let at = t.find('@', e)
        if at >= 0:
          let n = t[at ..< gqlNameEnd(t, at + 1)]
          put(n, "function", "directive", 0)
      of "query", "mutation", "subscription":
        let (n, _) = gqlWordAt(t, e)
        if n.len > 0: put(n, "function", first, 0)
        opens = "op"
      of "fragment":
        let (n, e2) = gqlWordAt(t, e)
        let (onW, e3) = gqlWordAt(t, e2)
        let (target, _) = gqlWordAt(t, e3)
        if n.len > 0: put(n, "function", "fragment" & (if onW == "on": " on " & target else: ""), 0)
        opens = "op"
      else:
        if t.startsWith("{"): opens = "op"
    elif stack.len == 1 and parens == 0 and stack[0] notin ["", "op"]:
      # a field (name, its arguments and type) or an enum's value
      let e = gqlNameEnd(t, 0)
      if e > 0:
        if stack[0] == "enum":
          put(t[0 ..< e], "constant", "", 1)
        else:
          var rest = t[e .. ^1].strip
          if rest.startsWith(":"): rest = rest[1 .. ^1].strip
          let at = rest.find(" @")
          if at >= 0: rest = rest[0 ..< at]
          put(t[0 ..< e], "field", rest, 1)
    # the braces and parentheses
    var kind = if opens.len > 0: opens else: pending
    var opened = false
    for c in code:
      case c
      of '{':
        stack.add (if kind == "op": "" else: kind)
        kind = ""
        opened = true
      of '}':
        if stack.len > 0: discard stack.pop()
      of '(': inc parens
      of ')': parens = max(0, parens - 1)
      else: discard
    pending = if opens.len > 0 and not opened and opens notin ["union", "scalar"]: opens else: ""

# ── the tools ──

proc gqlHave(cmd: string): bool =
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let gqlServerSet = setting("server", "").strip
var gqlServer: seq[string]
if gqlServerSet == "off": discard
elif gqlServerSet.len > 0:
  if gqlHave(gqlServerSet): gqlServer = gqlServerSet.splitWhitespace()
  else: echo "graphql: the server " & gqlServerSet & " is not installed (plugins.graphql.server)"
elif findExe("graphql-lsp").len > 0: gqlServer = @["graphql-lsp", "server", "-m", "stream"]
if gqlServer.len > 0:
  gqlServer[0] = expandTilde(gqlServer[0])
  languageServer("graphql", gqlServer)
else:
  symbols("graphql") do (b: Buf) -> seq[Symbol]:
    gqlSymbols(b.lines)

let gqlFmtSet = setting("formatter", "").strip
if gqlFmtSet == "off": discard
elif gqlFmtSet.len > 0:
  if gqlHave(gqlFmtSet): formatter("graphql", gqlFmtSet)
  else: echo "graphql: the formatter " & gqlFmtSet & " is not installed (plugins.graphql.formatter)"
elif findExe("prettier").len > 0:
  # (--stdin-filepath: the file's name picks prettier's GraphQL parser, its folder the project's .prettierrc)
  formatter("graphql", "prettier --stdin-filepath \"$file\"")
