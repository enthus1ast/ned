# the completion popup: the list for the word being typed (from the language server, nimsuggest, ned's own engines,
# snippets and the words of the file), filtering it as typing goes on, deciding after each key whether to open or close
# it, and putting the chosen item in the text
proc closeComp() =
  ## closes the completion popup and forgets the list it showed (the items themselves stay)
  compOpen = false
  compShown.setLen(0)

proc compValid(): bool =
  ## the shown list still points into the items (a new request can replace or empty them first)
  if compShown.len == 0 or compSel < 0 or compSel >= compShown.len: return false
  for i in compShown:
    if i < 0 or i >= compItems.len: return false
  true

proc compPrefix(): string =
  ## what has been typed of the word being completed — from where the completion started to the cursor — to filter the
  ## list by; "\0" when the cursor has left that line or moved back before the start
  let b = buf()
  let p = b.primary.head
  if p.line != compLine or p.col < compStartCol: return "\0"
  b.lines[p.line][compStartCol ..< p.col]

proc compRecentKey(it: CompItem): string =
  ## the key an item's choice is remembered by: the file's language and the item's label
  let b = buf()
  (if b != nil and b.lang != nil: b.lang.id else: "") & ":" & it.label

proc compRecentBonus(it: CompItem): int =
  ## a completion you chose lately: the more lately, the higher it goes (the last 24 choices)
  if compRecent.len == 0: return 0
  let at = compRecent.getOrDefault(compRecentKey(it), -1)
  if at < 0: return 0
  max(0, 24 - (compRecentN - at))

proc refilterComp() =
  ## makes the shown list from all the items for the word typed so far: first the plugins' items are merged in, then
  ## each item is scored by fuzzy match (a prefix match, a nearer rank and a recent choice raise it) and the sorted list
  ## is shown, the first item selected. An item that equals the word already typed is left out unless it is a postfix
  ## template, so Tab does not lengthen a finished word. With nothing typed after a dot the language server's own order
  ## is used, recent choices first. The popup closes when the cursor has left the word or nothing matches.
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
  ## the fallback candidates when no engine answers: the words of three to 64 characters in the 4000 lines around the
  ## cursor (not the word being typed) and the language's keywords. A byte budget keeps a huge file or line from
  ## stalling a keystroke, and a very long line is read only near the cursor.
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
  ## asks the language server for completions at the cursor; the answer is matched to the buffer, position and text
  ## version when it comes
  let p = b.primary.head
  discard s.lspRequest("textDocument/completion", %*{"textDocument": b.docId,
    "position": s.lspPos(b, p), "context": {"triggerKind": 1}},
    LspReq(kind: lrCompletion, bufId: b.id, pos: p, version: b.lspVersion))

proc startCompletion(manual: bool) =
  ## opens completion for the word at the cursor (`manual`: asked for with the key, not typed). The special sources are
  ## tried in turn and the first that takes the place answers by itself — .nimble versions and package names, plugins,
  ## pragma strings, C wrappers, C in an emit, languages embedded in strings, ned's own web and C engines, the Nim
  ## index. Otherwise the language server or nimsuggest is asked, and when two letters are typed, it was asked for or
  ## nothing could be asked, the snippets and the words of the file fill the list.
  let b = buf()
  let p = b.primary.head
  let ws = b.wordStart(p)
  compLine = p.line
  compStartCol = ws
  compManual = manual
  if b.lang.mode == lmNim and nbVersionComplete(b, p, manual): return   # a .nimble's requires: the versions
  if b.lang.mode == lmNim and nbNameComplete(b, p, manual): return      # … and the packages
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
  ## what to do after a character was typed. Signature help is asked for after `(` and `,` (and closed after `)` or on
  ## another line), and HTML closes its tag after `>`. Then, with automatic completion on (and not while a macro runs),
  ## the popup is opened, narrowed or closed: a word's first or second letter, or a trigger character such as `.`, opens
  ## it; each further letter of the word narrows it; anything else, and strings and comments, close it. The branches for
  ## .nimble files, C #include lines, ned's CSS/HTML/SQL engine, the C engine and the Nim index follow their own rules.
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
  if not long and b.path.endsWith(".nimble") and ch < 128 and (isWordByte(char(ch)) or char(ch) == '-'):
    if nbNameComplete(b, p, false): return                   # (a requires' package: the names nimble knows)
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
  ## puts the selected item in the text. The choice is remembered (the last 600, the older half forgotten when full) to
  ## rank it higher next time. A Nim routine may become a call with its parameters as snippet placeholders. A snippet is
  ## expanded in place of the word (or of the receiver, for a postfix template); other text replaces the word at every
  ## cursor. An item that needs an import or a C #include gets that added too.
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
    if it.addImport.startsWith("#include "): cAddInclude(b, it.addImport)    # (C: the header that declares it)
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
  if it.addImport.startsWith("#include "): cAddInclude(b, it.addImport)   # C: printf → #include <stdio.h>
  elif it.addImport.len > 0: b.addImport(it.addImport)      # e.g. initTable → import std/tables
