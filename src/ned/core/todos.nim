# ════════════════════════════════════════════════════════════════════════════
#  Comment tags: TODO · FIXME · BUG · HACK · NOTE (colours, the TODOs dock, next/previous)
# ════════════════════════════════════════════════════════════════════════════

type
  TodoTag = object
    word, color: string
    rank: int                  # 0 most urgent (red) … 4 a note (blue): sorts files and chips
  TodoHit = object
    tag: int                   # index into todoTags
    a, e: int                  # the tag word on the line
    wa, we: int                # its (name), -1 when there is none
    text: string               # what the comment says after the tag
  TodoItem = object
    path: string
    line, col, tag: int
    who, text: string

var
  todoTags: seq[TodoTag]
  todoTagsChanged = false      # the todo.tags setting changed: rescan with the new words
  todoTagsLoaded = false
  todoGen = 0                  # bumped whenever a file's tag list changes (the project list is cached on it)
  cfgTodoHl = true
  cfgTodoName = false

func todoRank(color: string): int =
  ## how urgent a tag's colour makes it, for sorting files and chips: red 0, orange 1, yellow 2, blue 4, any other
  ## colour 3
  case color.toLowerAscii
  of "red": 0
  of "orange": 1
  of "yellow": 2
  of "blue": 4
  else: 3

proc themeHue(target: float, fallback: Rgb): Rgb =
  ## the theme colour closest to a hue (degrees): a "blue" that fits the theme, whatever its info colour is
  result = fallback
  var bd = 45.0
  for c in [theme.info, theme.syn[tkFunc], theme.syn[tkType], theme.syn[tkProperty], theme.syn[tkKeyword],
            theme.syn[tkConst], theme.syn[tkPreproc], theme.accent, theme.gitMod]:
    let r = float((c shr 16) and 0xFF) / 255.0
    let g = float((c shr 8) and 0xFF) / 255.0
    let bl = float(c and 0xFF) / 255.0
    let mx = max(r, max(g, bl))
    let d = mx - min(r, min(g, bl))
    if mx <= 0.0 or d / mx < 0.25: continue
    var h = if mx == r: (g - bl) / d elif mx == g: (bl - r) / d + 2.0 else: (r - g) / d + 4.0
    if h < 0: h += 6.0
    var dd = abs(h * 60.0 - target)
    if dd > 180.0: dd = 360.0 - dd
    if dd < bd:
      bd = dd
      result = c

proc todoColor(i: int, bg: Rgb): Rgb =
  ## a tag's colour in the current theme, readable on `bg`
  if i < 0 or i >= todoTags.len: return theme.warn
  let c = todoTags[i].color.toLowerAscii
  var raw = theme.warn
  case c
  of "red": raw = theme.err
  of "yellow": raw = theme.warn
  of "orange": raw = blend(theme.err, theme.warn, 0.5)
  of "blue": raw = themeHue(212.0, 0x5B9BD5)
  of "green": raw = theme.gitAdd
  of "purple", "magenta": raw = themeHue(285.0, 0xB48EAD)
  of "accent": raw = theme.accent
  else:
    if c.len == 7 and c[0] == '#':
      try: raw = Rgb(parseHexInt(c[1 .. ^1]))
      except ValueError: discard
  readableOn(raw, bg, 3.0)

proc todoWordIn(s: string): bool =
  ## does the line hold a tag word? (one pass over it: this runs for every line of every open file)
  var firsts: set[char]
  for t in todoTags:
    if t.word.len > 0: firsts.incl t.word[0]
  for i in 0 ..< s.len:
    if s[i] in firsts and (i == 0 or s[i - 1] notin IdentChars):
      for t in todoTags:
        if t.word.len > 0 and t.word[0] == s[i] and s.continuesWith(t.word, i): return true

const TodoLead = {'#', '/', '*', '-', '!', ';', '%', '[', '{', '<'}

proc todoHits(s: string, toks: openArray[TokKind]): seq[TodoHit] =
  ## tag words that open a comment (after `#`, `//`, `--` …, or a line inside a block comment), with an optional (name).
  ## Upper case and a whole word only, so prose and strings are left alone.
  if todoTags.len == 0 or s.len > 20000: return
  for ti, t in todoTags:
    if t.word.len == 0: continue
    var k = s.find(t.word)
    while k >= 0:
      let e = k + t.word.len
      if (k == 0 or s[k - 1] notin IdentChars) and (e >= s.len or s[e] notin IdentChars) and
         k < toks.len and toks[k] in {tkComment, tkDoc}:
        var p = k - 1
        while p >= 0 and s[p] in {' ', '\t'}: dec p
        if p < 0 or s[p] in TodoLead:
          var h = TodoHit(tag: ti, a: k, e: e, wa: -1, we: -1)
          var j = e
          if j < s.len and s[j] == '(':
            let c = s.find(')', j)
            if c > j + 1 and c - j <= 40:
              h.wa = j
              h.we = c + 1
              j = c + 1
          while j < s.len and s[j] in {':', ' ', '\t', '-'}: inc j
          var ce = e                     # the message ends with the comment (code may follow a block comment)
          while ce < s.len and ce < toks.len and toks[ce] in {tkComment, tkDoc}: inc ce
          var m = if j < ce: s[j ..< ce].strip else: ""
          for closer in ["*/", "]##", "]#", "-->"]:
            if m.endsWith(closer): m = m[0 ..< m.len - closer.len].strip
          h.text = m
          result.add h
      k = s.find(t.word, k + 1)
  if result.len > 1: result.sort(proc(x, y: TodoHit): int = cmp(x.a, y.a))

func todoItemOf(path: string, line: int, s: string, h: TodoHit): TodoItem =
  ## the list entry for a tag found on one line s of a file: where it is, its tag, the text after it and the name in
  ## brackets (empty when there is none)
  TodoItem(path: path, line: line, col: h.a, tag: h.tag, text: h.text,
           who: (if h.wa >= 0: s[h.wa + 1 ..< h.we - 1] else: ""))

proc setTodoTags(j: JsonNode) =
  ## the todo.tags setting: {"TODO": "yellow", "FIXME": "red", …}
  var tags: seq[TodoTag]
  if j != nil and j.kind == JObject:
    for w, c in j:
      let word = w.strip
      if word.len == 0 or word.len > 24: continue
      let col = if c.kind == JString: c.getStr else: "yellow"
      tags.add TodoTag(word: word, color: col, rank: todoRank(col))
  if tags != todoTags:
    if todoTagsLoaded: todoTagsChanged = true
    todoTags = tags
  todoTagsLoaded = true

var
  todoBufCache = initTable[int, (int, seq[TodoItem])]()   # buffer id → (changeId, its tags)
  todoFiles = initTable[string, seq[TodoItem]]()          # path → tags found on disk by the last scan
  todoQueue: seq[string]                                # files the scan found, still to read
  todoScanBusy = false
  todoScanned = false
  todoScanAt: MonoTime
  todoScopeFile = false                                 # the dock: this file only
  todoOff: HashSet[string]                              # tag words the chips hide
  todoCollapsed: HashSet[string]
  todoGitName = ""

proc todoScanProject()

proc shiftTodos(b: Buffer, a, c, e: Pos) =
  ## an open file's TODO / NOTE marks (the scrollbar's, the gutter's, the TODOs dock's) move with its lines at
  ## once — the scan when typing pauses only confirms them
  if e.line == c.line or b.binary: return
  let delta = e.line - c.line
  proc moved(items: var seq[TodoItem]): bool =
    ## moves the marks of a list for an edit that replaced the text a ..< c with a ..< e: marks below follow their
    ## lines, those on the last replaced line move to the new last line, those inside the text that went are dropped.
    ## True when any changed
    var keep: seq[TodoItem]
    for it in items:
      var it = it
      if it.line == c.line and it.col >= c.col:      # after the edit on its last line: on the new last line
        it.col = it.col - c.col + e.col
        it.line = e.line
        result = true
      elif it.line > c.line:                         # below it
        it.line += delta
        result = true
      elif it.line > a.line or (it.line == a.line and it.col >= a.col):
        result = true
        continue                                     # inside the text that went: gone
      keep.add it
    items = keep
  if b.id in todoBufCache:
    var (cid, items) = todoBufCache[b.id]
    if moved(items): todoBufCache[b.id] = (cid, items)
  if b.path.len > 0 and b.path in todoFiles:
    var items = todoFiles[b.path]
    if moved(items):
      todoFiles[b.path] = items
      inc todoGen
