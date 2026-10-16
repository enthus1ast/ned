# ── remote folders over SSH: a local copy to edit (tree, search, language servers work as usual); every save
#    goes to the server at once, and the terminal, Run, tasks and tests run there, through one ssh connection ──

type Remote = object
  host, path, absPath, mirror, ctl: string    # path: as typed (~ allowed) · absPath: the server's real folder
  git: bool                                  # the folder is a git repository's top: git runs on the server
  pulledAt: float                            # when the whole folder was last copied over (epoch seconds)

var
  remotes: seq[Remote]
  remotePushing = 0                          # saves on their way to the server

proc remoteOf(local: string): int =
  ## the remote folder whose local copy holds `local` (-1: none)
  for i, r in remotes:
    if local == r.mirror or local.startsWith(r.mirror & "/"): return i
  -1

proc sshCmd(r: Remote, batch = true): string =
  ## ssh through the shared connection (BatchMode: never stops to ask for a password)
  "ssh -o ControlPath=" & quoteShell(r.ctl) & (if batch: " -o BatchMode=yes" else: "") & " " & quoteShell(r.host)

proc remoteScript(script: string): string =
  ## a POSIX script for the server, run by sh whatever the account's login shell is (fish, tcsh, nushell …): it
  ## travels as printf %b escapes inside single quotes, which every shell passes on unchanged
  var esc = ""
  for ch in script:
    case ch
    of '\\': esc.add "\\0134"
    of '\'': esc.add "\\0047"
    of '\n': esc.add "\\0012"
    of '!': esc.add "\\0041"              # (csh's history)
    else: esc.add ch
  "sh -c 'eval \"$(printf %b \"$1\")\"' sh '" & esc & "'"

proc sshRun(r: Remote, script: string, batch = true): string =
  ## ssh running `script` on the server (with sh)
  sshCmd(r, batch) & " " & quoteShell(remoteScript(script))

proc remotePath(r: Remote, local: string): string =
  if local == r.mirror: r.absPath else: r.absPath & local[r.mirror.len .. ^1]

proc remoteCommand(r: Remote, cmd, localCwd: string, tty = false): string =
  ## `cmd` run on the server, in the folder that matches `localCwd`; local copies' paths become the server's
  var c = cmd.replace(r.mirror & "/", r.absPath & "/")
  if c.endsWith(" " & r.mirror): c = c[0 ..< c.len - r.mirror.len] & r.absPath
  let cwd = remotePath(r, (if localCwd.len > 0 and remoteOf(localCwd) >= 0: localCwd else: r.mirror))
  sshCmd(r, not tty) & (if tty: " -t" else: "") & " " & quoteShell(remoteScript("cd " & quoteShell(cwd) & " && " & c))

proc remotePush(local: string)
proc remoteFileOp(op, local: string, dest = "")
proc remoteGitBefore(root: string): string
proc remoteGitAfter(root: string)
proc remoteRun(ri: int, script, okMsg: string, then: proc() = nil)
proc saveRemotes()
proc remoteSync(ri: int, then: proc() = nil)
proc remoteConnect(r: Remote, then: proc() {.closure.})

proc remotePushFlag(): string = privDir() / ("remote-pushing-" & $getCurrentProcessId())

proc remoteWaitPushes(): string =
  ## shell that waits (30 s at most) while saves are still on their way to the server
  "n=0; while [ -e " & quoteShell(remotePushFlag()) & " ] && [ $n -lt 300 ]; do sleep 0.1; n=$((n+1)); done; "

fileWrittenHook = proc(path: string) =
  if remotes.len > 0 and remoteOf(path) >= 0: remotePush(path)

var remoteTmpN = 0

proc remoteToo(local: string): string =
  ## for a question about a file of a remote folder: it happens on the server too
  if remotes.len == 0: return ""
  let ri = remoteOf(local)
  if ri >= 0: " (here and on " & remotes[ri].host & ")" else: ""

proc gitWrap(cmd, cwd: string): string =
  ## a git command for a remote folder's local copy, run by git on the server (whose repository is the real one):
  ## the local copy's paths become the server's, and ned's own temporary files the command reads (a commit
  ## message, a patch, a rebase plan) go along inside the command, to /tmp there
  if remotes.len == 0: return cmd
  let ri = remoteOf(cwd)
  if ri < 0: return cmd
  var c = cmd
  var pre, post = ""
  let pd = privDir() & "/"
  var k = c.find(pd)
  while k >= 0:
    var e = k + pd.len
    while e < c.len and c[e] notin {' ', '\'', '"', ';', '&', '|', '<', '>', '\n', ')'}: inc e
    let f = c[k ..< e]
    var body = ""
    let ok = fileExists(f) and (try: (body = readFile(f); true) except CatchableError: false)
    if not ok:
      k = c.find(pd, e)
      continue
    inc remoteTmpN
    let rf = "/tmp/ned-" & $getCurrentProcessId() & "-" & $remoteTmpN & "-" & extractFilename(f)
    var eof = "NED_EOF"
    while eof in body: eof.add "_"
    pre.add "cat > " & rf & " <<'" & eof & "'\n" & body & (if body.endsWith("\n") or body.len == 0: "" else: "\n") &
           eof & "\n"
    post.add " " & rf
    c = c[0 ..< k] & rf & c[e .. ^1]
    k = c.find(pd, k + rf.len)
  if post.len > 0: c = "{ " & pre & "( " & c & " ); ned_rc=$?; rm -f" & post & "; exit $ned_rc; }"
  remoteCommand(remotes[ri], c, cwd)
