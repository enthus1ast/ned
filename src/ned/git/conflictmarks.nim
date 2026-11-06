# finding the merge conflicts of a buffer (the <<<<<<< ======= >>>>>>> blocks), and the forward declarations and shared
# debugger state that code included earlier in ned.nim needs before their definitions come.
type Conflict = tuple[start, base, mid, stop: int]    # <<<<<<< · ||||||| (or -1) · ======= · >>>>>>>

var conflictCache: Table[int, (int, seq[Conflict])]

proc toggleBreakpoint()
proc openDiffView(title: string, left: seq[string], leftTitle: string, src: Buffer, right: seq[string],
                  rightTitle: string, lang: Lang)
proc cmdBranches()
proc gitSync()
proc gitNet(args, okMsg: string, then: proc() = nil)
proc gitCommitBox(amend: bool)
proc gitOpenChangeDiff(rel: string, staged: bool)
proc gitLogView()
proc gitStashMenu()
proc gitState(): string
proc gitContinue()
proc gitAbort()
proc gitIgnore(path: string)
proc commitMenu(hash, subject: string)
proc gitStaged(): int
proc gitBisectStep(what: string)
proc gitBisectStart()
proc gitWorktrees()
proc gitSubmodules()
proc userCmdExists(name: string): bool
proc setUserCmdField(name, field, value: string)
proc userCmdOutputMenu(name: string)
proc dbgPanelAction(key: string)
proc hunkActions()
proc setBpCond(cond: string)
proc setBpLog(msg: string)
proc profFor(b: Buffer): (Table[int, (int, int)], Table[int, (int, int)])
proc dbgAddWatchpoint(expr: string)
proc dbgRemoveWatchpoint(expr: string)
proc cmdWatchpoint()
proc dbgValueOf(name: string): string
proc dbgSend(cmd: string)
proc dbgStart()
proc dbgEnd(msg: string)
proc dbgCmd(cmd: string)
proc dbgPanel()
proc dapFromMi(cmd: string)
proc dapStop()
proc nimVarName(n: string): string
proc dapStart(b: Buffer)
proc dapSetBreakpoints(path: string)
proc dapReadFd(fd: cint): bool

# the debugger (gdb's machine interface): its state is drawn in the editor (breakpoints, the stopped line)
var
  dbgOn = false
  dbgAt: (string, int) = ("", -1)              # where the program is stopped (file, 0-based line)

var
  dbgProc: Proc
  dbgRbuf: string
  dbgState = ""
  dbgFrames: seq[(string, string, int)]          # function, file, line (0-based)
  dbgVars: seq[(string, string, string)]         # name, type, value
  dbgOut: seq[string]
  bpNums: Table[(string, int), string]           # (file, line) → gdb's breakpoint number
  dbgRunTo = ""                                  # run to cursor: a one-time breakpoint for the next start
  dbgArgs = ""                                   # the program's arguments for the next start (a test's name)
  dbgLaunchCmd = ""
  dbgPretty = false
  dbgPendingBps = 0
  dbgLaunchLater = false
  dbgExpanded: HashSet[string]                   # variables shown with their fields / items (C names)
  dbgDetail: Table[string, string]               # … and what gdb printed for them
  dbgWatchVals: seq[string]
  dbgCondPending = ""                            # stopped at a conditional breakpoint: its condition, to check
  dbgLogPending = ""                             # stopped at a logpoint: its message, to print (then go on)
  dbgLogAt = ""                                  # (its file:line, as shown)
  dbgLogExprs, dbgLogVals: seq[string]           # its {expressions} and what gdb answered for them
  dbgLogWait = 0
  dbgWatchpoints: seq[(string, string)]          # "stop when it changes": (expression, gdb's number · DAP's data id)
  dbgWpLookup, dbgWpSet: seq[string]             # watchpoints on their way: gdb looking up a global's C name · setting it
  dbgWpStartupLeft = 0                           # (of those, set before the program starts: it waits for them)
  dbgGlobals: Table[string, seq[string]]         # the program's Nim globals: name → C names (counter → counter__app_u3)
  dapCaps: JsonNode                              # what the debug adapter said it can do
  dapWpTried: HashSet[string]                    # "stop when it changes" asked of the adapter this session (at the first stop)
  dbgCondShown = ""

type DapCb = proc(body: JsonNode, ok: bool, msg: string) {.closure.}

var
  dbgDap = false                       # the session speaks DAP (not gdb's machine interface)
  dapSeq = 0
  dapPending: Table[int, DapCb]
  dapRbuf = ""
  dapSock: cint = -1                   # an adapter reached over TCP (delve)
  dapParentSock: cint = -1             # js-debug: the first session, kept open while its child session debugs
  dapPort = 0
  dapThread = 0
  dapFrameId = 0
  dapVarRefs: Table[string, int]       # a variable → its variablesReference (it has fields or items)
  dapTempBp: (string, int) = ("", -1)  # run to cursor: a breakpoint taken away at the next stop
  dapLaunched = false
  dapInitDone = false                  # the adapter answered "initialize" (what it printed before is its banner)

var conflictScanAt: Table[int, MonoTime]

proc conflictsOf(b: Buffer): seq[Conflict] =
  ## the conflict blocks in the buffer, each as the lines of its <<<<<<<, ||||||| (-1 when there is no common-ancestor
  ## part), ======= and >>>>>>> marks; kept until the text changes (a big file is scanned again at most once a second
  ## while typing)
  let c = conflictCache.getOrDefault(b.id, (-1, @[]))
  if c[0] == b.changeId: return c[1]
  # a big file: scanned again at most once a second while you type (markers rarely change)
  if b.lines.len > 20_000 and c[0] >= 0 and msSince(conflictScanAt.getOrDefault(b.id)) < 1000: return c[1]
  conflictScanAt[b.id] = getMonoTime()
  var start, base, mid = -1
  for i, l in b.lines:
    if l.len < 7 or l[0] notin {'<', '|', '=', '>'}: continue
    if l.startsWith("<<<<<<<"): (start = i; base = -1; mid = -1)
    elif start >= 0 and l.startsWith("|||||||"): base = i
    elif start >= 0 and l.startsWith("======="): mid = i
    elif start >= 0 and mid > start and l.startsWith(">>>>>>>"):
      result.add (start, base, mid, i)
      start = -1
  conflictCache[b.id] = (b.changeId, result)

proc conflictAt(b: Buffer, line: int): int =
  ## the index of the conflict block that holds this line, or -1
  for i, c in b.conflictsOf():
    if line >= c.start and line <= c.stop: return i
  -1

proc resolveConflict(b: Buffer, ci: int, choice: string)
