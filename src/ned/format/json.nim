# ── JSON (and JSON with comments): the text of every value is kept exactly; only the layout changes ──

type JTok* = object
  kind*: char        # '{' '}' '[' ']' ',' ':' 'v' value, 'c' comment (// or /* */)
  text*: string
  nl*: int           # line breaks just before it in the source

proc jsonToks*(s: string, err: var string): seq[JTok] =
  ## reads JSON (comments allowed) as tokens — brackets, commas, colons, whole values (strings, numbers, true, false,
  ## null; their text untouched) and comments — each with the number of line breaks before it; err is set for a string
  ## that runs past its line, an unclosed string or comment, or text that is not a value
  var i = 0
  var nl = 0
  template add(k: char, t: string) =
    ## adds a token of kind k with its text and the line breaks counted since the last token, and resets that count
    result.add JTok(kind: k, text: t, nl: nl)
    nl = 0
  while i < s.len:
    let c = s[i]
    case c
    of ' ', '\t', '\r': inc i
    of '\n':
      inc nl
      inc i
    of '{', '}', '[', ']', ',', ':':
      add(c, $c)
      inc i
    of '"':
      var j = i + 1
      while j < s.len and s[j] != '"':
        if s[j] == '\\': inc j
        elif s[j] == '\n':
          err = "a string runs past the end of its line (line " & $(s[0 ..< i].count('\n') + 1) & ")"
          return
        inc j
      if j >= s.len:
        err = "a string is not closed"
        return
      add('v', s[i .. j])
      i = j + 1
    of '/':
      if i + 1 < s.len and s[i + 1] == '/':
        var j = i
        while j < s.len and s[j] != '\n': inc j
        add('c', s[i ..< j].strip(leading = false))
        i = j
      elif i + 1 < s.len and s[i + 1] == '*':
        let e = s.find("*/", i + 2)
        if e < 0:
          err = "a comment is not closed"
          return
        add('c', s[i .. e + 1])
        i = e + 2
      else:
        err = "unexpected / (line " & $(s[0 ..< i].count('\n') + 1) & ")"
        return
    else:
      var j = i
      while j < s.len and s[j] notin {' ', '\t', '\r', '\n', '{', '}', '[', ']', ',', ':', '"', '/'}: inc j
      let w = s[i ..< j]
      if w.len == 0:
        err = "unexpected " & $c
        return
      if not (w in ["true", "false", "null"] or w[0] in {'-', '0'..'9'}):
        err = "unexpected `" & w & "` (line " & $(s[0 ..< i].count('\n') + 1) & ")"
        return
      add('v', w)
      i = j

proc fmtJson*(s: string, indent = 2, maxW = 80): (string, string) =
  ## (formatted text, error): one member per line, short arrays of plain values on one line, comments and
  ## single blank lines kept, every value's text exactly as it was (1e5 stays 1e5, big numbers stay whole)
  var err = ""
  let t = jsonToks(s, err)
  if err.len > 0: return (s, err)
  var nest, most = 0
  for k in t:
    if k.kind in {'{', '['}:
      inc nest
      most = max(most, nest)
    elif k.kind in {'}', ']'}: dec nest
  if most > FmtMaxNest:
    return (s, "nested " & $most & " deep: left as it is (more than " & $FmtMaxNest & ")")
  var o = ""
  var depth = 0
  var pending = false          # the next token starts a new line
  let ind = spaces(indent)
  proc newline(o: var string, d: int, blank: bool) =
    ## starts a new line in the output at depth d (with a blank line before it if asked), first removing spaces at the
    ## end of the line it leaves
    while o.len > 0 and o[^1] == ' ': o.setLen(o.len - 1)
    if o.len > 0:
      o.add "\n"
      if blank: o.add "\n"
    for _ in 0 ..< d: o.add ind
  var i = 0
  while i < t.len:
    let k = t[i]
    if pending and k.kind in {'{', '[', 'v'} or (k.kind == 'c' and k.nl > 0):
      o.newline(depth, k.nl >= 2)
      pending = false
    case k.kind
    of '{', '[':
      let close = if k.kind == '{': '}' else: ']'
      if i + 1 < t.len and t[i + 1].kind == close:
        o.add k.text & t[i + 1].text
        i += 2
        continue
      if k.kind == '[':
        # plain values that fit: on one line
        var j = i + 1
        var parts: seq[string]
        var flat = true
        while j < t.len and t[j].kind != ']':
          if t[j].kind == 'v': parts.add t[j].text
          elif t[j].kind != ',': flat = false
          inc j
        let line = "[" & parts.join(", ") & "]"
        if flat and j < t.len and o.len - (o.rfind('\n') + 1) + line.len + 1 <= maxW:
          o.add line
          i = j + 1
          continue
      o.add k.text
      inc depth
      pending = true
    of '}', ']':
      depth = max(0, depth - 1)
      o.newline(depth, false)
      o.add k.text
      pending = false
    of ',':
      o.add ","
      pending = true
    of ':': o.add ": "
    of 'v': o.add k.text
    of 'c':
      if k.nl == 0 and o.len > 0 and o[^1] notin {'\n', ' '}: o.add " "
      o.add k.text
      pending = true
    else: discard
    inc i
  var lines = o.split('\n')
  for l in lines.mitems: l = l.strip(leading = false)
  let res = lines.join("\n").strip(chars = {'\n'}) & "\n"
  # safety: the same tokens, in the same order
  var err2 = ""
  let t2 = jsonToks(res, err2)
  var a, b: seq[string]
  for x in t: a.add x.text
  for x in t2: b.add x.text
  if err2.len > 0 or a != b: return (s, "the formatted text would differ (please report this file)")
  (res, "")
