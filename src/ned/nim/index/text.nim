# ── small text helpers on code (strings already intact, comments gone) ──

func nxCharEnd*(s: string, i: int): int =
  ## s[i] starts a character literal ('a', '"', '\n', '\''): the index of its closing quote, else -1
  if i >= s.len or s[i] != '\'' or (i > 0 and s[i - 1] in IdentChars): return -1
  var j = i + 1
  if j < s.len and s[j] == '\\':
    j += 2
    while j < s.len and j - i < 12 and s[j] != '\'': inc j
  elif j < s.len and s[j] != '\'':
    j = nextRune(s, j)
  if j < s.len and s[j] == '\'': j else: -1

proc nxSplitTop*(s: string, seps: set[char]): seq[string] =
  ## split at separators outside brackets and strings
  var depth = 0
  var cur = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\'' and nxCharEnd(s, i) > i:
      let ce = nxCharEnd(s, i)
      cur.add s[i .. ce]
      i = ce + 1
      continue
    if c == '"':
      let st = i
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\': inc i
        inc i
      cur.add s[st .. min(i, s.high)]
      inc i
      continue
    if c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    if depth == 0 and c in seps:
      result.add cur
      cur = ""
    else: cur.add c
    inc i
  result.add cur

func nxFindTop*(s: string, what: char, start = 0): int =
  ## first `what` outside brackets/strings, or -1
  var depth = 0
  var i = start
  while i < s.len:
    let c = s[i]
    if c == '\'' and nxCharEnd(s, i) > i:
      i = nxCharEnd(s, i) + 1
      continue
    if c == '"':
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\': inc i
        inc i
    elif c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif c == what and depth == 0: return i
    inc i
  -1

func nxMatchClose*(s: string, open: int): int =
  ## index of the bracket closing s[open], or -1
  var depth = 0
  var i = open
  while i < s.len:
    let c = s[i]
    if c == '\'' and nxCharEnd(s, i) > i:
      i = nxCharEnd(s, i) + 1
      continue
    if c == '"':
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\': inc i
        inc i
    elif c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}:
      dec depth
      if depth == 0: return i
    inc i
  -1

func nxStripPragma*(s: string): (string, string) =
  ## "name* {.inline.}" → ("name*", "inline")
  let p = s.find("{.")
  if p < 0: return (s, "")
  var e = s.find(".}", p)
  if e < 0: e = s.high - 1
  (s[0 ..< p] & s[min(s.len, e + 2) .. ^1], s[p + 2 ..< max(p + 2, e)].strip)

func nxName*(s: string, start: int): (string, int) =
  ## an identifier or `backticked op` at s[start..]; returns (name, index after it)
  var i = start
  while i < s.len and s[i] == ' ': inc i
  if i < s.len and s[i] == '`':
    let e = s.find('`', i + 1)
    if e < 0: return ("", i)
    return (s[i + 1 ..< e].replace(" ", ""), e + 1)
  let st = i
  while i < s.len and nxIsIdent(s[i]): inc i
  (s[st ..< i], i)

func nxWordCol*(line, name: string): int =
  ## where `name` stands in the line as a whole word (`let t = …`: not the t in `let`), else where it appears
  let n = name.strip(chars = {'`'})
  if n.len == 0: return 0
  var k = line.find(n)
  while k >= 0:
    let before = k == 0 or line[k - 1] notin IdentChars
    let after = k + n.len >= line.len or line[k + n.len] notin IdentChars
    if before and after: return k
    k = line.find(n, k + 1)
  max(0, line.find(n))

proc nxParseParams*(text: string): seq[NxParam] =
  ## "a, b: int; c = 2, d: var seq[T] = @[]" → a: int, b: int, c (= 2), d: var seq[T] (= @[])
  var pending: seq[string]
  for piece in nxSplitTop(text, {',', ';'}):
    let p = piece.strip
    if p.len == 0: continue
    let colon = nxFindTop(p, ':')
    let eq = nxFindTop(p, '=')
    if colon < 0 and eq < 0:
      pending.add nxStripPragma(p)[0].strip
      continue
    var nameEnd = p.len
    if colon >= 0: nameEnd = colon
    if eq >= 0 and (colon < 0 or eq < colon): nameEnd = eq
    let nm = nxStripPragma(p[0 ..< nameEnd])[0].strip
    var typ = ""
    var def = ""
    if colon >= 0 and (eq < 0 or colon < eq):
      let e2 = nxFindTop(p, '=', colon + 1)
      if e2 >= 0:
        typ = p[colon + 1 ..< e2].strip
        def = p[e2 + 1 .. ^1].strip
      else: typ = p[colon + 1 .. ^1].strip
    elif eq >= 0: def = p[eq + 1 .. ^1].strip
    for q in pending: result.add NxParam(name: q, typ: typ, default: def)
    pending.setLen(0)
    result.add NxParam(name: nm, typ: typ, default: def)
  for q in pending: result.add NxParam(name: q)

proc nxParamsText*(ps: seq[NxParam], skipFirst = false): string =
  ## a parameter list written out as `name: type = default`, comma-separated; skipFirst leaves out the first (the
  ## receiver of a method call)
  var parts: seq[string]
  for i, p in ps:
    if skipFirst and i == 0: continue
    var s = p.name
    if p.typ.len > 0: s.add ": " & p.typ
    if p.default.len > 0: s.add " = " & p.default
    parts.add s
  parts.join(", ")

proc nxSig*(s: NxSym, ufcs = false): string =
  ## the one-line signature shown in completion, hover and signature help
  case s.kind
  of NxRoutineKinds:
    let nm = if s.name.len > 0 and not nxIsIdent(s.name[0]) and s.name[0] != '`': "`" & s.name & "`" else: s.name
    result = nxKindWord(s.kind) & " " & nm & s.generics & "(" & nxParamsText(s.params, ufcs) & ")"
    if s.ret.len > 0: result.add ": " & s.ret
  of nxType:
    result = "type " & s.name & s.generics & (if s.typ.len > 0: " = " & s.typ else: "")
  of nxField: result = s.name & (if s.typ.len > 0: ": " & s.typ else: "")
  of nxEnumVal: result = s.owner & "." & s.name & (if s.value.len > 0: " = " & s.value else: "")
  of nxConst, nxLet, nxVar:
    result = nxKindWord(s.kind) & " " & s.name & (if s.typ.len > 0: ": " & s.typ else: "") &
             (if s.value.len > 0 and (s.kind == nxConst or s.typ.len == 0): " = " & s.value else: "")
  of nxParam, nxForVar, nxResult: result = s.name & (if s.typ.len > 0: ": " & s.typ else: "")
  of nxModule: result = "module " & s.name

# ── chronos' futures that carry what they raise: the types its macros make ──

proc nxRaisesTuple*(list: string): string =
  ## a chronos raises list as its futures carry it: `[]` → void, `[A]` (or `A`) → (A,), `[A, B]` → (A, B)
  let s = list.strip
  var items: seq[string]
  if s.startsWith("[") and s.endsWith("]"):
    for x in nxSplitTop(s[1 ..< ^1], {','}):
      if x.strip.len > 0: items.add x.strip
  elif s.len > 0: items.add s
  if items.len == 0: "void"
  elif items.len == 1: "(" & items[0] & ",)"
  else: "(" & items.join(", ") & ")"

proc nxRaisingType*(t: string): string =
  ## chronos' `Future[T].Raising([A, B])` written as a type: the type its macro makes, InternalRaisesFuture[T, (A, B)]
  ## (`.Raising([])`: InternalRaisesFuture[T, void]) — also inside another type (seq[Future[T].Raising([A])])
  result = t
  var guard = 0
  var k = result.find(".Raising(")
  while k > 0 and guard < 8:
    inc guard
    let e = nxMatchClose(result, k + 8)
    if e < 0 or result[k - 1] != ']': return
    # the Future[T] before it
    var d = 0
    var j = k - 1
    while j >= 0:
      if result[j] == ']': inc d
      elif result[j] == '[':
        dec d
        if d == 0: break
      dec j
    if j <= 0: return
    var s = j
    while s > 0 and nxIsIdent(result[s - 1]): dec s
    let base = result[s ..< j]
    if base notin ["Future", "InternalRaisesFuture"]: return
    let targ = nxSplitTop(result[j + 1 ..< k - 1], {','})
    if targ.len == 0 or targ[0].strip.len == 0: return
    result = result[0 ..< s] & "InternalRaisesFuture[" & targ[0].strip & ", " & nxRaisesTuple(result[k + 9 ..< e]) &
             "]" & result[e + 1 .. ^1]
    k = result.find(".Raising(")

proc nxTypeText*(s: string): string =
  ## a type as written in a declaration, as the index keeps it: on one line, chronos' `.Raising(…)` made
  let c = nxCollapse(s)
  if ".Raising(" in c: nxRaisingType(c) else: c
