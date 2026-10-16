# ── completion: header names, and C names for importc ──

var cHeaderNamesCache: Table[string, seq[string]]

proc cHeaderNames(dirs: seq[string], angle: bool): seq[string] =
  let key = $angle & dirs.join("|")
  if angle and key in cHeaderNamesCache: return cHeaderNamesCache[key]
  defer:
    if angle: cHeaderNamesCache[key] = result
  var seen: HashSet[string]
  for d in dirs:
    try:
      for k, f in walkDir(d, relative = true):
        if k == pcFile and (f.endsWith(".h") or f.endsWith(".hpp")):
          if f notin seen:
            seen.incl f
            result.add f
        elif k in {pcDir, pcLinkToDir} and angle and not f.startsWith(".") and seen.len < 6000:
          for k2, f2 in walkDir(d / f, relative = true):
            if k2 == pcFile and f2.endsWith(".h") and (f / f2) notin seen:
              seen.incl f / f2
              result.add f / f2
    except OSError: discard
    if seen.len > 8000: break

proc cNamesIn(header: string, dirs: seq[string], fromDir: string): seq[string] =
  ## the functions, macros and variables a header declares (itself, not what it includes)
  let hp = cFindHeader(header, dirs, fromDir)
  if hp.len == 0: return
  for n, d in cHeaderIndex(hp).decls:
    if d.kind in ["function", "macro", "variable"] and not n.startsWith("_"): result.add n
  result.sort()

proc pragmaStringComplete(b: Buffer, p: Pos, manual: bool): bool =
  ## inside header: "…" — header names; inside importc: "…" — the C names in that header
  if b.lang == nil or b.lang.mode != lmNim: return false
  let s = b.lines[p.line]
  if p.col > s.len or p.col == 0: return false
  let q = s.rfind('"', last = p.col - 1)
  if q < 0: return false
  var quotes = 0
  for z in 0 ..< q:
    if s[z] == '"': inc quotes
  if quotes mod 2 == 1: return false
  var k = q - 1
  while k >= 0 and s[k] == ' ': dec k
  if k < 0 or s[k] != ':': return false
  dec k
  while k >= 0 and s[k] == ' ': dec k
  var a = k
  while a >= 0 and s[a] in IdentChars: dec a
  let key = s[a + 1 .. k]
  if key notin ["header", "importc", "importcpp"]: return false
  if s.find("{.") < 0 and not (p.line > 0 and "{." in b.lines[p.line - 1]): return false
  let prefix = s[q + 1 ..< p.col]
  let dirs = cIncludeDirs(b.path, b.lines)
  var items: seq[CompItem]
  if key == "header":
    let angle = prefix.startsWith("<")
    let names = if angle: cHeaderNames(cSystemIncludeDirs(), true)
                else: cHeaderNames(@[parentDir(b.path)] & (if rootDir.len > 0: @[rootDir] else: @[]), false)
    for n in names:
      let lbl = if angle: "<" & n & ">" else: n
      items.add CompItem(label: lbl, insert: lbl, detail: "header", kind: 17, filter: lbl, sortText: lbl, rank: 1)
  else:
    # the header of this declaration: on its lines, else the nearest one above (then below)
    proc headerIn(t: string): string =
      let h = t.find("header:")
      if h < 0: return ""
      let q1 = t.find('"', h)
      let q2 = if q1 >= 0: t.find('"', q1 + 1) else: -1
      if q2 > q1: t[q1 + 1 ..< q2] else: ""
    # the headers this file names: this declaration's own first, then the nearest ones
    var hdrs: seq[string]
    let own = headerIn(b.lines[p.line])
    if own.len > 0: hdrs.add own
    elif p.line + 1 < b.lines.len and not b.lines[p.line].contains(".}"):
      let nx = headerIn(b.lines[p.line + 1])
      if nx.len > 0: hdrs.add nx
    if hdrs.len == 0:
      for dist in 1 .. b.lines.len:
        for l in [p.line - dist, p.line + dist]:
          if l < 0 or l >= b.lines.len: continue
          let h = headerIn(b.lines[l])
          if h.len > 0 and h notin hdrs: hdrs.add h
        if hdrs.len >= 4 or (p.line - dist < 0 and p.line + dist >= b.lines.len): break
    if hdrs.len == 0: return false
    var seenNames: HashSet[string]
    for hdr in hdrs:
      for n in cNamesIn(hdr, dirs, parentDir(b.path)):
        if n in seenNames: continue
        seenNames.incl n
        items.add CompItem(label: n, insert: n, detail: hdr, kind: 3, filter: n, sortText: n, rank: 1)
  if items.len == 0: return false
  compLine = p.line
  compStartCol = q + 1
  compManual = manual
  compNx.setLen(0)
  compItems = items
  compFromLsp = true
  refilterComp()
  true
