# ── the decompiler, side by side: a function of a program — a Nim proc by its Nim name — as C (radare2 with
#    r2ghidra or r2dec, rizin with rz-ghidra, RetDec) or as its machine code with the Nim lines it came from
#    (objdump, llvm-objdump, radare2, rizin), in the pane beside the source or the binary; it follows the cursor to
#    the next proc. A Nim file: the program built for it (with --debugger:native, in ned's own folder) when the
#    sources changed. Whatever is installed (Termux: pkg install radare2 · binutils), decompiler.tool chooses. ──

type DcTool = enum dcNone, dcR2Ghidra, dcR2Dec, dcRzGhidra, dcRetdec, dcR2, dcRizin, dcObjdump, dcLlvmObjdump

const DcToolNames: array[DcTool, string] = ["", "r2ghidra", "r2dec", "rz-ghidra", "retdec", "radare2", "rizin",
                                            "objdump", "llvm-objdump"]

type DcView = object
  bufId, srcBufId: int          # the view, and what it follows (a Nim file, or a binary in the hex editor)
  exe: string                   # the program read
  sym: string                   # the symbol shown
  nimName: string               # (a Nim file) the proc the cursor was in
  tool: DcTool

var
  dcPlugins: set[DcTool]        # radare2's and rizin's decompiler plugins, once asked
  dcProbed = false
  dcView: DcView
  dcCache: Table[string, string]        # exe@mtime | symbol | tool → the text
  dcBusy = false
  dcWant = ""                   # (following) the proc the cursor moved into, and when
  dcWantAt: MonoTime
  dcBuilt: Table[string, string]        # a Nim main module → the program built for it

proc dcProbe() =
  ## which plugins radare2 and rizin have (in the background, once)
  if dcProbed: return
  dcProbed = true
  for (exe, tool) in [("r2", "r2"), ("rizin", "rizin")]:
    if not haveExe(exe): continue
    let (cmd, t) = (exe & " -q -c Lc -- 2>/dev/null", tool)
    capture t:                       # (each job its own tool: closures made in a loop share its variables)
      discard startJob(jkAux, cmd, rootDir, proc(j: Job) =
        let o = j.output.toLowerAscii
        if t == "r2":
          if "ghidra" in o: dcPlugins.incl dcR2Ghidra
          if "r2dec" in o or "pdd" in o: dcPlugins.incl dcR2Dec
        elif "ghidra" in o: dcPlugins.incl dcRzGhidra)

proc dcAvailable(): seq[DcTool] =
  dcProbe()
  if haveExe("r2"):
    if dcR2Ghidra in dcPlugins: result.add dcR2Ghidra
    if dcR2Dec in dcPlugins: result.add dcR2Dec
  if haveExe("rizin") and dcRzGhidra in dcPlugins: result.add dcRzGhidra
  if haveExe("retdec-decompiler"): result.add dcRetdec
  if haveExe("r2"): result.add dcR2
  if haveExe("rizin"): result.add dcRizin
  if haveExe("objdump"): result.add dcObjdump
  if haveExe("llvm-objdump"): result.add dcLlvmObjdump

proc dcChooseTool(): DcTool =
  let want = sStr("decompiler.tool")
  let have = dcAvailable()
  if want.len > 0 and want != "auto":
    for t in have:
      if DcToolNames[t] == want: return t
  if have.len > 0: have[0] else: dcNone

func dcIsC(t: DcTool): bool = t in {dcR2Ghidra, dcR2Dec, dcRzGhidra, dcRetdec}

proc dcInstallHint(): string =
  if getEnv("PREFIX").contains("com.termux"): "pkg install radare2 (or: pkg install binutils, for objdump)"
  elif defined(windows): "radare2 (radare.org) or LLVM's llvm-objdump"
  elif defined(macosx): "brew install radare2 (r2pm -ci r2ghidra: C)"
  else: "radare2 (r2pm -ci r2ghidra: C), rizin, RetDec, or binutils' objdump"

func dcHex(x: int64): string =
  let h = toHex(x).toLowerAscii.strip(trailing = false, chars = {'0'})
  "0x" & (if h.len == 0: "0" else: h)

proc dcCommand(t: DcTool, exe: string, s: BinSymbol): string =
  let addrS = dcHex(s.address)
  let stop = dcHex(s.address + max(1, s.size))
  let q = quoteShell(exe)
  case t
  of dcR2Ghidra, dcR2Dec, dcR2:
    let c = case t
            of dcR2Ghidra: "pdg"
            of dcR2Dec: "pdd"
            else: "pdf"
    "r2 -2 -q -e scr.color=0 -e asm.bytes=false -e scr.utf8=false -c " & quoteShell("s " & addrS & "; af; " & c) &
      " " & q & " 2>&1"
  of dcRzGhidra, dcRizin:
    "rizin -2 -q -e scr.color=0 -e asm.bytes=false -c " &
      quoteShell("s " & addrS & "; af; " & (if t == dcRzGhidra: "pdg" else: "pdf")) & " " & q & " 2>&1"
  of dcRetdec:
    let o = privTmp("retdec") & ".c"
    "retdec-decompiler --cleanup --silent --select-functions " & quoteShell(s.name) & " -o " & quoteShell(o) & " " & q &
      " >/dev/null 2>&1; cat " & quoteShell(o) & "; rm -f " & quoteShell(o) & "*"
  of dcObjdump, dcLlvmObjdump:
    (if t == dcObjdump: "objdump" else: "llvm-objdump") & " -d -C -l -S --no-show-raw-insn --start-address=" & addrS &
      " --stop-address=" & stop & " " & q & " 2>&1"
  of dcNone: ""

proc dcClean(t: DcTool, o: string): string =
  ## the tool's output, its noise left out
  var keep: seq[string]
  for raw in stripAnsi(o).splitLines:
    let l = raw.strip(leading = false)
    if t in {dcObjdump, dcLlvmObjdump}:
      if l.len == 0 and (keep.len == 0 or keep[^1].len == 0): continue
      if "file format" in l or l.startsWith("Disassembly of section"): continue
    if l.startsWith("WARNING:") or l.startsWith("INFO:"): continue
    keep.add (if rootDir.len > 1: l.replace(rootDir & "/", "") else: l)     # (the project's files: by their paths in it)
  while keep.len > 0 and keep[0].strip.len == 0: keep.delete(0)
  keep.join("\n")

proc dcLang(t: DcTool): Lang = (if dcIsC(t): langByName("C") else: langByName("Assembly"))

proc dcViewBuf(): Buffer =
  if dcView.bufId > 0: bufById(dcView.bufId) else: nil

proc dcShow(title, text: string, t: DcTool) =
  ## the text in the view (made, or its lines replaced), in the pane beside the source — the source keeps the focus
  let src = bufById(dcView.srcBufId)
  var v = dcViewBuf()
  if v == nil:
    let srcIdx = curBuf
    v = openScratch(title, text, dcLang(t))
    dcView.bufId = v.id
    if src != nil:
      # (beside it: the split's other pane; the source goes on being edited)
      let vi = curBuf
      curBuf = srcIdx
      if not splitOn:
        splitEditor(false)
        panes[0].bufId = src.id
        panes[0].snap = snapView(src)
        curBuf = vi
        panes[1].bufId = v.id
        focusPane(0)
      else:
        let other = 1 - activePane
        panes[other].bufId = v.id
        panes[other].snap = snapView(v)
        needRender = true
  else:
    v.setContent(text)
    v.title = title
    v.lang = dcLang(t)
    v.topLine = 0
    v.topSub = 0
    v.setSingle(Pos(line: 0, col: 0))
    if splitOn:
      for i in 0 .. 1:
        if panes[i].bufId == v.id:
          panes[i].snap.topLine = 0
          panes[i].snap.cursors = @[Cursor(anchor: Pos(), head: Pos(), goalX: -1)]
          panes[i].snap.prim = 0
  needRender = true

proc dcRun(exe: string, s: BinSymbol, label: string) =
  ## the symbol decompiled (or disassembled), cached while the program is the same
  let t = dcChooseTool()
  if t == dcNone:
    error("No decompiler or disassembler found — install " & dcInstallHint())
    return
  var stamp = ""
  try: stamp = $getLastModificationTime(exe).toUnixFloat
  except CatchableError: discard
  let key = exe & "@" & stamp & "|" & s.name & "|" & $t
  dcView.exe = exe
  dcView.sym = s.name
  dcView.tool = t
  let title = "⇄ " & label & " — " & DcToolNames[t]
  let head = (if dcIsC(t): "// " else: "; ") & label & "  ·  " & s.name & "  ·  0x" & toHex(s.address, 8).toLowerAscii &
             ", " & $s.size & " bytes  ·  " & DcToolNames[t] & "  ·  " & tildePath(exe) & "\n\n"
  if key in dcCache:
    dcShow(title, head & dcCache[key], t)
    return
  dcBusy = true
  dcShow(title, head & (if dcIsC(t): "// " else: "; ") & "decompiling…", t)
  let tt = t
  discard startJob(jkTool, dcCommand(t, exe, s), parentDir(exe), proc(j: Job) =
    dcBusy = false
    let txt = dcClean(tt, j.output)
    if txt.strip.len == 0:
      dcShow(title, head & (if dcIsC(tt): "// " else: "; ") & DcToolNames[tt] & " said nothing about it" &
             (if j.code != 0: " (exit code " & $j.code & ")" else: ""), tt)
      return
    dcCache[key] = txt
    if dcCache.len > 200: dcCache.clear()
    dcShow(title, head & txt, tt))

proc dcFindSym(info0: BinInfo, nimName, module: string): (bool, BinSymbol) =
  ## the program's code symbol for a Nim proc — the one of this module first
  var best = -1
  for i, s in info0.symbols:
    if not s.code or s.nimName != nimName or s.address == 0: continue
    if best < 0 or (s.nimModule.endsWith(module) and not info0.symbols[best].nimModule.endsWith(module)): best = i
  if best < 0:
    # (a name C kept as it is: exportc, importc'd, main)
    for i, s in info0.symbols:
      if s.code and s.name == nimName and s.address != 0: return (true, s)
    return (false, BinSymbol())
  (true, info0.symbols[best])

proc dcIsProgram(b: Buffer): bool =
  ## a Nim file that is a program of its own: `when isMainModule`, or statements at the top level
  const Decl = ["proc", "func", "method", "iterator", "converter", "template", "macro", "type", "const", "let", "var",
                "import", "include", "from", "export", "when", "static", "{.", "#", "##", "discard \"\"\""]
  for l in b.lines:
    if "isMainModule" in l: return true
    if l.len == 0 or l[0] in {' ', '\t'}: continue
    var decl = false
    for d in Decl:
      if l.startsWith(d): decl = true
    if not decl and l.strip.len > 0 and l[0] notin {'#', ')', ']', '}', '"'}: return true
  false

proc dcNimProgram(b: Buffer, then: proc(exe: string) {.closure.}) =
  ## the program for a Nim file: built (with the C compiler's debug info and Nim's names) when its sources are newer
  let main = if dcIsProgram(b): b.path else: nimProjectFile(b)
  let exe = privDir() / ("dc-" & splitFile(main).name & "-" & toHex(hash(main).uint32, 8).toLowerAscii) & ExeDot
  var newest = 0.0
  for x in bufs:
    if x.path.endsWith(".nim") and fileExists(x.path):
      try: newest = max(newest, getLastModificationTime(x.path).toUnixFloat)
      except CatchableError: discard
  var built = 0.0
  try: built = getLastModificationTime(exe).toUnixFloat
  except CatchableError: discard
  if built > 0 and built >= newest and dcBuilt.getOrDefault(main) == exe:
    then(exe)
    return
  let mode = case cfgNimMode
             of "release": " -d:release"
             of "danger": " -d:danger"
             else: ""
  let cmd = "nim c --hints:off --warnings:off --debugger:native" & mode & " --nimcache:" &
            quoteShell(privDir() / "dc-cache") & " -o:" & quoteShell(exe) & " " & quoteShell(main) & " 2>&1"
  info("Building " & extractFilename(main) & " to decompile it…")
  dcBusy = true
  discard startJob(jkTool, cmd, parentDir(main), proc(j: Job) =
    dcBusy = false
    if j.code != 0 or not fileExists(exe):
      var last = ""
      for l in j.output.splitLines:
        if "Error:" in l or (last.len == 0 and l.strip.len > 0): last = l.strip
      error("Could not build " & extractFilename(main) & (if last.len > 0: ": " & last else: " (exit code " & $j.code & ")"))
      return
    dcBuilt[main] = exe
    then(exe))

proc dcNimProc(b: Buffer, name: string) =
  ## (a Nim file) the proc `name` from the program built for it
  let module = splitFile(b.path).name
  let bid = b.id
  dcNimProgram(b, proc(exe: string) =
    var info0: BinInfo
    try: info0 = binParse(readFile(exe))
    except CatchableError as e:
      error("Cannot read " & tildePath(exe) & ": " & e.msg)
      return
    let (ok, s) = dcFindSym(info0, name, module)
    if not ok:
      warn(name & " is not in the program — Nim leaves out procs nothing calls (and some get inlined): call it " &
           "from the main module, or build in debug mode")
      return
    dcView.srcBufId = bid
    dcView.nimName = name
    dcRun(exe, s, name))

proc cmdDecompileProc() =
  ## Nim: decompile this proc (side by side)
  let b = buf()
  if b.hex != nil:
    runCmd("Hex: decompile a function…")
    return
  if b.lang.mode != lmNim or b.path.len == 0:
    info("Open a Nim file (or a program in the hex editor) — the proc at the cursor is decompiled")
    return
  if dcChooseTool() == dcNone:
    error("No decompiler or disassembler found — install " & dcInstallHint())
    return
  if b.dirty: discard b.saveBuffer()
  let name = enclosingProc(b)
  if name.len == 0:
    info("Put the cursor in a proc")
    return
  dcNimProc(b, name)

proc cmdDecompileHex(path = "") =
  ## a function of the program in the hex editor (or the file given): chosen from its code symbols — Nim's by their
  ## Nim names — and shown beside it; the view follows the hex cursor into the next function
  var b = buf()
  if path.len > 0:
    b = openFile(path)
    if b == nil: return
  if b.hex == nil:
    info("Open a program (it opens in the hex editor), then Hex: decompile a function…")
    return
  let info0 = b.hexInfo()
  var items: seq[(string, string, proc() {.closure.})]
  var order: seq[int]
  for i, s in info0.symbols:
    if s.code and s.address != 0 and s.size > 0: order.add i
  if order.len == 0:
    info(if info0.format.len == 0: "Not a program ned can read (ELF, Mach-O, PE)" else: "No functions in its symbols (stripped)")
    return
  order.sort(proc(x, y: int): int =
    let a = info0.symbols[x]
    let c = info0.symbols[y]
    cmp((c.nimName.len > 0, c.size), (a.nimName.len > 0, a.size)))
  let bid = b.id
  let exe = b.path
  for i in order:
    let s = info0.symbols[i]
    let label = if s.nimName.len > 0: s.nimName & "  (" & s.nimModule & ")" else: s.name
    let lab = if s.nimName.len > 0: s.nimName else: s.name
    let detail = $s.size & " bytes · 0x" & toHex(s.address, 8).toLowerAscii & (if s.nimName.len > 0: " · " & s.name else: "")
    capture s, lab:
      items.add (label, detail, proc() =
        dcView.srcBufId = bid
        dcView.nimName = ""
        let bb = bufById(bid)
        if bb != nil and bb.hex != nil and s.offset >= 0: bb.hexJump(s.offset)
        dcRun(exe, s, lab))
    if items.len >= 5000: break
  openActions("Decompile — " & $order.len & " functions" & (if info0.nim: " (Nim's procs by their Nim names)" else: "") &
              " · " & DcToolNames[dcChooseTool()], items)

proc cmdDecompileFile() =
  openPrompt(pPathInput, "A program to decompile (its path)", "")
  gitPromptCb = proc(p: string) =
    let full = absolutePath(expandTilde(p), rootDir)
    if not fileExists(full):
      error("No such file: " & p)
      return
    cmdDecompileHex(full)

proc dcPump() =
  ## (the main loop) the view follows the cursor: into another proc of the Nim file, another function of the binary
  if dcView.bufId <= 0 or not sBool("decompiler.follow"): return
  if dcViewBuf() == nil:
    dcView = DcView()
    return
  if dcBusy or bufs.len == 0: return
  let b = buf()
  if b.id != dcView.srcBufId: return
  var want = ""
  if b.hex != nil:
    let info0 = b.hexInfo()
    for s in info0.symbols:
      if s.code and s.offset >= 0 and b.hex.cur >= s.offset and b.hex.cur < s.offset + max(1, s.size):
        if s.name != dcView.sym: want = "\t" & s.name
        break
  elif b.lang.mode == lmNim:
    let name = enclosingProc(b)
    if name.len > 0 and name != dcView.nimName: want = name
  if want.len == 0:
    dcWant = ""
    return
  if want != dcWant:
    dcWant = want
    dcWantAt = getMonoTime()
    return
  if msSince(dcWantAt) < 450: return              # (still moving: wait until the cursor rests)
  dcWant = ""
  if want.startsWith("\t"):
    let info0 = b.hexInfo()
    for s in info0.symbols:
      if s.name == want[1 .. ^1]:
        dcRun(b.path, s, (if s.nimName.len > 0: s.nimName else: s.name))
        break
  elif not b.dirty:
    dcView.nimName = want
    dcNimProc(b, want)
