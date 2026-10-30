# ── the profile as a flame graph: each call stack the profiler saw, the program at the top and what each proc
#    called below it, as wide as the time it took — a tap on a box looks inside it, the top bar goes back. And the
#    profile against the one before (Nim: compare with the previous profile) ──

type FlameNode = ref object
  name, file: string
  count: int
  kids: seq[FlameNode]

var
  flameRoot: FlameNode
  flameMade = -1                          # (the profile it was made from: its samples)
  flameZoom: seq[(string, string)]        # the boxes looked inside, from the top

proc flameTree(): FlameNode =
  ## the profiler's call stacks as a tree: each box counts the samples that went through it, and each level is ordered
  ## with the biggest first
  result = FlameNode(name: "the whole program", count: 0)
  for (st, n) in profStacks:
    result.count += n
    var node = result
    for (name, file) in st:
      var next: FlameNode = nil
      for k in node.kids:
        if k.name == name and k.file == file:
          next = k
          break
      if next == nil:
        next = FlameNode(name: name, file: file)
        node.kids.add next
      next.count += n
      node = next
  proc order(x: FlameNode) =
    ## sorts a box's children by their samples, biggest first, and then theirs the same way
    x.kids.sort(proc(a, b: FlameNode): int = cmp(b.count, a.count))
    for k in x.kids: order(k)
  order(result)

proc flameNow(): FlameNode =
  ## the box looked inside (the whole program when none)
  if flameRoot == nil or flameMade != profSamples:
    flameRoot = flameTree()
    flameMade = profSamples
    flameZoom.setLen(0)
  result = flameRoot
  for (n, f) in flameZoom:
    var found: FlameNode = nil
    for k in result.kids:
      if k.name == n and k.file == f: found = k
    if found == nil:
      flameZoom.setLen(0)
      return flameRoot
    result = found

proc flameOwn(file: string): bool =
  ## whether the file is the project's own code (inside the project folder and not in the Nim library)
  rootDir.len > 1 and file.startsWith(rootDir & "/") and not (nxLibDir.len > 0 and file.startsWith(nxLibDir & "/"))

proc flameColor(n: FlameNode): Rgb =
  ## yours warm, the libraries' cool; neighbours told apart by a shade from the name
  let h = (hash(n.name) and 0xFF).float / 255.0
  if flameOwn(n.file): blend(blend(theme.warn, theme.err, h * 0.7), theme.bg, 0.35)
  else: blend(blend(theme.info, theme.accent, h * 0.7), theme.bg, 0.45)

proc flameAct(path: seq[(string, string)]): Action =
  ## (an action of its own for each box: closures made in a loop would share the loop's variables)
  result = proc() =
    flameZoom = path
    needRender = true

proc flameWhere(n: FlameNode): string =
  ## the line that says what a box is: its name, its share of all the samples (and how many), and its file — lib/… for
  ## the Nim library, else the path from the project
  let total = max(1, (if flameRoot != nil: flameRoot.count else: 1))
  n.name & " · " & formatFloat(n.count * 100 / total, ffDecimal, 1) & "% (" & $n.count & " samples)" &
    (if n.file.len > 0: " · " & (if nxLibDir.len > 0 and n.file.startsWith(nxLibDir & "/"): "lib/" &
     n.file[nxLibDir.len + 1 .. ^1] else: relPath(n.file)) else: "")

proc drawFlame(b: Buffer, x0, y0, w, h: int) =
  ## draws the flame graph in the given area: a title line, the top bar with the box looked inside (a tap goes back up
  ## one), a row for each level of calls with boxes as wide as their share of the samples (a tap looks inside one), and
  ## at the bottom what the box under the mouse is, or the keys
  cursorX = -1
  cursorY = -1
  if profStacks.len == 0:
    discard putStr(x0 + 2, y0 + 1, "No profile with call stacks yet — Nim: profile", theme.dim, theme.bg)
    return
  let top = flameNow()
  let total = max(1, flameRoot.count)
  # the line at the top: where you are, how to go back
  var hx = putStr(x0 + 1, y0, "FLAME GRAPH", theme.accent, theme.bg, {aBold})
  hx = putStr(hx, y0, " · " & $total & " samples · tap a box to look inside it", theme.dim, theme.bg, {}, x0 + w)
  # the box looked inside, as the top bar (a tap goes back up one)
  let barY = y0 + 1
  var path: seq[(string, string)]
  let up = if flameZoom.len > 0: flameZoom[0 ..< flameZoom.high] else: @[]
  let topLabel = (if flameZoom.len > 0: "↑ " else: "") & flameWhere(top)
  fillRect(x0, barY, w, 1, theme.fg, blend(theme.bg, theme.fg, 0.16))
  discard putStr(x0 + 1, barY, topLabel, theme.fg, blend(theme.bg, theme.fg, 0.16), {aBold}, x0 + w)
  region(x0, barY, w, 1, flameAct(up), (if flameZoom.len > 0: "Back up one" else: "The whole program"))
  for z in flameZoom: path.add z
  let bottom = y0 + h - 1                                  # (the last row: what a box is)
  var under = ""                                           # (the box under the mouse pointer)
  proc draw(n: FlameNode, x: int, width: float, y: int, path: seq[(string, string)]) =
    ## draws a box's children side by side on row `y`, across `width` columns from `x`, each as wide as its share of the
    ## samples (those too narrow to see are left out), then theirs on the rows below. `path` is the way to the box,
    ## which a tap on a child extends to look inside it
    if y >= bottom or width < 1.0: return
    var at = float(x)
    var other = 0.0
    for k in n.kids:
      let kw = width * k.count.float / max(1, n.count).float
      let a = int(at + 0.5)
      let e = int(at + kw + 0.5)
      at += kw
      if e - a < 1:
        other += kw
        continue
      let c = flameColor(k)
      fillRect(a, y, e - a, 1, theme.fg, c)
      if e - a >= 3:
        discard putStr(a + 1, y, k.name, theme.fg, c, {}, e - (if e - a > 4: 1 else: 0))
      if e < x0 + w: setCell(e - 1, y, Cell(ch: 0x2595, fg: blend(c, theme.bg, 0.5), bg: c))   # ▕ between boxes
      let kp = path & @[(k.name, k.file)]
      region(a, y, e - a, 1, flameAct(kp), flameWhere(k))
      if mouseY == y and mouseX >= a and mouseX < e: under = flameWhere(k)
      draw(k, a, float(e - a), y + 1, kp)
  draw(top, x0, float(w), barY + 1, path)
  let tip = if under.len > 0: under else: "yours: warm colours · the libraries': cool · Backspace or the top bar: " &
                                           "back up · Enter: its code"
  fillRect(x0, bottom, w, 1, theme.fg, theme.bg)
  discard putStr(x0 + 1, bottom, tip, theme.dim, theme.bg, {}, x0 + w)

proc flameKey(k: Key): bool =
  ## the flame graph's keys: Backspace (or u, Esc) back up, Enter its code
  if k.kind == kBackspace or (k.kind == kChar and k.mods == {} and k.ch == ord('u')):
    if flameZoom.len > 0:
      flameZoom.setLen(flameZoom.len - 1)
      needRender = true
    return true
  if k.kind == kEnter and k.mods == {}:
    let n = flameNow()
    if n.file.len > 0 and fileExists(n.file):
      var line = -1
      for r in profRows:
        if r[0] == n.name and r[1] == n.file: line = r[2]
      discard openFile(n.file, line)
    return true
  false

proc cmdFlame() =
  ## the last profile's call stacks as a flame graph, in a tab
  if profStacks.len == 0:
    info("No profile yet — Nim: profile runs the program and measures it")
    return
  for b in bufs:
    if b.id in flameViews:
      curBuf = bufs.find(b)
      needRender = true
      return
  let fb = openScratch("Flame graph", "", langByName("Text"))
  fb.readOnly = true
  flameViews.incl fb.id
  flameZoom.setLen(0)

proc cmdProfileCompare() =
  ## the last profile against the one before: each proc's share of the time, before and after
  if profPrevRows.len == 0 or profRows.len == 0:
    info("Profile twice (Nim: profile) — then this compares the two")
    return
  var before: Table[(string, string), int]
  for r in profPrevRows: before[(r[0], r[1])] = r[4]
  var rows: seq[(float, float, string, string, int)]       # (before %, after %, proc, file, line)
  var seen: HashSet[(string, string)]
  for r in profRows:
    let b = before.getOrDefault((r[0], r[1]), 0) * 100 / max(1, profPrevSamples)
    let a = r[4] * 100 / max(1, profSamples)
    rows.add (b, a, r[0], r[1], r[2])
    seen.incl (r[0], r[1])
  for r in profPrevRows:
    if (r[0], r[1]) notin seen: rows.add (r[4] * 100 / max(1, profPrevSamples), 0.0, r[0], r[1], r[2])
  rows.sort(proc(x, y: (float, float, string, string, int)): int = cmp(abs(y[1] - y[0]), abs(x[1] - x[0])))
  panelKind = pkSearch
  panelLines.setLen(0)
  panelLines.add PanelLine(text: "  before   after   change   proc   (" & $profPrevSamples & " samples, then " &
                           $profSamples & " — each proc's share of the time, with what it calls)", sev: 5, line: -1)
  for (b, a, name, file, line) in rows[0 ..< min(rows.len, 200)]:
    if b < 0.1 and a < 0.1: continue
    let d = a - b
    let sign = if d > 0.05: "+" elif d < -0.05: "−" else: " "
    panelLines.add PanelLine(text: align(formatFloat(b, ffDecimal, 1) & "%", 8) & align(formatFloat(a, ffDecimal, 1) &
                             "%", 8) & align(sign & formatFloat(abs(d), ffDecimal, 1), 8) & "   " & name & "  " &
                             relPath(file) & (if line >= 0: ":" & $(line + 1) else: ""),
                             path: (if line >= 0: file else: ""), line: line,
                             sev: (if d > 1.0: 1 elif d < -1.0: 4 else: 0))
  panelTitle = "PROFILE · BEFORE AND AFTER"
  panelOpen = true
  panelFollow = false
  needRender = true
