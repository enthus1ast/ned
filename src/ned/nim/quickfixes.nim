proc lintIgnoreLineAct(id, line: int, rule: string): Action
proc lintRuleOffAct(path, rule: string): Action

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
        of "varLet": "every var nothing changes made a let"
        of "canBeFunc": "every proc without side effects made a func"
        of "nim3": "every change for Nim 3 that ned can make"
        of "unnamedBreak": "every break that leaves a block names it"
        else: "the new name everywhere it is used"), a)
  when not defined(nedNoMain):
    for d in ds:
      if "unlisted exception" in d.msg or "can have side effects" in d.msg:
        result.add act("Why? — where it comes from", "the calls on the way, each one to go to",
                       whyHintAct(b.id, d.line))
        break
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
  # (ned's own checks: silence the rule on this line, or for the project — .ned/lint.json)
  var rules: HashSet[string]
  for d in ds:
    if d.src == "ned" and d.rule.len > 0 and d.rule notin rules:
      rules.incl d.rule
      result.add act("Silence " & d.rule & " on this line", "# ned: ignore[" & d.rule & "]",
                     lintIgnoreLineAct(b.id, d.line, d.rule))
      result.add act("Turn off " & d.rule & " for this project", ".ned/lint.json", lintRuleOffAct(b.path, d.rule))

proc lintIgnoreLineAct(id, line: int, rule: string): Action =
  ## `# ned: ignore[rule]` at the end of the line (added to one that is there)
  result = proc() =
    let b = bufById(id)
    if b == nil or line < 0 or line >= b.lines.len or not b.canEdit(): return
    let s = b.lines[line]
    let k = s.find("# ned: ignore[")
    b.beginEdit()
    if k >= 0:
      let c = s.find(']', k)
      if c > k: discard b.replaceText(Pos(line: line, col: c), Pos(line: line, col: c), ", " & rule)
    else:
      discard b.replaceText(Pos(line: line, col: s.len), Pos(line: line, col: s.len), "  # ned: ignore[" & rule & "]")
    b.endEdit()
    info("Silenced " & rule & " on this line")

proc lintRuleOffAct(path, rule: string): Action =
  ## the rule off in the project's .ned/lint.json (made when there is none, beside the .nimble or at the top)
  result = proc() =
    if quickFixDryRun: return                          # (it writes the file itself: not an edit nedls can send)
    var f = lintCfgFile(path)
    if f.len == 0:
      let nb = findNimbleFile(parentDir(path))
      let top = if nb.len > 0: parentDir(nb) elif rootDir.len > 0: rootDir else: parentDir(path)
      f = top / ".ned" / "lint.json"
    var j = newJObject()
    if fileExists(f):
      try: j = parseJson(readFile(f))
      except CatchableError:
        error(f & " is not valid JSON — fix it first")
        return
    if j{"rules"} == nil or j{"rules"}.kind != JObject: j["rules"] = newJObject()
    j["rules"][rule] = %"off"
    try:
      createDir(parentDir(f))
      writeFileSafe(f, j.pretty & "\n")
    except CatchableError as e:
      error("Could not write " & f & ": " & e.msg)
      return
    for b in bufs: b.lastChange = -1                    # (checked again)
    typoAt.clear()
    info(rule & " is off in " & relPath(f) & " — set it to \"warning\", \"hint\" … there to have it back")

proc nimRefactors(b: Buffer, lsp = false): seq[(string, string, Action)] =
  ## the refactorings ned offers at the cursor (and selection) in the quick-fix list. lsp: only those that are an
  ## edit of the text and nothing else — nedls sends them as code actions (no dialog, nothing run, no name asked:
  ## extract takes the name it would have proposed)
  block refactors:
    let (ra, re) = b.primary.range
    if ra != re and ra.line == re.line and b.lang.id in ["nim", "python", "ruby", "javascript", "typescript", "go",
                                                          "rust", "lua"]:
      let ex: Action = if lsp: (proc() = extractVariable(direct = true)) else: (proc() = extractVariable())
      result.add act("Extract into a variable", "let name = the selection", ex)
    if b.lang.mode == lmNim:
      let ln = b.lines[b.primary.head.line]
      let lt = ln.strip
      if '&' in ln and '"' in ln and fmtPlan(ln, b.primary.head.col).why.len == 0:
        result.add act("Use fmt for this string", "\"a\" & x → fmt\"a{x}\"", proc() = concatToFmt())
      let w = b.wordAt(b.primary.head)
      for kw in ["let ", "const "]:
        # (on the name it declares)
        if w.len > 0 and lt.startsWith(kw) and lt[kw.len .. ^1].startsWith(w) and
           (lt.len == kw.len + w.len or lt[kw.len + w.len] notin IdentChars):
          result.add act("Inline this variable", "its value where it is used", proc() = inlineVariable())
      if not lsp and (lt.startsWith("const ") or (ra != re and ra.line == re.line)):
        result.add act("Evaluate at compile time", "the value, as the compiler computes it", proc() = nimEvaluate())
  if nimEngineOn(b):
    let t = b.lines[b.primary.head.line].strip
    let (sa, se) = b.primary.range
    if sa != se and not lsp:
      result.add act("Run the selection", "nim r, with this file's imports", proc() = runSelection())
    let ci = caseInfo(b)
    if ci[0] >= 0 and b.primary.head.line - ci[0] < 60:
      var mb: typeof(missingBranches(b))
      try: mb = missingBranches(b)
      except Exception as e: internalError("Nim index", e)
      if mb.missing.len > 0:
        result.add act("Add the missing case branches", "one `of` per value of " & mb.tname & " without one",
                       proc() = addMissingBranches())
    if typeAtCursor(b)[1] >= 0:
      var rp: ReorderPlan
      try: rp = reorderPlan(b)
      except Exception as e: internalError("Nim index", e)
      if rp.ok:
        result.add act("Reorder fields to save " & $(rp.before - rp.after) & " bytes (" & $rp.before & " → " &
                       $rp.after & " B)", "largest alignment first; comments move with their field",
                       proc() = reorderFields())
      result.add act("Generate `$`, `==`, hash and a constructor", "for this object type", proc() = generateForType("all"))
      result.add act("Generate `$`", "", proc() = generateForType("$"))
      result.add act("Generate `==`", "", proc() = generateForType("=="))
      result.add act("Generate hash", "imports std/hashes", proc() = generateForType("hash"))
      result.add act("Generate a constructor", "", proc() = generateForType("init"))
    if t.startsWith("proc ") or t.startsWith("func ") or t.startsWith("method ") or t.startsWith("iterator ") or
       t.startsWith("template ") or t.startsWith("macro "):
      var hl = b.primary.head.line          # (none when it has one: the line after the header's `=`)
      while hl < b.lines.high and hl - b.primary.head.line < 12 and
            not b.lines[hl].strip(leading = false).endsWith("="): inc hl
      if not (hl + 1 <= b.lines.high and b.lines[hl + 1].strip.startsWith("##")):
        result.add act("Add a doc comment", "## naming the parameters", proc() = docCommentStub())
      var fw = -1
      try: fw = forwardDeclAt(b)[1]
      except Exception as e: internalError("Nim index", e)
      if fw >= 0: result.add act("Write its body", "at the end of the file", proc() = writeForwardBody())
    result.add nimRewrites(b)
    block ctor:
      var ci: CtorInfo
      try: ci = ctorAtCursor(b)
      except Exception as e: internalError("Nim index", e)
      if ci.ok and ci.missing.len > 0:
        var names: seq[string]
        for (n, _) in ci.missing: names.add n
        result.add act("Fill in the missing fields", truncTo(names.join(", "), 40), proc() = fillMissingFields())
    if not lsp and quotedName(t, "test ").len > 0:
      result.add act("Debug this test", "only this test, under gdb", proc() = debugTestAtCursor())
    # refactorings of the routine (or type) the cursor names
    var (rd, rok) = rfDeclOf(b)
    if rok and not (rd.file.path.startsWith(rootDir & "/") or bufIndexByPath(rd.file.path) >= 0):
      rok = false                  # (echo, a standard library proc: not ours to change)
    if rok and rd.sym.kind in NxRoutineKinds:
      if not lsp:
        result.add act("Change signature of " & rd.sym.name & "…", "parameters, order, defaults — and every call",
                       proc() = cmdChangeSignature())
      if rd.sym.kind in {nxProc, nxFunc, nxTemplate} and rfBodyExpr(rfLinesOf(rd.file.path), rd.sym).len > 0:
        result.add act("Inline " & rd.sym.name, "every call becomes its body", proc() = cmdInlineProc())
    if not lsp and rok and rd.file.path == b.path and rd.sym.kind in NxRoutineKinds + {nxType} and
       rd.sym.line == b.primary.head.line:
      result.add act("Move " & rd.sym.name & " to another module…", "imports follow", proc() = cmdMoveToModule())

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
    result.add cFixItActions(b, ds)
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
  result.add nbVersionFixes(b)                      # (a .nimble's version: bumped)
  let refStart = result.len
  result.add nimRefactors(b)
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
