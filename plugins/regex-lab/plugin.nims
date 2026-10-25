## regex-lab — try a regular expression on the file: its matches lit up, their groups beside them, a replace to check
##
##   Regex: try a pattern…          a pattern (the last one offered again) — its matches in the file (or the
##                                  selection) lit up, a ● in the gutter of each line with one, the groups of the
##                                  first match on a line after it (1="…" 2="…"), and how many in the status bar.
##                                  Again with an empty answer: the marks go
##   Regex: replace with a pattern…  a pattern, then what replaces it ($1 … $9 the groups, $0 the match, \n \t):
##                                  how many it changes is asked first; one undo step takes it back
##   Regex: explain the pattern…    what the pattern under the cursor (the string the cursor is in, or the
##                                  selection) does, a piece at a time — in a tab
##   Regex: clear the marks         the matches no longer lit up
## The patterns are ned's own (its search's): . [a-z] [^…] \d \w \s \b ^ $ * + ? {n,m} lazy *? groups (…) (?:…) |
## — the same in every file, with no program to install.
import nedplugin
import std/strutils

requiresNed(">= 6.27")

settingDef("ignoreCase", false, "Regex: try a pattern — upper and lower case the same")

var lastPattern = ""

func lineStarts(text: string): seq[int] =
  result = @[0]
  for i, c in text:
    if c == '\n': result.add i + 1

func posOf(starts: seq[int], off: int): Pos =
  ## a byte offset of the text → its line and column
  var lo = 0
  var hi = starts.high
  while lo < hi:
    let m = (lo + hi + 1) div 2
    if starts[m] <= off: lo = m else: hi = m - 1
  pos(lo, off - starts[lo])

proc scope(b: Buf): (string, int) =
  ## the text to work on (the selection, else the file) and where it starts in the file (an offset)
  let r = b.selection
  if r.isEmpty: return (b.text, 0)
  let all = b.text
  let starts = lineStarts(all)
  let a = starts[min(r.start.line, starts.high)] + r.start.col
  (b.textIn(r), a)

func shown(s: string): string =
  ## a group's text in one line, not too long
  var t = s.replace("\n", "\\n").replace("\t", "\\t")
  if t.len > 40: t = t[0 ..< 40] & "…"
  "\"" & t & "\""

proc tryPattern(b: Buf, pat: string) =
  b.clearDecorations()
  if pat.len == 0:
    status("")
    return
  let (text, base) = scope(b)
  var ms: seq[RegexMatch]
  try: ms = regexMatches(pat, text, setting("ignoreCase", false))
  except ValueError as e:
    warn(e.msg)
    return
  let all = if base == 0: text else: b.text
  let starts = lineStarts(all)
  var lines: seq[int]
  for m in ms:
    let a = posOf(starts, base + m.start)
    let e = posOf(starts, base + m.stop)
    b.highlight(rng(a, e), "accent")
    if a.line notin lines:
      lines.add a.line
      b.sign(a.line, "●", "accent")
      if m.groups.len > 0:
        var parts: seq[string]
        for k, (g0, g1) in m.groups:
          parts.add $(k + 1) & "=" & (if g0 < 0: "—" else: shown(text[g0 ..< g1]))
        b.virtualText(a.line, parts.join("  "))
  status($ms.len & (if ms.len == 1: " match" else: " matches") & " of /" & pat & "/" &
         (if lines.len > 1: " on " & $lines.len & " lines" else: ""))
  if ms.len > 0 and base == 0:
    # (the first match after the cursor shown)
    let c = b.cursor
    for m in ms:
      let a = posOf(starts, m.start)
      if a.line > c.line or (a.line == c.line and a.col >= c.col):
        b.setCursor(a)
        break

command "Regex: try a pattern…":
  let b = current()
  let pat = ask("Regular expression", lastPattern)
  lastPattern = pat
  tryPattern(b, pat)

command "Regex: clear the marks":
  current().clearDecorations()
  status("")

proc replaceWith() =
  let b = current()
  let pat = ask("Replace (a regular expression)", lastPattern)
  if pat.len == 0: return
  lastPattern = pat
  let with = ask("With ($1 … $9 the groups, $0 the match)", "")
  let (text, base) = scope(b)
  var res: tuple[text: string, count: int]
  try: res = regexReplace(pat, text, with, setting("ignoreCase", false))
  except ValueError as e:
    warn(e.msg)
    return
  if res.count == 0:
    message("No match of /" & pat & "/")
    return
  if not confirm("Replace " & $res.count & (if res.count == 1: " match" else: " matches") & "?"): return
  if base == 0 and b.selection.isEmpty: b.setText(res.text)
  else: b.replace(b.selection, res.text)
  b.clearDecorations()
  message("Replaced " & $res.count)

command "Regex: replace with a pattern…":
  replaceWith()

# ── what a pattern does, a piece at a time ──

func classWords(body: string): string =
  ## [a-z0-9_] in words
  var neg = false
  var s = body
  if s.startsWith("^"):
    neg = true
    s = s[1 .. ^1]
  var parts: seq[string]
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      parts.add (case s[i + 1]
                 of 'd': "a digit"
                 of 'w': "a letter, digit or _"
                 of 's': "a space"
                 of 'n': "a line end"
                 of 't': "a tab"
                 else: "'" & s[i + 1] & "'")
      i += 2
    elif i + 2 < s.len and s[i + 1] == '-':
      parts.add s[i] & "–" & s[i + 2]
      i += 3
    else:
      parts.add "'" & s[i] & "'"
      inc i
  (if neg: "any character but " else: "one of ") & parts.join(", ")

func quantWords(q: string): string =
  let lazy = q.len > 1 and q[^1] == '?' and q[0] != '?'
  let core = if lazy: q[0 ..< q.high] else: q
  result = case core
           of "*": "any number of times (none too)"
           of "+": "once or more"
           of "?": "or not at all"
           else:
             let inner = core.strip(chars = {'{', '}'})
             if ',' notin inner: inner & " times"
             elif inner.endsWith(","): inner[0 ..< inner.high] & " times or more"
             else: "from " & inner.replace(",", " to ") & " times"
  if lazy: result.add ", as few as it can"

proc explain*(pat: string): seq[string] =
  ## the pattern, a piece at a time: (what is written, what it does)
  var i = 0
  var group = 0
  var depth = 0
  template put(piece, words: string) =
    result.add spaces(depth * 2) & alignLeft(piece, 12) & "  " & words
  while i < pat.len:
    let c = pat[i]
    var piece = ""
    var words = ""
    case c
    of '\\':
      piece = pat[i .. min(i + 1, pat.high)]
      words = if i + 1 < pat.len:
                (case pat[i + 1]
                 of 'd': "a digit"
                 of 'D': "anything but a digit"
                 of 'w': "a letter, a digit or _"
                 of 'W': "anything but a letter, a digit or _"
                 of 's': "a space, a tab or a line end"
                 of 'S': "anything but a space"
                 of 'b': "where a word starts or ends"
                 of 'B': "not where a word starts or ends"
                 of 'n': "a line end"
                 of 't': "a tab"
                 of '1'..'9': "what group " & pat[i + 1] & " matched, again"
                 else: "the character '" & pat[i + 1] & "' itself")
              else: "a \\ at the end (nothing after it)"
      i += 2
    of '[':
      var e = i + 1
      if e < pat.len and pat[e] == '^': inc e
      if e < pat.len and pat[e] == ']': inc e
      while e < pat.len and pat[e] != ']':
        if pat[e] == '\\': inc e
        inc e
      piece = pat[i .. min(e, pat.high)]
      words = classWords(pat[i + 1 ..< min(e, pat.len)])
      i = e + 1
    of '(':
      if pat.continuesWith("(?:", i):
        piece = "(?:"
        words = "a group that is not numbered"
        i += 3
      else:
        inc group
        piece = "("
        words = "group " & $group & " starts"
        inc i
      put(piece, words)
      inc depth
      continue
    of ')':
      depth = max(0, depth - 1)
      piece = ")"
      words = "the group ends"
      inc i
    of '|': (piece, words) = ("|", "or")
    of '.': (piece, words) = (".", "any character (not a line end)")
    of '^': (piece, words) = ("^", "the start of a line")
    of '$': (piece, words) = ("$", "the end of a line")
    else:
      var e = i
      while e < pat.len and pat[e] notin {'\\', '[', '(', ')', '|', '.', '^', '$', '*', '+', '?', '{'}: inc e
      # (a quantifier after it takes only the last character)
      if e < pat.len and pat[e] in {'*', '+', '?', '{'} and e - i > 1: e = e - 1
      if e == i: e = i + 1
      piece = pat[i ..< e]
      words = "the text \"" & piece & "\""
      i = e
    if c in {'|', '.', '^', '$'}: inc i
    # its quantifier
    if i < pat.len and pat[i] in {'*', '+', '?', '{'}:
      var e = i + 1
      if pat[i] == '{':
        while e < pat.len and pat[e] != '}': inc e
        inc e
      if e < pat.len and pat[e] == '?': inc e
      let q = pat[i ..< min(e, pat.len)]
      piece.add q
      words.add " — " & quantWords(q)
      i = e
    put(piece, words)

proc patternAt(b: Buf): string =
  ## the selection, else the string the cursor is in, else the last pattern tried
  let r = b.selection
  if not r.isEmpty: return b.textIn(r)
  let c = b.cursor
  let s = b.line(c.line)
  for q in ['"', '\'', '`', '/']:
    var a = c.col
    while a > 0 and s[a - 1] != q: dec a
    if a == 0: continue
    var e = c.col
    while e < s.len and s[e] != q: inc e
    if e < s.len and e > a: return s[a ..< e]
  lastPattern

proc explainHere() =
  let b = current()
  var pat = patternAt(b)
  if pat.len == 0: pat = ask("Regular expression", "")
  if pat.len == 0: return
  var t = "/" & pat & "/\n\n" & explain(pat).join("\n") & "\n"
  try:
    discard regexMatches(pat, "")
  except ValueError as e:
    t.add "\n" & e.msg & "\n"
  discard newTab("regex: " & (if pat.len > 24: pat[0 ..< 24] & "…" else: pat), t)

command "Regex: explain the pattern…":
  explainHere()
