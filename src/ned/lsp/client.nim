# ════════════════════════════════════════════════════════════════════════════
#  LSP client
# ════════════════════════════════════════════════════════════════════════════

proc lspFlush(s: LspServer) =
  var off = 0
  while off < s.wbuf.len:
    let n = posix.write(s.inFd, addr s.wbuf[off], s.wbuf.len - off)
    if n > 0: off += n
    elif n < 0 and (errno == EAGAIN or errno == EINTR): break
    else:
      s.dead = true
      break
  if off > 0: s.wbuf = s.wbuf[off .. ^1]

proc lspSend(s: LspServer, j: JsonNode) =
  if s.dead: return
  let body = $j
  s.wbuf.add "Content-Length: " & $body.len & "\r\n\r\n" & body
  s.lspFlush()

proc lspRequest(s: LspServer, meth: string, params: JsonNode, req: LspReq): int =
  inc s.nextId
  s.pending[s.nextId] = req
  s.lspSend(%*{"jsonrpc": "2.0", "id": s.nextId, "method": meth, "params": params})
  s.nextId

proc lspNotify(s: LspServer, meth: string, params: JsonNode) =
  s.lspSend(%*{"jsonrpc": "2.0", "method": meth, "params": params})

proc lspReply(s: LspServer, id: JsonNode, res: JsonNode) =
  s.lspSend(%*{"jsonrpc": "2.0", "id": id, "result": res})

proc toU16(s: string, col: int): int =
  var i = 0
  while i < col and i < s.len:
    let (cp, n) = runeAt(s, i)
    result += (if cp >= 0x10000: 2 else: 1)
    i += n

proc fromU16(s: string, u: int): int =
  var i = 0
  var k = 0
  while i < s.len and k < u:
    let (cp, n) = runeAt(s, i)
    k += (if cp >= 0x10000: 2 else: 1)
    i += n
  i

proc lspPos(s: LspServer, b: Buffer, p: Pos): JsonNode =
  # a position past the end (the text got shorter since it was worked out) is the end of the last line
  let l = clamp(p.line, 0, b.lines.high)
  let c = if l < p.line: b.lines[l].len else: max(0, p.col)
  %*{"line": l, "character": (if s.utf8: c else: toU16(b.lines[l], c))}

proc fromLspPos(s: LspServer, b: Buffer, j: JsonNode): Pos =
  if j == nil: return Pos()
  let l = clamp(j{"line"}.getInt, 0, b.lines.high)
  let ch = j{"character"}.getInt
  let c = if s.utf8: min(ch, b.lines[l].len) else: fromU16(b.lines[l], ch)
  b.clampPos(Pos(line: l, col: c))

proc docId(b: Buffer): JsonNode = %*{"uri": uriFromPath(b.path)}

proc isTermux(): bool
proc installHint(termuxPkg, linuxPkg: string): string
proc runInTerm(cmd: string)

proc fileLinesNow(path: string): seq[string]

proc lspInstallCmd(exe: string): string =
  ## how to install a language server here ("" when ned does not know)
  let termux = isTermux()
  let npmPre = if haveExe("npm"): "" else: installHint("nodejs", "npm") & " && "
  case exe
  of "pylsp": "pip install python-lsp-server"
  of "pyright-langserver": npmPre & "npm install -g pyright"
  of "rust-analyzer": (if termux: "pkg install rust-analyzer" elif haveExe("rustup"): "rustup component add rust-analyzer"
                       else: installHint("rust-analyzer", "rust-analyzer"))
  of "gopls": (if haveExe("go"): "go install golang.org/x/tools/gopls@latest" else: installHint("gopls", "gopls"))
  of "clangd": (if termux: "pkg install clang" else: installHint("clang", "clangd"))
  of "typescript-language-server": npmPre & "npm install -g typescript-language-server typescript"
  of "lua-language-server": installHint("lua-language-server", "lua-language-server")
  of "bash-language-server": npmPre & "npm install -g bash-language-server"
  of "ruby-lsp": "gem install ruby-lsp"
  of "intelephense": npmPre & "npm install -g intelephense"
  of "csharp-ls": (if haveExe("dotnet"): "dotnet tool install --global csharp-ls" else: "")
  of "sqls": (if haveExe("go"): "go install github.com/sqls-server/sqls@latest" else: "")
  of "sql-language-server": npmPre & "npm install -g sql-language-server"
  of "kotlin-lsp", "kotlin-language-server": (if haveExe("brew"): "brew install kotlin-language-server" else: "")
  of "vscode-css-language-server", "vscode-json-language-server", "vscode-html-language-server":
    npmPre & "npm install -g vscode-langservers-extracted"
  of "yaml-language-server": npmPre & "npm install -g yaml-language-server"
  of "docker-langserver": npmPre & "npm install -g dockerfile-language-server-nodejs"
  else: ""

proc lspInstallToast(langName: string, cands: seq[seq[string]]) =
  ## once per language and session: say which server would give completion, errors and rename
  if langName in lspHinted: return
  lspHinted.incl langName
  for c in cands:
    if c.len == 0: continue
    let cmd = lspInstallCmd(extractFilename(c[0]))
    if cmd.len == 0: continue
    let shown = cmd
    toast(langName & ": no language server for completion, errors and rename — " & c[0] & " (" & shown & ")",
          3, "Install", proc() = runInTerm(shown), 12000)
    return

proc lspSpawn(id: string, c: seq[string], secondary: bool): LspServer =
  ## start one language server (its `initialize` sent); nil when it cannot start
  try:
    var p = spawnProc(c, rootDir, siPipe, erPipe)
    let shown = if c.len > 1 and extractFilename(c[0]) in ["python", "python3", "node", "sh", "bash", "ruby"]:
                  extractFilename(c[1]) else: extractFilename(c[0])
    let s = LspServer(langId: id, name: shown, cmd: c, pr: p, inFd: p.inFd, uid: lspUidNext, secondary: secondary,
                      outFd: p.outFd, errFd: p.errFd, status: "starting…", startedAt: getMonoTime())
    inc lspUidNext
    s.pr.inFd = -1
    s.pr.outFd = -1
    s.pr.errFd = -1
    setNonBlock(s.inFd); setNonBlock(s.outFd); setNonBlock(s.errFd)
    servers.add s
    let root = uriFromPath(rootDir)
    let params = %*{
      "processId": getCurrentProcessId(),
      "rootUri": root, "rootPath": rootDir,
      "workspaceFolders": wsFoldersJson(),
      "clientInfo": {"name": AppName, "version": Version},
      "capabilities": {
        "general": {"positionEncodings": ["utf-8", "utf-16"]},
        "textDocument": {
          "synchronization": {"didSave": true, "dynamicRegistration": false},
          "completion": {"completionItem": {"snippetSupport": false,
            "documentationFormat": ["markdown", "plaintext"],
            "resolveSupport": {"properties": ["documentation", "detail"]}}, "contextSupport": true},
          "hover": {"contentFormat": ["markdown", "plaintext"]},
          "signatureHelp": {"signatureInformation": {"parameterInformation": {"labelOffsetSupport": true},
                                                     "documentationFormat": ["markdown", "plaintext"]},
                            "contextSupport": true},
          "definition": {"linkSupport": true},
          "publishDiagnostics": {"relatedInformation": false, "codeActionsInline": true},
          "rename": {"prepareSupport": false},
          "formatting": {"dynamicRegistration": false},
          "inlayHint": {"dynamicRegistration": false},
          "codeAction": {"codeActionLiteralSupport": {"codeActionKind": {"valueSet":
            ["", "quickfix", "refactor", "refactor.extract", "refactor.inline", "refactor.rewrite", "source"]}}},
          "documentSymbol": {"hierarchicalDocumentSymbolSupport": true},
          "callHierarchy": {"dynamicRegistration": false},
          "typeHierarchy": {"dynamicRegistration": false},
          "typeDefinition": {"linkSupport": true}, "implementation": {"linkSupport": true},
          "documentLink": {"dynamicRegistration": false, "tooltipSupport": true},
          "onTypeFormatting": {"dynamicRegistration": false},
          "diagnostic": {"dynamicRegistration": false, "relatedDocumentSupport": false},
          "documentHighlight": {"dynamicRegistration": false},
          "foldingRange": {"dynamicRegistration": false, "lineFoldingOnly": true},
          "rangeFormatting": {"dynamicRegistration": false},
          "semanticTokens": {"dynamicRegistration": false, "requests": {"full": true},
            "tokenTypes": ["namespace", "type", "class", "enum", "interface", "struct", "typeParameter",
                           "parameter", "variable", "property", "enumMember", "event", "function", "method",
                           "macro", "keyword", "modifier", "comment", "string", "number", "regexp", "operator",
                           "decorator"],
            "tokenModifiers": ["declaration", "definition", "readonly", "static", "deprecated", "abstract",
                               "async", "modification", "documentation", "defaultLibrary"],
            "formats": ["relative"], "overlappingTokenSupport": false, "multilineTokenSupport": false}},
        "workspace": {"configuration": true, "workspaceFolders": true, "applyEdit": true,
                      "diagnostics": {"refreshSupport": true},
                      "didChangeConfiguration": {"dynamicRegistration": false},
                      "inlayHint": {"refreshSupport": true}, "symbol": {}, "executeCommand": {}},
        "window": {"workDoneProgress": true}}}
    if secondary: discard
    elif id == "nim": params["initializationOptions"] = nimSection()
    elif id == "html":
      params["initializationOptions"] = %*{"embeddedLanguages": {"css": true, "javascript": true},
                                            "provideFormatter": true}
    elif id in ["css", "json"]: params["initializationOptions"] = %*{"provideFormatter": true}
    discard s.lspRequest("initialize", params, LspReq(kind: lrInit))
    return s
  except CatchableError: discard

proc lspPullDiags(s: LspServer, b: Buffer)      # (doclinks.nim) pull diagnostics: the server's problems, asked for
proc lspLinksAsk(s: LspServer, b: Buffer)       # … the file's links (#include, @import, URLs)

proc lspFor(b: Buffer, start = true): LspServer =
  if b.path.len == 0 or b.lines.len > 40000 or b.largeOn: return nil   # huge files: keep typing instant
  let id = b.lang.id
  if id == "nim" and not nimUsesLsp(): return nil
  if id == "c" and cfgCEngine == "builtin": return nil        # (ned's own C engine answers)
  for s in servers:
    if s.langId == id and not s.dead and not s.secondary: return s
  if not start or id in lspFailed: return nil
  var cands: seq[seq[string]]
  if id in cfgUserLsp: cands.add cfgUserLsp[id]
  for c in b.lang.lsp: cands.add c
  if id == "nim":
    if not codeTrusted(rootDir):
      askTrust(rootDir, quiet = true)              # (nimlangserver runs nimsuggest: the folder's config.nims)
      return nil
    prepareNimMapping(b)
  for c in cands:
    if c.len == 0 or findExe(c[0]).len == 0: continue
    let s = lspSpawn(id, c, secondary = false)
    if s != nil: return s
  lspFailed.incl id
  if cands.len > 0 and cfgLspHints and id in ["python", "c", "cpp", "javascript", "typescript", "rust", "go",
                                              "shellscript", "lua", "ruby", "css", "php", "csharp", "sql", "kotlin"]:
    lspInstallToast(b.lang.name, cands)
  nil


# ── more servers for a language (lsp.alsoRun, lsp.linters): a linter next to the main server — only its problems
#    and quick fixes are used, merged with the main server's ──

const KnownLinters = [("python", @["ruff", "server"]), ("go", @["golangci-lint-langserver"]),
                      ("markdown", @["harper-ls", "--stdio"])]

proc lspMoreCmds(b: Buffer): seq[seq[string]] =
  ## the second servers this buffer's language gets: yours (lsp.alsoRun), then the known linters that are installed
  let id = b.lang.id
  for key in [id, "*"]:
    for c in cfgLspAlso.getOrDefault(key): result.add c
  if cfgLspLinters:
    for (lid, c) in KnownLinters:
      if lid == id and c notin result: result.add c
  # (not the main server again)
  var main: seq[string]
  for s in servers:
    if s.langId == id and not s.dead and not s.secondary: main = s.cmd
  var keep: seq[seq[string]]
  for c in result:
    if c.len > 0 and c != main and c.join(" ") notin lspMoreFailed and c notin keep: keep.add c
  keep

proc lspMoreFor(b: Buffer, start = true): seq[LspServer] =
  ## the second servers running for this buffer (started now when `start` and installed)
  if b.path.len == 0 or b.lines.len > 40000 or b.largeOn or b.lang == nil: return
  let id = b.lang.id
  for c in lspMoreCmds(b):
    var found: LspServer = nil
    for s in servers:
      if s.secondary and s.langId == id and s.cmd == c and not s.dead: found = s
    if found == nil and start and findExe(c[0]).len > 0:
      if not codeTrusted(rootDir):
        askTrust(rootDir, quiet = true)
        continue
      found = lspSpawn(id, c, secondary = true)
      if found == nil: lspMoreFailed.incl c.join(" ")
    if found != nil: result.add found

proc lspMoreSync(b: Buffer, start = false) =
  ## the second servers have the buffer as it is now (opened on first sight)
  if b.path.len == 0 or b.title.len > 0: return
  for s in lspMoreFor(b, start):
    if not s.ready or s.dead: continue
    let v = s.docVer.getOrDefault(b.id, -1)
    if v < 0:
      s.docVer[b.id] = b.changeId
      b.lspMore = true
      s.lspNotify("textDocument/didOpen", %*{"textDocument": {"uri": uriFromPath(b.path),
        "languageId": b.lang.id, "version": b.changeId + 1, "text": b.allText & "\n"}})
      lspPullDiags(s, b)
    elif v != b.changeId:
      s.docVer[b.id] = b.changeId
      s.lspNotify("textDocument/didChange", %*{"textDocument": {"uri": uriFromPath(b.path),
        "version": b.changeId + 1}, "contentChanges": [{"text": b.allText & "\n"}]})
      lspPullDiags(s, b)

proc lspMoreSaved(b: Buffer) =
  for s in lspMoreFor(b, false):
    if s.ready and not s.dead and b.id in s.docVer:
      lspMoreSync(b)
      s.lspNotify("textDocument/didSave", %*{"textDocument": b.docId, "text": b.allText & "\n"})
      lspPullDiags(s, b)

proc lspMoreClosed(b: Buffer) =
  for s in lspMoreFor(b, false):
    if s.ready and not s.dead and b.id in s.docVer:
      s.lspNotify("textDocument/didClose", %*{"textDocument": b.docId})
      s.docVer.del b.id
  b.lspMore = false

var lspHoldAttach = initTable[int, MonoTime]()   # buffer id → open it once nimlangserver has its new mapping
var nimCfgWaitUntil: MonoTime   # a fresh nimlangserver pulls its settings first: files open after that

proc lspAttach(b: Buffer) =
  let s = lspFor(b)                      # (the main server first: a second one is never the main one again)
  lspMoreSync(b, start = true)
  if s == nil or not s.ready or b.lspOpen: return
  if b.id in lspHoldAttach and getMonoTime() < lspHoldAttach[b.id]: return
  lspHoldAttach.del b.id
  if s.langId == "nim" and getMonoTime() < nimCfgWaitUntil:
    # nimlangserver asks for its settings (with the projectMapping) right after "initialized". A file opened
    # before the answer is matched against no mapping, and gets a nimsuggest of its own.
    lspHoldAttach[b.id] = nimCfgWaitUntil
    return
  if s.langId == "nim" and sBool("nim.autoProjectMapping") and
     (let pm = sval("nim.projectMapping"); pm.kind != JArray or pm.len == 0) and nimMapAdd(b):
    # a new project: nimlangserver must know its rule before the file opens, or it guesses (and may hand a
    # package file to another project's nimsuggest). It pulls the settings (workspace/configuration); the
    # file opens right after the answer (lspConfigAnswered), at the latest after 1.5 s.
    s.lspNotify("workspace/didChangeConfiguration", %*{"settings": {"nim": nimSection()}})
    lspHoldAttach[b.id] = getMonoTime() + initDuration(milliseconds = 1500)
    return
  b.lspOpen = true
  b.lspDirty = false
  inc b.lspVersion
  s.lspNotify("textDocument/didOpen", %*{"textDocument": {"uri": uriFromPath(b.path),
    "languageId": b.lang.id, "version": b.lspVersion, "text": b.allText & "\n"}})
  lspPullDiags(s, b)
  lspLinksAsk(s, b)

proc lspSync(b: Buffer) =
  if b.lspMore: lspMoreSync(b)
  let s = lspFor(b, false)
  if s == nil or not s.ready:
    if not b.lspOpen: b.lspDirty = false        # (a main server that starts later gets the whole text then)
    return
  if not b.lspOpen:
    lspAttach(b)
    return
  if not b.lspDirty: return
  b.lspDirty = false
  inc b.lspVersion
  s.lspNotify("textDocument/didChange", %*{"textDocument": {"uri": uriFromPath(b.path),
    "version": b.lspVersion}, "contentChanges": [{"text": b.allText & "\n"}]})
  lspPullDiags(s, b)
  lspLinksAsk(s, b)

proc lspDidSave(b: Buffer) =
  if b.lspMore: lspMoreSaved(b)
  let s = lspFor(b, false)
  if s == nil or not s.ready or not b.lspOpen: return
  lspSync(b)
  s.lspNotify("textDocument/didSave", %*{"textDocument": b.docId, "text": b.allText & "\n"})
  lspPullDiags(s, b)

proc lspDidClose(b: Buffer) =
  if b.lspMore: lspMoreClosed(b)
  let s = lspFor(b, false)
  if s == nil or not s.ready or not b.lspOpen: return
  s.lspNotify("textDocument/didClose", %*{"textDocument": b.docId})
  b.lspOpen = false

proc lspReady(b: Buffer): LspServer =
  let s = lspFor(b, false)
  if s != nil and s.ready and not s.dead:
    lspSync(b)
    return s
  nil

proc stripSnippet(s: string): string =
  var i = 0
  while i < s.len:
    if s[i] == '\\' and i + 1 < s.len:
      result.add s[i+1]
      i += 2
    elif s[i] == '$' and i + 1 < s.len and s[i+1] in Digits:
      i += 1
      while i < s.len and s[i] in Digits: inc i
    elif s[i] == '$' and i + 1 < s.len and s[i+1] == '{':
      var j = i + 2
      while j < s.len and s[j] in Digits: inc j
      if j < s.len and s[j] == ':':
        var depth = 1
        var k = j + 1
        var inner = ""
        while k < s.len:
          if s[k] == '{': inc depth
          elif s[k] == '}':
            dec depth
            if depth == 0: break
          inner.add s[k]
          inc k
        result.add stripSnippet(inner)
        i = k + 1
      else:
        let k = s.find('}', j)
        i = if k < 0: s.len else: k + 1
    else:
      result.add s[i]
      inc i

proc dropMdImages(s: string): string =
  ## ![alt](url) — pictures a terminal cannot show (the HTML server's base64 "Baseline" badges): left out
  if "![" notin s: return s
  var i = 0
  while i < s.len:
    if s[i] == '!' and i + 1 < s.len and s[i + 1] == '[':
      let cb = s.find(']', i + 2)
      if cb > 0 and cb + 1 < s.len and s[cb + 1] == '(':
        var d = 0
        var j = cb + 1
        while j < s.len:
          if s[j] == '(': inc d
          elif s[j] == ')':
            dec d
            if d == 0: break
          inc j
        if j < s.len:
          i = j + 1
          continue
    result.add s[i]
    inc i

proc markupText(c: JsonNode): string =
  if c == nil: return ""
  case c.kind
  of JString: dropMdImages(c.getStr)
  of JObject: dropMdImages(c{"value"}.getStr)
  of JArray:
    var parts: seq[string]
    for x in c: parts.add markupText(x)
    parts.join("\n---\n")
  else: ""

proc refilterComp()

proc wordStart(b: Buffer, p: Pos): int =
  let s = b.lines[p.line]
  result = p.col
  while result > 0 and isWordByte(s[result - 1]): dec result

proc handleCompletion(s: LspServer, req: LspReq, res: JsonNode) =
  let b = buf()
  if b.id != req.bufId or res == nil: return
  let items = if res.kind == JArray: res elif res.kind == JObject: res{"items"} else: nil
  if items == nil or items.kind != JArray: return
  let p = b.primary.head
  if p.line != req.pos.line or p.col < req.pos.col: return
  for i in req.pos.col ..< p.col:
    if not isWordByte(b.lines[p.line][i]): return
  var list: seq[CompItem]
  for it in items:
    if list.len >= 800: break
    let label = it{"label"}.getStr
    if label.len == 0: continue
    var ins = it{"insertText"}.getStr(label)
    let te = it{"textEdit"}
    if te != nil and te.kind == JObject and te.hasKey("newText"): ins = te["newText"].getStr
    if it{"insertTextFormat"}.getInt == 2: ins = stripSnippet(ins)
    let fullDetail = it{"detail"}.getStr
    var detail = fullDetail
    let nlp = detail.find('\n')
    if nlp >= 0: detail = detail[0 ..< nlp]
    var doc = markupText(it{"documentation"}).strip
    if fullDetail.strip.len > 0 and (doc.len == 0 or fullDetail.strip notin doc):
      doc = "```" & b.lang.name.toLowerAscii & "\n" & fullDetail.strip & "\n```" & (if doc.len > 0: "\n" & doc else: "")
    list.add CompItem(label: label, insert: ins, detail: detail, kind: it{"kind"}.getInt,
                      filter: it{"filterText"}.getStr(label), sortText: it{"sortText"}.getStr(label),
                      doc: doc, data: (if it{"documentation"} == nil: it else: nil))
  if list.len == 0: return
  compItems = list
  compFromLsp = true
  compLine = p.line
  compStartCol = b.wordStart(p)
  refilterComp()

# semantic colours from a language server (other languages; Nim has its own index)
var
  lspSem: Table[int, (int, Table[int, seq[(int, int, TokKind)]])]   # buffer → (change, line → (col, len, kind))
  lspSemAsked: Table[int, (int, MonoTime)]                            # buffer → (change asked for, when)
  callItems: seq[PickItem]                                            # call hierarchy answers, collected
  callWaiting = 0
  callName = ""

proc semKindOf(t: string): TokKind =
  case t
  of "function", "method", "decorator": tkFunc
  of "macro": tkPreproc
  of "parameter": tkParam
  of "type", "class", "enum", "interface", "struct", "typeParameter", "namespace": tkType
  of "enumMember": tkConst
  of "property": tkProperty
  else: tkText

proc lspSemFor(b: Buffer): Table[int, seq[(int, int, TokKind)]] =
  ## the language server's colours for this buffer (asks again after edits, at most every 400 ms)
  if not cfgSemColors or b.lang.mode == lmNim or b.path.len == 0: return
  let have = lspSem.getOrDefault(b.id, (-1, initTable[int, seq[(int, int, TokKind)]]()))
  result = have[1]
  if have[0] == b.changeId: return
  let asked = lspSemAsked.getOrDefault(b.id, (-1, MonoTime()))
  if asked[0] == b.changeId or msSince(asked[1]) < 400: return
  let s = lspFor(b, false)
  if s == nil or not s.ready or s.dead or s.caps == nil or s.caps{"semanticTokensProvider"} == nil: return
  if lspReady(b) == nil: return
  lspSemAsked[b.id] = (b.changeId, getMonoTime())
  discard s.lspRequest("textDocument/semanticTokens/full", %*{"textDocument": b.docId},
                       LspReq(kind: lrSemTokens, bufId: b.id, version: b.changeId))

proc callItemOf(s: LspServer, it: JsonNode, arrow: string): PickItem =
  let path = pathFromUri(it{"uri"}.getStr)
  let st = it{"selectionRange", "start"}
  PickItem(label: arrow & " " & it{"name"}.getStr, detail: relPath(path) & ":" & $(st{"line"}.getInt + 1) &
           (if it{"detail"}.getStr.len > 0: " · " & it{"detail"}.getStr else: ""),
           icon: "ƒ", path: path, line: st{"line"}.getInt, col: st{"character"}.getInt)

proc callDone() =
  dec callWaiting
  if callWaiting > 0: return
  if callItems.len == 0: info("No calls to or from " & callName)
  else: openPicker(pickSymbol, "Call hierarchy — " & callName & "  (← called by · → calls)", callItems)

proc handleDefinition(s: LspServer, res: JsonNode) =
  var loc = res
  if loc != nil and loc.kind == JArray:
    if loc.len == 0:
      info("No definition found")
      return
    loc = loc[0]
  if loc == nil or loc.kind != JObject:
    info("No definition found")
    return
  let uri = if loc.hasKey("targetUri"): loc["targetUri"].getStr else: loc{"uri"}.getStr
  let rng = if loc.hasKey("targetSelectionRange"): loc["targetSelectionRange"] else: loc{"range"}
  pushJump()
  let b = openFile(realPathOf(pathFromUri(uri)))
  if b == nil: return
  let at = fromLspPos(s, b, rng{"start"})
  if b.lang != nil and b.lang.mode == lmNim and s.langId in ["c", "cpp"]: b.cursors = @[cur(at)]   # in an emit
  b.centerOn(at)

proc handleLocations(s: LspServer, res: JsonNode, what: string) =
  ## Location | Location[] | LocationLink[]: one goes there, several open a list
  var items: seq[PickItem]
  var locs: seq[JsonNode]
  if res != nil and res.kind == JArray:
    for x in res: locs.add x
  elif res != nil and res.kind == JObject: locs.add res
  for loc in locs:
    let uri = if loc.hasKey("targetUri"): loc["targetUri"].getStr else: loc{"uri"}.getStr
    let rng = if loc.hasKey("targetSelectionRange"): loc["targetSelectionRange"] else: loc{"range"}
    if uri.len == 0 or rng == nil: continue
    let path = realPathOf(pathFromUri(uri))
    let l = rng{"start", "line"}.getInt
    var txt = ""
    let ls = fileLinesNow(path)
    if l < ls.len: txt = ls[l].strip
    items.add PickItem(label: relPath(path) & ":" & $(l + 1), detail: txt, path: path, line: l,
                       col: rng{"start", "character"}.getInt)
  if items.len == 0: info("No " & what & " found")
  elif items.len == 1:
    pushJump()
    let b = openFile(items[0].path)
    if b != nil: b.centerOn(b.clampPos(Pos(line: items[0].line, col: items[0].col)))
  else: openPicker(pickSymbol, what.capitalizeAscii & " (" & $items.len & ")", items)

var
  docHl: tuple[bufId, change: int, pos: Pos, ranges: seq[(Pos, Pos)]]   # the language server's highlights
  typeHier: tuple[name: string, items: seq[PickItem], waiting: int]

proc applyTextEdits(s: LspServer, b: Buffer, edits: JsonNode) =
  if edits == nil or edits.kind != JArray: return
  var list: seq[(Pos, Pos, string)]
  for e in edits:
    list.add (fromLspPos(s, b, e{"range", "start"}), fromLspPos(s, b, e{"range", "end"}),
              e{"newText"}.getStr.replace("\r\n", "\n"))
  list.sort(proc(x, y: (Pos, Pos, string)): int =
    if x[0] < y[0]: 1 elif y[0] < x[0]: -1 else: 0)
  b.beginEdit()
  for (a, c, t) in list: discard b.replaceText(a, c, t)
  b.endEdit()
  b.normalize()

proc lspDiagMsg(d: JsonNode): (string, JsonNode) =
  ## a server's diagnostic message without clangd's "(fix available)" (ned says how to apply it instead),
  ## and the fixes that came with it
  var m = d{"message"}.getStr
  for suffix in [" (fix available)", " (fixes available)"]:
    if m.endsWith(suffix): m = m[0 ..< m.len - suffix.len]
  if m.endsWith(" fixes available)"):
    let k = m.rfind(" (")
    if k > 0 and m[k + 2 ..< m.len - " fixes available)".len].allCharsInSet(Digits): m = m[0 ..< k]
  let ca = d{"codeActions"}
  (m, (if ca != nil and ca.kind == JArray and ca.len > 0: ca else: nil))

proc applyWorkspaceEdit(s: LspServer, we: JsonNode) =
  if we == nil or we.kind != JObject: return
  var files = 0
  if we.hasKey("changes") and we["changes"].kind == JObject:
    for uri, edits in we["changes"]:
      let b = loadBuffer(realPathOf(pathFromUri(uri)))
      if b != nil:
        applyTextEdits(s, b, edits)
        inc files
  if we.hasKey("documentChanges"):
    for dc in jitems(we["documentChanges"]):
      if dc.kind == JObject and dc.hasKey("edits"):
        let b = loadBuffer(realPathOf(pathFromUri(dc{"textDocument", "uri"}.getStr)))
        if b != nil:
          applyTextEdits(s, b, dc["edits"])
          inc files
  info("Applied edits to " & $files & " file(s) — Ctrl+S to save")

proc fixEditInfo(s: LspServer, edit: JsonNode): (int, string, string, string) =
  ## an edit in a few words: (how many text edits, the path of the first, its old text, its new text) —
  ## the old text only when that file is open
  if edit == nil or edit.kind != JObject: return
  var tes: seq[(string, JsonNode)]
  if edit{"changes"} != nil and edit["changes"].kind == JObject:
    for uri, arr in edit["changes"]:
      for te in jitems(arr): tes.add (uri, te)
  for dc in jitems(edit{"documentChanges"}):
    for te in jitems(dc{"edits"}): tes.add (dc{"textDocument", "uri"}.getStr, te)
  if tes.len == 0: return
  result[0] = tes.len
  let path = realPathOf(pathFromUri(tes[0][0]))
  result[1] = path
  result[3] = tes[0][1]{"newText"}.getStr
  let bi = bufIndexByPath(path)
  if bi >= 0 and s != nil:
    let fb = bufs[bi]
    let p0 = fromLspPos(s, fb, tes[0][1]{"range", "start"})
    let p1 = fromLspPos(s, fb, tes[0][1]{"range", "end"})
    if p0 < p1 and p1.line < fb.lines.len: result[2] = fb.getText(p0, p1)

proc fixShow(t: string): string =
  let x = t.strip.replace("\n", " ⏎ ")
  "'" & (if x.len > 32: x[0 ..< 31] & "…" else: x) & "'"

proc fixLabel(s: LspServer, ca: JsonNode): (string, string) =
  ## a fix's title, and what it changes in a few words (clang names some fixes after a note: "'printf'
  ## declared here" — those are titled by what they do)
  var title = ca{"title"}.getStr
  let (n, _, old, nt) = fixEditInfo(s, ca{"edit"})
  var what = ""
  if n == 1:
    if old.len == 0 and nt.len > 0: what = "insert " & fixShow(nt)
    elif nt.len == 0 and old.len > 0: what = (if '\n' in old.strip: "remove " & $old.strip.countLines & " lines" else: "remove " & fixShow(old))
    elif old.len > 0: what = fixShow(old) & " → " & fixShow(nt)
    elif nt.len > 0: what = "→ " & fixShow(nt)
  elif n > 1: what = $n & " changes"
  if ("declared here" in title or "defined here" in title) and nt.len > 0 and nt.strip.len <= 60 and '\n' notin nt:
    title = if old.len > 0: "Change " & old.strip & " to " & nt.strip else: "Change to " & nt.strip
  if what.toLowerAscii == title.toLowerAscii: what = ""
  (title, what)

proc fixHint(d: Diag): string =
  ## what Alt+Enter does about this problem, shown after it ("" when the server sent no fixes with it)
  if d.fixes == nil or d.fixes.len == 0: return ""
  if d.fixes.len > 1: return "  — Alt+Enter: " & $d.fixes.len & " fixes"
  var ca = d.fixes[0]
  "  — Alt+Enter: " & fixLabel(nil, ca)[0]
