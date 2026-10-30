# ── what the compiler made of a saved file, read from its NIF: Nim 2.4's `nim nif` (run in place of `nim check` on
#    save: the same messages, about the same time — and, for each module without errors, the compiler's reading of
#    it as NIF text) or Nim 3's nimony. Every name there is resolved to its declaration (which overload, what a macro
#    made) and every let and var has its type: the colours, the type hints and Go to definition of a file as saved
#    come from it. A file changed since keeps the engine's answers; a Nim older than 2.4 is checked as before ──

proc nim2NifOn(): bool =
  ## the on-save check of a Nim file is `nim nif`: nim.compilerNif on, the Nim in use 2.4 or newer, not a Nim 3 project
  cfgNimNif and not nim3On() and tcVer.len >= 2 and (tcVer[0] > 2 or (tcVer[0] == 2 and tcVer[1] >= 4))

proc nifCacheBase(): string =
  ## where ned keeps the NIF of the projects it checked (~/.cache/ned/nif), out of the projects themselves
  getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / AppName / "nif"

var nim2NifDirs: seq[string]          # the NIF folders checked in this session, the latest first

proc nim2NifDir(main: string): string =
  ## the folder `nim nif` of a main file writes to (`<name>-<hash of its path>`), made with a note of the main file in
  ## it; of the folders there, the 16 used least recently are removed when a new one is made
  let base = nifCacheBase()
  result = base / (splitFile(main).name & "-" & toHex(uint32(hash(main) and 0xFFFF_FFFF)).toLowerAscii)
  let k = nim2NifDirs.find(result)
  if k != 0:
    if k > 0: nim2NifDirs.delete(k)
    nim2NifDirs.insert(result, 0)
    if nim2NifDirs.len > 8: nim2NifDirs.setLen(8)
  if fileExists(result / "main.txt"): return
  try:
    createDir(result)
    writeFile(result / "main.txt", main)
    var ds: seq[(times.Time, string)]
    for kind, d in walkDir(base):
      if kind == pcDir: ds.add (getLastModificationTime(d), d)
    if ds.len > 16:
      ds.sort(proc(a, b: (times.Time, string)): int = cmp(a[0], b[0]))
      for (_, d) in ds[0 ..< ds.len - 16]:
        if d != result: removeDir(d)
  except CatchableError: discard

proc nim2NifCheckCmd(flags, main: string): string =
  ## the on-save check with Nim 2.4: `nim nif`, the flags of `nim check`, its NIF into ned's folder for the main file
  "nim nif --nimcache:" & quoteShell(nim2NifDir(main)) & flags & " " & quoteShell(main)

var nim2NifMaps: Table[string, (times.Time, Table[string, string])]   # folder → (when read, source file → its NIF)

proc nim2NifMap(dir: string): Table[string, string] =
  ## each NIF of a folder by the source file it is from: the file its first statements name (from the main file's
  ## folder when not absolute) — read again when the folder changed
  var t: times.Time
  try: t = getLastModificationTime(dir)
  except CatchableError: return
  nim2NifMaps.withValue(dir, m):
    if m[][0] == t: return m[][1]
  var mainDir = ""
  try: mainDir = parentDir(readFile(dir / "main.txt").strip)
  except CatchableError: return
  try:
    for kind, f in walkDir(dir):
      if kind != pcFile or not f.endsWith(".nim2.nif"): continue
      var head = ""
      let fh = open(f)
      try:
        var ln = ""
        var k = 0
        while k < 10 and fh.readLine(ln):
          if ln.contains("(stmts"):
            head = ln
            break
          inc k
      finally: fh.close()
      # (`(stmts@,1,app.nim`: the second comma's file)
      let a = head.find(',', head.find("(stmts"))
      if a < 0: continue
      let c = head.find(',', a + 1)
      if c < 0: continue
      var e = c + 1
      while e < head.len and head[e] notin {' ', '(', ')'}: inc e
      let rel = head[c + 1 ..< e]
      if rel.len == 0: continue
      result[normalizedPath(if rel.isAbsolute: rel else: mainDir / rel)] = f
  except CatchableError: discard
  if nim2NifMaps.len > 32: nim2NifMaps.clear()
  nim2NifMaps[dir] = (t, result)

proc nim2NifFor(path: string): string =
  ## the newest NIF `nim nif` made of a file: in the folder of its own check, of the module that includes it, or of
  ## a project checked in this session that imports it — "" none
  var dirs: seq[string]
  for m in [path, nxTopIncluder(path)]:
    if m.len > 0:
      let d = nifCacheBase() / (splitFile(m).name & "-" & toHex(uint32(hash(m) and 0xFFFF_FFFF)).toLowerAscii)
      if d notin dirs: dirs.add d
  for d in nim2NifDirs:
    if d notin dirs: dirs.add d
  var bestT: times.Time
  for d in dirs:
    if not dirExists(d): continue
    let f = nim2NifMap(d).getOrDefault(normalizedPath(path))
    if f.len == 0: continue
    try:
      let t = getLastModificationTime(f)
      if result.len == 0 or t > bestT: (result, bestT) = (f, t)
    except CatchableError: discard

# ── the declarations of other modules: their NIF read for its `(tag :symbol` pairs only ──

var nifDeclMemo: Table[string, (times.Time, Table[string, string])]   # NIF → (when read, module symbol → its tag)

proc nifDecls(nif: string): Table[string, string] =
  ## the module-level declarations of a NIF (symbols with a module part: `show.0.utierkx2a`) and the tag declaring each
  ## (proc, type, fld, const …), found without reading it as a tree
  var t: times.Time
  try: t = getLastModificationTime(nif)
  except CatchableError: return
  nifDeclMemo.withValue(nif, m):
    if m[][0] == t: return m[][1]
  var text = ""
  try: text = readFile(nif)
  except CatchableError: return
  var i = 0
  var tag = ""
  while i < text.len:
    let c = text[i]
    if c == '(':
      var e = i + 1
      while e < text.len and text[e] in {'a'..'z', 'A'..'Z', '0'..'9', '_', '.'}: inc e
      tag = text[i + 1 ..< e]
      i = e
    elif c == ':' and i > 0 and text[i - 1] in {' ', '\n', '\t'}:
      var e = i + 1
      while e < text.len and text[e] notin {' ', '\n', '\t', '(', ')', '@', '~', '"'}: inc e
      let sym = text[i + 1 ..< e]
      if sym.count('.') >= 2 and not sym.endsWith("."): result[sym] = tag
      tag = ""
      i = e
    elif c == '"':
      inc i
      while i < text.len and text[i] != '"': inc i
      inc i
    elif c in {' ', '\n', '\t'}: inc i
    else:
      if c notin {'@', '~', ',', ')'} and c notin Digits: tag = ""      # (an atom between: no longer its tag's first)
      inc i
  if nifDeclMemo.len > 64: nifDeclMemo.clear()
  nifDeclMemo[nif] = (t, result)

func nifModuleOf(sym: string): string =
  ## the module part of a symbol (`show.0.utierkx2a` → utierkx2a), "" for a local one (`x.0`)
  let a = sym.find('.')
  if a < 0: return ""
  let b = sym.find('.', a + 1)
  if b < 0: "" else: sym[b + 1 .. ^1]

proc nifForeignNif(ownNif, module: string, nim2: bool): string =
  ## the NIF of another module, beside this one's: `<module>.<project>.nim2.nif` (Nim 2.4), `<module>.s.nif` (nimony)
  let dir = parentDir(ownNif)
  if not nim2: return (if fileExists(dir / module & ".s.nif"): dir / module & ".s.nif" else: "")
  let name = extractFilename(ownNif)
  let parts = name.split('.')
  if parts.len < 4: return ""
  let f = dir / module & "." & parts[1] & ".nim2.nif"
  if fileExists(f): f else: ""

# ── a file's facts from its NIF ──

type NifFacts = ref object
  stamp: string                              # the source file's stamp they are for
  nif: string
  nifTime: times.Time
  kinds: Table[int, Table[string, TokKind]]  # line → a name as Nim compares it → its colour (tkText: not one colour)
  hints: Table[int, seq[(string, string)]]   # line → (a let or var declared there, its type as Nim writes it)
  uses: Table[int, seq[(string, string)]]    # line → (a name as Nim compares it, the symbol it is), in the NIF's order
  defs: Table[string, (string, int, int)]    # this module's symbol → (its file, line, column)

func nifTagKind(tag: string, top: bool): TokKind =
  ## a declaration's colour: routines, templates and macros, types, fields, enum values and constants, parameters,
  ## the module's own lets and vars (a local var: one that can change)
  case tag
  of "proc", "func", "iterator", "converter", "method": tkFunc
  of "template", "macro": tkPreproc
  of "type": tkType
  of "fld": tkProperty
  of "efld", "const", "gconst": tkConst
  of "param": tkParam
  of "gvar", "tvar": tkGlobalVar
  of "glet", "tlet": tkGlobal
  of "var": (if top: tkGlobalVar else: tkMutable)
  of "let": (if top: tkGlobal else: tkText)
  else: tkText

proc nifTypeText(ns: seq[NifNode], i: int, nimony: bool): string =
  ## a type of the NIF as Nim writes it (`seq[string]`, `Table[string, int]`, `ref Node`) — "" for a form not known here
  if i < 0 or i >= ns.len: return ""
  let n = ns[i]
  if n.tag.len == 0:
    let nm = nifSymName(n.atom)
    if nm.len == 0 or nm[0] notin IdentStartChars or '`' in n.atom or '.' notin n.atom: return ""
    return nm
  var kids: seq[int]
  for j in i + 1 ..< min(ns.len, i + 4000):
    if ns[j].depth <= n.depth: break
    if ns[j].parent == i: kids.add j
  template num(k: int): int =
    ## the k-th part as a number (-2 when it is not one)
    (try: parseInt(ns[kids[k]].atom) except ValueError: -2)
  case n.tag
  of "i", "u":
    if kids.len != 1: return ""
    let bits = num(0)
    let base = if n.tag == "i": "int" else: "uint"
    if bits == -1 or (nimony and bits == 64): base elif bits in [8, 16, 32, 64]: base & $bits else: ""
  of "f":
    if kids.len != 1: return ""
    let bits = num(0)
    if bits == 64 or bits == -1: "float" elif bits == 32: "float32" else: ""
  of "c": (if kids.len == 1 and num(0) == 8: "char" else: "")
  of "bool": "bool"
  of "ref", "ptr":
    if kids.len != 1: return ""
    let t = nifTypeText(ns, kids[0], nimony)
    if t.len > 0: n.tag & " " & t else: ""
  of "at":
    if kids.len < 2: return ""
    var head = kids[0]
    if ns[head].tag == "gbody":
      # (a generic's body: its name is its last part)
      var last = -1
      for j in head + 1 ..< ns.len:
        if ns[j].depth <= ns[head].depth: break
        if ns[j].parent == head: last = j
      head = last
    let h = nifTypeText(ns, head, nimony)
    if h.len == 0: return ""
    var args: seq[string]
    for k in kids[1 .. ^1]:
      let a = nifTypeText(ns, k, nimony)
      if a.len == 0: return ""
      args.add a
    h & "[" & args.join(", ") & "]"
  of "array":
    if kids.len != 2 or ns[kids[1]].tag != "range": return ""
    let el = nifTypeText(ns, kids[0], nimony)
    var bounds: seq[string]
    for j in kids[1] + 1 ..< ns.len:
      if ns[j].depth <= ns[kids[1]].depth: break
      if ns[j].parent == kids[1] and ns[j].tag.len == 0: bounds.add ns[j].atom
    if el.len == 0 or bounds.len != 2: return ""
    "array[" & bounds[0] & ".." & bounds[1] & ", " & el & "]"
  else: ""

var nifFactsMemo: Table[string, NifFacts]    # file → its facts
var nifFactsLooked: Table[string, MonoTime]  # (a file's NIF looked for: at most every 3 s)

proc nifFactsBuild(path, nif: string, nim2: bool): NifFacts =
  ## reads a file's NIF: the colour of each name on each line (by this module's declarations, and the other modules'
  ## from their NIF), the types of the lets and vars, which symbol each name is, where this module declares each
  result = NifFacts()
  var nodes: seq[NifNode]
  try: nodes = nifParse(readFile(nif).splitLines, before = nim2)
  except CatchableError: return
  let mainDir = if nim2: (try: parentDir(readFile(parentDir(nif) / "main.txt").strip) except CatchableError: "")
                else: ""
  var sameFile: Table[string, bool]
  proc here(f: string): bool =
    ## whether a file the NIF names is this one
    if f.len == 0: return false
    sameFile.withValue(f, v): return v[]
    let p = if f.isAbsolute: f elif nim2: normalizedPath(mainDir / f) else: nifSourcePath(nif, f)
    result = p == path or (p.len > 0 and path.endsWith("/" & f) and not nim2)
    sameFile[f] = result
  # this module's declarations: their tag, and whether at the top
  var own: Table[string, TokKind]
  for i, n in nodes:
    if not n.isDef or n.parent < 0: continue
    let d = nodes[n.parent]
    let top = d.parent >= 0 and nodes[d.parent].tag == "stmts" and nodes[d.parent].depth == 0
    let k = nifTagKind(d.tag, top)
    own[n.atom] = k
    if here(n.file) and n.sline >= 0: result.defs[n.atom] = (path, n.sline, n.scol)
    # a let or var: its type (the fourth thing in it)
    if d.tag in ["let", "var", "glet", "gvar", "tlet", "tvar"] and here(n.file) and n.sline >= 0:
      var kids: seq[int]
      for j in n.parent + 1 ..< min(nodes.len, n.parent + 4000):
        if nodes[j].depth <= d.depth: break
        if nodes[j].parent == n.parent: kids.add j
        if kids.len > 3: break
      if kids.len > 3 and kids[0] == i:
        let t = nifTypeText(nodes, kids[3], not nim2)
        if t.len > 0: result.hints.mgetOrPut(n.sline, @[]).add (nifSymName(n.atom), t)
  # the other modules' declarations, for the symbols used here
  var foreign: Table[string, Table[string, string]]
  proc kindOf(sym: string): TokKind =
    ## a symbol's colour: declared here, else by the NIF of its module
    if sym in own: return own[sym]
    let m = nifModuleOf(sym)
    if m.len == 0: return tkText
    if m notin foreign:
      let f = nifForeignNif(nif, m, nim2)
      foreign[m] = if f.len > 0: nifDecls(f) else: initTable[string, string]()
    let tag = foreign[m].getOrDefault(sym)
    if tag.len == 0: tkText else: nifTagKind(tag, true)
  for n in nodes:
    if n.tag.len > 0 or n.atom.len == 0 or n.sline < 0 or '.' notin n.atom: continue
    let name = nifSymName(n.atom)
    if name.len == 0 or name[0] notin IdentStartChars or '`' in n.atom or not here(n.file): continue
    let w = nxNorm(name)
    if not n.isDef: result.uses.mgetOrPut(n.sline, @[]).add (w, n.atom)
    let k = kindOf(n.atom)
    let row = addr result.kinds.mgetOrPut(n.sline, initTable[string, TokKind]())
    row[].withValue(w, old):
      if old[] != k: old[] = tkText                 # (two things of one name on a line: neither colour)
    do: row[][w] = k

proc nifFactsFor(b: Buffer): NifFacts =
  ## the compiler's facts about the buffer's file, when the buffer is the file as saved and the NIF was made after the
  ## save (Nim 2.4's `nim nif`, or nimony with Nim 3) — nil otherwise. The NIF is looked for at most every 3 s a file
  if b.path.len == 0 or b.dirty or b.lang == nil or b.lang.mode != lmNim or not b.path.endsWith(".nim"): return nil
  let nim3 = nim3On()
  if not nim3 and not nim2NifOn(): return nil
  let st = nxStamp(b.path)
  let old = nifFactsMemo.getOrDefault(b.path)
  let recent = msSince(nifFactsLooked.getOrDefault(b.path)) < 3000
  if old != nil and old.stamp == st and recent: return old
  if recent: return nil
  if nifFactsLooked.len > 200: nifFactsLooked.clear()
  nifFactsLooked[b.path] = getMonoTime()
  let nif = if nim3: nifFileFor(b.path) else: nim2NifFor(b.path)
  if nif.len == 0 or not (nif.endsWith(".s.nif") or nif.endsWith(".nim2.nif")): return nil
  var t, srcT: times.Time
  try:
    t = getLastModificationTime(nif)
    srcT = getLastModificationTime(b.path)
  except CatchableError: return nil
  if t < srcT: return nil                      # (made before the last save: its places are not this text's)
  if old != nil and old.nif == nif and old.nifTime == t:
    old.stamp = st
    return old
  if nifFactsMemo.len > 32: nifFactsMemo.clear()
  result = nifFactsBuild(b.path, nif, not nim3)
  (result.stamp, result.nif, result.nifTime) = (st, nif, t)
  nifFactsMemo[b.path] = result
  needRender = true

proc nifTypeHints(b: Buffer, line: int): seq[(int, string)] =
  ## the types the compiler gave the lets and vars declared on a line, each after its name (`: seq[string]`) — not
  ## for a name with its type written, nor a value whose type shows (a number, a string)
  if not cfgInlayHints or line >= b.lines.len: return
  let fx = nifFactsFor(b)
  if fx == nil or line notin fx.hints: return
  let s = b.lines[line]
  for (name, t) in fx.hints[line]:
    let w = nxNorm(name)
    var i = 0
    while i < s.len:
      if s[i] in IdentStartChars and (i == 0 or s[i - 1] notin IdentChars):
        var j = i
        while j < s.len and s[j] in IdentChars: inc j
        if nxNorm(s[i ..< j]) == w:
          var e = j
          if e < s.len and s[e] == '*': inc e
          var q = e
          while q < s.len and s[q] == ' ': inc q
          if q < s.len and s[q] in {':', '{'}: break        # (its type written, or pragmas: as the engine does)
          if q < s.len and s[q] == '=':
            var v = q + 1
            while v < s.len and s[v] == ' ': inc v
            if v < s.len and (s[v] in Digits or s[v] in {'"', '\''}): break
          result.add (e, ": " & t)
          break
        i = j
      else: inc i

proc nifHasHints(b: Buffer, line: int): bool =
  ## whether the compiler's NIF has a type for a let or var of this line (it is drawn even without the engine's hints)
  let fx = nifFactsFor(b)
  fx != nil and line in fx.hints

proc nimNifDefinition(b: Buffer, p: Pos): bool =
  ## Go to definition by the compiler's reading of the saved file: the symbol the name at the cursor is (the n-th of
  ## that name on the line is the n-th the NIF names there), then where its module's NIF declares it
  let fx = nifFactsFor(b)
  if fx == nil or p.line notin fx.uses: return false
  let s = b.lines[p.line]
  var a = min(p.col, s.len)
  while a > 0 and s[a - 1] in IdentChars: dec a
  var e = a
  while e < s.len and s[e] in IdentChars: inc e
  if a == e or s[a] notin IdentStartChars: return false
  let w = nxNorm(s[a ..< e])
  # (which of the names so written on the line it is)
  var nth = 0
  var i = 0
  while i < a:
    if s[i] in IdentStartChars and (i == 0 or s[i - 1] notin IdentChars):
      var j = i
      while j < s.len and s[j] in IdentChars: inc j
      if nxNorm(s[i ..< j]) == w: inc nth
      i = j
    else: inc i
  var syms: seq[string]
  for (u, sym) in fx.uses[p.line]:
    if u == w and sym notin syms: syms.add sym
  var all: seq[string]
  for (u, sym) in fx.uses[p.line]:
    if u == w: all.add sym
  if syms.len == 0: return false
  let sym = if syms.len == 1: syms[0] elif nth < all.len: all[nth] else: ""
  if sym.len == 0: return false
  var target: (string, int, int)
  if sym in fx.defs: target = fx.defs[sym]
  else:
    let m = nifModuleOf(sym)
    if m.len == 0: return false
    let nim2 = fx.nif.endsWith(".nim2.nif")
    let f = nifForeignNif(fx.nif, m, nim2)
    if f.len == 0: return false
    var ns: seq[NifNode]
    try: ns = nifParse(readFile(f).splitLines, before = nim2)
    except CatchableError: return false
    let mainDir = if nim2: (try: parentDir(readFile(parentDir(f) / "main.txt").strip) except CatchableError: "")
                  else: ""
    var found = false
    for n in ns:
      if n.isDef and n.atom == sym and n.sline >= 0 and n.file.len > 0:
        let src = if n.file.isAbsolute: n.file elif nim2: normalizedPath(mainDir / n.file) else: nifSourcePath(f, n.file)
        if src.len == 0 or not fileExists(src): return false
        target = (src, n.sline, n.scol)
        found = true
        break
    if not found: return false
  pushJump()
  let nb = if target[0] == b.path: b else: openFile(target[0])
  if nb != nil: nb.centerOn(nb.clampPos(Pos(line: target[1], col: target[2])))
  true

proc nifForget() =
  ## (another folder opened) the facts read from NIFs go
  nifFactsMemo.clear(); nifFactsLooked.clear(); nifDeclMemo.clear(); nim2NifMaps.clear(); nim2NifDirs.setLen(0)
