# ── ned --lint (and nedls --lint): the engine's own checks over files or folders, without the compiler — a
#    misspelled name, a field that is not there, a wrong number of arguments, a value neither used nor discarded,
#    an unused import or local, code that never runs, a var that can be a let, an unused parameter, a result never
#    set, a deprecated name, a library name newer than the package's Nim. Plain lines, GitHub annotations or JSON;
#    a git pre-commit hook that lints what is staged ──

const LintHookMark = "# ned --lint pre-commit hook"
const LintFixRules = ["var-let", "deprecated", "unused-import", "can-be-func", "import-not-required", "nim3"]

proc lintUsage(prog: string): string =
  prog & " — the Nim engine's checks over files and folders (no compiler run, no build)\n\n" &
  "Usage: " & prog & " [options] [FILE|FOLDER…]      (default: this folder)\n\n" &
  "  --format:text|github|json|sarif  plain lines (path:line:col: warning: … [rule]), GitHub annotations\n" &
  "                        (::warning file=…; by itself under GitHub Actions), a JSON array, or SARIF 2.1.0 for\n" &
  "                        GitHub code scanning\n" &
  "  --severity:error|warning|info|hint  what is shown: that and worse (default: warning)\n" &
  "  --fail-on:error|warning|info|hint|never  exit status 1 when something that bad is found (default: warning)\n" &
  "  --fix[:RULE,…]        fix what has a safe fix, in place: " & LintFixRules.join(", ") & "\n" &
  "  --diff                with --fix: show the changes as a diff, write nothing\n" &
  "  --rules               the rules, their default severity and which --fix can fix\n" &
  "  --staged              only the Nim files staged in git, as staged (what a commit would take)\n" &
  "  --no-config           do not ask `nim dump` for the project's paths (it reads config.nims: code of the project)\n" &
  "  --install-hook        a git pre-commit hook that runs " & prog & " --staged (--force replaces your own)\n" &
  "  -q, --quiet           no summary line\n" &
  "  -h, --help            this text\n\n" &
  "Settings that apply: nim.engineChecks, nim.engineHints, nim.minVersion (yours and the project's .ned/settings.json).\n" &
  "Rules: .ned/lint.json — {\"rules\": {\"var-let\": \"off\", \"deprecated\": \"error\"}, \"exclude\": [\"generated/\"]};\n" &
  "a line: # ned: ignore  ·  # ned: ignore[var-let]  ·  # ned: ignore-next-line[…]  ·  # ned: ignore-file[…]\n" &
  "Exit status: 0 nothing at --fail-on, 1 found, 2 a usage error.\n"

func lintSevName(s: int): string =
  case s
  of 1: "error"
  of 2: "warning"
  of 3: "info"
  else: "hint"

func lintSevOf(name: string): int =
  case name.toLowerAscii
  of "error", "errors": 1
  of "warning", "warnings", "warn": 2
  of "info": 3
  of "hint", "hints", "all": 4
  of "never", "none", "off": 0
  else: -1

func lintGhEscape(s: string, prop = false): string =
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

proc lintChecks(b: Buffer): seq[Diag] =
  ## what ned --lint reports for one file: a misspelled name (the compiler's words), then the engine's checks —
  ## as .ned/lint.json and `# ned: ignore` comments want them
  try:
    let f = nxFileFor(b)
    if f != nil:
      for (l, c, w, meant) in nxTypos(f, b.lines, 0, b.lines.high, (-1, -1)):
        result.add Diag(line: l, col: c, eline: l, ecol: c + w.len, sev: 1, src: "ned", rule: "typo",
                        msg: "undeclared identifier: '" & w & "' — did you mean '" & meant & "'?")
  except CatchableError, Defect: discard
  if cfgEngineChecks:
    try: result.add engineChecksFor(b)
    except CatchableError, Defect: discard
  lintApply(b.path, b.lines, result)
  result.sort(proc(x, y: Diag): int = cmp((x.line, x.col), (y.line, y.col)))

proc lintFixOne(b: Buffer, d: Diag): bool =
  ## one problem fixed in the buffer, the way its quick fix does it; true when it was
  if d.line < 0 or d.line >= b.lines.len: return false
  let s = b.lines[d.line]
  case d.rule
  of "var-let":
    let t = s.strip(trailing = false)
    let ind = s.len - t.len
    let nm = quotedName(d.msg)
    let comma = t.find(',')
    if nm.len > 0 and t.startsWith("var ") and t[4 .. ^1].strip.startsWith(nm) and (comma < 0 or comma > t.find('=')):
      discard b.replaceText(Pos(line: d.line, col: ind), Pos(line: d.line, col: ind + 3), "let")
      return true
  of "deprecated":
    let (at, old, repl) = qDeprecated(b, d)
    if at >= 0:
      discard b.replaceText(Pos(line: d.line, col: at), Pos(line: d.line, col: at + old.len), repl)
      return true
  of "unused-import":
    let nm = quotedName(d.msg)
    if nm.len > 0: return b.removeImport(nm)
  of "can-be-func":
    let k = qProcKeyword(s, d.col)                 # (as its quick fix: the `proc` before the name)
    if k >= 0:
      discard b.replaceText(Pos(line: d.line, col: k), Pos(line: d.line, col: k + 4), "func")
      return true
  of "nim3":
    # (the problem carries its edits: made from the right, so the columns of the others stay right)
    if d.code != nil and d.code.kind == JObject and d.code.hasKey("edits"):
      var es: seq[(Pos, Pos, string)]
      for e in d.code["edits"]:
        es.add (Pos(line: e[0].getInt, col: e[1].getInt), Pos(line: e[2].getInt, col: e[3].getInt), e[4].getStr)
      es.sort(proc(x, y: (Pos, Pos, string)): int = cmp((y[0].line, y[0].col), (x[0].line, x[0].col)))
      for (a, e, t) in es: discard b.replaceText(b.clampPos(a), b.clampPos(e), t)
      return es.len > 0
  else: discard
  false

proc lintMain(args: seq[string], prog = "ned --lint"): int =
  var inputs: seq[string]
  var format = if getEnv("GITHUB_ACTIONS") == "true": "github" else: "text"
  var showSev = 2
  var failSev = 2
  var staged, noConfig, quiet, installHook, force, fix, diffOnly, listRules = false
  var fixRules: seq[string]
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
      if val notin ["text", "github", "json", "sarif"]:
        stderr.writeLine prog & ": --format is text, github, json or sarif"
        return 2
      format = val
    of "severity", "min":
      showSev = lintSevOf(val)
      if showSev <= 0:
        stderr.writeLine prog & ": --severity is error, warning, info or hint"
        return 2
    of "fail-on", "failon":
      failSev = lintSevOf(val)
      if failSev < 0:
        stderr.writeLine prog & ": --fail-on is error, warning, info, hint or never"
        return 2
    of "fix":
      fix = true
      for r in val.split(','):
        let rr = r.strip
        if rr.len == 0: continue
        if rr notin LintFixRules:
          stderr.writeLine prog & ": --fix: " & rr & " has no fix (those that do: " & LintFixRules.join(", ") & ")"
          return 2
        fixRules.add rr
    of "diff": diffOnly = true
    of "rules": listRules = true
    of "staged": staged = true
    of "no-config", "noconfig": noConfig = true
    of "q", "quiet": quiet = true
    of "install-hook": installHook = true
    of "force": force = true
    else:
      stderr.writeLine prog & ": unknown option " & a & " (" & prog & " --help)"
      return 2
  if listRules:
    for (r, what, sev) in NedRules:
      echo alignLeft(r, 22) & alignLeft(lintSevName(sev), 9) & what & (if r in LintFixRules: " (--fix)" else: "")
    return 0
  if installHook: return lintInstallHook(prog, getAppFilename(), force)
  if fix and staged:
    stderr.writeLine prog & ": --fix changes your files, --staged checks what git has: not both"
    return 2
  if diffOnly and not fix:
    stderr.writeLine prog & ": --diff shows what --fix would change: give both"
    return 2
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
  nxStatMemo = true                              # (the files stay as they are while it runs: each stat'ed once)
  ecWantSev = if fix: 4 else: max(showSev, failSev)    # (hints not shown nor failed on: not looked for — faster)
  # the files: given, in the folders given (what git does not ignore), or staged
  var files: seq[(string, string)]            # (path, the text checked — "" read from disk)
  var nimbles: seq[string]                     # (.nimble files among them: their own checks)
  if staged:
    let (ok, o, _) = runFilter("git diff --cached --name-only -z --diff-filter=ACMR", "", rootDir, 20000)
    if not ok:
      stderr.writeLine prog & ": --staged needs a git repository"
      return 2
    var top = ""
    let (tok, t, _) = runFilter("git rev-parse --show-toplevel", "", rootDir, 10000)
    if tok: top = t.strip
    for f in o.split('\0'):
      if not (f.endsWith(".nim") or f.endsWith(".nimble")): continue
      let (sok, txt, _) = runFilter("git show " & quoteShell(":" & f), "", (if top.len > 0: top else: rootDir), 20000)
      if sok:
        let p = if top.len > 0: top / f else: absolutePath(f)
        if f.endsWith(".nimble"): nimbles.add p else: files.add (p, txt)
  else:
    if inputs.len == 0: inputs = @["."]
    for inp in inputs:
      if dirExists(inp):
        for p in fmtAllFiles(absolutePath(inp)):
          if p.endsWith(".nim"): files.add (p, "")
          elif p.endsWith(".nimble"): nimbles.add p
      elif fileExists(inp):
        if inp.endsWith(".nimble"): nimbles.add absolutePath(inp) else: files.add (absolutePath(inp), "")
      else:
        stderr.writeLine prog & ": " & inp & ": no such file or folder"
        return 2
  # (left out by .ned/lint.json)
  var excluded = 0
  block:
    var keep: seq[(string, string)]
    for (p, t) in files:
      if lintExcluded(lintCfgFor(p), p): inc excluded
      else: keep.add (p, t)
    files = keep
  # the project's search paths and defines, from `nim dump` (once)
  if not noConfig and files.len > 0 and haveExe("nim"):
    let b0 = newBuffer()
    b0.path = files[0][0]
    let proj = nimProjectFile(b0)
    let (_, o, _) = runFilter("nim dump --hints:off --warnings:off --dump.format:json " & quoteShell(proj) &
                              " 2>/dev/null", "", parentDir(proj), 60000)
    nxDumpApply(proj, o)
    nxDumped.incl proj
  # each file: checked, fixed when asked (then checked again: what is left)
  var found: seq[(string, Diag)]
  var counts, all: array[5, int]             # (shown; found at all — what --fail-on counts)
  var fixedProblems, fixedFiles = 0
  var cfgProblems: seq[string]
  var bufsByPath: Table[string, Buffer]
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
    let finalNl = b.lines.len > 1 and b.lines[^1].len == 0
    if finalNl: b.lines.setLen(b.lines.len - 1)
    var crlf = false
    for l in b.lines.mitems:
      if l.endsWith("\r"):
        l.setLen(l.len - 1)
        crlf = true
    b.lang = detectLang(path, b.lines[0])
    if b.lang == nil or b.lang.mode != lmNim: continue
    let lc = lintCfgFor(path)
    for pr in lc.problems:
      let m = relativePath(lc.dir / ".ned" / "lint.json", rootDir) & ": " & pr
      if m notin cfgProblems: cfgProblems.add m
    var ds = lintChecks(b)
    if fix:
      # (from the bottom up: an edit leaves the places above it where they were)
      var todo: seq[Diag]
      for d in ds:
        if d.rule in LintFixRules and d.rule != "import-not-required" and (fixRules.len == 0 or d.rule in fixRules):
          todo.add d
      todo.sort(proc(x, y: Diag): int = cmp((y.line, y.col), (x.line, x.col)))
      var n = 0
      for d in todo:
        if lintFixOne(b, d): inc n
      if n > 0:
        var outText = b.lines.join(if crlf: "\r\n" else: "\n")
        if finalNl: outText.add (if crlf: "\r\n" else: "\n")
        let shownPath = relativePath(path, rootDir)
        if diffOnly: stdout.write unifiedDiff(text, outText, shownPath, shownPath & " (fixed)", false)
        else:
          try:
            writeFileSafe(path, outText)               # (and forgets its stamp: the engine reads it again)
          except CatchableError as e:
            stderr.writeLine path & ": not written: " & e.msg
            continue
        fixedProblems += n
        inc fixedFiles
        if not diffOnly: ds = lintChecks(b)          # (what is left)
    bufsByPath[path] = b
    for d in ds:
      let sev = clamp(d.sev, 1, 4)
      inc all[sev]
      if sev > showSev: continue
      inc counts[sev]
      found.add (path, d)
  # the project's own checks: exports nothing uses, imports the .nimble does not require, its .nimble
  # (--fix: a requirement added to the .nimble for each package imported without one)
  if fix and (fixRules.len == 0 or "import-not-required" in fixRules):
    var want: Table[string, seq[string]]          # .nimble → the packages to require
    var keep: seq[(string, Diag)]
    var dropped: seq[Diag]
    for (p, d) in found:
      if d.rule == "import-not-required":
        let nb = findNimbleFile(parentDir(p))
        let pkg = quotedName(d.msg)
        if nb.len > 0 and pkg.len > 0:
          if pkg notin want.mgetOrPut(nb, @[]): want[nb].add pkg
          dropped.add d
          continue
      keep.add (p, d)
    for nb, pkgs in want:
      let nbb = newBuffer()
      nbb.path = nb
      var before = ""
      try: before = readFile(nb)
      except CatchableError: continue
      nbb.lines = before.split('\n')
      for pkg in pkgs: pcAddRequireTo(nbb, nb, pkg)
      let after = nbb.lines.join("\n")
      if diffOnly: stdout.write unifiedDiff(before, after, relativePath(nb, rootDir), relativePath(nb, rootDir) & " (fixed)", false)
      else:
        try: writeFileSafe(nb, after)
        except CatchableError as e:
          stderr.writeLine nb & ": not written: " & e.msg
          continue
      fixedProblems += pkgs.len
      inc fixedFiles
    if not diffOnly:
      found = keep
      for d in dropped:
        let sev = clamp(d.sev, 1, 4)
        dec all[sev]
        dec counts[sev]
  for (p, d0) in lintProjectChecks(bufsByPath, nimbles):
    let d = d0
    let sev = clamp(d.sev, 1, 4)
    inc all[sev]
    if sev > showSev: continue
    inc counts[sev]
    found.add (p, d)
  found.sort(proc(x, y: (string, Diag)): int = cmp((x[0], x[1].line, x[1].col), (y[0], y[1].line, y[1].col)))
  let shown = proc(p: string): string =
    let r = relativePath(p, rootDir)
    if r.startsWith(".."): p else: r
  let ruleOf = proc(d: Diag): string = (if d.rule.len > 0: d.rule else: "ned")
  case format
  of "json":
    let arr = newJArray()
    for (p, d) in found:
      arr.add %*{"file": shown(p), "line": d.line + 1, "column": d.col + 1, "endLine": max(d.eline, d.line) + 1,
                 "endColumn": (if d.ecol > 0: d.ecol + 1 else: d.col + 1), "severity": lintSevName(clamp(d.sev, 1, 4)),
                 "rule": ruleOf(d), "message": d.msg.splitLines()[0], "source": "ned"}
    echo arr.pretty
  of "sarif":
    # (SARIF 2.1.0: GitHub code scanning reads it — github/codeql-action/upload-sarif)
    var rules = newJArray()
    var index: Table[string, int]
    for (r, what, sev) in NedRules:
      index[r] = rules.len
      rules.add %*{"id": r, "shortDescription": {"text": what},
                   "defaultConfiguration": {"level": (case sev
                                                      of 1: "error"
                                                      of 2: "warning"
                                                      else: "note")}}
    var results = newJArray()
    for (p, d) in found:
      let level = case clamp(d.sev, 1, 4)
                  of 1: "error"
                  of 2: "warning"
                  else: "note"
      var region = %*{"startLine": d.line + 1, "startColumn": d.col + 1}
      if d.ecol > d.col and d.eline <= d.line:
        region["endLine"] = %(d.line + 1)
        region["endColumn"] = %(d.ecol + 1)
      var res = %*{"ruleId": ruleOf(d), "level": level, "message": {"text": d.msg.splitLines()[0]},
                   "locations": [{"physicalLocation": {"artifactLocation": {"uri": shown(p).replace('\\', '/'),
                                                                              "uriBaseId": "%SRCROOT%"},
                                                       "region": region}}]}
      if ruleOf(d) in index: res["ruleIndex"] = %index[ruleOf(d)]
      results.add res
    let sarif = %*{"$schema": "https://json.schemastore.org/sarif-2.1.0.json", "version": "2.1.0",
                   "runs": [{"tool": {"driver": {"name": "ned", "version": NedVersion, "rules": rules}},
                             "results": results}]}
    echo sarif.pretty
  of "github":
    for (p, d) in found:
      let kind = case clamp(d.sev, 1, 4)
                 of 1: "error"
                 of 2: "warning"
                 else: "notice"
      echo "::" & kind & " file=" & lintGhEscape(shown(p), true) & ",line=" & $(d.line + 1) & ",col=" & $(d.col + 1) &
           (if d.ecol > d.col and d.eline == d.line: ",endColumn=" & $(d.ecol + 1) else: "") &
           ",title=" & lintGhEscape("ned (" & ruleOf(d) & ")", true) & "::" & lintGhEscape(d.msg.splitLines()[0])
  else:
    for (p, d) in found:
      echo shown(p) & ":" & $(d.line + 1) & ":" & $(d.col + 1) & ": " & lintSevName(clamp(d.sev, 1, 4)) & ": " &
           d.msg.splitLines()[0] & " [" & ruleOf(d) & "]"
  for m in cfgProblems: stderr.writeLine prog & ": " & m
  if not quiet and format notin ["json", "sarif"]:
    var parts: seq[string]
    for s in 1 .. 4:
      if counts[s] > 0: parts.add $counts[s] & " " & lintSevName(s) & (if counts[s] == 1: "" else: "s")
    let nf = files.len + nimbles.len
    stderr.writeLine prog & ": " & $nf & " file" & (if nf == 1: "" else: "s") & " checked" &
                     (if excluded > 0: " (" & $excluded & " left out by .ned/lint.json)" else: "") &
                     (if fixedProblems > 0: " — " & $fixedProblems & " fixed in " & $fixedFiles & " file" &
                                            (if fixedFiles == 1: "" else: "s") & (if diffOnly: " (shown, not written)" else: "")
                      else: "") &
                     (if parts.len > 0: " — " & parts.join(", ") & (if fix and not diffOnly: " left" else: "")
                      else: ", nothing " & (if fix and not diffOnly: "left" else: "found"))
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

proc cmdLintRules() =
  ## Nim › lint rules for this project: .ned/lint.json opened — made with every rule at its own severity when
  ## there is none, to change
  if rootDir.len == 0:
    info("Open a project folder first")
    return
  var f = lintCfgFile(rootDir / "x.nim")
  if f.len == 0:
    f = rootDir / ".ned" / "lint.json"
    var rules = newJObject()
    for (r, _, sev) in NedRules: rules[r] = %lintSevName(sev)
    let j = %*{"rules": rules, "exclude": []}
    try:
      createDir(parentDir(f))
      writeFileSafe(f, j.pretty & "\n")
    except CatchableError as e:
      error("Could not write " & f & ": " & e.msg)
      return
    info("Made " & relPath(f) & " — every rule at its own severity: \"off\", \"error\", \"warning\", \"info\" or " &
         "\"hint\"; exclude takes folders (\"generated/\") and globs")
  discard openFile(f)
