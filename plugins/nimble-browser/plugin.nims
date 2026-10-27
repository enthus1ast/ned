## nimble-browser — nimble's packages browsed and searched: a package's README, installing it, adding it to your .nimble
##
##   Nimble: browse packages…    every package of nimble's list, with what it is, to choose from (type to narrow
##                               the list); then what to do with it
##   Nimble: search packages…    words to look for — in the names, the tags and the descriptions — first; the
##                               packages that have them all, the best first (the name, then the tags)
##   then, for a package         its README — fetched from its repository (GitHub, GitLab, Codeberg, SourceHut) and
##                               shown in a tab under what the list says of it, or what the list says alone when it
##                               cannot be fetched, and why —; install it (nimble install, in the terminal); add it
##                               to the project's .nimble file (requires "name", left for you to save)
##   Nimble: refresh the package list   nimble refresh in the background, then the list read again
##   settings                    plugins.nimble-browser.nimbleDir — nimble's folder, when it is neither $NIMBLE_DIR
##                               nor ~/.nimble
##
## The list is nimble's own: packages_official.json and any other packages*.json in nimble's folder, which `nimble
## refresh` writes. Packages installed (in pkgs2/ or pkgs/) say so (✓ 0.6.0). The README is fetched with curl; it
## needs nimble and curl on PATH (Termux: `pkg install nim curl`).
import nedplugin
import std/algorithm

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "fetches a package's README with curl, and runs nimble install and nimble refresh")

settingDef("nimbleDir", "", "Nimble: nimble's folder, where its package lists are (empty: $NIMBLE_DIR, else ~/.nimble)")

type Pkg* = object
  name*, url*, kind*, description*, license*, web*, doc*: string
  tags*: seq[string]

# ── the list ──

proc nimbleDir(): string =
  let s = setting("nimbleDir", "").strip
  if s.len > 0: return expandTilde(s)
  let e = getEnv("NIMBLE_DIR")
  if e.len > 0: e else: getHomeDir() / ".nimble"

func jsonItems(j: JsonNode): seq[JsonNode] =
  ## a JSON array's items; none for anything else (a key that is not there: nil)
  if j != nil and j.kind == JArray: j.getElems else: @[]

proc pkgsOf*(text: string): seq[Pkg] =
  ## the packages of one list (an alias, a name for another package, left out)
  let j = parseJson(text)
  if j.kind != JArray: return
  for p in j:
    if p.kind != JObject or p.hasKey("alias") or p{"name"}.getStr.len == 0: continue
    var tags: seq[string]
    for t in jsonItems(p{"tags"}): tags.add t.getStr
    result.add Pkg(name: p{"name"}.getStr, url: p{"url"}.getStr, kind: p{"method"}.getStr,
                   description: p{"description"}.getStr, license: p{"license"}.getStr, web: p{"web"}.getStr,
                   doc: p{"doc"}.getStr, tags: tags)

var
  cache: seq[Pkg]
  loaded = false
  installed: seq[(string, string)]       # (name, version) of the packages installed

proc load(): seq[Pkg] =
  ## the packages of every list in nimble's folder, by name (a name in two lists: the official one's)
  if loaded: return cache
  let d = nimbleDir()
  var files: seq[string]
  if dirExists(d):
    for kind, p in walkDir(d):
      let n = extractFilename(p)
      if kind in {pcFile, pcLinkToFile} and n.startsWith("packages") and n.endsWith(".json"): files.add p
  files.sort(proc(a, b: string): int = cmp(not a.endsWith("packages_official.json"), not b.endsWith(
    "packages_official.json")))
  var seen: seq[string]
  if files.len > 0: progress("Nimble: reading the package list")
  for f in files:
    var ps: seq[Pkg]
    try: ps = pkgsOf(readFile(f))
    except CatchableError as e:
      log("nimble-browser: " & f & " — " & e.msg)
      continue
    for p in ps:
      let k = p.name.toLowerAscii
      if k notin seen:
        seen.add k
        cache.add p
  if files.len > 0: progressDone()
  cache.sort(proc(a, b: Pkg): int = cmpIgnoreCase(a.name, b.name))
  installed.setLen(0)
  for sub in ["pkgs2", "pkgs"]:
    if dirExists(d / sub):
      for kind, p in walkDir(d / sub):
        if kind notin {pcDir, pcLinkToDir}: continue
        # name-1.2.3 (pkgs) or name-1.2.3-<checksum> (pkgs2)
        let parts = extractFilename(p).split('-')
        if parts.len >= 2: installed.add (parts[0].toLowerAscii, parts[1])
  loaded = cache.len > 0
  cache

proc installedVersion(name: string): string =
  for (n, v) in installed:
    if n == name.toLowerAscii and (result.len == 0 or v > result): result = v

func score*(p: Pkg, words: seq[string]): int =
  ## how well the package matches all the words (-1: one of them is nowhere): its name, then its tags, then what
  ## it says it is; lower is better
  let name = p.name.toLowerAscii
  let desc = p.description.toLowerAscii
  var tags: seq[string]
  for t in p.tags: tags.add t.toLowerAscii
  for w in words:
    var s = -1
    if name == w: s = 0
    elif name.startsWith(w): s = 1
    elif w in name: s = 2
    elif w in tags: s = 3
    else:
      for t in tags:
        if w in t: s = 4
      if s < 0 and w in desc: s = 5
    if s < 0: return -1
    result += s

func search*(ps: seq[Pkg], query: string): seq[Pkg] =
  let words = query.toLowerAscii.splitWhitespace
  if words.len == 0: return ps
  var scored: seq[(int, Pkg)]
  for p in ps:
    let s = score(p, words)
    if s >= 0: scored.add (s, p)
  scored.sort(proc(a, b: (int, Pkg)): int =
    result = cmp(a[0], b[0])
    if result == 0: result = cmpIgnoreCase(a[1].name, b[1].name))
  for (_, p) in scored: result.add p

# ── its README ──

func readmeUrls*(url: string): seq[string] =
  ## where its README may be, from its repository's address: GitHub, GitLab, Codeberg, SourceHut
  var u = url.strip
  if u.endsWith(".git"): u = u[0 ..< ^4]
  u = u.strip(leading = false, chars = {'/'})
  let names = ["README.md", "readme.md", "Readme.md", "README.markdown", "README.rst", "README.txt", "README"]
  for host in ["https://github.com/", "http://github.com/"]:
    if u.startsWith(host):
      let path = u[host.len .. ^1]
      for n in names: result.add "https://raw.githubusercontent.com/" & path & "/HEAD/" & n
      return
  if u.startsWith("https://gitlab.com/"):
    for n in names: result.add u & "/-/raw/HEAD/" & n
  elif u.startsWith("https://codeberg.org/"):
    for b in ["main", "master"]:
      for n in names[0 .. 2]: result.add u & "/raw/branch/" & b & "/" & n
  elif u.startsWith("https://git.sr.ht/"):
    for n in names: result.add u & "/blob/HEAD/" & n

func details*(p: Pkg, installedAs: string): string =
  ## what the list says of the package, as Markdown
  result = "# " & p.name & "\n\n"
  if p.description.len > 0: result.add "> " & p.description & "\n\n"
  if installedAs.len > 0: result.add "- **installed:** " & installedAs & "\n"
  if p.tags.len > 0: result.add "- **tags:** " & p.tags.join(", ") & "\n"
  if p.license.len > 0: result.add "- **licence:** " & p.license & "\n"
  if p.url.len > 0: result.add "- **repository:** " & p.url & (if p.kind.len > 0: " (" & p.kind & ")" else: "") & "\n"
  if p.web.len > 0 and p.web != p.url: result.add "- **web:** " & p.web & "\n"
  if p.doc.len > 0: result.add "- **docs:** " & p.doc & "\n"
  result.add "- **install:** `nimble install " & p.name & "`\n"

func curlWhy*(code: int, said: string): string =
  ## curl's exit code in words
  case code
  of 6: "the host could not be found — is the network on?"
  of 7: "it could not connect — is the network on?"
  of 22: "no README at the addresses tried"
  of 28: "it took too long"
  of 35, 60: "a secure connection could not be made"
  of 127: "curl is not installed (Termux: pkg install curl)"
  else: (if said.len > 0: said else: "curl stopped (" & $code & ")")

proc showReadme(p: Pkg) =
  let urls = readmeUrls(p.url)
  let head = details(p, installedVersion(p.name))
  let title = "nimble: " & p.name
  if urls.len == 0:
    discard newTab(title, head & "\n---\n\n*The README is fetched from GitHub, GitLab, Codeberg and SourceHut: " &
                   "this package lives elsewhere — " & (if p.web.len > 0: p.web else: p.url) & "*\n", "markdown")
    return
  # (the addresses tried one after the other, the first that answers kept)
  var script = "for u in"
  for u in urls: script.add " " & quoteShell(u)
  script.add "; do curl -fsSL --max-time 20 \"$u\" && exit 0; r=$?; [ $r -eq 22 ] || exit $r; done; exit 22"
  status("⇣ " & p.name)
  shellAsync("sh -c " & quoteShell(script)) do (o: string, code: int):
    status("")
    if code == 0 and o.strip.len > 0:
      discard newTab(title, head & "\n---\n\n" & o & "\n", "markdown")
    else:
      var said = ""
      for l in o.splitLines:
        if l.startsWith("curl: "): said = l[6 .. ^1].strip
      discard newTab(title, head & "\n---\n\n*The README could not be fetched: " & curlWhy(code, said) & "*\n",
                     "markdown")

# ── what to do with a package ──

proc nimbleFile(): string =
  ## the project's .nimble file ("" none)
  let root = projectRoot()
  for kind, p in walkDir(root):
    if kind in {pcFile, pcLinkToFile} and p.endsWith(".nimble"): return p

func requiresAt*(lines: seq[string], name: string): (int, bool) =
  ## where a requires line for the package goes (after the last one; else at the end), and whether one names it
  result = (lines.len, false)
  var last = -1
  for i, l in lines:
    let t = l.strip
    if t.startsWith("requires"):
      last = i
      var q = t.find('"')
      while q >= 0:
        let e = t.find('"', q + 1)
        if e < 0: break
        var dep = t[q + 1 ..< e].strip
        var k = 0
        while k < dep.len and dep[k] notin {' ', '>', '<', '=', '#', '@', '~', '^'}: inc k
        dep = dep[0 ..< k]
        if cmpIgnoreStyle(dep, name) == 0 or dep.endsWith("/" & name) or dep.endsWith("/" & name & ".git"):
          return (i, true)
        q = t.find('"', e + 1)
  if last >= 0: result[0] = last + 1
  else:
    # (at the end, without the blank lines there)
    var e = lines.len
    while e > 0 and lines[e - 1].strip.len == 0: dec e
    result[0] = e

proc addRequires(p: Pkg) =
  let f = nimbleFile()
  if f.len == 0:
    message("Nimble: the project has no .nimble file (nimble init makes one)")
    return
  let b = openFile(f)
  if not b.valid: return
  let ls = b.lines
  let (at, there) = requiresAt(ls, p.name)
  if there:
    discard openFile(f, at)
    message("Nimble: " & extractFilename(f) & " requires " & p.name & " already (line " & $(at + 1) & ")")
    return
  let line = "requires \"" & p.name & "\""
  if at >= ls.len:
    let last = ls.len - 1
    b.insert(pos(last, ls[last].len), (if ls[last].len > 0: "\n" else: "") & line)
  else: b.insert(pos(at, 0), line & "\n")
  b.setCursor(pos(min(at, b.lineCount - 1), 0))
  message("Nimble: requires \"" & p.name & "\" added to " & extractFilename(f) & " — save it to keep it")

proc act(p: Pkg) =
  let have = installedVersion(p.name)
  let nf = nimbleFile()
  var items = @["Its README", "Install it (nimble install " & p.name & ")"]
  var dets = @[(if p.url.len > 0: p.url else: ""), (if have.len > 0: "installed: " & have else: "in the terminal")]
  if nf.len > 0:
    items.add "Add it to " & extractFilename(nf)
    dets.add "requires \"" & p.name & "\""
  let i = pick(p.name & (if p.description.len > 0: " — " & p.description else: ""), items, dets)
  case i
  of 0: showReadme(p)
  of 1:
    if confirm("Install " & p.name & " with nimble?"): runInTerminal("nimble install " & quoteShell(p.name))
  of 2: addRequires(p)
  else: discard

proc choose(ps: seq[Pkg], title: string) =
  var items, dets: seq[string]
  for p in ps:
    let have = installedVersion(p.name)
    items.add (if have.len > 0: "✓ " else: "  ") & p.name
    dets.add p.description & (if have.len > 0: " (" & have & ")" else: "")
  let i = pick(title, items, dets)
  if i >= 0: act(ps[i])

proc noList(): bool =
  if load().len > 0: return false
  message("Nimble: no package list in " & nimbleDir() & " — Nimble: refresh the package list (nimble refresh) " &
          "makes it")
  true

command "Nimble: browse packages…":
  if not noList():
    choose(load(), "Nimble packages (" & $load().len & ")")

command "Nimble: search packages…":
  if not noList():
    let q = ask("Nimble: look for (words of the name, tags or description):")
    if q.strip.len > 0:
      let found = search(load(), q)
      if found.len == 0: message("Nimble: no package has all of “" & q.strip & "”")
      else: choose(found, "Nimble: " & $found.len & " for “" & q.strip & "”")

command "Nimble: refresh the package list":
  progress("Nimble: refreshing the package list")
  shellAsync("nimble refresh 2>&1") do (o: string, code: int):
    progressDone()
    if code == 0:
      loaded = false
      cache.setLen(0)
      toast("Nimble: the package list is refreshed — " & $load().len & " packages")
    elif code == 127: warn("Nimble: nimble is not installed")
    else:
      let ls = o.strip.splitLines
      warn("Nimble: nimble refresh failed — " & (if ls.len > 0: ls[^1] else: "exit code " & $code))
