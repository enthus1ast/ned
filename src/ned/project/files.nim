# ════════════════════════════════════════════════════════════════════════════
#  Project files & file tree
# ════════════════════════════════════════════════════════════════════════════

const
  SkipDirs = ["node_modules", "nimcache", "__pycache__", "target", "dist", ".git", ".hg", ".svn",
              ".cache", ".venv", "venv", ".idea", ".gradle", "zig-cache", "zig-out", ".nimble"]
  BinExts = ["png", "jpg", "jpeg", "gif", "webp", "ico", "bmp", "pdf", "zip", "gz", "xz", "bz2",
             "7z", "tar", "so", "o", "a", "dylib", "exe", "dll", "class", "jar", "apk", "ttf", "otf",
             "woff", "woff2", "mp3", "mp4", "mkv", "wav", "ogg", "flac", "db", "sqlite", "bin", "pyc",
             "out", "obj", "iso", "dmg", "deb", "rpm"]


var
  scanQueue: seq[(string, int)]
  scanHead = 0
  scanning = false
  scanTruncated = false
  pickFileCount = 0
  pickSeen: HashSet[string]

proc startScan() =
  inc todoGen
  todoFiles.clear()
  todoQueue.setLen(0)
  todoScanned = false
  todoScanProject()
  fileCache.setLen(0)
  scanQueue = @[(rootDir, 0)]
  for r in wsRoots:                       # a workspace's other folders: their files with absolute paths
    if dirExists(r): scanQueue.add (r, 0)
  scanHead = 0
  scanning = true
  scanTruncated = false
  fileCacheValid = true
  pickFileCount = 0

proc feedPickerFiles()

proc pumpScan(budgetMs: int) =
  ## breadth-first, time-sliced project scan: the UI never blocks, even on 500k files
  if not scanning: return
  let t0 = getMonoTime()
  let base = rootDir.len + 1
  while scanHead < scanQueue.len:
    let (dir, depth) = scanQueue[scanHead]
    inc scanHead
    var subs, files: seq[string]
    try:
      for kind, p in walkDir(dir):
        let nm = extractFilename(p)
        if nm.len > 0 and nm[0] == '.' and not showHidden and nm notin [".github", ".config"]: continue
        case kind
        of pcDir:
          if nm notin cfgExclude and (cfgExclude.len > 0 or nm notin SkipDirs) and depth < 24: subs.add p
        of pcFile, pcLinkToFile:
          let dot = nm.rfind('.')
          if dot < 0 or nm[dot + 1 .. ^1].toLowerAscii notin BinExts:
            files.add (if p.len > base and p.startsWith(rootDir & "/"): p[base .. ^1] else: p)
        else: discard
    except OSError: discard
    files.sort()
    subs.sort()
    for f in files: fileCache.add f
    for d in subs: scanQueue.add (d, depth + 1)
    if fileCache.len >= cfgScanLimit:
      scanTruncated = true
      break
    if msSince(t0) >= budgetMs: break
  if scanHead >= scanQueue.len or scanTruncated:
    scanning = false
    scanQueue.setLen(0)
    scanHead = 0
  if pickKind == pickFile:
    feedPickerFiles()
    needRender = true
  elif not scanning: needRender = true

proc projectFiles(): seq[string] =
  if not fileCacheValid:
    startScan()
    pumpScan(80)
  fileCache

proc loadChildren(n: TreeNode) =
  n.children.setLen(0)
  var dirs, files: seq[TreeNode]
  try:
    for kind, p in walkDir(n.path):
      let nm = extractFilename(p)
      if not showHidden and (nm.startsWith(".") or nm in cfgExclude): continue
      let node = TreeNode(name: nm, path: p, isDir: kind in {pcDir, pcLinkToDir}, depth: n.depth + 1)
      if node.isDir: dirs.add node else: files.add node
  except OSError: discard
  let byName = proc(a, b: TreeNode): int = cmpIgnoreCase(a.name, b.name)
  dirs.sort(byName)
  files.sort(byName)
  n.children = dirs & files
  n.loaded = true

proc flattenInto(n: TreeNode) =
  for c in n.children:
    treeRows.add c
    if c.isDir and c.expanded:
      if not c.loaded: loadChildren(c)
      flattenInto(c)

proc flattenTree() =
  let key = if wsRoots.len > 0: rootDir & "|" & wsRoots.join("|") else: rootDir
  if treeRoot == nil or treeBuiltFor != key:
    treeBuiltFor = key
    treeRoot = TreeNode(name: extractFilename(rootDir), path: rootDir, isDir: true, expanded: true, depth: -1)
    if wsRoots.len > 0:
      # a workspace: each folder is a top-level row of its own
      treeRoot.loaded = true
      for d in @[rootDir] & wsRoots:
        let n = TreeNode(name: extractFilename(d), path: d, isDir: true, expanded: true, depth: 0)
        loadChildren(n)
        treeRoot.children.add n
    else: loadChildren(treeRoot)
  treeRows.setLen(0)
  flattenInto(treeRoot)
  treeSel = clamp(treeSel, 0, max(0, treeRows.high))

proc refreshTree() =
  proc reload(n: TreeNode) =
    if not n.loaded: return
    var expanded: HashSet[string]
    for c in n.children:
      if c.expanded: expanded.incl c.path
    loadChildren(n)
    for c in n.children:
      if c.path in expanded:
        c.expanded = true
        reload(c)
  if treeRoot != nil: reload(treeRoot)
  flattenTree()
  fileCacheValid = false

proc revealInTree(path: string) =
  if treeRoot == nil: flattenTree()
  var node = treeRoot
  var base = rootDir
  if wsRoots.len > 0:
    node = nil
    for c in treeRoot.children:
      if path.startsWith(c.path & "/"):
        node = c
        base = c.path
    if node == nil: return
  elif not path.startsWith(rootDir & "/"): return
  let parts = path[base.len + 1 .. ^1].split('/')
  for i, part in parts:
    if not node.loaded: loadChildren(node)
    var found: TreeNode = nil
    for c in node.children:
      if c.name == part: found = c
    if found == nil: break
    if i < parts.high: found.expanded = true
    node = found
  flattenTree()
  for i, r in treeRows:
    if r.path == path: treeSel = i
