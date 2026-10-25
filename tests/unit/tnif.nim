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
