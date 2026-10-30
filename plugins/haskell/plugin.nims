## haskell — Haskell: colours, comments, indentation, F5, snippets, an outline; HLS and ormolu or fourmolu
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Haskell's `.hs` files: their colours (ned's generic
## lexer with Haskell's words: Capitalised names as types and constructors, `foldl'` and `x'` as names, 'c'
## characters, the Prelude's functions), `--` and `{- -}` comments (one inside another too; a pragma, `{-# … #-}`,
## in their colour; Haddock's `{-| … -}` in the documentation's), indentation after `where`, `do`, `of`, `let`, `=`
## and `->` (two spaces, as ormolu writes), brackets and quotes that close themselves, snippets (module, main,
## data, instance, case) and F5: `stack run` in a Stack project (stack.yaml above the file), `cabal run` in a Cabal
## one (a .cabal file or cabal.project), `runghc file` for a file of its own. Build (Alt+B) is `stack build`,
## `cabal build` or `ghc file` the same way, and `ghc -fno-code` checks a file of its own.
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the file's module, types, classes and
## instances (their methods under them), and top-level functions with their type signatures, from a simple scan.
##
## The tools, when they are on PATH — GHC itself: Termux `pkg install ghc cabal-install`; elsewhere GHCup,
## https://www.haskell.org/ghcup/
## - the Haskell Language Server: `haskell-language-server-wrapper --lsp` (it picks the server built for the
##   project's GHC), or `haskell-language-server --lsp` — `ghcup install hls`; Termux has no package for it
## - a formatter, the first installed: ormolu, or fourmolu (ormolu with settings, its fourmolu.yaml) —
##   `cabal install ormolu` (or fourmolu), or your system's package; each reads the text on its stdin and the
##   project's .cabal file for its language extensions
##
## Settings (the Plugins dock › haskell › its settings; Plugins: reload after a change):
## - plugins.haskell.server — the language server's command, when it is neither of those ("off": none)
## - plugins.haskell.formatter — the formatter's command (the text on its stdin), when it is neither of those
##   ("off": none) — `fourmolu --stdin-input-file "$file"` to have fourmolu when ormolu is installed too
import nedplugin

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for haskell-language-server-wrapper --lsp (or " &
           "haskell-language-server --lsp) when it is installed, \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for ormolu (or " &
           "fourmolu) when it is installed, \"off\" for none. Plugins: reload after a change")

language("haskell", LangSpec(
  name: "Haskell",
  extensions: @["hs"],
  lineComment: "--",
  blockComment: @["{-", "-}"],
  docBlockComment: @["{-|", "-}"],
  nestedComments: true,
  # (no `-- |` as the documentation's line: a new line would go on with another `-- |`, a second comment for the
  # same declaration — Haddock's lines after the first are plain `--`)
  quotes: "\"'",
  charLiterals: true,
  nameChars: "'",
  capitalTypes: true,
  keywords: @["case", "class", "data", "default", "deriving", "do", "else", "foreign", "if", "import", "in", "infix",
              "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then", "type", "where",
              "qualified", "hiding", "forall"],
  constants: @["True", "False", "otherwise"],      # (other constructors, Just and Nothing among them, as types)
  builtins: @["map", "filter", "foldr", "foldl", "foldMap", "putStrLn", "putStr", "print", "show", "read",
              "return", "pure", "fmap", "mapM", "mapM_", "forM", "forM_", "sequence", "sequence_", "traverse",
              "concat", "concatMap", "zip", "zip3", "zipWith", "unzip", "length", "head", "tail", "init", "last",
              "null", "elem", "notElem", "error", "undefined", "id", "const", "flip", "not", "fst", "snd",
              "lookup", "replicate", "take", "drop", "takeWhile", "dropWhile", "span", "reverse", "sum",
              "product", "maximum", "minimum", "any", "all", "iterate", "repeat", "cycle", "lines", "unlines",
              "words", "unwords", "getLine", "getContents", "readFile", "writeFile", "appendFile", "interact",
              "when", "unless", "seq", "succ", "pred", "fromIntegral", "toInteger", "realToFrac", "div", "mod",
              "quot", "rem", "abs", "signum", "negate", "even", "odd", "max", "min", "compare", "curry",
              "uncurry", "maybe", "either", "mempty", "mappend", "mconcat"],
  classWords: @["module", "data", "newtype", "class", "type", "instance"],
  indentAfter: @["where", "do", "of", "let", "=", "->", "(", "[", "{"],
  dedent: "})]",
  indentSize: 2,
  # (the project above the file: Stack's, Cabal's — else the file on its own)
  run: "sh -c 'd=$PWD; while [ \"$PWD\" != / ]; do if [ -f stack.yaml ]; then exec stack run; fi; " &
       "for c in *.cabal cabal.project; do if [ -f \"$c\" ]; then exec cabal run; fi; done; cd ..; done; " &
       "cd \"$d\"; exec runghc \"$file\"'",
  build: "sh -c 'd=$PWD; while [ \"$PWD\" != / ]; do if [ -f stack.yaml ]; then exec stack build; fi; " &
         "for c in *.cabal cabal.project; do if [ -f \"$c\" ]; then exec cabal build; fi; done; cd ..; done; " &
         "cd \"$d\"; exec ghc -outputdir \"$tmp/ned_ghc\" \"$file\"'",
  # (a file of its own: in a project, plain ghc knows neither its modules nor its packages — that is HLS's work)
  check: "sh -c 'd=$PWD; while [ \"$PWD\" != / ]; do for c in stack.yaml *.cabal cabal.project; do " &
         "if [ -f \"$c\" ]; then exit 0; fi; done; cd ..; done; cd \"$d\"; exec ghc -fno-code \"$file\"'",
  pairs: "()[]{}\"\""))

snippet("haskell", "module", "module ${1:Main} (${2:main}) where\n\n$0", "a module header")
snippet("haskell", "main", "main :: IO ()\nmain = do\n\t$0", "main")
snippet("haskell", "data", "data ${1:Name}\n\t= ${2:Constructor} ${3:Int}\n\tderiving (${4:Show, Eq})$0",
        "a data type")
snippet("haskell", "instance", "instance ${1:Show} ${2:Name} where\n\t${3:show} ${4:x} = $0", "an instance")
snippet("haskell", "case", "case ${1:value} of\n\t${2:pattern} -> $0", "a case")

# ── the outline, when there is no language server ──

const HsSymbolChars = {'!', '#', '$', '%', '&', '*', '+', '.', '/', '<', '=', '>', '?', '@', '\\', '^', '|', '-',
                       '~', ':'}

type HsScan = object
  comment: int                   # inside {- -} (they nest): how deep

# whether c can start a Haskell name: a letter or _
func hsIdentStart(c: char): bool = c in {'a'..'z', 'A'..'Z', '_'}
# whether c can be part of a Haskell name (a ' at its end counts: foo')
func hsIdentChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\''}

proc hsCode(s: string, st: var HsScan): string =
  ## the line with its comments, strings and characters made spaces (the columns kept): only the code is read
  result = s
  var i = 0
  template blank(a, b: int) =
    ## makes the characters a ..< b of the result spaces (up to the line's end)
    for k in a ..< min(b, s.len): result[k] = ' '
  while i < s.len:
    if st.comment > 0:
      if s.continuesWith("{-", i):
        inc st.comment
        blank(i, i + 2)
        i += 2
      elif s.continuesWith("-}", i):
        dec st.comment
        blank(i, i + 2)
        i += 2
      else:
        blank(i, i + 1)
        inc i
    elif s.continuesWith("{-", i):
      st.comment = 1
      blank(i, i + 2)
      i += 2
    elif s.continuesWith("--", i):
      # dashes not followed by an operator's character: a comment (--> and |-- are operators)
      var j = i
      while j < s.len and s[j] == '-': inc j
      if (j >= s.len or s[j] notin HsSymbolChars) and (i == 0 or s[i - 1] notin HsSymbolChars):
        blank(i, s.len)
        break
      i = j
    elif s[i] == '"':
      var j = i + 1
      while j < s.len and s[j] != '"':
        if s[j] == '\\': inc j
        inc j
      blank(i, j + 1)
      i = j + 1
    elif s[i] == '\'' and (i == 0 or not hsIdentChar(s[i - 1])):
      # a character: 'a', '\n', '\'' — not a prime (x') nor Template Haskell's 'name
      var j = i + 1
      if j < s.len and s[j] == '\\':
        j += 2
        while j < s.len and s[j] != '\'' and j - i < 12: inc j
      elif j < s.len:
        inc j
        while j < s.len and (ord(s[j]) and 0xC0) == 0x80: inc j
      if j < s.len and s[j] == '\'':
        blank(i, j + 1)
        i = j + 1
      else: inc i
    else: inc i

proc hsName(t: string, i: var int): string =
  ## a name at i — `foo'`, or an operator in parentheses, `(<+>)` — i moves past it ("" when none)
  let a = i
  if i < t.len and hsIdentStart(t[i]):
    while i < t.len and hsIdentChar(t[i]): inc i
  elif i + 1 < t.len and t[i] == '(' and t[i + 1] in HsSymbolChars:
    var j = i + 1
    while j < t.len and t[j] in HsSymbolChars: inc j
    if j < t.len and t[j] == ')': i = j + 1
  t[a ..< i]

proc hsSkip(t: string, i: var int) =
  ## moves i past any spaces and tabs at it
  while i < t.len and t[i] in {' ', '\t'}: inc i

proc hsTypeName(t: string, i: int): (string, int) =
  ## the declared type's name after `data`, `class` …: past a context (`(Show a) =>`); its column
  var k = i
  let arrow = t.find("=>", i)
  let eq = t.find('=', i)
  if arrow >= 0 and (eq < 0 or eq >= arrow): k = arrow + 2
  hsSkip(t, k)
  if k < t.len and t[k] == '(': inc k                 # (an operator type, `(:+:)`, or a context left bare)
  let a = k
  while k < t.len and (hsIdentChar(t[k]) or t[k] == '.'): inc k
  (t[a ..< k], a)

proc haskellSymbols(lines: seq[string]): seq[Symbol] =
  ## the module, types, classes and instances (their methods under them), the top-level functions and their
  ## signatures — from the declarations that start at the first column, as Haskell's layout has them
  var st: HsScan
  var seen: seq[string]          # the top-level names listed (a function's equations, after its signature, once)
  var holder = false             # in a class or an instance: its indented lines are its methods
  var holderInd = -1             # (the methods' indentation: deeper lines are their own `where`s)
  var seenIn: seq[string]
  var codes: seq[string]
  for s in lines: codes.add hsCode(s, st)
  for ln, code in codes:
    let t = code.strip(trailing = false)
    if t.strip.len == 0: continue
    let ind = code.len - t.len
    let s = lines[ln]
    if ind > 0 and not holder: continue
    if ind > 0 and holderInd >= 0 and ind != holderInd: continue
    if ind == 0:
      holder = false
      holderInd = -1
      seenIn.setLen(0)
    var i = 0
    var w = i
    while w < t.len and hsIdentChar(t[w]): inc w
    let word = t[0 ..< w]
    if ind == 0:
      case word
      of "module":
        var k = w
        hsSkip(t, k)
        let a = k
        while k < t.len and (hsIdentChar(t[k]) or t[k] == '.'): inc k
        if k > a: result.add Symbol(name: t[a ..< k], kind: "module", detail: "module", line: ln, col: a)
        continue
      of "data", "newtype", "type", "class", "instance":
        var k = w
        hsSkip(t, k)
        var detail = word
        for extra in ["family", "instance"]:
          if t.continuesWith(extra & " ", k):
            detail.add " " & extra
            k += extra.len
            hsSkip(t, k)
        if word == "instance":
          # its name: the class and the type, up to `where`
          var e = t.find(" where", k)
          if e < 0: e = t.strip(leading = false).len
          let arrow = t.find("=>", k)
          if arrow >= 0 and arrow < e:
            k = arrow + 2
            hsSkip(t, k)
          let name = t[k ..< e].strip
          if name.len > 0: result.add Symbol(name: name, kind: "class", detail: detail, line: ln, col: k)
        else:
          let (name, col) = hsTypeName(t, k)
          if name.len > 0:
            result.add Symbol(name: name, kind: (if word == "class": "class" else: "type"), detail: detail,
                              line: ln, col: col)
        holder = word in ["class", "instance"]
        continue
      of "import", "infix", "infixl", "infixr", "deriving", "default", "foreign", "where", "let", "in", "if",
         "then", "else", "case", "of", "do":
        continue
      of "pattern":
        var k = w
        hsSkip(t, k)
        if k < t.len and t[k] in {'A'..'Z'}:
          let a = k
          while k < t.len and hsIdentChar(t[k]): inc k
          result.add Symbol(name: t[a ..< k], kind: "constant", detail: "pattern", line: ln, col: a)
          continue
      else: discard
    elif holderInd < 0: holderInd = ind
    # a function: its signature (`a, b :: T`) or an equation (`f x = …`, `f x` with guards below)
    if t.len == 0 or not (t[0] in {'a'..'z', '_'} or t[0] == '('): continue
    var names: seq[(string, int)]
    while true:
      let a = i
      let n = hsName(t, i)
      if n.len == 0: break
      names.add (n, ind + a)
      hsSkip(t, i)
      if i < t.len and t[i] == ',':
        inc i
        hsSkip(t, i)
      else: break
    if names.len == 0: continue
    let depth = if ind > 0: 1 else: 0
    if t.continuesWith("::", i) and not t.continuesWith(":::", i):
      var detail = s[ind + i + 2 ..< min(s.len, ind + t.strip(leading = false).len)].strip
      if detail.len > 80: detail = detail[0 ..< 77] & "…"
      for (n, col) in names:
        if (if depth == 0: n in seen else: n in seenIn): continue
        result.add Symbol(name: n, kind: "function", detail: detail, line: ln, col: col, depth: depth)
        if depth == 0: seen.add n else: seenIn.add n
    elif names.len == 1:
      # (an equation: `=` on its line, or guards on the next — not a splice of Template Haskell's)
      var guarded = false
      for k in ln + 1 ..< codes.len:
        let nx = codes[k].strip
        if nx.len == 0: continue
        guarded = nx.startsWith("|")
        break
      if '=' notin t[i .. ^1] and not guarded: continue
      var (n, col) = names[0]
      # (an operator defined between its arguments: `a <+> b = …`, ``x `op` y = …``)
      if i < t.len and t[i] == '`':
        let e = t.find('`', i + 1)
        if e > i + 1:
          n = t[i + 1 ..< e]
          col = ind + i + 1
      elif i < t.len and t[i] in HsSymbolChars:
        var e = i
        while e < t.len and t[e] in HsSymbolChars: inc e
        let op = t[i ..< e]
        if op notin ["=", "|", "@", "!", "~"]:
          n = "(" & op & ")"
          col = ind + i
      if (if depth == 0: n in seen else: n in seenIn): continue
      result.add Symbol(name: n, kind: "function", line: ln, col: col, depth: depth)
      if depth == 0: seen.add n else: seenIn.add n

# ── the tools ──

proc haskellHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let haskellServerSet = setting("server", "").strip
var haskellServer: seq[string]
if haskellServerSet == "off": discard
elif haskellServerSet.len > 0:
  if haskellHave(haskellServerSet): haskellServer = haskellServerSet.splitWhitespace()
  else: echo "haskell: the server " & haskellServerSet & " is not installed (plugins.haskell.server)"
else:
  for cmd in ["haskell-language-server-wrapper --lsp", "haskell-language-server --lsp"]:
    if haskellHave(cmd):
      haskellServer = cmd.splitWhitespace()
      break
if haskellServer.len > 0:
  haskellServer[0] = expandTilde(haskellServer[0])
  languageServer("haskell", haskellServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("haskell") do (b: Buf) -> seq[Symbol]:
    haskellSymbols(b.lines)

let haskellFmtSet = setting("formatter", "").strip
if haskellFmtSet == "off": discard
elif haskellFmtSet.len > 0:
  if haskellHave(haskellFmtSet): formatter("haskell", haskellFmtSet)
  else: echo "haskell: the formatter " & haskellFmtSet & " is not installed (plugins.haskell.formatter)"
else:
  # (the file's path: where they look for the project's .cabal file, its language extensions, and fourmolu.yaml)
  for cmd in ["ormolu --stdin-input-file \"$file\"", "fourmolu --stdin-input-file \"$file\""]:
    if haskellHave(cmd):
      formatter("haskell", cmd)
      break
