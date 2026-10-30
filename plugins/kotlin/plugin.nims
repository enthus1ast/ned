## kotlin — Kotlin: F5 with Gradle, snippets, an outline; kotlin-lsp or kotlin-language-server, ktfmt or ktlint
##
## Turn it on in the Plugins dock (AVAILABLE). ned colours Kotlin's `.kt` files and its scripts, `.kts`
## (build.gradle.kts among them) by itself; this plugin adds to that: `/** */` as the documentation, Kotlin's
## common functions (println, listOf, let, apply …) as built-ins, indentation after `->` too, snippets (fun, main,
## class, data, when, for, test) and F5 in a Gradle project — a gradlew, or a build.gradle(.kts), above the file:
## `./gradlew run` (or `gradle run`); else `kotlinc -script` for a `.kts` file and, for a `.kt` file, kotlinc into a
## jar of ned's own, then `java -jar` on it. Build (Alt+B) is `gradle build` (or ./gradlew) the same way, else
## kotlinc on the file.
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the file's classes, interfaces, objects and
## enums (their functions and properties under them), its functions, top-level properties and type aliases, from a
## simple scan.
##
## The tools, when they are on PATH — Kotlin's compiler, kotlinc: Termux `pkg install kotlin`; elsewhere
## https://kotlinlang.org/docs/command-line.html (SDKMAN!: `sdk install kotlin`); Gradle for projects
## - a language server (completion, hover, go to definition, problems), the first installed: kotlin-lsp,
##   JetBrains' own (https://github.com/Kotlin/kotlin-lsp/releases), or kotlin-language-server
##   (https://github.com/fwcd/kotlin-language-server/releases)
## - a formatter, the first installed: ktfmt (`ktfmt --kotlinlang-style -`, https://github.com/facebook/ktfmt), or
##   ktlint (`ktlint --stdin -F`, https://pinterest.github.io/ktlint/) — Format document, and on save with
##   editor.formatOnSave
##
## Settings (the Plugins dock › kotlin › its settings; Plugins: reload after a change):
## - plugins.kotlin.server — the language server's command, when it is neither of those ("off": none)
## - plugins.kotlin.formatter — the formatter's command (the text on its stdin), when it is neither of those
##   ("off": none)
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs Gradle or kotlinc for F5 and Build, and a language server and ktfmt or ktlint when installed")

settingDef("server", "", "The language server's command: empty for kotlin-lsp (or kotlin-language-server) when " &
           "it is installed, \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for ktfmt (or ktlint) " &
           "when it is installed, \"off\" for none. Plugins: reload after a change")

language("kotlin", LangSpec(
  name: "Kotlin",
  extensions: @["kt", "kts"],
  lineComment: "//",
  blockComment: @["/*", "*/"],
  docBlockComment: @["/**", "*/"],
  nestedComments: true,
  quotes: "\"'",
  charLiterals: true,
  tripleQuotes: true,
  capitalTypes: true,
  decorators: true,
  keywords: @["as", "break", "class", "continue", "do", "else", "for", "fun", "if", "in", "interface", "is",
              "object", "package", "return", "super", "this", "throw", "try", "typealias", "typeof", "val", "var",
              "when", "while", "by", "catch", "constructor", "finally", "get", "import", "init", "set", "where",
              "abstract", "actual", "annotation", "companion", "const", "crossinline", "data", "enum", "expect",
              "external", "final", "infix", "inline", "inner", "internal", "lateinit", "noinline", "open",
              "operator", "out", "override", "private", "protected", "public", "reified", "sealed", "suspend",
              "tailrec", "vararg", "value"],
  constants: @["true", "false", "null"],
  builtins: @["println", "print", "readln", "readLine", "listOf", "mutableListOf", "arrayListOf", "mapOf",
              "mutableMapOf", "hashMapOf", "setOf", "mutableSetOf", "arrayOf", "intArrayOf", "emptyList",
              "emptyMap", "emptySet", "require", "requireNotNull", "check", "checkNotNull", "error", "TODO",
              "repeat", "run", "let", "apply", "also", "with", "takeIf", "takeUnless", "lazy", "buildList",
              "buildString", "buildMap", "maxOf", "minOf", "to"],
  functionWords: @["fun"],
  classWords: @["class", "interface", "object"],
  indentAfter: @["{", "(", "[", "->"],
  dedent: "})]",
  indentSize: 4,
  # (a Gradle project above the file: its wrapper, else gradle; else the file alone)
  run: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/gradlew\" ] && [ ! -f \"$d/build.gradle.kts\" ] && " &
       "[ ! -f \"$d/build.gradle\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
       "if [ -f \"$d/gradlew\" ]; then cd \"$d\" && exec sh ./gradlew run; " &
       "elif [ -f \"$d/build.gradle.kts\" ] || [ -f \"$d/build.gradle\" ]; then cd \"$d\" && exec gradle run; " &
       "else case \"$file\" in *.kts) exec kotlinc -script \"$file\" ;; " &
       "*) kotlinc \"$file\" -include-runtime -d \"$tmp/$name.jar\" && exec java -jar \"$tmp/$name.jar\" ;; esac; fi'",
  build: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/gradlew\" ] && [ ! -f \"$d/build.gradle.kts\" ] && " &
         "[ ! -f \"$d/build.gradle\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
         "if [ -f \"$d/gradlew\" ]; then cd \"$d\" && exec sh ./gradlew build; " &
         "elif [ -f \"$d/build.gradle.kts\" ] || [ -f \"$d/build.gradle\" ]; then cd \"$d\" && exec gradle build; " &
         "else exec kotlinc \"$file\" -include-runtime -d \"$name.jar\"; fi'",
  pairs: "()[]{}\"\""))

snippet("kotlin", "fun", "fun ${1:name}(${2}): ${3:Unit} {\n\t$0\n}", "a function")
snippet("kotlin", "main", "fun main() {\n\t${1:println(\"Hello\")}$0\n}", "a program")
snippet("kotlin", "class", "class ${1:Name}(${2:val x: Int}) {\n\t$0\n}", "a class")
snippet("kotlin", "data", "data class ${1:Name}(${2:val x: Int})$0", "a data class")
snippet("kotlin", "when", "when (${1:value}) {\n\t${2:1} -> ${3:TODO()}\n\telse -> $0\n}", "a when expression")
snippet("kotlin", "for", "for (${1:item} in ${2:items}) {\n\t$0\n}", "a for loop")
snippet("kotlin", "test", "@Test\nfun `${1:does something}`() {\n\tassertEquals(${2:expected}, ${3:actual})$0\n}",
        "a test (kotlin.test or JUnit)")

# ── the outline, when there is no language server ──

func kotlinCode(s: string, inBlock: var int, inRaw: var bool): string =
  ## the line with its comments and strings made spaces (the columns kept); a /* */ comment (nested) and a
  ## """raw string""" may go on to the next lines
  result = s
  var i = 0
  while i < s.len:
    if inRaw:
      if s.continuesWith("\"\"\"", i):
        for k in i .. i + 2: result[k] = ' '
        inRaw = false
        i += 3
        continue
      result[i] = ' '
      inc i
    elif inBlock > 0:
      if s.continuesWith("*/", i):
        dec inBlock
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
      elif s.continuesWith("/*", i):
        inc inBlock
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
      else:
        result[i] = ' '
        inc i
    elif s.continuesWith("//", i):
      for k in i ..< s.len: result[k] = ' '
      break
    elif s.continuesWith("/*", i):
      inc inBlock
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
    elif s.continuesWith("\"\"\"", i):
      for k in i .. i + 2: result[k] = ' '
      inRaw = true
      i += 3
    elif s[i] == '"' or s[i] == '\'':
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
    else: inc i

# whether c can be part of a Kotlin name
func kotlinIdent(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

const KotlinMods = ["public", "private", "protected", "internal", "open", "abstract", "final", "override", "sealed",
                    "data", "enum", "inline", "value", "inner", "annotation", "suspend", "operator", "infix",
                    "tailrec", "external", "const", "lateinit", "expect", "actual", "companion", "fun"]

func kotlinSymbols*(lines: seq[string]): seq[Symbol] =
  ## the classes, interfaces, objects and enums with what is in them, the functions, the properties, the aliases
  var inBlock = 0
  var inRaw = false
  var level = 0
  var bodies: seq[int]                  # the brace levels that are a class's (an object's …) body
  var pendingBody = false               # a class was named on this line: its { opens its body
  for ln, s in lines:
    let code = kotlinCode(s, inBlock, inRaw)
    let col = code.len - code.strip(trailing = false).len
    let depth = bodies.len
    let atTop = level == 0 or (bodies.len > 0 and level == bodies[^1])
    pendingBody = false
    if atTop and code.strip.len > 0:
      # the words before the name: modifiers, then the kind
      var i = col
      var words: seq[string]
      while i < code.len:
        while i < code.len and code[i] == ' ': inc i
        if i < code.len and code[i] == '@':          # (an annotation on the same line)
          inc i
          while i < code.len and (kotlinIdent(code[i]) or code[i] == '.'): inc i
          if i < code.len and code[i] == '(':
            let e = code.find(')', i)
            i = if e > 0: e + 1 else: code.len
          continue
        let a = i
        while i < code.len and kotlinIdent(code[i]): inc i
        if i == a: break
        let w = code[a ..< i]
        words.add w
        if w in ["class", "interface", "object", "fun", "val", "var", "typealias"]: break
        if w notin KotlinMods: break
      let kind = if words.len > 0: words[^1] else: ""
      let mods = if words.len > 1: words[0 ..< ^1] else: @[]
      if kind in ["class", "interface", "object", "fun", "val", "var", "typealias"]:
        while i < code.len and code[i] == ' ': inc i
        if kind == "fun" and i < code.len and code[i] == '<':   # fun <T> name
          let e = code.find('>', i)
          if e > 0: i = e + 1
          while i < code.len and code[i] == ' ': inc i
        var a = i
        while true:
          while i < code.len and (kotlinIdent(code[i]) or code[i] == '.' or code[i] == '`'): inc i
          if kind notin ["fun", "val", "var"] or i >= code.len or code[i] != '<': break
          var e = i                                            # (an extension of a generic type: List<T>.name)
          var nest = 0
          while e < code.len:
            if code[e] == '<': inc nest
            elif code[e] == '>':
              dec nest
              if nest == 0: break
            inc e
          if e + 1 < code.len and code[e + 1] == '.': i = e + 1
          else: break
        var name = code[a ..< i]
        if kind in ["fun", "val", "var"] and '.' in name:          # (an extension: Type.name)
          a += name.rfind('.') + 1
          name = name[name.rfind('.') + 1 .. ^1]
        if name.len == 0 and kind == "object" and "companion" in mods: name = "Companion"
        if name.len > 0:
          var sk = ""
          var detail = mods.join(" ")
          case kind
          of "class":
            sk = if "enum" in mods: "enum" elif "interface" in mods: "interface" else: "class"
            detail = (detail & " class").strip
          of "interface":
            sk = "interface"
            detail = (detail & " interface").strip
          of "object":
            sk = "class"
            detail = (detail & " object").strip
          of "fun":
            sk = if depth > 0: "method" else: "function"
            let p = code.find('(', i)
            let close = code.rfind(')')
            detail = (detail & " " & (if p >= 0 and close > p: s[p .. close] else: "(…)")).strip
          of "typealias":
            sk = "type"
            detail = "typealias"
          else:
            sk = if depth > 0: "field" elif kind == "val": "constant" else: "variable"
            detail = (detail & " " & kind).strip
          result.add Symbol(name: name, kind: sk, detail: detail, line: ln, col: a, depth: depth)
          if kind in ["class", "interface", "object"]: pendingBody = true
    for c in code:
      if c == '{':
        inc level
        if pendingBody:
          bodies.add level
          pendingBody = false
      elif c == '}':
        if bodies.len > 0 and bodies[^1] == level: discard bodies.pop()
        level = max(0, level - 1)

# ── the tools ──

proc kotlinHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let kotlinServerSet = setting("server", "").strip
var kotlinServer: seq[string]
if kotlinServerSet == "off": discard
elif kotlinServerSet.len > 0:
  if kotlinHave(kotlinServerSet): kotlinServer = kotlinServerSet.splitWhitespace()
  else: echo "kotlin: the server " & kotlinServerSet & " is not installed (plugins.kotlin.server)"
else:
  for cmd in ["kotlin-lsp --stdio", "kotlin-language-server"]:
    if kotlinHave(cmd):
      kotlinServer = cmd.splitWhitespace()
      break
if kotlinServer.len > 0:
  kotlinServer[0] = expandTilde(kotlinServer[0])
  languageServer("kotlin", kotlinServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("kotlin") do (b: Buf) -> seq[Symbol]:
    kotlinSymbols(b.lines)

let kotlinFmtSet = setting("formatter", "").strip
if kotlinFmtSet == "off": discard
elif kotlinFmtSet.len > 0:
  if kotlinHave(kotlinFmtSet): formatter("kotlin", kotlinFmtSet)
  else: echo "kotlin: the formatter " & kotlinFmtSet & " is not installed (plugins.kotlin.formatter)"
else:
  for cmd in ["ktfmt --kotlinlang-style -", "ktlint --stdin -F"]:
    if kotlinHave(cmd):
      formatter("kotlin", cmd)
      break
