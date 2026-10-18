# ── Nim helpers: REPL, export marker, docs, nimble dependencies ──

# ── Send to REPL: the selection, the statement at the cursor, a `# %%` cell or the file, typed into the
#    language's REPL in its own terminal tab (inim / nim secret, python, node, irb …) ──

proc replCommandFor(lang: Lang): (string, string) =
  ## (command, short name) of a language's REPL: settings › repl.commands, else ned's choice ("" when none)
  let user = settingNode("repl.commands")
  if user != nil and user.kind == JObject and user{lang.id}.getStr.strip.len > 0:
    let c = user[lang.id].getStr.strip
    return (c, extractFilename(c.firstWord))
  case lang.id
  of "nim":
    if haveExe("inim"): ("inim --noAutoIndent", "inim")   # (ned sends the indentation itself)
    elif haveExe("nim"): ("nim secret", "nim secret")
    else: ("", "")
  of "python":
    var py = ""
    for v in [rootDir / ".venv" / "bin" / "python", rootDir / "venv" / "bin" / "python"]:
      if fileExists(v): py = v
    if py.len > 0: (quoteShell(py) & " -q", "python (venv)")
    elif haveExe("ipython"): ("ipython --no-banner --no-autoindent", "ipython")
    elif haveExe("python3"): ("python3 -q", "python")
    elif haveExe("python"): ("python -q", "python")
    else: ("", "")
  of "javascript": (if haveExe("node"): ("node", "node") else: ("", ""))
  of "typescript":
    if haveExe("tsx"): ("tsx", "tsx")
    elif haveExe("ts-node"): ("ts-node", "ts-node")
    elif haveExe("deno"): ("deno repl", "deno")
    else: ("", "")
  of "ruby": (if haveExe("irb"): ("irb", "irb") else: ("", ""))
  of "lua": (if haveExe("lua"): ("lua", "lua") else: ("", ""))
  of "shellscript": (quoteShell(termShell()), extractFilename(termShell()))
  else: ("", "")

proc replTerm(lang: Lang, restart = false): Term =
  ## the language's REPL tab (started when there is none, or it ended)
  let (cmd, name) = replCommandFor(lang)
  if cmd.len == 0: return nil
  for i, t in terms:
    if t.replLang == lang.id:
      if t.dead or restart or t.replCmd != cmd:
        if not t.dead and t.pid > 0:
          discard kill(t.pid, SIGHUP)
          discard kill(-t.pid, SIGHUP)
        if t.fd >= 0 and not t.dead: discard posix.close(t.fd)
        let nt = newTerm(t.w, t.h, rootDir, cmd)
        nt.replLang = lang.id
        nt.name = name
        terms[i] = nt
      curTerm = i
      return terms[i]
  let t = newTerm(max(20, lay.edW), max(4, lay.panelH - 1), rootDir, cmd)
  t.replLang = lang.id
  t.name = name
  terms.add t
  curTerm = terms.high
  t

proc replShow() =
  ## the terminal panel on the REPL's tab, the keyboard left in the editor
  let f = focus
  setPanel(pkTerminal)
  focus = (if f == fPanel: fPanel else: fEditor)
  needRender = true

proc replSend(lang: Lang, code: string): bool =
  if lang == nil: return false
  let t = replTerm(lang)
  if t == nil:
    error("No REPL for " & lang.name & " — set one in settings › repl.commands (e.g. {\"" & lang.id & "\": \"…\"})" &
          (if lang.id == "nim": " · nimble install inim" else: ""))
    return false
  t.replQ.add code
  t.replFlush()
  replShow()
  true

proc replMarker(s: string): bool =
  ## a cell boundary: # %% (Python, Nim, shell, Ruby) · // %% (JavaScript, TypeScript) · -- %% (Lua)
  let t = s.strip(trailing = false)
  for m in ["# %%", "#%%", "## %%", "// %%", "//%%", "-- %%", "--%%"]:
    if t.startsWith(m): return true
  false

proc replHasCells(b: Buffer): bool =
  for i in 0 ..< min(b.lines.len, 20_000):
    if replMarker(b.lines[i]): return true
  false

proc replCellAt(b: Buffer, line: int): (int, int) =
  ## the cell around `line`: its first and last line of code (the markers left out)
  var a = min(line, b.lines.high)
  if replMarker(b.lines[a]): a = a + 1
  else:
    while a > 0 and not replMarker(b.lines[a - 1]): dec a
  var e = max(a, line)
  while e + 1 < b.lines.len and not replMarker(b.lines[e + 1]): inc e
  (a, min(e, b.lines.high))

proc replStatementAt(b: Buffer, line: int): (int, int) =
  ## the statement at `line`: a block opener takes its block (deeper lines, else/elif/except/of …), a decorator
  ## its def, and an open bracket the lines up to its partner
  let a = line
  let ind = leadingWs(b.lines[a]).len
  var e = a
  var depth = 0
  proc bal(s: string): int =
    var q = '\0'
    for c in s:
      if q != '\0':
        if c == q: q = '\0'
      elif c in {'"', '\''}: q = c
      elif c == '#' and b.lang.lineComment == "#": break
      elif c in {'(', '[', '{'}: inc result
      elif c in {')', ']', '}'}: dec result
  depth = bal(b.lines[a])
  var k = a + 1
  var isDeco = b.lines[a].strip.startsWith("@") and b.lang.id == "python"
  while k < b.lines.len:
    let t = b.lines[k]
    if depth > 0:
      depth += bal(t)
      e = k
      inc k
      continue
    if t.strip.len == 0:
      inc k
      continue
    let ti = leadingWs(t).len
    if ti > ind or (ti == ind and replContinues(b.lang.id, t)) or isDeco:
      if isDeco and ti == ind and not t.strip.startsWith("@"): isDeco = false
      depth += bal(t)
      e = k
      inc k
    else: break
  (a, e)

proc replSendSelOrStatement() =
  ## Shift+Enter: the selection; else in a file with # %% cells the cell (then on to the next one);
  ## else the statement at the cursor (then on to the next one)
  let b = buf()
  let (cmd, _) = replCommandFor(b.lang)
  discard cmd
  if b.primary.hasSel:
    let (a, e) = b.primary.range
    discard replSend(b.lang, b.getText(a, e))
    return
  var l = b.primary.head.line
  if replHasCells(b):
    let (a, e) = replCellAt(b, l)
    var code: seq[string]
    for k in a .. e: code.add b.lines[k]
    if replSend(b.lang, code.join("\n")):
      var nx = e + 1
      while nx < b.lines.len and replMarker(b.lines[nx]): inc nx
      b.setSingle(Pos(line: min(nx, b.lines.high), col: 0))
      b.ensureVisible()
    return
  while l < b.lines.high and b.lines[l].strip.len == 0: inc l
  if b.lines[l].strip.len == 0: return
  let (a, e) = replStatementAt(b, l)
  var code: seq[string]
  for k in a .. e: code.add b.lines[k]
  if replSend(b.lang, code.join("\n")):
    var nx = e + 1
    while nx < b.lines.high and b.lines[nx].strip.len == 0: inc nx
    b.setSingle(Pos(line: min(nx, b.lines.high), col: 0))
    b.ensureVisible()

proc replSendCell(b: Buffer, line: int) =
  let (a, e) = replCellAt(b, line)
  var code: seq[string]
  for k in a .. e: code.add b.lines[k]
  discard replSend(b.lang, code.join("\n"))

proc replSendFile() =
  let b = buf()
  var code: seq[string]
  for l in b.lines:
    if not replMarker(l): code.add l
  discard replSend(b.lang, code.join("\n"))

proc enclosingProc(b: Buffer, line: int): (int, int)

proc replSendProc() =
  ## the proc / def / function around the cursor
  let b = buf()
  var a, e = -1
  if b.lang.mode == lmNim: (a, e) = b.enclosingProc(b.primary.head.line)
  else:
    var l = b.primary.head.line
    while l >= 0:
      let t = b.lines[l].strip
      if t.startsWith("def ") or t.startsWith("async def ") or t.startsWith("class ") or t.startsWith("function ") or
         t.startsWith("async function ") or t.startsWith("def ") or t.startsWith("local function ") or
         (t.startsWith("export ") and "function " in t):
        (a, e) = replStatementAt(b, l)
        while a > 0 and b.lines[a - 1].strip.startsWith("@"): dec a
        if e >= b.primary.head.line: break
        a = -1
      dec l
  if a < 0:
    info("Put the cursor inside a proc / def / function")
    return
  var code: seq[string]
  for k in a .. e: code.add b.lines[k]
  discard replSend(b.lang, code.join("\n"))

proc replOpen(lang: Lang, restart = false) =
  let t = replTerm(lang, restart)
  if t == nil:
    error("No REPL for " & lang.name & " — set one in settings › repl.commands")
    return
  setPanel(pkTerminal)
  focus = fPanel
  if lang.id == "nim" and not haveExe("inim"): info("nim secret is a basic REPL — nimble install inim gives a nicer one")

proc nimRepl() =
  if not haveExe("nim") and not haveExe("inim"):
    error("nim is not installed")
    return
  replOpen(langByName("Nim"))
