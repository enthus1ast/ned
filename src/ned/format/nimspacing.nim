# ── the Nim formatter's spacing: where a space goes between two tokens, and a line made from its tokens ──

proc fDeclSite(toks: openArray[FTok], k: int): bool =
  ## is the name before toks[k] being declared (first on the line, after a comma, after proc/var/type …)?
  if k < 2: return true
  var b = k - 2
  while b > 0 and toks[b].kind == fkComment: dec b      # (`proc #[x]# f*()`)
  let before {.cursor.} = toks[b]
  before.kind in {fkComma, fkColon, fkSemi, fkPragClose} or
    (before.kind == fkKw and (before.text in FRoutineKw or before.text in FSectionKw or before.text == "case"))

proc fExportMark*(toks: openArray[FTok], k: int): bool =
  ## is toks[k] the `*` that exports the name before it?
  if k < 1 or toks[k].kind != fkOp or toks[k].text != "*" or toks[k].sp or toks[k - 1].kind != fkIdent: return false
  if not fDeclSite(toks, k): return false
  if k + 1 >= toks.len: return false          # (a line broken after it: a product — `delta *` ⏎ `x`)
  let nx {.cursor.} = toks[k + 1]
  (nx.kind in {fkOpen, fkColon, fkComma, fkPragOpen, fkComment} and not (nx.kind == fkOpen and nx.text == "{")) or
    (nx.kind == fkOp and nx.text == "=")                          # (flags*{a, b}: a product with a set)

proc fSpaceBefore*(toks: openArray[FTok], k: int, importLine: bool): bool {.inline.} =
  ## nph's spacing: is there a space between toks[k - 1] and toks[k] (k >= 1)?
  # a token that started a line had whitespace (the line break) in front of it
  let t {.cursor.} = toks[k]
  let tsp = t.sp or t.nl
  let p {.cursor.} = toks[k - 1]
  let psp = p.sp or (p.nl and k - 1 > 0)
  # (the token after t — at the end of the line, as if an empty comment followed — and the one before p — at its
  # start, as if a comma came before; no token made for them)
  let hasNx = k + 1 < toks.len
  let nxKind = if hasNx: toks[k + 1].kind else: fkComment
  let nsp = hasNx and (toks[k + 1].sp or toks[k + 1].nl)
  let hasPp = k >= 2
  var space = false
  if importLine and (t.kind in {fkOp, fkDot} or p.kind in {fkOp, fkDot}):
    space = p.kind in {fkKw, fkComma}                   # module paths: std/[a, b], ./x, ../y, "$nim"/z
  elif fExportMark(toks, k): space = false
  elif t.kind == fkOp and t.text == "*" and k >= 2 and toks[k - 2].kind == fkKw and toks[k - 2].text in FRoutineKw and
       p.kind == fkIdent:
    space = false                                  # proc `$` *(x: T) → proc `$`*(x: T): after a routine's name, `*`
                                                   # exports it
  elif k >= 1 and fExportMark(toks, k - 1): space = t.kind notin {fkOpen, fkColon, fkComma}
  elif t.kind == fkComment: space = true
  elif p.kind == fkComment and p.text.startsWith("#["): space = tsp       # (after `#[ … ]#`: as written — first
                                                                           # on a line, a space there is indentation)
  elif p.kind in {fkOpen, fkPragOpen}: space = false
  elif t.kind in {fkClose, fkPragClose, fkComma, fkSemi, fkColon}: space = false
  elif p.kind == fkColon and k >= 2 and toks[k - 2].kind == fkOpen and toks[k - 2].text == "[":
    space = false                                  # fromBin[:int16] — explicit generic arguments
  elif p.kind == fkColon and toks[0].kind == fkOp and toks[0].text in ["--", "-"] and
       toks.len > 1 and toks[1].kind == fkIdent:
    space = tsp                                    # NimScript switches: --path:"../src", --d:release (as written)
  elif p.kind in {fkComma, fkSemi, fkColon}: space = true
  elif t.kind == fkDot or p.kind == fkDot: space = false
  elif t.kind == fkPragOpen: space = true
  elif t.kind == fkOpen and t.text == "[" and p.kind == fkKw and p.text in ["tuple", "ptr", "ref"] and
       not (k >= 2 and toks[k - 2].kind == fkDot):
    space = p.text != "tuple"                      # tuple[x, y: int] · ptr [T], ref [T] (like nph)
  elif t.kind == fkOpen:
    if p.kind == fkKw and p.text notin ["addr", "cast", "static", "tuple", "proc", "func", "iterator", "ptr", "ref",
                                         "distinct", "enum", "object", "concept", "type", "var", "out", "nil", "do"] and
       not (k >= 2 and toks[k - 2].kind == fkDot):  # (`posix.raise(x)`: a call — the keyword is a name there)
      space = true                                 # not (a), if (a)
    elif p.kind == fkOp:
      space = psp or not (k >= 2 and fOperand(toks[k - 2]))      # a + (b)  ·  -(b)  ·  @[
      if psp and not tsp and k >= 2 and toks[k - 2].kind notin {fkOp, fkOpen, fkComma}:
        space = false                             # o.add $(y + 1): a unary operator in a command
      if p.text in ["@", "$", "-", "+", "!", "~", "&", "^", "*"] and not (k >= 2 and fOperand(toks[k - 2]) and psp):
        space = false
      if k >= 2 and fOperand(toks[k - 2]) and not (psp and not tsp): space = true
      let opBinary = hasPp and (fOperand(toks[k - 2]) or (toks[k - 2].kind == fkKw and not fWordOp(toks[k - 2]) and
                                                           psp == tsp)) and not (psp and not tsp)
      if not opBinary: space = false      # %(x), %*{…}, ?(a, b): a prefix operator (not distinct|(…): a typeclass)
      if p.kind == fkOp and p.text == "=" : space = true
    elif p.kind == fkKw and p.text in ["proc", "func", "do"]: space = false   # proc(x: int), do(x):
    elif p.kind == fkKw and p.text == "iterator": space = t.text == "("     # iterator (x: int): T (like nph)
    elif t.text == "(" and toks[0].kind == fkKw and toks[0].text in FRoutineKw and
         (k == 2 or k == 3 and toks[2].kind == fkOp and toks[2].text == "*"):
      space = false                               # proc `&` (a, b) → proc `&`(a, b): the parameters
    else: space = tsp                             # foo(a) is a call, foo (a) a command
  elif t.kind == fkOp:
    # binary after an operand — or after a keyword when spaced on both sides (object | tuple)
    let binary = (fOperand(p) or (p.kind == fkKw and not fWordOp(p) and tsp == nsp)) and
                 not (tsp and not nsp and nxKind != fkComment and t.text != "=")
    if t.text == "*" and p.kind == fkIdent and not tsp and fDeclSite(toks, k) and
       (nxKind in {fkColon, fkComma, fkPragOpen} or (nxKind == fkComment and hasNx and toks[k + 1].text.len > 0) or
        (nxKind == fkOpen and toks[k + 1].text != "{")):
      space = false                                # name* export marker
    elif t.text == "*" and p.kind == fkIdent and (nxKind == fkOp and toks[k + 1].text == "=") and not tsp and
         fDeclSite(toks, k):
      space = false
    elif binary or t.text == "=": space = true
    else: space = p.kind notin {fkOpen, fkPragOpen} and (p.kind in {fkComma, fkSemi, fkColon} or tsp or
                                                        p.kind == fkKw or p.kind == fkOp)
  elif p.kind == fkOp:
    # after an operator: binary ones are spaced, unary ones stick to their operand
    let wasBinary = hasPp and (fOperand(toks[k - 2]) or (toks[k - 2].kind == fkKw and not fWordOp(toks[k - 2]) and
                                                          psp == tsp)) and
                    not (psp and not tsp)
    if p.text == "*" and hasPp and toks[k - 2].kind == fkIdent and not psp and fDeclSite(toks, k - 1) and
       (t.kind in {fkColon, fkComma, fkPragOpen} or (t.kind == fkOpen and t.text != "{")):
      space = false
    elif wasBinary or p.text == "=": space = true
    else: space = false
  else: space = true                               # words next to words
  return space

proc fRender*(toks: openArray[FTok], params = false, importish = false): string =
  ## one line of tokens with nph's spacing
  let importLine = importish or
    (toks.len > 0 and toks[0].kind == fkKw and toks[0].text in ["import", "include", "from", "export"])
  var n = 0
  for t in toks: n += t.text.len + 1
  result = newStringOfCap(n)
  for k in 0 ..< toks.len:
    if k > 0 and fSpaceBefore(toks, k, importLine): result.add ' '
    result.add toks[k].text

proc fRenderLen*(toks: openArray[FTok], importish = false): int =
  ## fRender(toks, importish = importish).len, without making the string
  let importLine = importish or
    (toks.len > 0 and toks[0].kind == fkKw and toks[0].text in ["import", "include", "from", "export"])
  for k in 0 ..< toks.len:
    if k > 0 and fSpaceBefore(toks, k, importLine): inc result
    result += toks[k].text.len
