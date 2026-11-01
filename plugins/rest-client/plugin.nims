## rest-client — HTTP requests written in .http files, sent with curl; the response in a tab of its own
##
##   .http and .rest files   a language: the methods coloured, # and // comments, ### between requests, the
##                           {{variables}} and @name = value marked; the outline lists the requests
##   REST: send the request at the cursor   Ctrl+Alt+R or vim <leader>r (in .http files, and in an ```http block
##                           of Markdown) — curl runs in the background, at most timeoutSeconds; the response
##                           comes in a tab of the request's (Response: login — sent again, the tab shows the new
##                           one, unless you have changed it): the status line and the time, the headers, the body
##                           (JSON pretty-printed)
##   REST: copy as curl      the request at the cursor as a curl command, on the clipboard
##   REST: cancel the request
##   completion after {{ (the variables), hover on {{a variable}}: its value
##   settings                plugins.rest-client.timeoutSeconds, .followRedirects, .insecure (no certificate check)
##
## A file:
##   @host = http://localhost:8080          a variable, for the whole file ({{host}})
##   ### Log in                             a request starts (its title)
##   # @name login                          its name: its response is {{login.response.body.$.token}} (a JSON
##   POST {{host}}/login HTTP/1.1           path), {{login.response.headers.Location}}
##   Content-Type: application/json         headers, up to a blank line; then the body (or < ./file.json)
##
##   {"user": "ann", "id": "{{$guid}}"}
## and {{$timestamp}}, {{$randomInt 1 100}}, {{$datetime iso8601}}, {{$processEnv HOME}}, {{$dotenv KEY}} (the .env
## file beside it). The method can be left out (GET); lines that start with ? or & go on the address.
import nedplugin
import std/[tables, base64]
when not defined(nimscript):
  import std/osproc

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "sends your requests with curl")
permission("clipboard", "REST: copy as curl puts the command there")

settingDef("timeoutSeconds", 30, "REST: how long a request may take before curl gives up (seconds)")
settingDef("followRedirects", true, "REST: follow redirects (3xx) to the response at their end")
settingDef("insecure", false, "REST: do not check the server's certificate (a self-signed one, on your own machine)")

const Methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT", "TRACE"]

language("http", LangSpec(name: "HTTP requests", extensions: @["http", "rest"], lineComment: "#",
                          keywords: @Methods, constants: @["HTTP"], quotes: "\"", pairs: "()[]{}\"\""))

proc sh(cmd: string): (string, int) =
  ## a shell command's output and exit code (where it is: the commands here say where they run)
  when defined(nimscript): gorgeEx(cmd)
  else:
    let (o, c) = execCmdEx(cmd)
    (o.strip(leading = false, chars = {'\n'}), c)

# ── the file: requests and variables ──

type
  Req = object
    title, name: string
    meth, url, body, bodyFile: string
    headers: seq[(string, string)]
    line: int                    # the request line (-1: the part has none)
  Resp = object
    status: int
    headers: seq[(string, string)]
    body: string

var responses: Table[string, Resp]  # the named requests' last responses

# whether the (stripped) line is a # or // comment
func isComment(t: string): bool = t.startsWith("#") or t.startsWith("//")

func parts(lines: seq[string]): seq[(int, int, string)] =
  ## the file's parts between ### lines: first line, the line after the last, title
  var a = 0
  var title = ""
  for i, l in lines:
    if l.startsWith("###"):
      result.add (a, i, title)
      a = i + 1
      title = l[3 .. ^1].strip
  result.add (a, lines.len, title)

func parseReq(lines: seq[string], a, e: int, title: string): Req =
  ## reads the request in lines a ..< e: its @name from a comment, then the request line (a method left out is GET; a
  ## trailing HTTP/1.1 is dropped; lines starting with ? or & go on the address), the headers up to a blank line, and
  ## the body (or a `< file` that holds it); the request's line is -1 when the part has none
  result = Req(title: title, line: -1)
  var i = a
  while i < e:                   # (before the request line: blank lines, comments, variables)
    let t = lines[i].strip
    if t.len == 0 or t[0] == '@':
      inc i
      continue
    if isComment(t):
      let c = t.strip(trailing = false, chars = {'#', '/', ' '})
      if c.startsWith("@name ") or c.startsWith("@name\t"): result.name = c[6 .. ^1].strip
      inc i
      continue
    break
  if i >= e: return
  result.line = i
  let rl = lines[i].strip
  let sp = rl.find(' ')
  var rest = rl
  result.meth = "GET"
  if sp > 0 and rl[0 ..< sp] in Methods:
    result.meth = rl[0 ..< sp]
    rest = rl[sp + 1 .. ^1].strip
  let v = rest.rfind(" HTTP/")
  if v > 0: rest = rest[0 ..< v].strip
  result.url = rest
  inc i
  while i < e and lines[i].strip.len > 0 and lines[i].strip[0] in {'?', '&'}:
    result.url.add lines[i].strip
    inc i
  while i < e and lines[i].strip.len > 0:
    let t = lines[i].strip
    if not isComment(t):
      let c = t.find(':')
      if c > 0: result.headers.add (t[0 ..< c].strip, t[c + 1 .. ^1].strip)
    inc i
  if i < e: inc i                # (the blank line)
  var body = if i < e: lines[i ..< e] else: @[]
  while body.len > 0 and body[^1].strip.len == 0: discard body.pop
  if body.len > 0 and body[0].strip.startsWith("< "): result.bodyFile = body[0].strip[2 .. ^1].strip
  else: result.body = body.join("\n")

func fileVars(lines: seq[string]): seq[(string, string)] =
  ## the @name = value lines (before each request line: a body is not looked at)
  for (a, e, _) in parts(lines):
    for i in a ..< e:
      let t = lines[i].strip
      if t.len == 0 or isComment(t): continue
      if t[0] != '@': break
      let k = t.find('=')
      if k > 1: result.add (t[1 ..< k].strip, t[k + 1 .. ^1].strip)

func httpLines(lines: seq[string], md: bool): seq[string] =
  ## the lines with requests: a Markdown file's ```http (```rest) blocks, each a part of its own
  if not md: return lines
  var inside = false
  for l in lines:
    let t = l.strip
    if not inside and (t.startsWith("```http") or t.startsWith("```rest")):
      inside = true
      result.add "###"
    elif inside and t.startsWith("```"):
      inside = false
      result.add "###"
    else: result.add (if inside: l else: "###")

func reqAt(lines: seq[string], line: int): Req =
  ## the request of the part the line is in (the ### line above it counts as in it); a request with line -1 when there
  ## is none
  for (a, e, title) in parts(lines):
    if line >= a - 1 and line < e: return parseReq(lines, a, e, title)
  Req(line: -1)

# ── variables ──

type Vars = object
  file: seq[(string, string)]
  dir: string                    # the .http file's folder ($dotenv, < file)

func jsonPath(j: JsonNode, path: string): JsonNode =
  ## $.a.b[0].c in the JSON (nil when it has none)
  var n = j
  var p = path
  if p.startsWith("$"): p = p[1 .. ^1]
  var i = 0
  while i < p.len and n != nil:
    if p[i] == '.':
      inc i
      var k = i
      while k < p.len and p[k] notin {'.', '['}: inc k
      let key = p[i ..< k]
      n = if n.kind == JObject and n.hasKey(key): n[key] else: nil
      i = k
    elif p[i] == '[':
      let k = p.find(']', i)
      if k < 0: return nil
      let ix = try: parseInt(p[i + 1 ..< k]) except ValueError: -1
      n = if n.kind == JArray and ix >= 0 and ix < n.len: n[ix] else: nil
      i = k + 1
    else: return nil
  n

proc dotenv(dir, key: string): string =
  ## the value of KEY in the .env file in dir, without quotes; raises ValueError when there is no file or no such key
  let f = dir / ".env"
  if not fileExists(f): raise newException(ValueError, "no .env file beside this one (for {{$dotenv " & key & "}})")
  for l in readFile(f).splitLines:
    let k = l.find('=')
    if k > 0 and l[0 ..< k].strip == key: return l[k + 1 .. ^1].strip.strip(chars = {'"', '\''})
  raise newException(ValueError, "the .env file has no " & key)

proc guid(): string =
  ## a new GUID, from the system's (/proc, uuidgen, or 16 random bytes made into a version 4 one)
  let (o, _) = sh("cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || " &
                  "od -An -N16 -tx1 /dev/urandom | tr -d ' \\n'")
  var g = o.strip.toLowerAscii
  if g.len == 32:                # (16 random bytes: as a version 4 GUID)
    g = g[0 .. 7] & "-" & g[8 .. 11] & "-4" & g[13 .. 15] & "-a" & g[17 .. 19] & "-" & g[20 .. 31]
  g

# n with a zero in front when it has one digit
func two(n: int): string = align($n, 2, '0')

func utc(t: int, rfc1123: bool): string =
  ## the time (seconds since 1970) in UTC: 2026-10-24T14:03:05Z, or Sat, 24 Oct 2026 14:03:05 GMT
  let days = t div 86400
  let secs = t mod 86400
  let z = days + 719468                # (days to a date: the civil calendar's arithmetic)
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  let y = yoe + era * 400 + (if m <= 2: 1 else: 0)
  let hms = two(secs div 3600) & ":" & two(secs div 60 mod 60) & ":" & two(secs mod 60)
  if rfc1123:
    const Days = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]
    const Months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    Days[days mod 7] & ", " & two(d) & " " & Months[m - 1] & " " & $y & " " & hms & " GMT"
  else: $y & "-" & two(m) & "-" & two(d) & "T" & hms & "Z"

proc resolve(s: string, vs: Vars, depth = 0): string

proc valueOf(name: string, vs: Vars, depth: int): string =
  ## a {{name}}'s text (raises ValueError when there is none)
  if depth > 10: raise newException(ValueError, "{{" & name & "}} is defined by itself")
  let w = name.splitWhitespace
  if name.startsWith("$"):
    case w[0]
    of "$timestamp": return $int(unixTime())
    of "$guid": return guid()
    of "$randomInt":
      let lo = if w.len > 1: parseInt(w[1]) else: 0
      let hi = if w.len > 2: parseInt(w[2]) else: 1000
      let r = sh("od -An -N4 -tu4 /dev/urandom")[0].strip
      return $(lo + int(parseBiggestUInt(r) mod uint64(max(1, hi - lo))))
    of "$datetime": return utc(int(unixTime()), w.len > 1 and w[1] == "rfc1123")
    of "$processEnv":
      if w.len < 2: raise newException(ValueError, "{{$processEnv}} needs a name: {{$processEnv HOME}}")
      return getEnv(w[1])
    of "$dotenv":
      if w.len < 2: raise newException(ValueError, "{{$dotenv}} needs a name: {{$dotenv TOKEN}}")
      return dotenv(vs.dir, w[1])
    else: raise newException(ValueError, "ned's REST client has no {{" & w[0] & "}}")
  let r = name.find(".response.")
  if r > 0:
    let req = name[0 ..< r]
    if req notin responses: raise newException(ValueError, "send the request named " & req & " first")
    let resp = responses[req]
    let what = name[r + ".response.".len .. ^1]
    if what.startsWith("headers."):
      let h = what["headers.".len .. ^1]
      for (k, v) in resp.headers:
        if cmpIgnoreCase(k, h) == 0: return v
      raise newException(ValueError, "the response of " & req & " has no header " & h)
    if what == "body" or what == "body.*": return resp.body
    if what.startsWith("body."):
      var j: JsonNode = nil
      try: j = parseJson(resp.body)
      except CatchableError: raise newException(ValueError, "the response of " & req & " is not JSON")
      let n = jsonPath(j, what["body.".len .. ^1])
      if n == nil: raise newException(ValueError, "the response of " & req & " has no " & what[5 .. ^1])
      return (if n.kind == JString: n.getStr else: $n)
    raise newException(ValueError, "{{" & name & "}}: after .response. comes body or headers")
  for i in countdown(vs.file.high, 0):
    if vs.file[i][0] == name: return resolve(vs.file[i][1], vs, depth + 1)
  raise newException(ValueError, "{{" & name & "}} is not defined in this file")

proc resolve(s: string, vs: Vars, depth = 0): string =
  ## the text with each {{name}} replaced
  var i = 0
  while i < s.len:
    let k = s.find("{{", i)
    let e = if k >= 0: s.find("}}", k + 2) else: -1
    if k < 0 or e < 0:
      result.add s[i .. ^1]
      break
    result.add s[i ..< k]
    result.add valueOf(s[k + 2 ..< e].strip, vs, depth)
    i = e + 2

proc resolved(r: Req, vs: Vars): Req =
  ## the request with its variables' values; a Basic user:pass encoded as the header needs
  result = r
  result.url = resolve(r.url, vs).replace(" ", "%20")
  result.body = resolve(r.body, vs)
  result.bodyFile = resolve(r.bodyFile, vs)
  if result.bodyFile.len > 0 and not result.bodyFile.isAbsolute: result.bodyFile = vs.dir / result.bodyFile
  result.headers = @[]
  for (k, v) in r.headers:
    var x = resolve(v, vs)
    if cmpIgnoreCase(k, "Authorization") == 0 and x.startsWith("Basic "):
      let cred = x[6 .. ^1].strip
      let sp = cred.find(' ')
      if ':' in cred: x = "Basic " & encode(cred)
      elif sp > 0: x = "Basic " & encode(cred[0 ..< sp] & ":" & cred[sp + 1 .. ^1].strip)
    result.headers.add (k, x)

type Here = object
  ok: bool
  req: Req
  vars: Vars
  why: string

proc here(b: Buf): Here =
  ## the request at the cursor, its variables' values in it
  let path = b.path
  let md = b.lang == "markdown" or path.endsWith(".md")
  let lines = httpLines(b.lines, md)
  let r = reqAt(lines, b.cursor.line)
  if r.line < 0:
    result.why = if md: "the cursor is not in an ```http block with a request" else: "there is no request at the cursor"
    return
  result.vars = Vars(file: fileVars(lines), dir: (if path.len > 0: path.parentDir else: projectRoot()))
  try:
    result.req = resolved(r, result.vars)
    result.ok = true
  except ValueError as e:
    result.why = e.msg

func curlCommand(r: Req): string =
  ## the request as a curl command to run yourself
  result = "curl"
  if r.meth == "HEAD": result.add " -I"
  elif r.meth != "GET" or r.body.len > 0 or r.bodyFile.len > 0: result.add " -X " & r.meth
  result.add " " & quoteShell(r.url)
  for (k, v) in r.headers: result.add " -H " & quoteShell(k & ": " & v)
  if r.bodyFile.len > 0: result.add " --data-binary @" & quoteShell(r.bodyFile)
  elif r.body.len > 0: result.add " --data-raw " & quoteShell(r.body)

# ── sending: curl in the background (ned runs it and calls back) ──

var
  running = false
  cancelled = false
  sent: Req
  runDir = ""
  limit = 30
  made: Table[string, Buf]         # the response tabs: their title → the tab

func sizeText(n: int): string =
  ## a size in words: bytes, or KB with one decimal from 1024 on
  if n < 1024: $n & " bytes"
  else:
    let k = n * 10 div 1024
    $(k div 10) & "." & $(k mod 10) & " KB"

func pathOf(url: string): string =
  ## the address's path, without its query
  let s = url.find("://")
  let p = if s >= 0: url.find('/', s + 3) else: -1
  if p < 0: return "/"
  let q = url.find('?', p)
  if q < 0: url[p .. ^1] else: url[p ..< q]

proc responseTab(what, text, lang: string) =
  ## the response in its request's tab (the one before is replaced) — in another when you have changed that one
  var title = "Response: " & what
  var ids: seq[int]
  for x in buffers(): ids.add x.id
  var n = 2
  while title in made and made[title].id in ids and made[title].dirty:
    title = "Response: " & what & " (" & $n & ")"
    inc n
  made[title] = newTab(title, text, lang)

proc finish(output: string, code: int) =
  ## curl has ended: its exit code, what -w wrote (the status, the time)
  running = false
  progressDone()
  let d = runDir
  if cancelled:
    message("REST: the request was cancelled")
    return
  if code != 0:
    let err = if fileExists(d / "err.out"): readFile(d / "err.out").strip else: ""
    case code
    of 28: warn("REST: no answer in " & $limit & " s (plugins.rest-client.timeoutSeconds) from " & sent.url)
    of 6: warn("REST: the host is not known: " & sent.url)
    of 7: warn("REST: nothing answers at " & sent.url)
    of 60: warn("REST: the server's certificate is not trusted (plugins.rest-client.insecure turns the check off)")
    of 127: warn("REST: curl is not installed (on Termux: pkg install curl)")
    else: warn("REST: curl stopped (" & $code & ")" & (if err.len > 0: ": " & err else: ""))
    return
  let meta = output.splitWhitespace
  let status = if meta.len > 0: (try: parseInt(meta[0]) except ValueError: 0) else: 0
  let ms = if meta.len > 1: (try: int(parseFloat(meta[1]) * 1000) except ValueError: 0) else: 0
  # the headers: the last response's (after redirects)
  var head: seq[string]
  if fileExists(d / "headers.out"):
    for l in readFile(d / "headers.out").splitLines:
      let t = l.strip(leading = false, chars = {'\r'})
      if t.startsWith("HTTP/"): head = @[t]
      elif t.len > 0 and head.len > 0: head.add t
  let statusLine = if head.len > 0: head[0] else: "HTTP " & $status
  var hs: seq[(string, string)]
  var ctype = ""
  for l in head[min(1, head.len) .. ^1]:
    let c = l.find(':')
    if c > 0:
      hs.add (l[0 ..< c].strip, l[c + 1 .. ^1].strip)
      if cmpIgnoreCase(l[0 ..< c].strip, "content-type") == 0: ctype = l[c + 1 .. ^1].strip.toLowerAscii
  # (curl -I writes the headers where the body goes: a HEAD request has none)
  let body = if fileExists(d / "body.out") and sent.meth != "HEAD": readFile(d / "body.out") else: ""
  if sent.name.len > 0: responses[sent.name] = Resp(status: status, headers: hs, body: body)
  let about = statusLine & " · " & $ms & " ms · " & sizeText(body.len)
  var shown = body
  var lang = "plaintext"
  var isJson = "json" in ctype or (ctype.len == 0 and body.strip.len > 0 and body.strip[0] in {'{', '['})
  if isJson:
    try: shown = parseJson(body).pretty & "\n"
    except CatchableError: isJson = false
  let binary = '\0' in body or ctype.startsWith("image/") or ctype.startsWith("audio/") or
               ctype.startsWith("video/") or ctype in ["application/octet-stream", "application/pdf", "application/zip"]
  var text = ""
  if isJson:
    lang = "json"
    text = "// " & about & "\n"
    for l in head[min(1, head.len) .. ^1]: text.add "// " & l & "\n"
  else:
    if "html" in ctype or "xml" in ctype: lang = "html"
    text = about & "\n"
    for l in head[min(1, head.len) .. ^1]: text.add l & "\n"
  text.add "\n"
  text.add (if binary: "(" & sizeText(body.len) & " of " & ctype & " — not shown)\n" else: shown)
  let what = if sent.name.len > 0: sent.name
             elif sent.title.len > 0: sent.title
             else: sent.meth & " " & pathOf(sent.url)
  responseTab(what, text, lang)
  message("REST: " & statusLine.splitWhitespace[1 .. ^1].join(" ") & " in " & $ms & " ms")

proc send(b: Buf) =
  ## REST: send the request at the cursor — builds a curl command (method, headers, body or body file, timeout,
  ## redirects, certificate check by the settings) and runs it in the background, writing the body, headers and exit
  ## code to files in the data folder and keeping curl's process number for cancel; finish shows the response
  if running:
    message("REST: a request is still running (REST: cancel the request)")
    return
  let h = here(b)
  if not h.ok:
    warn("REST: " & h.why)
    return
  let r = h.req
  let d = dataDir() / "run"
  writeData("run/.keep", "")                    # (the folder curl writes its answer in: its own data, no permission)
  limit = max(1, setting("timeoutSeconds", 30))
  var args = "curl -sS --max-time " & $limit
  if setting("followRedirects", true): args.add " -L"
  if setting("insecure", false): args.add " -k"
  args.add (if r.meth == "HEAD": " -I" else: " -X " & r.meth)
  for (k, v) in r.headers: args.add " -H " & quoteShell(k & ": " & v)
  if r.bodyFile.len > 0:
    if not fileExists(r.bodyFile):
      warn("REST: there is no file " & r.bodyFile & " (for the body)")
      return
    args.add " --data-binary @" & quoteShell(r.bodyFile)
  elif r.body.len > 0:
    writeData("run/req.body", r.body)
    args.add " --data-binary @req.body"
  args.add " -o body.out -D headers.out -w '%{http_code} %{time_total}' --url " & quoteShell(r.url)
  running = true
  cancelled = false
  sent = r
  runDir = d
  progress("REST: " & r.meth & " " & r.url)
  # (curl's number kept, for REST: cancel the request; its exit code is the command's)
  shellAsync("rm -f body.out headers.out err.out pid.out; " & args & " 2>err.out & echo $! >pid.out; wait $!",
             finish, d)

proc cancel() =
  ## REST: cancel the request — ends the curl that is running; says so when none is
  if not running:
    message("REST: no request is running")
    return
  cancelled = true
  if fileExists(runDir / "pid.out"): discard sh("kill " & readFile(runDir / "pid.out").strip & " 2>/dev/null")

proc copyCurl(b: Buf) =
  ## REST: copy as curl — puts the request at the cursor on the clipboard as a curl command and shows its first 80
  ## characters
  let h = here(b)
  if not h.ok:
    warn("REST: " & h.why)
    return
  let c = curlCommand(h.req)
  setClipboard(c)
  message("Copied: " & (if c.len > 80: c[0 ..< 80] & "…" else: c))

command "REST: send the request at the cursor":
  send(current())
command "REST: copy as curl":
  copyCurl(current())
command "REST: cancel the request":
  cancel()

keyIn("http", "ctrl+alt+r", "send the request") do (b: Buf): send(b)
keyIn("markdown", "ctrl+alt+r", "send the ```http request") do (b: Buf): send(b)
nmapIn("http", "<leader>r", "send the request") do (count: int): send(current())
nmapIn("markdown", "<leader>r", "send the ```http request") do (count: int): send(current())

# ── the language's features: the outline, completion and hover of variables, marks ──

symbols("http") do (b: Buf) -> seq[Symbol]:
  let lines = b.lines
  for (n, v) in fileVars(lines):
    for i, l in lines:
      if l.strip.startsWith("@" & n):
        result.add Symbol(name: "@" & n, kind: "variable", detail: v, line: i)
        break
  for (a, e, title) in parts(lines):
    let r = parseReq(lines, a, e, title)
    if r.line >= 0:
      let name = if r.name.len > 0: r.name elif title.len > 0: title else: r.meth & " " & r.url
      result.add Symbol(name: name, kind: "function", detail: r.meth & " " & r.url, line: r.line)

func openVar(upto: string): int =
  ## where the name after an unclosed {{ starts (-1: none)
  let k = upto.rfind("{{")
  if k < 0 or upto.find("}}", k) >= 0: -1 else: k + 2

completions("http") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  let l = b.line(p.line)
  let s = openVar(l[0 ..< min(p.col, l.len)])
  if s < 0: return
  let typed = l[s ..< p.col].strip(trailing = false)
  var w = typed.len
  while w > 0 and (typed[w - 1] in IdentChars): dec w
  let before = typed[0 ..< w]
  var names: seq[(string, string)]
  for (n, v) in fileVars(b.lines): names.add (n, v)
  for x in [("$timestamp", "now, in seconds since 1970"), ("$guid", "a new GUID"), ("$randomInt 1 100", "a number"),
            ("$datetime iso8601", "now, UTC"), ("$processEnv HOME", "an environment variable"),
            ("$dotenv KEY", "from the .env file beside this one")]: names.add x
  for k, _ in responses: names.add (k & ".response.body.$", "the last response of " & k)
  var seen: seq[string]
  for (n, v) in names:
    if n.startsWith(typed) and n notin seen:
      seen.add n
      result.add CompletionItem(label: n, insert: n[before.len .. ^1], detail: v,
                                kind: (if n.startsWith("$"): "function" else: "variable"))

hover("http") do (b: Buf, p: Pos) -> string:
  let l = b.line(p.line)
  let k = l.rfind("{{", last = min(p.col + 1, l.len - 1))
  let e = if k >= 0: l.find("}}", k) else: -1
  if k < 0 or e < 0 or p.col > e + 1: return ""
  let name = l[k + 2 ..< e].strip
  if name.startsWith("$"): return "**{{" & name & "}}** — made when the request is sent"
  let vs = Vars(file: fileVars(b.lines), dir: b.path.parentDir)
  try: "**{{" & name & "}}** = `" & valueOf(name, vs, 0) & "`"
  except ValueError as x: "**{{" & name & "}}** — " & x.msg

proc mark(b: Buf) =
  ## the variables, their uses and the request names tinted; // comments dimmed
  let lines = b.lines
  b.clearDecorations()
  var n = 0
  for i, l in lines:
    if n > 300: break             # (each one is a call to ned)
    let t = l.strip
    let ind = l.len - l.strip(trailing = false).len
    if t.startsWith("//"):
      b.highlight(rng(pos(i, ind), pos(i, l.len)), "hint")
      inc n
      continue
    if t.startsWith("@"):
      let q = l.find('=')
      if q > 0:
        b.highlight(rng(pos(i, ind), pos(i, q)), "info")
        inc n
    let nm = t.find("@name")
    if t.startsWith("#") and nm >= 0:
      b.highlight(rng(pos(i, ind + nm + 6), pos(i, l.len)), "accent")
      inc n
    var k = l.find("{{")
    while k >= 0:
      let e = l.find("}}", k + 2)
      if e < 0: break
      b.highlight(rng(pos(i, k), pos(i, e + 2)), "accent")
      inc n
      k = l.find("{{", e + 2)

onOpen("lang:http") do (ev: Event): mark(ev.buf)
onChange("lang:http") do (ev: Event): mark(ev.buf)
