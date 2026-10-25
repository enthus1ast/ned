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
  if c <= '9': ord(c) - ord('0')
  elif c <= 'Z': ord(c) - ord('A') + 10
  else: ord(c) - ord('a') + 36

const B62 = {'0'..'9', 'A'..'Z', 'a'..'z'}

proc nifParse*(lines: openArray[string]): seq[NifNode] =
  ## every node and atom of a NIF text, in order
  var stack: seq[int]
  var l = 0
  var c = 0
  proc info(lines: openArray[string], l: int, c: var int, n: var NifNode, parent: NifNode, hasParent: bool) =
    ## the line information after a tag or an atom: `@col,line,file` (base 62, `~` negative; without a file,
    ## relative to the parent's place)
    let s = lines[l]
    if c >= s.len or s[c] notin {'@', '~'}:
      if hasParent: (n.file, n.sline, n.scol) = (parent.file, parent.sline, parent.scol)
      else: (n.sline, n.scol) = (-1, -1)
      return
    if s[c] == '@': inc c
    var nums = [0, 0]
    var given = [false, false]
    for k in 0 .. 1:
      var neg = false
      if c < s.len and s[c] == '~':
        neg = true
        inc c
      var v = 0
      while c < s.len and s[c] in B62:
        # (a word that is no number — not NIF, or cut — stays a big one, not an overflow)
        if v < 1_000_000_000: v = v * 62 + b62(s[c])
        given[k] = true
        inc c
      nums[k] = if neg: -v else: v
      if k == 0 and c < s.len and s[c] == ',': inc c
      elif k == 0: break
    var file = ""
    if c < s.len and s[c] == ',':
      inc c
      let a = c
      while c < s.len and s[c] notin {' ', '\t', '(', ')', '[', ']', '"', '\'', '#'}: inc c
      file = s[a ..< c]
    if file.len > 0:
      (n.file, n.sline, n.scol) = (file, nums[1] - 1, nums[0])     # (a file of its own: where in it, from line 1)
    elif hasParent and parent.sline >= 0:
      (n.file, n.sline, n.scol) = (parent.file, parent.sline + nums[1], parent.scol + nums[0])
    else:
      (n.sline, n.scol) = (nums[1] - 1, nums[0])
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
      info(lines, l, c, n, parentN, parentI >= 0)
      result.add n
      stack.add result.high
    of ')':
      if stack.len > 0:
        let i = stack.pop()
        result[i].eline = l
        result[i].ecol = c + 1
      inc c
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
      n.atom = s[n.col + (if n.isDef: 1 else: 0) ..< min(c, s.len)]
      n.eline = l
      n.ecol = min(c, s.len)
      info(lines, l, c, n, parentN, parentI >= 0)
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
