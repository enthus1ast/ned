# ── outline ──────────────────────────────────────────────────────────────────

proc heuristicOutline(b: Buffer): seq[SideItem] =
  for it in heuristicSymbols(b):
    let ind = if it.line < b.lines.len: leadingWs(b.lines[it.line]).len div max(1, b.indentW()) else: 0
    result.add SideItem(text: it.label.strip, detail: it.detail, path: b.path, line: it.line, col: it.col,
                        depth: (if it.icon == "#": (it.label.len - it.label.strip(trailing = false).len) div 2
                                else: min(ind, 6)), icon: it.icon,
                        role: (if it.icon == "ƒ": 7 elif it.icon == "T": 8 elif it.icon == "#": 1 else: 0))

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
  if b.outlineReqAt != b.changeId:
    b.outlineReqAt = b.changeId
    if nsUsable(b): discard nsRequest(b, nsOutline, Pos())
  if b.outline.len == 0 or b.outlineAt != b.changeId:
    if b.lines.len < 100_000:
      b.outline = heuristicOutline(b)
      b.outlineAt = b.changeId
