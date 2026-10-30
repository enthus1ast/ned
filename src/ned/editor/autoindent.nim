## Indentation as you type, for Nim (editor.autoDedent): where a closing bracket typed alone on its line goes, and
## where a branch word (`of`, `elif`, `else`, `except`, `finally`) typed at the start of a line goes — the line
## whose indentation it takes. Text in, a line number out: the editor copies that line's indentation.

import std/strutils

const
  aiScanLines = 400        # (how far up to look: an opening bracket or a `case` further away is not the one meant)
  aiRoutineWords = ["proc", "func", "method", "iterator", "converter", "template", "macro", "type"]

func aiLeading*(s: string): int =
  ## the width of a line's indentation, in bytes (spaces or tabs)
  while result < s.len and s[result] in {' ', '\t'}: inc result

func aiFirstWord(s: string): string =
  ## the identifier a line starts with, after its indentation ("" when it starts with anything else)
  var i = aiLeading(s)
  while i < s.len and s[i] in IdentChars:
    result.add s[i]
    inc i

func aiCode(s: string): bool =
  ## a line with code on it (not empty, not only a comment)
  let t = s.strip
  t.len > 0 and t[0] != '#'

proc aiBranchLine*(lines: openArray[string], line: int, word: string): int =
  ## a Nim branch word typed at the start of lines[line] (`of`, `elif`, `else`, `except`, `finally`): the line of
  ## the `case`, `if`/`when` or `try` it belongs to — or of a branch of it before — whose indentation it takes;
  ## -1 when there is none above, or the line is not deeper than it. Blocks deeper than the line are skipped
  ## (`if a:` ⏎ `  for x in y:` ⏎ `    f(x)` ⏎ `  else` → the `if`'s); a routine or a type section ends the search.
  let opens =
    case word
    of "of": @["case", "of"]
    of "elif": @["if", "when", "elif"]
    of "else": @["if", "when", "elif", "case", "of"]
    of "except": @["try", "except"]
    of "finally": @["try", "except"]
    else: return -1
  if line <= 0 or line > lines.high: return -1
  var cur = aiLeading(lines[line])
  if cur == 0: return -1
  var k = line - 1
  while k >= 0 and line - k <= aiScanLines:
    let s = lines[k]
    if aiCode(s):
      let ind = aiLeading(s)
      if ind < cur:
        let w = aiFirstWord(s)
        if w in opens: return k
        if w in aiRoutineWords or ind == 0: return -1
        cur = ind
    dec k
  -1

proc aiCloserLine*(lines: openArray[string], line: int, closer: char): int =
  ## a closing bracket typed at the start of lines[line] (nothing before it but spaces): the line holding the bracket
  ## it closes, whose indentation it takes — -1 when there is none (strings, characters and comments skipped)
  let opener = case closer
               of ')': '('
               of ']': '['
               of '}': '{'
               else: return -1
  if line <= 0 or line > lines.high: return -1
  var depth = 0                  # (closers of the same kind met on the way up, not yet opened)
  var k = line - 1
  while k >= 0 and line - k <= aiScanLines:
    let s = lines[k]
    # the line's brackets outside strings, characters and comments, read left to right, then counted backwards
    var brackets: seq[char]
    var i = 0
    while i < s.len:
      let c = s[i]
      if c == '#': break
      if c == '"':
        inc i
        while i < s.len and s[i] != '"':
          if s[i] == '\\': inc i
          inc i
      elif c == '\'' and i + 2 < s.len and (s[i + 2] == '\'' or s[i + 1] == '\\'):
        inc i
        while i < s.len and s[i] != '\'':
          if s[i] == '\\': inc i
          inc i
      elif c in {'(', ')', '[', ']', '{', '}'}: brackets.add c
      inc i
    for j in countdown(brackets.high, 0):
      let c = brackets[j]
      if c == closer: inc depth
      elif c == opener:
        if depth == 0: return k
        dec depth
    dec k
  -1
