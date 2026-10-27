# ── the change an edit/write call would make, as a unified diff ──

var aiDiffCache = initTable[string, string]()

proc diffForCall(c: AiCall): string =
  if c.name notin ["edit_file", "write_file"]: return ""
  if c.diff.len > 0: return c.diff
  let key = c.id & "/" & $c.args.len
  if key in aiDiffCache: return aiDiffCache[key]
  var j: JsonNode
  try: j = parseJson(if c.args.strip.len == 0: "{}" else: c.args)
  except CatchableError: return ""
  let path = absProjectPath(j{"path"}.getStr)
  let rel = relPath(path)
  var old = ""
  let bi = bufIndexByPath(path)
  if bi >= 0: old = bufs[bi].allText
  elif fileExists(path):
    try: old = readFile(path)
    except CatchableError: discard
  var nw = ""
  if c.name == "write_file": nw = j{"content"}.getStr
  else:
    let oldT = j{"old_text"}.getStr
    let newT = j{"new_text"}.getStr
    if oldT.len == 0: nw = old & (if old.len > 0 and not old.endsWith("\n"): "\n" else: "") & newT
    else:
      let i = old.find(oldT)
      if i < 0 or old.find(oldT, i + 1) >= 0:
        result = "(old_text " & (if i < 0: "not found" else: "is not unique") & " in " & rel & ")"
        aiDiffCache[key] = result
        return
      nw = old[0 ..< i] & newT & old[i + oldT.len .. ^1]
  result = unifiedDiff(textLines(old), textLines(nw), (if old.len == 0: "/dev/null" else: "a/" & rel), "b/" & rel)
  if result.len == 0: result = "(no change)"
  aiDiffCache[key] = result

proc showCallDiff(mi, ci: int) =
  if mi >= aiMsgs.len or ci >= aiMsgs[mi].calls.len: return
  let c = aiMsgs[mi].calls[ci]
  let d = diffForCall(c)
  if d.len == 0:
    info("No diff for this action")
    return
  var title = "AI change"
  try: title = "AI change: " & parseJson(c.args){"path"}.getStr
  except CatchableError: discard
  discard openScratch(title, d, langByName("Diff"))

# ── @mentions ──

proc termTail(n: int): string =
  if terms.len == 0: return ""
  let t = terms[clamp(curTerm, 0, terms.high)]
  var rows: seq[string]
  for r in t.sb & t.scr:
    var s = ""
    for c in r:
      if c.ch != 0: s.addUtf8(int(c.ch))
    rows.add s.strip(leading = false)
  while rows.len > 0 and rows[^1].len == 0: rows.setLen(rows.len - 1)
  rows[max(0, rows.len - n) .. ^1].join("\n")

proc gitText(args: string): string =
  let root = gitHome()
  if root.len == 0: return ""
  let (ok, o, _) = runFilter("git --no-pager " & args, "", root, 8000)
  if not ok: return ""
  if o.len > 60_000: o[0 ..< 60_000] & "\n… (diff truncated)" else: o

proc problemsText(): string =
  var o: seq[string]
  var paths: seq[string]
  for k in diagsLsp.keys: paths.add k
  for k in diagsBuild.keys:
    if k notin paths: paths.add k
  for path in paths:
    for d in diagsFor(path):
      if d.sev <= 2:
        o.add relPath(path) & ":" & $(d.line + 1) & ":" & $(d.col + 1) & ": " &
              (if d.sev == 1: "error" else: "warning") & ": " & d.msg.splitLines()[0]
      if o.len >= 200: break
  o.join("\n")

const AiMentions = ["@file", "@selection", "@diff", "@staged", "@problems", "@terminal", "@tree"]

proc mentionNames(): seq[string] =
  ## @mentions, the MCP servers' resources included (@server:uri)
  for m in AiMentions: result.add m
  for s in mcpServers:
    if not s.dead:
      for r in s.resources: result.add "@" & s.name & ":" & r.uri

proc aiMentionedPics(t: string, quiet = false): seq[string] =
  ## the pictures a message names (@shot.png, @~/storage/shared/Pictures/Screenshots/x.png): they go with it, for a
  ## model that reads pictures; one that cannot go is said why
  for w0 in t.splitWhitespace:
    let w = w0.strip(leading = false, chars = {',', ';', ':', '?', '!', ')'})
    if w.len < 2 or w[0] != '@' or not isPicturePath(w[1 .. ^1]): continue
    let p = absProjectPath(w[1 .. ^1])
    if p in result: continue
    let why = aiPicWhy(p)
    if why.len == 0: result.add p
    elif not quiet: setMsg(extractFilename(p) & ": " & why & " — not sent", 2)

proc expandMentions(t: string): string =
  ## "@path" attaches a file; @file @selection @diff @staged @problems @terminal @tree attach context
  result = t
  var extra = ""
  var seen: HashSet[string]
  for w0 in t.splitWhitespace:
    let w = w0.strip(leading = false, chars = {',', '.', ';', ':', '?', '!', ')'})
    if w.len < 2 or w[0] != '@' or w in seen: continue
    seen.incl w
    let b = buf()
    case w
    of "@file":
      if aiSecretFile(b.path): extra.add "\n<file path=\"" & relPath(b.path) & "\">" & AiSecretNote & "</file>"
      elif b.path.len > 0 or b.title.len > 0:
        extra.add "\n<file path=\"" & (if b.path.len > 0: relPath(b.path) else: b.name) & "\">\n" & b.allText & "\n</file>"
    of "@selection":
      let (a, e) = b.primary.range
      if aiSecretFile(b.path): extra.add "\n<selection file=\"" & relPath(b.path) & "\">" & AiSecretNote & "</selection>"
      elif a != e: extra.add "\n<selection file=\"" & relPath(b.path) & "\">\n" & b.getText(a, e) & "\n</selection>"
    of "@diff":
      let d = gitText("diff --no-color HEAD")
      extra.add "\n<git-diff>\n" & (if d.len > 0: d else: "(no changes)") & "\n</git-diff>"
    of "@staged":
      let d = gitText("diff --no-color --cached")
      extra.add "\n<git-diff staged=\"true\">\n" & (if d.len > 0: d else: "(nothing staged)") & "\n</git-diff>"
    of "@problems":
      let p = problemsText()
      extra.add "\n<problems>\n" & (if p.len > 0: p else: "(none reported)") & "\n</problems>"
    of "@terminal":
      extra.add "\n<terminal-output>\n" & termTail(120) & "\n</terminal-output>"
    of "@tree":
      var fs = projectFiles()
      if fs.len > 600: fs.setLen(600)
      extra.add "\n<project-files>\n" & fs.join("\n") & "\n</project-files>"
    else:
      let (srv, uri) = mcpMentionOf(w)
      if srv != nil and (srv.name & "\0" & uri) in mcpResCache:
        extra.add "\n<resource server=\"" & srv.name & "\" uri=\"" & uri & "\">\n" & mcpResCache[srv.name & "\0" & uri] &
                  "\n</resource>"
        continue
      let p = absProjectPath(w[1 .. ^1])
      if isPicturePath(p): continue            # (a picture goes as one: aiMentionedPics)
      if aiSecretFile(p) and fileExists(p):
        extra.add "\n<file path=\"" & relPath(p) & "\">" & AiSecretNote & "</file>"
      elif fileExists(p) and getFileSize(p) < 400_000:
        try: extra.add "\n<file path=\"" & relPath(p) & "\">\n" & readFile(p) & "\n</file>"
        except CatchableError: discard
  if extra.len > 0: result = extra & "\n\n" & t

# ── project instructions (AGENTS.md, CLAUDE.md …) go into the system prompt ──

proc projectInstructions(): string =
  if not sBool("ai.projectInstructions"): return ""
  for f in ["AGENTS.md", "CLAUDE.md", "NED.md", ".ned/instructions.md", ".github/copilot-instructions.md"]:
    let p = rootDir / f
    if fileExists(p):
      try:
        var t = readFile(p)
        if t.len > 12_000: t = t[0 ..< 12_000] & "\n…"
        result.add "\n\n<project-instructions file=\"" & f & "\">\n" & t.strip & "\n</project-instructions>"
      except CatchableError: discard
