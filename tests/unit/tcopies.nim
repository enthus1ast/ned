## Where ARC/ORC copies: the compiler's --expandArc output placed back in the source (src/ned/nim/arccopies).
## Run: nim r tests/unit/tcopies.nim (with nim on PATH)

import std/[os, osproc, strutils, unittest]
import ../../src/ned/nim/arccopies

const Src = """type Obj = object
  name: string
  tags: seq[string]

proc keep(s: sink seq[string]) = discard s.len

proc f(s: seq[int], o: Obj): int =
  var a = s
  var b = a
  echo b, a
  var names: seq[string]
  let n = o.name
  names.add n
  names.add o.name   # a copy of a field
  keep(names)
  echo names.len
  var o2 = o
  o2.name = "x"
  result = a.len + o2.tags.len

proc g(x: string): string =
  var y = x
  y.add "a"
  result = x & y

proc h(r: ref Obj) =
  let q = r
  echo q.name

proc moved(): seq[string] =
  var v = @["a"]
  var w = v            # its last use: moved, no copy
  result = w

proc lit(): string = "no copy"

import std/tables
type Wrap = object
  t: OrderedTable[string, seq[int]]
proc loops(w: ref Wrap, o: Obj): int =
  for k, v in pairs(w.t):
    result += k.len + v.len
  proc inner(): int = o.tags.len
  result += inner()
"""

proc expand(src: string, names: seq[string]): string =
  let dir = getTempDir() / "ned-tcopies-" & $getCurrentProcessId()
  createDir(dir)
  writeFile(dir / "m.nim", "{.push exportc.}\n" & src)
  var cmd = "nim c --compileOnly --hints:off --warnings:off --colors:off --nimcache:" & quoteShell(dir / "c")
  for n in names: cmd.add " --expandArc:" & n
  let (o, _) = execCmdEx(cmd & " " & quoteShell(dir / "m.nim"))
  removeDir(dir)
  o

proc routines(src: string): seq[ArcRoutine] =
  let ls = src.splitLines
  for i, l in ls:
    if l.startsWith("proc "):
      var e = i
      while e + 1 < ls.len and (ls[e + 1].len == 0 or ls[e + 1].startsWith(" ")): inc e
      let name = l[5 ..< l.find('(')]
      var ps: seq[string]
      let hdr = l[l.find('(') + 1 ..< l.find(')')]
      for part in hdr.split(','):
        let c = part.find(':')
        if c > 0 and "sink" notin part: ps.add part[0 ..< c].strip
      result.add ArcRoutine(name: name, line: i, endLine: e, params: ps)

suite "expandArc → the source":
  let lines = Src.splitLines
  let out0 = expand(Src, @["keep", "f", "g", "h", "moved", "lit", "loops"])
  let got = arcCopies(out0, lines, routines(Src))
  proc at(l: int, what: string): bool =
    for c in got:
      if c.line == l and lines[l][c.col ..< c.ecol] == what: return true
    checkpoint "copies: " & $got
    false

  test "an assignment that copies: var o2 = o":
    check at(16, "o")
  test "a parameter copied is borrowed: so marked":
    for c in got:
      if c.line == 16: check c.param
  test "a value given to a sink parameter it is still used after: add, keep":
    check at(12, "n")
    check at(13, "o.name")
    check at(14, "names")
  test "… with the call it goes to":
    for c in got:
      if c.line == 14: check c.callee == "keep" and c.kind == akSink
  test "a string kept and used again: var y = x":
    check at(21, "x")
  test "no copy where none is made (cursors, moves, refs, literals)":
    for c in got: check c.line notin [7, 8, 26, 31, 34]
    check got.len == 8

  test "what a for loop goes over, bound to an inlined iterator: the for line, not an earlier use":
    let o = "--expandArc: f\n`=copy_1`(:tmp_4, node.fields)\n-- end of expandArc ------------------------\n"
    let ls = @["proc f(node: JsonNode) =", "  if node.fields.len > 0:", "    for k, v in pairs(node.fields):"]
    let c = arcCopies(o, ls, [ArcRoutine(name: "f", line: 0, endLine: 2, params: @["node"])])
    check c.len == 1 and c[0].line == 2 and c[0].kind == akIterArg and ls[2][c[0].col ..< c[0].ecol] == "node.fields"
  test "… and each value it yields, a copy: the loop variables":
    check at(40, "k")
    check at(40, "v")
  test "a closure capturing a parameter: where the closure is made":
    check at(42, "inner")
    for c in got:
      if c.line == 42: check c.kind == akCapture and c.src == "o" and c.param

  test "the output parsed without the compiler":
    let o = "--expandArc: f\n\nvar y\n`=copy`(y, x_cursor)\nadd(names):\n  :tmpD = `=dup_1`(n[])\n  :tmpD\n" &
            "-- end of expandArc ------------------------\n"
    let ls = @["proc f(x: string) =", "  var y = x", "  names.add n"]
    let c = arcCopies(o, ls, [ArcRoutine(name: "f", line: 0, endLine: 2, params: @["x"])])
    check c.len == 2
    check c[0].line == 1 and c[0].col == 10 and c[0].param
    check c[1].line == 2 and c[1].callee == "add" and c[1].src == "n"
