# ── errors while you type, from the compiler: the unsaved text checked as it is ──
#    `nim check -` reads the module from stdin. Run in the file's folder, it sees the same imports (relative ones
#    too), the same nim.cfg / config.nims and the same nimble packages as a check of the file itself — so ned
#    hands it a private copy of the buffer after a pause in typing, and puts what it says on the buffer.

var
  typingChecks: Table[string, (int, MonoTime, string)]   # path → (the text's changeId, started, the copy)
  typingCheckMs: Table[string, int]                      # path → how long its last check took (ms)


proc typingCheckUsable(b: Buffer): bool =
  ## should the compiler check this buffer's unsaved text while you type (rather than nimsuggest, or nothing)?
  if b.lang == nil or b.lang.mode != lmNim or b.path.len == 0 or not b.path.endsWith(".nim") or b.largeOn or
     b.readOnly or not haveExe("nim") or lspActiveFor(b) or not nimEngineOn(b):
    return false
  let how = sStr("nim.liveDiagnosticsFrom")
  if how == "nimsuggest": return false
  let took = typingCheckMs.getOrDefault(b.path, 0)
  # (a big project whose check takes long: nimsuggest, which keeps the project in memory, answers faster)
  if how != "compiler" and took > 10_000 and nsUsable(b): return false
  if how != "compiler" and took > 30_000: return false
  for l in b.lines:
    if l.startsWith("<<<<<<< ") or l == "<<<<<<<": return false     # (a merge to finish first: no errors yet)
  nxIncluderOf(b.path).len == 0             # (a file another one includes is no module of its own)

proc parseNimCheck(output, cwd, stdinPath: string): (Table[string, seq[Diag]], Table[string, seq[(int, int, string)]]) =
  ## `nim check`'s errors, warnings and "declared but not used" hints by file; `stdinPath`: the file that
  ## "stdinfile.nim" stands for
  var lastP = ""
  var extra = 0
  for raw in output.splitLines:
    var t = stripAnsi(raw)
    if stdinPath.len > 0 and t.startsWith("stdinfile.nim("): t = stdinPath & t["stdinfile.nim".len .. ^1]
    let (ok, p, l, c, sev, m) = parseErrLine(t, cwd)
    if ok and sev in {1, 2} and m.len > 0 and m != "Traceback":
      result[0].mgetOrPut(p, @[]).add Diag(line: l, col: c, eline: l, ecol: -1, sev: sev, msg: m, src: "nim")
      lastP = p
      extra = 0
    elif ok:
      lastP = ""
      if "declared but not used" in m: result[1].mgetOrPut(p, @[]).add (l, c, quotedNameOf(m))
    elif lastP.len > 0 and extra < 60 and t.len > 0 and not t.startsWith("Hint:") and not t.startsWith("CC:") and
         not t.startsWith("Success"):
      # (a type mismatch goes on over the next lines)
      result[0][lastP][^1].msg.add "\n" & t
      inc extra

proc typingCheck(b: Buffer) =
  if b.path in typingChecks: return
  let id = b.changeId
  let copy = privTmp("typing") & ".nim"
  try: writeFile(copy, b.lines.join("\n") & (if b.noEol: "" else: "\n"))
  except CatchableError: return
  b.chkAt = id
  let path = b.path
  let bid = b.id
  typingChecks[path] = (id, getMonoTime(), copy)
  discard startJob(jkCheck, "nim check --hint:all:off --hint:XDeclaredButNotUsed:on --colors:off " &
                            "--listFullPaths:on - < " & quoteShell(copy), parentDir(path), proc(j: Job) =
    let st = typingChecks.getOrDefault(path)
    typingChecks.del path
    typingCheckMs[path] = int(msSince(st[1]))
    try: removeFile(copy)
    except CatchableError: discard
    let x = bufById(bid)
    if x == nil or x.changeId != id: return        # (typed since: the next pause checks the new text)
    let (found, unused) = parseNimCheck(j.output, j.cwd, path)
    var mine = found.getOrDefault(path)
    keepCDiags(path, mine)
    diagsBuild[path] = mine                          # (other files' errors: from their own checks, on disk)
    unusedHints[path] = unused.getOrDefault(path)
    needRender = true)

proc recheckBuildErrors(saved: Buffer) =
  ## after a save: the errors other files show from a build or check may be gone now (the fix was in this
  ## file), and with a language server this file's own build errors are not re-checked by runCheck — so
  ## check again every file of the same language that shows an error from a build or check
  if not cfgCheckOnSave or saved.path.len == 0 or saved.lang == nil: return
  let fam = if saved.lang.id in ["c", "cpp"]: @["c", "cpp"] else: @[saved.lang.id]
  let lspHere = lspActiveFor(saved)
  var todo: seq[(string, string)]
  var cmds: HashSet[string]
  for p, ds in diagsBuild:
    if todo.len >= 4: break
    var bad = false
    for d in ds:
      if d.sev == 1 and d.src != "examples": bad = true
    if not bad: continue
    if p == saved.path and not lspHere: continue          # runCheck has just checked it
    let i = bufIndexByPath(p)
    if i >= 0 and bufs[i].dirty: continue                 # its own save checks it; the disk copy is old
    let lid = if i >= 0: bufs[i].lang.id else: detectLang(p, "").id
    if lid notin fam or not fileExists(p): continue
    let (cmd, cwd) = checkCmdForPath(p, lid)
    if cmd.len == 0 or (cmd.startsWith("cargo ") and cwd in cmds): continue
    cmds.incl cwd
    todo.add (p, lid)
  for (p, lid) in todo: runCheckPath(p, lid, keepExamples = p != saved.path)

proc findGitRoot(start: string): string =
  if remotes.len > 0:
    # a remote folder's local copy: its repository is on the server (git runs there), when it has one
    let ri = remoteOf(start)
    if ri >= 0: return (if remotes[ri].git: remotes[ri].mirror else: "")
  var d = start
  for _ in 0 .. 40:
    if dirExists(d / ".git") or fileExists(d / ".git"): return d
    let p = parentDir(d)
    if p == d or p.len == 0: break
    d = p
  ""
