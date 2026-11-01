## github — the project's pull requests and issues on GitHub, through the gh CLI: listed, read, checked out, commented on
##
##   the Plugins dock          GITHUB: the open pull requests and issues — tap one for what to do with it; ↻ reads
##                             them again
##   GitHub: pull requests…    the open pull requests to choose from, then: read it (its description, reviews and
##                             comments in a tab), its diff (in a tab), check it out (gh switches to its branch),
##                             its checks, comment on it, open it in the browser, merge it (in the terminal: gh asks
##                             how)
##   GitHub: issues…           the open issues to choose from, then: read it, comment on it, close it (asked first),
##                             open it in the browser
##   GitHub: new issue…        its title, then its text (a line; more in the browser after) — made, its address said
##   GitHub: new pull request  gh pr create in the terminal, for the branch you are on (gh asks its questions there)
##   settings                  plugins.github.limit — how many of each are listed (30)
##
## It needs gh, GitHub's own command-line tool, on PATH and signed in: Termux `pkg install gh`, elsewhere
## https://cli.github.com — then `gh auth login` once. It works in the repository of the project's folder; what gh
## says when it cannot (not signed in, no GitHub remote) is shown as it says it.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs gh, GitHub's command-line tool, to list, read, comment on and check out pull requests and issues")

settingDef("limit", 30, "GitHub: how many pull requests and issues are listed")

const View = "GITHUB"

type Item* = object
  number*: int
  title*, author*, branch*, url*, updated*: string
  labels*: seq[string]
  draft*: bool
  isPr*: bool

func jsonItems(j: JsonNode): seq[JsonNode] =
  ## a JSON array's items; none for anything else (a key that is not there: nil)
  if j != nil and j.kind == JArray: j.getElems else: @[]

proc itemsOf*(text: string, isPr: bool): seq[Item] =
  ## gh pr list / gh issue list --json …
  let j = parseJson(text)
  if j.kind != JArray: return
  for x in jsonItems(j):
    var labels: seq[string]
    for l in jsonItems(x{"labels"}): labels.add l{"name"}.getStr
    result.add Item(number: x{"number"}.getInt, title: x{"title"}.getStr, author: x{"author"}{"login"}.getStr,
                    branch: x{"headRefName"}.getStr, url: x{"url"}.getStr, updated: x{"updatedAt"}.getStr,
                    labels: labels, draft: x{"isDraft"}.getBool, isPr: isPr)

func ghWhy*(o: string, code: int): string =
  ## what gh said when it could not, in a line
  if code == 127: return "gh is not installed (Termux: pkg install gh — then gh auth login)"
  for l in o.splitLines:
    let t = l.strip
    if "gh auth login" in t: return "gh is not signed in: run gh auth login (in the terminal)"
  for l in o.splitLines:
    let t = l.strip
    if t.len > 0: return t
  "gh stopped (" & $code & ")"

# the date part (the first ten characters, yyyy-mm-dd) of a timestamp gh gives
func when10(s: string): string = (if s.len >= 10: s[0 ..< 10] else: s)

proc page*(j: JsonNode, isPr: bool): string =
  ## a pull request or an issue as Markdown: its title, what it is, its text, its reviews and comments
  let n = j{"number"}.getInt
  result = "# " & j{"title"}.getStr & " (#" & $n & ")\n\n"
  var facts = @["**" & j{"state"}.getStr.toLowerAscii & "**", "by @" & j{"author"}{"login"}.getStr]
  if isPr:
    facts.add "`" & j{"headRefName"}.getStr & "` → `" & j{"baseRefName"}.getStr & "`"
    if j.hasKey("additions"):
      facts.add "+" & $j{"additions"}.getInt & " −" & $j{"deletions"}.getInt & " in " & $j{"changedFiles"}.getInt &
                " files"
  var labels: seq[string]
  for l in jsonItems(j{"labels"}): labels.add l{"name"}.getStr
  if labels.len > 0: facts.add "labels: " & labels.join(", ")
  result.add facts.join(" · ") & "\n\n" & j{"url"}.getStr & "\n\n---\n\n"
  let body = j{"body"}.getStr.strip
  result.add (if body.len > 0: body else: "*(no description)*") & "\n"
  var notes: seq[(string, string)]           # (when, the note)
  for r in jsonItems(j{"reviews"}):
    let st = r{"state"}.getStr.toLowerAscii.replace("_", " ")
    notes.add (r{"submittedAt"}.getStr, "### @" & r{"author"}{"login"}.getStr & " — review: " & st & " (" &
               when10(r{"submittedAt"}.getStr) & ")\n\n" & r{"body"}.getStr.strip)
  for c in jsonItems(j{"comments"}):
    notes.add (c{"createdAt"}.getStr, "### @" & c{"author"}{"login"}.getStr & " (" & when10(c{"createdAt"}.getStr) &
               ")\n\n" & c{"body"}.getStr.strip)
  if notes.len > 0:
    # (in the order they were written)
    for i in 1 ..< notes.len:
      var k = i
      while k > 0 and notes[k - 1][0] > notes[k][0]:
        swap(notes[k - 1], notes[k])
        dec k
    result.add "\n---\n\n## " & $notes.len & " comment" & (if notes.len == 1: "" else: "s") & "\n"
    for (_, t) in notes: result.add "\n" & t.strip & "\n"

# ── running gh ──

proc gh(args: string, what: string, then: proc(o: string)) =
  ## gh in the background, in the project's folder: `then` gets what it printed — else what went wrong is said
  status("⧗ " & what)
  shellAsync("gh " & args & " 2>&1") do (o: string, code: int):
    status("")
    if code == 0 or (code == 8 and "checks" in args): then(o)     # (gh pr checks: 8 while some are running)
    else: warn("GitHub: " & what & " — " & ghWhy(o, code))

proc noGh(): bool =
  ## true, with a message saying how to install it, when the gh program is not on PATH
  if findExe("gh").len > 0: return false
  message("GitHub: gh is not installed (Termux: pkg install gh — then gh auth login)")
  true

proc bodyFile(text: string): string =
  ## a text gh reads with --body-file (in the plugin's own folder)
  writeData("body.md", text)
  dataDir() / "body.md"

# ── what the dock shows: read in the background ──

var
  prs, issues: seq[Item]
  problem = ""
  state = 0                    # 0 not read · 1 being read · 2 read

const
  PrFields = "number,title,author,headRefName,isDraft,updatedAt,url"
  IssueFields = "number,title,author,labels,updatedAt,url"
  Mark = "\x1e issues"

proc readAll() =
  ## reads the open pull requests and issues in the background (one shell command, the two JSON lists split at a marker
  ## line), keeps them for the dock and redraws it; does nothing while a read is going; without gh makes the dock say so
  if state == 1: return
  if findExe("gh").len == 0:
    problem = "gh is not installed (pkg install gh)"
    state = 2
    refreshView(View)
    return
  state = 1
  let n = $setting("limit", 30)
  shellAsync("gh pr list --limit " & n & " --json " & PrFields & " 2>&1; echo '" & Mark & "'; gh issue list --limit " &
             n & " --json " & IssueFields & " 2>&1") do (o: string, code: int):
    let k = o.find(Mark)
    let a = if k >= 0: o[0 ..< k] else: o
    let b = if k >= 0: o[k + Mark.len .. ^1] else: ""
    problem = ""
    try:
      prs = itemsOf(a, true)
      issues = itemsOf(b, false)
    except CatchableError:
      prs.setLen(0)
      issues.setLen(0)
      problem = ghWhy(a & "\n" & b, 1)
    state = 2
    refreshView(View)

proc again() =
  ## forgets what was read and reads the pull requests and issues again
  state = 0
  readAll()

# ── what to do with one ──

proc readIt(it: Item) =
  ## opens the pull request or issue as a Markdown page in a tab (its description, reviews and comments), read with gh
  ## view in the background
  let kind = if it.isPr: "pr" else: "issue"
  let fields = if it.isPr: "number,title,body,author,state,headRefName,baseRefName,url,comments,reviews,labels," &
                           "additions,deletions,changedFiles"
               else: "number,title,body,author,state,url,comments,labels"
  gh(kind & " view " & $it.number & " --json " & fields, "reading #" & $it.number) do (o: string):
    try: discard newTab("#" & $it.number & " " & it.title, page(parseJson(o), it.isPr), "markdown")
    except CatchableError: warn("GitHub: gh's answer could not be read: " & o.strip.splitLines[0])

proc comment(it: Item) =
  ## asks for a line of text and adds it as a comment on the pull request or issue with gh (the text passed in a file in
  ## the data folder, so quotes and line ends are safe)
  let kind = if it.isPr: "pr" else: "issue"
  let text = ask("Comment on #" & $it.number & " (one line; a longer one in the browser):")
  if text.strip.len == 0: return
  gh(kind & " comment " & $it.number & " --body-file " & quoteShell(bodyFile(text)), "commenting on #" &
     $it.number) do (o: string):
    toast("GitHub: commented on #" & $it.number)

proc prActions(it: Item) =
  ## a list of what can be done with the pull request — read it, its diff in a tab, check it out, its checks in a tab,
  ## comment on it, open it in the browser, merge it (in the terminal, after asking) — and does the one chosen
  let n = $it.number
  let i = pick("#" & n & " " & it.title & " — @" & it.author,
               ["Read it", "Its diff", "Check it out", "Its checks", "Comment on it…", "Open it in the browser",
                "Merge it (in the terminal)"],
               ["its description, reviews and comments", "in a tab", "gh pr checkout " & n & " → " & it.branch,
                "gh pr checks", "a line", it.url, "gh pr merge " & n])
  case i
  of 0: readIt(it)
  of 1:
    gh("pr diff " & n & " --color never", "the diff of #" & n) do (o: string):
      discard newTab("#" & n & ".diff", o, "diff")
  of 2:
    gh("pr checkout " & n, "checking out #" & n) do (o: string):
      toast("GitHub: on the branch of #" & n & " — " & it.branch)
  of 3:
    gh("pr checks " & n, "the checks of #" & n) do (o: string):
      discard newTab("#" & n & " checks", (if o.strip.len > 0: o else: "no checks"), "plaintext")
  of 4: comment(it)
  of 5:
    gh("pr view " & n & " --web", "opening #" & n) do (o: string):
      discard
  of 6:
    if confirm("Merge #" & n & " " & it.title & "? (gh asks how, in the terminal)"): runInTerminal("gh pr merge " & n)
  else: discard

proc issueActions(it: Item) =
  ## a list of what can be done with the issue — read it, comment on it, close it (after asking; the dock is read
  ## again), open it in the browser — and does the one chosen
  let n = $it.number
  let i = pick("#" & n & " " & it.title & " — @" & it.author,
               ["Read it", "Comment on it…", "Close it", "Open it in the browser"],
               ["its text and comments", "a line", "gh issue close " & n, it.url])
  case i
  of 0: readIt(it)
  of 1: comment(it)
  of 2:
    if confirm("Close the issue #" & n & " " & it.title & "?"):
      gh("issue close " & n, "closing #" & n) do (o: string):
        toast("GitHub: #" & n & " closed")
        again()
  of 3:
    gh("issue view " & n & " --web", "opening #" & n) do (o: string):
      discard
  else: discard

proc choose(isPr: bool) =
  ## reads the open pull requests (or issues) now with gh, lists them to pick from (with author, branch or labels) and
  ## opens the actions for the one picked; says so when gh fails or there are none
  if noGh(): return
  let kind = if isPr: "pr" else: "issue"
  let (o, code) = shell("gh " & kind & " list --limit " & $setting("limit", 30) & " --json " &
                        (if isPr: PrFields else: IssueFields) & " 2>&1")
  if code != 0:
    warn("GitHub: " & ghWhy(o, code))
    return
  var its: seq[Item]
  try: its = itemsOf(o, isPr)
  except CatchableError:
    warn("GitHub: " & ghWhy(o, 1))
    return
  if isPr: prs = its else: issues = its
  if its.len == 0:
    message("GitHub: no open " & (if isPr: "pull requests" else: "issues"))
    return
  var items, dets: seq[string]
  for it in its:
    items.add "#" & $it.number & " " & it.title
    dets.add "@" & it.author & (if isPr: " · " & it.branch & (if it.draft: " · draft" else: "")
                                else: (if it.labels.len > 0: " · " & it.labels.join(", ") else: ""))
  let i = pick((if isPr: "Pull requests" else: "Issues") & " (" & $its.len & ")", items, dets)
  if i >= 0:
    if isPr: prActions(its[i]) else: issueActions(its[i])

command "GitHub: pull requests…":
  choose(true)

command "GitHub: issues…":
  choose(false)

command "GitHub: new issue…":
  if not noGh():
    let title = ask("GitHub: the new issue's title:")
    if title.strip.len > 0:
      let body = ask("Its text (a line; more in the browser after):")
      gh("issue create --title " & quoteShell(title.strip) & " --body-file " & quoteShell(bodyFile(body)),
         "making the issue") do (o: string):
        let ls = o.strip.splitLines
        let url = if ls.len > 0: ls[^1] else: ""
        output("GitHub: " & url)
        message("GitHub: the issue is made — " & url)
        again()

command "GitHub: new pull request":
  if not noGh(): runInTerminal("gh pr create")

view(View) do () -> seq[ViewItem]:
  if state == 0: readAll()
  result.add ViewItem(text: "Read them again", icon: "↻", color: "accent", id: "refresh",
                      detail: (if state == 1: "reading…" else: ""))
  if problem.len > 0:
    result.add ViewItem(text: problem, icon: "!", color: "error")
    return
  if state == 2:
    result.add ViewItem(text: "Pull requests", icon: "▸", detail: $prs.len)
    for k, it in prs:
      result.add ViewItem(text: "#" & $it.number & " " & it.title, detail: "@" & it.author & " · " & it.branch,
                          icon: (if it.draft: "◌" else: "⇄"), color: (if it.draft: "hint" else: "accent"),
                          id: "p" & $k, depth: 1)
    result.add ViewItem(text: "Issues", icon: "▸", detail: $issues.len)
    for k, it in issues:
      result.add ViewItem(text: "#" & $it.number & " " & it.title, detail: "@" & it.author &
                          (if it.labels.len > 0: " · " & it.labels.join(", ") else: ""), icon: "○", id: "i" & $k,
                          depth: 1)
do (id: string):
  if id == "refresh": again()
  elif id.len > 1:
    let k = try: parseInt(id[1 .. ^1]) except ValueError: -1
    if id[0] == 'p' and k in 0 ..< prs.len: prActions(prs[k])
    elif id[0] == 'i' and k in 0 ..< issues.len: issueActions(issues[k])
