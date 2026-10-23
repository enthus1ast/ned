# ── Editing a .nimble (and a config.nims): the versions a `requires` can name (installed, and the package's git tags)
#    completed and on hover, a dependency added from the package list, the version bumped, the lock file's changes,
#    and the configuration the compiler ends up with (nim dump: the config files read, where they disagree) ──

var
  nbTags: Table[string, (float, seq[string])]   # package (lower case) → (when read, its version tags, newest first)
  nbTagsLoaded = false
  nbTagsAsked: HashSet[string]                   # (a lookup under way)

proc nbTagsFile(): string = stateDir() / "nimble-tags.json"

proc nbTagsLoad() =
  if nbTagsLoaded: return
  nbTagsLoaded = true
  try:
    for k, v in parseFile(nbTagsFile()).pairs:
      var ts: seq[string]
      for t in jitems(v{"tags"}): ts.add t.getStr
      nbTags[k] = (v{"at"}.getFloat, ts)
  except CatchableError: discard

proc nbTagsSave() =
  var j = newJObject()
  for k, (at, ts) in nbTags: j[k] = %*{"at": at, "tags": ts}
  try: writeFile(nbTagsFile(), $j)
  except CatchableError: discard

proc nbInstalledVersions(name: string): seq[string] =
  ## every version of the package installed (nimble's folders, the project's nimbledeps)
  let ln = name.toLowerAscii
  let dirs = [nimble.dir / "nimbledeps" / "pkgs2", nimble.dir / "nimbledeps" / "pkgs", nimbleHome() / "pkgs2",
              nimbleHome() / "pkgs"]
  for d in dirs:
    if d.len <= 1: continue
    try:
      for kind, p in walkDir(d):
        if kind notin {pcDir, pcLinkToDir}: continue
        let parts = extractFilename(p).split('-')
        if parts.len >= 2 and parts[0].toLowerAscii == ln and parts[1].len > 0 and parts[1][0] in Digits and
           parts[1] notin result:
          result.add parts[1]
    except OSError: discard
  result.sort(proc(a, b: string): int = verCmp(b, a))

proc nbFetchTags(name: string, done: proc() {.closure.} = nil) =
  ## the package's version tags (git ls-remote of its repository; kept a day)
  nbTagsLoad()
  let ln = name.toLowerAscii
  if ln in nbTagsAsked: return
  let url = packageUrls().getOrDefault(ln)
  if url.len == 0 or not gitArgSafe(url) or not haveExe("git"): return
  nbTagsAsked.incl ln
  let cmd = (if haveExe("timeout"): "timeout 30 " else: "") & "env GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs -- " &
            quoteShell(url) & " 2>&1"
  let j = startJob(jkAux, cmd, (if nimble.dir.len > 0: nimble.dir else: rootDir), proc(jj: Job) =
    nbTagsAsked.excl ln
    if jj.code != 0:
      if done != nil: done()                     # (what is installed, then: the repository could not be read)
      return
    var vs: seq[string]
    for l in jj.output.splitLines:
      let parts = l.splitWhitespace()
      if parts.len < 2: continue
      let v = tagVersion(parts[1])
      if v.len > 0 and v notin vs: vs.add v
    vs.sort(proc(a, b: string): int = verCmp(b, a))
    nbTags[ln] = (epochTime(), vs)
    nbTagsSave()
    if done != nil: done())
  if j == nil: nbTagsAsked.excl ln

proc nbTagsOf(name: string): (bool, seq[string]) =
  ## (known, the version tags newest first) — a lookup started when not known (or a day old)
  nbTagsLoad()
  let ln = name.toLowerAscii
  if ln in nbTags:
    let (at, ts) = nbTags[ln]
    if epochTime() - at > 86400: nbFetchTags(name)
    return (true, ts)
  (false, @[])

func nbRequiresAt(line: string, col: int): (bool, string, int) =
  ## the cursor in the version part of `requires "pkg >= 1.2"` (also `pkg@1.2`, `pkg#head`): (yes, the package,
  ## where the version starts)
  let t = line.strip(trailing = false)
  if not (t.startsWith("requires") or t.startsWith("taskRequires") or t.startsWith("task_requires")): return
  let c = min(col, line.len)
  var q = -1
  var k = 0
  while k < c:
    if line[k] == '"':
      if q < 0: q = k
      else: q = -1
    elif line[k] == ',' and q < 0: discard
    inc k
  if q < 0: return
  # (the string the cursor is in: the last one opened before it, from its quote or its comma)
  var s = q + 1
  for i in countdown(c - 1, q + 1):
    if line[i] == ',':
      s = i + 1
      break
  var i = s
  while i < c and line[i] == ' ': inc i
  let n0 = i
  while i < c and line[i] notin {' ', '<', '>', '=', '~', '^', '@', '#'}: inc i
  let name = line[n0 ..< i]
  if name.len == 0 or i >= c: return
  while i < c and line[i] in {' ', '<', '>', '=', '~', '^', '@', '#'}: inc i
  # (the version typed so far: digits and dots only)
  for j in i ..< c:
    if line[j] notin {'0'..'9', '.'}: return
  if line[0 ..< c].count('"') mod 2 == 0: return
  (true, name, i)

proc nbVersionItems(name: string): seq[CompItem] =
  let inst = nbInstalledVersions(name)
  let (_, tags) = nbTagsOf(name)
  var seen: HashSet[string]
  var vs: seq[string]
  for v in inst & tags:
    if v notin seen:
      seen.incl v
      vs.add v
  vs.sort(proc(a, b: string): int = verCmp(b, a))
  for k, v in vs:
    let det = (if v in inst: "installed" else: "") & (if v in inst and v in tags: " · " else: "") &
              (if v in tags: (if k == 0 or (tags.len > 0 and v == tags[0]): "newest tag" else: "tag") else: "")
    result.add CompItem(label: v, insert: v, filter: v, sortText: align($k, 5, '0'), kind: 12, detail: det,
                        doc: "`" & name & "` " & v & (if v in inst: " — installed" else: ""), docMade: true)

proc nbVersionComplete(b: Buffer, p: Pos, manual: bool, force = false): bool =
  ## in a .nimble's `requires "pkg >= …"`: the package's versions (true: it was there)
  if b.path.len == 0 or not b.path.endsWith(".nimble") or p.line >= b.lines.len: return false
  let (ok, name, start) = nbRequiresAt(b.lines[p.line], p.col)
  if not ok or name.toLowerAscii == "nim": return false
  if not force and compOpen and compLine == p.line and compStartCol == start and compItems.len > 0 and
     compItems[0].kind == 12:
    refilterComp()                               # (the list there: narrowed as the version is typed)
    return true
  loadNimbleInfo()
  compLine = p.line
  compStartCol = start
  compManual = manual
  compItems = nbVersionItems(name)
  compFromLsp = true
  refilterComp()
  let (known, _) = nbTagsOf(name)
  if not known:
    let bid = b.id
    let line = p.line
    nbFetchTags(name, proc() =
      let cb = buf()
      if cb.id == bid and cb.primary.head.line == line: discard nbVersionComplete(cb, cb.primary.head, manual, true))
  if compItems.len == 0 and manual: info("No versions of " & name & " known yet — looking them up…")
  true

proc nbHover(b: Buffer, p: Pos): string =
  ## a package in a .nimble's `requires`: what it is, the versions installed, the one the project uses, the newest
  if b.path.len == 0 or not b.path.endsWith(".nimble") or p.line >= b.lines.len: return ""
  let line = b.lines[p.line]
  let t = line.strip(trailing = false)
  if not (t.startsWith("requires") or t.startsWith("taskRequires")): return ""
  let w = b.wordAt(p)
  if w.len == 0 or w.toLowerAscii == "nim" or w.toLowerAscii == "requires": return ""
  # (a package's name: right after a quote or a comma)
  var k = p.col
  while k > 0 and line[k - 1] notin {'"', ','}:
    if line[k - 1] notin IdentChars and line[k - 1] != ' ': return ""
    dec k
  if k == 0: return ""
  loadNimbleInfo()
  var desc, url, license, web = ""
  for f in packageListFiles():
    if not fileExists(f): continue
    try:
      for e in parseFile(f):
        if e{"name"}.getStr.toLowerAscii == w.toLowerAscii:
          desc = e{"description"}.getStr
          url = e{"url"}.getStr
          license = e{"license"}.getStr
          web = e{"web"}.getStr
          break
    except CatchableError: discard
    if url.len > 0: break
  let inst = nbInstalledVersions(w)
  let used = installedVersion(w)
  let (known, tags) = nbTagsOf(w)
  if not known:
    let bid = b.id
    let pp = p
    nbFetchTags(w, proc() =
      let cb = buf()
      if cb.id == bid and cb.primary.head == pp and hoverOpen: cmdHover())
  result = "**" & w & "**" & (if desc.len > 0: " — " & desc else: " (not in nimble's package list)") & "\n\n"
  if used.len > 0: result.add "- the project builds with **" & used & "**\n"
  result.add "- installed: " & (if inst.len > 0: inst.join(", ") else: "none (nimble install -d)") & "\n"
  if tags.len > 0:
    result.add "- newest release: **" & tags[0] & "**" &
               (if used.len > 0 and verCmp(tags[0], used) > 0: " (newer than the one used — Nimble: outdated dependencies)" else: "") & "\n"
  elif not known and url.len > 0: result.add "- newest release: looking it up…\n"
  if license.len > 0: result.add "- license: " & license & "\n"
  if url.len > 0: result.add "- " & url & (if web.len > 0 and web != url: " · " & web else: "") & "\n"

# ── a dependency from the package list ──

proc nbInsertRequire(spec: string): int =
  ## `requires "spec"` into the project's .nimble (after its last requires; saved): the line, -1 when not done
  loadNimbleInfo(true)
  if nimble.file.len == 0:
    error("No .nimble file in this project")
    return -1
  let b = openFile(nimble.file)
  if b == nil: return -1
  var last = -1
  var dep = -1
  for i, l in b.lines:
    let t = l.strip
    if t.startsWith("requires ") or t.startsWith("requires(") or t.startsWith("requires\""): last = i
    if t.toLowerAscii.startsWith("# dependencies"): dep = i
  let at = if last >= 0: last + 1 elif dep >= 0: dep + 1 else: b.lines.len
  var text = "requires " & escape(spec) & "\n"
  if last < 0 and dep < 0 and at > 0 and b.lines[at - 1].strip.len > 0: text = "\n" & text
  let pos = if at < b.lines.len: Pos(line: at, col: 0) else: Pos(line: b.lines.high, col: b.lines[^1].len)
  b.beginEdit()
  discard b.replaceText(pos, pos, (if at >= b.lines.len: "\n" & text.strip(leading = false, chars = {'\n'}) else: text))
  b.endEdit()
  b.setSingle(Pos(line: min(at + (if text.startsWith("\n"): 1 else: 0), b.lines.high), col: 0))
  discard b.saveBuffer()
  at

proc nbAskInstall(spec: string) =
  askConfirm("Added requires \"" & spec & "\" — install it now (nimble install -d)? (y/n)", proc(c: char) =
    if c in {'y', 'Y'}: runCommand("nimble install -d -y", nimble.dir))

proc nbPickVersion(name: string) =
  let inst = nbInstalledVersions(name)
  let (_, tags) = nbTagsOf(name)
  var items: seq[(string, string, Action)]
  var seen: HashSet[string]
  var vs: seq[string]
  for v in tags & inst:
    if v notin seen:
      seen.incl v
      vs.add v
  vs.sort(proc(a, b: string): int = verCmp(b, a))
  let nm = name
  if vs.len > 0:
    let top = vs[0]
    items.add act(nm & " >= " & top, "the newest release, or a later one", proc() =
      if nbInsertRequire(nm & " >= " & top) >= 0: nbAskInstall(nm & " >= " & top))
    let parts = verParts(top)
    if parts.len >= 2:
      let caret = "^= " & top
      items.add act(nm & " " & caret, "this release's compatible ones (" & $parts[0] & ".x)", proc() =
        if nbInsertRequire(nm & " " & caret) >= 0: nbAskInstall(nm & " " & caret))
  items.add act(nm, "any version", proc() =
    if nbInsertRequire(nm) >= 0: nbAskInstall(nm))
  for v in vs:
    let vv = v
    capture vv:
      items.add act(nm & " == " & vv, (if vv in inst: "installed" else: "exactly this release"), proc() =
        if nbInsertRequire(nm & " == " & vv) >= 0: nbAskInstall(nm & " == " & vv))
  items.add act(nm & "#head", "the repository's newest commit", proc() =
    if nbInsertRequire(nm & "#head") >= 0: nbAskInstall(nm & "#head"))
  openActions("requires \"" & name & " …\" — which versions", items)

proc cmdNimbleAddDependency() =
  ## a package from nimble's list (name, description) → which versions → the requires line → installed, if you say so
  loadNimbleInfo(true)
  if nimble.file.len == 0:
    error("No .nimble file in this project (Nim: new project… makes one)")
    return
  let names = nxPackageNames()
  if names.len == 0:
    error("No nimble package list — run nimble refresh (or Nimble: outdated dependencies fetches one)")
    return
  var have: HashSet[string]
  for r in nimble.requires: have.incl splitRequire(r)[0].toLowerAscii
  var items: seq[(string, string, Action)]
  var search: seq[string]
  for (n, d) in names:
    let nn = n
    let det = (if nn.toLowerAscii in have: "already required · " else: "") & truncTo(d, 90)
    capture nn:
      items.add act(nn, det, proc() =
        let (known, _) = nbTagsOf(nn)
        if known: nbPickVersion(nn)
        else:
          info("Looking up the versions of " & nn & "…")
          nbFetchTags(nn, proc() = nbPickVersion(nn))
          if nn.toLowerAscii notin nbTagsAsked: nbPickVersion(nn))   # (no repository to ask: those installed, any)
    search.add d.toLowerAscii
  openActions("Add a dependency — " & $names.len & " packages (type a name or words of its description)", items, search)

# ── the version ──

proc nbBumpAct(bid, l, c0, c1: int, newV: string): Action =
  proc() =
    let tb = bufById(bid)
    if tb == nil or not tb.canEdit(): return
    tb.beginEdit()
    discard tb.replaceText(Pos(line: l, col: c0), Pos(line: l, col: c1), newV)
    tb.endEdit()
    needRender = true
    info("Version " & newV & " — Git: create a tag (v" & newV & ") after the commit, for nimble to find it")

proc nbVersionFixes(b: Buffer): seq[(string, string, Action)] =
  ## on a .nimble's `version = "1.2.3"`: the next patch, minor and major versions
  if b.path.len == 0 or not b.path.endsWith(".nimble"): return
  let l = b.primary.head.line
  let s = b.lines[l]
  let t = s.strip
  if not t.startsWith("version"): return
  let q1 = s.find('"')
  let q2 = if q1 >= 0: s.find('"', q1 + 1) else: -1
  if q2 <= q1: return
  let v = s[q1 + 1 ..< q2]
  var p = verParts(v)
  if p.len == 0 or not v.allCharsInSet({'0'..'9', '.'}): return
  while p.len < 3: p.add 0
  for (what, nv) in [("patch", $p[0] & "." & $p[1] & "." & $(p[2] + 1)), ("minor", $p[0] & "." & $(p[1] + 1) & ".0"),
                     ("major", $(p[0] + 1) & ".0.0")]:
    result.add act("Bump the version to " & nv, what & " (was " & v & ")", nbBumpAct(b.id, l, q1 + 1, q2, nv))

# ── the lock file ──

proc nbLockPackages(text: string): OrderedTable[string, (string, string, string)] =
  ## nimble.lock's packages: name → (version, revision, url)
  try:
    for k, v in parseJson(text){"packages"}.pairs:
      result[k] = (v{"version"}.getStr, v{"vcsRevision"}.getStr, v{"url"}.getStr)
  except CatchableError: discard

proc cmdNimbleLockChanges() =
  ## nimble.lock: what it pins, and what changed since the last commit (versions, revisions, packages in and out)
  loadNimbleInfo(true)
  let dir = if nimble.dir.len > 0: nimble.dir else: rootDir
  let lock = dir / "nimble.lock"
  if not fileExists(lock):
    info("No nimble.lock here (nimble lock makes one)")
    return
  var now: OrderedTable[string, (string, string, string)]
  try: now = nbLockPackages(readFile(lock))
  except CatchableError as e:
    error("nimble.lock: " & e.msg)
    return
  proc show(before: string, haveBefore: bool) =
    var md = "# nimble.lock\n\n"
    if haveBefore:
      let old = nbLockPackages(before)
      var lines: seq[string]
      for k, (v, r, _) in now:
        if k notin old: lines.add "- **" & k & "** " & v & " — added"
        else:
          let (ov, orr, _) = old[k]
          if ov != v: lines.add "- **" & k & "** " & ov & " → " & v & (if verCmp(v, ov) < 0: " (older)" else: "")
          elif orr != r: lines.add "- **" & k & "** " & v & " — another commit (" & orr[0 ..< min(8, orr.len)] & " → " &
                                   r[0 ..< min(8, r.len)] & ")"
      for k, (v, _, _) in old:
        if k notin now: lines.add "- **" & k & "** " & v & " — removed"
      md.add "## Since the last commit\n\n" & (if lines.len > 0: lines.join("\n") else: "No change.") & "\n\n"
    else: md.add "_(not committed yet: no earlier version to compare with)_\n\n"
    md.add "## What it pins (" & $now.len & ")\n\n| package | version | commit |\n|---|---|---|\n"
    for k, (v, r, _) in now: md.add "| " & k & " | " & v & " | " & r[0 ..< min(10, r.len)] & " |\n"
    discard openScratch("nimble.lock", md, langByName("Markdown"))
  if not haveExe("git"):
    show("", false)
    return
  let rel = relativePath(lock, dir)
  let j = startJob(jkAux, "git show HEAD:" & quoteShell("./" & rel) & " 2>/dev/null", dir, proc(jj: Job) =
    show(jj.output, jj.code == 0 and jj.output.strip.len > 0))
  if j == nil: show("", false)

# ── the configuration the compiler ends up with ──

proc nbConfigSwitches(path: string): seq[(string, string, int)] =
  ## a config file's switches: (name, value, line) — nim.cfg (`--name:value`, `name = value`, `name:value`) and
  ## NimScript (`--name:value`, switch("name", "value"))
  var text = ""
  try: text = readFile(path)
  except CatchableError: return
  let nims = path.endsWith(".nims") or path.endsWith(".nimble")
  let ls = text.splitLines
  for i, raw in ls:
    let t = raw.strip
    if t.len == 0 or t[0] == '#' or t[0] == '@': continue
    var name, value = ""
    if t.startsWith("-"):
      var s = t.strip(trailing = false, chars = {'-'})
      let c = s.find({':', '='})
      if c > 0:
        name = s[0 ..< c]
        value = s[c + 1 .. ^1].strip(chars = {'"', ' '})
      else: name = s.split(' ')[0]
    elif nims:
      let k = t.find("switch(")
      if k >= 0:
        let parts = t[k + 7 .. ^1].split('"')
        if parts.len >= 2:
          name = parts[1]
          if parts.len >= 4: value = parts[3]
    else:
      let c = t.find({':', '='})
      if c > 0 and not t.startsWith("["):
        name = t[0 ..< c].strip
        value = t[c + 1 .. ^1].strip(chars = {'"', ' '})
    if '#' in value: value = value[0 ..< value.find('#')].strip(chars = {'"', ' '})
    name = name.strip
    if name.len > 0 and name.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '.', '[', ']'}):
      result.add (name, value, i)

func nbSwitchGroup(name: string): string =
  ## switches that set the same thing: --gc and --mm, -d and --define …
  case name.toLowerAscii
  of "gc", "mm": "mm"
  of "d", "define": "define"
  of "u", "undef": "undef"
  of "p", "path": "path"
  of "o", "out": "out"
  of "b", "backend": "backend"
  of "f", "forcebuild": "forceBuild"
  of "x", "checks": "checks"
  of "a", "assertions": "assertions"
  else: name

proc cmdNimConfig() =
  ## nim dump for the project's main module: the config files read (in order), where they disagree, the defines,
  ## the search paths, where the output goes
  let b = buf()
  var main = ""
  if b.path.endsWith(".nim"): main = nimProjectFile(b)
  if main.len == 0: main = nimMainModule(if nimble.dir.len > 0: nimble.dir else: rootDir)
  if main.len == 0 and b.path.endsWith(".nim"): main = b.path
  if main.len == 0:
    info("Open a Nim file of the project first")
    return
  if not haveExe("nim"):
    error("nim is not on PATH")
    return
  if not codeTrusted(parentDir(main)):
    warn("The folder is not trusted: nim dump would run its config.nims (Workspace: trust this folder)")
    return
  info("nim dump " & extractFilename(main) & "…")
  let errf = privTmp("dump") & ".err"
  let cmd = "nim dump --dump.format:json --hint:Conf:on " & quoteShell(main) & " 2>" & quoteShell(errf)
  let j = startJob(jkAux, cmd, parentDir(main), proc(jj: Job) =
    var hints = ""
    try:
      hints = readFile(errf)
      removeFile(errf)
    except CatchableError: discard
    var dj: JsonNode = nil
    let o = jj.output
    let k = o.find('{')
    if k >= 0:
      try: dj = parseJson(o[k .. ^1])
      except CatchableError: dj = nil
    if dj == nil:
      error("nim dump failed: " & (hints & o).strip.splitLines()[^1])
      return
    var files: seq[string]
    for l in hints.splitLines:
      let a = l.find("used config file '")
      if a >= 0:
        let e = l.find('\'', a + 18)
        if e > a: files.add l[a + 18 ..< e]
    let prefix = dj{"prefixdir"}.getStr
    var md = "# Configuration of " & extractFilename(main) & "\n\n"
    md.add "Nim " & dj{"version"}.getStr & " (" & dj{"nimExe"}.getStr & ")\n\n## Config files, in the order read\n\n"
    for i, f in files:
      md.add $(i + 1) & ". " & tildePath(f) & (if prefix.len > 0 and f.startsWith(prefix): " _(Nim's own)_" else: "") & "\n"
    if files.len == 0: md.add "_none_\n"
    # (where they disagree: the same switch set to different values — the last one read wins)
    var seen: OrderedTable[string, seq[(string, string, int)]]
    for f in files:
      if prefix.len > 0 and f.startsWith(prefix): continue
      for (n, v, ln) in nbConfigSwitches(f):
        let g = nbSwitchGroup(n)
        if g in ["define", "undef", "path", "hint", "warning", "passC", "passL", "import", "include"] or '[' in n:
          continue
        seen.mgetOrPut(g, @[]).add (f, (if n.toLowerAscii == "gc": "gc:" & v else: v), ln)
    var conflicts: seq[string]
    for g, uses in seen:
      var vals: seq[string]
      for (_, v, _) in uses:
        if v notin vals: vals.add v
      if vals.len > 1:
        var parts: seq[string]
        for (f, v, ln) in uses: parts.add "`" & v & "` in " & extractFilename(f) & ":" & $(ln + 1)
        conflicts.add "- **--" & g & "**: " & parts.join(", ") & " — the last read wins: `" & uses[^1][1] & "`"
    md.add "\n## Where they disagree\n\n" & (if conflicts.len > 0: conflicts.join("\n") else: "Nowhere.") & "\n"
    var defs: seq[string]
    for d in jitems(dj{"defined_symbols"}):
      let s = d.getStr
      if not s.startsWith("nim") and s notin ["c", "gcc", "clang", "posix", "unix", "linux", "amd64", "x86_64",
                                               "cpu64", "arm64", "aarch64", "android", "macosx", "windows", "bsd",
                                               "freebsd", "openbsd", "netbsd", "cpp", "js", "vcc", "tcc", "icc",
                                               "nintendoswitch", "lwip", "emscripten", "termux"]:
        defs.add s
    md.add "\n## Defined symbols (besides Nim's own and the platform's)\n\n" &
           (if defs.len > 0: "`" & defs.join("` `") & "`" else: "_none_") & "\n"
    var paths: seq[string]
    for p in jitems(dj{"lib_paths"}):
      let s = p.getStr
      if not (dj{"libpath"}.getStr.len > 0 and s.startsWith(dj{"libpath"}.getStr)): paths.add tildePath(s)
    md.add "\n## Search paths (besides the standard library)\n\n" &
           (if paths.len > 0: "- " & paths.join("\n- ") else: "_none_") & "\n"
    md.add "\n## Output\n\n- out: " & (if dj{"out"}.getStr.len > 0: dj{"out"}.getStr else: "_the module's name_") &
           "\n- outdir: " & tildePath(dj{"outdir"}.getStr) & "\n- nimcache: " & tildePath(dj{"nimcache"}.getStr) & "\n"
    discard openScratch("Nim configuration", md, langByName("Markdown")))
  if j == nil: error("Could not run nim dump")
