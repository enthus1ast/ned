# a file's problems (errors, warnings, hints) merged from every source — language server, builds and checks, tests,
# plugins, ned's own checks — kept in step with the buffer, and the colour of each severity
proc cmdCodeActions()

proc diagText(d: Diag, path: string): string =
  ## a diagnostic in one line (Nim's long messages summarised)
  if path.endsWith(".nim") or path.endsWith(".nims") or path.endsWith(".nimble"): nimMsgSummary(d.msg)
  else: d.msg.splitLines()[0]

proc lspAndBuildDiags(path: string): seq[Diag] =
  ## the language server's problems and those of the last build or check; one the two both report shows once, and so
  ## does one ned's own CSS, HTML or SQL engine finds where the server does
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
  let web = diagsWeb.getOrDefault(path)
  if web.len > 0 and fromServer > 0:
    # (ned's own engine beside a language server — web.engine on: a problem both find at the same place shows once,
    # in ned's words, which name what was meant, kept as the server's, whose fixes Alt+Enter asks it for)
    var at: Table[(int, int), int]
    for k in countdown(fromServer - 1, 0): at[(result[k].line, result[k].col)] = k
    for d in web:
      let k = at.getOrDefault((d.line, d.col), -1)
      if k < 0:
        result.add d
        continue
      if result[k].raw.len == 0: result[k].raw = result[k].msg
      result[k].msg = d.msg
      result[k].sev = min(result[k].sev, d.sev)
      if result[k].rule.len == 0: result[k].rule = d.rule
      if result[k].fixes == nil: result[k].fixes = d.fixes
  else:
    for d in web: result.add d
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

proc diagsMake(path: string): seq[Diag] =
  ## builds a file's merged list of problems: the language server's and the build's (without repeats), then the AI
  ## checks'; for Nim files the follow-on errors are dropped; a problem past the last line is moved to the end of the
  ## last line, so the editor, the gutter and F8 can show it
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

var diagsMemo: Table[string, (int, int, int, ref seq[Diag])]   # path → (diagGen, its lines, its last line's
                                                               #   length, the merged problems)

proc diagsShared(path: string): ref seq[Diag] =
  ## a file's problems, from every source, merged — kept while no problem list changed (each frame drew from a fresh
  ## copy, two or three times: thousands of problems copied at every key). Shared: read it, never change it
  let bi = bufIndexByPath(path)
  let n = if bi >= 0: bufs[bi].lines.len else: -1
  let last = if bi >= 0 and n > 0: bufs[bi].lines[^1].len else: -1
  diagsMemo.withValue(path, m):
    if m[][0] == diagGen and m[][1] == n and m[][2] == last: return m[][3]
  if diagsMemo.len > 64: diagsMemo.clear()
  result = new seq[Diag]
  result[] = diagsMake(path)
  diagsMemo[path] = (diagGen, n, last, result)

proc diagsFor(path: string): seq[Diag] =
  ## (a copy of its own: the caller may change it)
  if path.len == 0: return
  diagsShared(path)[]

proc sevColor(sev: int): Rgb =
  ## the theme's colour for a severity: 1 error, 2 warning, 3 information, anything else a hint
  case sev
  of 1: theme.err
  of 2: theme.warn
  of 3: theme.info
  else: theme.hint
