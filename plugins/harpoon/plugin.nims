## harpoon — pin the few files of a project you work on and jump to them with one key or one tap
##
##   Harpoon: add this file                 at the end of the list (4 files at most: the size setting)
##   Harpoon: the list…    (Alt+Shift+H)    the files: pick one to go there; also add, remove, move up, clear
##   Harpoon: go to 1 … Harpoon: go to 4    Harpoon: next · Harpoon: previous (round the list)
##   Harpoon: remove this file · Harpoon: remove a file… · Harpoon: move a file up… · Harpoon: clear the list
##   the Plugins dock      HARPOON: the files (● the one you are in) — tap one to open it, or + to add the file you
##                         are in
##   Each project (the folder ned has open) has its own list, kept in the plugin's data folder; each file opens at
##   the line you were on when you left it (for another tab, or when ned quit) or last saved it.
##   vim                   <leader>a add · <leader>h the list · <leader>1 … <leader>4 go to one
##   settings              plugins.harpoon.size — how many files the list holds
import nedplugin

requiresNed(">= 6.26")

settingDef("size", 4, "How many files Harpoon's list holds (Harpoon: go to 1 … 4 and <leader>1 … 4 reach the " &
           "first four; the list and the Plugins dock all of them)")

type Pin = object
  path: string                   ## from the project's folder (or absolute, for a file outside it)
  line: int                      ## the line it opens at (from 0)

var
  store: JsonNode                # every project's list: {"/the/project": [{"path": …, "line": …}]}
  storeFile = ""

proc load() =
  ## the lists, from the data folder (once)
  if store != nil: return
  storeFile = dataDir() / "harpoon.json"
  store = newJObject()
  if fileExists(storeFile):
    try:
      let j = parseJson(readFile(storeFile))
      if j.kind == JObject: store = j
    except CatchableError: discard

proc pins(): seq[Pin] =
  ## this project's list
  load()
  for x in store{projectRoot()}.getElems:
    if x{"path"}.getStr.len > 0: result.add Pin(path: x{"path"}.getStr, line: max(0, x{"line"}.getInt))

proc save(ps: seq[Pin]) =
  load()
  var a = newJArray()
  for p in ps: a.add %*{"path": p.path, "line": p.line}
  store[projectRoot()] = a
  writeData("harpoon.json", store.pretty & "\n")       # (its own data folder: no permission needed)
  refreshView("Harpoon")

proc listSize(): int = max(1, setting("size", 4))

func plural(n: int, word: string): string = $n & " " & word & (if n == 1: "" else: "s")

proc relPath(path: string): string =
  ## the path from the project's folder, when the file is in it
  let root = projectRoot()
  if root.len > 0 and path.startsWith(root & "/"): path[root.len + 1 .. ^1] else: path

proc absPath(p: string): string =
  if p.isAbsolute: p else: projectRoot() / p

func indexOf(ps: seq[Pin], rel: string): int =
  for i, p in ps:
    if p.path == rel: return i
  -1

func where(p: Pin): string =
  ## the folder a pinned file is in, and its line
  let d = p.path.parentDir
  (if d.len > 0 and d != ".": d & " · " else: "") & "line " & $(p.line + 1)

proc currentFile(): string =
  ## the file being edited, from the project's folder ("" for an unsaved tab)
  let b = current()
  if not b.valid: return ""
  let p = b.path
  if p.len == 0: "" else: relPath(p)

proc remember(b: Buf) =
  ## the cursor's line of the file, when it is in the list (where it opens next time)
  if not b.valid: return
  let p = b.path
  if p.len == 0: return
  var ps = pins()
  let i = ps.indexOf(relPath(p))
  if i >= 0:
    let l = b.cursor.line
    if ps[i].line != l:
      ps[i].line = l
      save(ps)

proc addThis() =
  let b = current()
  let f = currentFile()
  if f.len == 0:
    message("Harpoon: this tab is not a file yet — save it first")
    return
  var ps = pins()
  let i = ps.indexOf(f)
  if i >= 0:
    remember(b)
    message("Harpoon: " & extractFilename(f) & " is number " & $(i + 1) & " already")
    return
  if ps.len >= listSize():
    message("Harpoon: the list is full (" & plural(listSize(), "file") & ") — remove one first (Harpoon: the list…)")
    return
  ps.add Pin(path: f, line: b.cursor.line)
  save(ps)
  message("Harpoon: " & extractFilename(f) & " is number " & $ps.len)

proc goTo(i: int) =
  ## the i-th file (from 0) opened at its line
  let ps = pins()
  if i < 0 or i >= ps.len:
    message(if ps.len == 0: "Harpoon: no files in the list yet (Harpoon: add this file)"
            else: "Harpoon: there is no file " & $(i + 1) & " — the list has " & $ps.len)
    return
  remember(current())
  let p = ps[i]
  let full = absPath(p.path)
  if not fileExists(full):
    message("Harpoon: " & p.path & " is not there any more (Harpoon: remove a file…)")
    return
  discard openFile(full, p.line)
  refreshView("Harpoon")

proc step(d: int) =
  ## the next (d = 1) or the previous (d = -1) file of the list, round it
  let ps = pins()
  if ps.len == 0:
    message("Harpoon: no files in the list yet (Harpoon: add this file)")
    return
  let i = ps.indexOf(currentFile())
  goTo(if i < 0: (if d > 0: 0 else: ps.high) else: (i + d + ps.len) mod ps.len)

proc pickFile(title: string): int =
  ## one of the list's files, chosen (-1: none)
  let ps = pins()
  if ps.len == 0:
    message("Harpoon: no files in the list yet (Harpoon: add this file)")
    return -1
  var items, details: seq[string]
  for i, p in ps:
    items.add $(i + 1) & "  " & extractFilename(p.path)
    details.add where(p)
  pick(title, items, details)

proc removeAt(i: int) =
  var ps = pins()
  if i < 0 or i >= ps.len: return
  let f = ps[i].path
  ps.delete(i)
  save(ps)
  message("Harpoon: " & extractFilename(f) & " is out of the list")

proc moveUp(i: int) =
  var ps = pins()
  if i < 0 or i >= ps.len: return
  if i == 0:
    message("Harpoon: " & extractFilename(ps[0].path) & " is first already")
    return
  swap(ps[i], ps[i - 1])
  save(ps)
  message("Harpoon: " & extractFilename(ps[i - 1].path) & " is number " & $i & " now")

proc clearList() =
  if pins().len == 0:
    message("Harpoon: the list is empty already")
  elif confirm("Take every file out of Harpoon's list for this project?"):
    save(@[])
    message("Harpoon: the list is empty")

proc theList() =
  ## the files to pick from, and what to do with the list
  let ps = pins()
  let f = currentFile()
  var items, details: seq[string]
  var acts: seq[string]
  for i, p in ps:
    items.add $(i + 1) & "  " & extractFilename(p.path) & (if p.path == f: "  ●" else: "")
    details.add where(p)
    acts.add "go"
  if f.len > 0 and ps.indexOf(f) < 0 and ps.len < listSize():
    items.add "+ Add this file"
    details.add f
    acts.add "add"
  if ps.len > 0:
    for (t, d, a) in [("Remove a file from the list…", "", "remove"), ("Move a file up…", "", "up"),
                      ("Clear the list", "every file out", "clear")]:
      items.add t
      details.add d
      acts.add a
  if items.len == 0:
    message("Harpoon: no files in the list yet, and this tab is not a file (save it first)")
    return
  let k = pick("Harpoon — " & $ps.len & " of " & plural(listSize(), "file"), items, details)
  if k < 0: return
  case acts[k]
  of "go": goTo(k)
  of "add": addThis()
  of "remove": removeAt(pickFile("Take which file out of the list?"))
  of "up": moveUp(pickFile("Move which file up?"))
  of "clear": clearList()
  else: discard

command "Harpoon: add this file": addThis()
command "Harpoon: the list…", "alt+shift+h": theList()
command "Harpoon: next": step(1)
command "Harpoon: previous": step(-1)
command "Harpoon: remove this file":
  let i = pins().indexOf(currentFile())
  if i < 0: message("Harpoon: this file is not in the list")
  else: removeAt(i)
command "Harpoon: remove a file…": removeAt(pickFile("Take which file out of the list?"))
command "Harpoon: move a file up…": moveUp(pickFile("Move which file up?"))
command "Harpoon: clear the list": clearList()

proc goKeys(i: int) =
  ## (a factory: the command and the vim key of one place in the list)
  command("Harpoon: go to " & $(i + 1)): goTo(i)
  nmap("<leader>" & $(i + 1), "harpoon: go to file " & $(i + 1)) do (count: int): goTo(i)

for i in 0 ..< 4: goKeys(i)

nmap("<leader>a", "harpoon: add this file") do (count: int): addThis()
nmap("<leader>h", "harpoon: the list of files") do (count: int): theList()

# where each file opens next time: the line you were on when you left it for another tab (or quit), or saved it
var shown = -1                           # the tab in front (its line is remembered when another one comes)

onEnter("*") do (ev: Event):
  if shown >= 0 and shown != ev.buf.id:
    try: remember(Buf(id: shown))
    except CatchableError: discard       # (that tab was closed)
  shown = ev.buf.id
  refreshView("Harpoon")                 # (the ● of the file you are in)
onSave("*") do (ev: Event):
  if ev.path.len > 0 and pins().indexOf(relPath(ev.path)) >= 0: remember(ev.buf)
onQuit() do (ev: Event):
  remember(current())

view("Harpoon") do () -> seq[ViewItem]:
  let ps = pins()
  let f = currentFile()
  for i, p in ps:
    result.add ViewItem(text: $(i + 1) & "  " & extractFilename(p.path), detail: where(p), id: $i,
                        icon: (if p.path == f: "●" else: "○"), color: (if p.path == f: "accent" else: ""))
  if f.len > 0 and ps.indexOf(f) < 0 and ps.len < listSize():
    result.add ViewItem(text: "+ add " & extractFilename(f), detail: "the file you are in", id: "add", color: "hint")
  if result.len == 0: result.add ViewItem(text: "(no files yet — open one and Harpoon: add this file)", color: "hint")
do (id: string):
  if id == "add": addThis()
  elif id.len > 0 and id[0] in Digits: goTo(parseInt(id))
