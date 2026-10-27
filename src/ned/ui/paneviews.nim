# ── (6.32) a terminal and the assistant in a pane of the editor, a tab among the files — beside the code rather
#    than under it or in a dock: View › Panes › Terminal in a pane / Assistant in a pane ──

var paneTermSeq = 0

proc paneTermIndex(id: int): int =
  for i, t in terms:
    if t.paneId == id: return i
  -1

proc paneViewBuf(title: string, kind, arg: int): Buffer =
  result = newBuffer()
  result.title = title
  result.readOnly = true
  result.paneView = kind
  result.paneArg = arg
  bufs.add result

proc paneShow(b: Buffer) =
  ## b in a pane of its own at the right (beside the code), with the focus
  if b.isNil: return
  if not buf().isWelcome() and splitPaneOf(activePane, false, b): discard
  else:
    let k = bufs.find(b)
    if k >= 0: curBuf = k
  needRender = true

proc cmdTerminalInPane() =
  ## a new terminal in a pane at the right — its own shell, not one of the panel's
  inc paneTermSeq
  let t = newTerm(max(20, lay.edW div 2), max(4, lay.textH), termCwd(), remoteShellCmd(), keep = false)
  t.paneId = paneTermSeq
  terms.add t
  let b = paneViewBuf("Terminal " & $paneTermSeq, 1, paneTermSeq)
  paneShow(b)
  focus = fEditor

proc cmdAssistantInPane() =
  ## the assistant in a pane at the right (its dock closed: one place for it)
  var b: Buffer
  for x in bufs:
    if x.paneView == 2: b = x
  if b.isNil: b = paneViewBuf("Assistant", 2, 0)
  rightOpen = false
  rightView = svAssistant
  paneShow(b)
  focus = fRight

proc cmdPanelInPane() =
  ## the bottom panel — problems, output, its terminals, the debugger — in a pane at the right instead
  var b: Buffer
  for x in bufs:
    if x.paneView == 3: b = x
  if b.isNil: b = paneViewBuf("Panel", 3, 0)
  panelOpen = false
  paneShow(b)
  focus = fPanel

proc paneTermEnd(id: int) =
  ## a terminal's tab closed: its shell ends
  let i = paneTermIndex(id)
  if i < 0: return
  let t = terms[i]
  if t.pid > 0 and not t.dead:
    discard kill(t.pid, SIGHUP)
    discard kill(-t.pid, SIGHUP)
  if t.fd >= 0: discard posix.close(t.fd)
  terms.delete(i)
  if curTerm > i: dec curTerm
  if termOther > i: dec termOther
  elif termOther == i: termOther = -1
  curTerm = clamp(curTerm, 0, max(0, terms.high))

proc paneTermKey(k: Key): bool =
  ## a key while a pane's terminal has the focus: to its shell (false: not one)
  let b = buf()
  if b.paneView != 1: return false
  let i = paneTermIndex(b.paneArg)
  if i < 0: return false
  termForPane = i
  try: terminalKey(k)
  finally: termForPane = -1
  true

proc paneFocusAct(bid: int): Action =
  (proc() =
    for i in 0 ..< panes.len:
      let id = if i == activePane: buf().id else: panes[i].bufId
      if id == bid:
        focusPane(i)
        break
    let b = bufById(bid)
    if b != nil and b.paneView == 2: focus = fRight
    elif b != nil and b.paneView == 3: focus = fPanel)

proc drawPaneView(b: Buffer, x0, y0, w, h: int, active: bool) =
  ## a pane that is not text: its terminal, or the assistant
  case b.paneView
  of 1:
    let i = paneTermIndex(b.paneArg)
    if i < 0:
      fillRect(x0, y0, w, h, theme.fg, theme.bg)
      discard putStr(x0 + 2, y0 + 1, "The terminal ended — close this tab (Ctrl+W)", theme.dim, theme.bg, {aItalic},
                     x0 + w)
      return
    termPaneCursor = active and focus == fEditor
    drawTermPane(i, x0, y0, w, h, active)
    termPaneCursor = false
    if terms[i].dead:
      let s = " the shell ended (exit " & $terms[i].code & ") — Ctrl+W closes the tab "
      discard putStr(x0 + max(0, w - strWidth(s) - 1), y0 + h - 1, s, theme.badgeFg, theme.accent, {}, x0 + w)
    region(x0, y0, w, h, paneFocusAct(b.id), "")      # (a tap: this pane, its keys to the shell)
  of 2:
    drawAssistant(x0, y0, w, h)
  of 3:
    drawBottomPanel(x0, y0, w, h)
    if panelOpen: panelOpen = false        # (its × asked it closed, or Alt+O: the pane is where it is)
  else: discard
