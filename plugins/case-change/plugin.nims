## case-change — write the name at the cursor in another case: snake_case, camelCase, PascalCase, UPPER_CASE …
##
##   Case: to snake_case, to camelCase, to PascalCase, to UPPER_CASE, to kebab-case, to dot.case, to Title Case,
##   to space case     the name at the cursor (each cursor's), or the selected text — a selection on several lines:
##                     each name in it. HTTPServer → http_server, getHTTPResponse → get_http_response,
##                     utf8String → utf8_string; _private and __init__ keep their underscores
##   Case: the next case     snake_case → camelCase → PascalCase → UPPER_CASE → snake_case
##   Case: choose…           a list of the name in every case: tap the one you want
##   vim (normal mode, as vim-abolish)   crs snake_case · crc camelCase · crp crm PascalCase · cru crU UPPER_CASE ·
##                     crk cr- kebab-case · cr. dot.case · crt Title Case · cr<space> space case · crr the next case
##   In CSS, HTML, YAML, TOML and the Lisps a name at the cursor goes on over a - (font-size); elsewhere a - is
##   a minus: select a kebab-case name to change it.
import nedplugin
import std/algorithm

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")

type Style = enum sSnake, sCamel, sPascal, sUpper, sKebab, sDot, sTitle, sSpace

const
  StyleNames: array[Style, string] = ["snake_case", "camelCase", "PascalCase", "UPPER_CASE", "kebab-case",
                                      "dot.case", "Title Case", "space case"]
  Cycle = [sSnake, sCamel, sPascal, sUpper]
  Seps = {'_', '-', '.', ' ', '\t'}
  DashLangs = ["css", "scss", "sass", "less", "html", "xml", "yaml", "toml", "lisp", "clojure", "scheme", "racket",
               "elisp"]

func isIdent(c: char): bool = c in IdentChars or ord(c) >= 128
func isUp(c: char): bool = c in {'A' .. 'Z'}
func isLow(c: char): bool = c in {'a' .. 'z'}

func splitName(t: string): (string, seq[string], string) =
  ## the words of a name, in lower case, and what is before and after them (_private, __init__): at _ - . and
  ## spaces, and where the case changes — fooBar, HTTPServer (HTTP, Server), utf8String (utf8, String)
  var a = 0
  while a < t.len and t[a] in Seps: inc a
  var e = t.len
  while e > a and t[e - 1] in Seps: dec e
  var words: seq[string]
  var cur = ""
  for i in a ..< e:
    let ch = t[i]
    if ch in Seps:
      if cur.len > 0: words.add cur
      cur = ""
      continue
    if cur.len > 0:
      let p = t[i - 1]
      if ch.isUp and (p.isLow or p in Digits or (p.isUp and i + 1 < e and t[i + 1].isLow)):
        words.add cur
        cur = ""
    cur.add ch
  if cur.len > 0: words.add cur
  for w in words.mitems: w = w.toLowerAscii
  (t[0 ..< a], words, t[e .. ^1])

func joinHumps(ws: seq[string], firstLow: bool): string =
  for i, w in ws:
    # (two words that are both numbers at the join keep an underscore: x86_64 stays x86_64)
    if i > 0 and w[0] in Digits and ws[i - 1][^1] in Digits: result.add '_'
    result.add (if i == 0 and firstLow: w else: w.capitalizeAscii)

func inStyle(t: string, st: Style): string =
  ## the name t written in the style st
  let (pre, ws, post) = splitName(t)
  if ws.len == 0: return t
  let body = case st
    of sSnake: ws.join("_")
    of sCamel: joinHumps(ws, true)
    of sPascal: joinHumps(ws, false)
    of sUpper: ws.join("_").toUpperAscii
    of sKebab: ws.join("-")
    of sDot: ws.join(".")
    of sTitle:
      var r: seq[string]
      for w in ws: r.add w.capitalizeAscii
      r.join(" ")
    of sSpace: ws.join(" ")
  pre & body & post

func styleOf(t: string): Style =
  ## the style a name is written in (a one-word name in lower case counts as snake_case)
  var a = 0
  while a < t.len and t[a] in Seps: inc a
  var e = t.len
  while e > a and t[e - 1] in Seps: dec e
  let core = t[a ..< e]
  var up, low = false
  for c in core:
    if c.isUp: up = true
    elif c.isLow: low = true
  if ' ' in core: (if core.inStyle(sTitle) == core: sTitle else: sSpace)
  elif '-' in core: sKebab
  elif '.' in core: sDot
  elif up and not low: sUpper
  elif '_' in core: sSnake
  elif core.len > 0 and core[0].isUp: sPascal
  elif up: sCamel
  else: sSnake

func nextStyle(t: string): Style =
  ## the next style of the cycle that changes the name (snake → camel → Pascal → UPPER → snake)
  let st = styleOf(t)
  var k = Cycle.find(st)
  for _ in 0 ..< Cycle.len:
    k = (k + 1) mod Cycle.len
    if t.inStyle(Cycle[k]) != t: return Cycle[k]
  st

# ── what to change ──

proc wordSpan(s: string, c: int, dash: bool): (int, int) =
  ## the name at column c (or the next one on the line): letters, digits, _ — and - between them when dash
  proc w(i: int): bool =
    i >= 0 and i < s.len and (isIdent(s[i]) or
      (dash and s[i] == '-' and i > 0 and i + 1 < s.len and isIdent(s[i - 1]) and isIdent(s[i + 1])))
  var a = min(c, s.len)
  while a < s.len and not w(a): inc a
  if a >= s.len: return (-1, -1)
  while a > 0 and w(a - 1): dec a
  var e = a
  while e < s.len and w(e): inc e
  (a, e)

func before(a, b: Pos): bool = a.line < b.line or (a.line == b.line and a.col < b.col)

proc targets(b: Buf): seq[Range] =
  ## what to change: each selection (on one line its text, widened to whole names: one that ends inside a name
  ## takes all of it), each name of a selection on several lines, or the name at each cursor
  let dash = b.lang in DashLangs
  for r in b.selections:
    if r.isEmpty:
      let s = b.line(r.start.line)
      let (a, e) = wordSpan(s, r.start.col, dash)
      if a >= 0: result.add rng(pos(r.start.line, a), pos(r.start.line, e))
    elif r.start.line == r.stop.line:
      let s = b.line(r.start.line)
      var (a, e) = (r.start.col, min(r.stop.col, s.len))
      while a > 0 and a < s.len and isIdent(s[a - 1]) and isIdent(s[a]): dec a
      while e > 0 and e < s.len and isIdent(s[e - 1]) and isIdent(s[e]): inc e
      var phrase = true
      for ch in s[a ..< e]:
        if not (isIdent(ch) or ch in Seps): phrase = false
      if phrase: result.add rng(pos(r.start.line, a), pos(r.start.line, e))
      else:
        # (an expression: each name in it)
        var i = a
        while i < e:
          if isIdent(s[i]):
            var j = i
            while j < e and isIdent(s[j]): inc j
            result.add rng(pos(r.start.line, i), pos(r.start.line, j))
            i = j
          else: inc i
    else:
      let ls = b.lines(r.start.line, r.stop.line)
      for k, s in ls:
        let l = r.start.line + k
        let a0 = if k == 0: r.start.col else: 0
        let e0 = if l == r.stop.line: min(r.stop.col, s.len) else: s.len
        var i = a0
        while i > 0 and i < s.len and isIdent(s[i - 1]) and isIdent(s[i]): dec i
        while i < e0:
          if isIdent(s[i]):
            var j = i
            while j < s.len and isIdent(s[j]): inc j
            result.add rng(pos(l, i), pos(l, j))
            i = j
          else: inc i
  result.sort(proc(x, y: Range): int = (if before(y.start, x.start): -1 elif before(x.start, y.start): 1 else: 0))

proc changeTo(b: Buf, ts: seq[Range], style: proc(t: string): Style) =
  ## each target written in the style style(its text) gives — from the last one up: the others stay in place
  if ts.len == 0:
    message("Case: no name at the cursor")
    return
  var texts: seq[string]
  if ts.len == 1: texts = @[b.textIn(ts[0])]
  else:
    let ls = b.lines(ts[^1].start.line, ts[0].stop.line)
    for r in ts: texts.add ls[r.start.line - ts[^1].start.line][r.start.col ..< r.stop.col]
  var n = 0
  for i, r in ts:
    let t = texts[i]
    let nt = t.inStyle(style(t))
    if nt != t:
      b.replace(r, nt)
      inc n
  b.setCursor(ts[^1].start)
  if n == 0: message("Case: nothing to change — it is written so already")

proc styled(st: Style): proc(t: string): Style =
  ## (a factory: each command its own style)
  result = proc(t: string): Style = st

proc toStyle(st: Style) =
  let b = current()
  if b.valid: changeTo(b, targets(b), styled(st))

proc toNext() =
  let b = current()
  if b.valid: changeTo(b, targets(b), proc(t: string): Style = nextStyle(t))

proc choose() =
  ## the name in each case, in a list: the one chosen is what the targets become
  let b = current()
  if not b.valid: return
  let ts = targets(b)
  if ts.len == 0:
    message("Case: no name at the cursor")
    return
  let t = b.textIn(ts[^1])
  var items, details: seq[string]
  for st in Style:
    items.add t.inStyle(st)
    details.add StyleNames[st]
  let k = pick("Write " & t & " as", items, details)
  if k >= 0: changeTo(b, ts, styled(Style(k)))

proc caseCommand(st: Style) =
  ## (a factory: a palette command and its vim keys for one style — never made in a loop's body directly)
  command("Case: to " & StyleNames[st]): toStyle(st)

for st in Style: caseCommand(st)
command "Case: the next case (snake, camel, Pascal, UPPER)": toNext()
command "Case: choose…": choose()

# ── vim: vim-abolish's cr ──

proc crMap(keys: string, st: Style) =
  nmap(keys, "the name to " & StyleNames[st]) do (count: int): toStyle(st)

crMap("crs", sSnake)
crMap("crc", sCamel)
crMap("crp", sPascal)
crMap("crm", sPascal)
crMap("cru", sUpper)
crMap("crU", sUpper)
crMap("crk", sKebab)
crMap("cr-", sKebab)
crMap("cr.", sDot)
crMap("crt", sTitle)
crMap("cr<space>", sSpace)
nmap("crr", "the name to the next case") do (count: int): toNext()
