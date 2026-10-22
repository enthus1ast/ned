# ════════════════════════════════════════════════════════════════════════════
#  Plugins: folders with a plugin.nims (yours: ~/.config/ned/plugins/<name>, a project's: .ned/plugins/<name>,
#  once you trust the folder), all run in one NimScript process — `nim e`, or a compiled one (plugins.native). It
#  registers what each plugin has (commands, keys, events, languages, formatters, language servers, vim mappings,
#  timers …) and ned calls it back; the plugins ask ned for the text, to edit it, to show things (JSON lines). The
#  library a plugin imports is plugins/lib/nedplugin.nim; nedlsp.nim is for language servers written in NimScript
#  (`ned --lsp-bridge server.nims` gives them the Language Server Protocol's framing)
# ════════════════════════════════════════════════════════════════════════════

const
  PlugLibSrc = currentSourcePath().parentDir / "lib"
  NedPluginLib = staticRead(PlugLibSrc / "nedplugin.nim")
  NedLspLib = staticRead(PlugLibSrc / "nedlsp.nim")
  PlugMark = '\x1e'                       # (the start of a line of the host's that is a message)
  PlugExDir = currentSourcePath().parentDir.parentDir.parentDir.parentDir / "examples" / "plugins"
  PlugExamples = [
    ("zig-lite", "a language ned does not have (Zig), its formatter (zig fmt, or one in NimScript), zls",
     @[("plugin.nims", staticRead(PlugExDir / "zig-lite" / "plugin.nims"))]),
    ("wordinfo-lsp", "a language server written in NimScript (hover, completion, diagnostics) for text files",
     @[("plugin.nims", staticRead(PlugExDir / "wordinfo-lsp" / "plugin.nims")),
       ("server.nims", staticRead(PlugExDir / "wordinfo-lsp" / "server.nims"))]),
    ("commentary", "vim: the gc operator (gcc, gcip, gc in visual mode), the ie text object, :Comment",
     @[("plugin.nims", staticRead(PlugExDir / "commentary" / "plugin.nims"))])]
  PlugTemplate = """## $1 — a ned plugin (NimScript). ned runs it when it starts; edit it and save: the plugins reload.
## The API: the comments of nedplugin.nim (Plugins dock › ⓘ) — commands, keys, events, the text, problems,
## signs, languages, formatters, language servers, vim mappings, timers.
import nedplugin

command "$1: say hello":
  let b = current()
  message("Hello from $1 — " & b.path & " has " & $$b.lineCount & " lines")

command "$1: upper-case the line", "ctrl+alt+u":
  let b = current()
  let l = b.cursor.line
  b.replace(b.lineRange(l), b.line(l).toUpperAscii)

onSave("*") do (ev: Event):
  # (every file saved: a count in the status bar)
  status("$1 ✓ " & $$ev.buf.lineCount & " lines")
"""

type
  PlugInfo = object
    id, dir, file: string
    project, enabled: bool
    err: string                           # why it is not running ("" running, or off)
  PlugReg = object
    plugin, kind: string
    cb: int
    data: JsonNode
  PlugCall = object
    plugin: string
    sentAt: MonoTime
    onDone: proc(v: JsonNode, err: string) {.closure.}
    marks: seq[(int, int)]                # (buffer id, undo stack length): its edits are one undo step
  PlugQueued = object
    key: string                           # the registration it calls (its callback is known once the host runs)
    args: JsonNode
    onDone: proc(v: JsonNode, err: string) {.closure.}
  PlugTimer = object
    plugin: string
    cb, ms: int
    repeat: bool
    due: MonoTime

var
  plugs: seq[PlugInfo]
  plugRegs: seq[PlugReg]                  # what the plugins registered (the host's, or the manifest's until it runs)
  plugNewRegs: seq[PlugReg]               # (the host's, while it starts)
  phPr: Proc
  phIn, phOut, phErr: cint = -1
  phRbuf, phWbuf, phErrPart: string
  phState = "off"                         # off · starting · ready · failed: … · stopped (idle)
  phStartedAt, phLastUse: MonoTime
  phSig = ""                              # the plugins (and their files' stamps) it runs
  phNative = false
  phCalls: Table[int, PlugCall]
  phQueue: seq[PlugQueued]
  phNextRid = 0
  phErrTail: seq[string]
  phRunning = ""                          # the plugin whose call runs now (its echo is its log)
  phFailedOnce: HashSet[string]           # plugins left out after they broke the host (until their file changes)
  plugLog: seq[(string, string)]          # plugin, a line
  plugCmdNames: seq[string]
  plugTimers: seq[PlugTimer]
  plugEvts: seq[(string, string, string)] # event, pattern, registration key
  plugVimMaps: seq[(string, string, string)]   # mode (n v), keys, registration key
  plugOps: seq[(string, string)]          # keys, registration key
  plugTextObjs: Table[string, string]     # keys ("ie") → registration key
  plugExCmds: Table[string, string]       # name → registration key
  plugLspCmds: seq[(string, seq[string])] # language id, the command
  plugBootAt = MonoTime()                 # when the plugins are looked at (after the first frame)
  plugBooted = false
  plugStartupFired = false
  plugOpenQ: seq[int]                     # buffers opened (their "open" events, once the registrations are known)
  plugChangeSent: Table[int, int]         # buffer id → the change the "change" event was sent for
  plugUi: (int, string)                   # an answer the host waits for from you: (api id, pick · ask · confirm)
  plugUiTitle = ""
  plugSeq = ""                            # vim: keys typed of a plugin's mapping
  plugOpKeys = ""                         # vim: a plugin's operator waiting for its motion
  plugOpObj = '\0'
  plugOpCount = 1
  plugReplaying = false
  plugSilentSave = false                  # (a save a plugin asked for: no plugin events)
  plugSyncDepth = 0

# ── where things are ──

proc plugUserRoot(): string = configDir() / "plugins"
proc plugProjectRoot(): string = (if rootDir.len > 1: rootDir / ".ned" / "plugins" else: "")
proc plugCacheRoot(): string = getEnv("XDG_CACHE_HOME", getHomeDir() / ".cache") / AppName / "plugins"
proc plugDataRoot(): string = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / AppName / "plugins"

proc plugLibDir(): string =
  ## nedplugin.nim and nedlsp.nim as this ned has them (written once per version of them)
  result = plugCacheRoot() / ("lib-" & $(hash(NedPluginLib & NedLspLib) and 0xFFFFFFF))
  try:
    if not fileExists(result / "nedlsp.nim"):
      createDir(result)
      writeFile(result / "nedplugin.nim", NedPluginLib)
      writeFile(result / "nedlsp.nim", NedLspLib)
  except CatchableError: discard

proc plugLogAdd(plugin, line: string) =
  plugLog.add (plugin, (if line.len > 400: line[0 ..< 400] & "…" else: line))
  if plugLog.len > 400: plugLog = plugLog[^300 .. ^1]
  if rightOpen and rightView == svPlugins: needRender = true

proc plugsOn(): bool = sval("plugins.enabled").getBool(true)

func plugIdOk(id: string): bool =
  id.len > 0 and id.len <= 64 and id.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}) and id[0] != '.'

proc plugDisabledIds(): seq[string] =
  for x in jitems(sval("plugins.disabled")): result.add x.getStr

proc plugDiscover() =
  ## the plugin folders: yours, then the project's (a name that is yours is yours)
  plugs.setLen(0)
  let off = plugDisabledIds()
  for (root, project) in [(plugUserRoot(), false), (plugProjectRoot(), true)]:
    if root.len == 0 or not dirExists(root): continue
    var dirs: seq[string]
    try:
      for kind, d in walkDir(root):
        if kind in {pcDir, pcLinkToDir}: dirs.add d
    except OSError: continue
    dirs.sort()
    for d in dirs:
      let id = extractFilename(d)
      if not plugIdOk(id) or not fileExists(d / "plugin.nims"): continue
      var dup = false
      for p in plugs:
        if p.id == id: dup = true
      if dup: continue
      var p = PlugInfo(id: id, dir: d, file: d / "plugin.nims", project: project, enabled: id notin off)
      if not p.enabled: p.err = "off"
      elif project and not codeTrusted(rootDir):
        p.enabled = false
        p.err = "the folder is not trusted"
      elif id in phFailedOnce:
        p.enabled = false
        p.err = "it broke the plugins' start (fix it and save)"
      plugs.add p

proc plugSignature(): string =
  ## what the host is made of: each running plugin and its files' stamps (a change: a new host)
  var s = Version & "|" & $phNative & "|" & plugLibDir()
  for p in plugs:
    if not p.enabled: continue
    s.add "|" & p.id & "=" & p.dir
    try:
      for f in walkDirRec(p.dir):
        if f.endsWith(".nim") or f.endsWith(".nims"):
          let (mt, sz) = fileStamp(f)
          s.add ";" & f & ":" & $mt & ":" & $sz
    except OSError: discard
  $(hash(s) and 0xFFFFFFFFFFFF)

# ── registrations ──

proc plugInvoke(key: string, args: JsonNode, onDone: proc(v: JsonNode, err: string) {.closure.} = nil)

proc regKey(r: PlugReg): string =
  ## a registration's identity (its callback number may change when the host is made again)
  let d = r.data
  r.plugin & "|" & r.kind & "|" & (case r.kind
    of "command": d{"title"}.getStr
    of "event": d{"event"}.getStr & " " & d{"pattern"}.getStr
    of "vimMap": d{"mode"}.getStr & " " & d{"keys"}.getStr
    of "operator", "textObject": d{"keys"}.getStr
    of "ex": d{"name"}.getStr
    of "formatter", "lsp": d{"lang"}.getStr.toLowerAscii
    of "language": d{"id"}.getStr
    else: $r.cb)

proc regByKey(key: string): int =
  for i, r in plugRegs:
    if regKey(r) == key: return i
  -1

func plugKeyNorm(keys: string): string =
  ## "Alt+Ctrl+U", "ctrl + alt + u" → "ctrl+alt+u" (the order ned names keys in)
  var mods: seq[string]
  var key = ""
  for part0 in keys.toLowerAscii.split('+'):
    let part = part0.strip
    case part
    of "ctrl", "control", "c": (if "ctrl" notin mods: mods.add "ctrl")
    of "alt", "meta", "option", "opt", "m", "a": (if "alt" notin mods: mods.add "alt")
    of "shift", "s": (if "shift" notin mods: mods.add "shift")
    else: key = part
  var res: seq[string]
  for m in ["ctrl", "alt", "shift"]:
    if m in mods: res.add m
  if key.len > 0: res.add key
  res.join("+")

func vimKeysOf(keys: string): string =
  ## "<leader>f" → " f" (the leader is the space bar), <space> <cr> <tab> as themselves
  keys.multiReplace([("<leader>", " "), ("<Leader>", " "), ("<space>", " "), ("<Space>", " "), ("<cr>", "+"),
                     ("<CR>", "+"), ("<tab>", "\t"), ("<Tab>", "\t")])

proc plugApplyRegs() =
  ## the registrations → the palette, keys, languages, formatters, servers, vim's tables, events, timers
  var keep: seq[Command]
  for c in commands:
    if c.name notin plugCmdNames: keep.add c
  commands = keep
  plugCmdNames.setLen(0)
  plugKeys.clear()
  plugFmtCmd.clear()
  plugFmtCb.clear()
  plugLangSpecs.setLen(0)
  plugEvts.setLen(0)
  plugVimMaps.setLen(0)
  plugOps.setLen(0)
  plugTextObjs.clear()
  plugTextObjKeys.clear()
  plugExCmds.clear()
  plugLspCmds.setLen(0)
  var timers: seq[PlugTimer]
  for r in plugRegs:
    let d = r.data
    let key = regKey(r)
    case r.kind
    of "command":
      var name = d{"title"}.getStr
      if name.len == 0: continue
      if cmdByName(name) >= 0: name = r.plugin & ": " & name     # (ned has one of that name)
      let k = key
      let keysTxt = d{"keys"}.getStr
      capture k:
        commands.add Command(name: name, keys: keysTxt, action: proc() = plugInvoke(k, newJObject()))
      plugCmdNames.add name
      if keysTxt.len > 0: plugKeys[plugKeyNorm(keysTxt)] = name
    of "language":
      let id = d{"id"}.getStr.toLowerAscii
      if id.len > 0 and d{"spec"} != nil and d{"spec"}.kind == JObject: plugLangSpecs.add (r.plugin, id, d["spec"])
    of "formatter":
      let lang = d{"lang"}.getStr.toLowerAscii
      if d{"cmd"}.getStr.len > 0: plugFmtCmd[lang] = d["cmd"].getStr
      elif r.cb >= 0: plugFmtCb[lang] = (r.plugin, r.cb)
    of "lsp":
      var cmd: seq[string]
      for x in jitems(d{"cmd"}): cmd.add x.getStr
      let script = d{"script"}.getStr
      if script.len > 0:
        var dir = ""
        for p in plugs:
          if p.id == r.plugin: dir = p.dir
        cmd = @[getAppFilename(), "--lsp-bridge", (if script.isAbsolute: script else: dir / script)]
      if cmd.len > 0: plugLspCmds.add (d{"lang"}.getStr.toLowerAscii, cmd)
    of "event": plugEvts.add (d{"event"}.getStr, d{"pattern"}.getStr("*"), key)
    of "vimMap": plugVimMaps.add (d{"mode"}.getStr("n"), vimKeysOf(d{"keys"}.getStr), key)
    of "operator": plugOps.add (vimKeysOf(d{"keys"}.getStr), key)
    of "textObject":
      let k = d{"keys"}.getStr
      if k.len == 2:
        plugTextObjs[k] = key
        plugTextObjKeys.incl k
    of "ex": plugExCmds[d{"name"}.getStr] = key
    of "timer":
      timers.add PlugTimer(plugin: r.plugin, cb: r.cb, ms: max(100, d{"ms"}.getInt(1000)), repeat: d{"repeat"}.getBool,
                           due: getMonoTime() + initDuration(milliseconds = max(100, d{"ms"}.getInt(1000))))
    else: discard
  plugTimers = timers
  applyUserLanguages()
  # (a plugin's language server for its language: unless your "lsp" setting has one)
  for (lang, cmd) in plugLspCmds:
    let l = langByName(lang)
    if l == nil: continue
    let own = sval("lsp")
    if own != nil and own.kind == JObject and own.hasKey(lang): continue
    if l.lsp.len == 0 or l.lsp[0] != cmd:
      l.lsp = @[cmd]
      lspFailed.excl lang                  # (a file opened before the plugins ran found no server for it)
      for b in bufs:
        if b.lang == l and b.path.len > 0: lspAttach(b)
  needRender = true

proc plugEager(): bool =
  ## must the host run from the start (it answers events, keeps time, formats, gives text objects)?
  for r in plugRegs:
    if r.kind in ["timer", "textObject"] or (r.kind == "formatter" and r.cb >= 0): return true
    if r.kind == "event" and r.data{"event"}.getStr in ["startup", "open", "change", "beforeSave"]: return true
  false

proc plugManifestFile(): string = plugCacheRoot() / "manifest.json"

proc plugSaveManifest() =
  var a = newJArray()
  for r in plugRegs: a.add %*{"plugin": r.plugin, "kind": r.kind, "cb": r.cb, "data": r.data}
  try:
    createDir(plugCacheRoot())
    writeFile(plugManifestFile(), $(%*{"sig": phSig, "regs": a}))
  except CatchableError: discard

proc plugLoadManifest(sig: string): bool =
  ## the registrations the host made last time it ran these plugins: commands and keys at once, no host yet
  try:
    let j = parseFile(plugManifestFile())
    if j{"sig"}.getStr != sig: return false
    plugRegs.setLen(0)
    for r in jitems(j{"regs"}):
      plugRegs.add PlugReg(plugin: r{"plugin"}.getStr, kind: r{"kind"}.getStr, cb: r{"cb"}.getInt(-1), data: r{"data"})
    true
  except CatchableError: false

# ── the host process ──

proc plugSendRaw(j: JsonNode) =
  if phIn < 0: return
  phWbuf.add $j & "\n"

proc plugFlush(block_ms = 0) =
  ## what is waiting for the host, written (block_ms > 0: until it is all gone, that long at most)
  let t0 = getMonoTime()
  while phWbuf.len > 0 and phIn >= 0:
    let n = posix.write(phIn, addr phWbuf[0], phWbuf.len)
    if n > 0:
      phWbuf = phWbuf[n .. ^1]
      continue
    if n < 0 and errno in [EAGAIN, EINTR]:
      if block_ms <= 0 or msSince(t0) > block_ms: break
      var pf = TPollfd(fd: phIn, events: POLLOUT)
      discard poll(addr pf, 1, 20)
      continue
    phWbuf.setLen(0)                       # (the host is gone)
    break

proc plugStop(why = "off") =
  if phPr.pid > 0:
    plugSendRaw(%*{"t": "quit"})
    plugFlush(50)
    discard posix.kill(Pid(-phPr.pid), SIGTERM)
    discard waitProc(phPr, 150)
  closeFd(phIn)
  closeFd(phOut)
  closeFd(phErr)
  phIn = -1
  phOut = -1
  phErr = -1
  phPr = Proc(pid: -1, inFd: -1, outFd: -1, errFd: -1)
  phRbuf.setLen(0)
  phWbuf.setLen(0)
  for rid, c in phCalls:
    if c.onDone != nil:
      try: c.onDone(nil, "the plugins stopped")
      except CatchableError: discard
  phCalls.clear()
  phState = why
  needRender = true

proc plugHostSource(): string =
  result = "# made by ned " & Version & ": your plugins (and the project's) in one process\nimport nedplugin\n"
  for i, p in plugs:
    if p.enabled: result.add "import " & escape(p.file) & " as nedPlug" & $i & "\n"
  result.add "nedRun()\n"

proc plugNativeBin(): string = plugCacheRoot() / "native" / ("host-" & phSig)

proc plugBuildNative() =
  ## plugins.native: the host compiled (in the background; `nim e` until it is ready)
  let src = plugCacheRoot() / "native" / ("host_" & phSig & ".nim")
  let bin = plugNativeBin()
  try:
    createDir(parentDir(src))
    writeFile(src, plugHostSource())
  except CatchableError: return
  let cmd = "nim c -d:release --hints:off --warnings:off --path:" & quoteShell(plugLibDir()) & " --nimcache:" &
            quoteShell(plugCacheRoot() / "native" / "nimcache") & " -o:" & quoteShell(bin) & " " & quoteShell(src)
  discard startJob(jkTool, cmd, plugCacheRoot(), proc(j: Job) =
    if j.code == 0: plugLogAdd("ned", "native host built: the next start uses it")
    else:
      plugLogAdd("ned", "native host: the build failed (a plugin uses what only NimScript has?) — staying with nim e")
      for l in j.output.splitLines:
        if "Error" in l: plugLogAdd("ned", l))

proc plugStart() =
  ## the host for the enabled plugins (nothing when there are none)
  if phPr.pid > 0: return
  plugDiscover()
  var any = false
  for p in plugs:
    if p.enabled: any = true
  if not any or not plugsOn():
    phState = "off"
    return
  phNative = sval("plugins.native").getBool(false)
  phSig = plugSignature()
  var argv: seq[string]
  if phNative and fileExists(plugNativeBin()): argv = @[plugNativeBin()]
  else:
    if findExe("nim").len == 0:
      phState = "failed: plugins need nim (Termux: pkg install nim)"
      return
    let hostFile = plugCacheRoot() / "host" / ("host_" & phSig & ".nims")
    try:
      createDir(parentDir(hostFile))
      writeFile(hostFile, plugHostSource())
    except CatchableError as e:
      phState = "failed: " & e.msg
      return
    argv = @["nim", "e", "--hints:off", "--warnings:off", "--path:" & plugLibDir(), hostFile]
    if phNative: plugBuildNative()
  var dirs: seq[string]
  for p in plugs:
    if p.enabled: dirs.add p.id & "=" & p.dir
  let saved = (getEnv("NED_PLUGIN_DIRS"), existsEnv("NED_PLUGIN_DIRS"))
  putEnv("NED_PLUGIN_DIRS", dirs.join("\n"))
  try:
    let cwd = plugUserRoot()
    createDir(cwd)
    var p = spawnProc(argv, cwd, siPipe, erPipe, niceness = 5)
    phPr = p
    phIn = p.inFd
    phOut = p.outFd
    phErr = p.errFd
    phPr.inFd = -1
    phPr.outFd = -1
    phPr.errFd = -1
    setNonBlock(phIn); setNonBlock(phOut); setNonBlock(phErr)
    phState = "starting"
    phStartedAt = getMonoTime()
    phLastUse = getMonoTime()
    phErrTail.setLen(0)
    plugNewRegs.setLen(0)
  except CatchableError as e:
    phState = "failed: " & e.msg
  if saved[1]: putEnv("NED_PLUGIN_DIRS", saved[0]) else: delEnv("NED_PLUGIN_DIRS")

proc plugOwnerOf(path: string): string =
  for p in plugs:
    if path == p.dir or path.startsWith(p.dir & "/"): return p.id
  ""

proc plugHostDied() =
  ## the host ended: a plugin that did not compile is left out (its error in Problems) and the rest start again
  var culprit = ""
  var errs: Table[string, seq[Diag]]
  for l in phErrTail:
    let (ok, path, ln, c, sev, m) = parseErrLine(l, plugUserRoot())
    if ok and sev == 1:
      let owner = plugOwnerOf(path)
      if owner.len > 0:
        if culprit.len == 0: culprit = owner
        errs.mgetOrPut(path, @[]).add Diag(line: ln, col: c, eline: ln, ecol: -1, sev: 1, msg: m,
                                         src: "plugin " & owner)
  for p, ds in errs: diagsExt[p] = ds
  if errs.len > 0: rebuildProblems()
  let wasStarting = phState == "starting"
  let last = if phErrTail.len > 0: phErrTail[^1] else: "it exited"
  plugStop("failed: " & last)
  if culprit.len > 0:
    phFailedOnce.incl culprit
    plugLogAdd(culprit, "left out: " & last)
    toast("Plugin " & culprit & " has an error — the others run without it (Plugins dock)", 2)
    if wasStarting: plugStart()          # (the others)
  elif wasStarting:
    toast("The plugins could not start: " & last, 1)

proc plugLineOut(line: string)

proc plugReadOut() =
  var tmp: array[65536, char]
  var gone = false
  while true:
    let n = posix.read(phOut, addr tmp[0], tmp.len)
    if n > 0:
      let old = phRbuf.len
      phRbuf.setLen(old + n)
      copyMem(addr phRbuf[old], addr tmp[0], n)
    elif n == 0:
      gone = true
      break
    else: break
  while true:
    let nl = phRbuf.find('\n')
    if nl < 0: break
    let line = phRbuf[0 ..< nl]
    phRbuf = phRbuf[nl + 1 .. ^1]
    plugLineOut(line)
  if gone and phPr.pid > 0: plugHostDied()

proc plugReadErr() =
  var tmp: array[16384, char]
  while phErr >= 0:
    let n = posix.read(phErr, addr tmp[0], tmp.len)
    if n <= 0: break
    var chunk = newString(n)
    copyMem(addr chunk[0], addr tmp[0], n)
    let parts = (phErrPart & chunk).split('\n')
    for k in 0 ..< parts.high:
      let l = stripAnsi(parts[k]).strip
      if l.len == 0: continue
      phErrTail.add l
      let (ok, path, _, _, _, _) = parseErrLine(l, plugUserRoot())
      plugLogAdd((if ok and plugOwnerOf(path).len > 0: plugOwnerOf(path) elif phRunning.len > 0: phRunning else: "host"), l)
    phErrPart = parts[^1]
    if phErrTail.len > 40: phErrTail = phErrTail[^30 .. ^1]

# ── calling the plugins ──

proc plugSendCall(cb: int, plugin: string, args: JsonNode, onDone: proc(v: JsonNode, err: string) {.closure.}): int =
  inc phNextRid
  result = phNextRid
  phCalls[result] = PlugCall(plugin: plugin, sentAt: getMonoTime(), onDone: onDone)
  plugSendRaw(%*{"t": "call", "cb": cb, "rid": result, "args": args})
  plugFlush()
  phLastUse = getMonoTime()

proc plugInvoke(key: string, args: JsonNode, onDone: proc(v: JsonNode, err: string) {.closure.}) =
  ## call a registration's callback (the host starts first when it is not running: the call waits for it)
  if phState == "ready":
    let i = regByKey(key)
    if i < 0 or plugRegs[i].cb < 0:
      if onDone != nil: onDone(nil, "no such plugin callback")
      return
    discard plugSendCall(plugRegs[i].cb, plugRegs[i].plugin, args, onDone)
    return
  phQueue.add PlugQueued(key: key, args: args, onDone: onDone)
  if phState != "starting":
    plugStart()
    if phState != "starting":
      let q = phQueue
      phQueue.setLen(0)
      for x in q:
        if x.onDone != nil: x.onDone(nil, phState)
      if phState.startsWith("failed"): warn("Plugins: " & phState[8 .. ^1])

proc plugHandle(j: JsonNode)

proc plugWaitFor(done: proc(): bool, ms: int): bool =
  ## the host's messages until done() (or ms): what ned waits for before it goes on (a save, a format, a text object)
  let t0 = getMonoTime()
  inc plugSyncDepth
  defer: dec plugSyncDepth
  while not done():
    if phOut < 0: return false
    let left = ms - int(msSince(t0))
    if left <= 0: return false
    plugFlush(left)
    var pf = [TPollfd(fd: phOut, events: POLLIN), TPollfd(fd: phErr, events: POLLIN)]
    let r = poll(addr pf[0], 2, min(left, 50).cint)
    if r > 0:
      if (pf[1].revents and (POLLIN or POLLHUP)) != 0: plugReadErr()
      if (pf[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0: plugReadOut()
  true

proc plugTimeout(): int = max(200, sval("plugins.timeoutMs").getInt(1500))

proc plugCallSync(key: string, args: JsonNode, ms = -1): (bool, JsonNode, string) =
  ## call and wait for the answer (only when the host runs: a start takes a second or more — then: not now)
  if phState != "ready":
    if phState != "starting": plugStart()
    return (false, nil, "the plugins are starting")
  let i = regByKey(key)
  if i < 0 or plugRegs[i].cb < 0: return (false, nil, "no such plugin callback")
  var got = false
  var res: JsonNode = nil
  var err = ""
  discard plugSendCall(plugRegs[i].cb, plugRegs[i].plugin, args, proc(v: JsonNode, e: string) =
    got = true
    res = v
    err = e)
  if not plugWaitFor(proc(): bool = got, (if ms > 0: ms else: plugTimeout())):
    plugLogAdd(plugRegs[i].plugin, "no answer in " & $(if ms > 0: ms else: plugTimeout()) & " ms (plugins.timeoutMs)")
    return (false, nil, "no answer in time")
  (err.len == 0, res, err)

proc plugMatches(pattern: string, b: Buffer): bool =
  if pattern.len == 0 or pattern == "*": return true
  if pattern.startsWith("lang:"): return b.lang != nil and cmpIgnoreCase(b.lang.id, pattern[5 .. ^1]) == 0
  if b.path.len == 0: return false
  for pat in pattern.split(','):
    let pt = pat.strip
    if pt.len == 0: continue
    if '/' in pt:
      if globMatch(pt, relPath(b.path)): return true
    elif globMatch(pt, extractFilename(b.path)): return true
  false

proc plugEventArgs(b: Buffer): JsonNode =
  %*{"buf": b.id, "path": b.path, "lang": (if b.lang != nil: b.lang.id else: "")}

proc plugFire(event: string, b: Buffer) =
  if plugEvts.len == 0 or b == nil or plugSilentSave: return
  for (ev, pat, key) in plugEvts:
    if ev == event and plugMatches(pat, b): plugInvoke(key, plugEventArgs(b))

# ── the API: what the host asks of ned ──

proc plugAnswer(id: int, v: JsonNode, err = "") =
  if err.len > 0: plugSendRaw(%*{"t": "res", "id": id, "err": err})
  else: plugSendRaw(%*{"t": "res", "id": id, "value": (if v == nil: newJNull() else: v)})
  plugFlush()

proc jPos(p: Pos): JsonNode = %*{"line": p.line, "col": p.col}
proc posOf(j: JsonNode): Pos = Pos(line: j{"line"}.getInt, col: j{"col"}.getInt)

proc plugSetting(plugin, key: string): JsonNode =
  ## plugins.<plugin>.<key> — flat, or {"plugins.<plugin>": {key: …}}, or {"plugins": {"<plugin>": {key: …}}}
  result = settingNode("plugins." & plugin & "." & key)
  if result != nil: return
  let o = settingNode("plugins." & plugin)
  if o != nil and o.kind == JObject and o.hasKey(key): return o[key]
  let all = settingNode("plugins")
  if all != nil and all.kind == JObject and all{plugin} != nil and all[plugin].kind == JObject and all[plugin].hasKey(key):
    return all[plugin][key]

proc plugMarkEdit(rid: int, b: Buffer) =
  ## the first edit of a call in a buffer: where its undo step starts
  if rid notin phCalls: return
  for (id, _) in phCalls[rid].marks:
    if id == b.id: return
  phCalls[rid].marks.add (b.id, b.undoStack.len)

proc plugDecorSet(b: Buffer, plugin: string, d: PlugDecor) =
  var x = d
  x.plugin = plugin
  plugDecor.mgetOrPut(plugDecorKey(b), @[]).add x
  needRender = true

proc plugApi(j: JsonNode) =
  let id = j{"id"}.getInt
  let fn = j{"fn"}.getStr
  let a = j{"args"}
  let plugin = j{"plugin"}.getStr
  let rid = j{"rid"}.getInt
  phLastUse = getMonoTime()
  let b = if a != nil and a.hasKey("buf"): bufById(a["buf"].getInt) else: nil
  template needBuf() =
    if b == nil:
      plugAnswer(id, nil, "no such buffer (it was closed?)")
      return
  template rng(n: JsonNode): (Pos, Pos) =
    (b.clampPos(posOf(n{"start"})), b.clampPos(posOf(n{"stop"})))
  try:
    case fn
    of "current": plugAnswer(id, %buf().id)
    of "root": plugAnswer(id, %rootDir)
    of "open":
      var p = a{"path"}.getStr
      if p.len > 0 and not p.isAbsolute: p = rootDir / p
      let nb = openFile(p, a{"line"}.getInt(-1), a{"col"}.getInt(-1))
      plugAnswer(id, %(if nb == nil: -1 else: nb.id))
    of "buffers":
      var arr = newJArray()
      for x in bufs:
        if not x.isWelcome(): arr.add %x.id
      plugAnswer(id, arr)
    of "path": needBuf(); plugAnswer(id, %b.path)
    of "lang": needBuf(); plugAnswer(id, %(if b.lang != nil: b.lang.id else: ""))
    of "lineCount": needBuf(); plugAnswer(id, %b.lines.len)
    of "line":
      needBuf()
      let l = a{"line"}.getInt
      plugAnswer(id, %(if l >= 0 and l < b.lines.len: b.lines[l] else: ""))
    of "lines":
      needBuf()
      let f = clamp(a{"first"}.getInt, 0, b.lines.high)
      var l = a{"last"}.getInt(-1)
      if l < 0 or l > b.lines.high: l = b.lines.high
      var arr = newJArray()
      for i in f .. l: arr.add %b.lines[i]
      plugAnswer(id, arr)
    of "text": needBuf(); plugAnswer(id, %b.allText)
    of "textIn":
      needBuf()
      let (x, y) = rng(a{"range"})
      plugAnswer(id, %b.getText(x, y))
    of "dirty": needBuf(); plugAnswer(id, %b.dirty)
    of "indent": needBuf(); plugAnswer(id, %b.indent)
    of "lineComment": needBuf(); plugAnswer(id, %(if b.lang != nil: b.lang.lineComment else: ""))
    of "wordAt": needBuf(); plugAnswer(id, %b.wordAt(b.clampPos(posOf(a{"pos"}))))
    of "cursor": needBuf(); plugAnswer(id, jPos(b.primary.head))
    of "selection":
      needBuf()
      let (x, y) = b.primary.range
      plugAnswer(id, %*{"start": jPos(x), "stop": jPos(y)})
    of "selections":
      needBuf()
      var arr = newJArray()
      for c in b.cursors:
        let (x, y) = c.range
        arr.add %*{"start": jPos(x), "stop": jPos(y)}
      plugAnswer(id, arr)
    of "setText":
      needBuf()
      if not b.canEdit(): (plugAnswer(id, nil, "the file cannot be changed"); return)
      plugMarkEdit(rid, b)
      b.setTextMinimal(a{"text"}.getStr)
      needRender = true
      plugAnswer(id, newJNull())
    of "replace":
      needBuf()
      if not b.canEdit(): (plugAnswer(id, nil, "the file cannot be changed"); return)
      plugMarkEdit(rid, b)
      let (x, y) = rng(a{"range"})
      b.beginEdit()
      discard b.replaceText(x, y, a{"text"}.getStr)
      b.endEdit()
      needRender = true
      plugAnswer(id, newJNull())
    of "setCursor":
      needBuf()
      b.setSingle(b.clampPos(posOf(a{"pos"})))
      needRender = true
      plugAnswer(id, newJNull())
    of "select":
      needBuf()
      let (x, y) = rng(a{"range"})
      b.setSingle(y, x)
      needRender = true
      plugAnswer(id, newJNull())
    of "save":
      needBuf()
      plugSilentSave = true
      let ok = b.saveBuffer()
      plugSilentSave = false
      plugAnswer(id, %ok)
    of "message":
      if a{"level"}.getStr == "warn": warn(a{"text"}.getStr) else: info(a{"text"}.getStr)
      plugAnswer(id, newJNull())
    of "toast":
      toast(a{"text"}.getStr, 3)
      plugAnswer(id, newJNull())
    of "log":
      plugLogAdd(plugin, a{"text"}.getStr)
      plugAnswer(id, newJNull())
    of "pick", "ask", "confirm":
      if plugSyncDepth > 0 or plugUi[0] != 0:
        # (ned waits for this plugin — a save, a format — or already asks you something: not now)
        plugLogAdd(plugin, fn & ": not while ned waits for the plugin (an event before saving, a formatter …)")
        plugAnswer(id, (if fn == "pick": %(-1) elif fn == "ask": %"" else: %false))
        return
      plugUi = (id, fn)
      case fn
      of "pick":
        var items: seq[(string, string, Action)]
        var dets: seq[string]
        for x in jitems(a{"details"}): dets.add x.getStr
        var k = 0
        for x in jitems(a{"items"}):
          let idx = k
          capture idx:
            items.add act(x.getStr, (if idx < dets.len: dets[idx] else: ""), proc() =
              if plugUi[0] == id:
                plugUi = (0, "")
                plugAnswer(id, %idx))
          inc k
        plugUiTitle = a{"title"}.getStr
        openActions(plugUiTitle, items)
      of "ask":
        openPrompt(pPluginAsk, a{"prompt"}.getStr, a{"default"}.getStr)
      else:
        askConfirm(a{"text"}.getStr & " (y/n)", proc(c: char) =
          if plugUi[0] == id:
            plugUi = (0, "")
            plugAnswer(id, %(c in {'y', 'Y'})))
    of "runCommand":
      let n = a{"name"}.getStr
      plugAnswer(id, %(cmdByName(n) >= 0))
      if cmdByName(n) >= 0: runCmd(n)
    of "problems":
      needBuf()
      let key = if b.path.len > 0: b.path else: plugDecorKey(b)
      let src = "plugin " & plugin
      var keepDs: seq[Diag]
      for d in diagsExt.getOrDefault(key):
        if d.src != src: keepDs.add d
      for p in jitems(a{"problems"}):
        let (x, y) = rng(p{"range"})
        var fixes = newJArray()
        for f in jitems(p{"fixes"}):
          var edits = newJArray()
          for e in jitems(f{"edits"}): edits.add e
          fixes.add %*{"title": f{"title"}.getStr, "nedEdits": edits, "nedBuf": b.id}
        keepDs.add Diag(line: x.line, col: x.col, eline: y.line, ecol: y.col, sev: clamp(p{"severity"}.getInt(2), 1, 4),
                        msg: p{"message"}.getStr, src: src, fixes: (if fixes.len > 0: fixes else: nil))
      if keepDs.len > 0: diagsExt[key] = keepDs else: diagsExt.del key
      rebuildProblems()
      needRender = true
      plugAnswer(id, newJNull())
    of "sign":
      needBuf()
      let t = a{"text"}.getStr
      plugDecorSet(b, plugin, PlugDecor(kind: 0, line: a{"line"}.getInt, text: (if t.len > 0: t[0 ..< min(t.len, runeLen(t[0]))] else: "•"),
                                        color: a{"color"}.getStr))
      plugAnswer(id, newJNull())
    of "vtext":
      needBuf()
      plugDecorSet(b, plugin, PlugDecor(kind: 1, line: a{"line"}.getInt, text: a{"text"}.getStr, color: a{"color"}.getStr))
      plugAnswer(id, newJNull())
    of "highlight":
      needBuf()
      let (x, y) = rng(a{"range"})
      plugDecorSet(b, plugin, PlugDecor(kind: 2, line: x.line, col: x.col, eline: y.line, ecol: y.col,
                                        color: a{"color"}.getStr))
      plugAnswer(id, newJNull())
    of "clearDecorations":
      needBuf()
      let k = plugDecorKey(b)
      var keepD: seq[PlugDecor]
      for d in plugDecor.getOrDefault(k):
        if d.plugin != plugin: keepD.add d
      if keepD.len > 0: plugDecor[k] = keepD else: plugDecor.del k
      needRender = true
      plugAnswer(id, newJNull())
    of "status":
      var items: seq[(string, string)]
      for (p, t) in plugStatusItems:
        if p != plugin: items.add (p, t)
      if a{"text"}.getStr.len > 0: items.add (plugin, a{"text"}.getStr)
      plugStatusItems = items
      needRender = true
      plugAnswer(id, newJNull())
    of "setting": plugAnswer(id, plugSetting(plugin, a{"key"}.getStr))
    of "dataDir":
      let d = plugDataRoot() / plugin
      createDir(d)
      plugAnswer(id, %d)
    of "pluginDir":
      var d = ""
      for p in plugs:
        if p.id == plugin: d = p.dir
      plugAnswer(id, %d)
    of "stopTimer":
      let cb = a{"cb"}.getInt
      var keepT: seq[PlugTimer]
      for t in plugTimers:
        if not (t.cb == cb and t.plugin == plugin): keepT.add t
      plugTimers = keepT
      plugAnswer(id, newJNull())
    else: plugAnswer(id, nil, "ned has no " & fn)
  except CatchableError as e:
    plugAnswer(id, nil, e.msg)

proc plugCallDone(rid: int, v: JsonNode, err: string) =
  if rid notin phCalls: return
  let c = phCalls[rid]
  phCalls.del rid
  for (bid, mark) in c.marks:
    let b = bufById(bid)
    if b != nil: b.mergeUndo(mark)          # (all its edits: one undo step)
  if err.len > 0:
    plugLogAdd(c.plugin, "error: " & err)
    if plugSyncDepth == 0: warn("Plugin " & c.plugin & ": " & err)
  if c.onDone != nil:
    try: c.onDone(v, err)
    except CatchableError as e: internalError("plugin answer", e)

proc plugReady() =
  phState = "ready"
  plugRegs = plugNewRegs
  plugNewRegs.setLen(0)
  plugApplyRegs()
  plugSaveManifest()
  plugLogAdd("ned", "plugins ready in " & $msSince(phStartedAt) & " ms" & (if phNative and fileExists(plugNativeBin()):
             " (native)" else: " (nim e)"))
  # the calls that waited for it
  let q = phQueue
  phQueue.setLen(0)
  for x in q:
    let i = regByKey(x.key)
    if i >= 0 and plugRegs[i].cb >= 0: discard plugSendCall(plugRegs[i].cb, plugRegs[i].plugin, x.args, x.onDone)
    elif x.onDone != nil: x.onDone(nil, "the plugin has no such callback now")

proc plugHandle(j: JsonNode) =
  case j{"t"}.getStr
  of "reg":
    let r = PlugReg(plugin: j{"plugin"}.getStr, kind: j{"kind"}.getStr, cb: j{"cb"}.getInt(-1), data: j)
    if phState == "ready":
      # (registered later — a timer started in a command): at once
      plugRegs.add r
      if r.kind == "timer":
        plugTimers.add PlugTimer(plugin: r.plugin, cb: r.cb, ms: max(100, j{"ms"}.getInt(1000)), repeat: j{"repeat"}.getBool,
                                 due: getMonoTime() + initDuration(milliseconds = max(100, j{"ms"}.getInt(1000))))
      else: plugApplyRegs()
    else: plugNewRegs.add r
  of "ready": plugReady()
  of "api": plugApi(j)
  of "ret": plugCallDone(j{"rid"}.getInt, j{"value"}, j{"err"}.getStr)
  else: discard

proc plugLineOut(line: string) =
  if line.len > 0 and line[0] == PlugMark:
    var j: JsonNode
    try: j = parseJson(line[1 .. ^1])
    except CatchableError:
      plugLogAdd("host", line[1 .. ^1])
      return
    phRunning = ""
    for _, c in phCalls: phRunning = c.plugin
    plugHandle(j)
  elif line.strip.len > 0:
    var who = "host"
    for _, c in phCalls: who = c.plugin
    plugLogAdd(who, line)

# ── ned's side: what the editor calls ──

proc plugOpened(b: Buffer) =
  if plugsOn() and b != nil: plugOpenQ.add b.id

proc plugBeforeSave(b: Buffer) =
  ## the plugins' "before saving" events: what they change is saved (ned waits plugins.timeoutMs at most)
  if plugEvts.len == 0 or plugSilentSave or b == nil: return
  for (ev, pat, key) in plugEvts:
    if ev == "beforeSave" and plugMatches(pat, b):
      let (ok, _, err) = plugCallSync(key, plugEventArgs(b))
      if not ok and err == "the plugins are starting": info("Plugins are starting — saved without their changes")

proc plugSaved(b: Buffer) = plugFire("save", b)

proc plugClosed(b: Buffer) =
  plugFire("close", b)
  plugDecor.del plugDecorKey(b)
  plugChangeSent.del b.id

proc plugFormat(b: Buffer): bool =
  ## a plugin's NimScript formatter for the file's language (true: it had one — formatted, or said why not)
  if b.lang == nil or b.lang.id notin plugFmtCb: return false
  let (plugin, _) = plugFmtCb[b.lang.id]
  let key = plugin & "|formatter|" & b.lang.id
  let text = b.allText & "\n"
  let (ok, res, err) = plugCallSync(key, %*{"text": text}, max(plugTimeout(), 3000))
  if not ok:
    warn("Format (" & plugin & "): " & err)
    return true
  let t = res.getStr
  if t.len == 0 or t == text:
    info("Already formatted")
    return true
  b.setTextMinimal(t)
  info("Formatted (" & plugin & ")")
  true

proc plugTextObject(b: Buffer, kind, obj: char, p: Pos): (bool, bool, Pos, Pos) =
  ## a plugin's text object ("ie" …): (it is a plugin's, found, from, to)
  let k = $kind & $obj
  if k notin plugTextObjs: return (false, false, p, p)
  let (ok, res, _) = plugCallSync(plugTextObjs[k], %*{"buf": b.id, "pos": jPos(p)})
  if not ok or res == nil or res.kind != JObject: return (true, false, p, p)
  let a = posOf(res{"start"})
  let e = posOf(res{"stop"})
  if a.line < 0 or (a.line == e.line and a.col >= e.col and a.line >= 0 and e.line >= 0 and a == e):
    return (true, false, p, p)
  (true, true, b.clampPos(a), b.clampPos(e))

proc plugExCommand(cmd: string): bool =
  ## `:Name args` a plugin has
  let c = cmd.strip
  var k = 0
  while k < c.len and c[k] notin {' ', '!'}: inc k
  let name = c[0 ..< k]
  if name notin plugExCmds: return false
  plugInvoke(plugExCmds[name], %*{"args": c[k .. ^1].strip})
  true

proc plugVimReset() =
  plugSeq = ""
  plugOpKeys = ""
  plugOpObj = '\0'

proc plugRunOp(key: string, b: Buffer, a, e: Pos, linewise: bool) =
  plugInvoke(key, %*{"buf": b.id, "range": {"start": jPos(a), "stop": jPos(e)}, "linewise": linewise})

proc plugVimKey(b: Buffer, ch: char, visual: bool): bool =
  ## vim: a plugin's mappings and operators (sequences of keys); true when the key was theirs
  if plugReplaying or (plugVimMaps.len == 0 and plugOps.len == 0): return false
  let p = b.primary.head
  if plugOpKeys.len > 0:
    let op = plugOpKeys
    let key = block:
      var r = ""
      for (k, rk) in plugOps:
        if k == op: r = rk
      r
    if plugOpObj != '\0':
      let kind = plugOpObj
      plugOpObj = '\0'
      plugOpKeys = ""
      let (ok, a, e) = b.textObject(kind, ch, p)
      if ok: plugRunOp(key, b, a, e, false)
      return true
    if ch in {'1'..'9'} or (ch == '0' and plugOpCount > 1):
      plugOpCount = (if plugOpCount == 1 and ch != '0': 0 else: plugOpCount) * 10 + (ord(ch) - ord('0'))
      return true
    let n = max(1, plugOpCount)
    if ch == op[^1]:
      plugOpKeys = ""
      let last = min(b.lines.high, p.line + n - 1)
      plugRunOp(key, b, Pos(line: p.line, col: 0), Pos(line: last, col: b.lines[last].len), true)
      return true
    if ch in {'i', 'a'}:
      plugOpObj = ch
      return true
    plugOpKeys = ""
    let m = b.vimMotion($ch, n, p)
    if m.ok:
      var e = m.p
      if m.inclusive: e.col += 1
      let (x, y) = (minP(p, e), maxP(p, e))
      if m.linewise: plugRunOp(key, b, Pos(line: x.line, col: 0), Pos(line: y.line, col: b.lines[y.line].len), true)
      else: plugRunOp(key, b, x, y, false)
    return true
  if vimPending.len > 0: return false          # (one of vim's own commands waits for this key)
  if plugSeq.len == 0 and ch in {'0'..'9'}: return false
  let mode = if visual: "v" else: "n"
  let sq = plugSeq & $ch
  var exact, opExact = ""
  var longer = false
  for (md, keys, rk) in plugVimMaps:
    if md != mode: continue
    if keys == sq: exact = rk
    elif keys.startsWith(sq): longer = true
  for (keys, rk) in plugOps:
    if keys == sq: opExact = rk
    elif keys.startsWith(sq): longer = true
  let count = if vimCount.len > 0: (try: parseInt(vimCount) except ValueError: 1) else: 1
  if exact.len > 0:
    plugSeq = ""
    vimCount = ""
    plugInvoke(exact, %*{"count": count})
    return true
  if opExact.len > 0:
    plugSeq = ""
    vimCount = ""
    if visual:
      var (a, e) = b.primary.range
      let lw = vimMode == vmVLine
      if lw: (a, e) = (Pos(line: a.line, col: 0), Pos(line: e.line, col: b.lines[e.line].len))
      else: e = b.clampPos(Pos(line: e.line, col: e.col + 1))
      vimSetMode(vmNormal)
      b.setSingle(b.clampNormal(a))
      plugRunOp(opExact, b, a, e, lw)
    else:
      plugOpKeys = sq
      plugOpCount = count
      plugOpObj = '\0'
    return true
  if longer:
    plugSeq = sq
    return true
  if plugSeq.len > 0:
    # (not a plugin's after all: the keys held back go to vim, then this one)
    let held = plugSeq
    plugSeq = ""
    plugReplaying = true
    for c in held: discard vimKey(Key(kind: kChar, ch: ord(c)))
    plugReplaying = false
  false

proc plugFixAction(title, src: string, edits: JsonNode, bid: int): (string, string, Action) =
  act(title, src, proc() =
    let tb = bufById(bid)
    if tb == nil or not tb.canEdit(): return
    # (from the last edit back: the earlier ranges stay where they are)
    var es: seq[(Pos, Pos, string)]
    for e in jitems(edits):
      es.add (posOf(e{"range"}{"start"}), posOf(e{"range"}{"stop"}), e{"text"}.getStr)
    es.sort(proc(x, y: (Pos, Pos, string)): int = (if y[0] < x[0]: -1 elif x[0] < y[0]: 1 else: 0))
    tb.beginEdit()
    for (a, e, t) in es: discard tb.replaceText(tb.clampPos(a), tb.clampPos(e), t)
    tb.endEdit()
    needRender = true)

proc plugFixActions(b: Buffer, l0, l1: int): seq[(string, string, Action)] =
  ## the fixes of plugins' problems on these lines (Alt+Enter)
  for d in diagsExt.getOrDefault(if b.path.len > 0: b.path else: plugDecorKey(b)):
    if not d.src.startsWith("plugin ") or d.fixes == nil: continue
    if d.line > l1 or max(d.line, d.eline) < l0: continue
    for f in jitems(d.fixes): result.add plugFixAction(f{"title"}.getStr, d.src, f{"nedEdits"}, b.id)

# ── each round of the main loop ──

proc plugFds(fds: var seq[TPollfd]) =
  if phOut >= 0: fds.add TPollfd(fd: phOut, events: POLLIN)
  if phErr >= 0: fds.add TPollfd(fd: phErr, events: POLLIN)
  if phIn >= 0 and phWbuf.len > 0: fds.add TPollfd(fd: phIn, events: POLLOUT)

proc plugNextDueMs(): int =
  ## how soon the plugins need the loop again (a timer, the start, a change to tell them)
  result = int.high
  if not plugBooted: return 300
  for t in plugTimers: result = min(result, max(0, int((t.due - getMonoTime()).inMilliseconds)))
  if plugOpenQ.len > 0 and phState == "ready": result = 0
  for (ev, _, _) in plugEvts:
    if ev == "change":
      result = min(result, 200)
      break

proc plugPump(ready: HashSet[cint]) =
  if not plugBooted:
    if plugBootAt == MonoTime(): plugBootAt = getMonoTime()
    if msSince(plugBootAt) < 400 or not plugsOn(): return
    plugBooted = true
    # (the registrations of last time, at once; the host when it must run, or when they are not known)
    plugDiscover()
    var any = false
    for p in plugs:
      if p.enabled: any = true
    if not any: return
    phNative = sval("plugins.native").getBool(false)
    let sig = plugSignature()
    if plugLoadManifest(sig):
      plugApplyRegs()
      if plugEager(): plugStart()
    else: plugStart()
  if phOut >= 0 and phOut in ready: plugReadOut()
  if phErr >= 0 and phErr in ready: plugReadErr()
  if phWbuf.len > 0: plugFlush()
  if phPr.pid > 0 and phState in ["starting", "ready"] and phPr.reap():
    plugReadErr()
    plugHostDied()
  if phState != "ready": return
  if not plugStartupFired:
    plugStartupFired = true
    plugFire("startup", buf())
  if plugOpenQ.len > 0:
    let q = plugOpenQ
    plugOpenQ.setLen(0)
    for id in q: plugFire("open", bufById(id))
  # timers
  var i = 0
  while i < plugTimers.len:
    if getMonoTime() >= plugTimers[i].due:
      let t = plugTimers[i]
      discard plugSendCall(t.cb, t.plugin, newJObject(), nil)
      if t.repeat:
        plugTimers[i].due = getMonoTime() + initDuration(milliseconds = t.ms)
        inc i
      else: plugTimers.delete(i)
    else: inc i
  # changes, after a pause in the typing
  var wantChange = false
  for (ev, _, _) in plugEvts:
    if ev == "change": wantChange = true
  if wantChange and msSince(lastInputAt) > 400:
    for b in bufs:
      if b.isWelcome(): continue
      if plugChangeSent.getOrDefault(b.id, -1) == -1: plugChangeSent[b.id] = b.changeId
      elif plugChangeSent[b.id] != b.changeId:
        plugChangeSent[b.id] = b.changeId
        plugFire("change", b)
  # an answer you never gave (the list or the prompt closed some other way): cancelled
  if plugUi[0] != 0:
    let gone = case plugUi[1]
      of "pick": pickKind != pickAction or pickTitle != plugUiTitle
      of "ask": promptKind != pPluginAsk
      else: dialogs.len == 0
    if gone:
      let (id, kind) = plugUi
      plugUi = (0, "")
      plugAnswer(id, (if kind == "pick": %(-1) elif kind == "ask": %"" else: %false))
  # calls that never came back
  var late: seq[int]
  for rid, c in phCalls:
    if msSince(c.sentAt) > 60_000: late.add rid
  for rid in late:
    plugLogAdd(phCalls[rid].plugin, "a call took over a minute — given up (the plugin may be stuck: Reload)")
    plugCallDone(rid, nil, "no answer in a minute")
  # idle: stopped (it starts again when a plugin is needed)
  let idleMin = sval("plugins.idleStopMinutes").getInt(10)
  if idleMin > 0 and phCalls.len == 0 and plugUi[0] == 0 and not plugEager() and plugStatusItems.len == 0 and
     msSince(phLastUse) > idleMin * 60_000:
    plugStop("stopped (idle — it starts again when needed)")
    plugLogAdd("ned", "plugins stopped after " & $idleMin & " idle minutes")

proc plugAskDone(text: string) =
  ## the prompt a plugin's ask() opened: Enter
  if plugUi[1] == "ask":
    let id = plugUi[0]
    plugUi = (0, "")
    plugAnswer(id, %text)

proc plugReload() =
  ## the plugins again (after an edit, a new one, one turned on or off)
  plugStop("off")
  phFailedOnce.clear()
  plugStatusItems.setLen(0)
  plugDecor.clear()
  var keepX: Table[string, seq[Diag]]
  for p, ds in diagsExt:
    var k: seq[Diag]
    for d in ds:
      if not d.src.startsWith("plugin "): k.add d
    if k.len > 0: keepX[p] = k
  diagsExt = keepX
  rebuildProblems()
  plugRegs.setLen(0)
  plugApplyRegs()
  plugStartupFired = false
  plugStart()
  if phState == "off": info("No plugins (Plugins dock › New plugin…)")
  elif phState.startsWith("failed"): warn("Plugins: " & phState[8 .. ^1])
  else: info("Plugins: starting…")

proc plugFileSaved(path: string) =
  ## a plugin's own file saved: the plugins reload
  if not (path.endsWith(".nims") or path.endsWith(".nim")): return
  for root in [plugUserRoot(), plugProjectRoot()]:
    if root.len > 0 and path.startsWith(root & "/"):
      phFailedOnce.clear()
      plugReload()
      return

# ── the Plugins dock and its commands ──

proc plugSetEnabled(id: string, on: bool) =
  var off: seq[string]
  for x in plugDisabledIds():
    if x != id: off.add x
  if not on: off.add id
  setSetting("plugins.disabled", %off)
  plugReload()

proc plugNew(name0: string) =
  let name = name0.strip.replace(" ", "-")
  if not plugIdOk(name):
    warn("A plugin's name: letters, digits, - and _")
    return
  let d = plugUserRoot() / name
  if dirExists(d):
    discard openFile(d / "plugin.nims")
    info("That plugin exists — here it is")
    return
  try:
    createDir(d)
    writeFile(d / "plugin.nims", PlugTemplate % [name])
  except CatchableError as e:
    error("Could not make " & d & ": " & e.msg)
    return
  discard openFile(d / "plugin.nims")
  plugReload()
  info("New plugin " & name & " — edit it and save: the plugins reload (Plugins dock: its log)")

proc plugInstall(url0: string) =
  ## a plugin from a git repository (its plugin.nims at the top), into your plugins
  let url = url0.strip
  if not gitArgSafe(url) or not (url.startsWith("https://") or url.startsWith("git@") or url.startsWith("ssh://") or
                                  url.startsWith("http://") or url.startsWith("file://") or url.startsWith("/")):
    warn("Not a repository address: " & url)
    return
  var name = url.strip(chars = {'/'}).split('/')[^1]
  if name.endsWith(".git"): name = name[0 ..< name.len - 4]
  for pre in ["ned-plugin-", "ned-", "nedplugin-"]:
    if name.startsWith(pre) and name.len > pre.len: name = name[pre.len .. ^1]
  if not plugIdOk(name):
    warn("Cannot name a plugin after " & url)
    return
  let d = plugUserRoot() / name
  if dirExists(d):
    warn("You have a plugin called " & name & " (" & tildePath(d) & ")")
    return
  createDir(plugUserRoot())
  info("Installing " & name & "…")
  discard startJob(jkTool, "git clone -q --depth 1 -- " & quoteShell(url) & " " & quoteShell(d), plugUserRoot(),
    proc(j: Job) =
      if j.code != 0:
        error("git clone failed: " & j.output.strip.splitLines.join(" ")[0 ..< min(200, j.output.strip.len)])
        return
      if not fileExists(d / "plugin.nims"):
        warn(name & " has no plugin.nims at its top — not a ned plugin? (it is in " & tildePath(d) & ")")
        return
      plugReload()
      toast("Installed the plugin " & name & " — read its code: it runs with your rights (Plugins dock)", 3))

proc plugAddExample() =
  ## one of the examples, into your plugins (a copy: yours to change)
  var items: seq[(string, string, Action)]
  for (name, what, files) in PlugExamples:
    let n = name
    let w = what
    let fs = files
    capture n, w, fs:
      items.add act(n, w, proc() =
        let d = plugUserRoot() / n
        if dirExists(d):
          discard openFile(d / "plugin.nims")
          info("You have " & n & " — here it is")
          return
        try:
          createDir(d)
          for (f, text) in fs: writeFile(d / f, text)
        except CatchableError as e:
          error("Could not write " & d & ": " & e.msg)
          return
        discard openFile(d / "plugin.nims")
        plugReload()
        info("The example " & n & " is in " & tildePath(d) & " — it runs now (Plugins dock)"))
  openActions("Add an example plugin", items)

proc plugHelp() =
  ## the library's documentation (its source) in a tab, read-only (it is ned's copy: written again when it changes)
  let b = openFile(plugLibDir() / "nedplugin.nim")
  if b != nil: b.readOnly = true

proc plugInvokeAction(key: string): Action =
  proc() = plugInvoke(key, newJObject())

proc plugsRunning(): int =
  for p in plugs:
    if p.enabled: inc result

proc plugMenuAction(pid, file: string, on: bool): Action =
  proc() =
    openMenu(@[mi("Open plugin.nims", "", proc() = discard openFile(file)),
               mi((if on: "Turn off" else: "Turn on"), "", proc() = plugSetEnabled(pid, not on)),
               mi("Reload the plugins", "", proc() = plugReload())], mouseX, mouseY + 1)

proc buildPluginItems(): seq[SideItem] =
  result.add sideItem("PLUGINS", 6)
  if not plugsOn():
    result.add sideItem("off (plugins.enabled)", 2, "·", "turn on", proc() =
      setSetting("plugins.enabled", %true)
      plugReload())
    return
  if not plugBooted: plugDiscover()
  let host = case phState
    of "ready": ic("ok") & " running · " & (if phNative and fileExists(plugNativeBin()): "native" else: "nim e") &
                " · " & $plugsRunning() & " plugin" & (if plugsRunning() == 1: "" else: "s")
    of "starting": "○ starting… " & $msSince(phStartedAt) & " ms"
    else: "○ " & phState
  result.add sideItem(host, (if phState.startsWith("failed"): 3 elif phState == "ready": 5 else: 2), "◆")
  if plugs.len == 0:
    result.add sideItem("No plugins yet", 2, "·")
    result.add sideItem("New plugin…", 7, "+", "from a template", proc() =
      openPrompt(pPluginNew, "Name of the new plugin", ""))
    result.add sideItem("Install from git…", 7, "⇣", "a repository with a plugin.nims", proc() =
      openPrompt(pPluginInstall, "Plugin repository (https://…)", ""))
  var untrusted = 0
  for p in plugs:
    let pid = p.id
    let on = p.enabled
    let role = if on: (if p.err.len > 0: 3 else: 1) else: 2
    let det = if p.err.len > 0 and p.err != "off": p.err elif not on: "off" elif p.project: "project" else: ""
    if p.project and p.err == "the folder is not trusted": inc untrusted
    result.add sideItem(pid, role, (if on: "●" else: "○"), det, plugMenuAction(pid, p.file, on), path = p.file)
    if on:
      for r in plugRegs:
        if r.plugin != pid: continue
        let what = case r.kind
          of "command": "› " & r.data{"title"}.getStr & (if r.data{"keys"}.getStr.len > 0: "  " & r.data{"keys"}.getStr else: "")
          of "event": "on " & r.data{"event"}.getStr & " " & r.data{"pattern"}.getStr
          of "language": "language " & r.data{"id"}.getStr
          of "formatter": "formats " & r.data{"lang"}.getStr
          of "lsp": "language server for " & r.data{"lang"}.getStr
          of "vimMap": "vim " & r.data{"mode"}.getStr & "map " & r.data{"keys"}.getStr
          of "operator": "vim operator " & r.data{"keys"}.getStr
          of "textObject": "vim text object " & r.data{"keys"}.getStr
          of "ex": "vim :" & r.data{"name"}.getStr
          of "timer": "every " & $r.data{"ms"}.getInt & " ms"
          else: r.kind
        if r.kind == "command":
          result.add sideItem(what, 7, "", "", plugInvokeAction(regKey(r)), depth = 1)
        else: result.add sideItem(what, 2, "", "", depth = 1)
  if untrusted > 0:
    result.add sideItem($untrusted & " project plugin" & (if untrusted == 1: "" else: "s") & " held back", 4, "⛉",
                        "trust the folder", proc() = runCmd("Workspace: trust this folder"))
  if plugLog.len > 0:
    result.add sideItem("LOG", 6)
    for k in countdown(plugLog.high, max(0, plugLog.len - 40)):
      let (p, l) = plugLog[k]
      result.add sideItem(p & ": " & l, (if "rror" in l: 3 else: 2), "", depth = 1)

proc cmdPlugins() =
  showSide(svPlugins)

proc cmdPluginCommands() =
  ## the plugins' commands, in a list of their own (View › Plugin commands…)
  var items: seq[(string, string, Action)]
  for c in commands:
    if c.name in plugCmdNames:
      let n = c.name
      let k = c.keys
      capture n, k:
        items.add act(n, k, proc() = runCmd(n))
  if items.len == 0:
    info("No plugin commands" & (if phState == "starting": " yet — the plugins are starting" else: ""))
    return
  openActions("Plugin commands", items)

proc cmdPluginToggle() =
  plugDiscover()
  var items: seq[(string, string, Action)]
  for p in plugs:
    let pid = p.id
    let on = p.enabled
    let det = (if on: "turn off" else: "turn on") & (if p.err.len > 0 and p.err != "off": " · " & p.err else: "")
    capture pid, on:
      items.add act((if on: "● " else: "○ ") & pid, det, proc() = plugSetEnabled(pid, not on))
  if items.len == 0:
    info("No plugins yet — Plugins: new plugin…")
    return
  openActions("Plugins — turn one on or off", items)

# ── ned --lsp-bridge server.nims: a NimScript language server with the protocol's framing ──

proc lspBridge(script: string): int =
  ## stdin/stdout: Content-Length framed messages (an editor's language client); the script (nim e): a JSON message
  ## per line. Its other lines and its stderr go to stderr
  let file = absolutePath(script)
  if not fileExists(file):
    stderr.writeLine "ned --lsp-bridge: no such file: " & file
    return 2
  let nim = findExe("nim")
  if nim.len == 0:
    stderr.writeLine "ned --lsp-bridge: nim is not on PATH"
    return 2
  cfgFolderTrust = "off"                  # (the editor that runs the bridge chose to run the script)
  var p: Proc
  try:
    p = spawnProc(@[nim, "e", "--hints:off", "--warnings:off", "--path:" & plugLibDir(), file], parentDir(file),
                  siPipe, erPipe)
  except CatchableError as e:
    stderr.writeLine "ned --lsp-bridge: " & e.msg
    return 2
  let cin = p.inFd
  let cout = p.outFd
  let cerr = p.errFd
  var inBuf, outBuf: string
  var tmp: array[65536, char]
  proc writeAll(fd: cint, s: string) =
    var off = 0
    while off < s.len:
      let n = posix.write(fd, unsafeAddr s[off], s.len - off)
      if n > 0: off += n
      elif n < 0 and errno == EINTR: continue
      else: break
  var open0 = true
  while true:
    var fds = @[TPollfd(fd: cout, events: POLLIN), TPollfd(fd: cerr, events: POLLIN)]
    if open0: fds.add TPollfd(fd: 0, events: POLLIN)
    if poll(addr fds[0], fds.len.Tnfds, 1000) < 0:
      if errno == EINTR: continue
      break
    if open0 and (fds[2].revents and (POLLIN or POLLHUP)) != 0:
      let n = posix.read(0, addr tmp[0], tmp.len)
      if n <= 0:
        open0 = false
        discard posix.close(cin)
        p.inFd = -1
      else:
        let old = inBuf.len
        inBuf.setLen(old + n)
        copyMem(addr inBuf[old], addr tmp[0], n)
        # framed messages → lines
        while true:
          let he = inBuf.find("\r\n\r\n")
          if he < 0: break
          var clen = -1
          for hl in inBuf[0 ..< he].split("\r\n"):
            if hl.toLowerAscii.startsWith("content-length:"):
              try: clen = parseInt(hl[15 .. ^1].strip)
              except ValueError: discard
          if clen < 0:
            inBuf = inBuf[he + 4 .. ^1]
            continue
          if inBuf.len < he + 4 + clen: break
          let body = inBuf[he + 4 ..< he + 4 + clen]
          inBuf = inBuf[he + 4 + clen .. ^1]
          var oneLine = body
          if '\n' in oneLine or '\r' in oneLine:
            try: oneLine = $parseJson(body)
            except CatchableError: oneLine = body.replace("\r", "").replace("\n", " ")
          writeAll(cin, oneLine & "\n")
    if (fds[1].revents and (POLLIN or POLLHUP)) != 0:
      let n = posix.read(cerr, addr tmp[0], tmp.len)
      if n > 0: discard posix.write(2, addr tmp[0], n)
    if (fds[0].revents and (POLLIN or POLLHUP)) != 0:
      let n = posix.read(cout, addr tmp[0], tmp.len)
      if n <= 0: break
      let old = outBuf.len
      outBuf.setLen(old + n)
      copyMem(addr outBuf[old], addr tmp[0], n)
      while true:
        let nl = outBuf.find('\n')
        if nl < 0: break
        let line = outBuf[0 ..< nl].strip(leading = false, chars = {'\r'})
        outBuf = outBuf[nl + 1 .. ^1]
        if line.len > 0 and line[0] == '{':
          writeAll(1, "Content-Length: " & $line.len & "\r\n\r\n" & line)
        elif line.len > 0:
          writeAll(2, line & "\n")
  discard posix.close(cout)
  discard posix.close(cerr)
  result = waitProc(p, 3000)
