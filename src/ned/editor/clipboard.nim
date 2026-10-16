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

proc pasteLayout(b: Buffer, text: string, at: Pos, lineMode = false): string =
  ## pasted lines of code take the indentation of where they go (editor.formatOnPaste): the first line sits where
  ## the cursor is, the others keep their indentation relative to it. Pasting at column 0 — or lines inside a
  ## """string""" — stays exactly as copied
  result = text
  if cfgPasteFmt == "off" or b.cursors.len != 1 or '\n' notin text or text.len > 500_000: return
  if b.lang == nil or b.lang.mode in {lmPlain, lmMarkdown, lmDiff, lmMake}: return
  let w = b.indentW()
  proc cols(s: string): int =
    for ch in s:
      if ch == ' ': inc result
      elif ch == '\t': result = (result div w + 1) * w
      else: break
  var ls = text.split('\n')
  let line = b.lines[at.line]
  let before = line[0 ..< min(at.col, line.len)]
  # the copied lines: where the first one stood — its own indentation, or (copied from the middle of a line)
  # guessed from the lines under it
  var minRest, firstRest = -1
  for k in 1 ..< ls.len:
    if ls[k].strip.len > 0:
      let c = cols(ls[k])
      if minRest < 0 or c < minRest: minRest = c
      if firstRest < 0: firstRest = c
  if minRest < 0: return                        # one line of code
  let t0 = ls[0].strip
  let firstWs = ls[0].len > 0 and ls[0][0] in {' ', '\t'}
  let srcFirst =
    if t0.len == 0: firstRest
    elif lineMode or firstWs: cols(ls[0])
    elif t0[^1] in {':', '=', '(', '[', '{'} or t0.endsWith(" do") or t0.endsWith("->"): max(0, firstRest - w)
    else: minRest
  # where they go
  var target: int
  var stripFirst = false
  if lineMode:
    if line.strip.len == 0: return
    target = cols(line)
    stripFirst = true
  elif before.len == 0: return                  # (column 0: as copied)
  elif before.strip.len == 0:
    target = cols(before)
    stripFirst = true
  else: target = cols(line)
  proc indentStr(n: int): string =
    if b.indent == "\t": repeat('\t', n div w) & spaces(n mod w) else: spaces(n)
  var inString = false
  var outp: seq[string]
  for k, l in ls:
    let lead = leadingWs(l)
    if inString: outp.add l
    elif k == 0:
      outp.add (if stripFirst and t0.len > 0: indentStr(max(0, cols(l) - srcFirst)) & l[lead.len .. ^1]
                elif stripFirst: "" else: l)
    elif l.strip.len == 0: outp.add ""
    else: outp.add indentStr(max(0, target + cols(l) - srcFirst)) & l[lead.len .. ^1]
    if l.count("\"\"\"") mod 2 == 1: inString = not inString
  result = outp.join("\n")
  if lineMode and stripFirst: result = indentStr(target) & result.strip(trailing = false, chars = {' ', '\t'})

proc pasteFinish(b: Buffer, l0: int) =
  ## editor.formatOnPaste "format": the pasted Nim lines formatted too (built-in formatter; quietly left alone
  ## when they are not complete statements)
  if cfgPasteFmt != "format" or b.lang == nil or b.lang.mode != lmNim or cfgNimFormatter != "builtin": return
  let l1 = b.primary.head.line
  if l1 > l0 and l0 >= 0 and l1 < b.lines.len:
    let last = if b.lines[l1].strip.len == 0 or b.primary.head.col == 0: l1 - 1 else: l1
    if last > l0: discard b.formatLineRange(l0, last, quiet = true)

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
  let l0 = b.primary.range[0].line
  if clipLineMode and allEmpty:
    b.beginEdit()
    for i in countdown(b.cursors.high, 0):
      let l = b.cursors[i].head.line
      let part = if clipParts.len == b.cursors.len: clipParts[i]
                 else: b.pasteLayout(text, Pos(line: l, col: 0), lineMode = true)
      discard b.replaceText(Pos(line: l, col: 0), Pos(line: l, col: 0), part)
    b.endEdit()
    b.normalize()
  else:
    b.insertText(b.pasteLayout(text, b.primary.range[0]))
    b.pasteFinish(l0)
