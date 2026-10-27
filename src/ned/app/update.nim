# ── ned --update: the newest release, installed the way this ned was — the Termux package, nimble, or a checkout
#    built in place. It says what it will run and asks first (--yes: does not ask; --check: only says). A package
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

proc updLatest(): (string, JsonNode) =
  ## the newest release: (its version, GitHub's answer) — $NED_UPDATE_URL (a URL, or a file of the same JSON) in
  ## its place for tests; ("", nil) when it cannot be read
  let src = getEnv("NED_UPDATE_URL", "https://api.github.com/repos/" & NedRepo & "/releases/latest")
  var body = ""
  if src.startsWith("https://") or src.startsWith("http://"):
    if findExe("curl").len == 0: return ("", nil)
    let (ok, o, _) = runFilter("curl -fsSL --max-time 20 -H 'Accept: application/vnd.github+json' -- " &
                               quoteShell(src), "", getCurrentDir(), 30_000)
    if not ok: return ("", nil)
    body = o
  else:
    try: body = readFile(src)
    except CatchableError: return ("", nil)
  try:
    let j = parseJson(body)
    result = (j{"tag_name"}.getStr.strip(trailing = false, chars = {'v', 'V'}), j)
  except CatchableError: result = ("", nil)

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
      echo "The release has no Termux package — see https://github.com/", NedRepo, "/releases"
      return 1
    if sumsUrl.len == 0:
      echo "The release has no SHA256SUMS, so its package cannot be checked — nothing was installed. It is on " &
           "https://github.com/", NedRepo, "/releases/tag/", tag, " if you want it anyway."
      return 1
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
    echo "  Termux:   the package of the release, ned_", latest, "_aarch64.deb — pkg install ./ned_", latest, "_aarch64.deb"
    echo "  nimble:   nimble install https://github.com/", NedRepo, "@#", tag
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
