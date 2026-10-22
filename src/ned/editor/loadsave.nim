# ════════════════════════════════════════════════════════════════════════════
#  Loading & saving
# ════════════════════════════════════════════════════════════════════════════

func detectIndent(b: Buffer) =
  var tabs, spaced = 0
  var counts: array[9, int]
  var prev = 0
  for i in 0 ..< min(b.lines.len, 2000):
    let l = b.lines[i]
    if l.len == 0 or isBlank(l): continue
    if l[0] == '\t':
      inc tabs
      continue
    var k = 0
    while k < l.len and l[k] == ' ': inc k
    if k > 0: inc spaced
    let d = abs(k - prev)
    if d >= 2 and d <= 8: inc counts[d]
    prev = k
  if tabs > spaced and tabs > 0:
    b.indent = "\t"
  elif spaced > 0:
    var best = 0
    for d in 2..8:
      if counts[d] > counts[best] or (best == 0 and counts[d] > 0): best = d
    b.indent = spaces(if best == 0: b.lang.indentWidth else: best)
  else:
    b.indent = if b.lang.useTabs: "\t" else: spaces(max(1, b.lang.indentWidth))

proc fileStamp(path: string): (int64, int64) =
  try:
    let fi = getFileInfo(path)
    (fi.lastWriteTime.toUnix * 1000 + fi.lastWriteTime.nanosecond div 1_000_000, fi.size.int64)
  except CatchableError: (0'i64, -1'i64)

# ── .editorconfig (editorconfig.org): a project's indentation, line ends and whitespace, per file
#    (core/editorconfig reads the files) ──

const EcKnown = ["indent_style", "indent_size", "tab_width", "end_of_line", "trim_trailing_whitespace",
                 "insert_final_newline", "max_line_length", "charset"]

proc applyEditorConfig(b: Buffer) =
  ## indentation, tab width, line ends (new files), trailing whitespace and the final newline from .editorconfig
  b.ecInfo.setLen(0)
  b.tabSize = 0
  b.ecTrim = -1
  b.ecFinalNl = -1
  b.ecMaxLine = 0
  if not cfgEditorConfig or b.path.len == 0 or b.binary: return
  let props = editorConfigFor(b.path)
  if props.len == 0: return
  var t: Table[string, string]
  for (k, v, f) in props:
    t[k] = v.toLowerAscii
    if k in EcKnown: b.ecInfo.add (k, v, f)
  proc num(v: string): int =
    try: parseInt(v) except ValueError: 0
  let style = t.getOrDefault("indent_style")
  let sizeS = t.getOrDefault("indent_size")
  var size = num(sizeS)
  let tw = num(t.getOrDefault("tab_width"))
  if tw in 1 .. 32: b.tabSize = tw
  elif style == "tab" and size in 1 .. 32: b.tabSize = size
  if sizeS == "tab": size = b.tabOf
  if style == "tab": b.indent = "\t"
  elif style == "space":
    b.indent = spaces(if size in 1 .. 32: size elif b.indent != "\t": b.indent.len else: max(1, b.lang.indentWidth))
  elif size in 1 .. 32 and b.indent != "\t": b.indent = spaces(size)
  let fresh = not fileExists(b.path) or (b.lines.len == 1 and b.lines[0].len == 0)
  case t.getOrDefault("end_of_line")
  of "crlf": (if fresh: b.crlf = true)
  of "lf": (if fresh: b.crlf = false)
  else: discard
  case t.getOrDefault("trim_trailing_whitespace")
  of "true": b.ecTrim = 1
  of "false": b.ecTrim = 0
  else: discard
  case t.getOrDefault("insert_final_newline")
  of "true": b.ecFinalNl = 1
  of "false": b.ecFinalNl = 0
  else: discard
  let ml = num(t.getOrDefault("max_line_length"))
  if ml in 1 .. 2000: b.ecMaxLine = ml

proc refreshEditorConfig() =
  ## after an .editorconfig changed (or the setting): every open file looks again
  editorConfigForget()
  for b in bufs:
    if b.path.len == 0 or b.binary: continue
    let ind = b.indent
    b.detectIndent()
    b.applyEditorConfig()
    if b.ecInfo.len == 0 and b.dirty: b.indent = ind

proc iconvConvert(bytes, frm, to: string): (bool, string) =
  ## through iconv (an encoding ned does not convert itself)
  if findExe("iconv").len == 0: return (false, "")
  let base = getTempDir() / ("ned_iconv_" & $getCurrentProcessId())
  try:
    writeFile(base & ".in", bytes)
    let code = execShellCmd("iconv -f " & quoteShell(frm) & " -t " & quoteShell(to) & " < " & quoteShell(base & ".in") &
                            " > " & quoteShell(base & ".out") & " 2>/dev/null")
    let o = if code == 0: readFile(base & ".out") else: ""
    removeFile(base & ".in")
    removeFile(base & ".out")
    (code == 0, o)
  except CatchableError: (false, "")

proc decodeFile(bytes, enc: string): (bool, string) =
  ## a file's bytes in `enc` → the UTF-8 ned keeps
  if enc in BuiltinEncodings: decode(bytes, enc) else: iconvConvert(bytes, enc, "UTF-8")

proc encodeFile(text, enc: string): (bool, string, int) =
  ## the text → the file's bytes in `enc` (false: a character it cannot hold, at that byte; -1: iconv failed)
  if enc in BuiltinEncodings: encode(text, enc)
  else:
    let (ok, o) = iconvConvert(text, "UTF-8", enc)
    (ok, o, -1)

proc setContent(b: Buffer, content: string) =
  # one pass to count line ends; the text is split without a copy unless it has CRLF line ends
  b.nesHas = false
  b.wkLogFrom = -1
  var nl, crnl = 0
  var lastNl = -1
  var longest = 0
  for i in 0 ..< content.len:
    if content[i] == '\n':
      inc nl
      if i > 0 and content[i - 1] == '\r': inc crnl
      longest = max(longest, i - lastNl - 1)
      lastNl = i
  longest = max(longest, content.len - lastNl - 1)
  b.large = false
  b.largeWhy = ""
  if content.len >= cfgLargeMB * 1024 * 1024:
    b.large = true
    b.largeWhy = $(content.len div (1024 * 1024)) & " MB"
  elif cfgLongLine > 0 and longest >= cfgLongLine:
    b.large = true
    b.largeWhy = "a line of " & $longest & " characters"
  b.crlf = crnl > 0 and crnl * 2 >= nl
  b.mixedEol = crnl > 0 and crnl < nl
  if crnl > 0: b.lines = content.replace("\r\n", "\n").split('\n')
  else: b.lines = content.split('\n')
  b.noEol = false
  b.blankNl = content == "\n" or content == "\r\n"
  if b.lines.len > 1 and b.lines[^1].len == 0: b.lines.setLen(b.lines.len - 1)
  elif content.len > 0: b.noEol = true
  if b.lines.len == 0: b.lines = @[""]
  b.hlStart = newSeq[LexSt](b.lines.len + 1)
  b.hlValid = 0
  b.git = newSeq[uint8](b.lines.len)
  inc b.changeId
  b.undoStack.setLen(0)                        # (the steps of the old text mean nothing for this one)
  b.redoStack.setLen(0)
  b.undoBranches.setLen(0)
  if b.cursors.len > 0: b.normalize()          # the new text may be shorter than where the cursors were
  b.topLine = clamp(b.topLine, 0, b.lines.high)

proc setContentStream(b: Buffer, path: string): bool =
  ## a big text file read into lines a megabyte at a time: the whole text is never in memory as well as its lines
  ## (an 80 MB log took 199 MB — the text and its lines at once, and the text's memory kept by the allocator)
  var f: File
  if not open(f, path): return false
  defer: close(f)
  b.nesHas = false
  b.wkLogFrom = -1
  const Chunk = 1 shl 20
  var buf = newString(Chunk)
  # first: the line ends (how many, CRLF or LF, the longest line) — so the list of lines is made once, its size known
  var nl, crnl, longest, cur, total = 0
  var prevCR = false
  while true:
    let n = f.readBuffer(addr buf[0], Chunk)
    if n <= 0: break
    total += n
    var st = 0
    while true:
      var i = buf.find('\n', st)                       # (memchr: the bytes between line ends are not looked at)
      if i < 0 or i >= n: break
      inc nl
      if (i > 0 and buf[i - 1] == '\r') or (i == 0 and prevCR): inc crnl
      longest = max(longest, cur + i - st)
      cur = 0
      st = i + 1
    cur += n - st
    prevCR = n > 0 and buf[n - 1] == '\r'
  longest = max(longest, cur)
  b.large = false
  b.largeWhy = ""
  if total >= cfgLargeMB * 1024 * 1024:
    b.large = true
    b.largeWhy = $(total div (1024 * 1024)) & " MB"
  elif cfgLongLine > 0 and longest >= cfgLongLine:
    b.large = true
    b.largeWhy = "a line of " & $longest & " characters"
  b.crlf = crnl > 0 and crnl * 2 >= nl
  b.mixedEol = crnl > 0 and crnl < nl
  # then the lines themselves
  f.setFilePos(0)
  var lines = newSeqOfCap[string](nl + 1)
  var part = ""
  while true:
    let n = f.readBuffer(addr buf[0], Chunk)
    if n <= 0: break
    var st = 0
    for i in 0 ..< n:
      if buf[i] == '\n':
        var e = i
        if part.len == 0:
          if crnl > 0 and e > st and buf[e - 1] == '\r': dec e
          lines.add buf[st ..< e]
        else:
          part.add buf[st ..< e]
          if crnl > 0 and part.len > 0 and part[^1] == '\r': part.setLen(part.len - 1)
          lines.add move(part)
          part = ""
        st = i + 1
    if st < n: part.add buf[st ..< n]
  lines.add move(part)
  b.lines = move(lines)
  b.noEol = false
  b.blankNl = total == 1 and nl == 1
  if b.lines.len > 1 and b.lines[^1].len == 0: b.lines.setLen(b.lines.len - 1)
  elif total > 0: b.noEol = true
  if b.lines.len == 0: b.lines = @[""]
  b.hlStart = newSeq[LexSt](b.lines.len + 1)
  b.hlValid = 0
  b.git = newSeq[uint8](b.lines.len)
  inc b.changeId
  b.undoStack.setLen(0)
  b.redoStack.setLen(0)
  b.undoBranches.setLen(0)
  if b.cursors.len > 0: b.normalize()
  b.topLine = clamp(b.topLine, 0, b.lines.high)
  true

# ── a binary file: the hex editor holds its bytes (editor/hexedit.nim) ──

proc hexOpen(b: Buffer, content: sink string) =
  b.hex = HexState(data: content, anchor: -1, perRow: 16, rows: 20)
  b.lines = @[""]

proc hexInfo(b: Buffer): BinInfo =
  if not b.hex.infoMade:
    b.hex.infoMade = true
    b.hex.info = binParse(b.hex.data)
  b.hex.info

var loadingHook: proc(msg: string)      # a big file: say so on screen before reading it

proc readUndo(b: Buffer)
proc writeUndo(b: Buffer)

proc loadFile(b: Buffer, path: string): bool =
  b.path = absolutePath(path).normalizedPath
  if fileExists(b.path):
    var content: string
    var streamed = false
    try:
      let size = getFileSize(b.path)
      if size > 512 * 1024 * 1024:
        error("Cannot open " & path & ": " & $(size div (1024 * 1024)) & " MB is too big to edit safely")
        return false
      if size > 16 * 1024 * 1024 and loadingHook != nil:
        loadingHook("Opening " & extractFilename(path) & " (" & $(size div (1024 * 1024)) & " MB)…")
      if size >= 8 * 1024 * 1024:
        # a big file: is it text? (its first bytes) — then it is read straight into lines
        var head = newString(8000)
        var f: File
        if open(f, b.path):
          head.setLen(f.readBuffer(addr head[0], 8000))
          close(f)
        let bom = head.startsWith("\xFF\xFE") or head.startsWith("\xFE\xFF") or head.startsWith("\xEF\xBB\xBF")
        if '\0' notin head and not bom and b.setContentStream(b.path): streamed = true
      if not streamed: content = readFile(b.path)
    except CatchableError as e:
      error("Cannot read " & path & ": " & e.msg)
      return false
    b.enc = EncUtf8
    if content.len > 0 and not streamed:
      # (a BOM: UTF-8 or UTF-16; not UTF-8: files.encoding — Windows-1252 unless you said otherwise)
      let fb = if cfgFileEncoding in ["", "auto"]: EncCp1252 else: cfgFileEncoding.toLowerAscii
      let head = content[0 ..< min(content.len, 8000)]
      let enc = if '\0' in head and not (content.startsWith("\xFF\xFE") or content.startsWith("\xFE\xFF")): EncUtf8
                else: detectEncoding(content, fb)
      if enc != EncUtf8:
        let (ok, t) = decodeFile(content, enc)
        if ok or enc in [EncUtf16Le, EncUtf16Be, EncUtf8Bom]:
          content = t
          b.enc = enc
          if not ok: warn(extractFilename(path) & ": some bytes are not " & encLabel(enc) & " (shown as �)")
        else:
          warn(extractFilename(path) & " is not UTF-8 and could not be read as " & encLabel(enc) &
               (if enc notin BuiltinEncodings and findExe("iconv").len == 0: " (iconv is not installed)" else: "") &
               " — shown as it is")
    if content.len > 0 and '\0' in content[0 ..< min(content.len, 8000)]:
      # a binary file: the hex editor (its bytes as they are, nothing turned into lines)
      b.binary = true
      b.setContent("")
      b.hexOpen(move(content))                       # (the bytes moved, not copied: a big file once in memory)
      let bi = b.hexInfo()
      info("Binary file — hex editor" & (if bi.format.len > 0: " · " & bi.format & " " & bi.kind &
           (if bi.nim: ", built with Nim" else: "") else: "") & " (Tab: hex ↔ text · Insert: insert mode · Ctrl+G offset)")
      content = ""
    if not b.binary and not streamed: b.setContent(content)
    if b.large and not b.binary:
      info("Large-file mode (" & b.largeWhy & "): no soft wrap, language server, minimap or word highlight — " &
           "palette › Large file mode turns them back on")
    if b.mixedEol:
      warn(extractFilename(path) & " has both CRLF and LF line ends — saving makes them all " &
           (if b.crlf: "CRLF" else: "LF") & " (status bar › LF/CRLF picks the other)")
    (b.mtime, b.fsize) = fileStamp(b.path)
  else:
    b.lines = @[""]
    b.hlStart = @[0'u32, 0'u32]
    b.git = @[0'u8]
  b.lang = detectLang(b.path, b.lines[0])
  b.detectIndent()
  b.applyEditorConfig()
  if b.path in savedMarks:
    for m in savedMarks[b.path]:
      if m < b.lines.len: b.marks.add m
  b.undoStack.setLen(0)
  b.redoStack.setLen(0)
  b.undoBranches.setLen(0)
  b.savedSeq = 0
  if b.path in savedPos:
    b.setSingle(savedPos[b.path])
  else:
    b.setSingle(Pos())
  if not b.binary: readUndo(b)          # the undo history from last time, when the file is unchanged
  true

proc trimTrailing(b: Buffer, all = false) =
  ## trailing spaces go from the lines you changed (git's changed lines, or what you edited since opening
  ## the file) — never from the rest of someone else's file, which would fill its diff with whitespace
  ## (editor.trimAllLines: every line)
  var curLines: HashSet[int]
  for c in b.cursors: curLines.incl c.head.line
  var any = false
  for l in 0 ..< b.lines.len:
    if l in curLines: continue
    if not (cfgTrimAll or all) and (l >= b.git.len or b.git[l] notin {1'u8, 2'u8}): continue
    let s = b.lines[l]
    if s.len > 0 and s[^1] in {' ', '\t'}:
      if not any:
        b.beginEdit()
        any = true
      let t = s.strip(leading = false, chars = {' ', '\t'})
      discard b.replaceText(Pos(line: l, col: t.len), Pos(line: l, col: s.len), "")
  if any: b.endEdit()
