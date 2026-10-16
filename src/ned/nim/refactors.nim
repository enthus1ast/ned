# ── refactors: extract a variable, inline one, "a" & x → fmt"a{x}", and evaluating Nim at compile time ──

proc stmtStart(b: Buffer, line: int): int =
  ## the first line of the statement `line` belongs to (lines that end with , ( [ { or an operator continue)
  result = line
  while result > 0:
    let t = b.lines[result - 1].strip
    if t.len == 0: break
    let routine = t.startsWith("proc ") or t.startsWith("func ") or t.startsWith("method ") or
                  t.startsWith("iterator ") or t.startsWith("template ") or t.startsWith("macro ") or
                  t.startsWith("converter ") or t.startsWith("type ") or t.startsWith("def ") or t.startsWith("fn ")
    let cont = t[^1] in {',', '(', '[', '{', '+', '-', '*', '/', '&', '|', '\\'} or t.endsWith(" and") or
               t.endsWith(" or") or (t[^1] == '=' and not routine and not t.endsWith("=="))
    if not cont: break
    dec result

proc extractVariable() =
  ## the selected expression into a variable declared above the statement (and its other copies in the block)
  let b = buf()
  if not b.canEdit(): return
  let (sa, se) = b.primary.range
  if sa == se or sa.line != se.line:
    info("Select an expression (on one line) to put in a variable")
    return
  let expr = b.getText(sa, se).strip
  if expr.len == 0: return
  let decl = case b.lang.id
    of "nim": "let $1 = $2"
    of "python", "ruby": "$1 = $2"
    of "javascript", "typescript": "const $1 = $2;"
    of "go": "$1 := $2"
    of "rust": "let $1 = $2;"
    of "lua": "local $1 = $2"
    else: ""
  if decl.len == 0:
    info("Extract variable works in Nim, Python, Ruby, JS/TS, Go, Rust and Lua")
    return
  var guess = "value"
  block:
    var e = expr
    let p = e.find('(')
    if p > 0: e = e[0 ..< p]
    let parts = e.split({'.', ' ', '[', '$', '@'})
    for i in countdown(parts.high, 0):
      let w = parts[i].strip
      if w.len > 1 and w.validIdentifier and w notin b.lang.keywords:
        guess = w & (if p > 0: "Result" else: "")
        break
  let sl = b.stmtStart(sa.line)
  let ind = leadingWs(b.lines[sl])
  # the same expression elsewhere in the block, after the declaration
  var others: seq[(int, int)]
  var l = sl
  while l < b.lines.len:
    let s = b.lines[l]
    if l > sl and not isBlank(s) and leadingWs(s).len < ind.len: break
    var k = s.find(expr)
    while k >= 0:
      let okL = k == 0 or s[k - 1] notin IdentChars or expr[0] notin IdentChars
      let okR = k + expr.len >= s.len or s[k + expr.len] notin IdentChars or expr[^1] notin IdentChars
      if okL and okR and not (l == sa.line and k == sa.col): others.add (l, k)
      k = s.find(expr, k + expr.len)
    inc l
  let bid = b.id
  proc doIt(name: string, all: bool) =
    let bb = bufById(bid)
    if bb == nil: return
    bb.beginEdit()
    var spots = @[(sa.line, sa.col)]
    if all: spots.add others
    spots.sort(proc(x, y: (int, int)): int = cmp(y[0] * 1_000_000 + y[1], x[0] * 1_000_000 + x[1]))
    for (ln, c) in spots:                     # from the bottom up, so the positions stay right
      discard bb.replaceText(Pos(line: ln, col: c), Pos(line: ln, col: c + expr.len), name)
    discard bb.replaceText(Pos(line: sl, col: 0), Pos(line: sl, col: 0), ind & (decl % [name, expr]) & "\n")
    bb.endEdit()
    bb.setSingle(Pos(line: sl, col: ind.len + decl.find("$1")))
    info("Extracted " & name & (if all and others.len > 0: " (" & $(others.len + 1) & " places)" else: ""))
  askText("Name of the variable", guess, proc(name: string) =
    let n = name.strip
    if not n.validIdentifier:
      error(n & " is not a valid name")
      return
    if others.len > 0:
      askConfirm("Also replace the " & $others.len & " other occurrence(s) in this block? (y/n)", proc(c: char) =
        doIt(n, c in {'y', 'Y'}))
    else: doIt(n, false))

proc inlineVariable() =
  ## Nim: `let x = expr` — every later use of x in its block becomes expr, and the declaration goes
  let b = buf()
  if not b.canEdit() or b.lang.mode != lmNim: return
  let w = b.wordAt(b.primary.head)
  if w.len == 0:
    info("Put the cursor on a let or const name")
    return
  var dl = -1
  var expr = ""
  for l in countdown(b.primary.head.line, max(0, b.primary.head.line - 800)):
    let t = b.lines[l].strip
    for kw in ["let ", "const "]:
      if t.startsWith(kw):
        var r = t[kw.len .. ^1]
        if not r.startsWith(w): continue
        r = r[w.len .. ^1].strip(trailing = false)
        if r.startsWith("*"): r = r[1 .. ^1].strip(trailing = false)
        if r.startsWith(":"):
          let eq = r.find(" = ")
          if eq < 0: continue
          r = r[eq + 1 .. ^1]
        if not r.startsWith("= "): continue
        expr = r[2 .. ^1].strip
        let hash = expr.find(" #")
        if hash > 0: expr = expr[0 ..< hash].strip
        dl = l
    if dl >= 0: break
  if dl < 0 or expr.len == 0 or expr.endsWith("=") or expr.endsWith(","):
    info("No one-line `let " & w & " = …` above (inline works on let and const)")
    return
  var simple = true                            # needs ( ) around it when used inside other code?
  var depth = 0
  var inStr = false
  for c in expr:
    if c == '"': inStr = not inStr
    elif not inStr:
      if c in {'(', '['}: inc depth
      elif c in {')', ']'}: dec depth
      elif c == ' ' and depth == 0: simple = false
  let repl = if simple: expr else: "(" & expr & ")"
  let ind = leadingWs(b.lines[dl]).len
  var uses: seq[(int, int)]
  var l = dl + 1
  var (st, _) = b.stateAt(min(dl + 1, b.lines.high))
  var toks: seq[TokKind]
  while l < b.lines.len:
    let s = b.lines[l]
    if not isBlank(s) and leadingWs(s).len < ind: break
    st = lexLine(b.lang, s, st, toks)
    var k = s.find(w)
    while k >= 0:
      if (k == 0 or s[k - 1] notin IdentChars) and (k + w.len >= s.len or s[k + w.len] notin IdentChars) and
         (k >= toks.len or toks[k] notin {tkString, tkComment, tkDoc, tkChar}):
        uses.add (l, k)
      k = s.find(w, k + w.len)
    inc l
  b.beginEdit()
  for i in countdown(uses.high, 0):
    let (ln, c) = uses[i]
    discard b.replaceText(Pos(line: ln, col: c), Pos(line: ln, col: c + w.len), repl)
  discard b.replaceText(Pos(line: dl, col: 0), Pos(line: dl + 1, col: 0), "")
  b.endEdit()
  b.setSingle(b.clampPos(Pos(line: dl, col: ind)))
  info("Inlined " & w & " (" & $uses.len & " use" & (if uses.len == 1: ")" else: "s)"))

proc concatToFmt() =
  ## Nim: "Hello, " & name & "!" → fmt"Hello, {name}!" (imports std/strformat)
  let b = buf()
  if not b.canEdit() or b.lang.mode != lmNim: return
  let p = b.primary.head
  let s = b.lines[p.line]
  # the innermost brackets around the cursor (outside strings), then the comma-separated slot in them
  var depthAt = newSeq[int](s.len + 1)
  var inStr = newSeq[bool](s.len + 1)
  var depth = 0
  var i = 0
  var stop = s.len
  while i < s.len:
    let c = s[i]
    depthAt[i] = depth
    if c == '"':
      inStr[i] = true
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and i + 1 < s.len:
          depthAt[i] = depth
          inStr[i] = true
          inc i
        depthAt[i] = depth
        inStr[i] = true
        inc i
      if i < s.len:
        depthAt[i] = depth
        inStr[i] = true
      inc i
      continue
    if c == '\'' and i + 2 < s.len and s[i + 2] == '\'':
      for k in i .. i + 2:
        depthAt[k] = depth
        inStr[k] = true
      i += 3
      continue
    if c == '#':
      stop = i
      break
    if c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}:
      dec depth
      depthAt[i] = depth
    inc i
  let cur = min(p.col, max(0, stop - 1))
  let d = depthAt[cur]
  var ra = cur
  while ra > 0 and not (depthAt[ra - 1] < d or (depthAt[ra - 1] == d and not inStr[ra - 1] and s[ra - 1] == ',')): dec ra
  var rb = cur
  while rb < stop and not (depthAt[rb] < d or (depthAt[rb] == d and not inStr[rb] and s[rb] in {',', ')', ']', '}'})): inc rb
  # pieces separated by spaces at this depth
  var segs: seq[(int, int)]
  var k = ra
  var st = -1
  while k < rb:
    if s[k] == ' ' and depthAt[k] == d and not inStr[k]:
      if st >= 0: segs.add (st, k)
      st = -1
    elif st < 0: st = k
    inc k
  if st >= 0: segs.add (st, rb)
  var si = -1
  for j, (a, e) in segs:
    if cur >= a and cur <= e: si = j
  if si < 0:
    info("Put the cursor on a string joined with &")
    return
  if s[segs[si][0] ..< segs[si][1]] == "&": dec si
  var cs = si
  while cs >= 2 and s[segs[cs - 1][0] ..< segs[cs - 1][1]] == "&": cs -= 2
  var ce = si
  while ce + 2 < segs.len and s[segs[ce + 1][0] ..< segs[ce + 1][1]] == "&": ce += 2
  if cs < 0 or ce - cs < 2:
    info("No `\"text\" & value` here to turn into fmt")
    return
  var ops: seq[string]
  var j = cs
  while j <= ce:
    ops.add s[segs[j][0] ..< segs[j][1]]
    j += 2
  var anyLit = false
  var amp = false
  for op in ops:
    if op.len >= 2 and op[0] == '"' and op[^1] == '"' and not op.startsWith("\"\"\""):
      anyLit = true
      if '\\' in op: amp = true
    elif op.len == 3 and op[0] == '\'' and op[2] == '\'': discard
    elif '"' in op or '\\' in op: amp = true
  if not anyLit:
    info("No string literal in this & chain")
    return
  var body = ""
  for op in ops:
    if op.len >= 2 and op[0] == '"' and op[^1] == '"' and not op.startsWith("\"\"\""):
      body.add op[1 ..< op.high].replace("{", "{{").replace("}", "}}")
    elif op.len == 3 and op[0] == '\'' and op[2] == '\'':
      body.add ($op[1]).replace("{", "{{").replace("}", "}}").replace("\"", (if amp: "\\\"" else: "\"\""))
    else:
      var e = op
      if e.startsWith("$"): e = e[1 .. ^1]
      if e.startsWith("(") and e.endsWith(")"):
        var dd = 0
        var whole = true
        for q in 0 ..< e.high:
          if e[q] == '(': inc dd
          elif e[q] == ')':
            dec dd
            if dd == 0: whole = false
        if whole: e = e[1 ..< e.high]
      if amp: e = e.replace("\\", "\\\\").replace("\"", "\\\"")
      if ':' in e: e = "(" & e & ")"
      body.add "{" & e & "}"
  let lit = (if amp: "&\"" else: "fmt\"") & body & "\""
  b.beginEdit()
  discard b.replaceText(Pos(line: p.line, col: segs[cs][0]), Pos(line: p.line, col: segs[ce][1]), lit)
  b.endEdit()
  var hasImport = false
  for l in b.lines:
    if "strformat" in l and (l.strip.startsWith("import") or l.strip.startsWith("from")): hasImport = true
  if not hasImport: b.addImport("std/strformat")
  info("→ " & truncTo(lit, 60))

proc nimEvaluate() =
  ## the value of a const expression (the selection, or the name at the cursor), as the compiler computes it
  let b = buf()
  if b.lang.mode != lmNim or b.path.len == 0 or not haveExe("nim"):
    info("Open a saved Nim file")
    return
  let (sa, se) = b.primary.range
  var expr = if sa != se and sa.line == se.line: b.getText(sa, se).strip else: b.wordAt(b.primary.head)
  proc run(ex: string) =
    if not saveForTool(b): return
    var ls = b.lines
    ls.add "static: echo \"NEDEVAL\\t\", repr(" & ex & ")"
    let tmp = parentDir(b.path) / ("ned_eval_" & $getCurrentProcessId() & ".nim")
    try: writeFile(tmp, ls.join("\n") & "\n")
    except CatchableError as e:
      error("Cannot write next to the file: " & e.msg)
      return
    projectTemps.add tmp
    let last = ls.len
    info("Evaluating " & truncTo(ex, 40) & "…")
    discard startJob(jkTool, "nim check --hints:off --warnings:off --colors:off " & quoteShell(tmp) & " 2>&1",
                     parentDir(b.path), proc(j: Job) =
      try: removeFile(tmp)
      except CatchableError: discard
      var val = ""
      var err = ""
      let tn = extractFilename(tmp)
      for l in j.output.splitLines:
        if l.startsWith("NEDEVAL\t"):
          val = l[8 .. ^1]
          break
        if "Error:" in l and err.len == 0:
          err = l[l.find("Error:") + 6 .. ^1].strip
          if tn in l and ("(" & $last & ",") notin l: err = "the file does not compile: " & err
      if val.len == 0:
        error("Cannot evaluate " & truncTo(ex, 40) & " at compile time: " & (if err.len > 0: err else: "no answer"))
        return
      if val.len > 4000: val = val[0 ..< 4000] & "…"
      let shown = val
      openDialog(ex, "= " & shown, @[("Copy", 'c'), ("OK", 'y')], proc(c: char) =
        if c == 'c':
          clipSet(shown)
          info("Copied")))
  if expr.len == 0: askText("Evaluate at compile time (a const expression)", "", proc(t: string) = run(t))
  else: run(expr)
