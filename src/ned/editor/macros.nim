# ── keyboard macros: record what you type, play it back (N times, on each selected line, to the end of the file),
#    keep it under a name; vim's q and @ registers, Helix's Q and q, Emacs' C-x ( ) e ──

var
  macroReg = ""                          # the vim register being recorded ("" otherwise)
  macroKeys: seq[Key]                    # being recorded
  macroKeyStart = 0                      # where the key being handled starts in macroKeys
  macroUiMark = 0                        # … and where the last key that met no open menu or list starts
  macroMouseWarned = false
  macroLast: seq[Key]                    # the last macro recorded (or played)
  macroRegs: Table[string, seq[Key]]     # vim registers a–z
  macroSaved: OrderedTable[string, seq[Key]]   # by name, in macros.json
  macroLoaded = false
  vimMacroLastReg = ""                   # the register @@ plays

const MacroMark = "your macro"

proc macroBadge(): string =
  ## the status bar's recording mark: `● REC`, the vim register being recorded into if any, and the number of keys so
  ## far
  "● REC" & (if macroReg.len > 0: " @" & macroReg else: "") & " " & $macroKeys.len

proc macroNoteKey(k: Key) =
  ## a key while recording (called first thing for every key): kept, except the ones a macro plays itself
  if macroPlaying > 0: return
  if k.kind == kMouse:
    if not macroMouseWarned and k.press:
      macroMouseWarned = true
      warn("Mouse clicks are not recorded in a macro — use keys to move")
    return
  macroKeyStart = macroKeys.len
  if not (dialogOpen() or menuOpen() or pickKind != pickNone or promptKind != pNone): macroUiMark = macroKeyStart
  macroKeys.add k

proc macroStart(reg = "") =
  ## starts recording keys (into the vim register `reg`, if given) from an empty list, closes the completion popup and
  ## tells how to stop; does nothing while a macro is playing
  if macroPlaying > 0: return
  macroRecording = true
  macroReg = reg
  macroKeys.setLen(0)
  macroKeyStart = 0
  macroUiMark = 0
  macroMouseWarned = false
  closeComp()
  info("Recording a macro" & (if reg.len > 0: " into @" & reg else: "") & " — " &
       (if reg.len > 0: "q" elif cfgKeymap == "emacs": "C-x )" elif cfgKeymap == "helix": "Q" else: "Alt+Shift+R") &
       " stops")

proc macroStop(prefixKeys = 0) =
  ## the key that stopped it (with the `prefixKeys` before it, like Emacs' C-x — or the palette or menu it was
  ## stopped from) is not part of it
  if not macroRecording: return
  macroRecording = false
  macroKeys.setLen(max(0, min(macroKeys.len, min(macroKeyStart - prefixKeys, macroUiMark))))
  needRender = true
  if macroKeys.len == 0:
    info("Nothing was recorded")
    return
  macroLast = macroKeys
  if macroReg.len > 0: macroRegs[macroReg] = macroKeys
  info("Macro recorded: " & $macroKeys.len & " key(s) — " &
       (if macroReg.len > 0: "@" & macroReg & " plays it"
        elif cfgKeymap == "emacs": "C-x e plays it"
        elif cfgKeymap == "helix": "q plays it"
        else: "Alt+Shift+M plays it · palette › Macro: save the last one… keeps it"))

proc macroToggle() =
  ## stops the recording if one is going on, otherwise starts one
  if macroRecording: macroStop() else: macroStart()

proc macroRun(keys: seq[Key], times: int): bool =
  ## the keys handled as if typed, `times` times, one undo step per file; false when it stopped early
  ## (it changed nothing and did not move — playing it again would do the same)
  if keys.len == 0 or macroPlaying >= 3: return false
  result = true
  # (a copy: `keys` may be macroLast itself, which a macro played from inside this one replaces)
  var own = newSeqOfCap[Key](keys.len)
  for k in keys: own.add k
  var marks: Table[int, int]
  for b in bufs:
    marks[b.id] = b.undoStack.len
    b.newGroup = true
  inc macroPlaying
  let t0 = getMonoTime()
  try:
    closeComp()
    for i in 0 ..< times:
      if termSignal != 0: break                 # (the terminal went away: stop, so ned can exit)
      if i > 0 and msSince(t0) > 15_000:
        warn("The macro has been playing for 15 s — stopped after " & $i & " times")
        result = false
        break
      let b = buf()
      let before = (b.id, b.changeId, b.primary.head, b.lines.len)
      for k in own:
        if termSignal != 0: break
        handleKey(k)
      let b2 = buf()
      if i + 1 < times and (b2.id, b2.changeId, b2.primary.head, b2.lines.len) == before:
        result = false
        break
  finally:
    dec macroPlaying
  for b in bufs:
    let m = marks.getOrDefault(b.id, -1)
    if m >= 0:
      b.mergeUndo(m)
      if b.undoStack.len > m: b.undoStack[^1].kind = ekOther     # later typing starts its own step
    b.newGroup = true
  needRender = true

proc macroPlay(keys: seq[Key], times = 1) =
  ## plays a macro `times` times (up to 100000) with macroRun. A macro played from the keyboard becomes the last macro
  ## (one played by another macro does not); playing the macro being recorded is refused, and with nothing recorded the
  ## message says how to start.
  if keys.len == 0:
    info("No macro recorded yet — " & (if cfgKeymap == "emacs": "C-x (" elif cfgKeymap == "helix": "Q"
                                         else: "Alt+Shift+R") & " starts recording")
    return
  if macroRecording and macroPlaying == 0 and keys == macroKeys:
    warn("That is the macro being recorded — stop recording first")
    return
  if macroPlaying == 0: macroLast = keys     # (a macro played by a macro is not "the last one")
  let n = max(1, min(times, 100_000))
  let full = macroRun(keys, n)
  if n > 1: info(if full: "Played the macro " & $n & " times" else: "The macro stopped changing anything — played it until then")

proc macroPlayEachLine() =
  ## the last macro once per selected line, from its start (lines the macro adds or removes are allowed for)
  let b = buf()
  if macroLast.len == 0:
    info("No macro recorded yet")
    return
  let (a, e) = b.primary.range
  if a.line == e.line and b.cursors.len == 1:
    info("Select the lines to play the macro on")
    return
  var l = a.line
  var last = if e.col == 0 and e.line > a.line: e.line - 1 else: e.line
  var n = 0
  let t0 = getMonoTime()
  while l <= last and l < b.lines.len and n < 100_000 and msSince(t0) < 15_000:
    b.setSingle(Pos(line: l, col: 0))
    let before = b.lines.len
    discard macroRun(macroLast, 1)
    if buf() != b: break                       # the macro went to another tab
    let delta = b.lines.len - before
    last += delta
    l += 1 + max(0, delta)
    inc n
  info("Played the macro on " & $n & " line(s)")

proc macroPlayToEnd() =
  ## the last macro again and again while it moves down the file and changes something
  let b = buf()
  if macroLast.len == 0:
    info("No macro recorded yet")
    return
  var n = 0
  let t0 = getMonoTime()
  while n < 100_000 and msSince(t0) < 15_000:
    let before = (b.primary.head, b.changeId)
    discard macroRun(macroLast, 1)
    inc n
    if buf() != b or b.primary.head.line <= before[0].line: break     # (the last line: Down goes nowhere)
  info("Played the macro " & $n & " time(s), down to line " & $(b.primary.head.line + 1))

# saved macros: macros.json in the config folder, readable — typed text as strings, other keys as objects

# the file the named macros are kept in, in the config folder
proc macrosFile(): string = configDir() / "macros.json"

proc keyToJson(k: Key): JsonNode =
  ## a key as a JSON object: its name and kind, with its character code, function number, text and modifiers when it has
  ## them
  result = %*{"key": keyName(k), "kind": $k.kind}
  if k.ch != 0: result["ch"] = %k.ch
  if k.fn != 0: result["fn"] = %k.fn
  if k.text.len > 0: result["text"] = %k.text
  var ms: seq[string]
  if mCtrl in k.mods: ms.add "ctrl"
  if mAlt in k.mods: ms.add "alt"
  if mShift in k.mods: ms.add "shift"
  if ms.len > 0: result["mods"] = %ms

proc macroToJson(keys: seq[Key]): JsonNode =
  ## a macro as a JSON array that is easy to read and edit: runs of plain typed characters become one string each, every
  ## other key an object
  result = newJArray()
  var run = ""
  for k in keys:
    if k.kind == kChar and k.mods == {} and k.ch >= 32 and k.ch != 127:
      run.addUtf8(k.ch)
      continue
    if run.len > 0:
      result.add %run
      run = ""
    result.add keyToJson(k)
  if run.len > 0: result.add %run

proc macroFromJson(j: JsonNode): seq[Key] =
  ## the keys of a macro from its JSON — strings as typed characters, objects as keys; mouse and unknown keys are
  ## skipped, and anything that is not an array gives no keys
  if j == nil or j.kind != JArray: return
  for x in j:
    if x.kind == JString:
      let t = x.getStr
      var i = 0
      while i < t.len:
        let (cp, len) = runeAt(t, i)
        result.add Key(kind: kChar, ch: cp)
        i += max(1, len)
    elif x.kind == JObject:
      var k = Key(kind: kChar)
      try: k.kind = parseEnum[KeyKind](x{"kind"}.getStr("kChar"))
      except ValueError: continue
      if k.kind in {kNone, kMouse}: continue
      k.ch = x{"ch"}.getInt
      k.fn = x{"fn"}.getInt
      k.text = x{"text"}.getStr
      for m in jitems(x{"mods"}):
        case m.getStr
        of "ctrl": k.mods.incl mCtrl
        of "alt": k.mods.incl mAlt
        of "shift": k.mods.incl mShift
        else: discard
      result.add k

proc macroCommandsRefresh()

proc loadMacros() =
  ## reads the named macros from macros.json (a warning if it cannot be read) and makes a palette command of each
  macroLoaded = true
  macroSaved.clear()
  try:
    if fileExists(macrosFile()):
      let j = parseJson(readFile(macrosFile()))
      if j.kind == JObject:
        for name, v in j.pairs:
          let ks = macroFromJson(v)
          if ks.len > 0: macroSaved[name] = ks
  except CatchableError as e: warn("macros.json: " & e.msg)
  macroCommandsRefresh()

proc saveMacros() =
  ## writes the named macros to macros.json, creating the config folder if needed, and refreshes the palette commands
  var j = newJObject()
  for name, ks in macroSaved: j[name] = macroToJson(ks)
  try:
    createDir(configDir())
    writeFileSafe(macrosFile(), j.pretty & "\n")
  except CatchableError as e: error("Could not save macros.json: " & e.msg)
  macroCommandsRefresh()

proc macroRunAct(name: string): Action =
  ## an action that plays the saved macro called `name` — made here so each command keeps its own name
  result = proc() =
    if name in macroSaved: macroPlay(macroSaved[name])

proc macroCommandsRefresh() =
  ## each saved macro is a palette command "Macro: <name>" (so it can have keys through "keys")
  var keep: seq[Command]
  for c in commands:
    if c.keys != MacroMark: keep.add c
  commands = keep
  for name in macroSaved.keys:
    commands.add Command(name: "Macro: " & name, keys: MacroMark, action: macroRunAct(name))

proc macroSaveLast() =
  ## asks for a name and keeps the last recorded macro under it, as the command `Macro: <name>`
  if macroLast.len == 0:
    info("Record a macro first (Alt+Shift+R)")
    return
  askText("Name for the macro (it becomes the command “Macro: <name>”)", "", proc(t: string) =
    let n = t.strip
    if n.len == 0: return
    macroSaved[n] = macroLast
    saveMacros()
    info("Saved “Macro: " & n & "” — settings › keys can give it a shortcut"))

proc macroMenuAct(n: string): Action

proc macroManage() =
  ## palette command: lists the saved macros (and, when there is a last one, an item to save it); picking a macro opens
  ## its own menu
  if not macroLoaded: loadMacros()
  var items: seq[(string, string, Action)]
  if macroLast.len > 0:
    items.add act("Save the last macro…", $macroLast.len & " key(s)", proc() = macroSaveLast())
  for name, ks in macroSaved:
    let n = name
    let shown = block:
      var t = ""
      for x in macroToJson(ks):
        t.add (if x.kind == JString: x.getStr else: "‹" & x{"key"}.getStr & "›")
        if t.len > 60: break
      truncTo(t.replace("\n", "⏎"), 50)
    items.add act("▶ " & n, shown, macroMenuAct(n))
  if items.len == 0:
    info("No macros yet — Alt+Shift+R records one")
    return
  openActions("Macros", items)

proc macroMenuAct(n: string): Action =
  ## one saved macro's menu
  result = proc() =
      openActions("Macro: " & n, @[
        act("Play it", "", macroRunAct(n)),
        act("Play it N times…", "", proc() =
          askText("How many times?", "10", proc(t: string) =
            let c = (try: parseInt(t.strip) except ValueError: 0)
            if c > 0 and n in macroSaved: macroPlay(macroSaved[n], c))),
        act("Make it the last macro", "Alt+Shift+M, each line, to the end …", proc() =
          if n in macroSaved:
            macroLast = macroSaved[n]
            info("“" & n & "” is now the last macro")),
        act("Edit macros.json", "", proc() = discard openFile(macrosFile())),
        act("Delete", "", proc() =
          askConfirm("Delete the macro “" & n & "”? (y/n)", proc(c: char) =
            if c in {'y', 'Y'}:
              macroSaved.del n
              saveMacros()
              info("Deleted “" & n & "”")))])
