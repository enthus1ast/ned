## ned's formatters from the command line: `nedfmt` (and `ned --format`). nph's options — --check, --diff, --out,
## --outDir, `-` for stdin, --exclude/--include patterns — plus your `nim.format.*` settings (the user's and the
## project's), and a git pre-commit hook that keeps staged files formatted.
##
## Exit status: 0 done (or nothing to change), 1 --check found files that would change, 2 a file was left alone
## (the formatter was not sure of it, or it could not be read or written), 3 wrong arguments.

import std/[strutils, json, algorithm, osproc, terminal, streams, hashes, times, tables]
when defined(windows): import ../sys/winos as os   # (std/os, with '/' in the paths it makes)
else: import std/os
when defined(windows): import ../sys/winposix as posix
else: import std/posix
import formatters
import ../editor/regex, ../core/editorconfig

type FmtFn* = proc(text, path: string): (string, string) {.closure.}

const
  SkipDirNames = ["nimcache", "nimbledeps", "node_modules", "__pycache__", "venv", "_build", "buck-out", "build",
                  "dist"]     # (and every hidden folder: .git, .nimble, .venv, .vscode …) — nph's usual list
  HookMark = "# nedfmt --install-hook wrote this"

func fmtKindOf*(path: string): string =
  ## which of ned's formatters fits a file: "nim", "json", "markdown", "css", "scss", "c", "yaml", "toml", "html",
  ## "sql" or ""
  let ext = splitFile(path).ext.toLowerAscii
  case ext
  of ".nim", ".nims", ".nimble": "nim"
  of ".json", ".jsonc": "json"
  of ".md", ".markdown": "markdown"
  of ".scss", ".less": "scss"
  of ".css": "css"
  of ".c", ".h": "c"
  of ".yaml", ".yml": "yaml"
  of ".toml": "toml"
  of ".html", ".htm", ".xhtml": "html"
  of ".sql", ".psql", ".pgsql", ".mysql": "sql"
  else: ""

func looksCppText(text: string): bool =
  for w in ["template<", "template <", "namespace ", "std::", "class ", "public:", "private:", "nullptr"]:
    if w in text: return true

type ClangFn* = proc(c, fakeName, dir: string): string {.closure.}
  ## clang-format run on `c` as if it were the file `fakeName` (its .clang-format applies) — "" when it failed

var
  fmtEmbedNames*: Table[string, string]   ## nim.embeddedLanguages: a routine's name → the language its strings hold
  fmtEmitC* = true       ## nim.formatEmitC: the C in {.emit: """…""".} blocks formatted with the Nim around it
  fmtEmitCpp* = false    ## nim.backend is cpp: that C is C++
  fmtCStyleName* = "auto"                   ## c.format.style
  fmtCStyleOpts*: seq[(string, string)]     ## c.format.options (clang-format's keys)
  fmtCEngine* = "auto"                      ## c.engine: clangd for C → the emits' C with clang-format
  fmtCFormatter* = "auto"                   ## c.formatter

proc fmtClangdForC*(): bool =
  ## clangd answers for C here (c.engine clangd or both, or auto with clangd installed): C is formatted as clangd
  ## formats it — with clang-format
  fmtCEngine in ["clangd", "both"] or (fmtCEngine == "auto" and findExe("clangd").len > 0)

proc fmtUseClangFormat*(): bool =
  ## clang-format for C (files and emits): c.formatter = clang-format, or auto with clangd in use — when installed
  if findExe("clang-format").len == 0: return false
  case fmtCFormatter
  of "builtin": false
  of "clang-format": true
  else: fmtClangdForC()

proc formatEmitC*(text, path: string, cpp: bool, clang: ClangFn = nil, baseDir = "",
                  style = cStyleKeep()): (string, int, string) =
  ## the C in each {.emit: """…""".} of a Nim file formatted: clang-format when given (your .clang-format applies),
  ## else ned's own C formatter — (new text, blocks changed, what formatted them). A block with `nim symbols` in
  ## backticks, or on the string's first line, stays as it is
  result = (text, 0, "")
  if "emit" notin text: return
  var ok = true
  let toks = fLex(text, ok)
  if not ok: return
  let dir = if path.len > 0: parentDir(path) elif baseDir.len > 0: baseDir else: getCurrentDir()
  var outp = ""
  var at = 0
  for k in 0 ..< toks.len - 3:
    if not (toks[k].kind == fkPragOpen and toks[k + 1].kind == fkIdent and toks[k + 1].text == "emit" and
            toks[k + 2].kind == fkColon and toks[k + 3].kind == fkStr): continue
    let st = toks[k + 3]
    if not (st.text.startsWith("\"\"\"") and st.text.endsWith("\"\"\"") and st.text.len >= 7): continue
    let body = st.text[3 ..< st.text.len - 3]
    if '`' in body or not body.startsWith("\n"): continue
    var ls = body[1 .. ^1].split('\n')
    # the closing quotes on a line of their own: that line's indentation stays
    var closing = ""
    if ls.len > 0 and ls[^1].strip.len == 0:
      closing = ls[^1]
      ls.setLen(ls.len - 1)
    var base = high(int)
    for l in ls:
      if l.strip.len > 0: base = min(base, l.len - l.strip(trailing = false).len)
    if base == high(int): continue
    var c = ""
    for l in ls: c.add (if l.strip.len == 0: "" else: l[min(base, l.len) .. ^1].strip(leading = false)) & "\n"
    var res = ""
    if clang != nil:
      let o = clang(c, dir / (if cpp: "emit.cpp" else: "emit.c"), dir)
      if o.strip.len > 0: res = o
      result[2] = "clang-format"
    if res.len == 0:
      # (ned's own: the style chosen for C, at the Nim's indentation and its line length less the block's own)
      var est = style
      est.indent = 2
      est.contIndent = min(est.contIndent, 4)
      est.useTab = false
      est.colLimit = (if FmtWidth > 0: max(40, FmtWidth - base) else: est.colLimit)
      let (r, e) = fmtCWith(c, est, cpp)
      if e.len > 0: continue
      res = r
      if result[2].len == 0: result[2] = "ned's C formatter"
    if res.strip(chars = {'\n'}) == c.strip(chars = {'\n'}): continue
    var nb = "\"\"\"\n"
    for l in res.strip(chars = {'\n'}).split('\n'):
      nb.add (if l.strip.len == 0: "" else: spaces(base) & l.strip(leading = false)) & "\n"
    nb.add closing & "\"\"\""
    outp.add text[at ..< st.pos]
    outp.add nb
    at = st.pos + st.text.len
    inc result[1]
  if result[1] == 0: return
  outp.add text[at .. ^1]
  result[0] = outp

proc clangFormatCli(c, fakeName, dir: string): string =
  ## clang-format from nedfmt (the editor runs it its own way)
  try:
    let (o, code) = execCmdEx("clang-format --sort-includes=false --assume-filename=" & quoteShell(fakeName),
                              input = c, workingDir = dir, options = {poUsePath, poEvalCommand})
    if code == 0: o else: ""
  except CatchableError: ""

# ── Nim's own parser as a second check (nim.format.verify, nedfmt --verify): nedastcheck, built once against the
#    compiler sources found on this machine, says whether the formatted text parses to the same tree ──

const
  AstCheckSrc = staticRead("nedastcheck.nim")
  AstCheckKey = $(hash(AstCheckSrc) and 0xffffff)

var
  fmtVerifyExe* = ""     ## the checker in use ("" none): a Nim result it reads differently is left alone
  fmtVerifyWanted* = false   ## nim.format.verify
  compilerRootCache = "?"

proc nimCompilerRoot*(): string =
  ## a folder R with R/compiler/parser.nim: the Nim in use (choosenim, a source build), else nimble's
  ## compiler package — "" when there is none
  if compilerRootCache != "?": return compilerRootCache
  var cands: seq[string]
  let nim = findExe("nim")
  if nim.len > 0:
    var real = nim
    try: real = expandFilename(nim)
    except CatchableError: discard
    let r = parentDir(parentDir(real))
    cands.add r
    cands.add r / "lib" / "nim"
    cands.add r / "share" / "nim"
  let cur = getHomeDir() / ".choosenim" / "current"
  if fileExists(cur):
    try: cands.add readFile(cur).strip
    except CatchableError: discard
  let nimbleDir = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")
  for sub in ["pkgs2", "pkgs"]:
    var found: seq[string]
    try:
      for kind, d in walkDir(nimbleDir / sub):
        let nm = extractFilename(d)
        if kind == pcDir and (nm.startsWith("compiler-") or nm.startsWith("nim-")): found.add d
    except OSError: discard
    found.sort()
    for i in countdown(found.high, 0): cands.add found[i]
  compilerRootCache = ""
  for c in cands:
    if c.len > 1 and fileExists(c / "compiler" / "parser.nim"):
      compilerRootCache = c
      break
  compilerRootCache

proc fmtCacheDir(): string =
  getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / "ned"

proc astCheckerPath*(): string =
  ## where the checker for these compiler sources is (built or not); "" when there are no compiler sources
  let root = nimCompilerRoot()
  if root.len == 0: return ""
  var stamp = ""
  try: stamp = $getLastModificationTime(root / "compiler" / "parser.nim").toUnix
  except CatchableError: discard
  # (with .exe on Windows: the linker adds it to a name without one — looked for without it, the checker was built
  # again at every format, and said it could not be)
  addFileExt(fmtCacheDir() / ("nedastcheck-" & AstCheckKey & "-" & $(hash(root & stamp) and 0xffffff)), ExeExt)

proc astCheckerCacheDir*(): string =
  ## the build's scratch folder (removed after the build — by the caller: no `rm` in the command, Windows has none)
  fmtCacheDir() / "nedastcheck-src" / "cache"

proc astCheckerFailure*(output: string, code: int): string =
  ## why the checker's build failed, in one line: the compiler's error, else the last line it wrote, else the exit
  ## status
  var last = ""
  for raw in output.splitLines:
    let l = raw.strip
    if l.len == 0: continue
    if "Error:" in l: return l[l.find("Error:") .. ^1]
    last = l
  if last.len > 0: last else: "nim stopped with exit status " & $code & " and wrote nothing"

proc astCheckerBuildCmd*(): string =
  ## the shell command that builds it (the source written out first); "" when there are no compiler sources
  let exe = astCheckerPath()
  if exe.len == 0: return ""
  let root = nimCompilerRoot()
  let dir = fmtCacheDir() / "nedastcheck-src"
  try:
    createDir(dir)
    writeFile(dir / "nedastcheck.nim", AstCheckSrc)
  except CatchableError: return ""
  let nim = if fileExists(root / "bin" / addFileExt("nim", ExeExt)): root / "bin" / addFileExt("nim", ExeExt) else: "nim"
  quoteShell(nim) & " c -d:release --hints:off --warnings:off --verbosity:0 --path:" & quoteShell(root) &
    " --nimcache:" & quoteShell(astCheckerCacheDir()) & " -o:" & quoteShell(exe) & " " &
    quoteShell(dir / "nedastcheck.nim")

type CSigHandler = proc (a: cint) {.noconv.}
proc cSignal(sig: cint, handler: CSigHandler): CSigHandler {.importc: "signal", header: "<signal.h>".}
  ## (C's signal with its result: posix.signal has none before Nim 2.2.12)

proc astSame*(exe, a, b: string, timeoutMs = 20000): (int, string) =
  ## does `b` parse to the same tree as `a`? (0 yes · 1 no, and where · 2 cannot tell: `a` does not parse, or the
  ## checker failed)
  var p: Process
  # (a checker that stops reading early must not take this process with it: SIGPIPE ignored while writing to it)
  let oldPipe = cSignal(SIGPIPE, SIG_IGN)
  defer: discard cSignal(SIGPIPE, oldPipe)
  try:
    p = startProcess(exe, args = ["-"], options = {poStdErrToStdOut})
    let inp = p.inputStream
    inp.write $a.len & " " & $b.len & "\n"
    inp.write a
    inp.write b
    inp.close()
    let o = p.outputStream.readAll()
    let code = p.waitForExit(timeoutMs)
    p.close()
    let l = o.strip.splitLines
    let last = if l.len > 0: l[^1] else: ""
    case code
    of 0: (if last == "same": (0, "") else: (2, last))
    of 1: (1, last.replace("different ", ""))
    else: (2, last)
  except CatchableError as e:
    try:
      if p != nil:
        p.kill()
        p.close()
    except CatchableError: discard
    (2, e.msg)

proc verifyNim*(orig, formatted: string): string =
  ## "" when Nim's parser (fmtVerifyExe) reads the formatted text as the original, else why not
  if fmtVerifyExe.len == 0 or orig == formatted: return ""
  let (code, why) = astSame(fmtVerifyExe, orig, formatted)
  if code == 1:
    let parts = why.split(':', 1)
    let lines = parts[0].splitWhitespace()
    "Nim's parser reads the result differently" & (if lines.len == 2 and lines[0] != "0": " (line " & lines[0] & ")" else: "") &
      " — left alone; please report it"
  else: ""

proc fmtTextOf*(kind, text, path: string, nimFmt: FmtFn = nil): (string, string) =
  ## (the formatted text, why it was left alone — "" when it was formatted or already was)
  try:
    case kind
    of "nim":
      if nimFmt != nil: return nimFmt(text, path)
      var err = ""
      let keepS = FmtScript
      FmtScript = fIsScriptPath(path)          # (.nims, .nimble: NimScript's layout)
      var r = ""
      try: r = fFormat(text, err)
      finally: FmtScript = keepS
      if err.len > 0: return (text, err)
      let why = verifyNim(text, r)
      if why.len > 0: return (text, why)
      # (the SQL, HTML and JSON in its strings — nim.format.embedded — after Nim's own check: the strings change)
      if FmtEmbedded: r = fFormatEmbedded(r, fmtEmbedNames)[0]
      if not fmtEmitC: return (r, "")
      let clang: ClangFn = if fmtUseClangFormat(): clangFormatCli else: nil
      (formatEmitC(r, path, fmtEmitCpp, clang, "", cStyleFor(path, fmtCStyleName, fmtCStyleOpts))[0], "")
    of "c": fmtCWith(text, cStyleFor(path, fmtCStyleName, fmtCStyleOpts), looksCppText(text))
    of "json": fmtJson(text, 2)
    of "markdown": fmtMarkdown(text)
    of "css": fmtCss(text, 2)
    of "scss": fmtCss(text, 2, lineComments = true)
    of "yaml": fmtYaml(text, 2)
    of "toml": fmtToml(text)
    of "html": fmtHtml(text, 2)
    of "sql": fmtSql(text, 2)
    else: (text, "no formatter for this kind of file")
  except CatchableError, Defect:
    (text, "the formatter failed on this file (please report it)")

# ── settings: nim.format.* from your settings and the project's, as ned reads them ──

func stripJsoncText(s: string): string =
  ## JSON with comments and trailing commas → JSON
  var i = 0
  var inStr = false
  while i < s.len:
    let c = s[i]
    if inStr:
      result.add c
      if c == '\\' and i + 1 < s.len:
        result.add s[i + 1]
        i += 2
        continue
      if c == '"': inStr = false
      inc i
    elif c == '"':
      inStr = true
      result.add c
      inc i
    elif c == '/' and i + 1 < s.len and s[i + 1] == '/':
      while i < s.len and s[i] != '\n': inc i
    elif c == '/' and i + 1 < s.len and s[i + 1] == '*':
      let e = s.find("*/", i + 2)
      i = if e < 0: s.len else: e + 2
    elif c == ',':
      var j = i + 1
      while j < s.len and s[j] in Whitespace: inc j
      if j < s.len and s[j] in {'}', ']'}: inc i
      else:
        result.add c
        inc i
    else:
      result.add c
      inc i

proc settingOf(j: JsonNode, key: string): JsonNode =
  ## "nim.format.lineLength" written flat, or nested ({"nim": {"format": {…}}})
  if j == nil or j.kind != JObject: return nil
  if j.hasKey(key): return j[key]
  var cur = j
  for part in key.split('.'):
    if cur == nil or cur.kind != JObject or not cur.hasKey(part): return nil
    cur = cur[part]
  cur

var fmtWidthSaid = false        # (a settings file gave nim.format.lineLength: before any .editorconfig)

proc applySettingsFile(p: string) =
  if not fileExists(p): return
  var j: JsonNode
  try: j = parseJson(stripJsoncText(readFile(p)))
  except CatchableError: return
  var n = settingOf(j, "nim.format.lineLength")
  if n != nil and n.kind == JInt:
    FmtWidth = clamp(n.getInt, 40, 240)
    FmtMax = FmtWidth
    fmtWidthSaid = true
  for (key, which) in [("nim.format.params", 0), ("nim.format.arguments", 1), ("nim.format.collections", 2)]:
    n = settingOf(j, key)
    if n != nil and n.kind == JString:
      let w = parseEnum[FWrap](n.getStr, fwFit)
      case which
      of 0: FmtParams = w
      of 1: FmtArgs = w
      else: FmtColl = w
  n = settingOf(j, "nim.format.imports")
  if n != nil and n.kind == JString:
    FmtImports = case n.getStr
                 of "sort": 1
                 of "merge": 2
                 else: 0
  n = settingOf(j, "nim.format.align")
  if n != nil and n.kind == JBool: FmtAlign = n.getBool
  n = settingOf(j, "nim.format.alignNimbleFields")
  if n != nil and n.kind == JBool: FmtScriptAlign = n.getBool
  n = settingOf(j, "nim.format.alignComments")
  if n != nil and n.kind == JBool: FmtAlignComments = n.getBool
  n = settingOf(j, "nim.format.magicTrailingComma")
  if n != nil and n.kind == JBool: FmtMagicComma = n.getBool
  n = settingOf(j, "nim.format.normalizeNumbers")
  if n != nil and n.kind == JBool: FmtNumbers = n.getBool
  n = settingOf(j, "nim.format.docCode")
  if n != nil and n.kind == JBool: FmtDocCode = n.getBool
  n = settingOf(j, "nim.format.reflowDocComments")
  if n != nil and n.kind == JBool: FmtReflow = n.getBool
  n = settingOf(j, "nim.format.reflowComments")
  if n != nil and n.kind == JBool: FmtReflowPlain = n.getBool
  n = settingOf(j, "nim.format.maxBlankLines")
  if n != nil and n.kind == JInt: FmtBlank = clamp(n.getInt, 1, 3)
  n = settingOf(j, "nim.format.verify")
  if n != nil and n.kind == JBool: fmtVerifyWanted = n.getBool
  n = settingOf(j, "nim.formatEmitC")
  if n != nil and n.kind == JBool: fmtEmitC = n.getBool
  n = settingOf(j, "nim.format.embedded")
  if n != nil and n.kind == JBool: FmtEmbedded = n.getBool
  n = settingOf(j, "nim.embeddedLanguages")
  if n != nil and n.kind == JObject:
    for k, v in n:
      if v.kind == JString and k.len > 0: fmtEmbedNames[k] = v.getStr
  n = settingOf(j, "nim.backend")
  if n != nil and n.kind == JString: fmtEmitCpp = n.getStr == "cpp"
  n = settingOf(j, "c.format.style")
  if n != nil and n.kind == JString: fmtCStyleName = n.getStr
  n = settingOf(j, "c.format.options")
  if n != nil and n.kind == JObject: fmtCStyleOpts = cStyleOptions(n)
  n = settingOf(j, "c.engine")
  if n != nil and n.kind == JString: fmtCEngine = n.getStr
  n = settingOf(j, "c.formatter")
  if n != nil and n.kind == JString: fmtCFormatter = n.getStr

proc userSettingsFile(): string =
  getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "ned" / "config.json"

proc projectSettingsFile(start: string): string =
  ## the nearest .ned/settings.json above `start` ("" when there is none)
  var d = start
  for _ in 0 .. 40:
    if fileExists(d / ".ned" / "settings.json"): return d / ".ned" / "settings.json"
    let up = parentDir(d)
    if up.len == 0 or up == d: break
    d = up
  ""

proc applySettingsFor*(path: string) =
  ## the layout settings for one file: defaults, yours, then its project's
  FmtWidth = 88
  FmtMax = 88
  FmtParams = fwFit
  FmtArgs = fwFit
  FmtColl = fwFit
  FmtImports = 0
  FmtAlign = false
  FmtAlignComments = false
  FmtMagicComma = false
  FmtNumbers = false
  FmtDocCode = false
  FmtReflow = false
  FmtReflowPlain = false
  FmtBlank = 1
  fmtEmitC = true
  FmtEmbedded = true
  fmtEmbedNames.clear()
  fmtEmitCpp = false
  fmtCStyleName = "auto"
  fmtCStyleOpts = @[]
  fmtCEngine = "auto"
  fmtCFormatter = "auto"
  fmtVerifyWanted = false
  fmtWidthSaid = false
  applySettingsFile(userSettingsFile())
  let p = projectSettingsFile(parentDir(absolutePath(path)))
  if p.len > 0: applySettingsFile(p)
  # (nim.format.lineLength in neither: the file's .editorconfig max_line_length, as the editor does)
  if not fmtWidthSaid:
    let m = editorConfigMaxLine(absolutePath(path))
    if m > 0:
      FmtWidth = clamp(m, 40, 240)
      FmtMax = FmtWidth

# ── a unified diff of two texts ──

proc diffOps(a, b: seq[string]): seq[(char, int, int)] =
  ## the edit script: (' ' same, '-' only in a, '+' only in b; the line in a; the line in b) — Myers' algorithm
  ## between a common start and end
  var pre = 0
  while pre < a.len and pre < b.len and a[pre] == b[pre]: inc pre
  var suf = 0
  while suf < a.len - pre and suf < b.len - pre and a[a.high - suf] == b[b.high - suf]: inc suf
  for i in 0 ..< pre: result.add (' ', i, i)
  let n = a.len - pre - suf
  let m = b.len - pre - suf
  var mid: seq[(char, int, int)]
  if n > 0 or m > 0:
    let maxD = n + m
    if maxD > 20000:
      for i in 0 ..< n: mid.add ('-', pre + i, -1)
      for j in 0 ..< m: mid.add ('+', -1, pre + j)
    else:
      let off = maxD + 1
      var v = newSeq[int](2 * maxD + 3)
      var trace: seq[seq[int]]
      var found = false
      for d in 0 .. maxD:
        trace.add v
        var k = -d
        while k <= d:
          var x = if k == -d or (k != d and v[off + k - 1] < v[off + k + 1]): v[off + k + 1] else: v[off + k - 1] + 1
          var y = x - k
          while x < n and y < m and a[pre + x] == b[pre + y]:
            inc x
            inc y
          v[off + k] = x
          if x >= n and y >= m:
            found = true
            break
          k += 2
        if found: break
      # back through the trace
      var x = n
      var y = m
      var rev: seq[(char, int, int)]
      for d in countdown(trace.high, 0):
        let vv = trace[d]
        let k = x - y
        let prevK = if k == -d or (k != d and vv[off + k - 1] < vv[off + k + 1]): k + 1 else: k - 1
        let prevX = if d == 0: 0 else: vv[off + prevK]
        let prevY = prevX - prevK
        while x > prevX and y > prevY and x > 0 and y > 0:
          rev.add (' ', pre + x - 1, pre + y - 1)
          dec x
          dec y
        if d > 0:
          if x == prevX: rev.add ('+', -1, pre + y - 1)
          else: rev.add ('-', pre + x - 1, -1)
          x = prevX
          y = prevY
      while x > 0 and y > 0:
        rev.add (' ', pre + x - 1, pre + y - 1)
        dec x
        dec y
      for i in countdown(rev.high, 0): mid.add rev[i]
  result.add mid
  for i in 0 ..< suf: result.add (' ', a.len - suf + i, b.len - suf + i)

proc unifiedDiff*(a, b, nameA, nameB: string, color = false): string =
  ## `diff -u` of two texts, 3 lines of context
  let la = a.split('\n')
  let lb = b.split('\n')
  let ops = diffOps(la, lb)
  var changes: seq[int]
  for i, op in ops:
    if op[0] != ' ': changes.add i
  if changes.len == 0: return ""
  proc c(s, code: string): string = (if color: "\e[" & code & "m" & s & "\e[0m" else: s)
  result = c("--- " & nameA, "1") & "\n" & c("+++ " & nameB, "1") & "\n"
  var i = 0
  while i < changes.len:
    let lo = max(0, changes[i] - 3)
    var hi = min(ops.high, changes[i] + 3)
    var j = i + 1
    while j < changes.len and changes[j] - 3 <= hi + 1:
      hi = min(ops.high, changes[j] + 3)
      inc j
    # the hunk's starting lines and lengths in each text
    var aStart, bStart = -1
    var aLen, bLen = 0
    for k in lo .. hi:
      let (t, ia, ib) = ops[k]
      if t != '+':
        if aStart < 0: aStart = ia
        inc aLen
      if t != '-':
        if bStart < 0: bStart = ib
        inc bLen
    if aStart < 0:
      var k = lo
      while k > 0 and ops[k][1] < 0: dec k
      aStart = max(0, ops[k][1])
    if bStart < 0:
      var k = lo
      while k > 0 and ops[k][2] < 0: dec k
      bStart = max(0, ops[k][2])
    result.add c("@@ -" & $(aStart + (if aLen > 0: 1 else: 0)) & "," & $aLen & " +" & $(bStart + (if bLen > 0: 1 else: 0)) &
                 "," & $bLen & " @@", "36") & "\n"
    for k in lo .. hi:
      let (t, ia, ib) = ops[k]
      case t
      of ' ': result.add " " & la[ia] & "\n"
      of '-': result.add c("-" & la[ia], "31") & "\n"
      else: result.add c("+" & lb[ib], "32") & "\n"
    i = j

# ── which files ──

proc gitRootOf(dir: string): string =
  var d = dir
  for _ in 0 .. 40:
    if dirExists(d / ".git") or fileExists(d / ".git"): return d
    let up = parentDir(d)
    if up.len == 0 or up == d: break
    d = up
  ""

proc filesIn(dir: string, usualSkips = true): seq[string] =
  ## a folder's files: git's list in a repository (what .gitignore leaves out stays out), else a walk — never
  ## .git; nor (usualSkips) nimcache, node_modules, build folders or hidden ones
  proc skipped(nm: string): bool =
    nm in [".git", ".hg", ".svn"] or (usualSkips and (nm.startsWith(".") or nm in SkipDirNames))
  let gr = gitRootOf(dir)
  if gr.len > 0 and findExe("git").len > 0:
    try:
      let (o, code) = execCmdEx("git -C " & quoteShell(gr) & " ls-files -z --cached --others --exclude-standard -- " &
                                quoteShell(dir))
      if code == 0:
        for f in o.split('\0'):
          if f.len == 0: continue
          var skip = false
          for part in f.split('/')[0 ..< ^1]:
            if skipped(part): skip = true
          let p = gr / f
          if not skip and fileExists(p): result.add p
        result.sort()
        return
    except CatchableError: discard
  var stack = @[dir]
  while stack.len > 0 and result.len < 50000:
    let d = stack.pop()
    try:
      for kind, p in walkDir(d):
        let nm = extractFilename(p)
        if kind == pcDir:
          if not skipped(nm): stack.add p
        elif kind in {pcFile, pcLinkToFile} and not (usualSkips and nm.startsWith(".")): result.add p
    except OSError: discard
  result.sort()

proc matches(re: Regex, s: string): bool =
  var caps: seq[int]
  reSearch(re, s, 0, caps)

# ── writing ──

proc writeAtomically(path, text: string) =
  ## a temporary file beside it, renamed over it (its permissions kept): never half a file
  let tmp = path & ".nedfmt-" & $getCurrentProcessId()
  var perms: set[FilePermission]
  var hadPerms = false
  try:
    perms = getFilePermissions(path)
    hadPerms = true
  except CatchableError: discard
  writeFile(tmp, text)
  try:
    if hadPerms: setFilePermissions(tmp, perms)
    moveFile(tmp, path)
  except CatchableError as e:
    try: removeFile(tmp) except CatchableError: discard
    raise e

# ── the pre-commit hook ──

proc installHook(prog, exe: string, exeArgs: string, force: bool): int =
  ## .git/hooks/pre-commit (or core.hooksPath's): the staged Nim files must be formatted — what is staged, not the
  ## working copy. A file the formatter is not sure of does not stop the commit; nedfmt missing does not either
  let root = gitRootOf(getCurrentDir())
  if root.len == 0:
    stderr.writeLine prog & ": not in a git repository"
    return 2
  var hooks = ""
  try:
    let (o, code) = execCmdEx("git rev-parse --git-path hooks", workingDir = getCurrentDir())
    if code == 0 and o.strip.len > 0:
      hooks = o.strip
      if not hooks.isAbsolute: hooks = getCurrentDir() / hooks
  except CatchableError: discard
  if hooks.len == 0: hooks = root / ".git" / "hooks"
  let hook = hooks / "pre-commit"
  # (ned --lint's hook there: kept, before the format check's result)
  var lintBlock = ""
  if fileExists(hook):
    let old = readFile(hook)
    let k = old.find("# ned --lint pre-commit hook")
    if k >= 0:
      var e = k
      for _ in 0 ..< 4:
        let n = old.find('\n', e)
        e = if n < 0: old.len else: n + 1
      lintBlock = old[k ..< e]
  if fileExists(hook) and HookMark notin readFile(hook) and lintBlock.len == 0 and not force:
    stderr.writeLine prog & ": " & hook & " exists already (your own hook) — not replaced. Add this line to it:\n" &
                     "  git diff --cached --name-only --diff-filter=ACMR -- '*.nim' | xargs -r " & prog & " --check\n" &
                     "or run again with --force to replace it"
    return 2
  let script = "#!/bin/sh\n" & HookMark & ".\n" &
    "# The staged Nim files must be formatted (what is staged, not the working copy). Commit anyway: git commit --no-verify\n" &
    "BIN=" & quoteShell(exe) & "\n" &
    "[ -x \"$BIN\" ] || BIN=$(command -v nedfmt) || { echo \"nedfmt is not installed: the format check is skipped\" >&2; exit 0; }\n" &
    "files=$(git diff --cached --name-only --diff-filter=ACMR -- '*.nim' '*.nims' '*.nimble')\n" &
    "[ -n \"$files\" ] || exit 0\n" &
    "fail=0\nIFS='\n'\n" &
    "for f in $files; do\n" &
    "  git show \":$f\" | \"$BIN\" " & exeArgs & "--check --quiet --stdin-name=\"$f\" -\n" &
    "  [ $? = 1 ] && fail=1\n" &
    "done\n" &
    "[ $fail = 0 ] || echo \"Not formatted: run nedfmt on the files above (or Alt+F in ned), then git add them.\" >&2\n" &
    lintBlock & "exit $fail\n"
  try:
    createDir(hooks)
    writeFile(hook, script)
    setFilePermissions(hook, {fpUserRead, fpUserWrite, fpUserExec, fpGroupRead, fpGroupExec, fpOthersRead,
                              fpOthersExec})
  except CatchableError as e:
    stderr.writeLine prog & ": cannot write " & hook & ": " & e.msg
    return 2
  echo "Installed " & hook & " — a commit now needs its staged Nim files formatted (git commit --no-verify skips it)"
  0

# ── nph's .nph.toml: exclude, extend-exclude, include, color ──

proc tomlStrings(v: string): seq[string] =
  ## the strings of a TOML value: "x", 'x' or an array of them
  var i = 0
  while i < v.len:
    let q = v[i]
    if q == '#':
      while i < v.len and v[i] != '\n': inc i
    elif q in {'"', '\''}:
      var cur = ""
      inc i
      while i < v.len and v[i] != q:
        if q == '"' and v[i] == '\\' and i + 1 < v.len:
          case v[i + 1]
          of '\\', '"': cur.add v[i + 1]
          of 'n': cur.add '\n'
          of 't': cur.add '\t'
          else: cur.add v[i] & v[i + 1]          # (\. in a pattern: kept as it is)
          i += 2
        else:
          cur.add v[i]
          inc i
      inc i
      result.add cur
    else: inc i

proc readNphToml*(path: string): (seq[string], seq[string], seq[string], int) =
  ## (exclude, extend-exclude, include, color: -1 unset · 0 · 1) of a .nph.toml
  result[3] = -1
  if not fileExists(path): return
  var text = ""
  try: text = readFile(path)
  except CatchableError: return
  var i = 0
  let ls = text.splitLines
  while i < ls.len:
    let l = ls[i].strip
    inc i
    if l.len == 0 or l[0] in {'#', '['}: continue
    let eq = l.find('=')
    if eq < 0: continue
    let key = l[0 ..< eq].strip.strip(chars = {'"'})
    var val = l[eq + 1 .. ^1].strip
    if val.startsWith("[") and not val.endsWith("]"):
      while i < ls.len:
        val.add "\n" & ls[i]
        inc i
        if ls[i - 1].strip.startsWith("]") or ls[i - 1].strip.endsWith("]"): break
    case key
    of "exclude": result[0] = tomlStrings(val)
    of "extend-exclude": result[1] = tomlStrings(val)
    of "include": result[2] = tomlStrings(val)
    of "color": result[3] = (if val.startsWith("true"): 1 elif val.startsWith("false"): 0 else: -1)
    else: discard

var nphCache: Table[string, (string, seq[Regex])]    # .nph.toml → (its stamp, exclude + extend-exclude compiled)

proc nphTomlFor*(path: string): string =
  ## the .nph.toml nearest above a file (its folder or one above, up to the repository's top) — "" none
  var d = parentDir(path)
  for _ in 0 .. 40:
    if fileExists(d / ".nph.toml"): return d / ".nph.toml"
    if dirExists(d / ".git") or d.len <= 1: break
    let up = parentDir(d)
    if up == d or up.len == 0: break
    d = up
  ""

proc nphExcluded*(path: string): bool =
  ## does the project's .nph.toml leave this file out (its exclude / extend-exclude patterns, on the path from the
  ## .nph.toml's folder)? Formatting on save and formatting the project skip it, as nph would
  let t = nphTomlFor(path)
  if t.len == 0: return false
  var st = ""
  try: st = $getLastModificationTime(t).toUnix & ":" & $getFileSize(t)
  except CatchableError: return false
  var res: seq[Regex]
  if t in nphCache and nphCache[t][0] == st: res = nphCache[t][1]
  else:
    let (ex, ext, _, _) = readNphToml(t)
    for pat in ex & ext:
      try: res.add compileRegex(pat)
      except CatchableError: discard
    nphCache[t] = (st, res)
  let rel = relativePath(path, parentDir(t)).replace('\\', '/')
  for re in res:
    if re.matches(rel) or re.matches("/" & rel): return true
  false

# ── the command ──

func usageText(prog, version: string): string =
  prog & " " & version & " — ned's formatters: Nim (nph's style, checked), JSON, Markdown tables, CSS/SCSS, C, YAML, " &
  "TOML, HTML, SQL\n\n" &
  "Usage: " & prog & " [options] FILE|FOLDER…     " & prog & " [options] -   (stdin → stdout)\n\n" &
  "  --check               change nothing; exit 1 when a file would change (CI, hooks)\n" &
  "  --diff                show what would change (a unified diff), change nothing (with --check: exit 1)\n" &
  "  --out:FILE            write the result there (one input file)\n" &
  "  --outDir:DIR          write the results under DIR (the same relative paths)\n" &
  "  --line-length:N       where Nim lines wrap (default: nim.format.lineLength, else .editorconfig's\n" &
  "                        max_line_length, else 88)\n" &
  "  --include:REGEX       in folders: the paths to take (default: every kind of file ned formats)\n" &
  "  --exclude:REGEX       in folders: paths to leave out, instead of the usual ones (.git, nimcache, build …)\n" &
  "  --extend-exclude:REGEX  in folders: paths to leave out as well as the usual ones\n" &
  "  --config:FILE         nph's settings file (default: .nph.toml here — exclude, extend-exclude, include)\n" &
  "  --stdin-name:PATH     with -: the file the text is from (its kind, its project's settings)\n" &
  "  --color, --no-color   colours in --diff (default: when writing to a terminal)\n" &
  "  --verify              check each Nim result with Nim's own parser too (needs the compiler sources; the\n" &
  "                        checker is built once) — also nim.format.verify in your settings\n" &
  "  --install-hook        a git pre-commit hook: staged Nim files must be formatted (--force: replace yours)\n" &
  "  --quiet               say only what went wrong\n" &
  "  --version, --help\n\n" &
  "Files named on the command line are always taken; the filters are for what is found in folders.\n" &
  "Layout comes from your ned settings and the project's .ned/settings.json (nim.format.*).\n" &
  "Exit status: 0 done, 1 --check: would change, 2 a file left alone (the formatter was not sure of it) or not\n" &
  "readable, 3 wrong arguments.\n"

proc ensureChecker(prog: string, quiet: bool): string =
  ## the parser check's program, built now if it is not yet (once per compiler) — "" when it cannot be
  let exe = astCheckerPath()
  if exe.len == 0:
    stderr.writeLine prog & ": --verify needs Nim's compiler sources (choosenim and source builds have them, or: " &
                     "nimble install compiler)"
    return ""
  if fileExists(exe): return exe
  let cmd = astCheckerBuildCmd()
  if not quiet: stderr.writeLine prog & ": building the Nim parser check (once for this compiler)…"
  try:
    let (o, code) = execCmdEx(cmd)
    try: removeDir(astCheckerCacheDir())
    except CatchableError: discard
    if code == 0 and fileExists(exe): return exe
    stderr.writeLine prog & ": could not build the Nim parser check: " & astCheckerFailure(o, code) &
                     (if o.strip.len > 0: "\n" & o.strip else: "")
  except CatchableError as e:
    stderr.writeLine prog & ": could not build the Nim parser check: " & e.msg
  ""

proc fmtCliMain*(args: seq[string], prog = "nedfmt", version = "", nimFmt: FmtFn = nil): int =
  var check, diff, quiet, hook, force, verify = false
  var color = isatty(stdout) and getEnv("NO_COLOR").len == 0
  var colorSet = false
  var outFile, outDir, stdinName, configFile = ""
  var lineLength = 0
  var incl, excl, extExcl: seq[string]
  var inputs: seq[string]
  var onlyFiles = false
  for a in args:
    if onlyFiles or not a.startsWith("--"):
      inputs.add a
      continue
    let colon = a.find({':', '='})
    let name = (if colon > 0: a[2 ..< colon] else: a[2 .. ^1]).toLowerAscii
    let val = if colon > 0: a[colon + 1 .. ^1] else: ""
    case name
    of "": onlyFiles = true
    of "check": check = true
    of "diff": diff = true
    of "quiet", "q": quiet = true
    of "color":
      color = true
      colorSet = true
    of "no-color", "nocolor":
      color = false
      colorSet = true
    of "out", "output", "o": outFile = val
    of "outdir": outDir = val
    of "config": configFile = val
    of "stdin-name", "stdin-filepath", "stdin-filename": stdinName = val
    of "line-length", "linelength", "max-width":
      try: lineLength = parseInt(val)
      except ValueError:
        stderr.writeLine prog & ": --line-length needs a number"
        return 3
    of "include": incl.add val
    of "exclude": excl.add val
    of "extend-exclude", "extendexclude": extExcl.add val
    of "install-hook": hook = true
    of "force": force = true
    of "verify": verify = true
    of "help", "h":
      stdout.write usageText(prog, version)
      return 0
    of "version", "v":
      echo prog & " " & version
      return 0
    else:
      stderr.writeLine prog & ": unknown option " & a & " (" & prog & " --help)"
      return 3
    if name in ["out", "output", "o", "outdir", "config", "include", "exclude", "extend-exclude", "extendexclude"] and
       val.len == 0:
      stderr.writeLine prog & ": --" & name & " needs a value (--" & name & ":…)"
      return 3
  if hook:
    let self = try: getAppFilename() except CatchableError: ""
    return installHook(prog, (if self.len > 0: self else: "nedfmt"), (if prog.endsWith("--format"): "--format " else: ""),
                       force)
  if inputs.len == 0:
    stderr.write usageText(prog, version)
    return 3
  if outFile.len > 0 and outDir.len > 0:
    stderr.writeLine prog & ": --out and --outDir cannot both be given"
    return 3
  if diff and (outFile.len > 0 or outDir.len > 0):
    stderr.writeLine prog & ": --diff changes nothing: it cannot be used with --out or --outDir"
    return 3
  if outFile.len > 0 and (inputs.len > 1 or dirExists(inputs[0])):
    stderr.writeLine prog & ": --out takes one input file (use --outDir for several)"
    return 3
  # nph's settings file: the command line's patterns win
  let (tExcl, tExt, tIncl, tColor) = readNphToml(if configFile.len > 0: configFile else: ".nph.toml")
  if configFile.len > 0 and not fileExists(configFile):
    stderr.writeLine prog & ": " & configFile & ": no such file"
    return 3
  if excl.len == 0: excl = tExcl
  if incl.len == 0: incl = tIncl
  extExcl = tExt & extExcl
  if not colorSet and tColor >= 0: color = tColor == 1
  var includeRe, excludeRe: seq[Regex]
  for (list, isIncl) in [(incl, true), (excl & extExcl, false)]:
    for pat in list:
      try:
        let re = compileRegex(pat)
        if isIncl: includeRe.add re else: excludeRe.add re
      except CatchableError as e:
        stderr.writeLine prog & ": the pattern " & pat & ": " & e.msg
        return 3
  let usualSkips = excl.len == 0         # (--exclude replaces the usual folders left out; .git always is)
  var checker = ""
  var checkerTried = false
  if verify:
    checker = ensureChecker(prog, quiet)
    if checker.len == 0: return 3
    checkerTried = true
  proc settingsFor(p: string) =
    applySettingsFor(p)
    if lineLength > 0:
      FmtWidth = clamp(lineLength, 40, 240)
      FmtMax = FmtWidth
    if (verify or fmtVerifyWanted) and not checkerTried:
      checkerTried = true
      checker = ensureChecker(prog, quiet)
    fmtVerifyExe = if verify or fmtVerifyWanted: checker else: ""
  # stdin → stdout
  if inputs == @["-"]:
    let name = if stdinName.len > 0: stdinName else: "stdin.nim"
    let kind = fmtKindOf(name)
    if kind.len == 0:
      stderr.writeLine prog & ": " & name & ": no formatter for this kind of file"
      if not check and not diff: stdout.write readAll(stdin)
      return 2
    settingsFor(absolutePath(name))
    let text = readAll(stdin)
    let (res, err) = fmtTextOf(kind, text, absolutePath(name), nimFmt)
    if err.len > 0:
      stderr.writeLine name & ": " & err
      if not check and not diff: stdout.write text
      return 2
    if diff and res != text: stdout.write unifiedDiff(text, res, name, name & " (formatted)", color)
    if check or diff:
      if res != text:
        if check: stderr.writeLine name & ": would change"
        return (if check: 1 else: 0)
      return 0
    stdout.write res
    return 0
  if "-" in inputs:
    stderr.writeLine prog & ": - (stdin) is the only input when it is given"
    return 3
  # files and folders
  let cwd = getCurrentDir()
  let outAbs = if outDir.len > 0: absolutePath(outDir) else: ""
  var files: seq[(string, string)]          # (the path shown, the path under --outDir)
  proc underOut(rel: string): string =
    ## where a file goes under --outDir: its path as given (nph's way), or from its folder when that climbs out
    if rel.isAbsolute or rel.startsWith(".."): "" else: rel
  for inp in inputs:
    if dirExists(inp):
      let base = absolutePath(inp)
      for p in filesIn(base, usualSkips):
        if outAbs.len > 0 and (p & "/").startsWith(outAbs & "/"): continue
        let rel = relativePath(p, base)
        var take = if includeRe.len == 0: fmtKindOf(p).len > 0 else: false
        for re in includeRe:
          if re.matches(rel): take = true
        for re in excludeRe:
          if re.matches(rel): take = false
        if not take or fmtKindOf(p).len == 0: continue
        let shown = relativePath(p, cwd)
        let o = underOut(shown)
        files.add (shown, (if o.len > 0: o else: extractFilename(base) / rel))
    elif fileExists(inp):
      let o = underOut(inp)
      files.add (inp, (if o.len > 0: o else: extractFilename(inp)))
    else:
      stderr.writeLine inp & ": no such file or folder"
      return 2
  var changed, unchanged, refused = 0
  for (f, rel) in files:
    let kind = fmtKindOf(f)
    if kind.len == 0:
      stderr.writeLine f & ": no formatter for this kind of file — left alone"
      inc refused
      continue
    var text = ""
    try: text = readFile(f)
    except CatchableError as e:
      stderr.writeLine f & ": " & e.msg
      inc refused
      continue
    settingsFor(f)
    let (res, err) = fmtTextOf(kind, text, absolutePath(f), nimFmt)
    if err.len > 0:
      stderr.writeLine f & ": " & err
      inc refused
      continue
    if res == text: inc unchanged
    else: inc changed
    if diff or check:
      if res != text:
        if diff: stdout.write unifiedDiff(text, res, f, f & " (formatted)", color)
        if check and not quiet: echo f & ": would change"
      continue
    let dest = if outFile.len > 0: outFile elif outDir.len > 0: outDir / rel else: f
    if dest == f and res == text: continue
    try:
      if dest != f:
        let d = parentDir(absolutePath(dest))
        if d.len > 0: createDir(d)
        writeFile(dest, res)
      else: writeAtomically(f, res)
      if not quiet and res != text: echo f & ": formatted" & (if dest != f: " → " & dest else: "")
    except CatchableError as e:
      stderr.writeLine f & ": cannot write: " & e.msg
      inc refused
  if (check or diff) and not quiet and files.len > 0:
    var parts: seq[string]
    if changed > 0: parts.add $changed & (if changed == 1: " file" else: " files") & " would be reformatted"
    if unchanged > 0: parts.add $unchanged & (if unchanged == 1: " file" else: " files") & " would be left unchanged"
    if refused > 0: parts.add $refused & (if refused == 1: " file" else: " files") & " left alone"
    stdout.flushFile()
    stderr.writeLine parts.join(", ") & "."
  if refused > 0: return 2
  if check and changed > 0: return 1
  0
