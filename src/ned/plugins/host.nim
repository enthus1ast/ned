# ════════════════════════════════════════════════════════════════════════════
#  Plugins: folders with a plugin.nims (yours: ~/.config/ned/plugins/<name>, a project's: .ned/plugins/<name>,
#  once you trust the folder) run together in one NimScript process — `nim e`, or compiled (plugins.native: auto
#  compiles a set of plugins you keep); a folder with a plugin.nim is a plugin in full Nim, compiled into a program
#  of its own (and plugins.alone gives a NimScript plugin a process of its own). Each process registers what its
#  plugins have (commands, keys, events, languages, formatters, language servers, completions, hover, code actions,
#  symbols, snippets, the assistant's tools, dock views, vim mappings, timers …) and ned calls it back; the plugins
#  ask ned for the text, to edit it, to show things (JSON lines). The library a plugin imports is
#  plugins/lib/nedplugin.nim; nedlsp.nim is for language servers written in NimScript (`ned --lsp-bridge
#  server.nims` gives them the Language Server Protocol's framing)
# ════════════════════════════════════════════════════════════════════════════

func plugSrcUp(p: string, n: int): string =
  ## (compile time) p's folder n levels up — with '/' whatever the target (parentDir writes '\' for Windows)
  result = p
  for _ in 1 .. n: result.setLen(max(0, result.rfind({'/', '\\'})))

const
  PlugLibSrc = currentSourcePath().plugSrcUp(1) & "/" & "lib"
  NedPluginLib = staticRead(PlugLibSrc & "/" & "nedplugin.nim")
  NedLspLib = staticRead(PlugLibSrc & "/" & "nedlsp.nim")
  PlugMark = '\x1e'                       # (the start of a line of the host's that is a message)
  PlugShared = "*"                        # (the name of the process the NimScript plugins share)
  PlugExDir = currentSourcePath().plugSrcUp(4) & "/" & "examples" & "/" & "plugins"
  PlugBundledDir = currentSourcePath().plugSrcUp(4) & "/" & "plugins"
  # ned's own plugins: in ned, off until you turn one on (Plugins dock › AVAILABLE, Plugins › Available plugins…)
  PlugBundledNames = ["align", "case-change", "dial", "elixir", "exchange", "gleam", "harpoon", "haskell",
                      "json-to-nim", "markdown-tools", "odin", "oil", "path-complete", "pomodoro", "rest-client",
                      "split-join", "text-objects", "time-tracker", "which-key"]
  PlugBundled = block:
    var r: seq[(string, string, string)]           # name, what it does (its first ## line), its source
    for n in PlugBundledNames:
      let src = staticRead(PlugBundledDir & "/" & n & "/" & "plugin.nims")
      var what = src.splitLines()[0].strip(chars = {'#', ' '})
      let dash = what.find(" — ")
      if dash >= 0: what = what[dash + " — ".len .. ^1]
      r.add (n, what, src)
    r
  PlugBundledSig = block:
    var all = ""
    for (n, _, src) in PlugBundled: all.add n & "\0" & src
    $(hash(all) and 0xFFFFFFF)
  PlugExamples = [
    ("zig-lite", "a language ned does not have (Zig), its formatter (zig fmt, or one in NimScript), zls",
     @[("plugin.nims", staticRead(PlugExDir & "/" & "zig-lite" & "/" & "plugin.nims"))]),
    ("wordinfo-lsp", "a language server written in NimScript (hover, completion, diagnostics) for text files",
     @[("plugin.nims", staticRead(PlugExDir & "/" & "wordinfo-lsp" & "/" & "plugin.nims")),
       ("server.nims", staticRead(PlugExDir & "/" & "wordinfo-lsp" & "/" & "server.nims"))]),
    ("commentary", "vim: the gc operator (gcc, gcip, gc in visual mode), the ie text object, :Comment",
     @[("plugin.nims", staticRead(PlugExDir & "/" & "commentary" & "/" & "plugin.nims"))]),
    ("ini-tools", "a language's features: completions, hover, symbols (the outline), code actions, snippets — " &
     "for .ini files; a dock view, progress and the Output panel; a tool for the assistant",
     @[("plugin.nims", staticRead(PlugExDir & "/" & "ini-tools" & "/" & "plugin.nims"))]),
    ("clock-native", "a plugin in full Nim (plugin.nim), compiled into a program of its own: std/times, a timer, " &
     "a status-bar clock",
     @[("plugin.nim", staticRead(PlugExDir & "/" & "clock-native" & "/" & "plugin.nim"))]),
    ("notes", "the plugin tutorial's (docs/plugins/tutorial.md): the TODO, NOTE and FIXME notes of your files — " &
     "commands, signs and fixes, a setting, a dock view, completion and hover, vim keys, a timer, a tool for the assistant",
     @[("plugin.nims", staticRead(PlugExDir & "/" & "notes" & "/" & "plugin.nims"))])]
  PlugTemplate = """## $1 — a ned plugin (NimScript). ned runs it when it starts; edit it and save: the plugins reload.
## The API: the comments of nedplugin.nim (Plugins dock › ⓘ) — commands, keys, events, the text, problems,
## signs, languages, formatters, language servers, completions, hover, symbols, vim mappings, timers.
import nedplugin

requiresNed(">= 6.20")

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
  PlugTemplateFull = """## $1 — a ned plugin in full Nim: ned compiles it (nim c, in the background, again when it changes) into a
## program of its own beside the editor — the whole standard library (std/times, osproc, threads, sockets …),
## and its own process: a slow call of its never holds up the other plugins. Edit it and save: it is built again.
## The API: the comments of nedplugin.nim (Plugins dock › ⓘ).
import nedplugin
import std/times

requiresNed(">= 6.20")

command "$1: what time is it":
  message("$1 (compiled): " & now().format("HH:mm:ss"))

discard every(1000) do ():
  status("⏱ " & now().format("HH:mm"))
"""

type
  PlugInfo = object
    id, dir, file: string
    project, enabled: bool
    full: bool                            # a plugin.nim: full Nim, compiled, a process of its own
    alone: bool                           # a process of its own (full Nim, or plugins.alone)
    needs: string                         # requiresNed("…"): the ned it needs
    err: string                           # why it is not running ("" running, or off)
    bundled: bool                         # one of ned's own plugins (plugins/ in ned's source), turned on
    desc: string                          # what it does (ned's own: the first line of its ## comment)
  PlugReg = object
    plugin, kind: string
    cb: int
    data: JsonNode
    nth: int                              # the plugin's earlier registrations with the same identity (two onChange("*"))
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
  PlugHost = ref object
    ## one process of plugins: the NimScript ones together (name "*"), or one plugin alone (its name)
    name: string
    ids: seq[string]                      # the plugins it runs
    full: bool                            # a plugin in full Nim (always compiled)
    pr: Proc
    fdIn, fdOut, fdErr: cint
    rbuf, wbuf, errPart: string
    state: string                         # off · building · starting · ready · failed: … · stopped (idle)
    startedAt, lastUse: MonoTime
    sig: string                           # the plugins (and their files' stamps) it runs
    native: bool                          # runs compiled
    building: bool                        # (its compiled program is being built)
    calls: Table[int, PlugCall]
    queue: seq[PlugQueued]
    nextRid: int
    errTail: seq[string]
    running: string                       # the plugin whose call runs now (its echo is its log)
    regs, newRegs: seq[PlugReg]           # what it registered (or the manifest's, until it runs); while it starts
    startupFired: bool
  PlugView = object
    plugin, title, key, clickKey: string
    items: JsonNode                       # (the last answer)
    askedAt: MonoTime
    pending, stale: bool

var
  plugs: seq[PlugInfo]
  plugHosts: seq[PlugHost]
  plugRegs: seq[PlugReg]                  # every process's registrations
  plugFailedOnce: HashSet[string]         # plugins left out after they broke a start (until their file changes)
  plugLog: seq[(string, string)]          # plugin, a line
  plugCmdNames: seq[string]
  plugTimers: seq[PlugTimer]
  plugEvts: seq[(string, string, string)] # event, pattern, registration key
  plugVimMaps: seq[(string, string, string, string)]   # mode (n v), keys, registration key, language ("" any)
  plugLangKeys: Table[string, string]     # "<language>\t<key name>" → registration key (keys of one language)
  plugWriters: Table[string, string]      # language → registration key: saving a tab of it (not a file)
  plugKeyHints: seq[(string, string)]     # the box of what the next key does (which-key): key, what it does
  plugKeyHintsTitle = ""
  plugKeyHintsFor = ""                    # the keys waiting it is for (mode & "\t" & keys)
  plugKeysSeen = ""                       # the keys waiting the last round (mode & "\t" & keys)
  plugKeysSince = MonoTime()
  plugKeysFired: seq[string]              # the "keys" events told of them
  plugCurSeen = -1                        # the buffer in front the last round ("enter" events)
  plugSelects = 0                         # (the plugins' select and setCursor calls: did a vmap select something?)
  plugOps: seq[(string, string)]          # keys, registration key
  plugTextObjs: Table[string, string]     # keys ("ie") → registration key
  plugExCmds: Table[string, string]       # name → registration key
  plugLspCmds: seq[(string, seq[string])] # language id, the command
  plugProviders: seq[(string, string, string)]   # what (completion hover codeActions symbols), language id, key
  plugViews: seq[PlugView]
  plugBootAt = MonoTime()                 # when the plugins are looked at (after the first frame)
  plugBooted = false
  plugOpenQ: seq[int]                     # buffers opened (their "open" events, once the registrations are known)
  plugChangeSent: Table[int, int]         # buffer id → the change the "change" event was sent for
  plugUi: (int, string)                   # an answer a plugin waits for from you: (api id, pick · ask · confirm)
  plugUiHost: PlugHost
  plugUiTitle = ""
  plugSeq = ""                            # vim: keys typed of a plugin's mapping
  plugOpKeys = ""                         # vim: a plugin's operator waiting for its motion
  plugOpObj = '\0'
  plugOpWait = '\0'                       # vim: a plugin's operator, the first key of a two-key motion (gg, f{char})
  plugOpCount = 1
  plugReplaying = false
  plugSilentSave = false                  # (a save a plugin asked for: no plugin events)
  plugSyncDepth = 0
  plugCompAt: (int, int, int)             # the completion the plugins were asked for: buffer, line, word start
  plugCompItems: seq[CompItem]            # their answers
  plugCompRound = 0
  plugHoverAt: (int, Pos)                 # the hover they were asked for: buffer, where
  plugOutlines: Table[int, (int, seq[SideItem])]   # buffer id → (its change, the plugins' symbols)
  plugOutlineAsked: Table[int, int]       # buffer id → the change they were asked about
  plugNewFull = false                     # (New plugin…: in full Nim)

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

proc plugBundledRoot(): string =
  ## ned's own plugins as this ned has them (written once per version of them; the ones of other versions removed)
  result = plugCacheRoot() / ("bundled-" & PlugBundledSig)
  if dirExists(result): return
  try:
    for kind, d in walkDir(plugCacheRoot()):
      if kind == pcDir and extractFilename(d).startsWith("bundled-"): removeDir(d)
    for (n, _, src) in PlugBundled:
      createDir(result / n)
      writeFile(result / n / "plugin.nims", src)
  except CatchableError: discard

proc plugBundledOn(): seq[string] =
  ## the names of ned's own plugins you turned on (plugins.bundled)
  for x in jitems(sval("plugins.bundled")):
    if x.kind == JString: result.add x.getStr

proc plugBundledWhat(n: string): string =
  for (name, what, _) in PlugBundled:
    if name == n: return what

proc plugLogAdd(plugin, line: string) =
  plugLog.add (plugin, (if line.len > 400: line[0 ..< 400] & "…" else: line))
  if plugLog.len > 400: plugLog = plugLog[^300 .. ^1]
  if rightOpen and rightView == svPlugins: needRender = true

proc plugsOn(): bool = sval("plugins.enabled").getBool(true)

func plugIdOk(id: string): bool =
  id.len > 0 and id.len <= 64 and id.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}) and id[0] != '.'

proc plugDisabledIds(): seq[string] =
  for x in jitems(sval("plugins.disabled")): result.add x.getStr

proc plugAloneIds(): seq[string] =
  for x in jitems(sval("plugins.alone")): result.add x.getStr

proc plugNativeMode(): string =
  ## plugins.native: auto (a set of plugins run before unchanged is compiled, in the background) · on · off
  let v = sval("plugins.native")
  if v.kind == JBool: (if v.getBool: "on" else: "off")
  elif v.getStr in ["on", "off", "auto"]: v.getStr
  else: "auto"

func plugVerParts(v: string): seq[int] =
  for x in v.strip.split('.'):
    var n = 0
    for c in x:
      if c in Digits: n = n * 10 + (ord(c) - ord('0'))
      else: break
    result.add n

func plugVerCmp(a, b: seq[int]): int =
  for i in 0 ..< max(a.len, b.len):
    let x = if i < a.len: a[i] else: 0
    let y = if i < b.len: b[i] else: 0
    if x != y: return cmp(x, y)
  0

func plugNeedsOk(spec, have: string): bool =
  ## ">= 6.20", "6.20", ">6.19, <7" against this ned's version
  result = true
  for part in spec.split(','):
    var s = part.strip
    var op = ">="
    for o in [">=", "<=", "==", ">", "<", "="]:
      if s.startsWith(o):
        op = o
        s = s[o.len .. ^1].strip
        break
    if s.len == 0 or s[0] notin Digits: continue
    let c = plugVerCmp(plugVerParts(have), plugVerParts(s))
    let ok = case op
      of ">=": c >= 0
      of "<=": c <= 0
      of ">": c > 0
      of "<": c < 0
      else: c == 0
    if not ok: return false

proc plugNeedsOf(file: string): string =
  ## requiresNed("…") in the plugin's source (read before it runs: an older ned never runs it)
  try:
    let t = readFile(file)
    let k = t.find("requiresNed")
    if k < 0: return ""
    let q = t.find('"', k)
    let nl = t.find('\n', k)
    if q < 0 or (nl >= 0 and q > nl): return ""
    let e = t.find('"', q + 1)
    if e > q: return t[q + 1 ..< e]
  except CatchableError: discard
  ""

proc plugDiscover() =
  ## the plugin folders: yours, then the project's (a name that is yours is yours)
  plugs.setLen(0)
  let off = plugDisabledIds()
  let alone = plugAloneIds()
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
      if not plugIdOk(id): continue
      let full = not fileExists(d / "plugin.nims") and fileExists(d / "plugin.nim")
      if not full and not fileExists(d / "plugin.nims"): continue
      var dup = false
      for p in plugs:
        if p.id == id: dup = true
      if dup: continue
      var p = PlugInfo(id: id, dir: d, file: d / (if full: "plugin.nim" else: "plugin.nims"), project: project,
                       enabled: id notin off, full: full, alone: full or id in alone)
      p.needs = plugNeedsOf(p.file)
      if not p.enabled: p.err = "off"
      elif project and not codeTrusted(rootDir):
        p.enabled = false
        p.err = "the folder is not trusted"
      elif p.needs.len > 0 and not plugNeedsOk(p.needs, Version):
        p.enabled = false
        p.err = "it needs ned " & p.needs & " (this is " & Version & ")"
      elif id in plugFailedOnce:
        p.enabled = false
        p.err = "it broke the plugins' start (fix it and save)"
      plugs.add p
  # ned's own plugins you turned on (a plugin of yours with the same name is the one that runs)
  let bon = plugBundledOn()
  if bon.len > 0:
    let root = plugBundledRoot()
    for (n, what, _) in PlugBundled:
      if n notin bon: continue
      var dup = false
      for p in plugs:
        if p.id == n: dup = true
      if dup or not fileExists(root / n / "plugin.nims"): continue
      var p = PlugInfo(id: n, dir: root / n, file: root / n / "plugin.nims", enabled: n notin off, bundled: true,
                       alone: n in alone, desc: what)
      p.needs = plugNeedsOf(p.file)
      if not p.enabled: p.err = "off"
      elif p.needs.len > 0 and not plugNeedsOk(p.needs, Version):
        p.enabled = false
        p.err = "it needs ned " & p.needs & " (this is " & Version & ")"
      elif n in plugFailedOnce:
        p.enabled = false
        p.err = "it broke the plugins' start"
      plugs.add p

proc plugInfoOf(id: string): int =
  for i, p in plugs:
    if p.id == id: return i
  -1

proc plugHostOf(plugin: string): PlugHost =
  for h in plugHosts:
    if plugin in h.ids: return h
  nil

proc plugLabel(h: PlugHost): string = (if h.name == PlugShared: "plugins" else: h.name)

proc plugSignature(h: PlugHost): string =
  ## what the process is made of: each plugin and its files' stamps (a change: a new process, a new build)
  var s = Version & "|" & plugLibDir() & "|" & $h.full
  for id in h.ids:
    let i = plugInfoOf(id)
    if i < 0: continue
    s.add "|" & id & "=" & plugs[i].dir
    try:
      for f in walkDirRec(plugs[i].dir):
        if f.endsWith(".nim") or f.endsWith(".nims"):
          let (mt, sz) = fileStamp(f)
          s.add ";" & f & ":" & $mt & ":" & $sz
    except OSError: discard
  $(hash(s) and 0xFFFFFFFFFFFF)

proc plugStop(h: PlugHost, why = "off")

proc plugMakeHosts() =
  ## the processes the enabled plugins want: the NimScript ones together, each full-Nim (or alone) one by itself —
  ## a process whose plugins did not change is kept (and keeps running)
  var want: seq[(string, seq[string], bool)]
  var shared: seq[string]
  for p in plugs:
    if not p.enabled: continue
    if p.alone: want.add (p.id, @[p.id], p.full)
    else: shared.add p.id
  if shared.len > 0: want.insert((PlugShared, shared, false), 0)
  var keep: seq[PlugHost]
  for (n, ids, full) in want:
    var found: PlugHost = nil
    for h in plugHosts:
      if h.name == n and h.ids == ids and h.full == full: found = h
    keep.add (if found != nil: found
              else: PlugHost(name: n, ids: ids, full: full, state: "off", fdIn: -1, fdOut: -1, fdErr: -1,
                             pr: Proc(pid: -1, inFd: -1, outFd: -1, errFd: -1)))
  for h in plugHosts:
    if h notin keep: plugStop(h, "off")
  plugHosts = keep

# ── registrations ──

proc plugInvoke(key: string, args: JsonNode, onDone: proc(v: JsonNode, err: string) {.closure.} = nil)
proc plugPendingKeys(): (string, string)
proc plugCallSync(key: string, args: JsonNode, ms = -1): (bool, JsonNode, string)
proc plugKeyHost(key: string): PlugHost

proc regBaseKey(r: PlugReg): string =
  ## a registration's identity (its callback number may change when the host is made again) — without its number
  ## among the plugin's registrations of the same identity (see regKey)
  let d = r.data
  r.plugin & "|" & r.kind & "|" & (case r.kind
    of "command": d{"title"}.getStr
    of "event": d{"event"}.getStr & " " & d{"pattern"}.getStr
    of "vimMap": d{"mode"}.getStr & " " & d{"keys"}.getStr & (if d{"lang"}.getStr.len > 0: " " & d{"lang"}.getStr else: "")
    of "langKey": d{"lang"}.getStr & " " & d{"keys"}.getStr
    of "writer": d{"lang"}.getStr
    of "operator", "textObject": d{"keys"}.getStr
    of "ex": d{"name"}.getStr
    of "formatter", "lsp", "completion", "hover", "codeActions", "symbols": d{"lang"}.getStr.toLowerAscii
    of "language": d{"id"}.getStr
    of "aiTool": d{"name"}.getStr
    of "view", "viewClick": d{"title"}.getStr
    of "snippet": d{"lang"}.getStr & " " & d{"trigger"}.getStr
    of "setting": d{"key"}.getStr
    else: $r.cb)

proc regKey(r: PlugReg): string =
  ## a registration's identity: two of one plugin with the same identity (two onChange("*"), two hovers for one
  ## language) are told apart by their order, which is the same each time the plugin runs
  if r.nth > 0: regBaseKey(r) & "#" & $r.nth else: regBaseKey(r)

proc regNth(regs: seq[PlugReg], r: PlugReg): int =
  ## how many of `regs` have `r`'s identity (what r.nth should be when r is added after them)
  let k = regBaseKey(r)
  for q in regs:
    if q.plugin == r.plugin and q.kind == r.kind and regBaseKey(q) == k: inc result

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
  ## "<leader>f" → " f" (the leader is the space bar), <space> <cr> <tab> as themselves, <C-a> … <C-z> as the
  ## control characters vim mode hands plugins for Ctrl+A … Ctrl+Z
  result = keys.multiReplace([("<leader>", " "), ("<Leader>", " "), ("<space>", " "), ("<Space>", " "), ("<cr>", "\r"),
                              ("<CR>", "\r"), ("<Enter>", "\r"), ("<tab>", "\t"), ("<Tab>", "\t")])
  for c in 'a'..'z':
    for spec in ["<C-" & $c & ">", "<c-" & $c & ">", "<C-" & $c.toUpperAscii & ">"]:
      result = result.replace(spec, $chr(ord(c) - 96))

func vimKeysShow(keys: string): string =
  ## the keys as vim writes them: " f" → "<leader>f", Ctrl+A → "<C-a>", Enter → "<CR>"
  for c in keys:
    case c
    of ' ': result.add "<leader>"
    of '\r': result.add "<CR>"
    of '\t': result.add "<Tab>"
    of '\x01'..'\x08', '\x0b'..'\x0c', '\x0e'..'\x1a': result.add "<C-" & $chr(ord(c) + 96) & ">"
    else: result.add c

func plugToolName(plugin, name: string): string =
  ## what the model calls a plugin's tool: plugin__<plugin>__<tool> (letters, digits, _ and -; 64 at most)
  result = "plugin__"
  for c in plugin & "__" & name:
    result.add (if c.isAlphaNumeric or c in {'_', '-'}: c else: '_')
  if result.len > 64: result = result[0 ..< 64]

proc plugAiSchema(params: JsonNode): JsonNode =
  ## a tool's arguments: a JSON schema as given, or its properties (every one of them required)
  if params != nil and params.kind == JObject and params{"type"}.getStr == "object": return params
  var req = newJArray()
  var props = newJObject()
  if params != nil and params.kind == JObject:
    for k, v in params:
      props[k] = v
      if not v{"optional"}.getBool(false): req.add %k
  %*{"type": "object", "properties": props, "required": req}

proc plugApplyRegs() =
  ## the registrations → the palette, keys, languages, formatters, servers, providers, vim's tables, events, timers
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
  plugLangKeys.clear()
  plugWriters.clear()
  plugOps.setLen(0)
  plugTextObjs.clear()
  plugTextObjKeys.clear()
  plugExCmds.clear()
  plugLspCmds.setLen(0)
  plugProviders.setLen(0)
  plugSnippets.setLen(0)
  plugAiTools.setLen(0)
  var views: seq[PlugView]
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
    of "completion", "hover", "codeActions", "symbols":
      plugProviders.add (r.kind, d{"lang"}.getStr("*").toLowerAscii, key)
    of "snippet":
      plugSnippets.add (d{"lang"}.getStr("*").toLowerAscii, d{"trigger"}.getStr,
                        (if d{"description"}.getStr.len > 0: d{"description"}.getStr else: r.plugin & " snippet"),
                        d{"body"}.getStr)
    of "aiTool":
      plugAiTools.add PlugAiTool(name: plugToolName(r.plugin, d{"name"}.getStr), desc: d{"description"}.getStr,
                                 plugin: r.plugin, key: key, schema: plugAiSchema(d{"params"}),
                                 readOnly: d{"readOnly"}.getBool)
    of "view":
      var v = PlugView(plugin: r.plugin, title: d{"title"}.getStr, key: key, stale: true)
      for old in plugViews:
        if old.key == key:
          v.items = old.items                # (shown until the new items come)
      views.add v
    of "setting":
      let k = "plugins." & r.plugin & "." & d{"key"}.getStr
      if d{"key"}.getStr.len > 0 and k notin setIndex and d{"default"} != nil:
        defS("Plugins", k, d["default"], "(" & r.plugin & ") " & d{"description"}.getStr)
    of "event": plugEvts.add (d{"event"}.getStr, d{"pattern"}.getStr("*"), key)
    of "vimMap": plugVimMaps.add (d{"mode"}.getStr("n"), vimKeysOf(d{"keys"}.getStr), key, d{"lang"}.getStr.toLowerAscii)
    of "langKey":
      let n = plugKeyNorm(d{"keys"}.getStr)
      if n.len > 0: plugLangKeys[d{"lang"}.getStr.toLowerAscii & "\t" & n] = key
    of "writer": plugWriters[d{"lang"}.getStr.toLowerAscii] = key
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
  # (a view's click: on the view)
  for r in plugRegs:
    if r.kind == "viewClick":
      for v in views.mitems:
        if v.plugin == r.plugin and v.title == r.data{"title"}.getStr: v.clickKey = regKey(r)
  plugViews = views
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
  plugOutlines.clear()
  plugOutlineAsked.clear()
  needRender = true

proc plugRebuildRegs() =
  ## every process's registrations together (a plugin that needs a newer ned: its registrations left out)
  plugRegs.setLen(0)
  for h in plugHosts:
    for r in h.regs: plugRegs.add r
  plugApplyRegs()

proc plugEagerHost(h: PlugHost): bool =
  ## must the process run from the start (it answers events, keeps time, formats, gives text objects, completes,
  ## hovers, lists symbols, shows a view)?
  for r in h.regs:
    if r.kind in ["timer", "textObject", "completion", "hover", "symbols", "codeActions", "view"] or
       (r.kind == "formatter" and r.cb >= 0): return true
    if r.kind == "event" and r.data{"event"}.getStr in ["startup", "open", "change", "beforeSave", "keys"]: return true
  false

proc plugManifestFile(): string = plugCacheRoot() / "manifest.json"

proc plugManifest(): JsonNode =
  try:
    result = parseFile(plugManifestFile())
    if result.kind != JObject or result{"hosts"} == nil or result["hosts"].kind != JObject:
      result = %*{"hosts": {}}
  except CatchableError: result = %*{"hosts": {}}

proc plugSaveManifest(h: PlugHost) =
  var a = newJArray()
  for r in h.regs: a.add %*{"plugin": r.plugin, "kind": r.kind, "cb": r.cb, "data": r.data, "nth": r.nth}
  let m = plugManifest()
  m["hosts"][h.name] = %*{"sig": h.sig, "regs": a}
  try:
    createDir(plugCacheRoot())
    writeFile(plugManifestFile(), $m)
  except CatchableError: discard

proc plugLoadManifest(h: PlugHost): bool =
  ## the registrations the process made last time it ran these plugins: commands and keys at once, no process yet
  let e = plugManifest()["hosts"]{h.name}
  if e == nil or e{"sig"}.getStr != h.sig: return false
  h.regs.setLen(0)
  for r in jitems(e{"regs"}):
    h.regs.add PlugReg(plugin: r{"plugin"}.getStr, kind: r{"kind"}.getStr, cb: r{"cb"}.getInt(-1), data: r{"data"},
                       nth: r{"nth"}.getInt(0))
  true

# ── the processes ──

proc plugSendRaw(h: PlugHost, j: JsonNode) =
  if h.fdIn < 0: return
  h.wbuf.add $j & "\n"

proc plugFlush(h: PlugHost, block_ms = 0) =
  ## what is waiting for the process, written (block_ms > 0: until it is all gone, that long at most)
  let t0 = getMonoTime()
  while h.wbuf.len > 0 and h.fdIn >= 0:
    let n = posix.write(h.fdIn, addr h.wbuf[0], h.wbuf.len)
    if n > 0:
      h.wbuf = h.wbuf[n .. ^1]
      continue
    if n < 0 and errno in [EAGAIN, EINTR]:
      if block_ms <= 0 or msSince(t0) > block_ms: break
      var pf = TPollfd(fd: h.fdIn, events: POLLOUT)
      discard poll(addr pf, 1, 20)
      continue
    h.wbuf.setLen(0)                       # (the process is gone)
    break

proc plugStop(h: PlugHost, why = "off") =
  if h.pr.pid > 0:
    plugSendRaw(h, %*{"t": "quit"})
    plugFlush(h, 50)
    discard posix.kill(Pid(-h.pr.pid), SIGTERM)
    discard waitProc(h.pr, 150)
  closeFd(h.fdIn)
  closeFd(h.fdOut)
  closeFd(h.fdErr)
  h.fdIn = -1
  h.fdOut = -1
  h.fdErr = -1
  h.pr = Proc(pid: -1, inFd: -1, outFd: -1, errFd: -1)
  h.rbuf.setLen(0)
  h.wbuf.setLen(0)
  let calls = h.calls
  h.calls.clear()
  for rid, c in calls:
    if c.onDone != nil:
      try: c.onDone(nil, "the plugins stopped")
      except CatchableError: discard
  if plugUiHost == h:
    plugUi = (0, "")
    plugUiHost = nil
  h.state = why
  needRender = true

proc plugQuitEvents() =
  ## ned quits: the plugins' "quit" events, each waited for a moment (what they keep is written)
  if plugEvts.len == 0: return
  for (ev, _, key) in plugEvts:
    let h = plugKeyHost(key)
    if ev == "quit" and h != nil and h.state == "ready": discard plugCallSync(key, newJObject(), 1500)

proc plugStopAll() =
  for h in plugHosts: plugStop(h)

proc plugHostSource(h: PlugHost): string =
  result = "# made by ned " & Version & ": " & (if h.name == PlugShared: "your NimScript plugins (and the project's)"
                                                 else: "the plugin " & h.name) & " in one process\nimport nedplugin\n"
  for i, id in h.ids:
    let k = plugInfoOf(id)
    if k >= 0: result.add "import " & escape(plugs[k].file) & " as nedPlug" & $i & "\n"
  result.add "nedRun()\n"

proc plugBin(h: PlugHost): string = plugCacheRoot() / "native" / ("host-" & h.sig)

proc plugOwnerOf(path: string): string =
  for p in plugs:
    if path == p.dir or path.startsWith(p.dir & "/"): return p.id
  ""

proc plugCompileErrors(h: PlugHost, output: string): int =
  ## a build's errors in the plugins' files → Problems (how many)
  var errs: Table[string, seq[Diag]]
  for l in output.splitLines:
    let (ok, path, ln, c, sev, m) = parseErrLine(stripAnsi(l), plugUserRoot())
    if ok and sev == 1:
      let owner = plugOwnerOf(path)
      if owner.len > 0:
        errs.mgetOrPut(path, @[]).add Diag(line: ln, col: c, eline: ln, ecol: -1, sev: 1, msg: m,
                                         src: "plugin " & owner)
        plugLogAdd(owner, extractFilename(path) & ":" & $(ln + 1) & ": " & m)
  for p, ds in errs:
    diagsExt[p] = ds
    inc result, ds.len
  if errs.len > 0: rebuildProblems()

proc plugStart(h: PlugHost)

proc plugBuild(h: PlugHost, startAfter: bool) =
  ## the process compiled (nim c, in the background): a full-Nim plugin before it can run; the NimScript plugins
  ## (plugins.native) for the next start
  if h.building: return
  let sig = h.sig
  let bin = plugBin(h)
  let src = plugCacheRoot() / "native" / ("host_" & sig & ".nim")
  if findExe("nim").len == 0:
    if startAfter: h.state = "failed: building it needs nim (Termux: pkg install nim)"
    return
  try:
    createDir(parentDir(src))
    writeFile(src, plugHostSource(h))
  except CatchableError as e:
    if startAfter: h.state = "failed: " & e.msg
    return
  var dirs: seq[string]
  for id in h.ids:
    let k = plugInfoOf(id)
    if k >= 0: dirs.add "--path:" & quoteShell(plugs[k].dir)
  let cmd = "nim c -d:release --hints:off --warnings:off --path:" & quoteShell(plugLibDir()) & " " & dirs.join(" ") &
            " --nimcache:" & quoteShell(plugCacheRoot() / "native" / ("nimcache-" & (if h.name == PlugShared: "shared"
                                                                                     else: h.name))) &
            " -o:" & quoteShell(bin) & " " & quoteShell(src)
  h.building = true
  if startAfter:
    h.state = "building"
    h.startedAt = getMonoTime()
  let t0 = getMonoTime()
  let j = startJob(jkTool, cmd, plugCacheRoot(), proc(j: Job) =
    h.building = false
    try: removeFile(src)
    except CatchableError: discard
    if h.sig != sig: return                  # (its plugins changed meanwhile)
    if j.code == 0 and fileExists(bin):
      plugLogAdd(plugLabel(h), "compiled in " & $(msSince(t0) div 1000) & " s" &
                 (if startAfter: "" else: " — the next start uses it"))
      if startAfter and h.state == "building":
        h.state = "off"
        plugStart(h)
    else:
      try: writeFile(bin & ".failed", "")
      except CatchableError: discard
      let n = plugCompileErrors(h, j.output)
      if startAfter:
        plugStop(h, "failed: it does not compile" & (if n > 0: " (Problems)" else: ""))
        for l in j.output.splitLines:
          if "Error" in l: plugLogAdd(plugLabel(h), stripAnsi(l))
        toast("The plugin " & h.name & " does not compile — its errors are in Problems", 2)
        let q = h.queue
        h.queue.setLen(0)
        for x in q:
          if x.onDone != nil: x.onDone(nil, h.state)
      else:
        plugLogAdd(plugLabel(h), "the compiled process could not be built (a plugin uses what only NimScript has?)" &
                   " — staying with nim e"))
  if j == nil:
    h.building = false
    if startAfter: h.state = "failed: could not run nim c"

proc plugStart(h: PlugHost) =
  ## the process (nothing when its plugins are off; a full-Nim plugin is built first)
  if h.pr.pid > 0 or h.building: return
  if not plugsOn():
    h.state = "off"
    return
  h.sig = plugSignature(h)
  let bin = plugBin(h)
  var argv: seq[string]
  h.native = false
  if fileExists(bin):
    argv = @[bin]
    h.native = true
  elif h.full:
    if fileExists(bin & ".failed") and h.state.startsWith("failed"): return
    plugBuild(h, true)
    return
  else:
    if findExe("nim").len == 0:
      h.state = "failed: plugins need nim (Termux: pkg install nim)"
      return
    let hostFile = plugCacheRoot() / "host" / ("host_" & h.sig & ".nims")
    try:
      createDir(parentDir(hostFile))
      writeFile(hostFile, plugHostSource(h))
    except CatchableError as e:
      h.state = "failed: " & e.msg
      return
    argv = @["nim", "e", "--hints:off", "--warnings:off", "--path:" & plugLibDir(), hostFile]
    # (compiled for the next start: always with plugins.native on; with auto, a set of plugins run before as they are)
    let mode = plugNativeMode()
    let seen = plugManifest()["hosts"]{h.name}{"sig"}.getStr == h.sig
    if mode == "on" or (mode == "auto" and seen and not fileExists(bin & ".failed")): plugBuild(h, false)
  var dirs: seq[string]
  for id in h.ids:
    let k = plugInfoOf(id)
    if k >= 0: dirs.add id & "=" & plugs[k].dir
  let saved = (getEnv("NED_PLUGIN_DIRS"), existsEnv("NED_PLUGIN_DIRS"))
  putEnv("NED_PLUGIN_DIRS", dirs.join("\n"))
  try:
    let cwd = plugUserRoot()
    createDir(cwd)
    var p = spawnProc(argv, cwd, siPipe, erPipe, niceness = 5)
    h.pr = p
    h.fdIn = p.inFd
    h.fdOut = p.outFd
    h.fdErr = p.errFd
    h.pr.inFd = -1
    h.pr.outFd = -1
    h.pr.errFd = -1
    setNonBlock(h.fdIn); setNonBlock(h.fdOut); setNonBlock(h.fdErr)
    h.state = "starting"
    h.startedAt = getMonoTime()
    h.lastUse = getMonoTime()
    h.errTail.setLen(0)
    h.newRegs.setLen(0)
  except CatchableError as e:
    h.state = "failed: " & e.msg
  if saved[1]: putEnv("NED_PLUGIN_DIRS", saved[0]) else: delEnv("NED_PLUGIN_DIRS")

proc plugHostDied(h: PlugHost) =
  ## the process ended: a plugin that did not compile is left out (its error in Problems) and the rest start again
  var culprit = ""
  var errs: Table[string, seq[Diag]]
  for l in h.errTail:
    let (ok, path, ln, c, sev, m) = parseErrLine(l, plugUserRoot())
    if ok and sev == 1:
      let owner = plugOwnerOf(path)
      if owner.len > 0:
        if culprit.len == 0: culprit = owner
        errs.mgetOrPut(path, @[]).add Diag(line: ln, col: c, eline: ln, ecol: -1, sev: 1, msg: m,
                                         src: "plugin " & owner)
  for p, ds in errs: diagsExt[p] = ds
  if errs.len > 0: rebuildProblems()
  let wasStarting = h.state == "starting"
  let last = if h.errTail.len > 0: h.errTail[^1] else: "it exited"
  plugStop(h, "failed: " & last)
  if culprit.len > 0 and h.name == PlugShared and h.ids.len > 1:
    plugFailedOnce.incl culprit
    plugLogAdd(culprit, "left out: " & last)
    toast("Plugin " & culprit & " has an error — the others run without it (Plugins dock)", 2)
    if wasStarting:
      # (the others, in a process of their own)
      plugDiscover()
      plugMakeHosts()
      for x in plugHosts:
        if x.state == "off":
          discard plugLoadManifest(x)
          plugStart(x)
      plugRebuildRegs()
  elif culprit.len > 0:
    plugFailedOnce.incl culprit
    plugLogAdd(culprit, "left out: " & last)
    toast("Plugin " & culprit & " has an error — it is left out (Plugins dock)", 2)
    plugDiscover()                             # (its process goes: it is off until its file changes)
    plugMakeHosts()
    plugRebuildRegs()
  elif wasStarting:
    toast((if h.name == PlugShared: "The plugins could not start: " else: "The plugin " & h.name & " could not start: ") &
          last, 1)
  let q = h.queue
  h.queue.setLen(0)
  for x in q:
    if x.onDone != nil: x.onDone(nil, h.state)

proc plugLineOut(h: PlugHost, line: string)

proc plugReadOut(h: PlugHost) =
  var tmp: array[65536, char]
  var gone = false
  while h.fdOut >= 0:
    let n = posix.read(h.fdOut, addr tmp[0], tmp.len)
    if n > 0:
      let old = h.rbuf.len
      h.rbuf.setLen(old + n)
      copyMem(addr h.rbuf[old], addr tmp[0], n)
    elif n == 0:
      gone = true
      break
    else: break
  while true:
    let nl = h.rbuf.find('\n')
    if nl < 0: break
    let line = h.rbuf[0 ..< nl]
    h.rbuf = h.rbuf[nl + 1 .. ^1]
    plugLineOut(h, line)
  if gone and h.pr.pid > 0: plugHostDied(h)

proc plugReadErr(h: PlugHost) =
  var tmp: array[16384, char]
  while h.fdErr >= 0:
    let n = posix.read(h.fdErr, addr tmp[0], tmp.len)
    if n <= 0: break
    var chunk = newString(n)
    copyMem(addr chunk[0], addr tmp[0], n)
    let parts = (h.errPart & chunk).split('\n')
    for k in 0 ..< parts.high:
      let l = stripAnsi(parts[k]).strip
      if l.len == 0: continue
      h.errTail.add l
      let (ok, path, _, _, _, _) = parseErrLine(l, plugUserRoot())
      plugLogAdd((if ok and plugOwnerOf(path).len > 0: plugOwnerOf(path) elif h.running.len > 0: h.running
                  else: plugLabel(h)), l)
    h.errPart = parts[^1]
    if h.errTail.len > 40: h.errTail = h.errTail[^30 .. ^1]

# ── calling the plugins ──

proc plugSendCall(h: PlugHost, cb: int, plugin: string, args: JsonNode,
                  onDone: proc(v: JsonNode, err: string) {.closure.}): int =
  inc h.nextRid
  result = h.nextRid
  h.calls[result] = PlugCall(plugin: plugin, sentAt: getMonoTime(), onDone: onDone)
  plugSendRaw(h, %*{"t": "call", "cb": cb, "rid": result, "args": args})
  plugFlush(h)
  h.lastUse = getMonoTime()

proc plugKeyHost(key: string): PlugHost =
  let i = regByKey(key)
  plugHostOf(if i >= 0: plugRegs[i].plugin else: key.split('|')[0])

proc plugInvoke(key: string, args: JsonNode, onDone: proc(v: JsonNode, err: string) {.closure.}) =
  ## call a registration's callback (its process starts first when it is not running: the call waits for it)
  let h = plugKeyHost(key)
  if h == nil:
    if onDone != nil: onDone(nil, "the plugin is not running")
    return
  if h.state == "ready":
    let i = regByKey(key)
    if i < 0 or plugRegs[i].cb < 0:
      if onDone != nil: onDone(nil, "no such plugin callback")
      return
    discard plugSendCall(h, plugRegs[i].cb, plugRegs[i].plugin, args, onDone)
    return
  h.queue.add PlugQueued(key: key, args: args, onDone: onDone)
  if h.state notin ["starting", "building"]:
    plugStart(h)
    if h.state notin ["starting", "building"]:
      let q = h.queue
      h.queue.setLen(0)
      for x in q:
        if x.onDone != nil: x.onDone(nil, h.state)
      if h.state.startsWith("failed"): warn("Plugins: " & h.state[8 .. ^1])

proc plugHandle(h: PlugHost, j: JsonNode)

proc plugWaitFor(h: PlugHost, done: proc(): bool, ms: int): bool =
  ## the process's messages until done() (or ms): what ned waits for before it goes on (a save, a format …)
  let t0 = getMonoTime()
  inc plugSyncDepth
  defer: dec plugSyncDepth
  while not done():
    if h.fdOut < 0: return false
    let left = ms - int(msSince(t0))
    if left <= 0: return false
    plugFlush(h, left)
    var pf = [TPollfd(fd: h.fdOut, events: POLLIN), TPollfd(fd: h.fdErr, events: POLLIN)]
    let r = poll(addr pf[0], 2, min(left, 50).cint)
    if r > 0:
      if (pf[1].revents and (POLLIN or POLLHUP)) != 0: plugReadErr(h)
      if (pf[0].revents and (POLLIN or POLLHUP or POLLERR)) != 0: plugReadOut(h)
  true

proc plugTimeout(): int = max(200, sval("plugins.timeoutMs").getInt(1500))

proc plugCallSync(key: string, args: JsonNode, ms: int): (bool, JsonNode, string) =
  ## call and wait for the answer (only when the process runs: a start takes a second or more — then: not now)
  let h = plugKeyHost(key)
  if h == nil: return (false, nil, "the plugin is not running")
  if h.state != "ready":
    if h.state notin ["starting", "building"]: plugStart(h)
    return (false, nil, "the plugins are starting")
  let i = regByKey(key)
  if i < 0 or plugRegs[i].cb < 0: return (false, nil, "no such plugin callback")
  var got = false
  var res: JsonNode = nil
  var err = ""
  discard plugSendCall(h, plugRegs[i].cb, plugRegs[i].plugin, args, proc(v: JsonNode, e: string) =
    got = true
    res = v
    err = e)
  if not plugWaitFor(h, proc(): bool = got, (if ms > 0: ms else: plugTimeout())):
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

proc plugFire(event: string, b: Buffer, only: PlugHost = nil) =
  if plugEvts.len == 0 or b == nil or plugSilentSave: return
  for (ev, pat, key) in plugEvts:
    if ev == event and plugMatches(pat, b):
      if only != nil and plugKeyHost(key) != only: continue
      plugInvoke(key, plugEventArgs(b))

# ── the API: what the plugins ask of ned ──

proc plugVimRange(b: Buffer, c: Cursor): (Pos, Pos) =
  ## a selection as the plugin means it: in vim's visual mode the character under the cursor is in it, and in
  ## visual-line mode the whole lines are
  result = c.range
  if cfgVim and b == buf() and vimMode == vmVisual:
    result[1] = b.clampPos(Pos(line: result[1].line, col: nextCluster(b.lines[result[1].line], result[1].col)))
  elif cfgVim and b == buf() and vimMode == vmVLine:
    result = (Pos(line: result[0].line, col: 0), Pos(line: result[1].line, col: b.lines[result[1].line].len))

proc plugAnswer(h: PlugHost, id: int, v: JsonNode, err = "") =
  if err.len > 0: plugSendRaw(h, %*{"t": "res", "id": id, "err": err})
  else: plugSendRaw(h, %*{"t": "res", "id": id, "value": (if v == nil: newJNull() else: v)})
  plugFlush(h)

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

proc plugMarkEdit(h: PlugHost, rid: int, b: Buffer) =
  ## the first edit of a call in a buffer: where its undo step starts
  if rid notin h.calls: return
  for (id, _) in h.calls[rid].marks:
    if id == b.id: return
  h.calls[rid].marks.add (b.id, b.undoStack.len)

proc plugDecorSet(b: Buffer, plugin: string, d: PlugDecor) =
  var x = d
  x.plugin = plugin
  plugDecor.mgetOrPut(plugDecorKey(b), @[]).add x
  needRender = true

proc plugOutput(plugin, text: string) =
  ## a plugin's lines in the Output panel (file:line in them can be clicked)
  for l in text.splitLines:
    var pl = PanelLine(text: plugin & " │ " & l, line: -1)
    let (ok, path, ln, c, sev, _) = parseErrLine(l, rootDir)
    if ok:
      pl.path = path
      pl.line = ln
      pl.col = c
      pl.sev = sev
    addPanelLine(pl)

proc plugTerminal(cmd, dir: string) =
  ## a command in the integrated terminal (a new one when the current one is busy)
  openTerminal()
  var t = curTermObj()
  if t == nil: return
  if t.cmds.len > 0 and t.cmds[^1].ran and t.cmds[^1].endRow < 0:
    newTerminal()
    t = curTermObj()
  termRunText(t, (if dir.len > 0: "cd " & quoteShell(dir) & " && " else: "") & cmd)

proc plugApi(h: PlugHost, j: JsonNode) =
  let id = j{"id"}.getInt
  let fn = j{"fn"}.getStr
  let a = j{"args"}
  let plugin = j{"plugin"}.getStr
  let rid = j{"rid"}.getInt
  h.lastUse = getMonoTime()
  let b = if a != nil and a.hasKey("buf"): bufById(a["buf"].getInt) else: nil
  template answer(v: JsonNode, err = "") = plugAnswer(h, id, v, err)
  template needBuf() =
    if b == nil:
      answer(nil, "no such buffer (it was closed?)")
      return
  template rng(n: JsonNode): (Pos, Pos) =
    (b.clampPos(posOf(n{"start"})), b.clampPos(posOf(n{"stop"})))
  try:
    case fn
    of "current": answer(%buf().id)
    of "root": answer(%rootDir)
    of "open":
      var p = a{"path"}.getStr
      if p.len > 0 and not p.isAbsolute: p = rootDir / p
      let nb = openFile(p, a{"line"}.getInt(-1), a{"col"}.getInt(-1))
      answer(%(if nb == nil: -1 else: nb.id))
    of "newTab":
      # (a tab of its own with the plugin's text: a response, generated code — not a file until it is saved)
      let lg = langByName(a{"lang"}.getStr)
      let title = a{"title"}.getStr("untitled")
      for i, x in bufs:
        if x.title == title and x.path.len == 0 and x.dirty:
          # (that tab has edits not saved: to it, as it is)
          curBuf = i
          focus = fEditor
          needRender = true
          answer(%x.id)
          return
      let nb = openScratch(title, a{"text"}.getStr, (if lg != nil: lg else: langByName("plaintext")))
      if nb != nil: nb.readOnly = false
      answer(%(if nb == nil: -1 else: nb.id))
    of "closeTab":
      needBuf()
      let i = bufs.find(b)
      if i >= 0:
        if b.dirty and b.path.len > 0: closeBuffer(i)     # (a file with edits not saved: you are asked)
        else: closeBufferAt(i)
      needRender = true
      answer(newJNull())
    of "unixTime": answer(%epochTime())
    of "localTime": answer(%now().format("yyyy-MM-dd HH:mm:ss"))
    of "shellAsync":
      # (a command run in the background: its output to the plugin's callback when it ends)
      let dir = if a{"dir"}.getStr.len > 0: a{"dir"}.getStr elif rootDir.len > 0: rootDir else: getCurrentDir()
      let cb = a{"cb"}.getInt(-1)
      let hh = h
      let pl = plugin
      if cb < 0: (answer(nil, "no callback"); return)
      discard startJob(jkTool, a{"cmd"}.getStr, dir, proc(j: Job) =
        if hh.state == "ready" and hh in plugHosts:
          discard plugSendCall(hh, cb, pl, %*{"output": j.output.strip(leading = false, chars = {'\n'}),
                                            "code": j.code}, nil))
      answer(newJNull())
    of "markSaved":
      needBuf()
      b.savedSeq = b.topSeq()
      needRender = true
      answer(newJNull())
    of "title": needBuf(); answer(%b.name)
    of "setTitle":
      needBuf()
      if b.path.len > 0: (answer(nil, "a file's tab is named by its file"); return)
      b.title = a{"title"}.getStr(b.title)
      needRender = true
      answer(newJNull())
    of "pendingKeys":
      let (k, m) = plugPendingKeys()
      answer(%*{"keys": k, "mode": m})
    of "showKeyHints":
      let (k, m) = plugPendingKeys()
      plugKeyHints.setLen(0)
      if k.len > 0:
        for it in jitems(a{"hints"}):
          if it.kind == JArray and it.len >= 2: plugKeyHints.add (it[0].getStr, it[1].getStr)
        plugKeyHintsTitle = a{"title"}.getStr
        plugKeyHintsFor = m & "\t" & k
      needRender = true
      answer(%(k.len > 0))
    of "hideKeyHints":
      plugKeyHints.setLen(0)
      needRender = true
      answer(newJNull())
    of "keyMaps":
      # (which-key: what the plugins put on keys, and the commands with a key — yours and theirs)
      var arr = newJArray()
      for r in plugRegs:
        let d = r.data
        case r.kind
        of "vimMap": arr.add %*{"mode": d{"mode"}.getStr("n"), "keys": d{"keys"}.getStr, "desc": d{"desc"}.getStr,
                                "lang": d{"lang"}.getStr, "plugin": r.plugin}
        of "operator": arr.add %*{"mode": "op", "keys": d{"keys"}.getStr, "desc": d{"desc"}.getStr, "lang": "",
                                  "plugin": r.plugin}
        of "textObject": arr.add %*{"mode": "obj", "keys": d{"keys"}.getStr, "desc": d{"desc"}.getStr, "lang": "",
                                    "plugin": r.plugin}
        of "langKey": arr.add %*{"mode": "key", "keys": d{"keys"}.getStr, "desc": d{"desc"}.getStr,
                                 "lang": d{"lang"}.getStr, "plugin": r.plugin}
        of "command":
          if d{"keys"}.getStr.len > 0:
            arr.add %*{"mode": "key", "keys": d{"keys"}.getStr, "desc": d{"title"}.getStr, "lang": "", "plugin": r.plugin}
        else: discard
      for k, v in cfgKeys: arr.add %*{"mode": "key", "keys": k, "desc": v, "lang": "", "plugin": ""}
      answer(arr)
    of "clipboard": answer(%clipGet())
    of "setClipboard":
      clipSet(a{"text"}.getStr)
      answer(newJNull())
    of "buffers":
      var arr = newJArray()
      for x in bufs:
        if not x.isWelcome(): arr.add %x.id
      answer(arr)
    of "path": needBuf(); answer(%b.path)
    of "lang": needBuf(); answer(%(if b.lang != nil: b.lang.id else: ""))
    of "lineCount": needBuf(); answer(%b.lines.len)
    of "line":
      needBuf()
      let l = a{"line"}.getInt
      answer(%(if l >= 0 and l < b.lines.len: b.lines[l] else: ""))
    of "lines":
      needBuf()
      let f = clamp(a{"first"}.getInt, 0, b.lines.high)
      var l = a{"last"}.getInt(-1)
      if l < 0 or l > b.lines.high: l = b.lines.high
      var arr = newJArray()
      for i in f .. l: arr.add %b.lines[i]
      answer(arr)
    of "text": needBuf(); answer(%b.allText)
    of "textIn":
      needBuf()
      let (x, y) = rng(a{"range"})
      answer(%b.getText(x, y))
    of "dirty": needBuf(); answer(%b.dirty)
    of "indent": needBuf(); answer(%b.indent)
    of "lineComment": needBuf(); answer(%(if b.lang != nil: b.lang.lineComment else: ""))
    of "wordAt": needBuf(); answer(%b.wordAt(b.clampPos(posOf(a{"pos"}))))
    of "cursor": needBuf(); answer(jPos(b.primary.head))
    of "selection":
      needBuf()
      let (x, y) = plugVimRange(b, b.primary)
      answer(%*{"start": jPos(x), "stop": jPos(y)})
    of "selections":
      needBuf()
      var arr = newJArray()
      for c in b.cursors:
        let (x, y) = plugVimRange(b, c)
        arr.add %*{"start": jPos(x), "stop": jPos(y)}
      answer(arr)
    of "vimMode":
      answer(%(if not cfgVim: "" else:
                 (case vimMode
                  of vmNormal: "normal"
                  of vmInsert: "insert"
                  of vmVisual: "visual"
                  of vmVLine: "visual line"
                  of vmReplace: "replace")))
    of "setText":
      needBuf()
      if not b.canEdit(): (answer(nil, "the file cannot be changed"); return)
      plugMarkEdit(h, rid, b)
      b.setTextMinimal(a{"text"}.getStr)
      needRender = true
      answer(newJNull())
    of "replace":
      needBuf()
      if not b.canEdit(): (answer(nil, "the file cannot be changed"); return)
      plugMarkEdit(h, rid, b)
      let (x, y) = rng(a{"range"})
      b.beginEdit()
      discard b.replaceText(x, y, a{"text"}.getStr)
      b.endEdit()
      needRender = true
      answer(newJNull())
    of "setCursor":
      inc plugSelects
      needBuf()
      b.setSingle(b.clampPos(posOf(a{"pos"})))
      needRender = true
      answer(newJNull())
    of "select":
      inc plugSelects
      needBuf()
      let (x, y) = rng(a{"range"})
      b.setSingle(y, x)
      needRender = true
      answer(newJNull())
    of "save":
      needBuf()
      plugSilentSave = true
      let ok = b.saveBuffer()
      plugSilentSave = false
      answer(%ok)
    of "message":
      if a{"level"}.getStr == "warn": warn(a{"text"}.getStr) else: info(a{"text"}.getStr)
      answer(newJNull())
    of "toast":
      toast(a{"text"}.getStr, 3)
      answer(newJNull())
    of "log":
      plugLogAdd(plugin, a{"text"}.getStr)
      answer(newJNull())
    of "pick", "ask", "confirm":
      if plugSyncDepth > 0 or plugUi[0] != 0:
        # (ned waits for a plugin — a save, a format — or already asks you something: not now)
        plugLogAdd(plugin, fn & ": not while ned waits for the plugin (an event before saving, a formatter …)")
        answer((if fn == "pick": %(-1) elif fn == "ask": %"" else: %false))
        return
      plugUi = (id, fn)
      plugUiHost = h
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
              if plugUi[0] == id and plugUiHost == h:
                plugUi = (0, "")
                plugUiHost = nil
                plugAnswer(h, id, %idx))
          inc k
        plugUiTitle = a{"title"}.getStr
        openActions(plugUiTitle, items)
      of "ask":
        openPrompt(pPluginAsk, a{"prompt"}.getStr, a{"default"}.getStr)
      else:
        askConfirm(a{"text"}.getStr & " (y/n)", proc(c: char) =
          if plugUi[0] == id and plugUiHost == h:
            plugUi = (0, "")
            plugUiHost = nil
            plugAnswer(h, id, %(c in {'y', 'Y'})))
    of "runCommand":
      let n = a{"name"}.getStr
      answer(%(cmdByName(n) >= 0))
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
      answer(newJNull())
    of "sign":
      needBuf()
      let t = a{"text"}.getStr
      plugDecorSet(b, plugin, PlugDecor(kind: 0, line: a{"line"}.getInt, text: (if t.len > 0: t[0 ..< min(t.len, runeLen(t[0]))] else: "•"),
                                        color: a{"color"}.getStr))
      answer(newJNull())
    of "vtext":
      needBuf()
      plugDecorSet(b, plugin, PlugDecor(kind: 1, line: a{"line"}.getInt, text: a{"text"}.getStr, color: a{"color"}.getStr))
      answer(newJNull())
    of "highlight":
      needBuf()
      let (x, y) = rng(a{"range"})
      plugDecorSet(b, plugin, PlugDecor(kind: 2, line: x.line, col: x.col, eline: y.line, ecol: y.col,
                                        color: a{"color"}.getStr))
      answer(newJNull())
    of "clearDecorations":
      needBuf()
      let k = plugDecorKey(b)
      var keepD: seq[PlugDecor]
      for d in plugDecor.getOrDefault(k):
        if d.plugin != plugin: keepD.add d
      if keepD.len > 0: plugDecor[k] = keepD else: plugDecor.del k
      needRender = true
      answer(newJNull())
    of "status":
      var items: seq[(string, string)]
      for (p, t) in plugStatusItems:
        if p != plugin: items.add (p, t)
      if a{"text"}.getStr.len > 0: items.add (plugin, a{"text"}.getStr)
      plugStatusItems = items
      needRender = true
      answer(newJNull())
    of "progress":
      var items: seq[(string, string, int)]
      for x in plugProgress:
        if x[0] != plugin: items.add x
      if a{"text"}.getStr.len > 0: items.add (plugin, a{"text"}.getStr, clamp(a{"percent"}.getInt(-1), -1, 100))
      plugProgress = items
      needRender = true
      answer(newJNull())
    of "output":
      plugOutput(plugin, a{"text"}.getStr)
      answer(newJNull())
    of "showOutput":
      setPanel(pkOutput)
      answer(newJNull())
    of "terminal":
      let d = a{"dir"}.getStr
      plugTerminal(a{"cmd"}.getStr, (if d.len > 0 and not d.isAbsolute: rootDir / d else: d))
      answer(newJNull())
    of "refreshView":
      for v in plugViews.mitems:
        if v.plugin == plugin and v.title == a{"title"}.getStr: v.stale = true
      needRender = true
      answer(newJNull())
    of "setting": answer(plugSetting(plugin, a{"key"}.getStr))
    of "dataDir":
      let d = plugDataRoot() / plugin
      createDir(d)
      answer(%d)
    of "pluginDir":
      var d = ""
      for p in plugs:
        if p.id == plugin: d = p.dir
      answer(%d)
    of "stopTimer":
      let cb = a{"cb"}.getInt
      var keepT: seq[PlugTimer]
      for t in plugTimers:
        if not (t.cb == cb and t.plugin == plugin): keepT.add t
      plugTimers = keepT
      answer(newJNull())
    else: answer(nil, "ned has no " & fn)
  except CatchableError as e:
    plugAnswer(h, id, nil, e.msg)

proc plugCallDone(h: PlugHost, rid: int, v: JsonNode, err: string) =
  if rid notin h.calls: return
  let c = h.calls[rid]
  h.calls.del rid
  for (bid, mark) in c.marks:
    let b = bufById(bid)
    if b != nil: b.mergeUndo(mark)          # (all its edits: one undo step)
  if err.len > 0:
    plugLogAdd(c.plugin, "error: " & err)
    if plugSyncDepth == 0: warn("Plugin " & c.plugin & ": " & err)
  if c.onDone != nil:
    try: c.onDone(v, err)
    except CatchableError as e: internalError("plugin answer", e)

proc plugReady(h: PlugHost) =
  h.state = "ready"
  h.regs = h.newRegs
  h.newRegs.setLen(0)
  # (a plugin that needs a newer ned — said in a way its source did not show: its registrations left out)
  var tooNew: seq[string]
  for r in h.regs:
    if r.kind == "requires" and not plugNeedsOk(r.data{"spec"}.getStr, Version):
      tooNew.add r.plugin
      plugLogAdd(r.plugin, "left out: it needs ned " & r.data{"spec"}.getStr & " (this is " & Version & ")")
      let k = plugInfoOf(r.plugin)
      if k >= 0: plugs[k].err = "it needs ned " & r.data{"spec"}.getStr & " (this is " & Version & ")"
  if tooNew.len > 0:
    var keep: seq[PlugReg]
    for r in h.regs:
      if r.plugin notin tooNew: keep.add r
    h.regs = keep
  plugRebuildRegs()
  plugSaveManifest(h)
  plugLogAdd(plugLabel(h), "ready in " & $msSince(h.startedAt) & " ms" & (if h.native: " (compiled)" else: " (nim e)"))
  # the calls that waited for it
  let q = h.queue
  h.queue.setLen(0)
  for x in q:
    let i = regByKey(x.key)
    if i >= 0 and plugRegs[i].cb >= 0: discard plugSendCall(h, plugRegs[i].cb, plugRegs[i].plugin, x.args, x.onDone)
    elif x.onDone != nil: x.onDone(nil, "the plugin has no such callback now")

proc plugHandle(h: PlugHost, j: JsonNode) =
  case j{"t"}.getStr
  of "reg":
    var r = PlugReg(plugin: j{"plugin"}.getStr, kind: j{"kind"}.getStr, cb: j{"cb"}.getInt(-1), data: j)
    r.nth = regNth((if h.state == "ready": h.regs else: h.newRegs), r)
    if h.state == "ready":
      # (registered later — a timer started in a command): at once
      h.regs.add r
      if r.kind == "timer":
        plugRegs.add r
        plugTimers.add PlugTimer(plugin: r.plugin, cb: r.cb, ms: max(100, j{"ms"}.getInt(1000)), repeat: j{"repeat"}.getBool,
                                 due: getMonoTime() + initDuration(milliseconds = max(100, j{"ms"}.getInt(1000))))
      else: plugRebuildRegs()
    else: h.newRegs.add r
  of "ready": plugReady(h)
  of "api": plugApi(h, j)
  of "ret": plugCallDone(h, j{"rid"}.getInt, j{"value"}, j{"err"}.getStr)
  else: discard

proc plugLineOut(h: PlugHost, line: string) =
  if line.len > 0 and line[0] == PlugMark:
    var j: JsonNode
    try: j = parseJson(line[1 .. ^1])
    except CatchableError:
      plugLogAdd(plugLabel(h), line[1 .. ^1])
      return
    h.running = ""
    for _, c in h.calls: h.running = c.plugin
    plugHandle(h, j)
  elif line.strip.len > 0:
    var who = if h.ids.len == 1: h.ids[0] else: plugLabel(h)
    for _, c in h.calls: who = c.plugin
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
  plugOutlines.del b.id
  plugOutlineAsked.del b.id

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

# ── the language features plugins give: completions, hover, code actions, symbols ──

proc plugFixAction(title, src: string, edits: JsonNode, bid: int): (string, string, Action)
proc plugAddExample()

proc plugProvidersFor(what: string, b: Buffer): seq[string] =
  ## the registrations that give `what` for the buffer's language (its own, or "*")
  if plugProviders.len == 0 or b == nil or b.lang == nil: return
  let id = b.lang.id.toLowerAscii
  for (w, lang, key) in plugProviders:
    if w == what and (lang == id or lang == "*"):
      let h = plugKeyHost(key)
      if h != nil and h.state == "ready": result.add key

func plugCompKind(k: string): int =
  ## the Language Server Protocol's numbers (the list's icons)
  case k
  of "method": 2
  of "function", "proc", "func": 3
  of "constructor": 4
  of "field", "property": 5
  of "variable", "var", "let": 6
  of "class", "object": 7
  of "interface", "concept": 8
  of "module", "import": 9
  of "unit": 11
  of "value": 12
  of "enum": 13
  of "keyword": 14
  of "snippet": 15
  of "color": 16
  of "file": 17
  of "folder": 19
  of "enumMember": 20
  of "constant", "const": 21
  of "struct", "type": 22
  of "event": 23
  of "operator": 24
  else: 1

proc plugCompMerge() =
  ## the plugins' completions into the list being shown (when it is the one they were asked for, and not yet in it)
  if plugCompItems.len == 0: return
  let b = buf()
  if plugCompAt != (b.id, compLine, compStartCol): return
  for it in compItems:
    if it.plug: return
  # (a plain word of the file the plugin also gives: the plugin's item — its detail, its snippet — instead)
  var theirs: HashSet[string]
  for it in plugCompItems: theirs.incl it.label
  var keep: seq[CompItem]
  var have: HashSet[string]
  for it in compItems:
    if it.label in theirs and it.kind == 0 and it.detail.len == 0 and it.snippet.len == 0: continue
    keep.add it
    have.incl it.label
  for it in plugCompItems:
    if it.label notin have: keep.add it
  compItems = keep

proc plugHasCompletions(b: Buffer): bool = plugProvidersFor("completion", b).len > 0

proc plugComplete(b: Buffer, p: Pos) =
  ## ask the plugins for completions here (their answers join the list when they come)
  let keys = plugProvidersFor("completion", b)
  if keys.len == 0: return
  let ws = b.wordStart(p)
  plugCompAt = (b.id, p.line, ws)
  plugCompItems.setLen(0)
  inc plugCompRound
  let round = plugCompRound
  let at = plugCompAt
  let prefix = b.lines[p.line][ws ..< p.col]
  for key in keys:
    capture key:                  # (closures made in a loop share its variables: each its own)
      let k = key
      plugInvoke(k, %*{"buf": b.id, "pos": jPos(p), "prefix": prefix}, proc(v: JsonNode, err: string) =
        if round != plugCompRound or err.len > 0 or v == nil or v.kind != JArray: return
        let plugin = k.split('|')[0]
        for x in v:
          let label = x{"label"}.getStr
          if label.len == 0: continue
          let ins = x{"insert"}.getStr
          var it = CompItem(label: label, insert: (if ins.len > 0: ins else: label), filter: label, sortText: label,
                            detail: x{"detail"}.getStr, doc: x{"doc"}.getStr, docMade: true, plug: true,
                            kind: plugCompKind(x{"kind"}.getStr), rank: 1)
          if x{"snippet"}.getBool: it.snippet = it.insert
          if it.detail.len == 0: it.detail = plugin
          plugCompItems.add it
        let cb = buf()
        if cb.id != at[0] or compLine != at[1] or compStartCol != at[2]: return
        # (the list again with theirs: the one shown, or a new one when nothing else had any)
        var mine = false
        for it in compItems:
          if it.plug: mine = true
        if mine:
          var keep: seq[CompItem]
          for it in compItems:
            if not it.plug: keep.add it
          compItems = keep
        plugCompMerge()
        refilterComp())

proc plugHover(b: Buffer, p: Pos, auto: bool): bool =
  ## ask the plugins what to show at p (their text goes under ned's own, or alone): true when one was asked
  let keys = plugProvidersFor("hover", b)
  if keys.len == 0: return false
  plugHoverAt = (b.id, p)
  let at = plugHoverAt
  for key in keys:
    plugInvoke(key, %*{"buf": b.id, "pos": jPos(p)}, proc(v: JsonNode, err: string) =
      if err.len > 0 or v == nil or v.kind != JString or v.getStr.strip.len == 0: return
      let cb = buf()
      if plugHoverAt != at or cb.id != at[0] or cb.primary.head != at[1]: return
      if hoverOpen and hoverMd.len > 0: showHoverAuto(hoverMd & "\n\n---\n\n" & v.getStr, hoverIsAuto)
      else: showHoverAuto(v.getStr, auto))
  true

proc plugCodeActionItems(b: Buffer): seq[(string, string, Action)] =
  ## the plugins' code actions for the selection (or the cursor's line): asked, and waited for (1 s at most)
  let keys = plugProvidersFor("codeActions", b)
  if keys.len == 0: return
  let (a, e) = b.primary.range
  let r = if a == e: (Pos(line: a.line, col: 0), Pos(line: a.line, col: b.lines[a.line].len)) else: (a, e)
  for key in keys:
    let (ok, res, _) = plugCallSync(key, %*{"buf": b.id, "range": {"start": jPos(r[0]), "stop": jPos(r[1])}},
                                    min(plugTimeout(), 1000))
    if not ok or res == nil or res.kind != JArray: continue
    let plugin = key.split('|')[0]
    for f in res:
      var edits = newJArray()
      for x in jitems(f{"edits"}): edits.add x
      if f{"title"}.getStr.len > 0 and edits.len > 0:
        result.add plugFixAction(f{"title"}.getStr, "plugin " & plugin, edits, b.id)

proc plugSymbolItems(b: Buffer, v: JsonNode): seq[SideItem] =
  for s in jitems(v):
    let k = s{"kind"}.getStr
    let (icon, role) = case k
      of "function", "method", "proc", "func", "macro", "template": ("ƒ", 7)
      of "type", "class", "struct", "object", "enum", "interface", "concept": ("T", 8)
      of "heading", "section", "header": ("#", 1)
      of "constant", "const": ("c", 0)
      else: ("•", 0)
    result.add SideItem(text: s{"name"}.getStr, detail: s{"detail"}.getStr, path: b.path,
                        line: clamp(s{"line"}.getInt, 0, b.lines.high), col: max(0, s{"col"}.getInt),
                        depth: clamp(s{"depth"}.getInt, 0, 8), icon: icon, role: role)

proc plugOutline(b: Buffer): (bool, seq[SideItem]) =
  ## the plugins' symbols for the file (the outline): (a plugin gives them, the latest it gave) — asked again after
  ## each change, the old ones shown until the new come
  let keys = plugProvidersFor("symbols", b)
  if keys.len == 0: return (false, @[])
  if plugOutlineAsked.getOrDefault(b.id, -1) != b.changeId and msSince(lastInputAt) > 300:
    plugOutlineAsked[b.id] = b.changeId
    let bid = b.id
    let ch = b.changeId
    plugInvoke(keys[0], %*{"buf": b.id}, proc(v: JsonNode, err: string) =
      let tb = bufById(bid)
      if tb == nil or err.len > 0 or v == nil or v.kind != JArray: return
      plugOutlines[bid] = (ch, plugSymbolItems(tb, v))
      tb.outline = plugOutlines[bid][1]
      tb.outlineAt = tb.changeId
      needRender = true)
  (true, plugOutlines.getOrDefault(b.id, (-1, newSeq[SideItem]()))[1])

proc plugSymbolPicks(b: Buffer): seq[PickItem] =
  ## Go to symbol: the plugins' symbols (when a plugin gives them)
  let (has, items) = plugOutline(b)
  if not has: return
  for s in items:
    result.add PickItem(label: repeat("  ", s.depth) & s.text, detail: s.detail, icon: s.icon, path: b.path,
                        line: s.line, col: s.col)

# ── the assistant's tools from plugins ──

proc plugAiRun(name: string, args: JsonNode, done: proc(text: string, isError: bool) {.closure.}) =
  for t in plugAiTools:
    if t.name == name:
      plugInvoke(t.key, args, proc(v: JsonNode, err: string) =
        if err.len > 0: done(err, true)
        elif v == nil or v.kind == JNull: done("(done)", false)
        elif v.kind == JString: done(v.getStr, false)
        else: done($v, false))
      return
  done("unknown tool " & name & " (its plugin is not running)", true)

# ── vim ──

proc plugVimReset() =
  plugSeq = ""
  plugOpKeys = ""
  plugOpObj = '\0'
  plugOpWait = '\0'

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
      # (a text object of whole lines — from a line's start to a later one's: ip, ii — is linewise)
      if ok:
        if b.objLinewise(ch, a, e):
          let last = if e.col == 0: e.line - 1 else: e.line
          plugRunOp(key, b, Pos(line: a.line, col: 0), Pos(line: last, col: b.lines[last].len), true)
        else: plugRunOp(key, b, a, e, false)
      return true
    let n = max(1, plugOpCount)
    var motion = ""
    if plugOpWait != '\0':
      motion = $plugOpWait & $ch                      # gg, f{char}, t{char} …
      plugOpWait = '\0'
    else:
      if ch in {'1'..'9'} or (ch == '0' and plugOpCount > 1):
        plugOpCount = (if plugOpCount == 1 and ch != '0': 0 else: plugOpCount) * 10 + (ord(ch) - ord('0'))
        return true
      # a mapping that goes on from the operator's keys (exchange's cxc): it, not a motion
      let longerMap = op & $ch
      for (md, keys, rk, lg) in plugVimMaps:
        if md == "n" and keys == longerMap and lg.len == 0:
          plugOpKeys = ""
          plugInvoke(rk, %*{"count": n})
          return true
      if ch == op[^1]:
        plugOpKeys = ""
        let last = min(b.lines.high, p.line + n - 1)
        plugRunOp(key, b, Pos(line: p.line, col: 0), Pos(line: last, col: b.lines[last].len), true)
        return true
      if ch in {'i', 'a'}:
        plugOpObj = ch
        return true
      if ch in {'g', 'f', 't', 'F', 'T'}:
        plugOpWait = ch
        return true
      motion = $ch
    plugOpKeys = ""
    # (as after vim's own operators: $ and l take the last character too)
    let keepPending = vimPending
    vimPending = op
    let m = b.vimMotion(motion, n, p)
    vimPending = keepPending
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
  var longer, exactLang = false
  let blang = if b.lang != nil: b.lang.name.toLowerAscii else: ""
  for (md, keys, rk, lg) in plugVimMaps:
    if md != mode or (lg.len > 0 and lg != blang and (b.lang == nil or lg != b.lang.id)): continue
    if keys == sq:
      if lg.len > 0 or not exactLang: exact = rk      # (a mapping of the file's language wins over one of all)
      if lg.len > 0: exactLang = true
    elif keys.startsWith(sq): longer = true
  for (keys, rk) in plugOps:
    if keys == sq: opExact = rk
    elif keys.startsWith(sq): longer = true
  let count = if vimCount.len > 0: (try: parseInt(vimCount) except ValueError: 1) else: 1
  if exact.len > 0:
    plugSeq = ""
    vimCount = ""
    if visual:
      # (a visual-mode mapping: what it changed done, back to normal mode at the selection's start — unless it
      # made a selection of its own)
      let bid = b.id
      let selects = plugSelects
      plugInvoke(exact, %*{"count": count}, proc(v: JsonNode, err: string) =
        let x = bufById(bid)
        if x != nil and x == buf() and vimMode in {vmVisual, vmVLine} and plugSelects == selects:
          vimSetMode(vmNormal)
          x.setSingle(x.clampNormal(x.primary.range[0]))
          needRender = true)
    else: plugInvoke(exact, %*{"count": count})
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

proc plugPendingKeys(): (string, string) =
  ## the keys typed that wait for more (vim writes them: "g", "<leader>", "di"), and the mode: n (vim normal),
  ## v (visual), o (an operator waits for its motion), obj (… for its text object: "di"), emacs, helix — ("", "")
  ## when none waits
  if focus != fEditor or promptKind != pNone or pickKind != pickNone: return ("", "")
  if cfgKeymap == "helix": return ((if hxPending == "space": "<space>" else: hxPending), "helix")
  if cfgKeymap == "emacs": return (emacsPrefix, "emacs")
  if not cfgVim or vimMode notin {vmNormal, vmVisual, vmVLine}: return ("", "")
  let vis = vimMode in {vmVisual, vmVLine}
  if plugOpKeys.len > 0:
    if plugOpObj != '\0': return (vimKeysShow(plugOpKeys) & $plugOpObj, "obj")
    return (vimKeysShow(plugOpKeys), "o")
  if plugSeq.len > 0: return (vimKeysShow(plugSeq), (if vis: "v" else: "n"))
  if vimPending.len == 0: return ("", "")
  let p = vimPending
  let obj = (p.len == 2 and p[0] in {'d', 'c', 'y', '>', '<'} and p[1] in {'i', 'a'}) or
            (p.len == 3 and p[0 .. 1] in ["gu", "gU", "gc", "ys"] and p[2] in {'i', 'a'})
  let op = p in ["d", "c", "y", ">", "<", "gu", "gU", "gc", "ys"] or
           (p.len == 2 and p[0] in {'d', 'c', 'y', '>', '<'} and p[1] == 'g')
  (p, (if obj: "obj" elif op: "o" elif vis: "v" else: "n"))

proc plugKeyHintsShown(): bool =
  if plugKeyHints.len == 0: return false
  let (k, m) = plugPendingKeys()
  k.len > 0 and m & "\t" & k == plugKeyHintsFor

proc plugFeedKeys(keys: string) =
  ## keys as vim writes them ("d", "<C-a>", "<CR>", "<leader>f") — or emacs ("C-s", "M-x") — typed into the editor
  if keys.len == 0 or "…" in keys or (' ' in keys and keys != " "): return      # (a placeholder: "a … z")
  if keys.len == 3 and keys[1] == '-' and keys[0] in {'C', 'M'}:
    handleKey(Key(kind: kChar, ch: ord(keys[2]), mods: (if keys[0] == 'C': {mCtrl} else: {mAlt})))
    needRender = true
    return
  var i = 0
  while i < keys.len:
    var k = Key(kind: kChar, ch: ord(keys[i]))
    var n = 1
    if keys[i] == '<':
      let e = keys.find('>', i)
      if e > i:
        let name = keys[i + 1 ..< e]
        n = e - i + 1
        let ln = name.toLowerAscii
        if ln in ["leader", "space"]: k = Key(kind: kChar, ch: ord(' '))
        elif ln in ["cr", "enter"]: k = Key(kind: kEnter)
        elif ln == "tab": k = Key(kind: kTab)
        elif ln in ["esc", "escape"]: k = Key(kind: kEsc)
        elif ln.len == 3 and ln.startsWith("c-"): k = Key(kind: kChar, ch: ord(ln[2]), mods: {mCtrl})
        elif ln.len == 3 and ln.startsWith("m-"): k = Key(kind: kChar, ch: ord(ln[2]), mods: {mAlt})
        else: n = 1
    handleKey(k)
    i += n
  needRender = true

proc drawKeyHints(bottom: int) =
  ## which-key's box, above the status bar: each key that may follow and what it does (a tap types it)
  if not plugKeyHintsShown(): return
  var colW = 8
  for (k, d) in plugKeyHints: colW = max(colW, strWidth(k) + 2 + min(28, strWidth(d)) + 3)
  let w = max(20, scrW - 2)
  let cols = max(1, (w - 2) div colW)
  let rowsAll = (plugKeyHints.len + cols - 1) div cols
  let rows = min(rowsAll, max(1, min(12, bottom - 4)))
  let h = rows + 2
  let y = bottom - h
  if y < 1: return
  let x = 1
  drawFrame(x, y, w, h, theme.menuBg, theme.border, plugKeyHintsTitle)
  let cw = (w - 2) div cols
  for i, (key, what) in plugKeyHints:
    let (r, c) = (i mod rows, i div rows)
    if c >= cols: break
    let cx = x + 1 + c * cw
    let cy = y + 1 + r
    let kx = putStr(cx + 1, cy, key, theme.accent, theme.menuBg, {aBold}, cx + cw)
    discard putStr(kx, cy, " → ", theme.dim, theme.menuBg, {}, cx + cw)
    discard putStr(kx + 3, cy, what, theme.fg, theme.menuBg, {}, cx + cw - 1)
    let kk = key
    capture kk:
      region(cx, cy, cw, 1, proc() = plugFeedKeys(kk))
  if rowsAll > rows:
    discard putStr(x + w - 12, y + h - 1, " … more ", theme.dim, theme.menuBg, {})

proc plugKeysRound() =
  ## the "keys" events: keys that waited for more for the pause each asked for (once for each), and the box closed
  ## when they no longer wait
  var any = false
  for (ev, _, _) in plugEvts:
    if ev == "keys": any = true
  if not any and plugKeyHints.len == 0: return
  let (keys, mode) = plugPendingKeys()
  let cur = mode & "\t" & keys
  if cur != plugKeysSeen:
    plugKeysSeen = cur
    plugKeysSince = getMonoTime()
    plugKeysFired.setLen(0)
    if plugKeyHints.len > 0 and cur != plugKeyHintsFor:
      plugKeyHints.setLen(0)
      needRender = true
  if keys.len == 0: return
  for (ev, pat, key) in plugEvts:
    if ev == "keys" and key notin plugKeysFired and msSince(plugKeysSince) >= (try: parseInt(pat) except ValueError: 400):
      plugKeysFired.add key
      plugInvoke(key, %*{"keys": keys, "mode": mode})

proc plugKeysDueMs(): int =
  result = int.high
  if plugKeysSeen.len == 0 or plugKeysSeen.endsWith("\t"): return
  for (ev, pat, key) in plugEvts:
    if ev == "keys" and key notin plugKeysFired:
      let ms = (try: parseInt(pat) except ValueError: 400)
      result = min(result, max(0, ms - msSince(plugKeysSince)))

proc plugHasLangKeys(): bool = plugLangKeys.len > 0

proc plugLangKey(n: string): bool =
  ## a key a plugin gave the file's language (the folder view's Alt+Enter): true when it was one
  if plugLangKeys.len == 0 or focus != fEditor: return false
  let b = buf()
  if b == nil or b.lang == nil: return false
  for lg in [b.lang.name.toLowerAscii, b.lang.id]:
    let k = lg & "\t" & n
    if k in plugLangKeys:
      plugInvoke(plugLangKeys[k], %*{"buf": b.id})
      return true
  false

proc plugWrites(b: Buffer): bool =
  ## saving a tab that is not a file, of a language a plugin writes (the folder view): the plugin does it
  if plugWriters.len == 0 or b == nil or b.path.len > 0 or b.lang == nil: return false
  var key = plugWriters.getOrDefault(b.lang.name.toLowerAscii)
  if key.len == 0: key = plugWriters.getOrDefault(b.lang.id)
  if key.len == 0: return false
  plugInvoke(key, plugEventArgs(b))
  true

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
  ## the fixes of plugins' problems on these lines, then the plugins' code actions (Alt+Enter)
  for d in diagsExt.getOrDefault(if b.path.len > 0: b.path else: plugDecorKey(b)):
    if not d.src.startsWith("plugin ") or d.fixes == nil: continue
    if d.line > l1 or max(d.line, d.eline) < l0: continue
    for f in jitems(d.fixes): result.add plugFixAction(f{"title"}.getStr, d.src, f{"nedEdits"}, b.id)
  result.add plugCodeActionItems(b)

# ── each round of the main loop ──

proc plugFds(fds: var seq[TPollfd]) =
  for h in plugHosts:
    if h.fdOut >= 0: fds.add TPollfd(fd: h.fdOut, events: POLLIN)
    if h.fdErr >= 0: fds.add TPollfd(fd: h.fdErr, events: POLLIN)
    if h.fdIn >= 0 and h.wbuf.len > 0: fds.add TPollfd(fd: h.fdIn, events: POLLOUT)

proc plugSettled(): bool =
  ## every process's registrations known (none starting or being built)
  for h in plugHosts:
    if h.state in ["starting", "building"] and h.regs.len == 0: return false
  true

proc plugNextDueMs(): int =
  ## how soon the plugins need the loop again (a timer, the start, a change to tell them)
  result = int.high
  if not plugBooted: return 300
  for t in plugTimers: result = min(result, max(0, int((t.due - getMonoTime()).inMilliseconds)))
  if plugOpenQ.len > 0 and plugSettled(): result = 0
  result = min(result, plugKeysDueMs())
  for (ev, _, _) in plugEvts:
    if ev == "change":
      result = min(result, 200)
      break
  if plugProviders.len > 0:
    # (the file's symbols after a pause in the typing)
    let b = buf()
    if b != nil and plugOutlineAsked.getOrDefault(b.id, -1) != b.changeId and plugProvidersFor("symbols", b).len > 0:
      result = min(result, 400)

proc plugBoot() =
  ## the registrations of last time, at once; a process when it must run, or when they are not known
  plugBooted = true
  plugDiscover()
  plugMakeHosts()
  for h in plugHosts:
    h.sig = plugSignature(h)
    if plugLoadManifest(h):
      if plugEagerHost(h): plugStart(h)
    else: plugStart(h)
  plugRebuildRegs()

proc plugHostPump(h: PlugHost, ready: HashSet[cint]) =
  if h.fdOut >= 0 and h.fdOut in ready: plugReadOut(h)
  if h.fdErr >= 0 and h.fdErr in ready: plugReadErr(h)
  if h.wbuf.len > 0: plugFlush(h)
  if h.pr.pid > 0 and h.state in ["starting", "ready"] and h.pr.reap():
    plugReadErr(h)
    plugHostDied(h)
  if h.state != "ready": return
  if not h.startupFired:
    h.startupFired = true
    plugFire("startup", buf(), h)
  # calls that never came back
  var late: seq[int]
  for rid, c in h.calls:
    if msSince(c.sentAt) > 60_000: late.add rid
  for rid in late:
    plugLogAdd(h.calls[rid].plugin, "a call took over a minute — given up (the plugin may be stuck: Reload)")
    plugCallDone(h, rid, nil, "no answer in a minute")
  # idle: stopped (it starts again when a plugin is needed)
  let idleMin = sval("plugins.idleStopMinutes").getInt(10)
  if idleMin > 0 and h.calls.len == 0 and plugUiHost != h and not plugEagerHost(h) and msSince(h.lastUse) > idleMin * 60_000:
    for (p, _) in plugStatusItems:
      if p in h.ids: return
    plugStop(h, "stopped (idle — it starts again when needed)")
    plugLogAdd(plugLabel(h), "stopped after " & $idleMin & " idle minutes")

proc plugPump(ready: HashSet[cint]) =
  if not plugBooted:
    if plugBootAt == MonoTime(): plugBootAt = getMonoTime()
    if msSince(plugBootAt) < 400 or not plugsOn(): return
    plugBoot()
  let hosts = plugHosts                        # (a process that ends can change the list: a copy)
  for h in hosts: plugHostPump(h, ready)
  if plugOpenQ.len > 0 and plugSettled():
    let q = plugOpenQ
    plugOpenQ.setLen(0)
    for id in q: plugFire("open", bufById(id))
  # timers
  var i = 0
  while i < plugTimers.len:
    if getMonoTime() >= plugTimers[i].due:
      let t = plugTimers[i]
      let h = plugHostOf(t.plugin)
      if h != nil and h.state == "ready": discard plugSendCall(h, t.cb, t.plugin, newJObject(), nil)
      if t.repeat:
        plugTimers[i].due = getMonoTime() + initDuration(milliseconds = t.ms)
        inc i
      else: plugTimers.delete(i)
    else: inc i
  plugKeysRound()
  # another tab in front ("enter" events)
  if plugEvts.len > 0:
    let cb = buf()
    if cb != nil and cb.id != plugCurSeen:
      plugCurSeen = cb.id
      plugFire("enter", cb)
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
  # the outline of the file shown, from a plugin that gives symbols (after a pause in the typing)
  if plugProviders.len > 0 and msSince(lastInputAt) > 300:
    let b = buf()
    if b != nil and plugOutlineAsked.getOrDefault(b.id, -1) != b.changeId: discard plugOutline(b)
  # an answer you never gave (the list or the prompt closed some other way): cancelled
  if plugUi[0] != 0 and plugUiHost != nil:
    let gone = case plugUi[1]
      of "pick": pickKind != pickAction or pickTitle != plugUiTitle
      of "ask": promptKind != pPluginAsk
      else: dialogs.len == 0
    if gone:
      let (id, kind) = plugUi
      let h = plugUiHost
      plugUi = (0, "")
      plugUiHost = nil
      plugAnswer(h, id, (if kind == "pick": %(-1) elif kind == "ask": %"" else: %false))

proc plugAskDone(text: string) =
  ## the prompt a plugin's ask() opened: Enter
  if plugUi[1] == "ask" and plugUiHost != nil:
    let id = plugUi[0]
    let h = plugUiHost
    plugUi = (0, "")
    plugUiHost = nil
    plugAnswer(h, id, %text)

proc plugForget(ids: seq[string]) =
  ## what these plugins put in the editor: status items, progress, decorations, problems
  var st: seq[(string, string)]
  for x in plugStatusItems:
    if x[0] notin ids: st.add x
  plugStatusItems = st
  var pg: seq[(string, string, int)]
  for x in plugProgress:
    if x[0] notin ids: pg.add x
  plugProgress = pg
  var dk: seq[string]
  for k in plugDecor.keys: dk.add k
  for k in dk:
    var keepD: seq[PlugDecor]
    for d in plugDecor[k]:
      if d.plugin notin ids: keepD.add d
    if keepD.len > 0: plugDecor[k] = keepD else: plugDecor.del k
  var keepX: Table[string, seq[Diag]]
  for p, ds in diagsExt:
    var k: seq[Diag]
    for d in ds:
      if not (d.src.startsWith("plugin ") and d.src[7 .. ^1] in ids): k.add d
    if k.len > 0: keepX[p] = k
  diagsExt = keepX
  rebuildProblems()

proc plugReload() =
  ## the plugins again (after an edit, a new one, one turned on or off)
  plugStopAll()
  var all: seq[string]
  for p in plugs: all.add p.id
  for h in plugHosts:
    for id in h.ids: all.add id
  plugFailedOnce.clear()
  plugForget(all)
  plugHosts.setLen(0)
  plugBooted = true
  plugDiscover()
  plugMakeHosts()
  for h in plugHosts:
    h.regs.setLen(0)
    plugStart(h)
  plugRebuildRegs()
  if plugHosts.len == 0: info("No plugins (Plugins dock › New plugin…)")
  else:
    var failed: seq[string]
    for h in plugHosts:
      if h.state.startsWith("failed"): failed.add (if h.name == PlugShared: "" else: h.name & ": ") & h.state[8 .. ^1]
    if failed.len > 0: warn("Plugins: " & failed.join(" · "))
    else: info("Plugins: starting…")

proc plugReloadPlugin(id: string) =
  ## the process of one plugin again (its own; the shared one for a NimScript plugin) — the others keep running
  let h = plugHostOf(id)
  if h == nil:
    plugReload()
    return
  plugStop(h, "off")
  plugFailedOnce.excl id
  for x in h.ids: plugFailedOnce.excl x
  plugForget(h.ids)
  h.regs.setLen(0)
  let before = plugHosts
  plugDiscover()
  plugMakeHosts()
  for x in plugHosts:
    # (its process, or one its plugins now make — the others as they were: running, or waiting to be needed)
    if (x == h or x notin before) and x.state == "off": plugStart(x)
  plugRebuildRegs()
  info("Reloading " & (if h.name == PlugShared: "the NimScript plugins" else: id) & "…")

proc plugFileSaved(path: string) =
  ## a plugin's own file saved: its process reloads (a new plugin: all of them)
  if not (path.endsWith(".nims") or path.endsWith(".nim")): return
  for root in [plugUserRoot(), plugProjectRoot()]:
    if root.len > 0 and path.startsWith(root & "/"):
      let owner = plugOwnerOf(path)
      if owner.len > 0 and plugHostOf(owner) != nil: plugReloadPlugin(owner)
      else:
        plugFailedOnce.clear()
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

proc plugSetAlone(id: string, on: bool) =
  var al: seq[string]
  for x in plugAloneIds():
    if x != id: al.add x
  if on: al.add id
  setSetting("plugins.alone", %al)
  plugReload()

proc plugSetBundled(n: string, on: bool) =
  ## one of ned's own plugins on (it runs from now on, and after ned starts again) or removed (plugins.bundled)
  var xs: seq[string]
  for x in plugBundledOn():
    if x != n: xs.add x
  if on: xs.add n
  var changes = @[("plugins.bundled", %xs)]
  if on:                                   # (turned on again after it was turned off)
    var off: seq[string]
    for x in plugDisabledIds():
      if x != n: off.add x
    changes.add ("plugins.disabled", %off)
  setSettings(changes)
  plugReload()
  if on: info(n & " is on — " & plugBundledWhat(n) & " (Plugins dock: what it added)")
  else: info(n & " is removed — Plugins dock › AVAILABLE turns it on again")

proc plugBundledAct(n: string, on: bool): Action =
  ## (an action of its own for each of them: closures made in a loop would share the loop's variables)
  result = proc() = plugSetBundled(n, on)

proc plugOpenSource(file: string, bundled: bool) =
  ## a plugin's source in a tab — ned's own read-only (its copy is written again when ned changes: Copy to my
  ## plugins makes one to change)
  let b = openFile(file)
  if b != nil and bundled:
    b.readOnly = true
    info("ned's own plugin, read-only here — its menu › Copy to my plugins gives you one to change")

proc plugCopyBundled(n: string) =
  ## one of ned's own plugins copied into yours (yours to change: it is the one that runs from then on)
  var src = ""
  for (name, _, s) in PlugBundled:
    if name == n: src = s
  if src.len == 0: return
  let d = plugUserRoot() / n
  if dirExists(d):
    discard openFile(d / "plugin.nims")
    info("You have a plugin called " & n & " — here it is")
    return
  try:
    createDir(d)
    writeFile(d / "plugin.nims", src)
  except CatchableError as e:
    error("Could not write " & d & ": " & e.msg)
    return
  var xs: seq[string]
  for x in plugBundledOn():
    if x != n: xs.add x
  setSetting("plugins.bundled", %xs)
  discard openFile(d / "plugin.nims")
  plugReload()
  info(n & " is yours now, in " & tildePath(d) & " — change it and save: it reloads")

proc plugUninstall(id: string) =
  ## a plugin removed: ned's own one turned off for good (plugins.bundled); yours or a project's, its folder deleted
  ## after you say yes (the files it keeps — dataDir() — stay)
  plugDiscover()
  let i = plugInfoOf(id)
  if i < 0:
    info("No plugin called " & id)
    return
  let p = plugs[i]
  if p.bundled:
    plugSetBundled(id, false)
    return
  let pid = id
  let dir = p.dir
  askConfirm("Remove the plugin " & id & "? Its folder " & tildePath(dir) & " is deleted (y/n)", proc(c: char) =
    if c notin {'y', 'Y'}: return
    try: removeDir(dir)
    except CatchableError as e:
      error("Could not remove " & tildePath(dir) & ": " & e.msg)
      return
    var off, al: seq[string]
    for x in plugDisabledIds():
      if x != pid: off.add x
    for x in plugAloneIds():
      if x != pid: al.add x
    setSettings(@[("plugins.disabled", %off), ("plugins.alone", %al)])
    plugReload()
    info("Removed " & pid))

proc plugUninstallAct(id: string): Action =
  result = proc() = plugUninstall(id)

proc plugSettingsOf(id: string) =
  ## the plugin's own settings (plugins.<id>.…) in the Settings window — or what it does without any
  var has = false
  for r in plugRegs:
    if r.plugin == id and r.kind == "setting": has = true
  if not has:
    info(id & " has no settings of its own")
    return
  openSettingsUi("plugins." & id & ".")

proc cmdPluginsAvailable() =
  ## ned's own plugins: each with what it does — Enter turns it on (or, on already, removes it)
  plugDiscover()
  let on = plugBundledOn()
  var items: seq[(string, string, Action)]
  for (n, what, _) in PlugBundled:
    let isOn = n in on
    items.add act((if isOn: "● " else: "○ ") & n, (if isOn: "on — Enter removes it · " else: "") & what,
                  plugBundledAct(n, not isOn))
  openActions("ned's plugins — Enter turns one on (or removes it)", items)

proc cmdPluginUninstall() =
  plugDiscover()
  var items: seq[(string, string, Action)]
  for p in plugs:
    let det = if p.bundled: "ned's own — turned off, it stays in AVAILABLE"
              elif p.project: "the project's — its folder " & tildePath(p.dir) & " is deleted"
              else: "yours — its folder " & tildePath(p.dir) & " is deleted"
    items.add act(p.id, det, plugUninstallAct(p.id))
  if items.len == 0:
    info("No plugins installed — Plugins › Available plugins…")
    return
  openActions("Remove a plugin", items)

proc plugNew(name0: string) =
  let full = plugNewFull
  plugNewFull = false
  let name = name0.strip.replace(" ", "-")
  if not plugIdOk(name):
    warn("A plugin's name: letters, digits, - and _")
    return
  let d = plugUserRoot() / name
  let file = d / (if full: "plugin.nim" else: "plugin.nims")
  if dirExists(d):
    discard openFile((if fileExists(d / "plugin.nims"): d / "plugin.nims" else: d / "plugin.nim"))
    info("That plugin exists — here it is")
    return
  try:
    createDir(d)
    writeFile(file, (if full: PlugTemplateFull else: PlugTemplate) % [name])
  except CatchableError as e:
    error("Could not make " & d & ": " & e.msg)
    return
  discard openFile(file)
  plugReload()
  info("New plugin " & name & (if full: " (full Nim: it is compiled now, in the background)" else: "") &
       " — edit it and save: it reloads (Plugins dock: its log)")

proc plugInstall(url0: string, name0 = "") =
  ## a plugin from a git repository (its plugin.nims or plugin.nim at the top), into your plugins (named after the
  ## repository, or name0: the plugin list's name)
  let url = url0.strip
  if not gitArgSafe(url) or not (url.startsWith("https://") or url.startsWith("git@") or url.startsWith("ssh://") or
                                  url.startsWith("http://") or url.startsWith("file://") or url.startsWith("/")):
    warn("Not a repository address: " & url)
    return
  var name = url.strip(chars = {'/'}).split('/')[^1]
  if name.endsWith(".git"): name = name[0 ..< name.len - 4]
  for pre in ["ned-plugin-", "ned-", "nedplugin-"]:
    if name.startsWith(pre) and name.len > pre.len: name = name[pre.len .. ^1]
  if name0.len > 0: name = name0
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
      if not fileExists(d / "plugin.nims") and not fileExists(d / "plugin.nim"):
        warn(name & " has no plugin.nims (or plugin.nim) at its top — not a ned plugin? (it is in " & tildePath(d) & ")")
        return
      let needs = plugNeedsOf(d / (if fileExists(d / "plugin.nims"): "plugin.nims" else: "plugin.nim"))
      plugReload()
      if needs.len > 0 and not plugNeedsOk(needs, Version):
        warn("Installed " & name & ", but it needs ned " & needs & " (this is " & Version & ") — it stays off")
      else:
        toast("Installed the plugin " & name & " — read its code: it runs with your rights (Plugins dock)", 3))

proc plugUpdate() =
  ## your plugins that came from git: pulled (fast-forward only), then reloaded
  var parts: seq[string]
  var n = 0
  if dirExists(plugUserRoot()):
    for kind, d in walkDir(plugUserRoot()):
      if kind in {pcDir, pcLinkToDir} and dirExists(d / ".git"):
        inc n
        parts.add "echo " & quoteShell("== " & extractFilename(d)) & "; git -C " & quoteShell(d) &
                  " pull --ff-only 2>&1"
  if n == 0:
    info("None of your plugins came from git (Plugins: install from git…)")
    return
  info("Updating " & $n & " plugin" & (if n == 1: "" else: "s") & "…")
  discard startJob(jkTool, parts.join("; "), plugUserRoot(), proc(j: Job) =
    var cur = ""
    var updated, same, failed: seq[string]
    var curOut: seq[string]
    proc close() =
      if cur.len == 0: return
      let o = curOut.join("\n")
      if "Already up to date" in o or "Already up-to-date" in o: same.add cur
      elif "fatal:" in o or "error:" in o or "Not possible to fast-forward" in o or "diverging" in o:
        failed.add cur
        plugLogAdd(cur, "update: " & o.strip.splitLines()[^1])
      else: updated.add cur
    for l in j.output.splitLines:
      if l.startsWith("== "):
        close()
        cur = l[3 .. ^1]
        curOut.setLen(0)
      else: curOut.add l
    close()
    if updated.len > 0: plugReload()
    var msg = if updated.len > 0: "Updated: " & updated.join(", ") else: "Your plugins are up to date"
    if failed.len > 0: msg.add " · not updated (local changes?): " & failed.join(", ")
    if failed.len > 0: warn(msg) else: info(msg))

proc plugBrowseShow(j: JsonNode) =
  let arr = if j.kind == JArray: j elif j{"plugins"} != nil and j["plugins"].kind == JArray: j["plugins"] else: newJArray()
  var items: seq[(string, string, Action)]
  for x in arr:
    let name = x{"name"}.getStr
    let url = x{"url"}.getStr
    if name.len == 0 or url.len == 0: continue
    let have = dirExists(plugUserRoot() / name)
    let det = (if have: "installed · " else: "") & x{"description"}.getStr
    capture url, name, have:
      items.add act(name, det, proc() =
        if have:
          let d = plugUserRoot() / name
          discard openFile((if fileExists(d / "plugin.nims"): d / "plugin.nims" else: d / "plugin.nim"))
        else: plugInstall(url, name))
  if items.len == 0:
    warn("The plugin list has no plugins (each: {\"name\", \"url\", \"description\"})")
    return
  openActions("Plugins — pick one to install", items)

proc plugBrowse() =
  ## the plugin list (plugins.indexUrl: a JSON list of {name, url, description} — on the web, or a file)
  let src = sval("plugins.indexUrl").getStr.strip
  if src.len == 0:
    info("Set plugins.indexUrl to a plugin list (JSON: [{\"name\", \"url\", \"description\"}]) — the examples meanwhile")
    plugAddExample()
    return
  if not (src.startsWith("https://") or src.startsWith("http://")):
    try: plugBrowseShow(parseFile(expandTilde(src)))
    except CatchableError as e: warn("The plugin list (" & src & "): " & e.msg)
    return
  if not haveExe("curl"):
    error("curl is needed to read the plugin list")
    return
  info("Reading the plugin list…")
  discard startJob(jkTool, "curl -fsSL --max-time 30 -- " & quoteShell(src), plugUserRoot().parentDir, proc(j: Job) =
    if j.code != 0:
      warn("Could not read the plugin list: " & j.output.strip.splitLines.join(" ")[0 ..< min(160, j.output.strip.len)])
      return
    try: plugBrowseShow(parseJson(j.output))
    except CatchableError as e: warn("The plugin list is not JSON: " & e.msg))

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
        let main = if fs[0][0] == "plugin.nim": "plugin.nim" else: "plugin.nims"
        if dirExists(d):
          discard openFile(d / main)
          info("You have " & n & " — here it is")
          return
        try:
          createDir(d)
          for (f, text) in fs: writeFile(d / f, text)
        except CatchableError as e:
          error("Could not write " & d & ": " & e.msg)
          return
        discard openFile(d / main)
        plugReload()
        info("The example " & n & " is in " & tildePath(d) & " — it runs now (Plugins dock)"))
  openActions("Add an example plugin", items)

proc plugHelp() =
  ## the library's documentation (its source) in a tab, read-only (it is ned's copy: written again when it changes)
  let b = openFile(plugLibDir() / "nedplugin.nim")
  if b != nil: b.readOnly = true

proc plugInvokeAction(key: string): Action =
  proc() = plugInvoke(key, newJObject())

proc plugViewClick(v: PlugView, it: JsonNode): Action =
  let ck = v.clickKey
  let id = it{"id"}.getStr
  let path = it{"path"}.getStr
  let line = it{"line"}.getInt(-1)
  proc() =
    if ck.len > 0 and (id.len > 0 or path.len == 0): plugInvoke(ck, %*{"id": id})
    elif path.len > 0: discard openFile((if path.isAbsolute: path else: rootDir / path), line)

proc plugMenuAction(pid, file: string, on, alone, full, bundled: bool): Action =
  ## a plugin's own menu in the Plugins dock: see it, turn it off or on, its settings, remove it
  proc() =
    var items = @[mi((if bundled: "View its source" else: "Open " & extractFilename(file)), "",
                     proc() = plugOpenSource(file, bundled)),
                  mi((if on: "Turn off" else: "Turn on"), "", proc() = plugSetEnabled(pid, not on)),
                  mi("Its settings…", "", proc() = plugSettingsOf(pid)),
                  mi("Reload it", "", proc() = plugReloadPlugin(pid))]
    if not full:
      items.add mi((if alone: "Run it with the others" else: "Run it in a process of its own"), "",
                   proc() = plugSetAlone(pid, not alone))
    if bundled: items.add mi("Copy to my plugins (to change it)", "", proc() = plugCopyBundled(pid))
    items.add msep()
    items.add mi((if bundled: "Remove (it stays in AVAILABLE)" else: "Uninstall… (its folder is deleted)"), "",
                 proc() = plugUninstall(pid))
    items.add mi("Reload all the plugins", "", proc() = plugReload())
    openMenu(items, mouseX, mouseY + 1)

proc plugAvailableAction(n: string): Action =
  ## an AVAILABLE plugin's menu: turn it on, see its source first, or copy it into yours
  proc() =
    let src = plugBundledRoot() / n / "plugin.nims"
    openMenu(@[mi("Turn on", "", proc() = plugSetBundled(n, true)),
               mi("View its source", "", proc() = plugOpenSource(src, true)),
               mi("Copy to my plugins (to change it)", "", proc() = plugCopyBundled(n))], mouseX, mouseY + 1)

proc plugHostMenu(name: string): Action =
  proc() =
    var h: PlugHost = nil
    for x in plugHosts:
      if x.name == name: h = x
    if h == nil: return
    let hh = h
    openMenu(@[mi("Restart it", "", proc() = plugReloadPlugin(hh.ids[0])),
               mi("Stop it (it starts again when needed)", "", proc() =
                 plugStop(hh, "stopped")
                 plugLogAdd(plugLabel(hh), "stopped"))], mouseX, mouseY + 1)

proc buildPluginItems(): seq[SideItem] =
  result.add sideItem("PLUGINS", 6)
  if not plugsOn():
    result.add sideItem("off (plugins.enabled)", 2, "·", "turn on", proc() =
      setSetting("plugins.enabled", %true)
      plugReload())
    return
  if not plugBooted: plugDiscover()
  if plugHosts.len == 0:
    result.add sideItem("○ " & (if plugs.len == 0: "off" else: "no plugin is on"), 2, "◆")
  for h in plugHosts:
    let n = h.ids.len
    let what = if h.name == PlugShared: ""
               else: h.name & (if h.full: " (Nim)" else: "") & " · "
    let line = case h.state
      of "ready": ic("ok") & " " & what & "running · " & (if h.native: "native" else: "nim e") &
                  (if h.name == PlugShared: " · " & $n & " plugin" & (if n == 1: "" else: "s") else: "")
      of "starting": "○ " & what & "starting… " & $msSince(h.startedAt) & " ms"
      of "building": "○ " & what & "compiling… " & $(msSince(h.startedAt) div 1000) & " s"
      else: "○ " & what & h.state
    result.add sideItem(line, (if h.state.startsWith("failed"): 3 elif h.state == "ready": 5 else: 2), "◆", "",
                        plugHostMenu(h.name))
  for (p, t, pct) in plugProgress:
    result.add sideItem(t & (if pct >= 0: " " & $pct & "%" else: "…"), 4, "⟳", p, depth = 1)
  # the plugins' views
  for vi in 0 ..< plugViews.len:
    let v = plugViews[vi]
    if v.stale and not v.pending and msSince(v.askedAt) > 500:
      let h = plugHostOf(v.plugin)
      if h != nil and h.state == "ready":
        plugViews[vi].pending = true
        plugViews[vi].stale = false
        plugViews[vi].askedAt = getMonoTime()
        capture v:                  # (closures made in a loop share its variables: each its own)
          let key = v.key
          plugInvoke(key, newJObject(), proc(r: JsonNode, err: string) =
            for x in plugViews.mitems:
              if x.key == key:
                x.pending = false
                if err.len == 0 and r != nil and r.kind == JArray: x.items = r
                elif err.len > 0: x.items = %*[{"text": "error: " & err, "color": "error"}]
            needRender = true)
    result.add sideItem(v.title.toUpperAscii, 6, "", v.plugin)
    if v.items == nil:
      result.add sideItem("…", 2, "", "", depth = 1)
      continue
    for it in v.items:
      let role = case it{"color"}.getStr
        of "error", "err": 3
        of "warn", "warning": 4
        of "add", "ok", "green": 5
        of "accent": 7
        of "hint", "dim": 2
        else: 1
      result.add sideItem(it{"text"}.getStr, role, it{"icon"}.getStr, it{"detail"}.getStr, plugViewClick(v, it),
                          depth = 1 + clamp(it{"depth"}.getInt, 0, 6))
  result.add sideItem("INSTALLED", 6)
  if plugs.len == 0:
    result.add sideItem("None yet — turn one on in AVAILABLE below", 2, "·")
    result.add sideItem("New plugin…", 7, "+", "from a template", proc() = runCmd("Plugins: new plugin…"))
    result.add sideItem("Add an example…", 7, "+", "notes, zig-lite, ini-tools, commentary …", proc() =
      plugAddExample())
    result.add sideItem("Install from git…", 7, "⇣", "a repository with a plugin.nims", proc() =
      openPrompt(pPluginInstall, "Plugin repository (https://…)", ""))
  var untrusted = 0
  for p in plugs:
    let pid = p.id
    let on = p.enabled
    let role = if on: (if p.err.len > 0: 3 else: 1) else: 2
    let det = if p.err.len > 0 and p.err != "off": p.err elif not on: "off" elif p.project: "project"
              elif p.bundled: "ned's" elif p.full: "Nim, compiled" elif p.alone: "own process" else: ""
    if p.project and p.err == "the folder is not trusted": inc untrusted
    result.add sideItem(pid, role, (if on: "●" else: "○"), det,
                        plugMenuAction(pid, p.file, on, p.alone, p.full, p.bundled), path = p.file)
    if on:
      for r in plugRegs:
        if r.plugin != pid: continue
        let what = case r.kind
          of "command": "› " & r.data{"title"}.getStr & (if r.data{"keys"}.getStr.len > 0: "  " & r.data{"keys"}.getStr else: "")
          of "event": "on " & r.data{"event"}.getStr & " " & r.data{"pattern"}.getStr
          of "language": "language " & r.data{"id"}.getStr
          of "formatter": "formats " & r.data{"lang"}.getStr
          of "lsp": "language server for " & r.data{"lang"}.getStr
          of "completion": "completions for " & r.data{"lang"}.getStr
          of "hover": "hover for " & r.data{"lang"}.getStr
          of "codeActions": "code actions for " & r.data{"lang"}.getStr
          of "symbols": "symbols (outline) for " & r.data{"lang"}.getStr
          of "snippet": "snippet " & r.data{"trigger"}.getStr & " (" & r.data{"lang"}.getStr & ")"
          of "aiTool": "assistant's tool " & r.data{"name"}.getStr & (if r.data{"readOnly"}.getBool: " (reads)" else: "")
          of "view": "view " & r.data{"title"}.getStr
          of "viewClick", "requires": ""
          of "setting": "setting plugins." & pid & "." & r.data{"key"}.getStr
          of "vimMap": "vim " & r.data{"mode"}.getStr & "map " & r.data{"keys"}.getStr
          of "operator": "vim operator " & r.data{"keys"}.getStr
          of "textObject": "vim text object " & r.data{"keys"}.getStr
          of "ex": "vim :" & r.data{"name"}.getStr
          of "timer": "every " & $r.data{"ms"}.getInt & " ms"
          else: r.kind
        if what.len == 0: continue
        if r.kind == "command":
          result.add sideItem(what, 7, "", "", plugInvokeAction(regKey(r)), depth = 1)
        else: result.add sideItem(what, 2, "", "", depth = 1)
  if untrusted > 0:
    result.add sideItem($untrusted & " project plugin" & (if untrusted == 1: "" else: "s") & " held back", 4, "⛉",
                        "trust the folder", proc() = runCmd("Workspace: trust this folder"))
  # ned's own plugins not turned on yet: a tap shows what it does and turns it on
  var avail: seq[(string, string)]
  let bon = plugBundledOn()
  for (n, what, _) in PlugBundled:
    if n notin bon and plugInfoOf(n) < 0: avail.add (n, what)
  if avail.len > 0:
    result.add sideItem("AVAILABLE · ned's own plugins", 6)
    for (n, what) in avail:
      result.add sideItem(n, 1, "+", what, plugAvailableAction(n))
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
    var starting = false
    for h in plugHosts:
      if h.state in ["starting", "building"]: starting = true
    info("No plugin commands" & (if starting: " yet — the plugins are starting" else: ""))
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

proc cmdPluginReloadOne() =
  plugDiscover()
  var items: seq[(string, string, Action)]
  for p in plugs:
    if not p.enabled: continue
    let pid = p.id
    let det = if p.alone: "its own process" else: "with the other NimScript plugins"
    capture pid:
      items.add act(pid, det, proc() = plugReloadPlugin(pid))
  if items.len == 0:
    info("No plugin is on")
    return
  openActions("Reload a plugin", items)

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
