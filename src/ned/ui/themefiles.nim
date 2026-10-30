# ── themes: the terminal's background (auto), your own theme files, importing VS Code and base16 themes ──

proc handleTermBg() =
  ## OSC 11 answer "rgb:RRRR/GGGG/BBBB": light or dark terminal, for "theme": "auto"
  let r = oscBgReply
  oscBgReply = ""
  let p = r.find("rgb:")
  if p < 0: return
  let parts = r[p + 4 .. ^1].strip(chars = {'\a', '\e', '\\', ' '}).split('/')
  if parts.len < 3: return
  var ch: array[3, int]
  for i in 0 .. 2:
    var h = parts[i]
    if h.len == 0: return
    for c in h:
      if c notin HexDigits: return
    h = (h & h)[0 .. 1]                        # 1–4 hex digits: the top byte
    ch[i] = parseHexInt(h)
  termBgKnown = true
  termBgLight = luminance(Rgb((ch[0] shl 16) or (ch[1] shl 8) or ch[2])) > 0.25
  if cfgThemeName == "auto" and not autoByClock():
    applyTheme("auto")
    themeFollowers()
    prevGrid.setLen(0)
    needRender = true

proc handleTermScheme() =
  ## mode 2031: the terminal (or the system) switched between light and dark — "theme": "auto" follows at once
  tcSchemeNews = false
  if tcScheme notin [1, 2]: return
  writeAll("\e]11;?\a")                    # (and its new background colour: handleTermBg reads the answer)
  let light = tcScheme == 2
  if termBgKnown and termBgLight == light: return
  termBgKnown = true
  termBgLight = light
  if cfgThemeName == "auto" and not autoByClock():
    applyTheme("auto")
    themeFollowers()
    prevGrid.setLen(0)
    needRender = true

var lastDaytime = -1         # theme.autoBy "clock": light (1) or dark (0) at the last look

proc themeClockCheck() =
  ## every few seconds: "theme": "auto" by the clock switches at theme.dayStarts and theme.nightStarts
  if cfgThemeName != "auto" or not autoByClock():
    lastDaytime = -1
    return
  let d = ord(isDaytime())
  if d == lastDaytime: return
  let first = lastDaytime < 0
  lastDaytime = d
  if first: return                            # (applied when the settings were)
  applyTheme("auto")
  themeFollowers()
  prevGrid.setLen(0)
  needRender = true
  info((if d == 1: "Day: the light theme, " else: "Night: the dark theme, ") & theme.name)

proc refreshThemeChoices() =
  ## the settings' lists of themes, after adding one
  for key in ["theme", "theme.dark", "theme.light"]:
    let i = setIndex.getOrDefault(key, -1)
    if i >= 0: setDefs[i].opts = allThemeNames() & (if key == "theme": @["auto"] else: @[])

proc reloadThemes() =
  ## forgets the cached themes and reads them again (a theme file added or changed), applies the current theme and
  ## redraws the whole screen
  themeCache.setLen(0)
  refreshThemeChoices()
  applyTheme(cfgThemeName)
  prevGrid.setLen(0)
  needRender = true
  info("Themes reloaded")

# the colour as #rrggbb
func hexOf(c: Rgb): string = "#" & toHex(int(c), 6)

proc themeJson(t: Theme): JsonNode =
  ## a theme as a file you can edit: ~/.config/ned/themes/<name>.json
  result = %*{"name": t.name, "dark": t.dark}
  var cs = newJObject()
  for i, k in ThemeKeys: cs[k] = %hexOf(t.base[i])
  let ch = if t.hasChrome: t.chromeCols else: [t.titleBg, t.dockBg, t.statusBg]
  for i, k in ChromeKeys: cs[k] = %hexOf(ch[i])
  cs["ruler"] = %hexOf(t.ruler)
  result["colors"] = cs

func themeSlug(s: string): string =
  ## a theme name that is also a safe file name: lower case, letters, digits, - and _
  for c in s.toLowerAscii:
    if c in {'a'..'z', '0'..'9', '_'}: result.add c
    elif result.len > 0 and result[^1] != '-': result.add '-'
  result = result.strip(chars = {'-'})
  if result.len == 0: result = "my-theme"

proc saveThemeFile(j: JsonNode): string =
  ## writes a theme (JSON) into the themes folder as <name>.json, the name made a safe file name, and gives back the
  ## path
  let name = themeSlug(j{"name"}.getStr)
  createDir(themesDir())
  result = themesDir() / (name & ".json")
  writeFile(result, j.pretty & "\n")

# ── Termux: the whole terminal in ned's colours — ~/.termux/colors.properties written from the theme. Colours of
#    your own are kept beside it (colors.properties.ned-backup) and put back by "Theme: put Termux's own colours
#    back" ──

const TermuxMark = "# written by ned"

# the file where Termux reads its terminal colours
proc termuxColorsFile(): string = getHomeDir() / ".termux" / "colors.properties"

proc termuxColorsText(t: Theme): string =
  ## Termux's colours: background, foreground, cursor, the 16 ANSI colours — the theme's own
  result = TermuxMark & ", from its theme " & t.name & " — palette › Theme: put Termux's own colours back\n"
  result.add "background=" & hexOf(t.bg) & "\n"
  result.add "foreground=" & hexOf(t.fg) & "\n"
  result.add "cursor=" & hexOf(readableOn(t.accent, t.bg, 3.0)) & "\n"
  for i in 0 .. 15: result.add "color" & $i & "=" & hexOf(t.ansi[i]) & "\n"

proc termuxReload() =
  ## Termux reads the file again (the termux-reload-settings command; without it, on the next session)
  if haveExe("termux-reload-settings"):
    discard startJob(jkAux, "termux-reload-settings >/dev/null 2>&1", getHomeDir())

proc termuxWriteColors(quiet: bool): bool =
  ## the theme's colours into Termux; your own colours kept once beside them. false: could not
  let f = termuxColorsFile()
  let text = termuxColorsText(theme)
  try:
    if fileExists(f):
      let cur = readFile(f)
      if cur == text: return true
      if not cur.startsWith(TermuxMark): copyFile(f, f & ".ned-backup")    # (colours of your own: kept)
    else: createDir(parentDir(f))
    writeFileSafe(f, text)
  except CatchableError as e:
    if not quiet: error("Cannot write " & tildePath(f) & ": " & e.msg)
    return false
  termuxReload()
  true

proc themeFollowers() =
  ## after the theme changed: Termux follows it, when you asked for that
  if sBool("theme.termuxColors") and isTermux(): discard termuxWriteColors(quiet = true)

proc cmdTermuxColors() =
  ## writes the theme's colours into Termux (only in Termux), and — unless theme.termuxColors already keeps it matching
  ## — offers in a message to keep doing so
  if not isTermux():
    info("This is for Termux (Android): it writes ~/.termux/colors.properties from the theme — this is not Termux")
    return
  if not termuxWriteColors(quiet = false): return
  if sBool("theme.termuxColors"):
    info("Termux has the " & theme.name & " colours")
    return
  toast("Termux has the " & theme.name & " colours now (yours are kept: Theme › put Termux's own colours back)", 3,
        "Keep matching", proc() =
    setSetting("theme.termuxColors", %true)
    info("Termux follows ned's theme from now on"), 15000)

proc cmdTermuxRestore() =
  ## Termux's colours as they were before ned wrote them
  let f = termuxColorsFile()
  let bak = f & ".ned-backup"
  if sBool("theme.termuxColors"): setSetting("theme.termuxColors", %false)
  try:
    if fileExists(bak):
      moveFile(bak, f)
      info("Termux has your own colours again")
    elif fileExists(f) and readFile(f).startsWith(TermuxMark):
      removeFile(f)
      info("Termux has its default colours again")
    else:
      info("Termux's colours are not ned's — nothing to put back")
      return
  except CatchableError as e:
    error("Cannot put Termux's colours back: " & e.msg)
    return
  termuxReload()

func stripJsonc(s: string): string =
  ## VS Code's theme files are JSON with comments and trailing commas
  result = newStringOfCap(s.len)
  var i = 0
  var inStr = false
  while i < s.len:
    let c = s[i]
    if inStr:
      result.add c
      if c == '\\' and i + 1 < s.len:
        result.add s[i + 1]
        i += 2
        continue
      if c == '"': inStr = false
      inc i
    elif c == '"':
      inStr = true
      result.add c
      inc i
    elif c == '/' and i + 1 < s.len and s[i + 1] == '/':
      while i < s.len and s[i] != '\n': inc i
    elif c == '/' and i + 1 < s.len and s[i + 1] == '*':
      let e = s.find("*/", i + 2)
      i = if e < 0: s.len else: e + 2
    elif c == ',':
      var j = i + 1
      while j < s.len and s[j] in Whitespace: inc j
      if j < s.len and s[j] in {'}', ']'}: inc i       # a trailing comma
      else:
        result.add c
        inc i
    else:
      result.add c
      inc i

proc vscodeTheme(j: JsonNode, fallbackName: string): JsonNode =
  ## a VS Code colour theme → ned's theme file
  let c = j{"colors"}
  proc pick(keys: openArray[string]): string =
    ## the value of the first of these colour keys that the VS Code theme sets, else an empty string
    if c == nil or c.kind != JObject: return ""
    for k in keys:
      if c{k} != nil and c{k}.kind == JString and c{k}.getStr.len > 0: return c{k}.getStr
    ""
  var cs = newJObject()
  proc put(k, v: string) =
    ## sets ned's colour k to v in the theme being built, unless v is empty
    if v.len > 0: cs[k] = %v
  put("bg", pick(["editor.background"]))
  put("fg", pick(["editor.foreground", "foreground"]))
  put("selection", pick(["editor.selectionBackground", "editor.selectionHighlightBackground"]))
  put("accent", pick(["focusBorder", "button.background", "activityBarBadge.background", "textLink.foreground"]))
  put("error", pick(["editorError.foreground", "errorForeground", "terminal.ansiRed"]))
  put("warning", pick(["editorWarning.foreground", "list.warningForeground", "terminal.ansiYellow"]))
  put("ok", pick(["gitDecoration.addedResourceForeground", "terminal.ansiGreen"]))
  put("titleBar", pick(["titleBar.activeBackground"]))
  put("dock", pick(["sideBar.background"]))
  put("statusBar", pick(["statusBar.background"]))
  const cats = [("comment", @["comment", "punctuation.definition.comment"]),
                ("keyword", @["keyword.control", "keyword", "storage.type", "storage", "storage.modifier"]),
                ("type", @["entity.name.type", "support.type", "entity.name.class", "support.class", "storage.type"]),
                ("string", @["string", "string.quoted"]),
                ("number", @["constant.numeric", "constant", "constant.language"]),
                ("function", @["entity.name.function", "support.function", "meta.function-call"]),
                ("operator", @["keyword.operator", "punctuation"]),
                ("macro", @["entity.name.function.macro", "meta.preprocessor", "keyword.control.directive",
                            "entity.name.tag"]),
                ("property", @["variable.other.property", "support.variable.property",
                               "variable.other.object.property", "meta.object-literal.key", "variable.other.member"])]
  var best = initTable[string, (int, string)]()
  let tcs = j{"tokenColors"}
  if tcs != nil and tcs.kind == JArray:
    for e in tcs:
      let fgc = e{"settings"}{"foreground"}.getStr("")
      if fgc.len == 0: continue
      var scopes: seq[string]
      let sc = e{"scope"}
      if sc != nil and sc.kind == JString:
        for s in sc.getStr.split(','): scopes.add s.strip
      elif sc != nil and sc.kind == JArray:
        for s in sc: scopes.add s.getStr.strip
      for s in scopes:
        for (cat, cands) in cats:
          for ri, cand in cands:
            if s == cand or s.startsWith(cand & "."):
              if cat == "keyword" and s.startsWith("keyword.operator"): continue
              let rank = ri * 2 + (if s == cand: 0 else: 1)
              if cat notin best or rank < best[cat][0]: best[cat] = (rank, fgc)
  for cat, (_, col) in best: cs[cat] = %col
  result = %*{"name": j{"name"}.getStr(fallbackName), "colors": cs}
  let ty = j{"type"}.getStr("")
  if ty == "light": result["dark"] = %false
  elif ty in ["dark", "hc", "hc-black"]: result["dark"] = %true

proc base16Theme(text, fallbackName: string): JsonNode =
  ## a base16 scheme (YAML or JSON: base00 … base0F) → ned's theme file
  var b = initTable[string, string]()
  var name = fallbackName
  for raw in text.splitLines:
    let l = raw.strip(chars = Whitespace + {',', '{', '}'})
    let c = l.find(':')
    if c < 0: continue
    let k = l[0 ..< c].strip(chars = Whitespace + {'"', '\''})
    var v = l[c + 1 .. ^1].strip(chars = Whitespace + {'"', '\'', ','})
    if k in ["scheme", "name"] and v.len > 0: name = v
    elif k.len == 6 and k.startsWith("base0"):
      if v.startsWith("#"): v = v[1 .. ^1]
      if v.len >= 6: b[k.toLowerAscii] = "#" & v[0 .. 5]
  if b.len < 16: return nil
  let m = [("bg", "base00"), ("dock", "base01"), ("statusBar", "base01"), ("selection", "base02"),
           ("comment", "base03"), ("fg", "base05"), ("error", "base08"), ("property", "base08"),
           ("number", "base09"), ("type", "base0a"), ("warning", "base0a"), ("string", "base0b"), ("ok", "base0b"),
           ("operator", "base0c"), ("function", "base0d"), ("accent", "base0d"), ("keyword", "base0e"),
           ("macro", "base0f")]
  var cs = newJObject()
  for (k, bk) in m: cs[k] = %b[bk]
  %*{"name": name, "colors": cs}

proc importTheme(path: string) =
  ## turns a theme file into one of ned's: a base16 scheme, a VS Code colour theme (comments and trailing commas
  ## allowed) or a theme already in ned's format. It is saved in the themes folder under its name (with -imported added
  ## if that is taken), then applied and made the theme setting.
  let p = absolutePath(expandTilde(path))
  var text = ""
  try: text = readFile(p)
  except CatchableError as e:
    error("Cannot read " & path & ": " & e.msg)
    return
  let fallback = themeSlug(splitFile(p).name.toLowerAscii.replace("-color-theme", ""))
  var tj: JsonNode = nil
  if "base00" in text and "base0F".toLowerAscii in text.toLowerAscii: tj = base16Theme(text, fallback)
  else:
    try:
      let j = parseJson(stripJsonc(text))
      if j{"tokenColors"} != nil or (j{"colors"} != nil and j{"colors"}{"editor.background"} != nil):
        tj = vscodeTheme(j, fallback)
      elif j{"colors"} != nil:
        tj = j                                    # already ned's format
    except CatchableError as e:
      error("Not a theme file ned knows (VS Code .json, base16 .yaml/.json): " & e.msg)
      return
  if tj == nil or tj{"colors"} == nil or tj{"colors"}.len == 0:
    error("No colours found in " & path & " — VS Code .json and base16 .yaml/.json themes can be imported")
    return
  var name = themeSlug(tj{"name"}.getStr(fallback))
  for t in allThemesRaw():
    if t.name == name: name.add "-imported"
  tj["name"] = %name
  try:
    let f = saveThemeFile(tj)
    reloadThemes()
    applyTheme(name)
    setSetting("theme", %name)
    info("Imported the theme " & name & " → " & tildePath(f) & " (edit it there, Ctrl+S shows the change)")
  except CatchableError as e:
    error("Cannot save the theme: " & e.msg)

proc askText(label, initial: string, cb: proc(t: string)) =
  ## a one-line question; `cb` gets the answer (not called for an empty one)
  gitPromptCb = cb
  openPrompt(pGitInput, label, initial)

proc askPath(label, initial: string, cb: proc(t: string)) =
  ## a prompt for a file or folder (Tab completes)
  gitPromptCb = cb
  openPrompt(pPathInput, label, initial)

# ── the theme editor: every colour of the theme with a swatch and how readable it is (WCAG contrast); pick one to
#    type a new colour, make it lighter or darker, or readable — saved in your copy of the theme, shown at once ──

const ThemeEditKeys = ["fg", "bg", "comment", "keyword", "type", "string", "number", "function", "operator", "macro",
                       "property", "accent", "selection", "error", "warning", "ok", "titleBar", "dock", "statusBar", "ruler"]

proc themeKeyColor(t: Theme, k: string): Rgb =
  ## the theme's colour for one key of the theme editor: a syntax or base colour, a chrome colour (title bar, dock,
  ## status bar), else the ruler's
  let i = ThemeKeys.find(k)
  if i >= 0: return t.base[i]
  let j = ChromeKeys.find(k)
  if j >= 0: return (if t.hasChrome: t.chromeCols[j] else: [t.titleBg, t.dockBg, t.statusBg][j])
  t.ruler

# true for a key that is a background (text is read on it) rather than a foreground colour
func themeKeyIsBack(k: string): bool = k in ["bg", "selection", "titleBar", "dock", "statusBar"]

proc themeContrast(t: Theme, k: string): (float, float, string) =
  ## (the contrast, the least that reads well, what it is measured against)
  let c = themeKeyColor(t, k)
  let bg = t.base[0]
  let fg = t.base[1]
  case k
  of "bg", "fg": (contrast(fg, bg), 4.5, "text on the background")
  of "selection", "titleBar", "dock", "statusBar": (contrast(fg, c), 4.5, "text on it")
  of "comment": (contrast(c, bg), 3.0, "on the background")
  of "ruler": (contrast(c, bg), 1.3, "on the background")
  else: (contrast(c, bg), 3.0, "on the background")

proc themeFileOf(name: string): string =
  ## the file of one of your themes (~/.config/ned/themes), "" for a built-in one
  if not dirExists(themesDir()): return ""
  try:
    for kind, p in walkDir(themesDir()):
      if kind notin {pcFile, pcLinkToFile} or not p.endsWith(".json"): continue
      try:
        let (ok, th) = themeFromJson(parseFile(p), splitFile(p).name)
        if ok and th.name == name: return p
      except CatchableError: discard
  except OSError: discard
  ""

proc themeEditFile(): string =
  ## the theme's file to change: your own theme's, or a copy of a built-in one (<name>-mine), put in use
  var builtin = false
  for t in allThemesRaw():
    if t.name == theme.name: builtin = true
  if not builtin:
    let f = themeFileOf(theme.name)
    if f.len > 0: return f
  var j = themeJson(theme)
  var name = theme.name
  if not name.endsWith("-mine"): name.add "-mine"
  j["name"] = %name
  result = themeFileOf(name)
  if result.len == 0: result = saveThemeFile(j)
  themeCache.setLen(0)
  refreshThemeChoices()
  if cfgThemeName == "auto": setSetting(if theme.dark: "theme.dark" else: "theme.light", %name)
  else: setSetting("theme", %name)
  info("Changing your copy of the theme: " & name & " (" & tildePath(result) & ")")

proc cmdThemeEditor(at = "")

proc themeSetColor(k: string, c: Rgb) =
  ## one colour of your theme changed: written, applied, the editor shown again
  let f = themeEditFile()
  try:
    let j = parseFile(f)
    if j{"colors"} == nil or j{"colors"}.kind != JObject: j["colors"] = newJObject()
    j["colors"][k] = %hexOf(c)
    writeFileSafe(f, j.pretty & "\n")
  except CatchableError as e:
    error("Cannot change the theme file: " & e.msg)
    return
  for b in bufs:
    if b.path == f and not b.dirty: reloadBuffer(b)
  themeCache.setLen(0)
  applyTheme(cfgThemeName)
  themeFollowers()
  prevGrid.setLen(0)
  needRender = true
  cmdThemeEditor(k)

proc themeKeyMenu(k: string) =
  ## the menu for one colour of the theme editor: type a new value, make it readable (when its contrast is too low),
  ## lighter, darker, as in the theme this is a copy of, or back to the list. Each change goes through themeSetColor.
  let c = themeKeyColor(theme, k)
  let (r, want, what) = themeContrast(theme, k)
  var items: seq[(string, string, Action)]
  items.add act("Type a colour…", "#rrggbb", proc() =
    askText(k & " — a colour (#rrggbb)", hexOf(c), proc(t: string) =
      let v = parseColor(t, theme.base[0])
      if v < 0: error("Not a colour: " & t & " (#rrggbb)")
      else: themeSetColor(k, Rgb(v))))
  if r < want:
    let fixed = if themeKeyIsBack(k): bgUnder(c, theme.base[1], want) else: readableOn(c, theme.base[0], want)
    items.add act("Make it readable", hexOf(fixed) & " · " & formatFloat(want, ffDecimal, 1) & ":1", proc() =
      themeSetColor(k, fixed))
  items.add act("Lighter", "", proc() = themeSetColor(k, blend(c, 0xFFFFFF'u32, 0.12)))
  items.add act("Darker", "", proc() = themeSetColor(k, blend(c, 0x000000'u32, 0.12)))
  var orig = theme.name
  if orig.endsWith("-mine"): orig.setLen(orig.len - 5)
  let (found, ot) = themeNamed(orig)
  if found and orig != theme.name and themeKeyColor(ot, k) != c:
    let oc = themeKeyColor(ot, k)
    items.add act("As in " & orig, hexOf(oc), proc() = themeSetColor(k, oc))
  items.add act("Back to the list", "", proc() = cmdThemeEditor(k))
  openActions(k & "  " & hexOf(c) & " — " & formatFloat(r, ffDecimal, 1) & ":1 " & what, items)
  pickSwatches = @[]

proc themeKeyAct(k: string): Action =
  ## the action that opens the menu of colour k (a proc of its own so each row of a loop gets its own key)
  result = proc() = themeKeyMenu(k)

proc cmdThemeEditor(at = "") =
  ## the colours of the theme in use: a swatch, the value, its contrast — hard-to-read ones marked
  var items: seq[(string, string, Action)]
  var sw: seq[int]
  var weak = 0
  var sel = 0
  for k in ThemeEditKeys:
    let c = themeKeyColor(theme, k)
    let (r, want, _) = themeContrast(theme, k)
    let low = r < want
    if low: inc weak
    if k == at: sel = items.len
    items.add act((if low: "⚠ " else: "") & k & (if low: " — hard to read" else: ""),
                  hexOf(c) & "  " & formatFloat(r, ffDecimal, 1) & ":1", themeKeyAct(k))
    sw.add int(c)
  openActions("Theme editor — " & theme.name & (if weak > 0: " · " & $weak & " hard to read" else: " · all readable"),
              items)
  pickSwatches = sw
  if sel > 0 and sel < pickShown.len: pickSel = sel
