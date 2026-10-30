# ── your own commands (the "commands" setting): shell commands in the palette, with placeholders ──

const UserCmdMark = "your command"

proc problemsFromText(source, text, cwd: string): int =
  ## a build's or a linter's output → Problems, under `source` (what it sent before goes): file:line:col: msg,
  ## Nim's file(line, col) Error: …, Python's tracebacks … — the lines the Output panel links too
  let src = if source.len > 0: source else: "script"
  var keep = initDiagTable()
  for p, ds in diagsExt:
    var rest: seq[Diag]
    for d in ds:
      if d.src != src: rest.add d
    if rest.len > 0: keep[p] = rest
  diagsExt = keep
  inc diagGen                         # (a whole list put in place: counted as a change)
  for raw in text.splitLines:
    let (ok, path, l, c, sev, m) = parseErrLine(stripAnsi(raw), (if cwd.len > 0: cwd else: rootDir))
    if ok and path.len > 0:
      diagsExt.mgetOrPut(path, @[]).add Diag(line: l, col: c, eline: l, ecol: -1, sev: max(1, sev), msg: m, src: src)
      inc result
  rebuildProblems()
  needRender = true

proc runUserCommand(name: string, spec: JsonNode) =
  ## runs one of the user's commands from the commands setting (a string, or an object with run, input and output). The
  ## placeholders $file, $dir, $root, $name, $ext, $line, $col, $word and $selection in the shell command are filled in
  ## (quoted), and a file with changes is saved first when the command uses $file. The selection or the file goes to its
  ## input when asked (replace output reads one by default). The output goes to the Output panel, the terminal, or — as
  ## a job — replaces the selection or the file, is inserted at the cursor, shown in a popup or a message, or is read as
  ## Problems; a failing command shows its output as an error
  let b = buf()
  let run = if spec.kind == JString: spec.getStr else: spec{"run"}.getStr
  if run.strip.len == 0:
    warn("The command \"" & name & "\" has no \"run\"")
    return
  let output = if spec.kind == JObject and spec{"output"}.getStr.len > 0: spec{"output"}.getStr else: "panel"
  var input = if spec.kind == JObject: spec{"input"}.getStr else: ""
  let (a, e) = b.primary.range
  let sel = if a != e: b.getText(a, e) else: ""
  if input.len == 0 and output == "replace": input = (if sel.len > 0: "selection" else: "file")
  if "$file" in run and b.dirty and b.path.len > 0: discard b.saveBuffer()
  let dir = if b.path.len > 0: parentDir(b.path) else: rootDir
  let sf = splitFile(b.path)
  var cmd = run.multiReplace(("$file", quoteShell(b.path)), ("$dir", quoteShell(dir)), ("$root", quoteShell(rootDir)),
                             ("$name", quoteShell(sf.name)), ("$ext", sf.ext), ("$line", $(b.primary.head.line + 1)),
                             ("$col", $(b.primary.head.col + 1)), ("$word", quoteShell(b.wordAt(b.primary.head))),
                             ("$selection", quoteShell(sel)))
  if input in ["selection", "file"]:
    let tmp = privTmp("cmd-input") & ".txt"
    try: writeFile(tmp, (if input == "selection": sel else: b.lines.join("\n") & "\n"))
    except IOError, OSError:
      error("Could not write " & tmp)
      return
    cmd = "(" & cmd & ") < " & quoteShell(tmp)
  case output
  of "terminal":
    runInTerm(cmd)
  of "panel":
    runCommand(cmd, dir)
  else:
    let id = b.id
    let wholeDoc = output == "replace" and sel.len == 0
    discard startJob(jkTool, cmd, dir, proc(j: Job) =
      var o = j.output
      if j.code != 0 and output != "problems":
        error(name & " failed (exit " & $j.code & ")" & (if o.strip.len > 0: ":\n" & o.strip else: ""))
        return
      let tb = bufById(id)
      case output
      of "replace", "insert":
        if tb == nil or not tb.canEdit(): return
        if not (if output == "replace" and not wholeDoc: sel else: "").endsWith("\n") and o.endsWith("\n"):
          o.setLen(o.len - 1)
        if wholeDoc: tb.setTextMinimal(o)
        else:
          tb.beginEdit()
          if output == "replace" and a != e: discard tb.replaceText(a, e, o)
          else: discard tb.replaceText(tb.primary.head, tb.primary.head, o)
          tb.endEdit()
        info(name & ": done")
      of "popup": showHover("**" & name & "**\n```\n" & (if o.strip.len > 0: o.strip(leading = false) else: "(no output)") & "\n```")
      of "problems":
        let n = problemsFromText(name, o, dir)
        if n > 0:
          setPanel(pkProblems)
          info(name & ": " & $n & (if n == 1: " problem" else: " problems"))
        else: info(name & ": no problems")
      else: info(if o.strip.len > 0: o.strip else: name & ": done"))

proc userCmdExists(name: string): bool =
  ## whether the commands setting has a command of that name
  let cs = sval("commands")
  cs != nil and cs.kind == JObject and cs.hasKey(name)

proc setUserCmdField(name, field, value: string) =
  ## change one part of a command in the "commands" setting (a plain string becomes {"run": …})
  initSettingDefs()
  var cs = newJObject()
  let cur = sval("commands")
  if cur != nil and cur.kind == JObject:
    for k, v in cur.pairs: cs[k] = v
  var spec = if cs.hasKey(name): cs[name] else: newJObject()
  if spec.kind == JString: spec = %*{"run": spec.getStr}
  if spec.kind != JObject: spec = newJObject()
  if field == "delete":
    cs.delete(name)
  else:
    if value.len == 0: spec.delete(field) else: spec[field] = %value
    cs[name] = spec
  setSetting("commands", cs)

proc userCmdOutputMenu(name: string) =
  ## a menu of the places the output of the user's command can go; the one chosen is stored in the commands setting
  var items: seq[(string, string, Action)]
  for (o, d) in [("panel", "the Output panel (the default)"), ("replace", "replaces the selection — or the whole file"),
                 ("insert", "inserted at the cursor"), ("popup", "a popup"), ("message", "a short message"),
                 ("problems", "its file:line: messages become Problems (a linter, a build)"),
                 ("terminal", "runs in the terminal (interactive)")]:
    let oo = o
    let dd = d
    capture oo, dd:
      items.add act(oo, dd, proc() =
        setUserCmdField(name, "output", oo)
        info("“" & name & "”: output → " & oo & " · it is in the palette now"))
  openActions("Where does the output of “" & name & "” go?", items)

proc userCmdInputMenu(name: string) =
  ## a menu of what the user's command can read on its input (the default, the selection, the file, nothing); the one
  ## chosen is stored in the commands setting
  var items: seq[(string, string, Action)]
  for (o, d) in [("", "nothing (replace: the selection or the file)"), ("selection", "the selected text"),
                 ("file", "the whole file"), ("none", "nothing at all")]:
    let oo = o
    let dd = d
    capture oo, dd:
      items.add act((if oo.len > 0: oo else: "default"), dd, proc() =
        setUserCmdField(name, "input", oo)
        info("“" & name & "”: input → " & (if oo.len > 0: oo else: "default")))
  openActions("What does “" & name & "” read on its input?", items)

proc cmdEditUserCommands() =
  ## the "commands" setting as a list: add one, or pick one to run, change or delete it
  initSettingDefs()
  var items: seq[(string, string, Action)]
  items.add act("+ Add a command…", "a shell command of yours, in the palette", proc() =
    openPrompt(pUserCmdName, "Name of the new command (as the palette shows it)", ""))
  let cs = sval("commands")
  if cs != nil and cs.kind == JObject:
    for name, spec in cs.pairs:
      let n = name
      let run = if spec.kind == JString: spec.getStr else: spec{"run"}.getStr
      let outp = if spec.kind == JObject and spec{"output"}.getStr.len > 0: spec{"output"}.getStr else: "panel"
      let inp = if spec.kind == JObject: spec{"input"}.getStr else: ""
      capture n, run, outp, inp:
        items.add act(n, run & "  → " & outp, proc() =
          openActions(n, @[
            act("Run it", "", proc() = runCmd(n)),
            act("Change the shell command…", run, proc() =
              userCmdEditing = n
              openPrompt(pUserCmdRun, "Shell command for “" & n & "” ($file $dir $line $word $selection …)", run)),
            act("Where the output goes…", outp, proc() = userCmdOutputMenu(n)),
            act("What it reads…", (if inp.len > 0: inp else: "default"), proc() = userCmdInputMenu(n)),
            act("Delete", "", proc() =
              askConfirm("Delete the command “" & n & "”? (y/n)", proc(c: char) =
                if c in {'y', 'Y'}:
                  setUserCmdField(n, "delete", "")
                  info("Deleted “" & n & "”")))]))
  openActions("Your commands (settings › commands)", items)

proc refreshUserCommands() =
  ## the "commands" setting → palette commands (they can have keys through "keys")
  var keep: seq[Command]
  for c in commands:
    if c.keys != UserCmdMark: keep.add c
  commands = keep
  initSettingDefs()
  let cs = sval("commands")
  if cs == nil or cs.kind != JObject: return
  for name, spec in cs.pairs:
    let n = name
    let sp = spec
    capture n, sp:
      commands.add Command(name: n, keys: UserCmdMark, action: proc() = runUserCommand(n, sp))

var pipeLast = ""                 # (the last command a selection went through: offered again)

proc pipeThroughCommand(cmd: string) =
  ## the selection — or the whole file — through a shell command, its output in its place (sort, jq ., column -t,
  ## a formatter of your own …); one undo step
  if cmd.strip.len == 0: return
  pipeLast = cmd.strip
  if not buf().canEdit():
    info("This file cannot be changed")
    return
  runUserCommand("| " & pipeLast, %*{"run": pipeLast, "output": "replace"})

proc cmdPipeSelection() =
  ## Pipe through a command: asks for a shell command (the last one is offered) to put the selection, or the whole file,
  ## through; its output takes its place
  let b = buf()
  let (a, e) = b.primary.range
  openPrompt(pPipeCmd, "Put " & (if a != e: "the selection" else: "the whole file") &
             " through a command (its output replaces it: sort, jq ., column -t …)", pipeLast)
