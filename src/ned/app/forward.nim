# ════════════════════════════════════════════════════════════════════════════
#  Forward declarations
# ════════════════════════════════════════════════════════════════════════════

proc refreshGit(b: Buffer)
proc applyNimToolchain()
proc engineAgain(path: string)
proc showProblems()
proc pipeThroughCommand(cmd: string)
proc runCheck(b: Buffer)
proc runCheckPath(path, langId: string, keepExamples: bool)
proc recheckBuildErrors(saved: Buffer)
proc ffiCheck(b: Buffer)
proc copiesCheck(b: Buffer, everyRoutine = true)
proc testsOnSave(b: Buffer)
proc gitLoginNeeded(args, root, output: string)
proc gitRemoteUrl(root: string, remote = "origin"): string
proc ghAskAccount()
proc cmdGithubSignIn()
proc gitUndoMenu()
proc gitUndoLast()
proc precommitChecks(root: string, all: bool, commit: proc())
proc reviewNoteAt(path: string, line: int): string
proc reviewHoverAt(path: string, line: int): string
proc reviewsAfterPush(root: string)
proc cxFileOf(b: Buffer): CxFile
proc inactiveRanges(b: Buffer): seq[(int, int)]
proc lineInactive(rs: seq[(int, int)], line: int): bool
proc testNoteAt(b: Buffer, line: int): (string, int)
proc cmdCoverageTestFile(path: string)
var ffiQueue: seq[int]           # buffers whose C wrappers get checked once ned is idle (not before a file shows)
proc cGotoFromDecl(b: Buffer, p: Pos, anyUse = false): bool
proc cHoverInfo(b: Buffer, p: Pos): string
proc emitComplete(b: Buffer, p: Pos, manual: bool): bool
proc emitLspComplete(b: Buffer, p: Pos): bool
proc emitLspDefinition(b: Buffer, p: Pos): bool
proc emitPump(b: Buffer)
proc realPathOf(path: string): string
proc emitIsC(b: Buffer, p: Pos): bool
proc emitLsp(b: Buffer, start = true): (LspServer, Buffer)
proc embComplete(b: Buffer, p: Pos, manual: bool): bool
proc embHover(b: Buffer, p: Pos, auto: bool): bool
proc embPump(b: Buffer)
proc embClose(b: Buffer)
proc embDocAt(b: Buffer, p: Pos): (LspServer, Buffer)
proc mergeShadowDiags(path: string)
proc emitHoverInfo(b: Buffer, p: Pos): string
proc emitGoto(b: Buffer, p: Pos): bool
proc emitLspHover(b: Buffer, p: Pos, auto: bool): bool
proc emitSignature(b: Buffer, p: Pos): bool
proc emitShadowDiags(s: LspServer, shadowPath: string, params: JsonNode)
proc emitClose(b: Buffer)
proc emitNimNote(b: Buffer, w: string): string
proc pragmaStringComplete(b: Buffer, p: Pos, manual: bool): bool
proc pragmaStringHover(b: Buffer, p: Pos): string
proc pragmaStringGoto(b: Buffer, p: Pos): bool
proc cDocForNx(it: NxItem): string
proc cSigHintsUpdate(b: Buffer)
proc cWrapperComplete(b: Buffer, p: Pos, manual: bool): bool
proc cEngineOn(b: Buffer): bool
proc cEngComplete(b: Buffer, p: Pos, manual: bool): bool
proc cEngHover(b: Buffer, p: Pos): string
proc cEngDefinition(b: Buffer, p: Pos): bool
proc cEngReferences(b: Buffer, p: Pos): bool
proc cEngRename(b: Buffer, p: Pos, newName: string): bool
proc cEngSignature(b: Buffer, p: Pos): bool
proc cEngOutline(b: Buffer): seq[SideItem]
proc lspAttach(b: Buffer)
proc lspDidSave(b: Buffer)
proc lspDidClose(b: Buffer)
proc openPicker(kind: PickKind, title: string, items: seq[PickItem])
proc openPrompt(kind: PromptKind, label: string, initial = "")
proc askConfirm(message: string, action: proc(c: char) {.closure.})
proc closeComp()
proc showReferences(title: string, hits: seq[(string, int, int)])
proc openScratch(title, content: string, lang: Lang): Buffer
proc haveExe(name: string): bool
proc nsUsable(b: Buffer): bool
proc nimUsesLsp(): bool
proc nimEngineOn(b: Buffer): bool
proc nsRequest(b: Buffer, kind: NsKind, p: Pos, extra = ""): bool
proc openSettings()
proc requestQuit()
proc cmdProjectSymbols()
proc aiLine(line: string)
proc lspSync(b: Buffer)
proc lensAt(b: Buffer, l: int): (string, Action)
proc replMarker(s: string): bool
proc replSendCell(b: Buffer, line: int)
proc runExamples(b: Buffer, line: int)
var exampleStatus: Table[string, int]    # "path:line" of a runnableExamples block → 1 passed · 2 failed · 3 running

func examplesHead(s: string): bool =
  ## a `runnableExamples:` line — also with flags (`runnableExamples("-r:off"):`) or a comment after the colon
  let t = s.strip
  if not t.startsWith("runnableExamples"): return false
  let rest = t["runnableExamples".len .. ^1]
  if rest.len > 0 and rest[0] in IdentChars: return false
  var inStr = false
  var cut = rest.len
  for i, c in rest:
    if c == '"': inStr = not inStr
    elif c == '#' and not inStr:
      cut = i
      break
  rest[0 ..< cut].strip.endsWith(":")
proc foldRange(b: Buffer, l: int): (bool, int)
proc setPanel(k: PanelKind)
proc toast(text: string, sev = 3, actLabel = "", act: Action = nil, ttl = 0)
proc themeFollowers()           # after the theme changed: Termux's colours (theme.termuxColors)
proc showSide(v: SideView)
proc prepareNimMapping(b: Buffer)
proc nimMapAdd(b: Buffer): bool
proc runCmd(name: string)
proc writeFileSafe(path, content: string, newMode = 0o644)
proc offerRecovery(b: Buffer)
proc macroToggle()
proc macroNoteKey(k: Key)
proc loadMacros()
proc macroBadge(): string
proc keyName(k: Key): string
