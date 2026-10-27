# ════════════════════════════════════════════════════════════════════════════
#  Editing commands (all multi-cursor aware)
# ════════════════════════════════════════════════════════════════════════════

import autoindent

var cfgAutoDedent* = true   # editor.autoDedent: in Nim, a closer typed alone and `of`/`elif`/`else`/`except`/`finally`
                            # typed at a line's start go back to the column of what they close or belong to

func pairClose(pairs: string, ch: char): char =
  var i = 0
  while i + 1 < pairs.len:
    if pairs[i] == ch: return pairs[i+1]
    i += 2
  '\0'

func isCloser(pairs: string, ch: char): bool =
  var i = 1
  while i < pairs.len:
    if pairs[i] == ch: return true
    i += 2
  false

proc canEdit(b: Buffer): bool =
  if b.readOnly:
    if b.libLocked:
      warn(b.name & " is part of the Nim toolchain or an installed package: read-only, so it is not changed by " &
           "accident — palette › File: allow editing this file")
    else: warn("Buffer is read-only")
    return false
  true

proc insertText(b: Buffer, text: string, distribute = true) =
  ## inserts `text` at every cursor (replacing selections). With one line per cursor, lines are distributed.
  if not b.canEdit(): return
  var parts: seq[string]
  if distribute and b.cursors.len > 1:
    let ls = text.strip(leading = false, chars = {'\n'}).split('\n')
    if ls.len == b.cursors.len: parts = ls
    elif clipParts.len == b.cursors.len and clipParts.join("\n") == text: parts = clipParts
  b.beginEdit()
  for i in countdown(b.cursors.high, 0):
    let (a, e) = b.cursors[i].range
    let t = if parts.len > 0: parts[i] else: text
    let p = b.replaceText(a, e, t)
    b.cursors[i] = cur(p)
  b.endEdit()
  b.normalize()

proc typeChar(b: Buffer, ch: string) =
  if not b.canEdit(): return
  let c0 = ch[0]
  b.beginEdit(ekType)
  # undo stops at word starts: "foo bar" undoes as "bar", then "foo "
  let ph = b.primary.head
  let before = if ph.col > 0: b.lines[ph.line][ph.col - 1] else: ' '
  if c0 notin {' ', '\t'} and before in {' ', '\t'}: b.newGroup = true
  for i in countdown(b.cursors.high, 0):
    let cu = b.cursors[i]
    var (a, e) = cu.range
    # the language there: in C inside a Nim emit, C's pairs, and a typed } moves back
    let lang = b.langAt(a)
    let pairs = lang.pairs
    let line = b.lines[e.line]
    let next = if e.col < line.len: line[e.col] else: '\0'
    let prev = if a.col > 0: b.lines[a.line][a.col - 1] else: '\0'
    let close = if ch.len == 1 and cfgAutoPairs: pairClose(pairs, c0) else: '\0'
    let isQuote = close == c0
    # wrap a selection with a pair
    if cu.hasSel and close != '\0':
      let inner = b.getText(a, e)
      discard b.replaceText(a, e, ch & inner & $close)
      let s = Pos(line: a.line, col: a.col + 1)
      b.cursors[i] = Cursor(anchor: s, head: posAfter(s, inner), goalX: -1)
      continue
    # step over an existing closer
    if not cu.hasSel and ch.len == 1 and next == c0 and (isCloser(pairs, c0) or isQuote):
      b.cursors[i] = cur(Pos(line: e.line, col: e.col + 1))
      continue
    var ins = ch
    var caret = ch.len
    if close != '\0' and not cu.hasSel:
      let okNext = next in {'\0', ' ', '\t', ')', ']', '}', ',', ';', ':', '.'} or isCloser(pairs, next)
      let okPrev = not isQuote or (not isWordByte(prev) and prev != c0 and prev != '\\')
      if okNext and okPrev and b.tokenAt(Pos(line: a.line, col: max(0, a.col - 1))) notin
         {tkString, tkComment, tkDoc, tkChar} or (okNext and okPrev and a.col == 0):
        ins = ch & $close
    # dedent when typing a closer on a blank line
    if ch.len == 1 and c0 in lang.dedentChars and not cu.hasSel:
      let before = b.lines[a.line][0 ..< a.col]
      if before.len > 0 and isBlank(before):
        let w = b.indentW()
        let target = max(0, visColOf(before, before.len) - w)
        let newWs = if b.indent == "\t": repeat('\t', target div b.tabOf) else: spaces(target)
        discard b.replaceText(Pos(line: a.line, col: 0), a, newWs)
        a = Pos(line: a.line, col: newWs.len)
        e = a
    # Nim: a closing bracket typed alone on its line goes back to the indentation of the line that opened it
    # (editor.autoDedent)
    elif cfgAutoDedent and lang.mode == lmNim and ch.len == 1 and c0 in {')', ']', '}'} and not cu.hasSel:
      let before = b.lines[a.line][0 ..< a.col]
      if before.len > 0 and isBlank(before):
        let t = aiCloserLine(b.lines, a.line, c0)
        if t >= 0:
          let newWs = leadingWs(b.lines[t])
          if newWs.len < before.len:
            discard b.replaceText(Pos(line: a.line, col: 0), a, newWs)
            a = Pos(line: a.line, col: newWs.len)
            e = a
    let p0 = a
    discard b.replaceText(a, e, ins)
    b.cursors[i] = cur(Pos(line: p0.line, col: p0.col + caret))
    # Nim: a branch word typed at the start of a line — `of ` `elif ` `else:` `except` `finally:` — goes back to the
    # column of its `case`, `if`/`when` or `try` (editor.autoDedent)
    if cfgAutoDedent and lang.mode == lmNim and ch.len == 1 and c0 in {' ', ':'} and not cu.hasSel:
      let ln = p0.line
      let s = b.lines[ln]
      let cc = p0.col + caret
      let before = s[0 ..< p0.col]
      let w = before.strip
      let ind = aiLeading(before)
      if ind > 0 and ind + w.len == before.len and cc <= s.len and isBlank(s[cc .. ^1]) and
         ((c0 == ' ' and w in ["of", "elif", "except"]) or (c0 == ':' and w in ["else", "except", "finally"])):
        let t = aiBranchLine(b.lines, ln, w)
        if t >= 0:
          let newWs = leadingWs(b.lines[t])
          if newWs.len < ind:
            discard b.replaceText(Pos(line: ln, col: 0), Pos(line: ln, col: ind), newWs)
            b.cursors[i] = cur(Pos(line: ln, col: cc - ind + newWs.len))
    # a line that has become one of the language's dedent words alone (`end`): one level out, when it is as far in
    # as the line above (typed again, it stays)
    if lang.dedentWords.len > 0 and ch.len == 1 and isWordByte(c0) and not cu.hasSel:
      let ln = p0.line
      let s = b.lines[ln]
      let cc = p0.col + caret
      if cc <= s.len and s[cc .. ^1].strip.len == 0 and s.strip in lang.dedentWords and
         (cc == s.len or not isWordByte(s[cc])):
        let ind = s.len - s.strip(trailing = false).len
        var pl = ln - 1
        while pl >= 0 and b.lines[pl].strip.len == 0: dec pl
        let pind = if pl >= 0: b.lines[pl].len - b.lines[pl].strip(trailing = false).len else: 0
        if ind > 0 and ind >= pind:
          let w = b.indentW()
          let target = max(0, visColOf(s, ind) - w)
          let newWs = if b.indent == "\t": repeat('\t', target div b.tabOf) else: spaces(target)
          discard b.replaceText(Pos(line: ln, col: 0), Pos(line: ln, col: ind), newWs)
          b.cursors[i] = cur(Pos(line: ln, col: cc - ind + newWs.len))
  b.endEdit()
  b.normalize()

proc shouldIndent(b: Buffer, line: int, t: string, lang: Lang = nil): bool =
  ## does a new line after `t` go one level in? `lang`: the language there (C inside a Nim emit …)
  if t.len == 0: return false
  let lang = if lang != nil: lang else: b.lang
  let tk = b.tokenAt(Pos(line: line, col: t.len - 1))
  if tk in {tkComment, tkDoc, tkString}: return false
  if t[^1] in lang.indentChars:
    if lang.mode == lmNim and t[^1] == ',': return false
    return true
  for w in lang.indentWords:
    if t == w or t.endsWith(" " & w) or t.endsWith("\t" & w): return true
  false

proc newline(b: Buffer) =
  if not b.canEdit(): return
  b.beginEdit()
  for i in countdown(b.cursors.high, 0):
    var (a, e) = b.cursors[i].range
    let line = b.lines[a.line]
    let before = line[0 ..< a.col]
    let after = b.lines[e.line][e.col .. ^1]
    let ind = leadingWs(before)
    let trimmed = before.strip(leading = false)
    let lang = b.langAt(a)                 # C inside a Nim emit indents as C; a Markdown code block as its code
    var extra = if b.shouldIndent(a.line, trimmed, lang): b.indent else: ""
    var text = "\n" & ind & extra
    var caret = Pos(line: -1)
    # markdown / plain list continuation
    if lang.mode == lmMarkdown:
      let t = trimmed.strip(trailing = false)
      var marker = ""
      if t.len >= 2 and t[0] in {'-', '*', '+'} and t[1] == ' ':
        marker = t[0..1]
        if t.startsWith(marker & "[ ] ") or t.startsWith(marker & "[x] "): marker.add "[ ] "
      else:
        var d = 0
        while d < t.len and t[d] in Digits: inc d
        if d > 0 and d + 1 < t.len and t[d] == '.' and t[d+1] == ' ':
          marker = $(parseInt(t[0 ..< d]) + 1) & ". "
      if marker.len > 0:
        if t.strip() in ["-", "*", "+", "- [ ]", "* [ ]"] or (t.len <= marker.len + 1 and t.endsWith(". ")):
          discard b.replaceText(Pos(line: a.line, col: 0), e, "")
          b.cursors[i] = cur(Pos(line: a.line, col: 0))
          continue
        text = "\n" & ind & marker
    # a doc comment goes on (editor.continueComments): `##` in Nim, `///` `//!` in C, C++, Rust …, ` * ` in a
    # /** … */ block — when the line is that comment (not code with a comment after it)
    if cfgContinueComments and lang.mode != lmMarkdown and isBlank(after):
      let t = before.strip(trailing = false)
      var mark = ""
      if lang.docLine.len > 0 and t.startsWith(lang.docLine) and not t.startsWith(lang.docLine & "[") and
         t.len >= lang.docLine.len:
        mark = lang.docLine & " "
      elif lang.lineComment == "//" and t.startsWith("//!"):
        mark = "//! "
      elif lang.blockStart == "/*" and b.tokenAt(Pos(line: a.line, col: max(0, a.col - 1))) in {tkComment, tkDoc} and
           "*/" notin t and (t.startsWith("/**") or t.startsWith("* ") or t == "*"):
        mark = (if t.startsWith("/**"): " * " else: "* ")
      if mark.len > 0 and b.tokenAt(Pos(line: a.line, col: max(0, a.col - 1))) in {tkComment, tkDoc}:
        text = "\n" & ind & mark
    # split brackets: {|} -> {\n  |\n}
    let prevC = if trimmed.len > 0: trimmed[^1] else: '\0'
    let afterT = after.strip(trailing = false)
    let nextC = if afterT.len > 0: afterT[0] else: '\0'
    if prevC != '\0' and nextC != '\0' and pairClose("()[]{}", prevC) == nextC:
      if extra.len == 0: extra = b.indent
      text = "\n" & ind & extra & "\n" & ind
      caret = Pos(line: a.line + 1, col: (ind & extra).len)
    # drop whitespace-only content and leading spaces of the moved text
    if isBlank(before) and before.len > 0:
      a = Pos(line: a.line, col: 0)
    var k = 0
    while k < after.len and after[k] in {' ', '\t'}: inc k
    if k > 0: e = Pos(line: e.line, col: e.col + k)
    let p = b.replaceText(a, e, text)
    b.cursors[i] = cur(if caret.line >= 0: caret else: p)
  b.endEdit()
  b.normalize()

proc backspace(b: Buffer, word = false) =
  if not b.canEdit(): return
  b.beginEdit(ekDelete)
  for i in countdown(b.cursors.high, 0):
    let cu = b.cursors[i]
    if cu.hasSel:
      let (a, e) = cu.range
      b.cursors[i] = cur(b.replaceText(a, e, ""))
      continue
    let h = cu.head
    if h.col == 0:
      if h.line == 0: continue
      let a = Pos(line: h.line - 1, col: b.lines[h.line - 1].len)
      b.cursors[i] = cur(b.replaceText(a, h, ""))
      continue
    let s = b.lines[h.line]
    var a: Pos
    let pre = s[0 ..< h.col]
    if word:
      a = b.posWordLeft(h)
    elif b.indent != "\t" and pre.len > 0 and pre.allCharsInSet({' '}):
      let w = b.indentW()
      a = Pos(line: h.line, col: ((h.col - 1) div w) * w)
    else:
      a = Pos(line: h.line, col: prevCluster(s, h.col))
      if h.col < s.len and a.col == h.col - 1 and pairClose(b.lang.pairs, s[a.col]) == s[h.col] and
         pairClose(b.lang.pairs, s[a.col]) != '\0':
        b.cursors[i] = cur(b.replaceText(a, Pos(line: h.line, col: h.col + 1), ""))
        continue
    b.cursors[i] = cur(b.replaceText(a, h, ""))
  b.endEdit()
  b.normalize()

proc deleteForward(b: Buffer, word = false) =
  if not b.canEdit(): return
  b.beginEdit(ekDelete)
  for i in countdown(b.cursors.high, 0):
    let cu = b.cursors[i]
    if cu.hasSel:
      let (a, e) = cu.range
      b.cursors[i] = cur(b.replaceText(a, e, ""))
      continue
    let h = cu.head
    let e = if word: b.posWordRight(h) else: b.posRight(h)
    if e != h: b.cursors[i] = cur(b.replaceText(h, e, ""))
  b.endEdit()
  b.normalize()

proc selectedLines(b: Buffer): seq[int] =
  var s: HashSet[int]
  for c in b.cursors:
    let (a, e) = c.range
    var last = e.line
    if e.line > a.line and e.col == 0: dec last
    for l in a.line .. last: s.incl l
  for l in s: result.add l
  result.sort()

proc lineBlocks(b: Buffer): seq[(int, int)] =
  for l in b.selectedLines():
    if result.len > 0 and result[^1][1] + 1 >= l: result[^1][1] = l
    else: result.add (l, l)

proc indentLines(b: Buffer, dir: int) =
  if not b.canEdit(): return
  b.beginEdit()
  for l in b.selectedLines():
    let s = b.lines[l]
    if dir > 0:
      if s.len > 0: discard b.replaceText(Pos(line: l, col: 0), Pos(line: l, col: 0), b.indent)
    else:
      var n = 0
      if s.len > 0 and s[0] == '\t': n = 1
      else:
        while n < s.len and n < b.indentW() and s[n] == ' ': inc n
      if n > 0: discard b.replaceText(Pos(line: l, col: 0), Pos(line: l, col: n), "")
  b.endEdit()
  b.normalize()

proc tabKey(b: Buffer) =
  if not b.canEdit(): return
  for c in b.cursors:
    if c.hasSel and c.anchor.line != c.head.line:
      b.indentLines(1)
      return
  b.beginEdit(ekType)
  for i in countdown(b.cursors.high, 0):
    let (a, e) = b.cursors[i].range
    var t = b.indent
    if b.indent != "\t":
      let vc = visColOf(b.lines[a.line], a.col)
      t = spaces(b.indentW() - vc mod b.indentW())
    b.cursors[i] = cur(b.replaceText(a, e, t))
  b.endEdit()
  b.normalize()

proc toggleComment(b: Buffer) =
  if not b.canEdit(): return
  # the language there: C in a Nim emit gets //, HTML in a string <!-- -->, a Markdown code block its own
  let sl0 = b.selectedLines()
  let fl = if sl0.len > 0: sl0[0] else: b.primary.head.line
  let lang = b.langAt(Pos(line: fl, col: leadingWs(b.lines[fl]).len))
  let tok = lang.lineComment
  if tok.len == 0:
    if lang.blockStart.len == 0 and lang.mode != lmHtml:
      info("No comment syntax for " & lang.name)
      return
    let (o, cl) = if lang.mode == lmHtml: ("<!-- ", " -->") else: (lang.blockStart & " ", " " & lang.blockEnd)
    b.beginEdit()
    for l in countdown(b.selectedLines().high, 0):
      let ln = b.selectedLines()[l]
      let s = b.lines[ln]
      let ind = leadingWs(s).len
      let body = s[ind .. ^1]
      if body.startsWith(o.strip) and body.endsWith(cl.strip):
        var inner = body[o.strip.len ..< body.len - cl.strip.len]
        inner = inner.strip()
        discard b.replaceText(Pos(line: ln, col: ind), Pos(line: ln, col: s.len), inner)
      elif body.len > 0:
        discard b.replaceText(Pos(line: ln, col: ind), Pos(line: ln, col: s.len), o & body & cl)
    b.endEdit()
    b.normalize()
    return
  let ls = b.selectedLines()
  var all = true
  var minInd = high(int)
  for l in ls:
    let s = b.lines[l]
    if isBlank(s): continue
    let ind = leadingWs(s).len
    minInd = min(minInd, ind)
    if not s[ind .. ^1].startsWith(tok): all = false
  if minInd == high(int): minInd = 0
  b.beginEdit()
  for l in ls:
    let s = b.lines[l]
    if isBlank(s) and ls.len > 1: continue
    if all:
      let ind = leadingWs(s).len
      var n = tok.len
      if ind + n < s.len and s[ind + n] == ' ': inc n
      discard b.replaceText(Pos(line: l, col: ind), Pos(line: l, col: min(ind + n, s.len)), "")
    else:
      let at = min(minInd, s.len)
      discard b.replaceText(Pos(line: l, col: at), Pos(line: l, col: at), tok & " ")
  b.endEdit()
  b.normalize()

proc moveLines(b: Buffer, dir: int) =
  if not b.canEdit(): return
  let blocks = b.lineBlocks()
  if blocks.len == 0: return
  if dir < 0 and blocks[0][0] == 0: return
  if dir > 0 and blocks[^1][1] >= b.lines.high: return
  let saved = b.cursors
  b.beginEdit()
  let order = if dir < 0: blocks else: blocks.reversed
  for (s, e) in order:
    if dir < 0:
      let text = b.lines[s .. e].join("\n") & "\n" & b.lines[s - 1]
      discard b.replaceText(Pos(line: s - 1, col: 0), Pos(line: e, col: b.lines[e].len), text)
    else:
      let text = b.lines[e + 1] & "\n" & b.lines[s .. e].join("\n")
      discard b.replaceText(Pos(line: s, col: 0), Pos(line: e + 1, col: b.lines[e + 1].len), text)
  b.cursors = saved
  for c in b.cursors.mitems:
    c.anchor.line += dir
    c.head.line += dir
  b.endEdit()
  b.normalize()

proc duplicate(b: Buffer) =
  if not b.canEdit(): return
  b.beginEdit()
  for i in countdown(b.cursors.high, 0):
    let cu = b.cursors[i]
    if cu.hasSel:
      let (a, e) = cu.range
      let t = b.getText(a, e)
      let p = b.replaceText(e, e, t)
      b.cursors[i] = Cursor(anchor: e, head: p, goalX: -1)
    else:
      let l = cu.head.line
      let s = b.lines[l]
      discard b.replaceText(Pos(line: l, col: s.len), Pos(line: l, col: s.len), "\n" & s)
      b.cursors[i] = cur(Pos(line: l + 1, col: cu.head.col))
  b.endEdit()
  b.normalize()

proc deleteLines(b: Buffer) =
  if not b.canEdit(): return
  let blocks = b.lineBlocks()
  b.beginEdit()
  for k in countdown(blocks.high, 0):
    let (s, e) = blocks[k]
    if e < b.lines.high:
      discard b.replaceText(Pos(line: s, col: 0), Pos(line: e + 1, col: 0), "")
    elif s > 0:
      discard b.replaceText(Pos(line: s - 1, col: b.lines[s - 1].len), Pos(line: e, col: b.lines[e].len), "")
    else:
      discard b.replaceText(Pos(line: s, col: 0), Pos(line: e, col: b.lines[e].len), "")
  for c in b.cursors.mitems:
    c.anchor = c.head
  b.endEdit()
  b.normalize()

func wordRangeAt(b: Buffer, p: Pos): (Pos, Pos) =
  if p.line < 0 or p.line >= b.lines.len: return (p, p)     # a position from before the text changed
  let s = b.lines[p.line]
  var a = min(max(p.col, 0), s.len)
  var e = p.col
  if (a >= s.len or not isWordByte(s[a])) and a > 0 and isWordByte(s[a-1]): dec a
  if a < s.len and isWordByte(s[a]):
    while a > 0 and isWordByte(s[a-1]): dec a
    e = a
    while e < s.len and isWordByte(s[e]): inc e
  else:
    a = min(max(p.col, 0), s.len)
    e = a
  (Pos(line: p.line, col: a), Pos(line: p.line, col: e))

func wordAt(b: Buffer, p: Pos): string =
  if p.line < 0 or p.line >= b.lines.len: return ""
  let (a, e) = b.wordRangeAt(p)
  b.lines[p.line][a.col ..< e.col]

proc selectLine(b: Buffer) =
  for c in b.cursors.mitems:
    let (a, e) = c.range
    let full = c.hasSel and a.col == 0 and e.col == 0 and e.line > a.line
    let startL = a.line
    var endL = if full: e.line else: e.line + 1
    if endL > b.lines.high:
      c.anchor = Pos(line: startL, col: 0)
      c.head = Pos(line: b.lines.high, col: b.lines[^1].len)
    else:
      c.anchor = Pos(line: startL, col: 0)
      c.head = Pos(line: endL, col: 0)
  b.normalize()

func rawFind(s, q: string, start: int, caseSens: bool): int =
  ## allocation-free substring search; for case-insensitive search `q` may be any case
  let n = q.len
  if n == 0 or start < 0: return -1
  if caseSens: return s.find(q, start)
  let f0 = toLowerAscii(q[0])
  let f1 = toUpperAscii(q[0])
  var i = start
  let last = s.len - n
  while i <= last:
    let c = s[i]
    if c == f0 or c == f1:
      var k = 1
      while k < n and toLowerAscii(s[i + k]) == toLowerAscii(q[k]): inc k
      if k == n: return i
    inc i
  -1
