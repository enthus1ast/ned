## web-routes — the routes of a Jester or Prologue web app: listed by method and path, each a tap from its handler
##
##   Web routes: list…          every route of the project — GET /users/@id, POST /login … — to choose from; the one
##                              chosen opens at its handler: Jester's block under the route, or the proc Prologue
##                              calls (where the route is added when the proc is not found)
##   Web routes: as a table     the routes in a Markdown table, in a tab: method, path, handler, where
##   the Plugins dock           WEB ROUTES: the routes, file by file — tap one to go to its handler; ↻ reads the
##                              files again (saving a .nim file does it too)
##   the assistant              web_routes, a tool that lists them (it only reads)
##
## What it reads, in the project's .nim files (the open ones as they are in their tabs):
## - Jester: the `routes:` and `router name:` blocks — get, post, put, delete, patch, head, options, trace, connect
##   and any, with a "/path", a re"…" or a r"…", and `error Http404:` —, and `extend name, "/prefix"`, which puts a
##   router's routes under a prefix;
## - Prologue: `app.get("/", home)` (post, put, delete, patch, head, options, all), `app.addRoute("/x", handler,
##   HttpPost)` (a method or a list of them, GET when none), `pattern("/x", handler, @[HttpGet, HttpPost])` in a
##   list, and `app.addRoute(urlPatterns, "/prefix")`, which adds a list under a prefix.
## A route made by code of your own (in a loop, from a table) is not seen. It needs nothing installed.
import nedplugin
import std/[algorithm, tables]

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("maxFiles", 3000, "Web routes: the most .nim files read in a project")

const
  View = "WEB ROUTES"
  JesterVerbs = ["get", "post", "put", "delete", "patch", "head", "options", "trace", "connect", "any"]
  PrologueVerbs = ["get", "post", "put", "delete", "patch", "head", "options", "trace", "connect", "all"]
  SkipDirs = ["nimcache", "node_modules", "htmldocs", "nimbledeps", "vendor", "build", "dist"]

type
  Route* = object
    meth*, path*: string        # GET, /users/@id (a regular expression as written: re"^/x$")
    handler*: string            # the proc Prologue calls ("" for Jester's block)
    framework*: string          # Jester, Prologue
    file*: string               # where the route is (relative to the project)
    line*: int                  # … its line (from 0)
    goFile*: string             # where its handler is (its block, or its proc)
    goLine*: int
    group*: string              # a Jester router or a Prologue list it belongs to ("" none)
  Unit = object                 # one file's findings, before the prefixes are put in
    routes: seq[Route]
    extends: seq[(string, string)]    # (router or list, prefix)
    procs: seq[(string, int, bool)]   # (name, line, takes a Context)

# ── reading a file ──

func indentOf(s: string): int =
  ## the number of spaces and tabs at the start of the line
  while result < s.len and s[result] in {' ', '\t'}: inc result

func identAt(s: string, i: int): string =
  ## the name (letters, digits and `_`) that starts at `i`, empty when there is none
  var e = i
  while e < s.len and s[e] in {'a'..'z', 'A'..'Z', '0'..'9', '_'}: inc e
  s[i ..< e]

func literalAt*(s: string, i: int): (string, int) =
  ## the string literal at i — "…", r"…", re"…", re2"…", rex"…" — as the path it is ("" when there is none: an
  ## identifier, a call) and where it ends
  var j = i
  var prefix = ""
  while j < s.len and s[j] in {'a'..'z', '0'..'9'}:
    prefix.add s[j]
    inc j
  if j >= s.len or s[j] != '"' or prefix notin ["", "r", "re", "re2", "rex"]: return ("", i)
  let raw = prefix.len > 0
  inc j
  var v = ""
  while j < s.len and s[j] != '"':
    if s[j] == '\\' and not raw and j + 1 < s.len:
      v.add s[j + 1]
      j += 2
      continue
    v.add s[j]
    inc j
  if j >= s.len: return ("", i)
  ((if prefix in ["re", "re2", "rex"]: prefix & "\"" & v & "\"" else: v), j + 1)

func splitArgs*(s: string): seq[string] =
  ## a call's arguments, at the commas outside brackets and strings
  var depth = 0
  var cur = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '"':
      let a = i
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\': inc i
        inc i
      cur.add s[a .. min(i, s.len - 1)]
    elif c in {'(', '[', '{'}:
      inc depth
      cur.add c
    elif c in {')', ']', '}'}:
      dec depth
      cur.add c
    elif c == ',' and depth == 0:
      result.add cur.strip
      cur = ""
    else: cur.add c
    inc i
  if cur.strip.len > 0: result.add cur.strip

func callArgs(lines: seq[string], ln, open: int): string =
  ## the text between the ( at lines[ln][open] and its ), over the lines below too (10 at most)
  var depth = 0
  var l = ln
  var i = open
  var inStr = false
  while l < lines.len and l < ln + 10:
    let s = lines[l]
    while i < s.len:
      let c = s[i]
      if inStr:
        if c == '\\': inc i
        elif c == '"': inStr = false
        result.add c
      elif c == '"':
        inStr = true
        result.add c
      elif c == '#':
        break
      elif c in {'(', '['}:
        inc depth
        if depth > 1 or c != '(': result.add c
      elif c in {')', ']'}:
        dec depth
        if depth == 0: return
        result.add c
      elif depth > 0: result.add c
      inc i
    result.add ' '
    inc l
    i = 0

func methodsOf(arg: string): seq[string] =
  ## HttpPost, @[HttpGet, HttpPost] → POST; GET POST
  var i = 0
  while true:
    i = arg.find("Http", i)
    if i < 0: break
    let w = identAt(arg, i)
    if w.len > 4: result.add w[4 .. ^1].toUpperAscii
    i += max(1, w.len)

func lastName(s: string): string =
  ## views.index → index; a bare name as it is ("" for anything else)
  let t = s.strip
  let k = t.rfind('.')
  let n = if k >= 0: t[k + 1 .. ^1] else: t
  if n.len > 0 and n.identAt(0) == n: n else: ""

func readUnit*(file: string, lines: seq[string]): Unit =
  ## the routes of one file, its prefixes (Jester's extend, Prologue's lists added under a prefix) and its procs
  var jIndent = -1                 # inside a routes: (router …:) block: its indentation …
  var jBody = -1                   # … and the indentation of its routes
  var jRouter = ""
  var group = ""                   # a list of Prologue's patterns being read: its name …
  var groupDepth = 0               # … and its brackets still open
  for ln, s in lines:
    let t = s.strip
    let ind = indentOf(s)
    if t.len == 0 or t.startsWith("#"): continue
    # procs: where a handler is
    for kw in ["proc ", "func "]:
      if t.startsWith(kw):
        let n = identAt(t, kw.len)
        if n.len > 0: result.procs.add (n, ln, "Context" in t or "Request" in t)
    # Jester: a routes: or router name: block
    if jIndent >= 0 and ind <= jIndent:
      jIndent = -1
      jBody = -1
    if t == "routes:" or (t.startsWith("router ") and t.endsWith(":")):
      jIndent = ind
      jBody = -1
      jRouter = if t == "routes:": "" else: t[7 ..< ^1].strip
      continue
    if jIndent >= 0:
      if jBody < 0: jBody = ind
      if ind == jBody:
        let w = identAt(t, 0)
        if w in JesterVerbs:
          var k = w.len
          while k < t.len and t[k] == ' ': inc k
          let (path, _) = literalAt(t, k)
          if path.len > 0:
            result.routes.add Route(meth: w.toUpperAscii, path: path, framework: "Jester", file: file, line: ln,
                                    goFile: file, goLine: min(ln + 1, lines.high), group: jRouter)
        elif w == "error" and t.endsWith(":"):
          result.routes.add Route(meth: "ERROR", path: t[6 ..< ^1].strip, framework: "Jester", file: file, line: ln,
                                  goFile: file, goLine: min(ln + 1, lines.high), group: jRouter)
        elif w == "extend":
          let parts = splitArgs(t[6 .. ^1])
          if parts.len >= 2:
            let (prefix, _) = literalAt(parts[1], 0)
            result.extends.add (parts[0], prefix)
      continue
    # Prologue: a list of patterns (let urlPatterns* = @[ …), on this line or over several
    let at = t.find("@[")
    if at > 0 and '=' in t[0 ..< at] and group.len == 0:
      var w = t
      for kw in ["let ", "const ", "var "]:
        if w.startsWith(kw): w = w[kw.len .. ^1].strip
      let n = identAt(w, 0)
      if n.len > 0:
        group = n
        groupDepth = t[at .. ^1].count('[') - t[at .. ^1].count(']')
    elif group.len > 0:
      groupDepth += s.count('[') - s.count(']')
    # Prologue: pattern(…), x.addRoute(…), x.get(…) …
    var i = 0
    while i < s.len:
      if s[i] == '#': break
      if s[i] == '"':                          # (not in a string)
        inc i
        while i < s.len and s[i] != '"':
          if s[i] == '\\': inc i
          inc i
        inc i
        continue
      let w = if s[i] in {'a'..'z', 'A'..'Z'} and (i == 0 or s[i - 1] notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}):
                identAt(s, i) else: ""
      if w.len == 0:
        inc i
        continue
      let open = i + w.len
      let dotted = i > 0 and s[i - 1] == '.'
      if open < s.len and s[open] == '(' and (w == "pattern" or (dotted and (w == "addRoute" or w in PrologueVerbs))):
        let args = splitArgs(callArgs(lines, ln, open))
        if args.len >= 1:
          let (path, _) = literalAt(args[0], 0)
          if path.len > 0 and (path.startsWith("/") or path.startsWith("re")) and args.len >= 2:
            var ms: seq[string]
            if w in PrologueVerbs: ms = @[(if w == "all": "ANY" else: w.toUpperAscii)]
            elif args.len >= 3 and not args[2].startsWith("name") and not args[2].startsWith("middlewares"):
              ms = methodsOf(args[2])
            if ms.len == 0: ms = @["GET"]
            result.routes.add Route(meth: ms.join(" "), path: path, handler: lastName(args[1]),
                                    framework: "Prologue", file: file, line: ln, goFile: file, goLine: ln,
                                    group: (if w == "pattern": group else: ""))
          elif w == "addRoute" and path.len == 0 and args.len >= 2:
            let (prefix, _) = literalAt(args[1], 0)
            let n = lastName(args[0])
            if n.len > 0 and args[1].strip.startsWith("\""): result.extends.add (n, prefix)
      i = open
    if group.len > 0 and groupDepth <= 0: group = ""       # (the list ends on this line)

# ── the project ──

proc nimFiles(root: string, limit: int): seq[string] =
  ## the project's .nim files (relative), in order, `limit` at most
  var todo = @[root]
  while todo.len > 0 and result.len < limit:
    let d = todo.pop
    for kind, p in walkDir(d):
      let name = extractFilename(p)
      if kind in {pcDir, pcLinkToDir}:
        if not name.startsWith(".") and name notin SkipDirs: todo.add p
      elif kind in {pcFile, pcLinkToFile} and name.endsWith(".nim"):
        result.add p[root.len + 1 .. ^1]
  result.sort()

func joinPrefix(prefix, path: string): string =
  ## a route's path put under a prefix, with one `/` between them (the prefix alone for the path /); a regular
  ## expression path is left as it is
  if prefix.len == 0 or path.startsWith("re"): return path
  if path == "/": return prefix
  prefix.strip(leading = false, chars = {'/'}) & "/" & path.strip(trailing = false, chars = {'/'})

func resolve*(units: seq[Unit]): seq[Route] =
  ## the routes with their prefixes put in: a Jester router's under each `extend` of it, a Prologue list's under each
  ## addRoute that adds it — one never added stays as it is
  var extends: seq[(string, string)]
  for u in units: extends.add u.extends
  for u in units:
    for r in u.routes:
      var put = false
      if r.group.len > 0:
        for (g, prefix) in extends:
          if g == r.group:
            var y = r
            y.path = joinPrefix(prefix, r.path)
            result.add y
            put = true
      if not put: result.add r

proc readProject*(): seq[Route] =
  ## every route of the project: the files read (the open ones as they are now), the prefixes put in, the
  ## handlers found
  let root = projectRoot()
  var open: Table[string, seq[string]]
  for b in buffers():
    let p = b.path
    if p.endsWith(".nim") and p.startsWith(root & "/"): open[p[root.len + 1 .. ^1]] = b.lines
  var units: seq[Unit]
  var procs: Table[string, (string, int, bool)]
  let files = nimFiles(root, setting("maxFiles", 3000))
  for f in files:
    var ls: seq[string]
    if f in open: ls = open[f]
    else:
      let text = readFile(root / f)
      # (a quick look first: most files have no routes)
      if "routes:" notin text and "router " notin text and "addRoute" notin text and "pattern(" notin text and
         ".get(\"" notin text and ".post(\"" notin text and "Context" notin text:
        continue
      ls = text.splitLines
    let u = readUnit(f, ls)
    for (n, l, ctx) in u.procs:
      if n notin procs or (ctx and not procs[n][2]): procs[n] = (f, l, ctx)
    if u.routes.len > 0 or u.extends.len > 0: units.add u
  result = resolve(units)
  for r in result.mitems:
    if r.handler.len > 0 and r.handler in procs:
      r.goFile = procs[r.handler][0]
      r.goLine = procs[r.handler][1]

var
  cache: seq[Route]
  cached = false

proc routes(): seq[Route] =
  ## the project's routes, read once and kept until something clears the cache (a listing, a save of a .nim file)
  if not cached:
    cache = readProject()
    cached = true
  cache

# how a route is listed: its method in a column of six, then its path
func label(r: Route): string = alignLeft(r.meth, 6) & " " & r.path

func whereOf(r: Route): string =
  ## where a route is written: its handler (Prologue) and file:line
  (if r.handler.len > 0: r.handler & " — " else: "") & r.file & ":" & $(r.line + 1)

func table*(rs: seq[Route]): string =
  ## the routes as a Markdown page with a table of method, path, handler and place (the line numbers from 1), or a note
  ## on what is read when there are none
  result = "# Web routes\n\n"
  if rs.len == 0:
    return result & "No routes found: Jester's `routes:` blocks and Prologue's `addRoute`, `get`, `post` … and " &
                    "`pattern` calls are read in the project's .nim files.\n"
  result.add "| method | path | handler | where |\n|---|---|---|---|\n"
  for r in rs:
    result.add "| " & r.meth & " | `" & r.path.replace("|", "\\|") & "` | " &
               (if r.handler.len > 0: "`" & r.handler & "`" else: "(its block)") & " | " & r.file & ":" &
               $(r.line + 1) & " |\n"

# opens the file at the route's handler — Jester's block, or the proc Prologue calls
proc go(r: Route) = discard openFile(r.goFile, r.goLine)

proc listRoutes() =
  ## Web routes: list — reads the project again and lets the person pick a route, sorted by path and method with its
  ## framework and place beside it; the one picked is opened at its handler
  cached = false
  let rs = routes()
  if rs.len == 0:
    message("Web routes: none found in the project's .nim files (Jester's routes:, Prologue's addRoute, get, post …)")
    return
  var sorted = rs
  sorted.sort(proc(a, b: Route): int = cmp((a.path, a.meth), (b.path, b.meth)))
  var items, details: seq[string]
  for r in sorted:
    items.add label(r)
    details.add r.framework & " · " & whereOf(r)
  let i = pick("Web routes (" & $rs.len & ")", items, details)
  if i >= 0: go(sorted[i])

command "Web routes: list…":
  listRoutes()

command "Web routes: as a table":
  cached = false
  discard newTab("Web routes", table(routes()), "markdown")

view(View) do () -> seq[ViewItem]:
  let rs = routes()
  let root = projectRoot()
  result.add ViewItem(text: "Read them again", icon: "↻", color: "accent", id: "refresh",
                      detail: $rs.len & " route" & (if rs.len == 1: "" else: "s"))
  var last = ""
  for r in rs:
    if r.file != last:
      result.add ViewItem(text: r.file, icon: "▸", detail: r.framework)
      last = r.file
    result.add ViewItem(text: label(r), detail: (if r.handler.len > 0: r.handler else: "line " & $(r.line + 1)),
                        icon: "•", path: root / r.goFile, line: r.goLine, depth: 1)
do (id: string):
  if id == "refresh":
    cached = false
    refreshView(View)

onSave("*.nim") do (ev: Event):
  # (read again when the dock next shows them)
  if cached:
    cached = false
    refreshView(View)

aiToolReadOnly("web_routes", "The HTTP routes of the project's Jester or Prologue web app: each one's method, path, " &
               "handler and where it is (file:line)", %*{}) do (args: JsonNode) -> string:
  cached = false
  table(routes())
