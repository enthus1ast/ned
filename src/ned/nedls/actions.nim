# ════════════════════════════════════════════════════════════════════════════
#  nedls — code actions: what the editor's Alt+Enter offers, for the lines the client asks about. Quick fixes
#  for the problems there (each one's own fix, all of a kind in the file, the import that declares a name, the
#  rule silenced on the line), the refactorings that are an edit of the text (generate, inline, extract, the
#  missing case branches and fields …), and the source actions Organize imports and Fix all. Each is the edit
#  ned would make, found by running it on ned's buffer and undoing it (lsDryRun) — at once, or when the client
#  resolves the action it picked. Two are commands nedls carries out itself: a rule turned off for the project
#  (it writes .ned/lint.json) and Fix with AI (the model's answer checked with `nim check` on a private copy
#  before the client is asked to apply it: workspace/applyEdit).
# ════════════════════════════════════════════════════════════════════════════

const
  LsCmdRuleOff = "nedls.lintRuleOff"
  LsCmdAiFix = "nedls.aiFix"
  LsAiFixTitle = "Fix with AI (checked with nim check)"
  LsActionKinds = ["quickfix", "refactor.extract", "refactor.inline", "refactor.rewrite", "source.organizeImports",
                   "source.fixAll"]
  LsAiSystem = "You fix Nim code in the user's editor. Reply with only the replacement code you are asked for."

type
  LsAct = tuple[title, kind: string, act: Action, cmd: JsonNode]   # an edit to work out (act) or a command

  LsAiFix = object             # the AI fix being worked on (one at a time)
    running: bool
    d: LsDoc
    version: int               # (the document's version it is for: applied only to that text)
    diag: Diag
    a, e: Pos                  # the code the model rewrites
    attempt: int               # 1: asked again with what nim check said
    prev, prevErr: string
    retried: bool              # (asked again once after the provider refused a parameter it then learned)
    token: string              # the progress shown in the client ("" none)
    shown: bool                # (its "begin" was sent)

var
  lsActionResolve = false      # the client fills in a chosen action's edit (codeAction/resolve)
  lsApplyEdit = false          # the client applies an edit nedls sends (workspace/applyEdit)
  lsDocChanges = false         # … with the document's version (documentChanges: a changed text is left alone)
  lsProgress = false           # the client shows progress nedls reports (window/workDoneProgress)
  lsAskButtons = false         # the client asks the user with buttons (window/showMessageRequest)
  lsAnswers: Table[string, proc(m: JsonNode) {.closure.}]    # nedls's request to the client → what to do with
                                                             #   its answer
  lsAi: LsAiFix
  lsAiN = 0

proc lsAsk(meth: string, params: JsonNode, onAnswer: proc(m: JsonNode) {.closure.}) =
  ## a request to the client, and what to do with its answer (a client that never answers some: a few hundred
  ## waiting at most)
  if lsAnswers.len > 200: lsAnswers.clear()
  lsAnswers[lsRequestOut(meth, params)] = onAnswer

# ── kinds ──

proc lsKindWanted(only: JsonNode, kind: string): bool =
  ## LSP's `only`: none — every kind; else a kind it lists, or one under it ("refactor" → "refactor.inline")
  if only == nil or only.kind != JArray or only.len == 0: return true
  for k in only.elems:
    let w = k.getStr
    if w.len > 0 and (kind == w or kind.startsWith(w & ".")): return true
  false

proc lsAsked(only: JsonNode, kind: string): bool =
  ## the client named this kind (or one above it) in `only`
  only != nil and only.kind == JArray and only.len > 0 and lsKindWanted(only, kind)

proc lsMayWant(only: JsonNode, prefix: string): bool =
  ## could `only` want a kind under prefix ("refactor": refactor.inline, …)
  if only == nil or only.kind != JArray or only.len == 0: return true
  for k in only.elems:
    let w = k.getStr
    if w == prefix or w.startsWith(prefix & ".") or prefix.startsWith(w & "."): return true
  false

proc lsRefactorKind(title: string): string =
  if title.startsWith("Inline "): "refactor.inline"
  elif title.startsWith("Extract "): "refactor.extract"
  else: "refactor.rewrite"

proc lsAiReady(): bool =
  ## Fix with AI can be offered: a model set up in ned's settings (ai.provider and its key), curl and nim at hand,
  ## a client that applies edits — and the client did not turn it off (aiFix: false)
  let o = lsOpt("aiFix")
  if o != nil and o.kind == JBool and not o.getBool: return false
  lsApplyEdit and cfgAiProvider notin ["", "off"] and (cfgAiProvider in ["ollama", "custom"] or aiKey().len > 0) and
    haveExe("curl") and haveExe("nim")

# ── the list ──

proc lsSelect(d: LsDoc, a, e: Pos) =
  ## the document current, with a..e selected (ned's commands work on the cursor and the selection)
  lsFocus(d, a)
  if e != a: d.b.setSingle(e, a)

proc lsActionsAt(d: LsDoc, a, e: Pos, only: JsonNode): seq[LsAct] =
  ## the actions for a..e of a document, in the editor's order: the problems' fixes, then the refactorings, then
  ## the source actions (listed when asked for — or Organize imports on an import line)
  let b = d.b
  lsSelect(d, a, e)
  if lsKindWanted(only, "quickfix"):
    var ds: seq[Diag]
    for x in diagsFor(b.path):
      if x.line <= e.line and max(x.line, x.eline) >= a.line: ds.add x
    ds.sort(proc(x, y: Diag): int = cmp(x.sev, y.sev))
    if ds.len > 0:
      var fixes: seq[(string, string, Action)]
      try: fixes = nimProblemFixes(b, ds)
      except Exception as ex: lsLog("quick fixes: " & ex.msg)
      var rules: seq[string]
      for x in ds:
        if x.src == "ned" and x.rule.len > 0 and x.rule notin rules: rules.add x.rule
      for (title, _, act) in fixes:
        var cmd: JsonNode = nil
        for r in rules:
          if title == "Turn off " & r & " for this project":     # (it writes a file: nedls does it itself)
            cmd = %*{"title": title, "command": LsCmdRuleOff, "arguments": [b.path, r]}
        result.add (title, "quickfix", (if cmd != nil: Action(nil) else: act), cmd)
      if b.path.endsWith(".nim") and lsAiReady():
        for x in ds:
          if x.sev == 1:
            result.add (LsAiFixTitle, "quickfix", Action(nil), %*{"title": LsAiFixTitle, "command": LsCmdAiFix,
                        "arguments": [d.uri, d.version, x.line, x.msg.splitLines()[0]]})
            break
  if lsMayWant(only, "refactor"):
    lsSelect(d, a, e)
    if b.lang.mode == lmNim:
      let (l, _, body, lg) = b.embeddedStringAt(b.primary.head)
      if l >= 0 and lg != nil and body.len >= 2 and lsKindWanted(only, "refactor.rewrite"):
        let fa: Action = proc() = cmdFormatEmbedded()
        result.add ("Format the " & lg.name & " in this string", "refactor.rewrite", fa, JsonNode(nil))
    var rs: seq[(string, string, Action)]
    try: rs = nimRefactors(b, lsp = true)
    except Exception as ex: lsLog("refactorings: " & ex.msg)
    for (title, _, act) in rs:
      let k = lsRefactorKind(title)
      if lsKindWanted(only, k): result.add (title, k, act, JsonNode(nil))
  let t = b.lines[a.line].strip
  let noOnly = only == nil or only.kind != JArray or only.len == 0
  if lsAsked(only, "source.organizeImports") or (noOnly and (t.startsWith("import ") or t.startsWith("from "))):
    let oa: Action = proc() = cmdOrganizeImports()
    result.add ("Organize imports", "source.organizeImports", oa, JsonNode(nil))
  if lsAsked(only, "source.fixAll"):
    let (n, act) = nimFixAllKinds(b)
    if n > 0: result.add ("Fix all " & $n & " problems ned can fix in this file", "source.fixAll", act, JsonNode(nil))

proc lsEditOf(d: LsDoc, a, e: Pos, act: Action): JsonNode =
  ## the WorkspaceEdit an action makes (nil: none)
  lsSelect(d, a, e)
  lsWorkspaceEdit(lsDryRun(act))

proc lsCodeActions(params: JsonNode): JsonNode =
  let d = lsDocOf(params)
  result = newJArray()
  if not lsEngineOn(d) or d.b.path.len == 0: return
  let only = params{"context"}{"only"}
  let r = params{"range"}
  let a = lsToPos(d.b, r{"start"})
  var e = lsToPos(d.b, r{"end"})
  if e < a: e = a
  var acts: seq[LsAct]
  try: acts = lsActionsAt(d, a, e, only)
  except Exception as ex: lsLog("code actions: " & ex.msg)
  for x in acts:
    var j = %*{"title": x.title, "kind": x.kind}
    if x.cmd != nil: j["command"] = x.cmd
    elif x.kind == "quickfix" or not lsActionResolve:
      # (a quick fix is worked out at once — one that changes nothing is not listed; the rest when chosen, when
      # the client can ask for that)
      let we = lsEditOf(d, a, e, x.act)
      if we == nil: continue
      j["edit"] = we
    else:
      j["data"] = %*{"uri": d.uri, "version": d.version, "range": r}
    result.add j

proc lsCodeActionResolve(params: JsonNode): JsonNode =
  ## the edit of an action the client picked (listed without it): worked out on the text it was listed for
  result = params
  let data = params{"data"}
  if data == nil or data.kind != JObject or params{"edit"} != nil: return
  let d = lsDocs.getOrDefault(data{"uri"}.getStr)
  let title = params{"title"}.getStr
  if d == nil or d.version != data{"version"}.getInt(-1):
    lsLog("code action \"" & title & "\": the document changed since it was listed — no edit")
    return
  let r = data{"range"}
  let a = lsToPos(d.b, r{"start"})
  var e = lsToPos(d.b, r{"end"})
  if e < a: e = a
  for x in lsActionsAt(d, a, e, %*[params{"kind"}.getStr]):
    if x.title == title and x.act != nil:
      let we = lsEditOf(d, a, e, x.act)
      if we != nil: result["edit"] = we
      return

# ── sending edits ──

proc lsApplyText(d: LsDoc, a, e: Pos, text, label: string) =
  ## ask the client to put `text` in place of a..e (of the text it has now — with documentChanges, only if it is
  ## still the version nedls worked on)
  let eol = lsEol(d.b)
  let t = if eol == "\n": text else: text.replace("\n", eol)
  let te = %*[{"range": lsRangeIn(d.b.lines, a.line, a.col, e.line, e.col), "newText": t}]
  let edit = if lsDocChanges: %*{"documentChanges": [{"textDocument": {"uri": d.uri, "version": d.version},
                                                      "edits": te}]}
             else: %*{"changes": {d.uri: te}}
  lsAsk("workspace/applyEdit", %*{"label": label, "edit": edit}, proc(m: JsonNode) =
    let r = m{"result"}
    if m{"error"} != nil or r == nil or r.kind != JObject or not r{"applied"}.getBool(false):
      let why = if r != nil and r.kind == JObject: r{"failureReason"}.getStr else: m{"error"}{"message"}.getStr
      lsShowMessage(2, label & ": the editor did not apply it" & (if why.len > 0: " (" & why & ")" else: "")))

# ── Fix with AI ──

proc lsProgressStart(title, msg: string) =
  lsAi.token = ""
  lsAi.shown = false
  if not lsProgress: return
  inc lsAiN
  let tok = "nedls-ai-" & $lsAiN
  lsAi.token = tok
  lsAsk("window/workDoneProgress/create", %*{"token": tok}, proc(m: JsonNode) =
    if m{"error"} == nil and lsAi.running and lsAi.token == tok:      # (still going: show it)
      lsNotify("$/progress", %*{"token": tok, "value": {"kind": "begin", "title": title, "message": msg,
                                                         "cancellable": false}})
      lsAi.shown = true)

proc lsProgressSay(msg: string) =
  if lsAi.shown: lsNotify("$/progress", %*{"token": lsAi.token, "value": {"kind": "report", "message": msg}})

proc lsAiDone(msg: string, typ: int) =
  ## the AI fix is over: what came of it
  if lsAi.shown: lsNotify("$/progress", %*{"token": lsAi.token, "value": {"kind": "end", "message": msg}})
  lsAi.token = ""
  lsAi.shown = false
  lsAi.running = false
  lsShowMessage(typ, msg)

proc lsAiValid(): bool =
  ## the document is still open and still the text the model was asked about
  lsAi.running and lsDocs.getOrDefault(lsAi.d.uri) == lsAi.d and lsAi.d.version == lsAi.version

proc lsAiAsk()

proc lsAiChecked(code: string, bad: seq[string]) =
  if not lsAi.running: return
  if not lsAiValid():
    lsAiDone("Fix with AI: the file changed meanwhile — ask again", 2)
    return
  if bad.len == 0:
    lsApplyText(lsAi.d, lsAi.a, lsAi.e, code, "Fix with AI")
    lsAiDone("AI fix applied — nim check passes for it", 3)
    return
  if lsAi.attempt == 0:
    lsAi.attempt = 1
    lsAi.prev = code
    lsAi.prevErr = bad[0 ..< min(3, bad.len)].join("\n")
    lsProgressSay("its answer did not compile (" & bad[0] & ") — asking again with the error…")
    lsAiAsk()
    return
  # still wrong after the second answer: the user decides
  let msg = "the AI's fix still does not compile: " & bad[0]
  if not lsAskButtons:
    lsAiDone(msg, 2)
    return
  let (d, ver, a, e) = (lsAi.d, lsAi.version, lsAi.a, lsAi.e)
  if lsAi.shown: lsNotify("$/progress", %*{"token": lsAi.token, "value": {"kind": "end", "message": msg}})
  lsAi.token = ""
  lsAi.shown = false
  lsAi.running = false
  let buttons = %*{"type": 2, "message": "nedls: " & msg, "actions": [{"title": "Apply anyway"}, {"title": "Leave it"}]}
  lsAsk("window/showMessageRequest", buttons, proc(m: JsonNode) =
    if m{"result"}{"title"}.getStr != "Apply anyway": return
    if lsDocs.getOrDefault(d.uri) == d and d.version == ver: lsApplyText(d, a, e, code, "Fix with AI (not compiling)")
    else: lsShowMessage(2, "the file changed meanwhile — the AI's fix was not applied"))

proc lsAiAnswer(text: string) =
  ## the model's answer: put in a copy of the file and checked with nim check
  if not lsAi.running: return
  if not lsAiValid():
    lsAiDone("Fix with AI: the file changed while the model worked — ask again", 2)
    return
  let code = inlineClean(text)
  if code.strip.len == 0:
    lsAiDone("Fix with AI: the model gave no code", 2)
    return
  let b = lsAi.d.b
  let (cand, lo, hi) = aiFixCandidate(b, lsAi.a, lsAi.e, text)
  lsProgressSay("checking its answer with nim check…")
  let started = aiFixCheck(b, cand, lo, hi, lsAi.diag.msg.splitLines()[0], proc(bad: seq[string]) =
    lsAiChecked(code, bad))
  if not started: lsAiDone("Fix with AI: no copy of the file could be written to check the answer", 1)

proc lsAiFailed(why: string) =
  if lsAi.running: lsAiDone("Fix with AI: " & why, 1)

proc lsAiRetry() =
  ## the provider refused a parameter ned has now learned: once more
  if not lsAi.running: return
  if lsAi.retried:
    lsAiDone("Fix with AI: the provider refused the request", 1)
    return
  lsAi.retried = true
  lsAiAsk()

proc lsAiAsk() =
  let b = lsAi.d.b
  let instr = aiFixInstr(b, lsAi.diag, lsAi.attempt, lsAi.prev, lsAi.prevErr)
  let job = aiFastAsk(LsAiSystem, aiInlinePrompt(b, lsAi.a, lsAi.e, instr), 8000, lsAiAnswer, lsAiRetry,
                      model = aiModel(), timeoutS = 120, onFail = lsAiFailed)
  if job == nil: lsAiDone("Fix with AI: no model to ask — set ai.provider and its key in ned's settings", 2)

proc lsAiFixStart(args: JsonNode) =
  ## nedls.aiFix [uri, version, line, message]: ask the model to fix that problem
  if args == nil or args.kind != JArray or args.len < 4:
    lsRaise(ErrInvalidParams, "nedls.aiFix: uri, version, line, message")
  if lsAi.running:
    lsShowMessage(2, "an AI fix is being worked on already — one at a time")
    return
  let d = lsDocs.getOrDefault(args[0].getStr)
  if d == nil:
    lsShowMessage(2, "Fix with AI: the document is not open")
    return
  if d.version != args[1].getInt(-1):
    lsShowMessage(2, "Fix with AI: the file changed — ask again")
    return
  let line = args[2].getInt(-1)
  let msg = args[3].getStr
  var diag = Diag(line: -1)
  for x in diagsFor(d.b.path):
    if x.line == line and x.sev == 1 and x.msg.splitLines()[0] == msg:
      diag = x
      break
  if diag.line < 0:
    for x in diagsFor(d.b.path):
      if x.line == line and x.sev == 1:
        diag = x
        break
  if diag.line < 0 or diag.line > d.b.lines.high:
    lsShowMessage(3, "Fix with AI: that problem is gone")
    return
  lsAi = LsAiFix(running: true, d: d, version: d.version, diag: diag)
  (lsAi.a, lsAi.e) = aiFixRegion(d.b, diag)
  let model = if aiModel().len > 0: aiModel() else: ghostModel()
  lsProgressStart("Fix with AI", "asking " & model & "…")
  lsAiAsk()

# ── commands ──

proc lsRuleOff(args: JsonNode) =
  ## nedls.lintRuleOff [path, rule]: the rule off in the project's .ned/lint.json; the open files checked again
  if args == nil or args.kind != JArray or args.len < 2: lsRaise(ErrInvalidParams, "nedls.lintRuleOff: path, rule")
  let path = args[0].getStr
  let rule = args[1].getStr
  var known = false
  for (r, _, _) in NedRules:
    if r == rule: known = true
  if not known: lsRaise(ErrInvalidParams, "nedls.lintRuleOff: no rule " & rule)
  if lsDocByPath(path) == nil: lsRaise(ErrInvalidParams, "nedls.lintRuleOff: " & path & " is not open")
  lintRuleOffAct(path, rule)()
  typoAt.clear()
  for _, d in lsDocs:
    if lsEngineOn(d) and (d.b.dirty or engineChecksOnOpen(d.b)):
      try: lsEngineChecks(d)
      except Exception as e: lsLog("checks: " & e.msg)
  lsDiagsDirty = true
  lsShowMessage(3, rule & " is off for this project (.ned/lint.json)")

proc lsExecuteCommand(params: JsonNode): JsonNode =
  result = newJNull()
  let args = params{"arguments"}
  case params{"command"}.getStr
  of LsCmdRuleOff: lsRuleOff(args)
  of LsCmdAiFix: lsAiFixStart(args)
  of LsCmdRun: lsRunLens(args)
  else: lsRaise(ErrInvalidParams, "unknown command: " & params{"command"}.getStr)
