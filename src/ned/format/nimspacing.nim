# ── spacing ──

proc fDeclSite(toks: openArray[FTok], k: int): bool =
  ## is the name before toks[k] being declared (first on the line, after a comma, after proc/var/type …)?
  let before = if k >= 2: toks[k - 2] else: FTok(kind: fkComma)
  k == 1 or before.kind in {fkComma, fkColon, fkSemi, fkPragClose} or
    (before.kind == fkKw and (before.text in FRoutineKw or before.text in FSectionKw or before.text == "case"))

proc fExportMark*(toks: openArray[FTok], k: int): bool =
  ## is toks[k] the `*` that exports the name before it?
  if k < 1 or toks[k].kind != fkOp or toks[k].text != "*" or toks[k].sp or toks[k - 1].kind != fkIdent: return false
  if not fDeclSite(toks, k): return false
  if k + 1 >= toks.len: return false          # (a line broken after it: a product — `delta *` ⏎ `x`)
  let nx = toks[k + 1]
  nx.kind in {fkOpen, fkColon, fkComma, fkPragOpen, fkComment} or (nx.kind == fkOp and nx.text == "=")

proc fRender*(toks: openArray[FTok], params = false, importish = false): string =
  ## one line of tokens with nph's spacing
  let importLine = importish or
    (toks.len > 0 and toks[0].kind == fkKw and toks[0].text in ["import", "include", "from", "export"])
  for k, t0 in toks:
    if k == 0:
      result.add t0.text
      continue
    # a token that started a line had whitespace (the line break) in front of it
    let t = t0
    let tsp = t.sp or t.nl
    let p = toks[k - 1]
    let psp = p.sp or (p.nl and k - 1 > 0)
    let nx = if k + 1 < toks.len: toks[k + 1] else: FTok(kind: fkComment, text: "")
    let nsp = nx.sp or nx.nl
    var space = false
    if importLine and (t.kind in {fkOp, fkDot} or p.kind in {fkOp, fkDot}):
      space = p.kind in {fkKw, fkComma}                   # module paths: std/[a, b], ./x, ../y, "$nim"/z
    elif fExportMark(toks, k): space = false
    elif k >= 1 and fExportMark(toks, k - 1): space = t.kind notin {fkOpen, fkColon, fkComma}
    elif t.kind == fkComment: space = true
    elif p.kind in {fkOpen, fkPragOpen}: space = false
    elif t.kind in {fkClose, fkPragClose, fkComma, fkSemi, fkColon}: space = false
    elif p.kind == fkColon and k >= 2 and toks[k - 2].kind == fkOpen and toks[k - 2].text == "[":
      space = false                                  # fromBin[:int16] — explicit generic arguments
    elif p.kind in {fkComma, fkSemi, fkColon}: space = true
    elif t.kind == fkDot or p.kind == fkDot: space = false
    elif t.kind == fkPragOpen: space = true
    elif t.kind == fkOpen:
      if p.kind == fkKw and p.text notin ["addr", "cast", "static", "tuple", "proc", "func", "iterator", "ptr", "ref",
                                           "distinct", "enum", "object", "concept", "type", "var", "out", "nil"]:
        space = true                                 # not (a), if (a)
      elif p.kind == fkOp:
        space = psp or not (k >= 2 and fOperand(toks[k - 2]))      # a + (b)  ·  -(b)  ·  @[
        if psp and not tsp and k >= 2 and toks[k - 2].kind notin {fkOp, fkOpen, fkComma}:
          space = false                             # o.add $(y + 1): a unary operator in a command
        if p.text in ["@", "$", "-", "+", "!", "~", "&", "^", "*"] and not (k >= 2 and fOperand(toks[k - 2]) and psp):
          space = false
        if k >= 2 and fOperand(toks[k - 2]) and not (psp and not tsp): space = true
        if p.kind == fkOp and p.text == "=" : space = true
      elif p.kind == fkKw and p.text in ["proc", "func", "iterator"]: space = false   # proc(x: int) — a type
      else: space = tsp                             # foo(a) is a call, foo (a) a command
    elif t.kind == fkOp:
      # binary after an operand — or after a keyword when spaced on both sides (object | tuple)
      let binary = (fOperand(p) or (p.kind == fkKw and not fWordOp(p) and tsp == nsp)) and
                   not (tsp and not nsp and nx.kind != fkComment and t.text != "=")
      if t.text == "*" and p.kind == fkIdent and not tsp and fDeclSite(toks, k) and
         (nx.kind in {fkColon, fkComma, fkPragOpen} or (nx.kind == fkComment and nx.text.len > 0) or
          (nx.kind == fkOpen and nx.text != "{")):
        space = false                                # name* export marker
      elif t.text == "*" and p.kind == fkIdent and (nx.kind == fkOp and nx.text == "=") and not tsp and
           fDeclSite(toks, k):
        space = false
      elif binary or t.text == "=": space = true
      else: space = p.kind notin {fkOpen, fkPragOpen} and (p.kind in {fkComma, fkSemi, fkColon} or tsp or
                                                          p.kind == fkKw or p.kind == fkOp)
    elif p.kind == fkOp:
      # after an operator: binary ones are spaced, unary ones stick to their operand
      let pp = if k >= 2: toks[k - 2] else: FTok(kind: fkComma)
      let wasBinary = (fOperand(pp) or (pp.kind == fkKw and not fWordOp(pp) and psp == tsp)) and
                      not (psp and not tsp)
      if p.text == "*" and pp.kind == fkIdent and not psp and fDeclSite(toks, k - 1) and
         (t.kind in {fkColon, fkComma, fkPragOpen} or (t.kind == fkOpen and t.text != "{")):
        space = false
      elif wasBinary or p.text == "=": space = true
      else: space = false
    else: space = true                               # words next to words
    if space: result.add ' '
    result.add t.text
