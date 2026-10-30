# ════════════════════════════════════════════════════════════════════════════
#  The C formatter's style: as written ("keep", ned's own way since 5.13), one of clang-format's presets
#  (LLVM, Google, Chromium, Mozilla, WebKit, Microsoft, GNU) or the Linux kernel's, a project's .clang-format
#  (its keys ned knows), and clang-format's keys given as settings (c.format.options).
# ════════════════════════════════════════════════════════════════════════════

type
  CStyle* = object
    name*: string               # what it came from: "keep", "LLVM", ".clang-format" …
    indent*: int                # IndentWidth
    useTab*: bool               # UseTab (the indentation in tabs of tabWidth)
    tabWidth*: int
    colLimit*: int              # ColumnLimit — 0: your line breaks kept (lines are not joined nor wrapped)
    contIndent*: int            # ContinuationIndentWidth
    alignAfterParen*: bool      # AlignAfterOpenBracket: Align — a wrapped argument list under its first argument
    braceFunc*, braceCtl*, braceType*: int   # where a `{` goes: 0 as written · 1 at the end of the line · 2 on a
                                             # line of its own (a function's, an if/for/while's, a struct's)
    elseLine*: int              # 0 as written · 1 `} else {` · 2 `}` ⏎ `else`
    pointer*: int               # 0 as written · 1 `int *p` (Right) · 2 `int* p` (Left) · 3 `int * p` (Middle)
    parens*: int                # space before `(`: 0 as written · 1 after if/for/while/switch only
                                # (ControlStatements) · 2 never · 3 always
    caseIndent*: bool           # IndentCaseLabels: `case` one level inside its switch
    commentSpaces*: int         # spaces before a trailing comment (SpacesBeforeTrailingComments) — 0: as written
    alignComments*: bool        # AlignTrailingComments: those of lines that follow each other at one column
    alignMacros*: bool          # AlignConsecutiveMacros: the values of #defines that follow each other
    alignAssign*: bool          # AlignConsecutiveAssignments: the `=` of assignments that follow each other
    alignDecls*: bool           # AlignConsecutiveDeclarations: the names of declarations that follow each other
    shortBlocks*: bool          # AllowShortBlocksOnASingleLine: `if (a) { b; }` may stay on one line
    shortIfs*: bool             # AllowShortIfStatementsOnASingleLine: `if (a) return;`
    shortLoops*: bool           # AllowShortLoopsOnASingleLine: `while (a) a--;`
    shortFuncs*: int            # AllowShortFunctionsOnASingleLine: 0 none · 1 empty · 2 all (when it fits)
    shortCase*: bool            # AllowShortCaseLabelsOnASingleLine: `case 1: return a;`
    oneStatement*: bool         # one statement a line (`a; b;` split) — every preset, not "keep"
    spaceInBraces*: int         # a braced list `{1, 2}`: 0 as written · 1 `{1, 2}` · 2 `{ 1, 2 }`
    castSpace*: int             # after a cast `(int)x`: 0 as written · 1 none · 2 one
    maxBlank*: int              # MaxEmptyLinesToKeep
    breakBinary*: int           # BreakBeforeBinaryOperators: -1 as written · 0 None (an operator ends its line: a
                                # line that starts with one is joined to the one before) · 2 All (starts the next)
    alignOperands*: bool        # AlignOperands: a continued expression under its first operand (after `= `,
                                # `return `), the `:` of a ternary under its `?`
    derivePointer*: bool        # DerivePointerAlignment: `*` where the file has it most (else `pointer`)
    blankAtBlockStart*: bool    # KeepEmptyLinesAtTheStartOfBlocks
    breakReturnType*: int       # AlwaysBreakAfterDefinitionReturnType: 0 none · 1 all · 2 top level — a
                                # definition's return type on its own line (`static int⏎foo(void)`)
    indentBraces*: bool         # BraceWrapping.IndentBraces (GNU): a block's `{` one level in, its inside two
    escNewlines*: int           # AlignEscapedNewlines — a macro over several lines, formatted as code with its
                                # `\`: -1 as written · 0 one space before each · 1 at one column after the longest
                                # line (Left) · 2 at the column limit (Right)

func cStyleKeep*(indent = 2): CStyle =
  ## ned's own way: indentation and spaces, everything else as you wrote it
  CStyle(name: "keep", indent: max(1, indent), tabWidth: 8, contIndent: 2 * max(1, indent), alignAfterParen: true,
         shortBlocks: true, shortIfs: true, shortLoops: true, shortFuncs: 2, shortCase: true, maxBlank: 1,
         breakBinary: -1, escNewlines: -1, blankAtBlockStart: true)

func cStylePreset*(name: string): CStyle =
  ## clang-format's preset of that name (case does not matter), or the Linux kernel's ("Linux"); "keep" for others
  result = cStyleKeep()
  let n = name.toLowerAscii
  if n notin ["llvm", "google", "chromium", "mozilla", "webkit", "microsoft", "gnu", "linux"]: return
  # (LLVM first: the others are told as what they change)
  result = CStyle(name: "LLVM", indent: 2, tabWidth: 8, colLimit: 80, contIndent: 4, alignAfterParen: true,
                  braceFunc: 1, braceCtl: 1, braceType: 1, elseLine: 1, pointer: 1, parens: 1, caseIndent: false,
                  commentSpaces: 1, alignComments: true, shortBlocks: false, shortIfs: false, shortLoops: false,
                  shortFuncs: 2, shortCase: false, oneStatement: true, spaceInBraces: 1, castSpace: 1, maxBlank: 1,
                  breakBinary: 0, alignOperands: true, escNewlines: 2, blankAtBlockStart: true)
  case n
  of "google", "chromium":
    result.name = (if n == "google": "Google" else: "Chromium")
    result.pointer = 2
    result.caseIndent = true
    result.commentSpaces = 2
    result.shortIfs = n == "google"
    result.shortLoops = n == "google"
    result.escNewlines = 1
    result.derivePointer = n == "google"
    result.blankAtBlockStart = false
    if n == "chromium": result.shortFuncs = 1
  of "mozilla":
    result.name = "Mozilla"
    result.pointer = 2
    result.caseIndent = true
    result.braceFunc = 2
    result.braceType = 2
    result.contIndent = 2
    result.shortFuncs = 0
    result.breakReturnType = 2
  of "webkit":
    result.name = "WebKit"
    result.indent = 4
    result.colLimit = 0
    result.pointer = 2
    result.braceFunc = 2
    result.alignAfterParen = false
    result.alignComments = false
    result.breakBinary = 2
    result.alignOperands = false
  of "microsoft":
    result.name = "Microsoft"
    result.indent = 4
    result.colLimit = 120
    result.braceFunc = 2
    result.braceCtl = 2
    result.braceType = 2
    result.elseLine = 2
    result.shortFuncs = 0
  of "gnu":
    result.name = "GNU"
    result.colLimit = 79
    result.braceFunc = 2
    result.braceCtl = 2
    result.braceType = 2
    result.elseLine = 2
    result.parens = 3
    result.shortFuncs = 0
    result.breakBinary = 2
    result.breakReturnType = 1
    result.indentBraces = true
    result.alignComments = true
  of "linux":
    result.name = "Linux"
    result.indent = 8
    result.tabWidth = 8
    result.useTab = true
    result.contIndent = 8
    result.braceFunc = 2
    result.shortFuncs = 0
    result.alignComments = false
    result.escNewlines = 1
  else: discard

func cBraceWrap(v: string): int =
  ## a clang-format brace-wrapping value (true or false) as the style's brace setting: 2 — the brace on a line of its
  ## own, 1 — at the end of the line, 0 — anything else, left as written
  case v.toLowerAscii
  of "true": 2
  of "false": 1
  else: 0

proc cStyleSet*(st: var CStyle, key, value: string) =
  ## one of clang-format's keys (as a .clang-format writes it) on the style
  let v = value.strip.strip(chars = {'"', '\''})
  let lv = v.toLowerAscii
  let yes = lv in ["true", "yes", "always", "all", "consecutive", "acrossemptylines", "acrosscomments",
                   "acrossemptylinesandcomments"]
  case key
  of "IndentWidth":
    try: st.indent = clamp(parseInt(v), 1, 16) except ValueError: discard
  of "TabWidth":
    try: st.tabWidth = clamp(parseInt(v), 1, 16) except ValueError: discard
  of "UseTab": st.useTab = lv notin ["never", "false"]
  of "ColumnLimit":
    try: st.colLimit = clamp(parseInt(v), 0, 1000) except ValueError: discard
  of "ContinuationIndentWidth":
    try: st.contIndent = clamp(parseInt(v), 0, 16) except ValueError: discard
  of "AlignAfterOpenBracket": st.alignAfterParen = lv == "align"
  of "BreakBeforeBraces":
    case lv
    of "attach": (st.braceFunc, st.braceCtl, st.braceType, st.elseLine) = (1, 1, 1, 1)
    of "linux": (st.braceFunc, st.braceCtl, st.braceType, st.elseLine) = (2, 1, 1, 1)
    of "mozilla": (st.braceFunc, st.braceCtl, st.braceType, st.elseLine) = (2, 1, 2, 1)
    of "stroustrup": (st.braceFunc, st.braceCtl, st.braceType, st.elseLine) = (2, 1, 1, 2)
    of "allman", "whitesmiths", "gnu": (st.braceFunc, st.braceCtl, st.braceType, st.elseLine) = (2, 2, 2, 2)
    of "webkit": (st.braceFunc, st.braceCtl, st.braceType, st.elseLine) = (2, 1, 1, 1)
    else: discard                           # (Custom: BraceWrapping's keys)
  of "AfterFunction": st.braceFunc = cBraceWrap(v)
  of "AfterControlStatement":
    st.braceCtl = (if lv in ["always", "true"]: 2 elif lv in ["never", "false"]: 1 else: st.braceCtl)
  of "AfterStruct", "AfterUnion", "AfterEnum", "AfterClass": st.braceType = cBraceWrap(v)
  of "BeforeElse": st.elseLine = cBraceWrap(v)
  of "PointerAlignment":
    st.pointer = (case lv
                  of "right": 1
                  of "left": 2
                  of "middle": 3
                  else: st.pointer)
  of "SpaceBeforeParens":
    st.parens = (case lv
                 of "controlstatements", "controlstatementsexceptcontrolmacros", "custom": 1
                 of "never": 2
                 of "always", "nonemptyparentheses": 3
                 else: st.parens)
  of "IndentCaseLabels": st.caseIndent = yes
  of "SpacesBeforeTrailingComments":
    try: st.commentSpaces = clamp(parseInt(v), 1, 16) except ValueError: discard
  of "AlignTrailingComments":
    st.alignComments = lv notin ["false", "leave", "never"]     # (true, or `Kind: Always` in clang-format 16+)
  of "Kind": st.alignComments = lv == "always"       # (AlignTrailingComments: {Kind: Always, OverEmptyLines: 0})
  of "AlignConsecutiveMacros": st.alignMacros = yes
  of "AlignConsecutiveAssignments": st.alignAssign = yes
  of "AlignConsecutiveDeclarations": st.alignDecls = yes
  of "AllowShortBlocksOnASingleLine": st.shortBlocks = lv notin ["never", "false"]
  of "AllowShortIfStatementsOnASingleLine": st.shortIfs = lv notin ["never", "false"]
  of "AllowShortLoopsOnASingleLine": st.shortLoops = yes
  of "AllowShortFunctionsOnASingleLine":
    st.shortFuncs = (case lv
                     of "none", "false": 0
                     of "empty", "inline", "inlineonly": 1
                     else: 2)
  of "AllowShortCaseLabelsOnASingleLine": st.shortCase = yes
  of "Cpp11BracedListStyle": st.spaceInBraces = (if yes: 1 else: 2)
  of "SpaceAfterCStyleCast": st.castSpace = (if yes: 2 else: 1)
  of "BreakBeforeBinaryOperators":
    st.breakBinary = (case lv
                      of "none": 0
                      of "nonassignment": 2
                      of "all": 2
                      else: st.breakBinary)
  of "AlignOperands": st.alignOperands = lv notin ["false", "dontalign"]
  of "DerivePointerAlignment": st.derivePointer = yes
  of "KeepEmptyLinesAtTheStartOfBlocks": st.blankAtBlockStart = yes
  of "AlwaysBreakAfterDefinitionReturnType", "AlwaysBreakAfterReturnType":
    st.breakReturnType = (case lv
                          of "none": 0
                          of "all", "alldefinitions": 1
                          of "toplevel", "topleveldefinitions": 2
                          else: st.breakReturnType)
  of "IndentBraces": st.indentBraces = yes
  of "AlignEscapedNewlines":
    st.escNewlines = (case lv
                      of "dontalign": 0
                      of "left", "leftwithlastline": 1
                      of "right": 2
                      else: st.escNewlines)
  of "MaxEmptyLinesToKeep":
    try: st.maxBlank = clamp(parseInt(v), 0, 10) except ValueError: discard
  else: discard

proc cStyleFromClangFormat*(text: string, cpp = false): CStyle =
  ## a .clang-format (YAML: `Key: Value`, BraceWrapping's keys under it, `---` sections by Language): its
  ## BasedOnStyle, then the keys ned knows
  var sections: seq[seq[(string, string)]] = @[@[]]
  for raw in text.splitLines:
    let l = raw.split(" #")[0]
    if l.strip == "---":
      sections.add @[]
      continue
    if l.strip.len == 0 or l.strip.startsWith("#") or l.strip.startsWith("..."): continue
    let c = l.find(':')
    if c <= 0: continue
    let k = l[0 ..< c].strip.strip(chars = {'-', ' '})
    let v = l[c + 1 .. ^1].strip
    if v.startsWith("{") and v.endsWith("}"):
      # (an inline map: `AlignTrailingComments: {Kind: Always}` — its keys, and the key itself when it says one)
      for part in v[1 ..< v.high].split(','):
        let pc = part.find(':')
        if pc > 0: sections[^1].add (part[0 ..< pc].strip, part[pc + 1 .. ^1].strip)
      continue
    sections[^1].add (k, v)
  # (the section for C/C++ — Language: Cpp — or the first without a Language)
  var pick = sections[0]
  for s in sections:
    var lang = ""
    for (k, v) in s:
      if k == "Language": lang = v.toLowerAscii
    if lang in ["cpp", "c", "objc"]:
      pick = s
      break
    if lang.len == 0 and pick.len == 0: pick = s
  result = cStylePreset("LLVM")               # (clang-format's base when BasedOnStyle is not said)
  for (k, v) in pick:
    if k == "BasedOnStyle": result = cStylePreset(v)
  result.name = ".clang-format"
  for (k, v) in pick:
    if k notin ["BasedOnStyle", "Language"]: cStyleSet(result, k, v)

var cStyleFileCache: Table[string, (string, CStyle)]    # a .clang-format's path → (its time, its style)

proc cClangFormatFile*(dir: string): string =
  ## the .clang-format (or _clang-format) clang-format would use for a file in `dir` ("" none)
  var d = dir
  for _ in 0 .. 40:
    if d.len == 0: break
    for nm in [".clang-format", "_clang-format"]:
      if fileExists(d / nm): return d / nm
    let up = parentDir(d)
    if up.len == 0 or up == d: break
    d = up
  ""

proc cStyleFor*(path, name: string, options: seq[(string, string)], indent = 2): CStyle =
  ## the style for a C file (or a Nim file's emits): c.format.style — auto = the project's .clang-format when
  ## there is one, else ned's own way (keep) — then c.format.options (clang-format's keys)
  let n = name.strip
  if n.len == 0 or n.toLowerAscii == "auto" or n.toLowerAscii == "file":
    let f = if path.len > 0: cClangFormatFile(parentDir(absolutePath(path))) else: ""
    if f.len > 0:
      var stamp = ""
      try: stamp = $getLastModificationTime(f).toUnix
      except CatchableError: discard
      if f in cStyleFileCache and cStyleFileCache[f][0] == stamp: result = cStyleFileCache[f][1]
      else:
        try: result = cStyleFromClangFormat(readFile(f))
        except CatchableError: result = cStyleKeep(indent)
        cStyleFileCache[f] = (stamp, result)
    else: result = cStyleKeep(indent)
  elif n.toLowerAscii == "keep": result = cStyleKeep(indent)
  else: result = cStylePreset(n)
  for (k, v) in options: cStyleSet(result, k, v)     # (on keep too: its as-written choices, those keys aside)

proc cStyleOptions*(j: JsonNode): seq[(string, string)] =
  ## c.format.options ({"ColumnLimit": 100, "PointerAlignment": "Left"}) as key/value pairs
  if j == nil or j.kind != JObject: return
  for k, v in j:
    case v.kind
    of JString: result.add (k, v.getStr)
    of JInt: result.add (k, $v.getInt)
    of JBool: result.add (k, $v.getBool)
    of JObject:
      for k2, v2 in v: result.add (k2, (if v2.kind == JString: v2.getStr else: $v2))
    else: discard
