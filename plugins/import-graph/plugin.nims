## import-graph — how a Nim project's modules import one another: a Mermaid flowchart and a tree, and who imports a file
##
##   Imports: graph of this project's modules   the project's .nim files (not those in hidden folders, nimcache,
##                               nimbledeps or node_modules) read for their import, from … import and include
##                               lines; a Markdown tab, Imports.md, with a Mermaid flowchart (--> an import, -.-> an
##                               include; the standard library's modules and the nimble packages each in a box of
##                               their own) and the same as a tree of text, from the modules no other one imports
##   Imports: who imports this file   the project's modules that import or include the file you are in: pick one
##                               to go to its line
##   settings                    plugins.import-graph.external — the standard library and the nimble packages in
##                               the graph and the tree (true), or the project's own modules only (false)
##                               plugins.import-graph.direction — the flowchart's direction: LR or TD
##
## A module is found as the compiler would find it: beside the file that imports it, then from the project's
## folder, its src folder, the .nimble file's srcDir and the --path of its config.nims or nim.cfg. A name it does
## not find there is the standard library's (std/os, os) or a nimble package's (pkg/x, karax/vdom).
import nedplugin
import std/[strutils, algorithm, tables, sets]

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "reads the import lines of the project's .nim files with find and awk")

settingDef("external", true, "Imports: graph — show the standard library's modules and the nimble packages " &
           "(apart from the project's), or only the project's own modules")
settingDef("direction", "LR", "Imports: graph — the flowchart's direction: LR (left to right) or TD (top down)")

const StdModules = ["algorithm", "appdirs", "assertions", "async", "asyncdispatch", "asyncfile", "asyncfutures",
  "asynchttpserver", "asyncjs", "asyncmacro", "asyncnet", "asyncstreams", "atomics", "base64", "bitops", "browsers",
  "cgi", "chains", "cmdline", "colors", "compilesettings", "complex", "cookies", "coro", "cpuinfo", "cpuload",
  "critbits", "cstrutils", "decls", "deques", "dirs", "distros", "dom", "dynlib", "editdistance", "effecttraits",
  "encodings", "endians", "enumerate", "enumutils", "envvars", "exitprocs", "fenv", "files", "formatfloat", "genasts",
  "hashes", "heapqueue", "htmlgen", "htmlparser", "httpclient", "httpcore", "importutils", "intsets", "isolation",
  "jsbigints", "jsconsole", "jscore", "jsfetch", "jsffi", "jsformdata", "jsheaders", "json", "jsonutils", "jsre",
  "lenientops", "lexbase", "lists", "locks", "logging", "macrocache", "macros", "marshal", "math", "md5", "memfiles",
  "mimetypes", "monotimes", "nativesockets", "net", "nimprof", "nre", "objectdollar", "oids", "openssl", "options",
  "os", "oserrors", "osproc", "outparams", "packedsets", "parsecfg", "parsecsv", "parsejson", "parseopt",
  "parsesql", "parseutils", "parsexml", "pathnorm", "paths", "pcre", "pegs", "posix", "random", "rationals",
  "rdstdin", "re", "reservedmem", "rlocks", "ropes", "rst", "rstast", "rstgen", "segfaults", "selectors", "sequtils",
  "sets", "setutils", "sha1", "sharedlist", "sharedtables", "socketstreams", "stackframes", "staticos", "stats",
  "strbasics", "streams", "streamwrapper", "strformat", "strmisc", "strscans", "strtabs", "strutils", "sugar",
  "symlinks", "syncio", "sysatomics", "sysrand", "system", "tables", "tasks", "tempfiles", "terminal", "threadpool",
  "times", "typedthreads", "typeinfo", "typetraits", "unicode", "unidecode", "unittest", "uri", "varints",
  "volatile", "widestrs", "winlean", "with", "wordwrap", "wrapnils", "xmlparser", "xmltree"]

let stdSet = StdModules.toHashSet                  # (a lookup in a set: no loop over the list each time)

const SkipDirs = ["nimcache", "nimbledeps", "node_modules"]

type
  Imp* = object
    target*: string              # a module of the project (its path from the project's folder), "std/os" or a package
    kind*: string                # "import" or "include"
    line*: int                   # where (from 0)
    place*: int                  # 0 the project's · 1 the standard library's · 2 a nimble package's
  Module* = object
    path*: string                # from the project's folder
    imps*: seq[Imp]

func plural(n: int, word: string): string = $n & " " & word & (if n == 1: "" else: "s")

func at(s, sub: string, start = 0): int =
  ## where sub is in s, from start (-1: not there) — a plain loop: strutils' find makes a table of 256 entries at
  ## each call, and NimScript counts every turn of a loop against a budget the plugins share
  var i = start
  while i + sub.len <= s.len:
    var k = 0
    while k < sub.len and s[i + k] == sub[k]: inc k
    if k == sub.len: return i
    inc i
  -1

proc nimFiles*(root: string): seq[string] =
  ## the project's .nim files, from its folder (2000 at most)
  var todo = @[root]
  while todo.len > 0 and result.len < 2000:
    let d = todo.pop
    for kind, p in walkDir(d):
      let name = extractFilename(p)
      if kind == pcDir:
        if not name.startsWith(".") and name notin SkipDirs: todo.add p
      elif kind == pcFile and name.endsWith(".nim"):
        result.add p[root.len + 1 .. ^1]
  result.sort()

func codeOf(l: string): string =
  ## the line without its comment
  var q = false
  for i, c in l:
    if c == '"': q = not q
    elif c == '#' and not q: return l[0 ..< i]
  l

type Row* = tuple[line: int, text: string, more: bool]
  ## a line of an import statement, without its comment (more: it goes on from the line before)

func importRows*(text: string): seq[Row] =
  ## the lines that start an import, include or from (not in a """ string), and the lines they go on to: on
  ## while a bracket is open, the line ends with a comma, or the word is alone on its line — as AwkProg does.
  ## (One pass over the text: NimScript's loops have a budget)
  var inStr, open, alone = false
  var depth = 0
  var n = 0
  var i = 0
  while i < text.len:
    var k = i
    while k < text.len and text[k] in {' ', '\t'}: inc k
    var e = k
    var quotes = 0
    while e < text.len and text[e] != '\n':
      if text[e] == '"' and e + 2 < text.len and text[e + 1] == '"' and text[e + 2] == '"':
        inc quotes
        e += 3
      else: inc e
    if quotes mod 2 == 1:
      inStr = not inStr
      open = false
    elif inStr: discard
    elif open:
      let t = codeOf(text[k ..< e]).strip
      result.add (n, t, true)
      if t.len > 0: alone = false
      depth += t.count('[') - t.count(']')
      open = depth > 0 or t.endsWith(",") or alone
    elif k < e and text[k] in {'i', 'f'}:
      let t = codeOf(text[k ..< e]).strip
      for w in ["import", "include", "from"]:
        if t == w or t.startsWith(w & " ") or t.startsWith(w & "\t"):
          result.add (n, t, false)
          depth = t.count('[') - t.count(']')
          alone = t in ["import", "include"]
          open = depth > 0 or t.endsWith(",") or alone
          break
    inc n
    i = e + 1

func statements*(rows: seq[Row]): seq[(string, string, int)] =
  ## the statements the rows make: (import or include, the modules it names, its line) — from x import y is an
  ## import of x
  var raw: seq[(string, string, int)]
  for r in rows:
    if r.more:
      if raw.len > 0 and r.text.len > 0:
        let b = raw[^1][1]
        raw[^1][1] = b & (if b.len == 0 or b.endsWith("[") or b.endsWith(","): "" else: " ") & r.text
      continue
    for w in ["import", "include", "from"]:
      if r.text == w or r.text.startsWith(w & " ") or r.text.startsWith(w & "\t"):
        raw.add (w, r.text[w.len .. ^1].strip, r.line)
        break
  for (w, b, l) in raw:
    if w == "from":
      let k = at(b, " import")
      if k > 0: result.add ("import", b[0 ..< k].strip, l)
    else: result.add (w, b, l)

func modulesIn*(body: string): seq[string] =
  ## the modules a statement names: std/[os, strutils] → std/os, std/strutils; "a b" → a b; x as y → x
  var b = body
  let ex = at(b, " except ")
  if ex > 0: b = b[0 ..< ex]
  var parts: seq[string]
  var depth = 0
  var cur = ""
  for c in b:
    if c == '[': inc depth
    elif c == ']': dec depth
    if c == ',' and depth == 0:
      parts.add cur
      cur = ""
    else: cur.add c
  parts.add cur
  for p0 in parts:
    var p = p0.strip
    let a = at(p, " as ")
    if a > 0: p = p[0 ..< a].strip
    var q = ""
    for c in p:
      if c notin {' ', '"'}: q.add c
    p = q
    if p.len == 0: continue
    let br = p.find('[')
    if br >= 0 and p.endsWith("]"):
      let prefix = p[0 ..< br]
      for x in p[br + 1 ..< p.high].split(','):
        if x.len > 0: result.add prefix & x
    else: result.add p

proc searchRoots*(root: string): seq[string] =
  ## where modules are looked for besides the importing file's folder, from the project's folder: itself (""),
  ## src, the .nimble's srcDir, the --path of config.nims and nim.cfg
  result = @[""]
  proc add(result: var seq[string], root, v: string) =
    var d = normalizedPath(if v.isAbsolute: v else: root / v)
    if d == root: d = ""
    elif d.startsWith(root & "/"): d = d[root.len + 1 .. ^1]
    else: return                                         # (outside the project: none of its modules)
    if d notin result: result.add d
  if dirExists(root / "src"): result.add "src"
  for kind, p in walkDir(root):
    if kind != pcFile: continue
    let name = extractFilename(p)
    if name.endsWith(".nimble"):
      for l in readFile(p).splitLines:
        let t = l.strip
        if t.startsWith("srcDir"):
          let q = t.split('"')
          if q.len >= 2 and q[1].len > 0: add(result, root, q[1])
    elif name in ["config.nims", "nim.cfg"]:
      for l in readFile(p).splitLines:
        let t = l.strip
        var v = ""
        if t.startsWith("--path:") or t.startsWith("--p:"): v = t[t.find(':') + 1 .. ^1]
        elif t.startsWith("switch(\"path\""):
          let q = t.split('"')
          if q.len >= 4: v = q[3]
        elif t.startsWith("path") and (t.find('=') > 0 or t.find(':') > 0):
          v = t[max(t.find('='), t.find(':')) + 1 .. ^1]
        v = v.strip.strip(chars = {'"', '\''})
        if v.len > 0 and '$' notin v: add(result, root, v)

func dirOf(rel: string): string =
  let k = rel.rfind('/')
  if k < 0: "" else: rel[0 ..< k]

proc resolve*(item, fromDir: string, roots: seq[string], known: HashSet[string], isInclude: bool): (string, int) =
  ## the module an item names, from a file in fromDir (both from the project's folder): (a project file's path,
  ## 0), ("std/x", 1) or (a package, 2)
  var name = item
  if name.startsWith("std/") or name.startsWith("system/"): return ("std/" & name.split('/')[^1], 1)
  if name.startsWith("pkg/"): return (name[4 .. ^1].split('/')[0], 2)
  let file = if name.endsWith(".nim") or (isInclude and '.' in name.split('/')[^1]): name else: name & ".nim"
  let dots = file.startsWith(".") or at(file, "/.") >= 0
  for d in @[fromDir] & roots:
    var p = if d.len == 0: file else: d & "/" & file
    if dots: p = normalizedPath(p)
    if p in known: return (p, 0)
  name = name.strip(chars = {'.', '/'})
  let first = name.split('/')[0]
  if name.split('/').len == 1 and name in stdSet: return ("std/" & name, 1)
  (first, 2)

# (the project's .nim files, not in hidden folders, nimcache, nimbledeps or node_modules)
const FindNim* = "find . \\( -type d \\( -name '.?*' -o -name nimcache -o -name nimbledeps -o -name node_modules \\) " &
                "-prune \\) -o -type f -name '*.nim'"
# (importRows in awk: file, line, the text — a + before a line that goes on from the one before)
const AwkProg* = "function code(l) { sub(/#.*/, \"\", l); gsub(/^[ \\t]+|[ \\t]+$/, \"\", l); return l } " &
  "function depth(t,  a, b) { a = gsub(/\\[/, \"[\", t); b = gsub(/\\]/, \"]\", t); return a - b } " &
  "FNR == 1 { str = 0; open = 0 } " &
  "{ q = $0; if (gsub(/\"\"\"/, \"\", q) % 2 == 1) { str = !str; open = 0; next } } " &
  "str { next } " &
  "open { t = code($0); print FILENAME \"\\t\" FNR \"\\t+\" t; if (t != \"\") e = 0; d += depth(t); " &
  "if (!(d > 0 || t ~ /,$/ || e)) open = 0; next } " &
  "/^[ \\t]*(import|include|from)([ \\t]|$)/ { t = code($0); print FILENAME \"\\t\" FNR \"\\t\" t; d = depth(t); " &
  "e = (t ~ /^(import|include)$/); if (d > 0 || t ~ /,$/ || e) open = 1 }"
const VmBytes = 800_000            # (NimScript: what it reads itself at most — its loops have a budget)

proc readModules*(root: string): (seq[Module], bool) =
  ## the project's modules and what each imports — and whether all of them were read (find and awk read them when
  ## the plugin may run programs; else NimScript reads the files, as many as it can)
  var files: seq[string]
  var rows = initTable[string, seq[Row]]()
  var viaShell = false
  var whole = true
  if allowed("shell"):
    let a = shell(FindNim & " -print 2>/dev/null")
    let b = shell(FindNim & " -exec awk '" & AwkProg & "' {} + 2>/dev/null")
    if a.code <= 1 and b.code <= 1 and (a.output.len == 0 or a.output.startsWith("./")):
      viaShell = true
      for l in a.output.splitLines:
        if l.startsWith("./") and files.len < 2000: files.add l[2 .. ^1]
      for l in b.output.splitLines:
        let x = l.find('\t')
        let y = l.find('\t', x + 1)
        if x < 0 or y < 0: continue
        let f = if l.startsWith("./"): l[2 ..< x] else: l[0 ..< x]
        let n = try: parseInt(l[x + 1 ..< y]) - 1 except ValueError: -1
        if n < 0: continue
        let t = l[y + 1 .. ^1]
        let more = t.startsWith("+")
        rows.mgetOrPut(f, @[]).add (n, (if more: t[1 .. ^1] else: t), more)
      files.sort()
  if not viaShell:
    files = nimFiles(root)
    var bytes = 0
    for k, f in files:
      if files.len > 200 and k mod 100 == 0: progress("Imports: reading " & f, k * 100 div files.len)
      let text = readFile(root / f)
      bytes += text.len
      when defined(nimscript):
        if bytes > VmBytes:
          whole = false
          files.setLen(k)
          break
      rows[f] = importRows(text)
    if files.len > 200: progressDone()
  let known = files.toHashSet
  let roots = searchRoots(root)
  var ms: seq[Module]
  for f in files:
    var m = Module(path: f)
    let dir = dirOf(f)
    for (word, body, line) in statements(rows.getOrDefault(f)):
      for it in modulesIn(body):
        let (t, place) = resolve(it, dir, roots, known, word == "include")
        m.imps.add Imp(target: t, kind: word, line: line, place: place)
    ms.add m
  (ms, whole)

proc notWhole(n: int) =
  warn("Imports: only the first " & plural(n, "file") & " were read — NimScript reads so much at most; let the " &
       "plugin run programs (find and awk read them all): Plugins dock › import-graph")

# ── the graph ──

proc mermaid*(ms: seq[Module], external: bool, direction: string): string =
  var ids = initTable[string, string]()
  var lines = @["flowchart " & (if direction.toUpperAscii in ["LR", "RL", "TD", "TB", "BT"]: direction.toUpperAscii
                                else: "LR")]
  for i, m in ms:
    ids[m.path] = "m" & $i
    lines.add "  m" & $i & "[\"" & m.path & "\"]"
  var std, pkgs: seq[string]
  for m in ms:
    for x in m.imps:
      if x.place == 1 and x.target notin std: std.add x.target
      elif x.place == 2 and x.target notin pkgs: pkgs.add x.target
  std.sort()
  pkgs.sort()
  if external:
    if std.len > 0:
      lines.add "  subgraph std [Standard library]"
      for i, s in std:
        ids[s] = "s" & $i
        lines.add "    s" & $i & "[\"" & s[4 .. ^1] & "\"]"
      lines.add "  end"
    if pkgs.len > 0:
      lines.add "  subgraph pkgs [Nimble packages]"
      for i, s in pkgs:
        ids["pkg:" & s] = "p" & $i
        lines.add "    p" & $i & "[\"" & s & "\"]"
      lines.add "  end"
  var seen = initHashSet[string]()
  for m in ms:
    for x in m.imps:
      if x.place != 0 and not external: continue
      let key = if x.place == 2: "pkg:" & x.target else: x.target
      if key notin ids: continue
      let edge = "  " & ids[m.path] & (if x.kind == "include": " -.->|include| " else: " --> ") & ids[key]
      if edge notin seen:
        seen.incl edge
        lines.add edge
  lines.join("\n")

proc tree*(ms: seq[Module], external: bool): string =
  ## the modules as a tree of text, from those no module of the project imports
  var byPath = initTable[string, int]()
  for i, m in ms: byPath[m.path] = i
  var imported = initHashSet[string]()
  for m in ms:
    for x in m.imps:
      if x.place == 0 and x.target != m.path: imported.incl x.target
  var res: seq[string]
  var shown = initHashSet[string]()
  proc walk(i: int, prefix: string, onPath: var seq[string]) =
    let m = ms[i]
    var kids: seq[(string, string)]                     # (its path, what the tree shows)
    var seenKid: seq[string]
    for x in m.imps:
      if x.place == 0 and x.target in byPath and x.target notin seenKid:
        seenKid.add x.target
        kids.add (x.target, x.target & (if x.kind == "include": " (include)" else: ""))
    var outside: seq[string]
    if external:
      var std, pkgs: seq[string]
      for x in m.imps:
        if x.place == 1 and x.target[4 .. ^1] notin std: std.add x.target[4 .. ^1]
        elif x.place == 2 and x.target notin pkgs: pkgs.add x.target
      if std.len > 0: outside.add "std: " & std.join(", ")
      if pkgs.len > 0: outside.add "packages: " & pkgs.join(", ")
    let n = kids.len + outside.len
    for k, (path, kid) in kids:
      let last = k == n - 1
      var line = prefix & (if last: "└── " else: "├── ") & kid
      if path in onPath:
        res.add line & " — a cycle"
      elif path in shown:
        res.add line & " (above)"
      else:
        res.add line
        shown.incl path
        onPath.add path
        walk(byPath[path], prefix & (if last: "    " else: "│   "), onPath)
        discard onPath.pop
    for k, o in outside:
      res.add prefix & (if kids.len + k == n - 1: "└── " else: "├── ") & o
  var starts: seq[int]
  for i, m in ms:
    if m.path notin imported: starts.add i
  for i, m in ms:
    if m.path in imported: starts.add i                  # (modules only a cycle reaches: after the others)
  for i in starts:
    if ms[i].path in shown: continue
    shown.incl ms[i].path
    res.add ms[i].path
    var onPath = @[ms[i].path]
    walk(i, "", onPath)
  res.join("\n")

proc graphNow() =
  let root = projectRoot()
  if root.len == 0 or not dirExists(root):
    message("Imports: open a project's folder first")
    return
  let (ms, whole) = readModules(root)
  if ms.len == 0:
    message("Imports: no .nim files in " & root)
    return
  let external = setting("external", true)
  var edges, std, pkgs = 0
  var seenStd, seenPkg: HashSet[string]
  for m in ms:
    for x in m.imps:
      case x.place
      of 0: inc edges
      of 1:
        if x.target notin seenStd:
          seenStd.incl x.target
          inc std
      else:
        if x.target notin seenPkg:
          seenPkg.incl x.target
          inc pkgs
  var text = "# The imports of " & extractFilename(root) & "\n\n" & plural(ms.len, "module") & ", " &
             plural(edges, "import") & " between them"
  text.add (if external: "; " & plural(std, "module") & " of the standard library and " &
                         plural(pkgs, "nimble package") & " besides." else: " (the standard library and the nimble " &
                         "packages left out).")
  text.add "\n\n```mermaid\n" & mermaid(ms, external, setting("direction", "LR")) & "\n```\n\n## As a tree\n\n" &
           "```text\n" & tree(ms, external) & "\n```\n"
  discard newTab("Imports.md", text, "markdown")
  if whole: message("Imports: " & plural(ms.len, "module") & ", " & plural(edges, "import") & " — in Imports.md")
  else: notWhole(ms.len)

proc whoImports() =
  let b = current()
  let root = projectRoot()
  let p = if b.valid: b.path else: ""
  if p.len == 0 or not p.endsWith(".nim"):
    message("Imports: open a .nim file of the project first")
    return
  if not p.startsWith(root & "/"):
    message("Imports: " & extractFilename(p) & " is not in the project's folder")
    return
  let rel = p[root.len + 1 .. ^1]
  var names, details: seq[string]
  var at: seq[(string, int)]
  let (ms, whole) = readModules(root)
  if not whole: notWhole(ms.len)
  for m in ms:
    for x in m.imps:
      if x.place == 0 and x.target == rel and m.path != rel:
        names.add m.path
        details.add "line " & $(x.line + 1) & (if x.kind == "include": " · include" else: "")
        at.add (m.path, x.line)
  if names.len == 0:
    message("Imports: no module of the project imports " & rel)
    return
  let i = pick(plural(names.len, "module") & " import " & extractFilename(rel), names, details)
  if i >= 0 and i < at.len: discard openFile(root / at[i][0], at[i][1])

command "Imports: graph of this project's modules":
  graphNow()

command "Imports: who imports this file":
  whoImports()
