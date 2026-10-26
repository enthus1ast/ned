## scala — Scala (2 and 3, sbt files too): colours, comments, indentation, F5, snippets, an outline; Metals and scalafmt
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Scala's `.scala`, `.sc` and `.sbt` files: their
## colours (ned's generic lexer with Scala's words — Scala 3's too: given, using, enum, extension, then … —,
## Capitalised names as types, @annotations, """strings""" over several lines, 'c' characters), `//` and `/* … */`
## comments (nested, as Scala's are; `/** */` the documentation), indentation after `{` `(` `[`, `=`, `=>` and Scala
## 3's `:`, then, else, do, match … (two spaces, as scalafmt writes), brackets and quotes that close themselves,
## snippets (def, class, caseclass, object, trait, enum, match, for, main, test) and F5: `sbt run` in an sbt
## project (a build.sbt above the file; `sbt test` for a file of its src/test), else scala-cli on the file
## (`scala-cli test` for a .test.scala), or `scala file` when scala-cli is not installed. Build (Alt+B) is `sbt
## compile` in an sbt project, `scala-cli compile file` outside one.
##
## Without a language server, the outline lists the file's package, objects, classes, traits and enums (with the
## defs, vals, vars and types in them — in braces or by indentation), its top-level defs, vals and types, from a
## simple scan.
##
## The tools, when they are on PATH (Coursier installs them: `cs install metals scalafmt scala-cli`, see
## https://get-coursier.io): Metals, Scala's language server — completion, hover, go to definition, problems
## (it imports an sbt project's build the first time: that takes a while); scalafmt formats (Format document, and on
## save with editor.formatOnSave), with the project's .scalafmt.conf.
##
## Settings (the Plugins dock › scala › its settings; Plugins: reload after a change):
## - plugins.scala.server — the language server's command, when it is not `metals` ("off": none)
## - plugins.scala.formatter — the formatter's command (the text on its stdin), when it is not scalafmt
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for metals (when it is installed), \"off\" for " &
           "none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for scalafmt (when " &
           "it is installed), \"off\" for none. Plugins: reload after a change")

language("scala", LangSpec(
  name: "Scala",
  extensions: @["scala", "sc", "sbt"],
  lineComment: "//",
  blockComment: @["/*", "*/"],
  nestedComments: true,
  docBlockComment: @["/**", "*/"],
  quotes: "\"",
  tripleQuotes: true,
  charLiterals: true,
  capitalTypes: true,
  decorators: true,
  keywords: @["abstract", "case", "catch", "class", "def", "do", "else", "enum", "export", "extends", "final",
              "finally", "for", "forSome", "given", "if", "implicit", "import", "lazy", "match", "new", "object",
              "override", "package", "private", "protected", "return", "sealed", "super", "then", "this", "throw",
              "trait", "try", "type", "val", "var", "while", "with", "yield", "using", "as", "derives", "end",
              "extension", "infix", "inline", "opaque", "open", "transparent"],
  constants: @["true", "false", "null", "None", "Nil"],
  builtins: @["println", "print", "require", "assert", "assume", "implicitly", "summon", "classOf", "identity"],
  functionWords: @["def"],
  classWords: @["class", "object", "trait", "enum"],
  indentAfter: @["{", "(", "[", "=", "=>", ":", "then", "else", "do", "yield", "match", "try", "catch", "finally",
                 "with"],
  dedentWords: @["end", "else", "catch", "finally"],
  dedent: "})]",
  indentSize: 2,
  run: "sh -c 'f=\"$file\"; d=\"$dir\"; while [ ! -f \"$d/build.sbt\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); " &
       "done; if [ -f \"$d/build.sbt\" ]; then cd \"$d\"; case \"$f\" in */src/test/*) exec sbt test ;; esac; " &
       "exec sbt run; fi; if command -v scala-cli >/dev/null 2>&1; then case \"$f\" in *.test.scala) " &
       "exec scala-cli test \"$f\" ;; esac; exec scala-cli run \"$f\"; fi; exec scala \"$f\"'",
  # (sbt in the folder of build.sbt: run anywhere else, it would make a project there)
  build: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/build.sbt\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
         "if [ -f \"$d/build.sbt\" ]; then cd \"$d\" && exec sbt compile; fi; exec scala-cli compile \"$file\"'",
  pairs: "()[]{}\"\""))

snippet("scala", "def", "def ${1:name}(${2:x: Int}): ${3:Int} =\n\t$0", "a function")
snippet("scala", "class", "class ${1:Name}(${2:x: Int}):\n\t$0", "a class")
snippet("scala", "caseclass", "case class ${1:Name}(${2:x: Int})$0", "a case class")
snippet("scala", "object", "object ${1:Name}:\n\t$0", "an object")
snippet("scala", "trait", "trait ${1:Name}:\n\tdef ${2:name}: ${3:Int}$0", "a trait")
snippet("scala", "enum", "enum ${1:Name}:\n\tcase ${2:A}, ${3:B}$0", "an enum")
snippet("scala", "match", "${1:x} match\n\tcase ${2:pattern} => ${3:()}\n\tcase _ => $0", "a match")
snippet("scala", "for", "for ${1:x} <- ${2:xs} do\n\t$0", "a for loop")
snippet("scala", "main", "@main def ${1:run}(): Unit =\n\t$0", "a program")
snippet("scala", "test", "test(\"${1:what}\") {\n\tassert(${2:true})$0\n}", "a test (munit, ScalaTest)")

# ── the outline, when there is no language server ──

func scalaCode(s: string, nest: var int, triple: var bool): string =
  ## the line with its comments, strings and characters made spaces (the columns kept) — `nest`: the block
  ## comments open, `triple`: inside a """string""" that goes on below
  result = s
  var i = 0
  while i < s.len:
    if triple:
      if s.continuesWith("\"\"\"", i):
        triple = false
        var e = i + 3
        while e < s.len and s[e] == '"': inc e       # (""""a"""" ends at its last quotes)
        for k in i ..< e: result[k] = ' '
        i = e
        continue
      result[i] = ' '
      inc i
      continue
    if nest > 0:
      if s.continuesWith("*/", i):
        dec nest
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
      elif s.continuesWith("/*", i):
        inc nest
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
      else:
        result[i] = ' '
        inc i
      continue
    if s.continuesWith("//", i):
      for k in i ..< s.len: result[k] = ' '
      break
    if s.continuesWith("/*", i):
      inc nest
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
      continue
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
    elif s[i] == '\'' and i + 2 < s.len and (s[i + 2] == '\'' or s[i + 1] == '\\'):
      # a character ('a', '\n'), not a symbol ('sym)
      var k = i + 1
      if s[k] == '\\': k += 2
      else: inc k
      while k < s.len and s[k] != '\'' and k < i + 8: inc k
      if k < s.len and s[k] == '\'':
        for j in i .. k: result[j] = ' '
        i = k + 1
        continue
    inc i

func scalaIdentEnd(s: string, i: int): int =
  result = i
  if i < s.len and s[i] == '`':
    let e = s.find('`', i + 1)
    return if e < 0: s.len else: e + 1
  while result < s.len and (s[result].isAlphaNumeric or s[result] == '_' or ord(s[result]) >= 128): inc result
  if result == i:
    # an operator's name: def +(that: V), def ::(x: A)
    while result < s.len and s[result] in {'+', '-', '*', '/', '%', '<', '>', '=', '!', '&', '|', '^', '~', ':',
                                           '?', '#', '@', '\\'}:
      inc result

func scalaWord(w: string): string =
  var e = 0
  while e < w.len and (w[e].isAlphaNumeric or w[e] == '_'): inc e
  w[0 ..< e]

const ScalaModifiers = ["private", "protected", "override", "final", "sealed", "abstract", "implicit", "lazy",
                        "inline", "transparent", "opaque", "open", "infix", "export"]

func scalaStrip(t: string, isCase: var bool): string =
  ## the declaration without its @annotations and modifiers (`@main private def` → `def`); isCase: `case class`
  result = t
  isCase = false
  while true:
    if result.startsWith("@"):
      var e = scalaIdentEnd(result, 1)
      while e < result.len and result[e] == '.': e = scalaIdentEnd(result, e + 1)
      if e < result.len and result[e] == '(':
        let c = result.find(')', e)
        e = if c < 0: result.len else: c + 1
      result = result[e .. ^1].strip(trailing = false)
      continue
    let w = scalaWord(result)
    var after = w.len
    if after < result.len and result[after] == '[' and w in ["private", "protected"]:
      # private[pkg]
      let c = result.find(']', after)
      after = if c < 0: result.len else: c + 1
    if w in ScalaModifiers:
      result = result[after .. ^1].strip(trailing = false)
      continue
    if w == "case" and scalaWord(result[after .. ^1].strip) in ["class", "object"]:
      isCase = true
      result = result[after .. ^1].strip(trailing = false)
      continue
    break

func scalaDetail(w: string, at: int): string =
  ## a def's parameters and type (`(x: Int): Int`), up to its `=` or `{`
  var r = w[at .. ^1]
  for stop in [" = ", " {"]:
    let k = r.find(stop)
    if k >= 0: r = r[0 ..< k]
  r = r.strip
  if r.endsWith("="): r = r[0 ..< r.len - 1].strip
  r

const ScalaContainers = ["object", "class", "trait", "enum", "extension"]

func scalaSymbols*(lines: seq[string]): seq[Symbol] =
  ## the package, objects, classes, traits, enums and extensions with what is in them, the top-level defs, vals,
  ## vars and types — in braces or by indentation (Scala 3), not inside a def's body
  var nest = 0
  var triple = false
  # the blocks open: (a container's body?, its column when it goes by indentation — -1: in braces)
  var stack: seq[(bool, int)]
  var pending = false                  # a container's declaration whose `{` is on a line below
  for ln, s in lines:
    let code = scalaCode(s, nest, triple)
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    # (a line as far left as a block that goes by indentation, or further: that block is over)
    while stack.len > 0 and stack[^1][1] >= 0 and col <= stack[^1][1]: discard stack.pop()
    var depth = 0
    var inCode = false
    for (isBody, _) in stack:
      if isBody: inc depth
      else: inCode = true
    var isCase = false
    let w = scalaStrip(t, isCase)
    let first = scalaWord(w)
    var container = false
    var hasBody = false                # a def, val or var whose body goes on below (`=` at the end)
    template put(nm, kd, dt: string) =
      if not inCode:
        result.add Symbol(name: nm, kind: kd, detail: dt, line: ln, col: max(0, s.find(nm, col)), depth: depth)
    case first
    of "package":
      if w.startsWith("package object "):
        container = true
        let a = 15
        let e = scalaIdentEnd(w, a)
        if e > a: put(w[a ..< e], "object", "package object")
      elif stack.len == 0:
        let a = 8
        var e = a
        while e < w.len and (w[e].isAlphaNumeric or w[e] in {'_', '.'}): inc e
        if e > a:
          put(w[a ..< e], "module", "package")
          container = '{' in w
    of "object", "class", "trait", "enum":
      container = true
      var a = first.len
      while a < w.len and w[a] == ' ': inc a
      let e = scalaIdentEnd(w, a)
      if e > a:
        let kind = case first
                   of "trait": "interface"
                   of "enum": "enum"
                   of "object": "object"
                   else: "class"
        put(w[a ..< e], kind, (if isCase: "case " & first else: first))
    of "extension":
      container = true
      let p = w.find('(')
      let close = w.find(')', p + 1)
      if p >= 0 and close > p: put("extension " & w[p .. close], "class", "extension")
    of "def":
      var a = 3
      while a < w.len and w[a] == ' ': inc a
      let e = scalaIdentEnd(w, a)
      if e > a: put(w[a ..< e], (if depth > 0: "method" else: "function"), scalaDetail(w, e))
      hasBody = true
    of "val", "var":
      var a = 3
      while a < w.len and w[a] == ' ': inc a
      let e = scalaIdentEnd(w, a)
      if e > a and w[a] notin {'(', '{'}:
        put(w[a ..< e], (if first == "val": "constant" else: "variable"), first)
      hasBody = true
    of "type":
      var a = 4
      while a < w.len and w[a] == ' ': inc a
      let e = scalaIdentEnd(w, a)
      if e > a: put(w[a ..< e], "type", "type")
    of "given":
      hasBody = true
    else: discard
    # the blocks: a container's `{` (perhaps on a line below) or its `:` at the end opens its body; a def's `=` at
    # the end opens code that goes by indentation; any other `{` is code
    var bodyOpen = container or pending
    var opened = false
    for c in code:
      if c == '{':
        stack.add (bodyOpen, -1)
        bodyOpen = false
        opened = true
      elif c == '}':
        # (the blocks by indentation inside the braces end with them)
        while stack.len > 0 and stack[^1][1] >= 0: discard stack.pop()
        if stack.len > 0: discard stack.pop()
    if not opened:
      # (an extension's defs go by indentation with no `:` before them)
      if container and (t.endsWith(":") or first == "extension"): stack.add (true, col)
      elif hasBody and (t.endsWith("=") or t.endsWith("=>") or t.endsWith(" with")): stack.add (false, col)
    pending = container and not opened and not t.endsWith(":") and not inCode and
              (ln + 1 < lines.len and lines[ln + 1].strip.startsWith("{"))

# ── the tools ──

proc scalaHave(cmd: string): bool =
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let scalaServerSet = setting("server", "").strip
var scalaServer: seq[string]
if scalaServerSet == "off": discard
elif scalaServerSet.len > 0:
  if scalaHave(scalaServerSet): scalaServer = scalaServerSet.splitWhitespace()
  else: echo "scala: the server " & scalaServerSet & " is not installed (plugins.scala.server)"
elif findExe("metals").len > 0: scalaServer = @["metals"]
if scalaServer.len > 0:
  scalaServer[0] = expandTilde(scalaServer[0])
  languageServer("scala", scalaServer)
else:
  symbols("scala") do (b: Buf) -> seq[Symbol]:
    scalaSymbols(b.lines)

let scalaFmtSet = setting("formatter", "").strip
if scalaFmtSet == "off": discard
elif scalaFmtSet.len > 0:
  if scalaHave(scalaFmtSet): formatter("scala", scalaFmtSet)
  else: echo "scala: the formatter " & scalaFmtSet & " is not installed (plugins.scala.formatter)"
elif findExe("scalafmt").len > 0:
  # (--assume-filename: an .sbt or .sc file is formatted as one, and the rules of .scalafmt.conf for its path apply)
  formatter("scala", "scalafmt --stdin --assume-filename \"$file\"")
