# ── C knowledge in Nim: a wrapper's C documentation, header: / importc: strings, C signatures beside wrappers,
#    a wrapper rewritten from its C declaration, a new wrapper completed from a header ──

# ── header: "…" and importc: "…" ──

proc pragmaStringAt(b: Buffer, p: Pos): (string, string, int, int) =
  ## the pragma string the cursor is in: (key — header, importc, importcpp, dynlib —, its text, start, end column)
  result = ("", "", -1, -1)
  if b.lang == nil or b.lang.mode != lmNim or p.line >= b.lines.len: return
  let s = b.lines[p.line]
  if s.len > 4000 or '"' notin s: return
  var i = 0
  while i < s.len:
    if s[i] == '"':
      var j = i + 1
      while j < s.len and s[j] != '"':
        if s[j] == '\\': inc j
        inc j
      if p.col > i and p.col <= j:
        var k = i - 1
        while k >= 0 and s[k] == ' ': dec k
        if k < 0 or s[k] != ':': return
        dec k
        while k >= 0 and s[k] == ' ': dec k
        var a = k
        while a >= 0 and s[a] in IdentChars: dec a
        let key = s[a + 1 .. k]
        if key notin ["header", "importc", "importcpp", "dynlib"]: return
        if "{." notin s[0 ..< i] and not (p.line > 0 and "{." in b.lines[p.line - 1]) and
           not s.strip.startsWith(key): return
        return (key, s[i + 1 ..< min(j, s.len)], i + 1, j)
      i = j + 1
    else: inc i

proc cHeaderDescription(path: string): string =
  ## what a header says it is: its first comment that is not a licence (a couple of lines)
  let ls = cRawLines(path)
  var outp: seq[string]
  var i = 0
  while i < min(ls.len, 300) and outp.len < 3:
    let t = ls[i].strip
    var blk: seq[string]
    if t.startsWith("/*"):
      var e = i
      while e < ls.len and "*/" notin ls[e] and e - i < 200: inc e
      blk = ls[i .. min(e, ls.high)]
      i = e + 1
    elif t.startsWith("//"):
      var e = i
      while e + 1 < ls.len and ls[e + 1].strip.startsWith("//"): inc e
      blk = ls[i .. e]
      i = e + 1
    else:
      inc i
      continue
    # paragraphs: a licence one goes as a whole, else its boilerplate lines
    var para: seq[string]
    proc flush() =
      var hits = 0
      for l in para:
        for w in CBoilerplate:
          if w in l:
            inc hits
            break
      let all = para.join(" ")
      let licence = (hits * 2 > para.len and para.len > 1) or "free software" in all or "WITHOUT ANY WARRANTY" in all or
                    "Permission is hereby granted" in all or "under the terms of" in all
      if not licence:
        for l in para:
          var bad = false
          for w in CBoilerplate:
            if w in l: bad = true
          var letters = 0
          for ch in l:
            if ch in Letters: inc letters
          if not bad and letters >= 3 and outp.len < 3: outp.add l
      para.setLen(0)
    for l in cCommentClean(blk):
      if l.len == 0: flush()
      else: para.add l.replace("\t", " ").splitWhitespace.join(" ")
    flush()
  outp.join("\n")

proc pragmaStringHover(b: Buffer, p: Pos): string =
  ## the hover on header: "…" (the file, what it is, what it declares) and importc: "…" (the C declaration)
  let (key, val, _, _) = pragmaStringAt(b, p)
  if key.len == 0 or val.len == 0: return ""
  try:
    case key
    of "header":
      let dirs = cIncludeDirs(b.path, b.lines)
      let hp = cFindHeader(val, dirs, parentDir(b.path))
      if hp.len == 0:
        return "**" & val & "** — not found in the " & $dirs.len & " include folders ned knows (the C compiler's, " &
               "and -I in nim.extraFlags, config.nims or nim.cfg)"
      var fns, types, macros, vars = 0
      for _, d in cHeaderIndex(hp).decls:
        case d.kind
        of "function": inc fns
        of "type": inc types
        of "macro": inc macros
        of "variable": inc vars
        else: discard
      let desc = cHeaderDescription(hp)
      result = "**" & val & "** — " & hp & (if desc.len > 0: "\n\n" & desc else: "") & "\n\n" &
               $fns & " functions, " & $types & " types, " & $macros & " macros" &
               (if vars > 0: ", " & $vars & " variables" else: "") & " of its own · F12 opens it"
    of "importc", "importcpp":
      let decls = nimFfiDecls(b.lines)
      let i = ffiAtLine(decls, p.line)
      if i < 0: return ""
      let (cp, why) = ffiCDecl(decls[i], b.path, b.lines, false)
      if cp.kind.len == 0: return "**" & val & "** — " & why
      let doc = cProtoDoc(cp)
      result = "**" & val & "** — C " & cp.kind & ", " & extractFilename(cp.path) & ":" & $(cp.line + 1) &
               "\n```c\n" & (if cp.kind == "function": cPrettyProto(cp, decls[i].cname) else: cp.text) & "\n```" &
               (if doc.len > 0: "\n" & doc else: "") & "\n\nF12 opens the declaration"
    else: discard
  except CatchableError as e:
    internalError("C header", e)

proc pragmaStringGoto(b: Buffer, p: Pos): bool =
  ## F12 on header: "…" opens the header; on importc: "…" the C declaration
  let (key, val, _, _) = pragmaStringAt(b, p)
  if key notin ["header", "importc", "importcpp"] or val.len == 0: return false
  if key == "header":
    let hp = cFindHeader(val, cIncludeDirs(b.path, b.lines), parentDir(b.path))
    if hp.len == 0:
      info(val & " is not in the include folders ned knows")
      return true
    pushJump()
    discard openFile(hp)
    info(hp)
    return true
  let decls = nimFfiDecls(b.lines)
  let i = ffiAtLine(decls, p.line)
  if i < 0: return false
  let (cp, why) = ffiCDecl(decls[i], b.path, b.lines, true)
  if cp.kind.len == 0:
    info(why)
    return true
  pushJump()
  let nb = openFile(cp.path)
  if nb != nil:
    let at = nb.clampPos(Pos(line: cp.line, col: max(0, nb.lines[min(cp.line, nb.lines.high)].find(decls[i].cname))))
    nb.cursors = @[cur(at)]
    nb.centerOn(at)
    info("C: " & cp.text)
  true

proc cDocForNx(it: NxItem): string =
  ## completion docs of an importc proc: its C declaration and the comment above it
  if it.refs.len == 0: return ""
  let r = it.refs[0]
  if r.idx < 0 or r.idx >= r.file.syms.len: return ""
  let s = r.file.syms[r.idx]
  if "importc" notin s.pragmas and "header" notin s.pragmas: return ""
  try:
    let lines = cRawLines(r.file.path)
    let decls = nimFfiDecls(lines)
    let i = ffiAtLine(decls, s.line)
    if i < 0: return ""
    let (cp, _) = ffiCDecl(decls[i], r.file.path, lines, false)
    if cp.kind != "function": return ""
    let doc = cProtoDoc(cp)
    "\n\n**C** — " & extractFilename(cp.path) & "\n```c\n" & cPrettyProto(cp, decls[i].cname) & "\n```" &
      (if doc.len > 0: "\n" & doc else: "")
  except CatchableError: ""

# ── the C signature beside a wrapper (nim.cSignatureHints) ──

var cSigDecls: Table[int, (int, seq[NimFfi])]       # buffer id → (changeId, its importc declarations)

proc cSigHintsUpdate(b: Buffer) =
  ## the C declarations of the wrappers on screen, dimmed after them
  if b == nil or b.lang == nil or b.lang.mode != lmNim or b.path.len == 0 or b.largeOn or b.lines.len > 60000:
    return
  let lo = clamp(b.topLine - 20, 0, b.lines.high)
  let hi = min(b.lines.high, b.topLine + max(textH, 20) + 40)
  let at = cSigHintsAt.getOrDefault(b.id, (-2, -1, -1))
  if at[0] == b.changeId and lo >= at[1] and hi <= at[2]: return
  if at[0] != b.changeId and msSince(b.lspChangeAt) < 300: return     # (while typing: when it pauses)
  cSigHintsAt[b.id] = (b.changeId, lo, hi)
  var any = false
  for l in b.lines:
    if "importc" in l:
      any = true
      break
  var hs: Table[int, (int, string)]
  if any:
    try:
      var decls: seq[NimFfi]
      if cSigDecls.getOrDefault(b.id, (-1, @[]))[0] == b.changeId: decls = cSigDecls[b.id][1]
      else:
        decls = nimFfiDecls(b.lines)
        cSigDecls[b.id] = (b.changeId, decls)
      let dirs = cIncludeDirs(b.path, b.lines)
      let here = parentDir(b.path)
      let t0 = getMonoTime()
      for d in decls:
        if d.kind notin ["proc", "func"] or d.eline < lo or d.line > hi: continue
        if msSince(t0) > 80: break
        let (cp, _) = if d.header.len > 0: cDeclFor(d.header, d.cname, dirs, here)
                      else: ffiCDecl(d, b.path, b.lines, false)
        if cp.kind != "function": continue
        let el = min(d.eline, b.lines.high)
        var lb = cPrettyProto(cp, d.cname)
        if lb.len > 70: lb = lb[0 ..< 69] & "…"
        hs[el] = (b.lines[el].len, "  ⟵ " & lb)
    except CatchableError as e: internalError("C signature hints", e)
  cSigHints[b.id] = hs
  needRender = true

# ── a wrapper written from its C declaration ──

proc cToNim(ct: string): string =
  ## a C type (as cParamType gives it: "char*", "struct foo*", "unsigned int") as Nim writes it for importc
  if ct == "fnptr": return "pointer"
  let stars = ct.count('*')
  var base = ct.replace("*", "").strip
  for pre in ["struct ", "enum ", "union "]:
    if base.startsWith(pre): base = base[pre.len .. ^1].strip
  let prim = cNimFor(base)
  if stars == 0: return (if base == "void": "" elif prim.len > 0: prim[0] else: base)
  if base in ["char", "signed char"] and stars == 1: return "cstring"
  if base == "char" and stars == 2: return "cstringArray"
  if base == "void": return (if stars == 1: "pointer" else: "ptr pointer")
  result = if prim.len > 0: prim[0] else: base
  for _ in 1 .. stars: result = "ptr " & result

proc cParamName(p: string, i: int): string =
  ## a C parameter's name for Nim ("a1" … when it has none; a Nim keyword in backticks)
  let t = cCleanType(p).replace("*", " ").splitWhitespace
  const TypeWords = ["int", "char", "long", "short", "float", "double", "unsigned", "signed", "void", "_Bool", "bool",
                     "struct", "enum", "union"]
  var n = ""
  if t.len >= 2 and t[^1] notin TypeWords and t[^2] notin ["struct", "enum", "union"]: n = t[^1]
  n = n.strip(chars = {'_'})
  if n.len == 0 or n[0] notin IdentStartChars: n = "a" & $(i + 1)
  if n in FKeywords: n = "`" & n & "`"
  n

proc cNimSignature(cp: CProto): (string, bool) =
  ## "(s: cstring, n: csize_t): cint" for a C function, and whether it takes more arguments (…)
  var ps: seq[string]
  for i, p in cp.params:
    let t = cToNim(cParamType(p))
    ps.add cParamName(p, i) & ": " & (if t.len > 0: t else: "pointer")
  let r = cToNim(cp.ret.replace(" *", "*"))
  ("(" & ps.join(", ") & ")" & (if r.len > 0: ": " & r else: ""), cp.varargs)

proc ffiRewriteFix(b: Buffer): (string, string, Action) =
  ## the quick fix: this wrapper's parameters and result written again from its C declaration
  if b.lang == nil or b.lang.mode != lmNim: return
  let decls = nimFfiDecls(b.lines)
  let i = ffiAtLine(decls, b.primary.head.line)
  if i < 0 or decls[i].kind notin ["proc", "func"]: return
  let d = decls[i]
  let (cp, _) = ffiCDecl(d, b.path, b.lines, false)
  if cp.kind != "function": return
  let (sig, va) = cNimSignature(cp)
  var text = ""
  for l in d.line .. min(d.eline, b.lines.high): text.add (if text.len > 0: " " else: "") & b.lines[l].strip
  let pa = text.find("{.")
  let pe = if pa >= 0: text.find(".}", pa) else: -1
  if pa < 0 or pe < 0: return
  var prag = text[pa + 2 ..< pe].strip
  if va and "varargs" notin prag: prag = "varargs, " & prag
  let nameAt = text.find(d.name)
  if nameAt < 0: return
  var head = text[0 ..< nameAt + d.name.len]
  if nameAt + d.name.len < text.len and text[nameAt + d.name.len] == '*': head.add "*"
  let ind = b.lines[d.line][0 ..< leadWs(b.lines[d.line])]
  let newText = ind & head & sig & " {." & prag & ".}"
  if newText.strip == text.strip: return
  let bid = b.id
  let (l0, l1) = (d.line, min(d.eline, b.lines.high))
  ("Rewrite this wrapper from its C declaration", cPrettyProto(cp, d.cname), proc() =
    let bb = bufById(bid)
    if bb == nil or l1 >= bb.lines.len: return
    bb.beginEdit()
    discard bb.replaceText(Pos(line: l0, col: 0), Pos(line: l1, col: bb.lines[l1].len), newText)
    bb.endEdit()
    bb.normalize()
    if l1 > l0 and newText.len > FmtWidth and cfgNimFormatter == "builtin":
      discard bb.formatLineRange(l0, l0, quiet = true)     # (written one parameter a line: laid out as before)
    ffiCheck(bb)
    info("Wrapper written from C: " & newText.strip))

# ── proc <C name>: a wrapper completed from the headers the file uses ──

proc cWrapperComplete(b: Buffer, p: Pos, manual: bool): bool =
  ## after `proc ` (or func) in a file that imports C: the functions of its headers (and of its {.emit.}), each
  ## accepted as a whole wrapper — `puts(s: cstring): cint {.importc, header: "<stdio.h>".}`
  if b.lang == nil or b.lang.mode != lmNim or p.line >= b.lines.len: return false
  let s = b.lines[p.line]
  if p.col > s.len: return false
  let before = s[0 ..< p.col]
  let t = before.strip(trailing = false)
  var rest = ""
  for kw in ["proc ", "func "]:
    if t.startsWith(kw): rest = t[kw.len .. ^1]
  if rest.len == 0 and not (t == "proc " or t == "func "): return false
  for ch in rest:
    if ch notin IdentChars: return false
  if p.col < s.len and s[p.col ..< s.len].strip.len > 0: return false      # (only at the end of the line)
  # the headers this file imports from
  var hdrs: seq[string]
  for l in b.lines:
    let h = l.find("header:")
    if h < 0: continue
    let q1 = l.find('"', h)
    let q2 = if q1 >= 0: l.find('"', q1 + 1) else: -1
    if q2 > q1 + 1 and l[q1 + 1 ..< q2] notin hdrs: hdrs.add l[q1 + 1 ..< q2]
    if hdrs.len >= 12: break
  let own = emitIndex(b)
  if hdrs.len == 0 and own.decls.len == 0: return false
  let dirs = cIncludeDirs(b.path, b.lines)
  var have: HashSet[string]
  for d in nimFfiDecls(b.lines): have.incl d.cname
  var items: seq[CompItem]
  proc addFn(name: string, cp: CProto, pragma, where: string) =
    if name in have or name.startsWith("_") or items.len > 4000: return
    let (sig, va) = cNimSignature(cp)
    let prag = (if va: "varargs, " else: "") & pragma
    items.add CompItem(label: name, insert: name & sig & " {." & prag & ".}", detail: "C · " & where, kind: 3,
                       filter: name, sortText: name, rank: 1,
                       doc: "```c\n" & cPrettyProto(cp, name) & "\n```\n" & where & " — accepting writes the wrapper",
                       docMade: true)
  try:
    for n, d in own.decls:
      if d.kind == "function": addFn(n, d, "importc, nodecl", "{.emit.} in this file")
    for h in hdrs:
      let hp = cFindHeader(h, dirs, parentDir(b.path))
      if hp.len == 0: continue
      for n, d in cHeaderIndex(hp).decls:
        if d.kind == "function": addFn(n, d, "importc, header: \"" & h & "\"", h)
  except CatchableError as e:
    internalError("C wrapper completion", e)
    return false
  if items.len == 0: return false
  items.sort(proc(x, y: CompItem): int = cmp(x.label, y.label))
  compLine = p.line
  compStartCol = p.col - rest.len
  compManual = manual
  compNx.setLen(0)
  compItems = items
  compFromLsp = true
  refilterComp()
  compOpen
