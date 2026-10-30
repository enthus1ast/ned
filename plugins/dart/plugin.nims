## dart — Dart (and Flutter): colours, comments, indentation, F5, snippets, an outline; Dart's language server and
## dart format
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Dart's `.dart` files: their colours (ned's generic
## lexer with Dart's words: Capitalised names as types, @annotations, '…' and "…" strings, '''…''' over several
## lines), `//` comments (`///` the documentation), `/* … */` blocks, indentation after `{` `(` `[`, two spaces as
## `dart format` writes, snippets (main, class, stless, stful, test, async, for, switch) and F5: `flutter run` in a
## Flutter project (a pubspec.yaml with flutter in it, above the file), `dart test` for a test file (name_test.dart),
## else `dart run` on the file. Build (Alt+B) is `dart compile exe` on the file; the check on save `dart analyze`.
##
## Without a language server, the outline lists the file's classes, mixins, enums, extensions and typedefs with their
## constructors, methods, getters and fields, and the top-level functions and variables, from a simple scan.
##
## The tools, when they are on PATH: dart (Termux `pkg install dart`; https://dart.dev/get-dart, or the one in
## Flutter's SDK) — `dart language-server` gives completion, hover, go to definition, problems; `dart format` formats
## (Format document, and on save with editor.formatOnSave).
##
## Settings (the Plugins dock › dart › its settings; Plugins: reload after a change):
## - plugins.dart.server — the language server's command, when it is not `dart language-server --protocol=lsp`
##   ("off": none)
## - plugins.dart.formatter — the formatter's command (the text on its stdin), when it is not `dart format`
import nedplugin
import std/strutils

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for dart language-server (when dart is " &
           "installed), \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for dart format " &
           "(when dart is installed), \"off\" for none. Plugins: reload after a change")

language("dart", LangSpec(
  name: "Dart",
  extensions: @["dart"],
  lineComment: "//",
  docComment: "///",
  blockComment: @["/*", "*/"],
  nestedComments: true,
  docBlockComment: @["/**", "*/"],
  quotes: "\"'",
  tripleQuotes: true,
  capitalTypes: true,
  decorators: true,
  keywords: @["abstract", "as", "assert", "async", "await", "base", "break", "case", "catch", "class", "const",
              "continue", "covariant", "default", "deferred", "do", "dynamic", "else", "enum", "export", "extends",
              "extension", "external", "factory", "final", "finally", "for", "get", "hide", "if", "implements",
              "import", "in", "interface", "is", "late", "library", "mixin", "new", "on", "operator", "part",
              "required", "rethrow", "return", "sealed", "set", "show", "static", "super", "switch", "sync", "this",
              "throw", "try", "type", "typedef", "var", "when", "while", "with", "yield"],
  types: @["int", "double", "num", "bool", "String", "List", "Map", "Set", "Iterable", "Future", "Stream",
           "Object", "void", "Never", "Function", "Record", "Duration", "DateTime", "Widget"],
  constants: @["true", "false", "null"],
  builtins: @["print", "identical", "debugPrint", "setState"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 2,
  run: "sh -c 'f=\"$file\"; d=\"$dir\"; while [ ! -f \"$d/pubspec.yaml\" ] && [ \"$d\" != / ]; do " &
       "d=$(dirname \"$d\"); done; if [ -f \"$d/pubspec.yaml\" ]; then cd \"$d\"; " &
       "case \"$f\" in *_test.dart) exec dart test \"$f\" ;; esac; " &
       "if grep -q \"^  *sdk: flutter\" pubspec.yaml; then exec flutter run; fi; fi; " &
       "case \"$f\" in *_test.dart) exec dart test \"$f\" ;; esac; exec dart run \"$f\"'",
  build: "dart compile exe \"$file\"",
  check: "dart analyze \"$file\"",
  pairs: "()[]{}\"\"''"))

snippet("dart", "main", "void main(${1:List<String> args}) {\n\t$0\n}", "a program")
snippet("dart", "class", "class ${1:Name} {\n\t${1}(${2:this.value});\n\n\tfinal ${3:int} ${4:value};$0\n}", "a class")
snippet("dart", "stless", "class ${1:MyWidget} extends StatelessWidget {\n\tconst $1({super.key});\n\n\t@override\n\tWidget build(BuildContext context) {\n\t\treturn ${2:const Placeholder()};$0\n\t}\n}", "a stateless widget (Flutter)")
snippet("dart", "stful", "class ${1:MyWidget} extends StatefulWidget {\n\tconst $1({super.key});\n\n\t@override\n\tState<$1> createState() => _$1State();\n}\n\nclass _$1State extends State<$1> {\n\t@override\n\tWidget build(BuildContext context) {\n\t\treturn ${2:const Placeholder()};$0\n\t}\n}", "a stateful widget (Flutter)")
snippet("dart", "test", "test('${1:what}', () {\n\texpect(${2:actual}, ${3:matcher});$0\n});", "a test (package:test)")
snippet("dart", "async", "Future<${1:void}> ${2:name}() async {\n\t$0\n}", "an async function")
snippet("dart", "for", "for (final ${1:item} in ${2:items}) {\n\t$0\n}", "a for-in loop")
snippet("dart", "switch", "switch (${1:value}) {\n\tcase ${2:1}:\n\t\t$0\n\tdefault:\n}", "a switch")

# ── the outline, when there is no language server ──

func dartCode(s: string, nest: var int, triple: var string): string =
  ## the line with its comments and strings made spaces (the columns kept) — `nest`: the /* */ comments open,
  ## `triple`: the ''' or """ of a string that goes on below ("" none)
  result = s
  var i = 0
  while i < s.len:
    if triple.len > 0:
      if s.continuesWith(triple, i):
        for k in i ..< i + 3: result[k] = ' '
        i += 3
        triple = ""
        continue
      result[i] = ' '
      inc i
      continue
    if s.continuesWith("/*", i):
      inc nest
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
      continue
    if nest > 0:
      if s.continuesWith("*/", i):
        dec nest
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      result[i] = ' '
      inc i
      continue
    if s.continuesWith("//", i):
      for k in i ..< s.len: result[k] = ' '
      break
    if s.continuesWith("'''", i) or s.continuesWith("\"\"\"", i):
      triple = s[i ..< i + 3]
      for k in i ..< i + 3: result[k] = ' '
      i += 3
      continue
    if s[i] == '"' or s[i] == '\'':
      let q = s[i]
      result[i] = ' '
      inc i
      while i < s.len and s[i] != q:
        if s[i] == '\\' and i + 1 < s.len:
          result[i] = ' '
          inc i
        result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
    inc i

func identEnd(s: string, i: int): int =
  ## where the name that starts at i ends: letters, digits, _ and $
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] in {'_', '$'}): inc result

const DartNotNames = ["if", "for", "while", "switch", "catch", "return", "await", "assert", "super", "this", "new",
                      "throw", "print", "else", "do", "try", "yield", "case", "when"]
const DartContainers = ["class", "mixin", "enum", "extension"]

func dartSymbols*(lines: seq[string]): seq[Symbol] =
  ## the classes, mixins, enums, extensions (with their members), typedefs, top-level functions and variables
  var nest = 0
  var triple = ""
  var level = 0
  var containerAt: seq[int]            # the brace levels that are a container's body
  var className: seq[string]
  var pending = ""                     # a container's word seen, its { not yet (on a later line)
  var pendingName = ""
  for ln, s in lines:
    let code = dartCode(s, nest, triple)
    let t = code.strip
    let col = code.len - code.strip(trailing = false).len
    let depth = containerAt.len
    let atItem = level == 0 or (containerAt.len > 0 and level == containerAt[^1])
    if atItem and t.len > 0 and not t.startsWith("@"):
      var w = t
      for pre in ["abstract ", "sealed ", "base ", "final class", "interface ", "external ", "static ", "late ",
                  "const factory ", "factory ", "@override "]:
        if w.startsWith(pre):
          w = (if pre == "final class": "class" & w[pre.len .. ^1] else: w[pre.len .. ^1])
      let first = w.split({' ', '<', '(', '{'})[0]
      if first in DartContainers or w.startsWith("extension type "):
        var a = first.len + 1
        if w.startsWith("extension type "): a = 15
        let e = identEnd(w, a)
        let name = if e > a: w[a ..< e] else: "(extension)"
        var detail = first
        for kw in [" extends ", " on ", " with ", " implements "]:
          let k = w.find(kw)
          if k > 0:
            detail &= kw & w[k + kw.len .. ^1].split({' ', '{'})[0]
            break
        result.add Symbol(name: name, kind: (if first == "enum": "enum" elif first == "mixin": "interface"
                                             else: "class"), detail: detail, line: ln,
                          col: max(0, s.find(name, col)), depth: depth)
        pending = first
        pendingName = name
      elif first == "typedef":
        let e = identEnd(w, 8)
        if e > 8: result.add Symbol(name: w[8 ..< e], kind: "type", detail: "typedef", line: ln,
                                    col: max(0, s.find(w[8 ..< e], col)), depth: depth)
      elif first notin ["import", "export", "part", "library", "return", "}", ")", "]"] and
           (w[0].isAlphaAscii or w[0] == '_'):
        # a function, a method, a constructor, a getter: (a type) name( … ) { or => — else a field or a variable
        let p = w.find('(')
        let eq = w.find('=')
        let isGetter = " get " in (" " & w) and (p < 0 or w.find(" get ") < p)
        if p > 0 and (eq < 0 or eq > p or w.continuesWith("=>", eq)) and not w.startsWith("final ") and
           not w.startsWith("var ") and not w.startsWith("const "):
          var e = p
          while e > 0 and w[e - 1] == ' ': dec e
          if e > 0 and w[e - 1] == '>':
            # a generic function: T name<T>(…)
            var dp = 0
            while e > 0:
              dec e
              if w[e] == '>': inc dp
              elif w[e] == '<':
                dec dp
                if dp == 0: break
          var a = e
          while a > 0 and (w[a - 1].isAlphaNumeric or w[a - 1] in {'_', '$', '.'}): dec a
          var name = w[a ..< e]
          if name.len > 0 and name notin DartNotNames and not name[0].isDigit:
            let insideClass = className.len > 0 and depth > 0
            let ctor = insideClass and (name == className[^1] or name.startsWith(className[^1] & "."))
            if name.startsWith("operator"): name = w[w.find("operator") ..< p].strip
            let close = w.rfind(')')
            result.add Symbol(name: name, kind: (if ctor: "constructor" elif depth > 0: "method" else: "function"),
                              detail: (if close > p: w[p .. close] else: "(…)"), line: ln,
                              col: max(0, s.find(name, col)), depth: depth)
        elif isGetter:
          let g = (" " & w).find(" get ")
          let a = g + 4
          let e = identEnd(w, a)
          if e > a: result.add Symbol(name: w[a ..< e], kind: "property", detail: "get", line: ln,
                                      col: max(0, s.find(w[a ..< e], col)), depth: depth)
        elif w.endsWith(";") or eq > 0 or w.endsWith(","):
          # final int x = …;  String name;  — the last name before = or ;
          var stop = if eq > 0: eq else: w.len
          while stop > 0 and w[stop - 1] in {' ', ';', ','}: dec stop
          var a = stop
          while a > 0 and (w[a - 1].isAlphaNumeric or w[a - 1] in {'_', '$'}): dec a
          let name = w[a ..< stop]
          let before = w[0 ..< a].strip
          if name.len > 0 and not name[0].isDigit and name notin DartNotNames and before.len > 0:
            result.add Symbol(name: name, kind: (if depth > 0: "field" elif before.startsWith("const"): "constant"
                                                 else: "variable"), detail: before, line: ln,
                              col: max(0, s.find(name, col)), depth: depth)
    for i, c in code:
      if c == '{':
        inc level
        if pending.len > 0:
          containerAt.add level
          className.add pendingName
          pending = ""
      elif c == '}':
        if containerAt.len > 0 and containerAt[^1] == level:
          discard containerAt.pop()
          discard className.pop()
        level = max(0, level - 1)
      elif c == ';' and pending.len > 0:
        # (class A = B with C; — no body)
        pending = ""

# ── the tools ──

proc dartHave(cmd: string): bool =
  ## whether the first word of the command line is a program that can be found (a ~ is expanded) — so a server or
  ## formatter that is set is only used when it is installed
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let dartServerSet = setting("server", "").strip
var dartServer: seq[string]
if dartServerSet == "off": discard
elif dartServerSet.len > 0:
  if dartHave(dartServerSet): dartServer = dartServerSet.splitWhitespace()
  else: echo "dart: the server " & dartServerSet & " is not installed (plugins.dart.server)"
elif findExe("dart").len > 0: dartServer = @["dart", "language-server", "--protocol=lsp"]
if dartServer.len > 0:
  dartServer[0] = expandTilde(dartServer[0])
  languageServer("dart", dartServer)
else:
  symbols("dart") do (b: Buf) -> seq[Symbol]:
    dartSymbols(b.lines)

let dartFmtSet = setting("formatter", "").strip
if dartFmtSet == "off": discard
elif dartFmtSet.len > 0:
  if dartHave(dartFmtSet): formatter("dart", dartFmtSet)
  else: echo "dart: the formatter " & dartFmtSet & " is not installed (plugins.dart.formatter)"
elif findExe("dart").len > 0: formatter("dart", "dart format")
