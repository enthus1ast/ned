# ned's Landlock sandbox (src/ned/sys/landlock.nim): a child limited to one folder tries to write outside it, read
# a file it was not given, connect to the network and signal its parent — and is refused by the kernel; what it
# was given still works; `ned --sandbox`'s own code (sandboxMain) runs a shell under the same limits; with no
# Landlock (NED_NO_LANDLOCK) nothing is limited and the reason is given. Linux only: elsewhere the tests say so.

import std/[os, strutils, unittest]
when not defined(windows): import std/[posix, nativesockets]
import ../../src/ned/sys/landlock

let root = getTempDir() / ("ned-tlandlock-" & $getCurrentProcessId())
let inside = root / "project"
let outside = root / "elsewhere"
createDir(inside)
createDir(outside)
writeFile(outside / "secret.txt", "not for the sandbox")
writeFile(inside / "mine.txt", "the project's")

when defined(linux) or defined(android):
  proc inChild(body: proc(): int): int =
    ## runs body in a child process (the sandbox lasts for good: never in the test's own process) — its exit code
    let pid = fork()
    if pid == 0:
      var code = 99
      try: code = body()
      except CatchableError: code = 98
      exitnow(code.cint)
    var st: cint
    discard waitpid(pid, st, 0)
    if WIFEXITED(st): WEXITSTATUS(st).int else: 200 + WTERMSIG(st).int

  proc canWrite(p: string): bool =
    try:
      writeFile(p, "x")
      true
    except CatchableError: false

  proc canRead(p: string): bool =
    try:
      discard readFile(p)
      true
    except CatchableError: false

  proc canConnect(port: int): bool =
    let s = createNativeSocket(nativesockets.AF_INET, nativesockets.SOCK_STREAM, nativesockets.IPPROTO_TCP)
    var a: Sockaddr_in
    a.sin_family = TSa_Family(posix.AF_INET)
    a.sin_port = nativesockets.htons(port.uint16)
    a.sin_addr.s_addr = nativesockets.htonl(0x7f000001'u32)
    result = posix.connect(s, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) == 0
    s.close()

  proc listener(): (SocketHandle, int) =
    ## a TCP socket listening on 127.0.0.1 (a port the kernel picks)
    let s = createNativeSocket(nativesockets.AF_INET, nativesockets.SOCK_STREAM, nativesockets.IPPROTO_TCP)
    var a: Sockaddr_in
    a.sin_family = TSa_Family(posix.AF_INET)
    a.sin_addr.s_addr = nativesockets.htonl(0x7f000001'u32)
    doAssert posix.bindSocket(s, cast[ptr SockAddr](addr a), SockLen(sizeof(a))) == 0
    doAssert posix.listen(s, 4) == 0
    var b: Sockaddr_in
    var l = SockLen(sizeof(b))
    doAssert getsockname(s, cast[ptr SockAddr](addr b), addr l) == 0
    (s, nativesockets.ntohs(b.sin_port).int)

let abi = landlockAbi()
if abi == 0: echo "  (this kernel has no Landlock: the sandbox tests check only that nothing is limited)"
else: echo "  (Landlock version ", abi, ")"

suite "Landlock":
  test "a child limited to the project: writes there, nowhere else":
    when defined(linux) or defined(android):
      if abi == 0: skip()
      else:
        let code = inChild(proc(): int =
          let why = landlockApply(SandboxPolicy(write: @[inside], listAll: true))
          if why.len > 0: return 10
          if not canWrite(inside / "new.txt"): return 11            # its own folder: yes
          if canWrite(outside / "new.txt"): return 12               # elsewhere: refused
          if canWrite(getTempDir() / "ned-tlandlock-escape"): return 13
          if canRead(outside / "secret.txt"): return 14             # a file it was not given: refused
          if not canRead(inside / "mine.txt"): return 15
          if not canRead("/etc/hostname") and fileExists("/etc/hostname"): return 16   # the system's: yes
          var listed = false
          for _ in walkDir(outside): listed = true                  # folder listings: yes (names only)
          if not listed: return 17
          try:
            removeFile(outside / "secret.txt")
            if not fileExists(outside / "secret.txt"): return 18
          except CatchableError: discard
          0)
        check code == 0
        check fileExists(inside / "new.txt")
        check not fileExists(outside / "new.txt")
        check fileExists(outside / "secret.txt")
    else: skip()

  test "the network: refused unless allowed (Landlock 4, Linux 6.7)":
    when defined(linux) or defined(android):
      if abi < 4: skip()
      else:
        let (srv, port) = listener()
        check inChild(proc(): int =
          if landlockApply(SandboxPolicy(write: @[inside])).len > 0: return 10
          if canConnect(port): 1 else: 0) == 0
        check inChild(proc(): int =
          if landlockApply(SandboxPolicy(write: @[inside], net: true)).len > 0: return 10
          if canConnect(port): 0 else: 1) == 0
        check inChild(proc(): int =
          if landlockApply(SandboxPolicy(write: @[inside], connect: @[port])).len > 0: return 10
          if canConnect(port): 0 else: 1) == 0
        srv.close()
    else: skip()

  test "signals to processes outside: refused (Landlock 6)":
    when defined(linux) or defined(android):
      if abi < 6: skip()
      else:
        let parent = getCurrentProcessId()
        check inChild(proc(): int =
          if landlockApply(SandboxPolicy(write: @[inside])).len > 0: return 10
          if posix.kill(Pid(parent), 0) == 0: 1 else: 0) == 0
    else: skip()

  test "files: not limited when the policy says so":
    when defined(linux) or defined(android):
      if abi == 0: skip()
      else:
        check inChild(proc(): int =
          if landlockApply(SandboxPolicy(files: true)).len > 0: return 10
          if canWrite(outside / "allowed.txt"): 0 else: 1) == 0
        check fileExists(outside / "allowed.txt")
    else: skip()

  test "ned --sandbox: a shell that writes outside the folder is refused":
    when defined(linux) or defined(android):
      if abi == 0 or findExe("sh").len == 0: skip()
      else:
        let code = inChild(proc(): int =
          setCurrentDir(inside)
          sandboxMain(@["--quiet", "--", "sh", "-c",
                        "echo in > here.txt && { echo out 2>/dev/null > " & quoteShell(outside / "sh.txt") & "; " &
                        "test $? -ne 0; } && ! cat " & quoteShell(outside / "secret.txt") & " 2>/dev/null"]))
        check code == 0
        check fileExists(inside / "here.txt")
        check not fileExists(outside / "sh.txt")
        # --write gives it more; a program that is not there: 127; no command: the usage, 2
        check inChild(proc(): int =
          setCurrentDir(inside)
          sandboxMain(@["--quiet", "--write", outside, "sh", "-c", "echo ok > " & quoteShell(outside / "w.txt")])) == 0
        check fileExists(outside / "w.txt")
        check inChild(proc(): int = sandboxMain(@["--quiet", "ned-no-such-program-x"])) == 127
        check inChild(proc(): int = sandboxMain(@["--quiet"])) == 2
    else: skip()

  test "ned --sandbox: the environment's secrets and ned's socket left out":
    when defined(linux) or defined(android):
      if findExe("sh").len == 0: skip()
      else:
        let envOut = inside / "env.txt"
        check inChild(proc(): int =
          putEnv("OPENAI_API_KEY", "sk-test-0123456789abcdefghijkl")
          putEnv("SOME_URL", "postgres://u:hunter22@db/x")
          putEnv("NED_SOCKET", "/tmp/x.sock")
          putEnv("NED_TLANDLOCK_PLAIN", "kept")
          setCurrentDir(inside)
          sandboxMain(@["--quiet", "sh", "-c", "env > " & quoteShell(envOut)])) == 0
        let env = readFile(envOut)
        check "NED_TLANDLOCK_PLAIN=kept" in env
        check "OPENAI_API_KEY" notin env and "hunter22" notin env and "NED_SOCKET" notin env
        check inChild(proc(): int =
          putEnv("OPENAI_API_KEY", "sk-test-0123456789abcdefghijkl")
          setCurrentDir(inside)
          sandboxMain(@["--quiet", "--keep-env", "sh", "-c", "env > " & quoteShell(envOut)])) == 0
        check "OPENAI_API_KEY" in readFile(envOut)
    else: skip()

  test "no Landlock (NED_NO_LANDLOCK): nothing is limited, and why is said":
    when defined(linux) or defined(android):
      check inChild(proc(): int =
        putEnv("NED_NO_LANDLOCK", "1")
        let why = landlockApply(SandboxPolicy(write: @[inside]))
        if "no Landlock" notin why: return 1
        if not canWrite(outside / "free.txt"): return 2
        if sandboxMain(@["--require", "true"]) != 126: return 3
        0) == 0
      check fileExists(outside / "free.txt")
    else:
      check landlockApply(SandboxPolicy()).len > 0

  test "sandboxArgs: the options that give the same policy":
    let a = sandboxArgs(SandboxPolicy(read: @["/r"], write: @["/w1", "/w2"], net: true, listAll: true))
    check a == @["--no-project", "--read", "/r", "--write", "/w1", "--write", "/w2", "--net"]
    check "--files" in sandboxArgs(SandboxPolicy(files: true, listAll: true))
    check "--no-list" in sandboxArgs(SandboxPolicy())

removeDir(root)
