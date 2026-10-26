const Tips = [
  "Start a comment with TODO, FIXME, BUG, HACK or NOTE: it gets its colour, and View › TODOs lists and counts them",
  "Something missing? Help › Check setup (or ned --check) lists what ned found and how to install the rest",
  "Pipe into ned: git log | ned, or nim check app.nim 2>&1 | ned -",
  "Alt+M on a macro or template call shows its expansion",
  "Type `proc` and press Tab — snippets work for Nim, Python, C, Rust, JS, HTML",
  "Alt+E opens the Nim dock: nimble tasks, build modes, toolchain, Atlas, Nimony",
  "Ctrl+D selects the next occurrence — then just type to edit them all",
  "Alt+Q lists every reference to the symbol under the cursor",
  "Alt+C opens the AI assistant; in agent mode it can edit files and run commands after you approve",
  "Alt+Shift+C rewrites the selection with AI — Ctrl+Z undoes it",
  "Ctrl+\\ opens a real terminal inside ned (vim, htop, git … all work)",
  "F10 opens the menu bar; right click anywhere for a context menu",
  "Ctrl+P understands `:42` (line), `@name` (symbol), `#name` (project symbol) and `>cmd`",
  "The ARC/ORC view shows where Nim inserts =copy, =sink and =destroy",
  "Click ▶ in the gutter to run a single unittest `test` block",
  "Alt+- folds the block under the cursor; Alt+= unfolds it",
  "Palette › Toggle vim mode turns on Vim keys (:w, ciw, dd, . and friends)",
  "Every option lives in one commented settings file — palette › Settings",
  "Alt+U turns the mouse off so Termux's own text selection works",
]

proc recentList(n: int): seq[string] =
  for r in recentFiles:
    if result.len >= n: break
    if fileExists(r): result.add r

proc drawWelcome(x0, y0, w, h: int) =
  welcomeRegions.setLen(0)
  let logo = @[
    "                 _ ",
    " _ __   ___  __| |",
    "| '_ \\ / _ \\/ _` |",
    "| | | |  __/ (_| |",
    "|_| |_|\\___|\\__,_|"]
  let wide = w >= 74 and h >= 20
  let showLogo = h >= 24 and w >= 30
  let starts = @[
    ("n", "New file", "", Action(proc() =
      buf().welcome = false
      needRender = true)),
    ("o", "Open file…", "Ctrl+P", Action(proc() = cmdFindFile())),
    ("d", "Open folder…", "", Action(proc() = cmdOpenFolder())),
    ("g", "Clone from a link…", "", Action(proc() = gitCloneFromLink())),
    ("f", "Browse files", "Ctrl+B", Action(proc() = showSide(svFiles))),
    ("r", "Recent projects…", "", Action(proc() = runCmd("File: open recent project…"))),
    ("j", "New Nim project…", "", Action(proc() = cmdNewNimProject())),
    ("e", "Command palette", "Ctrl+E", Action(proc() = cmdPalette())),
    ("t", "Theme · " & cfgThemeName, "Alt+T", Action(proc() = cmdThemes())),
    ("s", "Settings", "", Action(proc() = openSettingsUi())),
    ("?", "Key bindings", "F1", Action(proc() =
      helpOpen = true
      helpScroll = 0))]
  let recents = recentList(if wide: min(9, h - 12) else: 5)
  # layout
  var lines = 0
  if showLogo: lines += logo.len + 1
  lines += 3
  let colH = if wide: max(starts.len, recents.len) + 1 else: starts.len + (if recents.len > 0: recents.len + 2 else: 0) + 1
  lines += colH + 3
  var y = y0 + max(0, (h - lines) div 2)
  let blockW = if wide: 72 else: min(w - 2, 44)
  let left = x0 + max(1, (w - blockW) div 2)
  if showLogo:
    let lx = x0 + max(0, (w - 20) div 2)
    let colors = [theme.syn[tkKeyword], theme.syn[tkFunc], theme.syn[tkType], theme.syn[tkString], theme.accent]
    for i, l in logo:
      discard putStr(lx, y, l, colors[i mod colors.len], theme.bg, {aBold}, x0 + w)
      inc y
    inc y
  let longTag = "ned " & Version & " · the desktop-class editor for Termux, made for Nim"
  let tag = if w >= strWidth(longTag) + 4: longTag else: "ned " & Version & " · made for Nim"
  discard putStr(x0 + max(0, (w - strWidth(tag)) div 2), y, truncTo(tag, w - 2), theme.dim, theme.bg, {}, x0 + w)
  y += 2
  proc row(x, yy: int, key, label, hint: string, a: Action, colW: int, rightAct: Action = nil) =
    var xx = putStr(x, yy, " " & key & " ", theme.bg, theme.accent, {aBold}, x0 + w)
    xx = putStr(xx + 1, yy, truncTo(label, colW - 6 - (if hint.len > 0: strWidth(hint) + 1 else: 0)), theme.fg,
                theme.bg, {}, x0 + w)
    if hint.len > 0: discard putStr(x + colW - strWidth(hint) - 1, yy, hint, theme.dim, theme.bg, {}, x0 + w)
    welcomeRegions.add (yy, x, x + colW, a)
    region(x, yy, colW, 1, a, "", rightAct)
  let colW = if wide: 34 else: blockW
  discard putStr(left, y, "START", theme.dim, theme.bg, {aBold})
  if wide: discard putStr(left + 38, y, "RECENT", theme.dim, theme.bg, {aBold})
  inc y
  let top = y
  for i, (k, l, hnt, a) in starts:
    row(left, y, k, l, hnt, a, colW)
    inc y
  if recents.len == 0 and wide:
    # (nothing opened yet: the column says how to fill it rather than staying blank)
    discard putStr(left + 38, top, "Nothing opened yet —", theme.dim, theme.bg, {aItalic}, x0 + w)
    discard putStr(left + 38, top + 1, "the files you open come here", theme.dim, theme.bg, {aItalic}, x0 + w)
  if recents.len > 0:
    var ry = if wide: top else: y + 1
    var rx = if wide: left + 38 else: left
    if not wide:
      discard putStr(left, ry, "RECENT", theme.dim, theme.bg, {aBold})
      inc ry
    for i, r in recents:
      let path = r
      var dir = relPath(parentDir(r))
      if dir == ".": dir = ""
      if dir.startsWith(getHomeDir()): dir = "~/" & dir[getHomeDir().len .. ^1]
      if dir.len > 14:
        let cut = dir.find('/', dir.len - 13)
        dir = "…" & (if cut >= 0: dir[cut .. ^1] else: dir[^13 .. ^1])
      let num = $(i + 1)
      let fname = extractFilename(r)
      capture path:
        # (right-click: open it beside, copy its path, take it off the list)
        row(rx, ry, num, fname, dir, Action(proc() = discard openFile(path)), colW, Action(proc() =
          ctxOpen(@[mi("Open", "", proc() = discard openFile(path)),
                    mi("Open to the side", "", proc() = discard openToSide(path)),
                    ctxCopy("Copy the path", path),
                    mi("Remove from the recent files", "", proc() =
                      let k = recentFiles.find(path)
                      if k >= 0: recentFiles.delete(k)
                      needRender = true)])))
      inc ry
    if not wide: y = ry
  y = max(y, top + (if wide: max(starts.len, recents.len) else: 0)) + 1
  # toolchain status
  var tx = left
  for t in ["nim", "nimble", "nimsuggest", "nimlangserver", "git", "rg", "curl", "gdb"]:
    let ok = haveExe(t)
    let v = toolVersions.getOrDefault(t)
    let label = (if ok: "✓ " else: "✗ ") & t & (if ok and v.len > 0: " " & v else: "")
    if tx + strWidth(label) + 2 > x0 + w:
      inc y
      tx = left
    tx = putStr(tx, y, label, (if ok: theme.gitAdd else: theme.dim), theme.bg, {}, x0 + w) + 2
  y += 2
  let tip = "tip: " & Tips[(getTime().toUnix div 3600) mod Tips.len]
  var tipLines = @[tip]
  if strWidth(tip) > w - 2:
    # wrap once at a space so phones see the whole tip
    var cut = -1
    for i in countdown(min(tip.high, w - 3), 1):
      if tip[i] == ' ':
        cut = i
        break
    if cut > 0: tipLines = @[tip[0 ..< cut], tip[cut + 1 .. ^1]]
  for tl in tipLines:
    if y >= y0 + h: break
    discard putStr(x0 + max(1, (w - strWidth(tl)) div 2), y, truncTo(tl, w - 2), theme.syn[tkComment], theme.bg,
                   {aItalic}, x0 + w)
    inc y

proc welcomeKey(k: Key): bool =
  ## single-key actions on the welcome page; false lets the key fall through to the editor
  let b = buf()
  if k.kind == kEnter:
    b.welcome = false
    return true
  if k.kind != kChar or k.mods != {}: return false
  let c = char(min(k.ch, 127))
  case c
  of 'n': b.welcome = false
  of 'o', 'p': cmdFindFile()
  of 'f': showSide(svFiles)
  of 'd': cmdOpenFolder()
  of 'g': gitCloneFromLink()
  of 'r': runCmd("File: open recent project…")
  of 'j': cmdNewNimProject()
  of 'e': cmdPalette()
  of 't': cmdThemes()
  of 's': openSettingsUi()
  of 'a': toggleAssistant()
  of '?', 'h':
    helpOpen = true
    helpScroll = 0
  of 'q': requestQuit()
  of '1'..'9':
    let r = recentList(9)
    let i = ord(c) - ord('1')
    if i < r.len: discard openFile(r[i])
  else:
    b.welcome = false
    return false
  needRender = true
  true

proc stickyLines(b: Buffer, top, maxN: int): seq[int] =
  ## lines of the blocks enclosing `top` (found by indentation), outermost first — a CSV table's first row
  if top <= 0 or maxN <= 0 or top >= b.lines.len: return
  if b.lang.mode == lmCsv: return (if cfgCsvAlign: @[0] else: @[])
  var l = top
  while l < b.lines.len and isBlank(b.lines[l]): inc l
  if l >= b.lines.len: return
  var ind = visColOf(b.lines[l], leadingWs(b.lines[l]).len)
  var k = top - 1
  let lc = b.lang.lineComment
  while k >= 0 and ind > 0 and top - k < 3000:
    let s = b.lines[k]
    if not isBlank(s):
      let lw = leadingWs(s).len
      let i2 = visColOf(s, lw)
      if i2 < ind:
        let t = s[lw .. ^1]
        if not (lc.len > 0 and t.startsWith(lc)) and t[0] notin {'}', ')', ']'}:
          result.insert(k, 0)
          ind = i2
    dec k
  if result.len > maxN: result = result[result.len - maxN .. ^1]
