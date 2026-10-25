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
