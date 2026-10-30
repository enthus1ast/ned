# ── the declaration parser ──

type
  NxBlock* = enum bkRoutine, bkTypeSec, bkVarSec, bkObject, bkEnum, bkTransparent, bkObjTransparent, bkOther,
    bkLocal                  # a block inside a routine (if, for, an active `when` branch …): it can declare types
  NxFrame* = object
    ind*: int
    kind*: NxBlock
    sym*: int              # routine/type symbol index (bkRoutine, bkObject, bkEnum)
    secKind*: NxKind       # bkVarSec: nxConst / nxLet / nxVar
    memberInd*: int        # first member's indent in a section (-1 until known)
    owner*: string
    inact*: bool           # a `when` branch left out here (its body: start + 1 .. the last line before the pop)
    start*: int
    chain*: int            # (keepInactive) the conditions of the left-out branches it is in: index into `chains`
    sum*: bool             # an object's `case` without a discriminator: a sum type (Nim 2.4, Nimony)
    branches*: seq[int]    # (a sum type's `of A, B:`) the branch constructors it declares: its fields are theirs

func nxTightSlash(s: string): string =
  ## `std / [os, strutils]`, `basic / versions`: the path without the spaces around its `/` (not in a "string")
  result = s
  if '"' in s or '/' notin s: return
  while " /" in result: result = result.replace(" /", "/")
  while "/ " in result: result = result.replace("/ ", "/")

proc nxParseImports*(f: NxFile, rest: string, line: int, kw: string) =
  ## reads what follows `import`, `include`, `from` or `export` on a line into f: `from x import a, b` (with its `only`
  ## list), `import x except a`, `import a as b`, `std/[os, strutils]` split into one import each, and Nim 3's
  ## parenthesised paths with a {.cyclic.} pragma. `export` adds to f.exports
  var r = nxTightSlash(rest.strip)
  if kw == "export":
    for p in nxSplitTop(r, {','}):
      let x = p.strip
      if x.len > 0: f.exports.add x
    return
  if kw == "from":
    let k = r.find(" import ")
    if k < 0: return
    var imp = NxImport(spec: r[0 ..< k].strip.strip(chars = {'"'}), line: line)
    for p in nxSplitTop(r[k + 8 .. ^1], {','}):
      let x = p.strip.strip(chars = {'`'})
      if x.len > 0: imp.only.add x
    f.imports.add imp
    return
  var excepts: seq[string]
  let ex = r.find(" except ")
  if ex >= 0:
    for p in nxSplitTop(r[ex + 8 .. ^1], {','}):
      let x = p.strip.strip(chars = {'`'})
      if x.len > 0: excepts.add x
    r = r[0 ..< ex]
  for p0 in nxSplitTop(r, {','}):
    var p = p0.strip
    if p.len == 0: continue
    # (Nim 3: `import (path / module) {.cyclic.}` — the pragma and the parentheses are not part of the path)
    if p.endsWith(".}"):
      let pa = p.rfind("{.")
      if pa > 0: p = p[0 ..< pa].strip
    if p.len > 1 and p[0] == '(' and p[^1] == ')' and '"' notin p: p = p[1 ..< p.high].strip.replace(" / ", "/")
    var alias = ""
    let a = p.find(" as ")
    if a >= 0:
      alias = p[a + 4 .. ^1].strip
      p = p[0 ..< a].strip
    p = p.strip(chars = {'"', ' '})
    let br = p.find('[')
    if br >= 0 and p.endsWith("]"):
      # std/[os, strutils]
      let base = p[0 ..< br].strip
      for q in nxSplitTop(p[br + 1 ..< p.high], {','}):
        let x = q.strip.strip(chars = {'"'})
        if x.len > 0: f.imports.add NxImport(spec: base & x, line: line, isInclude: kw == "include")
    else:
      f.imports.add NxImport(spec: p, line: line, alias: alias, isInclude: kw == "include")
  if excepts.len > 0 and f.imports.len > 0: f.imports[^1].excepts = excepts

proc nxLocate*(lines: openArray[string], name: string, a, b: int, start: (int, int)): (int, int) =
  ## where `name` stands as a whole word in lines a..b (searching from `start`)
  for l in max(a, start[0]) .. min(b, lines.high):
    let s = lines[l]
    var k = if l == start[0]: start[1] else: 0
    while true:
      k = s.find(name, k)
      if k < 0: break
      let okL = k == 0 or not nxIsIdent(s[k - 1])
      let okR = k + name.len >= s.len or not nxIsIdent(s[k + name.len])
      if okL and okR: return (l, k)
      k += 1
  (a, max(0, lines[min(a, lines.high)].find(name)))

var nxDefines*: HashSet[string]       # what `defined(x)` is true for (the platform ned runs on)
var nxDefinesComplete* = false        # nxDefines came from `nim dump`: a name not in it is not defined

proc nxInitDefines*() =
  ## fills nxDefines with what `defined(…)` is true for before `nim dump` has told: the memory-management and
  ## language-feature names of a current Nim, and the operating system and CPU ned itself is built for
  # (not nimPreviewSlimSystem: without it, system brings syncio's readFile, stdin, open … as the compiler does)
  for d in ["nimV2", "gcDestructors", "gcOrc", "nimSeqsV2", "nimHasAlignOf",
            "nimHasNoReturnError", "nimHasCursor", "nimHasSinkInference", "nimHasEffectsOf", "nimHasTopDownInference",
            "nimHasDefault", "nimHasStyleChecks", "nimHasWarningAsError", "ssl", "threads", "nimAllowNonVarDestructor"]:
    nxDefines.incl d
  # the system ned runs on (the one `defined` answers for)
  when defined(posix):
    nxDefines.incl "posix"
    nxDefines.incl "unix"
  when defined(linux): nxDefines.incl "linux"
  when defined(macosx):
    nxDefines.incl "macosx"
    nxDefines.incl "osx"
  when defined(bsd): nxDefines.incl "bsd"
  when defined(freebsd): nxDefines.incl "freebsd"
  when defined(openbsd): nxDefines.incl "openbsd"
  when defined(netbsd): nxDefines.incl "netbsd"
  when defined(windows): nxDefines.incl "windows"
  when defined(android): nxDefines.incl "android"
  when defined(amd64): nxDefines.incl "amd64"
  when defined(arm64): nxDefines.incl "arm64"

proc nxWhen*(cond: string): int =
  ## evaluate a `when` condition we can be sure about: 1 true, 0 false, -1 unknown
  var toks: seq[string]
  var i = 0
  let c = cond
  while i < c.len:
    if c[i] in {' ', '\t'}: inc i
    elif c[i] in {'(', ')'}:
      toks.add $c[i]
      inc i
    elif nxIsIdent(c[i]):
      var e = i
      while e < c.len and (nxIsIdent(c[e]) or c[e] == '.'): inc e
      let w = c[i ..< e]
      if (w == "defined" or w == "declared") and e < c.len and c[e] == '(':
        let ce = c.find(')', e)
        if ce < 0: return -1
        let arg = c[e + 1 ..< ce].strip
        if w == "declared": toks.add "?"
        elif nxDefines.len == 0 and false: toks.add "?"
        else:
          let known = ["windows", "macosx", "osx", "ios", "linux", "posix", "unix", "bsd", "js", "nimscript", "emscripten", "wasm", "hotcodereloading",
                       "freebsd", "openbsd", "netbsd", "dragonfly", "solaris", "haiku", "genode", "nintendoswitch",
                       "zephyr", "freertos", "standalone", "useNimRtl", "nimdoc", "gcRefc", "gcMarkAndSweep", "gcBoehm",
                       "gcGo", "gcRegions", "nogc", "nimHasCompiles", "nimNoLibc", "lwip", "nimdoc", "vcc", "msvc",
                       "createNimRtl", "booting", "nimTypeNames", "nimHasCursor"]
          if arg == "nimconfig": toks.add "?"      # (system's NimScript part: read, then a script's only — scope)
          elif arg in nxDefines: toks.add "1"
          elif arg in known or arg == "android" or arg == "amd64" or arg == "arm64" or arg == "i386" or
               nxDefinesComplete: toks.add "0"
          else: toks.add "?"
        i = ce + 1
      else:
        case w
        of "not", "and", "or": toks.add w
        of "true": toks.add "1"
        of "false": toks.add "0"
        else: toks.add "?"          # (a constant: defined(windows) and not weirdTarget is still false)
        i = e
    else: return -1
  # tiny recursive evaluator over 0 / 1 / ? with not, and, or, ()
  var p = 0
  proc orExpr(): int
  proc atom(): int =
    ## one operand of a `when` condition: 1, 0 or -1 (unknown), a `not` of one, or a bracketed condition
    if p >= toks.len: return -1
    let t = toks[p]
    inc p
    case t
    of "1": 1
    of "0": 0
    of "?": -1
    of "not":
      let v = atom()
      if v < 0: -1 else: 1 - v
    of "(":
      let v = orExpr()
      if p < toks.len and toks[p] == ")": inc p
      v
    else: -1
  proc andExpr(): int =
    ## atoms joined by `and`: false if either is false, true only if all are, else unknown
    result = atom()
    while p < toks.len and toks[p] == "and":
      inc p
      let r = atom()
      result = if result == 0 or r == 0: 0 elif result == 1 and r == 1: 1 else: -1
  proc orExpr(): int =
    ## and-groups joined by `or`: true if either is true, false only if all are, else unknown
    result = andExpr()
    while p < toks.len and toks[p] == "or":
      inc p
      let r = andExpr()
      result = if result == 1 or r == 1: 1 elif result == 0 and r == 0: 0 else: -1
  let v = orExpr()
  if p < toks.len: -1 else: v

func nxCodeOf*(s: string): string =
  ## a line without its comment (strings kept), stripped
  var q = false
  var k = 0
  while k < s.len:
    if s[k] == '\\' and q: inc k
    elif s[k] == '"': q = not q
    elif s[k] == '#' and not q: return s[0 ..< k].strip
    inc k
  s.strip

func nxGoesOn(t: string): bool =
  ## a line that ends inside an expression: the next one continues it
  t.endsWith(",") or t.endsWith("&") or t.endsWith("+") or t.endsWith("-") or t.endsWith("*") or
    t.endsWith(" or") or t.endsWith(" and") or t.endsWith("|") or t.endsWith("(") or t.endsWith("[")

func nxBalance(t: string): int =
  ## how many more brackets a line opens than it closes, not counting those inside a string (negative when it closes
  ## more)
  var q = false
  for ch in t:
    if ch == '"': q = not q
    elif not q:
      if ch in {'(', '[', '{'}: inc result
      elif ch in {')', ']', '}'}: dec result

proc nxBlockValue*(lines: openArray[string], start, ind: int, val: string): string =
  ## a value that goes on in the lines below — let x = if c:   /   case k   /   try:   /   block:   /   when c:
  ## — as one line for the type to come from: "if c: <the first branch's last statement> …" (for `when`: the branch
  ## taken here; for `block:` a variable of its own as what it holds)
  result = val
  var v = val.strip
  var start = start
  if v.len == 0:
    # let x =
    #   expression       (on the lines below: the first one, with what continues it)
    for l in start ..< min(lines.len, start + 20):
      let raw = lines[l]
      let t0 = nxCodeOf(raw)
      if t0.len == 0: continue
      if leadWs(raw) <= ind: return
      var t = t0
      if (t.startsWith("if ") or t.startsWith("when ")) and nxFindTop(t, ':') > 0 and not t.endsWith(":"):
        # when defined(macos): ':'⏎ elif …: '\\'⏎ else: '/'   — one branch a line: all of them
        let bi = leadWs(raw)
        for l2 in l + 1 ..< min(lines.len, l + 20):
          let c2 = nxCodeOf(lines[l2])
          if c2.len == 0: continue
          if leadWs(lines[l2]) != bi or not (c2.startsWith("elif ") or c2.startsWith("else:")): break
          t.add " " & c2
        return t
      if t.startsWith("if ") or t.startsWith("when ") or t.startsWith("case ") or t == "try:" or t == "block:":
        return nxBlockValue(lines, l + 1, ind, t)
      if (t.startsWith("quote") and t.endsWith(":")) or t == "quote do:": return "quote(nil)"
      var open = nxBalance(t)
      var l2 = l
      while open > 0 or nxGoesOn(t):
        inc l2
        if l2 >= lines.len or l2 - l > 30 or (lines[l2].strip.len > 0 and leadWs(lines[l2]) <= ind): break
        let c2 = nxCodeOf(lines[l2])
        if c2.len == 0: continue                   # (a comment line between: not part of the value)
        t.add " " & c2
        open += nxBalance(c2)
      return t
    return
  if nxGoesOn(v) and not (v.startsWith("if ") or v.startsWith("when ") or v.startsWith("case ")):
    # "\x01" &⏎ "…": the lines that continue it
    var t = v
    var open = nxBalance(t)
    var l2 = start - 1
    while open > 0 or nxGoesOn(t):
      inc l2
      if l2 >= lines.len or l2 - start > 30 or (lines[l2].strip.len > 0 and leadWs(lines[l2]) <= ind): break
      let c2 = nxCodeOf(lines[l2])
      if c2.len == 0: continue
      t.add " " & c2
      open += nxBalance(c2)
    return t
  block:
    # x⏎  .filterIt(…)⏎  .mapIt(…): a call chain going on in the lines below, each starting with a dot
    var t = v
    var l2 = start
    var any = false
    while l2 < lines.len and l2 - start < 30:
      let c2 = nxCodeOf(lines[l2])
      if c2.len == 0:
        inc l2
        continue
      if leadWs(lines[l2]) <= ind or c2.len < 2 or c2[0] != '.' or c2[1] in {'.', '}', ' '}: break
      t.add c2
      any = true
      inc l2
    if any: return t
  if (v.startsWith("if ") or v.startsWith("when ")) and not v.endsWith(":") and nxFindTop(v, ':') < 0:
    # if a and⏎ b:   the condition goes on below
    var l2 = start
    while l2 < lines.len and l2 - start < 8:
      let c2 = nxCodeOf(lines[l2])
      inc l2
      if c2.len == 0: continue
      v.add " " & c2
      if c2.endsWith(":"): break
    start = l2
  let isCase = v.startsWith("case ")
  let isWhen = v.startsWith("when ")
  if not (isCase or (v.endsWith(":") and (v.startsWith("if ") or isWhen or v == "try:" or v == "block:"))):
    return
  var inBranch = not isCase
  var taken = if isWhen: nxWhen(v[5 ..< ^1]) != 0 else: true    # (when: this branch is the one compiled)
  var anyTaken = isWhen and nxWhen(v[5 ..< ^1]) == 1
  var bodyInd = -1
  var last = ""
  var stmt = ""
  var bal = 0
  var decls: Table[string, string]           # (block:) its own variables: name → what gives their type
  var deepLast = ""                          # (the last value inside a nested block: `if isSsl: Port(443) …`)
  var elseVal = ""
  for l in start ..< min(lines.len, start + 60):
    let raw = lines[l]
    let t = nxCodeOf(raw)
    if t.len == 0: continue
    if leadWs(raw) <= ind: break
    if bal > 0:
      # a statement over several lines (accept4(…,⏎ addr(addrLen), …)): all of it
      stmt.add " " & t
      bal += nxBalance(t)
      if bal <= 0 and taken and inBranch: last = stmt
      continue
    let kw = t.startsWith("of ") or t.startsWith("elif ") or t.startsWith("else:") or t == "else" or
             t.startsWith("except")
    if kw and (bodyInd < 0 or leadWs(raw) < bodyInd):
      if isWhen:
        if taken and last.len > 0: break
        if t.startsWith("elif "):
          let c = nxFindTop(t, ':')
          let wv = nxWhen(if c > 5: t[5 ..< c] else: "")
          taken = not anyTaken and wv != 0
          if wv == 1: anyTaken = true
        else: taken = not anyTaken
        last = ""
        let c = nxFindTop(t, ':')
        if taken and c > 0 and c + 1 < t.len:
          last = t[c + 1 .. ^1].strip
          break
        continue
      if inBranch:
        if not isCase and t.startsWith("else:") and t.len > 5 and t[5 .. ^1].strip.len > 0:
          elseVal = t[5 .. ^1].strip         # (if c: … else: ("", 1): the other branch's value, the same type)
        break
      inBranch = true
      let c = t.find(": ")                  # of 1: "one"
      if c > 0 and c + 2 < t.len:
        last = t[c + 2 .. ^1].strip
        break
      continue
    if bodyInd < 0: bodyInd = leadWs(raw)
    if inBranch and taken and leadWs(raw) > bodyInd and last.len == 0 and not t.endsWith(":") and
       not (t.startsWith("else") or t.startsWith("elif ") or t.startsWith("of ")) and nxFindTop(t, '=') < 0 and
       nxName(t, 0)[0] notin ["raise", "return", "discard", "echo", "var", "let", "const", "inc", "dec", "add"]:
      deepLast = t
    if not inBranch or not taken or leadWs(raw) > bodyInd: continue
    if (t.startsWith("quote") and t.endsWith(":")) or t == "quote do:":
      last = "quote(nil)"                    # (a syntax tree: NimNode)
      continue
    if t.endsWith(":"): continue
    let (w, we) = nxName(t, 0)
    if w in ["var", "let", "const"] and v == "block:":
      let r = t[we .. ^1].strip
      let c1 = nxFindTop(r, ':')
      let e1 = nxFindTop(r, '=')
      var ne = r.len
      if c1 >= 0: ne = c1
      if e1 >= 0 and e1 < ne: ne = e1
      let nm = r[0 ..< ne].strip(chars = {'*', ' '})
      if c1 >= 0 and (e1 < 0 or c1 < e1):
        decls[nm] = "cast[" & (if e1 > c1: r[c1 + 1 ..< e1] else: r[c1 + 1 .. ^1]).strip & "](0)"
      elif e1 >= 0: decls[nm] = r[e1 + 1 .. ^1].strip
      continue
    if w in ["raise", "return", "discard", "echo", "doAssert", "assert", "inc", "dec", "break", "continue",
             "var", "let", "const", "add", "quit"]:
      continue
    let e = nxFindTop(t, '=')
    if e > 0 and e + 1 < t.len and t[e + 1] != '=' and t[e - 1] notin {'<', '>', '!', '='}: continue   # x = 1
    stmt = t
    bal = nxBalance(t)
    if bal <= 0: last = t
  if v == "block:" and last in decls: last = decls[last]
  if last.len == 0 and deepLast.len > 0 and nxBalance(deepLast) == 0: last = deepLast
  if last.len > 0 or elseVal.len > 0:
    result = (if isCase: v & ": " elif isWhen: "block: " else: v & " ") & last &
             (if elseVal.len > 0: " else: " & elseVal else: "") & " …"

proc nxShortValue*(v: string): string =
  ## a declaration's value kept short (it is shown, and typed): what decides its type stays — the callee or
  ## constructor of a long call (`ClCfg(…)`), the first item of a long array (`["CON", …]`)
  if v.len <= 200: return v
  var e = 0
  while e < v.len and (nxIsIdent(v[e]) or v[e] == '.'): inc e
  if e > 0 and e < v.len and v[e] in {'(', '['}:
    let ce = nxMatchClose(v, e)
    if ce == v.high or ce < 0: return v[0 .. e] & "…" & (if v[e] == '(': ")" else: "]")
  if v[0] == '[' or v.startsWith("@["):
    let b = if v[0] == '@': 1 else: 0
    let first = nxSplitTop(v[b + 1 .. ^1], {','})
    if first.len > 0 and first[0].len < 150: return v[0 .. b] & first[0].strip & ", …]"
  v[0 ..< 197] & "…"

proc nxSubstIdents*(s: string, sub: Table[string, string]): string =
  ## a template's body line with its arguments in place of its parameters; `lower 2` with lower = vec → vec2
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '#':
      result.add s[i .. ^1]
      return
    if c == '"':
      var j = i + 1
      while j < s.len and s[j] != '"':
        if s[j] == '\\': inc j
        inc j
      result.add s[i .. min(j, s.high)]
      i = j + 1
      continue
    if c == '\'' and nxCharEnd(s, i) > i:
      let e = nxCharEnd(s, i)
      result.add s[i .. e]
      i = e + 1
      continue
    if c == '`':
      let e = s.find('`', i + 1)
      if e < 0:
        result.add s[i .. ^1]
        return
      var joined = ""
      for part in s[i + 1 ..< e].splitWhitespace:
        joined.add sub.getOrDefault(part, part)
      if joined.len > 0 and joined[0] in IdentStartChars and joined.allCharsInSet(IdentChars): result.add joined
      else: result.add "`" & joined & "`"
      i = e + 1
      continue
    if c in IdentStartChars and (i == 0 or not nxIsIdent(s[i - 1])):
      var j = i
      while j < s.len and nxIsIdent(s[j]): inc j
      let w = s[i ..< j]
      result.add (if i > 0 and s[i - 1] == '.': w else: sub.getOrDefault(w, w))
      i = j
      continue
    result.add c
    inc i

proc nxConstWhen(f: NxFile, cond: string, depth = 0): int =
  ## a `when` on a constant of this file declared above (const useWinVersion = defined(windows) or …): its value
  ## worked out the same way (1 / 0 / -1)
  var c = cond.strip
  var neg = false
  if c.startsWith("not "):
    neg = true
    c = c[4 .. ^1].strip
  if c.len == 0 or depth > 3 or not c.allCharsInSet(IdentChars): return -1
  for k in countdown(f.syms.high, 0):
    let s = f.syms[k]
    if s.kind == nxConst and s.name == c and s.value.len > 0:
      var v = nxWhen(s.value)
      if v < 0: v = nxConstWhen(f, s.value, depth + 1)
      return (if v < 0: -1 elif neg: 1 - v else: v)
  -1

func nxLineGoesOn(t: string): bool {.inline.} =
  ## the line goes on on the next one: it ends in , | & or an operator word (`or`, `and`, `xor`, `+`)
  if t.len == 0: return false
  case t[^1]
  of ',', '|', '&': true
  of 'r': t.endsWith(" or") or t.endsWith(" xor")
  of 'd': t.endsWith(" and")
  of '+': t.endsWith(" +")
  else: false

proc nxParse*(lines: openArray[string], path: string, keepInactive = false): NxFile =
  ## the declarations of a file. A `when` branch left out on this platform is skipped (its lines are recorded in
  ## `inactive`); with keepInactive it is read too, and `symBranch` tells which declarations come from one: the
  ## conditions of the left-out branches around them (`chains`, outermost first), the same for every branch written
  ## with the same condition
  result = NxFile(path: path, module: splitFile(path).name)
  let f = result
  var st: NxLexState
  var stack: seq[NxFrame]
  var docTarget = -1         # symbol that following ## lines document
  var docInd = 0
  var valDoc = -1            # a const/let/var whose value is on the lines below (`AltSep* =⏎ when …⏎ ## doc`): the
  var valDocInd = 0          # ## lines after the value, at the value's indentation, are its doc
  var valInd = -1
  var trailDoc = -1          # a declaration whose line ends in `## …`: the ## lines right below go on with it, at
                             # any indentation — one comment, as Nim's lexer reads it (`x = 1 ## \⏎  ## more`)
  var moduleDocOpen = true
  var lastContent = 0
  var code, doc: string
  var t: string                    # (the line's code, stripped: one string for every line, not one each)
  var i = 0
  let n = lines.len
  var whenTaken = initTable[int, int]()
  var whenFirst = initTable[int, string]()    # (indentation → the condition of its `when`, for an `else` branch)

  var localDepth = 0         # > 0: inside a routine's body (a type declared there is a local one)
  var curInact = -1          # (keepInactive) the left-out branches the current statement is in: index into `chains`
  template addSym(s0: NxSym) =
    ## adds a declaration to the file: marks it local inside a routine, finds its real line and column from its name in
    ## the lines read so far, and attaches the doc comment waiting for it
    f.syms.add s0
    if localDepth > 0: f.syms[^1].local = true
    let (pl, pc) = nxLocate(lines, f.syms[^1].name, startLine, i - 1, posFrom)
    f.syms[^1].line = pl
    f.syms[^1].col = pc
    posFrom = (pl, pc + f.syms[^1].name.len)
    docTarget = f.syms.high
    docInd = ind
    if doc.len > 0:
      f.syms[^1].doc = doc
      trailDoc = f.syms.high

  template enumValues(textT: string, ownerT: string, expT: bool) =
    ## adds an enum value for each comma-separated entry of textT (`a = 1, b {.deprecated.}`), owned by the enum, with
    ## its `= value` as written
    for v in nxSplitTop(textT, {','}):
      let vv = nxStripPragma(v.strip)[0].strip
      if vv.len == 0: continue
      let (vn, ve) = nxName(vv, 0)
      if vn.len == 0: continue
      let eqv = vv.find('=', ve)
      addSym(NxSym(name: vn, kind: nxEnumVal, line: startLine, col: nxWordCol(raw, vn), owner: ownerT,
                   exported: expT, value: (if eqv >= 0: vv[eqv + 1 .. ^1].strip else: "")))

  template typeMember(mtT: string) =
    ## Name*[T] {.pragma.} = definition
    let mt = mtT
    let (nm, e) = nxName(mt, 0)
    if nm.len > 0:
      var s = NxSym(name: nm, kind: nxType, line: startLine, col: nxWordCol(raw, nm), endLine: startLine)
      var j = e
      if j < mt.len and mt[j] == '*':
        s.exported = true
        inc j
      let eq = nxFindTop(mt, '=', j)
      let (h2, prag) = nxStripPragma(if eq >= 0: mt[j ..< eq] else: mt[j .. ^1])
      let head = h2.strip
      s.pragmas = prag
      if head.startsWith("["): s.generics = nxCollapse(head)
      let def0 = if eq >= 0: mt[eq + 1 .. ^1].strip else: ""
      # (a proc type keeps its `{.async: (raises: […]).}`: what calling one gives depends on it)
      let def = if def0.startsWith("proc") and "async" in def0: def0 else: nxStripPragma(def0)[0].strip
      s.typ = nxTypeText(def)
      addSym(s)
      let tyIdx = f.syms.high
      let fw = def.split({' ', '['})
      if fw.len > 0 and fw[0] == "enum":
        stack.add NxFrame(ind: ind, kind: bkEnum, sym: tyIdx, owner: nm)
        enumValues(def[4 .. ^1], nm, s.exported)
        docTarget = tyIdx
      elif "object" in fw or def == "tuple" or def.startsWith("concept"):
        stack.add NxFrame(ind: ind, kind: bkObject, sym: tyIdx, owner: nm)
      elif def.startsWith("tuple["):
        let ce = nxMatchClose(def, 5)
        if ce > 5:
          var at = (startLine, 0)
          for p in nxParseParams(def[6 ..< ce]):
            # (where each is written: a tuple[ over several lines has its fields on the lines below)
            let fname = p.name.strip(chars = {'*'})
            let (pl, pc) = nxLocate(lines, fname, startLine, max(startLine, i - 1), at)
            at = (pl, pc + fname.len)
            f.syms.add NxSym(name: fname, kind: nxField, line: pl, col: pc, owner: nm, typ: p.typ, exported: true,
                             local: localDepth > 0)
        docTarget = tyIdx
      elif t.endsWith(":") or t.endsWith("=") or def.len == 0:
        stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)

  template whenBranch(transparentKind: NxBlock) =
    ## when / elif / else: skip branches that cannot apply on this platform, keep the ones that might
    var cond = rest.strip
    if cond.endsWith(":"): cond.setLen(cond.len - 1)
    var v = -1
    if w0 == "when":
      v = nxWhen(cond)
      if v < 0: v = nxConstWhen(f, cond)
      whenTaken[ind] = (if v == 1: 1 elif v == 0: 0 else: -1)
      whenFirst[ind] = cond
    elif w0 == "elif":
      let prev = whenTaken.getOrDefault(ind, -1)
      if prev == 1: v = 0
      else:
        v = nxWhen(cond)
        if v < 0: v = nxConstWhen(f, cond)
        if v == 1 and prev == 0: whenTaken[ind] = 1
        elif v == -1: whenTaken[ind] = -1
    else:
      let prev = whenTaken.getOrDefault(ind, -1)
      v = if prev == 1: 0 elif prev == 0: 1 else: -1
    if v == 0:
      # left out here: skipped — or, for code inside such a branch (keepInactive), read like the others
      var chain = -1
      if keepInactive:
        var outer = ""
        for fr in stack:
          if fr.inact: outer = f.chains[fr.chain] & "\x01"
        let key = outer & (if w0 == "else": "else|" & whenFirst.getOrDefault(ind) else: cond.strip)
        chain = f.chains.find(key)
        if chain < 0:
          chain = f.chains.len
          f.chains.add key
      stack.add NxFrame(ind: ind, kind: (if keepInactive: transparentKind else: bkOther), sym: -1, inact: true,
                        start: startLine, chain: chain)
    else: stack.add NxFrame(ind: ind, kind: transparentKind, sym: -1)

  template whenInline() =
    ## `when defined(windows): import a` and `else: import b`, each on one line: the import of the branch that
    ## applies (each, when that cannot be told) — such a line was passed over, and with it the module it imports
    ## (ned's own files bring std/os that way)
    let colon = nxFindTop(rest, ':')
    if colon >= 0:
      let body = rest[colon + 1 .. ^1].strip
      var kw = ""
      for k in ["import", "include", "export", "from"]:
        if body.startsWith(k & " "): kw = k
      if kw.len > 0:
        let cond = rest[0 ..< colon].strip
        var v = -1
        if w0 == "when":
          v = nxWhen(cond)
          if v < 0: v = nxConstWhen(f, cond)
          whenTaken[ind] = (if v == 1: 1 elif v == 0: 0 else: -1)
          whenFirst[ind] = cond
        elif w0 == "elif":
          let prev = whenTaken.getOrDefault(ind, -1)
          if prev == 1: v = 0
          else:
            v = nxWhen(cond)
            if v < 0: v = nxConstWhen(f, cond)
            if v == 1 and prev == 0: whenTaken[ind] = 1
            elif v == -1: whenTaken[ind] = -1
        else:
          let prev = whenTaken.getOrDefault(ind, -1)
          v = if prev == 1: 0 elif prev == 0: 1 else: -1
        if v != 0 and (kw != "from" or " import " in body):
          nxParseImports(f, body[kw.len .. ^1], startLine, kw)

  template varMember(mtT: string, kkT: NxKind) =
    ## a*, b {.pragma.}: T = value   /   (x, y) = value
    let mt = mtT
    let kk = kkT
    let c1 = nxFindTop(mt, ':')
    let e1 = nxFindTop(mt, '=')
    var endNames = mt.len
    if c1 >= 0: endNames = c1
    if e1 >= 0 and e1 < endNames: endNames = e1
    var typ = ""
    if c1 >= 0 and (e1 < 0 or c1 < e1): typ = (if e1 > c1: mt[c1 + 1 ..< e1] else: mt[c1 + 1 .. ^1]).strip
    let val = if e1 >= 0: mt[e1 + 1 .. ^1].strip else: ""
    let unpack = mt.strip.startsWith("(")          # let (a, b) = …: each name takes one element
    let names = nxSplitTop(mt[0 ..< endNames].strip(chars = {'(', ')', ' '}), {','})
    for vi, p in names:
      let (pn, _) = nxStripPragma(p)
      let (nm, e) = nxName(pn, 0)
      if nm.len == 0 or nm == "_": continue
      let val2 = if typ.len == 0 and e1 >= 0: nxBlockValue(lines, i, ind, val) else: val
      addSym(NxSym(name: nm, kind: kk, line: startLine, col: nxWordCol(raw, nm),
                   exported: e < pn.len and pn[e] == '*', typ: (if unpack: "" else: nxTypeText(typ)),
                   value: nxShortValue(val2),
                   slot: vi.int16, slots: (if unpack: -names.len.int16 else: 0)))

  while i < n:
    let startLine = i
    var posFrom = (i, 0)
    let raw = lines[i]
    var depth = 0
    let wasBlock = st.blockDepth > 0 or st.inTriple
    let wasDocBlock = st.docBlock
    nxSplitLine(raw, st, code, doc, depth)
    inc i
    if wasBlock:
      # still inside a block comment or a long string from an earlier line
      if wasDocBlock:
        let d = (if doc.len > 0: doc else: raw).strip(chars = {' ', '#', ']'})
        if moduleDocOpen and stack.len == 0 and docTarget < 0:
          f.doc.add "\n" & d
        elif docTarget >= 0:
          f.syms[docTarget].doc.add "\n" & d
      # a line that starts inside a long string or comment: its indentation means nothing
      continue
    t.stripInto(code)
    let ind = leadWs(raw)
    if t.len == 0:
      if doc.len > 0 or raw.blankOrStarts("##")[1]:
        # a pure doc comment line
        if moduleDocOpen and stack.len == 0 and ind == 0 and docTarget < 0:
          f.doc.add (if f.doc.len > 0: "\n" else: "") & doc
        elif docTarget >= 0 and ind > docInd:
          let d = f.syms[docTarget].doc
          f.syms[docTarget].doc = (if d.len > 0: d & "\n" else: "") & doc
        elif trailDoc >= 0 and trailDoc < f.syms.len:
          let d = f.syms[trailDoc].doc
          f.syms[trailDoc].doc = (if d.len > 0: d & "\n" else: "") & doc
        elif docTarget < 0 and valDoc >= 0 and valDoc < f.syms.len and ind == valInd:
          docTarget = valDoc
          docInd = valDocInd
          let d = f.syms[docTarget].doc
          f.syms[docTarget].doc = (if d.len > 0: d & "\n" else: "") & doc
      elif raw.blankOrStarts("")[0]:
        trailDoc = -1            # (an empty line ends a comment that went on from a declaration's line)
        if docTarget >= 0: discard     # a blank line inside a doc comment keeps it going
      continue
    moduleDocOpen = false
    # join continuation lines: open brackets, or a trailing comma
    var guard = 0
    while (depth > 0 or nxLineGoesOn(t)) and i < n and guard < 60 and not st.inTriple and st.blockDepth == 0:
      # (and `A = B |⏎ C`: one type; `const X* = defined(linux) or⏎ defined(osx) ## doc`: one value, its doc)
      var c2, d2: string
      nxSplitLine(lines[i], st, c2, d2, depth)
      t.add " " & c2.strip
      if d2.len > 0: doc = d2
      inc i
      inc guard
    # (the line's first word: what follows is only ever added to its end)
    let (w0, w0end) = nxName(t, 0)
    if not t.endsWith("=") and w0 in NxRoutineKw:
      # proc parseChunks(client: HttpClient): Future[void]
      #                  {.multisync.} =
      while i < n and guard < 60 and not st.inTriple and st.blockDepth == 0:
        let nl = lines[i].strip
        if leadWs(lines[i]) <= ind or nl.startsWith("#") or
           not (nl.startsWith("{.") or nl.startsWith("=") or nl.startsWith(":") or t.endsWith(":")): break
        var c2, d2: string
        nxSplitLine(lines[i], st, c2, d2, depth)
        t.add " " & c2.strip
        inc i
        inc guard
        while depth > 0 and i < n and guard < 60 and not st.inTriple and st.blockDepth == 0:
          nxSplitLine(lines[i], st, c2, d2, depth)
          t.add " " & c2.strip
          inc i
          inc guard
        if t.endsWith("="): break
    if t in ["import", "include", "export"] or (t.startsWith("from ") and t.endsWith(" import")):
      # import
      #   ast, astalgo, idents,
      #   semdata
      while i < n and guard < 60 and not st.inTriple and st.blockDepth == 0:
        if lines[i].strip.len == 0:
          # (a blank line inside the list: it goes on when the next line is still under the import, after a comma)
          var k = i + 1
          while k < n and lines[k].strip.len == 0: inc k
          if k < n and leadWs(lines[k]) > ind and t.endsWith(","):
            i = k
            continue
          break
        if leadWs(lines[i]) <= ind: break
        var c2, d2: string
        nxSplitLine(lines[i], st, c2, d2, depth)
        let c2s = c2.strip
        if c2s.len > 0:
          t.add (if t.endsWith(",") or t.endsWith("import") or t.endsWith("include") or
                    t.endsWith("export"): " " else: ", ") & c2s
        inc i
        inc guard
    if keepInactive:
      while f.symBranch.len < f.syms.len: f.symBranch.add curInact.int32
    while stack.len > 0 and stack[^1].ind >= ind:
      let fr = stack.pop()
      if fr.kind in {bkRoutine, bkObject, bkEnum} and fr.sym >= 0 and fr.sym < f.syms.len:
        f.syms[fr.sym].endLine = lastContent
      if fr.inact and lastContent > fr.start:
        f.inactive.add (int32(fr.start + 1), int32(lastContent))
        if keepInactive: f.inactiveChain.add fr.chain.int32
    lastContent = i - 1
    if keepInactive:
      curInact = -1
      for fr in stack:
        if fr.inact: curInact = fr.chain
    var k = stack.high
    while k >= 0 and stack[k].kind == bkTransparent: dec k
    let fk = if k >= 0: stack[k].kind else: bkTransparent
    localDepth = 0
    for fr in stack:
      if fr.kind == bkRoutine: inc localDepth
    docTarget = -1               # a code line ends a doc comment run (its own trailing ## aside)
    trailDoc = -1
    if valDoc >= 0:
      if ind <= valDocInd: valDoc = -1
      elif valInd < 0: valInd = ind
      # (`x: string =⏎ when …⏎ else:⏎ "open" ## \⏎ ## the doc`: the ## at the end of the value's last line is x's)
      if valDoc >= 0 and doc.len > 0 and valDoc < f.syms.len and f.syms[valDoc].doc.len == 0:
        f.syms[valDoc].doc = doc
        trailDoc = valDoc
    if t.startsWith("{.pragma:"):
      let (pn, _) = nxName(t, 9)
      if pn.len > 0: f.pragmas.add (pn, startLine)
    # (the rest of the line: inside a routine only a local type and a `when` read it — most lines need no copy)
    let rest = if w0end < t.len and (fk notin {bkRoutine, bkLocal} or
                                     (w0.len in 4 .. 5 and w0 in ["type", "when", "elif", "else"])):
                 t[w0end .. ^1] else: ""
    let opensBlock = t.endsWith(":") or t.endsWith("=")
    case fk
    of bkTransparent:     # module level (or inside `when`)
      if w0 in NxRoutineKw and rest.len > 0 and rest[0] in {' ', '`'}:
        # proc name*[T](params): Ret {.pragmas.} = body
        let (nm, e) = nxName(t, w0end)
        if nm.len == 0:
          if opensBlock: stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)
          continue
        posFrom = (startLine, ind + w0end)
        var s = NxSym(name: nm, kind: NxKind(NxRoutineKw.find(w0)), line: startLine, endLine: startLine)
        var j = e
        if j < t.len and t[j] == '*':
          s.exported = true
          inc j
        while j < t.len and t[j] == ' ': inc j
        if j < t.len and t[j] == '[':
          let ce = nxMatchClose(t, j)
          if ce > j:
            s.generics = nxCollapse(t[j .. ce])
            j = ce + 1
        while j < t.len and t[j] == ' ': inc j
        if j < t.len and t[j] == '(':
          let ce = nxMatchClose(t, j)
          if ce > j:
            s.params = nxParseParams(t[j + 1 ..< ce])
            for p in s.params.mitems:
              p.typ = nxTypeText(p.typ)
              p.default = nxCollapse(p.default)
            j = ce + 1
        while j < t.len and t[j] == ' ': inc j
        if j < t.len and t[j] == ':':
          var e2 = t.len
          let pr = t.find("{.", j)
          if pr >= 0: e2 = pr
          let eq = nxFindTop(t, '=', j + 1)
          if eq >= 0 and eq < e2: e2 = eq
          s.ret = nxTypeText(t[j + 1 ..< e2].strip)
          j = e2
        let pr = t.find("{.", j)
        if pr >= 0:
          let pe = t.find(".}", pr + 1)
          if pe >= pr + 2: s.pragmas = t[pr + 2 ..< pe].strip      # (`{.}` while typing has none)
        addSym(s)
        if opensBlock: stack.add NxFrame(ind: ind, kind: bkRoutine, sym: f.syms.high)
      elif w0 in ["import", "include", "export"] and rest.len > 0 and rest[0] in {' ', '"'}:
        nxParseImports(f, rest, startLine, w0)
      elif w0 == "from" and " import " in rest:
        nxParseImports(f, rest, startLine, "from")
      elif w0 == "type":
        let r = rest.strip
        if r.len == 0: stack.add NxFrame(ind: ind, kind: bkTypeSec, sym: -1, memberInd: -1)
        else: typeMember(r)
      elif w0 in ["const", "let", "var"]:
        let kk = if w0 == "const": nxConst elif w0 == "let": nxLet else: nxVar
        let r = rest.strip
        if r.len == 0: stack.add NxFrame(ind: ind, kind: bkVarSec, sym: -1, secKind: kk, memberInd: -1)
        else:
          # (let a = 1; let b = "x" — statements after `;` on the same line)
          let parts = if ';' in r: nxSplitTop(r, {';'}) else: @[r]
          varMember(parts[0], kk)
          for pk in 1 ..< parts.len:
            let p2 = parts[pk].strip
            for kw2 in ["let ", "var ", "const "]:
              if p2.startsWith(kw2):
                varMember(p2[kw2.len .. ^1].strip, (if kw2 == "const ": nxConst elif kw2 == "let ": nxLet else: nxVar))
          if opensBlock: stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)
      elif w0 in ["when", "elif", "else"] and opensBlock:
        whenBranch(bkTransparent)
      elif w0 in ["when", "elif", "else"]:
        whenInline()
      elif w0 == "since" and t.endsWith(":") and rest.strip.startsWith("("):
        # since (1, 3, 5): the standard library's declarations for Nim versions from then on (all of them here)
        stack.add NxFrame(ind: ind, kind: bkTransparent, sym: -1)
      elif opensBlock:
        stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)
      elif w0.len > 0 and rest.len > 0 and rest[0] in {'(', ' '}:
        # genVecConstructor(vec, Vec, float32): what a template of this file declares at the top level
        var tpl = -1
        for k in countdown(f.syms.high, 0):
          let s = f.syms[k]
          if s.kind == nxTemplate and s.name == w0 and s.endLine > s.line and s.line < startLine and
             s.params.len > 0:
            tpl = k
            break
        if tpl >= 0:
          let ts = f.syms[tpl]
          var argText = rest.strip
          if argText.startsWith("("):
            let ce = nxMatchClose(argText, 0)
            argText = if ce > 0: argText[1 ..< ce] else: ""
          let args = nxSplitTop(argText, {','})
          if args.len == ts.params.len:
            var sub: Table[string, string]
            for k, p in ts.params: sub[p.name.strip(chars = {'`', '*'})] = args[k].strip
            var body: seq[string]
            var bodyInd = -1
            var anyDecl = false
            for l in ts.line + 1 .. min(ts.endLine, lines.high):
              let rw = lines[l]
              if rw.strip.len == 0:
                body.add ""
                continue
              if bodyInd < 0: bodyInd = leadWs(rw)
              let bl = nxSubstIdents(rw[min(bodyInd, leadWs(rw)) .. ^1], sub)
              if leadWs(rw) == bodyInd and nxName(bl, 0)[0] in ["proc", "func", "template", "macro", "iterator",
                                                                  "converter", "method", "type", "const", "let", "var"]:
                anyDecl = true
              body.add bl
            if anyDecl and body.len < 2000:
              let g = nxParse(body, f.path)
              let cc = nxWordCol(raw, w0)
              for s0 in g.syms:
                var s = s0
                s.line = startLine
                s.col = cc
                s.endLine = startLine
                s.made = true
                if s.doc.len == 0: s.doc = "(declared by `" & w0 & "(" & argText.strip & ")`)"
                f.syms.add s
    of bkTypeSec:
      if stack[k].memberInd < 0: stack[k].memberInd = ind
      if w0 in ["when", "elif", "else"] and opensBlock: whenBranch(bkTransparent)
      else: typeMember(t)
    of bkObject, bkObjTransparent:
      var oi = k
      while oi >= 0 and stack[oi].kind != bkObject: dec oi
      let owner = if oi >= 0: stack[oi].owner else: ""
      if w0 in ["when", "elif", "else"] and opensBlock:
        whenBranch(bkObjTransparent)
        continue
      let inSum = oi >= 0 and stack[oi].sum         # (the `case` frame ends at its first `of`: kept on the object)
      var branchSyms: seq[int]
      if w0 == "of" and inSum:
        # a sum type's branch: `of AddOpr, SubOpr:` — each name constructs one (`AddOpr(a: x, b: y)`), its fields
        # are the branch's (a routine of the type's, made by the declaration: their parameters follow)
        let c = nxFindTop(t, ':')
        let names = (if c > 0: t[2 ..< c] else: t[2 .. ^1]).split(',')
        for nm0 in names:
          let nm = nm0.strip
          if nm.len == 0 or not nxIsIdent(nm[0]) or not nm.allCharsInSet(IdentChars): continue
          let exp = oi >= 0 and stack[oi].sym >= 0 and stack[oi].sym < f.syms.len and f.syms[stack[oi].sym].exported
          addSym(NxSym(name: nm, kind: nxProc, ret: owner, owner: owner, made: true, exported: exp,
                       doc: "(a branch of the sum type `" & owner & "`: `" & nm & "(…)` makes one, `of " & nm &
                            "(…)` in a `case` matches it)"))
          branchSyms.add f.syms.high
      if w0 == "of" and opensBlock:
        stack.add NxFrame(ind: ind, kind: bkObjTransparent, sym: -1, branches: branchSyms)
        continue
      var line2 = t
      if w0 == "case":
        line2 = rest.strip
        if line2.endsWith(":"): line2.setLen(line2.len - 1)
      if w0 in ["of", "else"]:
        # a branch of a case object with its field on the same line:  of kA: a: int
        let c = nxFindTop(t, ':')
        if c < 0: continue
        line2 = t[c + 1 .. ^1].strip
        let (w1, _) = nxName(line2, 0)
        if line2.len == 0 or w1 in ["discard", "nil"]: continue
      elif w0 in ["proc", "func", "discard", "nil"]: continue
      # (a field of a sum type's branch is a parameter of its constructors too)
      let owners = if branchSyms.len > 0: branchSyms elif k >= 0: stack[k].branches else: @[]
      for p in nxParseParams(line2):
        let pn = p.name.strip
        let nm = pn.strip(chars = {'*', ' ', '`'})
        if nm.len == 0 or not nxIsIdent(nm[0]): continue
        addSym(NxSym(name: nm, kind: nxField, line: startLine, col: nxWordCol(raw, nm), owner: owner,
                     typ: nxTypeText(p.typ), value: p.default, exported: pn.endsWith("*")))
        for b in owners:
          if b < f.syms.len: f.syms[b].params.add NxParam(name: nm, typ: nxTypeText(p.typ), default: p.default)
      if w0 == "case":
        if line2.len == 0 and oi >= 0: stack[oi].sum = true
        stack.add NxFrame(ind: ind, kind: bkObjTransparent, sym: -1)
    of bkEnum:
      let exp = stack[k].sym >= 0 and f.syms[stack[k].sym].exported
      enumValues(t, stack[k].owner, exp)
    of bkVarSec:
      if stack[k].memberInd < 0: stack[k].memberInd = ind
      if ind > stack[k].memberInd: discard        # a value continued on the next line
      elif w0 in ["when", "elif", "else"] and opensBlock: whenBranch(bkTransparent)
      else:
        varMember(t, stack[k].secKind)
        if opensBlock: stack.add NxFrame(ind: ind, kind: bkOther, sym: -1)
        if t.endsWith("=") and f.syms.len > 0:
          (valDoc, valDocInd, valInd) = (f.syms.high, ind, -1)
    of bkRoutine, bkLocal:
      # a routine's body: what it declares is local, but its types are worth knowing (their fields, for `x.`)
      if w0 == "type":
        let r = rest.strip
        if r.len == 0: stack.add NxFrame(ind: ind, kind: bkTypeSec, sym: -1, memberInd: -1)
        else: typeMember(r)
      elif w0 in ["when", "elif", "else"] and opensBlock: whenBranch(bkLocal)
      elif w0 in NxRoutineKw: (if opensBlock: stack.add NxFrame(ind: ind, kind: bkLocal, sym: -1))  # (a nested
                                                                    # routine: its local types too)
      elif opensBlock: stack.add NxFrame(ind: ind, kind: bkLocal, sym: -1)
    of bkOther: discard
  while stack.len > 0:
    let fr = stack.pop()
    if fr.kind in {bkRoutine, bkObject, bkEnum} and fr.sym >= 0 and fr.sym < f.syms.len:
      f.syms[fr.sym].endLine = lastContent
    if fr.inact and lastContent > fr.start:
      f.inactive.add (int32(fr.start + 1), int32(lastContent))
      if keepInactive: f.inactiveChain.add fr.chain.int32
  if keepInactive:
    while f.symBranch.len < f.syms.len: f.symBranch.add curInact.int32
