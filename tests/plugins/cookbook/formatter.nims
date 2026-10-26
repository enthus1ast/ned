## sh-format — formatters: shell scripts formatted by shfmt when it is installed (a formatter command), else by
## a small formatter written in Nim: no spaces at the ends of lines, one blank line at most, one line end at the end
import nedplugin

requiresNed(">= 6.31")

func tidy(text: string): string =
  ## the text with no spaces at the ends of its lines, no more than one blank line in a row, and one line end at
  ## its end
  var blank = 0
  for l in text.strip(leading = false).splitLines:
    let t = l.strip(leading = false)
    if t.len == 0:
      inc blank
      if blank > 1: continue
    else: blank = 0
    result.add t & "\n"

if findExe("shfmt").len > 0:
  # a command: the text on its standard input, the formatted text on its standard output; ned runs it in the
  # file's folder when you format (Alt+F, or on save)
  formatter("shellscript", "shfmt -i 2 -ci")
else:
  # a formatter in Nim: the text in, the formatted text out — the same text says it is formatted already
  formatter("shellscript") do (text: string) -> string:
    if "<<" in text:
      # a here-document's lines are data: raise to say why the file is left as it is (the status line shows it)
      raise newException(ValueError, "it has a here-document — install shfmt to format it")
    tidy(text)
