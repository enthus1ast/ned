func wordCount(b: Buffer): int =
  if b.lines.len > 200_000: return -1
  for l in b.lines:
    var inWord = false
    for c in l:
      if c in {' ', '\t'}: inWord = false
      elif not inWord:
        inWord = true
        inc result

proc drawZenInfo(b: Buffer) =
  ## quiet corner info and messages while the status bar is hidden
  let y = scrH - 1
  var info = ""
  if cfgZenInfo and scrW >= 40:
    let p = b.primary.head
    info = "Ln " & $(p.line + 1) & "/" & $b.lines.len
    if b.lang.mode in {lmMarkdown, lmPlain}:
      let wc = b.wordCount()
      if wc >= 0: info.add " · " & $wc & " words"
    if b.dirty: info.add " · ●"
  # vim mode: the mode is always shown (you need to know whether keys type or command)
  let vm = vimModeName()
  let vmW = if vm.len > 0: strWidth(vm) + 3 else: 0
  let iw = (if info.len > 0: strWidth(info) + 3 else: 0) + vmW
  if vm.len > 0:
    let vx = scrW - iw + (if info.len > 0: 0 else: 1)
    let vfg = case vimMode
      of vmInsert: theme.gitAdd
      of vmVisual, vmVLine: theme.syn[tkKeyword]
      of vmReplace: theme.err
      else: theme.accent
    discard putStr(vx, y, " " & vm & " ", vfg, theme.bg, {aBold})
  if msg.len > 0 and msSince(msgTime) < 4000:
    let room = scrW - iw - 2
    let m = truncTo(msg, max(8, room))
    let mx = if strWidth(m) + 2 <= room and scrW >= 80: max(1, (scrW - strWidth(m)) div 2) else: 1
    discard putStr(mx, y, m, sevColor(if msgSev == 0: 3 else: msgSev), theme.bg, {aItalic}, scrW - iw)
  if info.len == 0: return
  let x = scrW - strWidth(info) - 2
  discard putStr(x, y, info, blend(theme.dim, theme.bg, 0.35), theme.bg)
  region(x, y, strWidth(info), 1, proc() = toggleZen(), "Leave zen mode (Alt+Z)")

proc toggleZen() =
  zenMode = not zenMode
  if zenMode:
    zenSaved = (treeOpen, rightOpen, panelOpen)
    treeOpen = false
    rightOpen = false
    panelOpen = false
    focus = fEditor
    info(if cfgVim: "Zen mode — Alt+Z or :zen to leave" else: "Zen mode — Alt+Z or Esc Esc to leave")
  else:
    (treeOpen, rightOpen, panelOpen) = zenSaved
    info("Zen mode off")
  for b in bufs: b.lastChange = -1
  needRender = true
