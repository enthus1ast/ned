## ada — Ada and SPARK: colours, comments, indentation, F5, snippets, an outline; the Ada Language Server and gnatpp
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Ada's files — bodies `.adb`, specifications `.ads`,
## `.ada`, and GPR project files `.gpr` —: their colours (ned's generic lexer with Ada's words, in any case:
## `procedure`, `PROCEDURE` and `Procedure` alike; its types — Integer, Natural, String, Boolean …; True and False;
## Put_Line and the other Text_IO procedures; 'c' characters), `--` comments, indentation after `is`, `begin`,
## `then`, `else`, `loop`, `record`, `declare`, `private`, `generic` and `=>`, a level out when a line becomes `end`,
## `begin`, `else`, `elsif`, `exception` or `private`, three spaces as GNAT's style writes, brackets and quotes that
## close themselves, snippets (proc, func, spec, body, if, case, loop, for, while, declare, record, task) and F5: in
## an Alire crate (an alire.toml above the file) `alr run`, else gnatmake into a folder of ned's own, then the
## program. Build (Alt+B) is `alr build`, `gprbuild` with a project file beside the file, or gnatmake, and the check
## on save is GNAT's semantic check (`gcc -c -gnatc`, no object made): an error is at its line.
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the file's packages (specifications and
## bodies), their procedures, functions, tasks, protected objects and entries, nested as their `end`s say, and its
## types and subtypes (records, enumerations), from a simple scan.
##
## The tools, when they are on PATH — GNAT, the Ada compiler: Termux has no package (use a Linux distribution's
## gnat, or Alire, which installs one: https://alire.ada.dev); elsewhere `apt install gnat gprbuild` or Alire
## - ada_language_server (completion, hover, go to definition, problems, formatting): it comes with Alire's
##   toolchain or https://github.com/AdaCore/ada_language_server/releases
## - gnatpp, the formatter (Format document, and on save with editor.formatOnSave): it comes with GNAT's tools
##   (libadalang-tools)
##
## Settings (the Plugins dock › ada › its settings; Plugins: reload after a change):
## - plugins.ada.server — the language server's command, when it is not `ada_language_server` ("off": none)
## - plugins.ada.formatter — the formatter's command: its text on stdin, or $in and $out — when it is not
##   `gnatpp --pipe $in > $out` ("off": none)
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs Alire, gprbuild or gnatmake for F5 and Build, GNAT for the check, and the Ada Language Server and gnatpp when they are installed")

settingDef("server", "", "The language server's command: empty for ada_language_server (when it is installed), " &
           "\"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command — the text on its stdin, or $in and $out: empty for gnatpp " &
           "(when it is installed), \"off\" for none. Plugins: reload after a change")

func adaCases(ws: openArray[string]): seq[string] =
  ## each word as Ada takes it, in any case: lower, UPPER and Capitalised (Put_Line: as written too)
  for w in ws:
    for v in [w, w.toLowerAscii, w.toUpperAscii, w.toLowerAscii.capitalizeAscii]:
      if v notin result: result.add v

language("ada", LangSpec(
  name: "Ada",
  extensions: @["adb", "ads", "ada", "gpr"],
  lineComment: "--",
  quotes: "\"",
  charLiterals: true,
  keywords: adaCases(["abort", "abs", "abstract", "accept", "access", "aliased", "all", "and", "array", "at",
                      "begin", "body", "case", "constant", "declare", "delay", "delta", "digits", "do", "else",
                      "elsif", "end", "entry", "exception", "exit", "for", "function", "generic", "goto", "if", "in",
                      "interface", "is", "limited", "loop", "mod", "new", "not", "null", "of", "or", "others", "out",
                      "overriding", "package", "parallel", "pragma", "private", "procedure", "protected", "raise",
                      "range", "record", "rem", "renames", "requeue", "return", "reverse", "select", "separate",
                      "some", "subtype", "synchronized", "tagged", "task", "terminate", "then", "type", "until",
                      "use", "when", "while", "with", "xor",
                      # (a GPR project file's own)
                      "project", "extends", "external"]),
  types: adaCases(["Integer", "Natural", "Positive", "Long_Integer", "Long_Long_Integer", "Short_Integer",
                   "Float", "Long_Float", "Long_Long_Float", "Short_Float", "Boolean", "Character",
                   "Wide_Character", "Wide_Wide_Character", "String", "Wide_String", "Wide_Wide_String", "Duration",
                   "Unbounded_String", "Bounded_String", "File_Type", "Count", "Address", "Unsigned_8",
                   "Unsigned_16", "Unsigned_32", "Unsigned_64", "Exception_Occurrence"]),
  constants: adaCases(["True", "False"]),
  builtins: adaCases(["Put_Line", "Put", "Get", "Get_Line", "New_Line", "Skip_Line", "Open", "Create", "Close",
                      "End_Of_File", "To_String", "To_Unbounded_String", "Length", "Append", "Image", "Value",
                      "Ada", "Text_IO", "Integer_Text_IO", "Float_Text_IO", "Strings", "Unbounded",
                      "Containers", "Vectors", "Exceptions", "Calendar", "Command_Line", "Interfaces", "System",
                      "Unchecked_Conversion", "Unchecked_Deallocation", "Assert", "Pre", "Post", "Inline",
                      "Import", "Export", "Convention", "SPARK_Mode"]),
  functionWords: adaCases(["procedure", "function", "entry"]),
  indentAfter: adaCases(["is", "begin", "then", "else", "loop", "record", "declare", "private", "generic",
                         "exception", "select", "do"]) & @["=>", "("],
  dedentWords: adaCases(["end", "begin", "else", "elsif", "exception", "private"]),
  indentSize: 3,
  # (an Alire crate above the file: alr; else gnatmake, its objects and program in ned's own folder)
  run: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/alire.toml\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
       "if [ -f \"$d/alire.toml\" ]; then cd \"$d\" && exec alr run; " &
       "else gnatmake -q -D \"$tmp\" \"$file\" -o \"$tmp/$name\" && exec \"$tmp/$name\"; fi'",
  build: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/alire.toml\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
         "gpr=$(ls \"$dir\"/*.gpr 2>/dev/null | head -n 1); " &
         "if [ -f \"$d/alire.toml\" ]; then cd \"$d\" && exec alr build; " &
         "elif [ -n \"$gpr\" ]; then exec gprbuild -p -P \"$gpr\"; else exec gnatmake -D \"$tmp\" \"$file\"; fi'",
  # (GNAT's semantic check, in ned's own folder so no .ali is left beside the file; nothing when GNAT is missing)
  # (the file and its folder after the script: ned puts them there quoted)
  check: "sh -c 'command -v gnat >/dev/null 2>&1 || exit 0; " &
         "cd \"$tmp\" && exec gcc -c -gnatc -gnatf -I\"$2\" \"$1\"' " &
         "sh \"$file\" \"$dir\"",
  pairs: "()[]\"\""))

snippet("ada", "proc", "procedure ${1:Name} is\nbegin\n\t${0:null;}\nend ${1:Name};", "a procedure")
snippet("ada", "func", "function ${1:Name} (${2:X : Integer}) return ${3:Integer} is\nbegin\n\t" &
        "return ${0:X};\nend ${1:Name};",
        "a function")
snippet("ada", "spec", "package ${1:Name} is\n\n\t$0\n\nprivate\n\nend ${1:Name};", "a package specification")
snippet("ada", "body", "package body ${1:Name} is\n\n\t$0\n\nend ${1:Name};", "a package body")
snippet("ada", "if", "if ${1:Condition} then\n\t$0\nend if;", "an if")
snippet("ada", "case", "case ${1:X} is\n\twhen ${2:1} =>\n\t\t$3\n\twhen others =>\n\t\t${0:null;}\nend case;",
        "a case")
snippet("ada", "loop", "loop\n\t$1\n\texit when ${2:Done};\nend loop;$0", "a loop")
snippet("ada", "for", "for ${1:I} in ${2:1 .. 10} loop\n\t$0\nend loop;", "a for loop")
snippet("ada", "while", "while ${1:Condition} loop\n\t$0\nend loop;", "a while loop")
snippet("ada", "declare", "declare\n\t${1:X : Integer := 0;}\nbegin\n\t$0\nend;", "a declare block")
snippet("ada", "record", "type ${1:Name} is record\n\t${2:X : Integer;}\nend record;$0", "a record type")
snippet("ada", "task", "task body ${1:Worker} is\nbegin\n\tloop\n\t\t$0\n\tend loop;\nend ${1:Worker};", "a task body")
snippet("ada", "main", "with Ada.Text_IO; use Ada.Text_IO;\n\nprocedure ${1:Main} is\nbegin\n\t" &
        "Put_Line (\"${2:Hello}\");$0\nend ${1:Main};",
        "a program")

# ── the outline, when there is no language server ──

func adaCode(s: string): string =
  ## the line in lower case with its comment, strings and characters made spaces (the columns kept)
  result = s.toLowerAscii
  var i = 0
  while i < s.len:
    if s.continuesWith("--", i):
      for k in i ..< s.len: result[k] = ' '
      break
    if s[i] == '"':
      result[i] = ' '
      inc i
      while i < s.len:
        if s[i] == '"':
          if i + 1 < s.len and s[i + 1] == '"':          # ("" inside "…" is one quote)
            result[i] = ' '
            result[i + 1] = ' '
            i += 2
            continue
          break
        result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
    elif s[i] == '\'' and i + 2 < s.len and s[i + 2] == '\'' and
         (i == 0 or s[i - 1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_', ')'}):
      # ('c' a character — not the tick of X'First)
      result[i] = ' '
      result[i + 1] = ' '
      result[i + 2] = ' '
      i += 2
    inc i

func adaWords(code: string): seq[(string, int)] =
  ## the words of a line (lower case; a dotted name as one: ada.text_io) and where each starts
  var i = 0
  while i < code.len:
    if code[i] in {'a'..'z'}:
      let a = i
      while i < code.len and (code[i] in {'a'..'z', '0'..'9', '_'} or
                              (code[i] == '.' and i + 1 < code.len and code[i + 1] in {'a'..'z'})):
        inc i
      result.add (code[a ..< i], a)
    else: inc i

type AdaOpen = object
  unit: bool                     # a unit's body or a package (false: a declare block, an accept … do)
  begun: bool                    # its begin seen (a begin after that is a block of its own)

func adaSymbols*(lines: seq[string]): seq[Symbol] =
  ## the packages, procedures, functions, tasks, protected objects and entries, nested as their ends say; the
  ## types and subtypes
  var open: seq[AdaOpen]
  var pending = -1               # a declaration whose `is` (a body) or `;` (none) has not come yet: its depth
  var units = 0                  # the units in `open`: the depth of what is declared now
  var inRecord = 0               # a record's fields (until end record)
  for ln, s in lines:
    let code = adaCode(s)
    let ws = adaWords(code)
    if ws.len == 0: continue
    template add(nm, kd, dt: string, cl, dp: int) =
      result.add Symbol(name: nm, kind: kd, detail: dt, line: ln, col: cl, depth: dp)
    template orig(w: (string, int)): string = s[w[1] ..< w[1] + w[0].len]
    # a declaration's `is`, or its `;`, on a later line
    if pending >= 0:
      let isAt = block:
        var r = -1
        for (w, c) in ws:
          if w == "is":
            r = c
            break
        r
      let semi = code.find(';')
      if isAt >= 0 and (semi < 0 or isAt < semi):
        let after = code[isAt + 2 .. ^1].strip
        if not (after.startsWith("separate") or after.startsWith("new") or after.startsWith("abstract") or
                after.startsWith("null") or after.startsWith("(")):
          open.add AdaOpen(unit: true)
          inc units
        pending = -1
        continue
      elif semi >= 0:
        pending = -1
        continue
    if inRecord > 0:
      if ws[0][0] == "end" and ws.len > 1 and ws[1][0] == "record": dec inRecord
      elif ws[^1][0] == "record" and ws[0][0] != "end": inc inRecord
      continue
    let first = ws[0][0]
    case first
    of "end":
      let what = if ws.len > 1: ws[1][0] else: ""
      if what in ["if", "loop", "case", "select", "return", "record"]: continue
      if open.len > 0:
        if open[^1].unit: dec units
        discard open.pop()
      continue
    of "begin":
      if open.len > 0 and not open[^1].begun: open[^1].begun = true
      else: open.add AdaOpen(unit: false, begun: true)            # (a block: begin … end;)
      continue
    of "declare":
      open.add AdaOpen(unit: false)
      continue
    of "accept":
      if ws[^1][0] == "do": open.add AdaOpen(unit: false, begun: true)
      continue
    of "with", "use", "pragma", "limited":
      continue
    else: discard
    # a unit: [overriding] procedure, function, package [body], task [type | body], protected [type | body], entry
    var k = 0
    if first == "overriding": k = 1
    elif first == "not" and ws.len > 1 and ws[1][0] == "overriding": k = 2
    elif first in ["separate", "private"] and ws.len > 1: k = 1
    if k < ws.len and ws[k][0] in ["procedure", "function", "package", "task", "protected", "entry"]:
      let kind = ws[k][0]
      var j = k + 1
      var detail = kind
      if j < ws.len and ws[j][0] in ["body", "type"]:
        detail = kind & " " & ws[j][0]
        inc j
      if j < ws.len:
        let name = orig(ws[j])
        let sk = case kind
                 of "package": "module"
                 of "task", "protected": "class"
                 else: (if units > 0 and kind == "entry": "method" else: "function")
        var d = detail
        if kind in ["procedure", "function", "entry"]:
          let p = code.find('(', ws[j][1])
          if p >= 0:
            let close = code.find(')', p)
            d = detail & " " & (if close > p: s[p .. close] else: "(…)")
        add(name, sk, d, ws[j][1], units)
        # its body: an `is` (not `is new`, `is separate` …) before the `;`; neither yet: on a later line
        var isAt = -1
        for (w, c) in ws[j + 1 .. ^1]:
          if w == "is":
            isAt = c
            break
        let semi = code.find(';', ws[j][1])
        if isAt >= 0 and (semi < 0 or isAt < semi):
          let after = code[isAt + 2 .. ^1].strip
          if not (after.startsWith("separate") or after.startsWith("new") or after.startsWith("abstract") or
                  after.startsWith("null") or after.startsWith("(")):
            open.add AdaOpen(unit: true)
            inc units
        elif semi < 0 and not (kind == "task" and ws.len == j + 1 and code.strip.endsWith(";")):
          pending = units
      continue
    # a type or a subtype
    if first in ["type", "subtype"] and ws.len > 1:
      let name = orig(ws[1])
      let rest = code[ws[1][1] + ws[1][0].len .. ^1]
      let isAt = rest.find(" is ")
      let def = if isAt >= 0: rest[isAt + 4 .. ^1].strip else: rest.strip
      var kind = "type"
      var detail = first
      if def.startsWith("("):
        kind = "enum"
        detail = "enumeration"
      elif "record" in def or "tagged" in def:
        kind = "struct"
        detail = if "tagged" in def: "tagged record" else: "record"
        if def.endsWith("record") and "end record" notin def and "null record" notin def: inc inRecord
      elif def.startsWith("new"): detail = "new " & def[3 .. ^1].strip.strip(chars = {';', ' '}).split(' ')[0]
      elif def.startsWith("range"): detail = "range"
      add(name, kind, detail, ws[1][1], units)

# ── the tools ──

proc adaHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let adaServerSet = setting("server", "").strip
var adaServer: seq[string]
if adaServerSet == "off": discard
elif adaServerSet.len > 0:
  if adaHave(adaServerSet): adaServer = adaServerSet.splitWhitespace()
  else: echo "ada: the server " & adaServerSet & " is not installed (plugins.ada.server)"
else:
  for cmd in ["ada_language_server", "ada-language-server"]:
    if adaHave(cmd):
      adaServer = @[cmd]
      break
if adaServer.len > 0:
  adaServer[0] = expandTilde(adaServer[0])
  languageServer("ada", adaServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("ada") do (b: Buf) -> seq[Symbol]:
    adaSymbols(b.lines)

let adaFmtSet = setting("formatter", "").strip
if adaFmtSet == "off": discard
elif adaFmtSet.len > 0:
  if adaHave(adaFmtSet): formatter("ada", adaFmtSet)
  else: echo "ada: the formatter " & adaFmtSet & " is not installed (plugins.ada.formatter)"
elif adaHave("gnatpp"): formatter("ada", "gnatpp --pipe $in > $out")
