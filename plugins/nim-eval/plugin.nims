## nim-eval — a piece of Nim run where you write it: the selection (or the line) compiled and run, what it prints
## beside it
##
##   Nim: evaluate the selection      the selected code (nothing selected: the cursor's line) run with `nim r` —
##                                    with the file's imports, so what they give is there. A line that is an
##                                    expression (1 + 2, s.split(',')) has its value echoed. The output's first
##                                    line goes after the code (→ 3), all of it to the Output panel; an error's
##                                    line is the line of the selection it is on
##   Nim: evaluate the selection as NimScript   the same with `nim e` (faster; NimScript's own system, no FFI)
##   Nim: clear the results           the → lines taken away
## It needs nim on PATH.
import nedplugin
import std/strutils

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "runs the code you select with nim r (or nim e)")

settingDef("flags", "--hints:off", "Nim: evaluate the selection — the compiler's options")

const Keywords = ["let", "var", "const", "proc", "func", "iterator", "template", "macro", "type", "import", "from",
                  "echo", "for", "while", "if", "when", "case", "block", "discard", "assert", "doAssert", "return",
                  "include", "export", "method", "converter", "try", "raise", "defer", "yield", "static", "using"]

# s as one word for a shell command line, in single quotes (a quote inside it written '\'')
func q(s: string): string = "'" & s.replace("'", "'\\''") & "'"

func isExpression*(code: string): bool =
  ## one line that is a value, not a statement: 1 + 2, x.len, f(3) — not `let x = …`, `x = 3`, `echo x`
  let t = code.strip
  if t.len == 0 or '\n' in t or t.endsWith(":"): return false
  let w = t.split({' ', '(', '\t'})[0]
  if w in Keywords: return false
  # (an assignment: an = that is not ==, <=, >=, !=)
  var i = 0
  while i < t.len:
    if t[i] == '"':
      inc i
      while i < t.len and t[i] != '"':
        if t[i] == '\\': inc i
        inc i
    elif t[i] == '=' and (i == 0 or t[i - 1] notin {'=', '<', '>', '!', '+', '-', '*', '/', '&', '%'}) and
         (i + 1 >= t.len or t[i + 1] != '='):
      return false
    inc i
  true

proc programOf*(fileLines: seq[string], code: string): (string, int) =
  ## the program run: the file's imports, then the code (an expression echoed) — and how many lines come before
  ## the code (an error's line in the program, less that, is its line in the selection)
  var head: seq[string]
  for l in fileLines:
    let t = l.strip
    if (t.startsWith("import ") or t.startsWith("from ")) and l.len > 0 and l[0] notin {' ', '\t'}: head.add l
  var body = code
  if isExpression(code): body = "echo " & code.strip
  else:
    # (the code's own indentation taken off: a piece of a proc's body)
    var ind = high(int)
    for l in code.splitLines:
      if l.strip.len > 0: ind = min(ind, l.len - l.strip(trailing = false).len)
    if ind > 0 and ind < high(int):
      var ls: seq[string]
      for l in code.splitLines: ls.add (if l.len >= ind: l[ind .. ^1] else: l.strip)
      body = ls.join("\n")
  (head.join("\n") & (if head.len > 0: "\n" else: "") & body & "\n", head.len)

proc evaluate(script: bool) =
  ## runs the selection (else the cursor's line) with nim r, or nim e when script, as a program of its own in the data
  ## folder; the first line of its output goes after the code as a → note, an error is shown on the selection's line it
  ## names (✗), and all the output goes to the Output panel
  let b = current()
  var r = b.selection
  if r.isEmpty: r = b.lineRange(b.cursor.line)
  let code = b.textIn(r)
  if code.strip.len == 0:
    message("Select some code first")
    return
  let (prog, before) = programOf(b.lines, code)
  let name = if script: "eval.nims" else: "eval.nim"
  writeData(name, prog)
  let f = dataDir() & "/" & name
  let cmd = (if script: "nim e " else: "nim r ") & setting("flags", "--hints:off") & " " &
            (if script: "" else: "--nimcache:" & q(dataDir() & "/cache") & " ") & q(f) & " 2>&1"
  status("Evaluating…")
  let res = shell(cmd)
  status("")
  let last = max(r.start.line, r.stop.line - (if r.stop.col == 0 and r.stop.line > r.start.line: 1 else: 0))
  var outp = res.output.strip
  var errLine = -1
  if res.code != 0:
    # name.nim(L, C) Error: … — L in the program; its line in the file
    for l in outp.splitLines:
      let k = l.find(name & "(")
      if k >= 0 and "Error" in l:
        let a = k + name.len + 1
        var e = a
        while e < l.len and l[e] in Digits: inc e
        try:
          let pl = parseInt(l[a ..< e]) - 1 - before
          errLine = r.start.line + max(0, pl)
        except ValueError: discard
        outp = l[l.find("Error") .. ^1]
        break
  b.clearDecorations()
  let first = if outp.len == 0: "(nothing printed)" else: outp.splitLines[0]
  if res.code != 0 and errLine >= 0:
    b.virtualText(errLine, "✗ " & first, "error")
    b.sign(errLine, "✗", "error")
  else:
    b.virtualText(last, (if res.code == 0: "→ " else: "✗ ") & first, (if res.code == 0: "hint" else: "error"))
  output("▶ " & (if script: "nim e" else: "nim r") & " (" & $code.countLines & " lines)\n" & res.output.strip & "\n")

command "Nim: evaluate the selection":
  evaluate(false)

command "Nim: evaluate the selection as NimScript":
  evaluate(true)

command "Nim: clear the results":
  current().clearDecorations()
