## The Nim tour's lessons (tour/lesson*.nim), read into ned when it is built, and what ned needs to know of one:
## its title, its cells' titles, the exercise's answer (folded away when the lesson opens), whether a check said ✓,
## and the progress kept between runs. ned's side — the tabs, the commands — is editor/tour.nim; this part is a
## module of its own so that tests/unit/ttour.nim can test it.

import std/[json, strutils]

const TourLessons* = [
  ("lesson01_hello.nim", staticRead("../../../tour/lesson01_hello.nim")),
  ("lesson02_values.nim", staticRead("../../../tour/lesson02_values.nim")),
  ("lesson03_control.nim", staticRead("../../../tour/lesson03_control.nim")),
  ("lesson04_procs.nim", staticRead("../../../tour/lesson04_procs.nim")),
  ("lesson05_collections.nim", staticRead("../../../tour/lesson05_collections.nim")),
  ("lesson06_iterators.nim", staticRead("../../../tour/lesson06_iterators.nim")),
  ("lesson07_objects.nim", staticRead("../../../tour/lesson07_objects.nim")),
  ("lesson08_refs.nim", staticRead("../../../tour/lesson08_refs.nim")),
  ("lesson09_generics.nim", staticRead("../../../tour/lesson09_generics.nim")),
  ("lesson10_errors.nim", staticRead("../../../tour/lesson10_errors.nim")),
  ("lesson11_templates.nim", staticRead("../../../tour/lesson11_templates.nim")),
  ("lesson12_macros.nim", staticRead("../../../tour/lesson12_macros.nim")),
  ("lesson13_async.nim", staticRead("../../../tour/lesson13_async.nim")),
  ("lesson14_stdlib.nim", staticRead("../../../tour/lesson14_stdlib.nim")),
  ("lesson15_memory.nim", staticRead("../../../tour/lesson15_memory.nim")),
  ("lesson16_c.nim", staticRead("../../../tour/lesson16_c.nim"))]

type TourProgress* = object
  at*: int                      ## the lesson you were at (from 0)
  done*: seq[int]               ## the lessons whose exercise said ✓ (from 0)
  made*: seq[(string, string)]  ## each copy's file and the lesson it was made from (its hash): an unchanged old
                                ## copy is replaced when ned has a newer lesson

func tourTitle*(text: string): string =
  ## "# Nim tour · 3 of 16 · Control flow" → "Control flow"
  let first = text.split('\n', 1)[0]
  let k = first.rfind(" · ")
  if k >= 0: first[k + " · ".len .. ^1].strip else: first.strip(chars = {'#', ' '})

func tourCellTitles*(text: string): seq[string] =
  ## the titles of a lesson's cells: what follows `# %%` on their first lines
  for l in text.splitLines:
    if l.startsWith("# %%"):
      let t = l[4 .. ^1].strip
      if t.len > 0: result.add t

func tourAnswerFold*(lines: openArray[string]): (int, int) =
  ## the exercise's answer: its `# Answer:` line and the last of the indented lines under it ((-1, -1): none)
  for i in countdown(lines.high, 0):
    if lines[i].strip(leading = false) == "# Answer:":
      var last = i
      for k in i + 1 .. lines.high:
        if lines[k].startsWith("  #"): last = k
        elif lines[k].strip.len > 0: break
      return (if last > i: (i, last) else: (-1, -1))
  (-1, -1)

func tourExerciseLine*(lines: openArray[string]): int =
  ## the `# %% Exercise: …` line, -1 if none
  for i in countdown(lines.high, 0):
    if lines[i].startsWith("# %% Exercise"): return i
  -1

func tourPassed*(output: openArray[string]): bool =
  ## a check's output says ✓, and nothing in it says "not yet"
  var ok = false
  for l in output:
    if "not yet" in l: return false
    if l.strip.startsWith("✓"): ok = true
  ok

func tourHash*(text: string): string =
  ## a short fingerprint of a lesson's text (FNV-1a), to know a copy made from it
  var h = 0xcbf29ce484222325'u64
  for c in text:
    h = (h xor uint64(ord(c))) * 0x100000001b3'u64
  toHex(h)

proc tourProgressFrom*(s: string): TourProgress =
  ## the progress from its JSON (what is missing or wrong in it: left out)
  try:
    let j = parseJson(s)
    result.at = j{"at"}.getInt
    for d in j{"done"}.getElems:
      if d.kind == JInt and d.getInt notin result.done: result.done.add d.getInt
    let made = j{"made"}
    if made != nil and made.kind == JObject:
      for f, h in made:
        if h.kind == JString: result.made.add (f, h.getStr)
  except CatchableError: discard

proc tourProgressJson*(p: TourProgress): string =
  var made = newJObject()
  for (f, h) in p.made: made[f] = %h
  pretty(%*{"at": p.at, "done": p.done, "made": made})

func tourMadeFrom*(p: TourProgress, file: string): string =
  ## the hash of the lesson a copy was made from ("" when not known)
  for (f, h) in p.made:
    if f == file: return h
  ""

proc tourSetMade*(p: var TourProgress, file, h: string) =
  for m in p.made.mitems:
    if m[0] == file:
      m[1] = h
      return
  p.made.add (file, h)
