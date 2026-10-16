# ── REPL tabs: code is typed in once the REPL shows its prompt ──

proc replContinues(langId, line: string): bool =
  ## a top-level line that carries on the statement above it (no blank line may come before it)
  let t = line.strip
  if t.len == 0: return false
  if t[0] in {')', ']', '}'}: return true
  let w = t.split({' ', ':', '(', '\t'})[0]
  case langId
  of "python": w in ["else", "elif", "except", "finally"]
  of "nim": w in ["else", "elif", "except", "finally", "of"]
  else: false

proc replPrepare(langId, code: string, bracketed: bool): string =
  ## the keystrokes that make a REPL run `code`: one bracketed paste when the REPL takes them (Python 3.13+,
  ## IPython, irb, bash); else line by line, with blank lines where Python/Nim REPLs need them to end a block
  var lines = code.replace("\r\n", "\n").split('\n')
  while lines.len > 0 and lines[^1].strip.len == 0: lines.setLen(lines.len - 1)
  while lines.len > 0 and lines[0].strip.len == 0: lines.delete(0)
  if lines.len == 0: return "\r"
  var common = high(int)                   # a block from inside a proc: move it to the left edge
  for l in lines:
    if l.strip.len > 0: common = min(common, l.len - l.strip(trailing = false).len)
  if common > 0 and common < high(int):
    for l in lines.mitems:
      l = if l.len >= common: l[common .. ^1] else: l.strip(trailing = false)
  let blocky = langId in ["python", "nim"]
  proc indOf(l: string): int = l.len - l.strip(trailing = false).len
  let lastInd = indOf(lines[^1])
  let opensBlock = lines[^1].strip.endsWith(":") or (langId == "nim" and lines[^1].strip.endsWith("="))
  if bracketed:
    result = "\e[200~" & lines.join("\n") & "\e[201~\r"
    # Python's REPL runs a pasted block of several lines on an empty line; a Nim block ends the same way
    if lines.len > 1 and (langId == "python" or (blocky and (lastInd > 0 or opensBlock))): result.add "\r"
    return
  if not blocky: return lines.join("\r") & "\r"
  var outp: seq[string]
  var prev = 0
  for l in lines:
    if l.strip.len == 0: continue         # a blank line would end a block too early
    let ind = indOf(l)
    if ind == 0 and prev > 0 and outp.len > 0 and not replContinues(langId, l): outp.add ""
    outp.add l
    prev = ind
  if prev > 0 or opensBlock: outp.add ""
  outp.join("\r") & "\r"

proc termCursorText(t: Term): string =
  ## the text on the cursor's row, up to the cursor
  if t.cy < 0 or t.cy >= t.scr.len: return ""
  let row = t.scr[t.cy]
  for i in 0 ..< min(t.cx, row.len):
    let c = row[i].ch
    if c == 0: continue
    result.addUtf8(int(if c < 32: 32'u32 else: c))

proc replReady(t: Term): bool =
  ## the REPL shows a prompt (">>> ", "nim> ", "In [1]: ", "irb(main):001> ", "$ " …), or has had time enough
  if msSince(t.replAt) > 5000: return true
  if not t.gotOutput: return false
  let x = t.termCursorText().strip(leading = false)
  x.len > 0 and x[^1] in {'>', ':', '$', '#', '%', '?'}

proc replFlush(t: Term) =
  if t.replQ.len == 0 or t.dead or t.fd < 0 or not t.replReady(): return
  let q = t.replQ
  t.replQ.setLen(0)
  for code in q: t.termWrite(replPrepare(t.replLang, code, t.bracketed))
  needRender = true
