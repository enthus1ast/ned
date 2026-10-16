## ned's C engine as a program, for the comparison with clangd (ccompare.py): queries in, answers out, one JSON
## object a line. Build: nim c -d:release -o:ned-cengine tests/engine/cdriver.nim
##   {"file": "/abs/a.c", "line": 10, "col": 4, "kind": "def"}   → {"defs": [["/abs/b.h", 12]], "ms": 0.2}
##   {"file": …, "kind": "comp"}                                 → {"items": ["x", "y"], "type": "struct p *", "ms": …}
##   {"dirs": ["/usr/include", …]}                               → the include folders (once, first)
##   {"predef": {"__x86_64__": "1", …}}                          → the C compiler's predefined macros
##   {"root": "/abs/project"}                                    → where the project's .c files are
import std/[json, os, strutils, monotimes, times, tables]
import ../../src/ned/c/cindex

var dirFiles: Table[string, seq[string]]      # a folder's .c files (listed once)
var root = ""                                 # the project's folder (as the editor's): its .c files

for raw in stdin.lines:
  if raw.strip.len == 0: continue
  var q: JsonNode
  try: q = parseJson(raw)
  except CatchableError:
    echo "{}"
    continue
  if q.hasKey("predef"):
    for k, v in q["predef"]: cxPredef[k] = v.getStr
    cxPredefSet = true
    echo "{}"
    stdout.flushFile
    continue
  if q.hasKey("mem"):
    # this process's resident memory (kB), for the comparison's report
    var kb = 0
    for l in lines("/proc/self/status"):
      if l.startsWith("VmRSS:"): kb = parseInt(l.splitWhitespace()[1])
    echo $(%*{"rss_kb": kb})
    stdout.flushFile
    continue
  if q.hasKey("root"):
    root = q["root"].getStr
    echo "{}"
    stdout.flushFile
    continue
  if q.hasKey("dirs"):
    cxDirs.setLen(0)
    for d in q["dirs"]: cxDirs.add d.getStr
    echo "{}"
    stdout.flushFile
    continue
  let path = q["file"].getStr
  let t0 = getMonoTime()
  let f = cxLoad(path, readFile(path), "drv:" & path)
  var res = newJObject()
  let line = q["line"].getInt
  let col = q["col"].getInt
  case q["kind"].getStr
  of "def":
    var defs = newJArray()
    var ts = cxTargets(f, line, col, jump = true)
    # as the editor does: a body (or a global's definition) in the other .c files of the folder
    let dir = if root.len > 0: root else: parentDir(path)
    if dir notin dirFiles:
      dirFiles[dir] = @[]
      for p in walkDirRec(dir):
        if p.endsWith(".c") and dirFiles[dir].len < 5000: dirFiles[dir].add p
    var cs: seq[string]
    for p in dirFiles[dir]:
      if p != path: cs.add p
    if ts.len == 0:
      let (a, e) = cxWordAt(f.lines[line], col)
      if a < e and f.lines[line][a ..< e] notin CxKeywords:
        for kind in [cxFunc, cxVar, cxStruct]:
          let (h, k) = cxBodyIn(cs, f.lines[line][a ..< e], kind)
          if h != nil:
            ts.add (h, h.syms[k])
            break
    elif ts[0][1].kind in {cxFunc, cxStruct, cxUnion, cxVar} and not ts[0][1].isDef and
       not (ts[^1][1].isDef and ts[^1][0] == f and ts[^1][1].line == line) and
       (root.len == 0 or ts[0][0].path.startsWith(root & "/")):
      let (h, k) = cxBodyIn(cs, ts[0][1].name, ts[0][1].kind)
      if h != nil: ts.insert((h, h.syms[k]), 0)
    for (g, s) in ts: defs.add %*[g.path, s.line]
    res["defs"] = defs
  of "comp":
    let (items, _, typ) = cxComplete(f, line, col)
    var arr = newJArray()
    for it in items: arr.add %it.label
    res["items"] = arr
    res["type"] = %typ
  of "hover":
    res["hover"] = %cxHover(f, line, col)
  else: discard
  res["ms"] = %((getMonoTime() - t0).inMicroseconds.float / 1000.0)
  echo $res
  stdout.flushFile
