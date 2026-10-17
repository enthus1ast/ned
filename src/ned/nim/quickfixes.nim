proc nimProblemFixes(b: Buffer, ds: seq[Diag]): seq[(string, string, Action)] =
  ## the fixes for the compiler's problems `ds` (on one line of a Nim file): each one's own fixes, "all of this kind
  ## in the file", the imports that declare an undeclared name, the removal of an unused import (also used by nedls)
  var titles: HashSet[string]
  var kinds: HashSet[string]
  for d in ds:
    for fx in nimDiagFixes(b, d):
      if fx[0] notin titles:
        titles.incl fx[0]
        result.add fx
    let k = nimFixKind(d)
    if k.len > 0 and k notin kinds:
      kinds.incl k
      let (n, a) = nimFixAll(b, k)
      if n > 1: result.add act("Fix all " & $n & " like this in the file", (case k
        of "discard": "discard every unused result"
        of "bareExcept": "except CatchableError: everywhere"
        of "unusedImport": "remove every unused import"
        else: "the new name everywhere it is used"), a)
  for d in ds:
    let m = d.msg
    let name = quotedName(m)
    if name.len == 0: continue
    if "undeclared identifier" in m or "undeclared routine" in m or "undeclared field" in m:
      loadNimIndex()
      var mods = nimIndex.getOrDefault(name)
      mods.sort(proc(x, y: string): int = cmp(x.len, y.len))
      for k, md in mods:
        if k >= 6: break
        if ("Import " & md) in titles: continue
        titles.incl "Import " & md
        result.add act("Import " & md, "exports " & name, importAct(b.id, md))
      # the project's own modules that export it
      if "undeclared field" notin m:
        for md in projectModulesExporting(b, name):
          if ("Import " & md) in titles: continue
          titles.incl "Import " & md
          result.add act("Import " & md, "this project's module exports " & name, importAct(b.id, md))
    elif "imported and not used" in m:
      result.add act("Remove unused import " & name, "", removeImportAct(b.id, name))

proc localFixes(b: Buffer): seq[(string, string, Action)] =
  ## quick fixes ned offers itself, next to the language server's
  result = spellFixes(b)
  block embeddedFormat:
    if b.lang.mode == lmNim:
      let (l, _, body, lg) = b.embeddedStringAt(b.primary.head)
      if l >= 0 and lg != nil and body.len >= 2:
        result.add act("Format the " & lg.name & " in this string", "as " & lg.name & ", at the string's indentation",
                       proc() = cmdFormatEmbedded())
  let ds = diagsAtCursor(b)
  if b.lang != nil and b.lang.id in ["c", "cpp"]:
    var seenInc: HashSet[string]
    for d in ds:
      let (t, dsc, a) = cIncludeFix(b, d)
      if t.len > 0 and t notin seenInc:
        seenInc.incl t
        result.add act(t, dsc, a)
  for d in ds:
    if d.src != "C header": continue
    let u = d.msg.find(" — use ")
    if u >= 0:
      var typ = d.msg[u + " — use ".len .. ^1]
      let p2 = typ.find("  (")
      if p2 > 0: typ = typ[0 ..< p2]
      if d.ecol > d.col or d.eline > d.line:
        result.add act("Use " & typ, "what the C header declares", ffiTypeAct(b.id, Pos(line: d.line, col: d.col),
                                                                                Pos(line: d.eline, col: d.ecol), typ))
    if "add {.varargs.}" in d.msg: result.add act("Add {.varargs.}", "C takes more arguments (…)", ffiVarargsAct(b.id, d.line))
  if b.lang.mode == lmNim and "importc" in b.lines[b.primary.head.line] or
     (b.primary.head.line + 1 < b.lines.len and "importc" in b.lines[b.primary.head.line + 1]):
    try:
      let (t, dsc, a) = ffiRewriteFix(b)
      if t.len > 0: result.add act(t, dsc, a)
    except CatchableError as e: internalError("C wrapper fix", e)
  let refStart = result.len
  block refactors:
    let (ra, re) = b.primary.range
    if ra != re and ra.line == re.line and b.lang.id in ["nim", "python", "ruby", "javascript", "typescript", "go",
                                                          "rust", "lua"]:
      result.add act("Extract into a variable", "let name = the selection", proc() = extractVariable())
    if b.lang.mode == lmNim:
      let ln = b.lines[b.primary.head.line]
      let lt = ln.strip
      if '&' in ln and '"' in ln: result.add act("Use fmt for this string", "\"a\" & x → fmt\"a{x}\"", proc() = concatToFmt())
      if (lt.startsWith("let ") or lt.startsWith("const ")) and b.wordAt(b.primary.head).len > 0:
        result.add act("Inline this variable", "its value where it is used", proc() = inlineVariable())
      if lt.startsWith("const ") or (ra != re and ra.line == re.line):
        result.add act("Evaluate at compile time", "the value, as the compiler computes it", proc() = nimEvaluate())
  if nimEngineOn(b):
    let t = b.lines[b.primary.head.line].strip
    let (sa, se) = b.primary.range
    if sa != se: result.add act("Run the selection", "nim r, with this file's imports", proc() = runSelection())
    if caseInfo(b)[0] >= 0 and b.primary.head.line - caseInfo(b)[0] < 60:
      result.add act("Add the missing case branches", "one `of` per enum value", proc() = addMissingBranches())
    if typeAtCursor(b)[1] >= 0:
      result.add act("Generate `$`, `==`, hash and a constructor", "for this object type", proc() = generateForType("all"))
      result.add act("Generate `$`", "", proc() = generateForType("$"))
      result.add act("Generate `==`", "", proc() = generateForType("=="))
      result.add act("Generate hash", "imports std/hashes", proc() = generateForType("hash"))
      result.add act("Generate a constructor", "", proc() = generateForType("init"))
    if t.startsWith("proc ") or t.startsWith("func ") or t.startsWith("method ") or t.startsWith("iterator ") or
       t.startsWith("template ") or t.startsWith("macro "):
      result.add act("Add a doc comment", "## naming the parameters", proc() = docCommentStub())
      var fw = -1
      try: fw = forwardDeclAt(b)[1]
      except Exception as e: internalError("Nim index", e)
      if fw >= 0: result.add act("Write its body", "at the end of the file", proc() = writeForwardBody())
    block ctor:
      var ci: CtorInfo
      try: ci = ctorAtCursor(b)
      except Exception as e: internalError("Nim index", e)
      if ci.ok and ci.missing.len > 0:
        var names: seq[string]
        for (n, _) in ci.missing: names.add n
        result.add act("Fill in the missing fields", truncTo(names.join(", "), 40), proc() = fillMissingFields())
    if quotedName(t, "test ").len > 0:
      result.add act("Debug this test", "only this test, under gdb", proc() = debugTestAtCursor())
    # refactorings of the routine (or type) the cursor names
    var (rd, rok) = rfDeclOf(b)
    if rok and not (rd.file.path.startsWith(rootDir & "/") or bufIndexByPath(rd.file.path) >= 0):
      rok = false                  # (echo, a standard library proc: not ours to change)
    if rok and rd.sym.kind in NxRoutineKinds:
      result.add act("Change signature of " & rd.sym.name & "…", "parameters, order, defaults — and every call",
                     proc() = cmdChangeSignature())
      if rd.sym.kind in {nxProc, nxFunc, nxTemplate} and rfBodyExpr(rfLinesOf(rd.file.path), rd.sym).len > 0:
        result.add act("Inline " & rd.sym.name, "every call becomes its body", proc() = cmdInlineProc())
    if rok and rd.file.path == b.path and rd.sym.kind in NxRoutineKinds + {nxType} and rd.sym.line == b.primary.head.line:
      result.add act("Move " & rd.sym.name & " to another module…", "imports follow", proc() = cmdMoveToModule())
  let diagStart = result.len
  if b.lang.mode == lmNim: result.add nimProblemFixes(b, ds)
  if result.len > diagStart and diagStart > refStart:
    # (the fixes for the problem on this line before the refactorings the cursor's word allows)
    result = result[0 ..< refStart] & result[diagStart .. ^1] & result[refStart ..< diagStart]
  let failedTest = failingTestAt(b, b.primary.head.line)
  if failedTest.len > 0 and (cfgAiProvider in ["ollama", "custom"] or aiKey().len > 0):
    # a failed check of a test: the code it tests is what to fix — kept only when the test passes then
    let (tp, tn) = (b.path, failedTest)
    result.add act(ic("ai") & " Make this test pass with AI", "kept only when it passes: " & tn, proc() = aiFixTest(tp, tn))
  elif ds.len > 0 and (cfgAiProvider in ["ollama", "custom"] or aiKey().len > 0):
    result.add act(ic("ai") & " Fix with AI", truncTo(ds[0].msg.splitLines()[0], 50), proc() = aiFixProblem())
    result.add act(ic("ai") & " Explain this problem", "", proc() = aiExplainProblem())
