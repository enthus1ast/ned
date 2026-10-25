## ── ned's own JSON: what is wrong with a file as you type (a missing comma, a comma too many, a key twice, a value
##    a schema does not take), what a key or a value can be and what a key means (from a schema: package.json,
##    tsconfig.json, ned's own settings …), the file's outline and the path of keys to the cursor ──

import std/[strutils, tables, json]
from std/unicode import Rune, `$`    # (only these: all of unicode would make strutils' splitWhitespace ambiguous where
                                     # ned is merged into one file)
import webcommon

type
  JKind* = enum jkObject, jkArray, jkString, jkNumber, jkBool, jkNull, jkBad
  JNode* = ref object            # a value as it is written: where it is, and what is in it
    kind*: JKind
    line*, col*, eline*, ecol*: int
    key*: string                 # (a member of an object: its key, unquoted)
    keyLine*, keyCol*, keyEcol*: int
    text*: string                # (a string, a number, true / false / null: as written)
    kids*: seq[JNode]
  JSchema* = ref object          # what a value may be
    title*: string               # (the root's: the file's name in what is said — package.json)
    desc*: string
    typ*: string                 # object · array · string · number · integer · boolean · "" (anything)
    props*: OrderedTable[string, JSchema]
    items*: JSchema              # (an array: each item's)
    values*: seq[string]         # (one of these, as JSON text: "\"module\"", "true", "4")
    other*: JSchema              # (any other key of an object: dependencies' name → version)
    deprecated*: string
    default*: string
  JDoc* = object
    root*: JNode
    diags*: seq[WebDiag]

# ── reading it ──

type JLex = object
  lines: seq[string]
  l, c: int
  comments: bool                 # (JSONC: // and /* */ allowed)
  diags: seq[WebDiag]

proc jErr(x: var JLex, l, c, e: int, msg: string, sev = 1, rule = "json") =
  for d in x.diags:
    if d.line == l and d.col == c and d.msg == msg: return
  x.diags.add WebDiag(line: l, col: c, eline: l, ecol: max(c + 1, e), sev: sev, msg: msg, rule: rule)

proc jSkip(x: var JLex) =
  ## past spaces, line ends and (in JSONC) comments
  while x.l < x.lines.len:
    let s = x.lines[x.l]
    if x.c >= s.len:
      inc x.l
      x.c = 0
      continue
    let ch = s[x.c]
    if ch in {' ', '\t', '\r'}:
      inc x.c
    elif ch == '/' and x.c + 1 < s.len and s[x.c + 1] in {'/', '*'}:
      if not x.comments: x.jErr(x.l, x.c, x.c + 2, "comments are not allowed in JSON (a .jsonc file takes them)")
      if s[x.c + 1] == '/':
        inc x.l
        x.c = 0
      else:
        var l = x.l
        var k = s.find("*/", x.c + 2)
        while k < 0 and l + 1 < x.lines.len:
          inc l
          k = x.lines[l].find("*/")
        if k < 0:
          x.jErr(x.l, x.c, x.c + 2, "the comment is not closed (*/)")
          x.l = x.lines.len
          return
        x.l = l
        x.c = k + 2
    else: return

proc jPeek(x: JLex): char =
  if x.l < x.lines.len and x.c < x.lines[x.l].len: x.lines[x.l][x.c] else: '\0'

proc jValue(x: var JLex, depth: int): JNode

proc jString(x: var JLex): JNode =
  ## a string at the cursor (its opening quote)
  let s = x.lines[x.l]
  result = JNode(kind: jkString, line: x.l, col: x.c)
  var k = x.c + 1
  var val = ""
  while k < s.len and s[k] != '"':
    if s[k] == '\\':
      if k + 1 < s.len and s[k + 1] in {'"', '\\', '/', 'b', 'f', 'n', 'r', 't', 'u'}:
        if s[k + 1] == 'u':
          var ok = k + 5 < s.len
          for j in k + 2 .. min(k + 5, s.high):
            if s[j] notin HexDigits: ok = false
          if not ok: x.jErr(x.l, k, k + 2, "\\u takes four hex digits")
        val.add s[k .. min(k + 1, s.high)]
        k += 2
        continue
      x.jErr(x.l, k, k + 2, "not an escape JSON has: \\" & (if k + 1 < s.len: $s[k + 1] else: ""))
    elif s[k] == '\t': x.jErr(x.l, k, k + 1, "a tab in a string must be written \\t")
    val.add s[k]
    inc k
  if k >= s.len:
    x.jErr(x.l, x.c, s.len, "the string is not closed: \" before the end of the line")
    result.eline = x.l
    result.ecol = s.len
    result.text = val
    inc x.l
    x.c = 0
    return
  result.text = val
  result.eline = x.l
  result.ecol = k + 1
  x.c = k + 1

proc jScalar(x: var JLex): JNode =
  let s = x.lines[x.l]
  var k = x.c
  while k < s.len and s[k] notin {',', '}', ']', ':', ' ', '\t', '\r', '/', '"', '{', '['}: inc k
  let w = s[x.c ..< k]
  result = JNode(line: x.l, col: x.c, eline: x.l, ecol: k, text: w)
  case w
  of "true", "false": result.kind = jkBool
  of "null": result.kind = jkNull
  else:
    var ok = w.len > 0
    var j = 0
    if j < w.len and w[j] == '-': inc j
    if j >= w.len or w[j] notin Digits: ok = false
    elif w[j] == '0' and j + 1 < w.len and w[j + 1] in Digits: ok = false        # (a leading zero)
    while ok and j < w.len and w[j] in Digits: inc j
    if ok and j < w.len and w[j] == '.':
      inc j
      if j >= w.len or w[j] notin Digits: ok = false
      while ok and j < w.len and w[j] in Digits: inc j
    if ok and j < w.len and w[j] in {'e', 'E'}:
      inc j
      if j < w.len and w[j] in {'+', '-'}: inc j
      if j >= w.len or w[j] notin Digits: ok = false
      while ok and j < w.len and w[j] in Digits: inc j
    if ok and j == w.len: result.kind = jkNumber
    else:
      result.kind = jkBad
      let hint = if w in ["True", "False", "TRUE", "FALSE"]: " (JSON writes true and false in small letters)"
                 elif w in ["None", "nil", "NULL", "undefined", "Null"]: " (JSON writes null)"
                 elif w.len > 0 and w[0] == '\'': " (JSON's strings take \", not ')"
                 elif w.len > 0 and (w[0].isAlphaAscii or w[0] == '_'): " (a key or a string needs its \"…\")"
                 else: ""
      x.jErr(x.l, x.c, k, (if w.len == 0: "a value is missing here" else: "not a JSON value: " & w) & hint)
  x.c = max(k, x.c + 1)

proc jValue(x: var JLex, depth: int): JNode =
  x.jSkip()
  if x.l >= x.lines.len:
    let l = max(0, x.lines.high)
    x.jErr(l, x.lines[l].len, x.lines[l].len + 1, "a value is missing at the end of the file")
    return JNode(kind: jkBad, line: l, col: x.lines[l].len, eline: l, ecol: x.lines[l].len)
  if depth > 200:
    x.jErr(x.l, x.c, x.c + 1, "nested too deep")
    x.l = x.lines.len
    return JNode(kind: jkBad)
  let ch = x.jPeek()
  case ch
  of '"': return x.jString()
  of '{', '[':
    let obj = ch == '{'
    let close = if obj: '}' else: ']'
    result = JNode(kind: (if obj: jkObject else: jkArray), line: x.l, col: x.c)
    inc x.c
    var seen: Table[string, (int, int)]
    var first = true
    while true:
      x.jSkip()
      if x.l >= x.lines.len:
        x.jErr(result.line, result.col, result.col + 1, "the " & (if obj: "{" else: "[") & " is not closed (" & $close & ")")
        result.eline = max(0, x.lines.high)
        result.ecol = if x.lines.len > 0: x.lines[^1].len else: 0
        return
      var c = x.jPeek()
      if c == close:
        result.eline = x.l
        result.ecol = x.c + 1
        inc x.c
        return
      if not first:
        if c == ',':
          let (cl, cc) = (x.l, x.c)
          inc x.c
          x.jSkip()
          if x.jPeek() == close:
            # (JSONC — tsconfig.json, VS Code's settings, ned's own — takes one)
            if not x.comments: x.jErr(cl, cc, cc + 1, "a comma before the " & $close & " — JSON takes none there")
            continue
          c = x.jPeek()
        else:
          # (a comma is missing: said where the value before it ends)
          if result.kids.len > 0:
            let prev = result.kids[^1]
            x.jErr(prev.eline, prev.ecol, prev.ecol + 1, "a comma is missing after this " &
                   (if obj: "member" else: "item"))
          if c notin {'"', '{', '[', '-', '0'..'9', 't', 'f', 'n'}:
            # (something no value starts with: skipped, so the reading goes on)
            inc x.c
            continue
      first = false
      if obj:
        if c != '"':
          if c == '\'' or c.isAlphaAscii or c == '_':
            # an unquoted key (or one in ' '): read as one, said so
            let s = x.lines[x.l]
            var k = x.c + (if c == '\'': 1 else: 0)
            while k < s.len and s[k] notin {':', ' ', '\'', ',', '}'}: inc k
            let key = s[x.c + (if c == '\'': 1 else: 0) ..< k]
            x.jErr(x.l, x.c, k + (if c == '\'': 1 else: 0), "a key needs \"…\": \"" & key & "\"")
            let kn = JNode(kind: jkString, line: x.l, col: x.c, eline: x.l, ecol: k, text: key)
            x.c = k + (if c == '\'' and k < s.len and s[k] == '\'': 1 else: 0)
            var m = JNode(kind: jkBad, key: key, keyLine: kn.line, keyCol: kn.col, keyEcol: kn.ecol)
            x.jSkip()
            if x.jPeek() == ':':
              inc x.c
              let v = x.jValue(depth + 1)
              v.key = key
              v.keyLine = kn.line
              v.keyCol = kn.col
              v.keyEcol = kn.ecol
              m = v
            result.kids.add m
            continue
          x.jErr(x.l, x.c, x.c + 1, "a key (\"…\") is expected here")
          inc x.c
          continue
        let k = x.jString()
        x.jSkip()
        if x.jPeek() != ':':
          x.jErr(k.eline, k.ecol, k.ecol + 1, "a : is missing after the key")
          let m = JNode(kind: jkBad, key: k.text, keyLine: k.line, keyCol: k.col, keyEcol: k.ecol, line: k.eline,
                        col: k.ecol, eline: k.eline, ecol: k.ecol)
          result.kids.add m
          continue
        inc x.c
        let v = x.jValue(depth + 1)
        v.key = k.text
        v.keyLine = k.line
        v.keyCol = k.col
        v.keyEcol = k.ecol
        if k.text in seen:
          x.jErr(k.line, k.col, k.ecol, "the key \"" & k.text & "\" is here twice (line " & $(seen[k.text][0] + 1) &
                 " has it too): the last one counts", 2, "json-duplicate-key")
        else: seen[k.text] = (k.line, k.col)
        result.kids.add v
      else:
        result.kids.add x.jValue(depth + 1)
  of '}', ']':
    x.jErr(x.l, x.c, x.c + 1, "a value is missing before this " & $ch)
    return JNode(kind: jkBad, line: x.l, col: x.c, eline: x.l, ecol: x.c)
  of ',':
    x.jErr(x.l, x.c, x.c + 1, "a value is missing before this comma")
    return JNode(kind: jkBad, line: x.l, col: x.c, eline: x.l, ecol: x.c)
  else: return x.jScalar()

proc jsonRead*(lines: openArray[string], comments = false): JDoc =
  ## the document, read as far as it goes, and what is wrong with it
  var x = JLex(lines: @lines, comments: comments)
  x.jSkip()
  if x.l >= x.lines.len: return             # (an empty file: nothing to say)
  result.root = x.jValue(0)
  x.jSkip()
  if x.l < x.lines.len:
    x.jErr(x.l, x.c, x.lines[x.l].len, "more after the end of the document (one value per file)")
  result.diags = x.diags

# ── the schemas ──

proc jSch(typ: string, desc = "", values: seq[string] = @[]): JSchema =
  JSchema(typ: typ, desc: desc, values: values)

proc jObj(desc: string, props: openArray[(string, JSchema)], other: JSchema = nil): JSchema =
  result = JSchema(typ: "object", desc: desc, other: other)
  for (k, v) in props: result.props[k] = v

proc jArr(desc: string, items: JSchema): JSchema = JSchema(typ: "array", desc: desc, items: items)

proc packageJsonSchema(): JSchema =
  let deps = jObj("", [], jSch("string", "the version range wanted: ^1.2.3, ~1.2, >=2, a git URL or a path"))
  let person = jSch("", "a name — \"Ada <ada@example.com> (https://ada.dev)\" — or {\"name\", \"email\", \"url\"}")
  jObj("package.json — an npm package", [
    ("name", jSch("string", "the package's name: lower case, no spaces; @scope/name for a scoped one")),
    ("version", jSch("string", "the version, as semver: 1.2.3")),
    ("description", jSch("string", "what it is, in a sentence (npm search shows it)")),
    ("keywords", jArr("words npm search finds it by", jSch("string"))),
    ("homepage", jSch("string", "its web page")),
    ("bugs", jSch("", "where to report problems: a URL, or {\"url\", \"email\"}")),
    ("license", jSch("string", "its licence, as an SPDX name: MIT, ISC, Apache-2.0 …")),
    ("author", person),
    ("contributors", jArr("the people who helped", person)),
    ("funding", jSch("", "where to support it")),
    ("files", jArr("the files the published package has (globs)", jSch("string"))),
    ("main", jSch("string", "the module require() loads: index.js")),
    ("module", jSch("string", "the ES module entry, for bundlers")),
    ("browser", jSch("", "the entry for browsers, or replacements of modules there")),
    ("exports", jSch("", "what the package exports, by path and condition (import, require, types …)")),
    ("imports", jSch("object", "private import maps: #name → path")),
    ("type", jSch("string", "how .js files are read: module (ES modules) or commonjs (the default)",
               @["\"module\"", "\"commonjs\""])),
    ("types", jSch("string", "its TypeScript declarations: index.d.ts")),
    ("typings", jSch("string", "the same as types")),
    ("bin", jSch("", "the commands it installs: a path, or {name: path}")),
    ("man", jSch("", "its man pages")),
    ("directories", jSch("object", "where its parts are")),
    ("repository", jSch("", "where its source is: \"github:user/repo\" or {\"type\": \"git\", \"url\": …}")),
    ("scripts", jObj("the commands of npm run <name> (start, test, build …)", [
      ("start", jSch("string", "npm start")), ("test", jSch("string", "npm test")),
      ("build", jSch("string", "npm run build")), ("dev", jSch("string", "npm run dev")),
      ("lint", jSch("string", "npm run lint")), ("prepare", jSch("string", "after install, before publish")),
      ("prepublishOnly", jSch("string", "before npm publish")), ("postinstall", jSch("string", "after install"))],
      jSch("string", "a command: npm run <its name>"))),
    ("config", jSch("object", "values its scripts read (npm_package_config_*)")),
    ("dependencies", deps), ("devDependencies", deps), ("peerDependencies", deps),
    ("optionalDependencies", deps), ("bundleDependencies", jArr("the dependencies published inside it", jSch("string"))),
    ("overrides", jSch("object", "versions forced on the dependencies' dependencies")),
    ("engines", jObj("the versions it runs on", [("node", jSch("string", "the Node versions: >=18")),
                                                 ("npm", jSch("string", "the npm versions"))], jSch("string"))),
    ("os", jArr("the systems it installs on (!win32: not Windows)", jSch("string"))),
    ("cpu", jArr("the processors it installs on", jSch("string"))),
    ("private", jSch("boolean", "true: npm refuses to publish it", @["true", "false"])),
    ("publishConfig", jSch("object", "settings for npm publish (registry, access, tag)")),
    ("workspaces", jArr("the folders of a monorepo's packages (globs)", jSch("string"))),
    ("packageManager", jSch("string", "the package manager and its version: pnpm@9.1.0")),
    ("sideEffects", jSch("", "false: every module may be left out by a bundler when unused"))])

proc tsconfigSchema(): JSchema =
  let target = @["\"es5\"", "\"es2015\"", "\"es2016\"", "\"es2017\"", "\"es2018\"", "\"es2019\"", "\"es2020\"",
                 "\"es2021\"", "\"es2022\"", "\"es2023\"", "\"esnext\""]
  let modules = @["\"commonjs\"", "\"es2015\"", "\"es2020\"", "\"es2022\"", "\"esnext\"", "\"node16\"", "\"nodenext\"",
                  "\"preserve\"", "\"amd\"", "\"umd\"", "\"system\"", "\"none\""]
  let b = proc(d: string): JSchema = jSch("boolean", d, @["true", "false"])
  let co = jObj("how TypeScript checks and compiles", [
    ("target", jSch("string", "the JavaScript version it writes", target)),
    ("module", jSch("string", "the module system it writes", modules)),
    ("moduleResolution", jSch("string", "how imports are found",
                            @["\"node10\"", "\"node16\"", "\"nodenext\"", "\"bundler\"", "\"classic\""])),
    ("lib", jArr("the built-in declarations it knows: dom, es2022 …", jSch("string"))),
    ("jsx", jSch("string", "what JSX becomes", @["\"preserve\"", "\"react\"", "\"react-jsx\"", "\"react-jsxdev\"",
                                               "\"react-native\""])),
    ("strict", b("every strict check on: noImplicitAny, strictNullChecks …")),
    ("noImplicitAny", b("an error for a value whose type would be any")),
    ("strictNullChecks", b("null and undefined are types of their own")),
    ("noUnusedLocals", b("an error for a local nothing uses")),
    ("noUnusedParameters", b("an error for a parameter nothing uses")),
    ("noImplicitReturns", b("every path of a function returns")),
    ("noFallthroughCasesInSwitch", b("a case that runs into the next is an error")),
    ("noUncheckedIndexedAccess", b("an index may be undefined")),
    ("esModuleInterop", b("import a CommonJS module's default as ES modules do")),
    ("allowSyntheticDefaultImports", b("import x from \"m\" for a module without a default")),
    ("skipLibCheck", b("the .d.ts files are not checked (faster)")),
    ("forceConsistentCasingInFileNames", b("an import's case must be the file's")),
    ("resolveJsonModule", b("import a .json file")),
    ("isolatedModules", b("each file can be compiled on its own (esbuild, Babel)")),
    ("allowJs", b("JavaScript files take part")), ("checkJs", b("JavaScript files are checked too")),
    ("declaration", b("write .d.ts files")), ("declarationMap", b("and maps for them")),
    ("sourceMap", b("write .js.map files")), ("noEmit", b("check only: write nothing")),
    ("emitDeclarationOnly", b("write only .d.ts files")), ("composite", b("a project others reference")),
    ("incremental", b("keep what it learned between builds")),
    ("outDir", jSch("string", "where the .js files go")), ("rootDir", jSch("string", "the root of the sources")),
    ("outFile", jSch("string", "one file for everything (amd, system)")),
    ("baseUrl", jSch("string", "where bare imports are looked for")),
    ("paths", jSch("object", "import paths mapped to folders: {\"@/*\": [\"src/*\"]}")),
    ("types", jArr("the @types packages included (all when not given)", jSch("string"))),
    ("typeRoots", jArr("where the @types folders are", jSch("string"))),
    ("experimentalDecorators", b("the old decorators")), ("emitDecoratorMetadata", b("their metadata")),
    ("useDefineForClassFields", b("class fields as the standard defines them")),
    ("verbatimModuleSyntax", b("imports and exports written as they are")),
    ("allowImportingTsExtensions", b("import \"./x.ts\" (with noEmit)"))])
  jObj("tsconfig.json — a TypeScript project", [
    ("compilerOptions", co),
    ("include", jArr("the files it has (globs): [\"src\"]", jSch("string"))),
    ("exclude", jArr("the files it leaves out (globs)", jSch("string"))),
    ("files", jArr("the files it has, by name", jSch("string"))),
    ("extends", jSch("", "the configuration this one builds on: a path, or several")),
    ("references", jArr("the projects it builds on: [{\"path\": \"../core\"}]",
                       jObj("", [("path", jSch("string", "the project's folder"))]))),
    ("compileOnSave", jSch("boolean", "editors build on save", @["true", "false"]))])

proc atlasConfigSchema(): JSchema =
  let pat = jObj("", [], jSch("string"))
  jObj("atlas.config — the packages of an Atlas project", [
    ("deps", jSch("string", "the folder the dependencies are cloned into (vendor, deps …)")),
    ("nameOverrides", jObj("package names mapped to URLs: \"name\": \"https://github.com/me/fork\" ($1 for a * in the name)",
                          [], jSch("string", "the URL that name means"))),
    ("urlOverrides", jObj("URLs mapped to other URLs: a fork, a mirror (patterns: *, $1)", [],
                         jSch("string", "the URL used instead"))),
    ("pkgOverrides", jObj("a package replaced by another one's URL", [], jSch("string", "its URL"))),
    ("plugins", jSch("string", "a folder of .nims files that teach Atlas more (its own build steps)")),
    ("resolver", jSch("string", "which version of each dependency is taken: SemVer (the newest the ranges allow, " &
                     "the default), MinVer (the oldest they allow), MaxVer (the newest of all)",
                     @["\"SemVer\"", "\"MinVer\"", "\"MaxVer\""])),
    ("graph", jSch("", "(written by Atlas)"))])

proc atlasLockSchema(): JSchema =
  jObj("atlas.lock — the exact commit of each dependency (atlas pin writes it, atlas replay uses it)", [
    ("items", jObj("each dependency: where it is and which commit", [],
                  jObj("", [("dir", jSch("string", "where it is cloned")), ("url", jSch("string", "its repository")),
                           ("commit", jSch("string", "the commit it is pinned to")),
                           ("version", jSch("string", "its version at that commit"))]))),
    ("nimcfg", jArr("the nim.cfg lines Atlas wrote (--path: …)", jSch("string"))),
    ("nimbleFile", jObj("the project's .nimble when it was pinned", [("filename", jSch("string")),
                                                                    ("content", jArr("", jSch("string")))])),
    ("hostOS", jSch("string", "the system it was pinned on")), ("hostCPU", jSch("string", "the processor")),
    ("nimVersion", jSch("string", "the Nim it was pinned with")),
    ("gccVersion", jSch("string")), ("clangVersion", jSch("string"))])

proc nimbleLockSchema(): JSchema =
  jObj("nimble.lock — the exact version of each dependency (nimble lock writes it)", [
    ("version", jSch("integer", "the lock file's format")),
    ("packages", jObj("each package and what it was locked to", [],
                     jObj("", [("version", jSch("string")), ("vcsRevision", jSch("string", "the commit")),
                              ("url", jSch("string")), ("downloadMethod", jSch("string", "", @["\"git\"", "\"hg\""])),
                              ("dependencies", jArr("the packages it needs", jSch("string"))),
                              ("checksums", jObj("", [("sha1", jSch("string"))], jSch("string")))])))])

proc jsonSchemaFor*(path: string): JSchema =
  ## the schema ned knows for a file, by its name (nil: none)
  let name = path.replace('\\', '/').split('/')[^1].toLowerAscii
  if name == "package.json": result = packageJsonSchema()
  elif name in ["tsconfig.json", "jsconfig.json"] or (name.startsWith("tsconfig.") and name.endsWith(".json")):
    result = tsconfigSchema()
  elif name == "atlas.config" or name == "atlas.workspace": result = atlasConfigSchema()
  elif name == "atlas.lock": result = atlasLockSchema()
  elif name == "nimble.lock": result = nimbleLockSchema()
  if result != nil and result.title.len == 0: result.title = name

func jsonComments*(path: string): bool =
  ## does this file take comments (JSONC: .jsonc, tsconfig, VS Code's settings, ned's own)?
  let p = path.replace('\\', '/').toLowerAscii
  let name = p.split('/')[^1]
  p.endsWith(".jsonc") or p.endsWith(".json5") or name.startsWith("tsconfig") or name.startsWith("jsconfig") or
    "/.vscode/" in p or "/.ned/" in p or p.endsWith("/ned/config.json") or name in [".eslintrc.json", "devcontainer.json"]

# ── where the cursor is ──

proc jPathTo*(root: JNode, line, col: int): seq[JNode] =
  ## the values that hold the position, outermost first
  var n = root
  while n != nil:
    let inside = (line > n.line or (line == n.line and col >= n.col)) and
                 (line < n.eline or (line == n.eline and col <= n.ecol))
    let onKey = n.key.len > 0 and line == n.keyLine and col >= n.keyCol and col <= n.keyEcol
    if not inside and not onKey: break
    result.add n
    var next: JNode = nil
    for k in n.kids:
      if (line > k.line or (line == k.line and col >= k.col)) and (line < k.eline or (line == k.eline and col <= k.ecol)):
        next = k
      elif k.key.len > 0 and line == k.keyLine and col >= k.keyCol and col <= k.keyEcol: next = k
    n = next

proc jSchemaAt(schema: JSchema, path: seq[JNode]): JSchema =
  ## the schema of the last value of a path (from the root's)
  var s = schema
  for i in 1 ..< path.len:
    if s == nil: return nil
    let n = path[i]
    if path[i - 1].kind == jkArray: s = s.items
    elif n.key in s.props: s = s.props[n.key]
    else: s = s.other
  s

func jKeyPath*(path: seq[JNode]): string =
  ## "compilerOptions.paths" — the keys down to the cursor (an item's place: [2])
  for i in 1 ..< path.len:
    if path[i - 1].kind == jkArray:
      result.add "[" & $path[i - 1].kids.find(path[i]) & "]"
    else:
      if result.len > 0: result.add "."
      result.add path[i].key

# ── checks ──

func jTypeOk(s: JSchema, n: JNode): bool =
  case s.typ
  of "object": n.kind == jkObject
  of "array": n.kind == jkArray
  of "string": n.kind == jkString
  of "number": n.kind == jkNumber
  of "integer": n.kind == jkNumber and '.' notin n.text and 'e' notin n.text.toLowerAscii
  of "boolean": n.kind == jkBool
  else: true

func jWord(t: string): string =
  case t
  of "object": "an object {…}"
  of "array": "a list […]"
  of "string": "a string \"…\""
  of "number": "a number"
  of "integer": "a whole number"
  of "boolean": "true or false"
  else: "a value"

func jText(n: JNode): string =
  case n.kind
  of jkString: "\"" & n.text & "\""
  else: n.text

proc jCheck(n: JNode, s: JSchema, out0: var seq[WebDiag], what, place: string) =
  if s == nil or n == nil or n.kind == jkBad: return
  if s.deprecated.len > 0 and n.key.len > 0:
    out0.add WebDiag(line: n.keyLine, col: n.keyCol, eline: n.keyLine, ecol: n.keyEcol, sev: 2,
                     msg: "\"" & n.key & "\" is deprecated: " & s.deprecated, rule: "json-schema")
  if not jTypeOk(s, n):
    out0.add WebDiag(line: n.line, col: n.col, eline: n.eline, ecol: n.ecol, sev: 2, rule: "json-schema",
                     msg: (if n.key.len > 0: "\"" & n.key & "\"" else: "this") & " takes " & jWord(s.typ))
    return
  if s.values.len > 0 and n.kind in {jkString, jkNumber, jkBool, jkNull} and jText(n) notin s.values:
    var near = ""
    if n.kind == jkString:
      var names: seq[string]
      for v in s.values: names.add v.strip(chars = {'"'})
      near = closest(n.text, names)
    let shown = if s.values.len > 8: s.values[0 ..< 8].join(", ") & " …" else: s.values.join(", ")
    out0.add WebDiag(line: n.line, col: n.col, eline: n.eline, ecol: n.ecol, sev: 2, rule: "json-schema",
                     msg: (if near.len > 0: "\"" & near & "\"? " else: "") & "not one of " & shown)
  if n.kind == jkObject:
    for k in n.kids:
      let at = if place.len > 0: place & "." & k.key else: k.key
      if k.key in s.props: jCheck(k, s.props[k.key], out0, what, at)
      elif s.other != nil: jCheck(k, s.other, out0, what, at)
      elif s.props.len > 0:
        var names: seq[string]
        for p in s.props.keys: names.add p
        let near = closest(k.key, names)
        out0.add WebDiag(line: k.keyLine, col: k.keyCol, eline: k.keyLine, ecol: k.keyEcol, sev: 2,
                         rule: "json-unknown-key",
                         msg: "\"" & k.key & "\" is not a key of " & (if place.len > 0: place & " (" & what & ")" else: what) &
                              (if near.len > 0: " — \"" & near & "\"?" else: ""))
  elif n.kind == jkArray and s.items != nil:
    for i, k in n.kids: jCheck(k, s.items, out0, what, place & "[" & $i & "]")

proc jsonChecks*(lines: openArray[string], schema: JSchema = nil, comments = false): seq[WebDiag] =
  ## what is wrong: the JSON itself, then what the schema says of its keys and values
  let d = jsonRead(lines, comments)
  result = d.diags
  if schema != nil and d.root != nil:
    var errAt: seq[int]
    for x in d.diags:
      if x.sev == 1: errAt.add x.line
    var more: seq[WebDiag]
    jCheck(d.root, schema, more, (if schema.title.len > 0: schema.title else: "the file"), "")
    for m in more:
      if m.line notin errAt: result.add m        # (the JSON's own mistake first, where there is one)
  sortDiags(result)

func jUnescape*(t: string): string =
  ## a string's text as written (\n, \", \u00e9 …) → what it says
  var i = 0
  while i < t.len:
    if t[i] == '\\' and i + 1 < t.len:
      case t[i + 1]
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of 'b': result.add '\b'
      of 'f': result.add '\f'
      of 'u':
        var code = 0
        var ok = i + 5 < t.len
        if ok:
          for j in i + 2 .. i + 5:
            if t[j] in HexDigits: code = code * 16 + parseHexInt($t[j]) else: ok = false
        if ok:
          result.add $Rune(code)
          i += 6
          continue
        result.add "\\u"
      else: result.add t[i + 1]
      i += 2
    else:
      result.add t[i]
      inc i

proc jsonToNode*(n: JNode): JsonNode =
  ## the value as std/json has it (nil: a value not read)
  if n == nil: return nil
  case n.kind
  of jkObject:
    result = newJObject()
    for k in n.kids:
      let v = jsonToNode(k)
      if v != nil: result[k.key] = v
  of jkArray:
    result = newJArray()
    for k in n.kids:
      let v = jsonToNode(k)
      if v != nil: result.add v
  of jkString: result = %jUnescape(n.text)
  of jkNumber:
    try: result = (if '.' in n.text or 'e' in n.text.toLowerAscii: %parseFloat(n.text) else: %parseBiggestInt(n.text))
    except ValueError: result = %parseFloat(n.text)
  of jkBool: result = %(n.text == "true")
  of jkNull: result = newJNull()
  of jkBad: result = nil

# ── completion and hover ──

proc jMemberAt(n: JNode, line, col: int): bool =
  ## is the position where a key goes: inside the object, not inside one of its values
  if n.kind != jkObject: return false
  for k in n.kids:
    if k.kind != jkBad and (line > k.line or (line == k.line and col > k.col)) and
       (line < k.eline or (line == k.eline and col < k.ecol)): return false
    if k.key.len > 0 and line == k.keyLine and col > k.keyCol and col <= k.keyEcol: return true
  true

proc jsonComplete*(lines: openArray[string], line, col: int, schema: JSchema, comments = false): (int, seq[WebItem]) =
  ## (where the word starts, what fits there): the keys the object can have (not those it has), or the values
  ## its key takes
  if schema == nil or line >= lines.len: return (col, @[])
  let d = jsonRead(lines, comments)
  if d.root == nil:
    var items: seq[WebItem]
    items.add WebItem(label: "{}", insert: "{\n  $0\n}", snippet: "{\n  $0\n}", detail: schema.desc, kind: KStruct)
    return (col, items)
  let s = lines[line]
  # the word: from a quote (or the line's last space) to the cursor
  var a = col
  while a > 0 and s[a - 1] notin {'"', ' ', '\t', ',', '{', '[', ':'}: dec a
  let quoted = a > 0 and s[a - 1] == '"'
  let closed = quoted and col < s.len and s[col] == '"'     # (the closing quote is there: what is typed goes inside)
  let start = a
  let path = jPathTo(d.root, line, max(0, if quoted: a - 1 else: a))
  if path.len == 0: return (start, @[])
  let last = path[^1]
  # a key: in an object, before its member's ':'
  let colon = s.find(':', col)
  let beforeColon = s[0 ..< min(col, s.len)].rfind(':') < start
  var objNode: JNode = nil
  if last.kind == jkObject and jMemberAt(last, line, col): objNode = last
  elif last.kind == jkString and last.key.len > 0 and line == last.keyLine and col <= last.keyEcol and path.len >= 2:
    objNode = path[^2]
  elif last.kind == jkBad and last.key.len > 0 and path.len >= 2 and beforeColon: objNode = path[^2]
  var items: seq[WebItem]
  if objNode != nil:
    let os = jSchemaAt(schema, path[0 .. path.find(objNode)])
    if os == nil: return (start, @[])
    var have: seq[string]
    for k in objNode.kids:
      if not (k.key.len > 0 and line == k.keyLine and col >= k.keyCol and col <= k.keyEcol): have.add k.key
    let needColon = colon < 0 or s[col ..< colon].strip(chars = {' ', '"'}).len > 0
    for k, ps in os.props:
      if k in have: continue
      # (as much of `"key": value` as is not written yet)
      let ins = if closed: k elif quoted: k & "\"" else: "\"" & k & "\""
      var sn = ""
      if needColon and not closed:
        let v = case ps.typ
                of "object": "{$0}"
                of "array": "[$0]"
                of "string": "\"$0\""
                of "boolean": "${1|true,false|}"
                else: "$0"
        sn = ins & ": " & v
      items.add WebItem(label: k, insert: ins, snippet: sn, detail: (if ps.typ.len > 0: ps.typ else: ""),
                        doc: ps.desc, kind: KProp)
    return (start, items)
  # a value: the one the key before the cursor takes
  var vs: JSchema = nil
  if last.key.len > 0 or (path.len >= 2 and path[^2].kind == jkArray):
    vs = jSchemaAt(schema, path)
  if vs == nil and colon < 0:
    # (the value not typed yet: "key": | — the member the line names)
    for n in countdown(path.high, 0):
      if path[n].kind == jkObject:
        let os = jSchemaAt(schema, path[0 .. n])
        let m = s[0 ..< min(col, s.len)].strip.strip(trailing = false, chars = {'"'})
        let ke = m.find('"')
        if os != nil and ke > 0 and m[0 ..< ke] in os.props: vs = os.props[m[0 ..< ke]]
        break
  if vs == nil: return (start, @[])
  var values = vs.values
  if values.len == 0 and vs.typ == "boolean": values = @["true", "false"]
  for v in values:
    let isStr = v.startsWith("\"")
    if quoted and not isStr: continue            # (inside "…": only strings)
    let bare = v.strip(chars = {'"'})
    let ins = if not quoted: v elif closed: bare else: bare & "\""
    items.add WebItem(label: bare, insert: ins, detail: (if vs.typ.len > 0: vs.typ else: ""), doc: vs.desc,
                      kind: KValue)
  (start, items)

proc jsonHover*(lines: openArray[string], line, col: int, schema: JSchema, comments = false): string =
  ## a key's meaning (its schema's words, the values it takes), and where it is: compilerOptions.strict
  let d = jsonRead(lines, comments)
  if d.root == nil: return
  let path = jPathTo(d.root, line, col)
  if path.len < 2: return
  let n = path[^1]
  let onKey = n.key.len > 0 and line == n.keyLine and col >= n.keyCol and col <= n.keyEcol
  if not onKey and n.kind notin {jkString, jkNumber, jkBool, jkNull}: return
  let kp = jKeyPath(path)
  var md = "`" & kp & "`"
  if schema != nil:
    let s = jSchemaAt(schema, path)
    if s != nil:
      if s.typ.len > 0: md.add " · " & s.typ
      if s.desc.len > 0: md.add "\n\n" & s.desc
      if s.values.len > 0: md.add "\n\none of: " & s.values.join(", ")
      if s.default.len > 0: md.add "\n\ndefault: `" & s.default & "`"
      if s.deprecated.len > 0: md.add "\n\n**deprecated**: " & s.deprecated
  md

# ── the outline ──

type JOutlineItem* = object
  name*, detail*: string
  line*, col*, eline*, ecol*, depth*: int
  kind*: JKind

proc jOutline(n: JNode, depth: int, out0: var seq[JOutlineItem]) =
  for i, k in n.kids:
    let name = if n.kind == jkArray: "[" & $i & "]" else: k.key
    let detail = case k.kind
                 of jkObject: "{" & $k.kids.len & "}"
                 of jkArray: "[" & $k.kids.len & "]"
                 of jkString: "\"" & (if k.text.len > 40: k.text[0 ..< 40] & "…" else: k.text) & "\""
                 else: k.text
    let (l, c) = if k.key.len > 0: (k.keyLine, k.keyCol) else: (k.line, k.col)
    out0.add JOutlineItem(name: name, detail: detail, line: l, col: c, eline: k.eline, ecol: k.ecol, depth: depth,
                          kind: k.kind)
    if k.kind in {jkObject, jkArray} and depth < 12 and (k.kind == jkObject or k.kids.len <= 50):
      jOutline(k, depth + 1, out0)

proc jsonOutline*(lines: openArray[string], comments = true): seq[JOutlineItem] =
  ## each key (and the items of short lists), nested as in the file
  let d = jsonRead(lines, comments)
  if d.root != nil and d.root.kind in {jkObject, jkArray}: jOutline(d.root, 0, result)

proc jsonPathPartsAt*(lines: openArray[string], line, col: int): seq[(string, int)] =
  ## the keys (and items: [2]) down to the position, each with its line
  let d = jsonRead(lines, true)
  if d.root == nil: return
  let path = jPathTo(d.root, line, col)
  for i in 1 ..< path.len:
    if path[i - 1].kind == jkArray: result.add ("[" & $path[i - 1].kids.find(path[i]) & "]", path[i].line)
    else: result.add (path[i].key, path[i].keyLine)

proc jsonPathAt*(lines: openArray[string], line, col: int): string =
  ## the keys down to the position: scripts.build
  let d = jsonRead(lines, true)
  if d.root == nil: return
  jKeyPath(jPathTo(d.root, line, col))
