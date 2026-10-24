# ── code a compile leaves out, dimmed: Nim's `when` branches that are false on this platform (when
#    defined(windows) on Linux), C's #if 0 and #ifdef __cplusplus (editor.dimInactiveCode) ──

var inactiveCache: Table[int, (int, seq[(int, int)])]    # buffer id → (the change it was worked out for, ranges)

proc inactiveRanges(b: Buffer): seq[(int, int)] =
  if not cfgDimInactive or b.lang == nil or b.largeOn: return
  if b.lang.mode != lmNim and b.lang.id notin ["c", "cpp"]: return
  if b.id in inactiveCache and inactiveCache[b.id][0] == b.changeId: return inactiveCache[b.id][1]
  try:
    if b.lang.mode == lmNim:
      if nimEngineOn(b):
        var any = false
        for l in b.lines:
          if "when " in l:
            any = true
            break
        if any:
          let f = nxFileFor(b)
          if f != nil: result = nxInactiveWhen(f, b.lines)
    else:
      var any = false
      for l in b.lines:
        if l.len > 2 and l.strip(trailing = false).startsWith("#if"):
          any = true
          break
      # (clangd or ned's engine: the same rule)
      if any: result = cxInactiveIn(b.allText, cpp = cxIsCppBuf(b), path = b.path)
  except Exception as e:
    internalError("dimming left-out code", e)
  if result.len > 1:
    # in order, one inside another merged (lineInactive looks them up by halving)
    result.sort(proc(x, y: (int, int)): int = cmp(x[0], y[0]))
    var merged = @[result[0]]
    for r in result[1 .. ^1]:
      if r[0] <= merged[^1][1] + 1: merged[^1][1] = max(merged[^1][1], r[1])
      else: merged.add r
    result = merged
  inactiveCache[b.id] = (b.changeId, result)

proc lineInactive(rs: seq[(int, int)], line: int): bool =
  var lo = 0
  var hi = rs.high
  while lo <= hi:
    let m = (lo + hi) div 2
    if line < rs[m][0]: hi = m - 1
    elif line > rs[m][1]: lo = m + 1
    else: return true
  false
