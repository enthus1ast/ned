# ════════════════════════════════════════════════════════════════════════════
#  Themes: the built-in ones (mkTheme makes each from sixteen colours), the readability pass, true black, e-ink, the
#  names that stand for others
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
  ## builds a theme from sixteen colours: the background, text, accent and selection, the colours of comments, keywords,
  ## types, strings, numbers, functions, operators, macros and properties, and of errors, warnings and good news. Every
  ## other colour (dim text, line numbers, current line, bars, popups, git marks, the terminal's palette) is mixed from
  ## the background, the text and the accent, in strengths that differ for a dark and a light theme
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
  result.syn[tkMutable] = blend(fg, warn, 0.38)   # (a warm tint: this one can change)
  result.syn[tkGlobal] = fg
  result.syn[tkGlobalVar] = result.syn[tkMutable]
  result.syn[tkDeprecated] = blend(bg, fg, 0.5)
  result.syn[tkUnsafe] = warn
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

proc sunlit(t0: Theme): Theme =
  ## a light theme for a screen in sunlight: keywords bold, and what other light themes keep faint — line numbers,
  ## the current line, guides, borders, dim text, hints — strong enough to see through the glare
  result = t0
  let bg = t0.bg
  let fg = t0.fg
  result.boldKw = true
  result.dim = blend(bg, fg, 0.72)
  result.gutter = blend(bg, fg, 0.55)
  result.curLine = blend(bg, t0.accent, 0.10)
  result.guide = blend(bg, fg, 0.24)
  result.border = blend(bg, fg, 0.45)
  result.inputBorder = result.border
  result.inlay = blend(bg, fg, 0.62)
  result.wordHl = blend(bg, fg, 0.16)
  result.bracket = blend(bg, t0.accent, 0.30)
  result.match = blend(bg, t0.accent, 0.30)
  result.menuSel = blend(bg, t0.accent, 0.24)
  result.popupSel = result.menuSel
  result.scrollThumb = blend(bg, fg, 0.40)
  result.crumbBg = blend(bg, t0.accent, 0.12)
  result.syn[tkPunct] = result.dim

proc isInk(t: Theme): bool =
  ## black and white only, each of its colours one or the other: an e-ink theme
  if t.base[0] == t.base[1]: return false
  for c in t.base:
    if c != 0x000000'u32 and c != 0xFFFFFF'u32: return false
  if t.hasChrome:
    for c in t.chromeCols:
      if c != 0x000000'u32 and c != 0xFFFFFF'u32: return false
  true

proc inked(t0: Theme): Theme =
  ## e-ink: every colour the theme would mix is the ink or the paper — an e-ink screen shows a grey as dithering, and
  ## keeps a ghost of it. What other themes shade is shown inverted (the selection, find matches, the selected row of
  ## a menu, buttons, the status bar, the breadcrumb bar with the active tab, sticky headers) or by weight (keywords
  ## bold; the current line's number and the matching bracket are bold in every theme). The bars and docks keep the
  ## colours `chrome` gave them
  result = t0
  let p = t0.bg                    # paper
  let k = t0.fg                    # ink
  # the ink when c is the paper, else the paper
  proc other(c: Rgb): Rgb = (if c == p: k else: p)
  result.boldKw = true
  for f in [addr result.dim, addr result.gutter, addr result.gutterCur, addr result.sel, addr result.match,
            addr result.matchCur, addr result.border, addr result.accent, addr result.guide, addr result.cursorSec,
            addr result.ruler, addr result.popupFg, addr result.tabFg, addr result.tabActiveFg, addr result.popupSel,
            addr result.menuSel, addr result.err, addr result.warn, addr result.info, addr result.hint,
            addr result.gitAdd, addr result.gitMod, addr result.gitDel, addr result.stickyBg, addr result.inlay,
            addr result.inputBorder, addr result.btnBg, addr result.badgeBg, addr result.scrollThumb,
            addr result.focusBorder, addr result.minimap, addr result.shadow, addr result.crumbBg]:
    f[] = k
  for f in [addr result.curLine, addr result.wordHl, addr result.bracket, addr result.tabActiveBg,
            addr result.popupBg, addr result.popupSelFg, addr result.inputBg, addr result.btnFg, addr result.menuBg,
            addr result.toastBg, addr result.badgeFg, addr result.codeBg, addr result.userBg, addr result.splitBar]:
    f[] = p
  for f in [addr result.titleBg, addr result.dockBg, addr result.statusBg]:
    if f[] != k: f[] = p
  result.dockHeadBg = result.dockBg
  result.tabBarBg = result.dockBg
  result.tabBg = result.dockBg
  result.panelBg = result.dockBg
  result.hoverBg = result.dockBg
  result.titleFg = other(result.titleBg)
  result.statusFg = other(result.statusBg)
  result.rainbow = [k, k, k]
  for i in 0 .. 15: result.ansi[i] = k
  result.ansi[0] = 0x000000             # (the terminal's black and white stay black and white; its colours are ink)
  result.ansi[7] = 0xFFFFFF
  result.ansi[15] = 0xFFFFFF
  for tk in TokKind: result.syn[tk] = k

proc allThemesRaw(): seq[Theme] =
  ## the built-in themes as they are written, before makeReadable touches them: most from mkTheme's sixteen colours, the
  ## phosphor, slate and monochrome ones by their own helpers. A new list on every call
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
    mkTheme("tokyo-night-day",   false, 0xE1E2E7, 0x3760BF, 0x2E7DE9, 0xB7C1E3, 0x848CB5, 0x9854F1, 0x007197, 0x587539, 0xB15C00, 0x2E7DE9, 0x006A83, 0x8C6C3E, 0x007197, 0xF52A65, 0x8C6C3E, 0x587539),
    mkTheme("rose-pine-dawn",    false, 0xFAF4ED, 0x575279, 0x907AA9, 0xDFDAD9, 0x9893A5, 0x286983, 0x56949F, 0xEA9D34, 0xD7827E, 0x907AA9, 0x797593, 0xB4637A, 0xD7827E, 0xB4637A, 0xEA9D34, 0x56949F),
    mkTheme("kanagawa-lotus",    false, 0xF2ECBC, 0x545464, 0x4D699B, 0xC9CBD1, 0x8A8980, 0x624C83, 0x597B75, 0x6F894E, 0xB35B79, 0x4D699B, 0x836F4A, 0xC84053, 0x77713F, 0xE82424, 0xE98A00, 0x6F894E),
    mkTheme("ayu-light",         false, 0xFCFCFC, 0x5C6166, 0xFFAA33, 0xD1E4F4, 0xADAEB1, 0xFA8D3E, 0x399EE6, 0x86B300, 0xA37ACC, 0xF2AE49, 0xED9366, 0xE6BA7E, 0x55B4D4, 0xE65050, 0xFFAA33, 0x86B300),
    mkTheme("modus-vivendi",     true,  0x000000, 0xFFFFFF, 0x2FAFFF, 0x5A5A5A, 0x989898, 0xB6A0FF, 0x6AE4B9, 0x79A8FF, 0x00BCFF, 0xFEACD0, 0xFFFFFF, 0xFF7F9F, 0x00D3D0, 0xFF5F59, 0xFEC43F, 0x44BC44),
    mkTheme("modus-operandi",    false, 0xFFFFFF, 0x000000, 0x0031A9, 0xBDBDBD, 0x595959, 0x531AB6, 0x005F5F, 0x3548CF, 0x0000B0, 0x721045, 0x000000, 0xA0132F, 0x005E8B, 0xA60000, 0x884900, 0x006800),
    mkTheme("ayu-mirage",        true,  0x1F2430, 0xCCCAC2, 0xFFCC66, 0x33415E, 0x5C6773, 0xFFA759, 0x73D0FF, 0xD5FF80, 0xDFBFFF, 0xFFD173, 0xF29E74, 0xF28779, 0x5CCFE6, 0xFF6666, 0xFFCC66, 0x87D96C),
    mkTheme("ayu-dark",          true,  0x0B0E14, 0xBFBDB6, 0xE6B450, 0x1B395A, 0x626A73, 0xFF8F40, 0x59C2FF, 0xAAD94C, 0xD2A6FF, 0xFFB454, 0xF29668, 0xF07178, 0x39BAE6, 0xD95757, 0xE6B450, 0x7FD962),
    # from vim: jellybeans (nanotech), iceberg (cocopon), sonokai (sainnhe), PaperColor (NLKNguyen)
    mkTheme("jellybeans",        true,  0x151515, 0xE8E8D3, 0x8197BF, 0x404040, 0x888888, 0x8197BF, 0xFFB964, 0x99AD6A, 0xCF6A4C, 0xFAD07A, 0x799D6A, 0x8FBFDC, 0xC6B6EE, 0xD54E53, 0xFFB964, 0x99AD6A),
    mkTheme("iceberg",           true,  0x161821, 0xC6C8D1, 0x84A0C6, 0x272C42, 0x6B7089, 0x84A0C6, 0xB4BE82, 0x89B8C2, 0xA093C7, 0xE2A478, 0x84A0C6, 0xB4BE82, 0x89B8C2, 0xE27878, 0xE2A478, 0xB4BE82),
    mkTheme("sonokai",           true,  0x2C2E34, 0xE2E2E3, 0x76CCE0, 0x414550, 0x7F8490, 0xFC5D7C, 0x76CCE0, 0xE7C664, 0xB39DF3, 0x9ED072, 0xFC5D7C, 0xB39DF3, 0xF39660, 0xFC5D7C, 0xE7C664, 0x9ED072),
    mkTheme("papercolor-light",  false, 0xEEEEEE, 0x444444, 0x0087AF, 0xD0D0D0, 0x878787, 0xD70087, 0x005F87, 0x5F8700, 0xD75F00, 0x0087AF, 0x0087AF, 0x8700AF, 0x005FAF, 0xAF0000, 0xD75F00, 0x008700),
    # (6.39) more from other editors and their authors: Gruvbox Material, Material Palenight, Nightfox, Oxocarbon,
    # Poimandres, Synthwave '84, Cobalt2, Horizon, Vesper, Flexoki, Zenburn, Melange, Monokai Pro
    mkTheme("gruvbox-material-dark", true,  0x282828, 0xD4BE98, 0x7DAEA3, 0x45403D, 0x928374, 0xEA6962, 0xD8A657, 0x89B482, 0xD3869B, 0xA9B665, 0xE78A4E, 0xA9B665, 0x7DAEA3, 0xEA6962, 0xD8A657, 0xA9B665),
    mkTheme("gruvbox-material-light", false, 0xFBF1C7, 0x654735, 0x45707A, 0xEEE0B7, 0x928374, 0xC14A4A, 0xB47109, 0x4C7A5D, 0x945E80, 0x6C782E, 0xC35E0A, 0x6C782E, 0x45707A, 0xC14A4A, 0xB47109, 0x6C782E),
    mkTheme("material-palenight", true,  0x292D3E, 0xA6ACCD, 0x82AAFF, 0x444267, 0x676E95, 0xC792EA, 0xFFCB6B, 0xC3E88D, 0xF78C6C, 0x82AAFF, 0x89DDFF, 0x89DDFF, 0xF07178, 0xFF5370, 0xFFCB6B, 0xC3E88D),
    mkTheme("nightfox",          true,  0x192330, 0xCDCECF, 0x719CD6, 0x2B3B51, 0x738091, 0x9D79D6, 0xDBC074, 0x81B29A, 0xF4A261, 0x86ABDC, 0xAEAFB0, 0xD67AD2, 0x719CD6, 0xC94F6D, 0xDBC074, 0x81B29A),
    mkTheme("carbonfox",         true,  0x161616, 0xF2F4F8, 0x78A9FF, 0x2A2A2A, 0x6E6F70, 0xBE95FF, 0x08BDBA, 0x25BE6A, 0x3DDBD9, 0x8CB6FF, 0xB6B8BB, 0xFF7EB6, 0x78A9FF, 0xEE5396, 0xBE95FF, 0x25BE6A),
    mkTheme("dawnfox",           false, 0xFAF4ED, 0x575279, 0x286983, 0xD0D8D8, 0x9893A5, 0x907AA9, 0xEA9D34, 0x618774, 0xD7827E, 0x295E73, 0x625C87, 0xC9709E, 0x286983, 0xB4637A, 0xEA9D34, 0x618774),
    mkTheme("oxocarbon",         true,  0x161616, 0xD5D5D5, 0x78A9FF, 0x404040, 0x5C5C5C, 0x78A9FF, 0x3DDBD9, 0xBE95FF, 0x82CFFF, 0xFF7EB6, 0x78A9FF, 0x08BDBA, 0xEE5396, 0xEE5396, 0xBE95FF, 0x42BE65),
    mkTheme("poimandres",        true,  0x1B1E28, 0xA6ACCD, 0x5DE4C7, 0x303340, 0x767C9D, 0x91B4D5, 0xFFFAC2, 0x5DE4C7, 0x5DE4C7, 0xADD7FF, 0x91B4D5, 0xF087BD, 0xE4F0FB, 0xD0679D, 0xFFFAC2, 0x5FB3A1),
    mkTheme("synthwave-84",      true,  0x262335, 0xFFFFFF, 0xFF7EDB, 0x413E4E, 0x848BBD, 0xFEDE5D, 0xFE4450, 0xFF8B39, 0xF97E72, 0x36F9F6, 0xFEDE5D, 0x72F1B8, 0xFF7EDB, 0xFE4450, 0xFEDE5D, 0x72F1B8),
    mkTheme("cobalt2",           true,  0x193549, 0xFFFFFF, 0xFFC600, 0x0050A4, 0x0088FF, 0xFF9D00, 0x80FFBB, 0xA5FF90, 0xFF628C, 0xFFC600, 0xFF9D00, 0xFB94FF, 0x9EFFFF, 0xF44542, 0xFFC600, 0x3AD900),
    mkTheme("horizon",           true,  0x1C1E26, 0xD5D8DA, 0xE95678, 0x353747, 0x6C6F93, 0xB877DB, 0xEFB41B, 0xFAB795, 0xF09383, 0x25B2BC, 0xD5D8DA, 0xEE64AE, 0xE95678, 0xE95678, 0xEFB41B, 0x27D796),
    mkTheme("vesper",            true,  0x101010, 0xFFFFFF, 0xFFC799, 0x343434, 0x8B8B8B, 0xA0A0A0, 0xFFC799, 0x99FFE4, 0xFFC799, 0xFFC799, 0xA0A0A0, 0xFFC799, 0xFFFFFF, 0xFF8080, 0xFFC799, 0x99FFE4),
    mkTheme("flexoki-dark",      true,  0x100F0F, 0xCECDC3, 0x4385BE, 0x343331, 0x575653, 0x879A39, 0xD0A215, 0x3AA99F, 0x8B7EC8, 0xDA702C, 0x878580, 0xCE5D97, 0x4385BE, 0xD14D41, 0xDA702C, 0x879A39),
    mkTheme("flexoki-light",     false, 0xFFFCF0, 0x100F0F, 0x205EA6, 0xDAD8CE, 0xB7B5AC, 0x66800B, 0xAD8301, 0x24837B, 0x5E409D, 0xBC5215, 0x6F6E69, 0xA02F6F, 0x205EA6, 0xAF3029, 0xBC5215, 0x66800B),
    mkTheme("zenburn",           true,  0x3F3F3F, 0xDCDCCC, 0x8CD0D3, 0x2F2F2F, 0x7F9F7F, 0xF0DFAF, 0xDFDFBF, 0xCC9393, 0x8CD0D3, 0xEFEF8F, 0xF0EFD0, 0xFFCFAF, 0xEFDCBC, 0xE37170, 0xDFAF8F, 0x709080),
    mkTheme("melange-dark",      true,  0x292522, 0xECE1D7, 0xEBC06D, 0x403A36, 0xC1A78E, 0xE49B5D, 0x7B9695, 0xA3A9CE, 0xCF9BC2, 0xEBC06D, 0xD47766, 0x85B695, 0x7F91B2, 0xBD8183, 0xEBC06D, 0x78997A),
    mkTheme("melange-light",     false, 0xF1F1F1, 0x54433A, 0xA06D00, 0xD9D3CE, 0x7D6658, 0xBC5C00, 0x739797, 0x465AA4, 0x904180, 0xA06D00, 0xBF0021, 0x3A684A, 0x7892BD, 0xC77B8B, 0xA06D00, 0x6E9B72),
    mkTheme("monokai-pro",       true,  0x2D2A2E, 0xFCFCFA, 0xFFD866, 0x5B595C, 0x727072, 0xFF6188, 0x78DCE8, 0xFFD866, 0xAB9DF2, 0xA9DC76, 0xFF6188, 0xFC9867, 0xFCFCFA, 0xFF6188, 0xFC9867, 0xA9DC76),
    # 6.30: Shades of Purple (Ahmad Awais, VS Code) and its Super Dark; Foxoman's ClassicBlue (VS Code) and his Nebula
    # themes (Zed) — Nebula Void is ned's own Slate, kept under that name. Colours that read below 4.5:1 on their
    # background (3:1 for comments) were lifted to it, their hue kept (tests/themes/contrast.py)
    mkTheme("shades-of-purple",  true,  0x2D2B55, 0xFFFFFF, 0xFAD000, 0x6A4BB0, 0xB362FF, 0xFF9D00, 0x9EFFFF, 0xA5FF90, 0xFF628C, 0xFAD000, 0xFF9D00, 0xFB94FF, 0xFFEE80, 0xF1706E, 0xFAD000, 0x3AD900).chrome(0x1E1E3F, 0x222244, 0x1E1E3F),
    mkTheme("shades-of-purple-super-dark", true, 0x191830, 0xFFFFFF, 0xFAD000, 0x3A1270, 0xB362FF, 0xFF9D00, 0x9EFFFF, 0xA5FF90, 0xFF628C, 0xFAD000, 0xFF9D00, 0xFB94FF, 0xFFEE80, 0xED4441, 0xFAD000, 0x3AD900).chrome(0x15152B, 0x131327, 0x15152B),
    mkTheme("classic-blue",      true,  0x3E308B, 0xE6E6E6, 0x3FA9E0, 0x264F78, 0x9B9B9B, 0x78B0DE, 0x4EC9B0, 0xD49F89, 0xB5CEA8, 0xDCDCAA, 0xD4D4D4, 0xCF9BCB, 0x9CDCFE, 0xF88C8C, 0xCD9731, 0x89D185).chrome(0x222222, 0x252526, 0x222222),
    mkTheme("nebula-pulse",      true,  0x1E2340, 0xD1D5E8, 0x68A6E6, 0x2E4466, 0x6A7199, 0xC678DD, 0xE5C07B, 0x98C379, 0xE5C07B, 0x61AFEF, 0xFF9D00, 0xC678DD, 0x68A6E6, 0xE06C75, 0xE5C07B, 0x98C379).chrome(0x1A1E38, 0x252A47, 0x1A1E38),
    mkTheme("nebula-nova",       true,  0x1A1A22, 0xE1E1EF, 0x82C7FF, 0x2A3E55, 0x72A966, 0x5D95E8, 0x4FD6BA, 0xE69E83, 0xB5CEA8, 0xE8CC8D, 0xD4D4D4, 0x56BEFF, 0x9CDCFE, 0xF14C4C, 0xE5E510, 0x23D18B).chrome(0x15151D, 0x1E1E26, 0x15151D),
    mkTheme("nebula-nord",       true,  0x181B28, 0x50B1DC, 0x6DC2F2, 0x22394E, 0x666A73, 0x00A8FF, 0x6DBCD1, 0xDFFC00, 0xC850D1, 0x18A5DE, 0x48ACC7, 0x45AEE4, 0x6DC2F2, 0xFF5D5D, 0xFF6A00, 0x18A5DE).chrome(0x0C0E14, 0x161925, 0x0C0E14),
    mkTheme("nebula-serenity",   true,  0x0F0F18, 0xE6E6EE, 0xA2CFFF, 0x212B44, 0x626271, 0xACA8FF, 0xF9B98C, 0x4EBE96, 0xF9B98C, 0xE6E7A3, 0x859BB3, 0xC8E1FF, 0xA2CFFF, 0xF05A74, 0xE6E7A3, 0x4DCFB0).chrome(0x0A0A12, 0x14141D, 0x0A0A12),
    mkTheme("nebula-glow",       false, 0xE1E5F5, 0x2E3761, 0x3369A1, 0xBACCEA, 0x7781B0, 0x875295, 0x78622D, 0x496F35, 0x78622D, 0x3266A3, 0xCF6300, 0x875295, 0x3369A1, 0xA34A50, 0x7D621E, 0x496F35).chrome(0xD9DEF2, 0xDAE0F5, 0xD9DEF2),
    mkTheme("nebula-dawn",       false, 0xFFFFFF, 0x000000, 0x0000FF, 0xC4C4FF, 0x005500, 0x191970, 0x6D16BD, 0x8B4500, 0xBD00BD, 0x191970, 0x191970, 0xBD00BD, 0x0000FF, 0xCD0000, 0x8B4500, 0x005500).chrome(0xF0F0F0, 0xEEEEEE, 0xF0F0F0),
    # ned's own (6.3): frankincense resin and Omani silver, a desert evening, a lagoon at noon, sea glass, ink on
    # paper, rose quartz — and two old terminals (every colour checked for contrast: tests/themes/contrast.py)
    mkTheme("frankincense",      true,  0x1C1712, 0xE8DCC8, 0xE0A84E, 0x3D3224, 0x8F806C, 0xE6A94F, 0x9FC7B5, 0xC9D18A, 0xE8916C, 0xF2C77E, 0xC2A68A, 0xDC8FA4, 0xB8C8E0, 0xF07060, 0xF0B860, 0xA8C88A).chrome(0x15110D, 0x18140F, 0x15110D),
    mkTheme("desert-dusk",       true,  0x1E1A2B, 0xE6DCEB, 0xFF9E6B, 0x3A3150, 0x857B9C, 0xFF9E6B, 0xF5C97A, 0xB8D88B, 0xFF8FA3, 0x9EC3FF, 0xD4B8E8, 0xF7A6D0, 0xA8E0D8, 0xFF6B6B, 0xFFC66B, 0xA6D88B).chrome(0x171421, 0x1A1626, 0x171421),
    mkTheme("lagoon",            true,  0x0E1F24, 0xD5ECEC, 0x4FD6C8, 0x1E4148, 0x648F94, 0x4FD6C8, 0x8AC6FF, 0xF2D492, 0xFF9F8A, 0x8FE3A8, 0x9CC7CC, 0xE59BD8, 0xB0D8F0, 0xFF6E6E, 0xF2C46D, 0x7FE0A0).chrome(0x0A181C, 0x0C1B20, 0x0A181C),
    mkTheme("sea-glass",         false, 0xEEF6F3, 0x24403E, 0x177A71, 0xBCDBD3, 0x6E8C88, 0x1B6E82, 0x7E4E93, 0x3A7535, 0xA8522A, 0x0D6662, 0x4D6A68, 0x9E3F63, 0x2C5A84, 0xB83226, 0x9A6100, 0x2A7230).chrome(0xE2EFEB, 0xE7F2EE, 0xE2EFEB),
    mkTheme("paper-ink",         false, 0xF7F3EA, 0x23263A, 0x2A4BA0, 0xCCD7EF, 0x857F70, 0x2A4BA0, 0x74399A, 0x4D6B26, 0xA8372B, 0x1F3F7A, 0x55586E, 0x9A2E6C, 0x2A6874, 0xBA261C, 0x8F5B00, 0x2C7237).chrome(0xEEE8DB, 0xF2EDE2, 0xEEE8DB),
    mkTheme("rose-quartz",       false, 0xFAF1F2, 0x3D2B33, 0xB8406F, 0xF0D3DC, 0x927C87, 0xA62D63, 0x6650A0, 0x477552, 0xA9502A, 0x72379A, 0x6E5560, 0x26797F, 0x3A6893, 0xBF2626, 0x8F6000, 0x2B7449).chrome(0xF3E4E7, 0xF6EAEC, 0xF3E4E7),
    # ned's own (6.27), easy on the eyes: three for OLED screens — true black (its pixels off), text a soft grey
    # rather than white (no glow around it), a warm one with no blue for the evening, a dim one for the dark — and
    # three for LCD screens, whose black is a lit grey: a soft dark grey, a warm dark brown, warm paper
    mkTheme("oled-black",        true,  0x000000, 0xC9CCD1, 0x5FB3D9, 0x1C2733, 0x737880, 0xB89AE0, 0x6FCBBE, 0xA9CC8C, 0xE6A472, 0x82B4F0, 0x98A2AE, 0xE08FAE, 0xC2CCE6, 0xF07272, 0xE8C27E, 0x8FCB8A).chrome(0x000000, 0x070707, 0x000000),
    mkTheme("oled-warm",         true,  0x000000, 0xD9C9AB, 0xE3A552, 0x2A1F12, 0x86796A, 0xE6A552, 0xC2B46E, 0xA6C27A, 0xEE8F6A, 0xF2CF92, 0xB09D86, 0xDC8E9A, 0xD8C0A0, 0xF27A62, 0xF0C060, 0xA9C485).chrome(0x000000, 0x080604, 0x000000),
    mkTheme("oled-dim",          true,  0x000000, 0xA3A6AB, 0x6FA3BA, 0x161D24, 0x5F6368, 0xA08DC0, 0x5FAAA0, 0x8DAA74, 0xC09068, 0x7A9ED0, 0x7E868F, 0xBF7E96, 0x9EA8BE, 0xD06A6A, 0xC4A468, 0x7EA874).chrome(0x000000, 0x050505, 0x000000),
    mkTheme("lcd-soft",          true,  0x2B2D31, 0xD0D3D8, 0x7FAADD, 0x3D4A5C, 0x8A9099, 0xC7A2E2, 0x86CCC4, 0xAED193, 0xE3AA80, 0x92BFF0, 0xACB4BE, 0xE69AB0, 0xBCC7E0, 0xEE7D7D, 0xE6C487, 0x9CC88C).chrome(0x232528, 0x26282C, 0x232528),
    mkTheme("lcd-warm",          true,  0x2A2620, 0xDDD2C0, 0xD9A85C, 0x433A2D, 0x968B7A, 0xE2AC5F, 0xB6C072, 0x8FC088, 0xF0925A, 0x86BCB0, 0xC4B49A, 0xE095A8, 0xCFC09F, 0xF0736A, 0xE6BE68, 0xACC074).chrome(0x221F1A, 0x25211C, 0x221F1A),
    mkTheme("lcd-paper",         false, 0xEDE8DC, 0x2F302E, 0x2F64A0, 0xCCD6E2, 0x7A7568, 0x7A3E9D, 0x2B6B62, 0x4A7224, 0x9E4A22, 0x255A96, 0x55554F, 0x963558, 0x2E566F, 0xAE3428, 0x855B00, 0x2E7537).chrome(0xE3DDCF, 0xE7E2D5, 0xE3DDCF),
    #             name              bg        fg        bright    dim       comment   error     warning
    phosphorTheme("amber-crt",      0x140C02, 0xFFB347, 0xFFD580, 0xD9962F, 0xA5732C, 0xFF7A3D, 0xFFE066),
    phosphorTheme("green-phosphor", 0x041208, 0x6CF08A, 0xB8FFC8, 0x49B861, 0x43935A, 0xFF6F5E, 0xE8F06A),
    #          name            bg        title     dock      cur line  popup
    slateTheme("slate",        0x242430, 0x1B1B24, 0x1F1F29, 0x262633, 0x3E4452),
    monoTheme("monochrome", true),
    monoTheme("monochrome-light", false),
    # ned's own (6.32), for a tablet outdoors: in sunlight — deep colours, every one 7:1 or more on its background and
    # far apart in hue, comments 6:1, keywords bold, the current line and line numbers strong — on white, on warm
    # paper and on a cool blue white; and for an e-ink screen, black and white only (tests/themes/contrast.py)
    mkTheme("sunlight",          false, 0xFFFFFF, 0x000000, 0x0046C0, 0xB0D0FF, 0x52606C, 0x6200C8, 0x005A5E, 0x005E17, 0x8A3D00, 0x0046C0, 0x2E2E3A, 0x96008A, 0xA6001F, 0xB00000, 0x7A4F00, 0x00612A).sunlit,
    mkTheme("sunlight-warm",     false, 0xFBF5E6, 0x1A1206, 0x0043B5, 0xE8C98A, 0x5E5546, 0x5E00C0, 0x00575A, 0x2B5A00, 0x7E3A00, 0x0043B5, 0x3A2E20, 0x8C0080, 0x9E0020, 0xA80000, 0x6E4800, 0x1F5C14).chrome(0xF0E8D4, 0xF6EFDD, 0xF0E8D4).sunlit,
    mkTheme("sunlight-blue",     false, 0xEFF5FB, 0x0B1A2E, 0x0040B8, 0xB5CCF0, 0x4E5D70, 0x0040B8, 0x6200C0, 0x005E17, 0x8A3500, 0x00585E, 0x283447, 0x8E007E, 0xA0001E, 0xA80000, 0x704800, 0x00592A).chrome(0xE1EAF4, 0xE8F0F8, 0xE1EAF4).sunlit,
    mkTheme("e-ink",             false, 0xFFFFFF, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000).chrome(0xFFFFFF, 0xFFFFFF, 0x000000).inked,
    mkTheme("e-ink-dark",        true,  0x000000, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF).chrome(0x000000, 0x000000, 0xFFFFFF).inked,
    # 6.41: mint-night — near black, mint keywords and types, lavender function names, light blue strings
    mkTheme("mint-night",        true,  0x050505, 0xF4F4F4, 0xA8D8B9, 0x26332B, 0x6E6E6E, 0xA8D8B9, 0xA8D8B9, 0xA9CFE8, 0x5CB6E8, 0xA3AADC, 0xF4F4F4, 0xB0B8C8, 0xE2E5EE, 0xF2777A, 0xE8C27C, 0xA8D8B9),
    # 6.41: the themes of ray.so (github.com/raycast/ray-so, app/(navigation)/(code)/store/themes.ts), dark and light,
    # each with ray- before its name. Their code colours as ray.so has them; the background is the code window's on
    # ray.so (its frame over the theme's gradient), a light one brightened where that came out grey. Copyright (c) 2024
    # Raycast Technologies Ltd, under the MIT licence: Permission is hereby granted, free of charge, to any person
    # obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software
    # without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute,
    # sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so,
    # subject to the following conditions: The above copyright notice and this permission notice shall be included in
    # all copies or substantial portions of the Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY
    # KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
    # PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
    # CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
    # IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
    mkTheme("ray-vercel-dark",         true,  0x000000, 0xEDEDED, 0x47A8FF, 0x142F47, 0xA1A1A1, 0xFF4D8D, 0x47A8FF, 0x00CA50, 0xFFFFFF, 0xC472FB, 0xEDEDED, 0xFF9300, 0x47A8FF, 0xF32E40, 0xE5B54A, 0x00952D),
    mkTheme("ray-vercel-light",        false, 0xFFFFFF, 0x171717, 0x005FF2, 0xC7DCFC, 0x666666, 0xC41562, 0x005FF2, 0x107D32, 0x111111, 0x7D00CC, 0x171717, 0xAA4D00, 0x005FF2, 0xE2162A, 0xA86B00, 0x009432),
    mkTheme("ray-rabbit-dark",         true,  0x000000, 0xFFFFFF, 0xA7A7A7, 0x2F2F2F, 0x666666, 0xA7A7A7, 0xA7A7A7, 0xA7A7A7, 0xFFFFFF, 0xFFFFFF, 0xA7A7A7, 0xA7A7A7, 0xA7A7A7, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-rabbit-light",        false, 0xEBEBEB, 0x111111, 0x666666, 0xCECECE, 0x999999, 0x666666, 0x666666, 0x666666, 0x111111, 0x111111, 0x666666, 0x666666, 0x666666, 0xD0353A, 0xA86B00, 0x1A7F37),
    mkTheme("ray-supabase-dark",       true,  0x121212, 0xFFFFFF, 0xBDA4FF, 0x423B54, 0x7E7E7E, 0xBDA4FF, 0x3ECF8E, 0xFFCDA1, 0xEDEDED, 0x3ECF8E, 0xFFFFFF, 0xFFFFFF, 0x3ECF8E, 0xF06A50, 0xE5B54A, 0x3ECF8E),
    mkTheme("ray-supabase-light",      false, 0xFCFCFC, 0x525252, 0x009A55, 0xC5E6D7, 0x7E7E7E, 0x6B35DC, 0x15593B, 0xF1A10D, 0x525252, 0x15593B, 0xA0A0A0, 0x525252, 0x15593B, 0xD0353A, 0xA86B00, 0x1A7F37),
    mkTheme("ray-tailwind-dark",       true,  0x0F172A, 0xFFFFFF, 0xC1B2F9, 0x414264, 0x7B7F8A, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-tailwind-light",      false, 0xFFFFFF, 0x000000, 0x0484C7, 0xC8E4F3, 0x8C8C8C, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0x000000, 0xD0353A, 0xA86B00, 0x1A7F37),
    mkTheme("ray-openai-dark",         true,  0x121A29, 0xFFFFFF, 0xF22C3D, 0x511F2F, 0x71767F, 0x2E95D3, 0xDF3079, 0xFFFFFF, 0xE9950C, 0x00A67D, 0xFFFFFF, 0xFFFFFF, 0xF22C3D, 0xF22C3D, 0xE5B54A, 0x00A67D),
    mkTheme("ray-openai-light",        false, 0xFFFFFF, 0x171717, 0xF22C3D, 0xFCD1D4, 0xACACBE, 0x2E95D3, 0xDF3079, 0x171717, 0xE9950C, 0x00A67D, 0x171717, 0xEDEDED, 0xF22C3D, 0xF22C3D, 0xA86B00, 0x00A67D),
    mkTheme("ray-mintlify-dark",       true,  0x121212, 0xF3F7F6, 0xF7D87C, 0x524930, 0x707070, 0x569CD6, 0x4EC9B0, 0xF3F7F6, 0xB5CEA8, 0x9CDCFE, 0x808080, 0x4EC9B0, 0xB5CEA8, 0xE17271, 0xE5B54A, 0x4EC9B0),
    mkTheme("ray-mintlify-light",      false, 0xF6FBF9, 0x171717, 0xE8BC39, 0xF3EDCF, 0x707070, 0x0D548F, 0x0D9373, 0x171717, 0x4AAB15, 0x0576B7, 0x808080, 0x0D9373, 0x4AAB15, 0xDC2625, 0xA86B00, 0x0D9373),
    mkTheme("ray-prisma-dark",         true,  0x040404, 0xF9FAF5, 0x01D7E4, 0x033F43, 0xA5A5A6, 0x01D7E4, 0x7BE7F0, 0xF3C306, 0x7BE7F0, 0xFF7682, 0xF9FAF5, 0xF8DA85, 0x7BE7F0, 0xFF7682, 0xE5B54A, 0x01D7E4),
    mkTheme("ray-prisma-light",        false, 0xEAEAEA, 0x151515, 0x009AAA, 0xB7D8DC, 0x646567, 0x007F8D, 0x009AAA, 0xD48700, 0x009AAA, 0xD02344, 0x3A3B3C, 0x965100, 0x009AAA, 0xD02344, 0xA86B00, 0x009AAA),
    mkTheme("ray-clerk-dark",          true,  0x222222, 0xFFFFFF, 0xBAB1FF, 0x4D4A60, 0x9394A1, 0xBAB1FF, 0x86EF9B, 0x5DE3FF, 0x86EF9B, 0xBAB1FF, 0xB7B8C2, 0x86EF9B, 0x86EF9B, 0xE17271, 0xE5B54A, 0x86EF9B),
    mkTheme("ray-clerk-light",         false, 0xF9F9F9, 0x131316, 0x6C47FF, 0xDAD2FA, 0x9394A1, 0x6C47FF, 0x22C543, 0x00AEE3, 0x22C543, 0x6C47FF, 0x747686, 0x22C543, 0x22C543, 0xFF605E, 0xA86B00, 0x22C543),
    mkTheme("ray-elevenlabs-dark",     true,  0x111111, 0xFFFFFF, 0xFFF9B2, 0x54523E, 0xA1A1A1, 0xFFF9B2, 0x8F8FFF, 0xA1FFE0, 0x8F8FFF, 0xFF8080, 0xFFFFFF, 0x8F8FFF, 0x8F8FFF, 0xFF8080, 0xE5B54A, 0xA1FFE0),
    mkTheme("ray-elevenlabs-light",    false, 0xFFFFFF, 0x1C1C1C, 0xAEA8FF, 0xEDECFF, 0x666666, 0x1C1C1C, 0x4C3FFF, 0x00A890, 0x4C3FFF, 0xE85C5C, 0x1C1C1C, 0x4C3FFF, 0x4C3FFF, 0xFF605E, 0xA86B00, 0x00A890),
    mkTheme("ray-resend-dark",         true,  0x0C0C0C, 0xFFFFFF, 0xA7A7A7, 0x373737, 0x666666, 0xA7A7A7, 0xA7A7A7, 0xA7A7A7, 0xFFFFFF, 0xFFFFFF, 0xA7A7A7, 0xA7A7A7, 0xA7A7A7, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-resend-light",        false, 0xEAEAEA, 0x111111, 0x666666, 0xCDCDCD, 0x999999, 0x666666, 0x666666, 0x666666, 0x111111, 0x111111, 0x666666, 0x666666, 0x666666, 0xD0353A, 0xA86B00, 0x1A7F37),
    mkTheme("ray-triggerdev-dark",     true,  0x121317, 0xCCCBFF, 0x826DFF, 0x312C58, 0x5F6570, 0xE888F8, 0x9C9AF2, 0xAFEC73, 0xB5CEA8, 0x9684FF, 0x878C99, 0xCCCBFF, 0xCCCBFF, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-triggerdev-light",    false, 0xFAFAFA, 0x2E2E4B, 0x1A1A1A, 0xC9C9C9, 0x5F6570, 0xB114D3, 0x1E1E1E, 0x262626, 0x262626, 0x5C40FF, 0x333333, 0x404040, 0x222222, 0xD0353A, 0xA86B00, 0x1A7F37),
    mkTheme("ray-nuxt-dark",           true,  0x0B0C11, 0xBABED8, 0x80CBC4, 0x2C4143, 0x676E95, 0xC793EA, 0xBABED8, 0xC3E88D, 0xF78C6C, 0x82AAFF, 0x89DDFF, 0xBABED8, 0xF07178, 0xF07178, 0xE5B54A, 0xC3E88D),
    mkTheme("ray-nuxt-light",          false, 0xEAEAEC, 0x90A4AE, 0x80CBC4, 0xD3E3E3, 0x90A4AE, 0x39ADB5, 0x39ADB5, 0x91B859, 0xF76D47, 0x6182B8, 0x39ADB5, 0x90A4AE, 0xE53935, 0xE53935, 0xA86B00, 0x91B859),
    mkTheme("ray-browserbase-dark",    true,  0x000000, 0xFFFFFF, 0xFF4500, 0x471300, 0x98AFD3, 0xFF4500, 0xFF4500, 0xC4D600, 0xFF00FF, 0xFFFFFF, 0xC5D3E8, 0x00B0FF, 0xFF4500, 0xFF4500, 0xE5B54A, 0x00CB51),
    mkTheme("ray-browserbase-light",   false, 0xF8FAFC, 0x000000, 0xFF4500, 0xFAD2C5, 0x5A78AF, 0xFF4500, 0xFF4500, 0x0000CD, 0xFF00FF, 0x000000, 0x000000, 0x00B0FF, 0xFF4500, 0xFF4500, 0xA86B00, 0x00CB51),
    mkTheme("ray-cloudflare-dark",     true,  0x0C0C0C, 0xE8E8E8, 0xFF500A, 0x501F0B, 0x888888, 0xFF7F4D, 0x79B8FF, 0x0A95FF, 0x79B8FF, 0xB084FF, 0xAAAAAA, 0xFFB366, 0x79B8FF, 0xFF7F4D, 0xE5B54A, 0x00C853),
    mkTheme("ray-cloudflare-light",    false, 0xF5F5F5, 0x521000, 0xFF500A, 0xF7D1C1, 0xA3827A, 0xD94008, 0x5A11CC, 0x0876D9, 0x5A11CC, 0x7612CC, 0xA3827A, 0xC77700, 0x5A11CC, 0xD94008, 0xA86B00, 0x00C853),
    mkTheme("ray-gemini-dark",         true,  0x0E1016, 0xABB2BF, 0x5C9DC7, 0x243748, 0x5C6370, 0x5C9DC7, 0x56B6C2, 0x98C379, 0x56B6C2, 0x98C379, 0xABB2BF, 0xD19A66, 0x56B6C2, 0xE06C75, 0xE5B54A, 0x98C379),
    mkTheme("ray-gemini-light",        false, 0xFFFFFF, 0x37474F, 0xAEA8FF, 0xEDECFF, 0x666666, 0x1967D2, 0x37474F, 0x188038, 0x4C3FFF, 0x37474F, 0x37474F, 0x37474F, 0x4C3FFF, 0xFF605E, 0xA86B00, 0x188038),
    mkTheme("ray-stripe",              true,  0x0A2540, 0xFFFFFF, 0xFF6B35, 0x4F393D, 0xA9BCCE, 0x8095FF, 0xFFFFFF, 0xFFA956, 0xFFA956, 0x00D4FF, 0xFFFFFF, 0xFF6B35, 0x1ABDC0, 0xF87171, 0xE5B54A, 0x34D399),
    mkTheme("ray-bitmap-dark",         true,  0x170505, 0xFEFDFD, 0xE42B37, 0x501013, 0x996B6D, 0xEB6F6F, 0xE42B37, 0xE42B37, 0xE42B37, 0xE42B37, 0xEB6F6F, 0xC88E8E, 0xE42B37, 0xFF605E, 0xE5B54A, 0x00DE55),
    mkTheme("ray-bitmap-light",        false, 0xFCF4F4, 0x685B5B, 0xC90028, 0xF1BEC7, 0xB83737, 0xD63838, 0xC90028, 0x836250, 0xC94F0A, 0xC90028, 0xBE3B3B, 0x5E4040, 0xD15510, 0xFF605E, 0xA86B00, 0x00A67D),
    mkTheme("ray-noir-dark",           true,  0x0A0A0A, 0xFFFFFF, 0xA7A7A7, 0x363636, 0x666666, 0xA7A7A7, 0xA7A7A7, 0xA7A7A7, 0xFFFFFF, 0xFFFFFF, 0xA7A7A7, 0xA7A7A7, 0xA7A7A7, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-noir-light",          false, 0xF7F7F7, 0x111111, 0x666666, 0xD7D7D7, 0x999999, 0x666666, 0x666666, 0x666666, 0x111111, 0x111111, 0x666666, 0x666666, 0x666666, 0xD0353A, 0xA86B00, 0x1A7F37),
    mkTheme("ray-ice-dark",            true,  0x303C3D, 0xFFFFFF, 0x92DEF6, 0x4B6971, 0x5C6A70, 0xBFC4C9, 0x92DEF6, 0x92DEF6, 0x00B0E9, 0x778CB6, 0x778CB6, 0x92DEF6, 0x00B0E9, 0xFF605E, 0xE5B54A, 0x00B0E9),
    mkTheme("ray-ice-light",           false, 0xEFFBFC, 0x1C1B29, 0x00B0E9, 0xBAEAF8, 0xBDC0C1, 0x81909D, 0x00B0E9, 0x6ABAD8, 0x00B0E9, 0x1E3C78, 0x1E3C78, 0x00B0E9, 0x00B0E9, 0xFF605E, 0xA86B00, 0x00B0E9),
    mkTheme("ray-sand-dark",           true,  0x342C22, 0xFFFFFF, 0xF4A361, 0x6A4D34, 0x837E77, 0xD3B48C, 0xC2B181, 0xC2B181, 0xC2B181, 0xF4A361, 0xF4A361, 0xC2B181, 0xC2B181, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-sand-light",          false, 0xF3EBE1, 0x262217, 0xDA8744, 0xEED5BE, 0xC4B39C, 0x906937, 0xA28C4E, 0xA28C4E, 0xA28C4E, 0xDA8744, 0xDA8744, 0xA28C4E, 0xA28C4E, 0xFF605E, 0xA86B00, 0x1A7F37),
    mkTheme("ray-forest-dark",         true,  0x0E130F, 0xFFFFFF, 0x6B8F71, 0x28362A, 0x555E56, 0xAAB4A3, 0x6B8F71, 0xC9C8BC, 0xAAB4A3, 0x87B882, 0xAAB4A3, 0x6B8F71, 0xC9C7BC, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-forest-light",        false, 0xE9EBE9, 0x262217, 0x4B9442, 0xC6D8C4, 0x869288, 0x6A8458, 0x55725A, 0x828069, 0x78876E, 0x4B8042, 0x78876E, 0x6B8F71, 0x2E382F, 0xFF605E, 0xA86B00, 0x4B9442),
    mkTheme("ray-mono-dark",           true,  0x0A0A0A, 0xFFFFFF, 0xA7A7A7, 0x363636, 0x666666, 0xA7A7A7, 0xA7A7A7, 0xA7A7A7, 0xFFFFFF, 0xFFFFFF, 0xA7A7A7, 0xA7A7A7, 0xA7A7A7, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-mono-light",          false, 0xEAEAEA, 0x111111, 0x666666, 0xCDCDCD, 0x999999, 0x666666, 0x666666, 0x666666, 0x111111, 0x111111, 0x666666, 0x666666, 0x666666, 0xD0353A, 0xA86B00, 0x1A7F37),
    mkTheme("ray-breeze-dark",         true,  0x270E30, 0xFFFFFF, 0xECFEEF, 0x5E5165, 0x8A757D, 0x6599FF, 0x49E8F2, 0xE9AEFE, 0x55E7B2, 0xF8518D, 0xF8518D, 0x49E8F2, 0x49E8F2, 0xF8518D, 0xE5B54A, 0x00A67D),
    mkTheme("ray-breeze-light",        false, 0xF2E6F8, 0x434447, 0x625B6B, 0xD2C7D9, 0x8C828B, 0x496EB8, 0x0B7880, 0x886594, 0x24805E, 0xC44170, 0xC44170, 0x0B7880, 0x0B7880, 0xC44170, 0xA86B00, 0x00A67D),
    mkTheme("ray-candy-dark",          true,  0x322A3E, 0xFFFFFF, 0xFF659C, 0x6B3B58, 0x807796, 0xFF659C, 0x1AC8FF, 0xDFD473, 0x7A7FFD, 0x73DFA5, 0xFF659C, 0x1AC8FF, 0x1AC8FF, 0xFF605E, 0xE5B54A, 0x73DFA5),
    mkTheme("ray-candy-light",         false, 0xF1E9FE, 0x434447, 0xD15A8B, 0xEACAE5, 0x8D949B, 0xDC155E, 0x2286A6, 0xB2762E, 0x676DFF, 0x009033, 0xD15A8B, 0x2286A6, 0x2286A6, 0xFF605E, 0xA86B00, 0x009033),
    mkTheme("ray-crimson-dark",        true,  0x2E1313, 0xFEFDFD, 0xEB6F6F, 0x632D2D, 0x895E60, 0xEB6F6F, 0xD15510, 0xEBB99D, 0xFDA97A, 0xC88E8E, 0xEB6F6F, 0xD15510, 0xD15510, 0xEB6F6F, 0xE5B54A, 0x6FEB71),
    mkTheme("ray-crimson-light",       false, 0xF6E7E7, 0x685B5B, 0xBE3B3B, 0xEAC1C1, 0x978A8A, 0xBE3B3B, 0xC94F0A, 0x836250, 0xC94F0A, 0x9E7070, 0xBE3B3B, 0xC94F0A, 0xD15510, 0xBE3B3B, 0xA86B00, 0x00A67D),
    mkTheme("ray-falcon-dark",         true,  0x1E2328, 0xFFFFFF, 0x9AB6B2, 0x414C4F, 0x6D7E88, 0x9AB6B2, 0x799DB1, 0x6A8697, 0xBD9C9C, 0x6D88BB, 0x9AB6B2, 0x799DB1, 0x799DB1, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-falcon-light",        false, 0xE7EAEE, 0x464C65, 0x5C827D, 0xC8D3D5, 0x9DA4AD, 0x5C827D, 0x839AA7, 0x506483, 0xAE6A65, 0x6A7C9F, 0x5C827D, 0x839AA7, 0x839AA7, 0xD0353A, 0xA86B00, 0x1A7F37),
    mkTheme("ray-meadow-dark",         true,  0x1F2C19, 0xFFFFFF, 0x6DD79F, 0x355C3F, 0x708B6C, 0x6DD79F, 0xE4B165, 0xE9EB9D, 0x46B114, 0xB3D767, 0x6DD79F, 0xE4B165, 0xE4B165, 0xE4B165, 0xE5B54A, 0xB3D767),
    mkTheme("ray-meadow-light",        false, 0xE3EEDD, 0x54594D, 0x049649, 0xB2DBBC, 0x72806E, 0x049649, 0xB6781B, 0x837E50, 0x2C8801, 0x798B52, 0x049649, 0xB6781B, 0xB6781B, 0xB6781B, 0xA86B00, 0x049649),
    mkTheme("ray-midnight-dark",       true,  0x0E1D20, 0xFFFFFF, 0x7DA9AB, 0x2D4447, 0x4A4C56, 0x7DA9AB, 0x9681C2, 0x6D86A4, 0x75D2B1, 0x51D0F8, 0x7DA9AB, 0x9681C2, 0x9681C2, 0xFF605E, 0xE5B54A, 0x75D2B1),
    mkTheme("ray-midnight-light",      false, 0xE4ECEE, 0x434447, 0x5A797A, 0xC6D3D4, 0x78808C, 0x587678, 0x766599, 0x5F758F, 0x2D8264, 0x2F788F, 0x587678, 0x766599, 0x766599, 0xD0353A, 0xA86B00, 0x2D8264),
    mkTheme("ray-raindrop-dark",       true,  0x152434, 0xE4F2FF, 0x2ED9FF, 0x1C576D, 0x6C808B, 0x2ED9FF, 0x008BB7, 0x9DD8EB, 0x9984EE, 0x1AD6B5, 0x2ED9FF, 0x008BB7, 0x008BB7, 0x9984EE, 0xE5B54A, 0x2ED9FF),
    mkTheme("ray-raindrop-light",      false, 0xE1EBF7, 0x687077, 0x008DAC, 0xB0D6E6, 0x6E7780, 0x008DAC, 0x007BA1, 0x507683, 0x7459E1, 0x4F9488, 0x008DAC, 0x007BA1, 0x007BA1, 0x7459E1, 0xA86B00, 0x008DAC),
    mkTheme("ray-sunset-dark",         true,  0x402914, 0xFFFFFF, 0xFFAF65, 0x754F2B, 0x878572, 0xFFAF65, 0xE978A1, 0xF9D38C, 0xE7CF55, 0xE2D66B, 0xFFAF65, 0xE978A1, 0xE978A1, 0xE978A1, 0xE5B54A, 0xE7CF55),
    mkTheme("ray-sunset-light",        false, 0xFFE8D4, 0x737568, 0xA1642C, 0xEACBAF, 0x7A7055, 0xA1642C, 0xAD5A78, 0x8C703C, 0x856F00, 0x807410, 0xA1642C, 0xAD5A78, 0xAD5A78, 0xD0353A, 0xA86B00, 0x856F00),
    mkTheme("ray-firecrawl-dark",      true,  0x000000, 0xFFFFFF, 0xE97317, 0x412006, 0x666666, 0xA7A7A7, 0xE97317, 0xE97317, 0xFFFFFF, 0xE97317, 0xA7A7A7, 0xE97317, 0xA7A7A7, 0xFF605E, 0xE5B54A, 0x5FC992),
    mkTheme("ray-firecrawl-light",     false, 0xFFFFFF, 0x171717, 0x005FF2, 0xC7DCFC, 0x757575, 0x757575, 0xE97317, 0xE97317, 0xF97316, 0xE97317, 0x757575, 0xE97317, 0x757575, 0xE2162A, 0xA86B00, 0x009432),
    mkTheme("ray-aws-dark",            true,  0x151D26, 0xEDEDED, 0x9095E8, 0x373F5C, 0x91A2A7, 0xBBC2FF, 0xE0A4EE, 0x77C566, 0xF1B4FF, 0x43D5DC, 0xD0E1E7, 0x8CDEE2, 0x43D5DC, 0xEC7380, 0xE5B54A, 0x68B457),
    mkTheme("ray-aws-light",           false, 0xFFFFFF, 0x172428, 0x9095E8, 0xE7E8FA, 0x748389, 0x615ED6, 0xDC655F, 0x3A732C, 0xB76EC7, 0x007A85, 0x233035, 0x006267, 0x007A85, 0xD5455D, 0xA86B00, 0x499537),
    mkTheme("ray-auth0-dark",          true,  0x111217, 0xF1F1F1, 0x528BFF, 0x233458, 0x808080, 0xB59DF8, 0x99A7F1, 0x98D2B2, 0xB59DF8, 0x8B66F4, 0xFDE66F, 0xF1F1F1, 0xB9C3F5, 0xEA976A, 0xE5B54A, 0x98D2B2),
    mkTheme("ray-auth0-light",         false, 0xEBEAEC, 0x252733, 0x528BFF, 0xC9D5F0, 0x8C8C96, 0x7C5CE0, 0x5E72E4, 0x2F946F, 0x7C5CE0, 0x5A37C8, 0xBE9A24, 0x252733, 0x7383E8, 0xD27A55, 0xA86B00, 0x2F946F),
  ]

var themeCache: seq[Theme]

var inkScreen = false      # the theme in use is black and white only (e-ink): flushScreen sends every cell in them

proc inkOf(c: Rgb): Rgb {.inline.} =
  ## black or white, whichever the colour is nearer (by its luma: a grey mixed half way goes either side evenly)
  if c == NoColor: return c
  let luma = (((c shr 16) and 0xFF) * 2126 + ((c shr 8) and 0xFF) * 7152 + (c and 0xFF) * 722) div 10000
  if luma >= 128: 0xFFFFFF'u32 else: 0x000000'u32

proc inkCell(c: var Cell) {.inline.} =
  ## a cell as an e-ink theme sends it: its colours black or white — the shades other parts of ned mix (a hover, a
  ## fading highlight, a picture) become one or the other — faint text (a grey on the screen) plain, and text that
  ## would vanish into its own colour (on the selection, a find match, a menu's row) in the other one: inverted
  c.fg = inkOf(c.fg)
  c.bg = inkOf(c.bg)
  c.at.excl aDim
  if c.fg == c.bg and c.fg != NoColor: c.fg = (if c.bg == 0xFFFFFF'u32: 0x000000'u32 else: 0xFFFFFF'u32)
  if c.fg == c.bg and c.bg != NoColor and c.ch != 32 and c.ch != 0 and (c.ch < 0x2580 or c.ch > 0x259F):
    c.fg = c.bg xor 0xFFFFFF'u32         # (not the block elements: drawn in their own colour on purpose)

proc luminance(c: Rgb): float =
  ## how bright a colour looks, from 0 (black) to 1 (white): each channel in linear light, weighted by how bright the
  ## eye finds red, green and blue (the WCAG formula)
  proc ch(v: uint32): float =
    ## a channel (0 to 255) as linear light, 0 to 1: the sRGB curve undone
    let x = float(v) / 255.0
    if x <= 0.03928: x / 12.92 else: pow((x + 0.055) / 1.055, 2.4)
  0.2126 * ch((c shr 16) and 0xFF) + 0.7152 * ch((c shr 8) and 0xFF) + 0.0722 * ch(c and 0xFF)

proc contrast(a, b: Rgb): float =
  ## the contrast ratio of two colours, from 1 (the same) to 21 (black on white), whichever is the lighter (the WCAG
  ## formula)
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
  if isInk(t): return        # (black and white only: a colour moved towards the other would be a grey)
  for b in [t.bg, t.dockBg, t.crumbBg, t.menuBg, t.statusBg]: t.dim = readableOn(t.dim, b, 3.2)
  t.gutter = readableOn(t.gutter, t.bg, 2.2)
  t.inlay = readableOn(t.inlay, t.bg, 2.6)
  t.syn[tkComment] = readableOn(t.syn[tkComment], t.bg, 2.8)
  t.syn[tkDoc] = readableOn(t.syn[tkDoc], t.bg, 2.8)
  # (6.38) the code's own colours too, at 3:1: a few light themes as their authors made them (Ayu Light, Everforest
  # Light, Catppuccin Latte, Solarized Light, Rosé Pine Dawn) have strings, functions or warnings near 2:1, which
  # vanish on a tablet in daylight; the hue stays, only a little darker. A faded deprecated name stays faded
  for tk in TokKind:
    if tk notin {tkComment, tkDoc, tkDeprecated}: t.syn[tk] = readableOn(t.syn[tk], t.bg, 3.0)
  for c in [addr t.err, addr t.warn, addr t.info, addr t.hint]: c[] = readableOn(c[], t.bg, 3.0)
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
  ## every theme: the built-in ones made readable, then the user's from the themes folder. Made the first time and kept
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
  result.boldKw = t0.boldKw                  # (a theme that tells keywords apart by weight keeps it)
  if isInk(result): result = result.inked    # (still black and white only: e-ink)
  makeReadable(result)
  if colors != nil and colors.kind == JObject and colors{"ruler"} != nil and colors{"ruler"}.kind == JString:
    let rc = parseColor(colors{"ruler"}.getStr, result.bg)
    if rc >= 0: result.ruler = Rgb(rc)

proc themeFromJson(j: JsonNode, fallbackName: string): (bool, Theme) =
  ## a theme file: {"name": "…", "base": "a built-in theme", "dark": true, "colors": {"bg": "#…", …}}
  if j == nil or j.kind != JObject: return
  let name = j{"name"}.getStr(fallbackName).strip.toLowerAscii.replace(' ', '-')
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
  if j{"boldKeywords"} != nil and j{"boldKeywords"}.kind == JBool: start.boldKw = j{"boldKeywords"}.getBool
  (true, rebuildTheme(start, cs))

proc reloadThemes()

# the folder of the user's own theme files: `ned/themes` in the config folder (XDG_CONFIG_HOME, else ~/.config)
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

const ThemeAliases = [("molokai", "monokai"), ("catppuccin-macchiato", "catppuccin-mocha"),
                      ("catppuccin-frappe", "catppuccin-mocha"), ("github-dark-dimmed", "github-dark"),
                      ("slate-night", "slate"), ("nebula-void", "slate"),
                      ("gruvbox-material", "gruvbox-material-dark"), ("flexoki", "flexoki-dark"),
                      ("melange", "melange-dark"), ("synthwave", "synthwave-84"), ("palenight", "material-palenight"),
                      ("horizon-dark", "horizon"), ("ray-vercel", "ray-vercel-dark"),
                      ("ray-rabbit", "ray-rabbit-dark"), ("ray-supabase", "ray-supabase-dark"),
                      ("ray-tailwind", "ray-tailwind-dark"), ("ray-openai", "ray-openai-dark"),
                      ("ray-mintlify", "ray-mintlify-dark"), ("ray-prisma", "ray-prisma-dark"),
                      ("ray-clerk", "ray-clerk-dark"), ("ray-elevenlabs", "ray-elevenlabs-dark"),
                      ("ray-resend", "ray-resend-dark"), ("ray-triggerdev", "ray-triggerdev-dark"),
                      ("ray-nuxt", "ray-nuxt-dark"), ("ray-browserbase", "ray-browserbase-dark"),
                      ("ray-cloudflare", "ray-cloudflare-dark"), ("ray-gemini", "ray-gemini-dark"),
                      ("ray-bitmap", "ray-bitmap-dark"), ("ray-noir", "ray-noir-dark"), ("ray-ice", "ray-ice-dark"),
                      ("ray-sand", "ray-sand-dark"), ("ray-forest", "ray-forest-dark"), ("ray-mono", "ray-mono-dark"),
                      ("ray-breeze", "ray-breeze-dark"), ("ray-candy", "ray-candy-dark"),
                      ("ray-crimson", "ray-crimson-dark"), ("ray-falcon", "ray-falcon-dark"),
                      ("ray-meadow", "ray-meadow-dark"), ("ray-midnight", "ray-midnight-dark"),
                      ("ray-raindrop", "ray-raindrop-dark"), ("ray-sunset", "ray-sunset-dark"),
                      ("ray-firecrawl", "ray-firecrawl-dark"), ("ray-aws", "ray-aws-dark"),
                      ("ray-auth0", "ray-auth0-dark")]
  ## (6.30: themes that were another one under another name — or nearly: a setting naming one gets that one; 6.39:
  ## the short names other editors give the themes added then; 6.41: ray-<name>, the dark one of a ray.so pair)

proc themeAlias(name: string): string =
  ## the theme an old name stands for (see ThemeAliases), empty when the name is not one of them
  for (a, b) in ThemeAliases:
    if a == name: return b

proc trueBlackOn(): bool

proc onBlack(c, bg: Rgb): Rgb =
  ## a surface's colour moved onto true black: what lifted it above the theme's background stays (a little more,
  ## so it still shows), what was darker becomes black
  for sh in [16'u32, 8, 0]:
    let v = int((c shr sh) and 0xFF) - int((bg shr sh) and 0xFF)
    result = result or (Rgb(clamp(int(float(v) * 1.6), 0, 255)) shl sh)

proc trueBlackOf(t0: Theme): Theme =
  ## theme.trueBlack: a dark theme on an OLED screen — the editor and its bars on true black (the pixels off), the
  ## popups, the current line and the hover a lift above it; the text, the syntax and the selection keep their colours
  result = t0
  let bg = t0.bg
  result.bg = 0
  result.tabActiveBg = 0
  for f in [addr result.curLine, addr result.statusBg, addr result.tabBg, addr result.popupBg, addr result.panelBg,
            addr result.stickyBg, addr result.titleBg, addr result.dockBg, addr result.dockHeadBg, addr result.tabBarBg,
            addr result.hoverBg, addr result.inputBg, addr result.menuBg, addr result.toastBg, addr result.codeBg,
            addr result.crumbBg, addr result.splitBar, addr result.shadow, addr result.btnBg, addr result.userBg]:
    f[] = onBlack(f[], bg)
  makeReadable(result)

proc themeNamed(name: string): (bool, Theme) =
  ## the theme of that name (an old name counts as the new one) as (true, theme), or (false, an empty theme) when there
  ## is none
  let n = if themeAlias(name).len > 0: themeAlias(name) else: name
  for t in allThemes():
    if t.name == n: return (true, t)

proc clockMinutes(s: string, def: int): int =
  ## "07:30", "7", "19:05" → minutes after midnight (`def` when it is not a time)
  let p = s.strip.split(':')
  try:
    let h = parseInt(p[0].strip)
    let m = if p.len > 1: parseInt(p[1].strip) else: 0
    if h in 0 .. 24 and m in 0 .. 59: return (h * 60 + m) mod 1440
  except ValueError: discard
  def

proc isDaytime(): bool =
  ## by the clock: between theme.dayStarts and theme.nightStarts
  let dn = settingNode("theme.dayStarts")
  let nn = settingNode("theme.nightStarts")
  let day = clockMinutes(if dn != nil and dn.kind == JString: dn.getStr else: "", 7 * 60)
  let night = clockMinutes(if nn != nil and nn.kind == JString: nn.getStr else: "", 19 * 60)
  let t = times.now()
  let m = t.hour * 60 + t.minute
  if day == night: return true
  if day < night: m >= day and m < night
  else: m >= day or m < night

proc autoByClock(): bool =
  ## whether theme.autoBy is "clock": "auto" then follows the time of day and not the terminal's background
  let n = settingNode("theme.autoBy")
  n != nil and n.kind == JString and n.getStr == "clock"

proc autoWantsLight(): bool =
  ## "theme": "auto" — light by the clock (theme.autoBy: "clock") or by the terminal's background
  if autoByClock(): isDaytime() else: termBgKnown and termBgLight

proc applyTheme(name: string) =
  ## a theme by name ("auto": the light or dark one that matches the terminal, or the time of day), with your
  ## colour overrides
  defer: inkScreen = isInk(theme)
  var want = name
  if name == "auto":
    let light = autoWantsLight()
    let pick = settingNode(if light: "theme.light" else: "theme.dark")
    want = if pick != nil and pick.kind == JString: pick.getStr else: (if light: "github-light" else: "nim-crown")
  let (ok, t) = themeNamed(want)
  if ok:
    let ov = themeOverrides(t.name)
    theme = if ov != nil: rebuildTheme(t, ov) else: t
    if theme.dark and trueBlackOn(): theme = trueBlackOf(theme)
    cfgThemeName = name
    return
  for t in allThemes():          # an unknown name: the default theme
    if t.name == "nim-crown":
      theme = t
      cfgThemeName = t.name
      return
  theme = allThemes()[0]
  cfgThemeName = theme.name

proc trueBlackOn(): bool =
  ## whether theme.trueBlack is turned on
  let n = settingNode("theme.trueBlack")
  n != nil and n.kind == JBool and n.getBool
