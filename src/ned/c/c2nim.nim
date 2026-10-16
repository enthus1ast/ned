# ── wrap a header with c2nim (or futhark) ──

proc cWrapWith(header: string) =
  let h = if header.isAbsolute: header else: rootDir / header
  if not fileExists(h):
    error("No such file: " & header)
    return
  let (dir, name, ext) = splitFile(h)
  var outp = dir / name & ".nim"
  if fileExists(outp): outp = dir / name & "_c.nim"
  if haveExe("c2nim"):
    let cpp = ext.toLowerAscii in [".hpp", ".hh", ".hxx", ".h++"]
    let cmd = "c2nim --header --importc --stdints --skipinclude " & (if cpp: "--cpp " else: "") &
              "-o:" & quoteShell(outp) & " " & quoteShell(h)
    info("Wrapping " & extractFilename(h) & " with c2nim…")
    discard startJob(jkCheck, cmd, dir, proc(j: Job) =
      if j.code == 0 and fileExists(outp):
        discard openFile(outp)
        toast("Wrapped " & extractFilename(h) & " → " & extractFilename(outp) &
              " — check it: c2nim gets most of a header right, not all", 3)
      else:
        panelKind = pkOutput
        panelLines = @[PanelLine(text: "▶ " & cmd, sev: 5, line: -1)]
        for l in j.output.splitLines:
          if l.len > 0: panelLines.add PanelLine(text: l, line: -1)
        panelTitle = "OUTPUT"
        panelOpen = true
        error("c2nim could not wrap " & extractFilename(h) & " — see the Output panel"))
    return
  let (fok, _, _) = runFilter("nimble path futhark", "", dir, 8000)
  if fok:
    let rel = relativePath(h, dir)
    writeFile(outp, "## " & extractFilename(h) & ", wrapped by futhark when this compiles (needs libclang)\n" &
      "import futhark\n\nimportc:\n  path \"" & dir & "\"\n  \"" & rel & "\"\n")
    discard openFile(outp)
    info("futhark reads the header when " & extractFilename(outp) & " compiles")
    return
  var items: seq[(string, string, Action)]
  items.add act("Install c2nim", "nimble install c2nim — in the terminal", proc() = runInTerm("nimble install c2nim"))
  items.add act("Install futhark", "nimble install futhark — needs libclang (Termux: pkg install libclang)",
                proc() = runInTerm("nimble install futhark"))
  openActions("Wrapping a C header needs c2nim or futhark", items)

proc cmdWrapHeader() =
  var items: seq[(string, string, Action)]
  for rel in projectFiles():
    let lr = rel.toLowerAscii
    if lr.endsWith(".h") or lr.endsWith(".hpp") or lr.endsWith(".hh"):
      let r = rel
      let shown = relPath(if rel.isAbsolute: rel else: rootDir / rel)
      capture r:
        items.add act(shown, "", proc() = cWrapWith(r))
      if items.len >= 400: break
  items.add act("Another header…", "a path, e.g. /usr/include/zlib.h",
                proc() = askPath("Header to wrap", "", proc(t: string) = cWrapWith(t)))
  openActions("Wrap a C header for Nim (c2nim)", items)
