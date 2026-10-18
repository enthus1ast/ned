proc saveBuffer(b: Buffer, path = "", force = false): bool =
  if b.id in multiBufs and path.len == 0: return saveMultibuffer(b)
  if b.id in commitBufs and path.len == 0: return doCommitFromBuffer(b)
  if b.id in rebaseBufs and path.len == 0: return doRebaseFromBuffer(b)
  if b.id in sigPlans and path.len == 0: return doSignatureFromBuffer(b)
  if b.binary:
    warn("Binary files are shown as a hex dump and are never saved by ned")
    return false
  if path.len == 0 and b.path.len > 0 and not force:
    # never silently overwrite what another program wrote since we loaded the file
    if b.diskChanged:
      askConfirm(b.name & " changed on disk since you opened it. (o)verwrite with your version, (r)eload theirs, (c)ancel",
        proc(c: char) =
          case c
          of 'o', 'y': discard b.saveBuffer(force = true)
          of 'r': b.reloadBuffer()
          else: discard)
      return false
    # a read-only file is usually read-only on purpose (generated, someone else's): ask before replacing it
    var rst: Stat
    if stat(b.path.cstring, rst) == 0 and ((rst.st_mode.int and 0o222) == 0 or access(b.path.cstring, W_OK) != 0):
      askConfirm(b.name & " is read-only on disk. (o)verwrite it anyway (c)ancel — or File › Save as…",
        proc(c: char) =
          if c in {'o', 'y'}: discard b.saveBuffer(force = true))
      return false
    let other = otherSessionEditing(b.path)
    if other > 0:
      askConfirm(b.name & " has unsaved edits in another ned (pid " & $other & "). Save anyway? (y)es (c)ancel",
        proc(c: char) =
          if c == 'y': discard b.saveBuffer(force = true))
      return false
  if path.len > 0:
    removeSwap(b)                  # the recovery file belongs to the old name
    b.path = absolutePath(path).normalizedPath
    let old = b.lang
    b.lang = detectLang(b.path, b.lines[0])
    if b.lang != old:
      b.hlValid = 0
      b.lspOpen = false
    if fileCacheValid and relPath(b.path) notin fileCache: fileCache.add relPath(b.path)
  if b.path.len == 0:
    openPrompt(pSaveAs, "Save as", "")
    return false
  if cfgFormatOnSave and not b.readOnly and b.lines.len < 50_000 and
     (cfgFormatOnSaveLangs.len == 0 or b.lang.id.toLowerAscii in cfgFormatOnSaveLangs or
      b.lang.name.toLowerAscii in cfgFormatOnSaveLangs):
    formatOnSave(b)
  if not b.readOnly:
    if b.ecTrim == 1: b.trimTrailing(all = true)                 # .editorconfig: the project wants none anywhere
    elif b.ecTrim == -1 and cfgTrimOnSave: b.trimTrailing()
    if b.ecFinalNl == 1: b.noEol = false
  let eol = if b.crlf: "\r\n" else: "\n"
  var content = b.lines.join(eol)
  if not b.noEol and (b.lines.len > 1 or b.lines[0].len > 0 or b.blankNl): content.add eol
  try:
    createDir(parentDir(b.path))
    snapshotHistory(b.path)
    writeFileSafe(b.path, content)
  except CatchableError as e:
    error("Save failed: " & e.msg)
    toast("Save failed: " & e.msg & " — your edits are still here (and in the recovery file)", 1)
    writeSwap(b)
    return false
  b.savedSeq = b.topSeq()
  removeSwap(b)
  (b.mtime, b.fsize) = fileStamp(b.path)
  b.diskChanged = false
  writeUndo(b)
  info("Saved " & relPath(b.path) & "  (" & $b.lines.len & " lines)")
  addRecent(b.path)
  if b.path == configFile() or b.path == projectSettingsFile():
    reloadSettings()
    info("Settings applied")
  if b.path.startsWith(themesDir() & "/"): reloadThemes()     # your theme file: see it at once
  if extractFilename(b.path) == ".editorconfig":
    refreshEditorConfig()
    info("EditorConfig applied to the open files")
  lspAttach(b)
  lspDidSave(b)
  runCheck(b)
  recheckBuildErrors(b)
  ffiCheck(b)
  copiesCheck(b)
  testsOnSave(b)
  refreshGit(b)
  # (a remote folder's file goes to the server too: writeFileSafe → fileWritten)
  true

proc saveAll(): bool =
  result = true
  for b in bufs:
    if b.dirty and b.path.len > 0:
      if not b.saveBuffer(): result = false

proc reloadBuffer(b: Buffer) =
  try:
    var content = readFile(b.path)
    if b.binary: content = hexDump(content)
    var tmp = newBuffer()
    tmp.lang = b.lang
    tmp.setContent(content)
    let newText = tmp.lines.join("\n")
    let heads = b.cursors
    b.beginEdit()
    discard b.replaceText(Pos(), Pos(line: b.lines.high, col: b.lines[^1].len), newText)
    b.endEdit()
    b.cursors = heads
    b.normalize()
    b.crlf = tmp.crlf
    b.noEol = tmp.noEol
    b.savedSeq = b.topSeq()
    (b.mtime, b.fsize) = fileStamp(b.path)
    b.diskChanged = false
    refreshGit(b)
  except CatchableError as e:
    error("Reload failed: " & e.msg)

proc closeBufferAt(i: int) =
  if i < 0 or i >= bufs.len: return
  let b = bufs[i]
  rememberPos(b)
  writeUndo(b)
  if b.path.len > 0 and b.title.len == 0:
    closedTabs.add (b.path, b.primary.head)
    if closedTabs.len > 30: closedTabs.delete(0)
  lspDidClose(b)
  emitClose(b)
  embClose(b)
  removeSwap(b)
  let wasCur = i == curBuf
  if splitOn and panes[1 - activePane].bufId == b.id:
    splitOn = false          # the other pane showed it: back to one editor
    activePane = 0
  bufs.delete(i)
  if bufs.len == 0:
    bufs.add newBuffer()
    bufs[0].welcome = true
  if wasCur: curBuf = min(i, bufs.high)
  elif i < curBuf: dec curBuf
  curBuf = clamp(curBuf, 0, bufs.high)
  closeComp()
  needRender = true

proc closeBuffer(i: int) =
  if i < 0 or i >= bufs.len: return          # a stale index (two clicks before the tab bar was redrawn)
  let b = bufs[i]
  if b.dirty:
    curBuf = i
    askConfirm("Save changes to " & b.name & "? (y)es (n)o (c)ancel", proc(c: char) =
      case c
      of 'y':
        if b.saveBuffer():
          let k = bufs.find(b)
          if k >= 0: closeBufferAt(k)
      of 'n':
        let k = bufs.find(b)
        if k >= 0: closeBufferAt(k)
      else: discard)
  else:
    closeBufferAt(i)

proc checkDiskChanges() =
  for b in bufs:
    if b.path.len == 0 or b.mtime == 0: continue
    let (m, s) = fileStamp(b.path)
    if s < 0: continue
    if m != b.mtime or s != b.fsize:
      if not b.dirty and cfgAutoReload:
        b.reloadBuffer()
        info(b.name & " reloaded (changed on disk)")
      elif not b.diskChanged:
        b.diskChanged = true
        warn(b.name & " changed on disk — palette: \"Reload from disk\"")
      b.mtime = m
      b.fsize = s
