# ── ned --update: the newest release (GitHub's newest release, else its newest version tag), installed the way this
#    ned was — built with nimble, a checkout built in place, or a release's Termux package when it has one. It says what it will run and asks first (--yes: does not ask; --check: only says). A package
#    it downloads is checked before it is installed: its SHA-256 against the release's SHA256SUMS, and SHA256SUMS
#    against its signature by a key in release-signers (app/releasecheck.nim); --verify DIR checks a release
#    downloaded by hand the same way ──

const NedRepo = "foxoman/ned"

proc updTestMode(): bool =
  ## $NED_UPDATE_URL names a local file: the tests' fake release — only then do NED_UPDATE_HOW and
  ## NED_RELEASE_SIGNERS count
  let s = getEnv("NED_UPDATE_URL")
  s.len > 0 and not (s.startsWith("https://") or s.startsWith("http://"))

proc updSigners(): string =
  ## the keys releases are signed with: release-signers as ned was built with it (the tests': their own file)
  let f = getEnv("NED_RELEASE_SIGNERS")
  if f.len > 0 and updTestMode():
    try: return readFile(f)
    except CatchableError: discard
  ReleaseSigners

proc updVerify(dir: string, files: seq[string]): bool =
  ## the files (in dir, with the release's SHA256SUMS and SHA256SUMS.sig) checked: says what was checked, or why
  ## one is refused
  let run: ReleaseRun = proc(cmd, input: string): (bool, string) =
    let (ok, o, e) = runFilter(cmd, input, dir, 30_000)
    (ok, o & e)
  let r = releaseCheck(dir, files, updSigners(), run, findExe("ssh-keygen").len > 0)
  if r.note.len > 0: echo "Note: ", r.note
  if not r.ok:
    echo "Refused: ", r.why
    return false
  echo "Checked ", files.join(", "), ": ", (if r.signed: "the SHA-256 and the release's signature" else: "the SHA-256"),
       " match"
  true

proc updVerifyDir(dir: string, names: seq[string]): int =
  ## ned --update --verify DIR [FILE…]: the files (all of those SHA256SUMS lists that are in DIR, when none is named)
  if not fileExists(dir / "SHA256SUMS"):
    echo "There is no SHA256SUMS in ", dir, " — download it from the release's page with the files"
    return 1
  var files = names
  if files.len == 0:
    for n in releaseListed(readFile(dir / "SHA256SUMS")):
      if fileExists(dir / n): files.add n
    if files.len == 0:
      echo "None of the files SHA256SUMS lists is in ", dir
      return 1
  if updVerify(dir, files): 0 else: 1

const
  UpdReleaseUrl = "https://api.github.com/repos/" & NedRepo & "/releases/latest"
  UpdTagsUrl = "https://api.github.com/repos/" & NedRepo & "/tags?per_page=100"

proc updNewestOf(j: JsonNode): (string, JsonNode) =
  ## the newest version in GitHub's answer — a release ({"tag_name", "body", "assets"}) or the list of tags
  ## ([{"name"}]: the highest vX.Y.Z) — with the release (a tag: one made of it, without files or notes)
  if j == nil: return ("", nil)
  if j.kind == JObject and j{"tag_name"}.getStr.len > 0:
    return (j{"tag_name"}.getStr.strip(trailing = false, chars = {'v', 'V'}), j)
  if j.kind == JArray:
    var best = ""
    for t in j:
      let v = t{"name"}.getStr.strip(trailing = false, chars = {'v', 'V'})
      if v.len > 0 and v[0] in Digits and '.' in v and (best.len == 0 or verCmp(v, best) > 0): best = v
    if best.len > 0: return (best, %*{"tag_name": "v" & best, "assets": []})
  ("", nil)

proc updLatest(): (string, JsonNode) =
  ## the newest release: (its version, the release) — GitHub's newest release, else its newest version tag (a
  ## version may be only a tag: built with nimble); $NED_UPDATE_URL (a URL, or a file of the same JSON — a release
  ## or a list of tags) in its place for tests; ("", nil) when it cannot be read
  proc fetch(src: string): JsonNode =
    ## GitHub's answer at src (a URL, or a file for tests), nil when there is none
    var body = ""
    if src.startsWith("https://") or src.startsWith("http://"):
      if findExe("curl").len == 0: return nil
      let (ok, o, _) = runFilter("curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' -- " &
                                 quoteShell(src), "", getCurrentDir(), 30_000)
      if not ok: return nil
      body = o
    else:
      try: body = readFile(src)
      except CatchableError: return nil
    try: result = parseJson(body)
    except CatchableError: result = nil
  let test = getEnv("NED_UPDATE_URL")
  if test.len > 0: return updNewestOf(fetch(test))
  let rel = updNewestOf(fetch(UpdReleaseUrl))
  let tag = updNewestOf(fetch(UpdTagsUrl))
  if rel[0].len > 0 and (tag[0].len == 0 or verCmp(rel[0], tag[0]) >= 0): rel else: tag

proc updHow(): (string, string) =
  ## how this ned was installed: ("termux", "") the package · ("nimble", "") · ("source", the checkout) ·
  ## ("", "") not known
  let exe = getAppFilename()
  if updTestMode() and getEnv("NED_UPDATE_HOW") == "termux": return ("termux", "")
  if isTermux() and exe.startsWith(getEnv("PREFIX") & "/bin/"):
    let (ok, _, _) = runFilter("dpkg -s ned", "", getCurrentDir(), 5000)
    if ok: return ("termux", "")
  let nb = getEnv("NIMBLE_DIR", getHomeDir() / ".nimble")
  if exe.startsWith(nb & "/") or "/.nimble/" in exe: return ("nimble", "")
  var d = parentDir(exe)
  for _ in 0 .. 3:
    if fileExists(d / "ned.nimble") and dirExists(d / ".git"): return ("source", d)
    d = parentDir(d)
  ("", "")

proc updateMain(args: seq[string]): int =
  ## ned --update [--check] [--yes] · ned --update --verify DIR [FILE…]
  let yes = "--yes" in args or "-y" in args
  let vi = args.find("--verify")
  if vi >= 0:
    if vi + 1 >= args.len:
      echo "ned --update --verify needs the folder with the release's files and its SHA256SUMS"
      return 2
    var names: seq[string]
    for a in args[vi + 2 .. ^1]:
      if not a.startsWith("-"): names.add a
    return updVerifyDir(args[vi + 1], names)
  echo "ned ", Version, " — looking for a newer release…"
  let (latest, j) = updLatest()
  if latest.len == 0:
    echo "Could not read the list of ned's releases (https://github.com/", NedRepo, "/releases) — is curl there, " &
         "and the network?"
    return 1
  if verCmp(latest, Version) <= 0:
    echo "This is the newest: ned ", Version
    return 0
  echo "ned ", latest, " is out (this is ", Version, ")"
  if "--check" in args: return 0
  let (how, where) = updHow()
  let tag = j{"tag_name"}.getStr
  var cmds: seq[string]
  var downloads: seq[(string, string, bool)]     # (URL, where it goes, its progress shown)
  var dl = ""                                    # (the folder of the downloads: ned's private one)
  var check: seq[string]                         # the files checked against SHA256SUMS before cmds run
  case how
  of "termux":
    var url, sumsUrl, sigUrl = ""
    for a in jitems(j{"assets"}):
      let n = a{"name"}.getStr
      let u = a{"browser_download_url"}.getStr
      if n.startsWith("ned_") and n.endsWith("_aarch64.deb"): url = u
      elif n == "SHA256SUMS": sumsUrl = u
      elif n == "SHA256SUMS.sig": sigUrl = u
    if url.len == 0:
      # (no package to install: ned built on this device with nimble — Nim and git from Termux's packages)
      echo "There is no Termux package of ", latest, " to install: it is built here with nimble instead (a few minutes),"
      echo "into ~/.nimble/bin — put that before $PREFIX/bin in PATH (or apt remove ned) to use it."
      cmds = @["pkg install -y nim git clang",
               "nimble install -y " & quoteShell("https://github.com/" & NedRepo & "@#" & tag)]
    elif sumsUrl.len == 0:
      echo "The release has no SHA256SUMS, so its package cannot be checked — nothing was installed. It is on " &
           "https://github.com/", NedRepo, "/releases/tag/", tag, " if you want it anyway."
      return 1
    else:
      dl = privDir() / ("update-" & $getCurrentProcessId())
      let deb = dl / extractFilename(url)
      downloads.add (sumsUrl, dl / "SHA256SUMS", false)
      if sigUrl.len > 0: downloads.add (sigUrl, dl / "SHA256SUMS.sig", false)
      downloads.add (url, deb, true)
      check = @[extractFilename(url)]
      cmds = @["apt install -y " & quoteShell(deb)]
  of "nimble":
    cmds = @["nimble install -y " & quoteShell("https://github.com/" & NedRepo & "@#" & tag)]
  of "source":
    let exe = getAppFilename()
    cmds = @["git -C " & quoteShell(where) & " pull --ff-only",
             "cd " & quoteShell(where) & " && nim c -d:release --opt:speed -d:strip --hints:off -o:" & quoteShell(exe) &
               " src/ned.nim"]
  else:
    echo "ned does not know how it was installed here. Any of these brings ", latest, ":"
    echo "  nimble:   nimble install https://github.com/", NedRepo, "@#", tag, "   (Termux too: pkg install nim git)"
    echo "  a script: curl -fsSL https://raw.githubusercontent.com/", NedRepo, "/main/install.sh | sh"
    return 1
  if downloads.len > 0:
    echo "It will download ", extractFilename(downloads[^1][0]), " and the release's SHA256SUMS",
         (if downloads.len > 2: " and its signature" else: ""), ", check the package against them, then run:"
  else: echo "It will run:"
  for c in cmds: echo "  ", c
  if not yes:
    stdout.write "Go ahead? [y/N] "
    stdout.flushFile()
    var answer = ""
    try: answer = stdin.readLine.strip.toLowerAscii
    except EOFError: discard
    if answer notin ["y", "yes"]:
      echo "Nothing changed"
      return 1
  defer:
    if dl.len > 0:
      try: removeDir(dl)
      except CatchableError: discard
  if downloads.len > 0:
    try: createDir(dl)
    except CatchableError as e:
      echo "Cannot make a folder for the download (", e.msg, ") — ned is still ", Version
      return 1
  for (url, dest, progress) in downloads:
    let c = "curl -fL" & (if progress: "" else: "sS") & " --max-time 300 -o " & quoteShell(dest) & " -- " &
            quoteShell(url)
    if progress: echo "$ ", c
    let code = execShellCmd(c)
    if code != 0:
      echo "The download failed (", code, ") — ned is still ", Version
      return code
  if check.len > 0 and not updVerify(dl, check):
    echo "Nothing was installed — ned is still ", Version, ". If this goes on, tell ned's maker: https://github.com/",
         NedRepo, "/issues"
    return 1
  for c in cmds:
    echo "$ ", c
    let code = execShellCmd(c)
    if code != 0:
      echo "That failed (", code, ") — ned is still ", Version
      return code
  echo "Updated to ned ", latest, " — start ned again to use it"
  0

# ── in the editor: once a day, a little after ned starts, a look in the background for a newer release on GitHub
#    (update.check); a note and a mark in the status bar when there is one, Help › Check for updates to look now,
#    Help › What's new in the newest ned for its notes ──

var updLookedThisRun = false   # this run has had its look (or will not have one)

# where the last look's findings are kept: when, the newest version, its notes, a version you chose to skip
proc updStatePath(): string = stateDir() / "update.json"

proc updState(): JsonNode =
  ## what the last look found ({} before the first)
  try: result = parseJson(readFile(updStatePath()))
  except CatchableError: result = newJObject()
  if result.kind != JObject: result = newJObject()

proc updSaveState(j: JsonNode) =
  ## the findings kept for the next run
  try:
    createDir(stateDir())
    writeFile(updStatePath(), $j)
  except CatchableError: discard

proc updNoteNewer(latest: string) =
  ## a newer release is known: the status bar's mark, unless it is the version you skipped
  updNewer = if verCmp(latest, Version) > 0 and updState(){"skipped"}.getStr != latest: latest else: ""

proc updShowNotes() =
  ## the newest release's notes in a tab of their own, with how to update
  let st = updState()
  let latest = st{"latest"}.getStr
  if latest.len == 0 or verCmp(latest, Version) <= 0:
    info("ned " & Version & " is the newest")
    return
  let notes = st{"notes"}.getStr.strip
  var t = "# ned " & latest & "\n\nThis is ned " & Version & ". **Help › Update ned…** brings " & latest &
          " the way this ned was installed — built with nimble, or a source checkout pulled and built again (it says" &
          " what it will do and asks first); in a terminal, `ned --update`. To be told nothing more about " & latest &
          ": palette › *Help: skip this update*.\n\n"
  if notes.len > 0: t.add notes & "\n"
  let url = st{"url"}.getStr
  if url.len > 0: t.add "\n" & url & "\n"
  discard openScratch("ned " & latest, t, langByName("Markdown"))

proc updSkip() =
  ## Help: skip this update — the newest version is not mentioned again (a newer one is)
  var st = updState()
  let latest = st{"latest"}.getStr
  if latest.len == 0 or verCmp(latest, Version) <= 0:
    info("There is no newer ned to skip")
    return
  st["skipped"] = %latest
  updSaveState(st)
  updNewer = ""
  info("ned " & latest & " will not be mentioned again")

func updReadmeNotes(md, version: string): string =
  ## the README's "What's new in X.Y" for a version (its X.Y, else the README's first What's new)
  let parts = version.split('.')
  let want = "## What's new in " & (if parts.len >= 2: parts[0] & "." & parts[1] else: version)
  var at = md.find("\n" & want)
  while at >= 0 and at + 1 + want.len < md.len and md[at + 1 + want.len] in Digits:   # (6.4 is not 6.41)
    at = md.find("\n" & want, at + 1)
  if at < 0: at = md.find("\n## What's new in ")
  if at < 0: return ""
  let a = at + 1
  let e = md.find("\n## ", a + 3)
  md[a ..< (if e < 0: md.len else: e)].strip

proc updFound(latest, notes, url: string, manual: bool) =
  ## what a look found, kept for the next start; a newer version than this ned: a note with a button for what is
  ## new in it, and the status bar's mark (with `manual`, its notes at once; the same version: said so)
  var st = updState()
  st["checked"] = %epochTime()
  st["latest"] = %latest
  st["notes"] = %(if notes.len > 20_000: notes[0 ..< 20_000] & "…" else: notes)
  st["url"] = %url
  updSaveState(st)
  updNoteNewer(latest)
  if verCmp(latest, Version) <= 0:
    if manual: info("ned " & Version & " is the newest")
  elif manual: updShowNotes()
  elif updNewer.len > 0:
    toast("ned " & latest & " is out (this is " & Version & ")", 3, "What's new", proc() = updShowNotes(), 15_000)

proc updLook(manual: bool) =
  ## asks GitHub for the newest version (its tags), in the background (curl); a newer one than this ned: its What's
  ## new is read from the README at that tag, then a note with a button for it, and the status bar's mark. With
  ## `manual` (Help › Check for updates) it says either way, and why it could not look; the daily look stays quiet
  let test = getEnv("NED_UPDATE_URL")
  let src = if test.len > 0: test else: UpdTagsUrl
  let web = src.startsWith("https://") or src.startsWith("http://")
  if web and findExe("curl").len == 0:
    if manual: error("Looking for a newer ned needs curl" & (if isTermux(): " (pkg install curl)" else: ""))
    return
  if manual: info("Looking for a newer ned…")
  let cmd = if web: "curl -fsSL --max-time 15 -H 'Accept: application/vnd.github+json' -- " & quoteShell(src)
            else: "cat -- " & quoteShell(src)
  let dir = if dirExists(configDir()): configDir() else: getTempDir()
  discard startJob(jkAux, cmd, dir, proc(j: Job) =
    var latest, notes, url = ""
    if j.code == 0:
      try:
        let (v, r) = updNewestOf(parseJson(j.output))
        latest = v
        if r != nil:
          notes = r{"body"}.getStr
          url = r{"html_url"}.getStr
      except CatchableError: discard
    if latest.len == 0:
      if manual: error("Could not reach GitHub to look for a newer ned — is the network there?")
      return
    if url.len == 0: url = "https://github.com/" & NedRepo & "/blob/v" & latest & "/README.md"
    if notes.len > 0 or not web or verCmp(latest, Version) <= 0:
      updFound(latest, notes, url, manual)
      return
    # (a newer version, only a tag: its What's new from the README at that tag)
    let readme = "https://raw.githubusercontent.com/" & NedRepo & "/v" & latest & "/README.md"
    discard startJob(jkAux, "curl -fsSL --max-time 15 -- " & quoteShell(readme), dir, proc(r: Job) =
      updFound(latest, (if r.code == 0: updReadmeNotes(r.output, latest) else: ""), url, manual)))

proc updAutoLook() =
  ## (the main loop) the daily look, once a run: 20 seconds after start, with update.check on and a day after the
  ## last; meanwhile the last look's findings keep the status bar's mark
  if updLookedThisRun or msSince(startT0) < 20_000: return
  updLookedThisRun = true
  if not sBool("update.check"): return
  let st = updState()
  let latest = st{"latest"}.getStr
  if latest.len > 0: updNoteNewer(latest)
  if epochTime() - st{"checked"}.getFloat(0) >= 86_400 or getEnv("NED_UPDATE_URL").len > 0: updLook(false)
