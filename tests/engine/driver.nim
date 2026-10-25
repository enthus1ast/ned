# the engine's answers for compare.py, included after ned's source in place of its main (build.sh)
import std/osproc

when isMainModule:
  # the engine's answers for the comparison harness: one JSON request per line on stdin, one JSON answer per line
  when declared(engineInlayBudget): engineInlayBudget = 1_000_000
  # (the languages and the settings' defaults, as ned --lint has them: no one's own settings)
  putEnv("XDG_CONFIG_HOME", getTempDir() / "ned-engine-no-settings")
  initLangs()
  loadConfig()
  nxInitDefines()
  let lib = nxGuessLib()
  nxLibFound = lib
  var lazy: seq[string]
  if paramCount() >= 1:
    lazy.add paramStr(1)
    putEnv("NIMBLE_DIR", parentDir(paramStr(1)))   # (ned's own toolchain setup finds the packages there too)
  nxLibGuessed = true
  nxSetToolchain(lib, @[], lazy)
  cfgInlayHints = true
  when declared(cfgParamHints): cfgParamHints = "off"     # (type hints only: nimsuggest's are what they are compared with)
  var cache: Table[string, (NxFile, seq[string])]
  var dumped = false
  proc load(path: string): (NxFile, seq[string]) =
    if not dumped:
      # as ned does for a project: the symbols `nim dump` says are defined
      dumped = true
      try:
        let o = osproc.execProcess("nim dump --hints:off --warnings:off --dump.format:json " & quoteShell(path) & " 2>/dev/null",
                            workingDir = parentDir(path), options = {poEvalCommand})
        let a = o.find('{')
        let e = o.rfind('}')
        if a >= 0 and e > a:
          let js = parseJson(o[a .. e])
          var got = 0
          for x in js{"defined_symbols"}.getElems:
            nxDefines.incl x.getStr
            inc got
          when declared(nxDefinesComplete):
            if got > 20: nxDefinesComplete = true
      except CatchableError: discard
    if path notin cache:
      let ls = readFile(path).split('\n')
      cache[path] = (nxLoad(path), ls)
    cache[path]
  for raw in stdin.lines:
    var ans = newJObject()
    try:
      let j = parseJson(raw)
      let path = j{"path"}.getStr
      rootDir = parentDir(path)
      let (f, ls) = load(path)
      let line = j{"line"}.getInt
      let col = j{"col"}.getInt
      case j{"cmd"}.getStr
      of "def":
        var arr = newJArray()
        if f != nil:
          for (p, l, c, sig) in nxDefinition(f, ls, line, col): arr.add %*[p, l, c]
        ans["defs"] = arr
      of "type":
        var t = ""
        if f != nil:
          let (refs, locals, _) = nxTargets(f, ls, line, col)
          let sc = nxScope(f)
          if locals.len > 0:
            t = locals[0].typ
            if t.len == 0:
              t = nxTypeOfName(f, sc, nxLocals(f, ls, line, col), locals[0].name, line, 0).typ
          elif refs.len > 0:
            let s = refs[0].sym
            if s.kind in {nxLet, nxVar, nxConst, nxField, nxParam}:
              t = s.typ
              if t.len == 0 and s.value.len > 0:
                t = nxTypeOfExpr(refs[0].file, nxScope(refs[0].file), @[], s.value, s.line, 0).typ
        ans["type"] = %t
      of "expr":
        var t = ""
        if f != nil:
          let sc = nxScope(f)
          t = nxTypeOfExpr(f, sc, nxLocals(f, ls, line, col), j{"text"}.getStr, line, 0).typ
        ans["type"] = %t
      of "sug":
        var arr = newJArray()
        if f != nil:
          for it in nxComplete(f, ls, line, col).items: arr.add %it.label
        ans["items"] = arr
      of "hints":
        let b = newBuffer()
        b.path = path
        b.lines = ls
        b.lang = detectLang(path, "")
        var arr = newJArray()
        engineInlays(b, 0, ls.high)
        for l, hs in b.inlays:
          for (c, lab) in hs: arr.add %*[l, c, lab]
        ans["hints"] = arr
      of "refs":
        # (the references in this file: what nimsuggest's `use` says for it)
        let b = newBuffer()
        b.path = path
        b.lines = ls
        b.lang = detectLang(path, "")
        var hits: seq[(string, int, int)]
        var decl = ""
        var arr = newJArray()
        if engineReferences(b, Pos(line: line, col: col), hits, decl):
          for (p, l, c) in hits:
            if p == path: arr.add %*[l, c]
        ans["refs"] = arr
      of "hidden":
        # (the lines nimsuggest does not resolve every name of: `when` branches not taken here, runnableExamples'
        # blocks, the bodies of templates and of generic routines — where a name is bound when it is used)
        var arr = newJArray()
        if f != nil:
          for (a, e) in nxInactiveWhen(f, ls): arr.add %*[a, e]
          for s in f.syms:
            if s.kind in NxRoutineKinds and s.endLine > s.line and (s.kind == nxTemplate or s.generics.len > 0):
              arr.add %*[s.line + 1, s.endLine]
          var k = 0
          while k < ls.len:
            let t = ls[k].strip
            if t.startsWith("runnableExamples") and t.endsWith(":"):
              let ind = ls[k].len - ls[k].strip(trailing = false).len
              var e = k + 1
              while e < ls.len and (ls[e].strip.len == 0 or ls[e].len - ls[e].strip(trailing = false).len > ind): inc e
              arr.add %*[k, e - 1]
              k = e
            else: inc k
        ans["hidden"] = arr
      of "checks":
        # the engine's own checks of a text (as you type, before the compiler): what ned --lint reports — a
        # misspelled name, then the checks
        let b = newBuffer()
        b.path = path
        b.lines = (if j.hasKey("text"): j["text"].getStr.split('\n') else: ls)
        if b.lines.len > 1 and b.lines[^1].len == 0: b.lines.setLen(b.lines.len - 1)
        b.lang = detectLang(path, b.lines[0])
        var arr = newJArray()
        var errs = ""
        try:
          for d in lintChecks(b): arr.add %*[d.line, d.col, d.sev, d.msg]
        except CatchableError, Defect:
          errs = getCurrentExceptionMsg()
        ans["checks"] = arr
        if errs.len > 0: ans["error"] = %errs
      of "syms":
        var arr = newJArray()
        if f != nil:
          for sy in f.syms: arr.add %*[sy.name, $sy.kind, sy.line, sy.exported]
        ans["syms"] = arr
        ans["imports"] = %f.imports.len
      else: ans["error"] = %"unknown"
    except CatchableError as e: ans["error"] = %e.msg
    except Defect as e: ans["error"] = %("defect: " & e.msg)
    stdout.writeLine $ans
    stdout.flushFile
