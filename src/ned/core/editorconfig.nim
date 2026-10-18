## .editorconfig (editorconfig.org): the properties a project's .editorconfig files give a file — read by the
## editor (indentation, line ends, whitespace, the ruler) and by nedfmt and nedls (max_line_length: where Nim lines
## wrap when nim.format.lineLength is not set)

import std/[os, strutils, tables, times]

proc ecStamp(path: string): int64 =
  try:
    let t = getLastModificationTime(path)
    t.toUnix * 1000 + t.nanosecond div 1_000_000
  except CatchableError: 0'i64

type
  EcSection = object
    glob: string
    props: seq[(string, string)]
  EcFile = object
    root: bool
    sections: seq[EcSection]
var ecCache: Table[string, (int64, EcFile)]      # .editorconfig path → (when it changed, what it says)

proc parseEditorConfig(text: string): EcFile =
  var cur = -1
  for raw in text.splitLines:
    let l = raw.strip
    if l.len == 0 or l[0] in {'#', ';'}: continue
    if l[0] == '[':
      let e = l.rfind(']')
      if e > 0:
        result.sections.add EcSection(glob: l[1 ..< e])
        cur = result.sections.high
      continue
    let eq = l.find('=')
    if eq <= 0: continue
    let k = l[0 ..< eq].strip.toLowerAscii
    let v = l[eq + 1 .. ^1].strip
    if k.len == 0: continue
    if cur < 0:
      if k == "root": result.root = v.toLowerAscii == "true"
    else: result.sections[cur].props.add (k, v)

func ecMatch(p: string, pi0: int, s: string, si0: int): bool =
  ## EditorConfig globs: * (not /), ** (anything), ?, [abc] [a-z] [!abc], {a,b,c}, {1..10}, \\ escapes
  var pi = pi0
  var si = si0
  while pi < p.len:
    let c = p[pi]
    case c
    of '*':
      if pi + 1 < p.len and p[pi + 1] == '*':
        let np = pi + 2
        if np < p.len and p[np] == '/' and ecMatch(p, np + 1, s, si): return true    # **/ : no folder too
        for k in si .. s.len:
          if ecMatch(p, np, s, k): return true
        return false
      for k in si .. s.len:
        if ecMatch(p, pi + 1, s, k): return true
        if k < s.len and s[k] == '/': break
      return false
    of '?':
      if si >= s.len or s[si] == '/': return false
      inc pi
      inc si
    of '[':
      var e = pi + 1
      if e < p.len and p[e] == '!': inc e
      if e < p.len and p[e] == ']': inc e
      while e < p.len and p[e] != ']': inc e
      if e >= p.len:                                   # no closing ]: an ordinary [
        if si >= s.len or s[si] != '[': return false
        inc pi
        inc si
        continue
      if si >= s.len or s[si] == '/': return false
      var k = pi + 1
      let neg = p[k] == '!'
      if neg: inc k
      var hit = false
      while k < e:
        if k + 2 < e and p[k + 1] == '-':
          if s[si] >= p[k] and s[si] <= p[k + 2]: hit = true
          k += 3
        else:
          if s[si] == p[k]: hit = true
          inc k
      if hit == neg: return false
      pi = e + 1
      inc si
    of '{':
      var depth = 0
      var e = pi
      while e < p.len:
        if p[e] == '\\': inc e
        elif p[e] == '{': inc depth
        elif p[e] == '}':
          dec depth
          if depth == 0: break
        inc e
      if e >= p.len:                                   # no closing }: an ordinary {
        if si >= s.len or s[si] != '{': return false
        inc pi
        inc si
        continue
      let inner = p[pi + 1 ..< e]
      let rest = p[e + 1 .. ^1]
      let dd = inner.find("..")
      if dd > 0:                                       # {1..10}: a whole number in that range
        try:
          let lo = parseInt(inner[0 ..< dd])
          let hi = parseInt(inner[dd + 2 .. ^1])
          var k = si
          if k < s.len and s[k] == '-': inc k
          let ds = k
          while k < s.len and s[k].isDigit: inc k
          if k == ds: return false
          let v = parseInt(s[si ..< k])
          if v < min(lo, hi) or v > max(lo, hi): return false
          return ecMatch(rest, 0, s, k)
        except ValueError: discard
      var alts: seq[string]
      var d2 = 0
      var a0 = 0
      var q = 0
      while q < inner.len:
        let ch = inner[q]
        if ch == '\\': inc q
        elif ch == '{': inc d2
        elif ch == '}': dec d2
        elif ch == ',' and d2 == 0:
          alts.add inner[a0 ..< q]
          a0 = q + 1
        inc q
      alts.add inner[min(a0, inner.len) .. ^1]
      if alts.len == 1:                                # {word}: ordinary braces
        let lit = "{" & inner & "}"
        if si + lit.len > s.len or s[si ..< si + lit.len] != lit: return false
        si += lit.len
        pi = e + 1
        continue
      for a in alts:
        if ecMatch(a & rest, 0, s, si): return true
      return false
    of '\\':
      if pi + 1 >= p.len or si >= s.len or s[si] != p[pi + 1]: return false
      pi += 2
      inc si
    else:
      if si >= s.len or s[si] != c: return false
      inc pi
      inc si
  si == s.len

proc ecGlobMatches*(glob, rel: string): bool =
  ## `rel`: the file's path from the .editorconfig's folder; a glob without / matches the name in any folder
  ## (EditorConfig's globs: * ** ? [abc] {a,b} {1..10} — also used for .ned/lint.json's exclude)
  if '/' notin glob: return ecMatch(glob, 0, rel.rsplit('/', 1)[^1], 0)
  ecMatch(if glob.startsWith("/"): glob[1 .. ^1] else: glob, 0, rel, 0)

proc editorConfigFor*(path: string): seq[(string, string, string)] =
  ## the .editorconfig properties for a file: (name, value, the file that set it); nearer files win
  var files: seq[(string, EcFile)]
  var dir = parentDir(path)
  for _ in 0 .. 64:
    let f = dir / ".editorconfig"
    if fileExists(f):
      let mt = ecStamp(f)
      var ef: EcFile
      if f in ecCache and ecCache[f][0] == mt: ef = ecCache[f][1]
      else:
        try: ef = parseEditorConfig(readFile(f))
        except CatchableError: discard
        ecCache[f] = (mt, ef)
      files.add (f, ef)
      if ef.root: break
    let up = parentDir(dir)
    if up == dir or up.len == 0: break
    dir = up
  var props: OrderedTable[string, (string, string)]
  for fi in countdown(files.high, 0):
    let (f, ef) = files[fi]
    let rel = relativePath(path, parentDir(f)).replace('\\', '/')
    for sec in ef.sections:
      if ecGlobMatches(sec.glob, rel):
        for (k, v) in sec.props:
          if v.toLowerAscii == "unset": props.del k
          else: props[k] = (v, f)
  for k, (v, f) in props: result.add (k, v, f)

proc editorConfigForget*() =
  ## after an .editorconfig changed: read again
  ecCache.clear()

proc editorConfigMaxLine*(path: string): int =
  ## max_line_length for the file (0: none, or "off")
  for (k, v, _) in editorConfigFor(path):
    if k == "max_line_length":
      try: result = parseInt(v.strip)
      except ValueError: result = 0
  if result notin 1 .. 2000: result = 0
