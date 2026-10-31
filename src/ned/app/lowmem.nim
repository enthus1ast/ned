# ── (6.37) short of memory (ui.lowMemory): when the system has little left to give — on a phone, Android then closes
#    apps, Termux among them, with ned and its terminal — ned keeps light: what its caches hold goes (the engine's,
#    its worker's, the compiler's reading), checks run one at a time and on save only, nothing is read ahead in the
#    background, and the status bar says so. When memory comes back (twice the limit), all of it does too ──

var
  lowMemAt: MonoTime
  lowMemKnown = false

proc lowMemShed() =
  ## what can be worked out again goes: the engine's caches (what each file sees but the file in front's, what routines
  ## raise, headers, the compiler's reading of files), the engine worker's the same
  let keep = if bufs.len > 0: buf().path else: ""
  nxShed(keep)
  nifFactsMemo.clear(); nifDeclMemo.clear(); nifTyping.clear()
  diagsMemo.clear()
  if wkOn(): wkSend(%*{"op": "shed", "keep": keep})

proc lowMemPump() =
  ## (the main loop, every 5 s) is the system short of memory? MemAvailable under ui.lowMemory MB: light from then on,
  ## until it is back over twice that
  if lowMemKnown and msSince(lowMemAt) < 5000: return
  lowMemAt = getMonoTime()
  lowMemKnown = true
  let limit = sInt("ui.lowMemory")
  let avail = memAvailableMB()
  if limit <= 0 or avail < 0:
    lowMemory = false
    return
  if not lowMemory and avail < limit:
    lowMemory = true
    lowMemShed()
    warn("Little memory left (" & $avail & " MB): ned keeps light — checks one at a time and on save, " &
         "nothing read ahead (ui.lowMemory)")
    needRender = true
  elif lowMemory and avail > 2 * limit:
    lowMemory = false
    info("Memory back (" & $avail & " MB free): checks while you type again")
    needRender = true
