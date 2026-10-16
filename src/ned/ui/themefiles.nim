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
  if cfgThemeName == "auto":
    applyTheme("auto")
    prevGrid.setLen(0)
    needRender = true

proc refreshThemeChoices() =
  ## the settings' lists of themes, after adding one
  for key in ["theme", "theme.dark", "theme.light"]:
    let i = setIndex.getOrDefault(key, -1)
    if i >= 0: setDefs[i].opts = allThemeNames() & (if key == "theme": @["auto"] else: @[])

proc reloadThemes() =
  themeCache.setLen(0)
  refreshThemeChoices()
  applyTheme(cfgThemeName)
  prevGrid.setLen(0)
  needRender = true
  info("Themes reloaded")

proc hexOf(c: Rgb): string = "#" & toHex(int(c), 6)

proc themeJson(t: Theme): JsonNode =
  ## a theme as a file you can edit: ~/.config/ned/themes/<name>.json
  result = %*{"name": t.name, "dark": t.dark}
  var cs = newJObject()
  for i, k in ThemeKeys: cs[k] = %hexOf(t.base[i])
  let ch = if t.hasChrome: t.chromeCols else: [t.titleBg, t.dockBg, t.statusBg]
  for i, k in ChromeKeys: cs[k] = %hexOf(ch[i])
  cs["ruler"] = %hexOf(t.ruler)
  result["colors"] = cs

proc themeSlug(s: string): string =
  ## a theme name that is also a safe file name: lower case, letters, digits, - and _
  for c in s.toLowerAscii:
    if c in {'a'..'z', '0'..'9', '_'}: result.add c
    elif result.len > 0 and result[^1] != '-': result.add '-'
  result = result.strip(chars = {'-'})
  if result.len == 0: result = "my-theme"

proc saveThemeFile(j: JsonNode): string =
  let name = themeSlug(j{"name"}.getStr)
  createDir(themesDir())
  result = themesDir() / (name & ".json")
  writeFile(result, j.pretty & "\n")

proc stripJsonc(s: string): string =
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
    if c == nil or c.kind != JObject: return ""
    for k in keys:
      if c{k} != nil and c{k}.kind == JString and c{k}.getStr.len > 0: return c{k}.getStr
    ""
  var cs = newJObject()
  proc put(k, v: string) =
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
