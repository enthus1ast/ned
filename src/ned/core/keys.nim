# ════════════════════════════════════════════════════════════════════════════
#  Input decoding (keys, mouse, bracketed paste)
# ════════════════════════════════════════════════════════════════════════════

var ttyGone = false     # stdin hit end-of-file or an I/O error: the terminal is gone

proc readInput(): bool =
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
  let m = p - 1
  if m <= 0: return {}
  if (m and 1) != 0: result.incl mShift
  if (m and 2) != 0: result.incl mAlt
  if (m and 4) != 0: result.incl mCtrl

proc controlKey(c: char, k: var Key): bool =
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

var inOff = 0     # parse position inside inBuf (consumed bytes are dropped once per batch)

proc avail(): int {.inline.} = inBuf.len - inOff
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
      if i >= avail():
        if not force: return false
        inOff += 2
        k.kind = kChar; k.ch = ord('['); k.mods = {mAlt}
        return true
      let fin = at(i)
      var params: seq[int]
      for part in inBuf[inOff + ps ..< inOff + i].split(';'):
        let p0 = part.split(':')[0]
        params.add (if p0.len == 0: 0 else: (try: parseInt(p0) except ValueError: 0))
      inOff += i + 1
      let p1 = if params.len > 0: params[0] else: 0
      let p2 = if params.len > 1: params[1] else: 1
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
        k.mods = modsFromParam(p2)
        case p1
        of 13: k.kind = kEnter
        of 9: k.kind = kTab
        of 27: k.kind = kEsc
        of 127: k.kind = kBackspace
        else:
          k.kind = kChar
          k.ch = p1
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
  if inOff > 0:
    if inOff >= inBuf.len: inBuf.setLen(0)
    else: inBuf = inBuf[inOff .. ^1]
    inOff = 0
