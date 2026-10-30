# the terminal panel: reading the shells' output, drawing one terminal or two side by side with their tabs, command
# marks and scrollback, and handling their keys, mouse, selection, commands menu and splitting.
proc hostRead(t: Term) =
  ## a kept terminal: what its host sent (see termhost)
  var tmp: array[65536, char]
  var got = 0
  var gone = false
  while got < 1_000_000:
    let n = posix.read(t.fd, addr tmp[0], tmp.len)
    if n > 0:
      let old = t.inBuf.len
      t.inBuf.setLen(old + n)
      copyMem(addr t.inBuf[old], addr tmp[0], n)
      got += n
    elif n == 0 or (n < 0 and errno notin [EAGAIN, EINTR]):
      gone = true
      t.code = -1
      break
    else: break
  var kind: char
  var pay: string
  var at = 0
  while hostTake(t.inBuf, at, kind, pay):
    case kind
    of 'd', 'p':
      t.feed(pay)
      t.gotOutput = true
      if kind == 'p': t.reply.setLen(0)        # (answers to what was asked before ned came back: not again)
    of 'x':
      t.code = try: parseInt(pay) except ValueError: -1
      gone = true
    else: discard
  if at > 0: t.inBuf = t.inBuf[at .. ^1]
  if gone:
    t.dead = true
    discard posix.close(t.fd)
    t.fd = -1
    t.inBuf = ""
    t.feed("\r\n\e[2m[process exited" & (if t.code >= 0: " with code " & $t.code else: "") &
           " — press Enter to start a new shell]\e[0m")

proc ptyRead(t: Term) =
  ## reads what a shell's pseudo-terminal has sent (up to about 1 MB at a time) into the terminal's screen; at the end
  ## of the stream it marks the terminal dead, closes it, collects the shell's exit code and writes the "process exited
  ## — press Enter to start a new shell" line
  var tmp: array[65536, char]
  var got = 0
  while got < 1_000_000:
    let n = posix.read(t.fd, addr tmp[0], tmp.len)
    if n > 0:
      var s = newString(n)
      copyMem(addr s[0], addr tmp[0], n)
      t.feed(s)
      got += n
      t.gotOutput = true
    elif n == 0 or (n < 0 and errno notin [EAGAIN, EINTR]):
      t.dead = true
      discard posix.close(t.fd)
      t.fd = -1
      t.termReap()
      t.feed("\r\n\e[2m[process exited" & (if t.code >= 0: " with code " & $t.code else: "") &
             " — press Enter to start a new shell]\e[0m")
      break
    else: break

proc termRead(t: Term) =
  ## takes in a terminal's output (a kept terminal's host messages, or its shell's bytes), then sends the answers the
  ## screen has queued for the program's queries, types in the text waiting for the shell's first output, flushes code
  ## queued for a REPL and asks for a redraw
  if t.hosted: t.hostRead()
  else: t.ptyRead()
  if t.reply.len > 0:
    t.termWrite(t.reply)
    t.reply.setLen(0)
  if t.pending.len > 0 and t.gotOutput:
    let p = t.pending
    t.pending = ""
    t.termWrite(p)
  if t.replQ.len > 0: t.replFlush()
  needRender = true

proc termFds(): seq[cint] =
  ## the descriptors of the terminals that are alive, for the main loop to wait on
  for t in terms:
    if not t.dead and t.fd >= 0: result.add t.fd

proc pumpTerms(ready: HashSet[cint]) =
  ## reads each terminal whose descriptor is ready; a terminal with REPL code queued that has had no prompt yet gets it
  ## flushed (after 5 s)
  for t in terms:
    if not t.dead and t.fd >= 0 and t.fd in ready: t.termRead()
    elif t.replQ.len > 0: t.replFlush()          # a REPL that printed no prompt yet: typed in after 5 s

proc curTermObj(): Term =
  ## the terminal in use: a pane's while keys go to a pane's terminal, else the current one of the panel's (a terminal
  ## in an editor pane is passed over); nil when there is none
  if termForPane >= 0 and termForPane < terms.len: return terms[termForPane]
  if terms.len == 0: return nil
  curTerm = clamp(curTerm, 0, terms.high)
  if terms[curTerm].paneId != 0:
    # (the panel's terminals only: one in a pane is its tab's)
    for i, t in terms:
      if t.paneId == 0:
        curTerm = i
        return t
    return nil
  terms[curTerm]

proc termCwd(): string =
  ## the folder a new terminal starts in: the current file's folder when the terminal's folder setting is "file", else
  ## the project's
  let b = buf()
  if cfgTermCwd == "file" and b.path.len > 0: parentDir(b.path) else: rootDir

proc remoteShellCmd(): string =
  ## a remote folder's terminal: a login shell on the server, in the folder
  let ri = if remotes.len > 0: remoteOf(rootDir) else: -1
  if ri < 0: return ""
  let r = remotes[ri]
  let cwd = remotePath(r, termCwd())
  sshCmd(r, false) & " -t " & quoteShell(remoteScript("cd " & quoteShell(cwd) & " && exec \"${SHELL:-sh}\" -l"))

proc openTerminal() =
  ## makes the panel's first terminal when the panel has none (a shell on the server in a remote folder); nothing
  ## otherwise
  var panel = 0
  for t in terms:
    if t.paneId == 0: inc panel
  if panel == 0:
    let rc = remoteShellCmd()
    terms.add newTerm(max(20, lay.edW), max(4, lay.panelH - 1), termCwd(), rc, keep = true)
    if rc.len > 0: terms[^1].name = remotes[remoteOf(rootDir)].host
    curTerm = terms.high

proc newTerminal() =
  ## adds a terminal — a shell on the server in a remote folder — makes it the current one, opens the panel on it and
  ## gives it the focus
  let rc = remoteShellCmd()
  terms.add newTerm(max(20, lay.edW), max(4, lay.panelH - 1), termCwd(), rc, keep = true)
  if rc.len > 0: terms[^1].name = remotes[remoteOf(rootDir)].host
  curTerm = terms.high
  setPanel(pkTerminal)
  focus = fPanel

proc killTerminals() =
  ## (at quit) every terminal's shell ended — but a kept one's (terminal.keepRunning) goes on, for the next ned
  for t in terms:
    if t.hosted:
      if t.fd >= 0:
        t.hostSend(if cfgTermKeep: 'q' else: 'k', "")
        discard posix.close(t.fd)
        t.fd = -1
      continue
    if t.pid > 0:
      discard kill(t.pid, SIGHUP)
      discard kill(-t.pid, SIGHUP)
    if t.fd >= 0: discard posix.close(t.fd)
  for t in terms:
    if t.pid > 0 and not t.hosted:
      var st: cint
      for _ in 0 ..< 20:
        if waitpid(t.pid, st, WNOHANG) != 0: break
        os.sleep(5)

proc termScroll(d: int) =
  ## moves the view `d` rows into the scrollback (negative: back towards the live screen), kept within the scrollback
  let t = curTermObj()
  if t == nil: return
  t.view = clamp(t.view + d, 0, t.sb.len)
  needRender = true

proc termRowAt(t: Term, vr: int): TRow =
  ## visible row `vr` taking the scrollback offset into account
  t.view = clamp(t.view, 0, t.sb.len)          # (the scrollback may have been cleared meanwhile)
  let abs = t.sb.len - t.view + vr
  if abs < 0: return @[]
  if abs < t.sb.len: t.sb[abs]
  elif t.scr.len == 0: @[]
  else: t.scr[clamp(abs - t.sb.len, 0, t.scr.high)]

proc inSel(t: Term, absRow, col: int): bool =
  ## true when the cell at that absolute row and column is inside the terminal's selection, whichever way it was dragged
  if not t.hasSel: return false
  var (a, b) = (t.selA, t.selB)
  if b < a: swap(a, b)
  if absRow < a[0] or absRow > b[0]: return false
  if absRow == a[0] and col < a[1]: return false
  if absRow == b[0] and col > b[1]: return false
  true

proc termCmdMenu(ti, ci: int)
proc termClick(x, y: int)

proc termLastRan(t: Term): int =
  ## the newest command that was run (-1: none)
  for i in countdown(t.cmds.high, 0):
    if t.cmds[i].ran: return i
  -1

proc termCmdStatus(c: TermCmd): (string, Rgb) =
  ## a command's mark: ran fine, failed (its code), still running
  let ascii = cfgIcons == "ascii" or cfgAccessible
  if not c.ran: return ("", theme.dim)
  if c.endRow < 0: return ((if ascii: "o" else: "○"), theme.dim)
  if c.code == 0: return ((if ascii: "+" else: "●"), blend(theme.gitAdd, theme.bg, 0.25))
  if c.code < 0: return ((if ascii: "?" else: "●"), theme.dim)
  ((if ascii: "x" else: "●"), theme.err)

proc termCmdChip(t: Term): (string, Rgb) =
  ## the last command's result, for the panel header: "✓ 1.2 s" · "✗ exit 2"
  let i = t.termLastRan
  if i < 0: return ("", theme.dim)
  let c = t.cmds[i]
  if c.endRow < 0: return ("… " & truncTo(c.text, 20), theme.dim)
  let secs = (c.ended - c.started).inMilliseconds.float / 1000
  let dur = if secs < 10: formatFloat(secs, ffDecimal, 1) & " s" else: $int(secs) & " s"
  if c.code == 0: (ic("ok") & " " & dur, theme.gitAdd)
  else: ("✗ exit " & $c.code & " · " & dur, theme.err)

proc drawTermPane(ti: int, x0, y0, w, h: int, focused: bool) =
  ## draws terminal `ti` into the rectangle: sizes the terminal to it; a two-column gutter with a mark for each command
  ## when the shell sends them (clicking a mark opens that command's menu); its rows with the selection and reverse
  ## video, the rows of the command being browsed tinted; a badge showing the command browsed or the scrollback
  ## position; the cursor when focused. A click on the text focuses the terminal and selects or goes to the program; a
  ## right-click opens Copy, Paste, the command items, Clear, New terminal, Split and Kill.
  let t = terms[ti]
  let bgDef = theme.bg
  # a gutter for the commands' marks once the shell sends them
  let gut = if t.integrated and w >= 30: 2 else: 0
  t.resize(w - 1 - gut, h)
  termPanes.add (ti, (x0 + gut, y0, w - gut, h), gut)
  if focused: termRect = (x0 + gut, y0, w - gut, h)
  # where each command starts on screen, and the one Ctrl+↑/↓ went to
  var marks: Table[int, int]
  for i, c in t.cmds: marks[c.promptRow] = i
  var navA, navE = -1
  if t.navCmd >= 0 and t.navCmd < t.cmds.len:
    navA = t.cmds[t.navCmd].promptRow
    navE = if t.cmds[t.navCmd].endRow >= 0: t.cmds[t.navCmd].endRow - 1 else: t.gRow
  let navBg = blend(bgDef, theme.accent, 0.10)
  for r in 0 ..< h:
    let row = t.termRowAt(r)
    let absRow = t.sb.len - t.view + r
    let g = absRow + t.sbDropped
    let inNav = g >= navA and g <= navE and navA >= 0
    if gut > 0:
      fillRect(x0, y0 + r, gut, 1, theme.fg, bgDef)
      if inNav: setCell(x0, y0 + r, Cell(ch: 0x258E, fg: theme.accent, bg: bgDef))
      if g in marks:
        let ci = marks[g]
        let (glyph, col) = termCmdStatus(t.cmds[ci])
        if glyph.len > 0: discard putStr(x0, y0 + r, glyph, col, (if inNav: navBg else: bgDef))
    var x = 0
    let xs = x0 + gut
    if inNav: fillRect(xs, y0 + r, w - gut - 1, 1, theme.fg, navBg)
    while x < min(row.len, w - gut - 1):
      let c = row[x]
      var fg = if c.fg == NoColor: theme.fg else: c.fg
      var bg = if c.bg == NoColor: (if inNav: navBg else: bgDef) else: c.bg
      if aRev in c.at: swap(fg, bg)
      if t.inSel(absRow, x): bg = theme.sel
      var at = c.at - {aRev}
      grid[(y0 + r) * scrW + xs + x] = Cell(ch: (if c.ch == 0: 0'u32 else: c.ch), fg: fg, bg: bg, at: at)
      inc x
  if gut > 0:
    # a click on a command's mark: its menu
    for r in 0 ..< h:
      let g = t.sb.len - t.view + r + t.sbDropped
      if g in marks:
        let ci = marks[g]
        let tix = ti
        if t.cmds[ci].ran:
          capture tix, ci:
            region(x0, y0 + r, gut, 1, proc() = termCmdMenu(tix, ci),
                   "$ " & truncTo(t.cmds[ci].text, 40) & " — copy its output, run it again …")
  if t.navCmd >= 0 and t.navCmd < t.cmds.len:
    let c = t.cmds[t.navCmd]
    var nth, ran = 0
    for i, cc in t.cmds:
      if cc.ran:
        inc ran
        if i <= t.navCmd: inc nth
    # on the bottom row: the command shown is at the top
    let tail = (if c.endRow >= 0 and c.code > 0: "  ✗ " & $c.code else: "") & "  · Alt+Enter: menu · Esc "
    let head = " " & $nth & "/" & $ran & "  $ "
    let room = max(6, w - 4 - strWidth(head) - strWidth(tail))
    let s = head & truncTo(c.text, room) & tail
    discard putStr(x0 + max(0, w - strWidth(s) - 2), y0 + h - 1, s, theme.badgeFg, theme.accent, {}, x0 + w)
  elif t.view > 0:
    let s = " scrollback " & $t.view & "/" & $t.sb.len & " · Shift+PgDn "
    discard putStr(x0 + max(0, w - strWidth(s) - 2), y0, s, theme.badgeFg, theme.accent, {}, x0 + w)
  if focused and (focus == fPanel or termPaneCursor) and t.cursorVisible and t.view == 0 and not t.dead:
    cursorX = x0 + gut + min(t.cx, w - gut - 2)
    cursorY = y0 + t.cy
  let tix = ti
  let paneRect = (x0 + gut, y0, w - gut, h)
  region(x0 + gut, y0, w - gut, h, proc() =
    # a click: this terminal gets the focus (in a split, the other one stays beside it), then selects or
    # goes to the program (mouse mode)
    focus = fPanel
    if tix != curTerm:
      if termSplit: termOther = curTerm
      curTerm = tix
    termRect = paneRect
    termClick(mouseX, mouseY), "", proc() =
    if termSplit and tix != curTerm: termOther = curTerm
    curTerm = tix
    termRect = paneRect
    let tt = curTermObj()
    var items = @[mi("Copy", "", proc() = termCopySel()), mi("Paste", "", proc() =
      let txt = clipGet()
      if tt != nil and txt.len > 0:
        if tt.bracketed: tt.termWrite("\e[200~" & txt & "\e[201~") else: tt.termWrite(txt.replace("\n", "\r")))]
    if tt != nil and tt.termLastRan >= 0:
      items.add msep()
      items.add mi("Commands…", "Ctrl+↑/↓", proc() = runCmd("Terminal: commands…"))
      items.add mi("Copy the last command's output", "", proc() = runCmd("Terminal: copy the last command's output"))
      items.add mi("Run the last command again", "", proc() = runCmd("Terminal: run the last command again"))
    items.add msep()
    items.add mi("Clear", "", proc() =
      if tt != nil:
        tt.sbDropped += tt.sb.len
        tt.sb.setLen(0)
        tt.view = 0
        tt.navCmd = -1
        tt.termWrite("\x0c"))
    items.add mi("New terminal", "", proc() = newTerminal())
    items.add mi((if termSplit: "Unsplit" else: "Split: two side by side"), "", proc() = runCmd("Terminal: split"))
    items.add mi("Kill terminal", "", proc() =
      if tt != nil and tt.pid > 0:
        if tt.hosted: tt.hostSend('k', "")
        else: discard kill(tt.pid, SIGHUP))
    openMenu(items, mouseX, mouseY + 1))

proc drawTerminal(x0, y0, w, h: int) =
  ## draws the terminal panel: starts the first terminal if there is none, makes sure a split is still valid, shows a
  ## row of tabs when there are several terminals (a failed last command marked ✗), then the current terminal or — split
  ## — two side by side with a divider
  openTerminal()
  termPanes.setLen(0)
  let bgDef = theme.bg
  fillRect(x0, y0, w, h, theme.fg, bgDef)
  discard curTermObj()                     # (curTerm: one of the panel's)
  var panelTerms = 0
  for tt in terms:
    if tt.paneId == 0: inc panelTerms
  if termSplit and (panelTerms < 2 or termOther < 0 or termOther >= terms.len or termOther == curTerm or
                    terms[termOther].paneId != 0):
    termSplit = false
  # tabs for several terminals
  var hh = h
  var yy0 = y0
  if panelTerms > 1 and h > 4:
    var x = x0 + 1
    for i, tt in terms:
      if tt.paneId != 0: continue            # (a pane's terminal: its tab is in the editor)
      let active = i == curTerm
      let shown = termSplit and i == termOther
      let ii = i
      let li = tt.termLastRan
      let failed = li >= 0 and tt.cmds[li].endRow >= 0 and tt.cmds[li].code > 0
      let lab = " " & $(i + 1) & ": " & (if failed: "✗ " else: "") &
                (if tt.title.len > 0: truncTo(tt.title, 18) else: tt.name) & " "
      capture ii:
        x = button(x, y0, lab,
                   proc() =
                     if termSplit and ii != curTerm and ii != termOther: termOther = curTerm
                     curTerm = ii, "", (if active: theme.fg elif failed: theme.err else: theme.dim),
                   (if active: blend(bgDef, theme.accent, 0.15) elif shown: blend(bgDef, theme.accent, 0.06) else: bgDef)) + 1
    inc yy0
    dec hh
  if termSplit:
    let a = min(curTerm, termOther)
    let b = max(curTerm, termOther)
    let lw = max(12, (w - 1) div 2)
    drawTermPane(a, x0, yy0, lw, hh, a == curTerm)
    for r in 0 ..< hh: setCell(x0 + lw, yy0 + r, Cell(ch: 0x2502, fg: theme.border, bg: bgDef))
    drawTermPane(b, x0 + lw + 1, yy0, w - lw - 1, hh, b == curTerm)
  else:
    drawTermPane(curTerm, x0, yy0, w, hh, true)

# true when two terminals are shown side by side
proc termSplitOn(): bool = termSplit

proc termHeaderChip(): (string, Rgb) =
  ## the last command's result and its colour for the panel's header; empty when there is no terminal
  let t = curTermObj()
  if t == nil: ("", theme.dim) else: t.termCmdChip()

proc termGoCmd(t: Term, ci: int) =
  ## show command `ci` at the top of the terminal (its rows are tinted until a key goes to the shell)
  if ci < 0 or ci >= t.cmds.len: return
  t.navCmd = ci
  let a = t.cmds[ci].promptRow - t.sbDropped
  t.view = if a < t.sb.len: clamp(t.sb.len - max(0, a), 0, t.sb.len) else: 0
  needRender = true

proc termNav(t: Term, d: int) =
  ## Ctrl+↑/↓: the command before / after (the newest prompt and below: back to live)
  var ran: seq[int]
  for i, c in t.cmds:
    if c.ran and c.promptRow >= t.sbDropped: ran.add i
  if ran.len == 0:
    info("No commands yet" & (if t.integrated: "" else: " — this shell sends no command marks (terminal.shellIntegration: bash, zsh, fish)"))
    return
  var k = ran.find(t.navCmd)
  if k < 0: k = (if d < 0: ran.len else: -1)
  k += d
  if k < 0: k = 0
  if k >= ran.len:
    t.navCmd = -1
    t.view = 0
    needRender = true
    return
  t.termGoCmd(ran[k])

proc termCmdOutput(t: Term, ci: int): string =
  ## the text a command printed, from its first output row to where it ended (or the cursor, if it still runs), without
  ## trailing empty lines
  let c = t.cmds[ci]
  if c.outRow < 0: return ""
  let e = if c.endRow >= 0: c.endRow - 1 else: t.gRow - 1
  var lines: seq[string]
  for r in max(c.outRow, t.sbDropped) .. e: lines.add rowText(t.rowByGlobal(r))
  while lines.len > 0 and lines[^1].len == 0: lines.setLen(lines.len - 1)
  lines.join("\n")

proc termRunText(t: Term, cmd: string) =
  ## type a command into the shell and run it (only at a prompt)
  if cmd.strip.len == 0: return
  if t.cmds.len > 0 and t.cmds[^1].ran and t.cmds[^1].endRow < 0:
    warn("A command is still running in this terminal")
    return
  t.navCmd = -1
  t.view = 0
  t.termWrite(cmd.replace("\n", "\r") & "\r")
  setPanel(pkTerminal)
  focus = fPanel

proc termCmdMenu(ti, ci: int) =
  ## the menu of one command of a terminal: copy its output, copy the command, run it again, open its output in a tab,
  ## or go to it in the terminal
  if ti < 0 or ti >= terms.len: return
  let t = terms[ti]
  if ci < 0 or ci >= t.cmds.len: return
  let c = t.cmds[ci]
  let outp = t.termCmdOutput(ci)
  let n = if outp.len == 0: 0 else: outp.count('\n') + 1
  let tt = t
  let cmd = c.text
  openActions("$ " & truncTo(c.text, 50) & (if c.endRow < 0: "  (running)" elif c.code == 0: "  " & ic("ok")
                                             else: "  ✗ exit " & $c.code), @[
    act("Copy its output", $n & " line(s)", proc() =
      clipSet(outp)
      info("Copied the output (" & $n & " lines)")),
    act("Copy the command", truncTo(cmd, 40), proc() =
      clipSet(cmd)
      info("Copied: " & truncTo(cmd, 60))),
    act("Run it again", "", proc() = tt.termRunText(cmd)),
    act("Open its output in a tab", "to search it, save it …", proc() =
      discard openScratch("$ " & truncTo(cmd, 30), outp, langByName("Text"))),
    act("Go to it", "Ctrl+↑/↓ in the terminal", proc() =
      curTerm = ti
      tt.termGoCmd(ci)
      setPanel(pkTerminal)
      focus = fPanel)])

proc termCommands() =
  ## the commands of this terminal, newest first
  let t = curTermObj()
  if t == nil: return
  var items: seq[(string, string, Action)]
  for i in countdown(t.cmds.high, 0):
    let c = t.cmds[i]
    if not c.ran: continue
    let (glyph, _) = termCmdStatus(c)
    let ago = (getMonoTime() - c.started).inSeconds
    let when0 = if ago < 60: $ago & " s ago" elif ago < 3600: $(ago div 60) & " min ago" else: $(ago div 3600) & " h ago"
    let det = (if c.endRow < 0: "running" elif c.code > 0: "exit " & $c.code else: "") & "  " & when0
    let ci = i
    let ti = curTerm
    capture ti, ci:
      items.add act(glyph & " " & truncTo(c.text, 60), det, proc() = termCmdMenu(ti, ci))
  if items.len == 0:
    info(if t.integrated: "No commands in this terminal yet" else: "This shell sends no command marks — bash, zsh and fish do")
    return
  openActions("Terminal commands", items)

proc termSplitToggle() =
  ## turns the split on or off: on needs a second terminal (one is made when there is only one) to show beside the
  ## current one, and opens the panel on it
  if termSplit:
    termSplit = false
    info("One terminal")
    return
  if terms.len < 2:
    let prev = curTerm
    newTerminal()
    termOther = prev
  else:
    termOther = if curTerm == 0: 1 else: curTerm - 1
  termSplit = true
  setPanel(pkTerminal)
  focus = fPanel

proc termCycle(d: int) =
  ## Ctrl+PgUp/PgDn in a terminal: the other half of a split, or the next terminal
  if terms.len < 2: return
  if termSplit:
    swap(curTerm, termOther)
  else:
    for _ in 0 ..< terms.len:
      curTerm = (curTerm + d + terms.len) mod terms.len
      if terms[curTerm].paneId == 0: break
  needRender = true

proc termCopySel() =
  ## copies the terminal's selection to the clipboard (each row without trailing spaces) and says how many characters;
  ## nothing without a selection
  let t = curTermObj()
  if t == nil or not t.hasSel: return
  var (a, b) = (t.selA, t.selB)
  if b < a: swap(a, b)
  var lines: seq[string]
  for r in a[0] .. b[0]:
    let row = if r < t.sb.len: t.sb[r] elif r - t.sb.len < t.scr.len: t.scr[r - t.sb.len] else: @[]
    var s = ""
    let c0 = if r == a[0]: a[1] else: 0
    let c1 = if r == b[0]: b[1] else: row.high
    for x in max(0, c0) .. min(row.high, c1):
      if row[x].ch != 0: s.addUtf8(int(row[x].ch))
    lines.add s.strip(leading = false)
  let txt = lines.join("\n")
  if txt.len > 0:
    clipSet(txt)
    clipParts = @[txt]
    clipLineMode = false
    info("Copied " & $txt.len & " characters from the terminal")

proc mouseToTerm(t: Term, x, y: int, press: bool, btn: int) =
  ## passes a mouse press or release to the program in the terminal, as an SGR sequence or in the older form, with the
  ## position counted from 1 in the terminal's rectangle
  let (x0, y0, _, _) = termRect
  let cx = x - x0 + 1
  let cy = y - y0 + 1
  if t.sgrMouse:
    t.termWrite("\e[<" & $btn & ";" & $cx & ";" & $cy & (if press: "M" else: "m"))
  elif press:
    t.termWrite("\e[M" & char(32 + btn) & char(min(255, 32 + cx)) & char(min(255, 32 + cy)))

proc termClick(x, y: int) =
  ## a click in the terminal: when the program asked for the mouse and the view is live, sends it a press and a release;
  ## otherwise it starts a selection at that cell
  let t = curTermObj()
  if t == nil: return
  if t.mouseMode != 0 and t.view == 0:
    t.mouseToTerm(x, y, true, 0)
    t.mouseToTerm(x, y, false, 0)
    return
  let (x0, y0, _, _) = termRect
  let absRow = t.sb.len - t.view + (y - y0)
  t.selA = (absRow, x - x0)
  t.selB = t.selA
  t.hasSel = false
  termSelecting = true

proc termDragTo(x, y: int) =
  ## carries on a selection while the mouse is dragged: scrolls the view one row when the mouse is above or below the
  ## terminal and sets the end of the selection to the cell under it
  let t = curTermObj()
  if t == nil: return
  let (x0, y0, w, h) = termRect
  if y < y0: termScroll(1)
  elif y >= y0 + h: termScroll(-1)
  let absRow = t.sb.len - t.view + clamp(y - y0, 0, h - 1)
  t.selB = (absRow, clamp(x - x0, 0, w - 1))
  t.hasSel = true

proc keyBytes(t: Term, k: Key): string =
  ## the bytes a terminal program receives for a key: control letters, Alt as a leading ESC, arrows (the application
  ## form when the program asked, else with the modifiers as ESC [ 1 ; m), Home, End, Insert, Delete, PgUp, PgDn, F1 to
  ## F12 and Shift+Tab; a paste in bracketed form when the program asked for that
  let ctrl = mCtrl in k.mods
  let alt = mAlt in k.mods
  let shift = mShift in k.mods
  var m = 1
  if shift: m += 1
  if alt: m += 2
  if ctrl: m += 4
  proc arrow(c: char): string =
    ## the sequence for an arrow or Home/End key whose final letter is `c`: with a modifier ESC [ 1 ; m c, in
    ## application cursor mode ESC O c, else ESC [ c (m is 1 + shift, 2 for alt, 4 for ctrl)
    if m > 1: "\e[1;" & $m & $c
    elif t.appCursor: "\eO" & $c
    else: "\e[" & $c
  # the sequence for a key with a number code: ESC [ n ~, with the modifier ESC [ n ; m ~
  proc tilde(n: int): string = (if m > 1: "\e[" & $n & ";" & $m & "~" else: "\e[" & $n & "~")
  case k.kind
  of kChar:
    var s = ""
    if ctrl and k.ch < 128:
      let c = toLowerAscii(char(k.ch))
      case c
      of 'a'..'z': s = $char(ord(c) - ord('a') + 1)
      of ' ', '@', '2': s = "\0"
      of '[', '3': s = "\e"
      of '\\', '4': s = "\x1c"
      of ']', '5': s = "\x1d"
      of '^', '6': s = "\x1e"
      of '_', '/', '7': s = "\x1f"
      else: s.addUtf8(k.ch)
    else: s.addUtf8(k.ch)
    (if alt: "\e" else: "") & s
  of kEnter: (if alt: "\e\r" else: "\r")
  of kTab: (if shift: "\e[Z" else: "\t")
  of kBackspace: (if ctrl: "\x08" elif alt: "\e\x7f" else: "\x7f")
  of kEsc: "\e"
  of kUp: arrow('A')
  of kDown: arrow('B')
  of kRight: arrow('C')
  of kLeft: arrow('D')
  of kHome: arrow('H')
  of kEnd: arrow('F')
  of kInsert: tilde(2)
  of kDelete: tilde(3)
  of kPgUp: tilde(5)
  of kPgDn: tilde(6)
  of kFn:
    case k.fn
    of 1..4: (if m > 1: "\e[1;" & $m & $char(ord('P') + k.fn - 1) else: "\eO" & $char(ord('P') + k.fn - 1))
    of 5: tilde(15)
    of 6..10: tilde(17 + k.fn - 6)
    of 11, 12: tilde(23 + k.fn - 11)
    else: ""
  of kPaste:
    if t.bracketed: "\e[200~" & k.text & "\e[201~" else: k.text.replace("\n", "\r")
  else: ""

proc terminalKey(k: Key) =
  ## handles a key pressed while the terminal has the focus. Shift with PgUp, PgDn, Up or Down scrolls the scrollback;
  ## in a terminal whose shell has ended Enter starts a new one (a REPL tab starts its REPL again) and Esc returns to
  ## the editor; Ctrl+Shift+C copies the selection; Ctrl+Up/Down browse the commands, then Alt+Enter opens the menu of
  ## the one shown and Esc leaves; any other key goes to the shell, bringing the view back to live and dropping the
  ## selection
  let t = curTermObj()
  if t == nil: return
  if mShift in k.mods and k.kind in {kPgUp, kPgDn, kUp, kDown}:
    let d = case k.kind
      of kPgUp: t.h - 1
      of kPgDn: -(t.h - 1)
      of kUp: 1
      else: -1
    termScroll(d)
    return
  if t.dead:
    if k.kind == kEnter:
      let w = t.w
      let h = t.h
      if t.replCmd.len > 0:                  # a REPL tab starts its REPL again
        let nt = newTerm(w, h, rootDir, t.replCmd)
        nt.replLang = t.replLang
        nt.name = t.name
        terms[curTerm] = nt
      else: terms[curTerm] = newTerm(w, h, termCwd(), keep = true)
    elif k.kind == kEsc: focus = fEditor
    return
  if k.kind == kChar and mCtrl in k.mods and mShift in k.mods and k.ch in [ord('c'), ord('C')]:
    termCopySel()
    return
  # commands (shell integration): Ctrl+↑/↓ go from one to the next, Alt+Enter opens the one shown, Esc goes back
  if k.kind in {kUp, kDown} and k.mods == {mCtrl} and (t.integrated or t.cmds.len > 0) and not t.altActive:
    t.termNav(if k.kind == kUp: -1 else: 1)
    return
  if t.navCmd >= 0 and t.navCmd < t.cmds.len:
    if k.kind == kEnter and k.mods == {mAlt}:
      termCmdMenu(curTerm, t.navCmd)
      return
    if k.kind == kEsc and k.mods == {}:
      t.navCmd = -1
      t.view = 0
      return
  t.navCmd = -1
  t.view = 0
  t.hasSel = false
  t.termWrite(t.keyBytes(k))
