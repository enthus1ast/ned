# the open buffers: finding one by id or path, the jump history, centring the view on a position and opening a file in a
# tab; it also declares the tables behind the special tabs (multibuffer, commit message, rebase plan, change-signature
# plan)
proc bufById(id: int): Buffer =
  ## the open buffer with this id, or nil — ids stay the same when tabs move, unlike indexes
  for b in bufs:
    if b.id == id: return b
  nil

proc bufIndexByPath(path: string): int =
  ## the tab index of the buffer that has this file open, or -1
  for i, b in bufs:
    if b.path == path: return i
  -1

proc pushJump() =
  ## notes the cursor's place in the file (up to 100 places are kept) so that Jump back can return to it; a new jump
  ## empties the forward history. Buffers without a file are not noted.
  let b = buf()
  if b.path.len == 0: return
  jumpStack.add (b.path, b.primary.head)
  if jumpStack.len > 100: jumpStack.delete(0)
  fwdStack.setLen(0)                    # a new jump: nothing to go forward to

proc centerOn(b: Buffer, p: Pos) =
  ## puts the only cursor at `p` (opening a fold that hides it) and scrolls so that its line is a third of the way
  ## down the text area; also notes the line, so that the screen lights it up for a moment when that setting is on
  if cfgJumpHl and gRaw:
    landBuf = b.id                      # (the line it lands on lights up for a moment: ui.jumpHighlight)
    landLine = p.line
    landAt = getMonoTime()
  if b.isHidden(p.line): b.unfoldLine(p.line)     # (a jump into a folded part opens it)
  b.setSingle(p)
  (b.topLine, b.topSub) = b.stepBack(p.line, 0, max(0, textH div 3))
  b.lastHead = p
  b.lastChange = b.changeId

proc loadBuffer(path: string): Buffer =
  ## returns an existing or newly loaded (not focused) buffer
  let full = absolutePath(path).normalizedPath
  let i = bufIndexByPath(full)
  if i >= 0: return bufs[i]
  let b = newBuffer()
  if not b.loadFile(full): return nil
  bufs.add b
  lspAttach(b)
  refreshGit(b)
  b

proc cmdMergeEditor()

proc openWorkspace(f: string): bool

proc isLibraryFile(path: string): bool

proc openFile(path: string, line = -1, col = -1): Buffer =
  ## opens a file in a tab and makes it current, reusing the tab if it is open already. A workspace file opens the
  ## workspace and a folder becomes the project folder (both give nil). A new tab replaces an untouched Welcome or empty
  ## tab; a remote file, or a library file when those are protected, is read-only. A new tab gets the language server,
  ## git marks, crash recovery and the plugins' hook, and a toast offers the merge editor when it holds conflict
  ## markers. With `line` the cursor goes there; the file joins the recent list and the editor gets the focus.
  let full = absolutePath(path).normalizedPath
  if (full.endsWith(".ned-workspace") or full.endsWith(".code-workspace")) and fileExists(full) and line < 0:
    discard openWorkspace(full)
    return nil
  if dirExists(full):
    rootDir = full
    setCurrentDir(full)
    treeRoot = nil
    fileCacheValid = false
    treeOpen = true
    focus = fTree
    flattenTree()
    return nil
  var i = bufIndexByPath(full)
  if i < 0:
    let fetched = remoteFetch(full)        # (a remote server's file outside the folder: to read)
    let b = newBuffer()
    if not b.loadFile(full): return nil
    if fetched: b.readOnly = true
    elif not b.readOnly and isLibraryFile(full):
      b.readOnly = true            # (the standard library, an installed package: not changed by accident)
      b.libLocked = true
    if curBuf in 0..bufs.high and bufs[curBuf].isWelcome():
      bufs[curBuf] = b
      i = curBuf
    elif bufs.len == 1 and bufs[0].path.len == 0 and bufs[0].title.len == 0 and not bufs[0].dirty and
        bufs[0].lines == @[""]:
      bufs[0] = b
      i = 0
    else:
      bufs.add b
      i = bufs.high
    if b.hex != nil and isPicturePath(full) and sBool("pictures.open"): picOpen(b)    # (a picture: shown as one)
    lspAttach(b)
    refreshGit(b)
    offerRecovery(b)
    plugOpened(b)
    if b.lang != nil and b.lang.mode == lmNim and b.id notin ffiQueue: ffiQueue.add b.id    # (checked when idle)
    smark("  opened " & extractFilename(full))
    if not fileExists(full): info("New file: " & relPath(full))
    elif b.lines.len < 100_000:
      var nc = 0
      for l in b.lines:
        if l.startsWith("<<<<<<<") and (l.len == 7 or l[7] == ' '): inc nc
      if nc > 0:
        let bid = b.id
        toast($nc & " merge conflict" & (if nc == 1: "" else: "s") & " in " & b.name, 2, "Merge editor", proc() =
          for k, x in bufs:
            if x.id == bid:
              curBuf = k
              cmdMergeEditor()
              break, 12000)
  closeComp()
  curBuf = i
  result = bufs[i]
  if line >= 0:
    result.centerOn(result.clampPos(Pos(line: line, col: max(0, col))))
  addRecent(full)
  focus = fEditor
  if treeOpen and scrW < 70: treeOpen = false
  needRender = true

proc formatOnSave(b: Buffer)

# a multibuffer (like Zed's): pieces of many files in one editable buffer; saving writes them back
type MbSection = object
  path: string
  start: int                # 0-based first line in the file
  orig: seq[string]         # the lines as they were (to notice changes made elsewhere)
  note: string              # shown after its header (the Git changes view: what changed, staged or not)
var multiBufs: Table[int, seq[MbSection]]
proc saveMultibuffer(b: Buffer): bool

type CommitBuf = object
  amend: bool
  root: string                           # the repository it commits to
var commitBufs: Table[int, CommitBuf]    # commit message tabs: Ctrl+S commits
proc doCommitFromBuffer(b: Buffer): bool

type RebaseBuf = object
  root, base: string
  orig: seq[(string, string)]            # (hash, subject), oldest first
var rebaseBufs: Table[int, RebaseBuf]    # interactive-rebase plan tabs: Ctrl+S starts the rebase
proc doRebaseFromBuffer(b: Buffer): bool
type SigPlan = object
  path, name: string
  line, col: int
  params: seq[tuple[name, typ, default: string]]
  ret: string
var sigPlans: Table[int, SigPlan]        # change-signature plan tabs: Ctrl+S changes the routine and its calls
proc doSignatureFromBuffer(b: Buffer): bool
proc ciRefresh()
proc cmdRunConfigs()
proc ghRuns()
proc cmdRunTask()
proc cmdRerunTask()

proc mbHeaderAt(b: Buffer, line: int): (bool, string, int) =
  ## a multibuffer's `# § path:line` header: the file and the (0-based) line
  if line < 0 or line >= b.lines.len: return
  let t = b.lines[line]
  let k = t.find(" § ")
  if k < 0 or k > 4: return
  var rest = t[k + 3 .. ^1]
  let nk = rest.find("  — ")
  if nk >= 0: rest = rest[0 ..< nk]
  let c = rest.rfind(':')
  if c <= 0: return
  let n = (try: parseInt(rest[c + 1 .. ^1]) except ValueError: -1)
  if n < 1: return
  let rel = rest[0 ..< c]
  (true, (if rel.isAbsolute: rel else: rootDir / rel), n - 1)

proc mbOpen(path: string, line: int) =
  ## opens a file and centres it on a (0-based) line — where a multibuffer's section header leads
  let ob = openFile(path)
  if ob != nil: ob.centerOn(ob.clampPos(Pos(line: line, col: 0)))
