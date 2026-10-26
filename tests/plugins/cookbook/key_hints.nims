## leader-hints — keys that wait (which-key): when the space bar (vim's leader) has waited a moment for the next
## key, a box of the plugins' <leader> mappings and what they do; tap one to type it
import nedplugin

requiresNed(">= 6.31")

onKeysWaiting(400) do (keys, mode: string):
  # keys as vim writes them: "<leader>", "<leader>g" …; mode "n" is vim's normal mode
  if mode != "n" or not keys.startsWith("<leader>"): return
  var hints: seq[(string, string)]
  for m in keyMaps():                         # every plugin's mapping, with what it does
    let k = m.keys.replace("<Leader>", "<leader>")
    if m.mode == "n" and k.startsWith(keys) and k.len > keys.len:
      hints.add (k[keys.len .. ^1], (if m.desc.len > 0: m.desc else: m.plugin & "'s"))
  if hints.len > 0:
    # the box shows until the keys waiting change; false when they changed already
    discard showKeyHints(keys, hints)

command "Leader hints: what waits now":
  let (keys, mode) = pendingKeys()            # ("", "") here: the palette was open, nothing waits
  message(if keys.len == 0: "No keys wait" else: keys & " waits (" & mode & ")")
