# reading nimsuggest's answers: its output is split into replies, and each reply is turned into what the request asked
# for — completion, go to definition, hover, signature help, references, rename, live checks, outline, macro expansion
# or inlay hints.
proc nsHandle(s: NimSug, r: NsReq, lines: seq[string]) =
  ## acts on nimsuggest's answer (its tab-separated lines) to request r: fills the completion list, jumps to the
  ## definition, shows a hover or signature, lists references or the places a rename touches, stores the checks'
  ## problems and unused hints, the outline or the inlay hints, or opens a macro expansion in a scratch tab. An answer
  ## for a cursor that has since moved is dropped
  if r.kind == nsInlay:
    # Type<TAB>line<TAB>col<TAB>label<TAB>paddingLeft<TAB>paddingRight<TAB>…
    let b = bufById(r.bufId)
    if b == nil or r.extra.len == 0: return
    let parts = r.extra.split('/')
    if parts.len != 3 or parts[2] != $b.changeId: return
    b.inlays.clear()
    for l in lines:
      let f = l.split('\t')
      if f.len < 6 or f[0] notin ["Type", "Parameter"]: continue
      try:
        let ln = parseInt(f[1]) - 1
        let col = parseInt(f[2])
        if ln < 0 or ln >= b.lines.len: continue
        var label = f[3].strip.replace("system.", "")
        if label.len == 0: continue
        if f[4] == "true": label = " " & label
        if f[5] == "true": label = label & " "
        b.inlays.mgetOrPut(ln, @[]).add (min(col, b.lines[ln].len), label)
      except ValueError: discard
    for _, v in b.inlays.mpairs:
      v.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
    b.inlayAt = b.changeId
    try:
      b.inlayLo = parseInt(parts[0])
      b.inlayHi = parseInt(parts[1])
    except ValueError: discard
    needRender = true
    return
  var rows: seq[seq[string]]
  for l in lines:
    let f = l.split('\t')
    if f.len >= 8 and f[0] in ["sug", "def", "con", "use", "chk", "outline", "expand"]: rows.add f
  let b = bufById(r.bufId)
  case r.kind
  of nsSug:
    if b == nil or b != buf(): return
    let p = b.primary.head
    if p.line != r.pos.line or p.col < r.pos.col: return
    for i in r.pos.col ..< p.col:
      if not isWordByte(b.lines[p.line][i]): return
    var items: seq[CompItem]
    var seen: HashSet[string]
    for i, f in rows:
      let q = f[2]
      let dot = q.rfind('.')
      let label = if dot >= 0 and dot + 1 < q.len: q[dot + 1 .. ^1] else: q
      let key = label & "\t" & f[3]
      if label.len == 0 or key in seen: continue
      seen.incl key
      var detail = f[3]
      let pr = detail.find("{.")
      if pr > 0: detail = detail[0 ..< pr]
      var doc = "```nim\n" & nsSignature(f[1], label, f[3]) & "\n```"
      let d = nxRstToMd(unquoteNim(f[7]).strip)
      if d.len > 0: doc.add "\n" & d
      if f[4].len > 0: doc.add "\n\n" & extractFilename(f[4]) & ":" & f[5]
      items.add CompItem(label: label, insert: label, detail: detail, kind: skIcon(f[1]), filter: label,
                         sortText: align($i, 5, '0'), doc: doc, docMade: true)
    if items.len == 0: return
    compItems = items
    compFromLsp = true
    compLine = p.line
    compStartCol = b.wordStart(p)
    refilterComp()
  of nsDef:
    if rows.len == 0:
      info("No definition found")
      return
    let f = rows[0]
    pushJump()
    let nb = openFile(f[4])
    if nb != nil:
      try: nb.centerOn(nb.clampPos(Pos(line: parseInt(f[5]) - 1, col: parseInt(f[6]))))
      except ValueError: discard
  of nsHover, nsAutoHover:
    let auto = r.kind == nsAutoHover
    if b == nil or b != buf() or (auto and b.primary.head != r.pos): return
    var parts: seq[string]
    if hoverPrefix.len > 0: parts.add hoverPrefix.strip
    if rows.len > 0:
      let f = rows[0]
      let sig = "```nim\n" & nsSignature(f[1], f[2], f[3]) & "\n```"
      let doc = nxRstToMd(unquoteNim(f[7]).strip)
      var t = sig
      if doc.len > 0: t.add "\n---\n" & doc
      if f[4].len > 0 and f[4] != b.path and not f[4].startsWith(rootDir & "/"):
        t.add "\n---\n" & extractFilename(f[4]) & ":" & f[5]
      parts.add t
    else:
      let d = nimDocFor(b.wordAt(r.pos))
      if d.len > 0: parts.add d
    if parts.len > 0: showHoverAuto(parts.join("\n---\n"), auto)
    elif not auto: info("No information")
  of nsCon:
    sigOpen = false
    if b == nil or b != buf() or b.primary.head.line != r.pos.line or rows.len == 0: return
    let f = rows[0]
    let q = f[2]
    let dot = q.rfind('.')
    let nm = if dot >= 0: q[dot + 1 .. ^1] else: q
    var typ = f[3]
    let pr = typ.find("{.")
    if pr > 0: typ = typ[0 ..< pr]
    if typ.startsWith("proc "): typ = typ[5 .. ^1]
    sigLabel = nm & typ
    sigDoc = nxRstToMd(unquoteNim(f[7]).strip)
    sigMore = ""
    # active parameter: commas after the innermost open paren on this line
    let s = b.lines[b.primary.head.line][0 ..< b.primary.head.col]
    var depth = 0
    var commas = 0
    for i in countdown(s.high, 0):
      if s[i] == ')': inc depth
      elif s[i] == '(':
        if depth == 0: break
        dec depth
      elif s[i] == ',' and depth == 0: inc commas
    sigHl = (0, 0)
    let o = sigLabel.find('(')
    if o >= 0:
      var k = o + 1
      var idx = 0
      var start = k
      var d2 = 0
      while k < sigLabel.len:
        let c = sigLabel[k]
        if c in {'(', '['}: inc d2
        elif c in {')', ']'}:
          if d2 == 0:
            if idx == commas: sigHl = (start, k)
            break
          dec d2
        elif (c == ',' or c == ';') and d2 == 0:
          if idx == commas:
            sigHl = (start, k)
            break
          inc idx
          start = k + 2
        inc k
    sigLine = r.pos.line
    sigOpen = true
  of nsUse:
    var hits: seq[(string, int, int)]
    for f in rows:
      try: hits.add (f[4], parseInt(f[5]) - 1, parseInt(f[6]))
      except ValueError: discard
    showReferences("REFERENCES " & r.extra, hits)
  of nsRename:
    var hits: seq[(string, int, int)]
    for f in rows:
      if f[4].startsWith(parentDir(s.project)) or f[4].startsWith(rootDir & "/"):
        try: hits.add (f[4], parseInt(f[5]) - 1, parseInt(f[6]))
        except ValueError: discard
    let parts = r.extra.split('\t')
    if parts.len == 2 and hits.len > 0: previewRenameHits(hits, parts[0], parts[1])
    else: info("Nothing to rename")
  of nsChk:
    var found = initTable[string, seq[Diag]]()
    var unused = initTable[string, seq[(int, int, string)]]()
    if b != nil:
      found[b.path] = @[]
      unused[b.path] = @[]
    for f in rows:
      if f[3] == "Hint" and f[4] != "???" and ("declared but not used" in f[7] or "imported and not used" in f[7]):
        try: unused.mgetOrPut(f[4], @[]).add (parseInt(f[5]) - 1, max(0, parseInt(f[6])), quotedNameOf(unquoteNim(f[7])))
        except ValueError: discard
        continue
      if f[3] notin ["Error", "Warning"] or f[4] == "???" or not fileExists(f[4]): continue
      if not (f[4].startsWith(parentDir(s.project)) or f[4].startsWith(rootDir & "/")): continue
      try:
        found.mgetOrPut(f[4], @[]).add Diag(line: parseInt(f[5]) - 1, col: max(0, parseInt(f[6])),
          eline: parseInt(f[5]) - 1, ecol: -1, sev: (if f[3] == "Error": 1 else: 2),
          msg: unquoteNim(f[7]), src: "nimsuggest")
      except ValueError: discard
    for p, ds0 in found:
      var ds = ds0
      keepCDiags(p, ds)
      diagsBuild[p] = ds
      engineAgain(p)
    for p, us in unused: unusedHints[p] = us
  of nsOutline:
    if b == nil: return
    var items: seq[SideItem]
    for f in rows:
      let q = f[2]
      let dot = q.rfind('.')
      let nm = if dot >= 0: q[dot + 1 .. ^1] else: q
      if f[4] != b.path and f[4] != b.nsDirtyPath: continue
      try:
        let k = skIcon(f[1])
        items.add SideItem(text: nm, detail: skWord(f[1]), path: b.path, line: parseInt(f[5]) - 1,
                           col: parseInt(f[6]), role: (if k in {3, 99}: 7 elif k == 7: 8 else: 0),
                           icon: (if k in {3, 99}: "ƒ" elif k == 7: "T" elif k == 21: "c" else: "v"))
      except ValueError: discard
    items.sort(proc(x, y: SideItem): int = cmp(x.line, y.line))
    b.outline = items
    b.outlineAt = b.changeId
  of nsExpand:
    var text = ""
    if rows.len > 0: text = unquoteNim(rows[0][7]).strip(chars = {'\n'})
    if text.len == 0:
      info("Nothing to expand — put the cursor on a macro or template call")
      return
    let nm = if r.extra.len > 0 and r.extra != "all" and r.extra != "1": r.extra else: "expansion"
    discard openScratch("expand: " & nm, text & "\n", langByName("Nim"))
    info("Macro expansion shown in a read-only tab — Ctrl+W closes it")
  of nsInlay: discard          # handled above
  needRender = true

proc nsRead(s: NimSug) =
  ## reads what nimsuggest has written without blocking and cuts it into lines; an empty line ends a reply, which goes
  ## to nsHandle for the request in flight, and the next waiting request is sent. End of output marks the process dead
  var tmp: array[65536, char]
  while true:
    let n = posix.read(s.pr.outFd, addr tmp[0], tmp.len)
    if n > 0:
      let old = s.rbuf.len
      s.rbuf.setLen(old + n)
      copyMem(addr s.rbuf[old], addr tmp[0], n)
    elif n == 0:
      s.dead = true
      break
    else: break
  var start = 0
  while true:
    let nl = s.rbuf.find('\n', start)
    if nl < 0: break
    var line = s.rbuf[start ..< nl]
    if line.endsWith('\r'): line.setLen(line.len - 1)
    start = nl + 1
    if line.len == 0:
      if s.inflight.len > 0:
        let r = s.inflight[0]
        s.inflight.delete(0)
        s.warmed = true
        let ls = s.lines
        s.lines.setLen(0)
        try: nsHandle(s, r, ls)
        except Exception as e: warn("nimsuggest: " & e.msg)
        nsPump(s)
      else:
        s.lines.setLen(0)
    elif s.inflight.len > 0 and not line.startsWith("usage:") and not line.startsWith("type '"):
      s.lines.add line
  if start > 0: s.rbuf = s.rbuf[start .. ^1]

proc nsStatus(b: Buffer): string =
  ## the status bar text for the buffer's nimsuggest: indexing until its first answer, then busy or idle; empty when
  ## none is running
  let s = nsGet(b, false)
  if s == nil: return ""
  if not s.warmed and s.inflight.len > 0: "nimsuggest: indexing…"
  elif s.inflight.len > 0: "nimsuggest …"
  else: "nimsuggest"

proc nsShutdown() =
  ## stops every nimsuggest process (when ned quits)
  for s in nimSugs: nsKill(s)
  nimSugs.setLen(0)
