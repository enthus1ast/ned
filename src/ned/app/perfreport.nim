# ── Help › Performance: how fast frames are made, how much each sends to the terminal and how long the terminal
#    takes to draw it, what runs in the background, the memory — and what to change when something is slow ──

proc perfReport(): string =
  var buildSum, writeSum, bytesSum, buildMax, writeMax, bytesMax, scrolled = 0
  for f in frameStats:
    buildSum += f.buildUs
    writeSum += f.writeUs
    bytesSum += f.bytes
    buildMax = max(buildMax, f.buildUs)
    writeMax = max(writeMax, f.writeUs)
    bytesMax = max(bytesMax, f.bytes)
    if f.scrolled: inc scrolled
  let n = max(1, frameStats.len)
  func ms(us: int): string = formatFloat(float(us) / 1000.0, ffDecimal, 2) & " ms"
  result = "ned " & Version & " — performance\n" & "=".repeat(30) & "\n\n"
  result.add "Frames (the last " & $frameStats.len & ")\n"
  result.add "  made in        " & ms(buildSum div n) & " on average, " & ms(buildMax) & " at most\n"
  result.add "  sent           " & $(bytesSum div n) & " bytes on average, " & $bytesMax & " at most\n"
  result.add "  terminal took  " & ms(writeSum div n) & " on average, " & ms(writeMax) & " at most\n"
  result.add "  scrolled by the terminal (only the new lines sent): " & $scrolled & " of them" &
             (if not cfgTermScroll: " — ui.terminalScroll is off" else: "") & "\n"
  let (kbs, kn) = termSpeed()
  result.add "  terminal speed " & (if kbs < 0: "not measured yet (scroll a little first)"
                                    else: $kbs & " KB/s, from " & $kn & " frames") &
             (if slowTerminal(): " — slow: frames are kept light (no minimap)" else: "") & "\n"
  result.add "  since ned started: " & $framesTotal & " frames, " & $(frameBytesTotal div 1024) & " KB\n\n"
  var recent, recentMax = 0
  for (at, us) in busyRecent:
    if msSince(at) < 60_000:
      inc recent
      recentMax = max(recentMax, us)
  result.add "Answering keys and the mouse\n"
  result.add "  rounds of work over 50 ms (ned not reading input meanwhile): " & $recent & " in the last minute" &
             (if recent > 0: ", the longest " & ms(recentMax) else: "") & "; " & $busyOver50 & " since it started\n"
  result.add "  the longest round since it started: " & ms(busyMaxUs) & "\n"
  var byName: Table[string, (int, int)]
  for (at, what, us) in slowWork:
    if msSince(at) < 60_000:
      let (n, mx) = byName.getOrDefault(what, (0, 0))
      byName[what] = (n + 1, max(mx, us))
  if byName.len > 0:
    result.add "  what took over 30 ms in the last minute:\n"
    var rows: seq[(int, string, int)]
    for what, (n, mx) in byName: rows.add (mx, what, n)
    rows.sort(proc(a, b: (int, string, int)): int = cmp(b[0], a[0]))
    for (mx, what, n) in rows: result.add "    " & what & " — " & $n & "×, the longest " & ms(mx) & "\n"
  result.add "\n"
  result.add "Engine (the Nim file in front)\n"
  result.add "  type and parameter hints: " & (if lastInlayMs >= 0: $lastInlayMs & " ms for the last window" else: "-") & "\n"
  result.add "  its own checks:           " & (if lastChecksMs >= 0: $lastChecksMs & " ms the last time" else: "-") & "\n"
  result.add "  index: " & $(nxFilesBytes div 1048576) & " MB of parsed files (nim.indexMemory: " &
             $(nxIndexBudget div 1048576) & " MB)\n\n"
  result.add "Memory: ned " & $procRssMB(getpid().int) & " MB\n\n"
  result.add "Running in the background\n"
  var any = false
  for j in jobs:
    if j.done: continue
    any = true
    let c = if j.cmd.len > 90: j.cmd[0 ..< 89] & "…" else: j.cmd
    result.add "  " & $j.kind & "  " & $(msSince(j.started) div 1000) & " s  " & c & "\n"
  for s in servers:
    if s.dead: continue
    any = true
    result.add "  language server " & s.langId & (if s.ready: "" else: " (starting)") & " — " &
               $procRssMB(s.pr.pid.int) & " MB\n"
  for s in nimSugs:
    if s.dead: continue
    any = true
    result.add "  nimsuggest — " & $procRssMB(s.pr.pid.int) & " MB\n"
  if not any: result.add "  nothing\n"
  result.add "\nWhat makes it lighter (Settings)\n"
  var tips: seq[string]
  if bytesSum div n > 8000 or slowTerminal():
    tips.add "the terminal draws a lot each frame: \"ui.minimap\": \"off\", \"editor.stickyScroll\": false"
  if not cfgTermScroll: tips.add "\"ui.terminalScroll\": true — scrolling sends only the new lines"
  if buildSum div n > 8000:
    tips.add "frames are slow to make: \"editor.inlayHints\": false or \"nim.parameterHints\": \"off\", " &
             "\"nim.referenceCounts\": false, \"editor.semanticColors\": false"
  if lastChecksMs > 300: tips.add "the engine's checks are slow here: \"nim.engineHints\": false (hints such as can-be-func)"
  if cfgRaisesHints and lastInlayMs > 200: tips.add "exception hints cost the most here: View › Editor › Exception hints"
  if tips.len == 0: tips.add "nothing stands out"
  for t in tips: result.add "  · " & t & "\n"
  result.add "\n(ned --bench FILE measures the same without a terminal: ms and bytes per frame)\n"

proc cmdPerfReport() =
  discard openScratch("Performance", perfReport(), langByName("Text"))
