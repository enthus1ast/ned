## project-tasks — progress, the Output panel and the terminal: the project's TODO and FIXME lines in the Output
## panel (a click goes to one), with progress in the status bar; and your test command in ned's terminal
import nedplugin

requiresNed(">= 6.31")
permission("shell", "lists the project's files with git and grep, and runs your test command in the terminal")

settingDef("testCommand", "nimble test", "Project tasks: the command 'Project: run the tests' runs in the terminal")

proc projectFiles(): seq[string] =
  ## the project's files: git's list in a repository, else find's (no hidden folders)
  let (o, _) = shell("(git ls-files 2>/dev/null || find . -type f -not -path '*/.*') | head -5000")
  for f in o.splitLines:
    if f.len > 0: result.add (if f.startsWith("./"): f[2 .. ^1] else: f)

proc listTodos() =
  ## greps the project's files for TODO and FIXME, fifty files at a time with the progress shown after each, and lists
  ## the lines (file:line:text) in the Output panel, where a click goes to the line; says how many it found
  let files = projectFiles()
  var found: seq[string]
  var i = 0
  while i < files.len:                        # grep, 50 files at a time — the progress after each
    progress("TODOs: " & files[i], i * 100 div files.len)
    var cmd = "grep -nIH -E 'TODO|FIXME' --"
    for f in files[i ..< min(i + 50, files.len)]: cmd.add " " & quoteShell(f)
    let (o, _) = shell(cmd & " 2>/dev/null")
    for l in o.splitLines:
      if l.len > 0: found.add l               # file:line:text — ned makes file:line a link
    i += 50
  progressDone()
  if found.len > 0:
    output(found.join("\n"))                  # (one request for all the lines)
    showOutput()
  message($found.len & " TODO and FIXME lines in " & $files.len & " files")

command "Project: list the TODOs":
  listTodos()

command "Project: run the tests", "f6":
  # in ned's terminal, in the project's folder: you see it run and can stop it (Ctrl+C)
  runInTerminal(setting("testCommand", "nimble test"))
