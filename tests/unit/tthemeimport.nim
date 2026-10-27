## Zed and Helix themes imported (src/ned/core/themeimport.nim): the TOML reader, where each colour of the sample
## themes in tests/themes/samples lands, what is taken from the nearest built-in theme, colours made readable, and
## that every result is a theme file ned reads — with a built ned (NEDBIN, or ./ned at the top of the source) it is
## also loaded by ned itself.
## Run: nim r tests/unit/tthemeimport.nim

import std/[json, math, os, osproc, strutils, tables, unittest]

const themeImportAlone {.used.} = true      # (the converting alone: the editor's command is left out)
include ../../src/ned/core/themeimport

let top = currentSourcePath().parentDir.parentDir.parentDir
let samples = top / "tests" / "themes" / "samples"

proc builtinsFromSource(): seq[TiBuiltin] =
  ## the built-in themes made with one mkTheme line, read from themes.nim as tests/themes/contrast.py reads them
  for line in readFile(top / "src" / "ned" / "core" / "themes.nim").splitLines:
    let a = line.find("mkTheme(\"")
    if a < 0: continue
    let rest = line[a + 9 .. ^1]
    let q = rest.find('"')
    if q <= 0: continue
    let parts = rest[q + 1 .. ^1].split(',')
    if parts.len < 18 or parts[1].strip notin ["true", "false"]: continue
    var b = TiBuiltin(name: rest[0 ..< q], dark: parts[1].strip == "true")
    var ok = true
    for i in 0 .. 15:
      let p = parts[2 + i].strip
      if not p.startsWith("0x") or p.len < 8: ok = false
      else: b.base[i] = uint32(parseHexInt(p[2 .. 7]))
    if ok: result.add b

let builtins = builtinsFromSource()

proc builtin(name: string): TiBuiltin =
  for b in builtins:
    if b.name == name: return b
  raise newException(KeyError, "no built-in theme " & name)

proc col(t: JsonNode, k: string): string = t["colors"][k].getStr

proc colOf(b: TiBuiltin, k: string): string = tiHex(b.base[TiKeys.find(k)])

proc isNedTheme(t: JsonNode): bool =
  ## what themeFromJson takes: a name of its own, light or dark, a built-in base, every colour #RRGGBB
  result = true
  template need(c: bool, why: string) =
    if not c:
      checkpoint(why & ": " & $t)
      result = false
  need(t.kind == JObject, "an object")
  let name = t{"name"}.getStr
  need(name.len > 0 and name == tiSlug(name), "a name that is its own file name")
  for b in builtins: need(b.name != name, "not a built-in theme's name")
  need(t{"dark"} != nil and t["dark"].kind == JBool, "dark: true or false")
  need(t{"boldKeywords"} != nil and t["boldKeywords"].kind == JBool, "boldKeywords: true or false")
  var baseOk = false
  for b in builtins:
    if b.name == t{"base"}.getStr and b.dark == t{"dark"}.getBool: baseOk = true
  need(baseOk, "a built-in base of the same kind")
  let cs = t{"colors"}
  need(cs != nil and cs.kind == JObject, "colors")
  if cs == nil or cs.kind != JObject: return false
  for k in TiKeys: need(cs{k} != nil, "every colour: " & k)
  for k in TiChrome: need(cs{k} != nil, "every bar: " & k)
  for k, v in cs:
    need(k in TiKeys or k in TiChrome or k == "ruler", "a colour name ned knows: " & k)
    let s = v.getStr
    need(s.len == 7 and s[0] == '#' and tiParse(s, 0) >= 0, "#RRGGBB: " & k & " " & s)

proc reads(t: JsonNode): bool =
  ## every colour reads on the background — the thresholds of contrast.py for the themes ned took in (text 7:1, code
  ## 4.5:1, comments and operators 3:1), and the theme editor's for the bars and the selection (text on them 4.5:1)
  result = true
  proc c(k: string): uint32 = uint32(tiParse(t["colors"][k].getStr, 0))
  let bg = c("bg")
  for (k, need) in [("fg", 7.0), ("keyword", 4.5), ("type", 4.5), ("string", 4.5), ("number", 4.5),
                    ("function", 4.5), ("macro", 4.5), ("property", 4.5), ("error", 4.5), ("comment", 3.0),
                    ("operator", 3.0), ("accent", 3.0), ("warning", 3.0), ("ok", 3.0)]:
    if tiContrast(c(k), bg) < need:
      checkpoint(t["name"].getStr & " " & k & " " & formatFloat(tiContrast(c(k), bg), ffDecimal, 2) & " < " & $need)
      result = false
  for k in ["selection", "titleBar", "dock", "statusBar"]:
    if tiContrast(c("fg"), c(k)) < 4.5:
      checkpoint(t["name"].getStr & " text on " & k & " < 4.5")
      result = false

suite "the TOML reader":
  test "tables, inline tables, dotted and quoted keys, strings, arrays, numbers":
    let j = tiParseToml("""
# a comment
title = "x"   # and one after a value
int = 1_000
flt = 3.5
yes = true
"quoted.key" = 'lit\eral'
a.b.c = "deep"
"x".y = { z = "w", n = { m = 1 } }
spread = { one = 1,
           two = 2, }
arr = [ 1, 2,
  3, ]   # over two lines
multi = TRIPLE
line one
line two TRIPLE
esc = "tab\there \"q\" \u00e9"
lit3 = '''
raw \n here'''
cont = TRIPLE
hello \
   world TRIPLE
[table.sub]
k = "v"
[[items]]
n = 1
[[items]]
n = 2
""".replace(" TRIPLE", "\"\"\""))      # (TOML's three quotes would end this Nim string)
    check j["title"].getStr == "x"
    check j["int"].getInt == 1000
    check j["flt"].getFloat == 3.5
    check j["yes"].getBool
    check j["quoted.key"].getStr == "lit\\eral"
    check j["a"]["b"]["c"].getStr == "deep"
    check j["x"]["y"]["z"].getStr == "w"
    check j["x"]["y"]["n"]["m"].getInt == 1
    check j["spread"]["two"].getInt == 2
    check j["arr"].len == 3 and j["arr"][2].getInt == 3
    check j["multi"].getStr == "line one\nline two"
    check j["esc"].getStr == "tab\there \"q\" \xC3\xA9"
    check j["lit3"].getStr == "raw \\n here"
    check j["cont"].getStr == "hello world"
    check j["table"]["sub"]["k"].getStr == "v"
    check j["items"].len == 2 and j["items"][1]["n"].getInt == 2

  test "what it cannot read is an error with its line":
    for (text, line) in [("a = \"no end", "line 1"), ("ok = 1\na = 1 b = 2", "line 2"), ("= 3", "line 1"),
                         ("x = { y = 1", "line 1"), ("\n\n[t", "line 3"), ("s = \"\\q\"", "line 1")]:
      var msg = ""
      try: discard tiParseToml(text)
      except ValueError as e: msg = e.msg
      check msg.startsWith(line)

suite "a Zed theme family":
  let path = samples / "zed-harbour.json"
  let r = tiConvert(readFile(path), path, builtins)

  test "both themes, named, light and dark":
    check r.err == ""
    check r.format == "Zed"
    check r.themes.len == 2
    check r.themes[0]["name"].getStr == "harbour-dusk"
    check r.themes[1]["name"].getStr == "harbour-day"
    check r.themes[0]["dark"].getBool and not r.themes[1]["dark"].getBool
    check r.themes[0]["importedFrom"].getStr == "zed-harbour.json (Zed: Harbour Dusk)"

  test "the dark one's colours where ned uses them":
    let t = r.themes[0]
    check t.col("bg") == "#1B2430"                 # editor.background, not background
    check t.col("fg") == "#C9D4DF"                 # editor.foreground, not text
    check t.col("accent") == "#5FB4E8"
    check t.col("selection") == "#2B465C"          # the first player's selection, its alpha laid over the background
    check t.col("comment") == "#6D7D8C"
    check t.col("keyword") == "#C792EA"
    check t.col("type") == "#FFCB6B"
    check t.col("string") == "#A3D08A"
    check t.col("function") == "#82AAFF"
    check t.col("operator") == "#89DDFF"
    check t.col("property") == "#F78C6C"
    check t.col("error") == "#F07178"              # error, not terminal.ansi.red
    check t.col("warning") == "#FFCB6B"
    check t.col("ok") == "#A3D08A"
    check t.col("titleBar") == "#151D27"
    check t.col("dock") == "#18212C"
    check t.col("statusBar") == "#151D27"
    check t["colors"]{"ruler"} == nil              # (a wrap guide too faint to see: ned's own ruler instead)
    check t["boldKeywords"].getBool                # font_weight 700

  test "a colour too faint to read is made readable, its hue kept":
    let t = r.themes[0]
    check t.col("number") != "#3A4A5A"
    check tiContrast(uint32(tiParse(t.col("number"), 0)), 0x1B2430'u32) >= 4.5
    check tiDelta(uint32(tiParse(t.col("number"), 0)), tiBlend(0x3A4A5A'u32, 0xFFFFFF'u32, 0.5)) < 25
    check "number" in r.themeNotes[0] and "made readable" in r.themeNotes[0]

  test "what it leaves out comes from the nearest built-in theme of its kind":
    let t = r.themes[0]
    let b = builtin(t["base"].getStr)
    check b.dark
    check "macro as in " & b.name in r.themeNotes[0]
    let want = tiReadable(b.base[TiKeys.find("macro")], 0x1B2430'u32, 4.5)
    check t.col("macro") == tiHex(want)

  test "the light one: fallbacks for the colours it names otherwise":
    let t = r.themes[1]
    check t.col("bg") == "#F7F9FB"
    check t.col("fg") == "#2B3540"
    check t.col("selection") == "#CEDDF5"
    check t.col("comment") == "#6C7783"           # (#RRGGBB without an alpha)
    check t.col("type") == "#A35A00"              # type.builtin
    check t.col("number") == "#B0306A"            # constant
    check t.col("operator") == "#4A5560"          # punctuation
    check t.col("macro") == "#9A3D8A"             # preproc
    check t.col("property") == "#7A3E00"          # variable.member
    check t.col("ok") == "#2F7D32"                # created
    check t.col("titleBar") == "#E9EEF3"          # no title bar: the status bar's colour
    check t.col("statusBar") == "#E9EEF3"
    check t.col("dock") == "#EFF3F7"
    check t.col("ruler") == "#CED2D6"
    check not t["boldKeywords"].getBool
    check r.themeNotes[1] == ""                   # nothing taken from elsewhere, nothing moved

  test "the same name twice in a file, and a built-in theme's name":
    let j = %*{"themes": [
      {"name": "Dracula", "appearance": "dark", "style": {"editor.background": "#282a36", "editor.foreground": "#f8f8f2"}},
      {"name": "Dracula", "appearance": "dark", "style": {"editor.background": "#282a36", "editor.foreground": "#f8f8f2"}}]}
    let r2 = tiFromZed(j, "x.json", builtins)
    check r2.themes.len == 2
    check r2.themes[0]["name"].getStr == "dracula-imported"
    check r2.themes[1]["name"].getStr == "dracula-imported-2"

  test "the nearest theme gives exactly the colours left out":
    # dracula's colours without a macro or a property colour: they are dracula's
    let j = %*{"name": "Night Bat", "appearance": "dark", "style": {
      "editor.background": "#282a36ff", "editor.foreground": "#f8f8f2ff", "text.accent": "#bd93f9ff",
      "players": [{"selection": "#44475aff"}], "error": "#ff5555ff", "warning": "#ffb86cff", "success": "#50fa7bff",
      "syntax": {"comment": {"color": "#6272a4ff"}, "keyword": {"color": "#ff79c6ff"}, "type": {"color": "#8be9fdff"},
                 "string": {"color": "#f1fa8cff"}, "number": {"color": "#bd93f9ff"},
                 "function": {"color": "#50fa7bff"}, "operator": {"color": "#ff79c6ff"}}}}
    let r2 = tiFromZed(j, "night-bat.json", builtins)
    check r2.themes.len == 1
    let t = r2.themes[0]
    check t["name"].getStr == "night-bat"
    check t["base"].getStr == "dracula"
    check t.col("macro") == builtin("dracula").colOf("macro")
    check t.col("property") == builtin("dracula").colOf("property")
    check t["dark"].getBool                       # (appearance)

suite "a Helix theme":
  let path = samples / "helix-harbour-night.toml"
  let r = tiConvert(readFile(path), path, builtins)

  test "read with what it inherits, the palettes merged":
    check r.err == ""
    check r.format == "Helix"
    check r.notes.len == 0
    check r.themes.len == 1
    let t = r.themes[0]
    check t["name"].getStr == "helix-harbour-night"
    check t["dark"].getBool
    check t.col("bg") == "#161A20"                # the parent's ui.background, with this theme's palette
    check t.col("fg") == "#C8CCD4"
    check t.col("keyword") == "#D19AF0"           # the parent's keyword in this palette's purple
    check t["boldKeywords"].getBool               # (modifiers = ["bold"], from the parent)

  test "each colour where ned uses it":
    let t = r.themes[0]
    check t.col("accent") == "#61AFEF"            # ui.cursor.primary's background
    check t.col("selection") == "#3A4250"
    check t.col("comment") == "#7F8794"
    check t.col("type") == "#E5C07B"
    check t.col("string") == "#98C379"
    check t.col("number") == "#D19A66"            # constant.numeric
    check t.col("function") == "#61AFEF"
    check t.col("operator") == "#56B6C2"
    check t.col("macro") == "#E5A0C8"             # function.macro, a colour of its own
    check t.col("error") == "#E06C75"
    check t.col("warning") == "#E5C07B"
    check t.col("ok") == "#98C379"                # diff.plus
    check t.col("titleBar") == "#181B21"          # ui.bufferline
    check t.col("statusBar") == "#181B21"
    check t.col("dock") == "#12151A"              # (none in Helix: made from the background as ned does)
    check t.col("ruler") == "#2C313A"
    # light-red, one of the terminal's colours, made readable on this background
    check t.col("property") == "#FF1A1A"
    check "property made readable" in r.themeNotes[0]

  test "a parent that is not there: said, and the rest from a built-in theme":
    let r2 = tiConvert("inherits = \"no-such-theme-anywhere\"\n\"ui.background\" = { bg = \"#101418\" }\n" &
                       "\"keyword\" = \"#ff9e64\"\n", "/nowhere/lonely.toml", builtins)
    check r2.err == ""
    check r2.notes.len == 1 and "no-such-theme-anywhere" in r2.notes[0]
    check r2.themes.len == 1
    check r2.themes[0].col("keyword") == "#FF9E64"
    check r2.themes[0]["base"].getStr.len > 0

  test "a theme in the terminal's colours, with no background of its own: dark, the background from a built-in":
    let r2 = tiConvert("\"keyword\" = \"magenta\"\n\"string\" = \"green\"\n\"comment\" = \"gray\"\n",
                       "/x/term16.toml", builtins)
    check r2.err == ""
    check r2.themes.len == 1
    let t = r2.themes[0]
    check t["dark"].getBool
    check t.col("bg") == builtin(t["base"].getStr).colOf("bg")
    check "bg, fg" in r2.themeNotes[0]
    check reads(t)

  test "unquoted dotted scopes are read as Helix reads quoted ones":
    let r2 = tiConvert("[ui]\nbackground = { bg = \"#fafafa\" }\ntext = \"#202020\"\n", "/x/plain.toml", builtins)
    check r2.format == "Helix"
    check r2.themes.len == 1
    check r2.themes[0].col("bg") == "#FAFAFA"
    check not r2.themes[0]["dark"].getBool

suite "telling the formats apart":
  test "VS Code, base16 and ned's own files are not for this importer (no error: the caller hands them on)":
    let vs = tiConvert("""{"name": "x", "type": "dark", "colors": {"editor.background": "#000000"}, "tokenColors": []}""",
                       "x.json", builtins)
    check vs.format == "" and vs.err == ""
    let b16 = tiConvert("scheme: \"x\"\nbase00: \"101010\"\n", "x.yaml", builtins)
    check b16.format == "" and b16.err == ""
    let ned = tiConvert("""{"name": "mine", "colors": {"bg": "#101010"}}""", "mine.json", builtins)
    check ned.format == "" and ned.err == ""
    let bom = tiConvert("\xEF\xBB\xBF" & readFile(samples / "zed-harbour.json"), "bom.json", builtins)
    check bom.format == "Zed" and bom.themes.len == 2

  test "a broken .toml or .json is an error; Zed's comments and trailing commas are not":
    check tiConvert("\"ui.background\" = {", "x.toml", builtins).err.len > 0
    check tiConvert("{\"themes\": [", "x.json", builtins).err.len > 0
    check "No colours" in tiConvert("[package]\nname = \"x\"\nversion = \"0.1.0\"\n", "Cargo.toml", builtins).err
    let text = "{\n  // a comment\n  \"themes\": [{\"name\": \"C\", \"appearance\": \"light\", " &
               "\"style\": {\"editor.background\": \"#ffffff\",}},]\n}"
    let r = tiConvert(text, "c.json", builtins)
    check r.err == "" and r.themes.len == 1 and r.themes[0]["name"].getStr == "c"

suite "ned's theme files":
  var all: seq[JsonNode]
  for f in ["zed-harbour.json", "helix-harbour-night.toml"]:
    all.add tiConvert(readFile(samples / f), samples / f, builtins).themes

  test "the colour names are themes.nim's":
    let src = readFile(top / "src" / "ned" / "core" / "themes.nim")
    let a = src.find("ThemeKeys = [")
    let e = src.find("]", a)
    var keys: seq[string]
    for part in src[a + 13 ..< e].split(','): keys.add part.strip(chars = Whitespace + {'"'})
    check keys == @TiKeys
    check "ChromeKeys = [\"" & TiChrome.join("\", \"") & "\"]" in src

  test "every result is a theme file ned reads, and every colour reads":
    check all.len == 3
    for t in all:
      check isNedTheme(t)
      check reads(t)

  test "written into the themes folder, one file each":
    let dir = getTempDir() / ("tthemeimport-" & $getCurrentProcessId())
    removeDir(dir)
    var r = tiConvert(readFile(samples / "zed-harbour.json"), samples / "zed-harbour.json", builtins)
    tiWrite(r, dir)
    check r.err == ""
    check r.files == @[dir / "harbour-dusk.json", dir / "harbour-day.json"]
    for i, f in r.files: check parseFile(f) == r.themes[i]
    removeDir(dir)

  test "ned itself loads them (with a built ned: NEDBIN or ./ned)":
    let ned = getEnv("NEDBIN", top / "ned")
    if not fileExists(ned):
      echo "  (no ned built at ", ned, ": skipped)"
      skip()
    else:
      let cfg = getTempDir() / ("tthemeimport-cfg-" & $getCurrentProcessId())
      removeDir(cfg)
      createDir(cfg / "ned" / "themes")
      for t in all: writeFile(cfg / "ned" / "themes" / (t["name"].getStr & ".json"), t.pretty)
      let was = getEnv("XDG_CONFIG_HOME")
      putEnv("XDG_CONFIG_HOME", cfg)
      let (outp, code) = execCmdEx(quoteShell(ned) & " --default-settings")
      if was.len > 0: putEnv("XDG_CONFIG_HOME", was) else: delEnv("XDG_CONFIG_HOME")
      removeDir(cfg)
      check code == 0
      for t in all: check t["name"].getStr in outp     # (the `theme` setting lists the themes it read)
