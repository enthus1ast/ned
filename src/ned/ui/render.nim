# ════════════════════════════════════════════════════════════════════════════
#  A frame: the editor, docks, panel, popups and bars drawn in order; boxes, wrapped text, sticky lines
# ════════════════════════════════════════════════════════════════════════════

proc drawFrame(x, y, w, h: int, bg, border: Rgb, title = "", titleFg: Rgb = NoColor, shadow = true)

proc drawBox(x, y, w, h: int, title = "") =
  ## a framed box in the menu colours with a title, as popups and pickers use
  drawFrame(x, y, w, h, theme.menuBg, theme.border, title)

proc putHl(x, y: int, s: string, hl: seq[int], fg, hlFg, bg: Rgb, maxX: int, at: set[Attr] = {}): int =
  ## writes text with some characters marked: the characters whose byte offsets are in `hl` (matched letters) in `hlFg`
  ## and bold, the rest in `fg`; stops at column `maxX` and returns the column after the last one written
  var x = x
  var i = 0
  var k = 0
  while i < s.len and x < maxX:
    let n = runeLen(s[i])
    var isHl = false
    while k < hl.len and hl[k] < i: inc k
    if k < hl.len and hl[k] == i: isHl = true
    x = putStr(x, y, s[i ..< min(i + n, s.len)], (if isHl: hlFg else: fg), bg,
               (if isHl: at + {aBold} else: at), maxX)
    i += n
  x

proc wrapText(s: string, width: int): seq[string] =
  ## breaks text into lines no wider than `width` columns, at spaces (a word longer than a line is cut); existing line
  ## breaks are kept
  for para in s.splitLines:
    if strWidth(para) <= width:
      result.add para
      continue
    var lineS = ""
    for word in para.split(' '):
      if lineS.len > 0 and strWidth(lineS) + 1 + strWidth(word) > width:
        result.add lineS
        lineS = ""
      if strWidth(word) > width:
        var wv = word
        while strWidth(wv) > width:
          let cut = colAtVis(wv, width)
          result.add wv[0 ..< max(1, cut)]
          wv = wv[max(1, cut) .. ^1]
        lineS = wv
      else:
        lineS = if lineS.len == 0: word else: lineS & " " & word
    result.add lineS


proc stickyLines(b: Buffer, top, maxN: int): seq[int]

const CtrlWords = ["if", "elif", "else", "while", "for", "when", "case", "of", "try", "except", "finally",
                   "switch", "do", "with", "block", "return", "loop", "match", "catch", "static"]

proc crumbName(s: string): string =
  ## "proc foo*(x: int)" → "foo", "class Bar(Base):" → "Bar", "if x > 3:" → "if x > 3"
  let t = s.strip
  if t.len == 0: return ""
  var i = 0
  var first = true
  while i < t.len:
    let c = t[i]
    if c in IdentStartChars:
      let st = i
      while i < t.len and t[i] in IdentChars: inc i
      let w = t[st ..< i]
      if first:
        first = false
        if w in CtrlWords: return truncTo(t.strip(leading = false, chars = {':', '{', ' '}), 28)
      var j = i
      if j < t.len and t[j] == '*': inc j
      if j < t.len and t[j] in {'(', '[', '<', '=', ':', '{'}: return w
      if j + 1 < t.len and t[j] == ' ' and t[j + 1] in {'=', '{', '(', ':'}: return w
    elif c in {'"', '\'', '#'}: break
    else: inc i
  truncTo(t.strip(leading = false, chars = {':', '{', ' '}), 28)

proc toggleDock(side: DockSide)
proc togglePanel()
proc toggleZen()
proc panelJump(i: int)
proc termCopySel()
proc toggleAssistant()
proc openSettingsUi(filter = "")
proc aiAskAboutFile(path: string)
proc rescanTests()
proc toggleTerminal()
proc newTerminal()
proc cycleFocus(d: int)
proc aiKey(): string
proc aiCommitMessage()
