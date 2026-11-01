## todo-to-issue — a TODO or FIXME comment made a GitHub issue, and the issue's number written back into the comment
##
##   TODO: make it an issue     the TODO, FIXME, HACK, BUG or XXX comment on the cursor's line: asked first, then an
##                              issue with the comment's text as its title and, as its text, where it is (the file
##                              and line, a link to it on GitHub) and the lines around it; the comment then says
##                              which issue it is: # TODO(#42): …
##   TODO: open its issue       the issue a TODO(#42) comment names, in your browser
##   settings                   plugins.todo-to-issue.labels ("": none; "todo,tech-debt" for labels)
##
## Needs GitHub's gh, signed in (`gh auth login`), in a folder of a GitHub repository (Termux: `pkg install gh`). A
## comment that already names an issue is not made one again.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "makes the issue with gh issue create, and opens it with gh issue view --web")
permission("network", "gh talks to GitHub")

settingDef("labels", "", "TODO to issue: labels for the new issues, with commas between (empty: none)")

const Words = ["TODO", "FIXME", "HACK", "BUG", "XXX"]

func findTodo*(line: string): (int, int, string) =
  ## the TODO word on the line — where it starts, where its text starts — and the text ((-1, -1, "") when there is
  ## none). After the word: an optional (who) and a : or a space
  for w in Words:
    var k = line.find(w)
    while k >= 0:
      let before = if k > 0: line[k - 1] else: ' '
      let afterI = k + w.len
      let after = if afterI < line.len: line[afterI] else: ' '
      if before notin {'a'..'z', 'A'..'Z', '0'..'9', '_'} and after notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
        var i = afterI
        if i < line.len and line[i] == '(':
          let e = line.find(')', i)
          if e > 0: i = e + 1
        while i < line.len and line[i] in {':', ' ', '-'}: inc i
        var text = line[i .. ^1].strip
        for closer in ["*/", "-->", "#]"]:
          if text.endsWith(closer): text = text[0 ..< text.len - closer.len].strip
        return (k, i, text)
      k = line.find(w, k + 1)
  (-1, -1, "")

func issueNumber*(line: string): int =
  ## the issue a TODO(#42) names, -1 for none
  let k = line.find("(#")
  if k < 0: return -1
  var i = k + 2
  var n = 0
  var any = false
  while i < line.len and line[i] in {'0'..'9'}:
    n = n * 10 + ord(line[i]) - ord('0')
    any = true
    inc i
  if any and i < line.len and line[i] == ')': n else: -1

proc makeIssue() =
  ## the TODO on the cursor's line made an issue, then its number written into the comment
  let b = current()
  let ln = b.cursor.line
  let line = b.line(ln)
  let (k, _, text) = findTodo(line)
  if k < 0:
    message("TODO to issue: no TODO, FIXME, HACK, BUG or XXX comment on this line")
    return
  if issueNumber(line) >= 0:
    message("TODO to issue: this one is issue #" & $issueNumber(line) & " already (TODO: open its issue)")
    return
  if text.len == 0:
    message("TODO to issue: the comment says nothing to make a title of")
    return
  let title = if text.len > 120: text[0 ..< 119] & "…" else: text
  if not confirm("Make a GitHub issue of “" & title & "”?"): return
  let root = projectRoot()
  let rel = if b.path.startsWith(root & "/"): b.path[root.len + 1 .. ^1] else: extractFilename(b.path)
  let around = b.lines(max(0, ln - 3), ln + 3)
  let fence = if b.lang.len > 0 and b.lang != "plaintext": b.lang else: ""
  var we = k
  while we < line.len and line[we] in {'A'..'Z'}: inc we
  var body = "From a " & line[k ..< we] & " comment in `" & rel & "`, line " & $(ln + 1) & ":\n\n```" & fence & "\n"
  for l in around: body.add l & "\n"
  body.add "```\n"
  let (url, _) = shell("gh browse --no-browser " & quoteShell(rel & ":" & $(ln + 1)) & " 2>/dev/null")
  if url.startsWith("https://"): body.add "\n" & url.strip & "\n"
  writeData("body.md", body)
  var cmd = "gh issue create --title " & quoteShell(title) & " --body-file " & quoteShell(dataDir() / "body.md")
  for lb in setting("labels", "").split(','):
    if lb.strip.len > 0: cmd.add " --label " & quoteShell(lb.strip)
  message("TODO to issue: making it…")
  let id = b.id
  shellAsync(cmd) do (output: string, code: int):
    let x = Buf(id: id)
    var n = -1
    for w in output.splitWhitespace:
      let p = w.rfind("/issues/")
      if w.startsWith("https://") and p > 0:
        try: n = parseInt(w[p + "/issues/".len .. ^1].strip(chars = {'/', '.'}))
        except ValueError: discard
    if code != 0 or n < 0:
      let why = if output.strip.len > 0: output.strip.splitLines[^1] else: "gh ended with " & $code
      warn("TODO to issue: " & (if "not found" in why.toLowerAscii and "gh" in why: "GitHub's gh is not installed" else: why))
      return
    # (the number into the comment, when the line is still what it was)
    let now = x.line(ln)
    let (k2, _, _) = findTodo(now)
    if now == line and k2 >= 0:
      var e = k2
      while e < now.len and now[e] in {'A'..'Z'}: inc e
      if e < now.len and now[e] == '(':
        let close = now.find(')', e)
        if close > e: e = close + 1
      x.replace(rng(pos(ln, k2), pos(ln, e)), now[k2 ..< e].split('(')[0] & "(#" & $n & ")")
      message("TODO to issue: issue #" & $n & " made — the comment says so")
    else:
      message("TODO to issue: issue #" & $n & " made (the line changed meanwhile: written nowhere)")

command "TODO: make it an issue":
  makeIssue()

command "TODO: open its issue":
  let n = issueNumber(current().line(current().cursor.line))
  if n < 0: message("TODO to issue: no TODO(#…) on this line")
  else:
    shellAsync("gh issue view " & $n & " --web") do (output: string, code: int):
      if code != 0: warn("TODO to issue: " & output.strip)
    message("TODO to issue: opening issue #" & $n)
