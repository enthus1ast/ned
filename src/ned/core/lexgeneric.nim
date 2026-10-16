proc lexGeneric(lang: Lang, s: string, startState: uint8, toks: var seq[TokKind], start = 0): LexSt =
  var st = startState
  var i = start
  let n = s.len
  var prevDef = 0            # 1: next ident is a function name, 2: a type name
  var rawNext = false
  var emitCtx = false        # Nim: inside {.emit: …} — its strings are C (C++, JavaScript)
  template mark(a, b: int, k: TokKind) =
    for q in max(a, 0) ..< min(b, n): toks[q] = k
  while i < n:
    # ── continuing multi-line constructs
    if st >= 1 and st <= 63:
      let doc = st >= 32
      var depth = int(if doc: st - 32 else: st)
      let closeTok = if doc: lang.docBlockEnd else: lang.blockEnd
      let openTok = if doc: lang.docBlockStart else: lang.blockStart
      var j = i
      var closed = false
      while j < n:
        if lang.nested and openTok.len > 0 and s.startsAt(openTok, j):
          inc depth
          j += openTok.len
          continue
        if s.startsAt(closeTok, j):
          dec depth
          j += closeTok.len
          if depth <= 0:
            closed = true
            break
          continue
        inc j
      mark(i, j, (if doc: tkDoc else: tkComment))
      i = j
      st = if closed: stNormal else: uint8(min(depth, 30) + (if doc: 32 else: 0))
      continue
    if st == stTriple2 or st == stTriple1:
      let q = if st == stTriple2: "\"\"\"" else: "'''"
      let j = s.find(q, i)
      if j < 0:
        mark(i, n, tkString)
        return st
      var e = j + 3
      while e < n and s[e] == q[0]: inc e
      mark(i, e, tkString)
      i = e
      st = stNormal
      continue
    if st == stBacktick:
      var j = i
      while j < n and s[j] != '`':
        if s[j] == '\\': inc j
        inc j
      mark(i, min(j + 1, n), tkString)
      if j >= n: return st
      i = j + 1
      st = stNormal
      continue
    # ── normal state
    let c = s[i]
    if c in {' ', '\t'}:
      inc i
      continue
    if lang.docBlockStart.len > 0 and s.startsAt(lang.docBlockStart, i) and
       not (lang.mode == lmC and s.startsAt("/**/", i)):
      mark(i, i + lang.docBlockStart.len, tkDoc)
      i += lang.docBlockStart.len
      st = 33
      continue
    if lang.blockStart.len > 0 and s.startsAt(lang.blockStart, i):
      mark(i, i + lang.blockStart.len, tkComment)
      i += lang.blockStart.len
      st = 1
      continue
    if lang.docLine.len > 0 and s.startsAt(lang.docLine, i):
      mark(i, n, tkDoc)
      return st
    if lang.lineComment.len > 0 and s.startsAt(lang.lineComment, i) and
       (not lang.commentNeedsSpace or i == 0 or s[i-1] in {' ', '\t'}):
      mark(i, n, tkComment)
      return st
    if lang.mode == lmNim and c == '{' and i + 1 < n and s[i+1] == '.':
      var k = i + 2
      while k < n and s[k] == ' ': inc k
      if s.startsAt("emit", k):
        var m = k + 4
        while m < n and s[m] == ' ': inc m
        if m < n and s[m] == ':':
          mark(i, m + 1, tkPragma)
          i = m + 1
          emitCtx = true
          continue
      let j = s.find(".}", i + 2)
      let e = if j < 0: n else: j + 2
      mark(i, e, tkPragma)
      i = e
      continue
    if lang.mode == lmRust and c == '#' and i + 1 < n and (s[i+1] == '[' or s.startsAt("#![", i)):
      let j = s.find(']', i)
      let e = if j < 0: n else: j + 1
      mark(i, e, tkPragma)
      i = e
      continue
    if lang.mode == lmC and c == '#' and isBlank(s[0..<i]):
      var j = i + 1
      while j < n and s[j] in {' ', '\t'}: inc j
      while j < n and isWordByte(s[j]): inc j
      mark(i, j, tkPreproc)
      let dir = s[i..<j]
      i = j
      if "include" in dir:
        while i < n and s[i] == ' ': inc i
        if i < n and s[i] == '<':
          let e = s.find('>', i)
          let stop = if e < 0: n else: e + 1
          mark(i, stop, tkString)
          i = stop
      continue
    if lang.mode == lmShell and c == '$':
      var j = i + 1
      if j < n and s[j] == '{':
        let e = s.find('}', j)
        j = if e < 0: n else: e + 1
      elif j < n and s[j] == '(':
        mark(i, j + 1, tkOperator)
        i = j + 1
        continue
      else:
        while j < n and (isWordByte(s[j]) or (j == i + 1 and s[j] in {'@', '#', '?', '*', '!', '$', '-'})):
          inc j
          if j == i + 2 and s[j-1] in {'@', '#', '?', '*', '!', '$', '-'}: break
      mark(i, j, tkVariable)
      i = j
      continue
    if lang.decorators and c == '@' and i + 1 < n and isIdentStart(s[i+1]):
      var j = i + 1
      while j < n and (isWordByte(s[j]) or s[j] == '.'): inc j
      mark(i, j, tkPragma)
      i = j
      continue
    if lang.mode == lmNim and c == '\'':
      # a character literal: 'a', '"', '\n', '\x41', '\'' (1'u8 is a number, `'big` a name)
      var j = i + 1
      var ok = false
      if j < n and s[j] == '\\':
        j += 2
        while j < n and j - i < 12 and s[j] != '\'': inc j
        ok = j < n and s[j] == '\''
      elif j < n and s[j] != '\'':
        j = nextRune(s, j)
        ok = j < n and s[j] == '\''
      if ok:
        mark(i, j + 1, tkChar)
        if s[i+1] == '\\': mark(i + 1, j, tkEscape)
        i = j + 1
      else:
        mark(i, i + 1, tkOperator)
        inc i
      continue
    if c in lang.quotes:
      if lang.triple and c != '`' and i + 2 < n and s[i+1] == c and s[i+2] == c:
        if lang.mode == lmNim and c == '"':
          # the text may be another language: C in {.emit.}, sql"""…""", HTML, a #[lang]# marker …
          let name = nimStringLang(s, i, emitCtx)
          var id = 0
          let l2 = nimEmbedLang(name)
          if name.len == 0 or name == "nimfmt":
            # the text decides: HTML or SQL (with {expressions} in a strformat string) or not
            let isFmt = name == "nimfmt"
            let close = s.find("\"\"\"", i + 3)
            let txt = s[i + 3 ..< (if close < 0: n else: close)]
            if txt.strip.len == 0:
              if close < 0: id = embedId("", eeTriple, fmt = isFmt)       # the next line's text decides
              elif isFmt: id = embedId("nimfmt", eeTriple)
            else:
              let sn = sniffLang(txt)
              if sn.len > 0 and embedLang(sn) != nil: id = embedId(sn, eeTriple, fmt = isFmt)
              elif isFmt: id = embedId("nimfmt", eeTriple)
          elif l2 != nil: id = embedId(l2.id, eeTriple)
          if id != 0:
            mark(i, i + 3, tkString)
            let close = s.find("\"\"\"", i + 3)
            if close < 0: return lexInto(lang, s, stWrap(id, 0), toks, i + 3)    # it goes on below
            # it ends on this line: colour it here (no recursion, however many there are on the line)
            var after = close + 3
            while after < n and s[after] == '"': inc after
            let l3 = embedLang(embeds[id].langId)
            if l3 != nil:
              lexSub(l3, s, i + 3, close, toks, false)
              if embeds[id].fmt:
                let holes = fmtOverlay(s, i + 3, close, toks)
                if lexDepth == 0: addForeign(i + 3, close, holes)
              elif l3.id != "nimfmt" and lexDepth == 0: lexForeign.add (i + 3, close)
            mark(close, after, tkString)
            i = after
            rawNext = false
            continue
        let q = repeat(c, 3)
        let j = s.find(q, i + 3)
        if j < 0:
          mark(i, n, tkString)
          return LexSt(if c == '"': stTriple2 else: stTriple1)
        var e = j + 3
        while e < n and s[e] == c: inc e
        mark(i, e, tkString)
        i = e
        rawNext = false
        continue
      if c == '`' and lang.mode == lmJs:
        var j = i + 1
        while j < n and s[j] != '`':
          if s[j] == '\\': inc j
          inc j
        mark(i, min(j + 1, n), tkString)
        if j >= n: return stBacktick
        i = j + 1
        continue
      if c == '\'' and lang.charLit:
        var j = i + 1
        var ok = false
        if j < n and s[j] == '\\':
          j += 2
          while j < n and j - i < 12 and s[j] != '\'': inc j
          ok = j < n and s[j] == '\''
        elif j < n:
          j = nextRune(s, j)
          ok = j < n and s[j] == '\''
        if ok:
          mark(i, j + 1, tkChar)
          if s[i+1] == '\\': mark(i + 1, j, tkEscape)
          i = j + 1
        else:
          mark(i, i + 1, (if lang.mode == lmRust: tkType else: tkOperator))
          inc i
          if lang.mode == lmRust:
            while i < n and isWordByte(s[i]):
              toks[i] = tkType
              inc i
        continue
      let raw = rawNext or (lang.mode == lmNim and i > 0 and isWordByte(s[i-1])) or
                (lang.mode == lmGeneric and c == '`')
      rawNext = false
      var j = i + 1
      var escs: seq[int]
      while j < n:
        if s[j] == '\\' and not raw and c != '`':
          escs.add j
          j += 2
          continue
        if s[j] == c:
          if raw and lang.mode == lmNim and j + 1 < n and s[j+1] == c:
            j += 2
            continue
          break
        inc j
      let e = min(j + 1, n)
      var kind = tkString
      if lang.mode in {lmJson, lmCss}:
        var k = e
        while k < n and s[k] in {' ', '\t'}: inc k
        if k < n and s[k] == ':' and lang.mode == lmJson: kind = tkProperty
      mark(i, e, kind)
      for p in escs: mark(p, p + 2, tkEscape)
      if lang.mode == lmNim and c == '"' and e - i > 2:
        let name = nimStringLang(s, i, emitCtx)
        let ce = if j < n: j else: n
        let sn = if name == "nimfmt": sniffLang(s[i + 1 ..< ce]) else: ""
        if sn.len > 0 and embedLang(sn) != nil:          # &"<li>{x}</li>": HTML with Nim in it
          lexSub(embedLang(sn), s, i + 1, ce, toks, false)
          let holes = fmtOverlay(s, i + 1, ce, toks)
          if lexDepth == 0: addForeign(i + 1, ce, holes)
        else:
          let l2 = nimEmbedLang(name)
          if l2 != nil: lexSub(l2, s, i + 1, ce, toks, l2.id != "nimfmt")
      i = e
      continue
    if c in Digits or (c == '.' and i + 1 < n and s[i+1] in Digits and (i == 0 or not isWordByte(s[i-1]))):
      var j = i
      if c == '0' and j + 1 < n and s[j+1] in {'x', 'X', 'b', 'B', 'o', 'O'}:
        j += 2
        while j < n and s[j] in HexDigits + {'_'}: inc j
      else:
        while j < n and (s[j] in Digits + {'_'} or (s[j] == '.' and j + 1 < n and s[j+1] in Digits)): inc j
        if j < n and s[j] in {'e', 'E'} and j + 1 < n and
           (s[j+1] in Digits or (s[j+1] in {'+', '-'} and j + 2 < n and s[j+2] in Digits)):
          j += 2
          while j < n and s[j] in Digits: inc j
      if lang.mode == lmNim and j < n and s[j] == '\'':
        inc j
        while j < n and isWordByte(s[j]): inc j
      else:
        while j < n and s[j] in {'a'..'z', 'A'..'Z', '0'..'9'}: inc j
      mark(i, j, tkNumber)
      i = j
      continue
    if lang.mode == lmCss and c == '#':
      var j = i + 1
      while j < n and (isWordByte(s[j]) or s[j] == '-'): inc j
      mark(i, j, (if j - i in {4, 5, 7, 9}: tkNumber else: tkType))
      i = j
      continue
    if lang.mode == lmNim and c == '`':
      let e = s.find('`', i + 1)
      let stop = if e < 0: n else: e + 1
      mark(i, stop, (if prevDef > 0: tkFunc else: tkText))
      prevDef = 0
      i = stop
      continue
    if isIdentStart(c):
      var j = i + 1
      while j < n and (isWordByte(s[j]) or (lang.mode in {lmCss, lmMake} and s[j] == '-')): inc j
      let w = s[i..<j]
      var k = tkText
      if prevDef == 1: k = tkFunc
      elif prevDef == 2: k = tkType
      if prevDef != 0:
        prevDef = 0
      elif w in lang.keywords:
        k = tkKeyword
        if w in lang.defWords: prevDef = 1
        elif w in lang.classWords: prevDef = 2
      elif w in lang.classWords:
        k = tkKeyword
        prevDef = 2
      elif w in lang.consts: k = tkConst
      elif w in lang.types: k = tkType
      elif lang.capsTypes and c in {'A'..'Z'}:
        var allCaps = w.len > 1
        for ch in w:
          if ch notin {'A'..'Z', '0'..'9', '_'}: allCaps = false
        k = if allCaps: tkConst else: tkType
      else:
        var q = j
        if lang.mode == lmNim and q < n and s[q] == '*': inc q
        if q < n and s[q] == '(': k = tkFunc
        elif lang.mode == lmRust and q < n and s[q] == '!': k = tkFunc
        elif lang.mode == lmNim and q < n and s[q] == '"': k = tkFunc
        elif w in lang.builtins: k = tkFunc
        elif lang.mode == lmCss and q < n and s[q] == ':': k = tkProperty
      if lang.mode == lmPython and j < n and s[j] in {'"', '\''} and w.len <= 2 and
         w.toLowerAscii.allCharsInSet({'r', 'b', 'f', 'u'}):
        k = tkString
        rawNext = 'r' in w.toLowerAscii
      mark(i, j, k)
      i = j
      continue
    if lang.mode == lmNim and c == '.' and i + 1 < n and s[i+1] == '}':
      mark(i, i + 2, tkPragma)
      i += 2
      emitCtx = false
      continue
    const OpChars = {'+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~', '?', ':', '\\', '@', '$', '.'}
    if c == ':' and lang.mode == lmNim and (i + 1 >= n or s[i+1] notin OpChars) and
       (i == 0 or s[i-1] notin OpChars):
      mark(i, i + 1, tkPunct)       # Nim's `:` is a separator (`x: int`, `if c:`), not an operator
    elif c in OpChars - {'.'}:
      mark(i, i + 1, tkOperator)
    elif c == '.' and i + 1 < n and s[i+1] == '.':
      mark(i, i + 2, tkOperator)
      inc i
    elif c in {'(', ')', '[', ']', '{', '}', ',', ';', '.'}:
      mark(i, i + 1, tkPunct)
    inc i
  st
