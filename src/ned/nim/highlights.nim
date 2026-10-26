# ── the uses in this file of what the name at the cursor names (as clangd's document highlights), resolved by ned's
#    engine: a local of another proc, a field of another object, a parameter that shares the name are left out. The
#    editor marks them as it marks a language server's (editor.highlightOccurrences) ──

proc nimEngHighlights(b: Buffer, p: Pos, first = 0, last = int.high): seq[(Pos, Pos)] =
  ## (first .. last: the lines to look in — the editor asks for those on screen, and a little around them)
  if not nimEngineOn(b) or b.largeOn or p.line >= b.lines.len or b.lines.len > 50_000: return
  let s0 = b.lines[p.line]
  var a = min(p.col, s0.len)
  var e = a
  while a > 0 and (s0[a - 1] in IdentChars or s0[a - 1].ord >= 0x80): dec a
  while e < s0.len and (s0[e] in IdentChars or s0[e].ord >= 0x80): inc e
  if a >= e: return
  let w = s0[a ..< e]
  if w[0] in Digits or w in NxKeywords: return
  let tk = b.tokenAt(Pos(line: p.line, col: a))
  if tk in {tkComment, tkString, tkDoc, tkNumber}: return
  try:
    let f = nxFileFor(b)
    if f == nil: return
    let nw = nxNorm(w)
    var targets: seq[NxRef]
    var locals: seq[NxSym]
    var modPath = ""
    let at = nxSymAt(f, p.line, a)
    if at >= 0: targets = @[NxRef(file: f, idx: int32(at))]
    else: (targets, locals, modPath) = nxTargets(f, b.lines, p.line, a)
    var la = 0
    var le = b.lines.high
    if locals.len > 0:
      let ri = nxEnclosing(f, locals[0].line)
      if ri >= 0: (la, le) = (f.syms[ri].line, min(f.syms[ri].endLine, b.lines.high))
    la = max(la, first)
    le = min(le, last)
    let byName = modPath.len > 0 or (targets.len == 0 and locals.len == 0)
    let t0 = getMonoTime()
    var st: NxLexState
    # (the lexer's state from a little before: a string or a comment over several lines is seen as one)
    for l in max(0, la - 60) .. le:
      let s = b.lines[l]
      let ids = nxIdents(s, st)                       # (the lexer state follows every line)
      if l < la: continue
      for (c, ce) in ids:
        if nxNorm(s[c ..< ce]) != nw: continue
        var ok = false
        # (it runs as the cursor moves: after 4 ms the rest is matched by name alone)
        if byName or msSince(t0) > 4: ok = s[c ..< ce] == w or not byName
        elif locals.len > 0:
          if l == locals[0].line and c == locals[0].col: ok = true
          else:
            let (_, ls, _) = nxTargets(f, b.lines, l, c)
            ok = ls.len > 0 and ls[0].line == locals[0].line and ls[0].name == locals[0].name
        else:
          let k = nxSymAt(f, l, c)
          if k >= 0:
            let r = NxRef(file: f, idx: int32(k))
            for t in targets:
              if nxSameDecl(t, r): ok = true
          else:
            let (rs, ls, mp) = nxTargets(f, b.lines, l, c)
            if ls.len == 0 and mp.len == 0:
              for r in rs:
                for t in targets:
                  if nxSameDecl(t, r): ok = true
        if ok: result.add (Pos(line: l, col: c), Pos(line: l, col: ce))
  except CatchableError: result.setLen(0)
