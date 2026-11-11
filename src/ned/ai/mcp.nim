# ── MCP: Model Context Protocol servers give the agent more tools ("ai.mcpServers") ──

type
  McpTool = object
    name, desc: string
    schema: JsonNode
  McpRes = object                  # a resource the server offers (resources/list)
    uri, name, desc, mime: string
  McpPrompt = object               # a prompt template (prompts/list): a /server:name command in the chat
    name, desc: string
    args: seq[(string, string, bool)]   # name, description, required
  McpCb = proc(res: JsonNode, err: string) {.closure.}
  McpServer = ref object
    name: string
    cmd: seq[string]
    pr: Proc
    inFd, outFd, errFd: cint
    rbuf, wbuf, errPart: string
    wpos: int                      # how much of wbuf is written (pipeWrite)
    errTail: seq[string]
    nextId: int
    pending: Table[int, (McpCb, MonoTime)]
    tools: seq[McpTool]
    resources: seq[McpRes]
    prompts: seq[McpPrompt]
    hasResources, hasPrompts: bool
    state: string                  # starting · ready · failed: … · stopped
    dead, reaped: bool
    startedAt: MonoTime

var
  mcpServers: seq[McpServer]
  mcpStarted = false
  mcpSpecSeen = ""                 # the setting they were started from
  mcpWaitReq = false               # a request waits for the servers to list their tools

proc mcpFlush(s: McpServer) =
  ## writes as much of the server's waiting output as its pipe takes now (the pipe never blocks), keeps the rest for the
  ## next time; a failed write marks the server dead
  if not pipeWrite(s.inFd, s.wbuf, s.wpos): s.dead = true

proc mcpSend(s: McpServer, j: JsonNode) =
  ## queues one JSON message for the server — one line, as MCP over stdio wants — and writes what it can
  if s.dead: return
  s.wbuf.add $j
  s.wbuf.add '\n'                           # MCP over stdio: one JSON message per line
  s.mcpFlush()

proc mcpRequest(s: McpServer, meth: string, params: JsonNode, cb: McpCb) =
  ## sends a JSON-RPC request with a new id and keeps `cb` to call with the result or the error when the answer comes
  ## (or when the server stops, or does not answer)
  inc s.nextId
  s.pending[s.nextId] = (cb, getMonoTime())
  s.mcpSend(%*{"jsonrpc": "2.0", "id": s.nextId, "method": meth, "params": params})

proc mcpNotify(s: McpServer, meth: string, params: JsonNode) =
  ## sends a JSON-RPC notification, which has no id and gets no answer
  s.mcpSend(%*{"jsonrpc": "2.0", "method": meth, "params": params})

proc mcpListTools(s: McpServer, cursor = "") =
  ## asks the server for its tools, page by page, and keeps their names, descriptions and input schemas; when the list
  ## is complete the server is "ready", and an error marks it failed
  if cursor.len == 0: s.tools.setLen(0)
  let params = if cursor.len > 0: %*{"cursor": cursor} else: newJObject()
  s.mcpRequest("tools/list", params, proc(res: JsonNode, err: string) =
    if err.len > 0:
      s.state = "failed: " & err
      return
    for t in jitems(res{"tools"}):
      let n = t{"name"}.getStr
      if n.len == 0: continue
      var sc = t{"inputSchema"}
      if sc == nil or sc.kind != JObject: sc = %*{"type": "object", "properties": {}}
      s.tools.add McpTool(name: n, desc: t{"description"}.getStr, schema: sc)
    let nc = res{"nextCursor"}.getStr
    if nc.len > 0: s.mcpListTools(nc)
    else:
      s.state = "ready"
      needRender = true)

proc mcpListResources(s: McpServer, cursor = "") =
  ## asks the server for the resources it offers, page by page (an error is ignored)
  if cursor.len == 0: s.resources.setLen(0)
  let params = if cursor.len > 0: %*{"cursor": cursor} else: newJObject()
  s.mcpRequest("resources/list", params, proc(res: JsonNode, err: string) =
    if err.len > 0: return
    for r in jitems(res{"resources"}):
      if r{"uri"}.getStr.len == 0: continue
      s.resources.add McpRes(uri: r{"uri"}.getStr, name: r{"name"}.getStr, desc: r{"description"}.getStr,
                             mime: r{"mimeType"}.getStr)
    let nc = res{"nextCursor"}.getStr
    if nc.len > 0: s.mcpListResources(nc)
    needRender = true)

proc mcpListPrompts(s: McpServer, cursor = "") =
  ## asks the server for its prompt templates and their arguments, page by page (an error is ignored); they become
  ## /server:name commands
  if cursor.len == 0: s.prompts.setLen(0)
  let params = if cursor.len > 0: %*{"cursor": cursor} else: newJObject()
  s.mcpRequest("prompts/list", params, proc(res: JsonNode, err: string) =
    if err.len > 0: return
    for p in jitems(res{"prompts"}):
      if p{"name"}.getStr.len == 0: continue
      var pr = McpPrompt(name: p{"name"}.getStr, desc: p{"description"}.getStr)
      for a in jitems(p{"arguments"}):
        pr.args.add (a{"name"}.getStr, a{"description"}.getStr, a{"required"}.getBool(false))
      s.prompts.add pr
    let nc = res{"nextCursor"}.getStr
    if nc.len > 0: s.mcpListPrompts(nc)
    needRender = true)

proc mcpHandle(s: McpServer, j: JsonNode) =
  ## one message from the server: an answer calls the callback of the request with that id; a request from the server is
  ## answered (ping, roots/list with the project folder, anything else "not supported"); a notice that its tools,
  ## resources or prompts changed asks for them again
  if j.kind != JObject: return
  if j.hasKey("id") and (j.hasKey("result") or j.hasKey("error")) and not j.hasKey("method"):
    let id = j["id"].getInt
    if id in s.pending:
      let (cb, _) = s.pending[id]
      s.pending.del id
      let e = j{"error"}
      cb(j{"result"}, (if e != nil and e.kind == JObject: (let m = e{"message"}.getStr; if m.len > 0: m else: "error") else: ""))
    return
  let meth = j{"method"}.getStr
  if j.hasKey("id"):                         # the server asks something of ned
    case meth
    of "ping": s.mcpSend(%*{"jsonrpc": "2.0", "id": j["id"], "result": {}})
    of "roots/list":
      s.mcpSend(%*{"jsonrpc": "2.0", "id": j["id"], "result": {"roots": [{"uri": uriFromPath(rootDir),
                                                                           "name": extractFilename(rootDir)}]}})
    else: s.mcpSend(%*{"jsonrpc": "2.0", "id": j["id"], "error": {"code": -32601, "message": "not supported by ned"}})
  elif meth == "notifications/tools/list_changed": s.mcpListTools()
  elif meth == "notifications/resources/list_changed": s.mcpListResources()
  elif meth == "notifications/prompts/list_changed": s.mcpListPrompts()

proc mcpRead(s: McpServer) =
  ## reads what the server has written to its output, all that is there, and handles each complete line that is JSON;
  ## the end of the output means the server has died
  var tmp: array[65536, char]
  while true:
    let n = posix.read(s.outFd, addr tmp[0], tmp.len)
    if n > 0:
      let old = s.rbuf.len
      s.rbuf.setLen(old + n)
      copyMem(addr s.rbuf[old], addr tmp[0], n)
    elif n == 0:
      s.dead = true
      break
    else: break
  eachLine(s.rbuf, raw):
    let line = raw.strip
    if line.len > 0 and line[0] == '{':
      try: mcpHandle(s, parseJson(line))
      except CatchableError: discard

proc mcpReadErr(s: McpServer) =
  ## reads the server's error output into a short list of its last lines (each cut to 300 characters, about 40 kept),
  ## shown when it fails
  var tmp: array[16384, char]
  while true:
    let n = posix.read(s.errFd, addr tmp[0], tmp.len)
    if n <= 0: break
    var chunk = newString(n)
    copyMem(addr chunk[0], addr tmp[0], n)
    let parts = (s.errPart & chunk).split('\n')
    for k in 0 ..< parts.high:
      let l = stripAnsi(parts[k]).strip
      if l.len > 0: s.errTail.add (if l.len > 300: l[0 ..< 300] else: l)
    s.errPart = parts[^1]
    if s.errTail.len > 60: s.errTail = s.errTail[^40 .. ^1]

proc mcpStart(name: string, spec: JsonNode) =
  ## {"command": ["npx", "-y", "pkg"]} or {"command": "npx", "args": [...]} (Claude Desktop's form), "env": {…}
  var cmd: seq[string]
  let c = spec{"command"}
  if c != nil and c.kind == JString:
    cmd = @[c.getStr]
    for a in jitems(spec{"args"}): cmd.add a.getStr
  else:
    for a in jitems(c): cmd.add a.getStr
  let s = McpServer(name: name, cmd: cmd, state: "starting", startedAt: getMonoTime(), inFd: -1, outFd: -1, errFd: -1)
  mcpServers.add s
  if cmd.len == 0 or findExe(cmd[0]).len == 0:
    s.state = "failed: " & (if cmd.len == 0: "no command" else: cmd[0] & " not found")
    s.dead = true
    return
  # its environment (API tokens …) goes to the child only — never on a command line
  var saved: seq[(string, string, bool)]
  let env = spec{"env"}
  if env != nil and env.kind == JObject:
    for k, v in env:
      saved.add (k, getEnv(k), existsEnv(k))
      putEnv(k, v.getStr)
  try:
    var p = spawnProc(cmd, rootDir, siPipe, erPipe)
    s.pr = p
    s.inFd = p.inFd
    s.outFd = p.outFd
    s.errFd = p.errFd
    s.pr.inFd = -1
    s.pr.outFd = -1
    s.pr.errFd = -1
    setNonBlock(s.inFd); setNonBlock(s.outFd); setNonBlock(s.errFd)
  except CatchableError as e:
    s.state = "failed: " & e.msg
    s.dead = true
  for (k, v, had) in saved:
    if had: putEnv(k, v) else: delEnv(k)
  if s.dead: return
  s.mcpRequest("initialize", %*{"protocolVersion": "2025-06-18", "capabilities": {"roots": {"listChanged": false}},
                                "clientInfo": {"name": AppName, "version": Version}}, proc(res: JsonNode, err: string) =
    if err.len > 0:
      s.state = "failed: " & err
      return
    s.mcpNotify("notifications/initialized", newJObject())
    let caps = res{"capabilities"}
    s.hasResources = caps != nil and caps{"resources"} != nil
    s.hasPrompts = caps != nil and caps{"prompts"} != nil
    if s.hasResources: s.mcpListResources()
    if s.hasPrompts: s.mcpListPrompts()
    if caps != nil and caps.kind == JObject and caps{"tools"} == nil and (s.hasResources or s.hasPrompts):
      s.state = "ready"                        # resources or prompts only: no tools to list
      needRender = true
    else: s.mcpListTools())

proc mcpStopAll() =
  ## stops all MCP servers: asks each process group to end, waits a moment, closes the pipes and forgets the servers
  for s in mcpServers:
    s.state = "stopped"
    if s.pr.pid > 0:
      discard posix.kill(Pid(-s.pr.pid), SIGTERM)
      discard waitProc(s.pr, 150)
    closeFd(s.inFd)
    closeFd(s.outFd)
    closeFd(s.errFd)
  mcpServers.setLen(0)
  mcpStarted = false

proc mcpStartAll() =
  ## the servers in ai.mcpServers, once (again after the setting changed)
  let spec = settingNode("ai.mcpServers")
  let key = if spec == nil: "" else: $spec
  if mcpStarted and key == mcpSpecSeen: return
  if mcpStarted: mcpStopAll()
  mcpStarted = true
  mcpSpecSeen = key
  if spec == nil or spec.kind != JObject: return
  for name, sp in spec:
    if sp.kind == JObject and not sp{"disabled"}.getBool(false): mcpStart(name, sp)

proc mcpStarting(): bool =
  ## whether a server is still starting up and has been for less than 20 seconds, so that a request waits for its tools
  for s in mcpServers:
    if s.state == "starting" and not s.dead and msSince(s.startedAt) < 20_000: return true

func mcpSafe(s: string): string =
  ## the name with every character that is not a letter, digit, `_` or `-` turned into `_`, as tool names require
  for c in s:
    result.add (if c.isAlphaNumeric or c in {'_', '-'}: c else: '_')

func mcpToolName(server, tool: string): string =
  ## the name the model sees for a server's tool: mcp__server__tool, 64 characters at most
  result = "mcp__" & mcpSafe(server) & "__" & mcpSafe(tool)
  if result.len > 64: result = result[0 ..< 64]

const McpReadRes = "\x01read_resource"     # (ned's own tool for a server's resources)

func mcpHasTool(s: McpServer, name: string): bool =
  ## whether the server has a tool of that name
  for t in s.tools:
    if t.name == name: return true
  false

proc mcpTools(): seq[(string, string, JsonNode)] =
  ## the tools of the ready servers, for the model: (name, description, input schema); a server with
  ## resources also gets read_resource, its resources listed in the description
  for s in mcpServers:
    if s.state != "ready" or s.dead: continue
    for t in s.tools:
      result.add (mcpToolName(s.name, t.name), "[" & s.name & " MCP server] " & t.desc, t.schema)
    if s.resources.len > 0 and not s.mcpHasTool("read_resource"):
      var d = "[" & s.name & " MCP server] Read one of this server's resources by its URI. Resources:"
      for i, r in s.resources:
        if i >= 60:
          d.add "\n… " & $(s.resources.len - 60) & " more"
          break
        d.add "\n- " & r.uri & (if r.name.len > 0: " — " & r.name else: "") &
              (if r.desc.len > 0: ": " & truncTo(r.desc.splitLines()[0], 80) else: "")
      result.add (mcpToolName(s.name, "read_resource"), d,
                  %*{"type": "object", "properties": {"uri": {"type": "string", "description": "the resource's URI"}},
                     "required": ["uri"]})
  for t in plugAiTools:                           # (the plugins' tools)
    result.add (t.name, "[" & t.plugin & " plugin] " & t.desc, t.schema)

proc mcpFind(full: string): (McpServer, string) =
  ## the server and the tool's own name (or the read-resource marker) for a name the model used; nil when no server has
  ## it
  for s in mcpServers:
    for t in s.tools:
      if mcpToolName(s.name, t.name) == full: return (s, t.name)
    if s.resources.len > 0 and mcpToolName(s.name, "read_resource") == full: return (s, McpReadRes)
  (nil, "")

proc mcpResourceText(res: JsonNode): string =
  ## resources/read: the text of each part (binary parts summarised)
  for c in jitems(res{"contents"}):
    if c{"text"} != nil: result.add c{"text"}.getStr & "\n"
    elif c{"blob"} != nil:
      result.add "[" & (if c{"mimeType"}.getStr.len > 0: c{"mimeType"}.getStr else: "binary") & ", " &
                 $(c{"blob"}.getStr.len * 3 div 4) & " bytes]\n"
  result.strip(leading = false)

proc mcpResultText(res: JsonNode): string =
  ## the text of a tool call's result: each text part, images and audio as a note with their size, a resource by its
  ## text or address, a link by its address, or the structured result as JSON when there is no other
  for c in jitems(res{"content"}):
    case c{"type"}.getStr
    of "text": result.add c{"text"}.getStr & "\n"
    of "image", "audio": result.add "[" & c{"type"}.getStr & " " & c{"mimeType"}.getStr & ", " & $c{"data"}.getStr.len & " bytes]\n"
    of "resource":
      let r = c{"resource"}
      result.add (if r{"text"}.getStr.len > 0: r{"text"}.getStr else: r{"uri"}.getStr) & "\n"
    of "resource_link": result.add c{"uri"}.getStr & "\n"
    else: discard
  if result.len == 0 and res{"structuredContent"} != nil: result = res["structuredContent"].pretty
  result = result.strip(leading = false)

proc mcpPump(ready: HashSet[cint]) =
  ## read and write the MCP servers; ones that ended say why; calls that never came back time out
  var keep: seq[McpServer]
  for s in mcpServers:
    if not s.dead:
      if s.errFd in ready: mcpReadErr(s)
      if s.outFd in ready: mcpRead(s)
      if s.wbuf.len > 0: s.mcpFlush()
      var late: seq[int]
      for id, (_, at) in s.pending:
        if msSince(at) > 120_000: late.add id
      for id in late:
        let (cb, _) = s.pending[id]
        s.pending.del id
        cb(nil, "no answer from " & s.name & " in 2 minutes")
    if s.dead and not s.reaped and s.state != "stopped":
      s.reaped = true
      if s.errFd >= 0: mcpReadErr(s)
      if not s.state.startsWith("failed"):
        s.state = "failed: " & (if s.errTail.len > 0: s.errTail[^1] else: "it exited")
      for id, (cb, _) in s.pending: cb(nil, s.name & " stopped")
      s.pending.clear()
      if s.pr.pid > 0: discard waitProc(s.pr, 50)
      closeFd(s.inFd)
      closeFd(s.outFd)
      closeFd(s.errFd)
      s.inFd = -1
      s.outFd = -1
      s.errFd = -1
      needRender = true
    keep.add s
  mcpServers = keep

proc mcpFds(fds: var seq[TPollfd]) =
  ## adds the servers' pipes to the list the main loop waits on: their output and error output for reading, and their
  ## input when there is something to write
  for s in mcpServers:
    if s.dead or s.outFd < 0: continue
    fds.add TPollfd(fd: s.outFd, events: POLLIN)
    fds.add TPollfd(fd: s.errFd, events: POLLIN)
    if s.wbuf.len > 0: fds.add TPollfd(fd: s.inFd, events: POLLOUT)

proc cmdMcpServers() =
  ## AI: MCP servers — starts the servers if they are not, and lists them with their state and the numbers of tools,
  ## resources and prompts; choosing one shows its command, tools, resources, prompts and last error lines, and there is
  ## an entry to restart them all. With none set it says how to add one in ai.mcpServers
  mcpStartAll()
  let spec = settingNode("ai.mcpServers")
  if mcpServers.len == 0:
    info("No MCP servers yet — settings › ai.mcpServers: {\"github\": {\"command\": \"npx\", \"args\": " &
         "[\"-y\", \"@modelcontextprotocol/server-github\"], \"env\": {\"GITHUB_TOKEN\": \"…\"}}}")
    return
  discard spec
  var items: seq[(string, string, Action)]
  for s in mcpServers:
    let st = s.state.strip
    let label = (if st == "ready": "● " elif st == "starting": "◌ " else: "✗ ") & s.name
    let detail = if st == "ready": $s.tools.len & " tool(s)" &
                                  (if s.resources.len > 0: " · " & $s.resources.len & " resource(s)" else: "") &
                                  (if s.prompts.len > 0: " · " & $s.prompts.len & " prompt(s)" else: "") else: st
    let srv = s
    capture srv:
      items.add act(label, detail, proc() =
        var body = srv.cmd.join(" ") & "\n\n"
        if srv.tools.len > 0:
          for t in srv.tools: body.add "• " & t.name & (if t.desc.len > 0: " — " & truncTo(t.desc.splitLines()[0], 70) else: "") & "\n"
        else: body.add srv.state.strip & "\n"
        if srv.resources.len > 0:
          body.add "\nResources (@" & srv.name & ":<uri> in the chat attaches one):\n"
          for r in srv.resources: body.add "• " & r.uri & (if r.name.len > 0: " — " & r.name else: "") & "\n"
        if srv.prompts.len > 0:
          body.add "\nPrompts (/" & srv.name & ":<name> in the chat):\n"
          for p in srv.prompts:
            var a: seq[string]
            for (n, _, req) in p.args: a.add (if req: n else: "[" & n & "]")
            body.add "• /" & srv.name & ":" & p.name & (if a.len > 0: " " & a.join(" ") else: "") &
                     (if p.desc.len > 0: " — " & truncTo(p.desc.splitLines()[0], 60) else: "") & "\n"
        if srv.errTail.len > 0: body.add "\n" & srv.errTail[max(0, srv.errTail.len - 4) .. ^1].join("\n")
        openDialog("MCP server " & srv.name, body, @[("OK", 'y')], proc(c: char) = discard))
  items.add act("↻ Restart the MCP servers", "", proc() =
    mcpStopAll()
    mcpStartAll()
    info("Restarting the MCP servers…"))
  openActions("MCP servers (" & $mcpServers.len & ")", items)
