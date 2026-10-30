# ── NIF, Nim 3's code between its passes (nifread.nim reads it): its outline; on hover, what a tag is and where a
#    node comes from in the Nim source; F12 to that place (on a symbol, to where the NIF declares it); and the NIF
#    of a Nim file beside it, each following the cursor in the other ──

var
  nifMemo: Table[int, (int, seq[NifNode])]                    # buffer → (the change it was read at, its nodes)
  nifTagsMemo: (string, Table[string, (string, string)])      # (Nimony's doc/tags.md, read: tag → forms, meaning)
  nifv: tuple[srcBufId, viewBufId, hot: int, hotView: bool]   # the NIF beside a Nim file

const NifTagWords = {
  "stmts": "statements, in order", "scope": "a block's statements, with names of their own",
  "proc": "a proc", "func": "a func", "iterator": "an iterator", "converter": "a converter", "method": "a method",
  "template": "a template", "macro": "a macro", "type": "a type declaration", "object": "an object type",
  "enum": "an enum type", "efld": "an enum's value", "fld": "an object's field", "params": "a routine's parameters",
  "param": "a parameter", "result": "a routine's result", "let": "a let", "var": "a var", "const": "a const",
  "gvar": "a global var", "tvar": "a thread-local var", "glet": "a global let", "call": "a call",
  "cmd": "a call without parentheses", "infix": "an operator between two operands", "prefix": "an operator before one",
  "dot": "a field: object, field", "at": "an index, or a generic instantiation", "asgn": "an assignment",
  "if": "an if: its elif and else branches", "elif": "a branch with a condition", "else": "the else branch",
  "case": "a case", "of": "a case branch", "ranges": "the values of a case branch", "while": "a while loop",
  "for": "a for loop", "ret": "a return", "discard": "a discard", "block": "a block", "break": "a break",
  "continue": "a continue", "try": "a try", "except": "an except branch", "fin": "a finally branch",
  "raise": "a raise", "pragmas": "pragmas", "typevars": "generic parameters", "typevar": "a generic parameter",
  "oconstr": "an object constructed (every field named)", "aconstr": "an array constructed", "kv": "a key and a value",
  "vv": "a named argument", "conv": "a type conversion", "hconv": "a hidden conversion", "cast": "a cast",
  "addr": "an address", "deref": "a pointer dereferenced", "nil": "nil", "true": "true", "false": "false",
  "i": "a signed integer type: its bits", "u": "an unsigned integer type: its bits", "f": "a float type: its bits",
  "c": "a char type: its bits", "bool": "bool", "ptr": "a ptr type", "ref": "a ref type", "mut": "a var parameter",
  "out": "an out parameter", "lent": "a lent type", "sink": "a sink parameter", "array": "an array type",
  "tup": "a tuple", "import": "an import", "include": "an include", "export": "an export", "emit": "an emit",
  "defer": "a defer", "yld": "a yield", "and": "and", "or": "or", "not": "not", "add": "+ (its type first)",
  "sub": "- (its type first)", "mul": "* (its type first)", "div": "div or / (its type first)",
  "mod": "mod (its type first)", "eq": "==", "neq": "!=", "lt": "<", "le": "<=", "sizeof": "sizeof",
  "suf": "a literal with a suffix", "err": "an error the compiler found here", "proctype": "a proc type",
  "requires": "a contract: what must hold when the routine is called", "ensures": "a contract: what holds after it",
  "passive": "a passive proc (it can pause: CPS)", "par": "parentheses", "bracket": "[…] before its type is known",
  "curly": "{…} before its type is known", "expr": "statements with a value", "nifs": "NIF files"}.toTable

proc nifNodesOf(b: Buffer): seq[NifNode] =
  ## the nodes of a NIF buffer, parsed again only when the buffer changed (kept for the last 16 buffers)
  if b.id in nifMemo and nifMemo[b.id][0] == b.changeId: return nifMemo[b.id][1]
  result = nifParse(b.lines)
  if nifMemo.len > 16: nifMemo.clear()
  nifMemo[b.id] = (b.changeId, result)

proc nifTagDoc(tag: string): (string, string) =
  ## a tag's forms and meaning: Nimony's own doc/tags.md when its checkout is here, else ned's words
  let p = if nimonyRoot().len > 0: nimonyRoot() / "doc" / "tags.md" else: ""
  if p != nifTagsMemo[0]:
    var t: Table[string, (string, string)]
    try:
      if p.len > 0 and fileExists(p): t = nifTagTable(readFile(p))
    except CatchableError: discard
    nifTagsMemo = (p, t)
  if tag in nifTagsMemo[1]: return nifTagsMemo[1][tag]
  ("", NifTagWords.getOrDefault(tag, ""))

proc nifSourcePath(nifPath, file: string): string =
  ## a source file a NIF names (as nimony was given it): absolute, else from the project, Nimony's checkout, the
  ## NIF's folders
  if file.len == 0: return ""
  if file.isAbsolute: return (if fileExists(file): file else: "")
  for base in [rootDir, nimonyRoot(), parentDir(nifPath), parentDir(parentDir(nifPath)), getCurrentDir()]:
    if base.len > 0 and fileExists(base / file): return normalizedPath(base / file)
  ""

proc nifHover(b: Buffer, p: Pos): string =
  ## what the tag at p is, what an atom there is, where it comes from in the Nim source
  if b.lang == nil or b.lang.id != "nif" or b.lines.len > 300_000: return ""
  let ns = nifNodesOf(b)
  let i = nifAt(ns, p.line, p.col)
  if i < 0: return ""
  let n = ns[i]
  let ni = if n.tag.len > 0: i else: n.parent
  if ni >= 0:
    let t = ns[ni].tag
    let (forms, desc) = nifTagDoc(t)
    result = "**(" & t & " …)**" & (if forms.len > 0: "  `" & forms & "`" else: "") &
             (if desc.len > 0: "\n\n" & desc elif t.startsWith("."): "\n\na directive of the NIF file" else: "")
  if n.tag.len == 0 and n.atom.len > 0 and n.atom != ".":
    result.add "\n\n" & (if n.isDef: "declares " else: "") & "`" & n.atom & "`"
  if n.sline >= 0:
    result.add "\n\nfrom " & (if n.file.len > 0: n.file else: "the source") & ":" & $(n.sline + 1) & ":" &
               $(n.scol + 1) & " — F12 goes there"

proc nifDefinition(b: Buffer, p: Pos): bool =
  ## F12 in NIF: on a symbol, where the NIF declares it; else the Nim source the node comes from
  if b.lang == nil or b.lang.id != "nif": return false
  let ns = nifNodesOf(b)
  let i = nifAt(ns, p.line, p.col)
  if i < 0: return false
  let n = ns[i]
  if n.tag.len == 0 and not n.isDef and n.atom.len > 0 and n.atom[0] notin {'"', '\'', '0'..'9', '.', '-'}:
    for d in ns:
      if d.isDef and d.atom == n.atom:
        pushJump()
        b.setSingle(b.clampPos(Pos(line: d.line, col: d.col)))
        b.centerOn(b.primary.head)
        return true
  if n.sline < 0:
    info("This node has no line information")
    return true
  let src = nifSourcePath(b.path, n.file)
  if src.len == 0:
    info("The source is not here: " & n.file)
    return true
  pushJump()
  let nb = openFile(src)
  if nb != nil:
    let q = nb.clampPos(Pos(line: n.sline, col: n.scol))
    nb.setSingle(q)
    nb.centerOn(q)
  true

proc nifOutlineOf(b: Buffer): seq[SideItem] =
  ## the NIF buffer's outline for the side panel: its declarations, with an icon for routines, types and the rest
  for it in nifOutline(nifNodesOf(b)):
    let fn = it.tag in ["proc", "func", "method", "iterator", "converter", "template", "macro"]
    result.add SideItem(text: it.name, detail: it.tag, path: b.path, line: it.line, col: it.col, depth: it.depth,
                        icon: (if fn: "ƒ" elif it.tag == "type": "T" else: "v"),
                        role: (if fn: 7 elif it.tag == "type": 8 else: 0))

# ── the NIF of a Nim file beside it ──

proc nifFileFor(path: string): string =
  ## the NIF nimony made of a file (its semchecked one, else its parsed one), in its build folders — "" none
  var best = ""
  var bestTime: times.Time
  for dir in [nimonyCache(), rootDir / "nimcache", parentDir(path) / "nimcache"]:
    if not dirExists(dir): continue
    try:
      for kind, f in walkDir(dir):
        if kind != pcFile or not (f.endsWith(".s.nif") or f.endsWith(".p.nif")): continue
        # (its first lines name the source: `(stmts@,1,the/file.nim`)
        var head = ""
        let fh = open(f)
        try:
          var k = 0
          var ln = ""
          while k < 4 and fh.readLine(ln):
            head.add ln & "\n"
            inc k
        finally: fh.close()
        let at = head.find("(stmts@")
        if at < 0: continue
        let c = head.find(',', head.find(',', at) + 1)
        if c < 0: continue
        var e = c + 1
        while e < head.len and head[e] notin {' ', '\n', '(', ')'}: inc e
        let src = nifSourcePath(f, head[c + 1 ..< e])
        if src != path and not path.endsWith("/" & head[c + 1 ..< e]): continue
        let t = getLastModificationTime(f)
        if best.len == 0 or (f.endsWith(".s.nif") and best.endsWith(".p.nif")) or
           (f.endsWith(".s.nif") == best.endsWith(".s.nif") and t > bestTime):
          best = f
          bestTime = t
    except CatchableError: discard
  best

proc nifOpenBeside(src: Buffer, nifPath: string) =
  ## opens the NIF file read-only beside the Nim buffer and links the two, so each follows the cursor in the other
  let srcIdx = curBuf
  let v = openFile(nifPath)
  if v == nil: return
  v.readOnly = true
  nifv = (src.id, v.id, -1, false)
  curBuf = srcIdx
  showBeside(src, v)
  info("The NIF of " & extractFilename(src.path) & " beside it — each follows the cursor in the other; F12 in it " &
       "goes to the source")
  needRender = true

proc cmdNifView() =
  ## Nim 3: the NIF nimony makes of the file (checked first when there is none yet), beside it
  let b = buf()
  if b.path.len == 0 or not b.path.endsWith(".nim"):
    info("Open a .nim file first")
    return
  let f = nifFileFor(b.path)
  if f.len > 0:
    nifOpenBeside(b, f)
    return
  if nimonyExe().len == 0:
    info("The NIF comes from Nim 3's compiler, nimony — not installed (Nim 3: install nimony)")
    return
  info("nimony checks " & extractFilename(b.path) & " to make its NIF…")
  let bid = b.id
  let path = b.path
  discard startJob(jkCheck, nimonyCheckCmd(path), parentDir(path), proc(j: Job) =
    let x = bufById(bid)
    let nf = nifFileFor(path)
    if x == nil: return
    if nf.len == 0: warn("nimony made no NIF of " & extractFilename(path) & " — see Problems")
    else: nifOpenBeside(x, nf))

proc nifReveal(id, line: int) =
  ## scrolls the buffer (in the current pane or in another that shows it) so that the line is in view, when it is not
  ## already
  let b = bufById(id)
  if b == nil or line < 0 or line >= b.lines.len: return
  if b == buf():
    if line < b.topLine or line >= b.topLine + max(3, textH) - 1: b.topLine = max(0, line - max(3, textH) div 3)
  else:
    for o in panesShowing(id):
      let h = max(3, panes[o].textH)
      let s = addr panes[o].snap
      if line < s.topLine or line >= s.topLine + h - 1:
        s.topLine = max(0, line - h div 3)
        s.topSub = 0
  needRender = true

proc nifPump() =
  ## (the main loop) the cursor in the Nim file: its NIF lit up and brought into view; in the NIF: the source line
  if nifv.viewBufId <= 0: return
  let v = bufById(nifv.viewBufId)
  let src = bufById(nifv.srcBufId)
  if v == nil or src == nil:
    if v != nil: lineTints.del v.id
    if src != nil: lineTints.del src.id
    nifv = (0, 0, -1, false)
    return
  let cb = buf()
  var hot = -1
  var fromView = false
  if cb.id == src.id: hot = cb.primary.head.line
  elif cb.id == v.id:
    let ns = nifNodesOf(v)
    let i = nifAt(ns, cb.primary.head.line, cb.primary.head.col)
    if i >= 0: hot = ns[i].sline
    fromView = true
  if hot == nifv.hot and fromView == nifv.hotView: return
  nifv.hot = hot
  nifv.hotView = fromView
  let ns = nifNodesOf(v)
  var tv, ts: Table[int, (Rgb, float)]
  if hot >= 0:
    let k = nifForSource(ns, src.path, hot)
    ts[hot] = (theme.accent, 0.22)
    if k >= 0:
      for l in ns[k].line .. min(ns[k].eline, ns[k].line + 400): tv[l] = (theme.accent, (if l == ns[k].line: 0.30 else: 0.12))
      if not fromView: nifReveal(v.id, ns[k].line)
    if fromView: nifReveal(src.id, hot)
  lineTints[v.id] = tv
  lineTints[src.id] = ts
  needRender = true
