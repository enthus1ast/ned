# ════════════════════════════════════════════════════════════════════════════
#  Navigation helpers: find, goto, symbols, definitions, diagnostics
# ════════════════════════════════════════════════════════════════════════════

var diagsAi = initTable[string, seq[Diag]]()     # AI: review staged changes — kept until reviewed again

proc splitTop(s: string, seps: set[char]): seq[string] =
  ## split at `seps` outside brackets and quotes
  var depth = 0
  var q = '\0'
  var a = 0
  var i = 0
  while i < s.len:
    let c = s[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c in {'"', '\''}: q = c
    elif c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif depth == 0 and c in seps:
      result.add s[a ..< i]
      a = i + 1
    inc i
  result.add s[a .. ^1]

proc topColon(s: string): int =
  ## where "x: T" splits (": " outside brackets and quotes), -1 when none
  var depth = 0
  var q = '\0'
  var i = 0
  while i < s.len - 1:
    let c = s[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c in {'"', '\''}: q = c
    elif c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif depth == 0 and c == ':' and s[i + 1] == ' ': return i
    inc i
  -1

proc nimParams(sig: string): seq[(string, string)] =
  ## "proc foo[T](a, b: int; c = 1): int" → (a, int) (b, int) (c, = 1)
  var i = 0
  if sig.find('`') >= 0:                       # an operator name like `[]`: skip past it
    let e = sig.find('`', sig.find('`') + 1)
    if e > 0: i = e + 1
  var depth = 0
  while i < sig.len:                          # the ( after the name and its [generic params]
    if sig[i] == '[': inc depth
    elif sig[i] == ']': dec depth
    elif sig[i] == '(' and depth == 0: break
    inc i
  if i >= sig.len: return
  var e = i
  depth = 0
  while e < sig.len:
    if sig[e] in {'(', '['}: inc depth
    elif sig[e] in {')', ']'}:
      dec depth
      if depth == 0: break
    inc e
  for grp in splitTop(sig[i + 1 ..< min(e, sig.len)], {';'}):
    let g = grp.strip
    if g.len == 0: continue
    let c = topColon(g)
    var names, typ: string
    if c >= 0:
      names = g[0 ..< c]
      typ = g[c + 2 .. ^1].strip
    else:
      let eq = g.find('=')
      names = if eq > 0: g[0 ..< eq] else: g
      typ = if eq > 0: g[eq .. ^1].strip else: ""
    for n in names.split(','):
      if n.strip.len > 0: result.add (n.strip, typ)

proc plainType(t: string): string =
  ## "int literal(1)" → "int", "system.string" → "string"
  let k = t.find(" literal(")
  (if k > 0: t[0 ..< k] else: t).replace("system.", "")

proc sigName(sig: string): (string, int) =
  ## the routine's name in "proc `[]`[A](…)" and where it ends
  var i = sig.find(' ') + 1
  if i <= 0: return ("", 0)
  if i < sig.len and sig[i] == '`':
    let e = sig.find('`', i + 1)
    if e > i: return (sig[i + 1 ..< e], e + 1)
  var e = i
  while e < sig.len and sig[e] notin {'[', '(', ' '}: inc e
  (sig[i ..< e], e)

proc genericNames(sig: string): seq[string] =
  let (_, e) = sigName(sig)
  if e >= sig.len or sig[e] != '[': return
  var d = 0
  var k = e
  while k < sig.len:
    if sig[k] == '[': inc d
    elif sig[k] == ']':
      dec d
      if d == 0: break
    inc k
  for part in splitTop(sig[e + 1 ..< min(k, sig.len)], {',', ';'}):
    let n = part.split(':')[0].strip
    if n.len > 0: result.add n

proc unifyType(pt, gt: string, gens: seq[string], binds: var Table[string, string]) =
  ## what each generic parameter stands for, from the types you gave: seq[T] + seq[int] → T = int
  var p = pt.strip
  for pre in ["var ", "sink ", "lent ", "static "]:
    if p.startsWith(pre): p = p[pre.len .. ^1].strip
  let g = plainType(gt.strip)
  if p in gens:
    if p notin binds and g.len > 0: binds[p] = g
    return
  let pb = p.find('[')
  let gb = g.find('[')
  if pb <= 0 or gb <= 0 or not p.endsWith("]") or not g.endsWith("]"): return
  let ph = p[0 ..< pb]
  let gh = g[0 ..< gb]
  var pa = splitTop(p[pb + 1 ..< p.high], {','})
  var ga = splitTop(g[gb + 1 ..< g.high], {','})
  if ph == "openArray" and gh == "array" and ga.len == 2: ga = @[ga[1]]
  elif ph != gh and not (ph == "openArray" and gh == "seq"): return
  for i in 0 ..< min(pa.len, ga.len): unifyType(pa[i], ga[i], gens, binds)

proc withBinds(t: string, binds: Table[string, string]): string =
  ## "openArray[T]" → "openArray[T] (T = int)"
  result = t
  var notes: seq[string]
  var i = 0
  while i < t.len:
    if t[i] in IdentStartChars:
      var e = i
      while e < t.len and t[e] in IdentChars: inc e
      let w = t[i ..< e]
      if w in binds and (w & " = " & binds[w]) notin notes: notes.add w & " = " & binds[w]
      i = e
    else: inc i
  if notes.len > 0: result.add " (" & notes.join(", ") & ")"

type NimMismatch = object
  expr, callee: string
  args: seq[(string, string, string)]           # (expression, its type, the name given to it)
  cands: seq[(int, string, seq[string])]        # (first mismatch position, signature, details)
  best: int

proc parseMismatch(msg: string): NimMismatch =
  ## Nim 2.2's format:  Expression: f(a, b) ⏎ [1] a: T ⏎ … ⏎ Expected one of (first mismatch at [position]): ⏎ [2] proc f(…)
  result.best = -1
  var inCands = false
  for l in msg.splitLines:
    let t = l.strip
    if t.startsWith("Expression:"): result.expr = t["Expression:".len .. ^1].strip
    elif t.startsWith("Expected one of"): inCands = true
    elif t.startsWith("[") and "]" in t:
      let k = t.find(']')
      let n = (try: parseInt(t[1 ..< k]) except ValueError: 0)
      let rest = t[k + 1 .. ^1].strip
      if inCands: result.cands.add (n, rest, @[])
      else:
        let c = topColon(rest)
        var ex = if c >= 0: rest[0 ..< c] else: rest
        var ty = if c >= 0: rest[c + 2 .. ^1].strip else: ""
        var nm = ""
        let parts = splitTop(ex, {'='})
        if parts.len == 2 and parts[0].strip.validIdentifier:      # a named argument: "b = 1: b: int"
          nm = parts[0].strip
          if ty.startsWith(nm & ": "): ty = ty[nm.len + 2 .. ^1]
        result.args.add (ex.strip, ty, nm)
    elif inCands and result.cands.len > 0 and t.len > 0: result.cands[^1][2].add t
  for i, c in result.cands:
    if result.best < 0 or c[0] > result.cands[result.best][0]: result.best = i
  result.callee = if result.best >= 0: sigName(result.cands[result.best][1])[0] else: ""
  if result.callee.len == 0:
    let p = result.expr.find('(')
    result.callee = if p > 0: result.expr[0 ..< p] else: result.expr

proc mismatchWant(m: NimMismatch, ai: int): string =
  ## what the closest candidate wants for argument `ai` (0-based), its generic parameters filled in
  if m.best < 0: return ""
  let sig = m.cands[m.best][1]
  let ps = nimParams(sig)
  let gens = genericNames(sig)
  var binds: Table[string, string]
  if gens.len > 0:
    for i, a in m.args:
      if a[2].len == 0 and i < ps.len and i != m.cands[m.best][0] - 1: unifyType(ps[i][1], a[1], gens, binds)
  let nm = m.args[ai][2]
  if nm.len > 0:
    for (n, t) in ps:
      if n == nm: return n & ": " & withBinds(t, binds)
    return "(no parameter " & nm & ")"
  if ai < ps.len: ps[ai][0] & ": " & withBinds(ps[ai][1], binds)
  elif ps.len > 0 and ps[^1][1].startsWith("varargs["): ps[^1][0] & ": " & ps[^1][1]   # the rest go to varargs
  else: "(one too many)"

proc nimMsgSummary(msg: string): string =
  ## one line for the Problems panel and the end of the line: what is wrong, in words
  let first = msg.splitLines()[0]
  if first.startsWith("type mismatch") and "Expected one of" in msg:
    let m = parseMismatch(msg)
    if m.best < 0: return first
    let (n, _, det) = m.cands[m.best]
    for d in det:
      if d.startsWith("missing parameter:"):
        let pn = d.split(':')[^1].strip
        var want = pn
        for (x, t) in nimParams(m.cands[m.best][1]):
          if x == pn: want = x & ": " & t
        return m.expr & " — missing argument " & want
      if d.startsWith("extra argument"):
        return m.expr & " — one argument too many" & (if n in 1 .. m.args.len: ": " & m.args[n - 1][0] else: "")
    for a in m.args:                   # an argument with no type: an error before it is the real cause
      if a[1].strip.len == 0:
        return "type mismatch: " & a[0].strip(chars = {':', ' '}) & " has no type (see the error where it is made)"
    if n in 1 .. m.args.len:
      let a = m.args[n - 1]
      return "type mismatch: " & a[0] & " is " & plainType(a[1]) & ", " & m.callee & " wants " & mismatchWant(m, n - 1)
    var ts: seq[string]
    for a in m.args: ts.add plainType(a[1])
    return "type mismatch: no " & m.callee & " takes (" & ts.join(", ") & ")"
  if first.startsWith("undeclared identifier:") and "candidates" in msg:
    for l in msg.splitLines()[1 .. ^1]:
      let q1 = l.find('\'')
      let q2 = l.rfind('\'')
      if l.strip.startsWith("(") and q2 > q1 and q1 >= 0:
        return first & " — did you mean " & l[q1 + 1 ..< q2] & "?"
  first

proc prettyNimError2(msg: string): string =
  ## the mismatch as a table: each argument, its type, what the closest overload wants; ✗ the first misfit
  let m = parseMismatch(msg)
  if m.best < 0: return msg
  let (n, sig, det) = m.cands[m.best]
  result = "type mismatch in " & m.expr & "\n\n"
  if m.args.len > 0:
    var w1 = 10
    var w2 = 8
    for a in m.args:
      w1 = max(w1, min(28, a[0].len))
      w2 = max(w2, min(28, plainType(a[1]).len))
    result.add "    " & alignLeft("you gave", w1) & "  " & alignLeft("of type", w2) & "  " & m.callee & " wants\n"
    for i, a in m.args:
      let mark = if i + 1 == n: "  ✗ " else: "    "
      var ex = a[0]
      if ex.len > 28: ex = ex[0 ..< 27] & "…"
      var ty = plainType(a[1])
      if ty.len > 28: ty = ty[0 ..< 27] & "…"
      result.add mark & alignLeft(ex, w1) & "  " & alignLeft(ty, w2) & "  " & mismatchWant(m, i) & "\n"
  for d in det: result.add "    " & d & "\n"
  result.add "\nclosest: " & sig & "\n"
  if m.cands.len > 1:
    result.add $(m.cands.len - 1) & " other candidate" & (if m.cands.len > 2: "s" else: "") & ":\n"
    var shown = 0
    for i, c in m.cands:
      if i == m.best: continue
      if shown == 5:
        result.add "  … " & $(m.cands.len - 1 - shown) & " more\n"
        break
      result.add "  " & c[1] & (if c[0] in 1 .. m.args.len: "   (argument " & $c[0] & " does not fit)" else: "") & "\n"
      inc shown

proc nimFollowOn(msg: string): bool =
  ## errors Nim reports after a type mismatch or an unknown name on the same line: noise
  for p in ["expression '' has no type", "'let' symbol requires an initialization", "'' cannot be assigned to",
            "attempting to call routine:", "attempting to call undeclared routine:", "expression '' is of type",
            "undeclared identifier: ''", "'const' symbol requires"]:
    if msg.startsWith(p): return true

proc dropNimFollowOns(ds: var seq[Diag]) =
  var lines: HashSet[int]
  for d in ds:
    if d.sev == 1 and (d.msg.startsWith("type mismatch") or d.msg.startsWith("undeclared identifier")): lines.incl d.line
  if lines.len == 0: return
  var k = 0
  for d in ds:
    if not (d.line in lines and nimFollowOn(d.msg)):
      ds[k] = d
      inc k
  ds.setLen(k)
