# ── breadcrumbs ──


proc drawBreadcrumbs() =
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
        let lab = p
        capture path:
          x = button(x, y, lab, proc() =
            showSide(svFiles)
            revealInTree(path), "Reveal folder", theme.dim, cb)
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
  elif b.lines.len > 1 and b.lang.id notin ["html", "xml", "markdown", "text", "json"]:
    let p = b.primary.head
    for l in stickyLines(b, min(p.line + 1, b.lines.high), 4):
      let c = crumbName(b.lines[l])
      if c.len == 0 or x + 4 >= lim: continue
      x = putStr(x, y, sep, blend(theme.dim, cb, 0.4), cb, {}, lim)
      let line = l
      capture line:
        x = button(x, y, truncTo(c, max(4, lim - x)), proc() =
          let bb = buf()
          if line < bb.lines.len:
            pushJump()
            bb.centerOn(Pos(line: line, col: leadingWs(bb.lines[line]).len)), "Go to " & c, theme.syn[tkFunc], cb)
