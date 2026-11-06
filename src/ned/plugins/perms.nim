# ── plugin permissions: what a plugin may do beyond editing — run programs, use the network, change files, read
#    and set the clipboard. ned reads a plugin's source before it runs it (what it uses, and what it says it needs
#    and why), asks you once, and refuses at run time what was not allowed ──

type PlugPerm = enum ppShell = "shell", ppNetwork = "network", ppFiles = "files", ppClipboard = "clipboard"

const
  PlugPermWhat: array[PlugPerm, string] = [
    "run programs (a program can do anything you can, the network too)",
    "use the network",
    "change files — write, move or delete them (not only its own data)",
    "read and set the clipboard"]
  PlugPermShort: array[PlugPerm, string] = ["run programs", "use the network", "change files", "use the clipboard"]

func plugIdentNorm(s: string): string =
  ## a Nim name as Nim compares them: the first letter as it is, the rest without case or underscores
  if s.len == 0: return
  result.add s[0]
  for c in s[1 .. ^1]:
    if c != '_': result.add toLowerAscii(c)

const
  # (the names normalised as plugIdentNorm makes them)
  PlugUsesShell = ["shell", "shellasync", "exec", "gorgeex", "gorge", "staticexec", "selfexec", "execcmd",
                   "execcmdex", "execprocess", "execprocesses", "startprocess", "execshellcmd", "runinterminal"]
  PlugUsesNet = ["newsocket", "newhttpclient", "newasynchttpclient", "newasyncsocket"]
  # (modules: when imported)
  PlugModShell = ["osproc"]
  PlugModNet = ["net", "httpclient", "asyncnet", "asynchttpserver", "nativesockets", "smtp", "asyncftpclient"]
  PlugModAll = ["posix", "winlean", "dynlib", "ssl", "openssl"]
  PlugUsesFiles = ["writefile", "appendfile", "rmfile", "rmdir", "mvfile", "mvdir", "cpfile", "cpdir", "mkdir",
                   "removefile", "removedir", "movefile", "movedir", "copyfile", "copydir", "copyfilewithpermissions",
                   "copydirwithpermissions", "createdir", "existsorcreatedir", "setfilepermissions", "putenv",
                   "delenv", "createsymlink", "createhardlink", "fmwrite", "fmappend", "fmreadwrite",
                   "fmreadwriteexisting", "tryremovefile", "setcurrentdir"]
  PlugUsesClip = ["clipboard", "setclipboard"]
  # what makes code ned cannot read before it runs (names from text, foreign code), or reaches past the plugin
  # library to the host: taken as asking for everything
  PlugUsesAll = ["asm", "curPlugin", "curplugin"]
  # (pragmas: inside {. .})
  PlugPragmaAll = ["importc", "importcpp", "importjs", "importobjc", "emit", "dynlib", "compile", "passl", "passc",
                   "link", "header", "codegendecl"]
  PlugUsesAllMacros = ["parsestmt", "parseexpr", "ident", "newidentnode", "bindsym"]

type PlugScan = object
  uses: set[PlugPerm]
  seen: array[PlugPerm, string]          # where each was first seen: "plugin.nims:43 gorgeEx"
  why: array[PlugPerm, string]           # what the plugin says it needs it for (permission "shell", "…")
  progs: bool                            # it gives ned programs to run: a language's run, build or check command,
                                         # a formatter, a language server
  ownShell: bool                         # it runs programs itself (or may do anything)

func progOnly(sc: PlugScan): bool = sc.progs and not sc.ownShell
  ## "shell" only for the programs ned runs for it

func plugProgLine(t: string): string =
  ## a line that gives ned a program to run for the plugin: what it is ("" none) — a language server
  ## (languageServer, not a script), a formatter command (formatter "lang", "cmd"), a language's run, build or
  ## check command (run: "…", .build = "…")
  var i = t.find("languageServer")
  if i >= 0 and not t.continuesWith("languageServerScript", i): return "languageServer"
  i = t.find("formatter")
  if i >= 0 and t.count('"') - t[0 ..< i].count('"') >= 4: return "formatter"
  for kw in ["run", "build", "check"]:
    var k = 0
    while true:
      k = t.find(kw, k)
      if k < 0: break
      let before = if k > 0: t[k - 1] else: ' '
      var j = k + kw.len
      if before notin IdentChars:
        while j < t.len and t[j] == ' ': inc j
        if j < t.len and t[j] in {':', '='}:
          inc j
          while j < t.len and t[j] == ' ': inc j
          if j < t.len and t[j] == '"': return kw & " command"
      k += kw.len
  ""

proc plugScanText(name, text: string, sc: var PlugScan) =
  ## one source file: its names outside comments and strings, its imports, its permission "…", "…" lines
  var i = 0
  var line = 1
  var words: seq[(string, int, bool)]     # (the name as written, its line, in a pragma {. .})
  var strs: seq[(string, int)]            # (a string's text, its line)
  var lastWord = ""
  var pragma = 0
  let n = text.len
  while i < n:
    let c = text[i]
    if c == '\n':
      inc line
      inc i
    elif c == '#':
      if i + 1 < n and text[i + 1] == '[' or (i + 2 < n and text[i + 1] == '#' and text[i + 2] == '['):
        var depth = 0
        while i < n:
          if text[i] == '\n': inc line
          if text[i] == '#' and i + 1 < n and text[i + 1] == '[':
            inc depth
            i += 2
            continue
          if text[i] == ']' and i + 1 < n and text[i + 1] == '#':
            dec depth
            i += 2
            if depth == 0: break
            continue
          inc i
      else:
        while i < n and text[i] != '\n': inc i
    elif c == '"':
      let raw = lastWord.len > 0 and i > 0 and text[i - 1] in IdentChars      # (r"…", a generalised raw string)
      var s = ""
      let at = line
      if i + 2 < n and text[i + 1] == '"' and text[i + 2] == '"':
        i += 3
        while i < n and not (text[i] == '"' and i + 2 < n and text[i + 1] == '"' and text[i + 2] == '"'):
          if text[i] == '\n': inc line
          s.add text[i]
          inc i
        i += 3
        while i < n and text[i] == '"': inc i
      else:
        inc i
        while i < n and text[i] != '\n':
          if text[i] == '\\' and not raw and i + 1 < n:
            s.add text[i + 1]
            i += 2
            continue
          if text[i] == '"':
            if raw and i + 1 < n and text[i + 1] == '"':
              s.add '"'
              i += 2
              continue
            break
          s.add text[i]
          inc i
        inc i
      strs.add (s, at)
      lastWord = ""
    elif c == '\'':
      if i > 0 and text[i - 1] in IdentChars: inc i      # (1'i32: a number's type)
      else:
        inc i
        if i < n and text[i] == '\\': i += 2
        while i < n and text[i] notin {'\'', '\n'}: inc i
        inc i
    elif c == '`':
      let a = i + 1
      var e = a
      while e < n and text[e] notin {'`', '\n'}: inc e
      words.add (text[a ..< e], line, pragma > 0)
      lastWord = text[a ..< e]
      i = e + 1
    elif c in IdentStartChars or ord(c) >= 0x80:
      let a = i
      while i < n and (text[i] in IdentChars or ord(text[i]) >= 0x80): inc i
      lastWord = text[a ..< i]
      if lastWord in ["r", "R"] and i < n and text[i] == '"': continue
      words.add (lastWord, line, pragma > 0)
    else:
      if c == '{' and i + 1 < n and text[i + 1] == '.': inc pragma
      elif c == '.' and i + 1 < n and text[i + 1] == '}' and pragma > 0: dec pragma
      if c notin {' ', '\t', '\r'}: lastWord = ""
      inc i
  # the lines of import, from and include statements (a list in […] or ending in a comma goes on below)
  var importLines: HashSet[int]
  var cont = false
  let rawLines = text.split('\n')
  for li, raw in rawLines:
    let t = raw.strip
    let w0 = block:
      var e = 0
      while e < t.len and t[e] in IdentChars: inc e
      t[0 ..< e]
    if cont or (raw.len > 0 and raw[0] notin {' ', '\t'} and w0 in ["import", "from", "include", "export"]):
      importLines.incl li + 1
      let code = (let h = t.find('#'); if h >= 0: t[0 ..< h].strip else: t)
      cont = code.endsWith(",") or code.count('[') > code.count(']') or code.endsWith("[")
    else: cont = false
  var importsMacros = false
  for (w, l, _) in words:
    if l in importLines and plugIdentNorm(w) == "macros": importsMacros = true
  template mark(p: PlugPerm, w: string, l: int) =
    ## notes that the plugin uses the permission: "shell" also marks it as running programs itself; the first sighting
    ## of each permission is kept in `seen` with the file, line and name
    if p == ppShell: sc.ownShell = true
    if p notin sc.uses:
      sc.uses.incl p
      sc.seen[p] = name & ":" & $l & " " & w
  for (w, l, inPragma) in words:
    let nw = plugIdentNorm(w)
    if l in importLines:
      if nw in PlugModShell: mark(ppShell, w, l)
      elif nw in PlugModNet: mark(ppNetwork, w, l)
      elif nw in PlugModAll:
        for p in PlugPerm: mark(p, w, l)
      continue
    if inPragma:
      if nw in PlugPragmaAll:
        for p in PlugPerm: mark(p, "{." & w & ".}", l)
      continue
    if nw in PlugUsesShell: mark(ppShell, w, l)
    elif nw in PlugUsesNet: mark(ppNetwork, w, l)
    elif nw in PlugUsesFiles: mark(ppFiles, w, l)
    elif nw in PlugUsesClip: mark(ppClipboard, w, l)
    elif nw in PlugUsesAll or w in PlugUsesAll or (importsMacros and nw in PlugUsesAllMacros):
      for p in PlugPerm: mark(p, w, l)
  # a module named by a path: outside the plugin's folder, ned has not read it
  for (w, l, _) in words:
    if plugIdentNorm(w) in ["import", "include", "from"]:
      for (s, sl) in strs:
        if sl == l and (s.startsWith("/") or s.startsWith("..") or s.startsWith("~") or ':' in s):
          for p in PlugPerm: mark(p, w & " \"" & s & "\"", l)
  # a program ned runs for it — a language's run command, a formatter, a language server — is a program it runs
  var ln = 0
  for raw in text.split('\n'):
    inc ln
    let t = raw.strip
    if t.startsWith("#"): continue
    let what = plugProgLine(t)
    if what.len > 0:
      sc.progs = true
      if ppShell notin sc.uses:
        sc.uses.incl ppShell
        sc.seen[ppShell] = name & ":" & $ln & " " & what
  # permission "shell", "to send your requests with curl"
  for (w, l, _) in words:
    if plugIdentNorm(w) != "permission": continue
    var mine: seq[string]
    for (s, sl) in strs:
      if sl == l: mine.add s
    if mine.len >= 1:
      for p in PlugPerm:
        if mine[0] == $p:
          if p == ppShell: sc.ownShell = true
          sc.uses.incl p
          if sc.seen[p].len == 0: sc.seen[p] = name & ":" & $l & " permission"
          if mine.len >= 2: sc.why[p] = mine[1]

proc plugScanDir(dir: string): PlugScan =
  ## a plugin's folder: its .nims and .nim files (up to 60 of them, 4 MB in all)
  var budget = 4_000_000
  var count = 0
  try:
    for f in walkDirRec(dir):
      if not (f.endsWith(".nims") or f.endsWith(".nim")): continue
      inc count
      if count > 60 or budget <= 0:
        result.ownShell = true
        for p in PlugPerm:
          result.uses.incl p
          if result.seen[p].len == 0: result.seen[p] = "too many files to read"
        break
      let t = readFile(f)
      budget -= t.len
      plugScanText(relativePath(f, dir), t, result)
  except CatchableError: discard

func plugPermsList(ps: set[PlugPerm]): string =
  ## the permissions' short names, in a row and separated by commas, as the toasts and the Plugins dock say them
  var xs: seq[string]
  for p in ps: xs.add PlugPermShort[p]
  xs.join(", ")

# what you allowed each plugin: kept on this device only (not in the settings, not synced: asked on each device)
var
  plugGranted: Table[string, set[PlugPerm]]
  plugGrantedLoaded = false
  plugGrantedNew = false                  # (no file yet: the plugins on before 6.26 keep what they use)

# the file where what you allowed is kept, in ned's state folder
proc plugPermFile(): string = stateDir() / "plugin-permissions.json"

proc plugGrantLoad() =
  ## reads the saved grants into `plugGranted` once; with no file yet it sets `plugGrantedNew`, so the plugins that are
  ## on keep what they use
  if plugGrantedLoaded: return
  plugGrantedLoaded = true
  plugGranted.clear()
  if not fileExists(plugPermFile()):
    plugGrantedNew = true
    return
  try:
    let j = parseFile(plugPermFile())
    for k, v in j{"granted"}:
      var s: set[PlugPerm]
      for x in v:
        for p in PlugPerm:
          if x.getStr == $p: s.incl p
      plugGranted[k] = s
  except CatchableError: discard

proc plugGrantSave() =
  ## writes `plugGranted` to the permissions file (as a list of permission names for each plugin, readable by you alone)
  ## and clears `plugGrantedNew`; a failure to write is ignored
  var g = newJObject()
  for k, s in plugGranted:
    var a = newJArray()
    for p in s: a.add %($p)
    g[k] = a
  try:
    createDir(stateDir())
    writeFileSafe(plugPermFile(), (%*{"version": 1, "granted": g}).pretty & "\n", 0o600)
  except CatchableError: discard
  plugGrantedNew = false

func plugCommandRuns(name: string): bool =
  ## a command of ned's that runs programs (or changes what does): a plugin needs "shell" to run it
  let l = name.toLowerAscii
  for w in ["run", "build", "test", "debug", "terminal", "task", "git", "ai:", "ai ", "assistant", "agent",
            "compile", "explorer", "repl", "shell", "install", "nimble", "atlas", "make", "profile", "plugin",
            "sync", "macro", "execute", "decompile", "ssh", "remote", "trust", "setting", "reset", "commit", "push",
            "pull", "memory", "notebook", "check", "lint", "format", "bisect", "send", "open a terminal"]:
    if w in l: return true
  false
