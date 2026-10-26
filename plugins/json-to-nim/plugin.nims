## json-to-nim — Nim types from a sample of JSON: an object type for each object in it
##
##   JSON → Nim types      the JSON is the selection, else the clipboard, else the .json file you are in — in a .nim
##                         file with none of these, a .json file of the project you pick. The types go in at the
##                         cursor of a .nim file (JSON from the clipboard or another file), else in a tab (Root.nim:
##                         again, the same tab — unless you have changed it)
##   json_to_nim           the same for the assistant (it only reads)
##   setting               plugins.json-to-nim.rootName — the top-level type's name (Root)
##
## What the types are: `type Root* = object` with a field for each key, typed from its values — int, float, bool,
## string; an object is a type of its own, named after its key (`"home_address": {…}` → HomeAddress); an array is a
## seq[T] with T made from all its elements. A key some objects lack, or that is null somewhere, is an Option[T]; a
## value of mixed kinds is a JsonNode; an object whose keys are not names ("1", "en-GB") is a Table[string, T]. Two
## objects of the same shape share one type. A key that is a Nim keyword is in backticks (`type`); one that is not a
## Nim name gets a field of another name, and a comment says how to map it (jsony's renameHook). The fields work with
## std/json's `to` and with jsony, and an example of each ends the code.
import nedplugin
import std/algorithm

requiresNed(">= 6.26")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")
permission("shell", "lists the project's .json files with git (JSON → Nim types from a file)")
permission("clipboard", "reads JSON from the clipboard when nothing is selected")

settingDef("rootName", "Root", "JSON → Nim types: the name of the top-level type")

const NimKeywords = ["addr", "and", "as", "asm", "bind", "block", "break", "case", "cast", "concept", "const",
  "continue", "converter", "defer", "discard", "distinct", "div", "do", "elif", "else", "end", "enum", "except",
  "export", "finally", "for", "from", "func", "if", "import", "in", "include", "interface", "is", "isnot", "iterator",
  "let", "macro", "method", "mixin", "mod", "nil", "not", "notin", "object", "of", "or", "out", "proc", "ptr",
  "raise", "ref", "return", "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var", "when",
  "while", "xor", "yield"]
# (type names the code uses: a key of that name gets a type of another name)
const TakenTypes = ["Option", "Table", "OrderedTable", "JsonNode", "JsonNodeKind", "Natural", "Positive", "Ordinal",
  "Exception", "Defect", "Some", "None"]

type
  ShapeKind = enum skNull, skBool, skInt, skFloat, skString, skArray, skObject, skMap, skAny
  Shape = ref object
    ## what the values at one place of the JSON look like, all of them merged
    kind: ShapeKind
    nullable: bool               # null was one of them
    elem: Shape                  # skArray: its elements (nil: always empty); skMap: its values
    keys: seq[string]            # skObject: its keys, in the order they first came
    fields: seq[Shape]           # … each one's values
    present: seq[int]            # … in how many of the objects it was
    count: int                   # how many objects were merged
    hint: string                 # the key it came from (its type's name)

# ── names ──

func isIdentByte(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9'} or c.uint8 >= 0x80

func isNimName(s: string): bool =
  ## a name Nim takes as it is: a letter first, then letters, digits and single underscores, none at the end
  if s.len == 0 or not (s[0] in {'a'..'z', 'A'..'Z'} or s[0].uint8 >= 0x80): return false
  for i, c in s:
    if c == '_':
      if i == s.high or s[i + 1] == '_': return false
    elif not isIdentByte(c): return false
  true

func words(s: string): seq[string] =
  ## the runs of letters and digits ("first-name" → first, name; "userName" stays one)
  var w = ""
  for c in s:
    if isIdentByte(c): w.add c
    elif w.len > 0:
      result.add w
      w = ""
  if w.len > 0: result.add w

func capital(w: string): string =
  if w.len == 0: "" else: toUpperAscii(w[0]) & w[1 .. ^1]

func pascal(s: string): string =
  ## a type's name from a key: "home_address" → HomeAddress, "userId" → UserId
  for w in words(s): result.add capital(w)
  if result.len == 0: result = "Item"
  elif result[0] in Digits: result = "T" & result

func camel(s: string): string =
  ## a field's name from a key that is not a Nim name: "first-name" → firstName, "@id" → id, "2fa" → n2fa
  let ws = words(s)
  for i, w in ws: result.add (if i == 0: w else: capital(w))
  if result.len == 0: result = "empty"
  elif result[0] in Digits: result = "n" & result

func singular(s: string): string =
  ## the name of one element of an array: users → user, categories → category, boxes → box
  let l = s.toLowerAscii
  if l.endsWith("ies") and s.len > 4: s[0 ..< s.len - 3] & "y"
  elif (l.endsWith("sses") or l.endsWith("shes") or l.endsWith("ches") or l.endsWith("xes") or l.endsWith("zes")) and
       s.len > 4: s[0 ..< s.len - 2]
  elif l.endsWith("s") and not (l.endsWith("ss") or l.endsWith("us") or l.endsWith("is")) and s.len > 2:
    s[0 ..< s.len - 1]
  else: s & "Item"

func isKeyword(f: string): bool =
  ## a keyword, as Nim compares names (`isNot` is `isnot`)
  f.len > 0 and f[0] in {'a'..'z'} and f.replace("_", "").toLowerAscii in NimKeywords

func sameName(a, b: string): bool =
  ## Nim's rule: the first letters as they are, the rest without case and underscores
  a.len > 0 and b.len > 0 and a[0] == b[0] and
    a[1 .. ^1].replace("_", "").toLowerAscii == b[1 .. ^1].replace("_", "").toLowerAscii

# ── the shapes ──

proc clone(s: Shape): Shape =
  Shape(kind: s.kind, nullable: s.nullable, elem: s.elem, keys: s.keys, fields: s.fields, present: s.present,
        count: s.count, hint: s.hint)

proc merge(a, b: Shape): Shape =
  ## one shape for the values of both (a new one: neither changes)
  if a == nil: return b
  if b == nil: return a
  if a.kind == skNull:
    result = clone(b)
    result.nullable = true
    return
  if b.kind == skNull:
    result = clone(a)
    result.nullable = true
    return
  let nul = a.nullable or b.nullable
  if a.kind == b.kind:
    result = clone(a)
    result.nullable = nul
    case a.kind
    of skArray, skMap: result.elem = merge(a.elem, b.elem)
    of skObject:
      result.count = a.count + b.count
      for j, k in b.keys:
        let i = result.keys.find(k)
        if i < 0:
          result.keys.add k
          result.fields.add b.fields[j]
          result.present.add b.present[j]
        else:
          result.fields[i] = merge(result.fields[i], b.fields[j])
          result.present[i] += b.present[j]
    else: discard
  elif {a.kind, b.kind} == {skInt, skFloat}:
    result = Shape(kind: skFloat, nullable: nul)
  else:
    result = Shape(kind: skAny, nullable: nul)

proc infer(n: JsonNode, hint: string): Shape =
  case n.kind
  of JNull: result = Shape(kind: skNull, nullable: true, hint: hint)
  of JBool: result = Shape(kind: skBool)
  of JInt: result = Shape(kind: skInt)
  of JFloat: result = Shape(kind: skFloat)
  of JString: result = Shape(kind: skString)
  of JArray:
    var e: Shape = nil
    for x in n: e = merge(e, infer(x, singular(hint)))
    result = Shape(kind: skArray, elem: e, hint: hint)
  of JObject:
    var names = 0
    for k, _ in n:
      if isNimName(k): inc names
    if n.len >= 2 and names == 0:
      # keys that are not names ("1", "2", "en-GB"): a table, when its values have one shape
      var e: Shape = nil
      for _, v in n: e = merge(e, infer(v, singular(hint)))
      if e.kind != skAny: return Shape(kind: skMap, elem: e, hint: hint)
    result = Shape(kind: skObject, count: 1, hint: hint)
    for k, v in n:
      result.keys.add k
      result.fields.add infer(v, k)
      result.present.add 1

func sig(s: Shape): string =
  ## the shape as text: two objects with the same one share a type
  if s == nil: return "-"
  result = case s.kind
    of skNull: "n"
    of skBool: "b"
    of skInt: "i"
    of skFloat: "f"
    of skString: "s"
    of skAny: "a"
    of skArray: "[" & sig(s.elem) & "]"
    of skMap: "{:" & sig(s.elem) & "}"
    of skObject:
      var parts: seq[string]
      for i, k in s.keys:
        parts.add k & (if s.present[i] < s.count: "?" else: "") & ":" & sig(s.fields[i])
      parts.sort()
      "{" & parts.join(",") & "}"
  if s.nullable and s.kind != skNull: result.add "?"

# ── the code ──

type
  Gen = object
    names: seq[string]           # each object type's name …
    sigs: seq[string]            # … and its shape
    order: seq[Shape]            # the object types, in the order they are written
    usesOption, usesTable: bool

proc typeName(g: var Gen, s: Shape, parent: string): string =
  ## the type of an object shape: the one it had before, or a new name from its key
  let sg = sig(s)
  let k = g.sigs.find(sg)
  if k >= 0: return g.names[k]
  var name = pascal(s.hint)
  if name in g.names or name in TakenTypes: name = parent & name
  var n = 2
  let base = name
  while name in g.names or name in TakenTypes:
    name = base & $n
    inc n
  g.names.add name
  g.sigs.add sg
  g.order.add s
  name

proc nimType(g: var Gen, s: Shape, parent: string): string =
  ## what a value of the shape is in Nim (no Option: the field adds that)
  if s == nil: return "JsonNode"
  case s.kind
  of skNull, skAny: "JsonNode"
  of skBool: "bool"
  of skInt: "int"
  of skFloat: "float"
  of skString: "string"
  of skArray:
    var t = nimType(g, s.elem, parent)
    if s.elem != nil and s.elem.nullable and t != "JsonNode":
      g.usesOption = true
      t = "Option[" & t & "]"
    "seq[" & t & "]"
  of skMap:
    g.usesTable = true
    var t = nimType(g, s.elem, parent)
    if s.elem.nullable and t != "JsonNode":
      g.usesOption = true
      t = "Option[" & t & "]"
    "Table[string, " & t & "]"
  of skObject:
    if s.keys.len == 0: "JsonNode"        # (always {}: nothing to make a type of)
    else: typeName(g, s, parent)

func fieldName(key: string, taken: seq[string]): string =
  ## the field for a key: the key itself when Nim takes it (a keyword in backticks), else a name made from it;
  ## a number after it when Nim would take it for one the type has already
  var n = if isNimName(key): key else: camel(key)
  let base = n
  var i = 2
  var clash = true
  while clash:
    clash = false
    for t in taken:
      if sameName(t, n):
        clash = true
        n = base & $i
        inc i
        break
  n

proc typeSection(g: var Gen, root: Shape, rootName: string): tuple[code: string, renames: seq[string]] =
  var lines = @["type"]
  var hooks: seq[string]
  if root.kind != skObject or root.keys.len == 0:
    lines.add "  " & rootName & "* = " & nimType(g, root, rootName)
  else:
    discard typeName(g, root, "")
    g.names[0] = rootName             # (the top-level type has the name of the setting)
  var i = 0
  while i < g.order.len:            # (the types each one needs are added to the list as it is written)
    let s = g.order[i]
    let name = g.names[i]
    lines.add "  " & name & "* = object"
    var taken: seq[string]
    var renamed: seq[(string, string)]
    var rows: seq[(string, string)]
    for j, k in s.keys:
      let f = fieldName(k, taken)
      taken.add f
      let fs = s.fields[j]
      var t = nimType(g, fs, name)
      let missing = s.present[j] < s.count
      if (missing or fs.nullable) and not (t == "JsonNode" and not missing):
        g.usesOption = true
        t = "Option[" & t & "]"
      let decl = (if isKeyword(f): "`" & f & "`" else: f) & "*: " & t
      var note = ""
      if f != k:
        renamed.add (k, f)
        note = "the key " & escapeJson(k)
      if missing: note.add (if note.len > 0: "; " else: "") & "not in every object"
      rows.add (decl, note)
    var w = 0
    for (d, _) in rows: w = max(w, d.len)
    for (d, note) in rows:
      lines.add "    " & (if note.len > 0: d & spaces(max(1, w - d.len + 2)) & "# " & note else: d)
    if renamed.len > 0:
      hooks.add "#   proc renameHook*(v: var " & name & ", fieldName: var string) ="
      hooks.add "#     case fieldName"
      for (k, f) in renamed: hooks.add "#     of " & escapeJson(k) & ": fieldName = \"" & f & "\""
      hooks.add "#     else: discard"
    inc i
  (lines.join("\n"), hooks)

proc nimTypes(j: JsonNode, rootName: string, haveImports = ""): string =
  ## the Nim code for the JSON: imports (those `haveImports` does not have), the types, how to read the JSON
  var g: Gen
  let root = if j.kind == JArray: infer(j, rootName & "Items") else: infer(j, rootName)
  let (types, hooks) = typeSection(g, root, rootName)
  var mods = @["json"]
  if g.usesOption: mods.add "options"
  if g.usesTable: mods.add "tables"
  var need: seq[string]
  for m in mods:
    if m notin haveImports.splitWhitespace: need.add m
  var parts: seq[string]
  if need.len == 1: parts.add "import std/" & need[0]
  elif need.len > 1: parts.add "import std/[" & need.join(", ") & "]"
  parts.add types
  if hooks.len > 0:
    parts.add "# Keys that are not Nim names have fields of another name (the comment beside each). jsony maps " &
              "them\n# with a renameHook; std/json's `to` takes each field's name as the key, so rename those keys " &
              "in the\n# JsonNode before you call it.\n" & hooks.join("\n")
  parts.add "# let data = parseJson(text).to(" & rootName & ")     # std/json (text: the JSON)\n" &
            "# let data = text.fromJson(" & rootName & ")         # jsony"
  parts.join("\n\n") & "\n"

# ── where the JSON comes from, where the code goes ──

proc parsed(text: string, err: var string): JsonNode =
  ## the JSON (nil when it is not: err says why)
  let t = text.strip
  if t.len == 0 or t[0] notin {'{', '['}:
    err = "it does not start with { or ["
    return nil
  try: result = parseJson(t)
  except CatchableError as e:
    err = e.msg
    result = nil

func isNimPath(p: string): bool = p.endsWith(".nim") or p.endsWith(".nims") or p.endsWith(".nimble")

proc importsOf(lines: seq[string]): string =
  ## the modules the file's import lines name (std/json → json), as words
  for l in lines:
    let t = l.strip
    if t.startsWith("import ") or t.startsWith("from "):
      for w in t.multiReplace(("[", " "), ("]", " "), (",", " "), ("/", " ")).splitWhitespace: result.add " " & w

proc projectJsonFile(): string =
  ## a .json file of the project, from a list ("" when you choose none)
  let (o, _) = shell("(git ls-files --cached --others --exclude-standard '*.json' 2>/dev/null | grep . || " &
                     "find . -name '*.json' -not -path '*/.*' -not -path '*/node_modules/*' | sed 's|^\\./||') " &
                     "| sort | head -300")
  var files: seq[string]
  for f in o.splitLines:
    if f.strip.len > 0: files.add f.strip
  if files.len == 0: return ""
  let i = pick("Nim types from which JSON file?", files)
  if i < 0: "" else: files[i]

proc readProjectFile(rel: string): string =
  let p = if rel.isAbsolute: rel else: projectRoot() / rel
  if not fileExists(p): return ""
  readFile(p)

var made: seq[(string, Buf)]       # the tabs of types made: their title, the tab

proc typesTab(name, code: string): string =
  ## the types in a tab of their own — the one made before for that name (its text replaced), unless you have
  ## changed it: then another
  var ids: seq[int]
  for x in buffers(): ids.add x.id
  var title = name & ".nim"
  var n = 2
  var busy = true
  while busy:
    busy = false
    for (t, b) in made:
      if t == title and b.id in ids and b.dirty:
        busy = true
        title = name & " (" & $n & ").nim"
        inc n
        break
  made.add (title, newTab(title, code, "nim"))
  title

proc toNimTypes() =
  let b = current()
  if not b.valid:
    message("JSON → Nim types: open a file first")
    return
  let path = b.path
  let sel = b.selection
  var text, src: string
  var fromSel = false
  var err = ""
  var j: JsonNode = nil
  if not sel.isEmpty:
    text = b.textIn(sel)
    src = "the selection"
    fromSel = true
    j = parsed(text, err)
  else:
    let clip = clipboard()
    var clipErr = ""
    j = parsed(clip, clipErr)
    if j != nil: src = "the clipboard"
    elif path.endsWith(".json") or b.lang == "json":
      src = extractFilename(path)
      j = parsed(b.text, err)
    elif isNimPath(path):
      let f = projectJsonFile()
      if f.len == 0:
        message("JSON → Nim types: select some JSON or copy it first (no .json file was chosen)")
        return
      src = f
      j = parsed(readProjectFile(f), err)
    else:
      message("JSON → Nim types: select some JSON, copy it, or open a .json file first")
      return
  if j == nil:
    warn("JSON → Nim types: " & src & " is not JSON (" & err & ")")
    return
  if j.kind == JObject and j.len == 0:
    warn("JSON → Nim types: " & src & " is an empty object — there is nothing to make a type of")
    return
  var root = setting("rootName", "Root")
  if not isNimName(root): root = "Root"
  if isNimPath(path) and not fromSel:
    let lines = b.lines
    let code = nimTypes(j, root, importsOf(lines))
    let l = b.cursor.line
    if l < lines.len and lines[l].strip.len == 0: b.replace(b.lineRange(l), code.strip(leading = false))
    else: b.insert(pos(l, lines[l].len), "\n" & code.strip(leading = false))
    message("Nim types from " & src & " added at line " & $(l + 1))
  else:
    let t = typesTab(root, nimTypes(j, root))
    message("Nim types from " & src & " are in " & t)

command "JSON → Nim types":
  toNimTypes()

let toolParams = %*{"json": {"type": "string", "description": "the JSON sample"},
                   "name": {"type": "string", "description": "the top-level type's name (\"\": Root)"}}

aiToolReadOnly("json_to_nim", "Nim object types for a sample of JSON (for std/json's `to` and jsony): the Nim code",
               toolParams) do (args: JsonNode) -> string:
  var err = ""
  let j = parsed(args{"json"}.getStr, err)
  if j == nil: raise newException(ValueError, "not JSON: " & err)
  let name = args{"name"}.getStr
  nimTypes(j, (if isNimName(name): name else: setting("rootName", "Root")))
