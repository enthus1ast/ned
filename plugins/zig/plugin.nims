## zig — Zig: colours, comments, indentation, F5, snippets, an outline; zls and zig fmt
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Zig's `.zig` and `.zon` files: their colours (ned's
## generic lexer with Zig's words: its keywords, its types — i32, usize, comptime_int … —, Capitalised names as
## types, @builtins in their own colour, 'c' characters), `//` comments (`///` and `//!` the documentation),
## indentation after `{` `(` `[`, four spaces as `zig fmt` writes, brackets and quotes that close themselves,
## snippets (fn, pub, struct, test, for, while, switch, defer) and F5: `zig build run` in a project (a build.zig
## above the file), else `zig run` on the file — `zig test` for a file of tests. Build (Alt+B) is `zig build`, and
## the check on save `zig ast-check`.
##
## Without a language server, the outline lists the file's functions, its structs, enums, unions and error sets
## (with the functions inside them), its constants and its tests, from a simple scan.
##
## The tools, when they are on PATH: zig (Termux `pkg install zig`; https://ziglang.org/download/) — `zig fmt
## --stdin` formats (Format document, and on save with editor.formatOnSave); zls, Zig's language server
## (https://github.com/zigtools/zls): completion, hover, go to definition, problems.
##
## Settings (the Plugins dock › zig › its settings; Plugins: reload after a change):
## - plugins.zig.server — the language server's command, when it is not `zls` ("off": none)
## - plugins.zig.formatter — the formatter's command (the text on its stdin), when it is not `zig fmt --stdin`
import nedplugin
import std/strutils

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for zls (when it is installed), \"off\" for none. " &
           "Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for zig fmt --stdin " &
           "(when zig is installed), \"off\" for none. Plugins: reload after a change")

language("zig", LangSpec(
  name: "Zig",
  extensions: @["zig", "zon"],
  lineComment: "//",
  docComment: "///",
  quotes: "\"",
  charLiterals: true,
  capitalTypes: true,
  decorators: true,
  keywords: @["addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break",
              "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error",
              "export", "extern", "fn", "for", "if", "inline", "linksection", "noalias", "noinline", "nosuspend",
              "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test",
              "threadlocal", "try", "union", "unreachable", "usingnamespace", "var", "volatile", "while"],
  types: @["i8", "u8", "i16", "u16", "i32", "u32", "i64", "u64", "i128", "u128", "isize", "usize", "f16", "f32",
           "f64", "f80", "f128", "bool", "void", "noreturn", "type", "anyerror", "anyopaque", "comptime_int",
           "comptime_float", "c_char", "c_short", "c_ushort", "c_int", "c_uint", "c_long", "c_ulong",
           "c_longlong", "c_ulonglong", "c_longdouble"],
  constants: @["true", "false", "null", "undefined"],
  functionWords: @["fn"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 4,
  run: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/build.zig\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
       "if [ -f \"$d/build.zig\" ]; then cd \"$d\" && exec zig build run; " &
       "elif grep -q \"^test \" \"$file\"; then exec zig test \"$file\"; else exec zig run \"$file\"; fi'",
  build: "zig build",
  check: "zig ast-check \"$file\"",
  pairs: "()[]{}\"\""))

snippet("zig", "fn", "fn ${1:name}(${2}) ${3:void} {\n\t$0\n}", "a function")
snippet("zig", "pub", "pub fn ${1:name}(${2}) ${3:void} {\n\t$0\n}", "a public function")
snippet("zig", "struct", "const ${1:Name} = struct {\n\t${2:field}: ${3:u32},\n$0\n};", "a struct")
snippet("zig", "test", "test \"${1:what}\" {\n\ttry std.testing.expect(${2:true});$0\n}", "a test")
snippet("zig", "for", "for (${1:items}) |${2:item}| {\n\t$0\n}", "a for loop")
snippet("zig", "while", "while (${1:cond}) : (${2:i += 1}) {\n\t$0\n}", "a while loop")
snippet("zig", "switch", "switch (${1:value}) {\n\t${2:.a} => ${3:{}},\n\telse => $0,\n}", "a switch")
snippet("zig", "defer", "defer ${1:allocator.free(buf)};$0", "a defer")
snippet("zig", "main", "const std = @import(\"std\");\n\npub fn main() !void {\n\t$0\n}", "a program")

# ── the outline, when there is no language server ──

func zigCode(s: string): string =
  ## the line with its comments and strings made spaces (the columns kept)
  result = s
  var i = 0
  while i < s.len:
    if s.continuesWith("//", i):
      for k in i ..< s.len: result[k] = ' '
      break
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
  ## where the name (letters, digits and `_`) that starts at `i` ends
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] == '_'): inc result

func zigSymbols*(lines: seq[string]): seq[Symbol] =
  ## the functions, the containers (struct, enum, union, error) with what is in them, the constants, the tests
  var level = 0
  var containerAt: seq[int]             # the brace levels that are a container's body
  for ln, s in lines:
    let code = zigCode(s)
    let t = code.strip
    let col = code.len - code.strip(trailing = false).len
    let depth = containerAt.len
    var w = t
    var pub = false
    for pre in ["pub ", "export ", "extern ", "inline ", "noinline "]:
      if w.startsWith(pre):
        if pre == "pub ": pub = true
        w = w[pre.len .. ^1].strip
    if (level == 0 or (containerAt.len > 0 and level == containerAt[^1])) and t.len > 0:
      if w.startsWith("fn "):
        let a = w.find("fn ") + 3
        let e = identEnd(w, a)
        if e > a:
          let p = w.find('(', e)
          let close = w.rfind(')')
          let sig = if p >= 0 and close > p: w[p .. close] else: "(…)"
          result.add Symbol(name: w[a ..< e], kind: (if depth > 0: "method" else: "function"),
                            detail: (if pub: "pub " else: "") & sig, line: ln, col: s.find(w[a ..< e], col),
                            depth: depth)
      elif w.startsWith("const ") or w.startsWith("var "):
        let a = w.find(' ') + 1
        let e = identEnd(w, a)
        if e > a:
          let rest = w[e .. ^1]
          var kind = "constant"
          var detail = if w.startsWith("var "): "var" else: "const"
          for k in ["struct", "enum", "union", "error", "opaque"]:
            if ("= " & k) in rest or ("=" & k) in rest or ("packed " & k) in rest or ("extern " & k) in rest:
              kind = (if k == "enum": "enum" elif k == "error": "type" else: "struct")
              detail = k
          if "@import(" in rest:
            kind = "module"
            detail = "@import"
          result.add Symbol(name: w[a ..< e], kind: kind, detail: (if pub: "pub " else: "") & detail, line: ln,
                            col: s.find(w[a ..< e], col), depth: depth)
      elif t.startsWith("test") and depth == 0:
        let q = s.find('"')
        let q2 = if q >= 0: s.find('"', q + 1) else: -1
        let name = if q >= 0 and q2 > q: s[q + 1 ..< q2] else: "test"
        result.add Symbol(name: name, kind: "function", detail: "test", line: ln, col: col)
    for i, c in code:
      if c == '{':
        inc level
        # (a container's body: `struct {`, `enum(u8) {`, `union(enum) {`, `error {`)
        let before = code[0 ..< i].strip
        if before.endsWith("struct") or before.endsWith("union") or before.endsWith("opaque") or
           before.endsWith("error") or before.endsWith("enum") or before.endsWith(")") and
           (before.contains("enum(") or before.contains("union(")):
          containerAt.add level
      elif c == '}':
        if containerAt.len > 0 and containerAt[^1] == level: discard containerAt.pop()
        level = max(0, level - 1)

# ── the tools ──

proc zigHave(cmd: string): bool =
  ## whether the first word of a configured command (with ~ expanded) is a program that can be found on PATH
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let zigServerSet = setting("server", "").strip
var zigServer: seq[string]
if zigServerSet == "off": discard
elif zigServerSet.len > 0:
  if zigHave(zigServerSet): zigServer = zigServerSet.splitWhitespace()
  else: echo "zig: the server " & zigServerSet & " is not installed (plugins.zig.server)"
elif findExe("zls").len > 0: zigServer = @["zls"]
if zigServer.len > 0:
  zigServer[0] = expandTilde(zigServer[0])
  languageServer("zig", zigServer)
else:
  symbols("zig") do (b: Buf) -> seq[Symbol]:
    zigSymbols(b.lines)

let zigFmtSet = setting("formatter", "").strip
if zigFmtSet == "off": discard
elif zigFmtSet.len > 0:
  if zigHave(zigFmtSet): formatter("zig", zigFmtSet)
  else: echo "zig: the formatter " & zigFmtSet & " is not installed (plugins.zig.formatter)"
elif findExe("zig").len > 0: formatter("zig", "zig fmt --stdin")
