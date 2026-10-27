# ── macros you can see (6.32): what a macro or template call writes, folded under the call — rows that are not
#    text (Buffer.vrows), coloured as Nim. A name in them hovers with its doc and goes to its definition, as it would
#    in the code; a problem the compiler reports on the call marks the generated line it is about. Alt+M on a call
#    shows it, again hides it; it follows the call when the file changes, written again after a pause ──

type MacroView = object
  line: int                  # the call's line
  col: int                   # where its name is (for the engine)
  name: string               # the macro or the template
  callText: string           # the call's line as it was when expanded: to find the call again after edits
  code: seq[string]          # what it writes
  err: string                # why it could not be written out
  busy: bool                 # (a macro: the compiler is at it)
  isMacro: bool
  due: bool                  # its call changed: written again after a pause
  links: seq[seq[VLink]]     # each code line's names that lead somewhere (looked up once, when it is written out)

var
  macroViews: Table[int, seq[MacroView]]   # buffer id → its views
  mvRowLines: Table[int, seq[int]]         # buffer id → the lines whose rows are the views' (not a notebook's)
  mvSeen: Table[int, int]                  # buffer id → its changeId the last time the views were checked

const MvMaxRows = 300

proc mvQuoted(msg: string): seq[string] =
  ## the names a compiler message quotes: 'x', `x`, "x"
  var i = 0
  while i < msg.len:
    if msg[i] in {'\'', '`'}:
      let q = msg[i]
      let e = msg.find(q, i + 1)
      if e > i + 1 and e - i < 60:
        let w = msg[i + 1 ..< e].strip
        if w.len > 0 and w[0] in IdentStartChars: result.add w.split({'.', '('})[0]
        i = e + 1
        continue
    inc i

proc mvLinks(b: Buffer, code: seq[string]): seq[seq[VLink]] =
  ## the names in what a macro writes, looked up where its call is, as the code there sees them: their doc and
  ## where they are declared (a name the macro itself declares leads nowhere)
  result = newSeq[seq[VLink]](min(code.len, MvMaxRows))
  if b.path.len == 0 or not nimEngineOn(b): return
  try:
    let f = nxFileFor(b)
    if f == nil: return
    let sc = nxScope(f)
    var seen: Table[string, (string, string, int, int)]
    for k in 0 ..< result.len:
      let s = code[k]
      var i = 0
      while i < s.len:
        if s[i] in IdentStartChars and (i == 0 or s[i - 1] notin IdentChars):
          var e = i
          while e < s.len and s[e] in IdentChars: inc e
          let w = s[i ..< e]
          if w notin seen:
            var hit = ("", "", 0, 0)
            let refs = nxLookup(sc, w)
            if refs.len > 0:
              let r = refs[0]
              var tip = w
              try:
                let d = nxDoc(r).splitLines()
                if d.len > 0 and d[0].len > 0: tip = d[0]
              except CatchableError: discard
              hit = (r.file.path, tip, r.sym.line, r.sym.col)
            seen[w] = hit
          let h = seen[w]
          if h[0].len > 0:
            result[k].add (a: i, e: e, path: h[0], tip: h[1], line: h[2], col: h[3])
          i = e
        else: inc i
  except CatchableError: discard

proc mvRows(b: Buffer, v: MacroView): seq[VRow] =
  ## the rows of one view: a header, the code coloured, its problem marked
  let bg = blend(theme.bg, theme.accent, 0.06)
  let gut = blend(theme.accent, bg, 0.35)
  let lead = b.lines[v.line].len - b.lines[v.line].strip(trailing = false).len
  let pad = spaces(lead)
  var head = VRow(bg: bg, tag: 1)
  head.spans.add (pad & "⤷ ", theme.accent, {aBold})
  head.spans.add ((if v.isMacro: "the macro " else: "the template ") & v.name & " writes", theme.dim, {aItalic})
  if v.busy: head.spans.add ("  — the compiler is expanding it…", theme.dim, {aItalic})
  elif v.err.len > 0: head.spans.add ("  — " & v.err, theme.err, {aItalic})
  else: head.spans.add ("  · Alt+M hides it · a name: hover, click goes to it", blend(theme.dim, bg, 0.3), {aItalic})
  result.add head
  # the problems of the call: on the generated line that has the name they quote
  var probs: seq[(string, int, string)]        # (name, severity, message)
  var unplaced: seq[(int, string)]
  for d in diagsFor(b.path):
    if d.line != v.line or d.sev > 2: continue
    let qs = mvQuoted(d.msg)
    var placed = false
    for q in qs:
      for cl in v.code:
        if q in cl:
          probs.add (q, d.sev, d.msg)
          placed = true
          break
      if placed: break
    if not placed: unplaced.add (d.sev, d.msg)
  var toks: seq[TokKind]
  var st: LexSt
  let nimLang = langByName("Nim")
  for k, cl in v.code:
    if k >= MvMaxRows:
      result.add VRow(bg: bg, tag: 3, spans: @[(pad & "│ … " & $(v.code.len - MvMaxRows) & " more lines — " &
                                                 "Nim: expand macro/template in a tab", theme.dim, {aItalic})])
      break
    var row = VRow(bg: bg, tag: 2, text: cl, textX: lead + 2, links: (if k < v.links.len: v.links[k] else: @[]))
    var mark = ""
    var sev = 0
    for (q, s, m) in probs:
      var at = cl.find(q)
      if at >= 0 and (at == 0 or cl[at - 1] notin IdentChars) and
         (at + q.len >= cl.len or cl[at + q.len] notin IdentChars):
        mark = m
        sev = s
        break
    if sev > 0: row.bg = blend(bg, sevColor(sev), 0.16)
    row.spans.add (pad & "│ ", gut, {})
    st = lexLine(nimLang, cl, st, toks)
    var i = 0
    while i < cl.len:
      let tk = if i < toks.len: toks[i] else: tkText
      var e = i + 1
      while e < cl.len and e < toks.len and toks[e] == tk: inc e
      let fg = theme.syn[tk]
      row.spans.add (cl[i ..< e], fg, (if tk in {tkComment, tkDoc}: {aItalic} else: {}))
      i = e
    if mark.len > 0: row.spans.add ("  ● " & mark, sevColor(sev), {aItalic})
    result.add row
  for (s, m) in unplaced:
    result.add VRow(bg: bg, tag: 3, spans: @[(pad & "│ ● " & m, sevColor(s), {aItalic})])

proc mvSync(b: Buffer) =
  ## the views drawn: the rows under their calls (a notebook cell's output under the same line left alone)
  for l in mvRowLines.getOrDefault(b.id):
    if l notin b.vrows: continue
    var keep: seq[VRow]
    for r in b.vrows[l]:
      if r.tag == 0: keep.add r
    if keep.len > 0: b.vrows[l] = keep else: b.vrows.del l
  var ls: seq[int]
  for v in macroViews.getOrDefault(b.id):
    if v.line < 0 or v.line >= b.lines.len: continue
    b.vrows.mgetOrPut(v.line, @[]).add mvRows(b, v)
    ls.add v.line
  if ls.len > 0: mvRowLines[b.id] = ls else: mvRowLines.del b.id
  needRender = true

proc mvExpand(b: Buffer, k: int) =
  ## view k written out: a template by ned's engine at once, a macro by the compiler (nim check --expandMacro)
  var v = macroViews[b.id][k]
  v.err = ""
  v.callText = b.lines[v.line]
  v.due = false
  var text = ""
  if not v.isMacro and nimEngineOn(b):
    try:
      let f = nxFileFor(b)
      if f != nil: text = nxExpandTemplate(f, b.lines, v.line, v.col)[1]
    except CatchableError: discard
    if text.len > 0:
      v.code = text.splitLines
      while v.code.len > 0 and v.code[^1].strip.len == 0: v.code.setLen(v.code.len - 1)
      v.links = mvLinks(b, v.code)
      macroViews[b.id][k] = v
      mvSync(b)
      return
  if not haveExe("nim"):
    v.err = "a macro is expanded by the compiler — nim is not on PATH"
    macroViews[b.id][k] = v
    mvSync(b)
    return
  v.isMacro = true
  v.busy = true
  macroViews[b.id][k] = v
  mvSync(b)
  let bid = b.id
  let name = v.name
  let line = v.line
  expandMacroJob(b, name, line, proc(at: int, code, err: string) =
    let bb = bufById(bid)
    if bb == nil or bid notin macroViews: return
    for x in macroViews[bid].mitems:
      if x.name == name and x.line == line:
        x.busy = false
        x.err = err
        if err.len == 0:
          x.code = code.splitLines
          while x.code.len > 0 and x.code[^1].strip.len == 0: x.code.setLen(x.code.len - 1)
          x.links = mvLinks(bb, x.code)
    mvSync(bb))

proc cmdMacroView() =
  ## Alt+M: what the macro or template at the cursor writes, under its call — again: hidden
  let b = buf()
  if b.lang.mode != lmNim:
    info("Macro expansion is for Nim files")
    return
  let p = b.primary.head
  var views = macroViews.getOrDefault(b.id)
  for k, v in views:
    if v.line == p.line:
      views.delete(k)
      if views.len > 0: macroViews[b.id] = views else: macroViews.del b.id
      mvSync(b)
      info("Expansion hidden")
      return
  let (a, e) = b.wordRangeAt(p)
  let w = if a.line == e.line and e.col > a.col: b.lines[a.line][a.col ..< e.col] else: ""
  if w.len == 0:
    info("Put the cursor on a macro or template call")
    return
  var isMacro = false
  var isTpl = false
  if nimEngineOn(b):
    try:
      let f = nxFileFor(b)
      if f != nil:
        for r in nxLookup(nxScope(f), w):
          if r.sym.kind == nxMacro: isMacro = true
          if r.sym.kind == nxTemplate: isTpl = true
    except CatchableError: discard
  if not isMacro and not isTpl and not haveExe("nim"):
    info(w & " is not a macro or template ned knows — and nim is not on PATH to ask the compiler")
    return
  views.add MacroView(line: p.line, col: a.col, name: w, isMacro: isMacro and not isTpl)
  macroViews[b.id] = views
  mvSeen[b.id] = b.changeId
  mvExpand(b, views.high)

proc mvHideAll() =
  let b = buf()
  if b.id notin macroViews:
    info("No expansion shown")
    return
  macroViews.del b.id
  mvSync(b)

proc mvPump() =
  ## (the main loop) a view follows its call when lines come and go above it, and is written again a moment after
  ## the call itself changed; a call that is gone takes its view with it
  if macroViews.len == 0: return
  var ids: seq[int]
  for id in macroViews.keys: ids.add id
  for id in ids:
    let b = bufById(id)
    if b == nil:
      macroViews.del id
      mvRowLines.del id
      continue
    if mvSeen.getOrDefault(id, -1) != b.changeId:
      mvSeen[id] = b.changeId
      var keep: seq[MacroView]
      for v0 in macroViews[id]:
        var v = v0
        if v.line < b.lines.len and b.lines[v.line] == v.callText:
          keep.add v
          continue
        var found = -1
        for d in 0 .. 60:
          for c in [v.line - d, v.line + d]:
            if found < 0 and c >= 0 and c < b.lines.len and b.lines[c] == v.callText: found = c
          if found >= 0: break
        if found >= 0:
          v.line = found
          keep.add v
        elif v.line < b.lines.len and v.name in b.lines[v.line]:
          v.due = true                               # (its arguments changed: written again after a pause)
          v.col = max(0, b.lines[v.line].find(v.name))
          keep.add v
      if keep.len > 0: macroViews[id] = keep else: macroViews.del id
      mvSync(b)
    if id in macroViews and msSince(lastInputAt) > (if b == buf(): 700 else: 0):
      for k in 0 ..< macroViews[id].len:
        if macroViews[id][k].due and not macroViews[id][k].busy: mvExpand(b, k)

proc mvGoto(path: string, line, col: int): Action =
  (proc() =
    pushJump()
    let ob = openFile(path)
    if ob != nil: ob.centerOn(ob.clampPos(Pos(line: line, col: col))))

proc mvHideAt(bid, line: int): Action =
  (proc() =
    if bid notin macroViews: return
    var views = macroViews[bid]
    for k, v in views:
      if v.line == line:
        views.delete(k)
        break
    if views.len > 0: macroViews[bid] = views else: macroViews.del bid
    let b = bufById(bid)
    if b != nil: mvSync(b))

proc mvRowRegions(b: Buffer, line: int, row: VRow, x0, y, limX: int) =
  ## (drawing) the header hides the expansion when tapped; a name in a generated line hovers with its doc and goes
  ## to its definition
  if row.tag == 1:
    region(x0, y, max(1, limX - x0), 1, mvHideAt(b.id, line), "Hide what the macro writes (Alt+M)")
    return
  for l in row.links:
    let x = x0 + row.textX + visColOf(row.text, l.a)
    if x >= limX: break
    region(x, y, min(visColOf(row.text, l.e) - visColOf(row.text, l.a), limX - x), 1,
           mvGoto(l.path, l.line, l.col), l.tip)
