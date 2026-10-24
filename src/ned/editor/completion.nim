proc closeComp() =
  compOpen = false
  compShown.setLen(0)

proc compValid(): bool =
  ## the shown list still points into the items (a new request can replace or empty them first)
  if compShown.len == 0 or compSel < 0 or compSel >= compShown.len: return false
  for i in compShown:
    if i < 0 or i >= compItems.len: return false
  true

proc compPrefix(): string =
  let b = buf()
  let p = b.primary.head
  if p.line != compLine or p.col < compStartCol: return "\0"
  b.lines[p.line][compStartCol ..< p.col]

proc compRecentKey(it: CompItem): string =
  let b = buf()
  (if b != nil and b.lang != nil: b.lang.id else: "") & ":" & it.label

proc compRecentBonus(it: CompItem): int =
  ## a completion you chose lately: the more lately, the higher it goes (the last 24 choices)
  if compRecent.len == 0: return 0
  let at = compRecent.getOrDefault(compRecentKey(it), -1)
  if at < 0: return 0
  max(0, 24 - (compRecentN - at))

proc refilterComp() =
  plugCompMerge()                               # (a plugin's completions, when they came for this word)
  let pre = compPrefix()
  if pre == "\0":
    closeComp()
    return
  let lp = pre.toLowerAscii
  compShown.setLen(0)
  var exact = false
  for i in 0 ..< compItems.len:
    # (the letters matched are found when an item is drawn: a list of thousands, a handful on screen)
    let sc = fuzzyScore(lp, compFilter(compItems[i]))
    if sc != low(int):
      # a prefix match, and nearer names (locals, this module) before far ones (system)
      compItems[i].score = sc + (if compFilter(compItems[i]).startsWith(pre): 30 else: 0) +
                           max(0, 4 - compItems[i].rank) * 4 + compRecentBonus(compItems[i])
      if compItems[i].label != pre or compItems[i].postfix > 0: compShown.add i
      elif pre.len > 0: exact = true
  if exact and not compManual:
    # the word typed so far is already complete (`int`, `result`…): don't let Tab/Enter turn it into
    # something longer — keep typing to see longer candidates (a postfix template, xs.for, stays: it is what
    # the word was typed for)
    var keep: seq[int]
    for i in compShown:
      if compItems[i].postfix > 0 and compItems[i].label == pre: keep.add i
    compShown = keep
  if pre.len > 0:
    compShown.sort(proc(a, b: int): int =
      result = cmp(compItems[b].score, compItems[a].score)
      if result == 0: result = cmp(compItems[a].label.startsWith("_"), compItems[b].label.startsWith("_"))
      if result == 0: result = cmp(compItems[a].rank, compItems[b].rank)
      if result == 0: result = cmp(compItems[a].label.len, compItems[b].label.len))
  elif compFromLsp:
    # (each item's key made once, not at every comparison; the index's items sort by how near, then by name)
    var keyed = newSeqOfCap[(string, int)](compShown.len)
    for i in compShown:
      let it = addr compItems[i]
      # (nothing typed yet — after a dot: what you chose lately there first, the latest first)
      let rb = compRecentBonus(it[])
      keyed.add ((if rb > 0: " " & $(100 - rb) else: "") & (if it.label.startsWith("_"): "~" else: "") &
                 (if it.sortText.len > 0: it.sortText else: $it.rank & it.label.toLowerAscii), i)
    keyed.sort(proc(a, b: (string, int)): int = cmp(a[0], b[0]))
    for k, x in keyed: compShown[k] = x[1]
  compSel = 0
  compScroll = 0
  compDocIdx = -1
  compOpen = compShown.len > 0
  needRender = true

proc collectWords(b: Buffer): seq[string] =
  let p = b.primary.head
  let (ws, we) = b.wordRangeAt(p)
  let own = b.lines[p.line][ws.col ..< we.col]
  var seen: HashSet[string]
  let lo = max(0, p.line - 4000)
  let hi = min(b.lines.high, p.line + 4000)
  var budget = 4_000_000                       # bytes looked at: a huge file or line never stalls a keystroke
  for l in lo .. hi:
    let s = b.lines[l]
    var i = 0
    var stop = s.len
    if s.len > 200_000:                         # a very long line: only the part around the cursor
      if l != p.line: continue
      i = max(0, p.col - 100_000)
      stop = min(s.len, p.col + 100_000)
      while i > 0 and isWordByte(s[i - 1]): dec i
    budget -= stop - i
    if budget < 0: break
    while i < stop:
      if isIdentStart(s[i]):
        var j = i + 1
        while j < s.len and isWordByte(s[j]): inc j
        if j - i >= 3 and j - i <= 64:
          let w = s[i ..< j]
          if w != own: seen.incl w
        i = j
      else: inc i
  for k in b.lang.keywords:
    if k.len >= 3: seen.incl k
  for w in seen: result.add w

proc requestCompletion(b: Buffer, s: LspServer) =
  let p = b.primary.head
  discard s.lspRequest("textDocument/completion", %*{"textDocument": b.docId,
    "position": s.lspPos(b, p), "context": {"triggerKind": 1}},
    LspReq(kind: lrCompletion, bufId: b.id, pos: p, version: b.lspVersion))

proc startCompletion(manual: bool) =
  let b = buf()
  let p = b.primary.head
  let ws = b.wordStart(p)
  compLine = p.line
  compStartCol = ws
  compManual = manual
  if b.lang.mode == lmNim and nbVersionComplete(b, p, manual): return   # a .nimble's requires: the versions
  plugComplete(b, p)                                                  # (a plugin's: they join when they come)
  if b.lang.mode == lmNim and pragmaStringComplete(b, p, manual): return
  if b.lang.mode == lmNim and cWrapperComplete(b, p, manual): return  # proc ⟨C function⟩: the whole wrapper
  if b.lang.mode == lmNim and emitComplete(b, p, manual): return      # C in an emit
  if b.lang.mode == lmNim and embComplete(b, p, manual): return       # HTML, CSS, SQL … in a string
  if webComplete(b, p, manual): return                                # … ned's own (no language server for it)
  if cEngineOn(b) and cEngComplete(b, p, manual): return              # C: ned's own engine
  if nimEngineOn(b) and engineComplete(b, manual): return
  let s = lspReady(b)
  var asked = false
  if s != nil and s.caps != nil and s.caps{"completionProvider"} != nil:
    requestCompletion(b, s)
    asked = true
  elif nsUsable(b):
    asked = nsRequest(b, nsSug, p)
  if p.col - ws >= 2 or manual or not asked:
    let prefix = b.lines[p.line][ws ..< p.col]
    var items = snippetItems(b, prefix)
    for w in collectWords(b): items.add CompItem(label: w, insert: w, filter: w, sortText: w)
    compItems = items
    compFromLsp = false
    refilterComp()
    if manual and not compOpen and not asked: info("No completions")

proc afterType(ch: int) =
  let b = buf()
  let p = b.primary.head
  if ch == ord(')') or p.line != sigLine: sigOpen = false
  if ch == ord('>') and b.lang.mode == lmHtml: htmlAutoClose(b)
  if ch < 128 and char(ch) in {'(', ','} and cEngineOn(b) and cEngSignature(b, p): discard
  elif ch < 128 and char(ch) in {'(', ','} and
     not (b.lang.mode == lmNim and b.lines[p.line].len <= 2000 and emitSignature(b, p)):   # C in an emit: clangd's
    let s = lspReady(b)
    if nimEngineOn(b):
      if not engineSignature(b, p) and nsUsable(b): discard nsRequest(b, nsCon, p)
    elif s != nil and char(ch) in s.sigTriggers:
      discard s.lspRequest("textDocument/signatureHelp", %*{"textDocument": b.docId,
        "position": s.lspPos(b, p)}, LspReq(kind: lrSignature, bufId: b.id, pos: p))
    elif s == nil and nsUsable(b):
      discard nsRequest(b, nsCon, p)
  if not cfgAutoComplete: return
  if macroRecording or macroPlaying > 0: return   # a macro replays keys, not popups that come when they like
  if p.col == 0: return
  # lexing a huge line on every key would make typing in it quadratic; such lines are data, not code
  let long = b.lines[p.line].len > 2000
  if not long and b.path.endsWith(".nimble") and ch < 128 and char(ch) in {' ', '=', '>', '<', '@', '#', '^', '~', '.', '0'..'9'}:
    if nbVersionComplete(b, p, false): return                # (a requires' version: the package's versions)
  if not long and cEngineOn(b) and b.lines[p.line].strip(trailing = false).startsWith("#include"):
    # C: the headers there, in the quotes or <> of an #include, as the name is typed
    let c = if ch < 128: char(ch) else: 'a'
    if compOpen and compLine == p.line and isWordByte(c) and compFromLsp and compItems.len > 0 and
       b.wordStart(p) == compStartCol:
      refilterComp()
    elif c in {'<', '"', '/', '.'} or isWordByte(c):
      closeComp()
      discard cEngComplete(b, p, false)
    else: closeComp()
    return
  if not long and b.lang.mode != lmNim and webFamily(b.lang.id).len > 0 and webEngineOn(b, p):
    # ned's own CSS, HTML, SQL: after `<`, `:`, `.`, a space in a tag, a word's first letter — the list then
    # narrows as you type (an attribute's value too, which the colours call a string)
    let c = if ch < 128: char(ch) else: 'a'
    if c in {'<', '/', ':', '@', '!', '.', '#', ' ', '=', '"', '\'', '('} or isWordByte(c) or c == '-':
      if not webComplete(b, p, false): closeComp()
    else: closeComp()
    return
  let tk = if long: tkText else: b.tokenAt(Pos(line: p.line, col: p.col - 1))
  if tk in {tkString, tkPragma} and not long and b.lang.mode == lmNim and pragmaStringComplete(b, p, false): return
  if tk in {tkComment, tkDoc, tkString} or (not long and foreignAt(p.col - 1)):
    if tk notin {tkComment, tkDoc, tkString} and not long and b.lang.mode == lmNim and
       (emitComplete(b, p, false) or embComplete(b, p, false) or webComplete(b, p, false)):
      return                                                  # C in an emit, HTML/CSS/SQL in a string
    if not long and plugHasCompletions(b):
      # (a plugin's completions in strings and comments — paths, a Markdown link's #anchor: after / # ( and as the
      # word after them is typed)
      let c = if ch < 128: char(ch) else: 'a'
      if compOpen and compLine == p.line and (isWordByte(c) or c in {'.', '-'}) and compItems.len > 0 and
         p.col > compStartCol:
        refilterComp()                          # (a file name goes on past its dot: main.nim, on-termux)
        return
      if c in {'/', '#', '(', '~'}:
        closeComp()
        plugComplete(b, p)
        return
    closeComp()
    return
  # no document sync here: most keystrokes send nothing, and a full-text didChange per key is what makes
  # typing in big files slow. Requests below sync first; otherwise the main loop syncs after a pause.
  let s0 = lspFor(b, false)
  let s = if s0 != nil and s0.ready and not s0.dead: s0 else: nil
  let c = if ch < 128: char(ch) else: 'a'
  let ws = b.wordStart(p)
  if cEngineOn(b):
    # ned's C engine: after `.` and `->` the members, else names once a word starts
    if compLine == p.line and ws == compStartCol and isWordByte(c) and compFromLsp and compItems.len > 0:
      refilterComp()
      return
    if (c == '.' and not (p.col >= 2 and b.lines[p.line][p.col - 2] in Digits)) or
       (c == '>' and p.col >= 2 and b.lines[p.line][p.col - 2] == '-') or
       (c == ':' and p.col >= 2 and b.lines[p.line][p.col - 2] == ':' and cxIsCppBuf(b)):   # (C++: ns::, Class::)
      closeComp()
      discard cEngComplete(b, p, false)
      plugComplete(b, p)
      return
    if not isWordByte(c) or ws >= p.col or b.lines[p.line][ws] in Digits:
      closeComp()
      return
    if p.col - ws == 2:
      discard cEngComplete(b, p, false)
      plugComplete(b, p)
    return
  if nimEngineOn(b):
    # the index answers at once: after `.` the receiver's members, else names once a word starts
    if compLine == p.line and ws == compStartCol and isWordByte(c) and compFromLsp and compItems.len > 0:
      refilterComp()             # the list from this word's first letter (or the `.`) narrows as you type
      return
    if c == '.' and not (p.col >= 2 and b.lines[p.line][p.col - 2] == '.'):
      closeComp()
      discard engineComplete(b, false)
      plugComplete(b, p)
      return
    if not isWordByte(c) or ws >= p.col or b.lines[p.line][ws] in Digits:
      closeComp()
      return
    if p.col - ws == 1:
      discard engineComplete(b, false)
      plugComplete(b, p)
    return
  let ns = s == nil and nsUsable(b)
  if compOpen and compLine == p.line and ws == compStartCol and isWordByte(c):
    refilterComp()
    if compFromLsp or (s == nil and not ns): return
  if s != nil and c in s.triggers and not isWordByte(c):
    compLine = p.line
    compStartCol = p.col
    compItems.setLen(0)
    closeComp()
    lspSync(b)
    requestCompletion(b, s)
    return
  if ns and c == '.':
    compLine = p.line
    compStartCol = p.col
    compItems.setLen(0)
    closeComp()
    discard nsRequest(b, nsSug, p)
    return
  if not isWordByte(c) or ws >= p.col or ws >= b.lines[p.line].len or b.lines[p.line][ws] in Digits:
    closeComp()
    return
  let plen = p.col - ws
  if (plen == 1 and (s != nil or ns)) or plen == 2: startCompletion(false)

proc callSnippet(b: Buffer, it: CompItem): string =
  ## a routine's call with its parameters as placeholders — `area(${1:width}, ${2:height})` —, the receiver left out
  ## after a `.`; "" for anything else, a call already there (`(` after the cursor) or an import line
  let x = compNxAt(it.nx)
  if x == nil or x[].kind notin {nxProc, nxFunc, nxMethod, nxTemplate, nxMacro, nxConverter} or x[].refs.len == 0:
    return ""
  let h = b.primary.head
  let line = b.lines[h.line]
  if h.col < line.len and line[h.col] in {'(', '[', '`'}: return ""
  let t = line.strip(trailing = false)
  if t.startsWith("import ") or t.startsWith("from ") or t.startsWith("export ") or t.startsWith("include "): return ""
  let member = compStartCol > 0 and compStartCol - 1 < line.len and line[compStartCol - 1] == '.'
  let name = if it.insert.len > 0: it.insert else: it.label
  if x[].refs.len > 1:
    return name & "($0)"                      # (overloads: the parentheses, signature help tells the rest)
  var ps: seq[string]
  let params = x[].refs[0].sym.params
  for i, prm in params:
    if i == 0 and member: continue
    if prm.default.len > 0 or prm.typ.startsWith("varargs"): break
    ps.add "${" & $(ps.len + 1) & ":" & prm.name & "}"
  if ps.len == 0:
    return (if member or params.len > 0: "" else: name & "()$0")
  name & "(" & ps.join(", ") & ")$0"

proc acceptComp() =
  if not compOpen or compShown.len == 0: return
  if not compValid():
    closeComp()
    return
  var it = compItems[compShown[compSel]]
  let b = buf()
  inc compRecentN
  compRecent[compRecentKey(it)] = compRecentN
  if compRecent.len > 600:
    # (the oldest half go)
    var olds: seq[(int, string)]
    for k, v in compRecent: olds.add (v, k)
    olds.sort(proc(x, y: (int, string)): int = cmp(x[0], y[0]))
    for i in 0 ..< olds.len div 2: compRecent.del olds[i][1]
  if it.snippet.len == 0 and it.nx != 0 and cfgCallArgs and it.addImport.len == 0:
    # (nim.completeCallArguments: a routine with its parameters to fill in, as clangd and rust-analyzer do)
    let sn = callSnippet(b, it)
    if sn.len > 0: it.snippet = sn
  if it.snippet.len > 0:
    let h = b.primary.head
    closeComp()
    b.cursors = @[b.primary]
    b.prim = 0
    # a postfix template (xs.for) replaces its receiver as well
    let a = if it.postfix > 0 and h.line == compLine: min(it.postfix - 1, h.col) else: min(compStartCol, h.col)
    b.expandSnippet(Pos(line: h.line, col: a), h, it.snippet)
    return
  b.beginEdit()
  for i in countdown(b.cursors.high, 0):
    let h = b.cursors[i].head
    let a = if i == b.prim and h.line == compLine: Pos(line: h.line, col: min(compStartCol, h.col))
            else: Pos(line: h.line, col: b.wordStart(h))
    b.cursors[i] = cur(b.replaceText(a, h, compInsert(it)))
  b.endEdit()
  b.normalize()
  closeComp()
  compItems.setLen(0)
  if it.addImport.len > 0: b.addImport(it.addImport)      # e.g. initTable → import std/tables
