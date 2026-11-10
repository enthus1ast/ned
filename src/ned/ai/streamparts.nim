## What a model's reply sends in pieces, read as it comes: the thinking some models write into the answer itself
## (Qwen, QwQ, DeepSeek R1, GLM… between `<think>` and `</think>`, when the server leaves it there), split from the answer;
## a string of a tool call's arguments while the call is still being written (its JSON not whole yet); and how many
## words a text has, without splitting it. Run its tests: nim r tests/unit/tstreamparts.nim

import std/strutils
from std/unicode import Rune, toUTF8   # (only these: all of unicode would make strutils' splitWhitespace ambiguous where
                                       # ned is merged into one file)

type ThinkSplit* = object
  ## splits a streamed answer into its thinking and the answer: give it each piece with `feed`, then `finish`
  state: int            # 0 nothing but spaces yet, 1 inside <think>, 2 the answer
  closeTag: string      # the tag that ends this thinking (</think> or </thinking>)
  held: string          # what may be the start of a tag, waiting for the next piece
  closed: bool          # a thinking was ended (an answer that only closes one: what came before it moves)
  scanFrom: int         # the answer: where to look for a lone </think> from

const OpenTags = ["<think>", "<thinking>"]

proc toText(s: var ThinkSplit, piece: string, think, text: var string) =
  ## the answer gets `piece`; when no <think> opened it and a </think> closes a line in it, what came before was the
  ## thinking (a template that opens the thinking itself, so the model writes only its end). The answer starts at its
  ## first character that is not a space
  if text.len == 0:
    let p = piece.strip(trailing = false)
    if p.len == 0: return
    text.add p
  else: text.add piece
  if s.closed: return
  let at = text.find("</think>", max(0, s.scanFrom))
  if at >= 0:
    let after = at + "</think>".len
    if after == text.len or text[after] in {'\n', '\r'}:
      think.add text[0 ..< at].strip
      text = text[after .. ^1].strip(trailing = false)
      s.closed = true
      return
    if after < text.len: s.scanFrom = after
  else: s.scanFrom = max(0, text.len - "</think>".len)

proc feed*(s: var ThinkSplit, piece: string, think, text: var string) =
  ## adds one piece of the streamed answer: what is thought goes to `think`, the answer to `text`; a tag cut between two
  ## pieces waits for the next one
  if piece.len == 0: return
  var p = s.held & piece
  s.held = ""
  while p.len > 0:
    case s.state
    of 0:
      let lead = p.len - p.strip(trailing = false).len
      let rest = p[lead .. ^1]
      if rest.len == 0:
        s.held = p                       # (only spaces so far: the answer has not begun)
        return
      var opened = false
      for t in OpenTags:
        if rest.startsWith(t):
          s.state = 1
          s.closeTag = "</" & t[1 .. ^1]
          p = rest[t.len .. ^1].strip(trailing = false, chars = {'\n', '\r'})
          opened = true
          break
        if t.startsWith(rest):
          s.held = p                     # ("<thi": perhaps a tag, perhaps not)
          return
      if not opened:
        s.state = 2
        s.toText(p, think, text)
        return
    of 1:
      let at = p.find(s.closeTag)
      if at >= 0:
        think.add p[0 ..< at]
        s.state = 2
        s.closed = true
        p = p[at + s.closeTag.len .. ^1].strip(trailing = false)
        if p.len == 0: return
      else:
        # keep back what could be the start of the closing tag
        var keep = 0
        for k in countdown(min(s.closeTag.len - 1, p.len), 1):
          if s.closeTag.startsWith(p[p.len - k .. ^1]):
            keep = k
            break
        think.add p[0 ..< p.len - keep]
        s.held = p[p.len - keep .. ^1]
        return
    else:
      s.toText(p, think, text)
      return

proc finish*(s: var ThinkSplit, think, text: var string) =
  ## the reply is complete: what was held back goes where it belongs (a thinking left open stays thinking)
  if s.held.len > 0:
    if s.state == 1: think.add s.held
    elif s.state == 0 and s.held.strip.len > 0: text.add s.held
    s.held = ""
  think = think.strip

proc splitThink*(whole: string): (string, string) =
  ## a reply that came in one piece, as (its thinking, its answer)
  var s: ThinkSplit
  var think, text: string
  s.feed(whole, think, text)
  s.finish(think, text)
  (think, text)

proc wordCount*(s: string): int =
  ## how many words `s` has (runs of characters between spaces), counted without making any string
  var inWord = false
  for c in s:
    if c in Whitespace: inWord = false
    elif not inWord:
      inWord = true
      inc result

proc partialJsonString*(json, key: string): string =
  ## the string `key` has at the top level of the JSON object `json` so far — the object may stop anywhere (a tool call's
  ## arguments still being written): what is there of the string is returned, an escape cut at the end left out; ""
  ## when the key has not come yet, or holds something other than a string
  var i = 0
  let n = json.len
  template skipWs() =
    ## moves `i` past spaces and line ends
    while i < n and json[i] in Whitespace: inc i
  proc readStr(json: string, i: var int, keep: bool, o: var string): bool =
    ## reads the string starting after its opening quote at `i` into `o` (when `keep`); true when it closed
    let n = json.len
    while i < n:
      let c = json[i]
      if c == '"':
        inc i
        return true
      if c == '\\':
        if i + 1 >= n: return false
        let e = json[i + 1]
        case e
        of 'n': (if keep: o.add '\n')
        of 't': (if keep: o.add '\t')
        of 'r': (if keep: o.add '\r')
        of 'b': (if keep: o.add '\b')
        of 'f': (if keep: o.add '\f')
        of 'u':
          if i + 5 >= n: return false
          var cp = 0
          try: cp = parseHexInt(json[i + 2 .. i + 5])
          except ValueError: cp = 0xFFFD
          i += 6
          if cp >= 0xD800 and cp <= 0xDBFF:
            # (a character past U+FFFF comes as two: the second may not be here yet)
            if i + 5 >= n: return false
            if json[i] == '\\' and json[i + 1] == 'u':
              var lo = 0
              try: lo = parseHexInt(json[i + 2 .. i + 5])
              except ValueError: lo = 0
              if lo >= 0xDC00 and lo <= 0xDFFF:
                cp = 0x10000 + ((cp - 0xD800) shl 10) + (lo - 0xDC00)
                i += 6
              else: cp = 0xFFFD
            else: cp = 0xFFFD
          elif cp >= 0xDC00 and cp <= 0xDFFF: cp = 0xFFFD
          if keep: o.add Rune(cp).toUTF8
          continue
        else: (if keep: o.add e)
        i += 2
        continue
      if keep: o.add c
      inc i
    false
  skipWs()
  if i >= n or json[i] != '{': return ""
  inc i
  while i < n:
    skipWs()
    if i >= n or json[i] != '"': return ""
    inc i
    var k = ""
    if not readStr(json, i, true, k): return ""
    skipWs()
    if i >= n or json[i] != ':': return ""
    inc i
    skipWs()
    if i >= n: return ""
    if k == key:
      if json[i] != '"': return ""
      inc i
      discard readStr(json, i, true, result)
      return
    # another key's value: skipped, strings and nested objects and arrays included
    var depth = 0
    var junk = ""
    while i < n:
      let c = json[i]
      if c == '"':
        inc i
        if not readStr(json, i, false, junk): return ""
        continue
      if c in {'{', '['}: inc depth
      elif c in {'}', ']'}:
        if depth == 0: return ""
        dec depth
      elif c == ',' and depth == 0:
        inc i
        break
      inc i
