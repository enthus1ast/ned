# ════════════════════════════════════════════════════════════════════════════
#  Nim index — ned's own understanding of Nim code, no compiler needed.
#  A tolerant declaration parser (routines, types, fields, enum values, consts, lets, vars, imports, doc
#  comments), import resolution the way the compiler does it, and type-guided lookups for completion,
#  hover, definition, signature help, outline, project symbols and references.
# ════════════════════════════════════════════════════════════════════════════

type
  NxKind* = enum
    nxProc, nxFunc, nxMethod, nxIterator, nxConverter, nxTemplate, nxMacro,
    nxType, nxField, nxEnumVal, nxConst, nxLet, nxVar, nxParam, nxForVar, nxResult, nxModule
  NxParam* = object
    name*, typ*, default*: string
  NxSym* = object
    name*: string
    kind*: NxKind
    exported*: bool
    line*, col*: int            # 0-based position of the name
    endLine*: int              # routines/types: last line of the body
    generics*: string          # "[T: SomeNumber]"
    params*: seq[NxParam]      # routines
    ret*: string               # routines: return type
    typ*: string               # fields/vars/consts/params: type; types: the definition ("object", "enum", …)
    value*: string             # consts/vars/enum values/fields: the value or default as written (short)
    pragmas*: string
    doc*: string
    owner*: string             # fields and enum values: the type they belong to
    slot*, slots*: int16        # loop variables: which one of how many (for k, v in …)
    sub*: int16                # loop variables unpacked from one of them (for i, (a, b) in …): which part, from 1
    made*: bool                # declared by a template call on its line (genVecConstructor(vec, …))
    local*: bool               # declared in a routine's body (a local type, its fields): not the module's own
  NxImport* = object
    spec*: string              # as written: "std/strutils", "../x", "pkg/foo"
    line*: int
    only*: seq[string]         # from x import a, b
    excepts*: seq[string]      # import x except a, b
    alias*: string             # import x as y
    isInclude*: bool
  NxFile* = ref object
    path*: string
    module*: string
    stamp*: string
    doc*: string
    syms*: seq[NxSym]
    imports*: seq[NxImport]
    exports*: seq[string]
    pragmas*: seq[(string, int)]    # {.pragma: name, ….} it defines (name, line)
    byLine*: Table[int, seq[int]]   # line → the declarations on it (built on first use, for nxSymAt)
    byLineN*: int                   # syms.len when byLine was built
    inactive*: seq[(int32, int32)]  # the bodies of `when` branches left out here: (first line, last line)
    symBranch*: seq[int32]          # (nxParse keepInactive) the left-out branches each declaration is in (index into
    inactiveChain*: seq[int32]      #   chains, -1: none), those of each range in `inactive`, and the branches'
    chains*: seq[string]            #   conditions, outermost first, separated by \x01
    scopeKey*: string               # (the file as code in a left-out branch sees it: its scope's own key)
    unionTypes*: Table[string, int] # its types that are unions (`A | B`), private ones too: name → index (made on use)
    unionsMade*: bool

const
  NxOpChars* = {'+', '-', '*', '/', '\\', '<', '>', '!', '?', '^', '.', '|', '=', '%', '&', '$', '@', '~', ':'}
  NxRoutineKw* = ["proc", "func", "method", "iterator", "converter", "template", "macro"]
  NxRoutineKinds* = {nxProc, nxFunc, nxMethod, nxIterator, nxConverter, nxTemplate, nxMacro}

func nxIsIdent*(c: char): bool {.inline.} = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\x80'..'\xFF'}

func nxDotBefore*(t: string, a: int): bool {.inline.} =
  ## a name at `a` that a dot puts after a receiver (x.name), not one after a range's .. (0..len(s))
  a > 0 and t[a - 1] == '.' and not (a > 1 and t[a - 2] == '.')

func nxKindWord*(k: NxKind): string =
  case k
  of nxProc: "proc"
  of nxFunc: "func"
  of nxMethod: "method"
  of nxIterator: "iterator"
  of nxConverter: "converter"
  of nxTemplate: "template"
  of nxMacro: "macro"
  of nxType: "type"
  of nxField: "field"
  of nxEnumVal: "enum"
  of nxConst: "const"
  of nxLet: "let"
  of nxVar: "var"
  of nxParam: "param"
  of nxForVar: "for"
  of nxResult: "result"
  of nxModule: "module"

func nxCollapse*(s: string): string =
  ## one line, single spaces (multi-line headers read like one signature)
  var sp = false
  for c in s:
    if c in {' ', '\t', '\n', '\r'}:
      sp = true
    else:
      if sp and result.len > 0 and result[^1] notin {'(', '['} and c notin {')', ']', ','}: result.add ' '
      sp = false
      result.add c

# ── lexing: comments, strings and brackets on one physical line ──

type NxLexState* = object
  inTriple*: bool          # inside """ … """
  blockDepth*: int         # inside #[ … ]# (nested)
  docBlock*: bool          # the open block comment is a ##[ doc ]## block

proc addRange*(dst: var string, src: string, a, e: int) {.inline.} =
  ## dst & src[a ..< e], without making the slice first
  if e <= a: return
  let o = dst.len
  dst.setLen(o + e - a)
  copyMem(addr dst[o], unsafeAddr src[a], e - a)

func leadWs*(s: string): int {.inline.} =
  ## how much whitespace the line starts with (s.len - s.strip(trailing = false).len, without the copy)
  while result < s.len and s[result] in Whitespace: inc result

proc nxSplitLine*(line: string, st: var NxLexState, code, doc: var string, depth: var int) =
  ## code: the line without comments (strings kept); doc: text of a ## comment or ##[ … ]## part;
  ## depth: () [] {} balance change, ignoring strings and comments
  code.setLen(0)
  doc.setLen(0)
  var i = 0
  let n = line.len
  while i < n:
    if st.inTriple:
      let e = line.find("\"\"\"", i)
      if e < 0:
        code.addRange(line, i, n)
        return
      code.addRange(line, i, e + 3)
      i = e + 3
      while i < n and line[i] == '"':         # """" closes with extra quotes inside the string
        code.add '"'
        inc i
      st.inTriple = false
      continue
    if st.blockDepth > 0:
      if i + 1 < n and line[i] == '#' and line[i+1] == '[':
        inc st.blockDepth
        i += 2
      elif i + 1 < n and line[i] == ']' and line[i+1] == '#':
        dec st.blockDepth
        i += 2
        if st.blockDepth == 0 and st.docBlock:
          st.docBlock = false
          if i < n and line[i] == '#': inc i   # ]##
      else:
        if st.docBlock: doc.add line[i]
        inc i
      continue
    let c = line[i]
    case c
    of '#':
      if i + 2 < n and line[i+1] == '#' and line[i+2] == '[':
        st.blockDepth = 1
        st.docBlock = true
        i += 3
      elif i + 1 < n and line[i+1] == '[':
        st.blockDepth = 1
        st.docBlock = false
        i += 2
      elif i + 1 < n and line[i+1] == '#':
        var d = line[i + 2 .. ^1]
        if d.len > 0 and d[0] == ' ': d = d[1 .. ^1]
        doc = d
        return
      else: return
    of '"':
      if i + 2 < n and line[i+1] == '"' and line[i+2] == '"':
        let e = line.find("\"\"\"", i + 3)
        if e < 0:
          code.addRange(line, i, n)
          st.inTriple = true
          return
        var e2 = e + 3
        while e2 < n and line[e2] == '"': inc e2
        code.addRange(line, i, e2)
        i = e2
      else:
        let raw = i > 0 and line[i-1] in {'r', 'R'} and (i < 2 or not nxIsIdent(line[i-2]))
        var j = i + 1
        while j < n:
          if line[j] == '\\' and not raw: j += 2
          elif line[j] == '"':
            if raw and j + 1 < n and line[j+1] == '"': j += 2
            else: break
          else: inc j
        code.addRange(line, i, min(j, n - 1) + 1)
        i = j + 1
    of '\'':
      # a char literal ('a', '\n', '\'') — not a quote in an identifier like  x'u8
      if i > 0 and nxIsIdent(line[i-1]):
        code.add c
        inc i
      else:
        var j = i + 1
        if j < n and line[j] == '\\': j += 2 else: j += 1
        while j < n and line[j] != '\'' and j - i < 12: inc j
        code.addRange(line, i, min(j, n - 1) + 1)
        i = j + 1
    of '(', '[', '{':
      inc depth
      code.add c
      inc i
    of ')', ']', '}':
      dec depth
      code.add c
      inc i
    of '`':
      let e = line.find('`', i + 1)
      if e < 0:
        code.addRange(line, i, n)
        return
      code.addRange(line, i, e + 1)
      i = e + 1
    else:
      # a run of ordinary characters, copied at once
      var j = i + 1
      while j < n and line[j] notin {'#', '"', '\'', '(', ')', '[', ']', '{', '}', '`'}: inc j
      code.addRange(line, i, j)
      i = j
