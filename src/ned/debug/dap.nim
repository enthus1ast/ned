# ── DAP (the Debug Adapter Protocol, as in VS Code and Zed): debugging Python (debugpy), C, C++ and Rust (gdb's own
#    DAP mode, or lldb-dap), Go (delve) … in the same Debug panel, with the same keys ──


proc dapWrite(data: string) =
  let fd = if dapSock >= 0: dapSock else: dbgProc.inFd
  if fd < 0: return
  var off = 0
  while off < data.len:
    let n = posix.write(fd, unsafeAddr data[off], data.len - off)
    if n > 0: off += n
    elif n < 0 and errno in [EAGAIN, EINTR]: os.sleep(2)
    else: break

proc dapSend(j: JsonNode) =
  let body = $j
  dapWrite("Content-Length: " & $body.len & "\r\n\r\n" & body)

proc dapRequest(cmd: string, args: JsonNode, cb: DapCb = nil) =
  inc dapSeq
  if cb != nil: dapPending[dapSeq] = cb
  dapSend(%*{"seq": dapSeq, "type": "request", "command": cmd, "arguments": args})

proc dapSetBreakpoints(path: string) =
  ## DAP sets a file's breakpoints all at once (with their conditions)
  if not dbgOn or not dbgDap: return
  let bps = newJArray()
  var lines: seq[int]
  for l in breakpoints.getOrDefault(path): lines.add l
  if dapTempBp[0] == path and dapTempBp[1] notin lines: lines.add dapTempBp[1]
  lines.sort()
  var ls1 = newJArray()
  for l in lines: ls1.add %(l + 1)
  for l in lines:
    var bp = %*{"line": l + 1}
    let c = bpCond.getOrDefault(path & ":" & $l)
    if c.len > 0: bp["condition"] = %c
    let lg = bpLog.getOrDefault(path & ":" & $l)
    if lg.len > 0 and dapCaps != nil and dapCaps{"supportsLogPoints"}.getBool(false): bp["logMessage"] = %lg
    bps.add bp
  dapRequest("setBreakpoints", %*{"source": {"path": path, "name": extractFilename(path)}, "breakpoints": bps,
                                  "lines": ls1})

proc dapSetDataBreakpoints() =
  ## "stop when it changes": the adapter takes the whole list at once
  if not dbgOn or not dbgDap: return
  let arr = newJArray()
  for (_, id) in dbgWatchpoints: arr.add %*{"dataId": id, "accessType": "write"}
  dapRequest("setDataBreakpoints", %*{"breakpoints": arr})

var dapStopReason = ""

proc dapLogEmulate(path: string, ln: int) =
  ## a logpoint the adapter cannot print itself: ned works out its {expressions}, prints, and goes on
  let msg = bpLog.getOrDefault(path & ":" & $ln)
  let parts = logParts(msg)
  var vals: seq[string]
  var exprs: seq[string]
  for (isExpr, t) in parts:
    if isExpr: exprs.add t
  vals.setLen(exprs.len)
  let at = extractFilename(path) & ":" & $(ln + 1)
  proc finish() =
    var o = ""
    var k = 0
    for (isExpr, t) in parts:
      if isExpr:
        o.add (if k < vals.len: vals[k] else: "?")
        inc k
      else: o.add t
    dbgOut.add "◇ " & at & "  " & o
    dbgState = "● running"
    dapRequest("continue", %*{"threadId": dapThread})
    dbgPanel()
  if exprs.len == 0:
    finish()
    return
  var left = exprs.len
  for k, x in exprs:
    let kk = k
    capture kk:
      dapRequest("evaluate", %*{"expression": x, "frameId": dapFrameId, "context": "watch"},
                 proc(body: JsonNode, ok: bool, msg: string) =
        if kk < vals.len: vals[kk] = (if ok: body{"result"}.getStr else: "‹" & msg & "›")
        dec left
        if left == 0: finish())

proc dapRefresh() =
  ## stopped: the call stack, the innermost frame's variables, the watches
  dapRequest("stackTrace", %*{"threadId": dapThread, "startFrame": 0, "levels": 40}, proc(body: JsonNode, ok: bool, msg: string) =
    dbgFrames.setLen(0)
    var first = true
    for f in jitems(body{"stackFrames"}):
      let path = f{"source", "path"}.getStr
      let ln = f{"line"}.getInt(1) - 1
      dbgFrames.add (f{"name"}.getStr, path, ln)
      if first:
        first = false
        dapFrameId = f{"id"}.getInt
        if dapStopReason == "breakpoint" and (path & ":" & $ln) in bpLog and
           not (dapCaps != nil and dapCaps{"supportsLogPoints"}.getBool(false)):
          dapLogEmulate(path, ln)
          return
        # "stop when it changes" asked for before the program ran: now that there is a frame
        for w in dbgWpWanted:
          if w in dapWpTried: continue
          dapWpTried.incl w
          var active = false
          for (e, _) in dbgWatchpoints:
            if e == w: active = true
          if not active: dbgAddWatchpoint(w)
        if path.len > 0 and fileExists(path):
          dbgAt = (path, ln)
          let b = openFile(path)
          if b != nil: b.centerOn(Pos(line: min(ln, b.lines.high), col: 0))
          dbgState = dbgState.split(" at ")[0] & " at " & extractFilename(path) & ":" & $(ln + 1) & " in " & f{"name"}.getStr
    if dbgFrames.len == 0:
      dbgPanel()
      return
    dapRequest("scopes", %*{"frameId": dapFrameId}, proc(body: JsonNode, ok: bool, msg: string) =
      var refs: seq[int]
      for sc in jitems(body{"scopes"}):
        if not sc{"expensive"}.getBool(false) and sc{"variablesReference"}.getInt > 0:
          let n = sc{"name"}.getStr.toLowerAscii
          if "global" in n or "register" in n: continue
          refs.add sc{"variablesReference"}.getInt
        if refs.len >= 2: break
      dbgVars.setLen(0)
      dapVarRefs.clear()
      var left = refs.len
      if left == 0: dbgPanel()
      for r in refs:
        dapRequest("variables", %*{"variablesReference": r}, proc(body: JsonNode, ok: bool, msg: string) =
          for v in jitems(body{"variables"}):
            let n = v{"name"}.getStr
            if n.startsWith("__") or n in ["special variables", "function variables", "class variables"]: continue
            dbgVars.add (n, v{"type"}.getStr, v{"value"}.getStr)
            if v{"variablesReference"}.getInt > 0: dapVarRefs[n] = v{"variablesReference"}.getInt
            if n in dbgExpanded and v{"variablesReference"}.getInt > 0:
              let nn = n
              capture nn:
                dapRequest("variables", %*{"variablesReference": v{"variablesReference"}.getInt},
                           proc(body: JsonNode, ok: bool, msg: string) =
                  var parts: seq[string]
                  for c in jitems(body{"variables"}):
                    if not c{"name"}.getStr.startsWith("__"): parts.add c{"name"}.getStr & " = " & c{"value"}.getStr
                    if parts.len >= 60: break
                  dbgDetail[nn] = "{" & parts.join(", ") & "}"
                  dbgPanel())
          dec left
          if left == 0: dbgPanel()
          needRender = true)))
  dbgWatchVals = newSeq[string](dbgWatches.len)
  for i, w in dbgWatches:
    let k = i
    capture k:
      dapRequest("evaluate", %*{"expression": w, "frameId": dapFrameId, "context": "watch"},
                 proc(body: JsonNode, ok: bool, msg: string) =
        if k < dbgWatchVals.len: dbgWatchVals[k] = (if ok: body{"result"}.getStr else: "‹" & msg & "›")
        dbgPanel())

proc tcpConnect(port: int): cint

proc dapHandle(j: JsonNode) =
  case j{"type"}.getStr
  of "response":
    let rs = j{"request_seq"}.getInt
    let ok = j{"success"}.getBool(true)
    if rs in dapPending:
      let cb = dapPending[rs]
      dapPending.del rs
      cb(j{"body"}, ok, j{"message"}.getStr)
    elif not ok and j{"command"}.getStr notin ["disconnect", "setExceptionBreakpoints", "configurationDone"]:
      let m = (if j{"body", "error", "format"}.getStr.len > 0: j{"body", "error", "format"}.getStr else: j{"message"}.getStr)
      dbgOut.add "error (" & j{"command"}.getStr & "): " & m
      error("Debugger (" & j{"command"}.getStr & "): " & m)
  of "event":
    let body = j{"body"}
    case j{"event"}.getStr
    of "initialized":
      # breakpoints first, then the program may run
      for f, ls in breakpoints:
        if ls.len > 0: dapSetBreakpoints(f)
      if dapTempBp[1] >= 0 and dapTempBp[0] notin breakpoints: dapSetBreakpoints(dapTempBp[0])
      dapRequest("setExceptionBreakpoints", %*{"filters": []})
      dapRequest("configurationDone", newJObject())
    of "stopped":
      dapThread = body{"threadId"}.getInt(dapThread)
      let reason = body{"reason"}.getStr
      dapStopReason = reason
      let desc = body{"description"}.getStr
      dbgState = "‖ stopped" & (if reason.len > 0: " (" & reason & ")" else: "") &
                 (if desc.len > 0 and desc.toLowerAscii != reason.toLowerAscii and not desc.toLowerAscii.startsWith("paused"):
                    ": " & desc else: "") &
                 (if body{"text"}.getStr.len > 0: " " & body{"text"}.getStr else: "")
      if reason == "data breakpoint": dbgOut.add "● " & (if desc.len > 0: desc else: "a watched value changed")
      if dapTempBp[1] >= 0:
        let p = dapTempBp[0]
        dapTempBp = ("", -1)
        dapSetBreakpoints(p)
      dapRefresh()
    of "continued":
      dbgState = "● running"
      dbgAt = ("", -1)
    of "output":
      let cat = body{"category"}.getStr
      if cat notin ["telemetry", "important", "console"] and dapInitDone:   # (not the adapter's own banner and chatter)
        for l in body{"output"}.getStr.strip(leading = false).splitLines: dbgOut.add (if cat == "stderr": "! " else: "") & l
    of "exited": dbgState = "program exited with code " & $body{"exitCode"}.getInt
    of "terminated":
      let st = if dbgState.startsWith("program exited"): dbgState else: "program exited"
      dbgEnd(st)
      return
    else: discard
  of "request":
    if j{"command"}.getStr == "startDebugging" and dapSock >= 0 and dapParentSock < 0:
      # js-debug: the program runs in a child session, reached over a second connection to the same port
      dapSend(%*{"seq": (inc dapSeq; dapSeq), "type": "response", "request_seq": j{"seq"}.getInt, "success": true,
                 "command": "startDebugging"})
      let args = j{"arguments"}
      let fd = tcpConnect(dapPort)
      if fd < 0:
        dbgOut.add "could not open the child debug session on port " & $dapPort
        return
      dapParentSock = dapSock
      dapSock = fd
      dapRbuf = ""
      let req = args{"request"}.getStr("launch")
      let conf = if args{"configuration"} != nil: args["configuration"] else: newJObject()
      dapRequest("initialize", %*{"clientID": "ned", "clientName": AppName, "adapterID": conf{"type"}.getStr("pwa-node"),
                                  "pathFormat": "path", "linesStartAt1": true, "columnsStartAt1": true,
                                  "supportsVariableType": true, "supportsRunInTerminalRequest": false,
                                  "supportsStartDebuggingRequest": true, "locale": "en"},
                 proc(body: JsonNode, ok: bool, msg: string) =
        if not ok:
          dbgEnd("the child debug session refused to start: " & msg)
          return
        if body != nil: dapCaps = body
        dapRequest(req, conf, proc(body: JsonNode, ok: bool, msg: string) =
          if not ok: dbgEnd("could not " & req & ": " & msg)
          else:
            dapLaunched = true
            if dbgState.startsWith("starting"): dbgState = "● running"
          dbgPanel()))
      return
    # the adapter asks something else of ned (runInTerminal …): not supported
    dapSend(%*{"seq": (inc dapSeq; dapSeq), "type": "response", "request_seq": j{"seq"}.getInt, "success": false,
               "command": j{"command"}.getStr, "message": "not supported by ned"})
  else: discard
  dbgPanel()

proc dapReadFd(fd: cint): bool =
  ## false when the adapter is gone
  var tmp: array[65536, char]
  let n = posix.read(fd, addr tmp[0], tmp.len)
  if n == 0: return false
  if n < 0: return errno in [EAGAIN, EINTR]
  let old = dapRbuf.len
  dapRbuf.setLen(old + n)
  copyMem(addr dapRbuf[old], addr tmp[0], n)
  while true:
    let he = dapRbuf.find("\r\n\r\n")
    if he < 0: break
    var clen = -1
    for h in dapRbuf[0 ..< he].split("\r\n"):
      if h.toLowerAscii.startsWith("content-length:"):
        try: clen = parseInt(h[15 .. ^1].strip)
        except ValueError: discard
    if clen < 0:
      dapRbuf = dapRbuf[he + 4 .. ^1]
      continue
    if dapRbuf.len < he + 4 + clen: break
    let body = dapRbuf[he + 4 ..< he + 4 + clen]
    dapRbuf = dapRbuf[he + 4 + clen .. ^1]
    try: dapHandle(parseJson(body))
    except CatchableError: discard
    if not dbgOn: return true
  true

proc dapFromMi(cmd: string) =
  ## the debugger commands ned's keys send (gdb's words), for a DAP adapter
  let t = cmd.strip
  if t.startsWith("-exec-continue"): dapRequest("continue", %*{"threadId": dapThread})
  elif t.startsWith("-exec-next"): dapRequest("next", %*{"threadId": dapThread})
  elif t.startsWith("-exec-step"): dapRequest("stepIn", %*{"threadId": dapThread})
  elif t.startsWith("-exec-finish"): dapRequest("stepOut", %*{"threadId": dapThread})
  elif t.startsWith("-stack-list-variables"): dapRefresh()
  elif t.startsWith("-break-insert"):
    let q1 = t.find('"')
    let q2 = t.rfind('"')
    if q1 >= 0 and q2 > q1:
      let loc = t[q1 + 1 ..< q2]
      let c = loc.rfind(':')
      if c > 0:
        let p = loc[0 ..< c]
        let l = (try: parseInt(loc[c + 1 .. ^1]) - 1 except ValueError: -1)
        if " -t " in t & " " and l >= 0: dapTempBp = (p, l)
        dapSetBreakpoints(p)

proc dapDrainParent() =
  ## js-debug's first session: read and drop what it sends (its child session is the one ned follows)
  if dapParentSock < 0: return
  var tmp: array[16384, char]
  let n = posix.read(dapParentSock, addr tmp[0], tmp.len)
  if n == 0 or (n < 0 and errno notin [EAGAIN, EINTR]):
    discard posix.close(dapParentSock)
    dapParentSock = -1

proc tcpConnect(port: int): cint =
  let fd = posix.socket(AF_INET, SOCK_STREAM, 0)
  if fd.cint < 0: return -1
  var a: Sockaddr_in
  a.sin_family = TSa_Family(AF_INET)
  a.sin_port = htons(uint16(port))
  a.sin_addr.s_addr = inet_addr("127.0.0.1")
  if posix.connect(fd, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) != 0:
    discard posix.close(fd.cint)
    return -1
  fd.cint

proc cargoPackageName(root: string): string =
  try:
    var inPkg = false
    for l in readFile(root / "Cargo.toml").splitLines:
      let t = l.strip
      if t.startsWith("["): inPkg = t == "[package]"
      elif inPkg and t.startsWith("name") and '=' in t: return t.split('=', 1)[1].strip.strip(chars = {'"', '\''})
  except CatchableError: discard
  ""

proc versionOf(tool: string): string

var gdbDapState = 0                    # 0 not asked · 1 gdb speaks DAP (14 or newer) · 2 it does not

proc gdbSpeaksDap(): bool =
  ## gdb has a DAP mode from version 14 (built with Python, as distributions ship it)
  if gdbDapState == 0:
    gdbDapState = 2
    if haveExe("gdb"):
      let v = versionOf("gdb")
      let major = (try: parseInt(v.split('.')[0]) except ValueError: 0)
      if major >= 14: gdbDapState = 1
  gdbDapState == 1

proc lldbDapExe(): string =
  ## lldb's DAP program: lldb-dap (LLVM 18+), lldb-vscode before that; Debian adds the LLVM version
  for n in ["lldb-dap", "lldb-vscode"]:
    if haveExe(n): return n
  for v in countdown(24, 11):
    for n in ["lldb-dap-" & $v, "lldb-vscode-" & $v]:
      if haveExe(n): return n
  ""

proc codelldbExe(): string =
  if haveExe("codelldb"): return "codelldb"
  for p in [getHomeDir() / ".local/share/nvim/mason/bin/codelldb", getHomeDir() / ".local/bin/codelldb"]:
    if fileExists(p): return p
  ""

proc jsDebugDir(): string = getEnv("XDG_DATA_HOME", getHomeDir() / ".local" / "share") / "js-debug"

proc jsDebugCmd(): seq[string] =
  ## how to start vscode-js-debug's DAP server (empty when it is not installed)
  if haveExe("js-debug-adapter"): return @["js-debug-adapter", "$port", "127.0.0.1"]
  for p in [jsDebugDir() / "src" / "dapDebugServer.js",
            getHomeDir() / ".local/share/nvim/mason/packages/js-debug-adapter/js-debug/src/dapDebugServer.js",
            getHomeDir() / "js-debug" / "src" / "dapDebugServer.js"]:
    if fileExists(p): return @["node", p, "$port", "127.0.0.1"]
  @[]

const JsDebugInstall = "mkdir -p ~/.local/share && curl -fsSL \"$(curl -fsSL " &
  "https://api.github.com/repos/microsoft/vscode-js-debug/releases/latest | grep -o 'https://[^\"]*js-debug-dap-v[^\"]*tar.gz' " &
  "| head -1)\" | tar xz -C ~/.local/share"

proc nodeMajor(): int =
  let v = versionOf("node")
  try: parseInt(v.split('.')[0]) except ValueError: 0

proc dapPresets(b: Buffer): seq[JsonNode] =
  ## the debuggers ned knows for a file's language, best first: "name", "command", "build", "launch",
  ## "connect" (the adapter listens on $port), "needs" (what it is) and "install" (how to get it here)
  let py = block:
    var p = "python3"
    for v in [rootDir / ".venv" / "bin" / "python", rootDir / "venv" / "bin" / "python"]:
      if fileExists(v): p = v
    p
  case b.lang.id
  of "python":
    result.add %*{"name": "debugpy", "command": [py, "-m", "debugpy.adapter"],
      "launch": {"program": "$file", "cwd": "$dir", "console": "internalConsole", "justMyCode": true, "python": py},
      "needs": "debugpy", "install": py & " -m pip install debugpy", "check": [py, "-c", "import debugpy; print(debugpy.__version__)"]}
  of "c", "cpp", "rust":
    let build = if b.lang.id == "rust": "cargo build"
                elif b.lang.id == "c": (if haveExe("cc"): "cc" else: "clang") & " -g -O0 -o $exe $file"
                else: (if haveExe("c++"): "c++" else: "clang++") & " -g -O0 -o $exe $file"
    let prog = if b.lang.id == "rust": "$cargoexe" else: "$exe"
    let cwd = if b.lang.id == "rust": "$root" else: "$dir"
    let lldb = lldbDapExe()
    let cl = codelldbExe()
    result.add %*{"name": "gdb (DAP mode)", "command": ["gdb", "-i", "dap"], "build": build,
      "launch": {"program": prog, "cwd": cwd}, "needs": "gdb 14 or newer", "install": installHint("gdb", "gdb")}
    result.add %*{"name": "lldb-dap", "command": [(if lldb.len > 0: lldb else: "lldb-dap")], "build": build,
      "launch": {"program": prog, "cwd": cwd}, "needs": "lldb-dap (LLVM 18+; lldb-vscode before)",
      "install": installHint("lldb", "lldb")}
    var clLaunch = %*{"program": prog, "cwd": cwd}
    if b.lang.id == "rust": clLaunch["sourceLanguages"] = %["rust"]
    result.add %*{"name": "codelldb", "command": [(if cl.len > 0: cl else: "codelldb"), "--port", "$port"], "connect": true,
      "build": build, "launch": clLaunch, "needs": "codelldb",
      "install": "download codelldb-<platform>.vsix from github.com/vadimcn/codelldb/releases, unzip it and put " &
                 "extension/adapter/codelldb on your PATH"}
  of "go":
    result.add %*{"name": "delve", "command": ["dlv", "dap", "--listen=127.0.0.1:$port"], "connect": true,
      "launch": {"mode": (if b.path.endsWith("_test.go"): "test" else: "debug"), "program": "$dir", "cwd": "$dir"},
      "needs": "delve (dlv)",
      "install": (if isTermux(): "pkg install delve" else: "go install github.com/go-delve/delve/cmd/dlv@latest")}
  of "javascript", "typescript":
    var cmd = jsDebugCmd()
    if cmd.len == 0: cmd = @["js-debug-adapter", "$port", "127.0.0.1"]
    var launch = %*{"type": "pwa-node", "program": "$file", "cwd": "$dir", "console": "internalConsole",
                    "sourceMaps": true, "skipFiles": ["<node_internals>/**"]}
    if b.lang.id == "typescript":
      if nodeMajor() >= 22: launch["runtimeArgs"] = %["--experimental-strip-types", "--no-warnings"]
      elif haveExe("tsx"): launch["runtimeExecutable"] = %"tsx"
    result.add %*{"name": "js-debug (Node)", "command": cmd, "connect": true, "launch": launch,
      "needs": "vscode-js-debug's DAP server, and node", "install": JsDebugInstall}
  else: discard

proc dapExeFound(ad: JsonNode): bool =
  let c = ad{"command"}
  if c == nil or c.kind != JArray or c.len == 0: return false
  let x = c[0].getStr
  if x == "js-debug-adapter" and not haveExe(x): return false
  if x == "gdb": return gdbSpeaksDap()
  if x == "node" and c.len > 1: return haveExe("node") and fileExists(c[1].getStr)
  findExe(x).len > 0 or fileExists(x)

proc dapAdapterFor(b: Buffer): JsonNode =
  ## the adapter for a file's language: the "debug.adapters" setting, else the first of ned's presets
  ## that is installed (else the first one, so the Debug panel can say what to install)
  let user = settingNode("debug.adapters")
  if user != nil and user.kind == JObject and user{b.lang.id} != nil and user[b.lang.id].kind == JObject:
    result = user[b.lang.id].copy
    if result{"name"}.getStr.len == 0: result["name"] = %"from settings › debug.adapters"
    result["fromSettings"] = %true
    return
  let ps = dapPresets(b)
  if ps.len == 0: return nil
  for p in ps:
    if p.dapExeFound: return p
  ps[0]

proc dapSubst(s: string, b: Buffer, port: int, exe, cargoExe, root: string): string =
  s.replace("$file", b.path).replace("$dir", parentDir(b.path)).replace("$root", root).replace("$cargoexe", cargoExe)
   .replace("$exe", exe).replace("$port", $port)

proc dapSubstJ(n: JsonNode, b: Buffer, port: int, exe, cargoExe, root: string): JsonNode =
  case n.kind
  of JString: %dapSubst(n.getStr, b, port, exe, cargoExe, root)
  of JArray:
    let a = newJArray()
    for x in n: a.add dapSubstJ(x, b, port, exe, cargoExe, root)
    a
  of JObject:
    var o = newJObject()
    for k, v in n: o[k] = dapSubstJ(v, b, port, exe, cargoExe, root)
    o
  else: n

proc dapLaunch(b: Buffer, ad: JsonNode, port: int, exe, cargoExe, root: string) =
  var cmd: seq[string]
  for x in jitems(dapSubstJ(ad{"command"}, b, port, exe, cargoExe, root)): cmd.add x.getStr
  if cmd.len == 0 or not ad.dapExeFound:
    if cmd.len > 0 and cmd[0] == "gdb" and haveExe("gdb"):
      dbgState = "gdb " & versionOf("gdb") & " has no DAP mode (it needs gdb 14 or newer) — Debug: choose the debugger…"
    else:
      dbgState = "the debug adapter is not installed: " & (if ad{"needs"}.getStr.len > 0: ad{"needs"}.getStr
                                                         elif cmd.len > 0: cmd[0] else: "none set") &
                 (if ad{"install"}.getStr.len > 0: " — palette › Debug: install the debugger" else: "")
    dbgPanel()
    return
  try:
    dbgProc = spawnProc(cmd, parentDir(b.path), siPipe, (if ad{"connect"}.getBool: erMerge else: erNull))
  except OSError as e:
    dbgState = "could not start " & cmd[0] & ": " & e.msg
    dbgPanel()
    return
  dbgOn = true
  dbgDap = true
  dapPort = port
  dapRbuf = ""
  dapPending.clear()
  dapSeq = 0
  dapThread = 0
  dapLaunched = false
  dapInitDone = false
  if ad{"connect"}.getBool:
    var fd: cint = -1
    for _ in 0 ..< 60:                         # the adapter opens its port within a few seconds
      fd = tcpConnect(port)
      if fd >= 0: break
      os.sleep(100)
    if fd < 0:
      dbgEnd("could not connect to " & cmd[0] & " on port " & $port)
      return
    dapSock = fd
  dbgState = "starting " & extractFilename(cmd[0]) & "…"
  let launchArgs = dapSubstJ((if ad{"launch"} != nil: ad["launch"] else: newJObject()), b, port, exe, cargoExe, root)
  let request = ad{"request"}.getStr("launch")
  dapRequest("initialize", %*{"clientID": "ned", "clientName": AppName, "adapterID": b.lang.id, "pathFormat": "path",
                              "linesStartAt1": true, "columnsStartAt1": true, "supportsVariableType": true,
                              "supportsRunInTerminalRequest": false, "supportsStartDebuggingRequest": true,
                              "locale": "en"},
             proc(body: JsonNode, ok: bool, msg: string) =
    if not ok:
      dbgEnd("the debug adapter refused to start: " & msg)
      return
    dapCaps = body
    dapInitDone = true
    dapRequest(request, launchArgs, proc(body: JsonNode, ok: bool, msg: string) =
      if not ok: dbgEnd("could not " & request & ": " & msg)
      else:
        dapLaunched = true
        if dbgState.startsWith("starting"): dbgState = "● running"
      dbgPanel()))
  dbgPanel()

proc dapStart(b: Buffer) =
  ## build when the language needs it, start the adapter, launch the program
  let ad = dapAdapterFor(b)
  if ad == nil:
    info("No debugger for " & b.lang.name & " — set one in settings › debug.adapters (any Debug Adapter Protocol program)")
    return
  discard saveAll()
  let port = 42000 + (getCurrentProcessId() mod 9000)
  let exe = privDir() / ("ned_debug_" & splitFile(b.path).name)
  var root = parentDir(b.path)
  var cargoExe = ""
  if b.lang.id == "rust":
    let cr = cargoRoot(parentDir(b.path))
    if cr.len > 0:
      root = cr
      cargoExe = cr / "target" / "debug" / cargoPackageName(cr)
  setPanel(pkDebug)
  dbgFrames.setLen(0)
  dbgVars.setLen(0)
  let build = dapSubst(ad{"build"}.getStr, b, port, exe, cargoExe, root)
  if build.len == 0:
    dbgOut = @[]
    dapLaunch(b, ad, port, exe, cargoExe, root)
    return
  dbgState = "building " & extractFilename(b.path) & " with debug information…"
  dbgOut = @["$ " & build]
  dbgPanel()
  let bb = b
  discard startJob(jkTool, build & " 2>&1", root, proc(j: Job) =
    if j.code != 0:
      for l in j.output.splitLines: dbgOut.add l
      dbgState = "the build failed"
      dbgPanel()
      return
    dapLaunch(bb, ad, port, exe, cargoExe, root))

proc dapCheckReport(b: Buffer): string =
  ## what F5 will use for this file, whether it is installed, and how to get it
  result = "Debugger for " & b.name & " (" & b.lang.name & ")\n\n"
  if b.lang.mode == lmNim:
    result.add "Nim files use gdb (or lldb) through its machine interface — F5 builds with --debugger:native.\n"
    result.add (if haveExe("gdb"): "  ✓ gdb " & versionOf("gdb") & "\n"
                elif haveExe("lldb"): "  ✓ lldb " & versionOf("lldb") & "\n"
                else: "  ✗ gdb is not installed — " & installHint("gdb", "gdb") & "\n")
    return
  let chosen = dapAdapterFor(b)
  if chosen == nil:
    result.add "ned has no debugger for " & b.lang.name & ". Any Debug Adapter Protocol program works: add it to\n" &
               "settings › debug.adapters as \"" & b.lang.id & "\": {\"command\": [...], \"launch\": {...}}.\n"
    return
  result.add "F5 uses: " & chosen{"name"}.getStr & (if chosen{"fromSettings"}.getBool: "" else: " (ned's choice)") & "\n\n"
  var all = dapPresets(b)
  if chosen{"fromSettings"}.getBool: all.insert(chosen, 0)
  for p in all:
    let ok = p.dapExeFound
    var cmd: seq[string]
    for x in jitems(p{"command"}): cmd.add x.getStr
    var ver = ""
    if ok and cmd.len > 0:
      if cmd[0] == "node" and cmd.len > 1: ver = "node " & versionOf("node") & " · " & cmd[1]
      elif p{"check"} != nil:
        var c: seq[string]
        for x in jitems(p{"check"}): c.add quoteShell(x.getStr)
        let (_, o, _) = runFilter(c.join(" ") & " 2>&1", "", rootDir, 5000)
        ver = o.strip.splitLines[0]
      else: ver = versionOf(cmd[0])
    let mark = if ok: "✓" elif cmd.len > 0 and cmd[0] == "gdb" and haveExe("gdb"): "!" else: "✗"
    result.add "  " & mark & " " & alignLeft(p{"name"}.getStr, 18) &
               (if ok: (if ver.len > 0: ver else: "installed")
                elif mark == "!": "gdb " & versionOf("gdb") & " has no DAP mode — it needs gdb 14 or newer"
                else: "not installed — " & p{"needs"}.getStr) & "\n"
    if not ok and p{"install"}.getStr.len > 0: result.add "      install: " & p{"install"}.getStr & "\n"
    result.add "      runs:    " & cmd.join(" ") & "\n"
    if p{"build"}.getStr.len > 0: result.add "      builds:  " & p{"build"}.getStr & "\n"
  result.add "\nPalette › Debug: choose the debugger… picks another one for " & b.lang.name &
             " · Debug: install the debugger… runs its install command in the terminal.\n"

proc cmdDebugCheck() =
  let b = buf()
  discard openScratch("Debugger check", dapCheckReport(b), langByName("Text"))

proc cmdDebugChoose() =
  let b = buf()
  let ps = dapPresets(b)
  if ps.len == 0:
    info("ned has no debugger presets for " & b.lang.name & " — settings › debug.adapters takes any DAP program")
    return
  var items: seq[(string, string, Action)]
  let lid = b.lang.id
  items.add act("ned's choice", "the first one that is installed", proc() =
    var cur = settingNode("debug.adapters")
    var nx = if cur != nil and cur.kind == JObject: cur.copy else: newJObject()
    if nx.hasKey(lid): nx.delete(lid)
    setSetting("debug.adapters", nx)
    info("Debugger for " & lid & ": ned's choice"))
  for p0 in ps:
    let p: JsonNode = p0
    capture p:                         # (each row its own preset)
      items.add act(p{"name"}.getStr, (if p.dapExeFound: "installed" else: "not installed · " & p{"install"}.getStr),
        proc() =
          var cur = settingNode("debug.adapters")
          var nx = if cur != nil and cur.kind == JObject: cur.copy else: newJObject()
          var keep = newJObject()
          for k in ["name", "command", "build", "launch", "connect", "needs", "install"]:
            if p.hasKey(k): keep[k] = p[k]
          nx[lid] = keep
          setSetting("debug.adapters", nx)
          info("Debugger for " & lid & ": " & p{"name"}.getStr &
               (if p.dapExeFound: "" else: " — not installed yet (Debug: install the debugger…)")))
  openActions("Debugger for " & b.lang.name, items)

proc cmdDebugInstall() =
  let b = buf()
  let ps = dapPresets(b)
  var items: seq[(string, string, Action)]
  for p in ps:
    let cmd = p{"install"}.getStr
    if cmd.len == 0 or cmd.startsWith("download "): continue
    let label = p{"name"}.getStr
    capture cmd:
      items.add act(label, cmd, proc() =
        runInTerm(cmd)
        info("Installing in the terminal — Debug: check the debugger… when it is done"))
  if items.len == 0:
    if ps.len > 0: discard openScratch("Debugger check", dapCheckReport(b), langByName("Text"))
    else: info("ned has no debugger presets for " & b.lang.name)
    return
  openActions("Install a debugger for " & b.lang.name & " (runs in the terminal)", items)

proc dapStop() =
  if dapLaunched: dapRequest("disconnect", %*{"terminateDebuggee": true})
  if dapSock >= 0:
    discard posix.close(dapSock)
    dapSock = -1
  if dapParentSock >= 0:
    if dapLaunched:
      let child = dapSock
      dapSock = dapParentSock          # the first session ends too (it stops the adapter's program)
      dapRequest("disconnect", %*{"terminateDebuggee": true})
      dapSock = child
    discard posix.close(dapParentSock)
    dapParentSock = -1
  dbgDap = false
  dapPending.clear()
  dapVarRefs.clear()
  dapTempBp = ("", -1)
  dapLaunched = false
