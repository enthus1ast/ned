## ned's own C engine: an index of C files and the headers they include — functions, structs and their members,
## unions, enums, typedefs, macros, globals, a function's parameters and locals, and the comments that document
## them — answering completion (members after `.` and `->` too), hover, go to definition, references, the outline
## and signature help. Text in, answers out: no compiler, no server, a few milliseconds a file.
##
## It reads C the way a person skimming it does, not as a compiler: the preprocessor is not run (every #if branch
## is read, macros are not expanded), so code built out of macros is understood less than clangd understands it.

import std/[os, strutils, tables, sets, times, algorithm]

type
  CxKind* = enum
    cxFunc, cxStruct, cxUnion, cxEnum, cxTypedef, cxMacro, cxVar, cxEnumConst, cxField, cxParam, cxLocal, cxLabel
  CxParam* = object
    name*, typ*: string
    line*, col*: int            # where its name is written (-1: nowhere — unnamed)
  CxSym* = object
    name*: string
    kind*: CxKind
    line*, col*: int            # where its name is
    endLine*: int               # functions, structs, enums: where their body ends
    typ*: string                # variables, fields, params: the declared type ("struct point *"); typedefs: what they
                                # name; functions: what they return
    params*: seq[CxParam]       # functions and function-like macros
    varargs*: bool
    owner*: string              # fields: their struct or union (tag, or typedef name); enum constants: the enum
    text*: string               # the declaration, on one line
    doc*: string                # the comment above it (or after it on its line)
    isDef*: bool                # a function with its body; a struct with its members
    weak*: bool                 # a system header's inline wrapper over the real declaration (fortify, optimizing)
    scopeA*, scopeB*: int       # locals, parameters and labels: the lines they are seen on
  CxFile* = ref object
    path*: string
    stamp*: string
    syms*: seq[CxSym]
    includes*: seq[(string, int)]     # as written (<x.h> or "y.h"), and the line
    lines*: seq[string]
    inactive*: seq[(int, int)]        # what #if 0, #ifdef __cplusplus … leave out: (first line, last line)
    byName, byOwner: Table[string, seq[int32]]   # the syms by name, the fields by owner (made when first asked)
    indexed: bool
  CxTokKind = enum ctWord, ctNum, ctStr, ctChar, ctPunct
  CxTok = object
    kind: CxTokKind
    text: string
    line, col: int
  CxComment = object
    a, b: int                   # first and last line
    text: string
    lone: bool                  # nothing but the comment on its first line

const
  CxKeywords* = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
    "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short",
    "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while",
    "_Bool", "_Complex", "_Alignas", "_Alignof", "_Atomic", "_Generic", "_Noreturn", "_Static_assert",
    "_Thread_local", "bool", "true", "false", "NULL"]
  CxTypeWords = ["void", "char", "short", "int", "long", "float", "double", "signed", "unsigned", "_Bool", "bool",
    "_Complex", "struct", "union", "enum", "const", "volatile", "static", "extern", "register", "inline", "restrict",
    "__restrict", "__restrict__", "__inline", "__inline__", "__extension__", "_Atomic", "_Noreturn", "_Thread_local",
    "size_t", "ssize_t", "ptrdiff_t", "intptr_t", "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t",
    "uint8_t", "uint16_t", "uint32_t", "uint64_t", "FILE", "va_list", "off_t", "pid_t", "time_t", "wchar_t"]
  CxQualifiers = ["const", "volatile", "static", "extern", "register", "inline", "restrict", "__restrict",
    "__restrict__", "__inline", "__inline__", "__extension__", "_Atomic", "_Noreturn", "_Thread_local", "__const",
    "__volatile__", "__volatile"]

  CxTargetMacros = ["__x86_64__", "__amd64__", "__i386__", "__aarch64__", "__arm__", "__powerpc__", "__powerpc64__",
    "__ppc64__", "__riscv", "__s390x__", "__mips__", "__sparc__", "__loongarch__", "__wasm__", "__linux__",
    "__gnu_linux__", "__ANDROID__", "__APPLE__", "__MACH__", "__FreeBSD__", "__OpenBSD__", "__NetBSD__",
    "__DragonFly__", "__sun", "__CYGWIN__", "__MINGW32__", "__MINGW64__", "_WIN32", "_WIN64", "_MSC_VER",
    "__clang__", "__GNUC__", "__unix__", "__unix", "__LP64__", "_LP64", "__ILP32__", "__ELF__", "__EMSCRIPTEN__",
    "__HAIKU__", "__STDC_VERSION__", "__SIZEOF_POINTER__", "__CHAR_UNSIGNED__"]
    ## macros the compiler defines (or not) for its target, never a header: their #if branches are known

var
  cxCache: Table[string, CxFile]               # path → its index (by modification time and size, or a text stamp)
  cxCheckedAt: Table[string, float]            # path → when its stamp was last looked at (once a second is enough)
  cxDirs*: seq[string]                         # where #include <…> and "…" look (set by the editor)
  cxPredef*: Table[string, string]             # the C compiler's predefined macros (cc -dM -E), set by the editor
  cxPredefSet*: bool

# ── lexing ──

proc cxLex(text: string, toks: var seq[CxTok], comments: var seq[CxComment], pp: var seq[(int, string)]) =
  ## C as tokens (comments and preprocessor lines apart: pp is (line, the directive with its \ continuations))
  var i = 0
  var line = 0
  var col = 0
  var lineStart = true
  let n = text.len
  template adv() =
    if text[i] == '\n':
      inc line
      col = 0
      lineStart = true
    else: inc col
    inc i
  while i < n:
    let c = text[i]
    if c in {' ', '\t', '\r', '\f', '\v', '\n'}:
      adv()
      continue
    if c == '#' and lineStart:
      let l0 = line
      var s = ""
      while i < n:
        if text[i] == '\n':
          var k = s.len - 1
          while k >= 0 and s[k] in {' ', '\t', '\r'}: dec k
          if k >= 0 and s[k] == '\\':
            s.setLen(k)
            s.add ' '
            adv()
            continue
          break
        if text[i] == '/' and i + 1 < n and text[i + 1] == '*':
          let e = text.find("*/", i + 2)
          let stop = if e < 0: n else: e + 2
          while i < stop: adv()
          s.add ' '
          continue
        if text[i] == '/' and i + 1 < n and text[i + 1] == '/':
          while i < n and text[i] != '\n': adv()
          continue
        s.add text[i]
        adv()
      pp.add (l0, s.strip)
      continue
    let wasStart = lineStart
    lineStart = false
    let l0 = line
    let c0 = col
    if c == '/' and i + 1 < n and text[i + 1] == '/':
      var s = ""
      while i < n and text[i] != '\n':
        s.add text[i]
        adv()
      comments.add CxComment(a: l0, b: l0, text: s, lone: wasStart)
      continue
    if c == '/' and i + 1 < n and text[i + 1] == '*':
      let e = text.find("*/", i + 2)
      let stop = if e < 0: n else: e + 2
      let s = text[i ..< stop]
      while i < stop: adv()
      comments.add CxComment(a: l0, b: line, text: s, lone: wasStart)
      continue
    if c in {'"', '\''}:
      let st = i
      adv()
      while i < n and text[i] != c and text[i] != '\n':
        if text[i] == '\\' and i + 1 < n: adv()
        adv()
      if i < n and text[i] == c: adv()
      toks.add CxTok(kind: (if c == '"': ctStr else: ctChar), text: text[st ..< i], line: l0, col: c0)
      continue
    if c in Digits or (c == '.' and i + 1 < n and text[i + 1] in Digits):
      let st = i
      while i < n and (text[i] in {'0'..'9', 'a'..'z', 'A'..'Z', '_', '.', '\''} or
                       (text[i] in {'+', '-'} and text[i - 1] in {'e', 'E', 'p', 'P'})):
        adv()
      toks.add CxTok(kind: ctNum, text: text[st ..< i], line: l0, col: c0)
      continue
    if c in IdentStartChars or ord(c) >= 128:
      let st = i
      while i < n and (text[i] in IdentChars or ord(text[i]) >= 128): adv()
      toks.add CxTok(kind: ctWord, text: text[st ..< i], line: l0, col: c0)
      continue
    var len = 1
    for p in ["...", "->", "++", "--", "<<", ">>", "<=", ">=", "==", "!=", "&&", "||", "::"]:
      if text.continuesWith(p, i):
        len = p.len
        break
    let st = i
    for _ in 1 .. len: adv()
    toks.add CxTok(kind: ctPunct, text: text[st ..< i], line: l0, col: c0)

proc cxCleanComment*(t: string): string =
  ## a comment's text without its markers (/* */ // /// /** and a leading * on each line)
  var outp: seq[string]
  for raw in t.splitLines:
    var s = raw.strip
    for pre in ["/**<", "/*!<", "///<", "//!<", "/**", "/*!", "/*", "///", "//!", "//"]:
      if s.startsWith(pre):
        s = s[pre.len .. ^1]
        break
    if s.endsWith("*/"): s = s[0 ..< s.len - 2]
    s = s.strip
    if s.startsWith("* ") or s == "*": s = s[1 .. ^1].strip
    elif s.startsWith("*") and not s.startsWith("*/"): s = s[1 .. ^1].strip
    outp.add s
  while outp.len > 0 and outp[0].len == 0: outp.delete(0)
  while outp.len > 0 and outp[^1].len == 0: outp.setLen(outp.len - 1)
  outp.join("\n")

# ── declarations ──

proc cxIsTypeStart(toks: seq[CxTok], k: int, typedefs: HashSet[string]): bool =
  ## can a declaration start with toks[k]: a type word, a qualifier, struct/union/enum, or a typedef name
  if k >= toks.len or toks[k].kind != ctWord: return false
  let w = toks[k].text
  w in CxTypeWords or w in typedefs or w.endsWith("_t")

proc cxNoise(w: string): bool =
  ## words that are not part of the C a reader cares about: attributes, export and calling macros
  w.startsWith("__attribute") or w in ["__asm__", "__asm", "asm", "__declspec", "__THROW", "__wur", "__nonnull",
    "__attr_dealloc", "__attr_dealloc_free", "__THROWNL", "__NTH", "__LEAF", "__BEGIN_DECLS", "__END_DECLS",
    "__attribute_pure__", "__attribute_malloc__", "__attribute_warn_unused_result__", "__attribute_deprecated__",
    "__dead2", "__pure2", "__printflike", "__scanflike", "_GLIBCXX_NOTHROW", "__MINGW_NOTHROW", "WINAPI",
    "APIENTRY", "CALLBACK", "__cdecl", "__stdcall", "__fastcall", "__inline_always", "__extern_always_inline",
    "__extern_inline", "__fortify_function", "__always_inline", "__attribute_artificial__"]

proc cxTypeText(toks: seq[CxTok], a, b: int): string =
  ## tokens as a type, spaced the way C is written: "const char *", "struct point"
  for k in a ..< b:
    let t = toks[k].text
    if t in ["restrict", "__restrict", "__restrict__"] or cxNoise(t): continue
    if t == "*": result.add (if result.len > 0 and result[^1] != '*': " *" else: "*")
    elif t in ["[", "]", "(", ")", ","]: result.add t
    else:
      if result.len > 0 and result[^1] notin {'(', '['}: result.add ' '
      result.add t

proc cxSkipGroup(toks: seq[CxTok], k: int): int =
  ## past the bracket group that starts at toks[k] ( ( [ { ): the index after its closing one
  var d = 0
  var i = k
  while i < toks.len:
    let t = toks[i].text
    if toks[i].kind == ctPunct:
      if t in ["(", "[", "{"]: inc d
      elif t in [")", "]", "}"]:
        dec d
        if d == 0: return i + 1
    inc i
  toks.len

proc cxTypeEnd(toks: seq[CxTok], a, b: int): int =
  ## where a declaration's type ends and its first declarator starts: `struct list *next` → at `*`, `int x = 1` → at
  ## `x`, `int (*fn)(int)` → at `(`, `int f(void)` → at `f`; b when there is no declarator (`struct list;`)
  var j = a
  var lastWord = -1
  var words = 0
  while j < b:
    let x = toks[j]
    if x.kind == ctWord and cxNoise(x.text):
      j = if j + 1 < b and toks[j + 1].text == "(": cxSkipGroup(toks, j + 1) else: j + 1
      continue
    if x.kind == ctWord:
      lastWord = j
      inc words
    if x.text in ["*", "[", "=", ",", ";", ":", "("]: break
    inc j
  if j < b and toks[j].text == "*": return j
  if j < b and toks[j].text == "(" and j + 1 < b and toks[j + 1].text == "*": return j
  if j < b and toks[j].text == "(" and j + 1 < b and toks[j + 1].text == "(" and lastWord == j - 1 and
     lastWord - 1 > a and toks[lastWord - 1].kind == ctWord:
    return lastWord - 1                         # void name _((int a)): a prototype through a portability macro
  if lastWord > a:
    # struct list; — a tag, no declarator
    if words == 2 and toks[a].text in ["struct", "union", "enum"] and (j >= b or toks[j].text == ";"): return b
    return lastWord
  j

proc cxDeclarators(toks: seq[CxTok], a, b: int): seq[(int, string, int)] =
  ## the declarators of toks[a ..< b] after the type: (index of the name, the pointer stars and array part, the
  ## index just past it) — `*p = 1, q[3], (*fn)(int)`
  var k = a
  while k < b:
    var stars = ""
    while k < b and toks[k].text in ["*", "const", "volatile", "restrict", "__restrict"]:
      if toks[k].text == "*": stars.add "*"
      inc k
    var nameAt = -1
    if k < b and toks[k].text == "(" and k + 1 < b and toks[k + 1].text == "*":
      # (*name)(…): a function pointer
      var j = k + 1
      while j < b and toks[j].text in ["*", "const"]: inc j
      if j < b and toks[j].kind == ctWord: nameAt = j
      stars.add "(*)"
      k = cxSkipGroup(toks, k)
      if k < b and toks[k].text == "(": k = cxSkipGroup(toks, k)
    elif k < b and toks[k].kind == ctWord and not cxNoise(toks[k].text):
      nameAt = k
      inc k
    while k < b and toks[k].text == "[":
      stars.add "*"
      k = cxSkipGroup(toks, k)
    # what follows the name up to the next top-level comma: an initializer, a bit-field width, attributes
    var d = 0
    while k < b:
      let t = toks[k].text
      if toks[k].kind == ctPunct and t in ["(", "[", "{"]: inc d
      elif toks[k].kind == ctPunct and t in [")", "]", "}"]: dec d
      elif t == "," and d == 0: break
      inc k
    if nameAt >= 0: result.add (nameAt, stars, k)
    inc k                                         # past the comma

proc cxParams(toks: seq[CxTok], a, b: int): (seq[CxParam], bool) =
  ## a parameter list's parameters (toks[a ..< b] inside the parentheses); `void` alone: none; `...`: varargs
  var parts: seq[(int, int)]
  var d = 0
  var st = a
  for k in a ..< b:
    let t = toks[k].text
    if toks[k].kind == ctPunct and t in ["(", "["]: inc d
    elif toks[k].kind == ctPunct and t in [")", "]"]: dec d
    elif t == "," and d == 0:
      parts.add (st, k)
      st = k + 1
  if b > st: parts.add (st, b)
  for (x, y) in parts:
    if y - x == 1 and toks[x].text == "void": continue
    if y - x == 1 and toks[x].text == "...":
      result[1] = true
      continue
    # the name: the last word that is not a type word, before any [ ] (a function pointer: (*name))
    var nameAt = -1
    var e = y
    for k in x ..< y:
      if toks[k].text == "[":
        e = k
        break
    for k in countdown(e - 1, x):
      if toks[k].kind == ctWord and toks[k].text notin CxTypeWords and k > x:
        nameAt = k
        break
      if toks[k].text == ")": break
    for k in x ..< y:
      if toks[k].text == "(" and k + 1 < y and toks[k + 1].text == "*" and k + 2 < y and toks[k + 2].kind == ctWord:
        nameAt = k + 2
    var typ = ""
    if nameAt > x:
      typ = cxTypeText(toks, x, nameAt)
      if e < y: typ.add "*"
    else: typ = cxTypeText(toks, x, y)
    result[0].add CxParam(name: (if nameAt >= 0: toks[nameAt].text else: ""), typ: typ.strip,
                          line: (if nameAt >= 0: toks[nameAt].line else: -1),
                          col: (if nameAt >= 0: toks[nameAt].col else: -1))

proc cxDefinedKnown(name: string): int =
  ## is `name` defined — 1, 0, or -1 when only the preprocessor would know. Known: __cplusplus (not: this reads C),
  ## __STDC_HOSTED__, and the compiler's own target macros (__x86_64__, __linux__, _WIN32 …) once cxPredef is set
  case name
  of "__cplusplus": 0
  of "__STDC_HOSTED__", "__STDC__": 1
  else:
    if cxPredefSet and name in CxTargetMacros: (if name in cxPredef: 1 else: 0) else: -1

proc cxValueKnown(name: string): int =
  ## `#if name`: 1 when known nonzero, 0 when known zero (or not defined), -1 not known
  let d = cxDefinedKnown(name)
  if d <= 0: return d
  if name in cxPredef:
    try: return (if parseInt(cxPredef[name].strip(chars = {'L', 'U', 'l', 'u', ' '})) != 0: 1 else: 0)
    except ValueError: return 1
  1

proc cxTopSplit(t, op: string): seq[string] =
  ## t split at `op` outside parentheses
  var d = 0
  var st = 0
  var i = 0
  while i < t.len:
    if t[i] == '(': inc d
    elif t[i] == ')': dec d
    elif d == 0 and t.continuesWith(op, i):
      result.add t[st ..< i]
      i += op.len
      st = i
      continue
    inc i
  result.add t[st .. ^1]

proc cxCond(c: string): int =
  ## a #if condition known without running the preprocessor — 0 false, 1 true, -1 not known: `0`, `1`,
  ## `defined X` and `X` for the macros cxDefinedKnown knows, with !, &&, || and parentheses
  var t = c.strip
  # (a comment left on the line)
  let cm = t.find("/*")
  if cm >= 0: t = t[0 ..< cm].strip
  if t.len == 0: return -1
  proc unwrap(x: string): string =
    ## (a) → a, but not (a) && (b)
    result = x.strip
    while result.len >= 2 and result[0] == '(' and result[^1] == ')':
      var d = 0
      var closesAtEnd = true
      for i, ch in result:
        if ch == '(': inc d
        elif ch == ')':
          dec d
          if d == 0 and i < result.high:
            closesAtEnd = false
            break
      if not closesAtEnd: break
      result = result[1 .. ^2].strip
  t = unwrap(t)
  let ors = cxTopSplit(t, "||")
  if ors.len > 1:
    result = 0
    for o in ors:
      let v = cxCond(o)
      if v == 1: return 1
      if v < 0: result = -1
    return
  let ands = cxTopSplit(t, "&&")
  if ands.len > 1:
    result = 1
    for a in ands:
      let v = cxCond(a)
      if v == 0: return 0
      if v < 0: result = -1
    return
  var neg = false
  if t.startsWith("!") and not t.startsWith("!="):
    neg = true
    t = unwrap(t[1 .. ^1])
  var v = -1
  if t.startsWith("defined") and t.len > 7 and t[7] in {' ', '(', '\t'}:
    v = cxDefinedKnown(t[7 .. ^1].strip(chars = {' ', '(', ')', '\t'}))
  elif t == "0": v = 0
  elif t == "1": v = 1
  elif t.len > 0 and t.allCharsInSet(IdentChars): v = cxValueKnown(t)
  elif t.startsWith("__cplusplus") and t[11 .. ^1].strip.len > 0 and t[11 .. ^1].strip[0] in {'>', '='}: v = 0
  if v >= 0 and neg: v = 1 - v
  v

proc cxInactive(pp: seq[(int, string)]): seq[(int, int)] =
  ## the parts that #if 0, #ifdef __cplusplus and their #else leave out: (a, b), the lines after a and before b.
  ## Every other #if is read whole, all its branches
  type Frame = object
    known, taken, skip, outer: bool
    start: int
  var st: seq[Frame]
  for (l, d) in pp:
    var t = d[1 .. ^1].strip
    var w = 0
    while w < t.len and t[w] in IdentChars: inc w
    let word = t[0 ..< w]
    let rest = t[w .. ^1].strip
    case word
    of "if", "ifdef", "ifndef":
      if st.len > 0 and (st[^1].skip or st[^1].outer):
        st.add Frame(outer: true)
        continue
      let c = case word
        of "ifdef": cxDefinedKnown(rest)
        of "ifndef": (let d = cxDefinedKnown(rest); if d < 0: -1 else: 1 - d)
        else: cxCond(rest)
      st.add Frame(known: c >= 0, taken: c == 1, skip: c == 0, start: l)
    of "elif", "else":
      if st.len == 0 or st[^1].outer: continue
      var fr = st[^1]
      if fr.skip: result.add (fr.start, l)
      let c = if word == "else": 1 else: cxCond(rest)
      if fr.known and fr.taken: fr.skip = true
      elif c == 0: fr.skip = true
      else:
        fr.skip = false
        if c == 1 and fr.known: fr.taken = true
        else: fr.known = false
      fr.start = l
      st[^1] = fr
    of "endif":
      if st.len == 0: continue
      let fr = st.pop()
      if not fr.outer and fr.skip: result.add (fr.start, l)
    else: discard
  for fr in st:
    if not fr.outer and fr.skip: result.add (fr.start, high(int))
  result.sort(proc(x, y: (int, int)): int = cmp(x[0], y[0]))

proc cxUnbalanced(pp: seq[(int, string)], toks: seq[CxTok], gone: var seq[(int, int)]) =
  ## #if branches that open or close braces — `#ifdef X  if (a) {  #else  if (b) {  #endif` —: only the first is
  ## read (as ctags does), or the function's body would never close. Inner #ifs first
  type Chain = object
    marks: seq[int]                     # the lines of its #if, #elif …, #else and #endif
    depth: int
    closed: bool
  var chains: seq[Chain]
  var open: seq[int]
  for (l, d) in pp:
    let t = d[1 .. ^1].strip
    var w = 0
    while w < t.len and t[w] in IdentChars: inc w
    case t[0 ..< w]
    of "if", "ifdef", "ifndef":
      chains.add Chain(marks: @[l], depth: open.len)
      open.add chains.high
    of "elif", "else":
      if open.len > 0: chains[open[^1]].marks.add l
    of "endif":
      if open.len > 0:
        let c = open.pop()
        chains[c].marks.add l
        chains[c].closed = true
    else: discard
  var order: seq[int]
  for i, c in chains:
    if c.closed and c.marks.len >= 3: order.add i         # (two branches or more)
  if order.len == 0: return
  order.sort(proc(x, y: int): int = cmp(chains[y].depth, chains[x].depth))
  template isGone(l: int): bool =
    var r = false
    for (ga, gb) in gone:
      if l > ga and l < gb: r = true
    r
  template covered(a, b: int): bool =
    var r = false
    for (ga, gb) in gone:
      if ga <= a and gb >= b: r = true
    r
  for ci in order:
    let m = chains[ci].marks
    var branches: seq[(int, int, int)]       # (from, to, what its braces add)
    for k in 0 ..< m.len - 1:
      let (a, b) = (m[k], m[k + 1])
      if covered(a, b): continue
      var lo = 0
      var hi = toks.len
      while lo < hi:                         # the first token after line a
        let mid = (lo + hi) div 2
        if toks[mid].line <= a: lo = mid + 1 else: hi = mid
      var dl = 0
      var i = lo
      while i < toks.len and toks[i].line < b:
        if toks[i].kind == ctPunct and toks[i].text in ["{", "}"] and not isGone(toks[i].line):
          dl += (if toks[i].text == "{": 1 else: -1)
        inc i
      branches.add (a, b, dl)
    if branches.len < 2: continue
    # (read together, alternatives that each open or close a brace add up: one too many)
    var opens = false
    for x in branches:
      if x[2] != 0: opens = true
    if opens:
      for x in branches[1 .. ^1]: gone.add (x[0], x[1])

proc cxDocFor(comments: seq[CxComment], line: int, endLine = -1): string =
  ## the comment that documents what starts on `line`: the block right above it (ending on the line before), or
  ## one after it on its last line
  var lo = 0
  var hi = comments.high
  var best = -1
  while lo <= hi:                                 # the last comment that ends before `line`
    let m = (lo + hi) div 2
    if comments[m].b < line:
      best = m
      lo = m + 1
    else: hi = m - 1
  if best >= 0 and comments[best].b == line - 1 and comments[best].lone:
    # (several // lines in a row are one comment)
    var a = best
    while a > 0 and comments[a - 1].b == comments[a].a - 1 and comments[a - 1].lone and
          comments[a - 1].text.startsWith("//") and comments[a].text.startsWith("//"): dec a
    var parts: seq[string]
    for k in a .. best: parts.add comments[k].text
    let t = cxCleanComment(parts.join("\n"))
    if "Copyright" notin t and "License" notin t: return t
  let el = if endLine >= 0: endLine else: line
  for k in max(0, best) .. min(comments.high, best + 3):
    if k >= 0 and comments[k].a == el and not comments[k].lone: return cxCleanComment(comments[k].text)

proc cxInactiveIn*(text: string): seq[(int, int)] =
  ## what #if 0, #ifdef __cplusplus … leave out of a C text: (first line, last line) — for the editor to dim, with
  ## whichever engine answers for the file
  var toks: seq[CxTok]
  var comments: seq[CxComment]
  var pp: seq[(int, string)]
  cxLex(text, toks, comments, pp)
  for (a, b) in cxInactive(pp):
    if b - 1 >= a + 1: result.add (a + 1, b - 1)

proc cxParse*(text, path: string, full = true): CxFile =
  ## one C file's declarations (not the ones of the files it includes); full: a prototype's parameters too (the
  ## file being edited: they are answered for; a header read for it: they are not needed)
  result = CxFile(path: path)
  let f = result
  var toks: seq[CxTok]
  var comments: seq[CxComment]
  var pp: seq[(int, string)]
  cxLex(text, toks, comments, pp)
  f.lines = text.splitLines
  var gone = cxInactive(pp)
  # (what the preprocessor leaves out, for the editor to dim — not the branches cxUnbalanced sets aside to read one)
  for (a, b) in gone:
    if b - 1 >= a + 1: f.inactive.add (a + 1, b - 1)
  f.inactive.sort(proc(x, y: (int, int)): int = cmp(x[0], y[0]))
  cxUnbalanced(pp, toks, gone)
  if gone.len > 1:
    gone.sort(proc(x, y: (int, int)): int = cmp(x[0], y[0]))
    var merged = @[gone[0]]
    for g in gone[1 .. ^1]:
      if g[0] < merged[^1][1]: merged[^1][1] = max(merged[^1][1], g[1])     # (one inside another)
      else: merged.add g
    gone = merged
  if gone.len > 0:
    # (tokens, comments and directives are in line order; the parts left out too)
    proc keep[T](xs: var seq[T], lineOf: proc(x: T): int) =
      var r = 0
      var o = 0
      for i in 0 ..< xs.len:
        let l = lineOf(xs[i])
        while r < gone.len and l >= gone[r][1]: inc r
        if r < gone.len and l > gone[r][0] and l < gone[r][1]: continue
        if o != i: xs[o] = xs[i]
        inc o
      xs.setLen(o)
    keep(toks, proc(x: CxTok): int = x.line)
    keep(comments, proc(x: CxComment): int = x.a)
    keep(pp, proc(x: (int, string)): int = x[0])
  var typedefs: HashSet[string]
  # preprocessor: #define, #include
  for (l, d) in pp:
    let t = d[1 .. ^1].strip
    if t.startsWith("include"):
      let next = t.startsWith("include_next")             # (GCC's: the same name, from the folders after this one's)
      let r = t[(if next: 12 else: 7) .. ^1].strip
      if r.len >= 3 and r[0] in {'<', '"'}:
        let close = r.find((if r[0] == '<': '>' else: '"'), 1)
        if close > 0: f.includes.add ((if next: "next" else: "") & r[0 .. close], l)
    elif t.startsWith("define"):
      let r = t[6 .. ^1].strip
      var j = 0
      while j < r.len and r[j] in IdentChars: inc j
      if j == 0: continue
      var s = CxSym(name: r[0 ..< j], kind: cxMacro, line: l, endLine: l, text: "#define " & r)
      let c = f.lines[min(l, f.lines.high)].find(s.name)
      s.col = max(0, c)
      if j < r.len and r[j] == '(':
        let e = r.find(')', j)
        if e > j:
          for p in r[j + 1 ..< e].split(','):
            if p.strip == "...": s.varargs = true
            elif p.strip.len > 0: s.params.add CxParam(name: p.strip)
      if s.text.len > 160: s.text = s.text[0 ..< 159] & "…"
      s.doc = cxDocFor(comments, l)
      f.syms.add s
  # declarations, at file level (and inside extern "C" { … })
  let base = extractFilename(path)
  proc anonName(word: string, line: int): string =
    ## an anonymous struct's name, unique across the files read together
    "(anonymous " & word & " at " & base & ":" & $(line + 1) & ")"
  proc addSym(s0: CxSym) =
    var s = s0
    if s.doc.len == 0: s.doc = cxDocFor(comments, s.line, s.endLine)
    f.syms.add s
  proc parseMembers(a, b: int, owner: string, kind: CxKind) =
    ## a struct's (or union's) members, toks[a ..< b] inside the braces; an enum's constants
    if kind == cxEnum:
      var k = a
      while k < b:
        if toks[k].kind == ctWord:
          addSym(CxSym(name: toks[k].text, kind: cxEnumConst, line: toks[k].line, col: toks[k].col, endLine: toks[k].line,
                       owner: owner, typ: "enum " & owner, text: toks[k].text & " (" & owner & ")"))
          # past its value, to the next comma
          var d = 0
          while k < b:
            let t = toks[k].text
            if toks[k].kind == ctPunct and t in ["(", "[", "{"]: inc d
            elif toks[k].kind == ctPunct and t in [")", "]", "}"]: dec d
            elif t == "," and d == 0: break
            inc k
        inc k
      return
    var k = a
    var st = a
    while k < b:
      let t = toks[k]
      if t.kind == ctPunct and t.text == "{":
        k = cxSkipGroup(toks, k)
        continue
      if t.kind == ctPunct and t.text == ";":
        if k > st:
          # a member: type then declarators; a nested struct { … } name; flattens when it has no name
          var tEnd = st
          var nestedAt = -1
          if toks[st].text in ["struct", "union"]:
            var j = st + 1
            if j < k and toks[j].kind == ctWord: inc j
            if j < k and toks[j].text == "{":
              nestedAt = j
              tEnd = cxSkipGroup(toks, j)
          if nestedAt >= 0:
            let nk = if toks[st].text == "union": cxUnion else: cxStruct
            let decls = cxDeclarators(toks, tEnd, k)
            if decls.len == 0:
              parseMembers(nestedAt + 1, tEnd - 1, owner, nk)    # an anonymous member: its fields are ours
            else:
              let nm = if st + 1 < k and toks[st + 1].kind == ctWord and toks[st + 1].text != "{": toks[st + 1].text
                       else: anonName(toks[st].text, toks[st].line)
              addSym(CxSym(name: nm, kind: nk, line: toks[st].line, col: toks[st].col,
                           endLine: toks[tEnd - 1].line, isDef: true, text: toks[st].text & " " & nm & " { … }"))
              parseMembers(nestedAt + 1, tEnd - 1, nm, nk)
              for (ni, stars, _) in decls:
                addSym(CxSym(name: toks[ni].text, kind: cxField, line: toks[ni].line, col: toks[ni].col,
                             endLine: toks[ni].line, owner: owner, typ: toks[st].text & " " & nm & (if stars.len > 0: " " & stars else: ""),
                             text: toks[st].text & " " & nm & " " & stars & toks[ni].text))
          else:
            let typeEnd = cxTypeEnd(toks, st, k)
            let base = cxTypeText(toks, st, typeEnd)
            for (ni, stars, _) in cxDeclarators(toks, typeEnd, k):
              let typ = (base & (if stars.len > 0: " " & stars else: "")).strip
              addSym(CxSym(name: toks[ni].text, kind: cxField, line: toks[ni].line, col: toks[ni].col,
                           endLine: toks[ni].line, owner: owner, typ: typ, text: typ & " " & toks[ni].text))
        st = k + 1
      inc k
  proc parseDecl(a, b: int) =
    ## one declaration toks[a ..< b] that ended with `;`
    var k = a
    while k < b and cxNoise(toks[k].text):
      k = if k + 1 < b and toks[k + 1].text == "(": cxSkipGroup(toks, k + 1) else: k + 1
    if k >= b: return
    let isTypedef = toks[k].text == "typedef"
    if isTypedef: inc k
    let k0 = k
    while k < b and toks[k].text in CxQualifiers: inc k        # static const struct { … } table[] = …
    if k >= b or toks[k].text notin ["struct", "union", "enum"]: k = k0
    # struct / union / enum with a body
    var tagKind = cxVar
    var tag = ""
    var bodyEnd = -1
    if k < b and toks[k].text in ["struct", "union", "enum"]:
      tagKind = (case toks[k].text
                 of "struct": cxStruct
                 of "union": cxUnion
                 else: cxEnum)
      var j = k + 1
      while j < b and cxNoise(toks[j].text):
        j = if j + 1 < b and toks[j + 1].text == "(": cxSkipGroup(toks, j + 1) else: j + 1
      var tagAt = k
      if j < b and toks[j].kind == ctWord:
        tag = toks[j].text
        tagAt = j
        inc j
      if j < b and toks[j].text == "{":
        bodyEnd = cxSkipGroup(toks, j)
        var nm = tag
        if nm.len == 0: nm = anonName(toks[k].text, toks[k].line)
        let word = toks[k].text
        let firstSym = f.syms.len
        addSym(CxSym(name: nm, kind: tagKind, line: toks[tagAt].line, col: toks[tagAt].col,
                     endLine: toks[bodyEnd - 1].line, isDef: true,
                     text: word & " " & (if tag.len > 0: tag & " " else: "") & "{ … }"))
        parseMembers(j + 1, bodyEnd - 1, nm, tagKind)
        # declarators after the body: typedef names, or variables of this type
        let decls = cxDeclarators(toks, bodyEnd, b)
        var named = ""
        for (ni, stars, _) in decls:
          let typ = word & " " & nm & (if stars.len > 0: " " & stars else: "")
          if isTypedef:
            typedefs.incl toks[ni].text
            addSym(CxSym(name: toks[ni].text, kind: cxTypedef, line: toks[ni].line, col: toks[ni].col,
                         endLine: toks[ni].line, typ: typ, text: "typedef " & word & " " &
                         (if tag.len > 0: tag & " " else: "") & "{ … } " & stars & toks[ni].text,
                         doc: cxDocFor(comments, toks[k].line)))
            if tag.len == 0 and stars.len == 0 and named.len == 0: named = toks[ni].text
          else:
            addSym(CxSym(name: toks[ni].text, kind: cxVar, line: toks[ni].line, col: toks[ni].col,
                         endLine: toks[ni].line, typ: typ, text: typ & " " & toks[ni].text, isDef: true))
        if named.len > 0:
          # an anonymous struct named only by its typedef is filed under the typedef's name (as its fields' owner,
          # and in the types that name it: `typedef struct { … } Options, *OptionsP;`)
          let old = word & " " & nm
          for q in firstSym ..< f.syms.len:
            if f.syms[q].owner == nm: f.syms[q].owner = named
            if f.syms[q].name == nm and f.syms[q].kind == tagKind: f.syms[q].name = named
            if f.syms[q].typ.startsWith(old): f.syms[q].typ = word & " " & named & f.syms[q].typ[old.len .. ^1]
        return
    # the type: up to the first declarator
    let ts = k
    let typeEnd = cxTypeEnd(toks, ts, b)
    if typeEnd >= b:
      if tag.len > 0 and not isTypedef and b - k == 2:
        # struct list; — declared here, its members elsewhere (or nowhere: an opaque type)
        addSym(CxSym(name: tag, kind: tagKind, line: toks[k + 1].line, col: toks[k + 1].col, endLine: toks[k + 1].line,
                     text: toks[k].text & " " & tag & ";"))
      return
    var base = cxTypeText(toks, ts, typeEnd).strip
    for w in ["extern ", "static ", "inline ", "__inline ", "__inline__ ", "__extension__ ", "register ", "_Noreturn "]:
      base = base.replace(w, "")
    base = base.strip
    if base.len == 0: return
    var isExtern = false
    for q in a ..< typeEnd:
      if toks[q].text == "extern": isExtern = true
    for (ni, stars, after) in cxDeclarators(toks, typeEnd, b):
      let nm = toks[ni].text
      # a function: name( params ) — or name _(( params )), through a portability macro (zsh's _, __P, PROTO, OF)
      var p = ni + 1
      var viaMacro = false
      if p + 2 < after and toks[p].kind == ctWord and toks[p + 1].text == "(" and toks[p + 2].text == "(":
        inc p
        viaMacro = true
      if p < after and toks[p].text == "(" and "(*)" notin stars:
        let pe = cxSkipGroup(toks, p)
        let (ps, va) = if viaMacro: cxParams(toks, p + 2, cxSkipGroup(toks, p + 1) - 1)
                       else: cxParams(toks, p + 1, pe - 1)
        let ret = (base & (if stars.len > 0: " " & stars else: "")).strip
        if isTypedef:
          typedefs.incl nm
          addSym(CxSym(name: nm, kind: cxTypedef, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                       typ: ret & " (" & nm & ")(…)", text: "typedef " & cxTypeText(toks, ts, pe)))
        else:
          var txt = ret & " " & nm & "("
          var pl: seq[string]
          for q in ps: pl.add (q.typ & (if q.name.len > 0: " " & q.name else: "")).replace("* ", "*")
          if va: pl.add "..."
          txt.add pl.join(", ") & ")"
          addSym(CxSym(name: nm, kind: cxFunc, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                       typ: ret, params: ps, varargs: va, text: txt, doc: cxDocFor(comments, toks[ts].line)))
          if full:
            for q in ps:
              if q.name.len > 0 and q.line >= 0:
                f.syms.add CxSym(name: q.name, kind: cxParam, line: q.line, col: q.col, typ: q.typ,
                                 scopeA: toks[ni].line, scopeB: toks[pe - 1].line, owner: nm,
                                 text: q.typ & " " & q.name)
        continue
      let typ = (base & (if stars.len > 0: " " & stars else: "")).strip
      if isTypedef:
        typedefs.incl nm
        addSym(CxSym(name: nm, kind: cxTypedef, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                     typ: typ, text: "typedef " & typ & " " & nm, doc: cxDocFor(comments, toks[ts].line)))
      elif base notin ["return", "goto", "case"]:
        addSym(CxSym(name: nm, kind: cxVar, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                     typ: typ, text: typ & " " & nm, doc: cxDocFor(comments, toks[ts].line), isDef: not isExtern))
  var k = 0
  var st = 0
  var transparent = 0                       # extern "C" { … }: its braces are not a body
  while k < toks.len:
    let t = toks[k]
    if t.kind == ctPunct and t.text == ";":
      if k > st: parseDecl(st, k)
      st = k + 1
      inc k
      continue
    if t.kind == ctPunct and t.text == "}" and transparent > 0:
      dec transparent
      st = k + 1
      inc k
      continue
    if t.kind == ctPunct and t.text == "{":
      # extern "C" {
      if k - st == 2 and toks[st].text == "extern" and toks[st + 1].kind == ctStr:
        if toks[st + 1].text == "\"C++\"":         # extern "C++" { … }: C++'s declarations, left out
          k = cxSkipGroup(toks, k)
          st = k
          continue
        inc transparent
        st = k + 1
        inc k
        continue
      # a function's body: name(…) {
      var p = k - 1
      while p > st and (cxNoise(toks[p].text) or toks[p].text in ["const", "__attribute__"]): dec p
      # f(…) VA_DCL {, f(…) NOEXCEPT {: macro words between the parameters and the body
      var p2 = p
      while p2 > st and toks[p2].kind == ctWord and toks[p2].text.len > 1 and
            toks[p2].text.allCharsInSet({'A'..'Z', '0'..'9', '_'}): dec p2
      if p2 < p and p2 > st and toks[p2].text == ")": p = p2
      if p > st and toks[p].text == ")":
        # find its (
        var d = 0
        var q = p
        while q >= st:
          if toks[q].text == ")": inc d
          elif toks[q].text == "(":
            dec d
            if d == 0: break
          dec q
        # (… ) __attribute__((x)) {: back over the attribute to the parameter list
        while q > st + 1 and toks[q - 1].kind == ctWord and cxNoise(toks[q - 1].text) and toks[q - 2].text == ")":
          var d2 = 0
          var q2 = q - 2
          while q2 >= st:
            if toks[q2].text == ")": inc d2
            elif toks[q2].text == "(":
              dec d2
              if d2 == 0: break
            dec q2
          q = q2
        if q > st and toks[q - 1].kind == ctWord and toks[q - 1].text notin ["if", "while", "for", "switch"]:
          let ni = q - 1
          let bodyEnd = cxSkipGroup(toks, k)
          var tEnd = ni
          var stars = ""
          while tEnd > st and toks[tEnd - 1].text == "*":
            dec tEnd
            stars.add "*"
          var ts = st
          while ts < tEnd and cxNoise(toks[ts].text):
            ts = if ts + 1 < tEnd and toks[ts + 1].text == "(": cxSkipGroup(toks, ts + 1) else: ts + 1
          let ret = (cxTypeText(toks, ts, tEnd) & (if stars.len > 0: " " & stars else: "")).strip
          let (ps, va) = cxParams(toks, q + 1, p)
          var pl: seq[string]
          for x in ps: pl.add (x.typ & (if x.name.len > 0: " " & x.name else: "")).replace("* ", "*")
          if va: pl.add "..."
          let endL = toks[bodyEnd - 1].line
          var weak = false
          for q in st ..< ni:
            if toks[q].text in ["__extern_always_inline", "__extern_inline", "__fortify_function"]: weak = true
          addSym(CxSym(name: toks[ni].text, kind: cxFunc, line: toks[ni].line, col: toks[ni].col, endLine: endL,
                       typ: (if ret.len > 0: ret else: "int"), params: ps, varargs: va, isDef: not weak, weak: weak,
                       text: (if ret.len > 0: ret else: "int") & " " & toks[ni].text & "(" & pl.join(", ") & ")",
                       doc: cxDocFor(comments, toks[ts].line)))
          for x in ps:
            if x.name.len > 0:
              f.syms.add CxSym(name: x.name, kind: cxParam, line: (if x.line >= 0: x.line else: toks[ni].line),
                               col: max(0, x.col), typ: x.typ, scopeA: toks[ni].line, scopeB: endL,
                               owner: toks[ni].text, text: x.typ & " " & x.name)
          # its locals: declarations inside, seen from their line to the end of their block
          var blockEnds: seq[int]
          var bst = k + 1
          var i = k + 1
          var depth = 1
          blockEnds.add endL
          while i < bodyEnd - 1:
            let x = toks[i]
            if i > 0 and toks[i - 1].line != x.line and toks[i - 1].kind == ctPunct and toks[i - 1].text in [".", "->"]:
              bst = i                     # (a line still being typed — `p->` — does not swallow the next one)
            if x.kind == ctPunct and x.text == "{":
              inc depth
              let ce = cxSkipGroup(toks, i)
              blockEnds.add toks[ce - 1].line
              bst = i + 1
            elif x.kind == ctPunct and x.text == "}":
              dec depth
              if blockEnds.len > 1: blockEnds.setLen(blockEnds.len - 1)
              bst = i + 1
            elif x.kind == ctPunct and x.text == ";":
              bst = i + 1

            elif x.kind == ctWord and x.text == "for" and i + 1 < bodyEnd and toks[i + 1].text == "(":
              bst = i + 2                 # for (int i = 0; …): the declaration starts after the (
              inc i
              inc i
              continue
            elif i == bst and x.kind == ctWord and i + 1 < bodyEnd - 1 and toks[i + 1].text == ":" and
                 x.text notin ["default", "case"]:
              # a label — `goto` it from anywhere in the function
              f.syms.add CxSym(name: x.text, kind: cxLabel, line: x.line, col: x.col, scopeA: toks[ni].line,
                               scopeB: endL, owner: toks[ni].text, text: x.text & ":")
              bst = i + 2
              i += 2
              continue
            elif i == bst and toks[i].kind == ctWord and
                 toks[i].text notin ["return", "goto", "case", "else", "do", "sizeof", "break", "continue", "default",
                                     "if", "while", "switch", "for"] and
                 (cxIsTypeStart(toks, i, typedefs) or
                  (i + 2 < bodyEnd and toks[i + 1].kind == ctWord and toks[i + 2].text in [";", "=", ",", "["]) or
                  (block:
                    # a type named in a header (not known here): `T *p;`, `T **pp = 0;`
                    var j = i + 1
                    var stars = 0
                    while j < bodyEnd and toks[j].text in ["*", "const", "volatile", "restrict", "__restrict"]:
                      if toks[j].text == "*": inc stars
                      inc j
                    stars > 0 and j + 1 < bodyEnd and toks[j].kind == ctWord and
                      toks[j + 1].text in [";", "=", ",", "["])) and
                 not (i + 1 < bodyEnd and toks[i + 1].kind == ctPunct and toks[i + 1].text in ["(", "=", "[", ".", "->"]):
              # a declaration statement: type declarators ;
              var e = i
              var dd = 0
              while e < bodyEnd - 1:
                let y = toks[e]
                if y.kind == ctPunct and y.text in ["(", "[", "{"]: inc dd
                elif y.kind == ctPunct and y.text in [")", "]", "}"]:
                  if dd == 0: break
                  dec dd
                elif y.text == ";" and dd == 0: break
                inc e
              # struct { … } x; — a type of its own, declared here (its members known too)
              var r0 = i
              while r0 < e and toks[r0].text in CxQualifiers: inc r0
              if r0 + 1 < e and toks[r0].text in ["struct", "union", "enum"] and
                 (toks[r0 + 1].text == "{" or (toks[r0 + 1].kind == ctWord and r0 + 2 < e and toks[r0 + 2].text == "{")):
                let word = toks[r0].text
                let tag2 = if toks[r0 + 1].kind == ctWord: toks[r0 + 1].text else: ""
                let ob = if tag2.len > 0: r0 + 2 else: r0 + 1
                let be = cxSkipGroup(toks, ob)
                let nk = (case word
                          of "struct": cxStruct
                          of "union": cxUnion
                          else: cxEnum)
                let nm = if tag2.len > 0: tag2 else: anonName(word, toks[r0].line)
                addSym(CxSym(name: nm, kind: nk, line: toks[r0].line, col: toks[r0].col, endLine: toks[be - 1].line,
                             isDef: true, text: word & " " & (if tag2.len > 0: tag2 & " " else: "") & "{ … }"))
                parseMembers(ob + 1, be - 1, nm, nk)
                for (ni2, stars2, _) in cxDeclarators(toks, be, e):
                  let typ = word & " " & nm & (if stars2.len > 0: " " & stars2 else: "")
                  f.syms.add CxSym(name: toks[ni2].text, kind: cxLocal, line: toks[ni2].line, col: toks[ni2].col,
                                   typ: typ, scopeA: toks[ni2].line, scopeB: blockEnds[^1], owner: toks[ni].text,
                                   text: typ & " " & toks[ni2].text)
                i = e
                continue
              let typeEnd = cxTypeEnd(toks, i, e)
              if typeEnd > i and typeEnd < e:
                let baseT = cxTypeText(toks, i, typeEnd).strip
                for (ni2, stars2, _) in cxDeclarators(toks, typeEnd, e):
                  let typ = (baseT & (if stars2.len > 0: " " & stars2 else: "")).strip
                  f.syms.add CxSym(name: toks[ni2].text, kind: cxLocal, line: toks[ni2].line, col: toks[ni2].col,
                                   typ: typ, scopeA: toks[ni2].line, scopeB: blockEnds[^1], owner: toks[ni].text,
                                   text: typ & " " & toks[ni2].text)
              i = e
              continue
            inc i
          k = bodyEnd
          st = k
          continue
      # a struct / union / enum body or an initializer: to its end, then on to the `;`
      k = cxSkipGroup(toks, k)
      continue
    inc k
  if st < toks.len: parseDecl(st, toks.len)

proc cxStampOf(path: string): string =
  try:
    let i = getFileInfo(path)
    $i.lastWriteTime.toUnix & "/" & $i.lastWriteTime.nanosecond & "/" & $i.size
  except CatchableError: ""

proc cxLoad*(path: string, text = "", stamp = ""): CxFile =
  ## a file's index: from `text` (an open buffer, with its own stamp) or from disk; cached until it changes (a file
  ## read from disk does not keep its lines: headers are many)
  if text.len == 0 and stamp.len == 0 and path in cxCache:
    let now = epochTime()
    if now - cxCheckedAt.getOrDefault(path, 0.0) < 1.0: return cxCache[path]
    cxCheckedAt[path] = now
  let st = if stamp.len > 0: stamp else: cxStampOf(path)
  if st.len == 0 and text.len == 0: return nil
  if path in cxCache and cxCache[path].stamp == st: return cxCache[path]
  var t = text
  if t.len == 0 and stamp.len == 0:
    try:
      t = readFile(path)
      if t.len > 6_000_000: t.setLen(6_000_000)
    except CatchableError: return nil
  result = cxParse(t, path, full = text.len > 0)
  result.stamp = st
  if text.len == 0: result.lines = @[]
  if cxCache.len > 3000:
    cxCache.clear()
    cxCheckedAt.clear()
  cxCache[path] = result
  if text.len == 0: cxCheckedAt[path] = epochTime()

proc cxFindInclude*(name, fromDir: string): string =
  ## the file an #include names: "x.h" next to the including file first, then the include folders (#include_next,
  ## written "next<x.h>": the folders after the including file's)
  if name.startsWith("next"):
    let n = name[4 .. ^1].strip(chars = {'<', '>', '"'})
    var after = -1
    for i, d in cxDirs:
      if d.strip(leading = false, chars = {'/'}) == fromDir.strip(leading = false, chars = {'/'}): after = i
    for i in after + 1 .. cxDirs.high:
      if cxDirs[i] != fromDir and fileExists(cxDirs[i] / n): return cxDirs[i] / n
    return ""
  let angle = name.startsWith("<")
  let n = name.strip(chars = {'<', '>', '"'})
  if n.isAbsolute: return (if fileExists(n): n else: "")
  if not angle and fileExists(fromDir / n): return fromDir / n
  for d in cxDirs:
    if fileExists(d / n): return d / n
  if angle and fileExists(fromDir / n): return fromDir / n
  ""

var cxClosureCache: Table[string, (string, float, seq[CxFile])]   # path → (its stamp, when, the closure)

proc cxClosure*(f: CxFile, maxFiles = 400): seq[CxFile] =
  ## the file and every file it includes, transitively (each once) — kept a couple of seconds
  let now = epochTime()
  if f.path in cxClosureCache:
    let (st, at, files) = cxClosureCache[f.path]
    if st == f.stamp and now - at < 2.0 and files.len > 0 and files[0] == f: return files
  defer: cxClosureCache[f.path] = (f.stamp, now, result)
  var seen: HashSet[string]
  var stack = @[f]
  while stack.len > 0 and result.len < maxFiles:
    let g = stack.pop()
    if g == nil or g.path in seen: continue
    seen.incl g.path
    result.add g
    for (inc, _) in g.includes:
      let p = cxFindInclude(inc, parentDir(g.path))
      if p.len > 0 and p notin seen:
        let h = cxLoad(p)
        if h != nil: stack.add h

# ── types ──

proc cxStrip*(t: string): (string, int) =
  ## a C type without qualifiers, and how many pointers deep it is: "const struct p **" → ("struct p", 2)
  var stars = 0
  var words: seq[string]
  for w in t.replace("*", " * ").replace("(*)", " * ").splitWhitespace:
    if w == "*": inc stars
    elif w in CxQualifiers or w.startsWith("__attribute"): discard
    else: words.add w
  (words.join(" "), stars)

proc cxIndexed(g: CxFile) =
  if g.indexed: return
  g.indexed = true
  for k, s in g.syms:
    if s.kind in {cxParam, cxLocal, cxLabel}: continue
    g.byName.mgetOrPut(s.name, @[]).add k.int32
    if s.kind == cxField: g.byOwner.mgetOrPut(s.owner, @[]).add k.int32

iterator cxNamed*(g: CxFile, name: string): int =
  ## the indexes of g's declarations called `name` (not parameters, locals or labels)
  cxIndexed(g)
  g.byName.withValue(name, ks):
    for k in ks[]: yield k.int

proc cxFindSym*(files: seq[CxFile], name: string, kinds: set[CxKind]): (CxFile, int) =
  for g in files:
    for k in cxNamed(g, name):
      if g.syms[k].kind in kinds: return (g, k)
  (nil, -1)

proc cxDropMarkers(files: seq[CxFile], base: string): string =
  ## a type without the words that are macros meaning nothing to it: export markers (`mod_export struct job`,
  ## `API Foo`) — macros defined empty, or as attributes only
  let ws = base.splitWhitespace
  if ws.len < 2: return base
  var keep: seq[string]
  for w in ws:
    if w notin CxTypeWords and w notin ["struct", "union", "enum"]:
      let (g, k) = cxFindSym(files, w, {cxMacro})
      if g != nil and g.syms[k].params.len == 0 and not g.syms[k].varargs:
        let body = g.syms[k].text["#define ".len + w.len .. ^1].strip
        if body.len == 0 or body.startsWith("__attribute") or body.startsWith("__declspec"): continue
    keep.add w
  keep.join(" ")

proc cxRecord*(files: seq[CxFile], typ: string): (string, int) =
  ## the struct or union a type is (through typedefs): its name as fields know it as their owner, and the
  ## pointer depth left — ("", 0) when it is not one
  var (base, stars) = cxStrip(typ)
  base = cxDropMarkers(files, base)
  for _ in 0 .. 8:
    for kw in ["struct ", "union "]:
      if base.startsWith(kw): return (base[kw.len .. ^1].strip, stars)     # (an anonymous one's name has spaces)
    let w = base.splitWhitespace
    if w.len == 1:
      # a typedef: what it names (a struct named by the typedef only is filed under the typedef's name)
      let (g, k) = cxFindSym(files, w[0], {cxTypedef})
      if g != nil:
        var (b2, s2) = cxStrip(g.syms[k].typ)
        b2 = cxDropMarkers(files, b2)
        let ww = b2.splitWhitespace
        if ww.len == 2 and ww[0] in ["struct", "union"] and ww[1] == w[0]: return (w[0], stars + s2)
        base = b2
        stars += s2
        continue
      let (g2, _) = cxFindSym(files, w[0], {cxStruct, cxUnion})
      if g2 != nil: return (w[0], stars)
    return ("", 0)
  ("", 0)

proc cxFields*(files: seq[CxFile], owner: string): seq[(CxFile, int)] =
  for g in files:
    cxIndexed(g)
    g.byOwner.withValue(owner, ks):
      for k in ks[]: result.add (g, k.int)

proc cxLocalsAt*(f: CxFile, line: int): seq[CxSym] =
  ## the parameters, locals and labels seen on `line` (the innermost last)
  for s in f.syms:
    if s.kind in {cxParam, cxLocal, cxLabel} and line >= s.scopeA and line <= s.scopeB and
       (s.kind != cxLocal or s.line <= line): result.add s

proc cxTypeOfName*(files: seq[CxFile], f: CxFile, name: string, line: int): string =
  let ls = cxLocalsAt(f, line)
  for i in countdown(ls.high, 0):
    if ls[i].name == name and ls[i].kind != cxLabel: return ls[i].typ
  let (g, k) = cxFindSym(files, name, {cxVar, cxFunc, cxEnumConst})
  if g != nil:
    let s = g.syms[k]
    return (if s.kind == cxFunc: "fn:" & s.typ else: s.typ)

proc cxTypeOfExpr*(files: seq[CxFile], f: CxFile, expr: string, line: int, depth = 0): string =
  ## the type of `a.b->c[i]`, `p->next`, `get(x).y`, `*pp`, `(struct q *)v` — "" when not known; a name that is
  ## a macro (`#define atime tv[0]`) has its expansion's type
  var s = expr.strip
  var derefs = 0
  while s.startsWith("*"):
    inc derefs
    s = s[1 .. ^1].strip
  var addrOf = false
  if s.startsWith("&"):
    addrOf = true
    s = s[1 .. ^1].strip
  var typ = ""
  var i = 0
  if s.startsWith("("):
    # a cast (type)x, or a parenthesized expression
    var d = 0
    var e = 0
    while e < s.len:
      if s[e] == '(': inc d
      elif s[e] == ')':
        dec d
        if d == 0: break
      inc e
    if e >= s.len: return ""
    let inner = s[1 ..< e].strip
    let rest = s[e + 1 .. ^1].strip
    let words = inner.replace("*", " ").splitWhitespace
    if words.len > 0 and (words[0] in CxTypeWords or cxFindSym(files, words[0], {cxTypedef})[0] != nil) and
       rest.len > 0 and rest[0] notin {'.', '-', '['}:
      typ = inner                            # (struct q *)v
      i = s.len
    else:
      typ = cxTypeOfExpr(files, f, inner, line, depth + 1)
      i = e + 1
  else:
    var e = 0
    while e < s.len and s[e] in IdentChars: inc e
    if e == 0: return ""
    let name = s[0 ..< e]
    typ = cxTypeOfName(files, f, name, line)
    i = e
    if typ.len == 0 and depth < 4:
      # a macro: its expansion's type — `#define atime tv[0]`, `#define P_OPERAND(p) ((Upat)(p) + 1)` with the
      # arguments put in
      let (g, k) = cxFindSym(files, name, {cxMacro})
      if g != nil and not g.syms[k].text.endsWith("…"):
        let m = g.syms[k]
        var body = m.text["#define ".len + name.len .. ^1]
        if m.params.len == 0 and not m.varargs and not body.startsWith("("):
          if body.strip.len > 0: typ = cxTypeOfExpr(files, f, body.strip, line, depth + 1)
        elif body.startsWith("("):
          var pe = body.find(')')
          var j = i
          while j < s.len and s[j] == ' ': inc j
          if pe > 0 and j < s.len and s[j] == '(':
            body = body[pe + 1 .. ^1].strip
            # the arguments, at the call's top-level commas
            var d = 0
            var a = j + 1
            var args: seq[string]
            var q = j
            while q < s.len:
              if s[q] in {'(', '['}: inc d
              elif s[q] in {')', ']'}:
                dec d
                if d == 0:
                  args.add s[a ..< q].strip
                  break
              elif s[q] == ',' and d == 1:
                args.add s[a ..< q].strip
                a = q + 1
              inc q
            if q < s.len and args.len == m.params.len:
              var ex = ""
              var r = 0
              while r < body.len:                       # each parameter, as a whole word, by its argument
                if body[r] in IdentStartChars and (r == 0 or body[r - 1] notin IdentChars):
                  var t = r
                  while t < body.len and body[t] in IdentChars: inc t
                  let w = body[r ..< t]
                  var hit = -1
                  for pi, prm in m.params:
                    if prm.name == w: hit = pi
                  ex.add(if hit >= 0: "(" & args[hit] & ")" else: w)
                  r = t
                else:
                  ex.add body[r]
                  inc r
              typ = cxTypeOfExpr(files, f, ex, line, depth + 1)
              i = q + 1
  while i < s.len:
    while i < s.len and s[i] == ' ': inc i
    if i >= s.len: break
    if s[i] == '(':
      # a call: what the function returns
      var d = 0
      var e = i
      while e < s.len:
        if s[e] == '(': inc d
        elif s[e] == ')':
          dec d
          if d == 0: break
        inc e
      typ = if typ.startsWith("fn:"): typ[3 .. ^1] else: ""
      i = e + 1
    elif s[i] == '[':
      var d = 0
      var e = i
      while e < s.len:
        if s[e] == '[': inc d
        elif s[e] == ']':
          dec d
          if d == 0: break
        inc e
      let (b, st) = cxStrip(typ)
      typ = b & (if st > 1: " " & "*".repeat(st - 1) else: "")
      i = e + 1
    elif s[i] == '.' or s.continuesWith("->", i):
      i += (if s[i] == '.': 1 else: 2)
      var e = i
      while e < s.len and s[e] in IdentChars: inc e
      let m = s[i ..< e]
      let (rec, _) = cxRecord(files, typ)
      if rec.len == 0: return ""
      typ = ""
      for (g, k) in cxFields(files, rec):
        if g.syms[k].name == m:
          typ = g.syms[k].typ
          break
      if typ.len == 0: return ""
      i = e
    else: break
  if typ.startsWith("fn:"): typ = typ[3 .. ^1]
  if derefs > 0:
    let (b, st) = cxStrip(typ)
    typ = b & (if st > derefs: " " & "*".repeat(st - derefs) else: "")
  if addrOf: typ = typ & " *"
  typ

# ── answers ──

type
  CxItem* = object
    label*, detail*, doc*: string
    kind*: CxKind
    rank*: int                  # 0 locals · 1 this file · 2 its headers · 3 system headers · 4 keywords
    insert*: string

proc cxAfterWord(t: string, at: int, words: openArray[string]): bool =
  ## is the text before `at` one of `words` (as a whole word, spaces between)
  var e = at
  while e > 0 and t[e - 1] in {' ', '\t'}: dec e
  for w in words:
    if e >= w.len and t[e - w.len ..< e] == w and (e == w.len or t[e - w.len - 1] notin IdentChars): return true

proc cxReceiver*(line: string, endAt: int): string =
  ## the expression before `.` or `->` that ends at endAt (exclusive): `a.b[i]->` → "a.b[i]", `get(x)` → "get(x)"
  var k = endAt - 1
  var d = 0
  while k >= 0:
    let c = line[k]
    if c in {')', ']'} and d == 0 and k + 1 < endAt and line[k + 1] in IdentChars: break   # (T)x.y: x.y, cast
    if c in {')', ']'}: inc d
    elif c in {'(', '['}:
      if d == 0: break
      dec d
    elif d > 0: discard
    elif c in IdentChars or c == '.': discard
    elif c == '>' and k > 0 and line[k - 1] == '-': dec k
    else: break
    dec k
  line[k + 1 ..< endAt].strip

proc cxInitType*(files: seq[CxFile], f: CxFile, line, col: int, depth = 0): string =
  ## the type a brace initializer initializes at line:col (inside its braces) — for `.member =` designators:
  ## `struct p v = { .x = 1, .` → "struct p"; `{ .at = { .` → at's type; `arr[] = { { .` → arr's element type
  if depth > 6: return ""
  var d = 0
  var l = min(line, f.lines.high)
  while l >= max(0, line - 60):
    let t = f.lines[l]
    var k = (if l == line: min(col, t.len) else: t.len) - 1
    while k >= 0:
      let ch = t[k]
      if ch == '}': inc d
      elif ch == ';' and d == 0: return ""
      elif ch == '{':
        if d > 0:
          dec d
          dec k
          continue
        # what comes before the {: `name =`, `.member =`, or `{` / `,` (an element of an array)
        var bl = l
        var bk = k - 1
        while true:
          while bk >= 0 and f.lines[bl][bk] in {' ', '\t'}: dec bk
          if bk >= 0 or bl == 0 or bl <= line - 60: break
          dec bl
          bk = f.lines[bl].len - 1
        if bk < 0: return ""
        let bt = f.lines[bl]
        if bt[bk] in {'{', ','}:
          # an element: the outer initializer's type, one level less
          let outer = cxInitType(files, f, bl, (if bt[bk] == '{': bk + 1 else: bk), depth + 1)
          let (b, st) = cxStrip(outer)
          return (if st > 0: b & (if st > 1: " " & "*".repeat(st - 1) else: "") else: "")
        if bt[bk] != '=': return ""
        dec bk
        while bk >= 0 and bt[bk] in {' ', '\t'}: dec bk
        while bk >= 0 and bt[bk] == ']':                 # name[] = { … }, name[N] = { … }: the array's type
          while bk >= 0 and bt[bk] != '[': dec bk
          dec bk
          while bk >= 0 and bt[bk] in {' ', '\t'}: dec bk
        var a = bk
        while a >= 0 and bt[a] in IdentChars: dec a
        let name = bt[a + 1 .. bk]
        if name.len == 0: return ""
        var p = a
        while p >= 0 and bt[p] in {' ', '\t'}: dec p
        if p >= 0 and bt[p] == '.':
          # a nested designator: the member's type in the outer initializer's
          let outer = cxInitType(files, f, bl, p, depth + 1)
          let (rec, _) = cxRecord(files, outer)
          if rec.len == 0: return ""
          for (g, q) in cxFields(files, rec):
            if g.syms[q].name == name: return g.syms[q].typ
          return ""
        let typ = cxTypeOfName(files, f, name, bl)
        return (if typ.startsWith("fn:"): "" else: typ)
      dec k
    dec l
  ""

proc cxIncludeItems(f: CxFile, t: string, col: int, systemDirs: seq[string]): (bool, seq[CxItem]) =
  ## on an #include line: the headers the folders have, after what is typed (`<sys/ty` → sys/'s headers) — the
  ## file's own folder first, then the project's, then the system's
  let s = t.strip(trailing = false)
  if not (s.startsWith("#include") or s.startsWith("# include")): return
  var q = -1
  for k in 0 ..< min(col, t.len):
    if t[k] in {'<', '"'}: q = k
  if q < 0: return
  result[0] = true
  let typed = t[q + 1 ..< min(col, t.len)]
  let slash = typed.rfind('/')
  let sub = if slash >= 0: typed[0 .. slash] else: ""
  let pre = if slash >= 0: typed[slash + 1 .. ^1] else: typed
  var dirs: seq[string]
  if t[q] == '"' and f.path.len > 0: dirs.add parentDir(f.path)
  dirs.add cxDirs
  var seen: HashSet[string]
  for di, d in dirs:
    let dd = d / sub
    if not dirExists(dd): continue
    var rank = 2
    if di == 0 and t[q] == '"': rank = 1
    else:
      for sd in systemDirs:
        if d.startsWith(sd): rank = 3
    for kind, p in walkDir(dd, relative = true):
      if not p.startsWith(pre) or p in seen or p.startsWith("."): continue
      if kind in {pcDir, pcLinkToDir}:
        seen.incl p
        result[1].add CxItem(label: p & "/", detail: "folder", kind: cxMacro, rank: rank)
      elif p.endsWith(".h") or p.endsWith(".hpp") or p.endsWith(".hh") or ('.' notin p and sub.len > 0):
        seen.incl p
        result[1].add CxItem(label: p, detail: d / sub, kind: cxMacro, rank: rank)
      if result[1].len > 400: return

proc cxComplete*(f: CxFile, line, col: int, systemDirs: seq[string] = @[]): (seq[CxItem], bool, string) =
  ## completion at line:col: (items, after a member access, the type there)
  if f == nil or line >= f.lines.len: return
  let t = f.lines[line]
  var c = min(col, t.len)
  var w = c
  while w > 0 and t[w - 1] in IdentChars: dec w
  let (onInclude, headers) = cxIncludeItems(f, t, c, systemDirs)
  if onInclude:
    result[0] = headers
    return
  let files = cxClosure(f)
  # after . or ->: the members
  var mEnd = -1
  if w > 0 and t[w - 1] == '.': mEnd = w - 1
  elif w > 1 and t[w - 1] == '>' and t[w - 2] == '-': mEnd = w - 2
  if mEnd >= 0:
    let recv = cxReceiver(t, mEnd)
    # (`{ .x = 1, .` — a designated initializer: the members of what it initializes)
    let typ = if recv.len == 0 and t[mEnd] == '.': cxInitType(files, f, line, mEnd)
              else: cxTypeOfExpr(files, f, recv, line)
    result[1] = true
    result[2] = typ
    let (rec, _) = cxRecord(files, typ)
    if rec.len == 0: return
    for (g, k) in cxFields(files, rec):
      let s = g.syms[k]
      result[0].add CxItem(label: s.name, detail: s.typ, doc: s.doc, kind: cxField, rank: 0)
    return
  var seen: HashSet[string]
  let ls = cxLocalsAt(f, line)
  let afterGoto = cxAfterWord(t, w, ["goto"])
  for i in countdown(ls.high, 0):
    let s = ls[i]
    if s.name in seen or (s.kind == cxLabel) != afterGoto: continue
    seen.incl s.name
    result[0].add CxItem(label: s.name, detail: (if s.kind == cxLabel: "label" else: s.typ), kind: s.kind, rank: 0)
  if afterGoto: return
  for gi, g in files:
    let sys = gi > 0 and systemDirs.len > 0 and (block:
      var y = false
      for d in systemDirs:
        if g.path.startsWith(d): y = true
      y)
    for s in g.syms:
      if s.kind in {cxParam, cxLocal, cxField, cxLabel} or s.name in seen: continue
      if s.name.startsWith("__") or (s.name.startsWith("_") and (sys or (gi > 0 and s.name.len > 1 and s.name[1] in {'A'..'Z'}))):
        continue
      if s.name.startsWith("(anonymous"): continue
      seen.incl s.name
      result[0].add CxItem(label: s.name, detail: (if s.kind == cxFunc: s.text else: s.typ), doc: s.doc, kind: s.kind,
                           rank: (if gi == 0: 1 elif sys: 3 else: 2))
  for kw in CxKeywords:
    if kw notin seen: result[0].add CxItem(label: kw, detail: "keyword", kind: cxMacro, rank: 4)

proc cxWordAt*(t: string, col: int): (int, int) =
  var a = min(col, t.len)
  var e = a
  while a > 0 and t[a - 1] in IdentChars: dec a
  while e < t.len and t[e] in IdentChars: inc e
  (a, e)

proc cxTargets*(f: CxFile, line, col: int, jump = false): seq[(CxFile, CxSym)] =
  ## what the word at line:col names: a member, a local, parameter or label, or declarations in the file and its
  ## headers (a function's definition before its prototype; a typedef before the struct it names). jump: on a
  ## function definition's own name, its declarations first (the header's prototype), as clangd's go to definition
  if f == nil or line >= f.lines.len: return
  let t = f.lines[line]
  let (a, e) = cxWordAt(t, col)
  if a >= e: return
  let w = t[a ..< e]
  let files = cxClosure(f)
  # a member: x.w, p->w
  var mEnd = -1
  if a > 0 and t[a - 1] == '.': mEnd = a - 1
  elif a > 1 and t[a - 1] == '>' and t[a - 2] == '-': mEnd = a - 2
  if mEnd >= 0:
    let recv = cxReceiver(t, mEnd)
    let typ = if recv.len == 0 and t[mEnd] == '.': cxInitType(files, f, line, mEnd)
              else: cxTypeOfExpr(files, f, recv, line)
    let (rec, _) = cxRecord(files, typ)
    if rec.len > 0:
      for (g, k) in cxFields(files, rec):
        if g.syms[k].name == w: return @[(g, g.syms[k])]
    return
  # the declaration itself
  for s in f.syms:
    if s.name == w and s.line == line and s.col == a:
      if jump and s.kind in {cxFunc, cxVar}:
        # a definition's name: its prototype (extern declaration); a prototype's: the body
        var others: seq[(CxFile, CxSym)]
        for g in files:
          for k in cxNamed(g, w):
            let x = g.syms[k]
            if x.kind == s.kind and x.isDef != s.isDef and not x.weak: others.add (g, x)
        if others.len > 0: return others & @[(f, s)]
      return @[(f, s)]
  let afterGoto = cxAfterWord(t, a, ["goto"])
  let tagged = cxAfterWord(t, a, ["struct", "union", "enum"])     # (a tag: not a variable of the same name)
  if not tagged:
    let ls = cxLocalsAt(f, line)
    for i in countdown(ls.high, 0):
      if ls[i].name == w and (ls[i].kind == cxLabel) == afterGoto: return @[(f, ls[i])]
  if afterGoto: return
  var types, defs, decls, macros: seq[(CxFile, CxSym)]
  for g in files:
    for k in cxNamed(g, w):
      let s = g.syms[k]
      if s.kind notin {cxField}:
        # (a macro of a function's name — fortify, 64-bit names — and inline wrappers last)
        if s.kind == cxMacro or s.weak: macros.add (g, s)
        elif s.kind == cxTypedef and not tagged: types.add (g, s)
        elif s.isDef or s.kind notin {cxFunc, cxStruct, cxUnion, cxEnum, cxVar}: defs.add (g, s)
        else: decls.add (g, s)
  result = types & defs & decls & macros

proc cxBodyIn*(paths: openArray[string], name: string, kind = cxFunc): (CxFile, int) =
  ## a function's body (or a struct's members — an opaque type's) in one of these .c files (each read once, then
  ## kept while it is unchanged)
  for p in paths:
    let h = cxLoad(p)
    if h == nil: continue
    for k in cxNamed(h, name):
      if h.syms[k].kind == kind and h.syms[k].isDef: return (h, k)
  (nil, -1)

proc cxHover*(f: CxFile, line, col: int): string =
  let ts = cxTargets(f, line, col)
  if ts.len == 0: return ""
  let (g, s) = ts[0]
  var doc = s.doc
  if doc.len == 0 and s.kind in {cxFunc, cxVar, cxStruct, cxUnion, cxEnum, cxTypedef}:
    # (a definition in a .c file, its comment on the prototype in the header)
    block find:
      for g2 in cxClosure(f):
        for k in cxNamed(g2, s.name):
          let x = g2.syms[k]
          if x.kind == s.kind and x.doc.len > 0:
            doc = x.doc
            break find
  let kindWord = case s.kind
    of cxFunc: "function"
    of cxStruct: "struct"
    of cxUnion: "union"
    of cxEnum: "enum"
    of cxTypedef: "type"
    of cxMacro: "macro"
    of cxVar: "variable"
    of cxEnumConst: "enum constant"
    of cxField: "field of " & s.owner
    of cxParam: "parameter of " & s.owner
    of cxLocal: "local of " & s.owner
    of cxLabel: "label in " & s.owner
  result = "```c\n" & s.text & "\n```\n" & kindWord & " · " & extractFilename(g.path) & ":" & $(s.line + 1)
  if doc.len > 0: result.add "\n\n" & doc
  if s.kind in {cxStruct, cxUnion}:
    var fl: seq[string]
    for (g2, k) in cxFields(cxClosure(f), s.name):
      if fl.len < 12: fl.add g2.syms[k].text & ";"
    if fl.len > 0: result.add "\n```c\n{ " & fl.join(" ") & " }\n```"

proc cxSignature*(f: CxFile, line, col: int): (CxSym, int) =
  ## the call around line:col: the function (kind cxFunc, or a function-like macro) and the parameter being typed
  if f == nil or line >= f.lines.len: return
  let t = f.lines[line]
  var k = min(col, t.len) - 1
  var d = 0
  var commas = 0
  while k >= 0:
    let c = t[k]
    if c in {')', ']'}: inc d
    elif c in {'(', '['}:
      if d == 0:
        if c == '(': break
        return
      dec d
    elif c == ',' and d == 0: inc commas
    elif c == '"':
      dec k
      while k >= 0 and t[k] != '"': dec k
    dec k
  if k <= 0: return
  var e = k
  while e > 0 and t[e - 1] == ' ': dec e
  var a = e
  while a > 0 and t[a - 1] in IdentChars: dec a
  if a == e: return
  let name = t[a ..< e]
  let files = cxClosure(f)
  var best = -1
  var bf: CxFile
  for g in files:
    for i in cxNamed(g, name):
      let s = g.syms[i]
      if s.kind in {cxFunc, cxMacro} and (best < 0 or s.isDef):
        best = i
        bf = g
  if best < 0: return
  (bf.syms[best], commas)

proc cxOutline*(f: CxFile): seq[CxSym] =
  if f == nil: return
  for s in f.syms:
    if s.kind in {cxFunc, cxStruct, cxUnion, cxEnum, cxTypedef, cxMacro, cxVar} and not s.name.startsWith("(anonymous") and
       not (s.kind in {cxStruct, cxUnion, cxEnum} and not s.isDef):
      result.add s
  result.sort(proc(a, b: CxSym): int = cmp(a.line, b.line))

proc cxOccurrences*(lines: seq[string], name: string, a = 0, b = high(int)): seq[(int, int)] =
  ## where `name` is written as a word (not in strings, characters or comments) on lines a..b
  var inBlock = false
  for l in max(0, a) .. min(lines.high, b):
    let t = lines[l]
    if not inBlock and t.strip(trailing = false).startsWith("#include"): continue
    var i = 0
    while i < t.len:
      if inBlock:
        let e = t.find("*/", i)
        if e < 0: break
        inBlock = false
        i = e + 2
        continue
      let c = t[i]
      if c == '/' and i + 1 < t.len and t[i + 1] == '/': break
      if c == '/' and i + 1 < t.len and t[i + 1] == '*':
        inBlock = true
        i += 2
        continue
      if c in {'"', '\''}:
        inc i
        while i < t.len and t[i] != c:
          if t[i] == '\\': inc i
          inc i
        inc i
        continue
      if c in IdentStartChars and (i == 0 or t[i - 1] notin IdentChars):
        var e = i
        while e < t.len and t[e] in IdentChars: inc e
        if e - i == name.len and t[i ..< e] == name: result.add (l, i)
        i = e
        continue
      inc i
