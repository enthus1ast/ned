# ════════════════════════════════════════════════════════════════════════════
#  Global state
# ════════════════════════════════════════════════════════════════════════════

const NoColor: Rgb = 0xFF000000'u32

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
  cfgEmitClangd = true         # C in {.emit.} goes through clangd when it is installed
  cfgNimCompiler = "nim"       # nim | nimony
  # nimsuggest pool, tools, side panel
  nimSugs: seq[NimSug]
  exeCache = initTable[string, string]()
  toolVersions = initTable[string, string]()
  sideView = svFiles
  gitStatusLines: seq[string]
  gitStatusAt: MonoTime
  gitStatusBusy = false
  nimble: NimbleInfo
  nimbleAt = ""
  # auto hover bookkeeping
  navHead: Pos
  navBuf = -1
  navChange = -1
  navAt: MonoTime
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
  dbgWatches: seq[string]                      # debugger: watch expressions (Nim), kept with the session
  cmdUses = initTable[string, int]()
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
  cfgSemColors = true          # Nim: colour names by what the index knows they are
  cfgMinimap = "auto"
  cfgScrollbar = true
  cfgLongPress = true          # touch: press and hold opens the context menu
  cfgShadows = true
  cfgItalics = false
  cfgToasts = true
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
  cfgAutoPairs = true
  cfgSnippets = true
  cfgInlayHints = true
  cfgCodeLens = true
  cfgRefCounts = true
  cfgAiCheckEdits = true
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
  cfgTermScrollback = 3000
  cfgTermCwd = "project"
  cfgGitGutter = true
  cfgGitAutoRefresh = true
  cfgNimFlags = ""
  cfgNimTestFlags = "--hints:off"
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
  diagsFfi = initTable[string, seq[Diag]]()     # importc wrappers that do not fit their C header
  diagsEmit = initTable[string, seq[Diag]]()    # clangd's problems in the C a Nim file emits
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
