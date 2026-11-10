## A model's reply read in pieces: thinking between <think> tags split from the answer, however the pieces cut it; a
## tool call's arguments read while they are still being written. Run: nim r tests/unit/tstreamparts.nim

import std/unittest
import ../../src/ned/ai/streamparts

proc fed(pieces: openArray[string]): (string, string) =
  ## the thinking and the answer of a reply streamed as `pieces`
  var s: ThinkSplit
  var think, text: string
  for p in pieces: s.feed(p, think, text)
  s.finish(think, text)
  (think, text)

suite "the thinking in an answer (6.43)":
  test "a reply without thinking is the answer, untouched":
    check fed(["Hello ", "there."]) == ("", "Hello there.")
    check fed(["<div>", "x</div>"]) == ("", "<div>x</div>")
    check fed(["  ", "\n", "Answer"]) == ("", "Answer")

  test "<think> … </think> before the answer, the tags cut anywhere":
    let want = ("I should check.", "The answer.")
    check fed(["<think>\nI should check.</think>\n\nThe answer."]) == want
    check fed(["<thi", "nk>I should", " check.</th", "ink>", "\n\n", "The answer."]) == want
    check fed(["\n<", "think", ">", "I should check.", "<", "/", "think", ">The answer."]) == want
    check fed(["<thinking>I should check.</thinking>The answer."]) == want

  test "only the end of the thinking (the server's template opened it)":
    check fed(["I should", " check.\n</think>\n\nThe answer."]) == ("I should check.", "The answer.")
    check fed(["I should check.</th", "ink>\nThe answer."]) == ("I should check.", "The answer.")

  test "a thinking left open stays thinking; an answer that only mentions the tag keeps it":
    check fed(["<think>still going", " and going</thi"]) == ("still going and going</thi", "")
    check fed(["Write `</think>` here to close it."]) == ("", "Write `</think>` here to close it.")
    check splitThink("<think>a</think>b") == ("a", "b")

  test "words counted":
    check wordCount("") == 0
    check wordCount("  one two\nthree\t ") == 3

suite "a tool call's arguments still being written (6.43)":
  test "a string so far, its escapes read, one cut at the end left out":
    check partialJsonString("""{"path": "src/a.nim", "new_text": "line 1\nline""", "new_text") == "line 1\nline"
    check partialJsonString("""{"path": "src/a.nim", "new_text": "a\\""", "new_text") == "a\\"
    check partialJsonString("{\"path\": \"src/a.nim\", \"new_text\": \"a\\", "new_text") == "a"
    check partialJsonString("""{"path": "src/a.nim", "new_text": "café \ud83d""", "new_text") == "café "
    check partialJsonString("""{"path": "src/a.nim", "new_text": "😀!"}""", "new_text") == "😀!"
    check partialJsonString("""{"path": "src/a.nim"}""", "path") == "src/a.nim"
    check partialJsonString("""{"pa""", "path") == ""

  test "only the top level: a key inside another string or object is not taken":
    check partialJsonString("""{"old_text": "\"path\": \"x\"", "path": "real"}""", "path") == "real"
    check partialJsonString("""{"o": {"path": "inner"}, "path": "outer"}""", "path") == "outer"
    check partialJsonString("""{"n": 3, "path": "after"}""", "path") == "after"
    check partialJsonString("""{"path": 3}""", "path") == ""
    check partialJsonString("not json", "path") == ""
