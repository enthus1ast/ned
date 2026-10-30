# ════════════════════════════════════════════════════════════════════════════
#  C interop: the C side of importc wrappers — headers, prototypes, wrapper checks, c2nim, clangd
# ════════════════════════════════════════════════════════════════════════════

type
  NimFfi = object               # a Nim declaration that imports a C one
    line, eline: int            # its lines in the Nim file
    kind: string                # proc, func, var, let, const, type
    name: string                # the Nim name
    nameCol: int
    cname: string               # the C name: importc's argument, else the Nim name
    header: string              # header: "…" as written ("<stdio.h>" or "foo.h"); "" when none
    params: seq[(string, string, Pos, Pos)]   # name, Nim type, where the type is (for fixes)
    ret: string                 # the Nim return (or variable) type
    retAt, retEnd: Pos
    varargs: bool
  CProto = object               # a C declaration found in a header
    path: string
    line: int
    kind: string                # function, macro, type, variable
    text: string                # the declaration on one line
    ret: string                 # functions: the return type; variables: the type
    params: seq[string]         # each parameter's C text ("const char *fmt")
    varargs: bool

var
  cSysDirs: seq[string]                     # the C compiler's own include folders
  cSysDirsDone = false
  cDirsCache: Table[string, (MonoTime, seq[string])]
  cHeaderText: Table[string, (times.Time, string)]   # header → (mtime, its text with comments blanked)

var cSysDirsAsked = false

proc cSysDirsFrom(output: string) =
  ## the folders in `cc -E -v`'s answer (and the usual ones after them)
  var inList = false
  for l in output.splitLines:
    if l.startsWith("#include <...> search starts here"):
      inList = true
      continue
    if l.startsWith("End of search list"): break
    if inList and l.startsWith(" "):
      var d = l.strip
      if d.endsWith("(framework directory)"): d = d[0 ..< d.len - "(framework directory)".len].strip
      if dirExists(d) and d notin cSysDirs: cSysDirs.add d
  for d in [getEnv("PREFIX") / "include", "/usr/local/include", "/usr/include"]:
    if d.len > 1 and dirExists(d) and d notin cSysDirs: cSysDirs.add d

proc cSystemIncludeDirs(): seq[string] =
  ## where #include <…> looks, as the C compiler says (cc -v); cached. The editor asks the compiler in the
  ## background (a phone's clang takes a moment to start: no key waits for it) — the usual folders meanwhile
  if cSysDirsDone: return cSysDirs
  var cc = ""
  for c in ["cc", "clang", "gcc"]:
    if haveExe(c):
      cc = c
      break
  when defined(nedNoMain):
    cSysDirsDone = true
    if cc.len > 0:
      let (_, o, e) = runFilter("echo | " & cc & " -E -Wp,-v -x c - 2>&1", "", getCurrentDir(), 5000)
      cSysDirsFrom(o & "\n" & e)
    else: cSysDirsFrom("")
    cSysDirs
  else:
    if wkWorkerMode:
      # (the engine worker: asked at once — no key waits for it here, and its jobs are not run; with only the usual
      # folders a system header's own includes were missing: <string.h> unread whole, never "not used")
      cSysDirsDone = true
      if cc.len > 0:
        let (_, o, e) = runFilter("echo | " & cc & " -E -Wp,-v -x c - 2>&1", "", getCurrentDir(), 5000)
        cSysDirsFrom(o & "\n" & e)
      else: cSysDirsFrom("")
      return cSysDirs
    if cc.len == 0:
      cSysDirsDone = true
      cSysDirsFrom("")
      return cSysDirs
    if not cSysDirsAsked:
      cSysDirsAsked = true
      discard startJob(jkAux, "echo | " & cc & " -E -Wp,-v -x c - 2>&1", getCurrentDir(), proc(j: Job) =
        cSysDirs.setLen(0)
        cSysDirsFrom(j.output)
        cSysDirsDone = true
        cDirsCache.clear()
        for x in bufs:                       # (C files: their hints and checks again, the headers found now)
          if x.lang != nil and x.lang.id in ["c", "cpp"]: x.inlayAt = -1)
    var tmp: seq[string]
    for d in [getEnv("PREFIX") / "include", "/usr/local/include", "/usr/include"]:
      if d.len > 1 and dirExists(d): tmp.add d
    tmp

proc cFlagDirs(text, base: string, dirs: var seq[string]) =
  ## the -I folders named in config text (--passC:"-I…", switch("passC", "-I…"), {.passC: "-I…".})
  var i = text.find("-I")
  while i >= 0:
    if i == 0 or text[i - 1] in {' ', '"', '\'', ':', '\t', '='}:
      var j = i + 2
      var d = ""
      if j < text.len and text[j] in {'"', '\''}:
        let q = text[j]
        let e = text.find(q, j + 1)
        if e > j: d = text[j + 1 ..< e]
      else:
        while j < text.len and text[j] notin {' ', '"', '\'', ')', ',', '\t', '\n'}: inc j
        d = text[i + 2 ..< j]
      if d.len > 0:
        let p = if d.isAbsolute: d else: base / d
        if dirExists(p) and p notin dirs: dirs.add p
    i = text.find("-I", i + 2)


proc cConfigFiles(nimPath: string): seq[string] =
  ## the project's config files that may pass flags to the C compiler
  let dir = parentDir(nimPath)
  for d in [dir, rootDir]:
    if d.len == 0: continue
    for f in ["config.nims", "nim.cfg", extractFilename(d) & ".nims"]:
      if (d / f) notin result: result.add d / f
    try:
      for k, f in walkDir(d):
        if (f.endsWith(".nimble") or f.endsWith(".nim.cfg")) and f notin result: result.add f
    except OSError: discard

proc cFlagDefs(text: string, defs: var seq[string]) =
  ## the -D and -U flags named in config text or a {.passC.} (-DNAME, -DNAME=value, -UNAME)
  for flag in ["-D", "-U"]:
    var i = text.find(flag)
    while i >= 0:
      if i == 0 or text[i - 1] in {' ', '"', '\'', ':', '\t', '='}:
        var j = i + 2
        while j < text.len and text[j] notin {' ', '"', '\'', ')', ',', '\t', '\n'}: inc j
        let d = text[i ..< j]
        if d.len > 2 and d[2] in IdentStartChars and d notin defs: defs.add d
      i = text.find(flag, i + 2)

proc cDefines(nimPath: string, lines: seq[string]): seq[string] =
  ## the -D/-U flags the C of a Nim file is compiled with: its {.passC.}, then the project's config
  for l in lines:
    if "passC" in l or "passc" in l: cFlagDefs(l, result)
  for f in cConfigFiles(nimPath):
    if fileExists(f):
      try: cFlagDefs(readFile(f), result)
      except CatchableError: discard

proc cIncludeDirs(nimPath: string, lines: seq[string]): seq[string] =
  ## where a Nim file's headers are looked for: its folder, the project, -I flags in the project's
  ## config and the file's {.passC.}, Nim's lib folder, then the C compiler's own folders (kept 5 s:
  ## completion asks on every key)
  if nimPath in cDirsCache and (getMonoTime() - cDirsCache[nimPath][0]).inMilliseconds < 5000:
    return cDirsCache[nimPath][1]
  defer: cDirsCache[nimPath] = (getMonoTime(), result)
  let dir = parentDir(nimPath)
  result.add dir
  if rootDir.len > 0 and rootDir != dir: result.add rootDir
  for l in lines:
    if "passC" in l or "passc" in l: cFlagDirs(l, dir, result)
  var cfgs: seq[string]
  for d in [dir, rootDir]:
    if d.len == 0: continue
    for f in ["config.nims", "nim.cfg", extractFilename(d) & ".nims"]: cfgs.add d / f
    try:
      for k, f in walkDir(d):
        if f.endsWith(".nimble") or f.endsWith(".nim.cfg"): cfgs.add f
    except OSError: discard
  for f in cfgs:
    if fileExists(f):
      try: cFlagDirs(readFile(f), parentDir(f), result)
      except CatchableError: discard
  let nl = nimLibDir()
  if nl.len > 0: result.add nl
  for d in cSystemIncludeDirs():
    if d notin result: result.add d

proc cFindHeader(name: string, dirs: seq[string], fromDir = ""): string =
  ## the header file `name` (as #include writes it: <x.h> or "x.h") in these folders
  var n = name.strip
  let angle = n.startsWith("<")
  n = n.strip(chars = {'<', '>', '"', ' '})
  if n.len == 0: return ""
  if n.isAbsolute: return (if fileExists(n): n else: "")
  if not angle and fromDir.len > 0 and fileExists(fromDir / n): return fromDir / n
  for d in dirs:
    if fileExists(d / n): return d / n
  ""

proc cBlank(s: var string)

proc cHeaderCode(path: string): string =
  ## the header's text with comments (and string contents) blanked: positions and lines stay as they are
  var mt: times.Time
  try: mt = getLastModificationTime(path)
  except CatchableError: return ""
  if path in cHeaderText and cHeaderText[path][0] == mt: return cHeaderText[path][1]
  var s = ""
  try: s = readFile(path)
  except CatchableError: return ""
  if s.len > 4_000_000: s.setLen(4_000_000)
  cBlank(s)
  cHeaderText[path] = (mt, s)
  s

proc cBlank(s: var string) =
  ## C code with its comments (and string contents) blanked: positions and lines stay as they are
  var i = 0
  while i < s.len:
    if s[i] == '/' and i + 1 < s.len and s[i+1] == '*':
      let e = s.find("*/", i + 2)
      let stop = if e < 0: s.len else: e + 2
      for q in i ..< stop:
        if s[q] != '\n': s[q] = ' '
      i = stop
    elif s[i] == '/' and i + 1 < s.len and s[i+1] == '/':
      while i < s.len and s[i] != '\n':
        s[i] = ' '
        inc i
    elif s[i] == '"' or s[i] == '\'':
      let q = s[i]
      var j = i + 1
      while j < s.len and s[j] != q and s[j] != '\n':
        if s[j] == '\\': inc j
        inc j
      # #include "x.h" keeps its name: the include lines are read for it
      var k = i - 1
      while k >= 0 and s[k] != '\n': dec k
      if not s[k + 1 ..< i].strip.startsWith("#"):
        for q2 in i + 1 ..< min(j, s.len): s[q2] = ' '
      i = j + 1
    else: inc i
  # #ifdef __cplusplus / extern "C" { / #endif (and the closing } likewise): not braces of the C code
  var ls = 0
  while ls < s.len:
    var le = s.find('\n', ls)
    if le < 0: le = s.len
    let t = s[ls ..< le].strip
    if t in ["#ifdef __cplusplus", "#if defined(__cplusplus)", "#if defined __cplusplus", "# ifdef __cplusplus"]:
      var q = le + 1
      var n = 0
      while q < s.len and n < 4:
        var qe = s.find('\n', q)
        if qe < 0: qe = s.len
        let u = s[q ..< qe].strip
        if u.startsWith("#endif") or u.startsWith("#else") or u.startsWith("# endif"): break
        for z in q ..< qe: s[z] = ' '
        q = qe + 1
        inc n
    ls = le + 1

func cWordAt(s: string, i: int, w: string): bool =
  i >= 0 and s.continuesWith(w, i) and (i == 0 or s[i-1] notin IdentChars) and
    (i + w.len >= s.len or s[i + w.len] notin IdentChars)

proc cCleanType(t: string): string =
  ## a C type without storage words, attributes and export macros: "extern __attribute__((x)) int" → "int"
  var toks: seq[string]
  var i = 0
  while i < t.len:
    let c = t[i]
    if c in IdentStartChars:
      var j = i
      while j < t.len and t[j] in IdentChars: inc j
      let w = t[i ..< j]
      i = j
      if w.startsWith("__attribute") or w == "__declspec" or w == "__asm__" or w == "__asm" or w.startsWith("__nonnull"):
        # skip its (( … ))
        while i < t.len and t[i] == ' ': inc i
        if i < t.len and t[i] == '(':
          var d = 0
          while i < t.len:
            if t[i] == '(': inc d
            elif t[i] == ')':
              dec d
              if d == 0:
                inc i
                break
            inc i
        continue
      if w in ["extern", "static", "inline", "__inline", "__inline__", "__extension__", "_Noreturn", "register",
               "__restrict", "restrict", "__restrict__", "volatile", "__THROW", "__wur", "__BEGIN_DECLS", "const",
               "__const"]:
        continue
      var caps = w.len > 2
      for ch in w:
        if ch notin {'A'..'Z', '0'..'9', '_'}: caps = false
      if caps and ('_' in w or w.endsWith("API") or w.endsWith("CALL") or w.endsWith("EXPORT")):
        continue                              # SDL_DECLSPEC, SDLCALL, WINAPI …: export and calling macros
      toks.add w
    elif c == '*':
      toks.add "*"
      inc i
    elif c == '[':
      toks.add "*"
      let e = t.find(']', i)
      i = if e < 0: t.len else: e + 1
    else: inc i
  var r = ""
  for w in toks:
    if w == "*": r.add "*"
    else:
      if r.len > 0: r.add ' '
      r.add w
  r

proc cSplitParams(inside: string): (seq[string], bool) =
  ## a C parameter list's parameters ("void" alone: none; "..." sets the second result)
  var parts: seq[string]
  var d = 0
  var cur = ""
  for c in inside:
    if c in {'(', '['}: inc d
    elif c in {')', ']'}: dec d
    if c == ',' and d == 0:
      parts.add cur.strip
      cur = ""
    else: cur.add c
  if cur.strip.len > 0: parts.add cur.strip
  var va = false
  for p in parts:
    if p == "...": va = true
    elif p != "void": result[0].add p.splitWhitespace().join(" ")
  result[1] = va

proc cParamType(p: string): string =
  ## "const char *fmt" → "char*", "char buf[16]" → "char*" (the parameter's name dropped); "fnptr" for
  ## a function pointer
  if "(*" in p or "( *" in p: return "fnptr"
  let t = cCleanType(p)
  var toks = t.replace("*", " * ").splitWhitespace()
  var idents: seq[int]
  for i, w in toks:
    if w != "*": idents.add i
  const TypeWords = ["int", "char", "long", "short", "float", "double", "unsigned", "signed", "void", "_Bool", "bool"]
  if idents.len >= 2:
    let li = idents[^1]
    let w = toks[li]
    let prev = toks[idents[^2]]
    if w notin TypeWords and prev notin ["struct", "enum", "union"]: toks.delete(li)
  var r = ""
  for w in toks:
    if w == "*": r.add "*"
    else:
      if r.len > 0: r.add ' '
      r.add w
  r

type
  CIndex = object               # what one header declares, read once (until it changes)
    mt: times.Time
    decls: Table[string, CProto]
    includes: seq[string]       # its #include lines, as written: <x.h> or "y.h"

var cIndexes: Table[string, CIndex]

proc cClassify(s: string, k: int, name: string, lineOf: proc(i: int): int): CProto =
  ## the declaration that `name` at s[k] (brace depth 0, not a preprocessor line) is part of, if any
  let path = ""
  var j = k + name.len
  while j < s.len and s[j] in {' ', '\t', '\n', '\r'}: inc j
  if j >= s.len: return
  # the statement around it: back to the previous ; { } or the end of a preprocessor line
  var a = k - 1
  while a >= 0 and s[a] notin {';', '{', '}'}:
    if s[a] == '\n':
      var ls = a - 1
      while ls >= 0 and s[ls] != '\n': dec ls
      let prev = s[ls + 1 ..< a].strip
      if prev.startsWith("#") and not prev.endsWith("\\"): break
    dec a
  let before = s[a + 1 ..< k]
  let bs = before.strip
  if s[j] == '(':
    if "=" in before or "return" in before or bs.len == 0 or bs[^1] in {'.', '>', '(', ',', '-', '+', '!', '&', '|'}:
      return
    # a function: up to the matching ) and then ; or {
    var d = 0
    var e = j
    while e < s.len:
      if s[e] == '(': inc d
      elif s[e] == ')':
        dec d
        if d == 0: break
      inc e
    if e >= s.len: return
    let inside = s[j + 1 ..< e]
    if inside.strip.startsWith("*"): return          # (*name)(…): a function pointer
    var tail = e + 1
    while tail < s.len and s[tail] in {' ', '\t', '\n', '\r'}: inc tail
    if tail < s.len and s[tail] notin {';', '{', '_', 'a'..'z', 'A'..'Z'}: return   # a call, not a declaration
    let (ps, va) = cSplitParams(inside)
    var text = (bs & " " & name & "(" & inside.strip & ")").splitWhitespace().join(" ")
    text = text.replace("( ", "(").replace(" )", ")")
    return CProto(path: path, line: lineOf(a + 1 + (before.len - before.strip(trailing = false).len)),
                  kind: "function", text: text, ret: cCleanType(before), params: ps, varargs: va)
  if s[j] in {';', '[', '='}:
    if bs.len == 0 and a >= 0 and s[a] == '}':
      return CProto(path: path, line: lineOf(k), kind: "type", text: "typedef struct { … } " & name & ";")
    if bs.startsWith("typedef"):
      return CProto(path: path, line: lineOf(k), kind: "type", text: (bs & " " & name & ";").splitWhitespace().join(" "))
    if bs.len > 0 and "(" notin bs and "," notin bs and bs[^1] notin {'.', '>', '-', '+', '*' } or
       (bs.len > 0 and bs[^1] == '*' and "(" notin bs):
      return CProto(path: path, line: lineOf(k), kind: "variable", text: (bs & " " & name & ";").splitWhitespace().join(" "),
                    ret: cCleanType(bs))
    return
  if s[j] == '{':
    if bs.endsWith("struct") or bs.endsWith("union") or bs.endsWith("enum"):
      return CProto(path: path, line: lineOf(k), kind: "type", text: bs.splitWhitespace()[^1] & " " & name & " { … }")

proc cIndexOf(s, path: string): CIndex

proc cHeaderIndex(path: string): CIndex =
  ## every declaration in one header (not the ones it includes): functions, macros, types, variables
  var mt: times.Time
  try: mt = getLastModificationTime(path)
  except CatchableError: return
  if path in cIndexes and cIndexes[path].mt == mt: return cIndexes[path]
  result = cIndexOf(cHeaderCode(path), path)
  result.mt = mt
  if cIndexes.len > 400: cIndexes.clear()    # (every header looked at, in every project of a long session)
  cIndexes[path] = result

proc cIndexOf(s, path: string): CIndex =
  ## every declaration in C code (comments blanked): functions, macros, types, variables; and its #includes
  var lineStarts = @[0]
  for i, c in s:
    if c == '\n': lineStarts.add i + 1
  let lineOf = proc(i: int): int =
    var lo = 0
    var hi = lineStarts.high
    while lo < hi:
      let m = (lo + hi + 1) div 2
      if lineStarts[m] <= i: lo = m else: hi = m - 1
    lo
  proc keep(r: var CIndex, name: string, p: CProto) =
    if p.kind.len == 0: return
    var q = p
    q.path = path
    let old = r.decls.getOrDefault(name)
    if old.kind.len == 0 or (old.kind notin ["function", "macro"] and q.kind in ["function", "macro"]):
      r.decls[name] = q
  var i = 0
  var depth = 0
  var lineStart = true
  while i < s.len:
    let c = s[i]
    if lineStart and c in {' ', '\t'}:
      inc i
      continue
    if lineStart and c == '#':
      # a preprocessor line (with its continuations): #define NAME, #include <…>
      var e = i
      while e < s.len:
        if s[e] == '\n' and (e == 0 or s[e - 1] != '\\'): break
        inc e
      let t = s[i + 1 ..< e].strip
      if t.startsWith("define"):
        let r = t[6 .. ^1].strip
        var nj = 0
        while nj < r.len and r[nj] in IdentChars: inc nj
        if nj > 0:
          let nm = r[0 ..< nj]
          let txt = ("#" & t).replace("\\\n", " ").splitWhitespace().join(" ")
          keep(result, nm, CProto(line: lineOf(i), kind: "macro", text: txt))
      elif t.startsWith("include"):
        let rest = t[7 .. ^1].strip
        if rest.len >= 3:
          result.includes.add(if rest[0] == '<': rest[0 .. max(0, rest.find('>'))] else: rest)
      i = e
      continue
    lineStart = c == '\n'
    if c == '{': inc depth
    elif c == '}': depth = max(0, depth - 1)
    elif c in IdentStartChars and (i == 0 or s[i - 1] notin IdentChars):
      var e = i
      while e < s.len and s[e] in IdentChars: inc e
      if depth == 0:
        var j = e
        while j < s.len and s[j] in {' ', '\t', '\n', '\r'}: inc j
        if j < s.len and s[j] in {'(', ';', '[', '=', '{'}:
          let nm = s[i ..< e]
          if nm notin ["if", "while", "for", "switch", "return", "sizeof", "typedef", "struct", "enum", "union",
                       "extern", "static", "const", "__attribute__", "__extension__", "__asm__", "__THROW"]:
            keep(result, nm, cClassify(s, i, nm, lineOf))
      i = e
      continue
    inc i

proc cFindIn(path, name: string, dirs: seq[string], depth: int, seen: var HashSet[string]): CProto =
  ## the declaration of `name` in this header or the ones it includes
  if path in seen or seen.len > 300 or depth > 8: return
  seen.incl path
  let idx = cHeaderIndex(path)
  if name in idx.decls: return idx.decls[name]
  let here = parentDir(path)
  for incName in idx.includes:
    let hp = cFindHeader(incName, dirs, here)
    if hp.len > 0:
      let r = cFindIn(hp, name, dirs, depth + 1, seen)
      if r.kind.len > 0: return r

proc cDeclFor(header, cname: string, dirs: seq[string], fromDir: string): (CProto, string) =
  ## the C declaration of `cname` in `header` (and what it includes); the second result: why not
  let hp = cFindHeader(header, dirs, fromDir)
  if hp.len == 0: return (CProto(), "header " & header & " not found (looked in " & $dirs.len & " folders)")
  var seen: HashSet[string]
  let r = cFindIn(hp, cname, dirs, 0, seen)
  if r.kind.len == 0: return (r, "no declaration of " & cname & " in " & extractFilename(hp) &
                                 (if seen.len > 1: " or the " & $(seen.len - 1) & " headers it includes" else: ""))
  (r, "")

proc ffiCDecl(d: NimFfi, path: string, lines: seq[string], wide: bool): (CProto, string)
