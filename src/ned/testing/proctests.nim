# ── Tests for this proc, from running it: the proc called with arguments its parameters' types suggest (0, 1, 42;
#    "", "a"; an enum's first and last value …), what it returns written down as std/unittest checks — an exception
#    as `expect` — in tests/t<module>.nim; then the tests run with coverage. Tests of what it does now: read the
#    values, a wrong one is a bug the tests would keep ──

const PtBasic = ["int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64", "byte",
                 "Natural", "Positive", "float", "float32", "float64", "string", "char", "bool", "cstring"]

func ptBare(t: string): string =
  ## a parameter's type without var / sink / lent / static
  result = t.strip
  for w in ["var ", "sink ", "lent ", "static "]:
    if result.startsWith(w): result = result[w.len .. ^1].strip

func ptInner(t, outer: string): string =
  ## seq[int] → int (for outer "seq")
  if t.startsWith(outer & "[") and t.endsWith("]"): t[outer.len + 1 ..< t.high].strip else: ""

proc ptSamples(t0: string, f: NxFile, generics: seq[string], depth = 0): seq[string] =
  ## arguments for a parameter of type t: a few of them, from the simple to the less so ("" when ned cannot make one)
  var t = ptBare(t0)
  if t in generics or t in ["auto", "any", "SomeNumber", "SomeInteger", "SomeSignedInt", "Ordinal"]: t = "int"
  if t == "SomeFloat": t = "float"
  case t
  of "int", "int8", "int16", "int32", "int64": return @["0", "1", "-1", "42"]
  of "uint", "uint8", "uint16", "uint32", "uint64", "byte", "Natural": return @["0", "1", "42"]
  of "Positive": return @["1", "2", "42"]
  of "float", "float32", "float64": return @["0.0", "1.5", "-2.25"]
  of "string": return @["\"\"", "\"a\"", "\"hello world\""]
  of "cstring": return @["cstring\"\"", "cstring\"a\""]
  of "char": return @["'a'", "'Z'", "' '"]
  of "bool": return @["true", "false"]
  else: discard
  if depth < 2:
    for outer in ["seq", "openArray", "varargs"]:
      let inner = ptInner(t, outer)
      if inner.len > 0:
        let xs = ptSamples(inner, f, generics, depth + 1)
        if xs.len == 0: return @[]
        let it = if inner in generics: "int" else: inner
        return @["newSeq[" & it & "]()", "@[" & xs[0] & "]", "@[" & xs[min(1, xs.high)] & ", " & xs[0] & "]"]
  if f == nil: return @[]
  # a type of the module: an enum's first and last values; a value object or tuple: its default
  for s in f.syms:
    if s.kind == nxType and s.name == t:
      let d = s.typ.strip
      if d.startsWith("enum"):
        var vals: seq[string]
        for v in f.syms:
          if v.kind == nxEnumVal and v.owner == t: vals.add v.name
        if vals.len > 0: return (if vals.len == 1: @[vals[0]] else: @[vals[0], vals[^1]])
      if d.startsWith("object") or d.startsWith("tuple") or d.startsWith("distinct"): return @["default(" & t & ")"]
      return @[]                                      # (a ref, a ptr: nothing ned can make that would not crash)
  @[]

func ptBasicRet(t: string): bool =
  ## a return type whose value repr writes as a literal == compares with
  let x = t.strip
  if x in PtBasic: return true
  for outer in ["seq", "array"]:
    if x.startsWith(outer & "[") and x.endsWith("]"):
      let inner = x[outer.len + 1 ..< x.high]
      let k = inner.rfind(',')
      return ptBasicRet(if k >= 0: inner[k + 1 .. ^1] else: inner)
  false

proc ptTestFile(b: Buffer): (string, string) =
  ## (the test file, the module as the test imports it): tests/t<module>.nim beside the .nimble (else the project's)
  let nf = findNimbleFile(parentDir(b.path))
  let dir = (if nf.len > 0: parentDir(nf) else: (if rootDir.len > 1: rootDir else: parentDir(b.path))) / "tests"
  let name = splitFile(b.path).name
  (dir / ("t" & name & ".nim"), relativePath(b.path.changeFileExt(""), dir).replace('\\', '/'))

proc cmdWriteProcTests() =
  ## Nim: tests for the proc at the cursor, written from what it returns now
  let b = buf()
  if b.lang.mode != lmNim or not b.path.endsWith(".nim"):
    info("Open the Nim module whose proc you want tests for")
    return
  if not haveExe("nim"):
    error("nim is not installed")
    return
  if not saveForTool(b): return
  let f = nxFileFor(b)
  if f == nil: return
  let ri = nxEnclosing(f, b.primary.head.line)
  if ri < 0 or f.syms[ri].kind notin {nxProc, nxFunc, nxConverter}:
    info("Put the cursor in a proc or func (its name or its body)")
    return
  let s = f.syms[ri]
  var generics: seq[string]
  if s.generics.len > 2:
    for g in s.generics[1 ..< s.generics.high].split({',', ';'}):
      let n = g.split(':')[0].strip
      if n.len > 0: generics.add n
  # each parameter's arguments; a case takes the k-th of each (the shorter lists over again)
  var samples: seq[seq[string]]
  for p in s.params:
    let xs = ptSamples(p.typ, f, generics)
    if xs.len == 0:
      if p.default.len > 0:
        samples.add @[p.default]
        continue
      info(s.name & ": ned cannot make a " & p.name & ": " & p.typ & " — AI: write tests can, or write that test " &
           "by hand")
      return
    samples.add xs
  var n = 1
  for xs in samples: n = max(n, xs.len)
  n = min(n, 5)
  let void = s.ret.strip.len == 0 or s.ret.strip == "void"
  let isVar = block:
    var r: seq[bool]
    for p in s.params: r.add p.typ.strip.startsWith("var ")
    r
  # the cases' code: run in a module next to this one (its imports resolve as they do for it) that includes it —
  # its private procs too, its `when isMainModule` not run
  var cases = ""
  var calls: seq[string]
  for k in 0 ..< n:
    var args: seq[string]
    var pre = ""
    for pi, xs in samples:
      let v = xs[k mod xs.len]
      if isVar[pi]:
        pre.add "    var a" & $pi & " = " & v & "\n"
        args.add "a" & $pi
      else: args.add v
    let call = s.name & "(" & args.join(", ") & ")"
    var shown = s.name & "("
    for pi, xs in samples:
      if pi > 0: shown.add ", "
      shown.add xs[k mod xs.len]
    shown.add ")"
    calls.add shown
    cases.add "  block:\n" & pre & "    try:\n"
    if void: cases.add "      " & call & "\n      echo \"\\x1eR" & $k & "\\t\"\n"
    else:
      cases.add "      let v = " & call & "\n" &
                "      when compiles(repr(v)): echo \"\\x1eR" & $k & "\\t\", repr(v)\n" &
                "      when compiles($v): echo \"\\x1eS" & $k & "\\t\", escape($v)\n"
    for pi in 0 ..< samples.len:
      if isVar[pi]: cases.add "      echo \"\\x1eV" & $k & "\\t" & $pi & "\\t\", repr(a" & $pi & ")\n"
    cases.add "    except Exception as e:\n      echo \"\\x1eX" & $k & "\\t\", $e.name\n"
  let modDir = parentDir(b.path)
  let helper = modDir / ("nedtests" & $getCurrentProcessId() & ".nim")   # (a module's name: a Nim identifier)
  let tmp = privTmp("proctests")
  try:
    createDir(tmp)
    writeFile(helper, "# made by ned for a moment (Nim: write tests for this proc): removed when it has run\n" &
              "include \"" & extractFilename(b.path) & "\"\nimport std/strutils\n" &
              "proc nedRunCases*() =\n" & cases)
    writeFile(tmp / "run.nim", "import \"" & helper.changeFileExt("").replace('\\', '/') & "\"\nnedRunCases()\n")
  except CatchableError as e:
    error("Could not write the run: " & e.msg)
    return
  let (testPath, spec) = ptTestFile(b)
  let name = s.name
  let exported = s.exported
  info("Running " & name & " with " & $n & " sets of arguments…")
  let cmd = "nim c -r --hints:off --warnings:off --nimcache:" & quoteShell(tmp / "nc") & " -o:" &
            quoteShell(tmp / "run" & ExeDot) & " " & quoteShell(tmp / "run.nim")
  # (a case that never ends: stopped after 20 s — the cases before it are kept)
  discard startJob(jkRun, (if haveExe("timeout"): "timeout 20 " else: "") & cmd & " 2>&1", modDir, proc(j: Job) =
    try: removeFile(helper)
    except CatchableError: discard
    try: removeDir(tmp)
    except CatchableError: discard
    var reprs, strs, raised: Table[int, string]
    var vars: Table[(int, int), string]
    for raw in j.output.splitLines:
      let l = stripAnsi(raw)
      if l.len < 3 or l[0] != '\x1e': continue
      let tab = l.find('\t')
      if tab < 0: continue
      let k = (try: parseInt(l[2 ..< tab]) except ValueError: -1)
      if k < 0: continue
      let v = l[tab + 1 .. ^1]
      case l[1]
      of 'R': reprs[k] = v
      of 'S': strs[k] = v
      of 'X': raised[k] = v
      of 'V':
        let t2 = v.find('\t')
        if t2 > 0: vars[(k, (try: parseInt(v[0 ..< t2]) except ValueError: -1))] = v[t2 + 1 .. ^1]
      else: discard
    if reprs.len + raised.len == 0:
      var why = ""
      for l in j.output.splitLines:
        if "Error:" in l:
          why = l.strip
          break
      error("Could not run " & name & (if why.len > 0: ": " & why else: " (it did not end within 20 s?)"))
      return
    # the suite: a test for each case — its value checked, its exception expected
    var suite = "\nsuite \"" & name & "\":\n"
    var written = 0
    for k in 0 ..< n:
      if k notin reprs and k notin raised: continue      # (it did not end: left out)
      let call = calls[k]
      var pre = ""
      var callIn = call
      var anyVar = false
      for pi in 0 ..< samples.len:
        if isVar[pi]:
          anyVar = true
          pre.add "    var a" & $pi & " = " & samples[pi][k mod samples[pi].len] & "\n"
      if anyVar:
        var args: seq[string]
        for pi, xs in samples: args.add (if isVar[pi]: "a" & $pi else: xs[k mod xs.len])
        callIn = name & "(" & args.join(", ") & ")"
      suite.add "  test " & escape(call & (if k in raised: " raises " & raised[k] else: "")) & ":\n" & pre
      if k in raised:
        suite.add "    expect " & raised[k] & ":\n      " & (if void: "" else: "discard ") & callIn & "\n"
      elif void: suite.add "    " & callIn & "\n"
      elif ptBasicRet(s.ret): suite.add "    check " & callIn & " == " & reprs[k] & "\n"
      elif k in strs: suite.add "    check $" & callIn & " == " & strs[k] & "\n"
      else: suite.add "    discard " & callIn & "   # (a " & s.ret & ": ned cannot write its value)\n"
      for pi in 0 ..< samples.len:
        if isVar[pi] and (k, pi) in vars: suite.add "    check a" & $pi & " == " & vars[(k, pi)] & "\n"
      inc written
    var text = ""
    let have = fileExists(testPath)
    if have:
      try: text = readFile(testPath)
      except CatchableError: discard
    if not have or text.strip.len == 0:
      text = "# tests ned wrote from what the procs return now (Nim: write tests for this proc): read the values —\n" &
             "# a wrong one is a bug these tests would keep\nimport std/unittest\n" &
             (if exported: "import " & spec & "\n"
              else: "include " & spec & "   # (" & name & " is not exported: the module included — its " &
                    "`when isMainModule` code runs here too)\n")
    elif not exported and ("include " & spec) notin text:
      text = text.strip(leading = false) & "\ninclude " & spec & "   # (" & name & " is not exported)\n"
    elif exported and ("import " & spec) notin text and ("include " & spec) notin text:
      text = "import " & spec & "\n" & text
    if "std/unittest" notin text and "import unittest" notin text: text = "import std/unittest\n" & text
    text = text.strip(leading = false) & "\n" & suite
    try:
      createDir(parentDir(testPath))
      writeFileSafe(testPath, text)
    except CatchableError as e:
      error("Could not write " & testPath & ": " & e.msg)
      return
    let tb = openFile(testPath)
    if tb != nil:
      tb.reloadBuffer()
      tb.setSingle(Pos(line: max(0, tb.lines.len - 1), col: 0))
    info($written & " test" & (if written == 1: "" else: "s") & " for " & name & " in " & relPath(testPath) &
         " — check the values; the tests run now with coverage (AI: write tests adds the cases you describe)")
    cmdCoverageTestFile(testPath))
