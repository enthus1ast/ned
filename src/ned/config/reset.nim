# ── Reset everything: ned as on its first run — its settings, its state (sessions, history, chats …), its caches
#    and its downloads removed (each may be kept), then ned starts again in the same folder. `ned --reset` does it
#    from the shell (when ned no longer starts as it should). ──

type ResetPart = object
  key, label, what: string
  paths: seq[string]
  on: bool

var
  resetPending: seq[string]     # what goes once ned has stopped everything (main's shutdown)
  resetRestart = false

proc resetDataRoot(): string = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / AppName
proc resetCacheRoot(): string = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / AppName

proc resetSize(paths: seq[string]): (int64, int) =
  ## the bytes and files under the paths
  for p in paths:
    try:
      if fileExists(p) or symlinkExists(p):
        result[0] += getFileSize(p)
        inc result[1]
      elif dirExists(p):
        for f in walkDirRec(p, yieldFilter = {pcFile, pcLinkToFile}):
          try: result[0] += getFileSize(f)
          except CatchableError: discard
          inc result[1]
    except CatchableError: discard

func resetBytes(n: int64): string =
  if n < 1024: $n & " B"
  elif n < 1024 * 1024: $(n div 1024) & " KB"
  elif n < 1024 * 1024 * 1024: formatFloat(n.float / 1048576.0, ffDecimal, 1) & " MB"
  else: formatFloat(n.float / 1073741824.0, ffDecimal, 1) & " GB"

proc resetParts(project = ""): seq[ResetPart] =
  let cfg = configDir()
  var settingsPaths: seq[string]
  if dirExists(cfg):
    for kind, p in walkDir(cfg):
      if extractFilename(p) != "plugins": settingsPaths.add p
  result.add ResetPart(key: "settings", label: "Settings",
                       what: "your settings, key bindings, your commands, snippets, themes, macros, spelling words",
                       paths: settingsPaths, on: true)
  result.add ResetPart(key: "plugins", label: "Plugins you installed or wrote",
                       what: "every plugin in " & tildePath(cfg / "plugins") & " — your own too",
                       paths: @[cfg / "plugins"], on: true)
  result.add ResetPart(key: "state", label: "Sessions and history",
                       what: "each folder's open files and layout, recent files and folders, local history (the earlier " &
                             "versions of your files), undo history, AI chats, edits kept by hot exit, recovery files, " &
                             "trusted folders",
                       paths: @[stateDir()], on: true)
  result.add ResetPart(key: "cache", label: "Caches",
                       what: "the Nim index, compiled plugins, NimScript and nimble caches — made again when needed",
                       paths: @[resetCacheRoot()], on: true)
  result.add ResetPart(key: "data", label: "Downloads",
                       what: "spelling dictionaries you downloaded, plugins' own data",
                       paths: @[resetDataRoot()], on: true)
  if project.len > 0 and dirExists(project / ".ned"):
    result.add ResetPart(key: "project", label: "This folder's .ned",
                         what: tildePath(project / ".ned") & ": the project's own settings and tasks (often in git)",
                         paths: @[project / ".ned"], on: false)

proc resetOtherNeds(): int =
  ## other neds of this user running now (they would write their state back when they quit)
  when defined(linux) or defined(android):
    let me = getCurrentProcessId()
    try:
      for kind, p in walkDir("/proc"):
        let nm = extractFilename(p)
        if nm.len == 0 or not nm.allCharsInSet(Digits) or parseInt(nm) == me: continue
        try:
          if readFile(p / "comm").strip == AppName:
            var st: Stat
            if stat(cstring(p), st) == 0 and st.st_uid == getuid(): inc result
        except CatchableError: discard
    except CatchableError: discard
  else: discard

proc resetRemove(paths: seq[string]): seq[string] =
  ## the paths removed; what could not be, in the result
  for p in paths:
    try:
      if symlinkExists(p) or fileExists(p): removeFile(p)
      elif dirExists(p): removeDir(p)
    except CatchableError as e: result.add p & ": " & e.msg

proc resetFinish() =
  ## (main's shutdown, everything stopped) the parts removed — then ned again, in the same folder
  if resetPending.len == 0: return
  let failed = resetRemove(resetPending)
  resetPending.setLen(0)
  for f in failed: stderr.writeLine("ned: could not remove " & f)
  if resetRestart:
    try: setCurrentDir(rootDir)
    except CatchableError: discard
    let exe = getAppFilename()
    when defined(windows):
      # (no exec: the new ned runs in this console while this one waits, then ends with its code)
      quit(winRunArgv(@[exe], rootDir))
    else:
      let args = allocCStringArray([AppName])
      discard execv(cstring(exe), args)
      stderr.writeLine("ned: settings and state removed — start ned again")

proc cmdResetEverything() =
  ## the dialog: what goes (each part ticked, its size), then ned starts again
  let parts = resetParts(rootDir)
  let f = newForm("Reset everything",
    "ned as on its first run: what is ticked is removed, then ned starts again in this folder. This cannot be undone.")
  f.width = 76
  f.danger = true
  var unsaved: seq[string]
  for b in bufs:
    if b.dirty and b.path.len > 0: unsaved.add b.name
  let others = resetOtherNeds()
  if others > 0:
    f.addNote(ic("warn") & " " & $others & (if others == 1: " other ned is" else: " other neds are") &
              " running: quit " & (if others == 1: "it" else: "them") & " first, or they write their settings and state back")
  for p in parts:
    let (bytes, files) = resetSize(p.paths)
    let size = if files == 0: "nothing there" else: $files & (if files == 1: " file, " else: " files, ") & resetBytes(bytes)
    f.addCheck(p.key, p.label & "  ·  " & size, p.on and files > 0, p.what)
  if unsaved.len > 0:
    f.addHeader("Unsaved")
    f.addCheck("save", "Save " & unsaved.join(", ") & " first", true,
               "Off: their unsaved edits are lost (hot exit keeps nothing when the state goes)")
  f.addButton("Cancel", "cancel", primary = true)
  f.addButton("Reset and restart", "reset", danger = true)
  f.onButton = proc(ff: Form, id: string): bool =
    if id != "reset": return true
    var paths: seq[string]
    var names: seq[string]
    for p in parts:
      if ff.formChecked(p.key):
        paths.add p.paths
        names.add p.label
    if paths.len == 0:
      ff.error = "Nothing ticked"
      return false
    if ff.formChecked("save") and not saveAll():
      ff.error = "Could not save every file — untick \"Save … first\" to lose their edits"
      return false
    for b in bufs: removeSwap(b)
    resetPending = paths
    resetRestart = true
    quitting = true
    true
  openForm(f)

proc resetCli(args: seq[string]): int =
  ## ned --reset [--yes] [--keep-plugins]: from the shell
  let yes = "--yes" in args or "-y" in args
  var parts = resetParts()
  if "--keep-plugins" in args:
    for p in parts.mitems:
      if p.key == "plugins": p.on = false
  echo "ned --reset removes:"
  var paths: seq[string]
  for p in parts:
    if not p.on: continue
    let (bytes, files) = resetSize(p.paths)
    if files == 0: continue
    echo "  ", alignLeft(p.label, 32), align($files & " files", 12), align(resetBytes(bytes), 10)
    for x in p.paths:
      if fileExists(x) or dirExists(x): echo "      ", tildePath(x)
    paths.add p.paths
  if paths.len == 0:
    echo "  nothing: ned has no settings or state here"
    return 0
  let others = resetOtherNeds()
  if others > 0: echo "\nwarning: ", others, " ned", (if others == 1: " is" else: "s are"), " running — quit them first"
  if not yes:
    stdout.write "\nRemove all of this? This cannot be undone. [y/N] "
    stdout.flushFile()
    var ans = ""
    try: ans = stdin.readLine().strip.toLowerAscii
    except CatchableError: discard
    if ans notin ["y", "yes"]:
      echo "Nothing removed."
      return 1
  let failed = resetRemove(paths)
  for f in failed: stderr.writeLine("could not remove " & f)
  echo (if failed.len == 0: "Done: ned starts as on its first run." else: "Done, but not everything could be removed.")
  if failed.len == 0: 0 else: 1
