proc cmdCodeActions()

proc diagText(d: Diag, path: string): string =
  ## a diagnostic in one line (Nim's long messages summarised)
  if path.endsWith(".nim") or path.endsWith(".nims") or path.endsWith(".nimble"): nimMsgSummary(d.msg)
  else: d.msg.splitLines()[0]

proc lspAndBuildDiags(path: string): seq[Diag] =
  ## the language server's problems and those of the last build or check; one the two both report shows once
  result = diagsLsp.getOrDefault(path)
  let fromServer = result.len
  for d in diagsBuild.getOrDefault(path):
    var dup = false
    for k in 0 ..< fromServer:
      let e = result[k]
      if e.line == d.line and e.sev == d.sev and e.msg.splitLines()[0].strip == d.msg.splitLines()[0].strip:
        dup = true
        break
    if not dup: result.add d
  for d in diagsFfi.getOrDefault(path): result.add d
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

proc sevColor(sev: int): Rgb =
  case sev
  of 1: theme.err
  of 2: theme.warn
  of 3: theme.info
  else: theme.hint
