# ── project-wide symbols (heuristic, works offline for every language) ──

proc cmdProjectSymbols() =
  let t0 = getMonoTime()
  var items: seq[PickItem]
  let useIndex = cfgNimIde != "off" and not nimUsesLsp()
  for rel in projectFiles():
    let path = rootDir / rel
    let lang = detectLang(path, "")
    if lang.mode in {lmPlain, lmJson, lmYaml, lmToml, lmMake, lmDiff, lmCss, lmHtml}: continue
    if useIndex and lang.mode == lmNim:
      # Nim files: from ned's index (declarations with their kinds, fields and enum values too)
      try:
        let f = nxLoad(path)
        if f != nil:
          for s in f.syms:
            if s.kind in {nxModule} or s.local: continue
            let owner = if s.kind in {nxField, nxEnumVal}: s.owner & "." else: ""
            items.add PickItem(label: owner & s.name, detail: rel & ":" & $(s.line + 1), icon: nxIconText(s.kind),
                               path: path, line: s.line, col: s.col)
      except Exception as e: internalError("Nim index", e)
      if msSince(t0) > 2500 or items.len > 200_000: break
      continue
    try:
      if getFileSize(path) > 600_000: continue
      let tb = newBuffer()
      tb.lang = lang
      tb.path = path
      let bi = bufIndexByPath(path)
      tb.lines = if bi >= 0: bufs[bi].lines else: readFile(path).splitLines
      if tb.lines.len == 0: tb.lines = @[""]
      for it in heuristicSymbols(tb):
        var x = it
        x.detail = rel & ":" & $(it.line + 1)
        items.add x
    except CatchableError: discard
    if msSince(t0) > 2500 or items.len > 200_000: break
  if items.len == 0:
    info("No symbols found in the project")
    return
  openPicker(pickSymbol, "Go to symbol in project", items)
