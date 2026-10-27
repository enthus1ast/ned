# ned's SHA-256 (src/ned/core/sha256.nim): what ned --update checks a download with — the NIST test vectors, every
# length around a block's edge, a text fed in pieces of every size, a big file against sha256sum (or shasum), and
# reading a release's SHA256SUMS

import std/[os, osproc, random, strutils, unittest]
import ../../src/ned/core/sha256

proc sumTool(): string =
  ## the system's own SHA-256 program ("" none): sha256sum (Linux), shasum -a 256 (macOS)
  if findExe("sha256sum").len > 0: "sha256sum"
  elif findExe("shasum").len > 0: "shasum -a 256"
  else: ""

proc systemHash(path: string): string =
  let (o, code) = execCmdEx(sumTool() & " " & quoteShell(path))
  doAssert code == 0, o
  o.split(' ')[0].strip

suite "SHA-256":
  test "the NIST test vectors (FIPS 180-4 examples)":
    check sha256Hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256Hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256Hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq") ==
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
    check sha256Hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrs" &
                    "mnopqrstnopqrstu") == "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
    check sha256Hex('a'.repeat(1_000_000)) == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"

  test "the NIST byte-oriented short messages (SHAVS)":
    # (SHA256ShortMsg.rsp: a byte, four bytes, 55 and 56 bytes — the lengths where the padding needs one block or two)
    check sha256Hex("\xbd") == "68325720aabd7c82f30f554b313d0570c95accbb7dc4b5aae11204c08ffe732b"
    check sha256Hex("\xc9\x8c\x8e\x55") == "7abc22c0ae5af26ce93dbb94433a0e0b2e119d014f8e7f65bd56c61ccccd9504"
    check sha256Hex('\0'.repeat(55)) == "02779466cdec163811d078815c633f21901413081449002f24aa3e80f0b88ef7"
    check sha256Hex('\0'.repeat(56)) == "d4817aa5497628e7c77e6b606107042bbba3130888c5f47a375e6179be789fbb"
    check sha256Hex('\0'.repeat(57)) == "65a16cb7861335d5ace3c60718b5052e44660726da4cd13bb745381b235a1785"
    check sha256Hex('\0'.repeat(64)) == "f5a5fd42d16a20302798ef6ed309979b43003d2320d9f0e8ea9831a92759fb4b"
    check sha256Hex('\0'.repeat(1000)) == "541b3e9daa09b20bf85fa273e5cbd3e80185aa4ec298e765db87742b70138a53"
    check sha256Hex('A'.repeat(1000)) == "c2e686823489ced2017f6059b8b239318b6364f6dcd835d0a519105a1eadd6e4"
    check sha256Hex('U'.repeat(1005)) == "f4d62ddec0f3dd90ea1380fa16a5ff8dc4c54b21740650f24afc4120903552b0"

  test "fed in pieces of any size: the same as all at once (every length up to 300)":
    randomize(11)
    var s = ""
    for i in 0 ..< 300: s.add char(rand(255))
    for n in 0 .. s.len:
      let whole = sha256Hex(s[0 ..< n])
      var c = sha256Init()
      var i = 0
      while i < n:
        let k = min(n - i, rand(1 .. 130))
        sha256Update(c, s[i ..< i + k])
        i += k
      check sha256ToHex(sha256Final(c)) == whole

  test "files: small ones and every length around a block, against the system's program":
    if sumTool().len == 0:
      skip()
    else:
      let d = getTempDir() / "ned-tsha256-" & $getCurrentProcessId()
      createDir(d)
      randomize(3)
      for n in [0, 1, 55, 56, 63, 64, 65, 119, 120, 127, 128, 129, 1000, 65537]:
        var s = newString(n)
        for i in 0 ..< n: s[i] = char(rand(255))
        writeFile(d / "f", s)
        check sha256FileHex(d / "f") == systemHash(d / "f")
        check sha256FileHex(d / "f", chunk = 7) == sha256Hex(s)
      removeDir(d)

  test "a big file (80 MB, read in chunks), against the system's program":
    if sumTool().len == 0:
      skip()
    else:
      let p = getTempDir() / "ned-tsha256-big-" & $getCurrentProcessId()
      var f = open(p, fmWrite)
      var block1 = newString(1 shl 20)
      randomize(5)
      for i in 0 ..< block1.len: block1[i] = char(rand(255))
      for k in 0 ..< 80:
        block1[k] = char(k)                  # (each megabyte a little different)
        f.write block1
      f.write "and a tail of 33 bytes, no block"
      f.close()
      check sha256FileHex(p) == systemHash(p)
      removeFile(p)

  test "a file that is not there: an error, not a hash":
    expect IOError:
      discard sha256FileHex("/nonexistent/ned-sha256-test")

  test "SHA256SUMS: the line of a file, by its name or its base name":
    let sums = "# made by the release job\n" &
      "68325720aabd7c82f30f554b313d0570c95accbb7dc4b5aae11204c08ffe732b  ned_6.32.0_aarch64.deb\n" &
      "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD *ned-6.32.0-windows-x86_64.zip\n" &
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  dist/vscode-nedls-6.32.0.vsix\r\n" &
      "not a line of sha256sum\n"
    check sha256SumFor(sums, "ned_6.32.0_aarch64.deb") ==
      "68325720aabd7c82f30f554b313d0570c95accbb7dc4b5aae11204c08ffe732b"
    check sha256SumFor(sums, "ned-6.32.0-windows-x86_64.zip") ==
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    check sha256SumFor(sums, "vscode-nedls-6.32.0.vsix") ==
      "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    check sha256SumFor(sums, "ned_6.31.0_aarch64.deb") == ""
    check sha256SumFor(sums, "aarch64.deb") == ""
    check sha256SumFor("", "x") == ""
