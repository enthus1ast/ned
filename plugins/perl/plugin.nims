## perl — Perl: colours, comments, indentation, F5, snippets, an outline; Perl Navigator and perltidy
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned Perl's `.pl`, `.pm`, `.t` and `.psgi` files (and
## cpanfile): their colours (ned's generic lexer with Perl's words: my, our, sub, package, unless, foreach, qw …,
## the built-in functions, Capitalised packages as types, STDIN and other ALL-CAPS names as constants), `#` comments
## and POD (`=pod` or `=head1` … `=cut`) in the documentation's colour, indentation after `{` `(` `[`, four
## spaces as perltidy writes, brackets and quotes that close themselves, snippets (sub, package, if, foreach,
## while, open, test) and F5: `perl -Ilib file` in its project's folder (the one with Makefile.PL, Build.PL,
## dist.ini or cpanfile above the file; else the file's), `prove -lv file` for a test (.t).
##
## Without a language server, the outline lists the file's packages (and 5.38's classes) with their subs, methods
## and attributes (Moose's and Moo's `has`, `field`) under them, and its `use constant`s, from a simple scan.
##
## The tools, when they are on PATH: Perl Navigator (`npm install -g perlnavigator-server`), or Perl::LanguageServer
## (`cpanm Perl::LanguageServer`, found in Perl's libraries) — completion, hover, go to definition, problems;
## perltidy formats (`cpanm Perl::Tidy`; Format document, and on save with editor.formatOnSave), with the project's
## .perltidyrc.
##
## Settings (the Plugins dock › perl › its settings; Plugins: reload after a change):
## - plugins.perl.server — the language server's command, when it is neither of those ("off": none)
## - plugins.perl.formatter — the formatter's command (the text on its stdin), when it is not perltidy
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "MIT")

settingDef("server", "", "The language server's command: empty for perlnavigator --stdio (or Perl::LanguageServer) " &
           "when it is installed, \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for perltidy (when " &
           "it is installed), \"off\" for none. Plugins: reload after a change")

language("perl", LangSpec(
  name: "Perl",
  extensions: @["pl", "pm", "t", "psgi"],
  files: @["cpanfile"],
  lineComment: "#",
  # (POD: from a line =pod, =head1 … to =cut — the generic lexer has two such blocks, these are the usual starts)
  blockComment: @["=pod", "=cut"],
  docBlockComment: @["=head1", "=cut"],
  quotes: "\"'`",
  capitalTypes: true,
  # (no one-letter words — q, s, m, y, x: they would colour $x and $s)
  keywords: @["my", "our", "local", "state", "sub", "package", "use", "no", "require", "if", "elsif", "else",
              "unless", "while", "until", "for", "foreach", "do", "last", "next", "redo", "goto", "return", "and",
              "or", "not", "xor", "eq", "ne", "lt", "gt", "le", "ge", "cmp", "qw", "qq", "qr", "tr", "BEGIN", "END",
              "class", "method", "field"],
  constants: @["__PACKAGE__", "__FILE__", "__LINE__", "__DATA__", "__END__", "__SUB__", "STDIN", "STDOUT",
               "STDERR"],
  builtins: @["print", "printf", "say", "die", "warn", "eval", "defined", "undef", "ref", "bless", "push", "pop",
              "shift", "unshift", "splice", "keys", "values", "each", "exists", "delete", "scalar", "join", "split",
              "map", "grep", "sort", "reverse", "length", "substr", "index", "sprintf", "lc", "uc", "chomp", "chop",
              "open", "close", "binmode", "wantarray", "time", "sleep", "exit", "system", "exec"],
  functionWords: @["sub", "method"],
  classWords: @["package", "class"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 4,
  run: "sh -c 'f=\"$file\"; d=\"$dir\"; while [ \"$d\" != / ] && [ ! -f \"$d/Makefile.PL\" ] && " &
       "[ ! -f \"$d/Build.PL\" ] && [ ! -f \"$d/dist.ini\" ] && [ ! -f \"$d/cpanfile\" ]; do d=$(dirname \"$d\"); " &
       "done; [ \"$d\" = / ] && d=\"$dir\"; cd \"$d\"; case \"$f\" in *.t) exec prove -lv \"$f\" ;; esac; " &
       "exec perl -Ilib \"$f\"'",
  # (no check on save: `perl -c` runs the file's BEGIN blocks and the code of what it uses)
  pairs: "()[]{}\"\""))

# (Perl's own $0 $1 …, ${…}: none in these — a snippet takes them for its places)
snippet("perl", "sub", "sub ${1:name} {\n\tmy (${2:$self}) = @_;\n\t$0\n}", "a sub")
snippet("perl", "package", "package ${1:My::Module};\n\nuse strict;\nuse warnings;\n\n$0\n\n1;", "a module")
snippet("perl", "if", "if (${1:cond}) {\n\t$0\n}", "an if")
snippet("perl", "foreach", "foreach my ${1:$item} (${2:@items}) {\n\t$0\n}", "a foreach loop")
snippet("perl", "while", "while (${1:cond}) {\n\t$0\n}", "a while loop")
snippet("perl", "open", "open(my ${1:$fh}, '${2:<}', ${3:$path}) or die \"cannot open $3: $!\";$0", "a file opened")
snippet("perl", "test", "use strict;\nuse warnings;\nuse Test::More;\n\nok(${1:1}, '${2:what}');\n$0\n\n" &
        "done_testing();", "a test file (Test::More)")

# ── the outline, when there is no language server ──

func perlCode(s: string): string =
  ## the line with its comments and strings made spaces (the columns kept); `$#array` is not a comment
  result = s
  var i = 0
  while i < s.len:
    if s[i] == '#' and (i == 0 or s[i - 1] != '$'):
      for k in i ..< s.len: result[k] = ' '
      break
    if s[i] == '\\' and i + 1 < s.len:
      i += 2
      continue
    if s[i] in {'"', '\''} and (i == 0 or s[i - 1] notin {'$', '@', '%'}):
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

func perlHeredoc(s: string): string =
  ## the word that ends a <<"EOF", <<'EOF', <<EOF or <<~EOF text the line starts ("" none)
  var i = s.find("<<")
  while i >= 0:
    var k = i + 2
    if k < s.len and s[k] == '~': inc k
    if k < s.len and s[k] in {'"', '\''}:
      let e = s.find(s[k], k + 1)
      if e > k + 1: return s[k + 1 ..< e]
    elif k < s.len and (s[k].isAlphaAscii or s[k] == '_'):
      var e = k
      while e < s.len and (s[e].isAlphaNumeric or s[e] == '_'): inc e
      return s[k ..< e]
    i = s.find("<<", i + 2)
  ""

func perlName(s: string, i: int): int =
  ## where the (package) name at i ends: Foo::Bar, name
  result = i
  while result < s.len and (s[result].isAlphaNumeric or s[result] == '_' or s.continuesWith("::", result)):
    if s[result] == ':': inc result
    inc result

func perlSymbols*(lines: seq[string]): seq[Symbol] =
  ## the packages and classes with their subs, methods and attributes; the constants — POD, heredocs and what
  ## follows __END__ left out
  var pod = false
  var heredoc = ""
  var inPackage = false
  for ln, s in lines:
    if heredoc.len > 0:
      if s.strip == heredoc: heredoc = ""
      continue
    if pod:
      if s.startsWith("=cut"): pod = false
      continue
    if s.len > 1 and s[0] == '=' and s[1].isAlphaAscii:
      pod = not s.startsWith("=cut")
      continue
    let t0 = s.strip
    if t0 == "__END__" or t0 == "__DATA__": break
    let code = perlCode(s)
    # (a heredoc's word from the raw line: the code has its "EOF" made spaces)
    heredoc = if "<<" in code: perlHeredoc(s[code.find("<<") .. ^1]) else: ""
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    let depth = if inPackage: 1 else: 0
    let words = t.splitWhitespace()
    let first = words[0]
    case first
    of "package", "class":
      let a = first.len + 1
      let e = perlName(t, a)
      if e > a:
        result.add Symbol(name: t[a ..< e], kind: (if first == "class": "class" else: "module"), detail: first,
                          line: ln, col: col + a)
        inPackage = true
    of "sub", "method":
      let a = first.len + 1
      let e = perlName(t, a)
      if e > a:
        var detail = if first == "method": "method" else: ""
        var k = e
        while k < t.len and t[k] == ' ': inc k
        if k < t.len and t[k] == '(':
          let c = s.find(')', col + k)
          if c > 0: detail = s[col + k .. c]
        result.add Symbol(name: t[a ..< e], kind: (if first == "method": "method" else: "function"),
                          detail: detail, line: ln, col: col + a, depth: depth)
    of "has", "field":
      # has side => (…), has 'label' => (…), has '+name' — field $count
      let raw = s.strip
      var a = first.len
      while a < raw.len and raw[a] in {' ', '\'', '"', '+', '$', '@', '%'}: inc a
      var e = a
      while e < raw.len and (raw[e].isAlphaNumeric or raw[e] == '_'): inc e
      if e > a:
        result.add Symbol(name: raw[a ..< e], kind: "property", detail: first, line: ln, col: col + a, depth: depth)
    of "use":
      if words.len > 2 and words[1] == "constant":
        let raw = s.strip
        let a = raw.find("constant") + 9
        var k = a
        while k < raw.len and raw[k] in {' ', '{'}: inc k
        var e = k
        while e < raw.len and (raw[e].isAlphaNumeric or raw[e] == '_'): inc e
        if e > k:
          result.add Symbol(name: raw[k ..< e], kind: "constant", detail: "use constant", line: ln, col: col + k,
                            depth: depth)
    else: discard

# ── the tools ──

proc perlHave(cmd: string): bool =
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

proc perlSubDirs(d: string): seq[string] =
  when defined(nimscript):
    result = listDirs(d)
  else:
    for k, p in walkDir(d):
      if k in {pcDir, pcLinkToDir}: result.add p

proc perlHasModule(file: string): bool =
  ## is the module (Perl/LanguageServer.pm) in one of Perl's libraries: PERL5LIB's, local::lib's (~/perl5), the
  ## system's site and vendor folders (and their version folders), the ones beside the perl on PATH?
  var dirs: seq[string]
  for v in ["PERL5LIB", "PERLLIB"]:
    for d in getEnv(v).split({':', ';'}):
      if d.strip.len > 0: dirs.add expandTilde(d.strip)
  dirs.add expandTilde("~/perl5/lib/perl5")
  var roots = @["/usr/local/share/perl", "/usr/share/perl5", "/usr/share/perl", "/usr/local/lib/site_perl",
                "/usr/local/lib/perl5/site_perl", "/usr/lib/perl5/site_perl", "/usr/lib/perl5/vendor_perl",
                "/usr/share/perl5/vendor_perl", "/opt/homebrew/lib/perl5/site_perl", "/Library/Perl"]
  let perl = findExe("perl")
  if perl.len > 0:
    # (perlbrew's, plenv's, Termux's: lib/perl5/site_perl/<version> beside the bin folder)
    let prefix = parentDir(parentDir(perl))
    roots.add prefix & "/lib/perl5/site_perl"
    roots.add prefix & "/lib/site_perl"
    roots.add prefix & "/lib/perl5"
  for r in roots:
    dirs.add r
    for v in perlSubDirs(r): dirs.add v
  for d in dirs:
    if fileExists(d & "/" & file): return true

let perlServerSet = setting("server", "").strip
var perlServer: seq[string]
if perlServerSet == "off": discard
elif perlServerSet.len > 0:
  if perlHave(perlServerSet): perlServer = perlServerSet.splitWhitespace()
  else: echo "perl: the server " & perlServerSet & " is not installed (plugins.perl.server)"
elif findExe("perlnavigator").len > 0: perlServer = @["perlnavigator", "--stdio"]
elif findExe("perl").len > 0 and perlHasModule("Perl/LanguageServer.pm"):
  # (the command Perl::LanguageServer's documentation gives)
  perlServer = @["perl", "-MPerl::LanguageServer", "-e", "Perl::LanguageServer::run"]
if perlServer.len > 0:
  perlServer[0] = expandTilde(perlServer[0])
  languageServer("perl", perlServer)
else:
  symbols("perl") do (b: Buf) -> seq[Symbol]:
    perlSymbols(b.lines)

let perlFmtSet = setting("formatter", "").strip
if perlFmtSet == "off": discard
elif perlFmtSet.len > 0:
  if perlHave(perlFmtSet): formatter("perl", perlFmtSet)
  else: echo "perl: the formatter " & perlFmtSet & " is not installed (plugins.perl.formatter)"
elif findExe("perltidy").len > 0:
  # (no file: it reads stdin; -st the result to stdout, -se its errors to stderr — not to a perltidy.ERR file)
  formatter("perl", "perltidy -st -se")
