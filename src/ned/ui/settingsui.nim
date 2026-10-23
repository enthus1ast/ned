# ── settings UI: every option in one filterable list; Enter changes it ──

var
  settingsFilter = ""
  settingNoUi = false     # the value prompt came from outside the settings list (e.g. "Type a model id…")

func settingLabel(d: SetDef): string =
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
proc openSettingsList(filter = "")
proc reopenSettings() =
  ## (after a change from the quick list) the list again — the window does not go away for one
  if not formOpen(): openSettingsList(settingsFilter)
proc cmdEditUserCommands()

proc editSetting(d: SetDef) =
  let key = d.key
  case d.kind
  of skBool:
    setSetting(key, %(not sBool(key)))
    reopenSettings()
  of skEnum:
    var items: seq[MenuItem]
    for o in d.opts:
      let oo = o
      capture oo:
        items.add mi(oo, "", proc() =
          setSetting(key, %oo)
          reopenSettings(), (if sStr(key) == oo: 1 else: 0))
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
  else: reopenSettings()

proc settingPretty(d: SetDef): string =
  ## the setting's name as the Settings window shows it (its group is the category)
  var name = d.key
  let dot = name.find('.')
  if dot >= 0: name = name[dot + 1 .. ^1]
  for i, c in name:
    if c in {'A'..'Z'} and i > 0 and name[i - 1] != '.': result.add ' '
    result.add (if i == 0: toUpperAscii(c) else: toLowerAscii(c))

proc openSettingsForm(filter = "") =
  ## the Settings window: the categories on the left, each setting as a check box, a list to choose from or a text
  ## field (its description under the fields when it has the focus), a search over all of them; OK / Apply write
  ## what changed into the settings file (comments kept)
  initSettingDefs()
  let f = newForm("Settings")
  f.tall = true
  for d in setDefs:
    if d.cat notin f.groups: f.groups.add d.cat
  var initial = initTable[string, string]()          # (each field's value when shown: what changed is written)
  for d in setDefs:
    let label = settingPretty(d) & (if settingsUser.hasKey(d.key): "  •" else: "")
    var ff: FormField
    case d.kind
    of skBool: ff = f.addCheck(d.key, label, sBool(d.key), d.doc)
    of skEnum: ff = f.addChoice(d.key, label, d.opts, sStr(d.key), d.doc)
    of skInt: ff = f.addNumber(d.key, label, sInt(d.key), d.doc)
    of skStr:
      ff = f.addText(d.key, label, sStr(d.key), "(default)", d.doc, secret = d.key == "ai.apiKey")
    of skJson:
      let dd = d
      ff = f.addLink(label & " — " & settingValueText(d) & ", edit…", proc() =
        closeForm()
        editSetting(dd), d.doc)
    ff.group = d.cat
    ff.search = d.key
    ff.tag = $d.kind
    initial[d.key] = f.formValue(d.key)
  f.addButton("Settings file (JSON)", "file", left = true)
  f.addButton("Cancel", "cancel")
  f.addButton("Apply", "apply")
  f.addButton("OK", "ok", primary = true)
  f.onButton = proc(ff: Form, id: string): bool =
    case id
    of "file":
      openSettings()
      return true
    of "ok", "apply":
      var changes: seq[(string, JsonNode)]
      for fld in ff.fields:
        if fld.key.len == 0 or fld.kind == ffAction: continue
        let v = ff.formValue(fld.key)
        if initial.getOrDefault(fld.key) == v: continue
        case fld.kind
        of ffCheck: changes.add (fld.key, %fld.on)
        of ffNumber:
          try: changes.add (fld.key, %parseInt(v.strip))
          except ValueError:
            ff.error = settingPretty(setDefs[setIndex[fld.key]]) & ": \"" & v & "\" is not a number"
            ff.group = max(0, ff.groups.find(fld.group))
            ff.filter = ""
            ff.zone = 0
            ff.focus = ff.fields.find(fld)
            return false
        of ffText: changes.add (fld.key, %(if fld.key == "ai.model": v.strip else: v))
        of ffChoice: changes.add (fld.key, %v)
        else: discard
      setSettings(changes)
      for (k, _) in changes: initial[k] = ff.formValue(k)
      if changes.len > 0: info($changes.len & (if changes.len == 1: " setting changed" else: " settings changed"))
      return id == "ok"
    else: return true
  if filter.len > 0:
    f.filter = filter
    f.filterCur = filter.len
  f.zone = 2                       # (the search field has the keyboard: type what you look for)
  openForm(f)
  f.zone = 2

proc openSettingsUi(filter = "") =
  ## the Settings window — or, with ui.formButtons off (a keyboard person's choice), the quick list
  if cfgFormButtons:
    openSettingsForm(filter)
    return
  openSettingsList(filter)

proc openSettingsList(filter = "") =
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
