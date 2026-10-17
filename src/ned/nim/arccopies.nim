## ARC/ORC's copies, from `nim c --expandArc:name …`: where in the source each `=copy` and `=dup` the compiler
## inserted stands. The expanded code carries no line numbers, so each copy is found by what it copies (and what
## it copies into, or the call it is passed to) among the routine's lines, in the order the code runs.

import std/[strutils, sets]

type
  ArcRoutine* = object
    name*: string
    line*, endLine*: int          # 0-based: the routine's first and last line
    params*: seq[string]          # its parameters that are not `sink` (borrowed: copied to be kept)

  ArcKind* = enum
    akAssign                      # =copy: kept in a variable, a field, the result
    akSink                        # =dup: handed to a `sink` parameter (the call's)
    akIterArg                     # =copy: what a `for` loops over, bound to an inlined iterator's parameter
    akLoopVar                     # =copy: each value a `for` gets from its iterator (it yields copies)
    akCapture                     # =copy: captured by a closure, into its environment

  ArcCopy* = object
    line*, col*, ecol*: int       # the copied expression in the source (0-based; ecol: just after it)
    src*, dest*, callee*: string  # what is copied, into what (=copy), or the call that takes it (=dup)
    kind*: ArcKind
    param*: bool                  # it is one of the routine's (borrowed) parameters, or part of one
    loopView*: bool               # it is a loop variable (a view of an element, not its own), or part of one

const ArcIdent = {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}

proc arcBlocks*(output: string): seq[(string, seq[string])] =
  ## the expanded routines in the compiler's output: (name, lines)
  var cur = -1
  for l in output.splitLines:
    if l.startsWith("--expandArc: "):
      result.add (l[13 .. ^1].strip, newSeq[string]())
      cur = result.high
    elif l.startsWith("-- end of expandArc"):
      cur = -1
    elif cur >= 0:
      result[cur][1].add l

proc matchClose(s: string, open: int): int =
  var d = 0
  var inStr = false
  for i in open ..< s.len:
    let c = s[i]
    if inStr:
      if c == '\\': continue
      if c == '"': inStr = false
    elif c == '"': inStr = true
    elif c in {'(', '['}: inc d
    elif c in {')', ']'}:
      dec d
      if d == 0: return i
  -1

proc splitArgs(s: string): seq[string] =
  var d = 0
  var cur = ""
  var inStr = false
  for c in s:
    if inStr:
      if c == '"': inStr = false
    elif c == '"': inStr = true
    elif c in {'(', '['}: inc d
    elif c in {')', ']'}: dec d
    if c == ',' and d == 0 and not inStr:
      result.add cur.strip
      cur = ""
    else: cur.add c
  if cur.strip.len > 0: result.add cur.strip

proc arcNorm*(e: string): string =
  ## an expression of the expanded code as the source writes it: a_cursor → a, result_1 → result, x[] → x
  ## (a dereference the compiler made visible)
  var i = 0
  while i < e.len:
    if e[i] in ArcIdent and (i == 0 or e[i - 1] notin ArcIdent):
      var j = i
      while j < e.len and e[j] in ArcIdent: inc j
      var w = e[i ..< j]
      if w.endsWith("_cursor") and w.len > 7: w.setLen(w.len - 7)
      let u = w.rfind('_')
      if u > 0 and u < w.high and w[u + 1 .. ^1].allCharsInSet(Digits) and w[0] notin Digits: w.setLen(u)
      result.add w
      i = j
    elif e[i] == '[' and i + 1 < e.len and e[i + 1] == ']':
      i += 2
    else:
      result.add e[i]
      inc i

proc baseName(e: string): string =
  var j = 0
  while j < e.len and e[j] in ArcIdent: inc j
  e[0 ..< j]

type ArcEvent = object
  src, dest, callee: string
  dup: bool

proc arcEvents(body: seq[string]): seq[ArcEvent] =
  ## the copies in one expanded routine, in order
  for i, l in body:
    var k = 0
    while k < l.len:
      let a = l.find("`=", k)
      if a < 0: break
      let b = l.find('`', a + 1)
      if b < 0: break
      k = b + 1
      var op = l[a + 1 ..< b]
      let u = op.find('_')
      if u > 0: op.setLen(u)                       # =copy_1, =dup_2: another type's hook
      if op notin ["=copy", "=dup"] or b + 1 >= l.len or l[b + 1] != '(': continue
      let e = matchClose(l, b + 1)
      if e < 0: continue
      let args = splitArgs(l[b + 2 ..< e])
      if op == "=copy":
        if args.len >= 2: result.add ArcEvent(src: args[1], dest: args[0])
        continue
      if args.len == 0: continue
      # =dup: for the call it is made for — written around it (`f(=dup(x))`) or, hoisted into a temporary, the
      # line above that opens it (`add(names):`, `keep:`)
      var callee = ""
      var d = 0
      var q = a - 1
      while q >= 0:
        if l[q] in {')', ']'}: inc d
        elif l[q] in {'(', '['}:
          if d == 0:
            var s = q
            while s > 0 and l[s - 1] in ArcIdent: dec s
            callee = l[s ..< q]
            break
          dec d
        dec q
      if callee.len == 0:
        let ind = l.len - l.strip(trailing = false).len
        for j in countdown(i - 1, max(0, i - 8)):
          let pl = body[j]
          let t = pl.strip
          if t.len == 0: continue
          if pl.len - pl.strip(trailing = false).len < ind:
            if t.endsWith(":") or t.endsWith("(") or t.endsWith("[") or t.endsWith(","):
              var s = 0
              while s < t.len and (t[s] in ArcIdent or t[s] == '.'): inc s
              callee = t[0 ..< s]
              let dot = callee.rfind('.')
              if dot >= 0: callee = callee[dot + 1 .. ^1]
            break
      result.add ArcEvent(src: args[0], callee: callee, dup: true)

proc codeOf(line: string): string =
  ## the line without its comment, its strings blanked (a name in them is no use of it)
  result = line
  var inStr = false
  var i = 0
  while i < result.len:
    let c = result[i]
    if inStr:
      if c == '\\' and i + 1 < result.len:
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      if c == '"': inStr = false
      else: result[i] = ' '
    elif c == '"': inStr = true
    elif c == '\'' and i + 2 < result.len and result[i + 2] == '\'':
      result[i + 1] = ' '
      i += 3
      continue
    elif c == '#':
      result.setLen(i)
      break
    inc i

proc findExpr(code, w: string, start: int): int =
  ## w in code from start, standing on its own (`a.b` is in `x = a.b`, not in `xa.b`, `y.a.b`, `a.bc`, `a.b.c` or
  ## `a.b[0]`: a part of it is another value)
  var k = start
  while k <= code.len - w.len:
    let i = code.find(w, k)
    if i < 0: return -1
    let okL = i == 0 or (code[i - 1] notin ArcIdent and code[i - 1] != '.')
    let e = i + w.len
    let okR = e >= code.len or (code[e] notin ArcIdent and code[e] != '[' and
                                not (code[e] == '.' and e + 1 < code.len and code[e + 1] in ArcIdent))
    if okL and okR: return i
    k = i + 1
  -1

proc isTemp(e: string): bool =
  ## an inlined iterator's parameter, bound to what the loop goes over (:tmp, :tmp_3 — not a =dup's :tmpD)
  e == ":tmp" or (e.startsWith(":tmp_") and e[5 .. ^1].allCharsInSet(Digits))

proc hasWord(code, w: string): bool =
  ## the name w in code (`t` in `t.title = …`, `add` in `xs.add x`)
  var k = 0
  while true:
    let i = code.find(w, k)
    if i < 0: return false
    if (i == 0 or code[i - 1] notin ArcIdent) and (i + w.len >= code.len or code[i + w.len] notin ArcIdent): return true
    k = i + 1

proc place(evs: seq[ArcEvent], lines: openArray[string], r: ArcRoutine): seq[ArcCopy] =
  var at = r.line
  var taken: HashSet[(int, int)]
  let last = min(r.endLine, lines.high)
  # the header — its parameters, their defaults — may go on over several lines, up to the `=` that ends it
  var hdrEnd = r.line
  for l in r.line .. min(r.line + 12, last):
    if codeOf(lines[l]).strip.endsWith("="):
      hdrEnd = l
      break
  # the loop variables (`for k, v in …`): what is copied into one comes from the iterator's own code
  var loopVars: HashSet[string]
  for l in r.line .. last:
    let t = codeOf(lines[l]).strip
    if t.startsWith("for "):
      let i = t.find(" in ")
      if i > 4:
        for v in t[4 ..< i].split(','): loopVars.incl v.strip(chars = {' ', '(', ')'})
  for ev in evs:
    var src = arcNorm(ev.src)
    var dest = if ev.dest.startsWith(":"): "" else: arcNorm(ev.dest)
    var kind = if ev.dup: akSink elif isTemp(ev.dest): akIterArg elif ev.dest.startsWith(":env"): akCapture
               else: akAssign
    if not ev.dup and dest.len > 0 and dest in loopVars:
      # a loop variable given a copy of what the iterator yields: marked on the variable, in its `for`
      kind = akLoopVar
      src = dest
    # temporaries, closures' environments, literals and call results are no copy of a name in the source
    if src.len == 0 or src[0] notin ArcIdent or src[0] in Digits or ':' in src or '(' in src or '"' in src:
      continue
    var found = false
    for pass in 0 .. 1:
      let (a, e) = if pass == 0: (at, last) else: (r.line, at - 1)
      for l in a .. e:
        var code = codeOf(lines[l])
        var from0 = 0
        if l < hdrEnd: continue
        if l == hdrEnd:
          # the header names the parameters: only what follows its `=` (a one-line routine)
          let eq = code.rfind(" =")
          if eq < 0: continue
          from0 = eq + 2
        let t = code.strip
        var c = -1
        case kind
        of akIterArg, akLoopVar:
          if not t.startsWith("for "): continue
          let inAt = code.find(" in ")
          if inAt < 0: continue
          c = if kind == akLoopVar: findExpr(code[0 ..< inAt], src, 0) else: findExpr(code, src, inAt + 4)
        of akCapture:
          # the closure is made where it is declared: `proc grp(…) =`, `proc (…) =`, `(x) => …`
          if l <= hdrEnd: continue
          if not (t.startsWith("proc") or t.startsWith("func") or "= proc" in code or "=>" in code or " do" in code):
            continue
          let k = max(code.find("proc"), max(code.find("func"), code.find("=>")))
          if k < 0: continue
          var n0 = k + 4
          while n0 < code.len and code[n0] == ' ': inc n0
          var n1 = n0
          while n1 < code.len and code[n1] in ArcIdent: inc n1
          if (l, k) in taken: continue
          taken.incl (l, k)
          result.add ArcCopy(line: l, col: (if n1 > n0: n0 else: k), ecol: (if n1 > n0: n1 else: k + 4), src: src,
                             kind: akCapture, param: baseName(src) in r.params)
          at = l
          found = true
          break
        else:
          c = findExpr(code, src, from0)
        while c >= 0 and (l, c) in taken: c = findExpr(code, src, c + 1)
        if c < 0: continue
        if kind == akAssign and dest.len > 0 and dest != "result" and not hasWord(code, baseName(dest)): continue
        if kind == akSink and ev.callee.len > 0 and ev.callee[0] in ArcIdent and not hasWord(code, ev.callee): continue
        taken.incl (l, c)
        result.add ArcCopy(line: l, col: c, ecol: c + src.len, src: src, dest: dest, callee: ev.callee,
                           kind: kind, param: baseName(src) in r.params,
                           loopView: kind != akLoopVar and baseName(src) in loopVars)
        at = l
        found = true
        break
      if found: break

proc eqName(a, b: string): bool =
  ## Nim's rule: the first letter as written, the rest without case or underscores
  if a.len == 0 or b.len == 0 or a[0] != b[0]: return false
  a[1 .. ^1].replace("_", "").toLowerAscii == b[1 .. ^1].replace("_", "").toLowerAscii

proc arcCopies*(output: string, lines: openArray[string], routines: openArray[ArcRoutine]): seq[ArcCopy] =
  ## the copies the compiler's --expandArc output shows, placed in the source; a generic routine's
  ## instantiations and overloads land on the routine whose lines fit best, each place once
  var seen: HashSet[(int, int)]
  for (name, body) in arcBlocks(output):
    let evs = arcEvents(body)
    if evs.len == 0: continue
    var best: seq[ArcCopy]
    for r in routines:
      if not eqName(r.name, name) or r.line < 0 or r.line >= lines.len: continue
      let got = place(evs, lines, r)
      if got.len > best.len: best = got
      if best.len == evs.len: break
    for c in best:
      if (c.line, c.col) notin seen:
        seen.incl (c.line, c.col)
        result.add c
