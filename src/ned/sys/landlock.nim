## Landlock (Linux 5.13 and newer): a process says what it — and every program it starts — may do with files and the
## network, and the kernel holds it to that for good. ned runs a plugin's process this way (and any command, with
## `ned --sandbox CMD…`): it reads the project and what it needs to run (the system's folders, Nim, its own files),
## writes only where it is allowed (the project, its data folder), lists folders anywhere, and uses the network only
## when allowed. Raw system calls, no library. Where the kernel has no Landlock — an older Linux, Android's app
## sandbox, macOS, Windows — nothing is limited, and the caller is told.

import std/[os, strutils]
import ../core/secrets
when not defined(windows): import std/posix

type SandboxPolicy* = object
  ## what a sandboxed process may do — the rest is refused by the kernel
  read*: seq[string]          # files and folders it may read (and run programs from)
  write*: seq[string]         # … and change: write, make, remove, rename
  listAll*: bool              # folder listings everywhere (only the names: not what the files hold)
  files*: bool                # files not limited at all (the plugin may change files)
  net*: bool                  # TCP: connect and listen anywhere
  connect*: seq[int]          # … or connect to these ports only
  keepEnv*: bool              # keep the environment's secrets (API keys, tokens): left out otherwise

const
  LlCreateVersion = 1'u32               # LANDLOCK_CREATE_RULESET_VERSION
  LlRulePathBeneath = 1'u32
  LlRuleNetPort = 2'u32
  LlExecute = 1'u64 shl 0
  LlWriteFile = 1'u64 shl 1
  LlReadFile = 1'u64 shl 2
  LlReadDir = 1'u64 shl 3
  LlRemoveDir = 1'u64 shl 4
  LlRemoveFile = 1'u64 shl 5
  LlMakeChar = 1'u64 shl 6
  LlMakeDir = 1'u64 shl 7
  LlMakeReg = 1'u64 shl 8
  LlMakeSock = 1'u64 shl 9
  LlMakeFifo = 1'u64 shl 10
  LlMakeBlock = 1'u64 shl 11
  LlMakeSym = 1'u64 shl 12
  LlRefer = 1'u64 shl 13                # ABI 2
  LlTruncate = 1'u64 shl 14             # ABI 3
  LlIoctlDev = 1'u64 shl 15             # ABI 5
  LlNetBind = 1'u64 shl 0               # ABI 4
  LlNetConnect = 1'u64 shl 1
  LlScopeAbstractUnix = 1'u64 shl 0     # ABI 6
  LlScopeSignal = 1'u64 shl 1
  LlFileOnly = LlExecute or LlWriteFile or LlReadFile or LlTruncate or LlIoctlDev   # (rights a file can have)
  LlReadRights = LlExecute or LlReadFile or LlReadDir
  LlDevices = ["/dev/null", "/dev/zero", "/dev/full", "/dev/random", "/dev/urandom", "/dev/tty", "/dev/ptmx",
               "/dev/pts"]

var llAbiCache = -1

when defined(linux) or defined(android):
  type
    LlRulesetAttr = object
      handledFs, handledNet, scoped: uint64
    LlPathBeneath {.packed.} = object
      allowed: uint64
      parentFd: int32
    LlNetPortAttr = object
      allowed, port: uint64

  proc llSyscall(n: clong): clong {.importc: "syscall", header: "<unistd.h>", varargs.}
  proc llPrctl(option: cint): cint {.importc: "prctl", header: "<sys/prctl.h>", varargs.}
  const
    SysCreateRuleset = 444.clong        # (the same number on every architecture: added after they were unified)
    SysAddRule = 445.clong
    SysRestrictSelf = 446.clong
    PrSetNoNewPrivs = 38.cint

  proc llProbe(): int =
    let r = llSyscall(SysCreateRuleset, nil, 0.csize_t, LlCreateVersion.clong)
    if r < 0: 0 else: r.int

proc landlockAbi*(): int =
  ## the version of Landlock this kernel has (1, 2, … 7 …), 0 when it has none — or when $NED_NO_LANDLOCK is set
  if getEnv("NED_NO_LANDLOCK").len > 0: return 0
  if llAbiCache >= 0: return llAbiCache
  llAbiCache = 0
  when defined(android):
    # (Android's app sandbox may kill a process for a system call it does not know, rather than refuse it: the
    #  question goes to a child first)
    let pid = fork()
    if pid == 0:
      discard signal(SIGSYS, SIG_DFL)
      exitnow(min(llProbe(), 100).cint)
    if pid > 0:
      var st: cint
      if waitpid(pid, st, 0) == pid and WIFEXITED(st) and WEXITSTATUS(st) > 0: llAbiCache = llProbe()
  elif defined(linux):
    llAbiCache = llProbe()
  llAbiCache

func llFsHandled(abi: int): uint64 =
  result = (1'u64 shl 13) - 1                 # ABI 1: execute … make symlinks
  if abi >= 2: result = result or LlRefer
  if abi >= 3: result = result or LlTruncate
  if abi >= 5: result = result or LlIoctlDev

proc sandboxToolReads*(): seq[string] =
  ## what programs need to read to run, beyond the system's folders: Nim (its standard library), nimble's packages,
  ## your Nim settings
  let home = getHomeDir()
  var nim = findExe("nim")
  if nim.len > 0:
    try: nim = expandFilename(nim)
    except CatchableError: discard
    result.add parentDir(parentDir(nim))      # (…/nim-2.2.4/bin/nim: the folder with lib/ and config/)
  for d in [getEnv("NIMBLE_DIR"), home / ".nimble", home / ".choosenim", home / ".config" / "nim",
            getEnv("XDG_CONFIG_HOME", home / ".config") / "nim"]:
    if d.len > 0 and d notin result: result.add d

proc sandboxSystemReads*(): seq[string] =
  ## the system's folders, readable in every sandbox: programs and their libraries, settings in /etc, /proc …
  ## (not /tmp, /home, /root or /run: other programs' files and your own)
  for d in ["/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64", "/libx32", "/etc", "/opt", "/nix", "/gnu", "/snap",
            "/proc", "/sys", "/dev", "/run/current-system", "/run/systemd/resolve", "/system", "/apex", "/vendor",
            "/linkerconfig", "/odm", "/product", "/system_ext"]:
    if dirExists(d): result.add d
  # Termux: its prefix, except its tmp (where ned keeps its private files)
  let pre = getEnv("PREFIX")
  if pre.len > 0 and "com.termux" in pre and dirExists(pre):
    try:
      for kind, p in walkDir(pre):
        if extractFilename(p) != "tmp": result.add p
    except CatchableError: discard

when defined(linux) or defined(android):
  proc llAddPath(rfd: cint, path: string, rights, handled: uint64): bool =
    ## a file or folder (and everything below it) with these rights; false when it is not there
    let fd = posix.open(path.cstring, O_CLOEXEC or 0o10000000)       # (O_PATH)
    if fd < 0: return false
    var st: Stat
    var r = rights and handled
    if fstat(fd, st) == 0 and not S_ISDIR(st.st_mode): r = r and LlFileOnly
    var attr = LlPathBeneath(allowed: r, parentFd: fd.int32)
    result = r == 0 or llSyscall(SysAddRule, rfd.clong, LlRulePathBeneath.clong, addr attr, 0.clong) == 0
    discard posix.close(fd)

proc landlockApply*(p: SandboxPolicy): string =
  ## limits this process, and everything it starts from now on, to the policy: "" done, or why not (no Landlock
  ## here, or the kernel refused) — then nothing is limited
  when defined(linux) or defined(android):
    let abi = landlockAbi()
    if abi <= 0: return "this system has no Landlock (Linux 5.13 or newer, with Landlock turned on)"
    let fsAll = llFsHandled(abi)
    var attr = LlRulesetAttr()
    if not p.files: attr.handledFs = fsAll
    if abi >= 4 and not p.net: attr.handledNet = LlNetBind or LlNetConnect
    if abi >= 6: attr.scoped = LlScopeAbstractUnix or LlScopeSignal
    if attr.handledFs == 0 and attr.handledNet == 0 and attr.scoped == 0: return ""
    let rfd = llSyscall(SysCreateRuleset, addr attr, csize_t(sizeof(attr)), 0.clong).cint
    if rfd < 0: return "Landlock refused the rules (" & $strerror(errno) & ")"
    defer: discard posix.close(rfd)
    if not p.files:
      if p.listAll: discard llAddPath(rfd, "/", LlReadDir, fsAll)
      for d in sandboxSystemReads() & p.read: discard llAddPath(rfd, d, LlReadRights, fsAll)
      for d in LlDevices: discard llAddPath(rfd, d, LlFileOnly, fsAll)
      for d in p.write:
        if not llAddPath(rfd, d, fsAll, fsAll) and dirExists(d):
          return "Landlock refused " & d & " (" & $strerror(errno) & ")"
    if attr.handledNet != 0:
      for port in p.connect:
        var na = LlNetPortAttr(allowed: LlNetConnect, port: port.uint64)
        if llSyscall(SysAddRule, rfd.clong, LlRuleNetPort.clong, addr na, 0.clong) != 0:
          return "Landlock refused port " & $port & " (" & $strerror(errno) & ")"
    if llPrctl(PrSetNoNewPrivs, 1.culong, 0.culong, 0.culong, 0.culong) != 0:
      return "could not set no_new_privs (" & $strerror(errno) & ")"
    if llSyscall(SysRestrictSelf, rfd.clong, 0.clong) != 0:
      return "Landlock could not limit this process (" & $strerror(errno) & ")"
    ""
  else:
    "Landlock is Linux's: there is none on this system"

proc sandboxEnv*(keepSecrets: bool): seq[string] =
  ## the environment a sandboxed program gets: ned's remote-control socket left out (it could tell ned to run
  ## anything), and — unless kept — every variable that holds a secret by its name or its value
  for k, v in envPairs():
    if k == "NED_SOCKET": continue
    if not keepSecrets and (secretEnvName(k) or redactSecrets(v) != v): continue
    result.add k & "=" & v

proc sandboxArgs*(p: SandboxPolicy): seq[string] =
  ## the options of `ned --sandbox` for a policy (the project not added: it is in p.write when it is wanted)
  result.add "--no-project"
  for d in p.read: result.add ["--read", d]
  for d in p.write: result.add ["--write", d]
  if p.files: result.add "--files"
  if p.net: result.add "--net"
  for port in p.connect: result.add ["--connect", $port]
  if p.keepEnv: result.add "--keep-env"
  if not p.listAll: result.add "--no-list"

const SandboxUsage* = """ned --sandbox [OPTION…] [--] COMMAND [ARGUMENT…]
  Runs COMMAND so that it — and every program it starts — can read the current folder, the system's folders and
  Nim, change files only in the current folder, see folder listings anywhere, and not use the network (Linux's
  Landlock; elsewhere the command runs without limits, and this is said). Variables of the environment that hold
  secrets (API keys, tokens, passwords) are left out.
  --read PATH     may read PATH too (and run programs in it)
  --write PATH    may change files in PATH too
  --no-project    the current folder is not readable or writable (only what --read and --write give)
  --files         files are not limited (the network still is)
  --net           may use the network
  --connect PORT  may connect to this TCP port (Linux 6.7 or newer)
  --keep-env      keep the environment's secrets
  --no-list       no folder listings outside what it may read
  --require       refuse to run (exit status 126) where Landlock is missing
  --quiet         say nothing when Landlock is missing
  --explain       say what is allowed before running
  Example: ned --sandbox --write ~/.cache/nim nim c -r tool.nim"""

proc sandboxMain*(args: seq[string]): int =
  ## ned --sandbox [options] [--] CMD [ARGS…]: runs CMD (in place of this process) under the policy
  var p = SandboxPolicy(listAll: true)
  var project = true
  var require, quiet, explain = false
  var i = 0
  template val(): string =
    if i + 1 >= args.len:
      stderr.writeLine("ned --sandbox: " & args[i] & " needs a value\n" & SandboxUsage)
      return 2
    inc i
    args[i]
  while i < args.len:
    let a = args[i]
    if a == "--":
      inc i
      break
    if not a.startsWith("-"): break
    case a
    of "--read": p.read.add absolutePath(expandTilde(val()))
    of "--write": p.write.add absolutePath(expandTilde(val()))
    of "--no-project": project = false
    of "--files": p.files = true
    of "--net": p.net = true
    of "--connect":
      let v = val()
      try: p.connect.add parseInt(v)
      except ValueError:
        stderr.writeLine("ned --sandbox: --connect needs a port number, not " & v)
        return 2
    of "--keep-env": p.keepEnv = true
    of "--no-list": p.listAll = false
    of "--require": require = true
    of "--quiet": quiet = true
    of "--explain": explain = true
    of "-h", "--help":
      echo SandboxUsage
      return 0
    else:
      stderr.writeLine("ned --sandbox: unknown option " & a & "\n" & SandboxUsage)
      return 2
    inc i
  if i >= args.len:
    stderr.writeLine(SandboxUsage)
    return 2
  let cmd = args[i .. ^1]
  if project: p.write.add getCurrentDir()
  for d in sandboxToolReads():
    if d notin p.read: p.read.add d
  let env = sandboxEnv(p.keepEnv)
  if explain:
    stderr.writeLine("ned --sandbox: Landlock " & (if landlockAbi() > 0: "version " & $landlockAbi() else: "missing"))
    if p.files: stderr.writeLine("  files: not limited")
    else:
      stderr.writeLine("  read:  " & (sandboxSystemReads() & p.read).join(" "))
      stderr.writeLine("  write: " & (if p.write.len > 0: p.write.join(" ") else: "nothing"))
      stderr.writeLine("  lists: " & (if p.listAll: "every folder" else: "only what it may read"))
    stderr.writeLine("  network: " & (if p.net: "allowed" elif p.connect.len > 0: "ports " & $p.connect
                                      elif landlockAbi() >= 4: "none" else: "not limited (Linux 6.7 or newer)"))
  let why = landlockApply(p)
  if why.len > 0:
    if require:
      stderr.writeLine("ned --sandbox: " & why & " — not run")
      return 126
    if not quiet: stderr.writeLine("ned --sandbox: " & why & " — " & cmd[0] & " runs without limits")
  when defined(windows):
    return execShellCmd(quoteShellCommand(cmd))
  else:
    let argv = allocCStringArray(cmd)
    let envp = allocCStringArray(env)
    var path = cmd[0]
    if '/' notin path:
      # (as a shell looks for it: the first in $PATH that may be run — findExe takes any file of the name)
      for d in getEnv("PATH").split(':'):
        let f = (if d.len == 0: "." else: d) / path
        if fileExists(f) and access(f.cstring, X_OK) == 0:
          path = f
          break
    discard execve(path.cstring, argv, envp)
    stderr.writeLine("ned --sandbox: cannot run " & cmd[0] & " (" & $strerror(errno) & ")")
    127
