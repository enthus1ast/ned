proc heuristicOutline(b: Buffer): seq[SideItem]

proc engineOutline(b: Buffer): seq[SideItem] =
  ## the file's declarations: routines, types (with fields and enum values), constants, variables
  var f: NxFile
  try: f = nxFileFor(b)
  except Exception as e:
    internalError("Nim index", e)
    return heuristicOutline(b)
  if f == nil: return heuristicOutline(b)
  for s in f.syms:
    if s.kind == nxModule or s.local: continue
    let depth = if s.kind in {nxField, nxEnumVal}: 1 else: 0
    var detail = nxKindWord(s.kind)
    if s.kind == nxType:
      let w = s.typ.split({' ', '['})[0]
      detail = if w.len > 0: w else: "type"
    elif s.kind == nxField: detail = s.typ
    elif s.kind == nxEnumVal: detail = ""
    result.add SideItem(text: s.name & (if s.exported: "*" else: ""), detail: detail, path: b.path, line: s.line,
                        col: s.col, depth: depth, icon: nxIconText(s.kind),
                        role: (if s.kind in NxRoutineKinds: 7 elif s.kind == nxType: 8 else: 0))

proc engineSymbols(b: Buffer): seq[PickItem] =
  ## Ctrl+T: the file's declarations, with their signatures
  let f = nxFileFor(b)
  if f == nil: return
  for s in f.syms:
    if s.kind in {nxModule, nxEnumVal} or s.local: continue
    let owner = if s.kind == nxField: s.owner & "." else: ""
    result.add PickItem(label: owner & s.name, detail: truncTo(nxShortDetail(s), 60), icon: nxIconText(s.kind),
                        path: b.path, line: s.line, col: s.col)
