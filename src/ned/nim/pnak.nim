# ── pnak, Nim 3's package tool: its pnak.nif lockfile (every package at its commit) read — the outline, hover, F12
#    to the package's checkout, its problems — and pnak fetch / pnak pin run for the project ──

# whether the path is a pnak lockfile
func pnakFile(path: string): bool = extractFilename(path) == "pnak.nif"

proc pnakExe(): string =
  ## pnak on PATH, else the one beside the nimony in use
  result = findExe("pnak")
  if result.len == 0 and nimonyExe().len > 0:
    let near = parentDir(nimonyExe()) / "pnak".addFileExt(ExeExt)
    if fileExists(near): result = near

proc pnakCheckout(dir, name: string): (bool, string, string) =
  ## the package's checkout in the project's deps/ folder: (is it there, its commit, where it is) — a link file
  ## (deps/name holding a path) points to where it lives
  var at = dir / "deps" / name
  if fileExists(at):
    try:
      for l in readFile(at).splitLines:
        if l.strip.len > 0:
          let p = l.strip
          at = if p.isAbsolute: p else: normalizedPath(dir / "deps" / p)
          break
    except CatchableError: return (false, "", "")
  if not dirExists(at): return (false, "", at)
  var head = ""
  try:
    head = readFile(at / ".git" / "HEAD").strip
    if head.startsWith("ref: "):
      let r = head[5 .. ^1]
      head = ""
      if fileExists(at / ".git" / r): head = readFile(at / ".git" / r).strip
      elif fileExists(at / ".git" / "packed-refs"):
        for l in readFile(at / ".git" / "packed-refs").splitLines:
          if l.endsWith(" " & r): head = l.split(' ')[0]
  except CatchableError: discard
  (true, head, at)

func pnakSameCommit(a, b: string): bool =
  ## whether two commit ids are the same commit, one possibly being the short form of the other (case ignored)
  let x = a.toLowerAscii
  let y = b.toLowerAscii
  x.len > 0 and y.len > 0 and (x.startsWith(y) or y.startsWith(x))

proc pnakDiags(b: Buffer): seq[Diag] =
  ## a pnak.nif's problems: a package with no commit or with a branch's name (not pinned), one listed twice, one
  ## not fetched, one checked out at another commit
  if b == nil or not pnakFile(b.path): return
  let dir = parentDir(b.path)
  let fetched = dirExists(dir / "deps")
  var seen: Table[string, int]
  template add(l, c, e, sv: int, rl, m: string) =
    ## adds a problem on line l between columns c and e, with severity sv, rule rl and message m
    result.add Diag(line: l, col: c, eline: l, ecol: e, sev: sv, src: "ned", rule: rl, msg: m)
  for r in pnakRequires(b.lines):
    let key = r.name.toLowerAscii
    if key in seen:
      add(r.line, r.col, r.ecol, 2, "pnak", "'" & r.name & "' is in the lockfile twice (line " & $(seen[key] + 1) &
          " too)")
    else: seen[key] = r.line
    if r.commit.len == 0:
      add(r.line, r.col, r.ecol, 3, "pnak", "no commit: pnak takes the newest — pnak pin writes the commit it uses")
      continue
    if not pnakIsCommit(r.commit):
      add(r.cline, r.ccol, r.cecol, 3, "pnak", "'" & r.commit & "' is a branch or a tag, which can move — a " &
          "lockfile pins a commit (pnak pin)")
    if fetched:
      let (there, head, _) = pnakCheckout(dir, r.name)
      if not there:
        add(r.line, r.col, r.ecol, 4, "pnak", r.name & " is not in deps/ yet — Nim 3: pnak fetch")
      elif head.len > 0 and pnakIsCommit(r.commit) and not pnakSameCommit(head, r.commit):
        add(r.cline, r.ccol, r.cecol, 3, "pnak", "deps/" & r.name & " is at " & head[0 ..< min(10, head.len)] &
            ", not this commit — Nim 3: pnak fetch checks it out")

proc pnakAt(b: Buffer, p: Pos): int =
  ## the entry at p (on its lines), -1 none
  let rs = pnakRequires(b.lines)
  for i, r in rs:
    let last = max(r.line, r.cline)
    if p.line >= r.tline and p.line <= last: return i
  -1

proc pnakHover(b: Buffer, p: Pos): string =
  ## the hover for an entry of a pnak.nif: its package, URL, commit (flagging a branch or tag) and where it is checked
  ## out in deps/; on the file's first line, what a pnak.nif is
  if b == nil or not pnakFile(b.path): return ""
  let rs = pnakRequires(b.lines)
  let i = pnakAt(b, p)
  if i < 0:
    if p.line == 0 or (b.lines.len > 0 and b.lines[p.line].contains("stmts")):
      return "**pnak.nif** — the project's lockfile for pnak, Nim 3's package tool: every package, the ones it " &
             "needs and theirs, at the commit to use (pnak pin writes it; pnak fetch checks them out in deps/)"
    return ""
  let r = rs[i]
  result = "**" & r.name & "**  `" & r.url & "`\n\n"
  if r.commit.len == 0: result.add "no commit: the newest\n\n"
  else: result.add "at `" & r.commit & "`" & (if pnakIsCommit(r.commit): "" else: " (a branch or a tag)") & "\n\n"
  let (there, head, at) = pnakCheckout(parentDir(b.path), r.name)
  if there:
    result.add "in " & tildePath(at) & (if head.len > 0: ", at `" & head[0 ..< min(12, head.len)] & "`" else: "") &
               " — F12 opens its .nimble"
  else: result.add "not checked out in deps/ — Nim 3: pnak fetch"

proc pnakDefinition(b: Buffer, p: Pos): bool =
  ## F12 on an entry: the package's .nimble in its checkout (its folder when it has none)
  if b == nil or not pnakFile(b.path): return false
  let i = pnakAt(b, p)
  if i < 0: return false
  let r = pnakRequires(b.lines)[i]
  let (there, _, at) = pnakCheckout(parentDir(b.path), r.name)
  if not there:
    info(r.name & " is not checked out in deps/ — Nim 3: pnak fetch")
    return true
  var target = ""
  try:
    for kind, f in walkDir(at):
      if kind == pcFile and f.endsWith(".nimble"):
        target = f
        break
  except CatchableError: discard
  pushJump()
  if target.len > 0: discard openFile(target)
  else: info(tildePath(at))
  true

proc pnakOutlineOf(b: Buffer): seq[SideItem] =
  ## the outline of a pnak.nif: one row per package with its commit (or "newest")
  for r in pnakRequires(b.lines):
    result.add SideItem(text: r.name, detail: (if r.commit.len > 0: r.commit[0 ..< min(10, r.commit.len)] else: "newest"),
                        path: b.path, line: r.line, col: r.col, icon: "▣", role: 8)

proc pnakUnpinned(nimblePath: string, lines: seq[string]): seq[Diag] =
  ## the .nimble's requires a pnak.nif beside it does not list (Nim 3 projects that lock with pnak)
  let lock = parentDir(nimblePath) / "pnak.nif"
  if not fileExists(lock): return
  var names: HashSet[string]
  try:
    for r in pnakRequires(readFile(lock).splitLines): names.incl pcNorm(r.name)
  except CatchableError: return
  for r in pcRequires(lines):
    if r.name.len == 0 or r.name == "nim" or r.feature.len > 0: continue
    let n = if "://" in r.name or r.name.startsWith("git@"): pnakName(r.name) else: r.name.split('#')[0]
    if pcNorm(n) notin names:
      result.add Diag(line: r.line, col: r.col, eline: r.line, ecol: r.ecol, sev: 3, src: "ned", rule: "pnak",
                      msg: "'" & n & "' is not in pnak.nif — Nim 3: pnak pin writes the lockfile again")

proc cmdPnak(sub: string) =
  ## pnak fetch (the packages checked out in deps/, nimony.paths written) or pnak pin (pnak.nif written), in the
  ## project's folder, in the Output panel
  let exe = pnakExe()
  if exe.len == 0:
    error("pnak is not installed — it comes with Nimony: hastur build pnak (https://github.com/nim-lang/nimony)")
    return
  let b = buf()
  var dir = if nimble.dir.len > 0: nimble.dir else: rootDir
  if b != nil and b.path.len > 0 and (b.path.endsWith(".nimble") or pnakFile(b.path)): dir = parentDir(b.path)
  var any = fileExists(dir / "pnak.nif")
  if not any:
    try:
      for kind, f in walkDir(dir):
        if kind == pcFile and f.endsWith(".nimble"):
          any = true
          break
    except CatchableError: discard
  if not any:
    info("No .nimble or pnak.nif in " & tildePath(dir) & " — pnak reads the project's requires from them")
    return
  runCommand(quoteShell(exe) & " " & sub, dir)
