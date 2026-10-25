# ════════════════════════════════════════════════════════════════════════════
#  Forward declarations
# ════════════════════════════════════════════════════════════════════════════

proc refreshGit(b: Buffer)
proc applyNimToolchain()
var wkWorkerMode = false            # this process is the engine worker (`ned --engine-worker`, nim/worker.nim)
proc wkOn(): bool
proc wkInlayStep(b: Buffer)
proc wkChecks(b: Buffer)
proc wkDump(proj, o: string)
proc wkSettingsChanged()
proc wkFolderChanged()
proc wkReport(): string
proc engineAgain(path: string)
proc cEngAgain(path: string)
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
proc webComplete(b: Buffer, p: Pos, manual: bool): bool
proc webEngineOn(b: Buffer, p: Pos): bool
proc webHoverInfo(b: Buffer, p: Pos): string
proc webDefinition(b: Buffer, p: Pos): bool
proc webReferences(b: Buffer, p: Pos): bool
proc webRename(b: Buffer, p: Pos, newName: string): bool
proc webJsAt(b: Buffer, p: Pos): bool
proc webChecksPump(b: Buffer)
proc webDiagsOf(b: Buffer): seq[Diag]
proc embHover(b: Buffer, p: Pos, auto: bool): bool
proc embPump(b: Buffer)
proc embClose(b: Buffer)
proc embDocAt(b: Buffer, p: Pos): (LspServer, Buffer)
proc mergeShadowDiags(path: string)
proc emitHoverInfo(b: Buffer, p: Pos): string
proc emitNimHover(b: Buffer, p: Pos): string
type EmitWork = object
  lines: seq[string]          # the file with its emit statements blanked
  stmts: seq[(int, int)]      # each emit statement's first and last line
proc emitTickNames(ls: seq[string]): seq[(int, int, string)]
proc emitNimTargets(lines: seq[string], f: NxFile, l, s, e: int): (seq[NxRef], seq[NxSym])
proc emitWork(ls: seq[string]): EmitWork
proc emitNimTargetsIn(w: var EmitWork, src: seq[string], f: NxFile, l, s, e: int): (seq[NxRef], seq[NxSym])
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
proc cxIsCppBuf(b: Buffer): bool
proc cEngHover(b: Buffer, p: Pos): string
proc cEngDefinition(b: Buffer, p: Pos): bool
proc cEngReferences(b: Buffer, p: Pos): bool
proc cEngRename(b: Buffer, p: Pos, newName: string): bool
proc cEngSignature(b: Buffer, p: Pos): bool
proc cEngOutline(b: Buffer): seq[SideItem]
proc cEngCallHierarchy(b: Buffer): bool
proc cEngInlays(b: Buffer, lo, hi: int)
proc cmdSwitchHeaderSource()
proc ceIsView(b: Buffer): bool
proc ceDrawHeader(b: Buffer, i, x, y, w: int)
proc asmHoverAt(b: Buffer, p: Pos): string
proc ceDefinition(b: Buffer): bool
proc lspAttach(b: Buffer)
proc lspDidSave(b: Buffer)
proc lspDidClose(b: Buffer)
proc openPicker(kind: PickKind, title: string, items: seq[PickItem])
proc openPrompt(kind: PromptKind, label: string, initial = "")
proc askConfirm(message: string, action: proc(c: char) {.closure.})
proc closeComp()
proc showReferences(title: string, hits: seq[(string, int, int)])
proc openScratch(title, content: string, lang: Lang): Buffer
proc gcAfterSave(b: Buffer)
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
# (plugins/host)
proc plugOpened(b: Buffer)
proc plugBeforeSave(b: Buffer)
proc plugSaved(b: Buffer)
proc plugFileSaved(path: string)
proc plugClosed(b: Buffer)
proc plugFormat(b: Buffer): bool
proc plugTextObject(b: Buffer, kind, obj: char, p: Pos): (bool, bool, Pos, Pos)
proc plugExCommand(cmd: string): bool
proc plugVimKey(b: Buffer, ch: char, visual: bool): bool
proc plugVimReset()
proc plugLangKey(n: string): bool
proc plugHasLangKeys(): bool
proc plugWrites(b: Buffer): bool
proc drawKeyHints(bottom: int)
proc plugFixActions(b: Buffer, l0, l1: int): seq[(string, string, Action)]
proc buildPluginItems(): seq[SideItem]
proc plugAskDone(text: string)
proc nbVersionComplete(b: Buffer, p: Pos, manual: bool, force = false): bool
proc nbHover(b: Buffer, p: Pos): string
proc nifHover(b: Buffer, p: Pos): string            # nim/nifview.nim
proc nifDefinition(b: Buffer, p: Pos): bool
proc nifOutlineOf(b: Buffer): seq[SideItem]
proc pnakHover(b: Buffer, p: Pos): string           # nim/pnak.nim
proc pnakDefinition(b: Buffer, p: Pos): bool
proc pnakOutlineOf(b: Buffer): seq[SideItem]
proc pnakUnpinned(nimblePath: string, lines: seq[string]): seq[Diag]
proc cmdPnak(sub: string)
proc nbNameComplete(b: Buffer, p: Pos, manual: bool): bool
proc nbPackageKnown(name: string): int
proc nbPackageList(): seq[(string, string)]
proc nbPackageDefinition(b: Buffer, p: Pos): bool
proc nbPackageTarget(b: Buffer, p: Pos): (string, string, string)
proc nbVersionFixes(b: Buffer): seq[(string, string, Action)]
proc plugComplete(b: Buffer, p: Pos)
proc plugHasCompletions(b: Buffer): bool
proc plugCompMerge()
proc plugHover(b: Buffer, p: Pos, auto: bool): bool
proc plugOutline(b: Buffer): (bool, seq[SideItem])
proc plugSymbolPicks(b: Buffer): seq[PickItem]
proc plugAiRun(name: string, args: JsonNode, done: proc(text: string, isError: bool) {.closure.})
proc plugNew(name0: string)
proc plugInstall(url0: string, name0 = "")
proc plugReload()
proc cmdEncodingMenu()
proc hotExitOn(): bool
proc hotExitSave(): bool
proc keysCheckAtStart()
proc docPvText(b: Buffer): string
proc lfShowAt(b: Buffer, absLine, col: int)
proc lfFind(b: Buffer, q: string, forward = true)
proc lfClose(b: Buffer)
proc lfStatus(b: Buffer): string
proc drawDnd()                                       # ui/dragdrop.nim
proc dndShow(bufId: int)                              # ui/dragdrop.nim
proc dndSplitWith(id: int, down: bool)
proc moveToOtherPane()                               # ui/split.nim
proc plugLibDir(): string                            # plugins/host.nim
proc toSidePane()                                    # ui/split.nim
proc openToSide(path: string, line = -1, col = -1): Buffer   # ui/split.nim
proc splitEditor(down = false)                       # ui/split.nim
proc atlasConfigHover(b: Buffer, p: Pos): string           # nim/atlas.nim
proc verCmp(a, b: string): int                        # nim/nimbleupdates.nim
proc rebuildProblems()                                # ui/panel.nim
proc nbCanRun(b: Buffer): bool                        # editor/notebook.nim
proc isPicturePath(path: string): bool                # editor/pictures.nim
proc picOpen(b: Buffer)
proc drawPicture(b: Buffer, x0, y0, w, h: int)
proc drawFlame(b: Buffer, x0, y0, w, h: int)          # nim/flame.nim
proc nbRunAt(b: Buffer, line: int, advance = false)   # editor/notebook.nim
