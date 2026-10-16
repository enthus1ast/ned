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
    cxFunc, cxStruct, cxUnion, cxEnum, cxTypedef, cxMacro, cxVar, cxEnumConst, cxField, cxParam, cxLocal
  CxParam* = object
    name*, typ*: string
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
    scopeA*, scopeB*: int       # locals and parameters: the lines they are seen on
  CxFile* = ref object
    path*: string
    stamp*: string
    syms*: seq[CxSym]
    includes*: seq[(string, int)]     # as written (<x.h> or "y.h"), and the line
    lines*: seq[string]
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

var
  cxCache: Table[string, CxFile]               # path → its index (by modification time and size, or a text stamp)
  cxDirs*: seq[string]                         # where #include <…> and "…" look (set by the editor)

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
    "APIENTRY", "CALLBACK", "__cdecl", "__stdcall", "__fastcall", "__inline_always"]

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
    result[0].add CxParam(name: (if nameAt >= 0: toks[nameAt].text else: ""), typ: typ.strip)

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

proc cxParse*(text, path: string): CxFile =
  ## one C file's declarations (not the ones of the files it includes)
  result = CxFile(path: path)
  let f = result
  var toks: seq[CxTok]
  var comments: seq[CxComment]
  var pp: seq[(int, string)]
  cxLex(text, toks, comments, pp)
  f.lines = text.splitLines
  var typedefs: HashSet[string]
  # preprocessor: #define, #include
  for (l, d) in pp:
    let t = d[1 .. ^1].strip
    if t.startsWith("include"):
      let r = t[7 .. ^1].strip
      if r.len >= 3 and r[0] in {'<', '"'}:
        let close = r.find((if r[0] == '<': '>' else: '"'), 1)
        if close > 0: f.includes.add (r[0 .. close], l)
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
  var anonN = 0
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
              inc anonN
              let nm = if st + 1 < k and toks[st + 1].kind == ctWord and toks[st + 1].text != "{": toks[st + 1].text
                       else: "(anonymous " & toks[st].text & " " & $anonN & ")"
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
        if nm.len == 0:
          inc anonN
          nm = "(anonymous " & toks[k].text & " " & $anonN & ")"
        let word = toks[k].text
        addSym(CxSym(name: nm, kind: tagKind, line: toks[tagAt].line, col: toks[tagAt].col,
                     endLine: toks[bodyEnd - 1].line, isDef: true,
                     text: word & " " & (if tag.len > 0: tag & " " else: "") & "{ … }"))
        parseMembers(j + 1, bodyEnd - 1, nm, tagKind)
        # declarators after the body: typedef names, or variables of this type
        let decls = cxDeclarators(toks, bodyEnd, b)
        for (ni, stars, _) in decls:
          let typ = word & " " & nm & (if stars.len > 0: " " & stars else: "")
          if isTypedef:
            typedefs.incl toks[ni].text
            addSym(CxSym(name: toks[ni].text, kind: cxTypedef, line: toks[ni].line, col: toks[ni].col,
                         endLine: toks[ni].line, typ: typ, text: "typedef " & word & " " &
                         (if tag.len > 0: tag & " " else: "") & "{ … } " & stars & toks[ni].text,
                         doc: cxDocFor(comments, toks[k].line)))
            # an anonymous struct named only by its typedef: the struct takes its name too (fields' owner)
            if tag.len == 0 and stars.len == 0:
              for x in f.syms.mitems:
                if x.owner == nm: x.owner = toks[ni].text
                if x.name == nm and x.kind == tagKind: x.name = toks[ni].text
          else:
            addSym(CxSym(name: toks[ni].text, kind: cxVar, line: toks[ni].line, col: toks[ni].col,
                         endLine: toks[ni].line, typ: typ, text: typ & " " & toks[ni].text))
        return
    # the type: up to the first declarator
    let ts = k
    let typeEnd = cxTypeEnd(toks, ts, b)
    if typeEnd >= b: return
    var base = cxTypeText(toks, ts, typeEnd).strip
    for w in ["extern ", "static ", "inline ", "__inline ", "__inline__ ", "__extension__ ", "register ", "_Noreturn "]:
      base = base.replace(w, "")
    base = base.strip
    if base.len == 0: return
    for (ni, stars, after) in cxDeclarators(toks, typeEnd, b):
      let nm = toks[ni].text
      # a function: name( params )
      var p = ni + 1
      if p < after and toks[p].text == "(" and "(*)" notin stars:
        let pe = cxSkipGroup(toks, p)
        let (ps, va) = cxParams(toks, p + 1, pe - 1)
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
        continue
      let typ = (base & (if stars.len > 0: " " & stars else: "")).strip
      if isTypedef:
        typedefs.incl nm
        addSym(CxSym(name: nm, kind: cxTypedef, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                     typ: typ, text: "typedef " & typ & " " & nm, doc: cxDocFor(comments, toks[ts].line)))
      elif base notin ["return", "goto", "case"]:
        addSym(CxSym(name: nm, kind: cxVar, line: toks[ni].line, col: toks[ni].col, endLine: toks[ni].line,
                     typ: typ, text: typ & " " & nm, doc: cxDocFor(comments, toks[ts].line)))
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
        inc transparent
        st = k + 1
        inc k
        continue
      # a function's body: name(…) {
      var p = k - 1
      while p > st and (cxNoise(toks[p].text) or toks[p].text in ["const", "__attribute__"]): dec p
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
          addSym(CxSym(name: toks[ni].text, kind: cxFunc, line: toks[ni].line, col: toks[ni].col, endLine: endL,
                       typ: (if ret.len > 0: ret else: "int"), params: ps, varargs: va, isDef: true,
                       text: (if ret.len > 0: ret else: "int") & " " & toks[ni].text & "(" & pl.join(", ") & ")",
                       doc: cxDocFor(comments, toks[ts].line)))
          for x in ps:
            if x.name.len > 0:
              f.syms.add CxSym(name: x.name, kind: cxParam, line: toks[ni].line, col: 0, typ: x.typ,
                               scopeA: toks[k].line, scopeB: endL, owner: toks[ni].text, text: x.typ & " " & x.name)
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
            elif i == bst and toks[i].kind == ctWord and
                 toks[i].text notin ["return", "goto", "case", "else", "do", "sizeof", "break", "continue", "default",
                                     "if", "while", "switch", "for"] and
                 (cxIsTypeStart(toks, i, typedefs) or
                  (i + 2 < bodyEnd and toks[i + 1].kind == ctWord and toks[i + 2].text in [";", "=", ",", "["]) or
                  (i + 3 < bodyEnd and toks[i + 1].text == "*" and toks[i + 2].kind == ctWord and
                   toks[i + 3].text in [";", "=", ",", "["])) and
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
  let st = if stamp.len > 0: stamp else: cxStampOf(path)
  if st.len == 0 and text.len == 0: return nil
  if path in cxCache and cxCache[path].stamp == st: return cxCache[path]
  var t = text
  if t.len == 0 and stamp.len == 0:
    try:
      t = readFile(path)
      if t.len > 6_000_000: t.setLen(6_000_000)
    except CatchableError: return nil
  result = cxParse(t, path)
  result.stamp = st
  if text.len == 0: result.lines = @[]
  if cxCache.len > 3000: cxCache.clear()
  cxCache[path] = result

proc cxFindInclude*(name, fromDir: string): string =
  ## the file an #include names: "x.h" next to the including file first, then the include folders
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

proc cxFindSym*(files: seq[CxFile], name: string, kinds: set[CxKind]): (CxFile, int) =
  for g in files:
    for k, s in g.syms:
      if s.name == name and s.kind in kinds: return (g, k)
  (nil, -1)

proc cxRecord*(files: seq[CxFile], typ: string): (string, int) =
  ## the struct or union a type is (through typedefs): its name as fields know it as their owner, and the
  ## pointer depth left — ("", 0) when it is not one
  var (base, stars) = cxStrip(typ)
  for _ in 0 .. 8:
    let w = base.splitWhitespace
    if w.len == 2 and w[0] in ["struct", "union"]: return (w[1], stars)
    if w.len == 1:
      # a typedef: what it names (a struct named by the typedef only is filed under the typedef's name)
      let (g, k) = cxFindSym(files, w[0], {cxTypedef})
      if g != nil:
        let (b2, s2) = cxStrip(g.syms[k].typ)
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
    for k, s in g.syms:
      if s.kind == cxField and s.owner == owner: result.add (g, k)

proc cxLocalsAt*(f: CxFile, line: int): seq[CxSym] =
  ## the parameters and locals seen on `line` (the innermost last)
  for s in f.syms:
    if s.kind in {cxParam, cxLocal} and line >= s.scopeA and line <= s.scopeB and
       (s.kind == cxParam or s.line <= line): result.add s

proc cxTypeOfName*(files: seq[CxFile], f: CxFile, name: string, line: int): string =
  let ls = cxLocalsAt(f, line)
  for i in countdown(ls.high, 0):
    if ls[i].name == name: return ls[i].typ
  let (g, k) = cxFindSym(files, name, {cxVar, cxFunc, cxEnumConst})
  if g != nil:
    let s = g.syms[k]
    return (if s.kind == cxFunc: "fn:" & s.typ else: s.typ)

proc cxTypeOfExpr*(files: seq[CxFile], f: CxFile, expr: string, line: int): string =
  ## the type of `a.b->c[i]`, `p->next`, `get(x).y`, `*pp`, `(struct q *)v` — "" when not known
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
      typ = cxTypeOfExpr(files, f, inner, line)
      i = e + 1
  else:
    var e = 0
    while e < s.len and s[e] in IdentChars: inc e
    if e == 0: return ""
    typ = cxTypeOfName(files, f, s[0 ..< e], line)
    i = e
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

proc cxReceiver*(line: string, endAt: int): string =
  ## the expression before `.` or `->` that ends at endAt (exclusive): `a.b[i]->` → "a.b[i]", `get(x)` → "get(x)"
  var k = endAt - 1
  var d = 0
  while k >= 0:
    let c = line[k]
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

proc cxComplete*(f: CxFile, line, col: int, systemDirs: seq[string] = @[]): (seq[CxItem], bool, string) =
  ## completion at line:col: (items, after a member access, the type there)
  if f == nil or line >= f.lines.len: return
  let t = f.lines[line]
  var c = min(col, t.len)
  var w = c
  while w > 0 and t[w - 1] in IdentChars: dec w
  let files = cxClosure(f)
  # after . or ->: the members
  var mEnd = -1
  if w > 0 and t[w - 1] == '.': mEnd = w - 1
  elif w > 1 and t[w - 1] == '>' and t[w - 2] == '-': mEnd = w - 2
  if mEnd >= 0:
    let recv = cxReceiver(t, mEnd)
    let typ = cxTypeOfExpr(files, f, recv, line)
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
  for i in countdown(ls.high, 0):
    let s = ls[i]
    if s.name in seen: continue
    seen.incl s.name
    result[0].add CxItem(label: s.name, detail: s.typ, kind: s.kind, rank: 0)
  for gi, g in files:
    let sys = gi > 0 and systemDirs.len > 0 and (block:
      var y = false
      for d in systemDirs:
        if g.path.startsWith(d): y = true
      y)
    for s in g.syms:
      if s.kind in {cxParam, cxLocal, cxField} or s.name in seen: continue
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

proc cxTargets*(f: CxFile, line, col: int): seq[(CxFile, CxSym)] =
  ## what the word at line:col names: a member, a local or parameter, or declarations in the file and its headers
  ## (a function's definition before its prototype)
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
    let typ = cxTypeOfExpr(files, f, cxReceiver(t, mEnd), line)
    let (rec, _) = cxRecord(files, typ)
    if rec.len > 0:
      for (g, k) in cxFields(files, rec):
        if g.syms[k].name == w: return @[(g, g.syms[k])]
    return
  # the declaration itself
  for s in f.syms:
    if s.name == w and s.line == line and s.col == a and s.kind notin {cxParam}: return @[(f, s)]
  let ls = cxLocalsAt(f, line)
  for i in countdown(ls.high, 0):
    if ls[i].name == w:
      var s = ls[i]
      if s.kind == cxParam:
        # where the parameter is written: on the function's line(s)
        for l in max(0, s.line) .. min(f.lines.high, s.line + 8):
          let k = f.lines[l].find(w)
          if k >= 0 and (k == 0 or f.lines[l][k - 1] notin IdentChars) and
             (k + w.len >= f.lines[l].len or f.lines[l][k + w.len] notin IdentChars):
            s.line = l
            s.col = k
            break
      return @[(f, s)]
  var defs, decls, macros: seq[(CxFile, CxSym)]
  for g in files:
    for s in g.syms:
      if s.name == w and s.kind notin {cxParam, cxLocal, cxField}:
        if s.kind == cxMacro: macros.add (g, s)        # (a macro of a function's name — fortify, 64-bit names — last)
        elif s.isDef or s.kind notin {cxFunc, cxStruct, cxUnion, cxEnum}: defs.add (g, s)
        else: decls.add (g, s)
  result = defs & decls & macros

proc cxHover*(f: CxFile, line, col: int): string =
  let ts = cxTargets(f, line, col)
  if ts.len == 0: return ""
  let (g, s) = ts[0]
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
  result = "```c\n" & s.text & "\n```\n" & kindWord & " · " & extractFilename(g.path) & ":" & $(s.line + 1)
  if s.doc.len > 0: result.add "\n\n" & s.doc
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
    for i, s in g.syms:
      if s.name == name and s.kind in {cxFunc, cxMacro} and (best < 0 or s.isDef):
        best = i
        bf = g
  if best < 0: return
  (bf.syms[best], commas)

proc cxOutline*(f: CxFile): seq[CxSym] =
  if f == nil: return
  for s in f.syms:
    if s.kind in {cxFunc, cxStruct, cxUnion, cxEnum, cxTypedef, cxMacro, cxVar} and not s.name.startsWith("(anonymous"):
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
