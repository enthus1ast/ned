## fortran — Fortran: colours, comments, indentation, F5 (fpm or gfortran), snippets, an outline; fortls and fprettify
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Fortran's files — free form `.f90`, `.f95`, `.f03`,
## `.f08`, `.f18`, and the fixed form of `.f`, `.for` and `.f77` — : their colours (ned's generic lexer with
## Fortran's words, in any case: `program`, `PROGRAM` and `Program` alike; its types — integer, real, character …;
## .true. and .false.; the intrinsic functions), `!` comments (a `c` or `*` in the first column too, in fixed form's
## outline), indentation after `then`, `else`, `contains`, `interface` and a bare `do`, a level out when a line
## becomes `end` or `else`, three spaces as fprettify writes, brackets and quotes that close themselves, snippets
## (program, module, sub, func, do, if, type, select) and F5: `fpm run` in an fpm project (an fpm.toml above the
## file), else gfortran into a program of ned's own, then that program. Build (Alt+B) is `fpm build` or
## `gfortran -Wall` the same way, and the check on save is `gfortran -fsyntax-only` (or `fpm build`).
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the file's programs, modules and submodules,
## their subroutines and functions (under them, after `contains`), derived types and interfaces, from a simple scan.
##
## The tools, when they are on PATH — gfortran: Termux `pkg install gcc-default` (or `pkg install flang`);
## elsewhere your system's gfortran package; fpm: https://fpm.fortran-lang.org
## - fortls, the Fortran language server (completion, hover, go to definition, problems): `pip install fortls`
## - fprettify, the formatter (Format document, and on save with editor.formatOnSave): `pip install fprettify`
##
## Settings (the Plugins dock › fortran › its settings; Plugins: reload after a change):
## - plugins.fortran.server — the language server's command, when it is not `fortls` ("off": none)
## - plugins.fortran.formatter — the formatter's command (the text on its stdin), when it is not
##   `fprettify --silent` ("off": none)
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs gfortran or fpm for F5, Build and the check, and fortls and fprettify when they are installed")

settingDef("server", "", "The language server's command: empty for fortls (when it is installed), \"off\" for none. " &
           "Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for fprettify (when it " &
           "is installed), \"off\" for none. Plugins: reload after a change")

func fortranCases(ws: openArray[string]): seq[string] =
  ## each word as Fortran takes it, in any case: lower, UPPER and Capitalised (ned's colours match words exactly)
  for w in ws:
    for v in [w, w.toUpperAscii, w.capitalizeAscii]:
      if v notin result: result.add v

language("fortran", LangSpec(
  name: "Fortran",
  extensions: @["f90", "f95", "f03", "f08", "f18", "f", "for", "f77", "fpp", "ftn"],
  lineComment: "!",
  quotes: "\"'",
  keywords: fortranCases(["program", "end", "module", "submodule", "subroutine", "function", "contains", "use",
                          "only", "implicit", "none", "type", "class", "interface", "procedure", "call", "if", "then",
                          "else", "elseif", "endif", "do", "enddo", "while", "select", "case", "default", "where",
                          "elsewhere", "forall", "allocate", "deallocate", "allocatable", "pointer", "target",
                          "intent", "in", "out", "inout", "parameter", "dimension", "save", "data", "common",
                          "equivalence", "external", "intrinsic", "optional", "public", "private", "protected",
                          "return", "stop", "exit", "cycle", "continue", "goto", "print", "read", "write", "open",
                          "close", "format", "result", "recursive", "pure", "impure", "elemental", "abstract",
                          "extends", "import", "associate", "block", "critical", "concurrent", "sequence", "value",
                          "volatile", "bind", "enum", "enumerator", "nullify", "inquire", "rewind", "backspace",
                          "error", "sync", "all", "entry", "include", "non_overridable", "nopass", "pass",
                          "deferred", "final", "generic", "operator", "assignment", "endfunction", "endsubroutine",
                          "endmodule", "endprogram", "selectcase", "contiguous", "asynchronous"]),
  types: fortranCases(["integer", "real", "complex", "character", "logical", "double", "precision"]),
  constants: fortranCases(["true", "false"]),
  builtins: fortranCases(["abs", "sqrt", "sin", "cos", "tan", "asin", "acos", "atan", "atan2", "exp", "log",
                          "log10", "size", "shape", "sum", "product", "maxval", "minval", "maxloc", "minloc", "max",
                          "min", "mod", "modulo", "int", "nint", "dble", "cmplx", "trim", "adjustl", "adjustr",
                          "len_trim", "index", "scan", "verify", "allocated", "present", "associated", "huge",
                          "tiny", "epsilon", "matmul", "transpose", "dot_product", "reshape", "count", "any",
                          "merge", "pack", "unpack", "spread", "floor", "ceiling", "sign", "achar", "iachar", "char",
                          "ichar", "kind", "selected_int_kind", "selected_real_kind", "lbound", "ubound",
                          "random_number", "random_seed", "cpu_time", "system_clock", "date_and_time",
                          "get_command_argument", "command_argument_count", "get_environment_variable",
                          "move_alloc", "storage_size", "norm2", "repeat", "len", "new_line", "real", "aimag",
                          "conjg", "iand", "ior", "ieor", "not", "ishft", "btest", "execute_command_line"]),
  functionWords: fortranCases(["subroutine", "function", "program"]),
  classWords: fortranCases(["module", "submodule"]),
  indentAfter: fortranCases(["then", "else", "contains", "interface", "do"]),
  dedentWords: fortranCases(["end", "else", "contains"]),
  indentSize: 3,
  # (an fpm project above the file: fpm; else gfortran into ned's own folder, its modules there too)
  run: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/fpm.toml\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
       "if [ -f \"$d/fpm.toml\" ]; then cd \"$d\" && exec fpm run; " &
       "else gfortran -J \"$tmp\" \"$file\" -o \"$tmp/$name\" && exec \"$tmp/$name\"; fi'",
  build: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/fpm.toml\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
         "if [ -f \"$d/fpm.toml\" ]; then cd \"$d\" && exec fpm build; " &
         "else exec gfortran -Wall -J \"$tmp\" \"$file\" -o \"$name\"; fi'",
  # (one line for each problem, as ned reads them; nothing without the compiler; the file and its folder after the
  # script: ned puts them there quoted)
  check: "sh -c 'd=\"$2\"; while [ ! -f \"$d/fpm.toml\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
         "if [ -f \"$d/fpm.toml\" ] && command -v fpm >/dev/null 2>&1; then cd \"$d\" && exec fpm build; " &
         "elif command -v gfortran >/dev/null 2>&1; then " &
         "exec gfortran -fsyntax-only -fdiagnostics-plain-output -Wall -J \"$tmp\" \"$1\"; fi' sh \"$file\" \"$dir\"",
  pairs: "()[]\"\"''"))

snippet("fortran", "program", "program ${1:main}\n\timplicit none\n\t$0\nend program ${1:main}", "a program")
snippet("fortran", "module", "module ${1:name}\n\timplicit none\n\tprivate\n\t$2\ncontains\n\t$0\nend module ${1:name}",
        "a module")
snippet("fortran", "sub", "subroutine ${1:name}(${2:x})\n\t${3:real, intent(in) :: x}\n\t$0\nend subroutine ${1:name}",
        "a subroutine")
snippet("fortran", "func", "function ${1:name}(${2:x}) result(${3:y})\n\t${4:real, intent(in) :: x}\n\t" &
        "real :: ${3:y}\n\t$0\nend function ${1:name}",
        "a function")
snippet("fortran", "do", "do ${1:i} = ${2:1}, ${3:n}\n\t$0\nend do", "a do loop")
snippet("fortran", "if", "if (${1:condition}) then\n\t$0\nend if", "an if block")
snippet("fortran", "type", "type :: ${1:name}\n\t${2:real :: x}\n$0\nend type ${1:name}", "a derived type")
snippet("fortran", "select", "select case (${1:x})\ncase (${2:1})\n\t$3\ncase default\n\t$0\nend select",
        "a select case")

# ── the outline, when there is no language server ──

func fortranCode(s: string): string =
  ## the line in lower case with its comment and strings made spaces (the columns kept)
  result = s.toLowerAscii
  var i = 0
  while i < s.len:
    if s[i] == '!':
      for k in i ..< s.len: result[k] = ' '
      break
    if s[i] == '"' or s[i] == '\'':
      let q = s[i]
      result[i] = ' '
      inc i
      while i < s.len:
        if s[i] == q:
          if i + 1 < s.len and s[i + 1] == q:        # ('' inside '…' is one quote)
            result[i] = ' '
            result[i + 1] = ' '
            i += 2
            continue
          break
        result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
    inc i

# whether c can be part of a Fortran name
func fortranIdent(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

func fortranWords(code: string): seq[(string, int)] =
  ## the words of a line (lower case) and where each starts
  var i = 0
  while i < code.len:
    if code[i] in {'a'..'z', '_'}:
      let a = i
      while i < code.len and fortranIdent(code[i]): inc i
      result.add (code[a ..< i], a)
    else: inc i

const FortranUnits = ["program", "module", "submodule", "subroutine", "function", "type", "interface"]
const FortranPrefixes = ["pure", "impure", "elemental", "recursive", "module", "integer", "real", "complex",
                         "character", "logical", "double", "precision", "type", "class", "non_recursive", "simple"]

func fortranSymbols*(lines: seq[string], fixedForm = false): seq[Symbol] =
  ## the programs, modules and submodules, their subroutines and functions, derived types and interfaces —
  ## nested as their `end`s say
  var stack: seq[string]                 # what is open: program, module, subroutine, function, type, interface
  for ln, s in lines:
    if fixedForm and s.len > 0 and s[0] in {'c', 'C', '*', '!'}: continue
    let code = fortranCode(s)
    let t = code.strip
    if t.len == 0: continue
    let ws = fortranWords(code)
    if ws.len == 0: continue
    let first = ws[0][0]
    let depth = stack.len
    # the end of a program unit: end, end subroutine name, endmodule … (end do, end if: not followed)
    if first == "end" or (first.startsWith("end") and first[3 .. ^1] in FortranUnits):
      let what = if first.len > 3: first[3 .. ^1] elif ws.len > 1: ws[1][0] else: ""
      if (what.len == 0 or what in FortranUnits) and stack.len > 0: discard stack.pop()
      continue
    case first
    of "program", "module", "submodule":
      var k = 1
      if first == "submodule":                               # submodule (parent) name
        let close = code.find(')')
        while k < ws.len and ws[k][1] < close: inc k
      if not (first == "module" and ws.len > 1 and ws[1][0] in ["procedure", "function", "subroutine"]) and
         k < ws.len:
        let (name, col) = ws[k]
        result.add Symbol(name: s[col ..< col + name.len], kind: (if first == "program": "function" else: "module"),
                          detail: first, line: ln, col: col, depth: depth)
        stack.add first
        continue
    of "type":
      # a derived type's definition — type :: name, type, extends(x) :: name, type name — not type(x) :: var
      let after = code[ws[0][1] + 4 .. ^1].strip
      if after.len > 0 and after[0] != '(':
        let dc = code.find("::")
        var k = 1
        if dc > 0:
          while k < ws.len and ws[k][1] < dc: inc k
        if k < ws.len and (dc > 0 or k == 1) and ws[k][0] != "is":
          let (name, col) = ws[k]
          result.add Symbol(name: s[col ..< col + name.len], kind: "struct", detail: "type", line: ln, col: col,
                            depth: depth)
          stack.add "type"
          continue
    of "interface", "abstract":
      if first == "interface" or (ws.len > 1 and ws[1][0] == "interface"):
        let k = if first == "interface": 1 else: 2
        let name = if k < ws.len: s[ws[k][1] ..< ws[k][1] + ws[k][0].len] else: "interface"
        result.add Symbol(name: name, kind: "interface", detail: (if first == "abstract": "abstract interface"
                          else: "interface"), line: ln, col: (if k < ws.len: ws[k][1] else: ws[0][1]), depth: depth)
        stack.add "interface"
        continue
    else: discard
    # a subroutine or a function, after its prefixes (pure, recursive, real(8) …)
    var k = 0
    while k < ws.len and ws[k][0] in FortranPrefixes: inc k
    if k < ws.len and ws[k][0] in ["subroutine", "function"] and k + 1 < ws.len:
      let kind = ws[k][0]
      let (name, col) = ws[k + 1]
      let p = code.find('(', col)
      var detail = kind
      if p >= 0:
        let close = code.find(')', p)
        detail = kind & " " & (if close > p: s[p .. close] else: "(…)")
      result.add Symbol(name: s[col ..< col + name.len], kind: "function", detail: detail, line: ln, col: col,
                        depth: depth)
      stack.add kind

# ── the tools ──

proc fortranHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let fortranServerSet = setting("server", "").strip
var fortranServer: seq[string]
if fortranServerSet == "off": discard
elif fortranServerSet.len > 0:
  if fortranHave(fortranServerSet): fortranServer = fortranServerSet.splitWhitespace()
  else: echo "fortran: the server " & fortranServerSet & " is not installed (plugins.fortran.server)"
elif fortranHave("fortls"): fortranServer = @["fortls"]
if fortranServer.len > 0:
  fortranServer[0] = expandTilde(fortranServer[0])
  languageServer("fortran", fortranServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("fortran") do (b: Buf) -> seq[Symbol]:
    let p = b.path.toLowerAscii
    fortranSymbols(b.lines, p.endsWith(".f") or p.endsWith(".for") or p.endsWith(".f77") or p.endsWith(".ftn"))

let fortranFmtSet = setting("formatter", "").strip
if fortranFmtSet == "off": discard
elif fortranFmtSet.len > 0:
  if fortranHave(fortranFmtSet): formatter("fortran", fortranFmtSet)
  else: echo "fortran: the formatter " & fortranFmtSet & " is not installed (plugins.fortran.formatter)"
elif fortranHave("fprettify"): formatter("fortran", "fprettify --silent")
