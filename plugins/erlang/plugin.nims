## erlang — Erlang: colours, comments, indentation, F5, snippets, an outline; ELP or erlang_ls and erlfmt
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Erlang's `.erl`, `.hrl` and `.escript` files (and
## rebar.config): their colours (ned's generic lexer with Erlang's words: case, of, receive, after, fun, end …,
## Capitalised variables in the types' colour, ?MACROS and other ALL-CAPS names as constants, 'quoted atoms' as
## strings, OTP 27's """strings"""), `%` comments, indentation after `->`, of, receive, begin, try, after, if
## and brackets (end, after, catch and else typed alone go back a level), four spaces as erlfmt writes, brackets
## and quotes that close themselves, snippets (fun, case, receive, module, gen, test) and F5: in a rebar3 project
## (a rebar.config above the file) the module's EUnit tests — `rebar3 eunit --module=name` — or, for a
## Common Test suite (name_SUITE.erl), `rebar3 ct` on it; outside one, `escript file` for a script (#! on its first
## line), else the module compiled into ned's temporary folder and its main/0 run. Build (Alt+B) is `rebar3
## compile` in a project, `erlc` outside one.
##
## Without a language server, the outline lists the file's module, records, types, macros and functions (as
## name/arity, their clauses once), from a simple scan.
##
## The tools, when they are on PATH: ELP, the Erlang Language Platform
## (https://whatsapp.github.io/erlang-language-platform), or erlang_ls when ELP is not installed — completion,
## hover, go to definition, problems; erlfmt formats (Format document, and on save with editor.formatOnSave).
## Erlang itself: Termux `pkg install erlang`; rebar3 from https://rebar3.org.
##
## Settings (the Plugins dock › erlang › its settings; Plugins: reload after a change):
## - plugins.erlang.server — the language server's command, when it is neither `elp server` nor erlang_ls ("off":
##   none)
## - plugins.erlang.formatter — the formatter's command (the text on its stdin), when it is not `erlfmt -`
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Sultan Al Isaiee (@foxoman)", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for elp server (or erlang_ls) when it is " &
           "installed, \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for erlfmt - (when " &
           "it is installed), \"off\" for none. Plugins: reload after a change")

language("erlang", LangSpec(
  name: "Erlang",
  extensions: @["erl", "hrl", "escript"],
  files: @["rebar.config"],
  lineComment: "%",
  quotes: "\"'",
  tripleQuotes: true,
  capitalTypes: true,
  keywords: @["after", "and", "andalso", "band", "begin", "bnot", "bor", "bsl", "bsr", "bxor", "case", "catch",
              "cond", "div", "end", "fun", "if", "let", "maybe", "else", "not", "of", "orelse", "receive", "rem",
              "try", "when", "xor"],
  constants: @["true", "false", "undefined", "ok", "error"],
  builtins: @["self", "spawn", "spawn_link", "send", "hd", "tl", "length", "element", "setelement", "is_atom",
              "is_binary", "is_integer", "is_list", "is_map", "is_tuple", "is_pid", "throw", "exit", "apply",
              "make_ref", "node", "tuple_size", "map_size"],
  indentAfter: @["->", "of", "receive", "begin", "try", "after", "if", "maybe", "(", "[", "{"],
  dedentWords: @["end", "after", "catch", "else"],
  dedent: "})]",
  indentSize: 4,
  # (the suite by its path, with no .erl: the form rebar3's documentation gives)
  run: "sh -c 'f=\"$file\"; d=\"$dir\"; while [ ! -f \"$d/rebar.config\" ] && [ \"$d\" != / ]; do " &
       "d=$(dirname \"$d\"); done; if [ -f \"$d/rebar.config\" ]; then cd \"$d\"; case \"$f\" in *_SUITE.erl) " &
       "exec rebar3 ct --suite=\"$dir/$name\" ;; esac; exec rebar3 eunit --module=$name; fi; " &
       "if head -n 1 \"$f\" | grep -q \"^#!\"; then exec escript \"$f\"; fi; " &
       "erlc -o \"$tmp\" \"$f\" && exec erl -noshell -pa \"$tmp\" -s $name main -s init stop'",
  build: "sh -c 'd=\"$dir\"; while [ ! -f \"$d/rebar.config\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); done; " &
         "if [ -f \"$d/rebar.config\" ]; then cd \"$d\" && exec rebar3 compile; fi; exec erlc -o \"$tmp\" \"$file\"'",
  pairs: "()[]{}\"\""))

snippet("erlang", "fun", "${1:name}(${2:Args}) ->\n\t$0.", "a function")
snippet("erlang", "case", "case ${1:Expr} of\n\t${2:Pattern} ->\n\t\t${3:ok};\n\t_ ->\n\t\t$0\nend", "a case")
snippet("erlang", "receive", "receive\n\t${1:Msg} ->\n\t\t$0\nafter ${2:5000} ->\n\t\ttimeout\nend", "a receive")
snippet("erlang", "module", "-module(${1:name}).\n-export([${2:start/0}]).\n\n$0", "a module")
snippet("erlang", "gen", "-module(${1:name}).\n-behaviour(gen_server).\n\n" &
        "-export([start_link/0, init/1, handle_call/3, handle_cast/2]).\n\n" &
        "start_link() ->\n\tgen_server:start_link({local, ?MODULE}, ?MODULE, [], []).\n\n" &
        "init([]) ->\n\t{ok, ${2:state}}.\n\nhandle_call(_Request, _From, State) ->\n\t{reply, ok, State}.\n\n" &
        "handle_cast(_Msg, State) ->\n\t{noreply, State}.\n$0", "a gen_server")
snippet("erlang", "test", "${1:name}_test() ->\n\t?assertEqual(${2:Expected}, ${3:Actual})$0.", "an EUnit test")

# ── the outline, when there is no language server ──

func erlCode(s: string, triple: var bool): string =
  ## the line with its comments, strings, 'quoted atoms' and $c characters made spaces (the columns kept) —
  ## `triple`: inside a """string""" that goes on below
  result = s
  var i = 0
  if triple:
    # (its closing quotes stand on a line of their own)
    for k in 0 ..< s.len: result[k] = ' '
    if not s.strip.startsWith("\"\"\""): return
    triple = false
    i = s.find("\"\"\"") + 3
    result = repeat(' ', i) & s[i .. ^1]
  while i < s.len:
    if s[i] == '%':
      for k in i ..< s.len: result[k] = ' '
      break
    if s[i] == '$' and i + 1 < s.len:
      # a character: $a, $%, $", $\n
      let n = if s[i + 1] == '\\' and i + 2 < s.len: 3 else: 2
      for k in i ..< min(s.len, i + n): result[k] = ' '
      i += n
      continue
    if s.continuesWith("\"\"\"", i):
      triple = true
      for k in i ..< i + 3: result[k] = ' '
      i += 3
      continue
    if s[i] in {'"', '\''}:
      let q = s[i]
      result[i] = ' '
      inc i
      while i < s.len and s[i] != q:
        if s[i] == '\\' and i + 1 < s.len:
          result[i] = ' '
          inc i
        result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
    inc i

func erlAtomEnd(s: string, i: int): int =
  ## where the atom that starts at i ends: letters, digits, _ and @
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] in {'_', '@'}): inc result

func erlArity(args: string): int =
  ## how many arguments `(A, {B, C}, <<D, E>>)` has: its commas outside brackets (and binaries), and one
  var depth = 0
  var any = false
  var i = 0
  while i < args.len:
    let c = args[i]
    if args.continuesWith("<<", i):
      inc depth
      i += 2
      continue
    if args.continuesWith(">>", i):
      dec depth
      i += 2
      continue
    if c in {'(', '[', '{'}: inc depth
    elif c in {')', ']', '}'}: dec depth
    elif c == ',' and depth == 1: inc result
    elif depth >= 1 and c notin {' ', '\t'}: any = true
    inc i
  if any: inc result

func erlSymbols*(lines: seq[string]): seq[Symbol] =
  ## the module, records, types and macros, the functions as name/arity (one entry for their clauses)
  var triple = false
  var codes: seq[string]
  for s in lines: codes.add erlCode(s, triple)
  var last = ""                        # the last function's name/arity (its next clauses are not listed again)
  for ln, s in lines:
    let code = codes[ln]
    if code.len == 0 or code[0] == ' ' or code[0] == '\t': continue
    if code[0] == '-':
      # an attribute: -module(name). -record(name, …). -type name(…) :: … -define(NAME, …).
      let e = erlAtomEnd(code, 1)
      let attr = code[1 ..< e]
      var p = e
      while p < code.len and code[p] == ' ': inc p
      if p >= code.len: continue
      var a = p
      if code[p] == '(': a = p + 1
      while a < code.len and code[a] == ' ': inc a
      if attr == "define" and a < s.len and s[a] == '?': inc a
      let ne = erlAtomEnd(s, a)
      if ne == a: continue
      let name = s[a ..< ne]
      case attr
      of "module": result.add Symbol(name: name, kind: "module", detail: "-module", line: ln, col: a)
      of "record": result.add Symbol(name: name, kind: "struct", detail: "-record", line: ln, col: a)
      of "type", "opaque": result.add Symbol(name: name, kind: "type", detail: "-" & attr, line: ln, col: a)
      of "define":
        let withArgs = ne < code.len and code[ne] == '('
        result.add Symbol(name: "?" & name, kind: (if withArgs: "function" else: "constant"), detail: "-define",
                          line: ln, col: a)
      else: discard
      continue
    if code[0] notin {'a'..'z'}: continue
    # a function's clause: name(Args) -> … (its arguments may go on over lines)
    let e = erlAtomEnd(code, 0)
    if e >= code.len or code[e] != '(': continue
    var args = ""
    var depth = 0
    var k = ln
    var done = false
    while k < lines.len and k < ln + 20 and not done:
      let c = codes[k]
      for j in (if k == ln: e else: 0) ..< c.len:
        args.add c[j]
        if c[j] in {'(', '[', '{'}: inc depth
        elif c[j] in {')', ']', '}'}:
          dec depth
          if depth == 0:
            done = true
            break
      inc k
    let name = code[0 ..< e] & "/" & $erlArity(args)
    if name != last:
      result.add Symbol(name: name, kind: "function", detail: (if k == ln + 1: s[e ..< e + args.len] else: ""),
                        line: ln, col: 0)
      last = name

# ── the tools ──

proc erlHave(cmd: string): bool =
  ## whether the first word of the command line is a program that can be found (a ~ is expanded) — so a server or
  ## formatter that is set is only used when it is installed
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let erlServerSet = setting("server", "").strip
var erlServer: seq[string]
if erlServerSet == "off": discard
elif erlServerSet.len > 0:
  if erlHave(erlServerSet): erlServer = erlServerSet.splitWhitespace()
  else: echo "erlang: the server " & erlServerSet & " is not installed (plugins.erlang.server)"
else:
  for cmd in ["elp server", "erlang_ls"]:
    if erlHave(cmd):
      erlServer = cmd.splitWhitespace()
      break
if erlServer.len > 0:
  erlServer[0] = expandTilde(erlServer[0])
  languageServer("erlang", erlServer)
else:
  symbols("erlang") do (b: Buf) -> seq[Symbol]:
    erlSymbols(b.lines)

let erlFmtSet = setting("formatter", "").strip
if erlFmtSet == "off": discard
elif erlFmtSet.len > 0:
  if erlHave(erlFmtSet): formatter("erlang", erlFmtSet)
  else: echo "erlang: the formatter " & erlFmtSet & " is not installed (plugins.erlang.formatter)"
elif findExe("erlfmt").len > 0:
  # (`-`: the text from stdin, the formatted text to stdout)
  formatter("erlang", "erlfmt -")
