## protobuf — Protocol Buffers: colours, comments, indentation, F5, snippets, an outline; protols and buf format
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Protocol Buffers' `.proto` files (proto2, proto3 and
## editions): their colours (ned's generic lexer with protobuf's words: message, enum, service, rpc, oneof …, its
## scalar types, Capitalised names as types), `//` and `/* … */` comments, indentation after `{` `(` `[`, two
## spaces as buf format writes, brackets and quotes that close themselves, snippets (syntax, message, enum, service,
## rpc, oneof) and F5: `buf generate` in a buf project with a buf.gen.yaml (above the file), else `buf build file` —
## or `protoc` when buf is not installed. Build (Alt+B) is `buf build`, and the check on save `buf lint file` (its
## problems on the lines).
##
## Without a language server, the outline lists the file's package, its messages (with their fields, oneofs and the
## messages and enums inside them), enums with their values, services with their rpcs, from a simple scan.
##
## The tools, when they are on PATH: buf (https://buf.build/docs/cli/installation) — `buf format` formats (Format
## document, and on save with editor.formatOnSave; its --stdin-filepath is in recent versions — an older buf can be
## given `buf format $in -o $out` in the setting); protols, a language server for protobuf (`cargo install protols`):
## completion, hover, go to definition, problems — or bufls, buf's older one. buf's own language server is
## `buf lsp serve` in recent versions: give it in the server setting.
##
## Settings (the Plugins dock › protobuf › its settings; Plugins: reload after a change):
## - plugins.protobuf.server — the language server's command, when it is neither protols nor bufls ("off": none)
## - plugins.protobuf.formatter — the formatter's command (the text on its stdin), when it is not buf format — e.g.
##   `clang-format --assume-filename="$file"`
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for protols (or bufls) when it is installed, " &
           "\"off\" for none — buf lsp serve for buf's own. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for buf format " &
           "(when buf is installed), \"off\" for none. Plugins: reload after a change")

language("protobuf", LangSpec(
  name: "Protobuf",
  extensions: @["proto"],
  lineComment: "//",
  blockComment: @["/*", "*/"],
  quotes: "\"'",
  capitalTypes: true,
  keywords: @["syntax", "edition", "package", "import", "public", "weak", "option", "message", "enum", "service",
              "rpc", "returns", "stream", "oneof", "map", "reserved", "extend", "extensions", "repeated", "optional",
              "required", "to", "max", "group"],
  types: @["double", "float", "int32", "int64", "uint32", "uint64", "sint32", "sint64", "fixed32", "fixed64",
           "sfixed32", "sfixed64", "bool", "string", "bytes"],
  constants: @["true", "false", "inf", "nan"],
  functionWords: @["rpc"],
  classWords: @["message", "enum", "service", "extend"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 2,
  run: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/buf.gen.yaml\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
       "if [ -f \"$d/buf.gen.yaml\" ]; then cd \"$d\" && exec buf generate; fi; " &
       "if command -v buf >/dev/null 2>&1; then exec buf build \"$file\"; fi; " &
       "exec protoc -I . -o /dev/null \"$name.proto\"'",
  # (buf finds the buf.yaml above the folder itself)
  build: "buf build",
  check: "buf lint \"$file\"",
  pairs: "()[]{}\"\""))

snippet("protobuf", "syntax", "syntax = \"proto3\";\n\npackage ${1:name.v1};\n\n$0", "a file's start")
snippet("protobuf", "message", "message ${1:Name} {\n\t${2:string} ${3:field} = ${4:1};$0\n}", "a message")
snippet("protobuf", "enum", "enum ${1:Name} {\n\t${2:NAME}_UNSPECIFIED = 0;$0\n}", "an enum")
snippet("protobuf", "service", "service ${1:Name} {\n\trpc ${2:Get}(${3:Request}) returns (${4:Response});$0\n}",
        "a service")
snippet("protobuf", "rpc", "rpc ${1:Get}(${2:Request}) returns (${3:Response});$0", "an rpc")
snippet("protobuf", "oneof", "oneof ${1:name} {\n\t${2:string} ${3:field} = ${4:1};$0\n}", "a oneof")

# ── the outline, when there is no language server ──

func protoCode(s: string, inComment: var bool): string =
  ## the line with its comments and strings made spaces (the columns kept)
  result = s
  var i = 0
  while i < s.len:
    if inComment:
      if s.continuesWith("*/", i):
        inComment = false
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
      inComment = true
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
      continue
    if s[i] in {'"', '\''}:
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

func protoIdentEnd(s: string, i: int): int =
  ## where the name that starts at i ends: letters, digits, _ and . (a qualified name)
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] in {'_', '.'}): inc result

func protoSymbols*(lines: seq[string]): seq[Symbol] =
  ## the package, the messages with their fields, oneofs and what is inside them, the enums with their values, the
  ## services with their rpcs, the extends
  var inComment = false
  var stack: seq[string]               # the blocks open: message, enum, service, oneof, extend — or "" (an option's
  #                                      value, an rpc's options)
  var pendingKind = ""                 # a block's declaration whose `{` is on a line below
  for ln, s in lines:
    let code = protoCode(s, inComment)
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    var depth = 0
    var inCode = false
    for k in stack:
      if k.len > 0: inc depth
      else: inCode = true
    let inside = if stack.len > 0: stack[^1] else: ""
    let words = t.split({' ', '\t', '{', ';', '('})
    let first = words[0]
    var opens = ""                     # the kind of block this line's `{` opens
    template put(nm, kd, dt: string) =
      ## adds an outline symbol (name, kind, detail) for the line being read at the current depth, unless it is inside a
      ## value or an option's braces
      if not inCode:
        result.add Symbol(name: nm, kind: kd, detail: dt, line: ln, col: max(0, s.find(nm, col)), depth: depth)
    if inCode: discard
    elif first == "package" and stack.len == 0:
      let a = 8
      let e = protoIdentEnd(t, a)
      if e > a: put(t[a ..< e], "module", "package")
    elif first in ["message", "enum", "service", "oneof", "extend"] and words.len > 1:
      var a = first.len
      while a < t.len and t[a] == ' ': inc a
      let e = protoIdentEnd(t, a)
      if e > a:
        let kind = case first
                   of "message": "struct"
                   of "enum": "enum"
                   of "service": "interface"
                   of "oneof": "struct"
                   else: "class"
        put(t[a ..< e], kind, first)
      opens = first
    elif first == "rpc" and inside == "service":
      let a = t.find(' ') + 1
      let e = protoIdentEnd(t, a)
      if e > a:
        var detail = t[e .. ^1]
        let b = detail.find('{')
        if b >= 0: detail = detail[0 ..< b]
        put(t[a ..< e], "method", detail.strip.strip(chars = {';'}).strip)
    elif inside == "enum" and first notin ["option", "reserved"] and '=' in t:
      let e = protoIdentEnd(t, 0)
      if e > 0: put(t[0 ..< e], "constant", "")
    elif inside in ["message", "oneof", "extend"] and
         first notin ["option", "reserved", "extensions", "syntax", "import", "package", "edition"] and '=' in t:
      # [repeated|optional|required] type name = number [options];  map<K, V> name = number;
      var r = t
      for lab in ["repeated ", "optional ", "required "]:
        if r.startsWith(lab): r = r[lab.len .. ^1].strip
      var typeEnd = 0
      if r.startsWith("map<"):
        typeEnd = r.find('>') + 1
      else:
        typeEnd = protoIdentEnd(r, 0)
      if typeEnd > 0:
        var a = typeEnd
        while a < r.len and r[a] == ' ': inc a
        let e = protoIdentEnd(r, a)
        if e > a: put(r[a ..< e], "field", r[0 ..< typeEnd])
    # the blocks
    var kind = if opens.len > 0: opens else: pendingKind
    var opened = false
    for c in code:
      if c == '{':
        stack.add kind
        kind = ""
        opened = true
      elif c == '}':
        if stack.len > 0: discard stack.pop()
    pendingKind = if opens.len > 0 and not opened: opens else: ""

# ── the tools ──

proc protoHave(cmd: string): bool =
  ## whether the first word of the command line is a program that can be found (a ~ is expanded) — so a server or
  ## formatter that is set is only used when it is installed
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let protoServerSet = setting("server", "").strip
var protoServer: seq[string]
if protoServerSet == "off": discard
elif protoServerSet.len > 0:
  if protoHave(protoServerSet): protoServer = protoServerSet.splitWhitespace()
  else: echo "protobuf: the server " & protoServerSet & " is not installed (plugins.protobuf.server)"
else:
  for cmd in ["protols", "bufls serve"]:
    if protoHave(cmd):
      protoServer = cmd.splitWhitespace()
      break
if protoServer.len > 0:
  protoServer[0] = expandTilde(protoServer[0])
  languageServer("protobuf", protoServer)
else:
  symbols("protobuf") do (b: Buf) -> seq[Symbol]:
    protoSymbols(b.lines)

let protoFmtSet = setting("formatter", "").strip
if protoFmtSet == "off": discard
elif protoFmtSet.len > 0:
  if protoHave(protoFmtSet): formatter("protobuf", protoFmtSet)
  else: echo "protobuf: the formatter " & protoFmtSet & " is not installed (plugins.protobuf.formatter)"
elif findExe("buf").len > 0:
  # (the text on its stdin, the formatted text on stdout; the path is the one its messages name)
  formatter("protobuf", "buf format --stdin-filepath \"$file\"")
