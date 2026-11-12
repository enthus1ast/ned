# ════════════════════════════════════════════════════════════════════════════
#  Headless vim mode (`ned -es`): the editor's own keys with no terminal and no screen.
#  A file and a case per request on stdin (one JSON an line) go in; where vim mode
#  left the cursor, the mode and the text come back, one JSON an line. It is what
#  tests/ui/vimdiff.py asks instead of a ned in a tmux session — a case in a few
#  milliseconds, not two seconds — and a real vim answers the other side
#  (tests/ui/vimoracle.py).
#
#    ned -es FILE                              # a request per line on stdin, until EOF
#    ned -es --keys "d w" --start 2:5 FILE     # one case, one answer, then out
#
#  A request names the keys as vim writes them (`<Esc>`, `<CR>`, `<C-w>`, `<Right>`,
#  or the characters themselves) and where they start, from 1:
#
#    {"keys": "d w", "line": 1, "col": 1}
#    {"reload": true}                          # the file changed on disk: read it again
#    {"quit": true}
#
#  The answer is {"line", "col", "viscol", "visual", "text"}: line and col from 1, col a
#  character column as vim's col('.') counts it, viscol the display column the status
#  bar shows (a tab takes the columns it is drawn over), visual "" normal, "v" visual,
#  "V" visual-line, "i" insert, "R" replace, and text the lines as a save would read
#  them back.
# ════════════════════════════════════════════════════════════════════════════

var hlOrig = ""          # the file as it was read: every case starts from its lines again

proc hlKeyOf(s: string, i: var int): Key =
  ## one key of a case's keys, as vim writes them — `<Esc>`, `<CR>`, `<Tab>`, `<BS>`, `<Del>`, `<Space>`, `<Up>` …
  ## `<Right>`, `<Home>`, `<End>`, `<C-w>`, `<A-x>` — or the character at `i` itself; `i` is moved past what was read.
  ## A `<` that starts no key name is the character itself.
  result = Key()
  if s[i] != '<':
    let (cp, n) = runeAt(s, i)
    result.kind = kChar
    result.ch = cp
    i += n
    return
  let close = s.find('>', i + 1)
  if close < 0:
    result.kind = kChar
    result.ch = ord('<')
    inc i
    return
  var mods: set[Mod] = {}
  let parts = s[i + 1 ..< close].toLowerAscii.split('-')
  let name = parts[^1]
  for p in parts[0 ..< parts.high]:
    case p
    of "c", "ctrl", "control": mods.incl mCtrl
    of "a", "alt", "m", "meta", "option": mods.incl mAlt
    of "s", "shift": mods.incl mShift
    else: discard
  case name
  of "esc", "escape": result.kind = kEsc
  of "cr", "enter", "return": result.kind = kEnter
  of "tab": result.kind = kTab
  of "bs", "backspace": result.kind = kBackspace
  of "del", "delete": result.kind = kDelete
  of "insert", "ins": result.kind = kInsert
  of "home": result.kind = kHome
  of "end": result.kind = kEnd
  of "up": result.kind = kUp
  of "down": result.kind = kDown
  of "left": result.kind = kLeft
  of "right": result.kind = kRight
  of "pageup", "pgup": result.kind = kPgUp
  of "pagedown", "pgdn", "pagedn": result.kind = kPgDn
  of "space": result.kind = kChar; result.ch = ord(' ')
  of "lt": result.kind = kChar; result.ch = ord('<')
  of "bar": result.kind = kChar; result.ch = ord('|')
  of "bslash": result.kind = kChar; result.ch = ord('\\')
  else:
    if name.len == 1:
      result.kind = kChar
      result.ch = ord(name[0])
    elif name.len > 1 and name[0] == 'f' and name[1 .. ^1].allCharsInSet(Digits):
      result.kind = kFn
      result.fn = parseInt(name[1 .. ^1])
    else:
      # (no key by that name: the '<' was a character of its own)
      result.kind = kChar
      result.ch = ord('<')
      inc i
      return
  result.mods = mods
  i = close + 1

proc hlKeysOf(s: string): seq[Key] =
  ## every key of a case's keys string, in order
  var i = 0
  while i < s.len: result.add hlKeyOf(s, i)

proc hlModeName(): string =
  ## the mode as vim's visualmode() and ned's status bar name it: "" normal, "v" visual, "V" visual-line, "i" insert,
  ## "R" replace
  case vimMode
  of vmNormal: ""
  of vmVisual: "v"
  of vmVLine: "V"
  of vmInsert: "i"
  of vmReplace: "R"

proc hlReset(b: Buffer) =
  ## the file's lines again and the vim state empty, so that a case starts from the same place whatever the one before
  ## left — its mode, a pending count or operator, its register, what a `.` would repeat
  b.setContent(hlOrig)
  b.cursors = @[cur(Pos())]
  b.prim = 0
  b.topLine = 0
  b.topSub = 0
  b.leftCol = 0
  b.savedSeq = 0
  vimPending = ""
  vimCount = ""
  vimOpCount = ""
  vimRec.setLen(0)
  vimLastChange.setLen(0)
  vimIsChange = false
  vimReplaying = false
  vimUndoMark = -1
  vimReg = ""
  vimRegLine = false
  vimDesiredCol = -1
  vimPrevSel = (false, vmVisual, Pos(), Pos(), 0)
  vimSetMode(vmNormal)
  findQuery = ""
  findWord = false

proc hlFeed(keys: string) =
  ## the case's keys, one at a time, through the editor's own key path — except a `:` or a `/` / `?`, which the editor
  ## answers with a prompt: here the rest of the line is the command or the search itself, as typed in it
  let ks = hlKeysOf(keys)
  var n = 0
  while n < ks.len:
    let k = ks[n]
    inc n
    if not (cfgVim and k.kind == kChar and k.mods == {}):
      handleKey(k)
      continue
    if k.ch == ord(':') and vimMode in {vmNormal, vmVisual, vmVLine}:
      var cmd = if vimMode in {vmVisual, vmVLine}: "'<,'>" else: ""
      var done = false
      while n < ks.len:
        let k2 = ks[n]
        inc n
        if k2.kind == kEnter: done = true; break
        if k2.kind == kEsc: break
        if k2.kind == kChar and k2.ch < 128: cmd.add char(k2.ch)
      if vimMode in {vmVisual, vmVLine}: vimSetMode(vmNormal)
      if done or cmd.len > 0: vimEx(cmd)
      continue
    if k.ch in [ord('/'), ord('?')] and vimMode in {vmNormal, vmVisual, vmVLine}:
      var q = ""
      var done = false
      while n < ks.len:
        let k2 = ks[n]
        inc n
        if k2.kind == kEnter: done = true; break
        if k2.kind == kEsc: break
        if k2.kind == kChar and k2.ch < 128: q.add char(k2.ch)
      if vimMode in {vmVisual, vmVLine}: vimSetMode(vmNormal)
      if done and q.len > 0:
        findQuery = q
        findWord = false
        vimSearchBack = k.ch == ord('?')
        findStep(not vimSearchBack)
      continue
    handleKey(k)

proc hlCase(b: Buffer, keys: string, line, col: int): JsonNode =
  ## one case: the text and the cursor put back, the case's keys, and where they left the editor
  hlReset(b)
  b.setSingle(b.clampPos(Pos(line: max(0, line - 1), col: max(0, col - 1))))
  hlFeed(keys)
  let h = b.primary.head
  result = %*{
    "line": h.line + 1,
    "col": h.col + 1,
    "viscol": b.visColAt(h.line, h.col) + 1,
    "visual": hlModeName(),
    "text": %b.lines}

proc hlStartPos(start: string): (int, int) =
  ## the line and column `--start` names, both from 1 ("12:3", "12" or "" — 1,1)
  result = (1, 1)
  if start.len == 0: return
  let parts = start.split(':')
  if parts.len >= 1 and parts[0].strip.allCharsInSet(Digits): result[0] = max(1, parseInt(parts[0].strip))
  if parts.len >= 2 and parts[1].strip.allCharsInSet(Digits): result[1] = max(1, parseInt(parts[1].strip))

proc headlessMain(targets: seq[(string, int, int)], keys, start: string): int =
  ## `ned -es`: the editor with no terminal. One setup, then a case per request on stdin (or the one `--keys` names),
  ## each answered where vim mode left the cursor, the mode and the text. Its own settings and state, so that nothing
  ## of the caller's decides what a case answers
  if targets.len == 0:
    stderr.writeLine("ned -es needs a file — ned -es [--keys KEYS] [--start LINE:COL] FILE")
    return 2
  let path = absolutePath(targets[0][0]).normalizedPath
  if not fileExists(path):
    stderr.writeLine("ned -es: no such file: " & targets[0][0])
    return 1
  # (a folder of its own for settings and state: NED_ES_CONFIG/NED_ES_STATE bring one of the caller's)
  let home = getTempDir() / ("ned-es-" & $getCurrentProcessId())
  let ownHome = getEnv("NED_ES_CONFIG").len == 0 and getEnv("NED_ES_STATE").len == 0
  defer:
    if ownHome: removeDir(home)     # (nothing of it outlives the run)
  putEnv("XDG_CONFIG_HOME", getEnv("NED_ES_CONFIG", home / "config"))
  putEnv("XDG_STATE_HOME", getEnv("NED_ES_STATE", home / "state"))
  try:
    createDir(getEnv("XDG_CONFIG_HOME"))
    createDir(getEnv("XDG_STATE_HOME"))
  except OSError: discard
  initLangs()
  loadState()
  rootDir = parentDir(path)
  try: setCurrentDir(rootDir)
  except OSError: discard
  loadConfig()
  # vim mode, and none of what would take the keys a case types (a completion list, a hover popup, a linked tag)
  cfgKeymap = "vim"
  cfgVim = true
  cfgAutoComplete = false
  cfgFormatOnType = false
  cfgAutoHover = false
  cfgLinkedEditing = false
  cfgVimClipboard = false
  bufs = @[newBuffer()]
  bufs[0].welcome = false
  curBuf = 0
  focus = fEditor
  let b = bufs[0]
  try: hlOrig = readFile(path)
  except CatchableError as e:
    stderr.writeLine("ned -es: cannot read " & path & ": " & e.msg)
    return 1
  if not b.loadFile(path):
    stderr.writeLine("ned -es: cannot read " & path)
    return 1
  b.setContent(hlOrig)
  let (sl, sc) = hlStartPos(start)
  if keys.len > 0:
    stdout.writeLine($hlCase(b, keys, sl, sc))
    stdout.flushFile()
    return 0
  var line: string
  while stdin.readLine(line):
    let t = line.strip
    if t.len == 0: continue
    var req: JsonNode
    try:
      req = parseJson(t)
    except ValueError:
      stdout.writeLine($(%*{"error": "not JSON: " & t}))
      stdout.flushFile()
      continue
    if req.kind != JObject:
      stdout.writeLine($(%*{"error": "a request is a JSON object"}))
      stdout.flushFile()
      continue
    let q = req{"quit"}
    if q != nil and q.getBool(false): break
    let rl = req{"reload"}
    if rl != nil and rl.getBool(false):
      try: hlOrig = readFile(path)
      except CatchableError: discard
      b.setContent(hlOrig)
      stdout.writeLine($(%*{"ok": true}))
      stdout.flushFile()
      continue
    let k = req{"keys"}.getStr("")
    let ln = req{"line"}.getInt(sl)
    let cl = req{"col"}.getInt(sc)
    stdout.writeLine($hlCase(b, k, ln, cl))
    stdout.flushFile()
  return 0
