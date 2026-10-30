## ned on Windows: the POSIX calls ned makes, done with Win32 and the C runtime — imported as `posix` there, so the
## rest of ned stays one program. What it covers:
## · the console: raw mode (tcGetAttr/tcSetAttr) as console modes with virtual-terminal input and output, UTF-8 code
##   pages; its size (ioctl TIOCGWINSZ); its keys read as the bytes a Unix terminal sends (the console's VT input);
##   a resize noticed and told to the SIGWINCH handler; the window closing told to the SIGHUP handler
## · file descriptors: the C runtime's, read without blocking when they are pipes; sockets (winsock); pseudo-terminals
##   (ConPTY: a descriptor of ned's own for its two pipes)
## · poll: each descriptor asked (a pipe's bytes waiting, the console's input, a socket's select) every few ms
## · processes: started with CreateProcessW (winSpawn), waited for, stopped; a pseudo-console for the terminal panel
## · what has no meaning on Windows (owners, modes, sessions, priorities): calls that succeed and do nothing
## Built and checked with zig's C compiler (x86_64-windows-gnu); see README › Windows.

when not defined(windows):
  {.error: "ned/sys/winposix is the Windows side of ned's POSIX calls".}


import std/[os, strutils, tables, winlean, widestrs, monotimes, times, locks]
export winlean.SocketHandle, winlean.SockAddr, winlean.Sockaddr_in, winlean.SockLen, winlean.AF_INET,
       winlean.Servent, winlean.getservbyname, winlean.inet_addr

type
  Pid* = int32
  Mode* = uint32
  Off* = int64
  Uid* = uint32
  Gid* = uint32
  Tnfds* = culong
  TPollfd* = object
    fd*: cint
    events*, revents*: cshort
  Stat* = object
    st_mode*: Mode
    st_size*: Off
    st_uid*: Uid
    st_gid*: Gid
    st_nlink*: uint32
    st_mtime*: int64
  Timespec* = object
    tv_sec*: int64
    tv_nsec*: int
  Rusage* = object
    ru_maxrss*: int
  Utsname* = object
    sysname*, nodename*, release*, version*, machine*: array[65, char]
  IOctl_WinSize* = object
    ws_row*, ws_col*, ws_xpixel*, ws_ypixel*: uint16
  Termios* = object
    c_iflag*, c_oflag*, c_cflag*, c_lflag*: uint32
    c_cc*: array[32, char]
    inMode, outMode: uint32          # (the console's own modes, as they were)
    inCP, outCP: uint32
  Sighandler* = proc (a: cint) {.noconv.}
  TSa_Family* = uint16
  Sockaddr_un* = object
    sun_family*: TSa_Family
    sun_path*: array[108, char]
  DIR* = object

const
  # errno (the C runtime's numbers)
  EPERM* = 1.cint
  ENOENT* = 2.cint
  ESRCH* = 3.cint
  EINTR* = 4.cint
  EBADF* = 9.cint
  EAGAIN* = 11.cint
  EWOULDBLOCK* = 11.cint
  EACCES* = 13.cint
  EEXIST* = 17.cint
  EINVAL* = 22.cint
  EROFS* = 30.cint
  EPIPE* = 32.cint
  # open
  O_RDONLY* = 0x0000.cint
  O_WRONLY* = 0x0001.cint
  O_RDWR* = 0x0002.cint
  O_APPEND* = 0x0008.cint
  O_CREAT* = 0x0100.cint
  O_TRUNC* = 0x0200.cint
  O_EXCL* = 0x0400.cint
  O_BINARY = 0x8000.cint
  O_NOINHERIT = 0x0080.cint
  O_CLOEXEC* = 0x0080.cint           # (_O_NOINHERIT)
  O_NOCTTY* = 0.cint
  O_NONBLOCK* = 0x800000.cint         # (no C runtime flag: fcntl sets a socket so; pipes are read without blocking)
  O_NOFOLLOW* = 0.cint
  # fcntl
  F_GETFL* = 3.cint
  F_SETFL* = 4.cint
  F_GETFD* = 1.cint
  F_SETFD* = 2.cint
  FD_CLOEXEC* = 1.cint
  # poll
  POLLIN* = 0x001.cshort
  POLLPRI* = 0x002.cshort
  POLLOUT* = 0x004.cshort
  POLLERR* = 0x008.cshort
  POLLHUP* = 0x010.cshort
  POLLNVAL* = 0x020.cshort
  # signals (the numbers ned's code names; the C runtime has SIGINT, SIGTERM, SIGSEGV of them)
  SIGHUP* = 1.cint
  SIGINT* = 2.cint
  SIGQUIT* = 3.cint
  SIGKILL* = 9.cint
  SIGSEGV* = 11.cint
  SIGPIPE* = 13.cint
  SIGTERM* = 15.cint
  SIGTTOU* = 22.cint
  SIGWINCH* = 28.cint
  WNOHANG* = 1.cint
  # termios (raw mode is what ICANON's absence says)
  BRKINT* = 0x0002'u32
  ICRNL* = 0x0100'u32
  INPCK* = 0x0010'u32
  ISTRIP* = 0x0020'u32
  IXON* = 0x0400'u32
  OPOST* = 0x0001'u32
  CS8* = 0x0030'u32
  ECHO* = 0x0008'u32
  ICANON* = 0x0002'u32
  IEXTEN* = 0x8000'u32
  ISIG* = 0x0001'u32
  VERASE* = 2
  VMIN* = 6
  VTIME* = 5
  TCSAFLUSH* = 2.cint
  TIOCGWINSZ* = 0x5413.culong
  TIOCSWINSZ* = 0x5414.culong
  TIOCSCTTY* = 0x540E.culong
  CLOCK_THREAD_CPUTIME_ID* = 3.cint
  RUSAGE_SELF* = 0.cint
  SC_PAGESIZE* = 30.cint
  W_OK* = 2.cint
  R_OK* = 4.cint
  S_IFMT = 0xF000'u32
  S_IFDIR = 0x4000'u32
  S_IFREG = 0x8000'u32
  PROT_READ* = 1.cint
  MAP_SHARED* = 1.cint
  POSIX_FADV_WILLNEED* = 3.cint
  AF_UNIX* = 1.cint
  SOCK_STREAM* = 1.cint
  LC_ALL* = 0.cint
  LC_CTYPE* = 2.cint

let
  SIG_DFL* = cast[Sighandler](0)
  SIG_IGN* = cast[Sighandler](1)
  MAP_FAILED* = cast[pointer](-1)
  INVALID_SOCKET* = SocketHandle(-1)    # (ned's socket descriptors: -1 when there is none)

# true when the mode bits say a folder
template S_ISDIR*(m: Mode): bool = (m and S_IFMT) == S_IFDIR
# true when the mode bits say a regular file
template S_ISREG*(m: Mode): bool = (m and S_IFMT) == S_IFREG
# true when a wait status says the process ended by itself (the statuses here are the exit code shifted left by 8)
template WIFEXITED*(s: cint): bool = (s and 0x7f) == 0
# the exit code in a wait status
template WEXITSTATUS*(s: cint): cint = (s shr 8) and 0xff
# true when a wait status says the process was ended by a signal (it never is with the statuses `waitpidImpl` makes)
template WIFSIGNALED*(s: cint): bool = (s and 0x7f) != 0 and (s and 0x7f) != 0x7f
# the signal number in a wait status
template WTERMSIG*(s: cint): cint = s and 0x7f

# ── the C runtime ──

var errno* {.importc, header: "<errno.h>".}: cint
proc c_read(fd: cint, buf: pointer, n: cuint): cint {.importc: "_read", header: "<io.h>".}
proc c_write(fd: cint, buf: pointer, n: cuint): cint {.importc: "_write", header: "<io.h>".}
proc c_close(fd: cint): cint {.importc: "_close", header: "<io.h>".}
proc c_open(path: cstring, flags: cint, mode: cint): cint {.importc: "_open", header: "<io.h>".}
proc c_dup(fd: cint): cint {.importc: "_dup", header: "<io.h>".}
proc c_dup2(a, b: cint): cint {.importc: "_dup2", header: "<io.h>".}
proc c_isatty(fd: cint): cint {.importc: "_isatty", header: "<io.h>".}
proc c_commit(fd: cint): cint {.importc: "_commit", header: "<io.h>".}
proc c_getosfhandle(fd: cint): int {.importc: "_get_osfhandle", header: "<io.h>".}
proc c_openosfhandle(h: int, flags: cint): cint {.importc: "_open_osfhandle", header: "<io.h>".}
proc c_setmode(fd: cint, mode: cint): cint {.importc: "_setmode", header: "<io.h>".}
proc c_strerror(e: cint): cstring {.importc: "strerror", header: "<string.h>".}
proc c_signal(sig: cint, h: Sighandler): Sighandler {.importc: "signal", header: "<signal.h>".}
proc c_getpid(): cint {.importc: "_getpid", header: "<process.h>".}
proc c_exit(code: cint) {.importc: "_exit", header: "<stdlib.h>", noreturn.}

# ── Win32 (what winlean has not) ──

type
  Coord = object                  # (COORD)
    X, Y: int16
  SmallRect = object              # (SMALL_RECT)
    Left, Top, Right, Bottom: int16
  ConsoleScreenBufferInfo = object  # (CONSOLE_SCREEN_BUFFER_INFO)
    dwSize: Coord
    dwCursorPosition: Coord
    wAttributes: uint16
    srWindow: SmallRect
    dwMaximumWindowSize: Coord
  KeyEventRecord = object       # (KEY_EVENT_RECORD's layout)
    bKeyDown: int32
    wRepeatCount: uint16
    wVirtualKeyCode: uint16
    wVirtualScanCode: uint16
    uChar: uint16              # (the union's UnicodeChar)
    dwControlKeyState: uint32
  InputRecord = object          # (INPUT_RECORD's layout: the event's kind, then its union — 16 bytes at offset 4)
    EventType: uint16
    pad: uint16
    Event: array[16, byte]
  FileTime = object
    lo, hi: uint32
  ProcessMemoryCounters = object  # (PROCESS_MEMORY_COUNTERS)
    cb: uint32
    PageFaultCount: uint32
    PeakWorkingSetSize: csize_t
    WorkingSetSize: csize_t
    QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage, QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage: csize_t
    PagefileUsage, PeakPagefileUsage: csize_t
  StartupInfoExW = object         # (STARTUPINFOEXW)
    StartupInfo: STARTUPINFO
    lpAttributeList: pointer
  HandlerRoutine = proc (ctrlType: uint32): int32 {.stdcall.}
  JobBasicLimits = object       # (JOBOBJECT_BASIC_LIMIT_INFORMATION)
    perProcessUserTimeLimit, perJobUserTimeLimit: int64
    limitFlags: uint32
    minimumWorkingSetSize, maximumWorkingSetSize: csize_t
    activeProcessLimit: uint32
    affinity: uint
    priorityClass, schedulingClass: uint32
  JobExtendedLimits = object    # (JOBOBJECT_EXTENDED_LIMIT_INFORMATION)
    basic: JobBasicLimits
    io: array[6, uint64]
    processMemoryLimit, jobMemoryLimit, peakProcessMemoryUsed, peakJobMemoryUsed: csize_t

const
  STD_INPUT_HANDLE = -10'i32
  STD_OUTPUT_HANDLE = -11'i32
  ENABLE_PROCESSED_INPUT = 0x0001'u32
  ENABLE_LINE_INPUT = 0x0002'u32
  ENABLE_ECHO_INPUT = 0x0004'u32
  ENABLE_WINDOW_INPUT = 0x0008'u32
  ENABLE_MOUSE_INPUT = 0x0010'u32
  ENABLE_QUICK_EDIT_MODE = 0x0040'u32
  ENABLE_EXTENDED_FLAGS = 0x0080'u32
  ENABLE_VIRTUAL_TERMINAL_INPUT = 0x0200'u32
  ENABLE_PROCESSED_OUTPUT = 0x0001'u32
  ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004'u32
  DISABLE_NEWLINE_AUTO_RETURN = 0x0008'u32
  KEY_EVENT = 0x0001'u16
  WINDOW_BUFFER_SIZE_EVENT = 0x0004'u16
  FILE_TYPE_DISK = 1'i32
  FILE_TYPE_CHAR = 2'i32
  FILE_TYPE_PIPE = 3'i32
  ERROR_BROKEN_PIPE = 109'i32
  ERROR_NO_DATA = 232'i32
  HANDLE_FLAG_INHERIT = 1'i32
  STARTF_USESTDHANDLES = 0x100'i32
  CREATE_NO_WINDOW = 0x08000000'i32
  CREATE_NEW_PROCESS_GROUP = 0x00000200'i32
  CREATE_UNICODE_ENVIRONMENT = 0x00000400'i32
  EXTENDED_STARTUPINFO_PRESENT = 0x00080000'i32
  BELOW_NORMAL_PRIORITY_CLASS = 0x00004000'i32
  IDLE_PRIORITY_CLASS = 0x00000040'i32
  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016'u
  CREATE_SUSPENDED = 0x00000004'i32
  JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000'u32
  JobObjectExtendedLimitInformation = 9'i32
  STILL_ACTIVE = 259'i32
  PROCESS_TERMINATE = 0x0001'i32
  PROCESS_QUERY_LIMITED_INFORMATION = 0x1000'i32
  SYNCHRONIZE = 0x00100000'i32
  CP_UTF8 = 65001'u32
  CTRL_CLOSE_EVENT = 2'u32
  CTRL_LOGOFF_EVENT = 5'u32
  CTRL_SHUTDOWN_EVENT = 6'u32
  MOVEFILE_REPLACE_EXISTING = 1'u32
  MOVEFILE_WRITE_THROUGH = 8'u32
  CF_UNICODETEXT = 13'u32
  GMEM_MOVEABLE = 2'u32

proc GetStdHandle(n: int32): Handle {.stdcall, importc, dynlib: "kernel32".}
proc GetConsoleMode(h: Handle, m: ptr uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc SetConsoleMode(h: Handle, m: uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc GetConsoleCP(): uint32 {.stdcall, importc, dynlib: "kernel32".}
proc GetConsoleOutputCP(): uint32 {.stdcall, importc, dynlib: "kernel32".}
proc SetConsoleCP(cp: uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc SetConsoleOutputCP(cp: uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc GetConsoleScreenBufferInfo(h: Handle, i: ptr ConsoleScreenBufferInfo): int32 {.stdcall, importc, dynlib: "kernel32".}
proc GetNumberOfConsoleInputEvents(h: Handle, n: ptr uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc ReadConsoleInputW(h: Handle, buf: ptr InputRecord, n: uint32, got: ptr uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc SetConsoleCtrlHandler(h: HandlerRoutine, add: int32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc GetFileType(h: Handle): int32 {.stdcall, importc, dynlib: "kernel32".}
proc PeekNamedPipe(h: Handle, buf: pointer, size: uint32, read, avail, left: ptr uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc SetHandleInformation(h: Handle, mask, flags: int32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc GetThreadTimes(h: Handle, c, e, k, u: ptr FileTime): int32 {.stdcall, importc, dynlib: "kernel32".}
proc GetCurrentThread(): Handle {.stdcall, importc, dynlib: "kernel32".}
proc GetCurrentProcess(): Handle {.stdcall, importc, dynlib: "kernel32".}
proc K32GetProcessMemoryInfo(p: Handle, c: ptr ProcessMemoryCounters, cb: uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc OpenProcess(access: int32, inherit: int32, pid: uint32): Handle {.stdcall, importc, dynlib: "kernel32".}
proc MoveFileExW(a, b: WideCString, flags: uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc FlushFileBuffers(h: Handle): int32 {.stdcall, importc, dynlib: "kernel32".}
proc SetPriorityClass(h: Handle, c: int32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc GetModuleHandleA(name: cstring): Handle {.stdcall, importc, dynlib: "kernel32".}
proc GetProcAddress(m: Handle, name: cstring): pointer {.stdcall, importc, dynlib: "kernel32".}
proc InitializeProcThreadAttributeList(l: pointer, n: uint32, flags: uint32, size: ptr csize_t): int32 {.stdcall,
  importc, dynlib: "kernel32".}
proc UpdateProcThreadAttribute(l: pointer, flags: uint32, attr: uint, val: pointer, size: csize_t,
                               prev: pointer, retSize: ptr csize_t): int32 {.stdcall, importc, dynlib: "kernel32".}
proc DeleteProcThreadAttributeList(l: pointer) {.stdcall, importc, dynlib: "kernel32".}
proc CreateJobObjectW(sa: pointer, name: WideCString): Handle {.stdcall, importc, dynlib: "kernel32".}
proc SetInformationJobObject(job: Handle, cls: int32, info: pointer, n: uint32): int32 {.stdcall, importc,
  dynlib: "kernel32".}
proc AssignProcessToJobObject(job, p: Handle): int32 {.stdcall, importc, dynlib: "kernel32".}
proc TerminateJobObject(job: Handle, code: uint32): int32 {.stdcall, importc, dynlib: "kernel32".}
proc SetNamedPipeHandleState(h: Handle, mode: ptr uint32, maxCollect, timeout: pointer): int32 {.stdcall, importc,
  dynlib: "kernel32".}
proc OpenClipboard(w: Handle): int32 {.stdcall, importc, dynlib: "user32".}
proc CloseClipboard(): int32 {.stdcall, importc, dynlib: "user32".}
proc EmptyClipboard(): int32 {.stdcall, importc, dynlib: "user32".}
proc GetClipboardData(f: uint32): Handle {.stdcall, importc, dynlib: "user32".}
proc SetClipboardData(f: uint32, h: Handle): Handle {.stdcall, importc, dynlib: "user32".}
proc GlobalAlloc(flags: uint32, n: csize_t): Handle {.stdcall, importc, dynlib: "kernel32".}
proc GlobalLock(h: Handle): pointer {.stdcall, importc, dynlib: "kernel32".}
proc GlobalUnlock(h: Handle): int32 {.stdcall, importc, dynlib: "kernel32".}

type
  CreatePseudoConsoleFn = proc (size: Coord, hIn, hOut: Handle, flags: uint32, pc: ptr Handle): int32 {.stdcall.}
  ResizePseudoConsoleFn = proc (pc: Handle, size: Coord): int32 {.stdcall.}
  ClosePseudoConsoleFn = proc (pc: Handle) {.stdcall.}

# ── what ned's descriptors are ──

type
  VirtKind = enum vkPty, vkSock
  VirtFd = object               # a descriptor of ned's own (numbers from VirtBase up)
    case kind: VirtKind
    of vkPty:                   # a pseudo-terminal: ned writes to its input pipe, reads its output pipe
      inW, outR: Handle
      pc: Handle                # the pseudo-console
      pid: Pid
    of vkSock:
      sock: SocketHandle        # a winsock socket

const VirtBase = 100_000

var
  wpLock: Lock                  # (virts and procs: threads read and write files too)
  virts: Table[cint, VirtFd]
  nextVirt = VirtBase.cint
  procs: Table[Pid, (Handle, Handle)]   # the processes ned started (their handle, their job): waited for, stopped
  sigHandlers: array[64, Sighandler]
  conIn, conOut: Handle
  conInputOk = false            # stdin is a console (its events read as the bytes a terminal sends)
  conPending: string            # what the console said, not read yet
  conHighSurrogate: uint16
  lastCols, lastRows = -1       # (a resize: told to the SIGWINCH handler)
  wsaStarted = false

initLock(wpLock)

proc virtGet(fd: cint, v: var VirtFd): bool =
  ## copies the record of a descriptor of ned's own (a pseudo-terminal or a socket) into `v`; false for an ordinary
  ## descriptor or an unknown one
  if fd < VirtBase: return false
  {.cast(noSideEffect), cast(gcsafe).}:
    withLock wpLock:
      if fd in virts:
        v = virts[fd]
        result = true

proc virtAdd(v: VirtFd): cint =
  ## registers a descriptor of ned's own and returns its number, counted up from `VirtBase`
  {.cast(noSideEffect), cast(gcsafe).}:
    withLock wpLock:
      result = nextVirt
      inc nextVirt
      virts[result] = v

proc procHandle(pid: Pid): Handle =
  ## the process handle of a process ned started, by its id (0 when it is not one)
  {.cast(noSideEffect), cast(gcsafe).}:
    withLock wpLock: result = procs.getOrDefault(pid, (Handle(0), Handle(0)))[0]

proc procJob(pid: Pid): Handle =
  ## the job object (the group `kill` stops) of a process ned started, or 0
  {.cast(noSideEffect), cast(gcsafe).}:
    withLock wpLock: result = procs.getOrDefault(pid, (Handle(0), Handle(0)))[1]

proc procAdd(pid: Pid, h, job: Handle) =
  ## remembers a process ned started: its handle and its job
  {.cast(noSideEffect), cast(gcsafe).}:
    withLock wpLock: procs[pid] = (h, job)

proc procDel(pid: Pid) =
  ## forgets a process ned started
  {.cast(noSideEffect), cast(gcsafe).}:
    withLock wpLock: procs.del(pid)

proc winInitOnce()

proc handlerOf(sig: cint): Sighandler =
  ## the handler `signal` set for that signal
  {.cast(noSideEffect), cast(gcsafe).}: result = sigHandlers[sig]
proc conOk(): bool =
  ## true when stdin is a console, whose key events are read as the bytes a terminal sends
  {.cast(noSideEffect), cast(gcsafe).}: result = conInputOk
proc conInH(): Handle =
  ## the console's input handle
  {.cast(noSideEffect), cast(gcsafe).}: result = conIn
proc conOutH(): Handle =
  ## the console's output handle
  {.cast(noSideEffect), cast(gcsafe).}: result = conOut
proc conPendingLen(): int =
  ## how many bytes of console input have been read but not handed to a `read` yet
  {.cast(noSideEffect), cast(gcsafe).}: result = conPending.len

proc winInit() =
  ## makes sure the Windows side is set up (once)
  {.cast(noSideEffect), cast(gcsafe).}:
    if conIn == 0: winInitOnce()

proc winInitOnce() =
  ## takes the console's handles, notes whether stdin is a console, puts the three standard descriptors in binary mode
  ## and starts winsock
  conIn = GetStdHandle(STD_INPUT_HANDLE)
  conOut = GetStdHandle(STD_OUTPUT_HANDLE)
  var m: uint32
  conInputOk = GetConsoleMode(conIn, addr m) != 0
  discard c_setmode(0, O_BINARY)
  discard c_setmode(1, O_BINARY)
  discard c_setmode(2, O_BINARY)
  if not wsaStarted:
    var d: WSAData
    wsaStarted = wsaStartup(0x0202, addr d) == 0

proc osHandle(fd: cint): Handle =
  ## the Win32 handle behind a C runtime descriptor; -1 for a bad descriptor or one of ned's own
  if fd < 0 or fd >= VirtBase: return Handle(-1)
  Handle(c_getosfhandle(fd))

# ── signals ──

proc ctrlHandler(ctrlType: uint32): int32 {.stdcall.} =
  ## the console window closing, the user logging off: ned's SIGHUP handler (its unsaved work kept), a moment for it
  if ctrlType in [CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT]:
    let h = handlerOf(SIGHUP)
    if h != nil and h != SIG_IGN and h != SIG_DFL:
      h(SIGHUP)
      winlean.sleep(3000)               # (the main thread saves; Windows ends the process after the handler returns)
    return 1
  0

proc signal*(sig: cint, h: Sighandler): Sighandler {.discardable.} =
  ## sets the handler of a signal and returns the one before. SIGINT, SIGTERM and SIGSEGV go on to the C runtime; SIGHUP
  ## is also made the console's close, log-off and shutdown event; the others are only noted (SIGWINCH is called by
  ## `checkResize`).
  winInit()
  if sig >= 0 and sig < 64:
    {.cast(noSideEffect), cast(gcsafe).}:
      result = sigHandlers[sig]
      sigHandlers[sig] = h
  if sig in [SIGINT, SIGTERM, SIGSEGV]: discard c_signal(sig, h)
  if sig == SIGHUP: discard SetConsoleCtrlHandler(ctrlHandler, 1)

proc killImpl(pid: Pid, sig: cint): cint =
  ## sig 0: is it running; anything else: it is stopped (TerminateProcess — a process group: its leader)
  let p = abs(pid)
  var h = procHandle(Pid(p))
  var own = false
  if h == 0:
    h = OpenProcess(PROCESS_TERMINATE or PROCESS_QUERY_LIMITED_INFORMATION or SYNCHRONIZE, 0, uint32(p))
    own = true
  if h == 0:
    errno = ESRCH
    return -1
  defer:
    if own: discard closeHandle(h)
  if sig == 0:
    var code: int32
    if getExitCodeProcess(h, code) != 0 and code == STILL_ACTIVE: return 0
    errno = ESRCH
    return -1
  # (a process ned started: it and everything it started — its job; POSIX's process group)
  let job = procJob(Pid(p))
  if job != 0 and TerminateJobObject(job, uint32(128 + sig)) != 0: return 0
  if terminateProcess(h, 128 + sig) == 0:
    errno = EPERM
    return -1
  0

proc waitpidImpl(pid: Pid, status: var cint, options: cint): Pid =
  ## a process ned started: its exit code as POSIX's wait status (code shl 8); WNOHANG: 0 while it runs
  let h = procHandle(pid)
  if h == 0:
    errno = ESRCH
    return -1
  let r = waitForSingleObject(h, (if (options and WNOHANG) != 0: 0'i32 else: -1'i32))
  if r != 0: return 0
  var code: int32
  discard getExitCodeProcess(h, code)
  status = cint((code and 0xff) shl 8)
  let job = procJob(pid)
  discard closeHandle(h)
  if job != 0: discard closeHandle(job)         # (what it left running goes with it: kill on close)
  procDel(pid)
  pid

# this process's id
proc getpid*(): Pid = Pid(c_getpid())
# the parent's id as ned's launcher left it in $NED_PARENT_PID (0 when it did not)
proc getppid*(): Pid = Pid(parseInt(getEnv("NED_PARENT_PID", "0")))
# always 0: Windows has no user ids
proc getuid*(): Uid = 0
# always 0: Windows has no group ids
proc getgid*(): Gid = 0
# the process's own id: there are no process groups
proc getpgrp*(): Pid = getpid()
# does nothing; gives the process's own id (there are no sessions)
proc setsid*(): Pid = getpid()
# does nothing and succeeds (there are no process groups)
proc setpgid*(a, b: Pid): cint = 0
# does nothing and succeeds (there are no terminal process groups)
proc tcsetpgrp*(fd: cint, p: Pid): cint = 0
# does nothing: a lower priority is asked for when a process is started (`winSpawn`)
proc nice*(n: cint): cint = 0
# does nothing (files have no modes here)
proc umask*(m: Mode): Mode = 0
# does nothing and succeeds (files have no modes here)
proc chmod*(p: cstring, m: Mode): cint = 0
# does nothing and succeeds (files have no modes here)
proc fchmod*(fd: cint, m: Mode): cint = 0
# does nothing and succeeds (files have no owners here)
proc chown*(p: cstring, u: Uid, g: Gid): cint = 0
proc symlink*(a, b: cstring): cint =
  ## always fails with EPERM: Windows keeps symbolic links for those with the right to make them
  errno = EPERM
  -1
# only the page size (4096) is known; anything else gives -1
proc sysconf*(n: cint): int = (if n == SC_PAGESIZE: 4096 else: -1)
# the C runtime's text for an error number
proc strerror*(e: cint): cstring = c_strerror(e)
# ends the process at once, as the C runtime's _exit does
proc exitnow*(code: cint) {.noreturn.} = c_exit(code)
proc isatty*(fd: cint): cint =
  ## true for stdin when it is a console (with ned's own handling of it), else what the C runtime says for the
  ## descriptor
  winInit()
  if fd == 0 and conOk(): return 1
  c_isatty(fd)
# "CONIN$" — the console's input, which can be opened to read keys from — when the descriptor is a terminal, else nil
proc ttyname*(fd: cint): cstring = (if isatty(fd) != 0: "CONIN$" else: nil)   # (the console's input)
# 0 when a file or folder of that path exists, else -1 (the mode asked for is not looked at)
proc access*(p: cstring, mode: cint): cint = (if fileExists($p) or dirExists($p): 0 else: -1)

proc uname*(u: var Utsname): cint =
  ## fills in what Windows can say of itself: the system "Windows" and the machine's CPU kind
  proc put(a: var array[65, char], s: string) =
    ## copies a string into a 65-character field, cut at 64
    for i, c in s:
      if i < 64: a[i] = c
  put(u.sysname, "Windows")
  put(u.machine, (when defined(amd64): "x86_64" elif defined(arm64): "aarch64" else: "x86"))
  put(u.release, "")
  0

proc getrusage*(who: cint, r: ptr Rusage): cint =
  ## the highest memory this process has used, in KB, as `ru_maxrss`
  var c: ProcessMemoryCounters
  c.cb = uint32(sizeof(c))
  if K32GetProcessMemoryInfo(GetCurrentProcess(), addr c, c.cb) == 0: return -1
  r.ru_maxrss = int(c.PeakWorkingSetSize div 1024)
  0

proc clock_gettime*(clk: cint, ts: var Timespec): cint =
  ## (CLOCK_THREAD_CPUTIME_ID) the processor time this thread has used
  var c, e, k, u: FileTime
  if GetThreadTimes(GetCurrentThread(), addr c, addr e, addr k, addr u) == 0: return -1
  let t100 = (int64(k.hi) shl 32 or int64(k.lo)) + (int64(u.hi) shl 32 or int64(u.lo))
  ts.tv_sec = t100 div 10_000_000
  ts.tv_nsec = int((t100 mod 10_000_000) * 100)
  0

# ── files ──

proc stat*(p: cstring, s: var Stat): cint =
  ## a path's size, link count, modification time and mode; the mode is only a folder or a regular file, with owner-only
  ## rights (Windows' access lists are not modes). ENOENT when it cannot be read.
  try:
    let i = getFileInfo($p)
    # (the user's own, only theirs: what Windows gives a file in their profile — ACLs are not modes)
    s.st_mode = (if i.kind in {pcDir, pcLinkToDir}: S_IFDIR or 0o700'u32 else: S_IFREG or 0o600'u32)
    s.st_size = i.size
    s.st_nlink = uint32(i.linkCount)
    s.st_mtime = i.lastWriteTime.toUnix
    0
  except CatchableError:
    errno = ENOENT
    -1
# the same as `stat` (a link is followed)
proc lstat*(p: cstring, s: var Stat): cint = stat(p, s)
proc fstat*(fd: cint, s: var Stat): cint =
  ## the size of an open file, and a regular file's mode
  let h = osHandle(fd)
  if h == Handle(-1): return -1
  var hi: int32
  let lo = getFileSize(h, addr hi)
  s.st_size = (int64(hi) shl 32) or int64(uint32(lo))
  s.st_mode = S_IFREG
  0

proc open*(p: cstring, flags: cint): cint =
  ## opens a file by the C runtime in binary mode, never non-blocking; "/dev/null" is the NUL device
  winInit()
  if $p == "/dev/null": return c_open("NUL", (flags and 3) or O_BINARY or O_NOINHERIT, 0o666)
  c_open(p, (flags and not O_NONBLOCK) or O_BINARY, 0o666)
# `open` with the mode ignored: files have no modes here
proc open*(p: cstring, flags: cint, mode: Mode): cint = open(p, flags)

proc c_unlink(p: cstring): cint {.importc: "_unlink", header: "<io.h>".}
proc c_chdir(p: cstring): cint {.importc: "_chdir", header: "<direct.h>".}
# deletes a file by the C runtime
proc unlink*(p: cstring): cint = c_unlink(p)
# changes the current folder by the C runtime
proc chdir*(p: cstring): cint = c_chdir(p)

proc fsync*(fd: cint): cint =
  ## writes the file's buffers out to disk
  let h = osHandle(fd)
  if h == Handle(-1): return -1
  (if FlushFileBuffers(h) != 0: 0 else: -1)

proc c_ioctlsocket(s: SocketHandle, cmd: clong, arg: ptr culong): cint {.stdcall, importc: "ioctlsocket",
  dynlib: "ws2_32.dll".}

# does nothing (the form with no argument: F_GETFL, F_GETFD …)
proc fcntl*(fd: cint, cmd: cint): cint = 0
proc fcntl*(fd: cint, cmd: cint, arg: cint): cint =
  ## F_SETFL with O_NONBLOCK: a socket that does not block (FIONBIO), a pipe that takes what fits (PIPE_NOWAIT: a
  ## write to a full pipe returns at once — EAGAIN — as on Unix); anything else: nothing to do
  if cmd != F_SETFL: return 0
  var v: VirtFd
  if virtGet(fd, v):
    if v.kind == vkSock:
      var on = culong(if (arg and O_NONBLOCK) != 0: 1 else: 0)
      discard c_ioctlsocket(v.sock, cast[clong](0x8004667E'u32), addr on)       # FIONBIO
    return 0
  let h = osHandle(fd)
  if h != Handle(-1) and GetFileType(h) == FILE_TYPE_PIPE:
    var mode = uint32(if (arg and O_NONBLOCK) != 0: 1 else: 0)                   # PIPE_NOWAIT / PIPE_WAIT
    discard SetNamedPipeHandleState(h, addr mode, nil, nil)
  0
proc ioctlWinSize(ws: ptr IOctl_WinSize): cint =
  ## the console window's size in columns and rows (the visible part of its buffer); -1 when there is no console
  winInit()
  var i: ConsoleScreenBufferInfo
  if GetConsoleScreenBufferInfo(conOutH(), addr i) == 0: return -1
  ws.ws_col = uint16(i.srWindow.Right - i.srWindow.Left + 1)
  ws.ws_row = uint16(i.srWindow.Bottom - i.srWindow.Top + 1)
  0

var resizePseudo: ResizePseudoConsoleFn
var closePseudo: ClosePseudoConsoleFn
var createPseudo: CreatePseudoConsoleFn

proc conptyLoad(): bool =
  ## ConPTY (Windows 10 1809 and later), found at run time — an older Windows starts ned without its terminal
  {.cast(noSideEffect), cast(gcsafe).}:
    if createPseudo != nil: return true
    let k = GetModuleHandleA("kernel32.dll")
    if k == 0: return false
    createPseudo = cast[CreatePseudoConsoleFn](GetProcAddress(k, "CreatePseudoConsole"))
    resizePseudo = cast[ResizePseudoConsoleFn](GetProcAddress(k, "ResizePseudoConsole"))
    closePseudo = cast[ClosePseudoConsoleFn](GetProcAddress(k, "ClosePseudoConsole"))
    createPseudo != nil and resizePseudo != nil and closePseudo != nil

# any request but the two below: does nothing and succeeds
proc ioctl*(fd: cint, req: culong): cint {.varargs.} = 0
proc ioctl*(fd: cint, req: culong, ws: ptr IOctl_WinSize): cint =
  ## TIOCGWINSZ gives the console window's size; TIOCSWINSZ on a pseudo-terminal descriptor resizes its pseudo-console;
  ## anything else fails
  if req == TIOCGWINSZ: return ioctlWinSize(ws)
  var v: VirtFd
  if req == TIOCSWINSZ and virtGet(fd, v) and v.kind == vkPty:
    if conptyLoad():
      {.cast(noSideEffect), cast(gcsafe).}: discard resizePseudo(v.pc, Coord(X: int16(ws.ws_col), Y: int16(ws.ws_row)))
    return 0
  -1

# ── reading and writing ──

proc conDrain() =
  ## the console's input events: key presses (with virtual-terminal input, the bytes a terminal sends, as UTF-16
  ## characters) into conPending as UTF-8
  {.cast(noSideEffect), cast(gcsafe).}:
    if not conInputOk: return
    var n: uint32
    if GetNumberOfConsoleInputEvents(conIn, addr n) == 0 or n == 0: return
    var recs: array[64, InputRecord]
    var got: uint32
    if ReadConsoleInputW(conIn, addr recs[0], uint32(min(int(n), recs.len)), addr got) == 0: return
    for i in 0 ..< int(got):
      let r = recs[i]
      if r.EventType == KEY_EVENT:
        let k = cast[ptr KeyEventRecord](unsafeAddr r.Event[0])[]
        if k.bKeyDown == 0 or k.uChar == 0: continue
        let c = k.uChar
        for _ in 0 ..< max(1, int(k.wRepeatCount)):
          if c >= 0xD800'u16 and c <= 0xDBFF'u16:
            conHighSurrogate = c
            continue
          var cp = int(c)
          if c >= 0xDC00'u16 and c <= 0xDFFF'u16 and conHighSurrogate != 0:
            cp = 0x10000 + ((int(conHighSurrogate) - 0xD800) shl 10) + (int(c) - 0xDC00)
            conHighSurrogate = 0
          # UTF-8
          if cp < 0x80: conPending.add char(cp)
          elif cp < 0x800:
            conPending.add char(0xC0 or (cp shr 6))
            conPending.add char(0x80 or (cp and 0x3F))
          elif cp < 0x10000:
            conPending.add char(0xE0 or (cp shr 12))
            conPending.add char(0x80 or ((cp shr 6) and 0x3F))
            conPending.add char(0x80 or (cp and 0x3F))
          else:
            conPending.add char(0xF0 or (cp shr 18))
            conPending.add char(0x80 or ((cp shr 12) and 0x3F))
            conPending.add char(0x80 or ((cp shr 6) and 0x3F))
            conPending.add char(0x80 or (cp and 0x3F))

proc checkResize() =
  ## looks at the console's size and, when it is not the one seen last (and this is not the first look), calls the
  ## SIGWINCH handler
  {.cast(noSideEffect), cast(gcsafe).}:
    var ws: IOctl_WinSize
    if ioctlWinSize(addr ws) != 0: return
    if int(ws.ws_col) != lastCols or int(ws.ws_row) != lastRows:
      let first = lastCols < 0
      lastCols = int(ws.ws_col)
      lastRows = int(ws.ws_row)
      let h = sigHandlers[SIGWINCH]
      if not first and h != nil and h != SIG_IGN and h != SIG_DFL: h(SIGWINCH)

proc pipeRead(h: Handle, buf: pointer, n: int): int =
  ## a pipe read without blocking: what is there now (EAGAIN when nothing), 0 when the other end has closed it
  var avail: uint32
  if PeekNamedPipe(h, nil, 0, nil, addr avail, nil) == 0:
    let e = getLastError()
    if e == ERROR_BROKEN_PIPE or e == ERROR_NO_DATA: return 0
    errno = EBADF
    return -1
  if avail == 0:
    errno = EAGAIN
    return -1
  var got: int32
  if readFile(h, buf, int32(min(int(avail), n)), addr got, nil) == 0:
    if getLastError() == ERROR_BROKEN_PIPE: return 0
    errno = EBADF
    return -1
  int(got)

proc readImpl(fd: cint, buf: pointer, n: int): int =
  ## reads from a descriptor without ever blocking: a socket (EAGAIN when nothing is there), a pseudo-terminal's output
  ## pipe, the console (the bytes of its keys, after `checkResize` and `conDrain`; EAGAIN when none), a pipe
  ## (`pipeRead`), else the C runtime's read
  winInit()
  var v: VirtFd
  if virtGet(fd, v):
    if v.kind == vkSock:
      let r = winlean.recv(v.sock, buf, cint(n), 0)
      if r < 0: errno = (if wsaGetLastError() == WSAEWOULDBLOCK: EAGAIN else: EPIPE)
      return int(r)
    return pipeRead(v.outR, buf, n)
  {.cast(noSideEffect), cast(gcsafe).}:
    if fd == 0 and conInputOk:
      checkResize()
      conDrain()
      if conPending.len == 0:
        errno = EAGAIN
        return -1
      let k = min(n, conPending.len)
      copyMem(buf, addr conPending[0], k)
      conPending = conPending[k .. ^1]
      return k
  let h = osHandle(fd)
  if h != Handle(-1) and GetFileType(h) == FILE_TYPE_PIPE: return pipeRead(h, buf, n)
  int(c_read(fd, buf, cuint(n)))

proc writeImpl(fd: cint, buf: pointer, n: int): int =
  ## writes to a descriptor: a socket, a pseudo-terminal's input pipe, or the C runtime's write; a write of nothing to a
  ## full pipe that does not wait is EAGAIN
  winInit()
  var v: VirtFd
  if virtGet(fd, v):
    if v.kind == vkSock:
      let r = winlean.send(v.sock, buf, cint(n), 0)
      if r < 0: errno = (if wsaGetLastError() == WSAEWOULDBLOCK: EAGAIN else: EPIPE)
      return int(r)
    var put: int32
    if writeFile(v.inW, buf, int32(n), addr put, nil) == 0:
      errno = EPIPE
      return -1
    return int(put)
  let r = int(c_write(fd, buf, cuint(n)))
  if r == 0 and n > 0:
    errno = EAGAIN              # (a pipe without waiting, full: nothing went)
    return -1
  r

proc closeImpl(fd: cint): cint =
  ## closes a descriptor: one of ned's own is forgotten and its socket, or its pseudo-console and pipes, closed; any
  ## other by the C runtime
  var v: VirtFd
  if virtGet(fd, v):
    {.cast(noSideEffect), cast(gcsafe).}:
      withLock wpLock: virts.del(fd)
    if v.kind == vkSock: return closesocket(v.sock)
    if v.pc != 0 and conptyLoad():
      {.cast(noSideEffect), cast(gcsafe).}: closePseudo(v.pc)
    discard closeHandle(v.inW)
    discard closeHandle(v.outR)
    return 0
  c_close(fd)

# duplicates a descriptor by the C runtime
proc dup*(fd: cint): cint = c_dup(fd)
proc dup2*(a, b: cint): cint =
  ## duplicates a descriptor onto another by the C runtime; when that is stdin (`git log | ned`: text on stdin, keys
  ## from the console) the console handle is taken again
  result = c_dup2(a, b)
  if result == 0 and b == 0:
    # stdin is now the console (`git log | ned`: the text read, the keys from CONIN$)
    {.cast(noSideEffect), cast(gcsafe).}:
      winInit()
      conIn = Handle(c_getosfhandle(0))
      var m: uint32
      conInputOk = GetConsoleMode(conIn, addr m) != 0

proc pipe*(fds: var array[0..1, cint]): cint =
  ## two descriptors on an anonymous pipe (not inherited: winSpawn hands children their own ends)
  var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)), bInheritHandle: 0)
  var r, w: Handle
  if createPipe(r, w, sa, 65536) == 0: return -1
  fds[0] = c_openosfhandle(int(r), O_RDONLY or O_BINARY)
  fds[1] = c_openosfhandle(int(w), O_WRONLY or O_BINARY)
  0

# ── sockets ──

proc sockOf(s: SocketHandle): SocketHandle =
  ## (a descriptor of ned's) the winsock socket behind it
  var v: VirtFd
  if virtGet(cint(s), v) and v.kind == vkSock: v.sock else: INVALID_SOCKET

proc socket*(af, typ, protocol: cint): SocketHandle =
  ## a socket, as a descriptor of ned's (read, written, polled and closed like the others)
  winInit()
  let s = winlean.socket(af, typ, protocol)
  if s == INVALID_SOCKET: return SocketHandle(-1)
  SocketHandle(virtAdd(VirtFd(kind: vkSock, sock: s)))

# connects the socket of a descriptor of ned's own
proc connect*(s: SocketHandle, a: ptr SockAddr, n: SockLen): cint = winlean.connect(sockOf(s), a, n)
# binds the socket of a descriptor of ned's own
proc bindSocket*(s: SocketHandle, a: ptr SockAddr, n: SockLen): cint = winlean.bindSocket(sockOf(s), a, n)
# makes the socket of a descriptor of ned's own listen
proc listen*(s: SocketHandle, backlog: cint): cint = winlean.listen(sockOf(s), backlog)
proc accept*(s: SocketHandle, a: ptr SockAddr, n: ptr SockLen): SocketHandle =
  ## accepts a connection and gives it a descriptor of ned's own; -1 on failure
  let r = winlean.accept(sockOf(s), a, n)
  if r == INVALID_SOCKET: return SocketHandle(-1)
  SocketHandle(virtAdd(VirtFd(kind: vkSock, sock: r)))
# shuts down the socket of a descriptor of ned's own
proc shutdown*(s: SocketHandle, how: cint): cint = winlean.shutdown(sockOf(s), how)
# a port number in network byte order: the two bytes swapped
proc htons*(x: uint16): uint16 = (x shr 8) or (x shl 8)

# ── poll ──

proc pollImpl(fds: ptr TPollfd, n: Tnfds, timeout: cint): cint =
  ## each descriptor asked every few ms until one is ready or the time is up: a pipe (bytes waiting, or its other
  ## end closed), the console (its input, a resize), a socket (select), a file (always)
  winInit()
  let arr = cast[ptr UncheckedArray[TPollfd]](fds)
  let t0 = getMonoTime()
  var hasCon = false
  while true:
    var ready = 0
    for i in 0 ..< int(n):
      # the descriptor being looked at in the loop
      template p: untyped = arr[i]
      p.revents = 0
      let fd = p.fd
      if fd < 0: continue
      var v: VirtFd
      if virtGet(fd, v) and v.kind == vkPty:
        var avail: uint32
        if PeekNamedPipe(v.outR, nil, 0, nil, addr avail, nil) == 0: p.revents = POLLHUP
        elif avail > 0: p.revents = POLLIN
        if (p.events and POLLOUT) != 0: p.revents = p.revents or POLLOUT
      elif v.kind == vkSock and fd >= VirtBase:
        var rs, ws: TFdSet
        FD_ZERO(rs)
        FD_ZERO(ws)
        FD_SET(v.sock, rs)
        FD_SET(v.sock, ws)
        var tv = Timeval(tv_sec: 0, tv_usec: 0)
        if select(0, addr rs, addr ws, nil, addr tv) > 0:
          if (p.events and POLLIN) != 0 and FD_ISSET(v.sock, rs) != 0: p.revents = POLLIN
          if (p.events and POLLOUT) != 0 and FD_ISSET(v.sock, ws) != 0: p.revents = p.revents or POLLOUT
      elif fd == 0 and conOk():
        hasCon = true
        checkResize()
        conDrain()
        if conPendingLen() > 0: p.revents = POLLIN
      else:
        let h = osHandle(fd)
        if h == Handle(-1): p.revents = POLLNVAL
        else:
          case GetFileType(h)
          of FILE_TYPE_PIPE:
            if (p.events and POLLIN) != 0:
              var avail: uint32
              if PeekNamedPipe(h, nil, 0, nil, addr avail, nil) == 0: p.revents = POLLHUP
              elif avail > 0: p.revents = POLLIN
            if (p.events and POLLOUT) != 0: p.revents = p.revents or POLLOUT
          of FILE_TYPE_CHAR:
            if (p.events and POLLOUT) != 0: p.revents = POLLOUT
          else: p.revents = (p.events and (POLLIN or POLLOUT))
      if p.revents != 0: inc ready
    if ready > 0: return cint(ready)
    let spent = int((getMonoTime() - t0).inMilliseconds)
    if timeout >= 0 and spent >= timeout: return 0
    let slice = if timeout < 0: 10 else: max(1, min(10, timeout - spent))
    if hasCon: discard waitForSingleObject(conInH(), int32(slice))     # (a key ends the wait at once)
    else: winlean.sleep(int32(slice))

# ── the calls, as POSIX declares them (no side effects the compiler would see: ned calls them from funcs) ──

proc read*(fd: cint, buf: pointer, n: int): int =
  ## POSIX's read, for `readImpl` (declared so the compiler sees no side effects)
  {.cast(noSideEffect), cast(gcsafe).}: result = readImpl(fd, buf, n)
proc write*(fd: cint, buf: pointer, n: int): int =
  ## POSIX's write, for `writeImpl`
  {.cast(noSideEffect), cast(gcsafe).}: result = writeImpl(fd, buf, n)
proc close*(fd: cint): cint =
  ## POSIX's close, for `closeImpl`
  {.cast(noSideEffect), cast(gcsafe).}: result = closeImpl(fd)
proc kill*(pid: Pid, sig: cint): cint =
  ## POSIX's kill, for `killImpl`
  {.cast(noSideEffect), cast(gcsafe).}: result = killImpl(pid, sig)
proc poll*(fds: ptr TPollfd, n: Tnfds, timeout: cint): cint =
  ## POSIX's poll, for `pollImpl`
  {.cast(noSideEffect), cast(gcsafe).}: result = pollImpl(fds, n, timeout)
proc waitpid*(pid: Pid, status: var cint, options: cint): Pid =
  ## POSIX's waitpid, for `waitpidImpl`
  {.cast(noSideEffect), cast(gcsafe).}: result = waitpidImpl(pid, status, options)
# closes a socket (a descriptor of ned's own) like any other descriptor
proc close*(s: SocketHandle): cint = close(cint(s))

# ── processes ──

proc jobFor(process, thread: Handle): Handle =
  ## a job for a process started suspended (what it starts goes in it too), then the process let run: stopped as one
  ## (kill), and stopped with ned when ned ends (kill on close)
  result = CreateJobObjectW(nil, nil)
  if result != 0:
    var lim: JobExtendedLimits
    lim.basic.limitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
    discard SetInformationJobObject(result, JobObjectExtendedLimitInformation, addr lim, uint32(sizeof(lim)))
    if AssignProcessToJobObject(result, process) == 0:
      discard closeHandle(result)
      result = 0
  discard resumeThread(thread)

proc winQuote(a: string): string =
  ## one argument on a Windows command line (as CommandLineToArgvW and the C runtime split it)
  if a.len > 0 and not a.contains({' ', '\t', '"'}): return a
  result = "\""
  var bs = 0
  for c in a:
    if c == '\\': inc bs
    elif c == '"':
      result.add repeat('\\', bs * 2 + 1)
      result.add '"'
      bs = 0
    else:
      if bs > 0: result.add repeat('\\', bs)
      bs = 0
      result.add c
  if bs > 0: result.add repeat('\\', bs * 2)
  result.add '"'

proc winShell*(): seq[string] =
  ## the POSIX shell ned's commands are written for: Git for Windows' sh — else cmd.exe
  for c in [findExe("sh"), getEnv("ProgramFiles") / "Git" / "bin" / "sh.exe",
            getEnv("ProgramFiles") / "Git" / "usr" / "bin" / "sh.exe",
            getEnv("LOCALAPPDATA") / "Programs" / "Git" / "bin" / "sh.exe"]:
    if c.len > 0 and fileExists(c): return @[c, "-c"]
  @[getEnv("ComSpec", "cmd.exe"), "/d", "/s", "/c"]

# true when the program is cmd.exe, by its file name
proc isCmdExe*(p: string): bool = extractFilename(p).toLowerAscii in ["cmd.exe", "cmd"]

proc winCmdLine*(argv: seq[string]): string =
  ## argv as one Windows command line; cmd.exe's /c command as it is, in quotes (cmd.exe has its own quoting: /s
  ## takes the outer quotes off and runs what is inside)
  var cAt = -1
  if argv.len > 0 and isCmdExe(argv[0]):
    for i in 1 ..< argv.len:
      if argv[i].toLowerAscii == "/c":
        cAt = i
        break
  let upto = if cAt >= 0: cAt + 1 else: argv.len
  for i in 0 ..< upto:
    if i > 0: result.add ' '
    result.add winQuote(argv[i])
  if cAt >= 0 and cAt + 1 < argv.len:
    result.add " \""
    for i in cAt + 1 ..< argv.len:
      if i > cAt + 1: result.add ' '
      result.add argv[i]
    result.add '"'

proc winResolve*(argv: seq[string]): seq[string] =
  ## what Windows can start: `sh -c cmd` (ned's own commands are written for a POSIX shell) through Git for
  ## Windows' sh, else cmd.exe; a program found on PATH with its extension (.exe, .cmd, .bat); .cmd and .bat
  ## through cmd.exe
  result = argv
  if argv.len == 0: return
  let a0 = argv[0].replace('\\', '/')
  if a0 in ["sh", "bash", "/bin/sh", "/bin/bash"] and argv.len >= 3 and argv[1] == "-c":
    let sh = winShell()
    if isCmdExe(sh[0]): return sh & @[argv[2]]
    return @[sh[0], "-c"] & argv[2 .. ^1]
  if a0 == "/usr/bin/env" and argv.len >= 2: return winResolve(argv[1 .. ^1])
  if not fileExists(argv[0]):
    let name = extractFilename(a0)
    var found = ""
    if name.contains('.'): found = findExe(name, extensions = [""])
    if found.len == 0:
      for ext in ["exe", "cmd", "bat", "com"]:
        found = findExe(name, extensions = [ext])
        if found.len > 0: break
    if found.len > 0: result[0] = found
  let lo = result[0].toLowerAscii
  if lo.endsWith(".cmd") or lo.endsWith(".bat"):
    result = @[getEnv("ComSpec", "cmd.exe"), "/d", "/s", "/c", winCmdLine(result)]

proc nulHandle(write: bool): Handle =
  ## a handle to the NUL device that a started process inherits: for its output (`write`) or its input
  var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)), bInheritHandle: 1)
  createFileW(newWideCString("NUL"), (if write: GENERIC_WRITE else: GENERIC_READ), FILE_SHARE_READ or FILE_SHARE_WRITE,
              addr sa, OPEN_EXISTING, 0, 0)

proc winSpawn*(argv: seq[string], cwd: string, stdinPipe: bool, errMode: int, niceness = 0,
               env: seq[(string, string)] = @[]): tuple[pid: Pid, inFd, outFd, errFd: cint] =
  ## argv started with its output on a pipe (errMode 0: stderr there too, 1: its own pipe, 2: nowhere) and its input
  ## on a pipe or nothing; raises OSError when it cannot start
  winInit()
  result = (Pid(-1), -1.cint, -1.cint, -1.cint)
  var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)), bInheritHandle: 1)
  var outR, outW, inR, inW, errR, errW: Handle
  if createPipe(outR, outW, sa, 65536) == 0: raise newException(OSError, "CreatePipe failed")
  discard SetHandleInformation(outR, HANDLE_FLAG_INHERIT, 0)
  if stdinPipe:
    if createPipe(inR, inW, sa, 65536) == 0: raise newException(OSError, "CreatePipe failed")
    discard SetHandleInformation(inW, HANDLE_FLAG_INHERIT, 0)
  else: inR = nulHandle(false)
  case errMode
  of 1:
    if createPipe(errR, errW, sa, 65536) == 0: raise newException(OSError, "CreatePipe failed")
    discard SetHandleInformation(errR, HANDLE_FLAG_INHERIT, 0)
  of 2: errW = nulHandle(true)
  else: errW = outW
  var si: STARTUPINFO
  si.cb = int32(sizeof(si))
  si.dwFlags = STARTF_USESTDHANDLES
  si.hStdInput = inR
  si.hStdOutput = outW
  si.hStdError = errW
  var pi: PROCESS_INFORMATION
  let argv = winResolve(argv)
  let line = winCmdLine(argv)
  var envObj = newWideCString("")
  var envBlock: WideCString = nil
  if env.len > 0:
    var e = ""
    for k, v in envPairs():
      var replaced = false
      for (k2, _) in env:
        if cmpIgnoreCase(k, k2) == 0: replaced = true
      if not replaced: e.add k & "=" & v & "\0"
    for (k, v) in env: e.add k & "=" & v & "\0"
    e.add "\0"
    envObj = newWideCString(e)
    envBlock = envObj.toWideCString
  let wline = newWideCString(line)
  let wcwdObj = newWideCString(cwd)
  let wcwd: WideCString = if cwd.len > 0: wcwdObj.toWideCString else: nil
  let flags = CREATE_NO_WINDOW or CREATE_NEW_PROCESS_GROUP or CREATE_UNICODE_ENVIRONMENT or CREATE_SUSPENDED or
              (if niceness >= 10: IDLE_PRIORITY_CLASS elif niceness > 0: BELOW_NORMAL_PRIORITY_CLASS else: 0)
  let ok = createProcessW(nil, wline, nil, nil, 1, flags, envBlock,
                          wcwd, si, pi)
  discard closeHandle(outW)
  if stdinPipe or inR != 0: discard closeHandle(inR)
  if errMode == 1: discard closeHandle(errW)
  elif errMode == 2: discard closeHandle(errW)
  if ok == 0:
    discard closeHandle(outR)
    if stdinPipe: discard closeHandle(inW)
    if errMode == 1: discard closeHandle(errR)
    raise newException(OSError, "cannot start " & (if argv.len > 0: argv[0] else: "") & " (error " &
                       $getLastError() & ")")
  let job = jobFor(pi.hProcess, pi.hThread)
  discard closeHandle(pi.hThread)
  let pid = Pid(pi.dwProcessId)
  procAdd(pid, pi.hProcess, job)
  result.pid = pid
  result.outFd = c_openosfhandle(int(outR), O_RDONLY or O_BINARY)
  if stdinPipe: result.inFd = c_openosfhandle(int(inW), O_WRONLY or O_BINARY)
  if errMode == 1: result.errFd = c_openosfhandle(int(errR), O_RDONLY or O_BINARY)

proc winPtySpawn*(argv: seq[string], cwd: string, cols, rows: int, env: seq[(string, string)] = @[]):
                  tuple[pid: Pid, fd: cint, err: string] =
  ## argv in a pseudo-console (ConPTY) of cols × rows: one descriptor of ned's for it — written to, read from, its
  ## size changed with ioctl TIOCSWINSZ, closed with the pseudo-console
  winInit()
  result = (Pid(-1), -1.cint, "")
  if not conptyLoad():
    result.err = "this Windows has no pseudo-console (Windows 10 1809 or later)"
    return
  var sa = SECURITY_ATTRIBUTES(nLength: int32(sizeof(SECURITY_ATTRIBUTES)), bInheritHandle: 0)
  var inR, inW, outR, outW: Handle
  if createPipe(inR, inW, sa, 0) == 0 or createPipe(outR, outW, sa, 0) == 0:
    result.err = "CreatePipe failed"
    return
  var pc: Handle
  if createPseudo(Coord(X: int16(cols), Y: int16(rows)), inR, outW, 0, addr pc) != 0:
    result.err = "CreatePseudoConsole failed"
    return
  discard closeHandle(inR)
  discard closeHandle(outW)
  var size: csize_t
  discard InitializeProcThreadAttributeList(nil, 1, 0, addr size)
  var attrs = newSeq[byte](int(size))
  if InitializeProcThreadAttributeList(addr attrs[0], 1, 0, addr size) == 0:
    result.err = "InitializeProcThreadAttributeList failed"
    return
  if UpdateProcThreadAttribute(addr attrs[0], 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, cast[pointer](pc),
                               csize_t(sizeof(Handle)), nil, nil) == 0:
    result.err = "UpdateProcThreadAttribute failed"
    return
  var six: StartupInfoExW
  six.StartupInfo.cb = int32(sizeof(six))
  six.lpAttributeList = addr attrs[0]
  var pi: PROCESS_INFORMATION
  let argv = winResolve(argv)
  let line = winCmdLine(argv)
  var e = ""
  for k, v in envPairs():
    var replaced = false
    for (k2, _) in env:
      if cmpIgnoreCase(k, k2) == 0: replaced = true
    if not replaced: e.add k & "=" & v & "\0"
  for (k, v) in env: e.add k & "=" & v & "\0"
  e.add "\0"
  let envObj = newWideCString(e)
  let wline = newWideCString(line)
  let wcwdObj = newWideCString(cwd)
  let wcwd: WideCString = if cwd.len > 0: wcwdObj.toWideCString else: nil
  let ok = createProcessW(nil, wline, nil, nil, 0, EXTENDED_STARTUPINFO_PRESENT or CREATE_UNICODE_ENVIRONMENT or
                          CREATE_SUSPENDED,
                          envObj.toWideCString, wcwd, cast[ptr STARTUPINFO](addr six)[], pi)
  DeleteProcThreadAttributeList(addr attrs[0])
  if ok == 0:
    closePseudo(pc)
    discard closeHandle(inW)
    discard closeHandle(outR)
    result.err = "cannot start " & (if argv.len > 0: argv[0] else: "") & " (error " & $getLastError() & ")"
    return
  let job = jobFor(pi.hProcess, pi.hThread)
  discard closeHandle(pi.hThread)
  let pid = Pid(pi.dwProcessId)
  procAdd(pid, pi.hProcess, job)
  result = (pid, virtAdd(VirtFd(kind: vkPty, inW: inW, outR: outR, pc: pc, pid: pid)), "")

proc winRunArgv*(argv: seq[string], cwd: string): int =
  ## argv run in ned's own console (handed to it while it runs), waited for: its exit code (127: it did not start)
  winInit()
  let wline = newWideCString(winCmdLine(winResolve(argv)))
  let wcwdObj = newWideCString(cwd)
  let wcwd: WideCString = if cwd.len > 0: wcwdObj.toWideCString else: nil
  var si: STARTUPINFO
  si.cb = int32(sizeof(si))
  var pi: PROCESS_INFORMATION
  if createProcessW(nil, wline, nil, nil, 0, 0, nil, wcwd, si, pi) == 0: return 127
  discard closeHandle(pi.hThread)
  discard waitForSingleObject(pi.hProcess, -1)
  var code: int32
  discard getExitCodeProcess(pi.hProcess, code)
  discard closeHandle(pi.hProcess)
  int(code)

proc winRun*(cmd, cwd: string): int =
  ## a shell command run in ned's own console, waited for: its exit code
  winRunArgv(@["sh", "-c", cmd], cwd)

proc winMoveReplace*(a, b: string): bool =
  ## a over b, in one step (rename's semantics: Windows' rename fails when b is there)
  MoveFileExW(newWideCString(a), newWideCString(b), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) != 0

# ── the clipboard ──

proc winClipSet*(s: string): bool =
  ## puts the text on the Windows clipboard as Unicode text; false when the clipboard cannot be opened or memory cannot
  ## be had
  let w = newWideCString(s)
  let n = (w.len + 1) * 2
  if OpenClipboard(0) == 0: return false
  defer: discard CloseClipboard()
  discard EmptyClipboard()
  let h = GlobalAlloc(GMEM_MOVEABLE, csize_t(n))
  if h == 0: return false
  let p = GlobalLock(h)
  if p == nil: return false
  copyMem(p, cast[pointer](w.toWideCString), n)
  discard GlobalUnlock(h)
  SetClipboardData(CF_UNICODETEXT, h) != 0

proc winClipGet*(): string =
  ## the Unicode text on the Windows clipboard as UTF-8 with \n line ends, or "" when there is none
  if OpenClipboard(0) == 0: return ""
  defer: discard CloseClipboard()
  let h = GetClipboardData(CF_UNICODETEXT)
  if h == 0: return ""
  let p = GlobalLock(h)
  if p == nil: return ""
  result = $cast[WideCString](p)
  discard GlobalUnlock(h)
  result = result.replace("\r\n", "\n")

# ── raw mode: the console's modes ──

proc tcGetAttr*(fd: cint, t: ptr Termios): cint =
  ## reads the console's input and output modes and code pages into the `Termios` (to put back later) and gives it the
  ## flags of a terminal not in raw mode; -1 when stdin is not a console
  winInit()
  if not conInputOk: return -1
  discard GetConsoleMode(conIn, addr t.inMode)
  discard GetConsoleMode(conOut, addr t.outMode)
  t.inCP = GetConsoleCP()
  t.outCP = GetConsoleOutputCP()
  t.c_lflag = ECHO or ICANON or ISIG or IEXTEN
  t.c_iflag = ICRNL or IXON
  t.c_oflag = OPOST
  t.c_cc[VERASE] = '\x7f'
  0

proc tcSetAttr*(fd: cint, act: cint, t: ptr Termios): cint =
  ## raw (ICANON off): virtual-terminal input and output, no line editing, no echo, Ctrl+C a key, UTF-8 —
  ## else the modes as they were
  winInit()
  if not conInputOk: return -1
  if (t.c_lflag and ICANON) == 0:
    let inM = (t.inMode and not (ENABLE_ECHO_INPUT or ENABLE_LINE_INPUT or ENABLE_PROCESSED_INPUT or
                                 ENABLE_QUICK_EDIT_MODE or ENABLE_MOUSE_INPUT)) or
              ENABLE_VIRTUAL_TERMINAL_INPUT or ENABLE_WINDOW_INPUT or ENABLE_EXTENDED_FLAGS
    discard SetConsoleMode(conIn, inM)
    discard SetConsoleMode(conOut, t.outMode or ENABLE_PROCESSED_OUTPUT or ENABLE_VIRTUAL_TERMINAL_PROCESSING or
                                   DISABLE_NEWLINE_AUTO_RETURN)
    discard SetConsoleCP(CP_UTF8)
    discard SetConsoleOutputCP(CP_UTF8)
    lastCols = -1
    checkResize()
  else:
    discard SetConsoleMode(conIn, t.inMode)
    discard SetConsoleMode(conOut, t.outMode)
    if t.inCP != 0: discard SetConsoleCP(t.inCP)
    if t.outCP != 0: discard SetConsoleOutputCP(t.outCP)
  0

# ── what the rest asks for and Windows does not have ──

# always fails: Windows has no mmap here (its one caller, nxInMemory, is compiled for Linux and Android only)
proc mmap*(a: pointer, len: int, prot, flags, fd: cint, off: Off): pointer = MAP_FAILED
# does nothing: `mmap` never maps anything
proc munmap*(a: pointer, len: int): cint = 0
# does nothing: a hint to read a file ahead has no use here
proc posix_fadvise*(fd: cint, off, len: Off, advice: cint): cint = 0
