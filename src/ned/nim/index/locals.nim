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

func nxMacroParam*(typ: string): string =
  ## a macro's parameter inside the macro: a syntax tree (NimNode) whatever type is written — `cf: ClCfg`,
  ## `nested = true`, `x: typed{nkSym}` — apart from static[T] and typedesc ones, which keep theirs
  let t = typ.replace(" ", "")
  if t.startsWith("static") or t.startsWith("typedesc") or t.startsWith("type[") or t == "type": typ
  else: "NimNode"

proc nxMultisyncParam*(typ: string): string =
  ## a {.multisync.} routine's `HttpClient | AsyncHttpClient` parameter: the synchronous one (the routine is
  ## written as that, the async one is made from it) — as the macro splits it: two alternatives, one of them with
  ## "async" in its name; any other (`url: Uri | string`) stays what it is in both
  let alts = nxSplitTop(typ, {'|'})
  if alts.len != 2: return typ
  let a0 = "async" in alts[0].toLowerAscii.replace("_", "")
  let a1 = "async" in alts[1].toLowerAscii.replace("_", "")
  if a0 == a1: typ elif a0: alts[1].strip else: alts[0].strip

proc nxHeaderEnd*(lines: openArray[string], r: NxSym): int =
  ## the last line a routine's parameters can be on (its header may span many lines)
  min(lines.high, max(r.line + 12, min(r.line + 80, r.endLine)))

proc nxQuoteStart*(lines: openArray[string], line: int): int =
  ## the line of the `quote do:` whose quoted code `line` is in, or -1
  if line >= lines.len: return -1
  var curMin = high(int)
  if lines[line].strip.len > 0: curMin = leadWs(lines[line])
  var l = line - 1
  while l >= 0 and line - l < 400 and curMin > 0:
    let t = lines[l]
    let ts = t.strip
    if ts.len > 0 and not ts.startsWith("#") and leadWs(t) < curMin:
      curMin = leadWs(t)
      var c = ts
      let h = c.find(" #")
      if h >= 0: c = c[0 ..< h].strip
      if c.endsWith("quote do:") or c.endsWith("quote:") or (c.endsWith("do:") and "quote(" in c): return l
      if c.startsWith("proc ") or c.startsWith("macro ") or c.startsWith("template ") or c.startsWith("func "):
        if leadWs(t) == 0: return -1
    dec l
  -1

proc nxReceiver*(line: string, dot: int): string
proc nxCallArg*(args: string, params: seq[NxParam], k: int): string

const NxBlockKw = ["if", "elif", "else", "while", "when", "case", "of", "for", "block", "try", "except", "finally",
                   "static", "defer", "proc", "func", "method", "iterator", "converter", "template", "macro", "type",
                   "return", "let", "var", "const"]

type
  NxTplAround* = object      # a template around a line: its name, parameters, header line, last line of its body
    name*: string
    params*: seq[NxParam]
    line*, endLine*: int
  NxLines* = ref object
    key: string
    ls*: seq[string]
    tpls: seq[(int32, int32)]  # the templates declared in it, nested ones too: (header line, last line of the body)
    tplsMade: bool

var
  nxLinesCache: seq[NxLines]                                # the files last asked about (a few), the latest last
  nxCallSites: Table[string, seq[(int, int, string)]]       # (template, file) → its calls there
  nxInjects: Table[string, seq[(int, string, int)]]         # template → what it declares for its arguments

proc nxLinesOf*(f: NxFile): NxLines =
  ## the file's lines (the open buffer's when there is one), kept for the few files last asked about
  let key = f.path & "\t" & f.stamp.split('#')[0]
  for k in countdown(nxLinesCache.high, 0):
    if nxLinesCache[k].key == key:
      result = nxLinesCache[k]
      if k < nxLinesCache.high:
        nxLinesCache.delete(k)
        nxLinesCache.add result
      return
  result = NxLines(key: key)
  try:
    result.ls = if nxBufferLines != nil and nxBufferStamp(f.path).len > 0: nxBufferLines(f.path)
                elif f.path.len > 0 and getFileSize(f.path) <= 4_000_000: readFile(f.path).splitLines
                else: @[]
  except CatchableError: discard
  if nxLinesCache.len >= 4: nxLinesCache.delete(0)
  nxLinesCache.add result

proc nxTemplateHeader(lines: openArray[string], l: int): NxSym =
  ## the template declared on line l (its header may go on below)
  var hdr: seq[string]
  let i0 = leadWs(lines[l])
  for k in l .. min(lines.high, l + 12):
    hdr.add lines[k][min(i0, leadWs(lines[k])) .. ^1]
    if nxCodeOf(lines[k]).endsWith("=") or (k == l and nxFindTop(lines[k], '=') > 0): break
  let key = hdr.join("\n")
  if key notin nxHeaderCache:
    if nxHeaderCache.len > 4000: nxHeaderCache.clear()
    nxHeaderCache[key] = nxParse(hdr, "").syms
  for s in nxHeaderCache[key]:
    if s.kind == nxTemplate: return s

proc nxTemplateAround*(fl: NxLines, line: int): NxTplAround =
  ## the innermost template whose body (or header) `line` is in — at the top level or declared inside a routine —
  ## or line -1
  result.line = -1
  template lines: untyped = fl.ls
  if not fl.tplsMade:
    fl.tplsMade = true
    var st: NxLexState
    var code, doc: string
    var dep = 0
    for l in 0 ..< lines.len:
      let inStr = st.inTriple or st.blockDepth > 0
      nxSplitLine(lines[l], st, code, doc, dep)
      if inStr: continue
      let i0 = leadWs(code)
      if not code.continuesWith("template ", i0): continue
      var e = l
      for k in l + 1 ..< lines.len:
        let lw = leadWs(lines[k])
        if lw >= lines[k].len or lines[k][lw] == '#': continue
        if lw <= i0: break
        e = k
      fl.tpls.add (int32(l), int32(e))
  var best = -1
  for k, (a, e) in fl.tpls:
    if a <= line and line <= e and (best < 0 or a > fl.tpls[best][0]): best = k
  if best < 0: return
  let l = fl.tpls[best][0].int
  let s = nxTemplateHeader(lines, l)
  if s.name.len > 0: result = NxTplAround(name: s.name, params: s.params, line: l, endLine: fl.tpls[best][1].int)

func nxInactiveLine*(f: NxFile, l: int): bool =
  ## in a `when` branch left out here
  for (a, b) in f.inactive:
    if a <= l and l <= b: return true

proc nxTemplateCalls*(f: NxFile, lines: openArray[string], tpl: NxTplAround, mine: bool): seq[(int, int, string)] =
  ## the calls of a template in its file, outside its own body: (line, column of the name, its arguments' text —
  ## the receiver written before a dot first); calls in code compiled here first, or, for code in a `when` branch
  ## left out here (mine), calls in such branches first
  let key = f.path & "\t" & f.stamp.split('#')[0] & "\t" & $tpl.line & "\t" & $mine
  if key in nxCallSites: return nxCallSites[key]
  template inactive(l: int): bool = nxInactiveLine(f, l)
  var other, before: seq[(int, int, string)]
  # a template declared in a routine is called in the rest of it; one at the top level after it (or, in other
  # templates, before)
  var lo = 0
  var hi = lines.high
  let ri = nxEnclosing(f, tpl.line)
  if ri >= 0 and f.syms[ri].line < tpl.line:
    lo = tpl.endLine + 1
    hi = min(hi, f.syms[ri].endLine)
  for l in lo .. hi:
    if l >= tpl.line and l <= tpl.endLine: continue
    let raw = lines[l]
    if tpl.name notin raw: continue
    let code = nxCodeOf(raw)
    let off = leadWs(raw)
    var k = code.find(tpl.name)
    while k >= 0 and result.len + other.len + before.len < 12:
      let e = k + tpl.name.len
      var quotes = 0                             # (not in a string: of "resp", "pass": …)
      var q = 0
      while q < k:
        if code[q] == '\\': inc q
        elif code[q] == '"': inc quotes
        elif code[q] == '\'' and q + 2 < code.len and code[q + 2] == '\'': q += 2
        inc q
      if quotes mod 2 == 0 and (k == 0 or not nxIsIdent(code[k - 1])) and (e >= code.len or not nxIsIdent(code[e])):
        let pre = code[0 ..< k].strip
        if not (pre.endsWith("template") or pre.endsWith("proc") or pre.endsWith("func") or pre.endsWith("macro")):
          var args = ""
          if e < code.len and code[e] == '(':
            var whole = code[e .. ^1]
            var l2 = l
            while nxMatchClose(whole, 0) < 0 and l2 + 1 < lines.len and l2 - l < 12:
              inc l2
              whole.add " " & nxCodeOf(lines[l2])
            let ce = nxMatchClose(whole, 0)
            args = if ce > 0: whole[1 ..< ce] else: whole[1 .. ^1]
          elif e < code.len and code[e] == ' ':
            args = code[e .. ^1].strip
            if args.endsWith("do:"): args = args[0 ..< ^3].strip
            if args.endsWith(":"): args = args[0 ..< ^1].strip
          if k > 0 and code[k - 1] == '.':
            let r = nxReceiver(code, k - 1)
            if r.len > 0: args = (if args.len > 0: r & ", " & args else: r)
          let c = (l, off + k, args)
          if inactive(l) != mine: other.add c
          elif l < tpl.line: before.add c
          else: result.add c
      k = code.find(tpl.name, k + 1)
  result.add before
  result.add other
  if nxCallSites.len > 300: nxCallSites.clear()
  nxCallSites[key] = result

proc nxTemplateInjects*(r: NxRef): seq[(int, string, int)] =
  ## what a template declares in its body for its untyped parameters — withData(s, fd, value, body): `var value =
  ## addr(s.fds[fdi].data)` — as (parameter index, the value written, its line)
  template s: untyped = r.sym
  let key = r.file.path & "\t" & r.file.stamp & "\t" & $s.line
  if key in nxInjects: return nxInjects[key]
  let ls = nxLinesOf(r.file).ls
  if s.line >= ls.len: return
  for l in s.line + 1 .. min(s.endLine, ls.high):
    let t = nxCodeOf(ls[l])
    for kw in ["var ", "let "]:
      if t.startsWith(kw):
        let rest = t[kw.len .. ^1]
        let eq = nxFindTop(rest, '=')
        if eq <= 0: continue
        let nm = nxStripPragma(rest[0 ..< eq])[0].strip
        for k, p in s.params:
          if p.name == nm and (p.typ.len == 0 or p.typ == "untyped"): result.add (k, rest[eq + 1 .. ^1].strip, l)
  if nxInjects.len > 300: nxInjects.clear()
  nxInjects[key] = result

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
      let (pl, pc) = nxLocate(lines, nm, r.line, nxHeaderEnd(lines, r), at)
      at = (pl, pc + nm.len)
      var pt = p.typ
      if r.kind == nxMacro: pt = nxMacroParam(pt)    # (inside a macro its arguments are syntax trees)
      elif r.kind == nxTemplate and pt.len == 0 and p.default.len == 0: pt = "untyped"
      elif "multisync" in r.pragmas: pt = nxMultisyncParam(pt)
      # (ret: the type as written, when it is read otherwise inside — what its own declaration shows)
      result.add NxSym(name: nm, kind: nxParam, typ: pt, value: p.default, line: pl, col: pc,
                       ret: (if pt != p.typ: p.typ else: ""))
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
  # `when` opens no scope: what its branches declare is the enclosing block's (headers: (indentation, a `when`))
  var hdrs: seq[(int, bool)]
  var chainWhen: Table[int, bool]
  var secScope = 0
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
    if not wasOpen:
      while hdrs.len > 0 and hdrs[^1][0] >= ind: discard hdrs.pop()
      var k = hdrs.high
      while k >= 0 and hdrs[k][1] and hdrs[k][0] < lastS:
        lastS = hdrs[k][0]                       # (in a `when` branch: the block around the `when`)
        dec k
      if t.endsWith(":"):
        let w = nxName(t, 0)[0]
        if w == "when": chainWhen[ind] = true
        elif w in ["if", "case", "try"]: chainWhen[ind] = false
        hdrs.add (ind, w == "when" or (w in ["elif", "else"] and chainWhen.getOrDefault(ind)))
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
        if nm.len == 0: continue                 # (`_` too: it has a type hint, nothing refers to it)
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
    if not wasOpen and "proc" in t:
      # anonymous procs — fut.callback = proc (future: Future[T]) = … — their parameters, inside their bodies
      var k = t.find("proc")
      while k >= 0:
        var j = k + 4
        while j < t.len and t[j] == ' ': inc j
        if (k == 0 or not nxIsIdent(t[k - 1])) and j < t.len and t[j] == '(':
          let wt = whole(t)[j .. ^1]
          let ce = nxMatchClose(wt, 0)
          if ce > 0 and nxFindTop(wt[ce + 1 .. ^1], '=') >= 0:
            flushScopes()
            var at3 = (l, max(0, raw.find('(', raw.find("proc"))))
            for p in nxParseParams(wt[1 ..< ce]):
              let pn = p.name.strip(chars = {'`'})
              if pn.len == 0: continue
              let (pl, pc) = nxLocate(lines, pn, l, min(l + 12, lines.high), at3)
              at3 = (pl, pc + pn.len)
              result.add NxSym(name: pn, kind: nxParam, typ: p.typ, value: p.default, line: pl, col: pc)
              scopes.add ind + 1
        k = t.find("proc", k + 4)
    if secInd >= 0:
      if memberInd < 0: memberInd = ind
      if ind == memberInd:
        lastS = secScope
        addVars(whole(t), secKind, result, l, raw, lines, ind)
        continue
    if w0 in ["let", "var", "const"]:
      let kk = if w0 == "let": nxLet elif w0 == "var": nxVar else: nxConst
      if rest.len == 0:
        secKind = kk
        secInd = ind
        secScope = lastS
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
      let t = if dep > 0: whole(t) else: t         # (for p in s.partitionRange(⏎ …): the header goes on below)
      let k = t.find(" in ")
      if k > 3:
        let vars = nxSplitTop(t[4 ..< k].strip(chars = {'(', ')', ' '}), {','})
        let unpack = t[4 ..< k].strip.startsWith("(")   # for (a, b) in pairsOfThings
        let colon = nxFindTop(t, ':', k + 4)
        let iter = if colon > 0: t[k + 4 ..< colon].strip else: t[k + 4 .. ^1].strip(chars = {':', ' '})
        for vi, p in vars:
          if p.strip.startsWith("("):
            # for i, (a, b) in …: nested unpacking — each name a part of that variable's tuple
            for qi, q in nxSplitTop(p.strip(chars = {'(', ')', ' '}), {','}):
              let (qn, _) = nxName(q, 0)
              if qn.len > 0:
                result.add NxSym(name: qn, kind: nxForVar, line: l, col: nxWordCol(raw, qn), value: iter,
                                 slot: vi.int16, slots: (if unpack: -vars.len.int16 else: vars.len.int16),
                                 sub: int16(qi + 1),
                                 endLine: (if colon > 0 and colon < t.high: ind + colon + 1 else: -1))
            continue
          let (nm, _) = nxName(p, 0)
          if nm.len > 0:
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
          if s.kind == nxMacro: pt = nxMacroParam(pt)
          elif s.kind == nxTemplate and pt.len == 0 and p.default.len == 0: pt = "untyped"
          elif "multisync" in s.pragmas: pt = nxMultisyncParam(pt)
          result.add NxSym(name: pn, kind: nxParam, typ: pt, value: p.default, line: pl, col: pc,
                           ret: (if pt != p.typ: p.typ else: ""))
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
    elif t.endsWith(":") and not wasOpen and w0.len > 0 and w0 notin NxBlockKw:
      # a template called with a block: what it declares for its arguments there — withData(s, fd, value) do: …
      # (`var value = addr(s.fds[fdi].data)` in its body)
      let po = t.find('(')
      if po > 0 and t[0 ..< po].allCharsInSet(IdentChars + {'.'}):
        let pc = nxMatchClose(t, po)
        let tail = if pc > po: t[pc + 1 .. ^1].strip else: ""
        if tail in [":", "do:"]:
          let dot = t.rfind('.', last = po - 1)
          let callee = t[dot + 1 ..< po]
          var args = t[po + 1 ..< pc]
          if dot > 0: args = t[0 ..< dot] & ", " & args
          for r in nxLookup(nxScope(f), callee):
            if r.sym.kind != nxTemplate: continue
            let inj = nxTemplateInjects(r)
            if inj.len == 0: continue
            let ps = r.sym.params
            var sub: Table[string, string]
            for k, p in ps:
              let av = nxCallArg(args, ps, k)
              if av.len > 0: sub[p.name] = "(" & av & ")"
            flushScopes()
            for (k, v, vl) in inj:
              let nm = nxCallArg(args, ps, k)
              if nm.len == 0 or not nm.allCharsInSet(IdentChars): continue
              # (its type is worked out in the template's module, from what the call passes: owner says where)
              result.add NxSym(name: nm, kind: nxVar, value: nxSubstIdents(v, sub), line: l, col: nxWordCol(raw, nm),
                               owner: "\x01" & r.file.path & "\x01" & $vl & "\x01" & args)
              scopes.add ind + 1
            break
  flushScopes()
  block whenIs:
    # inside `when client is AsyncHttpClient:` the parameter is that one (multisync code, unions)
    var curMin = if line < lines.len: leadWs(lines[line]) else: 0
    var l = line - 1
    while l >= a and curMin > 0:
      let tl = lines[l].strip
      if tl.len > 0 and not tl.startsWith("#") and leadWs(lines[l]) < curMin:
        curMin = leadWs(lines[l])
        if (tl.startsWith("when ") or tl.startsWith("elif ")) and tl.endsWith(":") and " is " in tl:
          let c = tl[5 ..< ^1].strip
          let k = c.find(" is ")
          let pn = c[0 ..< k].strip
          let pt = c[k + 4 .. ^1].strip
          if pn.allCharsInSet(IdentChars) and pt.len > 0 and " " notin pt:
            for i in countdown(result.high, 0):
              if result[i].name == pn:
                # (a parameter, or a loop variable: `for f in x.fields: when f is string:`)
                if result[i].kind in {nxParam, nxForVar}: result[i].typ = pt
                break
          break
        if tl == "else:":
          # the `else:` of `when client is HttpClient:`: the parameter is the other one of its two
          let ind0 = leadWs(lines[l])
          var h = l - 1
          while h >= a and (lines[h].strip.len == 0 or leadWs(lines[h]) > ind0 or lines[h].strip.startsWith("#")): dec h
          if h >= a and leadWs(lines[h]) == ind0:
            let hl = nxCodeOf(lines[h])
            if hl.startsWith("when ") and hl.endsWith(":") and " is " in hl:
              let c = hl[5 ..< ^1].strip
              let k = c.find(" is ")
              let pn = c[0 ..< k].strip
              let pt = c[k + 4 .. ^1].strip
              for i in countdown(result.high, 0):
                if result[i].kind == nxParam and result[i].name == pn:
                  let written = if result[i].ret.len > 0: result[i].ret else: result[i].typ
                  let alts = nxSplitTop(written, {'|'})
                  if alts.len == 2:
                    let other = if alts[0].strip == pt: alts[1].strip elif alts[1].strip == pt: alts[0].strip else: ""
                    if other.len > 0: result[i].typ = other
                  break
          break
      dec l
  block itTemplate:
    # inside s.mapIt(…), filterIt(s, …) …: `it` is one item of the collection
    var depthP = 0
    var k = min(col, lines[line].len) - 1
    let t = lines[line]
    while k >= 0:
      if t[k] == ')': inc depthP
      elif t[k] == '(':
        if depthP == 0:
          let e = k
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
