# ════════════════════════════════════════════════════════════════════════════
#  nedls — JSON-RPC over stdio: Content-Length framing (partial reads, several messages in one read),
#  replies, notifications and logging. stdout carries only the protocol; everything else goes to stderr.
# ════════════════════════════════════════════════════════════════════════════

const
  ErrParse = -32700
  ErrInvalidRequest = -32600
  ErrMethodNotFound = -32601
  ErrInvalidParams = -32602
  ErrInternal = -32603
  ErrNotInitialized = -32002
  ErrRequestCancelled = -32800
  ErrRequestFailed = -32803
  LsMaxMessage = 256 * 1024 * 1024        # a header saying more than this is not believed

type LsError = object of CatchableError
  code: int                               # the JSON-RPC error code the reply carries

var
  lsIn = ""                               # bytes read from stdin, not yet taken apart
  lsInPos = 0                             # where the next message starts in lsIn
  lsEof = false                           # stdin is closed
  lsOutBroken = false                     # the client stopped reading (stdout closed)
  lsVerbose = false                       # --verbose: every message and how long it took, on stderr
  lsLogPath = ""                          # --log:FILE: the log goes there too
  lsQueue: seq[JsonNode]                  # messages read and not handled yet
  lsNextOutId = 0                         # ids of requests nedls sends to the client

proc lsRaise(code: int, msg: string) {.noreturn.} =
  var e = newException(LsError, msg)
  e.code = code
  raise e

proc lsLog(s: string) =
  ## a line on stderr (never stdout: that is the protocol's), and in --log's file
  let line = "nedls: " & s
  try:
    stderr.writeLine(line)
    stderr.flushFile()
  except CatchableError: discard
  if lsLogPath.len > 0:
    try:
      let f = open(lsLogPath, fmAppend)
      f.writeLine(times.now().format("HH:mm:ss.fff") & " " & s)
      f.close()
    except CatchableError: discard

proc lsWriteAll(data: string) =
  ## the whole of `data` on stdout (it blocks while the client is not reading)
  var off = 0
  while off < data.len and not lsOutBroken:
    let n = posix.write(1, unsafeAddr data[off], data.len - off)
    if n > 0: off += n
    elif n < 0 and errno == EINTR: continue
    elif n < 0 and errno == EAGAIN:
      var pfd = TPollfd(fd: 1, events: POLLOUT)
      discard poll(addr pfd, 1, 1000)
    else:
      lsOutBroken = true

proc lsSendText(body: string) =
  lsWriteAll("Content-Length: " & $body.len & "\r\n\r\n" & body)

proc lsSend(j: JsonNode) = lsSendText($j)

proc lsReply(id: JsonNode, res: JsonNode) =
  lsSendText("{\"jsonrpc\":\"2.0\",\"id\":" & $id & ",\"result\":" & (if res == nil: "null" else: $res) & "}")

proc lsReplyRaw(id: JsonNode, resText: string) =
  ## a reply whose result is already JSON text (big arrays are written without a JsonNode per number)
  lsSendText("{\"jsonrpc\":\"2.0\",\"id\":" & $id & ",\"result\":" & resText & "}")

proc lsReplyError(id: JsonNode, code: int, msg: string) =
  lsSend(%*{"jsonrpc": "2.0", "id": (if id == nil: newJNull() else: id),
            "error": {"code": code, "message": msg}})

proc lsNotify(meth: string, params: JsonNode) =
  lsSend(%*{"jsonrpc": "2.0", "method": meth, "params": params})

proc lsRequestOut(meth: string, params: JsonNode) =
  ## a request to the client (its answer is read and dropped)
  inc lsNextOutId
  lsSend(%*{"jsonrpc": "2.0", "id": "nedls-" & $lsNextOutId, "method": meth, "params": params})

proc lsShowMessage(typ: int, msg: string) =
  ## window/showMessage — 1 error, 2 warning, 3 info
  lsNotify("window/showMessage", %*{"type": typ, "message": "nedls: " & msg})

proc lsLogMessage(typ: int, msg: string) =
  lsNotify("window/logMessage", %*{"type": typ, "message": msg})

proc lsReadInput(): bool =
  ## what stdin has now (poll said it is readable); false at its end
  var tmp: array[65536, char]
  while true:
    let n = posix.read(0, addr tmp[0], tmp.len)
    if n > 0:
      let old = lsIn.len
      lsIn.setLen(old + n)
      copyMem(addr lsIn[old], addr tmp[0], n)
      return true
    if n == 0: return false
    if errno == EINTR: continue
    return errno == EAGAIN

proc lsHeaderEnd(s: string, start: int): (int, int) =
  ## where the header block that starts at `start` ends: (index of the separator, its length); (-1, 0) not yet
  let a = s.find("\r\n\r\n", start)
  let b = s.find("\n\n", start)
  if a >= 0 and (b < 0 or a <= b): return (a, 4)
  if b >= 0: return (b, 2)
  (-1, 0)

proc lsTakeMessages() =
  ## the complete messages in lsIn, parsed and queued; a broken header or body is answered and skipped
  while true:
    while lsInPos < lsIn.len and lsIn[lsInPos] in {'\r', '\n', ' ', '\t'}: inc lsInPos
    if lsInPos >= lsIn.len: break
    let (he, sepLen) = lsHeaderEnd(lsIn, lsInPos)
    if he < 0:
      if lsIn.len - lsInPos > 65536:
        # no header end in sight: not the protocol — skip to the next header we can find
        lsLog("garbage on stdin (" & $(lsIn.len - lsInPos) & " bytes without a header) — skipped")
        let k = lsIn.find("Content-Length", lsInPos + 1)
        lsInPos = if k < 0: lsIn.len else: k
        continue
      break
    var length = -1
    for raw in lsIn[lsInPos ..< he].split('\n'):
      let h = raw.strip
      let c = h.find(':')
      if c > 0 and cmpIgnoreCase(h[0 ..< c].strip, "Content-Length") == 0:
        try: length = parseInt(h[c + 1 .. ^1].strip)
        except ValueError: length = -1
    let bodyAt = he + sepLen
    if length < 0 or length > LsMaxMessage:
      lsLog("a message without a usable Content-Length — skipped")
      lsReplyError(newJNull(), ErrParse, "missing or invalid Content-Length header")
      lsInPos = bodyAt
      continue
    if lsIn.len - bodyAt < length: break           # (the rest of the body is still on its way)
    let body = lsIn[bodyAt ..< bodyAt + length]
    lsInPos = bodyAt + length
    try:
      let j = parseJson(body)
      if j.kind == JArray:
        for x in j.elems: lsQueue.add x           # (a batch: each one on its own)
      else: lsQueue.add j
    except CatchableError as e:
      lsLog("unreadable JSON: " & e.msg)
      lsReplyError(newJNull(), ErrParse, "parse error: " & e.msg)
  if lsInPos > 0 and (lsInPos >= lsIn.len or lsInPos > 1_048_576):
    lsIn = lsIn[lsInPos .. ^1]
    lsInPos = 0
