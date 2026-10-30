# ── one Nim per project (nim.toolchain): the Nim a project builds with, for every tool ned starts — nim, nimble,
#    nimsuggest, nimlangserver, testament, the terminal — by putting its bin folder first on PATH. "auto" (the
#    default) keeps the `nim` on PATH unless the project's .nimble asks for a Nim it is not and choosenim or grabnim
#    has one that is; a version ("2.0.16") or a folder picks one. Warnings when the Nim in use is not what the
#    .nimble asks for, or when nimsuggest is another Nim's ──

var
  tcBasePath = ""                  # PATH as ned started (a toolchain's bin goes in front of it)
  tcBin = ""                       # the bin folder put in front ("" none: PATH as it was)
  tcTop = ""                       # the Nim folder in use (its lib, its compiler, its bin)
  tcVer: seq[int]                  # its version (@[] not known)
  tcWhy = ""                       # why this one: "nim.toolchain", "the .nimble requires nim == 1.6.20", "PATH"
  tcNeeds = ""                     # what the project's .nimble asks for ("" nothing)
  tcProblem = ""                   # the Nim in use does not do: the status bar says so
  tcWarned: HashSet[string]        # (each warning once a session)
  tcApplied = "\x00"               # (the setting and project last worked out for)

proc tcVersionOf(top: string): seq[int] =
  ## a Nim folder's version, from its library (NimMajor, NimMinor, NimPatch) — no program run
  for f in [top / "lib" / "system" / "compilation.nim", top / "lib" / "system.nim",
            top / "lib" / "nim" / "system" / "compilation.nim", top / "lib" / "nim" / "system.nim"]:
    if not fileExists(f): continue
    var maj, mnr, pat = -1
    try:
      var n = 0
      for l in lines(f):
        inc n
        if n > 400: break
        let t = l.strip
        for (name, which) in [("NimMajor*", 0), ("NimMinor*", 1), ("NimPatch*", 2)]:
          if t.startsWith(name) and '=' in t:
            let v = t[t.rfind('=') + 1 .. ^1].strip
            var d = 0
            var any = false
            for c in v:
              if c notin Digits: break
              d = d * 10 + ord(c) - 48
              any = true
            if any:
              case which
              of 0: maj = d
              of 1: mnr = d
              else: pat = d
        if maj >= 0 and mnr >= 0 and pat >= 0: return @[maj, mnr, pat]
    except CatchableError: discard

proc tcVerText(v: seq[int]): string =
  ## a version as text, its numbers joined by dots
  var p: seq[string]
  for x in v: p.add $x
  p.join(".")

proc tcTopOfExe(exe: string): string =
  ## the Nim folder a `nim` program belongs to (symlinks followed; choosenim's proxy: its current toolchain)
  if exe.len == 0: return ""
  var real = exe
  for _ in 0 .. 8:
    try:
      let t = expandSymlink(real)
      real = if t.isAbsolute: t else: parentDir(real) / t
    except OSError: break
  let cur = getHomeDir() / ".choosenim" / "current"
  if parentDir(real) == getHomeDir() / ".nimble" / "bin" and fileExists(cur):
    try:
      let d = readFile(cur).strip
      if dirExists(d): return normalizedPath(d)
    except CatchableError: discard
  let top = parentDir(parentDir(real))
  if tcVersionOf(top).len > 0: return normalizedPath(top)
  # (a distribution's layout: /usr/bin/nim with /usr/lib/nim)
  for lib in [top / "lib" / "nim"]:
    if fileExists(lib / "system.nim"): return normalizedPath(top)
  ""

proc tcFindOn(path, name: string): string =
  ## `name` in the folders of a PATH value ("" none)
  for d in path.split(PathSep):
    if d.len == 0: continue
    let p = d / name.addFileExt(ExeExt)
    if fileExists(p):
      try:
        if fpUserExec in getFilePermissions(p): return p
      except OSError: discard
  ""

proc tcInstalled(): seq[(seq[int], string)] =
  ## the Nims choosenim and grabnim installed: (version, folder), newest first
  var dirs: seq[string]
  for root in [getHomeDir() / ".choosenim" / "toolchains", getHomeDir() / ".grabnim", getHomeDir() / ".local" / "share" / "grabnim",
               getEnv("NED_NIM_TOOLCHAINS"), (if rootDir.len > 0: rootDir / "deps" else: "")]:
    if root.len == 0 or not dirExists(root): continue
    try:
      for k, d in walkDir(root):
        if k in {pcDir, pcLinkToDir} and fileExists(d / "bin" / addFileExt("nim", ExeExt)): dirs.add d
    except OSError: discard
  for d in dirs:
    let v = tcVersionOf(d)
    if v.len > 0: result.add (v, normalizedPath(d))
  result.sort(proc(a, b: (seq[int], string)): int =
    for i in 0 ..< 3:
      let c = cmp(b[0][i], a[0][i])
      if c != 0: return c
    cmp(a[1], b[1]))

proc tcProjectNeeds(): string =
  ## what the project's .nimble asks of Nim ("nim >= 2.0.0" → ">= 2.0.0"; "" nothing)
  let nb = findNimbleFile(if rootDir.len > 0: rootDir else: getCurrentDir())
  if nb.len == 0: return ""
  var parts: seq[string]
  for r in nxNimbleRequires(nb):
    let (nm, cons) = nxSplitRequire(r)
    if cmpIgnoreCase(nm, "nim") == 0 and cons.strip.len > 0: parts.add cons.strip
  parts.join(" & ")

proc tcWarnOnce(key, msg: string, act: proc() = nil, label = "") =
  ## shows a warning once per key: a toast with a button (label, running act) when an action is given, else a plain
  ## warning
  if key in tcWarned: return
  tcWarned.incl key
  if act != nil: toast(msg, 2, label, act, 15000) else: warn(msg)

proc tcCheckNimsuggest() =
  ## nimsuggest from another Nim than `nim`: its answers follow that one's library
  let ns = findExe("nimsuggest")
  if ns.len == 0 or tcTop.len == 0: return
  let nsTop = tcTopOfExe(ns)
  if nsTop.len > 0 and nsTop != tcTop:
    let nv = tcVersionOf(nsTop)
    tcWarnOnce("ns:" & nsTop & ":" & tcTop, "nimsuggest is another Nim's (" &
               (if nv.len > 0: tcVerText(nv) else: nsTop) & ") than nim (" & tcVerText(tcVer) &
               ") — its answers follow that one. Put both on PATH from one install, or set nim.toolchain")

proc applyNimToolchain() =
  ## the Nim this project uses, first on PATH for every program ned starts (worked out again when nim.toolchain
  ## or the project changes)
  if tcBasePath.len == 0: tcBasePath = getEnv("PATH")
  let want = sStr("nim.toolchain").strip
  let key = want & "\t" & rootDir & "\t" & nxStamp(findNimbleFile(if rootDir.len > 0: rootDir else: getCurrentDir()))
  if key == tcApplied: return
  tcApplied = key
  tcNeeds = tcProjectNeeds()
  var top = ""
  var why = ""
  let pathNim = tcFindOn(tcBasePath, "nim")
  let pathTop = tcTopOfExe(pathNim)
  let pathVer = if pathTop.len > 0: tcVersionOf(pathTop) else: @[]
  case want.toLowerAscii
  of "path":
    discard
  of "", "auto":
    if tcNeeds.len > 0 and (pathVer.len == 0 or not nxSatisfies(tcVerText(pathVer), tcNeeds)):
      for (v, d) in tcInstalled():
        if nxSatisfies(tcVerText(v), tcNeeds):
          if pathVer.len > 0 or pathNim.len == 0:      # (the PATH one's version known not to do — or none)
            top = d
            why = "the .nimble requires nim " & tcNeeds
          break
  else:
    if dirExists(want):
      if fileExists(want / "bin" / addFileExt("nim", ExeExt)): top = normalizedPath(want)
      elif fileExists(want / addFileExt("nim", ExeExt)): top = normalizedPath(parentDir(want))
    elif fileExists(want) and splitFile(want).name == "nim":
      top = normalizedPath(parentDir(parentDir(want)))
    else:
      let v = ecVersion(want.strip(chars = {'v', ' '}).replace("nim-", "").replace("#", ""))
      for (iv, d) in tcInstalled():
        if v.len > 0 and iv[0 ..< min(iv.len, v.len)] == v:
          top = d
          break
      if top.len == 0 and want.toLowerAscii in ["stable", "devel"]:
        for (iv, d) in tcInstalled():
          if want.toLowerAscii in extractFilename(d).toLowerAscii:
            top = d
            break
    if top.len == 0:
      tcWarnOnce("tc:" & want, "nim.toolchain \"" & want & "\": no such Nim installed (choosenim " & want &
                 " installs it) — using the nim on PATH")
    else: why = "nim.toolchain"
  let bin = if top.len > 0: top / "bin" else: ""
  if bin != tcBin:
    tcBin = bin
    putEnv("PATH", if bin.len > 0: bin & PathSep & tcBasePath else: tcBasePath)
    resetExeCache()
    # (the index, nimsuggest and the language server follow the new Nim)
    nxLibGuessed = false
    nxLibFound = ""
    nxDumped.clear()
    if gRaw:                                     # (the editor: what runs follows; ned --lint, nedls: nothing runs)
      nsShutdown()
      restartLangServer("nim")
      toolVersions.del "nim"
      toolVersions.del "nimble"
      probeTools()
    if bin.len > 0 and gRaw: info("Nim " & tcVerText(tcVersionOf(top)) & " for this project (" & why & ")")
  tcTop = if top.len > 0: top else: pathTop
  tcVer = if top.len > 0: tcVersionOf(top) else: pathVer
  tcWhy = if top.len > 0: why else: "PATH"
  # (the Nim in use and what the project asks for)
  tcProblem = ""
  if tcNeeds.len > 0 and tcVer.len > 0 and not nxSatisfies(tcVerText(tcVer), tcNeeds):
    tcProblem = "needs nim " & tcNeeds
    tcWarnOnce("need:" & rootDir & ":" & tcVerText(tcVer), "This project's .nimble requires nim " & tcNeeds &
               "; the Nim in use is " & tcVerText(tcVer) & " — choose another for it", proc() =
                 runCmd("Nim: choose the Nim for this project…"), "Choose")
  tcCheckNimsuggest()
  needRender = true

proc nimToolchainLine(): string =
  ## for the Nim dock and the status bar's tip: "Nim 2.2.12 · ~/.choosenim/toolchains/nim-2.2.12 (PATH)"
  if tcVer.len == 0 and tcTop.len == 0: return ""
  "Nim " & (if tcVer.len > 0: tcVerText(tcVer) else: "?") & (if tcTop.len > 0: " · " & tildePath(tcTop) else: "") &
    " (" & tcWhy & ")"

proc cmdChooseProjectNim() =
  ## the Nims installed (PATH's, choosenim's, grabnim's): the one picked is this project's (nim.toolchain in
  ## .ned/settings.json — every tool ned starts uses it)
  var items: seq[(string, string, Action)]
  let pathNim = tcFindOn(if tcBasePath.len > 0: tcBasePath else: getEnv("PATH"), "nim")
  let pathTop = tcTopOfExe(pathNim)
  let need = tcProjectNeeds()
  proc mark(v: seq[int]): string =
    ## for a pick-list entry: whether a Nim version meets what the project's .nimble asks (a tick or a cross with the
    ## requirement), empty when it asks nothing
    if need.len == 0 or v.len == 0: "" elif nxSatisfies(tcVerText(v), need): "  ✓ meets " & need else: "  ✗ not " & need
  if pathNim.len > 0:
    let v = tcVersionOf(pathTop)
    items.add act("The nim on PATH" & (if v.len > 0: " (" & tcVerText(v) & ")" else: ""), tildePath(pathNim) & mark(v),
                  proc() = setProjectSetting("nim.toolchain", %"path"))
  items.add act("Automatic", "PATH's, unless the .nimble asks for another that is installed", proc() =
    setProjectSetting("nim.toolchain", %"auto"))
  for (v, d) in tcInstalled():
    let vv = tcVerText(v)
    let detail = tildePath(d) & mark(v)
    capture vv:
      items.add act("Nim " & vv, detail, proc() = setProjectSetting("nim.toolchain", %vv))
  if items.len <= 2 and not haveExe("choosenim") and not haveExe("grabnim"):
    info("One Nim is installed — choosenim or grabnim installs others (choosenim 2.0.16)")
  openActions("The Nim for this project" & (if need.len > 0: " (its .nimble: nim " & need & ")" else: ""), items)
