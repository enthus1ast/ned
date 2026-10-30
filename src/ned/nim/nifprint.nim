# ── what a macro call made, shown under the call (Alt+M) at once from the saved file's NIF (Nim 2.4's `nim nif`,
#    nimony) instead of running the compiler again — written by nifread's nifPrint, which knows the forms a macro's
#    output usually has; on any other it gives up and the compiler is asked as before ──

proc nifMacroText(b: Buffer, line: int): string =
  ## what a macro call on a line of its own, at the top of a saved file, made — from the compiler's NIF: the statements
  ## between the one before the call and the one after it, written as Nim. "" when there is no fresh NIF, the call is
  ## not at the top, or the printer does not know a form in it (the compiler is asked then, as before)
  let fx = nifFactsFor(b)
  if fx == nil or line >= b.lines.len or b.lines[line].len == 0 or b.lines[line][0] in {' ', '\t'}: return ""
  var ns: seq[NifNode]
  let nim2 = fx.nif.endsWith(".nim2.nif")
  try:
    if getFileSize(fx.nif) > NifReadMax: return ""
    ns = nifParse(readFile(fx.nif).splitLines, before = nim2)
  except CatchableError: return ""
  if ns.len == 0: return ""
  # (where the statements before and after the call start in the source: the lines at the left edge around it)
  var prevL = -1
  for l in countdown(line - 1, 0):
    let s = b.lines[l]
    if s.len > 0 and s[0] notin {' ', '\t', '#'}:
      prevL = l
      break
  # (a top statement of the source starts at the left edge: the NIF's own statements are at those lines; what the
  # call made is between the last before the call and the first after it — its places may be in the macro's body)
  var starts: HashSet[int]
  for l in 0 ..< b.lines.len:
    let s = b.lines[l]
    if l != line and s.len > 0 and s[0] notin {' ', '\t', '#'}: starts.incl l
  let fileEnd = extractFilename(b.path)
  var parts: seq[string]
  var inside = false
  for k in nifTopStatements(ns):
    let n = ns[k]
    let ordinary = (n.file.len == 0 or n.file.endsWith(fileEnd)) and n.sline in starts
    if ordinary and n.sline < line:
      inside = true
      parts.setLen(0)
      continue
    if ordinary and n.sline > line: break
    if not inside and prevL >= 0: continue
    if n.tag in ["call", "cmd"] and n.sline == line: return ""     # (the call itself: not expanded here)
    let s = nifPrint(ns, k, not nim2)
    if s.len == 0 and ns[k].tag notin ["comment", "pragmas"]: return ""
    if s.strip.len > 0: parts.add s
  parts.join("\n")
