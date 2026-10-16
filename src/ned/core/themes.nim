# ════════════════════════════════════════════════════════════════════════════
#  Themes
# ════════════════════════════════════════════════════════════════════════════

proc blend(a, b: Rgb, t: float): Rgb =
  ## mix two colours; t = 0 → a, t = 1 → b
  proc ch(c: Rgb, sh: int): float = float((c shr sh) and 0xFF)
  var r: uint32 = 0
  for sh in [16, 8, 0]:
    let v = clamp(int(ch(a, sh) + (ch(b, sh) - ch(a, sh)) * t + 0.5), 0, 255)
    r = r or (uint32(v) shl sh)
  r

proc mkTheme(name: string, dark: bool, bg, fg, accent, sel, comment, keyword, typ, str, num, fn, op,
             macroC, prop, err, warn, ok: Rgb): Theme =
  let black: Rgb = 0x000000
  result.name = name
  result.dark = dark
  result.base = [bg, fg, accent, sel, comment, keyword, typ, str, num, fn, op, macroC, prop, err, warn, ok]
  result.bg = bg
  result.fg = fg
  result.dim = blend(bg, fg, 0.55)
  result.gutter = blend(bg, fg, 0.30)
  result.gutterCur = fg
  result.curLine = blend(bg, fg, (if dark: 0.055 else: 0.045))
  result.sel = sel
  result.match = blend(bg, accent, 0.32)
  result.matchCur = accent
  result.wordHl = blend(bg, fg, 0.13)
  result.bracket = blend(bg, accent, 0.28)
  result.statusBg = if dark: blend(bg, black, 0.30) else: blend(bg, black, 0.06)
  result.statusFg = fg
  result.tabBg = result.statusBg
  result.tabFg = result.dim
  result.tabActiveBg = bg
  result.tabActiveFg = fg
  result.popupBg = if dark: blend(bg, fg, 0.075) else: blend(bg, black, 0.035)
  result.popupSel = sel
  result.border = blend(bg, fg, 0.22)
  result.accent = accent
  result.panelBg = if dark: blend(bg, black, 0.18) else: blend(bg, black, 0.03)
  result.guide = blend(bg, fg, 0.12)
  result.cursorSec = accent
  result.err = err
  result.warn = warn
  result.info = accent
  result.hint = result.dim
  result.gitAdd = ok
  result.gitMod = warn
  result.gitDel = err
  result.stickyBg = blend(bg, fg, (if dark: 0.085 else: 0.06))
  result.inlay = blend(bg, fg, 0.42)
  result.rainbow = [typ, keyword, fn]
  # chrome: docks and title bar sit a shade away from the editor, like desktop editors
  result.titleBg = if dark: blend(bg, black, 0.32) else: blend(bg, black, 0.07)
  result.titleFg = blend(bg, fg, 0.80)
  result.dockBg = if dark: blend(bg, black, 0.20) else: blend(bg, black, 0.035)
  result.dockHeadBg = result.dockBg
  result.tabBarBg = result.dockBg
  result.statusBg = result.titleBg
  result.tabBg = result.tabBarBg
  result.panelBg = result.dockBg
  result.hoverBg = blend(result.dockBg, fg, (if dark: 0.08 else: 0.07))
  result.inputBg = if dark: blend(bg, black, 0.12) else: blend(bg, 0xFFFFFF'u32, 0.6)
  result.inputBorder = blend(bg, fg, 0.25)
  result.btnBg = blend(result.titleBg, fg, 0.10)
  result.btnFg = fg
  result.menuBg = if dark: blend(bg, fg, 0.06) else: blend(bg, 0xFFFFFF'u32, 0.7)
  result.menuSel = blend(bg, accent, (if dark: 0.30 else: 0.22))
  result.popupSel = result.menuSel
  result.popupBg = result.menuBg
  result.popupFg = fg
  result.popupSelFg = fg
  result.toastBg = if dark: blend(bg, fg, 0.10) else: blend(bg, black, 0.05)
  result.badgeBg = accent
  result.badgeFg = if dark: bg else: 0xFFFFFF'u32
  result.scrollThumb = blend(bg, fg, 0.22)
  result.focusBorder = accent
  result.codeBg = if dark: blend(bg, black, 0.25) else: blend(bg, black, 0.04)
  result.userBg = blend(result.dockBg, accent, 0.10)
  result.minimap = blend(bg, fg, 0.35)
  result.shadow = blend(bg, black, 0.45)
  result.crumbBg = blend(bg, accent, (if dark: 0.10 else: 0.09))      # tinted: never mistaken for code or sticky lines
  result.splitBar = if dark: blend(bg, black, 0.35) else: blend(bg, black, 0.10)
  # ANSI palette for the integrated terminal
  let blackA = if dark: blend(bg, black, 0.4) else: blend(fg, black, 0.3)
  let whiteA = if dark: blend(fg, bg, 0.15) else: blend(bg, black, 0.15)
  result.ansi = [blackA, err, ok, warn, fn, keyword, op, whiteA,
                 blend(blackA, fg, 0.45), blend(err, 0xFFFFFF'u32, 0.2), blend(ok, 0xFFFFFF'u32, 0.2),
                 blend(warn, 0xFFFFFF'u32, 0.2), blend(fn, 0xFFFFFF'u32, 0.2), blend(keyword, 0xFFFFFF'u32, 0.2),
                 blend(op, 0xFFFFFF'u32, 0.2), (if dark: fg else: blend(bg, black, 0.05))]
  if result.ansi[4] == result.ansi[5]: result.ansi[5] = typ
  for k in TokKind: result.syn[k] = fg
  result.syn[tkKeyword] = keyword
  result.syn[tkType] = typ
  result.syn[tkConst] = num
  result.syn[tkString] = str
  result.syn[tkChar] = str
  result.syn[tkEscape] = op
  result.syn[tkNumber] = num
  result.syn[tkComment] = comment
  result.syn[tkDoc] = blend(comment, str, 0.25)
  result.syn[tkPragma] = macroC
  result.syn[tkOperator] = op
  result.syn[tkFunc] = fn
  result.syn[tkPunct] = result.dim
  result.syn[tkPreproc] = macroC
  result.syn[tkProperty] = prop
  result.syn[tkVariable] = prop
  result.syn[tkParam] = blend(fg, prop, 0.6)   # (quieter than a field: there are many of them)
  result.syn[tkTag] = keyword
  result.syn[tkAttr] = typ
  result.syn[tkHeading] = fn
  result.syn[tkLink] = op
  result.syn[tkBold] = typ
  result.syn[tkCode] = str
  result.syn[tkAdded] = ok
  result.syn[tkRemoved] = err

proc chrome(t: Theme, title, dock, status: Rgb): Theme =
  ## exact chrome colours for themes that copy a desktop editor's look
  result = t
  result.chromeCols = [title, dock, status]
  result.hasChrome = true
  result.titleBg = title
  result.dockBg = dock
  result.dockHeadBg = dock
  result.tabBarBg = dock
  result.tabBg = dock
  result.panelBg = dock
  result.statusBg = status
  result.hoverBg = blend(dock, t.fg, (if t.dark: 0.08 else: 0.06))
  result.btnBg = blend(title, t.fg, 0.10)

proc slateTheme(name: string, bg, title, dock, curLine, popup: Rgb): Theme =
  ## muted xterm-256 colours on blue-grey slate: rose text, brick keywords, violet types, sage strings
  ## and punctuation, steel-blue identifiers, teal accents with a solid teal completion bar
  result = mkTheme(name, true, bg, 0xD7AFAF, 0x5FAFAF, 0x3E4452, 0x666666, 0xAF5F5F, 0x875FAF, 0x87AF87,
                   0xFF875F, 0xD7AFAF, 0xAF5F5F, 0x5FAFAF, 0x6E88A6, 0xD75F5F, 0xD7AF5F, 0x87AF87)
                   .chrome(title, dock, title)
  result.syn[tkText] = 0x6E88A6          # identifiers
  result.syn[tkPunct] = 0x87AF87         # brackets, commas, colons
  result.syn[tkDoc] = 0x7A7A7A
  result.syn[tkEscape] = 0x5FAFAF
  result.dim = 0x8A8A9A
  result.gutter = 0x404040
  result.gutterCur = 0x87AF87
  result.curLine = curLine
  result.guide = 0x3E3E42
  result.inlay = 0x5F6878
  result.popupBg = popup
  result.menuBg = popup
  result.popupFg = 0x607C81
  result.popupSel = 0x5FAFAF
  result.popupSelFg = bg
  result.menuSel = blend(popup, 0x5FAFAF, 0.35)
  result.border = blend(popup, 0xD7AFAF, 0.18)
  result.rainbow = [0x87AF87, 0x875FAF, 0x5FAFAF]
  result.crumbBg = blend(bg, popup, 0.55)
  result.splitBar = title

proc monoTheme(name: string, dark: bool): Theme =
  ## grey only: structure by lightness and weight — keywords bold and brightest, names bright, strings and
  ## numbers a step down, punctuation and comments quiet; selection and bars in neutral greys
  if dark:
    #                                 bg        fg        accent    sel       comment   keyword   type      string
    result = mkTheme(name, true,      0x161616, 0xD0D0D0, 0xFFFFFF, 0x3A3A3A, 0x737373, 0xFFFFFF, 0xE8E8E8, 0xA6A6A6,
                     0xBFBFBF, 0xF2F2F2, 0x8E8E8E, 0x9A9A9A, 0xC6C6C6, 0xF0F0F0, 0xB8B8B8, 0x9E9E9E)
                     #  number    func      operator  macro     property  error     warning   ok
                     .chrome(0x0F0F0F, 0x121212, 0x0F0F0F)
    result.curLine = 0x1F1F1F
    result.crumbBg = 0x222222
    result.splitBar = 0x0A0A0A
    result.rainbow = [0xE0E0E0'u32, 0xA8A8A8'u32, 0x7C7C7C'u32]
    result.menuSel = 0x404040
    result.popupBg = 0x232323
    result.menuBg = 0x232323
    result.popupSel = 0x404040
    result.guide = 0x262626
    result.inlay = 0x7A7A7A
  else:
    result = mkTheme(name, false,     0xFAFAFA, 0x262626, 0x000000, 0xDADADA, 0x8C8C8C, 0x000000, 0x1A1A1A, 0x5C5C5C,
                     0x404040, 0x0D0D0D, 0x707070, 0x5A5A5A, 0x333333, 0x000000, 0x4A4A4A, 0x6A6A6A)
                     .chrome(0xEFEFEF, 0xF2F2F2, 0xEFEFEF)
    result.curLine = 0xF0F0F0
    result.crumbBg = 0xEAEAEA
    result.splitBar = 0xE0E0E0
    result.rainbow = [0x1A1A1A'u32, 0x5C5C5C'u32, 0x8A8A8A'u32]
    result.menuSel = 0xDDDDDD
    result.popupBg = 0xFFFFFF
    result.menuBg = 0xFFFFFF
    result.popupSel = 0xDDDDDD
    result.guide = 0xE6E6E6
    result.badgeFg = 0xFFFFFF
    result.shadow = 0xD4D4D4
  result.boldKw = true
  result.syn[tkPunct] = result.syn[tkOperator]
  result.syn[tkDoc] = blend(result.syn[tkComment], result.fg, 0.25)
  result.matchCur = if dark: 0x5A5A5A else: 0xBDBDBD
  result.match = if dark: 0x333333 else: 0xE2E2E2
  result.bracket = if dark: 0x3C3C3C else: 0xD6D6D6

proc phosphorTheme(name: string, bg, fg, bright, dim, comment, err, warn: Rgb): Theme =
  ## an old terminal's one-colour screen: structure by brightness and weight — keywords bold and brightest, names
  ## bright, strings and numbers a step down, punctuation and comments dim; errors keep a colour of their own
  result = mkTheme(name, true, bg, fg, bright, blend(bg, fg, 0.20), comment, bright, blend(fg, bright, 0.55),
                   blend(fg, dim, 0.45), blend(fg, bright, 0.30), blend(fg, 0xFFFFFF, 0.45), dim,
                   blend(fg, bright, 0.75), blend(fg, dim, 0.20), err, warn, bright)
                   .chrome(blend(bg, 0x000000, 0.35), blend(bg, 0x000000, 0.20), blend(bg, 0x000000, 0.35))
  result.boldKw = true
  result.syn[tkPunct] = dim
  result.syn[tkDoc] = blend(comment, fg, 0.30)
  result.curLine = blend(bg, fg, 0.07)
  result.guide = blend(bg, fg, 0.12)
  result.inlay = blend(bg, fg, 0.45)
  result.rainbow = [bright, fg, dim]
  result.popupBg = blend(bg, fg, 0.10)
  result.menuBg = result.popupBg
  result.popupSel = blend(bg, fg, 0.28)
  result.menuSel = result.popupSel
  result.crumbBg = blend(bg, fg, 0.06)

proc allThemesRaw(): seq[Theme] =
  #            name                dark   bg        fg        accent    sel       comment   keyword   type      string    number    func      operator  macro     property  error     warning   ok
  @[
    mkTheme("one-dark",          true,  0x282C34, 0xABB2BF, 0x61AFEF, 0x3E4451, 0x5C6370, 0xC678DD, 0xE5C07B, 0x98C379, 0xD19A66, 0x61AFEF, 0x56B6C2, 0xE06C75, 0xE06C75, 0xE06C75, 0xE5C07B, 0x98C379),
    mkTheme("one-light",         false, 0xFAFAFA, 0x383A42, 0x4078F2, 0xD7DAE0, 0xA0A1A7, 0xA626A4, 0xC18401, 0x50A14F, 0x986801, 0x4078F2, 0x0184BC, 0xE45649, 0xE45649, 0xE45649, 0xC18401, 0x50A14F),
    mkTheme("tokyo-night",       true,  0x1A1B26, 0xC0CAF5, 0x7AA2F7, 0x33467C, 0x565F89, 0xBB9AF7, 0x2AC3DE, 0x9ECE6A, 0xFF9E64, 0x7AA2F7, 0x89DDFF, 0xE0AF68, 0x7DCFFF, 0xF7768E, 0xE0AF68, 0x9ECE6A),
    mkTheme("catppuccin-mocha",  true,  0x1E1E2E, 0xCDD6F4, 0x89B4FA, 0x45475A, 0x6C7086, 0xCBA6F7, 0xF9E2AF, 0xA6E3A1, 0xFAB387, 0x89B4FA, 0x89DCEB, 0xF38BA8, 0xB4BEFE, 0xF38BA8, 0xF9E2AF, 0xA6E3A1),
    mkTheme("catppuccin-latte",  false, 0xEFF1F5, 0x4C4F69, 0x1E66F5, 0xCCD0DA, 0x9CA0B0, 0x8839EF, 0xDF8E1D, 0x40A02B, 0xFE640B, 0x1E66F5, 0x04A5E5, 0xD20F39, 0x7287FD, 0xD20F39, 0xDF8E1D, 0x40A02B),
    mkTheme("gruvbox-dark",      true,  0x282828, 0xEBDBB2, 0xFABD2F, 0x504945, 0x928374, 0xFB4934, 0xFABD2F, 0xB8BB26, 0xD3869B, 0x8EC07C, 0xFE8019, 0xFE8019, 0x83A598, 0xFB4934, 0xFABD2F, 0xB8BB26),
    mkTheme("gruvbox-light",     false, 0xFBF1C7, 0x3C3836, 0xB57614, 0xE0D3B0, 0x928374, 0x9D0006, 0xB57614, 0x79740E, 0x8F3F71, 0x427B58, 0xAF3A03, 0xAF3A03, 0x076678, 0x9D0006, 0xB57614, 0x79740E),
    mkTheme("dracula",           true,  0x282A36, 0xF8F8F2, 0xBD93F9, 0x44475A, 0x6272A4, 0xFF79C6, 0x8BE9FD, 0xF1FA8C, 0xBD93F9, 0x50FA7B, 0xFF79C6, 0xFFB86C, 0xFFB86C, 0xFF5555, 0xFFB86C, 0x50FA7B),
    mkTheme("nord",              true,  0x2E3440, 0xD8DEE9, 0x88C0D0, 0x434C5E, 0x616E88, 0x81A1C1, 0x8FBCBB, 0xA3BE8C, 0xB48EAD, 0x88C0D0, 0x81A1C1, 0xD08770, 0xEBCB8B, 0xBF616A, 0xEBCB8B, 0xA3BE8C),
    mkTheme("monokai",           true,  0x272822, 0xF8F8F2, 0x66D9EF, 0x49483E, 0x75715E, 0xF92672, 0x66D9EF, 0xE6DB74, 0xAE81FF, 0xA6E22E, 0xF92672, 0xFD971F, 0xFD971F, 0xF92672, 0xE6DB74, 0xA6E22E),
    mkTheme("solarized-dark",    true,  0x002B36, 0x93A1A1, 0x268BD2, 0x0E4A5A, 0x586E75, 0x859900, 0xB58900, 0x2AA198, 0xD33682, 0x268BD2, 0x859900, 0xCB4B16, 0x6C71C4, 0xDC322F, 0xB58900, 0x859900),
    mkTheme("solarized-light",   false, 0xFDF6E3, 0x586E75, 0x268BD2, 0xE4DCC4, 0x93A1A1, 0x859900, 0xB58900, 0x2AA198, 0xD33682, 0x268BD2, 0x859900, 0xCB4B16, 0x6C71C4, 0xDC322F, 0xB58900, 0x859900),
    mkTheme("github-dark",       true,  0x0D1117, 0xC9D1D9, 0x58A6FF, 0x264F78, 0x8B949E, 0xFF7B72, 0xFFA657, 0xA5D6FF, 0x79C0FF, 0xD2A8FF, 0xFF7B72, 0xFFA657, 0x79C0FF, 0xF85149, 0xD29922, 0x3FB950),
    mkTheme("rose-pine",         true,  0x191724, 0xE0DEF4, 0xC4A7E7, 0x403D52, 0x6E6A86, 0x3E8FB0, 0x9CCFD8, 0xF6C177, 0xEBBCBA, 0xC4A7E7, 0x908CAA, 0xEB6F92, 0xEBBCBA, 0xEB6F92, 0xF6C177, 0x9CCFD8),
    mkTheme("kanagawa",          true,  0x1F1F28, 0xDCD7BA, 0x7E9CD8, 0x2D4F67, 0x727169, 0x957FB8, 0x7AA89F, 0x98BB6C, 0xD27E99, 0x7E9CD8, 0xC0A36E, 0xE46876, 0xE6C384, 0xE82424, 0xFF9E3B, 0x98BB6C),
    mkTheme("everforest-dark",   true,  0x2D353B, 0xD3C6AA, 0xA7C080, 0x543A48, 0x859289, 0xE67E80, 0xDBBC7F, 0x83C092, 0xD699B6, 0xA7C080, 0xE69875, 0xD699B6, 0x7FBBB3, 0xE67E80, 0xDBBC7F, 0xA7C080),
    mkTheme("everforest-light",  false, 0xFDF6E3, 0x5C6A72, 0x8DA101, 0xE6E2CC, 0x939F91, 0xF85552, 0xDFA000, 0x35A77C, 0xDF69BA, 0x8DA101, 0xF57D26, 0xDF69BA, 0x3A94C5, 0xF85552, 0xDFA000, 0x8DA101),
    mkTheme("night-owl",         true,  0x011627, 0xD6DEEB, 0x82AAFF, 0x1D3B53, 0x637777, 0xC792EA, 0xFFCB8B, 0xECC48D, 0xF78C6C, 0x82AAFF, 0x7FDBCA, 0xADDB67, 0xBAEBE2, 0xEF5350, 0xFFCA28, 0x22DA6E),
    mkTheme("light-owl",         false, 0xFBFBFB, 0x403F53, 0x4876D6, 0xE0E0E0, 0x989FB1, 0x994CC3, 0xBC5454, 0xC96765, 0xAA0982, 0x4876D6, 0x0C969B, 0xAA0982, 0x0C969B, 0xDE3D3B, 0xDAAA01, 0x08916A),
    mkTheme("nim-crown",         true,  0x15161B, 0xD6D8E0, 0xFFE953, 0x3A3520, 0x6B7080, 0xE8B84A, 0x7FD1C4, 0x9BD07A, 0xF29E74, 0xFFE953, 0x8FB8FF, 0xFF7AA8, 0x9DB0FF, 0xFF6B6B, 0xFFC94A, 0x9BD07A),
    mkTheme("vscode-dark",       true,  0x1F1F1F, 0xCCCCCC, 0x0078D4, 0x264F78, 0x6A9955, 0x569CD6, 0x4EC9B0, 0xCE9178, 0xB5CEA8, 0xDCDCAA, 0xD4D4D4, 0xC586C0, 0x9CDCFE, 0xF14C4C, 0xCCA700, 0x89D185).chrome(0x181818, 0x181818, 0x181818),
    mkTheme("vscode-light",      false, 0xFFFFFF, 0x3B3B3B, 0x005FB8, 0xADD6FF, 0x008000, 0x0000FF, 0x267F99, 0xA31515, 0x098658, 0x795E26, 0x000000, 0xAF00DB, 0x001080, 0xE51400, 0xBF8803, 0x388A34).chrome(0xF8F8F8, 0xF8F8F8, 0xF8F8F8),
    mkTheme("github-light",      false, 0xFFFFFF, 0x24292F, 0x0969DA, 0xCDE3F8, 0x6E7781, 0xCF222E, 0x953800, 0x0A3069, 0x0550AE, 0x8250DF, 0xCF222E, 0x953800, 0x0550AE, 0xCF222E, 0x9A6700, 0x1A7F37).chrome(0xF6F8FA, 0xF6F8FA, 0xF6F8FA),
    mkTheme("catppuccin-frappe", true,  0x303446, 0xC6D0F5, 0x8CAAEE, 0x51576D, 0x737994, 0xCA9EE6, 0xE5C890, 0xA6D189, 0xEF9F76, 0x8CAAEE, 0x99D1DB, 0xE78284, 0xBABBF1, 0xE78284, 0xE5C890, 0xA6D189),
    mkTheme("catppuccin-macchiato", true, 0x24273A, 0xCAD3F5, 0x8AADF4, 0x494D64, 0x6E738D, 0xC6A0F6, 0xEED49F, 0xA6DA95, 0xF5A97F, 0x8AADF4, 0x91D7E3, 0xED8796, 0xB7BDF8, 0xED8796, 0xEED49F, 0xA6DA95),
    mkTheme("tokyo-night-day",   false, 0xE1E2E7, 0x3760BF, 0x2E7DE9, 0xB7C1E3, 0x848CB5, 0x9854F1, 0x007197, 0x587539, 0xB15C00, 0x2E7DE9, 0x006A83, 0x8C6C3E, 0x007197, 0xF52A65, 0x8C6C3E, 0x587539),
    mkTheme("rose-pine-dawn",    false, 0xFAF4ED, 0x575279, 0x907AA9, 0xDFDAD9, 0x9893A5, 0x286983, 0x56949F, 0xEA9D34, 0xD7827E, 0x907AA9, 0x797593, 0xB4637A, 0xD7827E, 0xB4637A, 0xEA9D34, 0x56949F),
    mkTheme("kanagawa-lotus",    false, 0xF2ECBC, 0x545464, 0x4D699B, 0xC9CBD1, 0x8A8980, 0x624C83, 0x597B75, 0x6F894E, 0xB35B79, 0x4D699B, 0x836F4A, 0xC84053, 0x77713F, 0xE82424, 0xE98A00, 0x6F894E),
    mkTheme("ayu-light",         false, 0xFCFCFC, 0x5C6166, 0xFFAA33, 0xD1E4F4, 0xADAEB1, 0xFA8D3E, 0x399EE6, 0x86B300, 0xA37ACC, 0xF2AE49, 0xED9366, 0xE6BA7E, 0x55B4D4, 0xE65050, 0xFFAA33, 0x86B300),
    mkTheme("github-dark-dimmed", true, 0x22272E, 0xADBAC7, 0x539BF5, 0x264466, 0x768390, 0xF47067, 0xF69D50, 0x96D0FF, 0x6CB6FF, 0xDCBDFB, 0xF47067, 0xF69D50, 0x6CB6FF, 0xE5534B, 0xC69026, 0x57AB5A),
    mkTheme("modus-vivendi",     true,  0x000000, 0xFFFFFF, 0x2FAFFF, 0x5A5A5A, 0x989898, 0xB6A0FF, 0x6AE4B9, 0x79A8FF, 0x00BCFF, 0xFEACD0, 0xFFFFFF, 0xFF7F9F, 0x00D3D0, 0xFF5F59, 0xFEC43F, 0x44BC44),
    mkTheme("modus-operandi",    false, 0xFFFFFF, 0x000000, 0x0031A9, 0xBDBDBD, 0x595959, 0x531AB6, 0x005F5F, 0x3548CF, 0x0000B0, 0x721045, 0x000000, 0xA0132F, 0x005E8B, 0xA60000, 0x884900, 0x006800),
    mkTheme("ayu-mirage",        true,  0x1F2430, 0xCCCAC2, 0xFFCC66, 0x33415E, 0x5C6773, 0xFFA759, 0x73D0FF, 0xD5FF80, 0xDFBFFF, 0xFFD173, 0xF29E74, 0xF28779, 0x5CCFE6, 0xFF6666, 0xFFCC66, 0x87D96C),
    # from vim: molokai (tomasr), jellybeans (nanotech), iceberg (cocopon), sonokai (sainnhe), PaperColor (NLKNguyen)
    mkTheme("molokai",           true,  0x1B1D1E, 0xF8F8F2, 0x66D9EF, 0x403D3D, 0x7E8E91, 0xF92672, 0x66D9EF, 0xE6DB74, 0xAE81FF, 0xA6E22E, 0xF92672, 0xA6E22E, 0xFD971F, 0xF92672, 0xFD971F, 0xA6E22E),
    mkTheme("jellybeans",        true,  0x151515, 0xE8E8D3, 0x8197BF, 0x404040, 0x888888, 0x8197BF, 0xFFB964, 0x99AD6A, 0xCF6A4C, 0xFAD07A, 0x799D6A, 0x8FBFDC, 0xC6B6EE, 0xD54E53, 0xFFB964, 0x99AD6A),
    mkTheme("iceberg",           true,  0x161821, 0xC6C8D1, 0x84A0C6, 0x272C42, 0x6B7089, 0x84A0C6, 0xB4BE82, 0x89B8C2, 0xA093C7, 0xE2A478, 0x84A0C6, 0xB4BE82, 0x89B8C2, 0xE27878, 0xE2A478, 0xB4BE82),
    mkTheme("sonokai",           true,  0x2C2E34, 0xE2E2E3, 0x76CCE0, 0x414550, 0x7F8490, 0xFC5D7C, 0x76CCE0, 0xE7C664, 0xB39DF3, 0x9ED072, 0xFC5D7C, 0xB39DF3, 0xF39660, 0xFC5D7C, 0xE7C664, 0x9ED072),
    mkTheme("papercolor-light",  false, 0xEEEEEE, 0x444444, 0x0087AF, 0xD0D0D0, 0x878787, 0xD70087, 0x005F87, 0x5F8700, 0xD75F00, 0x0087AF, 0x0087AF, 0x8700AF, 0x005FAF, 0xAF0000, 0xD75F00, 0x008700),
    # ned's own (6.3): frankincense resin and Omani silver, a desert evening, a lagoon at noon, sea glass, ink on
    # paper, rose quartz — and two old terminals (every colour checked for contrast: tests/themes/contrast.py)
    mkTheme("frankincense",      true,  0x1C1712, 0xE8DCC8, 0xE0A84E, 0x3D3224, 0x8F806C, 0xE6A94F, 0x9FC7B5, 0xC9D18A, 0xE8916C, 0xF2C77E, 0xC2A68A, 0xDC8FA4, 0xB8C8E0, 0xF07060, 0xF0B860, 0xA8C88A).chrome(0x15110D, 0x18140F, 0x15110D),
    mkTheme("desert-dusk",       true,  0x1E1A2B, 0xE6DCEB, 0xFF9E6B, 0x3A3150, 0x857B9C, 0xFF9E6B, 0xF5C97A, 0xB8D88B, 0xFF8FA3, 0x9EC3FF, 0xD4B8E8, 0xF7A6D0, 0xA8E0D8, 0xFF6B6B, 0xFFC66B, 0xA6D88B).chrome(0x171421, 0x1A1626, 0x171421),
    mkTheme("lagoon",            true,  0x0E1F24, 0xD5ECEC, 0x4FD6C8, 0x1E4148, 0x648F94, 0x4FD6C8, 0x8AC6FF, 0xF2D492, 0xFF9F8A, 0x8FE3A8, 0x9CC7CC, 0xE59BD8, 0xB0D8F0, 0xFF6E6E, 0xF2C46D, 0x7FE0A0).chrome(0x0A181C, 0x0C1B20, 0x0A181C),
    mkTheme("sea-glass",         false, 0xEEF6F3, 0x24403E, 0x177A71, 0xBCDBD3, 0x6E8C88, 0x1B6E82, 0x7E4E93, 0x3A7535, 0xA8522A, 0x0D6662, 0x4D6A68, 0x9E3F63, 0x2C5A84, 0xB83226, 0x9A6100, 0x2A7230).chrome(0xE2EFEB, 0xE7F2EE, 0xE2EFEB),
    mkTheme("paper-ink",         false, 0xF7F3EA, 0x23263A, 0x2A4BA0, 0xCCD7EF, 0x857F70, 0x2A4BA0, 0x74399A, 0x4D6B26, 0xA8372B, 0x1F3F7A, 0x55586E, 0x9A2E6C, 0x2A6874, 0xBA261C, 0x8F5B00, 0x2C7237).chrome(0xEEE8DB, 0xF2EDE2, 0xEEE8DB),
    mkTheme("rose-quartz",       false, 0xFAF1F2, 0x3D2B33, 0xB8406F, 0xF0D3DC, 0x927C87, 0xA62D63, 0x6650A0, 0x477552, 0xA9502A, 0x72379A, 0x6E5560, 0x26797F, 0x3A6893, 0xBF2626, 0x8F6000, 0x2B7449).chrome(0xF3E4E7, 0xF6EAEC, 0xF3E4E7),
    #             name              bg        fg        bright    dim       comment   error     warning
    phosphorTheme("amber-crt",      0x140C02, 0xFFB347, 0xFFD580, 0xD9962F, 0xA5732C, 0xFF7A3D, 0xFFE066),
    phosphorTheme("green-phosphor", 0x041208, 0x6CF08A, 0xB8FFC8, 0x49B861, 0x43935A, 0xFF6F5E, 0xE8F06A),
    #          name            bg        title     dock      cur line  popup
    slateTheme("slate",        0x242430, 0x1B1B24, 0x1F1F29, 0x262633, 0x3E4452),
    slateTheme("slate-night",  0x18181F, 0x101015, 0x141419, 0x1E1E27, 0x343A46),
    monoTheme("monochrome", true),
    monoTheme("monochrome-light", false),
  ]

var themeCache: seq[Theme]

proc luminance(c: Rgb): float =
  proc ch(v: uint32): float =
    let x = float(v) / 255.0
    if x <= 0.03928: x / 12.92 else: pow((x + 0.055) / 1.055, 2.4)
  0.2126 * ch((c shr 16) and 0xFF) + 0.7152 * ch((c shr 8) and 0xFF) + 0.0722 * ch(c and 0xFF)

proc contrast(a, b: Rgb): float =
  let x = luminance(a)
  let y = luminance(b)
  (max(x, y) + 0.05) / (min(x, y) + 0.05)

proc readableOn(c, bg: Rgb, minR: float): Rgb =
  ## `c` moved away from `bg` (lighter on a dark background, darker on a light one) until it reads
  if contrast(c, bg) >= minR: return c
  let target: Rgb = if luminance(bg) < 0.2: 0xFFFFFF'u32 else: 0x000000'u32
  result = c
  for i in 1 .. 20:
    result = blend(c, target, i.float * 0.05)
    if contrast(result, bg) >= minR: return

proc bgUnder(bg, text: Rgb, minR: float): Rgb =
  ## a background moved away from the text drawn on it until that text reads
  if contrast(text, bg) >= minR: return bg
  let target: Rgb = if luminance(text) > 0.2: 0x000000'u32 else: 0xFFFFFF'u32
  result = bg
  for i in 1 .. 20:
    result = blend(bg, target, i.float * 0.05)
    if contrast(text, result) >= minR: return

proc makeReadable(t: var Theme) =
  ## one pass over every theme: interface colours get a minimum contrast, so every theme is as readable
  ## as the best ones (the theme's own hues stay; only lightness moves)
  for b in [t.bg, t.dockBg, t.crumbBg, t.menuBg, t.statusBg]: t.dim = readableOn(t.dim, b, 3.2)
  t.gutter = readableOn(t.gutter, t.bg, 2.2)
  t.inlay = readableOn(t.inlay, t.bg, 2.6)
  t.syn[tkComment] = readableOn(t.syn[tkComment], t.bg, 2.8)
  t.syn[tkDoc] = readableOn(t.syn[tkDoc], t.bg, 2.8)
  t.popupFg = readableOn(t.popupFg, t.popupBg, 4.5)
  t.titleFg = readableOn(t.titleFg, t.titleBg, 4.5)
  t.statusFg = readableOn(t.statusFg, t.statusBg, 4.5)
  t.menuSel = bgUnder(t.menuSel, t.fg, 4.5)
  if t.popupSelFg != t.fg: t.popupSelFg = readableOn(t.popupSelFg, t.popupSel, 4.5)
  else: t.popupSel = bgUnder(t.popupSel, t.fg, 4.5)
  for b in [addr t.crumbBg, addr t.toastBg, addr t.hoverBg, addr t.inputBg, addr t.menuBg]:
    b[] = bgUnder(b[], t.fg, 4.5)
  for i in 0 .. 2: t.rainbow[i] = readableOn(t.rainbow[i], t.bg, 3.0)
  # the current line and the selection must show on every theme
  if contrast(t.curLine, t.bg) < 1.08:
    for i in 1 .. 10:
      t.curLine = blend(t.bg, t.fg, 0.04 + i.float * 0.01)
      if contrast(t.curLine, t.bg) >= 1.08: break
  if contrast(t.sel, t.bg) < 1.25: t.sel = blend(t.sel, t.accent, 0.25)
  # rulers: a little stronger than the indent guides, and always visible
  t.ruler = blend(t.bg, t.fg, 0.24)          # a thin glyph: it needs more contrast than a guide
  for i in 1 .. 12:
    if contrast(t.ruler, t.bg) >= 1.6: break
    t.ruler = blend(t.bg, t.fg, 0.24 + i.float * 0.025)

proc customThemes(): seq[Theme]

proc allThemes(): seq[Theme] =
  if themeCache.len > 0: return themeCache
  themeCache = allThemesRaw()
  for t in themeCache.mitems: makeReadable(t)
  for t in customThemes(): themeCache.add t      # ~/.config/ned/themes/*.json, made readable there
  themeCache

const
  ThemeKeys = ["bg", "fg", "accent", "selection", "comment", "keyword", "type", "string", "number", "function",
               "operator", "macro", "property", "error", "warning", "ok"]
  ChromeKeys = ["titleBar", "dock", "statusBar"]

proc parseColor(s: string, bg: Rgb = 0): int =
  ## "#RRGGBB", "RRGGBB", "#RGB", "#RRGGBBAA" (the alpha is blended over `bg`); -1 when it is not a colour
  var h = s.strip
  if h.startsWith("#"): h = h[1 .. ^1]
  if h.startsWith("0x"): h = h[2 .. ^1]
  if h.len == 3: h = $h[0] & h[0] & h[1] & h[1] & h[2] & h[2]
  if h.len notin [6, 8]: return -1
  for c in h:
    if c notin HexDigits: return -1
  let rgb = Rgb(parseHexInt(h[0 .. 5]))
  if h.len == 8: return int(blend(bg, rgb, parseHexInt(h[6 .. 7]).float / 255.0))
  int(rgb)

proc rebuildTheme(t0: Theme, colors: JsonNode): Theme =
  ## `t0` with some of its colours changed (ThemeKeys, ChromeKeys, "dark"): everything derived follows
  var b = t0.base
  var c = if t0.hasChrome: t0.chromeCols else: [t0.titleBg, t0.dockBg, t0.statusBg]
  var hc = t0.hasChrome
  var dark = t0.dark
  if colors != nil and colors.kind == JObject:
    if colors{"bg"} != nil and colors{"bg"}.kind == JString:
      let bgc = parseColor(colors{"bg"}.getStr)
      if bgc >= 0: b[0] = Rgb(bgc)
    for k, v in colors:
      if k == "dark" and v.kind == JBool:
        dark = v.getBool
        continue
      if v.kind != JString: continue
      let col = parseColor(v.getStr, b[0])
      if col < 0: continue
      let i = ThemeKeys.find(k)
      if i >= 0: b[i] = Rgb(col)
      let j = ChromeKeys.find(k)
      if j >= 0:
        c[j] = Rgb(col)
        hc = true
  result = mkTheme(t0.name, dark, b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11],
                   b[12], b[13], b[14], b[15])
  if hc: result = result.chrome(c[0], c[1], c[2])
  makeReadable(result)
  if colors != nil and colors.kind == JObject and colors{"ruler"} != nil and colors{"ruler"}.kind == JString:
    let rc = parseColor(colors{"ruler"}.getStr, result.bg)
    if rc >= 0: result.ruler = Rgb(rc)

proc themeFromJson(j: JsonNode, fallbackName: string): (bool, Theme) =
  ## a theme file: {"name": "…", "base": "a built-in theme", "dark": true, "colors": {"bg": "#…", …}}
  if j == nil or j.kind != JObject: return
  var name = j{"name"}.getStr(fallbackName).strip.toLowerAscii.replace(' ', '-')
  if name.len == 0: return
  let colors = j{"colors"}
  var dark = true
  var explicitDark = false
  if j{"dark"} != nil and j{"dark"}.kind == JBool:
    dark = j{"dark"}.getBool
    explicitDark = true
  elif colors != nil and colors{"bg"} != nil:
    let bgc = parseColor(colors{"bg"}.getStr)
    if bgc >= 0: dark = luminance(Rgb(bgc)) < 0.2
  let baseName = j{"base"}.getStr(if dark: "nim-crown" else: "github-light")
  var start: Theme
  var found = false
  for t in allThemesRaw():
    if t.name == baseName:
      start = t
      found = true
  if not found:
    for t in allThemesRaw():
      if t.name == (if dark: "nim-crown" else: "github-light"): start = t
  start.name = name
  var cs = if colors != nil and colors.kind == JObject: colors.copy else: newJObject()
  if explicitDark or start.dark != dark: cs["dark"] = %dark
  (true, rebuildTheme(start, cs))

proc reloadThemes()

proc themesDir(): string = getEnv("XDG_CONFIG_HOME", getHomeDir() / ".config") / "ned" / "themes"

proc customThemes(): seq[Theme] =
  ## your own and imported themes: ~/.config/ned/themes/*.json
  if not dirExists(themesDir()): return
  var builtin: HashSet[string]
  for t in allThemesRaw(): builtin.incl t.name
  try:
    for kind, p in walkDir(themesDir()):
      if kind notin {pcFile, pcLinkToFile} or not p.endsWith(".json"): continue
      try:
        let (ok, th) = themeFromJson(parseFile(p), splitFile(p).name)
        if ok and th.name notin builtin: result.add th
      except CatchableError: discard
  except OSError: discard

var
  termBgKnown = false        # the terminal told us its background colour (OSC 11)
  termBgLight = false
  oscBgReply = ""            # the terminal's answer, picked out of the input

proc settingNode(key: string): JsonNode     # nil before the settings are loaded
proc spellReset()
proc applyUserLanguages()

proc themeOverrides(name: string): JsonNode =
  ## "theme.colors": {"comment": "#888888", …} for every theme, {"nim-crown": {…}} for one
  let all = settingNode("theme.colors")
  if all == nil or all.kind != JObject or all.len == 0: return nil
  result = newJObject()
  for k, v in all:
    if v.kind == JString: result[k] = v
  for key in [name, "[" & name & "]"]:          # {"nim-crown": {…}} or VS Code's {"[nim-crown]": {…}}
    if all{key} != nil and all{key}.kind == JObject:
      for k, v in all[key]: result[k] = v
  if result.len == 0: result = nil

proc themeNamed(name: string): (bool, Theme) =
  for t in allThemes():
    if t.name == name: return (true, t)

proc applyTheme(name: string) =
  ## a theme by name ("auto": the light or dark one that matches the terminal), with your colour overrides
  var want = name
  if name == "auto":
    let light = termBgKnown and termBgLight
    let pick = settingNode(if light: "theme.light" else: "theme.dark")
    want = if pick != nil and pick.kind == JString: pick.getStr else: (if light: "github-light" else: "nim-crown")
  let (ok, t) = themeNamed(want)
  if ok:
    let ov = themeOverrides(t.name)
    theme = if ov != nil: rebuildTheme(t, ov) else: t
    cfgThemeName = name
    return
  for t in allThemes():          # an unknown name: the default theme
    if t.name == "nim-crown":
      theme = t
      cfgThemeName = t.name
      return
  theme = allThemes()[0]
  cfgThemeName = theme.name
