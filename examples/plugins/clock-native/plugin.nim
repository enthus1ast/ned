## clock-native — a plugin in full Nim (its file is plugin.nim, not plugin.nims): ned compiles it with nim c (in the
## background, again when it changes) into a program of its own, run beside the editor. It can use the whole
## standard library — std/times here (NimScript has no clock), osproc, threads, sockets … — and a slow call of its
## never holds up the other plugins.
##
## Copy this folder to ~/.config/ned/plugins/ (or Plugins dock › + › an example).
import nedplugin
import std/times

requiresNed(">= 6.20")

settingDef("format", "HH:mm", "The status-bar clock's format (std/times: HH:mm:ss, ddd HH:mm …)")

let started = now()

discard every(1000) do ():
  status("⏱ " & now().format(setting("format", "HH:mm")))

command "Clock: how long has ned been open":
  let d = now() - started
  message("ned has been open for " & $d.inMinutes & " min " & $(d.inSeconds mod 60) & " s")

command "Clock: insert the date":
  let b = current()
  b.insert(b.cursor, now().format("yyyy-MM-dd"))
