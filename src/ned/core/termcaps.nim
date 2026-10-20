# ════════════════════════════════════════════════════════════════════════════
#  What the terminal can do: asked of it when raw mode starts, never assumed from its name alone. The answers come
#  back among the keys (parseKey hands them here):
#    · the kitty keyboard protocol (CSI ? u): Ctrl+Shift+letters, Ctrl+I apart from Tab, Ctrl+Enter, Alt without a
#      delay — turned on when the terminal answers, off again when ned leaves
#    · grapheme clusters (DEC mode 2027): an emoji sequence is one character, two columns wide
#    · light or dark (mode 2031): told again whenever the terminal or the system switches
#    · 24-bit colour and curly, coloured underlines (XTGETTCAP RGB, Tc, Smulx, Setulc; DECRQSS of a colour)
# ════════════════════════════════════════════════════════════════════════════

var
  cfgKittyKeys = "auto"          # ui.kittyKeyboard: auto | off
  cfgGraphemes = "auto"          # ui.graphemes: auto | on | off
  cfgUndercurl = "auto"          # ui.undercurl: auto | on | off
  cfgTrueColorSet = "auto"       # ui.trueColor (an answer only upgrades "auto")
  tcAsked = false                # the questions went out (once per raw mode)
  tcKitty = false                # the terminal speaks the kitty keyboard protocol
  tcKittyOn = false              # … and ned pushed its flags (popped when it leaves raw mode)
  tc2027 = -1                    # its answer about mode 2027: 0 unknown, 1 set, 2 reset, 3 always set, 4 always reset
  tc2027On = false               # ned set mode 2027 (reset when it leaves)
  tcUndercurl = false            # it said it draws curly underlines (Smulx) or is known to
  tcUlColor = false              # … in a colour of their own (Setulc)
  tcRgb = false                  # it said it does 24-bit colour
  tcScheme = 0                   # mode 2031: 1 dark, 2 light (0: never said)
  tcSchemeNews = false           # (a new answer for the main loop: the theme may follow it)
  tcAnswers: seq[string]         # (what it answered, for Help › Check setup)
  termFocused = true             # the terminal window has the focus (focus events, mode 1004)
  focusLostAt = getMonoTime()
  focusNews = 0                  # (for the main loop: 1 the focus came back, 2 it went)

proc termKnownName(): bool =
  ## a terminal whose answers to these questions would show as text (the Linux console, a dumb terminal)
  let t = getEnv("TERM")
  t in ["linux", "dumb", "cons25"] or t.startsWith("vt1") or t.startsWith("vt2") or t.len == 0

proc undercurlByName(): bool =
  ## terminals known to draw curly, coloured underlines (and tmux, which reads them and draws what its terminal can)
  let t = getEnv("TERM")
  let p = getEnv("TERM_PROGRAM")
  if t in ["xterm-kitty", "xterm-ghostty", "foot", "foot-extra", "wezterm", "alacritty", "contour"]: return true
  if p in ["WezTerm", "ghostty", "vscode"]: return true
  if getEnv("TMUX").len > 0: return true
  let vte = getEnv("VTE_VERSION")
  if vte.len > 0 and vte.allCharsInSet(Digits) and parseInt(vte) >= 5200: return true      # (GNOME Terminal, Tilix …)
  false

proc applyUndercurl() =
  let was = ulStyled
  ulStyled = case cfgUndercurl
    of "on": true
    of "off": false
    else: tcUndercurl or undercurlByName()
  if was != ulStyled:
    prevGrid.setLen(0)
    needRender = true

proc applyGraphemes() =
  let want = case cfgGraphemes
    of "on": true
    of "off": false
    else: tc2027 in [1, 2, 3]
  if want and tc2027 == 2 and not tc2027On and cfgGraphemes != "off":
    writeAll("\e[?2027h")
    tc2027On = true
  if want != graphemes:
    graphemes = want
    resetCellPool()
    prevGrid.setLen(0)
    needRender = true

func hexName(h: string): string =
  ## an XTGETTCAP name, hex-encoded ("524742" → "RGB")
  var i = 0
  while i + 1 < h.len:
    try: result.add char(parseHexInt(h[i .. i + 1]))
    except ValueError: return ""
    i += 2

proc termCapsStart() =
  ## raw mode on: the questions (each terminal answers those it knows and ignores the rest)
  if tcKitty and cfgKittyKeys != "off" and not tcKittyOn:
    writeAll("\e[>5u")                 # (known from before a suspend: flags 1 + 4, disambiguate + alternate keys)
    tcKittyOn = true
  if tc2027On: writeAll("\e[?2027h")
  writeAll("\e[?2031h")                # (tell me when light and dark switch)
  if termKnownName(): return
  var q = "\e[?u\e[?2027$p\e[?996n"
  for name in ["RGB", "Tc", "Smulx", "Setulc"]:
    q.add "\eP+q" & toHex(name).toLowerAscii & "\e\\"
  if not trueColor: q.add "\e[48;2;1;2;3m\eP$qm\e\\\e[0m"   # (does a 24-bit colour stay what it was set to?)
  writeAll(q)
  tcAsked = true

proc termCapsStop() =
  ## leaving raw mode (quitting, a program run in the terminal): the terminal as ned found it
  if tcKittyOn:
    writeAll("\e[<u")
    tcKittyOn = false
  if tc2027On: writeAll("\e[?2027l")
  writeAll("\e[?2031l")

proc tcNote(s: string) =
  if tcAnswers.len < 40 and s notin tcAnswers: tcAnswers.add s

proc termCsiReply(priv, inter, fin: char, params: seq[int]): bool =
  ## a terminal's answer to one of the questions (CSI ? …): true when it was one
  if priv != '?': return false
  if fin == 'u' and inter == '\0':
    # kitty keyboard: the flags in use — it speaks the protocol
    tcKitty = true
    tcNote("kitty keyboard protocol")
    if cfgKittyKeys != "off" and not tcKittyOn:
      writeAll("\e[>5u")
      tcKittyOn = true
    return true
  if fin == 'y' and inter == '$' and params.len >= 2 and params[0] == 2027:
    tc2027 = params[1]
    if tc2027 in [1, 2, 3]: tcNote("grapheme clusters (mode 2027)")
    applyGraphemes()
    return true
  if fin == 'n' and params.len >= 2 and params[0] == 997:
    tcScheme = params[1]
    tcSchemeNews = true
    tcNote("light/dark notifications (mode 2031)")
    return true
  fin in {'c', 'y', 'n'}            # (DA1 and other answers: not keys)

proc termDcsReply(body: string) =
  ## DCS answers: XTGETTCAP (1+r<name>=<value>) and DECRQSS (1$r<SGR>)
  if body.startsWith("1+r"):
    for part in body[3 .. ^1].split(';'):
      let name = hexName(part.split('=')[0])
      case name
      of "RGB", "Tc":
        tcRgb = true
        tcNote("24-bit colour (" & name & ")")
      of "Smulx":
        tcUndercurl = true
        tcNote("curly underlines")
      of "Setulc":
        tcUlColor = true
        tcNote("underline colours")
      else: discard
  elif body.startsWith("1$r") and ("48:2:1:2:3" in body or "48;2;1;2;3" in body or "48:2::1:2:3" in body):
    tcRgb = true
    tcNote("24-bit colour (kept a colour set to it)")
  else: return
  if tcRgb and not trueColor and cfgTrueColorSet == "auto":
    trueColor = true
    prevGrid.setLen(0)
    needRender = true
  if tcUndercurl: applyUndercurl()

proc termFocusChange(gained: bool) =
  termFocused = gained
  focusNews = if gained: 1 else: 2
  if not gained: focusLostAt = getMonoTime()
  else:
    prevGrid.setLen(0)               # (back: everything drawn again — an app switch on Android may have spoilt it)
  needRender = true

proc awayIdle(): bool =
  ## the terminal lost the focus a while ago: background work that only serves what you look at waits
  not termFocused and msSince(focusLostAt) > 2000
