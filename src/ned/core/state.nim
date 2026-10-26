# ════════════════════════════════════════════════════════════════════════════
#  Global state
# ════════════════════════════════════════════════════════════════════════════

const NoColor: Rgb = 0xFF000000'u32

const JumpHlMs = 650           # (how long the line a jump lands on stays lit)

var
  bufs: seq[Buffer]
  curBuf = 0
  nextBufId = 1
  focus = fEditor
  quitting = false
  rootDir = ""
  # settings
  cfgTabSize = 4
  cfgWrap = true               # soft wrap for the buffer being drawn or edited (off in large-file mode)
  cfgWrapUser = true           # editor.softWrap
  cfgLargeMB = 16              # editor.largeFileSize: files this big (MB) open in large-file mode
  cfgViewerMB = 512            # editor.viewerSize: files bigger than this (MB) open in the large-file viewer
  cfgLongLine = 10000          # editor.longLineLimit: … and so do files with a line this long (0: never)
  cfgLineNums = 1          # 0 off, 1 absolute, 2 relative
  cfgMouse = true
  cfgThemeName = "nim-crown"
  cfgAutoSave = false
  cfgCheckOnSave = true
  cfgTrimOnSave = true
  cfgTrimAll = false
  cfgEditorConfig = true       # follow .editorconfig files
  cfgShowWs = false
  cfgScrollOff = 3
  cfgAutoComplete = true
  cfgGuides = true
  cfgRulers: seq[int]          # editor.rulers: columns with a vertical line (sorted)
  cfgRulerAtLength = false     # editor.rulers has "lineLength": a ruler where the file's formatter wraps
  cfgFormatOnSaveLangs: seq[string]  # editor.formatOnSaveLanguages (empty: all)
  cfgCsvAlign = true           # csv.alignColumns: CSV and TSV columns lined up (virtual spaces; the file is unchanged)
  csvWidthCache: Table[int, (string, seq[int])]   # buffer → (its version and rows looked at, the column widths)
  cfgSwatches = true           # editor.colorSwatches
  cfgSpell = "markdown"        # editor.spellCheck: off · markdown (Markdown and commit messages) · on (also comments, strings)
  cfgSpellDict = ""            # editor.spellDictionary: a .dic file or a word list ("" = look for one)
  cfgSpellLang = "en_US"       # editor.spellLanguage
  cfgInlineValues = true       # debug.inlineValues
  cfgLinkedEditing = true      # editor.linkedEditing: an HTML tag's partner follows its renaming
  cfgEmmet = true              # editor.emmet: Tab expands ul>li*3 in HTML
  cfgRulerTint = true          # tint what goes past the last ruler
  rulersHidden = false         # View › Rulers turned them off for this session
  cfgAutoHover = true          # show hover info automatically when the cursor rests on a symbol
  cfgHoverDelay = 700
  cfgSticky = true             # sticky scroll: keep enclosing proc/type headers visible
  cfgRainbow = true            # rainbow brackets
  cfgLigatures = "off"         # editor.fontLigatures: off | font (operators in one colour, for a ligature font) | symbols
  cfgLiveCheck = true          # diagnostics while typing (nimsuggest), not only on save
  cfgFormatOnSave = false
  cfgNimIde = "builtin"        # builtin (ned's index + nimsuggest) | nimlangserver | off
  cfgNimSuggest = false        # the built-in engine may start nimsuggest for what only the compiler knows
  cfgNsIdleMin = 15            # stop an idle nimsuggest after this many minutes (0 = never)
  cfgNimFormatter = "builtin"  # builtin (ned's own, nph style) | nph | nimpretty
  cfgNsMaxMB = 1500            # restart a nimsuggest that grows beyond this (0 = no limit)
  nsProtoVer = -1              # nimsuggest's protocol version (-1 = not asked yet)
  cfgCompDocs = true           # documentation beside the completion list
  cfgNimMode = "debug"         # debug | release | danger
  cfgNimTarget = "c"           # c | cpp | js | objc
  cfgCheckWrappers = true      # importc wrappers checked against their C headers
  cfgFolderTrust = "ask"       # security.folderTrust: ask (a folder's code runs once you trust it) | off
  cfgFileEncoding = "auto"     # files.encoding: what a file that is not UTF-8 (and has no BOM) is read as
  cfgEmitClangd = true         # C in {.emit.} goes through clangd when it is installed
  cfgFormatEmitC = true        # formatting a Nim file formats the C in its emits too
  quickFixDryRun = false       # (nedls works out what a quick fix would change by running it: one that writes a file
                               # itself — not through a buffer — does nothing then)
  cfgFmtWidth = 88             # nim.format.lineLength (the setting; FmtWidth is the width in use)
  cfgFmtWidthSet = false       # nim.format.lineLength written in a settings file — else .editorconfig's max_line_length
  cfgFormatVerify = false      # nim.format.verify: the built-in Nim formatter's result checked by Nim's own parser too
  cfgEngineChecks = true       # nim.engineChecks: the engine's own checks while typing (fields, arguments, dead code)
  cfgEngineMoreChecks = true   # nim.engineHints: a var never changed, a parameter never used, a result never set,
                               #   a proc that can be a func
  cfgNimMinVersion = ""        # nim.minVersion: the oldest Nim the code must build with ("" = the .nimble says, off)
  cfgMacroNames = true         # nim.macroNames: a module's top-level macro calls expanded by the compiler, once
  cfgCompilerAnswers = true    # nim.compilerAnswers: nimsuggest off — the compiler asked once where the engine has no answer
  cfgOracle = true             # nim.compilerOracle: the compiler asked in the background what the engine cannot work out
  cfgCSigHints = true          # nim.cSignatureHints: the C declaration dimmed after an importc wrapper
  cfgParamHints = "literals"   # nim.parameterHints: names before call arguments — literals | all | off
  cfgRaisesHints = false       # nim.raisesHints: what a routine can raise, after its header (the engine's inference)
  cfgChainHints = true         # nim.chainHints: the type after each step of a call chain written over several lines
  cfgCEngine = "auto"          # c.engine: auto (ned's own when clangd is not installed) | builtin | clangd | both
  cfgCFormatter = "auto"       # c.formatter: auto (clang-format while clangd is in use) | clang-format | builtin
  cfgCStyleName = "auto"       # c.format.style
  cfgCStyleOpts: seq[(string, string)]   # c.format.options
  cSigHints: Table[int, Table[int, (int, string)]]   # buffer id → line → (column, the C signature shown there)
  copyMarks: Table[int, Table[int, seq[CopyMark]]]    # buffer id → line → where ARC/ORC copies on it
  ghAccount = ""                                      # who the GitHub CLI is signed in as ("" not known)
  cSigHintsAt: Table[int, (int, int, int)]           # buffer id → (changeId, first, last line) they were made for
  cfgPasteFmt = "indent"       # editor.formatOnPaste: indent | format | off
  cfgNimCompiler = "nim"       # nim | nimony
  # nimsuggest pool, tools, side panel
  nimSugs: seq[NimSug]
  exeCache = initTable[string, string]()
  toolVersions = initTable[string, string]()
  sideView = svFiles
  gitStatusLines: seq[string]
  gitStatusAt: MonoTime
  gitStatusStart: MonoTime          # (when the last `git status` started, and how long it took: ms)
  gitStatusTook = 0
  gitStatusBusy = false
  nimble: NimbleInfo
  nimbleAt = ""
  # auto hover bookkeeping
  navHead: Pos
  navBuf = -1
  navChange = -1
  navAt: MonoTime
  lastInlayMs = -1                  # (Help › Performance: the last type-hint window, the engine's last checks)
  lastChecksMs = -1
  lastInputAt: MonoTime             # a key, a click, a wheel turn: when the last one came (background work waits)
  autoHoverFired = true
  hoverIsAuto = false
  breakpoints: Table[string, HashSet[int]]     # debugger: file → lines (0-based), kept with the session
  bpCond: Table[string, string]                # "file:line" → condition (a Nim expression)
  bpLog: Table[string, string]                 # "file:line" → a logpoint's message ("i = {i}"): printed, no stop
  dbgWpWanted: seq[string]                     # "stop when it changes": the expressions (set when debugging starts)
  depActs: seq[Action]                         # the Nimble dependency tree's lines: what Enter does on each
  profLines, profDecls: Table[string, Table[int, (int, int)]]   # the last profile: file → line → (self, total) samples
  profRows: seq[(string, string, int, int, int)]  # its procs: (name, file, declaration line, self, total)
  profSamples = 0
  profShown = false                            # (Nim: hide the profile)
  profMtime: Table[string, int64]              # the files as they were profiled (a changed file's numbers are not shown)
  profChecked: Table[int, int]                 # buffer → the change its staleness was checked at
  profStale: Table[int, bool]
  profStacks: seq[(seq[(string, string)], int)]   # its call stacks (the outermost first: (proc, file)) → samples
  profPrevRows: seq[(string, string, int, int, int)]   # the profile before it (Nim: compare with the previous profile)
  profPrevSamples = 0
  flameViews: HashSet[int]                     # the tabs that show the profile as a flame graph (nim/flame.nim)
  dbgWatches: seq[string]                      # debugger: watch expressions (Nim), kept with the session
  cmdUses = initTable[string, int]()
  compRecent = initTable[string, int]()   # completion: what you chose ("<language>:<label>") → when (compRecentN then)
  compRecentN = 0
  welcomeRegions: seq[(int, int, int, Action)]   # (y, x0, x1, action) for taps
  cfgIcons = "unicode"
  cfgTitleBar = true
  cfgMenuBar = true
  cfgTabBar = true
  cfgBreadcrumbs = true
  cfgStatusBar = true
  cfgTouchBar = "off"          # on-screen keys for touch: off | on | auto (phones)
  cfgTouchKeys: seq[string] = @[]
  cfgAutoImport = true         # Nim completion also offers standard-library names that need an import
  cfgPostfix = true            # Nim completion after a `.` offers postfix templates: xs.for, c.case, v.if …
  cfgShowCopies = true         # mark where ARC/ORC copies (nim c --expandArc on save, a trusted folder)
  cfgFormatScope = "file"      # format on save: the whole file, or only where lines changed (git)
  cfgCommitChecks = "both"     # before a commit: format (the staged files formatted) and tests (theirs pass) · both · off
  cfgDimInactive = true        # dim `when` branches false on this platform, C's #if 0 …
  cfgTestOnSave = "related"    # run std/unittest files on save: related (the file, or the tests importing it) · file · off
  cfgSemColors = true          # Nim: colour names by what the index knows they are
  cfgRichColors = true         # … var/let, globals, deprecated, unsafe (nim.richColors)
  cfgMinimap = "auto"
  cfgScrollbar = true
  cfgLongPress = true          # touch: press and hold opens the context menu
  cfgShadows = true
  cfgTermTitle = true          # ui.terminalTitle: the file and project in the terminal's title
  cfgTransparentBg = false     # ui.transparentBackground: the editor's background left to the terminal
  cfgJumpHl = true             # ui.jumpHighlight: the line a jump lands on lights up
  cfgProgressBar = true        # ui.progressBar: long jobs fill the status bar
  cfgPauseAway = true          # ui.pauseWhenAway: background work for the screen waits while the terminal is away
  cfgSaveOnBlur = false        # editor.saveOnFocusLost
  cfgEditorEnv = true          # terminal.editorEnv: GIT_EDITOR (EDITOR, VISUAL) in ned's terminal is this ned
  cfgItalics = false
  cfgToasts = true
  cfgFormButtons = true       # ui.formButtons: OK / Cancel under lists and prompts
  cfgDragDrop = true          # ui.dragAndDrop
  cfgMessages = "popup"        # info / warnings / errors: "popup" (wrapped, readable) or "statusbar"
  cfgRenamePreview = true
  cfgPersistentUndo = true
  msgLog: seq[(string, int, string)]     # recent messages: time, severity, text
  cfgHoverFx = true
  cfgPointer = true            # ui.pointerShapes: a hand over buttons, an I-beam over text (OSC 22)
  pointerShape = ""            # what the mouse pointer was last set to
  cfgTooltips = true
  cfgCursorStyle = "bar"
  cfgLeftW = 0
  cfgRightW = 0
  cfgPanelH = 0
  cfgLineHl = true
  cfgHighlightOcc = true
  cfgCallArgs = false          # nim.completeCallArguments: a routine completed with its parameters to fill in
  cfgContinueComments = true   # editor.continueComments: Enter in a doc comment (## /// /** *) starts the next line with it
  cfgAutoPairs = true
  cfgSnippets = true
  cfgInlayHints = true
  cfgCodeLens = true
  cfgRefCounts = true
  cfgAiCheckEdits = true
  cfgAiTrimOld = true
  cfgPickerPreview = true             # editor.pickerPreview: the file, symbol or buffer beside the picker's list
  cfgWebEngine = "auto"                # web.engine: ned's own CSS, HTML, SQL — auto (no language server) · on · off
  cfgFolding = true
  cfgVim = false
  cfgKeymap = "default"        # editor.keymap: default · vim · emacs · helix
  cfgVimEscape = ""
  cfgVimClipboard = true
  cfgVimRelative = false
  cfgExclude: seq[string]
  cfgScanLimit = 500_000
  cfgAutoReload = true
  cfgRestoreSession = true
  cfgUseRg = true
  cfgSearchMax = 5000
  cfgTermShell = ""
  cfgTermIntegration = true
  cfgTermKeep = true                  # terminal.keepRunning
  cfgTermScrollback = 3000
  cfgTermCwd = "project"
  cfgGitGutter = true
  cfgGitAutoRefresh = true
  cfgGitUntrackedAll = false          # git.untrackedFiles: every new file on its own line (git status -uall)
  cfgNimFlags = ""
  cfgNimTestFlags = "--hints:off"
  cfgCovTestFiles = false              # nim.coverageTestFiles: Nim test coverage counts the test files too
  cfgAiProvider = "anthropic"
  cfgAiModel = ""
  cfgAiKey = ""
  cfgAiKeyEnv = ""
  cfgAiBase = ""
  cfgAiMaxTokens = 8192
  cfgAiTemp = -1
  aiQuirks: HashSet[string]   # "<model>|<quirk>" learned from API refusals (kept in state.json):
                              # mct (max_completion_tokens), maxtokens, notemp, nostreamopts, nostream,
                              # responses (only /v1/responses), notools, developer, nosysrole
  cfgAiAgent = true
  cfgAiApprove = "reads"
  cfgAiMaxSteps = 30
  cfgAiIncludeFile = true
  cfgAiFastModel = ""
  aiFastOn = false
  cfgAiWarnTokens = 60000
  cfgAiNimContext = true
  cfgAiSystem = ""
  cfgKeys = initTable[string, string]()
  savedLayout: JsonNode
  savedSessions: JsonNode
  aiPromptHist: seq[string]
  cfgUserLsp = initTable[string, seq[string]]()
  cfgUserFmt = initTable[string, string]()
  cfgUserRun = initTable[string, string]()
  theme: Theme
  trueColor = true
  # terminal
  gOrigTerm: Termios
  gRaw = false
  gResized = true
  scrW = 80
  scrH = 24
  grid: seq[Cell]
  prevGrid: seq[Cell]      # what the terminal currently shows (cell-level diffing)
  cursorX = -1
  cursorY = -1
  inBuf = ""
  eraseIsCtrlH = false
  # ui
  msg = ""
  msgSev = 0
  msgTime: MonoTime
  needRender = true
  treeOpen = false
  treeRoot: TreeNode
  treeBuiltFor = ""              # what treeRoot was built for (the folder, or every folder of a workspace)
  wsRoots: seq[string]           # a multi-root workspace: its folders after the first (the first is rootDir)
  wsFile = ""                    # the .ned-workspace (or .code-workspace) file it came from
  treeRows: seq[TreeNode]
  treeSel = 0
  treeScroll = 0
  showHidden = false
  panelOpen = false
  panelKind = pkOutput
  panelStore: array[PanelKind, seq[PanelLine]]
  panelSelA: array[PanelKind, int]
  panelScrollA: array[PanelKind, int]
  panelTitles: array[PanelKind, string]
  rightOpen = false
  rightView = svAssistant
  panelFollow = true
  promptKind = pNone
  promptLabel = ""
  promptText = ""
  promptCur = 0
  promptHist = initTable[PromptKind, seq[string]]()
  promptHistIdx = -1
  findQuery = ""
  findCase = false
  findWord = false
  findOrigin: seq[Cursor]
  replaceQuery = ""
  replaceWith = ""
  replaceActive = false
  replaceCount = 0
  pickKind = pickNone
  pickTitle = ""
  pickNear = false                    # drawn beside the cursor's line (quick fixes), not at the top
  macroRecording = false              # keyboard macro: keys being recorded
  macroPlaying = 0                    # depth of macros being played (a macro may play another, not forever)
  edCaretX = -1                       # the editor caret on screen this frame (-1: not drawn)
  edCaretY = -1
  pickQuery = ""
  pickCur = 0
  pickItems: seq[PickItem]
  pickShown: seq[int]
  pickSel = 0
  pickScroll = 0
  pickPrevTheme = ""
  compOpen = false
  compItems: seq[CompItem]
  compShown: seq[int]
  compSel = 0
  compScroll = 0
  compLine = -1
  compStartCol = 0
  compFromLsp = false
  compManual = false
  hoverLines: seq[string]
  hoverScroll = 0
  hoverOpen = false
  helpOpen = false
  helpScroll = 0
  jumpStack: seq[(string, Pos)]
  fwdStack: seq[(string, Pos)]          # go forward (after jumping back)
  closedTabs: seq[(string, Pos)]        # reopen closed tab
  boxAnchor = Pos(line: -1)             # Alt+drag: a box (column) selection from here
  keyCaptureFor = ""                    # the shortcuts editor: the next key is bound to this command
  userCmdEditing = ""                   # the "commands" editor: the command being made or changed
  gitPromptCb: proc(t: string)          # git prompts (branch names, tag names, stash messages…)
  gitAhead, gitBehind = 0               # commits to push / to pull (from git status)
  gitHasUpstream = false
  blameBufs: Table[int, seq[string]]    # blame tab → the commit of each line
  graphBufs: HashSet[int]               # branch-graph tabs: coloured lanes, Enter opens a commit
  ciStatus = ""                         # GitHub Actions on this branch: "✓", "✗", "⟳" or ""
  ciBranch = ""
  ciDueAt: MonoTime                     # when to look again (a run is still going), zero = not planned
  ciDue = false
  clipParts: seq[string]
  fileCache: seq[string]
  fileCacheValid = false
  diagsLsp = initTable[string, seq[Diag]]()
  diagsBuild = initTable[string, seq[Diag]]()
  diagsTest = initTable[string, seq[Diag]]()    # failed checks of tests run on save
  diagsFfi = initTable[string, seq[Diag]]()     # importc wrappers that do not fit their C header
  diagsEmit = initTable[string, seq[Diag]]()    # clangd's problems in the C a Nim file emits
  diagsWeb = initTable[string, seq[Diag]]()     # ned's own CSS, HTML and SQL checks (web.engine)
  diagsExt = initTable[string, seq[Diag]]()     # what a script sent (ned --remote-problems): kept until it sends again
  shadowNim = initTable[string, string]()       # the hidden C document of a Nim file's emits → the Nim file
  diagsByShadow = initTable[string, seq[Diag]]()  # a hidden document → its problems, on the Nim file's lines
  shadowLangName = initTable[string, string]()  # a hidden document → its language's name (the messages' prefix)
  jobs: seq[Job]
  servers: seq[LspServer]
  recentFiles: seq[string]
  savedPos = initTable[string, Pos]()
  lastClickTime: MonoTime
  lastClickX, lastClickY, clickCount: int
  mouseDragging = false
  commands: seq[Command]
  lastRunCmd = ""
  gitBranch = ""
  activeRunConfig = ""                   # the project's chosen run configuration ("": the current file)
  taskRecent: seq[string]                # tasks you ran in this project, newest first (their keys)
  lastTask = ""                          # F4 runs it again: command ␟ folder ␟ label
  runArgsByFile = initTable[string, string]()
  langs: seq[Lang]
  editorRect: tuple[x, y, w, h: int]
  tabRanges: seq[(int, int, int)]       # (x0, x1, buffer index)
  # mouse and touch: what a drag moves, and the press a long-press (touch: the context menu) is timed from
  dragTarget = dtNone
  splitRatio = 0.5                        # share of the first pane in a split
  splitDiv: tuple[x, y, len: int, vertical: bool] = (-1, -1, 0, true)
  sbCol = -1                              # the active editor's scrollbar column (-1: none)
  sbTop, sbH: int
  mmRect: tuple[x, y, w, h: int] = (-1, 0, 0, 0)   # the minimap (x = -1: none)
  mmFirst: int                                     # first line it shows
  pressAt: MonoTime
  pressX, pressY: int
  pressMoved, pressLeft: bool
  closeRanges: seq[(int, int, int)]
  textW = 60
  textH = 20
  gutterW = 6
  undoSeq = 0
  lspFailed: HashSet[string]
  lspMoreFailed: HashSet[string]     # second servers (lsp.alsoRun) that could not start or died: their command
  lspUidNext = 1
  cfgLspAlso: Table[string, seq[seq[string]]]   # lsp.alsoRun: language id ("*": every one) → more servers
  cfgLspLinters = true               # lsp.linters: known linters' servers too, when installed
  cfgFormatOnType = false            # editor.formatOnType: the server's on-type formatting
  lspHinted: HashSet[string]          # languages already told how to install a language server
  cfgLspHints = true                  # editor.languageServerHints
  lspDeaths = initTable[string, int]()
  lastFileCheck: MonoTime
  checkPending: HashSet[string]
  pendingRecheck: HashSet[string]
  clipLineMode = false
  sysClipBroken = false
  panelTopY = -1
  treeWCur = 0
  compRect: tuple[x, y, w, h: int]
  pickBox: tuple[x, y, w, h: int]
  pickListY = 0
  pickListN = 0
  settingKey = ""            # the setting a value prompt is for
  dndPrevBufId = -1         # (drag and drop) the file shown before the press — a tab's press shows the tab's
  pickRegions = -1          # the picker's own regions (its query field, its buttons) start here
  hoverPrefix = ""
  sigOpen = false
  sigLabel = ""
  sigHl = (0, 0)
  sigLine = -1
  sigDoc = ""                   # Markdown documentation of the signature shown
  sigMore = ""                  # "1/3" when there are overloads
  compDocScroll = 0
  compDocIdx = -1               # the item the panel shows the documentation of
  compDocRect: tuple[x, y, w, h: int]
  compDocLines = 0
  hoverMd = ""                  # hover text (Markdown)
  landBuf = -1                  # the line a jump landed on (ui.jumpHighlight): lit up, fading over JumpHlMs
  landLine: int
  landAt: MonoTime
  flashBuf = -1                 # lines just inserted (AI chat): briefly tinted so you see where they went
  flashA, flashB: int
  flashAt: MonoTime
  findTotal = 0
  findIdx = 0
  findCapped = false

type SearchHit = object
  path, text: string
  line, col: int

var
  searchHits: seq[SearchHit]
  dockQuery = ""
  dockQueryCur = 0
  dockQueryRan = ""
  searchCollapsed: HashSet[string]
  # project-wide replace, filters and the options the current results were found with
  dockReplace = ""
  dockReplaceCur = 0
  dockInclude = ""
  dockIncludeCur = 0
  dockField = 0                 # which search-view input has the keyboard: 0 query, 1 replace, 2 files
  dockShowReplace = false
  dockShowInclude = false
  searchRx = false
  searchWord = false
  searchIncludeRan = ""
  searchDismissed: HashSet[string]       # "path" (whole file) or "path:line"
  lastReplaceUndo: seq[(string, string)] # disk files changed by the last replace-all: (path, old content)
  lastReplaceBufs: seq[(int, int)]       # open buffers it changed: (buffer id, undo seq id)

type DockList = object
  items: seq[SideItem]
  sel, scroll: int

# ── boxes you move: a dialog, a form or a picker dragged by its title bar stays where you put it (this session) ──

var
  boxMoves: Table[string, (int, int)]       # a box's offset from where it opens, by its kind
  moveBar: tuple[x, y, w, x0, y0: int, key: string] = (-1, -1, 0, 0, 0, "")   # the top box's title bar now
  moveGrab: tuple[dx, dy, x0, y0: int, key: string]                            # where it was taken

proc boxPlace(key: string, x0, y0, w, h: int): (int, int) =
  ## where a box opening at (x0, y0) is drawn — moved by its offset, kept on the screen — and its title bar the
  ## one a press may take (the last box drawn is the one on top)
  let off = boxMoves.getOrDefault(key, (0, 0))
  let x = clamp(x0 + off[0], 0, max(0, scrW - w))
  let y = clamp(y0 + off[1], 0, max(0, scrH - h - 1))
  moveBar = (x, y, w, x0, y0, key)
  (x, y)

var
  leftList, rightList: DockList
  leftTabRanges, rightTabRanges: seq[(int, int, SideView)]

var vimSearchBack = false
var
  zenMode = false
  zenSaved: (bool, bool, bool)
  zenEscAt: MonoTime
  cfgZenWidth = 90
  cfgZenHideNums = true
  cfgZenDim = true
  cfgZenTypewriter = false
  cfgZenGit = false            # zen.gitChanges: git's change marks in the gutter in zen mode
  cfgZenInfo = true
var vimMode = vmNormal

type HxMode = enum hxNormal, hxInsert, hxSelect
var
  hxMode = hxNormal                  # helix keymap: normal (select, then act) · insert · select (extend)
  hxPending = ""                     # g, space, r, m … waiting for the next key
  hxCount = ""
  emacsPrefix = ""                   # emacs keymap: C-x or M-g waiting for the next key
  emacsMark = false                  # C-SPC: moving extends the selection
  emacsKillAt: MonoTime              # C-k right after C-k adds to the same kill
var
  gitFileStatus = initTable[string, char]()
  gitDirty: HashSet[string]
  gitNewDirs: HashSet[string]       # folders git does not know at all (their files are new too)
var inlayShown: HashSet[int]
var
  savedMarks = initTable[string, seq[int]]()   # bookmarks per file (state.json)
  termSignal = 0                               # SIGHUP/SIGTERM arrived: keep recovery files and exit
  cfgBlame = false
  blameFor = ""
  blameText = ""
  blameReqAt: MonoTime
  cfgUserSnippets: seq[(string, string, string, string)]   # (language id or "*", prefix, description, body)
  cfgGhostOn = false
  lastSwapCheck: MonoTime
  autoSaveWarned: HashSet[string]

# ── split editor: two panes; the active one is `curBuf`, the other keeps a snapshot of its view ──
type
  ViewSnap = object
    topLine, topSub, leftCol, prim, lastChange: int
    cursors: seq[Cursor]
    lastHead: Pos
  Pane = object
    bufId: int
    snap: ViewSnap
    rect: tuple[x, y, w, h: int]
    gutterW, textW, textH: int
var
  splitOn = false
  splitDown = false      # stacked (one above the other) instead of side by side
  activePane = 0
  panes: array[2, Pane]

template panelLines: untyped = panelStore[panelKind]
template panelSel: untyped = panelSelA[panelKind]
template panelScroll: untyped = panelScrollA[panelKind]
template panelTitle: untyped = panelTitles[panelKind]

var lineTints: Table[int, Table[int, (Rgb, float)]]   # buffer id → its lines tinted: (colour, how much) — Compiler
                                                      # Explorer's source lines and the instructions they made
