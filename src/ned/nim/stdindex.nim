# ── Nim: an index of what the standard library exports (for "import std/…" quick fixes) ──

var
  nimIndex = initTable[string, seq[string]]()
  nimIndexLoaded = false

proc nimLibDir(): string =
  let nim = findExe("nim")
  var cands: seq[string]
  if nim.len > 0:
    var real = nim
    try: real = expandFilename(nim)
    except CatchableError: discard
    let root = parentDir(parentDir(real))
    cands.add root / "lib"
    cands.add root / "lib" / "nim"
  cands.add getEnv("PREFIX") / "lib" / "nim"
  cands.add "/usr/lib/nim"
  cands.add "/usr/lib/nim/lib"
  cands.add "/usr/local/lib/nim"
  for c in cands:
    if c.len > 1 and fileExists(c / "system.nim"): return c
  ""

proc scanNimExports(path: string, into: var Table[string, seq[string]], module: string) =
  var section = false
  try:
    for line in lines(path):
      if line.len == 0: continue
      if line[0] notin {' ', '#'}:
        section = false
        var kw = ""
        for k in ["proc ", "func ", "template ", "macro ", "iterator ", "converter ", "method "]:
          if line.startsWith(k):
            kw = k
            break
        if kw.len > 0:
          var i = kw.len
          var name = ""
          if i < line.len and line[i] == '`':
            let e = line.find('`', i + 1)
            if e > i: name = line[i + 1 ..< e]
            i = e + 1
          else:
            while i < line.len and line[i] in IdentChars:
              name.add line[i]
              inc i
          if name.len > 0 and i < line.len and line[i] == '*':
            let lst = addr into.mgetOrPut(name, @[])
            if module notin lst[]: lst[].add module
        elif line.strip in ["type", "const", "let", "var"]: section = true
      elif section and line.len > 3 and line[0 .. 1] == "  " and line[2] in IdentStartChars:
        var i = 2
        var name = ""
        while i < line.len and line[i] in IdentChars:
          name.add line[i]
          inc i
        if i < line.len and line[i] == '*':
          let lst = addr into.mgetOrPut(name, @[])
          if module notin lst[]: lst[].add module
  except CatchableError: discard

proc loadNimIndex() =
  if nimIndexLoaded: return
  nimIndexLoaded = true
  let lib = nimLibDir()
  if lib.len == 0: return
  let cache = stateDir() / "nimindex.json"
  let stamp = lib & "|" & $fileStamp(lib / "system.nim")[0]
  try:
    if fileExists(cache):
      let j = parseFile(cache)
      if j{"stamp"}.getStr == stamp:
        for k, v in (if j{"names"} != nil and j["names"].kind == JObject: j["names"] else: newJObject()):
          var ms: seq[string]
          for m in jitems(v): ms.add m.getStr
          nimIndex[k] = ms
        return
  except CatchableError: discard
  for sub in ["pure", "pure/collections", "pure/concurrency", "std", "core", "impure"]:
    let d = lib / sub
    if not dirExists(d): continue
    for kind, p in walkDir(d):
      if kind != pcFile or not p.endsWith(".nim"): continue
      let name = splitFile(p).name
      if name.startsWith("_") or name in ["nimprof", "coro"]: continue
      scanNimExports(p, nimIndex, "std/" & name)
  try:
    var names = newJObject()
    for k, v in nimIndex: names[k] = %v
    createDir(stateDir())
    writeFileSafe(cache, $(%*{"stamp": stamp, "names": names}))
  except CatchableError: discard

proc stdNamesStarting(lp: string): seq[(string, seq[string])] =
  ## standard-library exports whose name starts with `lp` (lower case), and the modules exporting them
  loadNimIndex()
  for name, ms in nimIndex:
    if name.len >= lp.len and name.toLowerAscii.startsWith(lp): result.add (name, ms)
  result.sort(proc(a, b: (string, seq[string])): int = cmp(a[0].len, b[0].len))

func quotedName(msg: string): string =
  ## 'foo' in a compiler message
  let a = msg.find('\'')
  if a < 0: return ""
  let e = msg.find('\'', a + 1)
  if e < 0: return ""
  msg[a + 1 ..< e]

proc importStmts(b: Buffer): seq[(int, int)] =
  ## top-level import/from/include statements as (first line, last line) — they may span lines
  var l = 0
  while l < min(b.lines.len, 400):
    let t = b.lines[l]
    if t.startsWith("import ") or t.startsWith("from ") or t.startsWith("include "):
      var e = l
      var depth = 0
      while e < b.lines.len:
        var code = b.lines[e]
        let h = code.find('#')
        if h >= 0: code = code[0 ..< h]
        depth += code.count('[') - code.count(']')
        let c = code.strip
        if depth <= 0 and not c.endsWith(",") and not (e == l and c.endsWith("import")): break
        inc e
      e = min(e, b.lines.high)
      result.add (l, e)
      l = e + 1
    else: inc l

proc importedModulesOf(stmt: string): seq[string] =
  ## the modules one `import` statement names, as written (std/[a, b] → std/a, std/b)
  var t = stmt.strip
  if t.startsWith("import "): t = t[7 .. ^1]
  var prefix = ""
  var i = 0
  var flat: seq[string]
  while i < t.len:
    if t[i] == '[':
      let e = t.find(']', i)
      let inner = if e > i: t[i + 1 ..< e] else: ""
      for m in inner.split(','):
        if m.strip.len > 0: flat.add prefix.strip & m.strip
      prefix = ""
      i = (if e > i: e + 1 else: t.len)
    elif t[i] == ',':
      if prefix.strip.len > 0: flat.add prefix.strip
      prefix = ""
      inc i
    else:
      prefix.add t[i]
      inc i
  if prefix.strip.len > 0: flat.add prefix.strip
  flat

proc isStdModule(m: string): bool =
  ## is a bare module name (os, strutils) one of the standard library's?
  let lib = nimLibDir()
  if lib.len == 0: return false
  for sub in ["pure", "pure/collections", "pure/concurrency", "std", "core", "impure", ""]:
    if fileExists(lib / sub / m & ".nim"): return true

proc importedModules(b: Buffer): HashSet[string] =
  ## the modules a file imports (their last path part: tables for std/tables)
  result = initHashSet[string]()
  for (l, le) in b.importStmts():
    var t = ""
    for k in l .. le: t.add " " & b.lines[k].split('#')[0]
    t = t.strip
    if t.startsWith("from "):
      let parts = t[5 .. ^1].splitWhitespace()
      if parts.len > 0: result.incl parts[0].split('/')[^1]
      continue
    if t.startsWith("import "): t = t[7 .. ^1]
    elif t.startsWith("include "): continue
    # std/[a, b], pkg/x, ./y, z as w
    var flat = ""
    var prefix = ""
    var i = 0
    while i < t.len:
      if t[i] == '[':
        let e = t.find(']', i)
        let inner = if e > i: t[i + 1 ..< e] else: ""
        for m in inner.split(','): flat.add "," & prefix & m.strip
        prefix = ""
        i = (if e > i: e + 1 else: t.len)
      elif t[i] == ',':
        flat.add "," & prefix
        prefix = ""
        inc i
      else:
        prefix.add t[i]
        inc i
    flat.add "," & prefix
    for m in flat.split(','):
      let w = m.strip.split(" as ")[0].strip
      if w.len > 0 and not w.endsWith("/"): result.incl w.split('/')[^1]

proc addImport(b: Buffer, module: string) =
  ## import std/x — into an existing `import std/[…]` list when there is one
  if not b.canEdit(): return
  let short = module.split('/')[^1]
  for (l, le) in b.importStmts():
    let t = b.lines[l]
    let lb = t.find("std/[")
    if module.startsWith("std/") and le == l and t.startsWith("import ") and lb >= 0 and t.endsWith("]"):
      let inner = t[lb + 5 ..< t.len - 1]
      for m in inner.split(','):
        if m.strip == short:
          info(module & " is already imported")
          return
      b.beginEdit()
      discard b.replaceText(Pos(line: l, col: t.len - 1), Pos(line: l, col: t.len - 1), ", " & short)
      b.endEdit()
      info("Added " & short & " to the import on line " & $(l + 1))
      return
  let ls = b.importStmts()
  var at = 0
  if ls.len > 0: at = ls[^1][1] + 1
  else:
    while at < b.lines.len and (b.lines[at].startsWith("#") or b.lines[at].strip.len == 0) and at < 50: inc at
    if at >= b.lines.len or at >= 50: at = 0
  b.beginEdit()
  discard b.replaceText(Pos(line: at, col: 0), Pos(line: at, col: 0), "import " & module & "\n")
  b.endEdit()
  info("Added: import " & module)

proc removeImport(b: Buffer, module: string): bool =
  ## drop `module` from the import lists (the line goes when it was the only one)
  if not b.canEdit(): return false
  let short = module.split('/')[^1]
  for (l, le) in b.importStmts():
    let t = b.lines[l]
    if not t.startsWith("import "): continue
    var whole = ""
    for k in l .. le:
      var x = b.lines[k]
      let hh = x.find('#')
      if hh >= 0 and k < le: x = x[0 ..< hh]
      whole.add (if k == l: x else: " " & x.strip)
    var body = whole[7 .. ^1]
    var comment = ""
    let h = body.find(" #")
    if h >= 0:
      comment = body[h .. ^1]
      body = body[0 ..< h]
    # split on commas outside brackets
    var parts: seq[string]
    var depth = 0
    var cur = ""
    for c in body:
      if c == '[': inc depth
      elif c == ']': dec depth
      if c == ',' and depth == 0:
        parts.add cur.strip
        cur = ""
      else: cur.add c
    if cur.strip.len > 0: parts.add cur.strip
    var changed = false
    var keep: seq[string]
    for p in parts:
      let lb = p.find('[')
      if lb >= 0 and p.endsWith("]"):
        let pre = p[0 ..< lb]
        var inner: seq[string]
        for m in p[lb + 1 ..< p.len - 1].split(','):
          if m.strip == short or m.strip.split('/')[^1] == short: changed = true
          elif m.strip.len > 0: inner.add m.strip
        if inner.len == 1: keep.add pre & inner[0]
        elif inner.len > 1: keep.add pre & "[" & inner.join(", ") & "]"
      else:
        let nm = p.split(' ')[0]
        if nm == short or nm.split('/')[^1] == short: changed = true
        else: keep.add p
    if not changed: continue
    b.beginEdit()
    if keep.len == 0:
      if le < b.lines.high: discard b.replaceText(Pos(line: l, col: 0), Pos(line: le + 1, col: 0), "")
      else: discard b.replaceText(Pos(line: l, col: 0), Pos(line: le, col: b.lines[le].len), "")
    else:
      discard b.replaceText(Pos(line: l, col: 0), Pos(line: le, col: b.lines[le].len),
                            "import " & keep.join(", ") & comment)
    b.endEdit()
    return true
  false

proc importAct(id: int, module: string): Action =
  result = proc() =
    let b = bufById(id)
    if b != nil: addImport(b, module)

proc removeImportAct(id: int, module: string): Action =
  result = proc() =
    let b = bufById(id)
    if b != nil:
      if b.removeImport(module): info("Removed the unused import " & module)
      else: info("Could not find the import of " & module)

proc projectModulesExporting(b: Buffer, name: string): seq[string] =
  ## the project's own modules that export `name`, as this file would import them (./x, ../lib/y)
  if rootDir.len == 0 or b.path.len == 0 or name.len == 0: return
  let want = nxNorm(name)
  let here = parentDir(b.path)
  var n = 0
  let t0 = getMonoTime()
  try:
    for f in projectFiles():
      if not f.endsWith(".nim"): continue
      let full = if f.isAbsolute: f else: rootDir / f
      if full == b.path: continue
      inc n
      if n > 800 or msSince(t0) > 1500: break
      let g = nxLoad(full)
      if g == nil: continue
      for s in g.syms:
        if s.exported and not s.local and nxNorm(s.name) == want:
          var rel = relativePath(full.changeFileExt(""), here).replace('\\', '/')
          if not rel.startsWith(".."): rel = "./" & rel
          if rel notin result: result.add rel
          break
      if result.len >= 4: break
  except CatchableError as e: internalError("Nim index", e)
