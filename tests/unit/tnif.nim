# ned's NIF reader: the nodes and where they come from in the source, the outline, and pnak's pnak.nif lockfile

import std/[unittest, strutils]
import ../../src/ned/nim/nifread

suite "NIF":
  test "tags, atoms, definitions and line information":
    let ns = nifParse(@["(.nif27)", "(stmts@,1,app.nim", " (proc 4,2 :foo.0.app . . . (params) . . . (stmts)))"])
    var tags: seq[string]
    var defs: seq[string]
    for n in ns:
      if n.tag.len > 0: tags.add n.tag
      if n.isDef: defs.add n.atom
    check "proc" in tags and "params" in tags
    check defs == @["foo.0.app"]
    check nifSymName("foo.0.app") == "foo"

  test "the outline: routines at the top level":
    let o = nifOutline(nifParse(@["(stmts", " (proc :foo.0.m . . . (params) . . . (stmts))",
                                  " (type :Obj.0.m . . . (object . (fld :x.0.m . . int .)))", ")"]))
    var names: seq[string]
    for it in o: names.add it.name
    check "foo" in names and "Obj" in names

suite "pnak.nif":
  const Lock = @["(.nif27)", "(stmts", " (requires \"https://github.com/nim-lang/checksums.git\" \"0123abc\")",
                 " (requires \"https://github.com/a/b/\" \"main\") (requires \"git@github.com:c/d.git\"",
                 "   \"fedcba9876543210fedcba9876543210fedcba98\")", " (requires \"bare\"))"]

  test "every entry, with its URL, commit and place":
    let rs = pnakRequires(Lock)
    check rs.len == 4
    check rs[0].name == "checksums" and rs[0].commit == "0123abc" and rs[0].line == 2
    check rs[0].col == Lock[2].find("\"https")
    check rs[1].name == "b" and rs[1].commit == "main"
    check rs[2].name == "d" and rs[2].tline == 3 and rs[2].cline == 4 and rs[2].commit.len == 40
    check rs[3].name == "bare" and rs[3].commit == "" and rs[3].cline == -1

  test "commits and names":
    check pnakIsCommit("0123abc") and pnakIsCommit("FEDCBA9876543210fedcba9876543210fedcba98")
    check not pnakIsCommit("main") and not pnakIsCommit("v1.2.3") and not pnakIsCommit("abc12")
    check pnakName("https://github.com/x/jsony.git#abc") == "jsony"
    check pnakName("git@github.com:x/y.git") == "y"
    check pnakName("plain") == "plain"

  test "NIF's escapes in a string":
    let rs = pnakRequires(@["(stmts (requires \"https://h/a\\20b\" \"1234567\"))"])
    check rs.len == 1 and rs[0].url == "https://h/a b"

suite "Nim 2.4's NIF (nim nif)":
  # (as Nim 2.4.0 writes `let s1 = show(3)` and a proc a macro made: a token's place comes after the token before it)
  const Nif24 = """(.nif27)
(.vendor "nim2")
(stmts@,1,app.nim
 (import strutils.0.strcl1rjq1)@,3,app.nim
 (proc@5 :answer.0.app . . .@1
  (params)
  (i -1)
  (pragmas).
  (stmts
   (result@1 :result.1 . .
    (i -1).)@1
   (asgn result.1 42)
   (ret result.1)))@4,F,app.nim
 (let :s1.0.app .
  (pragmas)string.0.sysvq0asl@9
  (call show.0.utierkx2a@1 3)))"""

  test "each token's place is the one written after the token before it":
    let ns = nifParse(Nif24.splitLines, before = true)
    var procAt, letAt, threeAt = (-1, -1)
    for n in ns:
      if n.tag == "proc": procAt = (n.sline, n.scol)
      if n.isDef and n.atom == "s1.0.app": letAt = (n.sline, n.scol)
      if n.atom == "3": threeAt = (n.sline, n.scol)
    check procAt == (2, 0)          # (line 3, from 0)
    check letAt == (14, 4)          # (`let s1 = show(3)` on line 15: s1 at column 4)
    check threeAt == (14, 14)       # (the 3 in show(3))

  test "what a macro made, written back as Nim":
    let ns = nifParse(Nif24.splitLines, before = true)
    let top = nifTopStatements(ns)
    check top.len == 3
    check nifPrint(ns, top[1], false) == "proc answer(): int =\n  result = 42"
    check nifPrint(ns, top[2], false) == "let s1: string = show(3)"

  test "a form the printer does not write: nothing (the compiler is asked instead)":
    let ns = nifParse(@["(stmts (emit \"x\"))"], before = true)
    check nifPrint(ns, nifTopStatements(ns)[0], false) == ""
