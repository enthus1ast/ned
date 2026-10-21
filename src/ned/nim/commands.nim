proc gotoAct(path: string, line, col: int): Action =
  ## open the file at line:col. (A closure made in a loop has to come from a proc like this one: closures made
  ## right in a loop's body share its variables, so they would all go to the last place.)
  result = proc() =
    let ob = openFile(path)
    if ob != nil:
      ob.setSingle(ob.clampPos(Pos(line: line, col: col)))
      ob.centerOn(ob.clampPos(Pos(line: line, col: col)))

proc cmdUnusedExports() =
  ## exported top-level declarations nothing in the project uses
  refFiles = nimSourceFiles()
  refFilesAt = getMonoTime()
  info("Looking for exports nothing uses…")
  for p in refFiles: refIndexFile(p)
  let t0 = getMonoTime()
  var items: seq[(string, string, Action)]
  var cut = false
  for p in refFiles:
    if not p.endsWith(".nim"): continue
    let f = nxLoad(p)
    if f == nil: continue
    for i in 0 ..< f.syms.len:
      template s: untyped = f.syms[i]
      if not s.exported or s.kind notin NxRoutineKinds + {nxType, nxConst}: continue
      if msSince(t0) > 20_000 or termSignal != 0:
        cut = true
        break
      if refCountOf(p, f, i, 100) == 0:
        items.add act(s.name, relPath(p) & ":" & $(s.line + 1) & "  " & nxKindWord(s.kind), gotoAct(p, s.line, s.col))
    if cut: break
  if items.len == 0:
    info(if cut: "None found in 20 s (the project is big: not every file was looked at)" else: "Every export is used somewhere in the project")
    return
  openActions("Exported, used nowhere in the project (" & $items.len & ")" & (if cut: " — stopped after 20 s" else: ""), items)

proc nimbleDir(): string =
  loadNimbleInfo()
  if nimble.dir.len > 0: nimble.dir else: rootDir

proc runNimble(args: string) =
  if not haveExe("nimble"):
    error("nimble not found (Termux: pkg install nim)")
    return
  runCommand("nimble " & args, nimbleDir())

proc runAtlas(args: string) =
  if not haveExe("atlas"):
    error("atlas not found — build it with: nimble install atlas")
    return
  runCommand("atlas " & args, rootDir)

proc saveForTool(b: Buffer): bool =
  if b.path.len == 0:
    info("Save the file first")
    return false
  if b.dirty: discard b.saveBuffer()
  true

proc compilerExpandMacro(b: Buffer, name: string, line: int) =
  ## a macro call as the compiler expands it: `nim check --expandMacro`, the unsaved text read from stdin in the
  ## file's folder (its imports and config as they are)
  let copy = privTmp("expand") & ".nim"
  try: writeFile(copy, b.lines.join("\n") & "\n")
  except CatchableError as e:
    error("Cannot expand: " & e.msg)
    return
  let dir = if b.path.len > 0: parentDir(b.path) else: rootDir
  info("Expanding " & name & " (nim check --expandMacro)…")
  discard startJob(jkTool, "nim check --colors:off --hint:ExpandMacro:on --expandMacro:" & quoteShell(name) & " - < " &
                   quoteShell(copy), dir, proc(j: Job) =
    try: removeFile(copy)
    except CatchableError: discard
    var blocks: seq[(int, string)]          # (line, the code it expands to)
    var cur = -1
    var acc: seq[string]
    var firstErr = ""
    for raw in stripAnsi(j.output).splitLines:
      let k = raw.find(") Hint: expanded macro:")
      if k > 0 and raw.startsWith("stdinfile.nim("):
        let inner = raw["stdinfile.nim(".len ..< k].split(',')
        cur = (try: parseInt(inner[0].strip) - 1 except ValueError: -1)
        acc = @[]
        let rest = raw[k + ") Hint: expanded macro:".len .. ^1].strip
        if rest.len > 0: acc.add rest
        continue
      if cur >= 0:
        if raw.endsWith(" [ExpandMacro]"):
          acc.add raw[0 ..< raw.len - " [ExpandMacro]".len]
          blocks.add (cur, acc.join("\n").strip(leading = false))
          cur = -1
        else: acc.add raw
      elif firstErr.len == 0 and " Error: " in raw: firstErr = raw.replace("stdinfile.nim", extractFilename(b.path))
    if blocks.len == 0:
      error(if firstErr.len > 0: "Not expanded — " & firstErr else: "The compiler expanded no " & name & " here")
      return
    var pick = 0
    for i, (l, _) in blocks:
      if l <= line and l >= blocks[pick][0]: pick = i
      if l == line:
        pick = i
        break
    discard openScratch("expand: " & name, "# " & name & " at line " & $(blocks[pick][0] + 1) &
                        ", as the compiler expands it\n" & blocks[pick][1] & "\n", langByName("Nim")))

proc cmdExpandMacro(level = "all") =
  let b = buf()
  if b.lang.mode != lmNim:
    info("Macro expansion is for Nim files")
    return
  let (a, e) = b.wordRangeAt(b.primary.head)
  let w = b.lines[a.line][a.col ..< e.col]
  if w.len == 0:
    info("Put the cursor on a macro or template call")
    return
  let s = lspReady(b)
  if s != nil:
    discard s.lspRequest("extension/macroExpand", %*{"textDocument": b.docId, "position": s.lspPos(b, a),
      "level": (if level == "all": -1 else: parseInt(level))}, LspReq(kind: lrExpand, bufId: b.id, pos: a, extra: w))
    info("Expanding " & w & "…")
  elif nimEngineOn(b):
    var call, text: string
    var isMacro = false
    try:
      let f = nxFileFor(b)
      if f != nil:
        # a template: written out by the engine, at once
        (call, text) = nxExpandTemplate(f, b.lines, a.line, a.col)
        for r in nxLookup(nxScope(f), w):
          if r.sym.kind == nxMacro: isMacro = true
    except Exception as e: internalError("Nim index", e)
    if text.len > 0:
      var head = ""
      for x in call.splitLines: head.add "# " & x & "\n"
      discard openScratch("expand: " & w, head & text & "\n", langByName("Nim"))
      info("The template written out with the arguments in place (names it declares are its own unless " &
           "{.inject.}) — Ctrl+W closes it")
    elif isMacro and haveExe("nim"): compilerExpandMacro(b, w, a.line)
    elif nsUsable(b):
      discard nsRequest(b, nsExpand, a, (if level == "all": w else: level))
      info("Expanding " & w & "…")
    else: info("Put the cursor on a template or macro call")
  elif nsUsable(b):
    discard nsRequest(b, nsExpand, a, (if level == "all": w else: level))
    info("Expanding " & w & "…")
  else:
    info("Macro expansion needs nimsuggest (ships with Nim) or nimlangserver")

proc toolOutput(title, cmd, cwd: string, extract: proc(o: string): string, lang: Lang) =
  ## run a tool in the background and show (part of) its output in a read-only tab
  info("Running: " & cmd)
  discard startJob(jkTool, cmd, cwd, proc(j: Job) =
    var o = stripAnsi(j.output)
    let r = extract(o)
    if r.strip.len > 0:
      discard openScratch(title, r, lang)
    else:
      let first = o.strip.splitLines
      error(if first.len > 0: first[^1] else: "no output"))

proc cmdExpandArc() =
  let b = buf()
  if b.lang.mode != lmNim or not saveForTool(b): return
  let name = enclosingProc(b)
  if name.len == 0:
    info("Put the cursor inside a proc")
    return
  let proj = nimProjectFile(b)
  let cmd = "nim c --compileOnly --hints:off --warnings:off --expandArc:" & quoteShell(name) & " " & quoteShell(proj)
  toolOutput("arc: " & name, cmd, parentDir(proj), proc(o: string): string =
    var take = false
    for l in o.splitLines:
      if l.startsWith("--expandArc: "):
        take = true
        result.add "# " & l & "\n"
        continue
      if l.startsWith("-- end of expandArc"):
        take = false
        result.add "\n"
        continue
      if take: result.add l & "\n"
    if result.len > 0:
      result = "# ARC/ORC view: inserted =copy / =sink / =destroy / wasMoved calls\n\n" & result,
    langByName("Nim"))

proc cmdShowC() =
  let b = buf()
  if b.lang.mode != lmNim or not saveForTool(b): return
  let proj = nimProjectFile(b)
  let cache = privDir() / "nimcache" / splitFile(proj).name
  let cmd = "nim " & (if cfgNimTarget == "cpp": "cpp" else: "c") & " --compileOnly --hints:off --warnings:off --nimcache:" &
            quoteShell(cache) & " " & quoteShell(proj)
  let want = extractFilename(b.path)
  info("Generating C for " & want & "…")
  discard startJob(jkTool, cmd, parentDir(proj), proc(j: Job) =
    var best = ""
    try:
      for kind, p in walkDir(cache):
        let nm = extractFilename(p)
        if nm.endsWith(want & ".c") or nm.endsWith(want & ".cpp"):
          if best.len == 0 or nm.len < extractFilename(best).len: best = p
    except OSError: discard
    if best.len == 0:
      let ls = stripAnsi(j.output).strip.splitLines
      error("No C output" & (if ls.len > 0: ": " & ls[^1] else: ""))
      return
    let nb = openFile(best)
    if nb != nil:
      nb.readOnly = true
      info("Generated " & (if cfgNimTarget == "cpp": "C++" else: "C") & " for " & want & " (read-only)"))

proc cmdCallHierarchy() =
  ## who calls the routine at the cursor (←) and what it calls (→), from the Nim index
  let b = buf()
  if not nimEngineOn(b):
    let s = lspReady(b)
    if s != nil and s.caps != nil and s.caps{"callHierarchyProvider"} != nil:
      discard s.lspRequest("textDocument/prepareCallHierarchy", %*{"textDocument": b.docId,
        "position": s.lspPos(b, b.primary.head)}, LspReq(kind: lrCallPrep, bufId: b.id))
    else: info("Call hierarchy needs the Nim engine or a language server that offers it")
    return
  let f = nxFileFor(b)
  if f == nil: return
  # the routine: the one named at the cursor, else the one around it
  var name = b.wordAt(b.primary.head)
  var ri = -1
  for i in 0 ..< f.syms.len:
    template sy: untyped = f.syms[i]
    if sy.kind in NxRoutineKinds and sy.line == b.primary.head.line and sy.name == name: ri = i
  if ri < 0 and name.len == 0:
    ri = nxEnclosing(f, b.primary.head.line)
    if ri >= 0: name = f.syms[ri].name
  if name.len == 0:
    info("Put the cursor on a proc's name")
    return
  var items: seq[PickItem]
  # ← incoming: every reference, grouped by the routine it is in
  var hits: seq[(string, int, int)]
  var decl = ""
  var at = b.primary.head
  if ri >= 0: at = Pos(line: f.syms[ri].line, col: f.syms[ri].col)
  try: discard engineReferences(b, at, hits, decl)
  except Exception as e: internalError("Nim index", e)
  if nxRefsCut: warn(RefsCutMsg)
  var seen: Table[string, int]
  for (path, l, c) in hits:
    let nf = if path == b.path: f else: nxLoad(path)
    if nf == nil: continue
    let e = nxEnclosing(nf, l)
    if e >= 0 and nf.syms[e].line == l: continue          # the declaration itself
    let caller = if e >= 0: nf.syms[e].name else: "(top level)"
    let key = path & ":" & caller
    if key in seen:
      inc items[seen[key]].score
      items[seen[key]].detail = relPath(path) & ":" & $(items[seen[key]].line + 1) & " · " & $items[seen[key]].score & " calls"
      continue
    seen[key] = items.len
    items.add PickItem(label: "← " & caller, detail: relPath(path) & ":" & $(l + 1), icon: "ƒ", path: path, line: l, col: c, score: 1)
  # → outgoing: the calls inside its body
  if ri >= 0:
    var outSeen: HashSet[string]
    var st: NxLexState
    for l in f.syms[ri].line + 1 .. min(f.syms[ri].endLine, b.lines.high):
      let ln = b.lines[l]
      for (a, e) in nxIdents(ln, st):
        var k = e
        while k < ln.len and ln[k] == ' ': inc k
        if k >= ln.len or ln[k] notin {'(', '['}: continue
        let w = ln[a ..< e]
        if w in outSeen: continue
        var defs: seq[(string, int, int, string)]
        try: defs = nxDefinition(f, b.lines, l, a)
        except Exception: continue
        if defs.len == 0: continue
        outSeen.incl w
        let dp = if defs[0][0] == f.path or defs[0][0].len == 0: b.path else: defs[0][0]
        items.add PickItem(label: "→ " & w, detail: relPath(dp) & ":" & $(defs[0][1] + 1), icon: "ƒ", path: dp,
                           line: defs[0][1], col: defs[0][2])
  if items.len == 0:
    info("No calls to or from " & name)
    return
  openPicker(pickSymbol, "Call hierarchy — " & name & "  (← called by · → calls)", items)

proc moduleRefSpans(line, importerDir, oldPath: string, fromStmt: bool): seq[(int, int, string)] =
  ## in one line of an import statement: the module paths that name `oldPath` (start, end, path as written)
  var i = 0
  var first = true
  while i < line.len:
    if line[i] in IdentStartChars or line[i] == '.':
      var j = i
      while j < line.len and line[j] in IdentChars + {'/', '.', '-'}: inc j
      let tok = line[i ..< j]
      if tok in ["import", "from", "include", "export", "as", "except"]:
        if fromStmt and tok == "import": break               # from x import a, b: a and b are not modules
        i = j
        continue
      var cands: seq[(int, int, string)]
      if j < line.len and line[j] == '[' and tok.endsWith("/"):
        # a/[b, c]: each name in the brackets
        var k = j + 1
        while k < line.len and line[k] != ']':
          if line[k] in IdentStartChars:
            var m = k
            while m < line.len and line[m] in IdentChars: inc m
            cands.add (k, m, tok & line[k ..< m])
            k = m
          else: inc k
        j = min(k + 1, line.len)
      else: cands.add (i, j, tok)
      for (a, e, c) in cands:
        for base in [importerDir, rootDir, rootDir / "src"]:
          if normalizedPath(base / c & ".nim") == normalizedPath(oldPath):
            result.add (a, e, c)
            break
      if fromStmt and first: break
      first = false
      i = j
    else: inc i

proc fixImportsAfterMove(oldPath, newPath: string) =
  ## a Nim file was renamed or moved: the imports that name it follow (asks first)
  if not (oldPath.endsWith(".nim") and newPath.endsWith(".nim")): return
  var edits: seq[(string, seq[string])]
  var skipped: seq[string]
  for path in nimSourceFiles():
    if path == newPath: continue
    let i = bufIndexByPath(path)
    var ls = if i >= 0: bufs[i].lines else: (try: readFile(path).splitLines except IOError, OSError: @[])
    let dir = parentDir(path)
    var changed = false
    var inImport = false
    var importInd = 0
    for l in 0 .. ls.high:
      let t = ls[l].strip
      let ind = leadingWs(ls[l]).len
      var fromStmt = false
      if t.startsWith("import ") or t.startsWith("include ") or t == "import":
        inImport = true
        importInd = ind
      elif t.startsWith("from "):
        inImport = true
        fromStmt = true
        importInd = ind
      elif inImport and (t.len == 0 or ind <= importInd): inImport = false
      if not inImport: continue
      let spans = moduleRefSpans(ls[l], dir, oldPath, fromStmt)
      if fromStmt: inImport = false
      for k in countdown(spans.high, 0):
        let (a, e, written) = spans[k]
        var repl: string
        let inBrackets = ls[l][a ..< e] != written          # a/[b, c]: only the name inside the brackets
        if parentDir(oldPath) == parentDir(newPath):
          repl = splitFile(newPath).name
          if not inBrackets:
            let slash = written.rfind('/')
            repl = (if slash >= 0: written[0 .. slash] else: "") & repl
        elif inBrackets:
          skipped.add relPath(path) & ":" & $(l + 1)
          continue
        else:
          repl = relativePath(newPath.changeFileExt(""), dir).replace('\\', '/')
          if written.startsWith("./") and not repl.startsWith("."): repl = "./" & repl
        ls[l] = ls[l][0 ..< a] & repl & ls[l][e .. ^1]
        changed = true
    if changed: edits.add (path, ls)
  if edits.len == 0:
    if skipped.len > 0: warn("Update these imports by hand: " & skipped.join(", "))
    return
  askConfirm("Update the imports in " & $edits.len & " file(s) that use " & splitFile(oldPath).name & "? (y/n)",
             proc(c: char) =
    if c notin {'y', 'Y'}: return
    for (path, ls) in edits:
      let i = bufIndexByPath(path)
      if i >= 0: bufs[i].setTextMinimal(ls.join("\n"))
      else:
        try:
          writeFile(path, ls.join("\n"))
          fileWritten(path)
        except IOError, OSError: error("Could not write " & relPath(path))
    info("Imports updated in " & $edits.len & " file(s)" & (if skipped.len > 0: " — by hand: " & skipped.join(", ") else: "")))

proc peekLines(path: string): seq[string] =
  ## a file's lines: from its open tab when there is one
  let i = bufIndexByPath(path)
  if i >= 0: return bufs[i].lines
  try: result = readFile(path).splitLines
  except IOError, OSError: discard

proc cmdPeekDefinition() =
  ## the definition's code in a popup, without leaving the file (Alt+F12)
  let b = buf()
  if not nimEngineOn(b) or b.wordAt(b.primary.head).len == 0:
    cmdDefinition()
    return
  var defs: seq[(string, int, int, string)]
  try:
    let f = nxFileFor(b)
    if f != nil:
      defs = nxDefinition(f, b.lines, b.primary.head.line, b.primary.head.col)
      for d in defs.mitems:
        if d[0] == f.path: d[0] = b.path
  except Exception as e:
    internalError("Nim index", e)
  if defs.len == 0:
    info("No definition found for " & b.wordAt(b.primary.head))
    return
  var md = ""
  for k, (path, l, _, _) in defs:
    if k >= 3: break
    let ls = peekLines(if path.len == 0: b.path else: path)
    if l >= ls.len: continue
    # the declaration and its body: up to the next line at the same or a lower indentation
    let ind = leadingWs(ls[l]).len
    var e = l + 1
    while e < ls.len and e - l < 24 and (ls[e].strip.len == 0 or leadingWs(ls[e]).len > ind): inc e
    while e > l + 1 and ls[e - 1].strip.len == 0: dec e
    if md.len > 0: md.add "\n"
    md.add "**" & relPath(if path.len == 0: b.path else: path) & ":" & $(l + 1) & "**\n```nim\n"
    for x in ls[l ..< e]: md.add x[min(ind, leadingWs(x).len) .. ^1] & "\n"
    md.add "```"
  md.add "\n\nF12 goes there"
  showHover(md)

proc cmdPeekReferences() =
  ## every use, with its line of code, in a popup (Alt+Q lists them in the Search panel)
  let b = buf()
  var hits: seq[(string, int, int)]
  var decl = ""
  var ok = false
  let name = if b.wordAt(b.primary.head).len > 0: b.wordAt(b.primary.head) else: opAtCursor(b)
  if nimEngineOn(b) and name.len > 0:
    try: ok = engineReferences(b, b.primary.head, hits, decl)
    except Exception as e: internalError("Nim index", e)
  if not ok:
    cmdReferences()
    return
  if hits.len == 0:
    info("No references")
    return
  var md = "**" & $hits.len & " reference" & (if hits.len == 1: "" else: "s") & " to " & name & "**" &
           (if nxRefsCut: " (stopped after 10 s — not every use was checked)" else: "") & "\n```nim\n"
  var cache: Table[string, seq[string]]
  for k, (path, l, _) in hits:
    if k >= 40:
      md.add "# … " & $(hits.len - 40) & " more (Alt+Q lists them all)\n"
      break
    if path notin cache: cache[path] = peekLines(path)
    let ls = cache[path]
    let code = if l < ls.len: ls[l].strip else: ""
    md.add "# " & relPath(path) & ":" & $(l + 1) & "\n" & code & "\n"
  md.add "```"
  showHover(md)

proc cmdReferences() =
  let b = buf()
  if cEngineOn(b) and cEngReferences(b, b.primary.head): return       # C: ned's own engine
  var w = b.wordAt(b.primary.head)
  if w.len == 0 and nimEngineOn(b): w = opAtCursor(b)
  if w.len == 0:
    info("No symbol under cursor")
    return
  if nimEngineOn(b):
    var hits: seq[(string, int, int)]
    var decl = ""
    var ok = false
    try: ok = engineReferences(b, b.primary.head, hits, decl)
    except Exception as e: internalError("Nim index", e)
    if ok:
      showReferences("REFERENCES " & w, hits)
      if nxRefsCut: warn(RefsCutMsg)
      return
    if w.startsWith("`"):
      if decl.len > 0:
        info(w & " here is " & nimShownPath(decl) & "'s — ned lists the uses of the project's own operators")
      else: info("ned cannot tell which " & w & " this is: the types of what it works on are not known here")
      return
    if nsUsable(b):
      discard nsRequest(b, nsUse, b.wordRangeAt(b.primary.head)[0], w)
      return
    if nim3On() and b.path.len > 0:
      # Nim 3: nimony's own --usages where the engine could not tell which symbol this is
      info("Asking nimony…")
      let bid = b.id
      b.nimonyAsk("usages", b.wordRangeAt(b.primary.head)[0], proc(found: seq[(string, int, int)]) =
        if bufById(bid) == nil: return
        showReferences("REFERENCES " & w & " (nimony)", found)
        needRender = true)
      return
  let s = lspReady(b)
  if s != nil and s.caps != nil and s.caps{"referencesProvider"} != nil:
    discard s.lspRequest("textDocument/references", %*{"textDocument": b.docId,
      "position": s.lspPos(b, b.primary.head), "context": {"includeDeclaration": true}},
      LspReq(kind: lrReferences, bufId: b.id, extra: w))
  elif s == nil and nsUsable(b):
    discard nsRequest(b, nsUse, b.wordRangeAt(b.primary.head)[0], w)
  else:
    projectSearch(w)

proc createNimProject(name0: string) =
  let name = name0.replace(" ", "_").replace("-", "_")
  let dir = rootDir / name
  if dirExists(dir):
    error(relPath(dir) & " already exists")
    return
  var author = getEnv("USER", "me")
  try:
    let gc = readFile(getHomeDir() / ".gitconfig")
    for l in gc.splitLines:
      if l.strip.startsWith("name"):
        author = l.split('=', 1)[1].strip
        break
  except CatchableError: discard
  try:
    createDir(dir / "src")
    createDir(dir / "tests")
    if trustKey(dir) notin trustedDirs: trustedDirs.add trustKey(dir)    # (you made it: its code may run)
    writeFile(dir / name & ".nimble", "# Package\n\nversion       = \"0.1.0\"\nauthor        = \"" & author &
      "\"\ndescription   = \"A new Nim project\"\nlicense       = \"MIT\"\nsrcDir        = \"src\"\nbin           = @[\"" &
      name & "\"]\n\n# Dependencies\n\nrequires \"nim >= 2.0.0\"\n\ntask docs, \"Generate HTML documentation\":\n" &
      "  exec \"nim doc --project --outdir:htmldocs src/" & name & ".nim\"\n")
    writeFile(dir / "src" / name & ".nim", "## " & name & " — entry point\n\nproc greet*(who: string): string =\n" &
      "  ## Returns a friendly greeting.\n  \"Hello, \" & who & \"!\"\n\nwhen isMainModule:\n  echo greet(\"Nim\")\n")
    writeFile(dir / "tests" / "test_" & name & ".nim", "import std/unittest\nimport " & name & "\n\n" &
      "suite \"" & name & "\":\n  test \"greet\":\n    check greet(\"Nim\") == \"Hello, Nim!\"\n")
    writeFile(dir / "tests" / "config.nims", "switch(\"path\", \"$projectDir/../src\")\n")
    writeFile(dir / ".gitignore", "nimcache/\nhtmldocs/\n/" & name & "\ntests/*\n!tests/*.nim\n!tests/config.nims\n")
  except CatchableError as e:
    error("Cannot create project: " & e.msg)
    return
  if haveExe("git"): gitInitNewProject(dir)       # (with its first commit)
  discard openFile(dir)
  discard openFile(dir / "src" / name & ".nim")
  treeOpen = scrW >= 70
  loadNimbleInfo(true)
  info("Created Nim project " & name & " — Alt+R runs it, Alt+E opens the Nim panel")

proc nimbleAct(task: string): Action = (proc() = runNimble(task))

proc nimbleTaskActions(): seq[(string, string, proc() {.closure.})] =
  loadNimbleInfo()
  result.add act("build", "nimble build", proc() = runNimble("build"))
  result.add act("run", "nimble run", proc() = runNimble("run"))
  result.add act("test", "nimble test", proc() = runNimble("test"))
  result.add act("install deps", "nimble install -d -y", proc() = runNimble("install -d -y"))
  result.add act("check", "nimble check", proc() = runNimble("check"))
  result.add act("refresh packages", "nimble refresh", proc() = runNimble("refresh"))
  for (t, d) in nimble.tasks:
    result.add act(t, (if d.len > 0: d else: "nimble " & t), nimbleAct(t))

proc cmdNimbleTasks() =
  if not haveExe("nimble"):
    error("nimble not found (Termux: pkg install nim)")
    return
  openActions("Nimble" & (if nimble.name.len > 0: " — " & nimble.name else: ""), nimbleTaskActions())

proc cmdAtlas() =
  openActions("Atlas (workspace & dependencies)", @[
    act("install", "atlas install — set up deps from the .nimble file", proc() = runAtlas("install")),
    act("use package…", "atlas use <pkg> — add a dependency", proc() = openPrompt(pAtlasUse, "atlas use", "")),
    act("update", "atlas update — refresh dependency refs", proc() = runAtlas("update")),
    act("search…", "atlas search <terms>", proc() = openPrompt(pAtlasSearch, "atlas search", "")),
    act("init", "atlas init — make this folder an Atlas project", proc() = runAtlas("init")),
    act("pin", "atlas pin — write atlas.lock", proc() = runAtlas("pin")),
  ])

proc cmdNimony(run: bool) =
  let b = buf()
  if b.lang.mode != lmNim or not saveForTool(b): return
  if nimonyExe().len == 0:
    error("nimony not found — build it from github.com/nim-lang/nimony (nim c -r src/hastur/hastur build all)")
    return
  # (its build files in ned's own folder: nimony would make nimcache/ next to the file)
  runCommand(quoteShell(nimonyExe()) & (if run: " c -r " else: " check ") & nimonyArgs() & " " & quoteShell(b.path),
             parentDir(b.path))

proc setNimMode(m: string) =
  cfgNimMode = m
  info("Nim build mode: " & m)
  setSetting("nim.buildMode", %m)
proc setNimTarget(t: string) =
  cfgNimTarget = t
  info("Nim backend: " & t)
  setSetting("nim.backend", %t)
proc setNimCompiler(c: string) =
  cfgNimCompiler = c
  info("Compiler for Alt+R: " & c)
  setSetting("nim.compiler", %c)
