# ── the Markdown preview's renderer: paragraphs reflowed, headings, lists nested (task lists ☐ ☑), quotes nested
#    (GitHub's > [!NOTE] too), tables with their columns lined up, code coloured, rules, pictures (drawn in the
#    terminal's cells), links a tap opens — each row knowing the source line it comes from, so the preview follows
#    the file ──

type MdBlock = object
  kind: char                 # p paragraph, h heading, l list item, q quote, c code, t table, r rule, i picture, x html
  level: int                 # heading level; list depth; quote depth
  text: string
  lang: string
  rows: seq[seq[string]]     # a table's cells
  aligns: seq[char]          # … its columns: l, c, r
  marker: string             # a list item's bullet or number; a task's [ ] / [x]
  src: int                   # the source line it starts at
  lines: seq[string]         # code

func mdIsRule(t: string): bool =
  ## whether a line is a horizontal rule: three or more `-`, `*` or `_` (spaces between allowed) and nothing else
  let x = t.replace(" ", "")
  x.len >= 3 and (x.allCharsInSet({'-'}) or x.allCharsInSet({'*'}) or x.allCharsInSet({'_'}))

func mdTableCells(t: string): seq[string] =
  ## the cells of a table row: the text between `|` bars (the outer ones optional), trimmed; `\|` and a bar inside
  ## backticks stay part of the cell
  var s = t.strip
  if s.startsWith("|"): s = s[1 .. ^1]
  if s.endsWith("|") and not s.endsWith("\\|"): s = s[0 ..< s.high]
  var cur = ""
  var i = 0
  var code = false
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len and s[i + 1] == '|':
      cur.add '|'
      i += 2
      continue
    if s[i] == '`': code = not code
    if s[i] == '|' and not code:
      result.add cur.strip
      cur = ""
    else: cur.add s[i]
    inc i
  result.add cur.strip

func mdIsTableSep(t: string): bool =
  ## whether a line is a table's separator row under the header (`|---|:--:|`): cells of at least a dash, with colons
  ## for alignment, three dashes in all
  let s = t.strip
  if '|' notin s and '-' notin s: return false
  if not s.allCharsInSet({'|', '-', ':', ' '}) or s.count('-') < 3: return false
  for c in mdTableCells(s):
    if c.len == 0 or '-' notin c: return false
  true

func mdListMark(t: string): (bool, string, string) =
  ## a list item's marker and its text: "- x" → ("•", "x"); "3. x" → ("3.", "x")
  if t.len >= 2 and t[0] in {'-', '*', '+'} and t[1] == ' ': return (true, $t[0], t[2 .. ^1])
  var k = 0
  while k < t.len and k < 9 and t[k] in Digits: inc k
  if k > 0 and k + 1 < t.len and t[k] in {'.', ')'} and t[k + 1] == ' ': return (true, t[0 .. k], t[k + 2 .. ^1])
  (false, "", "")

proc mdBlocks(text: string): seq[MdBlock] =
  ## the file's blocks, each with the line it starts at
  let ls = text.splitLines
  var i = 0
  var para: seq[string]
  var paraAt = -1
  proc flush(res: var seq[MdBlock]) =
    ## ends the paragraph being collected: adds it to the blocks as one text (lines joined by a space, or by a line
    ## break after two trailing spaces or a backslash)
    if para.len > 0:
      var t = ""
      for k, p in para:
        if k > 0:
          # (two spaces or a backslash at the end of a line: a line break)
          if para[k - 1].endsWith("  ") or para[k - 1].endsWith("\\"): t.add "\n" else: t.add " "
        t.add p.strip(chars = {' ', '\\'})
      res.add MdBlock(kind: 'p', text: t, src: paraAt)
      para.setLen(0)
  var inComment = false
  while i < ls.len:
    let raw = ls[i]
    let t = raw.strip
    let ind = raw.len - raw.strip(trailing = false).len
    if inComment:
      if "-->" in t: inComment = false
      inc i
      continue
    if t.startsWith("<!--"):
      flush(result)
      if "-->" notin t: inComment = true
      inc i
      continue
    if t.startsWith("```") or t.startsWith("~~~"):
      flush(result)
      let fence = t[0 ..< 3]
      var b = MdBlock(kind: 'c', lang: t[3 .. ^1].strip, src: i)
      inc i
      while i < ls.len and not ls[i].strip.startsWith(fence):
        b.lines.add ls[i]
        inc i
      inc i
      result.add b
      continue
    if t.len == 0:
      flush(result)
      inc i
      continue
    if ind >= 4 and para.len == 0 and (result.len == 0 or result[^1].kind != 'l'):
      # an indented code block
      var b = MdBlock(kind: 'c', src: i)
      while i < ls.len and (ls[i].strip.len == 0 or ls[i].len - ls[i].strip(trailing = false).len >= 4):
        b.lines.add (if ls[i].len >= 4: ls[i][4 .. ^1] else: "")
        inc i
      while b.lines.len > 0 and b.lines[^1].strip.len == 0: b.lines.setLen(b.lines.len - 1)
      result.add b
      continue
    if t.startsWith("#"):
      var k = 0
      while k < t.len and t[k] == '#': inc k
      if k <= 6 and (k == t.len or t[k] == ' '):
        flush(result)
        result.add MdBlock(kind: 'h', level: k, text: t[k .. ^1].strip(chars = {' ', '#'}), src: i)
        inc i
        continue
    if para.len > 0 and (t.allCharsInSet({'='}) or (t.allCharsInSet({'-'}) and t.len >= 2)):
      # a heading underlined (Setext)
      let text = para.join(" ")
      let at = paraAt
      para.setLen(0)
      result.add MdBlock(kind: 'h', level: (if t[0] == '=': 1 else: 2), text: text, src: at)
      inc i
      continue
    if mdIsRule(t):
      flush(result)
      result.add MdBlock(kind: 'r', src: i)
      inc i
      continue
    if t.startsWith(">"):
      flush(result)
      var depth = 0
      var s = t
      while s.startsWith(">"):
        inc depth
        s = s[1 .. ^1].strip(trailing = false)
      var lines = @[s]
      let at = i
      inc i
      while i < ls.len:
        var u = ls[i].strip
        if not u.startsWith(">"): break
        var d = 0
        while u.startsWith(">"):
          inc d
          u = u[1 .. ^1].strip(trailing = false)
        if d != depth: break
        lines.add u
        inc i
      result.add MdBlock(kind: 'q', level: depth, text: lines.join("\n"), src: at)
      continue
    if '|' in t and i + 1 < ls.len and mdIsTableSep(ls[i + 1]):
      flush(result)
      var b = MdBlock(kind: 't', src: i)
      b.rows.add mdTableCells(t)
      for c in mdTableCells(ls[i + 1]):
        b.aligns.add (if c.startsWith(":") and c.endsWith(":"): 'c' elif c.endsWith(":"): 'r' else: 'l')
      i += 2
      while i < ls.len and '|' in ls[i] and ls[i].strip.len > 0:
        b.rows.add mdTableCells(ls[i])
        inc i
      result.add b
      continue
    let (isItem, mark, rest) = mdListMark(t)
    if isItem:
      flush(result)
      var b = MdBlock(kind: 'l', level: ind div 2, marker: mark, text: rest, src: i)
      if rest.startsWith("[ ] ") or rest.startsWith("[x] ") or rest.startsWith("[X] "):
        b.marker = (if rest[1] == ' ': "[ ]" else: "[x]")
        b.text = rest[4 .. ^1]
      inc i
      # its lines that go on (indented, not an item of their own)
      while i < ls.len and ls[i].strip.len > 0 and not mdListMark(ls[i].strip)[0] and
            ls[i].len - ls[i].strip(trailing = false).len > ind and not ls[i].strip.startsWith("```"):
        b.text.add " " & ls[i].strip
        inc i
      result.add b
      continue
    if t.startsWith("![") and t.endsWith(")") and t.find("](") > 0:
      flush(result)
      result.add MdBlock(kind: 'i', text: t, src: i)
      inc i
      continue
    if t.startsWith("<") and not t.startsWith("<http") and para.len == 0:
      flush(result)
      result.add MdBlock(kind: 'x', text: t, src: i)
      inc i
      continue
    if para.len == 0: paraAt = i
    para.add raw
    inc i
  flush(result)

proc mdInline(s: string, fg, bg: Rgb): seq[ChatSpan] =
  ## **bold**, *italic* / _italic_, ~~struck~~, `code`, [links](…), <https://…>, bare https:// links, ![pictures](…)
  var i = 0
  var cur = ""
  var bold, ital, strike = false
  template attrs(): set[Attr] =
    ## the text attributes for the bold, italic and strike-through switches now on
    (if bold: {aBold} else: {}) + (if ital: {aItalic} else: {}) + (if strike: {aStrike} else: {})
  proc flush(res: var seq[ChatSpan]) =
    ## adds the plain text collected so far as a span in the current attributes and starts collecting again
    if cur.len > 0:
      res.add ChatSpan(t: cur, fg: fg, bg: bg, at: attrs())
      cur = ""
  while i < s.len:
    let c = s[i]
    if c == '\\' and i + 1 < s.len and s[i + 1] in {'*', '_', '`', '[', ']', '(', ')', '#', '|', '~', '\\', '<', '>', '!'}:
      cur.add s[i + 1]
      i += 2
      continue
    if c == '\n':
      flush(result)
      result.add ChatSpan(t: "\n", fg: fg, bg: bg)
      inc i
      continue
    if c == '`':
      var n = 1
      while i + n < s.len and s[i + n] == '`': inc n
      let fence = repeat('`', n)
      let e = s.find(fence, i + n)
      if e > i:
        flush(result)
        result.add ChatSpan(t: s[i + n ..< e].strip, fg: theme.syn[tkString], bg: theme.codeBg)
        i = e + n
        continue
    if (c == '*' or c == '_') and i + 1 < s.len and s[i + 1] == c:
      flush(result)
      bold = not bold
      i += 2
      continue
    if c == '~' and i + 1 < s.len and s[i + 1] == '~':
      flush(result)
      strike = not strike
      i += 2
      continue
    if (c == '*' or (c == '_' and (i == 0 or s[i - 1] notin IdentChars))) and i + 1 < s.len and s[i + 1] != ' ':
      let e = s.find(c, i + 1)
      if e > i + 1 and (c == '*' or e + 1 >= s.len or s[e + 1] notin IdentChars):
        flush(result)
        ital = not ital
        for sp in mdInline(s[i + 1 ..< e], fg, bg):
          var x = sp
          x.at = x.at + attrs()
          result.add x
        ital = not ital
        i = e + 1
        continue
    if c == '!' and i + 1 < s.len and s[i + 1] == '[':
      let cb = s.find(']', i + 2)
      if cb > 0 and cb + 1 < s.len and s[cb + 1] == '(':
        let ce = s.find(')', cb + 2)
        if ce > 0:
          flush(result)
          let alt = s[i + 2 ..< cb]
          let target = s[cb + 2 ..< ce].split(' ')[0]
          result.add ChatSpan(t: "▣ " & (if alt.len > 0: alt else: extractFilename(target)), fg: theme.accent, bg: bg,
                              at: {aUnder}, link: target)
          i = ce + 1
          continue
    if c == '[':
      let cb = s.find(']', i + 1)
      if cb > 0 and cb + 1 < s.len and s[cb + 1] == '(':
        var d = 0
        var ce = -1
        for k in cb + 1 ..< s.len:
          if s[k] == '(': inc d
          elif s[k] == ')':
            dec d
            if d == 0:
              ce = k
              break
        if ce > 0:
          flush(result)
          let target = s[cb + 2 ..< ce].split(' ')[0].strip(chars = {'<', '>'})
          for sp in mdInline(s[i + 1 ..< cb], theme.info, bg):
            var x = sp
            x.at = x.at + {aUnder} + attrs()
            x.link = target
            result.add x
          i = ce + 1
          continue
      if cb > 0 and s[i + 1 ..< cb].startsWith("^"):
        flush(result)
        result.add ChatSpan(t: "[" & s[i + 2 ..< cb] & "]", fg: theme.dim, bg: bg)     # a footnote's mark
        i = cb + 1
        continue
    if c == '<' and (s.continuesWith("<http://", i) or s.continuesWith("<https://", i)):
      let e = s.find('>', i)
      if e > 0:
        flush(result)
        result.add ChatSpan(t: s[i + 1 ..< e], fg: theme.info, bg: bg, at: {aUnder}, link: s[i + 1 ..< e])
        i = e + 1
        continue
    if c == '<' and (s.continuesWith("<br>", i) or s.continuesWith("<br/>", i) or s.continuesWith("<br />", i)):
      flush(result)
      result.add ChatSpan(t: "\n", fg: fg, bg: bg)
      i = s.find('>', i) + 1
      continue
    if (s.continuesWith("https://", i) or s.continuesWith("http://", i)) and (i == 0 or s[i - 1] in {' ', '('}):
      var e = i
      while e < s.len and s[e] notin {' ', ')', '>', '"'}: inc e
      while e > i and s[e - 1] in {'.', ',', ';', ':'}: dec e
      flush(result)
      result.add ChatSpan(t: s[i ..< e], fg: theme.info, bg: bg, at: {aUnder} + attrs(), link: s[i ..< e])
      i = e
      continue
    cur.add c
    inc i
  flush(result)

proc mdWrap(spans: seq[ChatSpan], width: int, bg: Rgb, indent, firstIndent: int, src: int,
            prefix: seq[ChatSpan] = @[]): seq[ChatLine] =
  ## spans word-wrapped (a "\n" span breaks the line), each row with its source line; `prefix` begins every row
  ## (a quote's bars)
  var line = ChatLine(bg: bg, src: src, spans: prefix)
  var col = firstIndent
  if col > 0: line.spans.add span(spaces(col), theme.fg, bg)
  proc newRow(res: var seq[ChatLine]) =
    ## ends the row being built and starts the next one with the quote bars and the hanging indent
    res.add line
    line = ChatLine(bg: bg, src: src, spans: prefix)
    if indent > 0: line.spans.add span(spaces(indent), theme.fg, bg)
    col = indent
  var pw = 0
  for p in prefix: pw += strWidth(p.t)
  let room = max(8, width - pw)
  for sp in spans:
    if sp.t == "\n":
      newRow(result)
      continue
    var words: seq[string]
    var cur = ""
    for ch in sp.t:
      cur.add ch
      if ch == ' ':
        words.add cur
        cur = ""
    if cur.len > 0: words.add cur
    for wd0 in words:
      var wd = wd0
      let ww = strWidth(wd.strip(leading = false))
      if col + ww > room and col > indent:
        newRow(result)
        wd = wd.strip(trailing = false)
      while strWidth(wd) > room - indent and room - indent > 4:
        let cut = colAtVis(wd, room - col)
        var x = sp
        x.t = wd[0 ..< max(1, cut)]
        line.spans.add x
        newRow(result)
        wd = wd[max(1, cut) .. ^1]
      var x = sp
      x.t = wd
      line.spans.add x
      col += strWidth(wd)
  result.add line

func mapSpans(sp: seq[ChatSpan], add: set[Attr]): seq[ChatSpan] =
  ## the spans with the attributes `add` added to each
  for x in sp:
    var y = x
    y.at = y.at + add
    result.add y

proc mdLineCode(code: seq[string], lang: string, width: int, src: int): seq[ChatLine] =
  ## a code block as rows on the code background: the language's name first (when given), then each line coloured with
  ## the syntax colours of that language (tabs as four spaces); each row knows its source line
  let l0 = if lang.len > 0: langByName(lang) else: nil
  let l = if l0 != nil and l0.name != "Text": l0 elif lang.len > 0: detectLang("x." & lang, "") else: langByName("Text")
  if lang.len > 0:
    result.add ChatLine(bg: theme.codeBg, src: src, spans: @[span(" " & lang, theme.dim, theme.codeBg)])
  var st: LexSt = 0
  var toks: seq[TokKind]
  for k, cl0 in code:
    let cl = cl0.replace("\t", "    ")
    st = lexLine(l, cl, st, toks)
    var row = ChatLine(bg: theme.codeBg, src: src + 1 + k)
    row.spans.add span(" ", theme.fg, theme.codeBg)
    var i = 0
    while i < cl.len:
      var j = i
      let tk = if i < toks.len: toks[i] else: tkText
      while j < cl.len and (if j < toks.len: toks[j] else: tkText) == tk: inc j
      row.spans.add span(cl[i ..< j], theme.syn[tk], theme.codeBg, (if tk in {tkComment, tkDoc}: {aItalic} else: {}))
      i = j
    result.add row

proc mdRender(text: string, width: int, bg: Rgb, baseDir: string): seq[ChatLine] =
  ## the Markdown as rows for the preview
  let blocks = mdBlocks(text)
  var counters: seq[int]                          # (each list depth's number, for 1. 2. 3. when written all as 1.)
  for bi, b in blocks:
    let gap = bi > 0 and not (b.kind == 'l' and blocks[bi - 1].kind == 'l')
    if gap and result.len > 0: result.add ChatLine(bg: bg, src: b.src)
    if b.kind != 'l': counters.setLen(0)
    case b.kind
    of 'h':
      let col = if b.level <= 2: theme.accent else: theme.syn[tkHeading]
      result.add mdWrap(mdInline(b.text, col, bg).mapSpans({aBold}), width, bg, 1, 1, b.src)
      if b.level <= 2:
        result.add ChatLine(bg: bg, src: b.src, spans: @[span(" " & repeat((if b.level == 1: "━" else: "─"),
                                                         max(4, min(width - 2, strWidth(b.text) + 2))),
                                                         blend(col, bg, 0.4), bg)])
    of 'p': result.add mdWrap(mdInline(b.text, theme.fg, bg), width, bg, 1, 1, b.src)
    of 'l':
      while counters.len <= b.level: counters.add 0
      counters.setLen(b.level + 1)
      inc counters[b.level]
      let ind = 1 + b.level * 3
      var mark = case b.marker
        of "[ ]": "☐ "
        of "[x]": "☑ "
        of "-", "*", "+": ["• ", "◦ ", "▪ "][b.level mod 3]
        else: (if b.marker.len > 1 and b.marker[0 .. ^2] == "1" and counters[b.level] > 1:
                 $counters[b.level] & b.marker[^1] & " "
               else: b.marker & " ")
      let done = b.marker == "[x]"
      var sp = @[span(mark, (if done: theme.gitAdd elif b.marker == "[ ]": theme.dim else: theme.accent), bg)]
      for x in mdInline(b.text, (if done: theme.dim else: theme.fg), bg):
        var y = x
        if done: y.at.incl aStrike
        sp.add y
      result.add mdWrap(sp, width, bg, ind + strWidth(mark), ind, b.src)
    of 'q':
      var bars: seq[ChatSpan]
      var col = theme.dim
      var text = b.text
      # GitHub's alerts: > [!NOTE], [!TIP], [!IMPORTANT], [!WARNING], [!CAUTION]
      for (k, c, label) in [("[!NOTE]", theme.info, "ℹ Note"), ("[!TIP]", theme.gitAdd, "✓ Tip"),
                            ("[!IMPORTANT]", theme.accent, "! Important"), ("[!WARNING]", theme.warn, "▲ Warning"),
                            ("[!CAUTION]", theme.err, "✗ Caution")]:
        if text.startsWith(k):
          col = c
          text = text[k.len .. ^1].strip(chars = {'\n', ' '})
          for _ in 1 .. b.level: bars.add span("▎ ", col, bg)
          result.add ChatLine(bg: bg, src: b.src, spans: bars & @[span(label, col, bg, {aBold})])
          bars.setLen(0)
          break
      for _ in 1 .. b.level: bars.add span("▎ ", col, bg)
      let parts = text.split("\n\n")
      for k, part in parts:
        if k > 0: result.add ChatLine(bg: bg, src: b.src, spans: bars)
        result.add mdWrap(mdInline(part.replace("\n", " "), (if col == theme.dim: theme.dim else: theme.fg), bg),
                          width, bg, 0, 0, b.src, bars)
    of 'c': result.add mdLineCode(b.lines, b.lang, width, b.src)
    of 'r':
      result.add ChatLine(bg: bg, src: b.src, spans: @[span(" " & repeat("─", max(4, width - 2)), theme.border, bg)])
    of 'x':
      result.add ChatLine(bg: bg, src: b.src, spans: @[span(" " & b.text, theme.dim, bg)])
    of 'i':
      # a picture on a line of its own: drawn (cells), else its name to tap
      let cb = b.text.find("](")
      let alt = b.text[2 ..< b.text.find(']')]
      let target = b.text[cb + 2 ..< b.text.high].split(' ')[0].strip(chars = {'<', '>'})
      let path = if target.isAbsolute or "://" in target: target else: baseDir / target
      let cols = max(8, min(width - 2, 80))
      let n = if "://" in target or not fileExists(path): 0 else: mdPicRows(path, cols)
      if n > 0:
        for k in 0 ..< n: result.add ChatLine(bg: bg, src: b.src, pic: path, picRow: k, picRows: n)
        if alt.len > 0: result.add ChatLine(bg: bg, src: b.src, spans: @[span(" " & alt, theme.dim, bg, {aItalic})])
      else:
        result.add ChatLine(bg: bg, src: b.src, spans: @[span(" ▣ " & (if alt.len > 0: alt else: target), theme.accent,
                                                              bg, {aUnder}), span("  " & target, theme.dim, bg)])
        result[^1].spans[0].link = target
    of 't':
      # the columns' widths: what the cells need, the widest cut down until the table fits
      var ncol = 0
      for r in b.rows: ncol = max(ncol, r.len)
      var cells: seq[seq[seq[ChatSpan]]]
      var want = newSeq[int](ncol)
      for r in b.rows:
        var row: seq[seq[ChatSpan]]
        for ci in 0 ..< ncol:
          let sp = mdInline((if ci < r.len: r[ci] else: ""), theme.fg, bg)
          var w = 0
          for x in sp: w += strWidth(x.t)
          want[ci] = max(want[ci], w)
          row.add sp
        cells.add row
      var widths = want
      let avail = max(ncol * 4, width - 2 - (ncol + 1) - ncol * 2)
      proc sum(xs: seq[int]): int =
        ## the total of the numbers
        for x in xs: result += x
      while sum(widths) > avail:
        var k = 0
        for ci in 1 ..< ncol:
          if widths[ci] > widths[k]: k = ci
        if widths[k] <= 3: break
        dec widths[k]
      let bc = theme.border
      proc rule(l, m, r: string): ChatLine =
        ## a horizontal border row of the table in box-drawing characters: `l` at the left end, `m` between columns, `r`
        ## at the right end
        var t = " " & l
        for ci in 0 ..< ncol:
          t.add repeat("─", widths[ci] + 2)
          t.add (if ci == ncol - 1: r else: m)
        ChatLine(bg: bg, src: b.src, spans: @[span(t, bc, bg)])
      result.add rule("┌", "┬", "┐")
      for ri, row in cells:
        # each cell wrapped to its column: the row as tall as its tallest cell
        var wrapped: seq[seq[ChatLine]]
        var tall = 1
        for ci in 0 ..< ncol:
          var sp = row[ci]
          if ri == 0:
            for x in sp.mitems: x.at.incl aBold
          let w = mdWrap(sp, widths[ci], bg, 0, 0, b.src + ri + (if ri > 0: 1 else: 0))
          wrapped.add w
          tall = max(tall, w.len)
        for k in 0 ..< tall:
          var line = ChatLine(bg: bg, src: b.src + ri + (if ri > 0: 1 else: 0))
          line.spans.add span(" │", bc, bg)
          for ci in 0 ..< ncol:
            var cellSp: seq[ChatSpan]
            var used = 0
            if k < wrapped[ci].len:
              for x in wrapped[ci][k].spans:
                cellSp.add x
                used += strWidth(x.t)
            let pad = max(0, widths[ci] - used)
            let a = if ci < b.aligns.len: b.aligns[ci] else: 'l'
            let left = if a == 'r': pad elif a == 'c': pad div 2 else: 0
            line.spans.add span(" " & spaces(left), theme.fg, bg)
            for x in cellSp: line.spans.add x
            line.spans.add span(spaces(pad - left) & " ", theme.fg, bg)
            line.spans.add span("│", bc, bg)
          result.add line
        if ri == 0: result.add rule("├", "┼", "┤")
      result.add rule("└", "┴", "┘")
    else: discard

proc mdHeadingAnchor(t: string): string =
  ## GitHub's anchor for a heading: lower case, spaces as -, other punctuation gone
  for c in t.toLowerAscii:
    if c in {'a'..'z', '0'..'9', '-', '_'} or ord(c) >= 0x80: result.add c
    elif c == ' ': result.add '-'
