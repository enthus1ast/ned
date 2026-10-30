## r — R: colours, comments, indentation, F5, snippets, an outline; R's languageserver and styler
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned R's `.R` and `.r` files (and .Rprofile): their colours
## (ned's generic lexer with R's words: TRUE, FALSE, NULL, NA … as constants, `is.na` and `data.frame` as one name,
## the base functions), `#` comments (`#'` roxygen's documentation), indentation after `{` `(` `[`, two spaces as
## styler writes, brackets and quotes that close themselves, snippets (fun, if, for, lapply, section, test) and F5:
## `Rscript file` — `testthat::test_file` for a file of a package's tests/testthat folder.
##
## The outline lists the file's code sections (`# Title ----`, as RStudio has them, `##` one level in), its
## top-level functions (`f <- function(x)`, `f = \(x)`) and classes (setClass, setRefClass, R6Class) and generics,
## from a simple scan.
##
## The tools are R packages, used when R (https://cran.r-project.org; Termux: `pkg install r-base`) and they are
## installed — `install.packages(c("languageserver", "styler"))`:
## - languageserver (completion, hover, definitions, its problems): it starts the first time you save an R file — R
##   and its packages take a few seconds to load, so only reading files costs nothing
## - styler formats (Format document, and on save with editor.formatOnSave), the tidyverse style
##
## Settings (the Plugins dock › r › its settings; Plugins: reload after a change):
## - plugins.r.server — the language server's command, when it is not R's languageserver ("off": none)
## - plugins.r.formatter — the formatter's command (the text on its stdin), when it is not styler's
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for R's languageserver package (when it is " &
           "installed; it starts when you first save an R file), \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for the styler " &
           "package (when it is installed), \"off\" for none. Plugins: reload after a change")

language("r", LangSpec(
  name: "R",
  extensions: @["r"],
  files: @[".Rprofile"],
  lineComment: "#",
  docComment: "#'",
  quotes: "\"'",
  nameChars: ".",
  keywords: @["if", "else", "repeat", "while", "function", "for", "in", "next", "break", "return"],
  constants: @["TRUE", "FALSE", "NULL", "NA", "NaN", "Inf", "NA_integer_", "NA_real_", "NA_character_",
               "NA_complex_"],
  builtins: @["c", "list", "library", "require", "print", "cat", "paste", "paste0", "length", "seq_along",
              "seq_len", "stop", "warning", "message", "invisible", "is.null", "is.na", "lapply", "sapply",
              "vapply", "apply", "data.frame", "matrix", "sum", "mean", "nrow", "ncol", "names", "sprintf",
              "match.arg", "stopifnot", "tryCatch", "on.exit"],
  indentAfter: @["{", "(", "["],
  dedent: "})]",
  indentSize: 2,
  run: "sh -c 'f=\"$file\"; case \"$f\" in */tests/testthat/*) " &
       "exec Rscript -e \"testthat::test_file(\\\"$f\\\")\" ;; esac; exec Rscript \"$f\"'",
  pairs: "()[]{}\"\""))

snippet("r", "fun", "${1:name} <- function(${2:x}) {\n\t$0\n}", "a function")
snippet("r", "if", "if (${1:cond}) {\n\t$0\n}", "an if")
snippet("r", "for", "for (${1:i} in ${2:seq_along(x)}) {\n\t$0\n}", "a for loop")
snippet("r", "lapply", "lapply(${1:xs}, function(${2:x}) {\n\t$0\n})", "lapply with a function")
snippet("r", "section", "# ${1:Section} ----\n$0", "a code section (the outline lists it)")
snippet("r", "test", "test_that(\"${1:what}\", {\n\texpect_equal(${2:x}, ${3:1})$0\n})", "a test (testthat)")

# ── the outline ──

func rCode(s: string, quote: var char): string =
  ## the line with its comments and strings made spaces (the columns kept) — `quote`: the quote of a string that
  ## goes on below ('\0' none: R's strings may hold new lines)
  result = s
  var i = 0
  while i < s.len:
    if quote != '\0':
      if s[i] == '\\' and i + 1 < s.len:
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      if s[i] == quote: quote = '\0'
      result[i] = ' '
      inc i
      continue
    if s[i] == '#':
      for k in i ..< s.len: result[k] = ' '
      break
    if s[i] in {'"', '\''}:
      quote = s[i]
      result[i] = ' '
    elif s[i] == '`':
      # a name in backquotes (`%+%`, `my var`): kept, its quotes and #s are not one
      let e = s.find('`', i + 1)
      i = if e < 0: s.len else: e + 1
      continue
    inc i

func rSection(s: string): (int, string) =
  ## a code section's level (from 1) and title: `## Title ----` (four or more -, = or # at its end) — (0, "") none
  let t = s.strip
  if not t.startsWith("#") or t.startsWith("#'"): return (0, "")
  var h = 0
  while h < t.len and t[h] == '#': inc h
  var e = t.len
  while e > h and t[e - 1] in {'-', '=', '#'}: dec e
  if t.len - e < 4: return (0, "")
  let title = t[h ..< e].strip
  if title.len == 0: return (0, "")
  (h, title)

func rNameEnd(s: string, i: int): int =
  ## where the name that starts at i ends: a `backticked` name to its closing backtick, else letters, digits, _ and .
  result = i
  if i < s.len and s[i] == '`':
    let e = s.find('`', i + 1)
    return if e < 0: s.len else: e + 1
  while result < s.len and (s[result].isAlphaNumeric or s[result] in {'_', '.'}): inc result

func rParams(s: string, at: int): string =
  ## the parameters at `(` (up to its `)`, on this line)
  if at >= s.len or s[at] != '(': return ""
  var dp = 0
  for k in at ..< s.len:
    if s[k] == '(': inc dp
    elif s[k] == ')':
      dec dp
      if dp == 0: return s[at .. k]
  s[at .. ^1]

func rFirstString(s: string, at: int): string =
  ## the first "string" (or 'string') of s from `at`: setClass("Circle", …) → Circle
  for k in at ..< s.len:
    if s[k] in {'"', '\''}:
      let e = s.find(s[k], k + 1)
      if e > k: return s[k + 1 ..< e]
      return ""
  ""

func rSymbols*(lines: seq[string]): seq[Symbol] =
  ## the code sections, the top-level functions, classes and generics (functions made inside a function's braces
  ## left out)
  var quote = '\0'
  var level = 0
  var secDepth = -1                    # the last section's depth (-1: none yet)
  for ln, s in lines:
    let inString = quote != '\0'
    let code = rCode(s, quote)
    let t = code.strip
    let col = code.len - code.strip(trailing = false).len
    let depth = secDepth + 1
    if not inString and level == 0:
      let (h, title) = rSection(s)
      if h > 0:
        secDepth = h - 1
        result.add Symbol(name: title, kind: "section", line: ln, col: s.find(title), depth: secDepth)
      elif t.len > 0:
        let e = rNameEnd(t, 0)
        var k = e
        while k < t.len and t[k] == ' ': inc k
        var op = ""
        for o in ["<<-", "<-", "="]:
          if t.continuesWith(o, k) and not t.continuesWith("==", k):
            op = o
            break
        if e > 0 and op.len > 0:
          var name = t[0 ..< e]
          if name.startsWith("`"): name = name.strip(chars = {'`'})
          var v = k + op.len
          while v < t.len and t[v] == ' ': inc v
          let value = t[v .. ^1]
          if value.startsWith("function") or value.startsWith("\\("):
            let p = if value.startsWith("\\("): 1 else: value.find('(')
            result.add Symbol(name: name, kind: "function", detail: rParams(value, max(0, p)), line: ln,
                              col: col, depth: depth)
          else:
            for cls in ["setRefClass(", "R6Class(", "setClass("]:
              if value.startsWith(cls) or value.startsWith("R6::" & cls) or value.startsWith("methods::" & cls):
                result.add Symbol(name: name, kind: "class", detail: cls[0 ..< cls.len - 1], line: ln, col: col,
                                  depth: depth)
                break
        else:
          for (fn, kind) in [("setClass(", "class"), ("setGeneric(", "function"), ("setMethod(", "method")]:
            if t.startsWith(fn) or t.startsWith("methods::" & fn):
              let st = s.strip(trailing = false)
              let name = rFirstString(st, 0)
              if name.len > 0:
                result.add Symbol(name: name, kind: kind, detail: fn[0 ..< fn.len - 1], line: ln,
                                  col: max(0, s.find(name)), depth: depth)
              break
    for c in code:
      if c in {'{', '(', '['}: inc level
      elif c in {'}', ')', ']'}: level = max(0, level - 1)

# ── the tools: R's packages, when R and they are installed ──

proc rWords*(cmd: string): seq[string] =
  ## a command line's words, as a shell splits it: `R -e "languageserver::run()"` is three
  var cur = ""
  var inWord = false
  var q = '\0'
  var i = 0
  while i < cmd.len:
    let c = cmd[i]
    if q != '\0':
      if c == q: q = '\0'
      elif c == '\\' and q == '"' and i + 1 < cmd.len and cmd[i + 1] in {'"', '\\', '$', '`'}:
        inc i
        cur.add cmd[i]
      else: cur.add c
    elif c in {'"', '\''}:
      q = c
      inWord = true
    elif c == '\\' and i + 1 < cmd.len:
      inc i
      cur.add cmd[i]
      inWord = true
    elif c in {' ', '\t'}:
      if inWord: result.add cur
      cur = ""
      inWord = false
    else:
      cur.add c
      inWord = true
    inc i
  if inWord: result.add cur

proc rHave(cmd: string): bool =
  ## whether the first word of the command line is a program that can be found (a ~ is expanded) — so a server or
  ## formatter that is set is only used when it is installed
  let w = rWords(cmd)
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

proc rSubDirs(d: string): seq[string] =
  ## the folders directly inside d, as full paths
  when defined(nimscript):
    result = listDirs(d)
  else:
    for k, p in walkDir(d):
      if k in {pcDir, pcLinkToDir}: result.add p

proc rLibraries(): seq[string] =
  ## where R keeps its packages: R_LIBS, R_LIBS_USER, R_LIBS_SITE; the user's library (~/R/<platform>/<version>,
  ## macOS's ~/Library/R/<arch>/<version>/library); the system's — and R's own, beside the R found on PATH
  for v in ["R_LIBS", "R_LIBS_USER", "R_LIBS_SITE"]:
    for d in getEnv(v).split({':', ';'}):
      # (a pattern — %v, R's version — is R's to fill in: the folders below are looked through instead)
      if d.strip.len > 0 and '%' notin d: result.add expandTilde(d.strip)
  for p in rSubDirs(expandTilde("~/R")):
    for v in rSubDirs(p): result.add v
  for p in rSubDirs(expandTilde("~/Library/R")):
    for v in rSubDirs(p): result.add v & "/library"
  let r = findExe("R")
  if r.len > 0:
    let prefix = parentDir(parentDir(r))
    for sub in ["lib/R/library", "lib/R/site-library", "lib64/R/library"]:
      result.add prefix & "/" & sub
  for d in ["/usr/lib/R/library", "/usr/lib/R/site-library", "/usr/local/lib/R/site-library",
            "/usr/local/lib/R/library", "/usr/lib64/R/library", "/usr/share/R/library",
            "/Library/Frameworks/R.framework/Resources/library"]:
    result.add d
  for root in ["/opt/homebrew/lib/R", "/usr/local/lib/R"]:
    for v in rSubDirs(root): result.add v & "/site-library"

proc rHasPackage(name: string): bool =
  ## whether the R package is installed: a folder of that name with a DESCRIPTION file in one of R's libraries
  for d in rLibraries():
    if fileExists(d & "/" & name & "/DESCRIPTION"): return true

let rServerSet = setting("server", "").strip
if rServerSet.len > 0 and rServerSet != "off":
  if rHave(rServerSet):
    var cmd = rWords(rServerSet)
    cmd[0] = expandTilde(cmd[0])
    # (R itself starting, the languageserver package or another: slow — any other server starts with the file)
    languageServer("r", cmd, afterSave = extractFilename(cmd[0]) in ["R", "Rscript"])
  else: echo "r: the server " & rServerSet & " is not installed (plugins.r.server)"
elif rServerSet.len == 0 and findExe("R").len > 0 and rHasPackage("languageserver"):
  # (the form languageserver's README gives; R starts and loads it — a few seconds, so not until the first save)
  languageServer("r", @["R", "--slave", "-e", "languageserver::run()"], afterSave = true)
# (the outline from the scan, server or not: the same before the server has started as after)
symbols("r") do (b: Buf) -> seq[Symbol]:
  rSymbols(b.lines)

let rFmtSet = setting("formatter", "").strip
if rFmtSet == "off": discard
elif rFmtSet.len > 0:
  if rHave(rFmtSet): formatter("r", rFmtSet)
  else: echo "r: the formatter " & rFmtSet & " is not installed (plugins.r.formatter)"
elif findExe("Rscript").len > 0 and rHasPackage("styler"):
  # (the text from stdin, styled, to stdout; warn = FALSE: no warning for a last line with no new line)
  formatter("r", "Rscript -e 'writeLines(styler::style_text(readLines(file(\"stdin\"), warn = FALSE)))'")
