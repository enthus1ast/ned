## dial — increase or decrease the number, date, time or true/false at the cursor (vim's Ctrl+A and Ctrl+X)
##
##   Ctrl+Alt+A / Ctrl+Alt+X   Dial: increment / Dial: decrement — what is under the cursor, or else the first
##                             number, date or time after it on the line; with a selection, the first number of
##                             each selected line
##   Dial: add 1, 2, 3 … to the selected lines' numbers    (a column of 0s becomes 1, 2, 3 …)
##   what it changes      numbers: -5 and 5 (item-1 is not negative), 1_000 keeps its underscores, 007 its zeros;
##                        hex 0x1F (its case kept), binary 0b101, octal 0o17; dates 2026-10-24 (the year, month or
##                        day the cursor is on — the day when the cursor is before the date; the months and the
##                        days roll over as a calendar does); times 9:30, 09:30 and 09:30:15 (the hour, minute or
##                        second; round the clock); words under the cursor: true/false, yes/no, on/off, and/or,
##                        let/var, inc/dec, Monday … Sunday, January … December (True and TRUE keep their case)
##   vim                  <C-a> <C-x> with a count (5<C-a>); in visual mode the first number of each selected line
##                        (5<C-a> adds 5 to each), g<C-a> g<C-x> one more on each line (1, 2, 3 …; 2g<C-a>: 2, 4, 6 …)
##   settings             plugins.dial.cycles — words of your own to go round: "red,green,blue;low,high"
import nedplugin

requiresNed(">= 6.25")

settingDef("cycles", "", "Words of your own that Dial goes round, the lists apart with ; and the words with , " &
           "(red,green,blue;low,high) — they come before Dial's own")

const
  Weekdays = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
  Months = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
            "november", "december"]

proc cycles(): seq[seq[string]] =
  ## the words Dial goes round: yours (the cycles setting) first, then its own
  for g in setting("cycles", "").split(';'):
    var ws: seq[string]
    for w in g.split(','):
      let t = w.strip.toLowerAscii
      if t.len > 0 and t notin ws: ws.add t
    if ws.len >= 2: result.add ws
  for ws in [@["true", "false"], @["yes", "no"], @["on", "off"], @["and", "or"], @["let", "var"], @["inc", "dec"]]:
    result.add ws
  result.add @Weekdays
  result.add @Months

# ── what is on the line ──

type
  Kind = enum kNone, kDate, kTime, kHex, kBin, kOct, kDec, kWord
  Hit = object
    ## something Dial can change: its kind and where it is in the line (a up to e)
    kind: Kind
    a, e: int
    words: seq[string]           ## (a word) the words it goes round
    idx: int                     ## (a word) its place among them

func isIdent(c: char): bool = c in IdentChars or ord(c) >= 128

func runEnd(s: string, i: int, ds: set[char]): int =
  ## the end of the digits (of ds) from i on — single underscores between them, as Nim writes 1_000
  result = i
  while result < s.len:
    if s[result] in ds: inc result
    elif s[result] == '_' and result > i and result + 1 < s.len and s[result + 1] in ds: inc result
    else: break

func numberHits(s: string): seq[Hit] =
  ## the numbers of the line: 0x 0b 0o ones, and decimal ones (a - right before one is its sign unless it follows a
  ## name, a number or a closing bracket: item-1 and a-1 are not negative)
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '0' and i + 2 < s.len and s[i + 1] in {'x', 'X', 'b', 'B', 'o', 'O'} and (i == 0 or not isIdent(s[i - 1])):
      let (k, ds) = case s[i + 1]
        of 'x', 'X': (kHex, HexDigits)
        of 'b', 'B': (kBin, {'0', '1'})
        else: (kOct, {'0' .. '7'})
      if s[i + 2] in ds:
        let e = runEnd(s, i + 2, ds)
        result.add Hit(kind: k, a: i, e: e)
        i = e
        continue
    if c in Digits:
      let e = runEnd(s, i, Digits)
      var a = i
      if i > 0 and s[i - 1] == '-' and
         (i < 2 or not (isIdent(s[i - 2]) or s[i - 2] in {')', ']', '}', '.', '"', '\''})):
        a = i - 1
      result.add Hit(kind: kDec, a: a, e: e)
      i = e
      continue
    inc i

func allDigits(s: string, a, e: int): bool =
  if a < 0 or e > s.len or a >= e: return false
  for i in a ..< e:
    if s[i] notin Digits: return false
  true

func toInt(s: string, a, e: int): int =
  for i in a ..< e: result = result * 10 + (ord(s[i]) - ord('0'))

func daysIn(y, m: int): int =
  case m
  of 2: (if (y mod 4 == 0 and y mod 100 != 0) or y mod 400 == 0: 29 else: 28)
  of 4, 6, 9, 11: 30
  else: 31

func dateHits(s: string): seq[Hit] =
  ## the dates of the line: 2026-10-24 (or 2026/10/24), a real date
  var i = 0
  while i + 10 <= s.len:
    if (i == 0 or s[i - 1] notin Digits) and allDigits(s, i, i + 4) and s[i + 4] in {'-', '/'} and
       allDigits(s, i + 5, i + 7) and s[i + 7] == s[i + 4] and allDigits(s, i + 8, i + 10) and
       (i + 10 == s.len or s[i + 10] notin Digits):
      let (y, m, d) = (toInt(s, i, i + 4), toInt(s, i + 5, i + 7), toInt(s, i + 8, i + 10))
      if m in 1 .. 12 and d in 1 .. daysIn(y, m):
        result.add Hit(kind: kDate, a: i, e: i + 10)
        i += 10
        continue
    inc i

func timeHits(s: string): seq[Hit] =
  ## the times of the line: 9:30, 09:30, 09:30:15 (hours 0–23)
  var i = 0
  while i < s.len:
    if s[i] in Digits and (i == 0 or s[i - 1] notin Digits + {':'}):
      var j = i
      while j < s.len and s[j] in Digits: inc j
      let hw = j - i
      if hw in 1 .. 2 and j + 3 <= s.len and s[j] == ':' and allDigits(s, j + 1, j + 3) and
         (j + 3 == s.len or s[j + 3] notin Digits):
        var e = j + 3
        var ok = toInt(s, i, j) <= 23 and toInt(s, j + 1, j + 3) <= 59
        if e + 3 <= s.len and s[e] == ':' and allDigits(s, e + 1, e + 3) and (e + 3 == s.len or s[e + 3] notin Digits):
          ok = ok and toInt(s, e + 1, e + 3) <= 59
          e += 3
        if ok:
          result.add Hit(kind: kTime, a: i, e: e)
          i = e
          continue
      i = j
      continue
    inc i

func wordHit(s: string, c: int, cs: seq[seq[string]]): Hit =
  ## the word of a list (true/false …) the cursor is on — a whole word: "on" is not in "onboard"
  let low = s.toLowerAscii
  for ws in cs:
    for k, w in ws:
      var p = low.find(w)
      while p >= 0 and p <= c:
        let e = p + w.len
        if c < e and (not isIdent(w[0]) or p == 0 or not isIdent(s[p - 1])) and
           (not isIdent(w[^1]) or e == s.len or not isIdent(s[e])):
          return Hit(kind: kWord, a: p, e: e, words: ws, idx: k)
        p = low.find(w, p + 1)
  Hit(kind: kNone)

func choose(s: string, c: int, cs: seq[seq[string]]): Hit =
  ## what the cursor is on (the longest: a date rather than its day), else the first number, date or time after it
  var hits = dateHits(s) & timeHits(s) & numberHits(s)
  let w = wordHit(s, c, cs)
  if w.kind != kNone: hits.add w
  result = Hit(kind: kNone)
  for h in hits:
    if h.a <= c and c < h.e and (result.kind == kNone or h.e - h.a > result.e - result.a): result = h
  if result.kind != kNone: return
  for h in hits:
    if h.a > c and (result.kind == kNone or h.a < result.a or (h.a == result.a and h.e - h.a > result.e - result.a)):
      result = h

# ── the new text ──

func regroup(orig, ds: string): string =
  ## the digits ds with underscores as the number had them: every 3 stays every 3 (9_999 → 10_000); groups of
  ## different sizes keep their places from the right
  let groups = orig.split('_')
  if groups.len < 2: return ds
  let g = groups[^1].len
  var even = groups[0].len <= g
  for k in 1 ..< groups.len:
    if groups[k].len != g: even = false
  var cuts: seq[int]                      # the underscores: how many digits are right of each
  if even:
    var k = g
    while k < ds.len:
      cuts.add k
      k += g
  else:
    var k = 0
    for j in countdown(groups.high, 1):
      k += groups[j].len
      if k < ds.len: cuts.add k
  result = ""
  var n = 0
  for j in countdown(ds.high, 0):
    if n > 0 and n in cuts: result = "_" & result
    result = $ds[j] & result
    inc n

func parseDigits(ds: string, base: int): int64 =
  const maxDigits = [0, 0, 62, 0, 0, 0, 0, 0, 20, 0, 18, 0, 0, 0, 0, 0, 15]
  if ds.len > maxDigits[base]: raise newException(ValueError, "Dial: the number is too large")
  for ch in ds:
    let d = if ch in Digits: ord(ch) - ord('0') else: ord(ch.toLowerAscii) - ord('a') + 10
    result = result * base + d

func inBase(v: int64, base: int, upper: bool): string =
  if v == 0: return "0"
  var x = v
  while x > 0:
    let d = int(x mod base)
    result = $(if d < 10: chr(ord('0') + d) elif upper: chr(ord('A') + d - 10) else: chr(ord('a') + d - 10)) & result
    x = x div base

func addDecimal(t: string, n: int): string =
  let neg = t.startsWith("-")
  let body = if neg: t[1 .. ^1] else: t
  let digits = body.replace("_", "")
  var v = parseDigits(digits, 10)
  if neg: v = -v
  let r = v + n
  var ds = $abs(r)
  if digits.len > 1 and digits[0] == '0' and ds.len < digits.len: ds = repeat('0', digits.len - ds.len) & ds
  (if r < 0: "-" else: "") & regroup(body, ds)

func addBased(t: string, n, base: int): string =
  ## 0x 0b 0o: never below 0, as many digits as before at least, the case of the hex letters kept
  let body = t[2 .. ^1]
  let digits = body.replace("_", "")
  var upper = false
  for ch in digits:
    if ch in {'A' .. 'F'}: upper = true
    elif ch in {'a' .. 'f'}:
      upper = false
      break
  let r = max(0'i64, parseDigits(digits, base) + n)
  var ds = inBase(r, base, upper)
  if ds.len < digits.len: ds = repeat('0', digits.len - ds.len) & ds
  t[0 .. 1] & regroup(body, ds)

func daysFromCivil(y0, m, d: int): int =
  ## days since 1970-01-01 (the proleptic Gregorian calendar)
  let y = if m <= 2: y0 - 1 else: y0
  let era = (if y >= 0: y else: y - 399) div 400
  let yoe = y - era * 400
  let doy = (153 * ((m + 9) mod 12) + 2) div 5 + d - 1
  let doe = yoe * 365 + yoe div 4 - yoe div 100 + doy
  era * 146097 + doe - 719468

func civilFromDays(z0: int): (int, int, int) =
  let z = z0 + 719468
  let era = (if z >= 0: z else: z - 146096) div 146097
  let doe = z - era * 146097
  let yoe = (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365
  let doy = doe - (365 * yoe + yoe div 4 - yoe div 100)
  let mp = (5 * doy + 2) div 153
  let d = doy - (153 * mp + 2) div 5 + 1
  let m = if mp < 10: mp + 3 else: mp - 9
  (yoe + era * 400 + (if m <= 2: 1 else: 0), m, d)

func pad(v, w: int): string =
  result = $v
  if result.len < w: result = repeat('0', w - result.len) & result

func datePart(off: int): int =
  ## the part of a date at offset off from its start: 0 the year, 1 the month, 2 the day (before it: the day)
  if off < 0: 2 elif off < 5: 0 elif off < 8: 1 else: 2

func addDate(t: string, part, n: int): string =
  var (y, m, d) = (toInt(t, 0, 4), toInt(t, 5, 7), toInt(t, 8, 10))
  case part
  of 0:
    y += n
    d = min(d, daysIn(y, m))
  of 1:
    let total = y * 12 + (m - 1) + n
    y = total div 12
    m = total mod 12 + 1
    if m < 1:
      m += 12
      y -= 1
    d = min(d, daysIn(y, m))
  else: (y, m, d) = civilFromDays(daysFromCivil(y, m, d) + n)
  if y < 1 or y > 9999: raise newException(ValueError, "Dial: the year would be " & $y)
  let sep = $t[4]
  pad(y, 4) & sep & pad(m, 2) & sep & pad(d, 2)

func timeShape(t: string): (int, bool) =
  ## a time's hour digits (1 or 2) and whether it has seconds
  let hw = t.find(':')
  (hw, t.len > hw + 3)

func timePart(t: string, off: int): int =
  ## the part of a time at offset off: 0 the hour, 1 the minute, 2 the second (before it: the minute)
  let (hw, _) = timeShape(t)
  if off < 0: 1 elif off <= hw: 0 elif off <= hw + 3: 1 else: 2

func addTime(t: string, part, n: int): string =
  let (hw, secs) = timeShape(t)
  var total = toInt(t, 0, hw) * 3600 + toInt(t, hw + 1, hw + 3) * 60 + (if secs: toInt(t, hw + 4, hw + 6) else: 0)
  let unit = case part
    of 0: 3600
    of 1: 60
    else: 1
  total = ((total + n * unit) mod 86400 + 86400) mod 86400
  result = pad(total div 3600, hw) & ":" & pad(total mod 3600 div 60, 2)
  if secs: result.add ":" & pad(total mod 60, 2)

func withCaseOf(w, orig: string): string =
  ## w in the case of orig: TRUE → FALSE, True → False, true → false
  var up, low = 0
  for c in orig:
    if c in {'A' .. 'Z'}: inc up
    elif c in {'a' .. 'z'}: inc low
  if up > 0 and low == 0: w.toUpperAscii
  elif orig.len > 0 and orig[0] in {'A' .. 'Z'}: w.capitalizeAscii
  else: w

func changed(s: string, h: Hit, c, n: int): (string, int) =
  ## the new text for h (n added: n < 0 takes away), and where the cursor goes in it (the end of what changed)
  let t = s[h.a ..< h.e]
  case h.kind
  of kDec:
    let r = addDecimal(t, n)
    (r, r.len - 1)
  of kHex, kBin, kOct:
    let r = addBased(t, n, (case h.kind
      of kHex: 16
      of kBin: 2
      else: 8))
    (r, r.len - 1)
  of kDate:
    let part = datePart(c - h.a)
    (addDate(t, part, n), [3, 6, 9][part])
  of kTime:
    let part = timePart(t, c - h.a)
    let r = addTime(t, part, n)
    let hw = r.find(':')
    (r, [hw - 1, hw + 2, hw + 5][part])
  of kWord:
    let k = ((h.idx + n) mod h.words.len + h.words.len) mod h.words.len
    let r = withCaseOf(h.words[k], t)
    (r, r.len - 1)
  of kNone: (t, 0)

# ── the commands ──

proc dialAt(b: Buf, n: int) =
  ## n added to what is at the cursor (or after it on the line)
  let p = b.cursor
  let s = b.line(p.line)
  let h = choose(s, p.col, cycles())
  if h.kind == kNone:
    message("Dial: nothing to change at the cursor or after it on the line")
    return
  try:
    let (t, off) = changed(s, h, p.col, n)
    if t != s[h.a ..< h.e]: b.replace(rng(pos(p.line, h.a), pos(p.line, h.e)), t)
    b.setCursor(pos(p.line, h.a + max(0, off)))
  except ValueError as e:
    message(e.msg)

proc dialLines(b: Buf, r: Range, n: int, progressive: bool, moveCursor = true) =
  ## the first number of each line of r: n added (progressive: n, 2n, 3n … one line after the other)
  var last = r.stop.line
  if r.stop.col == 0 and last > r.start.line: dec last
  let ls = b.lines(r.start.line, last)
  var k = 0
  try:
    for i, s in ls:
      let l = r.start.line + i
      let a0 = if i > 0: 0 else: r.start.col
      let e0 = if l < r.stop.line: s.len else: min(s.len, r.stop.col)
      for h in numberHits(s):
        if h.e > a0 and h.a < e0:
          inc k
          let (t, _) = changed(s, h, h.a, (if progressive: n * k else: n))
          b.replace(rng(pos(l, h.a), pos(l, h.e)), t)
          break
  except ValueError as e:
    message(e.msg)
  if k == 0: message("Dial: no number in the selection")
  if moveCursor: b.setCursor(r.start)

proc dialCommand(n: int, progressive = false) =
  ## a palette command: the selected lines' numbers, or what is at the cursor
  let b = current()
  if not b.valid: return
  let r = b.selection
  if not r.isEmpty: dialLines(b, r, n, progressive)
  elif progressive: message("Dial: select the lines first (each one gets one more than the line before)")
  else: dialAt(b, n)

command "Dial: increment", "ctrl+alt+a": dialCommand(1)
command "Dial: decrement", "ctrl+alt+x": dialCommand(-1)
command "Dial: add 1, 2, 3 … to the selected lines' numbers": dialCommand(1, true)

# ── vim ──

nmap("<C-a>", "add 1 to the number, date, time or word") do (count: int): dialAt(current(), count)
nmap("<C-x>", "take 1 from the number, date, time or word") do (count: int): dialAt(current(), -count)
nmap("g<C-a>", "add 1 to the number, date, time or word") do (count: int): dialAt(current(), count)
nmap("g<C-x>", "take 1 from the number, date, time or word") do (count: int): dialAt(current(), -count)

proc dialVisual(n: int, progressive: bool) =
  ## vim's visual mode: the selection as vim shows it (the character under the cursor in it, whole lines in
  ## visual-line mode); the cursor is left alone, so ned goes back to normal mode at the selection's start
  let b = current()
  if b.valid: dialLines(b, b.selection, n, progressive, moveCursor = false)

vmap("<C-a>", "add 1 to each line's first number") do (count: int): dialVisual(count, false)
vmap("<C-x>", "take 1 from each line's first number") do (count: int): dialVisual(-count, false)
vmap("g<C-a>", "add 1, 2, 3 … line after line") do (count: int): dialVisual(count, true)
vmap("g<C-x>", "take 1, 2, 3 … line after line") do (count: int): dialVisual(-count, true)
