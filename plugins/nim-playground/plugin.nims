## nim-playground — the selection (or the file) on the Nim playground, play.nim-lang.org: shared as a link, or run there
##
##   Playground: share the selection   the selected code (nothing selected: the whole file) sent to the playground,
##                                     which keeps it: its link — https://play.nim-lang.org/#pasty=… — on the
##                                     clipboard, in the status line and in the Output panel
##   Playground: run the selection there   the code compiled and run by the playground (its Nim, plugins.nim-
##                                     playground.version): what the compiler said and what the program printed in
##                                     the Output panel; an error's line marked in the file (✗ …)
##   settings                          plugins.nim-playground.server — https://play.nim-lang.org, or a playground
##                                     of your own · .version — latest, or one the playground has (2.2.4) · .target
##                                     — c or cpp · .timeoutSeconds — 30
##
## The request goes with curl, in the background. When the playground cannot be reached — no network, a proxy that
## refuses it, a server that is down — it says why, in words, and nothing is lost: the code stays as it was, and
## the request is in the plugin's data folder (request.json) to send again. It needs curl on PATH (Termux: `pkg
## install curl`).
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "sends the code you choose to the Nim playground with curl")
permission("clipboard", "Playground: share puts the link on the clipboard")

settingDef("server", "https://play.nim-lang.org", "Playground: the playground's address (one of your own: its address)")
settingDef("version", "latest", "Playground: the Nim the playground runs your code with — latest, or a version it has")
settingDef("target", "c", "Playground: the backend the playground compiles to — c or cpp")
settingDef("timeoutSeconds", 30, "Playground: how long a request may take")

# ── what the playground answers ──

func curlWhy*(code: int, said: string): string =
  ## curl's exit code (and what it said) in words
  let why = case code
    of 5: "the proxy's name could not be found"
    of 6: "the playground's address could not be found — is the network on?"
    of 7: "it could not connect — is the network on, is the playground up?"
    of 28: "it took too long (plugins.nim-playground.timeoutSeconds)"
    of 35, 60: "a secure connection could not be made"
    of 52: "the playground answered nothing"
    of 56: (if "CONNECT" in said or "proxy" in said.toLowerAscii: "a proxy on the way refused it"
            else: "the connection broke")
    of 127: "curl is not installed (Termux: pkg install curl)"
    else: "curl stopped (" & $code & ")"
  if said.len > 0 and code != 127: why & " — curl: " & said else: why

func splitStatus*(o: string): (string, int) =
  ## curl's output with -w '\n%{http_code}': the body and the HTTP status (0: none)
  let k = o.rfind('\n')
  let last = (if k >= 0: o[k + 1 .. ^1] else: o).strip
  var n = 0
  try: n = parseInt(last)
  except ValueError: return (o, 0)
  ((if k >= 0: o[0 ..< k] else: ""), n)

func pastyId*(body: string): string =
  ## the id of what the playground kept: the last part of the address it answers (https://pasty.ee/abc123)
  let t = body.strip
  if t.len == 0 or ' ' in t or '\n' in t: return ""
  let k = t.rfind('/')
  t[k + 1 .. ^1]

func errorLines*(log: string, first: int): seq[(int, string)] =
  ## the compiler's errors with their lines in the file: in.nim(3, 5) Error: … — line 3 of the code sent, which
  ## starts at the file's line `first`
  for l in log.splitLines:
    let e = l.find(") Error: ")
    if e < 0: continue
    let p = l.rfind('(', last = e)
    if p < 0: continue
    let nums = l[p + 1 ..< e].split(',')
    try:
      result.add (first + parseInt(nums[0].strip) - 1, l[e + 2 .. ^1])
    except ValueError: discard

# ── sending ──

var busy = false

proc codeOf(b: Buf): (string, int) =
  ## the selection's text (nothing selected: the whole file), and its first line
  let r = b.selection
  if r.isEmpty: (b.text, 0) else: (b.textIn(r), r.start.line)

proc post(path: string, body: JsonNode, what: string, done: proc(body: string)) =
  ## the request sent with curl in the background; `done` gets the answer's body when it is a 200 — else the
  ## reason is said
  let server = setting("server", "https://play.nim-lang.org").strip.strip(leading = false, chars = {'/'})
  writeData("request.json", $body)
  let req = dataDir() / "request.json"
  let cmd = "curl -sS --max-time " & $setting("timeoutSeconds", 30) & " -H 'Content-Type: application/json' " &
            "--data-binary @" & quoteShell(req) & " -w '\\n%{http_code}' " & quoteShell(server & path)
  busy = true
  progress("Playground: " & what)
  shellAsync(cmd) do (o: string, code: int):
    busy = false
    progressDone()
    if code != 0:
      var said = ""
      for l in o.splitLines:
        if l.startsWith("curl: "): said = l[6 .. ^1].strip
      warn("Playground: " & server & " could not be reached: " & curlWhy(code, said) & " — the request is in " & req)
      output("✗ " & what & ": " & server & path & " — " & curlWhy(code, said))
      return
    let (b, status) = splitStatus(o)
    if status != 200:
      let first = b.strip.splitLines
      warn("Playground: " & server & " answered " & $status & (if first.len > 0 and first[0].len > 0: ": " & first[
           0][0 ..< min(120, first[0].len)] else: "") & " — the request is in " & req)
      return
    done(b)

proc share() =
  let b = current()
  let (code, _) = codeOf(b)
  if code.strip.len == 0:
    message("Playground: nothing to share")
    return
  if busy:
    message("Playground: a request is on its way")
    return
  let server = setting("server", "https://play.nim-lang.org").strip.strip(leading = false, chars = {'/'})
  post("/pasty", %*{"code": code, "compilationTarget": setting("target", "c")}, "sharing " &
       $code.countLines & " lines") do (body: string):
    let id = pastyId(body)
    if id.len == 0:
      warn("Playground: the playground's answer was not a link: " & body.strip[0 ..< min(100, body.strip.len)])
      return
    let link = server & "/#pasty=" & id
    var where = ""
    try:
      setClipboard(link)
      where = " — on the clipboard"
    except ValueError: discard                      # (the clipboard not allowed: the link is said anyway)
    output("↗ " & link)
    message("Playground: " & link & where)

proc runThere() =
  let b = current()
  let (code, first) = codeOf(b)
  if code.strip.len == 0:
    message("Playground: nothing to run")
    return
  if busy:
    message("Playground: a request is on its way")
    return
  let version = setting("version", "latest")
  let target = setting("target", "c")
  post("/compile", %*{"code": code, "compilationTarget": target, "outputFormat": "raw", "version": version},
       "running " & $code.countLines & " lines (Nim " & version & ")") do (body: string):
    var log, compileLog: string
    try:
      let j = parseJson(body)
      log = j{"log"}.getStr
      compileLog = j{"compileLog"}.getStr
    except CatchableError:
      warn("Playground: the playground's answer was not what it gives: " & body.strip[0 ..< min(100, body.strip.len)])
      return
    let errs = errorLines(compileLog, first)
    try:
      b.clearDecorations()
      for (l, msg) in errs:
        b.virtualText(l, "✗ " & msg, "error")
        b.sign(l, "✗", "error")
    except ValueError: discard                      # (its tab was closed meanwhile)
    output("▶ the playground (Nim " & version & ", " & target & ")\n" & compileLog.strip & "\n" &
           (if log.strip.len > 0: "──── what it printed ────\n" & log.strip & "\n" else: ""))
    showOutput()
    if errs.len > 0: warn("Playground: " & errs[0][1] & " (line " & $(errs[0][0] + 1) & ")")
    else:
      let ls = log.strip.splitLines
      message("Playground: ran — " & (if log.strip.len == 0: "it printed nothing" else: ls[0] &
              (if ls.len > 1: " … (" & $ls.len & " lines in the Output panel)" else: "")))

command "Playground: share the selection":
  share()

command "Playground: run the selection there":
  runThere()
