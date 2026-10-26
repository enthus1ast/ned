## md-links' server — a language server for Markdown written in NimScript: a link to a file that is not there is
## a problem; hover over a link says where it goes; after ](# completion offers the file's headings; go to
## definition follows a link; the headings are the symbols (Go to symbol)
import nedlsp
import std/os

func slug(heading: string): string =
  ## a heading's anchor, as GitHub makes it: lower case, a space a -, other punctuation left out
  for c in heading.toLowerAscii:
    if c in {'a'..'z', '0'..'9', '-', '_'} or ord(c) >= 0x80: result.add c
    elif c == ' ': result.add '-'

func pathOf(uri: string): string =
  ## file:///home/you/my%20notes.md → /home/you/my notes.md
  result = uri
  if result.startsWith("file://"): result = result[7 .. ^1]
  result = result.replace("%20", " ")

func links(l: string): seq[(int, int, string)] =
  ## the links of a line, [text](target): where each target starts and ends (bytes) and the target
  var k = l.find("](")
  while k >= 0:
    let e = l.find(')', k + 2)
    if e < 0: break
    result.add (k + 2, e, l[k + 2 ..< e])
    k = l.find("](", e)

func local(target: string): string =
  ## the file a link goes to when it is one of this computer's ("" for a web address, or #a-heading here)
  let f = target.split('#')[0]
  if f.len == 0 or "://" in f or f.startsWith("mailto:"): "" else: f

proc headings(uri: string): seq[(int, int, string)] =
  ## the document's headings: line, level (# 1, ## 2 …) and text — not the # lines of code blocks
  var code = false
  for i, l in docLines(uri):
    if l.startsWith("```"): code = not code
    elif not code and l.startsWith("#"):
      var n = 0
      while n < l.len and l[n] == '#': inc n
      if n < l.len and l[n] == ' ': result.add (i, n, l[n + 1 .. ^1].strip)

proc check(uri: string) =
  ## a problem for each link to a file that is not there (the whole list, in place of the last one)
  let dir = parentDir(pathOf(uri))
  var diags = newJArray()
  for i, l in docLines(uri):
    for (a, e, t) in links(l):
      let f = local(t)
      if f.len > 0 and not fileExists(dir / f):
        diags.add %*{"range": lspRange(i, a, e, l), "severity": 2, "source": "md-links",
                     "message": "no such file: " & f}
  publishDiagnostics(uri, diags)

proc linkAt(params: JsonNode): (int, string) =
  ## the line and the target of the link at a request's position (-1 when there is none)
  let uri = params["textDocument"]["uri"].getStr
  let ln = params["position"]["line"].getInt
  let ls = docLines(uri)
  if ln >= ls.len: return (-1, "")
  let c = byteCol(ls[ln], params["position"]["character"].getInt)   # the client's column → a byte
  for (a, e, t) in links(ls[ln]):
    if c >= a and c <= e: return (ln, t)
  (-1, "")

# the document's text is kept by the library; these notifications come after it has it
onNotification("textDocument/didOpen") do (params: JsonNode):
  check(params["textDocument"]["uri"].getStr)
onNotification("textDocument/didChange") do (params: JsonNode):
  check(params["textDocument"]["uri"].getStr)

onRequest("textDocument/hover") do (params: JsonNode) -> JsonNode:
  let (ln, t) = linkAt(params)
  if ln < 0: return newJNull()
  let f = local(t)
  let dir = parentDir(pathOf(params["textDocument"]["uri"].getStr))
  let what = if f.len == 0: "a link" elif fileExists(dir / f): "a file of yours" else: "**no such file**"
  %*{"contents": {"kind": "markdown", "value": "→ `" & t & "` — " & what}}

onRequest("textDocument/completion") do (params: JsonNode) -> JsonNode:
  let uri = params["textDocument"]["uri"].getStr
  let ls = docLines(uri)
  let ln = params["position"]["line"].getInt
  var items = newJArray()
  if ln < ls.len:
    let before = ls[ln][0 ..< byteCol(ls[ln], params["position"]["character"].getInt)]
    let k = before.rfind("](#")
    if k >= 0 and ')' notin before[k .. ^1]:
      for (i, n, h) in headings(uri):
        items.add %*{"label": slug(h), "detail": "#".repeat(n) & " " & h, "kind": 18}
  %*{"isIncomplete": false, "items": items}

onRequest("textDocument/definition") do (params: JsonNode) -> JsonNode:
  let uri = params["textDocument"]["uri"].getStr
  let (ln, t) = linkAt(params)
  if ln < 0: return newJNull()
  let f = local(t)
  if f.len > 0:
    let full = parentDir(pathOf(uri)) / f
    if fileExists(full): return %*{"uri": "file://" & full, "range": lspRange(0, 0, 0, "")}
  elif t.startsWith("#"):
    for (i, n, h) in headings(uri):
      if slug(h) == t[1 .. ^1]: return %*{"uri": uri, "range": lspRange(i, 0, 0, "")}
  newJNull()

onRequest("textDocument/documentSymbol") do (params: JsonNode) -> JsonNode:
  let uri = params["textDocument"]["uri"].getStr
  let ls = docLines(uri)
  result = newJArray()
  for (i, n, h) in headings(uri):
    let r = lspRange(i, 0, ls[i].len, ls[i])
    result.add %*{"name": "#".repeat(n) & " " & h, "kind": 15, "range": r, "selectionRange": r}

serve(%*{"hoverProvider": true, "definitionProvider": true, "documentSymbolProvider": true,
         "completionProvider": {"triggerCharacters": ["#"]}})
