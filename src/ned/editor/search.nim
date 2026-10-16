proc searchTitle() =
  needRender = true

proc addSearchHit(path: string, line, col: int, text: string) =
  if searchCount >= cfgSearchMax: return
  if searchHits.len > 0 and searchHits[^1].path == path and searchHits[^1].line == line: return   # one row per line
  if path != searchLastPath:
    searchLastPath = path
    inc searchFiles
  var t = text.strip
  if t.len > 300: t = t[0 ..< 300]
  searchHits.add SearchHit(path: path, line: line, col: col, text: t)
  inc searchCount
  if searchCount >= cfgSearchMax and searchJob != nil and not searchJob.done:
    killProc(searchJob.pr)

proc stopSearch() =
  if searchJob != nil and not searchJob.done: killProc(searchJob.pr)
  searchJob = nil
  searchBuiltin = false
  searchDone = true

proc searchLine(j: Job, raw: string) =
  if j != searchJob: return
  var line = raw
  if line.endsWith('\r'): line.setLen(line.len - 1)
  if line.len == 0: return
  # ripgrep --vimgrep: path:line:col:text      grep -n: path:line:text
  let parts = line.split(':', 3)
  if parts.len < 3 or not parts[1].allDigits: return
  var path = parts[0]
  if path.startsWith("./"): path = path[2 .. ^1]
  let full = if path.isAbsolute: path else: rootDir / path
  if full in searchSkip: return
  let ln = parseInt(parts[1]) - 1
  var col = 0
  var text = ""
  if parts.len == 4 and parts[2].allDigits:
    col = parseInt(parts[2]) - 1
    text = parts[3]
  else:
    text = parts[2 .. ^1].join(":")
    let sp = findSpans(text, searchQuery, searchCaseS, searchWord, searchRx)
    col = if sp.len > 0: sp[0][0] else: 0
  addSearchHit(full, ln, col, text)
  if (searchCount and 63) == 0: searchTitle()

proc globMatch(pat, s: string): bool =
  ## '*' within a path segment, '**' across segments, '?' one character
  proc go(pi, si: int): bool =
    var p = pi
    var i = si
    while p < pat.len:
      if pat[p] == '*':
        let deep = p + 1 < pat.len and pat[p + 1] == '*'
        var np = p + (if deep: 2 else: 1)
        if deep and np < pat.len and pat[np] == '/': inc np
        for k in i .. s.len:
          if go(np, k): return true
          if k < s.len and s[k] == '/' and not deep: return false
        return false
      if i >= s.len: return false
      if pat[p] != '?' and pat[p] != s[i]: return false
      inc p
      inc i
    i == s.len
  go(0, 0)

proc includeMatch(filter, rel: string): bool =
  ## "files to include" box: comma-separated globs; "*.nim" matches names anywhere, "src/" a folder,
  ## "!tests/" excludes
  if filter.strip.len == 0: return true
  var anyInclude = false
  var included = false
  for raw in filter.split(','):
    var g = raw.strip
    if g.len == 0: continue
    let neg = g[0] == '!'
    if neg: g = g[1 .. ^1].strip
    if g.endsWith("/"): g.add "**"
    let target = if '/' in g: rel else: extractFilename(rel)
    let hit = globMatch(g, target) or ('/' in g and globMatch(g & "/**", rel))
    if neg:
      if hit: return false
    else:
      anyInclude = true
      if hit: included = true
  included or not anyInclude

proc pumpSearch(budgetMs: int) =
  ## built-in fallback when neither ripgrep nor grep exist
  if not searchBuiltin: return
  let t0 = getMonoTime()
  let files = projectFiles()
  while searchIdx < files.len and searchCount < cfgSearchMax:
    let rel = files[searchIdx]
    inc searchIdx
    let path = if rel.isAbsolute: rel else: rootDir / rel
    if path in searchSkip or not includeMatch(searchIncludeRan, relPath(path)): continue
    try:
      if getFileSize(path) <= 3_000_000:
        var l = 0
        for s in lines(path):
          if l == 0 and '\0' in s: break
          let sp = findSpans(s, searchQuery, searchCaseS, searchWord, searchRx)
          if sp.len > 0: addSearchHit(path, l, sp[0][0], s)
          inc l
    except CatchableError: discard
    if msSince(t0) > budgetMs: break
  if (searchIdx >= files.len and not scanning) or searchCount >= cfgSearchMax:
    searchBuiltin = false
    searchDone = true
  searchTitle()

proc wsSearchDirs(): string =
  for r in wsRoots:
    if dirExists(r): result.add " " & quoteShell(r)

proc projectSearch(q: string) =
  ## results go to the Search view of the left dock
  if q.len == 0: return
  if findRegex:
    let err = cachedRegex(q, true)[].err
    if err.len > 0:
      warn("Regular expression: " & err)
      return
  stopSearch()
  searchHits.setLen(0)
  searchCollapsed.clear()
  searchDismissed.clear()
  searchQuery = q
  dockQuery = q
  dockQueryCur = q.len
  dockQueryRan = q
  searchRx = findRegex
  searchWord = findWord
  searchIncludeRan = dockInclude.strip
  searchCaseS = findCase or (not searchRx and q != q.toLowerAscii)
  searchCount = 0
  searchFiles = 0
  searchLastPath = ""
  searchSkip.clear()
  searchDone = false
  showSide(svSearch)
  leftList.sel = 0
  leftList.scroll = 0
  # unsaved buffers are searched in memory so results match what you see
  for b in bufs:
    if b.path.len > 0 and b.dirty:
      searchSkip.incl b.path
      if not includeMatch(searchIncludeRan, relPath(b.path)): continue
      for l, s in b.lines:
        let sp = findSpans(s, q, searchCaseS, searchWord, searchRx)
        if sp.len > 0: addSearchHit(b.path, l, sp[0][0], s)
  var cmd = ""
  if cfgUseRg and findExe("rg").len > 0:
    var globs = ""
    for raw in searchIncludeRan.split(','):
      let g = raw.strip
      if g.len > 0: globs.add "-g " & quoteShell(if g.endsWith("/"): g & "**" elif g.startsWith("!") and g.endsWith("/"): g & "**" else: g) & " "
    cmd = "rg --vimgrep --no-heading --color=never --max-columns=400 --max-columns-preview " &
          (if searchRx: "" else: "--fixed-strings ") & (if searchWord: "-w " else: "") & globs &
          (if searchCaseS: "--case-sensitive" else: "--ignore-case") & " -- " & quoteShell(q) & " ." & wsSearchDirs()
  elif findExe("grep").len > 0 and not searchRx and searchIncludeRan.len == 0:
    var ex = ""
    for d in cfgExclude: ex.add "--exclude-dir=" & quoteShell(d) & " "
    cmd = "grep -rnIF --color=never " & ex & (if searchCaseS: "" else: "-i ") & (if searchWord: "-w " else: "") &
          "-e " & quoteShell(q) & " ." & wsSearchDirs()
  if cmd.len > 0:
    searchJob = startJob(jkSearch, cmd, rootDir, proc(j: Job) =
      if j.partial.len > 0:
        searchLine(j, j.partial)
        j.partial = ""
      if j == searchJob:
        searchDone = true
        searchTitle()
        if searchCount == 0: info("No results for \"" & searchQuery & "\""))
    if searchJob == nil:
      searchBuiltin = true
      searchIdx = 0
  else:
    searchBuiltin = true
    searchIdx = 0
  searchTitle()
