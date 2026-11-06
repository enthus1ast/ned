# ════════════════════════════════════════════════════════════════════════════
#  Telescope: one finder for everything (as Neovim's telescope.nvim) — Alt+Shift+F, or *Telescope…* in the
#  palette: a list of finders — files, live grep, symbols, commands, settings, keys, problems, git, Nim's library,
#  nimble packages, TODOs, the terminal's commands, themes, plugins … — each the same picker with the same preview
#  beside it: the file at the line, a commit, a setting's description. Enter acts; Esc goes back.
# ════════════════════════════════════════════════════════════════════════════

type TsEntry = object
  label, detail, search: string
  act: Action
  pv: TsPreview

var
  tsLast: proc() {.closure.} = nil       # the finder last opened (Telescope: resume)
  tsLastTitle = ""

# a preview that shows a file, at the line when one is given
proc tsFile(path: string, line = -1): TsPreview = TsPreview(path: path, line: line)
# a preview that shows the given text, coloured as the named language
proc tsText(text: string, lang = ""): TsPreview = TsPreview(text: text, lang: lang)
# a preview made of a command's output (a git diff by default), run the first time it is shown
proc tsCmd(cmd: string, lang = "Diff"): TsPreview = TsPreview(cmd: cmd, lang: lang)

proc tsOpen(title: string, entries: seq[TsEntry], again: proc() {.closure.} = nil) =
  ## a finder: the picker, each entry's preview beside it
  var items: seq[(string, string, Action)]
  var search: seq[string]
  for e in entries:
    items.add (e.label, e.detail, e.act)
    search.add e.search
  openActions(title, items, search)
  tsActive = true
  tsPreviews.setLen(0)
  for e in entries: tsPreviews.add e.pv
  if again != nil:
    tsLast = again
    tsLastTitle = title
    tsCurIsLast = true
    tsLastQuery = ""

proc tsGoTo(path: string, line, col: int): Action =
  ## the action that records a jump, opens the file and centres the window on the line and column (when a line is given)
  (proc() =
    pushJump()
    let b = openFile(path)
    if b != nil and line >= 0: b.centerOn(b.clampPos(Pos(line: line, col: max(0, col)))))

proc tsPreviewText(idx: int): Buffer =
  ## a text preview as a buffer to draw (made once; a command's output asked the first time it is shown)
  if idx < 0 or idx >= tsPreviews.len: return nil
  if idx in tsTextBufs: return tsTextBufs[idx]
  let p = tsPreviews[idx]
  if p.cmd.len > 0 and not p.asked:
    tsPreviews[idx].asked = true
    let root = if gitHome().len > 0: gitHome() else: rootDir
    let i = idx
    let gen = tsGen
    discard startJob(jkGit, p.cmd, root, proc(j: Job) =
      if gen != tsGen or i >= tsPreviews.len: return       # (another finder since)
      var t = stripAnsi(j.output)
      if t.len > 200_000: t = t[0 ..< 200_000]
      tsPreviews[i].text = (if t.strip.len == 0: "(nothing)" else: t)
      tsTextBufs.del i
      needRender = true)
  let text = if tsPreviews[idx].text.len > 0: tsPreviews[idx].text
             elif p.cmd.len > 0: "…"
             else: ""
  if text.len == 0: return nil
  let b = newBuffer()
  dec nextBufId                        # (not an editor buffer)
  b.id = -500 - idx
  b.lines = text.replace("\r\n", "\n").split('\n')
  if b.lines.len > 1 and b.lines[^1].len == 0: b.lines.setLen(b.lines.len - 1)
  b.lang = if p.lang.len > 0 and langByName(p.lang) != nil: langByName(p.lang) else: langByName("Text")
  b.hlStart = @[0'u32]
  b.hlValid = 0
  if p.cmd.len == 0 or tsPreviews[idx].text.len > 0: tsTextBufs[idx] = b
  b

# ── the finders ──

proc tsRecent() =
  ## the Recent files finder: the recently opened files that still exist, each previewed
  var es: seq[TsEntry]
  for p in recentFiles:
    if fileExists(p): es.add TsEntry(label: relPath(p), act: tsGoTo(p, -1, 0), pv: tsFile(p))
  tsOpen("Recent files", es, tsRecent)

proc tsWordAtCursor(): string =
  ## the text selected on one line, else the word under the primary cursor; empty when there is none
  let b = buf()
  let (a, e) = b.primary.range
  if a != e and a.line == e.line: return b.getText(a, e)
  let p = b.primary.head
  if p.line >= b.lines.len: return ""
  let s = b.lines[p.line]
  var x = min(p.col, s.len)
  var y = x
  while x > 0 and isWordByte(s[x - 1]): dec x
  while y < s.len and isWordByte(s[y]): inc y
  s[x ..< y]

proc tsGrep(q: string) =
  ## (live grep) the project's lines that have q: ripgrep, else git grep, else grep
  tsLiveQ = q
  if q.len < 2:
    pickItems.setLen(0)
    pickActions.setLen(0)
    tsPreviews.setLen(0)
    tsTextBufs.clear()
    refilterPicker()
    return
  let cs = q != q.toLowerAscii
  let cmd =
    if cfgUseRg and findExe("rg").len > 0:
      "rg --vimgrep --no-heading --color=never --max-columns=300 --max-count=40 --fixed-strings " &
        (if cs: "--case-sensitive" else: "--ignore-case") & " -- " & quoteShell(q) & " . 2>/dev/null | head -n 1500"
    elif gitHome().len > 0 and gitHome() == rootDir:
      "git grep -n --column -I -F " & (if cs: "" else: "-i ") & "-e " & quoteShell(q) & " 2>/dev/null | head -n 1500"
    else:
      var ex = ""
      for d in cfgExclude: ex.add "--exclude-dir=" & quoteShell(d) & " "
      "grep -rnIF --color=never " & ex & (if cs: "" else: "-i ") & "-e " & quoteShell(q) & " . 2>/dev/null | head -n 1500"
  let gen = tsGen
  if tsJob != nil and not tsJob.done: killProc(tsJob.pr)
  tsJob = startJob(jkAux, cmd, rootDir, proc(j: Job) =      # (jkAux: its lines are its own, not the Search panel's)
    if gen != tsGen or pickKind != pickAction or not tsActive or tsLiveQ != q: return
    var items: seq[PickItem]
    var acts: seq[Action]
    var pvs: seq[TsPreview]
    for l in j.output.splitLines:
      # path:line:col:text (git grep: path:line:col:text as well; grep: path:line:text)
      let a = l.find(':')
      if a <= 0: continue
      let b = l.find(':', a + 1)
      if b <= a: continue
      let ln = try: parseInt(l[a + 1 ..< b]) - 1 except ValueError: continue
      var col = 0
      var rest = l[b + 1 .. ^1]
      let c = rest.find(':')
      if c > 0 and rest[0 ..< c].allCharsInSet(Digits):
        col = (try: parseInt(rest[0 ..< c]) - 1 except ValueError: 0)
        rest = rest[c + 1 .. ^1]
      var path = l[0 ..< a]
      if path.startsWith("./"): path = path[2 .. ^1]
      let full = if path.isAbsolute: path else: rootDir / path
      items.add PickItem(label: rest.strip.truncTo(160), detail: path & ":" & $(ln + 1), idx: items.len, line: -1)
      acts.add tsGoTo(full, ln, col)
      pvs.add tsFile(full, ln)
    pickItems = items
    pickActions = acts
    tsPreviews = pvs
    tsTextBufs.clear()
    refilterPicker(keepSel = true)
    pickTitle = "Live grep — " & (if items.len >= 1500: "the first 1500 lines" else: $items.len & " lines") &
                " with “" & q & "”")

proc tsLiveGrep(initial = "") =
  ## opens the Live grep finder with no entries and no filtering: tsLive runs tsGrep on what is typed. With an initial
  ## text it is typed already and searched at once. Resume reopens it with the last query.
  tsOpen("Live grep — type at least 2 characters", @[])
  tsNoFilter = true
  tsLive = proc(q: string) = tsGrep(q)
  tsLast = proc() = tsLiveGrep(tsLastQuery)
  tsLastTitle = "Live grep"
  tsCurIsLast = true
  if initial.len > 0:
    pickQuery = initial
    pickCur = initial.len
    tsGrep(initial)

proc tsSettings() =
  ## every setting: its value, its default, what it does — Enter: the Settings panel at it
  initSettingDefs()
  var es: seq[TsEntry]
  for d in setDefs:
    let v = sval(d.key)
    let shown = if v.kind == JString: v.getStr else: $v
    let key = d.key
    var t = d.key & "\n\n" & d.doc & "\n\nNow:     " & shown & "\nDefault: " & (if d.def.kind == JString: d.def.getStr else: $d.def)
    if d.opts.len > 0: t.add "\nOne of:  " & d.opts.join(" · ")
    t.add "\nSection: " & d.cat
    es.add TsEntry(label: d.key, detail: truncTo(shown, 30), search: d.doc.toLowerAscii & " " & d.cat.toLowerAscii,
                   act: (proc() = openSettingsUi(key)), pv: tsText(t))
  tsOpen("Settings — Enter opens it in the Settings panel", es, tsSettings)

# the action that runs command number i, counting the use (which the palette's order follows)
proc tsCmdAct(i: int): Action = (proc() =
  cmdUses[commands[i].name] = cmdUses.getOrDefault(commands[i].name) + 1
  commands[i].action())

proc tsKeys() =
  ## the commands that have a key, by key
  var es: seq[TsEntry]
  for i, c in commands:
    if c.keys.len == 0: continue
    es.add TsEntry(label: c.keys & "   " & c.name, detail: "", search: c.name.toLowerAscii,
                   act: tsCmdAct(i), pv: tsText(c.name & "\n\nKey: " & c.keys & "\n\nEnter runs it. Your own keys: the " &
                                                "\"keys\" setting ({\"ctrl+alt+x\": \"" & c.name & "\"})."))
  tsOpen("Keys — Enter runs the command", es, tsKeys)

proc tsProblems() =
  ## the Problems finder: the problems of every file that have a place, marked ✗ error, ▲ warning or · hint; says so
  ## when there are none
  rebuildProblems()
  var es: seq[TsEntry]
  for pl in panelStore[pkProblems]:
    if pl.path.len == 0 or pl.line < 0: continue
    let mark = case pl.sev
      of 1: "✗ "
      of 2: "▲ "
      else: "· "
    es.add TsEntry(label: mark & pl.text.strip, detail: relPath(pl.path) & ":" & $(pl.line + 1),
                   act: tsGoTo(pl.path, pl.line, pl.col), pv: tsFile(pl.path, pl.line))
  if es.len == 0:
    info("No problems")
    return
  tsOpen("Problems", es, tsProblems)

proc tsGitStatus() =
  ## the Git: changed files finder: each line of git status (a rename by its new name), previewed with its diff against
  ## HEAD, or the file itself when it is untracked
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  var es: seq[TsEntry]
  for l in gitText("status --porcelain=v1 -uall").splitLines:
    if l.len < 4: continue
    let st = l[0 .. 1]
    var p = l[3 .. ^1]
    let arrow = p.find(" -> ")
    if arrow >= 0: p = p[arrow + 4 .. ^1]
    p = p.strip(chars = {'"'})
    let full = root / p
    let pv = if st == "??": tsFile(full) else: tsCmd("git --no-pager diff --no-color HEAD -- " & quoteShell(p))
    es.add TsEntry(label: p, detail: st.strip, act: tsGoTo(full, -1, 0), pv: pv)
  if es.len == 0:
    info("No changes — the working tree is clean")
    return
  tsOpen("Git: changed files — the diff beside each", es, tsGitStatus)

# the action that shows a commit (git show with its stat and patch) in an output tab
proc tsShowCommitAct(h, subject: string): Action = (proc() =
  let root = gitHome()
  toolOutput("commit " & h[0 ..< min(8, h.len)] & " " & subject, "git --no-pager show --no-color --stat -p " & h, root,
             proc(o: string): string = o, langByName("Diff")))

proc tsGitLog(file = "") =
  ## the Git: commits finder: the last 400 commits, each with its change beside it — only those that touched the file,
  ## following renames, when one is given
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  var es: seq[TsEntry]
  let rel = if file.len > 0: relPath(file) else: ""
  let args = "log --no-color --date=short --format=%H%x09%ad%x09%an%x09%s -n 400" &
             (if file.len > 0: " --follow -- " & quoteShell(file) else: "")
  for l in gitText(args).splitLines:
    let f = l.split('\t')
    if f.len < 4: continue
    let h = f[0]
    es.add TsEntry(label: f[3], detail: h[0 ..< 7] & " · " & f[1] & " · " & f[2], search: (h & " " & f[2]).toLowerAscii,
                   act: tsShowCommitAct(h, f[3]),
                   pv: tsCmd("git --no-pager show --no-color --stat -p " & h &
                             (if file.len > 0: " -- " & quoteShell(file) else: "")))
  if es.len == 0:
    info("No commits")
    return
  if file.len > 0: tsOpen("Git: commits of " & rel, es, proc() = tsGitLog(file))
  else: tsOpen("Git: commits — the change beside each", es, proc() = tsGitLog())

# the action that checks out the branch
proc tsCheckoutAct(br: string): Action = (proc() = gitRun(@["checkout", br], "On " & br))

proc tsGitBranches() =
  ## the Git: branches finder: local and remote branches (the current one marked ●) with the date and subject of the
  ## last commit and a log graph beside; Enter checks one out
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  var es: seq[TsEntry]
  for l in gitText("branch -a --no-color --format=%(HEAD)%09%(refname:short)%09%(committerdate:short)%09%(subject)").splitLines:
    let f = l.split('\t')
    if f.len < 4 or f[1].endsWith("/HEAD"): continue
    es.add TsEntry(label: (if f[0] == "*": "● " else: "  ") & f[1], detail: f[2] & " · " & f[3],
                   act: tsCheckoutAct(f[1]),
                   pv: tsCmd("git --no-pager log --no-color --oneline --graph -n 40 " & quoteShell(f[1]), "Text"))
  tsOpen("Git: branches — Enter checks one out", es, tsGitBranches)

# the action that applies the stash (a name like stash@{0}) — it stays in the list
proc tsStashAct(n: string): Action = (proc() = gitRun(@["stash", "apply", n], "Applied " & n))

proc tsGitStash() =
  ## the Git: stashes finder: each stash with its patch beside it; Enter applies one
  if gitHome().len == 0:
    info("Not a git repository")
    return
  var es: seq[TsEntry]
  for l in gitText("stash list --no-color").splitLines:
    let c = l.find(':')
    if c <= 0: continue
    let n = l[0 ..< c]
    es.add TsEntry(label: l[c + 1 .. ^1].strip, detail: n, act: tsStashAct(n),
                   pv: tsCmd("git --no-pager stash show --no-color -p " & quoteShell(n)))
  if es.len == 0:
    info("No stashes")
    return
  tsOpen("Git: stashes — Enter applies one", es, tsGitStash)

var tsNimModules: Table[string, string]       # a standard library module → its file

proc tsNimLib(): Table[string, string] =
  ## the modules of Nim's standard library (name → file), read once from the library folder and its usual subfolders;
  ## modules under std/ are named with that prefix. Empty when Nim's library is not found.
  if tsNimModules.len > 0: return tsNimModules
  let lib = nimLibDir()
  if lib.len == 0: return
  for sub in ["", "pure", "pure/collections", "pure/concurrency", "pure/unidecode", "std", "std/private", "core",
              "impure", "posix", "windows", "wrappers", "js", "deprecated/pure", "packages/docutils", "experimental"]:
    let d = if sub.len > 0: lib / sub else: lib
    try:
      for k, p in walkDir(d):
        if k in {pcFile, pcLinkToFile} and p.endsWith(".nim"):
          let name = (if sub.startsWith("std"): "std/" else: "") & splitFile(p).name
          if name notin tsNimModules: tsNimModules[name] = p
    except OSError: discard
  tsNimModules

proc tsNimModulesPick() =
  ## the finder of the standard library's modules by name, each previewed from its first line; Enter opens one
  let mods = tsNimLib()
  if mods.len == 0:
    info("Nim's library was not found (is nim on PATH?)")
    return
  var names: seq[string]
  for k in mods.keys: names.add k
  names.sort()
  var es: seq[TsEntry]
  for n in names:
    let p = mods[n]
    es.add TsEntry(label: n, detail: relPath(parentDir(p)), act: tsGoTo(p, 0, 0), pv: tsFile(p, 0))
  tsOpen("Nim: the standard library's modules — Enter opens one", es, tsNimModulesPick)

proc tsDeclLine(path, name: string): int =
  ## the line that declares `name` (exported) in a module, else -1
  try:
    var i = 0
    for l in lines(path):
      if l.len > name.len + 4 and l[0] notin {' ', '#'}:
        for kw in ["proc ", "func ", "template ", "macro ", "iterator ", "converter ", "method "]:
          if l.startsWith(kw) and l[kw.len .. ^1].startsWith(name) and l.len > kw.len + name.len and
             l[kw.len + name.len] in {'*', '['}:
            return i
      elif l.len > name.len + 2 and l.startsWith("  " & name) and l.len > name.len + 2 and l[name.len + 2] == '*':
        return i
      inc i
  except CatchableError: discard
  -1

# the action that opens the module and goes to the line that declares the exported name (the top of the file when it is
# not found)
proc tsNimNameAct(path, name: string): Action = (proc() =
  let l = tsDeclLine(path, name)
  tsGoTo(path, l, 0)())

proc tsNimNames() =
  ## every name the standard library exports, with the modules that do — Enter: its declaration
  loadNimIndex()
  let mods = tsNimLib()
  if nimIndex.len == 0 or mods.len == 0:
    info("Nim's library was not found (is nim on PATH?)")
    return
  var names: seq[string]
  for k in nimIndex.keys: names.add k
  names.sort()
  var es: seq[TsEntry]
  for n in names:
    let ms = nimIndex[n]
    if ms.len == 0: continue
    let m = ms[0]
    let p = mods.getOrDefault(m, mods.getOrDefault("std/" & m))
    if p.len == 0: continue
    es.add TsEntry(label: n, detail: ms.join(", ").truncTo(50), act: tsNimNameAct(p, n),
                   pv: TsPreview(path: p, line: -1, find: n))
  tsOpen("Nim: names of the standard library — Enter goes to one", es, tsNimNames)

proc tsNimble() =
  ## the nimble packages installed — Enter opens the package's folder in the Files tree
  var es: seq[TsEntry]
  let nd = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")
  for sub in ["pkgs2", "pkgs"]:
    try:
      for k, d in walkDir(nd / sub):
        if k notin {pcDir, pcLinkToDir}: continue
        let n = extractFilename(d)
        var nf = ""
        try:
          for k2, f in walkDir(d):
            if f.endsWith(".nimble"): nf = f
        except OSError: discard
        let dd = d
        es.add TsEntry(label: n, detail: sub, act: (proc() = discard openFile(if nf.len > 0: nf else: dd)),
                       pv: (if nf.len > 0: tsFile(nf, 0) else: tsText(d)))
    except OSError: discard
  if es.len == 0:
    info("No nimble packages installed (" & tildePath(nd) & ")")
    return
  tsOpen("Nim: nimble packages installed", es, tsNimble)

proc tsTodos() =
  ## the TODOs finder: the tagged comments found in the project (TODO, FIXME …), each with its place and the file at
  ## that line
  var es: seq[TsEntry]
  for t in todoCollect(false):
    let tag = if t.tag >= 0 and t.tag < todoTags.len: todoTags[t.tag].word else: "TODO"
    es.add TsEntry(label: tag & " " & t.text, detail: relPath(t.path) & ":" & $(t.line + 1),
                   act: tsGoTo(t.path, t.line, t.col), pv: tsFile(t.path, t.line))
  if es.len == 0:
    info("No TODOs found (yet: the project is read in the background)")
    return
  tsOpen("TODOs", es, tsTodos)

# the action that shows terminal ti in the panel and types the command into it again
proc tsRunInTermAct(ti: int, cmd: string): Action = (proc() =
  if ti >= 0 and ti < terms.len:
    curTerm = ti
    setPanel(pkTerminal)
    focus = fPanel
    terms[ti].termRunText(cmd))

proc tsTermCmds() =
  ## the commands run in the terminals (shell integration) — Enter runs one again
  var es: seq[TsEntry]
  for ti, t in terms:
    for ci in countdown(t.cmds.high, 0):
      let c = t.cmds[ci]
      if c.text.strip.len == 0: continue
      let st = if c.code > 0: "✗ " & $c.code elif c.code == 0: "✓" else: ""
      es.add TsEntry(label: c.text, detail: t.name & " " & st, act: tsRunInTermAct(ti, c.text),
                     pv: tsText(t.termCmdOutput(ci), "Text"))
  if es.len == 0:
    info("No commands seen in the terminals yet (bash, zsh, fish with terminal.shellIntegration)")
    return
  tsOpen("Terminal: commands run — Enter runs one again", es, tsTermCmds)

proc tsPlugins() =
  ## ned's own plugins and yours — Enter turns one on (or shows it in the Plugins dock)
  plugDiscover()
  var es: seq[TsEntry]
  var have: HashSet[string]
  for p in plugs:
    have.incl p.id
    es.add TsEntry(label: p.id, detail: (if p.enabled: "on" else: "off") & (if p.version.len > 0: " · " & p.version else: "") &
                   (if p.bundled: " · ned's" else: ""), act: (proc() = cmdPlugins()), pv: tsFile(p.file, 0))
  for (n, what, src) in PlugBundled:
    if n in have: continue
    es.add TsEntry(label: n, detail: "available · " & what, search: what.toLowerAscii, act: plugBundledAct(n, true),
                   pv: tsText(src, "Nim"))
  tsOpen("Plugins — Enter turns one of ned's on", es, tsPlugins)

proc tsBookmarks() =
  ## the Bookmarks finder: the marked lines of the open files, and those saved for files not open now
  var es: seq[TsEntry]
  for b in bufs:
    if b.path.len == 0: continue
    for l in b.marks:
      if l < b.lines.len:
        es.add TsEntry(label: b.lines[l].strip.truncTo(100), detail: relPath(b.path) & ":" & $(l + 1),
                       act: tsGoTo(b.path, l, 0), pv: tsFile(b.path, l))
  for p, ls in savedMarks:
    if bufIndexByPath(p) >= 0 or not fileExists(p): continue
    for l in ls:
      es.add TsEntry(label: relPath(p) & ":" & $(l + 1), detail: "", act: tsGoTo(p, l, 0), pv: tsFile(p, l))
  if es.len == 0:
    info("No bookmarks (Alt+' marks a line)")
    return
  tsOpen("Bookmarks", es, tsBookmarks)

# ── what a finder of places can do besides Enter: a pane beside, a multibuffer of them all ──

proc pickTargetAt(k: int): (string, int) =
  ## the file and the line (-1: the file) of the k-th item shown — ("", -1) when it is no place in a file
  if k < 0 or k >= pickShown.len: return ("", -1)
  let keep = pickSel
  pickSel = k
  let (p, l, _) = pickPreviewTarget()
  pickSel = keep
  (p, l)

proc pickOpenBeside(down: bool) =
  ## Alt+V (Alt+X) in a finder: what is chosen, in a new pane at the right (below)
  let (path, line) = pickTargetAt(pickSel)
  if path.len == 0:
    info("Not a place in a file — Enter does what it says")
    return
  closePicker()
  if not buf().isWelcome():
    if splitOn: discard splitPaneOf(activePane, down) else: splitEditor(down)
  pushJump()
  let b = openFile(path)
  if b != nil and line >= 0: b.centerOn(b.clampPos(Pos(line: line, col: 0)))

proc pickToMultibuffer() =
  ## Alt+Q in a finder: every place it lists (as filtered) in one multibuffer — a line around each, or the files
  ## (their first 300 lines) — to read and edit together (as telescope.nvim sends them to the quickfix list)
  var hits: seq[(string, int)]
  var files: seq[string]
  for k in 0 ..< min(pickShown.len, 2000):
    let (p, l) = pickTargetAt(k)
    if p.len == 0 or not fileExists(p): continue
    if l >= 0: hits.add (p, l)
    elif p notin files: files.add p
  if hits.len == 0 and files.len == 0:
    info("Nothing listed is a place in a file")
    return
  let title = pickTitle.split(" — ")[0]
  closePicker()
  if hits.len > 0: openMultibuffer(title, hits)
  else:
    var rs: seq[tuple[path: string, first, last: int, note: string]]
    for f in files[0 ..< min(files.len, 200)]: rs.add (f, 0, 299, "")
    discard openMultibufferOf(title, rs)

# ── more finders (6.31): the lines of this file, the panes, the places you jumped from ──

proc tsLines() =
  ## the file's lines: type to find one (fuzzy), the place beside
  let b = buf()
  if b.path.len == 0 and b.title.len == 0:
    info("Open a file first")
    return
  var es: seq[TsEntry]
  for i, l in b.lines:
    if i >= 20_000: break
    let t = l.strip
    if t.len == 0: continue
    es.add TsEntry(label: truncTo(t, 200), detail: $(i + 1), search: t.toLowerAscii,
                   act: tsGoTo(b.path, i, l.len - l.strip(trailing = false).len),
                   pv: (if b.path.len > 0: tsFile(b.path, i) else: tsText("")))
  tsOpen("Lines of " & b.name & " — Enter goes there", es, tsLines)

# the action that gives pane i the focus
proc tsPaneAct(i: int): Action = (proc() = (if splitOn: focusPane(i)))

proc tsPanes() =
  ## the panes: Enter gives one the focus
  var es: seq[TsEntry]
  if not splitOn:
    info("One pane only — Alt+\\ splits the editor")
    return
  for i in paneOrder():
    let pb = if i == activePane: buf() else: bufById(panes[i].bufId)
    if pb == nil: continue
    let top = if i == activePane: pb.primary.head.line else: panes[i].snap.topLine
    es.add TsEntry(label: (if i == activePane: "● " else: "  ") & pb.name, detail: relPath(parentDir(pb.path)),
                   act: tsPaneAct(i), pv: (if pb.path.len > 0: tsFile(pb.path, top) else: tsText(pb.title)))
  tsOpen("Panes — Enter goes to one", es, tsPanes)

proc tsJumps() =
  ## the places you jumped from (F12, a search, Ctrl+O's list), the latest first
  var es: seq[TsEntry]
  for k in countdown(jumpStack.high, 0):
    let (path, p) = jumpStack[k]
    if path.len == 0 or not fileExists(path): continue
    var t = ""
    let bi = bufIndexByPath(path)
    if bi >= 0 and p.line < bufs[bi].lines.len: t = bufs[bi].lines[p.line].strip
    es.add TsEntry(label: relPath(path) & ":" & $(p.line + 1), detail: truncTo(t, 60), search: t.toLowerAscii,
                   act: tsGoTo(path, p.line, p.col), pv: tsFile(path, p.line))
  if es.len == 0:
    info("No jumps yet — F12, a search or a reference leaves one")
    return
  tsOpen("Jumps — the places you jumped from", es, tsJumps)

proc tsResume() =
  ## the last finder again, with what you had typed in it
  if tsLast == nil:
    telescope()
    return
  let q = tsLastQuery
  tsLast()
  if not tsNoFilter and q.len > 0:
    pickQuery = q
    pickCur = q.len
    refilterPicker()

proc telescope() =
  ## the finders
  var es: seq[TsEntry]
  proc add(label, detail: string, act: Action, help: string) =
    ## adds a finder to the list, its help text as the preview beside it
    es.add TsEntry(label: label, detail: detail, act: act, pv: tsText(label & "\n\n" & help))
  add("Files", "Ctrl+P", proc() = cmdFindFile(), "The project's files, the open and recent ones first. :line, @symbol, " &
      "#project symbol and >command work in it too.\n\nIn every finder of places — files, lines, symbols, problems: " &
      "Alt+V opens the one chosen in a pane at the right, Alt+X in a pane below, Alt+Q puts them all in a multibuffer.")
  add("Live grep", "", proc() = tsLiveGrep(), "Every line of the project with what you type, found as you type " &
      "(ripgrep, git grep or grep), the file at the line beside it.")
  add("Grep the word under the cursor", "", proc() = tsLiveGrep(tsWordAtCursor()), "Live grep, with the word under " &
      "the cursor (or the selection) already typed.")
  add("Open tabs", "", proc() = cmdBuffers(), "The files open in tabs.")
  add("Recent files", "", proc() = tsRecent(), "The files you opened lately, in this folder and elsewhere.")
  add("Symbols in this file", "Ctrl+T", proc() = cmdSymbols(), "The routines, types and constants of the file in front.")
  add("Lines of this file", "", proc() = tsLines(), "Every line of the file in front — type a few letters of one " &
      "(fuzzy), the place beside it; Enter goes there.")
  add("Symbols in the project", "", proc() = cmdProjectSymbols(), "Every declaration of the project: Nim's from ned's " &
      "engine, the other languages' as ned reads them.")
  add("Commands", "Alt+X", proc() = cmdPalette(), "Every command of ned and of your plugins.")
  add("Settings", "", proc() = tsSettings(), "Every setting with what it does, its value and its default; Enter " &
      "opens it in the Settings panel.")
  add("Keys", "", proc() = tsKeys(), "The commands that have a key, by key.")
  add("Problems", "", proc() = tsProblems(), "Errors, warnings and hints of every file.")
  add("Git: changed files", "", proc() = tsGitStatus(), "What git status lists, with each file's diff beside it.")
  add("Git: commits", "", proc() = tsGitLog(), "The repository's commits, the change of each beside it.")
  add("Git: commits of this file", "", proc() = (if buf().path.len > 0: tsGitLog(buf().path) else: info("Not a file")),
      "The commits that changed the file in front, following renames.")
  add("Git: branches", "", proc() = tsGitBranches(), "Local and remote branches; Enter checks one out.")
  add("Git: stashes", "", proc() = tsGitStash(), "The stashes with their changes; Enter applies one.")
  add("Nim: the standard library's modules", "", proc() = tsNimModulesPick(), "Every module of Nim's standard library.")
  add("Nim: names of the standard library", "", proc() = tsNimNames(), "Every exported proc, type and constant of " &
      "Nim's standard library, with its module; Enter goes to its declaration.")
  add("Nim: nimble packages installed", "", proc() = tsNimble(), "The packages in ~/.nimble.")
  add("TODOs", "", proc() = tsTodos(), "The TODO, FIXME, BUG, HACK and NOTE comments of the project.")
  add("Bookmarks", "", proc() = tsBookmarks(), "The lines you marked (Alt+').")
  add("Jumps", "", proc() = tsJumps(), "The places you jumped from — with F12, a search, a reference — the latest " &
      "first.")
  add("Panes", "", proc() = tsPanes(), "The panes of the editor with their files; Enter gives one the focus.")
  add("Terminal: commands run", "", proc() = tsTermCmds(), "What you ran in ned's terminals, with its output; Enter " &
      "runs it again.")
  add("Themes", "Alt+T", proc() = cmdThemes(), "The colour themes, previewed as you move.")
  add("Languages", "", proc() = cmdLanguages(), "The language the file in front is coloured and checked as.")
  add("Plugins", "", proc() = tsPlugins(), "ned's own plugins and yours.")
  add("Recent projects", "", proc() = cmdRecentProjects(), "The folders you worked in.")
  if tsLast != nil:
    add("Resume: " & tsLastTitle, "", proc() = tsResume(), "The last finder, with what you had typed.")
  tsOpen("Telescope — what to find?", es)

proc tsLivePump() =
  ## (main loop) a live finder's query, a moment after the typing stops
  if tsLive == nil or pickKind != pickAction or not tsActive: return
  if pickQuery != tsLiveQ and getMonoTime() >= tsLiveDue: tsLive(pickQuery)
