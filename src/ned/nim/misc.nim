# small Nim commands that need no engine: share to the Nim Playground, switch the Nim version (choosenim or grabnim),
# browse the standard library's names, and list a project's nimble requirements to install.
proc cmdShareToPlayground() =
  ## the selection (or the whole file) on play.nim-lang.org; the link goes to the clipboard
  let b = buf()
  if not haveExe("curl"):
    error("Sharing needs curl (Termux: pkg install curl)")
    return
  let (a, e) = b.primary.range
  let code = if a != e: b.getText(a, e) else: b.lines.join("\n")
  let tmp = privDir() / "ned_share.json"
  try: writeFile(tmp, $(%*{"code": code, "compilationTarget": "c"}))
  except IOError, OSError: return
  info("Uploading to the Nim Playground…")
  discard startJob(jkTool, "curl -sS --max-time 30 -X POST -H 'Content-Type: application/json' --data-binary @" &
                   quoteShell(tmp) & " https://play.nim-lang.org/pasty", rootDir, proc(j: Job) =
    removeFile(tmp)
    let r = j.output.strip
    if j.code != 0 or r.len == 0 or ' ' in r or r.startsWith("<"):
      error("The Playground did not answer" & (if r.len > 0: ": " & r.splitLines()[0] else: ""))
      return
    let id = r.rsplit('/', maxsplit = 1)[^1]
    let url = "https://play.nim-lang.org/#pasty=" & id
    clipSet(url)
    info("Shared — the link is on the clipboard: " & url))

proc cmdSwitchNim() =
  ## choosenim or grabnim: the installed compilers, pick one
  let tool = if haveExe("choosenim"): "choosenim" elif haveExe("grabnim"): "grabnim" else: ""
  if tool.len == 0:
    info("Install choosenim or grabnim to switch Nim versions (the current one: " &
         (if haveExe("nim"): "nim on PATH" else: "none") & ")")
    return
  let listCmd = if tool == "choosenim": "choosenim versions --installed" else: "grabnim list"
  discard startJob(jkTool, listCmd & " 2>&1", rootDir, proc(j: Job) =
    var vers: seq[string]
    for l in j.output.splitLines:
      for w in l.multiReplace(("*", " "), ("[", " "), ("]", " ")).splitWhitespace:
        let v = w.strip(chars = {'#', '(', ')', ','})
        if (v.len > 2 and v[0].isDigit and v.count('.') >= 1) or v in ["devel", "stable"] or v.startsWith("nim-"):
          let vv = if v.startsWith("nim-"): v[4 .. ^1] else: v
          if vv notin vers: vers.add vv
    if vers.len == 0:
      info(tool & " lists no installed versions:\n" & j.output.strip)
      return
    var items: seq[(string, string, Action)]
    for v in vers:
      let vv = v
      capture vv:
        items.add act("Nim " & vv, tool & " " & vv, proc() =
          info("Switching to Nim " & vv & "…")
          discard startJob(jkTool, tool & " " & vv & " 2>&1", rootDir, proc(j2: Job) =
            if j2.code != 0:
              error(tool & " failed: " & j2.output.strip.splitLines()[^1])
              return
            nxLibGuessed = false
            runCmd("Nim: restart nimsuggest")
            discard startJob(jkTool, "nim --version 2>&1 | head -1", rootDir, proc(j3: Job) =
              info("Now using " & j3.output.strip))))
    openActions("Switch Nim version (" & tool & ")", items))

proc stdModulePath(m: string): string =
  ## the source file of a standard library module (with or without the `std/` prefix), looked for in the library's
  ## folders; "" when Nim's library is not known or has no such module
  let lib = nimLibDir()
  if lib.len == 0: return ""
  let short = if m.startsWith("std/"): m[4 .. ^1] else: m
  for d in ["pure", "std", "pure/collections", "system", "core", "impure", "pure/concurrency", "std/private", "posix", ""]:
    let p = lib / d / short & ".nim"
    if fileExists(p): return p
  ""

proc cmdDocsBrowser() =
  ## every name the standard library exports; pick one: its documentation, then its source
  loadNimIndex()
  if nimIndex.len == 0:
    info("The standard library index is not ready (is nim installed?)")
    return
  var items: seq[(string, string, Action)]
  var names: seq[string]
  for n in nimIndex.keys: names.add n
  names.sort()
  for n in names:
    for m in nimIndex[n]:
      let nn = n
      let mm = m
      capture nn, mm:
        items.add act(nn, mm, proc() =
          let path = stdModulePath(mm)
          if path.len == 0:
            info("Could not find " & mm & " in the standard library")
            return
          let f = nxLoad(path)
          if f == nil: return
          var md = ""
          var line = -1
          for sy in f.syms:
            if sy.name == nn and sy.exported:
              if line < 0: line = sy.line
              if md.len > 0: md.add "\n\n"
              md.add "```nim\n" & nxSig(sy) & "\n```\n" & nxRstToMd(sy.doc)
              if md.len > 6000: break
          let ob = openFile(path)
          if ob != nil and line >= 0:
            ob.readOnly = true
            ob.centerOn(Pos(line: line, col: 0))
          if md.len > 0: showHover("**" & mm & "." & nn & "**\n\n" & md))
  openActions("Standard library — " & $items.len & " names (type to search)", items)

proc nimbleRequires(path: string): seq[(string, string)] =
  ## `requires "a >= 1.0", "b"` in a .nimble file → (name, constraint)
  try:
    for l in lines(path):
      let t = l.strip
      if not t.startsWith("requires"): continue
      var i = 0
      while true:
        let a = t.find('"', i)
        if a < 0: break
        let e = t.find('"', a + 1)
        if e < 0: break
        let spec = t[a + 1 ..< e].strip
        var k = 0
        while k < spec.len and spec[k] notin {' ', '>', '<', '=', '#', '@', '~', '^'}: inc k
        result.add (spec[0 ..< k], spec[k .. ^1].strip)
        i = e + 1
  except IOError: discard

proc cmdNimbleView() =
  ## the project's dependencies with what is installed; pick one to update it
  let nf = findNimbleFile(rootDir)
  if nf.len == 0:
    info("No .nimble file in this folder")
    return
  if not haveExe("nimble"):
    error("nimble is not installed")
    return
  let reqs = nimbleRequires(nf)
  discard startJob(jkTool, "nimble list --installed 2>/dev/null", rootDir, proc(j: Job) =
    var inst: Table[string, string]
    var cur = ""
    for l in j.output.splitLines:
      let t = l.strip
      if t.len == 0 or t.startsWith("Package list format") or '{' in t: continue
      let br = t.find('[')
      let at = t.find('@')
      if at >= 0 and cur.len > 0:
        # nimble 0.16+:  name ⏎ └── @1.2.3 (checksum) …
        var e = at + 1
        while e < t.len and t[e] notin {' ', '('}: inc e
        let v = t[at + 1 ..< e]
        inst[cur] = (if cur in inst and inst[cur].len > 0: inst[cur] & ", " & v else: v)
      elif br > 0: inst[t[0 ..< br].strip.toLowerAscii] = t[br + 1 .. ^1].strip(chars = {']', ' '})   # older nimble
      elif ' ' notin t: cur = t.toLowerAscii
    var items: seq[(string, string, Action)]
    items.add act("Refresh the package list", "nimble refresh", proc() = runCommand("nimble refresh", rootDir))
    items.add act("Install everything the project needs", "nimble install -d", proc() = runCommand("nimble install -d -y", rootDir))
    for rq in reqs:
      let nm = rq[0]
      let cons = rq[1]
      if nm.toLowerAscii == "nim": continue
      let have = inst.getOrDefault(nm.toLowerAscii, "")
      capture nm:
        items.add act(nm & (if cons.len > 0: " " & cons else: ""),
                      (if have.len > 0: "installed: " & have & " · pick to install the newest" else: "not installed · pick to install"),
                      proc() = runCommand("nimble install -y " & quoteShell(nm), rootDir))
    openActions("Nimble — " & extractFilename(nf) & " (" & $reqs.len & " requirements)", items))
