## Text encodings: detection, and the conversions to and from UTF-8. Run: nim r tests/unit/tencodings.nim

import std/unittest
import ../../src/ned/core/encodings

suite "encodings (6.19)":
  test "detected: UTF-8, its BOM, UTF-16 by its BOM, Windows-1252 for what is not UTF-8":
    check detectEncoding("plain ascii\n") == EncUtf8
    check detectEncoding("caf\xC3\xA9 \xE2\x82\xAC \xF0\x9F\x8E\x89") == EncUtf8
    check detectEncoding("\xEF\xBB\xBFhello") == EncUtf8Bom
    check detectEncoding("\xFF\xFEh\x00i\x00") == EncUtf16Le
    check detectEncoding("\xFE\xFF\x00h\x00i") == EncUtf16Be
    check detectEncoding("caf\xE9 \x80") == EncCp1252
    check detectEncoding("caf\xE9", EncLatin1) == EncLatin1

  test "not UTF-8: overlong forms, surrogates, cut sequences":
    check not validUtf8("\xC0\xAF")
    check not validUtf8("\xED\xA0\x80")
    check not validUtf8("\xE2\x82")
    check not validUtf8("\xF5\x80\x80\x80")
    check validUtf8("")

  test "made UTF-8 for a strict server (6.42.1): every bad sequence one \uFFFD, good text as it is":
    check utf8Repaired("caf\xC3\xA9 \xE2\x82\xAC") == "caf\xC3\xA9 \xE2\x82\xAC"      # (valid: the same)
    check utf8Repaired("caf\xE9 latin") == "caf\xEF\xBF\xBD latin"                    # (a Latin-1 byte)
    check utf8Repaired("a\xE2\x82") == "a\xEF\xBF\xBD"                               # (a character cut at the end)
    check utf8Repaired("\xE2\x82x") == "\xEF\xBF\xBDx"                               # (… and cut before an ASCII one)
    check utf8Repaired("\xC0\xAF\xED\xA0\x80") == "\xEF\xBF\xBD\xEF\xBF\xBD\xEF\xBF\xBD"   # (C0, AF: two; a surrogate: one)
    check utf8Repaired("\x80\xBF") == "\xEF\xBF\xBD\xEF\xBF\xBD"                     # (lone continuation bytes)
    check validUtf8(utf8Repaired("\xF0\x9F\x8E\x89\xF0\x9F\xFF\xC3"))

  test "cut between characters (6.42.1)":
    let s = "ab\xC3\xA9\xE2\x82\xACz"
    check utf8Cut(s, 3) == 2 and utf8Cut(s, 4) == 4 and utf8Cut(s, 5) == 4 and utf8Cut(s, 6) == 4
    check utf8Cut(s, 7) == 7 and utf8Cut(s, 99) == s.len and utf8Cut(s, -1) == 0
    check validUtf8(s[0 ..< utf8Cut(s, 5)])

  test "UTF-16: both byte orders, a character outside the BMP, the BOM back on saving":
    let (ok, t) = decode("\xFF\xFEh\x00\xE9\x00<\xD8\x89\xDF", EncUtf16Le)
    check ok and t == "h\xC3\xA9\xF0\x9F\x8E\x89"
    let (ok2, t2) = decode("\xFE\xFF\x00h\x00\xE9", EncUtf16Be)
    check ok2 and t2 == "h\xC3\xA9"
    let (eok, bytes, _) = encode("h\xC3\xA9\xF0\x9F\x8E\x89", EncUtf16Le)
    check eok and bytes == "\xFF\xFEh\x00\xE9\x00<\xD8\x89\xDF"
    let (eok2, bytes2, _) = encode("h\xC3\xA9", EncUtf16Be)
    check eok2 and bytes2 == "\xFE\xFF\x00h\x00\xE9"
    check not decode("\xFF\xFEh\x00\x00\xD8", EncUtf16Le)[0]    # (a lone surrogate)

  test "Windows-1252 and Latin-1: decoded, encoded back the same; what they cannot hold is found":
    let raw = "caf\xE9 \x80 \x93q\x94"
    let (ok, t) = decode(raw, EncCp1252)
    check ok and t == "caf\xC3\xA9 \xE2\x82\xAC \xE2\x80\x9Cq\xE2\x80\x9D"
    let (eok, back, _) = encode(t, EncCp1252)
    check eok and back == raw
    let (lok, lt) = decode("\xE9\x80", EncLatin1)
    check lok and lt == "\xC3\xA9\xC2\x80"
    let (bad, _, at) = encode("ok \xE2\x82\xAC", EncLatin1)       # (no euro sign in Latin-1)
    check not bad and at == 3
    let (bad2, _, at2) = encode("x \xF0\x9F\x8E\x89", EncCp1252)
    check not bad2 and at2 == 2

  test "UTF-8 with a BOM: the BOM off when read, back on when written":
    check decode("\xEF\xBB\xBFhi", EncUtf8Bom) == (true, "hi")
    check encode("hi", EncUtf8Bom)[1] == "\xEF\xBB\xBFhi"
    check encLabel(EncUtf8) == "UTF-8" and encLabel(EncUtf16Le) == "UTF-16 LE" and encLabel("koi8-r") == "KOI8-R"

  test "mostly UTF-8 with a broken byte stays UTF-8 (its bytes kept); text with no UTF-8 in it is not":
    check detectEncoding("caf\xC3\xA9 na\xC3\xAFve r\xC3\xA9sum\xC3\xA9 \xE9") == EncUtf8
    check detectEncoding("caf\xE9 na\xEFve") == EncCp1252
