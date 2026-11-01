## notify-done — tells you when a long run, build or test has ended: a note, and on a phone a notification and a buzz
##
##   when one ends       a run, build, test or nimble task (what the Output panel shows) that took minSeconds or
##                       longer: a note in the corner — ✓ done in 42 s, or ✗ failed (exit code 1) after 3 min —, and
##                       a notification of the system's: Termux:API's termux-notification on a phone (and, when it
##                       failed, a buzz: termux-vibrate), notify-send on a Linux desktop, osascript on a Mac
##   Notify: test it     a note and a notification now, to see that they reach you
##   settings            plugins.notify-done.minSeconds (20) · .system (true): the system's notification too ·
##                       .vibrate (true)
##
## On Android: install the Termux:API app, then `pkg install termux-api`. While ned is in the background the
## notification is how you hear of it.
import nedplugin

requiresNed(">= 6.39")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "sends the notification with termux-notification, notify-send or osascript, and the buzz with " &
           "termux-vibrate")

settingDef("minSeconds", 20, "Notify: tell me about runs, builds and tests that take at least this many seconds")
settingDef("system", true, "Notify: a notification of the system's too (Termux:API, notify-send, osascript)")
settingDef("vibrate", true, "Notify: buzz the phone when one fails (Termux:API's termux-vibrate)")

var tools = ""                  # (the notifiers installed, looked for once: their names, a space between)

func took*(s: float): string =
  ## a time as people say it: 42 s, 3 min 5 s, 1 h 2 min
  let n = int(s + 0.5)
  if n < 60: $n & " s"
  elif n < 3600: $(n div 60) & " min" & (if n mod 60 > 0: " " & $(n mod 60) & " s" else: "")
  else: $(n div 3600) & " h" & (if (n mod 3600) div 60 > 0: " " & $((n mod 3600) div 60) & " min" else: "")

func short(cmd: string): string =
  ## the command, cut to a length a notification shows
  let c = cmd.strip
  if c.len <= 60: c else: c[0 ..< 59] & "…"

proc findTools(): string =
  ## which of the notifiers are installed (looked for once)
  if tools.len == 0:
    let (o, _) = shell("for t in termux-notification termux-vibrate notify-send osascript; do " &
                       "command -v $t >/dev/null 2>&1 && printf '%s ' $t; done; printf .")
    tools = o
  tools

proc systemNote(title, text: string, failed: bool): string =
  ## the system's notification (and the buzz when it failed); what was used, "" for none
  if not setting("system", true) or not allowed("shell"): return ""
  let t = findTools()
  # (what the notifier says back: nothing to do with it)
  proc nothing(output: string, code: int) = discard
  if "termux-notification" in t:
    shellAsync("termux-notification --id ned-notify-done --title " & quoteShell(title) & " --content " &
               quoteShell(text), nothing)
    if failed and setting("vibrate", true) and "termux-vibrate" in t:
      shellAsync("termux-vibrate -d 400", nothing)
    return "termux-notification"
  if "notify-send" in t:
    shellAsync("notify-send " & (if failed: "-u critical " else: "") & quoteShell(title) & " " & quoteShell(text), nothing)
    return "notify-send"
  if "osascript" in t:
    shellAsync("osascript -e " & quoteShell("display notification " & escapeJson(text) & " with title " &
               escapeJson(title)), nothing)
    return "osascript"
  ""

onJobDone do (job: JobEnd):
  if job.seconds < float(setting("minSeconds", 20)): return
  let ok = job.code == 0
  let text = (if ok: "✓ " & short(job.title) & " — done in " & took(job.seconds)
              else: "✗ " & short(job.title) & " — failed (exit code " & $job.code & ") after " & took(job.seconds))
  toast(text)
  discard systemNote(if ok: "ned: done" else: "ned: failed", text, not ok)

command "Notify: test it":
  toast("notify-done: this is how a note looks")
  let how = systemNote("ned", "notify-done: this is how a notification looks", false)
  message(if how.len > 0: "Notify: a note, and a notification through " & how
          elif not setting("system", true): "Notify: a note (the system's notifications are off: plugins.notify-done.system)"
          else: "Notify: a note only — no notifier found (Termux: pkg install termux-api, and the Termux:API app)")
