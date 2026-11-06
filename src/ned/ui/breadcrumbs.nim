# ── the breadcrumbs above the editor: the folders and symbols down to the cursor, each a menu of its neighbours ──

var jsonCrumbsAt = ((-1, -1, -1, -1), newSeq[(string, int)]())   # ((buffer, change, line, column), the keys there)


# ── (6.32) a crumb tapped lists what is beside it: a folder's files and folders, a symbol's siblings (the other
#    declarations in the same block) — pick one to go there ──

const CrumbCtrl = ["if", "elif", "else", "while", "for", "when", "case", "of", "try", "except", "finally", "block",
                   "switch", "do", "with", "return", "loop", "match", "catch", "static", "defer"]

proc crumbIsDecl(s: string): bool =
  ## a line that declares something (not a control statement): what a symbol's siblings are
  let c = crumbName(s)
  if c.len == 0: return false
  let w = s.strip.split({' ', '(', ':'})[0]
  w notin CrumbCtrl

proc crumbSiblings(b: Buffer, line: int, parent: int): seq[PickItem] =
  ## the declarations at the indentation of `line` inside the block of `parent` (-1: the whole file)
  let ind = leadingWs(b.lines[line]).len
  var a = 0
  var e = b.lines.high
  if parent >= 0:
    let pind = leadingWs(b.lines[parent]).len
    a = parent + 1
    e = a
    while e < b.lines.len and (b.lines[e].strip.len == 0 or leadingWs(b.lines[e]).len > pind): inc e
    dec e
  for l in a .. min(e, b.lines.high):
    let s = b.lines[l]
    if s.strip.len == 0 or leadingWs(s).len != ind or not crumbIsDecl(s): continue
    result.add PickItem(label: crumbName(s), detail: (if l == line: "here · " else: "") & "line " & $(l + 1),
                        icon: (if l == line: "▸" else: "·"), path: b.path, line: l, col: ind)
    if result.len >= 500: break

proc crumbSymbolAct(line, parent: int, name: string): Action =
  ## what clicking a symbol crumb does: a picker of the declarations beside it (same indentation, inside the same parent
  ## block); when it has no sibling, a jump straight to its line
  (proc() =
    let bb = buf()
    if line >= bb.lines.len: return
    let sib = if bb.path.len > 0: crumbSiblings(bb, line, parent) else: @[]
    if sib.len < 2:
      pushJump()
      bb.centerOn(Pos(line: line, col: leadingWs(bb.lines[line]).len))
      return
    openPicker(pickSymbol, "Beside " & name & " — pick one to go there", sib))

proc crumbFolderAct(dir: string): Action =
  ## what clicking a folder crumb does: a picker of its visible folders (shown in the file tree) and files (opened); an
  ## empty folder is just shown in the tree
  (proc() =
    var items: seq[(string, string, proc() {.closure.})]
    var ds, fs: seq[string]
    try:
      for k, p in walkDir(dir):
        let n = extractFilename(p)
        if n.startsWith("."): continue
        if k in {pcDir, pcLinkToDir}: ds.add p else: fs.add p
    except OSError: discard
    ds.sort()
    fs.sort()
    for d in ds:
      capture d:
        items.add act(extractFilename(d) & "/", "show it in the files", proc() =
          showSide(svFiles)
          revealInTree(d))
    for f in fs:
      capture f:
        items.add act(extractFilename(f), "", proc() = discard openFile(f))
    if items.len == 0:
      showSide(svFiles)
      revealInTree(dir)
      return
    openActions(relPath(dir) & "/", items))

proc drawBreadcrumbs() =
  ## draws the bar above the editor: the file's path as clickable folder names ending in the file (a workspace folder's
  ## files from that folder's name on), and after it, by file type, the CSV column the cursor is in, the JSON keys down
  ## to the cursor, or the blocks (functions, classes …) around the cursor; clicking elsewhere on it opens the
  ## breadcrumb menu
  let y = lay.crumbY
  if y < 0: return
  let cb = theme.crumbBg           # its own shade: the bar never reads as a line of code
  let b = buf()
  let x0 = lay.edX
  let w = lay.edW
  fillRect(x0, y, w, 1, theme.dim, cb)
  if b.isWelcome(): return
  ctxRegion(x0, y, w, 1, proc() = ctxOpen(breadcrumbMenu()))
  var x = x0 + 2
  let lim = x0 + w - 1
  let sep = " › "
  if b.path.len > 0:
    var rel = relPath(b.path)
    var acc = if rel.isAbsolute: "" else: rootDir
    for r in wsRoots:
      # a workspace's other folder: from that folder's name on, not from /
      if b.path.startsWith(r & "/"):
        rel = extractFilename(r) & "/" & b.path[r.len + 1 .. ^1]
        acc = parentDir(r)
        break
    let parts = rel.split('/')
    for i, p in parts:
      if x >= lim: break
      if p.len == 0: continue
      acc = if acc.len == 0: "/" & p else: acc / p
      let last = i == parts.high
      let path = acc
      if last:
        if cfgIcons == "nerd": x = putStr(x, y, fileIcon(b.path), langColor(b.path), cb, {}, lim) + 1
        x = button(x, y, p, proc() = cmdFindFile(), "Go to file", theme.fg, cb)
      else:
        x = button(x, y, p, crumbFolderAct(path), "What is in it", theme.dim, cb)
        x = putStr(x, y, sep, blend(theme.dim, cb, 0.4), cb, {}, lim)
  else:
    x = putStr(x, y, b.name, theme.fg, cb, {}, lim)
  if b.lang.mode == lmCsv and b.lines.len > 0:
    # a CSV table: the column the cursor is in, by its heading
    let p = b.primary.head
    let s = b.lines[p.line]
    var k = 0
    for i, (a, e) in csvFields(s, csvSepOf(b.lang, s)):
      if p.col >= a and p.col <= e:
        k = i
        break
    let hs = csvFields(b.lines[0], csvSepOf(b.lang, b.lines[0]))
    let head = if k < hs.len: b.lines[0][hs[k][0] ..< hs[k][1]].strip(chars = {'"', ' '}) else: ""
    x = putStr(x, y, sep, blend(theme.dim, cb, 0.4), cb, {}, lim)
    x = putStr(x, y, (if head.len > 0 and p.line > 0: head & "  (column " & $(k + 1) & ")" else: "column " & $(k + 1)),
               theme.fg, cb, {}, lim)
  elif b.lang.mode == lmJson and b.lines.len > 1 and b.lines.len < 20000:
    # a JSON file: the keys down to the cursor (scripts › build) — a key is a button to it
    let p = b.primary.head
    let key = (b.id, b.changeId, p.line, p.col)
    if jsonCrumbsAt[0] != key: jsonCrumbsAt = (key, jsonPathPartsAt(b.lines, p.line, p.col))
    for (name, l) in jsonCrumbsAt[1]:
      if x + 4 >= lim: break
      x = putStr(x, y, sep, blend(theme.dim, cb, 0.4), cb, {}, lim)
      let line = l
      let nm = name
      capture line, nm:
        x = button(x, y, truncTo(nm, max(4, lim - x)), proc() =
          let bb = buf()
          if line < bb.lines.len:
            pushJump()
            bb.centerOn(Pos(line: line, col: leadingWs(bb.lines[line]).len)), "Go to " & nm, theme.syn[tkProperty], cb)
  elif b.lines.len > 1 and b.lang.id notin ["html", "xml", "markdown", "text", "json"]:
    let p = b.primary.head
    var parent = -1
    # (the blocks around the line under the cursor's — its own when it opens one; at a block's last line, with
    # an empty one under it, the cursor's)
    let below = min(p.line + 1, b.lines.high)
    let at = if below > p.line and b.lines[below].strip.len == 0: p.line else: below
    for l in stickyLines(b, at, 4):
      let c = crumbName(b.lines[l])
      if c.len == 0 or x + 4 >= lim: continue
      x = putStr(x, y, sep, blend(theme.dim, cb, 0.4), cb, {}, lim)
      x = button(x, y, truncTo(c, max(4, lim - x)), crumbSymbolAct(l, parent, c),
                 "What is beside " & c & " — or go to it", theme.syn[tkFunc], cb)
      parent = l
