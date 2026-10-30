## align — line up the =, :, , or | of several lines (or any text you give) in one column
##
##   Align: on a character or text…   asks what to align on (= when you just press Enter; with a * in front, *=
##                     or *:, every one on the line and not only the first)
##   Align: on =   Align: on :   Align: on ,   Align: on | (table)
##   the lines         the selected lines, or the paragraph around the cursor (the lines that are not blank)
##   =                 the first = of each line, with what goes with it (+= := == != <= =>), its right side lined up
##   :                 the first : of each line, the colon after the key and the values lined up (a :: or := is
##                     not one) — key:   value
##   ,                 every , of the line: the columns of a list
##   |                 every | : a Markdown table, its rows and its |---| line (with dashes)
##   any text          its first one on each line: #, ->, //, AS …
##   An = (or anything) in a string or after the line's comment is not one; each line keeps its indentation; a line
##   without it is left as it is.
##   vim               ga{motion} or ga{text object}, then what to align on: gaip = (the paragraph), ga} :, gagg,
##                     gaii (with text-objects), gaa the line (3gaa three lines), ga on a visual selection
##   settings          plugins.align.all — every one on the line, not only the first (for = : and any text)
import nedplugin

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("all", false, "Align on every = (or :, or the text you give) of a line, not only the first one — " &
           ", and | are always every one")

const
  OpChars = {'=', '!', '<', '>', '+', '-', '*', '/', '%', ':', '&', '|', '^', '~', '?', '.', '@'}
  CharLitLangs = ["nim", "c", "cpp", "rust", "go", "java", "csharp", "kotlin", "zig", "odin", "haskell", "elixir",
                  "gleam", "scala", "swift", "dart"]

func width(s: string): int =
  ## how wide s is on the screen: its characters (not its bytes)
  for c in s:
    if (ord(c) and 0xC0) != 0x80: inc result

# s followed by fill characters up to w screen columns (unchanged when it is already that wide)
func padRight(s: string, w: int, fill = ' '): string = s & repeat(fill, max(0, w - width(s)))
# s with spaces in front of it up to w screen columns
func padLeft(s: string, w: int): string = repeat(' ', max(0, w - width(s))) & s

func codeMask(s, cm: string, charLit, keepComment: bool): string =
  ## each byte of the line: c code, s in a string (" ' `; in Nim, C, Rust … a ' only round a character), m the comment
  result = newString(s.len)
  var i = 0
  while i < s.len:
    let c = s[i]
    if not keepComment and cm.len > 0 and s.continuesWith(cm, i):
      for x in i ..< s.len: result[x] = 'm'
      return
    if c in {'"', '`'} or (c == '\'' and not charLit) or
       (c == '\'' and i + 2 < s.len and (s[i + 2] == '\'' or s[i + 1] == '\\')):
      var j = i + 1
      while j < s.len and s[j] != c:
        if s[j] == '\\' and c != '`': inc j
        inc j
      let e = min(s.len, j + 1)
      for x in i ..< e: result[x] = 's'
      i = e
      continue
    result[i] = 'c'
    inc i

type Found = object
  at: seq[int]                   ## where each delimiter starts
  toks: seq[string]              ## what it is there (= += :=)

func findDelims(s, mask, d: string, all: bool): Found =
  ## the delimiters d of the line (outside strings and the comment)
  var i = 0
  while i + d.len <= s.len:
    var code = true
    for x in i ..< i + d.len:
      if mask[x] != 'c': code = false
    if code and s.continuesWith(d, i):
      var a = i
      var e = i + d.len
      var ok = true
      if d == "=":
        # (with what goes with it: += := == != <= >= === =>)
        while a > 0 and s[a - 1] in OpChars and mask[a - 1] == 'c': dec a
        while e < s.len and s[e] in {'=', '>', '~'} and mask[e] == 'c': inc e
      elif d == ":":
        ok = not (i > 0 and s[i - 1] == ':') and not (e < s.len and s[e] in {':', '='})
      if ok:
        result.at.add a
        result.toks.add s[a ..< e]
        if not all: return
        i = e
        continue
    inc i

proc alignLines(b: Buf, first, last: int, d: string, all: bool) =
  ## lines first .. last aligned on d
  let ls = b.lines(first, last)
  let cm = b.lineComment
  let charLit = b.lang in CharLitLangs
  let stick = d in [":", ","]            # (key: value, a, b — the delimiter stays with what is before it)
  let table = d == "|"
  var cells, toks: seq[seq[string]]
  var have = 0
  for s in ls:
    let f = findDelims(s, codeMask(s, cm, charLit, d == cm), d, all)
    var cs: seq[string]
    if f.at.len > 0:
      inc have
      var a = 0
      for k, at in f.at:
        let c = s[a ..< at]
        cs.add (if k == 0: c.strip(leading = false) else: c.strip)
        a = at + f.toks[k].len
      cs.add s[a .. ^1].strip
    cells.add cs
    toks.add f.toks
  if have < 2:
    message("Align: fewer than two of the lines have " & d & " — nothing to line up")
    return
  # each column's width: the cells before a delimiter (with it, when it stays with them), and the delimiters'
  var w, tw: seq[int]
  for i, cs in cells:
    for k in 0 ..< toks[i].len:
      if w.len <= k:
        w.add 0
        tw.add 0
      w[k] = max(w[k], width(if stick: cs[k] & toks[i][k] else: cs[k]))
      tw[k] = max(tw[k], width(toks[i][k]))
  var outs: seq[string]
  for i, cs in cells:
    if cs.len == 0:
      outs.add ls[i]
      continue
    var o = ""
    for k in 0 ..< toks[i].len:
      let c = cs[k]
      let rule = table and k > 0 and c.len > 0 and c.strip(chars = {'-', ':'}).len == 0 and '-' in c
      if stick: o.add padRight(c & toks[i][k], w[k]) & " "
      elif k == 0 and c.strip.len == 0: o.add c & toks[i][k] & " "        # (a table row's | at its start)
      elif rule:
        # (a table's |---| line: dashes, a colon kept at its end)
        let colon = c.endsWith(":")
        o.add (if colon: c[0 ..< c.len - 1] else: c).padRight(w[k] - int(colon), '-') & (if colon: ":" else: "") &
              " " & padLeft(toks[i][k], tw[k]) & " "
      else: o.add padRight(c, w[k]) & " " & padLeft(toks[i][k], tw[k]) & " "
    o.add cs[^1]
    outs.add o.strip(leading = false)
  let now = outs.join("\n")
  if now != ls.join("\n"):
    b.replace(rng(pos(first, 0), pos(last, ls[^1].len)), now)
  message("Align: " & $have & " lines on " & d)

proc linesToAlign(b: Buf): (int, int) =
  ## the selected lines, or the paragraph around the cursor; (-1, -1) none
  let r = b.selection
  if not r.isEmpty:
    var last = r.stop.line
    if r.stop.col == 0 and last > r.start.line: dec last
    return (r.start.line, last)
  let ls = b.lines
  let l = r.start.line
  if ls[l].strip.len == 0: return (-1, -1)
  var (a, e) = (l, l)
  while a > 0 and ls[a - 1].strip.len > 0: dec a
  while e < ls.high and ls[e + 1].strip.len > 0: inc e
  (a, e)

proc parseAnswer(answer: string): (string, bool) =
  ## what to align on, and whether on every one: "*=" every =; ", and | always every one
  var d = answer.strip
  var all = setting("all", false)
  if d.len > 1 and d[0] == '*':
    d = d[1 .. ^1].strip
    all = true
  (d, all or d in [",", "|"])

proc alignCommand(answer: string) =
  ## the command behind every Align entry: takes the delimiter typed (or fixed by the entry), finds the selected lines
  ## or the paragraph around the cursor, and aligns them on it; says so in the message line when there is nothing to
  ## align
  let b = current()
  if not b.valid or answer.strip.len == 0: return
  let (first, last) = linesToAlign(b)
  if first < 0:
    message("Align: select the lines, or put the cursor in a paragraph")
    return
  let (d, all) = parseAnswer(answer)
  alignLines(b, first, last, d, all)

proc alignOn(d: string) =
  ## (a factory: one command for each delimiter)
  command("Align: on " & d & (if d == "|": " (table)" else: "")): alignCommand(d)

command "Align: on a character or text…":
  alignCommand(ask("Align on (* in front: every one on the line)", "="))
for d in ["=", ":", ",", "|"]: alignOn(d)

operator("ga", "align the lines on a character (asked)") do (b: Buf, r: Range, linewise: bool):
  var last = r.stop.line
  if not linewise and r.stop.col == 0 and last > r.start.line: dec last
  let answer = ask("Align on (* in front: every one on the line)", "=")
  if answer.strip.len > 0:
    let (d, all) = parseAnswer(answer)
    alignLines(b, r.start.line, last, d, all)
