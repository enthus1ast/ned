# ════════════════════════════════════════════════════════════════════════════
#  The status line's messages: info, warnings and errors (a long one in a popup)
# ════════════════════════════════════════════════════════════════════════════

proc popupMsg(s: string, sev: int)

const MsgMax = 4000            # (a message longer than this — a plugin's or a script's — is cut: it is drawn every frame)

proc capMsg(s: string): string =
  ## `s`, cut to MsgMax bytes at a character's start, with "…" when it was longer
  if s.len <= MsgMax: return s
  var cut = MsgMax
  while cut > 0 and (s[cut].uint8 and 0xC0) == 0x80: dec cut
  s[0 ..< cut] & "…"

proc setMsg(s: string, sev = 0) =
  ## shows a message in the message line (severity 0 information, 1 error, 2 warning), after cutting it with capMsg; it
  ## is kept in the log of the last 100 messages. When the messages setting is "popup" (and toasts are on) it appears as
  ## a popup instead and the message line is cleared
  let s = capMsg(s)
  if s.len > 0:
    msgLog.add (times.now().format("HH:mm:ss"), sev, s)
    if msgLog.len > 100: msgLog.delete(0)
  if cfgMessages == "popup" and cfgToasts and s.len > 0:
    popupMsg(s, sev)
    msg = ""
    needRender = true
    return
  msg = s
  msgSev = sev
  msgTime = getMonoTime()
  needRender = true

# shows an information message
proc info(s: string) = setMsg(s, 0)
# shows a warning
proc warn(s: string) = setMsg(s, 2)
# shows an error
proc error(s: string) = setMsg(s, 1)
