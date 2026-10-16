# ════════════════════════════════════════════════════════════════════════════
#  Keyboard routing
# ════════════════════════════════════════════════════════════════════════════

proc keyName(k: Key): string =
  ## "ctrl+alt+shift+x" style names for user key bindings
  var parts: seq[string]
  if mCtrl in k.mods: parts.add "ctrl"
  if mAlt in k.mods: parts.add "alt"
  if mShift in k.mods: parts.add "shift"
  case k.kind
  of kChar:
    var c = k.ch
    if c < 128 and char(c) in {'A'..'Z'} and mShift notin k.mods:
      parts.add "shift"
      c = ord(toLowerAscii(char(c)))
    var s = ""
    s.addUtf8(c)
    if s == " ": s = "space"
    parts.add s
  of kEnter: parts.add "enter"
  of kTab: parts.add "tab"
  of kBackspace: parts.add "backspace"
  of kDelete: parts.add "delete"
  of kEsc: parts.add "escape"
  of kUp: parts.add "up"
  of kDown: parts.add "down"
  of kLeft: parts.add "left"
  of kRight: parts.add "right"
  of kHome: parts.add "home"
  of kEnd: parts.add "end"
  of kPgUp: parts.add "pageup"
  of kPgDn: parts.add "pagedown"
  of kInsert: parts.add "insert"
  of kFn: parts.add "f" & $k.fn
  else: return ""
  parts.join("+")

proc customKey(k: Key): bool =
  if cfgKeys.len == 0: return false
  let n = keyName(k)
  if n.len == 0 or n notin cfgKeys: return false
  runCmd(cfgKeys[n])
  true

proc toggleTerminal() =
  if panelOpen and panelKind == pkTerminal and focus == fPanel:
    panelOpen = false
    focus = fEditor
  else:
    setPanel(pkTerminal)
    focus = fPanel

proc cycleFocus(d: int) =
  var order = @[fEditor]
  if treeOpen: order.add fTree
  if panelOpen: order.add fPanel
  if rightOpen: order.add fRight
  let i = max(0, order.find(focus))
  focus = order[(i + d + order.len) mod order.len]
  needRender = true

proc terminalPassKey(k: Key): bool =
  ## keys that still reach ned while the terminal has focus
  if k.kind == kChar and mCtrl in k.mods and k.ch in [ord('\\'), ord('q')]: return true
  if k.kind == kChar and mAlt in k.mods and k.ch in [ord('`'), ord('o'), ord('c')]: return true
  if k.kind == kFn and k.fn in [6, 10]: return true
  if k.kind in {kPgUp, kPgDn} and mCtrl in k.mods: return true
  if k.kind in {kUp, kDown, kPgUp, kPgDn} and mShift in k.mods: return true
  false

proc globalKey(k: Key): bool =
  let ctrl = mCtrl in k.mods
  let alt = mAlt in k.mods
  let shift = mShift in k.mods
  result = true
  case k.kind
  of kChar:
    if ctrl and not alt:
      case char(min(k.ch, 127))
      of 'q': requestQuit()
      of 's': discard buf().saveBuffer()
      of 'e': cmdPalette()
      of 'p', 'o': cmdFindFile()
      of 'b': toggleTree()
      of 'n': newFile()
      of 'w': closeBuffer(curBuf)
      of 't':
        focus = fEditor
        cmdSymbols()
      of 'g':
        focus = fEditor
        openPrompt(pGoto, "Go to line[:col]")
      of 'f':
        focus = fEditor
        let b = buf()
        let (a, e) = b.primary.range
        openPrompt(pFind, "Find", (if a != e and a.line == e.line: b.getText(a, e) else: findQuery))
        findIncremental()
      of 'r':
        if cfgVim and focus == fEditor and vimMode != vmInsert: return false
        focus = fEditor
        let b = buf()
        let (a, e) = b.primary.range
        openPrompt(pReplaceFind, "Replace", (if a != e and a.line == e.line: b.getText(a, e) else: findQuery))
      of '\\': toggleTerminal()
      else: result = false
    elif alt and not ctrl:
      case char(min(k.ch, 127))
      of 'x': cmdPalette()
      of 'v': todoJump(1)
      of 'V': todoJump(-1)
      of 'o': togglePanel()
      of 'r':
        focus = fEditor
        runCurrent()
      of 'b':
        focus = fEditor
        runCurrent(true)
      of 'n': gotoDiag(1)
      of 'p': gotoDiag(-1)
      of 't': cmdThemes()
      of 'T': reopenClosedTab()
      of 'R': macroToggle()                   # Alt+Shift+R: record a macro / stop
      of 'M': macroPlay(macroLast)            # Alt+Shift+M: play it (Alt+Shift+P arrives as ESC P, a terminal string)
      of 's':
        let b = buf()
        let (a, e) = b.primary.range
        openPrompt(pSearch, "Search project", (if a != e and a.line == e.line: b.getText(a, e) else: b.wordAt(b.primary.head)))
      of 'w':
        if cfgWrapUser and buf().largeOn:
          info("No soft wrap in this file: large-file mode (" & buf().largeWhy & ") — palette › Large file mode turns it off")
        else:
          cfgWrapUser = not cfgWrapUser
          cfgWrap = wrapFor(buf())
          info("Soft wrap " & (if cfgWrapUser: "on" else: "off"))
      of 'l':
        cfgLineNums = (cfgLineNums + 1) mod 3
        info("Line numbers: " & ["off", "absolute", "relative"][cfgLineNums])
      of 'u':
        cfgMouse = not cfgMouse
        setMouseMode()
        info("Mouse " & (if cfgMouse: "on" else: "off — Termux text selection works now"))
      of 'm':
        focus = fEditor
        cmdExpandMacro()
      of 'q':
        focus = fEditor
        cmdReferences()
      of 'e': (if treeOpen and sideView == svProject and focus == fTree: toggleTree() else: showSide(svProject))
      of 'g': (if treeOpen and sideView == svGit and focus == fTree: toggleTree() else: showSide(svGit))
      of 'i': (if rightOpen and rightView == svOutline and focus == fRight: toggleDock(dsRight) else: showSide(svOutline))
      of 'c', 'C':
        if k.ch == ord('C'): openPrompt(pAiEdit, "Edit with AI — describe the change", "")
        else: toggleAssistant()
      of '`': toggleTerminal()
      of 'z', 'Z': toggleZen()
      of '\\': toggleSplitFocus()
      of '|': closeSplit()
      of '\'': toggleBookmark()
      of ';': gotoBookmark(1)
      of ':': gotoBookmark(-1)
      of '-':
        let b = buf()
        b.foldLine(b.primary.head.line)
      of '=':
        let b = buf()
        b.unfoldLine(b.primary.head.line)
      of 'y': cmdNimbleTasks()
      of '1'..'9':
        let i = k.ch - ord('1')
        if i < bufs.len:
          curBuf = i
          focus = fEditor
          closeComp()
      of '?':
        helpOpen = true
        helpScroll = 0
      else: result = false
    else: result = false
  of kLeft, kRight:
    if alt and not ctrl and not shift: switchTab(if k.kind == kLeft: -1 else: 1)
    else: result = false
  of kPgUp, kPgDn:
    if ctrl and focus == fPanel and panelOpen and panelKind == pkTerminal and terms.len > 1:
      termCycle(if k.kind == kPgUp: -1 else: 1)          # in a terminal: the other terminal (or split half)
    elif ctrl: switchTab(if k.kind == kPgUp: -1 else: 1)
    else: result = false
  of kFn:
    case k.fn
    of 6: cycleFocus(if shift: -1 else: 1)
    of 9: toggleBreakpoint()
    of 10:
      if ctrl and not shift: dbgRunToCursor()                    # run to cursor (starts debugging if needed)
      elif dbgOn and not shift: dbgCmd("-exec-next")        # while debugging F10 steps (menus: ≡ or Shift+F10)
      elif lay.titleY >= 0 and menuBarRanges.len > 0: openMenuBar(0)
      else: openAppMenu()
    of 11:
      if dbgOn: dbgCmd(if shift: "-exec-finish" else: "-exec-step")
      else: result = false
    of 1:
      helpOpen = true
      helpScroll = 0
    of 2: cmdRename()
    of 3: findStep(not shift)
    of 5:
      if dbgOn: (if shift: dbgEnd("stopped") else: dbgCmd("-exec-continue"))
      elif not shift and ((breakpoints.len > 0 and buf().path in breakpoints and breakpoints[buf().path].len > 0) or
                          dbgWpWanted.len > 0): dbgStart()
      else: runCurrent(shift)
    of 8: gotoDiag(if shift: -1 else: 1)
    of 7: gotoHunk(if shift: -1 else: 1)
    of 4: (if shift: cmdRunTask() else: cmdRerunTask())
    of 12:
      if alt: (if shift: cmdPeekReferences() else: cmdPeekDefinition())
      elif shift: cmdReferences()
      else: cmdDefinition()
    else: result = false
  else: result = false

proc editorKey(k: Key) =
  let b = buf()
  let ctrl = mCtrl in k.mods
  let alt = mAlt in k.mods
  let shift = mShift in k.mods
  if ghostVisible(b):
    if k.kind == kTab and k.mods == {} and not compOpen and ghostAccept(): return
    if k.kind == kEsc:
      ghostClear()
      return
  if hoverOpen:
    hoverOpen = false
    if k.kind == kEsc: return
  if b.isWelcome() and welcomeKey(k): return
  if vimEditorKey(k): return
  if helixEditorKey(k): return
  if sigOpen and k.kind notin {kChar, kBackspace, kPaste}:
    sigOpen = false
    if k.kind == kEsc and not compOpen: return
  if compOpen:
    let n = compShown.len
    case k.kind
    of kUp:
      if ctrl: compDocScroll = max(0, compDocScroll - 3)          # scroll the documentation
      else: compSel = (compSel - 1 + n) mod n
      return
    of kDown:
      if ctrl: compDocScroll += 3
      else: compSel = (compSel + 1) mod n
      return
    of kChar:
      if ctrl and not alt and k.ch in [ord(' '), ord('@')]:
        # Ctrl+Space with the list open: documentation beside it on / off
        cfgCompDocs = not cfgCompDocs
        setSetting("editor.completionDocs", %cfgCompDocs)
        return
    of kPgUp:
      compSel = max(0, compSel - 8)
      return
    of kPgDn:
      compSel = min(n - 1, compSel + 8)
      return
    of kTab, kEnter:
      if k.mods == {}:
        acceptComp()
        return
    of kEsc:
      closeComp()
      return
    else: discard
  case k.kind
  of kChar:
    if ctrl and not alt:
      closeComp()
      case char(min(k.ch, 127))
      of 'a': b.setSingle(Pos(line: b.lines.high, col: b.lines[^1].len), Pos())
      of 'c': copySel(false)
      of 'x': copySel(true)
      of 'v': paste()
      of 'z': b.undo()
      of 'y': b.redo()
      of 'd': b.selectNextOccurrence()
      of 'l': b.selectLine()
      of 'k': b.deleteLines()
      of '/', '_', '7': b.toggleComment()
      of ' ', '@': startCompletion(true)
      of ']':
        let (ok, a, e) = b.matchBracket(b.primary.head)
        if ok: b.setSingle(if b.primary.head == a or b.primary.head.col == a.col + 1: e else: a)
      of 'u': b.undo()
      else: discard
    elif alt and not ctrl:
      closeComp()
      case char(min(k.ch, 127))
      of 'd': b.duplicate()
      of 'j': b.addCursorVert(1)
      of 'k': b.addCursorVert(-1)
      of 'a': b.selectAllOccurrences()
      of '.': cmdDefinition()
      of ',': jumpBack()
      of '<': jumpForward()
      of 'h': cmdHover()
      of 'f': b.formatBuffer()
      of '/': b.toggleComment()
      else: discard
    elif not ctrl and not alt:
      var s = ""
      s.addUtf8(k.ch)
      b.typeChar(s)
      afterType(k.ch)
  of kPaste:
    closeComp()
    b.insertText(k.text)
  of kEnter:
    closeComp()
    if alt or ctrl: cmdCodeActions()          # Alt+Enter: quick fixes (imports, AI fix, server actions)
    elif shift and replCommandFor(b.lang)[0].len > 0 and b.lang.id != "shellscript":
      replSendSelOrStatement()                # Shift+Enter (terminals that report it): send to the REPL
    else: b.newline()
  of kTab:
    closeComp()
    if shift:
      if not (b.stops.len > 0 and b.snippetJump(-1)): b.indentLines(-1)
    elif b.stops.len > 0 and b.snippetJump(1): discard
    elif b.trySnippetAtCursor(): discard
    elif b.lang.mode == lmHtml and cfgEmmet and b.tryEmmet(): discard
    elif b.lang.mode == lmCss and cfgEmmet and b.tryEmmetCss(): discard
    else: b.tabKey()
  of kBackspace:
    b.backspace(ctrl or alt)
    if compOpen: refilterComp()
  of kDelete:
    closeComp()
    b.deleteForward(ctrl)
  of kLeft, kRight, kHome, kEnd:
    closeComp()
    if alt and shift and k.kind in {kLeft, kRight}:
      if k.kind == kRight: expandSelection() else: shrinkSelection()
      return
    cmdMove(k.kind, shift, ctrl)
  of kUp, kDown:
    closeComp()
    if alt and not shift: b.moveLines(if k.kind == kUp: -1 else: 1)
    elif alt and shift: b.addCursorVert(if k.kind == kUp: -1 else: 1)
    elif ctrl: b.scrollBy(if k.kind == kUp: -1 else: 1)
    else: cmdMove(k.kind, shift, false)
  of kPgUp, kPgDn:
    closeComp()
    cmdMove(k.kind, shift, false)
  of kEsc:
    closeComp()
    if b.stops.len > 0:
      b.stops.setLen(0)
      b.stopIds.setLen(0)
    if b.cursors.len > 1:
      b.cursors = @[b.primary]
      b.prim = 0
    elif b.primary.hasSel:
      b.cursors[0].anchor = b.cursors[0].head
    elif panelOpen:
      panelOpen = false
    b.wordMode = false
  else: discard

proc helpKey(k: Key) =
  case k.kind
  of kUp: helpScroll = max(0, helpScroll - 1)
  of kDown: inc helpScroll
  of kPgUp: helpScroll = max(0, helpScroll - 10)
  of kPgDn: helpScroll += 10
  else: helpOpen = false

proc cmdKeyboardShortcuts() =
  ## every command with its keys; pick one, then press its new key
  var items: seq[(string, string, Action)]
  var search: seq[string]
  for c in commands:
    var mine: seq[string]
    for k, v in cfgKeys:
      if v == c.name: mine.add k
    let name = c.name
    let detail = (if mine.len > 0: mine.join(", ") & " (yours)" & (if c.keys.len > 0: " · " & c.keys else: "") else: c.keys)
    capture name:
      items.add act(name, detail, proc() =
        keyCaptureFor = name
        info("Press the new key for “" & name & "” — Esc cancels, Backspace removes your keys for it"))
    search.add detail.toLowerAscii
  openActions("Keyboard shortcuts — pick a command, then press its key", items, search)

proc captureKey(k: Key) =
  let name = keyCaptureFor
  keyCaptureFor = ""
  if k.kind == kEsc:
    info("Cancelled")
    return
  initSettingDefs()
  var keys = newJObject()
  let cur = sval("keys")
  if cur != nil and cur.kind == JObject:
    for kk, v in cur.pairs: keys[kk] = v
  if k.kind == kBackspace:
    var gone: seq[string]
    for kk, v in keys.pairs:
      if v.getStr == name: gone.add kk
    for kk in gone: keys.delete(kk)
    setSetting("keys", keys)
    info(if gone.len > 0: "Removed " & gone.join(", ") & " from “" & name & "”" else: "“" & name & "” had no keys of yours")
    return
  let kn = keyName(k)
  if kn.len == 0:
    warn("That key cannot be bound — try another")
    return
  let was = if keys.hasKey(kn): keys[kn].getStr else: ""
  keys[kn] = %name
  setSetting("keys", keys)
  info(kn & " → " & name & (if was.len > 0 and was != name: " (was: " & was & ")" else: ""))

proc handleKey(k: Key) =
  needRender = true
  if macroRecording: macroNoteKey(k)
  if bufs.len > 0:
    tabW = buf().tabOf
    cfgWrap = wrapFor(buf())
  if k.kind == kMouse:
    handleMouse(k)
    return
  if k.kind == kEsc and toasts.len > 0:
    var keep: seq[Toast]
    for t in toasts:
      if not t.fromMsg: keep.add t
    toasts = keep                         # Esc closes the message popups (and does its usual job too)
  if keyCaptureFor.len > 0:
    captureKey(k)
    return
  if dialogOpen():
    dialogKey(k)
    return
  if menuOpen():
    menuKey(k)
    return
  if helpOpen:
    helpKey(k)
    return
  if replaceActive:
    replaceKey(k)
    return
  if pickKind != pickNone:
    pickerKey(k)
    return
  if promptKind != pNone:
    promptKey(k)
    return
  if focus == fEditor and buf().id in diffViews and diffKey(k): return
  if focus == fEditor and renamePv.bufId > 0 and buf().id == renamePv.bufId and renamePvKey(k): return
  if focus == fEditor and k.kind == kEnter and k.mods == {} and buf().id in graphBufs:
    let h = graphHashAt(buf().lines[buf().primary.head.line])
    if h.len > 0: commitMenu(h, "")
    return
  if focus == fEditor and k.kind == kEnter and k.mods == {} and buf().id in blameBufs:
    let hs = blameBufs[buf().id]
    let l = buf().primary.head.line
    if l < hs.len and not hs[l].startsWith("0000000"): commitMenu(hs[l], "")
    return
  if focus == fEditor and k.kind == kEnter and k.mods == {} and buf().id in multiBufs:
    let (ok, path, fl) = mbHeaderAt(buf(), buf().primary.head.line)
    if ok:
      mbOpen(path, fl)                     # Enter on a § header: that place in its file
      return
  if k.kind in {kLeft, kRight, kUp, kDown} and k.mods == {mCtrl, mAlt}:
    case k.kind
    of kLeft: resizeBy(true, -1)
    of kRight: resizeBy(true, 1)
    of kUp: resizeBy(false, 1)
    else: resizeBy(false, -1)
    return
  if focus == fPanel and panelOpen and panelKind == pkTerminal and not terminalPassKey(k):
    terminalKey(k)
    return
  if zenMode and k.kind == kEsc and focus == fEditor and not compOpen and not hoverOpen and not cfgVim:
    # Esc Esc leaves zen — but not in vim mode, where Esc is how you get back to NORMAL (often twice,
    # by habit): there Alt+Z, :zen or a click on the corner info leave it
    if msSince(zenEscAt) < 450:
      toggleZen()
      return
    zenEscAt = getMonoTime()
  if hoverOpen and k.kind == kEsc:
    hoverOpen = false               # Esc always closes a hover popup first, wherever the focus is
    return
  if customKey(k): return
  if cfgKeymap == "emacs" and focus == fEditor and emacsKey(k): return
  if focus == fTree and sideView == svSearch and treeOpen and k.kind == kChar and mAlt in k.mods and
     mCtrl notin k.mods and char(min(k.ch, 127)) in {'c', 'w', 'r', 'x', 'h'}:
    searchViewKey(k)          # the search view's own toggles win over the global Alt keys
    return
  if globalKey(k): return
  case focus
  of fTree: sideKey(k)
  of fRight: rightKey(k)
  of fPanel:
    if panelKind == pkTerminal: terminalKey(k) else: panelKey(k)
  of fEditor:
    let hb = buf()
    let linked = cfgLinkedEditing and hb.lang.mode == lmHtml and k.kind in {kChar, kBackspace, kDelete, kPaste} and
                 mCtrl notin k.mods and mAlt notin k.mods
    if linked: htmlLinkBefore(hb)
    editorKey(k)
    if linked: htmlLinkAfter(hb)
