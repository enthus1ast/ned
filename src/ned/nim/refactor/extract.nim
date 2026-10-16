# ── Nim refactors: extract a proc, sort imports, proc ⇄ func ──

proc identsIn(text: string): HashSet[string] =
  ## the names used in some code (strings and comments left out)
  result = initHashSet[string]()
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '#':
      while i < text.len and text[i] != '\n': inc i
    elif c == '"':
      inc i
      while i < text.len and text[i] != '"' and text[i] != '\n':
        if text[i] == '\\': inc i
        inc i
      inc i
    elif c in IdentStartChars and (i == 0 or text[i - 1] notin IdentChars):
      var j = i
      while j < text.len and text[j] in IdentChars: inc j
      if i == 0 or text[i - 1] != '.': result.incl nxNorm(text[i ..< j])
      i = j
    else: inc i

proc assignedIn(text, name: string): bool =
  ## is `name` changed in the code (x = …, x += …, inc x, x.add …)? → a `var` parameter
  for line in text.splitLines:
    let t = line.strip
    for op in [" = ", " += ", " -= ", " *= ", " /= ", " &= ", ".add(", ".add ", ".setLen(", ".inc", ".dec"]:
      let k = t.find(name & op)
      if k >= 0 and (k == 0 or t[k - 1] notin IdentChars) and not t.startsWith("let ") and
         not t.startsWith("var ") and not t.startsWith("const "): return true
    for f in ["inc ", "dec ", "inc(", "dec("]:
      if t.startsWith(f & name): return true

proc cmdExtractProc() =
  ## the selection becomes a proc of its own (just above the routine it was in); the locals it uses are its
  ## parameters (`var` when it changes them); a part of one line becomes a proc that returns its value
  let b = buf()
  if not b.canEdit(): return
  if b.lang.mode != lmNim or not nimEngineOn(b):
    info("Extract proc works in Nim files with the built-in engine")
    return
  if not b.primary.hasSel:
    info("Select the lines (or the expression) to extract first")
    return
  let (a, e) = b.primary.range
  let partial = a.line == e.line and (a.col > leadingWs(b.lines[a.line]).len or e.col < b.lines[a.line].len)
  var l0 = a.line
  var l1 = e.line
  if not partial and e.col == 0 and l1 > l0: dec l1
  let text = if partial: b.lines[a.line][a.col ..< e.col] else: b.lines[l0 .. l1].join("\n")
  var f: NxFile
  try: f = nxFileFor(b)
  except Exception as ex:
    internalError("Nim index", ex)
    return
  if f == nil: return
  let ri = nxEnclosing(f, l0)
  # the locals the code uses, declared before it
  var locals: seq[NxSym]
  try: locals = nxLocals(f, b.lines, l0, (if partial: a.col else: 0))
  except Exception: discard
  let used = identsIn(text)
  var sc: NxScope
  try: sc = nxScope(f)
  except Exception: discard
  var params: seq[string]
  var args: seq[string]
  var seenP: HashSet[string]
  for loc in locals:
    let nn = nxNorm(loc.name)
    if nn notin used or nn in seenP or loc.kind == nxResult: continue
    seenP.incl nn
    var t = loc.typ
    if t.len == 0:
      try: t = nxTypeOfName(f, sc, locals, loc.name, l0, 0).typ
      except Exception: discard
    if t.len == 0: t = "auto"
    let isVar = not partial and assignedIn(text, loc.name)
    params.add loc.name & ": " & (if isVar: "var " else: "") & t
    args.add loc.name
  # a name declared in the extracted lines and used after them would be lost
  if not partial and ri >= 0:
    let after = b.lines[l1 + 1 .. min(b.lines.high, f.syms[ri].endLine)].join("\n")
    let usedAfter = identsIn(after)
    for line in b.lines[l0 .. l1]:
      let t = line.strip
      for kw in ["let ", "var ", "const "]:
        if t.startsWith(kw):
          var j = kw.len
          var nm = ""
          while j < t.len and t[j] in IdentChars:
            nm.add t[j]
            inc j
          if nm.len > 0 and nxNorm(nm) in usedAfter:
            error("'" & nm & "' is declared in the selection and used after it — extend the selection to " &
                  "include those uses, or move the declaration out")
            return
  # a name nobody uses yet
  var name = "extracted"
  var n = 1
  while ("proc " & name & "(") in b.allText: (inc n; name = "extracted" & $n)
  let insertAt = if ri >= 0: f.syms[ri].line else: l0
  let ind = leadingWs(b.lines[l0])
  var procText = "proc " & name & "(" & params.join(", ") & ")"
  if partial:
    procText.add ": auto =\n  " & text.strip & "\n\n"
  else:
    procText.add " =\n"
    for line in b.lines[l0 .. l1]:
      procText.add (if line.strip.len == 0: "" else: "  " & (if line.startsWith(ind): line[ind.len .. ^1] else: line.strip)) & "\n"
    procText.add "\n"
  let call = name & "(" & args.join(", ") & ")"
  b.beginEdit()
  if partial:
    discard b.replaceText(a, e, call)
  else:
    discard b.replaceText(Pos(line: l0, col: 0), Pos(line: l1, col: b.lines[l1].len), ind & call)
  discard b.replaceText(Pos(line: insertAt, col: 0), Pos(line: insertAt, col: 0), procText)
  b.endEdit()
  # rename it right away: the cursor on the new proc's name
  b.setSingle(Pos(line: insertAt, col: 5))
  info("Extracted into " & name & " — type a name for it (F2 renames it everywhere)")
  cmdRename()

proc cmdSortImports() =
  ## the import block at the top: standard library first (one `import std/[…]`), then packages, then the
  ## project's own modules, each sorted
  let b = buf()
  if not b.canEdit() or b.lang.mode != lmNim: return
  let stmts = b.importStmts()
  if stmts.len == 0:
    info("No imports")
    return
  # only the first run of consecutive plain `import` lines (no comments, no `as`/`except`)
  var first = stmts[0][0]
  var last = -1
  var std, pkgs, locals, keep: seq[string]
  var prev = first - 1
  for (l, le) in stmts:
    if l != prev + 1: break
    var t = ""
    for k in l .. le: t.add " " & b.lines[k].strip
    t = t.strip
    if '#' in t:
      info("The imports have comments — sort them by hand")
      return
    if not t.startsWith("import ") or " as " in t or " except " in t:
      keep.add t
      prev = le
      last = le
      continue
    for m in b.importedModulesOf(t):
      if m.startsWith("./") or m.startsWith("../"): (if m notin locals: locals.add m)
      elif m.startsWith("std/"): (if m[4 .. ^1] notin std: std.add m[4 .. ^1])
      elif m.startsWith("pkg/"): (if m notin pkgs: pkgs.add m)
      elif b.isStdModule(m): (if m notin std: std.add m)
      else: (if m notin pkgs: pkgs.add m)
    prev = le
    last = le
  if last < 0: return
  std.sort()
  pkgs.sort()
  locals.sort()
  var outp: seq[string]
  if std.len == 1: outp.add "import std/" & std[0]
  elif std.len > 1: outp.add "import std/[" & std.join(", ") & "]"
  if pkgs.len > 0: outp.add "import " & pkgs.join(", ")
  if locals.len > 0: outp.add "import " & locals.join(", ")
  outp.add keep
  var all = if first > 0: b.lines[0 ..< first] else: @[]
  all.add outp
  if last + 1 < b.lines.len: all.add b.lines[last + 1 .. ^1]
  b.setTextMinimal(all.join("\n"))
  info("Imports sorted")

proc cmdToggleFunc() =
  ## the routine around the cursor: proc ⇄ func
  let b = buf()
  if not b.canEdit() or b.lang.mode != lmNim: return
  var l = b.primary.head.line
  while l >= 0:
    let t = b.lines[l]
    let lw = leadingWs(t).len
    for (fromKw, toKw) in [("proc ", "func "), ("func ", "proc ")]:
      if t.continuesWith(fromKw, lw):
        b.beginEdit()
        discard b.replaceText(Pos(line: l, col: lw), Pos(line: l, col: lw + 4), toKw[0 .. 3])
        b.endEdit()
        info("Line " & $(l + 1) & ": " & fromKw.strip & " → " & toKw.strip)
        return
    if l < b.primary.head.line and lw == 0 and t.strip.len > 0 and not t.startsWith("#"): break
    dec l
  info("No proc or func around the cursor")

proc toggleExport() =
  ## add or remove the export marker (*) of the declaration on the cursor line
  let b = buf()
  if b.lang.mode != lmNim or not b.canEdit(): return
  let l = b.primary.head.line
  let s = b.lines[l]
  var i = leadingWs(s).len
  var nameStart = -1
  for kw in ["proc ", "func ", "template ", "macro ", "iterator ", "converter ", "method ", "type ", "const ", "let ", "var "]:
    if s[i .. ^1].startsWith(kw):
      i += kw.len
      while i < s.len and s[i] == ' ': inc i
      nameStart = i
      break
  if nameStart < 0 and i > 0 and i < s.len and s[i] in IdentStartChars: nameStart = i   # inside a type/const block
  if nameStart < 0 or nameStart >= s.len:
    info("Put the cursor on a declaration (proc, type, field, const …)")
    return
  var e = nameStart
  if s[e] == '`':
    let q = s.find('`', e + 1)
    if q < 0: return
    e = q + 1
  else:
    while e < s.len and s[e] in IdentChars: inc e
  if e == nameStart: return
  b.beginEdit()
  if e < s.len and s[e] == '*':
    discard b.replaceText(Pos(line: l, col: e), Pos(line: l, col: e + 1), "")
    info(s[nameStart ..< e] & " is now private")
  else:
    discard b.replaceText(Pos(line: l, col: e), Pos(line: l, col: e), "*")
    info(s[nameStart ..< e] & " is now exported")
  b.endEdit()

proc urlAct(u: string): Action = (proc() = openInBrowser(u))

proc nimDocsForSymbol() =
  let b = buf()
  let w = b.wordAt(b.primary.head)
  if w.len == 0:
    openInBrowser("https://nim-lang.org/docs/lib.html")
    return
  loadNimIndex()
  let mods = nimIndex.getOrDefault(w)
  if mods.len == 0:
    openInBrowser("https://nim-lang.org/docs/theindex.html#" & w)
    return
  var items: seq[(string, string, Action)]
  for m in mods:
    let url = "https://nim-lang.org/docs/" & m.split('/')[^1] & ".html#" & w
    items.add act(m, url, urlAct(url))
  if items.len == 1: items[0][2]()
  else: openActions("Documentation for " & w, items)

proc nimbleAddDep(pkg: string) =
  ## requires "pkg" in the .nimble file, then offer `nimble install -d`
  let p = pkg.strip
  if p.len == 0: return
  loadNimbleInfo(true)
  if nimble.file.len == 0:
    error("No .nimble file in this project — palette › Nim: new project…")
    return
  try:
    var lines = readFile(nimble.file).splitLines
    let name = p.splitWhitespace()[0].strip(chars = {'"'})
    for l in lines:
      if l.strip.startsWith("requires") and ("\"" & name) in l:
        info(name & " is already required")
        return
    var at = -1
    for i, l in lines:
      if l.strip.startsWith("requires"): at = i
    let entry = "requires \"" & p.strip(chars = {'"'}) & "\""
    if at >= 0: lines.insert(entry, at + 1)
    else:
      while lines.len > 0 and lines[^1].strip.len == 0: lines.setLen(lines.len - 1)
      lines.add ""
      lines.add "# Dependencies"
      lines.add ""
      lines.add entry
    snapshotHistory(nimble.file)
    writeFileSafe(nimble.file, lines.join("\n") & (if lines.len > 0 and lines[^1].len > 0: "\n" else: ""))
    for bb in bufs:
      if bb.path == nimble.file and not bb.dirty: reloadBuffer(bb)
    loadNimbleInfo(true)
    toast("Added " & entry & " to " & extractFilename(nimble.file), 5, "Install now",
          proc() = runNimble("install -d -y"), 15000)
  except CatchableError as e:
    error("Could not update " & nimble.file & ": " & e.msg)
