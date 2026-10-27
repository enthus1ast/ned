proc cmdCodeActions()

proc diagText(d: Diag, path: string): string =
  ## a diagnostic in one line (Nim's long messages summarised)
  if path.endsWith(".nim") or path.endsWith(".nims") or path.endsWith(".nimble"): nimMsgSummary(d.msg)
  else: d.msg.splitLines()[0]

proc lspAndBuildDiags(path: string): seq[Diag] =
  ## the language server's problems and those of the last build or check; one the two both report shows once
  result = diagsLsp.getOrDefault(path)
  let fromServer = result.len
  if fromServer > 0 and path in diagsBuild and diagsBuild[path].len > 0:
    # (the server's by line: with thousands of both, each of the check's looked at every one of the server's)
    var byLine: Table[int, seq[int]]
    for k in 0 ..< fromServer: byLine.mgetOrPut(result[k].line, @[]).add k
    for d in diagsBuild[path]:
      var dup = false
      for k in byLine.getOrDefault(d.line):
        if result[k].sev == d.sev and result[k].msg.splitLines()[0].strip == d.msg.splitLines()[0].strip:
          dup = true
          break
      if not dup: result.add d
  else:
    for d in diagsBuild.getOrDefault(path): result.add d
  for d in diagsFfi.getOrDefault(path): result.add d
  for d in diagsTest.getOrDefault(path): result.add d
  for d in diagsExt.getOrDefault(path): result.add d
  for d in diagsWeb.getOrDefault(path): result.add d
  let em = diagsEmit.getOrDefault(path)
  if em.len > 0:
    var k = 0
    for d in result:
      var same = false
      if d.msg.startsWith("C: "):
        for e in em:
          if e.line == d.line: same = true
      if not same:
        result[k] = d
        inc k
    result.setLen(k)
    for d in em: result.add d

proc diagsFor(path: string): seq[Diag] =
  if path.len == 0: return
  result = lspAndBuildDiags(path)
  for d in diagsAi.getOrDefault(path): result.add d
  if path.endsWith(".nim") or path.endsWith(".nims"): dropNimFollowOns(result)
  # a problem past the last line — "expected ')', but got '[EOF]'" is at the line after the file's last line end —
  # is shown at the end of the last line: in the editor, the gutter and F8 too, not only in Problems
  let bi = bufIndexByPath(path)
  if bi >= 0 and result.len > 0:
    let ls = addr bufs[bi].lines
    let hi = ls[].high
    for d in result.mitems:
      if d.line > hi:
        d.line = hi
        d.col = ls[][hi].len
        d.eline = hi
        d.ecol = -1
      elif d.line == hi and d.col > ls[][hi].len: d.col = ls[][hi].len

proc sevColor(sev: int): Rgb =
  case sev
  of 1: theme.err
  of 2: theme.warn
  of 3: theme.info
  else: theme.hint
