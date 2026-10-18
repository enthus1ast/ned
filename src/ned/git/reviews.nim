# ── GitHub review comments of the branch's pull request, on the lines they are about: a note at the end of the
#    line, the whole thread on hover, a list to go through them, reply and resolve (the GitHub CLI) ──

type ReviewThread = object
  id: string                    # GitHub's id of the thread (to resolve it)
  firstId: int                  # its first comment's number (to reply to it)
  rel: string                   # the file, from the repository's root
  line: int                     # 0-based, in the pull request's version of the file (-1: not known)
  outdated, resolved: bool
  comments: seq[(string, string, string)]   # (who, what, link)

var
  reviewThreads: seq[ReviewThread]
  reviewRoot = ""
  reviewPr = 0
  reviewPrUrl = ""
  reviewRepo = ("", "")
  reviewBusy = false

const ReviewQuery = "query($owner:String!,$repo:String!,$n:Int!){repository(owner:$owner,name:$repo){" &
  "pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved isOutdated path line originalLine " &
  "comments(first:30){nodes{databaseId author{login} body url}}}}}}}"

proc reviewThreadsAt(path: string, line: int): seq[ReviewThread] =
  if reviewThreads.len == 0 or reviewRoot.len == 0 or not path.startsWith(reviewRoot & "/"): return
  let rel = path[reviewRoot.len + 1 .. ^1]
  for t in reviewThreads:
    if t.rel == rel and t.line == line: result.add t

proc reviewNoteAt(path: string, line: int): string =
  ## the end-of-line note: the open threads on this line, their first comment
  if reviewThreads.len == 0: return
  for t in reviewThreadsAt(path, line):
    if t.resolved or t.comments.len == 0: continue
    let (who, body, _) = t.comments[0]
    let first = body.strip.splitLines()
    let s = if first.len > 0: first[0] else: ""
    result = ic("comment") & " " & who & ": " & s & (if t.comments.len > 1: "  (+" & $(t.comments.len - 1) & ")" else: "")
    return

proc reviewHoverAt(path: string, line: int): string =
  ## the threads on this line, for the hover
  for t in reviewThreadsAt(path, line):
    if result.len > 0: result.add "\n\n---\n\n"
    result.add "**Review" & (if t.resolved: " (resolved)" elif t.outdated: " (outdated)" else: "") & "**\n\n"
    for (who, body, _) in t.comments: result.add "**" & who & "**: " & body.strip & "\n\n"
  if result.len > 0: result.add "palette › *GitHub: review comments* to reply or resolve"

proc reviewsLoad(root: string, quiet: bool, then: proc() = nil) =
  ## the branch's pull request and its review threads, from GitHub (three gh calls, one after another)
  if not haveExe("gh"):
    if not quiet: warn("Review comments need the GitHub CLI: " & installHint("gh", "gh") & ", then gh auth login")
    return
  if reviewBusy: return
  reviewBusy = true
  if not quiet: info("Asking GitHub for the review comments…")
  discard startJob(jkTool, "gh pr view --json number,url 2>/dev/null", root, proc(j: Job) =
    var n = 0
    var url = ""
    try:
      let js = parseJson(j.output)
      n = js{"number"}.getInt
      url = js{"url"}.getStr
    except CatchableError: discard
    if n == 0:
      reviewBusy = false
      if not quiet: info("This branch has no pull request on GitHub")
      return
    discard startJob(jkTool, "gh repo view --json owner,name 2>/dev/null", root, proc(j2: Job) =
      var owner, name = ""
      try:
        let js = parseJson(j2.output)
        owner = js{"owner"}{"login"}.getStr
        name = js{"name"}.getStr
      except CatchableError: discard
      if owner.len == 0 or name.len == 0:
        reviewBusy = false
        if not quiet: error("gh could not tell which GitHub repository this is")
        return
      let cmd = "gh api graphql -f query=" & quoteShell(ReviewQuery) & " -F owner=" & quoteShell(owner) &
                " -F repo=" & quoteShell(name) & " -F n=" & $n & " 2>&1"
      discard startJob(jkTool, cmd, root, proc(j3: Job) =
        reviewBusy = false
        var got: seq[ReviewThread]
        try:
          let js = parseJson(j3.output)
          for th in js{"data"}{"repository"}{"pullRequest"}{"reviewThreads"}{"nodes"}:
            var t = ReviewThread(id: th{"id"}.getStr, rel: th{"path"}.getStr, resolved: th{"isResolved"}.getBool,
                                 outdated: th{"isOutdated"}.getBool, line: -1)
            let ln = if th{"line"} != nil and th{"line"}.kind == JInt: th{"line"}.getInt
                     elif th{"originalLine"} != nil and th{"originalLine"}.kind == JInt: th{"originalLine"}.getInt
                     else: 0
            if ln > 0: t.line = ln - 1
            for c in th{"comments"}{"nodes"}:
              if t.firstId == 0: t.firstId = c{"databaseId"}.getInt
              t.comments.add (c{"author"}{"login"}.getStr, c{"body"}.getStr, c{"url"}.getStr)
            got.add t
        except CatchableError:
          if not quiet: error("GitHub's review comments could not be read: " & j3.output.strip.splitLines()[0])
          return
        reviewThreads = got
        reviewRoot = root
        reviewPr = n
        reviewPrUrl = url
        reviewRepo = (owner, name)
        var open = 0
        for t in got:
          if not t.resolved: inc open
        if not quiet:
          info("Pull request #" & $n & ": " & $got.len & " review thread" & (if got.len == 1: "" else: "s") &
               " (" & $open & " open)")
        needRender = true
        if then != nil: then())))

proc reviewsAfterPush(root: string) =
  ## after a push: the comments again, when they are shown
  if reviewThreads.len > 0 and root == reviewRoot: reviewsLoad(root, quiet = true)

proc reviewReply(t: ReviewThread) =
  let (owner, name) = reviewRepo
  let root = reviewRoot
  let id = t.firstId
  gitAsk("Reply to " & (if t.comments.len > 0: t.comments[0][0] else: "the review"), "", proc(text: string) =
    if text.strip.len == 0: return
    let cmd = "gh api " & quoteShell("repos/" & owner & "/" & name & "/pulls/" & $reviewPr & "/comments/" & $id &
              "/replies") & " -f body=" & quoteShell(text) & " >/dev/null 2>&1"
    discard startJob(jkTool, cmd, root, proc(j: Job) =
      if j.code == 0:
        info("Replied")
        reviewsLoad(root, quiet = true)
      else: error("GitHub did not take the reply")))

proc reviewResolve(t: ReviewThread, resolve: bool) =
  let root = reviewRoot
  let m = if resolve: "resolveReviewThread" else: "unresolveReviewThread"
  let q = "mutation($id:ID!){" & m & "(input:{threadId:$id}){thread{isResolved}}}"
  discard startJob(jkTool, "gh api graphql -f query=" & quoteShell(q) & " -F id=" & quoteShell(t.id) & " >/dev/null 2>&1",
                   root, proc(j: Job) =
    if j.code == 0:
      info(if resolve: "Resolved" else: "Opened again")
      reviewsLoad(root, quiet = true)
    else: error("GitHub did not change the thread"))

proc reviewThreadMenu(t: ReviewThread) =
  let root = reviewRoot
  var items: seq[(string, string, Action)]
  items.add act("Go to it", t.rel & (if t.line >= 0: ":" & $(t.line + 1) else: ""), proc() =
    let b = openFile(root / t.rel)
    if b != nil and t.line >= 0: b.centerOn(b.clampPos(Pos(line: t.line, col: 0))))
  items.add act("Reply…", "", proc() = reviewReply(t))
  items.add act((if t.resolved: "Open it again" else: "Resolve"), "", proc() = reviewResolve(t, not t.resolved))
  if t.comments.len > 0 and t.comments[0][2].len > 0:
    let u = t.comments[0][2]
    items.add act("Open on GitHub", "", proc() = openInBrowser(u))
  openActions((if t.comments.len > 0: t.comments[0][0] & ": " & t.comments[0][1].strip.splitLines()[0] else: "Review"), items)

proc threadAct(t: ReviewThread): Action =
  result = proc() = reviewThreadMenu(t)

proc cmdReviewComments() =
  ## the review threads of the branch's pull request: open ones first
  let root = gitHome()
  if root.len == 0:
    info("Not a git repository")
    return
  reviewsLoad(root, quiet = false, proc() =
    if reviewThreads.len == 0:
      info("Pull request #" & $reviewPr & " has no review comments")
      return
    var items: seq[(string, string, Action)]
    for pass in 0 .. 1:
      for t in reviewThreads:
        if (pass == 0) == t.resolved: continue
        let who = if t.comments.len > 0: t.comments[0][0] else: ""
        let what = if t.comments.len > 0: t.comments[0][1].strip.splitLines()[0] else: ""
        items.add act((if t.resolved: "✓ " else: ic("comment") & " ") & who & ": " & what,
                      t.rel & (if t.line >= 0: ":" & $(t.line + 1) else: "") & (if t.outdated: " · outdated" else: ""),
                      threadAct(t))
    openActions("Pull request #" & $reviewPr & " — review comments", items))
