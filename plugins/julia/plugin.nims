## julia — Julia: colours, comments, indentation, F5, snippets, an outline; a language server and a formatter when set
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Julia's `.jl` files: their colours (ned's generic
## lexer with Julia's words: Capitalised names as types, @macros, """strings""" over several lines, 'c'
## characters), `#` comments and `#= … =#` blocks (nested), indentation after function, if, for, while, begin,
## let, struct, module, do, try … and back at `end` (else, elseif, catch, finally line up with their block), four
## spaces, snippets (function, struct, for, if, module, test) and F5: `julia --project` on the file, in its
## project (the folder with Project.toml, above the file) — `julia --project test/runtests.jl` for a file of its
## test folder.
##
## The outline lists the file's functions (`function f(…)` and `f(x) = …`), structs, abstract types, macros,
## modules and constants, from a simple scan.
##
## Julia's language server and formatter are Julia packages that start slowly, so they are not run unless you say:
## - plugins.julia.server — e.g. `julia --startup-file=no --history-file=no -e "using LanguageServer; runserver()"`
##   (after `] add LanguageServer`)
## - plugins.julia.formatter — e.g. `julia -e "using JuliaFormatter; print(format_text(read(stdin, String)))"`
## Julia itself: Termux `pkg install julia` is not there (use proot-distro); elsewhere https://julialang.org
import nedplugin
import std/strutils

requiresNed(">= 6.25")

settingDef("server", "", "The language server's command (e.g. julia -e \"using LanguageServer; runserver()\"): " &
           "empty or \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin (JuliaFormatter's): empty " &
           "or \"off\" for none. Plugins: reload after a change")

language("julia", LangSpec(
  name: "Julia",
  extensions: @["jl"],
  lineComment: "#",
  blockComment: @["#=", "=#"],
  nestedComments: true,
  quotes: "\"",
  tripleQuotes: true,
  charLiterals: true,
  capitalTypes: true,
  decorators: true,
  nameChars: "!",
  keywords: @["abstract", "baremodule", "begin", "break", "catch", "const", "continue", "do", "else", "elseif",
              "end", "export", "finally", "for", "function", "global", "if", "import", "in", "isa", "let", "local",
              "macro", "module", "mutable", "primitive", "quote", "return", "struct", "try", "type", "using",
              "where", "while", "public"],
  types: @["Int", "Int8", "Int16", "Int32", "Int64", "Int128", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
           "Float16", "Float32", "Float64", "Bool", "Char", "String", "Symbol", "Any", "Nothing", "Vector",
           "Matrix", "Array", "Dict", "Tuple", "Union", "AbstractString", "Real", "Number", "Integer"],
  constants: @["true", "false", "nothing", "missing", "NaN", "Inf", "pi"],
  functionWords: @["function", "macro"],
  classWords: @["struct", "module"],
  indentAfter: @["function", "if", "elseif", "else", "for", "while", "begin", "let", "struct", "module", "do",
                 "try", "catch", "finally", "macro", "quote", "baremodule", "(", "[", "{"],
  dedentWords: @["end", "else", "elseif", "catch", "finally"],
  dedent: ")]}",
  indentSize: 4,
  run: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/Project.toml\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
       "if [ -f \"$d/Project.toml\" ]; then cd \"$d\"; case \"$file\" in \"$d\"/test/*) " &
       "exec julia --project test/runtests.jl ;; esac; exec julia --project \"$file\"; " &
       "else exec julia \"$file\"; fi'",
  pairs: "()[]{}\"\""))

snippet("julia", "function", "function ${1:name}(${2:x})\n\t$0\nend", "a function")
snippet("julia", "struct", "struct ${1:Name}\n\t${2:field}::${3:Int}\nend$0", "a struct")
snippet("julia", "for", "for ${1:i} in ${2:1:10}\n\t$0\nend", "a for loop")
snippet("julia", "if", "if ${1:cond}\n\t$0\nend", "an if")
snippet("julia", "module", "module ${1:Name}\n\n$0\n\nend", "a module")
snippet("julia", "test", "@testset \"${1:what}\" begin\n\t@test ${2:true}$0\nend", "a test set")

# ── the outline ──

func jlCode(s: string, inTriple: var bool, nest: var int): string =
  ## the line with its comments and strings made spaces (the columns kept)
  result = s
  var i = 0
  while i < s.len:
    if nest > 0:
      if s.continuesWith("=#", i):
        dec nest
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      if s.continuesWith("#=", i):
        inc nest
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      result[i] = ' '
      inc i
      continue
    if inTriple:
      if s.continuesWith("\"\"\"", i):
        inTriple = false
        for k in i ..< i + 3: result[k] = ' '
        i += 3
        continue
      result[i] = ' '
      inc i
      continue
    if s.continuesWith("#=", i):
      inc nest
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
      continue
    if s[i] == '#':
      for k in i ..< s.len: result[k] = ' '
      break
    if s.continuesWith("\"\"\"", i):
      inTriple = true
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

func nameEnd(s: string, i: int): int =
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] in {'_', '!', '.'} or ord(s[result]) >= 128):
    inc result

const JlOpeners = ["function", "macro", "struct", "mutable", "if", "for", "while", "begin", "let", "module",
                   "baremodule", "try", "quote"]

func jlSymbols*(lines: seq[string]): seq[Symbol] =
  ## the functions (and one-line ones), structs, abstract and primitive types, macros, modules and constants — of
  ## the top level and of modules (not inside functions)
  var triple = false
  var nest = 0
  var stack: seq[string]               # the blocks open: their first words
  for ln, s in lines:
    let code = jlCode(s, triple, nest)
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    var w = t
    for pre in ["export ", "Base.", "@inline ", "@noinline ", "public "]:
      if w.startsWith(pre): w = w[pre.len .. ^1]
    let first = w.split({' ', '(', '\t', ';'})[0]
    var depth = 0
    var inCode = false
    for x in stack:
      if x in ["module", "baremodule"]: inc depth
      else: inCode = true
    # (the parameters are not called name, kind …: a template would put them in place of the fields' names)
    template put(nm, kd, dt: string) =
      if not inCode:
        result.add Symbol(name: nm, kind: kd, detail: dt, line: ln, col: max(0, s.find(nm, col)), depth: depth)
    if first in ["module", "baremodule"]:
      let a = w.find(' ') + 1
      put(w[a ..< nameEnd(w, a)], "module", "module")
    elif first in ["function", "macro"]:
      let a = w.find(' ') + 1
      let e = nameEnd(w, a)
      let p = w.find('(', e)
      let close = w.rfind(')')
      put(w[a ..< e], "function", (if first == "macro": "macro " else: "") &
          (if p >= 0 and close > p: w[p .. close] else: ""))
    elif first == "struct" or w.startsWith("mutable struct "):
      let a = w.find("struct ") + 7
      put(w[a ..< nameEnd(w, a)], "struct", (if first == "mutable": "mutable struct" else: "struct"))
    elif w.startsWith("abstract type ") or w.startsWith("primitive type "):
      let a = w.find("type ") + 5
      put(w[a ..< nameEnd(w, a)], "type", w[0 ..< w.find(" type")] & " type")
    elif first == "const":
      put(w[6 ..< nameEnd(w, 6)], "constant", "const")
    elif w.len > 0 and (w[0].isAlphaAscii or w[0] == '_') and first notin JlOpeners and first != "end":
      # f(x) = … — a function in one line (not `x = …`, not `a == b`)
      let e = nameEnd(w, 0)
      if e < w.len and w[e] == '(':
        var dp = 0
        var k = e
        while k < w.len:
          if w[k] == '(': inc dp
          elif w[k] == ')':
            dec dp
            if dp == 0: break
          inc k
        var r = k + 1
        while r < w.len and w[r] == ' ': inc r
        if r < w.len and w[r] == '=' and (r + 1 >= w.len or w[r + 1] != '='):
          put(w[0 ..< e], "function", w[e .. min(k, w.high)])
    # the blocks: one opens at its word (or a `do` at the end of the line), `end` closes the last
    let oneLine = w.endsWith(" end") or w.endsWith(";end") or w.endsWith(") end")
    if (first in JlOpeners or w.endsWith(" do") or " do " in w and w.rfind(" do ") > w.rfind(" end")) and
       not oneLine and not (first in ["abstract", "primitive"]):
      stack.add first
    for k in 0 ..< w.count(" end") + (if first == "end": 1 else: 0) - (if oneLine: 1 else: 0):
      if stack.len > 0: discard stack.pop()

# ── the tools (only when set) ──

proc jlHave(cmd: string): bool =
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let jlServerSet = setting("server", "").strip
var jlServed = false
if jlServerSet.len > 0 and jlServerSet != "off":
  if jlHave(jlServerSet):
    var cmd = jlServerSet.splitWhitespace()
    cmd[0] = expandTilde(cmd[0])
    languageServer("julia", cmd)
    jlServed = true
  else: echo "julia: the server " & jlServerSet & " is not installed (plugins.julia.server)"
if not jlServed:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("julia") do (b: Buf) -> seq[Symbol]:
    jlSymbols(b.lines)

let jlFmtSet = setting("formatter", "").strip
if jlFmtSet.len > 0 and jlFmtSet != "off":
  if jlHave(jlFmtSet): formatter("julia", jlFmtSet)
  else: echo "julia: the formatter " & jlFmtSet & " is not installed (plugins.julia.formatter)"
