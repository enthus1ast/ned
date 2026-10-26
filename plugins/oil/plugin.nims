## oil — a folder as text you edit: rename, move, delete and make files by changing its lines, then save
##
## Turn it on in the Plugins dock (AVAILABLE). "Oil: edit this file's folder as text" (the palette, the Plugins
## menu; in vim mode also <leader>-) opens a tab listing the folder: one line for each file, folders ending
## with /. Change a line to rename the file (or move it: "../a.txt", "sub/a.txt"), delete a line to delete it, add a
## line to make a file ("new/" makes a folder) — then save (Ctrl+S, :w): ned lists what will happen and asks first.
## Deleted files go to the plugin's trash folder ("Oil: open the trash"; move a line out of it to bring one back).
## A line changed where it is renames its file; where lines are changed, deleted and added together, a new name
## like an old one (b.nim → c.nim) is taken as its rename, the others as deletes and new files — the list shown
## before anything is done says which, and No changes nothing.
##
## In the tab: Enter (vim's normal mode) or Alt+Enter opens the file or folder under the cursor; - (vim) or Alt+Up
## goes to the folder above; "Oil: show or hide hidden files" for the names starting with a dot. In vim mode,
## <leader>- (the space bar, then -) opens the folder of the file from anywhere.
##
## Settings: plugins.oil.hidden (show the hidden files, false), plugins.oil.trash (deleted files to the trash
## folder rather than gone, true).
import nedplugin

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")
permission("files", "renames, moves, makes and deletes the files and folders you change in its view")
import std/[strutils, algorithm, tables]

settingDef("hidden", false, "show the files and folders whose names start with a dot")
settingDef("trash", true, "deleted files go to the plugin's trash folder (\"Oil: open the trash\") rather than being gone")

language("oil", LangSpec(name: "Oil"))

var
  listed: Table[int, seq[string]]      # tab → the lines as listed (what saving compares with)
  showHidden: Table[int, bool]         # tab → hidden files shown

# ── the file system (nim e and compiled alike) ──

proc entries(dir: string, hidden: bool): seq[string] =
  ## the folder's names, folders first (with a / after them), each part sorted
  var ds, fs: seq[string]
  when defined(nimscript):
    for d in listDirs(dir): ds.add extractFilename(d)
    for f in listFiles(dir): fs.add extractFilename(f)
  else:
    for k, p in walkDir(dir):
      if k in {pcDir, pcLinkToDir}: ds.add extractFilename(p) else: fs.add extractFilename(p)
  ds.sort(cmpIgnoreCase)
  fs.sort(cmpIgnoreCase)
  for d in ds:
    if hidden or not d.startsWith("."): result.add d & "/"
  for f in fs:
    if hidden or not f.startsWith("."): result.add f

proc makeDir(d: string) =
  when defined(nimscript): mkDir(d)
  else: createDir(d)

proc moveIt(a, b: string, isDir: bool) =
  makeDir(parentDir(b))
  when defined(nimscript):
    if isDir: mvDir(a, b) else: mvFile(a, b)
  else:
    if isDir: moveDir(a, b) else: moveFile(a, b)

proc removeIt(p: string, isDir: bool) =
  when defined(nimscript):
    if isDir: rmDir(p) else: rmFile(p)
  else:
    if isDir: removeDir(p) else: removeFile(p)

# ── the tab ──

proc home(): string = getHomeDir().strip(leading = false, chars = {'/'})

proc titleOf(dir: string): string =
  ## the tab's name: the folder (~ for your home), ending with /
  let h = home()
  result = if h.len > 0 and (dir == h or dir.startsWith(h & "/")): "~" & dir[h.len .. ^1] else: dir
  if not result.endsWith("/"): result.add "/"

proc dirOf(b: Buf): string =
  ## the folder a tab of ours lists (its name says it: what survives the plugin starting again)
  var t = b.title
  if t.startsWith("~"): t = home() & t[1 .. ^1]
  if t.len > 1: t = t.strip(leading = false, chars = {'/'})
  t

proc ours(b: Buf): bool = b.valid and b.path.len == 0 and b.lang.toLowerAscii == "oil" and dirExists(b.dirOf)

proc trashDir(): string = dataDir() / "trash"

proc marks(b: Buf, lines: seq[string]) =
  b.clearDecorations()
  let inTrash = b.dirOf == trashDir()
  var whence: Table[string, string]
  if inTrash and fileExists(trashDir() / ".where"):
    for l in readFile(trashDir() / ".where").splitLines:
      let k = l.find('\t')
      if k > 0: whence[l[0 ..< k]] = l[k + 1 .. ^1]
  for i, l in lines:
    if l.endsWith("/"): b.sign(i, "▸", "accent")
    if inTrash and l.strip(leading = false, chars = {'/'}) in whence:
      b.virtualText(i, "from " & whence[l.strip(leading = false, chars = {'/'})])

proc show(b: Buf, dir: string) =
  let lines = entries(dir, showHidden.getOrDefault(b.id, setting("hidden", false)))
  listed[b.id] = lines
  b.setText(lines.join("\n"))
  b.setTitle(titleOf(dir))
  b.markSaved()
  b.setCursor(pos(0, 0))
  b.marks(lines)

proc openDir(dir: string, from_name = "") =
  if not dirExists(dir):
    warn("No folder " & dir)
    return
  let b = newTab(titleOf(dir), "", "oil")
  if b.dirty: return                   # (that folder's tab has edits not saved: to it, as it is)
  b.show(dir)
  if from_name.len > 0:
    let ls = listed[b.id]
    for i, l in ls:
      if l == from_name or l == from_name & "/":
        b.setCursor(pos(i, 0))

proc goTo(b: Buf, dir: string, from_name = "") =
  ## the tab shows another folder (its edits not saved: asked first)
  if b.dirty and not confirm("This folder's tab has changes not saved. Leave them?"): return
  b.show(dir)
  if from_name.len > 0:
    for i, l in listed[b.id]:
      if l == from_name or l == from_name & "/": b.setCursor(pos(i, 0))

proc folderOfCurrent(): (string, string) =
  ## the folder to open, and the name to put the cursor on
  let b = current()
  if b.valid and b.ours: return (parentDir(b.dirOf), extractFilename(b.dirOf))
  if b.valid and b.path.len > 0: return (parentDir(b.path), extractFilename(b.path))
  (projectRoot(), "")

proc openUnder(b: Buf) =
  if not b.ours:
    message("Not a folder's tab — \"Oil: edit this file's folder as text\" opens one")
    return
  let name = b.line(b.cursor.line).strip
  if name.len == 0: return
  let dir = b.dirOf
  let target = if name.startsWith("/"): name else: dir / name.strip(leading = false, chars = {'/'})
  if dirExists(target): b.goTo(target)
  elif fileExists(target): discard openFile(target)
  else: message(name & " is not there yet — save to make it")

proc up(b: Buf) =
  if not b.ours: return
  let d = b.dirOf
  if d == "/" or parentDir(d) == d: return
  b.goTo(parentDir(d), extractFilename(d))

# ── saving: what changed, then do it ──

type
  Change = object
    kind: string                       # rename delete create
    a, b: string                       # the names (as written in the tab)

proc similar(a, b: string): float =
  ## how alike two names are: the characters they share in order, against the longer (0 … 1)
  if a.len == 0 or b.len == 0: return 0.0
  var row = newSeq[int](b.len + 1)
  for i in 1 .. a.len:
    var prev = 0
    for j in 1 .. b.len:
      let keep = row[j]
      row[j] = if a[i - 1] == b[j - 1]: prev + 1 else: max(row[j], row[j - 1])
      prev = keep
  row[b.len] / max(a.len, b.len)

proc pairUp(gone, added: seq[string], res: var seq[Change]) =
  ## a run of lines gone and lines added between two kept ones: one for one — a line changed in place, a rename
  ## (emptied: a delete); more — the alike names of the same kind are renames (a folder only to a folder), the
  ## rest deletes and new files
  var usedG = newSeq[bool](gone.len)
  var usedA = newSeq[bool](added.len)
  if gone.len == 1 and added.len == 1:
    if added[0].len == 0: res.add Change(kind: "delete", a: gone[0])
    elif gone[0].endsWith("/") == added[0].endsWith("/"): res.add Change(kind: "rename", a: gone[0], b: added[0])
    else:
      res.add Change(kind: "delete", a: gone[0])
      res.add Change(kind: "create", b: added[0])
    return
  var cands: seq[(float, int, int)]
  for x in 0 ..< gone.len:
    for y in 0 ..< added.len:
      if added[y].len == 0 or gone[x].endsWith("/") != added[y].endsWith("/"): continue
      let sc = similar(gone[x].strip(leading = false, chars = {'/'}), added[y].strip(leading = false, chars = {'/'}))
      if sc >= 0.5: cands.add (sc, x, y)
  cands.sort(proc(p, q: (float, int, int)): int = cmp(q[0], p[0]))
  for (_, x, y) in cands:
    if usedG[x] or usedA[y]: continue
    res.add Change(kind: "rename", a: gone[x], b: added[y])
    usedG[x] = true
    usedA[y] = true
  for x in 0 ..< gone.len:
    if not usedG[x]: res.add Change(kind: "delete", a: gone[x])
  for y in 0 ..< added.len:
    if not usedA[y] and added[y].len > 0: res.add Change(kind: "create", b: added[y])

proc plan(old, now: seq[string]): seq[Change] =
  ## the lines compared (their longest common part kept): a line changed in place is a rename, a line gone a
  ## delete, a new line a create
  let n = old.len
  let m = now.len
  var L = newSeq[seq[int]](n + 1)
  for i in 0 .. n: L[i] = newSeq[int](m + 1)
  for i in countdown(n - 1, 0):
    for j in countdown(m - 1, 0):
      L[i][j] = if old[i] == now[j]: L[i + 1][j + 1] + 1 else: max(L[i + 1][j], L[i][j + 1])
  var i, j = 0
  var gone, added: seq[string]
  proc flush(res: var seq[Change]) =
    pairUp(gone, added, res)
    gone.setLen(0)
    added.setLen(0)
  while i < n or j < m:
    if i < n and j < m and old[i] == now[j]:
      flush(result)
      inc i
      inc j
    elif j < m and (i == n or L[i][j + 1] >= L[i + 1][j]):
      added.add now[j]
      inc j
    else:
      gone.add old[i]
      inc i
  flush(result)
  # (a line moved — cut here, put there — is no change: the listing is sorted anyway)
  var keep: seq[Change]
  for c in result:
    var moved = false
    for d in result:
      if (c.kind == "delete" and d.kind == "create" and d.b == c.a) or
         (c.kind == "create" and d.kind == "delete" and d.a == c.b): moved = true
    if not moved: keep.add c
  result = keep

proc full(dir, name: string): string =
  let n = name.strip(leading = false, chars = {'/'})
  if n.startsWith("/"): n elif n.startsWith("~/"): home() & n[1 .. ^1] else: normalizedPath(dir / n)

proc describe(c: Change): string =
  case c.kind
  of "rename": "Rename " & c.a & " → " & c.b
  of "delete": "Delete " & c.a & (if setting("trash", true): " (to the trash)" else: " (gone for good)")
  else: "Make " & c.b & (if c.b.endsWith("/"): " (a folder)" else: "")

proc check(dir: string, cs: seq[Change], now: seq[string]): string =
  ## what is wrong with the changes ("" nothing)
  var seen: Table[string, bool]
  for l in now:
    if l.len == 0: continue
    if l in seen: return "Two lines name " & l
    seen[l] = true
  var leaving: Table[string, bool]
  for c in cs:
    if c.kind in ["rename", "delete"]: leaving[full(dir, c.a)] = true
  for c in cs:
    if c.kind == "create" or c.kind == "rename":
      let t = full(dir, c.b)
      if (fileExists(t) or dirExists(t)) and t notin leaving: return c.b & " is there already"
  ""

proc toTrash(p: string, isDir: bool) =
  let t = trashDir()
  makeDir(t)
  var name = extractFilename(p)
  var n = 1
  while fileExists(t / name) or dirExists(t / name):
    name = extractFilename(p) & "." & $n
    inc n
  moveIt(p, t / name, isDir)
  let w = t / ".where"
  let before = if fileExists(w): readFile(w) else: ""
  writeFile(w, before & name & "\t" & p & "\n")

proc apply(b: Buf) =
  let dir = b.dirOf
  var now: seq[string]                 # (an emptied line kept, as "": it says where a name went)
  var lines = b.lines
  while lines.len > 0 and lines[^1].strip.len == 0: lines.setLen(lines.len - 1)
  for l in lines: now.add l.strip
  let old = listed.getOrDefault(b.id, entries(dir, showHidden.getOrDefault(b.id, setting("hidden", false))))
  let cs = plan(old, now)
  if cs.len == 0:
    b.show(dir)
    message("Nothing to change in " & titleOf(dir))
    return
  let bad = check(dir, cs, now)
  if bad.len > 0:
    warn(bad & " — nothing was changed")
    return
  var text: seq[string]
  for c in cs: text.add c.describe
  if not confirm(text.join("\n") & "\n\nDo it?"): return
  var done = 0
  var failed = ""
  # (renames to the side first: a → b and b → a both work)
  var moving: seq[(string, string, bool)]
  for c in cs:
    try:
      case c.kind
      of "rename":
        let a = full(dir, c.a)
        let tmp = a & ".oil-" & $moving.len
        moveIt(a, tmp, c.a.endsWith("/"))
        moving.add (tmp, full(dir, c.b), c.a.endsWith("/"))
      of "delete":
        let a = full(dir, c.a)
        if setting("trash", true): toTrash(a, c.a.endsWith("/")) else: removeIt(a, c.a.endsWith("/"))
        inc done
      else:
        let t = full(dir, c.b)
        if c.b.endsWith("/"): makeDir(t)
        else:
          makeDir(parentDir(t))
          writeFile(t, "")
        inc done
    except CatchableError as e:
      failed = c.describe & ": " & e.msg
      break
  for (tmp, dst, isDir) in moving:
    try:
      moveIt(tmp, dst, isDir)
      inc done
    except CatchableError as e:
      if failed.len == 0: failed = "Rename to " & dst & ": " & e.msg
  b.show(dir)
  if failed.len > 0: warn(failed)
  else: message($done & (if done == 1: " change made in " else: " changes made in ") & titleOf(dir))

onSaveTab("oil", proc(ev: Event) = apply(ev.buf))

onChange("lang:oil", proc(ev: Event) =
  var ls: seq[string]
  for l in ev.buf.lines: ls.add l.strip
  ev.buf.marks(ls))

# ── commands and keys ──

command "Oil: edit this file's folder as text":
  let (d, name) = folderOfCurrent()
  openDir(d, name)

command "Oil: open the folder under the cursor (or the file)":
  openUnder(current())

command "Oil: the folder above":
  let b = current()
  if b.ours: b.up()
  else:
    let (d, name) = folderOfCurrent()
    openDir(d, name)

command "Oil: show or hide hidden files":
  let b = current()
  if not b.ours: message("Not a folder's tab")
  else:
    showHidden[b.id] = not showHidden.getOrDefault(b.id, setting("hidden", false))
    b.goTo(b.dirOf)

command "Oil: open the trash":
  makeDir(trashDir())
  openDir(trashDir())

keyIn("oil", "alt+enter", "open the folder or file under the cursor", proc(b: Buf) = openUnder(b))
keyIn("oil", "alt+up", "the folder above", proc(b: Buf) = up(b))
nmapIn("oil", "<CR>", "open the folder or file under the cursor", proc(count: int) = openUnder(current()))
nmapIn("oil", "-", "the folder above", proc(count: int) = up(current()))
nmap("<leader>-", "the folder of this file as text (oil)", proc(count: int) =
  let (d, name) = folderOfCurrent()
  openDir(d, name))
