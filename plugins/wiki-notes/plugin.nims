## wiki-notes — Markdown notes linked with [[links]]: followed (a new note made), completed, and the open note's backlinks
##
##   Wiki: follow the link     (Alt+Shift+O in Markdown; vim: Enter) the [[link]] at the cursor: its note opens —
##                             at its heading for [[Note#Heading]] —, or is made when there is none yet (# Note in
##                             it), beside the note the link is in
##   Wiki: backlinks…          the notes that link to the open one, each line that does, to choose from
##   Wiki: find a note…        every note, to choose from
##   Wiki: new note…           its name; the note made — or opened, when there is one of that name
##   completion                after [[ the notes' names; after [[Note# its headings
##   hover                     over a [[link]]: the start of its note, or that there is none yet
##   the Plugins dock          BACKLINKS: the notes that link to the note in front, with each line that does — tap
##                             one to go there
##   problems                  a [[link]] to a note there is none of yet: a hint, until the note is made
##   settings                  plugins.wiki-notes.folder — where the notes are: "" the project's folder, or one of
##                             your own (~/notes) · .markMissing — the hints of links to no note (true)
##
## A link names a note by its file's name without .md — [[Shopping list]] is `Shopping list.md` — in any case, with -
## or _ in place of its spaces too (`shopping-list.md`); [[Note|the text shown]] and [[Note#A heading]] as well. The
## notes are the .md files of the folder and of the folders in it (not hidden ones). A note made in the project is
## saved at once; one in a folder of your own outside it is left for you to save.
import nedplugin
import std/algorithm

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("folder", "", "Wiki: where the notes are — empty for the project's folder, or a folder (~/notes)")
settingDef("markMissing", true, "Wiki: a [[link]] to a note there is none of yet is marked (a hint)")

const
  View = "BACKLINKS"
  SkipDirs = ["node_modules", "nimcache", "build", "dist", "vendor"]

type
  Link* = object
    target*, heading*, shown*: string    # [[target#heading|shown]]
    line*, a*, b*: int                   # where: its line, from [[ up to after ]]

# ── links ──

func linksOf*(line: string, ln: int): seq[Link] =
  ## the [[links]] of a line (not in `code`)
  var i = 0
  var code = false
  while i + 1 < line.len:
    if line[i] == '`': code = not code
    if not code and line[i] == '[' and line[i + 1] == '[':
      let e = line.find("]]", i + 2)
      if e < 0: break
      let inner = line[i + 2 ..< e]
      if inner.len > 0 and '[' notin inner and '\n' notin inner:
        var t = inner
        var shown = ""
        let bar = t.find('|')
        if bar >= 0:
          shown = t[bar + 1 .. ^1].strip
          t = t[0 ..< bar]
        var heading = ""
        let h = t.find('#')
        if h >= 0:
          heading = t[h + 1 .. ^1].strip
          t = t[0 ..< h]
        result.add Link(target: t.strip, heading: heading, shown: shown, line: ln, a: i, b: e + 2)
      i = e + 2
      continue
    inc i

func norm*(name: string): string =
  ## a note's name as links match it: lower case, - and _ as spaces, one space between words
  var s = name.toLowerAscii
  for c in s.mitems:
    if c in {'-', '_'}: c = ' '
  s.splitWhitespace.join(" ")

func stemOf(path: string): string =
  ## a note's name: its file name without the .md
  let n = extractFilename(path)
  if n.toLowerAscii.endsWith(".md"): n[0 ..< ^3] else: n

func headingLine*(lines: seq[string], heading: string): int =
  ## the line of a heading of the note (any level, any case); -1 none
  let want = norm(heading)
  for i, l in lines:
    if l.startsWith("#"):
      if norm(l.strip(chars = {'#', ' '})) == want: return i
  -1

# ── the notes ──

proc folder(): string =
  ## the folder the notes are in: plugins.wiki-notes.folder (with ~ expanded), the project's folder when it is empty
  let f = setting("folder", "").strip
  if f.len == 0: projectRoot() else: expandTilde(f)

var
  known: seq[string]              # the notes as last read …
  knownAt = -1.0                  # … when (unixTime), and of which folder
  knownIn = ""

proc notes*(): seq[string] =
  ## the notes: the .md files of the folder and the folders in it (hidden ones left out), in order — read again
  ## after a few seconds, or when a note is saved
  let f = folder()
  let now = unixTime()
  if f == knownIn and knownAt >= 0 and now - knownAt < 5: return known
  var todo = @[f]
  while todo.len > 0 and result.len < 5000:
    let d = todo.pop
    if not dirExists(d): continue
    for kind, p in walkDir(d):
      let name = extractFilename(p)
      if name.startsWith("."): continue
      if kind in {pcDir, pcLinkToDir}:
        if name notin SkipDirs: todo.add p
      elif name.toLowerAscii.endsWith(".md"): result.add p
  result.sort()
  known = result
  knownAt = now
  knownIn = f

proc findNote(name: string, notesNow: seq[string]): string =
  ## the note a link's name names ("": none) — of several, the one nearest the folder's top; a path in the name
  ## ([[projects/Ideas]]) is the note's name after its last /
  let want = norm(name.split('/')[^1])
  var best = ""
  for p in notesNow:
    if norm(stemOf(p)) == want and (best.len == 0 or p.count('/') < best.count('/')): best = p
  best

proc noteLines(path: string): seq[string] =
  ## a note's lines: its tab's when it is open, else its file's
  for b in buffers():
    if b.path == path: return b.lines
  if fileExists(path): result = readFile(path).replace("\r\n", "\n").split('\n')

proc inFolder(path: string): bool =
  ## whether the path is a .md file in the notes' folder or under it
  let f = folder()
  path.toLowerAscii.endsWith(".md") and (path.startsWith(f & "/") or parentDir(path) == f)

func linkAt*(line: string, ln, col: int): (bool, Link) =
  ## the [[link]] of the line that the column is in, or on its brackets (false when there is none)
  for l in linksOf(line, ln):
    if col >= l.a and col <= l.b: return (true, l)

func safeName(name: string): string =
  ## a note's name as a file's: no / \ : * ? " < > |
  for c in name.strip:
    result.add (if c in {'/', '\\', ':', '*', '?', '"', '<', '>', '|'}: '-' else: c)

# ── making and opening notes ──

proc makeNote(name, nearDir: string) =
  ## a new note, `# name` in it, in `nearDir` (else the folder) — saved when it is in the project
  let dir = if nearDir.len > 0 and (nearDir == folder() or nearDir.startsWith(folder() & "/")): nearDir
            else: folder()
  let p = dir / safeName(name) & ".md"
  let b = openFile(p)
  if not b.valid:
    warn("Wiki: " & p & " could not be made")
    return
  if b.lineCount <= 1 and b.line(0).len == 0:
    b.setText("# " & name.strip & "\n\n")
    b.setCursor(pos(2, 0))
  try:
    b.save()
    knownAt = -1
    message("Wiki: the note " & name.strip & " made — " & p)
  except ValueError:
    message("Wiki: the note " & name.strip & " is in a tab — save it to make it (Ctrl+S)")
  refreshView(View)

proc follow(b: Buf): bool =
  ## the link at the cursor followed; false when there is none there
  let p = b.cursor
  let (found, l) = linkAt(b.line(p.line), p.line, p.col)
  if not found or l.target.len == 0:
    if found and l.heading.len > 0:                # [[#heading]]: a heading of this note
      let h = headingLine(b.lines, l.heading)
      if h >= 0: b.setCursor(pos(h, 0))
      return true
    return false
  let path = findNote(l.target, notes())
  if path.len == 0:
    makeNote(l.target, (if b.path.len > 0: parentDir(b.path) else: ""))
    return true
  var line = -1
  if l.heading.len > 0:
    line = headingLine(noteLines(path), l.heading)
    if line < 0: message("Wiki: " & stemOf(path) & " has no heading “" & l.heading & "”")
  discard openFile(path, line)
  true

proc followOrSay(b: Buf) =
  ## follows the link at the cursor; when there is none it says so in a message
  if not follow(b): message("Wiki: put the cursor on a [[link]]")

# ── backlinks ──

type Back* = object
  path*: string
  line*: int
  text*: string

proc backlinks*(target: string): seq[Back] =
  ## every line of every note that links to the note `target` (its path)
  let want = norm(stemOf(target))
  let all = notes()
  for p in all:
    if p == target: continue
    let ls = noteLines(p)
    for i, l in ls:
      if "[[" notin l: continue
      for k in linksOf(l, i):
        if norm(k.target.split('/')[^1]) == want:
          result.add Back(path: p, line: i, text: l.strip)
          break

# ── problems: links to no note ──

var marked: seq[int]              # the tabs whose links were marked (to clear when they have none any more)

proc markMissing(b: Buf) =
  ## marks each [[link]] of the tab whose note does not exist yet with a hint saying that following it makes the note,
  ## unless plugins.wiki-notes.markMissing is off; a tab without links does not read the notes, and loses the marks it
  ## had
  var links: seq[Link]
  if setting("markMissing", true):
    for i, l in b.lines:
      if "[[" in l: links.add linksOf(l, i)
  if links.len == 0:
    # (no links: the notes are not read; marks of before taken away)
    if b.id in marked:
      b.clearProblems()
      marked.delete(marked.find(b.id))
    return
  var names: seq[string]
  for p in notes(): names.add norm(stemOf(p))
  var ps: seq[Problem]
  for k in links:
    if k.target.len > 0 and norm(k.target.split('/')[^1]) notin names:
      ps.add Problem(range: rng(pos(k.line, k.a), pos(k.line, k.b)), severity: 4,
                     message: "no note “" & k.target & "” yet — Wiki: follow the link makes it")
  b.setProblems(ps)
  if b.id notin marked: marked.add b.id

# ── commands, keys ──

command "Wiki: follow the link":
  followOrSay(current())

keyIn("markdown", "alt+shift+o", "follow the [[link]] (or make its note)", proc(b: Buf) = followOrSay(b))

proc enterKey(count: int) =
  ## vim's Enter in a Markdown file: follows the [[link]] at the cursor, else goes to the first letter of the line below
  ## (count lines down)
  let b = current()
  if not follow(b):
    # (vim's Enter, where there is no link: the next line's first letter)
    let n = min(b.lineCount - 1, b.cursor.line + max(1, count))
    let l = b.line(n)
    b.setCursor(pos(n, l.len - l.strip(trailing = false).len))

nmapIn("markdown", "<CR>", "follow the [[link]], else the next line", enterKey)

command "Wiki: backlinks…":
  let b = current()
  if b.path.len == 0 or not inFolder(b.path):
    message("Wiki: open a note (a .md file of " & folder() & ")")
  else:
    let bs = backlinks(b.path)
    if bs.len == 0: message("Wiki: no note links to " & stemOf(b.path))
    else:
      var items, dets: seq[string]
      for x in bs:
        items.add stemOf(x.path)
        dets.add x.text
      let i = pick("Notes that link to " & stemOf(b.path) & " (" & $bs.len & ")", items, dets)
      if i >= 0: discard openFile(bs[i].path, bs[i].line)

command "Wiki: find a note…":
  let all = notes()
  if all.len == 0: message("Wiki: no notes in " & folder() & " yet — Wiki: new note…")
  else:
    var items, dets: seq[string]
    let f = folder()
    for p in all:
      items.add stemOf(p)
      dets.add (if p.startsWith(f & "/"): parentDir(p[f.len + 1 .. ^1]) else: parentDir(p))
    let i = pick("Notes (" & $all.len & ")", items, dets)
    if i >= 0: discard openFile(all[i])

command "Wiki: new note…":
  let name = ask("Wiki: the new note's name:")
  if name.strip.len > 0:
    let have = findNote(name, notes())
    if have.len > 0:
      discard openFile(have)
      message("Wiki: there is a note " & stemOf(have) & " already")
    else:
      let b = current()
      makeNote(name, (if b.path.len > 0 and inFolder(b.path): parentDir(b.path) else: ""))

# ── completion, hover ──

completions("markdown") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  let l = b.line(p.line)
  let before = l[0 ..< min(p.col, l.len)]
  let open = before.rfind("[[")
  if open >= 0 and "]]" notin before[open .. ^1]:
    let inner = before[open + 2 .. ^1]
    let after = l[min(p.col, l.len) .. ^1]
    let close = if after.startsWith("]]"): "" else: "]]"
    let h = inner.find('#')
    if h >= 0:
      let path = findNote(inner[0 ..< h], notes())
      for x in noteLines(path):
        if x.startsWith("#"):
          let t = x.strip(chars = {'#', ' '})
          result.add CompletionItem(label: t, insert: t & close, kind: "text", detail: "a heading")
    else:
      for path in notes():
        if path == b.path: continue
        let s = stemOf(path)
        result.add CompletionItem(label: s, insert: s & close, kind: "file", detail: "a note")

hover("markdown") do (b: Buf, p: Pos) -> string:
  let (found, l) = linkAt(b.line(p.line), p.line, p.col)
  if not found or l.target.len == 0: return ""
  let path = findNote(l.target, notes())
  if path.len == 0: return "**" & l.target & "** — no note yet (Wiki: follow the link makes it)"
  let ls = noteLines(path)
  var start = 0
  if l.heading.len > 0: start = max(0, headingLine(ls, l.heading))
  var shown: seq[string]
  for i in start ..< min(ls.len, start + 12): shown.add ls[i]
  "**" & stemOf(path) & "**\n\n" & shown.join("\n").strip

# ── the dock, the events ──

view(View) do () -> seq[ViewItem]:
  let b = current()
  let p = if b.valid: b.path else: ""
  if p.len == 0 or not inFolder(p):
    result.add ViewItem(text: "open a note to see what links to it", icon: "·", color: "hint")
    return
  let bs = backlinks(p)
  result.add ViewItem(text: stemOf(p), icon: "◆", color: "accent",
                      detail: (if bs.len == 0: "no backlinks" else: $bs.len & " link" & (if bs.len == 1: "" else: "s")))
  var last = ""
  for x in bs:
    if x.path != last:
      result.add ViewItem(text: stemOf(x.path), icon: "▸", path: x.path, line: x.line)
      last = x.path
    result.add ViewItem(text: x.text, icon: "•", path: x.path, line: x.line, depth: 1)

onEnter("*.md") do (ev: Event):
  refreshView(View)

onOpen("*.md") do (ev: Event):
  if inFolder(ev.path): markMissing(ev.buf)

onChange("*.md") do (ev: Event):
  if inFolder(ev.path): markMissing(ev.buf)

onSave("*.md") do (ev: Event):
  knownAt = -1                    # (a note saved may be a new one)
  refreshView(View)
  # (a note saved may be one others link to: their marks again)
  for b in buffers():
    let p = b.path
    if p.len > 0 and inFolder(p): markMissing(b)
