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
