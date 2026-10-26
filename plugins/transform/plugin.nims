## transform — the selected lines (or the whole file) sorted, made unique, reversed, numbered, joined; the selection
## encoded and decoded (base64, URL, hex, HTML, a string literal), JSON made pretty or one line, numbers added up
##
##   Transform: sort lines (A–Z), (Z–A), (by number), (by length)   — the selection's lines, else the file's
##   Transform: unique lines        the lines seen before taken out (the first of each kept)
##   Transform: reverse lines · number lines · trim the ends of lines · join lines (with a space) ·
##              split at commas (one item a line) · shuffle lines
##   Transform: base64 encode · base64 decode · URL encode · URL decode · hex encode · hex decode ·
##              HTML escape · HTML unescape · to a string literal · from a string literal · upper case · lower case
##              — the selection (a word at the cursor when nothing is selected)
##   Transform: pretty JSON · one-line JSON     the selection, else the file
##   Transform: add up the numbers  the numbers in the selection (or the file): their sum, count, mean, min and max
##   Transform: count               lines, words and characters of the selection (or the file)
## Each change is one undo step.
import nedplugin
import std/[strutils, algorithm, base64, uri, json]

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("clipboard", "Transform: add up the numbers puts the sum on the clipboard")

# ── what is worked on: the selected lines, the selection, the file ──

proc lineSpan(b: Buf): (int, int) =
  ## the lines of the selection (a selection ending at a line's start leaves that line out), else every line
  let r = b.selection
  if r.isEmpty: return (0, b.lineCount - 1)
  var last = r.stop.line
  if r.stop.col == 0 and last > r.start.line: dec last
  (r.start.line, last)

proc withLines(f: proc(ls: seq[string]): seq[string]) =
  let b = current()
  let (a, e) = lineSpan(b)
  let ls = b.lines(a, e)
  let nw = f(ls)
  if nw == ls: return
  b.replace(rng(pos(a, 0), pos(e, b.line(e).len)), nw.join("\n"))
  b.select(rng(pos(a, 0), pos(a + nw.len - 1, (if nw.len > 0: nw[^1].len else: 0))))

proc wordRange(b: Buf): Range =
  ## the selection, else the run of non-space characters at the cursor
  let r = b.selection
  if not r.isEmpty: return r
  let c = b.cursor
  let s = b.line(c.line)
  var a = c.col
  while a > 0 and s[a - 1] notin Whitespace: dec a
  var e = c.col
  while e < s.len and s[e] notin Whitespace: inc e
  rng(pos(c.line, a), pos(c.line, e))

proc withText(f: proc(s: string): string) =
  let b = current()
  let r = wordRange(b)
  if r.isEmpty:
    message("Select the text first")
    return
  let s = b.textIn(r)
  var t = ""
  try: t = f(s)
  except CatchableError as e:
    warn(e.msg)
    return
  if t == s: return
  b.replace(r, t)
  let ls = t.split('\n')
  b.select(rng(r.start, pos(r.start.line + ls.high, (if ls.len == 1: r.start.col + t.len else: ls[^1].len))))

proc wholeOrSelection(b: Buf): (Range, string) =
  let r = b.selection
  if r.isEmpty:
    let n = b.lineCount
    let all = rng(pos(0, 0), pos(n - 1, b.line(n - 1).len))
    return (all, b.text)
  (r, b.textIn(r))

# ── lines ──

func numKey(s: string): (bool, float) =
  ## the number a line starts with (after spaces), for sorting by number
  let t = s.strip
  var e = 0
  while e < t.len and t[e] in {'0'..'9', '.', '-', '+', 'e', 'E', '_'}: inc e
  try: (true, parseFloat(t[0 ..< e].replace("_", "")))
  except ValueError: (false, 0.0)

proc sortBy(ls: seq[string], how: string): seq[string] =
  result = ls
  case how
  of "az": result.sort(proc(a, b: string): int = cmp(a.toLowerAscii, b.toLowerAscii))
  of "za": result.sort(proc(a, b: string): int = cmp(b.toLowerAscii, a.toLowerAscii))
  of "num":
    result.sort(proc(a, b: string): int =
      let (ka, va) = numKey(a)
      let (kb, vb) = numKey(b)
      if ka and kb: cmp(va, vb) elif ka: -1 elif kb: 1 else: cmp(a, b))
  of "len": result.sort(proc(a, b: string): int = cmp(a.len, b.len))
  else: discard

func uniqueLines(ls: seq[string]): seq[string] =
  for l in ls:
    if l notin result: result.add l

func numbered(ls: seq[string]): seq[string] =
  let w = len($ls.len)
  for i, l in ls: result.add align($(i + 1), w) & ". " & l

func joined(ls: seq[string]): seq[string] =
  var parts: seq[string]
  for i, l in ls: parts.add (if i == 0: l.strip(leading = false) else: l.strip)
  @[parts.join(" ")]

func splitCommas(ls: seq[string]): seq[string] =
  for l in ls:
    let ind = l.len - l.strip(trailing = false).len
    for p in l.split(','):
      if p.strip.len > 0: result.add l[0 ..< ind] & p.strip

proc shuffled(ls: seq[string]): seq[string] =
  ## (a fixed shuffle seeded by the clock: no random module in NimScript)
  result = ls
  var seed = uint32(unixTime() * 1000.0) or 1
  for i in countdown(result.high, 1):
    seed = seed xor (seed shl 13)
    seed = seed xor (seed shr 17)
    seed = seed xor (seed shl 5)
    let j = int(seed mod uint32(i + 1))
    swap(result[i], result[j])

command "Transform: sort lines (A–Z)": withLines(proc(ls: seq[string]): seq[string] = sortBy(ls, "az"))
command "Transform: sort lines (Z–A)": withLines(proc(ls: seq[string]): seq[string] = sortBy(ls, "za"))
command "Transform: sort lines (by number)": withLines(proc(ls: seq[string]): seq[string] = sortBy(ls, "num"))
command "Transform: sort lines (by length)": withLines(proc(ls: seq[string]): seq[string] = sortBy(ls, "len"))
command "Transform: unique lines": withLines(uniqueLines)
command "Transform: reverse lines": withLines(proc(ls: seq[string]): seq[string] = reversed(ls))
command "Transform: number lines": withLines(numbered)
command "Transform: trim the ends of lines":
  withLines(proc(ls: seq[string]): seq[string] =
    for l in ls: result.add l.strip(leading = false))
command "Transform: join lines (with a space)": withLines(joined)
command "Transform: split at commas (one item a line)": withLines(splitCommas)
command "Transform: shuffle lines": withLines(shuffled)

# ── text ──

func hexEncode(s: string): string =
  for c in s: result.add toHex(ord(c), 2).toLowerAscii

proc hexDecode(s: string): string =
  let t = s.multiReplace(("0x", ""), (" ", ""), ("\n", ""), (":", ""))
  if t.len mod 2 != 0: raise newException(ValueError, "not hex: an odd number of digits")
  for i in countup(0, t.len - 2, 2): result.add chr(parseHexInt(t[i .. i + 1]))

func htmlEscape(s: string): string =
  s.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"), ("\"", "&quot;"), ("'", "&#39;"))

func htmlUnescape(s: string): string =
  s.multiReplace(("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
                 ("&amp;", "&"))

func toLiteral(s: string): string =
  ## a string literal: "…" with \\ \" \n \t \r, other control characters as \xHH (the rest as it is)
  result = "\""
  for c in s:
    case c
    of '\\': result.add "\\\\"
    of '"': result.add "\\\""
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    of '\0'..'\x08', '\x0B', '\x0C', '\x0E'..'\x1F', '\x7F': result.add "\\x" & toHex(ord(c), 2)
    else: result.add c
  result.add "\""

func toUTF8Rune(code: int): string =
  ## a code point as UTF-8
  if code < 0x80: result.add chr(code)
  elif code < 0x800:
    result.add chr(0xC0 or (code shr 6))
    result.add chr(0x80 or (code and 0x3F))
  elif code < 0x10000:
    result.add chr(0xE0 or (code shr 12))
    result.add chr(0x80 or ((code shr 6) and 0x3F))
    result.add chr(0x80 or (code and 0x3F))
  else:
    result.add chr(0xF0 or (code shr 18))
    result.add chr(0x80 or ((code shr 12) and 0x3F))
    result.add chr(0x80 or ((code shr 6) and 0x3F))
    result.add chr(0x80 or (code and 0x3F))

proc fromLiteral(s: string): string =
  ## what a string literal says: its quotes taken off, \n \t \r \\ \" \' \xHH \u{…} read
  var t = s.strip
  if t.len >= 2 and t[0] == '"' and t[^1] == '"': t = t[1 .. ^2]
  var i = 0
  while i < t.len:
    if t[i] == '\\' and i + 1 < t.len:
      let c = t[i + 1]
      i += 2
      case c
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of '0': result.add '\0'
      of 'x':
        if i + 2 > t.len: raise newException(ValueError, "\\x takes two hex digits")
        result.add chr(parseHexInt(t[i ..< i + 2]))
        i += 2
      of 'u':
        var e = i
        if e < t.len and t[e] == '{':
          e = t.find('}', i)
          if e < 0: raise newException(ValueError, "\\u{ is not closed")
          result.add toUTF8Rune(parseHexInt(t[i + 1 ..< e]))
          i = e + 1
        else:
          if i + 4 > t.len: raise newException(ValueError, "\\u takes four hex digits")
          result.add toUTF8Rune(parseHexInt(t[i ..< i + 4]))
          i += 4
      else: result.add c
    else:
      result.add t[i]
      inc i

command "Transform: base64 encode": withText(proc(s: string): string = encode(s))
command "Transform: base64 decode": withText(proc(s: string): string = decode(s.strip))
command "Transform: URL encode": withText(proc(s: string): string = encodeUrl(s, usePlus = false))
command "Transform: URL decode": withText(proc(s: string): string = decodeUrl(s, decodePlus = true))
command "Transform: hex encode": withText(hexEncode)
command "Transform: hex decode": withText(hexDecode)
command "Transform: HTML escape": withText(htmlEscape)
command "Transform: HTML unescape": withText(htmlUnescape)
command "Transform: to a string literal": withText(toLiteral)
command "Transform: from a string literal": withText(fromLiteral)
command "Transform: upper case": withText(proc(s: string): string = s.toUpperAscii)
command "Transform: lower case": withText(proc(s: string): string = s.toLowerAscii)

# ── JSON ──

proc jsonAs(pretty: bool) =
  let b = current()
  let (r, s) = wholeOrSelection(b)
  var j: JsonNode
  try: j = parseJson(s)
  except CatchableError as e:
    warn("Not JSON: " & e.msg)
    return
  let t = if pretty: j.pretty(b.indentUnit.len.max(2)) else: $j
  if t != s.strip: b.replace(r, t)

command "Transform: pretty JSON": jsonAs(true)
command "Transform: one-line JSON": jsonAs(false)

# ── numbers, counts ──

func numbersIn*(s: string): seq[float] =
  ## the numbers written in a text: 3, -2.5, 1e3, 1_000 (a dash between words is no minus)
  var i = 0
  while i < s.len:
    let neg = s[i] == '-' and i + 1 < s.len and s[i + 1] in Digits and (i == 0 or s[i - 1] notin IdentChars)
    if s[i] in Digits or neg:
      let a = i
      if neg: inc i
      while i < s.len and (s[i] in Digits or s[i] == '_' or
            (s[i] == '.' and i + 1 < s.len and s[i + 1] in Digits) or
            (s[i] in {'e', 'E'} and i + 1 < s.len and s[i + 1] in Digits + {'-', '+'})):
        if s[i] in {'e', 'E'}: inc i
        inc i
      if a > 0 and s[a - 1] in IdentChars: continue           # (a digit in a name: x2)
      try: result.add parseFloat(s[a ..< i].replace("_", ""))
      except ValueError: discard
    else: inc i

func fmtNum(x: float): string =
  if x == float(int(x)) and abs(x) < 1e15: $int(x) else: formatFloat(x, ffDecimal, 6).strip(leading = false, chars = {'0'})

command "Transform: add up the numbers":
  let (_, s) = wholeOrSelection(current())
  let ns = numbersIn(s)
  if ns.len == 0: message("No numbers here")
  else:
    var sum = 0.0
    for x in ns: sum += x
    let t = "sum " & fmtNum(sum) & " · " & $ns.len & " numbers · mean " & fmtNum(sum / float(ns.len)) &
            " · min " & fmtNum(min(ns)) & " · max " & fmtNum(max(ns))
    message(t)
    setClipboard(fmtNum(sum))

command "Transform: count":
  let (_, s) = wholeOrSelection(current())
  var words = 0
  for w in s.splitWhitespace: inc words
  message($s.countLines & " lines · " & $words & " words · " & $s.len & " characters")
