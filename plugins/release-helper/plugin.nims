## release-helper — a Nim package's release: its version bumped, a CHANGELOG entry from git's log, the tag
##
##   Release: bump the version…        patch, minor or major (or a version you type): the version in the .nimble
##                                     file, and in the const of a version.nim under src/ when there is one —
##                                     both changed in ned and saved
##   Release: add a CHANGELOG entry    a dated section at the top of CHANGELOG.md (made when there is none):
##                                     "## 1.2.4 — 2026-10-26" and a line for each commit since the last tag
##                                     (git log, merges left out), for you to edit and save
##   Release: tag it…                  the git commands — git tag -a v1.2.4, its message the CHANGELOG's section for
##                                     the version; git push origin v1.2.4 — in the Output panel, and run when you
##                                     choose to: the tag here, the push in the terminal (it may ask who you are)
##   settings                          plugins.release-helper.tagPrefix (v) · .push (true: offer to push the tag)
##                                     · .changelog (CHANGELOG.md)
import nedplugin
import std/[strutils, algorithm]

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")
permission("shell", "reads git's tags and log for the CHANGELOG, and makes the release's tag")

settingDef("tagPrefix", "v", "Release: tag it — what goes before the version in the tag's name (v1.2.4)")
settingDef("push", true, "Release: tag it — offer to push the tag to origin too (in the terminal)")
settingDef("changelog", "CHANGELOG.md", "Release: add a CHANGELOG entry — the file, from the project's folder")

func q(s: string): string = "'" & s.replace("'", "'\\''") & "'"

func plural(n: int, word: string): string = $n & " " & word & (if n == 1: "" else: "s")

# ── versions ──

func isVersion*(s: string): bool =
  ## 1.2.3 (or 1.2, 1.2.3-rc1, 1.2.3+build)
  var i = 0
  var parts = 0
  while true:
    let a = i
    while i < s.len and s[i] in Digits: inc i
    if i == a: return false
    inc parts
    if i < s.len and s[i] == '.' and parts < 3: inc i
    else: break
  parts >= 2 and (i == s.len or s[i] in {'-', '+'})

func bump*(v, kind: string): string =
  ## the version after a patch, minor or major release (a pre-release's suffix dropped)
  var core = v
  for c in ['-', '+']:
    let k = core.find(c)
    if k >= 0: core = core[0 ..< k]
  var n = @[0, 0, 0]
  let parts = core.split('.')
  for i, p in parts:
    if i < 3:
      try: n[i] = parseInt(p)
      except ValueError: discard
  case kind
  of "major": $(n[0] + 1) & ".0.0"
  of "minor": $n[0] & "." & $(n[1] + 1) & ".0"
  else: $n[0] & "." & $n[1] & "." & $(n[2] + 1)

func versionIn*(lines: seq[string], nimble: bool, want = ""): (int, int, int) =
  ## where the version is: (its line, its first column, its end) — the .nimble's `version = "…"`, or in a
  ## version.nim the first version-like string after an = (the one equal to `want`, when there is such); line -1:
  ## none
  result = (-1, 0, 0)
  for i, l in lines:
    let t = l.strip
    if nimble and not (t.startsWith("version") and t[7 .. ^1].strip.startsWith("=")): continue
    let eq = l.find('=')
    if eq < 0: continue
    var a = l.find('"', eq)
    while a >= 0:
      let e = l.find('"', a + 1)
      if e < 0: break
      let s = l[a + 1 ..< e]
      if isVersion(s):
        if nimble or want.len == 0 or s == want: return (i, a + 1, e)
        if result[0] < 0: result = (i, a + 1, e)
      a = l.find('"', e + 1)

proc nimbleFile(root: string): string =
  ## the project's .nimble file ("" when it has none)
  var all: seq[string]
  for kind, p in walkDir(root):
    if kind == pcFile and p.endsWith(".nimble"): all.add p
  all.sort()
  if all.len > 0: all[0] else: ""

proc versionFiles(root: string): seq[string] =
  ## the version.nim files under src/ (not in hidden folders or nimcache)
  if not dirExists(root / "src"): return
  var todo = @[root / "src"]
  while todo.len > 0:
    let d = todo.pop
    for kind, p in walkDir(d):
      let name = extractFilename(p)
      if kind == pcDir and not name.startsWith(".") and name != "nimcache": todo.add p
      elif kind == pcFile and name == "version.nim": result.add p
  result.sort()

proc currentVersion(root: string): (string, string) =
  ## the .nimble file and the version in it ("" when there is none)
  let f = nimbleFile(root)
  if f.len == 0: return ("", "")
  let ls = readFile(f).splitLines
  let (i, a, e) = versionIn(ls, true)
  if i < 0: return (f, "")
  (f, ls[i][a ..< e])

func rel(root, p: string): string = (if p.startsWith(root & "/"): p[root.len + 1 .. ^1] else: p)

proc setVersion(path, old, new: string, nimble: bool): bool =
  ## the version in the file changed (in ned: its tab, then saved)
  let b = openFile(path)
  if not b.valid: return false
  let (i, a, e) = versionIn(b.lines, nimble, old)
  if i < 0: return false
  b.replace(rng(pos(i, a), pos(i, e)), new)
  b.save()
  true

proc bumpNow() =
  let root = projectRoot()
  let (nimble, v) = currentVersion(root)
  if nimble.len == 0:
    message("Release: no .nimble file in " & root)
    return
  if v.len == 0:
    warn("Release: no version = \"…\" in " & extractFilename(nimble))
    return
  let kinds = ["patch", "minor", "major"]
  var items: seq[string]
  for k in kinds: items.add k & "    " & v & " → " & bump(v, k)
  items.add "another version…"
  let i = pick("Release: the version after " & v, items,
               ["a fix", "something new that breaks nothing", "a change that breaks what worked", "you type it"])
  if i < 0: return
  var nv = if i < 3: bump(v, kinds[i]) else: ask("Release: the new version", v).strip
  if nv.len == 0 or nv == v: return
  if not isVersion(nv):
    warn("Release: " & nv & " is not a version (1.2.3)")
    return
  let back = current()
  let backPath = if back.valid: back.path else: ""
  let backAt = if back.valid: back.cursor else: pos(0, 0)
  var done: seq[string]
  if setVersion(nimble, v, nv, true): done.add extractFilename(nimble)
  for f in versionFiles(root):
    if setVersion(f, v, nv, false): done.add rel(root, f)
  if backPath.len > 0: discard openFile(backPath, backAt.line, backAt.col)   # (back to the file you were in)
  message("Release: " & v & " → " & nv & " in " & done.join(" and ") & " (saved)")

# ── the CHANGELOG ──

proc git(args: string): tuple[output: string, code: int] = shell("git " & args & " 2>&1")

func sectionAt*(lines: seq[string], version: string): int =
  ## the line of the CHANGELOG's heading for the version (## 1.2.4, ## [1.2.4], ## v1.2.4 …), -1 for none
  for i, l in lines:
    if not l.startsWith("## "): continue
    var w = ""
    for c in l[3 .. ^1] & " ":
      if c in {'0'..'9', '.', '-', '+', 'a'..'z', 'A'..'Z'}: w.add c
      else:
        let x = if w.startsWith("v"): w[1 .. ^1] else: w
        if x == version: return i
        w = ""
  -1

func sectionText*(lines: seq[string], version: string): string =
  ## what the CHANGELOG says under the version's heading ("" when it has no section for it)
  let h = sectionAt(lines, version)
  if h < 0: return ""
  var body: seq[string]
  for l in lines[h + 1 .. ^1]:
    if l.startsWith("## ") or l.startsWith("# "): break
    body.add l
  body.join("\n").strip

func withEntry*(lines: seq[string], heading: string, items: seq[string]): (seq[string], int) =
  ## the CHANGELOG with the new section before its first ## section (after its title and what follows it; the
  ## title made when the file is empty), and the line of the section's heading
  var section = @[heading, ""]
  for x in items: section.add "- " & x
  section.add ""
  var ls = lines
  while ls.len > 0 and ls[^1].strip.len == 0: ls.setLen(ls.len - 1)
  if ls.len == 0: return (@["# Changelog", ""] & section, 2)
  var at = -1
  for i, l in ls:
    if l.startsWith("## "):
      at = i
      break
  if at < 0: return (ls & @[""] & section, ls.len + 1)
  (ls[0 ..< at] & section & ls[at .. ^1] & @[""], at)

proc changelogNow() =
  let root = projectRoot()
  let (_, v) = currentVersion(root)
  if v.len == 0:
    message("Release: no version in a .nimble file in " & root)
    return
  if git("rev-parse --git-dir").code != 0:
    warn("Release: " & extractFilename(root) & " is not a git repository")
    return
  let last = git("describe --tags --abbrev=0")
  let tag = if last.code == 0: last.output.strip else: ""
  let log = git("log --no-merges --pretty=format:%s " & (if tag.len > 0: q(tag & "..HEAD") else: "HEAD"))
  if log.code != 0:
    warn("Release: git log — " & log.output.strip.splitLines[^1])
    return
  var items: seq[string]
  for l in log.output.splitLines:
    if l.strip.len > 0: items.add l.strip
  if items.len == 0:
    message("Release: no commits since " & (if tag.len > 0: tag else: "the start"))
    return
  let file = root / setting("changelog", "CHANGELOG.md")
  let b = openFile(file)
  if not b.valid:
    warn("Release: cannot open " & file)
    return
  let ls = b.lines
  let had = sectionAt(ls, v)
  if had >= 0:
    b.setCursor(pos(had, 0))
    message("Release: " & extractFilename(file) & " has a section for " & v & " already (line " & $(had + 1) &
            ") — bump the version first?")
    return
  let (nl, at) = withEntry(ls, "## " & v & " — " & localTime()[0 ..< 10], items)
  b.setText(nl.join("\n"))
  b.setCursor(pos(at, 0))
  message("Release: " & plural(items.len, "commit") & (if tag.len > 0: " since " & tag else: "") & " in a section " &
          "for " & v & " — edit it, then save")

# ── the tag ──

proc tagNow() =
  let root = projectRoot()
  let (_, v) = currentVersion(root)
  if v.len == 0:
    message("Release: no version in a .nimble file in " & root)
    return
  if git("rev-parse --git-dir").code != 0:
    warn("Release: " & extractFilename(root) & " is not a git repository")
    return
  let tag = setting("tagPrefix", "v") & v
  if git("rev-parse -q --verify " & q("refs/tags/" & tag)).code == 0:
    warn("Release: the tag " & tag & " is there already — bump the version first?")
    return
  # its message: the CHANGELOG's section for the version, else "Release 1.2.4"
  let file = root / setting("changelog", "CHANGELOG.md")
  var body = ""
  if fileExists(file): body = sectionText(readFile(file).splitLines, v)
  let msg = "Release " & v & (if body.len > 0: "\n\n" & body else: "") & "\n"
  writeData("TAG_MSG", msg)
  let tagCmd = "git tag -a " & q(tag) & " -F " & q(dataDir() / "TAG_MSG")
  let pushCmd = "git push origin " & q(tag)
  let canPush = setting("push", true) and "origin" in git("remote").output.splitLines
  let changed = git("status --porcelain --untracked-files=no").output.strip
  let n = if changed.len == 0: 0 else: changed.splitLines.len
  var shown = @["Release: the commands for " & tag & ", in " & root, "  " & tagCmd]
  if canPush: shown.add "  " & pushCmd
  shown.add "the tag's message:"
  for l in msg.strip.splitLines: shown.add "  " & l
  if n > 0: shown.add plural(n, "file") & " changed and not committed: they are not in the tag"
  output(shown.join("\n"))
  showOutput()
  var items = @["Run: " & tagCmd & (if canPush: " — then " & pushCmd & " in the terminal" else: "")]
  if canPush: items.add "Tag only: " & tagCmd
  items.add "Cancel"
  let i = pick("Release: tag " & tag & "? (the commands are in the Output panel" &
               (if n > 0: "; " & plural(n, "file") & " not committed" else: "") & ")", items)
  if i < 0 or i >= items.high: return                   # (Cancel, or nothing chosen)
  let r = shell(tagCmd & " 2>&1")
  if r.code != 0:
    warn("Release: git tag — " & r.output.strip.splitLines[^1])
    return
  if canPush and i == 0:
    runInTerminal(pushCmd)
    message("Release: tagged " & tag & " — pushing it in the terminal")
  else: message("Release: tagged " & tag)

command "Release: bump the version…":
  bumpNow()

command "Release: add a CHANGELOG entry":
  changelogNow()

command "Release: tag it…":
  tagNow()
