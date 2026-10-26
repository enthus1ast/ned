# ════════════════════════════════════════════════════════════════════════════
#  Types
# ════════════════════════════════════════════════════════════════════════════

type
  Rgb = uint32

  TokKind = enum
    tkText, tkKeyword, tkType, tkConst, tkString, tkChar, tkEscape, tkNumber,
    tkComment, tkDoc, tkPragma, tkOperator, tkFunc, tkPunct, tkPreproc,
    tkProperty, tkVariable, tkTag, tkAttr, tkHeading, tkLink, tkBold, tkCode,
    tkAdded, tkRemoved,
    tkParam,                    # a routine's parameter, where it is used (semantic colours)
    tkMutable,                  # Nim: a `var` (it can change) — a `let` stays plain
    tkGlobal, tkGlobalVar,      # Nim: the module's own let / var, used anywhere (in bold)
    tkDeprecated,               # Nim: a {.deprecated.} name (faded, struck through)
    tkUnsafe                    # Nim: cast, addr, unsafeAddr, ptr — where memory safety is up to you

  LexMode = enum
    lmPlain, lmGeneric, lmNim, lmC, lmJs, lmRust, lmShell, lmPython, lmMarkdown,
    lmJson, lmYaml, lmToml, lmHtml, lmCss, lmMake, lmDiff,
    lmNimf,                     # Nim source-code-filter templates (#? stdtmpl): # lines are Nim, the rest HTML
    lmJinja,                    # Jinja-style templates (Nimja's .nimja, .jinja, .j2): HTML with {{ }}, {% %}, {# #}
    lmRegex,                    # (inside strings) regular expressions and PEGs
    lmNimFmt,                   # (inside strings) strformat: {expressions} are Nim
    lmCsv,                      # CSV, TSV: each column in its own colour
    lmNif                       # NIF (Nim 3's code between its passes): tags, definitions, symbols, line information

  LexSt = uint32                # a line's starting lexer state: byte 0 the innermost lexer's own state,
                                # bytes 1-3 the languages embedded in one another (0: none)

  Lang = ref object
    name, id: string
    exts, files: seq[string]
    mode: LexMode
    lineComment, docLine: string
    blockStart, blockEnd, docBlockStart, docBlockEnd: string
    nested: bool
    quotes: set[char]
    triple, charLit, capsTypes, decorators, commentNeedsSpace: bool
    multiline: bool               # (the generic lexer) a "…" or `…` string not closed on its line goes on below
    nameChars: set[char]          # characters a name may have after its first letter besides letters, digits, _
    dedentWords: seq[string]      # a line that becomes one of these words alone (`end`) goes one level out
    keywords, types, consts, builtins, defWords, classWords: HashSet[string]
    indentChars: set[char]
    indentWords: seq[string]
    dedentChars: set[char]
    useTabs: bool
    indentWidth: int
    run, build, check: string
    lsp: seq[seq[string]]
    fmt: seq[string]
    pairs: string
    csvSep: char                  # CSV-like files: the separator ('\0': , or ; as each line has more of)

  Theme = object
    name: string
    dark: bool
    bg, fg, dim, gutter, gutterCur, curLine, sel, match, matchCur, wordHl, bracket: Rgb
    statusBg, statusFg, tabBg, tabFg, tabActiveBg, tabActiveFg: Rgb
    popupBg, popupSel, border, accent, panelBg, guide, cursorSec: Rgb
    ruler: Rgb                    # editor.rulers: the vertical lines at fixed columns
    popupFg, popupSelFg: Rgb      # completion/picker rows (themes with a solid-colour selection bar)
    err, warn, info, hint, gitAdd, gitMod, gitDel: Rgb
    stickyBg, inlay: Rgb
    # desktop chrome
    titleBg, titleFg, dockBg, dockHeadBg, tabBarBg, hoverBg, inputBg, inputBorder: Rgb
    btnBg, btnFg, menuBg, menuSel, toastBg, badgeBg, badgeFg, scrollThumb, focusBorder: Rgb
    codeBg, userBg, minimap, shadow: Rgb
    crumbBg, splitBar: Rgb      # breadcrumb bar (and the active tab above it) · the bar between split panes
    boldKw: bool                # keywords in bold (themes without hues tell them apart by weight)
    ansi: array[16, Rgb]
    rainbow: array[3, Rgb]
    syn: array[TokKind, Rgb]
    base: array[16, Rgb]        # mkTheme's colours, kept so a theme can be rebuilt with some of them changed
    chromeCols: array[3, Rgb]   # title bar, docks, status bar — when the theme sets them
    hasChrome: bool

  Attr = enum
    aBold, aDim, aItalic, aUnder, aRev, aStrike,
    aCurl,                     # (with aUnder) a curly underline, where the terminal draws one (ui.undercurl)
    aUcErr, aUcWarn, aUcInfo   # (with aUnder) the underline in the error, warning or info colour (the text keeps its own)
  DragTarget = enum dtNone, dtSplit, dtLeftDock, dtRightDock, dtPanel, dtScroll, dtMinimap, dtTab,
    dtField,        # a press in a one-line field: the drag selects in it
    dtTabOut,       # a tab dragged off the tab bar: dropped on a pane (moved there) or an edge (split)
    dtFile,         # a file dragged from the file tree: dropped on the editor (opened) or a folder (moved)
    dtText,         # the selection dragged in the editor: dropped elsewhere (moved; with Ctrl: copied)
    dtFormScroll,   # a form's scroll bar
    dtMove          # a dialog, form or picker taken by its title bar
  Cell = object
    ch: uint32
    fg, bg: Rgb
    at: set[Attr]

  KeyKind = enum
    kNone, kChar, kEnter, kTab, kBackspace, kDelete, kEsc, kUp, kDown, kLeft, kRight,
    kHome, kEnd, kPgUp, kPgDn, kInsert, kFn, kMouse, kPaste
  Mod = enum mCtrl, mAlt, mShift
  Key = object
    kind: KeyKind
    ch: int
    mods: set[Mod]
    fn: int
    mb, mx, my: int
    press, drag: bool
    text: string

  Pos = object
    line, col: int
  Cursor = object
    anchor, head: Pos
    goalX: int
  EditOp = object
    a: Pos
    oldText, newText: string
  UndoGroup = object
    ops: seq[EditOp]
    before, after: seq[Cursor]
    kind: int
    time: MonoTime
    seqId: int
  WkEdit = object
    ## a change to a buffer's text, kept for the engine worker (nim/worker.nim): lines a..c replaced with text
    a, c: Pos
    text: string
  UndoBranch = object
    ## steps undone and then edited over: kept (the undo tree), off the line of edits after its first `at` steps
    at: int
    groups: seq[UndoGroup]
  Diag = object
    line, col, eline, ecol: int
    sev: int            # 1 error, 2 warning, 3 info, 4 hint
    msg, src: string
    code: JsonNode      # the server's code for it (sent back when asking for its fixes)
    raw: string         # the server's own words, when msg was tidied (sent back when asking for its fixes)
    fixes: JsonNode     # the fixes the server sent with it (clangd: codeActionsInline), nil when none
    srv: int            # the language server that reported it (its uid; 0: not a language server)
    rule: string        # ned's own checks: the rule that found it ("var-let", "unused-import" …; .ned/lint.json)

  VRow = object                        # a row drawn under a line of a file, not part of its text (a cell's output)
    spans: seq[(string, Rgb, set[Attr])]
    bg: Rgb
  Buffer = ref object
    id: int
    lines: seq[string]
    path: string
    cursors: seq[Cursor]
    prim: int
    undoStack, redoStack: seq[UndoGroup]
    undoBranches: seq[UndoBranch]      # the undo tree's other branches (editor/undotree.nim)
    wkLog: seq[WkEdit]                 # the engine worker: the edits since it last had the text (nim/worker.nim)
    wkLogFrom: int                     #   … the change they start from (-1: none kept — the whole text next time)
    nesHas: bool                       # next-edit suggestions: the line being edited, as it was before
    nesLine: int
    nesBefore: string
    group: UndoGroup
    inGroup: bool
    changeId, savedId: int
    lang: Lang
    hlStart: seq[LexSt]
    hlValid: int
    topLine, topSub, leftCol: int
    crlf: bool
    enc: string                        # the file's encoding ("" UTF-8; core/encodings): read as it, written back as it
    indent: string
    mtime, fsize: int64
    lspVersion: int
    lspDirty, lspOpen: bool
    lspMore: bool                 # a second language server (a linter: lsp.alsoRun) has it open too
    lspChangeAt: MonoTime
    git: seq[uint8]     # per line: 0 none, 1 added, 2 modified, 3 deleted-below
    readOnly: bool
    libLocked: bool     # read-only because it belongs to the Nim toolchain or an installed package (files.protectLibraries)
    mdSrc: int          # a Markdown preview: the id of the buffer it shows
    mdNimDocs: bool     # … a Nim file's docs (as nim doc shows them), not the file's text
    noEol: bool
    blankNl: bool                          # the file was one empty line ("\n"): it stays that, not 0 bytes
    mixedEol: bool                         # CRLF and LF line ends both: saving makes them one kind
    tabSize: int                           # .editorconfig tab_width (0: editor.tabSize)
    ecMaxLine: int                         # .editorconfig max_line_length: the ruler's column for this file
    lspFolds: Table[int, int]              # the language server's folding ranges: first line → last line
    lspFoldsAt: int                        # the change they belong to
    ecTrim, ecFinalNl: int8                # .editorconfig trim_trailing_whitespace / insert_final_newline (-1 unset)
    ecInfo: seq[(string, string, string)]  # (property, value, the .editorconfig it came from) applied to this file
    savedSeq: int
    lastHead: Pos
    lastChange: int
    wordsAt: int
    words: seq[string]
    diskChanged: bool
    wordMode: bool
    inGit: bool
    newGroup: bool
    title: string             # virtual (read-only) buffers: macro expansions, diffs, generated C …
    stops: seq[Cursor]        # snippet tab stops (kept valid across edits, like cursors)
    stopIds: seq[int]
    stopIdx: int
    hlDepth: seq[int16]       # bracket depth at line start (rainbow brackets)
    outline: seq[SideItem]
    outlineAt: int
    outlineReqAt: int
    nsDirtyAt: int
    nsDirtyPath: string
    chkAt: int
    welcome: bool
    folds: seq[(int, int)]                 # folded blocks: (header line, last hidden line)
    inlays: Table[int, seq[(int, string)]] # line → (col, label) inlay hints
    vrows: Table[int, seq[VRow]]       # line → rows drawn under it (a notebook cell's output: editor/notebook.nim)
    inlayAt, inlayLo, inlayHi: int
    inlayReqTime: MonoTime
    marks: seq[int]                        # bookmarked lines (Ctrl+F2 / F2)
    binary: bool                           # a binary file: in the hex editor (hex)
    hex: HexState                          # the hex editor's state (nil: a text file)
    swapAt: int                            # changeId last written to the recovery file
    gitBase: seq[string]                   # the file as git has it (index) — live change marks
    gitHasBase: bool
    gitAt: int                             # changeId the marks were computed for
    swapMine: bool                         # this session wrote the recovery file
    swapWrittenAt: MonoTime
    large: bool                            # large-file mode: very big, or a line too long for code features
    largeOff: bool                         # … turned off for this file (palette › Large file mode)
    largeWhy: string
    viewer: LfView                         # a file too big to edit: a window of its lines (editor/lfview)

  LfView = ref object                      # the large-file viewer: a window of a huge file's lines, read-only
    path: string
    size: int64
    f: File
    marks: seq[int64]                      # where lines 0, LfStep, 2·LfStep … start (the index, made in the background)
    lineCount: int                         # lines indexed so far (all of them once done)
    indexed: int64                         # bytes indexed so far
    done: bool
    lastNl: bool                           # (the last byte indexed was a line end)
    base: int                              # the window's first line in the file
    findQ, lastFind: string
    findAt, findFrom: int64                # the search: the next byte to look at, where it started
    findBusy, findWrapped, findFold: bool
    cut: int                               # lines in the window shown cut (too long)

  HexEdit = object                         # one change in the hex editor: at `at`, `old` replaced by `new`
    at: int
    old, new: string
  HexState = ref object                    # a binary file in the hex editor
    data: string                           # its bytes, as edited
    cur, anchor: int                       # the cursor's byte; the selection's other end (-1: none)
    top: int                               # the first row shown
    ascii: bool                            # the cursor is in the text column (else in the hex one)
    nibble: int                            # 1: the high half of the byte was typed, the low one comes next
    insert: bool                           # typing inserts bytes (else it types over them)
    undo, redo: seq[HexEdit]
    savedAt: int                           # undo.len when last saved (-1: never the same again)
    changed: seq[(int, int)]               # (from, to) byte ranges changed since loading — shown in colour
    perRow: int                            # bytes per row as last drawn
    rows: int                              # rows shown as last drawn
    find: string                           # what was last looked for (as bytes)
    infoMade: bool                         # the executable's sections and symbols were read
    info: BinInfo

  Focus = enum fEditor, fTree, fPanel, fRight
  VimMode = enum vmNormal, vmInsert, vmVisual, vmVLine, vmReplace
  DockSide = enum dsLeft, dsRight
  PromptKind = enum
    pNone, pFind, pReplaceFind, pReplaceWith, pGoto, pSaveAs, pRunCmd, pSearch,
    pNewFile, pNewFolder, pRenamePath, pLspRename, pNewProject, pAtlasUse, pAtlasSearch, pGitCommit,
    pNimbleTask, pVimCmd, pVimSearch, pOpenFolder, pAiEdit, pSetting, pNimbleAdd, pNimbleSearch,
    pBpCond, pBpLog, pDbgWp, pDbgWatch, pUserCmdName, pUserCmdRun, pPipeCmd, pGitInput, pPathInput,
    pPluginAsk, pPluginNew, pPluginInstall
  PickKind = enum pickNone, pickCmd, pickFile, pickSymbol, pickBuffer, pickTheme, pickRecent, pickLang, pickAction
  PanelKind = enum pkOutput, pkSearch, pkProblems, pkTerminal, pkDebug

  PanelLine = object
    text, path: string
    line, col, sev: int  # sev: 0 normal 1 error 2 warn 3 info 4 ok 5 header
    marks: seq[(int, int)]   # (byte start, length) in text drawn highlighted: the uses on the line

  CompItem = object
    label, insert, detail, filter, sortText, snippet: string
    kind, score: int
    hl: seq[int]
    rank: int                 # how close the item is: 0 local · 1 this module · 2 imports · 3 system …
    nx: int                   # 1-based index into compNx (ned's Nim index), 0 = none
    doc: string               # documentation shown beside the list (Markdown)
    docMade, resolveAsked: bool
    data: JsonNode            # the language server's item, for completionItem/resolve
    addImport: string         # accepting it also adds this import (a standard-library name not imported yet)
    postfix: int              # a postfix template (xs.for): 1 + the column its receiver starts at, 0 = not one
    plug: bool                # a plugin's (its completions join the list when they come)

  CopyMark = object             # where ARC/ORC copies (nim c --expandArc, on save)
    col, startCol: int          # just after the copied expression; where it starts
    text: string                # the line as it was then (the mark shows while the line is unchanged)
    what: string                # why it is copied, and how not to
  PickItem = object
    label, detail, path, icon: string
    search: string        # more text the query may match (lower case): a setting's description
    line, col, idx, score: int
    hl: seq[int]

  TreeNode = ref object
    name, path: string
    isDir, expanded, loaded: bool
    depth: int
    children: seq[TreeNode]

  Proc = object
    pid: Pid
    inFd, outFd, errFd: cint
    exited: bool
    code: int

  JobKind = enum jkRun, jkCheck, jkGit, jkAux, jkSearch, jkTool, jkAi
  Job = ref object
    kind: JobKind
    pr: Proc
    outFd, errFd: cint
    eof: bool
    output: string
    partial: string
    done: bool
    code: int
    started: MonoTime
    path, cmd, cwd: string
    bufId: int
    onDone: proc(j: Job) {.closure.}
    deadlineMs: int           # > 0: stopped after this long (tests run on save)
    resolve: seq[string]      # nimble's "Dependency resolution failed" explanation, a line at a time
    inResolve: bool
    atlasMsgs: seq[(int, string, string)]   # (an atlas job) its [Error]/[Warn] lines: severity, package, message

  LspReqKind = enum lrInit, lrCompletion, lrHover, lrDefinition, lrRename, lrFormat, lrSymbols, lrShutdown,
                    lrSignature, lrReferences, lrExpand, lrInlay, lrCodeAction, lrResolve, lrOther,
                    lrWsSymbols, lrSemTokens, lrCallPrep, lrCallIn, lrCallOut,
                    lrTypeDef, lrImpl, lrHighlight, lrFolding, lrTypePrep, lrTypeSuper, lrTypeSub,
                    lrPullDiag, lrLinks, lrOnType
  LspReq = object
    kind: LspReqKind
    bufId, version: int
    pos: Pos
    extra, extra2: string
  LspServer = ref object
    langId, name: string
    cmd: seq[string]
    pr: Proc
    inFd, outFd, errFd: cint
    rbuf, wbuf: string
    nextId: int
    pending: Table[int, LspReq]
    ready, dead: bool
    utf8: bool
    triggers: set[char]
    sigTriggers: set[char]
    caps: JsonNode
    status: string
    errTail: seq[string]      # the server's last stderr lines (shown when it dies, and in its status)
    errPart: string
    stopped: bool             # shut down on purpose (restart, folder change): not a crash
    startedAt: MonoTime
    uid: int                  # (its problems carry it: Diag.srv)
    secondary: bool           # a second server for the language (a linter): problems and fixes only
    docVer: Table[int, int]   # a second server: buffer id → the version it has
    pullIds: Table[string, string]   # pull diagnostics: file → the result id of its last answer
    remoteMap: seq[string]    # a remote folder's server, run there: the local copy, the folder there (as paths
                              # and as URIs), where its other files are fetched to (path, URI) — see lspMapJson

  Action = proc() {.closure.}
  Command = object
    name, keys: string
    action: proc() {.closure.}

  NsKind = enum nsSug, nsDef, nsHover, nsCon, nsUse, nsChk, nsOutline, nsExpand, nsRename, nsAutoHover, nsInlay
  NsReq = object
    kind: NsKind
    bufId: int
    pos: Pos
    path, extra, cmd: string
  NimSug = ref object
    project, cwd: string
    pr: Proc
    rbuf: string
    lines: seq[string]
    inflight: seq[NsReq]
    waiting: seq[NsReq]
    started: MonoTime
    dead, warmed: bool
    memAt: MonoTime           # when its memory use was last looked at
    usedAt: MonoTime          # the last request (an idle nimsuggest is stopped, and started again on demand)

  SideView = enum svFiles, svSearch, svGit, svProject, svTests, svAssistant, svOutline, svTimeline, svTodos, svPlugins
  SideItem = object
    text, detail, path, icon, data: string
    line, col, depth, role: int     # role: 0 text, 1 accent, 2 dim, 3 error, 4 warn, 5 ok, 6 header, 7 func, 8 type
    action: proc() {.closure.}

  NimbleInfo = object
    file, dir, name, version, author, desc, license, srcDir: string
    bins, requires: seq[string]
    tasks: seq[(string, string)]
