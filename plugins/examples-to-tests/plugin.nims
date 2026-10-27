## examples-to-tests — a routine's runnableExamples turned into a test file under tests/, to run with nimble test
##
##   Examples to tests: this routine     the runnableExamples of the routine the cursor is in — or the module's,
##                                       with the cursor on them — written into tests/t<module>.nim, each in a
##                                       block of its own named after the routine, the file importing the module;
##                                       the test file opens, saved. Made again, a routine's blocks take the place
##                                       of the ones before; the others stay
##   Examples to tests: the whole file   every routine's runnableExamples, and the module's, at once
##   settings                            plugins.examples-to-tests.folder — where the tests go, from the project's
##                                       folder (the one with the .nimble file): "tests" · .style — "block" (plain
##                                       blocks: doAssert, as runnableExamples are) or "unittest" (a test of
##                                       std/unittest for each)
##
## The examples' own imports go at the top of the test file (an import cannot be in a block). An example given
## flags — runnableExamples("-d:ssl") — says so in a comment: run the test with them. nimble test runs the files
## of tests/ whose names start with t. Writing the test file needs nothing more: it is saved as you would save it.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("folder", "tests", "Examples to tests: the folder the test files go in, from the project's folder")
settingDef("style", "block", "Examples to tests: \"block\" — each example a plain block (doAssert), or " &
           "\"unittest\" — a test of std/unittest for each")

const RoutineWords = ["proc", "func", "method", "iterator", "template", "macro", "converter"]

type
  Routine* = object
    name*: string
    start*, stop*: int          # its lines: from its header up to (not including) stop
    indent*: int
  Example* = object
    owner*: string              # the routine's name ("module": the module's own)
    line*: int                  # its runnableExamples line
    flags*: string              # runnableExamples("-d:ssl") → -d:ssl
    code*: seq[string]          # its lines, the block's indentation taken off

func indentOf(s: string): int =
  while result < s.len and s[result] in {' ', '\t'}: inc result

func routines*(lines: seq[string]): seq[Routine] =
  ## the routines and the lines each one covers (its header, its body)
  for i, s in lines:
    let t = s.strip
    var kw = ""
    for w in RoutineWords:
      if t.startsWith(w & " ") or t.startsWith(w & "`"): kw = w
    if kw.len == 0: continue
    var rest = t[kw.len .. ^1].strip
    var name = ""
    if rest.startsWith("`"):
      let e = rest.find('`', 1)
      if e > 0: name = rest[1 ..< e]
    else:
      var e = 0
      while e < rest.len and rest[e] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}: inc e
      name = rest[0 ..< e]
    if name.len == 0: continue
    let ind = indentOf(s)
    var stop = i + 1
    while stop < lines.len:
      let l = lines[stop]
      if l.strip.len > 0 and indentOf(l) <= ind and not l.strip.startsWith("#"): break
      inc stop
    # (blank lines at its end are not its own)
    while stop - 1 > i and lines[stop - 1].strip.len == 0: dec stop
    result.add Routine(name: name, start: i, stop: stop, indent: ind)

func examples*(lines: seq[string]): seq[Example] =
  ## every runnableExamples block, with the routine it is in (the innermost one)
  let rs = routines(lines)
  for i, s in lines:
    let t = s.strip
    if not t.startsWith("runnableExamples"): continue
    var rest = t["runnableExamples".len .. ^1].strip
    var flags = ""
    if rest.startsWith("("):
      let e = rest.rfind(')')
      if e < 0: continue
      flags = rest[1 ..< e].strip.strip(chars = {'"'})
      rest = rest[e + 1 .. ^1].strip
    if not rest.startsWith(":"): continue
    let ind = indentOf(s)
    var code: seq[string]
    let inline = rest[1 .. ^1].strip
    if inline.len > 0: code.add inline
    else:
      var j = i + 1
      var body = -1
      while j < lines.len:
        let l = lines[j]
        if l.strip.len > 0:
          if indentOf(l) <= ind: break
          if body < 0: body = indentOf(l)
        code.add l
        inc j
      while code.len > 0 and code[^1].strip.len == 0: code.setLen(code.len - 1)
      for c in code.mitems:
        c = if c.strip.len == 0: "" else: c[min(body, indentOf(c)) .. ^1]
    var owner = "module"
    var best = -1
    for r in rs:
      if r.start < i and i < r.stop and r.indent < ind and r.indent > best:
        owner = r.name
        best = r.indent
    result.add Example(owner: owner, line: i, flags: flags, code: code)

func ownerAt*(lines: seq[string], line: int): string =
  ## the routine the line is in (the innermost); "module" on the module's own runnableExamples; "" none
  var best = -1
  for r in routines(lines):
    if r.start <= line and line < r.stop and r.indent > best:
      result = r.name
      best = r.indent
  if result.len == 0:
    for e in examples(lines):
      if e.owner == "module" and e.line <= line and line <= e.line + e.code.len: return "module"

# ── the test file ──

const Header = "## Tests made from the runnableExamples of "
const Mark = "# ── "

func sectionName(owner: string): string =
  ## the routine's name as a name Nim takes in a label
  var s = ""
  for c in owner:
    s.add (if c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: c else: '_')
  while "__" in s: s = s.replace("__", "_")
  s = s.strip(chars = {'_'})
  if s.len == 0 or s[0] in {'0'..'9'}: s = "op_" & s
  s

func section*(e: Example, n: int, src: string, unittest: bool): (seq[string], seq[string]) =
  ## one example as the test file has it — its lines and the imports it needs (at the top)
  var body, imports: seq[string]
  for c in e.code:
    let t = c.strip
    if (t.startsWith("import ") or t.startsWith("from ") or t.startsWith("include ")) and c.len > 0 and
       c[0] notin {' ', '\t'}:
      imports.add t
    else: body.add c
  let name = sectionName(e.owner)
  var ls = @[Mark & (if e.owner == "module": "the module's examples" else: e.owner) &
             (if n > 1: " (" & $n & ")" else: "") & " — " & src & ":" & $(e.line + 1) & " ──"]
  if e.flags.len > 0: ls.add "# (its examples are run with " & e.flags & ": run this file with them too)"
  # (a block's label is a name in its scope: the routine's own name would hide the routine from its examples)
  ls.add (if unittest: "test \"" & (if e.owner == "module": "the module" else: e.owner) &
                      (if n > 1: " (" & $n & ")" else: "") & "\":"
          else: "block " & name & "_example" & (if n > 1: "_" & $n else: "") & ":")
  var any = false
  for b in body:
    if b.strip.len > 0: any = true
    ls.add (if b.len == 0: "" else: "  " & b)
  if not any: ls.add "  discard"
  (ls, imports)

func ownerOfMark(l: string): string =
  ## the routine a section's first line names
  if not l.startsWith(Mark): return ""
  var s = l[Mark.len .. ^1]
  let d = s.find(" — ")
  if d >= 0: s = s[0 ..< d]
  let p = s.find(" (")
  if p >= 0: s = s[0 ..< p]
  if s == "the module's examples": "module" else: s

func merge*(old: seq[string], header: seq[string], newImports: seq[string], sections: seq[(string, seq[string])]):
    seq[string] =
  ## the test file with these routines' sections in place of the ones it had (new ones at its end), the imports
  ## added at its top
  var top, rest: seq[string]
  var i = 0
  if old.len == 0 or (old.len == 1 and old[0].len == 0): top = header
  else:
    while i < old.len and not old[i].startsWith(Mark):
      top.add old[i]
      inc i
    while top.len > 0 and top[^1].strip.len == 0: top.setLen(top.len - 1)
    rest = old[i .. ^1]
  for imp in newImports:
    if imp notin top:
      var at = top.len
      for k in countdown(top.high, 0):
        if top[k].startsWith("import ") or top[k].startsWith("from "):
          at = k + 1
          break
      top.insert(imp, at)
  # the sections there, by routine: the ones made now take their places
  var olds: seq[(string, seq[string])]
  for l in rest:
    if l.startsWith(Mark): olds.add (ownerOfMark(l), @[l])
    elif olds.len > 0: olds[^1][1].add l
  var made: seq[string]
  for (o, _) in sections:
    if o notin made: made.add o
  var outS: seq[seq[string]]
  var placed: seq[string]
  for (o, ls) in olds:
    if o in made:
      if o notin placed:
        placed.add o
        for (o2, ls2) in sections:
          if o2 == o: outS.add ls2
    else:
      var l = ls
      while l.len > 0 and l[^1].strip.len == 0: l.setLen(l.len - 1)
      outS.add l
  for (o, ls) in sections:
    if o notin placed: outS.add ls
  result = top
  for s in outS:
    result.add ""
    result.add s

proc importPath*(fromDir, module: string): string =
  ## the module (without .nim) as the test file imports it: relative, quoted when it is not a plain path
  var r = relativePath(module, fromDir).replace('\\', '/')
  if not r.startsWith("."): r = "./" & r
  var plain = true
  for c in r:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '/', '.'}: plain = false
  for part in r.split('/'):
    if part notin [".", ".."] and (part.len == 0 or part[0] notin {'a'..'z', 'A'..'Z'}): plain = false
  if plain and not r.startsWith("./"): r else: "\"" & r & "\""

proc projectOf(path: string): string =
  ## the folder with the .nimble file above the file, else the project's
  var d = parentDir(path)
  while d.len > 1:
    for kind, p in walkDir(d):
      if kind == pcFile and p.endsWith(".nimble"): return d
    let up = parentDir(d)
    if up == d: break
    d = up
  projectRoot()

proc makeTests(whole: bool) =
  let b = current()
  let path = b.path
  if not path.endsWith(".nim"):
    message("Examples to tests: open a .nim file")
    return
  let ls = b.lines
  let all = examples(ls)
  var chosen: seq[Example]
  var what = ""
  if whole:
    chosen = all
    what = "the whole file"
  else:
    let owner = ownerAt(ls, b.cursor.line)
    for e in all:
      if e.owner == owner: chosen.add e
    what = if owner == "module": "the module" elif owner.len > 0: owner else: ""
    if owner.len == 0:
      message("Examples to tests: put the cursor in a routine that has runnableExamples (or Examples to tests: " &
              "the whole file)")
      return
  if chosen.len == 0:
    message("Examples to tests: " & (if whole: "the file has" else: what & " has") & " no runnableExamples")
    return
  let root = projectOf(path)
  let dir = root / setting("folder", "tests")
  let module = splitFile(path).name
  let testPath = dir / "t" & module & ".nim"
  let unittest = setting("style", "block") == "unittest"
  let rel = if path.startsWith(root & "/"): path[root.len + 1 .. ^1] else: extractFilename(path)
  var header = @[Header & rel & " — made again, a routine's blocks take the place of the ones before",
                 "## (ned's examples-to-tests plugin)"]
  if unittest: header.add "import std/unittest"
  header.add "import " & importPath(dir, path[0 ..< ^4])
  var imports: seq[string]
  var sections: seq[(string, seq[string])]
  var count: seq[(string, int)]
  for e in chosen:
    var n = 1
    for c in count.mitems:
      if c[0] == e.owner:
        inc c[1]
        n = c[1]
    if n == 1: count.add (e.owner, 1)
    let (s, imps) = section(e, n, rel, unittest)
    for imp in imps:
      if imp notin imports: imports.add imp
    sections.add (e.owner, s)
  let tb = openFile(testPath)
  if not tb.valid:
    warn("Examples to tests: " & testPath & " could not be opened")
    return
  let old = tb.lines
  if unittest and old.len > 1 and "import std/unittest" notin old: imports.insert("import std/unittest", 0)
  tb.setText(merge(old, header, imports, sections).join("\n") & "\n")
  tb.save()
  let shownPath = if testPath.startsWith(root & "/"): testPath[root.len + 1 .. ^1] else: testPath
  message("Examples to tests: " & $chosen.len & " example" & (if chosen.len == 1: "" else: "s") & " of " & what &
          " in " & shownPath & " — run it with nim r " & shownPath & " (or nimble test)")

command "Examples to tests: this routine":
  makeTests(false)

command "Examples to tests: the whole file":
  makeTests(true)
