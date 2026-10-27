## vlang — V: colours, comments, indentation, F5 (v run, v test), snippets, an outline; v-analyzer and v fmt
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned the V language's files — `.v`, `.vsh` scripts, `.vv`
## templates and `v.mod` —: their colours (ned's generic lexer with V's words: Capitalised names as types, its
## types — int, u8, string, rune …, true, false and none, @[attributes], 'strings', "strings" and `runes`, a string
## going on over several lines), `//` and `/* */` comments (one inside another too), indentation after `{` `(` `[`
## with tabs, as `v fmt` writes, brackets and quotes that close themselves, snippets (fn, main, struct, method,
## if, for, match, or, test, mod) and F5: `v test` for a `_test.v` file; in a module's folder (a v.mod beside the
## file) `v run .`; else `v run` on the file. Build (Alt+B) is `v .` or `v` on the file the same way, and the
## check on save `v -check` (the folder's module, or the file alone): an error is at its line.
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the file's module, its functions and methods
## (a method with its receiver: (p Point)), structs, unions, interfaces (their methods under them), enums, type
## aliases and sum types, and constants, from a simple scan.
##
## The tools, when they are on PATH — V itself: Termux `pkg install vlang`; elsewhere
## https://github.com/vlang/v (`make`, then `./v symlink`)
## - v-analyzer, V's language server (completion, hover, go to definition, problems): `v download -RD
##   https://raw.githubusercontent.com/vlang/v-analyzer/main/install.vsh` — else vls, the older one
## - `v fmt`, the formatter (Format document, and on save with editor.formatOnSave): it comes with V
##
## Settings (the Plugins dock › vlang › its settings; Plugins: reload after a change):
## - plugins.vlang.server — the language server's command, when it is neither of those ("off": none)
## - plugins.vlang.formatter — the formatter's command: its text on stdin, or $in and $out — when it is not
##   `v fmt $in > $out` ("off": none)
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs v for F5, Build, the check and formatting, and v-analyzer when it is installed")

settingDef("server", "", "The language server's command: empty for v-analyzer (or vls) when it is installed, " &
           "\"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command — the text on its stdin, or $in and $out: empty for v fmt " &
           "(when v is installed), \"off\" for none. Plugins: reload after a change")

language("v", LangSpec(
  name: "V",
  extensions: @["v", "vsh", "vv"],
  files: @["v.mod"],
  lineComment: "//",
  blockComment: @["/*", "*/"],
  nestedComments: true,
  quotes: "'\"`",
  multilineStrings: true,
  capitalTypes: true,
  decorators: true,
  keywords: @["as", "asm", "assert", "atomic", "break", "const", "continue", "defer", "else", "enum", "fn", "for",
              "go", "goto", "if", "implements", "import", "in", "interface", "is", "isreftype", "lock", "match",
              "module", "mut", "or", "pub", "return", "rlock", "select", "shared", "sizeof", "spawn", "static",
              "struct", "type", "typeof", "union", "unsafe", "volatile", "__global", "__offsetof"],
  types: @["bool", "string", "i8", "i16", "int", "i32", "i64", "isize", "u8", "byte", "u16", "u32", "u64", "usize",
           "rune", "f32", "f64", "voidptr", "byteptr", "charptr", "any", "map", "chan", "thread", "IError", "Error"],
  constants: @["true", "false", "none", "nil", "err", "it"],
  builtins: @["println", "print", "eprintln", "eprint", "exit", "panic", "dump", "error", "error_with_code",
              "isnil", "arrays", "maps", "os", "strings", "math", "time", "json", "rand"],
  functionWords: @["fn"],
  classWords: @["struct", "interface", "union", "enum"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 4,
  tabs: true,
  # (a test file: v test; a module's folder — a v.mod beside the file — v run .; else the file alone)
  run: "sh -c 'case \"$file\" in *_test.v) exec v test \"$file\" ;; " &
       "*.v) if [ -f \"$dir/v.mod\" ]; then cd \"$dir\" && exec v run .; fi ;; esac; exec v run \"$file\"'",
  build: "sh -c 'if [ -f \"$dir/v.mod\" ]; then cd \"$dir\" && exec v .; else exec v \"$file\"; fi'",
  # (the module's folder, when it has a v.mod — the file alone would not know its siblings; nothing without v; ned
  # puts the file and its folder after the script, quoted)
  check: "sh -c 'command -v v >/dev/null 2>&1 || exit 0; " &
         "if [ -f \"$2/v.mod\" ]; then cd \"$2\" && exec v -check .; else exec v -check \"$1\"; fi' " &
         "sh \"$file\" \"$dir\"",
  pairs: "()[]{}\"\"''``"))

snippet("v", "fn", "fn ${1:name}(${2}) ${3:int} {\n\t$0\n}", "a function")
snippet("v", "main", "module main\n\nfn main() {\n\t${1:println('hello')}$0\n}", "a program")
snippet("v", "struct", "struct ${1:Name} {\n\t${2:x} ${3:int}\nmut:\n\t$0\n}", "a struct")
snippet("v", "method", "fn (${1:p} ${2:Point}) ${3:name}(${4}) ${5:int} {\n\t$0\n}", "a method")
snippet("v", "if", "if ${1:condition} {\n\t$0\n}", "an if")
snippet("v", "for", "for ${1:i, x} in ${2:items} {\n\t$0\n}", "a for loop")
snippet("v", "match", "match ${1:x} {\n\t${2:1} { $3 }\n\telse { $0 }\n}", "a match")
snippet("v", "or", "or {\n\t${1:panic(err)}\n}$0", "an or block (a result's error)")
snippet("v", "test", "fn test_${1:name}() {\n\tassert ${2:1 + 1 == 2}$0\n}", "a test (in a _test.v file)")
snippet("v", "mod", "Module {\n\tname: '${1:name}'\n\tdescription: '${2}'\n\tversion: '${3:0.1.0}'\n\t" &
        "license: '${4:MIT}'\n\tdependencies: []\n}$0",
        "a v.mod file")

# ── the outline, when there is no language server ──

func vCode(s: string, inBlock: var int, inStr: var char): string =
  ## the line with its comments and strings made spaces (the columns kept); a /* */ comment (nested) and a string
  ## may go on to the next lines
  result = s
  var i = 0
  while i < s.len:
    if inStr != '\0':
      if s[i] == '\\' and i + 1 < s.len:
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      if s[i] == inStr: inStr = '\0'
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
    elif s[i] in {'"', '\'', '`'}:
      inStr = s[i]
      result[i] = ' '
      inc i
    else: inc i

func vIdentEnd(s: string, i: int): int =
  result = i
  while result < s.len and s[result] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: inc result

func vSymbols*(lines: seq[string]): seq[Symbol] =
  ## the module, the functions and methods, the structs, unions and interfaces (an interface's methods under it),
  ## the enums, the types, the constants
  var inBlock = 0
  var inStr = '\0'
  var level = 0
  var body = -1                         # an interface's body: its brace level (its lines are its methods)
  var constBlock = -1                   # a const ( … ) block: its paren level
  var paren = 0
  for ln, s in lines:
    let code = vCode(s, inBlock, inStr)
    let t = code.strip
    let col = code.len - code.strip(trailing = false).len
    template add(nm, kd, dt: string, cl, dp: int) =
      result.add Symbol(name: nm, kind: kd, detail: dt, line: ln, col: cl, depth: dp)
    if t.len > 0:
      var w = t
      var pre = ""
      for p in ["pub ", "mut ", "__global "]:
        if w.startsWith(p):
          pre = p.strip
          w = w[p.len .. ^1].strip
      # (an attribute before a declaration on its line: @[inline] fn …)
      while w.startsWith("@[") or w.startsWith("["):
        let e = w.find(']')
        if e < 0: break
        w = w[e + 1 .. ^1].strip
      let at = s.find(w, col)
      if body >= 0 and level == body:
        # an interface's method: name(args) result
        let e = vIdentEnd(w, 0)
        if e > 0 and e < w.len and w[e] == '(':
          add(w[0 ..< e], "method", w[e .. ^1].strip, at, 1)
      elif constBlock >= 0 and paren == constBlock and level == 0:
        let e = vIdentEnd(w, 0)
        if e > 0 and '=' in w[e .. ^1]: add(w[0 ..< e], "constant", "const", at, 1)
      elif level == 0 and paren == 0:
        if w.startsWith("module "):
          let e = vIdentEnd(w, 7)
          if e > 7: add(w[7 ..< e], "module", "module", at + 7, 0)
        elif w.startsWith("fn "):
          var i = 3
          var recv = ""
          if i < w.len and w[i] == '(':                       # a method: fn (p Point) name(…)
            let close = w.find(')', i)
            if close > 0:
              recv = w[i .. close]
              i = close + 1
              while i < w.len and w[i] == ' ': inc i
          # (C.puts, JS.alert: a function of C or JavaScript)
          var e = vIdentEnd(w, i)
          if e < w.len and w[e] == '.': e = vIdentEnd(w, e + 1)
          if e > i:
            let p = w.find('(', e)
            var sig = if p >= 0: w[p .. ^1].strip(chars = {'{', ' '}) else: ""
            if recv.len > 0: sig = recv & " " & sig
            add(w[i ..< e], (if recv.len > 0: "method" else: "function"), (if pre.len > 0: pre & " " else: "") & sig,
                at + i, 0)
        elif w.startsWith("struct ") or w.startsWith("union ") or w.startsWith("interface ") or
             w.startsWith("enum "):
          let kw = w[0 ..< w.find(' ')]
          let a = kw.len + 1
          let e = vIdentEnd(w, a)
          if e > a:
            add(w[a ..< e], (case kw
                             of "enum": "enum"
                             of "interface": "interface"
                             else: "struct"), (if pre.len > 0: pre & " " else: "") & kw, at + a, 0)
            if kw == "interface" and '{' in w and '}' notin w: body = 1
        elif w.startsWith("type "):
          let e = vIdentEnd(w, 5)
          if e > 5:
            let eq = w.find('=', e)
            add(w[5 ..< e], "type", (if eq >= 0: w[eq + 1 .. ^1].strip else: ""), at + 5, 0)
        elif w.startsWith("const "):
          let rest = w[6 .. ^1].strip
          if rest.startsWith("("): constBlock = 1
          else:
            let e = vIdentEnd(rest, 0)
            if e > 0: add(rest[0 ..< e], "constant", "const", s.find(rest, col), 0)
    for c in code:
      case c
      of '{': inc level
      of '}':
        if body >= 0 and level == body: body = -1
        level = max(0, level - 1)
      of '(': inc paren
      of ')':
        if constBlock >= 0 and paren == constBlock: constBlock = -1
        paren = max(0, paren - 1)
      else: discard

# ── the tools ──

proc vHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let vServerSet = setting("server", "").strip
var vServer: seq[string]
if vServerSet == "off": discard
elif vServerSet.len > 0:
  if vHave(vServerSet): vServer = vServerSet.splitWhitespace()
  else: echo "vlang: the server " & vServerSet & " is not installed (plugins.vlang.server)"
else:
  for cmd in ["v-analyzer", "vls"]:
    if vHave(cmd):
      vServer = @[cmd]
      break
if vServer.len > 0:
  vServer[0] = expandTilde(vServer[0])
  languageServer("v", vServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("v") do (b: Buf) -> seq[Symbol]:
    vSymbols(b.lines)

let vFmtSet = setting("formatter", "").strip
if vFmtSet == "off": discard
elif vFmtSet.len > 0:
  if vHave(vFmtSet): formatter("v", vFmtSet)
  else: echo "vlang: the formatter " & vFmtSet & " is not installed (plugins.vlang.formatter)"
elif vHave("v"): formatter("v", "v fmt $in > $out")    # (v fmt reads a file, not its stdin: ned gives it one)
