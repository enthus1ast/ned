# ── the Nim side: declarations that import C ──

proc pragmaItems(p: string): seq[(string, string)] =
  ## {.a, b: "x", c.} → (a, ""), (b, "x"), (c, "")
  var d = 0
  var cur = ""
  var parts: seq[string]
  var inStr = false
  for c in p:
    if c == '"': inStr = not inStr
    if not inStr:
      if c in {'(', '['}: inc d
      elif c in {')', ']'}: dec d
    if c == ',' and d == 0 and not inStr:
      parts.add cur
      cur = ""
    else: cur.add c
  parts.add cur
  for x in parts:
    let t = x.strip
    if t.len == 0: continue
    let c = t.find(':')
    if c > 0: result.add (t[0 ..< c].strip, t[c + 1 .. ^1].strip.strip(chars = {'"'}))
    else: result.add (t, "")

proc nimFfiDecls(lines: seq[string]): seq[NimFfi] =
  ## the declarations in a Nim file that import C: procs, vars and types with importc (or under a
  ## {.push importc.}), each with its header and parameter types
  var pushes: seq[(bool, string, string)]       # importc?, header, importc pattern
  var l = 0
  var section = ""                               # the var/let/const/type section we are in
  while l < lines.len:
    let raw = lines[l]
    let ind = leadWs(raw)
    if ind >= raw.len or raw[ind] == '#':
      inc l
      continue
    if ind == 0: section = ""
    # most lines cannot start an importc declaration: no copy of them is made
    if raw[ind] notin {'{', 'p', 'f', 'v', 'l', 'c', 't'} and not (section.len > 0 and ind > 0):
      inc l
      continue
    let t = raw.strip
    if t.startsWith("{.push"):
      var imp = false
      var hdr = ""
      var pat = ""
      for (k, v) in pragmaItems(t[6 .. ^1].replace(".}", "")):
        if k in ["importc", "importcpp"]:
          imp = true
          pat = v
        elif k == "header": hdr = v
      pushes.add (imp, hdr, pat)
      inc l
      continue
    if t.startsWith("{.pop"):
      if pushes.len > 0: pushes.setLen(pushes.len - 1)
      inc l
      continue
    var kind = ""
    var rest = ""
    for kw in ["proc", "func", "var", "let", "const", "type"]:
      if t.startsWith(kw) and (t.len == kw.len or t[kw.len] == ' '):
        kind = kw
        rest = t[kw.len .. ^1].strip
    if kind in ["var", "let", "const", "type"] and rest.len == 0:
      section = kind
      inc l
      continue
    if kind.len == 0 and section.len > 0 and ind > 0:
      kind = section
      rest = t
    if kind.len == 0:
      inc l
      continue
    # no importc push in force: the declaration (its first lines) has to say importc itself
    var pushImp = false
    for (pi, _, _) in pushes:
      if pi: pushImp = true
    if not pushImp:
      var said = false
      var k = l
      while k < lines.len and k - l <= 12 and not said:
        if k > l and leadWs(lines[k]) <= ind and lines[k].strip.len > 0: break
        if "importc" in lines[k]: said = true
        inc k
      if not said:
        inc l
        continue
    # the whole declaration: up to the end of its pragma, or its `=`
    var text = rest
    var map: seq[Pos]                              # text index → file position
    let startCol = raw.find(rest)
    for q in 0 ..< rest.len: map.add Pos(line: l, col: startCol + q)
    var e = l
    proc closed(x: string): bool =
      let pa = x.find("{.")
      if pa >= 0: return x.find(".}", pa) >= 0
      x.endsWith("=") or (x.count('(') <= x.count(')') and not x.endsWith(",") and not x.endsWith("("))
    while not closed(text) and e + 1 < lines.len and e - l < 12:
      inc e
      let nx = lines[e]
      let ns = nx.strip
      if ns.len == 0: break
      text.add " "
      map.add Pos(line: e, col: max(0, nx.len - 1))
      let c0 = nx.len - nx.strip(trailing = false).len
      for q in 0 ..< ns.len: map.add Pos(line: e, col: c0 + q)
      text.add ns
    # the name
    var n0 = 0
    while n0 < text.len and text[n0] == ' ': inc n0
    var n1 = n0
    if n1 < text.len and text[n1] == '`':
      let b2 = text.find('`', n1 + 1)
      n1 = if b2 < 0: text.len else: b2 + 1
    else:
      while n1 < text.len and text[n1] in IdentChars: inc n1
    let name = text[n0 ..< n1].strip(chars = {'`'})
    if name.len == 0:
      l = e + 1
      continue
    # its pragma
    var imp = false
    var cname = ""
    var hdr = ""
    var va = false
    let pa = text.find("{.")
    if pa >= 0:
      let pe = text.find(".}", pa + 1)
      for (k, v) in pragmaItems(text[pa + 2 ..< (if pe < 0: text.len else: max(pa + 2, pe))]):
        if k in ["importc", "importcpp"]:
          imp = true
          cname = v
        elif k == "header": hdr = v
        elif k == "varargs": va = true
    for (pi, ph, pp) in pushes:
      if pi and not imp:
        imp = true
        if pp.len > 0 and cname.len == 0: cname = pp.replace("$1", name)
      if hdr.len == 0 and ph.len > 0: hdr = ph
    if not imp or kind == "const":
      l = e + 1
      continue
    if cname.len == 0 or "$1" in cname: cname = (if cname.len > 0: cname.replace("$1", name) else: name)
    var f = NimFfi(line: l, eline: e, kind: kind, name: name, nameCol: (if n0 < map.len: map[n0].col else: 0),
                   cname: cname, header: hdr, varargs: va)
    if kind in ["proc", "func"]:
      let po = text.find('(', n1)
      if po >= 0 and (pa < 0 or po < pa):
        var d = 0
        var pc = po
        while pc < text.len:
          if text[pc] in {'(', '['}: inc d
          elif text[pc] in {')', ']'}:
            dec d
            if d == 0: break
          inc pc
        # groups "a, b: T" separated by ; or by , at the top level
        var groups: seq[(int, int)]
        var g0 = po + 1
        var dd = 0
        for q in po + 1 .. pc:
          if q == pc or (dd == 0 and text[q] == ';'):
            groups.add (g0, q)
            g0 = q + 1
          elif text[q] in {'(', '['}: inc dd
          elif text[q] in {')', ']'}: dec dd
        var names: seq[string]
        for (ga, ge) in groups:
          let gt = text[ga ..< ge]
          # "a: int, b: cint" also separates by commas: split where a comma is followed by `name:`
          var subs: seq[(int, int)]
          var s0 = ga
          var dq = 0
          for q in ga ..< ge:
            if text[q] in {'(', '['}: inc dq
            elif text[q] in {')', ']'}: dec dq
            elif text[q] == ',' and dq == 0:
              let after = text[q + 1 ..< ge]
              let colon = after.find(':')
              if colon > 0 and after[0 ..< colon].strip.allCharsInSet(IdentChars):
                subs.add (s0, q)
                s0 = q + 1
          subs.add (s0, ge)
          discard gt
          for (sa, se) in subs:
            let part = text[sa ..< se]
            let colon = part.find(':')
            if colon < 0:
              for nm in part.split(','): (if nm.strip.len > 0: names.add nm.strip)
              continue
            for nm in part[0 ..< colon].split(','): (if nm.strip.len > 0: names.add nm.strip)
            var ta = sa + colon + 1
            while ta < se and text[ta] == ' ': inc ta
            var te = se
            let eq = part.find('=', colon)
            if eq > 0: te = sa + eq
            while te > ta and text[te - 1] == ' ': dec te
            let typ = text[ta ..< te]
            for nm in names:
              if ta < map.len and te - 1 < map.len:
                f.params.add (nm, typ, map[ta], Pos(line: map[te - 1].line, col: map[te - 1].col + 1))
            names.setLen(0)
        # the return type
        var r = pc + 1
        while r < text.len and text[r] == ' ': inc r
        if r < text.len and text[r] == ':':
          inc r
          while r < text.len and text[r] == ' ': inc r
          var re = r
          while re < text.len and not text.continuesWith("{.", re) and text[re] != '=': inc re
          while re > r and text[re - 1] == ' ': dec re
          if re > r and r < map.len and re - 1 < map.len:
            f.ret = text[r ..< re]
            f.retAt = map[r]
            f.retEnd = Pos(line: map[re - 1].line, col: map[re - 1].col + 1)
    elif kind in ["var", "let"]:
      # name* {.pragma.}: T
      let pe = if pa >= 0: text.find(".}", pa) else: -1
      let from0 = if pe >= 0: pe + 2 else: n1
      let colon = text.find(':', from0)
      if colon >= 0:
        var r = colon + 1
        while r < text.len and text[r] == ' ': inc r
        var re = text.len
        let eq = text.find('=', r)
        if eq > 0: re = eq
        while re > r and text[re - 1] == ' ': dec re
        if re > r and re - 1 < map.len:
          f.ret = text[r ..< re]
          f.retAt = map[r]
          f.retEnd = Pos(line: map[re - 1].line, col: map[re - 1].col + 1)
    result.add f
    l = e + 1

proc ffiAtLine(decls: seq[NimFfi], line: int): int =
  for i, d in decls:
    if line >= d.line and line <= d.eline: return i
  -1
