# ── ned --update: the newest release, installed the way this ned was — the Termux package, nimble, or a checkout
#    built in place. It says what it will run and asks first (--yes: does not ask; --check: only says) ──

const NedRepo = "foxoman/ned"

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
  ## ned --update [--check] [--yes]
  let yes = "--yes" in args or "-y" in args
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
  case how
  of "termux":
    var url = ""
    for a in jitems(j{"assets"}):
      let n = a{"name"}.getStr
      if n.startsWith("ned_") and n.endsWith("_aarch64.deb"): url = a{"browser_download_url"}.getStr
    if url.len == 0:
      echo "The release has no Termux package — see https://github.com/", NedRepo, "/releases"
      return 1
    let deb = getEnv("TMPDIR", "/tmp") / extractFilename(url)
    cmds = @["curl -fL --max-time 300 -o " & quoteShell(deb) & " -- " & quoteShell(url), "apt install -y " & quoteShell(deb)]
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
  echo "It will run:"
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
  for c in cmds:
    echo "$ ", c
    let code = execShellCmd(c)
    if code != 0:
      echo "That failed (", code, ") — ned is still ", Version
      return code
  echo "Updated to ned ", latest, " — start ned again to use it"
  0
