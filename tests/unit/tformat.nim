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

suite "Nim: nph's layouts (6.9)":
  test "an argument that is an operator expression: broken after the operator, the operand on the next line":
    check nimFmt("proc f() =\n" &
                 "  localError(c.config, n.info, \"type expected, but got symbol '$1' of kind '$2'\" % [s.name.s, s.kind.toHumanStr])\n") ==
          "proc f() =\n  localError(\n    c.config,\n    n.info,\n" &
          "    \"type expected, but got symbol '$1' of kind '$2'\" % [s.name.s, s.kind.toHumanStr],\n  )\n"

  test "a value too long after `=`: on the next line, its operator lines not deeper":
    check nimFmt("proc f() =\n" &
                 "  let stmtShouldExecute = n.kind in {nkProcDef, nkFuncDef, nkMethodDef, nkConverterDef, nkVarSection, nkLetSection} or nfExecuteOnReload in n.flags\n") ==
          "proc f() =\n  let stmtShouldExecute =\n    n.kind in\n" &
          "    {nkProcDef, nkFuncDef, nkMethodDef, nkConverterDef, nkVarSection, nkLetSection} or\n" &
          "    nfExecuteOnReload in n.flags\n"

  test "a command's first argument stays on its line, the others go to the next":
    check nimFmt("assert node.kind == JObject, \": pairs() can not iterate a JsonNode of kind \" & $node.kind & \" (got it)\"\n") ==
          "assert node.kind == JObject,\n" &
          "  \": pairs() can not iterate a JsonNode of kind \" & $node.kind & \" (got it)\"\n"

  test "the space after an operator does not count: its operand may end at column 89":
    check nimFmt("proc f() =\n  if true:\n" &
                 "    raiseAssert \"empty command line given but\" & \" real command line is not accessible\"\n") ==
          "proc f() =\n  if true:\n" &
          "    raiseAssert \"empty command line given but\" & \" real command line is not accessible\"\n"

  test "a chain of calls too long: each `.call(…)` on a line of its own":
    check nimFmt("proc f() =\n" &
                 "  let external = AbsoluteFile(d.destFile).relativeTo(d.conf.outDir, '/').changeFileExt(HtmlExt).string\n") ==
          "proc f() =\n  let external = AbsoluteFile(d.destFile)\n    .relativeTo(d.conf.outDir, '/')\n" &
          "    .changeFileExt(HtmlExt).string\n"

  test "cast[T](f(…)): the call's arguments wrapped inside it":
    check nimFmt("proc f() =\n" &
                 "  result = cast[ptr SharedArray[T]](reallocShared0(sa, oldsize * sizeof(T), sizeof(T) * nsize, more))\n") ==
          "proc f() =\n  result = cast[ptr SharedArray[T]](reallocShared0(\n" &
          "    sa, oldsize * sizeof(T), sizeof(T) * nsize, more\n  ))\n"

  test "a condition: its continuation lines 4 deeper":
    check nimFmt("proc f() =\n" &
                 "  if expectedElementType != nil and typeAllowed(expectedElementType, skLet, c) == nil and moreChecks(x):\n" &
                 "    discard\n") ==
          "proc f() =\n" &
          "  if expectedElementType != nil and typeAllowed(expectedElementType, skLet, c) == nil and\n" &
          "      moreChecks(x):\n    discard\n"

  test "a pragma holding a long string: `{.` ⏎ the pragma ⏎ `.}`":
    check nimFmt("proc len(x: JsObject): int =\n  {.emit: \"\"\"\n  `result` = `x`.length;\n\"\"\".}\n") ==
          "proc len(x: JsObject): int =\n  {.\n    emit: \"\"\"\n  `result` = `x`.length;\n\"\"\"\n  .}\n"

  test "`var a, b: T` too long: the type on the next line":
    check nimFmt("proc f() =\n" &
                 "  var sysIdle, sysKernel, sysUser, procCreation, procExit, procKernel, procUser: FILETIME\n") ==
          "proc f() =\n  var sysIdle, sysKernel, sysUser, procCreation, procExit, procKernel, procUser:\n" &
          "    FILETIME\n"

  test "a routine's pragmas after wrapped parameters: the ` =` does not count":
    check nimFmt("proc add*[A, B](t: OrderedTableRef[A, B], key: A, val: sink B) {.deprecated: \"Deprecated since v1.4; it was more confusing than useful, use `[]=`\".} =\n" &
                 "  discard\n") ==
          "proc add*[A, B](\n    t: OrderedTableRef[A, B], key: A, val: sink B\n" &
          ") {.deprecated: \"Deprecated since v1.4; it was more confusing than useful, use `[]=`\".} =\n" &
          "  discard\n"

  test "a comment's trailing spaces stay":
    check nimFmt("proc f() = discard # trailing space   \n") ==
          "proc f() =\n  discard # trailing space   \n"

  test "`name: if a: x else: y` with values that are not plain: under the name, as a block":
    check nimFmt("let c = CgenObj(optionsStack: if module.initProc != nil: module.initProc.optionsStack else: @[], other: 1)\n") ==
          "let c = CgenObj(\n  optionsStack:\n    if module.initProc != nil:\n" &
          "      module.initProc.optionsStack\n    else:\n      @[],\n  other: 1,\n)\n"

  test "`(T)x` is a command (`(T) x`); inside parentheses operator lines line up":
    check nimFmt("pResult = (((uint64)x) shl 32) + (0xffffffff'u64 and ((z[5].uint64 shl 24) + (z[6].uint64 shl 16) + (z[7].uint64 shl 8)))\n") ==
          "pResult =\n  (((uint64) x) shl 32) + (\n    0xffffffff'u64 and\n" &
          "    ((z[5].uint64 shl 24) + (z[6].uint64 shl 16) + (z[7].uint64 shl 8))\n  )\n"

  test "`x =` with its value on the next line: one line again when it fits":
    check nimFmt("proc f() =\n  let decRefProc =\n    if isCyclic: \"nimDecRefIsLastCyclicDyn\"\n" &
                 "    else: \"nimDecRefIsLast\"\n  var count =\n" &
                 "    p.selector.selectInto(adjustTimeout(p, timeout, nextTimer), keys)\n") ==
          "proc f() =\n" &
          "  let decRefProc = if isCyclic: \"nimDecRefIsLastCyclicDyn\" else: \"nimDecRefIsLast\"\n" &
          "  var count = p.selector.selectInto(adjustTimeout(p, timeout, nextTimer), keys)\n"

  test "`name: stmt` (a call given a block): the statement under it":
    check nimFmt("proc f() =\n  runnableExamples: assert 1 == 1\n" &
                 "  runnableExamples: static: doAssert editDistanceAscii(\"Kitten\", \"Bitten\") == 1\n") ==
          "proc f() =\n  runnableExamples:\n    assert 1 == 1\n  runnableExamples:\n    static:\n" &
          "      doAssert editDistanceAscii(\"Kitten\", \"Bitten\") == 1\n"

  test "`Name = ptr object` with fields: `ptr object` under `Name =`":
    check nimFmt("type\n  SharedListNode[A] = ptr object\n    next: SharedListNode[A]\n    dataLen: int\n") ==
          "type SharedListNode[A] =\n  ptr object\n    next: SharedListNode[A]\n    dataLen: int\n"

  test "a field whose proc type does not fit after its name: the type on the next line":
    check nimFmt("type\n  T = object\n" &
                 "    semConstExpr*: proc (c: PContext, n: PNode; expectedType: PType = nil): PNode {.nimcall.}\n") ==
          "type T = object\n  semConstExpr*:\n" &
          "    proc(c: PContext, n: PNode, expectedType: PType = nil): PNode {.nimcall.}\n"

  test "imports packed: the comma counts in the width":
    check nimFmt("import modulegraphs, lineinfos, idents, ast, renderer, semdata, sighashes, lowerings, options, types, msgs\n") ==
          "import\n  modulegraphs, lineinfos, idents, ast, renderer, semdata, sighashes, lowerings,\n" &
          "  options, types, msgs\n"

  test "`bind` names packed, 4 deeper":
    check nimFmt("template t() =\n" &
                 "  bind shouldRun, checkpoints, formatters, ensureInitialized, testEnded, exceptionTypeName, setProgramResult\n") ==
          "template t() =\n  bind shouldRun, checkpoints, formatters, ensureInitialized, testEnded,\n" &
          "    exceptionTypeName, setProgramResult\n"

  test "a long `tuple[…]` type: under `X =`, its fields between the brackets":
    check nimFmt("type\n" &
                 "  TInfoOS* = tuple[name: string, parDir: string, dllFrmt: string, altDirSep: string, objExt: string]\n") ==
          "type TInfoOS* =\n  tuple[\n" &
          "    name: string, parDir: string, dllFrmt: string, altDirSep: string, objExt: string\n  ]\n"

  test "a named argument `(if a: x else: y)`: on the next line when it fits there":
    check nimFmt("proc f() =\n" &
                 "  blockLeaveActions(p, howManyTrys = 0, howManyExcepts = (if p.nestedTryStmts.len > 0 and p.nestedTryStmts[^1].inExcept: 1 else: 0))\n") ==
          "proc f() =\n  blockLeaveActions(\n    p,\n    howManyTrys = 0,\n    howManyExcepts =\n" &
          "      (if p.nestedTryStmts.len > 0 and p.nestedTryStmts[^1].inExcept: 1 else: 0),\n  )\n"

  test "`of` values packed: the comma counts in the width, the `:` does not":
    check nimFmt("proc f() =\n  case n.kind\n" &
                 "  of nkCallKinds, nkDotExpr, nkPar, nkTupleConstr, nkObjConstr, nkBracket, nkCurly, nkHiddenDeref, nkDerefExpr:\n" &
                 "    discard\n  else: discard\n") ==
          "proc f() =\n  case n.kind\n" &
          "  of nkCallKinds, nkDotExpr, nkPar, nkTupleConstr, nkObjConstr, nkBracket, nkCurly,\n" &
          "      nkHiddenDeref, nkDerefExpr:\n    discard\n  else:\n    discard\n"

  test "a routine header holding a long string: its parameters one a line, `{.` ⏎ its pragmas ⏎ `.}`":
    check nimFmt("proc sysctl(name: ptr cint, namelen: cuint, oldp: pointer, oldplen: ptr csize_t,\n" &
                 "            newp: pointer, newplen: csize_t): cint\n" &
                 "     {.importc: \"sysctl\",header: \"\"\"#include <sys/types.h>\n" &
                 "                                    #include <sys/sysctl.h>\"\"\".}\n") ==
          "proc sysctl(\n  name: ptr cint,\n  namelen: cuint,\n  oldp: pointer,\n  oldplen: ptr csize_t,\n" &
          "  newp: pointer,\n  newplen: csize_t,\n): cint {.\n  importc: \"sysctl\",\n" &
          "  header: \"\"\"#include <sys/types.h>\n" &
          "                                    #include <sys/sysctl.h>\"\"\"\n.}\n"

  test "`cast[T](f(…))` as a statement: the call's arguments wrapped inside it":
    check nimFmt("proc fetchAdd*[T: SomeInteger](location: var Atomic[T]; value: T; order: MemoryOrder = moSequentiallyConsistent): T {.inline.} =\n" &
                 "  cast[T](atomic_fetch_add_explicit(addr(location.value), cast[nonAtomicType(T)](value), order))\n") ==
          "proc fetchAdd*[T: SomeInteger](\n" &
          "    location: var Atomic[T], value: T, order: MemoryOrder = moSequentiallyConsistent\n" &
          "): T {.inline.} =\n  cast[T](atomic_fetch_add_explicit(\n" &
          "    addr(location.value), cast[nonAtomicType(T)](value), order\n  ))\n"

  test "after a long string over several lines nothing fits: `\"\"\" %` ⏎ the list":
    check nimFmt("proc f() =\n" &
                 "  r.res = \"\"\"if ($1.length < $2) { for (var i = $4.length ; i < $5 ; ++i) $4.push($3); }\n" &
                 "             else { $4.length = $5; }\"\"\" % [a, b, createVar(p, t, false), tmp, tmp2]\n") ==
          "proc f() =\n  r.res =\n" &
          "    \"\"\"if ($1.length < $2) { for (var i = $4.length ; i < $5 ; ++i) $4.push($3); }\n" &
          "             else { $4.length = $5; }\"\"\" %\n    [a, b, createVar(p, t, false), tmp, tmp2]\n"

  test "`x = proc(…) =` too long: the lambda's parameters as a routine's (4 deeper)":
    check nimFmt("proc f() =\n" &
                 "  d.onTestSnippet = proc (d: var RstGenerator; filename, cmd: string; status: int; content: string) {.gcsafe.} =\n" &
                 "    discard\n") ==
          "proc f() =\n  d.onTestSnippet = proc(\n" &
          "      d: var RstGenerator, filename, cmd: string, status: int, content: string\n" &
          "  ) {.gcsafe.} =\n    discard\n"

  test "a value `case` with plain branches stays inline; the last branch's comment goes under it":
    check nimFmt("proc f(k: int): int =\n  result = case k\n    of skMacro: -3\n    of skTemplate: -2\n" &
                 "    else: 0  # including skProc which have higher priority\n") ==
          "proc f(k: int): int =\n  result =\n    case k\n    of skMacro: -3\n    of skTemplate: -2\n" &
          "    else: 0\n    # including skProc which have higher priority\n"

  test "an inline if-expression value keeps its form; its trailing comment goes under it when too long":
    check nimFmt("proc f() =\n  if true:\n    let addrLen = when not useWinVersion: posix.INET6_ADDRSTRLEN.int\n" &
                 "                  else: 46 # it's actually 46 in both cases\n") ==
          "proc f() =\n  if true:\n" &
          "    let addrLen = when not useWinVersion: posix.INET6_ADDRSTRLEN.int else: 46\n" &
          "      # it's actually 46 in both cases\n"

  test "a long `from x import …`: the names packed on the lines under it":
    check nimFmt("from std/math import sqrt, ln, log10, log2, exp, round, arccos, arcsin, arctan, arctan2, cos, cosh, hypot, sinh, sin, tan, tanh, pow\n") ==
          "from std/math import\n" &
          "  sqrt, ln, log10, log2, exp, round, arccos, arcsin, arctan, arctan2, cos, cosh, hypot,\n" &
          "  sinh, sin, tan, tanh, pow\n"

  test "an identifier in backticks: its parts a space apart (`| div |`), not `=destroy`":
    check nimFmt("proc `|div|`*(a, b: BiggestInt): BiggestInt = a\nproc `=destroy`(x: var T) = discard\n") ==
          "proc `| div |`*(a, b: BiggestInt): BiggestInt =\n  a\n\nproc `=destroy`(x: var T) =\n  discard\n"

  test "an object branch `of x: discard` stays on its line":
    check nimFmt("type\n  Connection = object\n    case kind: VarIndexKind\n    of isEmptyRoot: discard\n" &
                 "    of dependsOn: parent: int\n") ==
          "type Connection = object\n  case kind: VarIndexKind\n  of isEmptyRoot: discard\n" &
          "  of dependsOn: parent: int\n"

  test "`of a:` ⏎ a plain value: joined when every branch is plain":
    check nimFmt("proc f(m: FileMode): int =\n  result = case m\n    of fmRead, fmReadWriteExisting:\n" &
                 "      OPEN_EXISTING\n    of fmAppend:\n      OPEN_ALWAYS\n    else: 0\n") ==
          "proc f(m: FileMode): int =\n  result =\n    case m\n" &
          "    of fmRead, fmReadWriteExisting: OPEN_EXISTING\n    of fmAppend: OPEN_ALWAYS\n    else: 0\n"

  test "a case's branches stay apart when the longest does not fit inline (nph counts from after `case `)":
    check nimFmt("proc getSlotKind(t: PType): TSlotKind =\n  case t.skipTypes(abstractRange-{tyTypeDesc}).kind\n" &
                 "  of tyBool, tyChar, tyEnum, tyOrdinal, tyInt..tyInt64, tyUInt..tyUInt64: slotTempInt\n" &
                 "  else: slotTempComplex\n") ==
          "proc getSlotKind(t: PType): TSlotKind =\n  case t.skipTypes(abstractRange - {tyTypeDesc}).kind\n" &
          "  of tyBool, tyChar, tyEnum, tyOrdinal, tyInt .. tyInt64, tyUInt .. tyUInt64:\n    slotTempInt\n" &
          "  else:\n    slotTempComplex\n"

  test "an `of` branch's trailing comment: at the `of`'s level before the next branch, under a command body":
    check nimFmt("proc f(t: PType): int =\n  case t.kind\n  of tySet: result = etyObject # map a set to a table\n" &
                 "  of tyString, tySequence: result = etySeq\n  of Lit: assert false # Can't happen\n") ==
          "proc f(t: PType): int =\n  case t.kind\n  of tySet:\n    result = etyObject\n" &
          "  # map a set to a table\n  of tyString, tySequence:\n    result = etySeq\n  of Lit:\n" &
          "    assert false\n    # Can't happen\n"

  test "an `if` body's trailing comment stays on its line":
    check nimFmt("proc f() =\n  if a: result = 3 # stays with its value\n") ==
          "proc f() =\n  if a:\n    result = 3 # stays with its value\n"

  test "a list element's trailing comment too long for its line: under it, 2 deeper (and it stays there)":
    check nimFmt("const winEncodings = [\n" &
                 "  (870, \"IBM870\"),         # IBM EBCDIC Multilingual/ROECE (Latin 2); IBM EBCDIC Multilingual Latin 2\n" &
                 "  (875, \"cp875\"),          # IBM EBCDIC Greek Modern\n  ]\n") ==
          "const winEncodings = [\n  (870, \"IBM870\"),\n" &
          "    # IBM EBCDIC Multilingual/ROECE (Latin 2); IBM EBCDIC Multilingual Latin 2\n" &
          "  (875, \"cp875\"), # IBM EBCDIC Greek Modern\n]\n"
    check nimFmt("const winEncodings = [\n  (870, \"IBM870\"),\n" &
                 "    # IBM EBCDIC Multilingual/ROECE (Latin 2); IBM EBCDIC Multilingual Latin 2\n" &
                 "  (875, \"cp875\"), # IBM EBCDIC Greek Modern\n]\n") ==
          "const winEncodings = [\n  (870, \"IBM870\"),\n" &
          "    # IBM EBCDIC Multilingual/ROECE (Latin 2); IBM EBCDIC Multilingual Latin 2\n" &
          "  (875, \"cp875\"), # IBM EBCDIC Greek Modern\n]\n"

  test "a statement wrapped over lines: its trailing comment at the end of the last line when it fits":
    check nimFmt("proc f() =\n" &
                 "  linefmt(p, cpsStmts, \"if ($1 < 0 || $1 >= $2Len_0){ #raiseIndexError2($1,$2Len_0-1); \", [rdCharLoc(b), rdLoc(a)]) # BUGFIX\n") ==
          "proc f() =\n  linefmt(\n    p,\n    cpsStmts,\n" &
          "    \"if ($1 < 0 || $1 >= $2Len_0){ #raiseIndexError2($1,$2Len_0-1); \",\n" &
          "    [rdCharLoc(b), rdLoc(a)],\n  ) # BUGFIX\n"

  test "a comment after a line of several enum values: the last value's comment; after a single value it stays":
    check nimFmt("type\n  G = enum\n    p, q,\n\n    # comment about r\n    r\n  H = enum\n    m,\n" &
                 "    # comment about n\n    n\n") ==
          "type\n  G = enum\n    p\n    q # comment about r\n    r\n\n  H = enum\n    m\n" &
          "    # comment about n\n    n\n"

  test "a comment under `if a:` written deeper than the body: the header's trailing comment":
    check nimFmt("proc f() =\n  if a:\n     # deeper comment\n    echo 1\n  if b:\n    # same level comment\n" &
                 "    echo 2\n") ==
          "proc f() =\n  if a: # deeper comment\n    echo 1\n  if b:\n    # same level comment\n" &
          "    echo 2\n"

  test "`X = object # note` stays; it goes under when the body starts with comment lines":
    check nimFmt("type\n  Token* = object                # a Nim token\n    tokType*: TokType\n" &
                 "  Scope = object # we do scope-based memory management.\n" &
                 "    # a scope is comparable to an nkStmtListExpr like\n    vars: seq[PSym]\n") ==
          "type\n  Token* = object # a Nim token\n    tokType*: TokType\n\n  Scope = object\n" &
          "    # we do scope-based memory management.\n" &
          "    # a scope is comparable to an nkStmtListExpr like\n    vars: seq[PSym]\n"

suite "Nim: nph's layouts (6.10)":
  # (each expected text is nph's own output for the input)
  test "a lambda with its body under it among a call's arguments: one argument a line, `name: proc(…) =`":
    check nimFmt("proc main() =\n  ol.data = CompletionData(fd: socket, cb:\n    proc (fd: AsyncFD, bytesCount: DWORD) =\n      if not retFuture.finished:\n        foo()\n      bar()\n  )\n") ==
          "proc main() =\n  ol.data = CompletionData(\n    fd: socket,\n    cb: proc(fd: AsyncFD, bytesCount: DWORD) =\n      if not retFuture.finished:\n        foo()\n      bar(),\n  )\n"

  test "the comma after a lambda's body: on its own line after a lone `if` or a command, else after the body":
    check nimFmt("proc main() =\n  x = f(a, proc (x: int) =\n    if a:\n      x = 1\n  )\n  x = f(a, proc (x: int) =\n    echo x\n  , b)\n  x = f(a, proc (x: int) =\n    if a:\n      x = 1\n    else:\n      x = 2\n  )\n") ==
          "proc main() =\n  x = f(\n    a,\n    proc(x: int) =\n      if a:\n        x = 1\n    ,\n  )\n  x = f(\n    a,\n    proc(x: int) =\n      echo x\n    ,\n    b,\n  )\n  x = f(\n    a,\n    proc(x: int) =\n      if a:\n        x = 1\n      else:\n        x = 2,\n  )\n"

  test "an if/elif/else written over lines as a call's only argument: each branch's value under it":
    check nimFmt("proc p() =\n  result.add(\n    if dt.hour == 0: \"12\"\n    elif dt.hour > 12: $(dt.hour - 12)\n    else: $dt.hour\n  )\n") ==
          "proc p() =\n  result.add(\n    if dt.hour == 0:\n      \"12\"\n    elif dt.hour > 12:\n      $(dt.hour - 12)\n    else:\n      $dt.hour\n  )\n"

  test "an object's one comment line goes on its line, an object's last field takes the comment line after it":
    check nimFmt("type\n  L = object\n    ## A singly linked list.\n    head: int\n  O = object\n    a: int\n    # xxx charMode, etc\n\n  P = int\n") ==
          "type\n  L = object ## A singly linked list.\n    head: int\n\n  O = object\n    a: int # xxx charMode, etc\n\n  P = int\n"

  test "a one-line routine's single doc line: on the header's line (after a `return`'s value)":
    check nimFmt("func kind*(p: Peg): PegKind = p.kind\n  ## Returns the kind.\n\nproc getFd*(s: Socket): int = return s.fd\n  ## Returns the descriptor\n") ==
          "func kind*(p: Peg): PegKind = ## Returns the kind.\n  p.kind\n\nproc getFd*(s: Socket): int =\n  return s.fd ## Returns the descriptor\n"

  test "an enum value's comment on the line under it, deeper: the value's own":
    check nimFmt("type\n  E = enum\n    eA,\n      # deeper comment\n    eB\n") ==
          "type E = enum\n  eA # deeper comment\n  eB\n"

  test "a value with comments after its operators: under `x =`, a line break after each comment":
    check nimFmt("proc p() =\n  let y = aaaa and\n    # c2\n    bbbb\n  result = aaaa and # c3\n           bbbb and # c4\n           cccc\n  let ignoreSecond = name != nil and name.s == \"[]\" and n.len > 1 and\n    # generic type instantiation:\n    ((n[1].typ != nil and n[1].typ.kind == tyTypeDesc) or\n      # generic proc instantiation:\n      (n[1].kind == nkSym and n[1].sym.isGenericRoutineStrict))\n") ==
          "proc p() =\n  let y =\n    aaaa and\n    # c2\n    bbbb\n  result =\n    aaaa and # c3\n    bbbb and # c4\n    cccc\n  let ignoreSecond =\n    name != nil and name.s == \"[]\" and n.len > 1 and\n    # generic type instantiation:\n    (\n      (n[1].typ != nil and n[1].typ.kind == tyTypeDesc) or\n      # generic proc instantiation:\n      (n[1].kind == nkSym and n[1].sym.isGenericRoutineStrict)\n    )\n"

  test "a condition with comments after its operators: as nph lines its operands up":
    check nimFmt("proc p() =\n  if aaaa and # c5\n     bbbb:\n    discard\n  if aaaa and\n      # c6\n      bbbb:\n    discard\n  if isSymChoice(n[1]) or\n      # generics usually leave field names as symchoices, but not types\n      (n[1].kind == nkSym and n[1].sym.kind == skType):\n    discard\n") ==
          "proc p() =\n  if aaaa and # c5\n  bbbb:\n    discard\n  if aaaa and\n      # c6\n      bbbb:\n    discard\n  if isSymChoice(n[1]) or\n  # generics usually leave field names as symchoices, but not types\n  (n[1].kind == nkSym and n[1].sym.kind == skType):\n    discard\n"

  test "an if-expression value with a comment in it: one branch a line":
    check nimFmt("proc p() =\n  let sepLen = if sep.len == 0: 1 # prevents infinite loop\n    else: sep.len\n") ==
          "proc p() =\n  let sepLen =\n    if sep.len == 0:\n      1 # prevents infinite loop\n    else:\n      sep.len\n"

  test "statements in parentheses too long for the line: `(` ⏎ one a line ⏎ `)`":
    check nimFmt("proc p() =\n  if expectedType != nil and (let expected = expectedType.skipTypes(abstractRange - {tyDistinct}); expected.kind == tySet):\n    discard\n") ==
          "proc p() =\n  if expectedType != nil and (\n    let expected = expectedType.skipTypes(abstractRange - {tyDistinct})\n    expected.kind == tySet\n  ):\n    discard\n"

  test "a list with a comment after its `]`: one element a line, the comment after the `]`":
    check nimFmt("const\n  LineContinuationTokens = [\n    \"let\", \"var\",  # section\n    \"object\",\n    # from ./layouter.oprSet\n    \"div\", \"mod\",\n  ]  # must be all `nimIdentNormalized`-ed\n") ==
          "const LineContinuationTokens = [\n  \"let\",\n  \"var\", # section\n  \"object\",\n  # from ./layouter.oprSet\n  \"div\",\n  \"mod\",\n] # must be all `nimIdentNormalized`-ed\n"

suite "Nim: code whose meaning the layout must keep (6.10)":
  # (6.9 changed what Nim's parser reads in these — found by running Nim's parser over Nim's own tests)
  test "`x.not` ending a line is a call, not an operator: the next statement stays apart":
    let src = "proc p() =\n  check (a <=\n    b).not\n\n  block: # next\n    discard 1\n"
    check nimFmt(src) == "proc p() =\n  check (a <= b).not\n\n  block: # next\n    discard 1\n"

  test "a `using` parameter after one with a type or default: formatted (`;` → `,` there), not left alone":
    let pre = "using\n  c: int\n  y: float\n  z: int\n\n"
    check nimFmt(pre & "proc d(c = 1; y; z: int) = discard\n") == pre & "proc d(c = 1, y; z: int) =\n  discard\n"
    check nimFmt(pre & "proc g(c; y = 2; z) = discard\n") == pre & "proc g(c; y = 2, z) =\n  discard\n"

  test "comment lines inside one parenthesized expression: still one expression (no trailing comma: no tuple)":
    var err = ""
    let r = fFormat("let x = (a or\n  b or   # c1\n  # c2\n  d)\n", err)
    check err == ""
    check "d," notin r and "# c2" in r

  test "a keyword after a dot is a name: `posix.raise(x)` gets no space":
    check nimFmt("proc p() =\n  discard posix.raise(signal)\n") == "proc p() =\n  discard posix.raise(signal)\n"

  test "a `;` after a block inside a statement is that block's: not split there":
    let src = "proc p() =\n  say f, if false: f else: f += 1; f\n"
    check nimFmt(src) == src

  test "the commas after a lambda's command are the command's: the call is not split there":
    let src = "proc p() =\n  o.cb.add(proc() = echo o.s, \" \", i)\n"
    check nimFmt(src) == src

  test "statements in parentheses a line apart keep their lines (nph's layout of a long one)":
    let src = "proc p() =\n  if x and (\n    let a = f(1)\n    a > 0\n  ):\n    discard\n"
    check nimFmt(src) == src

  test "a template's pattern `{` ⏎ statements ⏎ `}` keeps its lines":
    let src = "template optWrite{\n  write(f, x)\n  write(f, y)\n}(x, y: string, f: File) =\n  write(f, x & y)\n"
    check nimFmt(src) == src

  test "a section member's block is code, not more members (`x = f:` ⏎ `a:` ⏎ `b:`)":
    let src = "let\n  parse = peg.eventParser:\n    pkNonTerminal:\n      enter:\n        pStack.add p\n      leave:\n        pStack.setLen 0\n"
    check nimFmt(src) == "let parse = peg.eventParser:\n  pkNonTerminal:\n    enter:\n      pStack.add p\n    leave:\n      pStack.setLen 0\n"

  test "a number with a fraction in backticks is one part, like nph":
    check nimFmt("const\n  `v0.99.99` = \"0.99.99\"\n") == "const `v0 . 99.99` = \"0.99.99\"\n"

  test "the `*` that exports a name is never a place to break a line":
    # (6.10 broke `type Constructible *` ⏎ `[T] …` — not Nim; a header too long for nph's layout stays as written)
    check nimFmt("type Constructible*[T] {.importcpp: \"Genode::Constructible\", " &
                 "header: \"<util/reconstructible.h>\", byref, pure.} = object\n") ==
      "type Constructible*[T] {.\n  importcpp: \"Genode::Constructible\", header: \"<util/reconstructible.h>\", " &
      "byref, pure\n.} = object\n"
    let src = "proc abcdef*[T: not (tuple | object | string | cstring | char | ref | ptr | array | seq | distinct)]() =\n" &
              "  discard\n"
    check nimFmt(src) == src

  test "one parameter a line, the last without a type: a `;` after it, like nph (`b,` ⏎ `)` is not Nim)":
    check nimFmt("template batchImplxxxxxxxxxxxxxxxxxxxxxx(result: var int, dest: var openArray[byte], " &
                 "getRandomImplxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx) =\n  discard\n") ==
      "template batchImplxxxxxxxxxxxxxxxxxxxxxx(\n    result: var int,\n    dest: var openArray[byte],\n" &
      "    getRandomImplxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx;\n) =\n  discard\n"

  test "Unicode operators are operators: `⊙=` one, `a⊞++4⊙3` an operation":
    check nimFmt("proc `⊙=`(x: var int, y: int) = x *= y\nx ⊙= a⊞++4⊙3\n") ==
      "proc `⊙=`(x: var int, y: int) =\n  x *= y\n\nx ⊙= a ⊞++ 4 ⊙ 3\n"

  test "a `#[ … ]#` inside a line does not end it, and what follows it stays as close as written":
    check nimFmt("hel#[!]#lo()\nproc#[!]#someProc*() =\n  discard\n#[!]#someProc()\n") ==
      "hel #[!]#lo()\nproc #[!]#someProc*() =\n  discard\n\n#[!]#someProc()\n"

  test "statements in parentheses a line apart (no `;`) are never joined: the check refuses that":
    let src = "block: (\n  discard\n  echo \"2\"\n)\n"
    var err = ""
    let r = fFormat(src, err)
    check "(discard echo" notin r
    check r == src or "\n" in r[r.find("discard") .. r.find("echo")]

suite "Nim 3 (Nimony) code (6.11.2)":
  # (over the 1684 files of Nimony — its library, its tests and its compiler — the formatter leaves 2 alone)
  test "a keyword as a routine's name (`func addr*[T](x: T)`): a name, not the operator":
    check nimFmt("func addr*[T](x: T): ptr T {.magic: \"Addr\".}\n") == "func addr*[T](x: T): ptr T {.magic: \"Addr\".}\n"

  test "a parameter with a pragma of its own (`r {.register: \"rdi\".}: Words`): `;` → `,` as for any other":
    check nimFmt("proc add2(r {.register: \"rdi\".}: Words; a {.register: \"rsi\".}: Words) {.assembler.} =\n  discard\n") ==
      "proc add2(r {.register: \"rdi\".}: Words, a {.register: \"rsi\".}: Words) {.assembler.} =\n  discard\n"

  test "a `;` after the last parameter (`(q: var Queue;)`): formatted, not left alone":
    var err = ""
    discard fFormat("proc f*(q: var Queue;): int =\n  1\n", err)
    check err == ""

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

  test "keep: a line break stays where it was written, or goes where Nim allows one":
    FmtParams = fwKeep
    FmtArgs = fwKeep
    FmtColl = fwKeep
    # (asyncnet's bindAddr: 6.10 moved the break after `{.` to after the name's `*` — `proc bindAddr *` ⏎ `(…)`)
    check nimFmt("proc bindAddr*(socket: AsyncSocket, port = Port(0), address = \"\") {.\n" &
                 "  tags: [ReadIOEffect].} =\n  discard\n") ==
      "proc bindAddr*(socket: AsyncSocket, port = Port(0), address = \"\") {.\n    tags: [ReadIOEffect]\n.} =\n" &
      "  discard\n"
    check nimFmt("proc declaredInScope2*(x: untyped): bool {.magic: \"DefinedInScope\", noSideEffect, compileTime.}\n") ==
      "proc declaredInScope2*(x: untyped): bool {.\n  magic: \"DefinedInScope\", noSideEffect, compileTime\n.}\n"
    # (the parameters on one line, the return type over several: its breaks kept)
    let src = "iterator caasTestsRunner*(filter = \"\", verbose = false): tuple[test,\n    output: string, " &
              "status: bool,\n    mode: TRunMode] =\n  discard\n"
    check nimFmt(src) == src

  test "always: `;` after a last parameter without a type; generic parameters and a statement's commas left":
    FmtParams = fwAlways
    FmtArgs = fwAlways
    FmtColl = fwAlways
    check nimFmt("template t(a: int, b) =\n  b\n") == "template t(\n    a: int,\n    b;\n) =\n  b\n"
    check nimFmt("type\n  array*[I, T] {.magic: \"Array\".}\n") == "type array*[I, T] {.magic: \"Array\".}\n"
    check nimFmt("let a2 = collect: (for k,v in a: (k,v))\n") == "let a2 = collect: (for k, v in a: (k, v))\n"

  test "a doc comment after an argument stays on that line (Nim reads it there), however long":
    FmtMax = 60
    check nimFmt("idPacket(ZoneQuery, 'Q',\n  tuple[playerCount: uint16], ##i should include a time here or something\n" &
                 "  tuple[pad: char = '\\0'])\n") ==
      "idPacket(\n  ZoneQuery,\n  'Q',\n  tuple[playerCount: uint16], ##i should include a time here or something\n" &
      "  tuple[pad: char = '\\0'],\n)\n"

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

  test "long # comments re-wrapped (reflowComments), prose only — code, banners, TODOs and directives as they are":
    FmtReflow = false
    FmtReflowPlain = true
    FmtMax = 40
    let src = "# one two three four five six seven eight nine ten eleven\n# twelve\nlet a = 1\n"
    let want = "# one two three four five six seven\n# eight nine ten eleven twelve\nlet a = 1\n"
    check nimFmt(src) == want
    check nimFmt(want) == want                                   # (a second run changes nothing)
    # commented-out code, a banner, a TODO, a directive: left as they are, however long
    for keep in ["# let total = compute(alpha, beta, gamma, delta)\n",
                 "# echo \"a long line of output that goes on\", x\n",
                 "# TODO: a long thing to do some day, when there is time\n",
                 "# ned: ignore[unused-import] because the reason is long\n",
                 "# foo(bar) is called here with a long explanation after\n"]:
      check nimFmt(keep & "let a = 1\n") == keep & "let a = 1\n"
    # a banner longer than the line: its rule cut to fit
    check nimFmt("# ── section " & "─".repeat(36) & "\nlet a = 1\n") == "# ── section " & "─".repeat(27) & "\nlet a = 1\n"
    check nimFmt("# short ──────\n") == "# short ──────\n"
    # a ## doc comment is not touched by this one
    let doc = "## one two three four five six seven eight nine ten eleven\n"
    check nimFmt(doc) == doc
    # indented: the width counts the indentation; characters, not bytes
    check nimFmt("proc p() =\n  # aaa · bbb · ccc · ddd · eee · fff · ggg · hhh\n  discard\n") ==
          "proc p() =\n  # aaa · bbb · ccc · ddd · eee · fff ·\n  # ggg · hhh\n  discard\n"
    FmtReflowPlain = false
    check nimFmt(src) == src

  test "doc comments: a line that starts with inline code or emphasis is prose too; the width in characters":
    FmtReflow = true
    FmtMax = 40
    check nimFmt("## run `ned --lint --fix` and then see what it changed\n## `x` is used here too\n") ==
          "## run `ned --lint --fix` and then see\n## what it changed `x` is used here too\n"
    check nimFmt("## *emphasis* then words that make it too long a line\n") ==
          "## *emphasis* then words that make it\n## too long a line\n"
    # a list, an RST directive: as they are
    let lst = "## * one item of a list that is long enough to wrap it\n## .. code-block:: nim\n"
    check nimFmt(lst) == lst
    FmtReflow = false

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
