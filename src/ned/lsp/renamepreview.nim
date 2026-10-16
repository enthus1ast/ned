# ── rename preview: every change listed first; Space unticks one, Enter applies the rest ──

type RenamePv = object
  bufId: int
  oldName, newName: string
  hits: seq[(string, int, int)]           # from the Nim engine / nimsuggest: file, line, col
  lsp: LspServer                          # from a language server: its edits, one by one
  edits: seq[(string, JsonNode)]          # uri, TextEdit
  on: seq[bool]
  rowItem: seq[int]                       # preview line → change (-1: a heading)

var renamePv: RenamePv

proc applyRenameHits(hits: seq[(string, int, int)], oldName, newName: string)

proc renderRenamePv() =
  let b = bufById(renamePv.bufId)
  if b == nil: return
  var lines: seq[string]
  var rowItem: seq[int]
  let n = max(renamePv.hits.len, renamePv.edits.len)
  var onN = 0
  for x in renamePv.on:
    if x: inc onN
  var files: seq[string]
  var byFile: Table[string, seq[int]]
  for i in 0 ..< n:
    let path = if renamePv.lsp == nil: renamePv.hits[i][0] else: pathFromUri(renamePv.edits[i][0])
    if path notin byFile:
      files.add path
      byFile[path] = @[]
    byFile[path].add i
  lines.add "# Rename " & renamePv.oldName & " → " & renamePv.newName & " · " & $onN & " of " & $n & " changes in " &
            $files.len & " file(s)"
  rowItem.add -1
  lines.add "# Space ticks/unticks · a all · Enter applies the ticked ones · Esc cancels"
  rowItem.add -1
  for path in files:
    lines.add ""
    rowItem.add -1
    lines.add "@@ " & relPath(path)
    rowItem.add -1
    let src = (let i = bufIndexByPath(path); if i >= 0: bufs[i].lines else: (try: readFile(path).split('\n') except IOError, OSError: @[]))
    for i in byFile[path]:
      var l, c, e: int
      var nw = renamePv.newName
      if renamePv.lsp == nil:
        (l, c) = (renamePv.hits[i][1], renamePv.hits[i][2])
        e = c + renamePv.oldName.len
      else:
        let ed = renamePv.edits[i][1]
        l = ed{"range", "start", "line"}.getInt
        c = ed{"range", "start", "character"}.getInt
        e = if ed{"range", "end", "line"}.getInt == l: ed{"range", "end", "character"}.getInt else: c
        nw = ed{"newText"}.getStr
      let t = if l < src.len: src[l] else: ""
      let shown = if c <= t.len and e <= t.len and c <= e: t[0 ..< c] & nw & t[e .. ^1] else: t
      lines.add "  " & (if renamePv.on[i]: "[x]" else: "[ ]") & " line " & $(l + 1)
      rowItem.add i
      lines.add "-     " & t.strip
      rowItem.add i
      if renamePv.on[i]:
        lines.add "+     " & shown.strip
        rowItem.add i
  renamePv.rowItem = rowItem
  let keep = b.primary.head
  b.readOnly = false
  b.setContent(lines.join("\n"))
  b.readOnly = true
  b.setSingle(b.clampPos(keep))

proc openRenamePv() =
  let n = max(renamePv.hits.len, renamePv.edits.len)
  renamePv.on = newSeq[bool](n)
  for x in renamePv.on.mitems: x = true
  let pv = openScratch("Rename preview", "", langByName("Diff"))
  renamePv.bufId = pv.id
  renderRenamePv()
  # the cursor on the first change
  for k, it in renamePv.rowItem:
    if it >= 0:
      pv.setSingle(Pos(line: k, col: 0))
      break

proc previewRenameHits(hits: seq[(string, int, int)], oldName, newName: string) =
  if not cfgRenamePreview:
    applyRenameHits(hits, oldName, newName)
    return
  renamePv = RenamePv(oldName: oldName, newName: newName, hits: hits)
  openRenamePv()

proc previewWorkspaceEdit(s: LspServer, we: JsonNode, oldName, newName: string) =
  if not cfgRenamePreview or we == nil or we.kind != JObject:
    applyWorkspaceEdit(s, we)
    return
  var edits: seq[(string, JsonNode)]
  if we.hasKey("changes") and we["changes"].kind == JObject:
    for uri, es in we["changes"]:
      for e in jitems(es): edits.add (uri, e)
  if we.hasKey("documentChanges"):
    for dc in jitems(we["documentChanges"]):
      if dc.kind == JObject and dc.hasKey("edits"):
        for e in jitems(dc["edits"]): edits.add (dc{"textDocument", "uri"}.getStr, e)
  if edits.len == 0:
    applyWorkspaceEdit(s, we)
    return
  renamePv = RenamePv(oldName: oldName, newName: newName, lsp: s, edits: edits)
  openRenamePv()

proc renamePvKey(k: Key): bool =
  ## keys in the rename preview tab
  let b = buf()
  let row = b.primary.head.line
  if k.kind == kChar and k.mods == {} and k.ch == ord(' '):
    if row < renamePv.rowItem.len and renamePv.rowItem[row] >= 0:
      let i = renamePv.rowItem[row]
      renamePv.on[i] = not renamePv.on[i]
      renderRenamePv()
      # on to the next change
      var r = 0
      while r < renamePv.rowItem.len and renamePv.rowItem[r] != i: inc r
      while r < renamePv.rowItem.len and renamePv.rowItem[r] in [i, -1]: inc r
      if r < renamePv.rowItem.len: b.setSingle(Pos(line: r, col: 0))
    return true
  if k.kind == kChar and k.mods == {} and k.ch == ord('a'):
    var all = true
    for x in renamePv.on:
      if not x: all = false
    for x in renamePv.on.mitems: x = not all
    renderRenamePv()
    return true
  if k.kind == kEnter and k.mods == {}:
    let ci = bufs.find(b)
    if renamePv.lsp == nil:
      var hs: seq[(string, int, int)]
      for i, h in renamePv.hits:
        if renamePv.on[i]: hs.add h
      if ci >= 0: closeBufferAt(ci)
      if hs.len > 0: applyRenameHits(hs, renamePv.oldName, renamePv.newName)
      else: info("Nothing ticked — nothing renamed")
    else:
      var ch = newJObject()
      var n = 0
      for i, (uri, e) in renamePv.edits:
        if not renamePv.on[i]: continue
        if not ch.hasKey(uri): ch[uri] = newJArray()
        ch[uri].add e
        inc n
      if ci >= 0: closeBufferAt(ci)
      if n > 0: applyWorkspaceEdit(renamePv.lsp, %*{"changes": ch})
      else: info("Nothing ticked — nothing renamed")
    renamePv.bufId = -1
    return true
  if k.kind == kEsc:
    let ci = bufs.find(b)
    if ci >= 0: closeBufferAt(ci)
    renamePv.bufId = -1
    info("Rename cancelled")
    return true
  k.kind in {kChar, kBackspace, kDelete, kTab, kPaste} and k.mods - {mShift} == {}
