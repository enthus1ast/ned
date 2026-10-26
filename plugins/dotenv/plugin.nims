## dotenv — .env files: their colours, their keys in the outline, their mistakes as you type (a key twice, a name a
## shell would not take, spaces around =, a value with spaces and no quotes), a ${KEY}'s value on hover, and an
## .env.example made from them
##
##   The language: .env, .env.local, .env.production … .flaskenv, .envrc and *.env files — # comments, "…" and '…'
##   Problems as you type: a key set twice (the line before named), a name that is not A-Z a-z 0-9 _ (or starts
##   with a digit), `KEY = value` (most loaders read the spaces as part of the name), a value with spaces and no
##   quotes, a line with no =
##   Hover on a ${KEY} or $KEY in a value: what that key is set to
##   Env: make .env.example          the keys with their values taken out (comments kept), next to the file —
##                                    for the repository, where the real .env is not
##   Env: compare with .env.example  the keys one has that the other does not, in the Output panel
import nedplugin
import std/[strutils, os]

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("files", "Env: make .env.example writes that file next to the .env")

language("dotenv", LangSpec(
  name: ".env",
  extensions: @["env"],
  files: @[".env", ".env.local", ".env.example", ".env.sample", ".env.development", ".env.production", ".env.test",
           ".env.staging", ".env.defaults", ".flaskenv", ".envrc"],
  lineComment: "#",
  quotes: "\"'",
  keywords: @["export"],
  constants: @["true", "false", "yes", "no", "on", "off"],
  pairs: "\"\"''{}"))

type Entry* = object
  key*, value*: string
  line*, keyCol*, valCol*: int
  quoted*: bool
  problem*: string

func isName(k: string): bool =
  k.len > 0 and k[0] notin {'0'..'9'} and k.allCharsInSet({'A'..'Z', 'a'..'z', '0'..'9', '_'})

func parseEnv*(lines: seq[string]): seq[Entry] =
  ## each KEY=value line (an `export ` before it allowed), with what is wrong with it
  for i, raw in lines:
    let t = raw.strip
    if t.len == 0 or t.startsWith("#"): continue
    var s = raw
    var col = raw.len - raw.strip(trailing = false).len
    if t.startsWith("export "):
      col += 7
      while col < raw.len and raw[col] == ' ': inc col
    let eq = raw.find('=', col)
    var e = Entry(line: i, keyCol: col)
    if eq < 0:
      e.key = raw[col .. ^1].strip
      e.problem = "no = on this line: KEY=value"
      result.add e
      continue
    let rawKey = raw[col ..< eq]
    e.key = rawKey.strip
    var v = raw[eq + 1 .. ^1]
    e.valCol = eq + 1
    if rawKey.len != rawKey.strip(leading = false).len or (v.len > 0 and v[0] == ' '):
      e.problem = "spaces around = : most loaders take them as part of the name or the value (KEY=value)"
    elif not isName(e.key):
      e.problem = "'" & e.key & "' is not a name a shell takes: letters, digits and _, not a digit first"
    let vt = v.strip
    if vt.len > 0 and vt[0] in {'"', '\''}:
      e.quoted = true
      let q = vt[0]
      let close = vt.find(q, 1)
      e.value = if close > 0: vt[1 ..< close] else: vt[1 .. ^1]
      if close < 0 and e.problem.len == 0: e.problem = "the " & q & " is not closed"
    else:
      # (an unquoted value ends at a # that has a space before it)
      var val = vt
      let h = val.find(" #")
      if h >= 0: val = val[0 ..< h].strip
      e.value = val
      if ' ' in val and e.problem.len == 0:
        e.problem = "a value with spaces needs quotes: " & e.key & "=\"" & val & "\""
    discard s
    result.add e

proc check(b: Buf) =
  var ps: seq[Problem]
  let es = parseEnv(b.lines)
  var seen: seq[(string, int)]
  for e in es:
    let r = rng(pos(e.line, e.keyCol), pos(e.line, e.keyCol + e.key.len))
    if e.problem.len > 0:
      var fixes: seq[Fix]
      let l = b.line(e.line)
      if e.problem.startsWith("spaces around"):
        # KEY = value → KEY=value
        let eq = l.find('=', e.keyCol)
        var vs = eq + 1
        while vs < l.len and l[vs] == ' ': inc vs
        fixes.add Fix(title: "Take the spaces out: " & e.key & "=…",
                      edits: @[Edit(range: rng(pos(e.line, e.keyCol + e.key.len), pos(e.line, vs)), text: "=")])
      elif e.problem.startsWith("a value with spaces"):
        fixes.add Fix(title: "Put the value in quotes", edits: @[
          Edit(range: rng(pos(e.line, e.valCol + (l.len - e.valCol - l[e.valCol .. ^1].strip(trailing = false).len)),
                          pos(e.line, e.valCol + (l.len - e.valCol - l[e.valCol .. ^1].strip(trailing = false).len) +
                              e.value.len)), text: "\"" & e.value & "\"")])
      ps.add Problem(range: r, message: e.problem, fixes: fixes,
                     severity: (if "not closed" in e.problem or "no =" in e.problem: 1 else: 2))
    for (k, l) in seen:
      if k == e.key:
        ps.add Problem(range: r, message: "'" & e.key & "' is set twice (line " & $(l + 1) & " too): the last one counts",
                       severity: 2)
        break
    seen.add (e.key, e.line)
  b.setProblems(ps)

onOpen("lang:dotenv") do (ev: Event): check(ev.buf)
onChange("lang:dotenv") do (ev: Event): check(ev.buf)

symbols("dotenv") do (b: Buf) -> seq[Symbol]:
  for e in parseEnv(b.lines):
    result.add Symbol(name: e.key, kind: "variable", detail: (if e.value.len > 30: e.value[0 ..< 30] & "…" else: e.value),
                      line: e.line, col: e.keyCol)

hover("dotenv") do (b: Buf, p: Pos) -> string:
  let s = b.line(p.line)
  # ${KEY} or $KEY under the cursor
  var a = p.col
  while a > 0 and s[a - 1] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: dec a
  var e = p.col
  while e < s.len and s[e] in {'A'..'Z', 'a'..'z', '0'..'9', '_'}: inc e
  if a >= e: return ""
  let isRef = (a > 0 and s[a - 1] == '$') or (a > 1 and s[a - 1] == '{' and s[a - 2] == '$')
  if not isRef: return ""
  let key = s[a ..< e]
  for en in parseEnv(b.lines):
    if en.key == key and en.line != p.line:
      return "`" & key & "` = `" & en.value & "` (line " & $(en.line + 1) & ")"
  "`" & key & "` is not set in this file (the environment's, when there is one)"

func exampleOf*(lines: seq[string]): seq[string] =
  ## the file with its values taken out: KEY= (comments and blank lines kept)
  for l in lines:
    let t = l.strip
    if t.len == 0 or t.startsWith("#"):
      result.add l
      continue
    let eq = l.find('=')
    result.add (if eq < 0: l else: l[0 .. eq])

proc makeExample() =
  let b = current()
  if b.path.len == 0:
    message("Save the file first")
    return
  let dest = b.path.parentDir / ".env.example"
  if dest == b.path:
    message("This is the example")
    return
  if fileExists(dest) and not confirm(".env.example is there — replace it?"): return
  writeFile(dest, exampleOf(b.lines).join("\n") & "\n")
  message("Made " & dest.extractFilename & " (" & $parseEnv(b.lines).len & " keys, no values)")

proc compareExample() =
  let b = current()
  let other = b.path.parentDir / (if b.path.endsWith(".env.example"): ".env" else: ".env.example")
  if not fileExists(other):
    message("No " & other.extractFilename & " next to this file")
    return
  var mine, theirs: seq[string]
  for e in parseEnv(b.lines): mine.add e.key
  for e in parseEnv(readFile(other).splitLines): theirs.add e.key
  var onlyMine, onlyTheirs: seq[string]
  for k in mine:
    if k notin theirs: onlyMine.add k
  for k in theirs:
    if k notin mine: onlyTheirs.add k
  output("Only in " & b.path.extractFilename & ": " & (if onlyMine.len > 0: onlyMine.join(", ") else: "—") & "\n" &
         "Only in " & other.extractFilename & ": " & (if onlyTheirs.len > 0: onlyTheirs.join(", ") else: "—") & "\n")
  message(if onlyMine.len + onlyTheirs.len == 0: "The same keys" else: $(onlyMine.len + onlyTheirs.len) &
          " keys differ (Output panel)")

command "Env: make .env.example":
  makeExample()

command "Env: compare with .env.example":
  compareExample()
