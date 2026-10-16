proc termRead(t: Term) =
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
  for t in terms:
    if not t.dead and t.fd >= 0: result.add t.fd

proc pumpTerms(ready: HashSet[cint]) =
  for t in terms:
    if not t.dead and t.fd >= 0 and t.fd in ready: t.termRead()
    elif t.replQ.len > 0: t.replFlush()          # a REPL that printed no prompt yet: typed in after 5 s

proc curTermObj(): Term =
  if terms.len == 0: return nil
  curTerm = clamp(curTerm, 0, terms.high)
  terms[curTerm]

proc termCwd(): string =
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
  if terms.len == 0:
    let rc = remoteShellCmd()
    terms.add newTerm(max(20, lay.edW), max(4, lay.panelH - 1), termCwd(), rc)
    if rc.len > 0: terms[^1].name = remotes[remoteOf(rootDir)].host
    curTerm = 0

proc newTerminal() =
  let rc = remoteShellCmd()
  terms.add newTerm(max(20, lay.edW), max(4, lay.panelH - 1), termCwd(), rc)
  if rc.len > 0: terms[^1].name = remotes[remoteOf(rootDir)].host
  curTerm = terms.high
  setPanel(pkTerminal)
  focus = fPanel

proc killTerminals() =
  for t in terms:
    if t.pid > 0:
      discard kill(t.pid, SIGHUP)
      discard kill(-t.pid, SIGHUP)
    if t.fd >= 0: discard posix.close(t.fd)
  for t in terms:
    if t.pid > 0:
      var st: cint
      for _ in 0 ..< 20:
        if waitpid(t.pid, st, WNOHANG) != 0: break
        os.sleep(5)

proc termScroll(d: int) =
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
  if focused and focus == fPanel and t.cursorVisible and t.view == 0 and not t.dead:
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
      if tt != nil and tt.pid > 0: discard kill(tt.pid, SIGHUP))
    openMenu(items, mouseX, mouseY + 1))

proc drawTerminal(x0, y0, w, h: int) =
  openTerminal()
  termPanes.setLen(0)
  let bgDef = theme.bg
  fillRect(x0, y0, w, h, theme.fg, bgDef)
  if termSplit and (terms.len < 2 or termOther < 0 or termOther >= terms.len or termOther == curTerm):
    termSplit = false
  # tabs for several terminals
  var hh = h
  var yy0 = y0
  if terms.len > 1 and h > 4:
    var x = x0 + 1
    for i, tt in terms:
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

proc termSplitOn(): bool = termSplit

proc termHeaderChip(): (string, Rgb) =
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
    curTerm = (curTerm + d + terms.len) mod terms.len
  needRender = true

proc termCopySel() =
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
  let (x0, y0, _, _) = termRect
  let cx = x - x0 + 1
  let cy = y - y0 + 1
  if t.sgrMouse:
    t.termWrite("\e[<" & $btn & ";" & $cx & ";" & $cy & (if press: "M" else: "m"))
  elif press:
    t.termWrite("\e[M" & char(32 + btn) & char(min(255, 32 + cx)) & char(min(255, 32 + cy)))

proc termClick(x, y: int) =
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
  let t = curTermObj()
  if t == nil: return
  let (x0, y0, w, h) = termRect
  if y < y0: termScroll(1)
  elif y >= y0 + h: termScroll(-1)
  let absRow = t.sb.len - t.view + clamp(y - y0, 0, h - 1)
  t.selB = (absRow, clamp(x - x0, 0, w - 1))
  t.hasSel = true

proc keyBytes(t: Term, k: Key): string =
  let ctrl = mCtrl in k.mods
  let alt = mAlt in k.mods
  let shift = mShift in k.mods
  var m = 1
  if shift: m += 1
  if alt: m += 2
  if ctrl: m += 4
  proc arrow(c: char): string =
    if m > 1: "\e[1;" & $m & $c
    elif t.appCursor: "\eO" & $c
    else: "\e[" & $c
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
      else: terms[curTerm] = newTerm(w, h, termCwd())
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
