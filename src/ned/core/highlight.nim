# ════════════════════════════════════════════════════════════════════════════
#  Syntax highlighting (incremental, per-line state machine)
# ════════════════════════════════════════════════════════════════════════════

const
  stNormal = 0'u8      # 1..31 block comment depth, 33..63 doc block comment depth
  stTriple2 = 64'u8    # inside """
  stTriple1 = 65'u8    # inside '''
  stBacktick = 66'u8   # inside JS template string
  stFence = 67'u8      # inside markdown code fence
  stHtmlComment = 68'u8


# ── code of one language inside another: Nim's {.emit.}, sql"…", HTML in a Nim string, Markdown code blocks,
#    <script> and <style>. The line state then carries the inner language's own state (LexSt), so a block that
#    spans lines is coloured right and incremental re-colouring still works line by line.
proc embedId(langId: string, ends: EmbedEnd, tag = "", fmt = false): int =
  for i in 1 ..< embeds.len:
    if embeds[i].langId == langId and embeds[i].ends == ends and embeds[i].tag == tag and embeds[i].fmt == fmt:
      return i
  if embeds.len >= 256: return 0
  embeds.add EmbedDesc(langId: langId, ends: ends, tag: tag, fmt: fmt)
  embeds.high

proc embedLang(id: string): Lang =
  if id.len == 0: return nil
  result = embedLangCache.getOrDefault(id)
  if result != nil: return
  for l in pseudoLangs:
    if l.id == id: result = l
  if result == nil: result = langByName(id)
  if result != nil: embedLangCache[id] = result

proc langForWord(w: string): Lang =
  ## a language named the way people write it: html, c, c++, js, sql, json, css, xml, py, sh, regex …
  let x = w.strip.toLowerAscii
  if x.len == 0 or x.len > 30: return nil
  result = embedLang(case x
    of "c++": "cpp"
    of "js": "javascript"
    of "ts": "typescript"
    of "xml", "svg", "xhtml": "html"
    of "regexp": "regex"
    else: x)
  if result == nil:
    let l = detectLang("x." & x, "")
    if l != nil and l.id != "plaintext": result = l
  if result != nil and result.id == "plaintext": result = nil

proc stTop(st: LexSt): int {.inline.} = int((st shr 8) and 0xFF)
proc stInner(st: LexSt): LexSt {.inline.} = ((st shr 16) shl 8) or (st and 0xFF)
proc stWrap(id: int, inner: LexSt): LexSt =
  ## inside embedding `id`, with the inner language in state `inner`
  if (inner shr 24) != 0: return LexSt(id) shl 8      # nested four deep: the innermost starts over
  (inner and 0xFF) or ((inner shr 8) shl 16) or (LexSt(id) shl 8)

proc findNoCase(s, pat: string, start: int): int =
  for i in start .. s.len - pat.len:
    var ok = true
    for k in 0 ..< pat.len:
      if toLowerAscii(s[i + k]) != pat[k]:
        ok = false
        break
    if ok: return i
  -1

proc sniffLang(t: string): string =
  ## the language of a string's text, judged by how it starts ("" — plain text)
  let s = t.strip(trailing = false)
  if s.len >= 2 and s[0] == '<' and (s[1] in {'a'..'z', 'A'..'Z', '!', '/', '?'}): return "html"
  var w = 0
  while w < s.len and s[w] in {'A'..'Z'}: inc w
  if w >= 4 and (w == s.len or s[w] in {' ', '\t'}) and
     s[0 ..< w] in ["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "DROP", "ALTER", "WITH", "PRAGMA", "REPLACE"]:
    return "sql"
  ""

proc lexInto(lang: Lang, s: string, st: LexSt, toks: var seq[TokKind], start = 0): LexSt

proc lexSub(l: Lang, s: string, a, e: int, toks: var seq[TokKind], foreign: bool) =
  ## s[a ..< e] coloured as language `l` (one line, from its normal state)
  if e <= a: return
  let sub = s[a ..< e]
  var st = newSeq[TokKind](sub.len)
  lexLangs.add (lexOff + a, lexOff + e, lexDepth + 1, l)
  let off0 = lexOff
  lexOff += a
  inc lexDepth
  discard lexInto(l, sub, 0, st)
  dec lexDepth
  lexOff = off0
  for q in 0 ..< sub.len: toks[a + q] = st[q]
  if foreign and lexDepth == 0: lexForeign.add (a, e)

const NimEmbedNames = [("sql", "sql"), ("re", "regex"), ("rex", "regex"), ("peg", "peg"), ("fmt", "nimfmt"),
                       ("parseJson", "json"), ("html", "html"), ("css", "css"), ("js", "javascript"),
                       ("parseXml", "html"), ("parseHtml", "html")]

proc nimEmbedName(w: string): string =
  if w in cfgEmbedded: return cfgEmbedded[w]
  for (k, v) in NimEmbedNames:
    if k == w: return v
  "-"                                          # a name we know nothing about: a plain string

proc nimStringLang(s: string, i: int, emitCtx: bool): string =
  ## what the Nim string literal starting at s[i] holds: a language word, "-" (plain text, say so) or ""
  ## (nothing says: its text decides). Checked: {.emit.}, a generalized raw string (sql"…", re"…"), &"…",
  ## a #[lang]# marker just before it, or the routine it is passed to (parseJson("…"), render """…""")
  if emitCtx:
    return (case cfgNimTarget
      of "cpp": "cpp"
      of "js": "javascript"
      else: "c")
  var j = i
  while j > 0 and isWordByte(s[j-1]): dec j
  if j < i:
    let w = s[j ..< i]
    if w in ["r", "R"]: return ""               # r"""…""" is only a raw string: its text decides
    return nimEmbedName(w)
  if i > 0 and s[i-1] == '&' and (i < 2 or s[i-2] in {' ', '\t', '(', '[', ',', '=', ':'}): return "nimfmt"
  var k = i - 1
  while k >= 0 and s[k] in {' ', '\t'}: dec k
  if k >= 3 and s[k] == '#' and s[k-1] == ']':
    let a = s.rfind("#[", last = k - 2)
    if a >= 0 and k - 2 >= a + 2: return s[a + 2 .. k - 2].strip
    return ""
  if k >= 0 and s[k] == '(':
    dec k
    while k >= 0 and s[k] in {' ', '\t'}: dec k
  let e = k + 1
  while k >= 0 and isWordByte(s[k]): dec k
  if e > k + 1:
    let w = s[k + 1 ..< e]
    if w in cfgEmbedded: return cfgEmbedded[w]
    for (n, v) in NimEmbedNames:
      if n == w: return v
  ""

proc nimEmbedLang(name: string): Lang =
  if name.len == 0 or name == "-": nil else: langForWord(name)

proc htmlLang(): Lang = embedLang("html")
proc nimLang(): Lang = embedLang("nim")

proc lexRegex(peg: bool, s: string, toks: var seq[TokKind]) =
  ## a regular expression (re, nre) or a PEG (pegs): classes, groups, escapes, quantifiers, anchors
  let n = s.len
  var i = 0
  template mark(a, b: int, k: TokKind) =
    for q in max(a, 0) ..< min(b, n): toks[q] = k
  while i < n:
    let c = s[i]
    if c == '\\' and i + 1 < n:
      var e = i + 2
      if s[i+1] == 'x' and e < n and s[e] == '{':
        let r = s.find('}', e)
        e = if r < 0: n else: r + 1
      elif s[i+1] == 'x':
        while e < n and e < i + 4 and s[e] in HexDigits: inc e
      mark(i, e, tkEscape)
      i = e
    elif c == '[':
      var j = i + 1
      if j < n and s[j] == '^': inc j
      if j < n and s[j] == ']': inc j
      while j < n and s[j] != ']':
        if s[j] == '\\': inc j
        inc j
      let e = min(j + 1, n)
      mark(i, e, tkType)
      var q = i + 1
      while q < e - 1:
        if s[q] == '\\':
          mark(q, q + 2, tkEscape)
          q += 2
        else: inc q
      i = e
    elif c == '(':
      toks[i] = tkPunct
      inc i
      if i < n and s[i] == '?':
        var j = i + 1
        if j < n and s[j] in {'<', 'P'} and j + 1 < n and s[j+1] notin {'=', '!'}:
          let r = s.find('>', j)
          j = if r < 0: j + 1 else: r + 1
        elif j < n: inc j
        mark(i, j, tkKeyword)
        i = j
    elif c == ')': (toks[i] = tkPunct; inc i)
    elif c in {'*', '+', '?', '|'}: (toks[i] = tkOperator; inc i)
    elif c == '{' and not peg:
      let r = s.find('}', i)
      if r > i and s[i + 1 ..< r].allCharsInSet(Digits + {','}):
        mark(i, r + 1, tkNumber)
        i = r + 1
      else: (toks[i] = tkString; inc i)
    elif c in {'^', '$'} and not peg: (toks[i] = tkKeyword; inc i)
    elif c == '.' : (toks[i] = tkConst; inc i)
    elif peg and c in {'\'', '"'}:
      let r = s.find(c, i + 1)
      let e = if r < 0: n else: r + 1
      mark(i, e, tkString)
      i = e
    elif peg and c == '<' and i + 1 < n and s[i+1] == '-': (mark(i, i + 2, tkOperator); i += 2)
    elif peg and c in {'/', '!', '&', '@', '~'}: (toks[i] = tkOperator; inc i)
    elif peg and c in {'{', '}'}: (toks[i] = tkPunct; inc i)
    elif peg and c == '$': (toks[i] = tkVariable; inc i)
    elif peg and isIdentStart(c):
      var j = i
      while j < n and isWordByte(s[j]): inc j
      mark(i, j, tkFunc)
      i = j
    elif c in {' ', '\t'}: inc i
    else: (toks[i] = (if peg: tkText else: tkString); inc i)

proc fmtOverlay(s: string, a, e: int, toks: var seq[TokKind]): seq[(int, int)] =
  ## strformat in s[a ..< e]: {expressions} coloured as Nim, {{ and }} as escapes; returns where the
  ## expressions are
  var i = a
  while i < e:
    let c = s[i]
    if c == '{' and i + 1 < e and s[i+1] == '{':
      toks[i] = tkEscape
      toks[i+1] = tkEscape
      i += 2
    elif c == '}' and i + 1 < e and s[i+1] == '}':
      toks[i] = tkEscape
      toks[i+1] = tkEscape
      i += 2
    elif c == '{':
      var j = i + 1
      var depth = 0
      var spec = -1
      while j < e:
        let d = s[j]
        if d in {'"', '\''}:
          let r = s.find(d, j + 1)
          j = if r < 0 or r >= e: e else: r + 1
          continue
        if d in {'(', '[', '{'}: inc depth
        elif d in {')', ']'}: dec depth
        elif d == '}':
          if depth == 0: break
          dec depth
        elif d == ':' and depth == 0 and spec < 0: spec = j
        inc j
      toks[i] = tkEscape
      let ee = if spec >= 0: spec else: min(j, e)
      let nl = nimLang()
      if nl != nil and ee > i + 1:
        lexSub(nl, s, i + 1, ee, toks, false)
        result.add (i + 1, ee)
      for q in ee ..< min(j + 1, e): toks[q] = tkEscape
      i = j + 1
    else: inc i

proc lexNimFmt(s: string, toks: var seq[TokKind]) =
  ## strformat's text: a string with {expressions} (Nim) and \\escapes
  for q in 0 ..< s.len: toks[q] = tkString
  var i = 0
  while i + 1 < s.len:
    if s[i] == '\\':
      toks[i] = tkEscape
      toks[i+1] = tkEscape
      i += 2
    else: inc i
  discard fmtOverlay(s, 0, s.len, toks)

proc addForeign(a, e: int, holes: seq[(int, int)]) =
  ## s[a ..< e] is another language's, except the Nim expressions in it (strformat)
  var x = a
  for (h0, h1) in holes:
    if h0 > x: lexForeign.add (x, h0)
    x = max(x, h1)
  if e > x: lexForeign.add (x, e)

proc lexMarkdown(s: string, st: uint8, toks: var seq[TokKind]): LexSt =
  let t = s.strip(trailing = false)
  template markAll(k: TokKind) =
    for q in 0..<s.len: toks[q] = k
  if st == stFence:
    markAll(tkCode)
    if t.startsWith("```") or t.startsWith("~~~"): return stNormal
    return stFence
  if t.startsWith("```") or t.startsWith("~~~"):
    markAll(tkPunct)
    var w = t[3 .. ^1].strip
    for k, ch in w:
      if ch in {' ', '\t', '{', ',', ':'}:
        w = w[0 ..< k]
        break
    let l = langForWord(w)
    if l != nil and l.mode != lmMarkdown:
      let id = embedId(l.id, eeFence)
      if id != 0: return stWrap(id, 0)
    return stFence
  if t.startsWith("#"):
    var h = 0
    while h < t.len and t[h] == '#': inc h
    if h <= 6 and (h == t.len or t[h] == ' '):
      markAll(tkHeading)
      return stNormal
  if t.startsWith(">"):
    markAll(tkComment)
    return stNormal
  if t == "---" or t == "***" or t == "___":
    markAll(tkPunct)
    return stNormal
  let ind = s.len - t.len
  var i = 0
  if t.len >= 2 and t[0] in {'-', '*', '+'} and t[1] == ' ':
    toks[ind] = tkKeyword
    i = ind + 2
  else:
    var d = 0
    while d < t.len and t[d] in Digits: inc d
    if d > 0 and d + 1 < t.len and t[d] in {'.', ')'} and t[d+1] == ' ':
      for q in ind..ind+d: toks[q] = tkKeyword
      i = ind + d + 2
  while i < s.len:
    let c = s[i]
    if c == '`':
      let e = s.find('`', i + 1)
      let stop = if e < 0: s.len else: e + 1
      for q in i..<stop: toks[q] = tkCode
      i = stop
    elif (c == '*' or c == '_') and i + 1 < s.len and s[i+1] == c:
      let e = s.find(c & c, i + 2)
      if e < 0: inc i
      else:
        for q in i..<e+2: toks[q] = tkBold
        i = e + 2
    elif c == '[':
      let e = s.find(']', i + 1)
      if e > 0 and e + 1 < s.len and s[e+1] == '(':
        let e2 = s.find(')', e + 2)
        let stop = if e2 < 0: s.len else: e2 + 1
        for q in i..e: toks[q] = tkLink
        for q in e+1..<stop: toks[q] = tkComment
        i = stop
      else: inc i
    elif c == '<' and s.startsAt("<http", i):
      let e = s.find('>', i)
      let stop = if e < 0: s.len else: e + 1
      for q in i..<stop: toks[q] = tkLink
      i = stop
    else: inc i
  stNormal

proc lexHtml(s: string, st: uint8, toks: var seq[TokKind], at = 0): LexSt =
  var i = at
  var state = st
  let n = s.len
  while i < n:
    if state == stHtmlComment:
      let e = s.find("-->", i)
      let stop = if e < 0: n else: e + 3
      for q in i..<stop: toks[q] = tkComment
      i = stop
      if e >= 0: state = stNormal
      continue
    let c = s[i]
    if c == '<':
      if s.startsAt("<!--", i):
        state = stHtmlComment
        continue
      var j = i + 1
      let closing = j < n and s[j] == '/'
      if j < n and s[j] in {'/', '!', '?'}: inc j
      let nameAt = j
      while j < n and (isWordByte(s[j]) or s[j] in {'-', ':', '.'}): inc j
      let tagName = s[nameAt ..< j].toLowerAscii
      for q in i..<j: toks[q] = tkTag
      toks[i] = tkPunct
      i = j
      let attrsAt = i
      # attributes until '>'
      while i < n and s[i] != '>':
        let a = s[i]
        if a in {'"', '\''}:
          let e = s.find(a, i + 1)
          let stop = if e < 0: n else: e + 1
          for q in i..<stop: toks[q] = tkString
          i = stop
        elif isIdentStart(a):
          var k = i
          while k < n and (isWordByte(s[k]) or s[k] in {'-', ':', '@', '.'}): inc k
          for q in i..<k: toks[q] = tkAttr
          i = k
        else:
          if a in {'=', '/'}: toks[i] = tkPunct
          inc i
      if i < n:
        toks[i] = tkPunct
        inc i
        # <script> and <style>: their text is JavaScript (or JSON) and CSS, up to the closing tag
        if not closing and tagName in ["script", "style"] and s[i - 2] != '/':
          let attrs = s[attrsAt ..< i].toLowerAscii
          let inner = if tagName == "style": "css"
                      elif "json" in attrs: "json"
                      elif "typescript" in attrs or "lang=\"ts\"" in attrs or "lang='ts'" in attrs: "typescript"
                      elif "type=" in attrs and "javascript" notin attrs and "module" notin attrs: ""
                      else: "javascript"
          let il = embedLang(inner)
          if il != nil:
            let close = findNoCase(s, "</" & tagName, i)
            if close >= 0:                     # it ends on this line: colour it, then go on with the tag
              lexSub(il, s, i, close, toks, true)
              i = close
              continue
            let id = embedId(inner, eeTag, tagName)
            if id != 0: return lexInto(htmlLang(), s, stWrap(id, 0), toks, i)
    elif c == '&':
      let e = s.find(';', i)
      if e > 0 and e - i < 10:
        for q in i..e: toks[q] = tkEscape
        i = e + 1
      else: inc i
    else: inc i
  state
