# ── C in {.emit.}: completion, hover and F12 with no language server (headers read by ned itself). C++ in an emit
#    (the C++ backend's): ned's C engine reading it as C++ — classes, methods, namespaces, templates ──

const CKeywords = ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
                   "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return",
                   "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
                   "volatile", "while", "bool", "true", "false", "NULL", "size_t", "ssize_t", "ptrdiff_t",
                   "intptr_t", "uintptr_t", "int8_t", "int16_t", "int32_t", "int64_t", "uint8_t", "uint16_t",
                   "uint32_t", "uint64_t"]

proc emitBlocks(ls: seq[string]): seq[(int, int, seq[string])] =
  ## the triple-quoted strings of {.emit: """…""".} (also in emit's array form): line, column, text lines
  var any = false
  for l in ls:
    if "emit" in l:
      any = true
      break
  if not any: return
  for (l, c, body) in tripleStrings(ls):
    let pre = ls[l][0 ..< max(0, c - 3)]
    let ps = pre.strip
    if "emit" in pre or ((ps.len == 0 or ps in ["[", "(", "{.", "{.emit:"] or ps.endsWith(",")) and l > 0 and
       "emit" in ls[l - 1]):
      result.add (l, c, body)

proc emitCode(ls: seq[string]): string =
  ## the file with all but its emitted C blanked (comments too): lines and columns stay the file's own
  let blocks = emitBlocks(ls)
  if blocks.len == 0: return ""              # (no C here: nothing to blank, line by line)
  var outL = newSeq[string](ls.len)
  for (l, c, body) in blocks:
    for k, t in body:
      if l + k < outL.len: outL[l + k] = (if k == 0: spaces(c) & t else: t)
  result = outL.join("\n")
  cBlank(result)

var emitIdxCache: Table[int, (int, CIndex)]               # buffer id → (its changeId, the index)
var emitFileIdx: Table[string, (times.Time, CIndex)]      # other files, by mtime

proc emitIndexOf(path: string, lines: seq[string]): CIndex =
  ## the C index of what the lines emit (everything but the emitted C blanked out first), not kept anywhere
  cIndexOf(emitCode(lines), path)

proc emitIndex(b: Buffer): CIndex =
  ## what this file's emitted C declares (lines are the file's)
  if b.id in emitIdxCache and emitIdxCache[b.id][0] == b.changeId: return emitIdxCache[b.id][1]
  result = emitIndexOf(b.path, b.lines)
  if emitIdxCache.len > 64: emitIdxCache.clear()
  emitIdxCache[b.id] = (b.changeId, result)

proc emitIndexOfFile(path: string): CIndex =
  ## the index of the C a Nim file emits: from its open buffer when it is open, else read from disk (files over 4 MB are
  ## skipped) and kept in a table by modification time; an empty index when the file cannot be read
  let bi = bufIndexByPath(path)
  if bi >= 0: return emitIndex(bufs[bi])
  try:
    let mt = getLastModificationTime(path)
    if path in emitFileIdx and emitFileIdx[path][0] == mt: return emitFileIdx[path][1]
    if getFileSize(path) > 4_000_000: return
    let ls = readFile(path).splitLines()
    result = emitIndexOf(path, ls)
    if emitFileIdx.len > 200: emitFileIdx.clear()
    emitFileIdx[path] = (mt, result)
  except CatchableError: discard

proc emitHeaders(b: Buffer): seq[string] =
  ## the headers the emitted C sees: its own #includes, the file's header: pragmas, and Nim's nimbase.h
  for h in emitIndex(b).includes:
    if h notin result: result.add h
  for l in b.lines:
    let k = l.find("header:")
    if k < 0: continue
    let q1 = l.find('"', k)
    let q2 = if q1 >= 0: l.find('"', q1 + 1) else: -1
    if q2 > q1 + 1 and l[q1 + 1 ..< q2] notin result: result.add l[q1 + 1 ..< q2]
  result.add "nimbase.h"

proc emitIsC(b: Buffer, p: Pos): bool =
  ## is p in C (or C++) emitted from this Nim file?
  if b.lang == nil or b.lang.mode != lmNim or p.line >= b.lines.len or b.lines[p.line].len > 2000: return false
  let l = b.langAt(p)
  l != nil and l.id in ["c", "cpp"]

proc emitIsCpp(b: Buffer, p: Pos): bool =
  ## is p in C++ emitted from this Nim file (the backend is C++)?
  if not emitIsC(b, p): return false
  let l = b.langAt(p)
  l != nil and l.id == "cpp"

func cxKindIcon(k: CxKind): int =
  ## the completion list's icon for ned's C engine's kinds (LSP's numbers)
  case k
  of cxFunc: 3
  of cxMethod: 2
  of cxField: 5
  of cxVar, cxParam, cxLocal: 6
  of cxStruct, cxUnion: 22
  of cxClass: 7
  of cxNamespace: 9
  of cxEnum: 13
  of cxEnumConst: 20
  of cxTypedef: 7
  of cxMacro: 15
  of cxLabel: 18

proc emitCxx(b: Buffer): CxFile =
  ## the C++ this file emits as ned's C engine reads it — lines and columns the .nim file's own —, its headers:
  ## its #includes, the file's header: pragmas, nimbase.h
  result = cxLoad(b.path, emitCode(b.lines) & "\n", "emit:" & $b.id & ":" & $b.changeId, cpp = true)
  for h in emitHeaders(b):
    let w = if h.startsWith("<") or h.startsWith("\""): h else: "\"" & h & "\""
    var has = false
    for (x, _) in result.includes:
      if x == w: has = true
    if not has: result.includes.add (w, -1)

template withEmitDirs(b: Buffer, body: untyped) =
  ## the engine asked with the Nim file's C include folders (the C files' are put back after)
  let savedDirs = cxDirs
  let savedSys = cxSysDirs
  cxDirs = cIncludeDirs(b.path, b.lines)
  cxSysDirs = cSystemIncludeDirs()
  try: body
  finally:
    cxDirs = savedDirs
    cxSysDirs = savedSys

proc emitCxxComplete(b: Buffer, p: Pos, manual: bool): bool =
  ## C++ in an emit: after `.` `->` `::` the members (a namespace's names), else once a word starts
  let ws = b.wordStart(p)
  let line = b.lines[p.line]
  let prev = if ws > 0: line[ws - 1] else: ' '
  let member = prev == '.' or (prev == '>' and ws >= 2 and line[ws - 2] == '-') or
               (prev == ':' and ws >= 2 and line[ws - 2] == ':')
  if not manual and not member and p.col - ws < 2: return false
  var res: (seq[CxItem], bool, string)
  try:
    withEmitDirs(b):
      res = cxComplete(emitCxx(b), p.line, p.col, cSystemIncludeDirs())
  except CatchableError as e:
    internalError("C++ engine", e)
    return false
  let (items, isMember, typ) = res
  if isMember and items.len == 0:
    if manual: info(if typ.len > 0: "No members known for " & typ else: "The type there is not known")
    return manual
  var out0: seq[CompItem]
  for it in items:
    out0.add CompItem(label: it.label, insert: it.label, detail: it.detail, kind: cxKindIcon(it.kind),
                      filter: it.label, sortText: $it.rank & it.label, rank: it.rank,
                      doc: (if it.detail.len > 0: "```cpp\n" & it.detail & "\n```\n" else: "") & it.doc, docMade: true)
  if out0.len == 0: return false
  compLine = p.line
  compStartCol = ws
  compManual = manual
  compNx.setLen(0)
  compItems = out0
  compFromLsp = true
  refilterComp()
  true

func cKindIcon(kind: string): int =
  ## the completion-item kind (the language server protocol's number, which picks the icon) for a C declaration kind:
  ## function, macro, type or variable
  case kind
  of "function": 3
  of "macro": 21
  of "type": 22
  of "variable": 6
  else: 1

# ── Nim names in an emit (`name` — the compiler writes its C name there): completed, resolved, renamed, checked ──

proc emitTickAt(line: string, col: int): (bool, int, int) =
  ## inside `…` on the line (the backticks of an emit): (yes, where the name starts, where it ends)
  var open = -1
  for k in 0 ..< min(col, line.len):
    if line[k] == '`': open = (if open < 0: k else: -1)
  if open < 0: return
  for k in open + 1 ..< min(col, line.len):
    if line[k] notin IdentChars: return
  var e = min(col, line.len)
  while e < line.len and line[e] in IdentChars: inc e
  (true, open + 1, e)

proc emitStmtAt(ls: seq[string], line: int): (int, int) =
  ## the lines of the emit statement `line` is in: from its pragma to the closing quotes (one line for a one-line
  ## emit), (-1, -1) when it is in none
  for (l, c, body) in emitBlocks(ls):
    if line >= l and line <= l + body.high:
      let first = if l > 0 and "emit" notin ls[l][0 ..< max(0, c - 3)] and "emit" in ls[l - 1]: l - 1 else: l
      return (first, l + body.high)
  if line < ls.len and "emit" in ls[line]: return (line, line)
  (-1, -1)

proc emitAsCode(ls: seq[string], line, start, stop: int): (seq[string], int, int) =
  ## the lines with the emit statement around `line` blanked, and its first line the Nim name at start ..< stop
  ## alone, at the statement's indentation: what the engine reads to complete or resolve it — (the lines, the line
  ## the name is on now, its column; -1: not in an emit). (The statement's own line: a routine's body ends, for the
  ## engine, at the last line of code — the string's lines are not)
  let (a, e) = emitStmtAt(ls, line)
  if a < 0: return (@[], -1, -1)
  var res = ls
  let ind = leadingWs(ls[a])
  for k in a .. e: res[k] = ""
  res[a] = ind & ls[line][start ..< stop]
  (res, a, ind.len)

proc emitStmts(ls: seq[string]): seq[(int, int)] =
  ## each emit statement's first and last line (a one-line emit with backticks: its line)
  for (l, c, body) in emitBlocks(ls):
    let first = if l > 0 and "emit" notin ls[l][0 ..< max(0, c - 3)] and "emit" in ls[l - 1]: l - 1 else: l
    result.add (first, l + body.high)
  let n = result.len
  for l, t in ls:
    let k = t.find("emit:")
    let q = if k >= 0: t.find('"', k) else: -1
    if q >= 0 and t.find('`', q) > q:
      var inside = false
      for i in 0 ..< n:
        if l >= result[i][0] and l <= result[i][1]: inside = true
      if not inside: result.add (l, l)

proc emitTickNames(ls: seq[string]): seq[(int, int, string)] =
  ## every `name` in the file's emits: (line, column of the name, the name)
  var any = false
  for l in ls:
    if "emit" in l:
      any = true
      break
  if not any: return
  for (a, z) in emitStmts(ls):
    for l in a .. z:
      let t = ls[l]
      if '`' notin t: continue
      var k = 0
      while k < t.len:
        if t[k] == '`':
          let e = t.find('`', k + 1)
          if e < 0: break
          let n = t[k + 1 ..< e]
          if n.len > 0 and n[0] in {'a'..'z', 'A'..'Z', '_'} and n.allCharsInSet(IdentChars): result.add (l, k + 1, n)
          k = e + 1
        else: inc k

proc emitNimComplete(b: Buffer, p: Pos, manual: bool): bool =
  ## in an emit's backticks: the Nim names the statement's place sees (the engine's completion there)
  if not nimEngineOn(b) or p.line >= b.lines.len: return false
  let (ok, start, _) = emitTickAt(b.lines[p.line], p.col)
  if not ok: return false
  let (ls, at, ind) = emitAsCode(b.lines, p.line, start, p.col)
  if ind < 0: return false
  var c: NxCompletion
  try:
    let f = nxFileFor(b)
    if f == nil: return false
    c = nxComplete(f, ls, at, ind + p.col - start)
  except Exception as e:
    internalError("Nim index", e)
    return false
  var items: seq[CompItem]
  for i, it in c.items: items.add compItemOf(it, i + 1)
  compLine = p.line
  compStartCol = start
  compManual = manual
  compNx = move c.items
  compRest = nil
  compItems = items
  compFromLsp = true
  refilterComp()
  true

proc emitWork(ls: seq[string]): EmitWork =
  ## the file once with every emit statement blanked, for the engine to resolve each `name` in (one copy for all)
  result.lines = ls
  result.stmts = emitStmts(ls)
  for (a, e) in result.stmts:
    for k in a .. e: result.lines[k] = ""

proc emitNimTargetsIn(w: var EmitWork, src: seq[string], f: NxFile, l, s, e: int): (seq[NxRef], seq[NxSym]) =
  ## what the `name` at (l, s ..< e) of an emit names (the engine, as if it were Nim at the statement's place)
  if f == nil: return
  for (a, z) in w.stmts:
    if l < a or l > z: continue
    let ind = leadingWs(src[a])
    w.lines[a] = ind & src[l][s ..< e]
    let (rs, locals, _) = nxTargets(f, w.lines, a, ind.len)
    w.lines[a] = ""
    return (rs, locals)

proc emitNimTargets(lines: seq[string], f: NxFile, l, s, e: int): (seq[NxRef], seq[NxSym]) =
  ## what the `name` at line l, columns s ..< e of an emit names in Nim, building the blanked-out working copy of the
  ## file first — for a caller that has no copy of its own
  var w = emitWork(lines)
  emitNimTargetsIn(w, lines, f, l, s, e)

func emitCName(s: NxSym): string =
  ## the C name a Nim symbol has when it says (exportc, importc), "" when the compiler chooses it
  for prag in ["exportc", "importc", "importcpp"]:
    let k = s.pragmas.find(prag)
    if k < 0: continue
    let after = k + prag.len
    if after < s.pragmas.len and s.pragmas[after] in {'a'..'z', 'A'..'Z'}: continue
    let rest = s.pragmas[after .. ^1].strip(trailing = false)
    if rest.startsWith(":"):
      let q1 = rest.find('"')
      let q2 = if q1 >= 0: rest.find('"', q1 + 1) else: -1
      if q2 > q1: return rest[q1 + 1 ..< q2].replace("$1", s.name)
    return s.name

proc emitNimHover(b: Buffer, p: Pos): string =
  ## the hover on a `name` in an emit: the Nim declaration, and the C name the compiler writes there
  if not nimEngineOn(b) or p.line >= b.lines.len: return ""
  let (ok, s, e) = emitTickAt(b.lines[p.line], p.col)
  if not ok or e <= s: return ""
  try:
    let f = nxFileFor(b)
    let (ls, at, ind) = emitAsCode(b.lines, p.line, s, e)
    if f == nil or ind < 0: return ""
    result = nxHover(f, ls, at, ind)
    if result.len == 0:
      return "`" & b.lines[p.line][s ..< e] & "` — no Nim name here has it: the compiler stops at it (undeclared identifier)"
    let (rs, _, _) = nxTargets(f, ls, at, ind)
    let cn = if rs.len > 0: emitCName(rs[0].sym) else: ""
    result.add "\n\n**In the C:** " & (if cn.len > 0: "`" & cn & "`" else: "the name the compiler gives it (exportc fixes one)")
  except Exception as e:
    internalError("Nim index", e)
    result = ""

proc emitNimGoto(b: Buffer, p: Pos): bool =
  ## F12 on a `name` in an emit: its Nim declaration
  if not nimEngineOn(b) or p.line >= b.lines.len: return false
  let (ok, s, e) = emitTickAt(b.lines[p.line], p.col)
  if not ok or e <= s: return false
  var defs: seq[(string, int, int, string)]
  try:
    let f = nxFileFor(b)
    let (ls, at, ind) = emitAsCode(b.lines, p.line, s, e)
    if f == nil or ind < 0: return false
    defs = nxDefinition(f, ls, at, ind)
    for d in defs.mitems:
      if d[0] == f.path: d[0] = b.path
  except Exception as e:
    internalError("Nim index", e)
    return false
  if defs.len == 0:
    info("No Nim name " & b.lines[p.line][s ..< e] & " here — the compiler stops at it")
    return true
  pushJump()
  let nb = if defs[0][0] == b.path or defs[0][0].len == 0: b else: openFile(defs[0][0])
  if nb != nil:
    let at = nb.clampPos(Pos(line: defs[0][1], col: defs[0][2]))
    nb.cursors = @[cur(at)]
    nb.centerOn(at)
  true

proc emitComplete(b: Buffer, p: Pos, manual: bool): bool =
  ## completion in emitted C: the file's own C names, the headers' (its #includes and header: pragmas,
  ## nimbase.h), C keywords and types — in backticks, the Nim names
  if not emitIsC(b, p): return false
  if emitNimComplete(b, p, manual): return true
  let ws = b.wordStart(p)
  if compOpen and compLine == p.line and compStartCol == ws and compFromLsp and compItems.len > 0:
    refilterComp()
    return true
  if emitLspComplete(b, p): return true               # clangd, when installed
  if emitIsCpp(b, p): return emitCxxComplete(b, p, manual)
  if not manual and p.col - ws < 2: return false
  var items: seq[CompItem]
  var seen: HashSet[string]
  let own = emitIndex(b)
  for n, d in own.decls:
    seen.incl n
    items.add CompItem(label: n, insert: n, detail: d.kind & " · this file", kind: cKindIcon(d.kind), filter: n,
                       sortText: "1" & n, rank: 1, doc: "```c\n" & d.text & "\n```", docMade: true)
  let dirs = cIncludeDirs(b.path, b.lines)
  let here = parentDir(b.path)
  for h in emitHeaders(b):
    let hp = cFindHeader(h, dirs, here)
    if hp.len == 0: continue
    for n, d in cHeaderIndex(hp).decls:
      if n in seen or n.startsWith("_"): continue
      seen.incl n
      items.add CompItem(label: n, insert: n, detail: d.kind & " · " & h, kind: cKindIcon(d.kind), filter: n,
                         sortText: "2" & n, rank: 2, doc: "```c\n" & d.text & "\n```\n" & extractFilename(hp) &
                         ":" & $(d.line + 1), docMade: true)
  for k in CKeywords:
    if k notin seen:
      items.add CompItem(label: k, insert: k, detail: "C", kind: 14, filter: k, sortText: "3" & k, rank: 3)
  compLine = p.line
  compStartCol = ws
  compManual = manual
  compNx.setLen(0)
  compItems = items
  compFromLsp = true
  refilterComp()
  true

proc emitDecl(b: Buffer, w: string): (CProto, string) =
  ## the C declaration of `w` seen from this file's emitted C: the file's own, then its headers'
  ## (second result: the header's name, "" for this file)
  let own = emitIndex(b)
  if w in own.decls:
    var d = own.decls[w]
    d.path = b.path
    return (d, "")
  let dirs = cIncludeDirs(b.path, b.lines)
  let here = parentDir(b.path)
  for h in emitHeaders(b):
    let hp = cFindHeader(h, dirs, here)
    if hp.len == 0: continue
    var seenH: HashSet[string]
    let r = cFindIn(hp, w, dirs, 0, seenH)
    if r.kind.len > 0: return (r, h)

proc emitHoverInfo(b: Buffer, p: Pos): string =
  ## the hover on a name in emitted C: its C declaration, and the Nim proc that imports it
  if not emitIsC(b, p): return ""
  let nh = emitNimHover(b, p)                         # (a `name`: the Nim one)
  if nh.len > 0: return nh
  if emitIsCpp(b, p):
    let w = b.wordAt(p)
    if w.len == 0 or w in CxxKeywords: return ""
    try:
      withEmitDirs(b):
        result = cxHover(emitCxx(b), p.line, p.col)
    except CatchableError as e:
      internalError("C++ engine", e)
      return ""
    if result.len > 0: result.add emitNimNote(b, w)
    return
  let w = b.wordAt(p)
  if w.len == 0 or w in CKeywords: return ""
  let (d, h) = emitDecl(b, w)
  if d.kind.len == 0: return ""
  result = "**" & w & "** — C " & d.kind & ", " &
           (if h.len == 0: "line " & $(d.line + 1) & " of this file" else: extractFilename(d.path) & ":" & $(d.line + 1)) &
           "\n```c\n" & d.text & "\n```"
  let doc = cDocAt(if h.len == 0: b.lines else: cRawLines(d.path), d.line)
  if doc.len > 0: result.add "\n" & doc
  for nd in nimFfiDecls(b.lines):
    if nd.cname == w and nd.kind in ["proc", "func"]:
      result.add "\n\nImported into Nim as `" & nd.name & "` (line " & $(nd.line + 1) & ")"
      break

proc emitCxxGoto(b: Buffer, p: Pos): bool =
  ## F12 in emitted C++: the declaration (a method's body, its class's members, through the headers); on a
  ## definition with nothing else to go to, the Nim declaration that imports it
  let w = b.wordAt(p)
  if w.len == 0 or w in CxxKeywords: return false
  var ts: seq[(CxFile, CxSym)]
  try:
    withEmitDirs(b):
      ts = cxTargets(emitCxx(b), p.line, p.col, jump = true)
  except CatchableError as e:
    internalError("C++ engine", e)
    return false
  if ts.len == 0:
    if emitLspDefinition(b, p): return true            # clangd, when installed
    info("No C++ declaration of " & w & " in this file or the headers it includes")
    return true
  let (g, s) = ts[0]
  if ts.len == 1 and g.path == b.path and s.line == p.line:
    # on the definition itself: the Nim side
    for nd in nimFfiDecls(b.lines):
      if nd.cname == w and nd.kind in ["proc", "func", "var", "let"]:
        pushJump()
        b.centerOn(b.clampPos(Pos(line: nd.line, col: nd.nameCol)))
        b.cursors = @[cur(b.clampPos(Pos(line: nd.line, col: nd.nameCol)))]
        info("Nim: " & b.lines[nd.line].strip)
        return true
    info(w & " is declared here")
    return true
  pushJump()
  let nb = if g.path == b.path: b else: openFile(g.path)
  if nb != nil:
    let at = nb.clampPos(Pos(line: s.line, col: s.col))
    nb.cursors = @[cur(at)]
    nb.centerOn(at)
  info("C++: " & s.text)
  true

proc emitGoto(b: Buffer, p: Pos): bool =
  ## F12 in emitted C: from a definition to the Nim proc that imports it; from a use to the definition
  if not emitIsC(b, p): return false
  if emitNimGoto(b, p): return true                   # (a `name`: its Nim declaration)
  if emitIsCpp(b, p): return emitCxxGoto(b, p)
  let w = b.wordAt(p)
  if w.len == 0 or w in CKeywords: return false
  let (d, h) = emitDecl(b, w)
  if d.kind.len == 0:
    if emitLspDefinition(b, p): return true            # clangd knows locals, fields, deeper headers
    info("No C declaration of " & w & " in this file or the headers it includes")
    return true
  if h.len == 0 and d.line == p.line:
    # on the definition itself: the Nim side
    for nd in nimFfiDecls(b.lines):
      if nd.cname == w and nd.kind in ["proc", "func", "var", "let"]:
        pushJump()
        b.centerOn(b.clampPos(Pos(line: nd.line, col: nd.nameCol)))
        b.cursors = @[cur(b.clampPos(Pos(line: nd.line, col: nd.nameCol)))]
        info("Nim: " & b.lines[nd.line].strip)
        return true
    info(w & " is defined here; no Nim declaration imports it in this file")
    return true
  pushJump()
  if h.len == 0:
    let at = b.clampPos(Pos(line: d.line, col: max(0, b.lines[d.line].find(w))))
    b.cursors = @[cur(at)]
    b.centerOn(at)
  else:
    let nb = openFile(d.path)
    if nb != nil: nb.centerOn(nb.clampPos(Pos(line: d.line, col: 0)))
  info("C: " & d.text)
  true

proc ffiCDecl(d: NimFfi, path: string, lines: seq[string], wide: bool): (CProto, string) =
  ## the C side of a Nim importc declaration: in its header, or (no header) in emitted C — this file's,
  ## the open files', and with `wide` the project's
  if d.header.len > 0: return cDeclFor(d.header, d.cname, cIncludeDirs(path, lines), parentDir(path))
  let bi = bufIndexByPath(path)
  let own = if bi >= 0 and bufs[bi].lines.len == lines.len: emitIndex(bufs[bi]) else: emitIndexOf(path, lines)
  if d.cname in own.decls:
    var r = own.decls[d.cname]
    r.path = path
    return (r, "")
  for x in bufs:
    if x.path.len == 0 or x.path == path or x.lang == nil or x.lang.mode != lmNim: continue
    let ix = emitIndex(x)
    if d.cname in ix.decls:
      var r = ix.decls[d.cname]
      r.path = x.path
      return (r, "")
  if wide and rootDir.len > 0:
    var n = 0
    for f in projectFiles():
      if not f.endsWith(".nim"): continue
      let full = if f.isAbsolute: f else: rootDir / f
      if full == path or bufIndexByPath(full) >= 0: continue
      inc n
      if n > 400: break
      let ix = emitIndexOfFile(full)
      if d.cname in ix.decls:
        var r = ix.decls[d.cname]
        r.path = full
        return (r, "")
  (CProto(), d.name & " imports C's " & d.cname & " without a header: pragma, and no {.emit.} in " &
             (if wide: "the project" else: "the open files") & " defines it")
