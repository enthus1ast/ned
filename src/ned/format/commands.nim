proc builtinFmtKind(path, langId: string): string =
  ## which of ned's own formatters fits a file: "nim", "json", "markdown", "css", "scss" (with // comments) or ""
  let ext = splitFile(path).ext.toLowerAscii
  if ext in [".nim", ".nims", ".nimble"] or langId == "nim": return "nim"
  if ext in [".json", ".jsonc"] or (langId == "json" and ext != ".json5"): return "json"
  if ext in [".md", ".markdown"] or langId == "markdown": return (if ext == ".mdx": "" else: "markdown")
  if ext in [".scss", ".less"]: return "scss"
  if ext == ".css" or langId == "css": return "css"
  if ext in [".c", ".h"] or langId == "c": return "c"
  ""

proc looksCpp(text: string): bool =
  ## C++ rather than C (a .h file can be either): templates and namespaces give it away
  for w in ["template<", "template <", "namespace ", "std::", "class ", "public:", "private:", "nullptr"]:
    if w in text: return true

proc formatEmitBlocks(text, path: string): (string, int, string) =
  ## the C in each {.emit: """…""".} of a Nim file formatted (nim.formatEmitC): clang-format when it is installed
  ## (your .clang-format applies), else ned's own C formatter — (new text, blocks changed, what formatted them).
  ## A block with `nim symbols` in backticks, or on the string's first line, stays as it is
  result = (text, 0, "")
  if not cfgFormatEmitC or "emit" notin text: return
  var ok = true
  let toks = fLex(text, ok)
  if not ok: return
  let cpp = cfgNimTarget == "cpp"
  let clang = haveExe("clang-format")
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
    if clang:
      let fake = parentDir(if path.len > 0: path else: rootDir / "x") / (if cpp: "emit.cpp" else: "emit.c")
      let (fok, o, _) = runFilter("clang-format --sort-includes=false --assume-filename=" & quoteShell(fake), c,
                                  (if path.len > 0: parentDir(path) else: rootDir), 5000)
      if fok and o.strip.len > 0: res = o
      result[2] = "clang-format"
    if res.len == 0:
      let (r, e) = fmtC(c, 2, cpp)
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

proc nimFormatAll(text, path: string): (string, string) =
  ## ned's own Nim formatter on a whole file, then the C in its emits (nim.formatEmitC)
  var err = ""
  var r = fFormat(text, err)
  if err.len > 0: return (text, err)
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
  FmtMax = max(40, FmtWidth - ind)
  var res = ""
  try: res = fFormat(src, err)
  except CatchableError, Defect: err = "the built-in formatter failed on this selection"
  FmtMax = FmtWidth
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
    info("Formatted (built-in" & (if bk == "markdown": ": tables lined up" elif bk == "c": " C formatter: " &
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
  if bk in ["markdown", "css", "scss", "c"]:
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

proc formatOnSave(b: Buffer) =
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
  if bk in ["json", "markdown", "css", "scss", "c"]:
    let text = b.allText & "\n"
    let (res, err) = builtinFormatText(bk, text, b.indentW(), b.path)
    if err.len == 0 and res != text: b.setTextMinimal(res)
