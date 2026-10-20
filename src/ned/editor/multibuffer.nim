proc mbHeader(lang: Lang, path: string, start: int): string =
  (if lang != nil and lang.lineComment.len > 0: lang.lineComment else: "#") & " § " & relPath(path) & ":" & $(start + 1)

proc mbHeaderOf(lang: Lang, sc: MbSection): string =
  mbHeader(lang, sc.path, sc.start) & (if sc.note.len > 0: "  — " & sc.note else: "")

proc fileLinesNow(path: string): seq[string] =
  let i = bufIndexByPath(path)
  if i >= 0: return bufs[i].lines
  try: result = readFile(path).split('\n')
  except IOError, OSError: discard

proc openMultibuffer(title: string, hits: seq[(string, int)], context = 1) =
  ## every hit with a line of context around it, file by file, in one buffer you can edit; Ctrl+S saves
  var order: seq[string]
  var byFile: Table[string, seq[int]]
  for (path, l) in hits:
    if path notin byFile:
      order.add path
      byFile[path] = @[]
    byFile[path].add l
  var secs: seq[MbSection]
  for path in order:
    let ls = fileLinesNow(path)
    if ls.len == 0: continue
    var hs = byFile[path]
    hs.sort()
    var a = -1
    var e = -1
    for l in hs:
      if l < 0 or l > ls.high: continue           # a stale hit: the file got shorter since the search
      let la = max(0, l - context)
      let le = min(ls.high, l + context)
      if a >= 0 and la <= e + 1: e = max(e, le)
      else:
        if a >= 0: secs.add MbSection(path: path, start: a, orig: ls[a .. e])
        a = la
        e = le
    if a >= 0: secs.add MbSection(path: path, start: a, orig: ls[a .. e])
  if secs.len == 0:
    info("Nothing to show")
    return
  let lang = detectLang(secs[0].path, "")
  var text: seq[string]
  for sc in secs:
    text.add mbHeaderOf(lang, sc)
    text.add sc.orig
  let b = openScratch("Multibuffer: " & title, text.join("\n"), lang)
  b.readOnly = false
  b.savedSeq = b.topSeq()
  multiBufs[b.id] = secs
  info($secs.len & (if secs.len == 1: " piece of " else: " pieces of ") & $order.len &
       (if order.len == 1: " file" else: " files") & " — edit them here, Ctrl+S writes every change back")

proc saveMultibuffer(b: Buffer): bool =
  var secs = multiBufs[b.id]
  # the pieces, as edited: between the § headers
  var pieces: seq[seq[string]]
  var k = -1
  for l in b.lines:
    if k + 1 < secs.len and l == mbHeaderOf(b.lang, secs[k + 1]):
      inc k
      pieces.add @[]
    elif k >= 0: pieces[k].add l
    elif l.strip.len > 0:
      error("Text before the first § header — the multibuffer cannot be saved")
      return false
  if pieces.len != secs.len:
    error("A § header line was changed or removed — undo that (Ctrl+Z), then save")
    return false
  # nothing written if any file changed elsewhere since the multibuffer was made
  for i, sc in secs:
    let cur = fileLinesNow(sc.path)
    if sc.start + sc.orig.len > cur.len or cur[sc.start ..< sc.start + sc.orig.len] != sc.orig:
      error(relPath(sc.path) & ":" & $(sc.start + 1) & " changed since the multibuffer was made — open it again")
      return false
  var files: seq[string]
  for sc in secs:
    if sc.path notin files: files.add sc.path
  var written = 0
  for path in files:
    var idx: seq[int]
    for i, sc in secs:
      if sc.path == path: idx.add i
    var changed = false
    for i in idx:
      if pieces[i] != secs[i].orig: changed = true
    if not changed: continue
    inc written
    let bi = bufIndexByPath(path)
    let wasDirty = bi >= 0 and bufs[bi].dirty
    if bi >= 0:
      let fb = bufs[bi]
      fb.beginEdit()
      for j in countdown(idx.high, 0):
        let sc = secs[idx[j]]
        let last = sc.start + sc.orig.len - 1
        discard fb.replaceText(Pos(line: sc.start, col: 0), Pos(line: last, col: fb.lines[last].len), pieces[idx[j]].join("\n"))
      fb.endEdit()
      if not wasDirty: discard fb.saveBuffer()
    else:
      var ls = fileLinesNow(path)
      for j in countdown(idx.high, 0):
        let sc = secs[idx[j]]
        ls = ls[0 ..< sc.start] & pieces[idx[j]] & ls[sc.start + sc.orig.len .. ^1]
      try:
        writeFile(path, ls.join("\n"))
        fileWritten(path)
      except IOError, OSError:
        error("Could not write " & relPath(path))
        return false
    # the pieces now start where the edits above them moved them
    var delta = 0
    for i in idx:
      secs[i].start += delta
      delta += pieces[i].len - secs[i].orig.len
      secs[i].orig = pieces[i]
  multiBufs[b.id] = secs
  # the headers show the new line numbers
  var text: seq[string]
  for i, sc in secs:
    text.add mbHeaderOf(b.lang, sc)
    text.add pieces[i]
  if text != b.lines: b.setTextMinimal(text.join("\n"))
  b.savedSeq = b.topSeq()
  info(if written > 0: "Saved changes to " & $written & " file(s)" else: "No changes to save")
  if written > 0: gcAfterSave(b)
  true

proc cmdMultibufferFromSearch() =
  var hits: seq[(string, int)]
  if panelKind == pkSearch:
    for pl in panelLines:
      if pl.path.len > 0 and pl.line >= 0: hits.add (pl.path, pl.line)
  if hits.len == 0:
    for h in searchHits: hits.add (h.path, h.line)
  if hits.len == 0:
    info("Search the project first (Alt+S), or find references (Alt+Q)")
    return
  openMultibuffer((if panelTitle.len > 0 and panelKind == pkSearch: panelTitle else: "search results"), hits)

proc showReferences(title: string, hits: seq[(string, int, int)]) =
  panelKind = pkSearch
  panelLines.setLen(0)
  var last = ""
  var files = 0
  # each file is read once, not once per hit (60,000 uses of `int` across the standard library)
  var read = initTable[string, seq[string]]()
  var readBytes = 0
  var rowOf = initTable[(string, int), int]()     # one row per line: a second use on it is marked there too
  for (path, l, c) in hits:
    var rawText = ""
    let bi = bufIndexByPath(path)
    if bi >= 0 and l < bufs[bi].lines.len: rawText = bufs[bi].lines[l]
    else:
      if path notin read:
        if readBytes > 64_000_000: read.clear()
        var ls: seq[string]
        try:
          if getFileSize(path) <= 32_000_000:
            let all = readFile(path)
            readBytes += all.len
            ls = all.splitLines()
        except CatchableError: discard
        read[path] = ls
      read.withValue(path, ls):        # no copy of the file's lines per hit
        if l >= 0 and l < ls[].len: rawText = ls[][l]
    # the use: the word (or operator) written at the column
    let lead = rawText.len - rawText.strip(trailing = false).len
    var e = c
    if c >= 0 and c < rawText.len and isWordByte(rawText[c]):
      while e < rawText.len and isWordByte(rawText[e]): inc e
    elif c >= 0 and c < rawText.len and rawText[c] == '`':
      let q = rawText.find('`', c + 1)
      e = (if q > c: q + 1 else: c + 1)
    else:
      while e < rawText.len and rawText[e] in {'+', '-', '*', '/', '<', '>', '=', '!', '&', '$', '%', '@', '~',
                                                  '^', '|', '.', ':', '?'}: inc e
    let text = rawText.strip
    let pre = align($(l + 1), 5) & "  "
    let mark = (pre.len + c - lead, e - c)
    let okMark = c >= lead and e > c and c - lead + (e - c) <= text.len
    let key = (path, l)
    if key in rowOf:
      let r = rowOf[key]
      if okMark and mark notin panelLines[r].marks: panelLines[r].marks.add mark
      continue
    if path != last:
      panelLines.add PanelLine(text: relPath(path), sev: 5, line: -1)
      last = path
      inc files
    rowOf[key] = panelLines.len
    panelLines.add PanelLine(text: pre & text, path: path, line: l, col: c,
                             marks: (if okMark: @[mark] else: @[]))
  panelTitle = title & " · " & $hits.len
  panelOpen = true
  panelFollow = false
  panelScroll = 0
  panelSel = if panelLines.len > 1: 1 else: 0
  focus = if hits.len > 0: fPanel else: fEditor
  if hits.len == 0: info("No references found")

proc applyRenameHits(hits: seq[(string, int, int)], oldName, newName: string) =
  ## rename at exact positions (from nimsuggest `use`), grouped per file, bottom-up
  var byFile = initTable[string, seq[(int, int)]]()
  for (p, l, c) in hits: byFile.mgetOrPut(p, @[]).add (l, c)
  var n = 0
  for path, locs0 in byFile:
    let b = loadBuffer(path)
    if b == nil or b.readOnly: continue
    var locs = locs0
    locs.sort(proc(x, y: (int, int)): int = cmp(y[0] * 1_000_000 + y[1], x[0] * 1_000_000 + x[1]))
    b.beginEdit()
    var last = (-1, -1)
    for (l, c) in locs:
      if (l, c) == last or l >= b.lines.len: continue
      last = (l, c)
      let s = b.lines[l]
      var col = c
      var e = col + oldName.len
      if not s.startsAt(oldName, col):
        # Nim names are style-insensitive: foo_bar and fooBar are the same identifier
        var k = col
        while k < s.len and isWordByte(s[k]): inc k
        if k > col and s[col ..< k].replace("_", "").toLowerAscii == oldName.replace("_", "").toLowerAscii and
           s[col] == oldName[0]:
          e = k
        else:
          let j = s.find(oldName)
          if j < 0: continue
          col = j
          e = j + oldName.len
      discard b.replaceText(Pos(line: l, col: col), Pos(line: l, col: e), newName)
      inc n
    b.endEdit()
    b.normalize()
  info("Renamed " & $n & " occurrence(s) in " & $byFile.len & " file(s) — Ctrl+S saves")
