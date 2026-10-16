# ── settings UI: every option in one filterable list; Enter changes it ──

var
  settingKey = ""
  settingsFilter = ""
  settingNoUi = false     # the value prompt came from outside the settings list (e.g. "Type a model id…")

proc settingLabel(d: SetDef): string =
  var name = d.key
  let dot = name.find('.')
  if dot >= 0: name = name[dot + 1 .. ^1]
  var pretty = ""
  for i, c in name:
    if c in {'A'..'Z'} and i > 0: pretty.add ' '
    pretty.add (if i == 0: toUpperAscii(c) else: toLowerAscii(c))
  d.cat & " › " & pretty

proc settingValueText(d: SetDef): string =
  let v = sval(d.key)
  case v.kind
  of JBool: (if v.getBool: "✓ on" else: "· off")
  of JString: (if v.getStr.len == 0: "(default)" elif d.key == "ai.apiKey": "••••••" else: v.getStr)
  of JInt: $v.getInt
  of JArray: (if v.len == 0: "[ ]" else: $v.len & " item(s)")
  of JObject: (if v.len == 0: "{ }" else: $v.len & " entr" & (if v.len == 1: "y" else: "ies"))
  else: $v

proc cmdKeyboardShortcuts()
proc cmdEditUserCommands()

proc editSetting(d: SetDef) =
  let key = d.key
  case d.kind
  of skBool:
    setSetting(key, %(not sBool(key)))
    openSettingsUi(settingsFilter)
  of skEnum:
    var items: seq[MenuItem]
    for o in d.opts:
      let oo = o
      capture oo:
        items.add mi(oo, "", proc() =
          setSetting(key, %oo)
          openSettingsUi(settingsFilter), (if sStr(key) == oo: 1 else: 0))
    openMenu(items, max(0, scrW div 2 - 20), max(1, scrH div 4))
  of skInt, skStr:
    settingKey = key
    openPrompt(pSetting, d.key & " — " & d.doc, (if d.kind == skInt: $sInt(key) else: sStr(key)))
  of skJson:
    if key == "keys":
      cmdKeyboardShortcuts()             # pick a command, press its key
      return
    if key == "commands":
      cmdEditUserCommands()
      return
    if key == "editor.rulers":
      runCmd("View: set ruler columns…")
      return
    # other objects and lists are edited in the file itself
    openSettings()
    let b = buf()
    for i, l in b.lines:
      if l.strip.startsWith(escapeJson(key)):
        b.centerOn(Pos(line: i, col: l.find('"')))
        break

proc submitSetting(t: string) =
  let i = setIndex.getOrDefault(settingKey, -1)
  if i < 0: return
  let d = setDefs[i]
  if d.kind == skInt:
    try: setSetting(d.key, %parseInt(t.strip))
    except ValueError:
      error("Not a number: " & t)
      return
  else: setSetting(d.key, %(if d.key == "ai.model": t.strip else: t))
  info(d.key & " = " & settingValueText(d))
  if settingNoUi: settingNoUi = false        # asked from elsewhere (model picker): don't open the settings list
  else: openSettingsUi(settingsFilter)

proc openSettingsUi(filter = "") =
  initSettingDefs()
  settingNoUi = false
  settingsFilter = filter
  var items: seq[(string, string, Action)]
  var search: seq[string]
  items.add act("Open settings file (JSON with comments)", configFile(), proc() = openSettings())
  search.add ""
  if filter.len == 0:
    items.add act("Reset all settings to defaults…", "keeps a backup", proc() = resetSettings())
    search.add "reset defaults backup"
  for d in setDefs:
    if filter.len > 0 and not d.key.startsWith(filter): continue
    let dd = d
    capture dd:
      items.add act(settingLabel(dd), settingValueText(dd), proc() = editSetting(dd))
    search.add d.key & " " & d.cat & " " & d.doc        # the description is searched too
  openActions((if filter.len > 0: "Settings: " & filter else: "Settings — type a name or words from a description"),
              items, search)
