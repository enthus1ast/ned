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

proc setContent(b: Buffer, content: string) =
  # one pass to count line ends; the text is split without a copy unless it has CRLF line ends
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
  if b.cursors.len > 0: b.normalize()          # the new text may be shorter than where the cursors were
  b.topLine = clamp(b.topLine, 0, b.lines.high)

proc hexDump(data: string, limit = 1_048_576): string =
  ## read-only view of a binary file
  let n = min(data.len, limit)
  var i = 0
  while i < n:
    result.add toHex(i, 8).toLowerAscii & "  "
    for j in 0 ..< 16:
      if i + j < n: result.add toHex(ord(data[i + j]), 2).toLowerAscii & " "
      else: result.add "   "
      if j == 7: result.add " "
    result.add " │"
    for j in 0 ..< min(16, n - i):
      let c = data[i + j]
      result.add (if c in {' ' .. '~'}: c else: '.')
    result.add "│\n"
    i += 16
  if data.len > limit: result.add "… " & $(data.len - limit) & " more bytes not shown\n"

var loadingHook: proc(msg: string)      # a big file: say so on screen before reading it

proc readUndo(b: Buffer)
proc writeUndo(b: Buffer)

proc loadFile(b: Buffer, path: string): bool =
  b.path = absolutePath(path).normalizedPath
  if fileExists(b.path):
    var content: string
    try:
      let size = getFileSize(b.path)
      if size > 512 * 1024 * 1024:
        error("Cannot open " & path & ": " & $(size div (1024 * 1024)) & " MB is too big to edit safely")
        return false
      if size > 16 * 1024 * 1024 and loadingHook != nil:
        loadingHook("Opening " & extractFilename(path) & " (" & $(size div (1024 * 1024)) & " MB)…")
      content = readFile(b.path)
    except CatchableError as e:
      error("Cannot read " & path & ": " & e.msg)
      return false
    if content.len > 0 and '\0' in content[0 ..< min(content.len, 8000)]:
      b.readOnly = true
      b.binary = true
      info("Binary file — shown as a read-only hex dump")
      content = hexDump(content)
    b.setContent(content)
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
