# ── inside a routine: parameters, result, lets/vars/for variables before the cursor ──

proc nxEnclosing*(f: NxFile, line: int): int =
  ## index of the top-level routine around `line`, or -1
  result = -1
  for i in 0 ..< f.syms.len:
    template s: untyped = f.syms[i]      # (no copy of each symbol)
    if s.kind in NxRoutineKinds and s.line <= line and line <= s.endLine and not s.made:
      if result < 0 or s.line > f.syms[result].line: result = i

proc nxBaseName*(t: string): string
proc nxTypeArgs*(t: string): seq[string]

var nxHeaderCache*: Table[string, seq[NxSym]]    # a nested routine's header → its declaration

proc nxLocals*(f: NxFile, lines: openArray[string], line, col: int, everything = false): seq[NxSym] =
  ## the routine's parameters and the locals visible at line:col (everything: all declared up to that line,
  ## whatever block they are in)
  let ri = nxEnclosing(f, line)
  var a = 0
  var moduleLevel = false
  if ri >= 0:
    let r = f.syms[ri]
    var at = (r.line, max(0, lines[r.line].find('(')))
    for p in r.params:
      # where the parameter is written (headers can span lines)
      let nm = p.name.strip(chars = {'`'})
      let (pl, pc) = nxLocate(lines, nm, r.line, min(r.line + 12, lines.high), at)
      at = (pl, pc + nm.len)
      var pt = p.typ
      if r.kind == nxMacro and pt.replace(" ", "") in ["untyped", "typed", "varargs[untyped]", "varargs[typed]"]:
        pt = "NimNode"                    # (inside a macro its arguments are syntax trees)
      result.add NxSym(name: nm, kind: nxParam, typ: pt, value: p.default, line: pl, col: pc)
    if r.ret.len > 0 and r.kind notin {nxTemplate, nxMacro, nxIterator}:
      var rt = r.ret
      if rt.startsWith("owned(") and rt.endsWith(")"): rt = rt[6 ..< rt.high].strip
      elif rt.startsWith("owned "): rt = rt[6 .. ^1].strip
      if ("async" in r.pragmas or "multisync" in r.pragmas) and nxBaseName(rt) in ["Future", "FutureEx"]:
        # an async proc's result is what its Future holds
        let ta = nxTypeArgs(rt)
        rt = if ta.len > 0: ta[0] else: "void"
        let alts = nxSplitTop(rt, {'|'})
        if alts.len > 1: rt = alts[0].strip            # Response | AsyncResponse
      if rt != "void": result.add NxSym(name: "result", kind: nxResult, typ: rt, line: r.line)
    elif r.kind == nxMacro:
      result.add NxSym(name: "result", kind: nxResult, typ: "NimNode", line: r.line)   # (whatever it says it returns)
    a = r.line + 1
  else:
    # module level: the file's own symbols have its declarations; what a top-level statement declares in its
    # blocks (a `for` loop's variables, the lets in its body) is found from where that statement starts
    var s0 = min(line, lines.high)
    while s0 > 0:
      let t0 = lines[s0]
      if t0.len > 0 and t0[0] notin {' ', '\t', '#', ')', ']', '}'}: break
      dec s0
    if s0 >= 0 and nxEnclosing(f, s0) >= 0: return    # (the blank lines after a routine: none of its locals)
    a = max(0, s0)
    moduleLevel = true
  var st: NxLexState
  var code, doc: string
  var secKind = nxLet
  var secInd = -1
  var memberInd = -1
  # block scoping: each local remembers the indentation of the block it lives in; a later line
  # indented less than that ends the block (an `of` / `elif` branch, a loop body …)
  let last = min(line, lines.high)
  var scopes: seq[int]
  for _ in result: scopes.add -1
  var indents = newSeq[int](max(0, last - a + 1))
  var lastS, lastFor = 0
  var open = 0
  template flushScopes() =
    while scopes.len < result.len:
      scopes.add (if result[scopes.len].kind == nxForVar: lastFor + 1 else: lastS)
  for l in a .. last:
    flushScopes()
    var dep = 0
    let wasOpen = open > 0
    let inStr = st.inTriple or st.blockDepth > 0
    nxSplitLine(lines[l], st, code, doc, dep)
    open = max(0, open + dep)
    let raw = lines[l]
    var t = code.strip
    indents[l - a] = -1
    if t.len == 0 or inStr: continue
    let ind = raw.len - raw.strip(trailing = false).len
    if not wasOpen: indents[l - a] = ind
    lastS = ind
    lastFor = ind
    if secInd >= 0 and ind <= secInd:
      secInd = -1
      memberInd = -1
    let (w0, we) = nxName(t, 0)
    let rest = if we < t.len: t[we .. ^1].strip else: ""
    proc addVars(text: string, kk: NxKind, res: var seq[NxSym], l: int, raw: string, lines: openArray[string],
                 ind: int) =
      let c1 = nxFindTop(text, ':')
      let e1 = nxFindTop(text, '=')
      var endNames = text.len
      if c1 >= 0: endNames = c1
      if e1 >= 0 and e1 < endNames: endNames = e1
      var typ = ""
      if c1 >= 0 and (e1 < 0 or c1 < e1): typ = (if e1 > c1: text[c1 + 1 ..< e1] else: text[c1 + 1 .. ^1]).strip
      var val = if e1 >= 0: text[e1 + 1 .. ^1].strip else: ""
      if typ.len == 0 and e1 >= 0: val = nxBlockValue(lines, l + 1, ind, val)
      let unpack = text.strip.startsWith("(")      # let (a, b) = …: each name takes one element
      let names = nxSplitTop(text[0 ..< endNames].strip(chars = {'(', ')', ' '}), {','})
      for vi, p in names:
        let (nm, _) = nxName(nxStripPragma(p)[0], 0)
        if nm.len == 0 or nm == "_": continue
        res.add NxSym(name: nm, kind: kk, typ: (if unpack: "" else: nxCollapse(typ)), value: val, line: l,
                      col: nxWordCol(raw, nm), slot: vi.int16, slots: (if unpack: -names.len.int16 else: 0))
    template whole(x: string): string =
      # a declaration whose brackets close on later lines: all of it
      var tj = x
      if dep > 0:
        var st2 = st
        var d2 = dep
        var l2 = l + 1
        while d2 > 0 and l2 < lines.len and l2 - l < 60:
          var c2, dc2: string
          nxSplitLine(lines[l2], st2, c2, dc2, d2)
          tj.add " " & c2.strip
          inc l2
      tj
    if secInd >= 0:
      if memberInd < 0: memberInd = ind
      if ind == memberInd:
        lastS = secInd
        addVars(whole(t), secKind, result, l, raw, lines, ind)
        continue
    if w0 in ["let", "var", "const"]:
      let kk = if w0 == "let": nxLet elif w0 == "var": nxVar else: nxConst
      if rest.len == 0:
        secKind = kk
        secInd = ind
        memberInd = -1
      else:
        let wr = whole(rest)
        if ';' in wr:
          # let a = 1; let b = "x": each statement after `;` on the same line too
          let parts = nxSplitTop(wr, {';'})
          addVars(parts[0], kk, result, l, raw, lines, ind)
          for pk in 1 ..< parts.len:
            let p2 = parts[pk].strip
            for kw2 in ["let ", "var ", "const "]:
              if p2.startsWith(kw2):
                addVars(p2[kw2.len .. ^1].strip, (if kw2 == "const ": nxConst elif kw2 == "let ": nxLet else: nxVar),
                        result, l, raw, lines, ind)
        else: addVars(wr, kk, result, l, raw, lines, ind)
    elif w0 == "for":
      let k = t.find(" in ")
      if k > 3:
        let vars = nxSplitTop(t[4 ..< k].strip(chars = {'(', ')', ' '}), {','})
        let unpack = t[4 ..< k].strip.startsWith("(")   # for (a, b) in pairsOfThings
        let colon = nxFindTop(t, ':', k + 4)
        let iter = if colon > 0: t[k + 4 ..< colon].strip else: t[k + 4 .. ^1].strip(chars = {':', ' '})
        for vi, p in vars:
          if p.strip.startsWith("("):
            # for i, (a, b) in …: nested unpacking — the names are known, their types are not
            for q in nxSplitTop(p.strip(chars = {'(', ')', ' '}), {','}):
              let (qn, _) = nxName(q, 0)
              if qn.len > 0 and qn != "_":
                result.add NxSym(name: qn, kind: nxForVar, line: l, col: nxWordCol(raw, qn), value: "",
                                 endLine: (if colon > 0 and colon < t.high: ind + colon + 1 else: -1))
            continue
          let (nm, _) = nxName(p, 0)
          if nm.len > 0 and nm != "_":
            # endLine: where a one-line body starts (`for x in xs: echo x`), -1 when it is on the next lines
            result.add NxSym(name: nm, kind: nxForVar, line: l, col: nxWordCol(raw, nm), value: iter,
                             slot: vi.int16, slots: (if unpack: -vars.len.int16 else: vars.len.int16),
                             endLine: (if colon > 0 and colon < t.high: ind + colon + 1 else: -1))
    elif w0 in NxRoutineKw and rest.len > 0:
      let (nm, _) = nxName(rest, 0)
      if nm.len > 0: result.add NxSym(name: nm, kind: NxKind(NxRoutineKw.find(w0)), line: l, col: nxWordCol(raw, nm))
      # a routine in here (or in a `when` branch the declarations leave out): its parameters, inside its body
      flushScopes()
      var hdr: seq[string]
      for k in l .. min(lines.high, l + 12):
        hdr.add lines[k][min(ind, leadWs(lines[k])) .. ^1]
        if lines[k].strip.endsWith("="): break
      let hkey = hdr.join("\n")
      if hkey notin nxHeaderCache:
        if nxHeaderCache.len > 4000: nxHeaderCache.clear()
        nxHeaderCache[hkey] = nxParse(hdr, "").syms
      for s in nxHeaderCache[hkey]:
        if s.kind notin NxRoutineKinds: continue
        if nm.len > 0 and result.len > 0 and result[^1].name == nm and result[^1].line == l:
          # (the routine itself: what it takes and gives, for calls to it)
          result[^1].params = s.params
          result[^1].ret = s.ret
          result[^1].generics = s.generics
          result[^1].pragmas = s.pragmas
        var at2 = (l, max(0, raw.find('(')))
        for p in s.params:
          let pn = p.name.strip(chars = {'`'})
          let (pl, pc) = nxLocate(lines, pn, l, min(l + 12, lines.high), at2)
          at2 = (pl, pc + pn.len)
          var pt = p.typ
          if s.kind == nxMacro and pt.replace(" ", "") in ["untyped", "typed", "varargs[untyped]", "varargs[typed]"]:
            pt = "NimNode"
          result.add NxSym(name: pn, kind: nxParam, typ: pt, value: p.default, line: pl, col: pc)
          scopes.add ind + 1
        if s.ret.len > 0 and s.kind notin {nxTemplate, nxMacro, nxIterator}:
          result.add NxSym(name: "result", kind: nxResult, typ: s.ret, line: l)
          scopes.add ind + 1
        break
    elif w0 == "except" and " as " in t:
      let k = t.find(" as ")
      let (nm, _) = nxName(t, k + 4)
      if nm.len > 0: result.add NxSym(name: nm, kind: nxLet, typ: "ref " & t[6 ..< k].strip, line: l,
                                      col: nxWordCol(raw, nm))
  flushScopes()
  block itTemplate:
    # inside s.mapIt(…), filterIt(s, …) …: `it` is one item of the collection
    var depthP = 0
    var k = min(col, lines[line].len) - 1
    let t = lines[line]
    while k >= 0:
      if t[k] == ')': inc depthP
      elif t[k] == '(':
        if depthP == 0:
          var e = k
          var a2 = e
          while a2 > 0 and nxIsIdent(t[a2 - 1]): dec a2
          let tn = t[a2 ..< e]
          if tn.len > 2 and tn.endsWith("It"):
            var recvE = ""
            if a2 > 0 and t[a2 - 1] == '.':
              var r = a2 - 1
              var dd = 0
              while r > 0:
                let ch = t[r - 1]
                if ch in {')', ']'}: inc dd
                elif ch in {'(', '['}:
                  if dd == 0: break
                  dec dd
                elif dd == 0 and not (nxIsIdent(ch) or ch == '.'): break
                dec r
              recvE = t[r ..< a2 - 1]
            else:
              let ce = nxMatchClose(t, k)
              let inner = t[k + 1 ..< (if ce > 0: ce else: t.len)]
              let ps = nxSplitTop(inner, {','})
              if ps.len > 0: recvE = ps[0].strip
            if recvE.len > 0:
              result.add NxSym(name: "it", kind: nxLet, value: "(" & recvE & ")[0]", line: line, col: a2)
              scopes.add -1
          break
        dec depthP
      dec k
  if moduleLevel:
    # (what the file's own symbols already have is not a local too)
    var declared: HashSet[(int, string)]
    for sy in f.syms: declared.incl (sy.line, sy.name)
    var r2: seq[NxSym]
    var s2: seq[int]
    for k, sy in result:
      if (sy.line, sy.name) notin declared:
        r2.add sy
        s2.add scopes[k]
    result = r2
    scopes = s2
  # the smallest indentation from each line down to the cursor's
  var sufMin = newSeq[int](indents.len + 1)
  sufMin[indents.len] = high(int)
  for k in countdown(indents.high, 0):
    sufMin[k] = if indents[k] >= 0: min(indents[k], sufMin[k + 1]) else: sufMin[k + 1]
  # what the cursor's own line declares exists only from there on: `var node = node` reads the older
  # `node`; on the new name itself it is the new one
  if everything: return
  var keep: seq[NxSym]
  for k, s in result:
    if s.line != line or s.kind in {nxParam, nxResult} or (s.col <= col and col <= s.col + s.name.len) or
       (s.kind == nxForVar and s.endLine > 0 and col > s.endLine):
      # still inside its block?
      if scopes[k] >= 0 and s.line >= a and s.line < line and s.line - a + 1 <= indents.len and
         sufMin[s.line - a + 1] < scopes[k]: continue
      keep.add s
  result = keep
