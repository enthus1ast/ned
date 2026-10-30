## ── what ned's own CSS, HTML and SQL engines share: what they answer with, and small text helpers ──

import std/[strutils, algorithm]

type
  WebItem* = object            # a completion
    label*, insert*, snippet*, detail*, doc*: string
    kind*: int                 # the icon (LSP's CompletionItemKind numbers)
    rank*: int                 # 0 nearest … 3 farthest
  WebDiag* = object            # a problem found
    line*, col*, eline*, ecol*: int
    sev*: int                  # 1 error · 2 warning · 3 info · 4 hint
    msg*, rule*: string

const
  KProp* = 10
  KValue* = 12
  KKeyword* = 14
  KFunction* = 3
  KClass* = 7
  KField* = 5
  KColor* = 16
  KUnit* = 11
  KVariable* = 6
  KEnum* = 13
  KModule* = 9
  KStruct* = 22
  KConst* = 21

# can the character be in a CSS name (letters, digits, _ and -, or any non-ASCII byte)?
func isCssIdent*(c: char): bool {.inline.} = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'} or ord(c) >= 0x80

func webFamily*(id: string): string =
  ## the engine for a language: "css" (CSS, SCSS, Less), "html", "sql", "js" (JavaScript), "json" or ""
  case id
  of "css", "scss", "less": "css"
  of "html": "html"
  of "sql": "sql"
  of "javascript": "js"
  of "json": "json"
  else: ""

func wordDistance*(a, b: string, limit = 3): int =
  ## edits from one word to the other — a letter changed, added, dropped, or two swapped (dvi → div: one) —
  ## case-insensitive (limit + 1 once it is more than limit)
  if abs(a.len - b.len) > limit: return limit + 1
  var prev2 = newSeq[int](b.len + 1)
  var prev = newSeq[int](b.len + 1)
  var cur = newSeq[int](b.len + 1)
  for j in 0 .. b.len: prev[j] = j
  for i in 1 .. a.len:
    cur[0] = i
    var best = cur[0]
    for j in 1 .. b.len:
      let ca = toLowerAscii(a[i - 1])
      let cb = toLowerAscii(b[j - 1])
      let cost = if ca == cb: 0 else: 1
      cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost)
      if i > 1 and j > 1 and ca == toLowerAscii(b[j - 2]) and toLowerAscii(a[i - 2]) == cb:
        cur[j] = min(cur[j], prev2[j - 2] + 1)
      best = min(best, cur[j])
    if best > limit: return limit + 1
    let t = prev2
    prev2 = prev
    prev = cur
    cur = t
  prev[b.len]

proc closest*(w: string, names: openArray[string], limit = 2): string =
  ## the known name nearest to a misspelled one ("" when none is near enough)
  var best = limit + 1
  for n in names:
    if n.len < 2: continue
    let d = wordDistance(w, n, limit)
    if d < best or (d == best and d <= limit and n < result):
      best = d
      result = n
  if best > limit or best >= w.len: result = ""     # (two letters off a three-letter word: not a misspelling)

# true when the place (l1, c1) comes before (l2, c2) in the text
func posLess*(l1, c1, l2, c2: int): bool {.inline.} = l1 < l2 or (l1 == l2 and c1 < c2)

proc sortDiags*(ds: var seq[WebDiag]) =
  ## puts the problems in the order of the text: by line, then column
  ds.sort(proc(x, y: WebDiag): int = cmp((x.line, x.col), (y.line, y.col)))

func lineCol*(starts: seq[int], off: int): (int, int) =
  ## an offset in text joined by \n → (line, column), with each line's start offset in `starts`
  var lo = 0
  var hi = starts.high
  while lo < hi:
    let m = (lo + hi + 1) div 2
    if starts[m] <= off: lo = m else: hi = m - 1
  (lo, off - starts[lo])

proc joinLines*(lines: openArray[string]): (string, seq[int]) =
  ## the lines as one text, and where each starts in it
  var total = 0
  for l in lines: total += l.len + 1
  result[0] = newStringOfCap(total)
  result[1] = newSeqOfCap[int](lines.len)
  for l in lines:
    result[1].add result[0].len
    result[0].add l
    result[0].add '\n'
