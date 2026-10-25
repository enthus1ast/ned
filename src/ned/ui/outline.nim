# ── outline ──────────────────────────────────────────────────────────────────

proc heuristicOutline(b: Buffer): seq[SideItem] =
  for it in heuristicSymbols(b):
    let ind = if it.line < b.lines.len: leadingWs(b.lines[it.line]).len div max(1, b.indentW()) else: 0
    result.add SideItem(text: it.label.strip, detail: it.detail, path: b.path, line: it.line, col: it.col,
                        depth: (if it.icon == "#": (it.label.len - it.label.strip(trailing = false).len) div 2
                                else: min(ind, 6)), icon: it.icon,
                        role: (if it.icon == "ƒ": 7 elif it.icon == "T": 8 elif it.icon == "#": 1 else: 0))

proc jsonOutlineOf(b: Buffer): seq[SideItem] =
  ## a JSON file's keys, nested as in the file (and the items of short lists)
  for it in jsonOutline(b.lines, comments = true):
    result.add SideItem(text: it.name, detail: it.detail, path: b.path, line: it.line, col: it.col, depth: min(it.depth, 8),
                        icon: (case it.kind
                               of jkObject: "{"
                               of jkArray: "["
                               else: "·"),
                        role: (if it.kind in {jkObject, jkArray}: 8 else: 0))

proc jsOutlineOf(b: Buffer): seq[SideItem] =
  ## a JavaScript file's declarations: functions, classes and their members, its consts, lets, vars and imports
  for it in jsOutline(b.lines):
    let fn = it.kind in {jdFunction, jdMethod}
    result.add SideItem(text: it.name, detail: it.detail, path: b.path, line: it.line, col: it.col, depth: it.depth,
                        icon: (if fn: "ƒ" elif it.kind == jdClass: "T" else: "v"),
                        role: (if fn: 7 elif it.kind == jdClass: 8 else: 0))

proc ensureOutline(b: Buffer) =
  ## cheap heuristic outline right away; nimsuggest/LSP refine it in the background
  if b.outlineAt == b.changeId and b.outline.len > 0: return
  if cEngineOn(b):
    b.outline = cEngOutline(b)
    b.outlineAt = b.changeId
    b.outlineReqAt = b.changeId
    return
  if nimEngineOn(b):
    b.outline = engineOutline(b)
    b.outlineAt = b.changeId
    b.outlineReqAt = b.changeId
    return
  if b.lang.mode == lmNif and b.lines.len < 300_000:
    # (NIF: its routines, types, globals — pnak's lockfile: its packages)
    b.outline = if extractFilename(b.path) == "pnak.nif": pnakOutlineOf(b) else: nifOutlineOf(b)
    b.outlineAt = b.changeId
    b.outlineReqAt = b.changeId
    return
  if b.lang.mode == lmJson and b.lines.len < 200_000:
    b.outline = jsonOutlineOf(b)                   # (JSON: its keys, nested)
    b.outlineAt = b.changeId
    b.outlineReqAt = b.changeId
    return
  let (plugHas, plugItems) = plugOutline(b)        # a plugin's symbols for the language (the newest it gave)
  if plugHas and plugItems.len > 0:
    b.outline = plugItems
    b.outlineAt = b.changeId
    return
  if b.outlineReqAt != b.changeId:
    b.outlineReqAt = b.changeId
    if nsUsable(b): discard nsRequest(b, nsOutline, Pos())
  if b.outline.len == 0 or b.outlineAt != b.changeId:
    if b.lang.id == "javascript" and b.lines.len < 40_000 and cfgWebEngine != "off":
      b.outline = jsOutlineOf(b)                   # (ned's own JavaScript engine: classes with their members)
      b.outlineAt = b.changeId
    elif b.lines.len < 100_000:
      b.outline = heuristicOutline(b)
      b.outlineAt = b.changeId
