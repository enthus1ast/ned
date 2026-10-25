# ── Run with memory checks: the program built with the compiler's address and undefined-behaviour checks
#    (AddressSanitizer, UndefinedBehaviorSanitizer; Nim with -d:useMalloc so they see its allocations) — or, where
#    the compiler has none, run under valgrind. What they find goes to Problems, on the line, with the calls that
#    led there ──

type
  MemFrame = object
    fn, path: string
    line, col: int
  MemFind = object
    sev: int
    msg: string                     # in plain words, then the tool's own line
    at: seq[MemFrame]               # where it happened (the calls, the innermost first)
    alloc: seq[MemFrame]            # where the memory was made (an overflow, a leak, a use after free)
    freed: seq[MemFrame]            # … and where it was freed

func memDemangle(fn: string): string =
  ## Nim's C names without their module mark (`grow__app_u12` → grow)
  result = fn.strip
  let k = result.find("__")
  if k > 0: result = result[0 ..< k]

func memFrameOf(s: string): (bool, MemFrame) =
  ## one line of a stack: AddressSanitizer's "#3 0x4012ab in main /p/a.c:7:10", valgrind's "at 0x10916: main (a.c:7)"
  let t = s.strip
  var f: MemFrame
  if t.startsWith("#") and " in " in t:
    let k = t.find(" in ")
    var rest = t[k + 4 .. ^1].strip
    let sp = rest.rfind(' ')
    if sp < 0: return (true, MemFrame(fn: memDemangle(rest), line: -1))
    f.fn = memDemangle(rest[0 ..< sp])
    var loc = rest[sp + 1 .. ^1]
    if loc.startsWith("(") or ':' notin loc: return (true, MemFrame(fn: f.fn, line: -1))
    var parts = loc.split(':')
    var nums: seq[int]
    while parts.len > 1 and parts[^1].len > 0 and parts[^1].allCharsInSet(Digits) and nums.len < 2:
      nums.insert parseInt(parts.pop()), 0
    f.path = parts.join(":")
    f.line = if nums.len > 0: nums[0] - 1 else: -1
    f.col = if nums.len > 1: max(0, nums[1] - 1) else: 0
    return (true, f)
  var v = t
  if v.startsWith("=="):
    let e = v.find("==", 2)
    if e > 0: v = v[e + 2 .. ^1].strip
  if (v.startsWith("at 0x") or v.startsWith("by 0x")) and ": " in v:
    let k = v.find(": ")
    let rest = v[k + 2 .. ^1]
    let p = rest.rfind(" (")
    if p < 0 or not rest.endsWith(")"): return (true, MemFrame(fn: memDemangle(rest), line: -1))
    f.fn = memDemangle(rest[0 ..< p])
    let loc = rest[p + 2 ..< rest.high]
    if loc.startsWith("in "): return (true, MemFrame(fn: f.fn, line: -1))
    let c = loc.rfind(':')
    if c > 0 and loc[c + 1 .. ^1].allCharsInSet(Digits) and c + 1 < loc.len:
      f.path = loc[0 ..< c]
      f.line = parseInt(loc[c + 1 .. ^1]) - 1
      return (true, f)
    return (true, MemFrame(fn: f.fn, line: -1))
  (false, f)

func memPlain(kind, access: string): string =
  ## what AddressSanitizer's name for it means for the program
  let rw = if access.startsWith("WRITE"): "writes" elif access.startsWith("READ"): "reads" else: "uses"
  case kind
  of "heap-buffer-overflow": rw & " past the end (or before the start) of memory it allocated"
  of "stack-buffer-overflow": rw & " past the end of a local array"
  of "global-buffer-overflow": rw & " past the end of a global array"
  of "stack-buffer-underflow": rw & " before the start of a local array"
  of "heap-use-after-free": rw & " memory after it was freed"
  of "double-free": "frees memory that was already freed"
  of "attempting double-free": "frees memory that was already freed"
  of "stack-use-after-return": rw & " a local variable of a call that has returned"
  of "stack-use-after-scope": rw & " a variable after its block ended"
  of "SEGV": "a bad pointer (nil, or freed): the program was stopped"
  of "alloc-dealloc-mismatch": "frees memory with a different call than made it (malloc / delete, new / free)"
  of "bad-free", "attempting free": "frees memory that malloc did not give"
  of "memcpy-param-overlap": "copies between overlapping memory (memcpy: memmove is for that)"
  else: kind

proc memProjectFile(path, dir: string): bool =
  ## a file of yours (not the system's, not Nim's or a package's library, not ned's build folder)
  if path.len == 0 or not path.isAbsolute or "/nimcache/" in path or "/.nimble/" in path or "/nimble/pkgs" in path:
    return false
  if rootDir.len > 1 and path.startsWith(rootDir & "/"): return true
  path.startsWith(dir & "/")

proc memFirstOwn(fs: seq[MemFrame], dir: string, skipAlloc = false): int =
  ## the innermost call in a file of yours: where to put the problem (an allocation: past malloc, new, alloc …)
  for i, f in fs:
    if f.line < 0: continue
    if skipAlloc and f.fn in ["malloc", "calloc", "realloc", "free", "alloc", "alloc0", "allocImpl", "alloc0Impl",
                              "allocShared", "allocShared0", "reallocImpl", "rawAlloc", "newObj", "nimNewObj",
                              "newSeq", "operator new", "operator new[]", "strdup"]: continue
    if memProjectFile(f.path, dir): return i
  -1

proc memParse(lines: seq[string], dir: string): seq[MemFind] =
  ## the reports in a run's output: AddressSanitizer's and LeakSanitizer's blocks, UBSan's runtime errors,
  ## valgrind's errors and leaks
  var i = 0
  proc frames(i: var int): seq[MemFrame] =
    while i < lines.len:
      let (ok, f) = memFrameOf(lines[i])
      if not ok: break
      result.add f
      inc i
  while i < lines.len:
    let s = lines[i]
    let t = s.strip
    if "ERROR: AddressSanitizer: " in t:
      let tail = t[t.find("ERROR: AddressSanitizer: ") + "ERROR: AddressSanitizer: ".len .. ^1]
      let kind = tail.split(' ')[0]
      var m = MemFind(sev: 1)
      inc i
      var access = ""
      var where = 0                                # 0 the access, 1 made, 2 freed
      while i < lines.len and not lines[i].strip.startsWith("SUMMARY:"):
        let u = lines[i].strip
        if u.startsWith("READ of size") or u.startsWith("WRITE of size"): access = u.split(" at ")[0]
        elif u.startsWith("allocated by") or u.startsWith("previously allocated by"): where = 1
        elif u.startsWith("freed by"): where = 2
        let (ok, _) = memFrameOf(lines[i])
        if ok:
          let fs = frames(i)
          case where
          of 0: (if m.at.len == 0: m.at = fs)
          of 1: (if m.alloc.len == 0: m.alloc = fs)
          else: (if m.freed.len == 0: m.freed = fs)
          continue
        if "ERROR: AddressSanitizer: " in u or "ERROR: LeakSanitizer: " in u: break
        inc i
      m.msg = "memory: the program " & memPlain(kind, access) & (if access.len > 0: " (" & access & ")" else: "") &
              " — AddressSanitizer: " & kind
      result.add m
      continue
    if t.startsWith("Direct leak of") or t.startsWith("Indirect leak of"):
      var m = MemFind(sev: 2)
      let what = t.split(" allocated from")[0]
      m.msg = "memory: " & what.replace("Direct leak of", "never freed:").replace("Indirect leak of",
              "never freed (held by memory never freed):") & " — LeakSanitizer"
      inc i
      m.alloc = frames(i)
      result.add m
      continue
    if ": runtime error: " in t:
      # path:line:col: runtime error: …
      let k = t.find(": runtime error: ")
      var loc = t[0 ..< k]
      var nums: seq[int]
      var parts = loc.split(':')
      while parts.len > 1 and parts[^1].len > 0 and parts[^1].allCharsInSet(Digits) and nums.len < 2:
        nums.insert parseInt(parts.pop()), 0
      var path = parts.join(":")
      if path.len > 0 and not path.isAbsolute: path = dir / path
      var m = MemFind(sev: 2, msg: "undefined behaviour: " & t[k + ": runtime error: ".len .. ^1] & " — UBSan")
      if nums.len > 0: m.at.add MemFrame(path: path, line: nums[0] - 1, col: (if nums.len > 1: nums[1] - 1 else: 0))
      inc i
      let fs = frames(i)
      if m.at.len == 0: m.at = fs
      result.add m
      continue
    # valgrind: ==123== Invalid write of size 4 / … definitely lost …
    if t.startsWith("==") and t.find("==", 2) > 0:
      let v = t[t.find("==", 2) + 2 .. ^1].strip
      let errKinds = ["Invalid read", "Invalid write", "Invalid free", "Mismatched free", "Use of uninitialised",
                      "Conditional jump or move depends on uninitialised", "Syscall param", "Source and destination overlap"]
      var isErr = false
      for e in errKinds:
        if v.startsWith(e): isErr = true
      let leak = "definitely lost in loss record" in v or "possibly lost in loss record" in v
      if isErr or leak:
        var m = MemFind(sev: (if leak: 2 else: 1))
        m.msg = (if leak: "memory: never freed — " & v.split(" in loss record")[0] else: "memory: " & v) & " — valgrind"
        inc i
        let fs = frames(i)
        if leak: m.alloc = fs else: m.at = fs
        # "Address 0x… is 0 bytes after a block of size 8 alloc'd" — where that block was made
        if i < lines.len and "Address 0x" in lines[i] and ("alloc'd" in lines[i] or "free'd" in lines[i]):
          let freed = "free'd" in lines[i]
          inc i
          let more = frames(i)
          if freed: m.freed = more else: m.alloc = more
        result.add m
        continue
    inc i

proc memLoc(f: MemFrame): string =
  extractFilename(f.path) & ":" & $(f.line + 1) & (if f.fn.len > 0: " " & f.fn else: "")

proc memToDiags(fs: seq[MemFind], dir: string): Table[string, seq[Diag]] =
  ## each find on the line of yours it happened at (a leak: where the memory was made), the calls below it
  var errAt: HashSet[(string, int)]                     # (what AddressSanitizer stopped at: UBSan's word there goes)
  for m in fs:
    if m.sev == 1:
      let ai = memFirstOwn(m.at, dir)
      if ai >= 0: errAt.incl (m.at[ai].path, m.at[ai].line)
  for m in fs:
    if m.sev == 2 and m.msg.endsWith(" — UBSan") and m.at.len > 0:
      let ai = memFirstOwn(m.at, dir)
      if ai >= 0 and (m.at[ai].path, m.at[ai].line) in errAt: continue
    var where: MemFrame
    let ai = memFirstOwn(m.at, dir)
    if ai >= 0: where = m.at[ai]
    else:
      let li = memFirstOwn(m.alloc, dir, skipAlloc = true)
      if li >= 0: where = m.alloc[li]
      else: continue                                    # (nothing of yours in it: the Output panel has it)
    var msg = m.msg
    proc stack(title: string, xs: seq[MemFrame], skipAlloc: bool) =
      var shown = 0
      var started = false
      for f in xs:
        if f.line < 0 or f.path.len == 0: continue
        if skipAlloc and not started and memFirstOwn(@[f], dir, true) < 0: continue
        started = true
        if shown == 0: msg.add "\n" & title
        msg.add "\n  " & memLoc(f)
        inc shown
        if shown >= 6: break
    stack("where:", m.at, false)
    stack("the memory was made at:", m.alloc, true)
    stack("and freed at:", m.freed, true)
    result.mgetOrPut(where.path, @[]).add Diag(line: where.line, col: where.col, eline: where.line, ecol: -1,
                                                sev: m.sev, msg: msg, src: "memory")

proc memCheckCmd(b: Buffer, tmp: string): string =
  ## the build with the checks (address and undefined behaviour; then undefined behaviour only; then a plain build
  ## run under valgrind), then the run — one shell command
  let f = quoteShell(b.path)
  let t = quoteShell(tmp)
  let prog = quoteShell(tmp / "prog")
  var builds: seq[string]
  if b.lang.mode == lmNim:
    let base = "nim " & (if cfgNimTarget == "cpp": "cpp" else: "c") & " --hints:off --debugger:native -d:useMalloc" &
               (if cfgNimFlags.len > 0: " " & cfgNimFlags else: "") & " --nimcache:" & quoteShell(tmp / "nc") &
               " -o:" & prog
    builds = @[base & " --passC:-fsanitize=address,undefined --passC:-fsanitize-recover=address" &
                      " --passC:-fno-omit-frame-pointer --passL:-fsanitize=address,undefined " & f,
               base & " --passC:-fsanitize=undefined --passL:-fsanitize=undefined " & f,
               base & " " & f]
  else:
    let cpp = b.lang.id == "cpp"
    var cc = if cpp: "c++" else: "cc"
    if not haveExe(cc): cc = if cpp: "clang++" else: "clang"
    # (-O0: an optimiser drops a write to memory freed right after — and the overflow with it)
    let base = cc & " -g -O0 -fno-omit-frame-pointer" & (if cpp: " -std=c++17" else: "") & " -o " & prog & " " & f
    # (-fsanitize-recover=address: on after the first overflow, so one run finds them all — the leaks at the end too)
    builds = @[base & " -fsanitize=address,undefined -fsanitize-recover=address -lm", base & " -fsanitize=undefined -lm",
               base & " -lm"]
  # leaks: LeakSanitizer is there on Linux (not on Android, nor macOS on ARM)
  let leaks = when defined(linux): (if isTermux(): "0" else: "1") else: "0"
  let asan = "ASAN_OPTIONS=detect_leaks=" & leaks & ":halt_on_error=0:abort_on_error=0:print_summary=1:" &
             "allocator_may_return_null=1:color=never UBSAN_OPTIONS=print_stacktrace=1:halt_on_error=0:color=never"
  result = "T=" & t & "; mkdir -p \"$T\"; " &
    "if " & builds[0] & " >\"$T/b1\" 2>&1; then M=asan; " &
    "elif " & builds[1] & " >\"$T/b2\" 2>&1; then M=ubsan; " &
    "elif " & builds[2] & " >\"$T/b3\" 2>&1; then M=plain; " &
    "else cat \"$T/b3\"; echo '@@ned-mem build'; rm -rf \"$T\"; exit 1; fi; echo \"@@ned-mem $M\"; " &
    "case $M in asan|ubsan) env " & asan & " " & prog & "; c=$?;; " &
    "*) if command -v valgrind >/dev/null 2>&1; then valgrind --leak-check=full --show-leak-kinds=definite,possible " &
    "--fullpath-after= --error-exitcode=99 " & prog & "; c=$?; else " & prog & "; c=$?; echo '@@ned-mem none'; fi;; esac; " &
    "rm -rf \"$T\"; exit $c"

proc cmdMemoryChecks() =
  ## the current Nim, C or C++ program built with the memory checks and run: overflows, uses after free, leaks and
  ## undefined behaviour in Problems, on the lines of yours they happened at
  let b = buf()
  if b.path.len == 0 or b.lang == nil or not (b.lang.mode == lmNim and b.path.endsWith(".nim") or
                                                b.lang.id in ["c", "cpp"]):
    info("Run with memory checks: open a Nim, C or C++ program first")
    return
  if b.lang.mode == lmNim and not haveExe("nim"):
    error("nim is not installed")
    return
  if b.lang.id in ["c", "cpp"] and not (haveExe("cc") or haveExe("clang") or haveExe("c++") or haveExe("clang++")):
    error("No C compiler (cc, clang) is installed")
    return
  let dir = parentDir(b.path)
  let tmp = privTmp("memcheck")
  let path = b.path
  runCommand(memCheckCmd(b, tmp), dir, proc(code: int) =
    var lines: seq[string]
    var mode = ""
    for pl in panelLines:
      if pl.text.startsWith("@@ned-mem "):
        let m = pl.text["@@ned-mem ".len .. ^1].strip
        if m in ["asan", "ubsan", "plain"]: mode = m
        elif m == "none": mode = "none"
        elif m == "build": mode = "build"
      lines.add pl.text
    if mode == "build":
      addPanelLine(PanelLine(text: "✗ memory checks: it did not build (the errors are above)", sev: 1, line: -1))
      return
    let finds = memParse(lines, dir)
    # (UBSan's lines look like a compiler's: what the run's own reading made of them gives way to these)
    for p, ds in diagsBuild.mpairs:
      var keep: seq[Diag]
      for d in ds:
        if not (d.src == "build" and "runtime error" in d.msg): keep.add d
      ds = keep
    var n = 0
    for p, ds in memToDiags(finds, dir):
      for d in ds:
        diagsBuild.mgetOrPut(p, @[]).add d
        inc n
    let how = case mode
      of "asan": "address and undefined-behaviour checks"
      of "ubsan": "undefined-behaviour checks only (this compiler has no address checks)"
      of "plain": "valgrind"
      else: ""
    if mode == "none":
      addPanelLine(PanelLine(text: "✗ memory checks: this compiler has none, and valgrind is not installed — " &
                   (if isTermux(): "pkg install valgrind" else: "install valgrind, or clang"), sev: 1, line: -1))
    elif finds.len == 0:
      addPanelLine(PanelLine(text: "✓ memory checks (" & how & "): nothing found", sev: 4, line: -1))
    else:
      addPanelLine(PanelLine(text: "✗ memory checks (" & how & "): " & $finds.len & " found" &
                   (if n > 0: ", " & $n & " on lines of yours — Problems (Alt+N jumps to the next)" else: "") &
                   (if n < finds.len: "; the rest are in libraries (above)" else: ""), sev: 1, line: -1))
      if n > 0: info("Memory checks: " & $n & " problem" & (if n == 1: "" else: "s") & " in " & extractFilename(path))
    needRender = true)
