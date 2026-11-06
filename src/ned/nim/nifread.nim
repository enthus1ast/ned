## ── NIF, Nim 3's (Nimony's) code between its passes: read as nodes — each tag, atom and definition with where it
##    is in the NIF text and where it comes from in the Nim source (its line information, relative to its
##    parent's, made absolute) — for ned's NIF view, its outline, its hover and F12 to the source ──

import std/[strutils, tables]

type
  NifNode* = object
    tag*: string               # a node's tag (`proc`, `.nif27`); "" for an atom
    atom*: string              # an atom's text: a symbol, a number, "a string", 'c', `.`
    isDef*: bool               # `:name` — what declares a symbol
    line*, col*: int           # where it starts in the NIF text (from 0)
    eline*, ecol*: int         # where it ends there (a node: its `)`)
    file*: string              # the source file it comes from, as the NIF names it ("" not said)
    sline*, scol*: int         # where in that file (from 0; -1: no line information)
    depth*: int
    parent*: int               # (-1: the top)

func b62(c: char): int =
  ## the value of one base-62 digit (0-9, A-Z, a-z) used by NIF's line information
  if c <= '9': ord(c) - ord('0')
  elif c <= 'Z': ord(c) - ord('A') + 10
  else: ord(c) - ord('a') + 36

const B62 = {'0'..'9', 'A'..'Z', 'a'..'z'}

type NifInfo = object                  # one `@col,line,file` as written: not yet made absolute
  has: bool
  nums: array[2, int]
  file: string

proc nifReadInfo(s: string, c: var int): NifInfo =
  ## the line information at `c` (`@col,line,file`, base 62, `~` negative), read past — `has` false when there is none
  if c >= s.len or s[c] notin {'@', '~'}: return
  result.has = true
  if s[c] == '@': inc c
  for k in 0 .. 1:
    var neg = false
    if c < s.len and s[c] == '~':
      neg = true
      inc c
    var v = 0
    while c < s.len and s[c] in B62:
      # (a word that is no number — not NIF, or cut — stays a big one, not an overflow)
      if v < 1_000_000_000: v = v * 62 + b62(s[c])
      inc c
    result.nums[k] = if neg: -v else: v
    if k == 0 and c < s.len and s[c] == ',': inc c
    elif k == 0: break
  if c < s.len and s[c] == ',':
    inc c
    let a = c
    while c < s.len and s[c] notin {' ', '\t', '(', ')', '[', ']', '"', '\'', '#'}: inc c
    result.file = s[a ..< c]

proc nifPlace(n: var NifNode, r: NifInfo, parent: NifNode, hasParent: bool) =
  ## where a node comes from in the source: its own line information (with a file: where in it, from line 1;
  ## without: relative to its parent's place), or its parent's place when it has none
  if not r.has:
    if hasParent: (n.file, n.sline, n.scol) = (parent.file, parent.sline, parent.scol)
    else: (n.sline, n.scol) = (-1, -1)
  elif r.file.len > 0: (n.file, n.sline, n.scol) = (r.file, r.nums[1] - 1, r.nums[0])
  elif hasParent and parent.sline >= 0:
    (n.file, n.sline, n.scol) = (parent.file, parent.sline + r.nums[1], parent.scol + r.nums[0])
  else: (n.sline, n.scol) = (r.nums[1] - 1, r.nums[0])

proc nifParse*(lines: openArray[string], before = false): seq[NifNode] =
  ## every node and atom of a NIF text, in order. Nimony writes a token's line information right after it; Nim 2.4's
  ## `nim nif` writes it after the token before (after a `)` too) — `before` reads it that way
  var stack: seq[int]
  var l = 0
  var c = 0
  var pending: NifInfo                 # (before: what the next token's place is)
  while l < lines.len:
    let s = lines[l]
    if c >= s.len:
      inc l
      c = 0
      continue
    let ch = s[c]
    let parentI = if stack.len > 0: stack[^1] else: -1
    let parentN = if parentI >= 0: result[parentI] else: NifNode()
    case ch
    of ' ', '\t', '\r':
      inc c
    of '#':
      # a comment: up to the next #
      inc c
      while true:
        if l >= lines.len: break
        let k = lines[l].find('#', c)
        if k >= 0:
          c = k + 1
          break
        inc l
        c = 0
    of '(':
      var n = NifNode(line: l, col: c, depth: stack.len, parent: parentI)
      inc c
      let a = c
      while c < s.len and s[c] notin {' ', '\t', '(', ')', '@', '~', '#', '"', '\''}: inc c
      n.tag = s[a ..< c]
      let r = nifReadInfo(s, c)
      if before:
        nifPlace(n, pending, parentN, parentI >= 0)
        pending = r
      else: nifPlace(n, r, parentN, parentI >= 0)
      result.add n
      stack.add result.high
    of ')':
      if stack.len > 0:
        let i = stack.pop()
        result[i].eline = l
        result[i].ecol = c + 1
      inc c
      let r = nifReadInfo(s, c)          # (Nim 2.4's: the next token's place)
      if before: pending = r
    else:
      var n = NifNode(line: l, col: c, depth: stack.len, parent: parentI)
      if ch == '"' or ch == '\'':
        inc c
        while c < s.len and s[c] != ch: inc c
        inc c
      else:
        if ch == ':':
          n.isDef = true
          inc c
        while c < s.len and s[c] notin {' ', '\t', '(', ')', '@', '~', '#', '"'}: inc c
        if c == n.col:
          inc c                            # (a character no token starts with: passed over)
          continue
      n.atom = s[n.col + (if n.isDef: 1 else: 0) ..< min(c, s.len)]
      n.eline = l
      n.ecol = min(c, s.len)
      let r = nifReadInfo(s, c)
      if before:
        nifPlace(n, pending, parentN, parentI >= 0)
        pending = r
      else: nifPlace(n, r, parentN, parentI >= 0)
      result.add n
  for i in 0 ..< result.len:
    if result[i].tag.len > 0 and result[i].eline < result[i].line:
      result[i].eline = lines.high                           # (never closed)
      result[i].ecol = if lines.len > 0: lines[^1].len else: 0

func nifSymName*(atom: string): string =
  ## a symbol's name as written in Nim: `SortOrder.0.sysvq0asl` → SortOrder, `` dollar`.SortOrder.0. `` → `$`
  var n = atom
  let k = n.find('.')
  if k > 0: n = n[0 ..< k]
  case n
  of "dollar`": "$"
  else: n

proc nifAt*(nodes: seq[NifNode], line, col: int): int =
  ## the innermost node or atom at a place of the NIF text (-1 none)
  result = -1
  for i, n in nodes:
    let after = line > n.line or (line == n.line and col >= n.col)
    let before = line < n.eline or (line == n.eline and col < n.ecol)
    if after and before:
      if result < 0 or n.depth >= nodes[result].depth: result = i

proc nifForSource*(nodes: seq[NifNode], fileEnd: string, line: int): int =
  ## the first node from a source line (the one a file's path ends with) — the shallowest of them, -1 none
  result = -1
  for i, n in nodes:
    if n.sline == line and n.tag.len > 0 and (fileEnd.len == 0 or n.file.len == 0 or
       fileEnd.endsWith(n.file) or n.file.endsWith(fileEnd)):
      if result < 0 or n.depth < nodes[result].depth: result = i

type NifOutline* = object
  name*, tag*: string
  line*, col*, depth*: int

const NifDeclTags = ["proc", "func", "method", "iterator", "converter", "template", "macro", "type", "const", "let",
                     "var", "gvar", "tvar", "glet", "tlet", "gconst"]

proc nifOutline*(nodes: seq[NifNode]): seq[NifOutline] =
  ## the declarations: the routines, types, constants and globals of the top statements, and the fields and
  ## enum values of the types
  for i, n in nodes:
    if n.tag.len == 0 or n.depth > 4: continue
    let top = n.parent >= 0 and nodes[n.parent].tag == "stmts" and nodes[n.parent].depth == 0
    if not ((top and n.tag in NifDeclTags) or n.tag in ["efld", "fld"]): continue
    # (its name: the first `:sym` right inside it)
    for j in i + 1 ..< min(nodes.len, i + 4):
      if nodes[j].parent == i and nodes[j].isDef:
        result.add NifOutline(name: nifSymName(nodes[j].atom), tag: n.tag, line: n.line, col: n.col,
                              depth: (if top: 0 else: 1))
        break
      if nodes[j].parent == i and nodes[j].tag.len > 0: break

proc nifTagTable*(md: string): Table[string, (string, string)] =
  ## Nimony's doc/tags.md as tag → (its forms, what it is)
  for raw in md.splitLines:
    let s = raw.strip
    if not s.startsWith("| `("): continue
    let cells = s.strip(chars = {'|', ' '}).split(" | ")
    if cells.len < 2: continue
    let forms = cells[0].strip
    var k = forms.find("`(")
    if k < 0: continue
    var e = k + 2
    while e < forms.len and forms[e] notin {' ', ')', '`'}: inc e
    let tag = forms[k + 2 ..< e]
    let desc = if cells.len >= 3: cells[2].strip(chars = {' ', '|'}) else: ""
    if tag.len > 0 and tag notin result: result[tag] = (forms.replace("`", ""), desc)

# ── pnak.nif: Nimony's package lockfile — (stmts (requires "<git url>" "<commit>") …) ──

type PnakReq* = object
  url*, commit*, name*: string
  tline*, tcol*: int                   ## where its (requires starts
  line*, col*, ecol*: int              ## the URL's string
  cline*, ccol*, cecol*: int           ## the commit's string (-1: none)

func pnakName*(url: string): string =
  ## a package's name from its URL: https://github.com/a/foo.git → foo (a bare name stays as it is)
  var u = url.strip
  let h = u.find('#')
  if h >= 0: u = u[0 ..< h]
  while u.endsWith("/"): u.setLen(u.len - 1)
  if u.endsWith(".git"): u.setLen(u.len - 4)
  let k = max(u.rfind('/'), u.rfind(':'))
  if k >= 0: u[k + 1 .. ^1] else: u

func pnakIsCommit*(s: string): bool =
  ## a commit's hash (7 to 40 hex digits) — not a branch or a tag, which can move
  s.len >= 7 and s.len <= 40 and s.allCharsInSet({'0'..'9', 'a'..'f', 'A'..'F'})

func pnakRequires*(lines: openArray[string]): seq[PnakReq] =
  ## the lockfile's entries, where they are (a (requires …) may go over several lines)
  var inReq = false
  var cur: PnakReq
  var strs = 0
  for ln, s in lines:
    var i = 0
    while i < s.len:
      let c = s[i]
      if c == '"':
        # (NIF's strings: \ and two hex digits for a character it escapes)
        var e = i + 1
        var v = ""
        while e < s.len and s[e] != '"':
          if s[e] == '\\' and e + 2 < s.len and s[e + 1] in HexDigits and s[e + 2] in HexDigits:
            v.add chr(parseHexInt(s[e + 1 .. e + 2]))
            e += 3
          else:
            v.add s[e]
            inc e
        if inReq:
          if strs == 0:
            cur.url = v
            (cur.line, cur.col, cur.ecol) = (ln, i, min(e + 1, s.len))
          elif strs == 1:
            cur.commit = v
            (cur.cline, cur.ccol, cur.cecol) = (ln, i, min(e + 1, s.len))
          inc strs
        i = e + 1
        continue
      if c == '(':
        var e = i + 1
        while e < s.len and s[e] in {'a'..'z', 'A'..'Z', '0'..'9', '.', '_'}: inc e
        if s[i + 1 ..< e] == "requires":
          inReq = true
          strs = 0
          cur = PnakReq(tline: ln, tcol: i, line: ln, col: i, ecol: e, cline: -1, ccol: -1, cecol: -1)
        i = e
        continue
      if c == ')' and inReq:
        inReq = false
        if cur.url.len > 0:
          cur.name = pnakName(cur.url)
          result.add cur
      inc i

# ── the NIF written back as Nim: what a macro made (the editor shows it under the call) ──

proc nifTypeText*(ns: seq[NifNode], i: int, nimony: bool): string =
  ## a type of the NIF as Nim writes it (`seq[string]`, `Table[string, int]`, `ref Node`) — "" for a form not known here
  if i < 0 or i >= ns.len: return ""
  let n = ns[i]
  if n.tag.len == 0:
    let nm = nifSymName(n.atom)
    if nm.len == 0 or nm[0] notin IdentStartChars or '`' in n.atom or '.' notin n.atom: return ""
    return nm
  var kids: seq[int]
  for j in i + 1 ..< min(ns.len, i + 4000):
    if ns[j].depth <= n.depth: break
    if ns[j].parent == i: kids.add j
  template num(k: int): int =
    ## the k-th part as a number (-2 when it is not one)
    (try: parseInt(ns[kids[k]].atom) except ValueError: -2)
  case n.tag
  of "i", "u":
    if kids.len != 1: return ""
    let bits = num(0)
    let base = if n.tag == "i": "int" else: "uint"
    if bits == -1 or (nimony and bits == 64): base elif bits in [8, 16, 32, 64]: base & $bits else: ""
  of "f":
    if kids.len != 1: return ""
    let bits = num(0)
    if bits == 64 or bits == -1: "float" elif bits == 32: "float32" else: ""
  of "c": (if kids.len == 1 and num(0) == 8: "char" else: "")
  of "bool": "bool"
  of "ref", "ptr":
    if kids.len != 1: return ""
    let t = nifTypeText(ns, kids[0], nimony)
    if t.len > 0: n.tag & " " & t else: ""
  of "at":
    if kids.len < 2: return ""
    var head = kids[0]
    if ns[head].tag == "gbody":
      # (a generic's body: its name is its last part)
      var last = -1
      for j in head + 1 ..< ns.len:
        if ns[j].depth <= ns[head].depth: break
        if ns[j].parent == head: last = j
      head = last
    let h = nifTypeText(ns, head, nimony)
    if h.len == 0: return ""
    var args: seq[string]
    for k in kids[1 .. ^1]:
      let a = nifTypeText(ns, k, nimony)
      if a.len == 0: return ""
      args.add a
    h & "[" & args.join(", ") & "]"
  of "array":
    if kids.len != 2 or ns[kids[1]].tag != "range": return ""
    let el = nifTypeText(ns, kids[0], nimony)
    var bounds: seq[string]
    for j in kids[1] + 1 ..< ns.len:
      if ns[j].depth <= ns[kids[1]].depth: break
      if ns[j].parent == kids[1] and ns[j].tag.len == 0: bounds.add ns[j].atom
    if el.len == 0 or bounds.len != 2: return ""
    # (from 0: by its length, as it is written — and as ned's own engine shows it)
    if bounds[0] in ["0", "+0"]:
      try: return "array[" & $(parseInt(bounds[1].strip(trailing = false, chars = {'+'})) + 1) & ", " & el & "]"
      except ValueError: discard
    "array[" & bounds[0] & ".." & bounds[1] & ", " & el & "]"
  else: ""

type NifPrinter = object
  ns: seq[NifNode]
  nimony: bool
  ok: bool                       # (false: a form this printer does not write was met)

proc pKids(p: NifPrinter, i: int): seq[int] =
  ## the children of node i, in order
  if i < 0 or i >= p.ns.len or p.ns[i].tag.len == 0: return
  for j in i + 1 ..< p.ns.len:
    if p.ns[j].depth <= p.ns[i].depth: break
    if p.ns[j].parent == i: result.add j

func nifUnescape(s: string): string =
  ## a NIF symbol's or string's text: `\XX` (two hex digits) is the character it stands for
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 2 < s.len and s[i + 1] in HexDigits and s[i + 2] in HexDigits:
      result.add chr(parseHexInt(s[i + 1 .. i + 2]))
      i += 3
    else:
      result.add s[i]
      inc i

func nimStrLit(s: string): string =
  ## a Nim string literal for the text: quotes, backslashes and control characters escaped
  result = "\""
  for c in s:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    elif c < ' ': result.add "\\x" & toHex(ord(c), 2)
    else: result.add c
  result.add '"'

func isOpName(s: string): bool =
  ## whether a name is an operator (written between or before its operands)
  s.len > 0 and s[0] notin IdentStartChars and s[0] != '`' or s in ["and", "or", "not", "xor", "shl", "shr", "div",
                                                                    "mod", "in", "notin", "is", "isnot", "of"]

proc pSym(p: NifPrinter, i: int): string =
  ## an atom as Nim writes it: a symbol's name (`name.N.module`, a local `name.N`; an operator unescaped, a gensym's
  ## without its `gensym…`), a literal as it is, `.` as nothing
  let a = p.ns[i].atom
  if a.len == 0 or a == ".": return ""
  if a[0] == '"': return nimStrLit(nifUnescape(a[1 ..< a.len - 1]))
  if a[0] == '\'': return "'" & (if a.len == 3: $a[1] else: nifUnescape(a[1 ..< a.len - 1]).escape("", "")) & "'"
  if a[0] in {'0'..'9', '-', '+'}: return a
  var name = a
  if a.count('.') >= 2: name = a.rsplit('.', maxsplit = 2)[0]
  elif a.count('.') == 1: name = a.rsplit('.', maxsplit = 1)[0]
  name = nifUnescape(name)
  let g = name.find("`gensym")
  if g > 0: name = name[0 ..< g]
  name

proc pExpr(p: var NifPrinter, i: int): string
proc pStmt(p: var NifPrinter, i: int, ind: int): string

proc pTyp(p: var NifPrinter, i: int): string =
  ## a type as Nim writes it — the forms nifTypeText knows, a symbol, `ref`/`ptr`/`var`, `distinct`, a tuple
  if i < 0: return ""
  let n = p.ns[i]
  if n.tag.len == 0: return p.pSym(i)
  let t = nifTypeText(p.ns, i, p.nimony)
  if t.len > 0: return t
  let ks = p.pKids(i)
  case n.tag
  of "ref", "ptr", "var", "distinct", "sink", "lent", "out":
    if ks.len != 1: p.ok = false
    else: result = n.tag & " " & p.pTyp(ks[0])
  of "tuple":
    var fs: seq[string]
    for k in ks:
      let fk = p.pKids(k)
      if p.ns[k].tag != "fld" or fk.len < 4: p.ok = false; return
      fs.add p.pSym(fk[0]) & ": " & p.pTyp(fk[3])
    result = "tuple[" & fs.join(", ") & "]"
  of "at":
    var parts: seq[string]
    for k in ks: parts.add p.pTyp(k)
    if parts.len > 0: result = parts[0] & "[" & parts[1 .. ^1].join(", ") & "]"
  else: p.ok = false

proc pArgs(p: var NifPrinter, ks: seq[int], start: int): string =
  ## the arguments of a call, a field's `name: value` as it is
  var xs: seq[string]
  for k in ks[start .. ^1]:
    if p.ns[k].tag == "kv":
      let kk = p.pKids(k)
      if kk.len == 2: xs.add p.pExpr(kk[0]) & " = " & p.pExpr(kk[1])
      else: p.ok = false
    else: xs.add p.pExpr(k)
  xs.join(", ")

proc pExpr(p: var NifPrinter, i: int): string =
  ## an expression as Nim writes it; the compiler's hidden conversions left out
  if not p.ok or i < 0: return ""
  let n = p.ns[i]
  if n.tag.len == 0: return p.pSym(i)
  let ks = p.pKids(i)
  case n.tag
  of "call", "cmd", "infix", "prefix", "callstrlit":
    if ks.len == 0: p.ok = false; return
    var callee = p.pExpr(ks[0])
    if p.ns[ks[0]].tag == "at":
      # (a generic routine's instance: its name, the types are the compiler's choice)
      let ck = p.pKids(ks[0])
      if ck.len > 0: callee = p.pExpr(ck[0])
    if n.tag == "callstrlit" and ks.len == 2: return callee & p.pExpr(ks[1])
    if callee == "[]" and ks.len >= 2: return p.pExpr(ks[1]) & "[" & p.pArgs(ks, 2) & "]"
    if callee == "[]=" and ks.len >= 3: return p.pExpr(ks[1]) & "[" & p.pArgs(ks[0 .. ^2], 2) & "] = " & p.pExpr(ks[^1])
    proc operand(p: var NifPrinter, k: int): string =
      ## an operand, in brackets when it is itself an operator's call (the NIF has no brackets of its own)
      result = p.pExpr(k)
      if p.ns[k].tag in ["call", "infix", "prefix"]:
        let kk = p.pKids(k)
        if kk.len >= 2 and isOpName(p.pExpr(kk[0])): result = "(" & result & ")"
    if isOpName(callee) and ks.len == 3: return operand(p, ks[1]) & " " & callee & " " & operand(p, ks[2])
    if isOpName(callee) and ks.len == 2: return callee & operand(p, ks[1])
    result = callee & "(" & p.pArgs(ks, 1) & ")"
  of "dot":
    if ks.len < 2: p.ok = false; return
    result = p.pExpr(ks[0]) & "." & p.pExpr(ks[1])
  of "at":
    if ks.len < 2: p.ok = false; return
    result = p.pExpr(ks[0]) & "[" & p.pArgs(ks, 1) & "]"
  of "conv", "hconv", "hiddencallconv", "hstdconv", "hderef", "haddr":
    # (what the compiler put in: the value it converts)
    if ks.len == 0: p.ok = false; return
    result = p.pExpr(ks[^1])
  of "deref": result = (if ks.len == 1: p.pExpr(ks[0]) & "[]" else: "")
  of "addr": result = (if ks.len == 1: "addr " & p.pExpr(ks[0]) else: "")
  of "nil": result = "nil"
  of "par": result = (if ks.len == 1: "(" & p.pExpr(ks[0]) & ")" else: "")
  of "suf":
    if ks.len != 2: p.ok = false; return
    let lit = p.pExpr(ks[0])
    let s = p.ns[ks[1]].atom.strip(chars = {'"'})
    result = if s == "R": "r" & lit else: lit & "'" & s
  of "oconstr":
    if ks.len == 0: p.ok = false; return
    var fs: seq[string]
    for k in ks[1 .. ^1]:
      let kk = p.pKids(k)
      if p.ns[k].tag != "kv" or kk.len != 2: p.ok = false; return
      fs.add p.pExpr(kk[0]) & ": " & p.pExpr(kk[1])
    result = p.pTyp(ks[0]) & "(" & fs.join(", ") & ")"
  of "aconstr":
    var xs: seq[string]
    for k in ks[1 .. ^1]: xs.add p.pExpr(k)
    result = "[" & xs.join(", ") & "]"
  of "tupconstr":
    var xs: seq[string]
    for k in ks[1 .. ^1]: xs.add p.pExpr(k)
    result = "(" & xs.join(", ") & (if xs.len == 1: ",)" else: ")")
  of "expr":
    # (statements then a value: written only when there are no statements)
    if ks.len == 0: p.ok = false; return
    for k in ks[0 ..< ks.len - 1]:
      if p.ns[k].tag != "stmts" or p.pKids(k).len > 0: p.ok = false; return
    result = p.pExpr(ks[^1])
  else: p.ok = false
  if not p.ok: result = ""

proc pPragmas(p: var NifPrinter, i: int): string =
  ## `{.a, b: c.}` from a (pragmas …) node, "" for none
  if i < 0 or p.ns[i].tag != "pragmas": return ""
  var xs: seq[string]
  for k in p.pKids(i):
    if p.ns[k].tag == "kv":
      let kk = p.pKids(k)
      if kk.len == 2: xs.add p.pExpr(kk[0]) & ": " & p.pExpr(kk[1])
    else: xs.add p.pExpr(k)
  if xs.len > 0: " {." & xs.join(", ") & ".}" else: ""

proc pBody(p: var NifPrinter, i: int, ind: int, resultSym: var string): string =
  ## a routine's statements, one a line: its `result` declaration and the closing `return result` left out
  for k in p.pKids(i):
    let t = p.ns[k].tag
    if t == "result":
      let rk = p.pKids(k)
      if rk.len > 0: resultSym = p.ns[rk[0]].atom
      continue
    if t == "ret":
      let rk = p.pKids(k)
      if rk.len == 1 and p.ns[rk[0]].tag.len == 0 and p.ns[rk[0]].atom == resultSym: continue
    let s = p.pStmt(k, ind)
    if s.len > 0: result.add s & "\n"

proc pRoutine(p: var NifPrinter, i: int, ind: int): string =
  ## proc, func, iterator, template, macro, method, converter: `proc name*[T](a: int): R {.p.} =` and its body
  let ks = p.pKids(i)
  if ks.len < 9: p.ok = false; return
  let sp = spaces(ind)
  result = sp & p.ns[i].tag & " " & p.pSym(ks[0]) & (if p.ns[ks[1]].atom == "x": "*" else: "")
  if p.ns[ks[3]].tag == "typevars":
    var tv: seq[string]
    for k in p.pKids(ks[3]):
      let kk = p.pKids(k)
      if kk.len > 0: tv.add p.pSym(kk[0])
    result.add "[" & tv.join(", ") & "]"
  var ps: seq[string]
  for k in p.pKids(ks[4]):
    let pk = p.pKids(k)
    if p.ns[k].tag != "param" or pk.len < 4: p.ok = false; return
    var one = p.pSym(pk[0]) & ": " & p.pTyp(pk[3])
    if pk.len > 4 and p.ns[pk[4]].atom != ".": one.add " = " & p.pExpr(pk[4])
    ps.add one
  result.add "(" & ps.join(", ") & ")"
  let r = p.pTyp(ks[5])
  if r.len > 0 and r != "void": result.add ": " & r
  result.add p.pPragmas(ks[6])
  if p.ns[ks[8]].tag == "stmts":
    var resSym = ""
    let bd = p.pBody(ks[8], ind + 2, resSym)
    result.add " =\n" & (if bd.len > 0: bd.strip(leading = false) else: spaces(ind + 2) & "discard")
  elif p.ns[ks[8]].atom == ".": discard
  else: p.ok = false

proc pStmt(p: var NifPrinter, i: int, ind: int): string =
  ## one statement as Nim writes it, indented
  if not p.ok or i < 0: return ""
  let n = p.ns[i]
  let sp = spaces(ind)
  let ks = p.pKids(i)
  case n.tag
  of "stmts":
    var ls: seq[string]
    for k in ks:
      let s = p.pStmt(k, ind)
      if s.len > 0: ls.add s
    result = ls.join("\n")
  of "proc", "func", "iterator", "template", "macro", "method", "converter": result = p.pRoutine(i, ind)
  of "asgn":
    if ks.len != 2: p.ok = false; return
    result = sp & p.pExpr(ks[0]) & " = " & p.pExpr(ks[1])
  of "let", "var", "const", "glet", "gvar", "tvar", "tlet", "gconst":
    if ks.len < 5: p.ok = false; return
    let kw = if n.tag in ["const", "gconst"]: "const" elif n.tag in ["let", "glet", "tlet"]: "let" else: "var"
    result = sp & kw & " " & p.pSym(ks[0]) & (if p.ns[ks[1]].atom == "x": "*" else: "")
    let t = p.pTyp(ks[3])
    if t.len > 0: result.add ": " & t
    if p.ns[ks[4]].atom != ".": result.add " = " & p.pExpr(ks[4])
  of "ret":
    result = sp & "return" & (if ks.len == 1 and p.ns[ks[0]].atom != ".": " " & p.pExpr(ks[0]) else: "")
  of "discard":
    result = sp & "discard" & (if ks.len == 1 and p.ns[ks[0]].atom != ".": " " & p.pExpr(ks[0]) else: "")
  of "raise": result = sp & "raise " & (if ks.len == 1: p.pExpr(ks[0]) else: "")
  of "break": result = sp & "break"
  of "continue": result = sp & "continue"
  of "yld": result = sp & "yield " & (if ks.len == 1: p.pExpr(ks[0]) else: "")
  of "call", "cmd", "infix", "prefix": result = sp & p.pExpr(i)
  of "if":
    var first = true
    for k in ks:
      let bk = p.pKids(k)
      if p.ns[k].tag == "elif" and bk.len == 2:
        result.add (if first: sp & "if " else: "\n" & sp & "elif ") & p.pExpr(bk[0]) & ":\n" & p.pStmt(bk[1], ind + 2)
        first = false
      elif p.ns[k].tag == "else" and bk.len == 1:
        result.add "\n" & sp & "else:\n" & p.pStmt(bk[0], ind + 2)
      else: p.ok = false
  of "while":
    if ks.len != 2: p.ok = false; return
    result = sp & "while " & p.pExpr(ks[0]) & ":\n" & p.pStmt(ks[1], ind + 2)
  of "block":
    if ks.len != 2: p.ok = false; return
    let lbl = p.pSym(ks[0])
    result = sp & "block" & (if lbl.len > 0: " " & lbl else: "") & ":\n" & p.pStmt(ks[1], ind + 2)
  of "type":
    if ks.len < 5: p.ok = false; return
    result = sp & "type " & p.pSym(ks[0]) & (if p.ns[ks[1]].atom == "x": "*" else: "") & " = "
    let body = ks[4]
    case p.ns[body].tag
    of "object":
      result.add "object"
      for f in p.pKids(body):
        let fk = p.pKids(f)
        if p.ns[f].tag != "fld" or fk.len < 4: continue
        result.add "\n" & spaces(ind + 2) & p.pSym(fk[0]) & (if p.ns[fk[1]].atom == "x": "*" else: "") & ": " &
                   p.pTyp(fk[3])
    of "enum":
      var vs: seq[string]
      for f in p.pKids(body):
        let fk = p.pKids(f)
        if p.ns[f].tag == "efld" and fk.len > 0: vs.add p.pSym(fk[0])
      result.add "enum " & vs.join(", ")
    else: result.add p.pTyp(body)
  of "comment": result = ""
  else: p.ok = false
  if not p.ok: result = ""

proc nifPrint*(ns: seq[NifNode], i: int, nimony: bool): string =
  ## node i of a NIF as Nim (its statements, one a line) — "" when it holds a form not written here
  var p = NifPrinter(ns: ns, nimony: nimony, ok: true)
  result = p.pStmt(i, 0)
  if not p.ok: result = ""


proc nifTopStatements*(ns: seq[NifNode]): seq[int] =
  ## the module's own statements: the children of its first `(stmts`, in order
  var root = -1
  for i, n in ns:
    if n.tag == "stmts" and n.depth == 0:
      root = i
      break
  if root < 0: return
  for j in root + 1 ..< ns.len:
    if ns[j].depth == 0: break
    if ns[j].parent == root: result.add j

