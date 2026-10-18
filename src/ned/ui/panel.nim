# ════════════════════════════════════════════════════════════════════════════
#  Bottom panel (problems · output · terminal · results), status bar, inputs, minimap
# ════════════════════════════════════════════════════════════════════════════

proc drawTerminal(x0, y0, w, h: int)
proc termSplitOn(): bool
proc termHeaderChip(): (string, Rgb)
proc terminalKey(k: Key)
proc openTerminal()

proc problemCounts(): (int, int) =
  ## errors and warnings from the compiler and language servers (Nim's follow-on errors not counted)
  var paths: HashSet[string]
  for p in diagsLsp.keys: paths.incl p
  for p in diagsBuild.keys: paths.incl p
  for p in diagsFfi.keys: paths.incl p
  for p in diagsEmit.keys: paths.incl p
  for p in paths:
    var ds = lspAndBuildDiags(p)
    if p.endsWith(".nim") or p.endsWith(".nims"): dropNimFollowOns(ds)
    for d in ds:
      if d.sev == 1: inc result[0] elif d.sev == 2: inc result[1]

proc rebuildProblems() =
  var lines: seq[PanelLine]
  var paths: seq[string]
  for p in diagsLsp.keys: paths.add p
  for p in diagsBuild.keys:
    if p notin paths: paths.add p
  for p in diagsAi.keys:
    if p notin paths: paths.add p
  for p in diagsFfi.keys:
    if p notin paths: paths.add p
  for p in diagsEmit.keys:
    if p notin paths: paths.add p
  paths.sort()
  var n = 0
  for p in paths:
    var ds = diagsFor(p)
    if ds.len == 0: continue
    ds.sort(proc(a, b: Diag): int = cmp(a.line * 100000 + a.col, b.line * 100000 + b.col))
    lines.add PanelLine(text: relPath(p) & "  " & $ds.len, sev: 5, line: -1, path: "")
    for d in ds:
      lines.add PanelLine(text: "  " & diagText(d, p) & fixHint(d) & (if d.src.len > 0: "  " & d.src else: "") &
        (if d.rule.len > 0: "(" & d.rule & ")" else: "") &
        "  [" & $(d.line + 1) & ":" & $(d.col + 1) & "]", path: p, line: d.line, col: d.col, sev: d.sev)
      inc n
  if n == 0: lines.add PanelLine(text: "  No problems have been detected in the workspace.", sev: 4, line: -1)
  panelStore[pkProblems] = lines

# ── every problem with the code around it, in one editable buffer (like Zed's project diagnostics) ──

proc cmdProblemsMultibuffer() =
  var hits: seq[(string, int)]
  var paths: seq[string]
  for p in diagsLsp.keys: paths.add p
  for p in diagsBuild.keys:
    if p notin paths: paths.add p
  for p in diagsAi.keys:
    if p notin paths: paths.add p
  for p in diagsFfi.keys:
    if p notin paths: paths.add p
  for p in diagsEmit.keys:
    if p notin paths: paths.add p
  paths.sort()
  for p in paths:
    if not fileExists(p): continue
    for d in diagsFor(p):
      if d.sev <= 2 and (p, d.line) notin hits: hits.add (p, d.line)
  if hits.len == 0:
    info("No errors or warnings")
    return
  openMultibuffer("Problems (" & $hits.len & ")", hits, 2)

proc setPanel(k: PanelKind) =
  panelKind = k
  panelOpen = true
  if k == pkProblems: rebuildProblems()
  if k == pkTerminal: openTerminal()
  needRender = true

proc drawBottomPanel(x0, y0, w, h: int) =
  let bg0 = theme.dockBg
  fillRect(x0, y0, w, h, theme.fg, bg0)
  # header bar with the panel tabs — tinted with the accent while the panel has the keyboard
  let hb = if focus == fPanel: blend(theme.tabBarBg, theme.accent, 0.14) else: theme.tabBarBg
  fillRect(x0, y0, w, 1, theme.dim, hb)
  var x = x0 + 1
  let (ne, nw) = problemCounts()
  var tabs = @[(pkProblems, "PROBLEMS" & (if ne + nw > 0: " " & $(ne + nw) else: "")), (pkOutput, "OUTPUT"),
               (pkTerminal, "TERMINAL")]
  if panelStore[pkSearch].len > 0: tabs.add (pkSearch, (if panelTitles[pkSearch].len > 0: panelTitles[pkSearch] else: "RESULTS"))
  if dbgOn or panelStore[pkDebug].len > 0: tabs.add (pkDebug, (if dbgOn: "● DEBUG" else: "DEBUG"))
  for (k, label) in tabs:
    let active = k == panelKind
    let fg = if active: theme.fg else: theme.dim
    let kk = k
    let x1 = x
    let lab = " " & truncTo(label, 34) & " "
    capture kk:
      x = button(x, y0, lab, proc() =
        setPanel(kk)
        focus = fPanel, "", fg, (if active: blend(hb, theme.accent, 0.12) else: hb), (if active: {aBold} else: {}))
    if active:
      for xx in x1 + 1 ..< x - 1: grid[y0 * scrW + xx].at.incl aUnder
    if x >= x0 + w - 14: break
  if panelKind == pkOutput and runningJob() != nil:
    x = putStr(x + 1, y0, "● running", theme.accent, hb, {}, x0 + w - 12)
  if panelKind == pkDebug:
    # the debugger's buttons
    for (lab0, tip0, cmd) in [("▶", "Continue (F5)", "-exec-continue"), ("↷", "Step over (F10)", "-exec-next"),
                              ("↓", "Step into (F11)", "-exec-step"), ("↑", "Step out (Shift+F11)", "-exec-finish")]:
      if x + 4 >= x0 + w - 14: break
      let c = cmd
      let lab = " " & lab0 & " "
      let tip = tip0
      capture c:
        x = button(x + 1, y0, lab, proc() = (if dbgOn: dbgSend(c) else: dbgStart()), tip, theme.fg, theme.btnBg)
    if dbgOn and x + 4 < x0 + w - 14:
      x = button(x + 1, y0, " ■ ", proc() = dbgEnd("stopped"), "Stop (Shift+F5)", theme.err, theme.btnBg)
  # right buttons
  var rx = x0 + w - 10
  if panelKind == pkOutput and runningJob() != nil:
    rx = button(rx - 3, y0, " " & ic("stop") & " ", proc() = stopRun(), "Stop (Ctrl+C)", theme.err, hb)
  elif panelKind == pkTerminal:
    rx = button(rx - 3, y0, " " & ic("plus") & " ", proc() = runCmd("Terminal: new"), "New terminal", theme.dim, hb)
    rx = button(rx - 7, y0, " " & (if termSplitOn(): "▭" else: "◫") & " ", proc() = runCmd("Terminal: split"),
                (if termSplitOn(): "One terminal" else: "Split: two terminals side by side"), theme.dim, hb) - 4
    if scrW >= 60:
      let (chip, col) = termHeaderChip()
      if chip.len > 0 and x + strWidth(chip) + 3 < rx - 6:
        x = button(x + 1, y0, " " & chip & " ", proc() = runCmd("Terminal: commands…"),
                   "The last command — click: the commands of this terminal", col, hb)
  else: rx = rx - 3 + 3
  rx = button(x0 + w - 7, y0, " " & (if panelMax: ic("min") else: ic("max")) & " ", proc() =
    panelMax = not panelMax, "Maximize panel", theme.dim, hb)
  discard button(x0 + w - 4, y0, " " & ic("close") & " ", proc() =
    panelOpen = false
    if focus == fPanel: focus = fEditor, "Close panel (Alt+O)", theme.dim, hb)
  let cy = y0 + 1
  let rows = h - 1
  if rows <= 0: return
  if panelKind == pkTerminal:
    drawTerminal(x0, cy, w, rows)
    return
  if panelKind == pkProblems: rebuildProblems()
  if panelFollow and panelKind == pkOutput: panelScroll = max(0, panelLines.len - rows)
  if focus == fPanel:
    if panelSel < panelScroll: panelScroll = panelSel
    if panelSel >= panelScroll + rows: panelScroll = panelSel - rows + 1
  panelScroll = clamp(panelScroll, 0, max(0, panelLines.len - rows))
  for r in 0 ..< rows:
    let i = panelScroll + r
    if i >= panelLines.len: break
    let pl = panelLines[i]
    let y = cy + r
    let sel = focus == fPanel and i == panelSel
    let isH = hov(x0, y, w) and pl.path.len > 0
    let bg = if sel: theme.menuSel elif isH: theme.hoverBg else: bg0
    fillRect(x0, y, w, 1, theme.fg, bg)
    let fg = case pl.sev
      of 1: theme.err
      of 2: theme.warn
      of 3: theme.info
      of 4: theme.gitAdd
      of 5: theme.fg
      else: theme.fg
    var xx = x0 + 1
    if panelKind == pkProblems and pl.sev in {1, 2, 3}:
      let (icn, icc) = sevIcon(pl.sev)
      xx = putStr(xx + 2, y, icn, icc, bg) + 1
      discard putStr(xx, y, pl.text.strip, theme.fg, bg, {}, x0 + w)
    elif panelKind == pkProblems and pl.sev == 5:
      xx = putStr(xx, y, ic("chevD") & " ", theme.dim, bg)
      xx = putStr(xx, y, fileIcon(panelLines[min(i + 1, panelLines.high)].path), langColor(panelLines[min(i + 1, panelLines.high)].path), bg)
      discard putStr(xx + 1, y, pl.text, theme.fg, bg, {aBold}, x0 + w)
    elif panelKind == pkSearch and pl.sev == 0 and pl.text.len > 7:
      let x1 = xx
      xx = putStr(xx, y, pl.text[0 ..< 7], theme.dim, bg)
      discard putStr(xx, y, pl.text[7 .. ^1], theme.fg, bg, {}, x0 + w)
      for (ms, ml) in pl.marks:
        # the uses on the line, as the editor marks a match
        if ms >= 7 and ms + ml <= pl.text.len:
          let mx = x1 + strWidth(pl.text[0 ..< ms])
          if mx < x0 + w: discard putStr(mx, y, pl.text[ms ..< ms + ml], theme.fg, theme.match, {aBold}, x0 + w)
    else:
      let at = if pl.sev == 5: {aBold} elif pl.path.len > 0 and pl.sev in {1, 2}: {aUnder} else: {}
      let lead = pl.text.len - pl.text.strip(trailing = false).len      # (an indent is not underlined with the link)
      if lead > 0: xx = putStr(xx, y, pl.text[0 ..< lead], fg, bg, {}, x0 + w)
      discard putStr(xx, y, pl.text[lead .. ^1], fg, bg, at, x0 + w)
    if pl.path.len > 0:
      let idx = i
      capture idx:
        region(x0, y, w, 1, proc() =
          focus = fPanel
          panelSel = idx
          panelFollow = false
          panelJump(idx))
