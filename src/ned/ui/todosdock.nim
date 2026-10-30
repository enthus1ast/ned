# ── TODO comments: open files, the project scan, the dock's list ──

proc computeBufTodos(b: Buffer): seq[TodoItem] =
  ## the open file's tag comments: the highlighter's lexer state where it has one (or is close), otherwise
  ## the line on its own (a tag starts a comment on its line, so that is almost always the same)
  if b.binary or b.lines.len > 300_000 or todoTags.len == 0: return
  var toks: seq[TokKind]
  for l in 0 ..< b.lines.len:
    let s = b.lines[l]
    if s.len > 20000 or not todoWordIn(s): continue
    let st = if l <= b.hlValid and l < b.hlStart.len: b.hlStart[l]
             elif l - b.hlValid <= 2000: b.stateAt(l)[0]
             else: 0'u8
    discard lexLine(b.lang, s, st, toks)
    for h in todoHits(s, toks): result.add todoItemOf(b.path, l, s, h)

proc todoForBuf(b: Buffer): seq[TodoItem] =
  ## the tag comments last found in the open file (todoRefreshBufs fills the cache); none when it has not been read yet
  if b.id in todoBufCache: todoBufCache[b.id][1] else: @[]

proc todoBufStale(b: Buffer): bool =
  ## true when the file's tag comments were never worked out or the buffer has changed since
  b.id notin todoBufCache or todoBufCache[b.id][0] != b.changeId

proc todoRefreshBufs() =
  ## idle: tags of the open files, once typing pauses
  let t0 = getMonoTime()
  for b in bufs:
    if not b.todoBufStale() or msSince(b.lspChangeAt) < (if b.lines.len > 50_000: 1500 else: 300): continue
    if not b.binary and b.lines.len <= 300_000 and todoTags.len > 0:
      # the lexer's states up to the last tag below what is highlighted, a slice a round (a file just opened had a
      # thousand lines lexed at once for it)
      var need = -1
      for l in countdown(min(b.lines.high, b.hlValid + 2000), b.hlValid + 1):
        if b.lines[l].len <= 20000 and todoWordIn(b.lines[l]):
          need = l
          break
      while b.hlValid < need and msSince(t0) < 4: b.ensureHl(min(need, b.hlValid + 200))
      if b.hlValid < need: return                  # (more next round)
    let items = computeBufTodos(b)
    todoBufCache[b.id] = (b.changeId, items)
    inc todoGen
    if b.path.len > 0 and not b.dirty:
      if items.len > 0: todoFiles[b.path] = items else: todoFiles.del b.path
    needRender = true
    if msSince(t0) > 25: break

proc todoScanProject() =
  ## finds the files with tags (ripgrep, else grep) in the background; todoPump reads them a slice at a time
  if todoScanBusy or todoTags.len == 0 or rootDir.len <= 1: return
  if rootDir == getHomeDir().strip(leading = false, chars = {'/'}): return
  var cmd = ""
  if haveExe("rg"):
    cmd = "rg -l --no-messages -F -w --max-filesize 2M"
    for d in cfgExclude: cmd.add " -g " & quoteShell("!" & d)
  else:
    cmd = "grep -rlIwF"
    for d in cfgExclude: cmd.add " --exclude-dir=" & quoteShell(d)
  for t in todoTags: cmd.add " -e " & quoteShell(t.word)
  cmd.add " . 2>/dev/null"
  let root = rootDir
  todoScanBusy = true
  let j = startJob(jkTool, cmd, root, proc(j: Job) =
    todoScanBusy = false
    todoScanAt = getMonoTime()
    if root != rootDir:
      todoScanProject()              # the project changed while this one ran
      return
    # exit 0: found some · 1: none · more: an error (unreadable files, a bad pattern) — keep what we had
    let reliable = j.code in {0, 1}
    var fresh: HashSet[string]
    todoQueue.setLen(0)
    for l in j.output.splitLines:
      let p = l.strip
      if p.len == 0: continue
      let ap = (if p.startsWith("./"): root / p[2 .. ^1] elif p.isAbsolute: p else: root / p).normalizedPath
      if ap notin fresh:
        fresh.incl ap
        todoQueue.add ap
      if todoQueue.len >= 3000: break
    if reliable:
      var gone: seq[string]
      for p in todoFiles.keys:
        if p notin fresh: gone.add p
      for p in gone: todoFiles.del p
    inc todoGen
    if todoQueue.len == 0: todoScanned = true
    needRender = true)
  if j == nil: todoScanBusy = false

var
  todoCur: tuple[path: string, lines: seq[string], lang: Lang, l: int, st: LexSt, exact: bool,
                 items: seq[TodoItem]]                # (the file being read: a few hundred lines a round)

proc todoPump(budgetMs: int) =
  ## the files the scan found, read a slice at a time — a long file over several rounds (its tags exact: the lexer
  ## carried from line to line), so one never holds up a key
  let t0 = getMonoTime()
  while todoQueue.len > 0 and msSince(t0) < budgetMs:
    let p = todoQueue[^1]
    if todoCur.path != p:
      todoCur = (p, newSeq[string](), Lang(nil), 0, LexSt(0), true, newSeq[TodoItem]())
      var content: string
      try:
        if getFileSize(p) <= 2_000_000: content = readFile(p)
      except CatchableError: discard
      if content.len == 0 or '\0' in content[0 ..< min(content.len, 8000)]:
        discard todoQueue.pop()
        todoFiles.del p
        todoCur.path = ""
        continue
      let nl = content.find('\n')
      todoCur.lang = detectLang(p, if nl > 0: content[0 ..< nl] else: content)
      # (small files are lexed line by line — exact; big ones only on the lines with a tag word)
      todoCur.exact = content.len <= 300_000
      todoCur.lines = content.splitLines
    var toks: seq[TokKind]
    let stop = min(todoCur.lines.len, todoCur.l + 400)
    while todoCur.l < stop:
      # (the clock looked at every 32 lines: a slice of dense code lexed in one go took up to 14 ms)
      if (todoCur.l and 31) == 0 and msSince(t0) >= budgetMs: break
      let s = todoCur.lines[todoCur.l]
      if s.len <= 20000:
        if todoCur.exact: todoCur.st = lexLine(todoCur.lang, s, todoCur.st, toks)
        if todoWordIn(s):
          if not todoCur.exact: discard lexLine(todoCur.lang, s, 0'u32, toks)
          for h in todoHits(s, toks): todoCur.items.add todoItemOf(p, todoCur.l, s, h)
      inc todoCur.l
    if todoCur.l >= todoCur.lines.len:
      if todoCur.items.len > 0: todoFiles[p] = todoCur.items else: todoFiles.del p
      discard todoQueue.pop()
      todoCur.path = ""
      todoCur.lines.setLen(0)
      inc todoGen
  if todoQueue.len == 0: todoScanned = true
  needRender = true

var
  todoCacheKey = (-1, "", -1)
  todoCacheAll: seq[TodoItem]
  todoCacheUrgent = 0
  todoCacheByFile = initTable[string, (int, int)]()   # path → (count, most urgent tag)

proc todoRefreshCache() =
  ## the project's tags (open files from their buffers, the rest from the last scan) — rebuilt only when a
  ## list changed, a file was opened or closed, or the project changed; the status bar and the Files tree
  ## read it every frame
  var bk = 0
  for b in bufs: bk = bk *% 31 +% (b.id + 1)          # wrapping: many tabs must not overflow
  let key = (todoGen, rootDir, bk)
  if key == todoCacheKey: return
  todoCacheKey = key
  todoCacheAll.setLen(0)
  todoCacheUrgent = 0
  todoCacheByFile.clear()
  var seen: HashSet[string]
  let pre = rootDir & "/"
  for b in bufs:
    if b.path.len > 0 and b.path.startsWith(pre) and b.id in todoBufCache and b.path notin seen:
      seen.incl b.path
      todoCacheAll.add todoBufCache[b.id][1]
  for p, items in todoFiles:
    if p notin seen and p.startsWith(pre): todoCacheAll.add items
  for it in todoCacheAll:
    if it.tag >= todoTags.len: continue
    if todoTags[it.tag].rank == 0: inc todoCacheUrgent
    if it.path notin todoCacheByFile: todoCacheByFile[it.path] = (1, it.tag)
    else:
      var (n, best) = todoCacheByFile[it.path]
      inc n
      if todoTags[it.tag].rank < todoTags[best].rank: best = it.tag
      todoCacheByFile[it.path] = (n, best)

proc todoCollect(fileOnly: bool): seq[TodoItem] =
  ## the project's tags, or this file's
  if fileOnly: return todoForBuf(buf())
  todoRefreshCache()
  todoCacheAll

proc todoUrgentCount(): int =
  ## the red tags in the project (by default the fix-me and bug ones), for the status bar
  if todoTags.len == 0: return 0
  todoRefreshCache()
  todoCacheUrgent

proc todoGrouped(items: seq[TodoItem]): seq[(string, seq[TodoItem])] =
  ## by file: files with the most urgent tags first, then by name; lines in order
  var byPath = initOrderedTable[string, seq[TodoItem]]()
  for it in items:
    byPath.mgetOrPut(it.path, @[]).add it
  for p, xs in byPath:
    var ys = xs
    ys.sort(proc(a, b: TodoItem): int = cmp(a.line, b.line))
    result.add (p, ys)
  proc best(xs: seq[TodoItem]): int =
    ## the rank of the most urgent tag among the items (lower is more urgent), 9 when there are none
    result = 9
    for x in xs:
      if x.tag < todoTags.len: result = min(result, todoTags[x.tag].rank)
  result.sort(proc(a, b: (string, seq[TodoItem])): int =
    let c = cmp(best(a[1]), best(b[1]))
    if c != 0: c else: cmp(relPath(a[0]), relPath(b[0])))

proc todoVisible(items: seq[TodoItem]): seq[TodoItem] =
  ## the items whose tag has not been switched off with the dock's chips (todoOff)
  for it in items:
    if it.tag < todoTags.len and todoTags[it.tag].word notin todoOff: result.add it

proc todoChipOrder(counts: seq[int]): seq[int] =
  ## tags that have comments, most urgent first (the chips, and the 1-9 keys)
  for i in 0 ..< min(counts.len, todoTags.len):
    if counts[i] > 0: result.add i
  result.sort(proc(a, b: int): int = cmp(todoTags[a].rank, todoTags[b].rank))

proc todoCounts(items: seq[TodoItem]): seq[int] =
  ## how many comments there are of each tag, in the order of todoTags
  result = newSeq[int](todoTags.len)
  for it in items:
    if it.tag < result.len: inc result[it.tag]

var
  todoDockKey = ""               # what the dock's list was built from (rebuilt only when it changes)
  todoDockItems: seq[SideItem]
  todoDockCounts: seq[int]       # per tag, before the chips' filter
  todoDockVis, todoDockFiles = 0

proc todoDockKeyNow(): string =
  ## a text that changes whenever anything the dock's list is built from changes: the scan generation, the scope, the
  ## project, the tags, the open files, the tags switched off and the collapsed files. The list is rebuilt only then.
  result = $todoGen & "|" & $todoScopeFile & "|" & rootDir & "|" & $todoTags.len & "|"
  if todoScopeFile: result.add $buf().id
  else:
    for b in bufs: result.add $b.id & ","
  var ws: seq[string]
  for w in todoOff: ws.add w
  ws.sort()
  result.add "|" & ws.join(",") & "|"
  var cs: seq[string]
  for c in todoCollapsed: cs.add c
  cs.sort()
  result.add cs.join(",")

proc buildTodoItems(): seq[SideItem] =
  ## the dock's lines (and the header's counts); the dock draws every frame, so this is cached
  let key = todoDockKeyNow()
  if key == todoDockKey: return todoDockItems
  let all = todoCollect(todoScopeFile)
  todoDockCounts = todoCounts(all)
  let items = todoVisible(all)
  todoDockVis = items.len
  var files: HashSet[string]
  for it in items: files.incl it.path
  todoDockFiles = files.len
  for (p, xs) in todoGrouped(items):
    if not todoScopeFile:
      let pp = p
      var act: Action
      capture pp:
        act = proc() =
          if pp in todoCollapsed: todoCollapsed.excl pp else: todoCollapsed.incl pp
          needRender = true
      result.add sideItem(relPath(p), 0, (if p in todoCollapsed: ic("chevR") else: ic("chevD")), $xs.len, act,
                          data = "file")
      if p in todoCollapsed: continue
    for it in xs:
      var si = sideItem(it.text, 0, "", "", nil, it.path, it.line, (if todoScopeFile: 0 else: 1),
                        "todo:" & $it.tag & ":" & it.who)
      si.col = it.col
      result.add si
  todoDockKey = key
  todoDockItems = result

proc todoMarkdown(): string =
  ## the visible tag comments as Markdown: a heading with the project (or file) name and count, then a check-list per
  ## file with the tag, the person, the line and the text
  let items = todoVisible(todoCollect(todoScopeFile))
  let title = if todoScopeFile: buf().name else: extractFilename(rootDir)
  result = "## TODOs — " & title & " (" & $items.len & ")\n"
  for (p, xs) in todoGrouped(items):
    result.add "\n### " & relPath(p) & "\n\n"
    for it in xs:
      let w = if it.tag < todoTags.len: todoTags[it.tag].word else: "TODO"
      result.add "- [ ] **" & w & "**" & (if it.who.len > 0: " (" & it.who & ")" else: "") &
                 " line " & $(it.line + 1) & (if it.text.len > 0: ": " & it.text else: "") & "\n"

proc todoCopyMarkdown() =
  ## copies the TODO list as Markdown to the clipboard and says how many items it has
  let md = todoMarkdown()
  clipSet(md)
  toast("Copied the TODO list as Markdown (" & $max(0, md.count("\n- [ ]")) & " items)", 3)

proc todoJump(d: int) =
  ## next / previous tag comment in this file (wraps around)
  let b = buf()
  let items = computeBufTodos(b)
  todoBufCache[b.id] = (b.changeId, items)
  inc todoGen
  if items.len == 0:
    info("No " & (block:
      var ws: seq[string]
      for t in todoTags: ws.add t.word
      ws.join(", ")) & " comments in this file")
    return
  let h = b.primary.head
  var k = -1
  if d > 0:
    for i, it in items:
      if it.line > h.line or (it.line == h.line and it.col > h.col):
        k = i
        break
    if k < 0: k = 0
  else:
    for i in countdown(items.high, 0):
      let it = items[i]
      if it.line < h.line or (it.line == h.line and it.col < h.col):
        k = i
        break
    if k < 0: k = items.high
  let it = items[k]
  pushJump()
  b.centerOn(b.clampPos(Pos(line: it.line, col: it.col)))
  let w = if it.tag < todoTags.len: todoTags[it.tag].word else: ""
  info(w & " " & $(k + 1) & " of " & $items.len & (if it.text.len > 0: ": " & it.text else: ""))

proc todoInsert(tag: string) =
  ## a tag comment with the language's comment marker: on a blank line at its indentation,
  ## after the code otherwise
  let b = buf()
  if b.readOnly:
    warn("This buffer is read-only")
    return
  if cfgTodoName and todoGitName.len == 0:
    let (ok, o, _) = runFilter("git config user.name", "", rootDir, 2000)
    todoGitName = if ok: o.strip else: ""
  let head = tag & (if cfgTodoName and todoGitName.len > 0: "(" & todoGitName & ")" else: "") & ": "
  var open, close = ""
  if b.lang.lineComment.len > 0: open = b.lang.lineComment & " "
  elif b.lang.blockStart.len > 0:
    open = b.lang.blockStart & " "
    close = " " & b.lang.blockEnd
  else: open = "# "
  let ln = b.primary.head.line
  let s = b.lines[ln]
  if s.strip.len == 0:
    var ind = leadingWs(s)
    if ind.len == 0:
      for l2 in ln + 1 .. min(b.lines.high, ln + 50):
        if b.lines[l2].strip.len > 0:
          ind = leadingWs(b.lines[l2])
          break
    b.beginEdit()
    discard b.replaceText(Pos(line: ln, col: 0), Pos(line: ln, col: s.len), ind & open & head & close)
    b.setSingle(Pos(line: ln, col: ind.len + open.len + head.len))
    b.endEdit()
  else:
    let t = s.strip(leading = false)
    b.beginEdit()
    discard b.replaceText(Pos(line: ln, col: t.len), Pos(line: ln, col: s.len), "  " & open & head & close)
    b.setSingle(Pos(line: ln, col: t.len + 2 + open.len + head.len))
    b.endEdit()
  focus = fEditor
  needRender = true

proc todoInsertMenu() =
  ## opens a menu of the tags (the todo.tags setting) at the cursor; the one chosen is inserted as a comment by
  ## todoInsert
  var items: seq[MenuItem]
  for t in todoTags:
    let w = t.word
    capture w:
      items.add mi(w, "", proc() = todoInsert(w))
  if items.len == 0:
    warn("No tags: settings › todo.tags")
    return
  openMenu(items, (if cursorX >= 0: cursorX else: scrW div 3), (if cursorY >= 0: cursorY + 1 else: 3))

proc todoDeleteComment(path: string, line: int, word, text: string) =
  ## the work is done: remove the comment — the whole line when nothing else is on it; in a block comment
  ## only the tag's text, so the comment's opener and closer stay
  let f0 = focus
  let b = openFile(path)
  focus = f0                     # from the dock: stay there, to tick off the next one
  if b == nil or b.lines.len == 0: return
  if b.readOnly:
    warn("This buffer is read-only")
    return
  var toks: seq[TokKind]
  proc hitOn(l: int): TodoHit =
    ## the tag comment on line l that is the one being removed (same tag word and text), leaving that line's tokens in
    ## toks; a hit with tag -1 when it is not there
    result = TodoHit(tag: -1)
    if l < 0 or l >= b.lines.len: return
    let (st, _) = b.stateAt(l)
    discard lexLine(b.lang, b.lines[l], st, toks)
    for h in todoHits(b.lines[l], toks):
      if h.tag < todoTags.len and todoTags[h.tag].word == word and h.text == text: return h
  # the list can be a little older than the file: look for the same comment near its line
  var ln = -1
  var hit = TodoHit(tag: -1)
  for d in 0 .. 30:
    for l in [line + d, line - d]:
      let h = hitOn(l)
      if h.tag >= 0:
        ln = l
        hit = h
        break
    if ln >= 0: break
  if ln < 0:
    warn("That comment is not there any more — the list will catch up")
    todoScanProject()
    return
  discard hitOn(ln)              # toks for that line
  let s = b.lines[ln]
  var a = hit.a
  while a > 0 and toks[a - 1] in {tkComment, tkDoc}: dec a
  var e = hit.e
  while e < s.len and e < toks.len and toks[e] in {tkComment, tkDoc}: inc e
  let txt = s[a ..< e]
  let lg = b.lang
  proc startsWithAny(x: string, ms: openArray[string]): bool =
    ## true when x starts with one of the markers that is not empty
    for m in ms:
      if m.len > 0 and x.startsWith(m): return true
  let lineCmt = startsWithAny(txt, [lg.docLine, lg.lineComment])
  let opens = not lineCmt and startsWithAny(txt, [lg.docBlockStart, lg.blockStart])
  var closeAt = -1
  for m in [lg.docBlockEnd, lg.blockEnd]:
    if m.len > 0 and txt.strip(leading = false).endsWith(m):
      closeAt = a + txt.strip(leading = false).len - m.len
      break
  var ra, re: int                # what to remove on this line
  if lineCmt or (opens and closeAt >= 0):
    ra = a                       # the whole comment
    re = e
  elif opens:
    ra = hit.a                   # an opening `/* …` line whose comment goes on: keep the opener
    re = e
  elif closeAt >= 0:
    ra = hit.a                   # `TODO: x */` closes it: keep the closer
    re = closeAt
  else:
    ra = hit.a                   # a line inside a block comment
    re = e
  while ra > 0 and s[ra - 1] in {' ', '\t'}: dec ra     # and the spaces before it
  let rest = s[0 ..< ra] & s[re .. ^1]
  b.beginEdit()
  if rest.strip.len == 0 or (not lineCmt and not opens and closeAt < 0 and s[0 ..< hit.a].strip(chars = {' ', '\t', '*'}).len == 0):
    # nothing else on the line: the line goes
    if ln + 1 < b.lines.len:
      discard b.replaceText(Pos(line: ln, col: 0), Pos(line: ln + 1, col: 0), "")
    elif ln > 0:
      discard b.replaceText(Pos(line: ln - 1, col: b.lines[ln - 1].len), Pos(line: ln, col: s.len), "")
    else:
      discard b.replaceText(Pos(line: 0, col: 0), Pos(line: 0, col: s.len), "")
  else:
    discard b.replaceText(Pos(line: ln, col: ra), Pos(line: ln, col: re), (if closeAt >= 0 and re == closeAt: " " else: ""))
  b.setSingle(b.clampPos(Pos(line: ln, col: 0)))
  b.endEdit()
  info("Removed the comment — Ctrl+Z brings it back")
  needRender = true

proc remoteWebUrl(remote: string): string

proc todoCreateIssue(path: string, line: int, word, who, text: string) =
  ## a GitHub issue from a tag comment (gh): the comment as the title, a permalink and the code around it
  if not haveExe("gh"):
    warn("Creating issues needs the GitHub CLI: " & installHint("gh", "gh") & ", then run gh auth login once")
    return
  let root = findGitRoot(parentDir(path))
  if root.len == 0:
    warn(relPath(path) & " is not in a git repository")
    return
  let rel = relativePath(path, root).replace('\\', '/')
  let bi = bufIndexByPath(path)
  var lines: seq[string]
  if bi >= 0: lines = bufs[bi].lines
  else:
    try: lines = readFile(path).splitLines
    except CatchableError: discard
  var ctx = ""
  for l in max(0, line - 2) .. min(lines.high, line + 3): ctx.add lines[l] & "\n"
  let title = word & ": " & (if text.len > 0: text else: rel & " line " & $(line + 1))
  let fence = detectLang(path, "").id
  askConfirm("Create a GitHub issue “" & truncTo(title, 60) & "”? (y/n)", proc(c: char) =
    if c != 'y': return
    info("Creating the issue…")
    discard startJob(jkGit, "git remote get-url origin 2>/dev/null; git rev-parse HEAD 2>/dev/null", root, proc(g: Job) =
      # a permalink at this commit: GitHub shows the code right in the issue
      var link = ""
      let ls = g.output.strip.splitLines
      if ls.len >= 2 and "github" in ls[0]:
        link = remoteWebUrl(ls[0]) & "/blob/" & ls[^1].strip & "/" & rel & "#L" & $(max(1, line - 1)) & "-L" & $(line + 3)
      let body = "From `" & rel & "` line " & $(line + 1) & (if who.len > 0: " (" & who & ")" else: "") & ":\n\n" &
                 (if link.len > 0: link & "\n\n" else: "") &
                 "```" & fence & "\n" & ctx & "```\n\n_Created from a " & word & " comment in ned._\n"
      let bf = privTmp("issue")
      try: writeFile(bf, body)
      except CatchableError as e:
        error("Could not write the issue text: " & e.msg)
        return
      discard startJob(jkGit, "gh issue create --title " & quoteShell(title) & " --body-file " & quoteShell(bf) &
                       " 2>&1", root, proc(j: Job) =
        try: removeFile(bf)
        except CatchableError: discard
        var url = ""
        for l in j.output.splitLines:
          if l.strip.startsWith("https://"): url = l.strip
        if j.code == 0 and url.len > 0:
          clipSet(url)
          toast("Issue created — the link is copied: " & url, 3)
        else:
          let last = j.output.strip.splitLines
          error("gh issue create failed: " & (if last.len > 0: last[^1] else: "no output") &
                " — run gh auth login once if you have not"))))

proc todoItemMenu(it: SideItem): seq[MenuItem] =
  ## the menu of a row of the TODOs dock: open it, copy it, done (delete the comment), create a GitHub issue, copy the
  ## list as Markdown, switch between the file and the project, rescan. Empty for a row that is not a comment (a file's
  ## heading).
  let p = it.path
  let l = it.line
  let c = it.col
  if p.len == 0 or l < 0: return
  let parts = it.data.split(':', 2)
  let ti = (try: parseInt(parts[1]) except ValueError: -1)
  let w = if ti >= 0 and ti < todoTags.len: todoTags[ti].word else: "TODO"
  let line = w & (if parts.len > 2 and parts[2].len > 0: "(" & parts[2] & ")" else: "") & ": " & it.text &
             "  (" & relPath(p) & ":" & $(l + 1) & ")"
  @[mi("Open", "Enter", proc() =
      let b = openFile(p)
      if b != nil: b.centerOn(b.clampPos(Pos(line: l, col: c)))),
    mi("Copy", "", proc() =
      clipSet(line)
      info("Copied: " & line)),
    mi("Done: delete the comment", "x", proc() =
      todoDeleteComment(p, l, w, it.text)),
    mi("Create a GitHub issue…", "i", proc() =
      todoCreateIssue(p, l, w, (if parts.len > 2: parts[2] else: ""), it.text)),
    msep(),
    mi("Copy the list as Markdown", "c", proc() = todoCopyMarkdown()),
    mi((if todoScopeFile: "Show the whole project" else: "Show this file only"), "f", proc() =
      todoScopeFile = not todoScopeFile),
    mi("Rescan the project", "r", proc() = todoScanProject())]
