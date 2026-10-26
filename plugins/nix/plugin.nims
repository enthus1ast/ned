## nix — Nix: colours, comments, indentation, F5, snippets, an outline; nixd or nil and nixfmt
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Nix's `.nix` files: their colours (ned's generic
## lexer with Nix's words: let, in, with, rec, inherit …, the builtins, names with - and ' in them, "strings" over
## several lines), `#` and `/* … */` comments, indentation after `{` `(` `[`, `=`, let, then and else (and `in`
## typed alone goes back a level), two spaces as nixfmt writes, brackets and quotes that close themselves, snippets
## (let, if, fn, drv, shell, flake) and F5: `nix flake check` on a flake.nix, else `nix-instantiate --eval
## --strict file` — the file's value printed. Build (Alt+B) is `nix build` in a flake (a flake.nix above the
## file), else `nix-build file`. Its ''indented strings'' are not coloured as strings: the generic lexer has no such
## quotes.
##
## Without a language server, the outline lists the file's bindings — `name = …;` in its sets and lets, the ones
## inside a binding's value under it (a flake's outputs, a derivation's attributes …) — functions and sets marked as
## such, from a simple scan.
##
## The tools, when they are on PATH (`nix profile install nixpkgs#nixd nixpkgs#nixfmt`): nixd, or nil, Nix's
## language servers — completion, hover, go to definition, problems; nixfmt formats (Format document, and on save
## with editor.formatOnSave), or alejandra when nixfmt is not installed.
##
## Settings (the Plugins dock › nix › its settings; Plugins: reload after a change):
## - plugins.nix.server — the language server's command, when it is neither nixd nor nil ("off": none)
## - plugins.nix.formatter — the formatter's command (the text on its stdin), when it is neither of those
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")

settingDef("server", "", "The language server's command: empty for nixd (or nil) when it is installed, \"off\" " &
           "for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for nixfmt (or " &
           "alejandra) when it is installed, \"off\" for none. Plugins: reload after a change")

language("nix", LangSpec(
  name: "Nix",
  extensions: @["nix"],
  lineComment: "#",
  blockComment: @["/*", "*/"],
  quotes: "\"",
  multilineStrings: true,
  nameChars: "-'",
  keywords: @["let", "in", "with", "rec", "inherit", "if", "then", "else", "assert", "or"],
  constants: @["true", "false", "null"],
  builtins: @["import", "builtins", "map", "toString", "throw", "abort", "derivation", "fetchTarball", "fetchGit",
              "baseNameOf", "dirOf", "isNull", "removeAttrs"],
  indentAfter: @["{", "(", "[", "=", "let", "then", "else"],
  dedentWords: @["in"],
  dedent: "})]",
  indentSize: 2,
  run: "sh -c 'case \"$file\" in */flake.nix) exec nix flake check ;; esac; " &
       "exec nix-instantiate --eval --strict \"$file\"'",
  build: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/flake.nix\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
         "if [ -f \"$d/flake.nix\" ]; then cd \"$d\" && exec nix build; fi; exec nix-build \"$file\"'",
  pairs: "()[]{}\"\""))

# (no ${…} in these: a snippet takes it for a placeholder)
snippet("nix", "let", "let\n\t${1:name} = ${2:value};\nin\n$0", "a let … in")
snippet("nix", "if", "if ${1:cond} then ${2:a} else $0", "an if")
snippet("nix", "fn", "{ pkgs ? import <nixpkgs> { } }:\n\n$0", "a function of a set (a package's file)")
snippet("nix", "drv", "stdenv.mkDerivation {\n\tpname = \"${1:name}\";\n\tversion = \"${2:0.1.0}\";\n" &
        "\tsrc = ${3:./.};\n\t$0\n}", "a derivation")
snippet("nix", "shell", "pkgs.mkShell {\n\tpackages = [ ${1:pkgs.hello} ];\n\t$0\n}", "a development shell")
snippet("nix", "flake", "{\n\tdescription = \"${1:what it is}\";\n\n" &
        "\tinputs.nixpkgs.url = \"github:NixOS/nixpkgs/nixos-unstable\";\n\n" &
        "\toutputs = { self, nixpkgs }: {\n\t\t$0\n\t};\n}", "a flake")

# ── the outline, when there is no language server ──

func nixCode(s: string, st: var int): string =
  ## the line with its comments and strings made spaces (the columns kept) — `st`: what goes on from the line
  ## above (0 code, 1 a "string", 2 an ''indented string'', 3 a /* comment */)
  result = s
  var i = 0
  template blank(n: int) =
    for k in i ..< min(s.len, i + n): result[k] = ' '
    i += n
  while i < s.len:
    case st
    of 1:
      if s[i] == '\\' and i + 1 < s.len:
        blank(2)
        continue
      if s[i] == '"': st = 0
      blank(1)
    of 2:
      # ('''  ''$  ''\x: the string's escapes; '' alone ends it)
      if s.continuesWith("'''", i) or s.continuesWith("''$", i) or s.continuesWith("''\\", i):
        blank(3)
      elif s.continuesWith("''", i):
        st = 0
        blank(2)
      else: blank(1)
    of 3:
      if s.continuesWith("*/", i):
        st = 0
        blank(2)
      else: blank(1)
    else:
      if s[i] == '#':
        blank(s.len - i)
      elif s.continuesWith("/*", i):
        st = 3
        blank(2)
      elif s[i] == '"':
        st = 1
        blank(1)
      elif s.continuesWith("''", i):
        st = 2
        blank(2)
      else: inc i

func nixIsName(c: char): bool = c.isAlphaNumeric or c in {'_', '-', '\''}

func nixAttrPath(s: string, i: int): int =
  ## where the attribute path at i ends (a.b."c-d".${x}) — i: none
  var k = i
  while true:
    if k < s.len and s[k] == '"':
      let e = s.find('"', k + 1)
      if e < 0: return i
      k = e + 1
    elif s.continuesWith("${", k):
      let e = s.find('}', k)
      if e < 0: return i
      k = e + 1
    elif k < s.len and (s[k].isAlphaAscii or s[k] == '_'):
      while k < s.len and nixIsName(s[k]): inc k
    else: return i
    if k < s.len and s[k] == '.': inc k
    else: return k

func nixIsLambda(v: string): bool =
  ## does the value start with a function's argument (`x:`, `{ a, b }:`, `args@{ … }:`)?
  var k = 0
  while k < v.len and nixIsName(v[k]): inc k
  if k > 0 and k < v.len and v[k] == ':' and (k + 1 >= v.len or v[k + 1] in {' ', '\t'}): return true
  if k > 0 and k < v.len and v[k] == '@': return true
  if v.startsWith("{"):
    let e = v.find('}')
    if e > 0:
      var j = e + 1
      while j < v.len and v[j] == ' ': inc j
      return j < v.len and (v[j] == ':' or v[j] == '@')
  false

func nixSymbols*(lines: seq[string]): seq[Symbol] =
  ## the bindings (`name = …;`) of the file's sets and lets: the ones inside another binding's value under it
  var st = 0
  # what is open: { [ ( brackets, L a let (until its in), W a with or assert (until its ;), B a binding (its ;)
  var stack: seq[char]
  for ln, s in lines:
    let startsIn = st
    let code = nixCode(s, st)
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    var from0 = col
    if startsIn == 0:
      let e = nixAttrPath(s, col)
      var k = e
      while k < s.len and s[k] == ' ': inc k
      if e > col and k < code.len and code[k] == '=' and (k + 1 >= code.len or code[k + 1] != '='):
        let name = s[col ..< e]
        var depth = 0
        for c in stack:
          if c == 'B': inc depth
        let v = code[k + 1 .. ^1].strip
        let kind = if nixIsLambda(v): "function"
                   elif v.startsWith("{") or v.startsWith("rec {") or v.startsWith("rec{"): "object"
                   else: "variable"
        let detail = if kind == "function": s[k + 1 .. ^1].strip.split(':')[0].strip else: ""
        if name notin ["let", "in", "with", "rec", "inherit", "if", "then", "else", "assert"]:
          result.add Symbol(name: name, kind: kind, detail: detail, line: ln, col: col, depth: depth)
          stack.add 'B'
          from0 = k + 1
    # what the rest of the line opens and closes
    var i = from0
    while i < code.len:
      let c = code[i]
      if c in {'{', '[', '('}: stack.add c
      elif c in {'}', ']', ')'}:
        let open = case c
                   of '}': '{'
                   of ']': '['
                   else: '('
        while stack.len > 0:
          let top = stack.pop()
          if top == open: break
      elif c == ';':
        if stack.len > 0 and stack[^1] in {'W', 'B'}: discard stack.pop()
      elif c.isAlphaAscii and (i == 0 or not nixIsName(code[i - 1])):
        var e = i
        while e < code.len and nixIsName(code[e]): inc e
        case code[i ..< e]
        of "let": stack.add 'L'
        of "in":
          while stack.len > 0:
            if stack.pop() == 'L': break
        of "with", "assert": stack.add 'W'
        else: discard
        i = e
        continue
      inc i

# ── the tools ──

proc nixHave(cmd: string): bool =
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let nixServerSet = setting("server", "").strip
var nixServer: seq[string]
if nixServerSet == "off": discard
elif nixServerSet.len > 0:
  if nixHave(nixServerSet): nixServer = nixServerSet.splitWhitespace()
  else: echo "nix: the server " & nixServerSet & " is not installed (plugins.nix.server)"
else:
  for cmd in ["nixd", "nil"]:
    if nixHave(cmd):
      nixServer = @[cmd]
      break
if nixServer.len > 0:
  nixServer[0] = expandTilde(nixServer[0])
  languageServer("nix", nixServer)
else:
  symbols("nix") do (b: Buf) -> seq[Symbol]:
    nixSymbols(b.lines)

let nixFmtSet = setting("formatter", "").strip
if nixFmtSet == "off": discard
elif nixFmtSet.len > 0:
  if nixHave(nixFmtSet): formatter("nix", nixFmtSet)
  else: echo "nix: the formatter " & nixFmtSet & " is not installed (plugins.nix.formatter)"
else:
  # (nixfmt with no file reads stdin; alejandra's `-` is stdin, --quiet leaves only the text on stdout)
  for cmd in ["nixfmt", "alejandra --quiet -"]:
    if nixHave(cmd):
      formatter("nix", cmd)
      break
