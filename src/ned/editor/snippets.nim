# ════════════════════════════════════════════════════════════════════════════
#  Snippets (Tab expands; Tab / Shift+Tab walk the placeholders; same-number
#  placeholders are edited together with multiple cursors)
# ════════════════════════════════════════════════════════════════════════════

const Snippets = [
  # Nim
  ("nim", "proc", "procedure", "proc ${1:name}*(${2:x: int}): ${3:int} =\n\t${0:result = x}"),
  ("nim", "func", "side-effect free proc", "func ${1:name}*(${2:x: int}): ${3:int} =\n\t${0:x}"),
  ("nim", "iter", "iterator", "iterator ${1:items}*(${2:x: T}): ${3:T} =\n\t${0:yield x}"),
  ("nim", "tmpl", "template", "template ${1:name}*(${2:body: untyped}): untyped =\n\t${0:body}"),
  ("nim", "macro", "macro", "macro ${1:name}*(${2:body: untyped}): untyped =\n\tresult = newStmtList()\n\t${0:echo body.treeRepr}"),
  ("nim", "type", "object type", "type\n\t${1:Name}* = object\n\t\t${2:field}*: ${3:int}$0"),
  ("nim", "ref", "ref object type", "type\n\t${1:Name}* = ref object\n\t\t${2:field}*: ${3:int}$0"),
  ("nim", "enum", "enum type", "type\n\t${1:Color}* = enum\n\t\t${2:red}, ${3:green}, ${4:blue}$0"),
  ("nim", "case", "case statement", "case ${1:x}\nof ${2:value}:\n\t${3:discard}\nelse:\n\t${0:discard}"),
  ("nim", "for", "for loop", "for ${1:item} in ${2:items}:\n\t${0:echo $1}"),
  ("nim", "fori", "counting loop", "for ${1:i} in 0 ..< ${2:n}:\n\t${0:echo $1}"),
  ("nim", "while", "while loop", "while ${1:cond}:\n\t${0:discard}"),
  ("nim", "if", "if", "if ${1:cond}:\n\t${0:discard}"),
  ("nim", "ife", "if / else", "if ${1:cond}:\n\t${2:discard}\nelse:\n\t${0:discard}"),
  ("nim", "when", "compile-time when", "when ${1:defined(release)}:\n\t${0:discard}"),
  ("nim", "main", "when isMainModule", "when isMainModule:\n\t${0:echo \"hello\"}"),
  ("nim", "try", "try / except", "try:\n\t${1:discard}\nexcept ${2:CatchableError} as e:\n\t${0:echo e.msg}"),
  ("nim", "block", "labelled block", "block ${1:label}:\n\t${0:discard}"),
  ("nim", "test", "unittest suite", "suite \"${1:name}\":\n\ttest \"${2:works}\":\n\t\t${0:check true}"),
  ("nim", "imp", "import std modules", "import std/[${0:strutils, sequtils, tables}]"),
  ("nim", "concept", "concept", "type\n\t${1:Comparable} = concept x, y\n\t\t${0:(x < y) is bool}"),
  ("nim", "async", "async proc", "proc ${1:name}() {.async.} =\n\t${0:await sleepAsync(100)}"),
  ("nim", "obj", "object constructor", "${1:Name}(${2:field}: ${0:value})"),
  ("nim", "fmt", "strformat string", "fmt\"${0:{x}}\""),
  ("nim", "doc", "doc comment block", "##[\n${0:Documentation}\n]##"),
  ("nim", "push", "push/pop pragma", "{.push ${1:inline}.}\n$0\n{.pop.}"),
  ("nim", "task", "nimble task", "task ${1:name}, \"${2:description}\":\n\t${0:exec \"nim c -r src/main.nim\"}"),
  ("nim", "mainp", "main proc + isMainModule", "proc main() =\n\t${0:echo \"hello\"}\n\nwhen isMainModule:\n\tmain()"),
  ("nim", "dist", "distinct type", "type ${1:Meters}* = distinct ${2:float}$0"),
  ("nim", "tup", "named tuple type", "type ${1:Point}* = tuple[${2:x, y}: ${3:int}]$0"),
  ("nim", "exc", "custom exception", "type ${1:ParseError}* = object of ${2:CatchableError}$0"),
  ("nim", "raise", "raise newException", "raise newException(${1:ValueError}, ${0:\"message\"})"),
  ("nim", "conv", "converter", "converter ${1:toInt}*(${2:x: MyType}): ${3:int} = ${0:int(x)}"),
  ("nim", "meth", "method", "method ${1:name}*(${2:self: Base}) {.base.} =\n\t${0:discard}"),
  ("nim", "seq", "new seq", "var ${1:xs} = newSeq[${2:int}](${0})"),
  ("nim", "tbl", "table", "var ${1:t} = initTable[${2:string}, ${3:int}]()$0"),
  ("nim", "defer", "defer", "defer: ${0:close(f)}"),
  ("nim", "assert", "doAssert", "doAssert ${1:cond}, ${0:\"message\"}"),
  ("nim", "importc", "C function import", "proc ${1:puts}(${2:s: cstring}): ${3:cint} {.importc, header: \"${4:<stdio.h>}\".}$0"),
  ("nim", "exportc", "export to C", "proc ${1:name}*(${2}): ${3:cint} {.exportc, dynlib.} =\n\t${0:0}"),
  ("nim", "bench", "time a block", "import std/[monotimes, times]\nlet t0 = getMonoTime()\n${1:work()}\necho \"took \", getMonoTime() - t0$0"),
  ("nim", "cli", "command line loop", "import std/parseopt\nfor kind, key, val in getopt():\n\tcase kind\n\tof cmdArgument: ${1:echo key}\n\tof cmdLongOption, cmdShortOption: ${2:echo key, \"=\", val}\n\tof cmdEnd: discard$0"),
  ("nim", "json", "parse JSON", "import std/json\nlet ${1:j} = parseJson(${2:text})\necho $1[\"${3:key}\"]$0"),
  ("nim", "http", "HTTP GET", "import std/httpclient\nlet client = newHttpClient()\ndefer: client.close()\necho client.getContent(\"${1:https://example.com}\")$0"),
  ("nim", "rf", "read a file", "let ${1:text} = readFile(\"${2:input.txt}\")$0"),
  ("nim", "lines", "for each line of a file", "for ${1:line} in lines(\"${2:input.txt}\"):\n\t${0:echo $1}"),
  # Python
  ("python", "def", "function", "def ${1:name}(${2:args}):\n\t${0:pass}"),
  ("python", "class", "class", "class ${1:Name}:\n\tdef __init__(self${2:, value}):\n\t\t${0:self.value = value}"),
  ("python", "main", "main guard", "if __name__ == \"__main__\":\n\t${0:main()}"),
  ("python", "for", "for loop", "for ${1:item} in ${2:items}:\n\t${0:print($1)}"),
  ("python", "if", "if", "if ${1:cond}:\n\t${0:pass}"),
  ("python", "try", "try / except", "try:\n\t${1:pass}\nexcept ${2:Exception} as e:\n\t${0:print(e)}"),
  ("python", "with", "with open", "with open(${1:\"file.txt\"}) as ${2:f}:\n\t${0:data = $2.read()}"),
  # C / C++
  ("c", "main", "main()", "#include <stdio.h>\n\nint main(void) {\n\t${0:printf(\"hello\\n\");}\n\treturn 0;\n}"),
  ("c", "for", "for loop", "for (int ${1:i} = 0; $1 < ${2:n}; $1++) {\n\t$0\n}"),
  ("c", "if", "if", "if (${1:cond}) {\n\t$0\n}"),
  ("c", "while", "while", "while (${1:cond}) {\n\t$0\n}"),
  ("c", "struct", "typedef struct", "typedef struct {\n\t${1:int x;}\n} ${0:Name};"),
  ("c", "inc", "#include", "#include <${0:stdlib.h}>"),
  ("c", "fn", "function", "${1:int} ${2:name}(${3:void}) {\n\t$0\n}"),
  ("cpp", "main", "main()", "#include <iostream>\n\nint main() {\n\t${0:std::cout << \"hello\\n\";}\n\treturn 0;\n}"),
  ("cpp", "for", "range for", "for (auto& ${1:x} : ${2:xs}) {\n\t$0\n}"),
  ("cpp", "class", "class", "class ${1:Name} {\npublic:\n\t$1();\n\t$0\n};"),
  ("cpp", "inc", "#include", "#include <${0:vector}>"),
  # JavaScript / TypeScript
  ("javascript", "fn", "function", "function ${1:name}(${2}) {\n\t$0\n}"),
  ("javascript", "afn", "arrow function", "const ${1:name} = (${2}) => {\n\t$0\n};"),
  ("javascript", "log", "console.log", "console.log(${0});"),
  ("javascript", "for", "for…of", "for (const ${1:x} of ${2:xs}) {\n\t$0\n}"),
  ("javascript", "if", "if", "if (${1:cond}) {\n\t$0\n}"),
  ("javascript", "class", "class", "class ${1:Name} {\n\tconstructor(${2}) {\n\t\t$0\n\t}\n}"),
  ("javascript", "imp", "import", "import { ${2} } from \"${1:module}\";"),
  ("typescript", "fn", "function", "function ${1:name}(${2}): ${3:void} {\n\t$0\n}"),
  ("typescript", "afn", "arrow function", "const ${1:name} = (${2}): ${3:void} => {\n\t$0\n};"),
  ("typescript", "log", "console.log", "console.log(${0});"),
  ("typescript", "int", "interface", "interface ${1:Name} {\n\t${0:field: string;}\n}"),
  ("typescript", "for", "for…of", "for (const ${1:x} of ${2:xs}) {\n\t$0\n}"),
  # Rust
  ("rust", "fn", "function", "fn ${1:name}(${2}) -> ${3:()} {\n\t$0\n}"),
  ("rust", "main", "main()", "fn main() {\n\t${0:println!(\"hello\");}\n}"),
  ("rust", "struct", "struct", "#[derive(Debug, Clone)]\nstruct ${1:Name} {\n\t${0:field: i32,}\n}"),
  ("rust", "impl", "impl block", "impl ${1:Name} {\n\t$0\n}"),
  ("rust", "enum", "enum", "#[derive(Debug)]\nenum ${1:Name} {\n\t${0:A, B}\n}"),
  ("rust", "match", "match", "match ${1:x} {\n\t${2:_} => ${0:{}},\n}"),
  ("rust", "test", "unit test", "#[test]\nfn ${1:it_works}() {\n\t${0:assert_eq!(2 + 2, 4);}\n}"),
  ("rust", "pl", "println!", "println!(\"{}\", ${0});"),
  # Go
  ("go", "main", "main package", "package main\n\nimport \"fmt\"\n\nfunc main() {\n\t${0:fmt.Println(\"hello\")}\n}"),
  ("go", "func", "function", "func ${1:name}(${2}) ${3:error} {\n\t$0\n}"),
  ("go", "iferr", "if err != nil", "if err != nil {\n\t${0:return err}\n}"),
  ("go", "for", "range loop", "for ${1:_}, ${2:v} := range ${3:xs} {\n\t$0\n}"),
  # HTML
  ("html", "html5", "HTML5 page", "<!DOCTYPE html>\n<html lang=\"en\">\n<head>\n\t<meta charset=\"utf-8\">\n\t<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n\t<title>${1:Title}</title>\n\t<link rel=\"stylesheet\" href=\"${2:style.css}\">\n</head>\n<body>\n\t$0\n</body>\n</html>"),
  ("html", "div", "div", "<div class=\"${1}\">$0</div>"),
  ("html", "a", "link", "<a href=\"${1:#}\">$0</a>"),
  ("html", "img", "image", "<img src=\"${1}\" alt=\"${0}\">"),
  ("html", "script", "script tag", "<script src=\"${1:main.js}\"></script>$0"),
  ("html", "ul", "list", "<ul>\n\t<li>$0</li>\n</ul>"),
  ("html", "btn", "button", "<button type=\"${1:button}\">$0</button>"),
  # Shell
  ("shellscript", "sh", "bash script header", "#!/usr/bin/env bash\nset -euo pipefail\n\n$0"),
  ("shellscript", "if", "if", "if [ ${1:-n \"$x\"} ]; then\n\t$0\nfi"),
  ("shellscript", "for", "for loop", "for ${1:f} in ${2:*}; do\n\t${0:echo \"$$1\"}\ndone"),
  ("shellscript", "fn", "function", "${1:name}() {\n\t$0\n}"),
]

proc snippetList(langId: string): seq[(string, string, string)] =
  ## (prefix, description, body): yours first (they win), then the built-in ones
  for (l, k, d, body) in cfgUserSnippets:
    if l == langId or l == "*": result.add (k, d, body)
  for (l, k, d, body) in plugSnippets:              # (the plugins': after yours)
    if l == langId or l == "*":
      var dup = false
      for x in result:
        if x[0] == k: dup = true
      if not dup: result.add (k, d, body)
  for (l, k, d, body) in Snippets:
    if l == langId:
      var dup = false
      for x in result:
        if x[0] == k: dup = true
      if not dup: result.add (k, d, body)

proc snippetFor(b: Buffer, key: string): string =
  for (k, d, body) in snippetList(b.lang.id):
    if k == key: return body
  ""

proc snippetItems(b: Buffer, prefix: string): seq[CompItem] =
  if prefix.len == 0: return
  let lp = prefix.toLowerAscii
  for (k, d, body) in snippetList(b.lang.id):
    if k.toLowerAscii.startsWith(lp):
      result.add CompItem(label: k, insert: k, filter: k, sortText: k, kind: 15, detail: d, snippet: body)

proc activateStop(b: Buffer, idx: int) =
  var cs: seq[Cursor]
  for i, st in b.stops:
    if b.stopIds[i] == idx: cs.add Cursor(anchor: st.anchor, head: st.head, goalX: -1)
  if cs.len == 0: return
  b.cursors = cs
  b.prim = 0
  b.stopIdx = idx
  if idx == 0:
    b.stops.setLen(0)
    b.stopIds.setLen(0)
  b.normalize()

proc snippetJump(b: Buffer, dir: int): bool =
  ## Tab / Shift+Tab inside an expanded snippet; false when there is nowhere to go
  if b.stops.len == 0: return false
  var ids: seq[int]
  for i in b.stopIds:
    if i != 0 and i notin ids: ids.add i
  ids.sort()
  if 0 in b.stopIds: ids.add 0
  let pos = ids.find(b.stopIdx)
  let nxt = pos + dir
  if nxt < 0: return true
  if nxt >= ids.len:
    b.stops.setLen(0)
    b.stopIds.setLen(0)
    return false
  b.activateStop(ids[nxt])
  true

proc expandSnippet(b: Buffer, a, e: Pos, body: string, literal = false) =
  ## (literal: a tab stays a tab — text that is the user's, not a snippet's indentation)
  if not b.canEdit(): return
  let line = b.lines[a.line]
  let baseInd = leadingWs(line[0 ..< min(a.col, line.len)])
  var text = ""
  var marks: seq[(int, int, int)]      # (index, start, end) offsets in text
  var defaults = initTable[int, string]()
  var i = 0
  while i < body.len:
    let c = body[i]
    if c == '\\' and i + 1 < body.len and body[i + 1] == '$':
      text.add '$'
      i += 2
    elif c == '$' and i + 1 < body.len and body[i + 1] == '{':
      var j = i + 2
      var num = 0
      while j < body.len and body[j] in Digits:
        num = num * 10 + ord(body[j]) - ord('0')
        inc j
      var def = ""
      if j < body.len and body[j] == ':':
        let close = body.find('}', j)
        def = body[j + 1 ..< (if close < 0: body.len else: close)]
        j = if close < 0: body.len else: close
      else:
        j = body.find('}', j)
        if j < 0: j = body.len
      if num notin defaults: defaults[num] = def
      let d = defaults[num]
      marks.add (num, text.len, text.len + d.len)
      text.add d
      i = j + 1
    elif c == '$' and i + 1 < body.len and body[i + 1] in Digits:
      var j = i + 1
      var num = 0
      while j < body.len and body[j] in Digits:
        num = num * 10 + ord(body[j]) - ord('0')
        inc j
      let d = defaults.getOrDefault(num)
      marks.add (num, text.len, text.len + d.len)
      text.add d
      i = j
    elif c == '\n':
      text.add "\n" & baseInd
      inc i
    elif c == '\t' and not literal:
      text.add b.indent
      inc i
    else:
      text.add c
      inc i
  b.beginEdit()
  discard b.replaceText(a, e, text)
  b.endEdit()
  b.stops.setLen(0)
  b.stopIds.setLen(0)
  for (num, s0, e0) in marks:
    b.stops.add Cursor(anchor: posAfter(a, text[0 ..< s0]), head: posAfter(a, text[0 ..< e0]), goalX: -1)
    b.stopIds.add num
  if b.stops.len == 0:
    b.setSingle(posAfter(a, text))
    return
  b.stopIdx = -1
  var first = high(int)
  for n in b.stopIds:
    if n != 0: first = min(first, n)
  if first == high(int): first = 0
  b.activateStop(first)

proc trySnippetAtCursor(b: Buffer): bool =
  ## Tab on a snippet keyword (e.g. `proc`, `for`, `main`) expands it
  if b.cursors.len != 1 or b.primary.hasSel: return false
  let h = b.primary.head
  let ws = b.wordStart(h)
  if ws == h.col: return false
  let s = b.lines[h.line]
  if h.col < s.len and isWordByte(s[h.col]): return false
  let body = snippetFor(b, s[ws ..< h.col])
  if body.len == 0: return false
  b.expandSnippet(Pos(line: h.line, col: ws), h, body)
  true
