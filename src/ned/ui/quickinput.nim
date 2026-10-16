# ── quick input (prompts) and the find widget ──

proc promptHint(kind: PromptKind): string =
  case kind
  of pGoto: "Type a line number, line:column or +/- offset"
  of pSaveAs, pNewFile, pNewFolder, pRenamePath: "Tab completes paths · Enter to confirm · Esc to cancel"
  of pRunCmd: "Runs in the output panel · $file $dir $name are expanded"
  of pSearch: "Searches every file in the project"
  of pLspRename: "New name for the symbol everywhere it is used"
  of pGitCommit: "Commits the staged changes"
  else: "Enter to confirm · Esc to cancel · ↑↓ history"

proc drawQuickInput() =
  let w = min(scrW - 2, 72)
  let x = (scrW - w) div 2
  let y = max(0, lay.bodyTop)
  let h = 4
  drawFrame(x, y, w, h, theme.menuBg, theme.focusBorder, promptLabel)
  modalStart = regions.len
  region(x, y, w, h, proc() = discard)
  let iy = y + 1
  let fx = x + 2
  fillRect(fx, iy, w - 4, 1, theme.fg, theme.inputBg)
  let px = putStr(fx + 1, iy, "› ", theme.accent, theme.inputBg, {aBold})
  let fieldW = max(4, x + w - 3 - px)
  let curVis = strWidth(promptText[0 ..< promptCur])
  let off = max(0, curVis - fieldW + 1)
  let bi = colAtVis(promptText, off)
  discard putStr(px, iy, promptText[bi .. ^1], theme.fg, theme.inputBg, {}, px + fieldW)
  cursorX = px + curVis - visColOf(promptText, bi)
  cursorY = iy
  discard putStr(x + 2, y + 2, truncTo(promptHint(promptKind), w - 4), theme.dim, theme.menuBg, {aItalic})

proc drawFindWidget() =
  let isReplace = replaceActive
  let ex = lay.edX
  let ew = lay.edW
  let w = min(ew - 2, 58)
  let x = ex + ew - w - 1
  let y = lay.textY
  let bg = theme.menuBg
  fillRect(x, y, w, 1, theme.fg, bg)
  dropShadow(x, y, w, 1)
  if isReplace:
    var xx = putStr(x + 1, y, "Replace \"" & truncTo(replaceQuery, 14) & "\"?", theme.fg, bg, {aBold})
    xx += 1
    for (l, c) in [("Yes", 'y'), ("No", 'n'), ("All", 'a'), ("Done", 'q')]:
      let cc = c
      let lab = " " & l & " "
      capture cc:
        xx = button(xx, y, lab, proc() =
          var k = Key(kind: kChar, ch: ord(cc))
          replaceKey(k), "", (if cc == 'y': theme.badgeFg else: theme.fg), (if cc == 'y': theme.accent else: theme.btnBg)) + 1
    discard putStr(xx + 1, y, $replaceCount & " done", theme.dim, bg, {}, x + w)
    return
  let lbl = if promptKind == pReplaceFind: "Replace " elif promptKind == pReplaceWith: "With " else: ""
  var xx = putStr(x + 1, y, (if lbl.len > 0: lbl else: ic("search") & " "), theme.dim, bg)
  let rxErr = if findRegex and promptKind != pReplaceWith and promptText.len > 0:
                cachedRegex(promptText, findCase)[].err else: ""
  let infoS = if promptKind == pReplaceWith: (if findRegex: "$1 = group 1" else: "")
              elif rxErr.len > 0: truncTo(rxErr, 18)
              elif findQuery.len == 0 and promptText.len == 0: ""
              elif findTotal == 0 and not findCapped: "No results"
              else: (if findIdx > 0: $findIdx else: "?") & " of " & $findTotal & (if findCapped: "+" else: "")
  let btnW = if promptKind == pReplaceWith: 4 else: 20
  let fieldW = max(6, x + w - xx - btnW - strWidth(infoS) - 2)
  fillRect(xx, y, fieldW, 1, theme.fg, theme.inputBg)
  let curVis = strWidth(promptText[0 ..< promptCur])
  let off = max(0, curVis - fieldW + 1)
  let bi = colAtVis(promptText, off)
  discard putStr(xx, y, promptText[bi .. ^1], theme.fg, theme.inputBg, {}, xx + fieldW)
  cursorX = xx + curVis - visColOf(promptText, bi)
  cursorY = y
  xx += fieldW + 1
  if infoS.len > 0:
    xx = putStr(xx, y, infoS, (if findTotal == 0 or rxErr.len > 0: theme.err else: theme.dim), bg) + 1
  if promptKind != pReplaceWith:
    xx = button(xx, y, "Aa", proc() =
      findCase = not findCase
      findIncremental(), "Match case (Alt+C)", (if findCase: theme.accent else: theme.dim), bg,
      (if findCase: {aBold, aUnder} else: {})) + 1
    xx = button(xx, y, "W", proc() =
      findWord = not findWord
      findIncremental(), "Whole word (Alt+W)", (if findWord: theme.accent else: theme.dim), bg,
      (if findWord: {aBold, aUnder} else: {})) + 1
    xx = button(xx, y, ".*", proc() =
      findRegex = not findRegex
      findIncremental(), "Regular expression (Alt+R)", (if findRegex: theme.accent else: theme.dim), bg,
      (if findRegex: {aBold, aUnder} else: {})) + 1
    xx = button(xx, y, "↑", proc() = findStep(false), "Previous (Shift+Enter)", theme.fg, bg) + 1
    xx = button(xx, y, "↓", proc() = findStep(true), "Next (Enter)", theme.fg, bg) + 1
  discard button(x + w - 2, y, ic("close"), proc() = closePrompt(), "Close (Esc)", theme.dim, bg)
