# ════════════════════════════════════════════════════════════════════════════
#  Messages
# ════════════════════════════════════════════════════════════════════════════

proc popupMsg(s: string, sev: int)

proc setMsg(s: string, sev = 0) =
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
