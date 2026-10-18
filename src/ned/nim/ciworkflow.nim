# ── Nim: add a CI workflow — .github/workflows/ci.yml for the project: its dependencies, build and tests on Linux
#    and macOS with the oldest Nim its .nimble allows and the newest; optionally ned's lint (GitHub annotations on
#    the pull request) and a format check, with ned built from the repository you give (nim.ciNedRepository) ──

proc ciRepoOk(url: string): bool =
  ## a plain https or ssh git link: no login in it, nothing YAML or the shell would read as more than a link
  if url.len < 8 or gitLinkHasSecret(url): return false
  if not (url.startsWith("https://") or url.startsWith("git@")): return false
  for c in url:
    if c notin {'A'..'Z', 'a'..'z', '0'..'9', '.', '_', '~', ':', '/', '@', '+', '-'}: return false
  true

proc ciNimVersions(): seq[string] =
  ## the Nims to test with: the oldest the .nimble allows (requires "nim >= 2.0.0" → 2.0.0) and the newest
  let need = tcProjectNeeds()
  for part in need.split('&'):
    let p = part.strip
    for op in [">=", "==", "^=", "~="]:
      if p.startsWith(op):
        let v = p[op.len .. ^1].strip
        if ecVersion(v).len >= 2 and v notin result: result.add v
  result.add "stable"

proc ciWorkflowText(info: NimbleInfo, lint, fmtCheck: bool, nedRepo: string): string =
  let vers = ciNimVersions()
  var vq: seq[string]
  for v in vers: vq.add "'" & v & "'"
  let name = if info.name.len > 0: info.name else: extractFilename(rootDir)
  var hasTests = dirExists(rootDir / "tests")
  for (t, _) in info.tasks:
    if t == "test": hasTests = true
  let mainFile = (if info.srcDir.len > 0: info.srcDir & "/" else: "") & name & ".nim"
  result = "# CI for " & name & ": its dependencies, build and tests with Nim " & vers.join(" and ") &
           " on Linux and macOS\n# (made by ned: Nim › add a CI workflow — edit freely)\n" &
           "name: CI\n\non:\n  push:\n    branches: [main, master]\n  pull_request:\n  workflow_dispatch:\n\n" &
           "permissions:\n  contents: read\n\njobs:\n" &
           "  test:\n    name: Nim ${{ matrix.nim }} · ${{ matrix.os }}\n    runs-on: ${{ matrix.os }}\n" &
           "    strategy:\n      fail-fast: false\n      matrix:\n        os: [ubuntu-latest, macos-latest]\n" &
           "        nim: [" & vq.join(", ") & "]\n    steps:\n      - uses: actions/checkout@v4\n" &
           "      - uses: jiro4989/setup-nim-action@v2\n        with:\n          nim-version: ${{ matrix.nim }}\n" &
           "          repo-token: ${{ secrets.GITHUB_TOKEN }}\n" &
           "      - name: Dependencies\n        run: nimble install -y --depsOnly\n"
  if info.bins.len > 0: result.add "      - name: Build\n        run: nimble build -y\n"
  if hasTests: result.add "      - name: Tests\n        run: nimble test -y\n"
  elif fileExists(rootDir / mainFile): result.add "      - name: Check\n        run: nim check --hints:off " & mainFile & "\n"
  if lint or fmtCheck:
    result.add "\n  lint:\n    name: ned's lint" & (if fmtCheck: " and format check" else: "") &
               "\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v4\n" &
               "      - uses: jiro4989/setup-nim-action@v2\n        with:\n          nim-version: stable\n" &
               "          repo-token: ${{ secrets.GITHUB_TOKEN }}\n" &
               "      - name: Build ned\n        run: |\n          git clone --depth 1 " & nedRepo & " \"$RUNNER_TEMP/ned\"\n" &
               "          mkdir -p \"$HOME/.local/bin\"\n" &
               "          nim c -d:release --hints:off -o:\"$HOME/.local/bin/ned\" \"$RUNNER_TEMP/ned/src/ned.nim\"\n"
    if fmtCheck:
      result.add "          nim c -d:release --hints:off -o:\"$HOME/.local/bin/nedfmt\" \"$RUNNER_TEMP/ned/src/nedfmt.nim\"\n"
    result.add "          echo \"$HOME/.local/bin\" >> \"$GITHUB_PATH\"\n" &
               "      - name: Dependencies\n        run: nimble install -y --depsOnly\n"
    if lint:
      result.add "      - name: Lint (ned)\n        run: ned --lint --format:github .\n"
    if fmtCheck:
      result.add "      - name: Formatted (nedfmt, nph's style)\n        run: nedfmt --check .\n"

proc cmdAddCiWorkflow() =
  ## Nim › add a CI workflow: what it runs, then the file written (not committed) and opened to read
  if rootDir.len == 0:
    info("Open a project folder first")
    return
  loadNimbleInfo()
  let info0 = nimble
  let target0 = rootDir / ".github" / "workflows" / "ci.yml"
  let write = proc(lint, fmtCheck: bool, repo: string) =
    let target = if fileExists(target0): rootDir / ".github" / "workflows" / "ci-ned.yml" else: target0
    if fileExists(target):
      info(relPath(target) & " is there already — opened; delete it to make it again")
      discard openFile(target)
      return
    try:
      createDir(parentDir(target))
      writeFile(target, ciWorkflowText(info0, lint, fmtCheck, repo))
    except CatchableError as e:
      error("Could not write " & relPath(target) & ": " & e.msg)
      return
    discard openFile(target)
    info("Wrote " & relPath(target) & " — commit and push it to run (nothing is committed for you)")
  let withNed = proc(lint, fmtCheck: bool) =
    let have = sStr("nim.ciNedRepository").strip
    if have.len > 0 and ciRepoOk(have):
      write(lint, fmtCheck, have)
      return
    askText("ned's git repository (the CI builds ned from it), e.g. https://github.com/OWNER/ned", "https://github.com/",
            proc(t: string) =
      let u = t.strip
      if not ciRepoOk(u):
        error("Not a plain https:// or git@ link (and no login in it): " & u)
        return
      setSetting("nim.ciNedRepository", %u)
      write(lint, fmtCheck, u))
  let vers = ciNimVersions().join(" and ")
  openActions("Add a CI workflow (GitHub Actions)", @[
    act("Build and test", "Linux and macOS · Nim " & vers & " · nimble install, build, test", proc() =
      write(false, false, "")),
    act("Build, test and ned's lint", "…and the engine's checks as annotations on the pull request", proc() =
      withNed(true, false)),
    act("Build, test, lint and format check", "…and nedfmt --check (nph's style)", proc() =
      withNed(true, true))])
