proc ghReady(): bool =
  if not haveExe("gh"):
    warn("This needs the GitHub CLI: " & installHint("gh", "gh") & ", then gh auth login")
    return false
  if gitHome().len == 0:
    info("Not a git repository")
    return false
  true

proc ciRefresh() =
  ## GitHub Actions for this branch → the status bar (looks again while a run is going)
  if not haveExe("gh") or gitBranch.len == 0: return
  let root = gitHome()
  if root.len == 0: return
  let br = gitBranch
  ciDue = false
  discard startJob(jkTool, "gh run list --branch " & quoteShell(br) & " --limit 1 --json status,conclusion 2>/dev/null",
                   root, proc(j: Job) =
    if br != gitBranch: return
    ciBranch = br
    try:
      let a = parseJson(j.output)
      if a.kind != JArray or a.len == 0:
        ciStatus = ""
        return
      let st = a[0]{"status"}.getStr
      let co = a[0]{"conclusion"}.getStr
      ciStatus = if st != "completed": "⟳" elif co == "success": "✓" elif co in ["skipped", "neutral"]: "–" else: "✗"
      if st != "completed":
        ciDue = true
        ciDueAt = getMonoTime() + initDuration(seconds = 30)
    except CatchableError: ciStatus = ""
    needRender = true)

proc ghPullRequests() =
  if not ghReady(): return
  let root = gitHome()
  info("Asking GitHub for the pull requests…")
  discard startJob(jkTool, "gh pr list --limit 50 --json number,title,author,headRefName,isDraft 2>&1", root, proc(j: Job) =
    var a: JsonNode
    try: a = parseJson(j.output)
    except CatchableError:
      error("gh: " & j.output.strip.splitLines()[^1])
      return
    var items: seq[(string, string, Action)]
    for pr in jitems(a):
      let n = $pr{"number"}.getInt
      let title = pr{"title"}.getStr
      capture n, title:
        items.add act("#" & n & "  " & title, pr{"headRefName"}.getStr & " · " & pr{"author"}{"login"}.getStr &
                      (if pr{"isDraft"}.getBool: " · draft" else: ""), proc() =
          openActions("#" & n & "  " & title, @[
            act("Check it out", "gh pr checkout " & n, proc() =
              discard startJob(jkGit, "gh pr checkout " & n & " 2>&1", root, proc(j2: Job) =
                if j2.code == 0:
                  readBranch()
                  refreshGitStatus()
                  checkDiskChanges()
                  info("On the branch of #" & n)
                else: error("gh: " & j2.output.strip.splitLines()[^1]))),
            act("Its changes", "gh pr diff", proc() =
              toolOutput("PR #" & n, "gh pr diff " & n & " --color=never", root, proc(o: string): string = o,
                         langByName("Diff"))),
            act("Checks (CI)", "gh pr checks", proc() =
              toolOutput("Checks #" & n, "gh pr checks " & n & " 2>&1", root, proc(o: string): string = o,
                         langByName("Text"))),
            act("Read it", "gh pr view", proc() =
              toolOutput("PR #" & n, "gh pr view " & n & " --comments 2>&1", root, proc(o: string): string = o,
                         langByName("Markdown"))),
            act("Open in the browser", "", proc() =
              discard startJob(jkAux, "gh pr view " & n & " --web", root))]))
    if items.len == 0: info("No open pull requests")
    else: openActions("Pull requests", items))

proc ghIssues() =
  if not ghReady(): return
  let root = gitHome()
  info("Asking GitHub for the issues…")
  discard startJob(jkTool, "gh issue list --limit 50 --json number,title,labels 2>&1", root, proc(j: Job) =
    var a: JsonNode
    try: a = parseJson(j.output)
    except CatchableError:
      error("gh: " & j.output.strip.splitLines()[^1])
      return
    var items: seq[(string, string, Action)]
    for it in jitems(a):
      let n = $it{"number"}.getInt
      var labels: seq[string]
      for l in jitems(it{"labels"}): labels.add l{"name"}.getStr
      capture n:
        items.add act("#" & n & "  " & it{"title"}.getStr, labels.join(", "), proc() =
          openActions("#" & n, @[
            act("Read it", "gh issue view", proc() =
              toolOutput("Issue #" & n, "gh issue view " & n & " --comments 2>&1", root, proc(o: string): string = o,
                         langByName("Markdown"))),
            act("Open in the browser", "", proc() = discard startJob(jkAux, "gh issue view " & n & " --web", root))]))
    if items.len == 0: info("No open issues")
    else: openActions("Issues", items))

proc ghRuns() =
  if not ghReady(): return
  let root = gitHome()
  discard startJob(jkTool, "gh run list --limit 15 --json displayTitle,status,conclusion,headBranch,url,createdAt,workflowName 2>&1",
                   root, proc(j: Job) =
    var a: JsonNode
    try: a = parseJson(j.output)
    except CatchableError:
      error("gh: " & j.output.strip.splitLines()[^1])
      return
    var items: seq[(string, string, Action)]
    for r in jitems(a):
      let url = r{"url"}.getStr
      let st = r{"status"}.getStr
      let co = r{"conclusion"}.getStr
      let mark = if st != "completed": "⟳" elif co == "success": "✓" elif co in ["skipped", "neutral"]: "–" else: "✗"
      capture url:
        items.add act(mark & "  " & r{"displayTitle"}.getStr, r{"workflowName"}.getStr & " · " & r{"headBranch"}.getStr,
                      proc() = openInBrowser(url))
    ciRefresh()
    if items.len == 0: info("No workflow runs")
    else: openActions("GitHub Actions — pick one to open it", items))

proc ghMenu() =
  openActions("GitHub", @[
    act("Pull requests", "check out, see changes and checks, open", proc() = ghPullRequests()),
    act("Issues", "read, open", proc() = ghIssues()),
    act("Actions (CI)", "the latest runs", proc() = ghRuns()),
    act("Review comments", "of this branch's pull request, on their lines — reply, resolve",
        proc() = runCmd("Git: GitHub review comments…")),
    act("Create a pull request", "gh pr create --fill, in the terminal", proc() = runCmd("Git: create a pull request (gh)"))])
