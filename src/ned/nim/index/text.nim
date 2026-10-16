# ── small text helpers on code (strings already intact, comments gone) ──

proc nxCharEnd*(s: string, i: int): int =
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

proc nxFindTop*(s: string, what: char, start = 0): int =
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

proc nxMatchClose*(s: string, open: int): int =
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

proc nxStripPragma*(s: string): (string, string) =
  ## "name* {.inline.}" → ("name*", "inline")
  let p = s.find("{.")
  if p < 0: return (s, "")
  var e = s.find(".}", p)
  if e < 0: e = s.high - 1
  (s[0 ..< p] & s[min(s.len, e + 2) .. ^1], s[p + 2 ..< max(p + 2, e)].strip)

proc nxName*(s: string, start: int): (string, int) =
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

proc nxWordCol*(line, name: string): int =
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
