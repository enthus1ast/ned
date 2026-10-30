## ocaml — OCaml: colours, comments, indentation, F5, snippets, an outline; ocamllsp and ocamlformat
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned OCaml's `.ml`, `.mli`, `.mll`, `.mly` files (and
## dune's): their colours (ned's generic lexer with OCaml's words: Capitalised names as modules and constructors,
## 'a type variables, [@attributes]), `(* … *)` comments (nested, as OCaml's are), indentation after struct, sig,
## begin, object, let … =, match … with, ->, two spaces as ocamlformat writes, snippets (let, letrec, match, type,
## module, sig, test) and F5: `dune exec` in a dune project (a dune-project above the file; `dune test` for a file of
## its test folder), else `ocaml` on the file. Build (Alt+B) is `dune build`.
##
## Without a language server, the outline lists the file's lets, types, exceptions, externals, classes and modules
## (with what is in them), from a simple scan.
##
## The tools, when they are on PATH (`opam install ocaml-lsp-server ocamlformat`; Termux: `pkg install ocaml` has
## the compiler only): ocamllsp — completion, hover, go to definition, problems; ocamlformat formats (Format document,
## and on save with editor.formatOnSave), with the project's .ocamlformat when it has one.
##
## Settings (the Plugins dock › ocaml › its settings; Plugins: reload after a change):
## - plugins.ocaml.server — the language server's command, when it is not `ocamllsp` ("off": none)
## - plugins.ocaml.formatter — the formatter's command (the text on its stdin), when it is not ocamlformat
import nedplugin
import std/strutils

requiresNed(">= 6.25")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for ocamllsp (when it is installed), \"off\" for " &
           "none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for ocamlformat " &
           "(when it is installed), \"off\" for none. Plugins: reload after a change")

language("ocaml", LangSpec(
  name: "OCaml",
  extensions: @["ml", "mli", "mll", "mly"],
  blockComment: @["(*", "*)"],
  nestedComments: true,
  docBlockComment: @["(**", "*)"],
  quotes: "\"",
  charLiterals: true,
  capitalTypes: true,
  nameChars: "'",
  keywords: @["and", "as", "assert", "begin", "class", "constraint", "do", "done", "downto", "else", "end",
              "exception", "external", "for", "fun", "function", "functor", "if", "in", "include", "inherit",
              "initializer", "lazy", "let", "match", "method", "module", "mutable", "new", "nonrec", "object", "of",
              "open", "private", "rec", "sig", "struct", "then", "to", "try", "type", "val", "virtual", "when",
              "while", "with", "lor", "lsl", "lsr", "asr", "land", "lxor", "mod", "or"],
  types: @["int", "float", "bool", "char", "string", "bytes", "unit", "list", "array", "option", "result", "ref",
           "exn", "int32", "int64", "nativeint", "format", "lazy_t", "seq"],
  constants: @["true", "false", "None", "Some", "Ok", "Error"],
  builtins: @["print_endline", "print_string", "print_int", "printf", "failwith", "invalid_arg", "raise", "ignore",
              "not", "fst", "snd", "ref"],
  functionWords: @["let", "and", "val", "external", "method"],
  classWords: @["module", "type", "class", "exception"],
  indentAfter: @["struct", "sig", "begin", "object", "=", "->", "with", "then", "else", "in", "do", "(", "[", "{"],
  dedentWords: @["end", "done", "in", "|"],
  dedent: ")]}",
  indentSize: 2,
  run: "sh -c 'f=\"$file\"; d=\"$dir\"; while [ ! -f \"$d/dune-project\" ] && [ \"$d\" != / ]; do " &
       "d=$(dirname \"$d\"); done; if [ -f \"$d/dune-project\" ]; then cd \"$d\"; case \"$f\" in \"$d\"/test/*) " &
       "exec dune test ;; esac; r=$(dirname \"${f#$d/}\"); if [ \"$r\" = . ]; then exec dune exec ./$name.exe; fi; " &
       "exec dune exec \"./$r/$name.exe\"; else exec ocaml \"$f\"; fi'",
  build: "dune build",
  pairs: "()[]{}\"\""))

snippet("ocaml", "let", "let ${1:name} ${2:x} =\n  $0", "a function")
snippet("ocaml", "letrec", "let rec ${1:name} ${2:x} =\n  $0", "a recursive function")
snippet("ocaml", "match", "match ${1:x} with\n| ${2:None} -> ${3:()}\n| ${4:Some v} -> $0", "a match")
snippet("ocaml", "type", "type ${1:t} =\n  | ${2:A}\n  | ${3:B} of ${4:int}$0", "a variant type")
snippet("ocaml", "module", "module ${1:M} = struct\n  $0\nend", "a module")
snippet("ocaml", "sig", "module type ${1:S} = sig\n  val ${2:f} : ${3:int -> int}$0\nend", "a module type")
snippet("ocaml", "test", "let%test \"${1:what}\" = ${2:true}$0", "an inline test (ppx_inline_test)")

# ── the outline, when there is no language server ──

func mlCode(s: string, nest: var int, quoted: var string): string =
  ## the line with its comments and strings made spaces (the columns kept) — `nest`: the comments open, `quoted`:
  ## the end of a {id|…|id} string that goes on below ("" none)
  result = s
  var i = 0
  while i < s.len:
    if quoted.len > 0:
      if s.continuesWith(quoted, i):
        for k in i ..< i + quoted.len: result[k] = ' '
        i += quoted.len
        quoted = ""
        continue
      result[i] = ' '
      inc i
      continue
    if s.continuesWith("(*", i):
      inc nest
      result[i] = ' '
      result[i + 1] = ' '
      i += 2
      continue
    if nest > 0:
      if s.continuesWith("*)", i):
        dec nest
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      result[i] = ' '
      inc i
      continue
    if s[i] == '"':
      result[i] = ' '
      inc i
      while i < s.len and s[i] != '"':
        if s[i] == '\\' and i + 1 < s.len:
          result[i] = ' '
          inc i
        result[i] = ' '
        inc i
      if i < s.len: result[i] = ' '
    elif s[i] == '{' and i + 1 < s.len and (s[i + 1] == '|' or s[i + 1] in {'a'..'z', '_'}):
      # {|…|} and {id|…|id}
      var k = i + 1
      while k < s.len and s[k] in {'a'..'z', '_'}: inc k
      if k < s.len and s[k] == '|':
        quoted = "|" & s[i + 1 ..< k] & "}"
        for j in i .. k: result[j] = ' '
        i = k + 1
        continue
    elif s[i] == '\'' and i + 2 < s.len and (s[i + 2] == '\'' or s[i + 1] == '\\'):
      # a character ('a', '\n'), not a type variable ('a)
      var k = i + 1
      if s[k] == '\\': k += 2
      else: inc k
      while k < s.len and s[k] != '\'' and k < i + 6: inc k
      if k < s.len and s[k] == '\'':
        for j in i .. k: result[j] = ' '
        i = k + 1
        continue
    inc i

func mlName(s: string, i: int): (string, int) =
  ## the name at i (after spaces): (it, where it ends)
  var a = i
  while a < s.len and s[a] == ' ': inc a
  if a < s.len and s[a] == '(':
    # an operator: let ( +! ) a b = …
    let e = s.find(')', a)
    if e > a: return ("(" & s[a + 1 ..< e].strip & ")", e + 1)
  var e = a
  while e < s.len and (s[e].isAlphaNumeric or s[e] in {'_', '\''}): inc e
  (s[a ..< e], e)

const MlItems = ["let", "and", "type", "module", "exception", "external", "class", "val", "open", "include"]

func mlSymbols*(lines: seq[string]): seq[Symbol] =
  ## the lets, types, exceptions, externals, classes and modules — of the top level and of modules' struct … end
  var nest = 0
  var quoted = ""
  var stack: seq[(bool, int)]          # the blocks open (struct, sig, object, begin): a module's?, its items' column
  var lastItem = ""                    # the word of the last item (an `and` goes on with it)
  for ln, s in lines:
    let code = mlCode(s, nest, quoted)
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    var depth = 0
    var inCode = false
    for (isMod, _) in stack:
      if isMod: inc depth
      else: inCode = true
    let words = t.splitWhitespace()
    let first = words[0]
    # the items' column of this block: its first item's
    let want = if stack.len == 0: 0 else: stack[^1][1]
    if not inCode and first in MlItems and (want < 0 or col <= want):
      if stack.len > 0 and stack[^1][1] < 0: stack[^1][1] = col
      var rest = t[first.len .. ^1]
      var kind, detail: string
      case first
      of "let", "and":
        let w2 = rest.strip
        var r = rest
        if first == "let" or lastItem == "let":
          for kw in ["rec ", "%test ", "open ", "nonrec "]:
            if w2.startsWith(kw): r = w2[kw.len .. ^1]
          let (n, e) = mlName(r, 0)
          if n.len > 0 and n != "_" and n != "()":
            let after = r[e .. ^1].strip
            kind = if after.startsWith("=") or after.startsWith(":") and "->" notin after.split('=')[0]: "variable"
                   else: "function"
            detail = if w2.startsWith("rec "): "let rec" else: "let"
            if kind == "function":
              let eq = after.find('=')
              detail &= " " & (if eq >= 0: after[0 ..< eq].strip else: after.strip)
            result.add Symbol(name: n, kind: kind, detail: detail, line: ln, col: max(0, s.find(n, col)),
                              depth: depth)
        elif lastItem == "type":
          let (n, _) = mlName(rest, 0)
          if n.len > 0: result.add Symbol(name: n, kind: "type", detail: "type", line: ln, col: s.find(n, col),
                                          depth: depth)
      of "type":
        var r = rest.strip
        if r.startsWith("nonrec "): r = r[7 .. ^1]
        # type 'a t, type ('a, 'b) t
        if r.startsWith("'"): r = r[r.find(' ') + 1 .. ^1]
        elif r.startsWith("("): r = r[r.find(')') + 1 .. ^1]
        let (n, _) = mlName(r, 0)
        if n.len > 0: result.add Symbol(name: n, kind: "type", detail: "type", line: ln, col: s.find(n, col),
                                        depth: depth)
      of "module":
        var r = rest.strip
        var detail = "module"
        if r.startsWith("type "):
          r = r[5 .. ^1]
          detail = "module type"
        elif r.startsWith("rec "): r = r[4 .. ^1]
        let (n, _) = mlName(r, 0)
        if n.len > 0: result.add Symbol(name: n, kind: "module", detail: detail, line: ln, col: s.find(n, col),
                                        depth: depth)
      of "exception":
        let (n, _) = mlName(rest, 0)
        if n.len > 0: result.add Symbol(name: n, kind: "struct", detail: "exception", line: ln,
                                        col: s.find(n, col), depth: depth)
      of "external", "val":
        let (n, _) = mlName(rest, 0)
        let colon = rest.find(':')
        if n.len > 0:
          result.add Symbol(name: n, kind: "function", detail: first & (if colon >= 0: " :" &
                            rest[colon + 1 .. ^1].split('=')[0].strip(trailing = true).replace("  ", " ") else: ""),
                            line: ln, col: s.find(n, col), depth: depth)
      of "class":
        var r = rest.strip
        if r.startsWith("virtual "): r = r[8 .. ^1]
        let (n, _) = mlName(r, 0)
        if n.len > 0: result.add Symbol(name: n, kind: "class", detail: "class", line: ln, col: s.find(n, col),
                                        depth: depth)
      else: discard
    if first in MlItems and first != "and": lastItem = first
    # the blocks: struct and sig open a module's (their items listed), object and begin one of code; end closes
    for w in words:
      let ww = w.strip(chars = {'(', ')', ';'})
      if ww in ["struct", "sig"]: stack.add (true, -1)
      elif ww in ["object", "begin"]: stack.add (false, -1)
      elif ww == "end":
        if stack.len > 0: discard stack.pop()

# ── the tools ──

proc mlHave(cmd: string): bool =
  ## whether the first word of the command line is a program that can be found (a ~ is expanded) — so a server or
  ## formatter that is set is only used when it is installed
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let mlServerSet = setting("server", "").strip
var mlServer: seq[string]
if mlServerSet == "off": discard
elif mlServerSet.len > 0:
  if mlHave(mlServerSet): mlServer = mlServerSet.splitWhitespace()
  else: echo "ocaml: the server " & mlServerSet & " is not installed (plugins.ocaml.server)"
elif findExe("ocamllsp").len > 0: mlServer = @["ocamllsp"]
if mlServer.len > 0:
  mlServer[0] = expandTilde(mlServer[0])
  languageServer("ocaml", mlServer)
else:
  symbols("ocaml") do (b: Buf) -> seq[Symbol]:
    mlSymbols(b.lines)

let mlFmtSet = setting("formatter", "").strip
if mlFmtSet == "off": discard
elif mlFmtSet.len > 0:
  if mlHave(mlFmtSet): formatter("ocaml", mlFmtSet)
  else: echo "ocaml: the formatter " & mlFmtSet & " is not installed (plugins.ocaml.formatter)"
elif findExe("ocamlformat").len > 0:
  # (it reads stdin with `-`; --name says which kind of file it is, .ml or .mli, and finds the project's settings)
  formatter("ocaml", "ocamlformat --enable-outside-detected-project --name \"$file\" -")
