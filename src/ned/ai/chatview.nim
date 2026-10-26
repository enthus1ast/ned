# ── chat rendering ──

func span(t: string, fg: Rgb, bg: Rgb = NoColor, at: set[Attr] = {}): ChatSpan = ChatSpan(t: t, fg: fg, bg: bg, at: at)

proc wrapSpans(spans: seq[ChatSpan], width: int, bg: Rgb, indent = 0, firstIndent = -1): seq[ChatLine] =
  ## word-wrap styled spans
  var line = ChatLine(bg: bg)
  var col = if firstIndent >= 0: firstIndent else: indent
  if col > 0: line.spans.add span(spaces(col), theme.fg, bg)
  for sp in spans:
    var words: seq[string]
    var cur = ""
    for ch in sp.t:
      cur.add ch
      if ch == ' ':
        words.add cur
        cur = ""
    if cur.len > 0: words.add cur
    for wd in words:
      var wd = wd
      let ww = strWidth(wd.strip(leading = false))
      if col + ww > width and col > indent:
        result.add line
        line = ChatLine(bg: bg)
        if indent > 0: line.spans.add span(spaces(indent), theme.fg, bg)
        col = indent
        wd = wd.strip(trailing = false)
      while strWidth(wd) > width - indent and width - indent > 4:
        let cut = colAtVis(wd, width - col)
        line.spans.add ChatSpan(t: wd[0 ..< max(1, cut)], fg: sp.fg, bg: sp.bg, at: sp.at)
        result.add line
        line = ChatLine(bg: bg)
        if indent > 0: line.spans.add span(spaces(indent), theme.fg, bg)
        col = indent
        wd = wd[max(1, cut) .. ^1]
      line.spans.add ChatSpan(t: wd, fg: sp.fg, bg: sp.bg, at: sp.at)
      col += strWidth(wd)
  result.add line

proc inlineSpans(s: string, fg, bg: Rgb): seq[ChatSpan] =
  ## **bold**, `code`, *italic*
  var i = 0
  var cur = ""
  var bold = false
  var ital = false
  proc flush(res: var seq[ChatSpan]) =
    if cur.len > 0:
      res.add ChatSpan(t: cur, fg: (if bold: theme.fg else: fg), bg: bg,
                       at: (if bold: {aBold} else: {}) + (if ital: {aItalic} else: {}))
      cur = ""
  while i < s.len:
    if s[i] == '`':
      let e = s.find('`', i + 1)
      if e > i:
        flush(result)
        result.add ChatSpan(t: s[i + 1 ..< e], fg: theme.syn[tkString], bg: theme.codeBg)
        i = e + 1
        continue
    if i + 1 < s.len and s[i] == '*' and s[i + 1] == '*':
      flush(result)
      bold = not bold
      i += 2
      continue
    if s[i] == '*' and i + 1 < s.len and s[i + 1] != ' ' and (i == 0 or s[i - 1] == ' '):
      let e = s.find('*', i + 1)
      if e > i + 1:
        flush(result)
        result.add ChatSpan(t: s[i + 1 ..< e], fg: fg, bg: bg, at: {aItalic})
        i = e + 1
        continue
    cur.add s[i]
    inc i
  flush(result)

proc applyCodeToFile(path, code: string) =
  ## a code block written for a whole file: show the diff, apply on confirmation (undoable)
  let b = openFile(path)
  if b == nil: return
  var nl = textLines(code)
  let d = unifiedDiff(b.lines, nl, "a/" & relPath(path), "b/" & relPath(path))
  if d.len == 0:
    info("The file already has this content")
    return
  let id = b.id
  discard openScratch("apply to " & relPath(path), d, langByName("Diff"))
  toast("Replace " & relPath(path) & " with the code block? (− removed, + added)", 3, "Apply", proc() =
    let bb = bufById(id)
    if bb == nil: return
    let i = bufs.find(bb)
    if i >= 0: curBuf = i
    bb.setTextMinimal(nl.join("\n"))
    info("Applied — review, then Ctrl+S (Ctrl+Z undoes)"), 30000)

func indentOf(s: string): string = s[0 ..< s.len - s.strip(trailing = false).len]

func opensBlock(b: Buffer, s: string): bool =
  ## does this line open an indented block (Nim/Python `:` `=`, braces, `do`, `->` …)?
  let t = s.strip
  if t.len == 0: return false
  var code = t
  let lc = b.lang.lineComment
  if lc.len > 0:
    let k = code.find(" " & lc)
    if k > 0: code = code[0 ..< k].strip
  code.endsWith(":") or code.endsWith("=") or code.endsWith("{") or code.endsWith("(") or code.endsWith("[") or
    code.endsWith(" do") or code.endsWith("->") or code.endsWith(" then")

proc insertCode(code: string) =
  ## put a code block from the chat into the file, cleanly: over the selection if there is one, else on
  ## lines of its own after the cursor's line (a whole proc/type/import after the block the cursor is
  ## in), re-indented to the code around it, with one blank line between it and its neighbours, as one
  ## undo step — then flash it so you see where it went
  let b = buf()
  if not b.canEdit(): return
  var src = textLines(code.replace("\r\n", "\n").replace("\t", (if b.indent == "\t": "\t" else: spaces(b.indentW()))))
  while src.len > 0 and src[0].strip.len == 0: src.delete(0)
  while src.len > 0 and src[^1].strip.len == 0: src.setLen(src.len - 1)
  if src.len == 0: return
  # remove the block's own common indentation
  var common = high(int)
  for l in src:
    if l.strip.len > 0: common = min(common, l.len - l.strip(trailing = false).len)
  if common == high(int): common = 0
  for l in src.mitems: l = (if l.strip.len == 0: "" else: l[min(common, l.len) .. ^1])
  let c = b.primary
  b.cursors = @[c]
  b.prim = 0
  var first, last: int                   # the inserted lines, for the flash
  b.beginEdit()
  if c.hasSel:
    let (a, e) = c.range
    let line0 = b.lines[a.line]
    let wholeLines = a.col <= indentOf(line0).len and (e.col == 0 or e.col >= b.lines[e.line].len or e.line > a.line)
    if wholeLines and (src.len > 1 or e.line > a.line):
      # whole lines selected: the block takes their place, at their indentation
      let ind = indentOf(line0)
      var ea = e
      if ea.col == 0 and ea.line > a.line: ea = Pos(line: ea.line - 1, col: b.lines[ea.line - 1].len)
      var outp: seq[string]
      for l in src: outp.add (if l.len == 0: "" else: ind & l)
      discard b.replaceText(Pos(line: a.line, col: 0), Pos(line: ea.line, col: b.lines[ea.line].len), outp.join("\n"))
      first = a.line
      last = a.line + outp.high
    else:
      # part of a line: the code goes right there; its further lines line up under the line's indentation
      let ind = indentOf(line0)
      var outp = @[src[0]]
      for l in src[1 .. ^1]: outp.add (if l.len == 0: "" else: ind & l)
      discard b.replaceText(a, e, outp.join("\n"))
      first = a.line
      last = a.line + outp.high
  else:
    let p = c.head
    let topLevel = src[0].len > 0 and src[0][0] notin {' ', '\t'} and (block:
      let w = src[0].strip.split({' ', '(', '[', '*', ':'})[0]
      w in b.lang.defWords or w in b.lang.classWords or
        w in ["type", "import", "from", "include", "export", "const", "#include", "use", "package", "struct",
              "enum", "class", "interface", "impl", "trait", "when", "def", "fn", "func", "function", "async",
              "pub", "static", "public", "private", "template", "macro"])
    var at: int                          # the new lines go before this line
    var ind = ""
    var inBlock = false                  # the cursor's line belongs to an indented block (or opens one)
    if b.lines[p.line].strip.len > 0:
      inBlock = indentOf(b.lines[p.line]).len > 0 or b.opensBlock(b.lines[p.line])
    else:
      var nx = p.line + 1
      while nx < b.lines.len and b.lines[nx].strip.len == 0: inc nx
      inBlock = nx < b.lines.len and indentOf(b.lines[nx]).len > 0
    if topLevel and (inBlock or b.lines[p.line].strip.len > 0):
      # a whole declaration: after the top-level block the cursor is in
      var l = p.line + 1
      while l < b.lines.len and (b.lines[l].strip.len == 0 or indentOf(b.lines[l]).len > 0): inc l
      while l > p.line + 1 and b.lines[l - 1].strip.len == 0: dec l
      at = l
    elif b.lines[p.line].strip.len == 0:
      # an empty line: the code goes here, indented like the code above it (or into the block it opens)
      at = p.line
      var k = p.line - 1
      while k >= 0 and b.lines[k].strip.len == 0: dec k
      if k >= 0 and not topLevel:
        ind = indentOf(b.lines[k])
        if b.opensBlock(b.lines[k]): ind.add (if b.indent == "\t": "\t" else: spaces(b.indentW()))
        else:
          var nx = p.line + 1
          while nx < b.lines.len and b.lines[nx].strip.len == 0: inc nx
          if nx < b.lines.len and indentOf(b.lines[nx]).len < ind.len and nx > p.line + 1: ind = indentOf(b.lines[nx])
    else:
      at = p.line + 1
      ind = indentOf(b.lines[p.line])
      if b.opensBlock(b.lines[p.line]): ind.add (if b.indent == "\t": "\t" else: spaces(b.indentW()))
    var outp: seq[string]
    for l in src: outp.add (if l.len == 0: "" else: ind & l)
    let replaceBlank = at < b.lines.len and at == p.line and b.lines[at].strip.len == 0
    # one blank line between the block and its neighbours — for declarations and multi-line blocks
    let spaced = topLevel or src.len > 1
    let above = if at - 1 >= 0: b.lines[at - 1] else: ""
    let belowIdx = if replaceBlank: at + 1 else: at
    let below = if belowIdx < b.lines.len: b.lines[belowIdx] else: ""
    var pre, post: seq[string]
    if spaced and at > 0 and above.strip.len > 0 and not (not topLevel and b.opensBlock(above)): pre.add ""
    if spaced and belowIdx < b.lines.len and below.strip.len > 0 and
       not (not topLevel and indentOf(below).len < ind.len): post.add ""
    let blk = pre & outp & post
    if replaceBlank:
      discard b.replaceText(Pos(line: at, col: 0), Pos(line: at, col: b.lines[at].len), blk.join("\n"))
    elif at < b.lines.len:
      discard b.replaceText(Pos(line: at, col: 0), Pos(line: at, col: 0), blk.join("\n") & "\n")
    else:
      discard b.replaceText(Pos(line: b.lines.high, col: b.lines[^1].len), Pos(line: b.lines.high, col: b.lines[^1].len),
                            "\n" & blk.join("\n"))
      at = b.lines.len - blk.len
    first = at + pre.len
    last = first + outp.high
  b.endEdit()
  last = min(last, b.lines.high)
  b.setSingle(Pos(line: last, col: b.lines[last].len))
  b.normalize()
  if first < b.topLine or last >= b.topLine + textH: b.centerOn(Pos(line: first, col: 0))
  flashBuf = b.id
  flashA = first
  flashB = last
  flashAt = getMonoTime()
  focus = fEditor
  info("Inserted " & $(last - first + 1) & " line(s) at line " & $(first + 1) & " — Ctrl+Z undoes it")

proc markdownLines(text: string, width: int, bg: Rgb, compact = false): seq[ChatLine] =
  ## Markdown → styled lines. compact: documentation popups (no code block headers, --- rules,
  ## "error:" / "warning:" lines in their colours)
  var inCode = false
  var lang: Lang = nil
  var codeBuf: seq[string]
  var fenceLang = ""
  var text = text
  if compact:
    # doc comments are hard-wrapped: join each paragraph's lines so it reflows to the popup's width
    var outp: seq[string]
    var fence = false
    var prevPlain = false
    var prevBullet = false
    for l in text.splitLines:
      let t = l.strip
      if t.startsWith("```"):
        fence = not fence
        outp.add l
        prevPlain = false
        continue
      let special = fence or t.len == 0 or t.startsWith("- ") or t.startsWith("* ") or t.startsWith("#") or
                    t.startsWith("> ") or t.startsWith("|") or t == "---" or t.startsWith("error: ") or
                    t.startsWith("warning: ") or (t.len > 2 and t[0] in Digits and t.find(". ") in 1 .. 3) or
                    l.startsWith("    ") or (t.startsWith("**") and t.endsWith("**"))
      let bullet = not fence and (t.startsWith("- ") or t.startsWith("* ") or
                                  (t.len > 2 and t[0] in Digits and t.find(". ") in 1 .. 3))
      if not special and prevPlain and outp.len > 0: outp[^1].add " " & t
      elif not fence and t.len > 0 and l.startsWith(" ") and prevBullet and not bullet and outp.len > 0:
        outp[^1].add " " & t                    # a list item continued on an indented line
        continue
      else: outp.add l
      prevPlain = not special
      prevBullet = bullet
    text = outp.join("\n")
  proc emitCode(res: var seq[ChatLine]) =
    let code = codeBuf.join("\n")
    let l = if lang != nil: lang else: langByName("Text")
    var hdrIdx = -1
    if not compact:
      var head = ChatLine(bg: theme.codeBg)
      head.spans.add span(" " & (if fenceLang.len > 0: fenceLang else: "code"), theme.dim, theme.codeBg)
      res.add head
      hdrIdx = res.high
    var st: LexSt = 0
    var toks: seq[TokKind]
    for cl0 in codeBuf:
      let cl = cl0.replace("\t", "    ")
      st = lexLine(l, cl, st, toks)
      # too long for the popup: wrapped (at a space or a comma when there is one), never cut off
      var segs: seq[(int, int)]
      var a = 0
      while a < cl.len or segs.len == 0:
        let avail = if segs.len == 0: width - 2 else: width - 4
        var i = a
        var w = 0
        var brk = -1
        while i < cl.len:
          let (cw, n) = charWidthAt(cl, i, w)
          if w + cw > avail: break
          w += cw
          i += n
          if cl[i - 1] in {' ', ','} and i < cl.len: brk = i
        if i >= cl.len:
          segs.add (a, cl.len)
          break
        let e = if brk > a + 8: brk elif i > a: i else: a + runeAt(cl, a)[1]
        segs.add (a, e)
        a = e
        while a < cl.len and cl[a] == ' ': inc a
      for si, (sa, se) in segs:
        var cline = ChatLine(bg: theme.codeBg)
        cline.spans.add span((if si == 0: " " else: "   "), theme.fg, theme.codeBg)
        var i = sa
        while i < se:
          var j = i
          let tk = if i < toks.len: toks[i] else: tkText
          while j < se and (if j < toks.len: toks[j] else: tkText) == tk: inc j
          cline.spans.add span(cl[i ..< j], theme.syn[tk], theme.codeBg, (if tk in {tkComment, tkDoc}: {aItalic} else: {}))
          i = j
        res.add cline
    # action buttons live on the header line
    if hdrIdx >= 0:
      res[hdrIdx].tip = code
      for tok in fenceLang.split({' ', ':', '=', '"', '\''}):
        if tok.len > 2 and '.' in tok and not tok.startsWith(".") and fileExists(absProjectPath(tok)):
          res[hdrIdx].file = absProjectPath(tok)
          break
    codeBuf.setLen(0)
  for raw in text.splitLines:
    if raw.strip.startsWith("```"):
      if inCode:
        emitCode(result)
        inCode = false
      else:
        inCode = true
        fenceLang = raw.strip[3 .. ^1].strip
        lang = if fenceLang.len > 0: langByName(fenceLang) else: nil
        if lang != nil and lang.name == "Text":
          lang = detectLang("x." & fenceLang, "")
      continue
    if inCode:
      codeBuf.add raw
      continue
    let s = raw.strip(leading = false)
    if s.len == 0:
      result.add ChatLine(bg: bg)
      continue
    let lead = s.len - s.strip(trailing = false).len
    let t = s.strip(trailing = false)
    if compact and (t == "---" or t == "***" or t == "___"):
      result.add ChatLine(bg: bg, spans: @[span(repeat("─", max(1, width)), theme.border, bg)])
      continue
    if compact and (t.startsWith("error: ") or t.startsWith("warning: ")):
      result.add wrapSpans(@[span(t, (if t[0] == 'e': theme.err else: theme.warn), bg)], width, bg, 1)
      continue
    if t.startsWith("#"):
      var k = 0
      while k < t.len and t[k] == '#': inc k
      result.add wrapSpans(@[span(t[k .. ^1].strip, theme.syn[tkHeading], bg, {aBold})], width, bg, 1)
    elif t.startsWith("- ") or t.startsWith("* ") or t.startsWith("+ "):
      var sp = @[span("• ", theme.accent, bg)]
      sp.add inlineSpans(t[2 .. ^1], theme.fg, bg)
      result.add wrapSpans(sp, width, bg, lead + 3, lead + 1)
    elif t.len > 2 and t[0] in Digits and (t.find(". ") in 1 .. 3):
      let d = t.find(". ")
      var sp = @[span(t[0 .. d], theme.accent, bg)]
      sp.add inlineSpans(t[d + 1 .. ^1], theme.fg, bg)
      result.add wrapSpans(sp, width, bg, lead + d + 3, lead + 1)
    elif t.startsWith("> "):
      result.add wrapSpans(@[span("▎ ", theme.dim, bg)] & inlineSpans(t[2 .. ^1], theme.dim, bg), width, bg, 3, 1)
    else:
      result.add wrapSpans(inlineSpans(t, theme.fg, bg), width, bg, 1)
  if inCode: emitCode(result)

proc callSummary(c: AiCall): string =
  var j: JsonNode
  try: j = parseJson(if c.args.strip.len == 0: "{}" else: c.args)
  except CatchableError: j = newJObject()
  case c.name
  of "read_file": "read " & j{"path"}.getStr & (if j{"start_line"} != nil: ":" & $j{"start_line"}.getInt & "-" & $j{"end_line"}.getInt else: "")
  of "list_files": "list files" & (if j{"filter"}.getStr.len > 0: " *" & j{"filter"}.getStr & "*" else: "")
  of "search": "search \"" & j{"query"}.getStr & "\""
  of "edit_file": "edit " & j{"path"}.getStr
  of "write_file": "write " & j{"path"}.getStr
  of "run_command": "$ " & j{"command"}.getStr
  of "get_diagnostics": "diagnostics " & j{"path"}.getStr
  else:
    if c.name.startsWith("mcp__") or c.name.startsWith("plugin__"):
      let parts = c.name[(if c.name.startsWith("mcp__"): 5 else: 8) .. ^1].split("__", 1)
      (if parts.len == 2: parts[0] & " · " & parts[1] else: c.name) & " " & truncTo($j, 60)
    else: c.name

proc buildChat(width: int): seq[ChatLine] =
  let bg = theme.dockBg
  if aiMsgs.len == 0:
    result.add ChatLine(bg: bg)
    result.add wrapSpans(@[span(ic("ai") & " Assistant", theme.accent, bg, {aBold})], width, bg, 2)
    result.add wrapSpans(@[span(cfgAiProvider & " · " & (if aiModel().len > 0: aiModel() else: "no model"), theme.dim, bg)], width, bg, 2)
    result.add ChatLine(bg: bg)
    result.add wrapSpans(@[span("Ask about your code. The current file (or selection) is sent along. " &
      (if cfgAiAgent: "In agent mode the assistant can read and edit files and run commands — you approve each change." else: ""),
      theme.dim, bg)], width, bg, 2)
    result.add ChatLine(bg: bg)
    for (label, prompt) in [("Explain this file", "Explain what this file does, briefly."),
                            ("Find bugs", "Review this code and list likely bugs or risky spots, most important first."),
                            ("Write tests", "Write unit tests for this code (for Nim use std/unittest) and add them to the project."),
                            ("Fix the problems", "Fix the compiler errors and warnings in this file."),
                            ("Make it faster", "Suggest concrete performance improvements for this code.")]:
      let p = prompt
      var l = ChatLine(bg: bg)
      l.spans.add span("  " & ic("chevR") & " ", theme.syn[tkFunc], bg)      # (the arrow coloured, the words plain)
      l.spans.add span(label, theme.fg, bg)
      capture p:
        l.act = proc() =
          let cb = buf()
          if p.startsWith("Write unit tests") and cb.lang.mode == lmNim and cb.path.endsWith(".nim") and haveExe("nim"):
            aiWriteTests()          # (Nim: written beside the project, kept only when they compile and pass)
          else: aiSend(p)
      l.tip = prompt
      result.add l
    if aiKey().len == 0 and cfgAiProvider notin ["ollama", "custom"]:
      result.add ChatLine(bg: bg)
      result.add wrapSpans(@[span(ic("warn") & " No API key: export " & aiKeyEnvName() &
        "=… in ~/.bashrc, or set ai.apiKey in settings.", theme.warn, bg)], width, bg, 2)
    return
  for mi, m in aiMsgs:
    case m.role
    of 0:
      result.add ChatLine(bg: bg)
      let ub = theme.userBg
      var head = ChatLine(bg: ub)
      head.spans.add span(" " & ic("user") & " You", theme.accent, ub, {aBold})
      result.add head
      for l in (if m.shown.len > 0: m.shown else: m.text).splitLines:
        result.add wrapSpans(@[span(l, theme.fg, ub)], width, ub, 2)
      # its pictures: drawn small (a tap opens one), each with its name and size
      for p in m.pics:
        let cols = max(8, min(width - 4, 36))
        let n = if fileExists(p): min(mdPicRows(p, cols), 12) else: 0
        for k in 0 ..< n: result.add ChatLine(bg: ub, pic: p, picRow: k, picRows: n)
        let (pw, ph) = picSize(p)
        let kb = try: $(getFileSize(p) div 1024) & " KB" except CatchableError: "gone"
        var l = ChatLine(bg: ub, spans: @[span("  ▣ " & extractFilename(p), theme.accent, ub),
                                          span("  " & (if pw > 0: $pw & "×" & $ph & ", " else: "") & kb, theme.dim, ub)])
        let pp = p
        l.act = proc() = discard openFile(pp)
        l.tip = ""
        result.add l
    of 1:
      if m.text.len > 0 or mi == 0 or aiMsgs[mi - 1].role notin {1, 2}: result.add ChatLine(bg: bg)
      if m.text.len > 0 or (m.calls.len == 0 and aiBusy and mi == aiMsgs.high):
        var head = ChatLine(bg: bg)
        head.spans.add span(" " & ic("ai") & " " & (if aiModel().len > 0: aiModel() else: "assistant"), theme.syn[tkKeyword], bg, {aBold})
        result.add head
      if m.text.len > 0: result.add markdownLines(m.text, width, bg)
      elif aiBusy and mi == aiMsgs.high and m.calls.len == 0:
        result.add wrapSpans(@[span(aiPhase, theme.dim, bg, {aItalic})], width, bg, 2)
      for ci, c in m.calls:
        let (icn, fg) = case c.state
          of 0: ("?", theme.warn)
          of 1: ("…", theme.accent)
          of 3: ("✗", theme.err)
          else: (if c.isError: ("✗", theme.err) else: (ic("ok"), theme.gitAdd))
        var l = ChatLine(bg: bg)
        l.spans.add span(" " & ic("tool") & " ", theme.dim, bg)
        let chk = if c.check == "ok": " · checked " & ic("ok") elif c.check.len > 0: " · " & ic("warn") & " " & c.check else: ""
        l.spans.add span(truncTo(callSummary(c), max(10, width - 8 - chk.strWidth)), theme.fg, bg)
        l.spans.add span(" " & icn, fg, bg, {aBold})
        if chk.len > 0: l.spans.add span(chk, (if c.check == "ok": theme.dim else: theme.err), bg)
        let m2 = mi
        let c2 = ci
        capture m2, c2:
          l.act = proc() =
            if m2 < aiMsgs.len and c2 < aiMsgs[m2].calls.len:
              aiMsgs[m2].calls[c2].expanded = not aiMsgs[m2].calls[c2].expanded
              inc aiVersion
        l.tip = "Show / hide details"
        result.add l
        if c.state == 0 and needsApproval(c) and mi == aiMsgs.high:
          # approval card: commands verbatim, file changes as a real diff
          var info = c.args
          var isDiff = false
          try:
            let j = parseJson(c.args)
            info = case c.name
              of "run_command": "$ " & j{"command"}.getStr & (if j{"cwd"}.getStr.len > 0: "\n  in " & j{"cwd"}.getStr else: "")
              of "edit_file", "write_file":
                isDiff = true
                diffForCall(c)
              of "read_file": "read " & j{"path"}.getStr
              else: c.args
          except CatchableError: discard
          if outsideProject(c):
            result.add wrapSpans(@[span(ic("warn") & " outside the project folder", theme.warn, theme.codeBg, {aBold})],
                                 width, theme.codeBg, 3)
          var shown = 0
          let dl = info.splitLines
          let cap = if isDiff: 22 else: 14
          for il in dl:
            if isDiff and (il.startsWith("--- ") or il.startsWith("+++ ")): continue
            if shown >= cap:
              var more = ChatLine(bg: theme.codeBg)
              more.spans.add span("   … " & $(dl.len - shown) & " more lines — open the diff", theme.accent, theme.codeBg)
              let m4 = mi
              let c4 = ci
              capture m4, c4:
                more.act = proc() = showCallDiff(m4, c4)
              more.tip = "Open the whole diff in a tab"
              result.add more
              break
            let fgL = if il.startsWith("+"): theme.gitAdd elif il.startsWith("-"): theme.err
                      elif il.startsWith("@@"): theme.dim else: theme.fg
            var cl = ChatLine(bg: theme.codeBg)
            cl.spans.add span("   " & truncTo(il, width - 4), fgL, theme.codeBg)
            result.add cl
            inc shown
          if isDiff:
            var dlL = ChatLine(bg: bg)
            dlL.spans.add span("   ", theme.fg, bg)
            dlL.spans.add span(" Open diff ", theme.fg, theme.btnBg)
            let m5 = mi
            let c5 = ci
            capture m5, c5:
              dlL.act = proc() = showCallDiff(m5, c5)
            dlL.tip = "Show the full change in a tab"
            result.add dlL
          for (lbl, allow, always, key) in [(" Allow (y) ", true, false, "y"), (" Always (a) ", true, true, "a"),
                                            (" Deny (n) ", false, false, "n")]:
            var bl = ChatLine(bg: bg)
            let fgB = if allow and not always: theme.badgeFg else: theme.fg
            let bgB = if allow and not always: theme.accent elif not allow: blend(bg, theme.err, 0.25) else: theme.btnBg
            bl.spans.add span("   ", theme.fg, bg)
            bl.spans.add span(lbl, fgB, bgB, {aBold})
            let m3 = mi
            let c3 = ci
            let al = allow
            let aw = always
            capture m3, c3, al, aw:
              bl.act = proc() = approveCall(m3, c3, al, aw)
            discard key
            result.add bl
        elif c.expanded and c.diff.len > 0 and not c.isError:
          var shown = 0
          for il in c.checkOut.splitLines:
            if il.len == 0: continue
            result.add wrapSpans(@[span("   " & il, theme.err, theme.codeBg)], width, theme.codeBg, 5)
          for il in c.diff.splitLines:
            if il.startsWith("--- ") or il.startsWith("+++ "): continue
            if shown >= 40:
              result.add wrapSpans(@[span("… open the diff for the rest", theme.dim, theme.codeBg)], width, theme.codeBg, 3)
              break
            let fgL = if il.startsWith("+"): theme.gitAdd elif il.startsWith("-"): theme.err else: theme.dim
            var cl = ChatLine(bg: theme.codeBg)
            cl.spans.add span("   " & truncTo(il, width - 4), fgL, theme.codeBg)
            result.add cl
            inc shown
        elif c.expanded and c.result.len > 0:
          var shown = 0
          for il in c.result.splitLines:
            if shown >= 40:
              result.add wrapSpans(@[span("… (" & $c.result.splitLines.len & " lines)", theme.dim, theme.codeBg)], width, theme.codeBg, 3)
              break
            var cl = ChatLine(bg: theme.codeBg)
            cl.spans.add span("   " & truncTo(il, width - 4), (if c.isError: theme.err else: theme.dim), theme.codeBg)
            result.add cl
            inc shown
    of 2: discard
    else:
      result.add ChatLine(bg: bg)
      for l in m.text.splitLines:
        result.add wrapSpans(@[span(l, theme.warn, bg)], width, bg, 2)
  if aiBusy and aiPhase.len > 0 and aiMsgs.len > 0 and (aiMsgs[^1].role != 1 or aiMsgs[^1].text.len > 0 or aiMsgs[^1].calls.len > 0):
    let spin = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"][int(getMonoTime().ticks div 100_000_000) mod 10]
    result.add wrapSpans(@[span(spin & " " & aiPhase, theme.accent, bg, {aItalic})], width, bg, 2)
  elif not aiBusy and aiMsgs.len > 0 and aiMsgs[^1].role in {1, 3}:
    # after the last reply: regenerate it, copy it
    var l = ChatLine(bg: bg)
    l.spans.add span("  ↻ " & (if aiMsgs[^1].role == 3: "Retry" else: "Regenerate"), theme.dim, bg)
    l.act = proc() = aiRegenerate()
    l.tip = "Ask again (/regen)"
    result.add ChatLine(bg: bg)
    result.add l
    if aiMsgs[^1].role == 1 and aiMsgs[^1].text.len > 0:
      var c = ChatLine(bg: bg)
      c.spans.add span("  ⧉ Copy reply", theme.dim, bg)
      let t = aiMsgs[^1].text
      c.act = proc() =
        clipSet(t)
        clipParts = @[t]
        clipLineMode = false
        info("Copied the reply")
      c.tip = "Copy the whole reply as Markdown"
      result.add c

var
  aiInputRect: tuple[x, y, w, h: int]
  aiChatRows = 0
  aiUsageShownBelow = ""

proc aiScroll(d: int) =
  aiScrollOff = max(0, aiScrollOff - d)
  needRender = true

proc toggleAiFast() =
  if cfgAiFastModel.len == 0:
    info("Set \"ai.fastModel\" first (palette › AI: settings…) — e.g. a mini / haiku model")
    return
  aiFastOn = not aiFastOn
  info("AI model: " & aiModel() & (if aiFastOn: " (fast)" else: " (smart)"))
  needRender = true

proc drawAssistant(x0, y0, w, h: int) =
  let bg = theme.dockBg
  fillRect(x0, y0, w, h, theme.fg, bg)
  # model line
  aiUsageShownBelow = ""
  var x = x0 + 1
  x = button(x, y0, " " & truncTo((if aiModel().len > 0: aiModel() else: "choose model"), max(8, w div 2)) & " " & ic("chevD") & " ",
             proc() = aiChooseModel(), "Model (" & cfgAiProvider & ")", theme.dim, bg)
  x = button(x + 1, y0, (if cfgAiAgent: " agent " & ic("ok") & " " else: " chat "), proc() =
    setSetting("ai.agent", %(not cfgAiAgent)), "Agent mode: the assistant may use tools",
    (if cfgAiAgent: theme.accent else: theme.dim), bg)
  x = button(x + 1, y0, " " & ic("history") & " ", proc() = cmdChatHistory(), "Chat history", theme.dim, bg)
  if cfgAiFastModel.len > 0:
    x = button(x + 1, y0, (if aiFastOn: " ⚡ fast " else: " smart "), proc() = toggleAiFast(),
               "Switch between ai.model and ai.fastModel", (if aiFastOn: theme.warn else: theme.dim), bg)
  if aiUsageIn + aiUsageOut > 0:
    let cost = aiCostText(aiUsageIn + aiUsageCacheWrite, aiUsageOut, aiUsageCacheRead)
    let u = fmtTokens(aiUsageIn + aiUsageCacheRead + aiUsageCacheWrite) & "↑ " & fmtTokens(aiUsageOut) & "↓" &
            (if cost.len > 0: " " & cost else: "")
    let tip = "Tokens this chat: " & $(aiUsageIn + aiUsageCacheRead + aiUsageCacheWrite) & " sent (" &
              $aiUsageCacheRead & " from cache), " & $aiUsageOut & " received" &
              (if cost.len > 0: " — about " & cost & " (ai.price)" else: " — set ai.price to see the cost")
    if x + strWidth(u) + 2 < x0 + w:
      discard putStr(x0 + w - strWidth(u) - 1, y0, u, theme.dim, bg)
      region(x0 + w - strWidth(u) - 1, y0, strWidth(u), 1, proc() = discard, tip)
    else: aiUsageShownBelow = u
  # input box (grows with content up to 6 rows)
  let iw = w - 4
  var inLines = wrapText(aiInput, max(4, iw - 2))
  if inLines.len == 0: inLines = @[""]
  let ih = clamp(inLines.len, 1, 6) + 2
  let iy = y0 + h - ih - 1
  let chatTop = y0 + 1
  let chatH = max(1, iy - chatTop)
  aiChatRows = chatH
  # chat
  let key = $aiVersion & "/" & $w & "/" & cfgThemeName & "/" & aiPhase & "/" & $aiBusy & "/" & cfgAiProvider & "/" &
            aiModel() & "/" & $aiKey().len
  if key != aiRenderedKey or aiBusy:
    aiRendered = buildChat(w - 1)
    aiRenderedKey = key
  let total = aiRendered.len
  aiScrollOff = clamp(aiScrollOff, 0, max(0, total - chatH))
  let start = max(0, total - chatH - aiScrollOff)
  for r in 0 ..< chatH:
    let li = start + r
    if li >= total: break
    let cl = aiRendered[li]
    let y = chatTop + r
    let rb = if cl.act != nil and hov(x0, y, w): blend(cl.bg, theme.fg, 0.08) else: cl.bg
    fillRect(x0, y, w, 1, theme.fg, rb)
    if cl.pic.len > 0:
      # a picture sent with a message: half blocks, two pixels' rows to a cell
      let cols = max(8, min(w - 5, 36))
      let cells = mdPicRow(cl.pic, cols, cl.picRows, cl.picRow)
      for k, (top, bot) in cells:
        if k >= w - 3: break
        setCell(x0 + 2 + k, y, Cell(ch: 0x2580, fg: top, bg: bot))
      let pp = cl.pic
      region(x0 + 2, y, min(w - 3, cells.len), 1, proc() = discard openFile(pp), "Open the picture")
      continue
    var xx = x0
    for sp in cl.spans:
      xx = putStr(xx, y, sp.t, sp.fg, (if sp.bg == NoColor or sp.bg == cl.bg: rb else: sp.bg), sp.at, x0 + w)
    if cl.act != nil:
      region(x0, y, w, 1, cl.act, cl.tip)
    elif cl.tip.len > 0:
      # code block header: copy / insert buttons
      let code = cl.tip
      var bx = x0 + w - 18
      capture code:
        bx = button(bx, y, " Copy ", proc() =
          clipSet(code)
          clipParts = @[code]
          clipLineMode = false
          info("Copied code"), "Copy code", theme.fg, theme.btnBg) + 1
        bx = button(bx, y, " Insert ", proc() = insertCode(code), "Insert at the cursor", theme.badgeFg, theme.accent) + 1
      if cl.file.len > 0 and bx + 8 < x0 + w:
        let f = cl.file
        capture code, f:
          discard button(x0 + w - 27, y, " Apply ", proc() = applyCodeToFile(f, code),
                         "Replace " & relPath(f) & " with this block (shows the diff first)", theme.fg, theme.btnBg)
  if aiScrollOff > 0:
    discard button(x0 + w - 12, iy - 1, " ↓ latest ", proc() = (aiScrollOff = 0), "", theme.badgeFg, theme.accent)
  # input
  let focused = focus == fRight and rightView == svAssistant
  aiInputRect = (x0 + 1, iy, w - 2, ih)
  drawFrame(x0 + 1, iy, w - 2, ih, theme.inputBg, (if focused: theme.focusBorder else: theme.border), "", NoColor, false)
  let tx = x0 + 3
  if aiInput.len == 0:
    let ph = if aiBusy: "Esc stops · " & aiPhase else: "Ask anything… (Enter sends · Alt+Enter new line)"
    discard putStr(tx, iy + 1, truncTo(ph, iw - 2), theme.dim, theme.inputBg, {aItalic})
    if focused:
      cursorX = tx
      cursorY = iy + 1
  else:
    # place the cursor: walk wrapped lines
    var off = 0
    var cyRow = 0
    var cxCol = 0
    var acc = 0
    for i, l in inLines:
      if aiInputCur >= acc and aiInputCur <= acc + l.len:
        cyRow = i
        cxCol = strWidth(aiInput[acc ..< min(aiInputCur, aiInput.len)])
      acc += l.len
      if acc < aiInput.len and aiInput[acc] in {' ', '\n'}: inc acc
    let shownRows = ih - 2
    off = max(0, cyRow - shownRows + 1)
    for r in 0 ..< shownRows:
      let li = off + r
      if li >= inLines.len: break
      discard putStr(tx, iy + 1 + r, inLines[li], theme.fg, theme.inputBg, {}, tx + iw - 1)
    if focused:
      cursorX = tx + min(cxCol, iw - 2)
      cursorY = iy + 1 + cyRow - off
  # send / stop button
  let lbl = if aiBusy: " " & ic("stop") & " " else: " " & ic("send") & " "
  discard button(x0 + w - 6, iy + ih - 2, lbl, proc() =
    if aiBusy: aiStop()
    else:
      let t = aiInput
      aiInput = ""
      aiInputCur = 0
      aiSend(t), (if aiBusy: "Stop (Esc)" else: "Send (Enter)"), (if aiBusy: theme.err else: theme.accent), theme.inputBg)
  region(x0 + 1, iy, w - 8, ih, proc() = (focus = fRight))
  # hint row
  var hint = if aiBusy: "Esc stop" else: "/ commands · @ context · ↑ history · Ctrl+L new chat"
  if aiInput.len > 0 and aiInput[0] == '/' and ' ' notin aiInput:
    var ms: seq[string]
    for c in slashNames():
      if c.toLowerAscii.startsWith(aiInput.toLowerAscii): ms.add c
    hint = if ms.len > 0: ms.join(" ") & "  (Tab)" else: "unknown command — /help"
  else:
    let lastW = if aiInputCur > 0: aiInput[0 ..< aiInputCur].splitWhitespace() else: @[]
    if lastW.len > 0 and lastW[^1].startsWith("@") and aiInputCur > 0 and aiInput[aiInputCur - 1] != ' ':
      var ms: seq[string]
      for m in mentionNames():
        if m.startsWith(lastW[^1]): ms.add m
      hint = (if ms.len > 0: ms.join(" ") & "  (Tab) · " else: "") & "@path attaches a file (a picture as one)"
    elif "@" in aiInput:
      let n = aiMentionedPics(aiInput, quiet = true).len
      if n > 0: hint = "▣ " & (if n == 1: "a picture goes" else: $n & " pictures go") & " with it · " & hint
  var hx = x0 + w - 1
  if aiUsageShownBelow.len > 0 and strWidth(aiUsageShownBelow) + 14 < w:     # tokens and cost win over the hint
    hx = x0 + w - strWidth(aiUsageShownBelow) - 1
    discard putStr(hx, y0 + h - 1, aiUsageShownBelow, theme.dim, bg)
  discard putStr(x0 + 2, y0 + h - 1, truncTo(hint, hx - x0 - 3), blend(theme.dim, bg, 0.3), bg, {}, hx)

proc aiAttachPicture() =
  ## AI: attach a picture… — the project's pictures, and the newest screenshots and photos (on a phone or tablet
  ## too: ~/storage/shared/… once termux-setup-storage has run), newest first
  var found: seq[(int64, string)]
  var seen: HashSet[string]
  proc add(p: string) =
    if p in seen or aiPicMime(p).len == 0: return
    seen.incl p
    let t = try: getLastModificationTime(p).toUnix except CatchableError: 0'i64
    found.add (t, p)
  for p in projectFiles():
    if isPicturePath(p): add(rootDir / p)
  # (a screenshot in the project is often new — not one git knows, so not in the file list): three levels down
  var level = @[rootDir]
  var seenFiles = 0
  for depth in 0 .. 2:
    var next: seq[string]
    for d in level:
      try:
        for k, p in walkDir(d):
          let n = extractFilename(p)
          if n.startsWith(".") or n in ["node_modules", "nimcache", "target", "build", "dist", "__pycache__"]: continue
          if k == pcDir: next.add p
          elif k in {pcFile, pcLinkToFile} and isPicturePath(p): add(p)
          inc seenFiles
          if seenFiles > 5000: break
      except OSError: discard
    level = next
  let h = getHomeDir()
  for d in [h / "storage" / "shared" / "Pictures" / "Screenshots", h / "storage" / "shared" / "DCIM" / "Screenshots",
            h / "storage" / "dcim" / "Camera", h / "storage" / "downloads", h / "Pictures" / "Screenshots",
            h / "Pictures", h / "Desktop", h / "Downloads"]:
    if not dirExists(d): continue
    var n = 0
    try:
      for k, p in walkDir(d):
        if k in {pcFile, pcLinkToFile}:
          add(p)
          inc n
          if n > 400: break
    except OSError: discard
  found.sort(proc(a, b: (int64, string)): int = cmp(b[0], a[0]))
  if found.len == 0:
    info("No pictures in the project, nor in the usual screenshot folders — type @ and a picture's path")
    return
  proc pick(p: string): Action = (proc() =
    let m = "@" & (if p.startsWith(rootDir & "/"): relPath(p) else: tildePath(p)) & " "
    aiInput.insert(m, min(aiInputCur, aiInput.len))
    aiInputCur = min(aiInputCur, aiInput.len - m.len) + m.len
    showSide(svAssistant)
    focus = fRight)
  var items: seq[(string, string, Action)]
  for (t, p) in found:
    if items.len >= 300: break
    let why = aiPicWhy(p)
    let (w, h) = picSize(p)
    items.add act(extractFilename(p), (if why.len > 0: why else: (if w > 0: $w & "×" & $h & " · " else: "") &
                  tildePath(parentDir(p))), pick(p))
  openActions("Attach a picture to the message", items)

func mentionInsertAct(m: string): Action =
  proc() =
    let t = m & " "
    aiInput.insert(t, aiInputCur)
    aiInputCur += t.len
    showSide(svAssistant)

proc pendingApproval(): (int, int) =
  if aiMsgs.len == 0: return (-1, -1)
  let mi = aiMsgs.high
  if aiMsgs[mi].role != 1: return (-1, -1)
  for ci, c in aiMsgs[mi].calls:
    if c.state == 0 and needsApproval(c): return (mi, ci)
  (-1, -1)

proc assistantKey(k: Key) =
  let (pm, pc) = pendingApproval()
  if pm >= 0 and k.kind == kChar and k.mods == {} and aiInput.len == 0 and k.ch in [ord('y'), ord('n'), ord('a')]:
    approveCall(pm, pc, k.ch != ord('n'), k.ch == ord('a'))
    return
  case k.kind
  of kEnter:
    if mAlt in k.mods or mShift in k.mods:
      aiInput.insert("\n", aiInputCur)
      inc aiInputCur
    elif not aiBusy:
      let t = aiInput
      aiInput = ""
      aiInputCur = 0
      aiHistIdx = -1
      aiSend(t)
  of kEsc:
    if aiBusy: aiStop()
    else:
      focus = fEditor
      if scrW < 70: rightOpen = false
  of kUp:
    if aiInput.len == 0 or aiHistIdx >= 0:
      if aiPromptHist.len == 0: return
      if aiHistIdx < 0: aiHistIdx = aiPromptHist.len
      aiHistIdx = max(0, aiHistIdx - 1)
      aiInput = aiPromptHist[aiHistIdx]
      aiInputCur = aiInput.len
    else: aiScroll(-1)
  of kDown:
    if aiHistIdx >= 0:
      inc aiHistIdx
      if aiHistIdx >= aiPromptHist.len:
        aiHistIdx = -1
        aiInput = ""
      else: aiInput = aiPromptHist[aiHistIdx]
      aiInputCur = aiInput.len
    else: aiScroll(1)
  of kPgUp: aiScroll(-(aiChatRows - 2))
  of kPgDn: aiScroll(aiChatRows - 2)
  of kTab:
    # complete /commands and @mentions; otherwise Tab moves to the next right-dock view
    if aiInput.len > 0 and aiInput[0] == '/' and ' ' notin aiInput:
      for c in slashNames():
        if c.toLowerAscii.startsWith(aiInput.toLowerAscii):
          aiInput = c & " "
          aiInputCur = aiInput.len
          return
    if aiInputCur > 0 and aiInput[aiInputCur - 1] != ' ':
      var st = aiInputCur
      while st > 0 and aiInput[st - 1] notin {' ', '\n'}: dec st
      let w = aiInput[st ..< aiInputCur]
      if w.startsWith("@"):
        for m in mentionNames():
          if m.startsWith(w) and m != w:
            aiInput = aiInput[0 ..< st] & m & " " & aiInput[aiInputCur .. ^1]
            aiInputCur = st + m.len + 1
            return
    if mShift in k.mods: showSide(svTimeline) else: showSide(svOutline)
  of kChar:
    if mCtrl in k.mods and k.ch == ord('l'):
      aiNewChat()
      return
    if k.mods == {} and k.ch == ord('@') :
      # attach context: @file @selection … and the MCP servers' resources first, then the project's files
      var items: seq[(string, string, Action)]
      const MentionHelp = ["the current file", "the selection", "uncommitted changes (git diff)", "staged changes",
                           "errors and warnings", "the terminal's last output", "the project's file list"]
      for i, m in AiMentions: items.add act(m, MentionHelp[min(i, MentionHelp.high)], mentionInsertAct(m))
      items.add act("▣ a picture…", "a screenshot or a photo, for a model that reads pictures", proc() =
        aiAttachPicture())
      for srv in mcpServers:
        if srv.dead: continue
        for r in srv.resources:
          items.add act("@" & srv.name & ":" & r.uri, (if r.name.len > 0: r.name & " · " else: "") & srv.name & " MCP server",
                        mentionInsertAct("@" & srv.name & ":" & r.uri))
      for p in projectFiles():
        let pp = p
        capture pp:
          items.add act(pp, "", proc() =
            let t = "@" & pp & " "
            aiInput.insert(t, aiInputCur)
            aiInputCur += t.len
            showSide(svAssistant))
        if items.len >= 3000: break
      openActions("Attach a file to the message", items)
      return
    discard editLine(aiInput, aiInputCur, k)
  of kPaste:
    # a picture's path (a terminal pastes a dropped file's path, quoted or as file://): it goes with the message
    var t = k.text.strip.strip(chars = {'\'', '"'})
    if t.startsWith("file://"): t = pathFromUri(t)
    if '\n' notin t and isPicturePath(t) and fileExists(expandTilde(t)):
      let m = "@" & (let a = absolutePath(expandTilde(t)); if a.startsWith(rootDir & "/"): relPath(a) else: a) & " "
      aiInput.insert(m, aiInputCur)
      aiInputCur += m.len
      let why = aiPicWhy(absolutePath(expandTilde(t)))
      info(if why.len > 0: extractFilename(t) & ": " & why else: "The picture goes with the message")
      return
    aiInput.insert(k.text, aiInputCur)
    aiInputCur += k.text.len
  else: discard editLine(aiInput, aiInputCur, k)
