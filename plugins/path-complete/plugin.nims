## path-complete — the names of files and folders completed in a path you type (a string, an import, a link)
##
##   as you type a path — in quotes ("./…", '../…', "~/…", "/…", or a name with a / in it:
##   staticRead("data/…"), "src/…"), in a comment (# see ./docs/…), on a Nim import or include line
##   (import ../src/…: modules without .nim), in a Markdown link (](./docs/…) — a space as %20): after each / the
##   names in that folder (and on Ctrl+Space), folders first with a / after them.
##   ./ and ../ start from the file's folder, ~/ from your home folder; a name without either from the file's
##   folder, else the project's. Hidden files only once you type the dot (./.git…).
##   setting   plugins.path-complete.maxEntries — how many names at most (100)
##
## (In strings and comments ned asks after / ~ ( and #, and the list narrows as you type the name's letters and
## digits; a . - or space closes it: Ctrl+Space brings it back.)
import nedplugin
import std/algorithm

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("maxEntries", 100, "Path completion: how many names of a folder it offers at most")

type Ctx = enum cxNone, cxString, cxImport, cxLink, cxComment

# whether c is a letter, digit, _ or a byte of a non-ASCII character — what ned counts as the word being typed
func isWordCh(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'} or c.uint8 >= 0x80

func stringBefore(upto: string): (bool, int) =
  ## the cursor (at the end of upto) is in a string: where the string's text starts
  var q = '\0'
  var start = -1
  var i = 0
  while i < upto.len:
    let c = upto[i]
    if q != '\0':
      if c == '\\' and i + 1 < upto.len: inc i
      elif c == q: q = '\0'
    elif c in {'"', '\'', '`'}:
      q = c
      start = i + 1
    inc i
  (q != '\0', start)

func typedPath(line: string, col: int): (Ctx, string) =
  ## what the path typed before col is in, and the path as typed so far
  let upto = line[0 ..< min(col, line.len)]
  let t = upto.strip(trailing = false)
  for kw in ["import ", "include ", "from "]:
    if t.startsWith(kw):
      var rest = t[kw.len .. ^1]
      if kw == "from ":
        let k = rest.find(" import ")
        if k >= 0: return (cxNone, "")
      if rest.len == 0 or rest[^1] in {' ', ','}: return (cxNone, "")
      var a = rest.len
      while a > 0 and rest[a - 1] notin {' ', ',', '['}: dec a
      return (cxImport, rest[a .. ^1])
  let (inStr, s) = stringBefore(upto)
  let k = upto.rfind("](")
  if k >= 0 and ')' notin upto[k + 2 .. ^1] and (not inStr or s < k): return (cxLink, upto[k + 2 .. ^1])
  if inStr: return (cxString, upto[s .. ^1])
  (cxNone, "")

func inComment(upto, cm: string): (Ctx, string) =
  ## after the line's comment (not one in a string): the word before the cursor
  var q = '\0'
  var i = 0
  while i < upto.len:
    let c = upto[i]
    if q != '\0':
      if c == '\\': inc i
      elif c == q: q = '\0'
    elif c in {'"', '\''}: q = c
    elif upto.continuesWith(cm, i):
      var a = upto.len
      while a > i + cm.len and upto[a - 1] notin {' ', '\t', '(', '<', '`', '"', '\''}: dec a
      return (cxComment, upto[a .. ^1])
    inc i
  (cxNone, "")

func looksLikePath(p: string): bool =
  ## whether the text typed can be a path: it starts with ./, ../, ~/ or /, or has a / in it
  p.startsWith("./") or p.startsWith("../") or p.startsWith("~/") or p.startsWith("/") or '/' in p

# a Markdown link's path with %20 turned back into spaces
func decoded(s: string): string = s.replace("%20", " ")
# a name with its spaces written %20, for a Markdown link
func encoded(s: string): string = s.replace(" ", "%20")

proc entries(dir: string): seq[(string, bool)] =
  ## the folder's names, each with true for a folder
  when defined(nimscript):
    for d in listDirs(dir): result.add (extractFilename(d.strip(leading = false, chars = {'/'})), true)
    for f in listFiles(dir): result.add (extractFilename(f), false)
  else:
    for k, p in walkDir(dir, relative = true):
      result.add (p, k in {pcDir, pcLinkToDir})

func fuzzy(typed, s: string): bool =
  ## the letters typed are in s, in that order (any case)
  var k = 0
  for c in s:
    if k < typed.len and c.toLowerAscii == typed[k].toLowerAscii: inc k
  k == typed.len

proc folderOf(b: Buf, dirPart: string): string =
  ## the folder that the part of the path before its last / names
  let here = b.path.parentDir
  let root = projectRoot()
  let base = if here.len > 0: here else: root
  if dirPart.startsWith("~/"): return getHomeDir() / dirPart[2 .. ^1]
  if dirPart.startsWith("/"): return dirPart
  if dirPart.startsWith("./") or dirPart.startsWith("../") or dirPart.len == 0: return base / dirPart
  if dirExists(base / dirPart): base / dirPart else: root / dirPart

completions("*") do (b: Buf, p: Pos, prefix: string) -> seq[CompletionItem]:
  let l = b.line(p.line)
  var (ctx, raw) = typedPath(l, p.col)
  if ctx == cxNone and ('/' in l or '~' in l):
    let cm = b.lineComment
    if cm.len > 0: (ctx, raw) = inComment(l[0 ..< min(p.col, l.len)], cm)
  if ctx == cxNone or not looksLikePath(raw): return
  # the folder's part, the name's part; ned puts the item in place of the word typed (prefix), so each item is
  # what comes after the part of the name before that word
  let slash = raw.rfind('/')
  let seg = raw[slash + 1 .. ^1]
  var w = seg.len
  while w > 0 and isWordCh(seg[w - 1]): dec w
  let before = seg[0 ..< w]
  let word = seg[w .. ^1]
  let dir = folderOf(b, (if ctx == cxLink: decoded(raw[0 .. slash]) else: raw[0 .. slash]))
  if not dirExists(dir): return
  var found: seq[(string, bool)]
  for (name, isDir) in entries(dir):
    var n = name
    if ctx == cxImport and not isDir:
      if not n.endsWith(".nim"): continue
      n = n[0 ..< n.len - 4]
    if ctx == cxLink: n = encoded(n)
    if n.startsWith(".") and not before.startsWith("."): continue
    if n.startsWith(before) and fuzzy(word, n[before.len .. ^1]): found.add (n, isDir)
  found.sort(proc(x, y: (string, bool)): int =
    if x[1] != y[1]: (if x[1]: -1 else: 1) else: cmp(x[0].toLowerAscii, y[0].toLowerAscii))
  let most = max(1, setting("maxEntries", 100))
  for (n, isDir) in found[0 ..< min(found.len, most)]:
    let label = n & (if isDir: "/" else: "")
    result.add CompletionItem(label: label, insert: label[before.len .. ^1], kind: (if isDir: "folder" else: "file"),
                              detail: (if isDir: "folder" else: "file"))
