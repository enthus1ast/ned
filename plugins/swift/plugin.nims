## swift — Swift: colours, comments, indentation, F5, snippets, an outline; sourcekit-lsp and swift-format
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Swift's `.swift` files: their colours (ned's generic
## lexer with Swift's words: Capitalised names as types, @attributes — @MainActor, @State … —, """strings""" over
## several lines), `//` and `/* … */` comments (nested, as Swift's are; `///` and `/** */` the documentation),
## indentation after `{` `(` `[`, two spaces as swift-format writes unless told otherwise, brackets and quotes that
## close themselves, snippets (func, struct, class, enum, protocol, extension, guard, iflet, for, switch, test) and
## F5: `swift run` in a package (a Package.swift above the file; `swift test` for a file of its Tests folder), else
## `swift file` — the file run as a script. Build (Alt+B) is `swift build`, and the check on save `swiftc -parse`
## (the syntax only: quick).
##
## Without a language server, the outline lists the file's classes, structs, enums, protocols, actors and
## extensions (with their functions, initialisers, subscripts and properties under them), its functions, type
## aliases and top-level constants and variables, from a simple scan.
##
## The tools, when they are on PATH — they come with Swift's toolchain (https://www.swift.org/install; Termux: `pkg
## install swift`): sourcekit-lsp, Swift's language server — completion, hover, go to definition, problems;
## swift-format formats (Format document, and on save with editor.formatOnSave), with the project's .swift-format
## when it has one.
##
## Settings (the Plugins dock › swift › its settings; Plugins: reload after a change):
## - plugins.swift.server — the language server's command, when it is not `sourcekit-lsp` ("off": none)
## - plugins.swift.formatter — the formatter's command (the text on its stdin), when it is not swift-format
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for sourcekit-lsp (when it is installed), \"off\" " &
           "for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for swift-format " &
           "(when it is installed), \"off\" for none. Plugins: reload after a change")

language("swift", LangSpec(
  name: "Swift",
  extensions: @["swift"],
  lineComment: "//",
  blockComment: @["/*", "*/"],
  nestedComments: true,
  docComment: "///",
  docBlockComment: @["/**", "*/"],
  quotes: "\"",
  tripleQuotes: true,
  capitalTypes: true,
  decorators: true,
  keywords: @["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class",
              "continue", "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum",
              "extension", "fallthrough", "fileprivate", "final", "for", "func", "get", "guard", "if", "import",
              "in", "indirect", "init", "inout", "internal", "is", "isolated", "lazy", "let", "macro", "mutating",
              "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package",
              "precedencegroup", "private", "protocol", "public", "repeat", "required", "rethrows", "return",
              "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch", "throw", "throws",
              "try", "typealias", "unowned", "var", "weak", "where", "while", "willSet", "borrowing", "consuming",
              "consume"],
  constants: @["true", "false", "nil"],
  builtins: @["print", "debugPrint", "fatalError", "precondition", "assert", "min", "max", "abs", "zip", "stride",
              "type"],
  functionWords: @["func"],
  # (not "class": `class func` and `class var` would colour func and var as a type's name)
  classWords: @["struct", "enum", "protocol", "actor", "extension"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 2,
  run: "sh -c 'f=\"$file\"; d=\"$dir\"; while [ ! -f \"$d/Package.swift\" ] && [ \"$d\" != / ]; do " &
       "d=$(dirname \"$d\"); done; if [ -f \"$d/Package.swift\" ]; then cd \"$d\"; case \"$f\" in \"$d\"/Tests/*) " &
       "exec swift test ;; esac; exec swift run; else exec swift \"$f\"; fi'",
  # (swift build finds the Package.swift above the folder itself)
  build: "swift build",
  check: "swiftc -parse \"$file\"",
  pairs: "()[]{}\"\""))

snippet("swift", "func", "func ${1:name}(${2}) -> ${3:Void} {\n\t$0\n}", "a function")
snippet("swift", "struct", "struct ${1:Name} {\n\tvar ${2:field}: ${3:Int}\n$0\n}", "a struct")
snippet("swift", "class", "final class ${1:Name} {\n\tinit(${2}) {\n\t\t$0\n\t}\n}", "a class")
snippet("swift", "enum", "enum ${1:Name} {\n\tcase ${2:a}, ${3:b}$0\n}", "an enum")
snippet("swift", "protocol", "protocol ${1:Name} {\n\tfunc ${2:name}()$0\n}", "a protocol")
snippet("swift", "extension", "extension ${1:Type} {\n\t$0\n}", "an extension")
snippet("swift", "guard", "guard let ${1:value} = ${2:optional} else {\n\treturn$0\n}", "a guard let")
snippet("swift", "iflet", "if let ${1:value} = ${2:optional} {\n\t$0\n}", "an if let")
snippet("swift", "for", "for ${1:item} in ${2:items} {\n\t$0\n}", "a for loop")
snippet("swift", "switch", "switch ${1:value} {\ncase ${2:.a}:\n\t${3:break}\ndefault:\n\t$0\n}", "a switch")
snippet("swift", "test", "@Test func ${1:name}() {\n\t#expect(${2:true})$0\n}", "a test (Swift Testing)")

# ── the outline, when there is no language server ──

func swiftCode(s: string, nest: var int, triple: var bool): string =
  ## the line with its comments and strings made spaces (the columns kept) — `nest`: the block comments open,
  ## `triple`: inside a """string""" that goes on below
  result = s
  var i = 0
  while i < s.len:
    if triple:
      if s.continuesWith("\"\"\"", i):
        triple = false
        for k in i ..< i + 3: result[k] = ' '
        i += 3
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
    inc i

func swiftIdentEnd(s: string, i: int): int =
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] in {'_', '`'} or ord(s[result]) >= 128):
    inc result

const SwiftModifiers = ["public", "private", "fileprivate", "internal", "open", "package", "static", "final",
                        "override", "mutating", "nonmutating", "convenience", "required", "lazy", "weak",
                        "unowned", "dynamic", "indirect", "nonisolated", "optional", "prefix", "postfix", "infix"]
const SwiftTypeWords = ["class", "struct", "enum", "protocol", "actor", "extension"]

func swiftWord(w: string): string =
  ## the first word of w (up to a space, a bracket, a colon …)
  var e = 0
  while e < w.len and (w[e].isAlphaNumeric or w[e] == '_'): inc e
  w[0 ..< e]

func swiftStrip(t: string): string =
  ## the declaration without its @attributes and modifiers (`@MainActor public static func` → `func`)
  result = t
  while true:
    if result.startsWith("@"):
      var e = swiftIdentEnd(result, 1)
      if e < result.len and result[e] == '(':
        let c = result.find(')', e)
        e = if c < 0: result.len else: c + 1
      result = result[e .. ^1].strip(trailing = false)
      continue
    let w = swiftWord(result)
    var after = w.len
    if after < result.len and result[after] == '(' and w in ["private", "fileprivate", "internal", "public",
                                                              "package", "unowned", "nonisolated"]:
      # private(set), unowned(unsafe)
      let c = result.find(')', after)
      after = if c < 0: result.len else: c + 1
    if w in SwiftModifiers or (w == "class" and swiftWord(result[after .. ^1].strip) in
                               ["func", "var", "let", "subscript", "override", "final", "static"]):
      result = result[after .. ^1].strip(trailing = false)
      continue
    break

func swiftSig(w: string, at: int): string =
  ## a function's parameters and what it gives back: `(x: Int) -> Int` (up to its body)
  let p = w.find('(', at)
  if p < 0: return ""
  var e = w.find('{', p)
  if e < 0: e = w.len
  w[p ..< e].strip

func swiftSymbols*(lines: seq[string]): seq[Symbol] =
  ## the types (with what is in them), the functions, the type aliases, the top-level constants and variables —
  ## not what is inside a function's body
  var nest = 0
  var triple = false
  var stack: seq[bool]                 # the blocks open: a type's body (its members listed) or code
  var pendingType = false              # a type's declaration whose `{` is on a line below
  for ln, s in lines:
    let code = swiftCode(s, nest, triple)
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    var depth = 0
    var inCode = false
    for isType in stack:
      if isType: inc depth
      else: inCode = true
    let w = swiftStrip(t)
    let first = swiftWord(w)
    var isTypeDecl = false
    template put(nm, kd, dt: string) =
      if not inCode:
        result.add Symbol(name: nm, kind: kd, detail: dt, line: ln, col: max(0, s.find(nm, col)), depth: depth)
    case first
    of "func":
      var a = 4
      while a < w.len and w[a] == ' ': inc a
      var e = swiftIdentEnd(w, a)
      if e == a:
        # an operator: func == (a: T, b: T) -> Bool
        while e < w.len and w[e] notin {' ', '(', '<'}: inc e
      if e > a: put(w[a ..< e], (if depth > 0: "method" else: "function"), swiftSig(w, e))
    of "init", "subscript", "deinit":
      put(first, (if depth > 0: "method" else: "function"), swiftSig(w, first.len))
    of "let", "var":
      let a = first.len + 1
      let e = swiftIdentEnd(w, a)
      if e > a:
        put(w[a ..< e], (if depth > 0: "property" elif first == "let": "constant" else: "variable"), first)
    of "typealias":
      let a = first.len + 1
      let e = swiftIdentEnd(w, a)
      if e > a: put(w[a ..< e], "type", "typealias")
    else:
      if first in SwiftTypeWords and w.len > first.len and w[first.len] == ' ':
        isTypeDecl = true
        var a = first.len + 1
        while a < w.len and w[a] == ' ': inc a
        var e = swiftIdentEnd(w, a)
        while e < w.len and w[e] == '.':     # extension Array.Index
          e = swiftIdentEnd(w, e + 1)
        if e > a:
          let kind = case first
                     of "struct": "struct"
                     of "enum": "enum"
                     of "protocol": "interface"
                     else: "class"
          put(w[a ..< e], kind, first)
    # the blocks: a type's `{` opens its body (perhaps on a line below its declaration), any other `{` code
    var typeOpen = isTypeDecl or pendingType
    var opened = false
    for c in code:
      if c == '{':
        stack.add typeOpen
        typeOpen = false
        opened = true
      elif c == '}':
        if stack.len > 0: discard stack.pop()
    pendingType = (isTypeDecl or pendingType) and not opened and not inCode

# ── the tools ──

proc swiftHave(cmd: string): bool =
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let swiftServerSet = setting("server", "").strip
var swiftServer: seq[string]
if swiftServerSet == "off": discard
elif swiftServerSet.len > 0:
  if swiftHave(swiftServerSet): swiftServer = swiftServerSet.splitWhitespace()
  else: echo "swift: the server " & swiftServerSet & " is not installed (plugins.swift.server)"
elif findExe("sourcekit-lsp").len > 0: swiftServer = @["sourcekit-lsp"]
if swiftServer.len > 0:
  swiftServer[0] = expandTilde(swiftServer[0])
  languageServer("swift", swiftServer)
else:
  symbols("swift") do (b: Buf) -> seq[Symbol]:
    swiftSymbols(b.lines)

let swiftFmtSet = setting("formatter", "").strip
if swiftFmtSet == "off": discard
elif swiftFmtSet.len > 0:
  if swiftHave(swiftFmtSet): formatter("swift", swiftFmtSet)
  else: echo "swift: the formatter " & swiftFmtSet & " is not installed (plugins.swift.formatter)"
elif findExe("swift-format").len > 0:
  # (no file named: it reads stdin; --assume-filename is where it looks for the project's .swift-format)
  formatter("swift", "swift-format format --assume-filename \"$file\"")
