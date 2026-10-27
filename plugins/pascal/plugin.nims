## pascal — Pascal (Free Pascal, Delphi, Lazarus): colours, comments, indentation, F5, snippets, an outline; pasls
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Pascal's files — `.pas`, `.pp`, `.lpr`, `.dpr` and
## `.dpk` —: their colours (ned's generic lexer with Pascal's words, in any case: `begin`, `BEGIN` and `Begin`
## alike; its types — Integer, String, Boolean …; True, False and nil; WriteLn, Inc, Length and the other
## built-ins), `//` and `{ }` comments, 'strings', indentation after `begin`, `then`, `do`, `else`, `repeat`,
## `record`, `of`, `try`, `var`, `const` and `type`, a level out when a line becomes `end`, `begin`, `until`,
## `else`, `except` or `finally` (so `begin` under an `if … then` sits under the `if`), two spaces as Lazarus
## writes, brackets and quotes that close themselves, snippets (program, unit, proc, func, class, begin, for, if,
## case, try, repeat, while) and F5: with a Lazarus project (`.lpi`) beside the file, `lazbuild` and its program;
## else fpc into a folder of ned's own, then that program. Build (Alt+B) is `lazbuild`, or fpc on the file (the
## program beside it), and the check on save compiles with `fpc -s` (no program made): an error is at its line.
## (* *) comments are coloured as code — ned gives a language one kind of block comment; `{ }` is the usual.
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the program, unit or library, its
## interface and implementation sections, its types (classes, records, objects and interfaces with their methods
## and properties under them; enumerations) and its procedures and functions (TFoo.Bar for a method's body), from
## a simple scan.
##
## The tools, when they are on PATH — Free Pascal (fpc): Termux `pkg install fpc`; elsewhere your system's fpc
## package, or https://www.freepascal.org/download.html; Lazarus (lazbuild) for its projects
## - pasls, a Pascal language server (completion, hover, go to definition, problems):
##   https://github.com/genericptr/pascal-language-server (it needs the Lazarus sources it reads, as it says)
## - a formatter only when you set one: `ptop $in $out` (it comes with fpc) or JEDI's
##
## Settings (the Plugins dock › pascal › its settings; Plugins: reload after a change):
## - plugins.pascal.server — the language server's command, when it is not `pasls` ("off": none)
## - plugins.pascal.formatter — the formatter's command: its text on stdin, or $in and $out ("": none)
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs fpc or lazbuild for F5, Build and the check, and pasls when it is installed")

settingDef("server", "", "The language server's command: empty for pasls (when it is installed), \"off\" for none. " &
           "Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command — the text on its stdin, or $in and $out (ptop $in $out): " &
           "empty for none. Plugins: reload after a change")

func pascalCases(ws: openArray[string]): seq[string] =
  ## each word as Pascal takes it, in any case: lower, UPPER and Capitalised (ned's colours match words exactly)
  for w in ws:
    for v in [w, w.toLowerAscii, w.toUpperAscii, w.toLowerAscii.capitalizeAscii]:
      if v notin result: result.add v

language("pascal", LangSpec(
  name: "Pascal",
  extensions: @["pas", "pp", "lpr", "dpr", "dpk"],
  lineComment: "//",
  blockComment: @["{", "}"],
  quotes: "'",
  keywords: pascalCases(["and", "array", "as", "asm", "begin", "case", "class", "const", "constructor",
                         "destructor", "div", "do", "downto", "else", "end", "except", "exports", "file",
                         "finalization", "finally", "for", "function", "goto", "if", "implementation", "in",
                         "inherited", "initialization", "inline", "interface", "is", "label", "library", "mod",
                         "not", "object", "of", "on", "operator", "or", "out", "packed", "procedure", "program",
                         "property", "raise", "record", "repeat", "resourcestring", "set", "shl", "shr", "then",
                         "threadvar", "to", "try", "type", "unit", "until", "uses", "var", "while", "with", "xor",
                         "absolute", "abstract", "cdecl", "default", "deprecated", "dynamic", "external", "forward",
                         "generic", "helper", "overload", "override", "private", "protected", "public", "published",
                         "read", "reintroduce", "specialize", "static", "stdcall", "strict", "virtual", "write",
                         "exit", "break", "continue", "self", "result"]),
  types: pascalCases(["Integer", "Cardinal", "ShortInt", "SmallInt", "LongInt", "Int64", "Byte", "Word",
                      "LongWord", "DWord", "QWord", "NativeInt", "NativeUInt", "SizeInt", "PtrInt", "PtrUInt",
                      "Real", "Single", "Double", "Extended", "Currency", "Comp", "Boolean", "ByteBool",
                      "LongBool", "Char", "AnsiChar", "WideChar", "String", "AnsiString", "WideString",
                      "UnicodeString", "ShortString", "RawByteString", "PChar", "PAnsiChar", "PWideChar",
                      "Pointer", "Variant", "Text", "TextFile", "TObject", "TClass", "Exception", "TStringList",
                      "TStrings", "TList", "TComponent"]),
  constants: pascalCases(["True", "False", "nil", "MaxInt", "MaxLongInt", "LineEnding"]),
  builtins: pascalCases(["WriteLn", "Write", "ReadLn", "Read", "Inc", "Dec", "Length", "SetLength", "High", "Low",
                         "Ord", "Chr", "Succ", "Pred", "Copy", "Pos", "Delete", "Insert", "Assigned", "Halt",
                         "New", "Dispose", "GetMem", "FreeMem", "FreeAndNil", "SizeOf", "Assign", "AssignFile",
                         "Reset", "Rewrite", "Append", "Close", "CloseFile", "Eof", "IntToStr", "StrToInt",
                         "FloatToStr", "StrToFloat", "Format", "UpperCase", "LowerCase", "Trim", "Abs", "Sqr",
                         "Sqrt", "Round", "Trunc", "Frac", "Random", "Randomize", "Exclude", "Include", "Concat",
                         "Val", "Str", "FillChar", "Move"]),
  functionWords: pascalCases(["procedure", "function", "constructor", "destructor"]),
  indentAfter: pascalCases(["begin", "then", "do", "else", "repeat", "record", "of", "try", "except", "finally",
                            "var", "const", "type", "uses", "private", "protected", "public", "published",
                            "class", "object"]) & @["("],
  dedentWords: pascalCases(["end", "begin", "until", "else", "except", "finally"]),
  indentSize: 2,
  # (a Lazarus project beside the file: lazbuild and the program it names; else fpc into ned's own folder)
  run: "sh -c 'lpi=$(ls \"$dir\"/*.lpi 2>/dev/null | head -n 1); " &
       "if [ -n \"$lpi\" ]; then cd \"$dir\" && lazbuild -q \"$lpi\" && exec \"./$(basename \"$lpi\" .lpi)\"; " &
       "else fpc -vew -FE\"$tmp\" -FU\"$tmp\" \"$file\" && exec \"$tmp/$name\"; fi'",
  build: "sh -c 'lpi=$(ls \"$dir\"/*.lpi 2>/dev/null | head -n 1); " &
         "if [ -n \"$lpi\" ]; then cd \"$dir\" && exec lazbuild \"$lpi\"; else exec fpc -vewn \"$file\"; fi'",
  check: "fpc -s -vew -FE\"$tmp\" -FU\"$tmp\" \"$file\"",
  pairs: "()[]''"))

snippet("pascal", "program", "program ${1:Hello};\n\n{$mode objfpc}{$H+}\n\nuses\n\tSysUtils;\n\nbegin\n\t$0\nend.",
        "a program")
snippet("pascal", "unit", "unit ${1:Name};\n\n{$mode objfpc}{$H+}\n\ninterface\n\n$0\n\nimplementation\n\nend.",
        "a unit")
snippet("pascal", "proc", "procedure ${1:Name}(${2:const S: String});\nbegin\n\t$0\nend;", "a procedure")
snippet("pascal", "func", "function ${1:Name}(${2:X: Integer}): ${3:Integer};\nbegin\n\tResult := $0;\nend;",
        "a function")
snippet("pascal", "class", "T${1:Name} = class(${2:TObject})\nprivate\n\tF${3:Value}: ${4:Integer};\npublic\n\t" &
        "constructor Create;\n\tproperty ${3:Value}: ${4:Integer} read F${3:Value} write F${3:Value};\nend;$0",
        "a class (in a type section)")
snippet("pascal", "begin", "begin\n\t$0\nend;", "a begin … end block")
snippet("pascal", "for", "for ${1:I} := ${2:0} to ${3:High(A)} do\nbegin\n\t$0\nend;", "a for loop")
snippet("pascal", "if", "if ${1:Condition} then\nbegin\n\t$0\nend;", "an if")
snippet("pascal", "case", "case ${1:X} of\n\t${2:1}: ${3:WriteLn('one')};\nelse\n\t$0\nend;", "a case statement")
snippet("pascal", "try", "try\n\t$1\nfinally\n\t${2:FreeAndNil(Obj)};\nend;$0", "try … finally")
snippet("pascal", "repeat", "repeat\n\t$0\nuntil ${1:Done};", "a repeat … until loop")
snippet("pascal", "while", "while ${1:Condition} do\nbegin\n\t$0\nend;", "a while loop")

# ── the outline, when there is no language server ──

func pascalCode(s: string, inBrace, inParen: var bool): string =
  ## the line in lower case with its comments and strings made spaces (the columns kept); a { } or (* *) comment
  ## may go on to the next lines
  result = s.toLowerAscii
  var i = 0
  while i < s.len:
    if inBrace:
      if s[i] == '}': inBrace = false
      result[i] = ' '
      inc i
    elif inParen:
      if s.continuesWith("*)", i):
        result[i] = ' '
        result[i + 1] = ' '
        inParen = false
        i += 2
      else:
        result[i] = ' '
        inc i
    elif s.continuesWith("//", i):
      for k in i ..< s.len: result[k] = ' '
      break
    elif s[i] == '{':
      inBrace = true
      result[i] = ' '
      inc i
    elif s.continuesWith("(*", i):
      inParen = true
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
    elif s[i] == '\'':
      result[i] = ' '
      inc i
      while i < s.len:
        if s[i] == '\'':
          if i + 1 < s.len and s[i + 1] == '\'':     # ('' inside '…' is one quote)
            result[i] = ' '
            result[i + 1] = ' '
            i += 2
            continue
          break
        result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
      inc i
    else: inc i

func pascalWords(code: string): seq[(string, int)] =
  ## the words of a line (lower case, a dotted name as one: tfoo.bar) and where each starts
  var i = 0
  while i < code.len:
    if code[i] in {'a'..'z', '_', '&'}:
      let a = i
      while i < code.len and (code[i] in {'a'..'z', '0'..'9', '_', '&'} or
                              (code[i] == '.' and i + 1 < code.len and code[i + 1] in {'a'..'z', '_'})):
        inc i
      result.add (code[a ..< i], a)
    else: inc i

const PascalRoutines = ["procedure", "function", "constructor", "destructor", "operator"]

func pascalSymbols*(lines: seq[string]): seq[Symbol] =
  ## the program, unit or library, its sections, its types (with their methods and properties), its procedures
  ## and functions
  var inBrace, inParen = false
  var section = ""                       # "interface", "implementation" ("": a program's file)
  var inTypes = false                    # in a type section: Name = … declares a type
  var containers = 0                     # open class, record, object or interface bodies
  var nested = 0                         # a record inside one of them (its own end)
  var routines = 0                       # routines whose body has not ended: a nested one is one deeper
  var blocks = 0                         # begin, try, case, asm … end open in a routine's body
  for ln, s in lines:
    let code = pascalCode(s, inBrace, inParen)
    let ws = pascalWords(code)
    if ws.len == 0: continue
    let first = ws[0][0]
    let base = (if section.len > 0: 1 else: 0)
    template add(nm, kd, dt: string, cl, dp: int) =
      result.add Symbol(name: nm, kind: kd, detail: dt, line: ln, col: cl, depth: dp)
    template orig(w: (string, int)): string = s[w[1] ..< w[1] + w[0].len]
    # inside a class (record …) body: its methods and properties, until its end
    if containers > 0:
      let d = base + routines + containers
      if first == "end":
        if nested > 0: dec nested
        else: dec containers
        continue
      if ws[^1][0] == "record": inc nested                   # (a field that is a record: its own end)
      var k = 0
      if first == "class" and ws.len > 1: k = 1              # (class procedure, class function)
      if k < ws.len and ws[k][0] in PascalRoutines and k + 1 < ws.len:
        add(orig(ws[k + 1]), "method", ws[k][0], ws[k + 1][1], d)
      elif first == "property" and ws.len > 1:
        add(orig(ws[1]), "field", "property", ws[1][1], d)
      continue
    # a routine's body: its blocks counted, until the end of its own begin
    if routines > 0 and (blocks > 0 or first == "begin"):
      for (w, _) in ws:
        if w in ["begin", "try", "case", "asm"]: inc blocks
        elif w == "end":
          dec blocks
          if blocks <= 0:
            blocks = 0
            dec routines
      inTypes = false
      continue
    case first
    of "program", "unit", "library", "package":
      if ws.len > 1 and section.len == 0 and routines == 0:
        add(orig(ws[1]), "module", first, ws[1][1], 0)
      continue
    of "interface", "implementation":
      if ws.len == 1:
        add(orig(ws[0]), "section", "", ws[0][1], 0)
        section = first
        inTypes = false
        continue
    of "type":
      inTypes = true
      if ws.len == 1: continue
    of "var", "const", "uses", "resourcestring", "threadvar", "label", "initialization", "finalization", "begin":
      inTypes = false
      continue
    else: discard
    # a routine's heading (a method's body: TFoo.Bar); in the interface, or forward or external, it has no body
    var k = 0
    if first == "class" and ws.len > 1: k = 1
    if k < ws.len and ws[k][0] in PascalRoutines and k + 1 < ws.len:
      let kind = ws[k][0]
      let w = ws[k + 1]
      let name = orig(w)
      let p = code.find('(', w[1])
      var detail = kind
      if p >= 0:
        let close = code.find(')', p)
        detail = kind & " " & (if close > p: s[p .. close] else: "(…)")
      add(name, (if '.' in name: "method" else: "function"), detail, w[1], base + routines)
      inTypes = false
      if section != "interface" and "forward" notin code and "external" notin code: inc routines
      continue
    # a type: Name = class(…) / record / object / interface / (an enumeration) / anything else
    if inTypes and ws.len >= 2:
      let eq = code.find('=')
      if eq > ws[0][1] and ws[1][1] > eq:
        var r = code[eq + 1 .. ^1].strip
        let name = orig(ws[0])
        for pre in ["packed ", "sealed ", "abstract "]:
          if r.startsWith(pre): r = r[pre.len .. ^1].strip
        let what = if r.startsWith("record"): "record" elif r.startsWith("object"): "object"
                   elif r.startsWith("interface") or r.startsWith("dispinterface"): "interface"
                   elif r.startsWith("class") and not r.startsWith("class of"): "class" else: ""
        if what.len > 0:
          add(name, (if what == "record": "struct" elif what == "interface": "interface" else: "class"), what,
              ws[0][1], base + routines)
          # (a forward declaration — class; — or one on a single line — class(Exception); — has no body below)
          if not r.endsWith(";"): inc containers
        elif r.startsWith("("):
          add(name, "enum", "enumeration", ws[0][1], base + routines)
        elif r.startsWith("procedure") or r.startsWith("function") or r.startsWith("reference"):
          add(name, "type", "procedural type", ws[0][1], base + routines)
        else:
          add(name, "type", s[s.find('=', ws[0][1]) + 1 .. ^1].strip.strip(chars = {';', ' '}), ws[0][1],
              base + routines)

# ── the tools ──

proc pascalHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let pascalServerSet = setting("server", "").strip
var pascalServer: seq[string]
if pascalServerSet == "off": discard
elif pascalServerSet.len > 0:
  if pascalHave(pascalServerSet): pascalServer = pascalServerSet.splitWhitespace()
  else: echo "pascal: the server " & pascalServerSet & " is not installed (plugins.pascal.server)"
else:
  for cmd in ["pasls", "pascal-language-server"]:
    if pascalHave(cmd):
      pascalServer = @[cmd]
      break
if pascalServer.len > 0:
  pascalServer[0] = expandTilde(pascalServer[0])
  languageServer("pascal", pascalServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("pascal") do (b: Buf) -> seq[Symbol]:
    pascalSymbols(b.lines)

let pascalFmtSet = setting("formatter", "").strip
if pascalFmtSet.len > 0 and pascalFmtSet != "off":
  if pascalHave(pascalFmtSet): formatter("pascal", pascalFmtSet)
  else: echo "pascal: the formatter " & pascalFmtSet & " is not installed (plugins.pascal.formatter)"
