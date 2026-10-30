# ── CSS (and SCSS / Less): one declaration per line, blocks indented, `prop: value;` ──

func cssSquash*(s: string): string =
  ## the text with whitespace outside strings and comments removed, ; before } dropped, for the safety check
  var i = 0
  while i < s.len:
    let c = s[i]
    if c in {'"', '\''}:
      var j = i + 1
      while j < s.len and s[j] != c:
        if s[j] == '\\': inc j
        inc j
      result.add s[i .. min(j, s.high)]
      i = j + 1
    elif c == '/' and i + 1 < s.len and s[i + 1] == '*':
      let e = s.find("*/", i + 2)
      let stop = if e < 0: s.len else: e + 2
      for ch in s[i ..< stop]:
        if ch notin Whitespace: result.add ch
      i = stop
    elif c in Whitespace: inc i
    else:
      result.add c
      inc i
  result = result.replace(";}", "}")

proc fmtCss*(s: string, indent = 2, lineComments = false): (string, string) =
  ## (lineComments: SCSS and Less have // comments)
  var o = ""
  var par = 0             # inside ( ): url(data:…;base64,…) keeps its ; and //
  var depth = 0
  let ind = spaces(indent)
  var cur = ""            # the selector or declaration being read
  var blankBefore = false # the source had a blank line before it
  var i = 0
  var nls = 0
  proc lineOut(o: var string, d: int, text: string) =
    ## adds one line to the output: the text indented d levels, then a line break
    for _ in 0 ..< d: o.add ind
    o.add text
    o.add "\n"
  proc squashWs(x: string): string =
    ## runs of whitespace → one space (strings kept)
    var j = 0
    var sp = false
    while j < x.len:
      let c = x[j]
      if c in {'"', '\''}:
        if sp and result.len > 0: result.add ' '
        sp = false
        var k = j + 1
        while k < x.len and x[k] != c:
          if x[k] == '\\': inc k
          inc k
        result.add x[j .. min(k, x.high)]
        j = k + 1
      elif c in Whitespace:
        sp = true
        inc j
      else:
        if sp and result.len > 0: result.add ' '
        sp = false
        result.add c
        inc j
    result = result.strip
  proc commaSpace(x: string): string =
    ## a, b — one space after each comma outside strings, none before
    var j = 0
    while j < x.len:
      let c = x[j]
      if c in {'"', '\''}:
        var k = j + 1
        while k < x.len and x[k] != c:
          if x[k] == '\\': inc k
          inc k
        result.add x[j .. min(k, x.high)]
        j = k + 1
        continue
      if (c == 'u' or c == 'U') and x.continuesWith("rl(", j + 1) or x.continuesWith("RL(", j + 1):
        # url(…): as it is (a comma or a space there is part of the address)
        let e = x.find(')', j)
        let stop = if e < 0: x.len else: e + 1
        result.add x[j ..< stop]
        j = stop
        continue
      if c == ',':
        while result.len > 0 and result[^1] == ' ': result.setLen(result.len - 1)
        result.add ", "
        inc j
        while j < x.len and x[j] == ' ': inc j
        continue
      result.add c
      inc j
  proc blank(o: var string) =
    ## adds the blank line the source had before the next item, but never right after a `{` or another blank line
    if blankBefore and o.len > 0 and not o.endsWith("{\n") and not o.endsWith("\n\n"): o.add "\n"
    blankBefore = false
  proc flushDecl(o: var string) =
    ## writes out the declaration read so far as one line ending in `;`: whitespace squeezed, `property: value` with one
    ## space after the colon and after each comma in the value; text that does not look like a property is written as it
    ## is with the `;`
    let d = squashWs(cur)
    cur = ""
    if d.len == 0: return
    o.blank()
    # prop: value (a property name: letters, digits, -, _, $, @ for Less/SCSS variables, -- custom properties)
    let c = d.find(':')
    if c > 0 and d[0 ..< c].strip.allCharsInSet(IdentChars + {'-', '$', '@', '*'}):
      o.lineOut(depth, d[0 ..< c].strip & ": " & commaSpace(d[c + 1 .. ^1].strip) & ";")
    else:
      o.lineOut(depth, d & ";")
  while i < s.len:
    let c = s[i]
    if c in {'"', '\''}:
      var j = i + 1
      while j < s.len and s[j] != c:
        if s[j] == '\\': inc j
        elif s[j] == '\n': break
        inc j
      cur.add s[i .. min(j, s.high)]
      i = j + 1
      nls = 0
      continue
    if c == '/' and i + 1 < s.len and s[i + 1] == '*':
      let e = s.find("*/", i + 2)
      let stop = if e < 0: s.len else: e + 2
      let com = s[i ..< stop]
      if cur.strip.len > 0:
        cur.add com                         # inside a selector or a value: it stays there
      else:
        o.blank()
        # its own lines, re-indented
        var first = true
        for cl in com.splitLines:
          let t = cl.strip
          o.lineOut(depth, (if first: t else: (if t.startsWith("*"): " " & t else: t)))
          first = false
      i = stop
      nls = 0
      continue
    if lineComments and par == 0 and c == '/' and i + 1 < s.len and s[i + 1] == '/' and (i == 0 or s[i - 1] != ':'):
      # SCSS / Less line comments (not the // of a url's scheme)
      var j = i
      while j < s.len and s[j] != '\n': inc j
      if cur.strip.len > 0: cur.add s[i ..< j] & "\n"
      else:
        o.blank()
        o.lineOut(depth, s[i ..< j].strip)
      i = j
      continue
    if par > 0 and c notin {'(', ')'}:
      cur.add (if c in Whitespace: ' ' else: c)
      inc i
      continue
    case c
    of '(':
      inc par
      cur.add c
    of ')':
      par = max(0, par - 1)
      cur.add c
    of '\n':
      inc nls
      if nls >= 2 and cur.strip.len == 0: blankBefore = true
      cur.add ' '
    of '{':
      let sel = squashWs(cur)
      cur = ""
      o.blank()
      # selectors: one per line (outside parentheses: :is(a, b) stays)
      var parts: seq[string]
      var d = 0
      var p = ""
      for ch in sel:
        if ch == '(' or ch == '[': inc d
        elif ch == ')' or ch == ']': dec d
        if ch == ',' and d == 0 and not sel.startsWith("@"):
          parts.add p.strip
          p = ""
        else: p.add ch
      parts.add p.strip
      for k, pt in parts:
        if k < parts.high: o.lineOut(depth, pt & ",")
        else:
          for _ in 0 ..< depth: o.add ind
          o.add (if pt.len > 0: pt & " {" else: "{")
          o.add "\n"
      inc depth
      nls = 0
    of '}':
      o.flushDecl()
      depth = max(0, depth - 1)
      o.lineOut(depth, "}")
      blankBefore = false
      nls = 0
    of ';':
      o.flushDecl()
      nls = 0
    else:
      if c notin Whitespace: nls = 0
      cur.add c
    inc i
  if squashWs(cur).len > 0: o.flushDecl()
  let res = o.strip(chars = {'\n'}) & "\n"
  if depth != 0: return (s, "the braces do not match")
  if cssSquash(res) != cssSquash(s): return (s, "the formatted text would differ (please report this file)")
  (res, "")
