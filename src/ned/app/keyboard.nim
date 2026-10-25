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
  ## your "keys" setting, then the keys plugins gave their commands
  if cfgKeys.len == 0 and plugKeys.len == 0 and not plugHasLangKeys(): return false
  let n = keyName(k)
  if n.len == 0: return false
  if n in cfgKeys:
    runCmd(cfgKeys[n])
    return true
  if plugLangKey(n): return true            # (a plugin's key for the file's language: the folder view's Alt+Enter)
  if n in plugKeys:
    runCmd(plugKeys[n])
    return true
  false

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

func terminalPassKey(k: Key): bool =
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
        if cfgVim and focus == fEditor and vimMode == vmInsert: return false   # (vim's insert mode: one level in)
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
      of 'J': cmdJumpLabels()                 # Alt+Shift+J: a label on each word on screen
      of 'G':                                 # Alt+Shift+G: every change not committed, in one editable view
        focus = fEditor
        cmdGitChanges()
      of 'U':                                 # Alt+Shift+U: every state of the file, the undo tree's branches too
        focus = fEditor
        cmdUndoHistory()
      of 'S':                                 # Alt+Shift+S: brackets, quotes, a tag or a block around the selection
        focus = fEditor
        cmdSurround()
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
  # (cursors left past the end by a change that came from elsewhere — a reload, the assistant's undo — are put
  # back on the text before a key moves them)
  for c in b.cursors.mitems:
    c.head = b.clampPos(c.head)
    c.anchor = b.clampPos(c.anchor)
  let ctrl = mCtrl in k.mods
  let alt = mAlt in k.mods
  let shift = mShift in k.mods
  if ghostVisible(b):
    if k.kind == kTab and k.mods == {} and not compOpen and ghostAccept(): return
    if k.kind == kEsc:
      ghostClear()
      return
  if nesVisible(b) and not compOpen and k.mods == {}:
    # a next-edit suggestion: Tab goes to it, then makes it; Esc says no
    if k.kind == kTab and b.nesTab(): return
    if k.kind == kEsc:
      nesClear()
      info("")
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
      of '.': cmdCodeActions()                # Ctrl+. (where the terminal tells it apart): quick fixes, as Alt+Enter
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
      if cfgFormatOnType: formatOnTypeAsk(b, s)
  of kPaste:
    closeComp()
    let l0 = b.primary.range[0].line
    b.insertText(b.pasteLayout(k.text, b.primary.range[0]))
    b.pasteFinish(l0)
  of kEnter:
    closeComp()
    if ctrl and not alt and nbCanRun(b): nbRunAt(b, b.primary.head.line)   # Ctrl+Enter: the notebook's cell
    elif alt or ctrl: cmdCodeActions()          # Alt+Enter: quick fixes (imports, AI fix, server actions)
    elif shift and nbActive(b) and nbCanRun(b):
      nbRunAt(b, b.primary.head.line, advance = true)   # Shift+Enter once the notebook runs: the cell, then on
    elif shift and replCommandFor(b.lang)[0].len > 0 and b.lang.id != "shellscript":
      replSendSelOrStatement()                # Shift+Enter (terminals that report it): send to the REPL
    else:
      b.newline()
      if cfgFormatOnType: formatOnTypeAsk(b, "\n")
  of kTab:
    closeComp()
    if shift:
      if not (b.stops.len > 0 and b.snippetJump(-1)): b.indentLines(-1)
    elif b.stops.len > 0 and b.snippetJump(1): discard
    elif b.nesTab(): discard
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

const KeyWords = ["enter", "tab", "backspace", "delete", "escape", "up", "down", "left", "right", "home", "end",
                  "pageup", "pagedown", "insert", "space"]

func keyTokens(display: string): seq[string] =
  ## a command's shortcut as the palette shows it ("Ctrl+S", "Alt+. / F12", "Ctrl+Shift+P") → key names as the
  ## "keys" setting writes them ("ctrl+s" …); words that describe instead of naming a key are left out
  for part0 in display.split({'/', ','}):
    let part = part0.strip
    if part.len == 0 or ' ' in part: continue
    var mods: seq[string]
    var key = ""
    var ok = true
    let ws = if part == "+": @["+"] elif part.endsWith("++"): part[0 ..< part.len - 2].split('+') & @["+"]
             else: part.split('+')
    for i, w in ws:
      let lw = w.toLowerAscii
      if i < ws.high:
        case lw
        of "ctrl", "control": mods.add "ctrl"
        of "alt", "meta", "option": mods.add "alt"
        of "shift": mods.add "shift"
        else: ok = false
      else:
        key = case lw
          of "esc": "escape"
          of "del": "delete"
          of "ins": "insert"
          of "pgup": "pageup"
          of "pgdn", "pgdown": "pagedown"
          of "return": "enter"
          else: lw
    if not ok or key.len == 0: continue
    if key.len > 1 and key notin KeyWords and not (key[0] == 'f' and key[1 .. ^1].allCharsInSet(Digits)): continue
    var res: seq[string]
    for m in ["ctrl", "alt", "shift"]:
      if m in mods: res.add m
    res.add key
    result.add res.join("+")

proc keyOwners(kn: string): seq[(string, string)] =
  ## the commands a key name runs: (command, built-in · yours · a plugin's)
  for c in commands:
    if kn in keyTokens(c.keys): result.add (c.name, "built-in")
  if kn in cfgKeys: result.add (cfgKeys[kn], "yours")
  if kn in plugKeys: result.add (plugKeys[kn], "a plugin's")

proc keyTerminalProblem(kn: string): string =
  ## why a terminal may never send this key ("" none) — the kitty keyboard protocol sends them all
  if tcKitty: return ""
  let parts = kn.split('+')
  let key = parts[^1]
  let ctrl = "ctrl" in parts
  let shift = "shift" in parts
  if ctrl and shift and key.len == 1 and key[0] in {'a'..'z'}:
    return "most terminals send it as ctrl+" & key & " (the kitty keyboard protocol tells them apart)"
  if ctrl and key.len == 1 and key[0] in {'0'..'9', ';', '\'', ',', '.', '=', '-', '/'}:
    return "most terminals send nothing for it, or another key"
  if ctrl and not shift and key in ["i", "m", "h", "["]:
    return "terminals send it as " & (case key
      of "i": "Tab"
      of "m": "Enter"
      of "h": "Backspace"
      else: "Escape")
  if ctrl and key in ["tab", "enter", "backspace"]: return "most terminals send it as plain " & key
  if shift and not ctrl and "alt" notin parts and key == "enter": return "most terminals send it as plain Enter"
  ""

proc commandSuggest(name: string): string =
  ## the command a misspelled name in "keys" probably means
  var best = ""
  var bd = max(3, name.len div 4)
  for c in commands:
    let d = editDistanceAscii(name.toLowerAscii, c.name.toLowerAscii)
    if d < bd:
      bd = d
      best = c.name
  best

proc keysSettingProblems(): seq[string] =
  ## your "keys" setting: commands that do not exist, keys a terminal cannot send, a key bound twice
  var seen: Table[string, string]
  var unknown, unsent, twice: seq[string]
  let cur = sval("keys")
  if cur == nil or cur.kind != JObject: return
  for k, v in cur.pairs:
    let kn = k.toLowerAscii.replace(" ", "")
    let name = v.getStr
    if cmdByName(name) < 0:
      let s = commandSuggest(name)
      unknown.add "\"" & k & "\": no command \"" & name & "\"" & (if s.len > 0: " — \"" & s & "\"?" else: "")
    let tp = keyTerminalProblem(kn)
    if tp.len > 0: unsent.add "\"" & k & "\": " & tp
    if kn in seen and seen[kn] != name: twice.add "\"" & k & "\" is in the setting twice"
    seen[kn] = name
  unknown & unsent & twice

var keysToldAbout = ""

proc keysCheckAtStart() =
  ## a note (once per change of the setting) when the "keys" setting has a problem
  let ps = keysSettingProblems()
  let sig = ps.join("|")
  if ps.len == 0 or sig == keysToldAbout: return
  keysToldAbout = sig
  toast("Your \"keys\" setting: " & ps[0] & (if ps.len > 1: " (and " & $(ps.len - 1) & " more)" else: ""), 2,
        "Keyboard shortcuts…", proc() = runCmd("Keyboard shortcuts…"), 15000)

proc cmdKeyboardShortcuts() =
  ## every command with its keys; pick one, then press its new key
  var items: seq[(string, string, Action)]
  var search: seq[string]
  # (the setting's problems first: a command that does not exist, a key no terminal sends, one bound twice)
  for p in keysSettingProblems():
    items.add act("⚠ " & p, "open the settings", proc() = runCmd("Open settings file"))
    search.add p.toLowerAscii
  # a key that two commands claim: who wins (yours over a plugin's over the built-in one)
  # (ned's own keys that two commands share are on purpose — Alt+\ splits, or goes to the other pane: only a key
  # of yours or a plugin's that another command has is shown)
  var claims: Table[string, seq[string]]
  for k, v in cfgKeys: claims.mgetOrPut(k, @[]).add v
  for k, v in plugKeys: claims.mgetOrPut(k, @[]).add v
  for c in commands:
    for kn in keyTokens(c.keys):
      if kn in claims: claims[kn].add c.name
  for c in commands:
    var mine: seq[string]
    for k, v in cfgKeys:
      if v == c.name: mine.add k
    for k, v in plugKeys:
      if v == c.name and k notin cfgKeys: mine.add k & " (plugin)"
    let name = c.name
    var clash = ""
    for kn in keyTokens(c.keys) & mine:
      let k0 = kn.replace(" (plugin)", "")
      for other in claims.getOrDefault(k0):
        if other != name and clash.len == 0: clash = "  ⚠ " & k0 & " is also “" & other & "”"
    let detail = (if mine.len > 0: mine.join(", ") & " (yours)" & (if c.keys.len > 0: " · " & c.keys else: "") else: c.keys) & clash
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
  proc bindIt() =
    let was = if keys.hasKey(kn): keys[kn].getStr else: ""
    keys[kn] = %name
    setSetting("keys", keys)
    let tp = keyTerminalProblem(kn)
    info(kn & " → " & name & (if was.len > 0 and was != name: " (was: " & was & ")" else: "") &
         (if tp.len > 0: " — careful: " & tp else: ""))
  # (the key runs another command already: say which, and ask)
  var others: seq[string]
  for (c, who) in keyOwners(kn):
    if c != name: others.add (case who
      of "built-in": "ned's"
      of "yours": "your"
      else: who) & " “" & c & "”"
  if others.len > 0:
    # (no parentheses before the buttons: the dialog reads its buttons from the first one)
    askConfirm(kn & " runs " & others.join(", ") & " — give it to “" & name & "”? Your key wins (y)es (c)ancel",
      proc(c: char) =
        if c in {'y', 'Y'}: bindIt()
        else: info("Not changed"))
  else: bindIt()

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
  if jumpOn and jumpKey(k): return                # jump labels on screen: their letters
  if dialogOpen():
    dialogKey(k)
    return
  if menuOpen():
    menuKey(k)
    return
  if formOpen():
    formKey(k)
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
  # (a picture's keys before the hex editor's: its bytes are the hex editor's only when Tab shows them)
  if focus == fEditor and buf().id in picViews and picKey(buf(), k): return
  if focus == fEditor and buf().hex != nil and hexKey(buf(), k): return
  if focus == fEditor and renamePv.bufId > 0 and buf().id == renamePv.bufId and renamePvKey(k): return
  if focus == fEditor and buf().id in flameViews and flameKey(k): return
  if focus == fEditor and k.kind == kEnter and k.mods == {} and ceIsView(buf()) and ceEnter(): return
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
