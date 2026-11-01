## power-mode — typing with sparks: a combo count in the status bar, sparks after the line you type, a cheer at 50
##
##   Power mode: on/off    the sparks on, or off (off when ned starts, unless plugins.power-mode.onAtStart)
##   while on              ⚡ combo 37 in the status bar while you keep typing — it ends after three seconds
##                         without; sparks ✦ ✧ ⋆ after the line you are typing, gone a moment later; a cheer in the
##                         corner at 50, 100, 250, 500 and every 500 after, and the best combo kept
##   settings              plugins.power-mode.onAtStart (false) · .sparks (true): the sparks after the line
##
## ned tells a plugin about typing after a short pause, not at each key: the sparks come in small bursts.
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("onAtStart", false, "Power mode: on when ned starts")
settingDef("sparks", true, "Power mode: sparks after the line you type (off: the combo alone)")

const
  Sparks = ["✦", "✧", "⋆", "∗", "✶", "✷", "⁂", "✺"]
  Colours = ["accent", "warn", "error", "add", "info"]
  Cheers = ["Nice!", "On fire!", "Unstoppable!", "Legendary!", "Keyboard wizard!"]
  EndAfter = 3.0                # seconds without typing end the combo

var
  on = false
  combo = 0
  best = 0
  lastAt = 0.0
  ticker = -1                   # the timer that ends a combo
  sparked: seq[int]             # the files with sparks to clear
  clearer = -1                  # the timer that clears them
  seed = 0
  lastLen: seq[(int, int, int)] # (file, cursor line, its length) when last seen

proc rnd(n: int): int =
  ## a number from 0 to n - 1, more or less at random (NimScript has no random of its own)
  if seed == 0: seed = int(unixTime() * 1000) mod 2147483647 + 1
  seed = (seed * 1103515245 + 12345) mod 2147483648
  (seed shr 8) mod max(1, n)

func nextMark(c: int): int =
  ## the combo after `c` that earns a cheer: 50, 100, 250, 500, then every 500
  if c < 50: 50
  elif c < 100: 100
  elif c < 250: 250
  else: (c div 500 + 1) * 500

proc clearSparks() =
  ## the sparks go
  for id in sparked:
    try: Buf(id: id).clearDecorations()
    except CatchableError: discard          # (its tab closed meanwhile)
  sparked.setLen(0)
  if clearer >= 0: stopTimer(clearer)
  clearer = -1

proc show() =
  ## the combo in the status bar (none: nothing)
  status(if on and combo > 0: "⚡ combo " & $combo else: "")

proc tick() =
  ## (every half second while on) the combo ends after a pause
  if combo > 0 and unixTime() - lastAt > EndAfter:
    if combo > best:
      best = combo
      writeData("best.txt", $best)
    combo = 0
    show()

proc turn(state: bool) =
  ## power mode on or off
  on = state
  if on:
    if ticker < 0: ticker = every(500) do (): tick()
    try: best = parseInt(readData("best.txt").strip)
    except ValueError: best = 0
  else:
    if ticker >= 0: stopTimer(ticker)
    ticker = -1
    combo = 0
    clearSparks()
  show()

proc typedIn(b: Buf): int =
  ## the characters the cursor's line grew by since the last time (0 when it is another line, or shorter)
  let c = b.cursor
  let l = b.line(c.line).len
  for i, (id, line, n) in lastLen:
    if id == b.id:
      lastLen[i] = (b.id, c.line, l)
      return (if line == c.line: max(0, l - n) elif c.line == line + 1: 1 else: 0)
  lastLen.add (b.id, c.line, l)
  if lastLen.len > 16: lastLen.delete(0)
  0

onStartup do (ev: Event):
  if setting("onAtStart", false): turn(true)

onChange("*") do (ev: Event):
  if not on: return
  let b = ev.buf
  let n = typedIn(b)
  if n <= 0 or n > 200: return               # (nothing typed, or a paste)
  let before = combo
  combo += n
  lastAt = unixTime()
  if combo >= nextMark(before):
    let m = nextMark(before)
    toast("⚡ " & $m & " combo — " & Cheers[min(Cheers.high, (if m <= 50: 0 elif m <= 100: 1 elif m <= 250: 2
                                                              elif m <= 500: 3 else: 4))])
  if setting("sparks", true):
    var s = ""
    for i in 0 ..< min(6, max(2, n div 3)): s.add Sparks[rnd(Sparks.len)] & " "
    b.virtualText(b.cursor.line, s.strip, Colours[rnd(Colours.len)])
    if b.id notin sparked: sparked.add b.id
    if clearer >= 0: stopTimer(clearer)
    clearer = after(900) do (): clearSparks()
  show()

command "Power mode: on/off":
  turn(not on)
  message(if on: "⚡ Power mode on — type!" & (if best > 0: " (best combo: " & $best & ")" else: "")
          else: "Power mode off")
