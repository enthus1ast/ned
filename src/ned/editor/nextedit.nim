# ── next-edit suggestions (editor.nextEdit): after a change to a name — `width` made `size` — the next place that
#    still says `width` shows "→ size ⇥": Tab goes there, Tab again makes the same change (and shows the place after
#    it), Esc says no. Without a repeat in the file and with AI set up (ai.nextEdit), the quick model is asked where
#    the edit just made leads next ──

var
  nesSug: tuple[buf, change: int, at: Pos, fromT, toT: string, ai: bool] = (-1, -1, Pos(), "", "", false)
  nesAsked: tuple[buf, change: int] = (-1, -1)
  nesJob: Job

proc nesVisible(b: Buffer): bool =
  ## whether the suggestion on hand still applies to this buffer: it was made for the same text, with one cursor, and
  ## the word to change is still at its place
  nesSug.buf == b.id and nesSug.change == b.changeId and b.cursors.len == 1 and nesSug.at.line < b.lines.len and
    b.lines[nesSug.at.line].continuesWith(nesSug.fromT, nesSug.at.col)

proc nesHint(b: Buffer, line: int): (int, string) =
  ## the hint drawn after the place to change: (column, text) — column -1 for none
  if not nesVisible(b) or nesSug.at.line != line: return (-1, "")
  (nesSug.at.col + nesSug.fromT.len, " → " & nesSug.toT & " ⇥" & (if nesSug.ai: " (AI)" else: ""))

proc nesClear() =
  ## forgets the suggestion
  nesSug.buf = -1

func nesWordAt(s: string, i, n: int): bool =
  ## is s[i ..< i+n] a whole word (no word character just before or after)?
  (i == 0 or not isWordByte(s[i - 1])) and (i + n >= s.len or not isWordByte(s[i + n]))

proc nesFind(b: Buffer, t: string, after: Pos): Pos =
  ## the next whole-word `t` after a place (round to the top), line -1: none
  let n = b.lines.len
  for k in 0 .. min(n, 200_000):
    let l = (after.line + k) mod n
    let s = b.lines[l]
    var i = if k == 0: after.col else: 0
    if k == n:                      # (back on the starting line: only before the place)
      i = 0
    while true:
      let j = s.find(t, i)
      if j < 0: break
      if k == n and j >= after.col: break
      if nesWordAt(s, j, t.len): return Pos(line: l, col: j)
      i = j + 1
  Pos(line: -1)

func nesChange(before, now: string): (int, string, string) =
  ## the word a line's edit changed: (its column, the word before, the word now) — column -1 when the change is no
  ## word made another (text added or taken away around words, a change over several words)
  if before == now: return (-1, "", "")
  var p = 0
  while p < before.len and p < now.len and before[p] == now[p]: inc p
  var s = 0
  while s < before.len - p and s < now.len - p and before[before.len - 1 - s] == now[now.len - 1 - s]: inc s
  var a = p
  while a > 0 and isWordByte(before[a - 1]): dec a
  var eo = before.len - s
  var en = now.len - s
  while eo < before.len and isWordByte(before[eo]):
    inc eo
    inc en
  let t0 = before[a ..< eo]
  let t1 = now[a ..< en]
  if t0.len < 2 or t1.len == 0 or t0 == t1: return (-1, "", "")
  for c in t0:
    if not isWordByte(c): return (-1, "", "")
  for c in t1:
    if not isWordByte(c): return (-1, "", "")
  if t0[0] in Digits: return (-1, "", "")
  (a, t0, t1)

proc nesShow(b: Buffer, at: Pos, t0, t1: string, ai = false) =
  ## makes the place `at` the suggestion (change word `t0` into `t1`, from the AI if `ai`) for the text as it is now,
  ## redraws so the hint appears after it, and says in the message line what Tab and Esc do
  nesSug = (b.id, b.changeId, at, t0, t1, ai)
  needRender = true
  let away = at.line < b.topLine or at.line > b.topLine + max(1, textH) - 1
  info("Tab: “" & t0 & "” → “" & t1 & "” at line " & $(at.line + 1) & (if away: " (off screen)" else: "") &
       " too · Esc: no" & (if ai: " · suggested by AI" else: ""))

proc nesAskAi(b: Buffer, line: int, before, now: string) =
  ## no repeat of the change in the file: the quick model is asked where it leads next
  if aiSecretFile(b.path): return                 # (a file of secrets is not sent: ai.redactSecrets)
  if nesJob != nil and not nesJob.done: killProc(nesJob.pr)
  let a = max(0, line - 40)
  let e = min(b.lines.high, line + 40)
  var excerpt = ""
  for l in a .. e: excerpt.add $(l + 1) & "| " & b.lines[l] & "\n"
  let instr = "You predict the next edit a programmer will make in their code. Reply with ONLY a JSON object " &
              "{\"line\": N, \"old\": \"…\", \"new\": \"…\"}: on line N (the numbers before the |), the exact text " &
              "\"old\" becomes \"new\" — the one edit most likely to follow the one just made (the same change " &
              "where it is needed too, or what that change requires). Not the line just edited. If nothing " &
              "follows from it, reply {}."
  let user = "File: " & (if b.path.len > 0: relPath(b.path) else: b.name) & " (" & b.lang.name & ")\n" &
             "Just edited line " & $(line + 1) & ":\n  before: " & before & "\n  now:    " & now & "\n<code>\n" &
             excerpt & "</code>"
  let id = b.id
  let ch = b.changeId
  nesJob = aiFastAsk(instr, user, 200, proc(t: string) =
    let bb = bufById(id)
    if bb == nil or bb.changeId != ch: return
    var j: JsonNode
    try:
      let a = t.find('{')
      let z = t.rfind('}')
      if a < 0 or z < a: return
      j = parseJson(t[a .. z])
    except CatchableError: return
    let l = j{"line"}.getInt - 1
    let o = j{"old"}.getStr
    let n = j{"new"}.getStr
    if l < 0 or l > bb.lines.high or l == line or o.len == 0 or o == n or '\n' in o or '\n' in n: return
    let c = bb.lines[l].find(o)
    if c < 0: return
    nesShow(bb, Pos(line: l, col: c), o, n, ai = true))

proc nesTick() =
  ## main loop: a moment after an edit, what it suggests next
  if not sBool("editor.nextEdit") or focus != fEditor or compOpen or promptKind != pNone or pickKind != pickNone:
    return
  let b = buf()
  if b.readOnly or b.cursors.len != 1 or not b.nesHas or b.nesLine > b.lines.high: return
  if nesAsked.buf == b.id and nesAsked.change == b.changeId: return
  if nesSug.buf == b.id and nesSug.change == b.changeId: return
  if msSince(b.lspChangeAt) < 450: return
  nesAsked = (b.id, b.changeId)
  let before = b.nesBefore
  let now = b.lines[b.nesLine]
  let (col, t0, t1) = nesChange(before, now)
  if col >= 0:
    let p = b.nesFind(t0, Pos(line: b.nesLine, col: col))
    if p.line >= 0:
      b.nesShow(p, t0, t1)
      return
  if before != now and sBool("ai.nextEdit") and b.path.len > 0: b.nesAskAi(b.nesLine, before, now)

proc nesTab(b: Buffer): bool =
  ## Tab with a suggestion showing: to its place (the text selected), then the change made there
  if not nesVisible(b) or not b.canEdit(): return false
  let a = nesSug.at
  let e = Pos(line: a.line, col: a.col + nesSug.fromT.len)
  let (sa, se) = b.primary.range
  if sa != a or se != e:
    if a.line < b.topLine or a.line > b.topLine + max(1, textH) - 1: b.centerOn(a)
    b.setSingle(e, a)
    info("Tab: make it “" & nesSug.toT & "” · Esc: no")
    return true
  let t0 = nesSug.fromT
  let t1 = nesSug.toT
  let ai = nesSug.ai
  b.beginEdit()
  let q = b.replaceText(a, e, t1)
  b.endEdit()
  b.setSingle(q)
  nesAsked = (b.id, b.changeId)
  nesClear()
  if not ai:
    # the same change further on: shown at once (Tab, Tab… through the file)
    let p = b.nesFind(t0, q)
    if p.line >= 0: b.nesShow(p, t0, t1)
    else: info("No more “" & t0 & "” in " & b.name)
  true
