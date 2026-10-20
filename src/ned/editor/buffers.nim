proc bufById(id: int): Buffer =
  for b in bufs:
    if b.id == id: return b
  nil

proc bufIndexByPath(path: string): int =
  for i, b in bufs:
    if b.path == path: return i
  -1

proc pushJump() =
  let b = buf()
  if b.path.len == 0: return
  jumpStack.add (b.path, b.primary.head)
  if jumpStack.len > 100: jumpStack.delete(0)
  fwdStack.setLen(0)                    # a new jump: nothing to go forward to

proc centerOn(b: Buffer, p: Pos) =
  if cfgJumpHl and gRaw:
    landBuf = b.id                      # (the line it lands on lights up for a moment: ui.jumpHighlight)
    landLine = p.line
    landAt = getMonoTime()
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
    let b = newBuffer()
    if not b.loadFile(full): return nil
    if not b.readOnly and isLibraryFile(full):
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
    lspAttach(b)
    refreshGit(b)
    offerRecovery(b)
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
  let rest = t[k + 3 .. ^1]
  let c = rest.rfind(':')
  if c <= 0: return
  let n = (try: parseInt(rest[c + 1 .. ^1]) except ValueError: -1)
  if n < 1: return
  let rel = rest[0 ..< c]
  (true, (if rel.isAbsolute: rel else: rootDir / rel), n - 1)

proc mbOpen(path: string, line: int) =
  let ob = openFile(path)
  if ob != nil: ob.centerOn(ob.clampPos(Pos(line: line, col: 0)))
