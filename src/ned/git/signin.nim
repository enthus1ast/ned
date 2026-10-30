# ── signing in to GitHub: GitHub takes no password from git (since 2021), so when a push, pull or fetch needs a
#    login ned offers the ways that work — the GitHub CLI (signs in in the browser and becomes git's credential
#    helper) or an SSH key of this device. ned never asks for, sees or stores a token ──

var
  ghAccountAsked = false
  ghRemoteUrls: Table[string, (float, string)]   # repo root → (when read, its remote's URL)

proc gitRemoteUrl(root: string, remote = "origin"): string =
  ## the URL of a repository's remote (read again after a minute)
  let now = epochTime()
  let key = root & "\t" & remote
  if key in ghRemoteUrls and now - ghRemoteUrls[key][0] < 60: return ghRemoteUrls[key][1]
  let (ok, o, _) = runFilter("git remote get-url " & quoteShell(remote) & " 2>/dev/null", "", root, 3000)
  result = if ok: o.strip else: ""
  ghRemoteUrls[key] = (now, result)

proc githubRepoOf(url: string): (string, string) =
  ## (owner, repository) of a github.com URL — https://github.com/o/r(.git), git@github.com:o/r, ssh://git@github.com/o/r
  var rest = ""
  for pre in ["https://github.com/", "http://github.com/", "git@github.com:", "ssh://git@github.com/",
              "ssh://github.com/", "git://github.com/"]:
    if url.startsWith(pre):
      rest = url[pre.len .. ^1]
      break
  if rest.len == 0:
    # https://user@github.com/o/r
    let at = url.find("@github.com/")
    if url.startsWith("https://") and at > 0: rest = url[at + 12 .. ^1]
  if rest.endsWith(".git"): rest.setLen(rest.len - 4)
  rest = rest.strip(chars = {'/'})
  let parts = rest.split('/')
  if parts.len == 2 and parts[0].len > 0 and parts[1].len > 0 and
     (parts[0] & parts[1]).allCharsInSet(IdentChars + {'-', '.'}):
    return (parts[0], parts[1])
  ("", "")

proc ghSignedIn(): bool =
  ## is the GitHub CLI signed in to github.com? (no network: gh keeps its own login)
  if not haveExe("gh"): return false
  let (ok, _, _) = runFilter("gh auth status --hostname github.com >/dev/null 2>&1", "", getHomeDir(), 5000)
  ok

proc ghAskAccount() =
  ## who the GitHub CLI pushes as — once, in the background (for the Git dock)
  if ghAccountAsked or not haveExe("gh"): return
  ghAccountAsked = true
  discard startJob(jkTool, "gh api user --jq .login 2>/dev/null", getHomeDir(), proc(j: Job) =
    let l = j.output.strip
    if j.code == 0 and l.len > 0 and l.len < 60 and l.allCharsInSet(IdentChars + {'-'}):
      ghAccount = l
      needRender = true)

proc remoteOfArgs(root, args: string): string =
  ## the remote a push / pull / fetch goes to: named in it, else the branch's, else origin
  let w = args.splitWhitespace()
  for i in 1 ..< w.len:
    let a = w[i].strip(chars = {'\''})
    if a.startsWith("-"): continue
    let (ok, o, _) = runFilter("git remote 2>/dev/null", "", root, 3000)
    if ok and a in o.splitLines: return a
    break
  let (ok, o, _) = runFilter("git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null", "", root, 3000)
  if ok and '/' in o: return o.strip.split('/')[0]
  "origin"

proc sshPubKey(): string =
  ## this device's public SSH key file ("" when it has none)
  for k in ["id_ed25519.pub", "id_ecdsa.pub", "id_rsa.pub"]:
    let p = getHomeDir() / ".ssh" / k
    if fileExists(p): return p
  ""

proc ghRetry(root, args: string) =
  ## the git command that wanted a login, again
  if gitHome() == root: gitNet(args, "Done")

proc ghSignIn(root, args: string) =
  ## the GitHub CLI: signed in already → it becomes git's credential helper and the command runs again; else it
  ## signs you in in the browser (a one-time code), in the terminal, then the command runs there
  let then = if args.len > 0: " && git " & args else: ""
  if not haveExe("gh"):
    runInTerm(installHint("gh", "gh") & " && gh auth login --hostname github.com --git-protocol https --web" &
              " && gh auth setup-git --hostname github.com" & then)
    info("Installing the GitHub CLI, then signing in — follow it in the terminal")
    return
  if ghSignedIn():
    info("Letting git use your GitHub CLI sign-in…")
    discard startJob(jkGit, "gh auth setup-git --hostname github.com", root, proc(j: Job) =
      if j.code != 0:
        error("gh auth setup-git: " & j.output.strip.splitLines()[^1])
        return
      ghAccountAsked = false
      ghAskAccount()
      if args.len > 0: ghRetry(root, args)
      else: info("git now signs in to GitHub with the GitHub CLI"))
    return
  runInTerm("gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git --hostname github.com" &
            then)
  ghAccountAsked = false
  info("Sign in in the browser with the code the terminal shows — git asks no more after that")

proc sshUseRemote(root, remote, url, args: string) =
  ## the remote over SSH (git@github.com:owner/repo.git), then the command again
  let (owner, repo) = githubRepoOf(url)
  if owner.len == 0:
    if args.len > 0: ghRetry(root, args)
    return
  let sshUrl = "git@github.com:" & owner & "/" & repo & ".git"
  if url == sshUrl:
    if args.len > 0: runInTerm("git " & args)      # (the first connection asks to trust GitHub's host key)
    return
  discard startJob(jkGit, "git remote set-url " & quoteShell(remote) & " " & quoteShell(sshUrl), root, proc(j: Job) =
    ghRemoteUrls.clear()
    if j.code != 0:
      error("git remote set-url: " & j.output.strip)
      return
    info(remote & " now goes over SSH: " & sshUrl)
    # (the first connection asks to trust GitHub's host key: in the terminal)
    if args.len > 0: runInTerm("git " & args))

proc sshKeySetup(root, remote, url, args: string) =
  ## an SSH key for GitHub: made in the terminal when this device has none (you choose its passphrase there);
  ## added to your account by the GitHub CLI when it is signed in, else copied for you to paste on GitHub's page
  let key = sshPubKey()
  if key.len == 0:
    runInTerm("ssh-keygen -t ed25519 -C " & quoteShell("ned on " & getEnv("HOSTNAME", "this device")))
    toast("Making an SSH key in the terminal — when it is done, run Git: sign in to GitHub again to add it", 3,
          "Again", proc() = sshKeySetup(root, remote, url, args), 30000)
    return
  if ghSignedIn():
    info("Adding your SSH key to GitHub…")
    discard startJob(jkGit, "gh ssh-key add " & quoteShell(key) & " --title " & quoteShell("ned " & extractFilename(key)) &
                     " 2>&1", root, proc(j: Job) =
      let o = j.output.strip
      if j.code != 0 and "already" notin o.toLowerAscii:
        error("gh ssh-key add: " & (if o.len > 0: o.splitLines()[^1] else: "failed"))
        return
      sshUseRemote(root, remote, url, args))
    return
  var pub = ""
  try: pub = readFile(key).strip
  except CatchableError: discard
  if pub.len == 0 or "PRIVATE" in pub: return            # (a public key only, never the private one)
  clipSet(pub)
  openInBrowser("https://github.com/settings/ssh/new")
  toast("Your public SSH key is copied: paste it on GitHub's page (Settings › SSH keys › New), save, then press Done",
        3, "Done", proc() = sshUseRemote(root, remote, url, args), 120000)

proc githubSignInMenu(root, args, why: string) =
  ## the ways to sign in, for a GitHub remote; `args`: the git command to run again after (may be "")
  let remote = if args.len > 0: remoteOfArgs(root, args) else: "origin"
  let url = gitRemoteUrl(root, remote)
  let ssh = url.startsWith("git@") or url.startsWith("ssh://")
  var items: seq[(string, string, Action)]
  let r = root
  let a = args
  if not ssh:
    items.add act("Sign in with GitHub", (if haveExe("gh"): "in the browser, with the GitHub CLI — git asks no more"
                                          else: "installs the GitHub CLI, then you sign in in the browser"),
                  proc() = ghSignIn(r, a))
    items.add act("Use an SSH key", "this device's key, added to your GitHub account; " & remote & " switches to SSH",
                  proc() = sshKeySetup(r, remote, url, a))
  else:
    items.add act("Set up an SSH key", (if sshPubKey().len > 0: "add this device's key to your GitHub account"
                                        else: "make one, then add it to your GitHub account"),
                  proc() = sshKeySetup(r, remote, url, a))
    let (owner, repo) = githubRepoOf(url)
    if owner.len > 0:
      let httpsUrl = "https://github.com/" & owner & "/" & repo & ".git"
      items.add act("Use HTTPS and sign in with GitHub", remote & " → " & httpsUrl & ", then the GitHub CLI", proc() =
        discard startJob(jkGit, "git remote set-url " & quoteShell(remote) & " " & quoteShell(httpsUrl), r, proc(j: Job) =
          ghRemoteUrls.clear()
          if j.code == 0: ghSignIn(r, a)
          else: error("git remote set-url: " & j.output.strip)))
  if a.len > 0:
    items.add act("Type a login in the terminal", "a personal access token as the password — not your password",
                  proc() = runInTerm("git " & a))
  openActions(why, items)

proc gitLoginNeeded(args, root, output: string) =
  ## a push / pull / fetch the server refused for a login: for GitHub, the ways that work; elsewhere, the
  ## terminal, where git asks
  let remote = remoteOfArgs(root, args)
  let url = gitRemoteUrl(root, remote)
  if "github.com" notin url:
    runInTerm("git " & args)
    info("git needs your login — finish it in the terminal")
    return
  let why = if "Host key verification" in output: ""
            elif url.startsWith("git@") or url.startsWith("ssh://"): "GitHub did not take this device's SSH key — set one up"
            else: "GitHub needs you to sign in (it takes no password from git)"
  if why.len == 0:
    runInTerm("git " & args)                       # (GitHub's host key, the first time: say yes in the terminal)
    info("ssh asks whether to trust GitHub's host key — answer in the terminal")
    return
  githubSignInMenu(root, args, why)

proc cmdGithubSignIn() =
  ## the command "Git: sign in to GitHub": offers the sign-in ways for the current repository's remote; with no
  ## repository open it just reports the GitHub CLI's account, or starts the CLI's sign-in when it is not signed in
  let root = gitHome()
  if root.len == 0:
    if haveExe("gh") and ghSignedIn(): info("The GitHub CLI is signed in" & (if ghAccount.len > 0: " as @" & ghAccount else: ""))
    else: ghSignIn(getHomeDir(), "")
    return
  githubSignInMenu(root, "", "Sign in to GitHub — so push and pull ask no more")
