# ── C compiler errors in emitted code: the generated C file (nimcache/@mfile.nim.c) → the line in the .nim ──

var genCLines = initTable[string, (times.Time, seq[string])]()   # generated C files read, with their mtime

proc isNimGenC(path: string): bool =
  let n = extractFilename(path)
  n.endsWith(".nim.c") or n.endsWith(".nim.cpp") or n.endsWith(".nim.m")

proc genCSources(cpath, cwd: string): seq[string] =
  ## the .nim files a generated C file may come from: @mdemo@sutils.nim.c → …/demo/utils.nim
  var n = extractFilename(cpath)
  n = n[0 ..< n.rfind(".nim.") + 4]
  if n.startsWith("@m") or n.startsWith("@p"): n = n[2 .. ^1]
  let rel = n.replace("@s", "/")
  let leaf = "/" & rel
  for x in bufs:
    if x.path.len > 0 and (x.path.endsWith(leaf) or x.path == rel) and x.path notin result: result.add x.path
  for q in [cwd / rel, rootDir / rel, rootDir / "src" / rel]:
    if fileExists(q) and normalizedPath(q) notin result: result.add normalizedPath(q)
  if result.len == 0 and rootDir.len > 0:
    for f in projectFiles():
      let full = if f.isAbsolute: f else: rootDir / f
      if full.endsWith(leaf): result.add full
      if result.len >= 4: break

proc tripleStrings(ls: seq[string]): seq[(int, int, seq[string])] =
  ## the triple-quoted strings of a Nim file: (line, column of the text, its lines)
  var l = 0
  var c = 0
  while l < ls.len:
    let o = ls[l].find("\"\"\"", c)
    if o < 0:
      inc l
      c = 0
      continue
    var body: seq[string]
    var cl = l
    var from0 = o + 3
    var close = -1
    while cl < ls.len:
      close = ls[cl].find("\"\"\"", from0)
      if close >= 0:
        body.add ls[cl][from0 ..< close]
        break
      body.add ls[cl][from0 .. ^1]
      inc cl
      from0 = 0
    if close < 0: return
    result.add (l, o + 3, body)
    l = cl
    c = close + 3
    while c < ls[l].len and ls[l][c] == '"': inc c

proc mapGenC(cpath, cwd: string, cl, cc: int): (string, int, int) =
  ## a line of a generated C file → where it is in the Nim source (an emit's text), or ("", …)
  var cls: seq[string]
  try:
    let mt = getLastModificationTime(cpath)
    if cpath in genCLines and genCLines[cpath][0] == mt: cls = genCLines[cpath][1]
    else:
      if getFileSize(cpath) > 40_000_000: return ("", 0, 0)
      cls = readFile(cpath).splitLines()
      if genCLines.len > 16: genCLines.clear()
      genCLines[cpath] = (mt, cls)
  except CatchableError: return ("", 0, 0)
  if cl < 0 or cl >= cls.len: return ("", 0, 0)
  for src in genCSources(cpath, cwd):
    var ls: seq[string]
    let bi = bufIndexByPath(src)
    if bi >= 0: ls = bufs[bi].lines
    else:
      try: ls = readFile(src).splitLines()
      except CatchableError: continue
    for (l0, c0, body) in tripleStrings(ls):
      # the string's first line with text, found in the C file, and the lines after it matching too
      var k0 = -1
      for k, t in body:
        if t.strip.len > 0:
          k0 = k
          break
      if k0 < 0: continue
      let key = body[k0].strip(leading = false)
      for j in max(0, cl - body.len) .. min(cls.high, cl + k0):
        if cls[j].strip(leading = false) != key: continue
        let base = j - k0                      # the C line of the string's first line
        if cl - base < 0 or cl - base >= body.len: continue
        var same = true
        for t in k0 ..< min(body.len, k0 + 6):
          if base + t >= cls.len or cls[base + t].strip(leading = false) != body[t].strip(leading = false):
            same = false
            break
        if not same: continue
        let k = cl - base
        return (src, l0 + k, (if k == 0: c0 + cc else: cc))
  ("", 0, 0)
