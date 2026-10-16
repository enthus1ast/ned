# ── Tasks: the project's Makefile targets, package.json scripts, just recipes, Taskfile tasks, cargo, go and
#    nimble — one list (F4 runs the last one again, Shift+F4 picks), like Zed's task runner ──

type ProjTask = object
  name, cmd, cwd, source, detail: string

proc taskKey(t: ProjTask): string = t.cwd & "|" & t.source & "|" & t.name

proc hasTaskFile(d: string): bool =
  for f in ["Makefile", "makefile", "GNUmakefile", "package.json", "justfile", "Justfile", ".justfile", "Cargo.toml",
            "go.mod", "Taskfile.yml", "Taskfile.yaml"]:
    if fileExists(d / f): return true
  try:
    for kind, p in walkDir(d):
      if kind == pcFile and p.endsWith(".nimble"): return true
  except OSError: discard

proc makeTargets(path, dir: string): seq[ProjTask] =
  ## the targets a person would type: not pattern rules, variables, special (.PHONY) or file-looking ones
  var text = ""
  try: text = readFile(path)
  except CatchableError: return
  var seen: HashSet[string]
  for l in text.splitLines:
    if l.len == 0 or l[0] in {' ', '\t', '#', '.', '-'}: continue
    let c = l.find(':')
    if c <= 0 or (c + 1 < l.len and l[c + 1] in {'=', ':'}): continue
    let head = l[0 ..< c]
    if '=' in head or '$' in head or '%' in head or head.startsWith("export ") or head.startsWith("include "): continue
    let dd = l.find("##", c)
    let desc = if dd >= 0: l[dd + 2 .. ^1].strip else: ""
    for t in head.splitWhitespace:
      if t.len == 0 or t in seen or '/' in t or (t.contains('.') and t.split('.')[^1].len in 1 .. 4): continue
      seen.incl t
      result.add ProjTask(name: t, cmd: "make " & quoteShell(t), cwd: dir, source: "make",
                          detail: (if desc.len > 0: desc else: "make " & t))
      if result.len >= 150: return

proc npmScripts(path, dir: string): seq[ProjTask] =
  var j: JsonNode
  try: j = parseFile(path)
  except CatchableError: return
  let sc = j{"scripts"}
  if sc == nil or sc.kind != JObject: return
  let pm = if fileExists(dir / "pnpm-lock.yaml"): "pnpm"
           elif fileExists(dir / "yarn.lock"): "yarn"
           elif fileExists(dir / "bun.lockb") or fileExists(dir / "bun.lock"): "bun"
           else: "npm"
  for k, v in sc:
    result.add ProjTask(name: k, cmd: pm & " run " & quoteShell(k), cwd: dir, source: pm, detail: v.getStr)

proc justRecipes(path, dir: string): seq[ProjTask] =
  var text = ""
  try: text = readFile(path)
  except CatchableError: return
  var doc = ""
  for l in text.splitLines:
    if l.len == 0:
      doc = ""
      continue
    if l[0] in {' ', '\t'}: continue
    if l[0] == '#':
      doc = l[1 .. ^1].strip
      continue
    if l[0] == '[':                       # [private], [group(…)] …: attributes of the next recipe
      if l.startsWith("[private"): doc = "\x01"
      continue
    let c = l.find(':')
    if c <= 0 or (c + 1 < l.len and l[c + 1] == '=') or ":=" in l[0 ..< min(l.len, c + 2)]:
      doc = ""
      continue
    var name = l[0 ..< c].strip(chars = {'@', ' '}).split(' ')[0]
    if name.len == 0 or name[0] == '_' or name in ["set", "alias", "export", "import", "mod"] or doc == "\x01" or
       not (name[0].isAlphaAscii):
      doc = ""
      continue
    result.add ProjTask(name: name, cmd: "just " & quoteShell(name), cwd: dir, source: "just",
                        detail: (if doc.len > 0: doc else: "just " & name))
    doc = ""

proc taskfileTasks(path, dir: string): seq[ProjTask] =
  var text = ""
  try: text = readFile(path)
  except CatchableError: return
  var inTasks = false
  for l in text.splitLines:
    if l.len == 0 or l.strip.startsWith("#"): continue
    if l[0] != ' ':
      inTasks = l.startsWith("tasks:")
      continue
    if not inTasks: continue
    let ind = l.len - l.strip(trailing = false).len
    let t = l.strip
    if ind == 2 and t.endsWith(":") and ' ' notin t:
      let n = t[0 ..< t.high].strip(chars = {'"', '\''})
      result.add ProjTask(name: n, cmd: "task " & quoteShell(n), cwd: dir, source: "task", detail: "task " & n)
    elif ind == 4 and t.startsWith("desc:") and result.len > 0:
      result[^1].detail = t[5 .. ^1].strip(chars = {' ', '"', '\''})

proc projectTasks(): seq[ProjTask] =
  ## everything runnable in the project folder (and in the current file's own sub-project)
  var dirs = @[rootDir]
  let b = buf()
  if b.path.len > 0 and b.path.startsWith(rootDir & "/"):
    var d = parentDir(b.path)
    while d.len > rootDir.len:
      if hasTaskFile(d):
        dirs.add d
        break
      d = parentDir(d)
  for d in dirs:
    let tag = if d == rootDir: "" else: relPath(d) & " · "
    var found: seq[ProjTask]
    for f in ["Makefile", "makefile", "GNUmakefile"]:
      if fileExists(d / f):
        found.add makeTargets(d / f, d)
        break
    if fileExists(d / "package.json"): found.add npmScripts(d / "package.json", d)
    for f in ["justfile", "Justfile", ".justfile"]:
      if fileExists(d / f):
        found.add justRecipes(d / f, d)
        break
    for f in ["Taskfile.yml", "Taskfile.yaml"]:
      if fileExists(d / f):
        found.add taskfileTasks(d / f, d)
        break
    if fileExists(d / "Cargo.toml"):
      for (n, c) in [("build", "cargo build"), ("run", "cargo run"), ("test", "cargo test"), ("check", "cargo check"),
                     ("clippy", "cargo clippy"), ("fmt", "cargo fmt")]:
        found.add ProjTask(name: n, cmd: c, cwd: d, source: "cargo", detail: c)
    if fileExists(d / "go.mod"):
      for (n, c) in [("build", "go build ./..."), ("test", "go test ./..."), ("run", "go run ."), ("vet", "go vet ./...")]:
        found.add ProjTask(name: n, cmd: c, cwd: d, source: "go", detail: c)
    if d == rootDir:
      loadNimbleInfo()
      if nimble.file.len > 0:
        let nd = nimbleDir()
        for (n, c) in [("build", "nimble build"), ("test", "nimble test"), ("run", "nimble run")]:
          found.add ProjTask(name: n, cmd: c, cwd: nd, source: "nimble", detail: c)
        for (t, desc) in nimble.tasks:
          found.add ProjTask(name: t, cmd: "nimble " & quoteShell(t), cwd: nd, source: "nimble",
                             detail: (if desc.len > 0: desc else: "nimble " & t))
    for t in found.mitems: t.detail = tag & t.detail
    result.add found
  for c in runConfigs():
    let (cmd, cwd) = runConfigCmd(c, false)
    if cmd.len > 0:
      result.add ProjTask(name: c{"name"}.getStr, cmd: cmd, cwd: cwd, source: "run", detail: cmd)

proc runTask(t: ProjTask) =
  let k = taskKey(t)
  let i = taskRecent.find(k)
  if i >= 0: taskRecent.delete(i)
  taskRecent.insert(k, 0)
  if taskRecent.len > 30: taskRecent.setLen(30)
  lastTask = t.cmd & "\x1f" & t.cwd & "\x1f" & t.source & " " & t.name
  runCommand(t.cmd, t.cwd)

proc cmdRunTask() =
  let ts = projectTasks()
  if ts.len == 0:
    info("No tasks found: a Makefile, package.json, justfile, Taskfile, Cargo.toml, go.mod or .nimble file has them " &
         "(or Run › Configurations)")
    return
  var order: seq[int]
  for k in taskRecent:                          # the ones you ran last come first
    for i, t in ts:
      if taskKey(t) == k and i notin order: order.add i
  for i in 0 .. ts.high:
    if i notin order: order.add i
  var items: seq[(string, string, Action)]
  for i in order:
    let t = ts[i]
    let recent = taskKey(t) in taskRecent
    capture t:
      items.add act((if recent: ic("history") & " " else: "  ") & t.source & ": " & t.name, truncTo(t.detail, 60),
                    proc() = runTask(t))
  openActions("Run a task (" & $ts.len & ")", items)

proc cmdRerunTask() =
  ## F4: the last task again (the list when there is none yet)
  let p = lastTask.split('\x1f')
  if p.len < 3:
    cmdRunTask()
    return
  info("▶ " & p[2])
  runCommand(p[0], p[1])
