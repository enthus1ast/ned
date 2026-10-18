# ── ned --lint (and nedls --lint): the engine's own checks over files or folders, without the compiler — a
#    misspelled name, a field that is not there, a wrong number of arguments, a value neither used nor discarded,
#    an unused import or local, code that never runs, a var that can be a let, an unused parameter, a result never
#    set, a deprecated name, a library name newer than the package's Nim. Plain lines, GitHub annotations or JSON;
#    a git pre-commit hook that lints what is staged ──

const LintHookMark = "# ned --lint pre-commit hook"

proc lintUsage(prog: string): string =
  prog & " — the Nim engine's checks over files and folders (no compiler run, no build)\n\n" &
  "Usage: " & prog & " [options] [FILE|FOLDER…]      (default: this folder)\n\n" &
  "  --format:text|github|json  plain lines (path:line:col: warning: …), GitHub annotations (::warning file=…)\n" &
  "                        or a JSON array — github by itself under GitHub Actions\n" &
  "  --severity:error|warning|hint  what is shown: that and worse (default: warning)\n" &
  "  --fail-on:error|warning|hint|never  the exit status is 1 when something that bad is found (default: warning)\n" &
  "  --staged              only the Nim files staged in git, as staged (what a commit would take)\n" &
  "  --no-config           do not ask `nim dump` for the project's paths (it reads config.nims: code of the project)\n" &
  "  --install-hook        a git pre-commit hook that runs " & prog & " --staged (--force replaces your own)\n" &
  "  -q, --quiet           no summary line\n" &
  "  -h, --help            this text\n\n" &
  "Settings that apply: nim.engineChecks, nim.engineHints, nim.minVersion (yours and the project's .ned/settings.json).\n" &
  "Exit status: 0 nothing at --fail-on, 1 found, 2 a usage error.\n"

proc lintSevName(s: int): string =
  case s
  of 1: "error"
  of 2: "warning"
  of 3: "info"
  else: "hint"

proc lintSevOf(name: string): int =
  case name.toLowerAscii
  of "error", "errors": 1
  of "warning", "warnings", "warn": 2
  of "info": 3
  of "hint", "hints", "all": 4
  of "never", "none", "off": 0
  else: -1

proc lintGhEscape(s: string, prop = false): string =
  ## GitHub workflow command escaping (%, CR, LF; in properties also : and ,)
  result = s.multiReplace(("%", "%25"), ("\r", "%0D"), ("\n", "%0A"))
  if prop: result = result.multiReplace((":", "%3A"), (",", "%2C"))

proc lintInstallHook(prog, exe: string, force: bool): int =
  ## .git/hooks/pre-commit (or core.hooksPath's): the staged Nim files linted; beside nedfmt's hook when it is there
  var root = ""
  let (rok, ro, _) = runFilter("git rev-parse --show-toplevel", "", getCurrentDir(), 10000)
  if rok: root = ro.strip
  if root.len == 0:
    stderr.writeLine prog & ": not in a git repository"
    return 2
  var hooks = ""
  let (hok, ho, _) = runFilter("git rev-parse --git-path hooks", "", getCurrentDir(), 10000)
  if hok and ho.strip.len > 0:
    hooks = ho.strip
    if not hooks.isAbsolute: hooks = getCurrentDir() / hooks
  if hooks.len == 0: hooks = root / ".git" / "hooks"
  let hook = hooks / "pre-commit"
  let block0 = LintHookMark & " (installed by " & prog & " --install-hook). Commit anyway: git commit --no-verify\n" &
    "NED=" & quoteShell(exe) & "\n" &
    "[ -x \"$NED\" ] || NED=$(command -v ned) || NED=\"\"\n" &
    "if [ -n \"$NED\" ]; then \"$NED\" --lint --staged || exit 1; else echo \"ned is not installed: the lint is skipped\" >&2; fi\n"
  var script = ""
  if fileExists(hook):
    let old = readFile(hook)
    if LintHookMark in old:
      echo "The lint is in " & hook & " already"
      return 0
    if "nedfmt --install-hook wrote this" in old or force:
      # (nedfmt's hook ends in `exit $fail`: the lint goes before it)
      if force and "nedfmt --install-hook wrote this" notin old: script = "#!/bin/sh\n" & block0
      else:
        let k = old.rfind("exit $fail")
        script = if k >= 0: old[0 ..< k] & block0 & old[k .. ^1] else: old & "\n" & block0
    else:
      stderr.writeLine prog & ": " & hook & " exists already (your own hook) — not changed. Add this line to it:\n" &
                       "  " & quoteShell(exe) & " --lint --staged || exit 1\n" &
                       "or run again with --force to replace it"
      return 2
  else: script = "#!/bin/sh\n" & block0
  try:
    createDir(hooks)
    writeFile(hook, script)
    setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
                              fpOthersExec})
  except CatchableError as e:
    stderr.writeLine prog & ": cannot write " & hook & ": " & e.msg
    return 2
  echo "Installed in " & hook & " — a commit now needs its staged Nim files to pass the lint (git commit --no-verify skips it)"
  0

proc lintMain(args: seq[string], prog = "ned --lint"): int =
  var inputs: seq[string]
  var format = if getEnv("GITHUB_ACTIONS") == "true": "github" else: "text"
  var showSev = 2
  var failSev = 2
  var staged, noConfig, quiet, installHook, force = false
  for a in args:
    let (name, val) = block:
      let k = a.find({':', '='})
      if a.startsWith("--") and k > 2: (a[2 ..< k], a[k + 1 .. ^1]) else: (a.strip(chars = {'-'}), "")
    if not a.startsWith("-") or a == "-":
      inputs.add a
      continue
    case name
    of "h", "help":
      stdout.write lintUsage(prog)
      return 0
    of "format", "f":
      if val notin ["text", "github", "json"]:
        stderr.writeLine prog & ": --format is text, github or json"
        return 2
      format = val
    of "severity", "min":
      showSev = lintSevOf(val)
      if showSev <= 0:
        stderr.writeLine prog & ": --severity is error, warning or hint"
        return 2
    of "fail-on", "failon":
      failSev = lintSevOf(val)
      if failSev < 0:
        stderr.writeLine prog & ": --fail-on is error, warning, hint or never"
        return 2
    of "staged": staged = true
    of "no-config", "noconfig": noConfig = true
    of "q", "quiet": quiet = true
    of "install-hook": installHook = true
    of "force": force = true
    else:
      stderr.writeLine prog & ": unknown option " & a & " (" & prog & " --help)"
      return 2
  if installHook: return lintInstallHook(prog, getAppFilename(), force)
  # the editor's setup, without a screen: languages, settings (yours, the project's), the Nim library
  initLangs()
  rootDir = getCurrentDir()
  loadConfig()
  applyNimToolchain()
  nxInitDefines()
  nxLibFound = nxGuessLib()
  nxLibGuessed = true
  nxApplyToolchain()
  if nxLibFound.len == 0:
    stderr.writeLine prog & ": no Nim standard library found (is nim on PATH?) — the checks need it"
    return 2
  # the files: given, in the folders given (what git does not ignore), or staged
  var files: seq[(string, string)]            # (path, the text checked — "" read from disk)
  if staged:
    let (ok, o, _) = runFilter("git diff --cached --name-only -z --diff-filter=ACMR", "", rootDir, 20000)
    if not ok:
      stderr.writeLine prog & ": --staged needs a git repository"
      return 2
    var top = ""
    let (tok, t, _) = runFilter("git rev-parse --show-toplevel", "", rootDir, 10000)
    if tok: top = t.strip
    for f in o.split('\0'):
      if not f.endsWith(".nim"): continue
      let (sok, txt, _) = runFilter("git show " & quoteShell(":" & f), "", (if top.len > 0: top else: rootDir), 20000)
      if sok: files.add ((if top.len > 0: top / f else: absolutePath(f)), txt)
  else:
    if inputs.len == 0: inputs = @["."]
    for inp in inputs:
      if dirExists(inp):
        for p in fmtAllFiles(absolutePath(inp)):
          if p.endsWith(".nim"): files.add (p, "")
      elif fileExists(inp): files.add (absolutePath(inp), "")
      else:
        stderr.writeLine prog & ": " & inp & ": no such file or folder"
        return 2
  # the project's search paths and defines, from `nim dump` (once)
  if not noConfig and files.len > 0 and haveExe("nim"):
    let b0 = newBuffer()
    b0.path = files[0][0]
    let proj = nimProjectFile(b0)
    let (_, o, _) = runFilter("nim dump --hints:off --warnings:off --dump.format:json " & quoteShell(proj) &
                              " 2>/dev/null", "", parentDir(proj), 60000)
    nxDumpApply(proj, o)
    nxDumped.incl proj
  var found: seq[(string, Diag)]
  var counts, all: array[5, int]             # (shown; found at all — what --fail-on counts)
  for (path, given) in files:
    var text = given
    if text.len == 0:
      try: text = readFile(path)
      except CatchableError as e:
        stderr.writeLine path & ": " & e.msg
        continue
    let b = newBuffer()
    b.path = path
    b.lines = text.split('\n')
    if b.lines.len > 1 and b.lines[^1].len == 0: b.lines.setLen(b.lines.len - 1)
    for l in b.lines.mitems:
      if l.endsWith("\r"): l.setLen(l.len - 1)
    b.lang = detectLang(path, b.lines[0])
    if b.lang == nil or b.lang.mode != lmNim: continue
    var ds: seq[Diag]
    # a misspelled name (the compiler's words: undeclared identifier), then the engine's checks
    try:
      let f = nxFileFor(b)
      if f != nil:
        for (l, c, w, meant) in nxTypos(f, b.lines, 0, b.lines.high, (-1, -1)):
          ds.add Diag(line: l, col: c, eline: l, ecol: c + w.len, sev: 1, src: "ned",
                      msg: "undeclared identifier: '" & w & "' — did you mean '" & meant & "'?")
    except CatchableError, Defect: discard
    if cfgEngineChecks:
      try: ds.add engineChecksFor(b)
      except CatchableError, Defect: discard
    ds.sort(proc(x, y: Diag): int = cmp((x.line, x.col), (y.line, y.col)))
    for d in ds:
      let sev = clamp(d.sev, 1, 4)
      inc all[sev]
      if sev > showSev: continue
      inc counts[sev]
      found.add (path, d)
  let shown = proc(p: string): string =
    let r = relativePath(p, rootDir)
    if r.startsWith(".."): p else: r
  case format
  of "json":
    var arr = newJArray()
    for (p, d) in found:
      arr.add %*{"file": shown(p), "line": d.line + 1, "column": d.col + 1, "endLine": max(d.eline, d.line) + 1,
                 "endColumn": (if d.ecol > 0: d.ecol + 1 else: d.col + 1), "severity": lintSevName(clamp(d.sev, 1, 4)),
                 "message": d.msg.splitLines()[0], "source": "ned"}
    echo arr.pretty
  of "github":
    for (p, d) in found:
      let kind = case clamp(d.sev, 1, 4)
                 of 1: "error"
                 of 2: "warning"
                 else: "notice"
      echo "::" & kind & " file=" & lintGhEscape(shown(p), true) & ",line=" & $(d.line + 1) & ",col=" & $(d.col + 1) &
           (if d.ecol > d.col and d.eline == d.line: ",endColumn=" & $(d.ecol + 1) else: "") & ",title=ned::" &
           lintGhEscape(d.msg.splitLines()[0])
  else:
    for (p, d) in found:
      echo shown(p) & ":" & $(d.line + 1) & ":" & $(d.col + 1) & ": " & lintSevName(clamp(d.sev, 1, 4)) & ": " &
           d.msg.splitLines()[0] & " [ned]"
  if not quiet and format != "json":
    var parts: seq[string]
    for s in 1 .. 4:
      if counts[s] > 0: parts.add $counts[s] & " " & lintSevName(s) & (if counts[s] == 1: "" else: "s")
    stderr.writeLine prog & ": " & $files.len & " file" & (if files.len == 1: "" else: "s") & " checked" &
                     (if parts.len > 0: " — " & parts.join(", ") else: ", nothing found")
  if failSev > 0:
    for s in 1 .. failSev:
      if all[s] > 0: return 1
  0

proc cmdLintProject() =
  ## Nim › lint the project: ned --lint over the folder, in the output panel (each problem a link)
  if rootDir.len == 0:
    info("Open a project folder first")
    return
  runCommand(quoteShell(getAppFilename()) & " --lint --severity:hint --fail-on:never .", rootDir)
