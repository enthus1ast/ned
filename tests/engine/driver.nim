# the engine's answers for compare.py, included after ned's source in place of its main (build.sh)
import std/osproc

when isMainModule:
  # the engine's answers for the comparison harness: one JSON request per line on stdin, one JSON answer per line
  when declared(engineInlayBudget): engineInlayBudget = 1_000_000
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
