## read-aloud — the selection, the line or the whole file read out loud (Termux:API, espeak, spd-say or say)
##
##   Read aloud: the selection   the selection — or, with none, the line the cursor is on
##   Read aloud: the file        the file from the cursor on (at most maxChars characters)
##   Read aloud: stop            stops reading
##   settings                    plugins.read-aloud.command — the program ("": the first of termux-tts-speak,
##                               espeak-ng, espeak, spd-say, say that is installed) · .rate (1.0: as fast as the
##                               program speaks; 2.0 twice as fast) · .maxChars (4000) · .plain (true): code read
##                               as words — symbols, underscores and camelCase said apart
##
## On Android: the Termux:API app and `pkg install termux-api` (termux-tts-speak uses the phone's own voice). On
## Linux: espeak-ng or speech-dispatcher; on a Mac, say is there already.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "reads the text out with termux-tts-speak, espeak-ng, espeak, spd-say or say")

settingDef("command", "", "Read aloud: the program that speaks (empty: the first installed of termux-tts-speak, " &
           "espeak-ng, espeak, spd-say, say)")
settingDef("rate", 1.0, "Read aloud: how fast (1.0 as the program speaks, 2.0 twice as fast)")
settingDef("maxChars", 4000, "Read aloud: the most characters read at once")
settingDef("plain", true, "Read aloud: code read as words — symbols, underscores and camelCase said apart")

const Speakers = ["termux-tts-speak", "espeak-ng", "espeak", "spd-say", "say"]

proc speaker(): string =
  ## the program that speaks: the setting's, else the first one installed ("" none)
  let own = setting("command", "").strip
  if own.len > 0: return own
  let (o, _) = shell("for t in " & Speakers.join(" ") & "; do command -v $t >/dev/null 2>&1 && { echo $t; break; }; done")
  o.strip

func plainWords*(s: string): string =
  ## code made sayable: camelCase and snake_case apart, brackets and symbols as pauses, runs of spaces as one
  var prev = ' '
  for c in s:
    if c in {'A'..'Z'} and prev in {'a'..'z'}: result.add ' '
    case c
    of '_', '(', ')', '[', ']', '{', '}', '<', '>', '`', '"', '\'', '#', '*', '|', '\\', '/', '=', ';', '~', '^', '@', '$':
      if result.len > 0 and result[^1] != ' ': result.add ' '
    of '\n', '\r', '\t':
      if result.len > 0 and result[^1] notin {' ', '.'}: result.add ". "
    else: result.add c
    prev = c
  var one = ""
  for c in result:
    if c == ' ' and one.len > 0 and one[^1] == ' ': continue
    one.add c
  one.strip

proc commandFor(prog, file: string, rate: float): string =
  ## how the program reads the file: each takes its text and its speed its own way
  let f = quoteShell(file)
  let r = max(0.25, min(4.0, rate))
  case prog
  of "termux-tts-speak": "termux-tts-speak -r " & formatFloat(r, ffDecimal, 2) & " < " & f
  of "espeak-ng", "espeak": prog & " -s " & $int(175 * r) & " -f " & f
  of "spd-say": "spd-say -w -r " & $int(max(-100.0, min(100.0, (r - 1) * 100))) & " -e < " & f
  of "say": "say -r " & $int(180 * r) & " -f " & f
  else: prog & " < " & f

proc speak(text0: string) =
  ## the text read out in the background — any reading still going stopped first
  var text = text0
  if setting("plain", true): text = plainWords(text)
  let mx = setting("maxChars", 4000)
  if text.len > mx: text = text[0 ..< mx]
  if text.strip.len == 0:
    message("Read aloud: nothing to read there")
    return
  let prog = speaker()
  if prog.len == 0:
    warn("Read aloud: no program to speak with — Termux: pkg install termux-api (and the Termux:API app); " &
         "Linux: espeak-ng; or set plugins.read-aloud.command")
    return
  writeData("speak.txt", text)
  let pidFile = dataDir() / "speaking.pid"
  discard shell("[ -f " & quoteShell(pidFile) & " ] && kill $(cat " & quoteShell(pidFile) & ") 2>/dev/null; rm -f " &
                quoteShell(pidFile))
  let cmd = commandFor(prog, dataDir() / "speak.txt", setting("rate", 1.0))
  # (in a shell of its own whose number is kept, so that stop can end it)
  shellAsync("sh -c " & quoteShell("echo $$ > " & quoteShell(pidFile) & "; exec " & cmd) & "; rm -f " &
             quoteShell(pidFile)) do (output: string, code: int):
    if code != 0 and code != 143 and output.strip.len > 0: warn("Read aloud: " & output.strip.splitLines[^1])
  message("🔊 Reading " & $text.len & " characters with " & prog & " (Read aloud: stop)")

command "Read aloud: the selection":
  let b = current()
  let r = b.selection
  speak(if r.isEmpty: b.line(b.cursor.line) else: b.textIn(r))

command "Read aloud: the file":
  let b = current()
  let c = b.cursor
  let ls = b.lines(c.line, -1)
  var t = ""
  for i, l in ls:
    t.add (if i == 0: l[min(c.col, l.len) .. ^1] else: l) & "\n"
    if t.len > setting("maxChars", 4000): break
  speak(t)

command "Read aloud: stop":
  let pidFile = dataDir() / "speaking.pid"
  let (_, code) = shell("[ -f " & quoteShell(pidFile) & " ] && kill $(cat " & quoteShell(pidFile) & ") 2>/dev/null")
  discard shell("rm -f " & quoteShell(pidFile))
  message(if code == 0: "Read aloud: stopped" else: "Read aloud: nothing is being read")
