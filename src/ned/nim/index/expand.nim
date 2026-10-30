# ── a template call written out: its body with the arguments in place (no compiler needed) ──

proc nxFileLines*(path: string): seq[string] =
  ## a file's lines: the editor's open buffer when it holds the file (so unsaved changes count), else the file on disk,
  ## empty when it cannot be read
  if nxBufferLines != nil and nxBufferStamp(path).len > 0: return nxBufferLines(path)
  try: result = readFile(path).splitLines
  except CatchableError: discard

proc nxTemplateBody*(lines: seq[string], s: NxSym): seq[string] =
  ## a template's body, dedented: the lines below its header, or what follows `=` on a one-line one
  if s.line < 0 or s.line >= lines.len: return
  var h = s.line
  var hdr = lines[h]
  # (a header over several lines ends with `=`)
  while h < min(s.endLine, lines.high) and not hdr.strip.endsWith("="):
    inc h
    hdr.add " " & lines[h].strip
  let po = hdr.find('(')
  let pc = if po >= 0: nxMatchClose(hdr, po) else: -1
  let eq = nxFindTop(hdr, '=', (if pc > 0: pc + 1 else: 0))
  if eq >= 0 and eq + 1 < hdr.len and hdr[eq + 1 .. ^1].strip.len > 0:
    return @[hdr[eq + 1 .. ^1].strip]               # template sq(x: int): int = x * x
  var ind = high(int)
  for l in h + 1 .. min(s.endLine, lines.high):
    if lines[l].strip.len > 0: ind = min(ind, leadWs(lines[l]))
  if ind == high(int): return
  var lead = true
  for l in h + 1 .. min(s.endLine, lines.high):
    if lead and lines[l].strip.startsWith("##"): continue      # (its doc comment is not part of what it makes)
    lead = false
    result.add (if lines[l].len >= ind: lines[l][ind .. ^1] else: lines[l].strip)
  while result.len > 0 and result[^1].strip.len == 0: result.setLen(result.len - 1)

proc nxExpandTemplate*(f: NxFile, lines: seq[string], line, col: int): (string, string) =
  ## (the call, its expansion) for the template called at line:col; ("", "") when that is no template call
  if line < 0 or line >= lines.len: return
  let text = lines[line]
  let (a, e) = nxWordAt(text, col)
  if a >= e: return
  let name = text[a ..< e]
  let sc = nxScope(f)
  var tpls: seq[NxRef]
  for r in nxLookup(sc, name):
    if r.sym.kind == nxTemplate: tpls.add r
  if tpls.len == 0: return
  var args: seq[string]
  var call = name
  if nxDotBefore(text, a):
    let recv = nxReceiver(text, a - 1)
    if recv.len > 0:
      args.add recv                                  # x.name(…): x is the first argument
      call = recv & "." & name
  let k = e
  var blockArg = false
  if k < text.len and text[k] == '(':
    var joined = text[k .. ^1]
    var l2 = line
    while nxMatchClose(joined, 0) < 0 and l2 + 1 < lines.len and l2 - line < 30:
      inc l2
      joined.add " " & lines[l2].strip
    let ce = nxMatchClose(joined, 0)
    if ce < 0: return
    for p in nxSplitTop(joined[1 ..< ce], {','}):
      if p.strip.len > 0: args.add p.strip
    call.add joined[0 .. ce]
    blockArg = joined[ce + 1 .. ^1].strip == ":"
  elif k < text.len and text[k] == ' ':
    # command syntax: name a, b   /   name a:
    var rest = text[k .. ^1].strip
    let hk = rest.find(" #")
    if hk >= 0: rest = rest[0 ..< hk].strip
    if rest.endsWith(":"):
      blockArg = true
      rest = rest[0 ..< ^1].strip
    if rest.len > 0 and rest[0] in {'=', '+', '-', '*', '/', '<', '>', '&', '.'}: return     # (an operator, not arguments)
    for p in nxSplitTop(rest, {','}):
      if p.strip.len > 0: args.add p.strip
    if rest.len > 0: call.add " " & rest
  elif k < text.len and text[k] == ':':
    blockArg = true
  if blockArg:
    # the indented block below is the last argument
    let ind = leadWs(text)
    var blk: seq[string]
    var bi = high(int)
    var l2 = line + 1
    while l2 < lines.len and (lines[l2].strip.len == 0 or leadWs(lines[l2]) > ind):
      if lines[l2].strip.len > 0: bi = min(bi, leadWs(lines[l2]))
      blk.add lines[l2]
      inc l2
    while blk.len > 0 and blk[^1].strip.len == 0: blk.setLen(blk.len - 1)
    var body: seq[string]
    for x in blk: body.add (if x.len >= bi: x[bi .. ^1] else: x.strip)
    args.add body.join("\n")
    call.add ":"
  # the overload these arguments fit
  var best = -1
  for i, r in tpls:
    let ps = r.sym.params
    var need = 0
    for p in ps:
      if p.default.len == 0: inc need
    if args.len >= need and args.len <= ps.len:
      best = i
      break
  if best < 0: return
  let s = tpls[best].sym
  var sub: Table[string, string]
  var given: HashSet[int]
  var pos = 0
  for x in args:
    let eqk = nxFindTop(x, '=')
    if eqk > 0 and x[0 ..< eqk].strip.validIdentifier and (eqk + 1 >= x.len or x[eqk + 1] != '='):
      let nm = x[0 ..< eqk].strip
      for i, p in s.params:
        if nxNorm(p.name.strip(chars = {'`'})) == nxNorm(nm):
          sub[p.name.strip(chars = {'`'})] = x[eqk + 1 .. ^1].strip
          given.incl i
      continue
    while pos < s.params.len and pos in given: inc pos
    if pos < s.params.len:
      sub[s.params[pos].name.strip(chars = {'`'})] = x
      given.incl pos
      inc pos
  for i, p in s.params:
    if i notin given and p.default.len > 0: sub[p.name.strip(chars = {'`'})] = p.default
  let tlines = nxFileLines(tpls[best].file.path)
  var outL: seq[string]
  for bl in nxTemplateBody(tlines, s):
    let t = bl.strip
    if t in sub and '\n' in sub[t]:
      # a block argument on a line of its own: its lines, at that line's indentation
      let pre = bl[0 ..< leadWs(bl)]
      for x in sub[t].splitLines: outL.add pre & x
    elif t in sub:
      outL.add bl[0 ..< leadWs(bl)] & sub[t]          # (an argument that is a statement of its own)
    else:
      # (the compiler substitutes trees, not text: `3 + 1` in `x * x` stays together — written with brackets)
      var single: Table[string, string]
      for kk, vv in sub:
        let v1 = if '\n' in vv: vv.splitLines.join("; ") else: vv
        single[kk] = if ' ' in nxFlat(v1.strip) and not v1.strip.startsWith("("): "(" & v1.strip & ")" else: v1
      outL.add nxSubstIdents(bl, single)
  if outL.len == 0: return
  (call, outL.join("\n"))
