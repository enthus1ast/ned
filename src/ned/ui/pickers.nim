# ════════════════════════════════════════════════════════════════════════════
#  Pickers (command palette, files, symbols, buffers, themes, languages)
# ════════════════════════════════════════════════════════════════════════════

var
  pickPrevQ = ""
  pickCand: seq[int]
  pickCandUpTo = 0

# Telescope's finders (ui/telescope) are action pickers with a preview for each item
type TsPreview = object
  path: string            # a file to show, at `line`
  line: int
  find: string            # … the line that declares this name (looked for when first shown)
  text: string            # else this text (a setting's description …)
  lang: string            # … coloured as this language
  cmd: string             # … or what this command prints (git show …), asked when first shown
  asked: bool
var
  tsActive = false        # the open picker is a Telescope finder
  tsPreviews: seq[TsPreview]
  tsTextBufs: Table[int, Buffer]   # (a text preview, made once: a buffer to draw)
  tsNoFilter = false      # its items are the query's answer (live grep): shown as they come
  tsLive: proc(q: string) {.closure.} = nil
  tsLiveQ = ""
  tsLiveDue: MonoTime
  tsGen = 0               # (each picker opened: an answer for an earlier one is dropped)
  tsJob: Job
  tsCurIsLast = false     # the finder Telescope: resume opens again (its query is kept)
  tsLastQuery = ""

proc pickQueryNorm(): string =
  ## the query the picker filters by: lower case with spaces taken out (for the file picker, none when it starts with :
  ## @ > or #, which are jump prefixes)
  var q = pickQuery
  if pickKind == pickFile and q.len > 0 and q[0] in {':', '@', '>', '#'}: q = ""
  q.toLowerAscii.replace(" ", "")

proc refilterPicker(keepSel = false) =
  ## incremental: a refined query only rescans the previous matches; huge sets use a greedy scorer
  if tsActive and tsCurIsLast: tsLastQuery = pickQuery
  if tsLive != nil and pickQuery != tsLiveQ: tsLiveDue = getMonoTime() + initDuration(milliseconds = 220)
  if tsNoFilter:
    # (live grep: what the search found for the query is the list, as it is)
    pickShown = newSeq[int](pickItems.len)
    for i in 0 ..< pickItems.len: pickShown[i] = i
    pickSel = if keepSel: clamp(pickSel, 0, max(0, pickShown.high)) else: 0
    if not keepSel: pickScroll = 0
    needRender = true
    return
  let lq = pickQueryNorm()
  pickShown.setLen(0)
  if lq.len == 0:
    pickShown = newSeq[int](pickItems.len)
    for i in 0 ..< pickItems.len: pickShown[i] = i
    pickPrevQ = ""
  else:
    var cand: seq[int]
    let reuse = pickPrevQ.len > 0 and lq.startsWith(pickPrevQ)
    let total = if reuse: pickCand.len + (pickItems.len - pickCandUpTo) else: pickItems.len
    let quick = total > 40000
    template consider(i: int) =
      ## scores picker item `i` against the query (a quick scorer on very big lists); a name that does not match still
      ## counts, after the others, when every word of the query is in the item's description; items that match are added
      ## to the candidates
      var sc = if quick: fuzzyQuick(lq, pickItems[i].label) else: fuzzyScore(lq, pickItems[i].label)
      if sc == low(int) and pickItems[i].search.len > 0:
        # every word of the query in the description: listed after the name matches
        var all = true
        for w in pickQuery.toLowerAscii.splitWhitespace():
          if w notin pickItems[i].search: all = false
        if all: sc = -100_000
      if sc != low(int) and pickKind == pickFile and sc > -100_000:
        # (a file whose name is the query — `demo.nim` — before a longer name that starts with it, `demo.nimble`)
        let l = pickItems[i].label.toLowerAscii
        if l == lq or l.endsWith("/" & lq): sc += 1000
      if sc != low(int):
        pickItems[i].score = sc
        cand.add i
    if reuse:
      for i in pickCand: consider(i)
      for i in pickCandUpTo ..< pickItems.len: consider(i)
    else:
      for i in 0 ..< pickItems.len: consider(i)
    pickCand = cand
    pickPrevQ = lq
    pickShown = cand
    pickShown.sort(proc(a, b: int): int =
      result = cmp(pickItems[b].score, pickItems[a].score)
      if result == 0: result = cmp(a, b))
  pickCandUpTo = pickItems.len
  if not keepSel:
    pickSel = 0
    pickScroll = 0
  else:
    pickSel = clamp(pickSel, 0, max(0, pickShown.high))
  needRender = true

proc openPicker(kind: PickKind, title: string, items: seq[PickItem]) =
  ## opens a picker of the given kind with a title and its items, with an empty query: forgets the last Telescope
  ## finder's previews and live search, closes completion and hover, and filters; the symbol picker starts on the symbol
  ## the cursor is in
  inc tsGen
  tsActive = false
  tsPreviews.setLen(0)
  tsTextBufs.clear()
  tsNoFilter = false
  tsLive = nil
  tsLiveQ = ""
  tsCurIsLast = false
  closeComp()
  hoverOpen = false
  pickFolderDir = ""
  pickKind = kind
  pickTitle = title
  pickNear = false
  pickItems = items
  pickQuery = ""
  pickCur = 0
  refilterPicker()
  if kind == pickSymbol:
    let b = buf()
    var best = 0
    for i, it in pickItems:
      if it.path == b.path and it.line <= b.primary.head.line: best = i
    if pickItems.len > 0:
      pickSel = pickShown.find(best).max(0)

proc closePicker() =
  ## closes the picker, putting the previous theme back if the theme picker was only previewing one
  pickFolderDir = ""
  if pickKind == pickTheme and pickPrevTheme.len > 0: applyTheme(pickPrevTheme)
  pickKind = pickNone
  pickPrevTheme = ""
  needRender = true

proc fileItems(): seq[PickItem] =
  ## the file picker's items: the open files (marked ●), up to 30 recent ones (○), then every file of the project
  ## (workspace folders labelled by their name)
  pickSeen.clear()
  for b in bufs:
    if b.path.len > 0 and b != buf():
      let r = relPath(b.path)
      pickSeen.incl r
      result.add PickItem(label: (if r.isAbsolute and wsRoots.len > 0: wsLabel(r) else: r), path: b.path, icon: "●", line: -1)
  pickSeen.incl relPath(buf().path)
  for p in recentFiles:
    let r = relPath(p)
    if r notin pickSeen and result.len < 30 and fileExists(p):
      pickSeen.incl r
      result.add PickItem(label: (if r.isAbsolute and wsRoots.len > 0: wsLabel(r) else: r), path: p, icon: "○", line: -1)
  let files = projectFiles()
  for r in files:
    if r notin pickSeen:
      if r.isAbsolute and wsRoots.len > 0: result.add PickItem(label: wsLabel(r), path: r, line: -1)
      else: result.add PickItem(label: r, line: -1)
  pickFileCount = files.len

proc feedPickerFiles() =
  ## stream files found by the background scan into an open file picker
  if pickFileCount >= fileCache.len: return
  for i in pickFileCount ..< fileCache.len:
    let r = fileCache[i]
    if r notin pickSeen:
      if r.isAbsolute and wsRoots.len > 0: pickItems.add PickItem(label: wsLabel(r), path: r, line: -1)
      else: pickItems.add PickItem(label: r, line: -1)
  pickFileCount = fileCache.len
  refilterPicker(keepSel = true)

proc pickPath(it: PickItem): string =
  ## the file an item stands for: its path, else its label as an absolute path or under the project folder
  if it.path.len > 0: it.path
  elif it.label.isAbsolute: it.label
  else: rootDir / it.label

proc cmdFindFile(initial = "") =
  ## opens the file picker (Go to file), with `initial` already typed in the query
  openPicker(pickFile, "Open file   (:line  @symbol  #project symbol  >command)", fileItems())
  pickQuery = initial
  pickCur = initial.len
  refilterPicker()

proc cmdPalette() =
  ## most-used commands first, then the rest in definition order
  var order: seq[int]
  for i in 0 ..< commands.len: order.add i
  order.sort(proc(a, b: int): int =
    result = cmp(cmdUses.getOrDefault(commands[b].name), cmdUses.getOrDefault(commands[a].name))
    if result == 0: result = cmp(a, b))
  var items: seq[PickItem]
  for i in order: items.add PickItem(label: commands[i].name, detail: commands[i].keys, idx: i, line: -1)
  openPicker(pickCmd, "Command palette", items)

proc cmdBuffers() =
  ## opens a picker of the open tabs (modified ones marked), starting on the next one
  var items: seq[PickItem]
  for i, b in bufs:
    items.add PickItem(label: (if b.path.len > 0: relPath(b.path) else: "untitled"),
                       detail: (if b.dirty: "modified" else: ""), idx: i, icon: (if b.dirty: "●" else: " "), line: -1)
  openPicker(pickBuffer, "Switch buffer", items)
  if bufs.len > 1: pickSel = 1

proc cmdThemes() =
  ## opens a picker of the themes (and "auto"), starting on the current one; moving through it previews each theme,
  ## closing it without choosing puts the old one back
  var items: seq[PickItem]
  items.add PickItem(label: "auto", detail: "light or dark, to match the terminal (theme.light / theme.dark)", line: -1)
  for t in allThemes(): items.add PickItem(label: t.name, detail: (if t.dark: "dark" else: "light"), line: -1)
  pickPrevTheme = cfgThemeName
  openPicker(pickTheme, "Select theme", items)
  for i, it in items:
    if it.label == cfgThemeName: pickSel = i

proc cmdLanguages() =
  ## opens a picker of the languages to set the current file's language mode
  var items: seq[PickItem]
  for l in langs: items.add PickItem(label: l.name, detail: l.exts.join(" "), line: -1)
  openPicker(pickLang, "Set language mode", items)

proc acceptPicker() =
  ## uses the selected item by the picker's kind: runs the command, opens the file or symbol at its line (leaving a jump
  ## to come back to), switches to the tab, sets the theme (kept in the settings) or the file's language, or runs the
  ## action; in the file picker a query starting with `:` goes to that line, `@` to the file's symbols, `>` to the
  ## command palette, and a name matching nothing opens (creates) that file once the scan is done
  let kind = pickKind
  if kind == pickFile and pickQuery.len > 0 and pickQuery[0] in {':', '@', '>'}:
    let q = pickQuery
    pickKind = pickNone
    case q[0]
    of ':': gotoLineText(q[1 .. ^1])
    of '@':
      cmdSymbols()
      if pickKind != pickNone:
        pickQuery = q[1 .. ^1]
        pickCur = pickQuery.len
        refilterPicker()
    else:
      cmdPalette()
      pickQuery = q[1 .. ^1]
      pickCur = pickQuery.len
      refilterPicker()
    return
  if pickShown.len == 0:
    if kind == pickFile and pickQuery.strip.len > 0 and scanning:
      # the list is still being made: the file may well be there — never create a stray one
      info("Still listing the project's files — Enter again in a moment")
      return
    if kind == pickFile and pickQuery.strip.len > 0:
      pickKind = pickNone
      let p = expandTilde(pickQuery.strip)
      let full = if p.isAbsolute: p else: rootDir / p
      discard openFile(full)
      if fileCacheValid: fileCache.add relPath(full)
    return
  let it = pickItems[pickShown[pickSel]]
  pickKind = pickNone
  case kind
  of pickCmd:
    cmdUses[commands[it.idx].name] = cmdUses.getOrDefault(commands[it.idx].name) + 1
    commands[it.idx].action()
  of pickFile, pickSymbol:
    if kind == pickSymbol or it.line >= 0: pushJump()
    let b = openFile(pickPath(it))
    if b != nil and it.line >= 0: b.centerOn(b.clampPos(Pos(line: it.line, col: it.col)))
  of pickBuffer:
    curBuf = clamp(it.idx, 0, bufs.high)
    focus = fEditor
  of pickTheme:
    applyTheme(it.label)
    pickPrevTheme = ""
    setSetting("theme", %it.label)
    info("Theme: " & it.label)
  of pickLang:
    let b = buf()
    let l = langByName(it.label)
    if l != nil:
      lspDidClose(b)
      b.lang = l
      b.hlValid = 0
      lspAttach(b)
      info("Language: " & l.name)
  of pickRecent:
    discard openFile(pickPath(it))
  of pickAction:
    if it.idx >= 0 and it.idx < pickActions.len: pickActions[it.idx]()
  of pickNone: discard
  needRender = true

proc editLine(text: var string, cur: var int, k: Key): bool =
  ## shared single-line input editing (with its selection: ui/fieldsel); returns true if handled
  cur = clamp(cur, 0, text.len)
  let ctrl = mCtrl in k.mods
  let alt = mAlt in k.mods
  let shift = mShift in k.mods
  if not fieldOwns(text):
    fieldSelClear()                      # (another field had the selection: this one starts with none)
    fieldSelOwner = cast[pointer](addr text)
  proc move(text: var string, cur: var int, to: int, shift: bool) =
    ## moves the cursor to byte `to`, extending the selection when Shift is held and dropping it otherwise
    if shift:
      if fieldSelAnchor < 0: fieldSelect(text, cur, cur)
    else: fieldSelClear()
    cur = clamp(to, 0, text.len)
  proc insertText(text: var string, cur: var int, t: string) =
    ## types `t` at the cursor, replacing the selection if there is one
    discard fieldDeleteSel(text, cur)
    text.insert(t, cur)
    cur += t.len
  case k.kind
  of kChar:
    if ctrl and k.ch == ord('u'):
      fieldSelClear()
      text = text[cur .. ^1]
      cur = 0
    elif ctrl and k.ch == ord('k'):
      fieldSelClear()
      text.setLen(cur)
    elif ctrl and k.ch == ord('a'):
      # everything selected, as in any text box
      fieldSelect(text, 0, text.len)
      cur = text.len
    elif ctrl and k.ch == ord('e'): move(text, cur, text.len, shift)
    elif ctrl and k.ch in [ord('c'), ord('x')]:
      let t = fieldSelText(text, cur)
      if t.len == 0: return false        # (nothing selected: the key is the caller's)
      clipSet(t)
      if k.ch == ord('x'): discard fieldDeleteSel(text, cur)
    elif ctrl and k.ch == ord('v'):
      var t = if clipLineMode: clipParts.join("") else: clipParts.join("\n")
      let sys = clipGet()
      if sys.len > 0: t = sys
      t = t.splitLines()[0]
      insertText(text, cur, t)
    elif ctrl or alt: return false
    else:
      var s = ""
      s.addUtf8(k.ch)
      insertText(text, cur, s)
  of kPaste:
    let t = if k.text.len > 0: k.text.splitLines()[0] else: ""
    insertText(text, cur, t)
  of kBackspace:
    if fieldDeleteSel(text, cur): return true
    if cur > 0:
      var a = prevCluster(text, cur)
      if ctrl or alt:
        a = cur
        while a > 0 and text[a-1] == ' ': dec a
        while a > 0 and text[a-1] != ' ' and text[a-1] != '/': dec a
        if a == cur: a = prevCluster(text, cur)       # right after a '/': remove that one character
      if a < cur:
        text.delete(a ..< cur)
        cur = a
  of kDelete:
    if fieldDeleteSel(text, cur): return true
    if cur < text.len and nextCluster(text, cur) > cur: text.delete(cur ..< nextCluster(text, cur))
  of kLeft:
    let (a, _) = fieldSelRange(text, cur)
    if not shift and a != cur and not ctrl: move(text, cur, a, false)      # (a selection: to its start)
    elif ctrl or alt: move(text, cur, fieldWordStart(text, cur), shift)
    elif cur > 0: move(text, cur, prevCluster(text, cur), shift)
    else: move(text, cur, cur, shift)
  of kRight:
    let (_, b) = fieldSelRange(text, cur)
    if not shift and b != cur and not ctrl: move(text, cur, b, false)
    elif ctrl or alt: move(text, cur, fieldWordEnd(text, cur), shift)
    elif cur < text.len: move(text, cur, nextCluster(text, cur), shift)
    else: move(text, cur, cur, shift)
  of kHome: move(text, cur, 0, shift)
  of kEnd: move(text, cur, text.len, shift)
  else: return false
  true

proc pickerKey(k: Key) =
  ## the keys of the open picker: Esc closes, Enter uses the selection, arrows, Tab, Ctrl+N/P/J/K and Page Up/Down move
  ## in the list, Alt+V, Alt+X and Alt+Q open the item beside, below or all in a multibuffer, and other keys edit the
  ## query and filter again (typing > @ or # alone in the file picker switches to commands or symbols); in the folder
  ## browser Backspace or Left goes up, Right goes in and Alt+Enter opens the folder as the project; moving over themes
  ## previews them
  if pickFolderDir.len > 0:
    # the folder browser: Backspace or ← goes up, → goes in, Alt+Enter opens the highlighted folder,
    # a typed path (/… or ~/…) jumps there
    let atStart = pickQuery.len == 0
    if (k.kind == kBackspace and atStart and k.mods == {}) or (k.kind == kLeft and atStart):
      let up = parentDir(pickFolderDir)
      if up.len > 0 and up != pickFolderDir: browseFolder(up)
      return
    if k.kind == kRight and pickCur >= pickQuery.len:
      acceptPicker()
      return
    if k.kind == kEnter and mAlt in k.mods:
      if pickShown.len > 0:
        let it = pickItems[pickShown[pickSel]]
        if it.idx >= 0 and it.idx < pickFolderPaths.len:
          let d = pickFolderPaths[it.idx]
          closePicker()
          openFolder(d)
      return
    if k.kind == kEnter and pickQuery.len > 0 and pickQuery[0] in {'/', '~'}:
      let d = absolutePath(expandTilde(pickQuery.strip)).normalizedPath
      if dirExists(d): browseFolder(d)
      else: error("No such folder: " & pickQuery)
      return
  # (a finder of places — files, lines, symbols, Telescope's: Alt+V opens the one chosen in a pane at the right,
  # Alt+X in a pane below, Alt+Q puts them all in a multibuffer)
  if k.kind == kChar and k.mods == {mAlt} and k.ch in [ord('v'), ord('x'), ord('q')] and
     pickKind in {pickFile, pickRecent, pickSymbol, pickBuffer, pickAction}:
    if k.ch == ord('q'): pickToMultibuffer() else: pickOpenBeside(k.ch == ord('x'))
    return
  case k.kind
  of kEsc: closePicker()
  of kEnter: acceptPicker()
  of kUp:
    if pickShown.len > 0: pickSel = (pickSel - 1 + pickShown.len) mod pickShown.len
  of kDown, kTab:
    if pickShown.len > 0: pickSel = (pickSel + 1) mod pickShown.len
  of kPgUp: pickSel = max(0, pickSel - 10)
  of kPgDn: pickSel = max(0, min(pickShown.high, pickSel + 10))
  else:
    if k.kind == kChar and mCtrl in k.mods and k.ch in [ord('n'), ord('j')]:
      if pickShown.len > 0: pickSel = (pickSel + 1) mod pickShown.len
    elif k.kind == kChar and mCtrl in k.mods and k.ch in [ord('p'), ord('k')]:
      if pickShown.len > 0: pickSel = (pickSel - 1 + pickShown.len) mod pickShown.len
    elif editLine(pickQuery, pickCur, k):
      if pickKind == pickFile and pickQuery == ">":
        cmdPalette()
        return
      if pickKind == pickFile and pickQuery == "@":
        pickKind = pickNone
        cmdSymbols()
        return
      if pickKind == pickFile and pickQuery == "#":
        pickKind = pickNone
        cmdProjectSymbols()
        return
      refilterPicker()
  if pickKind == pickTheme and pickShown.len > 0:
    applyTheme(pickItems[pickShown[pickSel]].label)
