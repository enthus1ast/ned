# ════════════════════════════════════════════════════════════════════════════
#  Built-in nimsuggest client — completion, hover, definition, references,
#  signatures, outline, macro expansion and live checks with a stock `nim` install
# ════════════════════════════════════════════════════════════════════════════

proc nimUsesLsp(): bool =
  ## should Nim files go through a language server (nimlangserver, or the one set in "lsp")?
  if cfgNimIde == "off" or "nim" in lspFailed: return false
  cfgNimIde == "nimlangserver"

proc nsUsable(b: Buffer): bool =
  ## may the built-in engine ask nimsuggest about this buffer?
  b.lang != nil and b.lang.mode == lmNim and b.path.len > 0 and b.path.endsWith(".nim") and
    b.lines.len < 60000 and not b.largeOn and cfgNimIde != "off" and cfgNimSuggest and not nimUsesLsp() and
    haveExe("nimsuggest") and codeTrusted(parentDir(b.path))

proc procRssMB(pid: int): int =
  ## resident memory of a process in MB (Linux/Android /proc), 0 when unknown
  try:
    let f = readFile("/proc/" & $pid & "/statm").splitWhitespace()
    if f.len > 1: result = int(parseBiggestInt(f[1]) * sysconf(SC_PAGESIZE).int64 div (1024 * 1024))
  except CatchableError: discard

proc nsKill(s: NimSug) =
  if s.dead: return
  s.dead = true
  if s.pr.inFd >= 0: discard posix.write(s.pr.inFd, cstring("quit\n"), 5)
  killProc(s.pr)
  discard waitProc(s.pr, 150)
  closeProc(s.pr)

proc nsGet(b: Buffer, start = true): NimSug =
  if not nsUsable(b): return nil
  let proj = nimProjectFile(b)
  for s in nimSugs:
    if s.project == proj and not s.dead: return s
  if not start: return nil
  var keep: seq[NimSug]
  for s in nimSugs:
    if not s.dead: keep.add s
  nimSugs = keep
  if nimSugs.len >= 2:                     # phones have little RAM: at most two instances
    nsKill(nimSugs[0])
    nimSugs.delete(0)
  if nsProtoVer < 0:
    # protocol 4 (Nim 2.2+) adds inlay hints; ask once
    nsProtoVer = 3
    let (ok, o, _) = runFilter("nimsuggest --info:protocolVer", "", parentDir(proj), 4000)
    if ok:
      try: nsProtoVer = parseInt(o.strip.splitLines()[^1].strip)
      except ValueError: discard
  try:
    let ver = if nsProtoVer >= 4: "--v4" else: "--v3"
    var p = spawnProc(@["nimsuggest", "--stdin", ver, "--maxresults:500", proj], parentDir(proj), siPipe, erNull)
    setNonBlock(p.outFd)
    result = NimSug(project: proj, cwd: parentDir(proj), pr: p, started: getMonoTime())
    nimSugs.add result
  except CatchableError as e:
    warn("nimsuggest: " & e.msg)
    result = nil

proc nsDirtyFile(b: Buffer): string =
  ## unsaved content is passed to nimsuggest through a "dirty" copy
  if not b.dirty:
    # saved (or reloaded) since nimsuggest was last told about it: hand it the file itself once, or it goes
    # on using the text it had (its checks found errors that were already fixed)
    if b.nsDirtyAt != b.changeId and b.path.len > 0 and fileExists(b.path):
      b.nsDirtyAt = b.changeId
      return b.path
    return ""
  if b.nsDirtyPath.len == 0:
    let d = privDir() / "nimsuggest"
    try: createDir(d)
    except CatchableError: discard
    b.nsDirtyPath = d / ($b.id & "_" & extractFilename(b.path))
  if b.nsDirtyAt != b.changeId:
    try: writeFile(b.nsDirtyPath, b.allText & "\n")
    except CatchableError: return ""
    b.nsDirtyAt = b.changeId
  b.nsDirtyPath

proc nsLoc(b: Buffer, p: Pos): string =
  let d = nsDirtyFile(b)
  b.path & (if d.len > 0: ";" & d else: "") & ":" & $(p.line + 1) & ":" & $p.col

proc nsWrite(s: NimSug, cmd: string) =
  let line = cmd & "\n"
  var off = 0
  while off < line.len and s.pr.inFd >= 0:
    let n = posix.write(s.pr.inFd, unsafeAddr line[off], line.len - off)
    if n > 0: off += n
    elif n < 0 and errno == EINTR: continue
    else:
      s.dead = true
      break

proc nsPump(s: NimSug) =
  if s.dead or s.inflight.len > 0 or s.waiting.len == 0: return
  let r = s.waiting[0]
  s.waiting.delete(0)
  s.inflight.add r
  nsWrite(s, r.cmd)

proc nsRequest(b: Buffer, kind: NsKind, p: Pos, extra = ""): bool =
  ## queue a request; newer requests of the same kind replace queued ones
  let s = nsGet(b)
  if s == nil: return false
  s.usedAt = getMonoTime()
  var cmd = ""
  case kind
  of nsSug: cmd = "sug " & nsLoc(b, p)
  of nsDef, nsHover, nsAutoHover: cmd = "def " & nsLoc(b, p)
  of nsCon: cmd = "con " & nsLoc(b, p)
  of nsUse, nsRename: cmd = "use " & nsLoc(b, p)
  of nsChk:
    let d = nsDirtyFile(b)
    cmd = "chk " & b.path & (if d.len > 0: ";" & d else: "") & ":1:1"
  of nsOutline:
    let d = nsDirtyFile(b)
    cmd = "outline " & b.path & (if d.len > 0: ";" & d else: "") & ":1:1"
  of nsExpand: cmd = "expand " & nsLoc(b, p) & " " & (if extra.len > 0: extra else: "all")
  of nsInlay:
    # extra: "first/last/changeId" — the lines asked about and the buffer version they belong to
    let parts = extra.split('/')
    if nsProtoVer < 4 or parts.len != 3: return false
    var hiL = p.line + 100
    try: hiL = parseInt(parts[1])
    except ValueError: discard
    let d = nsDirtyFile(b)
    cmd = "inlayHints " & b.path & (if d.len > 0: ";" & d else: "") & ":" & $(p.line + 1) & ":0:" & $(hiL + 1) & ":0"
  var keep: seq[NsReq]
  for w in s.waiting:
    if w.kind != kind: keep.add w
  s.waiting = keep
  s.waiting.add NsReq(kind: kind, bufId: b.id, pos: p, path: b.path, extra: extra, cmd: cmd)
  nsPump(s)
  true

func skIcon(sk: string): int =
  ## nimsuggest symbol kind → LSP completion kind (for icons/colours)
  case sk
  of "skProc", "skFunc", "skMethod", "skIterator", "skConverter": 3
  of "skTemplate", "skMacro": 99
  of "skType", "skGenericParam": 7
  of "skField": 5
  of "skVar", "skLet", "skParam", "skResult", "skForVar": 6
  of "skConst", "skEnumField": 21
  of "skModule", "skPackage": 9
  else: 1

func skWord(sk: string): string =
  case sk
  of "skProc": "proc"
  of "skFunc": "func"
  of "skMethod": "method"
  of "skIterator": "iterator"
  of "skConverter": "converter"
  of "skTemplate": "template"
  of "skMacro": "macro"
  of "skType": "type"
  of "skVar": "var"
  of "skLet": "let"
  of "skConst": "const"
  of "skField": "field"
  of "skParam": "param"
  of "skEnumField": "enum"
  of "skModule": "module"
  of "skResult": "result"
  of "skForVar": "for"
  else: sk.replace("sk", "").toLowerAscii

func nsSignature(sk, qname, typ: string): string =
  ## "proc main.greet(p: Person): string" from nimsuggest fields
  let short = qname
  if typ.startsWith("proc ") or typ.startsWith("proc("):
    let rest = typ[(if typ.startsWith("proc "): 5 else: 4) .. ^1]
    return skWord(sk) & " " & short & rest
  if typ.startsWith("iterator ") or typ.startsWith("template ") or typ.startsWith("macro "):
    let sp = typ.find(' ')
    return skWord(sk) & " " & short & typ[sp + 1 .. ^1]
  if typ.len > 0: skWord(sk) & " " & short & ": " & typ else: skWord(sk) & " " & short
