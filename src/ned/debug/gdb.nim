# ── the debugger: gdb's machine interface (breakpoints, stepping, call stack, variables) ──


proc nimDemangle(fn: string): string =
  ## _ZN4demo5greetE6string → demo.greet
  if not fn.startsWith("_ZN"): return fn
  var i = 3
  var parts: seq[string]
  while i < fn.len and fn[i] in {'0'..'9'}:
    var n = 0
    while i < fn.len and fn[i] in {'0'..'9'}:
      n = n * 10 + ord(fn[i]) - ord('0')
      inc i
    if i + n > fn.len: break
    parts.add fn[i ..< i + n]
    i += n
  if parts.len == 0: fn else: parts.join(".")

func nimTypeName(t: string): string =
  ## the C type gdb reports → its Nim name (NI → int, tySequence__… → seq, tyObject_Person__… → Person)
  const simple = {"NimStringV2": "string", "NI": "int", "NI64": "int64", "NI32": "int32", "NI16": "int16",
                  "NI8": "int8", "NU": "uint", "NU64": "uint64", "NU32": "uint32", "NU8": "uint8",
                  "NIM_BOOL": "bool", "NF": "float", "NF64": "float64", "NF32": "float32", "NIM_CHAR": "char"}
  var base = t.strip
  var ptrs = ""
  while base.endsWith("*"):
    ptrs.add "*"
    base = base[0 ..< base.high].strip
  for (c, n) in simple:
    if base == c: return n & ptrs
  for (pre, n) in [("tySequence__", "seq"), ("tyArray__", "array"), ("tyTuple__", "tuple"), ("tyProc__", "proc")]:
    if base.startsWith(pre): return n & ptrs
  for pre in ["tyObject_", "tyEnum_", "tyDistinct_"]:
    if base.startsWith(pre):
      let rest = base[pre.len .. ^1]
      let k = rest.find("__")
      return (if k > 0: rest[0 ..< k] else: rest) & ptrs
  t

proc nimVarName(n: string): string =
  ## who_p0 → who, x_1 → x (Nim's C names for parameters and locals)
  var k = n.len - 1
  while k > 0 and n[k] in {'0'..'9'}: dec k
  if k < n.len - 1 and k > 0 and n[k] == '_': return n[0 ..< k]
  if k < n.len - 1 and k > 1 and n[k] == 'p' and n[k - 1] == '_': return n[0 ..< k - 1]
  n

proc miValue(s: string, i: var int): JsonNode
proc miResults(s: string, i: var int, stop: char): JsonNode =
  ## key=value,key=value … up to `stop` (or the end)
  result = newJObject()
  while i < s.len and s[i] != stop:
    var key = ""
    while i < s.len and s[i] notin {'=', ',', stop}:
      key.add s[i]
      inc i
    if i < s.len and s[i] == '=':
      inc i
      result[key] = miValue(s, i)
    if i < s.len and s[i] == ',': inc i

proc miValue(s: string, i: var int): JsonNode =
  ## one value of gdb's machine interface: "c-string", {tuple}, [list]
  if i >= s.len: return newJNull()
  case s[i]
  of '"':
    inc i
    var t = ""
    while i < s.len and s[i] != '"':
      if s[i] == '\\' and i + 1 < s.len:
        inc i
        case s[i]
        of 'n': t.add '\n'
        of 't': t.add '\t'
        else: t.add s[i]
      else: t.add s[i]
      inc i
    inc i
    result = %t
  of '{':
    inc i
    result = miResults(s, i, '}')
    inc i
  of '[':
    inc i
    result = newJArray()
    while i < s.len and s[i] != ']':
      if s[i] in {'a'..'z', 'A'..'Z'}:
        # key=value inside a list: keep the value
        while i < s.len and s[i] != '=': inc i
        inc i
      result.add miValue(s, i)
      if i < s.len and s[i] == ',': inc i
    inc i
  else:
    var t = ""
    while i < s.len and s[i] notin {',', '}', ']'}:
      t.add s[i]
      inc i
    result = %t

func miQuote(s: string): string =
  ## an argument for gdb's machine interface: a C string
  "\"" & s.replace("\\", "\\\\").replace("\"", "\\\"") & "\""

proc dbgSend(cmd: string) =
  if dbgDap:
    if dbgOn: dapFromMi(cmd)
    return
  if not dbgOn or dbgProc.inFd < 0: return
  let line = cmd & "\n"
  var off = 0
  while off < line.len:
    let n = posix.write(dbgProc.inFd, unsafeAddr line[off], line.len - off)
    if n <= 0: break
    off += n

func dbgExpandable(t: string): bool =
  let b = t.strip(chars = {' ', '*'})
  b.startsWith("tyObject_") or b.startsWith("tyTuple_") or b.startsWith("tyArray_") or b.startsWith("tySequence_")

proc dbgPrettyValue(v: string): seq[string] =
  ## gdb's {a = 1, b = {len = 3, p = 0x…}} → one field per line; Nim strings and seqs shown short
  var s = v.strip
  if s.startsWith("seq(") and " = " in s: s = s[s.find(" = ") + 3 .. ^1]      # (Nim's pretty printer)
  if s.startsWith("{") and s.endsWith("}"): s = s[1 ..< s.high]
  var parts: seq[string]
  var d = 0
  var cur = ""
  var inStr = false
  for i, ch in s:
    if ch == '"' and (i == 0 or s[i - 1] != '\\'): inStr = not inStr
    if not inStr:
      if ch == '{': inc d
      elif ch == '}': dec d
      elif ch == ',' and d == 0:
        parts.add cur.strip
        cur = ""
        continue
    cur.add ch
  if cur.strip.len > 0: parts.add cur.strip
  proc shortLen(x: string): string =
    # Nim strings and seqs inside: {len = 3, p = 0x…} → ‹len 3›
    result = x
    var k = result.find("{len = ")
    while k >= 0:
      let c = result.find(", p = ", k)
      let e = result.find('}', k)
      if c < 0 or e < 0 or c > e: break
      let n = result[k + 7 ..< c]
      result = result[0 ..< k] & "‹len " & n & "›" & result[e + 1 .. ^1]
      k = result.find("{len = ", k + 1)
  let indexed = parts.len > 0 and parts[0].startsWith("{")
  for i, p in parts:
    result.add (if indexed: "[" & $i & "] " else: "") & shortLen(p)
    if result.len > 60:
      result.add "…"
      break

proc dbgPanel() =
  ## the Debug panel: state, call stack (click to go there), variables, the program's output
  var ls: seq[PanelLine]
  ls.add PanelLine(text: "  " & (if dbgState.len > 0: dbgState else: "not running") &
                   (if dbgOn: "   ·   F5 continue · F10 step over · F11 step into · Shift+F11 step out · Shift+F5 stop"
                    else: "   ·   F9 toggles a breakpoint · F5 starts debugging"), sev: 5, line: -1)
  if dbgVars.len > 0:
    ls.add PanelLine(text: "VARIABLES   (Enter on ▸ shows the fields or items)", sev: 5, line: -1)
    for (n, t, v) in dbgVars:
      let expandable = if dbgDap: dapVarRefs.getOrDefault(n) > 0 else: dbgExpandable(t)
      let open = n in dbgExpanded
      ls.add PanelLine(text: (if expandable: (if open: "▾ " else: "▸ ") else: "  ") & (if dbgDap: n else: nimVarName(n)) &
                       (if t.len > 0: ": " & (if dbgDap: t else: nimTypeName(t)) else: "") & (if v.len > 0: " = " & v else: ""),
                       path: (if expandable: "dbg:var:" & n else: ""), line: (if expandable: 0 else: -1))
      if open:
        let d = dbgDetail.getOrDefault(n, "…")
        for part in dbgPrettyValue(d): ls.add PanelLine(text: "      " & part, line: -1)
  # watches: one line when there are none
  if dbgWatches.len == 0:
    ls.add PanelLine(text: "WATCH   + add a watch expression", path: "dbg:watch", line: 0, sev: 5)
  else:
    ls.add PanelLine(text: "WATCH", sev: 5, line: -1)
    for i, w in dbgWatches:
      let v = if i < dbgWatchVals.len and dbgOn: dbgWatchVals[i] else: ""
      ls.add PanelLine(text: "  " & w & (if v.len > 0: " = " & v else: "") & "    (Enter removes it)", path: "dbg:unwatch:" & $i, line: 0)
    ls.add PanelLine(text: "  + add a watch expression", path: "dbg:watch", line: 0, sev: 3)
  if dbgWpWanted.len > 0:
    ls.add PanelLine(text: "STOP WHEN IT CHANGES", sev: 5, line: -1)
    for i, w in dbgWpWanted:
      var on = false
      for (e, _) in dbgWatchpoints:
        if e == w: on = true
      ls.add PanelLine(text: "  ● " & w & (if dbgOn and not on: "  (not set: not in scope here)" else: "") &
                       "    (Enter removes it)", path: "dbg:unwp:" & $i, line: 0)
    ls.add PanelLine(text: "  + stop when a value changes", path: "dbg:wp", line: 0, sev: 3)
  if dbgFrames.len > 0:
    ls.add PanelLine(text: "CALL STACK", sev: 5, line: -1)
    var hidden = 0
    for (fn, f, l) in dbgFrames:
      # the C runtime's frames (main, NimMain…) are not your code
      if not dbgDap and (fn in ["main", "NimMain", "NimMainInner", "PreMain", "PreMainInner"] or
         not (f.endsWith(".nim") or f.endsWith(".nims"))):
        inc hidden
        continue
      let name = if dbgDap: fn elif fn == "NimMainModule": "(top level)" else: nimDemangle(fn)
      ls.add PanelLine(text: "  " & name & "   " & extractFilename(f) & ":" & $(l + 1), path: f, line: l, sev: 3)
    if hidden > 0: ls.add PanelLine(text: "  (" & $hidden & " frames of the C runtime hidden)", line: -1)
  if dbgOut.len > 0:
    ls.add PanelLine(text: "OUTPUT", sev: 5, line: -1)
    for o in dbgOut[max(0, dbgOut.len - 300) .. ^1]: ls.add PanelLine(text: "  " & o, line: -1)
  panelStore[pkDebug] = ls
  needRender = true

proc dbgEnd(msg: string) =
  if dbgDap: dapStop()
  if dbgProc.pid > 0:
    dbgSend("-gdb-exit")
    killProc(dbgProc)
    reapSoon(dbgProc.pid)
  closeFd(dbgProc.inFd)
  closeFd(dbgProc.outFd)
  closeFd(dbgProc.errFd)
  dbgProc = Proc(pid: -1, inFd: -1, outFd: -1, errFd: -1)
  dbgOn = false
  dbgAt = ("", -1)
  dbgState = msg
  dbgFrames.setLen(0)
  dbgVars.setLen(0)
  bpNums.clear()
  dbgCondPending = ""
  dbgLogPending = ""
  dbgLogWait = 0
  dbgWatchpoints.setLen(0)
  dbgWpLookup.setLen(0)
  dbgWpSet.setLen(0)
  dapWpTried.clear()
  dbgPanel()

proc nimGdbScript(): string =
  ## tools/debug/nim-gdb.py of the Nim in use (choosenim, grabnim, a source build, a distribution)
  var cands: seq[string]
  let nim = findExe("nim")
  if nim.len > 0:
    var real = nim
    try: real = expandFilename(nim)
    except CatchableError: discard
    let root = parentDir(parentDir(real))
    cands.add root / "tools" / "debug" / "nim-gdb.py"
    cands.add root / "lib" / "nim" / "tools" / "debug" / "nim-gdb.py"
    cands.add root / "share" / "nim" / "tools" / "debug" / "nim-gdb.py"
  let lib = nimLibDir()
  if lib.len > 0:
    cands.add parentDir(lib) / "tools" / "debug" / "nim-gdb.py"
    cands.add lib / "tools" / "debug" / "nim-gdb.py"
  for c in cands:
    if fileExists(c): return c
  ""

proc dbgLaunch() =
  dbgSend(dbgLaunchCmd)                         # (the program's input is not gdb's)
  dbgSend("-exec-run")

proc dbgStrCompares(e: string): string =
  ## `name == "Ann"` (a Nim string) → `(name.len == 3 && $_streq((char*)name.p->data, "Ann"))` for gdb
  result = e
  var k = 0
  while k < result.len - 1:
    let isEq = result[k] == '=' and result[k + 1] == '='
    let isNe = result[k] == '!' and result[k + 1] == '='
    if not (isEq or isNe):
      inc k
      continue
    var q = k + 2
    while q < result.len and result[q] == ' ': inc q
    if q >= result.len or result[q] != '"':
      k += 2
      continue
    var r = q + 1
    var lit = ""
    while r < result.len and result[r] != '"':
      if result[r] == '\\' and r + 1 < result.len:
        lit.add result[r .. r + 1]
        r += 2
      else:
        lit.add result[r]
        inc r
    if r >= result.len: return
    var l = k - 1
    while l >= 0 and result[l] == ' ': dec l
    var a = l
    while a >= 0 and result[a] in IdentChars + {'.', '[', ']'}: dec a
    let lhs = result[a + 1 .. l]
    if lhs.len == 0:
      k = r + 1
      continue
    var n = 0
    var t = 0
    while t < lit.len:
      if lit[t] == '\\': t += 2
      else: inc t
      inc n
    var c = if lit.len == 0: "(" & lhs & ".len == 0)"
            else: "(" & lhs & ".len == " & $n & " && $_streq((char*)" & lhs & ".p->data, \"" & lit & "\"))"
    if isNe: c = "!" & c
    result = result[0 .. a] & c & result[r + 1 .. ^1]
    k = a + 1 + c.len

proc dbgCExprNames(cond: string): string

proc dbgCExpr(cond: string): string =
  ## `i == 3 and not done` → `i_1 == 3 && !done_1`: Nim's operators and the C names of the locals
  ## (and `name == "Ann"` compares a Nim string's characters)
  result = dbgCExprNames(cond)
  result = dbgStrCompares(result)

proc dbgCExprNames(cond: string): string =
  var i = 0
  while i < cond.len:
    let ch = cond[i]
    if ch == '"':
      # a string literal: copied as it is
      var j = i + 1
      while j < cond.len and cond[j] != '"':
        if cond[j] == '\\': inc j
        inc j
      result.add cond[i .. min(j, cond.high)]
      i = j + 1
      continue
    if ch in IdentStartChars:
      var j = i
      while j < cond.len and cond[j] in IdentChars: inc j
      let w = cond[i ..< j]
      let afterDot = result.len > 0 and result[^1] == '.'
      if afterDot: result.add w
      elif w == "and": result.add "&&"
      elif w == "or": result.add "||"
      elif w == "not": result.add "!"
      elif w == "true": result.add "1"
      elif w == "false": result.add "0"
      else:
        var c = w
        var found = false
        for (n, _, _) in dbgVars:
          if nimVarName(n) == w:
            c = n
            found = true
            break
        if not found and w in dbgGlobals:
          # a global: its C name (the one of the module stopped in, when several modules have one)
          let cs = dbgGlobals[w]
          c = cs[0]
          if dbgAt[0].len > 0:
            for x in cs:
              if ("__" & splitFile(dbgAt[0]).name & "_u") in x: c = x
        result.add c
      i = j
    else:
      result.add ch
      inc i

proc logParts(msg: string): seq[(bool, string)] =
  ## a logpoint's message: (is an expression, text) parts — "i = {i}" → ("i = "), {i}; {{ and }} are braces
  var cur = ""
  var i = 0
  while i < msg.len:
    let c = msg[i]
    if c == '{' and i + 1 < msg.len and msg[i + 1] == '{':
      cur.add '{'
      i += 2
    elif c == '}' and i + 1 < msg.len and msg[i + 1] == '}':
      cur.add '}'
      i += 2
    elif c == '{':
      let e = msg.find('}', i + 1)
      if e < 0:
        cur.add msg[i .. ^1]
        break
      if cur.len > 0: result.add (false, cur)
      cur = ""
      result.add (true, msg[i + 1 ..< e].strip)
      i = e + 1
    else:
      cur.add c
      inc i
  if cur.len > 0: result.add (false, cur)

proc dbgLogFinish() =
  ## every value is in: the message to the Debug panel's output, and on with the program
  var o = ""
  var k = 0
  for (isExpr, t) in logParts(dbgLogPending):
    if isExpr:
      o.add (if k < dbgLogVals.len and dbgLogVals[k].len > 0: dbgLogVals[k] else: "?")
      inc k
    else: o.add t
  dbgOut.add "◇ " & dbgLogAt & "  " & o
  dbgLogPending = ""
  dbgLogWait = 0
  dbgState = "● running"
  dbgSend("-exec-continue")
  dbgPanel()

proc dbgLogStart() =
  ## at a logpoint, with the frame's variables known: ask gdb for each {expression} (in the locals' C names)
  dbgLogExprs.setLen(0)
  for (isExpr, t) in logParts(dbgLogPending):
    if isExpr: dbgLogExprs.add t
  dbgLogVals = newSeq[string](dbgLogExprs.len)
  dbgLogWait = dbgLogExprs.len
  if dbgLogWait == 0:
    dbgLogFinish()
    return
  for k, x in dbgLogExprs:
    var ex = dbgCExpr(x)
    for (n, t, _) in dbgVars:
      if n == ex and t.startsWith("NimStringV2"): ex = "(char*)" & n & ".p->data"
    dbgSend($(8000 + k) & "-data-evaluate-expression " & miQuote(ex))

proc dbgLogGot() =
  dec dbgLogWait
  if dbgLogWait <= 0 and dbgLogPending.len > 0: dbgLogFinish()

proc dbgWatchStart(expr: string) =
  ## gdb: stop whenever `expr` changes — a local of the current function (and its fields) by its C name, a global
  ## looked up first (Nim names them name__module_uN)
  var first = ""
  var k = 0
  while k < expr.len and expr[k] in IdentChars: inc k
  first = expr[0 ..< k]
  var local = false
  for (n, _, _) in dbgVars:
    if nimVarName(n) == first: local = true
  if first.len == 0 or local:
    dbgWpSet.add expr
    dbgSend("9000-break-watch " & miQuote(dbgCExpr(expr)))
  else:
    dbgWpLookup.add expr
    dbgSend("9100-symbol-info-variables --name " & miQuote("^" & first & "__"))

proc dbgWpDone(): bool =
  ## a watchpoint asked for at startup is answered (set or not): true while starting (its failure is no error)
  if dbgWpStartupLeft <= 0: return false
  dec dbgWpStartupLeft
  dec dbgPendingBps
  if dbgPendingBps == 0: dbgLaunchLater = true
  true

proc dbgLine(line: string) =
  ## one line from gdb
  if line.len == 0 or line.startsWith("(gdb)"): return
  var i = 0
  while i < line.len and line[i] in {'0'..'9'}: inc i
  let token = (if i > 0: (try: parseInt(line[0 ..< i]) except ValueError: 0) else: 0)
  let c = if i < line.len: line[i] else: ' '
  case c
  of '^', '*', '=':
    let body = line[i + 1 .. ^1]
    let comma = body.find(',')
    let cls = if comma >= 0: body[0 ..< comma] else: body
    var j = (if comma >= 0: comma + 1 else: body.len)
    let r = miResults(body, j, '\0')
    if token == 7000 and c == '^' and dbgPendingBps > 0:
      dec dbgPendingBps                           # (handled again below for the breakpoint's details)
      if dbgPendingBps == 0: dbgLaunchLater = true
    if c == '^' and cls == "error" and token >= 8000 and token < 9000:
      # a logpoint's {expression} gdb could not work out: said so in the message
      let k = token - 8000
      if k < dbgLogVals.len: dbgLogVals[k] = "‹" & r{"msg"}.getStr & "›"
      dbgLogGot()
    elif c == '^' and cls == "error" and token in [9000, 9100]:
      let q = if token == 9100: dbgWpLookup else: dbgWpSet
      let x = if q.len > 0: q[0] else: "it"
      if token == 9100 and dbgWpLookup.len > 0: dbgWpLookup.delete(0)
      if token == 9000 and dbgWpSet.len > 0: dbgWpSet.delete(0)
      if dbgWpDone(): dbgOut.add "● " & x & ": watched once the program stops where it is (" & r{"msg"}.getStr & ")"
      else: error("Cannot stop when " & x & " changes: " & r{"msg"}.getStr)
    elif c == '^' and cls == "error" and token >= 6000 and token < 7000:
      if token - 6000 < dbgWatchVals.len: dbgWatchVals[token - 6000] = "‹" & r{"msg"}.getStr & "›"
    elif c == '^' and cls == "error" and token >= 5000:
      if token - 5000 < dbgVars.len:
        let m = r{"msg"}.getStr
        dbgDetail[dbgVars[token - 5000][0]] = (if "Cannot access memory" in m: "(empty or nil)" else: "‹" & m & "›")
    elif c == '^' and cls == "error" and token == 3000:
      error("Breakpoint condition `" & dbgCondShown & "`: " & r{"msg"}.getStr & " — stopped here")
    elif c == '^' and cls == "error" and token >= 1000:
      # a string's characters could not be read (optimized out, not yet set): say so in its row
      if token < 2000 and token - 1000 < dbgVars.len and dbgVars[token - 1000][2].len == 0:
        let msg = r{"msg"}.getStr
        dbgVars[token - 1000][2] = (if msg.startsWith("Cannot access memory"): "\"\"" else: "‹" & msg & "›")
    elif c == '^' and cls == "error":
      dbgOut.add "error: " & r{"msg"}.getStr
      error("gdb: " & r{"msg"}.getStr)
    elif c == '^' and cls == "done":
      if r.hasKey("stack"):
        dbgFrames.setLen(0)
        for f in r["stack"]:
          dbgFrames.add (f{"func"}.getStr, f{"fullname"}.getStr, (try: parseInt(f{"line"}.getStr) - 1 except ValueError: -1))
      if r.hasKey("variables"):
        dbgVars.setLen(0)
        for v in r["variables"]:
          let nm = v{"name"}.getStr
          # (the C compiler's temporaries are not yours: T4_, colontmp_, FR_, nimErr_)
          if (nm.len >= 3 and nm[0] == 'T' and nm[1] in Digits and nm.endsWith("_")) or
             nm.startsWith("colontmp") or nm.startsWith("FR_") or nm.startsWith("nimErr_") or
             nm.startsWith("TM_") or nm.startsWith(":tmp") or nm.startsWith("blitTmp") or "@entry" in nm:
            continue
          dbgVars.add (nm, v{"type"}.getStr, v{"value"}.getStr)
          # Nim strings: their characters
          if v{"type"}.getStr.startsWith("NimStringV2") and v{"value"}.getStr.len == 0:
            dbgSend($(1000 + dbgVars.high) & "-data-evaluate-expression " & miQuote("(char*)" & nm & ".p->data"))
          elif v{"type"}.getStr.startsWith("tySequence__") and v{"value"}.getStr.len == 0:
            dbgSend($(2000 + dbgVars.high) & "-data-evaluate-expression " & miQuote(nm & ".len"))
        if dbgCondPending.len > 0:
          dbgCondShown = dbgCondPending
          dbgSend("3000-data-evaluate-expression " & miQuote(dbgCExpr(dbgCondPending)))
          dbgCondPending = ""
        elif dbgLogPending.len > 0 and dbgLogWait == 0: dbgLogStart()
        # watch expressions, in the locals' C names (a plain string variable: its characters)
        dbgWatchVals = newSeq[string](dbgWatches.len)
        for i, w in dbgWatches:
          var ex = dbgCExpr(w)
          for (n, t, _) in dbgVars:
            if n == ex and t.startsWith("NimStringV2"): ex = "(char*)" & n & ".p->data"
          dbgSend($(6000 + i) & "-data-evaluate-expression " & miQuote(ex))
        # expanded variables: their fields or items
        for i, (n, t, _) in dbgVars:
          if n notin dbgExpanded: continue
          let tt = t.strip
          let ex = if tt.startsWith("tySequence_") and not dbgPretty: "*(" & n & ".p->data)@" & n & ".len"
                   elif tt.endsWith("*"): "*" & n
                   else: n
          dbgSend($(5000 + i) & "-data-evaluate-expression " & miQuote(ex))
      if token >= 8000 and token < 9000 and r.hasKey("value"):
        let k = token - 8000
        if k < dbgLogVals.len:
          var val = r["value"].getStr
          let q = val.find('"')
          if q > 0 and val.startsWith("0x"): val = val[q .. ^1]
          dbgLogVals[k] = val
        dbgLogGot()
      elif token == 9200:
        for grp in jitems(r{"symbols", "debug"}):
          for sy in jitems(grp{"symbols"}):
            let nm = sy{"name"}.getStr
            let k = nm.find("__")
            if k > 0 and "_u" in nm[k .. ^1] and nm[k + 2 .. ^1].find("__") < 0:
              dbgGlobals.mgetOrPut(nm[0 ..< k], @[]).add nm
      elif token == 9100:
        # the global's C name: the one in this module when there are several
        let x = if dbgWpLookup.len > 0: dbgWpLookup[0] else: ""
        if dbgWpLookup.len > 0: dbgWpLookup.delete(0)
        var k = 0
        while k < x.len and x[k] in IdentChars: inc k
        var names: seq[string]
        for grp in jitems(r{"symbols", "debug"}):
          for sy in jitems(grp{"symbols"}):
            let nm = sy{"name"}.getStr
            if nm.startsWith(x[0 ..< k] & "__"): names.add nm
        if names.len == 0:
          if dbgWpDone(): dbgOut.add "● " & x & ": set it again when the program stops where it is in scope"
          else: error("Cannot stop when " & x & " changes: it is not a variable of this function, nor a global one")
        else:
          var pick = names[0]
          if dbgAt[0].len > 0:
            let m = "__" & splitFile(dbgAt[0]).name & "_u"
            for nm in names:
              if m in nm: pick = nm
          dbgWpSet.add x
          dbgSend("9000-break-watch " & miQuote(pick & x[k .. ^1]))
      elif token == 9000 and r.hasKey("wpt"):
        let x = if dbgWpSet.len > 0: dbgWpSet[0] else: r["wpt"]{"exp"}.getStr
        if dbgWpSet.len > 0: dbgWpSet.delete(0)
        dbgWatchpoints.add (x, r["wpt"]{"number"}.getStr)
        if not dbgWpDone(): info("The program stops whenever " & x & " changes")
      elif token >= 6000 and r.hasKey("value"):
        if token - 6000 < dbgWatchVals.len:
          var val = r["value"].getStr
          let q = val.find('"')
          if q > 0 and val.startsWith("0x"): val = val[q .. ^1]
          dbgWatchVals[token - 6000] = val
      elif token >= 5000 and token < 6000 and r.hasKey("value"):
        if token - 5000 < dbgVars.len: dbgDetail[dbgVars[token - 5000][0]] = r["value"].getStr
      elif token == 3000 and r.hasKey("value"):
        let v = r["value"].getStr.strip
        if v == "0" or v == "false":
          dbgLogPending = ""
          dbgSend("-exec-continue")       # the condition is false: go on
        elif dbgLogPending.len > 0: dbgLogStart()            # a logpoint with a condition: print, go on
        else: info("Breakpoint condition is true: " & dbgCondShown)
      elif token >= 2000 and token < 3000 and r.hasKey("value") and token - 2000 < dbgVars.len:
        dbgVars[token - 2000][2] = "len " & r["value"].getStr           # a seq: its length
      elif token >= 1000 and r.hasKey("value") and token - 1000 < dbgVars.len:
        var val = r["value"].getStr
        let q = val.find('"')
        if q >= 0: val = val[q .. ^1]          # 0x55… "text" → "text"
        elif "Cannot access memory" in val: val = "\"\""     # an empty string has no characters
        dbgVars[token - 1000][2] = val
      if r.hasKey("bkpt"):
        let bk = r["bkpt"]
        let ln = (try: parseInt(bk{"line"}.getStr) - 1 except ValueError: -1)
        if ln >= 0: bpNums[(bk{"fullname"}.getStr, ln)] = bk{"number"}.getStr
        # one line can map to several places; Nim's top-level code sometimes claims the next line's
        # number too — keep only the places on the line that was asked for
        let locs = bk{"locations"}
        let orig = bk{"original-location"}.getStr
        let colon = orig.rfind(':')
        if locs != nil and locs.kind == JArray and colon > 0:
          let want = orig[colon + 1 .. ^1]
          let path = orig[0 ..< colon].strip(chars = {'-', ' '})
          for lc in locs:
            if lc{"line"}.getStr != want: dbgSend("-break-disable " & lc{"number"}.getStr)
          let wl = (try: parseInt(want) - 1 except ValueError: -1)
          if wl >= 0: bpNums[(path, wl)] = bk{"number"}.getStr
    elif c == '*' and cls == "running":
      dbgState = "● running"
      dbgAt = ("", -1)
    elif c == '*' and cls == "stopped":
      let reason = r{"reason"}.getStr
      if reason.startsWith("exited"):
        dbgEnd("program exited" & (if r{"exit-code"} != nil: " with code " & r{"exit-code"}.getStr else: ""))
        return
      let fr = r{"frame"}
      let f = if fr != nil: fr{"fullname"}.getStr else: ""
      let ln = if fr != nil: (try: parseInt(fr{"line"}.getStr) - 1 except ValueError: -1) else: -1
      dbgState = "‖ stopped" & (if reason.len > 0: " (" & reason.replace("-", " ") & ")" else: "") &
                 (if r{"signal-name"} != nil: " " & r{"signal-name"}.getStr else: "") &
                 (if f.len > 0: " at " & extractFilename(f) & ":" & $(ln + 1) & " in " & nimDemangle(fr{"func"}.getStr) else: "")
      if reason == "breakpoint-hit" and f.len > 0:
        dbgCondPending = bpCond.getOrDefault(f & ":" & $ln)
        dbgLogPending = bpLog.getOrDefault(f & ":" & $ln)
        dbgLogWait = 0
        if dbgLogPending.len > 0:
          dbgLogAt = extractFilename(f) & ":" & $(ln + 1)
          dbgState = "● running (logpoint at " & dbgLogAt & ")"
      if reason in ["watchpoint-trigger", "access-watchpoint-trigger", "read-watchpoint-trigger"]:
        let num = r{"wpt"}{"number"}.getStr
        var x = r{"wpt"}{"exp"}.getStr
        for (e, n) in dbgWatchpoints:
          if n == num: x = e
        let v = r{"value"}
        let ch = if v != nil and v{"old"} != nil: v{"old"}.getStr & " → " & v{"new"}.getStr
                 elif v != nil and v{"new"} != nil: "now " & v{"new"}.getStr else: ""
        dbgState = "‖ stopped: " & x & " changed" & (if ch.len > 0: " (" & ch & ")" else: "") &
                   (if f.len > 0: " at " & extractFilename(f) & ":" & $(ln + 1) & " in " & nimDemangle(fr{"func"}.getStr) else: "")
        dbgOut.add "● " & x & " changed" & (if ch.len > 0: ": " & ch else: "") &
                   (if f.len > 0: "  (" & extractFilename(f) & ":" & $(ln + 1) & ")" else: "")
      elif reason == "watchpoint-scope":
        let num = r{"wpnum"}.getStr
        var keep: seq[(string, string)]
        for (e, n) in dbgWatchpoints:
          if n == num: info("No longer watching " & e & ": its function returned")
          else: keep.add (e, n)
        dbgWatchpoints = keep
        dbgSend("-exec-continue")
      if f.len > 0 and ln >= 0 and fileExists(f) and dbgLogPending.len == 0:
        dbgAt = (f, ln)
        let b = openFile(f)
        if b != nil: b.centerOn(Pos(line: min(ln, b.lines.high), col: 0))
      dbgSend("-stack-list-frames")
      dbgSend("-stack-list-variables --simple-values")
  of '~', '@':
    var j = i + 1
    let t = miValue(line, j).getStr
    for l in t.strip(leading = false).splitLines:
      # (gdb's own chatter: the stop is shown above and the line in the editor)
      if c == '~' and (l.strip.len == 0 or l.startsWith("Reading symbols") or l.startsWith("[Thread ") or
         l.startsWith("Using host libthread_db") or l.startsWith("[Inferior ") or l.startsWith("Breakpoint ") or
         (l.len > 0 and l[0] in Digits and '\t' in l)):
        continue
      # a watchpoint's stop: said once, in ned's words (not gdb's four lines with the C names)
      if c == '~' and (l.startsWith("Hardware watchpoint") or l.startsWith("Hardware read watchpoint") or
         l.startsWith("Hardware access") or l.startsWith("Watchpoint ") or l.startsWith("Old value = ") or
         l.startsWith("New value = ") or l.startsWith("Value = ") or
         (l.len > 0 and l[0] in IdentStartChars and ") at " in l and l.rfind(':') > 0 and
          l[l.rfind(':') + 1 .. ^1].strip.allCharsInSet(Digits))):
        continue
      dbgOut.add l
  of '&':
    # gdb's log: only its complaints and the pretty printers loading are worth showing
    var j = i + 1
    let t = miValue(line, j).getStr.strip
    if "rror" in t or "Loading Nim" in t or "No such file" in t: dbgOut.add t
  else: dbgOut.add line                       # the program's own output
  if dbgLaunchLater:
    dbgLaunchLater = false
    dbgLaunch()
  dbgPanel()

proc dbgRead() =
  if dbgDap:
    if dapSock >= 0:                         # an adapter reached over TCP: its own output is a log
      var t2: array[16384, char]
      let n2 = posix.read(dbgProc.outFd, addr t2[0], t2.len)
      if n2 > 0:
        var chunk = newString(n2)
        copyMem(addr chunk[0], addr t2[0], n2)
        for l in chunk.strip(leading = false).splitLines: dbgOut.add l
        dbgPanel()
      elif n2 == 0: closeFd(dbgProc.outFd)
      return
    if not dapReadFd(dbgProc.outFd): dbgEnd(if dbgState.startsWith("program exited"): dbgState else: "the debug adapter ended")
    return
  var tmp: array[16384, char]
  let n = posix.read(dbgProc.outFd, addr tmp[0], tmp.len)
  if n <= 0:
    if dbgOn: dbgEnd("gdb ended")
    return
  let old = dbgRbuf.len
  dbgRbuf.setLen(old + n)
  copyMem(addr dbgRbuf[old], addr tmp[0], n)
  while true:
    let e = dbgRbuf.find('\n')
    if e < 0: break
    let line = dbgRbuf[0 ..< e].strip(leading = false, chars = {'\r'})
    dbgRbuf = dbgRbuf[e + 1 .. ^1]
    dbgLine(line)

proc toggleBreakpoint() =
  let b = buf()
  if b.path.len == 0:
    info("Save the file first: breakpoints belong to files")
    return
  let l = b.primary.head.line
  var set = breakpoints.getOrDefault(b.path)
  if l in set:
    set.excl l
    bpCond.del(b.path & ":" & $l)
    let wasLog = (b.path & ":" & $l) in bpLog
    bpLog.del(b.path & ":" & $l)
    if dbgOn and (b.path, l) in bpNums: dbgSend("-break-delete " & bpNums[(b.path, l)])
    info((if wasLog: "Logpoint" else: "Breakpoint") & " removed (line " & $(l + 1) & ")")
  else:
    set.incl l
    if dbgOn: dbgSend("-break-insert -f " & miQuote(b.path & ":" & $(l + 1)))
    info("Breakpoint on line " & $(l + 1) & " — F5 debugs")
  breakpoints[b.path] = set
  if dbgOn and dbgDap: dapSetBreakpoints(b.path)
  needRender = true

func isNimProgram(b: Buffer): bool =
  ## top-level code or `when isMainModule`: a program (or a test), not only declarations
  for l in b.lines:
    if l.len == 0 or l[0] in {' ', '\t', '#', '{'}: continue
    var w = ""
    for ch in l:
      if ch in IdentChars: w.add ch
      else: break
    if w == "when":
      if "isMainModule" in l: return true
    elif w notin ["proc", "func", "method", "iterator", "converter", "template", "macro", "type", "const", "let",
                  "var", "import", "from", "include", "export", "static", "discard", "using", "mixin", "bind"]:
      return true
  false

proc dbgStart() =
  ## build with debug information, start gdb, set the breakpoints, run
  let b = buf()
  let runTo = dbgRunTo
  dbgRunTo = ""
  let args = dbgArgs
  dbgArgs = ""
  if dbgOn:
    dbgSend("-exec-continue")
    return
  if b.path.len == 0:
    info("Open the file to debug (F9 sets breakpoints)")
    return
  if b.lang.mode != lmNim:
    # other languages: a Debug Adapter Protocol program (debugpy, gdb -i dap, lldb-dap, delve …)
    if runTo.len > 0:
      let c = runTo.rfind(':')
      if c > 0: dapTempBp = (runTo[0 ..< c], (try: parseInt(runTo[c + 1 .. ^1]) - 1 except ValueError: -1))
    dapStart(b)
    return
  if not haveExe("gdb"):
    error("gdb is not installed (Termux: pkg install gdb · Debian/Ubuntu: apt install gdb)")
    return
  discard saveAll()
  # the file itself when it is a program (top-level code, `when isMainModule`), as F5 runs it; a library
  # module's breakpoints are reached through the project's main file
  let main = if isNimProgram(b): b.path else: nimProjectFile(b)
  let exe = privDir() / ("ned_debug_" & splitFile(main).name)
  let cmd = "nim c --debugger:native --opt:none --gcc.options.debug:-g3 --clang.options.debug:-g3 --hints:off " & (if cfgNimFlags.len > 0: cfgNimFlags & " " else: "") &
            "-o:" & quoteShell(exe) & " " & quoteShell(main)
  dbgState = "building " & extractFilename(main) & " with debug information…"
  dbgOut = @["$ " & cmd]
  dbgFrames.setLen(0)
  dbgVars.setLen(0)
  setPanel(pkDebug)
  dbgPanel()
  discard startJob(jkTool, cmd, parentDir(main), proc(j: Job) =
    if j.code != 0:
      for l in j.output.splitLines: dbgOut.add l
      dbgState = "the build failed"
      dbgPanel()
      return
    try:
      dbgProc = spawnProc(@["gdb", "--interpreter=mi3", "-q", "-nx", exe], parentDir(main), siPipe, erMerge)
    except OSError as e:
      dbgState = "could not start gdb: " & e.msg
      dbgPanel()
      return
    dbgOn = true
    dbgRbuf = ""
    dbgState = "starting…"
    # Nim's own gdb pretty printers (strings as text, seqs as items) when the toolchain has them
    dbgPretty = false
    let py = nimGdbScript()
    if py.len > 0:
      dbgSend("-interpreter-exec console " & miQuote("source " & py))
      dbgSend("-enable-pretty-printing")
      dbgPretty = true
    # the program's globals, for watches, conditions and logpoints that name one
    dbgGlobals.clear()
    dbgSend("9200-symbol-info-variables --name " & miQuote("__"))
    # the program starts once gdb has answered for every breakpoint (stray places get disabled first)
    dbgLaunchCmd = "-exec-arguments " & (if args.len > 0: quoteShell(args) & " " else: "") & "< /dev/null"
    dbgPendingBps = 0
    for f, ls in breakpoints:
      for l in ls:
        dbgSend("7000-break-insert -f " & miQuote(f & ":" & $(l + 1)))
        inc dbgPendingBps
    if runTo.len > 0:
      dbgSend("7000-break-insert -t -f " & miQuote(runTo))
      inc dbgPendingBps
    # "stop when it changes" on globals: set before the program runs (the locals' wait until it stops there)
    dbgWpStartupLeft = 0
    for w in dbgWpWanted:
      dbgWatchStart(w)
      inc dbgPendingBps
      inc dbgWpStartupLeft
    if dbgPendingBps == 0: dbgLaunch()
    dbgPanel())

proc dbgCmd(cmd: string) =
  if not dbgOn:
    info("Not debugging — F5 starts (with breakpoints from F9)")
    return
  dbgSend(cmd)

proc dbgPanelAction(key: string) =
  ## Enter / click on a Debug panel line: expand a variable, add or remove a watch
  if key.startsWith("dbg:var:"):
    let n = key[8 .. ^1]
    if n in dbgExpanded: dbgExpanded.excl n
    else:
      dbgExpanded.incl n
      if dbgOn: dbgSend("-stack-list-variables --simple-values")
  elif key == "dbg:wp":
    cmdWatchpoint()
    return
  elif key.startsWith("dbg:unwp:"):
    let i = (try: parseInt(key[9 .. ^1]) except ValueError: -1)
    if i >= 0 and i < dbgWpWanted.len: dbgRemoveWatchpoint(dbgWpWanted[i])
  elif key == "dbg:watch":
    let b = buf()
    let (a, e) = b.primary.range
    openPrompt(pDbgWatch, "Watch (a Nim expression, e.g. total * 2 or p.name)",
               (if a != e and a.line == e.line: b.getText(a, e) else: b.wordAt(b.primary.head)))
    return
  elif key.startsWith("dbg:unwatch:"):
    let i = (try: parseInt(key[12 .. ^1]) except ValueError: -1)
    if i >= 0 and i < dbgWatches.len:
      info("Stopped watching " & dbgWatches[i])
      dbgWatches.delete(i)
  dbgPanel()

proc debugTestAtCursor() =
  ## the unittest `test "…"` around the cursor, alone, under the debugger (a breakpoint at its first line
  ## when the file has none)
  let b = buf()
  if b.lang.mode != lmNim or b.path.len == 0: return
  var l = b.primary.head.line
  var name = ""
  while l >= 0:
    name = quotedName(b.lines[l].strip, "test ")
    if name.len > 0: break
    dec l
  if name.len == 0:
    info("Put the cursor in a test \"…\": block")
    return
  if dbgOn: dbgEnd("stopped")
  if breakpoints.getOrDefault(b.path).len == 0 and l + 1 < b.lines.len:
    breakpoints[b.path] = toHashSet([l + 1])
  dbgArgs = name
  dbgStart()

proc dbgRunToCursor() =
  ## run (or continue) to the cursor's line, with a one-time breakpoint
  let b = buf()
  if b.path.len == 0:
    info("Open the file to debug")
    return
  let loc = b.path & ":" & $(b.primary.head.line + 1)
  if dbgOn:
    dbgSend("-break-insert -t -f " & miQuote(loc))
    dbgSend("-exec-continue")
  else:
    dbgRunTo = loc
    dbgStart()

proc setBpCond(cond: string) =
  ## a condition for the breakpoint on the cursor's line (sets the breakpoint if needed; empty removes it)
  let b = buf()
  if b.path.len == 0: return
  let l = b.primary.head.line
  let key = b.path & ":" & $l
  if cond.strip.len == 0:
    bpCond.del key
    info("Breakpoint condition removed")
  else:
    bpCond[key] = cond.strip
    if l notin breakpoints.getOrDefault(b.path): toggleBreakpoint()
    info("Line " & $(l + 1) & " stops only when " & cond.strip)
  if dbgOn and dbgDap: dapSetBreakpoints(b.path)
  needRender = true

proc cmdBpCond() =
  let b = buf()
  if b.path.len == 0:
    info("Open a saved file first")
    return
  openPrompt(pBpCond, "Stop on line " & $(b.primary.head.line + 1) & " only when (a condition in the file's language, e.g. i == 3)",
             bpCond.getOrDefault(b.path & ":" & $b.primary.head.line))

proc setBpLog(msg: string) =
  ## a logpoint on the cursor's line: the message is printed each time the program passes, with the values of
  ## its {expressions}; the program does not stop (empty: the logpoint goes, and its breakpoint)
  let b = buf()
  if b.path.len == 0: return
  let l = b.primary.head.line
  let key = b.path & ":" & $l
  if msg.strip.len == 0:
    if key in bpLog:
      bpLog.del key
      if l in breakpoints.getOrDefault(b.path): toggleBreakpoint()
      info("Logpoint removed")
  else:
    bpLog[key] = msg.strip
    if l notin breakpoints.getOrDefault(b.path): toggleBreakpoint()
    info("Line " & $(l + 1) & " prints “" & msg.strip & "” each time it runs (in the Debug panel), without stopping")
  if dbgOn and dbgDap: dapSetBreakpoints(b.path)
  needRender = true

proc cmdBpLog() =
  let b = buf()
  if b.path.len == 0:
    info("Open a saved file first")
    return
  openPrompt(pBpLog, "Log on line " & $(b.primary.head.line + 1) & " without stopping — {expressions} show values, e.g. i = {i}, name = {p.name}",
             bpLog.getOrDefault(b.path & ":" & $b.primary.head.line))

proc dapSetDataBreakpoints()
proc dapRequest(cmd: string, args: JsonNode, cb: DapCb = nil)

proc dbgAddWatchpoint(expr: string) =
  ## stop whenever `expr` changes (a hardware watchpoint in gdb; a data breakpoint through DAP)
  if expr in dbgWpWanted and not dbgOn:
    info("Already watching " & expr)
    return
  if dbgOn and dbgDap:
    if dapCaps == nil or not dapCaps{"supportsDataBreakpoints"}.getBool(false):
      error("This debugger cannot stop when a value changes")
      return
    let x = expr
    dapRequest("dataBreakpointInfo", %*{"name": x, "frameId": dapFrameId}, proc(body: JsonNode, ok: bool, msg: string) =
      let id = if body != nil: body{"dataId"} else: nil
      if not ok or id == nil or id.kind == JNull:
        error("Cannot stop when " & x & " changes" & (if body != nil and body{"description"}.getStr.len > 0:
                                                        ": " & body{"description"}.getStr elif msg.len > 0: ": " & msg else: ""))
        return
      if x notin dbgWpWanted: dbgWpWanted.add x
      dbgWatchpoints.add (x, (if id.kind == JString: id.getStr else: $id))
      dapSetDataBreakpoints()
      info("The program stops whenever " & x & " changes")
      dbgPanel())
    return
  if expr notin dbgWpWanted: dbgWpWanted.add expr
  if dbgOn: dbgWatchStart(expr)
  else: info("The program will stop whenever " & expr & " changes — F5 starts debugging")
  dbgPanel()

proc dbgRemoveWatchpoint(expr: string) =
  var keep: seq[(string, string)]
  for (e, n) in dbgWatchpoints:
    if e == expr:
      if dbgOn and not dbgDap: dbgSend("-break-delete " & n)
    else: keep.add (e, n)
  dbgWatchpoints = keep
  let i = dbgWpWanted.find(expr)
  if i >= 0: dbgWpWanted.delete(i)
  if dbgOn and dbgDap: dapSetDataBreakpoints()
  info("No longer stopping when " & expr & " changes")
  dbgPanel()

proc cmdWatchpoint() =
  let b = buf()
  let (a, e) = b.primary.range
  openPrompt(pDbgWp, "Stop whenever this changes (a variable, or a field: p.count)",
             (if a != e and a.line == e.line: b.getText(a, e) else: b.wordAt(b.primary.head)))

proc dbgValueOf(name: string): string =
  ## while stopped: a local variable's value, for hover
  if not dbgOn: return ""
  for (n, t, v) in dbgVars:
    if (if dbgDap: n else: nimVarName(n)) == name:
      return name & (if t.len > 0: ": " & (if dbgDap: t else: nimTypeName(t)) else: "") & (if v.len > 0: " = " & v else: "")
  ""
