## A small language server: hover over a word says how often the text has it, completion offers the text's own
## words, and a line with TODO or over 100 characters is a diagnostic. Try it on its own:
##   ned --lsp-bridge server.nims   (then type LSP messages — or point another editor at that command)
import nedlsp

proc words(text: string): CountTable[string] =
  var w = ""
  for c in text & " ":
    if c in IdentChars: w.add c
    elif w.len > 0:
      if w.len > 2: result.inc w
      w = ""

proc check(uri: string) =
  var diags = newJArray()
  for i, l in docLines(uri):
    let k = l.find("TODO")
    if k >= 0:
      diags.add %*{"range": lspRange(i, k, k + 4, l), "severity": 3, "source": "wordinfo",
                   "message": "a TODO: something left to do"}
    if l.len > 100:
      diags.add %*{"range": lspRange(i, 100, l.len, l), "severity": 2, "source": "wordinfo",
                   "message": "a long line (" & $l.len & " characters)"}
  publishDiagnostics(uri, diags)

onNotification("textDocument/didOpen") do (params: JsonNode):
  check(params["textDocument"]["uri"].getStr)
onNotification("textDocument/didChange") do (params: JsonNode):
  check(params["textDocument"]["uri"].getStr)

onRequest("textDocument/hover") do (params: JsonNode) -> JsonNode:
  let w = wordAt(params)
  if w.len == 0: return newJNull()
  let uri = params["textDocument"]["uri"].getStr
  let n = words(docText(uri)).getOrDefault(w)
  %*{"contents": {"kind": "markdown", "value": "**" & w & "** — " & $n & " time" & (if n == 1: "" else: "s") &
                                               " in this text (" & $docLines(uri).len & " lines)"}}

onRequest("textDocument/completion") do (params: JsonNode) -> JsonNode:
  var items = newJArray()
  for w, n in words(docText(params["textDocument"]["uri"].getStr)):
    items.add %*{"label": w, "detail": $n & "×", "kind": 1}
  %*{"isIncomplete": false, "items": items}

serve(%*{"hoverProvider": true, "completionProvider": {"triggerCharacters": []}})
