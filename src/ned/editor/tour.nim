# ── The Nim tour (Help › Nim tour): sixteen short lessons of Nim that run in the notebook, from the first echo to
#    calling C. The lessons are in ned (editor/tourlessons.nim reads tour/ when ned is built), so the tour works
#    with no files around. Each lesson opens as your own copy in ned's state folder (tour/), so what you change in
#    it stays; where you were and the lessons whose exercise said ✓ are kept beside them (tour/progress.json) ──

import tourlessons

var
  tourProg: TourProgress
  tourLoaded = false
  tourSeen = -1                       # (the notebook's outputs last looked at: its nbVersion)

proc tourDir(): string = absolutePath(stateDir() / "tour").normalizedPath

proc tourLoad() =
  if tourLoaded: return
  tourLoaded = true
  try: tourProg = tourProgressFrom(readFile(tourDir() / "progress.json"))
  except CatchableError: discard      # (none yet: the tour starts at the first lesson)

proc tourSave() =
  try:
    createDir(tourDir())
    writeFileSafe0(tourDir() / "progress.json", tourProgressJson(tourProg))
  except CatchableError as e: warn("Nim tour: your progress could not be kept: " & e.msg)

proc tourLessonOf(b: Buffer): int =
  ## the lesson a tab holds (from 0), -1 for any other tab
  if b == nil or b.path.len == 0 or parentDir(b.path) != tourDir(): return -1
  let f = extractFilename(b.path)
  for i, (name, _) in TourLessons:
    if name == f: return i
  -1

proc tourCopy(i: int): string =
  ## the lesson's copy in the state folder ("" when it cannot be written): made when there is none, made again when
  ## it is an unchanged copy of an older ned's lesson; a copy you changed stays as it is
  let (file, text) = TourLessons[i]
  result = tourDir() / file
  if bufIndexByPath(result) >= 0: return            # (open: the tab is what counts)
  let h = tourHash(text)
  let made = tourProg.tourMadeFrom(file)
  if fileExists(result):
    var cur = ""
    try: cur = readFile(result)
    except CatchableError: return
    if cur == text:
      if made != h: tourProg.tourSetMade(file, h)
      return
    if made.len == 0 or made != tourHash(cur):       # (yours: changed since it was made)
      if made.len > 0 and made != h:
        toast("Lesson " & $(i + 1) & " is newer in this ned: Help › Nim tour › Reset this lesson brings it " &
              "(your changes to it go)")
      return
  try:
    createDir(tourDir())
    writeFileSafe0(result, text)
    tourProg.tourSetMade(file, h)
  except CatchableError as e:
    error("Nim tour: " & e.msg)
    result = ""

proc tourFoldAnswer(b: Buffer) =
  ## the exercise's answer folded away (Alt+= or the ▸ opens it)
  let (a, e) = tourAnswerFold(b.lines)
  if a >= 0: b.addFold(a, e)

proc tourOpen(i: int) =
  ## lesson i in a tab (its copy made first when it needs to be), and the tour remembers it
  tourLoad()
  let i = clamp(i, 0, TourLessons.high)
  let p = tourCopy(i)
  if p.len == 0: return
  let wasOpen = bufIndexByPath(p) >= 0
  let b = openFile(p)
  if b == nil: return
  if not wasOpen: tourFoldAnswer(b)
  tourProg.at = i
  tourSave()
  if not haveExe("nim"):
    toast("The tour runs its cells with Nim, which is not installed — Help › Check setup", 2)
  else:
    info("Nim tour · lesson " & $(i + 1) & " of " & $TourLessons.len & ": " & tourTitle(TourLessons[i][1]) &
         " — Ctrl+Enter runs the cell at the cursor; Help › Nim tour has the next lesson")

proc tourCurrent(): int =
  ## the lesson in front, else the one you were at
  let i = tourLessonOf(buf())
  if i >= 0: return i
  tourLoad()
  clamp(tourProg.at, 0, TourLessons.high)

proc tourNext() =
  let i = tourCurrent()
  if i >= TourLessons.high:
    info("That was the last lesson of the Nim tour. Help › Nim tour › All the lessons lists them all")
    return
  tourOpen(i + 1)

proc tourPump() =
  ## (each round of the main loop: nothing to do unless an output of the notebook changed) a lesson whose
  ## exercise's check said ✓ is kept as done
  if nbVersion == tourSeen: return
  tourSeen = nbVersion
  for b in bufs:
    if b.id notin nbOuts: continue
    let i = tourLessonOf(b)
    if i < 0: continue
    tourLoad()
    if i in tourProg.done: continue
    let ex = tourExerciseLine(b.lines)
    if ex < 0: continue
    let outs = nbOuts[b.id]
    for ci, c in nbCells(b):
      if c[0] != ex + 1 or ci >= outs.len: continue
      let o = outs[ci]
      if o.running or o.err or o.code != nbCellCode(b, c) or not tourPassed(o.lines): continue
      tourProg.done.add i
      tourSave()
      if i < TourLessons.high:
        toast("Nim tour: lesson " & $(i + 1) & " done ✓", 4, "Next lesson", proc() = tourNext())
      else:
        toast("Nim tour: lesson " & $(i + 1) & " done ✓ — that was the last one", 4)

# ── the commands ──

proc cmdNimTour() =
  ## the tour: the lesson you were at (the first, the first time)
  tourLoad()
  tourOpen(tourProg.at)

proc cmdNimTourNext() =
  tourPump()
  tourNext()

proc cmdNimTourPrev() =
  let i = tourCurrent()
  if i <= 0:
    info("This is the first lesson of the Nim tour")
    return
  tourOpen(i - 1)

proc tourOpenAct(i: int): proc() {.closure.} = (proc() = tourOpen(i))

proc cmdNimTourIndex() =
  ## every lesson, a ✓ beside each one done; the one in front (or you were at) selected
  tourPump()
  tourLoad()
  var items: seq[(string, string, proc() {.closure.})]
  for i, (_, text) in TourLessons:
    var topics: seq[string]
    for t in tourCellTitles(text):
      if not t.startsWith("Exercise"): topics.add t
    items.add ((if i in tourProg.done: "✓ " else: "  ") & align($(i + 1), 2) & " · " & tourTitle(text),
               topics.join(" · "), tourOpenAct(i))
  openActions("Nim tour — " & $tourProg.done.len & " of " & $TourLessons.len & " lessons done", items)
  pickSel = max(0, pickShown.find(tourCurrent()))

proc tourReset(i: int) =
  let (file, text) = TourLessons[i]
  let p = tourDir() / file
  try:
    createDir(tourDir())
    writeFileSafe0(p, text)
  except CatchableError as e:
    error("Nim tour: " & e.msg)
    return
  tourLoad()
  tourProg.tourSetMade(file, tourHash(text))     # (a lesson done stays done: its ✓ was earned)
  tourSave()
  let k = bufIndexByPath(p)
  if k < 0:
    tourOpen(i)
    return
  let b = bufs[k]
  b.reloadBuffer()                    # (as an edit: Ctrl+Z brings your version back)
  b.folds.setLen(0)
  tourFoldAnswer(b)
  info("Lesson " & $(i + 1) & " is as it was — Ctrl+Z brings your version back")

proc cmdNimTourReset() =
  let i = tourLessonOf(buf())
  if i < 0:
    info("Open a lesson of the Nim tour first (Help › Nim tour)")
    return
  askConfirm("Discard your changes to lesson " & $(i + 1) & " and bring it back as it was? (y/n)", proc(c: char) =
    if c == 'y': tourReset(i))
