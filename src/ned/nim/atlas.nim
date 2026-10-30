# ── Atlas (nim-lang/atlas): a project whose dependencies are in its own deps/ folder. What atlas selected (its
#    activation cache, deps/.cache/atlas.active.json) — version, commit, description; what the build uses (nim.cfg's
#    Atlas section); the projects linked in; atlas.lock against what is checked out. Its commands as forms and lists
#    (install, update, add a dependency, link, pin, replay, what changed, outdated, a Nim of its own for the project,
#    atlas-run's tasks, build and tests); its errors in Problems, on the .nimble's requires lines. ──

type AtlasDep = object
  key, name, version, commit, head, url, dir, desc: string   # key: atlas's name (nim-stew); name: its folder (stew)
  features: seq[string]
  linked, onPath, isRoot: bool
  lockCommit: string            # what atlas.lock pins ("" none)

var
  atlasMemo: tuple[key: string, at: MonoTime, deps: seq[AtlasDep]]
  atlasCfgMemo: tuple[path: string, at: times.Time, cfg: JsonNode]

proc nbInsertRequire(spec: string): int

proc atlasCfgPath(root: string): string =
  ## the project's atlas.config: next to its .nimble, else in deps/ (where `atlas init` writes it)
  if fileExists(root / "atlas.config"): return root / "atlas.config"
  if fileExists(root / "deps" / "atlas.config"): return root / "deps" / "atlas.config"
  ""

proc atlasConfig(root: string): JsonNode =
  ## the project's atlas.config parsed as JSON (an empty object when there is none or it does not parse), kept until the
  ## file's modification time changes
  let p = atlasCfgPath(root)
  if p.len == 0: return newJObject()
  try:
    let t = getLastModificationTime(p)
    if atlasCfgMemo.path == p and atlasCfgMemo.at == t: return atlasCfgMemo.cfg
    let j = parseJson(readFile(p))
    atlasCfgMemo = (p, t, j)
    j
  except CatchableError: newJObject()

proc atlasDepsDir(root: string): string =
  ## the folder atlas puts the dependencies in: atlas.config's "deps" (from the project folder when relative), else
  ## deps/
  let d = atlasConfig(root){"deps"}.getStr
  if d.len == 0: root / "deps" elif d.isAbsolute: d else: root / d

proc atlasNimCfgSection(root: string): seq[string] =
  ## nim.cfg's Atlas section, as written there
  try:
    var inside = false
    for l in readFile(root / "nim.cfg").splitLines:
      if "begin Atlas config section" in l: inside = true
      elif "end Atlas config section" in l: break
      elif inside: result.add l
  except CatchableError: discard

proc atlasIsProject(root = rootDir): bool =
  ## an Atlas project: its atlas.config, or nim.cfg with the section atlas writes
  if root.len == 0: return false
  if atlasCfgPath(root).len > 0: return true
  try: fileExists(root / "nim.cfg") and "begin Atlas config section" in readFile(root / "nim.cfg")
  except CatchableError: false

proc atlasGitHead(dir: string): string =
  ## the commit a checkout is at (atlas leaves them detached) — read from .git, no git started
  try:
    var gd = dir / ".git"
    if fileExists(gd):                                   # (a worktree or submodule: "gitdir: …")
      let t = readFile(gd).strip
      if t.startsWith("gitdir:"):
        gd = t[7 .. ^1].strip
        if not gd.isAbsolute: gd = dir / gd
    let h = readFile(gd / "HEAD").strip
    if not h.startsWith("ref:"): return h
    let r = h[4 .. ^1].strip
    if fileExists(gd / r): return readFile(gd / r).strip
    for l in readFile(gd / "packed-refs").splitLines:
      if l.endsWith(" " & r): return l.split(' ')[0]
  except CatchableError: discard
  ""

func atlasShortVersion(v: string): string =
  ## "0.6.4@5e9c0503…" → "0.6.4", "#head@73684aa…" → "#head", "1.2.3+5@abc^" stays readable
  let at = v.find('@')
  if at < 0: return v
  result = v[0 ..< at]
  if v.endsWith("^"): result.add "^"
  if "[pinned]" in v: result.add " [pinned]"

proc atlasDeps(root = rootDir, force = false): seq[AtlasDep] =
  ## the dependencies (cached a second, and until atlas writes again)
  if root.len == 0: return
  let dd = atlasDepsDir(root)
  let act = dd / ".cache" / "atlas.active.json"
  var key = root
  for p in [act, root / "atlas.lock", root / "nim.cfg"]:
    try: key.add "|" & $getLastModificationTime(p).toUnixFloat
    except CatchableError: key.add "|-"
  if not force and atlasMemo.key == key and msSince(atlasMemo.at) < 1500: return atlasMemo.deps
  # on nim.cfg's path
  var onPath: HashSet[string]
  for l in atlasNimCfgSection(root):
    let t = l.strip
    if t.startsWith("--path:"):
      var p = t[7 .. ^1].strip(chars = {'"', ' '})
      if not p.isAbsolute: p = root / p
      onPath.incl normalizedPath(p).strip(leading = false, chars = {'/'})
  # atlas.lock
  var lock = initTable[string, string]()          # dir (absolute) → commit
  try:
    let lj = parseJson(readFile(root / "atlas.lock"))
    for k, e in lj{"items"}.pairs:
      var d = e{"dir"}.getStr
      if d.startsWith("$deps"): d = dd / d[5 .. ^1].strip(chars = {'/'})
      elif d.startsWith("$project"): d = dd / d[8 .. ^1].strip(chars = {'/'})
      lock[normalizedPath(d)] = e{"commit"}.getStr
  except CatchableError: discard
  var seen: HashSet[string]
  try:
    let j = parseJson(readFile(act))
    for e in j{"packages"}:
      var d = AtlasDep(url: (if e{"url"}.kind == JString: e{"url"}.getStr else: $e{"url"}),
                       version: atlasShortVersion(e{"version"}.getStr), commit: e{"commit"}.getStr,
                       dir: normalizedPath(e{"ondisk"}.getStr), desc: e{"description"}.getStr,
                       isRoot: e{"isRoot"}.getBool)
      if d.isRoot: continue
      d.name = extractFilename(d.dir)
      d.key = e{"name"}.getStr
      if d.key.len == 0:
        let u = d.url.strip(leading = false, chars = {'/'})
        d.key = u[u.rfind('/') + 1 .. ^1].replace(".git", "")
      for f in e{"features"}: d.features.add f.getStr
      result.add d
      seen.incl d.dir
  except CatchableError: discard
  # (no activation cache yet — or a folder it does not know: what is there)
  try:
    for k, p in walkDir(dd):
      let nm = extractFilename(p)
      if nm.startsWith(".") or nm.startsWith("_") or nm.startsWith("nim-") and fileExists(p / "bin" / addFileExt("nim", ExeExt)): continue
      if k in {pcDir, pcLinkToDir} and normalizedPath(p) notin seen:
        var d = AtlasDep(name: nm, key: nm, dir: normalizedPath(p))
        for kk, f in walkDir(p):
          if f.endsWith(".nimble"):
            try:
              for l in readFile(f).splitLines:
                let t = l.strip
                if t.startsWith("version") and '"' in t: d.version = t[t.find('"') + 1 .. ^1].strip(chars = {'"'})
                elif t.startsWith("description") and '"' in t: d.desc = t[t.find('"') + 1 .. ^1].strip(chars = {'"'})
            except CatchableError: discard
            break
        result.add d
      elif k in {pcFile, pcLinkToFile} and nm.endsWith(".nimble-link"):
        # a project linked in (atlas link): the folder it points to
        try:
          let target = readFile(p).splitLines()[0].strip
          var d = AtlasDep(name: nm[0 ..< nm.len - ".nimble-link".len], linked: true,
                           dir: normalizedPath(if target.endsWith(".nimble"): parentDir(target) else: target))
          d.key = d.name
          var dup = false
          for x in result.mitems:
            if x.name == d.name or x.dir == d.dir:
              x.linked = true
              dup = true
          if not dup: result.add d
        except CatchableError: discard
  except CatchableError: discard
  for d in result.mitems:
    d.head = atlasGitHead(d.dir)
    d.onPath = d.dir.strip(leading = false, chars = {'/'}) in onPath
    if not d.onPath:
      for p in onPath:
        if p.startsWith(d.dir & "/"):          # (its srcDir on the path)
          d.onPath = true
          break
    d.lockCommit = lock.getOrDefault(d.dir)
  result.sort(proc(a, b: AtlasDep): int = cmp(a.name.toLowerAscii, b.name.toLowerAscii))
  atlasMemo = (key, getMonoTime(), result)

proc atlasEnvs(root = rootDir): seq[(string, string)] =
  ## the Nims `atlas env` put in the project: (version, folder)
  if root.len == 0: return
  try:
    for k, p in walkDir(atlasDepsDir(root)):
      let nm = extractFilename(p)
      if k in {pcDir, pcLinkToDir} and nm.startsWith("nim-") and fileExists(p / "bin" / addFileExt("nim", ExeExt)):
        result.add (nm[4 .. ^1], p)
  except CatchableError: discard
  result.sort(proc(a, b: (string, string)): int = verCmp(b[0], a[0]))

# ── running atlas: the Output panel; its errors on the .nimble ──

proc atlasNeeds(): bool =
  ## whether atlas is installed; if not, asks whether to build it with nimble and says false
  if haveExe("atlas"): return true
  askConfirm("atlas is not installed — build it with nimble (nimble install atlas)? (y/n)", proc(c: char) =
    if c == 'y': runCommand("nimble install -y atlas", rootDir))
  false

proc atlasRun(args: string, after: proc(code: int) {.closure.} = nil) =
  ## atlas in the project (no colours: its [Error] lines are read into Problems), then its deps read again
  if not atlasNeeds(): return
  runCommand("atlas --colors:off " & args, rootDir, proc(code: int) =
    atlasMemo.key = ""
    nxLibGuessed = false                 # (the engine reads nim.cfg's paths again)
    loadNimbleInfo(true)
    if after != nil: after(code))

proc atlasRunTool(args: string, after: proc(code: int) {.closure.} = nil) =
  ## atlas-run (tasks, build, tests)
  if not haveExe("atlas-run"):
    if haveExe("atlas"): error("atlas-run is not installed — it comes with atlas 0.16 (nimble install atlas)")
    else: discard atlasNeeds()
    return
  runCommand("atlas-run " & args, rootDir, after)

proc atlasProblemLine(j: Job, s: string): int =
  ## (an atlas job's output line) [Error]  (pkg) message → kept for the .nimble; its severity for the panel
  let t = s.strip
  var sev = 0
  if t.startsWith("[Error]"): sev = 1
  elif t.startsWith("[Warn]"): sev = 2
  else: return 0
  let a = t.find('(')
  let e = t.find(')', a + 1)
  if a < 0 or e < 0: return sev
  let pkg = t[a + 1 ..< e]
  let msg = t[e + 1 .. ^1].strip
  if pkg == "atlas" and (msg.startsWith("error summary") or msg == "failed"): return sev
  if sev == 1 or "cannot resolve" in msg or "no versions" in msg or "conflict" in msg:
    j.atlasMsgs.add (sev, pkg, msg)
  sev

proc atlasProblemsDone(j: Job) =
  ## the messages on the project's .nimble: on the requires line of the package they name, else its first one
  if j.atlasMsgs.len == 0: return
  loadNimbleInfo(true)
  if nimble.file.len == 0: return
  var lines: seq[string]
  try: lines = readFile(nimble.file).splitLines
  except CatchableError: return
  var first = -1
  for i, l in lines:
    if l.strip.startsWith("requires"):
      first = i
      break
  var seen: HashSet[string]
  for (sev, pkg, msg) in j.atlasMsgs:
    let k = pkg & "\t" & msg
    if k in seen: continue
    seen.incl k
    var at = -1
    let short = pkg.split('.')[0].toLowerAscii
    let bare = short.replace("nim-", "")
    for i, l in lines:
      let t = l.strip.toLowerAscii
      if t.startsWith("requires") and (short in t or ("\"" & bare) in t or ("/" & bare) in t):
        at = i
        break
    if at < 0: at = max(0, first)
    diagsBuild.mgetOrPut(nimble.file, @[]).add Diag(line: at, col: 0, eline: at, ecol: -1, sev: sev,
                                                    msg: "atlas: " & (if pkg.len > 0: pkg & ": " else: "") & msg,
                                                    src: "atlas")
  rebuildProblems()

# ── the commands ──

proc atlasDepMenu(d: AtlasDep) =
  ## a dependency's own actions
  let dep = d
  var items: seq[(string, string, Action)]
  items.add act("Open its .nimble", tildePath(dep.dir), proc() =
    try:
      for k, f in walkDir(dep.dir):
        if f.endsWith(".nimble"):
          discard openFile(f)
          return
      info("No .nimble file in " & tildePath(dep.dir))
    except CatchableError: discard)
  items.add act("Update it", "atlas update " & dep.key, proc() = atlasRun("update " & quoteShell(dep.key)))
  if dep.linked:
    items.add act("Unlink it", "atlas unlink — its own checkout again", proc() = atlasRun("unlink " & quoteShell(dep.name)))
  if dep.url.startsWith("http"):
    items.add act("Copy its URL", dep.url, proc() =
      clipSet(dep.url)
      info("Copied " & dep.url))
  items.add act("Its history", "git log", proc() =
    toolOutput("git log — " & dep.name, "git --no-pager log --oneline --decorate -n 100", dep.dir,
               proc(o: string): string = o, langByName("Text")))
  items.add act("Copy its folder", tildePath(dep.dir), proc() =
    clipSet(dep.dir)
    info("Copied " & dep.dir))
  openActions(dep.name & " " & dep.version & (if dep.desc.len > 0: " — " & truncTo(dep.desc, 50) else: ""), items)

proc cmdAtlasUpdateOne() =
  ## "Atlas: update which dependency": a list of the dependencies in deps/, each updated with `atlas update`
  let ds = atlasDeps(force = true)
  if ds.len == 0:
    info("No dependencies in " & tildePath(atlasDepsDir(rootDir)) & " — Atlas: install")
    return
  var items: seq[(string, string, Action)]
  for d in ds:
    let k = d.key
    let label = d.name
    let detail = d.version & (if d.desc.len > 0: " · " & truncTo(d.desc, 60) else: "")
    capture k:
      items.add act(label, detail, proc() = atlasRun("update " & quoteShell(k)))
  openActions("Atlas: update which dependency", items)

proc atlasPackageNames(): seq[(string, string)] =
  ## the package list: nimble's, else the one atlas keeps in deps/
  result = nxPackageNames()
  if result.len > 0: return
  let dd = atlasDepsDir(rootDir)
  for p in [dd / ".cache" / "packages.json", dd / "_packages" / "packages.json"]:
    try:
      for e in parseJson(readFile(p)):
        let n = e{"name"}.getStr
        if n.len > 0: result.add (n, e{"description"}.getStr)
      if result.len > 0: return
    except CatchableError: discard

proc cmdAtlasAddDependency(pkg0 = "") =
  ## a form: the package (a name, a URL, gh:user/repo — or one from the list), its versions, installed now
  let f = newForm("Atlas: add a dependency",
    "A package by its name in the package list, a git URL, or a forge alias: gh:user/repo, gl:, srht:, cb:.")
  f.addText("pkg", "Package", pkg0, "name, URL or gh:user/repo")
  f.addLink("Choose from the package list…", proc() =
    let names = atlasPackageNames()
    if names.len == 0:
      error("No package list yet — Atlas: install (or nimble refresh) fetches one")
      return
    var items: seq[(string, string, Action)]
    var search: seq[string]
    for (n, d) in names:
      let nn = n
      let dd = truncTo(d, 90)
      capture nn:
        items.add act(nn, dd, proc() =
          f.formField("pkg").text = nn
          f.formField("pkg").cur = nn.len
          f.focus = 2)
      search.add d.toLowerAscii
    openActions("A package (type a name or words of its description)", items, search),
    "nimble's list of packages (or the one atlas keeps in deps/)")
  f.addText("ver", "Versions", "", "any — or >= 1.2, ^= 1.2, #head, #<commit>",
            "Empty: atlas picks (its resolver). Else what the requires line asks for")
  f.addCheck("install", "Install it now (atlas install)", true)
  f.onButton = proc(ff: Form, id: string): bool =
    if id != "ok": return true
    let pkg = ff.formValue("pkg").strip
    let ver = ff.formValue("ver").strip
    if pkg.len == 0:
      ff.error = "Which package?"
      return false
    if ver.len == 0 and ff.formChecked("install"):
      atlasRun("use " & quoteShell(pkg))              # (atlas writes the requires line itself)
      return true
    let spec = if ver.len == 0: pkg elif ver.startsWith("#"): pkg & ver else: pkg & " " & ver
    if nbInsertRequire(spec) < 0: return true
    if ff.formChecked("install"): atlasRun("install")
    else: info("Added requires \"" & spec & "\" — Atlas: install fetches it")
    true
  openForm(f)

proc cmdAtlasLink() =
  ## another project of yours as a dependency (its working copy, not a checkout)
  let f = newForm("Atlas: link a project", "A folder with a .nimble file: the project uses it as it is (atlas link).")
  f.addText("dir", "Folder", "", "../myotherlib")
  f.onButton = proc(ff: Form, id: string): bool =
    if id != "ok": return true
    var d = expandTilde(ff.formValue("dir").strip)
    if d.len == 0:
      ff.error = "Which folder?"
      return false
    if not d.isAbsolute: d = rootDir / d
    if not dirExists(d):
      ff.error = "No such folder: " & tildePath(d)
      return false
    atlasRun("link " & quoteShell(d))
    true
  openForm(f)

proc cmdAtlasUnlink() =
  ## "Atlas: unlink which project": a list of the projects linked in, each unlinked with `atlas unlink`; says so when
  ## none is linked
  var items: seq[(string, string, Action)]
  for d in atlasDeps(force = true):
    if d.linked:
      let n = d.name
      let where = tildePath(d.dir)
      capture n:
        items.add act(n, where, proc() = atlasRun("unlink " & quoteShell(n)))
  if items.len == 0:
    info("No project is linked in — Atlas: link a project… does it")
    return
  openActions("Atlas: unlink which project", items)

proc cmdAtlasEnv() =
  ## a Nim of the project's own (atlas env): installed into deps/nim-<version>, and used for this project
  let envs = atlasEnvs()
  let f = newForm("Atlas: a Nim for this project",
    "atlas env installs a Nim into the project's deps/ folder (a release build, or built from source).")
  var have: seq[string]
  for (v, _) in envs: have.add v
  if have.len > 0: f.addNote("Already in this project: " & have.join(", "))
  f.addText("ver", "Version", (if tcNeeds.len > 0: tcNeeds.strip(chars = {'>', '=', ' ', '^', '~'}) else: ""),
            "2.2.4, devel, …", "A release (2.2.4), devel, or a branch with Source")
  f.addChoice("mode", "How", @["auto", "binary", "source"], "auto", "auto: a release build when there is one, else " &
              "built from source", @["Automatic", "A release build", "Built from source"])
  f.addCheck("use", "Use it for this project (nim.toolchain)", true,
             "In .ned/settings.json: every tool ned starts uses it")
  f.onButton = proc(ff: Form, id: string): bool =
    if id != "ok": return true
    let v = ff.formValue("ver").strip
    if v.len == 0:
      ff.error = "Which version?"
      return false
    let mode = ff.formValue("mode")
    let use = ff.formChecked("use")
    atlasRun("env " & (if mode == "binary": "--binary " elif mode == "source": "--source " else: "") & quoteShell(v),
      proc(code: int) =
        let d = atlasDepsDir(rootDir) / ("nim-" & v)
        if code == 0 and use and fileExists(d / "bin" / addFileExt("nim", ExeExt)):
          setProjectSetting("nim.toolchain", %d)
          info("This project uses Nim " & v & " (" & tildePath(d) & ")"))
    true
  openForm(f)

proc cmdAtlasTasks() =
  ## atlas-run's tasks of the .nimble — the list, then one runs
  if not haveExe("atlas-run"):
    atlasRunTool("task --list")
    return
  discard startJob(jkTool, "atlas-run task --list 2>&1", rootDir, proc(j: Job) =
    var items: seq[(string, string, Action)]
    for l in j.output.splitLines:
      let t = l.strip
      if t.len == 0 or t.startsWith("[") or t.endsWith(":"): continue
      let name = t.splitWhitespace()[0]
      let desc = t[name.len .. ^1].strip
      capture name:
        items.add act(name, desc, proc() = atlasRunTool("task " & quoteShell(name)))
    if items.len == 0:
      info("The .nimble has no tasks")
      return
    openActions("Atlas: run a task (atlas-run)", items))

proc cmdAtlasDepTree() =
  ## shows the dependency tree (`atlas deps --tree`) in the output view, without atlas's notices
  if not atlasNeeds(): return
  toolOutput("Atlas: dependency tree", "atlas --colors:off deps --tree 2>&1", rootDir,
             proc(o: string): string =
               var keep: seq[string]
               for l in o.splitLines:
                 if not l.startsWith("[Notice]"): keep.add l
               keep.join("\n"), langByName("Text"))

proc cmdAtlasInit() =
  ## after asking, makes the project folder an Atlas project: `atlas init`, then `atlas install`
  askConfirm("Make " & tildePath(rootDir) & " an Atlas project — its dependencies in deps/ (atlas init, then " &
             "atlas install)? (y/n)", proc(c: char) =
    if c == 'y': atlasRun("init", proc(code: int) =
      if code == 0: atlasRun("install")))

proc cmdAtlas() =
  ## every Atlas command, in one list
  let isA = atlasIsProject()
  var items = @[
    act("Install", "atlas install — the dependencies the .nimble asks for, into deps/", proc() = atlasRun("install")),
    act("Update all", "atlas update — every dependency to its newest allowed version", proc() = atlasRun("update")),
    act("Update one…", "atlas update <dependency>", proc() = cmdAtlasUpdateOne()),
    act("Add a dependency…", "atlas use (a name, a URL, gh:user/repo) — or a requires line with versions",
        proc() = cmdAtlasAddDependency()),
    act("Link a project…", "atlas link — another project of yours, as it is", proc() = cmdAtlasLink()),
    act("Unlink…", "atlas unlink", proc() = cmdAtlasUnlink()),
    act("Pin (atlas.lock)", "atlas pin — the commits checked out, written down", proc() = atlasRun("pin")),
    act("Replay atlas.lock", "atlas rep — those commits checked out again", proc() = atlasRun("rep")),
    act("What changed since atlas.lock", "atlas changed", proc() = atlasRun("changed")),
    act("Outdated dependencies", "atlas outdated — those with newer tags", proc() = atlasRun("outdated")),
    act("Dependency tree", "atlas deps --tree", proc() = cmdAtlasDepTree()),
    act("A Nim for this project…", "atlas env <version> — into deps/, used for this project", proc() = cmdAtlasEnv()),
    act("Run a task…", "atlas-run task", proc() = cmdAtlasTasks()),
    act("Build", "atlas-run build — the .nimble's binaries", proc() = atlasRunTool("build")),
    act("Run the tests", "atlas-run tests — tests/t*.nim, in parallel", proc() = atlasRunTool("tests")),
    act("Search packages…", "atlas search <words>", proc() = openPrompt(pAtlasSearch, "atlas search", "")),
    act("Open atlas.config", "resolver, overrides, plugins", proc() =
      let p = atlasCfgPath(rootDir)
      if p.len > 0: discard openFile(p) else: info("No atlas.config — Atlas: make this an Atlas project"))]
  if not isA:
    items.insert(act("Make this an Atlas project", "atlas init, then atlas install", proc() = cmdAtlasInit()), 0)
  openActions("Atlas" & (if isA: " — " & $atlasDeps().len & " dependencies" else: ""), items)

# ── atlas.config: its keys on hover ──

const AtlasConfigKeys = [
  ("deps", "the folder the dependencies go in, from the project (default: deps)"),
  ("resolver", "how versions are chosen: MaxVer (the newest allowed, the default), SemVer (the newest without a " &
               "major bump), MinVer (the lowest that every requirement allows)"),
  ("nameOverrides", "a package name → its URL: names the package list does not have, or another fork"),
  ("urlOverrides", "a URL pattern → another URL (a mirror, a fork): \"https://github.com/x/$+\": \"https://…/$#\""),
  ("pkgOverrides", "a package → the URL used instead, whoever requires it"),
  ("plugins", "a folder of *.nims build plugins (foreign projects as dependencies)"),
  ("nimEnvs", "the Nims `atlas env` made for the project"),
  ("graph", "(atlas's own) the last dependency graph")]

proc atlasConfigHover(b: Buffer, p: Pos): string =
  ## the hover text for a key of atlas.config under the mouse (what the setting does), "" elsewhere or in other files
  if b.path.len == 0 or extractFilename(b.path) != "atlas.config" or p.line > b.lines.high: return ""
  let l = b.lines[p.line]
  for (k, doc) in AtlasConfigKeys:
    let q = l.find("\"" & k & "\"")
    if q >= 0 and p.col >= q and p.col <= q + k.len + 2:
      return "**" & k & "** (atlas.config)\n\n" & doc
  ""

# ── a new Nim project, as a form ──

proc cmdNewNimProject() =
  ## the project's name and folder, a program or a library, its license, where its dependencies go (nimble's
  ## folder, or the project's own deps/ with atlas), git, tests — then made and opened
  if not cfgFormButtons:
    openPrompt(pNewProject, "New Nim project name", "")
    return
  let f = newForm("New Nim project")
  f.width = 72
  f.addText("name", "Name", "", "myproject", "Letters, digits and _ (a - or a space becomes _)")
  f.addText("where", "In the folder", tildePath(rootDir), "", "The project is made in a new folder under this one")
  f.addChoice("kind", "Kind", @["bin", "lib", "hybrid"], "bin", "A program (bin = …), a library, or both",
              @["A program", "A library", "Both"])
  f.addText("desc", "Description", "", "A new Nim project")
  f.addChoice("license", "License", @["MIT", "Apache-2.0", "BSD-3-Clause", "GPL-3.0-only", "MPL-2.0", "Unlicense"], "MIT")
  let canAtlas = haveExe("atlas")
  f.addChoice("deps", "Dependencies", @["nimble", "atlas"], "nimble",
              "nimble: in nimble's folder, shared by your projects · atlas: in the project's own deps/ (atlas init)" &
              (if canAtlas: "" else: " — atlas is not installed (nimble install atlas)"),
              @["nimble (shared)", "atlas (the project's deps/)"])
  f.addCheck("git", "A git repository, with a first commit", haveExe("git"))
  f.addCheck("tests", "A tests folder (unittest)", true)
  f.addButton("Cancel", "cancel")
  f.addButton("Create", "ok", primary = true)
  f.onButton = proc(ff: Form, id: string): bool =
    if id != "ok": return true
    let name = ff.formValue("name").strip
    if name.len == 0:
      ff.error = "The project needs a name"
      return false
    if not (name[0] in Letters) or not name.replace("-", "_").replace(" ", "_").allCharsInSet(IdentChars):
      ff.error = "A name of letters, digits and _ (starting with a letter)"
      return false
    let where = expandTilde(ff.formValue("where").strip)
    if where.len > 0 and not dirExists(where):
      ff.error = "No such folder: " & where
      return false
    if ff.formValue("deps") == "atlas" and not canAtlas:
      ff.error = "atlas is not installed — choose nimble, or install it (nimble install atlas)"
      return false
    discard createNimProject(name, where, ff.formValue("kind"), ff.formValue("desc").strip, ff.formValue("license"),
                             ff.formValue("deps"), ff.formChecked("git"), ff.formChecked("tests"))
    true
  openForm(f)
