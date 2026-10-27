# ── why? (6.32): where an exception or a side effect comes from — the place in the routine where it comes in, the
#    routine called there, the place in that one, … down to the raise, the global or the declaration that starts it
#    (ned's engine, nxWhy). For a routine (its raises hint: a tap), a compiler's "can raise an unlisted exception"
#    and "can have side effects". Each step is a row of a list; Enter goes there ──

proc whyRoutineAt(f: NxFile, line: int): int =
  ## the innermost routine whose lines hold `line` (-1: none)
  result = -1
  var span = high(int)
  for i in 0 ..< f.syms.len:
    let s = f.syms[i]
    if s.kind notin NxRoutineKinds or s.name.len == 0: continue
    let e = max(s.line, s.endLine)
    if line >= s.line and line <= e and e - s.line < span:
      span = e - s.line
      result = i

proc whyLabel(s: NxWhyStep, exc: string, fx: bool): string =
  case s.kind
  of nwCall: s.routine & " calls " & s.what
  of nwRaise: s.routine & ": raise " & exc & " — it starts here"
  of nwGlobal: s.routine & " uses the global " & s.what & " — a side effect"
  of nwDeclared:
    if fx: s.what
    elif s.what.startsWith("{."): s.routine & " says it raises it: " & s.what
    else: s.routine & " says it raises it"
  of nwStop: s.routine & ": ned's engine follows it no further (" & s.what & ")"

proc whyShow(r: NxRef, exc: string, fx: bool) =
  ## the steps, as a list to go through
  var steps: seq[NxWhyStep]
  try: steps = nxWhy(r, exc, fx)
  except CatchableError as e:
    internalError("why", e)
    return
  if steps.len == 0:
    info("ned's engine does not see where " & (if fx: "its side effect" else: exc) & " comes from")
    return
  var items: seq[PickItem]
  for k, s in steps:
    let icon = case s.kind
               of nwCall: "→"
               of nwRaise, nwGlobal: "●"
               of nwDeclared: "≡"
               of nwStop: "?"
    items.add PickItem(label: $(k + 1) & "  " & whyLabel(s, exc, fx),
                       detail: nimShownPath(s.path) & ":" & $(s.line + 1), icon: icon,
                       path: s.path, line: s.line, col: s.col)
  openPicker(pickSymbol, (if fx: "Why " & r.sym.name & " has side effects"
                          else: "Why " & r.sym.name & " can raise " & exc), items)
  pickSel = 0                                       # (the chain from its start)

proc whyAct(r: NxRef, exc: string, fx: bool): Action = (proc() = whyShow(r, exc, fx))

proc whyOf(r: NxRef) =
  ## a routine: what it raises (one: its chain; several: which one) — or, raising nothing, its side effects
  let x = nxRaisesOfBody(r, 4000, 3000)
  var pure = true
  let p = nxSideEffectsOf(r, 4000, 2000)
  if p.known and not p.pure: pure = false
  if x.known and x.excs.len > 0:
    if x.excs.len == 1 and pure:
      whyShow(r, x.excs[0].name, false)
      return
    var items: seq[(string, string, proc() {.closure.})]
    for e in x.excs: items.add act(e.name, "where it comes from", whyAct(r, e.name, false))
    if not pure: items.add act("side effects", "why it cannot be a func", whyAct(r, "", true))
    openActions("Why? — " & r.sym.name, items)
    return
  if not pure:
    whyShow(r, "", true)
    return
  if not x.known:
    info("ned's engine cannot tell what " & r.sym.name & " raises" & (if x.why.len > 0: ": " & x.why else: ""))
  else:
    info(r.sym.name & " raises nothing" & (if p.known: " and has no side effects" else: "") &
         ", as ned's engine reads it")

proc cmdWhy(atLine = -1) =
  ## Why? — at the cursor (or a line): a compiler's error about an exception or a side effect there, else the
  ## routine the line is in
  let b = buf()
  if b.lang == nil or b.lang.mode != lmNim or not nimEngineOn(b):
    info("Why? is for Nim files (ned's engine)")
    return
  let line = if atLine >= 0: atLine else: b.primary.head.line
  var f: NxFile
  try: f = nxFileFor(b)
  except CatchableError: discard
  if f == nil: return
  let ri = whyRoutineAt(f, line)
  if ri < 0:
    info("Put the cursor in a routine, or on a problem about what it raises")
    return
  let r = NxRef(file: f, idx: int32(ri))
  for d in diagsFor(b.path):
    if d.line != line: continue
    let m = d.msg
    let k = m.find("unlisted exception: ")
    if k >= 0:
      var e = k + "unlisted exception: ".len
      var w = ""
      while e < m.len and m[e] in IdentChars + {'.'}:
        w.add m[e]
        inc e
      if w.len > 0:
        whyShow(r, w.split('.')[^1], false)
        return
    if "can have side effects" in m:
      whyShow(r, "", true)
      return
  whyOf(r)

proc whyHintAct(bid, line: int): Action =
  ## (a tap on a routine's raises hint)
  (proc() =
    let b = bufById(bid)
    if b == nil or b != buf(): return
    cmdWhy(line))
