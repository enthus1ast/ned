# ── move a top-level declaration to another module ──

proc rfMoveTo(d: NxRef, target: string) =
  ## moves a top-level proc, template, type and the like (with the comments above it) to the end of another module,
  ## creating the module if need be: imports the moved code needs go with it, it is exported when others use it, and the
  ## modules that use it import the target. Refuses (with the reason) when the moved code uses names left in its own
  ## module, or the two modules would import each other
  let s = d.sym
  let src = d.file.path
  let srcLines = rfLinesOf(src)
  if target == src:
    info("That is the module it is in")
    return
  # its lines: the comments right above it, the declaration, the body
  var a = s.line
  let e = max(s.line, s.endLine)
  var isTypeInSection = false
  if s.kind == nxType:
    if srcLines[a].len > 0 and srcLines[a][0] in {' ', '\t'}: isTypeInSection = true
  elif s.kind == nxConst:
    info("Move a const by hand (cut and paste) — ned moves procs and types")
    return
  while a > 0 and srcLines[a - 1].strip.startsWith("#"): dec a
  if srcLines[s.line].len > 0 and srcLines[s.line][0] in {' ', '\t'} and s.kind != nxType:
    info("Only a top-level declaration can move to another module")
    return
  var text = srcLines[a .. e]
  if isTypeInSection:
    # out of its `type` section: it gets one of its own
    let ind = srcLines[s.line].len - srcLines[s.line].strip(trailing = false).len
    for x in text.mitems:
      if x.len >= ind and x[0 ..< ind].strip.len == 0: x = "  " & x[ind .. ^1]
    text.insert("type", 0)
  # what the moved code uses from elsewhere: those modules' imports go with it; things of its own module would
  # make the two modules import each other
  let f = d.file
  var needMods: seq[string]
  var ownUses: seq[string]
  var st: NxLexState
  for l in a .. e:
    for (ia, ie) in nxIdents(srcLines[l], st):
      if ia > 0 and srcLines[l][ia - 1] == '.': continue
      let (rs, ls, mp) = nxTargets(f, srcLines, l, ia)
      if ls.len > 0: continue
      if mp.len > 0:
        if mp != src and mp notin needMods: needMods.add mp
        continue
      for r in rs:
        let rp = r.file.path
        if rp == src:
          if r.sym.line != s.line and r.sym.name notin ownUses and r.sym.kind notin {nxParam, nxField, nxEnumVal}:
            ownUses.add r.sym.name
        elif rp != target and rp notin needMods: needMods.add rp
        break
  # (only modules the source imports itself: not system, nor what an import re-exports)
  let srcMods = rfImportMap(f)                 # path → the spec the source writes
  if ownUses.len > 0:
    error(s.name & " uses " & ownUses[0 ..< min(4, ownUses.len)].join(", ") & " from " & extractFilename(src) &
          " — move those too (or first), else the two modules would import each other")
    return
  # who uses it: the module it leaves and the others then import the target
  let (_, hits) = rfRefs(d)
  var users: seq[string]
  for (p, l, c) in hits:
    if p == src and l >= a and l <= e: continue          # (in the code that moves)
    if p != target and p notin users: users.add p
  if src in users and rfImports(target, src):
    error(extractFilename(target) & " imports " & extractFilename(src) & ", which still uses " & s.name &
          " — the two modules would import each other")
    return
  var edits: seq[RfEdit]
  # into the target: its imports, then the declaration (exported when anyone else uses it)
  if not fileExists(target):
    try: writeFile(target, "")
    except CatchableError as ex:
      error("Cannot create " & target & ": " & ex.msg)
      return
    fileWritten(target)
  let tLines = rfLinesOf(target)
  var moved = text
  if users.len > 0 and not s.exported:
    let k = s.line - a + (if isTypeInSection: 1 else: 0)
    let at = moved[k].find(s.name)
    if at >= 0: moved[k] = moved[k][0 ..< at + s.name.len] & "*" & moved[k][at + s.name.len .. ^1]
  var specs: seq[string]
  for m in needMods:
    if m == target or m notin srcMods or rfImports(target, m): continue
    # the spec the source module writes (std/x, a package's name), or a path from the target's folder
    specs.add rfSpecFor(target, m, srcMods[m])
  var tail = tLines.len
  while tail > 0 and tLines[tail - 1].strip.len == 0: dec tail
  let endPos = if tLines.len == 0: Pos(line: 0, col: 0) else: Pos(line: tLines.high, col: tLines[^1].len)
  if tail == 0:
    # a new (empty) module: its imports, then the declaration
    var t = ""
    for sp in specs: t.add "import " & sp & "\n"
    edits.add (target, Pos(line: 0, col: 0), endPos, t & (if t.len > 0: "\n" else: "") & moved.join("\n") & "\n")
  else:
    rfAddImport(target, specs, edits)
    edits.add (target, endPos, endPos, "\n\n" & moved.join("\n") & "\n")
  # out of the source, and the imports of the files that use it
  var cutEnd = e + 1
  if cutEnd < srcLines.len and srcLines[cutEnd].strip.len == 0: inc cutEnd
  edits.add (src, Pos(line: a, col: 0), (if cutEnd < srcLines.len: Pos(line: cutEnd, col: 0)
                                          else: Pos(line: srcLines.high, col: srcLines[^1].len)), "")
  for u in users:
    if not rfImports(u, target): rfAddImport(u, @[rfImportSpec(u, target)], edits)
  let files = rfApply(edits)
  info("Moved " & s.name & " to " & relPath(target) & " (" & $files & " files changed: imports added where it is used)" &
       " — Ctrl+S saves each")

proc cmdMoveToModule() =
  ## asks where to move the declaration at the cursor — a new module (a path is asked) or one of the project's files —
  ## and moves it
  let b = buf()
  if b.lang.mode != lmNim or not nimEngineOn(b) or b.path.len == 0:
    info("Moving works on Nim files, with the built-in engine")
    return
  let (d, ok) = rfDeclOf(b)
  if not ok or d.file.path != b.path or d.sym.kind notin NxRoutineKinds + {nxType}:
    info("Put the cursor on the name of a top-level proc or type in this file")
    return
  var items: seq[(string, string, Action)]
  let dd = d
  items.add act("New module…", "a path, e.g. src/demo/text.nim", proc() =
    askText("New module (path)", relPath(parentDir(b.path)) & "/", proc(t: string) =
      var p = expandTilde(t.strip)
      if p.len == 0: return
      if not p.endsWith(".nim"): p.add ".nim"
      let full = if p.isAbsolute: p else: rootDir / p
      try: createDir(parentDir(full))
      except CatchableError: discard
      rfMoveTo(dd, full)))
  for p in nimSourceFiles():
    if p == b.path or not p.endsWith(".nim"): continue
    let path = p
    capture path:
      items.add act(relPath(path), "", proc() = rfMoveTo(dd, path))
  openActions("Move " & d.sym.name & " to…", items)
