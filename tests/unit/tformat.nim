## The built-in formatters on their own: Nim (nph's style), JSON, CSS, Markdown tables — and the Nim formatter
## run twice over ned's own source changes nothing the second time. Run: nim r tests/unit/tformat.nim

import std/[os, strutils, unittest]
import ../../src/ned/format/formatters

proc nimFmt(s: string): string =
  var err = ""
  result = fFormat(s, err)
  checkpoint err
  check err.len == 0

suite "Nim":
  test "spaces around operators and after colons and commas, blocks opened":
    check nimFmt("proc g(a:int):int=\n  a+1\nlet x=[1,2,3]\nif x.len>2 and true: echo \"big\"\n") ==
          "proc g(a: int): int =\n  a + 1\n\nlet x = [1, 2, 3]\nif x.len > 2 and true:\n  echo \"big\"\n"

  test "formatted code stays as it is":
    let ok = "proc g(a: int): int =\n  a + 1\n"
    check nimFmt(ok) == ok

  test "ned's own source: a second run changes nothing":
    let root = currentSourcePath().parentDir.parentDir.parentDir / "src"
    var files = 0
    for p in walkDirRec(root):
      if not p.endsWith(".nim"): continue
      var err = ""
      let once = fFormat(readFile(p), err)
      if err.len > 0: continue                # (a file the formatter leaves alone, as it says)
      var err2 = ""
      let twice = fFormat(once, err2)
      checkpoint p
      check err2.len == 0
      check twice == once
      inc files
    check files > 100

suite "Nim: nph's layouts (6.8)":
  test "a lambda among the arguments: one argument a line, its body under it":
    check nimFmt("let f2 = filter(colors, proc(x: string): bool = x.len < 6)\n") ==
          "let f2 = filter(\n  colors,\n  proc(x: string): bool =\n    x.len < 6,\n)\n"

  test "after a command in a lambda's body the comma goes on a line of its own":
    check nimFmt("apply([0, 1], proc(item: int) = message.addInt item)\n") ==
          "apply(\n  [0, 1],\n  proc(item: int) =\n    message.addInt item\n  ,\n)\n"

  test "an if-expression argument with calls in it: as a block":
    check nimFmt("result = codePageToName(if uiApp: getACP() else: getGetConsoleCP())\n") ==
          "result = codePageToName(\n  if uiApp:\n    getACP()\n  else:\n    getGetConsoleCP()\n)\n"

  test "a command whose last argument is a lambda with a block: one argument a line":
    check nimFmt("registerCallback c, \"name\", proc(a: VmArgs) =\n  setResult(a, 1)\n") ==
          "registerCallback c,\n  \"name\",\n  proc(a: VmArgs) =\n    setResult(a, 1)\n"

  test "a keyword statement ends at a comma itself; a command does not":
    check nimFmt("let a = map(xs, proc(c: string): string = return c.replace(\"CC\", \"Link\"))\n") ==
          "let a = map(\n  xs,\n  proc(c: string): string =\n    return c.replace(\"CC\", \"Link\"),\n)\n"

  test "`f():` with a block loses its empty parentheses; a condition keeps them":
    check nimFmt("s.withLock():\n  echo 1\n") == "s.withLock:\n  echo 1\n"
    check nimFmt("if ready():\n  echo 1\n") == "if ready():\n  echo 1\n"

  test "a prefix operator stays on its bracket; a typeclass's | stays an operator":
    check nimFmt("x = % (a in b)\n") == "x = %(a in b)\n"
    check nimFmt("let j = %* {\"a\": 1}\n") == "let j = %*{\"a\": 1}\n"
    check nimFmt("let arr = %[0,1]\n") == "let arr = %[0, 1]\n"
    check nimFmt("template r*[T: distinct|(range and not enum)](x: T): string = $x\n") ==
          "template r*[T: distinct | (range and not enum)](x: T): string =\n  $x\n"
    check nimFmt("n = f(flags*{a, b})\n") == "n = f(flags * {a, b})\n"

  test "a routine's name and its parameters, do and its parameters: no space":
    check nimFmt("proc `&` (a, b: int): int = a\n") == "proc `&`(a, b: int): int =\n  a\n"
    check nimFmt("f.addCallback do ():\n  echo 1\n") == "f.addCallback do():\n  echo 1\n"

  test "a long call indexed by a tiny one: the call is opened, not the [0]":
    let src = "proc f() =\n  regs[ra].node.strVal = opGorge(regs[rb].node.strVal, regs[rc].node.strVal, " &
              "regs[rd].node.strVal, c.debug[pc], c.config)[0]\n"
    check nimFmt(src) == "proc f() =\n  regs[ra].node.strVal = opGorge(\n    regs[rb].node.strVal,\n" &
          "    regs[rc].node.strVal,\n    regs[rd].node.strVal,\n    c.debug[pc],\n    c.config,\n  )[0]\n"

  test "a lambda on the line after `=` goes up":
    check nimFmt("f.callback =\n  proc() =\n    echo 1\n") == "f.callback = proc() =\n  echo 1\n"

  test "a call's block given on its line goes under it":
    check nimFmt("doAssertRaises(IOError): discard s.readInt8()\n") ==
          "doAssertRaises(IOError):\n  discard s.readInt8()\n"

  test "`quote do:` as a statement's value loses its do — not when another call takes it":
    check nimFmt("result = quote do:\n  echo 1\n") == "result = quote:\n  echo 1\n"
    check nimFmt("result.add quote do:\n  echo 1\n") == "result.add quote do:\n  echo 1\n"

  test "a try value and a non-plain return-if as blocks; a plain if-else stays inline":
    check nimFmt("result = try: getAppl() except OSError: \"\"\n") ==
          "result =\n  try:\n    getAppl()\n  except OSError:\n    \"\"\n"
    check nimFmt("return if b: toUpper(s) else: toLower(s)\n") ==
          "return\n  if b:\n    toUpper(s)\n  else:\n    toLower(s)\n"
    check nimFmt("return if h < m: nil else: x\n") == "return if h < m: nil else: x\n"
    check nimFmt("if a:\n  x\nelse:\n  y\n") == "if a: x else: y\n"

  test "a format string and its long list: broken after %, the list wrapped in place when it does not fit":
    let src = "proc f() =\n  result = getConfigVar(d.conf, \"doc.section\") % [\"sectionid\", $ord(kind), " &
              "\"sectionTitle\", title, \"sectionTitleID\", $(ord(kind) + 50)]\n"
    check nimFmt(src) == "proc f() =\n  result =\n    getConfigVar(d.conf, \"doc.section\") % [\n      \"sectionid\",\n" &
          "      $ord(kind),\n      \"sectionTitle\",\n      title,\n      \"sectionTitleID\",\n      $(ord(kind) + 50),\n    ]\n"

  test "a condition ending in a call too long by itself: the call wrapped, the comparison after it":
    check nimFmt("if fillConsoleOutputAttribute(h, scrbuf.wAttributes, wt, scrbuf.dwCursorPosition, " &
                 "addr(numwrote)) == 0:\n  discard\n") ==
          "if fillConsoleOutputAttribute(\n  h, scrbuf.wAttributes, wt, scrbuf.dwCursorPosition, addr(numwrote)\n) == 0:\n" &
          "  discard\n"

  test "a product broken across lines keeps its spaces (not an export marker)":
    let r = nimFmt("proc f() =\n  result.mom4 = a.mom4 + b.mom4 + delta4*a.n.float*b.n.float * toFloat(a.n*a.n - " &
                   "a.n*b.n + b.n*b.n) / (n*n*n)\n")
    check "delta4 * a.n.float * b.n.float" in r
    check "delta4*" notin r

suite "Nim layout settings (nim.format.*)":
  setup:
    FmtMax = 88
    FmtWidth = 88
  teardown:
    FmtParams = fwFit
    FmtArgs = fwFit
    FmtColl = fwFit
    FmtImports = 0
    FmtAlign = false
    FmtReflow = false
    FmtBlank = 1
    FmtMax = 88

  test "always: one parameter, argument and element per line":
    FmtParams = fwAlways
    FmtArgs = fwAlways
    FmtColl = fwAlways
    check nimFmt("proc f(a: int, b: string): int =\n  g(a, b)\nlet xs = @[1, 2]\n") ==
      "proc f(\n    a: int,\n    b: string,\n): int =\n  g(\n    a,\n    b,\n  )\n\nlet xs = @[\n  1,\n  2,\n]\n"
    check nimFmt("if f(a, b):\n  discard\nlet t = Table[string, int]()\n") ==
          "if f(a, b):\n  discard\nlet t = Table[string, int]()\n"     # (not in conditions, not generics)

  test "fit (nph) joins what fits, onePerLine breaks only long lines":
    let src = "let y = call(1,\n  2, 3)\n"
    check nimFmt(src) == "let y = call(1, 2, 3)\n"
    FmtColl = fwOnePerLine
    FmtMax = 30
    check nimFmt("let zz = [100000, 200000, 300000]\nlet a = [1, 2]\n") ==
          "let zz = [\n  100000,\n  200000,\n  300000,\n]\nlet a = [1, 2]\n"

  test "keep: the line breaks as written":
    FmtParams = fwKeep
    FmtArgs = fwKeep
    let src = "proc g(alpha: int,\n       beta: int): int = alpha\nlet y = call(1,\n  2, 3)\nlet z = call(1, 2)\n"
    check nimFmt(src) == "proc g(alpha: int,\n    beta: int): int =\n  alpha\n\nlet y = call(1,\n  2, 3)\n" &
                         "let z = call(1, 2)\n"

  test "imports sorted, and merged":
    FmtImports = 1
    check nimFmt("import strutils, std/os, ./local, pkg/foo\ninclude b, a\n") ==
          "import std/os, pkg/foo, strutils, ./local\ninclude b, a\n"
    FmtImports = 2
    check nimFmt("import std/strutils\nimport std/[tables, os]\nimport ./x\n\nimport zeta\n") ==
          "import std/[os, strutils, tables], ./x\n\nimport zeta\n"
    check nimFmt("import strutils except split\nimport os\n") == "import strutils except split\nimport os\n"

  test "fields and section values lined up":
    FmtAlign = true
    check nimFmt("type Foo = object\n  a: int\n  longName*: string\n\nconst\n  x = 1\n  longer = 2\n") ==
          "type Foo = object\n  a:         int\n  longName*: string\n\nconst\n  x      = 1\n  longer = 2\n"
    FmtAlign = false
    check nimFmt("const\n  x      = 1\n  longer = 2\n") == "const\n  x = 1\n  longer = 2\n"

  test "long doc comments re-wrapped, lists kept":
    FmtReflow = true
    FmtMax = 40
    check nimFmt("## one two three four five six seven eight nine ten eleven\n## - a list item that is long enough to cross\n") ==
          "## one two three four five six seven\n## eight nine ten eleven\n## - a list item that is long enough to cross\n"

  test "blank lines: up to maxBlankLines":
    FmtBlank = 2
    check nimFmt("let a = 1\n\n\n\nlet b = 2\n") == "let a = 1\n\n\nlet b = 2\n"
    FmtBlank = 1
    check nimFmt("let a = 1\n\n\n\nlet b = 2\n") == "let a = 1\n\nlet b = 2\n"

suite "C (built-in, when clang-format is not there)":
  test "indentation by braces, spaces after commas and keywords, around assignments":
    let (c, err) = fmtC("int main( void )\n{\n    int x=1 ,y = 2;\n  if(x==1)\n  y=-x;\n  switch(y){\n    case 1:\n" &
                        "x++;\n    break;\n  }\n  return x+y;\n}\n")
    check err.len == 0
    check c == "int main(void)\n{\n  int x = 1, y = 2;\n  if (x == 1)\n    y = -x;\n  switch (y) {\n  case 1:\n" &
               "    x++;\n    break;\n  }\n  return x + y;\n}\n"

  test "strings, comments and macros as they are; a second run changes nothing":
    let src = "#define  A(x) \\\n   ((x)+1)\nchar *s = \"a  ,b\";   /* keep\n      this */\nint f(int a,\n      int b);\n"
    let (c, err) = fmtC(src)
    check err.len == 0
    check "\"a  ,b\"" in c
    check "#define  A(x) \\\n   ((x)+1)" in c
    check "int f(int a,\n      int b);" in c
    check fmtC(c)[0] == c

  test "unbalanced brackets: left alone":
    check fmtC("int f() {\n")[1].len > 0

suite "JSON, CSS, Markdown":
  test "JSON: one value per line, the text of each kept":
    let (j, err) = fmtJson("{\"a\":1,\"b\":[1,2,{\"c\":true}],\"d\":\"x\"}")
    check err.len == 0
    check j.startsWith("{\n  \"a\": 1,\n  \"b\": [\n")
    check "\"d\": \"x\"\n}" in j

  test "CSS: one declaration per line":
    let (c, err) = fmtCss("a{color:red;margin:0}\n")
    check err.len == 0
    check c == "a {\n  color: red;\n  margin: 0;\n}\n"

  test "Markdown: tables aligned":
    let (m, err) = fmtMarkdown("| a | bb |\n|---|---|\n| ccc | d |\n")
    check err.len == 0
    check m == "| a   | bb  |\n| --- | --- |\n| ccc | d   |\n"

suite "YAML and TOML":
  test "YAML: one indentation width, a sequence at its key's column kept, text blocks moved as one":
    let (r, err) = fmtYaml("a:\n    b:   1\n    c:\n    - x\n    - y\n    d: |\n        line one\n          two\n\n\n\ne: 2   \n")
    check err == ""
    check r == "a:\n  b: 1\n  c:\n  - x\n  - y\n  d: |\n    line one\n      two\n\ne: 2\n"
  test "YAML: formatted stays as it is; tabs and indentation indicators are left alone":
    let ok = "a:\n  b: 1\n  c:\n    - x\n"
    check fmtYaml(ok)[0] == ok
    check fmtYaml("a:\n\tb: 1\n")[0] == "a:\n\tb: 1\n"
    check fmtYaml("a: |2\n   x\n")[0] == "a: |2\n   x\n"
  test "TOML: spaces around =, headers, arrays, blank lines; strings untouched":
    let (r, err) = fmtToml("title=\"a  =  b\"\n[ server ]\nports=[1,2 ,3]\n\n\n[[ items ]]\nname = 'x'   # note\n" &
                           "text = \"\"\"\nkeep   this = as is\n\"\"\"\n")
    check err == ""
    check r == "title = \"a  =  b\"\n\n[server]\nports = [1, 2, 3]\n\n[[items]]\nname = 'x' # note\n" &
               "text = \"\"\"\nkeep   this = as is\n\"\"\"\n"
  test "TOML: an array over several lines keeps its layout":
    let src = "deps = [\n  \"a\",\n  \"b\",\n]\n"
    check fmtToml(src)[0] == src
