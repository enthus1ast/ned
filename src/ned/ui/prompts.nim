# ════════════════════════════════════════════════════════════════════════════
#  Prompts (find, replace, goto, save as, run, search, file ops)
# ════════════════════════════════════════════════════════════════════════════

proc openPrompt(kind: PromptKind, label: string, initial = "") =
  ## opens the one-line prompt of that kind with its label and starting text (the cursor at its end), closing completion
  ## and hover; for the find prompts it also remembers where the cursors were, starts counting matches and selects the
  ## starting text so typing replaces it
  fieldSelClear()                    # (a selection of the prompt before — the find box's — is not this one's)
  closeComp()
  hoverOpen = false
  promptKind = kind
  promptLabel = label
  promptText = initial
  promptCur = initial.len
  promptHistIdx = -1
  if kind in {pFind, pReplaceFind}:
    findOrigin = buf().cursors
    findQuery = initial
    countMatches()
    # (what it opens with is selected, as in any find box: typing replaces it, an arrow keeps it)
    if initial.len > 0: fieldSelect(promptText, 0, initial.len)
  needRender = true

proc closePrompt() =
  ## closes the prompt and drops the selection in its field
  if fieldOwns(promptText): fieldSelClear()
  promptKind = pNone
  needRender = true

proc addHist(kind: PromptKind, t: string) =
  ## remembers `t` as the newest entry of that prompt kind's history (an older equal entry is dropped, at most 50 kept),
  ## for the Up and Down keys
  if t.len == 0: return
  var h = promptHist.getOrDefault(kind)
  let i = h.find(t)
  if i >= 0: h.delete(i)
  h.add t
  if h.len > 50: h.delete(0)
  promptHist[kind] = h

proc completePath(t: string): string =
  ## Tab completion of a typed path: extends it to the longest common start of the names in its folder that begin with
  ## what was typed (a folder gets a trailing /), listing up to 8 candidates in a message when there are several; the
  ## path unchanged when nothing matches
  let full = expandTilde(t)
  let base = if full.isAbsolute: full else: rootDir / full
  let (dir, prefix) = if t.endsWith("/"): (base, "") else: (parentDir(base), extractFilename(base))
  var matches: seq[string]
  try:
    for kind, p in walkDir(dir):
      let nm = extractFilename(p)
      if nm.startsWith(prefix): matches.add (if kind in {pcDir, pcLinkToDir}: nm & "/" else: nm)
  except OSError: return t
  if matches.len == 0: return t
  var common = matches[0]
  for m in matches:
    var k = 0
    while k < common.len and k < m.len and common[k] == m[k]: inc k
    common.setLen(k)
  if matches.len > 1: info(matches[0 ..< min(8, matches.len)].join("  "))
  if t.endsWith("/"): return t & common
  # replace the typed last component (what was typed, not its expansion: "~", "..", "x/." …)
  let slash = t.rfind('/')
  let typedLast = if slash >= 0: t[slash + 1 .. ^1] else: t
  if not common.startsWith(typedLast) and typedLast != prefix: return t
  t[0 ..< t.len - typedLast.len] & common

var treeTarget = ""

proc vimEx(cmd: string)
proc aiInlineEdit(instruction: string)
proc submitSetting(t: string)
proc nimbleAddDep(pkg: string)

proc tildePath(p: string): string =
  ## the path with the home folder written as ~
  let h = getHomeDir().strip(leading = false, chars = {'/'})
  if p == h: "~" elif p.startsWith(h & "/"): "~" & p[h.len .. ^1] else: p

proc projectMarks(d: string): string =
  ## what makes `d` a project ("git · nimble"), empty when nothing does
  var ms: seq[string]
  for (m, label) in [(".git", "git"), (".hg", "hg"), ("Cargo.toml", "cargo"), ("package.json", "node"),
                     ("go.mod", "go"), ("pyproject.toml", "python"), ("setup.py", "python"), ("build.zig", "zig"),
                     (".ned", "ned")]:
    if (fileExists(d / m) or dirExists(d / m)) and label notin ms: ms.add label
  try:
    for kind, p in walkDir(d):
      if kind in {pcFile, pcLinkToFile} and p.endsWith(".nimble"):
        ms.insert("nimble", 0)
        break
  except OSError: discard
  ms.join(" · ")

proc browseFolder(dir: string) =
  ## Open folder: the folders in `dir` to tap through; the first line opens the one you are in.
  ## Projects (git, nimble, …) are marked ◆.
  var d = absolutePath(expandTilde(dir)).normalizedPath
  if d.len > 1: d = d.strip(leading = false, chars = {'/'})
  if not dirExists(d): d = getHomeDir().strip(leading = false, chars = {'/'})
  var subs: seq[string]
  try:
    for kind, p in walkDir(d):
      if kind in {pcDir, pcLinkToDir}:
        let nm = extractFilename(p)
        if nm.startsWith(".") and not showHidden: continue
        subs.add nm
  except OSError as e:
    error("Cannot read " & tildePath(d) & ": " & e.msg)
  subs.sort(proc(a, b: string): int = cmp(a.toLowerAscii, b.toLowerAscii))
  var items: seq[(string, string, Action)]
  var paths: seq[string]
  let here = d
  let hm = projectMarks(d)
  items.add act("✓ Open this folder", tildePath(d) & (if hm.len > 0: "  ◆ " & hm else: ""), proc() = openFolder(here))
  paths.add d
  let up = parentDir(d)
  if up.len > 0 and up != d:
    items.add act("↑ ..", "up to " & tildePath(up), proc() = browseFolder(up))
    paths.add up
  var cur = -1
  for i, nm in subs:
    let p = (if d == "/": "" else: d) & "/" & nm
    let marks = if i < 300: projectMarks(p) else: ""
    if p == rootDir: cur = items.len
    capture p:
      items.add act((if marks.len > 0: "◆ " else: "▸ ") & nm & "/",
                    (if p == rootDir: "open now · " else: "") & marks, proc() = browseFolder(p))
    paths.add p
  openActions("Open folder · " & tildePath(d) & "   Enter: go in · Alt+Enter: open it · ⌫ up · type /path", items)
  pickFolderDir = d
  pickFolderPaths = paths
  if cur >= 0:
    let s = pickShown.find(cur)
    if s >= 0: pickSel = s
