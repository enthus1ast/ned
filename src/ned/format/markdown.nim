# ── Markdown: tables aligned ──

proc mdCells*(line: string): seq[string] =
  ## the cells of a table row: split at every | but \| (in GitHub's tables a | inside `code` splits too)
  var s = line.strip
  if s.startsWith("|"): s = s[1 .. ^1]
  if s.endsWith("|") and not s.endsWith("\\|"): s = s[0 ..< ^1]
  var cur = ""
  var i = 0
  while i < s.len:
    let c = s[i]
    if c == '\\' and i + 1 < s.len:
      cur.add c
      cur.add s[i + 1]
      i += 2
      continue
    if c == '|':
      result.add cur.strip
      cur = ""
    else: cur.add c
    inc i
  result.add cur.strip

proc mdIsDelim*(line: string): bool =
  let t = line.strip
  if '-' notin t: return false
  if '|' notin t and not t.startsWith(":"): return false
  for c in mdCells(line):
    let x = c.strip
    if x.len == 0: return false
    for ch in x:
      if ch notin {'-', ':'}: return false
    if x.strip(chars = {':'}).len == 0: return false
  true

proc fmtMarkdown*(s: string): (string, string) =
  ## tables lined up (column widths, alignment colons kept); outside code blocks only
  var lines = s.split('\n')
  var outp: seq[string]
  var i = 0
  var fence = ""
  while i < lines.len:
    let l = lines[i]
    let t = l.strip
    if fence.len > 0:
      outp.add l
      if t.startsWith(fence): fence = ""
      inc i
      continue
    if t.startsWith("```") or t.startsWith("~~~"):
      fence = t[0 .. 2]
      outp.add l
      inc i
      continue
    if '|' in l and i + 1 < lines.len and mdIsDelim(lines[i + 1]) and not l.startsWith("    ") and
       mdCells(l).len == mdCells(lines[i + 1]).len:
      let lead = l[0 ..< (l.len - l.strip(trailing = false).len)]
      var rows = @[mdCells(l)]
      let delim = mdCells(lines[i + 1])
      var j = i + 2
      while j < lines.len and lines[j].strip.len > 0 and '|' in lines[j]:
        rows.add mdCells(lines[j])
        inc j
      let n = delim.len
      var al = newSeq[char](n)          # 'l' left · 'c' centre · 'r' right · ' ' none
      for k, d in delim:
        let x = d.strip
        al[k] = (if x.startsWith(":") and x.endsWith(":"): 'c' elif x.endsWith(":"): 'r' elif x.startsWith(":"): 'l' else: ' ')
      for r in rows.mitems:
        while r.len < n: r.add ""
      var w = newSeq[int](n)
      for k in 0 ..< n: w[k] = 3
      for r in rows:
        for k in 0 ..< r.len:
          if k < n: w[k] = max(w[k], strWidth(r[k]))
      proc cell(x: string, k: int): string =
        let pad = w[k] - strWidth(x)
        case al[k]
        of 'r': spaces(pad) & x
        of 'c': spaces(pad div 2) & x & spaces(pad - pad div 2)
        else: x & spaces(pad)
      proc row(r: seq[string]): string =
        var parts: seq[string]
        for k in 0 ..< r.len:
          parts.add (if k < n: cell(r[k], k) else: r[k])
        lead & "| " & parts.join(" | ") & " |"
      outp.add row(rows[0])
      var dl: seq[string]
      for k in 0 ..< n:
        dl.add (case al[k]
          of 'c': ":" & repeat('-', w[k] - 2) & ":"
          of 'r': repeat('-', w[k] - 1) & ":"
          of 'l': ":" & repeat('-', w[k] - 1)
          else: repeat('-', w[k]))
      outp.add lead & "| " & dl.join(" | ") & " |"
      for r in rows[1 .. ^1]: outp.add row(r)
      i = j
      continue
    outp.add l
    inc i
  var res = outp.join("\n")
  if not res.endsWith("\n"): res.add "\n"
  while res.endsWith("\n\n"): res.setLen(res.len - 1)
  (res, "")
