## cmake — CMake: colours, comments, indentation, F5, snippets, an outline; neocmakelsp and gersemi
##
## Turn it on in the Plugins dock (AVAILABLE). It teaches ned CMake's files — CMakeLists.txt by its name, and
## `.cmake` scripts and modules: their colours (ned's generic lexer with CMake's words: if, foreach, function …
## and their end…, the commands, ALL-CAPS arguments and variables as constants, "strings" over several lines),
## `#` and `#[[ … ]]` comments, indentation inside `( … )` over several lines (endif, else, endforeach,
## endfunction … typed alone go back a level: ned cannot tell that the line after `if(…)` goes in), four spaces as
## gersemi writes, brackets and quotes that close themselves, snippets (project, exe, lib, link, find, if, foreach,
## function) and F5: the project configured and built — `cmake -S . -B build && cmake --build build` in its top
## folder (the highest one above the file with a CMakeLists.txt) — or, for a .cmake file, `cmake -P file`, the
## script run. Build (Alt+B) configures and builds the project the same way.
##
## Without a language server, the outline lists the file's project, options, targets (executables, libraries,
## custom targets) and its functions and macros, from a simple scan.
##
## The tools, when they are on PATH: neocmakelsp (`cargo install neocmakelsp`), or cmake-language-server (`pipx
## install cmake-language-server`) — completion, hover, go to definition, problems; gersemi formats (`pipx install
## gersemi`; Format document, and on save with editor.formatOnSave), or cmake-format (`pipx install cmakelang`)
## when gersemi is not installed — each with the project's settings (.gersemirc, .cmake-format.yaml).
##
## Settings (the Plugins dock › cmake › its settings; Plugins: reload after a change):
## - plugins.cmake.server — the language server's command, when it is neither of those ("off": none)
## - plugins.cmake.formatter — the formatter's command (the text on its stdin), when it is neither of those
import nedplugin
import std/strutils

requiresNed(">= 6.28")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("server", "", "The language server's command: empty for neocmakelsp stdio (or cmake-language-server) " &
           "when it is installed, \"off\" for none. Plugins: reload after a change")
settingDef("formatter", "", "The formatter's command, which reads the text on its stdin: empty for gersemi (or " &
           "cmake-format) when it is installed, \"off\" for none. Plugins: reload after a change")

# (the project's top folder: the CMakeLists.txt nearest the file, then up while the folder above has one too)
const CmakeTop = "d=\"$dir\"; while [ ! -f \"$d/CMakeLists.txt\" ] && [ \"$d\" != / ]; do d=$(dirname \"$d\"); " &
                 "done; while [ -f \"$(dirname \"$d\")/CMakeLists.txt\" ] && [ \"$d\" != / ]; do " &
                 "d=$(dirname \"$d\"); done; cd \"$d\" && cmake -S . -B build && exec cmake --build build"

language("cmake", LangSpec(
  name: "CMake",
  extensions: @["cmake"],
  files: @["CMakeLists.txt"],
  lineComment: "#",
  blockComment: @["#[[", "]]"],
  quotes: "\"",
  multilineStrings: true,
  capitalTypes: true,
  keywords: @["if", "elseif", "else", "endif", "foreach", "endforeach", "while", "endwhile", "function",
              "endfunction", "macro", "endmacro", "return", "break", "continue", "block", "endblock", "AND", "OR",
              "NOT"],
  constants: @["ON", "OFF", "TRUE", "FALSE", "YES", "NO"],
  builtins: @["set", "unset", "option", "project", "cmake_minimum_required", "add_executable", "add_library",
              "target_link_libraries", "target_include_directories", "target_compile_options",
              "target_compile_definitions", "target_compile_features", "target_sources", "find_package",
              "include", "add_subdirectory", "install", "message", "list", "string", "file", "math",
              "configure_file", "add_custom_command", "add_custom_target", "add_test", "enable_testing",
              "include_directories", "set_target_properties", "set_property", "get_property", "execute_process",
              "FetchContent_Declare", "FetchContent_MakeAvailable"],
  functionWords: @["function", "macro"],
  indentAfter: @["("],
  dedentWords: @["endif", "else", "elseif", "endforeach", "endwhile", "endfunction", "endmacro", "endblock"],
  dedent: ")",
  indentSize: 4,
  run: "sh -c 'case \"$file\" in *.cmake) exec cmake -P \"$file\" ;; esac; " & CmakeTop & "'",
  build: "sh -c '" & CmakeTop & "'",
  pairs: "()[]{}\"\""))

snippet("cmake", "project", "cmake_minimum_required(VERSION ${1:3.20})\nproject(${2:app} LANGUAGES ${3:CXX})\n\n" &
        "add_executable($2 ${4:main.cpp})$0", "a project")
snippet("cmake", "exe", "add_executable(${1:app} ${2:main.cpp})$0", "an executable")
snippet("cmake", "lib", "add_library(${1:name} ${2:STATIC} ${3:src.cpp})$0", "a library")
snippet("cmake", "link", "target_link_libraries(${1:app} PRIVATE ${2:lib})$0", "a target's libraries")
snippet("cmake", "find", "find_package(${1:Name} REQUIRED)$0", "a package")
snippet("cmake", "if", "if(${1:cond})\n\t$0\nendif()", "an if")
snippet("cmake", "foreach", "foreach(${1:item} IN LISTS ${2:items})\n\t$0\nendforeach()", "a foreach")
snippet("cmake", "function", "function(${1:name} ${2:arg})\n\t$0\nendfunction()", "a function")

# ── the outline, when there is no language server ──

func cmakeCode(s: string, closer: var string): string =
  ## the line with its comments, strings and [[bracket arguments]] made spaces (the columns kept) — `closer`: what
  ## ends the one that goes on below (`"`, `]]`, `]=]` …; "" none)
  result = s
  var i = 0
  while i < s.len:
    if closer.len > 0:
      if closer == "\"" and s[i] == '\\' and i + 1 < s.len:
        result[i] = ' '
        result[i + 1] = ' '
        i += 2
        continue
      if s.continuesWith(closer, i):
        for k in i ..< i + closer.len: result[k] = ' '
        i += closer.len
        closer = ""
        continue
      result[i] = ' '
      inc i
      continue
    let bracketAt = if s[i] == '#' and i + 1 < s.len and s[i + 1] == '[': i + 1
                    elif s[i] == '[': i
                    else: -1
    if bracketAt >= 0:
      # [[…]] or [=[…]=] — a bracket comment after #
      var k = bracketAt + 1
      while k < s.len and s[k] == '=': inc k
      if k < s.len and s[k] == '[':
        closer = "]" & repeat('=', k - bracketAt - 1) & "]"
        for j in i .. k: result[j] = ' '
        i = k + 1
        continue
    if s[i] == '#':
      for k in i ..< s.len: result[k] = ' '
      break
    if s[i] == '"':
      closer = "\""
      result[i] = ' '
    inc i

func cmakeFirstArg(s: string, at: int): string =
  ## the first argument from `at` in the raw line: a word, or a "quoted" one
  var a = at
  while a < s.len and s[a] in {' ', '\t'}: inc a
  if a >= s.len: return ""
  if s[a] == '"':
    let e = s.find('"', a + 1)
    return if e > a: s[a + 1 ..< e] else: ""
  var e = a
  while e < s.len and s[e] notin {' ', '\t', ')', '#'}: inc e
  s[a ..< e]

func cmakeSymbols*(lines: seq[string]): seq[Symbol] =
  ## the project, the options, the targets, the functions and macros (not what a function's body makes)
  var closer = ""
  var inBody = 0                       # function and macro bodies open
  var pending = ("", "", -1)           # a command whose first argument is on a line below: (kind, detail, line)
  for ln, s in lines:
    let code = cmakeCode(s, closer)
    let t = code.strip
    if t.len == 0: continue
    let col = code.len - code.strip(trailing = false).len
    if pending[2] >= 0:
      let name = cmakeFirstArg(s, col)
      if name.len > 0:
        result.add Symbol(name: name, kind: pending[0], detail: pending[1], line: ln, col: col)
      pending = ("", "", -1)
      continue
    var e = col
    while e < code.len and (code[e].isAlphaNumeric or code[e] == '_'): inc e
    var p = e
    while p < code.len and code[p] in {' ', '\t'}: inc p
    if e == col or p >= code.len or code[p] != '(': continue
    let cmd = code[col ..< e].toLowerAscii
    var kind, detail: string
    case cmd
    of "function", "macro":
      if inBody == 0:
        kind = "function"
        detail = cmd
      inc inBody
    of "endfunction", "endmacro":
      inBody = max(0, inBody - 1)
    of "project":
      kind = "module"
      detail = "project"
    of "option":
      kind = "constant"
      detail = "option"
    of "add_executable":
      kind = "class"
      detail = "executable"
    of "add_library":
      kind = "class"
      detail = "library"
    of "add_custom_target":
      kind = "class"
      detail = "custom target"
    else: discard
    if kind.len == 0 or (inBody > 0 and kind != "function"): continue
    let name = cmakeFirstArg(s, p + 1)
    if name.len > 0:
      result.add Symbol(name: name, kind: kind, detail: detail, line: ln, col: max(0, s.find(name, p)))
    else:
      pending = (kind, detail, ln)

# ── the tools ──

proc cmakeHave(cmd: string): bool =
  ## whether the first word of the command line is a program that can be found (a ~ is expanded) — so a server or
  ## formatter that is set is only used when it is installed
  let w = cmd.splitWhitespace()
  w.len > 0 and findExe(expandTilde(w[0])).len > 0

let cmakeServerSet = setting("server", "").strip
var cmakeServer: seq[string]
if cmakeServerSet == "off": discard
elif cmakeServerSet.len > 0:
  if cmakeHave(cmakeServerSet): cmakeServer = cmakeServerSet.splitWhitespace()
  else: echo "cmake: the server " & cmakeServerSet & " is not installed (plugins.cmake.server)"
else:
  # (neocmakelsp's README gives `neocmakelsp stdio`; older versions took --stdio)
  for cmd in ["neocmakelsp stdio", "cmake-language-server"]:
    if cmakeHave(cmd):
      cmakeServer = cmd.splitWhitespace()
      break
if cmakeServer.len > 0:
  cmakeServer[0] = expandTilde(cmakeServer[0])
  languageServer("cmake", cmakeServer)
else:
  symbols("cmake") do (b: Buf) -> seq[Symbol]:
    cmakeSymbols(b.lines)

let cmakeFmtSet = setting("formatter", "").strip
if cmakeFmtSet == "off": discard
elif cmakeFmtSet.len > 0:
  if cmakeHave(cmakeFmtSet): formatter("cmake", cmakeFmtSet)
  else: echo "cmake: the formatter " & cmakeFmtSet & " is not installed (plugins.cmake.formatter)"
else:
  # (`-`: the text from stdin, the formatted text to stdout — the form both document)
  for cmd in ["gersemi -", "cmake-format -"]:
    if cmakeHave(cmd):
      formatter("cmake", cmd)
      break
