# ── checks before a commit (git.checksBeforeCommit): the files to be committed are formatted (ned's own
#    formatters, on what is staged), and the tests that cover them pass. One that does not stops the commit and
#    says why — with a way to fix it and a way to commit anyway ──

proc commitFiles(root: string, all: bool): seq[string] =
  ## what the commit takes: the staged files, or (commit -a) every changed tracked file — that still exist
  let (ok, o, _) = runFilter((if all: "git diff --name-only HEAD" else: "git diff --cached --name-only --diff-filter=ACMR") &
                             " 2>/dev/null", "", root, 5000)
  if not ok: return
  for l in o.splitLines:
    let p = l.strip
    if p.len > 0 and fileExists(root / p): result.add root / p

proc stagedText(root, path: string, all: bool): (bool, string) =
  ## the file as the commit takes it: what is staged (or, commit -a, the file itself)
  if all:
    try: return (true, readFile(path))
    except CatchableError: return (false, "")
  let rel = relativePath(path, root)
  let (ok, o, _) = runFilter("git show " & quoteShell(":" & rel) & " 2>/dev/null", "", root, 5000)
  (ok, o)

proc unformattedFiles(root: string, files: seq[string], all: bool): seq[(string, string, bool)] =
  ## (file, its formatted text, only staged = the worktree has the same text) for those ned's own formatter would change
  for f in files:
    let lang = detectLang(f, "")
    # (only the languages you have formatted on save: a file in another style is not called wrong)
    if not cfgFormatOnSave or lang == nil: continue
    if cfgFormatOnSaveLangs.len > 0 and lang.id.toLowerAscii notin cfgFormatOnSaveLangs and
       lang.name.toLowerAscii notin cfgFormatOnSaveLangs: continue
    let kind = builtinFmtKind(f, (if lang != nil: lang.id else: ""))
    if kind.len == 0 or (kind == "nim" and (cfgNimFormatter != "builtin" or "nim" in cfgUserFmt)): continue
    if kind == "c" and haveExe("clang-format"): continue          # (clang-format is the one in use for C)
    let (ok, text) = stagedText(root, f, all)
    if not ok or text.len == 0 or text.len > 2_000_000: continue
    let (res, err) = builtinFormatText(kind, text, 2, f)
    if err.len > 0 or res == text: continue
    var same = all
    if not all:
      try: same = readFile(f) == text
      except CatchableError: same = false
    let bi = bufIndexByPath(f)
    if bi >= 0 and bufs[bi].dirty: same = false          # (unsaved edits in ned: not written over)
    result.add (f, res, same)

proc precommitTests(files: seq[string], then: proc(failed: seq[(string, seq[string])], skipped: int)) =
  ## the test files that cover the files, run one after another; then(the ones that failed, how many could not run)
  var tests: seq[string]
  for f in files:
    if not f.endsWith(".nim"): continue
    var lines: seq[string]
    try:
      let bi = bufIndexByPath(f)
      lines = if bi >= 0: bufs[bi].lines else: readFile(f).splitLines
    except CatchableError: continue
    for t in testsOfFile(f, lines, related = true, most = 5):
      if t notin tests: tests.add t
  if tests.len == 0:
    then(@[], 0)
    return
  info("Before the commit: running " & $tests.len & " test file" & (if tests.len == 1: "" else: "s") & "…")
  var failed: seq[(string, seq[string])]
  var skipped = 0
  var i = 0
  proc next() =
    if i >= tests.len:
      then(failed, skipped)
      return
    let t = tests[i]
    inc i
    runTestOnSave(t, proc(state: int, names: seq[string], passed: int) =
      case state
      of 1: failed.add (t, names)
      of 2: failed.add (t, @["(it did not compile, or took too long)"])
      of 3: inc skipped
      else: discard
      next())
  next()

proc precommitChecks(root: string, all: bool, commit: proc()) =
  ## the checks, then `commit` — or what failed, and the choice
  if cfgCommitChecks == "off" or root.len == 0:
    commit()
    return
  let files = commitFiles(root, all)
  if files.len == 0:
    commit()
    return
  proc testsThen() =
    if cfgCommitChecks notin ["both", "tests"]:
      commit()
      return
    precommitTests(files, proc(failed: seq[(string, seq[string])], skipped: int) =
      if failed.len == 0:
        if skipped > 0: info("Tests not run before the commit: the folder is not trusted, or nim is missing")
        commit()
        return
      var what = ""
      for (t, ns) in failed:
        if what.len > 0: what.add "; "
        what.add extractFilename(t) & ": " & ns[0 ..< min(3, ns.len)].join(", ") & (if ns.len > 3: " …" else: "")
      let first = failed[0][0]
      askConfirm("Tests fail: " & what & " — not committed. (o)pen the test, (c)ommit anyway, (x) cancel",
                 proc(c: char) =
        if c == 'c': commit()
        elif c == 'o': discard openFile(first)))
  if cfgCommitChecks notin ["both", "format"]:
    testsThen()
    return
  let bad = unformattedFiles(root, files, all)
  if bad.len == 0:
    testsThen()
    return
  var names: seq[string]
  var fixable = true
  for (f, _, same) in bad:
    names.add relativePath(f, root)
    if not same: fixable = false
  let list = names[0 ..< min(4, names.len)].join(", ") & (if names.len > 4: " …" else: "")
  askConfirm("Not formatted: " & list & " — " &
             (if fixable: "(f)ormat and stage them, " else: "(they have unstaged changes too: format them yourself) ") &
             "(c)ommit anyway, (x) cancel", proc(c: char) =
    if c == 'c': testsThen()
    elif c == 'f' and fixable:
      var paths: seq[string]
      for (f, res, _) in bad:
        let bi = bufIndexByPath(f)
        try:
          if bi >= 0:
            bufs[bi].setTextMinimal(res)
            discard bufs[bi].saveBuffer()
          else: writeFileSafe(f, res)
          paths.add relativePath(f, root)
        except CatchableError as e:
          error("Format " & extractFilename(f) & ": " & e.msg)
          return
      var cmd = "git add --"
      for p in paths: cmd.add " " & quoteShell(p)
      discard startJob(jkGit, cmd, root, proc(j: Job) =
        if j.code != 0:
          error("git add: " & j.output.strip)
          return
        info("Formatted and staged " & $paths.len & " file" & (if paths.len == 1: "" else: "s"))
        testsThen()))
