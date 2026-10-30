# ── interactive rebase, cherry-pick from a branch, compare branches, branch graph, GitHub (gh) ──

proc gitRebasePlan(root, base, what: string) =
  ## opens the plan of an interactive rebase in a tab of its own: lists the commits after `base` (oldest first) as `pick
  ## <hash> <subject>` lines under a few lines of instructions, ready to be edited; refuses when there are merge commits
  ## after it or no commits at all. Saving the tab runs the rebase (doRebaseFromBuffer)
  discard startJob(jkGit, "git rev-list --merges --count " & quoteShell(base) & "..HEAD && " &
                   "git --no-pager log --reverse --format='%h%x09%s' " & quoteShell(base) & "..HEAD", root, proc(j: Job) =
    var ls = j.output.strip.splitLines
    if j.code != 0 or ls.len == 0:
      error("git: " & j.output.strip.splitLines()[^1])
      return
    if ls[0].strip != "0":
      error("There are merge commits after " & what & " — rebase those in the terminal (git rebase -i --rebase-merges)")
      return
    var orig: seq[(string, string)]
    for l in ls[1 .. ^1]:
      let f = l.split('\t', 1)
      if f.len == 2: orig.add (f[0], f[1])
    if orig.len == 0:
      info("No commits after " & what)
      return
    var text = "# Interactive rebase: " & $orig.len & " commit(s) after " & what & ", oldest first.\n" &
               "# Change the first word of a line:  pick · reword (then edit the message on the line) · squash (join it\n" &
               "# to the line above, keeping both messages) · fixup (join it, drop its message) · drop · edit (stop there).\n" &
               "# Alt+↑ / Alt+↓ moves a line. Ctrl+S starts the rebase; closing the tab cancels it. Uncommitted changes\n" &
               "# are put aside while it runs. On a conflict: fix the files, then Git › Continue (or Abort).\n"
    for (h, s) in orig: text.add "pick " & h & " " & s & "\n"
    let pb = openScratch("Rebase plan", text, langByName("Text"))
    pb.readOnly = false
    pb.savedSeq = pb.topSeq()
    rebaseBufs[pb.id] = RebaseBuf(root: root, base: base, orig: orig)
    pb.setSingle(Pos(line: 5, col: 0))
    focus = fEditor)

proc gitInteractiveRebase() =
  ## Git › Interactive rebase: asks which commits to rebase — those not pushed yet (everything after the upstream
  ## branch) or those made after any of the last 40 commits — then opens the plan for them. Refused outside a repository
  ## and while another rebase, merge or similar is in progress
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  if gitState().len > 0:
    error("A " & gitState() & " is already in progress — Git › Continue or Abort first")
    return
  discard startJob(jkGit, "git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null; echo ---; " &
                   "git --no-pager log --format='%h%x09%s%x09%ar' -n 40", root, proc(j: Job) =
    let parts = j.output.split("---")
    let up = if parts.len > 1: parts[0].strip else: ""
    var items: seq[(string, string, Action)]
    if up.len > 0:
      items.add act("Commits not pushed yet", "everything after " & up, proc() = gitRebasePlan(root, "@{upstream}", up))
    var first = true
    for l in (if parts.len > 1: parts[1] else: j.output).strip.splitLines:
      let f = l.split('\t')
      if f.len < 3: continue
      let h = f[0]
      let s = f[1]
      if first:                         # the newest commit: nothing after it to rebase
        first = false
        continue
      capture h, s:
        items.add act("after  " & s, h & " · " & f[2] & " — rebase the commits made after this one",
                      proc() = gitRebasePlan(root, h, h & " (" & s & ")"))
    if items.len == 0: info("Not enough commits to rebase")
    else: openActions("Interactive rebase — which commits?", items))

proc doRebaseFromBuffer(b: Buffer): bool =
  ## saving the rebase plan tab: checks every line (a known action, a known commit from the plan, none twice, nothing
  ## squashed into a commit that is not there), turns the plan into git's todo list — a reworded commit becomes a pick
  ## followed by an amend with the new message, commits left out of the plan are dropped — and, after a confirmation (it
  ## rewrites history), runs `git rebase -i --autostash` with that list; the plan tab closes when the rebase is done.
  ## Gives false when the plan is wrong or changes nothing
  let rb = rebaseBufs[b.id]
  var known = initTable[string, string]()
  for (h, s) in rb.orig: known[h] = s
  var todo: seq[string]
  var counts = initCountTable[string]()
  var seen: HashSet[string]
  var kept = 0
  for raw in b.lines:
    let l = raw.strip
    if l.len == 0 or l.startsWith("#"): continue
    let w = l.splitWhitespace()
    if w.len < 2:
      error("Not a plan line: " & l)
      return false
    let act = case w[0].toLowerAscii
      of "p", "pick": "pick"
      of "r", "reword": "reword"
      of "s", "squash": "squash"
      of "f", "fixup": "fixup"
      of "d", "drop": "drop"
      of "e", "edit": "edit"
      else: ""
    if act.len == 0:
      error("Unknown action \"" & w[0] & "\" — pick, reword, squash, fixup, drop or edit")
      return false
    let h = w[1]
    if h notin known:
      error("Unknown commit " & h & " — keep the hashes as they are")
      return false
    if h in seen:
      error(h & " is in the plan twice")
      return false
    seen.incl h
    counts.inc act
    if act in ["squash", "fixup"] and kept == 0:
      error("The first commit kept cannot be " & act & "ed into the one above it — there is none")
      return false
    if act != "drop": inc kept
    let msg = if l.len > w[0].len + 1 + h.len: l[w[0].len + 1 + h.len .. ^1].strip else: ""
    case act
    of "reword":
      todo.add "pick " & h
      if msg.len > 0 and msg != known[h]:
        todo.add "exec git commit --amend --no-verify -m " & quoteShell(msg)
    else: todo.add act & " " & h
  var dropped = 0
  for (h, _) in rb.orig:
    if h notin seen:
      todo.add "drop " & h
      inc dropped
  var summary: seq[string]
  for k in ["reword", "squash", "fixup", "drop", "edit"]:
    let n = counts[k] + (if k == "drop": dropped else: 0)
    if n > 0: summary.add $n & " " & k
  let order = block:
    var o: seq[string]
    for l in todo:
      if not l.startsWith("exec"): o.add l.split(' ')[1]
    var same = true
    for i, (h, _) in rb.orig:
      if i >= o.len or o[i] != h: same = false
    same
  if summary.len == 0 and order:
    info("The plan changes nothing — edit the first words or move lines, then Ctrl+S")
    return false
  let tf = privTmp("rebase-todo")
  try: writeFile(tf, todo.join("\n") & "\n")
  except CatchableError as e:
    error("Cannot write the plan: " & e.msg)
    return false
  let id = b.id
  askConfirm("Rebase " & $rb.orig.len & " commit(s)" & (if summary.len > 0: ": " & summary.join(", ") else: "") &
             (if not order: " (new order)" else: "") & "? It rewrites history — only for commits not shared yet. (y/n)",
    proc(c: char) =
      if c notin {'y', 'Y'}: return
      gitShell("GIT_SEQUENCE_EDITOR=" & quoteShell("cp " & quoteShell(tf)) & " GIT_EDITOR=true " &
               "git rebase -i --autostash " & quoteShell(rb.base), "Rebased", proc() =
        let pb = bufById(id)
        if pb != nil:
          rebaseBufs.del pb.id
          pb.savedSeq = pb.topSeq()
          let i = bufs.find(pb)
          if i >= 0: closeBufferAt(i)
        readBranch(), rb.root))
  b.savedSeq = b.topSeq()
  true

proc pickBranch(title: string, cb: proc(name: string)) =
  ## local and remote branches other than the current one ("$cur" in the title: the branch you are on, read fresh)
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  discard startJob(jkGit, "git for-each-ref --sort=-committerdate --format='%(HEAD)%09%(refname:short)%09%(refname)%09%(committerdate:relative)' refs/heads refs/remotes", root, proc(j: Job) =
    var items: seq[(string, string, Action)]
    for l in j.output.splitLines:
      let f = l.split('\t')
      if f.len < 4: continue
      if f[0] == "*":
        gitBranch = f[1]                     # the branch may have changed outside ned
        continue
      if f[1].endsWith("/HEAD"): continue
      let n = f[1]
      capture n:
        items.add act(n, (if f[2].startsWith("refs/remotes/"): "remote · " else: "") & f[3], proc() = cb(n))
    if items.len == 0: info("No other branches")
    else: openActions(title.replace("$cur", gitBranch), items))

proc gitCherryPickFromBranch() =
  ## Git › Cherry-pick from a branch: asks for a branch, lists its last commits that this branch does not have, and
  ## copies the chosen one onto the current branch (`git cherry-pick`) after a confirmation
  let root = gitHome()
  pickBranch("Cherry-pick from which branch?", proc(br: string) =
    discard startJob(jkGit, "git --no-pager log --format='%h%x09%s%x09%ar' -n 100 HEAD.." & quoteShell(br), root,
                     proc(j: Job) =
      var items: seq[(string, string, Action)]
      for l in j.output.splitLines:
        let f = l.split('\t')
        if f.len < 3: continue
        let h = f[0]
        capture h:
          items.add act(f[1], h & " · " & f[2], proc() =
            askConfirm("Copy " & h & " onto " & gitBranch & "? (y/n)", proc(c: char) =
              if c in {'y', 'Y'}: gitShell("git cherry-pick " & h, "Cherry-picked " & h)))
      if items.len == 0: info(br & " has no commits that " & gitBranch & " does not have")
      else: openActions("Commits on " & br & " that are not here", items)))

proc gitCompareBranch() =
  ## what changed on this branch since it left another one — the files, then each as a side-by-side diff
  let root = gitHome()
  pickBranch("Compare $cur with…", proc(br: string) =
    discard startJob(jkGit, "git merge-base HEAD " & quoteShell(br) & " && git --no-pager diff --name-status " &
                     quoteShell(br) & "...HEAD", root, proc(j: Job) =
      let ls = j.output.strip.splitLines
      if j.code != 0 or ls.len == 0:
        error("git: " & j.output.strip)
        return
      let mb = ls[0].strip
      var items: seq[(string, string, Action)]
      for l in ls[1 .. ^1]:
        let f = l.split('\t')
        if f.len < 2: continue
        let st = f[0]
        let path = f[^1]
        let old = if f.len >= 3: f[1] else: path
        capture st, path, old:
          items.add act(st & "  " & path, (case st[0]
            of 'A': "new on " & gitBranch
            of 'D': "deleted on " & gitBranch
            of 'R': "renamed from " & old
            else: "changed"), proc() =
              gitShowLines(root, mb & ":" & old, proc(before: seq[string]) =
                let full = root / path
                let src = if fileExists(full): loadBuffer(full) else: nil
                let after = if src != nil: src.lines else: @[]
                openDiffView(path & " vs " & br, (if st[0] == 'A': @[] else: before), br & ": " & old, src, after,
                             gitBranch & " (now): " & path, detectLang(full, ""))))
      if items.len == 0: info(gitBranch & " has no changes since it left " & br)
      else: openActions(gitBranch & " vs " & br & " — " & $items.len & " file(s); pick one for its diff", items)))

proc gitBranchGraph() =
  ## Git › Branch graph: shows `git log --graph --all` of the last 600 commits, with branch names, in a read-only tab
  ## (Enter on a commit shows its files)
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  discard startJob(jkGit, "git --no-pager log --graph --all --color=never --decorate=short " &
                   "--format='%h%d %s · %an, %ar' -n 600", root, proc(j: Job) =
    if j.code != 0:
      error("git log: " & j.output.strip)
      return
    let gb = openScratch("Branch graph", j.output, langByName("Text"))
    graphBufs.incl gb.id
    info("Branch graph — Enter on a commit shows its files")
    needRender = true)
