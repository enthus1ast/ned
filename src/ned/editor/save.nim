# ── the hex editor's bytes saved (editor/hexedit.nim) ──

proc hexSave(b: Buffer, path = ""): bool =
  ## the bytes written (safely: a new file renamed over the old one, its permissions kept)
  let p = if path.len > 0: path else: b.path
  try:
    var mode = 0o644
    try:
      mode = 0
      for f in getFilePermissions(p):
        mode = mode or (case f
          of fpUserExec: 0o100
          of fpUserWrite: 0o200
          of fpUserRead: 0o400
          of fpGroupExec: 0o010
          of fpGroupWrite: 0o020
          of fpGroupRead: 0o040
          of fpOthersExec: 0o001
          of fpOthersWrite: 0o002
          of fpOthersRead: 0o004)
    except CatchableError: mode = 0o644
    writeFileSafe(p, b.hex.data, mode)
  except CatchableError as e:
    error("Cannot save " & extractFilename(p) & ": " & e.msg)
    return false
  if path.len == 0 or path == b.path:
    b.hex.savedAt = b.hex.undo.len
    (b.mtime, b.fsize) = fileStamp(b.path)
  info("Saved " & extractFilename(p) & " (" & $b.hex.data.len & " bytes)")
  needRender = true
  true

proc saveBuffer(b: Buffer, path = "", force = false): bool =
  ## Ctrl+S for one buffer; true when it was written. Special tabs go their own way (multibuffer, commit message, rebase
  ## plan, signature plan, plugin tab, hex editor). Without force, a file that changed on disk, is read-only or is being
  ## edited by another ned is only saved after a confirmation. With a new path (Save as) the buffer takes that name and
  ## language; with no name at all it asks for one. Then: plugins' before-save events, format on save, trailing-space
  ## and final-newline rules, the line ending and encoding it was read in, and a crash-safe write after a local-history
  ## copy. After a successful write: the undo history is stored, the recovery file removed, and settings, themes and
  ## .editorconfig reload if that was the file, and the language server, checks, tests, git marks and plugins are told
  if b.id in multiBufs and path.len == 0: return saveMultibuffer(b)
  if b.id in commitBufs and path.len == 0: return doCommitFromBuffer(b)
  if b.id in rebaseBufs and path.len == 0: return doRebaseFromBuffer(b)
  if b.id in sigPlans and path.len == 0: return doSignatureFromBuffer(b)
  if path.len == 0 and b.path.len == 0 and plugWrites(b): return true   # (a plugin's tab: the folder view)
  if b.hex != nil:
    return b.hexSave(path)                           # (the hex editor: the bytes as they are)
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
  plugBeforeSave(b)                                # (plugins' "before saving" events: what they change is saved)
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
  if b.enc.len > 0:
    # (written in the encoding it was read in — UTF-16, Windows-1252 …)
    let (ok, bytes, at) = encodeFile(content, b.enc)
    if not ok:
      if at >= 0:
        let ln = content[0 ..< at].count('\n')
        let col = at - (content.rfind('\n', 0, max(0, at - 1)) + 1)
        var e = at + 1
        while e < content.len and (content[e].ord and 0xC0) == 0x80: inc e
        error("Not saved: " & content[at ..< e] & " (line " & $(ln + 1) & ", column " & $(col + 1) & ") cannot be written in " &
              encLabel(b.enc) & " — the status bar's " & encLabel(b.enc) & " › Save with encoding… (UTF-8)")
        b.setSingle(b.clampPos(Pos(line: ln, col: col)))
      else: error("Not saved: iconv could not write " & encLabel(b.enc))
      return false
    content = bytes
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
  info("Saved " & relPath(b.path) & "  (" & $b.lines.len & (if b.lines.len == 1: " line)" else: " lines)"))
  addRecent(b.path)
  if b.path == configFile() or b.path == projectSettingsFile():
    reloadSettings()
    info("Settings applied")
    keysCheckAtStart()
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
  plugSaved(b)
  plugFileSaved(b.path)                            # (a plugin's own file: the plugins reload)
  aiCommentsSaved(b)                               # (comments ending in AI! or AI?: ai.commentCommands)
  # (a remote folder's file goes to the server too: writeFileSafe → fileWritten)
  true

proc saveAll(): bool =
  ## saves every changed buffer that has a file; false when any of them failed or needed a confirmation
  result = true
  for b in bufs:
    if b.dirty and b.path.len > 0:
      if not b.saveBuffer(): result = false

proc reloadBuffer(b: Buffer) =
  ## reads the file again from disk into the buffer (in the encoding it was opened with) as one undoable edit, keeping
  ## the cursors, line ending and the 'saved' state; a hex buffer opens the bytes anew
  if b.hex != nil:
    try:
      b.hexOpen(readFile(b.path))
      (b.mtime, b.fsize) = fileStamp(b.path)
      b.diskChanged = false
      needRender = true
    except CatchableError as e: error("Reload failed: " & e.msg)
    return
  try:
    var content = readFile(b.path)
    if b.enc.len > 0:
      let (ok, t) = decodeFile(content, b.enc)
      if ok or b.enc in [EncUtf16Le, EncUtf16Be, EncUtf8Bom]: content = t
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
  ## closes the tab at index i without asking: tells plugins and the language server, keeps the cursor position, the
  ## undo history and (for a file) a place in the reopen-closed-tab list, removes the recovery file, ends a terminal
  ## tab's shell and closes the other panes showing it. The last tab left is replaced by an empty welcome buffer; the
  ## current tab moves to a neighbour
  if i < 0 or i >= bufs.len: return
  let b = bufs[i]
  plugClosed(b)
  rememberPos(b)
  writeUndo(b)
  if b.path.len > 0 and b.title.len == 0:
    closedTabs.add (b.path, b.primary.head)
    if closedTabs.len > 30: closedTabs.delete(0)
  lspDidClose(b)
  lfClose(b)
  emitClose(b)
  embClose(b)
  removeSwap(b)
  let wasCur = i == curBuf
  if b.paneView == 1: paneTermEnd(b.paneArg)      # (a terminal's tab: its shell ends)
  dropBufFromPanes(b.id)     # (the other panes that showed it close)
  bufs.delete(i)
  if bufs.len == 0:
    bufs.add newBuffer()
    bufs[0].welcome = true
  if wasCur: curBuf = min(i, bufs.high)
  elif i < curBuf: dec curBuf
  curBuf = clamp(curBuf, 0, bufs.high)
  if wasCur and paneAfterClose >= 0:              # (panes: the pane's own tab before it)
    let k = bufs.find(bufById(paneAfterClose))
    if k >= 0: curBuf = k
    paneAfterClose = -1
  closeComp()
  bufForget(b.id)                                 # (what ned kept about it: editor/bufforget.nim)
  needRender = true

proc closeBuffer(i: int) =
  ## closing a tab as the person asks: a buffer with unsaved changes first asks to save, discard or cancel, then closes
  ## it with closeBufferAt
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

proc saveOnFocusLost() =
  ## editor.saveOnFocusLost: the terminal lost the focus — the changed files are saved (never one that changed on
  ## disk meanwhile or that another ned is editing: that is yours to decide)
  var n = 0
  for b in bufs:
    if b.dirty and b.path.len > 0 and b.title.len == 0 and not b.readOnly and not b.diskChanged and
       otherSessionEditing(b.path) == 0:
      if b.saveBuffer(): inc n
  if n > 0: info("Saved " & $n & (if n == 1: " file" else: " files") & " (you switched away: editor.saveOnFocusLost)")

proc checkDiskChanges() =
  ## run now and then: for every open file whose time or size on disk changed, reloads it when it has no unsaved changes
  ## and auto-reload is on, otherwise marks it as changed on disk (saving then asks first) and warns once
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
