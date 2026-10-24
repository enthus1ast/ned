## elixir — Elixir: colours, comments, indentation, F5, snippets, an outline; its language server and mix format
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Elixir's `.ex` and `.exs` files (mix.exs among them):
## their colours (ned's generic lexer with Elixir's words: modules as types, `valid?` and `save!` as names,
## @attributes, `"""` heredocs and strings over several lines), `#` comments, indentation after `do`, `fn`, `->`,
## `else` … and brackets, and back out as you type `end`, `else`, `rescue`, `catch` or `after` alone (two spaces,
## as mix format writes), brackets and quotes that close themselves, snippets (defmodule, def, defp, case, test)
## and F5: in a Mix project (mix.exs above the file) `mix test` for a test, `mix run file.exs` for another script
## and `mix run` for the rest; outside one, `elixir file`. Build (Alt+B) is `mix compile` in a project, `elixirc`
## for a file of its own (its .beam files in ned's temporary folder).
##
## Without a language server, the outline (Alt+I, Go to symbol) lists the file's modules, protocols and their
## implementations, structs, functions and macros (name/arity, a function's clauses once), and ExUnit's describe
## and test blocks, from a simple scan; the documentation's heredocs are left out.
##
## The tools, when they are on PATH — Elixir itself: Termux `pkg install elixir` (it brings Erlang); elsewhere
## https://elixir-lang.org/install.html
## - a language server, the first of these installed: Expert (`expert --stdio`, Elixir's official one:
##   https://github.com/elixir-lang/expert/releases — the expert_… program, renamed expert), Next LS
##   (`nextls --stdio`), Lexical (`lexical`, or its `start_lexical.sh`), ElixirLS (`elixir-ls`, or the
##   `language_server.sh` of its release: https://github.com/elixir-lsp/elixir-ls/releases — unzip it and put that
##   folder on PATH; it needs only Elixir, so it runs on Termux too)
## - `mix format -`, the formatter (Format document, and on save with editor.formatOnSave), run in the project's
##   folder so that its .formatter.exs counts
##
## Settings (the Plugins dock › elixir › its settings; Plugins: reload after a change):
## - plugins.elixir.server — the language server's command, when it is none of those ("off": none)
## - plugins.elixir.formatter — the formatter's command (the text on its stdin), when it is not mix format
##   ("off": none)
import nedplugin

requiresNed(">= 6.25")

settingDef("server", "", "The language server's command: empty for the first installed of expert, nextls, " &
           "lexical and elixir-ls, \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for mix format " &
           "(when Elixir is installed), \"off\" for none. Plugins: reload after a change")

language("elixir", LangSpec(
  name: "Elixir",
  extensions: @["ex", "exs"],
  lineComment: "#",
  quotes: "\"'",
  tripleQuotes: true,
  multilineStrings: true,
  capitalTypes: true,
  decorators: true,
  nameChars: "?!",
  keywords: @["def", "defp", "defmodule", "defmacro", "defmacrop", "defguard", "defguardp", "defdelegate",
              "defstruct", "defexception", "defprotocol", "defimpl", "defoverridable", "do", "end", "fn", "case",
              "cond", "with", "when", "if", "unless", "else", "try", "catch", "rescue", "after", "raise", "reraise",
              "throw", "receive", "quote", "unquote", "unquote_splicing", "import", "require", "alias", "use", "for",
              "in", "and", "or", "not", "super"],
  constants: @["true", "false", "nil", "__MODULE__", "__DIR__", "__ENV__", "__CALLER__", "__STACKTRACE__"],
  builtins: @["is_atom", "is_binary", "is_bitstring", "is_boolean", "is_float", "is_function", "is_integer",
              "is_list", "is_map", "is_map_key", "is_nil", "is_number", "is_pid", "is_struct", "is_tuple", "elem",
              "put_elem", "hd", "tl", "length", "map_size", "tuple_size", "inspect", "spawn", "spawn_link", "send",
              "self", "apply", "to_string", "struct", "then", "tap", "dbg", "exit", "describe", "test", "setup",
              "setup_all", "assert", "refute", "assert_raise", "assert_receive", "refute_receive"],
  functionWords: @["def", "defp", "defmacro", "defmacrop", "defguard", "defguardp", "defdelegate"],
  classWords: @["defmodule", "defprotocol", "defimpl"],
  indentAfter: @["do", "fn", "->", "else", "after", "rescue", "catch", "(", "[", "{"],
  dedent: "})]",
  dedentWords: @["end", "else", "rescue", "catch", "after"],
  indentSize: 2,
  # (the project is the folder with mix.exs, above the file; a test runs with mix test, a script with mix run)
  run: "sh -c 'd=$PWD; while [ ! -f mix.exs ] && [ \"$PWD\" != / ]; do cd ..; done; " &
       "if [ ! -f mix.exs ]; then cd \"$d\"; exec elixir \"$file\"; fi; " &
       "case \"$file\" in *_test.exs) exec mix test \"$file\" ;; \"$PWD\"/mix.exs|*.ex) exec mix run ;; " &
       "*) exec mix run \"$file\" ;; esac'",
  build: "sh -c 'd=$PWD; while [ ! -f mix.exs ] && [ \"$PWD\" != / ]; do cd ..; done; " &
         "if [ -f mix.exs ]; then exec mix compile; fi; cd \"$d\"; exec elixirc -o \"$tmp/ned_beam\" \"$file\"'",
  pairs: "()[]{}\"\""))

snippet("elixir", "defmodule", "defmodule ${1:Name} do\n\t$0\nend", "a module")
snippet("elixir", "def", "def ${1:name}($2) do\n\t$0\nend", "a function")
snippet("elixir", "defp", "defp ${1:name}($2) do\n\t$0\nend", "a private function")
snippet("elixir", "case", "case ${1:value} do\n\t${2:pattern} -> $0\nend", "a case")
snippet("elixir", "test", "test \"${1:what it does}\" do\n\t$0\nend", "an ExUnit test")

# ── the outline, when there is no language server ──

func exIdentChar(c: char): bool = c in {'a'..'z', 'A'..'Z', '0'..'9', '_'}

proc exArity(lines: seq[string], ln, at: int): int =
  ## the number of arguments in the parentheses that open at `at` of line ln (they may go on over lines)
  var depth = 0
  var commas = 0
  var any = false
  var q = '\0'                   # inside a string of this quote
  var l = ln
  var i = at
  while l < lines.len and l < ln + 20:
    let s = lines[l]
    while i < s.len:
      let c = s[i]
      if q != '\0':
        if c == '\\': inc i
        elif c == q: q = '\0'
      elif c in {'"', '\''}:
        q = c
        any = true
      elif c in {'(', '[', '{'}:
        inc depth
        if depth > 1: any = true
      elif c in {')', ']', '}'}:
        dec depth
        if depth == 0: return (if any: commas + 1 else: 0)
      elif c == ',' and depth == 1: inc commas
      elif c == '#' and q == '\0': break
      elif c notin {' ', '\t'}: any = true
      inc i
    inc l
    i = 0
  if any: commas + 1 else: 0

proc exModuleName(t: string, i: var int): string =
  ## an alias at i (MyApp.Shapes) — i moves past it
  let a = i
  while i < t.len and (exIdentChar(t[i]) or t[i] == '.'): inc i
  t[a ..< i]

proc exString(t: string, i: int): string =
  ## the text of the string literal at i ("" when there is none)
  if i >= t.len or t[i] notin {'"', '\''}: return ""
  let e = t.find(t[i], i + 1)
  if e < 0: t[i + 1 .. ^1] else: t[i + 1 ..< e]

proc elixirSymbols(lines: seq[string]): seq[Symbol] =
  ## modules, protocols, implementations, structs, functions and macros, ExUnit's describe and test: nested by
  ## their indentation (as mix format writes it)
  var heredoc = false
  var open: seq[(int, string)]   # the blocks that hold others: their indentation, their module's name ("": none)
  for ln, s in lines:
    let quotes = s.count("\"\"\"") + s.count("'''")
    if heredoc:
      if quotes mod 2 == 1: heredoc = false
      continue
    if quotes mod 2 == 1: heredoc = true      # (it begins after what this line declares, if anything)
    let t = s.strip(trailing = false)
    let ind = s.len - t.len
    if t.len == 0 or t[0] == '#': continue
    var e = 0
    while e < t.len and exIdentChar(t[e]): inc e
    let word = t[0 ..< e]
    if word notin ["defmodule", "defprotocol", "defimpl", "def", "defp", "defmacro", "defmacrop", "defguard",
                   "defguardp", "defdelegate", "defstruct", "defexception", "describe", "test"]: continue
    if e >= t.len or t[e] notin {' ', '\t', '('}:
      if not (word in ["defstruct", "defexception"] and e == t.len): continue
    while open.len > 0 and open[^1][0] >= ind: open.setLen(open.len - 1)
    let depth = open.len
    var module = ""
    for (_, m) in open:
      if m.len > 0: module = m
    var i = e
    while i < t.len and t[i] in {' ', '\t'}: inc i
    var sym = Symbol(line: ln, col: ind + i, depth: depth, detail: word)
    var opens = ""                           # a block that holds others: its module's name, or "-"
    case word
    of "defmodule", "defprotocol":
      sym.name = exModuleName(t, i)
      sym.kind = (if word == "defmodule": "module" else: "interface")
      opens = (if module.len > 0 and word == "defmodule": module & "." & sym.name else: sym.name)
    of "defimpl":
      let proto = exModuleName(t, i)
      let f = t.find("for:", i)
      var target = module
      if f >= 0:
        var k = f + 4
        while k < t.len and t[k] == ' ': inc k
        target = exModuleName(t, k)
      sym.name = proto & (if target.len > 0: " for " & target else: "")
      sym.kind = "module"
      opens = "-"
    of "defstruct", "defexception":
      sym.name = (if module.len > 0: "%" & module & "{}" else: word)
      sym.kind = "struct"
      sym.col = ind
    of "describe", "test":
      sym.name = exString(t, i)
      if sym.name.len == 0: continue
      sym.kind = (if word == "describe": "section" else: "function")
      if word == "describe": opens = "-"
    else:
      let a = i
      while i < t.len and exIdentChar(t[i]): inc i
      if i < t.len and t[i] in {'?', '!'}: inc i
      let name = t[a ..< i]
      if name.len == 0 or name in ["unquote", "unquote_splicing"]: continue
      let arity = if i < t.len and t[i] == '(': exArity(lines, ln, ind + i) else: 0
      sym.name = name & "/" & $arity
      sym.kind = "function"
    if sym.name.len == 0: continue
    # (a function's clauses, one after another: once)
    if not (result.len > 0 and result[^1].name == sym.name and result[^1].depth == depth and
            result[^1].kind == sym.kind and opens.len == 0):
      result.add sym
    if opens.len > 0: open.add (ind, (if opens == "-": "" else: opens))

# ── the tools ──

proc elixirHave(cmd: string): bool =
  ## its program is installed (on PATH, or a path to it)
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let elixirServerSet = setting("server", "").strip
var elixirServer: seq[string]
if elixirServerSet == "off": discard
elif elixirServerSet.len > 0:
  if elixirHave(elixirServerSet): elixirServer = elixirServerSet.splitWhitespace()
  else: echo "elixir: the server " & elixirServerSet & " is not installed (plugins.elixir.server)"
else:
  for cmd in ["expert --stdio", "nextls --stdio", "lexical", "start_lexical.sh", "elixir-ls", "language_server.sh"]:
    if elixirHave(cmd):
      elixirServer = cmd.splitWhitespace()
      break
if elixirServer.len > 0:
  elixirServer[0] = expandTilde(elixirServer[0])
  languageServer("elixir", elixirServer)
else:
  # (a plugin's symbols take the place of the server's outline: only without one)
  symbols("elixir") do (b: Buf) -> seq[Symbol]:
    elixirSymbols(b.lines)

let elixirFmtSet = setting("formatter", "").strip
if elixirFmtSet == "off": discard
elif elixirFmtSet.len > 0:
  if elixirHave(elixirFmtSet): formatter("elixir", elixirFmtSet)
  else: echo "elixir: the formatter " & elixirFmtSet & " is not installed (plugins.elixir.formatter)"
elif findExe("mix").len > 0:
  # (in the project's folder, the one with mix.exs above the file: its .formatter.exs says how)
  formatter("elixir", "sh -c 'd=$PWD; while [ ! -f mix.exs ] && [ \"$PWD\" != / ]; do cd ..; done; " &
                      "[ -f mix.exs ] || cd \"$d\"; exec mix format -'")
