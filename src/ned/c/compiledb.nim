# ── compile_commands.json for clangd ──

proc cmdCompileCommands() =
  ## the C compiler's commands for this project, as Nim builds it, where clangd finds them
  let b = buf()
  let main = if b.lang != nil and b.lang.mode == lmNim and b.path.len > 0: nimProjectFile(b) else: ""
  if main.len == 0 or not fileExists(main):
    info("Open a Nim file of the project first")
    return
  if not haveExe("nim"):
    error("nim is not installed")
    return
  let nc = stateDir() / "clangd" / fnv(main)
  let backend = if cfgNimTarget in ["cpp", "objc"]: cfgNimTarget else: "c"
  let cmd = "nim " & backend & " --compileOnly --hints:off --nimcache:" & quoteShell(nc) & " " &
            cfgNimFlags & " " & quoteShell(main)
  let root = if rootDir.len > 0: rootDir else: parentDir(main)
  info("Asking Nim for the C compiler's commands…")
  discard startJob(jkCheck, cmd, parentDir(main), proc(j: Job) =
    let jf = nc / splitFile(main).name & ".json"
    if j.code != 0 or not fileExists(jf):
      error("Nim could not compile " & extractFilename(main) & " — see Run › Check")
      return
    try:
      let d = parseFile(jf)
      var arr = newJArray()
      var own = 0
      for c in d{"compile"}:
        if c.kind != JArray or c.len < 2: continue
        let file = c[0].getStr
        arr.add %*{"directory": parentDir(main), "command": c[1].getStr, "file": file}
        if not file.startsWith(nc): inc own
      writeFile(root / "compile_commands.json", arr.pretty)
      toast("Wrote compile_commands.json: " & $arr.len & " C files (" & $own & " of yours) — clangd now knows the " &
            "include folders and flags", 3)
      for s in servers:
        if s.langId in ["c", "cpp"] and not s.dead: info("Restart the C language server to read it (palette › Restart language server)")
    except CatchableError as e:
      error("compile_commands.json: " & e.msg))

proc ffiTypeAct(id: int, at, e: Pos, typ: string): Action =
  ## a wrapper's type → the one the C header asks for
  result = proc() =
    let b = bufById(id)
    if b == nil: return
    discard b.replaceText(at, e, typ)
    ffiCheck(b)

proc ffiVarargsAct(id, line: int): Action =
  result = proc() =
    let b = bufById(id)
    if b == nil: return
    for l in line .. min(b.lines.high, line + 8):
      let k = b.lines[l].find("{.")
      if k >= 0:
        discard b.replaceText(Pos(line: l, col: k + 2), Pos(line: l, col: k + 2), "varargs, ")
        ffiCheck(b)
        return
