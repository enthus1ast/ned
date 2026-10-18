## nedastcheck — do two Nim texts parse to the same syntax tree? Nim's own parser (the compiler's sources) reads
## both; comments, layout and the way a block is written (one line or several) are not differences. ned's
## formatter is checked with it (nim.format.verify, nedfmt --verify, tests/format/parsecheck.sh).
##
## This is not part of ned's build: ned writes it out and compiles it once against the compiler sources it finds
## (choosenim, a source build, or `nimble install compiler`):
##   nim c -d:release --path:NIMROOT -o:nedastcheck nedastcheck.nim
##
##   nedastcheck A.nim B.nim      the two files
##   nedastcheck -                stdin: "LEN_A LEN_B\n", then the two texts
## Prints "same" (exit 0), "different A_LINE B_LINE: what" (exit 1), or "unreadable: why" (exit 2: the first
## text does not parse — nothing to compare).

import std/[os, strutils, algorithm]
import compiler/[ast, llstream, parser, idents, options, pathutils, lineinfos]
from compiler/renderer import renderTree

proc parseText(text, name: string, errors: var int): PNode =
  let conf = newConfigRef()
  conf.errorMax = high(int)
  conf.writelnHook = proc(s: string) = discard
  conf.structuredErrorHook = proc(config: ConfigRef; info: TLineInfo; msg: string; severity: Severity) {.gcsafe.} =
    discard
  var p: Parser
  result = newNode(nkStmtList)
  try:
    openParser(p, AbsoluteFile(name), llStreamOpen(text), newIdentCache(), conf)
    while true:
      let s = p.parseTopLevelStmt()
      if s.kind == nkEmpty: break
      result.add s
    closeParser(p)
  except CatchableError:
    inc errors
  errors += conf.errorCounter

const Lists = {nkStmtList, nkStmtListExpr, nkFormalParams, nkRecList}

proc kept(n: PNode): seq[PNode] =
  ## a node's parts that count: comments do not (nor the empty statements a `;` leaves in an expression list)
  if n.kind in {nkCharLit .. nkUInt64Lit, nkFloatLit .. nkFloat128Lit, nkStrLit .. nkTripleStrLit, nkIdent, nkSym,
                nkEmpty, nkNilLit, nkType}:
    return @[]
  for s in n.sons:
    if s.kind == nkCommentStmt: continue
    if n.kind == nkStmtListExpr and s.kind == nkEmpty: continue
    result.add s

proc moduleNames(n: PNode, into: var seq[string]) =
  ## the modules one `import` names, `std/[a, b]` as std/a and std/b
  proc path(x: PNode): string =
    case x.kind
    of nkIdent: x.ident.s
    of nkStrLit .. nkTripleStrLit: x.strVal
    of nkInfix:
      if x.len == 3: path(x[1]) & "/" & path(x[2]) else: renderTree(x)
    of nkPrefix:
      if x.len == 2: path(x[0]) & path(x[1]) else: renderTree(x)
    of nkAccQuoted:
      var s = ""
      for c in x: s.add path(c)
      s
    else: renderTree(x)
  for m in n.sons:
    if m.kind == nkInfix and m.len == 3 and m[2].kind == nkBracket:
      let base = path(m[1]) & "/"
      for k in m[2]: into.add base & path(k)
    elif m.kind != nkCommentStmt: into.add path(m)

proc grouped(parts: seq[PNode]): seq[PNode] =
  ## a statement list with each run of plain `import` statements as one (nim.format.imports sorts and merges them):
  ## the run becomes a node of its own whose modules are compared as a set
  var i = 0
  while i < parts.len:
    if parts[i].kind == nkImportStmt:
      var names: seq[string]
      let first = parts[i]
      while i < parts.len and parts[i].kind == nkImportStmt:
        moduleNames(parts[i], names)
        inc i
      names.sort()
      let g = newNodeI(nkImportStmt, first.info)
      for s in names: g.add newStrNode(nkStrLit, s)
      result.add g
    else:
      result.add parts[i]
      inc i

proc similar(a, b: TNodeKind): bool =
  a == b or (a in {nkElse, nkElseExpr} and b in {nkElse, nkElseExpr}) or
    (a in {nkElifBranch, nkElifExpr} and b in {nkElifBranch, nkElifExpr})

func cCode(s: string): string =
  ## C in an emit, as far as its layout goes: no whitespace, no comment markers (nim.formatEmitC lays it out)
  for c in s:
    if c notin Whitespace: result.add c
  result = result.replace("//", "").replace("/*", "").replace("*/", "")

proc same(a, b: PNode, da, db: var PNode, inEmit = false): bool =
  ## a and b alike (else da, db: where they part)
  if not similar(a.kind, b.kind):
    # one written as a block of one statement, the other on the line: the same
    let ka = kept(a)
    let kb = kept(b)
    if a.kind in Lists and ka.len == 1: return same(ka[0], b, da, db, inEmit)
    if b.kind in Lists and kb.len == 1: return same(a, kb[0], da, db, inEmit)
    if (a.kind in Lists and ka.len == 0 and b.kind == nkEmpty) or (b.kind in Lists and kb.len == 0 and a.kind == nkEmpty):
      return true
    # `- 1` and `-1`: the same number (the space the formatter took out made it a literal)
    for (p, l) in [(a, b), (b, a)]:
      if p.kind == nkPrefix and p.len == 2 and p[0].kind == nkIdent and p[0].ident.s == "-" and p[1].kind == l.kind:
        if l.kind in {nkCharLit .. nkUInt64Lit} and p[1].intVal == -l.intVal: return true
        if l.kind in {nkFloatLit .. nkFloat128Lit} and p[1].floatVal == -l.floatVal: return true
    # `static: x` on a line of a value, and `static:` over lines: a call to static, or the statement
    for (c, st) in [(a, b), (b, a)]:
      if c.kind == nkCall and c.len == 2 and c[0].kind == nkIdent and c[0].ident.s == "static" and
         st.kind == nkStaticStmt and st.len == 1:
        return same(c[1], st[0], da, db, inEmit)
    da = a
    db = b
    return false
  let eq = case a.kind
    of nkCharLit .. nkUInt64Lit: a.intVal == b.intVal
    of nkFloatLit .. nkFloat128Lit: a.floatVal == b.floatVal or (a.floatVal != a.floatVal and b.floatVal != b.floatVal)
    of nkStrLit .. nkTripleStrLit: a.strVal == b.strVal or (inEmit and cCode(a.strVal) == cCode(b.strVal))
    of nkIdent: a.ident.s == b.ident.s
    of nkEmpty, nkNilLit, nkType, nkSym: true
    else:
      var ka = kept(a)
      var kb = kept(b)
      if a.kind == nkStmtList:
        ka = grouped(ka)
        kb = grouped(kb)
      let emit = inEmit or (a.kind == nkExprColonExpr and a.len == 2 and a[0].kind == nkIdent and
                            a[0].ident.s == "emit")
      if ka.len != kb.len:
        # where they part: the first part that differs, else the one only one of them has
        for i in 0 ..< min(ka.len, kb.len):
          var x, y: PNode
          if not same(ka[i], kb[i], x, y, emit):
            da = x
            db = y
            return false
        da = if ka.len > kb.len: ka[kb.len] else: a
        db = if kb.len > ka.len: kb[ka.len] else: b
        false
      else:
        for i in 0 ..< ka.len:
          if not same(ka[i], kb[i], da, db, emit): return false
        true
  if not eq and da == nil:
    da = a
    db = b
  eq

proc main() =
  var a, b, na, nb: string
  let args = commandLineParams()
  if args == @["-"]:
    let all = readAll(stdin)
    let nl = all.find('\n')
    if nl < 0: quit "unreadable: no header", 2
    let h = all[0 ..< nl].splitWhitespace()
    if h.len != 2: quit "unreadable: bad header", 2
    let la = parseInt(h[0])
    let lb = parseInt(h[1])
    if nl + 1 + la + lb > all.len: quit "unreadable: short input", 2
    a = all[nl + 1 ..< nl + 1 + la]
    b = all[nl + 1 + la ..< nl + 1 + la + lb]
    na = "a.nim"
    nb = "b.nim"
  elif args.len == 2:
    na = args[0]
    nb = args[1]
    a = readFile(na)
    b = readFile(nb)
  else:
    quit "usage: nedastcheck A.nim B.nim  |  nedastcheck -   (stdin: \"LEN_A LEN_B\\n\" then the texts)", 2
  var ea, eb = 0
  let ta = parseText(a, na, ea)
  if ea > 0:
    echo "unreadable: the first text does not parse"
    quit 2
  let tb = parseText(b, nb, eb)
  if eb > 0:
    echo "different 0 0: the second text does not parse"
    quit 1
  var da, db: PNode
  if same(ta, tb, da, db):
    echo "same"
    quit 0
  var what = renderTree(da).replace('\n', ' ')
  if what.len > 120: what = what[0 ..< 120] & "…"
  echo "different ", da.info.line, " ", db.info.line, ": ", what
  quit 1

main()
