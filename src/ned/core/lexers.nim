func keyPrefix(s: string, toks: var seq[TokKind], sep: char): int =
  ## marks a leading `key<sep>` (YAML/TOML/INI keys) as a property; returns where lexing continues
  var i = 0
  while i < s.len and s[i] in {' ', '\t'}: inc i
  if sep == ':' and i + 1 < s.len and s[i] == '-' and s[i+1] == ' ': i += 2
  let ks = i
  if i < s.len and s[i] in {'"', '\''}:
    let e = s.find(s[i], i + 1)
    if e < 0: return 0
    i = e + 1
  else:
    while i < s.len and (isWordByte(s[i]) or s[i] in {'-', '.', ' ', '/', '$'}) and s[i] != sep: inc i
  var j = i
  while j < s.len and s[j] == ' ': inc j
  if j < s.len and s[j] == sep and (sep != ':' or j + 1 >= s.len or s[j+1] in {' ', '\t'}):
    if i > ks:
      for q in ks..<i: toks[q] = tkProperty
      toks[j] = tkOperator
      return j + 1
  0

proc lexNimf(s: string, st: LexSt, toks: var seq[TokKind]): LexSt =
  ## a Nim source-code-filter template (#? stdtmpl): lines starting with # are Nim, the others are text (HTML)
  ## with $name, ${expr} and $(expr) substitutions
  let t = s.strip(trailing = false)
  let off = s.len - t.len
  if t.startsWith("#"):
    if t.startsWith("#?") or t.startsWith("#!"):
      for q in off ..< s.len: toks[q] = tkPreproc
      return st
    toks[off] = tkPreproc
    let nl = nimLang()
    if nl != nil: lexSub(nl, s, off + 1, s.len, toks, false)
    return st                                  # the text's state goes on past the code lines
  let h = htmlLang()
  result = if h != nil: lexInto(h, s, st, toks) else: st
  var i = 0
  let n = s.len
  while i < n:
    if s[i] == '$' and i + 1 < n:
      if s[i+1] == '$':
        i += 2
        continue
      if s[i+1] in {'{', '('}:
        let close = if s[i+1] == '{': '}' else: ')'
        let r = s.find(close, i + 2)
        let e = if r < 0: n else: r
        toks[i] = tkOperator
        toks[i+1] = tkOperator
        let nl = nimLang()
        if nl != nil: lexSub(nl, s, i + 2, e, toks, false)
        if e < n: toks[e] = tkOperator
        i = e + 1
        continue
      if isIdentStart(s[i+1]):
        var j = i + 1
        while j < n and (isWordByte(s[j]) or (s[j] == '.' and j + 1 < n and isIdentStart(s[j+1]))): inc j
        for q in i ..< j: toks[q] = tkVariable
        i = j
        continue
    inc i

const CsvColours = [tkKeyword, tkType, tkNumber, tkFunc, tkVariable, tkProperty, tkConst, tkTag, tkAttr, tkPreproc]

func csvSepOf(lang: Lang, s: string): char =
  ## a CSV line's separator: the language's, or (plain .csv) , unless the line has more ; than , outside quotes
  if lang.csvSep != '\0': return lang.csvSep
  var commas, semis = 0
  var q = false
  for c in s:
    if c == '"': q = not q
    elif not q:
      if c == ',': inc commas
      elif c == ';': inc semis
  if semis > commas: ';' else: ','

proc csvFields(s: string, sep: char): seq[(int, int)] =
  ## the fields of a CSV line: (first byte, end) — a "quoted, field" with its quotes ("" inside is a quote)
  var i = 0
  while true:
    let a = i
    if i < s.len and s[i] == '"':
      inc i
      while i < s.len:
        if s[i] == '"':
          if i + 1 < s.len and s[i + 1] == '"': i += 2
          else:
            inc i
            break
        else: inc i
    while i < s.len and s[i] != sep: inc i
    result.add (a, i)
    if i >= s.len: break
    inc i                      # the separator

proc lexCsv(lang: Lang, s: string, toks: var seq[TokKind]) =
  ## each column in its own colour, the separators as punctuation
  let sep = csvSepOf(lang, s)
  for k, (a, e) in csvFields(s, sep):
    let tk = CsvColours[k mod CsvColours.len]
    for q in a ..< e: toks[q] = tk
    if e < s.len: toks[e] = tkPunct

proc lexNif(s: string, toks: var seq[TokKind]) =
  ## NIF: a node's tag (after its `(`) as a keyword, a directive (`(.nif27)`) as one of the preprocessor's, what a
  ## node declares (`:name`) as a function, a symbol's name as a variable and its disambiguation and module quieter,
  ## strings, characters, numbers — and the line information after a tag or an atom (`@3,1`, `~2`) quietest
  let n = s.len
  var i = 0
  template info() =
    if i < n and s[i] in {'@', '~'}:
      let a = i
      inc i
      while i < n and s[i] notin {' ', '\t', '(', ')', '"', '\'', '#'}: inc i
      for q in a ..< i: toks[q] = tkComment
  while i < n:
    let c = s[i]
    case c
    of '(':
      toks[i] = tkPunct
      inc i
      let a = i
      while i < n and s[i] notin {' ', '\t', '(', ')', '@', '~', '#', '"', '\''}: inc i
      let k = if a < n and s[a] == '.': tkPreproc else: tkKeyword
      for q in a ..< i: toks[q] = k
      info()
    of ')':
      toks[i] = tkPunct
      inc i
    of '"', '\'':
      let a = i
      inc i
      while i < n and s[i] != c: inc i
      i = min(n, i + 1)
      for q in a ..< i: toks[q] = (if c == '"': tkString else: tkChar)
      info()
    of '#':
      let e = s.find('#', i + 1)
      let stop = if e < 0: n else: e + 1
      for q in i ..< stop: toks[q] = tkComment
      i = stop
    of ' ', '\t':
      inc i
    else:
      let a = i
      while i < n and s[i] notin {' ', '\t', '(', ')', '@', '~', '#', '"'}: inc i
      if c == ':':
        for q in a ..< i: toks[q] = tkFunc
      elif c in {'0'..'9', '-', '+'} and a + 1 <= i:
        for q in a ..< i: toks[q] = tkNumber
      elif c == '.':
        toks[a] = tkPunct
      else:
        # a symbol: its name, then .disambiguation.module quieter
        let d = s.find('.', a)
        let nameEnd = if d < 0 or d >= i: i else: d
        for q in a ..< nameEnd: toks[q] = tkVariable
        for q in nameEnd ..< i: toks[q] = tkPunct
      info()

proc lexHost(lang: Lang, s: string, st: uint8, toks: var seq[TokKind], at = 0): LexSt =
  ## the language's own lexer, from byte `at` (after an embedded block that ended inside the line)
  if at > 0:
    return (if lang.mode == lmHtml: lexHtml(s, st, toks, at) else: lexGeneric(lang, s, st, toks, at))
  case lang.mode
  of lmPlain: 0'u32
  of lmCsv:
    lexCsv(lang, s, toks)
    0'u32
  of lmNif:
    lexNif(s, toks)
    0'u32
  of lmMarkdown: lexMarkdown(s, st, toks)
  of lmHtml: lexHtml(s, st, toks)
  of lmNimf: lexNimf(s, LexSt(st), toks)
  of lmRegex:
    lexRegex(lang.id == "peg", s, toks)
    0'u32
  of lmNimFmt:
    lexNimFmt(s, toks)
    0'u32
  of lmDiff:
    let k = if s.startsWith("+++") or s.startsWith("---") or s.startsWith("diff ") or
               s.startsWith("index "): tkHeading
            elif s.startsWith("@@"): tkKeyword
            elif s.startsWith("+"): tkAdded
            elif s.startsWith("-"): tkRemoved
            else: tkText
    for i in 0..<s.len: toks[i] = k
    0'u32
  of lmYaml:
    if st == 0 and (s.startsWith("---") or s.startsWith("...")):
      for i in 0..<s.len: toks[i] = tkPunct
      return 0
    let start = if st == 0: keyPrefix(s, toks, ':') else: 0
    lexGeneric(lang, s, st, toks, start)
  of lmToml:
    let t = s.strip()
    if st == 0 and t.startsWith("[") and t.endsWith("]"):
      for i in 0..<s.len: toks[i] = tkHeading
      return 0
    if st == 0 and t.startsWith(";"):
      for i in 0..<s.len: toks[i] = tkComment
      return 0
    let start = if st == 0: keyPrefix(s, toks, '=') else: 0
    lexGeneric(lang, s, st, toks, start)
  of lmMake:
    let start = if st == 0 and s.len > 0 and s[0] != '\t': keyPrefix(s, toks, '=') else: 0
    if start == 0 and s.len > 0 and s[0] notin {'\t', ' ', '#'}:
      let c = s.find(':')
      if c > 0 and (c + 1 >= s.len or s[c+1] != '='):
        for q in 0..<c: toks[q] = tkFunc
        return lexGeneric(lang, s, st, toks, c)
    let r = lexGeneric(lang, s, st, toks, start)
    var i = 0
    while i < s.len:
      if s[i] == '$' and i + 1 < s.len and s[i+1] in {'(', '{'}:
        let e = s.find((if s[i+1] == '(': ')' else: '}'), i)
        let stop = if e < 0: s.len else: e + 1
        for q in i..<stop: toks[q] = tkVariable
        i = stop
      else: inc i
    r
  else:
    lexGeneric(lang, s, st, toks)

proc lexInto(lang: Lang, s: string, st: LexSt, toks: var seq[TokKind], start = 0): LexSt =
  ## colours s[start ..] as `lang` in state `st`; inside an embedded block, its own language colours the text
  ## up to where the block ends, and `lang` the rest of the line
  if lang.mode == lmNimf and start == 0: return lexNimf(s, st, toks)    # its text lines carry HTML's state
  let id = stTop(st)
  if id == 0 or id >= embeds.len: return lexHost(lang, s, uint8(st and 0xFF), toks, start)
  let d = embeds[id]
  let n = s.len
  var close = -1                      # where the text ends on this line
  var after = -1                      # where `lang` goes on
  case d.ends
  of eeTriple:
    close = s.find("\"\"\"", start)
    if close >= 0:
      after = close + 3
      while after < n and s[after] == '"': inc after
  of eeFence:
    let t = s.strip(trailing = false)
    if t.startsWith("```") or t.startsWith("~~~"):
      for q in start ..< n: toks[q] = tkPunct
      return 0
  of eeTag:
    close = findNoCase(s, "</" & d.tag, start)
    after = close
  let e = if close >= 0: close else: n
  var curId = id
  var inner = embedLang(d.langId)
  var innerSt = stInner(st)
  if d.langId.len == 0:
    # a triple-quoted string whose first line was empty: its first line of text decides
    let txt = s[start ..< e]
    let sn = if txt.strip.len == 0: "" else: sniffLang(txt)
    if sn.len > 0 and embedLang(sn) != nil:
      curId = embedId(sn, d.ends, fmt = d.fmt)
      inner = embedLang(sn)
      innerSt = 0
    elif txt.strip.len == 0 and close < 0:
      for q in start ..< n: toks[q] = tkString
      return st
    elif d.fmt:                       # a strformat string of plain text
      curId = embedId("nimfmt", d.ends)
      inner = embedLang("nimfmt")
      innerSt = 0
    else:                             # plain text: an ordinary string from here on
      if close < 0:
        for q in start ..< n: toks[q] = tkString
        return LexSt(stTriple2)
      for q in start ..< after: toks[q] = tkString
      return lexHost(lang, s, 0, toks, after)
  if inner == nil:                    # the language went away (a setting changed): plain text
    for q in start ..< e: toks[q] = tkString
    if close < 0: return st
    for q in e ..< after: toks[q] = tkString
    return lexHost(lang, s, 0, toks, after)
  var endSt: LexSt = 0
  if e > start:
    let sub = s[start ..< e]
    var sk = newSeq[TokKind](sub.len)
    lexLangs.add (lexOff + start, lexOff + e, lexDepth + 1, inner)
    let off0 = lexOff
    lexOff += start
    inc lexDepth
    endSt = lexInto(inner, sub, innerSt, sk)
    dec lexDepth
    lexOff = off0
    for q in 0 ..< sub.len: toks[start + q] = sk[q]
    if embeds[curId].fmt:
      let holes = fmtOverlay(s, start, e, toks)
      if lexDepth == 0: addForeign(start, e, holes)
    elif lexDepth == 0 and inner.id != "nimfmt": lexForeign.add (start, e)
  else: endSt = innerSt
  if close < 0: return stWrap(curId, endSt)
  if d.ends == eeTriple:
    for q in close ..< after: toks[q] = tkString
  lexHost(lang, s, 0, toks, after)

proc lexLine(lang: Lang, s: string, st: LexSt, toks: var seq[TokKind]): LexSt =
  toks.setLen(s.len)
  for i in 0..<s.len: toks[i] = tkText
  if lexDepth == 0:
    lexForeign.setLen(0)
    lexLangs.setLen(0)
    lexOff = 0
  if lang == nil: return 0
  lexInto(lang, s, st, toks)
