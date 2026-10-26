## yank-ring — a history of what you copied and cut: paste an older one from a list, or swap a paste for the one before
##
##   Yank ring: paste from history…   (Ctrl+Alt+V)   the last copies, newest first, each on one line (⏎ where a line
##                                    ends): the one chosen goes in at the cursor, over the selection when there is one
##   Yank ring: paste the one before  (Alt+Shift+Y)  right after a paste — this plugin's, or Ctrl+V's — the pasted
##                                    text is swapped for the copy before it; again, for the one before that, and round
##   Yank ring: clear the history
##   vim                              <leader>p  paste from history
##   settings                         plugins.yank-ring.size — how many copies it keeps (30)
##                                    plugins.yank-ring.keepOnDisk — off (the default): the history is kept for this
##                                    session only, in memory; on: in the plugin's data folder, for the next start too
##
## How it learns of a copy: ned gives plugins no event for one, so the plugin reads the clipboard — what Ctrl+V would
## paste: the system's clipboard, or ned's own when the system's cannot be read — at the moments a copy is likely to
## have happened: after the text changes (a cut, a paste, vim's d, x and p), when another tab comes to the front,
## once a second while text is selected and just after (Ctrl+C, Ctrl+X, vim's y in visual mode), and before the
## history is shown. A wrapper of ned's Copy command would miss vim's and emacs's copies, the right-click menu and
## other programs; reading the clipboard all the time would start the clipboard's helper program (xclip, wl-paste,
## Termux:API) every second. So a copy made in another program is recorded once you are back in ned and do one of
## those things, and of two copies with nothing between them (no edit, no selection), only the second is kept.
## A copy already in the history moves to the top; empty copies and ones over 100 KB are not kept. What you copy can
## be a password: that is why the history is not written to disk unless keepOnDisk says so.
import nedplugin

requiresNed(">= 6.29")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("clipboard", "reads what you copy and cut, to keep the history of it")

settingDef("size", 30, "Yank ring: how many copies the history keeps")
settingDef("keepOnDisk", false, "Yank ring: keep the history in the plugin's data folder for the next start (off: " &
           "in memory, for this session only — what you copy may be a password)")

const MaxEntry = 100_000         # (bytes: a bigger copy is not kept)

type Paste = object
  buf: int                       # the tab it went into (-1: none yet)
  at: Pos                        # where it starts
  text: string                   # what was put there
  idx: int                       # which entry of the ring it is

var
  ring: seq[string]              # the copies, newest first
  loaded = false
  lastClip = ""                  # the clipboard as it was last read
  lastRead = false
  selBefore = false              # (the timer) text was selected at its last look
  last = Paste(buf: -1)

proc maxSize(): int = max(1, setting("size", 30))

proc onDisk(): bool = setting("keepOnDisk", false)

proc load() =
  ## the history kept on disk (once, when keepOnDisk is on)
  if loaded: return
  loaded = true
  if not onDisk(): return
  try:
    let j = parseJson(readData("ring.json"))
    for x in j{"ring"}.getElems:
      if x.kind == JString and x.getStr.len > 0: ring.add x.getStr
  except CatchableError: discard

proc store() =
  if onDisk(): writeData("ring.json", $(%*{"ring": ring}) & "\n")

func remembered(r: seq[string], s: string, size: int): seq[string] =
  ## the ring with s at its top (taken from where it was), size entries at most
  result = @[s]
  for x in r:
    if x != s and result.len < size: result.add x

proc capture() =
  ## the clipboard read: something new in it goes to the top of the history
  load()
  var s = ""
  try: s = clipboard()
  except CatchableError: return            # (not allowed, or no clipboard: nothing to keep)
  if lastRead and s == lastClip: return
  lastClip = s
  lastRead = true
  if s.strip.len == 0 or s.len > MaxEntry: return
  if ring.len > 0 and ring[0] == s: return
  ring = remembered(ring, s, maxSize())
  store()

# ── showing an entry on one line ──

func runes(s: string): int =
  for c in s:
    if (ord(c) and 0xC0) != 0x80: inc result

func cut(s: string, n: int): string =
  ## the first n characters (UTF-8), … when there were more
  var k = 0
  for i, c in s:
    if (ord(c) and 0xC0) != 0x80:
      if k == n: return s[0 ..< i] & "…"
      inc k
  s

func oneLine(s: string, width = 100): string =
  ## an entry on one line: each line without its indentation, ⏎ between them, tabs as spaces
  var parts: seq[string]
  for l in s.strip(chars = {'\n', '\r'}).splitLines:
    parts.add l.strip.replace("\t", " ")
  cut(parts.join(" ⏎ "), width)

func about(s: string): string =
  ## "3 lines · 120 characters"
  let n = s.strip(leading = false, chars = {'\n'}).count('\n') + 1
  (if n == 1: "1 line" else: $n & " lines") & " · " & $runes(s) & (if runes(s) == 1: " character" else: " characters")

# ── pasting ──

func endOf(at: Pos, s: string): Pos =
  ## where s ends when it is put at `at`
  let k = s.rfind('\n')
  if k < 0: pos(at.line, at.col + s.len) else: pos(at.line + s.count('\n'), s.len - k - 1)

proc putAt(b: Buf, r: Range, s: string, idx: int) =
  ## s in place of the range, the cursor after it; remembered as the last paste
  b.replace(r, s)
  b.setCursor(endOf(r.start, s))
  last = Paste(buf: b.id, at: r.start, text: s, idx: idx)

proc pasteFromHistory() =
  let b = current()
  if not b.valid:
    message("Yank ring: open a file first")
    return
  capture()
  if ring.len == 0:
    message("Yank ring: nothing copied yet")
    return
  var items, details: seq[string]
  for s in ring:
    items.add oneLine(s)
    details.add about(s)
  let k = pick("Paste from history — " & $ring.len & (if ring.len == 1: " copy" else: " copies") & ", newest first",
               items, details)
  if k < 0 or k >= ring.len: return
  let sel = b.selection
  putAt(b, (if sel.isEmpty: rng(b.cursor, b.cursor) else: sel), ring[k], k)

func before(a, b: Pos): bool = a.line < b.line or (a.line == b.line and a.col <= b.col)

proc pastedHere(b: Buf): (bool, Range, int) =
  ## the paste right before this: this plugin's (its text still there, the cursor in it or at its end) — or
  ## Ctrl+V's, when the text before the cursor is the newest copy
  let c = b.cursor
  if last.buf == b.id and last.text.len > 0:
    let r = rng(last.at, endOf(last.at, last.text))
    if before(r.start, c) and before(c, r.stop) and r.stop.line < b.lineCount and b.textIn(r) == last.text:
      return (true, r, last.idx)
  if ring.len > 0:
    let s = ring[0]
    let n = s.count('\n')
    let first = c.line - n
    if first >= 0:
      let k = s.find('\n')
      let startCol = if n == 0: c.col - s.len else: b.line(first).len - k
      if startCol >= 0:
        let r = rng(pos(first, startCol), c)
        if b.textIn(r) == s: return (true, r, 0)
  (false, noRange(), -1)

proc pasteBefore() =
  let b = current()
  if not b.valid: return
  capture()
  let (ok, r, idx) = pastedHere(b)
  if not ok:
    message("Yank ring: paste first (Ctrl+V, or Yank ring: paste from history…), then this swaps it for the copy " &
            "before it")
    return
  if ring.len < 2:
    message("Yank ring: there is no other copy yet")
    return
  let n = (idx + 1) mod ring.len
  putAt(b, r, ring[n], n)
  message("Yank ring: " & $(n + 1) & " of " & $ring.len & " — " & oneLine(ring[n], 60))

command "Yank ring: paste from history…", "ctrl+alt+v": pasteFromHistory()
command "Yank ring: paste the one before", "alt+shift+y": pasteBefore()
command "Yank ring: clear the history":
  load()
  ring.setLen(0)
  last = Paste(buf: -1)
  store()
  message("Yank ring: the history is empty")

nmap("<leader>p", "yank ring: paste from history") do (count: int): pasteFromHistory()

# the moments a copy is likely to have happened (see the top of this file)
onChange("*") do (ev: Event): capture()
onEnter("*") do (ev: Event): capture()
discard every(1000) do ():
  let b = current()
  var selected = false
  if b.valid:
    try: selected = not b.selection.isEmpty
    except CatchableError: discard
  if selected or selBefore: capture()
  selBefore = selected
