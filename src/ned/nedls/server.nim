# ════════════════════════════════════════════════════════════════════════════
#  nedls — the server: lifecycle (initialize · initialized · shutdown · exit), settings, the project and its
#  toolchain (as the editor sets them up), the dispatch of every message (a failing handler answers with an
#  error and the server goes on), and the main loop (stdin, the compiler's checks, idle work).
# ════════════════════════════════════════════════════════════════════════════

var
  lsInitialized = false                # initialize answered
  lsShutdown = false                   # shutdown received
  lsExit = false                       # exit received (or stdin ended)
  lsCancelled: HashSet[string]         # ids of requests the client no longer wants
  lsParentPid = 0                      # the client's process (initialize's processId): nedls ends with it
  lsParentAt: MonoTime
  lsUseNedSettings = true              # read ned's own settings (~/.config/ned/config.json, .ned/settings.json)
  lsOptions = newJObject()             # the client's settings (didChangeConfiguration, workspace/configuration)
  lsInitOptions = newJObject()         # … and initializationOptions (the settings win)
  lsWarmed: HashSet[int]               # documents whose imports were read while idle
  lsSemRefresh = false                 # the client can be asked to colour again
  lsInlayRefresh = false
  lsWatchFiles = false                 # the client watches files for nedls (dynamic registration)
  lsSignal = 0                         # SIGTERM / SIGINT arrived
  lsRootGuess = false                  # no project folder from the client: the first file's project is it
  lsPullConfig = false                 # the client answers workspace/configuration
  lsConfigReq = ""                     # the id of that request, while its answer is awaited

const LsHelp = """nedls — ned's built-in engines as a language server (LSP over stdio): Nim, and C, C++, JavaScript,
HTML, CSS, SQL and JSON

Usage: nedls [--stdio] [--verbose] [--log:FILE]
       nedls --lint [options] [FILE|FOLDER…]    the engine's checks over files, no editor (nedls --lint --help)
       nedls --version | --help

Editors start it and talk to it over stdin/stdout. It gives what ned gives in its own editor — completion with
documentation, hover, signature help, definition, references, rename, symbols, semantic colours, inlay hints,
formatting (ned's nph-style formatter), folding, code actions (quick fixes, refactorings, Organize imports, Fix
all, Fix with AI checked by `nim check`), and problems as you type (`nim check` on the unsaved text) and on save —
without nimsuggest or nimlangserver. Nim itself (nim on PATH) is needed only for the compiler's checks and for
finding the standard library.

Options
  --stdio          talk over stdin/stdout (the default and only transport)
  --verbose, -v    log every message and how long it took (stderr)
  --log:FILE       also write the log to FILE
  --version        print the version
  --help, -h       this text

Settings (initializationOptions, or workspace/didChangeConfiguration under "nedls")
  inlayHints            true      type hints after let/var/const and parameter names in calls
  parameterHints        literals  parameter names before arguments: literals | all | off
  checkOnSave           true      `nim check` the file when it is saved
  liveDiagnostics       true      check the unsaved text while typing (misspelled names at once, the compiler
                                  after a pause)
  formatLineLength      88        line length of the built-in formatter (40–240); not given: nim.format.lineLength,
                                  else the file's .editorconfig max_line_length
  raisesHints           false     what a routine can raise, as a hint after its header ({.raises: [IOError].})
  nedSettings           true      also read ned's settings files (~/.config/ned/config.json, .ned/settings.json)
  aiFix                 true      offer Fix with AI on a compiler error when ned's settings name a model (ai.provider
                                  and its key): the answer is checked with `nim check` before the editor applies it
  workspaceDiagnostics  true      for an editor that asks for the whole workspace's problems: ned's checks also go
                                  over the project's files that are not open, while nedls is idle
"""

proc onLsSignal(sig: cint) {.noconv.} = lsSignal = sig.int

# ── settings ──

proc lsOptIn(o: JsonNode, key: string): JsonNode =
  if o == nil or o.kind != JObject: return nil
  let sub = o{"nedls"}
  if sub != nil and sub.kind == JObject and sub.hasKey(key): return sub[key]
  o{key}

proc lsOpt(key: string): JsonNode =
  ## a setting from the client: {"nedls": {key: …}} or {key: …} — its settings, else initializationOptions
  result = lsOptIn(lsOptions, key)
  if result == nil or result.kind == JNull: result = lsOptIn(lsInitOptions, key)

proc lsApplySettings() =
  ## ned's settings (yours and the project's, as the editor reads them), then nedls's own needs, then the client's
  if lsUseNedSettings: loadConfig()
  else:
    initSettingDefs()
    settingsJ = newJObject()
    for d in setDefs: settingsJ[d.key] = d.def
    applySettings()
  # the built-in engine, always: no nimsuggest, no other language server, no prompts
  cfgNimIde = "builtin"
  cfgNimSuggest = false
  cfgFolderTrust = "off"              # (the editor that started nedls decides whether this folder is trusted)
  cfgSemColors = true
  cfgCEngine = "builtin"               # (C, C++, JavaScript, HTML, CSS, SQL, JSON: ned's own engines answer)
  cfgWebEngine = "on"
  cfgMessages = "status"
  cfgToasts = false
  if sStr("nim.liveDiagnosticsFrom") == "nimsuggest":
    settingsJ["nim.liveDiagnosticsFrom"] = %"auto"   # (no nimsuggest here: the compiler checks while typing)
  var v = lsOpt("inlayHints")
  if v != nil and v.kind == JBool: cfgInlayHints = v.getBool
  v = lsOpt("parameterHints")
  if v != nil and v.kind == JString and v.getStr in ["literals", "all", "off"]: cfgParamHints = v.getStr
  v = lsOpt("checkOnSave")
  if v != nil and v.kind == JBool: cfgCheckOnSave = v.getBool
  v = lsOpt("liveDiagnostics")
  if v != nil and v.kind == JBool: cfgLiveCheck = v.getBool
  v = lsOpt("formatLineLength")
  if v != nil and v.kind in {JInt, JFloat}:
    FmtWidth = clamp((if v.kind == JInt: v.getInt else: int(v.getFloat)), 40, 240)
    FmtMax = FmtWidth
    cfgFmtWidth = FmtWidth
    cfgFmtWidthSet = true                 # (the client said it: before any .editorconfig)
  v = lsOpt("workspaceDiagnostics")
  if v != nil and v.kind == JBool:
    lsLintOn = v.getBool
    if not lsLintOn: lsLintOff()
  lsDiskChanged()                         # (other rules, other messages: the problems made again)

# ── the project ──

proc lsSetRoot(dir: string) =
  ## the project folder: what the editor would have open
  if dir.len == 0 or not dirExists(dir): return
  rootDir = normalizedPath(absolutePath(dir))
  while rootDir.len > 1 and rootDir.endsWith("/"): rootDir.setLen(rootDir.len - 1)
  try: setCurrentDir(rootDir)
  except OSError: discard
  fileCacheValid = false

proc lsInitialize(params: JsonNode): JsonNode =
  let caps = params{"capabilities"}
  # positions: UTF-8 when the client can, else UTF-16 (LSP's default)
  lsUtf8 = false
  for e in jitems(caps{"general"}{"positionEncodings"}):
    if e.getStr == "utf-8": lsUtf8 = true
  let td = caps{"textDocument"}
  lsSnippets = td{"completion"}{"completionItem"}{"snippetSupport"}.getBool(false)
  for p in jitems(td{"completion"}{"completionItem"}{"resolveSupport"}{"properties"}):
    if p.getStr == "additionalTextEdits": lsResolveEdits = true
  lsHierSymbols = td{"documentSymbol"}{"hierarchicalDocumentSymbolSupport"}.getBool(false)
  let rl = td{"foldingRange"}{"rangeLimit"}
  if rl != nil and rl.kind == JInt and rl.getInt > 0: lsFoldLimit = rl.getInt
  let prep = td{"rename"}{"prepareSupport"}.getBool(false)
  lsSemRefresh = caps{"workspace"}{"semanticTokens"}{"refreshSupport"}.getBool(false)
  lsInlayRefresh = caps{"workspace"}{"inlayHint"}{"refreshSupport"}.getBool(false)
  lsWatchFiles = caps{"workspace"}{"didChangeWatchedFiles"}{"dynamicRegistration"}.getBool(false)
  lsPullConfig = caps{"workspace"}{"configuration"}.getBool(false)
  # problems the client asks for (LSP 3.17's pull diagnostics) instead of being sent them: open documents' then
  lsPullDiags = td{"diagnostic"} != nil and td{"diagnostic"}.kind == JObject
  lsDiagRefresh = caps{"workspace"}{"diagnostics"}{"refreshSupport"}.getBool(false)
  lsWsTags = caps{"workspace"}{"symbol"}{"tagSupport"} != nil      # (a deprecated name: struck through)
  # code actions: an edit filled in when chosen; edits and progress nedls sends (Fix with AI); buttons
  lsActionResolve = false
  for p in jitems(td{"codeAction"}{"resolveSupport"}{"properties"}):
    if p.getStr == "edit": lsActionResolve = true
  lsApplyEdit = caps{"workspace"}{"applyEdit"}.getBool(false)
  lsDocChanges = caps{"workspace"}{"workspaceEdit"}{"documentChanges"}.getBool(false)
  lsProgress = caps{"window"}{"workDoneProgress"}.getBool(false)
  lsAskButtons = caps{"window"}{"showMessage"} != nil
  lsParentPid = params{"processId"}.getInt(0)
  lsParentAt = getMonoTime()
  if params{"initializationOptions"} != nil and params["initializationOptions"].kind == JObject:
    lsInitOptions = params["initializationOptions"]
    let ns = lsOpt("nedSettings")
    if ns != nil and ns.kind == JBool: lsUseNedSettings = ns.getBool
  # the project folder: the first workspace folder, else rootUri / rootPath
  var root = ""
  var others: seq[string]
  for f in jitems(params{"workspaceFolders"}):
    let p = lsPathOf(f{"uri"}.getStr)
    if p.len == 0: continue
    if root.len == 0: root = p else: others.add p
  if root.len == 0: root = lsPathOf(params{"rootUri"}.getStr)
  let rp = params{"rootPath"}
  if root.len == 0 and rp != nil and rp.kind == JString: root = rp.getStr
  let home = getHomeDir().normalizedPath.strip(leading = false, chars = {'/'})
  if root.len > 0 and dirExists(root) and root.normalizedPath.strip(leading = false, chars = {'/'}) notin [home, ""]:
    lsSetRoot(root)
  else:
    rootDir = ""                       # (a file on its own: its project, when it is opened)
    lsRootGuess = true
  wsRoots = others
  lsApplySettings()
  privSweep()
  # the toolchain: guessed from `nim` on PATH now; `nim dump` (search paths, defines) runs with the first file
  nxEnsureToolchain(nil)
  let legend = %*{"tokenTypes": LsTokTypes, "tokenModifiers": LsTokMods}
  result = %*{
    "capabilities": {
      "positionEncoding": (if lsUtf8: "utf-8" else: "utf-16"),
      "textDocumentSync": {"openClose": true, "change": 2, "save": {"includeText": false}},
      # (".": Nim's; the others C's -> :: #include "…", HTML's <, CSS's : # @, JSON's ")
      "completionProvider": {"triggerCharacters": [".", ">", ":", "<", "\"", "#", "@", "/"], "resolveProvider": true},
      "hoverProvider": true,
      "signatureHelpProvider": {"triggerCharacters": ["(", ","], "retriggerCharacters": [","]},
      "definitionProvider": true,
      "declarationProvider": true,
      "typeDefinitionProvider": true,
      "referencesProvider": true,
      "documentHighlightProvider": true,
      "renameProvider": (if prep: %*{"prepareProvider": true} else: %true),
      "documentSymbolProvider": true,
      "workspaceSymbolProvider": true,
      "semanticTokensProvider": {"legend": legend, "full": {"delta": true}, "range": true},
      "inlayHintProvider": true,
      "documentFormattingProvider": true,
      "documentRangeFormattingProvider": true,
      "foldingRangeProvider": true,
      "codeActionProvider": {"codeActionKinds": LsActionKinds, "resolveProvider": true},
      "executeCommandProvider": {"commands": [LsCmdRuleOff, LsCmdAiFix, LsCmdRun]},
      "callHierarchyProvider": true,
      "typeHierarchyProvider": true,
      "implementationProvider": true,
      "selectionRangeProvider": true,
      "codeLensProvider": {"resolveProvider": false},
      "documentLinkProvider": {"resolveProvider": false},
      "linkedEditingRangeProvider": true,
      "documentOnTypeFormattingProvider": {"firstTriggerCharacter": "\n"},
      "workspace": {"workspaceFolders": {"supported": true, "changeNotifications": true},
                    "fileOperations": {"willRename": {"filters": [{"scheme": "file", "pattern": {"glob": "**/*.nim"}}]}}}
    },
    "serverInfo": {"name": "nedls", "version": NedVersion}
  }
  if lsPullDiags:
    result["capabilities"]["diagnosticProvider"] = %*{"identifier": "nedls", "interFileDependencies": true,
                                                      "workspaceDiagnostics": true}
  lsLog("ned " & NedVersion & " · project " & rootDir & " · positions " & (if lsUtf8: "UTF-8" else: "UTF-16") &
        " · Nim library " & (if nxLibFound.len > 0: nxLibFound else: "not found (is nim on PATH?)"))

proc lsAskConfig() =
  ## the client's "nedls" settings, asked for (clients that keep settings send none on their own)
  if lsPullConfig: lsConfigReq = lsRequestOut("workspace/configuration", %*{"items": [{"section": "nedls"}]})

proc lsOnInitialized() =
  lsAskConfig()
  if lsWatchFiles:
    lsRequestOut("client/registerCapability", %*{"registrations": [{
      "id": "nedls-watch", "method": "workspace/didChangeWatchedFiles",
      "registerOptions": {"watchers": [{"globPattern": "**/*.{nim,nims,nimble}"},
                                       {"globPattern": "**/{nim.cfg,config.nims,.ned/settings.json}"}]}}]})

proc lsFilesChanged(params: JsonNode) =
  ## files created, changed or deleted outside the editor
  for ch in jitems(params{"changes"}):
    let p = lsPathOf(ch{"uri"}.getStr)
    let typ = ch{"type"}.getInt
    if p.len == 0: continue
    nxStatForget(p)                                      # (its stamp read again now, not up to a second later)
    let name = extractFilename(p)
    if typ in [1, 3]:
      fileCacheValid = false                             # (the project's file list)
      lsWsFilesComeAndGo()
    lsWsChanged(p)
    if typ == 3 and p in lsLintDiags: lsLintDiags.del p
    else: lsLintAgain(p)
    if name in ["nim.cfg", "config.nims"] or name.endsWith(".nimble"):
      nxDumped.clear()                                   # (`nim dump` again: search paths, defines)
      nxModCache.clear()
      nxResolveMemo.clear()
    if p.endsWith(".ned/settings.json"): lsApplySettings()
  lsDiskChanged()
  lsDiagsDirty = true

proc lsWorkspaceFolders(params: JsonNode) =
  let ev = params{"event"}
  for f in jitems(ev{"removed"}):
    let p = lsPathOf(f{"uri"}.getStr)
    let k = wsRoots.find(p)
    if k >= 0: wsRoots.delete(k)
  for f in jitems(ev{"added"}):
    let p = lsPathOf(f{"uri"}.getStr)
    if p.len > 0 and p != rootDir and p notin wsRoots: wsRoots.add p
  fileCacheValid = false
  lsWsFilesComeAndGo()

# ── dispatch ──

proc lsIdKey(id: JsonNode): string = (if id == nil: "" else: $id)

proc lsHandleRequest(meth: string, params: JsonNode, id: JsonNode) =
  ## one request: its answer, or an error answer — never a crash
  if not lsInitialized and meth != "initialize":
    lsReplyError(id, ErrNotInitialized, "the server is not initialized yet")
    return
  if lsShutdown and meth != "shutdown":
    lsReplyError(id, ErrInvalidRequest, "the server is shutting down")
    return
  let p = if params == nil: newJObject() else: params
  if lxHandle(meth, p, id): return            # (a document in another language: ned's engine for it)
  case meth
  of "initialize":
    if lsInitialized:
      lsReplyError(id, ErrInvalidRequest, "initialize was already received")
      return
    let r = lsInitialize(p)
    lsInitialized = true
    lsReply(id, r)
  of "shutdown":
    lsShutdown = true
    if lsWsPull != nil: lsWsPullTry(timedOut = true)   # (a workspace/diagnostic held: answered now)
    lsReply(id, newJNull())
  of "textDocument/completion": lsReply(id, lsCompletion(p))
  of "completionItem/resolve": lsReply(id, lsCompletionResolve(p))
  of "textDocument/hover": lsReply(id, lsHover(p))
  of "textDocument/signatureHelp": lsReply(id, lsSignatureHelp(p))
  of "textDocument/definition", "textDocument/declaration":
    lsReply(id, lsDefinition(p))
  of "textDocument/implementation": lsReply(id, lsImplementation(p))
  of "textDocument/prepareCallHierarchy": lsReply(id, lsPrepareCallHierarchy(p))
  of "callHierarchy/incomingCalls": lsReply(id, lsIncomingCalls(p))
  of "callHierarchy/outgoingCalls": lsReply(id, lsOutgoingCalls(p))
  of "textDocument/prepareTypeHierarchy": lsReply(id, lsPrepareTypeHierarchy(p))
  of "typeHierarchy/supertypes": lsReply(id, lsSupertypes(p))
  of "typeHierarchy/subtypes": lsReply(id, lsSubtypes(p))
  of "textDocument/selectionRange": lsReply(id, lsSelectionRanges(p))
  of "textDocument/codeLens": lsReply(id, lsCodeLens(p))
  of "textDocument/documentLink": lsReply(id, lsDocumentLinks(p))
  of "textDocument/diagnostic": lsReply(id, lsPullDiagnostics(p))
  of "workspace/diagnostic": lsWorkspaceDiagnostic(id, p)          # (answered now, or when something changes)
  of "textDocument/linkedEditingRange": lsReply(id, newJNull())        # (Nim: none; HTML's in langs.nim)
  of "textDocument/onTypeFormatting": lsReply(id, lsOnTypeFormatting(p))
  of "workspace/willRenameFiles": lsReply(id, lsWillRenameFiles(p))
  of "textDocument/typeDefinition": lsReply(id, lsTypeDefinition(p))
  of "textDocument/references": lsReply(id, lsReferences(p))
  of "textDocument/documentHighlight": lsReply(id, lsDocumentHighlight(p))
  of "textDocument/prepareRename": lsReply(id, lsPrepareRename(p))
  of "textDocument/rename": lsReply(id, lsRename(p))
  of "textDocument/documentSymbol": lsReply(id, lsDocumentSymbol(p))
  of "workspace/symbol": lsReply(id, lsWorkspaceSymbol(p))
  of "textDocument/semanticTokens/full": lsReplyRaw(id, lsSemFull(lsDocOf(p)))
  of "textDocument/semanticTokens/full/delta": lsReplyRaw(id, lsSemDelta(lsDocOf(p), p))
  of "textDocument/semanticTokens/range": lsReplyRaw(id, lsSemRange(lsDocOf(p), p))
  of "textDocument/inlayHint": lsReply(id, lsInlayHints(p))
  of "textDocument/formatting": lsReply(id, lsFormatting(p))
  of "textDocument/rangeFormatting": lsReply(id, lsRangeFormatting(p))
  of "textDocument/foldingRange": lsReply(id, lsFoldingRanges(p))
  of "textDocument/codeAction": lsReply(id, lsCodeActions(p))
  of "codeAction/resolve": lsReply(id, lsCodeActionResolve(p))
  of "workspace/executeCommand": lsReply(id, lsExecuteCommand(p))
  else:
    lsReplyError(id, ErrMethodNotFound, "method not found: " & meth)

proc lsHandleNotification(meth: string, params: JsonNode) =
  if meth == "exit":
    lsExit = true
    return
  if not lsInitialized: return                 # (dropped before initialize, as the protocol says)
  let p = if params == nil: newJObject() else: params
  case meth
  of "initialized": lsOnInitialized()
  of "textDocument/didOpen":
    let td = p{"textDocument"}
    let u = td{"uri"}.getStr
    if u.len == 0: lsRaise(ErrInvalidParams, "textDocument.uri expected")
    let path = lsPathOf(u)
    if lsRootGuess and path.len > 0:
      # no folder from the client: the project the file belongs to (else its own folder), as `ned file.nim` does
      lsRootGuess = false
      var r = projectRootOf(path)
      if r.len == 0: r = parentDir(path)
      lsSetRoot(r)
      lsApplySettings()                        # (the project's own settings, now that there is one)
    discard lsOpenDoc(u, td{"text"}.getStr, td{"version"}.getInt, td{"languageId"}.getStr)
    lsWsChanged(path)
    lsDiskChanged()
    lsDiagsDirty = true
  of "textDocument/didChange":
    let d = lsDocOf(p)
    for ch in jitems(p{"contentChanges"}): lsApplyChange(d, ch)
    d.version = p{"textDocument"}{"version"}.getInt(d.version + 1)
    lsKillStaleCheck(d)
    lsWsChanged(d.b.path)
    lsDiagsDirty = true
  of "textDocument/didSave":
    let d = lsDocOf(p)
    let b = d.b
    let t = p{"text"}
    if t != nil and t.kind == JString and lsNormText(t.getStr) != b.allText & "\n" and
       lsNormText(t.getStr) != b.allText:
      lsApplyChange(d, %*{"text": t.getStr})
    b.savedSeq = b.topSeq()
    if b.path.len > 0:
      if b.path == configFile() or b.path.endsWith("/.ned/settings.json"): lsApplySettings()
      lsSaved(b)
      lsWsChanged(b.path)
      lsLintAgain(b.path)                # (the files that import it: their problems may have changed)
    lsDiskChanged()
    lsDiagsDirty = true
  of "textDocument/didClose":
    let cd = lsDocs.getOrDefault(p{"textDocument"}{"uri"}.getStr)
    if cd != nil and cd.b.path.len > 0:
      # (a check of it waiting, or running: not wanted now — its problems would come back after the close)
      let path = cd.b.path
      var k = 0
      while k < lsCheckQueue.len:
        if lsCheckQueue[k][0] == path: lsCheckQueue.delete(k) else: inc k
      for j in jobs:
        if j.kind == jkCheck and not j.done and quoteShell(path) in j.cmd: killProc(j.pr, SIGKILL)
      lsPulled.del path                # (closed: its problems are sent again, as for any file not open)
      lsAnnounced.del path
    let cu = p{"textDocument"}{"uri"}.getStr
    lsCloseDoc(cu)
    lsSemForget(cu)
    if cd != nil:
      # (what the editor's parts kept for it goes, as when a tab closes: nedls kept it all, for every file a client
      # ever closed)
      bufForget(cd.b.id)
      lxCheckedAt.del cd.b.id
      lsWarmed.excl cd.b.id
      lsWsChanged(cd.b.path)           # (its names as the file on disk has them)
      lsLintAgain(cd.b.path)           # (not open now: ned's checks of the file on disk, for the workspace's problems)
    lsDiskChanged()
    lsDiagsDirty = true
  of "workspace/didChangeConfiguration":
    let s = p{"settings"}
    if s != nil and s.kind == JObject and s.len > 0:
      lsOptions = s
      lsApplySettings()
    else: lsAskConfig()
  of "workspace/didChangeWatchedFiles": lsFilesChanged(p)
  of "workspace/didChangeWorkspaceFolders": lsWorkspaceFolders(p)
  of "$/cancelRequest":
    if lsWsPullDrop(p{"id"}): return                     # (the workspace/diagnostic held: answered as cancelled)
    if lsCancelled.len > 1000: lsCancelled.clear()       # (cancels of requests already answered pile up)
    lsCancelled.incl lsIdKey(p{"id"})
  else: discard                                # ($/setTrace, $/progress … and unknown ones: nothing to do)

proc lsHandle(msg: JsonNode) =
  lsHeardAt = getMonoTime()              # (the idle work — the workspace's checks, its symbols — waits for a pause)
  if msg == nil or msg.kind != JObject:
    lsReplyError(newJNull(), ErrInvalidRequest, "a message must be a JSON object")
    return
  let id = msg{"id"}
  let methNode = msg{"method"}
  if methNode == nil:
    # an answer to one of nedls's requests: the settings it asked for, an edit it sent, a button pressed …
    if id != nil and id.kind == JString and id.getStr in lsAnswers:
      let cb = lsAnswers[id.getStr]
      lsAnswers.del id.getStr
      try: cb(msg)
      except Exception as e: lsLog("answer " & id.getStr & ": " & e.msg)
      return
    if id != nil and id.kind == JString and id.getStr == lsConfigReq and lsConfigReq.len > 0:
      lsConfigReq = ""
      let r = msg{"result"}
      if r != nil and r.kind == JArray and r.len > 0 and r[0].kind == JObject:
        lsOptions = %*{"nedls": r[0]}
        try: lsApplySettings()
        except Exception as e: lsLog("settings: " & e.msg)
    return
  if methNode.kind != JString:
    if id != nil: lsReplyError(id, ErrInvalidRequest, "method must be a string")
    return
  let meth = methNode.getStr
  if id != nil and id.kind notin {JInt, JString}:
    lsReplyError(newJNull(), ErrInvalidRequest, "id must be a number or a string")
    return
  let params = msg{"params"}
  let t0 = getMonoTime()
  let logLen = msgLog.len
  if id != nil:
    let key = lsIdKey(id)
    if key in lsCancelled:
      lsCancelled.excl key
      lsReplyError(id, ErrRequestCancelled, "cancelled")
      return
    try: lsHandleRequest(meth, params, id)
    except LsError as e: lsReplyError(id, e.code, e.msg)
    except Exception as e:
      lsLog(meth & " failed: " & $e.name & ": " & e.msg & "\n" & e.getStackTrace())
      lsReplyError(id, ErrInternal, meth & ": " & e.msg)
  else:
    try: lsHandleNotification(meth, params)
    except LsError as e: lsLog(meth & ": " & e.msg)
    except Exception as e: lsLog(meth & " failed: " & $e.name & ": " & e.msg & "\n" & e.getStackTrace())
  # what ned said meanwhile (a warning, an internal error): to the log
  for k in logLen ..< msgLog.len:
    let (_, sev, s) = msgLog[k]
    if sev in {1, 2}: lsLog(s)
  if lsVerbose:
    lsLog(meth & (if id != nil: " #" & $id else: "") & " — " &
          formatFloat(float((getMonoTime() - t0).inMicroseconds) / 1000.0, ffDecimal, 2) & " ms")

proc lsTakeQueue() =
  ## handle the queued messages in order; a request cancelled later in the queue is answered as cancelled
  for m in lsQueue:
    if m != nil and m.kind == JObject and m{"method"}.getStr == "$/cancelRequest":
      lsCancelled.incl lsIdKey(m{"params"}{"id"})
  var i = 0
  while i < lsQueue.len and not lsExit and not lsOutBroken:
    let m = lsQueue[i]
    inc i
    lsHandle(m)
  if i >= lsQueue.len: lsQueue.setLen(0)
  else: lsQueue = lsQueue[i .. ^1]

# ── idle work ──

proc lsIdle() =
  ## while nothing is asked: the project's file list, the open documents' imports read ahead
  if scanning:
    pumpScan(20)
    return
  pkgWatchPump()                         # (a nimble package installed meanwhile: read, the documents checked again)
  if lsActive != nil and lsActive.b.id notin lsWarmed and msSince(lsActive.changedAt) > 50:
    lsWarmed.incl lsActive.b.id
    let b = lsActive.b
    if nimEngineOn(b):
      try: discard nxScope(nxFileFor(b))
      except Exception as e: lsLog("reading imports: " & e.msg)
    return
  # (the workspace: its names for workspace/symbol, ned's checks of its files for workspace/diagnostic)
  try: lsWsIdle()
  except Exception as e:
    lsLog("workspace symbols: " & e.msg)
    lsWsBusy = false
  try: lsLintPump()
  except Exception as e: lsLog("workspace checks: " & e.msg)

proc lsParentGone(): bool =
  ## the client process ended without saying so
  if lsParentPid <= 0 or msSince(lsParentAt) < 3000: return false
  lsParentAt = getMonoTime()
  posix.kill(Pid(lsParentPid), 0) != 0 and errno == ESRCH

proc lsCleanup() =
  for j in jobs:
    if not j.done: killProc(j.pr, SIGKILL)
  for _, (id, t, copy) in typingChecks:
    try:
      if copy.len > 0: removeFile(copy)
    except CatchableError: discard
  typingChecks.clear()

proc lsMainLoop() =
  var lastNx = nxGen
  while not lsExit:
    if lsSignal != 0 or lsOutBroken: break
    var fds = @[TPollfd(fd: lsInFd, events: POLLIN)]
    if lsEof: fds.setLen(0)
    var timeout = 1000
    if lsQueue.len > 0: timeout = 0
    for j in jobs:
      if not j.eof and j.outFd >= 0: fds.add TPollfd(fd: j.outFd, events: POLLIN)
      elif j.eof and not j.done: timeout = min(timeout, 30)
    timeout = min(timeout, lsTimeToNextCheck())
    if scanning or (lsActive != nil and lsActive.b.id notin lsWarmed): timeout = min(timeout, 60)
    if lsDiagsDirty: timeout = min(timeout, 50)
    if reapPids.len > 0: timeout = min(timeout, 500)
    timeout = min(timeout, min(lsWsNextMs(), lsLintNext()))
    if lsEof and jobs.len == 0 and lsQueue.len == 0: break
    var ready: HashSet[cint]
    if fds.len > 0:
      let r = poll(addr fds[0], fds.len.Tnfds, timeout.cint)
      if r < 0 and errno != EINTR: os.sleep(10)
      elif r > 0:
        for f in fds:
          if (f.revents and (POLLIN or POLLHUP or POLLERR)) != 0: ready.incl f.fd
    else: os.sleep(timeout)
    if lsInFd in ready:
      if not lsReadInput():
        lsEof = true
      lsTakeMessages()
    lsTakeQueue()
    if lsExit: break
    if jobs.len > 0:
      let before = jobs.len
      try: pumpJobs(ready)
      except Exception as e: lsLog("checks: " & e.msg)
      if jobs.len != before:
        lsDiagsDirty = true
        lsDiskChanged()                  # (a check finished: another file's problems too, maybe)
    reapPending()
    if lsQueue.len == 0:
      lsPumpChecks()
      if lsDiagsDirty and msSince(lsPublishedAt) > 40: lsPublishAll()
      if lsWsPull != nil and msSince(lsWsPullAt) > LsWsPullHoldMs: lsWsPullTry(timedOut = true)
      lsWsPullMode()
      lsIdle()
    if nxGen != lastNx:
      # the toolchain changed (`nim dump` answered): colours and hints may be different now
      lastNx = nxGen
      if lsSemRefresh: lsRequestOut("workspace/semanticTokens/refresh", newJNull())
      if lsInlayRefresh: lsRequestOut("workspace/inlayHint/refresh", newJNull())
    if lsEof and lsQueue.len == 0: break
    if lsParentGone():
      lsLog("the client process ended — stopping")
      break

proc nedlsMain(): int =
  let args = commandLineParams()
  let li = args.find("--lint")
  if li >= 0:                                  # (the engine's checks over files, then out: ned --lint's)
    signal(SIGPIPE, SIG_DFL)
    return lintMain(args[li + 1 .. ^1], "nedls --lint")
  for a in args:
    case a
    of "--version", "-V":
      echo "nedls " & NedVersion & " (ned's Nim engine as a language server)"
      return 0
    of "--help", "-h":
      stdout.write LsHelp
      return 0
    of "--stdio": discard
    of "--verbose", "-v": lsVerbose = true
    else:
      if a.startsWith("--log:") or a.startsWith("--log="): lsLogPath = a[6 .. ^1]
      elif a.startsWith("--clientProcessId"): discard           # (some clients add it: initialize says it too)
      else:
        stderr.writeLine("nedls: unknown option " & a & " (nedls --help)")
        return 2
  lsTakeStdio()
  signal(SIGPIPE, SIG_IGN)
  signal(SIGTERM, onLsSignal)
  signal(SIGINT, onLsSignal)
  initLangs()
  bufs = @[newBuffer()]                        # (ned's current buffer when no document is: an empty one)
  curBuf = 0
  textH = 40
  try: lsMainLoop()
  except Exception as e:
    lsLog("fatal: " & $e.name & ": " & e.msg & "\n" & e.getStackTrace())
    lsCleanup()
    return 1
  lsCleanup()
  if lsSignal != 0: return 1
  if lsShutdown: 0 else: 1
