# ── Compiler Explorer, as godbolt.org: the file beside the assembly it compiles to, compiled again a moment after
#    you stop typing (the unsaved text, in a private copy of its folder), each source line and the instructions it
#    made in one colour, the cursor or the mouse on either side lighting up the other; a toolbar over the assembly
#    (the C compiler, the target, the options, Intel/AT&T, assembly or a disassembled object, the filters, running
#    the program, comparing two sets of options); what an instruction or a register is on hover; F12 on a call goes
#    to the function. Nim (through its C), C and C++. The reading of the assembly: asmview.nim ──

type CeState = object
  srcBufId, viewBufId: int
  lang: string                  # nim · c · cpp
  srcPath: string               # the file shown
  shadowRoot: string            # the private copy of its project (links to everything else in it)
  shadow: string                # … the file's folder in it
  copy: string                  # the source's copy there: what is compiled
  compiledChange: int           # the source's text compiled (or being compiled): its changeId
  running: bool
  started: MonoTime
  ms: int                       # the last compile's time
  res: AsmResult
  failed: bool
  errLines: seq[string]
  header: int                   # the view's lines before the assembly
  srcToView: Table[int, seq[int]]
  hotSrc: int                   # the source line lit up (-1)
  hotFromView: bool
  versions: Table[string, string]
  runGen: int                   # (execute) the run asked for last

var ce: CeState

const CePalette = [Rgb(0xE06C75), Rgb(0xD19A66), Rgb(0xE5C07B), Rgb(0x98C379), Rgb(0x56B6C2), Rgb(0x61AFEF),
                   Rgb(0xC678DD), Rgb(0xFF79C6), Rgb(0x8BE9FD), Rgb(0xB5E853), Rgb(0xF5A97F), Rgb(0x7AA2F7)]

proc ceIsView(b: Buffer): bool = b != nil and ce.viewBufId > 0 and b.id == ce.viewBufId

proc ceOpt(k: string): string = sStr("compilerExplorer." & k)

proc ceTermux(): bool = getEnv("PREFIX").contains("com.termux")

proc ceCompiler(): string =
  ## the C compiler used: the setting's, or (auto) gcc — clang on Termux and macOS —, else whichever is installed
  let c = ceOpt("compiler")
  if c in ["gcc", "clang", "zig"]: return (if haveExe(c): c else: "")
  let order = if ceTermux() or defined(macosx): @["clang", "gcc", "zig"] else: @["gcc", "clang", "zig"]
  for x in order:
    if haveExe(x): return x
  ""

proc ceTarget(): string =
  ## the processor: x86_64, arm64, riscv64, i386 (native: this one)
  let t = ceOpt("target")
  if t != "native" and t.len > 0: return t
  case hostCPU
  of "amd64": "x86_64"
  of "arm64": "arm64"
  of "riscv64": "riscv64"
  of "i386": "i386"
  else: hostCPU

proc ceCross(): bool =
  ## another processor than this one: built through zig cc
  let t = ceOpt("target")
  t.len > 0 and t != "native" and t != (case hostCPU
                                        of "amd64": "x86_64"
                                        else: hostCPU)

proc ceTargetLabel(t: string): string =
  case t
  of "x86_64": "x86-64"
  of "arm64": "ARM64"
  of "riscv64": "RISC-V 64"
  of "i386": "x86 (32-bit)"
  else: t

proc ceX86(): bool = ceTarget() in ["x86_64", "i386"]

proc ceInstallHint(what: string): string =
  if ceTermux(): (if what == "objdump": "pkg install binutils" else: "pkg install clang")
  elif defined(macosx): "xcode-select --install"
  elif defined(windows): "MinGW (gcc) or LLVM (clang)"
  else: (if what == "objdump": "binutils (apt install binutils)" else: "gcc or clang (apt install gcc)")

proc ceObjdump(): string =
  ## the disassembler for the binary output (llvm-objdump reads every processor; GNU's objdump this one's)
  if ceCross() and haveExe("llvm-objdump"): return "llvm-objdump"
  if haveExe("objdump"): return "objdump"
  if haveExe("llvm-objdump"): return "llvm-objdump"
  ""

proc ceZigWrapper(): string =
  ## a script that runs `zig cc` for the target (Nim takes it as its clang)
  let t = ceTarget()
  let triple = case t
               of "x86_64": "x86_64-linux-musl"
               of "arm64": "aarch64-linux-musl"
               of "riscv64": "riscv64-linux-musl"
               of "i386": "x86-linux-musl"
               else: t & "-linux-musl"
  result = privDir() / ("ce-zigcc-" & t)
  let body = "#!/bin/sh\nexec zig cc -target " & triple & " \"$@\"\n"
  try:
    if not fileExists(result) or readFile(result) != body:
      writeFile(result, body)
      setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})
  except CatchableError: discard

proc ceFilters(): AsmFilters =
  AsmFilters(labels: sBool("compilerExplorer.filterLabels"), library: sBool("compilerExplorer.filterLibrary"),
             directives: sBool("compilerExplorer.filterDirectives"), comments: sBool("compilerExplorer.filterComments"),
             demangle: sBool("compilerExplorer.demangle"))

proc ceOptionsText(): string =
  if ce.lang == "nim": ceOpt("options") else: ceOpt("cOptions")

proc ceCcShown(): string =
  ## the C compiler that compiles it (another processor: zig cc, whatever the setting)
  if ceCross(): "zig" else: ceCompiler()

proc ceDescribe(): string =
  ## the first line of the view: what compiled it, for what, how
  let cc = ceCcShown()
  var parts: seq[string]
  if ce.lang == "nim": parts.add ce.versions.getOrDefault("nim", "nim")
  parts.add (if cc.len > 0: ce.versions.getOrDefault(cc, cc) else: "no C compiler")
  parts.add ceTargetLabel(ceTarget())
  let o = ceOptionsText().strip
  parts.add (if o.len > 0: o elif ce.lang == "nim": "debug build" else: "no options")
  if ceX86(): parts.add (if ceOpt("syntax") == "att": "AT&T" else: "Intel")
  parts.add (if ceOpt("output") == "binary": "binary" else: "asm")
  parts.join(" · ")

# ── the private copy: a folder that links to everything beside the file (so its imports, includes and config
#    are found), with the unsaved text in place of the file ──

proc ceShadowFor(src: string): (string, string) =
  ## (the private folder, the folder the copy goes in): the project mirrored by links — from its top down to the
  ## file's folder, each folder on the way a real one holding links to everything else in it — so the file's
  ## imports, includes, nim.cfg / config.nims (its folder's and those above it) and their relative paths are found
  let dir = parentDir(src)
  let top = if rootDir.len > 1 and (dir == rootDir or dir.startsWith(rootDir & "/")): rootDir else: dir
  let base = privDir() / ("ce-" & toHex(hash(src).uint32, 8).toLowerAscii)
  var chain = @[top]
  if dir != top:
    var d = top
    for part in relativePath(dir, top).split({'/', '\\'}):
      if part.len == 0 or part == ".": continue
      d = d / part
      chain.add d
  try: createDir(base)
  except CatchableError: return ("", "")
  for k, d in chain:
    let mirror = if k == 0: base else: base / relativePath(d, top)
    try: createDir(mirror)
    except CatchableError: return ("", "")
    let next = if k + 1 < chain.len: extractFilename(chain[k + 1]) else: ""
    try:
      for kind, p in walkDir(d):
        let nm = extractFilename(p)
        if nm == next or (k == chain.high and nm == extractFilename(src)) or nm in [".git", ".ce-nimcache",
           ".ce-nimcache-run"] or nm.startsWith(".ce-out") or nm.startsWith(".ce-run"):
          continue
        let link = mirror / nm
        if symlinkExists(link) or fileExists(link) or dirExists(link): continue
        try: createSymlink(p, link)
        except CatchableError: discard
    except CatchableError: discard
  (base, base / relativePath(dir, top))

proc ceRoutineNames(lines: seq[string]): seq[string] =
  ## the file's own top-level procs, funcs, methods and converters, by name — not the generic ones, which a
  ## typed symbol cannot name before they are instantiated
  for l in lines:
    for kw in ["proc ", "func ", "method ", "converter "]:
      if not l.startsWith(kw): continue
      let s = l[kw.len .. ^1].strip(trailing = false)
      var name = ""
      var i = 0
      if s.startsWith("`"):
        let e = s.find('`', 1)
        if e > 1: (name, i) = (s[0 .. e], e + 1)
      else:
        while i < s.len and s[i] in IdentChars: inc i
        name = s[0 ..< i]
      if i < s.len and s[i] == '*': inc i
      if name.len == 0 or (i < s.len and s[i] == '['): continue          # (generic: needs a call to exist)
      if name notin result: result.add name

proc ceKeeper(names: seq[string], file: string): string =
  ## (the end of the private copy) a macro that takes each of the file's routines by its symbol — overloads too —
  ## and casts it to a pointer: Nim then compiles every one, also those nothing calls yet. Generic, compile-time,
  ## imported and magic ones are passed over. Nothing of it runs: a discarded cast is no code.
  if names.len == 0: return ""
  let suffix = "/" & extractFilename(file)
  result = "\n# ned · Compiler Explorer: every proc of this file compiled (Nim leaves out what nothing calls)\n" &
    "from std/macros import nil\n" &
    "macro nedCeKeepAll(syms: varargs[typed]): untyped =\n" &
    "  result = macros.newStmtList()\n" &
    "  for s in macros.children(syms):\n" &
    "    var xs: seq[NimNode]\n" &
    "    if macros.kind(s) in {macros.nnkClosedSymChoice, macros.nnkOpenSymChoice}:\n" &
    "      for c in macros.children(s): xs.add c\n" &
    "    else: xs.add s\n" &
    "    for x in xs:\n" &
    "      if macros.kind(x) != macros.nnkSym: continue\n" &
    "      if macros.symKind(x) notin {macros.nskProc, macros.nskFunc, macros.nskMethod, macros.nskConverter}: continue\n" &
    "      let f = macros.lineInfoObj(x).filename\n" &
    "      if f.len < " & $suffix.len & " or f[f.len - " & $suffix.len & " .. ^1] != " & suffix.escape & ": continue\n" &
    "      let d = macros.getImpl(x)\n" &
    "      if macros.kind(d) notin {macros.nnkProcDef, macros.nnkFuncDef, macros.nnkMethodDef, macros.nnkConverterDef}: continue\n" &
    "      if macros.kind(macros.`[]`(d, 2)) == macros.nnkGenericParams: continue\n" &
    "      var skip = false\n" &
    "      for p in macros.children(macros.`[]`(d, 4)):\n" &
    "        let n = if macros.kind(p) in {macros.nnkExprColonExpr, macros.nnkCall}: macros.`[]`(p, 0) else: p\n" &
    "        if macros.kind(n) in {macros.nnkIdent, macros.nnkSym}:\n" &
    "          for w in [\"compileTime\", \"importc\", \"importcpp\", \"importjs\", \"header\", \"magic\", \"error\"]:\n" &
    "            if macros.eqIdent(n, w): skip = true\n" &
    "      if skip: continue\n" &
    "      macros.add(result, macros.newTree(macros.nnkDiscardStmt, macros.newTree(macros.nnkCast, macros.ident(\"pointer\"), x)))\n" &
    "nedCeKeepAll(" & names.join(", ") & ")\n"

proc ceWriteCopy(src: Buffer, keepAll = false): bool =
  ## the buffer's text in the copy (when it changed) — with `keepAll`, and a Nim file, the line that keeps its procs
  if ce.shadow.len == 0: return false
  ce.copy = ce.shadow / extractFilename(src.path)
  var text = src.lines.join("\n") & "\n"
  if keepAll and ce.lang == "nim": text.add ceKeeper(ceRoutineNames(src.lines), ce.copy)
  try:
    if not fileExists(ce.copy) or readFile(ce.copy) != text: writeFile(ce.copy, text)
    true
  except CatchableError: false

# ── the build: Nim to C (--compileOnly, line directives on), then the C compiler's -S for the module (or -c and
#    objdump) — the C compiler's command as Nim wrote it in the nimcache's .json ──

proc ceNimCcFlags(cc: string): string =
  if ceCross() or cc == "zig":
    let w = quoteShell(ceZigWrapper())
    result = " --cc:clang --clang.exe:" & w & " --clang.linkerexe:" & w
    if ceCross():
      result.add " --os:linux --cpu:" & (case ceTarget()
                                         of "x86_64": "amd64"
                                         else: ceTarget())
  else: result = " --cc:" & cc

proc ceCcExe(cc: string): string =
  if ceCross() or cc == "zig": quoteShell(ceZigWrapper()) else: cc

proc ceAsmFlags(binary: bool): string =
  result = " -fno-asynchronous-unwind-tables"
  if binary: result.add " -gdwarf-4"
  elif ceX86() and ceOpt("syntax") != "att": result.add " -masm=intel"

proc ceRewriteCmd(cmd, outFile: string, binary: bool): string =
  ## Nim's command for the module's C file, made to write assembly (-S) or an object with plain DWARF
  result = cmd
  if not binary: result = result.replace(" -c ", " -S ")
  let k = result.find(" -o ")
  if k >= 0:
    var e = k + 4
    while e < result.len and result[e] == ' ': inc e
    if e < result.len and result[e] in {'"', '\''}:
      let q = result[e]
      let z = result.find(q, e + 1)
      e = if z > 0: z + 1 else: result.len
    else:
      while e < result.len and result[e] != ' ': inc e
    result = result[0 ..< k] & " -o " & quoteShell(outFile) & result[e .. ^1]
  result.add ceAsmFlags(binary)

proc ceModuleCmd(nimcache, copy: string): string =
  ## the C compiler's command for the main module, from Nim's .json in the nimcache
  let jf = nimcache / (splitFile(copy).name & ".json")
  try:
    let j = parseFile(jf)
    let want = "@m" & extractFilename(copy) & ".c"
    for e in j{"compile"}:
      if e.kind == JArray and e.len >= 2 and e[0].getStr.endsWith(want): return e[1].getStr
  except CatchableError: discard
  ""

proc ceBuild(src: Buffer, opts: string, done: proc(ok: bool, r: AsmResult, err: seq[string]) {.closure.}) =
  ## the file compiled with `opts` (the toolbar's other settings): its assembly read, or what went wrong
  let cc = ceCompiler()
  if cc.len == 0:
    done(false, AsmResult(), @["No C compiler — install " & ceInstallHint("cc")])
    return
  if ceCross() and not haveExe("zig"):
    done(false, AsmResult(), @["Another processor than this one needs zig (ziglang.org) — or set the target to native"])
    return
  let keepAll = ce.lang == "nim" and sBool("compilerExplorer.allProcs")
  if not ceWriteCopy(src, keepAll):
    done(false, AsmResult(), @["Cannot write the copy of the file in " & tildePath(ce.shadow)])
    return
  let binary = ceOpt("output") == "binary"
  let od = ceObjdump()
  if binary and od.len == 0:
    done(false, AsmResult(), @["The binary output needs objdump — install " & ceInstallHint("objdump")])
    return
  let copy = ce.copy
  let shadow = ce.shadow
  let shadowRoot = ce.shadowRoot
  let filters = ceFilters()
  let outS = shadow / ".ce-out" & (if binary: ".o" else: ".s")
  proc stage2(cmd: string) =
    let full = if binary: cmd & " && " & od & " -d -r -l --no-show-raw-insn" &
                          (if ceX86() and ceOpt("syntax") != "att": " -M intel" else: "") & " " & quoteShell(outS)
               else: cmd
    discard startJob(jkTool, "LC_ALL=C " & full & " 2>&1", shadow, proc(j: Job) =
      if j.code != 0:
        var errs: seq[string]
        for l in stripAnsi(j.output).splitLines:
          if l.strip.len > 0: errs.add l.replace(shadow & "/", "")
        done(false, AsmResult(), errs)
        return
      var r: AsmResult
      try:
        r = if binary: parseObjdump(j.output, copy, filters)
            else: parseGas(readFile(outS), copy, filters)
      except CatchableError as e:
        done(false, AsmResult(), @["Cannot read the assembly: " & e.msg])
        return
      done(true, r, @[]))
  if ce.lang == "nim":
    let nc = shadowRoot / ".ce-nimcache"
    let cmd = "nim c --hints:off --warnings:off --colors:off --debugger:native --compileOnly" & ceNimCcFlags(cc) &
              " --nimcache:" & quoteShell(nc) & (if opts.strip.len > 0: " " & opts.strip else: "") & " " &
              quoteShell(copy) & " 2>&1"
    let srcId = src.id
    proc nimStage(keep: bool) =
      discard startJob(jkTool, cmd, shadow, proc(j: Job) =
        if j.code != 0:
          let sb = bufById(srcId)
          if keep and sb != nil and ceWriteCopy(sb, false):
            nimStage(false)                  # (the line that keeps every proc did not compile here: without it)
            return
          var errs: seq[string]
          for l in stripAnsi(j.output).splitLines:
            if l.strip.len > 0: errs.add l.replace(shadow & "/", "")
          done(false, AsmResult(), errs)
          return
        let mc = ceModuleCmd(nc, copy)
        if mc.len == 0:
          done(false, AsmResult(), @["Nim wrote no C compiler command for the module (" & tildePath(nc) & ")"])
          return
        stage2(ceRewriteCmd(mc, outS, binary)))
    nimStage(keepAll)
  else:
    let cpp = ce.lang == "cpp"
    let ccx = ceCcExe(cc)
    let cxx = if cpp and not (ceCross() or cc == "zig"): (if cc == "gcc": "g++" else: "clang++") else: ccx
    let cmd = cxx & (if cpp and (ceCross() or cc == "zig"): " -x c++" else: "") & " -g " & opts.strip &
              (if binary: " -c" else: " -S") & " -I" & quoteShell(parentDir(ce.srcPath)) & " -o " & quoteShell(outS) &
              " " & quoteShell(copy) & ceAsmFlags(binary)
    stage2(cmd)

# ── the view ──

proc ceViewLines(): seq[string] =
  result.add "; " & ceDescribe()
  if ce.failed:
    result.add "; <Compilation failed>  (Enter on the first line: options)"
    result.add ""
    for l in ce.errLines: result.add "; " & l
    return
  let shown = ce.res.lines.len
  var status = "; compiled in " & formatFloat(ce.ms.float / 1000, ffDecimal, 2) & " s · " & $shown & " lines"
  if ce.res.total > shown: status.add " (" & $(ce.res.total - shown) & " filtered)"
  if shown == 0:
    status.add (if sBool("compilerExplorer.allProcs"): " — nothing here: a generic proc needs a call to be compiled"
                else: " — nothing here: Nim leaves out procs nothing calls (Filters ▾ › Every proc of the file)")
  result.add status
  result.add ""
  for l in ce.res.lines: result.add l.text

proc ceTints() =
  ## the colours: each source line and the instructions it made; the line under the cursor or the mouse stronger
  let src = bufById(ce.srcBufId)
  if src == nil or ce.viewBufId <= 0: return
  let stale = src.changeId != ce.compiledChange
  var tv, ts: Table[int, (Rgb, float)]
  if not ce.failed:
    for s, vls in ce.srcToView:
      let c = CePalette[s mod CePalette.len]
      let hot = s == ce.hotSrc
      ts[s] = (c, (if hot: 0.42 elif stale: 0.07 else: 0.16))
      for vl in vls: tv[vl] = (c, (if hot: 0.42 else: 0.16))
  lineTints[ce.viewBufId] = tv
  lineTints[ce.srcBufId] = ts
  needRender = true

proc ceShowView() =
  ## the view's text (made, or replaced keeping where it was scrolled)
  let v = bufById(ce.viewBufId)
  if v == nil: return
  let text = ceViewLines().join("\n")
  ce.header = if ce.failed: 0 else: 3
  ce.srcToView.clear()
  if not ce.failed:
    for i, l in ce.res.lines:
      if l.src >= 0: ce.srcToView.mgetOrPut(l.src, @[]).add ce.header + i
  if v.lines.join("\n") == text:
    ceTints()                                        # (the same assembly: nothing moves)
    return
  let keepTop = v.topLine
  let keepCur = v.primary.head
  v.readOnly = false
  v.setContent(text)
  v.readOnly = true
  v.topLine = clamp(keepTop, 0, v.lines.high)
  let kl = clamp(keepCur.line, 0, v.lines.high)
  v.setSingle(Pos(line: kl, col: min(keepCur.col, v.lines[kl].len)))
  if splitOn:
    for i in 0 ..< panes.len:
      if panes[i].bufId == v.id and i != activePane:
        panes[i].snap.topLine = clamp(panes[i].snap.topLine, 0, v.lines.high)
        for c in panes[i].snap.cursors.mitems:
          c.head.line = clamp(c.head.line, 0, v.lines.high)
          c.anchor.line = clamp(c.anchor.line, 0, v.lines.high)
  ceTints()

proc ceRun()

proc ceCompile() =
  ## the source compiled again (the newest text; one build at a time — the text changed meanwhile: again after)
  let src = bufById(ce.srcBufId)
  if src == nil or ce.running: return
  ce.running = true
  ce.started = getMonoTime()
  ce.compiledChange = src.changeId
  needRender = true
  ceBuild(src, ceOptionsText(), proc(ok: bool, r: AsmResult, err: seq[string]) =
    ce.running = false
    ce.ms = int(msSince(ce.started))
    ce.failed = not ok
    if ok:
      ce.res = r
      ce.errLines = @[]
    else: ce.errLines = err
    ceShowView()
    if ok and sBool("compilerExplorer.execute"): ceRun())

proc ceRun() =
  ## the program built and run (godbolt.org's Execution): its exit code and output in the Output panel
  let src = bufById(ce.srcBufId)
  if src == nil: return
  if ceCross():
    panelStore[pkOutput] = @[PanelLine(text: "Compiler Explorer: a program for " & ceTargetLabel(ceTarget()) &
                                        " does not run here (target: native runs it)", sev: 2, line: -1)]
    return
  let cc = ceCompiler()
  if cc.len == 0: return
  inc ce.runGen
  let gen = ce.runGen
  let exe = ce.shadow / ".ce-run" & (when defined(windows): ".exe" else: "")
  let args = ceOpt("args").strip
  let build = if ce.lang == "nim":
                "nim c --hints:off --warnings:off --colors:off" & ceNimCcFlags(cc) & " --nimcache:" &
                  quoteShell(ce.shadowRoot / ".ce-nimcache-run") & " " & ceOptionsText().strip & " -o:" & quoteShell(exe) &
                  " " & quoteShell(ce.copy)
              else:
                (if ce.lang == "cpp": (if cc == "gcc": "g++" else: "clang++") else: ceCcExe(cc)) & " " &
                  ceOptionsText().strip & " -I" & quoteShell(parentDir(ce.srcPath)) & " -o " & quoteShell(exe) & " " &
                  quoteShell(ce.copy)
  let name = extractFilename(ce.srcPath)
  discard startJob(jkTool, build & " 2>&1", ce.shadow, proc(j: Job) =
    if gen != ce.runGen: return
    if j.code != 0:
      var pl = @[PanelLine(text: "Compiler Explorer — " & name & ": the program did not build", sev: 1, line: -1)]
      for l in stripAnsi(j.output).splitLines:
        if l.strip.len > 0: pl.add PanelLine(text: l, line: -1)
      panelStore[pkOutput] = pl
      needRender = true
      return
    let rj = startJob(jkTool, quoteShell(exe) & (if args.len > 0: " " & args else: "") & " 2>&1 </dev/null", ce.shadow,
      proc(j2: Job) =
        if gen != ce.runGen: return
        var pl = @[PanelLine(text: "Compiler Explorer — " & name & " · Program returned: " & $j2.code, sev: 5, line: -1)]
        let o = stripAnsi(j2.output)
        if o.strip.len > 0:
          for l in o.strip(leading = false).splitLines: pl.add PanelLine(text: l, line: -1)
        else: pl.add PanelLine(text: "(no output)", line: -1)
        panelStore[pkOutput] = pl
        needRender = true)
    if rj != nil: rj.deadlineMs = 10_000)

proc ceVersions(cc: string) =
  ## nim's and the C compiler's versions for the first line (asked once, in the background)
  proc ask(key, cmd: string) =
    if key in ce.versions: return
    ce.versions[key] = key
    discard startJob(jkAux, cmd & " 2>&1", getHomeDir(), proc(j: Job) =
      let first = stripAnsi(j.output).splitLines()[0]
      var v = ""
      for w in first.split({' ', '(', ')'}):
        if w.len > 0 and w[0] in Digits and '.' in w:
          v = w
          if key != "gcc": break           # (gcc's: the last one — "gcc (Ubuntu 13.3.0-6…) 13.3.0")
      if v.len > 0:
        ce.versions[key] = key & " " & v
        let vb = bufById(ce.viewBufId)
        if vb != nil and vb.lines.len > 0:
          vb.readOnly = false
          vb.lines[0] = "; " & ceDescribe()
          vb.readOnly = true
          needRender = true)
  if ce.lang == "nim": ask("nim", "nim --version")
  if cc in ["gcc", "clang"]: ask(cc, cc & " --version")
  if (cc == "zig" or ceCross()) and haveExe("zig"): ask("zig", "zig version")

proc ceOpenView(src: Buffer) =
  ## the view in the pane beside the source (the source keeps the focus)
  let title = "⚙ Compiler Explorer — " & extractFilename(src.path)
  var v = bufById(ce.viewBufId)
  if v == nil:
    let srcIdx = curBuf
    v = openScratch(title, "; " & ceDescribe() & "\n; compiling…", langByName("Assembly"))
    v.readOnly = true
    ce.viewBufId = v.id
    curBuf = srcIdx
    showBeside(src, v)
  else:
    v.title = title
  needRender = true

proc ceClose() =
  lineTints.del ce.srcBufId
  lineTints.del ce.viewBufId
  ce = CeState(hotSrc: -1)

proc cmdCeOptions()

proc cmdCompilerExplorer() =
  ## Compiler Explorer for the file being edited (in the view itself: its options)
  let b = buf()
  if ceIsView(b):
    cmdCeOptions()
    return
  if b.path.len == 0 or b.lang == nil or not (b.lang.mode == lmNim or b.lang.id in ["c", "cpp"]):
    info("Open a Nim, C or C++ file — Compiler Explorer shows the assembly it compiles to")
    return
  if b.path.endsWith(".nims") or b.path.endsWith(".nimble"):
    info("A NimScript file runs in Nim's VM: it is not compiled to machine code")
    return
  let lang = if b.lang.mode == lmNim: "nim" else: b.lang.id
  if lang == "nim" and not haveExe("nim"):
    error("Compiler Explorer needs nim on the PATH")
    return
  let cc = ceCompiler()
  if cc.len == 0:
    error("Compiler Explorer needs a C compiler — install " & ceInstallHint("cc"))
    return
  if ce.viewBufId > 0 and ce.srcBufId != b.id:
    lineTints.del ce.srcBufId                       # (another file: the view follows it)
  let keepView = ce.viewBufId
  let keepVersions = ce.versions
  ce = CeState(srcBufId: b.id, viewBufId: (if bufById(keepView) != nil: keepView else: 0), lang: lang,
               srcPath: b.path, hotSrc: -1, versions: keepVersions, compiledChange: -1)
  (ce.shadowRoot, ce.shadow) = ceShadowFor(b.path)
  if ce.shadow.len == 0:
    error("Compiler Explorer: cannot make its private folder in " & tildePath(privDir()))
    return
  ceVersions(cc)
  ceOpenView(b)
  ceCompile()
  info("Compiler Explorer: " & extractFilename(b.path) & " — it compiles again as you type; the toolbar over the " &
       "assembly (or Enter on its first line) sets it up")

proc cmdCeToggleRun() =
  let on = not sBool("compilerExplorer.execute")
  setSetting("compilerExplorer.execute", %on)
  if on:
    panelKind = pkOutput
    panelOpen = true
    panelStore[pkOutput] = @[PanelLine(text: "Compiler Explorer: building and running the program…", sev: 5, line: -1)]
    if ce.viewBufId > 0 and not ce.failed: ceRun()
  info("Compiler Explorer: " & (if on: "the program runs after each compile (its output: the Output panel)"
                                else: "the program no longer runs"))

proc ceSet(key: string, val: JsonNode) =
  setSetting("compilerExplorer." & key, val)
  if key in ["compiler", "target"]: ceVersions(ceCompiler())
  if ce.viewBufId > 0:
    ce.compiledChange = -1                           # (compiled again at once by the pump)
    let v = bufById(ce.viewBufId)
    if v != nil and v.lines.len > 0:
      v.readOnly = false
      v.lines[0] = "; " & ceDescribe()
      v.readOnly = true
  needRender = true

proc cmdCeOptions() =
  ## every setting of Compiler Explorer in one form
  let f = newForm("Compiler Explorer", "The file beside its assembly, compiled again as you type (as godbolt.org)")
  f.width = 76
  f.addText("options", "Nim options", ceOpt("options"), "-d:release", "Empty: a debug build (Nim's stack " &
            "traces: nimFrame). -d:release, -d:danger (no checks), --mm:arc, --opt:size …")
  f.addText("cOptions", "C/C++ options", ceOpt("cOptions"), "-O2", "For a C or C++ file: -O0, -O2, -O3 -march=native …")
  f.addChoice("compiler", "C compiler", @["auto", "gcc", "clang", "zig"], ceOpt("compiler"),
              "auto: " & (let c = ceCompiler(); if c.len > 0: c else: "none installed"))
  f.addChoice("target", "Target", @["native", "x86_64", "arm64", "riscv64", "i386"], ceOpt("target"),
              "Another processor than this one: through zig cc" & (if haveExe("zig"): "" else: " (zig is not installed)"))
  f.addChoice("syntax", "x86 syntax", @["intel", "att"], ceOpt("syntax"), "", @["Intel", "AT&T"])
  f.addChoice("output", "Output", @["asm", "binary"], ceOpt("output"),
              "binary: the object file disassembled (objdump), with addresses and the calls' targets",
              @["The compiler's assembly", "A disassembled object"])
  f.addHeader("Filters")
  f.addCheck("filterLabels", "Unused labels", sBool("compilerExplorer.filterLabels"))
  f.addCheck("filterLibrary", "Library functions (the runtime, the standard library)",
             sBool("compilerExplorer.filterLibrary"))
  f.addCheck("filterDirectives", "Directives", sBool("compilerExplorer.filterDirectives"))
  f.addCheck("filterComments", "Comments", sBool("compilerExplorer.filterComments"))
  f.addCheck("demangle", "Names as Nim writes them", sBool("compilerExplorer.demangle"))
  f.addCheck("allProcs", "Every proc of a Nim file, also the ones nothing calls yet", sBool("compilerExplorer.allProcs"))
  f.addHeader("Execution")
  f.addCheck("execute", "Run the program after each compile (the Output panel)", sBool("compilerExplorer.execute"))
  f.addText("args", "Its arguments", ceOpt("args"))
  f.addNumber("delay", "Compile after a pause of (ms)", sInt("compilerExplorer.delay"))
  f.addButton("Cancel", "cancel")
  f.addButton("OK", "ok", primary = true)
  f.onButton = proc(ff: Form, id: string): bool =
    if id != "ok": return true
    var changes: seq[(string, JsonNode)]
    for k in ["options", "cOptions", "compiler", "target", "syntax", "output", "args"]:
      changes.add ("compilerExplorer." & k, %ff.formValue(k).strip)
    for k in ["filterLabels", "filterLibrary", "filterDirectives", "filterComments", "demangle", "allProcs", "execute"]:
      changes.add ("compilerExplorer." & k, %ff.formChecked(k))
    var d = 600
    try: d = clamp(parseInt(ff.formValue("delay").strip), 100, 10_000)
    except ValueError: discard
    changes.add ("compilerExplorer.delay", %d)
    setSettings(changes)
    if ce.viewBufId > 0:
      ceVersions(ceCompiler())
      ce.compiledChange = -1
      if sBool("compilerExplorer.execute"):
        panelKind = pkOutput
        panelOpen = true
    true
  openForm(f)

proc cmdCeCompare() =
  ## the assembly with other options beside this one, in the diff view
  if ce.viewBufId <= 0 or bufById(ce.srcBufId) == nil:
    info("Open Compiler Explorer first (Run › Compiler Explorer)")
    return
  let cur = ceOptionsText().strip
  let suggest = if ce.lang != "nim": (if "-O0" in cur: "-O2" else: "-O0")
                elif "danger" in cur: ""
                elif "release" in cur: "-d:danger"
                else: "-d:release"
  askText("Compare with the options:", suggest, proc(other: string) =
    let src = bufById(ce.srcBufId)
    if src == nil: return
    let a = cur
    let b2 = other.strip
    info("Compiler Explorer: compiling with " & (if b2.len > 0: b2 else: "no options") & "…")
    ceBuild(src, a, proc(ok1: bool, r1: AsmResult, e1: seq[string]) =
      ceBuild(src, b2, proc(ok2: bool, r2: AsmResult, e2: seq[string]) =
        var left, right: seq[string]
        if ok1:
          for l in r1.lines: left.add l.text
        else: left = @["; <Compilation failed>"] & e1
        if ok2:
          for l in r2.lines: right.add l.text
        else: right = @["; <Compilation failed>"] & e2
        let la = if a.len > 0: a else: "(no options)"
        let lb = if b2.len > 0: b2 else: "(no options)"
        openDiffView(extractFilename(src.path) & ": " & la & " ⇄ " & lb, left, la, nil, right, lb,
                     langByName("Assembly")))))

# ── following the cursor and the mouse ──

proc ceSrcOfView(line: int): int =
  let i = line - ce.header
  if ce.failed or i < 0 or i >= ce.res.lines.len: -1 else: ce.res.lines[i].src

proc ceReveal(id, line: int) =
  ## the line brought into view in the pane showing the buffer (the other pane: its saved scroll)
  let b = bufById(id)
  if b == nil or line < 0 or line >= b.lines.len: return
  if b == buf():
    if line < b.topLine or line >= b.topLine + max(3, textH) - 1: b.topLine = max(0, line - max(3, textH) div 3)
  else:
    for o in panesShowing(id):
      let h = max(3, panes[o].textH)
      let s = addr panes[o].snap
      if line < s.topLine or line >= s.topLine + h - 1:
        s.topLine = max(0, line - h div 3)
        s.topSub = 0
  needRender = true

proc cePump() =
  ## (the main loop) the view closed: Compiler Explorer ends; the source changed and you paused: compiled again;
  ## the line under the mouse or the cursor lights up its partner
  if ce.viewBufId <= 0: return
  let v = bufById(ce.viewBufId)
  let src = bufById(ce.srcBufId)
  if v == nil or src == nil:
    ceClose()
    return
  if not ce.running and src.changeId != ce.compiledChange and
     msSince(src.lspChangeAt) >= max(100, sInt("compilerExplorer.delay")):
    ceCompile()
  # the line lit up: under the mouse (it moved lately, over either pane), else the cursor's
  var hot = -1
  var fromView = false
  var byMouse = false
  if cfgHoverFx and splitOn and msSince(mouseMovedAt) < 2000 and not menuOpen() and not dialogOpen():
    let pi = paneAt(mouseX, mouseY)
    if pi >= 0:
      let id = if pi == activePane: buf().id else: panes[pi].bufId
      let r = panes[pi].rect
      let top = if pi == activePane: buf().topLine else: panes[pi].snap.topLine
      let row = mouseY - (r.y + 1)
      if row >= 0:
        if id == ce.srcBufId:
          hot = top + row
          byMouse = true
        elif id == ce.viewBufId:
          hot = ceSrcOfView(top + row)
          fromView = true
          byMouse = true
  if not byMouse:
    let cb = buf()
    if cb.id == ce.srcBufId: hot = cb.primary.head.line
    elif cb.id == ce.viewBufId:
      hot = ceSrcOfView(cb.primary.head.line)
      fromView = true
  if hot notin ce.srcToView: hot = (if fromView: hot else: -1)
  if hot != ce.hotSrc or fromView != ce.hotFromView:
    ce.hotSrc = hot
    ce.hotFromView = fromView
    ceTints()
    # (the partner brought into view — not under the mouse: the mouse only lights up)
    if hot >= 0 and not byMouse:
      if fromView: ceReveal(ce.srcBufId, hot)
      elif hot in ce.srcToView: ceReveal(ce.viewBufId, ce.srcToView[hot][0])

# ── the toolbar (the view's pane header), Enter, F12, the hover ──

proc ceSetAct(key, val: string): Action =
  ## (an action of its own for each item: a closure made in a loop would share the loop's variables, and every
  ## item would set the last value)
  result = proc() = ceSet(key, %val)

proc ceToggleAct(key: string): Action =
  result = proc() = ceSet(key, %(not sBool("compilerExplorer." & key)))

proc ceMenu(key: string, opts: seq[(string, string)], x, y: int) =
  var items: seq[MenuItem]
  let cur = ceOpt(key)
  for (val, label) in opts:
    items.add mi(label, "", ceSetAct(key, val), check = (if cur == val: 1 else: 0))
  openMenu(items, x, y + 1)

proc ceFilterMenu(x, y: int) =
  var items: seq[MenuItem]
  for (k, label) in [("filterLabels", "Unused labels"), ("filterLibrary", "Library functions"),
                     ("filterDirectives", "Directives"), ("filterComments", "Comments"),
                     ("demangle", "Demangle Nim's names"), ("allProcs", "Every proc of the file (also unused)")]:
    items.add mi(label, "", ceToggleAct(k), check = (if sBool("compilerExplorer." & k): 1 else: 0))
  openMenu(items, x, y + 1)

proc ceDrawHeader(b: Buffer, i, x, y, w: int) =
  ## the toolbar over the assembly, like godbolt.org's: options, compiler, target, output, filters, syntax, run,
  ## compare — what does not fit on a narrow screen is in the options form (⚙)
  let active = i == activePane
  let bg = if active: theme.crumbBg else: theme.splitBar
  fillRect(x, y, w, 1, theme.dim, bg)
  if active: discard putStr(x, y, "▎", theme.accent, bg)
  let lim = x + w - 3
  var xx = x + 1
  let pi = i
  capture pi:
    region(x, y, max(1, w - 2), 1, proc() = focusPane(pi), "", proc() = ctxOpen(paneHeaderMenu(pi)))
  xx = button(xx, y, "⚙", proc() = cmdCeOptions(), "Compiler Explorer: every setting", theme.accent, bg) + 1
  template item(label: string, act: Action, tip: string) =
    if xx + strWidth(label) < lim:
      xx = button(xx, y, label, act, tip, theme.fg, bg) + 1
      discard putStr(xx - 1, y, "│", blend(theme.dim, bg, 0.4), bg)
  let o = ceOptionsText().strip
  let optLabel = " " & (if o.len > 0: truncTo(o, 24) elif ce.lang == "nim": "debug" else: "options") & " ✎ "
  item(optLabel, proc() =
    let key = if ce.lang == "nim": "options" else: "cOptions"
    askText((if ce.lang == "nim": "Nim options" else: "C options") & " (Compiler Explorer):", ceOpt(key),
            proc(t: string) = ceSet(key, %t.strip)), "The compiler's options (-d:release, -d:danger, --mm:arc …)")
  let cc = ceCcShown()
  let ccx = xx
  item(" " & (if cc.len > 0: ce.versions.getOrDefault(cc, cc) else: "no cc") & " ▾ ",
       proc() = ceMenu("compiler", @[("auto", "auto"), ("gcc", "gcc"), ("clang", "clang"), ("zig", "zig cc")], ccx, y),
       "The C compiler")
  let tx = xx
  item(" " & ceTargetLabel(ceTarget()) & " ▾ ",
       proc() = ceMenu("target", @[("native", "native (" & ceTargetLabel(ceTarget()) & " here)"), ("x86_64", "x86-64"),
                                   ("arm64", "ARM64"), ("riscv64", "RISC-V 64"), ("i386", "x86 32-bit")], tx, y),
       "The processor (another one: through zig cc)")
  let fx = xx
  item(" Filters ▾ ", proc() = ceFilterMenu(fx, y), "What is left out of the assembly")
  let ux = xx
  item(" " & (if ceOpt("output") == "binary": "binary" else: "asm") & " ▾ ",
       proc() = ceMenu("output", @[("asm", "The compiler's assembly"), ("binary", "A disassembled object (objdump)")],
                       ux, y), "The compiler's assembly, or the object disassembled")
  if ceX86():
    let sx = xx
    item(" " & (if ceOpt("syntax") == "att": "AT&T" else: "Intel") & " ▾ ",
         proc() = ceMenu("syntax", @[("intel", "Intel"), ("att", "AT&T")], sx, y), "x86 assembly syntax")
  item((if sBool("compilerExplorer.execute"): " ▶ running " else: " ▶ run "), proc() = cmdCeToggleRun(),
       "Run the program after each compile (its output in the Output panel)")
  item(" ⇄ ", proc() = cmdCeCompare(), "Compare with other options (the diff view)")
  if ce.running and xx + 2 < lim: discard putStr(xx, y, "…", theme.accent, bg)
  discard button(x + w - 2, y, ic("close"), proc() = closePane(pi), "Close this pane (Alt+|)", theme.dim, bg)

proc ceEnter(): bool =
  ## Enter in the view: on its first lines, the options; on a call or a jump, its target (F12)
  let b = buf()
  if not ceIsView(b): return false
  let l = b.primary.head.line
  if l < max(1, ce.header):
    cmdCeOptions()
    return true
  false

proc ceDefinition(b: Buffer): bool =
  ## F12 (Ctrl+click) in the view: a label → its line; a function of the file → its declaration in the source
  if not ceIsView(b): return false
  result = true
  let w = b.wordAt(b.primary.head).strip(chars = {'`', '$'})
  if w.len == 0: return
  for i, l in b.lines:
    if l == w & ":":
      b.setSingle(Pos(line: i, col: 0))
      b.centerOn(Pos(line: i, col: 0))
      return
  let src = bufById(ce.srcBufId)
  if src != nil:
    for i, l in src.lines:
      let t = l.strip(trailing = false)
      for kw in ["proc ", "func ", "method ", "iterator ", "converter ", "template ", "macro "]:
        if t.startsWith(kw) and t[kw.len .. ^1].startsWith(w) and
           (t.len == kw.len + w.len or t[kw.len + w.len] notin IdentChars):
          let ps = panesShowing(src.id)
          if ps.len > 0: focusPane(ps[0])
          let s = buf()
          if s.id == src.id:
            s.setSingle(Pos(line: i, col: t.find(w) + (l.len - t.len)))
            s.centerOn(s.primary.head)
          return
      if ce.lang != "nim" and (t.contains(" " & w & "(") or t.startsWith(w & "(")) and not t.endsWith(";"):
        let ps = panesShowing(src.id)
        if ps.len > 0: focusPane(ps[0])
        let s = buf()
        if s.id == src.id:
          s.setSingle(Pos(line: i, col: max(0, l.find(w))))
          s.centerOn(s.primary.head)
        return
  info(w & " is not in this view nor declared in " & extractFilename(ce.srcPath))

proc asmHoverAt(b: Buffer, p: Pos): string =
  ## in assembly (Compiler Explorer's view, the decompiler's, a .s file): what the instruction or register is
  if b.lang == nil or b.lang.name != "Assembly" or p.line >= b.lines.len: return ""
  let line = b.lines[p.line]
  let w = b.wordAt(p)
  if w.len == 0: return ""
  var t = line.strip
  # (objdump's address in front: after it)
  let c = t.find(':')
  if c > 0 and c < 9 and t[0 ..< c].allCharsInSet(HexDigits): t = t[c + 1 .. ^1].strip
  let mn = t.split({' ', '\t'})[0].toLowerAscii
  var arm = if ceIsView(b): ce.res.arch == "arm64" else: false
  if not ceIsView(b):
    for x in t.split({' ', ',', '[', ']', '\t', '!'}):
      if x.len >= 2 and x[0] in {'x', 'w'} and x[1 .. ^1].allCharsInSet(Digits): arm = true
  if w.toLowerAscii == mn or (mn.startsWith("b.") and w.toLowerAscii in ["b", mn[2 .. ^1]]):
    let d = asmDoc(mn, arm)
    if d.len > 0: return "**" & mn & "** — " & d
  let rd = asmRegDoc(w, arm)
  if rd.len > 0: return "**" & w & "** — " & rd
  if ceIsView(b):
    for l in b.lines:
      if l == w & ":": return "**" & w & "** — a label in this view (F12 goes there)"
  ""
