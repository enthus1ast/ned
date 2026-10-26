## crystal — Crystal: colours, comments, indentation, F5, snippets, an outline; crystalline and crystal tool format
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Crystal's `.cr` files (and shard.yml's language is
## YAML, as it is): their colours (ned's generic lexer with Crystal's words: Capitalised names as types, @ivars and
## @[Annotations], :symbols, 'c' characters), `#` comments, indentation after def, class, module, struct, if, while,
## case, do … and back at `end` (else, elsif, when, rescue, ensure line up with their block), two spaces as
## `crystal tool format` writes, snippets (def, class, struct, module, spec, case, each, property) and F5: `crystal
## spec` for a file of the spec folder, else `crystal run` on the file — in its project (the folder with shard.yml,
## above the file). Build (Alt+B) is `shards build` in a project.
##
## Without a language server, the outline lists the file's modules, classes, structs, enums, libs and annotations
## with their methods (def, macro), constants, aliases and the top-level defs, from a simple scan.
##
## The tools, when they are on PATH: crystal (Termux `pkg install crystal`; https://crystal-lang.org/install/) —
## `crystal tool format -` formats (Format document, and on save with editor.formatOnSave); crystalline, Crystal's
## language server (https://github.com/elbywan/crystalline): completion, hover, go to definition, problems.
##
## Settings (the Plugins dock › crystal › its settings; Plugins: reload after a change):
## - plugins.crystal.server — the language server's command, when it is not `crystalline` ("off": none)
## - plugins.crystal.formatter — the formatter's command (the text on its stdin), when it is not crystal tool format
import nedplugin
import std/strutils

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for crystalline (when it is installed), \"off\" " &
           "for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for crystal tool " &
           "format - (when crystal is installed), \"off\" for none. Plugins: reload after a change")

language("crystal", LangSpec(
  name: "Crystal",
  extensions: @["cr"],
  lineComment: "#",
  quotes: "\"",
  charLiterals: true,
  capitalTypes: true,
  decorators: true,
  nameChars: "?!",
  keywords: @["abstract", "alias", "annotation", "as", "asm", "begin", "break", "case", "class", "def", "do",
              "else", "elsif", "end", "ensure", "enum", "extend", "for", "fun", "if", "in", "include", "instance_sizeof",
              "is_a?", "lib", "macro", "module", "next", "of", "offsetof", "out", "pointerof", "private", "protected",
              "require", "rescue", "responds_to?", "return", "select", "sizeof", "struct", "super", "then", "type",
              "typeof", "union", "uninitialized", "unless", "until", "verbatim", "when", "while", "with", "yield",
              "property", "getter", "setter", "record"],
  types: @["Int8", "Int16", "Int32", "Int64", "Int128", "UInt8", "UInt16", "UInt32", "UInt64", "Float32",
           "Float64", "String", "Char", "Bool", "Nil", "Symbol", "Array", "Hash", "Tuple", "NamedTuple", "Proc",
           "Pointer", "Slice", "Set", "Range", "Regex", "Exception", "Object", "Reference", "Value"],
  constants: @["true", "false", "nil", "self"],
  builtins: @["puts", "print", "p", "pp", "raise", "spawn", "loop", "sleep", "gets"],
  functionWords: @["def", "macro", "fun"],
  classWords: @["class", "struct", "module", "enum", "lib"],
  indentAfter: @["def", "class", "module", "struct", "enum", "lib", "macro", "if", "unless", "while", "until",
                 "case", "when", "else", "elsif", "begin", "rescue", "ensure", "do", "annotation", "union", "{",
                 "(", "["],
  dedentWords: @["end", "else", "elsif", "when", "in", "rescue", "ensure"],
  dedent: ")]}",
  indentSize: 2,
  run: "sh -c 'f=\"$file\"; d=\"$dir\"; while [ ! -f \"$d/shard.yml\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); " &
       "done; [ -f \"$d/shard.yml\" ] && cd \"$d\"; case \"$f\" in */spec/*|*_spec.cr) exec crystal spec \"$f\" ;; " &
       "esac; exec crystal run \"$f\"'",
  build: "shards build",
  pairs: "()[]{}\"\""))

snippet("crystal", "def", "def ${1:name}(${2:x})\n\t$0\nend", "a method")
snippet("crystal", "class", "class ${1:Name}\n\tdef initialize(${2:@value : Int32})\n\tend\n$0\nend", "a class")
snippet("crystal", "struct", "struct ${1:Name}\n\tgetter ${2:x} : ${3:Int32}\n\n\tdef initialize(@$2)\n\tend$0\nend", "a struct")
snippet("crystal", "module", "module ${1:Name}\n\t$0\nend", "a module")
snippet("crystal", "spec", "describe ${1:Thing} do\n\tit \"${2:works}\" do\n\t\t${3:true}.should eq(${4:true})$0\n\tend\nend", "a spec")
snippet("crystal", "case", "case ${1:x}\nwhen ${2:1}\n\t$0\nelse\nend", "a case")
snippet("crystal", "each", "${1:items}.each do |${2:item}|\n\t$0\nend", "an each block")
snippet("crystal", "property", "property ${1:name} : ${2:String}$0", "a property (getter and setter)")

# ── the outline, when there is no language server ──

func crCode(s: string, heredoc: var string): string =
  ## the line with its comments and strings made spaces (the columns kept) — `heredoc`: the word that ends a
  ## <<-WORD string that goes on below ("" none)
  result = s
  if heredoc.len > 0:
    if s.strip == heredoc: heredoc = ""
    return spaces(s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '#' and not (i + 1 < s.len and s[i + 1] == '{'):
      for k in i ..< s.len: result[k] = ' '
      break
    if c == '"' or c == '`':
      result[i] = ' '
      inc i
      while i < s.len and s[i] != c:
        if s[i] == '\\' and i + 1 < s.len:
          result[i] = ' '
          inc i
        result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
    elif c == '\'' and i + 2 < s.len:
      var k = i + 1
      if s[k] == '\\': k += 2
      else: inc k
      while k < s.len and s[k] != '\'' and k < i + 8: inc k
      if k < s.len and s[k] == '\'':
        for j in i .. k: result[j] = ' '
        i = k
    elif s.continuesWith("<<-", i) and i + 3 < s.len and s[i + 3] in {'A'..'Z', '_'}:
      var k = i + 3
      while k < s.len and s[k] in {'A'..'Z', '0'..'9', '_'}: inc k
      heredoc = s[i + 3 ..< k]
      for j in i ..< k: result[j] = ' '
      i = k
      continue
    inc i

func crName(s: string, i: int): int =
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] in {'_', '?', '!', '=', ':'} or
                            ord(s[result]) >= 128):
    # (a::b is a path: Foo::Bar; a method may end in ? ! or =)
    if s[result] == ':' and not (result + 1 < s.len and s[result + 1] == ':' or result > 0 and s[result - 1] == ':'):
      break
    if s[result] == '=' and not (result + 1 < s.len and s[result + 1] == '('): break
    inc result

const CrContainers = ["module", "class", "struct", "enum", "lib", "annotation", "union"]
const CrOpeners = ["def", "macro", "if", "unless", "while", "until", "case", "begin", "select", "fun"]

func crSymbols*(lines: seq[string]): seq[Symbol] =
  ## the modules, classes, structs, enums, libs (with what is in them), the methods, macros, constants, aliases
  var heredoc = ""
  var stack: seq[bool]                  # the blocks open: a container's (true) or code's (false)
  for ln, s in lines:
    let code = crCode(s, heredoc)
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    var w = t
    var abstractDef = false
    for pre in ["private ", "protected ", "abstract "]:
      if w.startsWith(pre):
        if pre == "abstract " and w.startsWith("abstract def "): abstractDef = true
        w = w[pre.len .. ^1]
    let first = w.split({' ', '(', ';'})[0]
    var depth = 0
    var inCode = false
    for isC in stack:
      if isC: inc depth
      else: inCode = true
    let oneLine = w.endsWith(" end") or w.endsWith(";end") or w.endsWith("; end")
    if not inCode:
      if first in CrContainers:
        let a = first.len + 1
        let e = crName(w, a)
        if e > a:
          let name = w[a ..< e]
          let kind = case first
                     of "module": "module"
                     of "enum": "enum"
                     of "struct", "union": "struct"
                     else: "class"
          let lt = w.find(" < ")
          result.add Symbol(name: name, kind: kind, detail: first & (if lt > 0: " < " & w[lt + 3 .. ^1].strip else: ""),
                            line: ln, col: max(0, s.find(name, col)), depth: depth)
      elif first in ["def", "macro", "fun"]:
        var a = first.len + 1
        if w.continuesWith("self.", a): a += 5
        let e = crName(w, a)
        if e > a:
          let name = w[a ..< e]
          let p = w.find('(', e - 1)
          let close = w.rfind(')')
          var detail = (if first == "def": "" else: first & " ") & (if p >= 0 and close > p: w[p .. close] else: "")
          let colon = w.find(" : ", max(e, close))
          if colon > 0: detail &= " : " & w[colon + 3 .. ^1].split(' ')[0]
          result.add Symbol(name: name, kind: (if depth > 0: "method" else: "function"), detail: detail.strip,
                            line: ln, col: max(0, s.find(name, col)), depth: depth)
      elif first == "alias":
        let e = crName(w, 6)
        if e > 6: result.add Symbol(name: w[6 ..< e], kind: "type", detail: "alias", line: ln,
                                    col: max(0, s.find(w[6 ..< e], col)), depth: depth)
      elif w.len > 0 and w[0] in {'A'..'Z'} and " =" in w:
        # CONSTANT = … (its value may be a string, made spaces here)
        let e = crName(w, 0)
        let rest = w[e .. ^1].strip
        if e > 0 and rest.startsWith("=") and not rest.startsWith("==") and
           w[0 ..< e].allCharsInSet({'A'..'Z', '0'..'9', '_'}):
          result.add Symbol(name: w[0 ..< e], kind: "constant", detail: "", line: ln, col: col, depth: depth)
    # the blocks: a container's word or a def's opens one (not an abstract def, not one ended on its line), so does
    # an if, a while … at the line's start or after =, and a do; end closes the last
    var opens = 0
    var container = false
    if first in CrContainers or first in CrOpeners:
      if not abstractDef and not oneLine:
        opens = 1
        container = first in CrContainers
    elif (" = if " in w or " = case " in w or " = begin" in w or " = unless " in w or " = while " in w) and
         not oneLine:
      opens = 1
    if (w.endsWith(" do") or " do |" in w) and opens == 0: opens = 1
    # (a fun in a lib has no body)
    if first == "fun" and stack.len > 0 and stack[^1] and not container: opens = 0
    var closes = 0
    for x in w.splitWhitespace():
      if x.strip(chars = {';', ')'}) == "end": inc closes
    if oneLine: closes = max(0, closes - 1)
    for k in 0 ..< opens: stack.add container
    for k in 0 ..< closes:
      if stack.len > 0: discard stack.pop()

# ── the tools ──

proc crHave(cmd: string): bool =
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let crServerSet = setting("server", "").strip
var crServer: seq[string]
if crServerSet == "off": discard
elif crServerSet.len > 0:
  if crHave(crServerSet): crServer = crServerSet.splitWhitespace()
  else: echo "crystal: the server " & crServerSet & " is not installed (plugins.crystal.server)"
elif findExe("crystalline").len > 0: crServer = @["crystalline"]
if crServer.len > 0:
  crServer[0] = expandTilde(crServer[0])
  languageServer("crystal", crServer)
else:
  symbols("crystal") do (b: Buf) -> seq[Symbol]:
    crSymbols(b.lines)

let crFmtSet = setting("formatter", "").strip
if crFmtSet == "off": discard
elif crFmtSet.len > 0:
  if crHave(crFmtSet): formatter("crystal", crFmtSet)
  else: echo "crystal: the formatter " & crFmtSet & " is not installed (plugins.crystal.formatter)"
elif findExe("crystal").len > 0: formatter("crystal", "crystal tool format -")
