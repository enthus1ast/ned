## code-pet — a small pet in the status bar that lives on your work: it eats when you save, grows with your commits
##
##   the status bar     =^.^= Biscuit · lv 3 — happy when fed, hungry after a long time without a save (=;.;=),
##                      asleep (=-.-= zZ) after twenty minutes without typing; a note when it grows a level
##   Pet: how is it?    its name, level, how fed it is, how old it is, the commits it has eaten
##   Pet: name it…      a name of your own
##   Pet: feed it       a treat, once an hour
##   settings           plugins.code-pet.kind: cat, dog, bear, owl or blob · .commits (true): count the commits
##                      of the project (git) to grow it
##
## A save feeds it a little and gives it 1 point, a new commit 5. It is kept in the plugin's data folder (pet.json),
## on this device only. Nothing happens to it while ned is closed: it is a calm pet.
import nedplugin
import std/math

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")
permission("shell", "counts the project's commits with git rev-list, for the pet to grow (plugins.code-pet.commits)")

settingDef("kind", "cat", "Pet: which one — cat, dog, bear, owl or blob")
settingDef("commits", true, "Pet: it grows with the project's commits (git)")

const
  Names = ["Biscuit", "Pixel", "Mochi", "Nimbus", "Byte", "Pickle", "Noodle", "Waffle"]
  SleepAfter = 20 * 60.0        # seconds without typing: asleep
  TreatEvery = 3600.0

type Pet = object
  name: string
  born: string                  # the day it came
  xp: int
  food: int                     # 0 hungry … 100 full
  lastFed, lastTreat: float
  eaten: int                    # the commits it has eaten
  commits: JsonNode             # project → commits counted

var
  pet: Pet
  loaded = false
  lastActive = 0.0
  lastLevel = 0

func level(xp: int): int =
  ## its level: 1 at the start, then each a little further than the last (5, 20, 45, 80 … points)
  1 + int(sqrt(float(xp) / 5.0))

func face(kind, mood: string): string =
  ## how it looks: its kind, happy, hungry or asleep
  case kind
  of "dog":
    case mood
    of "asleep": "U-ᴥ-U zZ"
    of "hungry": "U;ᴥ;U"
    else: "U•ᴥ•U"
  of "bear":
    case mood
    of "asleep": "ʕ-ᴥ-ʔ zZ"
    of "hungry": "ʕ;ᴥ;ʔ"
    else: "ʕ•ᴥ•ʔ"
  of "owl":
    case mood
    of "asleep": "(-v-) zZ"
    of "hungry": "(;v;)"
    else: "(OvO)"
  of "blob":
    case mood
    of "asleep": "(-‿-) zZ"
    of "hungry": "(;_;)"
    else: "(◕‿◕)"
  else:
    case mood
    of "asleep": "=-.-= zZ"
    of "hungry": "=;.;="
    else: "=^.^="

proc save() =
  ## the pet into the data folder
  writeData("pet.json", $(%*{"name": pet.name, "born": pet.born, "xp": pet.xp, "food": pet.food,
                              "lastFed": pet.lastFed, "lastTreat": pet.lastTreat, "eaten": pet.eaten,
                              "commits": pet.commits}) & "\n")

proc load() =
  ## the pet from the data folder, or a new one (a name of its own, full, born today)
  if loaded: return
  loaded = true
  try:
    let j = parseJson(readData("pet.json"))
    pet = Pet(name: j{"name"}.getStr, born: j{"born"}.getStr, xp: j{"xp"}.getInt, food: j{"food"}.getInt(100),
              lastFed: j{"lastFed"}.getFloat, lastTreat: j{"lastTreat"}.getFloat, eaten: j{"eaten"}.getInt,
              commits: j{"commits"})
  except CatchableError: discard
  if pet.commits == nil or pet.commits.kind != JObject: pet.commits = newJObject()
  if pet.name.len == 0:
    let now = unixTime()
    pet = Pet(name: Names[int(now) mod Names.len], born: localTime()[0 ..< 10], food: 100, lastFed: now,
              commits: newJObject())
    save()
  lastLevel = level(pet.xp)

proc mood(now: float): string =
  ## asleep after a while without typing, hungry when it has not eaten for long, else happy
  if lastActive > 0 and now - lastActive > SleepAfter: "asleep"
  elif pet.food < 30: "hungry"
  else: "happy"

proc show() =
  ## the pet in the status bar
  let now = unixTime()
  status(face(setting("kind", "cat"), mood(now)) & " " & pet.name & " · lv " & $level(pet.xp))

proc grew() =
  ## a note when its level went up
  let l = level(pet.xp)
  if l > lastLevel:
    toast(face(setting("kind", "cat"), "happy") & " " & pet.name & " grew to level " & $l & "!")
  lastLevel = l

proc hungerTick() =
  ## (every minute) a little hungrier — one point every three minutes it has not eaten
  let now = unixTime()
  let gone = int((now - pet.lastFed) / 180.0)
  let f = max(0, 100 - gone)
  if f < pet.food:
    pet.food = f
    save()

proc countCommits() =
  ## the project's commits counted: the new ones since last time are eaten (5 points each); the first count of a
  ## project only notes where it is
  if not setting("commits", true) or not allowed("shell"): return
  let root = projectRoot()
  if root.len == 0: return
  shellAsync("git rev-list --count HEAD 2>/dev/null") do (output: string, code: int):
    if code != 0: return
    var n = 0
    try: n = parseInt(output.strip)
    except ValueError: return
    let before = pet.commits{root}.getInt(-1)
    pet.commits[root] = %n
    if before >= 0 and n > before:
      let k = n - before
      pet.xp += 5 * k
      pet.eaten += k
      pet.food = min(100, pet.food + 10 * k)
      pet.lastFed = unixTime() - float(100 - pet.food) * 180.0
      toast(face(setting("kind", "cat"), "happy") & " " & pet.name & " ate " & $k &
            (if k == 1: " commit" else: " commits") & " — yum!")
      grew()
    save()
    show()

onStartup do (ev: Event):
  load()
  lastActive = unixTime()
  hungerTick()
  show()
  countCommits()

onChange("*") do (ev: Event):
  load()
  let wasAsleep = mood(unixTime()) == "asleep"
  lastActive = unixTime()
  if wasAsleep: message(pet.name & " woke up")
  show()

onSave("*") do (ev: Event):
  load()
  pet.xp += 1
  pet.food = min(100, pet.food + 5)
  pet.lastFed = unixTime() - float(100 - pet.food) * 180.0     # (hunger counts on from how full it is now)
  grew()
  save()
  show()

var minutes = 0
discard every(60_000) do ():
  load()
  hungerTick()
  inc minutes
  if minutes mod 10 == 0: countCommits()
  show()

command "Pet: how is it?":
  load()
  let now = unixTime()
  let m = mood(now)
  message(face(setting("kind", "cat"), m) & " " & pet.name & " — level " & $level(pet.xp) & " (" & $pet.xp &
          " points), " & (if m == "asleep": "asleep" elif m == "hungry": "hungry" else: "happy") &
          ", fed " & $pet.food & "%, " & $pet.eaten & (if pet.eaten == 1: " commit" else: " commits") &
          " eaten, here since " & pet.born)

command "Pet: name it…":
  load()
  let n = ask("Your pet's name:", pet.name).strip
  if n.len > 0:
    pet.name = n[0 ..< min(n.len, 20)]
    save()
    show()
    message(face(setting("kind", "cat"), "happy") & " Hello, " & pet.name & "!")

command "Pet: feed it":
  load()
  let now = unixTime()
  if now - pet.lastTreat < TreatEvery:
    message(pet.name & " is still full — the next treat in " & $int((TreatEvery - (now - pet.lastTreat)) / 60 + 1) &
            " min")
  else:
    pet.lastTreat = now
    pet.food = min(100, pet.food + 30)
    pet.lastFed = now - float(100 - pet.food) * 180.0
    pet.xp += 1
    grew()
    save()
    show()
    message(face(setting("kind", "cat"), "happy") & " " & pet.name & " loved it")
