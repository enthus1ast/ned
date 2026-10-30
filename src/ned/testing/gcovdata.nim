## Nim test coverage, the parts that stand on their own (unit-tested in tests/unit/tgcov.nim):
##
## Nim's C (built with --lineDir:on) puts a `#line N "file.nim"` before each statement, but a statement's C often
## takes several lines — the `goto`, the label after an `if`, a `break`, the frame pop — and those lines count on as
## N+1, N+2 … of the .nim file: an `else:` or a blank line, even the next proc's header, would show as run. Only the
## C line right after each `#line` (its anchor) stands for the .nim line:
##
## - gcc (gcov reads the .nim lines from the #line directives): `covRewriteC` moves the lines after each anchor to a
##   file of their own before the C is compiled; then gcov's output, gcc ≥ 9's JSON (`gcov --json-format --stdout`,
##   read as a stream of tokens, one document per .gcda) or the older intermediate / classic .gcov text, gives the
##   .nim lines' counts.
## - clang (Termux, macOS): its gcov instrumentation drops code whose #line names another file than its function's
##   (an inlined iterator, a template from another module), so clang's source-based coverage is used instead: it
##   counts C lines (`llvm-cov export -format=lcov`), and `covLineMap` / `parseLcovMapped` take each anchor's count
##   to its .nim line.
## - `nimRoutineSpans`: the procs of a Nim file and the lines that would hold their code. Nim leaves a proc no one
##   calls out of the C altogether, so gcov never hears of it; a proc of a tested module with no line in the data
##   is one no test reaches.

import std/[streams, parsejson, tables, strutils, os, cpuinfo]

const
  CovBleedFile* = "/ned-coverage/continued"
    ## where gcc's C lines after the first one of a statement are counted (never a real file)
  CovCacheVersion* = "1"
    ## the kept builds are made again when this changes (a different rewrite of the C)

type
  CovHits* = Table[string, Table[int, int]]
    ## source file → 1-based line → times it ran (summed over the .gcda files and the test programs)
  CovPathMap* = proc(file: string): string {.closure.}
    ## the absolute file gcov names → the file to count it under, "" to leave it out
  CovSpan* = object
    name*, kind*: string     ## the routine and its keyword (proc, func, method, iterator, converter)
    first*, last*: int       ## 0-based: its declaration's first line and its body's last line
    code*: seq[int]          ## 0-based: the lines that would hold its code (the declaration, each statement)

proc addHit*(h: var CovHits, file: string, line, count: int) =
  ## adds `count` runs to a file's line in the table (counts from several programs or .gcda files add up); an empty file
  ## name or a line below 1 is ignored
  if file.len == 0 or line <= 0: return
  h.mgetOrPut(file, initTable[int, int]()).mgetOrPut(line, 0) += max(count, 0)

proc covJobs*(): int =
  ## how many C files to compile at once
  max(1, cpuinfo.countProcessors())

func covHash*(s: string): string =
  ## FNV-1a, 64 bits, hex: has a text changed
  var x = 14695981039346656037'u64
  for c in s:
    x = (x xor uint64(ord(c))) * 1099511628211'u64
  toHex(x, 16).toLowerAscii

func covCacheName*(s: string): string =
  ## a short, stable folder name for a path (FNV-1a, hex) with the file's name in front when it has one
  var x = 2166136261'u32
  for c in s:
    x = (x xor uint32(ord(c))) * 16777619'u32
  let base = splitFile(s).name
  var safe = ""
  for c in base:
    if c in IdentChars: safe.add c
  (if safe.len > 0: safe[0 ..< min(safe.len, 40)] & "_" else: "") & toHex(x, 8).toLowerAscii

func isLineDirective(l: string): bool =
  ## `#line 12 "x.nim"` / `#line 12 FX_3` (as Nim writes them: at the start of a line)
  if not l.startsWith("#line "): return false
  var i = 6
  while i < l.len and l[i] == ' ': inc i
  i < l.len and l[i] in Digits

func covRewriteC*(src: string): string =
  ## Nim's generated C with each statement's later lines moved off the .nim lines, for gcc (see the top of the file).
  ## A line that a backslash continues is never split
  result = newStringOfCap(src.len + src.len div 3)
  var state = 0              # 0 before the first #line, 1 the anchor comes next, 2 the lines after it
  var cont = false           # the line before ended with a backslash
  var start = 0
  while start <= src.len:
    var e = src.find('\n', start)
    let last = e < 0
    if last: e = src.len
    if last and start == src.len: break
    let l = src[start ..< e]
    let nl = if last: "" else: "\n"
    if not cont and isLineDirective(l):
      result.add l
      result.add nl
      state = 1
    elif state == 1:
      result.add l
      result.add nl
      if not l.endsWith("\\"):
        state = 2
        result.add "#line 1 \"" & CovBleedFile & "\"\n"
    else:
      result.add l
      result.add nl
    cont = l.endsWith("\\")
    if last: break
    start = e + 1

# ── gcov's output ──

proc resolved(file, base: string): string =
  ## a normalised absolute file name: `file` as it is when absolute (or when there is no base folder), else under `base`
  if file.len == 0: return ""
  if file.isAbsolute or base.len == 0: normalizedPath(file) else: normalizedPath(base / file)

proc parseGcovJson*(s: Stream, h: var CovHits, mapPath: CovPathMap, baseDir = "") =
  ## gcc's `gcov --json-format --stdout a.gcda b.gcda …`: one JSON document per .gcda, read token by token (a big
  ## project's output is never held whole). files[].file, files[].lines[].line_number / count are taken; the
  ## documents' current_working_directory resolves a relative file name
  type Frame = object
    obj: bool
    key: string              # the key this container is the value of (an array's elements keep the array's)
  var p: JsonParser
  p.open(s, "gcov.json")
  defer: p.close()
  var stack: seq[Frame]
  var key = ""
  var wantKey = false        # in an object, a key comes next
  var cwd = baseDir
  var fileKnown = false
  var curFile = ""
  var pending: seq[(int, int)]       # a file's lines read before its name (kept until the file's object ends)
  var lineNo, lineCount = 0
  # whether the parser is directly inside one object of the document's `files` array
  proc inFile(st: seq[Frame]): bool = st.len == 3 and st[2].obj and st[1].key == "files"
  # whether the parser is directly inside one object of a file's `lines` array
  proc inLine(st: seq[Frame]): bool = st.len == 5 and st[4].obj and st[3].key == "lines" and st[1].key == "files"
  while true:
    let t = p.getTok()
    case t
    of tkEof, tkError: break
    of tkCurlyLe, tkBracketLe:
      let k = if stack.len > 0 and not stack[^1].obj: stack[^1].key else: key
      stack.add Frame(obj: t == tkCurlyLe, key: k)
      wantKey = t == tkCurlyLe
      key = ""
      if inFile(stack):
        fileKnown = false
        curFile = ""
        pending.setLen(0)
      elif inLine(stack):
        lineNo = 0
        lineCount = 0
    of tkCurlyRi, tkBracketRi:
      if inLine(stack):
        if lineNo > 0:
          if fileKnown:
            if curFile.len > 0: h.addHit(curFile, lineNo, lineCount)
          else: pending.add (lineNo, lineCount)
      elif inFile(stack):
        if not fileKnown: pending.setLen(0)    # (no name: nothing to count it under)
        fileKnown = false
        curFile = ""
      elif stack.len == 1:
        cwd = baseDir
      if stack.len > 0: stack.setLen(stack.len - 1)
      wantKey = stack.len > 0 and stack[^1].obj
      key = ""
    of tkColon: wantKey = false
    of tkComma: wantKey = stack.len > 0 and stack[^1].obj
    of tkString, tkInt, tkFloat, tkTrue, tkFalse, tkNull:
      if wantKey and t == tkString:
        key = p.a
        continue
      # a value
      if stack.len == 1 and key == "current_working_directory" and t == tkString:
        cwd = p.a
      elif inFile(stack) and key == "file" and t == tkString:
        fileKnown = true
        curFile = mapPath(resolved(p.a, cwd))
        if curFile.len > 0:
          for (ln, c) in pending: h.addHit(curFile, ln, c)
        pending.setLen(0)
      elif inLine(stack) and t == tkInt:
        if key == "line_number": lineNo = (try: parseInt(p.a) except ValueError: 0)
        elif key == "count": lineCount = (try: parseInt(p.a) except ValueError: 0)
      elif inLine(stack) and t == tkFloat and key == "count":
        lineCount = (try: int(parseFloat(p.a)) except ValueError: 0)
      key = ""

proc parseGcovIntermediate*(s: Stream, h: var CovHits, mapPath: CovPathMap, baseDir = "") =
  ## `llvm-cov gcov -i` / gcc < 9's `gcov -i`: file:<path> … lcount:<line>,<count>[,<unexecuted>]
  var cur = ""
  var line = ""
  while s.readLine(line):
    if line.startsWith("file:"):
      cur = mapPath(resolved(line[5 .. ^1].strip, baseDir))
    elif line.startsWith("lcount:") and cur.len > 0:
      let parts = line[7 .. ^1].split(',')
      if parts.len >= 2:
        let ln = (try: parseInt(parts[0].strip) except ValueError: 0)
        let c = (try: parseInt(parts[1].strip) except ValueError: 0)
        h.addHit(cur, ln, c)

proc parseGcovText*(s: Stream, h: var CovHits, mapPath: CovPathMap, baseDir = "") =
  ## the classic .gcov text: `count:line:source`, a `-:0:Source:<path>` before each file; ##### never ran
  var cur = ""
  var line = ""
  while s.readLine(line):
    let c1 = line.find(':')
    if c1 < 0: continue
    let c2 = line.find(':', c1 + 1)
    if c2 < 0: continue
    let cnt = line[0 ..< c1].strip
    let lnS = line[c1 + 1 ..< c2].strip
    if lnS.len == 0 or not lnS.allCharsInSet(Digits): continue
    let ln = parseInt(lnS)
    if ln == 0:
      let rest = line[c2 + 1 .. ^1]
      if rest.startsWith("Source:"): cur = mapPath(resolved(rest[7 .. ^1].strip, baseDir))
      continue
    if cur.len == 0 or cnt == "-" or cnt.len == 0: continue
    if cnt.startsWith("#####") or cnt.startsWith("====="): h.addHit(cur, ln, 0)
    else:
      let n = (try: parseInt(cnt.strip(chars = {'*'})) except ValueError: -1)
      if n >= 0: h.addHit(cur, ln, n)

proc parseGcovFile*(path: string, h: var CovHits, mapPath: CovPathMap, baseDir = "") =
  ## any of the three, told apart by how the file starts
  let s = newFileStream(path, fmRead)
  if s == nil: raise newException(IOError, "cannot read " & path)
  defer: s.close()
  var head = ""
  while not s.atEnd and head.len < 16:
    let c = s.readChar()
    if head.len == 0 and c in Whitespace: continue
    head.add c
  s.setPosition(0)
  if head.startsWith("{"): parseGcovJson(s, h, mapPath, baseDir)
  elif head.startsWith("file:") or head.startsWith("version:"): parseGcovIntermediate(s, h, mapPath, baseDir)
  else: parseGcovText(s, h, mapPath, baseDir)

proc covLineMap*(csrc: string): Table[int, (string, int)] =
  ## Nim's C: each anchor (the line after a `#line N "file"` or `#line N FX_k` with `#define FX_k "file"`) → (file,
  ## N); 1-based C lines
  var fx: Table[string, string]
  var ln = 0
  var start = 0
  var anchorOf = ("", 0)
  var cont = false
  while start < csrc.len:
    var e = csrc.find('\n', start)
    if e < 0: e = csrc.len
    inc ln
    if anchorOf[1] > 0:
      result[ln] = anchorOf
      anchorOf = ("", 0)
    if not cont and e - start > 8 and csrc[start] == '#':
      let l = csrc[start ..< e]
      if l.startsWith("#define FX_"):
        let sp = l.find(' ', 8)
        let q = l.find('"', sp)
        if sp > 0 and q > 0 and l.endsWith("\""): fx[l[8 ..< sp]] = l[q + 1 ..< ^1].replace("\\\\", "\\")
      elif isLineDirective(l):
        let parts = l.splitWhitespace(2)
        if parts.len == 3:
          let n = (try: parseInt(parts[1]) except ValueError: 0)
          let f = if parts[2].startsWith("\""): parts[2].strip(chars = {'"'}) else: fx.getOrDefault(parts[2])
          if n > 0 and f.len > 0: anchorOf = (f, n)
    cont = e > start and csrc[e - 1] == '\\'
    start = e + 1

proc parseLcovMapped*(s: Stream, h: var CovHits, mapPath: CovPathMap,
                      cmap: proc(cfile: string): Table[int, (string, int)]) =
  ## lcov of C files (`llvm-cov export -format=lcov`): each anchor's count to its .nim line (`cmap`: a C file's
  ## anchors, see covLineMap)
  var m: Table[int, (string, int)]
  var mapped: Table[string, string]           # the .nim files named → where they count ("" = not at all)
  var line = ""
  while s.readLine(line):
    if line.startsWith("SF:"):
      m = cmap(line[3 .. ^1].strip)
    elif line.startsWith("DA:") and m.len > 0:
      let parts = line[3 .. ^1].split(',')
      if parts.len < 2: continue
      let c = (try: parseInt(parts[0]) except ValueError: 0)
      if c notin m: continue
      let (f, n) = m[c]
      if f notin mapped: mapped[f] = mapPath(f)
      let p = mapped[f]
      if p.len > 0: h.addHit(p, n, (try: parseInt(parts[1].strip) except ValueError: 0))
    elif line == "end_of_record": m.clear()

proc parseLcovMappedFile*(path: string, h: var CovHits, mapPath: CovPathMap,
                          cmap: proc(cfile: string): Table[int, (string, int)]) =
  ## reads an lcov file from disk through parseLcovMapped (the C lines of clang's coverage taken to .nim lines by
  ## `cmap`); raises IOError when it cannot be opened
  let s = newFileStream(path, fmRead)
  if s == nil: raise newException(IOError, "cannot read " & path)
  defer: s.close()
  parseLcovMapped(s, h, mapPath, cmap)

# ── the procs of a Nim file, for the ones no test reaches ──

const
  RoutineWords = ["proc", "func", "method", "iterator", "converter"]
  BlockHeadWords = ["proc", "func", "method", "iterator", "converter", "template", "macro"]
  NoCodeWords = ["else", "of", "except", "finally", "try", "when", "type", "const", "block", "static", "defer",
                 "yield", "using", "mixin", "bind", "import", "from", "include", "export", "template", "macro"]
  ContinueEnds = [",", "(", "[", "{", "=", "+", "-", "*", "/", "&", "|", ".", "and", "or", "xor", "not", "div",
                  "mod", "shl", "shr", "in", "notin", "is", "isnot", "->", "==", "!=", "<", ">", "<=", ">=", "@",
                  "\\", "%", "^", "~", "$"]

type LineScan = object
  depth: int                 # brackets open at the line's end
  inLong: bool               # inside a """ string at the line's end
  inBlockComment: int        # inside #[ … ]# at the line's end (nested)
  code: string               # the line without its comments and its strings' insides

proc scanLine(l: string, st: var LineScan) =
  ## brackets, strings and comments of one line, carrying what stays open to the next
  st.code.setLen(0)
  var i = 0
  while i < l.len:
    let c = l[i]
    if st.inBlockComment > 0:
      if c == ']' and i + 1 < l.len and l[i + 1] == '#':
        dec st.inBlockComment
        inc i, 2
      elif c == '#' and i + 1 < l.len and l[i + 1] == '[':
        inc st.inBlockComment
        inc i, 2
      else: inc i
      continue
    if st.inLong:
      if c == '"' and i + 2 < l.len and l[i + 1] == '"' and l[i + 2] == '"':
        st.inLong = false
        inc i, 3
        while i < l.len and l[i] == '"': inc i
        st.code.add "\"\""
      else: inc i
      continue
    case c
    of '#':
      if i + 1 < l.len and l[i + 1] == '[':
        inc st.inBlockComment
        inc i, 2
        continue
      break                                  # a comment to the end of the line
    of '"':
      if i + 2 < l.len and l[i + 1] == '"' and l[i + 2] == '"':
        st.inLong = true
        inc i, 3
        continue
      let raw = i > 0 and l[i - 1] in IdentChars      # r"…", fmt"…": "" is a quote, \ is not an escape
      inc i
      while i < l.len:
        if l[i] == '\\' and not raw: inc i, 2
        elif l[i] == '"':
          if raw and i + 1 < l.len and l[i + 1] == '"': inc i, 2
          else: break
        else: inc i
      inc i
      st.code.add "\"\""
      continue
    of '\'':
      if i + 3 < l.len and l[i + 1] == '\\':           # '\n', '\'', '\x41'
        var k = i + 2
        while k < l.len and k < i + 8 and not (l[k] == '\'' and k > i + 2): inc k
        i = k + 1
        st.code.add "'x'"
        continue
      if i + 2 < l.len and l[i + 2] == '\'':          # 'a'
        inc i, 3
        st.code.add "'x'"
        continue
    of '(', '[', '{': inc st.depth
    of ')', ']', '}': st.depth = max(0, st.depth - 1)
    else: discard
    st.code.add c
    inc i

func covNoCodeLine*(t: string): bool =
  ## a (stripped) Nim line that holds no code of its own: blank, a comment, else: / of / try: / except / finally:,
  ## when (decided while compiling), type and const sections, block: / static: / defer:, yield (the loop's body runs
  ## there), template and macro heads, imports, a bare discard. Counts gcov puts there belong to the code after it
  if t.len == 0 or t[0] == '#' or t == "discard" or t == "nil" or t.startsWith("{.") or
     t.startsWith("discard \"\"\""): return true
  var w = ""
  for c in t:
    if c in IdentChars: w.add c
    else: break
  w in NoCodeWords

func gcovIndentOf(l: string): int =
  ## the number of leading spaces of a line
  while result < l.len and l[result] == ' ': inc result

func endsOpen(code: string): bool =
  ## the statement goes on to the next line: an operator, a comma or an open bracket at its end
  let t = code.strip
  if t.len == 0 or (t.endsWith(":") and not t.endsWith("::")): return false
  for e in ContinueEnds:
    if t.endsWith(e):
      if e[0] notin IdentChars: return true
      let k = t.len - e.len                          # a word: only standing alone (`x and`, not `band`)
      if k == 0 or t[k - 1] notin IdentChars: return true
  false

func startsWithWord(t: string, words: openArray[string]): string =
  ## the first of `words` that `t` starts with as a whole word (followed by the end, a space, tab, `*`, backtick or
  ## `[`), "" when none
  for w in words:
    if t.startsWith(w) and (t.len == w.len or t[w.len] in {' ', '\t', '*', '`', '['}): return w
  ""

func routineHead(t: string): (string, string) =
  ## `proc name*[T](…)` → (keyword, name); ("", "") when the line declares no named routine
  let w = startsWithWord(t, RoutineWords)
  if w.len == 0: return ("", "")
  var i = w.len
  while i < t.len and t[i] in {' ', '\t'}: inc i
  if i >= t.len or t[i] in {'(', '[', '{', '*'}: return ("", "")      # an anonymous proc, a proc type
  var name = ""
  if t[i] == '`':
    let e = t.find('`', i + 1)
    if e < 0: return ("", "")
    name = t[i + 1 ..< e]
  else:
    while i < t.len and t[i] in IdentChars:
      name.add t[i]
      inc i
  if name.len == 0: ("", "") else: (w, name)

func bodyEq(code: string, depth: var int, inTick: var bool): int =
  ## where the routine's `=` is on a header line (outside brackets and `names`; not ==, <=, => …), -1 if not here
  result = -1
  for j, ch in code:
    if ch == '`':
      inTick = not inTick
      continue
    if inTick: continue
    case ch
    of '(', '[', '{': inc depth
    of ')', ']', '}': depth = max(0, depth - 1)
    of '=':
      if depth == 0 and result < 0:
        let before = if j > 0: code[j - 1] else: ' '
        let after = if j + 1 < code.len: code[j + 1] else: ' '
        if before notin {'=', '<', '>', '!', ':', '+', '-', '*', '/', '&', '|', '%', '^', '~', '.', '@', '$'} and
           after notin {'=', '>', '<'}:
          result = j
    else: discard

proc nimRoutineSpans*(lines: openArray[string], inactive: openArray[(int, int)] = []): seq[CovSpan] =
  ## each proc, func, method, iterator and converter with a body: where it is and the lines that would hold its
  ## code (its declaration and each statement's first line — not `else:`, `of`, `try:`, comments, a statement's
  ## continuation lines). Left out: templates and macros (their code is at the call), compile-time procs, ones
  ## imported from C or borrowed, forward declarations, and procs in `when isMainModule` / `when false` blocks, in
  ## `static:` blocks or in `inactive` (0-based ranges: `when` branches this platform leaves out)
  var starts = newSeq[bool](lines.len)     # the line begins a statement
  var codes = newSeq[string](lines.len)
  var st: LineScan
  var prevOpen = false
  var head = ""                             # the line that began the statement this one belongs to
  for i, l in lines:
    let inside = st.depth > 0 or st.inLong or st.inBlockComment > 0
    let t = l.strip
    scanLine(l, st)
    codes[i] = st.code
    starts[i] = not inside and not prevOpen and t.len > 0 and t[0] != '#' and t[0] notin {'.', ')', ']', '}'} and
                not t.startsWith("and ") and not t.startsWith("or ")
    if starts[i]: head = t
    if st.depth > 0 or st.inLong or st.inBlockComment > 0: prevOpen = false
    elif st.code.strip.len > 0:
      prevOpen = endsOpen(st.code)
      if prevOpen and st.code.strip.endsWith("=") and startsWithWord(head, BlockHeadWords).len > 0:
        prevOpen = false                    # a routine's `=`: its body starts below
  var skip = newSeq[bool](lines.len)
  for (a, b) in inactive:
    for k in max(a, 0) .. min(b, lines.high): skip[k] = true
  for i, l in lines:
    if not starts[i]: continue
    let t = codes[i].strip
    if (t.startsWith("when isMainModule") or t.startsWith("when false") or t == "static:") and t.endsWith(":"):
      let ind = gcovIndentOf(l)
      var k = i + 1
      while k < lines.len:
        if starts[k] and gcovIndentOf(lines[k]) <= ind: break
        skip[k] = true
        inc k
  var i = 0
  while i < lines.len:
    if not starts[i] or skip[i]:
      inc i
      continue
    let (kw, name) = routineHead(lines[i].strip)
    if kw.len == 0:
      inc i
      continue
    let ind = gcovIndentOf(lines[i])
    # the header: to its `=` outside brackets, or to where it ends without one (a forward declaration)
    var k = i
    var depth = 0
    var inTick = false
    var eqAt = -1
    var inlineBody = false
    var pragmas = ""
    while k < lines.len:
      let c = codes[k]
      let e = bodyEq(c, depth, inTick)
      if e >= 0:
        eqAt = k
        inlineBody = c[e + 1 .. ^1].strip.len > 0
        pragmas.add c[0 ..< e]
        break
      pragmas.add c
      if depth == 0 and not endsOpen(c) and (k + 1 >= lines.len or starts[k + 1]): break
      inc k
    let headEnd = min(k, lines.high)
    let pr = pragmas.replace(" ", "")
    if eqAt < 0 or "compileTime" in pr or "importc" in pr or "importjs" in pr or "importobjc" in pr or
       ".borrow" in pr or "{.borrow" in pr:
      i = headEnd + 1
      continue
    var sp = CovSpan(name: name, kind: kw, first: i, last: headEnd)
    sp.code.add i
    var b = headEnd + 1
    while b < lines.len:
      let lb = lines[b]
      let tb = lb.strip
      if tb.len == 0 or tb.startsWith("#"):        # (blank, a comment: neither code nor the end)
        inc b
        continue
      if starts[b] and gcovIndentOf(lb) <= ind: break
      if starts[b]:
        if not covNoCodeLine(tb): sp.code.add b
      sp.last = b
      inc b
    if inlineBody or sp.last > headEnd: result.add sp
    i = headEnd + 1
