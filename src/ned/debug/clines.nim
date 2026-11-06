# ── the C files of a Nim 2.4 build put right for the debugger. Nim 2.4 writes a Nim line's C over several lines, with
#    one `#line` before them, and the C compiler counts on from it: the second of those lines is taken for the next
#    Nim line, the third for the one after, and so on — so a breakpoint stops before the variables are set, a step
#    goes to a line that did not run and the assembly is shaded against the wrong lines. Every line of code in a
#    function gets the `#line` it falls under again, which is what Nim 2.2's C (a Nim line's C on one line) gave;
#    a function's end goes under its proc's line, and an emit's C, which is the Nim file's own lines, keeps the
#    count. The build compiles copies put right, from the list of commands Nim wrote ──

import std/[json, os, strutils, tables, times]

func cLinesRaw(text: string): bool =
  ## whether `text` has what looks like a C++ raw string (`R"x(` … `)x"`), whose lines a `#line` put between would change
  var i = text.find("R\"")
  while i >= 0:
    var j = i + 2
    while j < text.len and j - i < 20 and text[j] notin {'(', ' ', '"', '\\', ')', '\n', '\t'}: inc j
    if j < text.len and text[j] == '(': return true
    i = text.find("R\"", i + 2)
  false

func cLinesGaps(lits: seq[string], k, at: int, s: string): bool =
  ## whether `s` from `at` is the literal parts `lits[k ..]` in order, something in each gap before them, the last at
  ## the end (cLinesLike's match of an emit line with `names`)
  if k == lits.len: return at == s.len
  if k == lits.high and lits[k].len == 0: return at < s.len
  var i = s.find(lits[k], at + 1)
  while i >= 0:
    if (k < lits.high or i + lits[k].len == s.len) and cLinesGaps(lits, k + 1, i + lits[k].len, s): return true
    i = s.find(lits[k], i + 1)
  false

func cLinesLike(src: seq[string], n: int, s: string): bool =
  ## whether the Nim line `n` (from 1) of a file's stripped lines `src` is the C line `s` (stripped) — the text of an
  ## emit, where a `name` in backquotes is the C name Nim gave it; a line of only braces or punctuation is not taken
  ## for one
  if n < 1 or n > src.len: return false
  let nim = src[n - 1]
  if nim != s:
    let parts = nim.split('`')
    if parts.len < 3 or parts.len mod 2 == 0 or not s.startsWith(parts[0]): return false
    var lits: seq[string]
    for j in countup(2, parts.high, 2): lits.add parts[j]
    if not cLinesGaps(lits, 0, parts[0].len, s): return false
  for c in s:
    if c in {'a' .. 'z', 'A' .. 'Z', '0' .. '9'}: return true
  false

func cLinesUnquote(s: string): string =
  ## a C string's text: `"/w/a.nim"` → /w/a.nim (with `\\` and `\"` read)
  let a = s.find('"')
  let b = s.rfind('"')
  if a < 0 or b <= a: return ""
  var i = a + 1
  while i < b:
    if s[i] == '\\' and i + 1 < b: inc i
    result.add s[i]
    inc i

proc cLinesFix*(text: string): string =
  ## `text` (a C file Nim wrote) with the last `#line` repeated before each further line of code until the function it
  ## is in ends — not inside a comment, nor after a line that a backslash continues. The text of an `{.emit}` is left
  ## to the C compiler's count, which is right for it: the lines under a `#line` that are the Nim file's own lines from
  ## there on (or from the next line, as a top-level emit starts; then that `#line` is put in). What Nim writes at a
  ## function's end (`popFrame();`, `return result;`, its closing brace) goes under the function's own `#line`, the
  ## proc's line, as its start does; what follows a function, until the next `#line`, is under none of the Nim files
  ## (Nim's own "generated_not_to_break_here"). `text` as it is when it has a C++ raw string
  if cLinesRaw(text): return text
  result = newStringOfCap(text.len + text.len div 2)
  var files: Table[string, string]   # FX_n → the Nim file it names (`#define FX_3 "/w/a.nim"`)
  var sources: Table[string, seq[string]]   # a Nim file's lines, stripped (none: it cannot be read)
  var cur = ""                      # the `#line` the lines are under ("" outside a function: nothing to repeat)
  var curN = 0                      # its line
  var curFile = ""                  # and its Nim file
  var curName = ""                  # as the `#line` names it (FX_3, "/w/a.nim")
  var cc = 0                        # the line the C compiler gives the next line of the file
  var fresh = false                 # the line before was that `#line` itself
  var emit = false                  # the lines under it are an emit's text: left to the C compiler's count
  var fnLine = ""                   # the `#line` the function started under (its proc's line)
  var fnN = 0
  var afterFn = false               # a function has just ended: the count is no Nim file's from here
  var depth = 0                     # braces open
  var inComment, cont = false       # inside /* */; the line before ended with a backslash
  var first = true
  for raw in text.split('\n'):
    if not first: result.add '\n'
    first = false
    let line = if raw.endsWith('\r'): raw[0 ..< ^1] else: raw
    let s = line.strip(trailing = false)
    if not inComment and not cont and s.startsWith('#'):
      # a preprocessor line: a `#line` is the one the next lines are under; any other takes a line of the count
      let d = s[1 .. ^1].strip(trailing = false)
      if d.startsWith("line ") or d.startsWith("line\t"):
        let w = d[4 .. ^1].strip.split(maxsplit = 1)
        cur = s
        curN = (try: parseInt(w[0]) except ValueError: 0)
        curName = if w.len < 2: "" else: w[1].strip
        curFile = if w.len < 2: "" elif w[1].startsWith('"'): cLinesUnquote(w[1]) else: files.getOrDefault(w[1].strip)
        cc = curN
        fresh = true
        emit = false
        afterFn = false
      else:
        if d.startsWith("define FX_"):
          let w = d[7 .. ^1].strip.split(maxsplit = 1)
          if w.len == 2: files[w[0]] = cLinesUnquote(w[1])
        fresh = false
        inc cc
      result.add raw
      cont = line.endsWith('\\')
      continue
    let st = line.strip
    if afterFn and st.len > 0 and not inComment and not cont:
      result.add "#line 999999 \"generated_not_to_break_here\"\n"
      afterFn = false
    if st.len > 0 and cur.len > 0 and not inComment and not cont and not emit:
      if curFile notin sources:
        var ls: seq[string]
        try:
          for l in readFile(curFile).splitLines: ls.add l.strip
        except IOError, OSError: discard
        sources[curFile] = ls
      let src = sources[curFile]
      if cLinesLike(src, cc, st):
        emit = true                 # (an emit's text, on the line the count gives it)
      elif cLinesLike(src, cc + 1, st):
        emit = true                 # (a top-level emit's: one line later than its `#line` says)
        inc cc
        result.add "#line " & $cc & " " & curName
        result.add '\n'
      elif fnLine.len > 0 and (st in ["popFrame();", "return result;", "BeforeRet_: ;"] or
                               depth == 1 and st.startsWith('}')):
        result.add fnLine           # (the function's end: the proc's line)
        result.add '\n'
        cc = fnN
      elif not fresh:
        result.add cur
        result.add '\n'
        cc = curN
    fresh = false
    result.add raw
    inc cc
    # the braces of the line, outside strings, characters and comments: when the function closes, nothing is repeated
    var i = 0
    while i < line.len:
      let c = line[i]
      if inComment:
        if c == '*' and i + 1 < line.len and line[i + 1] == '/':
          inComment = false
          inc i
      elif c == '/' and i + 1 < line.len and line[i + 1] == '/': break
      elif c == '/' and i + 1 < line.len and line[i + 1] == '*':
        inComment = true
        inc i
      elif c in {'"', '\''}:
        inc i
        while i < line.len and line[i] != c:
          if line[i] == '\\': inc i
          inc i
      elif c == '{':
        if depth == 0 and cur.len > 0: (fnLine, fnN) = (cur, curN)
        inc depth
      elif c == '}':
        dec depth
        if depth <= 0:
          depth = 0
          cur = ""
          fnLine = ""
          afterFn = true
      inc i
    cont = line.endsWith('\\')

proc cLinesFixFile*(path: string): bool =
  ## the C file at `path` put right in place (cLinesFix); whether it changed
  try:
    let t = readFile(path)
    let f = cLinesFix(t)
    if f != t:
      writeFile(path, f)
      return true
  except IOError, OSError: discard
  false

proc cLinesCopy*(cfile: string): string =
  ## the put-right copy of a C file Nim wrote, beside it: `@mapp.nim.c` → `@mapp.nim.lines.c`
  let (d, n, e) = splitFile(cfile)
  d / (n & ".lines" & e)

proc cLinesFixBuild*(dir: string): int =
  ## the build Nim listed in the nimcache `dir` (its newest `.json` with the C files to compile and the link command)
  ## made to compile put-right copies (cLinesCopy): each C file it lists is copied with its `#line`s put right, and its
  ## command given the copy in place of the file. Nim's own file stays as Nim wrote it, so that a module that has not
  ## changed is not compiled again next time. How many files; -1 when there is no such list
  var jf = ""
  var newest = 0.0
  for kind, p in walkDir(dir):
    if kind == pcFile and p.endsWith(".json"):
      try:
        let m = getLastModificationTime(p).toUnixFloat
        if m > newest and "\"linkcmd\"" in readFile(p):
          newest = m
          jf = p
      except CatchableError: discard
  if jf.len == 0: return -1
  var j: JsonNode
  try: j = parseFile(jf)
  except CatchableError: return -1
  let comp = j{"compile"}
  if comp == nil or comp.kind != JArray: return -1
  for e in comp:
    if e.kind != JArray or e.len < 2 or e[0].kind != JString or e[1].kind != JString: continue
    let cfile = e[0].getStr
    let cmd = e[1].getStr
    let at = cmd.rfind(cfile)                  # (the file comes last: before it, `-o` names the object, which stays)
    if at < 0: continue
    try:
      writeFile(cLinesCopy(cfile), cLinesFix(readFile(cfile)))
    except IOError, OSError: continue
    e.elems[1] = %(cmd[0 ..< at] & cLinesCopy(cfile) & cmd[at + cfile.len .. ^1])
    inc result
  try: writeFile(jf, $j)
  except IOError, OSError: return -1

proc cLinesMain*(args: seq[string]): int =
  ## ned --c-lines DIR: the build Nim listed in the nimcache DIR made to compile its C put right for the debugger
  ## (cLinesFixBuild), for `nim jsonscript` to run next; 0, or 2 when DIR has no such list
  if args.len != 1 or not dirExists(args[0]) or cLinesFixBuild(args[0]) < 0:
    stderr.writeLine("ned --c-lines DIR: the C files of the build Nim listed in the folder DIR (nim c --compileOnly " &
                     "--nimcache:DIR), put right for a debugger")
    return 2
  0
