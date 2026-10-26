# ── Nim 3 (Nimony): what Nim 2 code must change to compile under Nimony (doc/porting.md, each rule checked against
#    what nimony 0.6.3 itself rejects — closure iterators and generics without [T] compile now, and the project's own
#    ref exception types work as in Nim 2, so those are not flagged) — the engine's "nim3" rule. On in a Nim 3
#    project; in a Nim 2 one when asked (Nim › Nim 3 › What this file needs). Where the change is mechanical the
#    problem carries it, and the quick fix (Alt+Enter) makes it ──

proc n3Problem(res: var seq[Diag], l, a, e: int, msg: string, title = "",
               edits: seq[(int, int, int, int, string)] = @[], sev = 2) =
  ## a porting problem on line l (columns a ..< e); `edits`: (line, col, end line, end col, new text) that fix it
  var d = Diag(line: l, col: a, eline: l, ecol: e, sev: sev, msg: "Nim 3: " & msg, src: "ned", rule: "nim3")
  if title.len > 0 and edits.len > 0:
    var js = newJArray()
    for (l1, c1, l2, c2, t) in edits: js.add %*[l1, c1, l2, c2, t]
    d.code = %*{"nim3fix": title, "edits": js}
  res.add d

func n3Word(s: string, k: int, w: string): bool =
  ## is `w` at k a whole word?
  k >= 0 and k + w.len <= s.len and s[k ..< k + w.len] == w and (k == 0 or s[k - 1] notin IdentChars) and
    (k + w.len >= s.len or s[k + w.len] notin IdentChars)

iterator n3WordsAt(s, w: string): int =
  var k = s.find(w)
  while k >= 0:
    if n3Word(s, k, w): yield k
    k = s.find(w, k + 1)

func n3SkipSp(s: string, k: int): int =
  ## the first index at or after k that is no space
  result = k
  while result < s.len and s[result] in {' ', '\t'}: inc result

func n3IdentEnd(s: string, k: int): int =
  result = k
  while result < s.len and s[result] in IdentChars: inc result

proc n3OwnType(sc: NxScope, name: string): bool =
  ## is `name` a type the project declares (not the standard library's)? — an exception of its own: Nimony raises and
  ## catches those as Nim does (`except MyError as e`, newException(MyError, …)); the library's IOError, ValueError …
  ## are ErrorCode values in Nim 3
  if sc == nil: return false
  for r in nxLookup(sc, name):
    if r.sym.kind == nxType and not (nxLibDir.len > 0 and r.file.path.startsWith(nxLibDir & "/")): return true
  false

proc nim3Checks(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  let sc = try: nxScope(f) except CatchableError: nil
  var inPragma = false
  for l, c in code:
    let t = c.strip(trailing = false)
    if t.len == 0: continue
    let ind = c.len - t.len
    # ── except X as e: an ErrorCode has no `as`, no `.msg`
    if t.startsWith("except ") or t.startsWith("except\t"):
      let ex0 = n3SkipSp(c, c.find("except") + 6)
      let exName = c[ex0 ..< n3IdentEnd(c, ex0)]
      for k in n3WordsAt(c, "as"):
        if exName.len == 0 or n3OwnType(sc, exName): break
        let nm = n3SkipSp(c, k + 2)
        let ne = n3IdentEnd(c, nm)
        if ne > nm:
          var a = k
          while a > 0 and c[a - 1] == ' ': dec a
          res.n3Problem(l, k, ne, "an error is an ErrorCode value: no `as " & c[nm ..< ne] & "` (and no `.msg`)",
                        "Remove `as " & c[nm ..< ne] & "`", @[(l, a, l, ne, "")])
          break
    # ── raise newException(X, msg) → raise X
    for k in n3WordsAt(c, "newException"):
      var o = k + "newException".len
      while o < c.len and c[o] == ' ': inc o
      if o < c.len and c[o] == '(':
        let x0 = n3SkipSp(c, o + 1)
        let x1 = n3IdentEnd(c, x0)
        var depth = 0
        var close = -1
        for q in o ..< c.len:
          if c[q] in {'(', '['}: inc depth
          elif c[q] in {')', ']'}:
            dec depth
            if depth == 0:
              close = q
              break
        let ex = c[x0 ..< x1]
        if x1 > x0 and n3OwnType(sc, ex): continue          # (an exception type of the project's own: fine in Nim 3)
        if x1 > x0 and close > 0:
          res.n3Problem(l, k, close + 1, "errors are ErrorCode values: `raise " & ex & "`, not newException",
                        "Make it `" & ex & "`", @[(l, k, l, close + 1, ex)])
        else:
          res.n3Problem(l, k, k + 12, "errors are ErrorCode values: `raise IOError`, not newException")
    # ── {.async.} → {.passive.}; await x → x
    let po = c.find("{.")
    if po >= 0 or inPragma:
      let pe = c.find(".}", max(0, po))
      for k in n3WordsAt(c, "async"):
        if (po >= 0 and k > po and (pe < 0 or k < pe)) or (inPragma and (pe < 0 or k < pe)):
          var after = k + 5
          while after < c.len and c[after] == ' ': inc after
          if after < c.len and c[after] == ':':
            res.n3Problem(l, k, k + 5, "async is {.passive.} (and a call waits by itself, no await)")
          else:
            res.n3Problem(l, k, k + 5, "async is {.passive.} (and a call waits by itself, no await)",
                          "Make it {.passive.}", @[(l, k, l, k + 5, "passive")])
      if po >= 0 and pe < 0: inPragma = true
      elif pe >= 0: inPragma = false
    for k in n3WordsAt(c, "await"):
      var e = k + 5
      while e < c.len and c[e] == ' ': inc e
      if e < c.len and e > k + 5 and c[e] in IdentChars + {'('}:
        res.n3Problem(l, k, k + 5, "no await: a {.passive.} call waits by itself", "Remove `await`",
                      @[(l, k, l, e, "")])
    # ── an unlabeled break inside a block: it leaves only a loop in Nim 3
    if t == "break" or t.startsWith("break ") and t[6 .. ^1].strip.len == 0:
      var u = l - 1
      while u >= 0:
        let ut = code[u].strip(trailing = false)
        let ui = code[u].len - ut.len
        if ut.len > 0 and ui < ind:
          if ut.startsWith("for ") or ut.startsWith("while "): break
          if ut.startsWith("proc ") or ut.startsWith("func ") or ut.startsWith("iterator ") or
             ut.startsWith("method ") or ut.startsWith("template ") or ut.startsWith("macro "): break
          if ut.startsWith("block"):
            let lbl = ut[5 .. ^1].strip.strip(chars = {':', ' '})
            if lbl.len > 0 and lbl.allCharsInSet(IdentChars):
              res.n3Problem(l, ind, ind + 5, "a `break` leaves only a loop: `break " & lbl & "` leaves the block",
                            "Make it `break " & lbl & "`", @[(l, ind + 5, l, ind + 5, " " & lbl)])
            else:
              res.n3Problem(l, ind, ind + 5, "a `break` leaves only a loop: name the block (`block done:`) and " &
                            "`break done`")
            break
        dec u
    # ── x.isNil → x == nil (isNil is cstring's only)
    for k in n3WordsAt(c, "isNil"):
      if k > 0 and c[k - 1] == '.':
        var a = k - 1
        while a > 0 and (c[a - 1] in IdentChars or c[a - 1] == '.'): dec a
        let recv = c[a ..< k - 1]
        if recv.len > 0 and recv[0] in IdentStartChars:
          res.n3Problem(l, a, k + 5, "`" & recv & " == nil` (isNil is there only for cstring)",
                        "Make it `" & recv & " == nil`", @[(l, a, l, k + 5, recv & " == nil")], sev = 3)
    # ── for x in AnEnum: → low(AnEnum)..high(AnEnum)
    if t.startsWith("for ") and t.endsWith(":") and sc != nil:
      let inAt = c.find(" in ")
      if inAt > 0:
        let e0 = inAt + 4
        let e1 = n3IdentEnd(c, e0)
        if e1 > e0 and c[e1 ..< c.len].strip == ":":
          let nm = c[e0 ..< e1]
          var isEnum = false
          for r in nxLookup(sc, nm):
            if r.sym.kind == nxType and r.sym.typ.strip.startsWith("enum"): isEnum = true
          if isEnum:
            res.n3Problem(l, e0, e1, "an enum is not iterable: `low(" & nm & ")..high(" & nm & ")`",
                          "Make it low(" & nm & ")..high(" & nm & ")",
                          @[(l, e0, l, e1, "low(" & nm & ")..high(" & nm & ")")])
    # ── a template without parameters is called with ()
    if sc != nil and t.allCharsInSet(IdentChars) and t[0] in IdentStartChars and
       t notin ["discard", "break", "continue", "return", "result", "yield", "raise"]:
      var isTpl = false
      for r in nxLookup(sc, t):
        if r.sym.kind == nxTemplate and r.sym.params.len == 0: isTpl = true
      if isTpl:
        res.n3Problem(l, ind, ind + t.len, "a template without parameters is called with (): `" & t & "()`",
                      "Make it " & t & "()", @[(l, ind + t.len, l, ind + t.len, "()")])
    # ── a string has no terminating zero: cstring(s), s.cstring, cast[cstring](addr s[0])
    if "cast[cstring]" in c:
      let k = c.find("cast[cstring]")
      res.n3Problem(l, k, k + 13, "a string has no terminating zero: s.toCString (a copy that has one)", sev = 3)
  # ── names are case-sensitive in Nim 3: each one written as it is declared (`toUpperascii` → toUpperAscii)
  if sc != nil:
    var spell: Table[string, seq[string]]           # (Nim 2's identity of a name → how its declarations write it)
    template learn(nm: string) =
      if nm.len > 1 and nm[0] in IdentStartChars:
        let k = nxNorm(nm)
        if k notin spell: spell[k] = @[nm]
        elif nm notin spell[k]: spell[k].add nm
    for s0 in f.syms: learn(s0.name)
    for r in sc.refs: learn(r.file.syms[r.idx].name)
    var st: NxLexState
    var said = 0
    for l, c in code:
      for (a, e) in nxIdents(c, st):
        let w = c[a ..< e]
        if w.len < 2 or w in NxKeywords or (a > 0 and c[a - 1] == '`'): continue
        let k = nxNorm(w)
        if k notin spell or w in spell[k]: continue
        let want = spell[k]
        if want.len == 1:
          res.n3Problem(l, a, e, "names are case-sensitive: it is declared `" & want[0] & "`",
                        "Write it " & want[0], @[(l, a, l, e, want[0])])
        else:
          res.n3Problem(l, a, e, "names are case-sensitive: it is declared " & want.join(" or "))
        inc said
        if said >= 200: break
      if said >= 200: break

proc cmdNim3Problems() =
  ## Nim › Nim 3: what this file needs — the porting problems of a Nim 2 file shown (and from then on nimony checks
  ## it on save); in a Nim 3 project they are always shown
  let b = buf()
  if b.lang == nil or b.lang.mode != lmNim or b.path.len == 0:
    info("Open a saved Nim file")
    return
  if not nim3On():
    if b.path in nim3Asked:
      nim3Asked.excl b.path
      engineAgain(b.path)
      info("Nim 3 porting problems hidden for " & extractFilename(b.path))
      return
    nim3Asked.incl b.path
  engineAgain(b.path)
  needRender = true
  info("Nim 3: what " & extractFilename(b.path) & " needs is in Problems (Ctrl+. fixes what ned can)" &
       (if nimonyExe().len > 0: " — nimony checks it on save" else: " — install nimony to check it"))
  showProblems()

# ── Nim 3's contracts and passive procs: what nimony says when it compiles, said as you type ──

type N3Val = tuple[known: bool, v: BiggestInt]

type N3Names = proc (name: string): N3Val {.closure.}

proc n3Eval(e: string, vals: Table[string, BiggestInt], names: N3Names = nil): N3Val =
  ## the value of a `requires` condition with the parameters given (booleans as 1 and 0) — known: false when it
  ## names something else (s.len, a call, a constant ned does not know); `names`: the value of a name that is not
  ## a parameter (a constant), when it can tell
  var toks: seq[string]
  var i = 0
  while i < e.len:
    let c = e[i]
    if c in {' ', '\t'}: inc i
    elif c in IdentStartChars:
      var k = i
      while k < e.len and e[k] in IdentChars: inc k
      toks.add e[i ..< k]
      i = k
    elif c in {'0'..'9'}:
      var k = i
      while k < e.len and e[k] in {'0'..'9', '_', 'x', 'X', 'a'..'f', 'A'..'F', '\''}: inc k
      toks.add e[i ..< k]
      i = k
    elif i + 1 < e.len and e[i .. i + 1] in ["<=", ">=", "==", "!="]:
      toks.add e[i .. i + 1]
      i += 2
    elif c in {'<', '>', '+', '-', '*', '(', ')'}:
      toks.add $c
      inc i
    else: return (false, 0)                         # (s.len, a[i], "…": not worked out here)
  var p = 0
  proc peek(): string = (if p < toks.len: toks[p] else: "")
  proc expr(): N3Val
  proc primary(): N3Val =
    let t = peek()
    inc p
    if t == "(":
      result = expr()
      if peek() == ")": inc p
      else: result.known = false
    elif t == "-":
      let x = primary()
      result = (x.known, -x.v)
    elif t == "not":
      let x = primary()
      result = (x.known, BiggestInt(x.v == 0))
    elif t == "true": result = (true, 1)
    elif t == "false": result = (true, 0)
    elif t.len > 0 and t[0] in {'0'..'9'}:
      var s = t.replace("_", "")
      let q = s.find('\'')
      if q >= 0: s = s[0 ..< q]
      try: result = (true, BiggestInt(if s.startsWith("0x") or s.startsWith("0X"): parseHexInt(s) else: parseBiggestInt(s)))
      except ValueError: result = (false, 0)
    elif t.len > 0 and t in vals and peek() notin ["(", "."]: result = (true, vals[t])
    elif names != nil and t.len > 0 and t[0] in IdentStartChars and peek() notin ["(", ".", "["]: result = names(t)
    else: result = (false, 0)
  proc term(): N3Val =
    result = primary()
    while peek() in ["*", "div", "mod"]:
      let op = peek()
      inc p
      let r = primary()
      if not (result.known and r.known) or (op != "*" and r.v == 0): result.known = false
      else: result.v = (if op == "*": result.v * r.v elif op == "div": result.v div r.v else: result.v mod r.v)
  proc sum(): N3Val =
    result = term()
    while peek() in ["+", "-"]:
      let op = peek()
      inc p
      let r = term()
      result = (result.known and r.known, (if op == "+": result.v + r.v else: result.v - r.v))
  proc cmp(): N3Val =
    result = sum()
    if peek() in ["<", "<=", ">", ">=", "==", "!="]:
      let op = peek()
      inc p
      let r = sum()
      let ok = case op
               of "<": result.v < r.v
               of "<=": result.v <= r.v
               of ">": result.v > r.v
               of ">=": result.v >= r.v
               of "==": result.v == r.v
               else: result.v != r.v
      result = (result.known and r.known, BiggestInt(ok))
  proc conj(): N3Val =
    result = cmp()
    while peek() == "and":
      inc p
      let r = cmp()
      # (false and anything is false, even when the other side is not known)
      if (result.known and result.v == 0) or (r.known and r.v == 0): result = (true, 0)
      else: result = (result.known and r.known, 1)
  proc expr(): N3Val =
    result = conj()
    while peek() == "or":
      inc p
      let r = conj()
      if (result.known and result.v != 0) or (r.known and r.v != 0): result = (true, 1)
      else: result = (result.known and r.known, 0)
  result = expr()
  if p < toks.len: result.known = false

func n3PragmaValue(prag, key: string): string =
  ## `requires: (x > 0)` in a routine's pragmas: the condition
  var k = prag.find(key & ":")
  while k > 0 and prag[k - 1] in IdentChars: k = prag.find(key & ":", k + 1)
  if k < 0: return ""
  var i = k + key.len + 1
  while i < prag.len and prag[i] == ' ': inc i
  var depth = 0
  var e = i
  while e < prag.len:
    if prag[e] in {'(', '['}: inc depth
    elif prag[e] in {')', ']'}: dec depth
    elif prag[e] == ',' and depth == 0: break
    inc e
  prag[i ..< e].strip

func n3Args(s: string, open: int): (seq[string], int) =
  ## the arguments of the call whose ( is at `open`, split at its top-level commas, and where its ) is (-1: not on
  ## this line)
  var depth = 0
  var a = open + 1
  for i in open ..< s.len:
    case s[i]
    of '(', '[', '{': inc depth
    of ')', ']', '}':
      dec depth
      if depth == 0:
        if s[a ..< i].strip.len > 0: result[0].add s[a ..< i].strip
        result[1] = i
        return
    of ',':
      if depth == 1:
        result[0].add s[a ..< i].strip
        a = i + 1
    else: discard
  result[1] = -1

proc n3NameValue(sc: NxScope, locals: seq[NxSym], name: string, depth = 0): N3Val =
  ## a name whose value is known where it is used: a let or const of the routine (the last one declared), else a
  ## constant of the module or its imports — not a var (it may have changed), not a parameter
  if depth > 4: return (false, 0)
  let again: N3Names = proc (n: string): N3Val = n3NameValue(sc, locals, n, depth + 1)
  for k in countdown(locals.high, 0):
    let x = locals[k]
    if x.name != name: continue
    if x.kind in {nxLet, nxConst} and x.value.len > 0: return n3Eval(x.value, initTable[string, BiggestInt](), again)
    return (false, 0)
  for r in nxLookup(sc, name):
    if r.sym.kind == nxConst and r.sym.value.len > 0:
      return n3Eval(r.sym.value, initTable[string, BiggestInt](), again)
    return (false, 0)
  (false, 0)

proc n3LoopRange(sc: NxScope, locals: seq[NxSym], name: string): (bool, BiggestInt, BiggestInt) =
  ## a loop variable over `a .. b` or `a ..< b` (countup(a, b) too) whose ends are known: (yes, its first, its last)
  for k in countdown(locals.high, 0):
    let x = locals[k]
    if x.name != name: continue
    if x.kind != nxForVar: return
    var v = x.value.strip
    var lo, hi: string
    var open = false
    if v.startsWith("countup(") and v.endsWith(")"):
      let parts = v[8 ..< ^1].split(',')
      if parts.len != 2: return
      (lo, hi) = (parts[0].strip, parts[1].strip)
    else:
      let d = v.find("..")
      if d <= 0: return
      lo = v[0 ..< d].strip
      hi = v[d + 2 .. ^1].strip
      if hi.startsWith("<"):
        open = true
        hi = hi[1 .. ^1].strip
    let names: N3Names = proc (n: string): N3Val = n3NameValue(sc, locals, n)
    let a = n3Eval(lo, initTable[string, BiggestInt](), names)
    let e = n3Eval(hi, initTable[string, BiggestInt](), names)
    if not (a.known and e.known): return
    let last = if open: e.v - 1 else: e.v
    if last < a.v: return                                # (it does not run)
    return (true, a.v, last)

proc n3Ensures(f: NxFile, sc: NxScope, code: seq[string], res: var seq[Diag]) =
  ## a routine whose `{.ensures: …}` a `return` or `result =` of a value known where it is written breaks
  for s in f.syms:
    if s.kind notin {nxProc, nxFunc, nxMethod, nxConverter} or "ensures" notin s.pragmas: continue
    let cond = n3PragmaValue(s.pragmas, "ensures")
    if cond.len == 0 or s.endLine <= s.line: continue
    for l in s.line + 1 .. min(s.endLine, code.high):
      let t = code[l].strip
      var e = ""
      if t.startsWith("return "): e = t[7 .. ^1].strip
      elif t.startsWith("result =") or t.startsWith("result="): e = t[t.find('=') + 1 .. ^1].strip
      if e.len == 0: continue
      let locals = try: nxLocals(f, code, l, 0) except CatchableError: @[]
      let names: N3Names = proc (n: string): N3Val = n3NameValue(sc, locals, n)
      let v = n3Eval(e, initTable[string, BiggestInt](), names)
      if not v.known: continue
      let r = n3Eval(cond, {"result": v.v}.toTable, names)
      if r.known and r.v == 0:
        let a = code[l].len - code[l].strip(trailing = false).len
        res.add Diag(line: l, col: a, eline: l, ecol: a + t.len, sev: 1, src: "ned", rule: "contract",
                     msg: "Nim 3: contract violated: " & s.name & " ensures " & cond & " (result = " & e & ")")

proc nim3CodeChecks(f: NxFile, b: Buffer, code: seq[string], res: var seq[Diag]) =
  ## a call whose literal arguments break the routine's {.requires: …} (`contract`); delay(f(…)) of a passive proc
  ## with a var, out or lent parameter (`passive`) — nimony's own errors, before it compiles
  let sc = try: nxScope(f) except CatchableError: nil
  if sc == nil: return
  var said = 0
  for l, c in code:
    if '(' notin c: continue
    var k = c.find('(')
    while k >= 0 and said < 100:
      var ma = k
      while ma > 0 and c[ma - 1] in IdentChars: dec ma
      if ma < k and c[ma] notin {'0'..'9'} and (ma == 0 or c[ma - 1] != '.'):
        let name = c[ma ..< k]
        # (one routine of that name in scope: an overload ned cannot tell apart is not judged)
        var routs: seq[NxSym]
        for r in nxLookup(sc, name):
          if r.sym.kind in {nxProc, nxFunc, nxMethod, nxIterator, nxConverter}: routs.add r.sym
        let (args, close) = n3Args(c, k)
        if name == "delay" and args.len == 1:
          # delay(handle(c)): the callee's continuation outlives this frame
          let inner = args[0]
          let ip = inner.find('(')
          if ip > 0:
            let callee = inner[0 ..< ip].strip
            var cs: seq[NxSym]
            for r in nxLookup(sc, callee):
              if r.sym.kind in {nxProc, nxFunc, nxMethod}: cs.add r.sym
            if cs.len == 1 and "passive" in cs[0].pragmas:
              for prm in cs[0].params:
                let t = prm.typ.strip
                if t.startsWith("var ") or t.startsWith("out ") or t.startsWith("lent "):
                  let at = c.find(callee, k)
                  res.add Diag(line: l, col: max(0, at), eline: l, ecol: max(0, at) + callee.len, sev: 1, src: "ned",
                               rule: "passive", msg: "Nim 3: `delay` hands `" & callee & "` to a scheduler, so its " &
                               "continuation can outlive this frame; parameter `" & prm.name & ": " & t &
                               "` would alias a location that is already gone. Take it as `sink` instead")
                  inc said
                  break
        elif routs.len == 1 and "requires" in routs[0].pragmas and args.len > 0 and close > 0:
          let s = routs[0]
          let cond = n3PragmaValue(s.pragmas, "requires")
          if cond.len > 0 and args.len <= s.params.len:
            var vals: Table[string, BiggestInt]
            var shown: seq[string]
            var ok = true
            var loop: (string, string, BiggestInt, BiggestInt)    # (a loop variable given: the parameter, it, its ends)
            let locals = try: nxLocals(f, b.lines, l, k) except CatchableError: @[]
            let names: N3Names = proc (n: string): N3Val = n3NameValue(sc, locals, n)
            for i, a in args:
              var pname = s.params[i].name
              var av = a
              let eq = a.find('=')
              if eq > 0 and a[0 ..< eq].strip.allCharsInSet(IdentChars) and (eq + 1 >= a.len or a[eq + 1] != '='):
                pname = a[0 ..< eq].strip                  # (a named argument)
                av = a[eq + 1 .. ^1].strip
              # (a number, true or false, a let or const whose value is known here)
              let v = n3Eval(av, initTable[string, BiggestInt](), names)
              if v.known:
                vals[pname] = v.v
                shown.add pname & " = " & (if av.allCharsInSet(IdentChars) and av[0] in IdentStartChars and
                                             av notin ["true", "false"]: av & " = " & $v.v else: av)
              elif av.len > 0 and av.allCharsInSet(IdentChars) and loop[0].len == 0:
                let (isLoop, lo, hi) = n3LoopRange(sc, locals, av)
                if isLoop: loop = (pname, av, lo, hi)
              elif av.len == 0: ok = false
            if ok and loop[0].len > 0:
              # (the loop's first and its last value: the condition is held to both)
              for (v, which) in [(loop[2], "its first"), (loop[3], "its last")]:
                var vs = vals
                vs[loop[0]] = v
                let r = n3Eval(cond, vs, names)
                if r.known and r.v == 0:
                  res.add Diag(line: l, col: ma, eline: l, ecol: close + 1, sev: 1, src: "ned", rule: "contract",
                               msg: "Nim 3: contract violated: requires " & cond & " — when " & loop[1] & " = " & $v &
                                    " (the loop's " & which[4 .. ^1] & " value)" &
                                    (if shown.len > 0: ", " & shown.join(", ") else: ""))
                  inc said
                  break
            elif ok and vals.len > 0:
              let r = n3Eval(cond, vals, names)
              if r.known and r.v == 0:
                res.add Diag(line: l, col: ma, eline: l, ecol: close + 1, sev: 1, src: "ned", rule: "contract",
                             msg: "Nim 3: contract violated: requires " & cond & " (" & shown.join(", ") & ")")
                inc said
      k = c.find('(', k + 1)
  n3Ensures(f, sc, code, res)
