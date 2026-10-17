# ── git: undo — the last things done to the branch (git's reflog: commits, amends, pulls, merges, rebases,
#    resets, switches), each undone in one step: the branch goes back to where it was before, your uncommitted
#    work kept. A commit already pushed is reverted (a new commit) unless you say otherwise ──

type GitStep = object
  hash, subject, ago: string     # the state after the step; what git calls it ("commit: fix x"); when

proc gitSteps(root: string, n = 12): seq[GitStep] =
  ## the branch's recent steps, newest first (the one at i was made from the state at i + 1)
  let (ok, o, _) = runFilter("git reflog -n " & $n & " --date=relative --format='%H%x09%gs%x09%gd' 2>/dev/null", "",
                             root, 4000)
  if not ok: return
  for l in o.splitLines:
    let p = l.split('\t')
    if p.len < 3 or p[0].len < 7: continue
    var ago = p[2]
    let a = ago.find('{')
    if a >= 0 and ago.endsWith("}"): ago = ago[a + 1 ..< ^1]
    result.add GitStep(hash: p[0], subject: p[1], ago: ago)

proc stepWords(s: string): string =
  ## a step as a person would say it
  let c = s.find(": ")
  let kind = if c > 0: s[0 ..< c] else: s
  let what = if c > 0: s[c + 2 .. ^1] else: ""
  if kind == "commit" or kind == "commit (initial)": "the commit “" & what & "”"
  elif kind == "commit (amend)": "the amend of “" & what & "”"
  elif kind == "commit (merge)": "the merge commit “" & what & "”"
  elif kind.startsWith("pull"): "the pull" & (if what.len > 0: " (" & what & ")" else: "")
  elif kind.startsWith("merge"): "the " & kind & (if what.len > 0: " (" & what & ")" else: "")
  elif kind.startsWith("rebase"): "the rebase"
  elif kind.startsWith("reset"): "the reset (" & what & ")"
  elif kind.startsWith("checkout"): "the switch (" & what & ")"
  elif kind.startsWith("cherry-pick"): "the cherry-pick “" & what & "”"
  elif kind.startsWith("revert"): "the revert “" & what & "”"
  else: s

proc stepGroup(s: string): string =
  ## the steps of one rebase (or pull --rebase) share this: "rebase", "pull --rebase" — "" for a step of its own
  let i = s.find(" (")
  if i > 0:
    let e = s.find(')', i)
    if e > i and s[i + 2 ..< e] in ["start", "pick", "finish", "continue", "squash", "fixup", "reword", "edit",
                                    "abort", "returning"]:
      return s[0 ..< i]
  ""

proc gitPushed(root, commit: string): bool =
  ## is this commit on the branch's upstream already (pushed)?
  let (ok, _, _) = runFilter("git merge-base --is-ancestor " & quoteShell(commit) & " '@{u}' 2>/dev/null", "", root, 4000)
  ok

proc gitUndoTo(root: string, steps: seq[GitStep], k: int) =
  ## back to the state before steps[k] (and every step after it)
  if k + 1 >= steps.len:
    info("Nothing before " & stepWords(steps[k].subject) & " to go back to")
    return
  # a rebase (its steps one group): back to before it started
  var j = k
  let g = stepGroup(steps[k].subject)
  if g.len > 0:
    while j + 1 < steps.len and stepGroup(steps[j + 1].subject) == g: inc j
  if j + 1 >= steps.len:
    info("Nothing before " & stepWords(steps[k].subject) & " to go back to")
    return
  let tgt = steps[j + 1].hash
  let s0 = steps[k].subject
  if s0.startsWith("checkout: moving from "):
    # a switch: switch back
    let rest = s0["checkout: moving from ".len .. ^1]
    let t = rest.find(" to ")
    let back = if t > 0: rest[0 ..< t] else: ""
    if back.len > 0:
      gitRun(@["switch", back], "Back on " & back)
      return
  var onlyCommits = true
  for i in 0 .. k:
    let s = steps[i].subject
    if not (s.startsWith("commit:") or s.startsWith("commit (amend)")): onlyCommits = false
  let head = steps[0].hash
  let pushed = gitPushed(root, head) and head != tgt
  let what = stepWords(s0)
  let mode = if onlyCommits: "--soft" else: "--keep"
  proc doIt() =
    gitShell("git reset " & mode & " " & tgt,
             "Undid " & what & (if onlyCommits: " — its changes are staged" else: " — your uncommitted work is kept"),
             nil, root)
  if pushed and k == 0 and s0.startsWith("commit:"):
    askConfirm("This commit is pushed already — undoing it would rewrite what others may have. " &
               "(r)evert it with a new commit, (u)ndo it anyway (you will have to force-push), (c)ancel", proc(c: char) =
      if c == 'r': gitShell("git revert --no-edit HEAD", "Reverted " & what & " with a new commit", nil, root)
      elif c == 'u': doIt())
  elif pushed:
    askConfirm("What this goes back over is pushed already — you will have to force-push after. Undo " & what &
               " anyway? (u)ndo, (c)ancel", proc(c: char) =
      if c == 'u': doIt())
  else:
    askConfirm("Undo " & what & "? " & (if onlyCommits: "Its changes stay, staged." else: "Your uncommitted work is kept.") &
               " (u)ndo, (c)ancel", proc(c: char) =
      if c == 'u': doIt())

proc undoAct(root: string, steps: seq[GitStep], k: int): Action =
  ## (an action of its own for each step: a closure made in the loop would see the loop's last k)
  result = proc() = gitUndoTo(root, steps, k)

proc gitUndoMenu() =
  ## the last steps of the branch: pick one to go back to before it
  let root = gitHome()
  if not gitOk(root):
    error("Not a git repository")
    return
  if gitState().len > 0:
    info("A " & gitState() & " is in progress — continue or abort it first")
    return
  let steps = gitSteps(root)
  if steps.len < 2:
    info("Nothing to undo yet")
    return
  var items: seq[(string, string, Action)]
  var lastGroup = ""
  for k in 0 ..< min(steps.len - 1, 10):
    let kk = k
    let g = stepGroup(steps[k].subject)
    if g.len > 0 and g == lastGroup: continue        # (a rebase's steps: once)
    lastGroup = g
    items.add act((if k == 0: "Undo " else: "Go back to before ") & stepWords(steps[k].subject), steps[k].ago,
                  undoAct(root, steps, kk))
  openActions("Git: undo — the branch goes back to before it; your uncommitted work stays", items)

proc gitUndoLast() =
  ## undo the newest step (a commit, an amend, a pull, a merge …)
  let root = gitHome()
  if not gitOk(root):
    error("Not a git repository")
    return
  let steps = gitSteps(root, 3)
  if steps.len < 2:
    info("Nothing to undo yet")
    return
  gitUndoTo(root, gitSteps(root), 0)
