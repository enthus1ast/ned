## Checking a release before it is installed. A release has SHA256SUMS (the SHA-256 of each of its files, as
## sha256sum writes them) and, once releases are signed, SHA256SUMS.sig: an ssh signature (`ssh-keygen -Y sign -n
## ned-release`) by a key whose public half is in release-signers, read into ned when it is built. A file whose
## SHA-256 is not the one in SHA256SUMS, or a SHA256SUMS whose signature does not match, is refused. A module of its
## own: `ned --update` runs it with ned's way of starting programs, the unit tests with theirs.

import std/[os, strutils]
import ../core/sha256

const
  ReleaseNamespace* = "ned-release"              # (what the signature is for: no other file signed with the key fits)
  ReleaseSignersFile* = "src/ned/app/release-signers"
  ReleaseSigners* = staticRead("release-signers")

type
  ReleaseRun* = proc(cmd, input: string): (bool, string) {.closure.}
    ## runs a shell command with `input` on its stdin: (it succeeded, what it printed)
  ReleaseCheck* = object
    ok*: bool
    signed*: bool                  # the signature was checked
    note*: string                  # to say once: why only the SHA-256 was checked
    why*: string                   # why it was refused

func releaseSignerLines*(text: string): seq[string] =
  ## the keys of a release-signers text: its allowed_signers lines (not the comments, not the placeholder)
  for raw in text.splitLines:
    let l = raw.strip
    if l.len == 0 or l.startsWith("#") or "PLACEHOLDER" in l: continue
    if l.splitWhitespace.len >= 3: result.add l

proc releaseVerifySig*(sums, sig: string, signers: seq[string], tmpDir: string, run: ReleaseRun): (bool, string) =
  ## does `sig` sign `sums` with one of the keys? (ssh-keygen -Y verify) — (yes, who) or (no, what ssh-keygen said)
  let allowed = tmpDir / "allowed_signers"
  let sigFile = tmpDir / "SHA256SUMS.sig"
  try:
    createDir(tmpDir)
    writeFile(allowed, signers.join("\n") & "\n")
    writeFile(sigFile, sig)
  except CatchableError as e: return (false, e.msg)
  var said = ""
  for l in signers:
    let who = l.splitWhitespace[0]
    let (ok, o) = run("ssh-keygen -Y verify -f " & quoteShell(allowed) & " -I " & quoteShell(who) & " -n " &
                      ReleaseNamespace & " -s " & quoteShell(sigFile), sums)
    if ok: return (true, who)
    if said.len == 0: said = o.strip.splitLines()[0 .. ^1].join(" ").strip
  (false, (if said.len > 0: said else: "ssh-keygen found no matching key"))

proc releaseCheck*(dir: string, files: seq[string], signersText: string, run: ReleaseRun,
                   haveKeygen: bool): ReleaseCheck =
  ## checks `files` (names of files in `dir`) against dir/SHA256SUMS, and SHA256SUMS against dir/SHA256SUMS.sig
  ## when ned has a release key (`signersText`: release-signers) — every file must match
  let sumsPath = dir / "SHA256SUMS"
  if not fileExists(sumsPath):
    result.why = "the release has no SHA256SUMS, so " & (if files.len == 1: files[0] else: "its files") &
                 " cannot be checked"
    return
  let sums = readFile(sumsPath)
  let signers = releaseSignerLines(signersText)
  let sigPath = dir / "SHA256SUMS.sig"
  if signers.len > 0:
    if not fileExists(sigPath):
      result.why = "the release is not signed (it has no SHA256SUMS.sig), and this ned expects signed releases"
      return
    if not haveKeygen:
      result.why = "checking the release's signature needs ssh-keygen (Termux: pkg install openssh; elsewhere " &
                   "OpenSSH's client)"
      return
    let (ok, who) = releaseVerifySig(sums, readFile(sigPath), signers, dir / ".ned-verify", run)
    try: removeDir(dir / ".ned-verify")
    except CatchableError: discard
    if not ok:
      result.why = "SHA256SUMS is not signed by the key ned trusts (" & ReleaseSignersFile & "): " & who
      return
    result.signed = true
  elif fileExists(sigPath):
    result.note = "this ned has no release key yet (" & ReleaseSignersFile & "), so the release's signature " &
                  "cannot be checked: checking the SHA-256 only"
  else:
    result.note = "the release is not signed yet: checking the SHA-256 only"
  for f in files:
    let want = sha256SumFor(sums, f)
    if want.len == 0:
      result.why = "SHA256SUMS has no line for " & f
      return
    var got = ""
    try: got = sha256FileHex(dir / f)
    except CatchableError:
      result.why = f & " cannot be read"
      return
    if got != want:
      result.why = f & " is not the file the release lists: its SHA-256 is " & got & ", SHA256SUMS says " & want &
                   " (changed, or the download broke)"
      return
  result.ok = true

func releaseListed*(sums: string): seq[string] =
  ## the names SHA256SUMS lists (their base names)
  for raw in sums.splitLines:
    let l = raw.strip(leading = false)
    if l.len < 66 or l.startsWith("#") or l[64] != ' ': continue
    var n = l[65 .. ^1]
    if n.startsWith("*") or n.startsWith(" "): n = n[1 .. ^1]
    result.add n[n.rfind('/') + 1 .. ^1]
