## long-lines — decorations: a line longer than plugins.long-lines.width gets a sign in the gutter, the part past
## the width tinted and how much too long it is after its end; and a command that colours the indentation's levels
import nedplugin
from std/unicode import runeLen, runeOffset   # (just these two: std/unicode's strip would clash with strutils')

requiresNed(">= 6.31")

settingDef("width", 100, "Long lines: how many characters a line may have")

proc mark(b: Buf) =
  ## this plugin's marks in the file made again: the old ones go, the long lines get new ones
  b.clearDecorations()                        # (only this plugin's: other plugins' marks stay)
  let width = setting("width", 100)
  var n = 0
  for i, l in b.lines:
    let chars = l.runeLen                     # characters — a column is a byte: "é" is two bytes, one character
    if chars <= width: continue
    inc n
    if n > 200: break                         # (each mark is a request: the first 200 long lines are enough)
    let cut = l.runeOffset(width)             # the byte where the first character past the width starts
    b.sign(i, "»", "warn")
    b.highlight(rng(pos(i, cut), pos(i, l.len)), "warn")
    b.virtualText(i, "+" & $(chars - width), "hint")

onOpen("*") do (ev: Event):
  mark(ev.buf)
onChange("*") do (ev: Event):                 # (marks stay on their line numbers: make them again after a change)
  mark(ev.buf)

var rainbow = false

command "Long lines: rainbow indentation on/off":
  rainbow = not rainbow
  if rainbow:
    # a colour for each level of indentation, a dot in each space of it, a red band where it is not whole levels
    indentStyle(IndentStyle(levels: @["warn", "add", "info", "accent"], dot: "·", blankLines: true,
                            wrongColor: "error"))
  else:
    indentStyle(IndentStyle())                # (an empty look takes this plugin's away)
  message("Rainbow indentation " & (if rainbow: "on" else: "off"))
