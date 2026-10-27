# ════════════════════════════════════════════════════════════════════════════
#  Messages
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

proc info(s: string) = setMsg(s, 0)
proc warn(s: string) = setMsg(s, 2)
proc error(s: string) = setMsg(s, 1)
