# ════════════════════════════════════════════════════════════════════════════
#  Clipboard (internal + OSC 52 + Termux:API / wl-clipboard / xclip)
# ════════════════════════════════════════════════════════════════════════════

var wslState = -1

proc isWsl(): bool =
  ## Linux under Windows (WSL): the Windows clipboard and browser are reached through Windows programs
  if wslState < 0:
    wslState = 0
    if getEnv("WSL_DISTRO_NAME").len > 0: wslState = 1
    else:
      try:
        if "microsoft" in readFile("/proc/sys/kernel/osrelease").toLowerAscii: wslState = 1
      except CatchableError: discard
  wslState == 1

const WslPaste = "powershell.exe -NoProfile -NonInteractive -Command " &
                 "\"[Console]::OutputEncoding=[Text.Encoding]::UTF8; [Console]::Out.Write((Get-Clipboard -Raw))\""

proc clipSet(text: string) =
  ## OSC 52 asks the terminal to copy (Windows Terminal, iTerm2, kitty, WezTerm, Termux …); a helper as well when there is one
  if text.len < 200_000:
    writeAll("\e]52;c;" & base64.encode(text) & "\a")
  var cmd = ""
  if findExe("termux-clipboard-set").len > 0: cmd = "termux-clipboard-set"
  elif findExe("pbcopy").len > 0: cmd = "LC_CTYPE=UTF-8 pbcopy"                # macOS
  elif getEnv("WAYLAND_DISPLAY").len > 0 and findExe("wl-copy").len > 0: cmd = "wl-copy"
  elif getEnv("DISPLAY").len > 0 and findExe("xclip").len > 0: cmd = "xclip -selection clipboard"
  elif isWsl() and findExe("powershell.exe").len > 0:
    # the Windows clipboard, for consoles without OSC 52 and for big copies
    cmd = "powershell.exe -NoProfile -NonInteractive -Command " &
          "\"[Console]::InputEncoding=[Text.Encoding]::UTF8; Set-Clipboard -Value ([Console]::In.ReadToEnd())\""
  if cmd.len > 0:
    let f = privTmp("clip")
    try:
      writeFile(f, text)
      discard startJob(jkAux, cmd & " < " & quoteShell(f), rootDir, proc(j: Job) =
        try: removeFile(f)
        except CatchableError: discard)
    except CatchableError: discard

proc clipGet(): string =
  if sysClipBroken: return ""
  var cmd = ""
  var wait = 1500
  if findExe("termux-clipboard-get").len > 0: cmd = "termux-clipboard-get"
  elif findExe("pbpaste").len > 0: cmd = "LC_CTYPE=UTF-8 pbpaste"               # macOS
  elif getEnv("WAYLAND_DISPLAY").len > 0 and findExe("wl-paste").len > 0: cmd = "wl-paste -n"
  elif getEnv("DISPLAY").len > 0 and findExe("xclip").len > 0: cmd = "xclip -selection clipboard -o"
  elif isWsl() and findExe("powershell.exe").len > 0:
    cmd = WslPaste                                                              # the Windows clipboard
    wait = 5000                                                                 # PowerShell starts slowly
  if cmd.len == 0: return ""
  let (ok, o, e) = runFilter(cmd, "", rootDir, wait)
  if not ok and e == "timed out":
    sysClipBroken = true
    warn(if cmd.startsWith("termux"): "System clipboard unavailable (is the Termux:API app installed?)"
         else: "System clipboard unavailable (" & cmd.split(' ')[0] & " did not answer)")
    return ""
  if ok: o.replace("\r\n", "\n") else: ""

proc copySel(cut: bool) =
  let b = buf()
  var lineMode = true
  for c in b.cursors:
    if c.hasSel: lineMode = false
  var parts: seq[string]
  if lineMode:
    var seen: HashSet[int]
    for c in b.cursors:
      if c.head.line notin seen:
        seen.incl c.head.line
        parts.add b.lines[c.head.line] & "\n"
  else:
    for c in b.cursors:
      if c.hasSel: parts.add b.getText(c.range[0], c.range[1])
  clipParts = parts
  clipLineMode = lineMode
  let text = if lineMode: parts.join("") else: parts.join("\n")
  clipSet(text)
  if cut and b.canEdit():
    if lineMode: b.deleteLines()
    else:
      b.beginEdit()
      for i in countdown(b.cursors.high, 0):
        let (a, e) = b.cursors[i].range
        b.cursors[i] = cur(b.replaceText(a, e, ""))
      b.endEdit()
      b.normalize()
  let n = text.count('\n') + (if lineMode: 0 else: 1)
  info((if cut: "Cut " else: "Copied ") & (if lineMode: $parts.len & " line(s)" else: $text.len & " chars" &
       (if n > 1: " / " & $n & " lines" else: "")))

proc paste() =
  let b = buf()
  if not b.canEdit(): return
  var text = if clipLineMode: clipParts.join("") else: clipParts.join("\n")
  let sys = clipGet()
  if sys.len > 0 and sys != text:
    text = sys
    clipParts = @[sys]
    clipLineMode = false
  if text.len == 0:
    info("Clipboard is empty")
    return
  var allEmpty = true
  for c in b.cursors:
    if c.hasSel: allEmpty = false
  if clipLineMode and allEmpty:
    b.beginEdit()
    for i in countdown(b.cursors.high, 0):
      let l = b.cursors[i].head.line
      let part = if clipParts.len == b.cursors.len: clipParts[i] else: text
      discard b.replaceText(Pos(line: l, col: 0), Pos(line: l, col: 0), part)
    b.endEdit()
    b.normalize()
  else:
    b.insertText(text)
