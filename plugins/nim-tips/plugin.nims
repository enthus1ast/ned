## nim-tips — a Nim tip a day: something about the language, its library or its tools, in a note when ned starts
##
##   at start              once a day, the next tip in a note in the corner (plugins.nim-tips.atStart)
##   Nim tip: another one  the next tip, in a note and in the status line
##   Nim tip: all of them  every tip in a Markdown tab of its own, to read through
##   settings              plugins.nim-tips.atStart (true)
##
## The tips go round in order, each once before the first comes back; the plugin keeps where it is, and the day it
## last showed one, in its data folder (state.json).
import nedplugin

requiresNed(">= 6.31")
pluginInfo(version = "1.0.0", author = "Foxoman", homepage = "https://github.com/foxoman/ned", license = "GPL-3.0-or-later")

settingDef("atStart", true, "Nim tips: a tip in a note when ned starts, once a day")

const Tips = [
  "`echo` takes any number of values: `echo \"x = \", x, \" and \", y` — each turned to text with `$`.",
  "`x.len` and `len(x)` are the same call: any routine can be written as a method of its first argument (UFCS).",
  "`let` cannot change after it is set, `var` can, `const` is worked out while compiling.",
  "`func` is a `proc` without side effects: the compiler checks that it changes nothing outside itself.",
  "`result` is there in every routine that returns something: set it, and it is returned at the end.",
  "`defer: close(f)` runs when the block it is in ends — however it ends, an exception too.",
  "`for i, x in s:` gives each item with its index; `pairs` and `items` are what make it work.",
  "`a ..< b` is a to b without b: `for i in 0 ..< s.len` goes over every index of `s`.",
  "`s[^1]` is the last item, `s[^2]` the one before: `^` counts from the end.",
  "`case` on an enum must list every value (or have an `else`): the compiler tells you which you forgot.",
  "`std/strformat`: `fmt\"{name} is {age} years old\"` and `&\"{x:>8.2f}\"` for widths and decimals.",
  "`std/sequtils`: `s.mapIt(it * 2)`, `s.filterIt(it > 0)`, `s.anyIt(it == 3)` — `it` is each item.",
  "`std/tables`: `var t = initTable[string, int]()`; `t.getOrDefault(k)`; `t.mgetOrPut(k, 0) += 1` counts.",
  "`Option[T]` (std/options) says \"maybe a value\": `some(3)`, `none(int)`, `if o.isSome: echo o.get`.",
  "`object` is a value, copied when assigned; `ref object` is shared — two names for the same thing.",
  "Nim 2 manages memory with ORC: reference counting, a cycle collector for the rest, `=destroy` at the end of a scope.",
  "`sink` and `lent` parameters tell the compiler a value is moved in, or only lent: fewer copies.",
  "`{.raises: [].}` on a routine: the compiler checks it can raise nothing — handy at the edges of a program.",
  "`when defined(release):` keeps code only in a release build: `nim c -d:release` sets it.",
  "`nim c -r file.nim` compiles and runs; `nim r file.nim` does the same, keeping the program out of your folder.",
  "`nim check file.nim` finds the errors without building anything — what ned runs when you save.",
  "`-d:danger` turns every runtime check off: only for code you have tested well.",
  "`--mm:arc` is ORC without the cycle collector: a little faster when you know you make no cycles.",
  "`doAssert x > 0` stays in release builds; `assert` goes in `-d:danger` ones.",
  "`runnableExamples:` in a routine's doc comment is code `nim doc` compiles and runs, and shows.",
  "`template` pastes its body where it is called; `macro` writes code with the AST in your hands.",
  "`dumpTree:` (std/macros) shows the AST of the code in it — the first step of writing a macro.",
  "`typedesc` parameters take a type: `proc zero(T: typedesc): T = default(T)`, then `zero(int)`.",
  "`concept` describes what a type must be able to do; any type that can is accepted.",
  "Generics: `proc biggest[T](a, b: T): T = (if a > b: a else: b)` works for any `T` with `>`.",
  "`distinct` makes a new type from an old one: `type Meters = distinct float` stops meters and seconds mixing.",
  "`enum` values can have text: `type Colour = enum red = \"Red\", green = \"Green\"`; `$red` is \"Red\".",
  "`set[char]` and `set[enum]` are bit sets: `if c in {'a'..'z', '_'}:` is one test.",
  "`try: … except ValueError as e: echo e.msg` — and `finally:` runs either way.",
  "`importc` and `header` call C directly: `proc puts(s: cstring): cint {.importc, header: \"<stdio.h>\".}`.",
  "`{.emit: \"\"\"…\"\"\".}` puts C straight into the generated C — ned colours it and checks it as C.",
  "`nimble init` starts a package; `nimble install`, `nimble test`, `nimble build` do the rest.",
  "`atlas` keeps a project's dependencies in its own deps/ folder, each at the version it pins.",
  "`std/monotimes`: `let t = getMonoTime(); …; echo getMonoTime() - t` times a piece of code.",
  "`std/strutils`: `split`, `strip`, `startsWith`, `replace`, `parseInt`, `toUpperAscii`, `%` for formats.",
  "`iterator` gives values one at a time with `yield`, to a `for` loop: nothing is collected into a list first.",
  "`object` variants: `case kind: Kind` inside an object gives each kind its own fields, checked at runtime.",
  "In ned: Alt+M expands the macro or template call under the cursor, so you see the code it writes.",
  "In ned: *Why?* on a routine says what it may raise, what side effects it has, and where they come from.",
]

var
  next = 0                      # the tip shown next
  lastDay = ""                  # the day a tip was last shown at start

proc readState() =
  ## where the tips are, and the day one was last shown, from the data folder
  try:
    let j = parseJson(readData("state.json"))
    next = j{"next"}.getInt(0) mod Tips.len
    lastDay = j{"day"}.getStr
  except CatchableError: discard

proc writeState() =
  ## where the tips are, and the day, into the data folder
  writeData("state.json", $(%*{"next": next, "day": lastDay}) & "\n")

proc plain(tip: string): string =
  ## a tip without its Markdown backticks and stars, for a note
  tip.replace("`", "").replace("*", "")

proc showNext() =
  ## the next tip, in a note and the status line, and the one after it next time
  let t = Tips[next]
  toast("Nim tip " & $(next + 1) & "/" & $Tips.len & ": " & plain(t))
  message("Nim tip: " & plain(t))
  next = (next + 1) mod Tips.len
  writeState()

onStartup do (ev: Event):
  readState()
  let today = localTime()[0 ..< 10]
  if setting("atStart", true) and today != lastDay:
    lastDay = today
    showNext()

command "Nim tip: another one":
  readState()
  showNext()

command "Nim tip: all of them":
  var md = "# Nim tips\n\n"
  for i, t in Tips: md.add $(i + 1) & ". " & t & "\n"
  discard newTab("Nim tips", md, "markdown")
