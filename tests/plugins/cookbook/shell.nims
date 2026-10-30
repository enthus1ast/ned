## git-line — permissions and programs: who last changed the cursor's line (git blame, waited for) and a git
## fetch in the background (shellAsync), its result in a note
import nedplugin

requiresNed(">= 6.31")
# what it needs beyond editing, and why: ned reads this line before the plugin runs and asks you once
permission("shell", "runs git: who changed the line, and a fetch in the background")

proc gitAllowed(): bool =
  ## a kinder word than the error when you have not allowed it (yet)
  result = allowed("shell")
  if not result: warn("git-line may not run programs: Plugins dock › git-line › Allow…")

proc blame(b: Buf) =
  ## runs git blame for the cursor's line, waiting for it, and shows who last changed that line and why (the commit
  ## summary) in a message; says when the file is not saved or git fails
  if not gitAllowed(): return
  let p = b.path
  if p.len == 0:
    message("git-line: the file is not saved")
    return
  let n = $(b.cursor.line + 1)
  # shell waits for the command — and so do the plugins in the same process: keep it to quick ones
  let (o, code) = shell("git blame --porcelain -L " & n & "," & n & " -- " & quoteShell(extractFilename(p)),
                        parentDir(p))
  if code != 0:
    warn("git blame: " & o.splitLines()[0])
    return
  var author, summary = ""
  for l in o.splitLines:
    if l.startsWith("author "): author = l[7 .. ^1]
    elif l.startsWith("summary "): summary = l[8 .. ^1]
  message("Line " & n & ": " & author & " — " & summary & (if b.dirty: " (as saved)" else: ""))

proc fetch() =
  ## starts a git fetch in the background, with a note in the status bar while it runs, and reports in a toast or a
  ## warning when it is done
  if not gitAllowed(): return
  status("⟳ git fetch")
  # shellAsync: the plugin goes on; the callback runs when git is done
  shellAsync("git fetch --quiet") do (output: string, code: int):
    status("")
    if code == 0: toast("git fetch: done")
    else: warn("git fetch: " & output.splitLines()[0])

command "Git: who changed this line", "ctrl+alt+g":
  blame(current())

command "Git: fetch in the background":
  fetch()
