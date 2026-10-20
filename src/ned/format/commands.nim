func builtinFmtKind(path, langId: string): string =
  ## which of ned's own formatters fits a file: "nim", "json", "markdown", "css", "scss" (with // comments) or ""
  let ext = splitFile(path).ext.toLowerAscii
  if ext in [".nim", ".nims", ".nimble"] or langId == "nim": return "nim"
  if ext in [".json", ".jsonc"] or (langId == "json" and ext != ".json5"): return "json"
  if ext in [".md", ".markdown"] or langId == "markdown": return (if ext == ".mdx": "" else: "markdown")
  if ext in [".scss", ".less"]: return "scss"
  if ext == ".css" or langId == "css": return "css"
  if ext in [".c", ".h"] or langId == "c": return "c"
  if ext in [".yaml", ".yml"]: return "yaml"
  if ext == ".toml": return "toml"                  # (not .ini, .cfg …: TOML's colours, not its rules)
  if ext in [".html", ".htm", ".xhtml"]: return "html"
  if ext in [".sql", ".psql", ".pgsql", ".mysql"] or langId == "sql": return "sql"
  ""

func looksCpp(text: string): bool =
  ## C++ rather than C (a .h file can be either): templates and namespaces give it away
  for w in ["template<", "template <", "namespace ", "std::", "class ", "public:", "private:", "nullptr"]:
    if w in text: return true

var emitClangMemo: Table[string, string]   # (.clang-format and its time, the block) → clang-format's answer

proc clangStyleKey(dir: string): string =
  ## the .clang-format clang-format would use from dir, and when it changed ("" none)
  var d = dir
  for _ in 0 .. 40:
    for n in [".clang-format", "_clang-format"]:
      let p = d / n
      if fileExists(p):
        try: return p & "@" & $getLastModificationTime(p).toUnix
        except CatchableError: return p
    let up = parentDir(d)
    if up.len == 0 or up == d: break
    d = up
  ""

proc formatEmitBlocks(text, path: string): (string, int, string) =
  ## the C in each {.emit: """…""".} of a Nim file formatted (nim.formatEmitC): clang-format when it is installed
  ## (your .clang-format applies), else ned's own C formatter — (new text, blocks changed, what formatted them).
  ## A block clang-format answered for before, with the same style file, is not sent again
  if not cfgFormatEmitC or "emit" notin text: return (text, 0, "")
  let clang: ClangFn = if haveExe("clang-format"):
      proc(c, fake, dir: string): string =
        let key = clangStyleKey(dir) & "\0" & fake & "\0" & c
        if key in emitClangMemo: return emitClangMemo[key]
        let (ok, o, _) = runFilter("clang-format --sort-includes=false --assume-filename=" & quoteShell(fake), c, dir, 5000)
        result = if ok: o else: ""
        if ok:
          if emitClangMemo.len > 2000: emitClangMemo.clear()
          emitClangMemo[key] = result
    else: nil
  formatEmitC(text, path, cfgNimTarget == "cpp", clang, rootDir)

var
  fmtCheckerBuilding = false
  fmtCheckerNoted = false
  fmtVerifyFromCli = false       # (ned --format: fmtCliMain chose the checker)

proc fmtCheckerExe(): string =
  ## nim.format.verify: Nim's own parser as the formatter's second check — the checker program, built once in the
  ## background against the compiler sources here (until it is ready, the formatter's own check is the one)
  if not cfgFormatVerify: return ""
  let exe = astCheckerPath()
  if exe.len == 0:
    if not fmtCheckerNoted:
      fmtCheckerNoted = true
      warn("nim.format.verify: no Nim compiler sources here (choosenim and source builds have them, or: nimble " &
           "install compiler) — the formatter's own check is used")
    return ""
  if fileExists(exe): return exe
  if not fmtCheckerBuilding:
    let cmd = astCheckerBuildCmd()
    if cmd.len == 0: return ""
    fmtCheckerBuilding = true
    info("nim.format.verify: building the Nim parser check (once, in the background)…")
    discard startJob(jkTool, cmd, getHomeDir(), proc(j: Job) =
      fmtCheckerBuilding = false
      if j.code == 0 and fileExists(exe): info("The Nim parser check is ready: formatting is checked with it too")
      else:
        let l = j.output.strip.splitLines
        error("Could not build the Nim parser check" & (if l.len > 0: ": " & truncTo(l[^1], 80) else: "")))
  ""

proc nimFormatAll(text, path: string, ownWidth = true): (string, string) =
  ## ned's own Nim formatter on a whole file (checked by Nim's parser too with nim.format.verify), then the C in
  ## its emits (nim.formatEmitC); ownWidth: at the file's line length (nimLineLength — else FmtWidth as it is)
  var err = ""
  var r = ""
  var fresh: seq[(string, string)]       # (the statements formatted this time: the rest are remembered)
  if ownWidth and path.len > 0:
    withNimLineLength(path):
      r = fFormatPieces(text, err, fresh)
  else: r = fFormatPieces(text, err, fresh)
  if err.len > 0: return (text, err)
  if not fmtVerifyFromCli: fmtVerifyExe = fmtCheckerExe()
  let why = verifyNim(text, r)
  if why.len > 0:
    if ownWidth and path.len > 0:
      withNimLineLength(path): fForgetPieces(fresh)
    else: fForgetPieces(fresh)
    return (text, why)
  r = formatEmitBlocks(r, path)[0]
  (r, "")

proc builtinFormatText(kind, text: string, indentW = 2, path = ""): (string, string) =
  ## (result, error) of ned's own formatter `kind` (builtinFmtKind) on a whole file's text
  try:
    case kind
    of "nim": nimFormatAll(text, path)
    of "c": fmtC(text, max(1, indentW), looksCpp(text))
    of "json": fmtJson(text, max(1, indentW))
    of "markdown": fmtMarkdown(text)
    of "css": fmtCss(text, max(1, indentW))
    of "scss": fmtCss(text, max(1, indentW), lineComments = true)
    of "yaml": fmtYaml(text, max(1, indentW))
    of "toml": fmtToml(text)
    of "html": fmtHtml(text, max(1, indentW))
    of "sql": fmtSql(text, max(1, indentW))
    else: (text, "no built-in formatter")
  except CatchableError, Defect: (text, "the built-in formatter failed on this file (please report it)")

proc nimFormatCmds(b: Buffer): seq[string] =
  ## the external formatter to run for a Nim file ("" entries never): a "formatters" entry, else nim.formatter
  if b.lang.id in cfgUserFmt: return @[cfgUserFmt[b.lang.id]]
  case cfgNimFormatter
  of "nph": @["nph -"]
  of "nimpretty": @["nimpretty --out:$out $in"]
  else: @[]

proc formatBuiltin(b: Buffer, quiet = false) =
  ## ned's own Nim formatter: in-process, nph's style; it checks its own result
  let t0 = getMonoTime()
  var err = ""
  let text = b.allText & "\n"
  var res = ""
  try: (res, err) = nimFormatAll(text, b.path)
  except CatchableError, Defect: err = "the built-in formatter failed on this file (please report it)"
  if err.len > 0:
    error("Format: " & err)
    return
  if res == text:
    if not quiet: info("Already formatted")
    return
  b.setTextMinimal(res)
  info("Formatted (built-in, nph style) in " & $msSince(t0) & " ms")

proc formatLineRange(b: Buffer, l0, l1: int, quiet: bool): bool =
  ## lines l0..l1 of a Nim file with the built-in formatter, as a block at their own indentation; true when done
  var ind = int.high
  for l in l0 .. l1:
    if b.lines[l].strip.len > 0: ind = min(ind, leadingWs(b.lines[l]).len)
  if ind == int.high: return false
  var src = ""
  for l in l0 .. l1:
    let s = b.lines[l]
    src.add (if s.len >= ind: s[ind .. ^1] else: "") & "\n"
  var err = ""
  let keepW = FmtWidth
  FmtWidth = nimLineLength(b.path)
  FmtMax = max(40, FmtWidth - ind)
  var res = ""
  try: res = fFormat(src, err)
  except CatchableError, Defect: err = "the built-in formatter failed on this selection"
  FmtWidth = keepW
  FmtMax = FmtWidth
  if err.len == 0:
    fmtVerifyExe = fmtCheckerExe()
    err = verifyNim(src, res)
  if err.len > 0:
    if not quiet: error("Format selection: " & err)
    return false
  var outp: seq[string]
  for l in res.strip(leading = false, chars = {'\n'}).split('\n'):
    outp.add (if l.len > 0: spaces(ind) & l else: "")
  if outp == b.lines[l0 .. l1]: return true
  var all = if l0 > 0: b.lines[0 ..< l0] else: @[]
  all.add outp
  if l1 + 1 < b.lines.len: all.add b.lines[l1 + 1 .. ^1]
  b.setTextMinimal(all.join("\n"))
  if not quiet: info("Formatted " & $(l1 - l0 + 1) & " line(s)")
  true

proc formatSelection(b: Buffer) =
  ## the selected lines only, with the built-in Nim formatter: formatted as a block at their own indentation
  if not b.canEdit(): return
  if b.lang.mode != lmNim:
    let s = lspReady(b)
    if s != nil and s.caps != nil and s.caps{"documentRangeFormattingProvider"} != nil and
       not (s.caps["documentRangeFormattingProvider"].kind == JBool and not s.caps["documentRangeFormattingProvider"].getBool):
      let (ra, re) = b.primary.range
      lspSync(b)
      discard s.lspRequest("textDocument/rangeFormatting", %*{"textDocument": b.docId,
        "range": {"start": s.lspPos(b, Pos(line: ra.line, col: 0)), "end": s.lspPos(b, re)},
        "options": {"tabSize": b.indentW(), "insertSpaces": b.indent != "\t"}},
        LspReq(kind: lrFormat, bufId: b.id))
      return
    info("Format selection needs the built-in Nim formatter or a language server that formats ranges — " &
         "Alt+F formats the whole file")
    return
  let (a, e) = b.primary.range
  var l1 = e.line
  if e.col == 0 and l1 > a.line: dec l1
  discard b.formatLineRange(a.line, l1, quiet = false)

proc formatBuffer(b: Buffer) =
  if not b.canEdit(): return
  var cmds: seq[string]
  if b.lang.mode != lmNim and b.primary.hasSel and b.primary.range[0].line != b.primary.range[1].line:
    # lines selected, a language server that formats ranges: just those (Alt+F)
    let s = lspReady(b)
    if s != nil and s.caps != nil and s.caps{"documentRangeFormattingProvider"} != nil and
       not (s.caps["documentRangeFormattingProvider"].kind == JBool and not s.caps["documentRangeFormattingProvider"].getBool):
      formatSelection(b)
      return
  if b.lang.mode == lmNim:
    cmds = nimFormatCmds(b)
    if cmds.len == 0:
      # with a selection over several lines: only those lines
      if b.primary.hasSel and b.primary.range[0].line != b.primary.range[1].line:
        formatSelection(b)
        return
      formatBuiltin(b)
      return
    let exe = cmds[0].firstWord
    if findExe(exe).len == 0:
      error(exe & " is not installed (" & (if exe == "nph": "nimble install nph" else: "it comes with Nim") &
            ") — or use ned's own: \"nim.formatter\": \"builtin\"")
      return
  else:
    if b.lang.id in cfgUserFmt: cmds.add cfgUserFmt[b.lang.id]
    for c in b.lang.fmt: cmds.add c
  for c in cmds:
    let exe = c.firstWord
    if findExe(exe).len == 0: continue
    let text = b.allText & "\n"
    let cwd = if b.path.len > 0: parentDir(b.path) else: rootDir
    var ok: bool
    var o, e: string
    if "$in" in c:
      let inP = privDir() / ("ned_fmt_in_" & $getCurrentProcessId() & splitFile(b.path).ext)
      let outP = privDir() / ("ned_fmt_out_" & $getCurrentProcessId() & splitFile(b.path).ext)
      try:
        writeFile(inP, text)
        (ok, o, e) = runFilter(expandCmd(c, b).replace("$in", quoteShell(inP)).replace("$out", quoteShell(outP)), "", cwd)
        if ok: o = readFile(outP)
        removeFile(inP)
        removeFile(outP)
      except CatchableError as ex:
        ok = false
        e = ex.msg
    else:
      (ok, o, e) = runFilter(expandCmd(c, b), text, cwd)
    if ok and o.strip.len > 0:
      # (nph or nimpretty for the Nim, then the C in its emits)
      if b.lang.mode == lmNim: o = formatEmitBlocks(o, b.path)[0]
      b.setTextMinimal(o)
      info("Formatted with " & exe)
    else:
      let first = (e & o).strip.splitLines
      error(exe & ": " & (if first.len > 0: first[0] else: "failed"))
    return
  let bk = builtinFmtKind(b.path, b.lang.id)
  proc builtin(b: Buffer) =
    let t0 = getMonoTime()
    let text = b.allText & "\n"
    let (res, err) = builtinFormatText(bk, text, b.indentW(), b.path)
    if err.len > 0:
      error("Format: " & err)
      return
    if res == text:
      info("Already formatted")
      return
    b.setTextMinimal(res)
    info("Formatted (built-in" & (if bk == "markdown": ": tables lined up" elif bk == "yaml": " YAML: indentation and spacing" elif bk == "toml": " TOML: spacing" elif bk == "c": " C formatter: " &
         "indentation and spaces — clang-format does more" else: "") & ") in " & $msSince(t0) & " ms")
  if bk == "json":
    builtin(b)
    return
  let s = lspReady(b)
  if s != nil and s.caps != nil and s.caps{"documentFormattingProvider"} != nil:
    discard s.lspRequest("textDocument/formatting", %*{"textDocument": b.docId,
      "options": {"tabSize": b.indentW(), "insertSpaces": b.indent != "\t"}},
      LspReq(kind: lrFormat, bufId: b.id))
    return
  if bk in ["markdown", "css", "scss", "c", "yaml", "toml", "html", "sql"]:
    builtin(b)
    return
  let hint = if b.lang.fmt.len > 0: " (install " & b.lang.fmt[0].firstWord & ")" else: ""
  info("No formatter for " & b.lang.name & hint)

proc embeddedStringAt(b: Buffer, p: Pos): (int, int, seq[string], Lang) =
  ## the triple-quoted string at p in a Nim file and the language ned reads its text as: (line, column of the
  ## text, its lines, language) — the language is nil when there is none or it is plain text
  result = (-1, 0, @[], nil)
  if b.lang == nil or b.lang.mode != lmNim or b.lines.len > 20000: return
  for (l, c, body) in tripleStrings(b.lines):
    let last = l + body.high
    if p.line < l or p.line > last: continue
    if p.line == l and p.col < c - 3: continue
    let closeCol = (if body.len == 1: c + body[0].len else: body[^1].len)
    if p.line == last and p.col > closeCol + 3: continue
    var lg: Lang = nil
    for k, t in body:
      if t.strip.len == 0: continue
      let col = (if k == 0: c else: 0) + (t.len - t.strip(trailing = false).len)
      lg = b.langAt(Pos(line: l + k, col: col))
      break
    if lg != nil and (lg == b.lang or lg.id in ["nim", "nimfmt", "text"]): lg = nil
    return (l, c, body, lg)

proc formatEmbedded(b: Buffer): bool =
  ## the code in the triple-quoted string at the cursor (JSON, CSS, C in an emit, HTML, SQL …) formatted as
  ## that language and put back at the string's indentation; false when the cursor is not in such a string
  let (l, c, body, lg) = b.embeddedStringAt(b.primary.head)
  if l < 0 or lg == nil: return false
  if not b.canEdit(): return true
  if body.len < 2:
    info("A one-line string stays as it is — put its text on lines of its own to format it")
    return true
  let firstInline = body[0].strip.len > 0
  let lastInline = body[^1].strip.len > 0
  var content: seq[string]
  if firstInline: content.add body[0].strip
  for k in 1 ..< body.high: content.add body[k]
  if lastInline: content.add body[^1]
  var base = high(int)
  for t in content:
    if t.strip.len > 0: base = min(base, t.len - t.strip(trailing = false).len)
  if base == high(int):
    info("Nothing to format in this string")
    return true
  var plain: seq[string]
  for k, t in content:
    plain.add (if t.strip.len == 0: "" elif k == 0 and firstInline: t else: t[min(base, t.len) .. ^1])
  let text = plain.join("\n").strip(chars = {'\n'}) & "\n"
  var res = ""
  var err = ""
  var by = "built-in"
  let bk = case lg.id
           of "json": "json"
           of "css": "css"
           of "scss", "less": "scss"
           of "c", "cpp": "c"             # (C in an emit: clang-format when installed, else ned's own)
           of "yaml": "yaml"
           of "toml": "toml"
           of "markdown": "markdown"
           of "html": "html"
           of "sql": "sql"
           else: ""
  # a formatter of your own or the language's tool first, then ned's own
  var cmd = ""
  if lg.id in cfgUserFmt and "$in" notin cfgUserFmt[lg.id]: cmd = cfgUserFmt[lg.id]
  else:
    for fc in lg.fmt:
      let w = fc.splitWhitespace
      if w.len > 0 and haveExe(w[0]) and "$in" notin fc:
        cmd = fc
        break
  if cmd.len > 0:
    let fake = parentDir(if b.path.len > 0: b.path else: rootDir / "x") / ("embedded." & (if lg.id == "javascript": "js" elif lg.id == "cpp": "cpp" else: lg.id))
    let (ok, o, e) = runFilter(cmd.replace("$file", fake).replace("$dir", parentDir(fake)).replace("$name", "embedded"),
                               text, (if b.path.len > 0: parentDir(b.path) else: rootDir))
    by = cmd.firstWord
    if ok and o.strip.len > 0: res = o
    else:
      let first = (e & o).strip.splitLines
      err = by & ": " & (if first.len > 0: first[0] else: "failed")
  elif bk.len > 0: (res, err) = builtinFormatText(bk, text, b.indentW())
  else:
    let hint = if lg.fmt.len > 0: " (install " & lg.fmt[0].firstWord & ")" else: ""
    info("No formatter for the " & lg.name & " in this string" & hint)
    return true
  if err.len > 0:
    error("Format: " & err)
    return true
  var outL: seq[string]
  for t in res.strip(chars = {'\n'}).split('\n'):
    outL.add (if t.strip.len == 0: "" else: spaces(base) & t.strip(leading = false))
  let closeLine = l + body.high
  let closeCol = body[^1].len
  let closing = if lastInline: "" else: "\n" & body[^1]
  let newText = "\n" & outL.join("\n") & closing
  let a = Pos(line: l, col: c)
  let e = Pos(line: closeLine, col: closeCol)
  if b.getText(a, e) == newText:
    info("The " & lg.name & " in this string is formatted already")
    return true
  b.beginEdit()
  discard b.replaceText(a, e, newText)
  b.endEdit()
  b.normalize()
  info("Formatted the " & lg.name & " in this string (" & by & ")")
  true

proc cmdFormatEmbedded() =
  let b = buf()
  if not formatEmbedded(b):
    info("Put the cursor in a \"\"\"string\"\"\" that holds code (JSON, CSS, HTML, SQL, C in an emit …)")

proc changedLineSet(b: Buffer): (bool, HashSet[int]) =
  ## the lines changed since git last saw the file (its staged or committed version): (known, lines) — not known
  ## for a file git does not have
  if not b.gitHasBase: return (false, initHashSet[int]())
  var s: HashSet[int]
  let ops = lineDiff(b.gitBase, b.lines)
  for k, op in ops:
    if op.kind == '+': s.incl op.bLine
    elif op.kind == '-':
      # a line deleted: the lines on both sides of where it was
      var q = k - 1
      while q >= 0 and ops[q].bLine < 0: dec q
      if q >= 0: s.incl ops[q].bLine
      q = k + 1
      while q < ops.len and ops[q].bLine < 0: inc q
      if q < ops.len: s.incl ops[q].bLine
  (true, s)

proc keepFormatOf(orig, formatted: seq[string], changed: HashSet[int]): seq[string] =
  ## the formatter's changes only where they touch a changed line (a re-indented block is one change: all of it
  ## or none); elsewhere the lines as they were
  let ops = lineDiff(orig, formatted)
  var i = 0
  while i < ops.len:
    if ops[i].kind == ' ':
      result.add ops[i].text
      inc i
      continue
    var j = i
    var touches = false
    var olds, news: seq[string]
    while j < ops.len and ops[j].kind != ' ':
      if ops[j].kind == '-':
        olds.add ops[j].text
        if ops[j].aLine in changed: touches = true
      else: news.add ops[j].text
      inc j
    if olds.len == 0:
      # lines only added (a blank line put between): when the lines around them changed
      let before = if i > 0: ops[i - 1].aLine else: -1
      let after = if j < ops.len: ops[j].aLine else: -1
      touches = before in changed or after in changed
    for x in (if touches: news else: olds): result.add x
    i = j

proc formatOnSave0(b: Buffer)

proc formatOnSave(b: Buffer) =
  ## the formatter on save — on the whole file, or (editor.formatOnSaveScope: changed) only where the lines
  ## changed since git last saw the file are. A Nim file the project's .nph.toml excludes is left as it is
  if b.lang != nil and b.lang.mode == lmNim and b.path.len > 0 and nphExcluded(b.path): return
  if cfgFormatScope != "changed":
    formatOnSave0(b)
    return
  let (known, changed) = changedLineSet(b)
  if not known:
    formatOnSave0(b)                         # (a file git does not have: all of it is new)
    return
  if changed.len == 0: return
  let before = b.lines
  formatOnSave0(b)
  if b.lines == before: return
  var merged = keepFormatOf(before, b.lines, changed)
  if merged == b.lines: return
  if b.lang.mode == lmNim:
    # (a Nim file that is half formatted must still be the same code: the formatter reads it again)
    var err = ""
    discard fFormat(merged.join("\n") & "\n", err)
    if err.len > 0: merged = before
  b.setTextMinimal(merged.join("\n"))

proc formatOnSave0(b: Buffer) =
  ## only fast, synchronous formatters (external tool or JSON) — never leaves the file dirty after saving
  var cmds: seq[string]
  if b.lang.mode == lmNim:
    cmds = nimFormatCmds(b)
    if cmds.len == 0:
      formatBuiltin(b, quiet = true)
      return
  else:
    if b.lang.id in cfgUserFmt: cmds.add cfgUserFmt[b.lang.id]
    for c in b.lang.fmt: cmds.add c
  for c in cmds:
    let w = c.splitWhitespace()
    if w.len > 0 and haveExe(w[0]):
      formatBuffer(b)
      return
  # ned's own JSON, Markdown and CSS formatters (quietly: a file it is not sure about stays as it is)
  let bk = builtinFmtKind(b.path, b.lang.id)
  if bk in ["json", "markdown", "css", "scss", "c", "yaml", "toml", "html", "sql"]:
    let text = b.allText & "\n"
    let (res, err) = builtinFormatText(bk, text, b.indentW(), b.path)
    if err.len == 0 and res != text: b.setTextMinimal(res)
