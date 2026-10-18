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
