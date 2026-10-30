# ── quick input (prompts) and the find widget ──

func promptHint(kind: PromptKind): string =
  ## the hint line shown under a prompt's field for that kind of prompt
  case kind
  of pGoto: "Type a line number, line:column or +/- offset"
  of pSaveAs, pNewFile, pNewFolder, pRenamePath: "Tab completes paths · Enter to confirm · Esc to cancel"
  of pRunCmd: "Runs in the output panel · $file $dir $name are expanded"
  of pSearch: "Searches every file in the project"
  of pLspRename: "New name for the symbol everywhere it is used"
  of pGitCommit: "Commits the staged changes"
  else: "Enter to confirm · Esc to cancel · ↑↓ history"

proc drawQuickInput() =
  ## draws the prompt as a framed box at the top of the screen: its label as the title, a field for the text (hiding it
  ## for an API key), the hint for its kind and OK and Cancel buttons when there is room
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
  cursorX = drawField(px, iy, fieldW, promptText, promptCur, true,
                      secret = promptKind == pSetting and settingKey == "ai.apiKey")
  cursorY = iy
  var hintEnd = x + w - 2
  if cfgFormButtons and w >= 40:
    # OK and Cancel, as a dialog has them
    var bx = x + w - 2 - (strWidth("OK") + 4) - 1 - (strWidth("Cancel") + 4)
    hintEnd = bx - 1
    bx = pill(bx, y + 2, "Cancel", proc() = closePrompt(), "Esc", theme.fg, theme.btnBg) + 1
    discard pill(bx, y + 2, "OK", proc() = submitPrompt(), "Enter", theme.badgeFg, theme.accent, {aBold},
                 blend(theme.accent, theme.fg, 0.15))
  discard putStr(x + 2, y + 2, truncTo(promptHint(promptKind), hintEnd - x - 2), theme.dim, theme.menuBg, {aItalic},
                 hintEnd)

proc drawFindWidget() =
  ## draws the find bar at the top right of the editor: while replacing step by step, the question with Yes, No, All and
  ## Done buttons and the count; otherwise the query field with the result count (or the regex error), the case,
  ## whole-word and regex toggles, previous and next buttons and a close button
  let isReplace = replaceActive
  let ex = lay.edX
  let ew = lay.edW
  let w = min(ew - 2, 58)
  let x = ex + ew - w - 1
  let y = lay.textY
  let bg = theme.menuBg
  fillRect(x, y, w, 1, theme.fg, bg)
  dropShadow(x, y, w, 1)
  # (the bar itself: a click on it between its buttons is its own — not the text's, the minimap's under it)
  region(x, y, w, 1, proc() = discard)
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
  cursorX = drawField(xx, y, fieldW, promptText, promptCur, true)
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
