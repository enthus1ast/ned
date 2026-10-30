# ════════════════════════════════════════════════════════════════════════════
#  Layout: title bar · docks · tabs · breadcrumbs · editor · bottom panel · status
# ════════════════════════════════════════════════════════════════════════════

type Layout = object
  titleY, statusY, bodyTop, bodyBot: int
  leftW, rightX, rightW: int
  rightFloat, overlay: bool
  edX, edW: int
  tabY, crumbY: int
  textY, textH: int
  panelY, panelH: int
  touchY: int             # the touch keys row (-1: none)

var
  lay: Layout
  panelMax = false

proc computeLayout() =
  ## works out where every part of the screen goes for this frame from the screen size, the settings and what is open,
  ## and stores it in `lay`: the title and status bars (hidden in zen mode or on a tiny screen), the touch keys row, the
  ## left and right docks (full-width overlays below 70 columns, a floating right dock when there is no room beside the
  ## editor), the editor column, the bottom panel's height, and the tab bar, breadcrumbs and text area down the editor
  ## column
  var L: Layout
  L.overlay = scrW < 70
  L.titleY = if cfgTitleBar and scrH >= 14 and not zenMode: 0 else: -1
  L.statusY = if (cfgStatusBar or scrH < 8) and not zenMode: scrH - 1 else: -1
  L.bodyTop = L.titleY + 1
  L.bodyBot = if L.statusY >= 0: L.statusY else: scrH
  L.touchY = -1
  if (cfgTouchBar == "on" or (cfgTouchBar == "auto" and L.overlay)) and not zenMode and scrH >= 12:
    L.touchY = L.bodyBot - 1
    dec L.bodyBot
  let bodyH = L.bodyBot - L.bodyTop
  if L.overlay:
    if treeOpen and focus != fTree: treeOpen = false
    if rightOpen and focus != fRight: rightOpen = false
  if treeOpen:
    L.leftW = if L.overlay: scrW elif cfgLeftW > 0: clamp(cfgLeftW, 16, scrW - 30) else: clamp(scrW * 2 div 9, 24, 40)
  if rightOpen and not (L.overlay and treeOpen):
    if L.overlay: L.rightW = scrW
    else:
      L.rightW = if cfgRightW > 0: clamp(cfgRightW, 24, scrW - 30) else: clamp(scrW * 3 div 10, 34, 64)
      let room = scrW - L.leftW - (if L.leftW > 0: 1 else: 0) - 1 - 40
      if L.rightW > room:
        if room >= 28: L.rightW = room
        else:
          L.rightFloat = true
          L.rightW = min(L.rightW, scrW - 4)
  L.rightX = scrW - L.rightW
  L.edX = if L.leftW > 0 and not L.overlay: L.leftW + 1 else: 0
  let edRight = if L.rightW > 0 and not L.rightFloat and not L.overlay: L.rightX - 1 else: scrW
  L.edW = max(1, edRight - L.edX)
  if panelOpen and bodyH >= 8:
    L.panelH = if panelMax: bodyH - 2
               elif cfgPanelH > 0: clamp(cfgPanelH, 4, bodyH - 4)
               else: clamp(bodyH div 3, 6, 18)
    L.panelH = min(L.panelH, bodyH - 3)
  L.panelY = L.bodyBot - L.panelH
  var y = L.bodyTop
  L.tabY = -1
  L.crumbY = -1
  if cfgTabBar and bodyH - L.panelH >= 6 and not zenMode:
    L.tabY = y
    inc y
  if cfgBreadcrumbs and bodyH - L.panelH >= 12 and not zenMode:
    L.crumbY = y
    inc y
  L.textY = y
  L.textH = max(1, L.panelY - y)
  lay = L
