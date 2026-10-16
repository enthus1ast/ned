# ── multi-root workspaces: several folders in one window (tree, quick open, search, language servers);
#    saved as a .ned-workspace file — VS Code's .code-workspace files open too ──

proc wsNotifyServers(added, removed: seq[string]) =
  for srv in servers:
    if srv.dead: continue
    var a, r = newJArray()
    for d in added: a.add %*{"uri": uriFromPath(d), "name": extractFilename(d)}
    for d in removed: r.add %*{"uri": uriFromPath(d), "name": extractFilename(d)}
    srv.lspNotify("workspace/didChangeWorkspaceFolders", %*{"event": {"added": a, "removed": r}})

proc wsChanged() =
  treeRoot = nil
  fileCacheValid = false
  startScan()
  flattenTree()
  needRender = true

proc wsAddFolder(d0: string) =
  let d = absolutePath(expandTilde(d0.strip)).normalizedPath
  if not dirExists(d):
    error("No such folder: " & d0)
    return
  if d == rootDir or d in wsRoots:
    info(extractFilename(d) & " is already in the workspace")
    return
  wsRoots.add d
  wsNotifyServers(@[d], @[])
  wsChanged()
  treeOpen = true
  info("Added " & tildePath(d) & " — " & $(wsRoots.len + 1) & " folders · Workspace: save as… keeps them together")

proc wsRemoveFolder(d: string) =
  let i = wsRoots.find(d)
  if i < 0: return
  wsRoots.delete(i)
  wsNotifyServers(@[], @[d])
  wsChanged()
  info("Removed " & tildePath(d) & " from the workspace")

proc wsSave(path0: string) =
  var f = absolutePath(expandTilde(path0.strip)).normalizedPath
  if not (f.endsWith(".ned-workspace") or f.endsWith(".code-workspace")): f.add ".ned-workspace"
  var folders = newJArray()
  for d in @[rootDir] & wsRoots:
    let rel = relativePath(d, parentDir(f))
    folders.add %*{"path": (if rel.startsWith("../../..") : d else: rel)}
  try:
    var j = if fileExists(f): (try: parseJson(readFile(f)) except CatchableError: newJObject()) else: newJObject()
    if j.kind != JObject: j = newJObject()
    j["folders"] = folders
    writeFileSafe(f, j.pretty & "\n")
    wsFile = f
    addRecent(f)
    info("Workspace saved: " & tildePath(f) & " (" & $folders.len & " folders) — ned " & tildePath(f) & " opens it")
  except CatchableError as e: error("Could not save the workspace: " & e.msg)

proc openWorkspace(f: string): bool =
  ## a .ned-workspace / .code-workspace file: its first folder is the project, the others join it
  var j: JsonNode
  try: j = parseJson(readFile(f))
  except CatchableError as e:
    error("Not a workspace file: " & e.msg)
    return false
  var dirs: seq[string]
  for x in jitems(j{"folders"}):
    var d = x{"path"}.getStr
    if d.len == 0: continue
    d = expandTilde(d)
    if not d.isAbsolute: d = parentDir(f) / d
    d = d.normalizedPath
    if dirExists(d) and d notin dirs: dirs.add d
  if dirs.len == 0:
    error("The workspace has no folders that exist here")
    return false
  if rootDir != dirs[0]: openFolder(dirs[0])
  if rootDir != dirs[0]: return false              # (unsaved files kept the old folder open)
  let old = wsRoots
  wsRoots = dirs[1 .. ^1]
  wsFile = f
  wsNotifyServers(wsRoots, old)
  wsChanged()
  treeOpen = true
  addRecent(f)
  info("Workspace " & splitFile(f).name & ": " & $dirs.len & " folders")
  true

proc wsRemoveAct(d: string): Action = (proc() = wsRemoveFolder(d))

proc cmdWsRemove() =
  if wsRoots.len == 0:
    info("Only one folder is open — Workspace: add a folder… adds another")
    return
  var items: seq[(string, string, Action)]
  for d in wsRoots: items.add act(extractFilename(d), tildePath(d), wsRemoveAct(d))
  openActions("Remove a folder from the workspace", items)
