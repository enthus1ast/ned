# ════════════════════════════════════════════════════════════════════════════
#  Loading & saving
# ════════════════════════════════════════════════════════════════════════════

proc detectIndent(b: Buffer) =
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

# ── .editorconfig (editorconfig.org): a project's indentation, line ends and whitespace, per file ──

type
  EcSection = object
    glob: string
    props: seq[(string, string)]
  EcFile = object
    root: bool
    sections: seq[EcSection]
var ecCache: Table[string, (int64, EcFile)]      # .editorconfig path → (when it changed, what it says)

proc parseEditorConfig(text: string): EcFile =
  var cur = -1
  for raw in text.splitLines:
    let l = raw.strip
    if l.len == 0 or l[0] in {'#', ';'}: continue
    if l[0] == '[':
      let e = l.rfind(']')
      if e > 0:
        result.sections.add EcSection(glob: l[1 ..< e])
        cur = result.sections.high
      continue
    let eq = l.find('=')
    if eq <= 0: continue
    let k = l[0 ..< eq].strip.toLowerAscii
    let v = l[eq + 1 .. ^1].strip
    if k.len == 0: continue
    if cur < 0:
      if k == "root": result.root = v.toLowerAscii == "true"
    else: result.sections[cur].props.add (k, v)

proc ecMatch(p: string, pi0: int, s: string, si0: int): bool =
  ## EditorConfig globs: * (not /), ** (anything), ?, [abc] [a-z] [!abc], {a,b,c}, {1..10}, \\ escapes
  var pi = pi0
  var si = si0
  while pi < p.len:
    let c = p[pi]
    case c
    of '*':
      if pi + 1 < p.len and p[pi + 1] == '*':
        let np = pi + 2
        if np < p.len and p[np] == '/' and ecMatch(p, np + 1, s, si): return true    # **/ : no folder too
        for k in si .. s.len:
          if ecMatch(p, np, s, k): return true
        return false
      for k in si .. s.len:
        if ecMatch(p, pi + 1, s, k): return true
        if k < s.len and s[k] == '/': break
      return false
    of '?':
      if si >= s.len or s[si] == '/': return false
      inc pi
      inc si
    of '[':
      var e = pi + 1
      if e < p.len and p[e] == '!': inc e
      if e < p.len and p[e] == ']': inc e
      while e < p.len and p[e] != ']': inc e
      if e >= p.len:                                   # no closing ]: an ordinary [
        if si >= s.len or s[si] != '[': return false
        inc pi
        inc si
        continue
      if si >= s.len or s[si] == '/': return false
      var k = pi + 1
      let neg = p[k] == '!'
      if neg: inc k
      var hit = false
      while k < e:
        if k + 2 < e and p[k + 1] == '-':
          if s[si] >= p[k] and s[si] <= p[k + 2]: hit = true
          k += 3
        else:
          if s[si] == p[k]: hit = true
          inc k
      if hit == neg: return false
      pi = e + 1
      inc si
    of '{':
      var depth = 0
      var e = pi
      while e < p.len:
        if p[e] == '\\': inc e
        elif p[e] == '{': inc depth
        elif p[e] == '}':
          dec depth
          if depth == 0: break
        inc e
      if e >= p.len:                                   # no closing }: an ordinary {
        if si >= s.len or s[si] != '{': return false
        inc pi
        inc si
        continue
      let inner = p[pi + 1 ..< e]
      let rest = p[e + 1 .. ^1]
      let dd = inner.find("..")
      if dd > 0:                                       # {1..10}: a whole number in that range
        try:
          let lo = parseInt(inner[0 ..< dd])
          let hi = parseInt(inner[dd + 2 .. ^1])
          var k = si
          if k < s.len and s[k] == '-': inc k
          let ds = k
          while k < s.len and s[k].isDigit: inc k
          if k == ds: return false
          let v = parseInt(s[si ..< k])
          if v < min(lo, hi) or v > max(lo, hi): return false
          return ecMatch(rest, 0, s, k)
        except ValueError: discard
      var alts: seq[string]
      var d2 = 0
      var a0 = 0
      var q = 0
      while q < inner.len:
        let ch = inner[q]
        if ch == '\\': inc q
        elif ch == '{': inc d2
        elif ch == '}': dec d2
        elif ch == ',' and d2 == 0:
          alts.add inner[a0 ..< q]
          a0 = q + 1
        inc q
      alts.add inner[min(a0, inner.len) .. ^1]
      if alts.len == 1:                                # {word}: ordinary braces
        let lit = "{" & inner & "}"
        if si + lit.len > s.len or s[si ..< si + lit.len] != lit: return false
        si += lit.len
        pi = e + 1
        continue
      for a in alts:
        if ecMatch(a & rest, 0, s, si): return true
      return false
    of '\\':
      if pi + 1 >= p.len or si >= s.len or s[si] != p[pi + 1]: return false
      pi += 2
      inc si
    else:
      if si >= s.len or s[si] != c: return false
      inc pi
      inc si
  si == s.len

proc ecGlobMatches(glob, rel: string): bool =
  ## `rel`: the file's path from the .editorconfig's folder; a glob without / matches the name in any folder
  if '/' notin glob: return ecMatch(glob, 0, rel.rsplit('/', 1)[^1], 0)
  ecMatch(if glob.startsWith("/"): glob[1 .. ^1] else: glob, 0, rel, 0)

proc editorConfigFor(path: string): seq[(string, string, string)] =
  ## the .editorconfig properties for a file: (name, value, the file that set it); nearer files win
  var files: seq[(string, EcFile)]
  var dir = parentDir(path)
  for _ in 0 .. 64:
    let f = dir / ".editorconfig"
    if fileExists(f):
      let (mt, _) = fileStamp(f)
      var ef: EcFile
      if f in ecCache and ecCache[f][0] == mt: ef = ecCache[f][1]
      else:
        try: ef = parseEditorConfig(readFile(f))
        except CatchableError: discard
        ecCache[f] = (mt, ef)
      files.add (f, ef)
      if ef.root: break
    let up = parentDir(dir)
    if up == dir or up.len == 0: break
    dir = up
  var props: OrderedTable[string, (string, string)]
  for fi in countdown(files.high, 0):
    let (f, ef) = files[fi]
    let rel = relativePath(path, parentDir(f)).replace('\\', '/')
    for sec in ef.sections:
      if ecGlobMatches(sec.glob, rel):
        for (k, v) in sec.props:
          if v.toLowerAscii == "unset": props.del k
          else: props[k] = (v, f)
  for k, (v, f) in props: result.add (k, v, f)

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
  ecCache.clear()
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
