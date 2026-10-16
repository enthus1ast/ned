# ── F12 and hover: the C side ──

proc ffiTarget(b: Buffer, p: Pos): (NimFfi, string, seq[string]) =
  ## the importc declaration the cursor is on, or that the word under it names (this file, then the
  ## definition the Nim engine finds); with its file and lines
  let w = b.wordAt(p)
  if w.len == 0: return
  var decls = nimFfiDecls(b.lines)
  let i = ffiAtLine(decls, p.line)
  if i >= 0 and decls[i].name == w: return (decls[i], b.path, b.lines)
  if nimEngineOn(b):
    try:
      let f = nxFileFor(b)
      if f != nil:
        for (path, l, _, _) in nxDefinition(f, b.lines, p.line, p.col):
          let lines = if path == f.path or path.len == 0: b.lines
                      else:
                        let bi = bufIndexByPath(path)
                        if bi >= 0: bufs[bi].lines
                        elif fileExists(path): readFile(path).splitLines()
                        else: @[]
          let ds = nimFfiDecls(lines)
          let k = ffiAtLine(ds, l)
          if k >= 0: return (ds[k], (if path.len == 0 or path == f.path: b.path else: path), lines)
    except Exception as e: internalError("Nim index", e)
  for d in decls:
    if d.name == w: return (d, b.path, b.lines)

proc cGotoFromDecl(b: Buffer, p: Pos, anyUse = false): bool =
  ## F12 on an importc declaration (or, from the palette, on any use of one): the C declaration
  if b.lang == nil or b.lang.mode != lmNim: return false
  var d: NimFfi
  var path: string
  var lines: seq[string]
  if anyUse: (d, path, lines) = ffiTarget(b, p)
  else:
    let decls = nimFfiDecls(b.lines)
    let i = ffiAtLine(decls, p.line)
    if i < 0 or decls[i].name != b.wordAt(p): return false
    (d, path, lines) = (decls[i], b.path, b.lines)
  if d.name.len == 0:
    if anyUse: info("Not an importc declaration (or a use of one)")
    return anyUse
  let (cp, why) = ffiCDecl(d, path, lines, true)
  if cp.kind.len == 0:
    info(why)
    return true
  pushJump()
  let nb = openFile(cp.path)
  if nb != nil:
    let at = nb.clampPos(Pos(line: cp.line, col: max(0, nb.lines[min(cp.line, nb.lines.high)].find(d.cname))))
    if d.header.len == 0: nb.cursors = @[cur(at)]          # C emitted from Nim: the cursor on its name
    nb.centerOn(at)
    info("C: " & cp.text)
  true

proc cHoverInfo(b: Buffer, p: Pos): string =
  ## for the hover: the C declaration behind an importc wrapper
  if b.lang == nil or b.lang.mode != lmNim: return ""
  var any = false
  for l in b.lines:
    if "importc" in l:
      any = true
      break
  if not any and not nimEngineOn(b): return ""
  let (d, path, lines) = ffiTarget(b, p)
  if d.name.len == 0: return ""
  let (cp, _) = ffiCDecl(d, path, lines, false)
  if cp.kind.len == 0: return ""
  "\n\n**C** — " & (if d.header.len == 0: "{.emit.} in " else: "") & extractFilename(cp.path) & ":" & $(cp.line + 1) &
    " (F12 on the declaration opens it)\n```c\n" & cp.text & "\n```"
