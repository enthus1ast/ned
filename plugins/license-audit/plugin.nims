## license-audit — the licences of your project's dependencies in one table, the ones that may not go with yours marked
##
##   Licences: check the dependencies    every package the project's .nimble requires, and the ones they require in
##                                       turn: each one's version and licence, read from its own .nimble where it is
##                                       installed — nimble's pkgs2 or pkgs, or the project's deps/ (Atlas) —, in a
##                                       Markdown tab. Marked: a copyleft licence (GPL, AGPL, LGPL) under a permissive
##                                       project, one with no licence given, one not installed
##   settings                            plugins.license-audit.nimbleDir — nimble's folder, when it is neither
##                                       $NIMBLE_DIR nor ~/.nimble
##
## Not legal advice: what a licence allows is for you, or a lawyer, to read. The table only says what each package's
## .nimble file declares.
import nedplugin
import std/algorithm

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("nimbleDir", "", "Licences: nimble's folder (empty: $NIMBLE_DIR, else ~/.nimble)")

type Dep = object
  name, version, license, where: string
  by: string                    # the package that requires it ("" the project)

proc nimbleDir(): string =
  ## nimble's folder: the setting, $NIMBLE_DIR, else ~/.nimble
  let own = setting("nimbleDir", "")
  if own.len > 0: return own
  if existsEnv("NIMBLE_DIR"): return getEnv("NIMBLE_DIR")
  getHomeDir() / ".nimble"

func field*(nimble, key: string): string =
  ## a `key = "value"` line of a .nimble file ("" when it has none)
  for l in nimble.splitLines:
    let t = l.strip
    if t.startsWith(key):
      let rest = t[key.len .. ^1].strip
      if rest.startsWith("="):
        let v = rest[1 .. ^1].strip
        if v.len >= 2 and v[0] == '"':
          let e = v.find('"', 1)
          if e > 0: return v[1 ..< e]

func requiresOf*(nimble: string): seq[string] =
  ## the packages a .nimble file requires (their names, small letters; not nim itself), in the order they come
  for l in nimble.splitLines:
    let t = l.strip
    if not t.startsWith("requires"): continue
    var i = 0
    while true:
      let a = t.find('"', i)
      if a < 0: break
      let e = t.find('"', a + 1)
      if e < 0: break
      var name = t[a + 1 ..< e].strip
      var k = 0
      while k < name.len and name[k] notin {' ', '>', '<', '=', '#', '@', '~', '^'}: inc k
      name = name[0 ..< k]
      if name.contains("://"):                       # (a URL: its last part)
        name = name.strip(chars = {'/'}).split('/')[^1]
        if name.endsWith(".git"): name = name[0 ..< name.len - 4]
      name = name.toLowerAscii
      if name.len > 0 and name != "nim" and name notin result: result.add name
      i = e + 1

func copyleft*(lic: string): bool =
  ## a licence that asks for what is built with it to be shared alike
  let l = lic.toUpperAscii
  "GPL" in l or "AGPL" in l or "LGPL" in l or "EUPL" in l or "MPL" in l or "CDDL" in l or "EPL" in l or
    "OSL" in l or "SSPL" in l

func permissive*(lic: string): bool =
  ## a licence that lets others use the code as they like, keeping the notice
  let l = lic.toUpperAscii
  "MIT" in l or "BSD" in l or "APACHE" in l or "ISC" in l or "ZLIB" in l or "UNLICENSE" in l or "BOOST" in l or
    "0BSD" in l or "CC0" in l or "WTFPL" in l

func newer*(a, b: string): bool =
  ## is version `a` newer than `b`, number by number (0.10.0 after 0.9.2)?
  let x = a.split('.')
  let y = b.split('.')
  for i in 0 ..< max(x.len, y.len):
    var p, q = 0
    try: p = (if i < x.len: parseInt(x[i]) else: 0)
    except ValueError: discard
    try: q = (if i < y.len: parseInt(y[i]) else: 0)
    except ValueError: discard
    if p != q: return p > q
  false

proc findInstalled(name: string): (string, string) =
  ## where the package is installed and its version: the project's deps/ (Atlas), else its nimbledeps/ or nimble's
  ## pkgs2 or pkgs — the newest version there ("", "" when it is not installed)
  let root = projectRoot()
  let atlas = root / "deps" / name
  if dirExists(atlas): return (atlas, "")
  var best = ""
  var bestV = ""
  for base in [root / "nimbledeps" / "pkgs2", nimbleDir() / "pkgs2", nimbleDir() / "pkgs"]:
    if not dirExists(base): continue
    for kind, p in walkDir(base):
      if kind notin {pcDir, pcLinkToDir}: continue
      # (name-1.2.3 in pkgs, name-1.2.3-<checksum> in pkgs2)
      let parts = extractFilename(p).split('-')
      if parts.len >= 2 and parts[0].toLowerAscii == name:
        let v = parts[1]
        if bestV.len == 0 or newer(v, bestV):
          bestV = v
          best = p
    if best.len > 0: break
  (best, bestV)

proc nimbleFileIn(dir, name: string): string =
  ## the package's .nimble file in its folder ("" none)
  if fileExists(dir / (name & ".nimble")): return dir / (name & ".nimble")
  for kind, p in walkDir(dir):
    if kind in {pcFile, pcLinkToFile} and p.endsWith(".nimble"): return p
  ""

proc audit(): string =
  ## the table: the project's licence, then each dependency's, the ones to look at marked
  let root = projectRoot()
  var own = ""
  for kind, p in walkDir(root):
    if kind in {pcFile, pcLinkToFile} and p.endsWith(".nimble"):
      own = p
      break
  if own.len == 0: return ""
  let text = readFile(own)
  let mine = field(text, "license")
  var deps: seq[Dep]
  var queue: seq[(string, string)]
  for n in requiresOf(text): queue.add (n, "")
  var seen: seq[string]
  while queue.len > 0 and deps.len < 200:
    let (n, by) = queue[0]
    queue.delete(0)
    if n in seen: continue
    seen.add n
    let (dir, v) = findInstalled(n)
    var d = Dep(name: n, version: v, by: by, where: (if dir.len == 0: "" elif "/deps/" in dir: "deps/" else: "nimble"))
    if dir.len > 0:
      let nf = nimbleFileIn(dir, n)
      if nf.len > 0:
        let t = readFile(nf)
        d.license = field(t, "license")
        if d.version.len == 0: d.version = field(t, "version")
        for m in requiresOf(t): queue.add (m, n)
    deps.add d
  deps.sort(proc(a, b: Dep): int = cmp(a.name, b.name))
  result = "# Licences of " & extractFilename(own).changeFileExt("") & "'s dependencies\n\n" &
           "This project: **" & (if mine.len > 0: mine else: "no licence given") & "** · " & $deps.len &
           (if deps.len == 1: " package" else: " packages") & "\n\n| package | version | licence | required by | note |\n" &
           "|---|---|---|---|---|\n"
  var marked = 0
  for d in deps:
    var note = ""
    if d.where.len == 0: note = "? not installed — `nimble install " & d.name & "`"
    elif d.license.len == 0: note = "? no licence given"
    elif copyleft(d.license) and (permissive(mine) or mine.len == 0): note = "⚠ copyleft, under a " &
      (if mine.len > 0: mine else: "project without a licence") & ": read what it asks"
    if note.len > 0: inc marked
    result.add "| " & d.name & " | " & (if d.version.len > 0: d.version else: "—") & " | " &
               (if d.license.len > 0: d.license else: "—") & " | " & (if d.by.len > 0: d.by else: "the project") &
               " | " & note & " |\n"
  result.add "\n" & (if marked == 0: "Nothing to look at." else: $marked & " to look at.") &
             " Not legal advice: the table only says what each package's .nimble file declares.\n"

command "Licences: check the dependencies":
  let md = audit()
  if md.len == 0: message("Licences: no .nimble file in the project's folder")
  else:
    discard newTab("Licences", md, "markdown")
    let n = md.count("| ? ") + md.count("| ⚠ ")
    message("Licences: " & (if n == 0: "nothing to look at" else: $n & " to look at") & " — the table is in its tab")
