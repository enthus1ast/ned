## C checks from ned's own engine, while you type and with no compiler: an #include nothing of which is used, a
## struct whose fields ordered by size take less room, a printf- or scanf-style format against its arguments. Only
## what the engine is sure of: where it cannot be (a name it cannot place, a type it does not know, a format made by
## a macro) it says nothing. Pure procs over the engine's index (cindex) and the file's text; the editor puts what
## they find on the buffer, with their fixes (c/cengine.nim)

import std/[strutils, tables, sets, algorithm]
when defined(windows): import ../sys/winos as os   # (std/os, with '/' in the paths it makes)
else: import std/os
import cindex

type
  CkEdit* = object
    line*, col*, eline*, ecol*: int   # what it replaces (the end not included)
    text*: string
  CkFix* = object
    title*: string
    edits*: seq[CkEdit]
  CkProblem* = object
    line*, col*, eline*, ecol*: int
    sev*: int                         # 2 warning · 3 information · 4 hint
    rule*, msg*: string
    fixes*: seq[CkFix]

const
  CkBuiltins = ["__func__", "__FUNCTION__", "__PRETTY_FUNCTION__", "__LINE__", "__FILE__", "__DATE__", "__TIME__",
    "__COUNTER__", "__VA_ARGS__", "__VA_OPT__", "__has_include", "__has_include_next", "__has_attribute",
    "__has_builtin", "__has_feature", "__has_c_attribute", "_Generic", "__typeof__", "__typeof", "typeof",
    "typeof_unqual", "__alignof__", "_Alignof", "alignof", "_Alignas", "alignas", "__extension__", "__restrict",
    "__restrict__", "__inline", "__inline__", "__volatile__", "__volatile", "__const", "__signed__", "__signed",
    "__int128", "__label__", "__real__", "__imag__", "__auto_type", "_Static_assert", "static_assert", "_Pragma",
    "__asm__", "__asm", "asm", "__attribute__", "__attribute", "__declspec", "thread_local", "_Thread_local",
    "_Noreturn", "noreturn", "_BitInt", "constexpr", "nullptr", "_Float16", "_Float32", "_Float64", "_Float128",
    "__float128", "_Decimal32", "_Decimal64", "_Decimal128"]
  CkFeatureMacros = ["_GNU_SOURCE", "_DEFAULT_SOURCE", "_BSD_SOURCE", "_SVID_SOURCE", "_POSIX_SOURCE",
    "_POSIX_C_SOURCE", "_XOPEN_SOURCE", "_XOPEN_SOURCE_EXTENDED", "_ISOC99_SOURCE", "_ISOC11_SOURCE",
    "_LARGEFILE_SOURCE", "_LARGEFILE64_SOURCE", "_FILE_OFFSET_BITS", "_TIME_BITS", "_REENTRANT", "_THREAD_SAFE",
    "_FORTIFY_SOURCE", "_DARWIN_C_SOURCE", "_NETBSD_SOURCE", "__EXTENSIONS__", "_ALL_SOURCE",
    "WIN32_LEAN_AND_MEAN", "NOMINMAX", "UNICODE", "_UNICODE", "_WIN32_WINNT", "WINVER", "_CRT_SECURE_NO_WARNINGS",
    "NDEBUG"]
    ## macros that change what other headers declare: a header that defines one is never "not used"
  CkHeaderExts = [".h", ".hh", ".hpp", ".hxx", ".h++"]

func ckShort(s: string): string =
  ## an argument as a message shows it: on one line, not too long
  result = s.strip.replace("\n", " ")
  if result.len > 32: result = result[0 ..< 30] & "…"

func ckSilenced(lines: seq[string], l: int, rule: string): bool =
  ## `// ned: ignore` (or `ned: ignore[rule]`) in a comment on the line
  if l < 0 or l >= lines.len: return false
  let t = lines[l]
  let k = t.find("ned: ignore")
  if k < 0: return false
  let r = t[k + "ned: ignore".len .. ^1]
  not r.startsWith("[") or rule in r[0 ..< max(0, r.find(']'))]

# ── an #include nothing of which is used ──

proc ckUnusedIncludes*(f: CxFile): seq[CkProblem] =
  ## the #includes of a C file nothing from which is used: no name the file (or a project header it includes) uses is
  ## declared by the header or by the headers it includes — for headers the engine read whole only, never one that
  ## defines a feature macro or only macros, and not at all when the file uses a name the engine cannot place
  if f == nil or f.cpp or f.lines.len == 0 or f.incAt.len == 0: return
  cxUsedNames(f)
  let files = cxClosure(f)
  # every name the engine can place: what the files declare (this one's locals, parameters, labels too), the
  # compiler's macros, the -D flags'
  var known: HashSet[string]
  for g in files:
    for s in g.syms: known.incl s.name
  for k in cxPredef.keys: known.incl k
  for d in cxDefines:
    if d.len > 2: known.incl d[2 .. ^1].split('=')[0].split('(')[0]
  for n in f.liveNames:
    if n in known or n in CxKeywords or n in CkBuiltins or n.startsWith("__builtin_") or n.startsWith("__sync_") or
       n.startsWith("__atomic_"): continue
    return                     # (a name it cannot place: a header might bring it in a way the engine does not see)
  # the names used: here, and in the project's headers it includes (one may need what an earlier #include brings)
  var used = f.names.toHashSet
  var projects: seq[CxFile]
  for g in files:
    if g != f and not cxIsSystem(g.path):
      projects.add g
      for n in g.names: used.incl n
  # which files declare each of them
  var declares: Table[string, seq[pointer]]
  for g in files:
    if g == f: continue
    for s in g.syms:
      if s.kind in {cxParam, cxLocal, cxLabel} or s.name notin used: continue
      let p = cast[pointer](g)
      declares.withValue(s.name, xs):
        if xs[].len == 0 or xs[][^1] != p: xs[].add p
      do: declares[s.name] = @[p]
  for ic in f.incAt:
    if not ic.known or not ic.top or ic.file == nil or ic.line >= f.lines.len: continue
    if ic.file.path.splitFile.ext.toLowerAscii notin CkHeaderExts: continue
    # what it brings: the header and the headers it includes, read whole
    var sub: HashSet[pointer]
    var stack = @[ic.file]
    var whole = true
    var declOnlyMacros = true
    var feature = false
    while stack.len > 0:
      let g = stack.pop()
      if cast[pointer](g) in sub: continue
      sub.incl cast[pointer](g)
      if g.missing > 0: whole = false
      let sys = cxIsSystem(g.path)
      for s in g.syms:
        if s.kind == cxMacro:
          if s.name in CkFeatureMacros and not sys: feature = true      # (a system header's are its own business)
        elif s.kind notin {cxParam, cxLocal, cxLabel}: declOnlyMacros = false
      for d in g.deps: stack.add d
    if not whole or declOnlyMacros or feature: continue
    # (used: a name of this file's, or of a project header it does not bring itself, that it declares)
    proc declared(n: string): bool =
      declares.withValue(n, ps):
        for p in ps[]:
          if p in sub: return true
    var isUsed = false
    for n in f.names:
      if declared(n):
        isUsed = true
        break
    if not isUsed:
      for g in projects:
        if cast[pointer](g) in sub: continue
        for n in g.names:
          if declared(n):
            isUsed = true
            break
        if isUsed: break
    if isUsed or ckSilenced(f.lines, ic.line, "c-unused-include"): continue
    let t = f.lines[ic.line]
    var a = t.find('<')
    if a < 0: a = t.find('"')
    if a < 0: a = 0
    var e = if t[a] == '<': t.find('>', a + 1) + 1 elif t[a] == '"': t.find('"', a + 1) + 1 else: t.len
    if e <= a: e = t.len
    let del = if ic.line + 1 < f.lines.len: CkEdit(line: ic.line, col: 0, eline: ic.line + 1, ecol: 0)
              else: CkEdit(line: ic.line, col: 0, eline: ic.line, ecol: t.len)
    result.add CkProblem(line: ic.line, col: a, eline: ic.line, ecol: e, sev: 2, rule: "c-unused-include",
                         msg: "nothing from " & ic.name & " is used here",
                         fixes: @[CkFix(title: "Remove the #include", edits: @[del])])

# ── a struct whose fields, ordered by size, take less room ──

type CkUnit = object                  # a field's declaration (`int x, y;` is one) and the comment lines above it
  lines: seq[string]
  line: int
  size, align: int
  gap: bool                           # (a blank line before it)

func ckCommentOnly(t: string, inBlock: var bool): bool =
  ## is the line only a comment (or blank)? inBlock: in a /* … */ that goes on (and after it)
  var i = 0
  result = true
  while i < t.len:
    if inBlock:
      let e = t.find("*/", i)
      if e < 0: return
      inBlock = false
      i = e + 2
      continue
    if t[i] in Whitespace:
      inc i
      continue
    if t.continuesWith("//", i): return
    if t.continuesWith("/*", i):
      inBlock = true
      i += 2
      continue
    return false

func ckCode(t: string): string =
  ## a line without its comments and with its strings blanked (same length): to count `;` `{` `}` in
  result = t
  var i = 0
  while i < result.len:
    if result.continuesWith("//", i):
      for k in i ..< result.len: result[k] = ' '
      return
    if result.continuesWith("/*", i):
      let e = result.find("*/", i + 2)
      let stop = if e < 0: result.len else: e + 2
      for k in i ..< stop: result[k] = ' '
      i = stop
      continue
    if result[i] in {'"', '\''}:
      let q = result[i]
      var k = i + 1
      while k < result.len and result[k] != q:
        if result[k] == '\\': inc k
        inc k
      for x in i + 1 ..< min(k, result.len): result[x] = ' '
      i = k + 1
      continue
    inc i

proc ckPositional(texts: seq[seq[string]], names: seq[string]): bool =
  ## is one of these types initialized somewhere in the texts with a brace list in order (`= { 1, 2 }`, not
  ## `{ .x = 1 }`) — whose meaning a change of the fields' order would change?
  for ls in texts:
    for l, raw in ls:
      let t = ckCode(raw)
      for n in names:
        var k = t.find(n)
        while k >= 0:
          let before = k == 0 or t[k - 1] notin IdentChars
          let after = k + n.len >= t.len or t[k + n.len] notin IdentChars
          if before and after:
            # the statement on from here: `= {`, or `(T){` (a compound literal), up to its `;`
            var line = l
            var c = k + n.len
            var steps = 0
            var sawEq = false
            var literal = t[k + n.len .. ^1].strip.startsWith(")")
            block scan:
              while line < ls.len and steps < 12:
                let u = if line == l: t else: ckCode(ls[line])
                while c < u.len:
                  let ch = u[c]
                  if ch == ';': break scan
                  if ch == '=' and not (c + 1 < u.len and u[c + 1] == '='): sawEq = true
                  if ch in {'(', ')'} and not sawEq and not (literal and ch == ')'): literal = false
                  if ch == '{':
                    if not sawEq and not literal: break scan
                    # its first element
                    var l2 = line
                    var c2 = c + 1
                    while l2 < ls.len:
                      let v = if l2 == line: u else: ckCode(ls[l2])
                      while c2 < v.len and v[c2] in Whitespace: inc c2
                      if c2 < v.len:
                        if v[c2] notin {'.', '}', '['}: return true
                        break scan
                      inc l2
                      c2 = 0
                    break scan
                  inc c
                inc line
                c = 0
                inc steps
          k = t.find(n, k + 1)

proc ckPadding*(f: CxFile, extraTexts: seq[seq[string]] = @[]): seq[CkProblem] =
  ## the structs of a C file whose fields, ordered by alignment (the largest first), take less room — with the
  ## fix that orders them, a field's comments with it. Not for bit-fields, a flexible array member, packed or
  ## aligned structs, a struct with a struct or union inside it, one a brace list fills in order in the files the
  ## engine sees (extraTexts: more of them, as lines), nor when the first field is a struct (the "base" of a C
  ## "derived" struct: it stays first)
  if f == nil or f.cpp or f.lines.len == 0: return
  let files = cxClosure(f)
  var packFile = false
  for t in f.lines:
    if t.strip.startsWith("#") and "pragma" in t and "pack" in t: packFile = true
  if packFile: return
  var texts = @[f.lines]
  var textsRead = false
  for s in f.syms:
    if s.kind != cxStruct or not s.isDef or s.name.startsWith("(anonymous") or s.endLine <= s.line or
       s.endLine >= f.lines.len: continue
    if ckSilenced(f.lines, s.line, "c-padding"): continue
    let tag = s.name
    # its fields, in order
    var fields: seq[CxSym]
    for x in f.syms:
      if x.kind == cxField and x.owner == tag and x.line > s.line and x.line < s.endLine: fields.add x
    if fields.len < 2: continue
    fields.sort(proc(a, b: CxSym): int = cmp((a.line, a.col), (b.line, b.col)))
    var skip = false
    for x in fields:
      if x.bits.len > 0 or x.dims == "[]" or x.dims.startsWith("[]"): skip = true
    if skip: continue
    # the body: `{` closing its line, `}` opening the last, nothing but fields, comments and blank lines between
    var open = -1
    for l in s.line .. s.endLine - 1:
      let c = ckCode(f.lines[l])
      let k = c.find('{')
      if k >= 0:
        if c[k + 1 .. ^1].strip.len > 0: skip = true
        open = l
        break
    if open < 0 or skip: continue
    let closeT = ckCode(f.lines[s.endLine]).strip
    if not closeT.startsWith("}"): continue
    var spans = false
    for l in s.line .. min(s.endLine + 1, f.lines.high):
      let low = f.lines[l].toLowerAscii
      if "packed" in low or "aligned" in low or "alignas" in low or "__declspec" in low: spans = true
    if spans: continue
    var units: seq[CkUnit]
    var pending: seq[string]
    var gap = false
    var inBlock = false
    var fieldLines: HashSet[int]
    for x in fields: fieldLines.incl x.line
    for l in open + 1 .. s.endLine - 1:
      let raw = f.lines[l]
      let wasBlock = inBlock
      if raw.strip.len == 0 and not wasBlock:
        if pending.len == 0: gap = true
        else: pending.add raw
        continue
      if raw.strip.startsWith("#"):
        skip = true
        break
      if l in fieldLines:
        let c = ckCode(raw)
        if c.count(';') != 1 or '{' in c or '}' in c:
          skip = true
          break
        var u = CkUnit(lines: pending & @[raw], line: l, gap: gap)
        var off = 0
        var al = 1
        for x in fields:
          if x.line != l: continue
          var typ = x.typ
          if x.dims.len > 0 and typ.endsWith("*"): typ = typ[0 ..< typ.high].strip
          let (ok, sz, a) = cxSizeAlign(files, typ, x.dims)
          if not ok:
            skip = true
            break
          off = (off + a - 1) div a * a + sz
          al = max(al, a)
        if skip: break
        u.size = off
        u.align = al
        units.add u
        pending.setLen(0)
        gap = false
        continue
      var ib = wasBlock
      if ckCommentOnly(raw, ib):
        inBlock = ib
        pending.add raw
        continue
      skip = true                                     # (code that is not a field: left alone)
      break
    if skip or units.len < 2: continue
    let trailing = pending                             # (comment lines after the last field: stay last)
    let (ok, size, _, _) = cxRecordLayout(files, tag, false)
    if not ok: continue
    proc layout(us: seq[CkUnit]): int =
      ## the size in bytes the struct would have with its fields in this order: each one at the next multiple of its
      ## alignment, and the whole rounded up to the largest alignment
      var off = 0
      var al = 1
      for u in us:
        off = (off + u.align - 1) div u.align * u.align + u.size
        al = max(al, u.align)
      (off + al - 1) div al * al
    if layout(units) != size: continue                 # (the engine's reading of it and the layout disagree)
    # a struct (or union) first: stays first
    var keep = 0
    let ft = fields[0].typ.strip
    if (ft.startsWith("struct ") or ft.startsWith("union ")) and '*' notin ft: keep = 1
    var order: seq[int]
    for k in keep ..< units.len: order.add k
    order.sort(proc(x, y: int): int =
      result = cmp(units[y].align, units[x].align)
      if result == 0: result = cmp(x, y))
    var sorted: seq[CkUnit]
    for k in 0 ..< keep: sorted.add units[k]
    for k in order: sorted.add units[k]
    let better = layout(sorted)
    if better >= size: continue
    # (and only when no brace list fills it in order: its names — the tag, the typedefs of it, the structs that
    # have it as a field)
    var names = @["struct " & tag]
    for g in files:
      for x in g.syms:
        if x.kind == cxTypedef and (x.typ == "struct " & tag or x.name == tag): names.add x.name
    for g in files:
      for x in g.syms:
        if x.kind == cxField and '*' notin x.typ and x.typ.strip in names and x.owner != tag:
          names.add x.owner
          names.add "struct " & x.owner
    if not textsRead:
      textsRead = true
      for g in files:
        if g != f and not cxIsSystem(g.path):
          try: texts.add readFile(g.path).splitLines
          except CatchableError: discard
      for t in extraTexts: texts.add t
    if ckPositional(texts, names): continue
    var outp: seq[string]
    for i, u in sorted:
      if i > 0 and u.gap: outp.add ""
      outp.add u.lines
    for t in trailing: outp.add t
    let first = open + 1
    let last = s.endLine - 1
    let shown = if s.text.startsWith("struct " & tag): "struct " & tag else: tag      # (a typedef's name alone)
    let col = max(0, f.lines[s.line].find(tag, s.col))
    result.add CkProblem(line: s.line, col: col, eline: s.line, ecol: col + tag.len, sev: 4, rule: "c-padding",
                         msg: shown & ": " & $size & " bytes, " & $better & " with its fields ordered by size",
                         fixes: @[CkFix(title: "Order the fields",
                                        edits: @[CkEdit(line: first, col: 0, eline: last,
                                                        ecol: f.lines[last].len, text: outp.join("\n"))])])

# ── printf and scanf formats against their arguments ──

type
  CkArg = object
    text: string
    line, col, eline, ecol: int
  CkConv = object
    spec: string                      # as written: %-08.3ld
    length: string                    # hh h l ll j z t L q
    conv: char
    stars: int                        # `*` widths and precisions: an int argument each
    noArg: bool                       # %m, scanf's %*d
    at: seq[(int, int)]               # where each of the spec's characters is (line, col); (-1, -1): split up
  CkTy = enum tyUnknown, tyInt, tyUnsigned, tyLong, tyULong, tyLongLong, tySizeT, tyInt64, tyDouble, tyLongDouble,
              tyString, tyPtr, tyStruct, tyChar

const CkFamily = [("printf", 0, false), ("fprintf", 1, false), ("sprintf", 1, false), ("snprintf", 2, false),
  ("dprintf", 1, false), ("asprintf", 1, false), ("syslog", 1, false), ("warn", 0, false), ("warnx", 0, false),
  ("err", 1, false), ("errx", 1, false), ("scanf", 0, true), ("fscanf", 1, true), ("sscanf", 1, true)]

proc ckCallArgs(lines: seq[string], line, open: int): (bool, seq[CkArg]) =
  ## the arguments of the call whose `(` is at line:open, as written (comments left out), and whether its `)` is
  ## there
  var d = 0
  var cur = CkArg(line: -1)
  var inBlock = false
  var l = line
  var i = open
  proc finish(r: var seq[CkArg], c: var CkArg, l, i: int) =
    ## ends the argument being read at line `l`, column `i`: its text is trimmed, it is added to `r`, and an empty one
    ## is started for the next
    c.text = c.text.strip
    c.eline = l
    c.ecol = i
    r.add c
    c = CkArg(line: -1)
  while l < lines.len and l <= line + 30:
    let t = lines[l]
    while i < t.len:
      if inBlock:
        let e = t.find("*/", i)
        if e < 0:
          i = t.len
          break
        inBlock = false
        i = e + 2
        continue
      let c = t[i]
      if c == '/' and i + 1 < t.len and t[i + 1] == '/': break
      if c == '/' and i + 1 < t.len and t[i + 1] == '*':
        inBlock = true
        i += 2
        continue
      if d >= 1 and cur.line < 0 and c notin Whitespace and not (c == ')' and d == 1) and not (c == ',' and d == 1):
        cur.line = l
        cur.col = i
      if c in {'"', '\''}:
        var j = i + 1
        while j < t.len and t[j] != c:
          if t[j] == '\\': inc j
          inc j
        cur.text.add t[i .. min(j, t.high)]
        i = j + 1
        continue
      if c in {'(', '[', '{'}:
        inc d
        if d > 1: cur.text.add c
      elif c in {')', ']', '}'}:
        dec d
        if d == 0:
          if cur.line >= 0 or result[1].len > 0: finish(result[1], cur, l, i)
          result[0] = true
          return
        cur.text.add c
      elif c == ',' and d == 1: finish(result[1], cur, l, i)
      elif c == ';' and d <= 1: return
      elif d >= 1: cur.text.add c
      inc i
    if d >= 1: cur.text.add ' '
    inc l
    i = 0

proc ckFormat(lines: seq[string], a: CkArg): (bool, string, seq[(int, int)]) =
  ## a format argument made only of string literals ("…" "…", on several lines too): its text (escapes as written)
  ## and where each of its characters is
  var l = a.line
  var i = a.col
  var any = false
  var inBlock = false
  while l <= a.eline and l < lines.len:
    let t = lines[l]
    let stop = if l == a.eline: min(a.ecol, t.len) else: t.len
    while i < stop:
      if inBlock:
        let e = t.find("*/", i)
        if e < 0:
          i = stop
          break
        inBlock = false
        i = e + 2
        continue
      let c = t[i]
      if c in Whitespace:
        inc i
        continue
      if t.continuesWith("//", i): break
      if t.continuesWith("/*", i):
        inBlock = true
        i += 2
        continue
      if c != '"': return (false, "", @[])                 # (a macro, a variable, L"…": not known for sure)
      any = true
      inc i
      while i < t.len and t[i] != '"':
        if t[i] == '\\' and i + 1 < t.len:
          result[1].add t[i .. i + 1]
          result[2].add (l, i)
          result[2].add (l, i + 1)
          i += 2
          continue
        result[1].add t[i]
        result[2].add (l, i)
        inc i
      inc i
    inc l
    i = 0
  result[0] = any

proc ckConvs(fmt: string, at: seq[(int, int)], scan: bool): (bool, seq[CkConv]) =
  ## a format's conversions — (false, …) when it numbers its arguments (%1$d): not checked
  var i = 0
  result[0] = true
  while i < fmt.len:
    if fmt[i] != '%':
      inc i
      continue
    let st = i
    inc i
    if i < fmt.len and fmt[i] == '%':
      inc i
      continue
    var c = CkConv()
    var j = i
    while j < fmt.len and fmt[j] in Digits: inc j
    if j < fmt.len and fmt[j] == '$' and j > i: return (false, @[])
    if scan and i < fmt.len and fmt[i] == '*':
      c.noArg = true
      inc i
    while not scan and i < fmt.len and fmt[i] in {'-', '+', ' ', '#', '0', '\''}: inc i
    if not scan and i < fmt.len and fmt[i] == '*':
      inc c.stars
      inc i
    while i < fmt.len and fmt[i] in Digits: inc i
    if not scan and i < fmt.len and fmt[i] == '.':
      inc i
      if i < fmt.len and fmt[i] == '*':
        inc c.stars
        inc i
      while i < fmt.len and fmt[i] in Digits: inc i
    let ls = i
    for m in ["hh", "ll", "h", "l", "j", "z", "t", "L", "q"]:
      if fmt.continuesWith(m, i):
        i += m.len
        break
    c.length = fmt[ls ..< i]
    if i >= fmt.len: return (false, @[])                     # (a % at the end: the compiler says it)
    c.conv = fmt[i]
    if c.conv == '[' and scan:
      var k = i + 1
      if k < fmt.len and fmt[k] == '^': inc k
      if k < fmt.len and fmt[k] == ']': inc k
      while k < fmt.len and fmt[k] != ']': inc k
      i = k
    if c.conv notin {'d', 'i', 'o', 'u', 'x', 'X', 'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A', 'c', 's', 'p', 'n', 'm',
                     '[', 'C', 'S', 'b', 'B'}:
      return (false, @[])                                    # (one the engine does not know: not checked)
    if c.conv == 'm': c.noArg = true
    c.spec = fmt[st .. min(i, fmt.high)]
    for k in st .. min(i, fmt.high): c.at.add (if k < at.len: at[k] else: (-1, -1))
    result[1].add c
    inc i

const CkTypeWords = ["void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "bool",
  "_Complex"]

proc ckBaseOf(files: seq[CxFile], typ: string): (string, int) =
  ## a type's base words and pointer depth, through typedefs (`Score` → int, `charp` → char, 1) — "" when a word
  ## of it is not known (an export macro that is not defined empty, an anonymous union)
  if '{' in typ: return ("", 0)
  var (b, st) = cxStrip(typ)
  b = cxDropMarkers(files, b)
  for _ in 0 .. 6:
    for kw in ["struct ", "union ", "enum "]:
      if b.startsWith(kw): return (b, st)
    let ws = b.splitWhitespace
    if ws.len > 1:
      for w in ws:
        if w notin CkTypeWords: return ("", 0)
      return (b, st)
    if b in ["size_t", "ssize_t", "int64_t", "uint64_t", "int32_t", "uint32_t", "int16_t", "uint16_t", "int8_t",
             "uint8_t", "intptr_t", "uintptr_t", "ptrdiff_t", "off_t", "time_t", "wchar_t"]: return (b, st)
    let (g, k) = cxFindSym(files, b, {cxTypedef})
    if g == nil: return (b, st)
    let (b2, s2) = cxStrip(g.syms[k].typ)
    if b2 == b: return (b, st)
    b = b2
    st += s2
  (b, st)

proc ckArgType(f: CxFile, files: seq[CxFile], a: string, line: int): (CkTy, string) =
  ## what kind of value an argument is, when the engine is sure — and how to call it in a message
  let t = a.strip
  if t.len == 0: return (tyUnknown, "")
  if t[0] == '"' and t.endsWith("\""): return (tyString, "a string")
  if t[0] == '\'' and t.endsWith("'"): return (tyInt, "a character (an int)")
  if t[0] in Digits or (t.len > 1 and t[0] in {'-', '+', '.'} and t[1] in Digits):
    let low = t.toLowerAscii.strip(chars = {'-', '+', ' '})
    if not low.allCharsInSet({'0'..'9', 'a'..'f', 'x', 'u', 'l', '.', 'p', '+', '-', '\''}): return (tyUnknown, "")
    let hex = low.startsWith("0x")
    if (not hex and ('.' in low or 'e' in low)) or (hex and 'p' in low):
      return (if low.endsWith("l"): (tyLongDouble, "a long double") else: (tyDouble, "a double"))
    var e = low.len
    var u = false
    var ls = 0
    while e > 0 and low[e - 1] in {'u', 'l'}:
      if low[e - 1] == 'u': u = true else: inc ls
      dec e
    return case ls
           of 0: (if u: (tyUnsigned, "an unsigned int") else: (tyInt, "an int"))
           of 1: (if u: (tyULong, "an unsigned long") else: (tyLong, "a long"))
           else: (tyLongLong, "a long long")
  # a variable, a field, a call, a cast: its type, when the engine knows it
  if not t.allCharsInSet(IdentChars + {'.', '-', '>', '[', ']', '(', ')', '*', '&', ' '}): return (tyUnknown, "")
  if f.cpp: return (tyUnknown, "")
  let ty = cxExprType(f, t, line)
  if ty.len == 0: return (tyUnknown, "")
  if ty == "fn:": return (tyPtr, "a function")
  if "(*)" in ty: return (tyPtr, "a function pointer")
  if '(' in ty: return (tyUnknown, "")
  let (b, st) = ckBaseOf(files, ty)
  if b.len == 0: return (tyUnknown, "")
  let shown = cxDropMarkers(files, cxStrip(ty)[0]) & (if st > 0: " " & "*".repeat(st) else: "")
  let an = (if shown.len > 0 and shown[0] in {'a', 'e', 'i', 'o', 'u'}: "an " else: "a ") & shown
  if st > 0:
    if st == 1 and b in ["char", "signed char", "unsigned char"]: return (tyString, an)
    return (tyPtr, an)
  if b.startsWith("struct ") or b.startsWith("union "): return (tyStruct, an)
  if b.startsWith("enum "): return (tyInt, "an enum")
  case b
  of "char", "signed char", "unsigned char": (tyChar, "a char")
  of "short", "short int", "unsigned short", "unsigned short int", "int", "signed", "signed int", "_Bool", "bool",
     "int32_t", "int16_t", "int8_t", "uint16_t", "uint8_t": (tyInt, "an " & (if b == "_Bool" or b == "bool": "int (bool)"
                                                                            else: "int"))
  of "unsigned", "unsigned int", "uint32_t": (tyUnsigned, "an unsigned int")
  of "long", "long int", "signed long", "long signed int": (tyLong, "a long")
  of "unsigned long", "unsigned long int", "long unsigned int": (tyULong, "an unsigned long")
  of "long long", "long long int", "unsigned long long", "unsigned long long int": (tyLongLong, "a long long")
  of "size_t": (tySizeT, "a size_t")
  of "int64_t", "uint64_t": (tyInt64, "an " & b)
  of "float", "double": (tyDouble, "a " & b)
  of "long double": (tyLongDouble, "a long double")
  else: (tyUnknown, "")

# whether a printf conversion letter is one that takes an integer (d i o u x X)
func ckIntConv(c: char): bool = c in {'d', 'i', 'o', 'u', 'x', 'X'}

func ckTakes(c: CkConv): string =
  ## what a printf conversion takes, in words
  let uns = c.conv in {'o', 'u', 'x', 'X', 'b', 'B'}
  case c.conv
  of 'd', 'i', 'o', 'u', 'x', 'X', 'b', 'B':
    case c.length
    of "l": (if uns: "an unsigned long" else: "a long")
    of "ll", "q": (if uns: "an unsigned long long" else: "a long long")
    of "z": "a size_t"
    of "j": "an intmax_t"
    of "t": "a ptrdiff_t"
    else: (if uns: "an unsigned int" else: "an int")
  of 'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A': (if c.length == "L": "a long double" else: "a double")
  of 'c': "an int (a character)"
  of 's': "a string"
  of 'p': "a pointer"
  else: "something else"
# whether a printf conversion letter is one that takes a floating-point number
func ckFloatConv(c: char): bool = c in {'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A'}

proc ckCall(f: CxFile, files: seq[CxFile], name: string, fi: int, scan: bool, args: seq[CkArg], line, col: int):
    seq[CkProblem] =
  ## one printf- (scanf-) family call: its format against its arguments
  let fa = args[fi]
  let (isLit, fmt, at) = ckFormat(f.lines, fa)
  if not isLit: return
  let (plain, convs) = ckConvs(fmt, at, scan)
  if not plain: return
  var want = 0
  for c in convs: want += c.stars + (if c.noArg: 0 else: 1)
  let given = args.len - fi - 1
  proc where(a: CkArg): (int, int, int, int) =
    ## where to mark an argument, as line, column, end line, end column — one that runs over several lines is marked to
    ## the end of its first line
    (a.line, a.col, a.line, (if a.eline == a.line: a.ecol else: f.lines[a.line].len))
  if given < want:
    var missing = ""
    var n = 0
    for c in convs:
      n += c.stars + (if c.noArg: 0 else: 1)
      if n > given and missing.len == 0: missing = c.spec
    let (l0, c0, l1, c1) = where(fa)
    return @[CkProblem(line: l0, col: c0, eline: l1, ecol: c1, sev: 2, rule: "c-format",
                       msg: missing & " has no argument: the format wants " & $want & ", " & $given &
                            (if given == 1: " follows it" else: " follow it"))]
  if given > want:
    let x = args[fi + 1 + want]
    let (l0, c0, l1, c1) = where(x)
    result.add CkProblem(line: l0, col: c0, eline: l1, ecol: c1, sev: 2, rule: "c-format",
                         msg: "the format wants " & $want & " argument" & (if want == 1: "" else: "s") & ", " & $given &
                              " follow it — " & (if given - want == 1: "this one is" else: "these are") &
                              (if scan: " not read into" else: " not printed"))
  # each conversion against its argument
  var ai = fi + 1
  for c in convs:
    for _ in 1 .. c.stars:
      if ai < args.len:
        let (ty, what) = ckArgType(f, files, args[ai].text, args[ai].line)
        if ty in {tyDouble, tyLongDouble, tyString, tyPtr, tyStruct}:
          let (l0, c0, l1, c1) = where(args[ai])
          result.add CkProblem(line: l0, col: c0, eline: l1, ecol: c1, sev: 2, rule: "c-format",
                               msg: "a * in " & c.spec & " takes an int, " & args[ai].text.ckShort & " is " & what)
      inc ai
    if c.noArg: continue
    if ai >= args.len: break
    let a = args[ai]
    inc ai
    if c.conv in {'n', 'C', 'S'} or c.length in ["j", "t", "q"]: continue
    let (ty, what) = ckArgType(f, files, a.text, a.line)
    if ty == tyUnknown: continue
    var takes = ""                              # (what the conversion takes, when the argument is not that)
    var better = ""                             # (the conversion the argument takes)
    let lp64 = cxPredef.getOrDefault("__SIZEOF_LONG__", "8") == "8"
    if scan:
      # scanf: where to put what it reads
      if ty notin {tyPtr, tyString}:
        let ident = a.text.strip.allCharsInSet(IdentChars) and a.text.strip.len > 0
        let (l0, c0, l1, c1) = where(a)
        var p = CkProblem(line: l0, col: c0, eline: l1, ecol: c1, sev: 2, rule: "c-format",
                          msg: c.spec & " needs where to put what it reads: &" & a.text.strip &
                               " (" & a.text.strip.ckShort & " is " & what & ")")
        if ident and ty notin {tyString}:
          p.fixes.add CkFix(title: "Pass &" & a.text.strip,
                            edits: @[CkEdit(line: a.line, col: a.col, eline: a.line, ecol: a.col, text: "&")])
        result.add p
        continue
      if ty == tyString and c.conv notin {'s', '[', 'c'}:
        takes = "a pointer to a number"
      elif ty == tyPtr:
        let (b, st) = ckBaseOf(files, cxExprType(f, a.text.strip, a.line))
        if st == 1:
          if c.conv in {'f', 'e', 'g', 'a', 'E', 'G', 'F', 'A'}:
            if b == "double" and c.length == "": (takes, better) = ("a float *", "%l" & $c.conv)
            elif b == "float" and c.length == "l": (takes, better) = ("a double *", "%" & $c.conv)
            elif b in ["int", "long", "unsigned", "unsigned int", "short", "char"]: (takes, better) = ("a float *", "%d")
          elif ckIntConv(c.conv) and c.length == "":
            if b in ["double", "float"]: (takes, better) = ("an int *", (if b == "double": "%lf" else: "%f"))
            elif b in ["long", "long int"] and lp64: (takes, better) = ("an int *", "%l" & $c.conv)
          elif ckIntConv(c.conv) and c.length == "l":
            if b in ["int", "unsigned", "unsigned int"]: (takes, better) = ("a long *", "%" & $c.conv)
            elif b in ["double", "float"]: (takes, better) = ("a long *", (if b == "double": "%lf" else: "%f"))
      if takes.len == 0: continue
    else:
      case c.conv
      of 'd', 'i', 'o', 'u', 'x', 'X', 'b', 'B':
        let L = c.length
        let base = if c.conv in {'d', 'i'}: "d" else: $c.conv
        if ty == tyDouble or ty == tyLongDouble: (takes, better) = ("an int", (if ty == tyDouble: "%f" else: "%Lf"))
        elif ty == tyString: (takes, better) = ("an int", "%s")
        elif ty == tyPtr: (takes, better) = ("an int", "%p")
        elif ty == tyStruct: takes = "an int"
        elif L in ["", "h", "hh"]:
          if ty == tyLong or ty == tyULong: (takes, better) = ("an int", "%l" & base)
          elif ty == tyLongLong: (takes, better) = ("an int", "%ll" & base)
          elif ty == tySizeT and lp64: (takes, better) = ("an int", (if c.conv in {'d', 'i'}: "%zu" else: "%z" & base))
          elif ty == tyInt64: takes = "an int"
        elif L == "l":
          if ty in {tyInt, tyUnsigned, tyChar}: (takes, better) = ("a long", "%" & base)
        elif L == "ll":
          if ty in {tyInt, tyUnsigned, tyChar}: (takes, better) = ("a long long", "%" & base)
        elif L == "z":
          if ty in {tyInt, tyUnsigned, tyChar} and lp64: (takes, better) = ("a size_t", "%" & base)
      of 'f', 'F', 'e', 'E', 'g', 'G', 'a', 'A':
        if ty in {tyInt, tyUnsigned, tyChar}: (takes, better) = ("a double", "%d")
        elif ty in {tyLong, tyULong}: (takes, better) = ("a double", "%ld")
        elif ty == tyLongLong: (takes, better) = ("a double", "%lld")
        elif ty == tySizeT: (takes, better) = ("a double", "%zu")
        elif ty == tyString: (takes, better) = ("a double", "%s")
        elif ty in {tyPtr, tyStruct, tyInt64}: takes = "a double"
        elif ty == tyDouble and c.length == "L": (takes, better) = ("a long double", "%" & $c.conv)
        elif ty == tyLongDouble and c.length != "L": (takes, better) = ("a double", "%L" & $c.conv)
      of 'c':
        if ty in {tyDouble, tyLongDouble}: takes = "an int (a character)"
        elif ty == tyString: (takes, better) = ("an int (a character)", "%s")
        elif ty in {tyPtr, tyStruct}: takes = "an int (a character)"
      of 's':
        if ty == tyChar: (takes, better) = ("a string", "%c")
        elif ty in {tyInt, tyUnsigned}: (takes, better) = ("a string", "%d")
        elif ty in {tyLong, tyULong}: (takes, better) = ("a string", "%ld")
        elif ty in {tyDouble}: (takes, better) = ("a string", "%f")
        elif ty in {tyPtr}: (takes, better) = ("a string", "%p")
        elif ty in {tyStruct, tyLongLong, tySizeT, tyInt64, tyLongDouble}: takes = "a string"
      of 'p':
        if ty in {tyInt, tyUnsigned, tyLong, tyULong, tyLongLong, tySizeT, tyInt64, tyDouble, tyLongDouble, tyStruct,
                  tyChar}:
          takes = "a pointer"
      else: discard
    if takes.len == 0: continue
    if not scan: takes = ckTakes(c)
    # where the conversion is written (its length and letter), for the diagnostic and the fix
    var p = CkProblem(sev: 2, rule: "c-format",
                      msg: c.spec & " takes " & takes & ", " & a.text.strip.ckShort & " is " & what)
    let (a0, b0) = (c.at[0], c.at[^1])
    if a0[0] >= 0 and b0[0] == a0[0]:
      (p.line, p.col, p.eline, p.ecol) = (a0[0], a0[1], b0[0], b0[1] + 1)
      if better.len > 0:
        # (the flags, width and precision as they are: the length and the letter changed)
        let keepLen = c.spec.len - c.length.len - 1
        let lenAt = c.at[keepLen]
        if lenAt[0] == a0[0]:
          p.fixes.add CkFix(title: "Use " & better, edits: @[CkEdit(line: lenAt[0], col: lenAt[1], eline: b0[0],
                                                                 ecol: b0[1] + 1, text: better[1 .. ^1])])
    else:
      let (l0, c0, l1, c1) = where(a)
      (p.line, p.col, p.eline, p.ecol) = (l0, c0, l1, c1)
    result.add p

proc ckFormats*(f: CxFile): seq[CkProblem] =
  ## the printf- and scanf-family calls of a file whose format (a string literal) and arguments do not go together:
  ## how many conversions and how many arguments; a conversion and an argument whose type the engine is sure of
  ## (a string for %d, an int for %s or %f, a double for %d, an int for %ld …; for scanf, a value instead of where to
  ## put it) — with a fix where it is clear (the conversion the argument takes, `&x`)
  if f == nil or f.lines.len == 0: return
  let files = cxClosure(f)
  var fam: Table[string, (int, bool)]
  for (n, k, scan) in CkFamily:
    # (the C library's — not a macro or a function of the project's that has the name)
    var own = false
    for g in files:
      if cxIsSystem(g.path): continue
      for k2 in cxNamed(g, n):
        if g.syms[k2].kind in {cxMacro, cxFunc}: own = true
    if not own: fam[n] = (k, scan)
  if fam.len == 0: return
  var inBlock = false
  var gone = 0
  for l, t in f.lines:
    # (not in the branches the preprocessor leaves out)
    while gone < f.inactive.len and f.inactive[gone][1] < l: inc gone
    if gone < f.inactive.len and l >= f.inactive[gone][0]: continue
    var i = 0
    while i < t.len:
      if inBlock:
        let e = t.find("*/", i)
        if e < 0: break
        inBlock = false
        i = e + 2
        continue
      if t.continuesWith("//", i): break
      if t.continuesWith("/*", i):
        inBlock = true
        i += 2
        continue
      if t[i] in {'"', '\''}:
        let q = t[i]
        inc i
        while i < t.len and t[i] != q:
          if t[i] == '\\': inc i
          inc i
        inc i
        continue
      if i == 0 and t.strip.startsWith("#"): break
      if t[i] in IdentStartChars and (i == 0 or t[i - 1] notin IdentChars):
        var e = i
        while e < t.len and t[e] in IdentChars: inc e
        let name = t[i ..< e]
        var k = e
        while k < t.len and t[k] == ' ': inc k
        if name in fam and k < t.len and t[k] == '(':
          # (a call: not after `.`, `->`, a type word — a declaration)
          var p = i - 1
          while p >= 0 and t[p] == ' ': dec p
          let prevWord = (block:
            var q = p
            while q >= 0 and t[q] in IdentChars: dec q
            if p >= 0 and t[p] in IdentChars: t[q + 1 .. p] else: "")
          let call = not (p >= 0 and (t[p] == '.' or (t[p] == '>' and p > 0 and t[p - 1] == '-'))) and
                     (prevWord.len == 0 or prevWord in ["return", "else", "do", "case"]) and
                     not (p >= 0 and t[p] == '*')
          if call and not ckSilenced(f.lines, l, "c-format"):
            let (fi, scan) = fam[name]
            let (closed, args) = ckCallArgs(f.lines, l, k)
            if closed and args.len > fi:
              result.add ckCall(f, files, name, fi, scan, args, l, i)
        i = e
        continue
      inc i

proc ckChecks*(f: CxFile, includes = true, padding = true, formats = true,
               extraTexts: seq[seq[string]] = @[]): seq[CkProblem] =
  ## the engine's checks of a C (C++: the formats only) file, those turned on
  if f == nil: return
  if formats: result.add ckFormats(f)
  if f.cpp: return
  if includes: result.add ckUnusedIncludes(f)
  if padding: result.add ckPadding(f, extraTexts)

# ── refactors at the cursor (Alt+Enter): a switch's missing cases, a selection put in a variable, an if/else turned
#    round — each one edit of the text, made only where the engine is sure of what it changes ──

type CkText = object                  # some lines' code as one string: comments and the insides of strings blanked
  code: string
  first: int                          # the first line's number
  starts: seq[int]                    # where each line starts in code

proc ckTextOf(lines: seq[string], a, b: int): CkText =
  ## lines a..b as code (a /* … */ over several lines blanked too), joined with "\n": positions stay where they are
  result.first = a
  var inBlock = false
  for l in a .. min(b, lines.high):
    result.starts.add result.code.len
    var t = lines[l]
    var i = 0
    while i < t.len:
      if inBlock:
        let e = t.find("*/", i)
        let stop = if e < 0: t.len else: e + 2
        for k in i ..< stop: t[k] = ' '
        if e >= 0: inBlock = false
        i = stop
        continue
      if t.continuesWith("//", i):
        for k in i ..< t.len: t[k] = ' '
        break
      if t.continuesWith("/*", i):
        inBlock = true
        continue
      if t[i] in {'"', '\''}:
        let q = t[i]
        var k = i + 1
        while k < t.len and t[k] != q:
          if t[k] == '\\': inc k
          inc k
        for x in i + 1 ..< min(k, t.len): t[x] = ' '
        i = k + 1
        continue
      inc i
    result.code.add t
    result.code.add '\n'

func ckPosOf(t: CkText, off: int): (int, int) =
  ## an offset in t.code as (line, column)
  var k = t.starts.high
  while k > 0 and t.starts[k] > off: dec k
  (t.first + k, off - t.starts[k])

# the offset in `t.code` of a column on a line (the opposite of ckPosOf)
func ckOffOf(t: CkText, line, col: int): int = t.starts[line - t.first] + col

func ckMatch(code: string, i: int): int =
  ## the bracket that closes the one at i (`(`, `[`, `{`): its offset, -1 when it is not there
  var d = 0
  for k in i ..< code.len:
    if code[k] in {'(', '[', '{'}: inc d
    elif code[k] in {')', ']', '}'}:
      dec d
      if d == 0: return k
  -1

func ckSkipWs(code: string, i: int): int =
  ## the offset of the first character from `i` on that is not white space (the end of the text when there is none)
  result = i
  while result < code.len and code[result] in Whitespace: inc result

func ckWordAt(code: string, i: int, w: string): bool =
  ## whether the word `w` stands at `i` in the code as a whole word, not as part of a longer name
  code.continuesWith(w, i) and (i == 0 or code[i - 1] notin IdentChars) and
    (i + w.len >= code.len or code[i + w.len] notin IdentChars)

func ckTextBetween(lines: seq[string], a, b: (int, int)): string =
  ## the text from a to b (b not included), lines joined with "\n"
  if a[0] == b[0]: return lines[a[0]][a[1] ..< b[1]]
  result = lines[a[0]][a[1] .. ^1]
  for l in a[0] + 1 ..< b[0]: result.add "\n" & lines[l]
  result.add "\n" & lines[b[0]][0 ..< b[1]]

func ckIndentUnit(lines: seq[string]): string =
  ## the file's step of indentation: a tab, or the number of spaces it steps in by most
  var counts: array[1 .. 8, int]
  var prev = -1
  for l in 0 ..< min(lines.len, 2000):
    let t = lines[l]
    if t.strip.len == 0: continue
    if t[0] == '\t': return "\t"
    var n = 0
    while n < t.len and t[n] == ' ': inc n
    if prev >= 0 and n > prev and n - prev <= 8: inc counts[n - prev]
    prev = n
  var best = 4
  for k in 1 .. 8:
    if counts[k] > counts[best]: best = k
  spaces(best)

func ckLeading(t: string): string =
  ## the spaces and tabs a line starts with
  var n = 0
  while n < t.len and t[n] in {' ', '\t'}: inc n
  t[0 ..< n]

proc ckFillSwitch*(f: CxFile, line, col: int): seq[CkFix] =
  ## a `switch` on an enum (the cursor on it, or in its body): the cases it does not have yet, each with its
  ## `break;` — before `default:` when there is one
  if f == nil or line >= f.lines.len: return
  let lines = f.lines
  let t = ckTextOf(lines, max(0, line - 400), min(lines.high, line + 4000))
  let here = t.ckOffOf(line, min(col, lines[line].len))
  # the innermost switch whose body the cursor is in (or whose head it is on)
  var k = here + 6
  var sw, open, close = -1
  while k >= 0:
    k = t.code.rfind("switch", last = min(k, t.code.high))
    if k < 0: break
    if ckWordAt(t.code, k, "switch"):
      let p = ckSkipWs(t.code, k + 6)
      if p < t.code.len and t.code[p] == '(':
        let pe = ckMatch(t.code, p)
        let b = if pe > 0: ckSkipWs(t.code, pe + 1) else: -1
        if b > 0 and b < t.code.len and t.code[b] == '{':
          let be = ckMatch(t.code, b)
          if be > 0 and ((here >= k and here <= be) or t.ckPosOf(k)[0] == line):
            (sw, open, close) = (k, p, b)
            break
    dec k
  if sw < 0: return
  let bodyEnd = ckMatch(t.code, close)
  let pe = ckMatch(t.code, open)
  let (sl, _) = t.ckPosOf(sw)
  let expr = t.code[open + 1 ..< pe].replace("\n", " ").strip
  let (ename, consts) = cxEnumConsts(f, cxExprType(f, expr, sl))
  if consts.len == 0: return
  # the cases it has: at its own level (not a switch inside it)
  var have: HashSet[string]
  var caseLine, defaultLine = -1
  var depth = 0
  var i = close + 1
  while i < bodyEnd:
    let c = t.code[i]
    if c in {'{', '(', '['}: inc depth
    elif c in {'}', ')', ']'}: dec depth
    elif depth == 0 and ckWordAt(t.code, i, "case"):
      let j = ckSkipWs(t.code, i + 4)
      var e = j
      while e < bodyEnd and t.code[e] != '\n':
        if t.code[e] == ':':
          if e + 1 < bodyEnd and t.code[e + 1] == ':':        # (Color::Red)
            e += 2
            continue
          break
        inc e
      let lbl = t.code[j ..< e].strip
      have.incl cxxSplit(lbl)[^1]
      if caseLine < 0: caseLine = t.ckPosOf(i)[0]
      i = e
      continue
    elif depth == 0 and ckWordAt(t.code, i, "default"):
      let j = ckSkipWs(t.code, i + 7)
      if j < bodyEnd and t.code[j] == ':' and defaultLine < 0: defaultLine = t.ckPosOf(i)[0]
    inc i
  var missing: seq[string]
  for s in consts:
    if s.name notin have:
      # (C++: an enum class's constants, and a namespace's, written with their scope)
      missing.add(if f.cpp and s.scope.len > 0: s.scope & "::" & s.name else: s.name)
  if missing.len == 0: return
  let unit = ckIndentUnit(lines)
  # (as its cases are indented — one on the switch's own line says nothing —, else a step in from the switch)
  let caseInd = if caseLine >= 0 and caseLine != sl: ckLeading(lines[caseLine])
                elif defaultLine >= 0 and defaultLine != sl: ckLeading(lines[defaultLine])
                else: ckLeading(lines[sl]) & unit
  var text = ""
  for m in missing: text.add caseInd & "case " & m & ":\n" & caseInd & unit & "break;\n"
  let (el, ec) = t.ckPosOf(bodyEnd)
  var edit: CkEdit
  if defaultLine >= 0: edit = CkEdit(line: defaultLine, col: 0, eline: defaultLine, ecol: 0, text: text)
  elif lines[el][0 ..< ec].strip.len == 0: edit = CkEdit(line: el, col: 0, eline: el, ecol: 0, text: text)
  else:
    # (the body on one line with its `}`: the cases go before it, on lines of their own)
    var sp = ec
    while sp > 0 and lines[el][sp - 1] in {' ', '\t'}: dec sp
    edit = CkEdit(line: el, col: sp, eline: el, ecol: ec, text: "\n" & text & ckLeading(lines[sl]))
  result.add CkFix(title: "Add the " & (if missing.len == 1: "missing case " & missing[0]
                                         else: $missing.len & " missing cases") & " (" & ename & ")",
                   edits: @[edit])

func ckIsOperand(e: string): bool =
  ## a name, a call, a member or an element — what `!` can go in front of without parentheses
  var d = 0
  var i = 0
  if e.len == 0 or e[0] notin IdentStartChars: return false
  while i < e.len:
    let c = e[i]
    if c in {'(', '['}: inc d
    elif c in {')', ']'}: dec d
    elif d == 0 and not (c in IdentChars or c == '.' or (c == '-' and i + 1 < e.len and e[i + 1] == '>') or
                         (c == '>' and i > 0 and e[i - 1] == '-')):
      return false
    inc i
  d == 0

func ckNegate*(c: string): string =
  ## not c, written simply: a comparison turned round, `!x` → x, else `!x` or `!(…)`
  let t = c.strip
  if t.startsWith("!") and not t.startsWith("!="):
    let r = t[1 .. ^1].strip
    if r.startsWith("(") and ckMatch(r, 0) == r.high: return r[1 ..< r.high].strip
    if ckIsOperand(r): return r
  # (one comparison at the top level is turned round; && || ?: , = & | ^ there: the whole in !( … ))
  var d = 0
  var ops: seq[(int, string)]
  var i = 0
  while i < t.len:
    let ch = t[i]
    if ch in {'(', '['}: inc d
    elif ch in {')', ']'}: dec d
    elif d == 0:
      if t.continuesWith("->", i) or t.continuesWith("<<", i) or t.continuesWith(">>", i):
        i += 2
        continue
      var op = ""
      for o in ["==", "!=", "<=", ">="]:
        if t.continuesWith(o, i): op = o
      if op.len == 0 and ch in {'<', '>'}: op = $ch
      if op.len > 0:
        ops.add (i, op)
        i += op.len
        continue
      if ch in {'&', '|', '?', ',', '^', '='}: return "!(" & t & ")"
    inc i
  if ops.len == 1:
    const flip = {"==": "!=", "!=": "==", "<": ">=", ">": "<=", "<=": ">", ">=": "<"}.toTable
    let (k, op) = ops[0]
    return t[0 ..< k].strip(leading = false) & " " & flip[op] & " " & t[k + op.len .. ^1].strip(trailing = false)
  if ops.len == 0 and ckIsOperand(t): return "!" & t
  "!(" & t & ")"

proc ckInvertIf*(lines: seq[string], line: int): seq[CkFix] =
  ## `if (c) { A } else { B }` (the `if` on the cursor's line) as `if (!c) { B } else { A }` — braces on both
  ## branches, the else not an `else if`
  if line >= lines.len or lines[line].strip.startsWith("#"): return
  let t = ckTextOf(lines, line, min(lines.high, line + 4000))
  var k = 0
  while k < t.code.len and t.code[k] != '\n':
    if ckWordAt(t.code, k, "if"): break
    inc k
  if k >= t.code.len or t.code[k] == '\n': return
  let open = ckSkipWs(t.code, k + 2)
  if open >= t.code.len or t.code[open] != '(': return
  let pe = ckMatch(t.code, open)
  if pe < 0: return
  let a = ckSkipWs(t.code, pe + 1)
  if a >= t.code.len or t.code[a] != '{': return
  let ae = ckMatch(t.code, a)
  if ae < 0: return
  let el = ckSkipWs(t.code, ae + 1)
  if not ckWordAt(t.code, el, "else"): return
  let b = ckSkipWs(t.code, el + 4)
  if b >= t.code.len or t.code[b] != '{': return
  let be = ckMatch(t.code, b)
  if be < 0: return
  let thenText = ckTextBetween(lines, t.ckPosOf(a + 1), t.ckPosOf(ae))
  let elseText = ckTextBetween(lines, t.ckPosOf(b + 1), t.ckPosOf(be))
  if thenText.strip.len == 0 or elseText.strip.len == 0: return
  var es: seq[CkEdit]
  let (cl0, cc0) = t.ckPosOf(open + 1)
  let (cl1, cc1) = t.ckPosOf(pe)
  if cl0 == cl1:
    es.add CkEdit(line: cl0, col: cc0, eline: cl1, ecol: cc1, text: ckNegate(lines[cl0][cc0 ..< cc1]))
  else:
    # (a condition over several lines: the whole of it in !( … ))
    es.add CkEdit(line: cl1, col: cc1, eline: cl1, ecol: cc1, text: ")")
    es.add CkEdit(line: cl0, col: cc0, eline: cl0, ecol: cc0, text: "!(")
  let (al, ac) = t.ckPosOf(a + 1)
  let (ael, aec) = t.ckPosOf(ae)
  let (bl, bc) = t.ckPosOf(b + 1)
  let (bel, bec) = t.ckPosOf(be)
  es.add CkEdit(line: al, col: ac, eline: ael, ecol: aec, text: elseText)
  es.add CkEdit(line: bl, col: bc, eline: bel, ecol: bec, text: thenText)
  result.add CkFix(title: "Invert the if: !(condition), its branches swapped", edits: es)

func ckLitType(e: string): string =
  ## a literal's type ("" when e is not one)
  if e.len == 0: return
  if e[0] == '"': return "const char *"
  if e[0] == '\'': return "char"
  if e[0] notin Digits and not (e.len > 1 and e[0] == '.' and e[1] in Digits): return
  let low = e.toLowerAscii
  let hex = low.startsWith("0x")
  if not hex and ('.' in low or 'e' in low): return (if low.endsWith("f"): "float" elif low.endsWith("l"): "long double"
                                                     else: "double")
  if low.endsWith("ull") or low.endsWith("llu"): "unsigned long long"
  elif low.endsWith("ll"): "long long"
  elif low.endsWith("ul") or low.endsWith("lu"): "unsigned long"
  elif low.endsWith("l"): "long"
  elif low.endsWith("u"): "unsigned"
  else: "int"

const CkArith = ["int", "unsigned", "long", "unsigned long", "long long", "unsigned long long", "float", "double",
                 "long double"]        ## (the usual arithmetic conversions: the later one wins)

func ckArithRank(t: string): int =
  ## where a type comes in the usual arithmetic conversions, the later one winning: 0 for int and anything smaller, then
  ## unsigned, the long types, float, double and long double; -1 for a type not in that list (a typedef such as size_t)
  case t
  of "char", "signed char", "unsigned char", "short", "short int", "unsigned short", "_Bool", "bool", "signed",
     "signed int", "int": 0
  of "unsigned int": 1
  of "long int", "signed long": 2
  of "unsigned long int": 3
  of "long long int": 4
  of "unsigned long long int": 5
  else: CkArith.find(t)

proc ckTypeOf(f: CxFile, expr: string, line: int, depth = 0): string =
  ## the type of an expression, where the engine can tell: a literal's, a name's, a member's, a call's; a sum or a
  ## product of numbers: the type C gives it; a comparison or a logical operation: int — "" otherwise (a pointer's
  ## arithmetic too)
  let e = expr.strip
  if e.len == 0 or depth > 6: return
  result = ckLitType(e)
  if result.len > 0: return
  if e.startsWith("sizeof"): return "size_t"
  if e[0] == '(' and ckMatch(e, 0) == e.high: return ckTypeOf(f, e[1 ..< e.high], line, depth + 1)
  if ckIsOperand(e) or (e[0] in {'*', '&'} and ckIsOperand(e[1 .. ^1].strip)):
    result = cxExprType(f, e, line)
    if result.startsWith("fn:"): result = ""
    return
  let c = ckCode(e)
  if c.startsWith("!") or "==" in c or "!=" in c or "<=" in c or ">=" in c or "&&" in c or "||" in c: return "int"
  if '?' in c or '=' in c or ',' in c: return ""
  # (the operands of + - * / % << >> & | ^ at the top level — a sign is part of its operand)
  var parts: seq[string]
  var d = 0
  var st = 0
  var i = 0
  var prevOp = true
  while i < e.len:
    let ch = e[i]
    if ch in {'(', '['}: inc d
    elif ch in {')', ']'}: dec d
    elif d == 0 and e.continuesWith("->", i):
      i += 2
      continue
    elif d == 0 and ch in {'<', '>'} and not (e.continuesWith("<<", i) or e.continuesWith(">>", i)):
      return "int"                               # (a comparison)
    elif d == 0 and ch in {'+', '-', '*', '/', '%', '<', '>', '&', '|', '^'}:
      if not prevOp:
        parts.add e[st ..< i]
        if e.continuesWith("<<", i) or e.continuesWith(">>", i): inc i
        st = i + 1
        prevOp = true
      inc i
      continue
    if ch notin Whitespace: prevOp = false
    inc i
  parts.add e[st .. ^1]
  if parts.len < 2: return
  var best = -1
  var same = ""
  for pt in parts:
    let t = ckTypeOf(f, pt, line, depth + 1)
    if t.len == 0: return ""
    let (b, stars) = cxStrip(t)
    if stars > 0: return ""                      # (a pointer's arithmetic: not said here)
    let r = ckArithRank(b)
    if r < 0:
      # (a type C's conversions do not name here — size_t, a typedef —: only when every operand has it)
      if same.len == 0 or same == b: same = b else: return ""
      continue
    best = max(best, r)
  if same.len > 0: return (if best < 0: same else: "")
  result = CkArith[best]

proc ckExtractVar*(f: CxFile, line, c0, c1: int, name = ""): seq[CkFix] =
  ## the expression selected on `line` (columns c0 ..< c1) put in a variable declared before its statement — of the
  ## type the engine knows it has (C++: auto) — and used in its place. name: the variable's (else one made from the
  ## expression)
  if f == nil or line >= f.lines.len: return
  let lines = f.lines
  let s = lines[line]
  var a = clamp(c0, 0, s.len)
  var e = clamp(c1, a, s.len)
  while a < e and s[a] in Whitespace: inc a
  while e > a and s[e - 1] in Whitespace: dec e
  if a >= e: return
  let expr = s[a ..< e]
  # (in a function's body)
  var fn = -1
  for i, x in f.syms:
    if x.kind in {cxFunc, cxMethod} and x.isDef and x.line < line and line <= x.endLine: fn = i
  if fn < 0: return
  let code = ckTextOf(lines, line, line).code
  # (a whole expression: brackets that close, no statement in it, not a name being assigned or a member's name)
  var d = 0
  for i in a ..< e:
    if code[i] in {'(', '['}: inc d
    elif code[i] in {')', ']'}:
      dec d
      if d < 0: return
    elif code[i] in {';', '{', '}'}: return
  if d != 0: return
  if expr[0] in {'/', '%', '=', ',', '<', '>', '|', '^', '?', ':', '.', '+', ')', ']'} and
     not (expr.len > 1 and expr[0] == '+' and expr[1] in Digits): return
  if expr[^1] in {'*', '/', '%', '=', ',', '<', '>', '|', '^', '?', ':', '.', '+', '-', '&', '!'}: return
  if expr in CxKeywords: return
  var after = e
  while after < s.len and s[after] in Whitespace: inc after
  if after < s.len and ((s[after] == '=' and not s.continuesWith("==", after)) or s.continuesWith("++", after) or
     s.continuesWith("--", after) or (s[after] in {'+', '-', '*', '/', '%', '&', '|', '^'} and
     after + 1 < s.len and s[after + 1] == '=') or s.continuesWith("<<=", after) or s.continuesWith(">>=", after)):
    return
  var before = a
  while before > 0 and s[before - 1] in Whitespace: dec before
  if before > 0 and (s[before - 1] == '.' or s.continuesWith("->", max(0, before - 2)) or
                     s.continuesWith("++", max(0, before - 2)) or s.continuesWith("--", max(0, before - 2))):
    return
  if before > 0 and s[before - 1] == '&' and not (before > 1 and s[before - 2] == '&'):
    # (`&x`: its address — a copy in a variable has another one; `a & x` is fine)
    var q = before - 1
    while q > 0 and s[q - 1] in Whitespace: dec q
    if q == 0 or s[q - 1] notin IdentChars + {')', ']'}: return
  # its statement's first line: back while the line before goes on into this one
  func control(p: string): bool =
    ## (the head of an if, a for, a while or an else without braces: the next statement is its body)
    for kw in ["if", "for", "while", "else", "} else", "}else"]:
      if p.startsWith(kw) and (p.len == kw.len or p[kw.len] notin IdentChars): return p.endsWith(")") or
                                                                                         p.endsWith("else")
  var sl = line
  let fnLine = f.syms[fn].line
  while sl > fnLine + 1:
    let p = ckCode(lines[sl - 1]).strip
    if p.len == 0 or p[^1] in {';', '{', '}', ':'} or p.startsWith("#"): break
    if control(p): return
    dec sl
  let first = ckCode(lines[sl]).strip
  for kw in ["for", "while", "do", "else", "case", "default", "}", "{"]:
    if first.startsWith(kw) and (first.len == kw.len or first[kw.len] notin IdentChars): return
  # its type
  let typ = if f.cpp: "auto" else: ckTypeOf(f, expr, line)
  if typ.len == 0: return
  # its name
  var nm = name.strip
  if nm.len == 0:
    var w = expr
    let p = w.find('(')
    if p > 0: w = w[0 ..< p]
    nm = "value"
    var parts: seq[string]
    var cur = ""
    for ch in w & " ":
      if ch in IdentChars: cur.add ch
      else:
        if cur.len > 0: parts.add cur
        cur = ""
    for i in countdown(parts.high, 0):
      if not ckIsOperand(w): break                 # (a sum, a comparison …: "value")
      if parts[i][0] notin Digits and parts[i] notin CxKeywords and (parts[i].len > 1 or i == parts.high):
        nm = parts[i] & (if p > 0: "_result" else: "")
        break
    # (not a name already seen there)
    var taken: HashSet[string]
    for x in cxLocalsAt(f, line): taken.incl x.name
    let base = nm
    var n = 2
    while nm in taken or nm == expr:
      nm = base & $n
      inc n
  let ind = ckLeading(lines[sl])
  let decl = typ & (if typ.endsWith("*"): "" else: " ") & nm & " = " & expr & ";"
  result.add CkFix(title: "Extract into a variable: " & decl,
                   edits: @[CkEdit(line: line, col: a, eline: line, ecol: e, text: nm),
                            CkEdit(line: sl, col: 0, eline: sl, ecol: 0, text: ind & decl & "\n")])
