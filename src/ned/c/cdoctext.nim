# ── the documentation of a C declaration (the comment above it in its header or {.emit.}), and its short form ──

var cRawCache: Table[string, (times.Time, seq[string])]      # header → (mtime, its lines as written)

proc cRawLines(path: string): seq[string] =
  ## a C (or Nim) file's lines as written: its tab's when it is open, else from disk (a few kept)
  let bi = bufIndexByPath(path)
  if bi >= 0: return bufs[bi].lines
  var mt: times.Time
  try: mt = getLastModificationTime(path)
  except CatchableError: return
  if path in cRawCache and cRawCache[path][0] == mt: return cRawCache[path][1]
  try:
    var s = readFile(path)
    if s.len > 4_000_000: s.setLen(4_000_000)
    result = s.splitLines()
  except CatchableError: return
  if cRawCache.len > 24: cRawCache.clear()
  cRawCache[path] = (mt, result)

const CBoilerplate = ["Copyright", "(C)", "(c)", "License", "LICENSE", "GNU", "WARRANTY", "warranty",
  "Free Software Foundation", "This file is part of", "You should have received", "SPDX", "All rights reserved",
  "Permission is hereby granted", "THE SOFTWARE IS PROVIDED", "free software", "redistribute", "http://",
  "https://", "see <", "Boston, MA"]

proc cCommentClean(block0: seq[string]): seq[string] =
  ## a C comment's text: /* */ // /// //! /** * markers gone, Doxygen's @param / @return made readable
  for raw in block0:
    var t = raw.strip
    for pre in ["/**<", "/*!<", "///<", "//!<", "/**", "/*!", "/*", "///", "//!", "//"]:
      if t.startsWith(pre):
        t = t[pre.len .. ^1]
        break
    if t.endsWith("*/"): t = t[0 ..< t.len - 2]
    t = t.strip
    if t.startsWith("* ") or t == "*": t = t[1 .. ^1].strip
    elif t.startsWith("*") and not t.startsWith("*/"): t = t[1 .. ^1].strip
    for tag in ["@brief ", "\\brief ", "@short ", "\\short "]:
      if t.startsWith(tag): t = t[tag.len .. ^1]
    for tag in ["@param ", "\\param ", "@param[in] ", "@param[out] ", "@param[in,out] ", "\\param[in] ",
                "\\param[out] "]:
      if t.startsWith(tag):
        let r = t[tag.len .. ^1].strip
        let sp = r.find(' ')
        t = if sp > 0: "- `" & r[0 ..< sp] & "` — " & r[sp + 1 .. ^1].strip else: "- `" & r & "`"
    for tag in ["@return ", "\\return ", "@returns ", "\\returns ", "@retval ", "\\retval "]:
      if t.startsWith(tag): t = "Returns " & t[tag.len .. ^1].strip
    result.add t
  while result.len > 0 and result[0].len == 0: result.delete(0)
  while result.len > 0 and result[^1].len == 0: result.setLen(result.len - 1)

proc cDocAt(lines: seq[string], line: int): string =
  ## the comment that documents the C declaration starting at `line`: the block right above it, else one after
  ## it on its last line (/**< … */, //!< …, or a plain one) — "" when there is none
  if line < 0 or line >= lines.len: return ""
  var blk: seq[string]
  let l = line - 1
  if l >= 0:
    let t = lines[l].strip
    if t.endsWith("*/"):
      var a = l
      while a >= 0 and "/*" notin lines[a] and l - a < 80: dec a
      # (a comment after the code of another line is that line's, not this one's)
      if a >= 0 and lines[a].strip.startsWith("/*"): blk = lines[a .. l]
    elif t.startsWith("//"):
      var a = l
      while a > 0 and lines[a - 1].strip.startsWith("//") and l - a < 60: dec a
      blk = lines[a .. l]
  if blk.len == 0:
    var e = line
    while e < lines.len and e < line + 12 and ';' notin lines[e] and '{' notin lines[e]: inc e
    if e < lines.len:
      let t = lines[e]
      let stop = max(t.find(';'), t.find('{'))
      let c1 = t.find("//", max(0, stop))
      let c2 = t.find("/*", max(0, stop))
      let c = if c1 >= 0 and (c2 < 0 or c1 < c2): c1 else: c2
      if stop >= 0 and c > stop: blk = @[t[c .. ^1]]
  let text = cCommentClean(blk)
  if text.len == 0: return ""
  var letters = 0
  for t in text:
    for ch in t:
      if ch in Letters: inc letters
  if letters < 3: return ""
  let joined = text.join("\n")
  if "Copyright" in joined or "License" in joined: return ""
  var r = text[0 ..< min(text.len, 30)].join("\n")
  if r.len > 1800: r = r[0 ..< 1800] & "…"
  r

proc cProtoDoc(cp: CProto): string =
  ## a C declaration's documentation (its header's comment, or the one in the {.emit.} it is defined in)
  if cp.path.len == 0: return ""
  cDocAt(cRawLines(cp.path), cp.line)

proc cPrettyParam(p: string): string =
  ## "const char *__restrict __format" → "const char *format"
  var t = p
  for w in ["__restrict__", "__restrict", "restrict", "__const", "__extension__"]:
    var k = t.find(w)
    while k >= 0:
      let before = k == 0 or t[k - 1] notin IdentChars
      let after = k + w.len >= t.len or t[k + w.len] notin IdentChars
      if before and after: t = t[0 ..< k] & t[k + w.len .. ^1]
      k = t.find(w, k + (if before and after: 0 else: w.len))
  # attributes: __attribute__((…)), __nonnull ((1))
  for w in ["__attribute__", "__nonnull", "__attr_dealloc"]:
    var k = t.find(w)
    while k >= 0:
      var e = k + w.len
      while e < t.len and t[e] == ' ': inc e
      if e < t.len and t[e] == '(':
        var d = 0
        while e < t.len:
          if t[e] == '(': inc d
          elif t[e] == ')':
            dec d
            if d == 0:
              inc e
              break
          inc e
      t = t[0 ..< k] & t[min(e, t.len) .. ^1]
      k = t.find(w)
  t = t.splitWhitespace.join(" ")
  # a reserved parameter name (__stream) reads better without its underscores
  var e = t.len
  while e > 0 and t[e - 1] in IdentChars: dec e
  if e < t.len and t[e .. ^1].startsWith("__") and e > 0: t = t[0 ..< e] & t[e .. ^1].strip(chars = {'_'})
  t.replace(" *", " *").replace("* ", "*")

proc cPrettyProto(cp: CProto, name: string): string =
  ## a C function's declaration, short: "int fprintf(FILE *stream, const char *format, ...)"
  var ps: seq[string]
  for p in cp.params: ps.add cPrettyParam(p)
  if cp.varargs: ps.add "..."
  if ps.len == 0: ps.add "void"
  let ret = cp.ret.replace("*", " *").splitWhitespace.join(" ").replace("* *", "**")
  result = ret & (if ret.endsWith("*"): "" else: " ") & name & "(" & ps.join(", ") & ")"
