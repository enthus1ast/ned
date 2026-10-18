# ── C in {.emit.}: completion, hover and F12 with no language server (headers read by ned itself) ──

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
  cIndexOf(emitCode(lines), path)

proc emitIndex(b: Buffer): CIndex =
  ## what this file's emitted C declares (lines are the file's)
  if b.id in emitIdxCache and emitIdxCache[b.id][0] == b.changeId: return emitIdxCache[b.id][1]
  result = emitIndexOf(b.path, b.lines)
  if emitIdxCache.len > 64: emitIdxCache.clear()
  emitIdxCache[b.id] = (b.changeId, result)

proc emitIndexOfFile(path: string): CIndex =
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

func cKindIcon(kind: string): int =
  case kind
  of "function": 3
  of "macro": 21
  of "type": 22
  of "variable": 6
  else: 1

proc emitComplete(b: Buffer, p: Pos, manual: bool): bool =
  ## completion in emitted C: the file's own C names, the headers' (its #includes and header: pragmas,
  ## nimbase.h), C keywords and types
  if not emitIsC(b, p): return false
  let ws = b.wordStart(p)
  if compOpen and compLine == p.line and compStartCol == ws and compFromLsp and compItems.len > 0:
    refilterComp()
    return true
  if emitLspComplete(b, p): return true               # clangd, when installed
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

proc emitGoto(b: Buffer, p: Pos): bool =
  ## F12 in emitted C: from a definition to the Nim proc that imports it; from a use to the definition
  if not emitIsC(b, p): return false
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
