# ── status bar ──

proc vimModeName(): string
proc aiStatus(): string

proc handleKey(k: Key)

proc drawTouchBar() =
  ## big on-screen keys for touch: each sends the real key, so it works wherever the focus is
  let y = lay.touchY
  if y < 0: return
  fillRect(0, y, scrW, 1, theme.fg, theme.tabBarBg)
  var keys: seq[(string, Key, string)]        # label, key — or a palette command
  for spec in cfgTouchKeys:
    let n = spec.strip
    let ctl = proc(c: char): Key = Key(kind: kChar, ch: ord(c), mods: {mCtrl})
    case n.toLowerAscii
    of "esc": keys.add ("Esc", Key(kind: kEsc), "")
    of "tab": keys.add ("Tab", Key(kind: kTab), "")
    of "enter": keys.add ("⏎", Key(kind: kEnter), "")
    of "left": keys.add ("←", Key(kind: kLeft), "")
    of "right": keys.add ("→", Key(kind: kRight), "")
    of "up": keys.add ("↑", Key(kind: kUp), "")
    of "down": keys.add ("↓", Key(kind: kDown), "")
    of "home": keys.add ("Home", Key(kind: kHome), "")
    of "end": keys.add ("End", Key(kind: kEnd), "")
    of "pgup": keys.add ("PgUp", Key(kind: kPgUp), "")
    of "pgdn": keys.add ("PgDn", Key(kind: kPgDn), "")
    of "undo": keys.add ("↶", ctl('z'), "")
    of "redo": keys.add ("↷", ctl('y'), "")
    of "save": keys.add ("Save", ctl('s'), "")
    of "find": keys.add ("Find", ctl('f'), "")
    of "palette": keys.add ("≡", ctl('e'), "")
    of "copy": keys.add ("Copy", ctl('c'), "")
    of "cut": keys.add ("Cut", ctl('x'), "")
    of "paste": keys.add ("Paste", ctl('v'), "")
    else:
      let eqAt = n.find('=')
      let low = n.toLowerAscii
      if eqAt > 0: keys.add (n[0 ..< eqAt].strip, Key(kind: kNone), n[eqAt + 1 .. ^1].strip)
      elif low.len == 6 and low.startsWith("ctrl+") and low[5] in {'a'..'z'}: keys.add (n, ctl(low[5]), "")
      elif low.len == 5 and low.startsWith("alt+") and low[4] in {'a'..'z', '0'..'9'}:
        keys.add (n, Key(kind: kChar, ch: ord(low[4]), mods: {mAlt}), "")
      elif n.len > 0: keys.add (n, Key(kind: kNone), n)            # a palette command by its name
  if keys.len == 0: return
  var labW = 0
  for (l, _, _) in keys: labW += strWidth(l)
  # spread the keys over the whole row: wide targets for fingers
  let pad = max(1, (scrW - labW - keys.len) div (keys.len * 2))
  var x = max(0, (scrW - labW - pad * 2 * keys.len - (keys.len - 1)) div 2)
  for (l0, k, cmd0) in keys:
    let kk = k
    let cmd = cmd0
    let lab = spaces(pad) & l0 & spaces(pad)
    let w = strWidth(lab)
    if x + w > scrW: break
    capture kk, cmd:
      discard button(x, y, lab, proc() = (if cmd.len > 0: runCmd(cmd) else: handleKey(kk)), "", theme.fg, theme.btnBg)
    x += w + 1

proc drawStatusBar() =
  let y = lay.statusY
  if y < 0: return
  let bg = theme.statusBg
  fillRect(0, y, scrW, 1, theme.statusFg, bg)
  let b = buf()
  # ── left ──
  var x = 0
  let vm = vimModeName()
  if vm.len > 0:
    let vbg = case vm
      of "INSERT": theme.gitAdd
      of "VISUAL", "V-LINE", "V-BLOCK": theme.syn[tkKeyword]
      of "REPLACE": theme.err
      else: theme.accent
    x = putStr(x, y, " " & vm & " ", theme.badgeFg, vbg, {aBold})
  if macroRecording:
    x = button(x, y, " " & macroBadge() & " ", proc() = macroToggle(), "Recording a macro — click (or Alt+Shift+R) to stop",
               theme.badgeFg, theme.err, {aBold})
  let (ne, nw) = problemCounts()
  let pfg = if ne > 0: theme.err elif nw > 0: theme.warn else: theme.dim
  let ptxt = if ne + nw == 0: " " & ic("ok") & " 0 " else: " " & ic("error") & " " & $ne & "  " & ic("warn") & " " & $nw & " "
  x = button(x + 1, y, ptxt, proc() = setPanel(pkProblems), "Problems", pfg, bg)
  if activeRunConfig.len > 0 and scrW >= 70:
    x = button(x, y, " ▶ " & truncTo(activeRunConfig, 16) & " ", proc() = cmdRunConfigs(),
               "Alt+R runs this configuration — click to choose another", theme.syn[tkFunc], bg)
  if ciStatus.len > 0 and ciBranch == gitBranch and scrW >= 60:
    let cfg = if ciStatus == "✓": theme.gitAdd elif ciStatus == "✗": theme.err else: theme.warn
    x = button(x, y, " CI " & ciStatus & " ", proc() = ghRuns(), "GitHub Actions on " & gitBranch, cfg, bg)
  let urgent = todoUrgentCount()
  if urgent > 0:
    x = button(x, y, " " & ic("todo") & " " & $urgent & " ", proc() = showSide(svTodos),
               "FIXME and BUG comments in the project — open the TODOs dock", theme.err, bg)
  # language server / nimsuggest
  let srv = lspFor(b, false)
  var lsTxt = ""
  if srv != nil:
    lsTxt = if srv.status.len > 0: "○ " & truncTo(srv.status, 26) elif srv.ready: ic("ok") & " " & srv.name else: "○ " & srv.name
  if b.lspMore:
    # a linter's server next to it (lsp.alsoRun, lsp.linters): "pyright + ruff"
    var more = ""
    for s in servers:
      if s.secondary and not s.dead and s.langId == b.lang.id and b.id in s.docVer: more.add " + " & s.name
    if more.len > 0: lsTxt = (if lsTxt.len > 0: lsTxt & more else: ic("ok") & " " & more[3 .. ^1])
  elif nimEngineOn(b):
    let st = if nsUsable(b): nsStatus(b) else: ""
    lsTxt = ic("ok") & " Nim" & (if tcVer.len > 0 and scrW >= 100: " " & tcVerText(tcVer) else: "") &
            (if st.len == 0: "" elif st == "nimsuggest": " + nimsuggest" else: " · " & st)
  elif nsUsable(b):
    let st = nsStatus(b)
    lsTxt = if st.len == 0: "○ nimsuggest" elif st == "nimsuggest": ic("ok") & " nimsuggest" else: "○ " & st
  if lsTxt.len > 0 and scrW >= 60:
    let tip = if b.lang.mode == lmNim and nimToolchainLine().len > 0: "Language intelligence · " & nimToolchainLine()
              else: "Language intelligence"
    x = button(x, y, " " & lsTxt & " ", proc() = showSide(svProject), tip, theme.dim, bg)
  if b.lang.mode == lmNim and tcProblem.len > 0 and scrW >= 60:
    # (the Nim in use is not what the project's .nimble asks for)
    x = button(x, y, " " & (if cfgAccessible: "[!]" else: "⚠") & " Nim " & tcVerText(tcVer) & ": " & tcProblem & " ",
               proc() = cmdChooseProjectNim(), "Choose the Nim for this project", theme.warn, bg)
  if remotes.len > 0 and remoteOf(rootDir) >= 0 and scrW >= 60:
    let rh = remotes[remoteOf(rootDir)].host
    x = button(x, y, " " & (if remotePushing > 0: "⇡ " else: "⇅ ") & rh & " ", proc() = runCmd("Remote: SSH menu…"),
               "A remote folder: saves go to " & rh & ", the terminal and Run work there", theme.accent, bg)
  if cfgFolderTrust == "ask" and rootDir.len > 0 and trustKey(rootDir) in trustAsked and not codeTrusted(rootDir):
    # (something of this folder's was held back: why, and the way out)
    x = button(x, y, " " & (if cfgAccessible: "[!]" else: "⛉") & " Not trusted ",
               proc() = runCmd("Workspace: trust this folder"),
               "ned runs none of this folder's code until you trust it — click to trust it", theme.warn, bg)
  if b.libLocked and scrW >= 60:
    x = button(x, y, " Read-only ", proc() = runCmd("File: allow editing this file"),
               "Part of the Nim toolchain or an installed package — click to edit it anyway", theme.warn, bg)
  if b.largeOn:
    x = button(x, y, " Large file ", proc() = runCmd("Large file mode: on/off for this file"),
               "Large-file mode (" & b.largeWhy & ") — click to turn the code features back on", theme.warn, bg)
  if scrW >= 80:
    x = button(x, y, " " & ic("terminal") & " Terminal ", proc() = runCmd("Toggle terminal"), "Integrated terminal (Ctrl+\\)",
               theme.dim, bg)
  if runningJob() != nil:
    x = button(x, y, " " & ic("run") & " running ", proc() = setPanel(pkOutput), "Show output", theme.accent, bg)
  let msgX = x + 1
  # ── right ──
  var right: seq[(string, Rgb, Action, string)]
  let p = b.primary.head
  var pos = "Ln " & $(p.line + 1) & ", Col " & $(visColOf(b.lines[p.line], p.col) + 1)
  if b.cursors.len > 1: pos.add " (" & $b.cursors.len & " cursors)"
  elif b.primary.hasSel:
    let (a, e) = b.primary.range
    let n = if a.line == e.line: e.col - a.col else: e.line - a.line + (if e.col > 0: 1 else: 0)
    pos.add " (" & $n & (if a.line == e.line: " selected)" else: " lines)")
  right.add (pos, theme.statusFg, Action(proc() = openPrompt(pGoto, "Go to line[:col]")), "Go to line (Ctrl+G)")
  right.add ((if b.indent == "\t": "Tab Size: " & $b.tabOf else: "Spaces: " & $b.indent.len) &
             (if b.ecInfo.len > 0: " (EditorConfig)" else: ""), theme.dim,
             Action(proc() = openMenu(@[mc("Indent with 2 spaces"), mc("Indent with 4 spaces"), mc("Indent with tabs")],
                                      mouseX - 10, y - 4)), "Indentation")
  right.add ("UTF-8", theme.dim, nil, "Encoding")
  right.add ((if b.crlf: "CRLF" else: "LF"), theme.dim, Action(proc() = runCmd("Toggle line endings (LF/CRLF)")), "Line endings")
  right.add (b.lang.name, theme.dim, Action(proc() = cmdLanguages()), "Select language mode")
  if b.lang.mode == lmNim and b.path.len > 0:
    var nm: seq[string]
    if cfgNimCompiler == "nimony": nm.add "nimony"
    if cfgNimTarget != "c": nm.add cfgNimTarget
    if cfgNimMode != "debug": nm.add cfgNimMode
    if nm.len > 0: right.add (nm.join("·"), theme.accent, Action(proc() = openMenuBar(4)), "Build settings")
  let ais = aiStatus()
  right.add ((if ais.len > 0: ic("ai") & " " & ais else: ic("ai")), (if ais.len > 0: theme.accent else: theme.dim),
             Action(proc() = toggleAssistant()), "AI assistant (Alt+C)")
  # priority: keep position and AI, drop encoding/eol first
  let order = [0, 5, 4, 1, 3, 2, 6]
  var keep: seq[bool]
  for _ in right: keep.add true
  proc total(): int =
    for i, r in right:
      if keep[i]: result += strWidth(r[0]) + 2
  var showMsg = msg.len > 0 and msSince(msgTime) < 6000
  let minMsg = if showMsg: min(strWidth(msg), 30) + 2 else: 0
  for k in countdown(order.high, 0):
    let i = order[k]
    if i < right.len and msgX + minMsg + total() > scrW and i != 0: keep[i] = false
  var rx = scrW - total()
  for i, (t, fg, a, tip) in right:
    if not keep[i]: continue
    if a != nil: rx = button(rx, y, " " & t & " ", a, tip, fg, bg)
    else: rx = putStr(rx, y, " " & t & " ", fg, bg)
  if showMsg:
    let maxX = scrW - total() - 1
    if maxX - msgX >= 6:
      discard putStr(msgX, y, truncTo(msg, maxX - msgX), sevColor(if msgSev == 0: 3 else: msgSev), bg,
                     (if msgSev == 1: {aBold} else: {}), maxX)
