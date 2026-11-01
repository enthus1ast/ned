## odin — Odin: colours, comments, indentation, F5, snippets, an outline; ols and odinfmt when installed
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Odin's `.odin` files: their colours (ned's generic
## lexer with Odin's words: Capitalised names as types, ALL-CAPS ones as constants, 'r' runes, `raw strings` over
## several lines, @attributes — and the names of #directives and @(attributes) as built-ins), `//` and `/* */`
## comments (one inside another too), indentation after `{` with tabs (as odinfmt writes), brackets and quotes that
## close themselves, snippets (proc, struct, for, switch, if) and F5: `odin run .` builds and runs the file's
## folder, which is its package — or only the file (`odin run file.odin -file`) when more of the folder's files
## have a `main` of their own. Build (Alt+B) is `odin build` the same way, and `odin check` checks it.
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the file's procedures, types and constants
## from a simple scan, nested as they are in the file.
##
## The tools, when they are on PATH (Termux has no package for them: build them from source):
## - odin, for F5 — https://odin-lang.org/docs/install/
## - ols, Odin's language server: completion, hover, go to definition, problems and the outline — build it from
##   https://github.com/DanielGavin/ols (`./build.sh`), with the `builtin` folder next to the `ols` program
## - odinfmt, the formatter (Format document, and on save with editor.formatOnSave): it comes with ols
##   (`./odinfmt.sh`); it reads the project's odinfmt.json
##
## Settings (the Plugins dock › odin › its settings; Plugins: reload after a change):
## - plugins.odin.server — the language server's command, when it is not `ols` ("off": none)
## - plugins.odin.formatter — the formatter's command (the text on its stdin), when it is not `odinfmt -stdin`
##   ("off": none)
import nedplugin

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for ols (when it is installed), \"off\" for " &
           "none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for " &
           "odinfmt -stdin (when it is installed), \"off\" for none. Plugins: reload after a change")

language("odin", LangSpec(
  name: "Odin",
  extensions: @["odin"],
  lineComment: "//",
  blockComment: @["/*", "*/"],
  nestedComments: true,
  quotes: "\"'`",
  charLiterals: true,
  multilineStrings: true,        # (a `raw string` goes on below; a "…" one does not, but is closed as you type)
  capitalTypes: true,            # (Odin's way: Ada_Case types, SCREAMING_CASE constants)
  decorators: true,
  keywords: @["asm", "auto_cast", "bit_field", "bit_set", "break", "case", "cast", "context", "continue", "defer",
              "distinct", "do", "dynamic", "else", "enum", "fallthrough", "for", "foreign", "if", "import", "in",
              "map", "matrix", "not_in", "or_break", "or_continue", "or_else", "or_return", "package", "proc",
              "return", "struct", "switch", "transmute", "union", "using", "when", "where"],
  types: @["bool", "b8", "b16", "b32", "b64", "int", "i8", "i16", "i32", "i64", "i128", "uint", "u8", "u16", "u32",
           "u64", "u128", "uintptr", "i16le", "i32le", "i64le", "i128le", "u16le", "u32le", "u64le", "u128le",
           "i16be", "i32be", "i64be", "i128be", "u16be", "u32be", "u64be", "u128be", "f16", "f32", "f64", "f16le",
           "f32le", "f64le", "f16be", "f32be", "f64be", "complex32", "complex64", "complex128", "quaternion64",
           "quaternion128", "quaternion256", "rune", "string", "cstring", "string16", "cstring16", "rawptr",
           "typeid", "any"],
  constants: @["true", "false", "nil", "ODIN_OS", "ODIN_ARCH", "ODIN_DEBUG", "ODIN_ENDIAN", "ODIN_VENDOR",
               "ODIN_VERSION", "ODIN_ROOT", "ODIN_BUILD_MODE", "ODIN_OPTIMIZATION_MODE", "ODIN_NO_RTTI"],
  builtins: @["len", "cap", "size_of", "align_of", "offset_of", "offset_of_by_string", "type_of", "type_info_of",
              "typeid_of", "swizzle", "complex", "quaternion", "real", "imag", "jmag", "kmag", "conj",
              "expand_values", "min", "max", "abs", "clamp", "soa_zip", "soa_unzip", "make", "new", "new_clone",
              "free", "free_all", "delete", "append", "inject_at", "assign_at", "ordered_remove",
              "unordered_remove", "pop", "clear", "reserve", "resize", "copy", "panic", "assert", "unreachable",
              "raw_data", "card",
              # (the names of #directives, and of attributes in @(…): ned's generic lexer has no colour of their
              # own for them, so they have a built-in's — only the ones no one would name a variable)
              "partial", "force_inline", "force_no_inline", "no_bounds_check", "bounds_check", "type_assert",
              "no_type_assert", "caller_location", "optional_ok", "optional_allocator_error", "raw_union", "no_nil",
              "shared_nil", "soa", "simd", "c_vararg", "by_ptr", "any_int", "no_alias", "load_directory",
              "load_hash", "unroll", "row_major", "column_major", "require_results", "link_name", "link_prefix",
              "link_section", "default_calling_convention", "deferred_in", "deferred_out", "deferred_none",
              "deferred_in_out", "thread_local", "optimization_mode", "no_instrumentation", "enable_target_feature",
              "require_target_feature", "objc_name", "objc_type", "objc_is_class_method", "entry_point_only"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 4,
  tabs: true,
  # (the folder is the package; only the file when more of the folder's files have a main — a folder of examples)
  run: "sh -c 'if [ \"$(grep -l \"^main *:: *proc\" *.odin 2>/dev/null | wc -l)\" -gt 1 ]; then " &
       "odin run \"$file\" -file -out:\"$tmp/ned_run\"; else odin run . -out:\"$tmp/ned_run\"; fi'",
  build: "sh -c 'if [ \"$(grep -l \"^main *:: *proc\" *.odin 2>/dev/null | wc -l)\" -gt 1 ]; then " &
         "odin build \"$file\" -file; else odin build .; fi'",
  # (a package without a main is checked too; its errors as file:line:col)
  check: "sh -c 'if [ \"$(grep -l \"^main *:: *proc\" *.odin 2>/dev/null | wc -l)\" -gt 1 ]; then " &
         "odin check \"$file\" -file -error-pos-style:unix; else odin check . -no-entry-point " &
         "-error-pos-style:unix; fi'",
  pairs: "()[]{}\"\"''``"))

snippet("odin", "proc", "${1:name} :: proc($2) {\n\t$0\n}", "a procedure")
snippet("odin", "struct", "${1:Name} :: struct {\n\t${2:field}: ${3:int},\n}$0", "a struct")
snippet("odin", "for", "for ${1:i} in ${2:0 ..< n} {\n\t$0\n}", "a for loop over a range")
snippet("odin", "switch", "switch ${1:value} {\ncase ${2:a}:\n\t$0\ncase:\n}", "a switch with a default case")
snippet("odin", "if", "if ${1:condition} {\n\t$0\n}", "an if")

# ── the outline, when there is no language server ──

type OdinScan = object
  comment: int                   # inside /* */ (they nest): how deep
  raw: bool                      # inside a `raw string` that goes on to the next line

# whether c can start an Odin name: a letter, _ or a byte of a non-ASCII character
func odinIdentStart(c: char): bool = c in {'a'..'z', 'A'..'Z', '_'} or ord(c) >= 0x80
# whether c can be part of an Odin name
func odinIdentChar(c: char): bool = odinIdentStart(c) or c in {'0'..'9'}

proc odinCode(s: string, st: var OdinScan): string =
  ## the line with its comments and strings made spaces (the columns kept): only the code is read
  result = s
  var i = 0
  while i < s.len:
    if st.comment > 0:
      if s.continuesWith("/*", i):
        inc st.comment
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
      elif s.continuesWith("*/", i):
        dec st.comment
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
      else:
        result[i] = ' '
        inc i
    elif st.raw:
      if s[i] == '`': st.raw = false
      result[i] = ' '
      inc i
    elif s.continuesWith("//", i):
      for k in i ..< s.len: result[k] = ' '
      break
    elif s.continuesWith("/*", i):
      st.comment = 1
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
    elif s[i] == '`':
      st.raw = true
      result[i] = ' '
      inc i
    elif s[i] in {'"', '\''}:
      let q = s[i]
      result[i] = ' '
      inc i
      while i < s.len and s[i] != q:
        if s[i] == '\\' and i + 1 < s.len:
          result[i] = ' '
          inc i
        result[i] = ' '
        inc i
      if i < s.len:
        result[i] = ' '
        inc i
    else: inc i

proc odinSymbols(lines: seq[string]): seq[Symbol] =
  ## `name :: proc …`, `Name :: struct …`, `N :: 10` …: the declarations, nested as the braces nest them
  var st: OdinScan
  var level = 0                  # how deep in braces
  var open: seq[int]             # the brace level inside each declaration still open (its body)
  for ln, s in lines:
    let code = odinCode(s, st)
    var i = 0
    while i < code.len and code[i] in {' ', '\t'}: inc i
    # (an attribute before it on the line: `@(private) foo :: proc() {`)
    if i < code.len and code[i] == '@':
      inc i
      if i < code.len and code[i] == '(':
        var d = 0
        while i < code.len:
          if code[i] == '(': inc d
          elif code[i] == ')':
            dec d
            if d == 0:
              inc i
              break
          inc i
      else:
        while i < code.len and odinIdentChar(code[i]): inc i
      while i < code.len and code[i] in {' ', '\t'}: inc i
    var found = false
    let at = level
    if i < code.len and odinIdentStart(code[i]):
      let col = i
      var e = i
      while e < code.len and odinIdentChar(code[e]): inc e
      let name = code[col ..< e]
      var k = e
      while k < code.len and code[k] in {' ', '\t'}: inc k
      if code.continuesWith("::", k) and not code.continuesWith(":::", k):
        k += 2
        while k < code.len and code[k] in {' ', '\t'}: inc k
        var kind = "constant"
        var r = k                # the start of what is declared, after the directives
        var isTypeDirective = false
        while r < code.len and code[r] == '#':
          var q = r + 1
          while q < code.len and odinIdentChar(code[q]): inc q
          if code[r + 1 ..< q] == "type": isTypeDirective = true
          r = q
          while r < code.len and code[r] in {' ', '\t'}: inc r
        var w = r
        while w < code.len and odinIdentChar(code[w]): inc w
        let word = code[r ..< w]
        case word
        of "proc": kind = (if isTypeDirective: "type" else: "function")
        of "struct": kind = "struct"
        of "enum": kind = "enum"
        of "union", "bit_set", "bit_field", "distinct", "matrix", "map": kind = "type"
        else:
          if isTypeDirective or (r < code.len and code[r] in {'[', '^'}) or
             (word.len > 0 and word[0] in {'A'..'Z'} and w >= code.strip(leading = false).len): kind = "type"
        # its detail: what follows `::` up to its body (`{`, but a group's `proc{a, b}` is the declaration), from
        # the line itself — its strings kept, a comment after it left out
        var stop = code.strip(leading = false).len
        let group = word == "proc" and code[w ..< max(w, stop)].strip(trailing = false).startsWith("{")
        let brace = code.find('{', k)
        if brace >= 0 and brace < stop and not group: stop = brace
        var detail = s[k ..< max(k, stop)].strip
        if detail.endsWith("---"): detail = detail[0 ..< ^3].strip
        if detail.endsWith("(") or detail.endsWith(","): detail = detail[0 ..< ^1].strip
        if detail.len > 80: detail = detail[0 ..< 77] & "…"
        var depth = 0
        for b in open:
          if b <= at: inc depth
        result.add Symbol(name: name, kind: kind, detail: detail, line: ln, col: col, depth: depth)
        found = true
    for c in code:
      if c == '{': inc level
      elif c == '}': level = max(0, level - 1)
    if found and level > at: open.add at + 1
    while open.len > 0 and open[^1] > level: open.setLen(open.len - 1)

# ── the tools ──

proc odinHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let odinServerSet = setting("server", "").strip
var odinServer: seq[string]
if odinServerSet == "off": discard
elif odinServerSet.len > 0:
  if odinHave(odinServerSet): odinServer = odinServerSet.splitWhitespace()
  else: echo "odin: the server " & odinServerSet & " is not installed (plugins.odin.server)"
elif findExe("ols").len > 0: odinServer = @["ols"]
if odinServer.len > 0:
  odinServer[0] = expandTilde(odinServer[0])
  languageServer("odin", odinServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("odin") do (b: Buf) -> seq[Symbol]:
    odinSymbols(b.lines)

let odinFmtSet = setting("formatter", "").strip
if odinFmtSet == "off": discard
elif odinFmtSet.len > 0:
  if odinHave(odinFmtSet): formatter("odin", odinFmtSet)
  else: echo "odin: the formatter " & odinFmtSet & " is not installed (plugins.odin.formatter)"
elif findExe("odinfmt").len > 0: formatter("odin", "odinfmt -stdin")
