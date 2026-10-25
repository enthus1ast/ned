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
        v = v * 62 + b62(s[c])
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
