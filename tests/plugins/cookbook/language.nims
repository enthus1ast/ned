## just — a language: justfiles (the `just` command runner) coloured and indented, F5 runs them; their recipes,
## variables and aliases as the outline, completion of their names, hover over a recipe, code actions, snippets
import nedplugin

requiresNed(">= 6.31")

const
  Settings = ["allow-duplicate-recipes", "dotenv-load", "dotenv-filename", "export", "fallback",
              "positional-arguments", "quiet", "shell", "tempdir", "windows-shell", "working-directory"]
  Functions = ["arch", "os", "os_family", "env", "env_var", "env_var_or_default", "invocation_directory",
               "justfile", "justfile_directory", "just_executable", "num_cpus", "quote", "replace", "trim",
               "uppercase", "lowercase", "join", "absolute_path", "parent_directory", "file_name",
               "without_extension", "error", "uuid", "sha256"]

language("just", LangSpec(
  name: "Just",
  files: @["justfile", "Justfile", ".justfile"],  # (no extension: by the file's whole name)
  extensions: @["just"],
  lineComment: "#",
  quotes: "\"'`",
  keywords: @["alias", "export", "import", "mod", "set", "if", "else", "unexport"],
  constants: @["true", "false"],
  builtins: @Functions,
  indentAfter: @[":"],                        # a recipe's line ends in ":": its body is indented below it
  indentSize: 4,
  tripleQuotes: true,
  nameChars: "-",                             # build-docs is one name
  run: "just --justfile $file",               # F5: the first recipe
  pairs: "()[]{}\"\"''``"))

type Item = object
  ## a recipe, a variable or an alias of a justfile
  name, kind, detail, doc: string             # kind: "function" (a recipe), "variable" or "constant" (an alias)
  line, col: int

func parse(lines: seq[string]): seq[Item] =
  ## the justfile's recipes, variables and aliases, each with the comment lines just above it
  for i, l in lines:
    if l.len == 0 or l[0] in {' ', '\t', '#', '['}: continue
    var s = l
    if s.startsWith("export "): s = s[7 .. ^1]
    var it = Item(line: i)
    let assign = s.find(":=")
    if s.startsWith("alias ") and assign > 0:
      it.name = s[6 ..< assign].strip
      it.kind = "constant"
      it.detail = "alias of " & s[assign + 2 .. ^1].strip
    elif s.startsWith("set ") or s.startsWith("import ") or s.startsWith("mod "):
      continue
    elif assign > 0:
      it.name = s[0 ..< assign].strip
      it.kind = "variable"
      it.detail = s[assign + 2 .. ^1].strip
    elif s.find(':') > 0:
      let head = s[0 ..< s.find(':')].strip   # the name and its parameters
      it.name = head.splitWhitespace[0].strip(chars = {'@'})
      it.kind = "function"
      it.detail = head
    else: continue
    it.col = l.find(it.name)
    var j = i - 1                             # its comment: the # lines above it (attributes between are skipped)
    while j >= 0 and lines[j].startsWith("["): dec j
    while j >= 0 and lines[j].startsWith("#"):
      it.doc = lines[j].strip(chars = {'#', ' '}) & (if it.doc.len > 0: "\n" & it.doc else: "")
      dec j
    result.add it

func nameAt(l: string, col: int): string =
  ## the name at `col` — with the - a justfile's names may have (wordAt stops at it)
  var a = col
  var e = col
  while a > 0 and l[a - 1] in IdentChars + {'-'}: dec a
  while e < l.len and l[e] in IdentChars + {'-'}: inc e
  l[a ..< e]

# the outline (the Outline dock, Go to symbol, the breadcrumbs): every recipe, variable and alias
symbols("just") do (b: Buf) -> seq[Symbol]:
  for it in parse(b.lines):
    result.add Symbol(name: it.name, kind: it.kind, detail: it.detail, line: it.line, col: it.col)

# completion: the settings after "set", the functions in {{ }}, else the recipes and the variables
completions("just") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  let l = b.line(p.line)
  let before = l[0 ..< min(p.col, l.len)]
  if before.startsWith("set "):
    for s in Settings:
      if s.startsWith(prefix): result.add CompletionItem(label: s, kind: "keyword", detail: "a setting")
    return
  if before.rfind("{{") > before.rfind("}}"):
    for f in Functions:
      if f.startsWith(prefix):
        result.add CompletionItem(label: f, insert: f & "($1)$0", snippet: true, kind: "function",
                                  detail: "a function of just's")
  for it in parse(b.lines):
    if it.name.startsWith(prefix) and it.line != p.line:
      result.add CompletionItem(label: it.name, kind: it.kind, detail: it.detail, doc: it.doc)

# hover over a recipe's name (in its own line, or where another recipe needs it): what it is and does
hover("just") do (b: Buf, p: Pos) -> string:
  let ls = b.lines
  let w = nameAt(ls[p.line], p.col)
  if w.len == 0: return ""
  for it in parse(ls):
    if it.name != w: continue
    result = "**" & it.detail & "**" & (if it.doc.len > 0: "\n\n" & it.doc else: "")
    if it.kind == "function":
      var body: seq[string]
      var j = it.line + 1
      while j < ls.len and body.len < 8 and (ls[j].startsWith(" ") or ls[j].startsWith("\t")):
        body.add ls[j].strip
        inc j
      if body.len > 0: result.add "\n\n```sh\n" & body.join("\n") & "\n```"
    return

# Alt+Enter: on a recipe's line, add the comment that says what it does, or make it private; on lines of a
# recipe's body, make them quiet (@: just does not print them)
codeActions("just") do (b: Buf, r: Range) -> seq[Fix]:
  let ls = b.lines
  for it in parse(ls):
    if it.line != r.start.line or it.kind != "function": continue
    let top = rng(pos(it.line, 0), pos(it.line, 0))
    if it.doc.len == 0:
      result.add Fix(title: "Say what " & it.name & " does", edits: @[Edit(range: top, text: "# what it does\n")])
    if it.line == 0 or ls[it.line - 1] != "[private]":
      result.add Fix(title: "Make " & it.name & " private (not in just --list)",
                     edits: @[Edit(range: top, text: "[private]\n")])
  var quiet: seq[Edit]                        # one fix, an edit for each line: one undo step
  for i in r.start.line .. min(r.stop.line, ls.high):
    let t = ls[i].strip(trailing = false)
    if t.len > 0 and t.len < ls[i].len and not t.startsWith("@"):
      let at = pos(i, ls[i].len - t.len)
      quiet.add Edit(range: rng(at, at), text: "@")
  if quiet.len > 0:
    result.add Fix(title: "Do not print " & (if quiet.len == 1: "this line" else: "these lines") & " (@)",
                   edits: quiet)

# snippets: typing the trigger offers them in the completion list
snippet("just", "recipe", "# ${1:what it does}\n${2:name}:\n    $0", "a recipe with its comment")
snippet("just", "var", "${1:name} := \"${2:value}\"$0", "a variable")
snippet("just", "bash", "set shell := [\"bash\", \"-uc\"]$0", "run the recipes with bash")
