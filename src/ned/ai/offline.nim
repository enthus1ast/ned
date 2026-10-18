# ── AI on this device, without the internet: Ollama (or llama.cpp's llama-server) found or installed, started, a
#    model that fits the memory downloaded, ned set to use it and a first answer timed. Nothing leaves the device ──

const LocalModels = [
  # (Ollama's name, download size, memory it needs to run well — MB)
  ("qwen2.5-coder:0.5b", "0.4 GB", 1500), ("qwen2.5-coder:1.5b", "1 GB", 3000),
  ("qwen2.5-coder:3b", "1.9 GB", 5000), ("qwen2.5-coder:7b", "4.7 GB", 9000),
  ("qwen2.5-coder:14b", "9 GB", 18000)]

var
  ollamaPullJob: Job        # a model being downloaded
  ollamaPullModel = ""
  ollamaPullShown = ""

proc memTotalMB(): int =
  ## this device's memory (Linux and Android: /proc/meminfo; macOS: sysctl)
  try:
    for l in readFile("/proc/meminfo").splitLines:
      if l.startsWith("MemTotal:"):
        return parseInt(l.splitWhitespace()[1]) div 1024
  except CatchableError: discard
  let (ok, o, _) = runFilter("sysctl -n hw.memsize 2>/dev/null", "", rootDir, 2000)
  if ok:
    try: return int(parseBiggestInt(o.strip) div (1024 * 1024))
    except ValueError: discard
  0

func localModelFits(mb: int): int =
  ## the biggest of LocalModels that runs well in this much memory (0: the smallest)
  result = 0
  for i, (_, _, need) in LocalModels:
    if mb == 0 or need <= mb: result = i

proc ollamaUrl(): string =
  result = sStr("ai.localUrl").strip(leading = false, chars = {'/'})
  if result.len == 0: result = "http://127.0.0.1:11434"

proc useOllamaModel(model: string) =
  ## ned set to the local model; then a first, timed answer
  setSetting("ai.provider", %"ollama")
  setSetting("ai.model", %model)
  let u = ollamaUrl()
  setSetting("ai.baseUrl", %(if u in ["http://127.0.0.1:11434", "http://localhost:11434"]: "" else: u & "/v1"))
  info("AI: " & model & " on this device — asking it something to see that it answers…")
  let t0 = getMonoTime()
  aiOneShot("Reply with just the word: ready", proc(t: string) =
    let ms = (getMonoTime() - t0).inMilliseconds
    toast("✓ " & model & " answers on this device (" & formatFloat(ms.float / 1000, ffDecimal, 1) & " s) — chat, " &
          "inline edits and suggestions use it now, without the internet", 4, "Chat", proc() = showSide(svAssistant), 15000))

proc ollamaStart(then: proc()) =
  ## the Ollama server in the background (it keeps running after ned), then `then` once it answers
  if not haveExe("ollama"):
    error("Ollama is not installed")
    return
  let log = privDir() / "ollama.log"
  info("Starting Ollama…")
  let cmd = "(command -v setsid >/dev/null 2>&1 && setsid nohup ollama serve >" & quoteShell(log) &
            " 2>&1 & ) || (nohup ollama serve >" & quoteShell(log) & " 2>&1 &); " &
            "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do curl -s --max-time 1 " &
            quoteShell(ollamaUrl() & "/api/tags") & " >/dev/null 2>&1 && exit 0; sleep 0.5; done; exit 1"
  discard startJob(jkTool, cmd, getHomeDir(), proc(j: Job) =
    if j.code == 0: then()
    else: error("Ollama did not start — see " & log))

proc ollamaPull(model: string) =
  ## the model downloaded through Ollama's API (progress in the status line), then used
  if ollamaPullJob != nil and not ollamaPullJob.done:
    info("Already downloading " & ollamaPullModel)
    return
  let body = $(%*{"model": model})
  ollamaPullModel = model
  ollamaPullShown = ""
  info("Downloading " & model & "…")
  ollamaPullJob = startJob(jkTool, "curl -sN --max-time 7200 " & quoteShell(ollamaUrl() & "/api/pull") & " -d " &
                           quoteShell(body) & " 2>&1", getHomeDir(), proc(j: Job) =
    ollamaPullJob = nil
    if "\"success\"" in j.output:
      info("Downloaded " & model)
      useOllamaModel(model)
    else:
      var why = ""
      for l in j.output.splitLines:
        if "\"error\"" in l:
          try: why = parseJson(l){"error"}.getStr
          except CatchableError: discard
      error("Could not download " & model & (if why.len > 0: ": " & why else: " (is Ollama running?)")))

proc ollamaPullTick() =
  ## the download's progress, from the last line Ollama sent
  if ollamaPullJob == nil or ollamaPullJob.done: return
  let o = ollamaPullJob.output & ollamaPullJob.partial
  let e = o.rfind('{')
  if e < 0: return
  try:
    let j = parseJson(o[e .. ^1].splitLines()[0])
    let total = j{"total"}.getBiggestInt(0)
    let done = j{"completed"}.getBiggestInt(0)
    let s = if total > 0: "Downloading " & ollamaPullModel & " — " & $(done * 100 div total) & "% of " &
                          formatFloat(total.float / 1e9, ffDecimal, 1) & " GB"
            else: "Downloading " & ollamaPullModel & " — " & j{"status"}.getStr
    if s != ollamaPullShown:
      ollamaPullShown = s
      setMsg(s, 3)
      needRender = true
  except CatchableError: discard

proc ollamaInstallCmd(): string =
  if isTermux(): "pkg install ollama"
  elif defined(macosx): "brew install ollama"
  else: "curl -fsSL https://ollama.com/install.sh | sh"

proc pullAct(model: string): Action =
  result = proc() = ollamaPull(model)
proc startPullAct(model: string): Action =
  result = proc() = ollamaStart(pullAct(model))
proc useAct(model: string): Action =
  result = proc() = useOllamaModel(model)

proc cmdAiOffline() =
  ## what is here (Ollama running? its models? llama.cpp's server?), and the way to a model on this device
  if not haveExe("curl"):
    error("curl is needed: " & installHint("curl", "curl"))
    return
  let mb = memTotalMB()
  let fit = localModelFits(mb)
  let probe = "curl -s --max-time 2 " & quoteShell(ollamaUrl() & "/api/tags") & "; echo; echo '<<ned>>'; " &
              "curl -s --max-time 2 http://127.0.0.1:8080/v1/models; echo"
  info("Looking for a local AI server…")
  discard startJob(jkTool, probe, getHomeDir(), proc(j: Job) =
    let parts = j.output.split("<<ned>>")
    var running = false
    var have: seq[(string, int64)]
    try:
      let t = parseJson(parts[0].strip)
      running = t{"models"} != nil
      for m in t{"models"}:
        have.add (m{"name"}.getStr, m{"size"}.getBiggestInt(0))
    except CatchableError: discard
    var llamaModel = ""
    if parts.len > 1:
      try:
        let t = parseJson(parts[1].strip)
        for m in t{"data"}:
          llamaModel = m{"id"}.getStr
          break
      except CatchableError: discard
    let installed = haveExe("ollama")
    var items: seq[(string, string, Action)]
    for (name, size) in have:
      items.add act("Use " & name, "downloaded · " & formatFloat(size.float / 1e9, ffDecimal, 1) & " GB" &
                    (if name == aiModel() and cfgAiProvider == "ollama": " · in use" else: ""), useAct(name))
    let (rec, recSize, _) = LocalModels[fit]
    var haveRec = false
    for (n, _) in have:
      if n == rec or n == rec & ":latest": haveRec = true
    if not installed and not running:
      let ic = ollamaInstallCmd()
      items.add act("Install Ollama", ic & " — then this menu again", proc() =
        runInTerm(ic)
        info("When it is installed: palette › AI: on this device, offline…"))
    elif not haveRec:
      let r = rec
      items.add act("Download and use " & rec, recSize & " — fits " & (if mb > 0: $(mb div 1024) & " GB of memory" else: "this device"),
                    proc() =
        if running: ollamaPull(r)
        else: ollamaStart(proc() = ollamaPull(r)))
    if installed or running:
      var more: seq[(string, string, Action)]
      for i, (n, size, need) in LocalModels:
        let note = size & " download · wants " & $(need div 1024) & " GB of memory" & (if i > fit: " (more than here)" else: "")
        more.add act(n, note, (if running: pullAct(n) else: startPullAct(n)))
      items.add act("Other models…", "smaller is faster; bigger answers better", proc() =
        openActions("Models for this device", more))
    if installed and not running:
      items.add act("Start Ollama", "it keeps running in the background", proc() =
        ollamaStart(proc() = cmdAiOffline()))
    if llamaModel.len > 0:
      let lm = llamaModel
      items.add act("Use llama.cpp's server", lm & " · 127.0.0.1:8080", proc() =
        setSetting("ai.provider", %"custom")
        setSetting("ai.baseUrl", %"http://127.0.0.1:8080/v1")
        setSetting("ai.model", %lm)
        info("AI: llama.cpp's server (" & lm & ") on this device"))
    let state = if running: "Ollama is running" elif installed: "Ollama is installed, not running" else: "no Ollama yet"
    openActions("AI on this device — " & (if mb > 0: $(mb div 1024) & " GB memory · " else: "") & state, items))
