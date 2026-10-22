# ── a file's encoding: reopen it as another, save it as another (the status bar's UTF-8 · Windows-1252 …) ──

proc encodingChoices(): seq[string] =
  ## ned's own, and iconv's when it is installed
  for e in BuiltinEncodings: result.add e
  if findExe("iconv").len > 0:
    for e in IconvEncodings: result.add e

proc reopenWithEncoding(b: Buffer, enc: string) =
  ## the file read again from disk as `enc` (its unsaved edits go: asked first)
  if b.path.len == 0 or not fileExists(b.path):
    info("Not a file on disk — Save with encoding… sets how it is written")
    return
  proc doIt() =
    var bytes: string
    try: bytes = readFile(b.path)
    except CatchableError as e:
      error("Cannot read " & b.name & ": " & e.msg)
      return
    let (ok, t) = decodeFile(bytes, enc)
    if not ok and enc notin [EncUtf16Le, EncUtf16Be]:
      error(b.name & " cannot be read as " & encLabel(enc) &
            (if enc notin BuiltinEncodings and findExe("iconv").len == 0: " (iconv is not installed)" else: ""))
      return
    var tmp = newBuffer()
    tmp.setContent(t)
    b.beginEdit()
    discard b.replaceText(Pos(), Pos(line: b.lines.high, col: b.lines[^1].len), tmp.lines.join("\n"))
    b.endEdit()
    b.crlf = tmp.crlf
    b.noEol = tmp.noEol
    b.enc = enc
    b.savedSeq = b.topSeq()
    (b.mtime, b.fsize) = fileStamp(b.path)
    b.hlValid = 0
    needRender = true
    info(b.name & " read as " & encLabel(enc) & (if ok: "" else: " — some bytes are not (shown as �)"))
  if b.dirty:
    askConfirm(b.name & " has unsaved edits — reading it again loses them. (r)eopen (c)ancel", proc(c: char) =
      if c in {'r', 'y'}: doIt())
  else: doIt()

proc saveWithEncoding(b: Buffer, enc: string) =
  let old = b.enc
  b.enc = enc
  if b.saveBuffer(force = true): info("Saved " & b.name & " as " & encLabel(enc))
  else: b.enc = old

proc cmdEncodingPick(reopen: bool) =
  let b = buf()
  var items: seq[(string, string, Action)]
  for e in encodingChoices():
    let enc = e
    let cur = if enc == b.enc: "● " else: ""
    capture enc:
      items.add act(cur & encLabel(enc), (if enc in BuiltinEncodings: "" else: "iconv"), proc() =
        if reopen: reopenWithEncoding(buf(), enc) else: saveWithEncoding(buf(), enc))
  openActions((if reopen: "Reopen " & b.name & " with encoding" else: "Save " & b.name & " with encoding") &
              " (now " & encLabel(b.enc) & ")", items)

proc cmdEncodingMenu() =
  let b = buf()
  openActions("Encoding of " & b.name & ": " & encLabel(b.enc), @[
    act("Reopen with encoding…", "read the file again as another encoding", proc() = cmdEncodingPick(true)),
    act("Save with encoding…", "write it in another encoding from now on", proc() = cmdEncodingPick(false))])
