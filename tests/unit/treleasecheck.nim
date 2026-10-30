# Checking a release before ned --update installs it (src/ned/app/releasecheck.nim): files against SHA256SUMS, and
# SHA256SUMS against its ssh signature (a key made here with ssh-keygen) — a changed file, a changed SHA256SUMS, a
# signature by another key, a missing signature once ned has a key: refused; no key in ned yet: the SHA-256 only

import std/[os, osproc, strutils, unittest]
import ../../src/ned/core/sha256
import ../../src/ned/app/releasecheck

let dir = getTempDir() / ("ned-treleasecheck-" & $getCurrentProcessId())
let keys = dir / "keys"
let rel = dir / "release"
createDir(keys)
createDir(rel)

proc run(cmd, input: string): (bool, string) =
  ## runs a command with the text on its standard input; whether it succeeded, and its output. The release check is
  ## given this to run ssh-keygen.
  let (o, code) = execCmdEx(cmd, input = input)
  (code == 0, o)

let keygen = findExe("ssh-keygen").len > 0

proc makeKey(name: string): string =
  ## a new ed25519 key: its allowed_signers line
  discard execCmdEx("ssh-keygen -q -t ed25519 -N '' -C test -f " & quoteShell(keys / name))
  "ned-release namespaces=\"ned-release\" " & readFile(keys / name & ".pub").strip

proc sign(name: string) =
  ## signs the release folder's SHA256SUMS with the key of that name, in the ned-release namespace, replacing any
  ## earlier signature (the test fails if ssh-keygen does)
  removeFile(rel / "SHA256SUMS.sig")
  let (o, code) = execCmdEx("ssh-keygen -q -Y sign -f " & quoteShell(keys / name) & " -n ned-release " &
                            quoteShell(rel / "SHA256SUMS"))
  doAssert code == 0, o

proc writeRelease() =
  ## writes a small pretend release in the release folder: a package and a zip, a SHA256SUMS that lists their hashes,
  ## and no signature
  writeFile(rel / "ned_6.99.0_aarch64.deb", "a package\n")
  writeFile(rel / "ned-6.99.0-windows-x86_64.zip", "a zip")
  writeFile(rel / "SHA256SUMS", sha256Hex("a package\n") & "  ned_6.99.0_aarch64.deb\n" &
                                sha256Hex("a zip") & "  ned-6.99.0-windows-x86_64.zip\n")
  removeFile(rel / "SHA256SUMS.sig")

const Placeholder = "# comment\nPLACEHOLDER-RELEASE-KEY\n"

suite "release check":
  test "the shipped release-signers: a key, or the marked placeholder":
    check releaseSignerLines(ReleaseSigners).len > 0 or "PLACEHOLDER" in ReleaseSigners
    check releaseSignerLines(Placeholder).len == 0

  test "no key in ned yet: the SHA-256 only, and said":
    writeRelease()
    let r = releaseCheck(rel, @["ned_6.99.0_aarch64.deb", "ned-6.99.0-windows-x86_64.zip"], Placeholder, run, keygen)
    check r.ok and not r.signed
    check "not signed yet" in r.note
    writeFile(rel / "SHA256SUMS.sig", "whatever")
    let r2 = releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], Placeholder, run, keygen)
    check r2.ok and "no release key" in r2.note

  test "a file that is not the one listed: refused":
    writeRelease()
    writeFile(rel / "ned_6.99.0_aarch64.deb", "a package, changed\n")
    let r = releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], Placeholder, run, keygen)
    check not r.ok and "is not the file the release lists" in r.why
    writeRelease()
    writeFile(rel / "extra.deb", "x")
    check "no line for extra.deb" in releaseCheck(rel, @["extra.deb"], Placeholder, run, keygen).why
    removeFile(rel / "SHA256SUMS")
    check "has no SHA256SUMS" in releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], Placeholder, run, keygen).why

  test "signed: the right key passes; another key, a changed SHA256SUMS, no signature are refused":
    if not keygen: skip()
    else:
      let good = makeKey("good")
      let other = makeKey("other")
      writeRelease()
      sign("good")
      let r = releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], "# k\n" & good & "\n", run, true)
      check r.ok and r.signed and r.note.len == 0
      # (two keys trusted, the second one signed)
      check releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], other & "\n" & good & "\n", run, true).ok
      sign("other")
      let r2 = releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], good, run, true)
      check not r2.ok and "not signed by the key ned trusts" in r2.why
      sign("good")
      writeFile(rel / "SHA256SUMS", readFile(rel / "SHA256SUMS").replace("  ned-6.99.0", "  ned-6.98.0"))
      check not releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], good, run, true).ok
      writeRelease()
      let r3 = releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], good, run, true)
      check not r3.ok and "not signed" in r3.why
      sign("good")
      let r4 = releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], good, run, false)
      check not r4.ok and "ssh-keygen" in r4.why
      # (signed, but the file changed after: the SHA-256 still catches it)
      writeFile(rel / "ned_6.99.0_aarch64.deb", "evil\n")
      check "is not the file" in releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], good, run, true).why
      # (a signature for another namespace — another use of the same key — does not fit)
      writeRelease()
      discard execCmdEx("ssh-keygen -q -Y sign -f " & quoteShell(keys / "good") & " -n file " &
                        quoteShell(rel / "SHA256SUMS"))
      check not releaseCheck(rel, @["ned_6.99.0_aarch64.deb"], good, run, true).ok

  test "the names SHA256SUMS lists":
    check releaseListed(sha256Hex("x") & "  a.deb\n" & sha256Hex("y") & " *dist/b.zip\n# c\n") == @["a.deb", "b.zip"]

removeDir(dir)
