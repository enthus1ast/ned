# ── YAML and TOML: careful formatters — only the layout changes, never what the file says, and each checks
#    its own result (the same words in the same order and, for YAML, the same nesting) ──

func yamlBlockScalarStart(t: string): bool =
  ## `key: |`, `- >-`, `key: |+  # note` …: the lines below are text, kept as they are (shifted as one)
  var s = t
  let h = s.find(" #")
  if h >= 0: s = s[0 ..< h]
  s = s.strip(leading = false)
  if s.len == 0: return false
  var k = s.high
  while k >= 0 and s[k] in {'+', '-', '0'..'9'}: dec k
  k >= 0 and s[k] in {'|', '>'} and (k == 0 or s[k - 1] == ' ')

proc yamlWords(lines: openArray[string]): seq[string] =
  ## what the file says, without its layout: each line's text, its runs of spaces made one
  for l in lines:
    let t = l.strip
    if t.len == 0: continue
    result.add t.splitWhitespace.join(" ")

proc fmtYaml*(s: string, indent = 2): (string, string) =
  ## YAML: one indentation width (`indent`) for every level — a sequence written at its key's column stays
  ## there — no spaces at line ends, at most one blank line in a row, `key:   value` → `key: value`. Text blocks
  ## (`|`, `>`) move with their key and keep their own layout; flow collections over several lines, tabs and
  ## indentation indicators (`|2`) leave the file as it is
  if '\t' in s or '\r' in s: return (s, "")
  let src = s.split('\n')
  var outp: seq[string]
  var stack: seq[(int, int)] = @[(0, 0)]       # (indentation in the file, indentation written)
  var i = 0
  var blanks = 0
  var flowDepth = 0
  while i < src.len:
    let raw = src[i]
    let t = raw.strip
    if t.len == 0:
      inc blanks
      if blanks <= 1 and outp.len > 0: outp.add ""
      inc i
      continue
    blanks = 0
    let ind = raw.len - raw.strip(trailing = false).len
    if flowDepth > 0:
      # inside [ … ] or { … } over several lines: as written
      outp.add raw.strip(leading = false)
      for c in t:
        if c in {'[', '{'}: inc flowDepth
        elif c in {']', '}'}: dec flowDepth
      inc i
      continue
    if t.startsWith("#") or t == "---" or t == "..." or t.startsWith("%"):
      # a comment: at the indentation of what follows it; markers and directives at the start
      var nxt = i + 1
      while nxt < src.len and (src[nxt].strip.len == 0 or src[nxt].strip.startsWith("#")): inc nxt
      var at = 0
      if not (t == "---" or t == "..." or t.startsWith("%")) and nxt < src.len:
        let ni = src[nxt].len - src[nxt].strip(trailing = false).len
        var k = stack.high
        while k > 0 and stack[k][0] > ni: dec k
        at = if stack[k][0] == ni: stack[k][1] elif ni > stack[k][0]: stack[k][1] + indent else: stack[k][1]
      if t == "---" or t == "...": stack = @[(0, 0)]
      outp.add spaces(at) & t
      inc i
      continue
    while stack.len > 1 and stack[^1][0] > ind: stack.setLen(stack.len - 1)
    var newInd: int
    if stack[^1][0] == ind: newInd = stack[^1][1]
    else:
      newInd = stack[^1][1] + indent
      stack.add (ind, newInd)
    # one space after a mapping key's colon (a plain key, not in quotes or brackets)
    var text = t
    block spacing:
      var k = 0
      if text.startsWith("- "): k = 2
      var e = k
      while e < text.len and text[e] notin {':', ' ', '"', '\'', '[', '{', '#'}: inc e
      if e < text.len and text[e] == ':' and e + 2 < text.len and text[e + 1] == ' ' and text[e + 2] == ' ':
        var v = e + 1
        while v < text.len and text[v] == ' ': inc v
        if v < text.len and text[v] != '#': text = text[0 .. e] & " " & text[v .. ^1]
    outp.add spaces(newInd) & text
    # a sequence item's content (`- key: v`) is a level of its own, where the text after the dash starts: the
    # item's other keys line up with it
    var keyOff = 0                                  # (where the key starts after the dashes)
    block items:
      var off = 0
      while off + 1 < t.len and t[off] == '-' and t[off + 1] == ' ':
        inc off
        while off < t.len and t[off] == ' ': inc off
        if off < t.len and t[off] != '#':
          stack.add (ind + off, newInd + off)
          keyOff = off
    # a flow collection that goes on below
    var depth = 0
    var q = ' '
    for c in t:
      if q != ' ':
        if c == q: q = ' '
      elif c in {'"', '\''}: q = c
      elif c == '#': break
      elif c in {'[', '{'}: inc depth
      elif c in {']', '}'}: dec depth
    if depth > 0: flowDepth = depth
    if yamlBlockScalarStart(t):
      let hdr = t.strip
      let lastC = hdr[^1]
      if lastC in Digits: return (s, "")             # (an indentation indicator: left as it is)
      # the text block: its lines (and blank lines among them) shifted as one, after its key
      var j = i + 1
      var base = -1
      while j < src.len:
        let r2 = src[j]
        if r2.strip.len == 0:
          inc j
          continue
        let i2 = r2.len - r2.strip(trailing = false).len
        if i2 <= ind: break
        if base < 0: base = i2
        if i2 < base: break
        inc j
      # (trailing blank lines belong after the block)
      var last = j - 1
      while last > i and src[last].strip.len == 0: dec last
      if base >= 0:
        # (deeper than its key; the text exactly as it is, spaces at line ends too — they are part of it)
        let target = newInd + keyOff + indent
        for k2 in i + 1 .. last:
          let r2 = src[k2]
          if r2.strip.len == 0: outp.add (if r2.len > base: spaces(target) & r2[base .. ^1] else: "")
          else: outp.add spaces(target) & r2[base .. ^1]
      i = last + 1
      continue
    inc i
  while outp.len > 0 and outp[^1].len == 0: outp.setLen(outp.len - 1)
  let res = outp.join("\n") & "\n"
  # the check: the same words in the same order (only spaces moved)
  let before = yamlWords(src)
  let after = yamlWords(outp)
  if before.len != after.len: return (s, "the YAML formatter would change more than the layout — left as it is")
  for k in 0 ..< before.len:
    if before[k] != after[k] and before[k].replace(" ", "") != after[k].replace(" ", ""):
      return (s, "the YAML formatter would change more than the layout — left as it is")
  (res, "")

proc tomlCode(s: string): string =
  ## what a TOML line says, without its spaces (outside strings) — for the check
  var q = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if q.len > 0:
      result.add c
      if c == '\\' and q == "\"" and i + 1 < s.len:
        result.add s[i + 1]
        i += 2
        continue
      if s.continuesWith(q, i):
        if q.len == 3:
          result.add s[i + 1 .. i + 2]
          i += 3
          q = ""
          continue
        q = ""
    elif s.continuesWith("\"\"\"", i) or s.continuesWith("'''", i):
      q = s[i .. i + 2]
      result.add q
      i += 3
      continue
    elif c in {'"', '\''}:
      q = $c
      result.add c
    elif c notin {' ', '\t', '\n', '\r'}: result.add c
    inc i

proc fmtToml*(s: string): (string, string) =
  ## TOML: `key = value` with one space around `=`, `[table]` headers without inner spaces and a blank line
  ## before each (but the first), `[1,2]` → `[1, 2]`, no spaces at line ends, at most one blank line in a row.
  ## Strings (multi-line ones too) and comments stay as they are; the result is checked to say the same
  let src = s.split('\n')
  var outp: seq[string]
  var inMulti = ""                                  # inside a """ or ''' string over several lines
  var arrayDepth = 0                                # inside an array over several lines
  for raw in src:
    if inMulti.len > 0:
      outp.add raw
      if raw.count(inMulti) mod 2 == 1: inMulti = ""
      continue
    let t = raw.strip
    if t.len == 0:
      if outp.len > 0 and outp[^1].len > 0: outp.add ""
      continue
    if t.startsWith("#"):
      outp.add (if arrayDepth > 0: raw.strip(leading = false) else: t)
      continue
    if arrayDepth == 0 and t.startsWith("[") and not t.startsWith("[["):
      # a table header
      let close = t.find(']')
      if close > 0:
        let name = t[1 ..< close].strip
        if outp.len > 0 and outp[^1].len > 0: outp.add ""
        outp.add "[" & name & "]" & t[close + 1 .. ^1]
        continue
    if arrayDepth == 0 and t.startsWith("[["):
      let close = t.find("]]")
      if close > 0:
        if outp.len > 0 and outp[^1].len > 0: outp.add ""
        outp.add "[[" & t[2 ..< close].strip & "]]" & t[close + 2 .. ^1]
        continue
    # a key = value line (or a line of an array that goes on): spaces normalized outside strings
    let startDepth = arrayDepth
    var o = ""
    var q = ""
    var i = 0
    while i < t.len:
      let c = t[i]
      if q.len > 0:
        o.add c
        if c == '\\' and q == "\"" and i + 1 < t.len:
          o.add t[i + 1]
          i += 2
          continue
        if t.continuesWith(q, i) and q.len == 1:
          q = ""
        elif q.len == 3 and t.continuesWith(q, i):
          o.add t[i + 1 .. i + 2]
          i += 3
          q = ""
          continue
        inc i
        continue
      if t.continuesWith("\"\"\"", i) or t.continuesWith("'''", i):
        q = t[i .. i + 2]
        o.add q
        i += 3
        continue
      case c
      of '"', '\'':
        q = $c
        o.add c
      of '#':
        o = o.strip(leading = false) & " " & t[i .. ^1]
        break
      of '=':
        o = o.strip(leading = false) & " = "
        while i + 1 < t.len and t[i + 1] == ' ': inc i
      of ',':
        o = o.strip(leading = false) & ","
        if i + 1 < t.len and t[i + 1] notin {']', '}'}:
          o.add " "
          while i + 1 < t.len and t[i + 1] == ' ': inc i
      of '[', '{':
        inc arrayDepth
        o.add c
      of ']', '}':
        dec arrayDepth
        o = o.strip(leading = false)
        if o.endsWith(", "): o.setLen(o.len - 1)
        o.add c
      else: o.add c
      inc i
    if q.len == 3: inMulti = q                      # (a multi-line string starts here)
    if arrayDepth < 0: return (s, "")
    # (a line of an array that goes on keeps its indentation; a key starts the line)
    outp.add (if startDepth > 0: raw[0 ..< raw.len - raw.strip(trailing = false).len] else: "") & o.strip(leading = false)
  while outp.len > 0 and outp[^1].len == 0: outp.setLen(outp.len - 1)
  let res = outp.join("\n") & "\n"
  if tomlCode(res) != tomlCode(s): return (s, "the TOML formatter would change more than the layout — left as it is")
  (res, "")
