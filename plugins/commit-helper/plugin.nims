## commit-helper — a commit message drafted from what is staged: the kind of change, where, what — to read, fix and
## commit
##
##   Git: draft a commit message      from `git diff --cached`: a first line — `docs: …`, `test(engine): …`,
##                                    `feat(ui): add outline.nim`, `fix(core): screen.nim` (the kind guessed from
##                                    the files: docs, tests, CI, build files, new files, changed ones; the scope
##                                    their common folder) — and a line for each file with its + and - counts,
##                                    in a tab. Nothing staged: it asks to stage everything first
##   Git: commit with this message    the tab's text (its # lines left out) as the message: git commit -F
##   plugins.commit-helper.style      "conventional" (type(scope): summary) or "plain" (a summary only)
import nedplugin
import std/[strutils, algorithm]

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "reads the staged changes (git diff --cached) and commits them (git commit -F)")

settingDef("style", "conventional", "Git: draft a commit message — conventional (type(scope): summary) or plain")

const DraftTitle = "COMMIT message"

type Change* = object
  status*: char            # A added · M modified · D deleted · R renamed
  path*: string
  added*, removed*: int

# s as one word for a shell command line, in single quotes (a quote inside it written '\'')
func q(s: string): string = "'" & s.replace("'", "'\\''") & "'"

func parseStaged*(nameStatus, numstat: string): seq[Change] =
  ## `git diff --cached --name-status` and `--numstat`, as changes
  for l in nameStatus.splitLines:
    let f = l.split('\t')
    if f.len < 2 or f[0].len == 0: continue
    result.add Change(status: f[0][0], path: f[^1])
  for l in numstat.splitLines:
    let f = l.split('\t')
    if f.len < 3: continue
    for c in result.mitems:
      if c.path == f[^1] or f[^1].endsWith("=> " & c.path & "}") or f[^1].endsWith(c.path):
        c.added = (try: parseInt(f[0]) except ValueError: 0)
        c.removed = (try: parseInt(f[1]) except ValueError: 0)
        break

# the file name at the end of a path
func base(p: string): string = p.split('/')[^1]

func kindOf*(cs: seq[Change]): string =
  ## the kind of the change: docs, test, ci, build, feat (mostly new files), refactor (renames), fix
  var docs, tests, ci, build, added, renamed = 0
  for c in cs:
    let p = c.path.toLowerAscii
    if p.endsWith(".md") or p.startsWith("docs/") or p.endsWith(".rst") or p.endsWith(".txt"): inc docs
    elif p.startsWith("tests/") or p.startsWith("test/") or "/tests/" in p or "/test/" in p or
         base(p).startsWith("test_") or base(p).contains("_test."): inc tests
    elif p.startsWith(".github/") or p.startsWith(".gitlab") or p.endsWith(".yml") and "ci" in p: inc ci
    elif base(p) in ["makefile", "cmakelists.txt", "package.json", "cargo.toml", "go.mod", "build.zig"] or
         p.endsWith(".nimble") or p.endsWith(".nims") or base(p) == "nim.cfg": inc build
    if c.status == 'A': inc added
    if c.status == 'R': inc renamed
  let n = cs.len
  if n == 0: return "chore"
  if docs == n: "docs"
  elif tests == n: "test"
  elif ci == n: "ci"
  elif build == n: "build"
  elif renamed == n: "refactor"
  elif added * 2 >= n: "feat"
  else: "fix"

func scopeOf*(cs: seq[Change]): string =
  ## the folder the files share, by its last name (src/ned/ui/x.nim, src/ned/ui/y.nim → ui) — "" when none
  if cs.len == 0: return
  var common = cs[0].path.split('/')[0 ..< ^1]
  for c in cs[1 .. ^1]:
    let d = c.path.split('/')[0 ..< ^1]
    var k = 0
    while k < common.len and k < d.len and common[k] == d[k]: inc k
    common.setLen(k)
  if common.len == 0: return
  let s = common[^1]
  if s in ["src", "lib", "source", "app"]: "" else: s

func summaryOf*(cs: seq[Change]): string =
  ## what changed, short: "add outline.nim", "remove old.nim", "screen.nim and theme.nim", "12 files"
  var add, del, other: seq[string]
  for c in cs:
    case c.status
    of 'A': add.add base(c.path)
    of 'D': del.add base(c.path)
    else: other.add base(c.path)
  func names(xs: seq[string]): string =
    ## the names written in words: one, "a and b", "a, b and c" — and from four on only how many files there are
    if xs.len == 1: xs[0]
    elif xs.len == 2: xs[0] & " and " & xs[1]
    elif xs.len <= 3: xs[0 ..< ^1].join(", ") & " and " & xs[^1]
    else: $xs.len & " files"
  var parts: seq[string]
  if add.len > 0: parts.add "add " & names(add)
  if del.len > 0: parts.add "remove " & names(del)
  if other.len > 0: parts.add (if parts.len > 0: "change " else: "") & names(other)
  parts.join("; ")

proc draft*(cs: seq[Change], style: string): string =
  ## the message text for the changes: a first line (the summary, with the kind and scope in front unless the style is
  ## plain), a line for each file — the most changed first — with its + and - counts and whether it is new, deleted or
  ## renamed, then # lines saying how the text is used
  var head = summaryOf(cs)
  if style != "plain":
    let s = scopeOf(cs)
    head = kindOf(cs) & (if s.len > 0: "(" & s & ")" else: "") & ": " & head
  var body: seq[string]
  var sorted = cs
  sorted.sort(proc(a, b: Change): int = cmp(b.added + b.removed, a.added + a.removed))
  for c in sorted:
    let what = case c.status
               of 'A': "new"
               of 'D': "deleted"
               of 'R': "renamed"
               else: ""
    body.add "- " & c.path & " (+" & $c.added & " -" & $c.removed & (if what.len > 0: ", " & what else: "") & ")"
  head & "\n\n" & body.join("\n") & "\n\n" &
    "# The first line is the summary (under 72 characters); the lines starting with # are left out.\n" &
    "# Git: commit with this message — commits what is staged.\n"

proc staged(): seq[Change] =
  ## the staged changes, from git diff --cached (names with their status, and the line counts, renames followed); raises
  ## ValueError with git's message when git fails
  let a = shell("git diff --cached --name-status -M")
  let b = shell("git diff --cached --numstat -M")
  if a.code != 0: raise newException(ValueError, a.output.strip)
  parseStaged(a.output, b.output)

proc draftNow() =
  ## Git: draft a commit message — reads what is staged (asking to stage everything with git add -A when nothing is) and
  ## opens the drafted message in a tab, the cursor at the end of its first line
  var cs: seq[Change]
  try: cs = staged()
  except ValueError as e:
    warn("git: " & e.msg)
    return
  if cs.len == 0:
    if not confirm("Nothing is staged — stage every change (git add -A)?"): return
    discard shell("git add -A")
    try: cs = staged()
    except ValueError: discard
    if cs.len == 0:
      message("Nothing to commit")
      return
  let text = draft(cs, setting("style", "conventional"))
  let t = newTab(DraftTitle, text, "markdown")
  t.markSaved()
  t.setCursor(pos(0, text.find('\n')))

proc commitNow() =
  ## Git: commit with this message — takes the text of the current tab without its # lines, writes it into the data
  ## folder and runs git commit -F on it; shows git's first line, and closes the tab if it is the draft
  let b = current()
  var msg: seq[string]
  for l in b.lines:
    if not l.startsWith("#"): msg.add l
  let text = msg.join("\n").strip
  if text.len == 0:
    message("The message is empty")
    return
  writeData("COMMIT_MSG", text & "\n")
  let r = shell("git commit -F " & q(dataDir() & "/COMMIT_MSG"))
  if r.code != 0:
    warn("git commit: " & r.output.strip.splitLines[^1])
    return
  message(r.output.strip.splitLines[0])
  if b.title == DraftTitle:
    b.markSaved()
    b.closeTab()

command "Git: draft a commit message":
  draftNow()

command "Git: commit with this message":
  commitNow()
