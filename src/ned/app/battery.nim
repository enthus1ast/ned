# ── (6.32) battery saver (ui.batterySaver): on a battery, ned does less — no cursor glide, the compiler checks
#    on save rather than while you type, no AI completion as you type, fewer wake-ups while you are not typing.
#    "auto" asks the system (Linux and Android: /sys/class/power_supply) once a minute ──

var
  batteryAt: MonoTime
  batteryKnown = false

proc onBattery(): bool =
  ## is the device running on its battery: a battery discharging, no mains supply online
  var discharging, mains = false
  try:
    for k, d in walkDir("/sys/class/power_supply"):
      let typ = (try: readFile(d / "type").strip except CatchableError: "")
      if typ == "Battery":
        let st = (try: readFile(d / "status").strip except CatchableError: "")
        if st == "Discharging": discharging = true
      elif typ in ["Mains", "USB", "USB_C", "USB_PD"]:
        if (try: readFile(d / "online").strip except CatchableError: "") == "1": mains = true
  except OSError: discard
  discharging and not mains

proc batteryPump() =
  ## (the main loop) whether to save the battery now
  if batteryKnown and msSince(batteryAt) < 60_000: return
  batteryAt = getMonoTime()
  batteryKnown = true
  let was = batterySave
  batterySave = case sStr("ui.batterySaver")
                of "on": true
                of "off": false
                else: onBattery()
  if was != batterySave: needRender = true

proc batteryToggle() =
  ## (the leaf in the status bar) on ⇄ off
  setSetting("ui.batterySaver", %(if batterySave: "off" else: "on"))
  batteryKnown = false
  batteryPump()
  info(if batterySave: "Battery saver on — no cursor glide, the compiler checks on save, fewer wake-ups"
       else: "Battery saver off")
