# ════════════════════════════════════════════════════════════════════════════
#  Docks: left (files · search · git · nim · tests) and right (assistant · outline · timeline)
# ════════════════════════════════════════════════════════════════════════════

const
  LeftViews = [svFiles, svSearch, svGit, svProject, svTests]
  RightViews = [svAssistant, svOutline, svTodos, svTimeline]

proc viewIcon(v: SideView): string =
  case v
  of svFiles: ic("files")
  of svSearch: ic("search")
  of svGit: ic("git")
  of svProject: ic("nim")
  of svTests: ic("tests")
  of svAssistant: ic("ai")
  of svOutline: ic("outline")
  of svTimeline: ic("timeline")
  of svTodos: ic("todo")

proc viewTitle(v: SideView): string =
  case v
  of svFiles: "EXPLORER"
  of svSearch: "SEARCH"
  of svGit: "SOURCE CONTROL"
  of svProject: "NIM"
  of svTests: "TESTS"
  of svAssistant: "ASSISTANT"
  of svOutline: "OUTLINE"
  of svTimeline: "TIMELINE"
  of svTodos: "TODOS"

proc sideItem(text: string, role = 0, icon = "", detail = "", action: Action = nil, path = "", line = -1,
              depth = 0, data = ""): SideItem =
  SideItem(text: text, role: role, icon: icon, detail: detail, action: action, path: path, line: line,
           depth: depth, data: data)

proc roleColor(role: int): Rgb =
  case role
  of 1: theme.accent
  of 2: theme.dim
  of 3: theme.err
  of 4: theme.warn
  of 5: theme.gitAdd
  of 6: theme.dim
  of 7: theme.syn[tkFunc]
  of 8: theme.syn[tkType]
  of 9: theme.syn[tkKeyword]
  else: theme.fg

proc toolLine(name, hint: string, install: Action = nil): SideItem =
  if haveExe(name):
    let v = toolVersions.getOrDefault(name)
    sideItem(name & (if v.len > 0: " " & v else: ""), 5, ic("ok"))
  else:
    sideItem(name, 2, "✗", hint, install)

proc buildProjectItems(): seq[SideItem] =
  loadNimbleInfo()
  let b = buf()
  let isNim = b.lang.mode == lmNim
  result.add sideItem("PROJECT", 6)
  if nimble.file.len > 0:
    result.add sideItem(nimble.name & (if nimble.version.len > 0: "  v" & nimble.version else: ""), 1, "◆",
                        action = proc() = discard openFile(nimble.file))
    if nimble.desc.len > 0: result.add sideItem(nimble.desc, 2, depth = 1)
  else:
    result.add sideItem(extractFilename(rootDir), 1, "◆")
    result.add sideItem("no .nimble file — create a project:", 2, depth = 1)
  result.add sideItem("New Nim project…", 0, "+", action = proc() = openPrompt(pNewProject, "New Nim project name", ""))
  result.add sideItem("CODE INTELLIGENCE", 6)
  if nimUsesLsp():
    var nsN = -1
    var nsProjects: seq[string]
    if nlsStatus != nil and nlsStatus{"nimsuggestInstances"} != nil:
      nsN = nlsStatus["nimsuggestInstances"].len
      for it in jitems(nlsStatus["nimsuggestInstances"]): nsProjects.add it{"projectFile"}.getStr
    let st = (if nsN < 0: "" elif nsN == 1: "1 nimsuggest" else: $nsN & " nimsuggest")
    result.add sideItem("nimlangserver", 1, "◆", st, proc() = runCmd("Nim: language server status"))
    let mainShown = if nlsMain.len > 0: relPath(nlsMain) else: "(decided when a Nim file opens)"
    result.add sideItem("main: " & mainShown, 0, "▣", (if sStr("nim.projectFile").len > 0: "set" else: "auto"),
                        proc() = (if nlsMain.len > 0: discard openFile(nlsMain)))
    for pf in nsProjects:
      if pf != nlsMain: result.add sideItem("also running: " & relPath(pf), 4, "·", depth = 1)
    result.add sideItem("Use current file as main module", 0, "⌖", "", proc() = runCmd("Nim: use current file as main module"))
    result.add sideItem("Restart nimsuggest", 0, "↻", "", proc() = runCmd("Nim: restart nimsuggest"))
  elif cfgNimIde != "off":
    result.add sideItem("ned's Nim index", 1, "◆", (if nxLibFound.len > 0: $nxFiles.len & " files" else: "no stdlib found"),
                        proc() = runCmd("Nim: language server status"))
    var live = 0
    for s in nimSugs:
      if not s.dead: inc live
    if not haveExe("nimsuggest"):
      result.add sideItem("nimsuggest: not installed (comes with nim)", 2, "·")
    elif not cfgNimSuggest:
      result.add sideItem("nimsuggest: off", 2, "·", "turn on", proc() = setSetting("nim.nimsuggest", %true))
    else:
      result.add sideItem("nimsuggest: " & (if live == 0: "starts when needed" else: $live & " running"), 0, "◇",
                          (if live > 0: "restart" else: ""), proc() = runCmd("Nim: restart nimsuggest"))
    if haveExe("nimlangserver"):
      result.add sideItem("Use nimlangserver instead", 0, "⇄", "", proc() = setSetting("nim.ide", %"nimlangserver"))
  else:
    result.add sideItem("off (settings › nim.ide)", 3, "·")
  result.add sideItem("BUILD & RUN", 6)
  result.add sideItem("Run current file", 7, ic("run"), "Alt+R", proc() = runCurrent())
  result.add sideItem("Build current file", 7, "■", "Alt+B", proc() = runCurrent(true))
  result.add sideItem("Debug with gdb", 7, ic("debug"), "", proc() = runCmd("Nim: debug with gdb"))
  result.add sideItem("Mode: " & cfgNimMode, 0, "◇", "click cycles", proc() =
    setNimMode(case cfgNimMode
      of "debug": "release"
      of "release": "danger"
      else: "debug"))
  result.add sideItem("Backend: " & cfgNimTarget, 0, "◇", "click cycles", proc() =
    setNimTarget(case cfgNimTarget
      of "c": "cpp"
      of "cpp": "js"
      of "js": "objc"
      else: "c"))
  if haveExe("nimony"):
    result.add sideItem("Compiler: " & cfgNimCompiler, 0, "◇", "nim / nimony", proc() =
      setNimCompiler(if cfgNimCompiler == "nim": "nimony" else: "nim"))
  if haveExe("nimble") and nimble.file.len > 0:
    result.add sideItem("NIMBLE", 6)
    for (l, d, a) in nimbleTaskActions():
      result.add sideItem(l, 7, "›", d, a)
    if nimble.requires.len > 0:
      result.add sideItem("DEPENDENCIES", 6)
      for r in nimble.requires: result.add sideItem(r, 0, "·", action = proc() = discard openFile(nimble.file))
  result.add sideItem("NIM TOOLS", 6)
  result.add sideItem("Expand macro/template at cursor", 0, "μ", "Alt+M", proc() = cmdExpandMacro())
  result.add sideItem("Expand one level", 0, "μ", "", proc() = cmdExpandMacro("1"))
  result.add sideItem("ARC/ORC view of current proc", 0, "⇄", "expandArc", proc() = cmdExpandArc())
  result.add sideItem("Show generated C", 0, "C", "", proc() = cmdShowC())
  result.add sideItem("Find references", 0, "⌕", "Alt+Q", proc() = cmdReferences())
  result.add sideItem("Check project", 0, ic("ok"), "nim check", proc() =
    if isNim and b.path.len > 0: runCommand("nim check --hints:off " & quoteShell(nimProjectFile(b)), parentDir(b.path))
    else: info("Open a Nim file first"))
  result.add sideItem("Generate docs", 0, "≡", "nim doc", proc() = runCmd("Nim: generate docs"))
  result.add sideItem("Language server settings…", 0, ic("gear"), "", proc() = runCmd("Nim: language server settings…"))
  result.add sideItem("ATLAS", 6)
  if haveExe("atlas"):
    result.add sideItem("install deps", 7, "›", "atlas install", proc() = runAtlas("install"))
    result.add sideItem("use package…", 7, "›", "atlas use", proc() = openPrompt(pAtlasUse, "atlas use", ""))
    result.add sideItem("update", 7, "›", "atlas update", proc() = runAtlas("update"))
    result.add sideItem("search…", 7, "›", "atlas search", proc() = openPrompt(pAtlasSearch, "atlas search", ""))
  else:
    result.add sideItem("install atlas", 2, "+", "nimble install atlas", proc() = runNimble("install -y atlas"))
  result.add sideItem("NIMONY", 6)
  if haveExe("nimony"):
    result.add sideItem("check with nimony", 7, "›", "", proc() = cmdNimony(false))
    result.add sideItem("run with nimony", 7, "›", "", proc() = cmdNimony(true))
  else:
    result.add sideItem("not installed (github.com/nim-lang/nimony)", 2, "·")
  result.add sideItem("TOOLCHAIN", 6)
  result.add toolLine("nim", "pkg install nim")
  result.add toolLine("nimble", "pkg install nim")
  result.add toolLine("nimsuggest", "ships with nim (errors while typing, inlay hints)")
  result.add toolLine("nimlangserver", "optional — click installs", proc() = runNimble("install -y nimlangserver"))
  result.add toolLine("nph", "optional (ned formats Nim itself) — click installs", proc() = runNimble("install -y nph"))
  result.add toolLine("gdb", "pkg install gdb")
  result.add toolLine("git", "pkg install git")
  result.add toolLine("rg", "pkg install ripgrep (fast search)")
  result.add toolLine("curl", "pkg install curl (AI assistant)")

proc gitRole(c: char): int = (if c in {'A', '?'}: 5 elif c == 'D': 3 elif c == 'M': 4 else: 1)

proc gitPickRepoAct(root: string, quiet = false): Action =
  result = proc() =
    gitRepo = root
    let st = GitStatusRun(pending: 0)
    for r in gitRepos: st.outs[r.root] = r.lines.join("\n") & (if r.state.len > 0: "\n#ned-state " & r.state else: "")
    gitStatusDone(st)                            # the dock shows it at once; a fresh status follows
    refreshGitStatus()
    if not quiet: info("Git: " & extractFilename(root) & (if gitBranch.len > 0: " ⎇ " & gitBranch else: ""))

proc buildGitItems(): seq[SideItem] =
  let home = gitHome()
  let ri = if remotes.len > 0: remoteOf(rootDir) else: -1
  if home.len == 0:
    result.add sideItem("Not a git repository", 2)
    if ri >= 0:
      # a remote folder without a repository: make one on the server
      let host = remotes[ri].host
      result.add sideItem("git init on " & host, 7, "+", "", proc() =
        let k = remoteOf(rootDir)
        if k < 0: return
        remoteRun(k, "git init -q", "Initialised a repository on " & host, proc() =
          let k2 = remoteOf(rootDir)
          if k2 >= 0:
            remotes[k2].git = true
            saveRemotes()
          refreshGitStatus()))
    elif haveExe("git"):
      result.add sideItem("Initialize a repository here (git init)", 7, "+", "", proc() = gitInitHere())
      result.add sideItem("Clone from a link…", 7, ic("branch"), "", proc() = gitCloneFromLink())
    else:
      result.add sideItem("git is not installed — Termux: pkg install git", 2)
    return
  # every repository of the workspace's folders: pick the one the dock (and git commands) act on
  let roots = gitRepoRoots()
  if roots.len > 1:
    result.add sideItem("REPOSITORIES  " & $roots.len, 6)
    for root in roots:
      let inf = gitRepoInfo(root)
      var detail = (if inf.branch.len > 0: "⎇ " & inf.branch else: "")
      if inf.changes > 0: detail.add "  " & $inf.changes & " changed"
      if inf.ahead > 0: detail.add "  ↑" & $inf.ahead
      if inf.behind > 0: detail.add "  ↓" & $inf.behind
      if inf.state.len > 0: detail.add "  " & inf.state & "!"
      result.add sideItem(extractFilename(root), (if root == home: 1 else: 7), (if root == home: "●" else: "○"), detail,
                          gitPickRepoAct(root))
  var branch = ""
  var staged, changes, untracked: seq[SideItem]
  for l in gitStatusLines:
    if l.len < 3: continue
    if l.startsWith("## "):
      branch = l[3 .. ^1]
      continue
    let x = l[0]
    let y = l[1]
    var path = l[3 .. ^1]
    let arrow = path.find(" -> ")
    if arrow >= 0: path = path[arrow + 4 .. ^1]
    if path.len > 1 and path[0] == '"': path = unquoteNim(path)
    let full = gitHome() / path
    if x == '?' and y == '?':
      untracked.add sideItem(path, 5, "U", "", nil, full, data = "untracked")
    else:
      if x notin {' ', '?'}: staged.add sideItem(path, gitRole(x), $x, "", nil, full, data = "staged")
      if y notin {' ', '?'}: changes.add sideItem(path, gitRole(y), $y, "", nil, full, data = "unstaged")
  let br = branch.replace("...", " → ")
  let hk = if remotes.len > 0: remoteOf(home) else: -1
  result.add sideItem((if br.len > 0: br else: "(no branch)") & (if roots.len > 1: "  · " & extractFilename(home) else: ""),
                      1, ic("branch"), (if hk >= 0: "git on " & remotes[hk].host else: ""), proc() = cmdBranches())
  let st = gitState()
  if st.len > 0:
    var conflicted: seq[SideItem]
    for l in gitStatusLines:
      if l.len > 3 and not l.startsWith("## ") and (l[0] == 'U' or l[1] == 'U' or l[0 .. 1] in ["AA", "DD"]):
        let full = gitHome() / l[3 .. ^1]
        var n = 0
        try:
          for x in lines(full):
            if x.startsWith("<<<<<<<"): inc n
        except IOError, OSError: discard
        conflicted.add sideItem(l[3 .. ^1], 3, "!", (if n > 0: $n & " conflict" & (if n > 1: "s" else: "") else: "resolved?"),
                                nil, full, data = "unstaged")
    result.add sideItem(st.toUpperAscii & " IN PROGRESS" & (if conflicted.len > 0: " · " & $conflicted.len & " file(s) with conflicts" else: ""), 6)
    for it in conflicted: result.add it
    result.add sideItem("Continue the " & st, 7, "▶", "", proc() = gitContinue())
    result.add sideItem("Abort the " & st, 7, "■", "", proc() = gitAbort())
  if gitBisecting(home):
    result.add sideItem("BISECTING" & (if bisectSteps.len > 0: " · " & bisectSteps else: ""), 6)
    if bisectAt.len > 0:
      let h = bisectAt
      let sj = bisectSubj
      result.add sideItem(h[0 ..< min(7, h.len)] & " " & sj, 5, "▸", "testing", proc() = commitMenu(h, sj))
    result.add sideItem("Good — it works here", 7, ic("ok"), "", proc() = gitBisectStep("good"))
    result.add sideItem("Bad — it is broken here", 7, "✗", "", proc() = gitBisectStep("bad"))
    result.add sideItem("Skip — cannot tell here", 7, "↷", "", proc() = gitBisectStep("skip"))
    result.add sideItem("Stop, back to where I was", 7, "■", "", proc() = gitBisectStep("reset"))
  result.add sideItem("Commit…", 7, ic("ok"), "c", proc() = gitCommitBox(false))
  if cfgAiProvider in ["ollama", "custom"] or aiKey().len > 0:
    result.add sideItem("Write the message with AI", 7, ic("ai"), "", proc() = aiCommitMessage())
  if staged.len > 0:
    result.add sideItem("STAGED CHANGES  " & $staged.len, 6)
    for it in staged: result.add it
  if changes.len > 0:
    result.add sideItem("CHANGES  " & $changes.len, 6)
    for it in changes: result.add it
  if untracked.len > 0:
    result.add sideItem("UNTRACKED  " & $untracked.len, 6)
    for it in untracked: result.add it
  if staged.len + changes.len + untracked.len == 0:
    result.add sideItem("Working tree clean", 5, ic("ok"))
  result.add sideItem("ACTIONS", 6)
  result.add sideItem("Stage everything", 7, "+", "a", proc() = gitRun(@["add", "-A"], "Staged all changes"))
  result.add sideItem("Sync (pull, then push)" & (if gitAhead + gitBehind > 0: "  ↑" & $gitAhead & " ↓" & $gitBehind else: ""),
                      7, "⟳", "", proc() = gitSync())
  result.add sideItem("Pull", 7, "↓", "L", proc() = gitNet("pull", "Pulled"))
  result.add sideItem("Push", 7, "↑", "P", proc() = gitNet("push", "Pushed"))
  result.add sideItem("Fetch", 7, "⇣", "", proc() = gitNet("fetch --all --prune", "Fetched"))
  if "github.com" in gitRemoteUrl(home):
    ghAskAccount()
    if ghAccount.len > 0:
      result.add sideItem("GitHub: @" & ghAccount, 5, ic("ok"), "signed in", proc() = cmdGithubSignIn())
    else:
      result.add sideItem("Sign in to GitHub…", 7, "→", "no passwords", proc() = cmdGithubSignIn())
  result.add sideItem("Branches…", 7, ic("branch"), "b", proc() = cmdBranches())
  result.add sideItem("History…", 7, ic("timeline"), "l", proc() = gitLogView())
  result.add sideItem("Stash…", 7, "▤", "", proc() = gitStashMenu())
  result.add sideItem("Worktrees…", 7, "⑂", "", proc() = gitWorktrees())
  if fileExists(home / ".gitmodules"):
    result.add sideItem("Submodules…", 7, "⊞", "", proc() = gitSubmodules())
  if not gitBisecting(home):
    result.add sideItem("Find the commit that broke it…", 7, "⌕", "bisect", proc() = gitBisectStart())
  result.add sideItem("Amend the last commit…", 7, "✎", "", proc() = gitCommitBox(true))
  result.add sideItem("Undo the last commit", 7, "↶", "", proc() =
    askConfirm("Undo the last commit? Its changes stay, staged. (y/n)", proc(c: char) =
      if c in {'y', 'Y'}: gitRun(@["reset", "--soft", "HEAD~1"], "Undid the last commit — its changes are staged")))

# ── timeline: git history of the current file ──

var
  timelinePath = ""
  timelineLines: seq[string]
  timelineBusy = false

proc refreshTimeline() =
  let b = buf()
  if b.path.len == 0 or timelineBusy: return
  let root = findGitRoot(parentDir(b.path))
  if not gitOk(root):
    timelinePath = b.path
    timelineLines = @[]
    return
  timelineBusy = true
  let p = b.path
  discard startJob(jkGit, "git --no-pager log --follow -n 200 --format=%h%x09%an%x09%ar%x09%s -- " & quoteShell(p),
                   root, proc(j: Job) =
    timelineBusy = false
    timelinePath = p
    timelineLines = j.output.strip.splitLines
    needRender = true)

proc commitAct(hash, path: string): Action =
  ## a version from the file's history: side by side with your file
  proc() =
    let root = findGitRoot(parentDir(path))
    let rel = relativePath(path, root).replace('\\', '/')
    let h = hash
    discard startJob(jkGit, "git --no-pager show " & quoteShell(h & ":" & rel), root, proc(j: Job) =
      var old = if j.code == 0: j.output.split('\n') else: @[]
      if old.len > 0 and old[^1].len == 0: old.setLen(old.len - 1)
      let src = openFile(path)
      if src != nil: openDiffView(h & " ↔ " & extractFilename(path), old, h & ": " & extractFilename(path), src, @[],
                                  extractFilename(path) & " (yours)", src.lang))

proc buildTimelineItems(): seq[SideItem] =
  let b = buf()
  if b.path.len == 0: return @[sideItem("Open a file to see its history", 2)]
  if timelinePath != b.path:
    refreshTimeline()
    return @[sideItem("Loading…", 2)]
  if timelineLines.len == 0 or timelineLines[0].len == 0:
    return @[sideItem("No commits for this file yet", 2)]
  result.add sideItem(extractFilename(b.path), 6)
  for l in timelineLines:
    let f = l.split('\t')
    if f.len < 4: continue
    result.add sideItem(f[3], 0, "◯", f[2] & " · " & f[1], commitAct(f[0], b.path))

# ── search view: the query lives in the dock, results grouped by file ──

proc collapseAct(p: string): Action =
  proc() =
    if p in searchCollapsed: searchCollapsed.excl p else: searchCollapsed.incl p

proc buildSearchItems(): seq[SideItem] =
  if searchHits.len == 0:
    if dockQueryRan.len == 0: return @[sideItem("Type and press Enter to search the project", 2)]
    return @[sideItem((if searchDone: "No results" else: "Searching…"), 2)]
  var last = ""
  var counts = initCountTable[string]()
  for h in searchHits: counts.inc h.path
  for h in searchHits:
    if h.path != last:
      last = h.path
      result.add sideItem(relPath(h.path), 0, (if h.path in searchCollapsed: ic("chevR") else: ic("chevD")),
                          $counts[h.path], collapseAct(h.path), data = "file")
    if h.path in searchCollapsed: continue
    var t = h.text.strip
    result.add sideItem(t, 0, "", $(h.line + 1), nil, h.path, h.line, 1, "hit")
    result[^1].col = h.col
