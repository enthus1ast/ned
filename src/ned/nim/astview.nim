# ── the AST view (Nim: AST view): the code's tree as a macro gets it — `body: untyped` — from Nim's own parser
#    (nim e, parseStmt + treeRepr), and what the macro or template at the cursor expands to; beside the code in the
#    other pane, made again after each pause in the typing ──

const AstTitle = "AST"

var
  astOn = false
  astSrc = -1                     # the buffer whose code is shown
  astKey = ""                     # what is on show: the text's version, the lines, the call at the cursor
  astBusy = false
  astTree = ""                    # the parts of the view, as they come in
  astExpand = ""

func astDedent(lines: seq[string]): string =
  var ind = high(int)
  for l in lines:
    if l.strip.len > 0: ind = min(ind, l.len - l.strip(trailing = false).len)
  if ind == high(int): ind = 0
  var res: seq[string]
  for l in lines: res.add (if l.len >= ind: l[ind .. ^1] else: l.strip(trailing = false))
  res.join("\n")

proc astRangeOf(b: Buffer): (int, int) =
  ## the lines shown: the selection's, or the top-level statement the cursor is in (with what is indented under it)
  let (a, e) = b.primary.range
  if a != e:
    return (a.line, (if e.col == 0 and e.line > a.line: e.line - 1 else: e.line))
  var first = b.primary.head.line
  while first > 0 and (b.lines[first].len == 0 or b.lines[first][0] in {' ', '\t', '#'} or
                       b.lines[first].strip.startsWith("#")):
    dec first
  var last = first
  while last + 1 < b.lines.len and (b.lines[last + 1].len == 0 or b.lines[last + 1][0] in {' ', '\t'} or
                                    b.lines[last + 1].startsWith("#")):
    inc last
  while last > first and b.lines[last].strip.len == 0: dec last
  (first, last)

proc astCallAt(b: Buffer): (string, int, bool) =
  ## the macro or template called at the cursor (its name, the line, a macro?), "" when none
  if not nimEngineOn(b): return ("", -1, false)
  let w = b.wordAt(b.primary.head)
  if w.len == 0: return ("", -1, false)
  try:
    let f = nxFileFor(b)
    if f == nil: return ("", -1, false)
    for r in nxLookup(nxScope(f), w):
      if r.sym.kind in {nxMacro, nxTemplate}: return (w, b.primary.head.line, r.sym.kind == nxMacro)
  except CatchableError: discard
  ("", -1, false)

proc astBuffer(): Buffer =
  for x in bufs:
    if x.title == AstTitle: return x
  result = newBuffer()
  result.title = AstTitle
  result.lang = langByName("Nim")
  result.readOnly = true
  result.indent = "  "
  bufs.add result

proc astShow() =
  ## the view's text, in the pane beside the code (the code's pane keeps the focus)
  let src = bufById(astSrc)
  if src == nil: return
  let ab = astBuffer()
  let top = ab.topLine
  ab.setContent(astTree & (if astExpand.len > 0: "\n" & astExpand else: ""))
  ab.topLine = clamp(top, 0, ab.lines.high)
  ab.savedSeq = ab.topSeq()
  if buf() == src:
    if not splitOn:
      splitOn = true
      splitDown = false
      activePane = 0
      panes[0] = Pane(bufId: src.id, snap: snapView(src))
    panes[1 - activePane] = Pane(bufId: ab.id, snap: snapView(ab))
  needRender = true

proc astRefresh(force = false) =
  let b = bufById(astSrc)
  if b == nil or b.lang == nil or b.lang.mode != lmNim:
    astOn = false
    return
  let (first, last) = astRangeOf(b)
  let (call, callLine, isMacro) = astCallAt(b)
  let key = $b.changeId & ":" & $first & "-" & $last & ":" & call
  if key == astKey and not force: return
  astKey = key
  if findExe("nim").len == 0:
    astTree = "# the AST view needs nim on PATH\n"
    astShow()
    return
  let code = astDedent(b.lines[first .. last])
  let base = privTmp("ast")
  let src = base & ".txt"
  let script = parentDir(base) / (extractFilename(base).replace("-", "_") & ".nims")   # (a module's name: an identifier)
  try:
    writeFile(src, code)
    writeFile(script, "import std/macros\nlet code = readFile(" & escape(src) & ")\ntry:\n" &
              "  echo parseStmt(code).treeRepr\nexcept ValueError as e:\n  echo \"# not parsed: \", e.msg\n")
  except CatchableError as e:
    error("AST view: " & e.msg)
    return
  astBusy = true
  let header = "# AST of " & (if b.path.len > 0: extractFilename(b.path) else: b.name) & " lines " & $(first + 1) & "–" &
               $(last + 1) & " — the tree a macro gets as `body: untyped` (Nim's parser; select code to see its own)\n"
  # (nim e on a script of ned's own in its private folder: no project code runs — the folder of your settings is
  # trusted, the private one is the project's for the trust check)
  try: createDir(configDir())
  except CatchableError: discard
  discard startJob(jkTool, "nim e --hints:off --warnings:off " & quoteShell(script), configDir(), proc(j: Job) =
    astBusy = false
    try:
      removeFile(src)
      removeFile(script)
    except CatchableError: discard
    let o = stripAnsi(j.output).strip(leading = false)
    astTree = header & (if o.len > 0: o & "\n" else: "# (nothing)\n")
    if not astOn: return
    astShow())
  if call.len > 0 and not isMacro:
    # a template: written out by the engine, at once
    var text = ""
    try: text = nxExpandTemplate(nxFileFor(b), b.lines, b.primary.head.line, b.primary.head.col)[1]
    except CatchableError: discard
    astExpand = if text.len > 0: "# what the template " & call & " at the cursor writes out (ned's engine)\n" & text & "\n"
                else: ""
  elif call.len > 0 and haveExe("nim"):
    astExpand = "# " & call & " at the cursor: expanding (nim check --expandMacro)…\n"
    expandMacroJob(b, call, callLine, proc(at: int, text, err: string) =
      astExpand = if err.len > 0: "# " & call & ": not expanded — " & err & "\n"
                  else: "# what " & call & " at line " & $(at + 1) & " expands to (the compiler's expansion)\n" & text & "\n"
      if astOn: astShow())
  else: astExpand = ""

proc cmdAstView() =
  ## on for the current file (again: off)
  let b = buf()
  if astOn and (b.id == astSrc or b.title == AstTitle):
    astOn = false
    for i, x in bufs:
      if x.title == AstTitle:
        if splitOn and panes[1 - activePane].bufId == x.id: closeSplit()
        if i != curBuf: closeBufferAt(i)
        break
    info("AST view off")
    return
  if b.lang == nil or b.lang.mode != lmNim:
    info("The AST view is for Nim code")
    return
  astOn = true
  astSrc = b.id
  astKey = ""
  astTree = "# AST: Nim's parser is reading the code…\n"
  astExpand = ""
  astRefresh(true)
  astShow()
  info("AST view: the tree of the statement at the cursor (or the selection), again after each pause — run it again to close")

proc astPump() =
  ## after a pause in the typing (or a move to another statement), the view again
  if not astOn or astBusy or msSince(lastInputAt) < 450: return
  let b = buf()
  if b.id != astSrc:
    if b.lang != nil and b.lang.mode == lmNim and b.title.len == 0 and b.path.len > 0:
      astSrc = b.id                        # (another Nim file: its tree)
      astKey = ""
    else: return
  astRefresh()

# ── the docs preview (Nim: preview this file's docs): the module's doc comment and each exported declaration with its
#    signature and doc comment, rendered as `nim doc` would show them (and each runnableExamples block's last result),
#    beside the code — made again after each pause in the typing ──

var docPvSrc = -1                 # the Nim buffer whose docs are previewed (-1: none)

proc docPvText(b: Buffer): string =
  let f = try: nxFileFor(b) except CatchableError: nil
  if f == nil: return "# " & b.name & "\n\n(the engine cannot read it)\n"
  result = "# " & nxModuleName(b.path) & "\n\n"
  if f.doc.strip.len > 0: result.add nxRstToMd(f.doc) & "\n\n"
  var n = 0
  for i in 0 ..< f.syms.len:
    let s = f.syms[i]
    if not s.exported or s.local or s.made or s.kind in {nxField, nxEnumVal, nxParam, nxForVar, nxResult}: continue
    inc n
    var d = nxDoc(NxRef(file: f, idx: int32(i)))
    let k = d.rfind("\n\n")
    if k > 0 and " · " in d[k .. ^1] and '\n' notin d[k + 2 .. ^1]: d.setLen(k)      # (not where it is: it is here)
    result.add "## " & s.name & "\n\n" & d & "\n\n"
    # (its runnableExamples: their last run)
    for l in s.line .. min(s.endLine, b.lines.high):
      if examplesHead(b.lines[l]):
        let st = exampleStatus.getOrDefault(b.path & ":" & $l, 0)
        result.add (case st
          of 1: "✓ its examples passed (line " & $(l + 1) & ")"
          of 2: "✗ its examples failed (line " & $(l + 1) & ") — Nim: run the examples at the cursor"
          of 3: "… its examples are running"
          else: "▶ its examples (line " & $(l + 1) & ") have not been run — Nim: run all examples in this file") & "\n\n"
  if n == 0: result.add "_Nothing is exported (a `*` after a name exports it)._\n"

proc cmdDocPreview() =
  ## on for the current Nim file (again: off)
  let b = buf()
  if docPvSrc >= 0 and (b.id == docPvSrc or (b.mdNimDocs and b.mdSrc == docPvSrc)):
    for i in countdown(bufs.high, 0):
      if bufs[i].mdNimDocs:
        if splitOn and panes[1 - activePane].bufId == bufs[i].id: closeSplit()
        if i != curBuf: closeBufferAt(i)
    docPvSrc = -1
    info("Docs preview off")
    return
  if b.lang == nil or b.lang.mode != lmNim:
    info("The docs preview is for Nim files")
    return
  let pv = newBuffer()
  pv.title = "Docs: " & b.name
  pv.lang = langByName("Markdown")
  pv.mdSrc = b.id
  pv.mdNimDocs = true
  pv.readOnly = true
  bufs.add pv
  docPvSrc = b.id
  let ci = bufs.find(b)
  if ci >= 0: curBuf = ci
  if not splitOn:
    splitOn = true
    splitDown = false
    activePane = 0
    panes[0] = Pane(bufId: b.id, snap: snapView(b))
  panes[1 - activePane] = Pane(bufId: pv.id, snap: snapView(pv))
  needRender = true
  info("Docs preview beside the code — as nim doc shows them; it follows your edits (run it again to close)")

var docPvSeen = -1

proc docPvPump() =
  ## after a pause in the typing: the preview again
  let b = bufById(docPvSrc)
  if b == nil:
    docPvSrc = -1
    return
  if msSince(lastInputAt) >= 400 and docPvSeen != b.changeId:
    docPvSeen = b.changeId
    needRender = true
