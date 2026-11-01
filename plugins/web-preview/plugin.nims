## web-preview — the page you are writing in a browser: the file opened as it is, or served from the project's
## folder (so its links, scripts and fetches work), and the address at the cursor opened
##
##   Web: open this file in the browser   the HTML (or SVG, Markdown's HTML, any file a browser shows) as a file
##                                  — on Termux with termux-open, elsewhere xdg-open, open (macOS) or start
##   Web: serve the project and open this page   a web server for the project's folder in a terminal (python3's
##                                  http.server, on plugins.web-preview.port), and the page opened from it:
##                                  http://localhost:8000/docs/index.html — a second time, the same server
##   Web: open the address at the cursor   the http(s) URL under the cursor (or the selection) in the browser
##   Web: stop the server           (it is the terminal's: close it there, or this ends it)
## Settings: plugins.web-preview.port (8000), plugins.web-preview.browser (the program that opens a page: empty
## for the system's own).
import nedplugin
import std/strutils

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "opens pages with the system's browser and starts a web server for the project")

settingDef("port", 8000, "Web: serve the project — the port of the web server")
settingDef("browser", "", "The program that opens a page (empty: termux-open, xdg-open, open or start)")

var serving = false

# the text quoted for the shell, in single quotes (a quote inside it written as '\'')
func q(s: string): string = "'" & s.replace("'", "'\\''") & "'"

proc opener(): string =
  ## the program that opens a file or an address in the browser
  let b = setting("browser", "").strip
  if b.len > 0: return b
  for (exe, cmd) in [("termux-open-url", ""), ("termux-open", "termux-open"), ("xdg-open", "xdg-open"),
                     ("open", "open"), ("wslview", "wslview")]:
    if cmd.len > 0 and findExe(exe).len > 0: return cmd
  when defined(windows): "start \"\""
  else: ""

proc openInBrowser(target: string) =
  ## opens a file or an address with the browser opener, started in the background (on Termux an address goes to
  ## termux-open-url and a file to termux-open); it warns when no program can open it and says what it opened in the
  ## status bar
  var o = opener()
  # (Termux: an address goes to termux-open-url, a file to termux-open)
  if o == "termux-open" and (target.startsWith("http://") or target.startsWith("https://")) and
     findExe("termux-open-url").len > 0: o = "termux-open-url"
  if o.len == 0:
    warn("No program opens a browser here — set plugins.web-preview.browser (firefox, chromium …)")
    return
  let r = shell(o & " " & q(target) & " >/dev/null 2>&1 &")
  if r.code != 0: warn("Could not open it: " & r.output.strip)
  else: status("Opened " & target)

proc openFileHere() =
  ## Web: open this file in the browser — saves the file when it has changes and opens it by its path; a file with no
  ## path is not opened
  let b = current()
  let p = b.path
  if p.len == 0:
    message("Save the file first: the browser opens a file")
    return
  if b.dirty: b.save()
  openInBrowser(p)

func urlPath*(root, file: string): string =
  ## a file of the project as the server shows it: /docs/index.html
  var rel = file
  if root.len > 0 and file.startsWith(root & "/"): rel = file[root.len + 1 .. ^1]
  "/" & rel.replace(" ", "%20")

proc serveAndOpen() =
  ## Web: serve the project and open this page — saves the file, starts python's http.server on plugins.web-preview.port
  ## for the project's folder in a terminal (only once, then the same server is used) and, after 700 ms for the server
  ## to start, opens the page from http://localhost, or the server's root for a file outside the project
  let b = current()
  let root = projectRoot()
  let port = setting("port", 8000)
  if b.dirty: b.save()
  if not serving:
    let py = if findExe("python3").len > 0: "python3" elif findExe("python").len > 0: "python" else: ""
    if py.len == 0:
      warn("The web server is python3's: it is not installed (Termux: pkg install python)")
      return
    runInTerminal(py & " -m http.server " & $port & " --bind 127.0.0.1", root)
    serving = true
  let page = if b.path.len > 0 and b.path.startsWith(root): urlPath(root, b.path) else: "/"
  let url = "http://localhost:" & $port & page
  # (the server needs a moment to start: the page opens after it)
  discard after(700, proc() = openInBrowser(url))
  message("Serving " & root & " on " & $port & " — " & url)

func urlAt*(s: string, col: int): string =
  ## the http(s) address a column of the line is in ("" none)
  var k = s.find("http")
  while k >= 0:
    if s.continuesWith("http://", k) or s.continuesWith("https://", k):
      var e = k
      while e < s.len and s[e] notin {' ', '\t', '"', '\'', '<', '>', ')', ']', '`'}: inc e
      while e > k and s[e - 1] in {'.', ',', ';', ':'}: dec e
      if col >= k and col <= e: return s[k ..< e]
      k = s.find("http", e)
    else: k = s.find("http", k + 4)
  ""

proc openUrlHere() =
  ## Web: open the address at the cursor — opens the selection, else the http(s) address under the cursor, in the
  ## browser
  let b = current()
  let r = b.selection
  let u = if not r.isEmpty: b.textIn(r).strip else: urlAt(b.line(b.cursor.line), b.cursor.col)
  if u.len == 0: message("No address under the cursor")
  else: openInBrowser(u)

command "Web: open this file in the browser":
  openFileHere()

command "Web: serve the project and open this page":
  serveAndOpen()

command "Web: open the address at the cursor":
  openUrlHere()

command "Web: stop the server":
  if serving:
    discard shell("pkill -f 'http.server " & $setting("port", 8000) & "' 2>/dev/null")
    serving = false
    message("The web server is stopped")
  else: message("No web server of this plugin is running")
