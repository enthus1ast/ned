# ── code a compile leaves out, dimmed: Nim's `when` branches that are false on this platform (when
#    defined(windows) on Linux), C's #if 0 and #ifdef __cplusplus (editor.dimInactiveCode) ──

var inactiveCache: Table[int, (int, seq[(int, int)], int)]
  ## buffer id → (the change it was worked out for, ranges, the file's lines then)

proc inactiveRanges(b: Buffer): seq[(int, int)] =
  ## the line ranges (first, last) of code the compiler leaves out, to be dimmed: false `when` branches in Nim (from the
  ## Nim index) and `#if 0` / `#ifdef __cplusplus` parts in C and C++. They are worked out once per change of the text
  ## and kept; while typing, the earlier ranges are moved by the lines added or removed at the cursor and the real work
  ## waits for a pause; a big file just opened is dimmed a moment later. The result is sorted, with overlapping ranges
  ## merged. It is empty when dimming is off, for other languages and in large-file mode.
  if not cfgDimInactive or b.lang == nil or b.largeOn or (b.lang.mode != lmNim and b.lang.id notin ["c", "cpp"]):
    inactiveCache.del b.id
    return
  if b.id in inactiveCache:
    let c = inactiveCache[b.id]
    if c[0] == b.changeId: return c[1]
    if msSince(b.lspChangeAt) < SemPauseMs:
      # (typing: the ranges as they were, moved by the lines added or taken out at the cursor — worked out again
      # in the pause, like the semantic colours: it reads the whole file, which in a big one made every key late)
      let d = b.lines.len - c[2]
      if d == 0: return c[1]
      let at = b.primary.head.line
      for (a, e) in c[1]:
        let r = if a > at: (a + d, e + d) elif e >= at: (a, max(a, e + d)) else: (a, e)
        if r[0] >= 0 and r[0] < b.lines.len: result.add (r[0], min(r[1], b.lines.high))
      return
  elif b.lines.len > 3000:
    # (a big file just opened: shown at once, its left-out code dimmed a moment later — the main loop asks for it
    # in the next quiet round; reading it first held up the first frame by half)
    inactiveCache[b.id] = (-1, @[], b.lines.len)
    return
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
  inactiveCache[b.id] = (b.changeId, result, b.lines.len)

proc inactiveDue(b: Buffer): bool =
  ## its dimmed ranges kept from before the last edit: the main loop draws again once typing pauses
  cfgDimInactive and b.id in inactiveCache and inactiveCache[b.id][0] != b.changeId and not b.largeOn and
    b.id notin diffViews and b.id notin multiBufs

proc lineInactive(rs: seq[(int, int)], line: int): bool =
  ## whether a line lies in one of the sorted, merged ranges, found by halving
  var lo = 0
  var hi = rs.high
  while lo <= hi:
    let m = (lo + hi) div 2
    if line < rs[m][0]: hi = m - 1
    elif line > rs[m][1]: lo = m + 1
    else: return true
  false
