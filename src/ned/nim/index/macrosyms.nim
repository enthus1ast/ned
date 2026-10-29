# ── names a macro makes: the compiler's expansion of a file's top-level macro calls (ned's nim/macronames runs it)
#    adds their declarations to the file's own, at the call — as a template call's are (`made`) ──

type NxMacroCall* = object
  line*: int                # where the call was when it was expanded
  text*: string             # that line as it was (to find the call again when lines above it change)
  syms*: seq[NxSym]         # what the expansion declares (positions: its own)

var nxMacroSyms* = initTable[string, seq[NxMacroCall]]()   # path → its top-level macro calls, expanded
var nxMacroDone* = initTable[string, string]()    # path → its top-level macro calls (their lines) that this expansion
                                                 # is of: what they make is known while the calls are the same

proc nxAddMacroSyms*(f: NxFile, lines: openArray[string]) =
  ## the names the file's macro calls make, added to its declarations (each at its call, wherever that is now; a
  ## call no longer there adds nothing)
  if f == nil: return
  let calls = nxMacroSyms.getOrDefault(f.path)
  if calls.len == 0: return
  var taken: seq[int]
  for c in calls:
    var at = -1
    if c.line >= 0 and c.line < lines.len and lines[c.line] == c.text and c.line notin taken: at = c.line
    else:
      var best = high(int)
      for i in 0 ..< lines.len:
        if lines[i] == c.text and i notin taken and abs(i - c.line) < best:
          best = abs(i - c.line)
          at = i
    if at < 0: continue
    taken.add at
    var col = 0
    while col < c.text.len and c.text[col] in {' ', '\t'}: inc col
    for s0 in c.syms:
      var s = s0
      s.line = at
      s.col = col
      s.endLine = at
      s.made = true
      f.syms.add s
