# ════════════════════════════════════════════════════════════════════════════
#  Input decoding (keys, mouse, bracketed paste)
# ════════════════════════════════════════════════════════════════════════════

var ttyGone = false     # stdin hit end-of-file or an I/O error: the terminal is gone

proc readInput(): bool =
  ## reads whatever the terminal has sent into the input buffer without waiting; true when some bytes came. End of file
  ## or a real read error marks the terminal as gone (ttyGone)
  var tmp: array[8192, char]
  while true:
    let n = posix.read(0.cint, addr tmp[0], tmp.len)
    if n == 0 or (n < 0 and errno notin [EAGAIN, EWOULDBLOCK, EINTR]):
      ttyGone = true
      break
    if n <= 0: break
    result = true
    let old = inBuf.len
    inBuf.setLen(old + n)
    copyMem(addr inBuf[old], addr tmp[0], n)
    if n < tmp.len: break

proc modsFromParam(p: int): set[Mod] =
  ## the modifiers of a terminal's modifier number (one more than a sum of 1 for Shift, 2 for Alt, 4 for Ctrl); none for
  ## 1 or less
  let m = p - 1
  if m <= 0: return {}
  if (m and 1) != 0: result.incl mShift
  if (m and 2) != 0: result.incl mAlt
  if (m and 4) != 0: result.incl mCtrl

proc controlKey(c: char, k: var Key): bool =
  ## a control byte as the key it stands for — Enter, Tab, Backspace (the byte 8 is Ctrl+Backspace unless the terminal's
  ## erase key sends it), NUL as Ctrl+Space, the rest as Ctrl with a letter or one of \ ] ^ /; false when the byte is
  ## none of them
  case c
  of '\r', '\n': k.kind = kEnter
  of '\t': k.kind = kTab
  of '\x7f': k.kind = kBackspace
  of '\x08':
    k.kind = kBackspace
    if not eraseIsCtrlH: k.mods.incl mCtrl
  of '\x00': k.kind = kChar; k.ch = ord(' '); k.mods.incl mCtrl
  of '\x01'..'\x07', '\x0b', '\x0c', '\x0e'..'\x1a':
    k.kind = kChar; k.ch = ord(c) - 1 + ord('a'); k.mods.incl mCtrl
  of '\x1c': k.kind = kChar; k.ch = ord('\\'); k.mods.incl mCtrl
  of '\x1d': k.kind = kChar; k.ch = ord(']'); k.mods.incl mCtrl
  of '\x1e': k.kind = kChar; k.ch = ord('^'); k.mods.incl mCtrl
  of '\x1f': k.kind = kChar; k.ch = ord('/'); k.mods.incl mCtrl
  else: return false
  true

proc kittyKey(raw: string, k: var Key) =
  ## a key in the kitty keyboard protocol: CSI code[:shifted[:base]] ; mods[:event] u — turned into the Key ned has
  ## always had for it, so bindings keep working: Alt+Shift+R is 'R' with Alt (as ESC R was), Ctrl+[ is Esc; and
  ## what the old way could not tell apart now is: Ctrl+Shift+F, Ctrl+I and Tab, Ctrl+Enter, Shift+Enter
  let parts = raw.split(';')
  proc num(s: string): int =
    ## the number in a string, 0 when it is empty or not one
    if s.len == 0: return 0
    try: parseInt(s) except ValueError: 0
  let codes = parts[0].split(':')
  let code = num(codes[0])
  var shifted = if codes.len > 1: num(codes[1]) else: 0
  if shifted < 32 or shifted > 0x10FFFF or shifted in 0xD800 .. 0xDFFF: shifted = 0
  if code < 32 and code notin [8, 9, 13, 27] or code > 0x10FFFF or code in 0xD800 .. 0xDFFF:
    k.kind = kNone                    # (no key: what a terminal would never send)
    return
  let mp = if parts.len > 1: num(parts[1].split(':')[0]) else: 1
  let m = max(0, mp - 1)
  k.mods = modsFromParam(mp)
  if (m and (8 or 16 or 32)) != 0:     # (Super, Hyper, Meta: the desktop's, not ned's)
    k.kind = kNone
    return
  if parts.len > 1 and parts[1].split(':').len > 1 and num(parts[1].split(':')[1]) == 3:
    k.kind = kNone                    # (a key let go: only with flags ned does not ask for)
    return
  case code
  of 13, 57414: k.kind = kEnter
  of 9: k.kind = kTab
  of 27: k.kind = kEsc
  of 127, 8: k.kind = kBackspace
  of 57417: k.kind = kLeft
  of 57418: k.kind = kRight
  of 57419: k.kind = kUp
  of 57420: k.kind = kDown
  of 57421: k.kind = kPgUp
  of 57422: k.kind = kPgDn
  of 57423: k.kind = kHome
  of 57424: k.kind = kEnd
  of 57425: k.kind = kInsert
  of 57426: k.kind = kDelete
  of 57399 .. 57408: k.kind = kChar; k.ch = ord('0') + code - 57399
  of 57409: k.kind = kChar; k.ch = ord('.')
  of 57410: k.kind = kChar; k.ch = ord('/')
  of 57411: k.kind = kChar; k.ch = ord('*')
  of 57412: k.kind = kChar; k.ch = ord('-')
  of 57413: k.kind = kChar; k.ch = ord('+')
  of 57415: k.kind = kChar; k.ch = ord('=')
  of 57416: k.kind = kChar; k.ch = ord(',')
  of 57376 .. 57398: k.kind = kFn; k.fn = 13 + code - 57376
  of 57344 .. 57375, 57427 .. 63743: k.kind = kNone      # (media keys, lone modifiers, other private-use keys)
  else:
    k.kind = kChar
    k.ch = code
    let ctrl = mCtrl in k.mods
    if mShift in k.mods and not ctrl:
      # Shift (with Alt): the shifted character, as the terminal would have sent it — 'R', '?' — without Shift
      if shifted > 0:
        k.ch = shifted
        k.mods.excl mShift
      elif code < 128 and char(code) in {'a'..'z'}:
        k.ch = ord(toUpperAscii(char(code)))
        k.mods.excl mShift
    elif ctrl and code < 128 and char(code) in {'A'..'Z'}:
      k.ch = ord(toLowerAscii(char(code)))
      k.mods.incl mShift
    # as they always were: Ctrl+[ is Esc, Ctrl+M and Ctrl+J are Enter, Ctrl+H deletes back (Ctrl+I is not Tab now)
    if k.mods == {mCtrl}:
      if code == ord('['): k = Key(kind: kEsc)
      elif code in [ord('m'), ord('j')]: k = Key(kind: kEnter)
      elif code == ord('h'): k = Key(kind: kBackspace, mods: (if eraseIsCtrlH: {} else: {mCtrl}))

var inOff = 0     # parse position inside inBuf (consumed bytes are dropped once per batch)

# how many bytes of the input buffer are not decoded yet
proc avail(): int {.inline.} = inBuf.len - inOff
# the undecoded byte i places on
proc at(i: int): char {.inline.} = inBuf[inOff + i]

proc parseKey(force: bool, k: var Key): bool =
  ## decodes one event from `inBuf`; false when empty or incomplete (unless `force`)
  k = Key()
  if avail() <= 0: return false
  if avail() >= 6 and inBuf.continuesWith("\e[200~", inOff):
    let e = inBuf.find("\e[201~", inOff + 6)
    if e < 0:
      if not force: return false
      k.kind = kPaste
      k.text = inBuf[inOff + 6 .. ^1]
      inOff = inBuf.len
    else:
      k.kind = kPaste
      k.text = inBuf[inOff + 6 ..< e]
      inOff = e + 6
    k.text = k.text.replace("\r\n", "\n").replace('\r', '\n')
    return true
  let c = at(0)
  if c == '\e':
    if avail() == 1:
      if not force: return false
      inc inOff
      k.kind = kEsc
      return true
    let c2 = at(1)
    if c2 == '[':
      var i = 2
      var priv = '\0'
      if i < avail() and at(i) in {'<', '?', '>', '='}:
        priv = at(i)
        inc i
      let ps = i
      while i < avail() and at(i) in {'0'..'9', ';', ':'}: inc i
      let pe = i
      var inter = '\0'                  # (an intermediate byte: CSI ? 2027 ; 2 $ y)
      while i < avail() and at(i) in {' ' .. '/'}:
        inter = at(i)
        inc i
      if i >= avail():
        if not force: return false
        inOff += 2
        k.kind = kChar; k.ch = ord('['); k.mods = {mAlt}
        return true
      let fin = at(i)
      let raw = inBuf[inOff + ps ..< inOff + pe]
      var params: seq[int]
      for part in raw.split(';'):
        let p0 = part.split(':')[0]
        params.add (if p0.len == 0: 0 else: (try: parseInt(p0) except ValueError: 0))
      inOff += i + 1
      let p1 = if params.len > 0: params[0] else: 0
      let p2 = if params.len > 1: params[1] else: 1
      if priv == '?' and termCsiReply(priv, inter, fin, params):
        k.kind = kNone          # the terminal answering a question (see termcaps)
        return true
      if inter != '\0':
        k.kind = kNone
        return true
      if priv == '<' and fin in {'M', 'm'} and params.len >= 3:
        k.kind = kMouse
        let b = params[0]
        k.mb = if b >= 64: b and 0xC3 else: b and 3
        k.drag = (b and 32) != 0
        if (b and 4) != 0: k.mods.incl mShift
        if (b and 8) != 0: k.mods.incl mAlt
        if (b and 16) != 0: k.mods.incl mCtrl
        k.mx = params[1] - 1
        k.my = params[2] - 1
        k.press = fin == 'M'
        return true
      if priv in {'?', '>'}:
        k.kind = kNone          # terminal replies (DA, DECRPM …)
        return true
      case fin
      of 'A': k.kind = kUp
      of 'B': k.kind = kDown
      of 'C': k.kind = kRight
      of 'D': k.kind = kLeft
      of 'H': k.kind = kHome
      of 'F': k.kind = kEnd
      of 'Z': k.kind = kTab; k.mods.incl mShift; return true
      of 'P'..'S': k.kind = kFn; k.fn = ord(fin) - ord('P') + 1
      of 'I', 'O':
        k.kind = kNone           # focus in/out
        termFocusChange(fin == 'I')
        return true
      of '~':
        case p1
        of 1, 7: k.kind = kHome
        of 2: k.kind = kInsert
        of 3: k.kind = kDelete
        of 4, 8: k.kind = kEnd
        of 5: k.kind = kPgUp
        of 6: k.kind = kPgDn
        of 11..15: k.kind = kFn; k.fn = p1 - 10
        of 17..21: k.kind = kFn; k.fn = p1 - 11
        of 23, 24: k.kind = kFn; k.fn = p1 - 12
        else: k.kind = kNone
        k.mods = k.mods + modsFromParam(p2)
        return true
      of 'u':
        kittyKey(raw, k)
        return true
      else:
        k.kind = kNone
        return true
      if params.len >= 2: k.mods = k.mods + modsFromParam(p2)
      return true
    if c2 == 'O':
      if avail() < 3:
        if not force: return false
        inOff += 2
        k.kind = kChar; k.ch = ord('O'); k.mods = {mAlt}
        return true
      let f = at(2)
      inOff += 3
      case f
      of 'A': k.kind = kUp
      of 'B': k.kind = kDown
      of 'C': k.kind = kRight
      of 'D': k.kind = kLeft
      of 'H': k.kind = kHome
      of 'F': k.kind = kEnd
      of 'P'..'S': k.kind = kFn; k.fn = ord(f) - ord('P') + 1
      of 'M': k.kind = kEnter
      else: k.kind = kNone
      return true
    if c2 == ']' or c2 == 'P' or c2 == '_':
      # OSC / DCS / APC replies from the terminal: skip to ST or BEL (the background colour is kept)
      var i = 2
      while i < avail():
        let bel = at(i) == '\a'
        if bel or (at(i) == '\e' and i + 1 < avail() and at(i + 1) == '\\'):
          if c2 == ']' and i > 5:
            var body = newStringOfCap(i)
            for q in 2 ..< i: body.add at(q)
            if body.startsWith("11;"): oscBgReply = body[3 .. ^1]
          elif c2 == 'P' and i > 3:
            var body = newStringOfCap(i)
            for q in 2 ..< i: body.add at(q)
            termDcsReply(body)
          inOff += i + (if bel: 1 else: 2)
          k.kind = kNone
          return true
        inc i
      if not force: return false
      inOff = inBuf.len
      k.kind = kNone
      return true
    if c2 == '\e':
      inc inOff
      k.kind = kEsc
      return true
    # Alt + key
    let saved = inOff
    inc inOff
    var sub: Key
    if not parseKey(force, sub):
      inOff = saved
      return false
    k = sub
    k.mods.incl mAlt
    return true
  if controlKey(c, k):
    inc inOff
    return true
  let n = runeLen(c)
  if avail() < n:
    if not force: return false
  let (cp, used) = runeAt(inBuf, inOff)
  inOff += used
  k.kind = kChar
  k.ch = cp
  true

proc compactInput() {.inline.} =
  ## drops the bytes already decoded from the front of the input buffer and starts the decoding position at 0
  if inOff > 0:
    if inOff >= inBuf.len: inBuf.setLen(0)
    else: inBuf = inBuf[inOff .. ^1]
    inOff = 0
